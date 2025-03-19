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
    try stdout.writeAll(DotFileWriter.header);
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();

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
    try dotfile.writeClusters(b, stdout);
    try stdout.writeAll(DotFileWriter.footer);
}

pub const DotFileWriter = struct {
    pub const header = "digraph {\n";
    pub const node = "\"N{d}\" [label=\"{s}\", style=\"filled\", fillcolor=\"{s}\", group=\"G{d}\", tooltip=\"{s}\"]\n";
    pub const cluster_header = "subgraph cluster_{d} {{\n  cluster = true\n  label = \"{s}\"\n";
    pub const cluster = "\"N{d}\" -> \"N{d}\"\n";
    pub const footer = "}\n";
    gpa: std.mem.Allocator,
    step_id: u32,
    depth: u32,
    steps: std.AutoArrayHashMapUnmanaged(usize, struct {
        id: u32 = 0,
        visited: bool = false,
        pkg_id: u32 = 0,
    }),
    pkg_id: u32,
    pkgs: std.AutoArrayHashMapUnmanaged(usize, u32),

    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .depth = 0,
            .gpa = gpa,
            .step_id = 0,
            .steps = .empty,
            .pkg_id = 0,
            .pkgs = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.steps.deinit(self.gpa);
        self.pkgs.deinit(self.gpa);
    }

    pub fn writeSteps(self: *@This(), b: *std.Build, step: *std.Build.Step, writer: anytype) !void {
        const pkg_entry = try self.pkgs.getOrPut(self.gpa, @intFromPtr(step.owner));
        if (!pkg_entry.found_existing) {
            pkg_entry.value_ptr.* = self.pkg_id;
            self.pkg_id += 1;
        }

        const step_entry = try self.steps.getOrPut(self.gpa, @intFromPtr(step));
        if (step_entry.found_existing) {
            if (step_entry.value_ptr.visited) return;
            step_entry.value_ptr.visited = true;
            step_entry.value_ptr.pkg_id = pkg_entry.value_ptr.*;
        } else {
            step_entry.value_ptr.* = .{
                .id = self.step_id,
                .visited = true,
                .pkg_id = pkg_entry.value_ptr.*,
            };
            self.step_id += 1;
        }

        try self.printStep(b, step, step_entry.value_ptr.*.id, writer);

        self.depth += 1;
        for (step.dependencies.items) |dep_step| {
            try self.writeSteps(b, dep_step, writer);
        }
        self.depth -= 1;
    }

    fn printStep(self: *@This(), b: *std.Build, step: *std.Build.Step, i: u32, writer: anytype) !void {
        const pkg_entry = try self.pkgs.getOrPut(self.gpa, @intFromPtr(step.owner));
        if (!pkg_entry.found_existing) {
            pkg_entry.value_ptr.* = self.pkg_id;
            self.pkg_id += 1;
        }
        {
            const label = try depBuildRootEscaped(b, step.owner, self.gpa);
            const color = stepColor(step);
            defer self.gpa.free(label);
            try writer.print(node, .{
                i,
                step.name,
                color,
                pkg_entry.value_ptr.*,
                label,
            });
        }
        for (step.dependencies.items) |dep_step| {
            const dot_entry = try self.steps.getOrPut(self.gpa, @intFromPtr(dep_step));
            if (!dot_entry.found_existing) {
                dot_entry.value_ptr.* = .{
                    .id = self.step_id,
                    .visited = false,
                };
                self.step_id += 1;
            }
            try writer.print(cluster, .{
                i,
                dot_entry.value_ptr.id,
            });
        }
    }

    pub fn writeClusters(self: *@This(), b: *std.Build, writer: anytype) !void {
        var iter = self.pkgs.iterator();
        while (iter.next()) |val| {
            const build: *std.Build = @ptrFromInt(val.key_ptr.*);
            {
                const label = try depBuildRootEscaped(b, build, self.gpa);
                defer self.gpa.free(label);
                try writer.print(cluster_header, .{ val.value_ptr.*, label });
            }
            var step_iter = self.steps.iterator();
            while (step_iter.next()) |step_entry| {
                const step: *std.Build.Step = @ptrFromInt(step_entry.key_ptr.*);
                if (step.owner == build) {
                    try writer.print("  \"N{d}\"\n", .{step_entry.value_ptr.id});
                }
            }
            try writer.writeAll("}\n");
        }
    }
};

fn depBuildRootEscaped(root_b: *const std.Build, dep_b: *const std.Build, gpa: std.mem.Allocator) ![]u8 {
    const cache_root = root_b.graph.global_cache_root.path.?;
    const raw_label = if (std.mem.startsWith(u8, dep_b.build_root.path.?, cache_root))
        dep_b.build_root.path.?[cache_root.len + std.fs.path.sep_str.len * 2 + 1 ..]
    else if (dep_b == root_b)
        std.fs.path.basename(root_b.build_root.path.?)
    else if (std.mem.startsWith(u8, dep_b.build_root.path.?, root_b.build_root.path.?))
        dep_b.build_root.path.?[root_b.build_root.path.?.len..]
    else
        dep_b.build_root.path.?;

    return std.mem.replaceOwned(
        u8,
        gpa,
        raw_label,
        "\\",
        "\\\\",
    );
}

fn stepColor(step: *std.Build.Step) []const u8 {
    inline for (&.{
        .{ std.Build.Step.Compile, "#6495ed" },
        .{ std.Build.Step.InstallArtifact, "#309430" },
        .{ std.Build.Step.InstallDir, "#8b4513" },
        .{ std.Build.Step.InstallFile, "#8f6f6f" },
        .{ std.Build.Step.Run, "#bdb76b" },
        .{ std.Build.Step.WriteFile, "#000080" },
        .{ std.Build.Step.UpdateSourceFiles, "#ff44ff" },
        .{ std.Build.Step.CheckFile, "#b03060" },
        .{ std.Build.Step.CheckObject, "#ff4500" },
        .{ std.Build.Step.ConfigHeader, "#ff4500" },
        .{ std.Build.Step.Fail, "#ffa500" },
        .{ std.Build.Step.Fmt, "#ffff00" },
        .{ std.Build.Step.ObjCopy, "#7fff00" },
        .{ std.Build.Step.Options, "#00ffff" },
        .{ std.Build.Step.RemoveDir, "#0000ff" },
        .{ std.Build.Step.TranslateC, "#00fa9a" },
    }) |T| {
        if (step.cast(T[0]) != null) return T[1];
    }
    return "#ffffff";
}

pub fn printStructStdout(item: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try std.zon.stringify.serializeMaxDepth(item, .{
        .whitespace = true,
    }, stdout, 3);
    try stdout.writeAll("\n");
}
