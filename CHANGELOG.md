# Changelog

All notable changes to aho-corasick are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Matcher`, a comptime Aho-Corasick automaton, with `MatchKind`, overlapping
  iteration, `whichMatches`, `replaceAll`, and the raw state machine.
- `Automaton`, the runtime builder for the same tables, with `init` and
  `deinit`.
- `acviz`, a developer tool that prints the automaton's stats, trie, Graphviz
  DOT, or a walk over a haystack (`just viz`).
- The `acviz` terminal view with libvaxis: browse the trie and step a haystack
  through it (`just viz <patterns> -f tui -t <text>`). The tool is a separate
  0.17 package under `tools/`.
