const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Manifest = @import("Manifest.zig");
const tar = std.tar;
const zlib = @cImport({
    @cInclude("zlib.h");
});

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
            var zon_file = std.io.Writer.Allocating.init(gpa);
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

    var compressor: ZLibDeflater = try .init(.{
        .gpa = opt.gpa,
        .writer = &output.interface,
    });
    defer compressor.deinit();

    var archive = std.tar.Writer{
        .underlying_writer = &compressor.writer,
    };

    var zon_src: std.io.Writer.Allocating = .init(opt.gpa);
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

            manifest = Manifest.fromSlice(
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
}

fn zLibError(ret: c_int) !void {
    return switch (ret) {
        zlib.Z_OK => {},
        zlib.Z_STREAM_ERROR => error.ZLibStream,
        zlib.Z_DATA_ERROR => error.ZLibData,
        zlib.Z_NEED_DICT => error.ZLibNeedDict,
        zlib.Z_MEM_ERROR => error.ZLibMem,
        zlib.Z_BUF_ERROR => error.ZLibBuf,
        zlib.Z_VERSION_ERROR => error.ZLibVersion,
        else => error.ZLibUnknown,
    };
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

const ZLibDeflater = struct {
    const Self = @This();
    const CHUNKSIZE = 16 * 1024;
    zstream: zlib.z_stream,
    outbuf: []u8,
    underlying_writer: *std.io.Writer,
    writer: std.io.Writer,
    gpa: std.mem.Allocator,

    pub const Options = struct {
        gpa: std.mem.Allocator,
        level: u4 = 6,
        writer: *std.io.Writer,
    };

    pub fn init(opt: Self.Options) !Self {
        @breakpoint();
        var self: @This() = .{
            .zstream = .{
                // .zalloc = null,
                // .zfree = null,
                // .@"opaque" = null,
                .next_in = zlib.Z_NULL,
                .avail_in = 0,
                .next_out = zlib.Z_NULL,
                .avail_out = 0,
            },
            .outbuf = try opt.gpa.alloc(u8, CHUNKSIZE),
            .writer = .{
                .buffer = try opt.gpa.alloc(u8, CHUNKSIZE),
                .vtable = &.{
                    .drain = drain,
                },
            },
            .underlying_writer = opt.writer,
            .gpa = opt.gpa,
        };
        try zLibError(zlib.deflateInit2(
            &self.zstream,
            opt.level,
            zlib.Z_DEFLATED,
            zlib.MAX_WBITS,
            zlib.MAX_MEM_LEVEL,
            zlib.Z_DEFAULT_STRATEGY,
        ));
        return self;
    }

    pub fn deinit(self: Self) void {
        self.gpa.free(self.writer.buffer);
        self.gpa.free(self.outbuf);
    }

    fn drain(wr: *Io.Writer, blobs: []const []const u8, splat: usize) error{WriteFailed}!usize {
        const self: *Self = @fieldParentPtr("writer", wr);
        var count: usize = 0;

        try self.zdrain(wr.buffer[0..wr.end]);
        count += wr.end;
        wr.end = 0;
        for (blobs, 1..) |blob, i| {
            var splat_i: usize = 0;
            while ((i != blobs.len and splat_i < 1) or (i == blobs.len and splat_i < splat)) : (splat_i += 1) {
                try self.zdrain(blob);
                count += blob.len;
            }
        }
        return count;
    }

    fn zdrain(self: *Self, blob: []const u8) !void {
        self.zstream.next_in = @constCast(blob.ptr);
        self.zstream.avail_in = @intCast(blob.len);
        while (self.zstream.avail_in > 0) {
            self.zstream.next_out = self.outbuf.ptr;
            self.zstream.avail_out = @intCast(self.outbuf.len);

            std.log.err("zstream pre deflate: {d}\n{any}", .{
                self.writer.end,
                self.zstream,
            });

            zLibError(zlib.deflate(&self.zstream, zlib.Z_NO_FLUSH)) catch |err| switch (err) {
                error.ZLibBuf => {
                    std.log.err("ZLibBuf!!!\nzstream:\n{any}", .{self.zstream});
                    std.log.err("zlib error: {}", .{err});
                    return;
                },
                else => {
                    std.log.err("zstream:\n{any}", .{self.zstream});
                    std.log.err("zlib error: {}\n", .{err});
                    return error.WriteFailed;
                },
            };
            const have = self.outbuf.len - self.zstream.avail_out;
            std.log.err("have: {d}", .{have});
            try self.underlying_writer.writeAll(self.zstream.next_out[0..have]);
        }
    }

    // if (archive_writer.end == 0) continue;
    // zs.avail_out = z_out.len;
    // zs.next_out = &z_out;
    // zs.avail_in = @intCast(archive_writer.end);
    // zs.next_in = &z_in;
    // zLibError(zlib.deflate(&zs, zlib.Z_NO_FLUSH)) catch |err| switch (err) {
    //     error.ZLibBuf => {},
    //     else => return err,
    // };
    // _ = archive_writer.consumeAll();
    // const have = z_chunk - zs.avail_out;
    // _ = try output.interface.write(zs.next_out[0..have]);

    // try zLibError(zlib.deflate(&zs, zlib.Z_FINISH));
    // try zLibError(zlib.deflateEnd(&zs));
    // const have = z_chunk - zs.avail_out;
    // _ = try output.interface.write(zs.next_out[0..have]);
};

pub fn streamThread(reader: *Io.Reader, writer: *Io.Writer) !void {
    _ = reader.streamRemaining(writer) catch |e| {
        switch (e) {
            error.ReadFailed => {},
            else => return e,
        }
    };
}
