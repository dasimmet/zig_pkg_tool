const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const deppkg_step = b.step("deppkg", "create .tar.gz packages of dependencies");
    const depPkgArc = depPackagesInternal(b, b, .{
        .name = "depkg",
        .opt = .debug,
    });
    const depPkgInstall = b.addInstallFile(
        depPkgArc,
        "share/pkgtool-deppkg.tar.gz",
    );
    b.default_step.dependOn(&depPkgInstall.step);
    deppkg_step.dependOn(&depPkgInstall.step);

    const zigpkg_mod = b.addModule("zigpkg", .{
        .root_source_file = b.path("src/zigpkg.zig"),
        .target = target,
        .optimize = opt,
    });
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    zigpkg_mod.addImport("known-folders", known_folders);

    const zigpkg = build_zigpkg(b, target, opt);
    b.installArtifact(zigpkg);
    b.step("exe", "").dependOn(&b.addInstallArtifact(zigpkg, .{}).step);

    const zigpkg_run = b.addRunArtifact(zigpkg);
    zigRunEnv(b, zigpkg_run);

    zigpkg_run.addPassthruArgs();
    b.step("zigpkg", "zigpkg cli").dependOn(&zigpkg_run.step);

    const tests = b.addTest(.{
        .root_module = zigpkg.root_module,
        .use_llvm = true,
    });
    const test_run = b.addRunArtifact(tests);
    b.step("test", "run tests").dependOn(&test_run.step);
    b.default_step.dependOn(&test_run.step);
    {
        const dotgraph = dotGraphStepInternal(b, zigpkg, &.{}).captureStdOut(.{});
        const svggraph = svgGraph(b, dotgraph);

        const update_dotgraph = b.addUpdateSourceFiles();
        update_dotgraph.addCopyFileToSource(dotgraph, "graph.dot");
        update_dotgraph.addCopyFileToSource(svggraph, "graph.svg");
        b.step("dot", "generate dot graph").dependOn(&update_dotgraph.step);
    }

    b.step("fmt", "format source code").dependOn(&b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path("src"),
            b.path("example/build.zig"),
            b.path("example/build.zig.zon"),
            b.path("example/src"),
        },
    }).step);

    const print_cfg_cmd = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--print-configuration",
    });
    const tree_zon = print_cfg_cmd.captureStdOut(.{});
    const update_bs = b.addUpdateSourceFiles();
    update_bs.addCopyFileToSource(tree_zon, "build.tree.zon");
    const update_bs_step = b.step("update-build-tree", "update build.tree.zon");
    update_bs_step.dependOn(&update_bs.step);
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
        b.root.root_dir.path orelse ".",
    });
    zigRunEnv(b, dotgraph);

    dotgraph.addArgs(args);
    return dotgraph;
}

fn zigRunEnv(b: *std.Build, run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("ZIG", b.graph.zig_exe);
}

pub fn build_zigpkg(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const zigpkg = b.addExecutable(.{
        .name = "zigpkg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zigpkg.zig"),
            .target = target,
            .optimize = opt,
            .link_libc = if (target.result.os.tag == .windows) true else null,
        }),
    });

    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    zigpkg.root_module.addImport("known-folders", known_folders);
    return zigpkg;
}

pub const DepPackageOptions = struct {
    name: []const u8,
    opt: std.builtin.OptimizeMode = .safe,
};

pub fn depPackagesStep(b: *std.Build, opt: DepPackageOptions) std.Build.LazyPath {
    const this_b = b.dependencyFromBuildZig(@This(), {}).builder;
    return depPackagesInternal(b, this_b, opt);
}

fn depPackagesInternal(b: *std.Build, this_b: *std.Build, opt: DepPackageOptions) std.Build.LazyPath {
    const print_cfg_cmd = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--print-configuration",
    });
    const zon_file = print_cfg_cmd.captureStdOut(.{});
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
    run.addArg(b.root.root_dir.path orelse ".");
    run.addFileArg(zon_file);
    return out_file;
}
