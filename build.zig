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

    const deppkg_step = b.step("deppkg", "create .tar.gz packages of dependencies");
    const depPkgArc = depPackagesInternal(b, b, .{
        .name = "depkg",
        .opt = .Debug,
    });
    const depPkgInstall = b.addInstallFile(
        depPkgArc,
        "share/pkgtool-deppkg.tar.gz",
    );
    b.default_step.dependOn(&depPkgInstall.step);
    deppkg_step.dependOn(&depPkgInstall.step);

    _ = b.addModule("zigpkg", .{
        .root_source_file = b.path("src/zigpkg.zig"),
        .target = target,
        .optimize = opt,
    });

    const zigpkg = build_zigpkg(b, target, opt);
    b.installArtifact(zigpkg);
    b.step("exe", "").dependOn(&b.addInstallArtifact(zigpkg, .{}).step);

    const zigpkg_run = b.addRunArtifact(zigpkg);
    zigRunEnv(b, zigpkg_run);

    if (b.args) |args| zigpkg_run.addArgs(args);
    b.step("zigpkg", "zigpkg cli").dependOn(&zigpkg_run.step);

    const tests = b.addTest(.{
        .root_module = zigpkg.root_module,
        .use_llvm = true,
    });
    const test_run = b.addRunArtifact(tests);
    b.step("test", "run tests").dependOn(&test_run.step);
    b.default_step.dependOn(&test_run.step);
    {
        const dotgraph = dotGraphStepInternal(b, zigpkg, &.{}).captureStdOut();
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
        "dotall",
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

pub fn build_zigpkg(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const zigpkg = b.addExecutable(.{
        .name = "zigpkg",
        .root_module = b.addModule("zigpkg", .{
            .root_source_file = b.path("src/zigpkg.zig"),
            .target = target,
            .optimize = opt,
        }),
    });

    if (target.result.os.tag == .windows) {
        zigpkg.linkLibC();
    }
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    zigpkg.root_module.addImport("known-folders", known_folders);
    return zigpkg;
}

pub const DepPackageOptions = struct {
    name: []const u8,
    opt: std.builtin.OptimizeMode = .ReleaseSafe,
};

pub fn depPackagesStep(b: *std.Build, opt: DepPackageOptions) std.Build.LazyPath {
    const this_b = b.dependencyFromBuildZig(@This(), {}).builder;
    return depPackagesInternal(b, this_b, opt);
}

fn depPackagesInternal(b: *std.Build, this_b: *std.Build, opt: DepPackageOptions) std.Build.LazyPath {
    const zon_source = Serialize.serializeBuild(b, .{
        .whitespace = false,
        .emit_default_optional_fields = false,
    }) catch @panic("Build Serialize");
    const wf = b.addWriteFiles();
    const zon_file = wf.add("buildgraph.zon", zon_source);
    const out_basename = b.fmt("{s}{s}", .{ opt.name, ".tar.gz" });

    const zigpkg = build_zigpkg(
        this_b,
        this_b.graph.host,
        opt.opt,
    );
    const run = b.addRunArtifact(zigpkg);
    zigRunEnv(b, run);
    run.addArgs(&.{
        "deppkg",
        "from-zon",
    });
    const out_file = run.addOutputFileArg(out_basename);
    run.addArg(b.build_root.path.?);
    run.addFileArg(zon_file);
    return out_file;
}
