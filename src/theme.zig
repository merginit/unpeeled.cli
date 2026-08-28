const std = @import("std");

pub const Hsl = struct {
    hue: f64,
    saturation: f64,
    lightness: f64,
};

pub const ContrastResult = struct {
    mode: []const u8,
    background: []const u8,
    foreground: []const u8,
    ratio: f64,

    pub fn passesAa(self: ContrastResult) bool {
        return self.ratio >= 4.5;
    }
};

pub const ThemeReport = struct {
    token_count: usize,
    invalid_values: usize,
    missing_pairs: usize,
    aa_failures: usize,
    contrasts: []ContrastResult,
};

pub const semantic_pairs = [_][2][]const u8{
    .{ "background", "foreground" },
    .{ "card", "card-foreground" },
    .{ "popover", "popover-foreground" },
    .{ "primary", "primary-foreground" },
    .{ "secondary", "secondary-foreground" },
    .{ "muted", "muted-foreground" },
    .{ "accent", "accent-foreground" },
    .{ "destructive", "destructive-foreground" },
    .{ "sidebar", "sidebar-foreground" },
    .{ "sidebar-primary", "sidebar-primary-foreground" },
    .{ "sidebar-accent", "sidebar-accent-foreground" },
};

const color_keys = [_][]const u8{
    "background",
    "foreground",
    "card",
    "card-foreground",
    "popover",
    "popover-foreground",
    "primary",
    "primary-foreground",
    "secondary",
    "secondary-foreground",
    "muted",
    "muted-foreground",
    "accent",
    "accent-foreground",
    "destructive",
    "destructive-foreground",
    "border",
    "input",
    "ring",
    "chart-1",
    "chart-2",
    "chart-3",
    "chart-4",
    "chart-5",
    "sidebar",
    "sidebar-foreground",
    "sidebar-primary",
    "sidebar-primary-foreground",
    "sidebar-accent",
    "sidebar-accent-foreground",
    "sidebar-border",
    "sidebar-ring",
};

pub fn isColorKey(key: []const u8) bool {
    for (color_keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

fn parsePercent(value: []const u8) !f64 {
    if (value.len < 2 or value[value.len - 1] != '%') return error.InvalidHsl;
    const parsed = try std.fmt.parseFloat(f64, value[0 .. value.len - 1]);
    if (!std.math.isFinite(parsed) or parsed < 0 or parsed > 100) return error.InvalidHsl;
    return parsed / 100.0;
}

pub fn parseHsl(input: []const u8) !Hsl {
    var value = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, value, "hsl(") and std.mem.endsWith(u8, value, ")")) {
        value = value[4 .. value.len - 1];
    }

    var normalized_buffer: [192]u8 = undefined;
    if (value.len > normalized_buffer.len) return error.InvalidHsl;
    for (value, 0..) |character, index| {
        normalized_buffer[index] = switch (character) {
            ',', '/' => ' ',
            else => character,
        };
    }

    var parts = std.mem.tokenizeAny(u8, normalized_buffer[0..value.len], " \t\r\n");
    const hue_text = parts.next() orelse return error.InvalidHsl;
    const saturation_text = parts.next() orelse return error.InvalidHsl;
    const lightness_text = parts.next() orelse return error.InvalidHsl;
    if (parts.next() != null) return error.InvalidHsl;

    var hue = try std.fmt.parseFloat(f64, hue_text);
    if (!std.math.isFinite(hue)) return error.InvalidHsl;
    hue = @mod(hue, 360.0);
    if (hue < 0) hue += 360.0;

    return .{
        .hue = hue,
        .saturation = try parsePercent(saturation_text),
        .lightness = try parsePercent(lightness_text),
    };
}

