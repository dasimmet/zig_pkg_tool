const std = @import("std");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");
pub const targz = @import("src/targz.zig");
pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer {
        switch (gpa_alloc.deinit()) {
            .leak => @panic("GPA MEMORY LEAK"),
            .ok => {},
        }
    }

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // std.debug.print("args:\n", .{});
    // for (args) |arg| std.debug.print(" {s}", .{ arg });
    // std.debug.print("\n", .{});

    if (args.len != 10) {
        std.log.err("usage: zig build --build-runner <path to runner> <output file>", .{});
        return;
    }

    const zig_exe = args[1];
    _ = zig_exe;
    const zig_lib_dir = args[2];
    _ = zig_lib_dir;
    const build_root = args[3];
    const cache_dir = args[4];
    _ = cache_dir;
    const output_file = args[9];

    var tar_paths = std.ArrayList([]const u8).init(gpa);
    try tar_paths.append("build/root");
    defer {
        for (tar_paths.items[1..]) |it| {
            gpa.free(it);
        }
        tar_paths.deinit();
    }

    var fs_paths = std.ArrayList([]const u8).init(gpa);
    defer {
        fs_paths.deinit();
    }
    try fs_paths.append(build_root);

    var add_pkg_to_arc: bool = true;
    inline for (comptime std.meta.declarations(dependencies.packages)) |decl| {
        add_pkg_to_arc = true;
        const hash = decl.name;
        const dep = @field(dependencies.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            const tar_path = try std.fmt.allocPrint(gpa, "build/p/{s}", .{hash});

            for (fs_paths.items, 0..) |parent_check, j| {
                if (std.mem.startsWith(u8, dep.build_root, parent_check)) {
                    add_pkg_to_arc = false;
                }
                if (std.mem.startsWith(u8, parent_check, dep.build_root)) {
                    _ = tar_paths.orderedRemove(j);
                    _ = fs_paths.orderedRemove(j);
                }
            }
            if (add_pkg_to_arc) {
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
}
