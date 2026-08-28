const std = @import("std");
const api = @import("api.zig");
const export_data = @import("export.zig");

pub const version = "0.1.0";

pub const ExitCode = enum(u8) {
    success = 0,
    internal = 1,
    usage = 2,
    validation = 3,
    filesystem = 4,
    network = 5,
};

const Options = struct {
    json: bool = false,
    api_base_url: []const u8 = api.default_base_url,
    timeout_seconds: u32 = api.default_timeout_seconds,
};

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
};

const help_text =
    \\Brand Peel CLI 0.1.0
    \\
    \\Usage:
    \\  brandpeel [--json] [--api-base-url URL] [--timeout SECONDS] <command>
    \\
    \\Local export commands:
    \\  inspect [EXPORT_DIRECTORY]
    \\  doctor [EXPORT_DIRECTORY] [--strict]
    \\  export [EXPORT_DIRECTORY|theme.json] --format css|tailwind-v4|json|typescript [-o FILE] [--force]
    \\  compile-book [EXPORT_DIRECTORY] [-o BRAND.md] [--force]
    \\
    \\Public API commands:
    \\  api health [--detail full|status]
    \\  api release [--platform windows|macos|linux] [--channel stable|alpha|beta]
    \\  api tools [--category VALUE] [--query VALUE]
    \\  api tool <slug>
    \\  api schema [--version 1.0.0]
    \\  api agent-info [--include all|functions|guidance]
    \\  api cli-manifest [--platform windows|macos|linux]
    \\
    \\Global options must precede the command. The API defaults to https://brandpeel.app.
;

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn success(
    context: *Context,
    command: []const u8,
    human: []const u8,
    data_json: []const u8,
) !u8 {
    if (context.options.json) {
        try context.stdout.writeAll("{\"ok\":true,\"command\":");
        try writeJsonString(context.stdout, command);
        try context.stdout.writeAll(",\"data\":");
        try context.stdout.writeAll(data_json);
        try context.stdout.writeAll("}\n");
    } else {
        try context.stdout.writeAll(human);
        if (!std.mem.endsWith(u8, human, "\n")) try context.stdout.writeByte('\n');
    }
    return @intFromEnum(ExitCode.success);
}

fn failure(
    context: *Context,
    code: ExitCode,
    error_code: []const u8,
    message: []const u8,
) !u8 {
    if (context.options.json) {
        try context.stdout.writeAll("{\"ok\":false,\"error\":{\"code\":");
        try writeJsonString(context.stdout, error_code);
        try context.stdout.writeAll(",\"message\":");
        try writeJsonString(context.stdout, message);
        try context.stdout.writeAll("}}\n");
    } else {
        try context.stderr.print("error: {s}\n", .{message});
    }
    return @intFromEnum(code);
}

fn usage(context: *Context, message: []const u8) !u8 {
    return failure(context, .usage, "USAGE", message);
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "A required file or directory was not found.",
        error.AccessDenied, error.PermissionDenied => "Permission was denied while accessing a file.",
        error.PathAlreadyExists => "The output already exists; pass --force to replace it.",
        error.InvalidMarker => "The export marker is invalid or contains unexpected fields.",
        error.UnsupportedExportVersion => "This Brand Peel export version is not supported.",
        error.InvalidTheme => "theme.json must contain light and dark token objects.",
        error.InvalidHsl => "A semantic color token is not a valid HSL triplet.",
        error.InsecureBaseUrl => "The API base URL must use HTTPS unless it targets a loopback host.",
        error.InvalidBaseUrl => "The API base URL is invalid.",
        error.Timeout => "The Brand Peel API request exceeded its deadline.",
        error.ResponseTooLarge => "The Brand Peel API response exceeded 4 MiB.",
        error.InvalidJsonResponse => "The Brand Peel API returned invalid JSON.",
        error.ApiStatus => "The Brand Peel API returned a non-success status.",
        else => @errorName(err),
    };
}

fn validationFailure(context: *Context, err: anyerror) !u8 {
    return failure(context, .validation, @errorName(err), errorMessage(err));
}

fn filesystemFailure(context: *Context, err: anyerror) !u8 {
    return failure(context, .filesystem, @errorName(err), errorMessage(err));
}

fn networkFailure(context: *Context, err: anyerror) !u8 {
    return failure(context, .network, @errorName(err), errorMessage(err));
}

