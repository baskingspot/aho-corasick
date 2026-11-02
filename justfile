# aho-corasick: multi-pattern search built at comptime. `just --list` shows
# the recipes. AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests (Debug)")]
[group("test")]
test:
    zig build test --summary all

[doc("Unit tests (ReleaseSafe): the option matrix, because lazy analysis hides code that only instantiates in release modes")]
[group("test")]
test-release-safe:
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Unit tests (ReleaseFast)")]
[group("test")]
test-release-fast:
    zig build test -Doptimize=ReleaseFast --summary all

[doc("Lint Zig, Nix, Markdown, and the workflows: ziglint against 0.16, the ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    baskingspot-lint src test tools
    zig fmt --check src test tools build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test tools build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md .github
    just --fmt

[doc("Inspect an Aho-Corasick automaton: `just viz tools/patterns.txt`, `just viz tools/patterns.txt -f walk -t ushers`")]
[group("viz")]
viz *ARGS:
    zig build viz -- {{ ARGS }}

[doc("Render the automaton to SVG: `just viz-svg tools/patterns.txt automaton.svg`. Needs Graphviz on PATH")]
[group("viz")]
viz-svg PATTERNS OUT="automaton.svg":
    zig build viz -- {{ PATTERNS }} -f dot | dot -Tsvg > {{ OUT }}

[private]
viz-smoke:
    zig build viz -- tools/patterns.txt -f stats > /dev/null

[doc("The per-version gate: the Debug and release-mode test suites")]
[group("ci")]
check: test test-release-safe test-release-fast viz-smoke

[doc("Everything CI runs: the gate and lint")]
[group("ci")]
ci: check lint
