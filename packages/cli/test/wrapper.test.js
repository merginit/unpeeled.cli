import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";

const packageJsonUrl = new URL("../package.json", import.meta.url);
const wrapperUrl = new URL("../bin/brandpeel.js", import.meta.url);

test("wrapper exposes the brandpeel executable", async () => {
  const manifest = JSON.parse(await readFile(packageJsonUrl, "utf8"));
  assert.equal(manifest.bin.brandpeel, "bin/brandpeel.js");
  assert.equal(manifest.publishConfig.access, "public");
  assert.equal(manifest.publishConfig.provenance, true);
});

test("wrapper declares all supported optional packages at an exact version", async () => {
  const manifest = JSON.parse(await readFile(packageJsonUrl, "utf8"));
  const expected = [
    "darwin-arm64",
    "darwin-x64",
    "linux-arm64",
    "linux-x64",
    "win32-arm64",
    "win32-x64",
  ];
  assert.deepEqual(
    Object.keys(manifest.optionalDependencies).sort(),
    expected.map((target) => `@merginit/brandpeel-${target}`).sort(),
  );
  for (const version of Object.values(manifest.optionalDependencies)) {
    assert.equal(version, manifest.version);
  }
});

test("wrapper never enables shell execution", async () => {
  const source = await readFile(wrapperUrl, "utf8");
  assert.match(source, /shell: false/);
  assert.doesNotMatch(source, /shell:\s*process\.platform/);
});

test("wrapper reports unsupported platforms without invoking a shell", () => {
  const result = spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "--eval",
      `Object.defineProperty(process, "platform", { value: "freebsd" }); await import(${JSON.stringify(wrapperUrl.href)});`,
    ],
    { encoding: "utf8", shell: false },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /does not provide a binary for freebsd/);
});

test("wrapper contains explicit signal and exit-code propagation", async () => {
  const source = await readFile(wrapperUrl, "utf8");
  assert.match(source, /child\.kill\(signal\)/);
  assert.match(source, /process\.kill\(process\.pid, signal\)/);
  assert.match(source, /process\.exit\(code \?\? 1\)/);
});
