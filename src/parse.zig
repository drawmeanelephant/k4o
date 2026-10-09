//! Template parser: Knap-subset template text -> AST.
//!
//! The subset is documented in README.md ("Template subset") and was
//! derived clean-room from Knap's user-facing documentation only (see the
//! clean-room record in README.md).

const std = @import("std");
const diag = @import("diag.zig");

pub const Error = error{ Template, OutOfMemory };

pub const Literal = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,
};

pub const Step = union(enum) {
    key: []const u8,
    index: u64,
};

pub const Path = struct {
    root: []const u8,
    steps: []const Step,
};

pub const Expr = union(enum) {
    literal: Literal,
    path: Path,
};

pub const CmpOp = enum { eq, ne, lt, le, gt, ge, contains };

pub const Cond = union(enum) {
    operand: Expr,
    neg: *Cond,
    and_: struct { lhs: *Cond, rhs: *Cond },
    or_: struct { lhs: *Cond, rhs: *Cond },
    cmp: struct { op: CmpOp, lhs: Expr, rhs: Expr },
};

pub const Arg = union(enum) {
    bare: []const u8,
    string: []const u8,
    number: f64,
};

pub const FilterCall = struct {
    name: []const u8,
    arg: ?Arg,
    /// Absolute byte offset of the filter name in the template.
    offset: usize,
};

pub const Pipeline = struct {
    value: Expr,
    filters: []FilterCall,
    /// Absolute byte offset of the opening `{{`.
    offset: usize,
};

pub const Node = union(enum) {
    text: []const u8,
    output: Pipeline,
    ifelse: IfChain,
    loop: LoopNode,
};

pub const Branch = struct {
    cond: ?Cond,
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
};

pub const Document = struct {
    nodes: []Node,
};

