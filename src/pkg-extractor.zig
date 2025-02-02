const std = @import("std");
const tar = std.tar;
const gzip = std.compress.gzip;
const TempFile = @import("TempFile.zig");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const zig = env_map.get("ZIG") orelse "zig";

    var tempD = try TempFile.tmpDir(.{
        .prefix = "extractor",
    });
    defer tempD.deinit();

    var temp = std.StringHashMap(TempTar).init(gpa);
    // TODO: get rid of pointers in TempBar
    try temp.ensureTotalCapacity(512);
    defer {
        var vit = temp.valueIterator();
        while (vit.next()) |a| {
            if (a.hash) |h| gpa.free(h);
            a.tar.finish() catch @panic("tar could not be finished");
            a.tf.deinit();
        }
        temp.deinit();
    }

    if (args.len != 2) {
        std.log.err("usage: extractor <deppkg.tar.gz", .{});
        return error.ArgumentsMismatch;
    }
    const filepath = args[1];
    const fd = try std.fs.cwd().openFile(filepath, .{});
    var gz = gzip.decompressor(fd.reader());

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var t = tar.iterator(gz.reader(), .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    while (try t.next()) |entry| {
        const sep_idx = std.mem.indexOfAnyPos(
            u8,
            entry.name,
            "build/root".len,
            std.fs.path.sep_str_posix,
        ) orelse entry.name.len;
        const prefix = entry.name[0..sep_idx];

        const gop = try temp.getOrPut(prefix);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .hash = if (std.mem.eql(
                    u8,
                    "build/p/",
                    prefix[0.."build/p/".len],
                )) try gpa.dupe(u8, prefix["build/p/".len..]) else null,
                .tf = try TempFile.tmpFile(.{
                    .tmp_dir = &tempD,
                    .suffix = ".tar",
                }),
                .name_offset = sep_idx,
                .tar = undefined,
            };
            gop.value_ptr.*.tar = tar.writer(gop.value_ptr.*.tf.f.writer());
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
                entry.reader(),
                .{},
            ),
            .directory => try gop.value_ptr.tar.writeDir(
                short_name,
                .{},
            ),
            .sym_link => try gop.value_ptr.tar.writeLink(
                short_name,
                entry.link_name,
                .{},
            ),
        }
    }
    {
        var fetch_err: ?anyerror = null;
        var err_buf: std.ArrayList(u8) = .init(gpa);
        defer err_buf.deinit();

        var vit = temp.valueIterator();
        while (vit.next()) |a| {
            a.tar.finish() catch @panic("tar could not be finished");
            std.log.info("zig fetch {s}", .{ a.tf.abs_path });
            const res = try std.process.Child.run(.{
                .allocator = gpa,
                .argv = &.{
                    zig, "fetch", a.tf.abs_path,
                },
            });
            defer {
                gpa.free(res.stderr);
                gpa.free(res.stdout);
            }
            if (res.term != .Exited or res.term.Exited != 0) {
                try err_buf.writer().print("ZigFetch:\n{s}\n{s}\n", .{res.stdout, res.stderr});
                fetch_err = error.ZigFetch;
            }
            if (a.hash) |hash| {
                if (!std.mem.startsWith(u8, res.stdout, hash)) {
                    try err_buf.writer().print("hash mismatch: {s}\n{s}\n{s}\n", .{ a.tf.abs_path, hash, res.stdout });
                    fetch_err = error.HashMismatch;
                }
                std.log.info("extracted:\n{s}\n{s}", .{ hash, res.stdout });
            }
        }
        if (err_buf.items.len > 0) {
            std.log.err("{s}", .{err_buf.items});
        }
        if (fetch_err) |fe| return fe;
    }
}

const TempTar = struct {
    tf: TempFile.TmpFile,
    name_offset: usize,
    hash: ?[]const u8,
    tar: @TypeOf(tar.writer(std.io.getStdOut().writer())),
};
