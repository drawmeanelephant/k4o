# Hardening: condition-depth stack overflow, link scheme entity bypass, float OOM

Fixes #42

## Summary

Four fixes, one per finding in the issue. Each crashing or wrong-error repro
now fails as a **template diagnostic** (exit 1, stderr message, stdout empty —
the buffered-output boundary holds) instead of aborting the process or
misreporting `out of memory`.

| # | Finding | Fix |
|---|---------|-----|
| 1 | Unbounded `not`/`!` chain recursion in `parseNot` (stack overflow at parse time) | `cond_depth` counter threaded through `parseOr`/`parseAnd`/`parseNot`, capped at `max_cond_depth = 256` |
| 2 | Left-leaning `and`/`or` `Cond` trees crash recursive `evalCond` (stack overflow at eval time) | The same counter **accumulates across chain links** (a chain of *N* operands builds *N−1* nested nodes), bounding template-reachable trees; `evalCondDepth` adds an independent 512-frame budget for library callers, mirroring the existing `max_compare_depth` guard |
| 3 | `link` scheme blocklist bypass via HTML entities in CommonMark destinations | Scheme validation now decodes entity/numeric references **before** checking (`&#106;`, `&#x6a;`/`&#X6A;`, `&colon;`); `escapeUrl` also emits `&` as `&amp;` in markdown destinations as defense in depth |
| 4 | Large floats report `out of memory` instead of rendering | `writeValue`'s formatting buffers sized for worst-case decimal expansion (`1e308` → 309 digits, `5e-324` → 326 chars) |

### Why the depth counter must accumulate (finding 2 detail)

`parseAnd` is iterative, but each `and` wraps the previous result:
`x and x and x` builds `((x and x) and x)` — tree depth equals chain length.
Checking depth only at parseNot entry (like the paren counter) misses this;
the loop-local `depth` variable increments per link and threads into the
recursive descent, so the counter tracks the tree being built, and it flows
through parenthesized subexpressions too (a paren's inner chain starts at the
outer accumulated depth).

### Why entity decoding in validation, not just output escaping (finding 3 detail)

The issue suggests `&` → `&amp;` in `escapeUrl` (markdown path). That alone
leaves the **textile** path emitting `"x":&#106;avascript:…` and data-provided
URLs unaudited. Since CommonMark's reference table is fixed and **no HTML5
named reference resolves to a plain ASCII letter**, the complete smuggle
surface for a scheme is: semicolon-terminated numeric references (`&#106;`,
`&#x6a;`, case-insensitive `x`, up to 8 digits) plus `&colon;` for the
separator. `decodeEntityPrefix` decodes exactly that (up to the first decoded
`:`, bounded to a 64-byte prefix buffer), so `hasBlockedScheme` judges the
destination a CommonMark renderer would actually resolve — for literal
arguments, bare-word data lookups, and lint's static check alike. The
`&amp;` output escaping stays as a second layer: legitimate `?a=1&b=2` query
strings round-trip to `&` unchanged, while smuggled references become inert.

Verified against: `&#106;avascript:`, `&#x6a;avascript:`, `&#X6A;avascript:`,
`&#x0006A;avascript:` (overlong), `javascript&colon;`, `JAVASCRIPT:`,
`&#100;ata:`, `&#118;bscript:`, entity payloads via data-provided URLs, and
the negatives — `https://…?a=1&b=2` passes, an entity payload **inside a
query string** of an `https` URL passes (scheme position is `https`),
semicolon-less `&#106avascript` stays literal per CommonMark §6.2. The
escaping also matches the knap 0.6.0 oracle, which emits `&amp;` in link
destinations the same way.

## Behavior change summary

