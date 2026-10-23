const std = @import("std");
const print = std.log.info;
const pkg_extractor = @import("pkg-extractor.zig");
const pkg_targz = @import("pkg-targz.zig");
const known_folders = @import("known-folders");
pub const Manifest = @import("Manifest.zig");
const viz_network = @import("viz_network.html.zig").viz_network;

const usage =
    \\usage: zigpkg <subcommand> [--help]
    \\
    \\a multicall tool to work with zig's build graphs
    \\
    \\available subcommands:
    \\  dot     rerun "zig build" and output a graphviz ".dot" file of build steps based on args
    \\  dotall  rerun "zig build" and output a graphviz ".dot" file of all build steps
    \\  dothtml "dotall", but output html for vis.js instead of ".dot"
    \\  zon     rerun "zig build" and output the build graph as .zon to stdout
    \\  json    same as "zon" but output json
    \\  deppkg  more subcommands for creating and working with "deppkg.tar.gz" files.
    \\          stores all dependencies of a directory containing build.zig.zon in a .tar.gz archive
    \\
    \\environment variables:
    \\
    \\  ZIG: path to the zig compiler to invoke in subprocesses.
    \\       defaults to "zig" in the PATH.
    \\
;

pub const StepTag = enum(u32) {
    check_file,
    compile,
    config_header,
    fail,
    find_program,
    fmt,
    install_artifact,
    install_dir,
    install_file,
    obj_copy,
    options,
    run,
    top_level,
    translate_c,
    update_source_files,
    write_file,
    _,
};

pub const Step = struct {
    name: []const u8,
    owner: std.zig.Zoir.Node.Index,
    deps: []const u32 = &.{},
    extended: struct {
        flags: struct {
            tag: StepTag = .top_level,
        } = .{},
    } = .{},
};

pub const ScannedConfig = struct {
    default_step: u32 = 0,
    top_level_steps: std.zig.Zoir.Node.Index = .root,
    steps: []const Step = &.{},
};

pub const ParsedConfig = struct {
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,
    arena: std.heap.ArenaAllocator,
    config: ScannedConfig,
    source: [:0]u8,

    pub fn deinit(self: *ParsedConfig, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        self.zoir.deinit(gpa);
        self.ast.deinit(gpa);
        gpa.free(self.source);
    }

    pub fn getOwnerId(self: *const ParsedConfig, owner_node: std.zig.Zoir.Node.Index) ?u32 {
        return switch (owner_node.get(&self.zoir)) {
            .enum_literal => null,
            .int_literal => |il| switch (il) {
                .small => |v| @as(u32, @intCast(v)),
                .big => |big| big.toInt(u32) catch null,
            },
            else => null,
        };
    }

    pub fn getTopLevelStepIndex(self: *const ParsedConfig, target: []const u8) ?u32 {
        const node = self.config.top_level_steps.get(&self.zoir);
        switch (node) {
            .struct_literal => |s| {
                for (s.names, 0..) |nts, i| {
                    const name = nts.get(&self.zoir);
                    if (std.mem.eql(u8, name, target)) {
                        const val_idx = s.vals.at(@intCast(i));
                        return switch (val_idx.get(&self.zoir)) {
                            .int_literal => |il| switch (il) {
                                .small => |v| @as(u32, @intCast(v)),
                                .big => |big| big.toInt(u32) catch null,
                            },
                            else => null,
                        };
                    }
                }
            },
            else => {},
        }
        return null;
    }
};

pub fn parseConfig(gpa: std.mem.Allocator, source: [:0]u8) !ParsedConfig {
    var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
    errdefer ast.deinit(gpa);

    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
    errdefer zoir.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var diags: std.zon.parse.Diagnostics = undefined;
    const config = try std.zon.parse.fromZoir(ScannedConfig, .{
        .arena = arena.allocator(),
        .ast = &ast,
        .zoir = &zoir,
        .diagnostics = &diags,
        .ignore_unknown_fields = true,
    });

    return .{
        .ast = ast,
        .zoir = zoir,
        .arena = arena,
        .config = config,
        .source = source,
    };
}

pub const DotFileWriter = struct {
    pub const header = "digraph {\n";
    pub const node = "\"N{d}\" [label=\"{s}\", style=\"filled\", fillcolor=\"{s}\", group=\"G{d}\", tooltip=\"{s}\"]\n";
    pub const edge = "\"N{d}\" -> \"N{d}\"\n";
    pub const cluster_header = "subgraph cluster_{d} {{\n  cluster = true\n  label = \"{s}\"\n";
    pub const cluster_node = "  \"N{d}\"\n";
    pub const cluster_footer = "}\n";
    pub const footer = "}\n";
};

