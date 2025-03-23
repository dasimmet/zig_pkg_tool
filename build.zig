const std = @import("std");
// const zon = @import("build.zig.zon");
const Serialize = @import("src/BuildSerialize.zig");

pub fn build(b: *std.Build) void {
    const update_bsb = b.addUpdateSourceFiles();
    const bs_boring = Serialize.serializeBuildOrPanic(b, .{
        .whitespace = true,
        .emit_default_optional_fields = false,
    });
    update_bsb.addBytesToSource(bs_boring, "build.boring.tree.zon");

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
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    zigpkg.root_module.addImport("known-folders", known_folders);

    const zigpkg_run = b.addRunArtifact(zigpkg);
    zigRunEnv(b, zigpkg_run);

    if (b.args) |args| zigpkg_run.addArgs(args);
    b.step("zigpkg", "zigpkg cli").dependOn(&zigpkg_run.step);

    const tests = b.addTest(.{
        .root_module = zigpkg.root_module,
    });
    const test_run = b.addRunArtifact(tests);
    b.step("test", "run tests").dependOn(&test_run.step);
    b.default_step.dependOn(&test_run.step);
    {
        const dotgraph = dotGraphStepInternal(b, zigpkg, &.{
            "install",
            "exe",
            "deppkg",
            "zigpkg",
            "dot",
            "test",
            "fmt",
        }).captureStdOut();
        const svggraph = svgGraph(b, dotgraph);

        const update_dotgraph = b.addUpdateSourceFiles();
        update_dotgraph.addCopyFileToSource(dotgraph, "graph.dot");
        update_dotgraph.addCopyFileToSource(svggraph, "graph.svg");
        b.step("dot", "generate dot graph").dependOn(&update_dotgraph.step);
    }

    b.step("fmt", "format source code").dependOn(&b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src",
            "example/build.zig",
            "example/build.zig.zon",
            "example/src",
        },
    }).step);

    const update_bs = b.addUpdateSourceFiles();
    const update_bs_step = b.step("update-build-tree", "update build.tree.zon");
    update_bs_step.dependOn(&update_bs.step);
    update_bs_step.dependOn(&update_bsb.step);
    const bs = Serialize.serializeBuildOrPanic(b, .{
        .whitespace = true,
        .emit_default_optional_fields = false,
    });
    update_bs.addBytesToSource(bs, "build.tree.zon");
}

pub fn svgGraph(b: *std.Build, dotgraph: std.Build.LazyPath) std.Build.LazyPath {
    const svggraph = b.addSystemCommand(&.{
        "dot",
        "-Kdot",
        "-Tsvg",
        "-Goverlap=false",
        "-x",
        "-Ln100",
        "-LO",
        "-Lg",
    });
    svggraph.setName("dot to svg");
    const svggraph_out = svggraph.addPrefixedOutputFileArg("-o", "graph.svg");
    svggraph.addFileArg(dotgraph);
    return svggraph_out;
}

pub fn dotGraphStep(b: *std.Build, args: []const []const u8) *std.Build.Step.Run {
    const zigpkg = b.dependencyFromBuildZig(@This(), .{}).artifact("zigpkg");
    return dotGraphStepInternal(b, zigpkg, args);
}

fn dotGraphStepInternal(b: *std.Build, zigpkg: *std.Build.Step.Compile, args: []const []const u8) *std.Build.Step.Run {
    const dotgraph = b.addRunArtifact(zigpkg);
    dotgraph.setName("dot generation");
    dotgraph.addArgs(&.{
        "dot",
        b.build_root.path.?,
    });
    zigRunEnv(b, dotgraph);

    dotgraph.addArgs(args);
    return dotgraph;
}

fn zigRunEnv(b: *std.Build, run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    if (b.graph.zig_lib_directory.path) |lib_dir| {
        run.setEnvironmentVariable("ZIG_LIB_DIR", lib_dir);
    }
    if (b.cache_root.path) |cache_root| {
        run.setEnvironmentVariable("ZIG_LOCAL_CACHE_DIR", cache_root);
    }
    if (b.graph.global_cache_root.path) |cache_root| {
        run.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", cache_root);
    }
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
    depPkg.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", global_cache);

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
