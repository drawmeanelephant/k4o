//! Template parser: knap template text -> AST.
//!
//! The grammar is documented in README.md ("Template language") and was
//! derived clean-room from Knap's user-facing documentation plus black-box
//! oracle probing (see the clean-room record in README.md and
//! tools/differential/oracle-docs/).

const std = @import("std");
const diag = @import("diag.zig");

pub const Error = error{ Template, OutOfMemory };

pub const Literal = union(enum) {
    string: StringLit,
    integer: i64,
    float: f64,
    boolean: bool,
    null,
};

/// A quoted string literal: `value` has escapes applied (`\n` →
/// newline, `\d` → `d`), `raw` is the pre-unescape source — `replace`
/// regex specs need it (`"/\d+/g"` must still see `\d`).
pub const StringLit = struct {
    value: []const u8,
    raw: []const u8,
};

pub const Step = union(enum) {
    key: []const u8,
    index: u64,
    /// `x[expr]` — dynamic key/index resolved at render time.
    expr: *const Pipeline,
};

pub const Path = struct {
    root: []const u8,
    steps: []const Step,
};

pub const Primary = union(enum) {
    literal: Literal,
    path: Path,
};

/// A value plus its filter chain: `a.b | f | g:x`.
pub const Pipeline = struct {
    value: Primary,
    filters: []FilterCall,
    /// Absolute byte offset of the opening `{{`, or of the expression.
    offset: usize,
};

/// `a ?? b` — the first truthy term wins. A single term is a plain value.
pub const Expr = struct {
    terms: []const Pipeline,
};

/// Arrow expression: `item => item.name`, `x => ({k: x.v})`,
/// `x => "pre/${x}"`. The body is intentionally narrow; `map` owns it.
pub const Arrow = struct {
    var_name: []const u8,
    body: ArrowBody,
};

pub const ArrowBody = union(enum) {
    /// `x`, `x.a.b` — evaluated against the arrow variable.
    path: Path,
    /// `({k: v, "k2": v2})` — keys are names or quoted strings.
    object: []const ArrowField,
    /// `"pre${x.a}post"` — literal text with `${path}` interpolation.
    interp: []const InterpPart,
    /// `x => 42` / `x => "lit"` (a plain string interpolates nothing).
    literal: Literal,
};

pub const ArrowField = struct {
    name: []const u8,
    value: ArrowValue,
};

pub const ArrowValue = union(enum) {
    path: Path,
    literal: Literal,
    interp: []const InterpPart,
};

pub const InterpPart = union(enum) {
    text: []const u8,
    path: Path,
};

/// One parameter inside a filter argument list.
pub const Param = union(enum) {
    /// Bare word (resolved against data, then literal), quoted string,
    /// number, boolean, null, or a path — all are evaluated pipelines.
    value: *const Expr,
    /// `"k":"v"` — replacement pairs, where-style key/value params.
    pair: struct { key: *const Expr, value: *const Expr },
    /// `item => expr`.
    arrow: Arrow,
};

pub const FilterCall = struct {
    name: []const u8,
    params: []const Param,
    /// Absolute byte offset of the filter name in the template.
    offset: usize,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge, contains };

pub const Cond = union(enum) {
    operand: Expr,
    neg: *Cond,
    and_: struct { lhs: *Cond, rhs: *Cond },
    or_: struct { lhs: *Cond, rhs: *Cond },
    cmp: struct { op: CmpOp, lhs: Expr, rhs: Expr },
};

pub const Node = union(enum) {
    text: []const u8,
    output: Chain,
    ifelse: IfChain,
    loop: LoopNode,
    set: SetNode,
};

pub const SetNode = struct {
    name: []const u8,
    expr: Chain,
    offset: usize,
};

/// A `??`-chain of conditions — `??` binds looser than `and`/`or`/`==`,
/// so `x ?? y == "z"` reads `x ?? (y == "z")`: the first truthy term
/// wins and contributes its value (a bool for comparisons, the operand
/// value otherwise).
pub const Chain = struct {
    terms: []const Cond,
};

pub const Branch = struct {
    cond: ?Chain,
    body: []Node,
    /// Absolute offset of the tag that opened this branch.
    offset: usize,
};

pub const IfChain = struct {
    branches: []Branch,
    offset: usize,
};

pub const LoopNode = struct {
    var_name: []const u8,
    list: Expr,
    body: []Node,
    offset: usize,
    /// `{% endfor %}` sat on a standalone line, so the body's trailing
    /// whitespace run must be trimmed once after the final iteration.
    endfor_standalone: bool,
    /// `{% endfor %}` was standalone at column 0: it eats one newline of
    /// the rendered tail (`B1\n{% endfor %}` ends `B1`, not `B1\n`).
    endfor_col0: bool,
    /// `{% for %}` was standalone on its line; the body's leading
    /// spaces/tabs are stripped once, on the first emitted iteration.
    strip_first: bool,
};

pub const Document = struct {
    nodes: []Node,
};

const max_depth = 100;
/// Cap on condition expression depth, matching the oracle's maxDepth=100:
/// each `and`/`or` link and each `not`/`!` costs one level, each
/// parenthesized group costs two (so 49 nested parens pass, 50 fail).
/// It also keeps the recursive evaluator well inside its budget.
const max_cond_depth = 100;

const Mode = enum { top, branch, loop_body };

const EndTag = enum { eof, elseif, else_, endif, endfor };

const SeqResult = struct {
    nodes: []Node,
    end: EndTag,
    /// Absolute offset of the terminating `{%`.
    end_offset: usize,
    /// Raw content of the terminating tag (inside `{% %}`).
    end_content: []const u8,
    /// Absolute offset of `end_content[0]`.
    end_content_offset: usize,
    /// True when the terminating close tag sat on a standalone line.
    end_standalone: bool,
    /// True when the terminating close tag was standalone at column 0.
    end_col0: bool,
};

pub fn parseDocument(
    alloc: std.mem.Allocator,
    src: []const u8,
    d: *diag.Diagnostic,
) Error!Document {
    var p = Parser{ .alloc = alloc, .src = src, .diag = d };
    const seq = try p.parseSeq(.top, 0);
    return .{ .nodes = seq.nodes };
}

