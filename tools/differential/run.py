#!/usr/bin/env python3
"""Black-box differential and CommonMark structure checks (no knap source)."""

import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).resolve().parent
KNAP_VERSION = "0.6.0"
TIMEOUT = 8

# These pre-existing Textile fixtures cannot have byte-identical output against
# knap 0.6.0 without changing k4o's language/data semantics. They are still
# checked against .markdown and parsed by Oliver. Tables use opt-in GFM parity.
EXCLUDED_FIXTURES = {
    "fixtures/filter-codeblock-basic": "Knap has code_block, not k4o's codeblock filter",
    "fixtures/filter-codeblock-blank-lines": "Knap has code_block, not k4o's codeblock filter",
    "fixtures/filter-numbered-basic": "Knap has list:numbered, not k4o's numbered filter",
    "fixtures/filter-numbered-nested": "Knap has list:numbered, not k4o's numbered filter",
    "fixtures/filter-link-basic": "Knap takes URL as input and label as argument; k4o does the reverse",
    "fixtures/filter-link-data-arg": "Knap takes URL as input and label as argument; k4o does the reverse",
    "fixtures/filter-link-literal-arg": "Knap takes URL as input and label as argument; k4o does the reverse",
    "fixtures/logic-contains-object": "Knap compares objects by identity; k4o compares structure",
    "fixtures/logic-eq-array-nested": "Knap compares arrays by identity; k4o compares structure",
    "fixtures/logic-eq-object-order": "Knap compares objects by identity; k4o compares structure",
    "fixtures/loop-nested": "Knap strips leading whitespace at nested standalone tags",
    "fixtures/loop-values": "Knap strips whitespace before the following tag",
    "fixtures/var-float-large": "Knap renders extreme floats in exponent notation (1e+308); k4o's subset expands decimal (309 digits)",
    "fixtures/logic-cond-depth-boundary": "Knap caps condition expression depth below k4o's documented 256 (LIMIT_EXCEEDED)",
}

GFM_FIXTURES = {"examples/table", "fixtures/filter-table-basic"}

# Error cases whose failure needs data, so a static lint sees nothing. Every
# other error case must be rejected by `k4o lint` with teaching output.
LINT_DATA_DEPENDENT = {"loop-nonarray"}


