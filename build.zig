const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "menuconfig",
        .root_source_file = b.path("src/menuconfig.zig"),
        .target = target,
        .optimize = opt,
    });
    const run = b.addRunArtifact(exe);
    b.installArtifact(exe);

    const dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = opt,
    });
    exe.root_module.addImport("vaxis", dep.module("vaxis"));

    const config_step = b.step("menuconfig", "example menu");
    config_step.dependOn(&run.step);
}
