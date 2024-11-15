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

    depPackages(b);
}

pub fn depPackages(b: *std.Build) void {
    const build_runner = @import("root");
    const deps = build_runner.dependencies;
    const exe = b.addExecutable(.{
        .name = "targz",
        .root_source_file = b.path("src/targz.zig"),
        .target = b.host,
        .optimize = .ReleaseFast,
    });
    const deppkg_step = b.step("deppkg", "create .tar.gz packages of dependencies");
    inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        const hash = decl.name;
        const dep = @field(deps.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            const build_root = dep.build_root;
            const depPkg = b.addRunArtifact(exe);
            depPkg.addArg(build_root);
            const basename = hash ++ ".tar.gz";
            const depPkgOut = depPkg.addOutputFileArg(basename);

            const depPkgInstall = b.addInstallFile(depPkgOut, "deppkg/" ++ basename);
            // b.default_step.dependOn(&depPkgInstall.step);
            deppkg_step.dependOn(&depPkgInstall.step);
        }
    }
}
