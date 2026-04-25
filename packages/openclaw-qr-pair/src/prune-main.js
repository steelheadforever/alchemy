import readline from "node:readline/promises";

import { parsePruneArgs } from "./prune-args.js";
import { OpenClawCli } from "./openclaw-cli.js";
import { DiagnosticLogger } from "./logger.js";
import { formatRelativeAge, selectPrunableDevices } from "./prune.js";

export async function pruneMain(argv, { io = defaultIO, openclaw: injectedOpenclaw } = {}) {
  const options = parsePruneArgs(argv);
  const logger = new DiagnosticLogger({ enabled: options.verbose });
  const openclaw = injectedOpenclaw ?? new OpenClawCli({ logger });

  logger.info("Starting openclaw-node-prune", { options });

  await openclaw.checkInstalled();
  const snapshot = await openclaw.listDevices();
  const nowMs = Date.now();

  const candidates = selectPrunableDevices({
    snapshot,
    nowMs,
    olderThanMs: options.staleForMs,
    deviceId: options.deviceId,
    restrictToNodeRole: !options.allRoles,
  });

  io.log(describeSelection({ candidates, options }));

  if (candidates.length === 0) {
    io.log("Nothing to remove.");
    return { removed: [], failed: [], skipped: true };
  }

  printCandidateTable(candidates, nowMs, io);

  if (options.dryRun) {
    io.log("");
    io.log("Dry run: no devices were removed.");
    return { removed: [], failed: [], skipped: true };
  }

  if (!options.yes) {
    const answer = await io.prompt(`Remove ${candidates.length} device(s)? [y/N]: `);
    if (!/^y(es)?$/i.test(answer.trim())) {
      io.log("Aborted.");
      return { removed: [], failed: [], skipped: true };
    }
  }

  const removed = [];
  const failed = [];

  for (const entry of candidates) {
    try {
      logger.info("Removing device", { deviceId: entry.deviceId });
      await openclaw.removeDevice(entry.deviceId);
      removed.push(entry.deviceId);
      io.log(`  removed ${entry.deviceId}`);
    } catch (error) {
      failed.push({ deviceId: entry.deviceId, message: error.message });
      io.log(`  FAILED ${entry.deviceId}: ${error.message}`);
    }
  }

  io.log("");
  io.log(`Summary: ${removed.length} removed, ${failed.length} failed.`);
  return { removed, failed, skipped: false };
}

function describeSelection({ candidates, options }) {
  const filterDescription =
    options.deviceId
      ? `deviceId=${options.deviceId}`
      : options.staleForMs
        ? `stale-for=${formatDurationMs(options.staleForMs)}`
        : "no filter (all paired node devices)";
  const roleScope = options.allRoles ? "all roles" : "role=node";
  return `Matched ${candidates.length} device(s) (${roleScope}, ${filterDescription}):`;
}

function printCandidateTable(candidates, nowMs, io) {
  for (const entry of candidates) {
    const lastSeen =
      entry.lastUsedMs === null ? "never" : formatRelativeAge(nowMs - entry.lastUsedMs);
    const created =
      entry.createdMs === null ? "unknown" : formatRelativeAge(nowMs - entry.createdMs);
    const platform = entry.platform ? ` platform=${entry.platform}` : "";
    io.log(
      `  ${truncateId(entry.deviceId)} role=${entry.role ?? "?"}${platform} lastSeen=${lastSeen} created=${created}`,
    );
  }
}

function truncateId(deviceId) {
  if (deviceId.length <= 16) {
    return deviceId;
  }
  return `${deviceId.slice(0, 8)}...${deviceId.slice(-8)}`;
}

function formatDurationMs(ms) {
  const days = ms / 86_400_000;
  if (days >= 1) return `${days}d`;
  const hours = ms / 3_600_000;
  if (hours >= 1) return `${hours}h`;
  const minutes = ms / 60_000;
  if (minutes >= 1) return `${minutes}m`;
  return `${Math.round(ms / 1000)}s`;
}

const defaultIO = {
  log(message) {
    console.log(message);
  },
  async prompt(question) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    try {
      return await rl.question(question);
    } finally {
      rl.close();
    }
  },
};
