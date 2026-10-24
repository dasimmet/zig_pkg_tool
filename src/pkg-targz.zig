const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Manifest = @import("Manifest.zig");
const tar = std.tar;
const flate = std.compress.flate;

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const env_map = init.environ_map;

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
        .io = io,
        .gpa = gpa,
        .out_path = args[1],
        .tar_paths = tar_paths.items,
        .fs_paths = fs_paths.items,
    });
}

pub fn collectDependencies(
    io: std.Io,
    gpa: std.mem.Allocator,
    cache_root: []const u8,
    dir_path: []const u8,
    deps_map: *std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    const cwd = std.Io.Dir.cwd();
    const zon_path = try std.fs.path.join(gpa, &.{ dir_path, "build.zig.zon" });
    defer gpa.free(zon_path);

    const zon_src = cwd.readFileAllocOptions(
        io,
        zon_path,
        gpa,
        std.Io.Limit.limited(10 * 1024 * 1024),
        std.mem.Alignment.@"1",
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(zon_src);

    const zon_srcZ = try gpa.dupeSentinel(u8, zon_src, 0);
    defer gpa.free(zon_srcZ);

    var diag: Manifest.ZonDiag = .{};
    defer diag.deinit(gpa);

    const manifest = Manifest.fromSliceAlloc(gpa, zon_srcZ, &diag) catch return;
    defer manifest.deinit(gpa);

    if (manifest.dependencies) |deps| {
        var it = deps.iterator();
        while (it.next()) |entry| {
            const dep = entry.value_ptr.*;
            if (dep.hash) |hash| {
                if (deps_map.contains(hash)) continue;
                const cache_p_dir = try std.fs.path.join(gpa, &.{ cache_root, "p", hash });
                const cache_p_tar = try std.fmt.allocPrint(gpa, "{s}.tar.gz", .{cache_p_dir});

                var found_path: ?[]const u8 = null;
                if (cwd.openDir(io, cache_p_dir, .{})) |d| {
                    d.close(io);
                    found_path = cache_p_dir;
                    gpa.free(cache_p_tar);
                } else |_| {
                    gpa.free(cache_p_dir);
                    if (cwd.openFile(io, cache_p_tar, .{})) |f| {
                        f.close(io);
                        found_path = cache_p_tar;
                    } else |_| {
                        gpa.free(cache_p_tar);
                    }
                }

                if (found_path) |fp| {
                    const owned_hash = try gpa.dupe(u8, hash);
                    try deps_map.put(gpa, owned_hash, fp);
                    if (!std.mem.endsWith(u8, fp, ".tar.gz")) {
                        try collectDependencies(io, gpa, cache_root, fp, deps_map);
                    }
                }
            } else if (dep.path) |subpath| {
                const sub_dir = try std.fs.path.join(gpa, &.{ dir_path, subpath });
                defer gpa.free(sub_dir);
                try collectDependencies(io, gpa, cache_root, sub_dir, deps_map);
            }
        }
    }
}

fn appendTarGzToArchive(
    io: std.Io,
    gpa: std.mem.Allocator,
    archive: *std.tar.Writer,
    archive_prefix: []const u8,
    tar_gz_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, tar_gz_path, .{});
    defer file.close(io);

    var fbuf: [8192]u8 = undefined;
    var freader = file.reader(io, &fbuf);

    var flate_buffer: [flate.max_window_len]u8 = undefined;
    var gz = flate.Decompress.init(
        &freader.interface,
        .gzip,
        &flate_buffer,
    );

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gz.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    while (try it.next()) |entry| {
        var name = entry.name;
        if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
            name = name[slash + 1 ..];
        }
        if (name.len == 0) continue;

        const full_path = try std.fs.path.join(gpa, &.{ archive_prefix, name });
        defer gpa.free(full_path);

        try archive.setRoot("");
        switch (entry.kind) {
            .file => {
                try archive.writeFileStream(full_path, entry.size, it.reader, .{ .mode = entry.mode });
            },
            .directory => {
                try archive.writeDir(full_path, .{ .mode = entry.mode });
            },
            .sym_link => {
                try archive.writeLink(full_path, entry.link_name, .{ .mode = entry.mode });
            },
        }
        it.unread_file_bytes = 0;
    }
}

