import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const ciWorkflow = await readFile(".github/workflows/ci.yml", "utf8");
const releaseWorkflow = await readFile(".github/workflows/release.yml", "utf8");
const gitAttributes = await readFile(".gitattributes", "utf8");

function assertUsesSetupZigWithoutOptionalDependencies(workflow) {
  assert.match(workflow, /uses: mlugg\/setup-zig@v2/);
  assert.match(workflow, /npm ci --omit=dev --omit=optional/);
  assert.match(workflow, /run: zig build test/);
  assert.match(
    workflow,
    /run: node --test packages\/cli\/test\/\*\.test\.js test\/\*\.test\.js/,
  );
  assert.doesNotMatch(workflow, /run: npm run check/);
  assert.doesNotMatch(workflow, /run: npm test/);
}

test("CI uses setup-zig when npm platform packages are omitted", () => {
  assertUsesSetupZigWithoutOptionalDependencies(ciWorkflow);
  assert.match(ciWorkflow, /run: zig fmt --check build\.zig src/);
  assert.match(ciWorkflow, /run: zig build -Doptimize=ReleaseSafe/);
});

test("release validation uses setup-zig when npm platform packages are omitted", () => {
  assertUsesSetupZigWithoutOptionalDependencies(releaseWorkflow);
});

test("release checks npm publication before starting the build matrix", () => {
  const checkPosition = releaseWorkflow.indexOf("  release_check:");
  const buildPosition = releaseWorkflow.indexOf("  build:");

  assert.ok(checkPosition >= 0 && checkPosition < buildPosition);
  assert.match(
    releaseWorkflow,
    /release_needed: \$\{\{ steps\.check\.outputs\.release_needed \}\}/,
  );
  assert.match(
    releaseWorkflow,
    /needs: release_check\s+if: needs\.release_check\.outputs\.release_needed == 'true'/,
  );
  assert.match(
    releaseWorkflow,
    /npm view "\$\{package_name\}@\$\{version\}" version/,
  );
  for (const packagePath of [
    "packages/darwin-arm64",
    "packages/darwin-x64",
    "packages/linux-arm64",
    "packages/linux-x64",
    "packages/win32-arm64",
    "packages/win32-x64",
    "packages/cli",
  ]) {
    assert.match(releaseWorkflow, new RegExp(packagePath.replace("/", "\\/")));
  }
});

test("release publishing uses protected OIDC without an npm token", () => {
  assert.match(releaseWorkflow, /^\s{4}environment: npm-publish$/m);
  assert.match(releaseWorkflow, /^\s{6}id-token: write$/m);
  assert.doesNotMatch(releaseWorkflow, /NPM_TOKEN|NODE_AUTH_TOKEN/);
  assert.match(releaseWorkflow, /npm publish .*--provenance/);
});

test("release publishing can resume after a partial publication", () => {
  assert.match(
    releaseWorkflow,
    /npm view "\$\{package_name\}@\$\{package_version\}" version/,
  );
  assert.match(releaseWorkflow, /is already published; skipping\./);
});

test("Zig sources retain LF endings on Windows runners", () => {
  assert.match(gitAttributes, /^\*\.zig text eol=lf$/m);
  assert.match(gitAttributes, /^\*\.zig\.zon text eol=lf$/m);
});