fn formatInspect(
    allocator: std.mem.Allocator,
    report: export_data.ExportInfo,
) !struct { human: []u8, json: []u8 } {
    var human: std.Io.Writer.Allocating = .init(allocator);
    errdefer human.deinit();
    try human.writer.print(
        "Brand Peel export: {s}\nProject: {s}\nExported: {s}\nTokens: {d}\nMissing files: {d}\nInvalid color values: {d}\nMissing semantic pairs: {d}\nWCAG AA warnings: {d}\n",
        .{
            report.path,
            if (report.project_id.len == 0) "unknown" else report.project_id,
            if (report.exported_at.len == 0) "unknown" else report.exported_at,
            report.theme_report.token_count,
            report.missing_files.len,
            report.theme_report.invalid_values,
            report.theme_report.missing_pairs,
            report.theme_report.aa_failures,
        },
    );
    if (report.missing_files.len != 0) {
        try human.writer.writeAll("Missing:\n");
        for (report.missing_files) |file_name| try human.writer.print("  - {s}\n", .{file_name});
    }

    var json: std.Io.Writer.Allocating = .init(allocator);
    errdefer json.deinit();
    try json.writer.writeAll("{");
    try json.writer.writeAll("\"path\":");
    try writeJsonString(&json.writer, report.path);
    try json.writer.writeAll(",\"projectId\":");
    try writeJsonString(&json.writer, report.project_id);
    try json.writer.writeAll(",\"exportedAt\":");
    try writeJsonString(&json.writer, report.exported_at);
    try json.writer.print(
        ",\"valid\":{},\"tokenCount\":{d},\"invalidValues\":{d},\"missingPairs\":{d},\"aaFailures\":{d},\"missingFiles\":[",
        .{
            report.valid(),
            report.theme_report.token_count,
            report.theme_report.invalid_values,
            report.theme_report.missing_pairs,
            report.theme_report.aa_failures,
        },
    );
    for (report.missing_files, 0..) |file_name, index| {
        if (index != 0) try json.writer.writeByte(',');
        try writeJsonString(&json.writer, file_name);
    }
    try json.writer.writeAll("]}");
    return .{ .human = try human.toOwnedSlice(), .json = try json.toOwnedSlice() };
}

fn commandInspect(context: *Context, arguments: []const []const u8) !u8 {
    if (arguments.len > 1) return usage(context, "inspect accepts at most one export directory.");
    const path = if (arguments.len == 1) arguments[0] else ".";
    const report = export_data.inspect(context.allocator, context.io, path) catch |err| {
        return validationFailure(context, err);
    };
    const formatted = try formatInspect(context.allocator, report);
    return success(context, "inspect", formatted.human, formatted.json);
}

fn commandDoctor(context: *Context, arguments: []const []const u8) !u8 {
    var path: []const u8 = ".";
    var strict = false;
    var path_seen = false;
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--strict")) {
            strict = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return usage(context, "doctor received an unknown option.");
        } else if (path_seen) {
            return usage(context, "doctor accepts at most one export directory.");
        } else {
            path = argument;
            path_seen = true;
        }
    }
    const report = export_data.inspect(context.allocator, context.io, path) catch |err| {
        return validationFailure(context, err);
    };

    var human: std.Io.Writer.Allocating = .init(context.allocator);
    defer human.deinit();
    try human.writer.print("Brand Peel doctor: {s}\n", .{path});
    for (report.theme_report.contrasts) |contrast| {
        try human.writer.print(
            "  {s}: {s}/{s} {d:.2}:1  AA {s}  AAA {s}\n",
            .{
                contrast.mode,
                contrast.background,
                contrast.foreground,
                contrast.ratio,
                if (contrast.ratio >= 4.5) "pass" else "fail",
                if (contrast.ratio >= 7.0) "pass" else "fail",
            },
        );
    }
    try human.writer.print(
        "Summary: {d} missing files, {d} invalid colors, {d} missing pairs, {d} AA warnings.\n",
        .{
            report.missing_files.len,
            report.theme_report.invalid_values,
            report.theme_report.missing_pairs,
            report.theme_report.aa_failures,
        },
    );

    var json: std.Io.Writer.Allocating = .init(context.allocator);
    defer json.deinit();
    try json.writer.writeAll("{\"path\":");
    try writeJsonString(&json.writer, path);
    try json.writer.print(
        ",\"strict\":{},\"valid\":{},\"missingFiles\":{d},\"invalidValues\":{d},\"missingPairs\":{d},\"aaFailures\":{d},\"contrasts\":[",
        .{
            strict,
            report.valid(),
            report.missing_files.len,
            report.theme_report.invalid_values,
            report.theme_report.missing_pairs,
            report.theme_report.aa_failures,
        },
    );
    for (report.theme_report.contrasts, 0..) |contrast, index| {
        if (index != 0) try json.writer.writeByte(',');
        try json.writer.writeAll("{\"mode\":");
        try writeJsonString(&json.writer, contrast.mode);
        try json.writer.writeAll(",\"background\":");
        try writeJsonString(&json.writer, contrast.background);
        try json.writer.writeAll(",\"foreground\":");
        try writeJsonString(&json.writer, contrast.foreground);
        try json.writer.print(
            ",\"ratio\":{d:.4},\"aa\":{},\"aaa\":{}}}",
            .{ contrast.ratio, contrast.ratio >= 4.5, contrast.ratio >= 7.0 },
        );
    }
    try json.writer.writeAll("]}");

    if (!report.valid() or (strict and report.theme_report.aa_failures != 0)) {
        if (context.options.json) {
            try context.stdout.writeAll("{\"ok\":false,\"error\":{\"code\":\"DOCTOR_FAILED\",\"message\":\"Brand Peel export validation failed.\",\"details\":");
            try context.stdout.writeAll(json.written());
            try context.stdout.writeAll("}}\n");
        } else {
            try context.stdout.writeAll(human.written());
        }
        return @intFromEnum(ExitCode.validation);
    }
    return success(context, "doctor", human.written(), json.written());
}

