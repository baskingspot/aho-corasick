# AGENTS.md

Working notes for AI coding agents in baskingspot/aho-corasick.

## What this is

Aho-Corasick multi-pattern search in Zig, with the automaton built at comptime.
It is incubating: unstable, with no promises about its API.

## Environment

Zig 0.16 and 0.17. The default shell is 0.17; `nix develop .#zig-old` is 0.16.
The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides
Zig, `ziglint-0-16`, and the base tools, and nothing comes from the system
PATH. The justfile is the command interface: `just test`, `just check`,
`just lint`, `just ci`. `just ci` is the full gate on the default shell;
`just check` on `zig-old` is the compatibility lane. Run `just fmt` before you
commit.

Version differences go in `src/compat.zig`, behind a shape probe (`@hasDecl`,
`@hasField`), never in the public API. The build API probe for
`Run.addPassthruArgs` lives in `build.zig` for the same reason.

`Matcher` is the comptime form; `Automaton` is the runtime form. The search
semantics, iterators, and match-kind rules live only in `src/Search.zig`, and
both forms feed it their tables. Do not fork that code.

The comptime builder runs while the type is analyzed. A comptime array element
access copies the array, so the builder writes each table once, copies it to a
`const`, and reads only the `const`. Keep that shape; see `research/` in
`baskingspot/internal` for the measurements.

`tools/` is a separate package: `tools/build.zig` and `tools/build.zig.zon`
build `acviz` against the library, `baskingspot/cli`, and `libvaxis`. It needs
Zig 0.17 because libvaxis does, so `just check` on `zig-old` does not build it;
`viz-smoke` runs in `ci` on the default shell. `just viz` builds the tool and
runs the binary from the repo root, so pattern paths are repo-relative.

`cli` and `libvaxis` are pinned by commit in `tools/build.zig.zon` until their
next releases. They are not in the library's manifest, so a consumer fetches
neither. `tools/zig-pkg/` is the tool's fetch directory; keep it out of the
linters by listing the tool's source files in `.ziglint.zon` and the justfile.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint-0-16`. `just fmt` and `just lint` run both.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
