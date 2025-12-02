const std = @import("std");
const builtin = @import("builtin");

// since the 0.14.0 release, there were changes to Zoir, which is referenced by
// `std.zon.parse`. We need to vendor this file here for now to be able
// to parse `build.zig.zon` for two reasons:
// - the `name` field is an enum literal with runtime unknown members and not supported yet.
//   PR: https://github.com/ziglang/zig/pull/23261
// - the `dependencies` field is a struct with runtime unknown fields. There is this PR:
//   PR: https://github.com/ziglang/zig/pull/22973
//   But in this tool i found another solution to parse it into a hashmap....
//   PR: TODO:
//
// So in this file, switch out `zonparse` based on the zig compiler version
// so it stays compatible with `master` as well as the release version

// 0.15.0-dev.375+8f8f37fb0
// https://github.com/dasimmet/zig/blob/zon-struct-hashmap/lib/std/zon/parse.zig
const zig_15_or_later = builtin.zig_version.order(std.SemanticVersion.parse("0.14.99") catch unreachable) == .gt;

// changes to readFileAllocOptions after this
const later_than_zig_15 = std.mem.containsAtLeastScalar(std.math.Order, &.{
    .gt,
    .eq,
}, 1, builtin.zig_version.order(
    std.SemanticVersion.parse("0.16.0") catch unreachable,
));

pub const zonparse = @import("zonparse-master.zig");

pub const Diagnostics = zonparse.Diagnostics;

pub const align_one = if (zig_15_or_later)
    std.mem.Alignment.@"1"
else
    1;

pub fn cwdReadFileAllocZ(
    subpath: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) ![:0]const u8 {
    const cwd = std.fs.cwd();
    if (comptime later_than_zig_15) {
        return cwd.readFileAllocOptions(
            subpath,
            allocator,
            std.Io.Limit.limited(max_bytes),
            align_one,
            0,
        );
    } else {
        return cwd.readFileAllocOptions(
            allocator,
            subpath,
            max_bytes,
            null,
            align_one,
            0,
        );
    }
}
