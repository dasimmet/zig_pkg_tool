const std = @import("std");
const builtin = @import("builtin");
pub const root = @import("@build");
pub const dependencies = @import("@dependencies");
const Manifest = @import("Manifest.zig");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer {
        switch (gpa_alloc.deinit()) {
            .leak => @panic("GPA MEMORY LEAK"),
            .ok => {},
        }
    }

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_alloc.allocator();
    defer arena_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 9) {
        for (args, 0..) |arg, i| {
            std.debug.print("arg {d}: {s}\n", .{ i, arg });
        }
        std.log.err("usage: zig build --build-runner <path to runner>", .{});
        return;
    }

    const zig_exe = args[1];
    _ = zig_exe;
    const zig_lib_dir = args[2];
    _ = zig_lib_dir;
    const build_root = args[3];
    // _ = build_root;
    const cache_dir = args[4];
    _ = cache_dir;
    const rootdep: TreeDep = .{
        .path = build_root,
    };

    var dep_iter = rootdep.iterate(arena);
    while (try dep_iter.next()) |it| {
        std.debug.print("dep: depth: {d} hash: {?s} path: \"{s}\"\n", .{
            it.depth,
            it.hash,
            it.path,
        });
    }
}

pub const TreeDep = struct {
    depth: usize = 0,
    hash: ?[]const u8 = null,
    manifest: ?Manifest = null,
    path: []const u8,
    pub fn iterate(self: TreeDep, arena: std.mem.Allocator) Iterator {
        return .{
            .root = self,
            .arena = arena,
        };
    }

    pub const Iterator = struct {
        root: TreeDep,
        last: ?TreeDep = null,
        arena: std.mem.Allocator,
        pub fn next(self: *Iterator) !?TreeDep {
            if (self.last) |last| {
                const zon_path = try std.fs.path.join(self.arena, &.{ last.path, Manifest.basename });
                const zon_src = std.fs.cwd().readFileAllocOptions(
                    self.arena,
                    zon_path,
                    std.math.maxInt(u32),
                    null,
                    1,
                    0,
                ) catch |err| switch (err) {
                    error.FileNotFound => return null,
                    else => return err,
                };
                var zonStatus: std.zon.parse.Status = .{};
                // defer zonStatus.deinit(self.arena);
                const zon = Manifest.fromSlice(self.arena, zon_src, &zonStatus) catch |err| {
                    Manifest.log(std.log.err, err, last.path, zonStatus);
                    return err;
                };
                if (zon.dependencies) |deps| {
                    std.debug.print("deps: {any}\n", .{deps});
                    return null;
                } else {
                    return null;
                }
            } else {
                self.last = self.root;
                return self.last;
            }
        }
    };
};

// inline for (comptime std.meta.declarations(dependencies.packages)) |decl| {
//     const hash = decl.name;
//     const dep = @field(dependencies.packages, hash);
// }
