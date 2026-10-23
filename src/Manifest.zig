const std = @import("std");
const Manifest = @This();
pub const basename = "build.zig.zon";

pub const Dependency = struct {
    lazy: ?bool = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const ZonDiag = struct {
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

name: []const u8 = "",
paths: ?[]const []const u8 = null,
version: []const u8 = "",
fingerprint: ?u64 = null,
dependencies: ?std.StringArrayHashMapUnmanaged(Dependency) = null,
minimum_zig_version: ?[]const u8 = null,

pub fn fromSliceAlloc(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    zonStatus: ?*ZonDiag,
) !Manifest {
    _ = zonStatus;
    var ast = try std.zig.Ast.parse(allocator, source, .{ .mode = .zon });
    defer ast.deinit(allocator);

    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(allocator);

    var manifest: Manifest = .{};

    const root_node = std.zig.Zoir.Node.Index.root.get(&zoir);
    switch (root_node) {
        .struct_literal => |s| {
            for (s.names, 0..) |nts, i| {
                const name = nts.get(&zoir);
                const val_idx = s.vals.at(@intCast(i));
                const val_node = val_idx.get(&zoir);

                if (std.mem.eql(u8, name, "name")) {
                    manifest.name = switch (val_node) {
                        .string_literal => |v| try allocator.dupe(u8, v),
                        .enum_literal => |e_nts| try allocator.dupe(u8, e_nts.get(&zoir)),
                        else => "",
                    };
                } else if (std.mem.eql(u8, name, "version")) {
                    manifest.version = switch (val_node) {
                        .string_literal => |v| try allocator.dupe(u8, v),
                        else => "",
                    };
                } else if (std.mem.eql(u8, name, "minimum_zig_version")) {
                    manifest.minimum_zig_version = switch (val_node) {
                        .string_literal => |v| try allocator.dupe(u8, v),
                        else => null,
                    };
                } else if (std.mem.eql(u8, name, "paths")) {
                    switch (val_node) {
                        .array_literal => |arr| {
                            var p_list = try allocator.alloc([]const u8, arr.len);
                            var p_count: usize = 0;
                            while (p_count < arr.len) : (p_count += 1) {
                                const elem_idx = arr.at(@intCast(p_count));
                                switch (elem_idx.get(&zoir)) {
                                    .string_literal => |sv| p_list[p_count] = try allocator.dupe(u8, sv),
                                    else => p_list[p_count] = "",
                                }
                            }
                            manifest.paths = p_list;
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, name, "dependencies")) {
                    switch (val_node) {
                        .struct_literal => |deps_s| {
                            var dep_map: std.StringArrayHashMapUnmanaged(Dependency) = .empty;
                            for (deps_s.names, 0..) |dep_nts, j| {
                                const dep_key = dep_nts.get(&zoir);
                                const dep_node = deps_s.vals.at(@intCast(j)).get(&zoir);
                                switch (dep_node) {
                                    .struct_literal => |fields_s| {
                                        var dep: Dependency = .{};
                                        for (fields_s.names, 0..) |f_nts, k| {
                                            const f_name = f_nts.get(&zoir);
                                            const f_val = fields_s.vals.at(@intCast(k)).get(&zoir);
                                            if (std.mem.eql(u8, f_name, "url")) {
                                                switch (f_val) {
                                                    .string_literal => |sv| dep.url = try allocator.dupe(u8, sv),
                                                    else => {},
                                                }
                                            } else if (std.mem.eql(u8, f_name, "hash")) {
                                                switch (f_val) {
                                                    .string_literal => |sv| dep.hash = try allocator.dupe(u8, sv),
                                                    else => {},
                                                }
                                            } else if (std.mem.eql(u8, f_name, "path")) {
                                                switch (f_val) {
                                                    .string_literal => |sv| dep.path = try allocator.dupe(u8, sv),
                                                    else => {},
                                                }
                                            } else if (std.mem.eql(u8, f_name, "lazy")) {
                                                switch (f_val) {
                                                    .true => dep.lazy = true,
                                                    .false => dep.lazy = false,
                                                    else => {},
                                                }
                                            }
                                        }
                                        try dep_map.put(allocator, try allocator.dupe(u8, dep_key), dep);
                                    },
                                    else => {},
                                }
                            }
                            manifest.dependencies = dep_map;
                        },
                        else => {},
                    }
                }
            }
        },
        else => {},
    }
    return manifest;
}

pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
    if (self.name.len > 0) allocator.free(self.name);
    if (self.version.len > 0) allocator.free(self.version);
    if (self.minimum_zig_version) |mzv| allocator.free(mzv);
    if (self.paths) |paths| {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    if (self.dependencies) |mut_deps| {
        var deps = mut_deps;
        for (deps.keys()) |k| allocator.free(k);
        for (deps.values()) |dep| {
            if (dep.url) |u| allocator.free(u);
            if (dep.hash) |h| allocator.free(h);
            if (dep.path) |p| allocator.free(p);
        }
        deps.deinit(allocator);
    }
}

const LogFunction = @TypeOf(std.log.err);

pub fn log(logfn: LogFunction, err: anyerror, manifest_path: []const u8, diag: ZonDiag) void {
    _ = diag;
    const fmt_str = "Manifest: {s} {s}" ++ std.fs.path.sep_str ++ basename;
    logfn(fmt_str, .{ @errorName(err), manifest_path });
}

pub fn cwdReadFileAllocZ(
    subpath: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) ![:0]const u8 {
    const cwd = std.Io.Dir.cwd();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return cwd.readFileAllocOptions(
        io,
        subpath,
        allocator,
        std.Io.Limit.limited(max_bytes),
        std.mem.Alignment.@"1",
        0,
    );
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
        self.manifest.deinit(allocator);
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
        zon_iterator: ?std.StringArrayHashMapUnmanaged(Manifest.Dependency).Iterator = null,

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
                        const zon_path = try std.fs.path.join(self.gpa, &.{
                            std.fs.path.dirname(self.parent.?.path) orelse ".",
                            subpath[0..],
                            "build.zig.zon",
                        });
                        var zonDiag: ZonDiag = .{};
                        const source = try cwdReadFileAllocZ(
                            zon_path,
                            self.gpa,
                            std.math.maxInt(u32),
                        );
                        const child: ManifestFile = .{
                            .path = zon_path,
                            .source = source,
                            .manifest = try fromSliceAlloc(self.gpa, source, &zonDiag),
                        };
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
