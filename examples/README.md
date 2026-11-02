# Examples

`scan` reads a pattern file and a haystack file, builds the runtime
`Automaton`, and prints every non-overlapping match as `start..end  pattern`.

```sh
just examples
zig-out/bin/scan tools/patterns.txt <(printf 'ushers')
```

The pattern file has one pattern per line. Blank lines and lines that start
with `#` are skipped. `scan` uses the runtime `Automaton` because the patterns
are read at run time; the comptime `Matcher` takes the patterns in the type.
