import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";

const binaryName = process.platform === "win32" ? "brandpeel.exe" : "brandpeel";
const executable = resolve("zig-out", "bin", binaryName);
const fixture = resolve("test/fixtures/valid-export");
const protocolVersion = "2025-11-25";

async function temp(t) {
  await mkdir(resolve(".zig-cache"), { recursive: true });
  const directory = await mkdtemp(resolve(".zig-cache/mcp-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function client(t, args = [], command = executable) {
  const child = spawn(command, [...args, "mcp"], { shell: false, windowsHide: true });
  const closed = once(child, "close");
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const queue = [];
  let waiter;
  lines.on("line", (line) => {
    if (waiter) {
      const receive = waiter;
      waiter = undefined;
      receive(line);
    } else queue.push(line);
  });
  let id = 0;
  const api = {
    child,
    async next() {
      const line = queue.length ? queue.shift() : await new Promise((resolveLine, reject) => {
        const timer = setTimeout(() => {
          waiter = undefined;
          reject(new Error(`MCP response timeout: ${stderr}`));
        }, 10000);
        waiter = (value) => { clearTimeout(timer); resolveLine(value); };
      });
      const value = JSON.parse(line);
      Object.defineProperty(value, "wire", { value: line });
      assert.equal(value.jsonrpc, "2.0");
      if ("id" in value) assert.notEqual(value.id, null, "MCP IDs must never be null");
      return value;
    },
    send(value) { child.stdin.write(`${JSON.stringify(value)}\n`); },
    notify(method, params) { api.send({ jsonrpc: "2.0", method, ...(params ? { params } : {}) }); },
    async request(method, params) {
      const requestId = ++id;
      api.send({ jsonrpc: "2.0", id: requestId, method, ...(params === undefined ? {} : { params }) });
      const response = await api.next();
      assert.equal(response.id, requestId);
      return response;
    },
    async initialize(version = protocolVersion) {
      const response = await api.request("initialize", {
        protocolVersion: version,
        capabilities: {},
        clientInfo: { name: "brandpeel-integration-test", version: "1" },
      });
      assert.equal(response.result.protocolVersion, protocolVersion);
      assert.deepEqual(response.result.capabilities, { tools: { listChanged: false } });
      assert.equal(response.result.serverInfo.name, "brandpeel");
      api.notify("notifications/initialized");
      return response;
    },
    async call(name, arguments_ = {}) {
      const response = await api.request("tools/call", { name, arguments: arguments_ });
      assert.ok(response.result, JSON.stringify(response));
      assert.equal(typeof response.result.isError, "boolean");
      assert.equal(response.result.content[0].type, "text");
      assert.deepEqual(JSON.parse(response.result.content[0].text), response.result.structuredContent);
      return response.result;
    },
    async close() {
      if (!child.stdin.writableEnded) child.stdin.end();
      const [code, signal] = await closed;
      assert.equal(code, 0, stderr);
      assert.equal(signal, null);
      assert.equal(stderr, "");
      assert.deepEqual(queue, [], "Unexpected output or notification reply");
    },
  };
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await closed;
    lines.close();
  });
  return api;
}

async function server(t, handler) {
  const http = createServer(handler);
  http.listen(0, "127.0.0.1");
  await once(http, "listening");
  t.after(() => new Promise((done) => {
    http.closeAllConnections();
    http.close(done);
  }));
  return `http://127.0.0.1:${http.address().port}`;
}

test("MCP handshake, lifecycle, fallback negotiation and EOF", async (t) => {
  const c = client(t);
  assert.equal((await c.request("tools/list")).error.code, -32000);
  assert.deepEqual((await c.request("ping")).result, {});
  assert.equal((await c.request("initialize", {})).error.code, -32602);
  const init = await c.initialize("unknown-future-version");
  const version = spawnSync(executable, ["--version"], { encoding: "utf8", shell: false });
  assert.equal(`brandpeel ${init.result.serverInfo.version}\n`, version.stdout);
  assert.equal((await c.request("initialize", {})).error.code, -32600);
  c.notify("notifications/unknown");
  c.notify("tools/call", { name: "doctor", arguments: { directory: fixture } });
  c.send({ jsonrpc: "2.0", id: 999, result: {} });
  assert.deepEqual((await c.request("ping")).result, {});
  await c.close();
});

