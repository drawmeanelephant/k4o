# k4o

[![CI](https://github.com/drawmeanelephant/k4o/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/k4o/actions/workflows/ci.yml)

A Knap template engine that emits Textile (default), CommonMark 0.31.2, or
CommonMark with opt-in GFM pipe tables.

The name is a nod: *Knap for Oliver* — Oliver being the sibling project that
parses Textile and CommonMark. Short name, plain job.

Knap (Obsidian's template language) turns data into Markdown. k4o renders
its documented template subset to Textile, CommonMark, or GFM tables, selected
at runtime.
The sibling [Oliver](https://github.com/drawmeanelephant/oliver) parses
the Textile and strict CommonMark outputs. The production binary is Zig,
stdlib only, with no Node or network dependency. Official knap is installed
only for differential tests.

```text
template.knap + data.json ──> k4o ──> Textile or CommonMark ──> Oliver ──> HTML
```

## Build, run, test

Requires Zig 0.17.0.

```sh
zig build                       # binary -> zig-out/bin/k4o
zig build test                  # full suite: fixture corpus + unit tests
tools/verify.sh                 # build + tests + red-green mutants + CLI smoke + static check
npm ci --prefix tools/differential --ignore-scripts
python3 tools/differential/run.py --oliver /path/to/oliver
```

```sh
zig-out/bin/k4o render template.knap --data data.json
zig-out/bin/k4o render template.knap --data=data.json
zig-out/bin/k4o render template.knap --data=data.json --format markdown
zig-out/bin/k4o render template.knap --data=data.json --format gfm
zig-out/bin/k4o lint template.knap
zig-out/bin/k4o lint one.knap two.knap
zig-out/bin/k4o init
zig-out/bin/k4o --help
zig-out/bin/k4o --version
```

- `render` writes Textile by default, or CommonMark with `--format markdown`
  (also `--format=markdown`). `--format gfm` (or `--format=gfm`) changes only
  table rendering. `--format textile` selects the default explicitly.
  No trailing newline is added: the output bytes are exactly the rendered template.
- `--data` is optional; without it the variables default to `{}`. Both
  `--data FILE` and `--data=FILE` are accepted (and `-d` / `-d=FILE`); a bare
  second positional is an error that suggests `--data`.
- `--max-output` (or `-m`) caps rendered output; see
  [Output size](#output-size). Defaults to 256 MiB; `0` means no cap.
- Exit codes: `0` on success, `1` on any error. The message goes to stderr and
  stdout stays empty — rendering is buffered, so partially rendered output is
  never emitted.

### Output format contract

- `markdown` is strict **CommonMark 0.31.2**. Tables remain HTML blocks, and
  its output bytes are unchanged by the opt-in GFM format.
- `gfm` is **CommonMark + GFM pipe tables**, for Obsidian consumers. Every
  non-table construct, including escaping and loop whitespace, emits the same
  bytes as `markdown`. No strikethrough, task-list or autolink extensions are
  added.
- The no-argument `table` filter carries no alignment metadata. The GFM table
  layout matches the knap **0.6.0** black-box oracle: an empty header, plain `-`
  delimiters with no alignment markers, then every input row as a body row.
  Single hyphens are valid GFM delimiters. This deliberately follows the
  observed oracle bytes rather than promoting the first data row to a header
  or using `---` delimiters.
- GFM tables are knowingly unfriendly to **Oliver**: its strict CommonMark
  parser reads pipe tables as paragraphs, not tables. That is the opt-in
  tradeoff, not a bug; use `markdown` when feeding tables to Oliver.

## Template subset

The documented subset, derived clean-room from Knap's user-facing
documentation (see the clean-room record below):

| Construct | Syntax | Notes |
| --- | --- | --- |
| Interpolation | `{{ title }}` | Whitespace optional (`{{title}}`). A value resolving to an object or array renders as compact JSON — see [Structured values](#structured-values). |
| Paths | `{{ author.name }}`, `{{ authors[0].name }}`, `{{ metadata["article:section"] }}` | Dotted properties and bracket access with a number or a quoted key. Names may contain spaces in interpolation (`{{ First name }}`). |
| Filters | `{{ value \| filter }}`, `{{ value \| filter:arg }}` | Chains run left to right: `{{ name \| italic \| h2 }}`. At most one argument; a bare word resolves against the data root, a quoted or numeric argument is a literal. See [Filter arguments](#filter-arguments). |
| Literals | `{{ "text" }}`, `{{ 7 }}`, `{{ 1.5 }}`, `{{ true }}` | Usable as values and as condition operands. |
| Logic | `{% if expr %} … {% elseif expr %} … {% else %} … {% endif %}` | Operators: `==` `!=` `<` `<=` `>` `>=`, `contains` (substring or array member), `and`/`&&`, `or`/`||`, `not`/`!`, parentheses. `==`/`!=` compare the whole value structurally, so objects and arrays work and key order does not matter; `<`/`<=`/`>`/`>=` are numbers and strings only. |
| Truthiness | — | `false`, `null`, missing values, `""`, `0`, and `[]` are false; everything else true. |
| Loops | `{% for item in array %} … {% endfor %}` | Loop values: `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last`, `loop.length`. Iterating a non-array is a render error. **Nested loops multiply** — see [Output size](#output-size). |
| Comments | `{# … #}` | Single- or multi-line; removed from the output; never evaluated; unclosed is a syntax error. |
| Missing values | — | Render as empty text; are false in conditions. |

Whitespace notes: one newline immediately following an opening tag
(`{% if %}`, `{% elseif %}`, `{% else %}`, `{% for %}`) is consumed once, so
branches and loop bodies join naturally; the newline before a closing tag is
preserved — place it deliberately. In Markdown and GFM, loop iterations join
with a newline and one body-final newline is removed. Some standalone-tag whitespace
still differs from knap (see [Differential boundary](#differential-boundary)).

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
emits compact JSON rather than markup:

```text
{{ data }}
```

with `{"data":{"k":1,"s":"x"}}` emits `{"k":1,"s":"x"}`. This matches Knap's
behaviour for structured values and is pinned by the `var-json-object`
fixture. Key order is preserved from the input, so two inputs that are
semantically equal but serialise differently produce different bytes.

Reach for the field you want rather than the container: `{{ data.k }}` renders
`1`, and `{{ items | list }}` renders the selected format. The JSON form is a deliberate
escape hatch, not the recommended way to emit prose.

Floats are the one place where interpolation is lossy: `{"a":2.0}` renders as
`2`, so scalar interpolation emits a whole-number float and the equal integer
as the same bytes. Use `{{ a }}` for display, and do not reach for `==` to
recover the distinction: numeric equality compares the numeric value, not the
integer/float representation, so `{% if a == 2 %}` is true for both `2` and
`2.0`.

### Filter arguments

A filter takes at most one argument, and how it is written decides whether it
is a value or a literal.

| Written as | Meaning |
| --- | --- |
| `filter:"text"` | The literal `text`. Always. |
| `filter:7` | The literal `7`. |
| `filter:name` | The value of the top-level data key `name`, **or** the literal word `name` if the data has no such key. |

So with `{"name":"Example","url":"https://example.com/post"}`:

```text
{{ name | link:url }}      -> "Example":https://example.com/post
{{ name | link:"url" }}    -> "Example":url
```

The bare form exists because the common case is a URL that lives in the data,
and the alternative is unreachable: there is no syntax for putting a
data-derived value into a filter argument other than a bare word. Only
top-level keys are consulted — `link:a.b` is a syntax error, not a nested
lookup.

If the key exists but holds `null`, an object or an array, the argument is a
`bad argument` error rather than a silent fallback to the bare word, since
none of those have a text form.

### URL schemes in `link`

`link` refuses the `javascript:`, `vbscript:` and `data:` schemes (matched
case-insensitively), because a Textile renderer will happily turn those into
script execution:

```text
{{ name | link:url }}   with {"url":"javascript:alert(1)"}   -> bad argument
```

The check is entity-aware: CommonMark resolves entity and numeric character
references inside link destinations, so `&#106;avascript:`, `&#x6a;avascript:`
and `javascript&colon;` are all `javascript:` in disguise and are refused the
same way. In the CommonMark/GFM output a literal `&` in a URL is emitted as
`&amp;`, which the renderer decodes back to `&` — legitimate query strings
round-trip unchanged, while smuggled references stay inert.

Navigational and relative URLs are untouched — `http:`, `https:`,
`mailto:`, `ftp:`, `file:` and site-relative paths all pass. A colon that is
not a well-formed scheme, as in `a/b:c`, is treated as part of the path.

The trust boundary here is deliberate: this tool's stated purpose is to
produce Textile for a downstream parser, so a scheme that executes in that
parser is refused at the point it is written rather than shipped. If your
input is trusted and you need one of the refused schemes anyway, this is a
deliberate limit, not an oversight.

### Output size

**Nested loops multiply.** A loop over an array of length *N* runs its body
*N* times, so *L* nested loops over arrays of length *N* render *N<sup>L</sup>*
times. Three nested loops over 300-element arrays is 27 million iterations
from a three-line template, and a fourth level would need about 72 billion.
Output grows as the product, which makes it exponential from the point of
view of anyone writing the template.

The CLI bounds this with an output cap, default 256 MiB, that fails with a
diagnostic naming the loop depth rather than exhausting memory:

```sh
k4o render t.knap --data d.json --max-output=64m
```

`--max-output` accepts plain bytes or a `k`/`m`/`g` suffix, in both
`--max-output=64m` and `--max-output 64m` form; `-m` is the short spelling.
Pass `--max-output=0` to remove the cap entirely, which is occasionally
wanted for a deliberately huge render.

The cap is enforced in the engine rather than the CLI, so the library API
gets it too: `render` uses the default and `renderWithLimit` takes an
explicit byte count. Because the check is a budget charged per write, it
trips the instant the limit is crossed instead of after the allocator is
exhausted — a small cap fails in milliseconds where the old behaviour took
seconds to produce hundreds of megabytes first.

## k4o lint

`k4o lint` checks templates against the documented subset and teaches the
fix. Knap is new to training data, so agents hallucinate it; lint closes the
loop — write, verify, fix — with education-grade diagnostics: every finding
names the offending construct, states the rule, and shows an example of
right. Verify and educate in one binary, over one parser.

```sh
zig-out/bin/k4o lint template.knap
zig-out/bin/k4o lint one.knap two.knap three.knap
```

A broken template prints a finding per problem and exits 1:

```text
broken.knap:1:1: syntax error: unclosed if block (missing '{% endif %}')
  construct: `{% if %}` block
  why: every {% if %} needs a matching {% endif %}; branches inside come from {% elseif %} and {% else %}
  example: {% if draft %}Draft{% else %}Published{% endif %}

k4o lint: 1 problem(s) in 1 of 1 file(s)
```

- **One parser, no drift.** lint reuses k4o's parser and filter registry, so
  a construct either renders or lints — never both, never neither. There is
  no standalone lint binary and no second frontend to maintain.
- **Stable exit codes.** `0` when every file is clean, `1` when any file has
  findings or cannot be read. Findings go to stdout.
- **Static scope.** lint checks what is knowable without data: template
  syntax, the 15-filter registry, argument arity, and the `link` URL rules
  that a literal argument already violates. Data-dependent failures (a loop
  over a non-array, a ragged table) are render errors and stay with
  `k4o render`.
- **Rules have ids.** `unclosed-if`, `unknown-filter`, `link-scheme`,
  `bracket-key`, … — stable identifiers the test suite pins per fixture, so
  a parser message can never drift away from its teaching text unnoticed.
- **Fixture contract.** the clean corpus (`fixtures/*.knap`,
  `examples/*.knap`) lints clean; the broken set (`fixtures/errors/*.knap`
  and the dedicated `fixtures/lint/*.knap` rules) is rejected with the
  expected rule named. `tools/verify.sh` asserts both on every run.

## k4o init

`k4o init` drops knap teaching files (language tour, templates, examples,
gotchas) into the working dir so an agent can pull knap-into-context when
doing knap work — no prompt bloat, no training-data dependency. It teaches;
nothing else: rendering is oliver's job and building sites is dogbed's job.

```sh
zig-out/bin/k4o init
```

```text
created knap-tour.md
created knap-templates.md
created knap-examples.md
created knap-gotchas.md
k4o init: 4 created, 0 untouched, 0 archived
```

The poop rules (load-bearing):

- **Look for poop; if nah, take a poop.** Only files that don't exist are
  created. A rerun in the same dir changes nothing and says so.
- **Never overwrite an existing file, modified or not.** Existence is the
  only test — no manifest, no checksums, no "was it modified" detective
  work. init is strictly additive, forever.
- **When init supersedes an old file with a new one: archive, don't
  replace.** A future k4o that ships new teaching content identifies its own
  old copies by the embedded `<!-- k4o init <name> v<N> -->` marker line,
  moves them to a timestamped `k4o-archive/<UTC timestamp>/` directory, and
  reports the location in the output. Bag it, don't curb it — and
  especially no trash day: no auto-expiry, no "archives older than N days
  get purged". Nobody should ever have to ask where their shit went.

The marker is what keeps the second rule absolute: a file without a
recognizable marker — a user file, or a teaching file edited past
recognition — is never touched at all, and neither is a copy whose marker
claims a version newer than this build ships. The teaching content covers
knap knowledge only and is pinned by tests: the tour must mention every
filter the registry implements, and every template shown in it must lint
and render exactly as claimed.

Exit 0 unless the filesystem fails; anything else is exit 1 with the error
on stderr.

## Filter registry → output formats

This is the complete registry (15 names). The fixture corpus pins all three
formats byte-for-byte for every filter, reusing `.markdown` expectations for
non-table GFM output and `.gfm` expectations for tables. The Markdown table is
raw HTML because pipe tables are a GFM extension, not part of CommonMark 0.31.2.
The GFM format changes only that row of the registry.

| Filter | Argument | Textile | CommonMark |
| --- | --- | --- | --- |
| `h1` … `h6` | — | `h2. Title` | `## Title` |
| `bold` | — | `*watch out*` | `**watch out**` |
| `italic` | — | `_very_` | `*very*` |
| `code` | — | `@zig build@` | `` `zig build` `` (adaptive backtick delimiter) |
| `codeblock` | — | `bc. ` + content; `bc.. ` when content has a blank line | fenced code block (adaptive fence) |
| `blockquote` | — | `bq. Quote` | `> Quote` |
| `link` | URL (required) | `"Example":https://example.com/` | `[Example](https://example.com/)` |
| `list` | — | `* item`; nested `**`/`***` | `- item`; nested tab-indented lists |
| `numbered` | — | `# item`; nested `##`/`###` | `1. item`, `2. item`; nested ordered lists |
| `table` | — | `\|_. name\|` then `\|Ada\|` | `<table>` with `<thead>`, `<tbody>`, escaped cells |

In Markdown and GFM, `code` emits nothing for empty input. All-space input
remains a code span containing exactly the original spaces, without padding.
Other nonempty code retains its boundary spaces and backticks, including
`" a "`; it is not trimmed to match knap. `codeblock` preserves every existing
terminal newline. Nonempty content without a terminal newline needs one before
the closing fence, so its parsed code content ends in one newline. Empty
content produces an empty fenced block, not a blank code line.

In Textile, `codeblock` emits `bc. ` + content. A single-block signature ends
at the first blank line, so content with a blank line followed by more content
is emitted with the extended `bc.. ` signature instead — it holds across blank
lines until the next block signature or the end of input, and the tail stays
inside the code block instead of being re-parsed downstream. The extended form
absorbs whatever follows it until that boundary, so template text directly
after such a code block needs its own block signature (`p. `, `h2. `, …).
Blank lines that trail into nothing leak nothing, and keep the single form.

Error conditions (all produce a message with kind, line, and column):

- Unknown filter name, or an argument where none is allowed / missing where
  required — `bad argument` / `unknown filter`.
- Phrase filters (`h1`…`h6`, `bold`, `italic`, `code`, `blockquote`, `link`)
  require single-line text; `link` also rejects `"` in text and whitespace or
  `"` in the URL.
- `link` rejects the `javascript:`, `vbscript:` and `data:` URL schemes, and
  any filter argument that resolves to a non-text value. See
  [URL schemes](#url-schemes-in-link).
- `list`/`numbered`/`table` require arrays; `table` rows must all have the
  same cell count and cells must not contain `|` or newlines; `list` nesting
  beyond 3 levels is an error.
- Textile values are left as fragments, as before. Markdown phrase filters
  escape user-supplied punctuation and raw HTML; markup from earlier filters
  in a chain stays markup.

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

The same heading example under `--format markdown` emits:

```text
# The Machine Stops

*A reading note*
```

The Markdown table uses HTML, parsed as a CommonMark raw HTML block rather
than a GFM pipe table. Under `--format gfm`, the table example emits the
knap 0.6.0 no-argument table form:

```text
|  |  |
| - | - |
| name | age |
| Walter | 5 |
| Florence | 6 |
```

(The emitted table form is byte-identical to the textile-spec `page_layout`
table example input, and the other emitted forms — `h1. `, `bq. `, `* item`,
`# item`, `"text":url`, `@code@`, `bc. `, and `bc.. ` after the same spec's
extended-block rule — follow the phrase-modifier and block-signature forms in
the same specification.)

## What's out (an honest subset)

Not implemented, by design — a static Zig binary and a documented subset are
the product:

- **Async variable resolvers.** No async anything; the engine is a pure
  function over bytes.
- **DOM-dependent filters** (`html_to_json`, `remove_html`, and friends). A
  static Zig binary has no DOM — that is a feature, not a gap.
- **The rest of Knap's broader filter catalog** (data/serialization filters
  such as `yaml`, `calc`, `parse_json`, `date`, `truncate`, `map`, `where`, …).
- **Regex features** and **whitespace-control operators** (`{%- … -%}`).
- **`{% set %}` assignment** and the **`??` fallback operator**.
- **Batch/CSV modes and `--output` file flags** from the reference CLI; only
  `render` with stdout is provided.
- **Bracket expressions that reference variables** (e.g. `a[loop.index0]`);
  brackets take a number or a quoted string key only.
- **Spaced names in conditions**; spaced names work in interpolation and
  filter inputs only.
- **Other GFM extensions** (strikethrough, task lists, autolinks) and table
  alignment or cell spans. The opt-in GFM format adds pipe tables only.

## Verification (red-green, no goldbricks)

The suite contains a fixture corpus (byte-exact: template + JSON → expected
Textile **and** Markdown, including trailing-newline behavior) and error fixtures
(message-checked including line/column), plus GFM table expectations and unit
tests. Two compile-time mutant modes let anyone *prove* the tests fail against
degraded engines:

```sh
zig build test                                # expects: all pass
zig build test -Dengine-mode=passthrough      # goldbrick: engine returns the template unchanged -> MUST fail
zig build test -Dengine-mode=markdown         # wrong default dialect -> MUST fail
```

The table below is **generated** by `tools/verify.sh` from a real run and
re-asserted by CI on every push and pull request: if the committed table ever
disagrees with what a run actually reports, the build fails. Regenerate it
locally with `tools/verify.sh --update-readme`.

<!-- verify-table:start -->
| Mode | Result |
| --- | --- |
| `normal` | 85 passed, 0 failed |
| `passthrough` | 0 passed, 85 failed |
| `markdown` | 0 passed, 85 failed |
<!-- verify-table:end -->

CI runs builds and tests on Linux and macOS at Zig 0.17.0. The verification
job runs on Linux; the counts are platform-independent.

Every test re-asserts Textile-specific syntax (`h1. `, `bq. `, `*bold*`,
`_italic_`, `"text":url`, `|_. …|`) through a dialect guard, so neither
passthrough output nor Markdown emission can satisfy it.

`tools/verify.sh` runs all of the above plus CLI smoke checks (the three
examples compared byte-for-byte; error paths exit 1 with empty stdout), lint
smoke checks (the clean corpus lints clean; broken templates are rejected
with the expected teaching rule), init smoke checks (create, idempotent
rerun, supersede-with-archive, user files untouched) and a static cross-build check
(`-Dtarget=x86_64-linux-musl`, verified with
`file(1)` as "statically linked"; the macOS host build links the system libc,
which is a platform constraint).

### Differential boundary

`tools/differential/package-lock.json` pins the official black-box knap CLI
to **0.6.0** and records its npm integrity hash and transitive dependency.
The harness uses only `knap render` and `knap --version`; no TypeScript source
is read. `tools/differential/cases.json` and `expected.json` commit the
templates, data and oracle stdout. The suite checks exact stdout from both
programs, a pinned oracle snapshot, exit status, empty stdout on errors,
diagnostics, timeouts and crashes. It covers headings, phrase filters,
chains, lists, empty and missing data, comments, nested loops, whitespace
and malformed templates. Every `.markdown` fixture also runs through
[Oliver](https://github.com/drawmeanelephant/oliver) as a CommonMark parser,
with structural assertions for headings, emphasis, links, code, lists and
HTML tables. Raw HTML is rejected for non-table cases. CI builds Oliver at
`a45aa5ede557ea7cf7de727bdba61c1f80af544b`.

**Full byte parity with knap is not possible without changing existing k4o
template semantics.** The harness explicitly enumerates 12 existing fixtures
outside that shared subset in
`EXCLUDED_FIXTURES` and still checks their Markdown bytes and Oliver parse.
The conflicts are:

- Knap 0.6.0 rejects k4o's `codeblock` and `numbered` filter names.
- Knap's `link` takes a URL input and label argument, the reverse of k4o.
- Knap compares structured values by identity; k4o compares structure.
- Two nested/adjacent standalone-tag cases trim whitespace differently.

Changing these in only one backend would violate the shared template and data
contract. The differential suite has zero divergences **in its compatible
corpus**, not over the entire language. The same job also runs `k4o lint`
over every case template — the backend's own fixtures: ok cases must lint
clean without data, and the deliberately broken cases must be rejected with
teaching output (data-dependent breakage like a loop over a non-array stays
invisible to a static lint and is checked at render time instead). Markdown-only adversarial tests also
check that punctuation and HTML in data cannot silently turn headings,
emphasis or list items into different CommonMark nodes. Code-content
regressions check empty and all-space spans, preserved boundary spaces and
backticks, and fences with zero, one, or multiple terminal newlines through
Oliver, with identical GFM/Markdown bytes.

Scalar `list` and `numbered` items escape ordered-list markers such as
`1. text`, `1) text` and their multi-digit forms at the start of a line
(including up to three leading spaces). They stay literal item text; genuine
nested arrays still create nested lists. This intentionally differs from
knap's bytes for those markers and is checked structurally through Oliver,
not added to the byte-parity corpus. Markdown and GFM emit identical escapes;
Textile and raw interpolation remain unchanged.

Nested `numbered` lists start at their preceding parent's content column:
three spaces after `9.`, four after `10.`, five after `100.`, and so on.
These offsets accumulate through the supported three levels. Oliver checks
the actual parent/child relationships at marker-width transitions, not
parity with knap's tab indentation. Sibling numbering and Textile are unchanged.

`examples/table` and `fixtures/filter-table-basic` now byte-match knap 0.6.0
under `--format gfm` against committed `.gfm` expectations. They are not
excluded. Their unchanged `.markdown` expectations still run through Oliver
as HTML tables. Every non-table fixture also verifies GFM/Markdown byte parity.

## Clean-room record

k4o is a clean-room implementation: behavior was derived from Knap's
**user-facing documentation**, the Textile specification and black-box CLI
observations. Knap's TypeScript source was never read. The Markdown backend
is checked through Oliver's CommonMark 0.31.2 parser.

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

Zig 0.17 standard library documentation (local toolchain) was used for
language and library APIs only.

## Rollback / uninstall

Nothing is installed system-wide. To undo this work: `git revert <commit>`
(or check out the parent revision), or simply delete the repository and its
build outputs (`zig-out/`, `.zig-cache/`). No global state, config, or
shell files are touched.

## License

MIT — see [LICENSE](LICENSE).