- `{% if !!!…(300k)!!!x %}` → `syntax error … expression nesting too deep` (was: `Abort trap: 6`)
- `{% if x and x and … (300k terms) %}` → same syntax error (was: `Abort trap: 6` at eval)
- `{{ x | link:"&#106;avascript:alert(1)" }}` → `bad argument … refuses the URL scheme 'javascript:'` (was: rendered `[x](&#106;avascript:alert\(1\))` which downstream resolves to `javascript:`)
- `{{ big }}` with `1e308` → renders 309 digits (was: `k4o: out of memory`)
- Markdown link destinations now emit `&amp;` for a literal `&` (renders identically downstream; pinned in fixtures)
- Conditions deeper than 256 expression levels are now a syntax error; at-cap conditions (256 negations / 256 chain links) still parse and evaluate correctly, pinned by fixtures

No legitimate template in the corpus changed output except markdown/gfm link
destinations containing `&` (the new `&amp;` escaping, byte-pinned).

## Tests

- `tests/hardening_issue42.zig` — seven tests: each 300k repro (error, not
  abort), at-cap evaluation, composed paren×chain trees, all three entity
  variants refused, legitimate `&` round-trip in both formats, and exact
  byte/length assertions for `1e308` / `5e-324`. Compiled into the main test
  binary (via `tests.zig`) so `verify.sh` keeps parsing a single summary line;
  every test ends with the Textile-dialect assertion, so both engine mutants
  keep a **zero survivor** count.
- Error-corpus fixtures (message-pinned): `err-cond-not-chain`,
  `err-cond-and-chain`, `err-link-scheme-entity`,
  `err-link-scheme-colon-entity`, `err-link-scheme-hex-entity` — the latter
  three also map to lint rules (`link-scheme`), the former two to the existing
  `paren-too-deep` teaching rule (the diagnostic text is unchanged, so lint
  and its fixtures needed no rewording).
- Positive fixtures: `var-float-large` (byte-exact in textile/markdown/gfm),
  `logic-cond-depth-boundary` (256 negations and a 256-link chain render).
- Lint fixtures: `cond-too-deep`, `link-scheme-entity`.

## Verification

Zig 0.16.0 (`/tmp/zig-aarch64-macos-0.16.0/zig`, per the task) and zig 0.17.0
(CI-pinned; `build.zig.zon` sets `minimum_zig_version = 0.17.0`):

```
zig build test                                  # 84 pass, 0 fail (84 total), both versions
zig build test -Dengine-mode=passthrough        # 0 pass, 84 fail — 0 survivors
zig build test -Dengine-mode=markdown           # 0 pass, 84 fail — 0 survivors
zig build test -Doptimize=ReleaseSafe           # all pass
zig build -Dtarget=x86_64-linux-musl            # statically linked
python3 tools/differential/run.py --oliver …    # 232 cases: 75 byte-identical to knap 0.6.0,
                                                #  14 documented incompatibilities, Oliver-clean
```

`tools/verify.sh --check-readme` passes 37/37. README results table regenerated
via `--update-readme` (77 → 84 total). Manual CLI checks: every repro exits 1
with an empty stdout and the diagnostic on stderr.

### Differential note (new fixtures)

The two new corpus fixtures are byte-pinned against k4o and parsed by Oliver,
but excluded from byte parity with the knap 0.6.0 oracle, joining the existing
12 documented incompatibilities (14 total, asserted by the harness):

- `var-float-large`: knap renders extreme floats in exponent notation
  (`1e+308`) where k4o's subset expands decimal (309 digits).
- `logic-cond-depth-boundary`: knap's own `maxDepth` rejects 256-level
  conditions (`LIMIT_EXCEEDED`), below the depth k4o documents and supports.

Verified red/green: without the exclusions the differential job fails
(knap `LIMIT_EXCEEDED`); with them it passes. Notably, knap 0.6.0 itself
emits `&amp;` in link destinations — the new `&` escaping matches the oracle's
behavior.

Closes the three crash bugs and the `out of memory` misreport from #42. The
issue's "Minor" items (usage text for lint/init, init archive-retry empty
dir, `--max-output` overflow message) are intentionally **not** in this PR —
one concern per branch.
