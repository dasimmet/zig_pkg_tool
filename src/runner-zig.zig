const std = @import("std");
const builtin = @import("builtin");

// changes to readFileAllocOptions after this
const later_than_zig_15 = std.mem.containsAtLeastScalar(std.math.Order, &.{
    .gt,
    .eq,
}, 1, builtin.zig_version.order(
    std.SemanticVersion.parse("0.16.0") catch unreachable,
));

pub const runner = if (later_than_zig_15)
    // 0.16.0-dev.1354+94e98bfe8
    @import("runner-zig-master.zig")
else
    @import("runner-zig-0.15.X.zig");