pub fn stepTagColor(tag: StepTag) []const u8 {
    return switch (tag) {
        .compile => "#6495ed",
        .install_artifact => "#309430",
        .install_dir => "#8b4513",
        .install_file => "#8f6f6f",
        .run => "#bdb76b",
        .write_file => "#3333aa",
        .update_source_files => "#ff44ff",
        .check_file => "#b03060",
        .config_header => "#ff4500",
        .fail => "#ffa500",
        .fmt => "#ffff00",
        .obj_copy => "#7fff00",
        .options => "#00ffff",
        .translate_c => "#00fa9a",
        .top_level => "#ffffff",
        .find_program => "#aaaaaa",
        else => "#aaaaaa",
    };
}

const GlobalOptions = struct {
    init: std.process.Init,
    self_exe: []const u8,
    cwd: std.Io.Dir,
    debug_level: u8 = 0,
    zig_exe: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const CommandMap = []const Command;
const Command = struct {
    []const u8,
    *const fn (GlobalOptions, []const []const u8) anyerror!u8,
};

const commands: CommandMap = &.{
    .{ "dot", cmd_dot },
    .{ "dotall", cmd_dotall },
    .{ "dothtml", cmd_dothtml },
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const env_map = init.environ_map;

    var stdout_buf: [128]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    var stderr_buf: [128]u8 = undefined;
    var stderr_file = std.Io.File.stdout().writer(io, &stderr_buf);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};

    if (args.len < 2) {
        try stdout.writeAll(usage);
        try stdout.flush();
        try stderr.flush();
        return std.process.exit(1);
    }

    if (helpArg(args[1..2])) {
        try stdout.writeAll(usage);
        return;
    }

    var opt: GlobalOptions = .{
        .init = init,
        .self_exe = args[0],
        .cwd = std.Io.Dir.cwd(),
        .zig_exe = env_map.get("ZIG") orelse "zig",
        .stdout = stdout,
        .stderr = stderr,
    };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) opt.debug_level += 1;
        if (std.mem.eql(u8, arg, "-d")) opt.debug_level += 1;
    }

    inline for (commands) |cmd| {
        if (std.mem.eql(u8, args[1], cmd[0])) {
            const res = try cmd[1](opt, args[2..]);
            if (res == 0) return;
            try stdout.flush();
            try stderr.flush();
            std.process.exit(res);
        }
    }

    try stdout.writeAll(usage);
    try stdout.writeAll("unknown command: ");
    try stdout.writeAll(args[1]);
    try stdout.writeAll("\n");
    try stdout.flush();
    try stderr.flush();
    return std.process.exit(1);
}

pub fn cmd_deppkg(opt: GlobalOptions, args: []const []const u8) !u8 {
    const cmd_usage =
        \\usage: zigpkg deppkg <-h|--help|subcommand> [args]
        \\
        \\commands for packed build dependencies in .tar.gz files
        \\
        \\available subcommands:
        \\  create   <deppkg.tar.gz> {build root path}
        \\  from-zon <deppkg.tar.gz> <build root path> <zon file>
        \\  extract  <deppkg.tar.gz> {build root output path}
        \\  build    <deppkg.tar.gz> <intall prefix> [zig build args] # WIP
        \\  checkout <empty directory for git deps> {build root path} # WIP
        \\
    ;
    if (args.len < 1) {
        try opt.stdout.writeAll(cmd_usage);
        return 1;
    }
    if (helpArg(args[0..1])) {
        try opt.stdout.writeAll(cmd_usage);
        return 0;
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
    return 1;
}

pub fn helpArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        inline for (&.{ "--help", "-h", "-?", "--usage", "help", "-help" }) |helparg| {
            if (std.ascii.eqlIgnoreCase(arg, helparg)) return true;
        }
    }
    return false;
}

pub fn cmd_extract(opt: GlobalOptions, args: []const []const u8) !u8 {
    const cmd_usage =
        \\usage: zigpkg extract <deppkg.tar.gz> <output_root>
        \\
    ;
    if (args.len != 1 and args.len != 2) {
        try opt.stdout.writeAll(cmd_usage);
        return 1;
    }
    if (helpArg(args[0..args.len])) {
        try opt.stdout.writeAll(cmd_usage);
        return 0;
    }
    try pkg_extractor.process(.{
        .io = opt.init.io,
        .gpa = opt.init.gpa,
        .env = opt.init.environ_map.*,
        .zig_exe = opt.zig_exe,
        .filepath = args[0],
        .root_out_dir = if (args.len == 1) null else args[1],
    });
    return 0;
}

