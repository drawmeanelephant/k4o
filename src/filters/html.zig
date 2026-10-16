//! HTML cleanup — knap 0.6.0 filter group.
//!
//! remove_attr / strip_attr / remove_tags / replace_tags / strip_tags /
//! strip_md (alias stripmd). Semantics probed from the knap 0.6.0 oracle
//! (tools/differential); KNAP-FIDELITY.md tracks the quirks.
//!
//! Input contract, oracle-observed: a single-element array holding a
//! primitive unwraps before filtering; any other array or object is
//! serialized to compact JSON and the text is transformed as one string
//! (escapes like \" therefore leak into markup — remove_attr on
//! {"k":"<b a=\"1\">"} yields `<b 1>` because `a=\"` is not a valued token).

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "remove_attr",
    "strip_attr",
    "remove_tags",
    "replace_tags",
    "strip_tags",
    "strip_md",
    "stripmd",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    const name = call.name;
    if (std.mem.eql(u8, name, "remove_attr")) {
        const list = try nameParams(it, call);
        return overInput(it, input, list.items, removeAttrText);
    }
    if (std.mem.eql(u8, name, "strip_attr")) {
        const list = try nameParams(it, call);
        return overInput(it, input, list.items, stripAttrText);
    }
    if (std.mem.eql(u8, name, "remove_tags")) {
        const list = try nameParams(it, call);
        return overInput(it, input, list.items, removeTagsText);
    }
    if (std.mem.eql(u8, name, "replace_tags")) {
        const list = try renameParams(it, call);
        return overInput(it, input, list.items, replaceTagsText);
    }
    if (std.mem.eql(u8, name, "strip_tags")) {
        const list = try nameParams(it, call);
        return overInput(it, input, list.items, stripTagsText);
    }
    if (std.mem.eql(u8, name, "strip_md") or std.mem.eql(u8, name, "stripmd")) {
        return overInput(it, input, {}, stripMdText);
    }
    return null;
}

// --------------------------------------------------------------------
// Filter parameters.

/// `.value` params evaluated to text (bare words resolve against the data
/// root); `key:value` pairs and arrows are ignored by the oracle here.
fn nameParams(it: *Interp, call: parse.FilterCall) Error!std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).empty;
    for (call.params) |p| {
        switch (p) {
            .value => |e| {
                const v = try it.evalParam(e);
                try list.append(it.alloc, try filters.jsToString(it.alloc, v));
            },
            else => {},
        }
    }
    return list;
}

const Rename = struct { from: []const u8, to: ?[]const u8 };

/// replace_tags: `"old":"new"` pairs rename, bare names remove the tag.
/// Every name must look like a tag name or the oracle errors
/// ("replace_tags requires tag names").
fn renameParams(it: *Interp, call: parse.FilterCall) Error!std.ArrayList(Rename) {
    var list = std.ArrayList(Rename).empty;
    for (call.params) |p| {
        switch (p) {
            .value => |e| {
                const v = try it.evalParam(e);
                const from = try filters.jsToString(it.alloc, v);
                try checkTagName(it, call, from);
                try list.append(it.alloc, .{ .from = from, .to = null });
            },
            .pair => |pair| {
                const kv = try it.evalParam(pair.key);
                const vv = try it.evalParam(pair.value);
                const from = try filters.jsToString(it.alloc, kv);
                const to = try filters.jsToString(it.alloc, vv);
                try checkTagName(it, call, from);
                try checkTagName(it, call, to);
                try list.append(it.alloc, .{ .from = from, .to = to });
            },
            .arrow => return filters.badArg(it, call, "filter 'replace_tags' requires tag names", .{}),
        }
    }
    return list;
}

/// `[a-zA-Z][\w:-]*` — `b`, `h2`, `b-x`, `b_c`, `a:b` pass; `2b`, `_b`,
/// `b.` are rejected.
fn checkTagName(it: *Interp, call: parse.FilterCall, name: []const u8) Error!void {
    var ok = name.len > 0 and std.ascii.isAlphabetic(name[0]);
    if (ok) {
        for (name[1..]) |c| {
            if (!isNameStart(c) and c != '-' and c != ':') {
                ok = false;
                break;
            }
        }
    }
    if (!ok) {
        return filters.badArg(it, call, "filter 'replace_tags' requires tag names", .{});
    }
}

