# k4o → knap 0.6.0 fidelity spec

Working document. Derived from the knap 0.6.0 oracle (`knap help`, black-box —
no source consulted) cross-referenced with Oliver's parse/extension surface.
k4o today: 15 filters. knap CLI ships 78 filters + 1 alias, plus 2 DOM-only
filters upstream segregates into `knap/html`.

## Decisions (issue #60, resolved)

- **`embed`: implemented.** Initially ruled out for lack of a vault
  resolver; probing showed it needs none — strings emit `![[x]]` /
  `![[x|alias]]` and Oliver ≥1.3 gives the bytes a typed node downstream.
- **`textile`/`gfm`: cut.** v0.1.0 was tagged on main as the final subset
  release before removal. `--format markdown` becomes the default and only
  faithful mode; `--format oliver` adds an HTML passthrough for `comment`
  and widens `table`'s `| - |` delimiters to `| --- |`.
- **`replace`: bounded regex engine.** Built in-repo as a separable Zig
  module (`src/re.zig`) designed to be lifted into its own package later;
  step-capped so hostile patterns degrade to a diagnostic, not a hang.
- **`batch`: included.** CSV / JSON array / folder inputs, `--filename`,
  `--dry-run`, `--overwrite`.
- **Doc-vs-oracle divergence:** the 0.6.0 CLI *rejects* `{{- -}}` and
  `{%- -%}` (`PARSE_ERROR: Unexpected character '-'`) even though
  `knap help syntax` documents them. Fidelity = oracle, so k4o rejects
  dash markers too. Recorded here so nobody "fixes" it back.

Legend:
- **native** — emits strict CommonMark; Oliver parses as-is
- **ext** — emits syntax Oliver parses with an opt-in ParseOptions flag
- **html⇄** — faithful knap bytes in markdown mode; HTML passthrough in oliver mode
- **data** — markup-free transform; works in every mode
- **blocked** — cannot be implemented faithfully in an embeddable engine
- **risk** — implementable, with a named fidelity risk
- **have** — already in k4o (still needs byte verification against oracle)

## 1. Language features (parser + engine)

| Feature | Knap semantics | k4o today | Work |
| --- | --- | --- | --- |
| `{% set %}` | Ordered assignment: literal, expression, or filtered value | missing | Medium — new AST node + scope |
| `??` | Fallback to first truthy; lowest precedence; filters bind first | missing | Small-medium |
| `{{- -}}` / `{%- -%}` | **Oracle rejects** (PARSE_ERROR) despite help text — match oracle | missing | Match oracle: reject `-` in tags |
| `item_index` | Back-compat 0-based index named after the iterator | missing | Trivial |
| `x[loop.index0]` | Bracket access with a variable key | number/quoted literal only | Small-medium |
| `:(a, b)` params | Multi-arg params, `"k":"v"` pairs, arrow expressions | single arg | Medium |
| **Typed filter values** | Filters see arrays/objects, not serialized strings; chains preserve type | text-only pipes | **Large — core engine rework; ~30 filters depend on it** |
| `==` / `!=` / `contains` | Containers compare by **identity** | structural (deliberate) | Small — reverts a documented k4o choice |
| Whitespace rules | Nested standalone-tag stripping; loop line-break joins | diverges (in exclusion list) | Medium — match oracle bytes |
| Number rendering | JS `Number.toString`: shortest round-trip, exponent at extremes (`1e+308`) | expands decimal | Medium — JS float print in Zig |
| Depth / exec limits | JSON depth ~119 → `LIMIT_EXCEEDED`; condition depth < 256 | different caps | Small — retune to oracle |

## 2. Formatting filters → Oliver route

