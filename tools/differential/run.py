#!/usr/bin/env python3
"""Black-box differential and CommonMark structure checks (no knap source).

k4o emits markdown by default — identical bytes to knap 0.6.0 — and an
`oliver` format that swaps `comment`'s `%%…%%` for an HTML comment (a
`%%` block only opens at line start in Oliver ≥1.3, so the passthrough
is the safe emit at any column). Every fixture is byte-compared against
both the oracle and the committed .markdown snapshot; error fixtures pin
k4o's diagnostics with empty stdout."""

import argparse
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).resolve().parent
KNAP_VERSION = "0.6.0"
TIMEOUT = 8

# Error fixtures whose knap byte parity is deliberately divergent — both
# engines reject the template, but k4o pins its own diagnostic shape
# (the oracle's PARSE_ERROR texts are not part of k4o's surface).
ERROR_KNAP_DIVERGENT = set()


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
    # Date filters resolve to local time — pin TZ so snapshots and the
    # knap-vs-k4o comparison are machine-independent (CI runs UTC).
    env = {**os.environ, "TZ": "UTC"}
    try:
        return subprocess.run(command, input=input, capture_output=True, timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(f"timeout: {command[0]} ({TIMEOUT}s)") from error
    except OSError as error:
        raise AssertionError(f"could not execute {command[0]}: {error}") from error


def check_result(result, name, status):
    if status == "ok":
        # A clean render may still warn — the oracle prints `warning`
        # diagnostics (e.g. `Invalid Date` passthrough) on exit 0. Only
        # `error` lines are fatal.
        fatal = any(b"error" in line for line in result.stderr.splitlines())
        assert result.returncode == 0 and not fatal, (
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


# HTML-cleanup filters legitimately emit raw HTML (that IS the
# transform), so their fixtures need allowed mode instead of rejected.
HTML_FIXTURE_PREFIXES = ("filter-remove_attr", "filter-strip_attr",
    "filter-remove_tags", "filter-replace_tags", "filter-strip_tags",
    "filter-strip_md")

# Oliver extensions are opt-in — a fixture that relies on one enables it
# for the structural check.
OLIVER_FLAGS = {
    "filter-callout": ["--callouts"],
    "filter-strike": ["--strikethrough"],
    "filter-wikilink": ["--wikilinks"],
    "filter-footnote": ["--footnotes"],
    "filter-list-task": ["--task-lists"],
    "filter-highlight": ["--highlights"],
    "filter-math": ["--math"],
    "filter-comment": ["--comments"],
    "filter-embed": ["--embeds"],
}


def oliver_flags(stem):
    for prefix, flags in OLIVER_FLAGS.items():
        if stem.startswith(prefix):
            return flags
    return []

# tag, optional substring, oliver flags — what a filter's output must
# become inside this Oliver build.
def expected_tag(name):
    stem = name.split("/")[-1]
    if stem.startswith("filter-h") and re.match(r"filter-h[1-6]-", stem):
        return "h" + stem[len("filter-h")]
    if stem.startswith("filter-list-numbered") or stem.startswith("filter-numbered-"):
        return "ol"
    if stem.startswith("filter-list-task"):
        return "input"
    if stem.startswith("filter-list-") or stem.startswith("render-nonarray-list"):
        return "ul"
    if stem.startswith("filter-callout"):
        return "callout"
    if stem.startswith("filter-strike"):
        return "del"
    if stem.startswith("filter-table_pretty"):
        return "table"
    if stem.startswith("filter-table") or stem.startswith("render-ragged-table") or name == "examples/table":
        # Compact `| - |` delimiters don't parse as a table in this Oliver
        # build (the pretty `| --- |` form does) — still valid CommonMark,
        # so the check is only that it parses.
        return "p"
    if stem.startswith("filter-wikilink"):
        return "a"
    if stem.startswith("filter-footnote"):
        # Bare `[^n]:` definitions render nothing in Oliver without a
        # matching `[^n]` reference — valid CommonMark, empty output.
        return None
    if stem.startswith("filter-math_block") or stem.startswith("filter-math-multiline"):
        return "math-display"
    if stem.startswith("filter-math"):
        return "math-inline"
    if stem.startswith("filter-highlight"):
        return "mark"
    if stem.startswith("filter-comment"):
        return "comment-gone"
    if stem.startswith("filter-embed"):
        return "embed"
    return {
        "filter-bold-basic": "strong",
        "filter-italic-basic": "em",
        "filter-code-basic": "code",
        "filter-code_block-basic": "pre",
        "filter-blockquote-basic": "blockquote",
        "filter-link-basic": "a",
        "filter-link-data-arg": "a",
        "filter-link-literal-arg": "a",
        "filter-image-basic": "img",
        "filter-strike-basic": "del",
        "filter-hard_break-basic": "br",
        "filter-hr-basic": "hr",
        "filter-chain-h2-italic": "h2",
        "heading": "h1",
        "list": "ul",
    }.get(stem)


def check_commonmark(name, markdown, oliver, required=None, raw_html="rejected"):
    stem = name.split("/")[-1]
    required = required or expected_tag(name)
    flags = oliver_flags(stem)
    # Oliver's default allows raw HTML (knap emits content verbatim —
    # fidelity means the same). The structural check forces rejected mode
    # so a leaked template tag or injected markup surfaces loudly instead;
    # cases that deliberately carry raw HTML switch to escaped.
    if any(stem.startswith(pfx) for pfx in HTML_FIXTURE_PREFIXES):
        raw_html = "allowed"
    command = [oliver, "render", "--from", "markdown", "--raw-html", raw_html, *flags]
    result = invoke(command, input=markdown)
    assert result.returncode == 0 and not result.stderr, (
        f"{name}: Oliver rejected Markdown: {result.returncode}: {result.stderr!r}"
    )
    assert b"{{" not in markdown and b"{%" not in markdown, f"{name}: template tag leaked"
    html = result.stdout.decode("utf-8")
    tags = Tags()
    tags.feed(html)
    if required == "callout":
        assert "callout" in html, f"{name}: expected callout markup in {html!r}"
    elif required == "embed":
        assert "data-embed-target" in html, f"{name}: expected embed markup in {html!r}"
    elif required in ("math-inline", "math-display"):
        cls = "math inline" if required == "math-inline" else "math display"
        assert f'class="{cls}"' in html, f"{name}: expected class=\"{cls}\" in {html!r}"
    elif required == "comment-gone":
        # `--comments` removes `%%…%%` at parse — the fixtures are all
        # comment, so nothing may survive. An accepted-but-inert flag
        # would leave the `%%` bytes visible.
        assert not html.strip(), f"{name}: comment bytes survived: {html!r}"
    elif required == "footnote-ref":
        assert "footnote" in html, f"{name}: expected footnote markup in {html!r}"
    elif required:
        assert required in tags.names, f"{name}: expected <{required}> in {html!r}"
    if name.endswith("list-nested") or name.endswith("list"):
        if "nested" in name:
            assert tags.names.count("ul") >= 2, f"{name}: nested list not nested in {html!r}"
    if name.endswith("numbered-nested"):
        assert tags.names.count("ol") >= 2, f"{name}: nested ordered list not nested in {html!r}"
    if name.endswith("chain-h2-italic"):
        assert "<h2><em>" in html, f"{name}: heading/emphasis chain not parsed: {html!r}"
    if name.endswith("link-basic"):
        assert '<a href="x">' in html or "<a href=" in html, f"{name}: link target lost: {html!r}"
    return html


def run(k4o, knap, oliver):
    version = invoke([knap, "--version"])
    assert version.returncode == 0 and version.stdout.decode().strip() == KNAP_VERSION, (
        f"wrong knap version: {version.stdout!r} {version.stderr!r}"
    )
    cases = json.loads((CORPUS / "cases.json").read_text())
    expected = json.loads((CORPUS / "expected.json").read_text())
    assert set(expected) == {case["name"] for case in cases}, "corpus and oracle snapshots differ"
    fixture_paths = sorted([
        *ROOT.glob("fixtures/*.knap"),
        *ROOT.glob("examples/*.knap"),
    ])
    error_paths = sorted(ROOT.glob("fixtures/errors/*.knap"))
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
        # Render fixtures: byte-identical markdown to the oracle.
        for path in fixture_paths:
            name = str(path.relative_to(ROOT).with_suffix(""))
            data_path = path.with_suffix(".json")
            data = json.loads(data_path.read_text()) if data_path.exists() else {}
            expected_markdown = path.with_suffix(".markdown").read_bytes()
            compare(name, path.read_bytes(), data, "ok", expected_markdown, k4o, knap, directory)
            check_commonmark(name, expected_markdown, oliver)
            # The one remaining format divergence: `comment`'s `<!-- -->`
            # passthrough — prove Oliver still accepts that output.
            if name.startswith("fixtures/filter-comment"):
                data_arg = ["--data", str(data_path)] if data_path.exists() else []
                ours = invoke([k4o, "render", str(path), *data_arg, "--format", "oliver"])
                check_result(ours, f"k4o {name} --format oliver", "ok")
                parsed = invoke([oliver, "render", "--from", "markdown", "--raw-html", "allowed"], input=ours.stdout)
                assert parsed.returncode == 0 and not parsed.stderr, (
                    f"{name}: Oliver rejected oliver-format output: {parsed.returncode}: {parsed.stderr!r}"
                )
                assert b"<!--" in parsed.stdout, f"{name}: comment passthrough lost: {parsed.stdout!r}"
                checks += 1
            checks += 1
        # Error fixtures: k4o exits 1 with empty stdout and the pinned
        # diagnostic; the oracle's verdict is informational — when it also
        # rejects the template that is parity, when it renders, the fixture
        # documents a deliberate k4o strictness and goes on a short list.
        for path in error_paths:
            name = path.stem
            data_path = path.with_suffix(".json")
            data_arg = ["--data", str(data_path)] if data_path.exists() else []
            ours = invoke([k4o, "render", str(path), *data_arg])
            check_result(ours, f"k4o {name}", "error")
            expected_error = path.with_suffix(".error").read_text().strip()
            ours_text = ours.stderr.decode().removeprefix("k4o: ").strip()
            assert ours_text == expected_error, (
                f"{name}: diagnostic drift\nk4o: {ours_text!r}\npinned: {expected_error!r}"
            )
            theirs = invoke([knap, "render", str(path), *data_arg])
            if name not in ERROR_KNAP_DIVERGENT:
                assert theirs.returncode == 1, (
                    f"{name}: k4o rejects but knap renders — move the template to "
                    f"a render fixture or document the divergence"
                )
            checks += 1
        # Structural checks for constructs outside knap's byte surface.
        structural = [
            ("inline-code-backticks", '{{ text | code }}', {"text": "a`b"}, "code"),
            # `*` wrapped in `**`/`~~` is a real CommonMark edge — `***`
            # parses as a rule, not emphasis, in knap's own output too.
            ("bold-punctuation", '{{ text | bold }}', {"text": "*"}, "hr"),
            ("italic-punctuation", '{{ text | italic }}', {"text": "*"}, "hr"),
            ("heading-raw-html", '{{ text | h2 }}', {"text": "<script>"}, "h2"),
            ("list-raw-html", '{{ items | list }}', {"items": ["<script>"]}, "ul"),
            # A `<script>` URL is percent-encoded by the link filter — it
            # can never smuggle raw HTML into Oliver.
            ("link-url-encoded", '{{ text | link:"https://example.com/" }}', {"text": "<script>"}, "a"),
        ]
        for name, template, data, tag in structural:
            path = directory / "case.knap"
            json_path = directory / "data.json"
            path.write_text(template)
            json_path.write_text(json.dumps(data))
            ours = invoke([k4o, "render", str(path), "--data", str(json_path), "--format", "markdown"])
            check_result(ours, f"k4o {name}", "ok")
            html = check_commonmark(name, ours.stdout, oliver, tag, raw_html="escaped" if "raw-html" in name else "rejected")
            assert f"<{tag}" in html, f"{name}: expected {tag}: {html!r}"
            if "raw-html" in name:
                assert "<script>" not in html and "&lt;script&gt;" in html, f"{name}: raw HTML leaked: {html!r}"
            checks += 1
        # k4o lint must see the same errors the renderer does, and stay
        # silent on clean templates (the error corpus exercises parse
        # failures; render-time data failures lint clean by design).
        lint_data_dependent = {"err-loop-nonarray", "err-bad-args-extra", "err-deep-serialize", "err-value-depth"}
        for path in error_paths:
            name = path.stem
            if name in lint_data_dependent:
                continue
            lint = invoke([k4o, "lint", str(path)])
            assert lint.returncode == 1 and lint.stdout, (
                f"{name}: lint missed the problem {lint.stdout!r}"
            )
            checks += 1
        for path in fixture_paths:
            lint = invoke([k4o, "lint", str(path)])
            assert lint.returncode == 0, (
                f"{path.name}: lint flagged a clean template: {lint.stdout!r}"
            )
            checks += 1
    print(f"differential: {checks} checks, 0 failures")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--k4o", default=str(ROOT / "zig-out/bin/k4o"))
    parser.add_argument("--knap", default=str(ROOT / "tools/differential/node_modules/.bin/knap"))
    parser.add_argument("--oliver", default="oliver")
    args = parser.parse_args()
    run(args.k4o, args.knap, args.oliver)


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
