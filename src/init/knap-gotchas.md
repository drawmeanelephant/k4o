<!-- k4o init knap-gotchas v7 -->
# knap gotchas

The sharp edges, in order of how often they bite. Everything here is
verified behavior of the local `k4o` engine — not folklore.

## Spaced names — `{{ my field }}` — but operator words end them

Names inside `{{ }}` may contain spaces, but only non-keyword words
join the name. `and`/`or`/`not`/`contains`/`in` (plus `true`/`false`/
`null` and the tag keywords) are always read as operators:

```text
{{ a or b }}            the condition `a or b` — `false` when both are
                        falsy, even if a variable literally named
                        "a or b" exists
{{ my or field }}       `my or field` — `or` splits mid-name
{{ a in b }}            parse error — `in` is reserved
{{ a andy b }}          a variable named "a andy b" — `andy` is not a
                        keyword, so the whole run joins
{{ a && b }}            works — symbols are not name characters
{{ not a }}             works — `not`/`!` at the front is fine
```

The same grammar applies inside parentheses and in `{% if %}`:
`{{ (a or b) }}` is the condition `a or b`, never the spaced name.

## `{{- -}}` and `{%- -%}` are rejected

`knap help syntax` documents dash whitespace trimming, but the 0.6.0 CLI
rejects it (`PARSE_ERROR`) — k4o matches the oracle, not the docs. Use
standalone lines and inline tags; the whitespace model below is the
control you actually get.

## `??` binds looser than everything — and falls through to the last term

```text
{{ x ?? y == "z" }}     means x ?? (y == "z") — a truthy x wins as itself,
                        otherwise the comparison's true/false renders
{{ a ?? b ?? c }}       all falsy → renders c's falsy value ("", 0, false)
{{ t ?? "D" | upper }}  the filter binds to "D" only — {% set %} first
                        if the winner should carry the filter
```

## Filters cannot sit left of a comparison

`{{ x | upper == "Y" }}` is a syntax error anywhere a condition lives —
`{% if %}`, `{% set %}` and `{{ }}` alike. Filter the right side:
`{{ x == y | upper }}`.

## Singleton arrays unwrap to their element

`{{ ["a"] }}` prints `a`, `{{ [7] }}` prints `7`. The unwrap happens at
interpolation for a one-element array holding a primitive (null and
containers stay arrays). Filters that stringify see the element too;
collection filters still see the array.

## Strings holding JSON get re-parsed by filters

A pipeline value that is a *string* containing a JSON array or object
(`"[1,2]"`, `'{"a":1}'`) is parsed into a real value before a filter
runs — `{{ s | length }}` on `"[1,2]"` counts 2, not 5 characters. The
rule exists so serialized collections chain; it also means data that
happens to look like JSON is silently retyped. `parse_json` makes the
same conversion explicit.

## Containers compare by identity, not structure

`==`, `!=` and `contains` on arrays/objects ask "same node?", not "same
contents?":

```text
{"a":[1],"b":[1]}  →  {{ a == b }}   is false — two nodes, same bytes
{% set s = a %}    →  {{ s == a }}   is true  — one node, two names
```

Numbers compare by value (`2 == 2.0` is true), strings by text. To test
container contents, compare a property: `{{ a[0] == b[0] }}`.

## `{% set %}` inside a loop outlives the iteration

A `set` writes to the innermost loop's scope — shared across every
iteration of that loop, dropped at `{% endfor %}`:

```text
{% for i in xs %}{% if i == 1 %}{% set c = "one" %}{% endif %}{{ c }}{% endfor %}
→ c reads "one" in iteration 2 as well; outside the loop c is missing
```