const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    diag: *diag.Diagnostic,
    i: usize = 0,
    /// Modes of the parseSeq frames currently open, outermost first. When a
    /// closing tag is rejected this tells crossed nesting apart from a
    /// genuinely unmatched tag: in `{% for %}{% if %}{% endfor %}` the
    /// endfor fails because an if is in the way, not because no for is open.
    /// parseSeq nests once per block and depth is capped at max_depth, so
    /// the fixed array cannot overflow.
    modes: [max_depth + 1]Mode = undefined,
    mode_depth: usize = 0,

    fn errAt(
        p: *Parser,
        kind: diag.Kind,
        offset: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) error{Template} {
        return diag.fail(p.alloc, p.diag, kind, p.src, offset, fmt, args);
    }

    /// True when a frame with mode `m` is open outside the innermost frame.
    /// The innermost frame is the sequence rejecting the closing tag, and its
    /// mode is exactly the one the tag failed to match, so it can never be
    /// `m` itself — any hit is a block the tag would have to reach across.
    fn isOpen(p: *const Parser, m: Mode) bool {
        var i: usize = 0;
        while (i + 1 < p.mode_depth) : (i += 1) {
            if (p.modes[i] == m) return true;
        }
        return false;
    }

    fn makeCond(p: *Parser, c: Cond) Error!*Cond {
        const ptr = try p.alloc.create(Cond);
        ptr.* = c;
        return ptr;
    }

    /// Scans a line fragment for "only whitespace, `{% %}` tags and
    /// `{# #}` comments" — the standalone-line content rule. `{{` output
    /// tags and literal text disqualify a line.
    fn tagLineContent(s: []const u8) bool {
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c == ' ' or c == '\t') {
                i += 1;
            } else if (std.mem.startsWith(u8, s[i..], "{%")) {
                const close = std.mem.indexOfPos(u8, s, i + 2, "%}") orelse return false;
                i = close + 2;
            } else if (std.mem.startsWith(u8, s[i..], "{#")) {
                const close = std.mem.indexOfPos(u8, s, i + 2, "#}") orelse return false;
                i = close + 2;
            } else {
                return false;
            }
        }
        return true;
    }

    /// Whether the tag spanning [tag_start, tag_end) sits on a line whose
    /// other content is only whitespace and `{%`/`{#` tags.
    fn lineStandalone(p: *const Parser, tag_start: usize, tag_end: usize) bool {
        var ls = tag_start;
        while (ls > 0 and p.src[ls - 1] != '\n') ls -= 1;
        if (!tagLineContent(p.src[ls..tag_start])) return false;
        var j = tag_end;
        while (j < p.src.len and p.src[j] != '\n') j += 1;
        return tagLineContent(p.src[tag_end..j]);
    }

    /// After a standalone open/mid tag, consume the rest of its line:
    /// trailing spaces/tabs plus one newline.
    fn eatLineEnd(p: *Parser) void {
        var j = p.i;
        while (j < p.src.len and (p.src[j] == ' ' or p.src[j] == '\t')) j += 1;
        if (j < p.src.len and p.src[j] == '\n') {
            p.i = j + 1;
        } else if (j + 1 < p.src.len and p.src[j] == '\r' and p.src[j + 1] == '\n') {
            p.i = j + 2;
        }
    }

    /// An `{% endif %}`/`{% else %}`/`{% elseif %}` tag swallows the
    /// whitespace run that ends the branch body — `A\n  {% endif %}`
    /// leaves `A`, not `A\n`.
    fn trimBodyTail(nodes: []Node) void {
        if (nodes.len == 0) return;
        switch (nodes[nodes.len - 1]) {
            .text => |t| {
                var end = t.len;
                while (end > 0 and (t[end - 1] == ' ' or t[end - 1] == '\t' or t[end - 1] == '\n' or t[end - 1] == '\r')) end -= 1;
                nodes[nodes.len - 1] = .{ .text = t[0..end] };
            },
            else => {},
        }
    }

    /// Drop one trailing newline (and a `\r` before it) of the body's
    /// last text node.
    fn dropTailNewline(nodes: []Node) void {
        if (nodes.len == 0) return;
        switch (nodes[nodes.len - 1]) {
            .text => |t| {
                var end = t.len;
                if (end > 0 and t[end - 1] == '\n') {
                    end -= 1;
                    if (end > 0 and t[end - 1] == '\r') end -= 1;
                    nodes[nodes.len - 1] = .{ .text = t[0..end] };
                }
            },
            else => {},
        }
    }

    /// An inline block opener eats the same-line whitespace at the head
    /// of the body it opens (`{% if x %} a {% endif %}` -> `a`).
    fn trimHeadSpaces(nodes: []Node) void {
        if (nodes.len == 0) return;
        switch (nodes[0]) {
            .text => |t| {
                var n: usize = 0;
                while (n < t.len and (t[n] == ' ' or t[n] == '\t')) n += 1;
                if (n > 0) nodes[0] = .{ .text = t[n..] };
            },
            else => {},
        }
    }

    fn parseSeq(p: *Parser, mode: Mode, depth: usize) Error!SeqResult {
        p.modes[p.mode_depth] = mode;
        p.mode_depth += 1;
        defer p.mode_depth -= 1;

        var nodes = std.ArrayList(Node).empty;
        errdefer nodes.deinit(p.alloc);

        var trim_next_text = false;
        while (p.i < p.src.len) {
            const rest = p.src[p.i..];
            if (std.mem.startsWith(u8, rest, "{{")) {
                trim_next_text = false;
                const tag_start = p.i;
                const content = try p.tagContent(tag_start, "{{", "}}");
                const expr = try p.parseExprTag(content, tag_start, true);
                try nodes.append(p.alloc, .{ .output = expr });
            } else if (std.mem.startsWith(u8, rest, "{%")) {
                const tag_start = p.i;
                const content = try p.tagContent(tag_start, "{%", "%}");
                const standalone = p.lineStandalone(tag_start, p.i);
                const tag = try p.parseLogicTag(content, tag_start, tag_start + 2, mode, depth, standalone, &nodes);
                trim_next_text = tag.trim_next;
                switch (tag.kind) {
                    .terminated => |t| {
                        return .{
                            .nodes = try nodes.toOwnedSlice(p.alloc),
                            .end = t.end,
                            .end_offset = tag_start,
                            .end_content = t.content,
                            .end_content_offset = t.content_offset,
                            .end_standalone = standalone,
                            .end_col0 = standalone and tagAtLineStart(p, tag_start),
                        };
                    },
                    .if_node => |ifc| try nodes.append(p.alloc, .{ .ifelse = ifc }),
                    .loop_node => |ln| try nodes.append(p.alloc, .{ .loop = ln }),
                    .set_node => |sn| try nodes.append(p.alloc, .{ .set = sn }),
                }
            } else if (std.mem.startsWith(u8, rest, "{#")) {
                const close = std.mem.indexOf(u8, rest, "#}") orelse
                    return p.errAt(.syntax, p.i, "unclosed comment (missing '#}}')", .{});
                p.i += close + 2;
            } else {
                const stop = nextOpener(rest) orelse rest.len;
                if (stop > 0) {
                    var text = rest[0..stop];
                    if (trim_next_text) {
                        // An inline opener eats the same-line whitespace
                        // that follows it (`{% if x %} a {% endif %}` ->
                        // `a`). Newlines are not part of the run.
                        var n: usize = 0;
                        while (n < text.len and (text[n] == ' ' or text[n] == '\t')) n += 1;
                        text = text[n..];
                    }
                    trim_next_text = false;
                    if (text.len > 0) try nodes.append(p.alloc, .{ .text = text });
                    p.i += stop;
                } else {
                    // rest[0] is '{' but not an opener: emit a single byte.
                    try nodes.append(p.alloc, .{ .text = rest[0..1] });
                    trim_next_text = false;
                    p.i += 1;
                }
            }
        }

        return .{
            .nodes = try nodes.toOwnedSlice(p.alloc),
            .end = .eof,
            .end_offset = p.src.len,
            .end_content = "",
            .end_content_offset = p.src.len,
            .end_standalone = false,
            .end_col0 = false,
        };
    }

    /// Returns the content inside `<open> ... <close>`, advancing p.i past
    /// the closing delimiter. Quoted strings inside the tag may contain the
    /// closing delimiter.
    fn tagContent(
        p: *Parser,
        tag_start: usize,
        open: []const u8,
        close: []const u8,
    ) error{Template}![]const u8 {
        var i = tag_start + open.len;
        var in_string: u8 = 0;
        while (i < p.src.len) {
            const c = p.src[i];
            if (in_string != 0) {
                if (c == '\\') {
                    i += 2;
                    continue;
                }
                if (c == in_string) in_string = 0;
                i += 1;
            } else if (c == '\'' or c == '"') {
                in_string = c;
                i += 1;
            } else if (std.mem.startsWith(u8, p.src[i..], close)) {
                const content = p.src[tag_start + open.len .. i];
                p.i = i + close.len;
                return content;
            } else {
                i += 1;
            }
        }
        return p.errAt(.syntax, tag_start, "unclosed '{s}' tag (missing '{s}')", .{ open, close });
    }

    const LogicTag = struct {
        kind: Kind,
        /// The tag was inline (not standalone); the parser trims the
        /// leading spaces/tabs of the next text node.
        trim_next: bool = false,

        const Kind = union(enum) {
            terminated: struct { end: EndTag, content: []const u8, content_offset: usize },
            if_node: IfChain,
            loop_node: LoopNode,
            set_node: SetNode,
        };
    };

    fn parseLogicTag(
        p: *Parser,
        content: []const u8,
        tag_start: usize,
        content_offset: usize,
        mode: Mode,
        depth: usize,
        standalone: bool,
        nodes: *std.ArrayList(Node),
    ) Error!LogicTag {
        var q = Scanner{ .p = p, .text = content, .base = content_offset };
        q.skipWs();
        const keyword = q.word() orelse return q.err("empty logic tag", .{});

        if (std.mem.eql(u8, keyword, "if")) {
            if (depth >= max_depth) return q.err("nesting too deep (max {d} levels)", .{max_depth});
            const chain = try q.parseChainExpr(false);
            if (standalone) p.eatLineEnd();
            const ifc = try p.parseIfChain(chain, tag_start, depth + 1, standalone);
            return .{ .kind = .{ .if_node = ifc }, .trim_next = false };
        }
        if (std.mem.eql(u8, keyword, "for")) {
            if (depth >= max_depth) return q.err("nesting too deep (max {d} levels)", .{max_depth});
            const var_name = q.word() orelse return q.err("expected a loop variable name after 'for'", .{});
            q.skipWs();
            if (!q.matchWord("in")) return q.err("expected 'in' in for tag", .{});
            const list_expr = try q.parseExpr(false);
            q.skipWs();
            if (!q.eof()) return q.err("unexpected text after the for expression", .{});
            if (standalone) {
                p.eatLineEnd();
            }
            const seq = try p.parseSeq(.loop_body, depth + 1);
            if (!standalone) trimHeadSpaces(seq.nodes);
            switch (seq.end) {
                .endfor => {
                    var qe = Scanner{ .p = p, .text = seq.end_content, .base = seq.end_content_offset };
                    _ = qe.word();
                    qe.skipWs();
                    if (!qe.eof()) return qe.err("unexpected text in '{{% endfor %}}'", .{});
                    return .{ .kind = .{ .loop_node = .{
                        .var_name = var_name,
                        .list = list_expr,
                        .body = seq.nodes,
                        .offset = tag_start,
                        .endfor_standalone = seq.end_standalone,
                        .endfor_col0 = seq.end_col0,
                        .strip_first = standalone,
                    } }, .trim_next = false };
                },
                .eof => return p.errAt(.syntax, tag_start, "unclosed for block (missing '{{% endfor %}}')", .{}),
                else => return p.errAt(.syntax, seq.end_offset, "unexpected '{s}' tag inside a for block", .{endTagWord(seq.end)}),
            }
        }
        if (std.mem.eql(u8, keyword, "set")) {
            q.skipWs();
            const name = q.word() orelse return q.err("expected a variable name after 'set'", .{});
            q.skipWs();
            if (!q.matchOp("=")) return q.err("expected '=' in set tag", .{});
            const expr = try q.parseChainExpr(false);
            q.skipWs();
            if (!q.eof()) return q.err("unexpected text after the set expression", .{});
            if (standalone) p.eatLineEnd();
            return .{ .kind = .{ .set_node = .{ .name = name, .expr = expr, .offset = tag_start } }, .trim_next = !standalone };
        }
        if (std.mem.eql(u8, keyword, "elseif")) {
            if (mode != .branch) {
                if (p.isOpen(.branch)) return q.err("unexpected '{{% elseif %}}' inside a for block", .{});
                return q.err("unexpected '{{% elseif %}}' outside an if block", .{});
            }
            if (standalone) {
                trimBodyTail(nodes.items);
                p.eatLineEnd();
            }
            return .{ .kind = .{ .terminated = .{ .end = .elseif, .content = content, .content_offset = content_offset } }, .trim_next = false };
        }
        if (std.mem.eql(u8, keyword, "else")) {
            if (mode != .branch) {
                if (p.isOpen(.branch)) return q.err("unexpected '{{% else %}}' inside a for block", .{});
                return q.err("unexpected '{{% else %}}' outside an if block", .{});
            }
            if (standalone) {
                trimBodyTail(nodes.items);
                p.eatLineEnd();
            }
            return .{ .kind = .{ .terminated = .{ .end = .else_, .content = content, .content_offset = content_offset } }, .trim_next = false };
        }
        if (std.mem.eql(u8, keyword, "endif")) {
            if (mode != .branch) {
                if (p.isOpen(.branch)) return q.err("unexpected '{{% endif %}}' inside a for block", .{});
                return q.err("unexpected '{{% endif %}}' outside an if block", .{});
            }
            if (standalone) {
                trimBodyTail(nodes.items);
                // The `\n` after `{% endif %}` stays as emitted text.
            }
            return .{ .kind = .{ .terminated = .{ .end = .endif, .content = content, .content_offset = content_offset } } };
        }
        if (std.mem.eql(u8, keyword, "endfor")) {
            if (mode != .loop_body) {
                if (p.isOpen(.loop_body)) return q.err("unexpected '{{% endfor %}}' inside an if block", .{});
                return q.err("unexpected '{{% endfor %}}' outside a for block", .{});
            }
            if (standalone and tagAtLineStart(p, tag_start)) {
                // A column-0 `{% endfor %}` eats the one newline that
                // ends the line before it — including the newline a
                // previous standalone closer left behind. An indented
                // `  {% endfor %}` instead leaves the whitespace inside
                // the body, where it lands between iterations.
                dropTailNewline(nodes.items);
            }
            // The `\n` after `{% endfor %}` stays as emitted text.
            return .{ .kind = .{ .terminated = .{ .end = .endfor, .content = content, .content_offset = content_offset } } };
        }
        return q.err("unknown logic tag '{s}'", .{keyword});
    }

    /// True when nothing but the newline precedes the tag on its line —
    /// the column-0 case of a standalone tag.
    fn tagAtLineStart(p: *const Parser, tag_start: usize) bool {
        var ls = tag_start;
        while (ls > 0 and p.src[ls - 1] != '\n') ls -= 1;
        return ls == tag_start;
    }

    /// Trim trailing spaces/tabs (not newlines) of the last text node —
    /// an inline if-family closer eats the same-line whitespace before it.
    fn trimTailSpaces(nodes: []Node) void {
        if (nodes.len == 0) return;
        switch (nodes[nodes.len - 1]) {
            .text => |t| {
                var end = t.len;
                while (end > 0 and (t[end - 1] == ' ' or t[end - 1] == '\t')) end -= 1;
                nodes[nodes.len - 1] = .{ .text = t[0..end] };
            },
            else => {},
        }
    }

    fn parseIfChain(
        p: *Parser,
        first_cond: Chain,
        open_offset: usize,
        depth: usize,
        open_standalone: bool,
    ) Error!IfChain {
        var branches = std.ArrayList(Branch).empty;
        errdefer branches.deinit(p.alloc);

        var current_cond: ?Chain = first_cond;
        var current_open = open_offset;
        var saw_else = false;

        var seq = try p.parseSeq(.branch, depth);
        if (!open_standalone) trimHeadSpaces(seq.nodes);
        var next_trim = false;
        while (true) {
            switch (seq.end) {
                .elseif => {
                    if (saw_else) return p.errAt(.syntax, seq.end_offset, "unexpected '{{% elseif %}}' after '{{% else %}}'", .{});
                    try branches.append(p.alloc, .{ .cond = current_cond, .body = seq.nodes, .offset = current_open });
                    var q = Scanner{ .p = p, .text = seq.end_content, .base = seq.end_content_offset };
                    _ = q.word();
                    const chain = try q.parseChainExpr(false);
                    current_cond = chain;
                    current_open = seq.end_offset;
                    next_trim = !seq.end_standalone;
                    seq = try p.parseSeq(.branch, depth);
                    if (next_trim) trimHeadSpaces(seq.nodes);
                },
                .else_ => {
                    if (saw_else) return p.errAt(.syntax, seq.end_offset, "duplicate '{{% else %}}'", .{});
                    saw_else = true;
                    try branches.append(p.alloc, .{ .cond = current_cond, .body = seq.nodes, .offset = current_open });
                    var q = Scanner{ .p = p, .text = seq.end_content, .base = seq.end_content_offset };
                    _ = q.word();
                    q.skipWs();
                    if (!q.eof()) return q.err("unexpected text in '{{% else %}}'", .{});
                    current_cond = null;
                    current_open = seq.end_offset;
                    next_trim = !seq.end_standalone;
                    seq = try p.parseSeq(.branch, depth);
                    if (next_trim) trimHeadSpaces(seq.nodes);
                },
                .endif => {
                    try branches.append(p.alloc, .{ .cond = current_cond, .body = seq.nodes, .offset = current_open });
                    var q = Scanner{ .p = p, .text = seq.end_content, .base = seq.end_content_offset };
                    _ = q.word();
                    q.skipWs();
                    if (!q.eof()) return q.err("unexpected text in '{{% endif %}}'", .{});
                    return .{ .branches = try branches.toOwnedSlice(p.alloc), .offset = open_offset };
                },
                .eof => return p.errAt(.syntax, open_offset, "unclosed if block (missing '{{% endif %}}')", .{}),
                .endfor => return p.errAt(.syntax, seq.end_offset, "unexpected '{{% endfor %}}' inside an if block", .{}),
            }
        }
    }

    fn parseExprTag(p: *Parser, content: []const u8, tag_start: usize, spaced_names: bool) Error!Chain {
        var q = Scanner{ .p = p, .text = content, .base = tag_start + 2 };
        const chain = try q.parseChainExpr(spaced_names);
        q.skipWs();
        if (!q.eof()) return q.err("unexpected text in output tag", .{});
        return chain;
    }
};

