const std = @import("std");
const theme = @import("theme.zig");

pub const max_file_size = 4 * 1024 * 1024;
pub const marker_file = ".brand-peel-export.json";
pub const required_files = [_][]const u8{
    marker_file,
    "identity.md",
    "visual.md",
    "guidelines.md",
    "theme.json",
    "theme.css",
};

pub const ExportInfo = struct {
    path: []const u8,
    project_id: []const u8,
    exported_at: []const u8,
    missing_files: []const []const u8,
    theme_report: theme.ThemeReport,

    pub fn valid(self: ExportInfo) bool {
        return self.missing_files.len == 0 and
            self.theme_report.invalid_values == 0 and
            self.theme_report.missing_pairs == 0;
    }
};

pub const TokenFormat = enum {
    css,
    tailwind_v4,
    json,
    typescript,

    pub fn parse(value: []const u8) ?TokenFormat {
        if (std.mem.eql(u8, value, "css")) return .css;
        if (std.mem.eql(u8, value, "tailwind-v4")) return .tailwind_v4;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "typescript")) return .typescript;
        return null;
    }

    pub fn label(self: TokenFormat) []const u8 {
        return switch (self) {
            .css => "css",
            .tailwind_v4 => "tailwind-v4",
            .json => "json",
            .typescript => "typescript",
        };
    }
};

pub fn joinPath(allocator: std.mem.Allocator, base: []const u8, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base, child });
}

pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
}

fn validateMarker(allocator: std.mem.Allocator, json_text: []const u8) !struct {
    project_id: []const u8,
    exported_at: []const u8,
} {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 5) return error.InvalidMarker;
    const app = parsed.value.object.get("app") orelse return error.InvalidMarker;
    const kind = parsed.value.object.get("type") orelse return error.InvalidMarker;
    const version = parsed.value.object.get("version") orelse return error.InvalidMarker;
    const project_id = parsed.value.object.get("projectId") orelse return error.InvalidMarker;
    const exported_at = parsed.value.object.get("exportedAt") orelse return error.InvalidMarker;
    if (app != .string or !std.mem.eql(u8, app.string, "brand-peel")) return error.InvalidMarker;
    if (kind != .string or !std.mem.eql(u8, kind.string, "project-export")) return error.InvalidMarker;
    if (version != .integer or version.integer != 1) return error.UnsupportedExportVersion;
    if (project_id != .string or project_id.string.len == 0) return error.InvalidMarker;
    if (exported_at != .string or exported_at.string.len == 0) return error.InvalidMarker;
    return .{
        .project_id = try allocator.dupe(u8, project_id.string),
        .exported_at = try allocator.dupe(u8, exported_at.string),
    };
}

pub fn inspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    export_path: []const u8,
) !ExportInfo {
    var missing: std.ArrayList([]const u8) = .empty;
    errdefer missing.deinit(allocator);
    for (required_files) |file_name| {
        const path = try joinPath(allocator, export_path, file_name);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            try missing.append(allocator, file_name);
        };
    }

    if (missing.items.len != 0) {
        return .{
            .path = export_path,
            .project_id = "",
            .exported_at = "",
            .missing_files = try missing.toOwnedSlice(allocator),
            .theme_report = .{
                .token_count = 0,
                .invalid_values = 0,
                .missing_pairs = 0,
                .aa_failures = 0,
                .contrasts = &.{},
            },
        };
    }

    const marker_path = try joinPath(allocator, export_path, marker_file);
    const marker_json = try readFile(allocator, io, marker_path);
    const marker = try validateMarker(allocator, marker_json);
    const theme_path = try joinPath(allocator, export_path, "theme.json");
    const theme_json = try readFile(allocator, io, theme_path);

    return .{
        .path = export_path,
        .project_id = marker.project_id,
        .exported_at = marker.exported_at,
        .missing_files = try missing.toOwnedSlice(allocator),
        .theme_report = try theme.analyze(allocator, theme_json),
    };
}

