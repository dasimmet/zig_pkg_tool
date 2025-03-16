const std = @import("std");
const builtin = @import("builtin");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");
pub const targz = @import("pkg-targz.zig");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer {
        switch (gpa_alloc.deinit()) {
            .leak => @panic("GPA MEMORY LEAK"),
            .ok => {},
        }
    }

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_alloc.allocator();
    defer arena_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 10) {
        std.log.err("usage: zig build --build-runner <path to runner> <output file>", .{});
        return;
    }
    // if (true) {
    //     return try @import("zig_build_runner.zig").mainBuild(.{
    //         .executeBuildFn = no_build,
    //         .ctx = undefined,
    //     });
    // }

    const zig_exe = args[1];
    _ = zig_exe;
    const zig_lib_dir = args[2];
    _ = zig_lib_dir;
    const build_root = args[3];
    const cache_dir = args[4];
    _ = cache_dir;
    const output_file = args[9];

    var tar_paths = std.ArrayList([]const u8).init(gpa);
    defer tar_paths.deinit();

    var fs_paths = std.ArrayList([]const u8).init(gpa);
    defer fs_paths.deinit();

    try tar_paths.append("build/zig_version.txt");
    try fs_paths.append(try std.mem.join(
        arena,
        "",
        &.{ "raw:", builtin.zig_version_string, "\n" },
    ));

    try tar_paths.append("build/root");
    try fs_paths.append(build_root);

    var add_pkg_to_arc: bool = true;
    inline for (comptime std.meta.declarations(dependencies.packages)) |decl| {
        add_pkg_to_arc = true;
        const hash = decl.name;
        const dep = @field(dependencies.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            var j: usize = fs_paths.items.len;
            while (j > 0) : (j -= 1) {
                const parent_check = fs_paths.items[j - 1];
                if (std.mem.startsWith(u8, parent_check, "raw:")) continue;
                if (std.mem.startsWith(u8, dep.build_root, parent_check)) {
                    add_pkg_to_arc = false;
                } else if (std.mem.startsWith(u8, parent_check, dep.build_root)) {
                    _ = tar_paths.orderedRemove(j - 1);
                    _ = fs_paths.orderedRemove(j - 1);
                }
            }
            if (add_pkg_to_arc) {
                const cache_hash = std.fs.path.basename(dep.build_root);

                const tar_path = try std.fmt.allocPrint(arena, "build/p/{s}", .{cache_hash});
                try tar_paths.append(tar_path);
                try fs_paths.append(dep.build_root);
            }
        }
    }

    try targz.process(.{
        .gpa = gpa,
        .out_path = output_file,
        .tar_paths = tar_paths.items,
        .fs_paths = fs_paths.items,
    });
    std.log.info("written deppk tar.gz: {s}", .{output_file});
}

pub fn no_build(b: *std.Build, ctx: ?*anyopaque) !void {
    _ = ctx;
    for (b.available_deps) |d| {
        std.log.info("dep: {s}:{s}", .{d[0], d[1]});
    }
    print_dep_steps(b, &b.install_tls.step, 0);
}

var i: usize = 0;
pub fn print_dep_steps(b: *std.Build, step: *std.Build.Step, depth: usize) !void {
    if (step.state == .success) return;
    step.state = .success;
    
    const stdout = std.io.getStdOut();
    try std.zon.stringify.serializeArbitraryDepth(.{
        .i = i,
        .depth = depth,
        .name = step.name,
        .build_root = step.owner.build_root.path.?,
    }, .{
        .whitespace = true,
    }, stdout.writer());
    try stdout.writer().writeAll("\n");
    // std.log.info("step {d} {d}: {s}", .{i, depth, step.name});
    // std.log.info("owner: {s}", .{});
    i += 1;
    for (step.dependencies.items) |dep_step| {
        try print_dep_steps(b, dep_step, depth + 1);
    }
}
