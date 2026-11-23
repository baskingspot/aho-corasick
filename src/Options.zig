//! Match semantics shared by the comptime and runtime automata.
//!
//! `Matcher` and `Automaton` take this struct as their options bag:
//! `match_kind` picks which match wins, and `ascii_case_insensitive` folds
//! ASCII letters in the patterns and the haystack.

// ast-grep-ignore: public-struct-field-default -- an options bag; a call site overrides one knob.
match_kind: MatchKind = .standard,
/// Fold ASCII letters in both the patterns and the haystack, so `"Apple"`
/// matches `"apple"`. Other bytes compare exactly.
// ast-grep-ignore: public-struct-field-default -- an options bag; a call site overrides one knob.
ascii_case_insensitive: bool = false,

/// How an automaton chooses the match to report when more than one ends up
/// being a candidate.
pub const MatchKind = enum {
    /// Report each match as soon as the automaton reaches it, which orders
    /// matches by end offset. This is the textbook Aho-Corasick behavior and
    /// the only kind that supports overlapping searches.
    standard,
    /// Report the match that starts earliest. When two matches start at the
    /// same offset, the pattern listed first wins, so `{"ab", "abc"}` returns
    /// the one listed first on `"abc"`.
    leftmost_first,
    /// Report the match that starts earliest. When two matches start at the
    /// same offset, the longest wins.
    leftmost_longest,
};
