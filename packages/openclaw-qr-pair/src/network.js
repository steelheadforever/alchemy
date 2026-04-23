import os from "node:os";
import { execFileSync } from "node:child_process";

export function resolveGatewayAddress(options, logger, dependencies = {}) {
  if (options.url) {
    logger?.info("Using explicit gateway URL", { url: options.url });
    return { host: options.url, source: "explicit-url" };
  }

  const tailscaleAddress = resolveTailscaleIPv4({ logger, ...dependencies });
  if (tailscaleAddress) {
    logger?.info("Selected Tailscale IPv4 address", { host: tailscaleAddress });
    return { host: tailscaleAddress, source: "tailscale" };
  }

  const lanAddress = resolveLanIPv4(dependencies.interfaces);
  if (lanAddress) {
    logger?.info("Selected LAN IPv4 address", { host: lanAddress });
    return { host: lanAddress, source: "lan" };
  }

  logger?.warn("No Tailscale or LAN IPv4 address found; using configured host", {
    host: options.host,
  });
  return { host: options.host, source: "configured-host" };
}

export function resolveTailscaleIPv4({
  logger,
  interfaces = os.networkInterfaces(),
  runTailscaleIp = defaultRunTailscaleIp,
} = {}) {
  const cliAddress = resolveTailscaleIPv4FromCli({ logger, runTailscaleIp });
  if (cliAddress) {
    return cliAddress;
  }

  const interfaceAddress = resolveTailscaleIPv4FromInterfaces(interfaces);
  if (interfaceAddress) {
    logger?.info("Found Tailscale IPv4 address on a network interface", {
      host: interfaceAddress,
    });
    return interfaceAddress;
  }

  return null;
}

export function resolveTailscaleIPv4FromInterfaces(interfaces) {
  for (const addresses of Object.values(interfaces)) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal && isTailscaleIPv4(address.address)) {
        return address.address;
      }
    }
  }

  return null;
}

export function resolveLanIPv4(interfaces = os.networkInterfaces()) {
  for (const addresses of Object.values(interfaces)) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal && isPrivateIPv4(address.address)) {
        return address.address;
      }
    }
  }

  return null;
}

export function isTailscaleIPv4(address) {
  const octets = parseIPv4(address);
  if (!octets) {
    return false;
  }

  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

export function isPrivateIPv4(address) {
  return (
    address.startsWith("10.") ||
    address.startsWith("192.168.") ||
    /^172\.(1[6-9]|2\d|3[0-1])\./.test(address)
  );
}

function resolveTailscaleIPv4FromCli({ logger, runTailscaleIp }) {
  try {
    const output = runTailscaleIp();
    const address = output.trim().split(/\s+/).find(Boolean);
    return address || null;
  } catch (error) {
    logger?.warn("Could not read Tailscale IPv4 address from tailscale CLI", {
      message: error.message,
    });
    return null;
  }
}

function defaultRunTailscaleIp() {
  return execFileSync("tailscale", ["ip", "-4"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
}

function parseIPv4(address) {
  const octets = String(address).split(".");
  if (octets.length !== 4) {
    return null;
  }

  const parsed = octets.map((octet) => Number.parseInt(octet, 10));
  if (parsed.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) {
    return null;
  }

  return parsed;
}
