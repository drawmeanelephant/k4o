<!-- k4o init knap-gotchas v4 -->
# knap gotchas

The sharp edges, in order of how often they bite. Everything here is
verified behavior of the local `k4o` engine — not folklore.

## Nested loops multiply

A loop over N items runs its body N times, so L nested loops over
N-element arrays render N^L times. Three nested loops over 300-element
arrays is 27 million iterations from three lines of template.

`k4o render` caps output at 256 MiB by default and fails with a diagnostic
naming the loop depth instead of exhausting memory:

```sh
k4o render t.knap --data d.json --max-output=64m   # k/m/g suffix, 0 = no cap
```

## Whitespace: what is eaten, what is kept

- One newline immediately after an opening tag (`{% if %}`, `{% elseif %}`,
  `{% else %}`, `{% for %}`) is consumed — once. A second newline stays.
- The newline before a closing tag (`{% endif %}`, `{% endfor %}`) is
  **kept**. If your output has a stray blank line, look here first.
- In Markdown/GFM output, loop iterations join with a newline and one
  body-final newline is removed, so `{% for x in xs %}{{ x }}\n{% endfor %}`
  does not grow blank lines between items.
- `{%- … -%}` whitespace-control operators are not in the subset; they are
  a syntax error.

## Filter arguments: bare vs quoted

`link:url` resolves the top-level data key `url` and falls back to the
literal word `url` only when no such key exists. `link:"url"` is always the
literal. Only top-level keys resolve — `link:a.b` is a syntax error. A bare
key holding `null`, an object or an array is a bad-argument error, not a
silent fallback.

## `link` refuses scripts, not navigation

`javascript:`, `vbscript:` and `data:` (any case) are refused because they
execute in a renderer. `http:`, `https:`, `mailto:`, `ftp:`, `file:` and
relative paths pass. The URL must not contain whitespace, ASCII control
characters or `"`, and must not start with `<`; the link text must not
contain `"`.

## Truthiness surprises

`0`, `""`, `[]`, `null` and missing values are all falsy; `{}` (empty
object) is **truthy**. Comparisons: `==`/`!=` are structural (objects and
arrays compare member-wise, key order irrelevant); `<` `<=` `>` `>=` work
on two numbers or two strings only — anything else is simply not ordered.

## Structured values render as JSON

`{{ data }}` with an object or array emits compact JSON, key order
preserved from the input. Reach for the field instead: `{{ data.k }}`.

## Floats are lossy

`{"a":2.0}` renders as `2`: scalar interpolation emits a whole-number float
and the equal integer as the same bytes. Numeric equality does not recover
the distinction — it compares the numeric value, not the integer/float
representation — so `{% if a == 2 %}` is true for both `2` and `2.0`.

## Phrase filters take one line

`h1`–`h6`, `bold`, `italic`, `code`, `blockquote`, `link` require
single-line text; a value with a newline is a render error. Use `codeblock`
for multiline content.

## Codeblock content with blank lines emits `bc..`

Textile's single-block `bc.` signature ends at the first blank line, so
`codeblock` content with a blank line and more content after it is emitted
with the extended `bc..` signature instead — that form holds until the next
block signature or the end of input, keeping the tail inside the code block.
The same rule means template text directly after such a code block is
absorbed into it unless that text starts with a block signature
(`p. `, `h2. `, `bq. `, …). Content without blank lines keeps `bc. `.

## Lists and tables need arrays

`list`/`numbered`/`table` on a non-array is a render error. List nesting
beyond 3 levels is an error. Table rows must share one cell count, and
cells must not contain `|` or newlines.

## Comments are removed, never evaluated

`{# … #}` can span lines and its contents are not parsed as template. An
unclosed `{#` is a syntax error.

## Missing values are safe

Absent paths render empty and are falsy in conditions — they never throw.
Guard with `{% if optional %}` when absence means something different from
empty.

## k4o's names differ from knap 0.6.0

`codeblock` (knap: `code_block`) and `numbered` (knap: `list:numbered`);
k4o's `link` takes text as input and the URL as argument (knap: the
reverse). The official knap CLI will reject k4o-style templates for these —
trust `k4o lint` for what runs in the local binary.