// --------------------------------------------------------------------
// Input handling.

/// normalizeInput, single-primitive unwrap, container serialization.
fn overInput(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .array => |arr| {
            if (arr.items.len == 1) switch (arr.items[0]) {
                .bool, .integer, .float, .number_string, .string =>
                    return overInput(it, &arr.items[0], ctx, f),
                else => {},
            };
            return serializeThen(it, v, ctx, f);
        },
        .object => return serializeThen(it, v, ctx, f),
        else => {
            const t = (try filters.scalarText(it.alloc, v.*)) orelse unreachable;
            return it.make(.{ .string = try f(ctx, it, t) });
        },
    }
}

fn serializeThen(
    it: *Interp,
    v: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    var buf: std.Io.Writer.Allocating = .init(it.alloc);
    try it.jsStringify(v, &buf);
    return it.make(.{ .string = try f(ctx, it, buf.written()) });
}

// --------------------------------------------------------------------
// Character classes shared by the tag scanners.

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isAttrNameChar(c: u8) bool {
    return isNameStart(c) or c == '-' or c == ':';
}

/// ASCII `\s`: space, tab, LF, CR, VT, FF.
fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d);
}

// --------------------------------------------------------------------
// remove_attr / strip_attr — tags are tokenized and rebuilt.
//
// A tag is `<`, optional `/`, a `\w` first char, `[^\s>/]*` more, then an
// optional attribute section that must begin with whitespace, then `>`.
// Anything else leaves the `<` literal (`<br/>`, `<br/ >`, `<!-- -->`,
// `a<b` all pass through untouched).
//
// The section is re-tokenized: attribute names are `[\w:-]+`, optionally
// followed by `=` and a `"..."`, `'...'` or bare (`[^\s"'<>]+`) value —
// quoted values cannot contain a backslash, which is why attributes vanish
// inside serialized container input (`a=\"` degrades to a bare `a`).
// Garbage between tokens is dropped; a `/` that survives after the last
// token re-emits as ` />`.

const AttrMode = enum { remove, keep };

const AttrCtx = struct { mode: AttrMode, names: []const []const u8 };

fn removeAttrText(targets: []const []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    return rewriteAttrTags(it, s, .{ .mode = .remove, .names = targets });
}

fn stripAttrText(allow: []const []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    return rewriteAttrTags(it, s, .{ .mode = .keep, .names = allow });
}