fn hueChannel(p: f64, q: f64, raw_t: f64) f64 {
    var t = raw_t;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

fn toSrgb(hsl: Hsl) [3]f64 {
    if (hsl.saturation == 0) return .{ hsl.lightness, hsl.lightness, hsl.lightness };
    const q = if (hsl.lightness < 0.5)
        hsl.lightness * (1.0 + hsl.saturation)
    else
        hsl.lightness + hsl.saturation - hsl.lightness * hsl.saturation;
    const p = 2.0 * hsl.lightness - q;
    const h = hsl.hue / 360.0;
    return .{
        hueChannel(p, q, h + 1.0 / 3.0),
        hueChannel(p, q, h),
        hueChannel(p, q, h - 1.0 / 3.0),
    };
}

fn linearize(channel: f64) f64 {
    if (channel <= 0.04045) return channel / 12.92;
    return std.math.pow(f64, (channel + 0.055) / 1.055, 2.4);
}

pub fn relativeLuminance(hsl: Hsl) f64 {
    const rgb = toSrgb(hsl);
    return 0.2126 * linearize(rgb[0]) +
        0.7152 * linearize(rgb[1]) +
        0.0722 * linearize(rgb[2]);
}

pub fn contrastRatio(background: Hsl, foreground: Hsl) f64 {
    const first = relativeLuminance(background);
    const second = relativeLuminance(foreground);
    const lighter = @max(first, second);
    const darker = @min(first, second);
    return (lighter + 0.05) / (darker + 0.05);
}

fn objectValue(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn analyze(allocator: std.mem.Allocator, json_text: []const u8) !ThemeReport {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTheme;

    var contrasts: std.ArrayList(ContrastResult) = .empty;
    errdefer contrasts.deinit(allocator);
    var token_count: usize = 0;
    var invalid_values: usize = 0;
    var missing_pairs: usize = 0;
    var aa_failures: usize = 0;

    for ([_][]const u8{ "light", "dark" }) |mode| {
        const mode_value = parsed.value.object.get(mode) orelse return error.InvalidTheme;
        if (mode_value != .object) return error.InvalidTheme;
        token_count += mode_value.object.count();

        var iterator = mode_value.object.iterator();
        while (iterator.next()) |entry| {
            if (!isColorKey(entry.key_ptr.*)) continue;
            if (entry.value_ptr.* != .string) {
                invalid_values += 1;
                continue;
            }
            _ = parseHsl(entry.value_ptr.string) catch {
                invalid_values += 1;
                continue;
            };
        }

        for (semantic_pairs) |pair| {
            const background_text = objectValue(mode_value.object, pair[0]) orelse {
                missing_pairs += 1;
                continue;
            };
            const foreground_text = objectValue(mode_value.object, pair[1]) orelse {
                missing_pairs += 1;
                continue;
            };
            const background = parseHsl(background_text) catch continue;
            const foreground = parseHsl(foreground_text) catch continue;
            const ratio = contrastRatio(background, foreground);
            if (ratio < 4.5) aa_failures += 1;
            try contrasts.append(allocator, .{
                .mode = mode,
                .background = pair[0],
                .foreground = pair[1],
                .ratio = ratio,
            });
        }
    }

    return .{
        .token_count = token_count,
        .invalid_values = invalid_values,
        .missing_pairs = missing_pairs,
        .aa_failures = aa_failures,
        .contrasts = try contrasts.toOwnedSlice(allocator),
    };
}

test "parse Brand Peel HSL triplets" {
    const result = try parseHsl("240 10% 3.9%");
    try std.testing.expectApproxEqAbs(@as(f64, 240), result.hue, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.saturation, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.039), result.lightness, 0.0001);
}

test "parse wrapped and comma-separated HSL" {
    const result = try parseHsl("hsl(0, 0%, 100%)");
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.lightness, 0.0001);
}

test "WCAG black and white contrast is 21 to 1" {
    const ratio = contrastRatio(
        try parseHsl("0 0% 0%"),
        try parseHsl("0 0% 100%"),
    );
    try std.testing.expectApproxEqAbs(@as(f64, 21), ratio, 0.001);
}

test "WCAG identical colors have ratio 1" {
    const color = try parseHsl("210 50% 40%");
    try std.testing.expectApproxEqAbs(@as(f64, 1), contrastRatio(color, color), 0.001);
}
