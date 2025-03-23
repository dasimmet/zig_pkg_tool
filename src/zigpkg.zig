const std = @import("std");
const print = std.log.info;
const pkg_extractor = @import("pkg-extractor.zig");
const pkg_targz = @import("pkg-targz.zig");
const known_folders = @import("known-folders");
const Manifest = @import("Manifest.zig");
const Serialize = @import("BuildSerialize.zig");
const BuildRunnerTmp = @import("BuildRunnerTmp.zig");

const usage =
    \\usage: zigpkg <subcommand> [--help]
    \\
    \\stores all dependencies of a directory containing build.zig.zon in a .tar.gz archive
    \\
    \\available subcommands:
    \\  dot      <build root path> [--] [zig build args]
    \\  zon      {<build root path>|--} [zig build args]
    \\  create   <deppkg.tar.gz> {build root path}
    \\  extract  <deppkg.tar.gz> {build root output path}
    \\  build    <deppkg.tar.gz> <intall prefix> [zig build args] # WIP
    \\  checkout <empty directory for git deps> {build root path} # WIP
    \\
    \\environment variables:
    \\
    \\  ZIG: path to the zig compiler to invoke in subprocesses. defaults to "zig".
    \\
;

const commands = &.{
    .{ "dot", cmd_dot },
    .{ "create", cmd_create },
    .{ "extract", cmd_extract },
    .{ "build", cmd_build },
    .{ "checkout", cmd_checkout },
    .{ "zon", cmd_zon },
};

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

    var opt: GlobalOptions = .{
        .gpa = gpa,
        .self_exe = args[0],
        .cwd = cwd,
        .zig_exe = env_map.get("ZIG") orelse "zig",
        .env_map = env_map,
        .stdout = stdout,
        .stderr = std.io.getStdErr().writer().any(),
    };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) opt.debug_level += 1;
        if (std.mem.eql(u8, arg, "-d")) opt.debug_level += 1;
    }

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
        if (std.mem.eql(u8, arg, "--")) break;
        inline for (&.{ "--help", "-h", "-?" }) |helparg| {
            if (std.mem.eql(u8, arg, helparg)) return true;
        }
    }
    return false;
}

const GlobalOptions = struct {
    gpa: std.mem.Allocator,
    self_exe: []const u8,
    cwd: []const u8,
    debug_level: u8 = 0,
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

pub fn cmd_create(opt: GlobalOptions, args: []const []const u8) !void {
    const cmd_usage =
        \\usage: zigpkg create <deppkg.tar.gz> <<build root path>|--> [z]
        \\
    ;
    if (args.len < 1) {
        try opt.stdout.writeAll(cmd_usage);
        return std.process.exit(1);
    }

    const output = try std.fs.path.resolve(opt.gpa, &.{ opt.cwd, args[0] });
    defer opt.gpa.free(output);

    const root = if (args.len > 1 and !std.mem.eql(u8, args[1], "--")) args[1] else ".";
    const arg_sep: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "--")) 2 else 1;

    const serialized_b = try runZonStdoutCommand(
        opt,
        "runner-zon.zig",
        root,
        args[arg_sep..],
        Serialize,
    );
    defer serialized_b.deinit(opt.gpa);
    const cache = if (opt.env_map.get(
        "ZIG_GLOBAL_CACHE_DIR",
    )) |dir| dir else blk: {
        const cp = try known_folders.getPath(
            opt.gpa,
            .cache,
        ) orelse return error.CacheNotFound;
        break :blk try std.fs.path.join(
            opt.gpa,
            &.{ cp, "zig" },
        );
    };

    try pkg_targz.fromBuild(
        opt.gpa,
        serialized_b.parsed,
        cache,
        root,
        output,
    );
}

pub fn cmd_dot(opt: GlobalOptions, args: []const []const u8) !void {
    var arg_sep: usize = 0;
    var root: []const u8 = ".";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            arg_sep += 1;
            break;
        } else if (arg_sep == 0) {
            arg_sep += 1;
            root = arg;
            break;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    return runnerCommand(opt, "runner-dot.zig", root, args[arg_sep..]);
}

