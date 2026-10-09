//! k4o lint: education-grade diagnostics over the shared parser.
//!
//! Lint answers three questions for every rejected construct: what is
//! wrong, why it is wrong, and what right looks like. It reuses
//! `parse.parseDocument` — one parser, no drift — plus the shared filter
//! registry, and knows nothing about data: a template that only fails when
//! specific JSON reaches it lints clean, because that failure is a render
//! error, not a template error.
//!
//! Two check layers:
//!
//!  1. Parse. A rejected template becomes one finding, classified from the
//!     diagnostic's detail (the same strings the error fixtures pin).
//!  2. Registry walk. A parsed template is walked for output-tag problems
//!     that do not need data: unknown filters, filter/argument arity, and
//!     the `link` URL rules that a literal argument already violates.

const std = @import("std");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const filters = @import("filters.zig");

/// One education-grade diagnostic.
pub const Finding = struct {
    /// Stable rule identifier (e.g. "unclosed-if") for tests and tooling.
    rule: []const u8,
    kind: diag.Kind,
    line: u32,
    column: u32,
    /// What is wrong — the shared parser's own detail text.
    detail: []const u8,
    /// The construct the failure belongs to.
    construct: []const u8,
    /// The rule behind the failure.
    why: []const u8,
    /// A correct snippet.
    example: []const u8,
};

pub const Error = error{OutOfMemory};

/// Lints `template`, returning every finding (empty when clean). Parse
/// failures stop at the first problem, so a broken template yields exactly
/// one finding; registry findings are collected across the whole document.
pub fn lintDocument(
    alloc: std.mem.Allocator,
    template: []const u8,
    d: *diag.Diagnostic,
) Error![]Finding {
    if (parse.parseDocument(alloc, template, d)) |doc| {
        var findings: std.ArrayList(Finding) = .empty;
        errdefer findings.deinit(alloc);
        try walkNodes(alloc, template, doc.nodes, &findings);
        return findings.toOwnedSlice(alloc);
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Template => {
            const finding = classifyParseFailure(d);
            const out = try alloc.alloc(Finding, 1);
            out[0] = finding;
            return out;
        },
    }
}

