const std = @import("std");
const lib = @import("example_lib");

pub fn main(init: std.process.Init) !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    var stdout_buf: [128]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_file.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});
    try stdout.flush();
}

test "simple test" {
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), smith: *std.testing.Smith) anyerror!void {
            _ = context;
            var buf: [64]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
