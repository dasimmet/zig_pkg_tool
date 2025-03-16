const std = @import("std");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub fn main() !void {
    return try @import("runner-zig.zig").mainBuild(.{
        .executeBuildFn = build_main,
        .ctx = undefined,
    });
}

pub fn build_main(b: *std.Build, targets: []const []const u8, ctx: ?*anyopaque) !void {
    _ = ctx;
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("digraph {\n");
    if (targets.len == 0) {
        try iterate_steps(b, &b.default_step.*, 0, true, &printStep);
    } else {
        for (targets) |target| {
            if (b.top_level_steps.get(target)) |step| {
                try iterate_steps(b, &step.step, 0, true, &printStep);
            }
        }
    }
    try stdout.writeAll("}\n");
}

pub const DepFn = fn (*std.Build, *std.Build.Step, usize, usize) anyerror!void;

var iterator: usize = 0;
pub fn iterate_steps(b: *std.Build, step: *std.Build.Step, depth: usize, once: bool, depfn: *const DepFn) !void {
    if (once) {
        if (step.state == .success) return;
        step.state = .success;
    }

    try depfn(b, step, depth, iterator);

    iterator += 1;
    for (step.dependencies.items) |dep_step| {
        try iterate_steps(b, dep_step, depth + 1, once, depfn);
    }
}

pub fn printStep(b: *std.Build, step: *std.Build.Step, depth: usize, i: usize) !void {
    _ = b;
    _ = depth;
    _ = i;
    const stdout = std.io.getStdOut().writer();
    for (step.dependencies.items) |dep_step| {
        try stdout.print("\"{x} {s}\" -> \"{x} {s}\"\n", .{
            @intFromPtr(step),
            step.name,
            @intFromPtr(dep_step),
            dep_step.name,
        });
    }
    // return printStructStdout(.{
    //     .i = i,
    //     .depth = depth,
    //     .name = step.name,
    //     .build_root = step.owner.build_root.path.?,
    // });
}

pub fn printStructStdout(item: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try std.zon.stringify.serializeMaxDepth(item, .{
        .whitespace = true,
    }, stdout, 3);
    try stdout.writeAll("\n");
}
