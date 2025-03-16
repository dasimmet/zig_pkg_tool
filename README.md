# Zig Package tool


## Usage

```
zig build zigpkg -- --help
```

## Graphviz dependency graph

```
zig build zigpkg -- dot | dot -x -Gbgcolor=transparent -Tsvg > graph.svg
```

![Build Graph](graph.svg)
