import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const executable = resolve(
  "zig-out",
  "bin",
  process.platform === "win32" ? "brandpeel.exe" : "brandpeel",
);
const fixture = resolve("test", "fixtures", "valid-export");

function run(arguments_) {
  return spawnSync(executable, arguments_, { encoding: "utf8" });
}

test("inspect emits a stable JSON envelope for a real desktop export", () => {
  const result = run(["--json", "inspect", fixture]);
  assert.equal(result.status, 0, result.stderr);
  const payload = JSON.parse(result.stdout);
  assert.equal(payload.ok, true);
  assert.equal(payload.command, "inspect");
  assert.equal(payload.data.projectId, "fixture-project");
  assert.equal(payload.data.valid, true);
});

test("strict doctor passes reference WCAG pairs", () => {
  const result = run(["--json", "doctor", fixture, "--strict"]);
  assert.equal(result.status, 0, result.stderr);
  const payload = JSON.parse(result.stdout);
  assert.equal(payload.data.aaFailures, 0);
  assert.equal(payload.data.missingPairs, 0);
  assert.ok(payload.data.contrasts.length > 0);
  assert.ok(payload.data.contrasts.every((contrast) => contrast.aa));
  assert.ok(payload.data.contrasts.every((contrast) => typeof contrast.aaa === "boolean"));
});

test("all token export formats produce deterministic content", () => {
  for (const format of ["css", "tailwind-v4", "json", "typescript"]) {
    const first = run(["export", fixture, "--format", format]);
    const second = run(["export", fixture, "--format", format]);
    assert.equal(first.status, 0, first.stderr);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(first.stdout, second.stdout);
    assert.ok(first.stdout.length > 100);
  }
});

test("compiled book has one H1 and source H2 headings", () => {
  const result = run(["compile-book", fixture]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.match(/^# /gmu)?.length, 1);
  assert.match(result.stdout, /^## Identity$/mu);
  assert.match(result.stdout, /^## Visual Identity$/mu);
  assert.match(result.stdout, /^## Guidelines$/mu);
});

test("output refuses overwrite unless force is supplied", async () => {
  const directory = await mkdtemp(join(tmpdir(), "brandpeel-cli-test-"));
  try {
    const output = join(directory, "tokens.css");
    const first = run(["export", fixture, "--format", "css", "-o", output]);
    assert.equal(first.status, 0, first.stderr);
    const second = run(["export", fixture, "--format", "css", "-o", output]);
    assert.equal(second.status, 4);
    const third = run([
      "export",
      fixture,
      "--format",
      "css",
      "-o",
      output,
      "--force",
    ]);
    assert.equal(third.status, 0, third.stderr);
    assert.match(await readFile(output, "utf8"), /--background/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("doctor fails missing exports with the validation exit code", () => {
  const result = run(["--json", "doctor", resolve("test", "fixtures", "missing")]);
  assert.equal(result.status, 3);
  assert.equal(JSON.parse(result.stdout).error.code, "DOCTOR_FAILED");
});
