const std = @import("std");
const tar = std.tar;
const gzip = std.compress.gzip;
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

    process(.{
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
            a.tar.finish() catch @panic("tar could not be finished");
            a.tf.deinit();
        }
        temp.deinit();
    }

    const fd = try std.fs.cwd().openFile(opt.filepath, .{});
    var gz = gzip.decompressor(fd.reader());

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var t = tar.iterator(gz.reader(), .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    while (try t.next()) |entry| {
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
            gop.value_ptr.* = .{
                .hash = try opt.gpa.dupe(u8, prefix[tar_prefix.len..]),
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
            a.tar.finish() catch @panic("tar could not be finished");
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
    name_offset: usize,
    hash: []const u8,
    tar: @TypeOf(tar.writer(std.io.getStdOut().writer())),
};