fn rewriteAttrTags(it: *Interp, s: []const u8, ctx: AttrCtx) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '<') {
            try out.append(it.alloc, s[i]);
            i += 1;
            continue;
        }
        var j = i + 1;
        var closing = false;
        if (j < s.len and s[j] == '/') {
            closing = true;
            j += 1;
        }
        if (j >= s.len or !isNameStart(s[j])) {
            try out.append(it.alloc, '<');
            i += 1;
            continue;
        }
        const name_start = j;
        while (j < s.len and !isSpace(s[j]) and s[j] != '>' and s[j] != '/') j += 1;
        const tag_name = s[name_start..j];
        var section: []const u8 = "";
        if (j < s.len and isSpace(s[j])) {
            const sec_start = j;
            while (j < s.len and s[j] != '>') j += 1;
            if (j == s.len) {
                try out.append(it.alloc, '<');
                i += 1;
                continue;
            }
            section = s[sec_start..j];
        } else if (j >= s.len or s[j] != '>') {
            try out.append(it.alloc, '<');
            i += 1;
            continue;
        }
        try emitAttrTag(&out, it, closing, tag_name, section, ctx);
        i = j + 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn emitAttrTag(
    out: *std.ArrayList(u8),
    it: *Interp,
    closing: bool,
    tag_name: []const u8,
    section: []const u8,
    ctx: AttrCtx,
) Error!void {
    try out.append(it.alloc, '<');
    if (closing) try out.append(it.alloc, '/');
    try out.appendSlice(it.alloc, tag_name);
    var p: usize = 0;
    var last_token_end: usize = 0;
    while (p < section.len) {
        while (p < section.len and !isAttrNameChar(section[p])) p += 1;
        if (p == section.len) break;
        const ns = p;
        while (p < section.len and isAttrNameChar(section[p])) p += 1;
        const aname = section[ns..p];
        var end = p;
        var quoted = false;
        var q = p;
        while (q < section.len and isSpace(section[q])) q += 1;
        if (q < section.len and section[q] == '=') {
            q += 1;
            while (q < section.len and isSpace(section[q])) q += 1;
            if (q < section.len) {
                const qc = section[q];
                if (qc == '"' or qc == '\'') {
                    var r = q + 1;
                    while (r < section.len and section[r] != qc and section[r] != '\\') r += 1;
                    if (r < section.len and section[r] == qc) {
                        end = r + 1;
                        quoted = true;
                    }
                } else {
                    var r = q;
                    while (r < section.len and !isSpace(section[r]) and
                        section[r] != '"' and section[r] != '\'' and
                        section[r] != '<' and section[r] != '>') r += 1;
                    if (r > q) end = r;
                }
            }
        }
        // strip_attr only honours ` name="..."` tokens — the name must be
        // preceded by whitespace (`a="1"b="2"` drops `b="2"`).
        const keep = switch (ctx.mode) {
            .remove => !nameIn(ctx.names, aname),
            .keep => quoted and isSpace(section[ns - 1]) and nameIn(ctx.names, aname),
        };
        if (keep) {
            try out.append(it.alloc, ' ');
            try out.appendSlice(it.alloc, section[ns..end]);
        }
        last_token_end = end;
        p = end;
    }
    // remove_attr re-emits a trailing `/` as ` />`; strip_attr never does.
    if (ctx.mode == .remove and
        std.mem.indexOfScalar(u8, section[last_token_end..], '/') != null)
    {
        try out.appendSlice(it.alloc, " /");
    }
    try out.append(it.alloc, '>');
}

