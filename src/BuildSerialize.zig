const std = @import("std");
const Build = std.Build;
const builtin = @import("builtin");

const Serialized = @This();

pub const Dependency = struct {
    pub const Index = u32;
    pub const Edge = struct {
        name: []const u8,
        id: Index,
    };

    name: []const u8,
    location: Location,
    dependencies: []const Edge = &.{},

    pub const Context = struct {
        index: std.AutoArrayHashMapUnmanaged(*std.Build, Dependency),
        deps: std.AutoArrayHashMapUnmanaged(*std.Build, std.ArrayListUnmanaged(Edge)),
    };
};
options: struct {
    available: []const AvailableOption,
    user_input: []const struct { []const u8, UserInputOption },
},
verbose: bool,
release_mode: Build.ReleaseMode,
dependencies: []const Dependency = &.{},
steps: ?[]const Step = null,
zig_version: []const u8,

pub fn serializeBuildOrPanic(b: *std.Build, opt: std.zon.stringify.SerializeOptions) []const u8 {
    return serializeBuild(b, opt) catch |err| {
        std.log.err("serializeBuild: {s}", .{@errorName(err)});
        @panic("serializeBuild");
    };
}

pub fn serializeBuild(b: *std.Build, opt: std.zon.stringify.SerializeOptions) ![]const u8 {
    var serialized: Serialized = try Serialized.init(b);
    defer serialized.deinit(b);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    std.zon.stringify.serializeMaxDepth(
        serialized,
        opt,
        output.writer(b.allocator),
        128,
    ) catch @panic("OOM");
    try output.writer(b.allocator).writeAll("\n");
    return output.toOwnedSlice(b.allocator);
}

pub fn init(b: *std.Build) anyerror!@This() {
    var ctx = Dependency.Context{
        .deps = .empty,
        .index = .empty,
    };
    try recurse(b, &ctx, b, null);

    var self: @This() = .{
        .options = .{
            .available = &.{},
            .user_input = &.{},
        },
        .verbose = b.verbose,
        .release_mode = b.release_mode,
        .dependencies = ctx.index.values(),
        .zig_version = builtin.zig_version_string,
    };
    try self.addOptions(b);
    try self.addSteps(b);
    return self;
}

pub fn recurse(root_b: *std.Build, ctx: *Dependency.Context, b: *std.Build, parent: ?Dependency.Index) !void {
    const gop_deps = try ctx.deps.getOrPut(root_b.allocator, b);
    if (!gop_deps.found_existing) gop_deps.value_ptr.* = .empty;
    const gop = try ctx.index.getOrPut(root_b.allocator, b);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .name = depBuildRoot(root_b, b),
            .location = Location.fromRootBuildAndPath(root_b, b.build_root.path.?),
            .dependencies = gop_deps.value_ptr.items,
        };
        for (b.available_deps) |dep| {
            if (b.lazyDependency(dep[0], .{})) |lazy_dep| {
                try recurse(root_b, ctx, lazy_dep.builder, @intCast(gop.index));
            }
        }
    }
    if (parent) |p| {
        try ctx.deps.values()[p].append(root_b.allocator, .{
            .name = "",
            .id = @intCast(gop.index),
        });
    }
    const gop2 = try ctx.index.getOrPut(root_b.allocator, b);
    const gop_deps2 = try ctx.deps.getOrPut(root_b.allocator, b);

    var dep_it: usize = 0;
    for (b.available_deps) |dep| {
        if (b.lazyDependency(dep[0], .{})) |_| {
            gop_deps2.value_ptr.items[dep_it].name = dep[0];
            dep_it += 1;
        }
    }
    gop2.value_ptr.dependencies = gop_deps2.value_ptr.items;
}

pub fn addOptions(self: *@This(), b: *std.Build) !void {
    var opts = std.ArrayListUnmanaged(struct { []const u8, UserInputOption }).empty;
    var opt_it = b.user_input_options.iterator();
    while (opt_it.next()) |opt| {
        try opts.append(b.allocator, .{ opt.key_ptr.*, .{
            .name = opt.value_ptr.name,
            .used = opt.value_ptr.used,
            .value = switch (opt.value_ptr.value) {
                .flag => .flag,
                .scalar => |optv| .{ .scalar = optv },
                .list => |optv| .{ .list = optv.items },
                .lazy_path => |optv| .{ .lazy_path = optv.getPath(b) },
                .lazy_path_list => |optv| blk: {
                    var lp_list = std.ArrayListUnmanaged([]const u8).empty;
                    for (optv.items) |lp| {
                        try lp_list.append(b.allocator, lp.getPath(b));
                    }
                    break :blk .{ .lazy_path_list = try lp_list.toOwnedSlice(b.allocator) };
                },
                .map => .map_dummy_not_implemented,
            },
        } });
    }
    self.options.user_input = try opts.toOwnedSlice(b.allocator);
    // TODO: im lazy casting this, because AvailableOption is private and vendored
    // it'll be fine as long as the the std.Build version is identical
    self.options.available = @ptrCast(b.available_options_list.items);
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
    const root_base = std.fs.path.basename(root_b.build_root.path.?);
    const sep_str = std.fs.path.sep_str.len;
    return if (dep_b == root_b)
        root_base
    else if (std.mem.startsWith(u8, dep_b.build_root.path.?, cache_root))
        dep_b.build_root.path.?[cache_root.len + sep_str * 2 + 1 ..]
    else if (std.mem.startsWith(u8, dep_b.build_root.path.?, root_b.build_root.path.?))
        dep_b.build_root.path.?[root_b.build_root.path.?.len - root_base.len ..]
    else
        dep_b.build_root.path.?;
}

pub const Location = enum {
    root,
    // a subdirectory of root
    root_sub,
    cache,
    // a subdirectory of a cached dep
    cache_sub,
    unknown,
    pub fn fromRootBuildAndPath(root_b: *const std.Build, build_path: []const u8) @This() {
        const cache_root = root_b.graph.global_cache_root.path.?;
        return if (std.mem.eql(u8, build_path, root_b.build_root.path.?))
            .root
        else if (std.mem.startsWith(u8, build_path, cache_root)) blk: {
            if (std.mem.containsAtLeast(u8, build_path[cache_root.len..], 3, std.fs.path.sep_str))
                break :blk .cache_sub;
            break :blk .cache;
        } else if (std.mem.startsWith(u8, build_path, root_b.build_root.path.?))
            .root_sub
        else
            .unknown;
    }
};

const Step = struct {
    pub const Context = struct {
        steps: std.AutoArrayHashMapUnmanaged(usize, Step),
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

// vendored and "non-recusive" from private std.Build
pub const UserInputOption = struct {
    name: []const u8,
    value: UserValue,
    used: bool,
};

pub const UserValue = union(enum) {
    flag: void,
    scalar: []const u8,
    list: []const []const u8,
    // TODO: fully support map with a non-recursive type
    // map: []const struct { []const u8, *const UserValue },
    map_dummy_not_implemented: void,
    lazy_path: []const u8,
    lazy_path_list: []const []const u8,
};

pub const AvailableOption = struct {
    name: []const u8,
    type_id: TypeId,
    description: []const u8,
    /// If the `type_id` is `enum` or `enum_list` this provides the list of enum options
    enum_options: ?[]const []const u8,
};

pub const TypeId = enum {
    bool,
    int,
    float,
    @"enum",
    enum_list,
    string,
    list,
    build_id,
    lazy_path,
    lazy_path_list,
};
