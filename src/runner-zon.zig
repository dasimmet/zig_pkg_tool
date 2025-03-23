const std = @import("std");
const Serialize = @import("BuildSerialize.zig");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub fn main() !void {
    return try @import("runner-zig.zig").mainBuild(.{
        .executeBuildFn = build_main,
        .ctx = null,
    });
}

pub fn build_main(b: *std.Build, targets: []const []const u8, ctx: ?*anyopaque) !void {
    _ = ctx;
    _ = targets;
    const stdout = std.io.getStdOut().writer();

    const bs = try Serialize.serializeBuild(b, .{
        .whitespace = false,
        .emit_default_optional_fields = false,
    });
    try stdout.writeAll(bs);
}
