import os from "node:os";
import { execFileSync } from "node:child_process";
import qrcode from "qrcode-terminal";

import { parseArgs } from "./args.js";
import { OpenClawCli } from "./openclaw-cli.js";
import {
  detectNodePairingChanges,
  getDeviceId,
  getRequestId,
  summarizeDeviceSnapshot,
  summarizePairingCandidates,
} from "./pending-requests.js";
import { decodeSetupCode } from "./setup-code.js";
import { DiagnosticLogger } from "./logger.js";

export async function main(argv) {
  const options = parseArgs(argv);
  const logger = new DiagnosticLogger({ enabled: options.verbose });
  const openclaw = new OpenClawCli({ logger });

  logger.info("Starting openclaw-qr-pair", {
    options: {
      host: options.host,
      port: options.port,
      ttlSeconds: options.ttlSeconds,
      pollIntervalSeconds: options.pollIntervalSeconds,
      name: options.name,
      url: options.url,
      dryRun: options.dryRun,
      verbose: options.verbose,
    },
    hostname: os.hostname(),
  });

  await openclaw.checkInstalled();
  const gatewayProbe = await openclaw.probeGateway();
  logger.info("Gateway probe succeeded", { gatewayProbe });

  const networkChoice = resolveGatewayAddress(options, logger);
  const gatewayUrl = options.url ?? `ws://${networkChoice.host}:${options.port}`;
  const setup = await openclaw.generateSetupCode({ url: gatewayUrl });
  const decodedSetup = decodeSetupCode(setup.setupCode);
  logger.info("Setup code generated", {
    requestedGatewayUrl: gatewayUrl,
    returnedGatewayUrl: setup.gatewayUrl,
    decodedSetup,
  });

  printHeader({
    name: options.name,
    gatewayUrl: setup.gatewayUrl ?? decodedSetup.url,
    networkChoice,
  });

  qrcode.generate(setup.setupCode, { small: true });
  console.log("");
  console.log("Scan the QR in the iOS app to begin pairing.");
  if (options.verbose) {
    console.log("Verbose diagnostics are enabled; pairing details will be written to stderr.");
  }

  if (options.dryRun) {
    console.log("");
    console.log(`Setup code: ${setup.setupCode}`);
    return;
  }

  const startedAt = Date.now();
  const baseline = await openclaw.listDevices();
  logger.info("Captured baseline device snapshot", summarizeDeviceSnapshot(baseline));
  const approved = await waitForAndApproveRequest({
    openclaw,
    baseline,
    ttlSeconds: options.ttlSeconds,
    pollIntervalSeconds: options.pollIntervalSeconds,
    startedAt,
    logger,
  });

  console.log("");
  if (approved.kind === "paired") {
    console.log(
      `Bootstrap pairing completed without manual approval for device ${approved.deviceId}.`,
    );
  } else {
    console.log(`Approved device pairing request ${approved.requestId}.`);
  }
}