const Scanner = struct {
    p: *Parser,
    text: []const u8,
    base: usize,
    pos: usize = 0,

    fn abs(s: *const Scanner) usize {
        return s.base + s.pos;
    }

    fn eof(s: *const Scanner) bool {
        return s.pos >= s.text.len;
    }

    fn peek(s: *const Scanner) ?u8 {
        return if (s.pos < s.text.len) s.text[s.pos] else null;
    }

    fn skipWs(s: *Scanner) void {
        while (s.pos < s.text.len and isWs(s.text[s.pos])) s.pos += 1;
    }

    fn err(s: *Scanner, comptime fmt: []const u8, args: anytype) error{Template} {
        return diag.fail(s.p.alloc, s.p.diag, .syntax, s.p.src, s.abs(), fmt, args);
    }

    fn matchOp(s: *Scanner, op: []const u8) bool {
        if (s.pos + op.len <= s.text.len and std.mem.eql(u8, s.text[s.pos .. s.pos + op.len], op)) {
            s.pos += op.len;
            return true;
        }
        return false;
    }

    fn matchWord(s: *Scanner, token: []const u8) bool {
        if (!std.mem.startsWith(u8, s.text[s.pos..], token)) return false;
        const after = s.pos + token.len;
        if (after < s.text.len and isNameChar(s.text[after])) return false;
        s.pos = after;
        return true;
    }

    fn matchBang(s: *Scanner) bool {
        if (s.pos < s.text.len and s.text[s.pos] == '!' and
            (s.pos + 1 >= s.text.len or s.text[s.pos + 1] != '='))
        {
            s.pos += 1;
            return true;
        }
        return false;
    }

    fn word(s: *Scanner) ?[]const u8 {
        s.skipWs();
        const start = s.pos;
        while (s.pos < s.text.len and isNameChar(s.text[s.pos])) s.pos += 1;
        if (s.pos == start) return null;
        return s.text[start..s.pos];
    }

    fn parseStringLit(s: *Scanner) Error!StringLit {
        const quote = s.text[s.pos];
        s.pos += 1;
        var needs_copy = false;
        var scan = s.pos;
        while (scan < s.text.len) {
            const c = s.text[scan];
            if (c == '\\') {
                needs_copy = true;
                scan += 2;
                continue;
            }
            if (c == quote) break;
            scan += 1;
        }
        if (scan >= s.text.len) return s.err("unterminated string literal", .{});
        const raw = s.text[s.pos..scan];
        s.pos = scan + 1;
        if (!needs_copy) return .{ .value = raw, .raw = raw };
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(s.p.alloc);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                // knap 0.6.0 maps only \n \t \r to control bytes; every
                // other \X drops the backslash (\x41 -> x41, not 'A').
                try buf.append(s.p.alloc, switch (raw[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => raw[i + 1],
                });
                i += 2;
            } else {
                try buf.append(s.p.alloc, raw[i]);
                i += 1;
            }
        }
        return .{ .value = try buf.toOwnedSlice(s.p.alloc), .raw = raw };
    }

    fn parseNumberLit(s: *Scanner) error{Template}!Literal {
        const start = s.pos;
        if (s.text[s.pos] == '-') s.pos += 1;
        while (s.pos < s.text.len and std.ascii.isDigit(s.text[s.pos])) s.pos += 1;
        var is_float = false;
        if (s.pos + 1 < s.text.len and s.text[s.pos] == '.' and std.ascii.isDigit(s.text[s.pos + 1])) {
            is_float = true;
            s.pos += 1;
            while (s.pos < s.text.len and std.ascii.isDigit(s.text[s.pos])) s.pos += 1;
        }
        if (s.pos < s.text.len and isNameChar(s.text[s.pos])) {
            return s.err("invalid number literal", .{});
        }
        const slice = s.text[start..s.pos];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, slice) catch return s.err("invalid number literal", .{});
            return .{ .float = f };
        }
        const n = std.fmt.parseInt(i64, slice, 10) catch {
            // Wider than i64: JS parses every literal as a double, so fall
            // back to float to match (`9007199254740993` -> 9007199254740992).
            const f = std.fmt.parseFloat(f64, slice) catch return s.err("invalid number literal", .{});
            return .{ .float = f };
        };
        return .{ .integer = n };
    }

    /// A full `??` fallback chain: `term | f ?? "default"`.
    fn parseExpr(s: *Scanner, spaced_names: bool) Error!Expr {
        var terms = std.ArrayList(Pipeline).empty;
        errdefer terms.deinit(s.p.alloc);
        while (true) {
            const pipe = try s.parsePipelineInner(spaced_names, s.abs());
            try terms.append(s.p.alloc, pipe);
            s.skipWs();
            if (s.matchOp("??")) continue;
            break;
        }
        return .{ .terms = try terms.toOwnedSlice(s.p.alloc) };
    }

    fn parsePipelineInner(s: *Scanner, spaced_names: bool, offset: usize) Error!Pipeline {
        const value = try s.parsePrimary(spaced_names);
        var filter_list = std.ArrayList(FilterCall).empty;
        errdefer filter_list.deinit(s.p.alloc);
        while (true) {
            const save = s.pos;
            s.skipWs();
            if (s.eof() or s.peek() != '|') {
                s.pos = save;
                break;
            }
            // `||` is the boolean operator, not a filter.
            if (s.pos + 1 < s.text.len and s.text[s.pos + 1] == '|') {
                s.pos = save;
                break;
            }
            s.pos += 1;
            s.skipWs();
            const fstart = s.pos;
            const name = s.word() orelse return s.err("expected a filter name after '|'", .{});
            var params = std.ArrayList(Param).empty;
            errdefer params.deinit(s.p.alloc);
            s.skipWs();
            if (!s.eof() and s.peek() == ':') {
                s.pos += 1;
                try s.parseParams(&params);
            }
            try filter_list.append(s.p.alloc, .{
                .name = name,
                .params = try params.toOwnedSlice(s.p.alloc),
                .offset = s.base + fstart,
            });
        }
        return .{
            .value = value,
            .filters = try filter_list.toOwnedSlice(s.p.alloc),
            .offset = offset,
        };
    }

    /// Filter arguments after `:` — `(a, b)`, `"k":"v"`, `x => expr`,
    /// bare tokens like `2n` or `2,3:4`, quoted strings, numbers,
    /// booleans, null and paths.
    fn parseParams(s: *Scanner, params: *std.ArrayList(Param)) Error!void {
        s.skipWs();
        var paren = false;
        if (!s.eof() and s.peek() == '(') {
            paren = true;
            s.pos += 1;
        }
        while (true) {
            s.skipWs();
            if (paren and !s.eof() and s.peek() == ')') {
                s.pos += 1;
                if (params.items.len == 0) {
                    return s.err("expected a filter argument inside '()'", .{});
                }
                return;
            }
            if (s.eof()) {
                if (paren) return s.err("unclosed '(' in filter arguments", .{});
                return;
            }
            try s.parseParam(params);
            s.skipWs();
            if (paren) {
                if (!s.eof() and s.peek() == ',') {
                    s.pos += 1;
                    continue;
                }
                if (!s.eof() and s.peek() == ')') {
                    s.pos += 1;
                    return;
                }
                return s.err("expected ',' or ')' in filter arguments", .{});
            }
            // Unparenthesized lists only continue after a pair (`"a":"b", "c":"d"`).
            if (!s.eof() and s.peek() == ',') {
                s.pos += 1;
                continue;
            }
            return;
        }
    }

    fn parseParam(s: *Scanner, params: *std.ArrayList(Param)) Error!void {
        // Arrow expression: `name => body`.
        {
            const save = s.pos;
            if (s.word()) |w| {
                s.skipWs();
                if (s.matchOp("=>")) {
                    const body = try s.parseArrowBody();
                    try params.append(s.p.alloc, .{ .arrow = .{ .var_name = w, .body = body } });
                    return;
                }
            }
            s.pos = save;
        }
        const expr = try s.parseParamExpr();
        s.skipWs();
        // `"k":"v"` / `name:value` pairs.
        if (!s.eof() and s.peek() == ':' and
            !(s.pos + 1 < s.text.len and s.text[s.pos + 1] == ':'))
        {
            s.pos += 1;
            const value = try s.parseParamExpr();
            const key = try s.p.alloc.create(Expr);
            key.* = expr;
            const val = try s.p.alloc.create(Expr);
            val.* = value;
            try params.append(s.p.alloc, .{ .pair = .{ .key = key, .value = val } });
            return;
        }
        const single = try s.p.alloc.create(Expr);
        single.* = expr;
        try params.append(s.p.alloc, .{ .value = single });
    }

    /// One parameter value: quoted string, number, boolean, null, a
    /// parenthesized expression, or a bare token (path or pattern).
    /// No `|` filters, no `??` inside a single param.
    fn parseParamExpr(s: *Scanner) Error!Expr {
        s.skipWs();
        const c = s.peek() orelse return s.err("expected a filter argument", .{});
        var primary: Primary = undefined;
        if (c == '"' or c == '\'') {
            primary = .{ .literal = .{ .string = try s.parseStringLit() } };
        } else if (std.ascii.isDigit(c) or
            (c == '-' and s.pos + 1 < s.text.len and std.ascii.isDigit(s.text[s.pos + 1])))
        {
            // A bare token like `2,3:4` (nth patterns) is not a number:
            // scan ahead and keep the whole token when it is not numeric.
            const save = s.pos;
            if (s.parseNumberLit()) |lit| {
                primary = .{ .literal = lit };
            } else |_| {
                s.pos = save;
                const start = s.pos;
                while (s.pos < s.text.len and isBareChar(s.text[s.pos])) s.pos += 1;
                if (s.pos == start) return s.err("expected a filter argument", .{});
                const tok = s.text[start..s.pos];
                // knap tokenizes `1e1`/`0x10` as a malformed number and
                // errors; only `5n`-style nth patterns may carry letters
                // after a leading digit run.
                if (std.ascii.isDigit(tok[0])) {
                    var has_letter = false;
                    for (tok) |ch| {
                        if (std.ascii.isAlphabetic(ch)) has_letter = true;
                    }
                    const nth_pat = tok.len >= 2 and tok[tok.len - 1] == 'n' and
                        std.fmt.parseInt(u64, tok[0 .. tok.len - 1], 10) != error.InvalidCharacter;
                    if (has_letter and !nth_pat) {
                        s.pos = save;
                        return s.err("invalid number literal", .{});
                    }
                }
                primary = .{ .literal = .{ .string = .{ .value = tok, .raw = tok } } };
            }
        } else if (c == '(') {
            // Nested parenthesized expression — treat like a literal arg group.
            s.pos += 1;
            const inner = try s.parseExpr(false);
            s.skipWs();
            if (s.eof() or s.peek() != ')') return s.err("expected ')'", .{});
            s.pos += 1;
            return inner;
        } else if (s.matchWord("true")) {
            primary = .{ .literal = .{ .boolean = true } };
        } else if (s.matchWord("false")) {
            primary = .{ .literal = .{ .boolean = false } };
        } else if (s.matchWord("null")) {
            primary = .{ .literal = .null };
        } else {
            // Bare token: variable path (`url`, `a.b`) or a pattern
            // (`2n`, `[0-9]`, `/re/g`, `numbered-task`). Bare tokens may
            // contain `:` and `,` — `replace:"a":"b"` is handled by the
            // quoted-string path, while `nth:2,3:4` needs them.
            const start = s.pos;
            var bracket_depth: usize = 0;
            while (s.pos < s.text.len) {
                const b = s.text[s.pos];
                if (b == '[') bracket_depth += 1;
                if (b == ']') {
                    if (bracket_depth == 0) break;
                    bracket_depth -= 1;
                }
                if (bracket_depth == 0 and !isBareChar(b)) break;
                if (bracket_depth > 0 and (b == '|' or b == ' ' or b == '\t')) break;
                s.pos += 1;
            }
            const tok = s.text[start..s.pos];
            if (tok.len == 0) return s.err("expected a filter argument", .{});
            // A bare token is a path when it walks like one (name chars,
            // dots, bracket steps); anything else is a pattern literal.
            if (looksLikePath(tok)) {
                var q = Scanner{ .p = s.p, .text = tok, .base = s.abs() - tok.len };
                primary = .{ .path = try q.parsePath(false) };
            } else {
                primary = .{ .literal = .{ .string = .{ .value = tok, .raw = tok } } };
            }
        }
        const pipe = Pipeline{ .value = primary, .filters = &.{}, .offset = s.abs() };
        const terms = try s.p.alloc.alloc(Pipeline, 1);
        terms[0] = pipe;
        return .{ .terms = terms };
    }

    fn parseArrowBody(s: *Scanner) Error!ArrowBody {
        s.skipWs();
        const c = s.peek() orelse return s.err("expected an arrow body after '=>'", .{});
        if (c == '(') {
            s.pos += 1;
            s.skipWs();
            if (s.eof() or s.peek() != '{') {
                return s.err("expected '{{' to open the arrow object", .{});
            }
            s.pos += 1;
            var fields = std.ArrayList(ArrowField).empty;
            errdefer fields.deinit(s.p.alloc);
            while (true) {
                s.skipWs();
                if (!s.eof() and s.peek() == '}') {
                    s.pos += 1;
                    s.skipWs();
                    if (s.eof() or s.peek() != ')') {
                        return s.err("expected ')' after the arrow object", .{});
                    }
                    s.pos += 1;
                    if (fields.items.len == 0) return s.err("expected an object field in the arrow body", .{});
                    break;
                }
                s.skipWs();
                const name = if (s.peek() == '"' or s.peek() == '\'')
                    (try s.parseStringLit()).value
                else
                    (s.word() orelse return s.err("expected a field name in the arrow object", .{}));
                s.skipWs();
                if (s.eof() or s.peek() != ':') return s.err("expected ':' after an arrow object field name", .{});
                s.pos += 1;
                s.skipWs();
                const value = try s.parseArrowValue();
                try fields.append(s.p.alloc, .{ .name = name, .value = value });
                s.skipWs();
                if (!s.eof() and s.peek() == ',') {
                    s.pos += 1;
                    continue;
                }
                if (!s.eof() and s.peek() == '}') {
                    s.pos += 1;
                    s.skipWs();
                    if (s.eof() or s.peek() != ')') {
                        return s.err("expected ')' after the arrow object", .{});
                    }
                    s.pos += 1;
                    break;
                }
                return s.err("expected ',' or '}}' in the arrow object", .{});
            }
            return .{ .object = try fields.toOwnedSlice(s.p.alloc) };
        }
        if (c == '"' or c == '\'') {
            const raw = try s.parseStringLit();
            const parts = try s.splitInterp(raw.value);
            if (parts.len == 1 and parts[0] == .text) return .{ .literal = .{ .string = .{ .value = raw.value, .raw = raw.raw } } };
            return .{ .interp = parts };
        }
        if (std.ascii.isDigit(c) or
            (c == '-' and s.pos + 1 < s.text.len and std.ascii.isDigit(s.text[s.pos + 1])))
        {
            return .{ .literal = try s.parseNumberLit() };
        }
        if (s.matchWord("true")) return .{ .literal = .{ .boolean = true } };
        if (s.matchWord("false")) return .{ .literal = .{ .boolean = false } };
        if (s.matchWord("null")) return .{ .literal = .null };
        return .{ .path = try s.parsePath(false) };
    }

    fn parseArrowValue(s: *Scanner) Error!ArrowValue {
        s.skipWs();
        const c = s.peek() orelse return s.err("expected a value in the arrow object", .{});
        if (c == '"' or c == '\'') {
            const raw = try s.parseStringLit();
            const parts = try s.splitInterp(raw.value);
            if (parts.len == 1 and parts[0] == .text) return .{ .literal = .{ .string = .{ .value = raw.value, .raw = raw.raw } } };
            return .{ .interp = parts };
        }
        if (std.ascii.isDigit(c) or
            (c == '-' and s.pos + 1 < s.text.len and std.ascii.isDigit(s.text[s.pos + 1])))
        {
            return .{ .literal = try s.parseNumberLit() };
        }
        if (s.matchWord("true")) return .{ .literal = .{ .boolean = true } };
        if (s.matchWord("false")) return .{ .literal = .{ .boolean = false } };
        if (s.matchWord("null")) return .{ .literal = .null };
        return .{ .path = try s.parsePath(false) };
    }

    /// `"${a.b} text ${c}"` -> interp parts. `${` must contain a path;
    /// a lone `$` stays literal.
    fn splitInterp(s: *Scanner, raw: []const u8) Error![]const InterpPart {
        var parts = std.ArrayList(InterpPart).empty;
        errdefer parts.deinit(s.p.alloc);
        var i: usize = 0;
        var text_start: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                const close = std.mem.indexOfPos(u8, raw, i + 2, "}") orelse
                    return s.err("unclosed '${{' in string", .{});
                const inner = raw[i + 2 .. close];
                var q = Scanner{ .p = s.p, .text = inner, .base = s.abs() + i + 2 };
                const path = try q.parsePath(false);
                q.skipWs();
                if (!q.eof()) return q.err("expected a path inside '${{}}'", .{});
                if (i > text_start) try parts.append(s.p.alloc, .{ .text = raw[text_start..i] });
                try parts.append(s.p.alloc, .{ .path = path });
                i = close + 1;
                text_start = i;
            } else {
                i += 1;
            }
        }
        if (text_start < raw.len) try parts.append(s.p.alloc, .{ .text = raw[text_start..] });
        if (parts.items.len == 0) try parts.append(s.p.alloc, .{ .text = "" });
        return parts.toOwnedSlice(s.p.alloc);
    }

    fn parsePrimary(s: *Scanner, spaced_names: bool) Error!Primary {
        s.skipWs();
        const c = s.peek() orelse return s.err("expected a value", .{});
        if (c == '"' or c == '\'') {
            const str = try s.parseStringLit();
            return .{ .literal = .{ .string = .{ .value = str.value, .raw = str.raw } } };
        }
        if (std.ascii.isDigit(c) or
            (c == '-' and s.pos + 1 < s.text.len and std.ascii.isDigit(s.text[s.pos + 1])))
        {
            return .{ .literal = try s.parseNumberLit() };
        }
        if (s.matchWord("true")) return .{ .literal = .{ .boolean = true } };
        if (s.matchWord("false")) return .{ .literal = .{ .boolean = false } };
        if (s.matchWord("null")) return .{ .literal = .null };
        return .{ .path = try s.parsePath(spaced_names) };
    }

    fn parsePath(s: *Scanner, spaced_names: bool) Error!Path {
        var steps = std.ArrayList(Step).empty;
        errdefer steps.deinit(s.p.alloc);

        const root = try s.parseName(spaced_names);
        while (true) {
            const c = s.peek() orelse break;
            if (c == '.') {
                s.pos += 1;
                const name = try s.parseName(spaced_names);
                try steps.append(s.p.alloc, .{ .key = name });
            } else if (c == '[') {
                s.pos += 1;
                s.skipWs();
                const k = s.peek() orelse return s.err("unclosed '[' in path", .{});
                if (k == '"' or k == '\'') {
                    const key = try s.parseStringLit();
                    s.skipWs();
                    if (s.peek() != ']') return s.err("expected ']' after bracket key", .{});
                    s.pos += 1;
                    try steps.append(s.p.alloc, .{ .key = key.value });
                } else if (std.ascii.isDigit(k)) {
                    const dstart = s.pos;
                    while (s.pos < s.text.len and std.ascii.isDigit(s.text[s.pos])) s.pos += 1;
                    const idx = std.fmt.parseInt(u64, s.text[dstart..s.pos], 10) catch
                        return s.err("invalid array index", .{});
                    s.skipWs();
                    if (s.peek() != ']') return s.err("expected ']' after array index", .{});
                    s.pos += 1;
                    try steps.append(s.p.alloc, .{ .index = idx });
                } else {
                    // `x[expr]` — dynamic key or index.
                    const inner = try s.parseExpr(false);
                    if (inner.terms.len != 1 or inner.terms[0].filters.len != 0) {
                        return s.err("bracket access takes a single value expression", .{});
                    }
                    s.skipWs();
                    if (s.peek() != ']') return s.err("expected ']' after bracket expression", .{});
                    s.pos += 1;
                    const pipe = try s.p.alloc.create(Pipeline);
                    pipe.* = inner.terms[0];
                    try steps.append(s.p.alloc, .{ .expr = pipe });
                }
            } else {
                break;
            }
        }
        return .{ .root = root, .steps = try steps.toOwnedSlice(s.p.alloc) };
    }

    fn parseName(s: *Scanner, spaced_names: bool) Error![]const u8 {
        s.skipWs();
        if (!spaced_names) {
            const start = s.pos;
            while (s.pos < s.text.len and isNameChar(s.text[s.pos])) s.pos += 1;
            if (s.pos == start) return s.err("expected a variable name", .{});
            return s.text[start..s.pos];
        }
        // Spaced mode (interpolation and filter inputs): join
        // whitespace-separated name tokens with a single space and stop at
        // the first non-name character.
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(s.p.alloc);
        while (true) {
            const start = s.pos;
            while (s.pos < s.text.len and isNameChar(s.text[s.pos])) s.pos += 1;
            if (s.pos == start) break;
            if (buf.items.len > 0) try buf.append(s.p.alloc, ' ');
            try buf.appendSlice(s.p.alloc, s.text[start..s.pos]);
            const save = s.pos;
            s.skipWs();
            if (s.pos < s.text.len and isNameChar(s.text[s.pos])) continue;
            s.pos = save;
            break;
        }
        if (buf.items.len == 0) return s.err("expected a variable name", .{});
        return buf.toOwnedSlice(s.p.alloc);
    }

    /// `cond (?? cond)*` — the chain separator sits looser than every
    /// boolean operator, so `a ?? b == c` is `a ?? (b == c)`.
    fn parseChainExpr(s: *Scanner, spaced_names: bool) Error!Chain {
        var terms = std.ArrayList(Cond).empty;
        errdefer terms.deinit(s.p.alloc);
        while (true) {
            const cond = try s.parseOr(0, 0, spaced_names);
            try terms.append(s.p.alloc, cond);
            s.skipWs();
            if (s.matchOp("??")) {
                if (s.eof()) return s.err("expected a value", .{});
                continue;
            }
            break;
        }
        if (!s.eof()) return s.err("unexpected text after condition", .{});
        return .{ .terms = try terms.toOwnedSlice(s.p.alloc) };
    }

    fn parseOr(s: *Scanner, paren_depth: usize, cond_depth: usize, spaced_names: bool) Error!Cond {
        var lhs = try s.parseAnd(paren_depth, cond_depth, spaced_names);
        var depth = cond_depth;
        while (true) {
            const save = s.pos;
            s.skipWs();
            if (s.matchOp("||") or s.matchWord("or")) {
                if (depth >= max_cond_depth) return s.err("expression nesting too deep", .{});
                depth += 1;
                const rhs = try s.parseAnd(paren_depth, depth, spaced_names);
                // Copy through temporaries: `lhs` must not be read while
                // its own replacement is being constructed (result-location
                // aliasing corrupts the pointers otherwise).
                const lhs_ptr = try s.p.makeCond(lhs);
                const rhs_ptr = try s.p.makeCond(rhs);
                lhs = .{ .or_ = .{ .lhs = lhs_ptr, .rhs = rhs_ptr } };
            } else {
                s.pos = save;
                break;
            }
        }
        return lhs;
    }

    fn parseAnd(s: *Scanner, paren_depth: usize, cond_depth: usize, spaced_names: bool) Error!Cond {
        var lhs = try s.parseNot(paren_depth, cond_depth, spaced_names);
        var depth = cond_depth;
        while (true) {
            const save = s.pos;
            s.skipWs();
            if (s.matchOp("&&") or s.matchWord("and")) {
                if (depth >= max_cond_depth) return s.err("expression nesting too deep", .{});
                depth += 1;
                const rhs = try s.parseNot(paren_depth, depth, spaced_names);
                // Copy through temporaries (see parseOr).
                const lhs_ptr = try s.p.makeCond(lhs);
                const rhs_ptr = try s.p.makeCond(rhs);
                lhs = .{ .and_ = .{ .lhs = lhs_ptr, .rhs = rhs_ptr } };
            } else {
                s.pos = save;
                break;
            }
        }
        return lhs;
    }

    fn parseNot(s: *Scanner, paren_depth: usize, cond_depth: usize, spaced_names: bool) Error!Cond {
        s.skipWs();
        if (s.matchWord("not") or s.matchBang()) {
            if (cond_depth >= max_cond_depth) return s.err("expression nesting too deep", .{});
            const inner = try s.parseNot(paren_depth, cond_depth + 1, spaced_names);
            return .{ .neg = try s.p.makeCond(inner) };
        }
        if (s.peek() == '(') {
            // Parenthesized groups cost two depth levels in the oracle.
            if (paren_depth >= 50 or cond_depth + 2 > max_cond_depth) return s.err("expression nesting too deep", .{});
            s.pos += 1;
            const inner = try s.parseOr(paren_depth + 1, cond_depth + 2, spaced_names);
            s.skipWs();
            if (s.peek() != ')') return s.err("expected ')'", .{});
            s.pos += 1;
            return inner;
        }
        return s.parseComparison(spaced_names);
    }

    /// `lhs [op rhs]` — operands are single pipelines (the `??` chain
    /// lives one level up, joining whole conditions). The left operand
    /// rejects filters, matching the oracle's LHS restriction.
    fn parseComparison(s: *Scanner, spaced_names: bool) Error!Cond {
        s.skipWs();
        const lhs = try s.parseOperandExpr(spaced_names);
        const save = s.pos;
        s.skipWs();
        var op: ?CmpOp = null;
        if (s.matchOp("==")) {
            op = .eq;
        } else if (s.matchOp("!=")) {
            op = .ne;
        } else if (s.matchOp("<=")) {
            op = .le;
        } else if (s.matchOp(">=")) {
            op = .ge;
        } else if (s.matchOp("<")) {
            op = .lt;
        } else if (s.matchOp(">")) {
            op = .gt;
        } else if (s.matchWord("contains")) {
            op = .contains;
        }
        if (op) |o| {
            if (lhs.terms[0].filters.len != 0) {
                return s.err("filters are not allowed on the left side of a comparison", .{});
            }
            s.skipWs();
            const rhs = try s.parseOperandExpr(spaced_names);
            return .{ .cmp = .{ .op = o, .lhs = lhs, .rhs = rhs } };
        }
        s.pos = save;
        return .{ .operand = lhs };
    }

    /// One pipeline as a single-term Expr — `??` is the chain-level
    /// combinator, so operands never hold multi-term chains.
    fn parseOperandExpr(s: *Scanner, spaced_names: bool) Error!Expr {
        const pipe = try s.parsePipelineInner(spaced_names, s.abs());
        const terms = try s.p.alloc.alloc(Pipeline, 1);
        terms[0] = pipe;
        return .{ .terms = terms };
    }
};

