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

test("Zig sources retain LF endings on Windows runners", () => {
  assert.match(gitAttributes, /^\*\.zig text eol=lf$/m);
  assert.match(gitAttributes, /^\*\.zig\.zon text eol=lf$/m);
});
