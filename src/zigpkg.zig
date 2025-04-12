const std = @import("std");
const print = std.log.info;
const pkg_extractor = @import("pkg-extractor.zig");
const pkg_targz = @import("pkg-targz.zig");
const known_folders = @import("known-folders");
pub const Manifest = @import("Manifest.zig");
const Serialize = @import("BuildSerialize.zig");
const BuildRunnerTmp = @import("BuildRunnerTmp.zig");
const dot = @import("runner-dot.zig");

const usage =
    \\usage: zigpkg <subcommand> [--help]
    \\
    \\stores all dependencies of a directory containing build.zig.zon in a .tar.gz archive
    \\
    \\available subcommands:
    \\  dot     rerun "zig build" and output a graphviz ".dot" file of build steps based on args
    \\  dotall  rerun "zig build" and output a graphviz ".dot" file of all build steps
    \\  zon     rerun "zig build" with a custom build runner and output the build graph as .zon to stdout
    \\  json    same as "zon" but output json
    \\  deppkg  more subcommands for creating and working with "deppkg.tar.gz" files storing all
    \\          dependencies required to build a zig package
    \\
    \\environment variables:
    \\
    \\  ZIG: path to the zig compiler to invoke in subprocesses. defaults to "zig".
    \\
    \\
;

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

const CommandMap = []const Command;
const Command = struct {
    []const u8,
    *const fn (GlobalOptions, []const []const u8) anyerror!void,
};

const commands = &.{
    .{ "dot", cmd_dot },
    .{ "dotall", cmd_dotall },
    .{ "deppkg", cmd_deppkg },
    .{ "zon", cmd_zon },
    .{ "json", cmd_json },
};

const deppkg_commands: CommandMap = &.{
    .{ "create", cmd_create },
    .{ "from-zon", cmd_from_zon },
    .{ "extract", cmd_extract },
    .{ "build", cmd_build },
    .{ "checkout", cmd_checkout },
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

pub fn cmd_deppkg(opt: GlobalOptions, args: []const []const u8) !void {
    const cmd_usage =
        \\usage: zigpkg deppkg <-h|--help|subcommand> [args]
        \\
        \\commands for packed build dependencies in .tar.gz files
        \\
        \\available subcommands:
        \\  create   <deppkg.tar.gz> {build root path}
        \\  from-zon <deppkg.tar.gz> {build root path}
        \\  extract  <deppkg.tar.gz> {build root output path}
        \\  build    <deppkg.tar.gz> <intall prefix> [zig build args] # WIP
        \\  checkout <empty directory for git deps> {build root path} # WIP
        \\
        \\
    ;
    if (args.len < 1) {
        try opt.stdout.writeAll(cmd_usage);
        return std.process.exit(1);
    }
    if (helpArg(args[0..1])) {
        try opt.stdout.writeAll(cmd_usage);
        return std.process.exit(0);
    }
    inline for (deppkg_commands) |cmd| {
        if (std.mem.eql(u8, args[0], cmd[0])) {
            return cmd[1](opt, args[1..]);
        }
    }

    try opt.stdout.writeAll(cmd_usage);
    try opt.stdout.writeAll("unknown command: ");
    try opt.stdout.writeAll(args[0]);
    try opt.stdout.writeAll("\n");
    return std.process.exit(1);
}

pub fn helpArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        inline for (&.{ "--help", "-h", "-?" }) |helparg| {
            if (std.ascii.eqlIgnoreCase(arg, helparg)) return true;
        }
    }
    return false;
}

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

    var cache_is_allocated = false;
    const cache = if (opt.env_map.get(
        "ZIG_GLOBAL_CACHE_DIR",
    )) |dir| dir else blk: {
        const cp = try known_folders.getPath(
            opt.gpa,
            .cache,
        ) orelse return error.CacheNotFound;
        defer opt.gpa.free(cp);
        cache_is_allocated = true;
        break :blk try std.fs.path.join(
            opt.gpa,
            &.{ cp, "zig" },
        );
    };
    defer if (cache_is_allocated) opt.gpa.free(cache);

    try pkg_targz.fromBuild(
        opt.gpa,
        serialized_b.parsed,
        cache,
        root,
        output,
    );
}

pub fn cmd_from_zon(opt: GlobalOptions, args: []const []const u8) !void {
    const root = args[0];

    const zon_src = try std.fs.cwd().readFileAllocOptions(
        opt.gpa,
        args[1],
        std.math.maxInt(u32),
        1048576,
        @alignOf(u8),
        0,
    );

    const output = try std.fs.path.resolve(
        opt.gpa,
        &.{ opt.cwd, args[2] },
    );
    defer opt.gpa.free(output);

    const parsed = try std.zon.parse.fromSlice(
        Serialize,
        opt.gpa,
        zon_src,
        null,
        .{},
    );
    defer std.zon.parse.free(opt.gpa, parsed);

    var cache_is_allocated = false;
    const cache = if (opt.env_map.get(
        "ZIG_GLOBAL_CACHE_DIR",
    )) |dir| dir else blk: {
        const cp = try known_folders.getPath(
            opt.gpa,
            .cache,
        ) orelse return error.CacheNotFound;
        defer opt.gpa.free(cp);
        cache_is_allocated = true;
        break :blk try std.fs.path.join(
            opt.gpa,
            &.{ cp, "zig" },
        );
    };
    defer if (cache_is_allocated) opt.gpa.free(cache);

    try pkg_targz.fromBuild(
        opt.gpa,
        parsed,
        cache,
        root,
        output,
    );
}

