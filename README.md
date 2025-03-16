# Zig Package tool


## Usage

```
zig build
./zig-out/bin/zigpkg --help
# or:
zig build zigpkg -- --help
```

## Graphviz dependency graph

```
./zig-out/bin/zigpkg dot . install | dot -x -Gbgcolor=transparent -Tsvg > graph.svg
```

![Build Graph](graph.svg)
