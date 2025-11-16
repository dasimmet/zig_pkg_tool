const std = @import("std");

pub fn main() !void {
    var gpa_impl = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    const file = args[1];

    const fd = try std.fs.cwd().openFile(file, .{});
    defer fd.close();
    var fr = fd.reader(&.{});

    var flate_buffer: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var gz = std.compress.flate.Decompress.init(
        &fr.interface,
        .gzip,
        &flate_buffer,
    );

    const tar_reader = &gz.reader;

    var tardiag: std.tar.Diagnostics = .{
        .allocator = gpa,
    };
    defer tardiag.deinit();

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    var it: std.tar.Iterator = .init(tar_reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
        .diagnostics = &tardiag,
    });
    while (it.next() catch |err| {
        std.log.err("{}", .{err});
        return err;
    }) |entry| {
        std.log.info("entry: {f}", .{std.json.fmt(entry, .{})});
        try it.reader.discardAll64(entry.size);
        it.unread_file_bytes = 0;
    }
}
