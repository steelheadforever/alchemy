import os from "node:os";
import qrcode from "qrcode-terminal";

import { parseArgs } from "./args.js";
import { OpenClawCli } from "./openclaw-cli.js";
import { resolveGatewayAddress } from "./network.js";
import {
  detectNodePairingChanges,
  getDeviceId,
  getRequestId,
  summarizeDeviceSnapshot,
  summarizePairingCandidates,
} from "./pending-requests.js";
import { decodeSetupCode, encodeSetupCode } from "./setup-code.js";
import { DiagnosticLogger } from "./logger.js";
import { Sidecar } from "./sidecar.js";

export async function main(argv) {
  const options = parseArgs(argv);
  const logger = new DiagnosticLogger({ enabled: options.verbose });
  const openclaw = new OpenClawCli({ logger });

  logger.info("Starting openclaw-qr-pair", {
    options: {
      host: options.host,
      port: options.port,
      sidecarPort: options.sidecarPort,
      ttlSeconds: options.ttlSeconds,
      pollIntervalSeconds: options.pollIntervalSeconds,
      name: options.name,
      url: options.url,
      remote: options.remote,
      dryRun: options.dryRun,
      verbose: options.verbose,
    },
    hostname: os.hostname(),
  });

  await openclaw.checkInstalled();
  const gatewayProbe = await openclaw.probeGateway();
  logger.info("Gateway probe succeeded", { gatewayProbe });

  // Step 1: Resolve gateway address and generate setup code.
  // The sidecar pairs with the gateway (not the phone).
  const networkChoice = options.remote
    ? { host: "openclaw remote configuration", source: "remote" }
    : resolveGatewayAddress(options, logger);
  const gatewayUrl = options.remote ? null : options.url ?? `ws://${networkChoice.host}:${options.port}`;
  const setup = await openclaw.generateSetupCode({ url: gatewayUrl, remote: options.remote });
  const decodedSetup = decodeSetupCode(setup.setupCode);
  logger.info("Setup code generated for gateway pairing", {
    remote: options.remote,
    requestedGatewayUrl: gatewayUrl,
    returnedGatewayUrl: setup.gatewayUrl,
    urlSource: setup.urlSource,
    decodedSetup,
  });

  const resolvedGatewayUrl = setup.gatewayUrl ?? decodedSetup.url;
  const bootstrapToken = decodedSetup.bootstrapToken;

  // Step 2: Create the sidecar and connect it to the gateway.
  const sidecar = new Sidecar({
    gatewayUrl: resolvedGatewayUrl,
    bootstrapToken,
    sidecarPort: options.sidecarPort,
    logger,
  });

  console.log(`Host: ${options.name}`);
  console.log(`Gateway URL: ${resolvedGatewayUrl}`);
  printNetworkInfo(networkChoice);
  console.log(`Local machine: ${os.hostname()}`);
  console.log("");
  console.log("Connecting sidecar to gateway...");

  // Step 3: Connect sidecar to gateway AND approve its pairing concurrently.
  const startedAt = Date.now();
  const baseline = await openclaw.listDevices();
  logger.info("Captured baseline device snapshot", summarizeDeviceSnapshot(baseline));

  const [, approved] = await Promise.all([
    sidecar.connectToGateway(),
    waitForAndApproveRequest({
      openclaw,
      baseline,
      ttlSeconds: options.ttlSeconds,
      pollIntervalSeconds: options.pollIntervalSeconds,
      startedAt,
      logger,
    }),
  ]);

  if (approved.kind === "paired") {
    logger.info("Sidecar paired without manual approval", { deviceId: approved.deviceId });
  } else {
    logger.info("Sidecar pairing approved", { requestId: approved.requestId });
  }

  console.log("Sidecar connected to gateway.");

  // Step 4: Start the phone-facing server.
  await sidecar.startPhoneServer();

  // Step 5: Generate a NEW QR code pointing to the sidecar (not the gateway).
  const sidecarHost = networkChoice.host === "openclaw remote configuration"
    ? "127.0.0.1"
    : networkChoice.host;
  const sidecarUrl = `ws://${sidecarHost}:${options.sidecarPort}`;
  const phoneSetupCode = encodeSetupCode({
    url: sidecarUrl,
    bootstrapToken,
  });

  logger.info("Phone QR generated", {
    sidecarUrl,
    sidecarPort: options.sidecarPort,
  });

  console.log("");
  console.log(`Sidecar URL: ${sidecarUrl}`);
  console.log("");

  qrcode.generate(phoneSetupCode, { small: true });
  console.log("");
  console.log("Scan the QR in the iOS app to connect through the sidecar.");
  console.log("Messages will be buffered while the phone is disconnected.");
  if (options.verbose) {
    console.log("Verbose diagnostics are enabled; details will be written to stderr.");
  }

  if (options.dryRun) {
    console.log("");
    console.log(`Setup code: ${phoneSetupCode}`);
    return;
  }

  // Step 6: Run until Ctrl+C.
  console.log("Press Ctrl+C to stop.");
  await sidecar.run();
  console.log("Sidecar stopped.");
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

function printNetworkInfo(networkChoice) {
  if (networkChoice.source === "tailscale") {
    console.log(`Using Tailscale address: ${networkChoice.host}`);
    console.log("Warning: current upstream OpenClaw docs say mobile pairing may fail closed for Tailscale ws:// URLs.");
  } else if (networkChoice.source === "remote") {
    console.log("Using OpenClaw remote gateway configuration.");
  } else if (networkChoice.source === "tailscale-raw-fallback") {
    console.log(`Using Tailscale fallback address: ${networkChoice.host}`);
    console.log("Warning: OpenClaw requires wss:// or Tailscale Serve/Funnel for Tailscale mobile pairing.");
  } else if (networkChoice.source === "lan-with-tailscale-detected") {
    console.log(`Using LAN fallback address: ${networkChoice.host}`);
    console.log("Tailscale was detected, but raw ws:// Tailscale pairing is not accepted by OpenClaw.");
  } else if (networkChoice.source === "lan") {
    console.log(`Using LAN fallback address: ${networkChoice.host}`);
  } else if (networkChoice.source === "explicit-url") {
    console.log(`Using explicit URL override: ${networkChoice.host}`);
  } else {
    console.log(`Using configured host override: ${networkChoice.host}`);
  }
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
