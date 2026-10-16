//! re — a bounded backtracking regular-expression engine, built for k4o's
//! `replace` filter and designed to be lifted into a standalone package.
//! Stdlib only; callers pass an allocator (an arena is ideal) and no global
//! state exists.
//!
//! Behaviour targets JS RegExp observables, since the knap oracle delegates
//! to `new RegExp`: matching runs over UTF-16 code units (so a non-`u`
//! pattern may split a surrogate pair — halves re-encode as U+FFFD), `i`
//! folds with ECMA-262 Canonicalize, `m`/`s` adjust `^`/`$`/`.`, `g`
//! iterates with the empty-match +1 advance, and `y` anchors at lastIndex.
//!
//! Supported syntax: literals, `.`, character classes `[...]` (ranges,
//! negation, `\d\w\s` escapes, `[\b]` backspace), anchors `^` `$` `\b` `\B`,
//! quantifiers `*` `+` `?` `{n}` `{n,}` `{n,m}` plus lazy `?`, groups `()`
//! `(?:)` `(?<name>)`, alternation `|`, look-ahead `(?=)` `(?!)`,
//! look-behind `(?<=)` `(?<!)`, backreferences `\1`..`\99` and `\k<name>`,
//! escapes `\n \r \t \f \v \0 \cX \xHH \uHHHH \u{H+}` (u-mode) and JS Annex-B
//! leniency (identity escapes, octal fallbacks, literal `{`/`}`/`]`).
//!
//! Rejected with error.InvalidPattern: anything `new RegExp` throws on —
//! unbalanced parens/classes, `a{2,1}`, `a**`, quantified anchors, u-mode
//! strictness violations, `\p{...}`. At match time the step budget (4M) or
//! the depth cap (8192) report error.StepLimit instead of hanging on
//! catastrophic backtracking.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, InvalidPattern, StepLimit };

pub const Flags = struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dotall: bool = false,
    unicode: bool = false,
    sticky: bool = false,
};

pub const Span = struct { start: usize, end: usize };

pub const Match = struct {
    start: usize,
    end: usize,
    /// groups[i] is the span captured by group i+1, or null when it did not
    /// participate in the match.
    groups: []const ?Span,
};

pub const NamedGroup = struct { name: []const u8, index: u16 };

const Op = enum {
    char, // a: u16 code unit (already canonicalized under the i flag)
    any, // `.` — honors dotall; u-mode consumes a full surrogate pair
    class, // a: index into Regex.classes
    bol,
    eol,
    wordb,
    nwordb,
    backref, // a: capture group index (1-based)
    save, // a: capture slot index (2*g = start, 2*g+1 = end)
    jmp, // a: target
    split, // a: first choice, b: fallback
    mark, // a: mark slot — records pos at loop iteration start
    loopback, // a: mark slot, b: target — loops only when pos advanced
    look, // a: sub-program index; b bit0 = negated, bit1 = look-behind
    match, // terminal success (honors expect_end inside look-behind scans)
};

const Inst = struct { op: Op, a: u32 = 0, b: u32 = 0 };

const Range = struct { lo: u32, hi: u32 };

const Class = struct {
    negated: bool,
    /// Sorted disjoint ranges. Under `i` the set also contains the
    /// canonicalized image of the written ranges; matching compares
    /// canon(input) against it.
    ranges: []const Range,
};

pub const Regex = struct {
    prog: []const Inst,
    classes: []const Class,
    subs: []const []const Inst,
    group_count: usize,
    mark_count: usize,
    names: []const NamedGroup,
    flags: Flags,

    pub fn groupIndex(re: *const Regex, name: []const u8) ?u16 {
        for (re.names) |n| {
            if (std.mem.eql(u8, n.name, name)) return n.index;
        }
        return null;
    }
};

pub const max_steps: usize = 4_000_000;
pub const max_depth: usize = 8192;
const max_insts: usize = 32768;
const max_look_depth: usize = 16;
const max_group_nesting: usize = 256;
const unset: usize = std.math.maxInt(usize);
const inf_bound: u32 = std.math.maxInt(u32);

// --------------------------------------------------------------------
// UTF-16 bridging

