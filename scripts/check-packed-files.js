import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

const npmCli = process.env.npm_execpath;
if (!npmCli) throw new Error("Run this check through npm so npm_execpath is available.");

const packages = [
  ["darwin-arm64", "bin/brandpeel"],
  ["darwin-x64", "bin/brandpeel"],
  ["linux-arm64", "bin/brandpeel"],
  ["linux-x64", "bin/brandpeel"],
  ["win32-arm64", "bin/brandpeel.exe"],
  ["win32-x64", "bin/brandpeel.exe"],
  ["cli", "bin/brandpeel.js"],
];

for (const [directory, executable] of packages) {
  const result = spawnSync(
    process.execPath,
    [npmCli, "pack", `./packages/${directory}`, "--dry-run", "--json"],
    { encoding: "utf8", shell: false },
  );
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout)[0];
  const paths = report.files.map((file) => file.path).sort();
  assert.deepEqual(paths, ["README.md", executable, "package.json"].sort());

  if (process.platform !== "win32" && !executable.endsWith(".exe")) {
    const binary = report.files.find((file) => file.path === executable);
    assert.equal(binary.mode, 0o755, `${directory} binary must be executable`);
  }
}

console.log("Packed-file allowlists are correct for all seven npm packages.");