test("MCP requires the initialized notification before tool execution", async (t) => {
  const c = client(t);
  await c.request("initialize", { protocolVersion, capabilities: {}, clientInfo: { name: "test", version: "1" } });
  assert.equal((await c.request("tools/list")).error.code, -32000);
  c.notify("notifications/initialized");
  assert.equal((await c.request("tools/list")).result.tools.length, 11);
  await c.close();
});

test("MCP catalog exposes all commands with closed, typed schemas and honest annotations", async (t) => {
  const c = client(t);
  await c.initialize();
  const { tools } = (await c.request("tools/list")).result;
  const expected = {
    inspect: ["directory"], doctor: ["directory", "strict"],
    export: ["input", "format", "output", "force"], compile_book: ["directory", "output", "force"],
    api_health: ["detail"], api_release: ["platform", "channel"], api_tools: ["category", "query"],
    api_tool: ["slug"], api_schema: ["version"], api_agent_info: ["include"], api_cli_manifest: ["platform"],
  };
  assert.deepEqual(tools.map((tool) => tool.name).sort(), Object.keys(expected).sort());
  for (const tool of tools) {
    assert.ok(tool.description.length > 20);
    assert.equal(tool.inputSchema.type, "object");
    assert.equal(tool.inputSchema.additionalProperties, false);
    assert.deepEqual(Object.keys(tool.inputSchema.properties), expected[tool.name]);
    assert.equal(tool.annotations.readOnlyHint, !["export", "compile_book"].includes(tool.name));
    assert.equal(tool.annotations.openWorldHint, tool.name.startsWith("api_"));
    for (const [name, schema] of Object.entries(tool.inputSchema.properties)) {
      assert.equal(schema.type, ["force", "strict"].includes(name) ? "boolean" : "string");
      assert.ok(schema.description);
    }
    for (const name of tool.inputSchema.required) assert.ok(tool.inputSchema.properties[name]);
    assert.equal((await c.call(tool.name, { unexpected: true })).isError, true);
  }
  assert.deepEqual(tools.find((tool) => tool.name === "export").inputSchema.required, ["input", "format"]);
  assert.deepEqual(tools.find((tool) => tool.name === "api_tool").inputSchema.required, ["slug"]);
  assert.equal((await c.request("tools/list", { cursor: "not-a-cursor" })).error.code, -32602);
  await c.close();
});

test("MCP local tools return the same data as the CLI, including all export formats", async (t) => {
  const c = client(t);
  await c.initialize();
  const cases = [
    ["inspect", { directory: fixture }, ["inspect", fixture]],
    ["doctor", { directory: fixture, strict: true }, ["doctor", fixture, "--strict"]],
    ["compile_book", { directory: fixture }, ["compile-book", fixture]],
    ...["css", "tailwind-v4", "json", "typescript"].map((format) => ["export", { input: join(fixture, "theme.json"), format }, ["export", join(fixture, "theme.json"), "--format", format]]),
  ];
  for (const [name, args, cliArgs] of cases) {
    const value = await c.call(name, args);
    assert.equal(value.isError, false);
    const cli = spawnSync(executable, ["--json", ...cliArgs], { encoding: "utf8", shell: false });
    assert.equal(cli.status, 0, cli.stderr);
    assert.deepEqual(value.structuredContent, JSON.parse(cli.stdout));
  }
  await c.close();
});

