import { loadOrGenerateIdentity } from "./sidecar-identity.js";
import { EventBuffer } from "./sidecar-buffer.js";
import { GatewayConnection } from "./sidecar-gateway.js";
import { PhoneServer } from "./sidecar-phone.js";

export class Sidecar {
  #gatewayUrl;
  #gatewayToken;
  #bootstrapToken;
  #sidecarPort;
  #logger;
  #gateway;
  #phone;
  #buffer;
  #subscribedSessions = new Set();

  constructor({ gatewayUrl, gatewayToken, bootstrapToken, sidecarPort, logger }) {
    this.#gatewayUrl = gatewayUrl;
    this.#gatewayToken = gatewayToken;
    this.#bootstrapToken = bootstrapToken;
    this.#sidecarPort = sidecarPort;
    this.#logger = logger;
    this.#buffer = EventBuffer();
  }

  async connectToGateway() {
    const identity = loadOrGenerateIdentity();
    this.#gateway = new GatewayConnection({
      gatewayUrl: this.#gatewayUrl,
      identity,
      gatewayToken: this.#gatewayToken,
      logger: this.#logger,
    });

    this.#wireGatewayEvents();
    await this.#gateway.connect();
  }

  async startPhoneServer() {
    this.#phone = new PhoneServer({
      port: this.#sidecarPort,
      bootstrapToken: this.#bootstrapToken,
      logger: this.#logger,
    });

    this.#wirePhoneEvents();
    await this.#phone.start();
  }

  #wireGatewayEvents() {
    this.#gateway.on("event", (frame) => {
      // Buffer all bufferable events.
      this.#buffer.push(frame);

      // Forward to phone if connected.
      if (this.#phone?.phoneConnected) {
        this.#phone.sendEvent(frame);
      }
    });

    this.#gateway.on("forwarded-response", (frame) => {
      if (this.#phone?.phoneConnected) {
        this.#phone.sendToPhone(frame);
      }
    });

    this.#gateway.on("disconnected", () => {
      this.#logger?.warn("Gateway disconnected, will reconnect");
      this.#gateway.reconnect();
    });

    this.#gateway.on("error", (err) => {
      this.#logger?.error("Gateway error", { error: err.message });
    });

    this.#gateway.on("connected", () => {
      this.#logger?.info("Gateway reconnected, resubscribing", {
        sessions: [...this.#subscribedSessions],
      });
      // Resubscribe to all tracked sessions.
      for (const sessionKey of this.#subscribedSessions) {
        this.#gateway.subscribe(sessionKey).catch((err) => {
          this.#logger?.error("Resubscribe failed", {
            sessionKey,
            error: err.message,
          });
        });
      }
    });
  }

  #wirePhoneEvents() {
    this.#phone.on("phone-connected", () => {
      this.#logger?.info("Phone connected, replaying buffer", {
        bufferStats: this.#buffer.stats(),
      });

      // Replay all buffered events from all channels.
      const allEvents = this.#buffer.peekAll();
      for (const frame of allEvents) {
        this.#phone.sendEvent(frame);
      }

      this.#logger?.info("Buffer replay complete", {
        replayedEvents: allEvents.length,
      });
    });

    this.#phone.on("phone-disconnected", () => {
      this.#logger?.info("Phone disconnected, continuing to buffer");
    });

    this.#phone.on("phone-request", (frame) => {
      this.#handlePhoneRequest(frame);
    });
  }

  #handlePhoneRequest(frame) {
    // Check if this is a subscribe request — track it and subscribe on gateway.
    if (frame.method === "sessions.messages.subscribe") {
      const sessionKey = frame.params?.key;
      if (sessionKey && !this.#subscribedSessions.has(sessionKey)) {
        this.#subscribedSessions.add(sessionKey);
        this.#logger?.info("Tracking new session subscription", { sessionKey });

        // Subscribe on gateway side.
        this.#gateway.subscribe(sessionKey).catch((err) => {
          this.#logger?.error("Gateway subscribe failed", {
            sessionKey,
            error: err.message,
          });
        });
      }

      // Also replay buffer for this specific session.
      const buffered = this.#buffer.peek(sessionKey);
      if (buffered.length > 0) {
        this.#logger?.info("Replaying buffered events for session", {
          sessionKey,
          count: buffered.length,
        });
        for (const event of buffered) {
          this.#phone.sendEvent(event);
        }
      }
    }

    // Forward all requests to gateway.
    if (!this.#gateway.connected) {
      this.#phone.sendResponse(frame.id, false, {
        code: "SIDECAR_GATEWAY_UNAVAILABLE",
        message: "Sidecar is not connected to gateway, retrying...",
        retryable: true,
        retryAfterMs: 2000,
      });
      return;
    }

    const forwarded = this.#gateway.forwardRequest(frame);
    if (forwarded === null) {
      this.#phone.sendResponse(frame.id, false, {
        code: "SIDECAR_GATEWAY_UNAVAILABLE",
        message: "Sidecar lost gateway connection during forward",
        retryable: true,
        retryAfterMs: 2000,
      });
    }
  }

  async run() {
    return new Promise((resolve) => {
      const shutdown = () => {
        this.#logger?.info("Shutting down sidecar");
        this.#phone?.close();
        this.#gateway?.close();
        resolve();
      };

      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);
    });
  }
}
