//! MCP 2025-11-25 stdio adapter. No shell, HTTP listener, or runtime dependencies.
const std = @import("std");
const cli = @import("cli.zig");
const tools = @import("mcp_tools.zig");
const Value = std.json.Value;

pub const protocol_version = "2025-11-25";
pub const max_request_size = 1024 * 1024;
pub const max_request_memory = 256 * 1024 * 1024;
const max_control_memory = 64 * 1024 * 1024;
const max_json_depth = 64;

const State = enum { fresh, initializing, ready };

fn get(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}

fn stringIs(value: ?Value, expected: []const u8) bool {
    const item = value orelse return false;
    return item == .string and std.mem.eql(u8, item.string, expected);
}

fn isString(value: ?Value) bool {
    const item = value orelse return false;
    return item == .string;
}

fn isObject(value: ?Value) bool {
    const item = value orelse return false;
    return item == .object;
}

fn validId(value: Value) bool {
    return switch (value) {
        .string, .integer => true,
        // Preserve arbitrarily large integer IDs without floating-point rounding.
        .number_string => std.mem.indexOfAny(u8, value.number_string, ".eE") == null,
        else => false,
    };
}

/// Check nesting before recursive serialization. The JSON parser still validates syntax.
fn depthAllowed(bytes: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_json_depth) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

fn rpcError(writer: *std.Io.Writer, id: Value, code: i32, message: []const u8) !void {
    // MCP 2025-11-25 omits unreadable IDs in errors; its RequestId excludes null.
    const response_id: ?Value = if (id == .null) null else id;
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = response_id, .@"error" = .{ .code = code, .message = message } }, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

fn result(writer: *std.Io.Writer, id: Value, payload: anytype) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .result = payload }, .{}, writer);
    try writer.writeByte('\n');
}

fn toolError(writer: *std.Io.Writer, id: Value, code: []const u8, message: []const u8) !void {
    const payload = .{ .ok = false, .@"error" = .{ .code = code, .message = message } };
    // Error reporting must still work when the request allocator is exhausted.
    var text_buffer: [2048]u8 = undefined;
    var text = std.Io.Writer.fixed(&text_buffer);
    try std.json.Stringify.value(payload, .{}, &text);
    try result(writer, id, .{
        .content = .{.{ .type = "text", .text = text.buffered() }},
        .structuredContent = payload,
        .isError = true,
    });
}

