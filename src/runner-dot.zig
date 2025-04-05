const std = @import("std");
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
    pub const edge = "\"N{d}\" -> \"N{d}\"\n";
    pub const cluster_header = "subgraph cluster_{d} {{\n  cluster = true\n  label = \"{s}\"\n";
    pub const cluster_node = "  \"N{d}\"\n";
    pub const cluster_footer = "}\n";
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
            const color = stepColor(step.id);
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
            try writer.print(edge, .{
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
                    try writer.print(cluster_node, .{step_entry.value_ptr.id});
                }
            }
            try writer.writeAll(cluster_footer);
        }
    }
};

fn depBuildRootEscaped(root_b: *const std.Build, dep_b: *const std.Build, gpa: std.mem.Allocator) ![]u8 {
    const cache_root = root_b.graph.global_cache_root.path.?;
    return buildRootEscaped(
        cache_root,
        root_b.build_root.path.?,
        dep_b.build_root.path.?,
        gpa,
    );
}

pub fn buildRootEscaped(cache_root: []const u8, build_root: []const u8, dep_root: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const raw_label = if (std.mem.startsWith(u8, dep_root, cache_root))
        dep_root[cache_root.len + std.fs.path.sep_str.len * 2 + 1 ..]
    else if (std.mem.eql(u8, build_root, dep_root))
        std.fs.path.basename(build_root)
    else if (std.mem.startsWith(u8, dep_root, build_root))
        dep_root[build_root.len..]
    else
        build_root;

    return std.mem.replaceOwned(
        u8,
        gpa,
        raw_label,
        "\\",
        "\\\\",
    );
}

pub fn stepColor(id: std.Build.Step.Id) []const u8 {
    return switch (id) {
        .compile => "#6495ed",
        .install_artifact => "#309430",
        .install_dir => "#8b4513",
        .install_file => "#8f6f6f",
        .run => "#bdb76b",
        .write_file => "#3333aa",
        .update_source_files => "#ff44ff",
        .check_file => "#b03060",
        .check_object => "#ff4500",
        .config_header => "#ff4500",
        .fail => "#ffa500",
        .fmt => "#ffff00",
        .objcopy => "#7fff00",
        .options => "#00ffff",
        .remove_dir => "#0000ff",
        .translate_c => "#00fa9a",
        .top_level => "#ffffff",
        .custom => "#aaaaaa",
    };
}
