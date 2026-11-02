# aho-corasick

Aho-Corasick multi-pattern search in Zig, with the automaton built at comptime.

This project is incubating. It is unstable, its API will change, and it is not
ready to depend on.

Aho-Corasick finds every occurrence of a set of patterns in one pass over the
haystack. The first version of this lived in `moomd`, where a fixed list of
Postgres process states had to be classified from a log line. That one
returned a boolean and stopped at the first match.

This is the general version. There are two forms. `Matcher` takes the patterns
and the match semantics as comptime values: the compiler builds the trie, the
failure links, and the output links, and the result is read-only data.
`Automaton` builds the same tables at runtime from a pattern list and an
allocator. Both share one searcher, so a `Match` is a pattern id and a byte
range, and three match kinds say which of several matches wins. The API
follows the Rust [`aho-corasick`](https://docs.rs/aho-corasick) crate.

```zig
const ac = @import("aho-corasick");

const Keywords = ac.Matcher(&.{ "she", "he", "hers" }, .{});

var it = Keywords.findOverlappingIter("ushers");
while (it.next()) |m| {
    // "she" at 1..4, "he" at 2..4, "hers" at 2..6
}
```

The compiler pays for the comptime automaton once. Measured with Zig 0.16 on
aarch64-linux, above a one-pattern baseline: 100 patterns take about 0.2 s to
compile, 1,000 take about 4 s, and 5,000 take about 80 s. The cost grows faster
than the pattern count because Zig's comptime evaluator copies an array on
every element access. Static dictionaries in the hundreds are the sweet spot.

The runtime form pays none of that at compile time:

```zig
var automaton = try ac.Automaton.init(gpa, &.{ "she", "he", "hers" }, .{});
defer automaton.deinit();
const m = automaton.find("ushers").?;
```

## What is in it

- `Matcher`: builds an automaton from a comptime pattern list and options.
  Every pattern gets the id of its position in that list.
- `Automaton`: builds the same automaton at runtime from a pattern list and an
  allocator. It copies the patterns, owns its tables, and frees them in
  `deinit`.
- `find`, `findIter`, `findOverlappingIter`, `isMatch`, `whichMatches`: the
  search surface. `Match` carries the pattern id and the byte range.
- `MatchKind`: `.standard` reports the earliest end and is the only kind that
  supports overlapping search. `.leftmost_first` and `.leftmost_longest`
  report the earliest start, breaking ties by pattern order or by length.
- `replaceAll`: writes the haystack with a replacement per pattern to any
  `std.Io.Writer`.
- `nextState`, `isMatchState`, `firstMatch`: the raw state machine, for a
  caller that scans in chunks and keeps the state itself.
- `ascii_case_insensitive`: folds ASCII letters in the byte classes, so a
  case-insensitive automaton keeps the same shape.

Not implemented:

- A terminal UI. `just viz` prints stats, the trie, Graphviz DOT, and a match
  walk; there is no interactive view yet.
- Unicode case folding. `ascii_case_insensitive` folds ASCII letters only.
- Empty patterns and duplicate patterns, including duplicates after folding,
  are compile errors.

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

`aho-corasick` builds with Zig 0.16 and 0.17.

## Documentation

- The doc comments in `src/root.zig` and `src/Matcher.zig` state the contract
  until the guide and the API reference are published.
- `test/fuzz.zig` checks every match kind against a naive scan over generated
  haystacks.

## Work on it

```sh
nix develop            # Zig 0.17 and the tools
nix develop .#zig-old  # Zig 0.16
just ci                # the full gate: Debug, ReleaseSafe, ReleaseFast, then lint
just check             # the test matrix alone, for the compatibility shell
just viz tools/patterns.txt                 # the trie, with failure links and outputs
just viz tools/patterns.txt -f stats        # pattern, state, and memory counts
just viz tools/patterns.txt -f walk -t ushers  # one state per byte, with matches
just viz-svg tools/patterns.txt             # DOT through Graphviz, if `dot` is on PATH
```

## License

MIT. See `LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
