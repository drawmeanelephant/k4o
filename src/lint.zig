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
            .why = "a logic tag needs a keyword — if, elseif, else, endif, for, endfor, set or raw — followed by its expression",
            .example = "{% if draft %}Draft{% endif %}",
        };
    } else if (startsWith(detail, "nesting too deep")) {
        teaching = .{
            .rule = "nesting-too-deep",
            .construct = "block nesting",
            .why = "if and for blocks can nest at most 100 deep; flatten the template or split it into smaller ones",
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
    } else if (eql(detail, "unexpected text in '{% raw %}'") or
        eql(detail, "unexpected text in '{% endraw %}'"))
    {
        teaching = .{
            .rule = "raw-tag-trailing-text",
            .construct = "`{% raw %}` tag",
            .why = "raw and endraw stand alone — the bytes between them render literally, so the tags themselves take no expression",
            .example = "{% raw %}{{ literal }}{% endraw %}",
        };
    } else if (eql(detail, "unclosed raw block (missing '{% endraw %}')")) {
        teaching = .{
            .rule = "unclosed-raw",
            .construct = "`{% raw %}` block",
            .why = "every {% raw %} needs a matching {% endraw %} — the first endraw tag closes the block, so leaving it out swallows the rest of the template",
            .example = "{% raw %}{% if x %}{% endraw %}",
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
            .why = "after the | comes a filter name from the knap registry — `knap help filters` lists every one",
            .example = "{{ name | bold }}",
        };
    } else if (eql(detail, "unexpected text in output tag")) {
        teaching = .{
            .rule = "output-tag-trailing-text",
            .construct = "output tag `{{ ... }}`",
            .why = "an output tag is a value followed by zero or more `| filter` stages and `??` fallbacks; a name with spaces is one variable, so further words need a |",
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
            .why = "after the colon come the arguments: quoted strings, numbers, bare words, `(a, b)` lists, `k:v` pairs or `x => expr` arrows",
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
            .why = "brackets take a number index, a quoted key, or an expression like x[loop.index0]",
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
            .why = "condition expressions nest at most 100 deep",
            .example = "{% if (a or b) and c %}…{% endif %}",
        };
    } else if (eql(detail, "expected a variable name after 'set'")) {
        teaching = .{
            .rule = "set-missing-var",
            .construct = "`{% set %}` tag",
            .why = "set binds a name: {% set name = expression %} — the variable name comes first",
            .example = "{% set title = post.title %}",
        };
    } else if (eql(detail, "expected '=' in set tag")) {
        teaching = .{
            .rule = "set-missing-eq",
            .construct = "`{% set %}` tag",
            .why = "a set tag assigns with a single `=` between the name and the expression",
            .example = "{% set title = post.title %}",
        };
    } else if (eql(detail, "unexpected text after the set expression")) {
        teaching = .{
            .rule = "set-trailing-text",
            .construct = "`{% set %}` tag",
            .why = "a set tag holds exactly `set <name> = <expression>` with nothing after the expression",
            .example = "{% set total = price %}",
        };
    } else if (eql(detail, "expected a filter argument after ':'") or
        eql(detail, "expected a filter argument"))
    {
        teaching = .{
            .rule = "missing-filter-arg",
            .construct = "filter argument",
            .why = "after the colon come the arguments: quoted strings, numbers, bare words, `(a, b)` lists, `k:v` pairs or `x => expr` arrows",
            .example = "{{ name | link:\"https://example.com/\" }}",
        };
    } else if (eql(detail, "expected a filter argument inside '()'")) {
        teaching = .{
            .rule = "filter-args-empty",
            .construct = "filter arguments",
            .why = "an empty `()` is not an argument list — pass at least one argument or drop the parentheses",
            .example = "{{ name | link:\"https://example.com/\" }}",
        };
    } else if (eql(detail, "unclosed '(' in filter arguments")) {
        teaching = .{
            .rule = "filter-args-unclosed",
            .construct = "filter arguments",
            .why = "a parenthesized argument list `filter:(a, b)` needs its closing `)`",
            .example = "{{ rows | table:(\"Name\", \"Role\") }}",
        };
    } else if (eql(detail, "expected ',' or ')' in filter arguments")) {
        teaching = .{
            .rule = "filter-args-separator",
            .construct = "filter arguments",
            .why = "arguments in a `filter:(a, b)` list are separated by commas",
            .example = "{{ rows | table:(\"Name\", \"Role\") }}",
        };
    } else if (eql(detail, "expected an arrow body after '=>'")) {
        teaching = .{
            .rule = "arrow-body",
            .construct = "arrow expression",
            .why = "an arrow `x => expr` needs a body after the `=>`: a path, a `({k: v})` object, or an interpolated string",
            .example = "{{ people | map:p => p.name }}",
        };
    } else if (startsWith(detail, "expected") and
        (indexOf(detail, "arrow") != null))
    {
        teaching = .{
            .rule = "arrow-object",
            .construct = "arrow object",
            .why = "an arrow object `({k: v, \"k2\": v2})` holds `name: value` pairs separated by commas",
            .example = "{{ people | map:p => ({name: p.name}) }}",
        };
    } else if (eql(detail, "unclosed '${' in string")) {
        teaching = .{
            .rule = "unclosed-interp",
            .construct = "string interpolation",
            .why = "a `${` inside a quoted string needs a path and a closing `}`",
            .example = "{{ genres | map:g => g.name }}",
        };
    } else if (eql(detail, "expected a path inside '${}'")) {
        teaching = .{
            .rule = "interp-path",
            .construct = "string interpolation",
            .why = "a `${ }` interpolation holds a variable path like `${item}` or `${item.name}`",
            .example = "{{ genres | map:g => g.name }}",
        };
    } else if (eql(detail, "bracket access takes a single value expression") or
        eql(detail, "expected ']' after bracket expression"))
    {
        teaching = .{
            .rule = "bracket-expr",
            .construct = "bracket access",
            .why = "a bracket takes one index or key — a number, a quoted key, or an expression like x[loop.index0] — then closes with ]",
            .example = "{{ items[i] }}",
        };
    } else if (eql(detail, "filters are not allowed on the left side of a comparison")) {
        teaching = .{
            .rule = "filter-on-lhs",
            .construct = "condition comparison",
            .why = "a comparison's left side is a plain value — put filters on the right side or wrap the filtered value in parentheses",
            .example = "{% if name == \"Ada\" %}…{% endif %}",
        };
    } else if (startsWith(detail, "unknown logic tag")) {
        teaching = .{
            .rule = "unknown-logic-tag",
            .construct = "logic tag `{% ... %}`",
            .why = "the logic tags are if, elseif, else, endif, for, endfor, set and raw; anything else is unknown",
            .example = "{% if draft %}Draft{% endif %}",
        };
    }

    const fallback: Teaching = .{
        .rule = "unclassified-error",
        .construct = "template",
        .why = "the parser rejected this template; README's \"Template language\" documents the grammar this tool implements",
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
            .output => |chain| try walkChain(alloc, template, chain, findings),
            .ifelse => |chain| {
                for (chain.branches) |branch| {
                    if (branch.cond) |bc| try walkChain(alloc, template, bc, findings);
                    try walkNodes(alloc, template, branch.body, findings);
                }
            },
            .loop => |ln| {
                try walkExpr(alloc, template, ln.list, findings);
                try walkNodes(alloc, template, ln.body, findings);
            },
            .set => |sn| try walkChain(alloc, template, sn.expr, findings),
        }
    }
}

