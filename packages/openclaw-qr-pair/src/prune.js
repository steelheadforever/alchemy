import {
  extractPairedDevices,
  getDeviceCreatedAtMs,
  getDeviceId,
  getDeviceLastUsedMs,
  getDeviceStalenessAnchorMs,
} from "./pending-requests.js";

export function selectPrunableDevices({
  snapshot,
  nowMs,
  olderThanMs = null,
  deviceId = null,
  restrictToNodeRole = true,
}) {
  const devices = extractPairedDevices(snapshot);

  return devices
    .filter((device) => {
      if (deviceId) {
        return getDeviceId(device) === deviceId;
      }

      if (restrictToNodeRole && !isNodeRoleEntry(device)) {
        return false;
      }

      if (olderThanMs === null) {
        return true;
      }

      const anchor = getDeviceStalenessAnchorMs(device);
      if (anchor === null) {
        return false;
      }

      return nowMs - anchor >= olderThanMs;
    })
    .map((device) => ({
      device,
      deviceId: getDeviceId(device),
      role: deviceRole(device),
      platform: device?.platform ?? null,
      lastUsedMs: getDeviceLastUsedMs(device),
      createdMs: getDeviceCreatedAtMs(device),
    }))
    .filter((entry) => entry.deviceId);
}

export function parseDuration(input) {
  if (typeof input !== "string") {
    throw new Error("Duration must be a string");
  }

  const match = input.trim().match(/^(\d+)\s*(s|m|h|d)$/i);
  if (!match) {
    throw new Error(`Invalid duration: ${input}. Use forms like 30s, 15m, 6h, 7d.`);
  }

  const amount = Number.parseInt(match[1], 10);
  const unit = match[2].toLowerCase();
  const multipliers = { s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 };
  return amount * multipliers[unit];
}

export function formatRelativeAge(deltaMs) {
  if (deltaMs === null || deltaMs === undefined || Number.isNaN(deltaMs)) {
    return "never";
  }

  const abs = Math.max(0, deltaMs);
  const days = Math.floor(abs / 86_400_000);
  if (days >= 1) {
    return `${days}d ago`;
  }
  const hours = Math.floor(abs / 3_600_000);
  if (hours >= 1) {
    return `${hours}h ago`;
  }
  const minutes = Math.floor(abs / 60_000);
  if (minutes >= 1) {
    return `${minutes}m ago`;
  }
  return "just now";
}

function isNodeRoleEntry(device) {
  if (device?.role === "node") {
    return true;
  }
  if (Array.isArray(device?.roles)) {
    return device.roles.includes("node");
  }
  return false;
}

function deviceRole(device) {
  if (device?.role) {
    return device.role;
  }
  if (Array.isArray(device?.roles) && device.roles.length > 0) {
    return device.roles.join(",");
  }
  return null;
}
