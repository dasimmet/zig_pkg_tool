const std = @import("std");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");
pub const targz = @import("src/targz.zig");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // for (args) |arg| std.debug.print(" {s}", .{ arg });
    // std.debug.print("\n", .{});

    const zig_exe = args[1];
    _ = zig_exe;
    const zig_lib_dir = args[2];
    _ = zig_lib_dir;
    const build_root = args[3];
    const cache_dir = args[4];
    _ = cache_dir;
    const extra_args = args[9..];
    // for (extra_args) |arg| std.debug.print(" {s}", .{ arg });
    // std.debug.print("\n", .{});

    if (extra_args.len != 1) {
        std.log.err("usage: zig build --build-runner <path to runner> <output file>", .{});
        return error.NotEnoughArguments;
    }
    const output_file = extra_args[0];

    var tar_args = std.ArrayList([]const u8).init(gpa);
    defer {
        for (tar_args.items) |it| {
            gpa.free(it);
        }
        tar_args.deinit();
    }
    try tar_args.append(try std.fmt.allocPrint(gpa, "root:{s}", .{build_root}));

    inline for (@typeInfo(dependencies.packages).@"struct".decls) |decl| {
        const hash = decl.name;
        const dep = @field(dependencies.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            try tar_args.append(try std.fmt.allocPrint(gpa, "{s}:{s}", .{hash,dep.build_root}));
        }
    }
    try targz.process(output_file, tar_args.items, gpa);
}
