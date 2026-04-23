export function extractPendingRequests(snapshot) {
  const pending = snapshot?.pending;

  if (Array.isArray(pending)) {
    return pending;
  }

  if (Array.isArray(snapshot?.requests)) {
    return snapshot.requests;
  }

  if (Array.isArray(snapshot?.items)) {
    return snapshot.items;
  }

  return [];
}

export function extractPairedDevices(snapshot) {
  const paired = snapshot?.paired;

  if (Array.isArray(paired)) {
    return paired;
  }

  if (Array.isArray(snapshot?.devices)) {
    return snapshot.devices;
  }

  return [];
}

export function getRequestId(request) {
  return String(
    request?.requestId ??
      request?.id ??
      request?.pendingId ??
      request?.pairingRequestId ??
      "",
  );
}

export function getDeviceId(entry) {
  return String(entry?.deviceId ?? entry?.nodeId ?? entry?.id ?? "");
}

export function getPublicKey(entry) {
  return String(entry?.publicKey ?? entry?.public_key ?? "");
}

export function detectNodePairingChanges({ baseline, current, sinceMs }) {
  const baselineIds = new Set(extractPendingRequests(baseline).map(getRequestId).filter(Boolean));
  const baselinePairingKeys = new Set(
    extractPairedDevices(baseline).map(getPairingKey).filter(Boolean),
  );

  const pending = extractPendingRequests(current).filter((request) => {
    const requestId = getRequestId(request);
    if (!requestId || baselineIds.has(requestId)) {
      return false;
    }

    if (!isNodeRoleEntry(request)) {
      return false;
    }

    const createdAt = getCreatedAtMs(request);
    if (createdAt && createdAt < sinceMs) {
      return false;
    }

    return true;
  });

  const paired = extractPairedDevices(current).filter((entry) => {
    if (!isNodeRoleEntry(entry)) {
      return false;
    }

    const pairingKey = getPairingKey(entry);
    if (!pairingKey || baselinePairingKeys.has(pairingKey)) {
      return false;
    }

    return true;
  });

  return { pending, paired };
}

function isNodeRoleEntry(entry) {
  if (entry?.role === "node") {
    return true;
  }

  if (Array.isArray(entry?.roles)) {
    return entry.roles.includes("node");
  }

  return entry?.requestedRole === "node";
}

function getPairingKey(entry) {
  const deviceId = getDeviceId(entry).trim();
  const publicKey = getPublicKey(entry).trim();

  if (!deviceId && !publicKey) {
    return "";
  }

  return `${deviceId}|${publicKey}`;
}

function getCreatedAtMs(request) {
  const rawValue =
    request?.createdAt ??
    request?.created_at ??
    request?.requestedAt ??
    request?.requested_at ??
    request?.ts;

  if (rawValue == null) {
    return null;
  }

  if (typeof rawValue === "number") {
    return rawValue;
  }

  const parsed = Date.parse(rawValue);
  return Number.isNaN(parsed) ? null : parsed;
}
