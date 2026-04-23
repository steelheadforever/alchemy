import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export class OpenClawCli {
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

  async generateSetupCode({ url }) {
    const args = ["qr", "--json", "--no-ascii"];
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

  async #retryJsonCommand(args, attempts = 3) {
    let lastError;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await this.#run(args);
      } catch (error) {
        lastError = error;
        if (attempt < attempts) {
          await delay(attempt * 500);
        }
      }
    }

    throw lastError;
  }

  async #run(args) {
    const { stdout } = await execFileAsync("openclaw", args, {
      env: process.env,
      maxBuffer: 1024 * 1024,
    });

    return stdout.trim();
  }
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

