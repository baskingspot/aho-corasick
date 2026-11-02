# Third party

`aho-corasick` is MIT. See `LICENSE`. These pieces shaped it.

## Rust `aho-corasick`

The API shape comes from BurntSushi's Rust crate: a `Match` with a pattern id
and a span, the three `MatchKind` variants, and the method names `find`,
`find_iter`, `find_overlapping_iter`, `replace_all`, and
`which_overlapping_matches`. No code is copied. The crate is Unlicense or MIT.

## moomd

The first comptime implementation of this automaton lived in PlanetScale's
`moomd`, in `src/aho_corasick.zig`, where it classified Postgres process
states. The packed transition layout and the type-level pattern list come from
there. The code here is a rewrite. `moomd` carries no license file.