/// Parse layer: classify the diagnostic the parser produced. The detail
/// strings are the same user-facing messages the error fixtures pin, so a
/// message change without a matching entry here is caught by the lint tests.
fn classifyParseFailure(d: *diag.Diagnostic) Finding {
    const detail = d.detail;
    const Teaching = struct {
        rule: []const u8,
        construct: []const u8,
        why: []const u8,
        example: []const u8,
    };

    var teaching: ?Teaching = null;
    if (eql(detail, "unclosed '{{' tag (missing '}}')")) {
        teaching = .{
            .rule = "unclosed-output-tag",
            .construct = "output tag `{{ ... }}`",
            .why = "an output tag opens with {{ and must close with }} — the parser ran out of template while still inside this one",
            .example = "{{ title }}",
        };
    } else if (eql(detail, "unclosed '{%' tag (missing '%}')")) {
        teaching = .{
            .rule = "unclosed-logic-tag",
            .construct = "logic tag `{% ... %}`",
            .why = "a logic tag opens with {% and must close with %} before its contents can be understood",
            .example = "{% if draft %}Draft{% endif %}",
        };
    } else if (eql(detail, "unclosed comment (missing '#}')")) {
        teaching = .{
            .rule = "unclosed-comment",
            .construct = "comment `{# ... #}`",
            .why = "a comment opens with {# and must close with #}; it may span lines and nothing inside it is evaluated",
            .example = "{# a note, removed from the output #}",
        };
    } else if (eql(detail, "empty logic tag")) {
        teaching = .{
            .rule = "empty-logic-tag",
            .construct = "logic tag `{% ... %}`",
            .why = "a logic tag needs a keyword — if, elseif, else, endif, for or endfor — followed by its expression",
            .example = "{% if draft %}Draft{% endif %}",
        };
    } else if (startsWith(detail, "nesting too deep")) {
        teaching = .{
            .rule = "nesting-too-deep",
            .construct = "block nesting",
            .why = "if and for blocks can nest at most 64 deep; flatten the template or split it into smaller ones",
            .example = "{% if a %}{% for x in xs %}{{ x }}{% endfor %}{% endif %}",
        };
    } else if (eql(detail, "expected a loop variable name after 'for'")) {
        teaching = .{
            .rule = "for-missing-var",
            .construct = "`{% for %}` tag",
            .why = "for needs a name to bind each item to, then in, then the array expression",
            .example = "{% for item in items %}{{ item }}{% endfor %}",
        };
    } else if (eql(detail, "expected 'in' in for tag")) {
        teaching = .{
            .rule = "for-missing-in",
            .construct = "`{% for %}` tag",
            .why = "the loop variable and the array are separated by the keyword in",
            .example = "{% for item in items %}{{ item }}{% endfor %}",
        };
    } else if (eql(detail, "unexpected text after the for expression")) {
        teaching = .{
            .rule = "for-trailing-text",
            .construct = "`{% for %}` tag",
            .why = "a for tag holds exactly one clause — for <name> in <array> — with nothing after the array",
            .example = "{% for item in items %}{{ item }}{% endfor %}",
        };
    } else if (endsWith(detail, "outside an if block") or
        endsWith(detail, "outside a for block"))
    {
        teaching = .{
            .rule = "misplaced-closing-tag",
            .construct = "closing tag",
            .why = "elseif, else and endif close an {% if %} opened earlier, and endfor closes a {% for %}; a closing tag with no open block is never valid",
            .example = "{% if draft %}Draft{% endif %}",
        };
    } else if (eql(detail, "unexpected '{% elseif %}' after '{% else %}'")) {
        teaching = .{
            .rule = "elseif-after-else",
            .construct = "`{% if %}` chain",
            .why = "else is the last branch of an if chain; every elseif must come before it",
            .example = "{% if a %}…{% elseif b %}…{% else %}…{% endif %}",
        };
    } else if (eql(detail, "duplicate '{% else %}'")) {
        teaching = .{
            .rule = "duplicate-else",
            .construct = "`{% if %}` chain",
            .why = "an if chain has at most one else branch",
            .example = "{% if a %}…{% else %}…{% endif %}",
        };
    } else if (startsWith(detail, "unexpected text in '{% ")) {
        teaching = .{
            .rule = "closing-tag-trailing-text",
            .construct = "closing tag",
            .why = "elseif carries a condition, but else, endif and endfor stand alone — the condition belongs to the tag that opened the branch",
            .example = "{% if draft %}Draft{% else %}Published{% endif %}",
        };
    } else if (eql(detail, "unclosed if block (missing '{% endif %}')")) {
        teaching = .{
            .rule = "unclosed-if",
            .construct = "`{% if %}` block",
            .why = "every {% if %} needs a matching {% endif %}; branches inside come from {% elseif %} and {% else %}",
            .example = "{% if draft %}Draft{% else %}Published{% endif %}",
        };
    } else if (eql(detail, "unclosed for block (missing '{% endfor %}')")) {
        teaching = .{
            .rule = "unclosed-for",
            .construct = "`{% for %}` block",
            .why = "every {% for %} needs a matching {% endfor %}",
            .example = "{% for item in items %}{{ item }}{% endfor %}",
        };
    } else if (eql(detail, "unexpected '{% endfor %}' inside an if block")) {
        teaching = .{
            .rule = "endfor-inside-if",
            .construct = "block nesting",
            .why = "blocks close in the order they opened: an {% if %} opened inside a for loop must close before the loop's {% endfor %}",
            .example = "{% for x in xs %}{% if ok %}{{ x }}{% endif %}{% endfor %}",
        };
    } else if (endsWith(detail, "inside a for block")) {
        teaching = .{
            .rule = "tag-inside-for",
            .construct = "block nesting",
            .why = "elseif, else and endif close an {% if %} from outside: the {% for %} opened after it must close with {% endfor %} first",
            .example = "{% if a %}{% for x in xs %}{{ x }}{% endfor %}{% endif %}",
        };
    } else if (eql(detail, "expected a filter name after '|'")) {
        teaching = .{
            .rule = "missing-filter-name",
            .construct = "filter pipeline",
            .why = "after the | comes a filter name from the registry: h1-h6, bold, italic, code, codeblock, blockquote, link, list, numbered, table",
            .example = "{{ name | bold }}",
        };
    } else if (eql(detail, "unexpected text in output tag (expected '|' or end of tag)")) {
        teaching = .{
            .rule = "output-tag-trailing-text",
            .construct = "output tag `{{ ... }}`",
            .why = "an output tag is a value followed by zero or more `| filter` stages (each optionally `:arg`); a name with spaces is one variable, so further words need a |",
            .example = "{{ name | bold }}",
        };
    } else if (eql(detail, "unterminated string literal")) {
        teaching = .{
            .rule = "unterminated-string",
            .construct = "string literal",
            .why = "a quoted literal needs its matching closing quote",
            .example = "{{ \"The Machine Stops\" }}",
        };
    } else if (eql(detail, "invalid number literal") or eql(detail, "invalid array index")) {
        teaching = .{
            .rule = "invalid-number",
            .construct = "number literal",
            .why = "numbers are digits with an optional decimal point and an optional leading minus; a digit followed by a letter, or an index too large to count, is not a number",
            .example = "{{ 7 }}",
        };
    } else if (eql(detail, "expected a value")) {
        teaching = .{
            .rule = "missing-value",
            .construct = "expression",
            .why = "a condition or interpolation needs a value: a variable path or a literal (\"text\", 7, 1.5, true, false, null)",
            .example = "{% if title %}…{% endif %}",
        };
    } else if (eql(detail, "expected a filter argument after ':'")) {
        teaching = .{
            .rule = "missing-filter-arg",
            .construct = "filter argument",
            .why = "after the colon comes the argument: a quoted string, a number, or a bare word resolved against the data root",
            .example = "{{ name | link:\"https://example.com/\" }}",
        };
    } else if (eql(detail, "unclosed '[' in path") or
        eql(detail, "expected ']' after bracket key") or
        eql(detail, "expected ']' after array index"))
    {
        teaching = .{
            .rule = "bracket-unclosed",
            .construct = "bracket access",
            .why = "a bracket holds a number index or a quoted key and closes with ]",
            .example = "{{ items[0] }}",
        };
    } else if (eql(detail, "bracket access supports a number or a quoted key")) {
        teaching = .{
            .rule = "bracket-key",
            .construct = "bracket access",
            .why = "brackets take a number or a quoted string key only; bracket expressions that reference variables are not in the subset",
            .example = "{{ authors[0].name }}",
        };
    } else if (eql(detail, "expected a variable name")) {
        teaching = .{
            .rule = "missing-variable",
            .construct = "variable name",
            .why = "a value starts with a variable name (letters, digits, underscores) or a literal",
            .example = "{{ title }}",
        };
    } else if (eql(detail, "unexpected text after condition")) {
        teaching = .{
            .rule = "condition-trailing-text",
            .construct = "`{% if %}` condition",
            .why = "one condition per tag; combine operands with and / or / not, parentheses, and the comparisons == != < <= > >= contains",
            .example = "{% if draft and title %}…{% endif %}",
        };
    } else if (eql(detail, "expected ')'")) {
        teaching = .{
            .rule = "unclosed-paren",
            .construct = "parenthesized condition",
            .why = "an open parenthesis needs a matching close parenthesis",
            .example = "{% if (a or b) and c %}…{% endif %}",
        };
    } else if (eql(detail, "expression nesting too deep")) {
        teaching = .{
            .rule = "paren-too-deep",
            .construct = "condition parentheses",
            .why = "conditions nest parentheses at most 32 deep",
            .example = "{% if (a or b) and c %}…{% endif %}",
        };
    } else if (startsWith(detail, "unknown logic tag")) {
        teaching = .{
            .rule = "unknown-logic-tag",
            .construct = "logic tag `{% ... %}`",
            .why = "the logic tags are if, elseif, else, endif, for and endfor; anything else is unknown",
            .example = "{% if draft %}Draft{% endif %}",
        };
    }

    const fallback: Teaching = .{
        .rule = "unclassified-error",
        .construct = "template",
        .why = "the parser rejected this template; README's \"Template subset\" documents the full grammar this tool implements",
        .example = "{{ title }}",
    };
    const t = teaching orelse fallback;
    return .{
        .rule = t.rule,
        .kind = d.kind,
        .line = d.line,
        .column = d.column,
        .detail = detail,
        .construct = t.construct,
        .why = t.why,
        .example = t.example,
    };
}