async function waitForAndApproveRequest({
  openclaw,
  baseline,
  ttlSeconds,
  pollIntervalSeconds,
  startedAt,
  logger,
}) {
  const deadline = startedAt + ttlSeconds * 1000;
  let pollCount = 0;

  while (Date.now() < deadline) {
    pollCount += 1;
    const current = await openclaw.listDevices();
    const candidates = detectNodePairingChanges({
      baseline,
      current,
      sinceMs: startedAt,
    });
    logger?.info("Polled device snapshot", {
      pollCount,
      elapsedSeconds: Math.round((Date.now() - startedAt) / 1000),
      remainingSeconds: Math.max(0, Math.ceil((deadline - Date.now()) / 1000)),
      snapshot: summarizeDeviceSnapshot(current),
      candidates: summarizePairingCandidates(candidates),
    });

    if (candidates.paired.length > 1) {
      logger?.error("Multiple new paired node devices detected", {
        candidates: summarizePairingCandidates(candidates),
      });
      throw new Error(
        "Multiple new paired node devices appeared during the bootstrap window; refusing to continue automatically.",
      );
    }

    if (candidates.paired.length === 1) {
      logger?.info("Detected silently paired node device", {
        deviceId: getDeviceId(candidates.paired[0]) || "unknown-device",
      });
      return {
        kind: "paired",
        deviceId: getDeviceId(candidates.paired[0]) || "unknown-device",
      };
    }

    if (candidates.pending.length > 1) {
      logger?.error("Multiple new pending node requests detected", {
        candidates: summarizePairingCandidates(candidates),
      });
      throw new Error(
        "Multiple new pending node pairing requests appeared during the approval window; refusing to auto-approve.",
      );
    }

    if (candidates.pending.length === 1) {
      const requestId = getRequestId(candidates.pending[0]);
      logger?.info("Approving pending node pairing request", { requestId });
      await openclaw.approveDevice(requestId);
      logger?.info("Pending node pairing request approved", { requestId });
      return { kind: "approved", requestId };
    }

    await delay(pollIntervalSeconds * 1000);
  }

  logger?.error("Pairing window expired", {
    ttlSeconds,
    pollCount,
    startedAt: new Date(startedAt).toISOString(),
  });
  throw new Error(
    "Pairing window expired before a new node request appeared. If the phone said it could not connect to the server, it likely could not reach the Gateway URL printed above; retry with --url ws://<reachable-host>:<port> or use --verbose for address and polling diagnostics.",
  );
}

function printHeader({ name, gatewayUrl, networkChoice }) {
  console.log(`Host: ${name}`);
  console.log(`Gateway URL: ${gatewayUrl}`);

  if (networkChoice.source === "tailscale") {
    console.log(`Using Tailscale address: ${networkChoice.host}`);
    console.log("Warning: current upstream OpenClaw docs say mobile pairing may fail closed for Tailscale ws:// URLs.");
  } else if (networkChoice.source === "lan") {
    console.log(`Using LAN fallback address: ${networkChoice.host}`);
  } else if (networkChoice.source === "explicit-url") {
    console.log(`Using explicit URL override: ${networkChoice.host}`);
  } else {
    console.log(`Using configured host override: ${networkChoice.host}`);
  }

  console.log(`Local machine: ${os.hostname()}`);
  console.log("");
}

function resolveGatewayAddress(options, logger) {
  if (options.url) {
    logger?.info("Using explicit gateway URL", { url: options.url });
    return { host: options.url, source: "explicit-url" };
  }

  const tailscaleAddress = resolveTailscaleIPv4();
  if (tailscaleAddress) {
    logger?.info("Selected Tailscale IPv4 address", { host: tailscaleAddress });
    return { host: tailscaleAddress, source: "tailscale" };
  }

  const lanAddress = resolveLanIPv4();
  if (lanAddress) {
    logger?.info("Selected LAN IPv4 address", { host: lanAddress });
    return { host: lanAddress, source: "lan" };
  }

  logger?.warn("No Tailscale or LAN IPv4 address found; using configured host", {
    host: options.host,
  });
  return { host: options.host, source: "configured-host" };
}

function resolveTailscaleIPv4() {
  try {
    const output = execFileSync("tailscale", ["ip", "-4"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    })
      .trim()
      .split(/\s+/)
      .find(Boolean);

    return output || null;
  } catch {
    return null;
  }
}

function resolveLanIPv4() {
  const interfaces = os.networkInterfaces();

  for (const addresses of Object.values(interfaces)) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal && isPrivateIPv4(address.address)) {
        return address.address;
      }
    }
  }

  return null;
}

function isPrivateIPv4(address) {
  return (
    address.startsWith("10.") ||
    address.startsWith("192.168.") ||
    /^172\.(1[6-9]|2\d|3[0-1])\./.test(address)
  );
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
