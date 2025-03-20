const std = @import("std");
const Build = std.Build;

const Serialized = @This();
pub const Location = enum {
    root,
    root_sub,
    cache,
    unknown,
    pub fn fromRootBuildAndPath(b: *const std.Build, build_path: []const u8) @This() {
        const cache_root = b.graph.global_cache_root.path.?;
        return if (std.mem.eql(u8, build_path, b.build_root.path.?))
            .root
        else if (std.mem.startsWith(u8, build_path, cache_root))
            .cache
        else if (std.mem.startsWith(u8, b.build_root.path.?,build_path))
            .root_sub
        else
            .unknown;
    }
};

name: []const u8,
location: Location,
dependencies: []const Serialized,

pub fn run(b: *std.Build) void {
    runCaught(b) catch |err| {
        std.log.err("\nserialize: {}\n", .{err});
    };
}

pub fn runCaught(b: *std.Build) !void {
    var serialized: Serialized = try .init(b);
    defer serialized.deinit(b);
    const stdout_file = std.io.getStdOut();
    const stdout = stdout_file.writer();
    try std.zon.stringify.serializeMaxDepth(serialized, .{}, stdout, 32);
}

pub fn serializeBuild(b: *std.Build, opt: std.zon.stringify.SerializeOptions) []const u8 {
    var serialized: Serialized = Serialized.init(b) catch |err| {
        std.log.err("serializeBuild: {s}", .{@errorName(err)});
        @panic("serializeBuild");
    };
    defer serialized.deinit(b);
    var output : std.ArrayListUnmanaged(u8) = .empty;
    std.zon.stringify.serializeMaxDepth(serialized, opt, output.writer(b.allocator), 128) catch @panic("OOM");
    output.writer(b.allocator).writeAll("\n") catch @panic("OOM");
    return output.toOwnedSlice(b.allocator) catch @panic("OOM");
}


pub fn init(b: *std.Build) anyerror!@This() {
    return recurse(b, b);
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