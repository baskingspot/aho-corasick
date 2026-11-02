<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="aho-corasick" height="48">
  </picture>
</h1>

Aho-Corasick multi-pattern search in Zig, with the automaton built at comptime.

Aho-Corasick finds every occurrence of a set of patterns in one pass over the
haystack. The first version of this lived in `moomd`, where a fixed list of
Postgres process states had to be classified from a log line. That one
returned a boolean and stopped at the first match.

This is the general version. `Matcher` puts the patterns in the type and builds
the trie, the failure links, and the output links while the type is analyzed,
so a search allocates nothing. `Automaton` builds the same tables at runtime
from a pattern list and an allocator. Both report a `Match` with a pattern id
and a byte range, and three match kinds say which of several matches wins.

```zig
const ac = @import("aho-corasick");

const Keywords = ac.Matcher(&.{ "she", "he", "hers" }, .{});

var it = Keywords.findOverlappingIter("ushers");
while (it.next()) |m| {
    // "she" at 1..4, "he" at 2..4, "hers" at 2..6
}
```

## What is in it

- [A matcher in the type](https://baskingspot.dev/aho-corasick/#a-matcher-in-the-type): `Matcher` builds the automaton from a comptime pattern list and options.
- [Matching](https://baskingspot.dev/aho-corasick/#matching): `find`, `findIter`, and `isMatch` return a `Match` with the pattern id and the byte range.
- [Match kinds](https://baskingspot.dev/aho-corasick/#match-kinds): `.standard`, `.leftmost_first`, and `.leftmost_longest` choose between competing matches.
- [Overlapping matches](https://baskingspot.dev/aho-corasick/#overlapping-matches): `findOverlappingIter` reports every match, including the nested ones.
- [Replace](https://baskingspot.dev/aho-corasick/#replace): `replaceAll` writes the haystack to any writer with one replacement per pattern.
- [The runtime automaton](https://baskingspot.dev/aho-corasick/#the-runtime-automaton): `Automaton` builds the same tables from a pattern list at runtime.
- [Case folding](https://baskingspot.dev/aho-corasick/#case-folding): `ascii_case_insensitive` folds ASCII letters as byte classes, not extra trie branches.
- [Inspect an automaton](https://baskingspot.dev/aho-corasick/#inspect-an-automaton): `just viz` prints the trie, a walk, and a libvaxis view.
- [Design](https://baskingspot.dev/aho-corasick/#design): the compact tables, the failure and output links, and the one searcher both forms share.
- [Performance](https://baskingspot.dev/aho-corasick/#performance): what the comptime build costs, and the memory the runtime automaton uses.

Not implemented:

- Unicode case folding. `ascii_case_insensitive` folds ASCII letters only.
- `Input` spans and anchored search. A search takes the whole `[]const u8`.
- A streaming iterator that carries state across chunks. The raw state machine is exposed.
- A prefilter or a full-DFA mode. A transition miss walks the failure links.
- A two-dimensional graph. The TUI shows the trie as an indented list.

## Install

Before the first tag:

```sh
zig fetch --save git+https://github.com/baskingspot/aho-corasick
```

Add the module to your build:

```zig
const aho_corasick = b.dependency("aho_corasick", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("aho-corasick", aho_corasick.module("aho-corasick"));
```

Then import it:

```zig
const ac = @import("aho-corasick");
```

`aho-corasick` builds with Zig 0.16 and 0.17. The `acviz` tool in `tools/` is a
separate 0.17 package, because libvaxis requires 0.17.

## Documentation

- The [guide](https://baskingspot.dev/aho-corasick/) has the recipes, and every example compiles.
- The [API reference](https://baskingspot.dev/aho-corasick/api/) documents every symbol.
- [`examples/`](examples/README.md) has a complete scanner over the runtime automaton.
- [`bench/README.md`](bench/README.md) has the dictionary, the haystacks, and the local baseline.
- [`THIRD_PARTY.md`](THIRD_PARTY.md) records the Rust crate the API follows and the `moomd` code this grew from.

## Work on it

```sh
nix develop            # Zig 0.17 and the tools
nix develop .#zig-old  # Zig 0.16
just ci                # the full gate: tests, lint, and the docs build
just check             # the test matrix and the examples, for the compatibility shell
just viz tools/patterns.txt -f tui -t ushers  # browse the automaton
just examples          # build the scanner in examples/
just bench             # local benchmark suite; see bench/README.md
```

`just` lists every recipe.

## License

MIT. See `LICENSE`. The Rust API and the `moomd` origin are recorded in
[`THIRD_PARTY.md`](THIRD_PARTY.md). The logo files in `docs/static/` are
baskingspot marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
