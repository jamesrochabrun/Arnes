#!/usr/bin/env node
"use strict";
const { execFileSync } = require("node:child_process");

const PACKAGES = {
  "darwin-arm64": "arnes-darwin-arm64",
  "darwin-x64": "arnes-darwin-x64",
  "linux-x64": "arnes-linux-x64",
  "linux-arm64": "arnes-linux-arm64",
};

const key = `${process.platform}-${process.arch}`;
const pkg = PACKAGES[key];
if (!pkg) {
  console.error(
    `arnes: unsupported platform ${key} (supported: ${Object.keys(PACKAGES).join(", ")})`
  );
  process.exit(1);
}

let bin;
try {
  bin = require.resolve(`${pkg}/bin/arnes`);
} catch {
  console.error(
    `arnes: native package ${pkg} is not installed — optional dependencies were skipped.\n` +
      `Reinstall with: bun add -g arnes  (or: npm install -g arnes)`
  );
  process.exit(1);
}

// The binary owns the terminal: the REPL runs raw-mode and treats SIGINT as
// turn-cancel. The shim must outlive those signals or the child is orphaned
// mid-session with the shell prompt back.
process.on("SIGINT", () => {});
process.on("SIGTERM", () => {});

try {
  execFileSync(bin, process.argv.slice(2), { stdio: "inherit" });
} catch (err) {
  if (typeof err.status === "number") process.exit(err.status);
  if (err.signal) {
    process.removeAllListeners(err.signal);
    process.kill(process.pid, err.signal);
  }
  console.error(`arnes: ${err.message ?? err}`);
  process.exit(1);
}