const OutputArguments = struct {
    input_path: []const u8 = ".",
    output_path: ?[]const u8 = null,
    force: bool = false,
    format: ?export_data.TokenFormat = null,
};

fn parseOutputArguments(arguments: []const []const u8, needs_format: bool) !OutputArguments {
    var result: OutputArguments = .{};
    var input_seen = false;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--force")) {
            result.force = true;
        } else if (std.mem.eql(u8, argument, "-o") or std.mem.eql(u8, argument, "--output")) {
            index += 1;
            if (index >= arguments.len) return error.MissingOptionValue;
            result.output_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--format")) {
            if (!needs_format) return error.UnknownOption;
            index += 1;
            if (index >= arguments.len) return error.MissingOptionValue;
            result.format = export_data.TokenFormat.parse(arguments[index]) orelse return error.InvalidFormat;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return error.UnknownOption;
        } else if (input_seen) {
            return error.TooManyArguments;
        } else {
            result.input_path = argument;
            input_seen = true;
        }
    }
    if (needs_format and result.format == null) return error.MissingFormat;
    return result;
}

fn outputPayload(
    allocator: std.mem.Allocator,
    kind: []const u8,
    output_path: ?[]const u8,
    content: []const u8,
) !struct { human: []u8, json: []u8 } {
    var human: []u8 = undefined;
    if (output_path) |path| {
        human = try std.fmt.allocPrint(allocator, "Wrote {s} to {s}.\n", .{ kind, path });
    } else {
        human = try allocator.dupe(u8, content);
    }
    var json: std.Io.Writer.Allocating = .init(allocator);
    errdefer json.deinit();
    try json.writer.writeAll("{\"kind\":");
    try writeJsonString(&json.writer, kind);
    if (output_path) |path| {
        try json.writer.writeAll(",\"output\":");
        try writeJsonString(&json.writer, path);
    } else {
        try json.writer.writeAll(",\"content\":");
        try writeJsonString(&json.writer, content);
    }
    try json.writer.writeByte('}');
    return .{ .human = human, .json = try json.toOwnedSlice() };
}

fn commandExport(context: *Context, arguments: []const []const u8) !u8 {
    const parsed = parseOutputArguments(arguments, true) catch |err| {
        return usage(context, errorMessage(err));
    };
    const format = parsed.format.?;
    const generated = export_data.generateTokens(
        context.allocator,
        context.io,
        parsed.input_path,
        format,
    ) catch |err| return validationFailure(context, err);
    if (parsed.output_path) |path| {
        export_data.writeOutput(context.io, path, generated, parsed.force) catch |err| {
            return filesystemFailure(context, err);
        };
    }
    const payload = try outputPayload(context.allocator, format.label(), parsed.output_path, generated);
    return success(context, "export", payload.human, payload.json);
}

