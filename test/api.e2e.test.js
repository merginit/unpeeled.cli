import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { resolve } from "node:path";
import test from "node:test";

const executable = resolve(
  "zig-out",
  "bin",
  process.platform === "win32" ? "brandpeel.exe" : "brandpeel",
);

function run(arguments_) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(executable, arguments_, { shell: false });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.setEncoding("utf8").on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("exit", (status, signal) => {
      resolveResult({ status, signal, stdout, stderr });
    });
  });
}

async function withServer(handler, callback) {
  const server = createServer(handler);
  await new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolveListen);
  });
  try {
    const address = server.address();
    return await callback(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}

function apiArguments(baseUrl, ...arguments_) {
  return ["--json", "--api-base-url", baseUrl, ...arguments_];
}

test("API status errors use the network exit code and JSON envelope", async () => {
  await withServer((_request, response) => {
    response.writeHead(503, { "content-type": "application/json" });
    response.end('{"error":"unavailable"}');
  }, async (baseUrl) => {
    const result = await run(apiArguments(baseUrl, "api", "health"));
    assert.equal(result.status, 5, result.stderr);
    assert.equal(JSON.parse(result.stdout).error.code, "ApiStatus");
  });
});

test("invalid API JSON uses the network exit code", async () => {
  await withServer((_request, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end("not-json");
  }, async (baseUrl) => {
    const result = await run(apiArguments(baseUrl, "api", "health"));
    assert.equal(result.status, 5, result.stderr);
    assert.equal(JSON.parse(result.stdout).error.code, "InvalidJsonResponse");
  });
});

test("API responses larger than 4 MiB are rejected", async () => {
  const oversizedBody = JSON.stringify({ data: "x".repeat(4 * 1024 * 1024) });
  await withServer((_request, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(oversizedBody);
  }, async (baseUrl) => {
    const result = await run(apiArguments(baseUrl, "api", "health"));
    assert.equal(result.status, 5, result.stderr);
    assert.equal(JSON.parse(result.stdout).error.code, "ResponseTooLarge");
  });
});

test("API requests honor the configured timeout", async () => {
  await withServer((_request, response) => {
    setTimeout(() => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"status":"healthy"}');
    }, 1500);
  }, async (baseUrl) => {
    const startedAt = Date.now();
    const result = await run([
      "--json",
      "--api-base-url",
      baseUrl,
      "--timeout",
      "1",
      "api",
      "health",
    ]);
    assert.equal(result.status, 5, result.stderr);
    assert.equal(JSON.parse(result.stdout).error.code, "Timeout");
    assert.ok(Date.now() - startedAt < 2500);
  });
});