pub fn cmd_create(opt: GlobalOptions, args: []const []const u8) !u8 {
    const cmd_usage =
        \\usage: zigpkg create <deppkg.tar.gz> [<build root path>] [-- [zig args]]
        \\
    ;
    if (args.len < 1) {
        try opt.stdout.writeAll(cmd_usage);
        return 1;
    }

    if (helpArg(args[0..@min(1, args.len)])) {
        try opt.stdout.writeAll(cmd_usage);
        return 1;
    }

    const output = args[0];
    const root = if (args.len > 1 and !std.mem.eql(u8, args[1], "--")) args[1] else ".";
    const arg_sep: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "--")) 2 else 1;

    const zon_src = try runPrintConfiguration(opt, root, args[arg_sep..]);
    defer opt.init.gpa.free(zon_src);

    var cache_is_allocated = false;
    const cache = if (opt.init.environ_map.get(
        "ZIG_GLOBAL_CACHE_DIR",
    )) |dir| dir else blk: {
        const cp = try known_folders.getPath(
            opt.init.io,
            opt.init.gpa,
            opt.init.environ_map,
            .cache,
        ) orelse return error.CacheNotFound;
        defer opt.init.gpa.free(cp);
        cache_is_allocated = true;
        break :blk try std.fs.path.join(
            opt.init.gpa,
            &.{ cp, "zig" },
        );
    };
    defer if (cache_is_allocated) opt.init.gpa.free(cache);

    try pkg_targz.fromBuild(
        opt.init.io,
        opt.init.gpa,
        zon_src,
        cache,
        root,
        output,
    );
    return 0;
}

pub fn cmd_from_zon(opt: GlobalOptions, args: []const []const u8) !u8 {
    if (args.len < 3) {
        try opt.stdout.writeAll("usage: zigpkg deppkg from-zon <output.tar.gz> <build_root> <zon_file>\n");
        return 1;
    }
    const output = args[0];
    const root = args[1];

    const gpa = opt.init.gpa;
    const zon_src = try Manifest.cwdReadFileAllocZ(
        args[2],
        gpa,
        std.math.maxInt(u32),
    );
    defer gpa.free(zon_src);

    var cache_is_allocated = false;
    const cache = if (opt.init.environ_map.get(
        "ZIG_GLOBAL_CACHE_DIR",
    )) |dir| dir else blk: {
        const cp = try known_folders.getPath(
            opt.init.io,
            gpa,
            opt.init.environ_map,
            .cache,
        ) orelse return error.CacheNotFound;
        defer gpa.free(cp);
        cache_is_allocated = true;
        break :blk try std.fs.path.join(
            gpa,
            &.{ cp, "zig" },
        );
    };
    defer if (cache_is_allocated) gpa.free(cache);

    try pkg_targz.fromBuild(
        opt.init.io,
        gpa,
        zon_src,
        cache,
        root,
        output,
    );
    return 0;
}

