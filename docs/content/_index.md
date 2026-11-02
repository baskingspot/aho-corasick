+++
title = "aho-corasick"
+++

Aho-Corasick multi-pattern search in Zig, with the automaton built at comptime.

Aho-Corasick finds every occurrence of a set of patterns in one pass over the
haystack. The first version of this lived in `moomd`, where a fixed list of
Postgres process states had to be classified from a log line. That one
returned a boolean and stopped at the first match. This is the general version.
`Matcher` puts the patterns in the type and builds the automaton at comptime,
so a search allocates nothing. `Automaton` builds the same tables at runtime
from a pattern list and an allocator, for dictionaries that are not known until
the program runs.

Both report a `Match`: a pattern id and a byte range in the haystack. Three
match kinds say which of several matches wins, the same three the Rust
[`aho-corasick`](https://docs.rs/aho-corasick) crate defines.

- [A matcher in the type](#a-matcher-in-the-type): `Matcher` builds the trie, the failure links, and the output links while the type is analyzed.
- [Matching](#matching): `find`, `findIter`, and `isMatch` return a `Match` with the pattern id and the byte range.
- [Match kinds](#match-kinds): `.standard`, `.leftmost_first`, and `.leftmost_longest` choose between competing matches.
- [Overlapping matches](#overlapping-matches): `findOverlappingIter` reports every match, including the ones nested inside another.
- [Replace](#replace): `replaceAll` writes the haystack to any writer with one replacement per pattern.
- [The runtime automaton](#the-runtime-automaton): `Automaton` builds the same tables from a pattern list at runtime.
- [Case folding](#case-folding): `ascii_case_insensitive` folds ASCII letters as byte classes, not extra trie branches.
- [Inspect an automaton](#inspect-an-automaton): `just viz` prints the stats, the trie, a walk, and a libvaxis view.
- [Design](#design): the compact tables, the failure and output links, and the one searcher both forms share.
- [Performance](#performance): what the comptime build costs, and the memory the runtime automaton uses.
- [Limits](#limits): what has no API, and what is a compile error.

This guide is the recipes. The [API reference](api/) has the contract for every
symbol.

# Getting started

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/aho-corasick
```

Add the module to your build in `build.zig`:

```zig
const aho_corasick = b.dependency("aho_corasick", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("aho-corasick", aho_corasick.module("aho-corasick"));
```

`aho-corasick` builds with Zig 0.16 and 0.17. The `acviz` tool in `tools/` is a
separate 0.17 package, because libvaxis requires 0.17.

## Import it

```zig
const ac = @import("aho-corasick");
```

`std` has no Aho-Corasick, so the name does not collide with a namespace. Bind
it as `ac` and keep the call sites short.

## Read the examples

Every example in this guide is a test in `docs/examples/root.zig`. The test step
compiles and runs them, so the code here builds:

```sh
just test
```

There is also a complete scanner in `examples/scan.zig`:

```sh
just examples
zig-out/bin/scan patterns.txt haystack.txt
```

# A matcher in the type

`Matcher` takes the pattern list and the options as comptime values and returns
a type. The trie, the failure links, the output links, and the byte classes are
built while that type is analyzed. The result is read-only data.

```zig
const ac = @import("aho-corasick");

const Keywords = ac.Matcher(&.{ "apple", "maple" }, .{});

const m = Keywords.find("a maple leaf").?;
// m.pattern == 1, m.start == 2, m.end == 7
```

Pattern `i` in the list is pattern id `i` in every `Match`. Keep the values you
care about in an array indexed by that id:

```zig
const levels = [_][]const u8{ "debug", "info", "warn", "error" };
const Levels = ac.Matcher(&.{ "[DEBUG]", "[INFO]", "[WARN]", "[ERROR]" }, .{});

const line = "[WARN] connection timeout";
if (Levels.find(line)) |m| {
    const level = levels[m.pattern];
    _ = level; // "warn"
}
```

The pattern list is checked while the type is analyzed. An empty pattern, an
empty list, and two patterns that are equal, including equal after ASCII case
folding, are compile errors.

The compiler pays for the table once. A few hundred patterns compile in well
under a second. The [Performance](#performance) chapter has the measured
numbers and the reason they grow faster than the pattern count.

Searching takes an `[]const u8` and allocates nothing. The same table is read
by every call, so a matcher can live at file scope or in a struct with no
initialization.

# Matching

A `Match` has three fields:

- `pattern`: the id of the pattern that matched.
- `start`: the byte offset where the match starts.
- `end`: the byte offset one past the last byte.

`find` returns the first match according to the [match kind](#match-kinds), or
`null`:

```zig
const m = Keywords.find("a maple leaf").?;
const text = "a maple leaf"[m.start..m.end]; // "maple"
```

`findIter` returns the non-overlapping matches in order:

```zig
var it = Keywords.findIter("maple, apple, maple");
while (it.next()) |m| {
    // pattern 1 at 0..5, pattern 0 at 7..12, pattern 1 at 14..19
}
```

`isMatch` answers whether any pattern occurs, without reporting which one:

```zig
if (Keywords.isMatch(response)) {
    // one of the patterns is in the response
}
```

An empty haystack and a haystack with no match both return `null`. The
iterators return `null` at the end. They never allocate and never retain a
pointer to the haystack after `next` returns.

# Match kinds

The kind is part of the matcher type. It decides which match wins when more
than one is a candidate. The three names and their meanings are the Rust
crate's.

| Kind                | Rule                                                                                                                             |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `.standard`         | Report the match that ends earliest. At one end offset, the longest pattern comes first, then the suffixes on the failure chain. |
| `.leftmost_first`   | Report the match that starts earliest. At one start offset, the pattern listed first wins.                                       |
| `.leftmost_longest` | Report the match that starts earliest. At one start offset, the longest pattern wins.                                            |

The difference is easiest to see with `append`, `appendage`, and `app` on the
same haystack:

```zig
const patterns = &.{ "append", "appendage", "app" };
const haystack = "append the app to the appendage";

const Standard = ac.Matcher(patterns, .{});
const First = ac.Matcher(patterns, .{ .match_kind = .leftmost_first });
const Longest = ac.Matcher(patterns, .{ .match_kind = .leftmost_longest });
```

`Standard.findIter` returns `app` at 0..3, 11..14, and 22..25. It stops at the
first ending match and resumes after it.

`First.findIter` returns `append` at 0..6, `app` at 11..14, and `append` at
22..28. At offset 0, `append` is listed before `appendage` and `app`. At offset
22, `append` is listed before `appendage`.

`Longest.findIter` returns `append` at 0..6, `app` at 11..14, and `appendage`
at 22..31. At offset 22, `appendage` is longer than `append`.

The leftmost kinds need lookahead. A match that starts at or before the best
candidate and has not finished would be a suffix of the bytes read so far. The
iterator stops as soon as the current state is shorter than that suffix.

Overlapping searches are only defined for `.standard`. Calling
`findOverlapping` or `findOverlappingIter` on a leftmost matcher is a compile
error.

# Overlapping matches

`findOverlappingIter` reports every match, including matches that start before
the previous one ended. Matches come in end-offset order. At one end offset the
longest match comes first, then the suffixes on the failure chain.

```zig
const Words = ac.Matcher(&.{ "she", "he", "hers" }, .{});

var it = Words.findOverlappingIter("ushers");
// "she" 1..4, "he" 2..4, "hers" 2..6
```

`whichMatches` answers which patterns occur at all. On the comptime matcher it
returns a static bitset, with one bit per pattern:

```zig
const set = Words.whichMatches("ushers");
// set.isSet(0) is true for "she"
// set.isSet(1) is true for "he"
// set.isSet(2) is true for "hers"
```

Use `isMatch` when any hit is enough. Use `whichMatches` when the caller needs
the set, and `findOverlappingIter` when it needs the positions.

# Replace

`replaceAll` writes the haystack to a writer and replaces each non-overlapping
match with the replacement at the same pattern index:

```zig
const Replace = ac.Matcher(&.{ "fox", "brown", "quick" }, .{});

var buffer: [64]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buffer);
try Replace.replaceAll(&writer, "The quick brown fox.", &.{ "sloth", "grey", "slow" });
// writer.buffered() is "The slow grey sloth."
```

The writer is any type with `writeAll`. The replacement list must have one
entry per pattern; a different length is a panic. The function uses the
matcher's match kind, so a leftmost matcher replaces the leftmost matches. It
does not allocate.

# The runtime automaton

`Automaton` builds the same tables at runtime. Use it when the patterns come
from a file, a network response, or a command line, or when the dictionary is
too large to compile.

```zig
var automaton = try ac.Automaton.init(gpa, &.{ "she", "he", "hers" }, .{});
defer automaton.deinit();

const m = automaton.find("ushers").?;
const she = automaton.pattern(m.pattern);
```

`init` copies the pattern bytes into the automaton. The caller can free its own
copy after `init` returns. `deinit` frees the tables and the copy; call it once.
The automaton is not copyable.

Its methods mirror the comptime ones: `find`, `findIter`,
`findOverlappingIter`, `isMatch`, `replaceAll`, `nextState`, `firstMatch`, and
the inspection methods. The match kind is a runtime field, so an overlapping
search on a leftmost automaton panics rather than failing to compile.

`init` returns an error for the cases the comptime matcher rejects at compile
time:

- `error.NoPatterns`
- `error.EmptyPattern`
- `error.DuplicatePattern`
- `error.PatternTooLong`
- `error.TooManyPatterns`
- `error.OutOfMemory`

`whichMatches` takes an allocator on the runtime automaton, because the pattern
count is not part of the type:

```zig
var set = try automaton.whichMatches(gpa, "ushers");
defer set.deinit(gpa);
```

Its tables use `u32` state ids and a fixed 256-bit mask per state. The mask is
32 bytes per state even for a 26-letter alphabet. The
[Performance](#performance) chapter has the rest.

# Case folding

`Options.ascii_case_insensitive` folds ASCII letters in both the patterns and
the haystack. It is a byte-class remap, not extra trie branches, so a
case-insensitive automaton has the same number of states as a sensitive one.

```zig
const Warning = ac.Matcher(
    &.{"warning"},
    .{ .ascii_case_insensitive = true },
);
try std.testing.expect(Warning.isMatch("WaRnInG"));
```

Two patterns that are equal after folding are a compile error. Folding applies
to ASCII letters only. Every byte outside `A-Z` and `a-z` compares exactly. The
haystack is still bytes; a UTF-8 codepoint is not case folded.

# Inspect an automaton

`just viz` builds the `acviz` tool in `tools/` and runs it from the repository
root. It reads a pattern file with one pattern per line; blank lines and lines
that start with `#` are skipped.

```sh
just viz tools/patterns.txt                  # the trie
just viz tools/patterns.txt -f stats         # counts and memory
just viz tools/patterns.txt -f walk -t ushers  # one state per byte, with matches
just viz tools/patterns.txt -f matches -t "append the app" -m leftmost-longest
just viz tools/patterns.txt -f dot           # Graphviz DOT
```

`-f tree` is the default. It prints the trie with the state id, the incoming
byte, the pattern that ends at the state, and the failure link. The failure
link is the longest suffix of the path that is still a prefix of a pattern;
that link is how `she` also reports `he`.

`-f walk` steps the automaton over `-t` and lists every match ending at each
position. `-f matches` prints the non-overlapping spans the chosen match kind
returns, which is the quickest way to see the difference between the kinds.

`-f tui` opens the libvaxis view: the trie as an indented list, a details pane
with the path, failure link, and output, and a walk that follows the matching
state. `j` and `k` move, `space` steps the haystack, `r` resets, `f` toggles
following, and `q` quits.

The other flags are `-p <file>` when the pattern file is not positional, `-m`
for the match kind, `-i` for ASCII case folding, and `-h` for usage.

`acviz` is a developer program. It is not part of the published package, and a
consumer of the library never fetches it or its dependencies.

# Design

The automaton is a trie plus two kinds of links.

A state's children are a bitset over the pattern alphabet, not a 256-entry
table. The set bits index a packed child array through a popcount, so a node
with two children stores two child ids, not 256. A 256-entry byte-to-class
table maps each input byte to its class once.

The failure link of a state points to the longest proper suffix that is also a
trie prefix. The output link points to the nearest state on the failure chain
that ends a pattern. A match state reports its own pattern, then follows the
output links. That is why a single state can report `she` and `he` without
copying the suffix's output into every state.

The comptime build sorts the patterns and builds the trie from the sorted
order. Each pattern shares a prefix with the one before it, so the trie is
written once from a path stack and never searched during insertion. Failure
links and output links are built one depth at a time. Every table is written
once, copied to a `const`, and read only after the copy. Zig 0.16's comptime
evaluator copies an array on every element access, so a table that is written
and then read in place is dramatically slower.

The runtime build uses the same table fields with allocated slices. The search
algorithms live in `src/Search.zig` and are generic over the tables. The
comptime matcher and the runtime automaton are two table implementations, not
two searchers, so the match semantics cannot drift between them.

# Performance

The comptime build is the price of the no-allocation form. Measured with Zig
0.16 on aarch64-linux, `zig build-exe -OReleaseSafe`, above a one-pattern
baseline:

| Patterns | Total bytes | User time | Automaton build |
| -------- | ----------- | --------- | --------------- |
| 100      | ~700        | 1.77 s    | ~0.2 s          |
| 1,000    | ~7,000      | 5.84 s    | ~4.3 s          |
| 5,000    | ~35,000     | 81.1 s    | ~79.5 s         |

The words were random 4 to 10 letter lowercase strings. The same generated file
with a one-pattern matcher took 1.58 s of user time, which is subtracted. The
machine was loaded, so wall time is not useful; the user time is.

The cost grows faster than the pattern count because of the comptime evaluator
copy described in [Design](#design). A dictionary in the hundreds is the sweet
spot for the comptime form. Above a few thousand patterns, use
[`Automaton`](#the-runtime-automaton); it pays none of this at compile time.

The comptime table for 1,000 average words is 119,512 bytes, about 17 bytes per
node. The runtime form uses 32 bytes per state for its fixed 256-bit masks,
plus the failure, output, offset, depth, and pattern tables.

This guide makes no search-throughput claim. The cost per byte is one class
lookup and a short failure walk; the walk is O(1) for most inputs and O(depth)
in the worst case. Measure your own dictionary and haystack before depending on
a number. `just bench` runs the local suite, and `bench/README.md` records the
method and the baseline.

# Limits

- Empty patterns and duplicate patterns are compile errors in `Matcher` and
  runtime errors in `Automaton.init`.
- `ascii_case_insensitive` folds ASCII letters only. There is no Unicode case
  folding.
- There is no `Input` type. A search takes the whole `[]const u8`; a caller
  that needs a span slices the haystack and adds the offset.
- There is no anchored search. `find` searches the whole haystack.
- There is no streaming iterator that carries state across chunks. The raw
  state machine is exposed as `nextState`, `isMatchState`, `firstMatch`, and
  `matchesAt`, so a caller can build one.
- There is no prefilter and no full-DFA mode. The automaton walks failure links
  on a transition miss.
- The TUI shows the trie as an indented list. It does not draw a
  two-dimensional graph.
