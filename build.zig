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
    b.installArtifact(exe);
    b.step("exe", "install menuconfig").dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run = b.addRunArtifact(exe);
    run.setEnvironmentVariable("ZIG_CACHE_DIR", b.cache_root.path.?);

    if (b.lazyDependency("vaxis", .{
        .target = target,
        .optimize = opt,
    })) |vaxis| {
        exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    }

    const config_step = b.step("menuconfig", "example menu");
    config_step.dependOn(&run.step);

    const deppkg_step = b.step("deppkg", "create .tar.gz packages of dependencies");
    const depPkgArc = depPackagesInternal(b, .{ .name = "depkg" });
    const depPkgInstall = b.addInstallFile(
        depPkgArc,
        "deppkg/deppkg.tar.gz",
    );
    b.default_step.dependOn(&depPkgInstall.step);
    deppkg_step.dependOn(&depPkgInstall.step);

    const zigpkg = b.addExecutable(.{
        .name = "zigpkg",
        .root_source_file = b.path("src/zigpkg.zig"),
        .target = target,
        .optimize = opt,
    });
    if (target.result.os.tag == .windows) {
        zigpkg.linkLibC();
    }
    b.installArtifact(zigpkg);

    const zigpkg_run = b.addRunArtifact(zigpkg);
    zigpkg_run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    if (b.args) |args| zigpkg_run.addArgs(args);
    b.step("zigpkg", "zigpkg cli").dependOn(&zigpkg_run.step);
}

pub const DepPackageOptions = struct {
    name: []const u8,
};

pub fn depPackagesStep(b: *std.Build, opt: DepPackageOptions) std.Build.LazyPath {
    const this_b = b.dependencyFromBuildZig(@This(), {}).builder;
    return depPackagesInternal(this_b, opt);
}

fn depPackagesInternal(b: *std.Build, opt: DepPackageOptions) std.Build.LazyPath {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const exe = b.addExecutable(.{
        .name = "pkg-targz",
        .root_source_file = b.path("src/pkg-targz.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const depPkg = b.addRunArtifact(exe);
    const basename = b.fmt("{s}{s}", .{ opt.name, ".tar.gz" });
    const depPkgOut = depPkg.addOutputFileArg(basename);

    depPkg.setEnvironmentVariable("ZIG_BUILD_ROOT", b.build_root.path.?);

    const global_cache = b.graph.global_cache_root.path.?;
    depPkg.setEnvironmentVariable("ZIG_GLOBAL_CACHE", global_cache);

    inline for (comptime std.meta.declarations(deps.packages)) |decl| {
        const hash = decl.name;
        const dep = @field(deps.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            if (std.mem.startsWith(u8, dep.build_root, global_cache)) {
                const cache_dir = std.fs.path.basename(dep.build_root);
                const arg = b.fmt("{s}:{s}", .{ cache_dir, cache_dir });
                depPkg.addArg(arg);
            }
        }
    }

    return depPkgOut;
}