const max_depth = 64;
const max_paren_depth = 32;
/// Cap on condition expression depth: one `Cond` node per negation and
/// per and/or chain link, so tree depth grows with chain length. Without
/// the cap a long `!` chain overflows the parser's own stack and a long
/// `and`/`or` chain overflows the engine's recursive `evalCond`.
const max_cond_depth = 256;

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

    fn parseSeq(p: *Parser, mode: Mode, depth: usize) Error!SeqResult {
        p.modes[p.mode_depth] = mode;
        p.mode_depth += 1;
        defer p.mode_depth -= 1;

        var nodes = std.ArrayList(Node).empty;
        errdefer nodes.deinit(p.alloc);

        while (p.i < p.src.len) {
            const rest = p.src[p.i..];
            if (std.mem.startsWith(u8, rest, "{{")) {
                const tag_start = p.i;
                const content = try p.tagContent(tag_start, "{{", "}}");
                const pipe = try p.parsePipeline(content, tag_start);
                try nodes.append(p.alloc, .{ .output = pipe });
            } else if (std.mem.startsWith(u8, rest, "{%")) {
                const tag_start = p.i;
                const content = try p.tagContent(tag_start, "{%", "%}");
                const tag = try p.parseLogicTag(content, tag_start, tag_start + 2, mode, depth);
                switch (tag) {
                    .terminated => |t| {
                        if (mode != .top) stripLeadingNewline(nodes.items);
                        return .{
                            .nodes = try nodes.toOwnedSlice(p.alloc),
                            .end = t.end,
                            .end_offset = tag_start,
                            .end_content = t.content,
                            .end_content_offset = t.content_offset,
                        };
                    },
                    .if_node => |ifc| try nodes.append(p.alloc, .{ .ifelse = ifc }),
                    .loop_node => |ln| try nodes.append(p.alloc, .{ .loop = ln }),
                }
            } else if (std.mem.startsWith(u8, rest, "{#")) {
                const close = std.mem.indexOf(u8, rest, "#}") orelse
                    return p.errAt(.syntax, p.i, "unclosed comment (missing '#}}')", .{});
                p.i += close + 2;
            } else {
                const stop = nextOpener(rest) orelse rest.len;
                if (stop > 0) {
                    try nodes.append(p.alloc, .{ .text = rest[0..stop] });
                    p.i += stop;
                } else {
                    // rest[0] is '{' but not an opener: emit a single byte.
                    try nodes.append(p.alloc, .{ .text = rest[0..1] });
                    p.i += 1;
                }
            }
        }

        if (mode != .top) stripLeadingNewline(nodes.items);
        return .{
            .nodes = try nodes.toOwnedSlice(p.alloc),
            .end = .eof,
            .end_offset = p.src.len,
            .end_content = "",
            .end_content_offset = p.src.len,
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

    const LogicTag = union(enum) {
        terminated: struct { end: EndTag, content: []const u8, content_offset: usize },
        if_node: IfChain,
        loop_node: LoopNode,
    };

    fn parseLogicTag(
        p: *Parser,
        content: []const u8,
        tag_start: usize,
        content_offset: usize,
        mode: Mode,
        depth: usize,
    ) Error!LogicTag {
        var q = Scanner{ .p = p, .text = content, .base = content_offset };
        q.skipWs();
        const keyword = q.word() orelse return q.err("empty logic tag", .{});

        if (std.mem.eql(u8, keyword, "if")) {
            if (depth >= max_depth) return q.err("nesting too deep (max {d} levels)", .{max_depth});
            const cond = try q.parseCondExpr();
            const ifc = try p.parseIfChain(cond, tag_start, depth + 1);
            return .{ .if_node = ifc };
        }
        if (std.mem.eql(u8, keyword, "for")) {
            if (depth >= max_depth) return q.err("nesting too deep (max {d} levels)", .{max_depth});
            const var_name = q.word() orelse return q.err("expected a loop variable name after 'for'", .{});
            q.skipWs();
            if (!q.matchWord("in")) return q.err("expected 'in' in for tag", .{});
            const list_expr = try q.parseExpr(false);
            q.skipWs();
            if (!q.eof()) return q.err("unexpected text after the for expression", .{});
            const seq = try p.parseSeq(.loop_body, depth + 1);
            switch (seq.end) {
                .endfor => {
                    var qe = Scanner{ .p = p, .text = seq.end_content, .base = seq.end_content_offset };
                    _ = qe.word();
                    qe.skipWs();
                    if (!qe.eof()) return qe.err("unexpected text in '{{% endfor %}}'", .{});
                    return .{ .loop_node = .{
                        .var_name = var_name,
                        .list = list_expr,
                        .body = seq.nodes,
                        .offset = tag_start,
                    } };
                },
                .eof => return p.errAt(.syntax, tag_start, "unclosed for block (missing '{{% endfor %}}')", .{}),
                else => return p.errAt(.syntax, seq.end_offset, "unexpected '{s}' tag inside a for block", .{endTagWord(seq.end)}),
            }
        }
        if (std.mem.eql(u8, keyword, "elseif")) {
            if (mode != .branch) {
                if (p.isOpen(.branch)) return q.err("unexpected '{{% elseif %}}' inside a for block", .{});
                return q.err("unexpected '{{% elseif %}}' outside an if block", .{});
            }
            return .{ .terminated = .{ .end = .elseif, .content = content, .content_offset = content_offset } };
        }
        if (std.mem.eql(u8, keyword, "else")) {
            if (mode != .branch) {
                if (p.isOpen(.branch)) return q.err("unexpected '{{% else %}}' inside a for block", .{});
                return q.err("unexpected '{{% else %}}' outside an if block", .{});
            }
            return .{ .terminated = .{ .end = .else_, .content = content, .content_offset = content_offset } };
        }
        if (std.mem.eql(u8, keyword, "endif")) {
            if (mode != .branch) {
                if (p.isOpen(.branch)) return q.err("unexpected '{{% endif %}}' inside a for block", .{});
                return q.err("unexpected '{{% endif %}}' outside an if block", .{});
            }
            return .{ .terminated = .{ .end = .endif, .content = content, .content_offset = content_offset } };
        }
        if (std.mem.eql(u8, keyword, "endfor")) {
            if (mode != .loop_body) {
                if (p.isOpen(.loop_body)) return q.err("unexpected '{{% endfor %}}' inside an if block", .{});
                return q.err("unexpected '{{% endfor %}}' outside a for block", .{});
            }
            return .{ .terminated = .{ .end = .endfor, .content = content, .content_offset = content_offset } };
        }
        return q.err("unknown logic tag '{s}'", .{keyword});
    }

    fn parseIfChain(
        p: *Parser,
        first_cond: Cond,
        open_offset: usize,
        depth: usize,
    ) Error!IfChain {
        var branches = std.ArrayList(Branch).empty;
        errdefer branches.deinit(p.alloc);

        var current_cond: ?Cond = first_cond;
        var current_open = open_offset;
        var saw_else = false;

        var seq = try p.parseSeq(.branch, depth);
        while (true) {
            switch (seq.end) {
                .elseif => {
                    if (saw_else) return p.errAt(.syntax, seq.end_offset, "unexpected '{{% elseif %}}' after '{{% else %}}'", .{});
                    try branches.append(p.alloc, .{ .cond = current_cond, .body = seq.nodes, .offset = current_open });
                    var q = Scanner{ .p = p, .text = seq.end_content, .base = seq.end_content_offset };
                    _ = q.word();
                    const cond = try q.parseCondExpr();
                    current_cond = cond;
                    current_open = seq.end_offset;
                    seq = try p.parseSeq(.branch, depth);
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
                    seq = try p.parseSeq(.branch, depth);
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

    fn parsePipeline(p: *Parser, content: []const u8, tag_start: usize) Error!Pipeline {
        var q = Scanner{ .p = p, .text = content, .base = tag_start + 2 };
        const value = try q.parseExpr(true);
        var filter_list = std.ArrayList(FilterCall).empty;
        errdefer filter_list.deinit(p.alloc);
        while (true) {
            q.skipWs();
            if (q.eof()) break;
            if (q.peek() == '|') {
                q.pos += 1;
                q.skipWs();
                const fstart = q.pos;
                const name = q.word() orelse return q.err("expected a filter name after '|'", .{});
                var arg: ?Arg = null;
                q.skipWs();
                if (!q.eof() and q.peek() == ':') {
                    q.pos += 1;
                    q.skipWs();
                    arg = try q.parseArg();
                }
                try filter_list.append(p.alloc, .{
                    .name = name,
                    .arg = arg,
                    .offset = tag_start + 2 + fstart,
                });
            } else {
                return q.err("unexpected text in output tag (expected '|' or end of tag)", .{});
            }
        }
        return .{
            .value = value,
            .filters = try filter_list.toOwnedSlice(p.alloc),
            .offset = tag_start,
        };
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

    fn parseStringLit(s: *Scanner) Error![]const u8 {
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
        if (!needs_copy) return raw;
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(s.p.alloc);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                try buf.append(s.p.alloc, raw[i + 1]);
                i += 2;
            } else {
                try buf.append(s.p.alloc, raw[i]);
                i += 1;
            }
        }
        return buf.toOwnedSlice(s.p.alloc);
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
        const n = std.fmt.parseInt(i64, slice, 10) catch return s.err("invalid number literal", .{});
        return .{ .integer = n };
    }

    fn parseExpr(s: *Scanner, spaced_names: bool) Error!Expr {
        s.skipWs();
        const c = s.peek() orelse return s.err("expected a value", .{});
        if (c == '"' or c == '\'') {
            const str = try s.parseStringLit();
            return .{ .literal = .{ .string = str } };
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

    fn parseArg(s: *Scanner) Error!Arg {
        s.skipWs();
        const c = s.peek() orelse return s.err("expected a filter argument after ':'", .{});
        if (c == '"' or c == '\'') {
            return .{ .string = try s.parseStringLit() };
        }
        if (std.ascii.isDigit(c) or
            (c == '-' and s.pos + 1 < s.text.len and std.ascii.isDigit(s.text[s.pos + 1])))
        {
            const lit = try s.parseNumberLit();
            return switch (lit) {
                .integer => |n| .{ .number = @floatFromInt(n) },
                .float => |f| .{ .number = f },
                else => s.err("invalid number argument", .{}),
            };
        }
        const start = s.pos;
        while (s.pos < s.text.len and isNameChar(s.text[s.pos])) s.pos += 1;
        if (s.pos == start) return s.err("expected a filter argument after ':'", .{});
        return .{ .bare = s.text[start..s.pos] };
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
                    try steps.append(s.p.alloc, .{ .key = key });
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
                    return s.err("bracket access supports a number or a quoted key", .{});
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

    fn parseCondExpr(s: *Scanner) Error!Cond {
        const cond = try s.parseOr(0, 0);
        s.skipWs();
        if (!s.eof()) return s.err("unexpected text after condition", .{});
        return cond;
    }

    fn parseOr(s: *Scanner, paren_depth: usize, cond_depth: usize) Error!Cond {
        var lhs = try s.parseAnd(paren_depth, cond_depth);
        var depth = cond_depth;
        while (true) {
            const save = s.pos;
            s.skipWs();
            if (s.matchOp("||") or s.matchWord("or")) {
                if (depth >= max_cond_depth) return s.err("expression nesting too deep", .{});
                depth += 1;
                const rhs = try s.parseAnd(paren_depth, depth);
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

    fn parseAnd(s: *Scanner, paren_depth: usize, cond_depth: usize) Error!Cond {
        var lhs = try s.parseNot(paren_depth, cond_depth);
        var depth = cond_depth;
        while (true) {
            const save = s.pos;
            s.skipWs();
            if (s.matchOp("&&") or s.matchWord("and")) {
                if (depth >= max_cond_depth) return s.err("expression nesting too deep", .{});
                depth += 1;
                const rhs = try s.parseNot(paren_depth, depth);
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

    fn parseNot(s: *Scanner, paren_depth: usize, cond_depth: usize) Error!Cond {
        s.skipWs();
        if (s.matchWord("not") or s.matchBang()) {
            if (cond_depth >= max_cond_depth) return s.err("expression nesting too deep", .{});
            const inner = try s.parseNot(paren_depth, cond_depth + 1);
            return .{ .neg = try s.p.makeCond(inner) };
        }
        if (s.peek() == '(') {
            if (paren_depth >= max_paren_depth) return s.err("expression nesting too deep", .{});
            s.pos += 1;
            const inner = try s.parseOr(paren_depth + 1, cond_depth);
            s.skipWs();
            if (s.peek() != ')') return s.err("expected ')'", .{});
            s.pos += 1;
            return inner;
        }
        return s.parseComparison();
    }

    fn parseComparison(s: *Scanner) Error!Cond {
        s.skipWs();
        const lhs = try s.parseExpr(false);
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
            s.skipWs();
            const rhs = try s.parseExpr(false);
            return .{ .cmp = .{ .op = o, .lhs = lhs, .rhs = rhs } };
        }
        s.pos = save;
        return .{ .operand = lhs };
    }
};

fn stripLeadingNewline(nodes: []Node) void {
    if (nodes.len == 0) return;
    switch (nodes[0]) {
        .text => |t| {
            if (std.mem.startsWith(u8, t, "\r\n")) {
                nodes[0] = .{ .text = t[2..] };
            } else if (std.mem.startsWith(u8, t, "\n")) {
                nodes[0] = .{ .text = t[1..] };
            }
        },
        else => {},
    }
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

fn isNameChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '.', '[', ']', '|', ':', '(', ')', '!', '=', '<', '>', '&', '\'', '"', '{', '}', '%', ',', '#', '\\' => false,
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
