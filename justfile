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
    baskingspot-lint src test tools/acviz.zig tools/tui.zig tools/build.zig docs/examples examples
    zig fmt --check src test tools/acviz.zig tools/tui.zig tools/build.zig docs/examples examples build.zig build.zig.zon tools/build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md examples/README.md bench/README.md docs/content docs/config.toml docs/static .github
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test tools/acviz.zig tools/tui.zig tools/build.zig docs/examples examples build.zig build.zig.zon tools/build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md examples/README.md bench/README.md docs/content docs/config.toml docs/static .github
    just --fmt

[doc("Build the site into zig-out/site/aho-corasick/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /aho-corasick/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build aho-corasick

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve aho-corasick

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    mkdir -p docs/data
    docgen --root src/root.zig --title aho-corasick --repo-url https://github.com/baskingspot/aho-corasick --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Build the example programs")]
[group("examples")]
examples:
    zig build examples

[doc("Run benchmarks (ReleaseFast by default); args pass to the binary: just bench --benchtime=250ms --filter=FindIter")]
[group("bench")]
bench *ARGS:
    zig build bench -- {{ ARGS }}

[doc("Run every benchmark once: proves the suite builds and runs, without measuring")]
[group("bench")]
bench-smoke:
    zig build bench -- --benchtime=8x --count=1 --no-env

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
check: test test-release-safe test-release-fast examples

[doc("Everything CI runs: the gate and lint")]
[group("ci")]
ci: check lint viz-smoke doc bench-smoke
