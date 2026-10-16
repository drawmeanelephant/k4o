# k4o — Agent Operating Manual

Read this first. Then `README.md` — the "Template subset" section is the
contract, and the "Clean-room record" section is the provenance. The
teaching files in `src/init/` restate the subset for agents using knap;
this file is for agents *working on k4o*.

## What this is

A Knap template engine in Zig, stdlib only — byte-compatible with
knap 0.6.0. `template.knap + data.json → CommonMark (default, faithful)
or oliver-format` (markdown plus HTML passthrough for highlight/math/
comment). Sibling [Oliver](https://github.com/drawmeanelephant/oliver)
parses the output downstream; [dogbed](https://github.com/drawmeanelephant/dogbed)
embeds this library. The legacy subset surface (Textile/GFM) is preserved
in release v0.1.0.

## Hard boundaries

1. **One parser.** `render` and `lint` share `src/parse.zig`. Never fork
   parsing logic into a second implementation.
2. **Buffered output.** Rendering buffers completely; on any error stdout
   stays empty, the diagnostic goes to stderr, exit is 1. Never
   half-emit a document.
3. **Every byte is charged.** All output flows through `Interp.charge()`
   so `--max-output` bounds nested-loop amplification. No write path may
   skip it.
4. **`oliver` diverges only on extension filters.** Every construct emits
   identical bytes in both formats except `highlight`/`math`/`comment`,
   which emit HTML passthrough under oliver (`<mark>`, `<span class="math">`,
   `<!-- -->`); tests assert this.
5. **Clean-room.** The subset derives from Knap's user-facing docs only.
   Real knap is a *black-box oracle* for differential testing — its
   internals are never consulted.
6. **Diagnostic detail strings are load-bearing.** Lint classifies parse
   failures by the `d.detail` text and fixtures pin the messages.
   Rewording a parser message without a matching lint entry and fixture
   update breaks the suite.
7. **The README results table is generated.** Never hand-edit it —
   `tools/verify.sh --update-readme` regenerates; CI's `--check-readme`
   fails on drift.
8. **`k4o init` never destroys.** Teaching files are additive-only; a
   superseded file is archived to a timestamped dir, never overwritten,
   never deleted.

## Build / test / gates

Requires Zig 0.17.0 (CI pins it).

```sh
zig build            # binary -> zig-out/bin/k4o
zig build test       # fixture corpus + unit tests
tools/verify.sh      # the gate — run this before declaring done
```

`verify.sh` is the real bar: build, suite, **red-green mutants**
(`-Dengine-mode=passthrough` and `-Dengine-mode=noeval` must make every
test fail — a survivor means the suite stopped discriminating; engine-free
tests assert `expectNormalEngine` so they discriminate too), a ReleaseSafe
run, CLI byte-exactness, error-path empty-stdout checks, the `--max-output`
trip, lint/init smoke, and a static musl cross-build.

## Layout

- `src/parse.zig` — template → AST for render and lint. Depth caps: ~100
  block nesting, 100 condition depth (parens cost ~2), 100 data depth.
- `src/engine.zig` — evaluation, loop frames, `charge()` budget. Values are
  typed `*const std.json.Value` handles: containers compare by identity,
  JS-style number rendering, `??` cond-chains (looser than every boolean
  op), `set`, scoped loop frames, `writeValue` fails past the 100-level
  serialize depth with a diagnostic, not a panic.
- `src/filters.zig` + `src/filters/*.zig` — the ~75-filter registry split by
  group (markup/text/numbers/dates/collections/advanced/extensions/html),
  plus `src/re.zig` — the bounded regex engine behind `replace`, designed
  to be lifted out as its own package. `link` input=URL/arg=label, blocked
  schemes shared with lint.
- `src/lint.zig` — education-grade findings over the shared parser.
- `src/init.zig`, `src/init/knap-*.md` — embedded teaching files with
  versioned marker lines.
- `src/diag.zig` — structured diagnostics (`kind`, line, column, detail).
- `tests.zig`, `fixtures/` — unit tests plus the byte-exact and
  error-message corpus. `examples/` — golden CLI outputs.
- `tools/verify.sh` — the gate. `tools/differential/` — knap-oracle and
  Oliver byte-diffing across the full surface (needs `npm ci --prefix
  tools/differential`), plus `tools/differential/oracle-docs/` — captured
  `knap help` output embedded into `k4o help` via `src/help/`.
- `KNAP-FIDELITY.md` — the issue-#60 implementation spec and decisions log
  (embed implemented as text emit, textile/gfm cut, bounded regex, batch).

## Conventions

- Allocator discipline: callers pass an arena; the engine allocates
  freely inside it. No global state.
- Errors are `error{Template, OutOfMemory}` with a `diag.Diagnostic`
  carrying kind + position + detail.
- `build.zig.zon` `.version` is the single source of truth for
  `--version`.
- Zig style: compact, switch-driven, no comments unless the why is
  non-obvious.

## Verification protocol

Run `tools/verify.sh` and report the exact commands and their results —
not "tests pass". Mutant legs are expected to fail; report the survivor
count, which must be zero.
