#!/usr/bin/env node

import { main } from "./main.js";

main(process.argv.slice(2)).catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`openclaw-qr-pair: ${message}`);
  process.exitCode = 1;
});

