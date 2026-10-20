# k4o

[![CI](https://github.com/drawmeanelephant/k4o/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/k4o/actions/workflows/ci.yml)

A Knap template engine in Zig — byte-compatible with the knap **0.6.0** CLI.

The name is a nod: *Knap for Oliver* — Oliver being the sibling project that
parses CommonMark. Short name, plain job.

Knap (Obsidian's template language) turns data into Markdown. k4o implements
the full 0.6.0 language — every logic tag, `{% set %}`, the `??` fallback,
bracket key expressions, the multi-parameter filter grammar, and the complete
CLI filter registry — and emits the same bytes as the official CLI, which the
differential suite verifies case by case against the black-box oracle.
The sibling [Oliver](https://github.com/drawmeanelephant/oliver) parses the
output downstream, and [dogbed](https://github.com/drawmeanelephant/dogbed)
embeds this library. The production binary is Zig, stdlib only, with no Node
or network dependency. Official knap is installed only for differential
tests.

```text
template.knap + data.json ──> k4o ──> CommonMark ──> Oliver ──> HTML
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
zig-out/bin/k4o render template.knap --data=data.json --format oliver
zig-out/bin/k4o render -t 'hi {{ name }}' --data-json '{"name":"Ada"}'
zig-out/bin/k4o render template.knap --data data.json --set draft=true -o out.md
zig-out/bin/k4o batch template.knap --data rows.csv --output-dir out --filename '{{ title | safe_name }}.md'
zig-out/bin/k4o validate template.knap
zig-out/bin/k4o lint template.knap
zig-out/bin/k4o lint one.knap two.knap
zig-out/bin/k4o help filters
zig-out/bin/k4o help filter table
zig-out/bin/k4o init
zig-out/bin/k4o --help
zig-out/bin/k4o --version
```

- `render` writes CommonMark by default; `--format oliver` selects the
  Oliver-targeted variant. No trailing newline is added: the output bytes
  are exactly the rendered template.
- The template comes from a file, `-` or piped stdin, or `-t`/`--template`
  inline text. Data comes from `-d`/`--data FILE` (or `-` for stdin),
  `--data-json '<json>'`, and repeatable `--set key=value` overrides (string
  values, merged last). Only one input may read stdin. Without data the
  variables default to `{}`.
- `-o`/`--output FILE` writes the buffered render to a file (parent
  directories are created; `-` means stdout, the default).
- `--max-output` (or `-m`) caps rendered output; see
  [Output size](#output-size). Defaults to 256 MiB; `0` means no cap.
- Exit codes: `0` on success, `1` on any error. The message goes to stderr
  and stdout stays empty — rendering is buffered, so partially rendered
  output is never emitted.

### Output formats

- `markdown` is the default and the knap-faithful mode: on the implemented
  surface the bytes are identical to the knap 0.6.0 CLI, and the
  differential suite asserts that on every corpus case and fixture. That
  includes knap's own idioms — pipe tables, `==highlight==`, `$math$` —
  not a curated CommonMark subset.
- `oliver` emits identical bytes everywhere except two spots: `comment`
  becomes `<!-- -->` — Oliver ≥1.3 parses `==x==`, `$…$`/`$$…$$`,
  `![[x]]` and callout folds natively, but a `%%` block only opens at
  line start, so the passthrough survives mid-line values — and `table`'s
  `| - |` delimiter cells widen to `| --- |`, since Oliver's `:?-+:?`
  delimiter grammar needs three hyphens or a colon and the compact form
  would render as a paragraph. The output
  assumes the matching Oliver `ParseOptions` for what it produces:
  `callouts`, `wikilinks`, `embeds`, `footnotes`, `strikethrough`,
  `task_lists`, `highlights`, `math`, `frontmatter` (the `--obsidian`
  preset covers all but `frontmatter`), plus `raw_html=allowed` for the
  comment passthrough.
- The legacy Textile/GFM subset surface was removed for the fidelity work;
  release **v0.1.0** preserves it.

## The knap language

The full knap 0.6.0 language, verified against the black-box oracle (see
the [clean-room record](#clean-room-record)):

| Construct | Syntax | Notes |
| --- | --- | --- |
| Output | `{{ title }}` | Whitespace optional (`{{title}}`). Accepts a condition, not just a value — `{{ a == 1 }}` prints `true`, and `{{ a && b }}`, `{{ !a }}`, `{{ "text" contains "x" }}` work — plus `??` chains. A container renders as compact JSON; a single-element array holding a scalar unwraps to its element. See [Structured values](#structured-values). |
| Paths | `{{ author.name }}`, `{{ authors[0].name }}`, `{{ meta["a:b"] }}`, `{{ xs[loop.index0] }}`, `{{ obj[k] }}` | Dotted properties, numeric indices, quoted keys, or any single-value expression in brackets. `xs["1"]` indexes an array like `xs[1]`. Names may contain spaces (`{{ First name }}`) — operator words (`and`/`or`/`not`/`contains`/`in`, literals, tag keywords) end a spaced name — `{{ a and b }}` is a condition, `{{ a in b }}` is a parse error — so `{{ My title }}` works only because `My`/`title` are not keywords. |
| Fallback | `{{ title ?? headline ?? "Untitled" }}` | First truthy term wins and contributes its value. `??` has the lowest precedence — `a ?? b == c` is `a ?? (b == c)` — and filters bind before it. |
| Literals | `{{ "text" }}`, `{{ 'x' }}`, `{{ 7 }}`, `{{ 1.5 }}`, `{{ true }}`, `{{ null }}` | Usable as values and condition operands. Inside a quoted literal `\n`, `\t` and `\r` produce the control characters; `\"`, `\'` and `\\` produce the quote or backslash; any other `\x` drops the backslash (`\q` is `q`, `\x41` is `x41`), matching knap 0.6.0. The same unescaping applies to quoted filter arguments and bracket keys. |
| Filters | `{{ value \| filter }}`, `{{ value \| filter:"arg" }}`, `{{ value \| filter:(a, b) }}` | Chains run left to right and carry typed values, not text. Parameters: a single value after `:`, several inside `:(…)`, `"key":"value"` pairs, and `x => expr` arrow expressions where a filter accepts one. See [Filter parameters](#filter-parameters). In a comparison, a filter may sit on the right operand (`a == b \| upper`) but not the left. |
| Logic | `{% if expr %} … {% elseif expr %} … {% else %} … {% endif %}` | Operators: `==` `!=` `<` `<=` `>` `>=`, `contains` (substring or array member), `and`/`&&`, `or`/`||`, `not`/`!`, parentheses. `==`/`!=` compare containers by *identity*, not structure — see [Structured values](#structured-values). `<`/`<=`/`>`/`>=` are numbers and strings only. |
| Truthiness | — | `false`, `null`, missing values, `""`, `0`, and `[]` are false; everything else — including `{}` — is true. |
| Loops | `{% for item in items %} … {% endfor %}` | Loop values: `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last`, `loop.length`, plus `{item}_index` — the 0-based counter named after the iterator (`item_index` here). Iterating `null` or a missing value emits nothing; anything else non-array is a render error. Inside a loop `loop` always means the loop object, so a variable bound as `{% for loop in array %}` is unreachable. **Nested loops multiply** — see [Output size](#output-size). |
| Assignment | `{% set slug = title \| kebab %}` | Ordered assignment of a literal, expression or filtered value; produces no output. Assignments land in the innermost scope — inside a loop that is the current iteration's scope, so they die with the loop; `{% if %}` opens no scope. |
| Comments | `{# … #}` | Single- or multi-line; removed from the output; never evaluated; ends at the first `#}`, does not nest; unclosed is a syntax error. |
| Missing values | — | Render as empty text; are false in conditions. |
| Whitespace control | `{{- … -}}`, `{%- … -%}` | **Parse error.** `knap help syntax` documents dash markers, but the 0.6.0 CLI rejects them (`Unexpected character '-'`). Fidelity is to the oracle, so k4o rejects them too — a documented doc-vs-implementation divergence. |

### Whitespace

The model matches the oracle byte-for-byte:

- A logic tag is **standalone** when its line holds only whitespace,
  `{% … %}` tags and `{# … #}` comments besides it. A standalone open,
  mid or set tag (`{% if %}`, `{% elseif %}`, `{% else %}`, `{% for %}`,
  `{% set %}`) consumes the rest of its own line — trailing spaces plus
  one newline — and a standalone `{% elseif %}`/`{% else %}`/`{% endif %}`
  additionally swallows the whitespace run that ends the body before it.
  `A\n{% if x %}\nB\n{% endif %}\nC` renders `A\nB\nC`. Whitespace *before*
  a standalone tag is ordinary emitted text — `A\n  {% if x %}\nB\n{% endif %}`
  renders `A\n  B`.
- A standalone `{% endif %}`/`{% endfor %}` leaves the newline *after* the
  tag in the output.
- An **inline** open or mid tag trims the same-line spaces and tabs at the
  head of the body it opens (`{% if x %} A` → `A`); it never reaches past
  a newline. An inline `{% else %}`/`{% endif %}`/`{% endfor %}` keeps the
  whitespace before it (`{% if x %}A {% endif %}` → `A `).
- Loop iterations join with a newline, emitted only between iterations
  that produced output — a loop of `{% set %}`-only bodies emits nothing
  and leaves no separator. A standalone `{% for %}` strips the body's
  leading whitespace run once, on the first emitted iteration; trailing
  spaces/tabs before `{% endfor %}` are trimmed once after the last
  iteration, so they land between iterations rather than after the last.
- A column-0 `{% endfor %}` also eats the one newline that ends the line
  before it (`B1\n{% endfor %}` ends `B1`); an indented `{% endfor %}`
  leaves that whitespace inside the body instead.

### Structured values

Values flow through pipelines as typed JSON values — filters see arrays and
objects, not serialized text, and chains preserve the type
(`{{ xs | sort | first }}` never re-parses a string). A string that *holds*
serialized JSON is the exception: a `["a","b"]`- or `{"k":…}`-shaped string
is re-parsed before a filter sees it, so `{{ "[1,2]" | list }}` iterates the
array — knap's "serialized collections from another filter are recognized
automatically" rule.

**Comparing them.** `==`, `!=` and `contains` compare containers by
**identity** (JavaScript `===`/SameValueZero): two structurally equal but
distinct objects are not equal, while `a == a` always is:

```text
{% if a == b %}same{% else %}different{% endif %}   {# {"a":{"p":1},"b":{"p":1}} -> different #}
```

`contains` applies the same rule member-wise: `{% if items contains x %}`
matches an object element only when `x` names that same value. Numbers
compare by value, so `1 == 1.0` is true regardless of representation.

**Interpolating them.** An `{{ … }}` that resolves to an object or array
emits compact JSON — `{"k":1,"s":"x"}` — with JSON.stringify's string
escaping and number printing. A single-element array holding a primitive
(string, number, boolean — not `null`) unwraps to its element, so
`{{ ["a"] }}` renders `a`.

Numbers print the JavaScript way: shortest round-trip digits, decimal
notation for exponents in `[-6, 20]`, and `d[.ddd]e±E` outside it — `2.0`
renders `2`, `1e21` renders `1e+21`, `0.0000001` renders `1e-7`. `NaN` and
`Infinity` print as themselves.

Where a filter argument is coerced to text, the coercion is JavaScript's:
an object becomes `[object Object]` and an array joins its elements with
commas.

### Filter parameters

A filter takes parameters after a colon. The forms:

| Written as | Meaning |
| --- | --- |
| `filter:"text"` | The literal `text`. Always. |
| `filter:7` | The literal `7`. |
| `filter:name` | The value of `name` resolved like a variable (dotted paths included), **or** the literal word `name` if it resolves to nothing. |
| `filter:(a, b)` | Several parameters, each a value expression: `{{ t \| truncate:(100, "…") }}`, `{{ rows \| table:("Name", "Age") }}`. |
| `filter:"k":"v"` | A key/value pair (`replace`, `where`); unparenthesized lists continue after a pair: `replace:("a":"b", "c":"d")`. |
| `filter:x => expr` | An arrow expression (`map`): `x => x.name`, `x => ({name: x.name})`, `x => "pre/${x}"`. |

A bare-word parameter that resolves to `null` yields its own text
(`link:url` is `"url"` when `url` is not in the data); a parameter that
resolves to a container coerces the JavaScript way, so `link:obj` passes
`[object Object]` to the filter rather than failing.

### URL schemes in `link` and `image`

`link` takes a URL as its input and an optional label parameter — the
common case is the URL living in the data:

```text
{{ url | link:name }}      with {"url":"https://example.com","name":"Example"}  -> [Example](https://example.com)
{{ url | link:"Example" }}  -> [Example](https://example.com)
{{ url | link }}            -> [link](https://example.com)   (default label)
```

Arrays emit one link per item; an object maps URLs to labels.

The `javascript:`, `vbscript:` and `data:` schemes (matched
case-insensitively) never reach the output: `link` strips the destination
and emits `[label]()`, matching the oracle byte-for-byte; `image` refuses
them with an error. The check is entity-aware — CommonMark resolves entity
and numeric character references inside link destinations, so
`&#106;avascript:`, `&#x6a;avascript:` and `javascript&colon;` are all
`javascript:` in disguise and are treated the same way.

Other URLs are percent-encoded the way the oracle encodes them: space,
`"`, `<`, `>`, `[`, `]`, `(`, `)`, `\`, backtick, ASCII control characters
and non-ASCII bytes each become `%XX`. Navigational and relative URLs —
`http:`, `https:`, `mailto:`, `ftp:`, `file:`, site-relative paths — pass
through; a colon that is not a well-formed scheme, as in `a/b:c`, belongs
to the path. The label is Markdown-escaped (`&` → `&amp;`, `<>_*[]` get a
backslash) so it cannot smuggle markup into the destination's owner.

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

### Depths and limits

Everything the oracle bounds, k4o bounds, with a diagnostic — never a
panic or an abort:

- **Template nesting:** 100 block levels (`if`/`for` nesting).
- **Condition depth:** 100 levels; each `and`/`or`/`not` link costs one and
  each parenthesized group costs two, so 49 nested parens pass and 50 fail.
- **Data and value depth:** 100 levels — input JSON and filter-produced
  values deeper than that are a render diagnostic, matching the oracle's
  `LIMIT_EXCEEDED`.
- **Serialization depth:** 100 — interpolating a container nested deeper
  fails with a diagnostic instead of writing past the serializer's bound.
- **Input size:** template and data files are read up to 16 MiB.
- **Output:** the 256 MiB cap above.

## Filter registry

The complete knap 0.6.0 CLI registry — 78 filters plus the `stripmd`
alias — grouped the way `knap help` groups them. The suite's registry
property test requires every implemented name to carry at least one
fixture; a name still in flight fails with a `not implemented yet`
diagnostic rather than a wrong render. `k4o help filters` prints the list
with one-line descriptions and `k4o help filter <name>` the full
per-filter reference (syntax, parameters, examples) — the captured oracle
text, offline.

| Group | Filters | Notes |
| --- | --- | --- |
| Markup | `h1`–`h6`, `bold`, `italic`, `code`, `code_block`, `blockquote`, `list`, `link`, `image`, `hr`, `hard_break`, `escape_md`, `fragment_link`, `embed` | CommonMark emitters, plus Obsidian `![[x]]`/`![[x|alias]]` embeds — Oliver ≥1.3 parses them under `embeds`. `code` chooses span vs fenced block (multiline or `:lang`); `list` takes `bullet`/`numbered`/`task`/`numbered-task`; `image` maps object URL keys to alt text; `fragment_link` appends `#:~:text=` anchors. |
| Text | `camel`, `capitalize`, `kebab`, `lower`, `pascal`, `snake`, `title`, `uncamel`, `upper`, `trim`, `truncate`, `truncatewords`, `indent`, `unescape`, `safe_name`, `encode_uri`, `decode_uri` | Casing, whitespace and URI transforms. Most recurse over arrays (and, per filter, object values): `["a","b"] \| upper` → `["A","B"]`. |
| Numbers | `calc`, `number_format`, `round` | `calc:"+10"`, `*2`, `**3` — `+ - * / ** ^`. |
| Dates | `date`, `date_modify`, `duration` | Format tokens, interval math (`"+1d"`), ISO 8601 durations. |
| Collections | `compact`, `first`, `join`, `last`, `length`, `merge`, `nth`, `object`, `parse_json`, `reverse`, `slice`, `sort`, `split`, `sum`, `unique`, `where` | Typed values end to end. `nth` takes pattern syntax (`nth:3`, `nth:2n`, `nth:n+3`); `sort:"prop"` sorts object arrays; `where:("status", "draft")` filters by property. |
| Extensions | `callout`, `wikilink`, `footnote`, `strike`, `table`, `table_pretty`, `highlight`, `math`, `math_block`, `comment` | Obsidian-flavored constructs. `table`/`table_pretty` emit pipe tables — headers from object keys or `:(h1, h2)` parameters. Two filters diverge under `--format oliver`: `comment` switches to `<!-- -->` because a `%%` block only opens at line start (Oliver ≥1.3 parses `==…==`, `$…$`/`$$…$$` natively), and `table` widens its `| - |` delimiters to `| --- |` for Oliver's `:?-+:?` grammar. |
| Advanced | `map`, `template`, `replace`, `yaml`, `yaml_property` | `map` takes a property name or an arrow (`x => ({name: x.name})`); `template` interpolates `${prop}`; `replace` takes `"old":"new"` pairs or regexes (`"/[aeiou]/g"`) via a bounded, step-capped engine; `yaml`/`yaml_property` write bounded YAML (block or `flow`). |
| HTML | `remove_attr`, `strip_attr`, `remove_tags`, `replace_tags`, `strip_tags`, `strip_md`, `stripmd` | Clean HTML inside *data* with a tag/attribute tokenizer — no DOM. `stripmd` is the `strip_md` alias. |
| Blocked | `remove_html`, `html_to_json` | Need a DOM that an embeddable engine does not have (upstream segregates the DOM pair itself). Both render and lint fail them with a diagnostic naming the filter. |

## k4o batch

`k4o batch` renders one template against many data rows — a CSV file, a
JSON array, or a folder of JSON objects — writing one file per row:

```sh
k4o batch t.knap --data rows.csv --output-dir out
k4o batch t.knap --data items.json --output-dir out --filename '{{ title | safe_name }}.md' --overwrite
k4o batch -t '{{ name }}' --data-json '[{"name":"a"},{"name":"b"}]' --output-dir out --dry-run
```

- `--data` is the *source*: a `.csv` file (header row names the keys), a
  `.json` array file, a directory of `.json` files, or `-` for stdin
  (JSON). `--format csv|json` overrides the inference; `--data-json`
  takes the array inline.
- `--output-dir` is required and created if needed.
- Output names come from `--filename` — a template rendered against each
  row and sanitized to a basename — else `1.md`, `2.md`, … for CSV/JSON
  rows and `<file stem>.md` for folder sources. Duplicate names are an
  error; existing files are refused without `--overwrite`; `--dry-run`
  lists the would-be paths on stdout and writes nothing.
- `--set key=value` merges into every row before rendering.
- Each row is a normal buffered render, so a failing row aborts the batch
  with its diagnostic on stderr. The summary (`Wrote N files to dir.` /
  `Would write …`) goes to stderr, like the oracle.

## k4o validate

`k4o validate` checks that a template parses — no data, no render:

```sh
zig-out/bin/k4o validate template.knap
zig-out/bin/k4o validate -t '{{ ok }}'
```

```text
template.knap: Template is valid (static checks only; runtime values are not checked).
```

Exit `0` on a clean parse; a broken template exits `1` with the diagnostic
on stderr and empty stdout, same as `render` — it shares the one parser.

## k4o lint

`k4o lint` checks templates against the knap language and teaches the fix.
Knap is new to training data, so agents hallucinate it; lint closes the
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
  syntax, the filter registry, parameter arity, blocked filters, and the
  `link` URL rules that a literal argument already violates. Data-dependent
  failures (a loop over a non-array, a ragged table) are render errors and
  stay with `k4o render`.
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

## k4o help

The offline language reference, embedded in the binary — the captured text
of `knap help` at 0.6.0 (see `tools/differential/oracle-docs/`):

```sh
k4o help syntax            # variables, filter chaining, logic, whitespace
k4o help filters           # every filter, one line each
k4o help tags              # if / elseif / else / endif / for / endfor / set
k4o help filter table      # full reference for one filter
k4o help tag for           # syntax and examples for one tag
```

## Out of scope

Still out, by design — a static Zig binary is the product:

- **Host-dependent filters.** `remove_html` and `html_to_json` (a DOM)
  are registered — `k4o help` documents them — but
  render and lint fail them with a `needs a host environment` diagnostic.
- **Host integrations.** Browser selectors, prompt execution, Markdown
  conversion back ends — the oracle's CLI does not supply them either.
- **Async resolvers.** No async anything; the engine is a pure function
  over bytes.
- **Dash whitespace markers** (`{{- -}}`, `{%- -%}`). Documented by
  `knap help syntax`, rejected by the 0.6.0 CLI; k4o matches the CLI.

## Verification (red-green, no goldbricks)

The suite contains a fixture corpus (byte-exact: template + JSON → expected
Markdown, including trailing-newline behavior), error fixtures
(message-checked including line/column), registry property tests (every
registered filter has a fixture or an accounted status), lint coverage, and
unit tests for engine semantics the corpus does not pin. Two compile-time
mutant modes let anyone *prove* the tests fail against degraded engines:

```sh
zig build test                                # expects: all pass
zig build test -Dengine-mode=passthrough      # goldbrick: engine returns the template unchanged -> MUST fail
zig build test -Dengine-mode=noeval           # tags never evaluate -> MUST fail
```

Tests that do not touch the engine assert `expectNormalEngine`, so they
fail the mutants too — a survivor means the suite stopped discriminating.

The table below is **generated** by `tools/verify.sh` from a real run and
re-asserted by CI on every push and pull request: if the committed table ever
disagrees with what a run actually reports, the build fails. Regenerate it
locally with `tools/verify.sh --update-readme`.

<!-- verify-table:start -->
| Mode | Result |
| --- | --- |
| `normal` | 24 passed, 0 failed |
| `passthrough` | 0 passed, 24 failed |
| `noeval` | 0 passed, 24 failed |
<!-- verify-table:end -->

CI runs builds and tests on Linux and macOS at Zig 0.17.0. The verification
job runs on Linux; the counts are platform-independent.

`tools/verify.sh` runs all of the above plus a ReleaseSafe run, CLI smoke
checks (the three examples compared byte-for-byte; `-t`, stdin, `--set`,
`-o`, `validate`, `help` surfaces; error paths exit 1 with empty stdout;
the `--max-output` trip and its suffix forms), lint smoke checks (the clean
corpus lints clean; broken templates are rejected with the expected
teaching rule), init smoke checks (create, idempotent rerun,
supersede-with-archive, user files untouched) and a static cross-build
check (`-Dtarget=x86_64-linux-musl`, verified with `file(1)` as
"statically linked"; the macOS host build links the system libc, which is
a platform constraint).

## Differential testing

`tools/differential/package-lock.json` pins the official knap CLI to
**0.6.0** and records its npm integrity hash and transitive dependency. The
harness uses only the oracle's own CLI — `knap render` and
`knap --version`; no TypeScript source is read — and captures `knap help`
under `tools/differential/oracle-docs/` (the same text `k4o help` embeds).
`tools/differential/cases.json` and `expected.json` commit the templates,
data and oracle stdout.

`python3 tools/differential/run.py` then checks, for every committed case
and every `fixtures/`/`examples/` template:

- k4o's stdout is **byte-identical** to the oracle's — no exclusion list.
- error fixtures exit 1 with empty stdout and the pinned diagnostic, and
  the oracle rejects them too (both engines refuse; only the message shape
  differs — the oracle's `PARSE_ERROR` texts are not part of k4o's
  surface).
- every Markdown render also parses through
  [Oliver](https://github.com/drawmeanelephant/oliver) with structural
  assertions — expected element tags, real nested lists, no leaked
  template tags, and raw HTML rejected unless the case deliberately
  carries it (adversarial cases check that `<script>` in data can never
  reach the output unescaped).
- `k4o lint` agrees: clean corpus lints clean, broken corpus reports, and
  data-dependent failures stay invisible to a static lint by design.

CI builds Oliver at `967bfdf428ff58b9b6e292d2f0d05184e929fb92` (v1.3.0 —
needs ≥1.3 for the `highlights`/`math`/`comments`/`embeds` parse flags).

## Clean-room record

k4o is a clean-room implementation: behavior was derived from Knap's
**user-facing documentation**, the captured `knap help` text, and black-box
CLI observations of the 0.6.0 binary. Knap's TypeScript source was never
read. The Markdown output is checked through Oliver's parser.

Sources consulted (with pinned revisions; fetched 2026-09-29):

| Source | Revision | Files read | sha256 |
| --- | --- | --- | --- |
| [obsidianmd/knap](https://github.com/obsidianmd/knap) | `6395cb8b5432b3c3495eab43c10b0d637e021592` | `README.md` | `558b4f442b34898e04a669b9860d32ca5795594c0c7951c87ec1cbd335a61556` |
| | | `CHANGELOG.md` | `33d9c1444871100a4b1b12006f985ee3e7b0479f0a184ec83870b35e58cdcda7` |
| | | `website/src/content/docs/variables.md` | `1c75845a372200a39cf73ae362bcaddd4cf302e97f1f6aed962e426146d16a2b` |
| | | `website/src/content/docs/filters.md` | `a0fc8c10ac435c7ac284c3b116b3526f9d02b36eb37c17fa603ecd669fe904df` |
| | | `website/src/content/docs/logic.md` | `8629fcbd8c170769ef0d4a4d45fce2e784ea2d326b291e0ca2529f2917598bd8` |
| | | `website/src/content/docs/cli.md` | `1662d6afb7098a6258ae90f568cdeb23454cb645ede24d1fb79a4647394ba2f9` |
| knap 0.6.0 binary (npm, black box) | `tools/differential/package-lock.json` | `knap help` output — captured under `tools/differential/oracle-docs/` | — |

Zig 0.17 standard library documentation (local toolchain) was used for
language and library APIs only.

## Rollback / uninstall

Nothing is installed system-wide. To undo this work: `git revert <commit>`
(or check out the parent revision), or simply delete the repository and its
build outputs (`zig-out/`, `.zig-cache/`). No global state, config, or
shell files are touched.

## License

MIT — see [LICENSE](LICENSE).
