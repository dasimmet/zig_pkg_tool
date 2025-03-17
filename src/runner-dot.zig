const std = @import("std");
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
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("digraph {\n");
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};

    var dotfile: DotFileWriter = .init(gpa_alloc.allocator());
    defer dotfile.deinit();

    if (targets.len == 0) {
        try dotfile.writeSteps(b, &b.default_step.*, stdout);
    } else {
        for (targets) |target| {
            if (b.top_level_steps.get(target)) |step| {
                try dotfile.writeSteps(b, &step.step, stdout);
            }
        }
    }
    try stdout.writeAll("}\n");
}

pub const DotFileWriter = struct {
    id: u32,
    depth: u32,
    gpa: std.mem.Allocator,
    steps: std.AutoHashMapUnmanaged(usize, struct {
        id: u32 = 0,
        visited: bool = false,
    }),

    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .id = 0,
            .depth = 0,
            .gpa = gpa,
            .steps = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.steps.deinit(self.gpa);
    }

    pub fn writeSteps(self: *@This(), b: *std.Build, step: *std.Build.Step, writer: anytype) !void {
        const step_entry = try self.steps.getOrPut(self.gpa, @intFromPtr(step));
        if (step_entry.found_existing) {
            if (step_entry.value_ptr.visited) return;
            step_entry.value_ptr.visited = true;
        } else {
            step_entry.value_ptr.* = .{
                .id = self.id,
                .visited = true,
            };
            self.id += 1;
        }

        try self.printStep(step, step_entry.value_ptr.*.id, writer);

        self.depth += 1;
        for (step.dependencies.items) |dep_step| {
            try self.writeSteps(b, dep_step, writer);
        }
        self.depth -= 1;
    }

    fn printStep(self: *@This(), step: *std.Build.Step, i: u32, writer: anytype) !void {
        try writer.print("\"N{d}\" [label=\"{s}\"]\n", .{ i, step.name });
        for (step.dependencies.items) |dep_step| {
            const dot_entry = try self.steps.getOrPut(self.gpa, @intFromPtr(dep_step));
            if (!dot_entry.found_existing) {
                dot_entry.value_ptr.* = .{
                    .id = self.id,
                    .visited = false,
                };
                self.id += 1;
            }
            try writer.print("\"N{d}\" -> \"N{d}\"\n", .{
                i,
                dot_entry.value_ptr.id,
            });
        }
    }
};

pub fn printStructStdout(item: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try std.zon.stringify.serializeMaxDepth(item, .{
        .whitespace = true,
    }, stdout, 3);
    try stdout.writeAll("\n");
}