test("MCP validates arguments and paths; tool failures leave the session usable", async (t) => {
  const c = client(t);
  await c.initialize();
  for (const [name, args] of [
    ["inspect", {}], ["inspect", { directory: "." }], ["inspect", { directory: "C:relative" }],
    ["inspect", { directory: `${fixture}\0hidden` }], ["inspect", { directory: 42 }],
    ["doctor", { directory: fixture, strict: "true" }],
    ["export", { input: fixture, format: "sass" }],
    ["export", { input: fixture, format: "css", output: "relative.css" }],
    ["export", { input: fixture, format: "css", force: true }],
    ["api_health", { detail: "bad" }], ["api_release", { platform: "freebsd" }],
    ["api_schema", { version: "2.0.0" }], ["api_agent_info", { include: "private" }],
    ["api_tool", { slug: "" }], ["api_tools", { query: "x".repeat(4097) }],
  ]) {
    const value = await c.call(name, args);
    assert.equal(value.isError, true, `${name} ${JSON.stringify(args)}`);
    assert.equal(value.structuredContent.error.code, "INVALID_ARGUMENTS");
  }
  const missing = await c.call("doctor", { directory: resolve("test/fixtures/missing") });
  assert.equal(missing.isError, true);
  assert.equal(missing.structuredContent.error.code, "DOCTOR_FAILED");
  assert.deepEqual((await c.request("ping")).result, {});
  assert.equal((await c.call("inspect", { directory: fixture })).isError, false);
  await c.close();
});

test("MCP preserves corrupt export validation and strict contrast failure details", async (t) => {
  const directory = join(await temp(t), "export");
  await cp(fixture, directory, { recursive: true });
  const c = client(t);
  await c.initialize();
  const path = join(directory, "theme.json");
  const theme = JSON.parse(await readFile(path, "utf8"));
  theme.light.foreground = theme.light.background;
  await writeFile(path, JSON.stringify(theme));
  assert.equal((await c.call("doctor", { directory })).isError, false);
  const strict = await c.call("doctor", { directory, strict: true });
  assert.equal(strict.isError, true);
  assert.ok(strict.structuredContent.error.details.aaFailures > 0);
  await writeFile(join(directory, ".brand-peel-export.json"), "{}");
  assert.equal((await c.call("inspect", { directory })).structuredContent.error.code, "InvalidMarker");
  await writeFile(path, "not json");
  assert.equal((await c.call("export", { input: directory, format: "css" })).isError, true);
  const nested = '{"light":{"background":' + "[".repeat(300) + "0" + "]".repeat(300) + '},"dark":{}}';
  await writeFile(path, nested);
  for (const format of ["css", "tailwind-v4", "json", "typescript"]) {
    const failure = await c.call("export", { input: directory, format });
    assert.equal(failure.isError, true);
    assert.equal(failure.structuredContent.error.code, "InvalidTheme");
    const direct = spawnSync(executable, ["--json", "export", directory, "--format", format], { encoding: "utf8", shell: false });
    assert.equal(direct.status, 3, direct.stderr);
    assert.equal(JSON.parse(direct.stdout).error.code, "InvalidTheme");
  }
  assert.deepEqual((await c.request("ping")).result, {});
  await c.close();
});

test("MCP file output is explicit and overwrite requires force", async (t) => {
  const directory = await temp(t);
  const c = client(t);
  await c.initialize();
  for (const [name, args, filename] of [
    ["export", { input: fixture, format: "css" }, "tokens.css"],
    ["compile_book", { directory: fixture }, "BRAND.md"],
  ]) {
    const output = join(directory, filename);
    assert.equal((await c.call(name, { ...args, output })).isError, false);
    await writeFile(output, "keep this existing file");
    const conflict = await c.call(name, { ...args, output });
    assert.equal(conflict.isError, true);
    assert.equal(conflict.structuredContent.error.code, "PathAlreadyExists");
    assert.equal(await readFile(output, "utf8"), "keep this existing file");
    assert.equal((await c.call(name, { ...args, output, force: true })).isError, false);
    assert.notEqual(await readFile(output, "utf8"), "keep this existing file");
  }
  await c.close();
});

