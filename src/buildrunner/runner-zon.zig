const std = @import("std");
const Serialize = @import("BuildSerialize.zig");
const runner_zig = @import("runner-zig.zig");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const main = if (runner_zig.later_than_zig_15)
    main_16
else
    main_legacy;

fn main_16(init: std.process.Init.Minimal) !void {
    return try runner_zig.runner.mainBuild(init, .{
        .executeBuildFn = build_main,
        .ctx = null,
    });
}

fn main_legacy() !void {
    return try runner_zig.runner.mainBuild(.{
        .executeBuildFn = build_main,
        .ctx = null,
    });
}

pub fn build_main(b: *std.Build, targets: []const []const u8, ctx: ?*anyopaque) !void {
    _ = ctx;
    _ = targets;
    var stdout_buf: [8192]u8 = undefined;
    const bs = try Serialize.serializeBuild(b, .{
        .whitespace = false,
        .emit_default_optional_fields = false,
    });

    if (runner_zig.later_than_zig_15) {
        const stdout = std.Io.File.stdout();
        var stdout_w = stdout.writer(b.graph.io, &stdout_buf);
        try stdout_w.interface.writeAll(bs);
        try stdout_w.interface.flush();
    } else {
        const stdout = std.fs.File.stdout();
        var stdout_w = stdout.writer(&stdout_buf);
        try stdout_w.interface.writeAll(bs);
        try stdout_w.interface.flush();
    }
}
