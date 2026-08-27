"use strict";

const { spawnSync } = require("node:child_process");

const script = process.argv[2];
if (!script) {
  console.error("usage: node run-powershell.js <script.ps1> [arguments]");
  process.exit(2);
}

const windows = process.platform === "win32";
const executable = windows ? "powershell.exe" : "pwsh";
const shellArgs = ["-NoProfile"];
if (windows) {
  shellArgs.push("-ExecutionPolicy", "Bypass");
}
shellArgs.push("-File", script, ...process.argv.slice(3));

const result = spawnSync(executable, shellArgs, { stdio: "inherit" });
if (result.error) {
  console.error(`could not start ${executable}: ${result.error.message}`);
  process.exit(127);
}
process.exit(result.status ?? 1);
