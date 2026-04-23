import test from "node:test";
import assert from "node:assert/strict";

import {
  detectNodePairingChanges,
  getDeviceId,
  getRequestId,
} from "../src/pending-requests.js";

test("filters only new node requests after startup", () => {
  const baseline = {
    pending: [{ requestId: "existing", role: "node", createdAt: 10 }],
  };

  const current = {
    pending: [
      { requestId: "existing", role: "node", createdAt: 10 },
      { requestId: "fresh-node", role: "node", createdAt: 2000 },
      { requestId: "fresh-operator", role: "operator", createdAt: 2000 },
    ],
  };

  const result = detectNodePairingChanges({
    baseline,
    current,
    sinceMs: 1000,
  });

  assert.equal(result.pending.length, 1);
  assert.equal(getRequestId(result.pending[0]), "fresh-node");
  assert.equal(result.paired.length, 0);
});

test("detects a silently paired node device", () => {
  const baseline = {
    paired: [{ deviceId: "existing", publicKey: "aaa", role: "node" }],
  };

  const current = {
    paired: [
      { deviceId: "existing", publicKey: "aaa", role: "node" },
      { deviceId: "fresh-device", publicKey: "bbb", role: "node" },
    ],
  };

  const result = detectNodePairingChanges({
    baseline,
    current,
    sinceMs: Date.now(),
  });

  assert.equal(result.pending.length, 0);
  assert.equal(result.paired.length, 1);
  assert.equal(getDeviceId(result.paired[0]), "fresh-device");
});
