const std = @import("std");
const Manifest = @This();
pub const zonparse = @import("zonparse.zig");
const ZonDiag = zonparse.Status;
pub const basename = "build.zig.zon";

name: []const u8,
paths: []const []const u8,
version: []const u8,
dependencies: ?zonparse.ZonStructHashMap(struct {
    lazy: ?bool = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
}) = null,

pub fn fromSlice(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    zonStatus: ?*ZonDiag,
) !Manifest {
    return zonparse.fromSlice(
        Manifest,
        allocator,
        source,
        zonStatus,
        .{
            .ignore_unknown_fields = true,
        },
    );
}

pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
    zonparse.free(allocator, self);
}

const LogFunction = @TypeOf(std.log.err);

pub fn log(logfn: LogFunction, err: anyerror, manifest_path: []const u8, diag: ZonDiag) void {
    const fmt_str = "Manifest: {s} {s}" ++ std.fs.path.sep_str ++ basename ++ ":{}";
    logfn(fmt_str, .{ @errorName(err), manifest_path, diag });
}

pub fn iterate(root: [:0]const u8, gpa: std.mem.Allocator) Iterator {
    return .{
        .gpa = gpa,
        .root_path = root,
    };
}

const ManifestFile = struct {
    path: []const u8,
    source: [:0]const u8,
    manifest: Manifest,
    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        self.manifest.deinit();
        allocator.free(self.path);
        allocator.free(self.source);
    }
};

pub const Iterator = struct {
    gpa: std.mem.Allocator,
    root_path: []const u8,
    source: ?[:0]const u8 = null,
    i: usize = 0,
    parent: ?ManifestFile = null,
    child: ?ManifestFile = null,
    pub fn next(self: *@This()) !?Manifest {
        var next_path: ?[:0]const u8 = null;
        if (self.parent) |manifest| {
            if (manifest.manifest.dependencies) |deps| {
                var zon_iter = deps.impl.iterator();
                var i: usize = 0;
                blk: {
                    while (zon_iter.next()) |zon_dep| : (i += 1) {
                        if (i == self.i) {
                            self.i += 1;
                            if (zon_dep.value_ptr.path) |subpath| {
                                next_path = try std.fs.path.joinZ(self.gpa, &.{
                                    std.fs.path.dirname(manifest.path) orelse ".",
                                    subpath[0..],
                                    "build.zig.zon",
                                });
                                break :blk;
                            }
                        }
                    }
                    manifest.manifest.deinit(self.gpa);
                    self.parent = null;
                    next_path = null;
                }
            }
        }
        if (next_path) |zon_path| {
            var zonDiag: ZonDiag = .{};
            self.child = .{
                .path = zon_path,
                .source = try std.fs.cwd().readFileAllocOptions(
                    self.gpa,
                    zon_path,
                    std.math.maxInt(u32),
                    null,
                    1,
                    0,
                ),
                .manifest = undefined,
            };
            self.child.?.manifest = try fromSlice(self.gpa, self.source.?, &zonDiag);

            if (self.parent == null) {
                self.parent = self.child;
            }
            return self.child.?.manifest;
        } else {
            return null;
        }
    }
};
