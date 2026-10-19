<!-- k4o init knap-templates v5 -->
# knap starter templates

Copy one, replace the data keys, verify with `k4o lint`, render with
`k4o render <file> --data <data.json>` (Markdown out). Literal template
text passes through unescaped — keep markup in filters or hand-write
Markdown; do not hand-write one syntax and expect the other.

## Reading note (heading + emphasis)

```text
{{ title | h1 }}

{{ subtitle | italic }}
```

```json
{"title":"The Machine Stops","subtitle":"A reading note"}
```

`bold:_` / `italic:_` switch to the `__x__` / `_x_` marker forms.

## List page

```text
{{ "Sections" | h2 }}

{{ sections | list }}
```

```json
{"sections":["The Air-Ship","The Mending Apparatus","The Homeless"]}
```

`list` modes: `list:numbered` → `1.`, `list:task` → `- [ ]`,
`list:numbered-task` → `1. [ ]`. Nested arrays nest the list.

## Table

Arrays of objects take their headers from the object keys; arrays of
arrays get a header per column with `table:("Name", "Role")`; a flat
array is one `Value` column. `table_pretty` pads columns to equal width.

```text
{{ people | table }}
```

```json
{"people":[{"name":"Ada","role":"Engineer"},{"name":"Lin","role":"Designer"}]}
```

## Conditional banner

```text
{% if draft %}{{ "DRAFT — not for publication" | bold }}
{% endif %}{{ title | h1 }}
```

```json
{"draft":true,"title":"The Machine Stops"}
```

The `{% if %}` shares its line with the output tag, so it is an inline
opener — it renders nothing itself and the newline before `{% endif %}`
keeps the banner on its own line when `draft` is true; when false the
heading comes first with no gap.

## Fallback chain

```text
{% set t = title ?? headline ?? "Untitled" %}{{ t | h1 }}
```

```json
{"headline":"From the wires"}
```

`??` binds looser than filters — `{{ title ?? "Untitled" | h1 }}` styles
only the `"Untitled"` term — so to style whichever value wins, bind the
chain with `{% set %}` and filter the name. A `{% if %}/{% elseif %}/
{% else %}` chain is the multi-branch form.

## Slug once, use twice

```text
{% set slug = title | kebab %}File: {{ slug }}.md — {{ title | h1 }}
```

```json
{"title":"Reading Notes"}
```

`{% set %}` evaluates in order and emits nothing. Inside a loop the
assignment lives in the loop's scope and is gone after `{% endfor %}`.

## Loop with an index

```text
{% for item in items %}{{ loop.index }}. {{ item }}
{% endfor %}
```

```json
{"items":["Air-Ship","Mending Apparatus","Homeless"]}
```

`loop` also carries `index0`, `first`, `last` and `length`; `item_index`
is the 0-based counter named after the loop variable. A column-0
`{% endfor %}` keeps the output tidy: `1. Air-Ship\n2. Mending
Apparatus\n3. Homeless`.

## Links and images

The value is the URL; the argument is the text:

```text
{{ link.url | link:link.text }}
{{ image.url | image:image.alt }}
```

```json
{"link":{"url":"https://example.com/post","text":"Example"},
 "image":{"url":"cover.jpg","alt":"Cover art"}}
```

An array of URLs maps to one link per line; an object maps `key=URL` to
`value=text`. Blocked schemes (`javascript:`, `vbscript:`, `data:`) are
refused.

## Obsidian-flavored markup

```text
{{ quote | callout:("tip", "Note") }}
{{ page | wikilink:"Alias" }}
{{ refs | footnote }}
{{ spot | highlight:blue }}
{{ expr | math }}
{{ note | comment }}
```

```json
{"quote":"Remember this","page":"Project Atlas","refs":["first","second"],
 "spot":"watch this","expr":"x^2 + y^2","note":"hidden"}
```

These emit Obsidian conventions (`> [!tip]`, `[[Page|Alias]]`, `[^1]:`,
`==text==`, `$…$`, `%%…%%`) that plain Markdown leaves as text; Oliver
≥1.3 parses all of them under `--obsidian`, so `--format oliver` emits
the same bytes — except `comment`, which stays `<!-- -->` because a `%%`
block only opens at line start.

## Front matter from data

```text
---
title: {{ title | yaml }}
year: {{ year | yaml }}
genre:
{{ genres | yaml | indent:2 }}
---
```

```json
{"title":"Reading Notes","year":1999,"genres":["Action","Sci-fi"]}
```

`yaml` keeps strings quoted and numbers/booleans typed; `yaml_property`
emits a complete `name: value` line (or block) itself.

## Many rows, many files — `k4o batch`

```sh
k4o batch card.knap --data rows.csv --output-dir out \
  --filename '{{ title | safe_name }}.md'
```

Data can be a CSV file, a JSON array, or a folder of JSON objects; one
render per row. `--filename` is a mini-template rendered per row (then
sanitized to a basename — pipe through `safe_name`); without it files
are `N.md` for rows and `<stem>.md` for folder records. `--dry-run`
lists the paths, `--overwrite` allows replacing; duplicate output names
always fail.
