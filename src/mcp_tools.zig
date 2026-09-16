const std = @import("std");
const builtin = @import("builtin");

const Field = struct {
    name: []const u8,
    description: []const u8,
    kind: enum { string, boolean, path } = .string,
    required: bool = false,
    option: ?[]const u8 = null,
    choices: ?[]const []const u8 = null,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    command: []const u8,
    subcommand: ?[]const u8 = null,
    fields: []const Field,
    writes: bool = false,
};

const directory: Field = .{ .name = "directory", .description = "Absolute path to a desktop export directory containing .brand-peel-export.json, identity.md, visual.md, guidelines.md, theme.json and theme.css.", .kind = .path, .required = true };
const output: Field = .{ .name = "output", .description = "Absolute destination file path. Omit to return generated content without writing any file.", .kind = .path, .option = "-o" };
const force: Field = .{ .name = "force", .description = "Replace an existing output file when true. Defaults to false.", .kind = .boolean, .option = "--force" };
const platform: Field = .{ .name = "platform", .description = "Filter by operating system.", .option = "--platform", .choices = &.{ "windows", "macos", "linux" } };

// Schema generation and argument validation use the same declarations.
pub const catalog = [_]Tool{
    .{ .name = "inspect", .description = "Inspect a Brand Peel export and report its files and theme validity. Read-only; invalid exports may return a report with valid=false.", .command = "inspect", .fields = &.{directory} },
    .{ .name = "doctor", .description = "Validate a desktop export and report WCAG 2 AA/AAA semantic color contrast. Strict mode fails ratios below 4.5:1.", .command = "doctor", .fields = &.{ directory, .{ .name = "strict", .description = "Fail semantic pairs below WCAG AA normal text (4.5:1). Defaults to false.", .kind = .boolean, .option = "--strict" } } },
    .{ .name = "export", .description = "Generate deterministic design tokens. Returns content unless output is supplied; writing refuses existing files unless force=true.", .command = "export", .writes = true, .fields = &.{
        .{ .name = "input", .description = "Absolute path to a desktop export directory or theme.json.", .kind = .path, .required = true },
        .{ .name = "format", .description = "Output token format.", .required = true, .option = "--format", .choices = &.{ "css", "tailwind-v4", "json", "typescript" } },
        output,
        force,
    } },
    .{ .name = "compile_book", .description = "Combine identity, visual and guidelines documents into one Brand Book. Returns Markdown unless output is supplied; refuses overwrite unless force=true.", .command = "compile-book", .writes = true, .fields = &.{ directory, output, force } },
    .{ .name = "api_health", .description = "Read public API health. Defaults to the full health payload.", .command = "api", .subcommand = "health", .fields = &.{.{ .name = "detail", .description = "Health response detail; defaults to full.", .option = "--detail", .choices = &.{ "full", "status" } }} },
    .{ .name = "api_release", .description = "Read the latest desktop release, optionally filtered by platform and release channel.", .command = "api", .subcommand = "release", .fields = &.{ platform, .{ .name = "channel", .description = "Release channel; defaults to stable.", .option = "--channel", .choices = &.{ "stable", "alpha", "beta" } } } },
    .{ .name = "api_tools", .description = "List or search public Brand Peel tools.", .command = "api", .subcommand = "tools", .fields = &.{ .{ .name = "category", .description = "Filter by tool category.", .option = "--category" }, .{ .name = "query", .description = "Search text.", .option = "--query" } } },
    .{ .name = "api_tool", .description = "Read one public tool by its slug.", .command = "api", .subcommand = "tool", .fields = &.{.{ .name = "slug", .description = "Public tool slug, for example contrast-checker.", .required = true }} },
    .{ .name = "api_schema", .description = "Read the brand-guide JSON Schema.", .command = "api", .subcommand = "schema", .fields = &.{.{ .name = "version", .description = "Schema version; defaults to 1.0.0.", .option = "--version", .choices = &.{"1.0.0"} }} },
    .{ .name = "api_agent_info", .description = "Read agent integration information and function definitions.", .command = "api", .subcommand = "agent-info", .fields = &.{.{ .name = "include", .description = "Select information to include; defaults to all.", .option = "--include", .choices = &.{ "all", "functions", "guidance" } }} },
    .{ .name = "api_cli_manifest", .description = "Read the CLI manifest, optionally filtered by platform.", .command = "api", .subcommand = "cli-manifest", .fields = &.{platform} },
};

