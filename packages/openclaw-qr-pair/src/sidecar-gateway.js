import { EventEmitter } from "node:events";
import crypto from "node:crypto";
import WebSocket from "ws";
import {
  computeDeviceID,
  buildSignaturePayloadV3,
  sign,
  publicKeyBase64URL,
  saveIdentity,
} from "./sidecar-identity.js";

const CLIENT_DESCRIPTOR = {
  id: "openclaw-ios",
  version: "0.1.0",
  platform: "ios",
  deviceFamily: "phone",
};

const OPERATOR_SCOPES = [
  "operator.approvals",
  "operator.read",
  "operator.talk.secrets",
  "operator.write",
];

const RECONNECT_BASE_MS = 1000;
const RECONNECT_MAX_MS = 16000;

export class GatewayConnection extends EventEmitter {
  #gatewayUrl;
  #identity;
  #bootstrapToken;
  #logger;
  #ws = null;
  #connectResolve = null;
  #connectReject = null;
  #pendingRequests = new Map();
  #nextRequestId = 1;
  #forwardMap = new Map(); // sidecar request ID → phone request ID
  #reconnectAttempt = 0;
  #reconnectTimer = null;
  #intentionalClose = false;
  #hello = null;
  #connectGeneration = 0; // Incremented on each connect to prevent stale close handlers.

  constructor({ gatewayUrl, identity, bootstrapToken, logger }) {
    super();
    this.#gatewayUrl = gatewayUrl;
    this.#identity = identity;
    this.#bootstrapToken = bootstrapToken;
    this.#logger = logger;
  }

  get hello() {
    return this.#hello;
  }

  get connected() {
    return this.#ws?.readyState === WebSocket.OPEN && this.#hello !== null;
  }

  async connect() {
    // Two-phase connect, mirroring the iOS GatewayClient flow:
    //   Phase 1: connect as node with bootstrapToken → receive device tokens for both roles
    //   Phase 2: reconnect as operator with operator device token → full access
    //
    // On reconnect (after initial pairing), skip phase 1 and use stored operator token.

    if (this.#identity.operatorToken) {
      // Fast path: reconnect as operator with stored token.
      this.#logger?.info("Gateway connect: reconnecting as operator with stored token");
      try {
        return await this.#connectAsOperator(this.#identity.operatorToken, "token");
      } catch (err) {
        // Stale token — clear it and fall through to full two-phase bootstrap.
        this.#logger?.warn("Stored operator token rejected, falling back to bootstrap", {
          error: err.message,
        });
        this.#identity.operatorToken = null;
        this.#identity.deviceToken = null;
        saveIdentity(undefined, this.#identity);
      }
    }

