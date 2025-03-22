const std = @import("std");
const Build = std.Build;

const Serialized = @This();

name: []const u8,
location: Location,
dependencies: ?[]const Serialized,
steps: ?[]const Step = null,

pub fn serializeBuild(b: *std.Build, opt: std.zon.stringify.SerializeOptions) []const u8 {
    var serialized: Serialized = Serialized.init(b) catch |err| {
        std.log.err("serializeBuild: {s}", .{@errorName(err)});
        @panic("serializeBuild");
    };
    defer serialized.deinit(b);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    std.zon.stringify.serializeMaxDepth(serialized, opt, output.writer(b.allocator), 128) catch @panic("OOM");
    output.writer(b.allocator).writeAll("\n") catch @panic("OOM");
    return output.toOwnedSlice(b.allocator) catch @panic("OOM");
}

pub fn init(b: *std.Build) anyerror!@This() {
    var self = try recurse(b, b);
    try self.addSteps(b);
    return self;
}

pub fn recurse(root_b: *std.Build, b: *std.Build) !@This() {
    var deps: std.ArrayListUnmanaged(Serialized) = .empty;
    for (b.available_deps) |dep| {
        if (b.lazyDependency(dep[0], .{})) |lazy_dep| {
            try deps.append(b.allocator, try .recurse(root_b, lazy_dep.builder));
        }
    }
    return .{
        .name = depBuildRoot(root_b, b),
        .location = Location.fromRootBuildAndPath(root_b, b.build_root.path.?),
        .dependencies = try deps.toOwnedSlice(b.allocator),
    };
}

pub fn addSteps(self: *@This(), b: *std.Build) !void {
    var steps: Step.Context = if (self.steps) |_|
        return error.StepsNotNull
    else
        .empty;
    try addStepsRecurse(b, &steps);
    self.steps = steps.steps.values();
}

pub fn addStepsRecurse(b: *std.Build, steps: *Step.Context) !void {
    var tld_iter = b.top_level_steps.iterator();
    while (tld_iter.next()) |tld| {
        const gop = try steps.steps.getOrPut(b.allocator, @intFromPtr(&tld.value_ptr.*.step));
        const dep_gop = try steps.deps.getOrPut(b.allocator, @intFromPtr(&tld.value_ptr.*.step));
        if (!dep_gop.found_existing) dep_gop.value_ptr.* = .empty;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .id = tld.value_ptr.*.step.id,
                .name = tld.key_ptr.*,
                .dependencies = dep_gop.value_ptr.items,
            };
            try addDepSteps(b, tld.value_ptr.*.step, steps, @intCast(gop.index));
            const dep_gop2 = try steps.deps.getOrPut(b.allocator, @intFromPtr(&tld.value_ptr.*.step));
            const gop2 = try steps.steps.getOrPut(b.allocator, @intFromPtr(&tld.value_ptr.*.step));
            gop2.value_ptr.dependencies = dep_gop2.value_ptr.items;
        }
    }
}

pub fn addDepSteps(b: *Build, step: Build.Step, steps: *Step.Context, parent: ?u32) !void {
    for (step.dependencies.items) |dep| {
        const dep_gop = try steps.deps.getOrPut(b.allocator, @intFromPtr(dep));
        if (!dep_gop.found_existing) {
            dep_gop.value_ptr.* = .empty;
        }
        const gop = try steps.steps.getOrPut(b.allocator, @intFromPtr(dep));
        if (!gop.found_existing) { 
            gop.value_ptr.* = .{
                .id = dep.id,
                .parent = parent,
                .name = dep.name,
                .dependencies = dep_gop.value_ptr.items,
            };
            try addDepSteps(b, dep.*, steps, @intCast(gop.index));
        }
        if (parent) |p| {
            try steps.deps.values()[p].append(b.allocator, @intCast(gop.index));
        }
        const dep_gop2 = try steps.deps.getOrPut(b.allocator, @intFromPtr(dep));
        const gop2 = try steps.steps.getOrPut(b.allocator, @intFromPtr(dep));
        gop2.value_ptr.dependencies = dep_gop2.value_ptr.items;
    }
}

pub fn deinit(self: *@This(), b: *std.Build) void {
    // for (self.dependencies)|*dep| {
    //     dep.deinit(b.dependency(dep.name, .{}));
    // }
    _ = self;
    _ = b;
}

fn depBuildRoot(root_b: *const std.Build, dep_b: *const std.Build) []const u8 {
    const cache_root = root_b.graph.global_cache_root.path.?;
    return if (dep_b == root_b)
        std.fs.path.basename(root_b.build_root.path.?)
    else if (std.mem.startsWith(u8, dep_b.build_root.path.?, cache_root))
        dep_b.build_root.path.?[cache_root.len + std.fs.path.sep_str.len * 2 + 1 ..]
    else if (std.mem.startsWith(u8, dep_b.build_root.path.?, root_b.build_root.path.?))
        dep_b.build_root.path.?[root_b.build_root.path.?.len..]
    else
        dep_b.build_root.path.?;
}

pub const Location = enum {
    root,
    root_sub,
    cache,
    unknown,
    pub fn fromRootBuildAndPath(root_b: *const std.Build, build_path: []const u8) @This() {
        const cache_root = root_b.graph.global_cache_root.path.?;
        return if (std.mem.eql(u8, build_path, root_b.build_root.path.?))
            .root
        else if (std.mem.startsWith(u8, build_path, cache_root))
            .cache
        else if (std.mem.startsWith(u8, root_b.build_root.path.?, build_path))
            .root_sub
        else
            .unknown;
    }
};

const Step = struct {
    pub const Context = struct {
        steps:  std.AutoArrayHashMapUnmanaged(usize, Step),
        deps: std.AutoArrayHashMapUnmanaged(usize, std.ArrayListUnmanaged(u32)),
        pub const empty: Context = .{
            .steps = .empty,
            .deps = .empty,
        };
    };
    id: Build.Step.Id,
    parent: ?u32 = null,
    name: []const u8,
    dependencies: []u32 = &.{},
};
