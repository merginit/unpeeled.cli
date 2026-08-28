const std = @import("std");
const brandpeel = @import("brandpeel");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    const code = brandpeel.cli.run(init, stdout, stderr) catch |err| {
        try stderr.print("error: unexpected internal failure ({s})\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(@intFromEnum(brandpeel.cli.ExitCode.internal));
    };
    try stdout.flush();
    try stderr.flush();
    if (code != 0) std.process.exit(code);
}
