const std = @import("std");
const builtin = @import("builtin");

const later_than_zig_14 = std.mem.containsAtLeastScalar(std.math.Order, &.{
    .gt,
    .eq,
}, 1, builtin.zig_version.order(
    std.SemanticVersion.parse("0.15.0") catch unreachable,
));

// changes to readFileAllocOptions after this
const later_than_zig_15 = std.mem.containsAtLeastScalar(std.math.Order, &.{
    .gt,
    .eq,
}, 1, builtin.zig_version.order(
    std.SemanticVersion.parse("0.16.0") catch unreachable,
));

pub const zonparse = if (later_than_zig_14)
    @import("zonparse-master.zig")
else
    @import("zonparse-0.14.X.zig");

pub const fromSliceAlloc = if (later_than_zig_14)
    zonparse.fromSliceAlloc
else
    zonparse.fromSlice;

pub const Diagnostics = if (later_than_zig_14)
    zonparse.Diagnostics
else
    zonparse.Status;

pub const align_one = if (later_than_zig_14)
    std.mem.Alignment.@"1"
else
    1;

pub fn cwdReadFileAllocZ(
    subpath: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) ![:0]const u8 {
    const cwd = std.fs.cwd();
    if (comptime later_than_zig_14) {
        return cwd.readFileAllocOptions(
            allocator,
            subpath,
            max_bytes,
            null,
            align_one,
            0,
        );
    } else {
        return cwd.readFileAllocOptions(
            subpath,
            allocator,
            std.Io.Limit.limited(max_bytes),
            align_one,
            0,
        );
    }
}
