<!-- k4o init knap-tour v4 -->
# knap in one page

Knap is a template language: template + JSON data in, Markdown-family text
out. This file documents knap 0.6.0 as the local `k4o` engine implements
it — the full language, byte-faithful to the knap CLI. Verify anything you
write with:

```sh
k4o validate template.knap    # parse check, no data needed
k4o lint template.knap        # parse + filter registry + URL rules
k4o render template.knap --data data.json
k4o help syntax|filters|tags  # the knap help text, offline
```

## Interpolation: `{{ ... }}`

```text
{{ title }}                 the data key "title"; missing renders empty
{{title}}                   whitespace around the expression is optional
{{ "text" }} {{ 'x' }}      string literals, single or double quoted
{{ "a\nb" }}                escapes: \n \t \r emit control bytes; any
                            other \X drops the backslash (\q is q)
{{ 7 }} {{ 1.5 }} {{ -3 }}  number literals; JS-style printing
{{ true }} {{ false }} {{ null }}
{{ First name }}            names may contain spaces inside {{ }}
```

A value resolving to an object or array renders as compact JSON (key order
preserved). A single-element array holding a primitive renders as the
element — `{{ ["a"] }}` prints `a`.

## Paths

```text
{{ author.name }}              dotted properties
{{ authors[0].name }}          bracket index (a number)
{{ meta["article:section"] }}  bracket key (a quoted string)
{{ xs[i] }}                    dynamic bracket: any single expression —
{{ xs[loop.index0] }}          resolves a string key or a numeric index
{{ xs["1"] }}                  a quoted numeric key indexes arrays too
```

Bracket expressions take one value — no filters, no `??` inside `[]`.

## Fallback: `a ?? b`

```text
{{ title ?? headline ?? "Untitled" }}
```

The first truthy term wins and contributes its value. `??` binds LOOSER
than filters, comparisons and boolean ops — `x ?? y == "z"` reads
`x ?? (y == "z")`. When no term is truthy the last term's value renders
(`{{ a ?? b ?? c }}` all-falsy prints whatever `c` is: `""`, `0`, `false`).

## Output expressions: `{{ }}` takes the full condition grammar

```text
{{ a == b }}             renders true or false
{{ n >= 3 && ok }}
{{ not draft }}          or {{ !draft }}
{{ (a && b) || !c }}     == != < <= > >= contains, and/&& or/|| not/! ()
```

One catch: because names inside `{{ }}` may contain spaces, word
operators after a bare name are absorbed into the name — `{{ a or b }}`
looks up a variable literally named "a or b" (usually empty, no error),
even inside parentheses. Use `&&` `||` `!` in output tags, or move the
condition into `{% if %}`; `not`/`!` at the front and the comparison
symbols are always safe (`{{ a == 1 and b }}` parses — a comparison ends
the operand, so `and` lands as an operator).

Filters are allowed only on the RIGHT side of a comparison:

```text
{{ x == y | upper }}     ok — y is filtered, then compared
{{ x | upper == "Y" }}   syntax error: filters are not allowed on the
                         left side of a comparison
```

## `{% set name = expr %}` — assignment

```text
{% set slug = title | kebab %}{{ slug }}
{% set ok = a == 1 or b ?? "n" %}    any chain expression is legal
```

Assignments evaluate in order and emit nothing. A `set` inside a loop
writes to that loop's scope — visible for the rest of the loop, dropped
at `{% endfor %}`. `{% if %}` does not open a scope.

## `{% if %} … {% endif %}`

```text
{% if draft %}…{% else %}…{% endif %}
{% if a %}…{% elseif b %}…{% else %}…{% endif %}
```

All boolean operators work here, word forms included (the spaced-name
rule is an output-tag feature only). `contains` checks for a substring in
a string or an element in an array. Truthiness: `false`, `null`, missing,
`""`, `0` and `[]` are false; everything else — including `{}` — is true.
Comparisons: `==`/`!=` compare numbers by value, strings by text, and
containers by identity; `<` `<=` `>` `>=` order two numbers or two
strings only. No `{% else %}` on `for`.

## `{% for %} … {% endfor %}`

```text
{% for item in items %}{{ loop.index }}. {{ item.name }}
{% endfor %}
```

Inside a loop: `loop.index` (1-based), `loop.index0`, `loop.first`,
`loop.last`, `loop.length`, and `item_index` — a 0-based counter named
after the loop variable (`{% for x in xs %}` gets `x_index`). The loop
variable, `loop` and `x_index` shadow data of the same name. Iterations
join with a newline; a loop that emits nothing emits nothing. Iterating a
missing or null value is empty; iterating any other non-array is a render
error.

