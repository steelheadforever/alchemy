import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const TAILSCALE_FALLBACK_PATHS = [
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  "/usr/local/bin/tailscale",
  "/opt/homebrew/bin/tailscale",
];

const DEFAULT_DEPS = {
  async runCommand(cmd, args) {
    const { stdout } = await execFileAsync(cmd, args, { maxBuffer: 1024 * 1024 });
    return stdout;
  },
};

export async function resolveTailscaleBin({ deps = DEFAULT_DEPS, logger } = {}) {
  for (const candidate of ["tailscale", ...TAILSCALE_FALLBACK_PATHS]) {
    try {
      await deps.runCommand(candidate, ["version"]);
      if (candidate !== "tailscale") {
        logger?.info("Resolved tailscale binary at fallback path", { path: candidate });
      }
      return candidate;
    } catch {
      // Try the next candidate.
    }
  }
  return null;
}

export class TailscaleServeManager {
  #bin;
  #gatewayPort;
  #sidecarPort;
  #logger;
  #deps;
  #captured = null;
  #repointed = false;
  #restored = false;

  constructor({ bin, gatewayPort, sidecarPort, logger, deps = DEFAULT_DEPS }) {
    this.#bin = bin;
    this.#gatewayPort = gatewayPort;
    this.#sidecarPort = sidecarPort;
    this.#logger = logger;
    this.#deps = deps;
  }

  async captureCurrent() {
    let stdout;
    try {
      stdout = await this.#deps.runCommand(this.#bin, ["serve", "status", "--json"]);
    } catch (error) {
      this.#logger?.warn("Could not capture current tailscale serve status", {
        message: error.message,
      });
      this.#captured = null;
      return null;
    }

    try {
      this.#captured = JSON.parse(stdout);
    } catch {
      this.#logger?.warn("Could not parse tailscale serve status JSON; restoration may be lossy");
      this.#captured = null;
    }
    this.#logger?.info("Captured tailscale serve state", {
      hadConfig: this.#captured !== null && Object.keys(this.#captured ?? {}).length > 0,
    });
    return this.#captured;
  }

  async pointAtSidecar() {
    await this.#resetServe();
    await this.#serveBackend(this.#sidecarPort);
    this.#repointed = true;
    this.#logger?.info("Tailscale serve pointed at sidecar", { port: this.#sidecarPort });
  }

  async restoreToGateway() {
    if (this.#restored) return;
    this.#restored = true;
    if (!this.#repointed) {
      this.#logger?.info("Tailscale serve was never repointed; skipping restore");
      return;
    }
    try {
      await this.#resetServe();
      await this.#serveBackend(this.#gatewayPort);
      this.#logger?.info("Tailscale serve restored to gateway", { port: this.#gatewayPort });
    } catch (error) {
      this.#logger?.error("Failed to restore tailscale serve", { message: error.message });
      throw error;
    }
  }

  async #resetServe() {
    try {
      await this.#deps.runCommand(this.#bin, ["serve", "reset"]);
    } catch (error) {
      this.#logger?.warn("`tailscale serve reset` failed; continuing", { message: error.message });
    }
  }

  async #serveBackend(port) {
    await this.#deps.runCommand(this.#bin, [
      "serve",
      "--bg",
      "--https=443",
      `http://127.0.0.1:${port}`,
    ]);
  }
}