pub fn cmd_zon(opt: GlobalOptions, args: []const []const u8) !void {
    var arg_sep: usize = 0;
    var root: []const u8 = ".";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            arg_sep += 1;
            break;
        } else if (arg_sep == 0) {
            arg_sep += 1;
            root = arg;
            break;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    const serialized_b = try runZonStdoutCommand(
        opt,
        "runner-zon.zig",
        root,
        args[arg_sep..],
        Serialize,
    );
    defer serialized_b.deinit(opt.gpa);

    try std.zon.stringify.serialize(serialized_b.parsed, .{
        .whitespace = true,
        .emit_default_optional_fields = false,
    }, opt.stdout);
    try opt.stdout.writeAll("\n");
    // std.log.info("Build: \n{any}\n", .{serialized_b.parsed});
}

pub fn runZonStdoutCommand(opt: GlobalOptions, runner: []const u8, root: []const u8, args: []const []const u8, T: type) !struct {
    parsed: T,
    source: [:0]u8,
    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        gpa.free(self.source);
        std.zon.parse.free(gpa, self.parsed);
    }
} {
    var buildrunner: BuildRunnerTmp.Embedded = try .init(opt.gpa, runner);
    defer buildrunner.deinit(opt.gpa);

    var argv = std.ArrayList([]const u8).init(opt.gpa);
    defer argv.deinit();
    try argv.appendSlice(&.{
        opt.zig_exe, "build", "--build-runner", buildrunner.runner,
    });
    try argv.appendSlice(args);

    const term = try std.process.Child.run(.{
        .argv = argv.items,
        .allocator = opt.gpa,
        .cwd = root,
        .env_map = &opt.env_map,
    });
    defer opt.gpa.free(term.stdout);
    defer opt.gpa.free(term.stderr);
    try opt.stderr.writeAll(term.stderr);

    switch (term.term) {
        .Exited => |ex| {
            if (ex != 0) {
                try opt.stderr.print("subprocess exitcode: {d}\n", .{ex});
                return error.ExitCode;
            }
        },
        else => {
            try opt.stderr.print("Term: {}\n", .{term.term});
            return error.Term;
        },
    }
    const my_src = try opt.gpa.dupeZ(u8, term.stdout);
    return .{
        .parsed = try std.zon.parse.fromSlice(T, opt.gpa, my_src, null, .{}),
        .source = my_src,
    };
}

pub fn runnerCommand(opt: GlobalOptions, runner: []const u8, root: []const u8, args: []const []const u8) !void {
    var buildrunner: BuildRunnerTmp.Embedded = try .init(opt.gpa, runner);
    defer buildrunner.deinit(opt.gpa);

    var argv = std.ArrayList([]const u8).init(opt.gpa);
    defer argv.deinit();
    try argv.appendSlice(&.{
        opt.zig_exe, "build", "--build-runner", buildrunner.runner,
    });
    try argv.appendSlice(args);

    var proc = std.process.Child.init(argv.items, opt.gpa);
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

pub fn cmd_build(opt: GlobalOptions, args: []const []const u8) !void {
    _ = args;
    const cmd_usage =
        \\usage: zigpkg build <deppkg.tar.gz> <install directory> [zig build args]
        \\
        \\extract and build the contents from a deppkg.tar.gz directly in a temporary directory
        \\
    ;
    try opt.stdout.writeAll(cmd_usage);
    @panic("NOT IMPLEMENTED");
}

pub fn cmd_checkout(opt: GlobalOptions, args: []const []const u8) !void {
    _ = args;
    const cmd_usage =
        \\usage: zigpkg checkout <empty directory for git deps> {build root path} 
        \\
        \\git clone the git dependencies in build.zig.zon
        \\in an empty directory, and rewrite build.zig.zon to point to
        \\the clones
        \\
    ;
    try opt.stdout.writeAll(cmd_usage);
    @panic("NOT IMPLEMENTED");
}
