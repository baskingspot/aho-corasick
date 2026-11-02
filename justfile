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
    baskingspot-lint src test tools/acviz.zig tools/tui.zig tools/build.zig
    zig fmt --check src test tools/acviz.zig tools/tui.zig tools/build.zig build.zig build.zig.zon tools/build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test tools/acviz.zig tools/tui.zig tools/build.zig build.zig build.zig.zon tools/build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md .github
    just --fmt

[doc("Inspect an Aho-Corasick automaton: `just viz tools/patterns.txt`, `just viz tools/patterns.txt -f walk -t ushers`")]
[group("viz")]
viz *ARGS:
    cd tools && zig build
    tools/zig-out/bin/acviz {{ ARGS }}

[private]
viz-smoke:
    cd tools && zig build
    tools/zig-out/bin/acviz tools/patterns.txt -f stats > /dev/null

[doc("The per-version gate: the Debug and release-mode test suites")]
[group("ci")]
check: test test-release-safe test-release-fast

[doc("Everything CI runs: the gate and lint")]
[group("ci")]
ci: check lint viz-smoke
