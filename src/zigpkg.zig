const std = @import("std");
const print = std.log.info;
const pkg_extractor = @import("pkg-extractor.zig");
const TempFile = @import("TempFile.zig");
const Sources = struct {
    pub const @"deppkg-runner.zig" = @embedFile("deppkg-runner.zig");
    pub const @"pkg-targz.zig" = @embedFile("pkg-targz.zig");
    pub const @"pkg-extractor.zig" = @embedFile("pkg-extractor.zig");
};

const usage =
    \\usage: zigpkg <subcommand> [--help]
    \\
    \\available subcommands:
    \\  extract <package>
    \\  create <output.tar.gz> {build root path}
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

    const stdout = std.io.getStdOut().writer().any();
    if (args.len < 2) {
        try stdout.writeAll(usage);
        return std.process.exit(1);
    }

    const opt: GlobalOptions = .{
        .gpa = gpa,
        .self_exe = args[0],
        .zig_exe = env_map.get("ZIG") orelse "zig",
        .env_map = env_map,
        .stdout = stdout,
        .stderr = std.io.getStdErr().writer().any(),
    };

    inline for (commands) |cmd| {
        if (std.mem.eql(u8, args[1], cmd[0])) {
            return cmd[1](opt, args[2..]);
        }
    }
}

const commands = &.{
    .{ "create", cmd_create },
    .{ "extract", cmd_extract },
};

const GlobalOptions = struct {
    gpa: std.mem.Allocator,
    self_exe: []const u8,
    zig_exe: []const u8,
    env_map: std.process.EnvMap,
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

pub fn cmd_create(opt: GlobalOptions, args: []const []const u8) !void {
    if (args.len == 0 or args.len > 2) {
        try opt.stdout.writeAll(
            \\usage: zigpkg create <output.tar.gz> {build root path}
            \\
        );
        return std.process.exit(1);
    }
    const output = args[0];
    const root = if (args.len == 2) args[1] else ".";

    var tempD = try TempFile.tmpDir(.{
        .prefix = "zigpkg",
    });
    defer tempD.deinit();

    const runner = try std.fs.path.join(opt.gpa, &.{
        tempD.abs_path,
        "deppkg-runner.zig",
    });
    defer opt.gpa.free(runner);

    inline for (comptime std.meta.declarations(Sources)) |decl| {
        try tempD.dir.writeFile(.{
            .data = @field(Sources, decl.name),
            .sub_path = decl.name,
        });
    }

    var proc = std.process.Child.init(&.{
        opt.zig_exe, "build", "--build-runner", runner, output,
    }, opt.gpa);
    proc.stdin_behavior = .Inherit;
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;
    proc.cwd = root;
    proc.env_map = &opt.env_map;
    try proc.spawn();
    const term = try proc.wait();
    switch (term) {
        .Exited => |ex| {
            if (ex != 0) {
                try opt.stderr.print("subprocess exitcode: {d}\n", .{ex});
                return error.ExitCode;
            }
        },
        else => {
            try opt.stderr.print("Term: {}\n", .{term});
            return error.Term;
        },
    }
}
