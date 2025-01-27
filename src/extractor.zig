const std = @import("std");
const tar = std.tar;
const gzip = std.compress.gzip;

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_allocator.allocator();
    defer arena_allocator.deinit();

    _ = arena;
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
        std.debug.print("e: {s}\n", .{entry.name});
    }
}