pub const Session = struct {
    state: State = .fresh,

    pub fn handle(self: *Session, allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, options: cli.Options, bytes: []const u8) !void {
        if (!depthAllowed(bytes)) return rpcError(writer, .null, -32600, "JSON nesting exceeds 64 levels.");
        const parsed = std.json.parseFromSlice(Value, allocator, bytes, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| {
            return rpcError(writer, .null, if (err == error.OutOfMemory) @as(i32, -32603) else -32700, "Unable to parse JSON request within server limits.");
        };
        defer parsed.deinit();
        const request = parsed.value;
        if (request != .object or !stringIs(get(request, "jsonrpc"), "2.0")) return rpcError(writer, .null, -32600, "Expected one JSON-RPC 2.0 object (batches are not supported).");
        const id = get(request, "id");
        const readable_id = if (id != null and validId(id.?)) id.? else Value.null;
        const method = get(request, "method");
        // This server sends no requests. Ignore unsolicited responses, never reply to them.
        if (method == null and id != null and (get(request, "result") != null or get(request, "error") != null)) return;
        if (!isString(method) or get(request, "result") != null or get(request, "error") != null) return rpcError(writer, readable_id, -32600, "Invalid JSON-RPC request.");
        if (id) |request_id| {
            if (!validId(request_id)) return rpcError(writer, .null, -32600, "Request IDs must be strings or integers, never null.");
        }
        const params = get(request, "params");
        if (id == null) {
            // Notifications must never produce a reply or execute a tool.
            if ((params == null or isObject(params)) and stringIs(method, "notifications/initialized") and self.state == .initializing) self.state = .ready;
            return;
        }
        const request_id = id.?;
        if (params != null and !isObject(params)) return rpcError(writer, request_id, -32602, "params must be an object.");
        if (params) |p| {
            if (get(p, "_meta") != null and !isObject(get(p, "_meta"))) return rpcError(writer, request_id, -32602, "_meta must be an object.");
        }
        if (stringIs(method, "ping")) return result(writer, request_id, struct {}{});
        if (stringIs(method, "initialize")) {
            if (self.state != .fresh) return rpcError(writer, request_id, -32600, "This connection has already been initialized.");
            const p = params orelse return rpcError(writer, request_id, -32602, "initialize requires parameters.");
            const client = get(p, "clientInfo") orelse return rpcError(writer, request_id, -32602, "initialize requires clientInfo.");
            if (!isString(get(p, "protocolVersion")) or !isObject(get(p, "capabilities")) or !isString(get(client, "name")) or !isString(get(client, "version"))) {
                return rpcError(writer, request_id, -32602, "initialize requires protocolVersion, capabilities and clientInfo name/version.");
            }
            try result(writer, request_id, .{
                .protocolVersion = protocol_version,
                .capabilities = .{ .tools = .{ .listChanged = false } },
                .serverInfo = .{ .name = "brandpeel", .version = cli.version },
                .instructions = "Brand Peel tools inspect local exports, generate design tokens or a brand book, and read the public API. Local paths must be absolute. Output is returned unless a destination is supplied; existing files require force=true.",
            });
            self.state = .initializing;
            return;
        }
        if (self.state != .ready) return rpcError(writer, request_id, -32000, "Complete initialize and notifications/initialized before calling tools.");
        if (stringIs(method, "tools/list")) {
            if (params) |p| {
                if (get(p, "cursor") != null) return rpcError(writer, request_id, -32602, "Invalid cursor; all tools are returned in one page.");
            }
            try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
            try std.json.Stringify.value(request_id, .{}, writer);
            try writer.writeAll(",\"result\":");
            try tools.writeList(writer);
            try writer.writeAll("}\n");
            return;
        }
        if (!stringIs(method, "tools/call")) return rpcError(writer, request_id, -32601, "Method not found.");
        const p = params orelse return rpcError(writer, request_id, -32602, "tools/call requires parameters.");
        if (!isString(get(p, "name"))) return rpcError(writer, request_id, -32602, "tools/call requires a tool name.");
        if (get(p, "task") != null) return rpcError(writer, request_id, -32602, "Task-augmented execution is not supported.");
        const tool = tools.find(get(p, "name").?.string) orelse return rpcError(writer, request_id, -32602, "Unknown tool.");
        const arguments = get(p, "arguments") orelse Value{ .object = .empty };
        if (arguments != .object) return rpcError(writer, request_id, -32602, "arguments must be an object.");
        if (tools.validate(tool, arguments.object)) |message| return toolError(writer, request_id, "INVALID_ARGUMENTS", message);

        const invocation = invoke(allocator, io, options, tool, arguments.object) catch |err| {
            return toolError(writer, request_id, if (err == error.OutOfMemory) "RESOURCE_LIMIT" else "INTERNAL", if (err == error.OutOfMemory) "Tool exceeded the per-request memory limit." else "Tool failed unexpectedly.");
        };
        try result(writer, request_id, .{
            .content = .{.{ .type = "text", .text = invocation.text }},
            .structuredContent = invocation.payload,
            .isError = invocation.failed,
        });
    }
};

fn invoke(allocator: std.mem.Allocator, io: std.Io, options: cli.Options, tool: tools.Tool, arguments: std.json.ObjectMap) !struct { text: []const u8, payload: Value, failed: bool } {
    var captured: std.Io.Writer.Allocating = .init(allocator);
    defer captured.deinit();
    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();
    var context: cli.Context = .{ .allocator = allocator, .io = io, .stdout = &captured.writer, .stderr = &diagnostics.writer, .options = options };
    context.options.json = true;
    const args = try tools.commandArguments(allocator, tool, arguments);
    const status = try cli.runCommand(&context, tool.command, args);
    if (!depthAllowed(captured.written())) return error.ResultNestingLimit;
    const parsed = try std.json.parseFromSlice(Value, allocator, captured.written(), .{ .allocate = .alloc_always });
    // Owned by the per-request allocator; retained through response serialization.
    const text = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    return .{ .text = text, .payload = parsed.value, .failed = status != 0 };
}

/// One bounded tool worker keeps control messages responsive during network I/O.
/// All stdout access (including flush) is protected to prevent interleaved frames.
const ToolWorker = struct {
    io: std.Io,
    writer: *std.Io.Writer,
    mutex: *std.Io.Mutex,
    options: cli.Options,
    allocator: std.mem.Allocator,
    bytes: []const u8 = "",
    id: Value = .null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ToolWorker) anyerror!void {
        defer self.done.store(true, .release);
        var response: std.Io.Writer.Allocating = .init(self.allocator);
        defer response.deinit();
        var session: Session = .{ .state = .ready };
        session.handle(self.allocator, self.io, &response.writer, self.options, self.bytes) catch {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try toolError(self.writer, self.id, "RESOURCE_LIMIT", "Unable to encode the tool response within the request memory limit.");
            try self.writer.flush();
            self.done.store(true, .release);
            return;
        };
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.writer.writeAll(response.written());
        try self.writer.flush();
        self.done.store(true, .release);
    }
};

fn copyId(allocator: std.mem.Allocator, id: Value) !Value {
    return switch (id) {
        .string => .{ .string = try allocator.dupe(u8, id.string) },
        .number_string => .{ .number_string = try allocator.dupe(u8, id.number_string) },
        else => id,
    };
}

