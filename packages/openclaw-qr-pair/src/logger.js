export class DiagnosticLogger {
  constructor({ enabled = false, stream = process.stderr } = {}) {
    this.enabled = enabled;
    this.stream = stream;
  }

  info(message, details) {
    this.#write("info", message, details);
  }

  warn(message, details) {
    this.#write("warn", message, details);
  }

  error(message, details) {
    this.#write("error", message, details);
  }

  #write(level, message, details) {
    if (!this.enabled) {
      return;
    }

    const timestamp = new Date().toISOString();
    const suffix = details === undefined ? "" : ` ${JSON.stringify(redactSecrets(details))}`;
    this.stream.write(`[${timestamp}] ${level.toUpperCase()} ${message}${suffix}\n`);
  }
}

export function redactSecrets(value) {
  if (Array.isArray(value)) {
    return value.map(redactSecrets);
  }

  if (!value || typeof value !== "object") {
    return value;
  }

  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      isSecretKey(key) ? redactValue(entry) : redactSecrets(entry),
    ]),
  );
}

function isSecretKey(key) {
  return /token|secret|password|signature/i.test(key);
}

function redactValue(value) {
  if (typeof value !== "string") {
    return "[redacted]";
  }

  if (value.length <= 8) {
    return "[redacted]";
  }

  return `${value.slice(0, 4)}...${value.slice(-4)}`;
}