test("MCP API tools map all seven operations and correctly encode inputs", async (t) => {
  const base = await server(t, (request, response) => {
    assert.equal(request.method, "GET");
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ url: request.url }, null, 2));
  });
  const c = client(t, ["--api-base-url", base]);
  await c.initialize();
  const cases = [
    ["api_health", { detail: "status" }, "/api/v1/health?detail=status"],
    ["api_release", { platform: "linux", channel: "beta" }, "/api/v1/release/latest?platform=linux&channel=beta"],
    ["api_tools", { category: "Design System", query: "color & type" }, "/api/v1/tools?category=Design%20System&q=color%20%26%20type"],
    ["api_tool", { slug: "test/space ?é" }, "/api/v1/tools/test%2Fspace%20%3F%C3%A9"],
    ["api_schema", { version: "1.0.0" }, "/api/v1/brand-guide/schema?version=1.0.0"],
    ["api_agent_info", { include: "functions" }, "/api/v1/agent-info?include=functions"],
    ["api_cli_manifest", { platform: "windows" }, "/api/v1/cli/manifest?platform=windows"],
  ];
  for (const [name, args, url] of cases) {
    const value = await c.call(name, args);
    assert.equal(value.isError, false, JSON.stringify(value));
    assert.equal(value.structuredContent.data.url, url);
  }
  const noArgs = await c.request("tools/call", { name: "api_health" });
  assert.equal(noArgs.result.structuredContent.data.url, "/api/v1/health");
  await c.close();
});

test("MCP API timeout, size, status, invalid JSON and redirects remain bounded", async (t) => {
  let mode = "status";
  const base = await server(t, (_request, response) => {
    if (mode === "timeout") return;
    if (mode === "redirect") {
      response.writeHead(302, { location: "/api/v1/health" });
      return response.end();
    }
    response.writeHead(mode === "status" ? 503 : 200, { "content-type": "application/json" });
    response.end(mode === "invalid" ? "not-json" : mode === "size" ? JSON.stringify({ data: "x".repeat(4 * 1024 * 1024) }) : '{"status":"ok"}');
  });
  const c = client(t, ["--api-base-url", base, "--timeout", "1"]);
  await c.initialize();
  for (const [failureMode, code] of [["status", "ApiStatus"], ["invalid", "InvalidJsonResponse"], ["size", "ResponseTooLarge"], ["timeout", "Timeout"], ["redirect", null]]) {
    mode = failureMode;
    const value = await c.call("api_health");
    assert.equal(value.isError, true, failureMode);
    if (code) assert.equal(value.structuredContent.error.code, code);
    assert.deepEqual((await c.request("ping")).result, {});
  }
  mode = "success";
  assert.equal((await c.call("api_health")).isError, false);
  await c.close();
});

test("MCP rejects insecure API origins without terminating", async (t) => {
  const c = client(t, ["--api-base-url", "http://example.com"]);
  await c.initialize();
  assert.equal((await c.call("api_health")).structuredContent.error.code, "InsecureBaseUrl");
  assert.deepEqual((await c.request("ping")).result, {});
  await c.close();
});

test("MCP ping remains responsive during API work and overlapping tool calls are bounded", async (t) => {
  let releaseResponse;
  let receivedRequest;
  const received = new Promise((resolveRequest) => { receivedRequest = resolveRequest; });
  const base = await server(t, (_request, response) => {
    releaseResponse = () => response.end('{"status":"ok"}');
    receivedRequest();
  });
  const c = client(t, ["--api-base-url", base]);
  await c.initialize();
  c.send({ jsonrpc: "2.0", id: 900, method: "tools/call", params: { name: "api_health" } });
  await received;
  const start = Date.now();
  assert.deepEqual((await c.request("ping")).result, {});
  assert.ok(Date.now() - start < 1000, "Ping waited for the unfinished API request");
  assert.equal((await c.request("tools/list")).result.tools.length, 11);
  const busy = await c.request("tools/call", { name: "inspect", arguments: { directory: fixture } });
  assert.equal(busy.error.code, -32000);
  releaseResponse();
  const completed = await c.next();
  assert.equal(completed.id, 900);
  assert.equal(completed.result.isError, false);
  assert.equal((await c.call("inspect", { directory: fixture })).isError, false);
  await c.close();
});

test("MCP EOF waits for an active tool and flushes its response before exit", async (t) => {
  const base = await server(t, (_request, response) => {
    setTimeout(() => response.end('{"status":"ok"}'), 100);
  });
  const c = client(t, ["--api-base-url", base]);
  await c.initialize();
  c.send({ jsonrpc: "2.0", id: 901, method: "tools/call", params: { name: "api_health" } });
  c.child.stdin.end();
  const response = await c.next();
  assert.equal(response.id, 901);
  assert.equal(response.result.isError, false);
  await c.close();
});

