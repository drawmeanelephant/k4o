<!-- k4o init knap-examples v5 -->
# knap worked examples

The three examples shipped with k4o, end to end: template, data, and the
exact bytes out. `--format markdown` is the default and knap-faithful;
`--format oliver` differs only for `comment` (`<!-- -->`); Oliver ≥1.3
parses `highlight`'s `==x==` and `math`'s `$…$`/`$$…$$` natively.

## Heading — `{{ value | filter }}` and chains

Template (`heading.knap`):

```text
{{ title | h1 }}

{{ subtitle | italic }}
```

Data (`heading.json`):

```json
{"title":"The Machine Stops","subtitle":"A reading note"}
```

Output:

```text
# The Machine Stops

*A reading note*
```

## List — arrays and the `list` filter

Template (`list.knap`):

```text
{{ "Sections" | h2 }}

{{ sections | list }}
```

Data (`list.json`):

```json
{"sections":["The Air-Ship","The Mending Apparatus","The Homeless"]}
```

Output:

```text
## Sections

- The Air-Ship
- The Mending Apparatus
- The Homeless
```

`list:numbered` emits `1.`/`2.`/…, `list:task` emits `- [ ]`.

## Table — arrays to pipe tables

Template (`table.knap`):

```text
{{ rows | table }}
```

Data (`table.json`):

```json
{"rows":[["name","age"],["Walter","5"],["Florence","6"]]}
```

Output — a compact pipe table; an array of arrays gets an empty header
row unless you pass `table:("Name", "Age")`:

```text
|  |  |
| - | - |
| name | age |
| Walter | 5 |
| Florence | 6 |
```

An array of objects uses its keys as the header instead:

```text
{{ people | table }}        with [{"name":"Ada","role":"Engineer"},…]
```

```text
| name | role |
| - | - |
| Ada | Engineer |
```

## Combining: `set`, `for` and `if` in one template

Template:

```text
{% set slug = title | kebab %}# {{ title }}

{% for tag in tags %}- #{{ tag | kebab }}
{% endfor %}

{% if draft %}DRAFT{% endif %}
```

Data:

```json
{"title":"Reading Notes","tags":["science fiction","novel"],"draft":true}
```

Output:

```text
# Reading Notes

- #science-fiction
- #novel

DRAFT
```

What happened, line by line: the `{% set %}` shares its line with text,
so it emits nothing and only trims leading whitespace; the loop body's
own newline is the per-iteration separator and the column-0 `{% endfor %}`
eats the body's trailing newline; the `{% if %}` line holds `DRAFT`, so
it is inline — the blank line before `DRAFT` is the empty line written in
the template, and with `draft` false the tail is just whitespace.

## Reproduce these locally

```sh
k4o lint examples/heading.knap
k4o render examples/heading.knap --data examples/heading.json
k4o render examples/heading.knap --data examples/heading.json --format oliver
k4o render -t '{{ x ?? "fallback" | upper }}' --data-json '{}'
```

Errors exit 1 with a diagnostic on stderr and nothing on stdout — output
is buffered, so a failed render never half-emits.