/// A bare param token is a path when it is a dotted/bracketed name —
/// `a`, `a.b`, `a[0]` — and a pattern literal otherwise (`2n`,
/// `2,3:4`, `[0-9]`, `numbered-task`).
fn looksLikePath(tok: []const u8) bool {
    if (tok.len == 0 or !isNameStart(tok[0])) return false;
    for (tok) |c| {
        if (!isNameChar(c) and c != '.' and c != '[' and c != ']') return false;
    }
    return true;
}

fn nextOpener(s: []const u8) ?usize {
    var best: ?usize = null;
    for ([_][]const u8{ "{{", "{%", "{#" }) |op| {
        if (std.mem.indexOf(u8, s, op)) |idx| {
            if (best == null or idx < best.?) best = idx;
        }
    }
    return best;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '.', '[', ']', '|', ':', '(', ')', '!', '=', '<', '>', '&', '\'', '"', '{', '}', '%', ',', '#', '\\', '?', '$', '/', '-' => false,
        else => true,
    };
}

/// Characters that end an unquoted filter-argument token.
fn isBareChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '|', '"', '\'', '}', '{', '%', '(', ')', '?', '$' => false,
        else => true,
    };
}

fn endTagWord(e: EndTag) []const u8 {
    return switch (e) {
        .eof => "end of input",
        .elseif => "elseif",
        .else_ => "else",
        .endif => "endif",
        .endfor => "endfor",
    };
}