pub fn cmd_dot(opt: GlobalOptions, args: []const []const u8) !u8 {
    const cmd_usage =
        \\usage: zigpkg dot [<build_root_path>] [-- [targets...]]
        \\
        \\rerun "zig build" and output a graphviz ".dot" file of build steps based on args
        \\
    ;
    var arg_sep: usize = 0;
    var root: []const u8 = ".";
    for (args) |arg| {
        if (helpArg(&.{arg})) {
            try opt.stdout.writeAll(cmd_usage);
            return 0;
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

    const zon_src = try runPrintConfiguration(opt, root, args[arg_sep..]);
    var parsed = try parseConfig(opt.init.gpa, zon_src);
    defer parsed.deinit(opt.init.gpa);

    try writeDotFiltered(opt, &parsed, args[arg_sep..]);
    return 0;
}

pub fn cmd_dotall(opt: GlobalOptions, args: []const []const u8) !u8 {
    const cmd_usage =
        \\usage: zigpkg dotall [<build_root_path>] [-- [zig args]]
        \\
        \\rerun "zig build" and output a graphviz ".dot" file of all build steps
        \\
    ;
    var arg_sep: usize = 0;
    var root: []const u8 = ".";
    for (args) |arg| {
        if (helpArg(&.{arg})) {
            try opt.stdout.writeAll(cmd_usage);
            return 0;
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

    const zon_src = try runPrintConfiguration(opt, root, args[arg_sep..]);
    var parsed = try parseConfig(opt.init.gpa, zon_src);
    defer parsed.deinit(opt.init.gpa);

    try writeDotAll(opt, &parsed);
    return 0;
}

fn writeDotFiltered(
    opt: GlobalOptions,
    parsed: *const ParsedConfig,
    targets: []const []const u8,
) !void {
    const gpa = opt.init.gpa;
    const num_steps = parsed.config.steps.len;
    var reachable = try gpa.alloc(bool, num_steps);
    defer gpa.free(reachable);
    @memset(reachable, false);

    var queue = std.ArrayList(u32).empty;
    defer queue.deinit(gpa);

    if (targets.len == 0) {
        if (parsed.config.default_step < num_steps) {
            try queue.append(gpa, parsed.config.default_step);
            reachable[parsed.config.default_step] = true;
        }
    } else {
        for (targets) |target| {
            if (parsed.getTopLevelStepIndex(target)) |idx| {
                if (idx < num_steps and !reachable[idx]) {
                    reachable[idx] = true;
                    try queue.append(gpa, idx);
                }
            }
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const curr = queue.items[head];
        if (curr >= num_steps) continue;
        for (parsed.config.steps[curr].deps) |dep| {
            if (dep < num_steps and !reachable[dep]) {
                reachable[dep] = true;
                try queue.append(gpa, dep);
            }
        }
    }

    try opt.stdout.writeAll(DotFileWriter.header);
    for (parsed.config.steps, 0..) |step, step_id| {
        if (!reachable[step_id]) continue;
        const owner_id = parsed.getOwnerId(step.owner) orelse 0;
        try opt.stdout.print(DotFileWriter.node, .{
            step_id,
            step.name,
            stepTagColor(step.extended.flags.tag),
            owner_id,
            "",
        });
        for (step.deps) |dep| {
            if (dep < num_steps and reachable[dep]) {
                try opt.stdout.print(DotFileWriter.edge, .{ step_id, dep });
            }
        }
    }

    var owners: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer owners.deinit(gpa);
    for (parsed.config.steps, 0..) |step, step_id| {
        if (!reachable[step_id]) continue;
        const oid = parsed.getOwnerId(step.owner) orelse 0;
        try owners.put(gpa, oid, {});
    }

    for (owners.keys()) |owner_id| {
        const label = if (owner_id == 0) "root" else "dep";
        try opt.stdout.print(DotFileWriter.cluster_header, .{
            owner_id,
            label,
        });
        for (parsed.config.steps, 0..) |step, step_id| {
            if (!reachable[step_id]) continue;
            const oid = parsed.getOwnerId(step.owner) orelse 0;
            if (oid == owner_id) {
                try opt.stdout.print(DotFileWriter.cluster_node, .{step_id});
            }
        }
        try opt.stdout.writeAll(DotFileWriter.cluster_footer);
    }
    try opt.stdout.writeAll(DotFileWriter.footer);
}

fn writeDotAll(
    opt: GlobalOptions,
    parsed: *const ParsedConfig,
) !void {
    const gpa = opt.init.gpa;
    const num_steps = parsed.config.steps.len;

    try opt.stdout.writeAll(DotFileWriter.header);
    for (parsed.config.steps, 0..) |step, step_id| {
        const owner_id = parsed.getOwnerId(step.owner) orelse 0;
        try opt.stdout.print(DotFileWriter.node, .{
            step_id,
            step.name,
            stepTagColor(step.extended.flags.tag),
            owner_id,
            "",
        });
        for (step.deps) |dep| {
            if (dep < num_steps) {
                try opt.stdout.print(DotFileWriter.edge, .{ step_id, dep });
            }
        }
    }

    var owners: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer owners.deinit(gpa);
    for (parsed.config.steps) |step| {
        const oid = parsed.getOwnerId(step.owner) orelse 0;
        try owners.put(gpa, oid, {});
    }

    for (owners.keys()) |owner_id| {
        const label = if (owner_id == 0) "root" else "dep";
        try opt.stdout.print(DotFileWriter.cluster_header, .{
            owner_id,
            label,
        });
        for (parsed.config.steps, 0..) |step, step_id| {
            const oid = parsed.getOwnerId(step.owner) orelse 0;
            if (oid == owner_id) {
                try opt.stdout.print(DotFileWriter.cluster_node, .{step_id});
            }
        }
        try opt.stdout.writeAll(DotFileWriter.cluster_footer);
    }
    try opt.stdout.writeAll(DotFileWriter.footer);
}

pub fn cmd_dothtml(opt: GlobalOptions, args: []const []const u8) !u8 {
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
    const zon_src = try runPrintConfiguration(opt, root, args[arg_sep..]);
    var parsed = try parseConfig(opt.init.gpa, zon_src);
    defer parsed.deinit(opt.init.gpa);

    const gpa = opt.init.gpa;
    const JsonStep = struct {
        name: []const u8,
        owner: ?u32,
        dependencies: []const u32,
        tag: []const u8,
    };
    const JsonConfig = struct {
        default_step: u32,
        steps: []const JsonStep,
    };

    var steps = try gpa.alloc(JsonStep, parsed.config.steps.len);
    defer gpa.free(steps);
    for (parsed.config.steps, 0..) |step, i| {
        steps[i] = .{
            .name = step.name,
            .owner = parsed.getOwnerId(step.owner),
            .dependencies = step.deps,
            .tag = @tagName(step.extended.flags.tag),
        };
    }

    const json_cfg: JsonConfig = .{
        .default_step = parsed.config.default_step,
        .steps = steps,
    };

    try viz_network.render(json_cfg, opt.stdout);
    return 0;
}

pub fn cmd_json(opt: GlobalOptions, args: []const []const u8) !u8 {
    if (helpArg(args[0..@min(1, args.len)])) {
        try opt.stdout.writeAll(
            \\usage: zigpkg json [<build root path>] [-- [arguments to zig build]]
            \\
            \\output the build graph as .json to stdout
            \\
        );
        return 0;
    }
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
    const zon_src = try runPrintConfiguration(opt, root, args[arg_sep..]);
    var parsed = try parseConfig(opt.init.gpa, zon_src);
    defer parsed.deinit(opt.init.gpa);

    const gpa = opt.init.gpa;
    const JsonStep = struct {
        name: []const u8,
        owner: ?u32,
        dependencies: []const u32,
        tag: []const u8,
    };
    const JsonConfig = struct {
        default_step: u32,
        steps: []const JsonStep,
    };

    var steps = try gpa.alloc(JsonStep, parsed.config.steps.len);
    defer gpa.free(steps);
    for (parsed.config.steps, 0..) |step, i| {
        steps[i] = .{
            .name = step.name,
            .owner = parsed.getOwnerId(step.owner),
            .dependencies = step.deps,
            .tag = @tagName(step.extended.flags.tag),
        };
    }

    const json_cfg: JsonConfig = .{
        .default_step = parsed.config.default_step,
        .steps = steps,
    };

    try opt.stdout.print("{f}\n", .{
        std.json.fmt(json_cfg, .{}),
    });
    return 0;
}

pub fn cmd_zon(opt: GlobalOptions, args: []const []const u8) !u8 {
    if (helpArg(args[0..@min(1, args.len)])) {
        try opt.stdout.writeAll(
            \\usage: zigpkg zon [<build root path>] [-- [arguments to zig build]]
            \\
            \\output the build graph as .zon to stdout
            \\
        );
        return 0;
    }
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

    const zon_src = try runPrintConfiguration(opt, root, args[arg_sep..]);
    defer opt.init.gpa.free(zon_src);

    try opt.stdout.writeAll(zon_src);
    if (!std.mem.endsWith(u8, zon_src, "\n")) {
        try opt.stdout.writeAll("\n");
    }
    return 0;
}

pub fn runPrintConfiguration(
    opt: GlobalOptions,
    root: []const u8,
    args: []const []const u8,
) ![:0]u8 {
    const gpa = opt.init.gpa;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        opt.zig_exe, "build", "--print-configuration",
    });
    try argv.appendSlice(gpa, args);

    const term = std.process.run(gpa, opt.init.io, .{
        .argv = argv.items,
        .cwd = .{ .path = root },
        .environ_map = opt.init.environ_map,
        .expand_arg0 = .expand,
    }) catch |err| {
        std.log.err("Subprocess error: {}\nArgv: {f}", .{
            err,
            std.json.fmt(argv.items, .{ .whitespace = .minified }),
        });
        return err;
    };
    defer gpa.free(term.stderr);
    if (term.stderr.len > 0) {
        try opt.stderr.writeAll(term.stderr);
    }

    switch (term.term) {
        .exited => |ex| {
            if (ex != 0) {
                gpa.free(term.stdout);
                try opt.stderr.print("subprocess exitcode: {d}\n", .{ex});
                return error.ExitCode;
            }
        },
        else => {
            gpa.free(term.stdout);
            try opt.stderr.print("Term: {}\n", .{term.term});
            return error.Term;
        },
    }

    const my_src = try gpa.dupeSentinel(u8, term.stdout, 0);
    gpa.free(term.stdout);
    return my_src;
}

pub fn cmd_build(opt: GlobalOptions, args: []const []const u8) !u8 {
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

pub fn cmd_checkout(opt: GlobalOptions, args: []const []const u8) !u8 {
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

comptime {
    std.testing.refAllDecls(pkg_extractor);
    std.testing.refAllDecls(pkg_targz);
}
