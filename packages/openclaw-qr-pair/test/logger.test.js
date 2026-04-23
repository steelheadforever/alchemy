import test from "node:test";
import assert from "node:assert/strict";

import { DiagnosticLogger, redactSecrets } from "../src/logger.js";

test("redacts token-like diagnostic fields", () => {
  const redacted = redactSecrets({
    url: "wss://gateway.example/ws",
    bootstrapToken: "bootstrap-secret-token",
    nested: {
      deviceToken: "device-secret-token",
    },
  });

  assert.equal(redacted.url, "wss://gateway.example/ws");
  assert.equal(redacted.bootstrapToken, "boot...oken");
  assert.equal(redacted.nested.deviceToken, "devi...oken");
});

test("diagnostic logger writes enabled entries to stream", () => {
  let output = "";
  const stream = {
    write(value) {
      output += value;
    },
  };
  const logger = new DiagnosticLogger({ enabled: true, stream });

  logger.info("Setup code generated", {
    bootstrapToken: "bootstrap-secret-token",
  });

  assert.match(output, /INFO Setup code generated/);
  assert.doesNotMatch(output, /bootstrap-secret-token/);
  assert.match(output, /boot\.\.\.oken/);
});
