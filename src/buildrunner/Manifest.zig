const std = @import("std");
const Manifest = @This();
pub const cwdReadFileAllocZ = @import("zonparse.zig").cwdReadFileAllocZ;
pub const zonparse = @import("zonparse.zig").zonparse;
pub const ZonDiag = @import("zonparse.zig").Diagnostics;
pub const basename = "build.zig.zon";
pub const Dependency = struct {
    lazy: ?bool = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

name: []const u8,
paths: ?[]const []const u8 = null,
version: []const u8,
fingerprint: ?usize = null,
dependencies: ?zonparse.ZonStructHashMap(Dependency) = null,
minimum_zig_version: ?[]const u8 = null,

pub fn fromSliceAlloc(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    zonStatus: ?*ZonDiag,
) !Manifest {
    return @import("zonparse.zig").fromSliceAlloc(
        Manifest,
        allocator,
        source,
        zonStatus,
        .{
            .ignore_unknown_fields = true,
            .enum_literals_as_strings = true,
        },
    );
}

pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
    zonparse.free(allocator, self);
}

const LogFunction = @TypeOf(std.log.err);

pub fn log(logfn: LogFunction, err: anyerror, manifest_path: []const u8, diag: ZonDiag) void {
    const fmt_str = "Manifest: {s} {s}" ++ std.fs.path.sep_str ++ basename ++ ":{f}";
    logfn(fmt_str, .{ @errorName(err), manifest_path, diag });
}

pub const ManifestFile = struct {
    path: []const u8,
    source: [:0]const u8,
    manifest: Manifest,
    fn init(path: []const u8) ManifestFile {
        return .{
            .path = path,
            .source = undefined,
            .manifest = undefined,
        };
    }
    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        self.manifest.deinit();
        allocator.free(self.path);
        allocator.free(self.source);
    }

    pub fn iterate(self: @This(), gpa: std.mem.Allocator) Iterator {
        return .{
            .gpa = gpa,
            .root_path = self.path,
        };
    }

    pub const Iterator = struct {
        gpa: std.mem.Allocator,
        root_path: []const u8,
        i: usize = 0,
        parent: ?ManifestFile = null,
        child: ?ManifestFile = null,
        zon_iterator: ?zonparse.ZonStructHashMap(Manifest.Dependency).HashMap.Iterator = null,
        pub fn deinit(self: *@This()) void {
            if (self.parent) |parent| {
                _ = parent;
            }
        }

        pub fn next(self: *@This()) !?ManifestFile {
            if (self.zon_iterator) |*iter| {
                if (iter.next()) |dependency| {
                    const zon_dep = dependency.value_ptr;
                    if (zon_dep.path) |subpath| {
                        const zon_path = try std.fs.path.joinZ(self.gpa, &.{
                            std.fs.path.dirname(self.parent.?.path) orelse ".",
                            subpath[0..],
                            "build.zig.zon",
                        });
                        var zonDiag: ZonDiag = .{};
                        var child: ManifestFile = .{
                            .path = zon_path,
                            .source = try cwdReadFileAllocZ(
                                self.gpa,
                                zon_path,
                                std.math.maxInt(u32),
                            ),
                            .manifest = undefined,
                        };
                        child.manifest = try fromSliceAlloc(self.gpa, child.source, &zonDiag);
                        return child;
                    }
                }
                self.zon_iterator = null;
            }
            if (self.parent) |parent| {
                _ = parent;
            }
            return null;
        }
    };
};