fn commandCompileBook(context: *Context, arguments: []const []const u8) !u8 {
    const parsed = parseOutputArguments(arguments, false) catch |err| {
        return usage(context, errorMessage(err));
    };
    const generated = export_data.compileBook(context.allocator, context.io, parsed.input_path) catch |err| {
        return validationFailure(context, err);
    };
    if (parsed.output_path) |path| {
        export_data.writeOutput(context.io, path, generated, parsed.force) catch |err| {
            return filesystemFailure(context, err);
        };
    }
    const payload = try outputPayload(context.allocator, "brand-book", parsed.output_path, generated);
    return success(context, "compile-book", payload.human, payload.json);
}

fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn apiCall(
    context: *Context,
    command: []const u8,
    endpoint: []const u8,
    query: []const [2][]const u8,
) !u8 {
    const url = api.buildUrl(context.allocator, context.options.api_base_url, endpoint, query) catch |err| {
        return networkFailure(context, err);
    };
    const response = api.fetch(
        context.allocator,
        context.io,
        url,
        context.options.timeout_seconds,
    ) catch |err| return networkFailure(context, err);
    return success(context, command, response.body, response.body);
}

fn commandApi(context: *Context, arguments: []const []const u8) !u8 {
    if (arguments.len == 0) return usage(context, "api requires a subcommand.");
    const subcommand = arguments[0];
    const rest = arguments[1..];
    var query_storage: [2][2][]const u8 = undefined;
    var query_len: usize = 0;

    if (std.mem.eql(u8, subcommand, "health")) {
        var index: usize = 0;
        while (index < rest.len) : (index += 1) {
            if (!std.mem.eql(u8, rest[index], "--detail") or index + 1 >= rest.len) return usage(context, "health accepts --detail full|status.");
            index += 1;
            if (!oneOf(rest[index], &.{ "full", "status" })) return usage(context, "health detail must be full or status.");
            query_storage[query_len] = .{ "detail", rest[index] };
            query_len += 1;
        }
        return apiCall(context, "api health", "/api/v1/health", query_storage[0..query_len]);
    }
    if (std.mem.eql(u8, subcommand, "release")) {
        var index: usize = 0;
        while (index < rest.len) : (index += 1) {
            const option = rest[index];
            index += 1;
            if (index >= rest.len) return usage(context, "release option is missing a value.");
            const value = rest[index];
            if (std.mem.eql(u8, option, "--platform")) {
                if (!oneOf(value, &.{ "windows", "macos", "linux" })) return usage(context, "release platform is invalid.");
                query_storage[query_len] = .{ "platform", value };
            } else if (std.mem.eql(u8, option, "--channel")) {
                if (!oneOf(value, &.{ "stable", "alpha", "beta" })) return usage(context, "release channel is invalid.");
                query_storage[query_len] = .{ "channel", value };
            } else return usage(context, "release received an unknown option.");
            query_len += 1;
        }
        return apiCall(context, "api release", "/api/v1/release/latest", query_storage[0..query_len]);
    }
    if (std.mem.eql(u8, subcommand, "tools")) {
        var index: usize = 0;
        while (index < rest.len) : (index += 1) {
            const option = rest[index];
            index += 1;
            if (index >= rest.len) return usage(context, "tools option is missing a value.");
            const value = rest[index];
            if (std.mem.eql(u8, option, "--category")) {
                query_storage[query_len] = .{ "category", value };
            } else if (std.mem.eql(u8, option, "--query")) {
                query_storage[query_len] = .{ "q", value };
            } else return usage(context, "tools received an unknown option.");
            query_len += 1;
        }
        return apiCall(context, "api tools", "/api/v1/tools", query_storage[0..query_len]);
    }
    if (std.mem.eql(u8, subcommand, "tool")) {
        if (rest.len != 1 or rest[0].len == 0) return usage(context, "tool requires exactly one slug.");
        var endpoint: std.Io.Writer.Allocating = .init(context.allocator);
        defer endpoint.deinit();
        try endpoint.writer.writeAll("/api/v1/tools/");
        try api.appendQueryValue(&endpoint.writer, rest[0]);
        return apiCall(context, "api tool", endpoint.written(), &.{});
    }
    if (std.mem.eql(u8, subcommand, "schema")) {
        if (rest.len != 0) {
            if (rest.len != 2 or !std.mem.eql(u8, rest[0], "--version") or !std.mem.eql(u8, rest[1], "1.0.0")) {
                return usage(context, "schema accepts only --version 1.0.0.");
            }
            query_storage[0] = .{ "version", rest[1] };
            query_len = 1;
        }
        return apiCall(context, "api schema", "/api/v1/brand-guide/schema", query_storage[0..query_len]);
    }
    if (std.mem.eql(u8, subcommand, "agent-info")) {
        if (rest.len != 0) {
            if (rest.len != 2 or !std.mem.eql(u8, rest[0], "--include") or !oneOf(rest[1], &.{ "all", "functions", "guidance" })) {
                return usage(context, "agent-info accepts --include all|functions|guidance.");
            }
            query_storage[0] = .{ "include", rest[1] };
            query_len = 1;
        }
        return apiCall(context, "api agent-info", "/api/v1/agent-info", query_storage[0..query_len]);
    }
    if (std.mem.eql(u8, subcommand, "cli-manifest")) {
        if (rest.len != 0) {
            if (rest.len != 2 or !std.mem.eql(u8, rest[0], "--platform") or !oneOf(rest[1], &.{ "windows", "macos", "linux" })) {
                return usage(context, "cli-manifest accepts --platform windows|macos|linux.");
            }
            query_storage[0] = .{ "platform", rest[1] };
            query_len = 1;
        }
        return apiCall(context, "api cli-manifest", "/api/v1/cli/manifest", query_storage[0..query_len]);
    }
    return usage(context, "Unknown api subcommand.");
}

