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

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = opt,
    });
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));

    const config_step = b.step("menuconfig", "example menu");
    config_step.dependOn(&run.step);

    depTree(b);

    const deppkg_step = b.step("deppkg", "create .tar.gz packages of dependencies");
    const depPkgInstall = b.addInstallFile( 
        depPackagesInternal(b, .{ .name = "depkg" }),
        "deppkg/deppkg.tar.gz",
    );
    deppkg_step.dependOn(&depPkgInstall.step);
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
        .root_source_file = b.path("src/targz.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const depPkg = b.addRunArtifact(exe);
    depPkg.has_side_effects = true;
    const basename = b.fmt("{s}{s}", .{ opt.name, ".tar.gz" });
    const depPkgOut = depPkg.addOutputFileArg(basename);

    depPkg.setEnvironmentVariable("ZIG_BUILD_ROOT", b.build_root.path.?);

    const global_cache = b.graph.global_cache_root.path.?;
    depPkg.setEnvironmentVariable("ZIG_GLOBAL_CACHE", global_cache);

    const cache_prefix_len = global_cache.len + std.fs.path.sep_str.len * 2 + "o".len;

    inline for (comptime std.meta.declarations(deps.packages)) |decl| {
        const hash = decl.name;
        const dep = @field(deps.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            if (!std.mem.startsWith(u8, dep.build_root, global_cache)) {
                std.log.err("yo: {s}", .{dep.build_root});
                @panic("yo");
            }
            const arg = b.fmt("{s}:{s}", .{ hash, dep.build_root[cache_prefix_len..] });
            depPkg.addArg(arg);
        }
    }

    return depPkgOut;
}

pub fn depTree(b: *std.Build) void {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const deppkg_step = b.step("deptree", "");

    var cmd: ?*std.Build.Step.Run = null;

    inline for (deps.root_deps) |decl| {
        const next_cmd = bPrint(b, "%s - %s\n", .{ decl[0], decl[1] });
        if (cmd) |c| c.step.dependOn(&next_cmd.step);
        cmd = next_cmd;
        for (@field(deps.packages, decl[1]).deps) |dep_decl| {
            const dep_next_cmd = bPrint(b, "%s - %s\n", .{ dep_decl[0], dep_decl[1] });
            if (cmd) |c| c.step.dependOn(&dep_next_cmd.step);
            cmd = next_cmd;
        }
    }
    if (deps.root_deps.len > 0) {
        deppkg_step.dependOn(&cmd.?.step);
    }
}

pub fn bPrint(b: *std.Build, fmt: []const u8, args: anytype) *std.Build.Step.Run {
    const next_cmd = b.addSystemCommand(&.{"printf"});
    next_cmd.stdio = .inherit;
    next_cmd.has_side_effects = true;
    next_cmd.addArg(fmt);
    inline for (args) |arg| {
        next_cmd.addArg(arg);
    }
    return next_cmd;
}
