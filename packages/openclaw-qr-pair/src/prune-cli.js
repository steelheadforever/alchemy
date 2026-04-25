#!/usr/bin/env node

import { pruneMain } from "./prune-main.js";

pruneMain(process.argv.slice(2)).catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`openclaw-node-prune: ${message}`);
  process.exitCode = 1;
});
