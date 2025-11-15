const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Manifest = @import("Manifest.zig");
const tar = std.tar;
const flate = @import("flate/flate.zig");

pub const default_ignores: []const []const u8 = &.{
    "zig-cache/",
    ".zig-cache/",
    "zig-out/",
    ".git/",
    ".svn/",
    ".venv/",
    "_venv/",
    ".spin/",
};

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const cache_dir = env_map.get("ZIG_GLOBAL_CACHE_DIR") orelse {
        std.log.err("Need ZIG_GLOBAL_CACHE_DIR environment variable\n", .{});
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

    var tar_paths = std.array_list.Managed([]const u8).init(gpa);
    defer tar_paths.deinit();

    var fs_paths = std.array_list.Managed([]const u8).init(gpa);
    defer fs_paths.deinit();

    try tar_paths.append("build/zig_version.txt");
    const zig_version_str = try std.mem.join(
        gpa,
        "",
        &.{ "raw:", builtin.zig_version_string, "\n" },
    );
    defer gpa.free(zig_version_str);
    try fs_paths.append(zig_version_str);

    try tar_paths.append("build/root");
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

const Serialized = @import("BuildSerialize.zig");

/// convert a std.Build zon to a tar.gz archive
pub fn fromBuild(
    gpa: std.mem.Allocator,
    build: Serialized,
    cache_root: []const u8,
    root: []const u8,
    out_path: []const u8,
) !void {
    var tar_paths_array = std.ArrayList([]const u8).empty;
    var tar_paths = tar_paths_array.toManaged(gpa);
    defer {
        for (tar_paths.items) |it| gpa.free(it);
        tar_paths.deinit();
    }

    var fs_paths_array = std.ArrayList([]const u8).empty;
    var fs_paths = fs_paths_array.toManaged(gpa);
    defer {
        for (fs_paths.items) |it| gpa.free(it);
        fs_paths.deinit();
    }

    for (build.dependencies, 0..) |dep, i| {
        if (i == 0) {
            std.debug.assert(dep.location == .root);
            try tar_paths.append(try gpa.dupe(u8, "build/root"));
            try fs_paths.append(try gpa.dupe(u8, root));
            var zon_file = std.Io.Writer.Allocating.init(gpa);
            try zon_file.writer.writeAll("raw:");
            try std.zon.stringify.serialize(build, .{
                .whitespace = true,
                .emit_default_optional_fields = false,
            }, &zon_file.writer);

            try tar_paths.append(try gpa.dupe(u8, "build/root.zon"));
            try fs_paths.append(try zon_file.toOwnedSlice());
        } else {
            switch (dep.location) {
                .root => {
                    std.log.err("unexpected root dep: {any}", .{dep});
                    return error.Unexpected;
                },
                .cache => {
                    const fs_p = try std.fs.path.join(
                        gpa,
                        &.{ cache_root, "p", dep.name },
                    );

                    const tar_p = try std.fmt.allocPrint(
                        gpa,
                        "build/p/{s}",
                        .{dep.name},
                    );

                    try tar_paths.append(tar_p);
                    try fs_paths.append(fs_p);
                },
                .root_sub => {},
                .cache_sub => {},
                .unknown => {
                    std.log.err("unknown dep: {any}", .{dep});
                    return error.Unexpected;
                },
            }
        }
    }

    return process(.{
        .gpa = gpa,
        .out_path = out_path,
        .tar_paths = tar_paths.items,
        .fs_paths = fs_paths.items,
    });
}

const Options = struct {
    gpa: std.mem.Allocator,
    out_path: []const u8,
    tar_paths: []const []const u8, // paths inside the tar archive. the fist element is expected to be "root"
    fs_paths: []const []const u8, // paths to directories on the local filesystem
};

/// convert a list of zig package directories to a tar.gz archive
pub fn process(opt: Options) !void {
    std.debug.assert(opt.fs_paths.len == opt.tar_paths.len);

    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(opt.out_path)) |dir| {
        try cwd.makePath(dir);
    }

    var out_file = try cwd.createFile(opt.out_path, .{});
    defer out_file.close();
    var out_buf: [8192]u8 = undefined;
    var output = out_file.writer(&out_buf);

    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor: flate.Compress = try .init(
        &output.interface,
        &compress_buf,
        .gzip,
        .best,
    );

    var archive = std.tar.Writer{
        .underlying_writer = &compressor.writer,
    };

    var zon_src: std.Io.Writer.Allocating = .init(opt.gpa);
    defer zon_src.deinit();

    for (opt.fs_paths, 0..) |fs_path, i| {
        const archive_path = opt.tar_paths[i];

        try archive.setRoot("");

        if (std.mem.startsWith(u8, fs_path, "raw:")) {
            try archive.writeFileBytes(archive_path, fs_path["raw:".len..], .{});
            continue;
        }

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
        var manifest: ?Manifest = null;

        if (zon_file) |zf| {
            const zon_sliceZ: [:0]u8 = blk: {
                defer zf.close();
                zon_src.clearRetainingCapacity();
                var zfb: [8192]u8 = undefined;
                var zfr: std.fs.File.Reader = zf.reader(&zfb);
                _ = try zfr.interface.stream(&zon_src.writer, .unlimited);
                try zon_src.writer.writeByte(0);
                const zon_slice = zon_src.written();
                break :blk @ptrCast(zon_slice[0..if (zon_slice.len == 0) 0 else zon_slice.len - 1]);
            };

            var zonDiag: Manifest.ZonDiag = .{};
            defer zonDiag.deinit(opt.gpa);

            manifest = Manifest.fromSliceAlloc(
                opt.gpa,
                zon_sliceZ,
                &zonDiag,
            ) catch |e| {
                Manifest.log(std.log.err, e, fs_path, zonDiag);
                return e;
            };
        }

        defer {
            if (manifest) |mani| {
                mani.deinit(opt.gpa);
            }
        }

        var iter = try input.walk(opt.gpa);
        defer iter.deinit();
        outer: while (iter.next() catch |err| {
            std.log.err("error accessing: {s}\n{}\n", .{
                iter.name_buffer.items,
                err,
            });
            return err;
        }) |entry| {
            include_entry: {
                if (manifest) |mani| {
                    if (std.mem.eql(u8, entry.path, "build.zig.zon")) break :include_entry;
                    if (mani.paths) |paths| {
                        for (paths) |p| {
                            if (std.mem.startsWith(u8, entry.path, p)) {
                                break :include_entry;
                            }
                        }
                    } else {
                        for (default_ignores) |ignore| {
                            if (std.mem.indexOf(u8, entry.path, ignore)) |_| {
                                continue :outer;
                            }
                        }
                    }
                    continue :outer;
                } else {
                    for (default_ignores) |ignore| {
                        if (std.mem.indexOf(u8, entry.path, ignore)) |_| {
                            continue :outer;
                        }
                    }
                }
            }
            var arc_entry: @TypeOf(entry) = entry;

            if (@import("builtin").os.tag == .windows) {
                const arc_path = try opt.gpa.dupeZ(u8, entry.path);
                _ = std.mem.replace(u8, entry.path, std.fs.path.sep_str, std.fs.path.sep_str_posix, arc_path);
                arc_entry.path = arc_path;
            }
            if (@import("builtin").os.tag == .windows) {
                defer opt.gpa.free(arc_entry.path);
            }

            try writeTarEntry(&archive, &arc_entry);
        }
    }
    try archive.finishPedantically();
    try compressor.writer.flush();
    try output.interface.flush();
}

pub fn writeTarEntry(arc: *std.tar.Writer, entry: *std.fs.Dir.Walker.Entry) !void {
    const file = entry.dir.openFile(
        entry.basename,
        .{},
    ) catch |e| switch (e) {
        error.IsDir => return,
        else => return e,
    };
    defer file.close();

    switch (entry.kind) {
        .file => {
            var buf: [64]u8 = undefined;
            const stat = try entry.dir.statFile(entry.basename);
            var reader = file.reader(&buf);
            try arc.writeFileStream(
                entry.path,
                try reader.getSize(),
                &reader.interface,
                .{
                    .mode = 0,
                    .mtime = @intCast(@divFloor(stat.mtime, std.time.ns_per_s)),
                },
            );
        },
        else => return,
    }
}
