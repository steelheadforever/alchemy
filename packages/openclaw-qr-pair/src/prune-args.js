import { parseDuration } from "./prune.js";

const FLAG_WITH_VALUE = new Set(["--stale-for", "--id"]);

export function parsePruneArgs(argv) {
  const options = {
    staleForMs: null,
    deviceId: null,
    dryRun: false,
    yes: false,
    allRoles: false,
    verbose: process.env.OPENCLAW_QR_PAIR_DEBUG === "1",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === "--dry-run") {
      options.dryRun = true;
      continue;
    }
    if (token === "--yes" || token === "-y") {
      options.yes = true;
      continue;
    }
    if (token === "--all-roles") {
      options.allRoles = true;
      continue;
    }
    if (token === "--verbose") {
      options.verbose = true;
      continue;
    }

    if (!FLAG_WITH_VALUE.has(token)) {
      throw new Error(`Unknown argument: ${token}`);
    }

    const value = argv[index + 1];
    if (!value) {
      throw new Error(`Missing value for ${token}`);
    }
    index += 1;

    switch (token) {
      case "--stale-for":
        options.staleForMs = parseDuration(value);
        break;
      case "--id":
        options.deviceId = value.trim();
        break;
      default:
        break;
    }
  }

  if (options.deviceId && options.staleForMs !== null) {
    throw new Error("--id and --stale-for cannot be used together");
  }

  return options;
}