pub fn run(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    var options: Options = .{};
    if (init.environ_map.get("BRANDPEEL_API_BASE_URL")) |base_url| options.api_base_url = base_url;

    var index: usize = 1;
    while (index < arguments.len) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--json")) {
            options.json = true;
            index += 1;
        } else if (std.mem.eql(u8, argument, "--api-base-url")) {
            index += 1;
            if (index >= arguments.len) {
                var context: Context = .{ .allocator = allocator, .io = init.io, .stdout = stdout, .stderr = stderr, .options = options };
                return usage(&context, "--api-base-url requires a value.");
            }
            options.api_base_url = arguments[index];
            index += 1;
        } else if (std.mem.eql(u8, argument, "--timeout")) {
            index += 1;
            if (index >= arguments.len) {
                var context: Context = .{ .allocator = allocator, .io = init.io, .stdout = stdout, .stderr = stderr, .options = options };
                return usage(&context, "--timeout requires a value.");
            }
            options.timeout_seconds = std.fmt.parseInt(u32, arguments[index], 10) catch 0;
            if (options.timeout_seconds == 0 or options.timeout_seconds > 300) {
                var context: Context = .{ .allocator = allocator, .io = init.io, .stdout = stdout, .stderr = stderr, .options = options };
                return usage(&context, "--timeout must be between 1 and 300 seconds.");
            }
            index += 1;
        } else break;
    }

    var context: Context = .{
        .allocator = allocator,
        .io = init.io,
        .stdout = stdout,
        .stderr = stderr,
        .options = options,
    };
    if (index >= arguments.len or std.mem.eql(u8, arguments[index], "--help") or std.mem.eql(u8, arguments[index], "-h")) {
        return success(&context, "help", help_text, "{\"version\":\"0.1.0\"}");
    }
    if (std.mem.eql(u8, arguments[index], "--version") or std.mem.eql(u8, arguments[index], "-V")) {
        return success(&context, "version", "brandpeel 0.1.0", "{\"version\":\"0.1.0\"}");
    }

    const command = arguments[index];
    const rest = arguments[index + 1 ..];
    if (std.mem.eql(u8, command, "inspect")) return commandInspect(&context, rest);
    if (std.mem.eql(u8, command, "doctor")) return commandDoctor(&context, rest);
    if (std.mem.eql(u8, command, "export")) return commandExport(&context, rest);
    if (std.mem.eql(u8, command, "compile-book")) return commandCompileBook(&context, rest);
    if (std.mem.eql(u8, command, "api")) return commandApi(&context, rest);
    return usage(&context, "Unknown Brand Peel command. Run brandpeel --help.");
}

test "output parser requires a token format" {
    try std.testing.expectError(error.MissingFormat, parseOutputArguments(&.{"."}, true));
}

test "output parser handles force and output path" {
    const parsed = try parseOutputArguments(&.{ ".", "--format", "css", "-o", "tokens.css", "--force" }, true);
    try std.testing.expectEqualStrings(".", parsed.input_path);
    try std.testing.expectEqualStrings("tokens.css", parsed.output_path.?);
    try std.testing.expect(parsed.force);
    try std.testing.expectEqual(export_data.TokenFormat.css, parsed.format.?);
}

test "enum validation rejects unknown API values" {
    try std.testing.expect(oneOf("linux", &.{ "windows", "macos", "linux" }));
    try std.testing.expect(!oneOf("freebsd", &.{ "windows", "macos", "linux" }));
}
