const std = @import("std");
const tar = std.tar;
const gzip = std.compress.gzip;

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();


    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 3) {
        std.log.err("usage: targz <output file> [<hash>:<dir>]", .{});
        return error.NotEnoughArguments;
    }
    try process(args[1],args[2..], gpa);
}

pub fn process(out_path: []const u8, args:[]const []const u8, gpa: std.mem.Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_allocator.allocator();
    defer arena_allocator.deinit();

    const cwd = std.fs.cwd();
    var output = try cwd.createFile(out_path, .{});
    defer output.close();

    var compress = try gzip.compressor(output.writer(), .{});
    defer compress.finish() catch @panic("compress finish error");

    var archive = tar.writer(compress.writer().any());
    defer archive.finish() catch @panic("archive finish error");

    var archiveRoot: []const u8 = undefined;

    for (args) |arg| {

        const split = std.mem.indexOf(u8, arg, ":") orelse {
            std.log.err("invalid arg: {s}", .{arg});
            return error.InvalidArg;
        };
        const hash = arg[0..split];
        const path = arg[split+1..];

        if (std.mem.eql(u8, hash, "root")) {
            archiveRoot = try arena.dupe(u8, "root");
        } else {
            archiveRoot = try std.fmt.allocPrint(arena, "p/{s}", .{hash});
        }
        try archive.setRoot("");
        try archive.setRoot(archiveRoot);

        var input = try cwd.openDir(path, .{
            .iterate = true,
            .access_sub_paths = true,
        });
        defer input.close();

        var iter = try input.walk(gpa);
        defer iter.deinit();
        outer: while (try iter.next()) |entry| {
            inline for (&.{
                "zig-cache",
                ".zig-cache",
                "zig-out",
                ".git",
                ".svn",
                ".venv",
                "_venv",
                ".spin",
            }) |ignore| {
                if (std.mem.indexOf(u8, entry.path, ignore)) |_| continue :outer;
            }
            try archive.writeEntry(entry);
        }
    }
}
