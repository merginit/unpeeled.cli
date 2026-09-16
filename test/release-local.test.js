import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const script = await readFile("scripts/release-local.js", "utf8");
const manifest = JSON.parse(await readFile("package.json", "utf8"));

test("local release command is wired into the workspace", () => {
  assert.equal(manifest.scripts["release:local"], "node scripts/release-local.js");
});

test("local release stages, validates and publishes the complete package set", () => {
  assert.match(script, /git",\s*\["describe", "--tags"/);
  assert.match(script, /\["view",/);
  assert.match(script, /\["clone", "--local", "--no-hardlinks"/);
  assert.match(script, /scripts\/assemble-release\.js/);
  assert.match(script, /npmCommand,\s*\[\s*"publish"/);
  assert.match(script, /--provenance=false/);
  assert.match(script, /mkdtemp\(join\(tmpdir\(\), "brandpeel-release-"\)\)/);
});
