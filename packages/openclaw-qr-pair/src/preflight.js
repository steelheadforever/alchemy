import fs from "node:fs/promises";

import { resolveTailscaleBin } from "./sidecar-serve.js";

export class PreflightError extends Error {
  constructor(message) {
    super(message);
    this.name = "PreflightError";
  }
}

const DEFAULT_DEPS = {
  async readFile(path) {
    return fs.readFile(path, "utf8");
  },
  warn(message) {
    console.warn(message);
  },
};

export async function runPreflight({ openclaw, options, logger, deps = DEFAULT_DEPS }) {
  await checkOpenclawInstalled({ openclaw, logger });
  const probe = await probeGateway({ openclaw, logger });

  let tailscaleBin = null;
  if (options?.url) {
    logger?.info("Explicit --url override; skipping tailscale preflight checks", {
      url: options.url,
    });
  } else {
    checkTailscaleUpFromProbe({ probe, logger });
    checkTailscaleServeFromProbe({ probe, logger });
    tailscaleBin = await checkTailscaleBinResolvable({ deps, logger });
  }

  await warnIfTrustedProxiesMissing({ deps, logger, probe });
  return { probe, tailscaleBin };
}

async function checkOpenclawInstalled({ openclaw, logger }) {
  try {
    await openclaw.checkInstalled();
    logger?.info("openclaw CLI detected");
  } catch (error) {
    throw new PreflightError(
      `openclaw CLI was not found on PATH. Install OpenClaw before retrying. (${error.message})`,
    );
  }
}

async function probeGateway({ openclaw, logger }) {
  try {
    const probe = await openclaw.probeGateway();
    logger?.info("Gateway probe succeeded", { probe });
    return probe;
  } catch (error) {
    throw new PreflightError(
      `Could not reach the OpenClaw gateway. Start it with \`openclaw gateway --tailscale serve\`. (${error.message})`,
    );
  }
}

function checkTailscaleUpFromProbe({ probe, logger }) {
  const tailnetIPv4 = probe?.network?.tailnetIPv4;
  if (!tailnetIPv4) {
    throw new PreflightError(
      "Tailscale does not appear to be running: the OpenClaw gateway probe did not report a tailnet IPv4 address. " +
        "Open the Tailscale app (or run `tailscale up`) and try again.",
    );
  }
  logger?.info("Tailscale is up", { tailnetIPv4 });
}

async function checkTailscaleBinResolvable({ deps, logger }) {
  const resolveDeps = deps.runCommand ? { runCommand: deps.runCommand } : undefined;
  const bin = await resolveTailscaleBin({ deps: resolveDeps, logger });
  if (!bin) {
    throw new PreflightError(
      "Could not locate the tailscale binary on PATH or at common install paths " +
        "(/Applications/Tailscale.app/Contents/MacOS/Tailscale, /usr/local/bin/tailscale, " +
        "/opt/homebrew/bin/tailscale). Install Tailscale or symlink the CLI before retrying.",
    );
  }
  logger?.info("Tailscale binary resolvable", { bin });
  return bin;
}

function checkTailscaleServeFromProbe({ probe, logger }) {
  const tailscaleMode = probe?.targets?.[0]?.config?.gateway?.tailscaleMode;
  if (tailscaleMode !== "serve") {
    throw new PreflightError(
      `OpenClaw gateway is not running in tailscale serve mode (tailscaleMode=${tailscaleMode ?? "unset"}). ` +
        "Start the gateway with `openclaw gateway --tailscale serve` before pairing.",
    );
  }
  logger?.info("OpenClaw gateway has tailscale serve enabled");
}

async function warnIfTrustedProxiesMissing({ deps, logger, probe }) {
  const tailscaleMode = probe?.targets?.[0]?.config?.gateway?.tailscaleMode;
  if (tailscaleMode !== "serve") {
    return;
  }

  const configPath = probe?.targets?.[0]?.config?.path;
  if (!configPath) {
    logger?.warn("Cannot verify gateway.trustedProxies: config path missing from gateway probe");
    return;
  }

  let raw;
  try {
    raw = await deps.readFile(configPath);
  } catch (error) {
    logger?.warn("Cannot read openclaw config file for trustedProxies check", {
      configPath,
      message: error.message,
    });
    return;
  }

  let config;
  try {
    config = JSON.parse(raw);
  } catch {
    logger?.warn("openclaw config file is not valid JSON; skipping trustedProxies check", {
      configPath,
    });
    return;
  }

  const trustedProxies = Array.isArray(config?.gateway?.trustedProxies)
    ? config.gateway.trustedProxies
    : [];
  const hasLoopback = trustedProxies.some(
    (entry) => typeof entry === "string" && (entry.startsWith("127.") || entry === "::1"),
  );

  if (!hasLoopback) {
    const message =
      `Warning: gateway.trustedProxies in ${configPath} does not include loopback. ` +
      `Add ["127.0.0.1", "::1"] to silence "Proxy headers detected from untrusted address" warnings.`;
    deps.warn(message);
    logger?.warn("gateway.trustedProxies missing loopback entry", {
      configPath,
      trustedProxies,
    });
  } else {
    logger?.info("gateway.trustedProxies includes loopback", { trustedProxies });
  }
}