/// Decode UTF-8 to UTF-16 code units; malformed input decodes byte-wise as
/// U+FFFD so a mangled pattern is still finite work.
pub fn utf8ToUtf16(alloc: Allocator, s: []const u8) error{OutOfMemory}![]u16 {
    var out = std.ArrayList(u16).empty;
    var i: usize = 0;
    while (i < s.len) {
        const cp: u21 = blk: {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                i += 1;
                break :blk 0xFFFD;
            };
            if (i + n > s.len) {
                i = s.len;
                break :blk 0xFFFD;
            }
            const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
                i += 1;
                break :blk 0xFFFD;
            };
            i += n;
            break :blk cp;
        };
        if (cp < 0x10000) {
            try out.append(alloc, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try out.append(alloc, @intCast(0xD800 + (v >> 10)));
            try out.append(alloc, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Encode UTF-16 units to UTF-8. A lone surrogate emits U+FFFD, matching
/// Node's output when a replacement splits a pair.
pub fn utf16ToUtf8Lossy(alloc: Allocator, units: []const u16) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < units.len) {
        const u = units[i];
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len and
            units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF)
        {
            const cp: u21 = 0x10000 + ((@as(u21, u - 0xD800) << 10) | (units[i + 1] - 0xDC00));
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(alloc, buf[0..n]);
            i += 2;
            continue;
        }
        const cp: u21 = if (u >= 0xD800 and u <= 0xDFFF) 0xFFFD else u;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(alloc, buf[0..n]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------------
// Case folding — ECMA-262 Canonicalize for non-u regexes is the single
// code-unit uppercase mapping, except that chars >= 0x80 never fold into
// ASCII (which is why ſ, ı, K, İ and ẞ stay put). The table covers ASCII,
// Latin-1, Latin Extended-A pairs, Greek (incl. ypogegrammeni and final
// sigma), Cyrillic, Armenian and the common Latin Extended-B singletons;
// rarer folds may differ from the oracle.

fn canon(c: u16) u16 {
    if (c < 0x80) return if (c >= 'a' and c <= 'z') c - 0x20 else c;
    switch (c) {
        0xE0...0xF6, 0xF8...0xFE => return c - 0x20,
        0xFF => return 0x178,
        else => {},
    }
    // Latin Extended-A pairs (parity alternates across sub-ranges).
    if (c >= 0x101 and c <= 0x12F) return if (c % 2 == 1) c - 1 else c;
    if (c >= 0x133 and c <= 0x137) return if (c % 2 == 1) c - 1 else c;
    if (c >= 0x13A and c <= 0x148) return if (c % 2 == 0) c - 1 else c;
    if (c >= 0x14B and c <= 0x177) return if (c % 2 == 1) c - 1 else c;
    if (c >= 0x17A and c <= 0x17E) return if (c % 2 == 0) c - 1 else c;
    // Greek.
    if (c >= 0x3B1 and c <= 0x3C1) return c - 0x20;
    if (c >= 0x3C3 and c <= 0x3CB) return c - 0x20;
    if (c >= 0x3CC and c <= 0x3CE) return c - 0x40;
    if (c >= 0x3D8 and c <= 0x3EF) return if (c % 2 == 1) c - 1 else c;
    // Cyrillic.
    if (c >= 0x430 and c <= 0x44F) return c - 0x20;
    if (c >= 0x450 and c <= 0x45F) return c - 0x50;
    if (c >= 0x460 and c <= 0x481) return if (c % 2 == 1) c - 1 else c;
    if (c >= 0x48B and c <= 0x4BF) return if (c % 2 == 1) c - 1 else c;
    if (c >= 0x4C2 and c <= 0x4CE) return if (c % 2 == 0) c - 1 else c;
    if (c >= 0x4D0 and c <= 0x4FF) return if (c % 2 == 1) c - 1 else c;
    // Armenian.
    if (c >= 0x561 and c <= 0x586) return c - 0x30;
    // Greek extended.
    if (c >= 0x1F00 and c <= 0x1F07) return c + 8;
    if (c >= 0x1F10 and c <= 0x1F15) return c + 8;
    if (c >= 0x1F20 and c <= 0x1F27) return c + 8;
    if (c >= 0x1F30 and c <= 0x1F37) return c + 8;
    if (c >= 0x1F40 and c <= 0x1F45) return c + 8;
    if (c >= 0x1F60 and c <= 0x1F67) return c + 8;
    if (c >= 0x1F70 and c <= 0x1F7B) return c + 0x4A;
    if (c >= 0x1F80 and c <= 0x1FAF) return c + 8;
    if (c >= 0x1FB0 and c <= 0x1FB1) return c + 8;
    if (c >= 0x1FD0 and c <= 0x1FD1) return c + 8;
    if (c >= 0x1FE0 and c <= 0x1FE1) return c + 8;
    return switch (c) {
        0x3C2 => 0x3A3, // final sigma
        0x345 => 0x399, // combining ypogegrammeni
        0x1FBE => 0x399,
        0x1F51 => 0x1F59,
        0x1F53 => 0x1F5B,
        0x1F55 => 0x1F5D,
        0x1F57 => 0x1F5F,
        0x3D0 => 0x392,
        0x3D1 => 0x398,
        0x3D5 => 0x3A6,
        0x3D6 => 0x3A0,
        0xB5 => 0x39C, // micro sign
        0x180 => 0x243,
        0x183 => 0x182,
        0x185 => 0x184,
        0x188 => 0x187,
        0x18C => 0x18B,
        0x192 => 0x191,
        0x195 => 0x1F6,
        0x199 => 0x198,
        0x19A => 0x23D,
        0x19E => 0x220,
        0x1A1 => 0x1A0,
        0x1A3 => 0x1A2,
        0x1A5 => 0x1A4,
        0x1A8 => 0x1A7,
        0x1AD => 0x1AC,
        0x1B0 => 0x1AF,
        0x1B4 => 0x1B3,
        0x1B6 => 0x1B5,
        0x1B9 => 0x1B8,
        0x1BD => 0x1BC,
        0x1BF => 0x1F7,
        0x1C5, 0x1C6 => 0x1C4,
        0x1C8, 0x1C9 => 0x1C7,
        0x1CB, 0x1CC => 0x1CA,
        0x1F2, 0x1F3 => 0x1F1,
        0x1DD => 0x18E,
        0x252 => 0x2C6F,
        0x253 => 0x181,
        0x254 => 0x186,
        0x257 => 0x18A,
        0x259 => 0x18F,
        0x25B => 0x190,
        0x260 => 0x193,
        0x263 => 0x194,
        0x268 => 0x197,
        0x269 => 0x198,
        0x26B => 0x2C62,
        0x26F => 0x19C,
        0x271 => 0x2C6E,
        0x272 => 0x19D,
        0x275 => 0x19F,
        0x27D => 0x2C64,
        0x280 => 0x1A6,
        0x283 => 0x1A9,
        0x288 => 0x1AE,
        0x28A => 0x1B1,
        0x28B => 0x1B2,
        0x292 => 0x1B7,
        else => c,
    };
}

// --------------------------------------------------------------------
// Built-in class sets (JS definitions)

const set_digit = [_]Range{.{ .lo = '0', .hi = '9' }};
const set_word = [_]Range{
    .{ .lo = '0', .hi = '9' },
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = '_', .hi = '_' },
    .{ .lo = 'a', .hi = 'z' },
};
const set_space = [_]Range{
    .{ .lo = 0x09, .hi = 0x0D },
    .{ .lo = 0x20, .hi = 0x20 },
    .{ .lo = 0xA0, .hi = 0xA0 },
    .{ .lo = 0x1680, .hi = 0x1680 },
    .{ .lo = 0x2000, .hi = 0x200A },
    .{ .lo = 0x2028, .hi = 0x2029 },
    .{ .lo = 0x202F, .hi = 0x202F },
    .{ .lo = 0x205F, .hi = 0x205F },
    .{ .lo = 0x3000, .hi = 0x3000 },
    .{ .lo = 0xFEFF, .hi = 0xFEFF },
};

fn isLineTerm(u: u16) bool {
    return u == '\n' or u == '\r' or u == 0x2028 or u == 0x2029;
}

fn isWordChar(u: u16) bool {
    return (u >= '0' and u <= '9') or (u >= 'A' and u <= 'Z') or
        (u >= 'a' and u <= 'z') or u == '_';
}

fn isDigit16(u: u16) bool {
    return u >= '0' and u <= '9';
}

fn isAlpha16(u: u16) bool {
    return (u >= 'a' and u <= 'z') or (u >= 'A' and u <= 'Z');
}

// --------------------------------------------------------------------
// AST

const Rep = struct { min: u32, max: u32, lazy: bool, child: *const Node };

const Node = union(enum) {
    empty,
    char: u16,
    any,
    class: u32, // index into Parser.classes
    bol,
    eol,
    wordb,
    nwordb,
    digits: []const u16, // `\dd+` — resolved to backref/octal at emit time
    named_ref: []const u8, // `\k<name>` — resolved at emit time
    group: struct { index: u16, body: []const Node }, // index 0 = non-capturing
    look: struct { neg: bool, behind: bool, body: []const Node },
    alt: []const []const Node,
    rep: Rep,
};

/// What a `\…` escape produced.
const Esc = union(enum) {
    char: u32, // a codepoint
    set: []const Range,
    negset: []const Range,
    wordb,
    nwordb,
    digits: []const u16, // needs the final group count to resolve
    named_ref: []const u8,
};

const Parser = struct {
    src: []const u16,
    pos: usize = 0,
    alloc: Allocator,
    flags: Flags,
    detail: *[]const u8,
    group_count: u16 = 0,
    classes: std.ArrayList(Class) = .empty,
    names: std.ArrayList(NamedGroup) = .empty,
    look_depth: u32 = 0,
    group_depth: u32 = 0,

    fn fail(s: *Parser, msg: []const u8) Error {
        s.detail.* = msg;
        return error.InvalidPattern;
    }

    fn peek(s: *Parser) ?u16 {
        if (s.pos >= s.src.len) return null;
        return s.src[s.pos];
    }

    fn take(s: *Parser) ?u16 {
        const c = s.peek() orelse return null;
        s.pos += 1;
        return c;
    }

    /// Whole-pattern entry: alternatives until EOF.
    fn parseAll(s: *Parser) Error![]const Node {
        const alts = try s.parseAlts(false);
        if (s.pos != s.src.len) return s.fail("unbalanced parenthesis");
        if (alts.len == 1) return alts[0];
        const node = try s.alloc.create(Node);
        node.* = .{ .alt = alts };
        const seq = try s.alloc.alloc(Node, 1);
        seq[0] = node.*;
        return seq;
    }

    /// `alt1|alt2|…` — each alternative is a node list. Consumes `|`s and
    /// stops before `)` (inside a group) or EOF.
    fn parseAlts(s: *Parser, in_group: bool) Error![]const []const Node {
        var alts = std.ArrayList([]const Node).empty;
        while (true) {
            const seq = try s.parseSeq(in_group);
            try alts.append(s.alloc, seq);
            if (s.peek() == @as(u16, '|')) {
                s.pos += 1;
                continue;
            }
            break;
        }
        return alts.toOwnedSlice(s.alloc);
    }

    fn parseSeq(s: *Parser, in_group: bool) Error![]const Node {
        var items = std.ArrayList(Node).empty;
        while (s.peek()) |c| {
            if (c == '|' or (c == ')' and in_group)) break;
            try items.append(s.alloc, try s.parseItem());
        }
        return items.toOwnedSlice(s.alloc);
    }

    fn parseItem(s: *Parser) Error!Node {
        const atom = try s.parseAtom();
        var min: u32 = 1;
        var max: u32 = 1;
        var has_quant = false;
        if (s.peek()) |c| {
            switch (c) {
                '*' => {
                    s.pos += 1;
                    min = 0;
                    max = inf_bound;
                    has_quant = true;
                },
                '+' => {
                    s.pos += 1;
                    min = 1;
                    max = inf_bound;
                    has_quant = true;
                },
                '?' => {
                    s.pos += 1;
                    min = 0;
                    max = 1;
                    has_quant = true;
                },
                '{' => {
                    if (s.scanQuantifier()) |q| {
                        if (q.max != inf_bound and q.max < q.min)
                            return s.fail("quantifier numbers out of order");
                        s.pos = q.end;
                        min = q.min;
                        max = q.max;
                        has_quant = true;
                    } else if (s.flags.unicode) {
                        return s.fail("lone '{' in unicode mode");
                    }
                },
                else => {},
            }
        }
        if (!has_quant) return atom;
        switch (atom) {
            .bol, .eol, .wordb, .nwordb =>
            return s.fail("quantifier applied to a zero-width assertion"),
            .look => if (s.flags.unicode)
                return s.fail("quantifier applied to a look-around in unicode mode"),
            else => {},
        }
        var lazy = false;
        if (s.peek() == @as(u16, '?')) {
            s.pos += 1;
            lazy = true;
        }
        const child = try s.alloc.create(Node);
        child.* = atom;
        return .{ .rep = .{ .min = min, .max = max, .lazy = lazy, .child = child } };
    }

    const QuantScan = struct { min: u32, max: u32, end: usize };

    /// `{n}` `{n,}` `{n,m}` at pos — null when the text is not quantifier
    /// shaped (then `{` is literal, Annex-B style).
    fn scanQuantifier(s: *Parser) ?QuantScan {
        var i = s.pos + 1;
        var min: u32 = 0;
        var nd: usize = 0;
        while (i < s.src.len and isDigit16(s.src[i])) : (i += 1) {
            min = std.math.mul(u32, min, 10) catch return null;
            min = std.math.add(u32, min, s.src[i] - '0') catch return null;
            nd += 1;
        }
        if (nd == 0) return null;
        var max: u32 = min;
        if (i < s.src.len and s.src[i] == ',') {
            i += 1;
            max = inf_bound;
            var m2: u32 = 0;
            var md: usize = 0;
            while (i < s.src.len and isDigit16(s.src[i])) : (i += 1) {
                m2 = std.math.mul(u32, m2, 10) catch return null;
                m2 = std.math.add(u32, m2, s.src[i] - '0') catch return null;
                md += 1;
            }
            if (md > 0) max = m2;
        }
        if (i >= s.src.len or s.src[i] != '}') return null;
        return .{ .min = min, .max = max, .end = i + 1 };
    }

    fn parseAtom(s: *Parser) Error!Node {
        const c = s.take() orelse return s.fail("unexpected end of pattern");
        switch (c) {
            '^' => return .bol,
            '$' => return .eol,
            '.' => return .any,
            '(' => return s.parseGroup(),
            '[' => return s.parseClassNode(),
            '\\' => {
                const e = try s.parseEscape(false);
                return switch (e) {
                    .char => |ch| s.charNode(ch),
                    .set => |r| s.classNode(false, r),
                    .negset => |r| s.classNode(true, r),
                    .wordb => .wordb,
                    .nwordb => .nwordb,
                    .digits => |d| .{ .digits = d },
                    .named_ref => |n| .{ .named_ref = n },
                };
            },
            '*', '+', '?' => return s.fail("quantifier has nothing to repeat"),
            '{' => {
                if (s.scanQuantifier() != null)
                    return s.fail("quantifier has nothing to repeat");
                if (s.flags.unicode) return s.fail("lone '{' in unicode mode");
                return .{ .char = '{' };
            },
            ')' => return s.fail("unbalanced parenthesis"),
            ']', '}' => {
                if (s.flags.unicode) return s.fail("lone ']' or '}' in unicode mode");
                return .{ .char = c };
            },
            else => return .{ .char = c },
        }
    }

    fn charNode(s: *Parser, cp: u32) Error!Node {
        if (cp > 0xFFFF) {
            // An astral escape is a single-codepoint atom under u; the class
            // form lets the executor consume the whole surrogate pair.
            if (!s.flags.unicode) return s.fail("astral escape outside unicode mode");
            const r = try s.alloc.alloc(Range, 1);
            r[0] = .{ .lo = cp, .hi = cp };
            return s.classNode(false, r);
        }
        return .{ .char = @intCast(cp) };
    }

    fn classNode(s: *Parser, negated: bool, ranges_in: []const Range) Error!Node {
        var list = std.ArrayList(Range).empty;
        for (ranges_in) |r| try pushRange(&list, s.alloc, r.lo, r.hi);
        if (s.flags.ignore_case) try foldRanges(&list, s.alloc);
        const idx: u32 = @intCast(s.classes.items.len);
        try s.classes.append(s.alloc, .{
            .negated = negated,
            .ranges = try list.toOwnedSlice(s.alloc),
        });
        return .{ .class = idx };
    }

    fn parseGroup(s: *Parser) Error!Node {
        var gindex: u16 = 0; // 0 = non-capturing / look-around
        var look: ?struct { neg: bool, behind: bool } = null;
        if (s.peek() == @as(u16, '?')) {
            s.pos += 1;
            const c = s.peek() orelse return s.fail("unterminated group");
            switch (c) {
                ':' => s.pos += 1,
                '=' => {
                    s.pos += 1;
                    look = .{ .neg = false, .behind = false };
                },
                '!' => {
                    s.pos += 1;
                    look = .{ .neg = true, .behind = false };
                },
                '<' => {
                    s.pos += 1;
                    const c2 = s.peek() orelse return s.fail("unterminated group");
                    if (c2 == '=') {
                        s.pos += 1;
                        look = .{ .neg = false, .behind = true };
                    } else if (c2 == '!') {
                        s.pos += 1;
                        look = .{ .neg = true, .behind = true };
                    } else {
                        const start = s.pos;
                        while (s.pos < s.src.len and s.src[s.pos] != '>') : (s.pos += 1) {
                            const ch = s.src[s.pos];
                            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$'))
                                return s.fail("invalid capture-group name");
                        }
                        if (s.pos >= s.src.len or s.pos == start)
                            return s.fail("unterminated or empty capture-group name");
                        const name = try unitsToUtf8(s.alloc, s.src[start..s.pos]);
                        s.pos += 1;
                        s.group_count += 1;
                        gindex = s.group_count;
                        for (s.names.items) |n| {
                            if (std.mem.eql(u8, n.name, name))
                                return s.fail("duplicate capture-group name");
                        }
                        try s.names.append(s.alloc, .{ .name = name, .index = gindex });
                    }
                },
                else => return s.fail("unsupported group syntax"),
            }
        } else {
            s.group_count += 1;
            gindex = s.group_count;
        }
        if (look != null) {
            if (s.look_depth >= max_look_depth) return s.fail("look-around nested too deep");
            s.look_depth += 1;
        }
        s.group_depth += 1;
        if (s.group_depth > max_group_nesting) return s.fail("groups nested too deep");
        defer {
            s.group_depth -= 1;
            if (look != null) s.look_depth -= 1;
        }
        const alts = try s.parseAlts(true);
        if (s.peek() != @as(u16, ')')) return s.fail("unbalanced parenthesis");
        s.pos += 1;
        var body: []const Node = undefined;
        if (alts.len == 1) {
            body = alts[0];
        } else {
            const node = try s.alloc.create(Node);
            node.* = .{ .alt = alts };
            const seq = try s.alloc.alloc(Node, 1);
            seq[0] = node.*;
            body = seq;
        }
        const node = try s.alloc.create(Node);
        if (look) |l| {
            node.* = .{ .look = .{ .neg = l.neg, .behind = l.behind, .body = body } };
        } else {
            node.* = .{ .group = .{ .index = gindex, .body = body } };
        }
        return node.*;
    }

    fn parseClassNode(s: *Parser) Error!Node {
        // cursor is just past '['
        var negated = false;
        if (s.peek() == @as(u16, '^')) {
            s.pos += 1;
            negated = true;
        }
        var list = std.ArrayList(Range).empty;
        defer list.deinit(s.alloc);
        while (true) {
            const c = s.peek() orelse return s.fail("unterminated character class");
            s.pos += 1;
            if (c == ']') {
                // `[]` never matches: ']' right after '[' closes an empty
                // class rather than becoming a member.
                break;
            }
            const lo = try s.parseClassTerm(c);
            if (lo == .char and s.peek() == @as(u16, '-')) {
                s.pos += 1;
                const nc = s.peek() orelse return s.fail("unterminated character class");
                if (nc == ']') {
                    // trailing '-' is literal
                    s.pos += 1;
                    try pushRange(&list, s.alloc, lo.char, lo.char);
                    try pushRange(&list, s.alloc, '-', '-');
                    break;
                }
                s.pos += 1;
                const hi = try s.parseClassTerm(nc);
                if (hi != .char) {
                    // `a-\d`: Annex-B treats the '-' as literal, then the set.
                    if (s.flags.unicode) return s.fail("bad class range");
                    try pushRange(&list, s.alloc, lo.char, lo.char);
                    try pushRange(&list, s.alloc, '-', '-');
                    for (try hi.spans(s.alloc)) |r| try pushRange(&list, s.alloc, r.lo, r.hi);
                    continue;
                }
                if (hi.char < lo.char) return s.fail("class range out of order");
                try pushRange(&list, s.alloc, lo.char, hi.char);
                continue;
            }
            for (try lo.spans(s.alloc)) |r| try pushRange(&list, s.alloc, r.lo, r.hi);
        }
        if (s.flags.ignore_case) try foldRanges(&list, s.alloc);
        const idx: u32 = @intCast(s.classes.items.len);
        try s.classes.append(s.alloc, .{
            .negated = negated,
            .ranges = try list.toOwnedSlice(s.alloc),
        });
        return .{ .class = idx };
    }

    /// One member of a class; `c` was already consumed.
    fn parseClassTerm(s: *Parser, c: u16) Error!ClassTerm {
        if (c != '\\') return .{ .char = c };
        const e = try s.parseEscape(true);
        return switch (e) {
            .char => |ch| .{ .char = ch },
            .set => |r| .{ .set = r },
            .negset => |r| .{ .set = try complement(s.alloc, r) },
            .wordb => .{ .char = 0x08 }, // \b inside [] is backspace
            .nwordb => s.fail("\\B is not valid inside a class"),
            .digits => |run| .{ .set = try s.digitsToPointRanges(run) },
            .named_ref => s.fail("named backreference inside a class"),
        };
    }

    /// A `\d` digit escape inside a class is Annex-B octal / literal digits —
    /// never a backreference. Returns point ranges for the resulting chars.
    fn digitsToPointRanges(s: *Parser, run: []const u16) Error![]const Range {
        const chars = try digitsToChars(s.alloc, run, s.flags.unicode, s.detail);
        var list = std.ArrayList(Range).empty;
        for (chars) |ch| try pushRange(&list, s.alloc, ch, ch);
        return list.toOwnedSlice(s.alloc);
    }

    fn parseEscape(s: *Parser, in_class: bool) Error!Esc {
        const c = s.take() orelse return s.fail("trailing backslash");
        switch (c) {
            'd' => return .{ .set = &set_digit },
            'w' => return .{ .set = &set_word },
            's' => return .{ .set = &set_space },
            'D' => return .{ .negset = &set_digit },
            'W' => return .{ .negset = &set_word },
            'S' => return .{ .negset = &set_space },
            'b' => return if (in_class) .{ .char = 0x08 } else .wordb,
            'B' => return if (in_class)
                s.fail("\\B is not valid inside a class")
            else
                .nwordb,
            'n' => return .{ .char = '\n' },
            'r' => return .{ .char = '\r' },
            't' => return .{ .char = '\t' },
            'f' => return .{ .char = 0x0C },
            'v' => return .{ .char = 0x0B },
            '0'...'9' => return s.decimalEscape(),
            'x' => {
                if (s.takeHex(2)) |cp| return .{ .char = cp };
                if (s.flags.unicode) return s.fail("invalid \\x escape");
                return .{ .char = 'x' };
            },
            'u' => {
                if (s.flags.unicode and s.peek() == @as(u16, '{')) {
                    s.pos += 1;
                    return .{ .char = try s.parseBracedCodepoint() };
                }
                if (s.takeHex(4)) |cp| return .{ .char = cp };
                if (s.flags.unicode) return s.fail("invalid \\u escape");
                return .{ .char = 'u' };
            },
            'c' => {
                if (s.peek()) |lc| {
                    if (isAlpha16(lc)) {
                        s.pos += 1;
                        return .{ .char = lc & 0x1F };
                    }
                }
                if (s.flags.unicode) return s.fail("invalid \\c escape");
                return .{ .char = 'c' };
            },
            'k' => {
                if (s.peek() == @as(u16, '<')) {
                    s.pos += 1;
                    const start = s.pos;
                    while (s.pos < s.src.len and s.src[s.pos] != '>') : (s.pos += 1) {}
                    if (s.pos >= s.src.len or s.pos == start)
                        return s.fail("unterminated \\k<name>");
                    const name = try unitsToUtf8(s.alloc, s.src[start..s.pos]);
                    s.pos += 1;
                    return .{ .named_ref = name };
                }
                if (s.flags.unicode) return s.fail("invalid \\k escape");
                return .{ .char = 'k' };
            },
            'p', 'P' => return s.fail("unicode property escapes are not supported"),
            else => {
                // Syntax characters always escape to themselves; anything
                // else is an identity escape in non-u mode, an error in u.
                if (s.flags.unicode) {
                    switch (c) {
                        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {},
                        else => return s.fail("invalid identity escape in unicode mode"),
                    }
                }
                return .{ .char = c };
            },
        }
    }

    fn decimalEscape(s: *Parser) Error!Esc {
        // Read the whole digit run: `\12` resolves to a backref when the
        // pattern has >= 12 groups, else degrades to Annex-B octal or
        // identity digits — decided at emit time once group_count is final.
        const start = s.pos - 1; // first digit already consumed
        while (s.pos < s.src.len and isDigit16(s.src[s.pos])) : (s.pos += 1) {}
        return .{ .digits = s.src[start..s.pos] };
    }

    fn takeHex(s: *Parser, n: usize) ?u32 {
        if (s.pos + n > s.src.len) return null;
        var v: u32 = 0;
        for (s.src[s.pos .. s.pos + n]) |u| {
            if (u > 0xFF) return null;
            const d = std.fmt.charToDigit(@intCast(u), 16) catch return null;
            v = v * 16 + d;
        }
        s.pos += n;
        return v;
    }

    fn parseBracedCodepoint(s: *Parser) Error!u32 {
        var v: u32 = 0;
        var nd: usize = 0;
        while (s.peek()) |u| {
            if (u == '}') break;
            if (u > 0xFF) return s.fail("bad \\u{...} codepoint");
            const d = std.fmt.charToDigit(@intCast(u), 16) catch return s.fail("bad \\u{...} codepoint");
            v = std.math.mul(u32, v, 16) catch return s.fail("codepoint out of range");
            v = std.math.add(u32, v, d) catch return s.fail("codepoint out of range");
            s.pos += 1;
            nd += 1;
        }
        if (nd == 0 or s.peek() != @as(u16, '}')) return s.fail("unterminated \\u{...}");
        s.pos += 1;
        if (v > 0x10FFFF) return s.fail("codepoint out of range");
        return v;
    }
};

const ClassTerm = union(enum) {
    char: u32,
    set: []const Range,

    /// The term's contributing ranges; for a lone char it is the point.
    fn spans(t: ClassTerm, alloc: Allocator) error{OutOfMemory}![]const Range {
        return switch (t) {
            .set => |r| r,
            .char => |c| blk: {
                const r = try alloc.alloc(Range, 1);
                r[0] = .{ .lo = c, .hi = c };
                break :blk r;
            },
        };
    }
};

/// A `\d` digit run that is not a backreference becomes Annex-B octal
/// (leading 0-3 take up to 3 digits, 4-7 take 2) or literal digits (8, 9).
/// Returns the resulting codepoints. In unicode mode any such escape is an
/// error except a bare `\0`.
fn digitsToChars(alloc: Allocator, run: []const u16, unicode: bool, detail: *[]const u8) Error![]u32 {
    var out = std.ArrayList(u32).empty;
    var n: u32 = 0;
    for (run) |d| n = n * 10 + (d - '0');
    if (unicode) {
        if (run.len == 1 and run[0] == '0') {
            try out.append(alloc, 0);
            return out.toOwnedSlice(alloc);
        }
        detail.* = "backreference to a group that does not exist";
        return error.InvalidPattern;
    }
    if (run[0] == '8' or run[0] == '9') {
        for (run) |d| try out.append(alloc, d);
        return out.toOwnedSlice(alloc);
    }
    const limit: usize = if (run[0] <= '3') 3 else 2;
    var v: u32 = 0;
    var used: usize = 0;
    while (used < run.len and used < limit and run[used] >= '0' and run[used] <= '7') : (used += 1) {
        v = v * 8 + (run[used] - '0');
    }
    try out.append(alloc, v);
    while (used < run.len) : (used += 1) try out.append(alloc, run[used]);
    return out.toOwnedSlice(alloc);
}

fn unitsToUtf8(alloc: Allocator, units: []const u16) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (units) |u| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(u, &buf) catch return error.InvalidPattern;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

fn pushRange(list: *std.ArrayList(Range), alloc: Allocator, lo: u32, hi: u32) Error!void {
    var r = Range{ .lo = lo, .hi = hi };
    var i: usize = 0;
    while (i < list.items.len) {
        const cur = list.items[i];
        if (r.hi + 1 < cur.lo) break;
        if (cur.hi + 1 < r.lo) {
            i += 1;
            continue;
        }
        r.lo = @min(r.lo, cur.lo);
        r.hi = @max(r.hi, cur.hi);
        _ = list.orderedRemove(i);
    }
    try list.insert(alloc, i, r);
}

/// Extend a range set with the canonicalized image of each member.
fn foldRanges(list: *std.ArrayList(Range), alloc: Allocator) Error!void {
    const orig = try alloc.dupe(Range, list.items);
    defer alloc.free(orig);
    for (orig) |r| {
        var c = r.lo;
        while (c <= r.hi) : (c += 1) {
            if (c > 0xFFFF) break;
            const cu = canon(@intCast(c));
            if (cu != c) try pushRange(list, alloc, cu, cu);
        }
    }
}

/// Complement a sorted disjoint range list over [0, 0x10FFFF].
fn complement(alloc: Allocator, ranges: []const Range) Error![]const Range {
    var out = std.ArrayList(Range).empty;
    var lo: u32 = 0;
    for (ranges) |r| {
        if (r.lo > lo) try out.append(alloc, .{ .lo = lo, .hi = r.lo - 1 });
        lo = r.hi + 1;
    }
    if (lo <= 0x10FFFF) try out.append(alloc, .{ .lo = lo, .hi = 0x10FFFF });
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------------
// Emission — AST to instruction stream. `subs` and `mark_count` are shared
// across the top program and every look-around body.

const Emitter = struct {
    alloc: Allocator,
    p: *Parser,
    prog: std.ArrayList(Inst) = .empty,
    subs: *std.ArrayList([]const Inst),
    mark_count: *u16,
    look_depth: u32 = 0,

    fn emit(e: *Emitter, inst: Inst) Error!void {
        if (e.prog.items.len >= max_insts) {
            e.p.detail.* = "regular expression is too large when unrolled";
            return error.InvalidPattern;
        }
        try e.prog.append(e.alloc, inst);
    }

    fn emitSeq(e: *Emitter, nodes: []const Node) Error!void {
        for (nodes) |n| try e.emitNode(n);
    }

    fn emitNode(e: *Emitter, node: Node) Error!void {
        switch (node) {
            .empty => {},
            .char => |c| try e.emitChar(c),
            .any => try e.emit(.{ .op = .any }),
            .class => |ci| try e.emit(.{ .op = .class, .a = ci }),
            .bol => try e.emit(.{ .op = .bol }),
            .eol => try e.emit(.{ .op = .eol }),
            .wordb => try e.emit(.{ .op = .wordb }),
            .nwordb => try e.emit(.{ .op = .nwordb }),
            .digits => |run| try e.emitDigits(run),
            .named_ref => |name| try e.emitNamedRef(name),
            .group => |g| {
                if (g.index != 0)
                    try e.emit(.{ .op = .save, .a = 2 * @as(u32, g.index) });
                try e.emitSeq(g.body);
                if (g.index != 0)
                    try e.emit(.{ .op = .save, .a = 2 * @as(u32, g.index) + 1 });
            },
            .look => |l| {
                if (e.look_depth >= max_look_depth) {
                    e.p.detail.* = "look-around nested too deep";
                    return error.InvalidPattern;
                }
                var sub = Emitter{
                    .alloc = e.alloc,
                    .p = e.p,
                    .subs = e.subs,
                    .mark_count = e.mark_count,
                    .look_depth = e.look_depth + 1,
                };
                try sub.emitSeq(l.body);
                try sub.emit(.{ .op = .match });
                const sub_prog = try sub.prog.toOwnedSlice(e.alloc);
                const idx: u32 = @intCast(e.subs.items.len);
                try e.subs.append(e.alloc, sub_prog);
                var flags: u32 = 0;
                if (l.neg) flags |= 1;
                if (l.behind) flags |= 2;
                try e.emit(.{ .op = .look, .a = idx, .b = flags });
            },
            .alt => |alts| {
                if (alts.len == 1) {
                    try e.emitSeq(alts[0]);
                    return;
                }
                var jmps = std.ArrayList(usize).empty;
                defer jmps.deinit(e.alloc);
                for (alts[0 .. alts.len - 1]) |alt| {
                    const sp = e.prog.items.len;
                    try e.emit(.{ .op = .split, .a = @intCast(sp + 1) });
                    try e.emitSeq(alt);
                    try jmps.append(e.alloc, e.prog.items.len);
                    try e.emit(.{ .op = .jmp });
                    e.prog.items[sp].b = @intCast(e.prog.items.len);
                }
                try e.emitSeq(alts[alts.len - 1]);
                const end: u32 = @intCast(e.prog.items.len);
                for (jmps.items) |jp| e.prog.items[jp] = .{ .op = .jmp, .a = end };
            },
            .rep => |r| try e.emitRep(r),
        }
    }

    fn emitChar(e: *Emitter, c: u16) Error!void {
        const cc: u16 = if (e.p.flags.ignore_case) canon(c) else c;
        try e.emit(.{ .op = .char, .a = cc });
    }

    fn emitRep(e: *Emitter, r: Rep) Error!void {
        var i: u32 = 0;
        while (i < r.min) : (i += 1) try e.emitNode(r.child.*);
        if (r.max == inf_bound) {
            const slot = e.mark_count.*;
            e.mark_count.* += 1;
            const loop_pc = e.prog.items.len;
            try e.emit(.{ .op = .split });
            const body_pc = e.prog.items.len;
            try e.emit(.{ .op = .mark, .a = slot });
            try e.emitNode(r.child.*);
            try e.emit(.{ .op = .loopback, .a = slot, .b = @intCast(loop_pc) });
            const end_pc = e.prog.items.len;
            e.prog.items[loop_pc] = .{
                .op = .split,
                .a = if (r.lazy) @intCast(end_pc) else @intCast(body_pc),
                .b = if (r.lazy) @intCast(body_pc) else @intCast(end_pc),
            };
            return;
        }
        var j: u32 = r.min;
        while (j < r.max) : (j += 1) {
            const sp = e.prog.items.len;
            try e.emit(.{ .op = .split });
            const body_pc = e.prog.items.len;
            try e.emitNode(r.child.*);
            const next_pc = e.prog.items.len;
            e.prog.items[sp] = .{
                .op = .split,
                .a = if (r.lazy) @intCast(next_pc) else @intCast(body_pc),
                .b = if (r.lazy) @intCast(body_pc) else @intCast(next_pc),
            };
        }
    }

    fn emitDigits(e: *Emitter, run: []const u16) Error!void {
        var n: u32 = 0;
        for (run) |d| n = n *| 10 +| (d - '0');
        if (n >= 1 and n <= e.p.group_count) {
            try e.emit(.{ .op = .backref, .a = n });
            return;
        }
        const chars = try digitsToChars(e.alloc, run, e.p.flags.unicode, e.p.detail);
        for (chars) |c| try e.emitChar(@intCast(c));
    }

    fn emitNamedRef(e: *Emitter, name: []const u8) Error!void {
        for (e.p.names.items) |n| {
            if (std.mem.eql(u8, n.name, name)) {
                try e.emit(.{ .op = .backref, .a = n.index });
                return;
            }
        }
        if (e.p.names.items.len > 0 or e.p.flags.unicode) {
            e.p.detail.* = "named reference to a group that does not exist";
            return error.InvalidPattern;
        }
        // Annex B: with no named groups anywhere, `\k<name>` is literal text.
        try e.emitChar('k');
        try e.emitChar('<');
        for (name) |c| try e.emitChar(c);
        try e.emitChar('>');
    }
};

// --------------------------------------------------------------------
// Executor — recursive backtracking with a step budget. Each `split`/`save`
// tries its preferred branch by calling run() and falls back on false.

pub const Exec = struct {
    re: *const Regex,
    caps: []usize,
    marks: []usize,
    alloc: Allocator,
    steps: usize = 0,
    depth: usize = 0,
    expect_end: ?usize = null,
    input: []const u16 = &.{},

    pub fn init(alloc: Allocator, re: *const Regex) Error!Exec {
        const caps = try alloc.alloc(usize, 2 * (re.group_count + 1));
        const marks = try alloc.alloc(usize, @max(re.mark_count, 1));
        return .{ .re = re, .caps = caps, .marks = marks, .alloc = alloc };
    }

    /// The first match at or after `pos` — exactly at `pos` when sticky.
    pub fn next(e: *Exec, input: []const u16, pos: usize) Error!?Match {
        e.input = input;
        if (e.re.flags.sticky) return try e.matchStart(pos);
        var p = pos;
        while (p <= input.len) : (p += 1) {
            if (try e.matchStart(p)) |m| return m;
        }
        return null;
    }

    fn matchStart(e: *Exec, pos: usize) Error!?Match {
        @memset(e.caps, unset);
        if (!try e.run(e.re.prog, 0, pos)) return null;
        const groups = try e.alloc.alloc(?Span, e.re.group_count);
        var g: usize = 0;
        while (g < e.re.group_count) : (g += 1) {
            const a = e.caps[2 * (g + 1)];
            const b = e.caps[2 * (g + 1) + 1];
            groups[g] = if (a != unset and b != unset) Span{ .start = a, .end = b } else null;
        }
        return .{ .start = e.caps[0], .end = e.caps[1], .groups = groups };
    }

    /// (codepoint, width in u16 units) at pos; astral pairs are one
    /// codepoint only under the u flag.
    fn charAt(e: *Exec, pos: usize) struct { cp: u32, w: usize } {
        const u = e.input[pos];
        if (e.re.flags.unicode and u >= 0xD800 and u <= 0xDBFF and
            pos + 1 < e.input.len and
            e.input[pos + 1] >= 0xDC00 and e.input[pos + 1] <= 0xDFFF)
        {
            return .{
                .cp = 0x10000 + ((@as(u32, u - 0xD800) << 10) | (e.input[pos + 1] - 0xDC00)),
                .w = 2,
            };
        }
        return .{ .cp = u, .w = 1 };
    }

    fn inRanges(ranges: []const Range, cp: u32) bool {
        var lo: usize = 0;
        var hi: usize = ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = ranges[mid];
            if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return true;
        }
        return false;
    }

    fn run(e: *Exec, prog: []const Inst, pc_in: usize, pos_in: usize) Error!bool {
        var pc = pc_in;
        var pos = pos_in;
        e.depth += 1;
        defer e.depth -= 1;
        if (e.depth > max_depth) return error.StepLimit;
        while (true) {
            e.steps += 1;
            if (e.steps > max_steps) return error.StepLimit;
            const inst = prog[pc];
            switch (inst.op) {
                .match => {
                    if (e.expect_end) |ee| return pos == ee;
                    return true;
                },
                .char => {
                    if (pos >= e.input.len) return false;
                    const u = e.input[pos];
                    if ((if (e.re.flags.ignore_case) canon(u) else u) != inst.a) return false;
                    pos += 1;
                    pc += 1;
                },
                .any => {
                    if (pos >= e.input.len) return false;
                    if (!e.re.flags.dotall and isLineTerm(e.input[pos])) return false;
                    pos += e.charAt(pos).w;
                    pc += 1;
                },
                .class => {
                    if (pos >= e.input.len) return false;
                    const cw = e.charAt(pos);
                    var cp = cw.cp;
                    if (e.re.flags.ignore_case and cp <= 0xFFFF) cp = canon(@intCast(cp));
                    const cl = e.re.classes[inst.a];
                    if (inRanges(cl.ranges, cp) == cl.negated) return false;
                    pos += cw.w;
                    pc += 1;
                },
                .bol => {
                    const ok = pos == 0 or
                        (e.re.flags.multiline and isLineTerm(e.input[pos - 1]));
                    if (!ok) return false;
                    pc += 1;
                },
                .eol => {
                    const ok = pos == e.input.len or
                        (e.re.flags.multiline and isLineTerm(e.input[pos]));
                    if (!ok) return false;
                    pc += 1;
                },
                .wordb, .nwordb => {
                    const left = pos > 0 and isWordChar(e.input[pos - 1]);
                    const right = pos < e.input.len and isWordChar(e.input[pos]);
                    if ((left != right) != (inst.op == .wordb)) return false;
                    pc += 1;
                },
                .backref => {
                    const a = e.caps[2 * inst.a];
                    const b = e.caps[2 * inst.a + 1];
                    if (a == unset or b == unset) {
                        // A group that did not participate matches empty.
                        pc += 1;
                        continue;
                    }
                    const len = b - a;
                    if (pos + len > e.input.len) return false;
                    for (0..len) |k| {
                        const want = e.input[a + k];
                        const got = e.input[pos + k];
                        if (e.re.flags.ignore_case) {
                            if (canon(got) != canon(want)) return false;
                        } else if (got != want) return false;
                    }
                    pos += len;
                    pc += 1;
                },
                .save => {
                    const old = e.caps[inst.a];
                    e.caps[inst.a] = pos;
                    if (try e.run(prog, pc + 1, pos)) return true;
                    e.caps[inst.a] = old;
                    return false;
                },
                .jmp => pc = inst.a,
                .split => {
                    if (try e.run(prog, inst.a, pos)) return true;
                    pc = inst.b;
                },
                .mark => {
                    e.marks[inst.a] = pos;
                    pc += 1;
                },
                .loopback => {
                    if (pos == e.marks[inst.a]) return false;
                    pc = inst.b;
                },
                .look => {
                    if (!try e.runLook(inst, pos)) return false;
                    pc += 1;
                },
            }
        }
    }

    fn runLook(e: *Exec, inst: Inst, pos: usize) Error!bool {
        const neg = inst.b & 1 != 0;
        const behind = inst.b & 2 != 0;
        const sub = e.re.subs[inst.a];
        const saved_end = e.expect_end;
        defer e.expect_end = saved_end;
        if (!behind) {
            const snapshot = try e.alloc.dupe(usize, e.caps);
            e.expect_end = null;
            const ok = try e.run(sub, 0, pos);
            if (!ok or neg) @memcpy(e.caps, snapshot);
            // Positive look-ahead keeps the captures it set on success;
            // negative look-ahead always resets them.
            return ok != neg;
        }
        // Look-behind: try every start position ascending, so the longest
        // (earliest) match wins like JS's reversed evaluation.
        var s: usize = 0;
        while (s <= pos) : (s += 1) {
            const snapshot = try e.alloc.dupe(usize, e.caps);
            e.expect_end = pos;
            const ok = try e.run(sub, 0, s);
            e.expect_end = saved_end;
            if (ok) {
                if (neg) @memcpy(e.caps, snapshot);
                return !neg;
            }
            @memcpy(e.caps, snapshot);
        }
        return neg;
    }
};

// --------------------------------------------------------------------
// Public compile / match

/// Compile `pattern` (UTF-8 with regex escapes still present) into a Regex.
/// `detail` gets a short human-readable reason on failure.
pub fn compile(
    alloc: Allocator,
    pattern: []const u8,
    flags: Flags,
    detail: *[]const u8,
) Error!Regex {
    const units = try utf8ToUtf16(alloc, pattern);
    var p = Parser{
        .src = units,
        .alloc = alloc,
        .flags = flags,
        .detail = detail,
    };
    const root_nodes = try p.parseAll();
    if (p.group_count > 98) {
        p.detail.* = "too many capture groups";
        return error.InvalidPattern;
    }
    var subs = std.ArrayList([]const Inst).empty;
    var mark_count: u16 = 0;
    var em = Emitter{
        .alloc = alloc,
        .p = &p,
        .subs = &subs,
        .mark_count = &mark_count,
    };
    try em.emit(.{ .op = .save, .a = 0 });
    try em.emitSeq(root_nodes);
    try em.emit(.{ .op = .save, .a = 1 });
    try em.emit(.{ .op = .match });
    return .{
        .prog = try em.prog.toOwnedSlice(alloc),
        .classes = try p.classes.toOwnedSlice(alloc),
        .subs = try subs.toOwnedSlice(alloc),
        .group_count = p.group_count,
        .mark_count = mark_count,
        .names = try p.names.toOwnedSlice(alloc),
        .flags = flags,
    };
}
