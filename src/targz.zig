const std = @import("std");
const tar = std.tar;
const gzip = std.compress.gzip;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const cwd = std.fs.cwd();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    std.debug.assert(args.len == 3);
    var output = try cwd.createFile(args[2], .{});
    defer output.close();

    var compress = try gzip.compressor(output.writer(), .{ .level = .best });
    defer compress.finish() catch @panic("compress finish error");

    var archive = tar.writer(compress.writer().any());
    defer archive.finish() catch @panic("archive finish error");
    const archiveRoot = std.fs.path.basename(args[1]);
    try archive.setRoot(archiveRoot);

    // std.debug.print("opening: {s}\n", .{args[1]});
    var input = try cwd.openDir(args[1], .{
        .iterate = true,
    });
    defer input.close();

    var iter = try input.walk(alloc);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        // std.debug.print("entry: {s}\n", .{entry.path});
        switch (entry.kind) {
            .directory => {},
            else => {
                try archive.writeEntry(entry);
            },
        }
    }
}
