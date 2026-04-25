import test from "node:test";
import assert from "node:assert/strict";

import {
  formatRelativeAge,
  parseDuration,
  selectPrunableDevices,
} from "../src/prune.js";
import { parsePruneArgs } from "../src/prune-args.js";

const NOW = 1_777_000_000_000;
const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

function makeDevice({ id, role = "node", lastUsed = null, created = null, platform = "ios" }) {
  const tokens = [];
  if (lastUsed !== null) {
    tokens.push({ role: "node", lastUsedAtMs: lastUsed, createdAtMs: created ?? lastUsed });
  } else if (created !== null) {
    tokens.push({ role: "node", lastUsedAtMs: 0, createdAtMs: created });
  }
  return {
    deviceId: id,
    role,
    roles: [role],
    platform,
    approvedAtMs: created ?? NOW,
    createdAtMs: created ?? NOW,
    tokens,
  };
}

test("parseDuration understands s/m/h/d", () => {
  assert.equal(parseDuration("30s"), 30_000);
  assert.equal(parseDuration("15m"), 15 * MINUTE);
  assert.equal(parseDuration("6h"), 6 * HOUR);
  assert.equal(parseDuration("7d"), 7 * DAY);
});

test("parseDuration rejects malformed inputs", () => {
  assert.throws(() => parseDuration("abc"));
  assert.throws(() => parseDuration("10"));
  assert.throws(() => parseDuration("10x"));
});

test("formatRelativeAge handles edge cases", () => {
  assert.equal(formatRelativeAge(null), "never");
  assert.equal(formatRelativeAge(0), "just now");
  assert.equal(formatRelativeAge(5 * MINUTE), "5m ago");
  assert.equal(formatRelativeAge(2 * HOUR), "2h ago");
  assert.equal(formatRelativeAge(3 * DAY), "3d ago");
});

test("selectPrunableDevices selects node devices when no filter is set", () => {
  const snapshot = {
    paired: [
      makeDevice({ id: "a", role: "node", lastUsed: NOW - 2 * DAY }),
      makeDevice({ id: "b", role: "agent", lastUsed: NOW - 2 * DAY }),
    ],
  };
  const result = selectPrunableDevices({ snapshot, nowMs: NOW });
  assert.deepEqual(result.map((entry) => entry.deviceId), ["a"]);
});

test("selectPrunableDevices includes non-node roles with allRoles", () => {
  const snapshot = {
    paired: [
      makeDevice({ id: "a", role: "node" }),
      makeDevice({ id: "b", role: "agent" }),
    ],
  };
  const result = selectPrunableDevices({
    snapshot,
    nowMs: NOW,
    restrictToNodeRole: false,
  });
  assert.deepEqual(result.map((entry) => entry.deviceId).sort(), ["a", "b"]);
});

test("selectPrunableDevices filters by staleness based on lastUsedAtMs", () => {
  const snapshot = {
    paired: [
      makeDevice({ id: "stale", role: "node", lastUsed: NOW - 10 * DAY }),
      makeDevice({ id: "fresh", role: "node", lastUsed: NOW - 1 * HOUR }),
    ],
  };
  const result = selectPrunableDevices({
    snapshot,
    nowMs: NOW,
    olderThanMs: 7 * DAY,
  });
  assert.deepEqual(result.map((entry) => entry.deviceId), ["stale"]);
});

test("selectPrunableDevices falls back to createdAtMs when never used", () => {
  const snapshot = {
    paired: [
      makeDevice({ id: "never-connected", role: "node", lastUsed: null, created: NOW - 30 * DAY }),
    ],
  };
  const result = selectPrunableDevices({
    snapshot,
    nowMs: NOW,
    olderThanMs: 7 * DAY,
  });
  assert.deepEqual(result.map((entry) => entry.deviceId), ["never-connected"]);
});

test("selectPrunableDevices matches a single device by id", () => {
  const snapshot = {
    paired: [
      makeDevice({ id: "a", role: "node" }),
      makeDevice({ id: "b", role: "node" }),
    ],
  };
  const result = selectPrunableDevices({
    snapshot,
    nowMs: NOW,
    deviceId: "b",
  });
  assert.deepEqual(result.map((entry) => entry.deviceId), ["b"]);
});

test("selectPrunableDevices takes latest lastUsed across multiple tokens", () => {
  const device = {
    deviceId: "multi",
    role: "node",
    approvedAtMs: NOW - 30 * DAY,
    createdAtMs: NOW - 30 * DAY,
    tokens: [
      { role: "node", lastUsedAtMs: NOW - 20 * DAY },
      { role: "node", lastUsedAtMs: NOW - 1 * DAY },
    ],
  };

  const result = selectPrunableDevices({
    snapshot: { paired: [device] },
    nowMs: NOW,
    olderThanMs: 7 * DAY,
  });
  assert.equal(result.length, 0);
});

test("parsePruneArgs accepts flags in any order", () => {
  const options = parsePruneArgs(["--stale-for", "7d", "--dry-run"]);
  assert.equal(options.staleForMs, 7 * DAY);
  assert.equal(options.dryRun, true);
  assert.equal(options.yes, false);
});

test("parsePruneArgs short and long yes flags", () => {
  assert.equal(parsePruneArgs(["-y"]).yes, true);
  assert.equal(parsePruneArgs(["--yes"]).yes, true);
});

test("parsePruneArgs rejects --id with --stale-for", () => {
  assert.throws(
    () => parsePruneArgs(["--id", "abc", "--stale-for", "1d"]),
    /--id and --stale-for cannot be used together/,
  );
});

test("parsePruneArgs rejects unknown flag", () => {
  assert.throws(() => parsePruneArgs(["--nuke"]), /Unknown argument: --nuke/);
});
