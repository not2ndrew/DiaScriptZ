const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const frontend = b.addModule("frontend", .{
        .root_source_file = b.path("src/frontend.zig"),
        .target = target,
    });

    const util = b.addModule("util", .{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "frontend", .module = frontend },
        },
    });

    const exe = b.addExecutable(.{
        .name = "DiaScriptZ",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "frontend", .module = frontend },
                .{ .name = "util", .module = util },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
