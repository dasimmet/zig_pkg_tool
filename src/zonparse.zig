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

pub const zonparse = if (zig_15_or_later)
    @import("zonparse-master.zig")
else
    @import("zonparse-0.14.0.zig");

pub const Diagnostics = if (zig_15_or_later)
    zonparse.Diagnostics
else
    zonparse.Status;
