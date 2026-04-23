export function encodeSetupCode(payload) {
  const normalized = normalizeSetupCode(payload);
  const json = JSON.stringify(normalized);
  return Buffer.from(json, "utf8").toString("base64url");
}

export function decodeSetupCode(input) {
  const trimmed = String(input ?? "").trim();
  if (!trimmed) {
    throw new Error("Setup code is empty");
  }

  const parsed = tryParseJson(trimmed) ?? tryDecodeBase64Payload(trimmed);
  return normalizeSetupCode(parsed);
}

function tryDecodeBase64Payload(input) {
  for (const encoding of ["base64url", "base64"]) {
    try {
      const json = Buffer.from(input, encoding).toString("utf8");
      const parsed = tryParseJson(json);
      if (parsed) {
        return parsed;
      }
    } catch {
      // Try the next encoding.
    }
  }

  throw new Error("Setup code is not valid JSON or base64-encoded JSON");
}

function tryParseJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function normalizeSetupCode(payload) {
  if (!payload || typeof payload !== "object") {
    throw new Error("Setup code payload must be an object");
  }

  const url = String(payload.url ?? "").trim();
  const bootstrapToken = String(payload.bootstrapToken ?? payload.token ?? "").trim();

  if (!url) {
    throw new Error("Setup code payload is missing url");
  }

  if (!bootstrapToken) {
    throw new Error("Setup code payload is missing bootstrapToken");
  }

  return { url, bootstrapToken };
}

