<!-- k4o init knap-tour v3 -->
# knap in one page

Knap is a template language: template + JSON data in, Markdown-family text
out. This file teaches the exact subset that the local `k4o` engine
implements — every construct below is verified by its test suite, so you can
trust it and copy from it. Verify any template you write with:

```sh
k4o lint template.knap          # syntax and filter-registry check
k4o render template.knap --data data.json
```

## Interpolation: `{{ ... }}`

```text
{{ title }}          the value of the data key "title" (or empty if absent)
{{title}}            whitespace around the expression is optional
{{ "text" }}         a string literal
{{ 7 }} {{ 1.5 }}    number literals
{{ true }} {{ null }}  boolean and null literals
{{ First name }}     names may contain spaces inside interpolation
```

A value resolving to an object or array renders as compact JSON (key order
preserved). Prefer reaching into it: `{{ data.k }}`.

## Paths

```text
{{ author.name }}                 dotted properties
{{ authors[0].name }}             bracket index (a number)
{{ metadata["article:section"] }} bracket key (a quoted string)
```

Brackets take a number or a quoted key only — bracket expressions that
reference variables (like `a[loop.index0]`) are not in the subset.

## Filters: `{{ value | filter }}`

Filters transform a value. Chains run left to right:
`{{ name | italic | h2 }}`.

The complete filter registry (15 names — there are no others):

| Filter | Argument | Emits (Textile form shown) |
| --- | --- | --- |
| `h1` `h2` `h3` `h4` `h5` `h6` | none | `h2. Title` |
| `bold` | none | `*watch out*` |
| `italic` | none | `_very_` |
| `code` | none | `@zig build@` |
| `codeblock` | none | `bc. ` + content (`bc.. ` across blank lines) |
| `blockquote` | none | `bq. Quote` |
| `link` | URL (required) | `"Example":https://example.com/` |
| `list` | none | `* item` (nested `**`) |
| `numbered` | none | `# item` (nested `##`) |
| `table` | none | `\|_. name\|` rows |

Phrase filters (`h1`–`h6`, `bold`, `italic`, `code`, `blockquote`, `link`)
require single-line text. `list`/`numbered`/`table` require arrays. `table`
rows must all have the same cell count, and cells must not contain `|` or
newlines. List nesting goes at most 3 levels deep.

## Filter arguments: `filter:arg`

At most one argument per filter, and how it is written decides what it is:

| Written | Meaning |
| --- | --- |
| `link:"https://example.com/"` | the literal text — always |
| `link:42` | the literal number |
| `link:url` | the value of top-level data key `url`, or the literal word `url` if no such key |

Only top-level keys are consulted: `link:a.b` is a syntax error. If the key
exists but holds `null`, an object or an array, that is a bad-argument error
rather than a silent fallback. Quote the argument to force the literal.

`link` refuses `javascript:`, `vbscript:` and `data:` URLs (they execute in
a renderer); `http(s):`, `mailto:`, `ftp:`, `file:` and relative paths all
pass. The URL must not contain whitespace, ASCII control characters or a
double quote, and must not start with `<`.

## Logic: `{% if %} … {% endif %}`

```text
{% if draft %}…{% else %}…{% endif %}
{% if a %}…{% elseif b %}…{% else %}…{% endif %}
```

Operators: `==` `!=` `<` `<=` `>` `>=`, `contains` (substring or array
member), `and`/`&&`, `or`/`||`, `not`/`!`, and parentheses.

- `==`/`!=` compare whole values structurally: objects and arrays work, key
  order does not matter.
- `<` `<=` `>` `>=` work on two numbers or two strings only; anything else
  is simply not ordered.
- Truthiness: `false`, `null`, missing values, `""`, `0` and `[]` are false;
  everything else is true.

## Loops: `{% for %} … {% endfor %}`

```text
{% for item in items %}{{ item }}{% endfor %}
```

Inside a loop, `loop` exposes `loop.index` (1-based), `loop.index0`,
`loop.first`, `loop.last`, `loop.length`. Iterating a non-array is a render
error. Nested loops multiply — see knap-gotchas.md.

## Comments: `{# … #}`

```text
A {# removed, never evaluated #} B
{# comments may
   span lines #}
```

An unclosed comment is a syntax error.

## Missing values

Missing paths render as empty text and are false in conditions — they never
throw.

## Whitespace (the part everyone gets wrong)

- One newline immediately after an opening tag (`{% if %}`, `{% elseif %}`,
  `{% else %}`, `{% for %}`) is consumed once, so branches and loop bodies
  join naturally.
- The newline before a closing tag is preserved — place it deliberately.
- In Markdown/GFM output, loop iterations join with a newline and one
  body-final newline is removed.

## Where knap-the-language and k4o-the-engine differ from knap 0.6.0

If you cross-check the official knap docs, four deliberate differences:

- knap 0.6.0 has `code_block` and `list:numbered`; k4o names them
  `codeblock` and `numbered`.
- knap's `link` takes a URL as input and a label as argument; k4o does the
  reverse (text input, URL argument).
- knap compares structured values by identity; k4o compares structure.
- Two nested/adjacent standalone-tag whitespace cases trim differently.

k4o's documented subset (this file) is the source of truth for what runs in
the local `k4o` binary.
