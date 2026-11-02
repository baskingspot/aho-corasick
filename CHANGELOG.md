# Changelog

All notable changes to aho-corasick are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Matcher`, a comptime Aho-Corasick automaton, with `MatchKind`, overlapping
  iteration, `whichMatches`, `replaceAll`, and the raw state machine.
