const std = @import("std");

pub const default_base_url = "https://brandpeel.app";
pub const max_response_size = 4 * 1024 * 1024;
pub const default_timeout_seconds: u32 = 15;

pub const Response = struct {
    status: u16,
    body: []u8,
};

pub fn normalizeBaseUrl(base_url: []const u8) ![]const u8 {
    var value = std.mem.trim(u8, base_url, " \t\r\n");
    while (value.len > 0 and value[value.len - 1] == '/') value = value[0 .. value.len - 1];
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "?#") != null) return error.InvalidBaseUrl;
    if (std.mem.startsWith(u8, value, "https://")) return value;
    if (!std.mem.startsWith(u8, value, "http://")) return error.InsecureBaseUrl;

    const authority_and_path = value[7..];
    const authority_end = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse authority_and_path.len;
    const authority = authority_and_path[0..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidBaseUrl;

    const host = if (authority[0] == '[') block: {
        const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidBaseUrl;
        break :block authority[0 .. closing + 1];
    } else block: {
        const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        break :block authority[0..colon];
    };
    if (!std.mem.eql(u8, host, "localhost") and
        !std.mem.eql(u8, host, "127.0.0.1") and
        !std.mem.eql(u8, host, "[::1]")) return error.InsecureBaseUrl;
    return value;
}

fn isUnreserved(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or
        character == '-' or character == '.' or character == '_' or character == '~';
}

pub fn appendQueryValue(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |character| {
        if (isUnreserved(character)) {
            try writer.writeByte(character);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[character >> 4]);
            try writer.writeByte(hex[character & 0x0f]);
        }
    }
}

pub fn buildUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    endpoint: []const u8,
    query: []const [2][]const u8,
) ![]u8 {
    const base = try normalizeBaseUrl(base_url);
    if (!std.mem.startsWith(u8, endpoint, "/")) return error.InvalidEndpoint;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{s}{s}", .{ base, endpoint });
    for (query, 0..) |pair, index| {
        try output.writer.writeByte(if (index == 0) '?' else '&');
        try appendQueryValue(&output.writer, pair[0]);
        try output.writer.writeByte('=');
        try appendQueryValue(&output.writer, pair[1]);
    }
    return output.toOwnedSlice();
}

const FetchResult = anyerror!Response;
const Event = union(enum) {
    fetched: FetchResult,
    timed_out: void,
};

fn fetchTask(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) FetchResult {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const buffer = try allocator.alloc(u8, max_response_size);
    defer allocator.free(buffer);
    var response_writer: std.Io.Writer = .fixed(buffer);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = @enumFromInt(5),
        .response_writer = &response_writer,
        .headers = .{
            .accept_encoding = .omit,
            .user_agent = .{ .override = "brandpeel-cli/0.1.0" },
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseTooLarge,
        else => return err,
    };
    const status: u16 = @intFromEnum(result.status);
    const body = try allocator.dupe(u8, response_writer.buffered());
    return .{ .status = status, .body = body };
}

fn timeoutTask(io: std.Io, seconds: u32) void {
    io.sleep(.fromSeconds(seconds), .awake) catch {};
}

pub fn fetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    timeout_seconds: u32,
) !Response {
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &events);
    select.async(.fetched, fetchTask, .{ allocator, io, url });
    select.async(.timed_out, timeoutTask, .{ io, timeout_seconds });
    const event = try select.await();
    switch (event) {
        .timed_out => {
            select.cancelDiscard();
            return error.Timeout;
        },
        .fetched => |result| {
            select.cancelDiscard();
            const response = try result;
            if (response.status < 200 or response.status >= 300) {
                allocator.free(response.body);
                return error.ApiStatus;
            }
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
                allocator.free(response.body);
                return error.InvalidJsonResponse;
            };
            parsed.deinit();
            return response;
        },
    }
}

test "base URL requires HTTPS except loopback" {
    try std.testing.expectEqualStrings("https://brandpeel.app", try normalizeBaseUrl("https://brandpeel.app/"));
    try std.testing.expectEqualStrings("http://localhost:3000", try normalizeBaseUrl("http://localhost:3000"));
    try std.testing.expectError(error.InsecureBaseUrl, normalizeBaseUrl("http://brandpeel.app"));
    try std.testing.expectError(error.InsecureBaseUrl, normalizeBaseUrl("http://localhost.example"));
}

test "query values use RFC 3986 percent encoding" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try appendQueryValue(&output.writer, "Color & type/scale");
    try std.testing.expectEqualStrings("Color%20%26%20type%2Fscale", output.written());
}

test "build URL preserves parameter order" {
    const result = try buildUrl(
        std.testing.allocator,
        default_base_url,
        "/api/v1/tools",
        &.{ .{ "category", "Design System" }, .{ "q", "color" } },
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "https://brandpeel.app/api/v1/tools?category=Design%20System&q=color",
        result,
    );
}