    // Phase 1: bootstrap as node to get device tokens.
    const useStoredNodeToken = Boolean(this.#identity.deviceToken);
    const nodeAuthField = useStoredNodeToken ? "deviceToken" : "bootstrapToken";
    const nodeAuthValue = useStoredNodeToken ? this.#identity.deviceToken : this.#bootstrapToken;
    this.#logger?.info("Gateway connect: phase 1 — connecting as node", {
      auth: nodeAuthField,
    });

    const nodeHello = await this.#connectWithRole({
      role: "node",
      mode: "node",
      scopes: [],
      authField: nodeAuthField,
      authValue: nodeAuthValue,
    });

    // Extract and persist tokens for both roles.
    const nodeToken = this.#extractDeviceToken(nodeHello, "node");
    const operatorToken = this.#extractDeviceToken(nodeHello, "operator");
    this.#logger?.info("Phase 1 complete, extracted tokens", {
      hasNodeToken: Boolean(nodeToken),
      hasOperatorToken: Boolean(operatorToken),
    });

    if (nodeToken && nodeToken !== this.#identity.deviceToken) {
      this.#identity.deviceToken = nodeToken;
    }
    if (operatorToken) {
      this.#identity.operatorToken = operatorToken;
    }
    saveIdentity(undefined, this.#identity);

    if (!operatorToken) {
      // Fallback: if no operator token issued, stay connected as node.
      this.#logger?.warn("No operator token issued by gateway; staying as node");
      this.#hello = nodeHello;
      this.#reconnectAttempt = 0;
      this.emit("connected", nodeHello);
      return nodeHello;
    }

    // Phase 2: disconnect node, reconnect as operator.
    this.#logger?.info("Gateway connect: phase 2 — disconnecting node, reconnecting as operator");
    this.#closeWs();

    return this.#connectAsOperator(operatorToken, "token");
  }

  async #connectAsOperator(token, authField) {
    const hello = await this.#connectWithRole({
      role: "operator",
      mode: "node",
      scopes: OPERATOR_SCOPES,
      authField,
      authValue: token,
    });

    // Update stored operator token if gateway issued a new one.
    const freshToken = this.#extractDeviceToken(hello, "operator");
    if (freshToken && freshToken !== this.#identity.operatorToken) {
      this.#identity.operatorToken = freshToken;
      saveIdentity(undefined, this.#identity);
      this.#logger?.info("Updated stored operator token");
    }

    this.#hello = hello;
    this.#reconnectAttempt = 0;
    this.emit("connected", hello);
    this.#logger?.info("Gateway operator connection established", {
      connectionID: hello?.server?.connId,
    });
    return hello;
  }

  #connectWithRole({ role, mode, scopes, authField, authValue, clientIdOverride }) {
    const generation = ++this.#connectGeneration;

    return new Promise((resolve, reject) => {
      this.#connectResolve = resolve;
      this.#connectReject = reject;
      this.#intentionalClose = false;

      this.#ws = new WebSocket(this.#gatewayUrl);

      this.#ws.on("open", () => {
        this.#logger?.info("WebSocket open to gateway");
      });

      this.#ws.on("message", (data) => {
        if (generation !== this.#connectGeneration) return;
        try {
          const frame = JSON.parse(data.toString());
          this.#handleFrame(frame, { role, mode, scopes, authField, authValue, clientIdOverride });
        } catch (err) {
          this.#logger?.error("Failed to parse gateway frame", { error: err.message });
        }
      });

      this.#ws.on("close", (code, reason) => {
        if (generation !== this.#connectGeneration) return; // Stale handler from previous phase.
        this.#logger?.info("Gateway WebSocket closed", { code, reason: reason?.toString() });
        if (this.#connectReject) {
          this.#connectReject(new Error(`Gateway WebSocket closed during handshake: ${code}`));
          this.#connectResolve = null;
          this.#connectReject = null;
        }
        this.#failPendingRequests("Gateway disconnected");
        if (!this.#intentionalClose && this.#hello) {
          this.#hello = null;
          this.emit("disconnected");
        }
      });

      this.#ws.on("error", (err) => {
        if (generation !== this.#connectGeneration) return;
        this.#logger?.error("Gateway WebSocket error", { error: err.message });
        if (this.#connectReject) {
          this.#connectReject(err);
          this.#connectResolve = null;
          this.#connectReject = null;
        }
        this.emit("error", err);
      });
    });
  }

  #handleFrame(frame, connectParams) {
    const type = frame.type;

    if (type === "event") {
      if (frame.event === "connect.challenge") {
        const nonce = frame.payload?.nonce;
        if (!nonce) {
          this.#logger?.error("Challenge missing nonce");
          return;
        }
        this.#sendConnectRequest(nonce, connectParams);
        return;
      }

      // Forward session events.
      this.emit("event", frame);
      return;
    }

    if (type === "res") {
      this.#handleResponse(frame);
      return;
    }
  }

  #sendConnectRequest(nonce, { role, mode, scopes, authField, authValue, clientIdOverride }) {
    const clientId = clientIdOverride ?? CLIENT_DESCRIPTOR.id;
    const deviceID = computeDeviceID(this.#identity.publicKey);
    const signedAtMilliseconds = Date.now();
    const signaturePayload = buildSignaturePayloadV3({
      deviceID,
      clientID: clientId,
      clientMode: mode,
      role,
      scopes,
      signedAtMilliseconds,
      token: authValue,
      nonce,
      platform: CLIENT_DESCRIPTOR.platform,
      deviceFamily: CLIENT_DESCRIPTOR.deviceFamily,
    });

    const signature = sign(this.#identity.seed, signaturePayload);
    const pubKeyB64 = publicKeyBase64URL(this.#identity.publicKey);

    const requestID = crypto.randomUUID();

    const connectFrame = {
      type: "req",
      id: requestID,
      method: "connect",
      params: {
        minProtocol: 3,
        maxProtocol: 3,
        client: {
          id: clientId,
          version: CLIENT_DESCRIPTOR.version,
          platform: CLIENT_DESCRIPTOR.platform,
          mode,
          deviceFamily: CLIENT_DESCRIPTOR.deviceFamily,
        },
        role,
        scopes,
        caps: [],
        device: {
          id: deviceID,
          publicKey: pubKeyB64,
          signature,
          signedAt: signedAtMilliseconds,
          nonce,
        },
        auth: {
          [authField]: authValue,
        },
      },
    };

    this.#connectRequestId = requestID;
    this.#send(connectFrame);
  }

  #connectRequestId = null;

  #handleResponse(frame) {
    const id = frame.id;
    const ok = frame.ok ?? false;

    // Connect response.
    if (id === this.#connectRequestId) {
      this.#connectRequestId = null;
      if (ok) {
        this.#connectResolve?.(frame.payload);
        this.#connectResolve = null;
        this.#connectReject = null;
      } else {
        const errMsg = frame.error?.message ?? "Gateway connect failed";
        this.#connectReject?.(new Error(errMsg));
        this.#connectResolve = null;
        this.#connectReject = null;
      }
      return;
    }

    // Forwarded request response.
    const pending = this.#pendingRequests.get(id);
    if (pending) {
      this.#pendingRequests.delete(id);
      pending.resolve(frame);
      return;
    }

    // Check if it's a forwarded phone request.
    const phoneRequestId = this.#forwardMap.get(id);
    if (phoneRequestId !== undefined) {
      this.#forwardMap.delete(id);
      // Rewrite ID back to phone's original.
      const rewritten = { ...frame, id: phoneRequestId };
      this.emit("forwarded-response", rewritten);
      return;
    }
  }

  async request(method, params) {
    if (!this.connected) {
      throw new Error("Not connected to gateway");
    }

    const id = `sidecar-${this.#nextRequestId++}`;
    const frame = { type: "req", id, method, params };

    return new Promise((resolve, reject) => {
      this.#pendingRequests.set(id, { resolve, reject });
      this.#send(frame);
    });
  }

  async subscribe(sessionKey) {
    return this.request("sessions.messages.subscribe", { key: sessionKey });
  }

  forwardRequest(phoneFrame) {
    if (!this.connected) {
      return null; // Caller should send error to phone.
    }

    const phoneRequestId = phoneFrame.id;
    const sidecarId = `fwd-${this.#nextRequestId++}`;

    this.#forwardMap.set(sidecarId, phoneRequestId);
    const rewritten = { ...phoneFrame, id: sidecarId };
    this.#send(rewritten);
    return sidecarId;
  }

  async reconnect() {
    if (this.#reconnectTimer) return;
    if (!this.#identity.operatorToken && !this.#identity.deviceToken && !this.#bootstrapToken) {
      this.#logger?.error("Cannot reconnect: no stored tokens or bootstrap token");
      return;
    }

    const delay = Math.min(
      RECONNECT_BASE_MS * 2 ** this.#reconnectAttempt,
      RECONNECT_MAX_MS,
    );
    this.#reconnectAttempt++;

    this.#logger?.info("Reconnecting to gateway", {
      attempt: this.#reconnectAttempt,
      delayMs: delay,
    });

    await new Promise((resolve) => {
      this.#reconnectTimer = setTimeout(resolve, delay);
    });
    this.#reconnectTimer = null;

    try {
      await this.connect();
    } catch (err) {
      this.#logger?.error("Reconnect failed", { error: err.message });
      // If operator token was rejected, clear it and retry from bootstrap.
      if (this.#identity.operatorToken) {
        this.#logger?.info("Clearing stored operator token, will retry from bootstrap");
        this.#identity.operatorToken = null;
        saveIdentity(undefined, this.#identity);
      }
      this.emit("error", err);
      this.reconnect();
    }
  }

  close() {
    this.#intentionalClose = true;
    clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = null;
    this.#closeWs();
  }

  #closeWs() {
    if (this.#ws) {
      this.#intentionalClose = true;
      try {
        this.#ws.close(1000);
      } catch {
        // Ignore close errors.
      }
      this.#ws = null;
    }
  }

  #send(frame) {
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#ws.send(JSON.stringify(frame));
    }
  }

  #failPendingRequests(reason) {
    for (const [id, pending] of this.#pendingRequests) {
      pending.reject(new Error(reason));
    }
    this.#pendingRequests.clear();
    this.#forwardMap.clear();
  }

  #extractDeviceToken(helloPayload, targetRole) {
    const auth = helloPayload?.auth;
    if (!auth) return null;

    // Prefer a token explicitly issued for the target role.
    if (auth.role === targetRole && auth.deviceToken) {
      return auth.deviceToken;
    }
    const tokens = Array.isArray(auth.deviceTokens) ? auth.deviceTokens : [];
    for (const t of tokens) {
      if (t.role === targetRole && t.deviceToken) {
        return t.deviceToken;
      }
    }

    // Fallback: openclaw appears to issue a single device token per device,
    // not per role. Use whichever token is present; the gateway will enforce
    // role and scopes on the next connect.
    if (auth.deviceToken) {
      return auth.deviceToken;
    }
    for (const t of tokens) {
      if (t.deviceToken) {
        return t.deviceToken;
      }
    }

    return null;
  }
}

function shapeOf(value, depth = 0) {
  if (depth > 3 || value === null || value === undefined) {
    return value === undefined ? "undefined" : value === null ? "null" : "...";
  }
  if (Array.isArray(value)) {
    return value.length === 0 ? "array(empty)" : `array[${value.length}](${shapeOf(value[0], depth + 1)})`;
  }
  if (typeof value === "object") {
    const out = {};
    for (const key of Object.keys(value)) {
      out[key] = shapeOf(value[key], depth + 1);
    }
    return out;
  }
  return typeof value;
}
