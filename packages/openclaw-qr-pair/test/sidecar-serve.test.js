import test from "node:test";
import assert from "node:assert/strict";

import {
  TailscaleServeManager,
  resolveTailscaleBin,
} from "../src/sidecar-serve.js";

function makeRunCommand({ accept = [], reject = [], record = [] }) {
  return async (cmd, args) => {
    record.push({ cmd, args });
    if (reject.includes(cmd)) {
      throw new Error(`mocked failure for ${cmd}`);
    }
    if (accept.includes(cmd)) {
      return "{}";
    }
    throw new Error(`unexpected command: ${cmd}`);
  };
}

test("resolveTailscaleBin returns 'tailscale' when on PATH", async () => {
  const record = [];
  const bin = await resolveTailscaleBin({
    deps: { runCommand: makeRunCommand({ accept: ["tailscale"], record }) },
  });
  assert.equal(bin, "tailscale");
  assert.equal(record.length, 1);
  assert.deepEqual(record[0], { cmd: "tailscale", args: ["version"] });
});

test("resolveTailscaleBin falls back to macOS app path when PATH lookup fails", async () => {
  const record = [];
  const bin = await resolveTailscaleBin({
    deps: {
      runCommand: makeRunCommand({
        accept: ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"],
        reject: ["tailscale"],
        record,
      }),
    },
  });
  assert.equal(bin, "/Applications/Tailscale.app/Contents/MacOS/Tailscale");
});

test("resolveTailscaleBin returns null when nothing is found", async () => {
  const record = [];
  const bin = await resolveTailscaleBin({
    deps: {
      async runCommand(cmd, args) {
        record.push({ cmd, args });
        throw new Error("not found");
      },
    },
  });
  assert.equal(bin, null);
  assert.equal(record.length, 4); // 1 PATH + 3 fallback paths
});

test("TailscaleServeManager.captureCurrent stores parsed JSON", async () => {
  const calls = [];
  const deps = {
    async runCommand(cmd, args) {
      calls.push({ cmd, args });
      return JSON.stringify({ Web: { "foo:443": {} } });
    },
  };
  const manager = new TailscaleServeManager({
    bin: "tailscale",
    gatewayPort: 18789,
    sidecarPort: 18790,
    deps,
  });
  const captured = await manager.captureCurrent();
  assert.deepEqual(captured, { Web: { "foo:443": {} } });
  assert.deepEqual(calls[0], { cmd: "tailscale", args: ["serve", "status", "--json"] });
});

test("TailscaleServeManager.pointAtSidecar runs reset then serve at sidecar port", async () => {
  const calls = [];
  const deps = {
    async runCommand(cmd, args) {
      calls.push({ cmd, args });
      return "";
    },
  };
  const manager = new TailscaleServeManager({
    bin: "tailscale",
    gatewayPort: 18789,
    sidecarPort: 18790,
    deps,
  });
  await manager.pointAtSidecar();
  assert.deepEqual(
    calls.map((entry) => entry.args.join(" ")),
    ["serve reset", "serve --bg --https=443 http://127.0.0.1:18790"],
  );
});

test("TailscaleServeManager.restoreToGateway is no-op when never repointed", async () => {
  const calls = [];
  const deps = {
    async runCommand(cmd, args) {
      calls.push({ cmd, args });
      return "";
    },
  };
  const manager = new TailscaleServeManager({
    bin: "tailscale",
    gatewayPort: 18789,
    sidecarPort: 18790,
    deps,
  });
  await manager.restoreToGateway();
  assert.equal(calls.length, 0);
});

test("TailscaleServeManager.restoreToGateway routes back to gateway port after pointAtSidecar", async () => {
  const calls = [];
  const deps = {
    async runCommand(cmd, args) {
      calls.push({ cmd, args });
      return "";
    },
  };
  const manager = new TailscaleServeManager({
    bin: "tailscale",
    gatewayPort: 18789,
    sidecarPort: 18790,
    deps,
  });
  await manager.pointAtSidecar();
  await manager.restoreToGateway();
  assert.deepEqual(
    calls.map((entry) => entry.args.join(" ")),
    [
      "serve reset",
      "serve --bg --https=443 http://127.0.0.1:18790",
      "serve reset",
      "serve --bg --https=443 http://127.0.0.1:18789",
    ],
  );
});

test("TailscaleServeManager.restoreToGateway is idempotent", async () => {
  const calls = [];
  const deps = {
    async runCommand(cmd, args) {
      calls.push({ cmd, args });
      return "";
    },
  };
  const manager = new TailscaleServeManager({
    bin: "tailscale",
    gatewayPort: 18789,
    sidecarPort: 18790,
    deps,
  });
  await manager.pointAtSidecar();
  await manager.restoreToGateway();
  const callCountAfterFirst = calls.length;
  await manager.restoreToGateway();
  assert.equal(calls.length, callCountAfterFirst, "second restore should not run any commands");
});
