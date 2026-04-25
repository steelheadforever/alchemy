import test from "node:test";
import assert from "node:assert/strict";

import { pruneMain } from "../src/prune-main.js";

const NOW_ISH = Date.now();
const DAY = 86_400_000;
const HOUR = 3_600_000;

function makeSnapshot() {
  return {
    paired: [
      {
        deviceId: "stale-one",
        role: "node",
        approvedAtMs: NOW_ISH - 30 * DAY,
        createdAtMs: NOW_ISH - 30 * DAY,
        platform: "ios",
        tokens: [{ role: "node", lastUsedAtMs: NOW_ISH - 10 * DAY }],
      },
      {
        deviceId: "fresh-one",
        role: "node",
        approvedAtMs: NOW_ISH - 1 * DAY,
        createdAtMs: NOW_ISH - 1 * DAY,
        platform: "ios",
        tokens: [{ role: "node", lastUsedAtMs: NOW_ISH - 1 * HOUR }],
      },
      {
        deviceId: "agent-one",
        role: "agent",
        approvedAtMs: NOW_ISH - 30 * DAY,
        createdAtMs: NOW_ISH - 30 * DAY,
        tokens: [{ role: "agent", lastUsedAtMs: NOW_ISH - 30 * DAY }],
      },
    ],
  };
}

function makeMockEnv({ snapshot = makeSnapshot(), promptAnswer = "y" } = {}) {
  const calls = { removed: [] };
  const openclaw = {
    async checkInstalled() {},
    async listDevices() {
      return snapshot;
    },
    async removeDevice(deviceId) {
      calls.removed.push(deviceId);
      return { ok: true };
    },
  };
  const logs = [];
  const io = {
    log(message) {
      logs.push(message);
    },
    async prompt() {
      return promptAnswer;
    },
  };
  return { openclaw, io, logs, calls };
}

test("pruneMain dry-run does not remove devices", async () => {
  const { openclaw, io, logs, calls } = makeMockEnv();
  const result = await pruneMain(["--stale-for", "7d", "--dry-run"], { io, openclaw });

  assert.equal(result.skipped, true);
  assert.equal(calls.removed.length, 0);
  assert.ok(logs.some((line) => /Dry run/.test(line)));
});

test("pruneMain aborts when prompt is not confirmed", async () => {
  const { openclaw, io, logs, calls } = makeMockEnv({ promptAnswer: "n" });
  const result = await pruneMain(["--stale-for", "7d"], { io, openclaw });

  assert.equal(result.skipped, true);
  assert.equal(calls.removed.length, 0);
  assert.ok(logs.some((line) => /Aborted/.test(line)));
});

test("pruneMain removes stale node devices when confirmed", async () => {
  const { openclaw, io, calls } = makeMockEnv({ promptAnswer: "y" });
  const result = await pruneMain(["--stale-for", "7d"], { io, openclaw });

  assert.deepEqual(calls.removed, ["stale-one"]);
  assert.deepEqual(result.removed, ["stale-one"]);
  assert.deepEqual(result.failed, []);
});

test("pruneMain --yes skips the prompt", async () => {
  const { openclaw, io, calls } = makeMockEnv();
  let promptCalled = false;
  io.prompt = async () => {
    promptCalled = true;
    return "";
  };

  const result = await pruneMain(["--stale-for", "7d", "--yes"], { io, openclaw });

  assert.equal(promptCalled, false);
  assert.deepEqual(result.removed, ["stale-one"]);
});

test("pruneMain with no matches reports nothing to remove", async () => {
  const snapshot = { paired: [] };
  const { openclaw, io, logs } = makeMockEnv({ snapshot, promptAnswer: "y" });
  const result = await pruneMain(["--stale-for", "7d"], { io, openclaw });

  assert.equal(result.skipped, true);
  assert.ok(logs.some((line) => /Nothing to remove/.test(line)));
});

test("pruneMain --id targets a single device by id", async () => {
  const { openclaw, io, calls } = makeMockEnv();
  const result = await pruneMain(["--id", "fresh-one", "--yes"], { io, openclaw });

  assert.deepEqual(calls.removed, ["fresh-one"]);
  assert.deepEqual(result.removed, ["fresh-one"]);
});

test("pruneMain --all-roles includes non-node devices", async () => {
  const { openclaw, io, calls } = makeMockEnv();
  const result = await pruneMain(["--stale-for", "7d", "--all-roles", "--yes"], { io, openclaw });

  assert.deepEqual(calls.removed.sort(), ["agent-one", "stale-one"]);
  assert.deepEqual(result.failed, []);
});

test("pruneMain records failed removals without aborting", async () => {
  const { openclaw, io, logs } = makeMockEnv();
  let calls = 0;
  openclaw.removeDevice = async (deviceId) => {
    calls += 1;
    if (deviceId === "stale-one") throw new Error("boom");
    return { ok: true };
  };

  const result = await pruneMain(["--stale-for", "7d", "--all-roles", "--yes"], { io, openclaw });

  assert.equal(calls, 2);
  assert.deepEqual(result.removed, ["agent-one"]);
  assert.equal(result.failed.length, 1);
  assert.equal(result.failed[0].deviceId, "stale-one");
  assert.ok(logs.some((line) => /FAILED stale-one/.test(line)));
});
