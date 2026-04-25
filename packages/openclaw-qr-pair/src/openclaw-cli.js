import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export class OpenClawCli {
  constructor({ logger } = {}) {
    this.logger = logger;
  }

  async checkInstalled() {
    await this.#run(["--version"]);
  }

  async probeGateway() {
    try {
      const output = await this.#run(["gateway", "probe", "--json"]);
      return JSON.parse(output);
    } catch (error) {
      throw new Error(`OpenClaw gateway probe failed: ${error.message}`);
    }
  }

  async generateSetupCode({ url, remote = false }) {
    const args = ["qr", "--json", "--no-ascii"];
    if (remote) {
      args.push("--remote");
    }
    if (url) {
      args.push("--url", url);
    }

    const output = await this.#run(args);
    const payload = JSON.parse(output);

    if (typeof payload.setupCode !== "string" || payload.setupCode.length === 0) {
      throw new Error("openclaw qr did not return a setupCode");
    }

    return payload;
  }

  async listDevices() {
    const output = await this.#retryJsonCommand(["devices", "list", "--json"]);
    return JSON.parse(output);
  }

  async approveDevice(requestId) {
    const output = await this.#retryJsonCommand(["devices", "approve", requestId, "--json"]);
    return JSON.parse(output);
  }

  async removeDevice(deviceId) {
    const output = await this.#retryJsonCommand(["devices", "remove", deviceId, "--json"]);
    return JSON.parse(output);
  }

  async #retryJsonCommand(args, attempts = 3) {
    let lastError;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        this.logger?.info("Running retryable openclaw command", {
          command: ["openclaw", ...args],
          attempt,
          attempts,
        });
        return await this.#run(args);
      } catch (error) {
        lastError = error;
        this.logger?.warn("Retryable openclaw command failed", {
          command: ["openclaw", ...args],
          attempt,
          attempts,
          message: error.message,
        });
        if (attempt < attempts) {
          await delay(attempt * 500);
        }
      }
    }

    throw lastError;
  }

  async #run(args) {
    this.logger?.info("Running openclaw command", { command: ["openclaw", ...args] });

    try {
      const { stdout, stderr } = await execFileAsync("openclaw", args, {
        env: process.env,
        maxBuffer: 1024 * 1024,
      });

      this.logger?.info("Openclaw command completed", {
        command: ["openclaw", ...args],
        stdoutBytes: stdout.length,
        stderr: stderr.trim() || undefined,
      });

      return stdout.trim();
    } catch (error) {
      this.logger?.error("Openclaw command failed", {
        command: ["openclaw", ...args],
        message: error.message,
        stdout: error.stdout,
        stderr: error.stderr,
      });
      throw error;
    }
  }
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
