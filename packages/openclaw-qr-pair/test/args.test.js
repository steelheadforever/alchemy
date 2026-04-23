import test from "node:test";
import assert from "node:assert/strict";

import { parseArgs } from "../src/args.js";

test("enables verbose diagnostics with flag", () => {
  const options = parseArgs(["--verbose"]);

  assert.equal(options.verbose, true);
});

test("enables remote setup code generation with flag", () => {
  const options = parseArgs(["--remote"]);

  assert.equal(options.remote, true);
});

test("rejects remote and explicit url together", () => {
  assert.throws(
    () => parseArgs(["--remote", "--url", "wss://gateway.example/ws"]),
    /--remote and --url cannot be used together/,
  );
});

test("enables verbose diagnostics with environment variable", () => {
  const original = process.env.OPENCLAW_QR_PAIR_DEBUG;
  process.env.OPENCLAW_QR_PAIR_DEBUG = "1";

  try {
    const options = parseArgs([]);
    assert.equal(options.verbose, true);
  } finally {
    if (original === undefined) {
      delete process.env.OPENCLAW_QR_PAIR_DEBUG;
    } else {
      process.env.OPENCLAW_QR_PAIR_DEBUG = original;
    }
  }
});
