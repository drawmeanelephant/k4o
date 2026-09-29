# knap-textile

[![CI](https://github.com/drawmeanelephant/k4o/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/k4o/actions/workflows/ci.yml)

A Knap template engine that emits Textile.

Knap (Obsidian's template language) turns data into Markdown. knap-textile
turns data into Textile instead — template plus JSON in, Textile bytes out,
ready for a Textile parser (the sibling
[Oliver](https://github.com/drawmeanelephant) project renders the result).
It is a deliberately small, honest subset: a template core plus a filter
registry whose every filter emits Textile. Zig, stdlib only, built for a
static binary — no npm, no network, no dependency on the official knap
package.

```text
template.knap + data.json ──> knap-textile ──> Textile bytes ──> a Textile parser ──> HTML
```

## Build, run, test

Requires Zig 0.16.0.

```sh
zig build                       # binary -> zig-out/bin/knap-textile
zig build test                  # full suite: fixture corpus + unit tests
tools/verify.sh                 # build + tests + red-green mutants + CLI smoke + static check
```

```sh
zig-out/bin/knap-textile render template.knap --data data.json
zig-out/bin/knap-textile --help
zig-out/bin/knap-textile --version
```

- `render` writes the rendered Textile to stdout, exit 0. No trailing newline
  is added: the output bytes are exactly the rendered template.
- `--data` is optional; without it the variables default to `{}`.
- Exit codes: `0` on success, `1` on any error. The message goes to stderr and
  stdout stays empty — rendering is buffered, so partially rendered output is
  never emitted.

## Template subset

The documented subset, derived clean-room from Knap's user-facing
documentation (see the clean-room record below):

| Construct | Syntax | Notes |
| --- | --- | --- |
| Interpolation | `{{ title }}` | Whitespace optional (`{{title}}`). A value resolving to an object or array renders as compact JSON — see [Structured values](#structured-values). |
| Paths | `{{ author.name }}`, `{{ authors[0].name }}`, `{{ metadata["article:section"] }}` | Dotted properties and bracket access with a number or a quoted key. Names may contain spaces in interpolation (`{{ First name }}`). |
| Filters | `{{ value \| filter }}`, `{{ value \| filter:arg }}` | Chains run left to right: `{{ name \| italic \| h2 }}`. At most one argument (bare word, quoted string, or number). |
| Literals | `{{ "text" }}`, `{{ 7 }}`, `{{ 1.5 }}`, `{{ true }}` | Usable as values and as condition operands. |
| Logic | `{% if expr %} … {% elseif expr %} … {% else %} … {% endif %}` | Operators: `==` `!=` `<` `<=` `>` `>=`, `contains` (substring or array member), `and`/`&&`, `or`/`||`, `not`/`!`, parentheses. `==`/`!=` compare the whole value structurally, so objects and arrays work and key order does not matter; `<`/`<=`/`>`/`>=` are numbers and strings only. |
| Truthiness | — | `false`, `null`, missing values, `""`, `0`, and `[]` are false; everything else true. |
| Loops | `{% for item in array %} … {% endfor %}` | Loop values: `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last`, `loop.length`. Iterating a non-array is a render error. |
| Comments | `{# … #}` | Single- or multi-line; removed from the output; never evaluated; unclosed is a syntax error. |
| Missing values | — | Render as empty text; are false in conditions. |

Whitespace notes: one newline immediately following an opening tag
(`{% if %}`, `{% elseif %}`, `{% else %}`, `{% for %}`) is consumed once, so
branches and loop bodies join naturally; the newline before a closing tag is
preserved — place it deliberately.

### Structured values

Two rules cover values that are not plain text.

**Comparing them.** `==` and `!=` are structural, not scalar-only. Arrays and
objects are compared member by member, recursively, so a value always equals
itself and two objects are equal regardless of key order:

```text
{% if a == b %}same{% else %}different{% endif %}   {# {"a":{"p":1,"q":2},"b":{"q":2,"p":1}} -> same #}
```

`contains` uses the same comparison when the haystack is an array, so
`{% if items contains needle %}` matches an object member. Comparing across
different kinds is simply not equal: `{} == []` is false, and an object never
equals its own JSON text.

**Interpolating them.** An `{{ ... }}` that resolves to an object or array
emits compact JSON rather than Textile:

```text
{{ data }}
```

with `{"data":{"k":1,"s":"x"}}` emits `{"k":1,"s":"x"}`. This matches Knap's
behaviour for structured values and is pinned by the `var-json-object`
fixture. Key order is preserved from the input, so two inputs that are
semantically equal but serialise differently produce different bytes.

Reach for the field you want rather than the container: `{{ data.k }}` renders
`1`, and `{{ items | list }}` renders Textile. The JSON form is a deliberate
escape hatch, not the recommended way to emit prose.

Floats are the one place where interpolation is lossy: `{"a":2.0}` renders as
`2`, so a float and an integer are indistinguishable in the output. Use
`{{ a }}` for display and compare with `==` when the distinction matters —
`{% if a == 2 %}` is true for both `2` and `2.0`.

## Filter registry → Textile mapping

Every filter emits Textile. This is the complete registry (15 names); the
fixture corpus pins one byte-exact case per filter at minimum.

| Filter | Argument | Input example | Emits (Textile) |
| --- | --- | --- | --- |
| `h1` … `h6` | — | `{{ title \| h2 }}` | `h2. The Mending Apparatus` |
| `bold` | — | `{{ word \| bold }}` | `*watch out*` |
| `italic` | — | `{{ word \| italic }}` | `_very_` |
| `code` | — | `{{ cmd \| code }}` | `@zig build@` |
| `codeblock` | — | `{{ snippet \| codeblock }}` | `bc. ` + first line, remaining lines verbatim |
| `blockquote` | — | `{{ quote \| blockquote }}` | `bq. To be, or not to be.` |
| `link` | URL (required) | `{{ name \| link:"https://example.com/" }}` | `"Example":https://example.com/` |
| `list` | — | `{{ items \| list }}` | `* alpha` lines; nested arrays `**`, `***` (max depth 3) |
| `numbered` | — | `{{ steps \| numbered }}` | `# first` lines; nested arrays `##`, `###` |
| `table` | — | `{{ rows \| table }}` | `\|_. name\|_. age\|` header row, then `\|Walter\|5\|` rows |

Error conditions (all produce a message with kind, line, and column):

- Unknown filter name, or an argument where none is allowed / missing where
  required — `bad argument` / `unknown filter`.
- Phrase filters (`h1`…`h6`, `bold`, `italic`, `code`, `blockquote`, `link`)
  require single-line text; `link` also rejects `"` in text and whitespace or
  `"` in the URL.
- `list`/`numbered`/`table` require arrays; `table` rows must all have the
  same cell count and cells must not contain `|` or newlines; `list` nesting
  beyond 3 levels is an error.
- Values inside filters are treated as Textile fragments; no escaping is
  applied.

## Example renders (from JSON data)

Heading (`examples/heading.knap` + `.json`):

```text
h1. The Machine Stops

_A reading note_
```

List (`examples/list.knap`):

```text
h2. Sections

* The Air-Ship
* The Mending Apparatus
* The Homeless
```

Table (`examples/table.knap`):

```text
|_. name|_. age|
|Walter|5|
|Florence|6|
```

(The emitted table form is byte-identical to the textile-spec `page_layout`
table example input, and the other emitted forms — `h1. `, `bq. `, `* item`,
`# item`, `"text":url`, `@code@`, `bc. ` — follow the phrase-modifier and
block-signature forms in the same specification.)

## What's out (an honest subset)

Not implemented, by design — a static Zig binary and a documented subset are
the product:

- **Async variable resolvers.** No async anything; the engine is a pure
  function over bytes.
- **DOM-dependent filters** (`html_to_json`, `remove_html`, and friends). A
  static Zig binary has no DOM — that is a feature, not a gap.
- **The rest of Knap's broader filter catalog** (data/serialization filters
  such as `yaml`, `calc`, `parse_json`, `date`, `truncate`, `map`, `where`,
  …, plus the Markdown-emitting format filters this tool deliberately
  replaces with Textile ones).
- **Regex features** and **whitespace-control operators** (`{%- … -%}`).
- **`{% set %}` assignment** and the **`??` fallback operator**.
- **Batch/CSV modes and `--output` file flags** from the reference CLI; only
  `render` with stdout is provided.
- **Bracket expressions that reference variables** (e.g. `a[loop.index0]`);
  brackets take a number or a quoted string key only.
- **Spaced names in conditions**; spaced names work in interpolation and
  filter inputs only.

## Verification (red-green, no goldbricks)

The suite contains a fixture corpus (byte-exact: template + JSON → expected
Textile, including trailing-newline behavior) and error fixtures
(message-checked including line/column), plus unit tests. Two compile-time
mutant modes let anyone *prove* the tests fail against degraded engines:

```sh
zig build test                                # expects: all pass
zig build test -Dengine-mode=passthrough      # goldbrick: engine returns the template unchanged -> MUST fail
zig build test -Dengine-mode=markdown         # wrong dialect: filters emit Markdown -> MUST fail
```

The table below is **generated** by `tools/verify.sh` from a real run and
re-asserted by CI on every push and pull request: if the committed table ever
disagrees with what a run actually reports, the build fails. Regenerate it
locally with `tools/verify.sh --update-readme`.

<!-- verify-table:start -->
| Mode | Result |
| --- | --- |
| `normal` | 29 passed, 0 failed |
| `passthrough` | 0 passed, 29 failed |
| `markdown` | 0 passed, 29 failed |
<!-- verify-table:end -->

CI runs the same script on `ubuntu-latest` at Zig 0.16.0. The counts are
platform-independent, which is why one table serves both CI and local runs.

Every test re-asserts Textile-specific syntax (`h1. `, `bq. `, `*bold*`,
`_italic_`, `"text":url`, `|_. …|`) through a dialect guard, so neither
passthrough output nor Markdown emission can satisfy it.

`tools/verify.sh` runs all of the above plus CLI smoke checks (the three
examples compared byte-for-byte; error paths exit 1 with empty stdout) and a
static cross-build check (`-Dtarget=x86_64-linux-musl`, verified with
`file(1)` as "statically linked"; the macOS host build links the system libc,
which is a platform constraint).

## Clean-room record

knap-textile is a clean-room implementation: behavior was derived only from
Knap's **user-facing documentation** and the Textile specification. The Knap
parser source was never read, and no existing Knap or Textile
implementation source was consulted.

Sources consulted (with pinned revisions; fetched 2026-09-29):

| Source | Revision | Files read | sha256 |
| --- | --- | --- | --- |
| [obsidianmd/knap](https://github.com/obsidianmd/knap) | `6395cb8b5432b3c3495eab43c10b0d637e021592` | `README.md` | `558b4f442b34898e04a669b9860d32ca5795594c0c7951c87ec1cbd335a61556` |
| | | `CHANGELOG.md` | `33d9c1444871100a4b1b12006f985ee3e7b0479f0a184ec83870b35e58cdcda7` |
| | | `website/src/content/docs/variables.md` | `1c75845a372200a39cf73ae362bcaddd4cf302e97f1f6aed962e426146d16a2b` |
| | | `website/src/content/docs/filters.md` | `a0fc8c10ac435c7ac284c3b116b3526f9d02b36eb37c17fa603ecd669fe904df` |
| | | `website/src/content/docs/logic.md` | `8629fcbd8c170769ef0d4a4d45fce2e784ea2d326b291e0ca2529f2917598bd8` |
| | | `website/src/content/docs/cli.md` | `1662d6afb7098a6258ae90f568cdeb23454cb645ede24d1fb79a4647394ba2f9` |
| [textile/textile-spec](https://github.com/textile/textile-spec) | `a0615116ddf341bd57f54564af96e018bd5b9731` | `README.textile` | `5f07d62f8182a53e166315119e865eef7e4fb2cb2b0252616483019e1a76f03a` |
| | | `CHANGELOG` | `5efd5274043889e9dc1516db158e0c803642f8a57e40d9ea6b547fba807cb266` |
| | | `index.yaml` | `a78a5d8615cfd2fc94ba3b785a3ad7df1900c8916414b6d4290ebb06936eaa10` |
| | | `paragraph_text.yaml` | `68f901606cead3069af01ba49d52b87176253507797596ef0e862cb48bd3601b` |
| | | `page_layout.yaml` | `9eaac8e35526906c58062176bf45b424e484f3419ca40034241395e78e2a676b` |
| | | `phrase_modifiers.yaml` | `76ba245b10cf8b8ac445d6e6cac75e8b7ed2412bd303d2721e6064c5ca301566` |
| | | `attributes.yaml` | `03a2428dfe1e49ae72edd2efb4528d924245b3cabe03ddbea8620900bfc4dfa5` |
| | | `html.yaml` | `b3643c21becc2702891618bca1fe1efbca6558062c9cc07660edd4e931ce72f3` |

Zig 0.16 standard library documentation (local toolchain) was used for
language and library APIs only.

## Rollback / uninstall

Nothing is installed system-wide. To undo this work: `git revert <commit>`
(or check out the parent revision), or simply delete the repository and its
build outputs (`zig-out/`, `.zig-cache/`). No global state, config, or
shell files are touched.

## License

MIT — see [LICENSE](LICENSE).
