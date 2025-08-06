const std = @import("std");
const Serialize = @import("BuildSerialize.zig");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub fn main() !void {
    return try @import("runner-zig.zig").runner.mainBuild(.{
        .executeBuildFn = build_main,
        .ctx = null,
    });
}

pub fn build_main(b: *std.Build, targets: []const []const u8, ctx: ?*anyopaque) !void {
    _ = ctx;
    _ = targets;
    var stdout_buf: [8192]u8 = undefined;
    const stdout = std.fs.File.stdout();
    var stdout_w = stdout.writer(&stdout_buf);

    const bs = try Serialize.serializeBuild(b, .{
        .whitespace = false,
        .emit_default_optional_fields = false,
    });
    try stdout_w.interface.writeAll(bs);
    try stdout_w.interface.flush();
}
