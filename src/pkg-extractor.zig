const std = @import("std");
const tar = std.tar;
const TempFile = @import("TempFile.zig");
const flate = @import("flate/flate.zig");
const tar_package_prefix = "build/p/";
const tar_root_prefix = "build/root/";

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const zig = env_map.get("ZIG") orelse "zig";

    if (args.len != 2) {
        std.log.err("usage: extractor <deppkg.tar.gz", .{});
        return error.ArgumentsMismatch;
    }

    try process(.{
        .gpa = gpa,
        .zig_exe = zig,
        .filepath = args[1],
    });
}

pub const Options = struct {
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    filepath: []const u8,
    root_out_dir: ?[]const u8 = null,
};

pub fn process(opt: Options) !void {
    var tempD = try TempFile.tmpDir(.{
        .prefix = "extractor",
    });
    defer tempD.deinit();

    var temp = std.StringHashMap(TempTar).init(opt.gpa);
    // TODO: get rid of invalid pointers in TempTar when it reallocates
    // for now we avoid reallocations by oversizing
    try temp.ensureTotalCapacity(512);
    defer {
        var vit = temp.valueIterator();
        while (vit.next()) |a| {
            opt.gpa.free(a.hash);
        }
        temp.deinit();
    }

    const fd = try std.fs.cwd().openFile(opt.filepath, .{});
    var fbuf: [8192]u8 = undefined;
    var freader = fd.reader(&fbuf);

    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gz = flate.Decompress.init(
        &freader.interface,
        .gzip,
        &flate_buffer,
    );

    var tardiag: std.tar.Diagnostics = .{
        .allocator = opt.gpa,
    };
    defer tardiag.deinit();

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    var it: tar.Iterator = .init(&gz.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
        .diagnostics = &tardiag,
    });

    const root_out_dir = if (opt.root_out_dir) |rod|
        try std.fs.cwd().makeOpenPath(rod, .{})
    else
        null;

    var count_entries: usize = 0;
    while (it.next() catch |err| {
        std.log.err("count_entries: {} err: {}", .{ count_entries, err });
        for (tardiag.errors.items) |errit| {
            std.log.err("err: {any}", .{errit});
        }
        return err;
    }) |entry| {
        count_entries += 1;
        if (root_out_dir) |rod| {
            if (std.mem.startsWith(u8, entry.name, "build/root/")) {
                const entry_short_name = entry.name["build/root/".len..];
                switch (entry.kind) {
                    .directory => try rod.makePath(entry_short_name),
                    .file => {
                        if (std.fs.path.dirname(entry_short_name)) |out_dir_name| {
                            try rod.makePath(out_dir_name);
                        }
                        const out_fd = try rod.createFile(entry_short_name, .{});
                        defer out_fd.close();
                        var out_writer = out_fd.writer(&.{});
                        try it.reader.streamExact64(&out_writer.interface, entry.size);
                        it.unread_file_bytes = 0;
                    },
                    .sym_link => {
                        if (std.fs.path.dirname(entry_short_name)) |out_dir_name| {
                            try rod.makePath(out_dir_name);
                        }
                        try rod.symLink(entry_short_name, entry.link_name, .{});
                    },
                }
                it.unread_file_bytes = 0;
                continue;
            }
        }
        if (!std.mem.startsWith(u8, entry.name, tar_package_prefix)) continue;
        const sep_idx = std.mem.indexOfAnyPos(
            u8,
            entry.name,
            tar_package_prefix.len,
            std.fs.path.sep_str_posix,
        ) orelse entry.name.len;
        const prefix = entry.name[0..sep_idx];

        const gop = try temp.getOrPut(prefix);
        if (!gop.found_existing) {
            const hash = try opt.gpa.dupe(u8, prefix[tar_package_prefix.len..]);
            gop.value_ptr.* = .{
                .hash = hash,
                .tf = try TempFile.tmpFile(.{
                    .tmp_dir = &tempD,
                    .prefix = hash,
                    .suffix = ".tar",
                }),
                .filew = undefined,
                .name_offset = sep_idx,
                .tarbuf = undefined,
                .tar = undefined,
            };
            gop.value_ptr.*.filew = gop.value_ptr.*.tf.f.writer(&gop.value_ptr.*.tarbuf);
            gop.value_ptr.*.tar = tar.Writer{
                .underlying_writer = &gop.value_ptr.*.filew.interface,
            };
            std.debug.print("e: {s}\n{s}\n", .{
                entry.name,
                gop.value_ptr.*.tf.abs_path,
            });
        }
        const short_name = if (gop.value_ptr.name_offset < entry.name.len and entry.name[gop.value_ptr.name_offset] == std.fs.path.sep_posix)
            entry.name[gop.value_ptr.name_offset + 1 ..]
        else
            entry.name[gop.value_ptr.name_offset..];
        switch (entry.kind) {
            .file => try gop.value_ptr.tar.writeFileStream(
                short_name,
                entry.size,
                it.reader,
                .{
                    .mode = entry.mode,
                },
            ),
            .directory => try gop.value_ptr.tar.writeDir(
                short_name,
                .{
                    .mode = entry.mode,
                },
            ),
            .sym_link => try gop.value_ptr.tar.writeLink(
                short_name,
                entry.link_name,
                .{
                    .mode = entry.mode,
                },
            ),
        }
        it.unread_file_bytes = 0;
    }

    if (opt.root_out_dir) |rod| {
        std.log.info("extracted: {s}", .{rod});
    }

    {
        var fetch_err: ?anyerror = null;
        var err_buf: std.Io.Writer.Allocating = .init(opt.gpa);
        defer err_buf.deinit();
        const err_writer = &err_buf.writer;

        var vit = temp.valueIterator();
        while (vit.next()) |a| {
            a.tar.underlying_writer.flush() catch @panic("tar could not be finished");
            std.log.info("zig fetch {s}", .{a.tf.abs_path});
            const res = try std.process.Child.run(.{
                .allocator = opt.gpa,
                .argv = &.{
                    opt.zig_exe, "fetch", a.tf.abs_path,
                },
            });
            defer {
                opt.gpa.free(res.stderr);
                opt.gpa.free(res.stdout);
            }
            if (res.term != .Exited or res.term.Exited != 0) {
                try err_writer.print("zig fetch {s}\n{s}\n{s}\n", .{
                    a.tf.abs_path,
                    res.stdout,
                    res.stderr,
                });
                fetch_err = error.ZigFetch;
            }
            if (!std.mem.startsWith(u8, res.stdout, a.hash)) {
                try err_writer.print("hash mismatch: {s}\nexpected:\"{s}\"\n  actual:\"{s}\"\n", .{
                    a.tf.abs_path,
                    a.hash,
                    res.stdout[0..@min(res.stdout.len, a.hash.len)],
                });
                fetch_err = error.HashMismatch;
            }
            std.log.info("extracted:\n{s}\n{s}", .{ a.hash, res.stdout });
        }
        if (err_buf.written().len > 0) {
            std.log.err("{s}", .{err_buf.written()});
        }
        if (fetch_err) |fe| return fe;
    }
}

const TempTar = struct {
    tf: TempFile.TmpFile,
    filew: std.fs.File.Writer,
    name_offset: usize,
    hash: []const u8,
    tarbuf: [64]u8,
    tar: tar.Writer,
};
