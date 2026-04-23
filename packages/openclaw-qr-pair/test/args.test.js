import test from "node:test";
import assert from "node:assert/strict";

import { parseArgs } from "../src/args.js";

test("enables verbose diagnostics with flag", () => {
  const options = parseArgs(["--verbose"]);

  assert.equal(options.verbose, true);
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