pub fn cmd_dot(opt: GlobalOptions, args: []const []const u8) !void {
    const cmd_usage =
        \\usage: zigpkg dot {--help|build_root_path|--} [zig args]
        \\
        \\rerun "zig build" and output a graphviz ".dot" file of all build steps
        \\
        \\
    ;
    var arg_sep: usize = 0;
    var root: []const u8 = ".";
    for (args) |arg| {
        if (helpArg(&.{arg})) {
            try opt.stdout.writeAll(cmd_usage);
            return std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--")) {
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

pub fn cmd_dotall(opt: GlobalOptions, args: []const []const u8) !void {
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
    try opt.stdout.writeAll(dot.DotFileWriter.header);
    for (serialized_b.parsed.steps.?, 0..) |step, step_id| {
        // const label = dot.buildRootEscaped(opt.zig_exe, build_root: []const u8, dep_root: []const u8, gpa: std.mem.Allocator)
        try opt.stdout.print(dot.DotFileWriter.node, .{
            step_id,
            step.name,
            dot.stepColor(step.id),
            step.owner orelse 42,
            "",
        });
        for (step.dependencies) |dep| {
            try opt.stdout.print(dot.DotFileWriter.edge, .{ step_id, dep });
        }
    }
    for (serialized_b.parsed.dependencies, 0..) |dep, dep_id| {
        try opt.stdout.print(dot.DotFileWriter.cluster_header, .{
            dep_id,
            dep.name,
        });
        for (serialized_b.parsed.steps.?, 0..) |step, step_id| {
            if (step.owner != null and step.owner.? == dep_id) {
                try opt.stdout.print(dot.DotFileWriter.cluster_node, .{
                    step_id,
                });
            }
        }
        try opt.stdout.writeAll(dot.DotFileWriter.cluster_footer);
    }
    try opt.stdout.writeAll(dot.DotFileWriter.footer);
}

pub fn cmd_json(opt: GlobalOptions, args: []const []const u8) !void {
    const b = try zonOutputCmd(opt, args);
    defer b.deinit(opt.gpa);

    try std.json.stringify(b.parsed, .{
        .emit_null_optional_fields = false,
    }, opt.stdout);
}

pub fn cmd_zon(opt: GlobalOptions, args: []const []const u8) !void {
    const b = try zonOutputCmd(opt, args);
    defer b.deinit(opt.gpa);

    try std.zon.stringify.serialize(b.parsed, .{
        .whitespace = true,
        .emit_default_optional_fields = false,
    }, opt.stdout);
    try opt.stdout.writeAll("\n");
}

pub fn zonOutputCmd(opt: GlobalOptions, args: []const []const u8) !SerializedZonType(Serialize) {
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

    return runZonStdoutCommand(
        opt,
        "runner-zon.zig",
        root,
        args[arg_sep..],
        Serialize,
    );
}

pub fn SerializedZonType(T: type) type {
    return struct {
        parsed: T,
        source: [:0]u8,
        pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
            gpa.free(self.source);
            std.zon.parse.free(gpa, self.parsed);
        }
    };
}

pub fn runZonStdoutCommand(opt: GlobalOptions, runner: []const u8, root: []const u8, args: []const []const u8, T: type) !SerializedZonType(T) {
    var buildrunner: BuildRunnerTmp.Embedded = try .init(opt.gpa, runner);
    defer buildrunner.deinit(opt.gpa);

    var argv = std.ArrayList([]const u8).init(opt.gpa);
    defer argv.deinit();
    try argv.appendSlice(&.{
        opt.zig_exe, "build", "--build-runner", buildrunner.runner,
    });
    try argv.appendSlice(args);

    const term = std.process.Child.run(.{
        .argv = argv.items,
        .allocator = opt.gpa,
        .cwd = root,
        .env_map = &opt.env_map,
        .expand_arg0 = .expand,
    }) catch |err| {
        std.log.err("Subprocess error: {}\nArgv: {}", .{ err, std.json.fmt(argv.items, .{ .whitespace = .minified }) });
        switch (err) {
            error.FileNotFound => {
                std.log.err("Executable not found: {s}", .{argv.items[0]});
            },
            else => {},
        }
        return err;
    };
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
    errdefer opt.gpa.free(my_src);

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

    const term = proc.spawnAndWait() catch |err| {
        std.log.err("Subprocess error: {}\nArgv: {}", .{ err, std.json.fmt(argv.items, .{ .whitespace = .minified }) });
        switch (err) {
            error.FileNotFound => {
                std.log.err("Executable not found: {s}", .{argv.items[0]});
            },
            else => {},
        }
        return err;
    };
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
