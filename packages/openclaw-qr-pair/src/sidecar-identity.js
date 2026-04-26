import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const CONFIG_DIR = path.join(os.homedir(), ".config", "openclaw-qr-pair");
const IDENTITY_FILE = "identity.json";

export function loadOrGenerateIdentity(configDir = CONFIG_DIR) {
  const identityPath = path.join(configDir, IDENTITY_FILE);

  try {
    const data = JSON.parse(fs.readFileSync(identityPath, "utf8"));
    if (data.seed && data.publicKey) {
      return {
        seed: Buffer.from(data.seed, "hex"),
        publicKey: Buffer.from(data.publicKey, "hex"),
        deviceToken: data.deviceToken ?? null,
        operatorToken: data.operatorToken ?? null,
      };
    }
  } catch {
    // Generate new identity.
  }

  const keypair = crypto.generateKeyPairSync("ed25519", {
    privateKeyEncoding: { type: "pkcs8", format: "der" },
    publicKeyEncoding: { type: "spki", format: "der" },
  });

  // Extract raw 32-byte seed from PKCS8 DER (last 32 bytes of the nested octet string).
  const seed = extractEd25519Seed(keypair.privateKey);
  // Extract raw 32-byte public key from SPKI DER (last 32 bytes).
  const publicKey = keypair.publicKey.subarray(keypair.publicKey.length - 32);

  const identity = { seed, publicKey, deviceToken: null, operatorToken: null };
  saveIdentity(configDir, identity);
  return identity;
}

export function saveIdentity(configDir = CONFIG_DIR, identity) {
  fs.mkdirSync(configDir, { recursive: true });
  const identityPath = path.join(configDir, IDENTITY_FILE);
  fs.writeFileSync(
    identityPath,
    JSON.stringify({
      seed: identity.seed.toString("hex"),
      publicKey: identity.publicKey.toString("hex"),
      deviceToken: identity.deviceToken ?? null,
      operatorToken: identity.operatorToken ?? null,
    }),
    "utf8",
  );
}

export function computeDeviceID(publicKey) {
  const hash = crypto.createHash("sha256").update(publicKey).digest();
  return hash.toString("hex");
}

export function buildSignaturePayloadV3({
  deviceID,
  clientID,
  clientMode,
  role,
  scopes,
  signedAtMilliseconds,
  token,
  nonce,
  platform,
  deviceFamily,
}) {
  return [
    "v3",
    deviceID,
    clientID,
    clientMode,
    role,
    scopes.join(","),
    String(signedAtMilliseconds),
    token ?? "",
    nonce,
    normalizeMetadataForAuth(platform),
    normalizeMetadataForAuth(deviceFamily),
  ].join("|");
}

export function sign(seed, payload) {
  const privateKey = crypto.createPrivateKey({
    key: wrapEd25519Seed(seed),
    format: "der",
    type: "pkcs8",
  });
  const signature = crypto.sign(null, Buffer.from(payload, "utf8"), privateKey);
  return base64url(signature);
}

export function publicKeyBase64URL(publicKey) {
  return base64url(publicKey);
}

export function normalizeMetadataForAuth(value) {
  const trimmed = (value ?? "").trim();
  if (!trimmed) return "";

  let result = "";
  for (const char of trimmed) {
    const code = char.codePointAt(0);
    if (code >= 65 && code <= 90) {
      result += String.fromCodePoint(code + 32);
    } else {
      result += char;
    }
  }
  return result;
}

function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function extractEd25519Seed(pkcs8Der) {
  // PKCS8 DER for Ed25519: 30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20 <32 bytes seed>
  // The seed is the last 32 bytes.
  return pkcs8Der.subarray(pkcs8Der.length - 32);
}

function wrapEd25519Seed(seed) {
  // Rebuild PKCS8 DER wrapper around raw 32-byte Ed25519 seed.
  const prefix = Buffer.from(
    "302e020100300506032b657004220420",
    "hex",
  );
  return Buffer.concat([prefix, seed]);
}
