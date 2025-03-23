const std = @import("std");
const builtin = @import("builtin");
const Manifest = @import("Manifest.zig");
const tar = std.tar;
const gzip = std.compress.gzip;

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

    var fs_paths = std.ArrayList([]const u8).init(gpa);
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
    var tar_paths = std.ArrayList([]const u8).init(gpa);
    defer {
        for (tar_paths.items) |it| gpa.free(it);
        tar_paths.deinit();
    }

    var fs_paths = std.ArrayList([]const u8).init(gpa);
    defer {
        for (fs_paths.items) |it| gpa.free(it);
        fs_paths.deinit();
    }

    for (build.dependencies, 0..) |dep, i| {
        if (i == 0) {
            std.debug.assert(dep.location == .root);
            try tar_paths.append(try gpa.dupe(u8, "build/root"));
            try fs_paths.append(try gpa.dupe(u8, root));
            var zon_file = std.ArrayList(u8).init(gpa);
            try zon_file.appendSlice("raw:");
            try std.zon.stringify.serializeArbitraryDepth(build, .{
                .whitespace = true,
                .emit_default_optional_fields = false,
            }, zon_file.writer());
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
    // std.log.info("writing deppkg tar.gz: {s}", .{opt.out_path});
    var output = try cwd.createFile(opt.out_path, .{});
    defer output.close();

    var compress = try std.compress.gzip.compressor(output.writer(), .{});
    defer compress.finish() catch @panic("compress finish error");

    var archive = std.tar.writer(compress.writer().any());
    defer archive.finish() catch @panic("archive finish error");

    var zon_src: std.ArrayList(u8) = .init(opt.gpa);
    defer zon_src.deinit();

    for (opt.fs_paths, 0..) |fs_path, i| {
        const archive_path = opt.tar_paths[i];

        try archive.setRoot("");

        if (std.mem.startsWith(u8, fs_path, "raw:")) {
            try archive.writeFileBytes(archive_path, fs_path["raw:".len..], .{});
            continue;
        }

        // std.log.info("tar_path: {s}:{s}", .{ archive_path, fs_path });
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
            defer zf.close();
            zon_src.clearRetainingCapacity();
            try zf.reader().readAllArrayList(&zon_src, std.math.maxInt(u32));
            try zon_src.append(0);

            var zonStatus: Manifest.zonparse.Status = .{};
            defer zonStatus.deinit(opt.gpa);

            manifest = Manifest.fromSlice(
                opt.gpa,
                @ptrCast(zon_src.items[0 .. zon_src.items.len - 1]),
                &zonStatus,
            ) catch |e| {
                Manifest.log(std.log.err, e, fs_path, zonStatus);
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
        outer: while (try iter.next()) |entry| {
            include_entry: {
                if (manifest) |mani| {
                    // if (mani.dependencies) |deps| {
                    //     var dep_iterator = deps.impl.iterator();
                    //     while (dep_iterator.next()) |dep| {
                    //         std.log.info("dep: {s} -> {s}:\n{}", .{
                    //             mani.name,
                    //             dep.key_ptr.*,
                    //             zonfmt(dep.value_ptr.*, .{
                    //                 .whitespace = true,
                    //             }),
                    //         });
                    //     }
                    // }
                    if (std.mem.eql(u8, entry.path, "build.zig.zon")) break :include_entry;
                    for (mani.paths) |p| {
                        if (std.mem.startsWith(u8, entry.path, p)) {
                            break :include_entry;
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
            defer {
                if (@import("builtin").os.tag == .windows) {
                    defer opt.gpa.free(arc_entry.path);
                }
            }

            archive.writeEntry(arc_entry) catch |e| {
                switch (e) {
                    error.IsDir => continue,
                    else => {
                        std.log.err("file: {s}\n{s}\n{s}", .{ fs_path, entry.path, arc_entry.path });
                        return e;
                    },
                }
            };
        }
    }
}

pub fn zonfmt(value: anytype, options: std.zon.stringify.SerializeOptions) Formatter(@TypeOf(value)) {
    return Formatter(@TypeOf(value)){ .value = value, .options = options };
}

/// Formats the given value using stringify.
pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: std.zon.stringify.SerializeOptions,

        pub fn format(
            self: @This(),
            comptime fmt_spec: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt_spec;
            _ = options;
            try std.zon.stringify.serializeArbitraryDepth(self.value, self.options, writer);
        }
    };
}
