const std = @import("std");
const print = std.log.info;
const pkg_extractor = @import("pkg-extractor.zig");

const usage = 
\\usage: zigpkg <subcommand> [--help]
\\
\\available subcommands:
\\  extract <package>
\\
\\environment variables:
\\
\\  ZIG: path to the zig compiler to invoke in subprocesses. defaults to "zig".
\\
;

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_alloc.allocator();
    defer _ = gpa_alloc.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();

    const opt: GlobalOptions = .{
        .gpa = gpa,
        .zig_exe = env_map.get("ZIG") orelse "zig",
        .env = env_map,
        .stdout = std.io.getStdOut().writer().any(),
        .stderr = std.io.getStdErr().writer().any(),
    };

    if (args.len < 2) {
        try opt.stdout.writeAll(usage);
        return std.process.exit(1);
    }

    inline for (commands) |cmd| {
        if (std.mem.eql(u8, args[1], cmd[0])) {
            return cmd[1](opt, args[2..]);
        }
    }
}

const commands = &.{
    .{"extract", cmd_extract},
};

const GlobalOptions = struct {
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    env: std.process.EnvMap,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
};

pub fn cmd_extract(opt: GlobalOptions, args: []const []const u8) !void {
    if (args.len != 1) {
        try opt.stdout.writeAll(
            \\usage: zigpkg extract <tar.gz filename>
            \\
        );
        return std.process.exit(1);
    }
    try pkg_extractor.process(.{
        .gpa = opt.gpa,
        .zig_exe = opt.zig_exe,
        .filepath = args[0],
    });
}