`{% if %}` does not open a scope — a set in an if-branch lands in the
enclosing scope (the loop's, or the globals).

## `--set key=value` stores strings

`k4o render t.knap --set draft=true` puts the *string* `"true"` over the
data key — truthy like `true`, but `{{ draft == true }}` is false.
Repeatable; overrides only top-level keys; needs a JSON-object data root.
For typed values use `--data-json`.

## Whitespace: the rules that move bytes

- A line of only whitespace plus `{% %}`/`{# #}` tags renders nothing —
  tag and newline both go. This is why logic on its own lines is free.
- An inline opener eats the body's leading spaces/tabs on the same line
  once: `{% if x %}  hi{% endif %}` → `hi`.
- The newline after `{% endif %}`/`{% endfor %}` is real output.
- `{% endfor %}` at column 0 eats the newline ending the line before it
  (`…{{ i }}\n{% endfor %}` ends clean); indented `{% endfor %}` keeps
  that whitespace inside the body — it lands between iterations.
- Loop iterations join with ONE `\n` separator, emitted only when the
  body produced output; the loop also trims trailing spaces/tabs once.
- The newline before a standalone `{% elseif %}`/`{% else %}`/`{% endif %}`
  is consumed — branches join tight.

## `link` orientation: value is the URL, argument is the text

`{{ url | link:"Example" }}` → `[Example](https://…)`, and with no
argument the label is `link`. Arrays give one link per line; objects map
`key=URL` → `value=text`. `image` works the same way (`![alt](url)`).
`javascript:`, `vbscript:` and `data:` are refused — even spelled with
character references (`javascript&colon;…`, `&#106;avascript:…`), which
a CommonMark renderer would resolve.

## Missing values are safe — most things are not

Absent paths render empty and are falsy; `{% for i in missing %}`
iterates nothing. But a `for` over a *present* non-array is a render
error, and so is `list`/`table` on a scalar or `link` on a non-URL input,
etc. Errors are buffered: stdout stays empty, stderr gets the diagnostic,
exit is 1.

## Truthiness and `{}`

`false`, `null`, missing, `""`, `0`, `[]` are falsy; `{}` is TRUTHY —
an empty object is a real value. Comparisons `<` `<=` `>` `>=` order two
numbers or two strings only; anything else is simply not ordered (the
condition is false, no error).

## Numbers print JavaScript-style

`2.0` renders `2`; `1e21` in data renders `1e+21` — the f64 printer uses
JS `Number.toString` rules, and a number that only fits in a double (past
the i64 range, or a float literal) can lose precision like a JS double.
`length`, `slice` and `reverse` count UTF-16 code units — an astral emoji
is 2 units, and a `slice` that cuts a surrogate pair re-encodes as `�`.

## Batch filenames are basenames, sanitized

`k4o batch --filename '{{ title | safe_name }}.md'` renders the name per
row, then trims whitespace and refuses anything containing `/` or `\`,
or made only of spaces, dots, dashes and underscores (that row's batch
fails, naming the offending name). Duplicate output names always fail;
`--overwrite` only governs pre-existing files on disk. Default names:
`N.md` (1-based) for CSV/JSON rows, `<stem>.md` for folder records.

## Blocked filters error at render

`html_to_json` and `remove_html` are registered but need DOM APIs an
embeddable engine does not have — they fail the render with a
diagnostic, and `k4o lint` flags them ahead of
time. `validate` cannot catch them (it only parses).

## Comments end at the first `#}`

`{# a #} b #}` — the second `#}` is literal text. Comments do not nest
and an unclosed `{#` is a syntax error. A comment removes only its own
bytes: `{# gone #}` alone on a line leaves the indentation and the
newline behind — a blank line. Put comments inline, or share the line
with a `{% %}` tag to keep output clean.

## Literal `{{`/`{%`/`{#` — `{% raw %}`

Tags are live everywhere — code spans and fenced blocks included — so a
template cannot print knap syntax unaided. `{% raw %}…{% endraw %}`
emits the bytes between the tags verbatim:

```text
{% raw %}Use {{ title }} inside {% if x %}…{% endif %}{% endraw %}
```

renders exactly that text. The tags follow the usual whitespace rules —
a standalone `{% raw %}` eats its line end like `{% if %}`, and a
column-0 `{% endraw %}` on a clean line swallows the body's trailing
whitespace like `{% endif %}`. The first `{% endraw %}` wins — blocks
do not nest — so a literal `{% endraw %}` must come from a quoted
literal: `{{ "{% endraw %}" }}`. The same trick covers one-off escapes
anywhere: `{{ "{% if x %}" }}` renders `{% if x %}`.

`{% raw %}` is a k4o extension — knap 0.6.0 rejects it as an unknown
tag — so it is for k4o-only templates, not shared ones.