/// convert a std.Build zon to a tar.gz archive
pub fn fromBuild(
    io: std.Io,
    gpa: std.mem.Allocator,
    zon_src: []const u8,
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

    // 1. Add root
    try tar_paths.append(try gpa.dupe(u8, "build/root"));
    try fs_paths.append(try gpa.dupe(u8, root));

    // 2. Add root.zon
    const raw_zon = try std.fmt.allocPrint(gpa, "raw:{s}", .{zon_src});
    try tar_paths.append(try gpa.dupe(u8, "build/root.zon"));
    try fs_paths.append(raw_zon);

    // 3. Collect dependencies from root and cache
    var deps_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        for (deps_map.keys()) |k| gpa.free(k);
        for (deps_map.values()) |v| gpa.free(v);
        deps_map.deinit(gpa);
    }
    try collectDependencies(io, gpa, cache_root, root, &deps_map);

    for (deps_map.keys(), deps_map.values()) |hash, fs_p| {
        const tar_p = try std.fmt.allocPrint(gpa, "build/p/{s}", .{hash});
        try tar_paths.append(tar_p);
        try fs_paths.append(try gpa.dupe(u8, fs_p));
    }

    return process(.{
        .io = io,
        .gpa = gpa,
        .out_path = out_path,
        .tar_paths = tar_paths.items,
        .fs_paths = fs_paths.items,
    });
}

const Options = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    out_path: []const u8,
    tar_paths: []const []const u8, // paths inside the tar archive. the fist element is expected to be "root"
    fs_paths: []const []const u8, // paths to directories on the local filesystem
};

/// convert a list of zig package directories to a tar.gz archive
pub fn process(opt: Options) !void {
    std.debug.assert(opt.fs_paths.len == opt.tar_paths.len);

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(opt.out_path)) |dir| {
        try cwd.createDirPath(opt.io, dir);
    }

    var out_file = try cwd.createFile(opt.io, opt.out_path, .{});
    defer out_file.close(opt.io);
    var out_buf: [8192]u8 = undefined;
    var output = out_file.writer(opt.io, &out_buf);

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

        if (std.mem.endsWith(u8, fs_path, ".tar.gz")) {
            try appendTarGzToArchive(opt.io, opt.gpa, &archive, archive_path, fs_path);
            continue;
        }

        try archive.setRoot(archive_path);

        var input = try cwd.openDir(opt.io, fs_path, .{
            .iterate = true,
            .access_sub_paths = true,
        });
        defer input.close(opt.io);

        const zon_file = input.openFile(opt.io, "build.zig.zon", .{}) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        var manifest: ?Manifest = null;

        if (zon_file) |zf| {
            const zon_sliceZ: [:0]u8 = blk: {
                defer zf.close(opt.io);
                zon_src.clearRetainingCapacity();
                var zfb: [8192]u8 = undefined;
                var zfr: std.Io.File.Reader = zf.reader(opt.io, &zfb);
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
        outer: while (iter.next(opt.io) catch |err| {
            std.log.err("error accessing: {s}\n{}\n", .{
                iter.inner.name_buffer.items,
                err,
            });
            return err;
        }) |entry| {
            include_entry: {
                if (manifest) |mani| {
                    if (std.mem.eql(u8, entry.path, "build.zig.zon")) break :include_entry;
                    if (mani.paths) |paths| {
                        var filter: Filter = .{
                            .include_paths = paths,
                        };

                        if (filter.includePath(entry.path)) break :include_entry;
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

            try writeTarEntry(&archive, opt.io, &arc_entry);
        }
    }
    try archive.finishPedantically();
    try compressor.finish();
    try output.interface.flush();
}

pub fn writeTarEntry(arc: *std.tar.Writer, io: std.Io, entry: *std.Io.Dir.Walker.Entry) !void {
    const file = entry.dir.openFile(
        io,
        entry.basename,
        .{},
    ) catch |e| switch (e) {
        error.IsDir => return,
        else => return e,
    };
    defer file.close(io);

    switch (entry.kind) {
        .file => {
            var buf: [64]u8 = undefined;
            const stat = try entry.dir.statFile(io, entry.basename, .{});
            var reader = file.reader(io, &buf);
            try arc.writeFileStream(
                entry.path,
                try reader.getSize(),
                &reader.interface,
                .{
                    .mode = 0,
                    .mtime = @intCast(stat.mtime.toSeconds()),
                },
            );
        },
        else => return,
    }
}

/// exact same logic zig uses for the `paths` manifest field.
/// except we use a []const []const u8 instead of a hashmap
const Filter = struct {
    include_paths: []const []const u8,
    /// sub_path is relative to the package root.
    pub fn includePath(self: Filter, sub_path: []const u8) bool {
        if (self.include_paths.len == 0) return true;
        for (self.include_paths) |ip| {
            if (std.mem.eql(u8, ip, "")) return true;
            if (std.mem.eql(u8, ip, ".")) return true;
            if (std.mem.eql(u8, ip, sub_path)) return true;
        }

        // Check if any included paths are parent directories of sub_path.
        var dirname = sub_path;
        while (std.fs.path.dirname(dirname)) |next_dirname| {
            for (self.include_paths) |ip| {
                if (std.mem.eql(u8, ip, next_dirname)) return true;
            }
            dirname = next_dirname;
        }

        return false;
    }
};

test "includePath" {
    var filter: Filter = .{
        .include_paths = &.{"src"},
    };
    try std.testing.expect(filter.includePath("src/core/unix/SDL_poll.c"));
    try std.testing.expect(!filter.includePath(".gitignore"));
}
