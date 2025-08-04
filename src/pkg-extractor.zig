const std = @import("std");
const tar = std.tar;
const TempFile = @import("TempFile.zig");
const tar_prefix = "build/p/";
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

    const gz_buf = try opt.gpa.alloc(u8, std.compress.flate.max_window_len);
    defer opt.gpa.free(gz_buf);
    var gz = std.compress.flate.Decompress.init(
        &freader.interface,
        .gzip,
        gz_buf,
    );

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it: tar.Iterator = .init(&gz.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, tar_prefix)) continue;
        const sep_idx = std.mem.indexOfAnyPos(
            u8,
            entry.name,
            tar_prefix.len,
            std.fs.path.sep_str_posix,
        ) orelse entry.name.len;
        const prefix = entry.name[0..sep_idx];

        const gop = try temp.getOrPut(prefix);
        if (!gop.found_existing) {
            const hash = try opt.gpa.dupe(u8, prefix[tar_prefix.len..]);
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
    }
    {
        var fetch_err: ?anyerror = null;
        var err_buf: std.ArrayList(u8) = .init(opt.gpa);
        defer err_buf.deinit();

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
                try err_buf.writer().print("zig fetch {s}\n{s}\n{s}\n", .{
                    a.tf.abs_path,
                    res.stdout,
                    res.stderr,
                });
                fetch_err = error.ZigFetch;
            }
            if (!std.mem.startsWith(u8, res.stdout, a.hash)) {
                try err_buf.writer().print("hash mismatch: {s}\nexpected:\"{s}\"\n  actual:\"{s}\"\n", .{
                    a.tf.abs_path,
                    a.hash,
                    res.stdout[0..@min(res.stdout.len, a.hash.len)],
                });
                fetch_err = error.HashMismatch;
            }
            std.log.info("extracted:\n{s}\n{s}", .{ a.hash, res.stdout });
        }
        if (err_buf.items.len > 0) {
            std.log.err("{s}", .{err_buf.items});
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
