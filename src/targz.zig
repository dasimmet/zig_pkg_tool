const std = @import("std");
const tar = std.tar;
const gzip = std.compress.gzip;

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
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const cache_dir = env_map.get("ZIG_GLOBAL_CACHE") orelse {
        std.log.err("Need ZIG_GLOBAL_CACHE environment variable\n", .{});
        return error.MissingEnvironmentVariable;
    };
    const package_dir = try std.fs.path.join(gpa, &.{ cache_dir, "p" });
    defer gpa.free(package_dir);

    const build_root = env_map.get("ZIG_BUILD_ROOT") orelse {
        std.log.err("Need ZIG_BUILD_ROOT environment variable\n", .{});
        return error.MissingEnvironmentVariable;
    };

    if (args.len < 3) {
        std.log.err("usage: targz <output file> [<hash>:<dir>]", .{});
        return error.NotEnoughArguments;
    }

    var tar_paths = std.ArrayList([]const u8).init(gpa);
    defer tar_paths.deinit();
    try tar_paths.append("build/root");

    var fs_paths = std.ArrayList([]const u8).init(gpa);
    defer fs_paths.deinit();
    try fs_paths.append(build_root);

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_allocator.allocator();
    defer arena_allocator.deinit();

    next_arg: for (args[2..]) |arg| {
        const split = std.mem.indexOf(u8, arg, ":") orelse {
            std.log.err("invalid arg: {s}", .{arg});
            return error.InvalidArg;
        };
        const hash = arg[0..split];

        var package_path: []const u8 = undefined;
        const archiveRoot: []const u8 = try std.fmt.allocPrint(arena, "build/p/{s}", .{hash});

        if (std.mem.eql(u8, hash, "root")) {
            package_path = try arena.dupe(u8, arg[split + 1 ..]);
        } else {
            package_path = try std.fs.path.join(arena, &.{ package_dir, arg[split + 1 ..] });
        }
        for (fs_paths.items, 0..) |parent_check, j| {
            if (std.mem.startsWith(u8, package_path, parent_check)) {
                continue :next_arg;
            } else if (std.mem.startsWith(u8, parent_check, package_path)) {
                _ = tar_paths.orderedRemove(j);
                _ = fs_paths.orderedRemove(j);
            }
        }
        try tar_paths.append(archiveRoot);
        try fs_paths.append(package_path);
    }

    try process(.{
        .gpa = gpa,
        .out_path = args[1],
        .tar_paths = tar_paths.items,
        .fs_paths = fs_paths.items,
    });
}

const Options = struct {
    gpa: std.mem.Allocator,
    out_path: []const u8,
    tar_paths: []const []const u8,
    fs_paths: []const []const u8,
};

pub fn process(opt: Options) !void {
    std.debug.assert(opt.fs_paths.len == opt.tar_paths.len);

    const cwd = std.fs.cwd();
    std.log.info("writing deppk tar.gz: {s}", .{opt.out_path});
    var output = try cwd.createFile(opt.out_path, .{});
    defer output.close();

    var compress = try std.compress.gzip.compressor(output.writer(), .{});
    defer compress.finish() catch @panic("compress finish error");

    var archive = std.tar.writer(compress.writer().any());
    defer archive.finish() catch @panic("archive finish error");

    for (opt.fs_paths, 0..) |fs_path, i| {
        const archive_path = opt.tar_paths[i];

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

        var iter = try input.walk(opt.gpa);
        defer iter.deinit();
        outer: while (try iter.next()) |entry| {
            for (ignores) |ignore| {
                if (std.mem.indexOf(u8, entry.path, ignore)) |_| continue :outer;
            }
            var arc_entry: @TypeOf(entry) = entry;

            if (@import("builtin").os.tag == .windows) {
                const arc_path = try opt.gpa.dupeZ(u8, entry.path);
                defer opt.gpa.free(arc_path);
                _ = std.mem.replace(u8, entry.path, std.fs.path.sep_str, std.fs.path.sep_str_posix, arc_path);
                arc_entry.path = arc_path;
            }

            archive.writeEntry(arc_entry) catch |e| {
                switch (e) {
                    error.IsDir => continue,
                    else => return e,
                }
            };
        }
    }

    std.log.info("written deppk tar.gz: {s}", .{opt.out_path});
}
