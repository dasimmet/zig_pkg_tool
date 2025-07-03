const std = @import("std");
const builtin = @import("builtin");

// master is on this state:
// https://github.com/ziglang/zig/commit/31bc6d5a9ddaf09511d8e5dc6017957adec0564b
// 0.15.0-dev.911+31bc6d5a9
pub const runner = if (builtin.zig_version.order(std.SemanticVersion.parse("0.14.0") catch unreachable) == .gt)
    @import("runner-zig-master.zig")
else
    @import("runner-zig-0.14.0.zig");
