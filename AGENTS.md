# k4o — Agent Operating Manual

Read this first. Then `README.md` — the "Template subset" section is the
contract, and the "Clean-room record" section is the provenance. The
teaching files in `src/init/` restate the subset for agents using knap;
this file is for agents *working on k4o*.

## What this is

A Knap template engine in Zig, stdlib only. `template.knap + data.json →
Textile (default), strict CommonMark 0.31.2, or CommonMark + GFM pipe
tables`. Sibling [Oliver](https://github.com/drawmeanelephant/oliver)
parses the output downstream; [dogbed](https://github.com/drawmeanelephant/dogbed)
embeds this library.

## Hard boundaries

1. **One parser.** `render` and `lint` share `src/parse.zig`. Never fork
   parsing logic into a second implementation.
2. **Buffered output.** Rendering buffers completely; on any error stdout
   stays empty, the diagnostic goes to stderr, exit is 1. Never
   half-emit a document.
3. **Every byte is charged.** All output flows through `Interp.charge()`
   so `--max-output` bounds nested-loop amplification. No write path may
   skip it.
4. **`gfm` ≡ `markdown` except tables.** Every non-table construct emits
   identical bytes in both formats; tests assert this.
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
(`-Dengine-mode=passthrough` and `-Dengine-mode=markdown` must make every
test fail — a survivor means the suite stopped discriminating), a
ReleaseSafe run, CLI byte-exactness, error-path empty-stdout checks, the
`--max-output` trip, lint/init smoke, and a static musl cross-build.

## Layout

- `src/parse.zig` — template → AST. Depth caps: 64 block nesting,
  32 condition parens, 256 condition expression depth.
- `src/engine.zig` — evaluation, loop frames, `charge()` budget.
- `src/filters.zig` — the 15-filter registry and per-format emitters,
  including the `link` URL rules (blocked schemes shared with lint).
- `src/lint.zig` — education-grade findings over the shared parser.
- `src/init.zig`, `src/init/knap-*.md` — embedded teaching files with
  versioned marker lines.
- `src/diag.zig` — structured diagnostics (`kind`, line, column, detail).
- `tests.zig`, `fixtures/` — unit tests plus the byte-exact and
  error-message corpus. `examples/` — golden CLI outputs.
- `tools/verify.sh` — the gate. `tools/differential/` — knap-oracle and
  Oliver byte-diffing (needs `npm ci --prefix tools/differential`).

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