| Filter | Knap emits | Oliver route | Effort |
| --- | --- | --- | --- |
| `h1`–`h6` | `#` … `######` | native | have — verify per-line + whitespace |
| `bold` / `italic` | `**x**` / `*x*`; `bold:_` → `__x__` | native | have + `bold:_` param |
| `code` | `` `x` ``; multiline or `:lang` → fenced; adaptive backticks | native | have — merge with code_block semantics |
| `code_block` | ` ```lang ` | native | have — rename `codeblock`, add `:lang` |
| `blockquote` | `> ` per line | native | have |
| `list` | `-` / `1.` / `- [ ]` / `1. [ ]` | native + ext task_lists for task modes | have — fold `numbered` in as `list:numbered`; add task modes |
| `link` | `[text](url)` — **input=URL, arg=text** | native | risk — k4o arg order is reversed: breaking fix |
| `image` | `![alt](url)`; object: keys=URLs vals=alts | native | Medium — typed input |
| `hr` | `---` before/after/both, blank-line separated | native | Trivial |
| `hard_break` | trailing two-space breaks | native | Trivial |
| `escape_md` | backslash-escape ASCII md punctuation | native | partial — align byte-set to oracle |
| `fragment_link` | appends `[link](url#:~:text=…)` anchors | native (standard links) | Medium — URL encoding |
| `callout` | `> [!type] Title`, `+`/`-` fold, `:(type,title,fold)` | ext — Oliver callouts opt-in | Medium |
| `wikilink` | `[[target]]` / `[[t|alias]]` | ext — Oliver wikilinks opt-in | Small |
| `footnote` | `[^1]:` / `[^kebab-key]:` definitions | ext — Oliver footnotes opt-in | Medium |
| `strike` | `~~x~~` | ext — Oliver strikethrough opt-in | Small |
| `table` | pipe table; headers from object keys or `:(h1,h2)`; `| - |` delims | ext — GFM tables built into Oliver; oliver mode widens delims to `\| --- \|` (Oliver's `:?-+:?` needs 3+ hyphens or a colon) | Medium — header derivation + shapes |
| `table_pretty` | padded pipe table | ext — GFM tables | Medium |
| `highlight` | `==x==`; color `==🔵x==` | ext — Oliver `highlights` opt-in (≥1.3) | Small |
| `math` / `math_block` | `$x$` / `$$…$$` | ext — Oliver `math` opt-in (≥1.3) | Small-medium |
| `comment` | `%%x%%` | html⇄ → `<!--x-->` in oliver mode — a `%%` block only opens at line start in Oliver, so the passthrough is the safe emit at any column | Small |
| `yaml` / `yaml_property` | YAML block/flow; `name: value` | data — front-matter payload; Oliver frontmatter opt-in consumes at index 0 | Medium-large — bounded YAML writer |
| `embed` | `![[target]]` / `![[t|alias]]` | ext — Oliver `embeds` opt-in (≥1.3) | Implemented — needs no resolver (supersedes the earlier "can't") |

## 3. Data filters (markup-free — all implementable)

| Group | Filters | Notes |
| --- | --- | --- |
| Text | `camel` `capitalize` `kebab` `lower` `pascal` `snake` `title` `uncamel` `upper` `trim` `truncate` `truncatewords` `indent` `unescape` `safe_name` `encode_uri` `decode_uri` | risk — JS Unicode-aware casing vs Zig std (ASCII fine, non-ASCII edges); `truncate`/`length` count UTF-16 code units upstream |
| Numbers | `calc` `number_format` `round` | `calc` ops: `+ - * / ** ^` |
| Dates | `date` `date_modify` `duration` | risk — format-token mini-language + strict input parsing + interval math |
| Collections | `compact` `first` `join` `last` `length` `merge` `nth` `object` `parse_json` `reverse` `slice` `sort` `split` `sum` `unique` `where` | All need typed values; `nth` patterns + `sort` by property are medium each |
| Collections (hard) | `map` `template` | `map:x => ({name: x.name})` arrow-expression mini-language; `template:"${prop}"` interpolation mini-language — **large** |
| Replace | `replace` | risk — accepts real regexes `/[aeiou]/g`; **Zig stdlib has no regex**. Decided: bounded engine in `src/re.zig` (separable, step-capped) |

## 4. HTML cleanup filters

| Filter | Behavior | Assessment |
| --- | --- | --- |
| `remove_attr` `strip_attr` `remove_tags` `replace_tags` `strip_tags` | Clean HTML inside *data*; emit HTML/text | Need an HTML tokenizer in k4o (tag/attr stream, not a DOM). Medium-large as a group; each cheap once infra exists. Output passes through Oliver as raw HTML. |
| `strip_md` | Remove Markdown formatting, keep readable text | Markdown-aware stripping (emphasis, wikilinks, fences, footnote refs). Medium. |
| `html_to_json` `remove_html` | DOM-dependent; upstream exports separately from `knap/html` | **blocked** — upstream itself isolates these; legitimately out of an embeddable registry. Documented exclusion. |

## 5. CLI surface

| knap 0.6.0 | k4o today | Work |
| --- | --- | --- |
| `render` file / `-t` inline / stdin | `render` file | Small |
| `validate` | `lint` (education-grade superset) | Keep lint; add `validate` alias or match |
| `--data-json` `--set` `-o/--output` | `--data` only; stdout only | Small |
| `batch` (CSV / JSON array / folder) + `--filename` `--dry-run` `--overwrite` | missing | **Medium-large** — CSV parser, filename rules |
| `knap help filters|tags|filter|tag|syntax` | `init` teaching files | Medium — or fold into lint/init |
| — | `--max-output`, `lint`, `init` | Keep — k4o extensions, no knap conflict |

## 6. Output-mode architecture

- `--format markdown` becomes the **default and faithful** mode — bytes match
  the oracle on the implemented surface. Textile default flips: breaking
  change, lands alongside the site fixes anyway.
- `--format oliver` (new): markdown mode + HTML substitution for `comment`
  (`<!-- -->`) + widened `table` delimiters (`| --- |` for knap's
  `| - |`). Oliver ≥1.3 parses `==…==`, `$…$`/`$$…$$`, `![[…]]` and
  callout fold markers natively, so the rest emits faithful knap bytes in
  both formats; `comment` keeps the passthrough because a `%%` block only
  opens at line start — mid-line it would leak the marker and hide what
  follows — and `table` widens its delimiters because Oliver's `:?-+:?`
  delimiter grammar needs three hyphens or a colon, so the compact form
  would parse as a paragraph, not a table (issue #63). The output assumes
  Oliver ParseOptions `callouts`, `wikilinks`,
  `embeds`, `footnotes`, `strikethrough`, `task_lists`, `highlights`,
  `math`, `frontmatter` (or `--obsidian` plus `frontmatter`), and
  `raw_html=allowed` for the comment passthrough.
- `textile` / `gfm`: **cut** (decided). v0.1.0 tagged as the final release
  containing them; Oliver's opt-ins cover the original need. dogbed must
  move to markdown/oliver output.
- `embed`: **implemented** — probing showed it needs no vault resolver:
  strings emit `![[x]]`/`![[x|alias]]`, arrays vectorize, objects emit
  `["![[k|v]]"]` as a *serialized-string* result (reparsed by later
  filters). The earlier "can't" note is corrected.

## 7. The honest "can't" list

- **blocked** `html_to_json`, `remove_html` — need DOM globals; upstream
  segregates them. Permanent, documented exclusion. (Every other filter
  in the registry — including `embed` — is implemented.)
- **risk** `replace` regex — no stdlib regex; bounded engine (decided:
  build `src/re.zig` as a separable step-capped module).
- **risk** Unicode casing + UTF-16-unit counting — JS semantics vs Zig bytes;
  oracle diffs possible at edges.
- **risk** JS number printing — exponent thresholds, shortest round-trip;
  must reproduce exactly.
- **risk** `map` arrows + `template` ${} — two embedded mini-languages.
- **risk** Whitespace fidelity — nested standalone-tag stripping must match
  oracle bytes; currently in the exclusion list.

**Scorecard:** 78 CLI filters → 2 blocked (DOM pair), 76 implementable +
regex engine. Weight concentrates in: typed-value
engine rework, regex, date mini-language, arrow expressions, HTML tokenizer,
JS float print.

## 8. Landed semantics (implementation findings, post-spec)

These were pinned by oracle probes during implementation:

- **`??` binds below every boolean op.** `x ?? y == "z"` is
  `x ?? (y == "z")` — terms are whole conditions; first truthy wins; when
  none is truthy the LAST term's value renders (`{{ 0 }}` emits `0`).
- **`{{ }}` takes the full boolean grammar** — `==`, `and`, `contains`,
  `not`, parens — with filters banned on the left of a comparison
  (`{{ x | bold == "b" }}` is a parse error; oracle agrees).
- **Loop separator joins only non-empty iterations** — a loop whose
  bodies emit nothing emits nothing (no `\n`s from `{% set %}` bodies).
- **`set` scopes to the innermost loop frame** — `{% set n = i %}` inside
  a `for` does not leak to the outer scope.
- **Quoted index** — `xs["1"]` indexes arrays like `xs[1]`.
- **`map` semantics** — non-array input passthrough; `map:"path"` → real
  `null` for missing keys; `map:x => x.path` missing → the literal
  `"undefined"` string (sentinel, not a primitive — `[undefined]`
  serializes `["undefined"]` and does not unwrap); `x => x` renders the
  variable name; arrow `${x.name}` inside a string body stays literal
  (`${x}` alone substitutes); `x => ({k: v})` object construction.
- **Singleton unwrap rule** — `{{ [prim] }}` unwraps only for
  string/number/bool elements; `[null]`, `[[]]`, `[{}]` and the
  `undefined` sentinel stay wrapped.
- **`template` semantics** — `${path}` resolves nested props; `${str}`
  is the item itself; arrays iterate with blank-line joins; `${arr}`
  comma-joins; missing `${x}` → empty.
- **CLI** — `render -t`/stdin/`--data-json`/`--set`/`-o`, `validate`,
  `batch` (CSV/JSON-array/folder + `--filename`/`--overwrite`/`--dry-run`),
  `help syntax|filters|tags|filter|tag` — implemented in `src/batch.zig`,
  `src/help.zig`, `src/main.zig`; oracle docs embedded under `src/help/`.
