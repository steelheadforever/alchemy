import os from "node:os";

const FLAG_WITH_VALUE = new Set(["--host", "--port", "--ttl", "--name", "--url", "--poll-interval"]);

export function parseArgs(argv) {
  const options = {
    host: "127.0.0.1",
    port: 18789,
    ttlSeconds: 90,
    pollIntervalSeconds: 2,
    name: os.hostname(),
    url: null,
    dryRun: false,
    verbose: process.env.OPENCLAW_QR_PAIR_DEBUG === "1",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === "--dry-run") {
      options.dryRun = true;
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
      case "--host":
        options.host = value;
        break;
      case "--port":
        options.port = parseIntegerFlag(token, value);
        break;
      case "--ttl":
        options.ttlSeconds = parseIntegerFlag(token, value);
        break;
      case "--poll-interval":
        options.pollIntervalSeconds = parseIntegerFlag(token, value);
        break;
      case "--name":
        options.name = value.trim();
        break;
      case "--url":
        options.url = value.trim();
        break;
      default:
        break;
    }
  }

  return options;
}

function parseIntegerFlag(flag, value) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return parsed;
}