/// Registry layer: walk a parsed document for output-tag problems that are
/// visible without data.
fn walkNodes(
    alloc: std.mem.Allocator,
    template: []const u8,
    nodes: []const parse.Node,
    findings: *std.ArrayList(Finding),
) Error!void {
    for (nodes) |node| {
        switch (node) {
            .text => {},
            .output => |pl| try walkPipeline(alloc, template, pl, findings),
            .ifelse => |chain| {
                for (chain.branches) |branch| {
                    try walkNodes(alloc, template, branch.body, findings);
                }
            },
            .loop => |ln| try walkNodes(alloc, template, ln.body, findings),
        }
    }
}

fn walkPipeline(
    alloc: std.mem.Allocator,
    template: []const u8,
    pl: parse.Pipeline,
    findings: *std.ArrayList(Finding),
) Error!void {
    for (pl.filters) |call| {
        const entry = findEntry(call.name) orelse {
            const pos = diag.positionOf(template, call.offset);
            try findings.append(alloc, .{
                .rule = "unknown-filter",
                .kind = .unknown_filter,
                .line = pos.line,
                .column = pos.column,
                .detail = try std.fmt.allocPrint(alloc, "no filter named \"{s}\"", .{call.name}),
                .construct = "filter",
                .why = "the filter registry is h1-h6, bold, italic, code, codeblock, blockquote, link, list, numbered, table — filter names come from the documented subset, not from imagination",
                .example = "{{ text | bold }}",
            });
            continue;
        };

        if (!entry.takes_arg and call.arg != null) {
            const pos = diag.positionOf(template, call.offset);
            try findings.append(alloc, .{
                .rule = "filter-arg-unexpected",
                .kind = .bad_argument,
                .line = pos.line,
                .column = pos.column,
                .detail = try std.fmt.allocPrint(alloc, "filter '{s}' takes no arguments", .{call.name}),
                .construct = "filter argument",
                .why = "only link takes an argument (a URL); every other filter in the registry stands alone after the |",
                .example = "{{ text | bold }}",
            });
            continue;
        }

        if (std.mem.eql(u8, call.name, "link")) {
            if (call.arg) |arg| {
                try checkLinkArg(alloc, template, call, arg, findings);
            } else {
                const pos = diag.positionOf(template, call.offset);
                try findings.append(alloc, .{
                    .rule = "link-missing-url",
                    .kind = .bad_argument,
                    .line = pos.line,
                    .column = pos.column,
                    .detail = "filter 'link' requires a URL argument",
                    .construct = "`link` filter",
                    .why = "link pairs the input text with a destination; the URL comes after the colon as a quoted string, a number, or a bare word naming a top-level data key",
                    .example = "{{ name | link:url }}",
                });
            }
        }
    }
}