fn walkChain(
    alloc: std.mem.Allocator,
    template: []const u8,
    chain: parse.Chain,
    findings: *std.ArrayList(Finding),
) Error!void {
    for (chain.terms) |term| {
        try walkCond(alloc, template, term.cond, findings);
        for (term.filters) |call| try walkFilter(alloc, template, call, findings);
    }
}

fn walkCond(
    alloc: std.mem.Allocator,
    template: []const u8,
    cond: parse.Cond,
    findings: *std.ArrayList(Finding),
) Error!void {
    switch (cond) {
        .operand => |e| try walkExpr(alloc, template, e, findings),
        .neg => |c| try walkCond(alloc, template, c.*, findings),
        .and_ => |pair| {
            try walkCond(alloc, template, pair.lhs.*, findings);
            try walkCond(alloc, template, pair.rhs.*, findings);
        },
        .or_ => |pair| {
            try walkCond(alloc, template, pair.lhs.*, findings);
            try walkCond(alloc, template, pair.rhs.*, findings);
        },
        .cmp => |c| {
            try walkExpr(alloc, template, c.lhs, findings);
            try walkExpr(alloc, template, c.rhs, findings);
        },
    }
}

fn walkExpr(
    alloc: std.mem.Allocator,
    template: []const u8,
    expr: parse.Expr,
    findings: *std.ArrayList(Finding),
) Error!void {
    for (expr.terms) |pl| try walkPipeline(alloc, template, pl, findings);
}

fn walkPipeline(
    alloc: std.mem.Allocator,
    template: []const u8,
    pl: parse.Pipeline,
    findings: *std.ArrayList(Finding),
) Error!void {
    for (pl.filters) |call| try walkFilter(alloc, template, call, findings);
}

/// Registry checks for one filter call — unknown-name and blocked-name
/// findings (tail filters on `??`/`==` results walk through here too).
fn walkFilter(
    alloc: std.mem.Allocator,
    template: []const u8,
    call: parse.FilterCall,
    findings: *std.ArrayList(Finding),
) Error!void {
    {
        if (!filters.isRegistered(call.name)) {
            const pos = diag.positionOf(template, call.offset);
            try findings.append(alloc, .{
                .rule = "unknown-filter",
                .kind = .unknown_filter,
                .line = pos.line,
                .column = pos.column,
                .detail = try std.fmt.allocPrint(alloc, "no filter named \"{s}\"", .{call.name}),
                .construct = "filter",
                .why = "filter names come from the knap registry — see `k4o init` for the full list or `knap help filters`",
                .example = "{{ text | bold }}",
            });
            return;
        }
        for (filters.blocked_names) |b| {
            if (std.mem.eql(u8, call.name, b)) {
                const pos = diag.positionOf(template, call.offset);
                try findings.append(alloc, .{
                    .rule = "blocked-filter",
                    .kind = .bad_argument,
                    .line = pos.line,
                    .column = pos.column,
                    .detail = try std.fmt.allocPrint(alloc, "filter '{s}' is not supported by k4o", .{call.name}),
                    .construct = "filter",
                    .why = "this filter needs DOM APIs that an embeddable engine does not have — it will fail at render time",
                    .example = "{{ text | strip_md }}",
                });
            }
        }
        for (call.params) |prm| {
            switch (prm) {
                .value => |e| try walkExpr(alloc, template, e.*, findings),
                .pair => |pr| {
                    try walkExpr(alloc, template, pr.key.*, findings);
                    try walkExpr(alloc, template, pr.value.*, findings);
                },
                .arrow => {},
            }
        }
    }
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

fn indexOf(a: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, a, needle);
}
