const std = @import("std");
const builtin = @import("builtin");

// master is on this state:
// https://github.com/ziglang/zig/commit/b5a5260546ddd8953e493f75c5ee12c5a853263b
pub const runner = if (builtin.zig_version.order(std.SemanticVersion.parse("0.14.0") catch unreachable) == .gt)
    @import("runner-zig-master.zig")
else
    @import("runner-zig-0.14.0.zig");