## Comments: `{# … #}`

```text
A {# removed, never evaluated #} B
{# may span
   lines #}
```

Comments end at the first `#}` and do not nest; an unclosed `{#` is a
syntax error. A comment removes only its own text — the whitespace around
it stays, so `{# gone #}` on its own line leaves a blank line.

## Whitespace

- A line holding only whitespace plus `{% %}`/`{# #}` tags is
  *standalone* for logic tags: the `{% %}` tag and the newline render
  nothing. Logic on its own lines never leaves blank lines behind.
  ({# #} comments don't eat their own line — only the comment text goes.)
- An inline opener (`{% if x %} A {% endif %}`) eats the leading
  spaces/tabs of the body it opens, once.
- The newline AFTER `{% endif %}` or `{% endfor %}` is real output.
- `{% endfor %}` at column 0 eats the one newline ending the line before
  it; an indented `{% endfor %}` keeps that whitespace inside the body,
  where it lands between iterations.
- `{{- x -}}` and `{%- x -%}` dash markers are a SYNTAX ERROR — the 0.6.0
  CLI rejects them too, even though `knap help syntax` claims them.

## Filters: `{{ value | filter }}`

Chains run left to right: `{{ title | trim | upper }}`. Arguments follow
a colon:

```text
{{ x | f:2 }}              bare word or number — a word shaped like a
{{ x | f:url }}            path resolves against data first and falls
                           back to its literal text (link:url reads
                           data.url; link:missing sends the word
                           "missing"); other bare tokens are literal
                           (list:numbered-task, nth:2n, split:[0-9])
{{ x | f:"lit" }}          quoted — always the literal text
{{ x | f:(a, 4, "s") }}    parenthesized multi-argument
{{ x | f:"k":"v" }}        key:value pairs (replace, where, …)
{{ x | map:i => i.name }}  arrow expression: item => path, literal,
                           ({k: v}) object, or "pre/${i}" string
```

## The filter registry

Every name knap 0.6.0 ships; `k4o help filter <name>` gives parameters
and examples for each.

| Group | Filters |
| --- | --- |
| Markup | `h1`–`h6` `bold` `italic` `code` `code_block` `blockquote` `list` `link` `image` `hr` `hard_break` `escape_md` `fragment_link` |
| Extensions | `callout` `wikilink` `footnote` `strike` `table` `table_pretty` `highlight` `math` `math_block` `comment` |
| Text | `camel` `capitalize` `kebab` `lower` `pascal` `snake` `title` `uncamel` `upper` `trim` `truncate` `truncatewords` `indent` `unescape` `safe_name` `encode_uri` `decode_uri` |
| Numbers | `calc` `number_format` `round` |
| Dates | `date` `date_modify` `duration` |
| Collections | `compact` `first` `join` `last` `length` `merge` `nth` `object` `parse_json` `reverse` `slice` `sort` `split` `sum` `unique` `where` |
| Advanced | `map` `template` `replace` `yaml` `yaml_property` |
| HTML | `remove_attr` `strip_attr` `remove_tags` `replace_tags` `strip_tags` `strip_md` (+ alias `stripmd`) |
| Blocked | `embed` `html_to_json` `remove_html` — need a host environment (DOM, vault resolver); registered so the error is explicit, and `lint` flags them |

`link` and `image` take the URL as INPUT and the label/alt text as the
argument: `{{ url | link:"Example" }}` → `[Example](url)`. `link` refuses
`javascript:`, `vbscript:` and `data:` URLs — including character
references that decode into one (`&#106;avascript:`).

## Output formats and errors

```sh
k4o render t.knap --data d.json                     # markdown (default)
k4o render t.knap --data d.json --format oliver
```

`markdown` is the knap-faithful byte surface. `oliver` is the same bytes
plus HTML for the three constructs plain Markdown cannot carry:
`highlight` → `<mark>`, `math` → `<span class="math">`, `comment` →
`<!-- -->`. There is no `textile` or `gfm` format.

Rendering buffers completely: on any error stdout stays empty, the
diagnostic (kind, line, column, detail) goes to stderr, exit is 1.
`--max-output` bounds every emitted byte including inside loops —
nested-loop amplification trips the cap, not the allocator (default
256 MiB; `k`/`m`/`g` suffixes, `0` = no cap).
