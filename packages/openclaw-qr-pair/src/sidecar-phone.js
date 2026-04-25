import { EventEmitter } from "node:events";
import crypto from "node:crypto";
import { WebSocketServer } from "ws";

export class PhoneServer extends EventEmitter {
  #port;
  #bootstrapToken;
  #logger;
  #wss = null;
  #phone = null;
  #phoneConnected = false;

  constructor({ port, bootstrapToken, logger }) {
    super();
    this.#port = port;
    this.#bootstrapToken = bootstrapToken;
    this.#logger = logger;
  }

  get phoneConnected() {
    return this.#phoneConnected;
  }

  start() {
    return new Promise((resolve, reject) => {
      this.#wss = new WebSocketServer({ port: this.#port });

      this.#wss.on("listening", () => {
        this.#logger?.info("Phone server listening", { port: this.#port });
        resolve();
      });

      this.#wss.on("error", (err) => {
        this.#logger?.error("Phone server error", { error: err.message });
        reject(err);
      });

      this.#wss.on("connection", (ws) => {
        this.#handleNewConnection(ws);
      });
    });
  }

  #handleNewConnection(ws) {
    // One phone at a time — new connection replaces old.
    if (this.#phone) {
      this.#logger?.info("New phone connection replacing previous");
      try {
        this.#phone.close(1000, "Replaced by new connection");
      } catch {
        // Ignore.
      }
      this.#phoneConnected = false;
    }

    this.#phone = ws;
    this.#logger?.info("Phone connected, sending challenge");

    // Send connect.challenge to mimic gateway protocol.
    const nonce = crypto.randomBytes(32).toString("hex");
    this.#sendToWs(ws, {
      type: "event",
      event: "connect.challenge",
      payload: { nonce },
    });

    ws.on("message", (data) => {
      try {
        const frame = JSON.parse(data.toString());
        this.#handlePhoneFrame(ws, frame);
      } catch (err) {
        this.#logger?.error("Failed to parse phone frame", { error: err.message });
      }
    });

    ws.on("close", (code, reason) => {
      this.#logger?.info("Phone disconnected", { code, reason: reason?.toString() });
      if (this.#phone === ws) {
        this.#phone = null;
        this.#phoneConnected = false;
        this.emit("phone-disconnected");
      }
    });

    ws.on("error", (err) => {
      this.#logger?.error("Phone WebSocket error", { error: err.message });
    });
  }

  #handlePhoneFrame(ws, frame) {
    if (frame.type !== "req") return;

    if (frame.method === "connect") {
      this.#handleConnectRequest(ws, frame);
      return;
    }

    // All other requests are forwarded.
    this.emit("phone-request", frame);
  }

  #handleConnectRequest(ws, frame) {
    const auth = frame.params?.auth;
    const token =
      auth?.bootstrapToken ?? auth?.token ?? auth?.deviceToken;

    if (token !== this.#bootstrapToken) {
      this.#logger?.warn("Phone connect auth failed", {
        authKeys: Object.keys(auth || {}),
        receivedTokenPrefix: token ? token.slice(0, 8) + "..." : "<none>",
        expectedTokenPrefix: this.#bootstrapToken ? this.#bootstrapToken.slice(0, 8) + "..." : "<none>",
        role: frame.params?.role,
      });
      this.#sendToWs(ws, {
        type: "res",
        id: frame.id,
        ok: false,
        error: {
          code: "AUTH_FAILED",
          message: "Invalid bootstrap token",
        },
      });
      return;
    }

    const role = frame.params?.role ?? "operator";
    const scopes = frame.params?.scopes ?? ["operator.read", "operator.write", "operator.admin"];

    // Reply with hello, mimicking gateway protocol exactly.
    const hello = {
      protocol: 3,
      features: {
        methods: [
          "agents.list",
          "sessions.list",
          "sessions.create",
          "sessions.messages.subscribe",
          "sessions.send",
          "exec.approval.resolve",
          "plugin.approval.resolve",
        ],
        events: [
          "session.message",
          "agent",
          "chat",
          "session.tool",
          "exec.approval.requested",
          "exec.approval.resolved",
          "plugin.approval.requested",
          "plugin.approval.resolved",
        ],
      },
      server: {
        connId: crypto.randomUUID(),
      },
      auth: {
        deviceToken: this.#bootstrapToken,
        role,
        scopes,
        // Include tokens for both roles so iOS can store credentials for
        // its two-phase connect: node bootstrap → operator reconnect.
        deviceTokens: [
          {
            deviceToken: this.#bootstrapToken,
            role: "node",
            scopes: [],
          },
          {
            deviceToken: this.#bootstrapToken,
            role: "operator",
            scopes: [
              "operator.approvals",
              "operator.read",
              "operator.talk.secrets",
              "operator.write",
            ],
          },
        ],
      },
    };

    this.#sendToWs(ws, {
      type: "res",
      id: frame.id,
      ok: true,
      payload: hello,
    });

    this.#phoneConnected = true;
    this.#logger?.info("Phone authenticated", { role });
    this.emit("phone-connected", { role, scopes });
  }

  sendEvent(frame) {
    if (!this.#phone || !this.#phoneConnected) return false;
    this.#sendToWs(this.#phone, frame);
    return true;
  }

  sendResponse(id, ok, payload) {
    if (!this.#phone || !this.#phoneConnected) return false;
    const frame = { type: "res", id, ok };
    if (ok) {
      frame.payload = payload;
    } else {
      frame.error = payload;
    }
    this.#sendToWs(this.#phone, frame);
    return true;
  }

  sendToPhone(frame) {
    if (!this.#phone || !this.#phoneConnected) return false;
    this.#sendToWs(this.#phone, frame);
    return true;
  }

  close() {
    if (this.#phone) {
      try {
        this.#phone.close(1000);
      } catch {
        // Ignore.
      }
      this.#phone = null;
      this.#phoneConnected = false;
    }
    if (this.#wss) {
      this.#wss.close();
      this.#wss = null;
    }
  }

  #sendToWs(ws, frame) {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify(frame));
    }
  }
}
