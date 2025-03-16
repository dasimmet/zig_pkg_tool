# Zig Package tool


## Usage

```
zig build
./zig-out/bin/zigpkg --help
# or:
zig build zigpkg -- --help
```

## Graphviz dependency graph

this executes `zig build` with a custom build runner (including potiential additional arguments),
to convert the `Build.Step` graph to basic graphviz `dot` code.
that can be easily be converted to the svg form.
For now, generated dot strings are not escaped and might break.

```
./zig-out/bin/zigpkg dot . install | dot -Tsvg > graph.svg
```

![Build Graph](graph.svg)
