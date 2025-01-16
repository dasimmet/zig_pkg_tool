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
            try tar_args.append(try std.fmt.allocPrint(gpa, "{s}:{s}", .{ hash, dep.build_root }));
        }
    }

    try process(output_file, tar_args.items, gpa);
}

pub fn process(out_path: []const u8, args: []const []const u8, gpa: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_allocator.allocator();
    defer arena_allocator.deinit();

    const cwd = std.fs.cwd();
    std.log.info("writing deppk tar.gz: {s}", .{out_path});
    var output = try cwd.createFile(out_path, .{});
    defer output.close();

    var compress = try std.compress.gzip.compressor(output.writer(), .{});
    defer compress.finish() catch @panic("compress finish error");

    var archive = std.tar.writer(compress.writer().any());
    defer archive.finish() catch @panic("archive finish error");

    var archiveRoot: []const u8 = undefined;

    next_arg: for (args, 0..) |arg, i| {
        const split = std.mem.indexOf(u8, arg, ":") orelse {
            std.log.err("invalid arg: {s}", .{arg});
            return error.InvalidArg;
        };
        const hash = arg[0..split];
        const path = arg[split + 1 ..];

        for (args, 0..) |arg_check, j| {
            if (i != j and try argStartsWith(arg_check, path)) continue :next_arg;
        }

        std.log.info("dep: {s}:{s}", .{ hash, path });

        if (std.mem.eql(u8, hash, "root")) {
            archiveRoot = try arena.dupe(u8, "root");
        } else {
            archiveRoot = try std.fmt.allocPrint(arena, "p/{s}", .{hash});
        }
        try archive.setRoot("");
        try archive.setRoot(archiveRoot);

        var input = try cwd.openDir(path, .{
            .iterate = true,
            .access_sub_paths = true,
        });
        defer input.close();

        var iter = try input.walk(gpa);
        defer iter.deinit();
        outer: while (try iter.next()) |entry| {
            inline for (&.{
                ".zig-cache",
                "zig-out",
                ".git",
                ".svn",
                ".venv",
                "_venv",
                ".spin",
            }) |ignore| {
                if (std.mem.indexOf(u8, entry.path, ignore)) |_| continue :outer;
            }
            archive.writeEntry(entry) catch |e| {
                switch (e) {
                    error.IsDir => continue,
                    else => return e,
                }
            };
        }
    }
}

fn argStartsWith(needle: []const u8, haystack: []const u8) !bool {
    const split = std.mem.indexOf(u8, needle, ":") orelse {
        std.log.err("invalid arg: {s}", .{needle});
        return error.InvalidArg;
    };
    const path = needle[split + 1 ..];
    return std.mem.startsWith(u8, haystack, path);
}
