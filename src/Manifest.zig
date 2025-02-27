const std = @import("std");
const Manifest = @This();
const ZonDiag = std.zon.parse.Status;
pub const basename = "build.zig.zon";

name: []const u8,
paths: []const []const u8,
version: []const u8,
dependencies: ?struct { // needs https://github.com/ziglang/zig/pull/22973
    lazy: ?bool = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
} = null,

pub fn fromSlice(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    zonStatus: ?*ZonDiag,
) !Manifest {
    return std.zon.parse.fromSlice(
        Manifest,
        allocator,
        source,
        zonStatus,
        .{
            .ignore_unknown_fields = true,
        },
    );
}

pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
    std.zon.parse.free(allocator, self);
}

const LogFunction = @TypeOf(std.log.err);

pub fn log(logfn: LogFunction, err: anyerror, manifest_path: []const u8, diag: ZonDiag) void {
    const fmt_str = "Manifest: {s} {s}" ++ std.fs.path.sep_str ++ basename ++ ":{}";
    logfn(fmt_str, .{ @errorName(err), manifest_path, diag });
}
