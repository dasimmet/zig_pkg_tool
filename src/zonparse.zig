
const std = @import("std");
const builtin = @import("builtin");
pub const zonparse = if (builtin.zig_version.order(std.SemanticVersion.parse("0.14.0") catch unreachable) == .eq)
    @import("zonparse-0.14.0.zig")
else
    @import("zonparse-master.zig");