fn dispatchFrame(session: *Session, scratch: *std.heap.FixedBufferAllocator, worker_scratch: *std.heap.FixedBufferAllocator, worker: *ToolWorker, future: *?std.Io.Future(anyerror!void), bytes: []const u8) !void {
    const io = worker.io;
    try worker.mutex.lock(io);
    defer worker.mutex.unlock(io);
    if (future.* != null and worker.done.load(.acquire)) {
        try future.*.?.await(io);
        future.* = null;
    }
    scratch.reset();
    const allocator = scratch.allocator();
    if (session.state == .ready and depthAllowed(bytes)) {
        const parsed = std.json.parseFromSlice(Value, allocator, bytes, .{ .allocate = .alloc_always, .parse_numbers = false }) catch {
            scratch.reset();
            try session.handle(allocator, io, worker.writer, worker.options, bytes);
            try worker.writer.flush();
            return;
        };
        defer parsed.deinit();
        const request = parsed.value;
        const id = get(request, "id");
        if (stringIs(get(request, "jsonrpc"), "2.0") and stringIs(get(request, "method"), "tools/call") and id != null and validId(id.?) and get(request, "result") == null and get(request, "error") == null) {
            if (future.* != null) {
                try rpcError(worker.writer, id.?, -32000, "A tool call is already in progress; retry after it completes.");
            } else {
                worker_scratch.reset();
                worker.bytes = try worker.allocator.dupe(u8, bytes);
                worker.id = try copyId(worker.allocator, id.?);
                worker.done.store(false, .release);
                future.* = std.Io.concurrent(io, ToolWorker.run, .{worker}) catch {
                    try rpcError(worker.writer, id.?, -32603, "Tool execution is temporarily unavailable.");
                    try worker.writer.flush();
                    return;
                };
            }
            try worker.writer.flush();
            return;
        }
    }
    try session.handle(allocator, io, worker.writer, worker.options, bytes);
    try worker.writer.flush();
}

pub fn serve(io: std.Io, writer: *std.Io.Writer, options: cli.Options) !void {
    const allocator = std.heap.page_allocator;
    const line = try allocator.alloc(u8, max_request_size);
    defer allocator.free(line);
    // Reused, bounded scratch space: no request allocations survive the next frame.
    const memory = try allocator.alloc(u8, max_request_memory);
    defer allocator.free(memory);
    var worker_scratch = std.heap.FixedBufferAllocator.init(memory);
    const control_memory = try allocator.alloc(u8, max_control_memory);
    defer allocator.free(control_memory);
    var scratch = std.heap.FixedBufferAllocator.init(control_memory);
    var mutex: std.Io.Mutex = .init;
    var worker: ToolWorker = .{ .io = io, .writer = writer, .mutex = &mutex, .options = options, .allocator = worker_scratch.allocator() };
    var future: ?std.Io.Future(anyerror!void) = null;
    // Keep worker storage alive until any in-flight request finishes, including EOF.
    defer if (future) |*active| active.await(io) catch {};
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &input_buffer);
    var session: Session = .{};
    var length: usize = 0;
    var oversized = false;
    while (true) {
        const byte = input.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (future) |*active| {
                    try active.await(io);
                    future = null;
                }
                if (length != 0 or oversized) {
                    try rpcError(writer, .null, -32700, "Incomplete newline-delimited message at EOF.");
                    try writer.flush();
                }
                return;
            },
            else => return err,
        };
        if (byte == '\n') {
            if (oversized) {
                try mutex.lock(io);
                defer mutex.unlock(io);
                try rpcError(writer, .null, -32600, "Request exceeds 1 MiB.");
                try writer.flush();
            } else {
                try dispatchFrame(&session, &scratch, &worker_scratch, &worker, &future, line[0..length]);
            }
            length = 0;
            oversized = false;
        } else if (length < line.len) {
            line[length] = byte;
            length += 1;
        } else {
            // Drain the rest of this frame so the next valid request can recover.
            oversized = true;
        }
    }
}

test "JSON depth guard respects strings and escapes" {
    try std.testing.expect(depthAllowed("{\"text\":\"[\\\"{\"}"));
    try std.testing.expect(!depthAllowed("[" ** 65));
}

test "request IDs reject null and preserve integer spelling" {
    try std.testing.expect(!validId(.null));
    try std.testing.expect(!validId(.{ .number_string = "1.5" }));
    try std.testing.expect(validId(.{ .number_string = "9007199254740993" }));
}

test "request allocator exhaustion returns a protocol error and the next frame recovers" {
    var memory: [4096]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&memory);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var session: Session = .{};
    const large = "{\"jsonrpc\":\"2.0\",\"id\":\"" ++ "x" ** 4096 ++ "\",\"method\":\"ping\"}";
    try session.handle(scratch.allocator(), std.testing.io, &output.writer, .{}, large);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"code\":-32603") != null);
    scratch.reset();
    try session.handle(scratch.allocator(), std.testing.io, &output.writer, .{}, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}");
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n"));
}

test "tool error reporting does not require the request allocator" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try toolError(&output.writer, .{ .integer = 1 }, "RESOURCE_LIMIT", "Request memory exhausted.");
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const payload = get(parsed.value, "result").?;
    try std.testing.expect(get(payload, "isError").?.bool);
    const text = get(payload, "content").?.array.items[0].object.get("text").?.string;
    const content = try std.json.parseFromSlice(Value, std.testing.allocator, text, .{});
    defer content.deinit();
    try std.testing.expect(!get(content.value, "ok").?.bool);
}
