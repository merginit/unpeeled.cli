#!/usr/bin/env node

import { spawn } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const supported = new Set([
  "darwin-arm64",
  "darwin-x64",
  "linux-arm64",
  "linux-x64",
  "win32-arm64",
  "win32-x64",
]);
const platformKey = `${process.platform}-${process.arch}`;

if (!supported.has(platformKey)) {
  console.error(
    `Brand Peel CLI does not provide a binary for ${process.platform}/${process.arch}.`,
  );
  process.exit(1);
}

const packageName = `@merginit/brandpeel-${platformKey}`;
const extension = process.platform === "win32" ? ".exe" : "";

let binaryPath;
try {
  binaryPath = require.resolve(`${packageName}/bin/brandpeel${extension}`);
} catch {
  console.error(`Could not find the optional native package ${packageName}.`);
  console.error("Reinstall @merginit/brandpeel without omitting optional dependencies.");
  process.exit(1);
}

const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
  shell: false,
  windowsHide: true,
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}

child.on("error", (error) => {
  console.error(`Failed to start Brand Peel CLI: ${error.message}`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