class Tags(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.names = []
        self.code_contents = []
        self.list_item_contents = []
        self.list_item_depths = []
        self.list_item_parents = []
        self._list_depth = 0
        self._items = []
        self._code = None

    def handle_starttag(self, tag, attrs):
        self.names.append(tag)
        if tag in {"ul", "ol"}:
            self._list_depth += 1
        if tag == "li":
            self.list_item_parents.append(self._items[-1] if self._items else None)
            self._items.append(len(self.list_item_contents))
            self.list_item_contents.append("")
            self.list_item_depths.append(self._list_depth)
        if tag == "code":
            self._code = []

    def handle_endtag(self, tag):
        if tag == "li":
            self._items.pop()
        if tag in {"ul", "ol"}:
            self._list_depth -= 1
        if tag == "code" and self._code is not None:
            self.code_contents.append("".join(self._code))
            self._code = None

    def handle_data(self, data):
        if self._items:
            self.list_item_contents[self._items[-1]] += data
        if self._code is not None:
            self._code.append(data)


def invoke(command, *, input=None):
    try:
        return subprocess.run(command, input=input, capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(f"timeout: {command[0]} ({TIMEOUT}s)") from error
    except OSError as error:
        raise AssertionError(f"could not execute {command[0]}: {error}") from error


def check_result(result, name, status):
    if status == "ok":
        assert result.returncode == 0 and not result.stderr, (
            f"{name}: expected clean exit 0, got {result.returncode}: {result.stderr!r}"
        )
    else:
        assert result.returncode == 1 and not result.stdout and result.stderr.strip(), (
            f"{name}: error must exit 1 with empty stdout and diagnostic; "
            f"got {result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}"
        )


def compare(name, template, data, status, expected, k4o, knap, directory, format="markdown"):
    path = directory / "case.knap"
    json_path = directory / "data.json"
    path.write_bytes(template)
    json_path.write_bytes(json.dumps(data, ensure_ascii=False).encode())
    ours = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", format])
    theirs = invoke([knap, "render", str(path), "--data", str(json_path)])
    check_result(ours, f"k4o {name}", status)
    check_result(theirs, f"knap {name}", status)
    assert ours.stdout == theirs.stdout == expected, (
        f"{name}: byte mismatch\nk4o: {ours.stdout!r}\nknap: {theirs.stdout!r}\n"
        f"committed oracle: {expected!r}"
    )
    return ours.stdout


def expected_tag(name):
    stem = name.split("/")[-1]
    if stem.startswith("filter-h") and re.match(r"filter-h[1-6]-", stem):
        return "h" + stem[len("filter-h")]
    if stem.startswith("filter-list-"):
        return "ul"
    if stem.startswith("filter-numbered-"):
        return "ol"
    if stem.startswith("filter-table-") or name == "examples/table":
        return "table"
    return {
        "filter-bold-basic": "strong",
        "filter-italic-basic": "em",
        "filter-code-basic": "code",
        "filter-codeblock-basic": "pre",
        "filter-blockquote-basic": "blockquote",
        "filter-link-basic": "a",
        "filter-link-data-arg": "a",
        "filter-link-literal-arg": "a",
        "filter-chain-h2-italic": "h2",
        "heading": "h1",
        "list": "ul",
    }.get(stem)


def check_commonmark(name, markdown, oliver, required=None):
    required = required or expected_tag(name)
    table = required == "table"
    command = [oliver, "render", "--from", "markdown", "--raw-html", "allowed" if table else "rejected"]
    result = invoke(command, input=markdown)
    assert result.returncode == 0 and not result.stderr, (
        f"{name}: Oliver rejected Markdown: {result.returncode}: {result.stderr!r}"
    )
    assert b"{{" not in markdown and b"{%" not in markdown, f"{name}: template tag leaked"
    html = result.stdout.decode("utf-8")
    tags = Tags()
    tags.feed(html)
    if required:
        assert required in tags.names, f"{name}: expected <{required}> in {html!r}"
    if required == "table":
        assert {"table", "thead", "th", "tbody", "td"} <= set(tags.names), (
            f"{name}: missing table structure in {html!r}"
        )
        assert markdown.startswith(b"<table>\n"), f"{name}: GFM pipe table is not CommonMark"
    if name.endswith("list-nested"):
        assert tags.names.count("ul") >= 2, f"{name}: nested list not nested in {html!r}"
    if name.endswith("numbered-nested"):
        assert tags.names.count("ol") >= 2, f"{name}: nested ordered list not nested in {html!r}"
    if name.endswith("chain-h2-italic"):
        assert "<h2><em>" in html, f"{name}: heading/emphasis chain not parsed: {html!r}"
    if name.endswith("codeblock-basic") or name.endswith("codeblock-blank-lines"):
        assert "<pre><code>" in html, f"{name}: fenced block not parsed: {html!r}"
    if name.endswith("codeblock-blank-lines"):
        assert "line two\n\nline four after blank" in html, (
            f"{name}: blank line or tail lost from the block: {html!r}"
        )
    if name.endswith("link-basic"):
        assert '<a href="https://example.com/">' in html, f"{name}: link target lost: {html!r}"
    return html


def run(k4o, knap, oliver):
    version = invoke([knap, "--version"])
    assert version.returncode == 0 and version.stdout.decode().strip() == KNAP_VERSION, (
        f"wrong knap version: {version.stdout!r} {version.stderr!r}"
    )
    cases = json.loads((CORPUS / "cases.json").read_text())
    expected = json.loads((CORPUS / "expected.json").read_text())
    assert set(expected) == {case["name"] for case in cases}, "corpus and oracle snapshots differ"
    fixture_paths = sorted([*ROOT.glob("fixtures/*.knap"), *ROOT.glob("examples/*.knap")])
    fixture_names = {str(path.relative_to(ROOT).with_suffix("")) for path in fixture_paths}
    assert EXCLUDED_FIXTURES.keys() <= fixture_names, "stale fixture exclusions"
    assert len(EXCLUDED_FIXTURES) == 14, "expected 14 documented fixture incompatibilities"
    assert GFM_FIXTURES <= fixture_names and not GFM_FIXTURES & EXCLUDED_FIXTURES.keys(), (
        "stale or excluded GFM parity fixtures"
    )
    checks = 0
    with tempfile.TemporaryDirectory(prefix="k4o-differential-") as tmp:
        directory = Path(tmp)
        for case in cases:
            name = case["name"]
            snapshot = expected[name]
            status = case.get("status", "ok")
            assert snapshot["status"] == status, f"{name}: snapshot status changed"
            output = compare(
                name, case["template"].encode(), case["data"], status,
                snapshot["stdout"].encode(), k4o, knap, directory,
            )
            if status == "ok":
                check_commonmark(name, output, oliver)
            checks += 1
        for path in fixture_paths:
            name = str(path.relative_to(ROOT).with_suffix(""))
            data = json.loads(path.with_suffix(".json").read_text())
            expected_markdown = path.with_suffix(".markdown").read_bytes()
            if name in GFM_FIXTURES:
                gfm_output = compare(
                    name, path.read_bytes(), data, "ok", path.with_suffix(".gfm").read_bytes(),
                    k4o, knap, directory, format="gfm",
                )
                # The opt-in tradeoff: strict CommonMark sees pipe tables as
                # paragraphs. The same fixture must still parse as a table
                # below when rendered with --format markdown.
                html = check_commonmark(name + "-gfm", gfm_output, oliver, required="p")
                assert "<table>" not in html, f"{name}: Oliver unexpectedly parsed GFM tables"
            elif name not in EXCLUDED_FIXTURES:
                compare(name, path.read_bytes(), data, "ok", expected_markdown, k4o, knap, directory)
            if name in EXCLUDED_FIXTURES or name in GFM_FIXTURES:
                ours = invoke([k4o, "render", str(path), "--data", str(path.with_suffix(".json")), "--format=markdown"])
                check_result(ours, f"k4o {name}", "ok")
                assert ours.stdout == expected_markdown, f"{name}: Markdown fixture differs"
            if name not in GFM_FIXTURES:
                gfm = invoke([k4o, "render", str(path), "--data", str(path.with_suffix(".json")), "--format=gfm"])
                check_result(gfm, f"k4o GFM {name}", "ok")
                assert gfm.stdout == expected_markdown, f"{name}: GFM changed non-table output"
            check_commonmark(name, expected_markdown, oliver)
            checks += 1
        # Dedicated cases for constructs absent from the knap CLI or outside
        # CommonMark's pipe-table syntax, including HTML-escaped table cells.
        structural = [
            ("table-escaped", '{{ rows | table }}', {"rows": [["A&B", "<name>"], ["x", "y"]]}, "table"),
            ("code-fence-backticks", '{{ text | codeblock }}', {"text": "```\ncode"}, "pre"),
            ("inline-code-backticks", '{{ text | code }}', {"text": "a`b"}, "code"),
            ("bold-punctuation", '{{ text | bold }}', {"text": "*"}, "strong"),
            ("italic-punctuation", '{{ text | italic }}', {"text": "*"}, "em"),
            ("bold-whitespace", '{{ text | bold }}', {"text": "  space  "}, "strong"),
            ("heading-raw-html", '{{ text | h2 }}', {"text": "<script>"}, "h2"),
            ("list-raw-html", '{{ items | list }}', {"items": ["<script>"]}, "ul"),
            ("list-leading-nested", '{{ items | list }}', {"items": [["child"], "parent"]}, "ul"),
            ("list-leading-siblings", '{{ items | list }}', {"items": [["one"], ["two"]]}, "ul"),
            ("list-heading-text", '{{ items | list }}', {"items": ["# not a heading"]}, "ul"),
            ("blockquote-raw-html", '{{ text | blockquote }}', {"text": "<script>"}, "blockquote"),
            ("link-raw-html", '{{ text | link:"https://example.com/" }}', {"text": "<script>"}, "a"),
        ]
        for name, template, data, tag in structural:
            path = directory / "case.knap"
            json_path = directory / "data.json"
            path.write_text(template)
            json_path.write_text(json.dumps(data))
            ours = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "markdown"])
            check_result(ours, f"k4o {name}", "ok")
            if tag != "table":
                gfm = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "gfm"])
                check_result(gfm, f"k4o GFM {name}", "ok")
                assert gfm.stdout == ours.stdout, f"{name}: GFM changed non-table output"
            html = check_commonmark(name, ours.stdout, oliver, tag)
            assert f"<{tag}" in html, f"{name}: expected {tag}: {html!r}"
            if name == "table-escaped":
                assert "A&amp;B" in html and "&lt;name&gt;" in html, f"{name}: unescaped HTML: {html!r}"
            if "raw-html" in name:
                assert "<script>" not in html and "&lt;script&gt;" in html, f"{name}: raw HTML leaked: {html!r}"
            if name.startswith("list-"):
                assert "<pre>" not in html and "<h1>" not in html, f"{name}: list item misparsed: {html!r}"
            checks += 1
        # Structural, not knap byte parity: text-driven ordered markers must
        # remain literal, while genuine arrays must still produce nested lists.
        scalar_list_text = [
            "1. numbered", "1) numbered", "12. numbered", "12) numbered",
            "0. zero", "001) leading zero",
            "123456789. nine digits", "123456789) nine digits",
            "1.", "1)", "1.\ttab", "1)\ttab",
            " 1. indented", "   12) indented",
            "plain 1. inline", "1.2 decimal", "1.no space", "1)no space",
            "1234567890. ten digits", "1234567890) ten digits",
            "# heading", "> quote", "---", "***", "<script>",
        ]
        list_content = [
            (f"scalar-{index}", [text], [1], [text.strip()])
            for index, text in enumerate(scalar_list_text)
        ] + [
            ("block-starts", scalar_list_text, [1] * len(scalar_list_text),
             [text.strip() for text in scalar_list_text]),
            ("nested-arrays",
             ["1. parent", ["12) child", ["123. grandchild"], "2. child"], "3) sibling"],
             [1, 2, 3, 2, 1],
             ["1. parent", "12) child", "123. grandchild", "2. child", "3) sibling"]),
            ("leading-array", [["1. promoted"], "12) sibling"], [1, 1],
             ["1. promoted", "12) sibling"]),
            ("continuation-dot", ["intro\n1. continuation"], [1], ["intro\n1. continuation"]),
            ("continuation-parenthesis", ["intro\n1) continuation"], [1], ["intro\n1) continuation"]),
        ]
        for filter_name, tag in [("list", "ul"), ("numbered", "ol")]:
            for name, items, depths, contents in list_content:
                name = f"{filter_name}-{name}"
                path = directory / "case.knap"
                json_path = directory / "data.json"
                path.write_text("{{ items | " + filter_name + " }}")
                json_path.write_text(json.dumps({"items": items}))
                ours = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "markdown"])
                gfm = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "gfm"])
                check_result(ours, f"k4o {name}", "ok")
                check_result(gfm, f"k4o GFM {name}", "ok")
                assert gfm.stdout == ours.stdout, f"{name}: GFM changed non-table output"
                html = check_commonmark(name, ours.stdout, oliver, tag)
                tags = Tags()
                tags.feed(html)
                assert set(tags.names) <= {tag, "li"}, (
                    f"{name}: scalar text introduced another node type: {html!r}"
                )
                assert tags.list_item_depths == depths, (
                    f"{name}: list nesting changed: expected {depths}, got {tags.list_item_depths}"
                )
                actual = [text.strip() for text in tags.list_item_contents]
                assert actual == contents, (
                    f"{name}: item text changed: expected {contents!r}, got {actual!r}"
                )
                checks += 1
        # Marker widths are structural, not knap tab-byte parity. Check the
        # actual parent of every item across one-, two-, and three-digit
        # parents, including all combinations at the third supported level.
        numbered_widths = []
        for parent_number in [9, 10, 100]:
            parents = [f"parent {number}" for number in range(1, parent_number + 1)]
            numbered_widths.append((
                f"numbered-width-{parent_number}",
                parents + [["child"], "parent sibling"],
                parents + ["child", "parent sibling"],
                [None] * parent_number + [parent_number - 1, None],
            ))
            for child_number in [9, 10, 100]:
                children = [f"child {number}" for number in range(1, child_number + 1)]
                numbered_widths.append((
                    f"numbered-width-{parent_number}-{child_number}",
                    parents + [children + [["grandchild"], "child sibling"], "parent sibling"],
                    parents + children + ["grandchild", "child sibling", "parent sibling"],
                    [None] * parent_number + [parent_number - 1] * child_number
                    + [parent_number + child_number - 1, parent_number - 1, None],
                ))
        for name, items, contents, parents in numbered_widths:
            path = directory / "case.knap"
            json_path = directory / "data.json"
            path.write_text("{{ items | numbered }}")
            json_path.write_text(json.dumps({"items": items}))
            ours = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "markdown"])
            gfm = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "gfm"])
            check_result(ours, f"k4o {name}", "ok")
            check_result(gfm, f"k4o GFM {name}", "ok")
            assert gfm.stdout == ours.stdout, f"{name}: GFM changed non-table output"
            html = check_commonmark(name, ours.stdout, oliver, "ol")
            tags = Tags()
            tags.feed(html)
            assert set(tags.names) <= {"ol", "li"}, f"{name}: unexpected list node: {html!r}"
            assert tags.list_item_parents == parents, (
                f"{name}: incorrect parent/child structure: expected {parents}, got {tags.list_item_parents}"
            )
            actual = [text.strip() for text in tags.list_item_contents]
            assert actual == contents, (
                f"{name}: item text changed: expected {contents!r}, got {actual!r}"
            )
            checks += 1
        # Check parsed code content, not just the presence of a <code> tag.
        # All-space spans remain code (knap emits plain whitespace); neither
        # boundary spaces nor repeated terminal newlines are trimmed for parity.
        code_content = [
            ("code-empty", "code", "", None),
            ("code-one-space", "code", " ", " "),
            ("code-only-spaces", "code", "   ", "   "),
            ("code-tab", "code", "\t", "\t"),
            ("code-space-tab", "code", " \t ", " \t "),
            ("code-boundary-spaces", "code", " a ", " a "),
            ("code-leading-space", "code", " a", " a"),
            ("code-trailing-space", "code", "a ", "a "),
            ("code-only-backtick", "code", "`", "`"),
            ("code-leading-backtick", "code", "`a", "`a"),
            ("code-trailing-backtick", "code", "a`", "a`"),
            ("code-longest-run", "code", "a`b```c``d", "a`b```c``d"),
            ("code-space-backticks", "code", " ``` ", " ``` "),
            ("fence-empty", "codeblock", "", ""),
            ("fence-only-spaces", "codeblock", "   ", "   \n"),
            ("fence-no-terminal-newline", "codeblock", "x", "x\n"),
            ("fence-terminal-newline", "codeblock", "x\n", "x\n"),
            ("fence-two-terminal-newlines", "codeblock", "x\n\n", "x\n\n"),
            ("fence-three-terminal-newlines", "codeblock", "x\n\n\n", "x\n\n\n"),
            ("fence-only-newline", "codeblock", "\n", "\n"),
            ("fence-only-newlines", "codeblock", "\n\n", "\n\n"),
            ("fence-leading-backticks", "codeblock", "```\nx", "```\nx\n"),
            ("fence-terminal-backticks", "codeblock", "x\n```\n", "x\n```\n"),
            ("fence-longest-run", "codeblock", "`````\nx\n```\n\n", "`````\nx\n```\n\n"),
        ]
        for name, filter_name, text, content in code_content:
            path = directory / "case.knap"
            json_path = directory / "data.json"
            path.write_text("{{ text | " + filter_name + " }}")
            json_path.write_text(json.dumps({"text": text}))
            ours = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "markdown"])
            gfm = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "gfm"])
            check_result(ours, f"k4o {name}", "ok")
            check_result(gfm, f"k4o GFM {name}", "ok")
            assert gfm.stdout == ours.stdout, f"{name}: GFM changed non-table output"
            tag = None if content is None else ("code" if filter_name == "code" else "pre")
            html = check_commonmark(name, ours.stdout, oliver, tag)
            tags = Tags()
            tags.feed(html)
            if content is None:
                assert not ours.stdout and not html and not tags.code_contents, (
                    f"{name}: empty code invented content: {ours.stdout!r}, {html!r}"
                )
            else:
                assert tags.code_contents == [content], (
                    f"{name}: code content changed: expected {content!r}, got {tags.code_contents!r}"
                )
            checks += 1
        # k4o lint must pass the markdown backend's own fixtures: every ok
        # case lints clean without data, and every statically-broken case is
        # rejected with education-grade output (construct, why, example).
        # Data-dependent breakage stays invisible to lint and is checked at
        # render time above.
        for case in cases:
            name = case["name"]
            path.write_text(case["template"])
            linted = invoke([k4o, "lint", str(path)])
            if case.get("status", "ok") == "error" and name not in LINT_DATA_DEPENDENT:
                assert linted.returncode != 0 and not linted.stderr, (
                    f"lint {name}: broken template must be rejected, got {linted.returncode}: {linted.stdout!r}"
                )
                stdout = linted.stdout.decode()
                for teaching in ("construct:", "why:", "example:"):
                    assert teaching in stdout, (
                        f"lint {name}: missing teaching line {teaching!r} in {stdout!r}"
                    )
            else:
                assert linted.returncode == 0 and not linted.stderr, (
                    f"lint {name}: expected clean lint, got {linted.returncode}: {linted.stdout!r}"
                )
            checks += 1
    print(f"PASS {checks} cases: {len(fixture_paths) - len(EXCLUDED_FIXTURES) + len(cases)} "
          f"byte-identical to knap {KNAP_VERSION} (including {len(GFM_FIXTURES)} GFM tables); "
          f"{len(EXCLUDED_FIXTURES)} documented "
          "fixture incompatibilities checked with Oliver")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--k4o", default=str(ROOT / "zig-out/bin/k4o"))
    parser.add_argument("--knap", default=str(CORPUS / "node_modules/.bin/knap"))
    parser.add_argument("--oliver", default="oliver")
    args = parser.parse_args()
    try:
        run(str(Path(args.k4o).resolve()), str(Path(args.knap).resolve()), args.oliver)
    except (AssertionError, UnicodeError, ValueError, KeyError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        sys.exit(1)