pub fn find(name: []const u8) ?Tool {
    for (catalog) |tool| if (std.mem.eql(u8, name, tool.name)) return tool;
    return null;
}

pub fn writeList(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"tools\":[");
    for (catalog, 0..) |tool, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tool.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(tool.description, .{}, writer);
        try writer.writeAll(",\"inputSchema\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{");
        for (tool.fields, 0..) |field, field_index| {
            if (field_index != 0) try writer.writeByte(',');
            try std.json.Stringify.value(field.name, .{}, writer);
            try writer.writeAll(":{\"type\":");
            try std.json.Stringify.value(if (field.kind == .boolean) "boolean" else "string", .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(field.description, .{}, writer);
            if (field.kind == .boolean) {
                try writer.writeAll(",\"default\":false");
            } else {
                try writer.writeAll(",\"minLength\":1,\"maxLength\":4096");
            }
            if (field.choices) |choices| {
                try writer.writeAll(",\"enum\":");
                try std.json.Stringify.value(choices, .{}, writer);
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("},\"required\":[");
        var first = true;
        for (tool.fields) |field| {
            if (!field.required) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(field.name, .{}, writer);
        }
        try writer.writeAll("]},\"annotations\":");
        try std.json.Stringify.value(.{
            .readOnlyHint = !tool.writes,
            .destructiveHint = tool.writes,
            .idempotentHint = !tool.writes,
            .openWorldHint = tool.subcommand != null,
        }, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn absolutePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    if (builtin.os.tag == .windows) {
        // Root-relative paths (\foo) still depend on the current drive.
        return (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) or
            (path.len > 2 and path[0] == '\\' and path[1] == '\\');
    }
    return true;
}

pub fn validate(tool: Tool, arguments: std.json.ObjectMap) ?[]const u8 {
    var keys = arguments.iterator();
    while (keys.next()) |entry| {
        var known = false;
        for (tool.fields) |field| {
            if (std.mem.eql(u8, entry.key_ptr.*, field.name)) known = true;
        }
        if (!known) return "Unknown argument; use only properties from this tool's inputSchema.";
    }
    for (tool.fields) |field| {
        const value = arguments.get(field.name) orelse {
            if (field.required) return "Missing required argument; consult the tool's inputSchema.";
            continue;
        };
        if (field.kind == .boolean) {
            if (value != .bool) return "Expected a JSON boolean.";
            continue;
        }
        if (value != .string) return "Expected a JSON string.";
        const string = value.string;
        const characters = std.unicode.utf8CountCodepoints(string) catch return "Strings must be valid UTF-8.";
        if (characters == 0 or characters > 4096 or std.mem.indexOfScalar(u8, string, 0) != null) return "Strings must contain 1 to 4096 characters and no NUL.";
        if (field.kind == .path and !absolutePath(string)) return "Local input and output paths must be explicit absolute paths.";
        if (field.choices) |choices| {
            var valid = false;
            for (choices) |choice| if (std.mem.eql(u8, choice, string)) {
                valid = true;
            };
            if (!valid) return "Unsupported argument value; consult the enum in the tool's inputSchema.";
        }
    }
    if (arguments.get("force")) |value| {
        if (value.bool and !arguments.contains("output")) return "force requires an explicit output path.";
    }
    return null;
}

pub fn commandArguments(allocator: std.mem.Allocator, tool: Tool, arguments: std.json.ObjectMap) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    if (tool.subcommand) |subcommand| try result.append(allocator, subcommand);
    for (tool.fields) |field| {
        const value = arguments.get(field.name) orelse continue;
        if (field.kind == .boolean) {
            if (value.bool) try result.append(allocator, field.option.?);
        } else {
            if (field.option) |option| try result.append(allocator, option);
            try result.append(allocator, value.string);
        }
    }
    return result.toOwnedSlice(allocator);
}

test "tool names are unique and cover four local and seven API commands" {
    var apis: usize = 0;
    for (catalog, 0..) |tool, index| {
        if (tool.subcommand != null) apis += 1;
        for (catalog[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, tool.name, previous.name));
    }
    try std.testing.expectEqual(7, apis);
    try std.testing.expectEqual(11, catalog.len);
}
