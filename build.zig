const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_module = b.addModule("brandpeel", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executable = b.addExecutable(.{
        .name = "brandpeel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "brandpeel", .module = cli_module },
            },
        }),
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| run_command.addArgs(arguments);
    const run_step = b.step("run", "Run the Brand Peel CLI");
    run_step.dependOn(&run_command.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Brand Peel CLI unit tests");
    test_step.dependOn(&run_tests.step);
}
