const std = @import("std");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");
pub const targz = @import("src/targz.zig");
pub const default_ignores = .{
    "zig-cache",
    ".zig-cache",
    "zig-out",
    ".git",
    ".svn",
    ".venv",
    "_venv",
    ".spin",
};

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

    inline for (comptime std.meta.declarations(dependencies.packages)) |decl| {
        const hash = decl.name;
        const dep = @field(dependencies.packages, hash);
        if (@hasDecl(dep, "build_root")) {
            const tar_path = try std.fmt.allocPrint(gpa, "build/p/{s}", .{hash});
            try tar_paths.append(tar_path);
            try fs_paths.append(dep.build_root);
        }
    }

    try process(output_file, tar_paths.items, fs_paths.items, gpa);
}

pub fn process(out_path: []const u8, tar_paths: []const []const u8, fs_paths: []const []const u8, gpa: std.mem.Allocator) !void {
    std.debug.assert(fs_paths.len == tar_paths.len);

    const cwd = std.fs.cwd();
    std.log.info("writing deppk tar.gz: {s}", .{out_path});
    var output = try cwd.createFile(out_path, .{});
    defer output.close();

    var compress = try std.compress.gzip.compressor(output.writer(), .{});
    defer compress.finish() catch @panic("compress finish error");

    var archive = std.tar.writer(compress.writer().any());
    defer archive.finish() catch @panic("archive finish error");

    next_arg: for (fs_paths, 0..) |fs_path, i| {
        for (fs_paths, 0..) |parent_check, j| {
            if (i != j and parent_check.len <= fs_path.len and std.mem.startsWith(u8, fs_path, parent_check)) {
                continue :next_arg;
            }
        }
        const archive_path = tar_paths[i];

        std.log.info("tar_path: {s}:{s}", .{ archive_path, fs_path });

        try archive.setRoot("");
        try archive.setRoot(archive_path);

        var input = try cwd.openDir(fs_path, .{
            .iterate = true,
            .access_sub_paths = true,
        });
        defer input.close();

        const zon_file = input.openFile("build.zig.zon", .{}) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        const ignores: []const []const u8 = &default_ignores;
        if (zon_file) |zf| {
            // TODO: import "files" filter based on "paths" once "std.zon" is available
            // also, we could update the dependencies to a relative path inside the archive,
            // and add top-level build.zig(.zon) files pointing to root
            //
            // for now we use a default "ignores" blacklist instead
            //
            // after extracting, ideally the generated top level file is equivalent to
            // the root with all dependencies insourced
            std.debug.print("zf: {any}\n", .{zf});
            zf.close();
        }

        var iter = try input.walk(gpa);
        defer iter.deinit();
        outer: while (try iter.next()) |entry| {
            for (ignores) |ignore| {
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

    std.log.info("written deppk tar.gz: {s}", .{out_path});
}

fn argStartsWith(needle: []const u8, haystack: []const u8) !bool {
    const split = std.mem.indexOf(u8, needle, ":") orelse {
        std.log.err("invalid arg: {s}", .{needle});
        return error.InvalidArg;
    };
    const path = needle[split + 1 ..];
    return std.mem.startsWith(u8, haystack, path);
}
