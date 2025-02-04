const std = @import("std");
const print = std.log.info;
const pkg_extractor = @import("pkg-extractor.zig");
const TempFile = @import("TempFile.zig");
const DepPkgRunner = struct {
    pub const @"deppkg-runner.zig" = @embedFile("deppkg-runner.zig");
    pub const @"pkg-targz.zig" = @embedFile("pkg-targz.zig");
    pub const @"pkg-extractor.zig" = @embedFile("pkg-extractor.zig");
    pub const @"zigpkg.zig" = @embedFile("zigpkg.zig");
    pub const @"TempFile.zig" = @embedFile("TempFile.zig");
};

const usage =
    \\usage: zigpkg <subcommand> [--help]
    \\
    \\stores all dependencies of a directory containing build.zig.zon in a .tar.gz archive
    \\
    \\available subcommands:
    \\  extract <deppkg.tar.gz>
    \\  create  <deppkg.tar.gz> {build root path}
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

    if (helpArg(args[1..2])) {
        try stdout.writeAll(usage);
        return;
    }

    const cwd = try std.process.getCwdAlloc(gpa);
    defer gpa.free(cwd);

    const opt: GlobalOptions = .{
        .gpa = gpa,
        .self_exe = args[0],
        .cwd = cwd,
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

    try stdout.writeAll(usage);
    try stdout.writeAll("unknown command: ");
    try stdout.writeAll(args[1]);
    try stdout.writeAll("\n");
    return std.process.exit(1);
}

pub fn helpArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

const commands = &.{
    .{ "create", cmd_create },
    .{ "extract", cmd_extract },
};

const GlobalOptions = struct {
    gpa: std.mem.Allocator,
    self_exe: []const u8,
    cwd: []const u8,
    zig_exe: []const u8,
    env_map: std.process.EnvMap,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
};

pub fn cmd_extract(opt: GlobalOptions, args: []const []const u8) !void {
    const cmd_usage =
        \\usage: zigpkg extract <deppkg.tar.gz>
        \\
    ;
    if (args.len != 1) {
        try opt.stdout.writeAll(cmd_usage);
        return std.process.exit(1);
    }
    if (helpArg(args[0..args.len])) {
        try opt.stdout.writeAll(cmd_usage);
        return;
    }
    try pkg_extractor.process(.{
        .gpa = opt.gpa,
        .zig_exe = opt.zig_exe,
        .filepath = args[0],
    });
}

pub fn BuildRunner(T: type) type {
    return struct {
        const Self = @This();
        temp: TempFile.TmpDir,
        runner: []const u8,

        pub fn init(gpa: std.mem.Allocator, runner_file: []const u8) !Self {
            var tempD = try TempFile.tmpDir(.{
                .prefix = "zigpkg",
            });

            const runner = try std.fs.path.join(gpa, &.{
                tempD.abs_path,
                runner_file,
            });

            inline for (comptime std.meta.declarations(T)) |decl| {
                try tempD.dir.writeFile(.{
                    .data = @field(T, decl.name),
                    .sub_path = decl.name,
                });
            }

            return .{
                .temp = tempD,
                .runner = runner,
            };
        }
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.temp.deinit();
            gpa.free(self.runner);
        }
    };
}

pub fn cmd_create(opt: GlobalOptions, args: []const []const u8) !void {
    const cmd_usage =
        \\usage: zigpkg create <deppkg.tar.gz> {build root path}
        \\
    ;
    if (args.len == 0 or args.len > 2) {
        try opt.stdout.writeAll(cmd_usage);
        return std.process.exit(1);
    }
    if (helpArg(args[0..args.len])) {
        try opt.stdout.writeAll(cmd_usage);
        return;
    }

    const output = try std.fs.path.resolve(opt.gpa, &.{ opt.cwd, args[0] });
    defer opt.gpa.free(output);

    const root = if (args.len == 2) args[1] else ".";

    var buildrunner: BuildRunner(DepPkgRunner) = try .init(opt.gpa, "deppkg-runner.zig");
    defer buildrunner.deinit(opt.gpa);

    var proc = std.process.Child.init(&.{
        opt.zig_exe, "build", "--build-runner", buildrunner.runner, output,
    }, opt.gpa);
    proc.stdin_behavior = .Inherit;
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;
    proc.cwd = root;
    proc.env_map = &opt.env_map;
    proc.expand_arg0 = .expand;

    const term = try proc.spawnAndWait();
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
