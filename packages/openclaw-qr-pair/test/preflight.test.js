import test from "node:test";
import assert from "node:assert/strict";

import { PreflightError, runPreflight } from "../src/preflight.js";

function makeProbe({
  tailscaleMode = "serve",
  tailnetIPv4 = "100.75.48.35",
  port = 18789,
  configPath = "/tmp/openclaw.json",
} = {}) {
  return {
    network: tailnetIPv4 ? { tailnetIPv4 } : {},
    targets: [
      {
        config: {
          path: configPath,
          gateway: {
            mode: "local",
            bind: "loopback",
            port,
            tailscaleMode,
          },
        },
      },
    ],
  };
}

function makeOpenclaw({ installed = true, probe } = {}) {
  return {
    async checkInstalled() {
      if (!installed) {
        throw new Error("openclaw not found");
      }
    },
    async probeGateway() {
      if (!probe) {
        throw new Error("gateway unreachable");
      }
      return probe;
    },
  };
}

function makeDeps(overrides = {}) {
  const warnings = [];
  return {
    warnings,
    deps: {
      async readFile() {
        return "{}";
      },
      warn(message) {
        warnings.push(message);
      },
      async runCommand(cmd, args) {
        if (cmd === "tailscale" && args?.[0] === "version") {
          return "1.0.0";
        }
        throw new Error(`unexpected command in test: ${cmd}`);
      },
      ...overrides,
    },
  };
}

test("throws when openclaw CLI is missing", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    runPreflight({
      openclaw: makeOpenclaw({ installed: false }),
      options: { url: null },
      deps,
    }),
    (error) => error instanceof PreflightError && /openclaw CLI was not found/.test(error.message),
  );
});

test("throws when gateway probe fails", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    runPreflight({
      openclaw: makeOpenclaw({ probe: null }),
      options: { url: null },
      deps,
    }),
    (error) =>
      error instanceof PreflightError && /Could not reach the OpenClaw gateway/.test(error.message),
  );
});

test("throws when probe reports no tailnet IPv4", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    runPreflight({
      openclaw: makeOpenclaw({ probe: makeProbe({ tailnetIPv4: null }) }),
      options: { url: null },
      deps,
    }),
    (error) =>
      error instanceof PreflightError && /Tailscale does not appear to be running/.test(error.message),
  );
});

test("throws when gateway is not in tailscale serve mode", async () => {
  const { deps } = makeDeps();
  await assert.rejects(
    runPreflight({
      openclaw: makeOpenclaw({ probe: makeProbe({ tailscaleMode: null }) }),
      options: { url: null },
      deps,
    }),
    (error) =>
      error instanceof PreflightError &&
      /not running in tailscale serve mode/.test(error.message),
  );
});

test("warns (does not throw) when trustedProxies is missing loopback", async () => {
  const configJson = JSON.stringify({ gateway: { tailscaleMode: "serve", trustedProxies: [] } });
  const { deps, warnings } = makeDeps({
    async readFile() {
      return configJson;
    },
  });

  const result = await runPreflight({
    openclaw: makeOpenclaw({ probe: makeProbe() }),
    options: { url: null },
    deps,
  });

  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /does not include loopback/);
  assert.ok(result.probe);
});

test("does not warn when trustedProxies includes loopback", async () => {
  const configJson = JSON.stringify({
    gateway: { tailscaleMode: "serve", trustedProxies: ["127.0.0.1", "::1"] },
  });
  const { deps, warnings } = makeDeps({
    async readFile() {
      return configJson;
    },
  });

  await runPreflight({
    openclaw: makeOpenclaw({ probe: makeProbe() }),
    options: { url: null },
    deps,
  });

  assert.equal(warnings.length, 0);
});

test("skips trustedProxies check when tailscaleMode is not serve (via --url override)", async () => {
  const { deps, warnings } = makeDeps({
    async readFile() {
      throw new Error("readFile should not be called");
    },
  });

  await runPreflight({
    openclaw: makeOpenclaw({ probe: makeProbe({ tailscaleMode: null, tailnetIPv4: null }) }),
    options: { url: "wss://gateway.example/ws" },
    deps,
  });

  assert.equal(warnings.length, 0);
});

test("skips tailscale-up and serve-mode checks when --url is provided", async () => {
  const { deps } = makeDeps();

  const result = await runPreflight({
    openclaw: makeOpenclaw({ probe: makeProbe({ tailscaleMode: null, tailnetIPv4: null }) }),
    options: { url: "wss://gateway.example/ws" },
    deps,
  });

  assert.ok(result.probe);
});

test("returns resolved tailscale binary path on success", async () => {
  const { deps } = makeDeps();
  const result = await runPreflight({
    openclaw: makeOpenclaw({ probe: makeProbe() }),
    options: { url: null },
    deps,
  });
  assert.equal(result.tailscaleBin, "tailscale");
});

test("throws when tailscale binary cannot be resolved anywhere", async () => {
  const { deps } = makeDeps({
    async runCommand() {
      throw new Error("not found");
    },
  });
  await assert.rejects(
    runPreflight({
      openclaw: makeOpenclaw({ probe: makeProbe() }),
      options: { url: null },
      deps,
    }),
    (error) =>
      error instanceof PreflightError && /Could not locate the tailscale binary/.test(error.message),
  );
});

test("does not check tailscale binary when --url override is set", async () => {
  let runCommandCalls = 0;
  const { deps } = makeDeps({
    async runCommand() {
      runCommandCalls += 1;
      throw new Error("should not be called");
    },
  });
  const result = await runPreflight({
    openclaw: makeOpenclaw({ probe: makeProbe({ tailscaleMode: null, tailnetIPv4: null }) }),
    options: { url: "wss://gateway.example/ws" },
    deps,
  });
  assert.equal(runCommandCalls, 0);
  assert.equal(result.tailscaleBin, null);
});
