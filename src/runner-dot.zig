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
        try iterate_steps(b, &b.default_step.*, 0, &printStep);
    } else {
        for (targets) |target| {
            if (b.top_level_steps.get(target)) |step| {
                try iterate_steps(b, &step.step, 0, &printStep);
            }
        }
    }
    try stdout.writeAll("}\n");
}

pub const DepFn = fn (*std.Build, *std.Build.Step, usize, u32) anyerror!void;

var iterator: u32 = 0;
var dotMap: std.AutoHashMapUnmanaged(usize, struct {
    id: u32,
    visited: bool,
}) = .empty;
pub fn iterate_steps(b: *std.Build, step: *std.Build.Step, depth: usize, depfn: *const DepFn) !void {
    const dot_entry = try dotMap.getOrPut(b.allocator, @intFromPtr(step));
    if (dot_entry.found_existing) {
        if (dot_entry.value_ptr.visited) return;
        dot_entry.value_ptr.visited = true;
    } else {
        dot_entry.value_ptr.* = .{
            .id = iterator,
            .visited = true,
        };
        iterator += 1;
    }

    try depfn(b, step, depth, dot_entry.value_ptr.*.id);

    for (step.dependencies.items) |dep_step| {
        try iterate_steps(b, dep_step, depth + 1, depfn);
    }
}

pub fn printStep(b: *std.Build, step: *std.Build.Step, depth: usize, i: u32) !void {
    _ = depth;
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\"N{d}\" [label=\"{s}\"]\n", .{ i, step.name });
    for (step.dependencies.items) |dep_step| {
        const dot_entry = try dotMap.getOrPut(b.allocator, @intFromPtr(dep_step));
        if (!dot_entry.found_existing) {
            dot_entry.value_ptr.* = .{
                .id = iterator,
                .visited = false,
            };
            iterator += 1;
        }
        try stdout.print("\"N{d}\" -> \"N{d}\"\n", .{
            i,
            dot_entry.value_ptr.id,
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
