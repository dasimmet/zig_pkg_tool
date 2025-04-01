const std = @import("std");
const builtin = @import("builtin");

pub const runner = if (builtin.zig_version.order(std.SemanticVersion.parse("0.15.0-dev.155+acfdad858") catch unreachable) == .gt)
    @import("runner-zig-master.zig")
else
    @import("runner-zig-0.14.0.zig");