fn themePath(allocator: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, input_path, ".json")) return allocator.dupe(u8, input_path);
    return joinPath(allocator, input_path, "theme.json");
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn sortedKeys(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    try keys.ensureTotalCapacity(allocator, object.count());
    var iterator = object.iterator();
    while (iterator.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, lessThan);
    return keys.toOwnedSlice(allocator);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeSortedObject(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    object: std.json.ObjectMap,
    indent: []const u8,
) !void {
    const keys = try sortedKeys(allocator, object);
    try writer.writeAll("{\n");
    for (keys, 0..) |key, index| {
        try writer.writeAll(indent);
        try writeJsonString(writer, key);
        try writer.writeAll(": ");
        const value = object.get(key).?;
        try std.json.Stringify.value(value, .{}, writer);
        if (index + 1 != keys.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    const closing_indent = if (indent.len >= 2) indent[0 .. indent.len - 2] else "";
    try writer.writeAll(closing_indent);
    try writer.writeByte('}');
}

fn writeCssVariables(writer: *std.Io.Writer, object: std.json.ObjectMap, keys: []const []const u8) !void {
    for (keys) |key| {
        const value = object.get(key).?;
        if (value != .string) continue;
        try writer.print("  --{s}: {s};\n", .{ key, value.string });
    }
}

pub fn generateTokens(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    format: TokenFormat,
) ![]u8 {
    const path = try themePath(allocator, input_path);
    const raw = try readFile(allocator, io, path);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTheme;
    const light = parsed.value.object.get("light") orelse return error.InvalidTheme;
    const dark = parsed.value.object.get("dark") orelse return error.InvalidTheme;
    if (light != .object or dark != .object) return error.InvalidTheme;
    const light_keys = try sortedKeys(allocator, light.object);
    const dark_keys = try sortedKeys(allocator, dark.object);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    switch (format) {
        .css => {
            try writer.writeAll("/** Generated by Brand Peel CLI. */\n:root {\n");
            try writeCssVariables(writer, light.object, light_keys);
            try writer.writeAll("}\n\n.dark {\n");
            try writeCssVariables(writer, dark.object, dark_keys);
            try writer.writeAll("}\n");
        },
        .tailwind_v4 => {
            try writer.writeAll("/** Generated by Brand Peel CLI for Tailwind CSS v4. */\n:root {\n");
            try writeCssVariables(writer, light.object, light_keys);
            try writer.writeAll("}\n\n.dark {\n");
            try writeCssVariables(writer, dark.object, dark_keys);
            try writer.writeAll("}\n\n@theme inline {\n");
            for (light_keys) |key| {
                if (!theme.isColorKey(key)) continue;
                try writer.print("  --color-{s}: hsl(var(--{s}));\n", .{ key, key });
            }
            try writer.writeAll("}\n");
        },
        .json => {
            try writer.writeAll("{\n  \"light\": ");
            try writeSortedObject(allocator, writer, light.object, "    ");
            try writer.writeAll(",\n  \"dark\": ");
            try writeSortedObject(allocator, writer, dark.object, "    ");
            try writer.writeAll("\n}\n");
        },
        .typescript => {
            try writer.writeAll("/** Generated by Brand Peel CLI. */\nexport const brandPeelTheme = {\n  light: ");
            try writeSortedObject(allocator, writer, light.object, "    ");
            try writer.writeAll(",\n  dark: ");
            try writeSortedObject(allocator, writer, dark.object, "    ");
            try writer.writeAll("\n} as const;\n\nexport type BrandPeelTheme = typeof brandPeelTheme;\n");
        },
    }

    return output.toOwnedSlice();
}

fn demoteLeadingH1(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, content, "# ")) {
        return std.fmt.allocPrint(allocator, "#{s}", .{content});
    }
    return allocator.dupe(u8, content);
}

pub fn compileBook(
    allocator: std.mem.Allocator,
    io: std.Io,
    export_path: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("# Brand Book\n\n> Compiled by Brand Peel CLI.\n");
    for ([_][]const u8{ "identity.md", "visual.md", "guidelines.md" }) |file_name| {
        const path = try joinPath(allocator, export_path, file_name);
        const content = try readFile(allocator, io, path);
        try writer.writeAll("\n---\n\n");
        try writer.writeAll(try demoteLeadingH1(allocator, content));
        if (!std.mem.endsWith(u8, content, "\n")) try writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

pub fn writeOutput(
    io: std.Io,
    path: []const u8,
    data: []const u8,
    force: bool,
) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = force,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    if (force) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
}

test "token format parser accepts public names" {
    try std.testing.expectEqual(TokenFormat.tailwind_v4, TokenFormat.parse("tailwind-v4").?);
    try std.testing.expect(TokenFormat.parse("unknown") == null);
}

test "leading H1 is demoted exactly once" {
    const first = try demoteLeadingH1(std.testing.allocator, "# Identity\nText");
    defer std.testing.allocator.free(first);
    const second = try demoteLeadingH1(std.testing.allocator, "Text");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("## Identity\nText", first);
    try std.testing.expectEqualStrings("Text", second);
}
