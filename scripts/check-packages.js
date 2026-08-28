import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const targets = [
  ["darwin", "arm64"],
  ["darwin", "x64"],
  ["linux", "arm64"],
  ["linux", "x64"],
  ["win32", "arm64"],
  ["win32", "x64"],
];

for (const [os, cpu] of targets) {
  const manifest = JSON.parse(
    await readFile(`packages/${os}-${cpu}/package.json`, "utf8"),
  );
  assert.equal(manifest.name, `@merginit/brandpeel-${os}-${cpu}`);
  assert.deepEqual(manifest.os, [os]);
  assert.deepEqual(manifest.cpu, [cpu]);
  assert.deepEqual(manifest.files, ["bin", "README.md"]);
  assert.equal(manifest.publishConfig.access, "public");
  assert.equal(manifest.publishConfig.provenance, true);
}

const wrapper = JSON.parse(await readFile("packages/cli/package.json", "utf8"));
assert.equal(wrapper.name, "@merginit/brandpeel");
assert.equal(wrapper.bin.brandpeel, "bin/brandpeel.js");
assert.deepEqual(wrapper.files, ["bin", "README.md"]);
assert.deepEqual(
  Object.keys(wrapper.optionalDependencies).sort(),
  targets.map(([os, cpu]) => `@merginit/brandpeel-${os}-${cpu}`).sort(),
);
for (const version of Object.values(wrapper.optionalDependencies)) {
  assert.equal(version, wrapper.version);
}

const cliSource = await readFile("src/cli.zig", "utf8");
const apiSource = await readFile("src/api.zig", "utf8");
const zon = await readFile("build.zig.zon", "utf8");
const escapedVersion = wrapper.version.replaceAll(".", "\\.");
assert.match(
  cliSource,
  new RegExp(`pub const version = "${escapedVersion}";`),
);
assert.match(apiSource, new RegExp(`brandpeel-cli/${escapedVersion}`));
assert.match(zon, new RegExp(`\\.version = "${escapedVersion}"`));

console.log("Wrapper and native package manifests are consistent.");