/// Statically checks the `link` URL rules that a literal argument already
/// violates. A bare word is resolved against the data at render time, so it
/// is not lintable here.
fn checkLinkArg(
    alloc: std.mem.Allocator,
    template: []const u8,
    call: parse.FilterCall,
    arg: parse.Arg,
    findings: *std.ArrayList(Finding),
) Error!void {
    const url = switch (arg) {
        .bare => return,
        .string => |s| s,
        .number => return,
    };
    const pos = diag.positionOf(template, call.offset);
    if (url.len == 0) {
        try findings.append(alloc, .{
            .rule = "link-url-text",
            .kind = .bad_argument,
            .line = pos.line,
            .column = pos.column,
            .detail = "filter 'link' URL must not be empty",
            .construct = "`link` filter URL",
            .why = "an empty URL cannot link anywhere; give the destination as a quoted string, a number, or a bare word naming a top-level data key",
            .example = "{{ name | link:\"https://example.com/\" }}",
        });
        return;
    }
    for (url) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '"') {
            try findings.append(alloc, .{
                .rule = "link-url-text",
                .kind = .bad_argument,
                .line = pos.line,
                .column = pos.column,
                .detail = "filter 'link' URL must not contain whitespace or a double quote",
                .construct = "`link` filter URL",
                .why = "whitespace and double quotes break the Textile link form; percent-encode them (a space becomes %20) or choose a URL that needs neither",
                .example = "{{ name | link:\"https://example.com/my%20post\" }}",
            });
            return;
        }
    }
    if (filters.hasBlockedScheme(url)) {
        try findings.append(alloc, .{
            .rule = "link-scheme",
            .kind = .bad_argument,
            .line = pos.line,
            .column = pos.column,
            .detail = try std.fmt.allocPrint(
                alloc,
                "filter 'link' refuses the URL scheme '{s}:', which can execute script in the Textile renderer",
                .{try filters.schemeName(alloc, url)},
            ),
            .construct = "`link` filter URL",
            .why = "javascript:, vbscript: and data: URLs execute when the output is rendered, so link refuses them at the source; navigational schemes (http:, https:, mailto:, ftp:, file:) and relative paths pass",
            .example = "{{ name | link:\"https://example.com/\" }}",
        });
    }
}

fn findEntry(name: []const u8) ?filters.Entry {
    for (filters.registry()) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(a: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, a, prefix);
}

fn endsWith(a: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, a, suffix);
}