fn nameIn(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

// --------------------------------------------------------------------
// remove_tags — `</?name\b[^>]*>` case-insensitively; the tag vanishes but
// its content stays. `<b-x>` counts as `b` (word boundary), `<b2>` does
// not; unterminated tags stay literal.

fn removeTagsText(targets: []const []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '<') {
            var j = i + 1;
            if (j < s.len and s[j] == '/') j += 1;
            for (targets) |n| {
                if (n.len == 0) continue;
                if (j + n.len > s.len or !std.ascii.eqlIgnoreCase(s[j..][0..n.len], n)) continue;
                const after = j + n.len;
                if (after < s.len and isNameStart(s[after])) continue;
                var k = after;
                while (k < s.len and s[k] != '>') k += 1;
                if (k == s.len) break;
                i = k + 1;
                continue :outer;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

// --------------------------------------------------------------------
// replace_tags — case-SENSITIVE `<name(\s[^>]*)?>` and `</name>` rename;
// a bare name param removes the tag instead. Attributes ride along
// verbatim; `<b-x>` and `<br/>` do not match `b`/`br` (only whitespace or
// `>` may follow the name).

fn replaceTagsText(maps: []const Rename, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '<') {
            if (i + 1 < s.len and s[i + 1] == '/') {
                for (maps) |m| {
                    const j = i + 2;
                    if (j + m.from.len < s.len and
                        std.mem.eql(u8, s[j..][0..m.from.len], m.from) and
                        s[j + m.from.len] == '>')
                    {
                        if (m.to) |to| {
                            try out.appendSlice(it.alloc, "</");
                            try out.appendSlice(it.alloc, to);
                            try out.append(it.alloc, '>');
                        }
                        i = j + m.from.len + 1;
                        continue :outer;
                    }
                }
            } else {
                for (maps) |m| {
                    const j = i + 1;
                    if (j + m.from.len >= s.len) continue;
                    if (!std.mem.eql(u8, s[j..][0..m.from.len], m.from)) continue;
                    const after = j + m.from.len;
                    if (s[after] == '>') {
                        if (m.to) |to| {
                            try out.append(it.alloc, '<');
                            try out.appendSlice(it.alloc, to);
                            try out.append(it.alloc, '>');
                        }
                        i = after + 1;
                        continue :outer;
                    }
                    if (isSpace(s[after])) {
                        var k = after;
                        while (k < s.len and s[k] != '>') k += 1;
                        if (k == s.len) break;
                        if (m.to) |to| {
                            try out.append(it.alloc, '<');
                            try out.appendSlice(it.alloc, to);
                            try out.appendSlice(it.alloc, s[after..k]);
                            try out.append(it.alloc, '>');
                        }
                        i = k + 1;
                        continue :outer;
                    }
                }
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

// --------------------------------------------------------------------
// strip_tags — every `<[^>]+>?` span is dropped (an unterminated `<...`
// runs to EOF; a bare `<>` stays). Allowlisted tags survive verbatim when
// the name right after `<` or `</` matches a list entry at a word
// boundary. Entities decode afterwards on the whole output — a fixed
// twelve-name table plus `&#d;`/`&#xd;` through String.fromCharCode,
// looping until stable (`&amp;lt;` -> `<`).

// Decoding is one pass per entity in this order — `&amp;amp;` becomes
// `&amp;` (amp expands once) while `&amp;lt;` becomes `<` (amp's pass
// leaves `&lt;` for lt's pass). `&nbsp;` decodes before `&amp;`
// (`&amp;nbsp;` stays `&nbsp;`); numerics run last (`&amp;#65;` -> `A`).
const Entity = struct { name: []const u8, cp: u21 };

const named_entities = [_]Entity{
    .{ .name = "nbsp", .cp = ' ' },
    .{ .name = "amp", .cp = '&' },
    .{ .name = "lt", .cp = '<' },
    .{ .name = "gt", .cp = '>' },
    .{ .name = "quot", .cp = '"' },
    .{ .name = "hellip", .cp = 0x2026 },
    .{ .name = "ndash", .cp = 0x2013 },
    .{ .name = "mdash", .cp = 0x2014 },
    .{ .name = "lsquo", .cp = 0x2018 },
    .{ .name = "rsquo", .cp = 0x2019 },
    .{ .name = "ldquo", .cp = 0x201C },
    .{ .name = "rdquo", .cp = 0x201D },
};

fn stripTagsText(allow: []const []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '<') {
            try out.append(it.alloc, s[i]);
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < s.len and s[j] != '>') j += 1;
        const inner = s[i + 1 .. j];
        if (inner.len == 0) {
            try out.append(it.alloc, '<');
            i += 1;
            continue;
        }
        if (j == s.len) {
            // Unterminated `<...`: dropped by a bare strip_tags, kept as
            // literal text once an allowlist is supplied.
            if (allow.len != 0) try out.appendSlice(it.alloc, s[i..]);
            break;
        }
        if (tagAllowed(inner, allow)) {
            try out.appendSlice(it.alloc, s[i .. j + 1]);
        }
        i = j + 1;
    }
    const decoded = try decodeEntities(it, out.items);
    var a: usize = 0;
    var b: usize = decoded.len;
    while (a < b and isSpace(decoded[a])) a += 1;
    while (b > a and isSpace(decoded[b - 1])) b -= 1;
    return decoded[a..b];
}

/// `^/?name` at a word boundary — `<b-x>`, `<b/>` and `</b/x>` all count
/// as `b`; `<b2>` does not.
fn tagAllowed(inner: []const u8, allow: []const []const u8) bool {
    const rest = if (inner.len > 0 and inner[0] == '/') inner[1..] else inner;
    for (allow) |n| {
        if (n.len == 0) continue;
        if (rest.len < n.len or !std.ascii.eqlIgnoreCase(rest[0..n.len], n)) continue;
        if (rest.len == n.len or !isNameStart(rest[n.len])) return true;
    }
    return false;
}

fn decodeEntities(it: *Interp, s: []const u8) Error![]const u8 {
    var cur = s;
    for (named_entities) |e| {
        cur = try replaceNamedEntity(it, cur, e);
    }
    return decodeNumericEntities(it, cur);
}

fn replaceNamedEntity(it: *Interp, s: []const u8, e: Entity) Error![]const u8 {
    if (std.mem.indexOf(u8, s, e.name) == null) return s;
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&' and i + 1 + e.name.len < s.len and
            std.mem.eql(u8, s[i + 1 ..][0..e.name.len], e.name) and
            s[i + 1 + e.name.len] == ';')
        {
            try appendCharCode(&out, it, e.cp);
            i += e.name.len + 2;
            continue;
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn decodeNumericEntities(it: *Interp, s: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, s, "&#") == null) return s;
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&' and i + 1 < s.len and s[i + 1] == '#') {
            var k = i + 2;
            var value: u32 = 0;
            var digits: usize = 0;
            if (k < s.len and s[k] == 'x') {
                k += 1;
                while (k < s.len and std.ascii.isHex(s[k])) : (k += 1) {
                    value = value *| 16 +| @as(u32, std.fmt.charToDigit(s[k], 16) catch unreachable);
                    digits += 1;
                }
            } else {
                while (k < s.len and std.ascii.isDigit(s[k])) : (k += 1) {
                    value = value *| 10 +| (s[k] - '0');
                    digits += 1;
                }
            }
            if (digits > 0 and k < s.len and s[k] == ';') {
                try appendCharCode(&out, it, @intCast(value & 0xFFFF));
                i = k + 1;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// String.fromCharCode: the codepoint is already mod 2^16; lone
/// surrogates encode as U+FFFD.
fn appendCharCode(out: *std.ArrayList(u8), it: *Interp, cp: u21) Error!void {
    const c: u21 = if (cp >= 0xD800 and cp <= 0xDFFF) 0xFFFD else cp;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
    try out.appendSlice(it.alloc, buf[0..n]);
}

// --------------------------------------------------------------------
// strip_md — an ordered list of oracle-observed rewrites. Each rule is a
// single left-to-right pass; later rules see earlier output, which is why
// `` `# x` `` stays `# x` (headings ran before code spans) and `> - item`
// stays `- item` (bullets ran before the blockquote did).

fn stripMdText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    var cur: []const u8 = s;
    cur = try mdHeadings(it, cur);
    cur = try mdHr(it, cur);
    cur = try mdImages(it, cur);
    cur = try mdWikiLink(it, cur, true);
    cur = try mdWikiLink(it, cur, false);
    cur = try mdLinks(it, cur);
    cur = try mdUrls(it, cur);
    cur = try mdEmptyBrackets(it, cur);
    cur = try mdFootnotes(it, cur);
    cur = try mdHtml(it, cur);
    cur = try mdCode(it, cur);
    for ([_]u8{ '*', '_' }) |m| cur = try mdDelim(it, cur, m, .{ .empty_ok = true });
    cur = try mdDelim(it, cur, '~', .{ .empty_ok = true, .width2 = true });
    cur = try mdWord(it, cur, '~');
    cur = try mdWord(it, cur, '^');
    cur = try mdDelim(it, cur, '=', .{ .empty_ok = true, .width2 = true });
    cur = try mdBullets(it, cur);
    cur = try mdBlockquote(it, cur);
    cur = try mdPipes(it, cur);
    cur = try mdCollapse(it, cur);
    return mdTrim(cur);
}

fn lineStart(s: []const u8, i: usize) bool {
    return i == 0 or s[i - 1] == '\n';
}

/// `^#+\s+` — `# x` loses its marker, a `#`-only line is eaten together
/// with its newline (`#` itself is whitespace before EOL), `#x` stays.
fn mdHeadings(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (lineStart(s, i) and s[i] == '#') {
            var j = i;
            while (j < s.len and s[j] == '#') j += 1;
            if (j < s.len and isSpace(s[j])) {
                while (j < s.len and isSpace(s[j])) j += 1;
                i = j;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `^-{3,}[^\S\n]*$` — a dashes-only line empties out; `---x` survives.
fn mdHr(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (lineStart(s, i) and s[i] == '-') {
            var j = i;
            while (j < s.len and s[j] == '-') j += 1;
            var k = j;
            while (k < s.len and isSpace(s[k]) and s[k] != '\n') k += 1;
            if (j - i >= 3 and (k == s.len or s[k] == '\n')) {
                i = k;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `![alt](url)` with a nonempty url drops entirely.
fn mdImages(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (findBracketLink(s, i + 1)) |m| {
                if (m.url_len > 0) {
                    i = m.end;
                    continue;
                }
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `[[a|b]]` keeps `b`; `[[a]]` keeps `a`. The piped form runs first so
/// `[[a|b|c]]` falls through to the plain rule and the pipe pass then
/// strips `|b|`.
fn mdWikiLink(it: *Interp, s: []const u8, piped: bool) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[' and i + 1 < s.len and s[i + 1] == '[') {
            if (piped) {
                var j = i + 2;
                while (j < s.len and s[j] != ']' and s[j] != '|') j += 1;
                if (j < s.len and s[j] == '|') {
                    const vs = j + 1;
                    var k = vs;
                    while (k < s.len and s[k] != ']' and s[k] != '|') k += 1;
                    if (k + 1 < s.len and s[k] == ']' and s[k + 1] == ']') {
                        try out.appendSlice(it.alloc, s[vs..k]);
                        i = k + 2;
                        continue;
                    }
                }
            } else {
                var j = i + 2;
                while (j < s.len and s[j] != ']') j += 1;
                if (j + 1 < s.len and s[j] == ']' and s[j + 1] == ']') {
                    try out.appendSlice(it.alloc, s[i + 2 .. j]);
                    i = j + 2;
                    continue;
                }
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `[text](url)` -> `text`; both sides must be nonempty (`[a]()` and
/// `[](u)` survive — the empty brackets get eaten by a later rule).
const BracketLink = struct { text_start: usize, text_end: usize, url_len: usize, end: usize };

fn findBracketLink(s: []const u8, open: usize) ?BracketLink {
    var j = open + 1;
    while (j < s.len and s[j] != ']') j += 1;
    if (j >= s.len or j + 1 >= s.len or s[j + 1] != '(') return null;
    var k = j + 2;
    while (k < s.len and s[k] != ')') k += 1;
    if (k == s.len) return null;
    return .{ .text_start = open + 1, .text_end = j, .url_len = k - (j + 2), .end = k + 1 };
}

fn mdLinks(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[') {
            if (findBracketLink(s, i)) |m| {
                if (m.text_end > m.text_start and m.url_len > 0) {
                    try out.appendSlice(it.alloc, s[m.text_start..m.text_end]);
                    i = m.end;
                    continue;
                }
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// Bare `http(s)://\S+` runs vanish (the url regex eats `)` and `>` too,
/// which is why `<https://x>` leaves a lone `<`).
fn mdUrls(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "http://") or
            std.mem.startsWith(u8, s[i..], "https://"))
        {
            while (i < s.len and !isSpace(s[i])) i += 1;
            continue;
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `[^ref]` footnote refs drop, nonempty (`[^]` stays; the `[^1]: ...`
/// definition line loses its marker the same way — the rest stays).
fn mdFootnotes(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[' and i + 1 < s.len and s[i + 1] == '^') {
            var j = i + 2;
            while (j < s.len and s[j] != ']') j += 1;
            if (j < s.len and j > i + 2) {
                i = j + 1;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `[]` / `[ ]` — brackets holding only whitespace vanish.
fn mdEmptyBrackets(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[') {
            var j = i + 1;
            while (j < s.len and isSpace(s[j])) j += 1;
            if (j < s.len and s[j] == ']') {
                i = j + 1;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `<[^>]+>` — stricter than strip_tags: an unterminated `<` stays.
fn mdHtml(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '<') {
            var j = i + 1;
            while (j < s.len and s[j] != '>') j += 1;
            if (j > i + 1 and j < s.len) {
                i = j + 1;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `` `code` `` keeps its text; content is `[^`]+` — nonempty and it may
/// span newlines (which is also why ``` ```x``` ``` degrades to ` ``x`` `).
fn mdCode(it: *Interp, s: []const u8) Error![]const u8 {
    return mdDelim(it, s, '`', .{ .nl_ok = true });
}

const DelimCfg = struct { empty_ok: bool = false, nl_ok: bool = false, width2: bool = false };

fn mdDelim(it: *Interp, s: []const u8, m: u8, comptime cfg: DelimCfg) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    const width: usize = if (cfg.width2) 2 else 1;
    var i: usize = 0;
    while (i < s.len) {
        if (i + width > s.len or s[i] != m or (width == 2 and s[i + 1] != m)) {
            try out.append(it.alloc, s[i]);
            i += 1;
            continue;
        }
        var j = i + width;
        if (width == 1) {
            // `m[^m\n]*m` (or `[^m]+` for code): the next marker closes.
            while (j < s.len and s[j] != m and (cfg.nl_ok or s[j] != '\n')) j += 1;
            if (j == s.len or s[j] != m or (!cfg.empty_ok and j == i + 1)) {
                try out.append(it.alloc, s[i]);
                i += 1;
                continue;
            }
        } else {
            // lazy `mm(.*?)mm`: first closing pair; `.` never crosses `\n`.
            var found = false;
            while (j + 1 < s.len) : (j += 1) {
                if (s[j] == '\n') break;
                if (s[j] == m and s[j + 1] == m) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try out.append(it.alloc, s[i]);
                i += 1;
                continue;
            }
        }
        try out.appendSlice(it.alloc, s[i + width .. j]);
        i = j + width;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `^sup^` / `~a~` — `m(\w+)m`: word-chars only, nonempty — `^^x^^` ->
/// `^x^` (the inner pair never forms), `^a b^` and `~a;b~` survive.
fn mdWord(it: *Interp, s: []const u8, m: u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == m) {
            var j = i + 1;
            while (j < s.len and isNameStart(s[j])) j += 1;
            if (j > i + 1 and j < s.len and s[j] == m) {
                try out.appendSlice(it.alloc, s[i + 1 .. j]);
                i = j + 1;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `^[-*+] ` — bullet markers drop marker plus exactly one space, and a
/// task checkbox written as `[]`/`[x]`/`[ ]` plus its trailing space goes
/// with it (but only inside the marker — `[x] a` elsewhere stays put).
fn mdBullets(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (lineStart(s, i) and (s[i] == '-' or s[i] == '*' or s[i] == '+') and
            i + 1 < s.len and s[i + 1] == ' ')
        {
            var k = i + 2;
            if (k < s.len and s[k] == '[') {
                var m = k + 1;
                while (m < s.len and s[m] != ']') m += 1;
                if (m < s.len and m - k <= 2 and m + 1 < s.len and s[m + 1] == ' ') {
                    k = m + 2;
                }
            }
            i = k;
            continue;
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `^>\s+` — `> q` unquotes; `>\n` swallows the marker plus the newline;
/// `>>` stays put.
fn mdBlockquote(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (lineStart(s, i) and s[i] == '>') {
            var j = i + 1;
            while (j < s.len and isSpace(s[j])) j += 1;
            if (j > i + 1) {
                i = j;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// `|...|` runs vanish — greedy within a line (`x | y | z` -> `x  z`,
/// `|only|bars|here` -> `here`), which also deletes whole table rows.
fn mdPipes(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '|') {
            var e = i + 1;
            while (e < s.len and s[e] != '\n') e += 1;
            var last: ?usize = null;
            var j = i + 1;
            while (j < e) : (j += 1) {
                if (s[j] == '|') last = j;
            }
            if (last) |j2| {
                i = j2 + 1;
                continue;
            }
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn mdCollapse(it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            var j = i;
            while (j < s.len and s[j] == '\n') j += 1;
            if (j - i >= 3) {
                try out.appendSlice(it.alloc, "\n\n");
            } else {
                try out.appendSlice(it.alloc, s[i..j]);
            }
            i = j;
            continue;
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn mdTrim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and isSpace(s[a])) a += 1;
    while (b > a and isSpace(s[b - 1])) b -= 1;
    return s[a..b];
}
