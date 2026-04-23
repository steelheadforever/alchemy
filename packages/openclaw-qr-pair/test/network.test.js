import test from "node:test";
import assert from "node:assert/strict";

import {
  isTailscaleIPv4,
  resolveGatewayAddress,
  resolveTailscaleIPv4,
  resolveTailscaleIPv4FromInterfaces,
} from "../src/network.js";

test("recognizes Tailscale IPv4 carrier-grade NAT range", () => {
  assert.equal(isTailscaleIPv4("100.64.0.1"), true);
  assert.equal(isTailscaleIPv4("100.100.100.100"), true);
  assert.equal(isTailscaleIPv4("100.127.255.254"), true);
  assert.equal(isTailscaleIPv4("100.63.255.255"), false);
  assert.equal(isTailscaleIPv4("100.128.0.1"), false);
  assert.equal(isTailscaleIPv4("192.168.1.20"), false);
});

test("finds Tailscale IPv4 address from network interfaces", () => {
  const interfaces = {
    en0: [{ family: "IPv4", internal: false, address: "192.168.1.20" }],
    utun4: [{ family: "IPv4", internal: false, address: "100.101.102.103" }],
  };

  assert.equal(resolveTailscaleIPv4FromInterfaces(interfaces), "100.101.102.103");
});

test("falls back to interface Tailscale IP when CLI lookup fails", () => {
  const interfaces = {
    en0: [{ family: "IPv4", internal: false, address: "192.168.1.20" }],
    utun4: [{ family: "IPv4", internal: false, address: "100.101.102.103" }],
  };

  const address = resolveTailscaleIPv4({
    interfaces,
    runTailscaleIp() {
      throw new Error("tailscale command not found");
    },
  });

  assert.equal(address, "100.101.102.103");
});

test("prefers LAN address over raw Tailscale address for gateway URL", () => {
  const interfaces = {
    en0: [{ family: "IPv4", internal: false, address: "192.168.1.20" }],
    utun4: [{ family: "IPv4", internal: false, address: "100.101.102.103" }],
  };

  const choice = resolveGatewayAddress(
    { host: "127.0.0.1", url: null },
    null,
    {
      interfaces,
      runTailscaleIp() {
        throw new Error("tailscale command not found");
      },
    },
  );

  assert.deepEqual(choice, { host: "192.168.1.20", source: "lan-with-tailscale-detected" });
});

test("falls back to raw Tailscale address only when no LAN address exists", () => {
  const interfaces = {
    utun4: [{ family: "IPv4", internal: false, address: "100.101.102.103" }],
  };

  const choice = resolveGatewayAddress(
    { host: "127.0.0.1", url: null },
    null,
    {
      interfaces,
      runTailscaleIp() {
        throw new Error("tailscale command not found");
      },
    },
  );

  assert.deepEqual(choice, { host: "100.101.102.103", source: "tailscale-raw-fallback" });
});
