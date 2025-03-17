# Zig Package tool

a command line tool to work with `build.zig` dependencies and build graphs.

It embeds custom build runners to retrieve build graph information,
used to backup dependencies, output a graphviz `dot` file etc.

## Usage

```
> zig build
> ./zig-out/bin/zigpkg --help
# or:
> zig build zigpkg -- --help
usage: zigpkg <subcommand> [--help]

stores all dependencies of a directory containing build.zig.zon in a .tar.gz archive

available subcommands:
  dot      <build root path> [--] [zig build args]
  create   <deppkg.tar.gz> {build root path}
  extract  <deppkg.tar.gz> {build root output path}
  build    <deppkg.tar.gz> <intall prefix> [zig build args] # WIP
  checkout <empty directory for git deps> {build root path} # WIP

environment variables:

  ZIG: path to the zig compiler to invoke in subprocesses. defaults to "zig".
```

## Graphviz dependency graph

this executes `zig build` with a custom build runner (including potiential additional arguments),
to convert the `Build.Step` graph to basic graphviz `dot` code.
that can be easily be converted to the svg form.
For now, generated dot strings are not escaped and might break.

```bash
# cli
./zig-out/bin/zigpkg dot . install | dot -Tsvg > graph.svg
```

![Build Graph](graph.svg)

```zig
// build.zig usage
// - the disadvantage here is, `dotGraphStep` basically reruns `zig build`,
//   and passes the extra arguments down, but does not know about the original arguments.
// - svgGraph is a system "dot" command
const zig_pkg_tool = @import("pkg_tool");
const svggraph = zig_pkg_tool.svgGraph(b, zig_pkg_tool.dotGraphStep(b, &.{
    "install", // extra args zig build, e.g. targets
    "dot",
    "test",
    "run",
}).captureStdOut());
b.step("dot", "install graph.svg").dependOn(&b.addInstallFile(
    svggraph,
    "graph.svg",
).step);
```