test("MCP malformed frames, invalid IDs and errors recover without stdout contamination", async (t) => {
  const c = client(t);
  await c.initialize();
  for (const [frame, code] of [
    ["not-json", -32700], ["", -32700], ["[]", -32600],
    ['{"jsonrpc":"1.0","id":1,"method":"ping"}', -32600],
    ['{"jsonrpc":"2.0","id":null,"method":"ping"}', -32600],
    ['{"jsonrpc":"2.0","id":1.5,"method":"ping"}', -32600],
    ['{"jsonrpc":"2.0","id":1,"method":7}', -32600],
    ['{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}', -32700],
    ["[".repeat(65) + "]".repeat(65), -32600],
    [" ".repeat(1024 * 1024 + 1), -32600],
  ]) {
    c.child.stdin.write(`${frame}\n`);
    assert.equal((await c.next()).error.code, code);
  }
  for (const [method, params, code] of [
    ["unknown", {}, -32601], ["tools/call", [], -32602],
    ["tools/call", { name: "not_a_tool" }, -32602],
    ["tools/call", { name: "inspect", arguments: [] }, -32602],
    ["tools/call", { name: "inspect", task: {} }, -32602],
  ]) assert.equal((await c.request(method, params)).error.code, code);
  c.child.stdin.write('{"jsonrpc":"2.0","id":"string-id","method":"pi');
  c.child.stdin.write('ng"}\r\n');
  assert.equal((await c.next()).id, "string-id");
  c.child.stdin.write('{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}\n');
  // Number is intentionally beyond JS safe-integer precision; preserve the wire spelling.
  assert.match((await c.next()).wire, /"id":9007199254740993[,}]/);
  assert.deepEqual((await c.request("ping")).result, {});
  await c.close();
});

test("MCP multiple requests stay usable and bounded across a long-lived connection", async (t) => {
  const c = client(t);
  await c.initialize();
  for (let i = 0; i < 200; i++) {
    assert.equal((await c.call("inspect", { directory: fixture })).isError, false);
  }
  await c.close();
});

test("MCP EOF rejects a partial frame and clean EOF emits nothing", () => {
  const partial = spawnSync(executable, ["mcp"], { input: '{"jsonrpc":', encoding: "utf8", shell: false, timeout: 5000 });
  assert.equal(partial.status, 0, partial.stderr);
  assert.equal(JSON.parse(partial.stdout).error.code, -32700);
  const empty = spawnSync(executable, ["mcp"], { input: "", encoding: "utf8", shell: false, timeout: 5000 });
  assert.equal(empty.status, 0, empty.stderr);
  assert.equal(empty.stdout, "");
  for (const args of [["--json", "mcp"], ["mcp", "unexpected"]]) {
    const invalid = spawnSync(executable, args, { encoding: "utf8", shell: false, timeout: 5000 });
    assert.equal(invalid.status, 2);
    assert.equal(invalid.stdout, "");
    assert.match(invalid.stderr, /mcp accepts/);
  }
});

test("MCP works through the real npm launcher and native package resolution", async (t) => {
  const directory = await temp(t);
  const wrapper = join(directory, "node_modules/@merginit/brandpeel");
  const native = join(directory, `node_modules/@merginit/brandpeel-${process.platform}-${process.arch}`);
  await mkdir(join(wrapper, "bin"), { recursive: true });
  await mkdir(join(native, "bin"), { recursive: true });
  await copyFile("packages/cli/package.json", join(wrapper, "package.json"));
  await copyFile("packages/cli/bin/brandpeel.js", join(wrapper, "bin/brandpeel.js"));
  await copyFile(`packages/${process.platform}-${process.arch}/package.json`, join(native, "package.json"));
  await copyFile(executable, join(native, "bin", binaryName));
  const c = client(t, [join(wrapper, "bin/brandpeel.js")], process.execPath);
  await c.initialize();
  assert.equal((await c.request("tools/list")).result.tools.length, 11);
  assert.equal((await c.call("doctor", { directory: fixture, strict: true })).isError, false);
  assert.equal((await c.call("doctor", { directory: "." })).isError, true);
  await c.close();
});
