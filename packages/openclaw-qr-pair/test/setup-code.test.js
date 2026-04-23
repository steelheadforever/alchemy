import test from "node:test";
import assert from "node:assert/strict";

import { decodeSetupCode, encodeSetupCode } from "../src/setup-code.js";

test("round-trips a setup code payload", () => {
  const encoded = encodeSetupCode({
    url: "wss://gateway.example/ws",
    bootstrapToken: "secret-token",
  });

  assert.deepEqual(decodeSetupCode(encoded), {
    url: "wss://gateway.example/ws",
    bootstrapToken: "secret-token",
  });
});

test("accepts raw json for debugging", () => {
  const decoded = decodeSetupCode('{"url":"ws://127.0.0.1:18789","bootstrapToken":"abc"}');

  assert.deepEqual(decoded, {
    url: "ws://127.0.0.1:18789",
    bootstrapToken: "abc",
  });
});

test("falls back to legacy token key", () => {
  const payload = Buffer.from('{"url":"ws://127.0.0.1:18789","token":"legacy"}', "utf8").toString("base64");

  assert.deepEqual(decodeSetupCode(payload), {
    url: "ws://127.0.0.1:18789",
    bootstrapToken: "legacy",
  });
});

