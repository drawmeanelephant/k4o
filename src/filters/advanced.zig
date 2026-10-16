//! Mini-languages and YAML — knap 0.6.0 filter group.
//!
//! `replace` pairs a quoted search value with a quoted replacement
//! (`replace:"a":"b"`, `replace:("a":"b","c":"d")`). A search written
//! `/pattern/flags` is a regex evaluated by src/re.zig — the bounded
//! engine mirrors JS RegExp semantics, including surrogate-pair splitting
//! under non-`u` patterns and `$`-forms in replacements. A spec that is not
//! slash-shaped, or whose flags are not in `gimsuy`, is a literal string;
//! a pattern `new RegExp` would reject silently skips its pair.
//!
//! `yaml` serializes block YAML (two-space nesting) or `yaml:flow` compact
//! JSON-shaped inline collections; strings are always double-quoted with an
//! escape set that additionally covers C1 controls and U+2028/29.
//! `yaml_property:"name"` emits `name: value` / `name:\n  block`.
//!
//! `map` and `template` remain stubbed — their batches land elsewhere.

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");
const engine = @import("../engine.zig");
const re = @import("../re.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "map",
    "template",
    "replace",
    "yaml",
    "yaml_property",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    if (std.mem.eql(u8, call.name, "replace")) return replaceFilter(it, call, input);
    if (std.mem.eql(u8, call.name, "yaml")) return yamlFilter(it, call, input);
    if (std.mem.eql(u8, call.name, "yaml_property")) return yamlProperty(it, call, input);
    if (std.mem.eql(u8, call.name, "map") or std.mem.eql(u8, call.name, "template")) {
        return filters.failAt(it, call.offset, "filter '{s}' is not implemented yet", .{call.name});
    }
    return null;
}

// --------------------------------------------------------------------
// replace

const Pair = struct { spec: []const u8, repl: []const u8 };

/// A Param must be a `"search":"repl"` pair of quoted literals — knap
/// rejects bare words, numbers and resolved paths alike.
fn literalPair(it: *Interp, call: parse.FilterCall, e: *const parse.Expr) Error!?[]const u8 {
    if (e.terms.len != 1) return null;
    const term = e.terms[0];
    if (term.filters.len != 0) return null;
    _ = it;
    _ = call;
    return switch (term.value) {
        .literal => |l| switch (l) {
            // Spec/repl keep the raw source — `"/\d+/g"` must still see
            // the `\d` that the string value would have eaten.
            .string => |s| s.raw,
            else => null,
        },
        else => null,
    };
}

fn replaceFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    if (call.params.len == 0) {
        return filters.badArg(it, call, "filter 'replace' requires search and replacement (e.g., replace:\"old\":\"new\")", .{});
    }
    var pairs = std.ArrayList(Pair).empty;
    for (call.params) |p| {
        switch (p) {
            .pair => |pr| {
                const spec = (try literalPair(it, call, pr.key)) orelse
                    return badQuoted(it, call);
                const repl = (try literalPair(it, call, pr.value)) orelse
                    return badQuoted(it, call);
                try pairs.append(it.alloc, .{ .spec = spec, .repl = repl });
            },
            else => return badQuoted(it, call),
        }
    }
    const text = try inputText(it, input);
    const out = try applyPairs(it, call, text, pairs.items);
    return it.make(.{ .string = out });
}

fn badQuoted(it: *Interp, call: parse.FilterCall) Error {
    return filters.badArg(it, call, "filter 'replace' values must be quoted (e.g., replace:\"old\":\"new\" or replace:\"text\":\"\")", .{});
}

/// Input coercion: scalars stringify JS-style, containers serialize to
/// compact JSON first (keys and quotes are replaceable text), null is "".
fn inputText(it: *Interp, input: *const Value) Error![]const u8 {
    switch (input.*) {
        .null => return "",
        .string => |s| return s,
        .bool => |b| return if (b) "true" else "false",
        .integer => |i| return std.fmt.allocPrint(it.alloc, "{d}", .{i}),
        .float => |f| return engine.jsFloat(it.alloc, f),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return s;
            return engine.jsFloat(it.alloc, f);
        },
        .array, .object => {
            var buf = std.Io.Writer.Allocating.init(it.alloc);
            try it.jsStringify(input, &buf);
            return buf.written();
        },
    }
}

/// The second unescape layer knap applies to replace arguments: the
/// template string `\\n` arrives as `\n` and becomes a newline here.
/// `\n` `\t` `\r` map to control bytes, `\\` to a lone backslash, and any
/// other `\X` drops the backslash — the same map as template strings.
fn unescapeArg(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            try out.append(alloc, switch (s[i + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => s[i + 1],
            });
            i += 2;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `/pattern/flags` detection: first `/` at index 0, last `/` is the
/// delimiter (embedded slashes are pattern text), pattern must be
/// non-empty, and every flag char must be in `gimsuy`. Anything else is a
/// literal search string.
const Spec = struct { pattern: []const u8, flags: re.Flags };

fn regexSpec(spec: []const u8) ?Spec {
    if (spec.len < 2 or spec[0] != '/') return null;
    const last = std.mem.lastIndexOfScalar(u8, spec, '/') orelse return null;
    if (last == 0 or last == 1) return null; // `//...` has no pattern body
    var flags = re.Flags{};
    for (spec[last + 1 ..]) |f| {
        switch (f) {
            'g' => flags.global = true,
            'i' => flags.ignore_case = true,
            'm' => flags.multiline = true,
            's' => flags.dotall = true,
            'u' => flags.unicode = true,
            'y' => flags.sticky = true,
            else => return null,
        }
    }
    return .{ .pattern = spec[1..last], .flags = flags };
}

fn applyPairs(
    it: *Interp,
    call: parse.FilterCall,
    text_in: []const u8,
    pairs: []const Pair,
) Error![]const u8 {
    var text = text_in;
    for (pairs) |p| {
        const repl_u16 = try re.utf8ToUtf16(it.alloc, try unescapeArg(it.alloc, p.repl));
        const units = try re.utf8ToUtf16(it.alloc, text);
        if (regexSpec(p.spec)) |spec| {
            var detail: []const u8 = "";
            const rex = re.compile(it.alloc, spec.pattern, spec.flags, &detail) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidPattern => continue, // knap: new RegExp throws -> pair is a no-op
                error.StepLimit => unreachable,
            };
            text = try applyRegex(it, call, &rex, units, repl_u16);
        } else {
            const needle = try re.utf8ToUtf16(it.alloc, try unescapeArg(it.alloc, p.spec));
            text = try applyLiteral(it.alloc, units, needle, repl_u16);
        }
    }
    return text;
}

/// JS `replace` over UTF-16 units: global iterates with the empty-match +1
/// advance; sticky anchors at the current position only.
fn applyRegex(
    it: *Interp,
    call: parse.FilterCall,
    rex: *const re.Regex,
    units: []const u16,
    repl: []const u16,
) Error![]const u8 {
    var exec = re.Exec.init(it.alloc, rex) catch return error.OutOfMemory;
    var out = std.ArrayList(u16).empty;
    var cursor: usize = 0;
    var pos: usize = 0;
    while (true) {
        const m = exec.next(units, pos) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern => unreachable,
            error.StepLimit => return filters.failAt(it, call.offset, "filter 'replace' regex exceeded the step limit (the pattern backtracks too much)", .{}),
        } orelse break;
        try out.appendSlice(it.alloc, units[cursor..m.start]);
        const sub = try substitute(it.alloc, repl, units, m, rex);
        try out.appendSlice(it.alloc, sub);
        cursor = m.end;
        if (!rex.flags.global) break;
        pos = m.end;
        if (m.end == m.start) pos += advanceWidth(rex, units, pos);
        if (pos > units.len) break;
    }
    try out.appendSlice(it.alloc, units[cursor..]);
    return re.utf16ToUtf8Lossy(it.alloc, out.items);
}

/// JS `advanceStringIndex`: one UTF-16 unit, or a whole code point under u.
fn advanceWidth(rex: *const re.Regex, units: []const u16, pos: usize) usize {
    if (!rex.flags.unicode or pos >= units.len) return 1;
    const u = units[pos];
    if (u >= 0xD800 and u <= 0xDBFF and pos + 1 < units.len and
        units[pos + 1] >= 0xDC00 and units[pos + 1] <= 0xDFFF) return 2;
    return 1;
}

/// JS `replaceAll` for a literal needle — `$` escapes still apply, but no
/// capture groups exist, so `$n`/`$<n>` stay literal.
fn applyLiteral(
    alloc: std.mem.Allocator,
    units: []const u16,
    needle: []const u16,
    repl: []const u16,
) Error![]const u8 {
    var out = std.ArrayList(u16).empty;
    var cursor: usize = 0;
    var pos: usize = 0;
    if (needle.len == 0) {
        // Empty search matches at every position, including the ends.
        while (pos <= units.len) : (pos += 1) {
            try out.appendSlice(alloc, units[cursor..pos]);
            const sub = try substLiteral(alloc, repl, units, pos, pos);
            try out.appendSlice(alloc, sub);
            cursor = pos;
        }
        return re.utf16ToUtf8Lossy(alloc, out.items);
    }
    while (pos + needle.len <= units.len) {
        if (std.mem.eql(u16, units[pos .. pos + needle.len], needle)) {
            try out.appendSlice(alloc, units[cursor..pos]);
            const sub = try substLiteral(alloc, repl, units, pos, pos + needle.len);
            try out.appendSlice(alloc, sub);
            pos += needle.len;
            cursor = pos;
        } else {
            pos += 1;
        }
    }
    try out.appendSlice(alloc, units[cursor..]);
    return re.utf16ToUtf8Lossy(alloc, out.items);
}

/// JS GetSubstitution on the replacement string.
fn substitute(
    alloc: std.mem.Allocator,
    repl: []const u16,
    units: []const u16,
    m: re.Match,
    rex: *const re.Regex,
) Error![]const u16 {
    var out = std.ArrayList(u16).empty;
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c != '$' or i + 1 >= repl.len) {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        const n = repl[i + 1];
        switch (n) {
            '$' => {
                try out.append(alloc, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(alloc, units[m.start..m.end]);
                i += 2;
            },
            '`' => {
                try out.appendSlice(alloc, units[0..m.start]);
                i += 2;
            },
            '\'' => {
                try out.appendSlice(alloc, units[m.end..]);
                i += 2;
            },
            '<' => {
                if (rex.names.len == 0) {
                    try out.append(alloc, '$');
                    i += 1;
                    continue;
                }
                const close = std.mem.indexOfScalarPos(u16, repl, i + 2, '>') orelse {
                    try out.append(alloc, '$');
                    i += 1;
                    continue;
                };
                const name = try unitsToUtf8(alloc, repl[i + 2 .. close]);
                if (rex.groupIndex(name)) |g| {
                    if (m.groups[g - 1]) |sp| {
                        try out.appendSlice(alloc, units[sp.start..sp.end]);
                    }
                } else {
                    // Unknown name: literal `$<name>`.
                    try out.appendSlice(alloc, repl[i .. close + 1]);
                }
                i = close + 1;
            },
            '0'...'9' => {
                var digits: [2]u16 = .{ 0, 0 };
                var nd: usize = 0;
                var j = i + 1;
                while (j < repl.len and nd < 2 and repl[j] >= '0' and repl[j] <= '9') : (j += 1) {
                    digits[nd] = repl[j];
                    nd += 1;
                }
                const n2: usize = if (nd == 2)
                    @as(usize, digits[0] - '0') * 10 + (digits[1] - '0')
                else
                    digits[0] - '0';
                var used: usize = 0;
                var group: usize = 0;
                if (n2 >= 1 and n2 <= rex.group_count) {
                    group = n2;
                    used = nd;
                } else if (digits[0] != '0' and digits[0] - '0' <= rex.group_count) {
                    group = digits[0] - '0';
                    used = 1;
                }
                if (group > 0) {
                    if (m.groups[group - 1]) |sp| {
                        try out.appendSlice(alloc, units[sp.start..sp.end]);
                    }
                    i += 1 + used;
                } else {
                    try out.append(alloc, '$');
                    i += 1;
                }
            },
            else => {
                try out.append(alloc, '$');
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Substitution for a literal search: positions span [start,end) of the
/// needle occurrence; there are no capture groups.
fn substLiteral(
    alloc: std.mem.Allocator,
    repl: []const u16,
    units: []const u16,
    start: usize,
    end: usize,
) Error![]const u16 {
    var out = std.ArrayList(u16).empty;
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c != '$' or i + 1 >= repl.len) {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        switch (repl[i + 1]) {
            '$' => {
                try out.append(alloc, '$');
                i += 2;
            },
            '&' => {
                try out.appendSlice(alloc, units[start..end]);
                i += 2;
            },
            '`' => {
                try out.appendSlice(alloc, units[0..start]);
                i += 2;
            },
            '\'' => {
                try out.appendSlice(alloc, units[end..]);
                i += 2;
            },
            else => {
                try out.append(alloc, '$');
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

fn unitsToUtf8(alloc: std.mem.Allocator, units: []const u16) Error![]const u8 {
    return re.utf16ToUtf8Lossy(alloc, units);
}

// --------------------------------------------------------------------
// yaml / yaml_property

fn yamlFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const arg = try filters.paramText(it, call, 0);
    if (call.params.len > 1 or (arg != null and !std.mem.eql(u8, arg.?, "flow"))) {
        return filters.badArg(it, call, "filter 'yaml' accepts only \"flow\"; omit the parameter for block YAML", .{});
    }
    const v = try filters.normalizeInput(it, input);
    var buf = std.ArrayList(u8).empty;
    if (arg != null) {
        try emitFlow(it, &buf, v);
    } else {
        try emitBlockHead(it, &buf, v, 0);
    }
    return it.make(.{ .string = buf.items });
}

fn yamlProperty(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    if (call.params.len != 1) {
        return filters.badArg(it, call, "filter 'yaml_property' requires one non-empty property name (e.g., yaml_property:\"director\")", .{});
    }
    const name = switch (call.params[0]) {
        .value => |e| blk: {
            const v = try it.evalParam(e);
            break :blk try filters.jsToString(it.alloc, v);
        },
        // knap splices a pair parameter back into its raw `a":"b` text.
        .pair => |pr| blk: {
            const k = try filters.jsToString(it.alloc, try it.evalParam(pr.key));
            const v = try filters.jsToString(it.alloc, try it.evalParam(pr.value));
            break :blk try std.fmt.allocPrint(it.alloc, "{s}\":\"{s}", .{ k, v });
        },
        .arrow => return filters.badArg(it, call, "filter 'yaml_property' does not take an arrow argument", .{}),
    };
    if (name.len == 0) {
        return filters.badArg(it, call, "filter 'yaml_property' requires one non-empty property name (e.g., yaml_property:\"director\")", .{});
    }
    const v = try filters.normalizeInput(it, input);
    var buf = std.ArrayList(u8).empty;
    try yamlKey(it, &buf, name);
    try buf.append(it.alloc, ':');
    if (isBlockValue(v)) {
        try buf.append(it.alloc, '\n');
        try emitColl(it, &buf, v, 2, false);
    } else {
        try buf.append(it.alloc, ' ');
        try emitScalar(it, &buf, v);
    }
    return it.make(.{ .string = buf.items });
}

/// Whether the value occupies its own block under a key (non-empty
/// collection) versus sitting inline after `key:`.
fn isBlockValue(v: *const Value) bool {
    return switch (v.*) {
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
        else => false,
    };
}

fn emitScalar(it: *Interp, w: *std.ArrayList(u8), v: *const Value) Error!void {
    switch (v.*) {
        .null => try w.appendSlice(it.alloc, "null"),
        .bool => |b| try w.appendSlice(it.alloc, if (b) "true" else "false"),
        .integer => |i| try w.appendSlice(it.alloc, try std.fmt.allocPrint(it.alloc, "{d}", .{i})),
        .float => |f| try yamlNumber(it, w, f),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch 0;
            try yamlNumber(it, w, f);
        },
        .string => |s| try yamlQuoted(it, w, s),
        .array => |a| if (a.items.len == 0) {
            try w.appendSlice(it.alloc, "[]");
        } else {
            try emitColl(it, w, v, 0, true);
        },
        .object => |o| if (o.count() == 0) {
            try w.appendSlice(it.alloc, "{}");
        } else {
            try emitColl(it, w, v, 0, true);
        },
    }
}

/// Non-finite numbers serialize as quoted strings ("Infinity", "-Infinity",
/// "NaN") since YAML has no literal for them.
fn yamlNumber(it: *Interp, w: *std.ArrayList(u8), f: f64) Error!void {
    const text = try engine.jsFloat(it.alloc, f);
    if (std.math.isNan(f) or std.math.isInf(f)) {
        try yamlQuoted(it, w, text);
    } else {
        try w.appendSlice(it.alloc, text);
    }
}

/// Double-quoted scalar: JSON escapes for `"` `\` and `\b \f \n \r \t`,
/// `\uXXXX` for other C0 controls, the C1 range 0x7F-0x9F, and the unicode
/// line separators U+2028/U+2029. All other text is raw UTF-8.
fn yamlQuoted(it: *Interp, w: *std.ArrayList(u8), s: []const u8) Error!void {
    try w.append(it.alloc, '"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        switch (b) {
            '"' => {
                try w.appendSlice(it.alloc, "\\\"");
                i += 1;
            },
            '\\' => {
                try w.appendSlice(it.alloc, "\\\\");
                i += 1;
            },
            '\n' => {
                try w.appendSlice(it.alloc, "\\n");
                i += 1;
            },
            '\r' => {
                try w.appendSlice(it.alloc, "\\r");
                i += 1;
            },
            '\t' => {
                try w.appendSlice(it.alloc, "\\t");
                i += 1;
            },
            0x08 => {
                try w.appendSlice(it.alloc, "\\b");
                i += 1;
            },
            0x0C => {
                try w.appendSlice(it.alloc, "\\f");
                i += 1;
            },
            else => {
                if (b < 0x20 or b == 0x7F) {
                    try w.appendSlice(it.alloc, try std.fmt.allocPrint(it.alloc, "\\u{x:0>4}", .{b}));
                    i += 1;
                    continue;
                }
                if (b < 0x80) {
                    try w.append(it.alloc, b);
                    i += 1;
                    continue;
                }
                const n = std.unicode.utf8ByteSequenceLength(b) catch {
                    try w.append(it.alloc, b);
                    i += 1;
                    continue;
                };
                if (i + n > s.len) {
                    try w.append(it.alloc, b);
                    i += 1;
                    continue;
                }
                const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
                    try w.append(it.alloc, b);
                    i += 1;
                    continue;
                };
                if ((cp >= 0x80 and cp <= 0x9F) or cp == 0x2028 or cp == 0x2029) {
                    try w.appendSlice(it.alloc, try std.fmt.allocPrint(it.alloc, "\\u{x:0>4}", .{cp}));
                } else {
                    try w.appendSlice(it.alloc, s[i .. i + n]);
                }
                i += n;
            },
        }
    }
    try w.append(it.alloc, '"');
}

const yaml_reserved = [_][]const u8{
    "y", "n", "yes", "no", "on", "off", "true", "false", "null",
};

/// A key stays bare iff it matches `[A-Za-z_][A-Za-z0-9_-]*` and is not a
/// YAML 1.1 boolean/null word (case-insensitive).
fn plainKeySafe(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    var lower: [8]u8 = undefined;
    if (s.len <= lower.len) {
        for (s, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        for (yaml_reserved) |r| {
            if (std.mem.eql(u8, lower[0..s.len], r)) return false;
        }
    }
    return true;
}

fn yamlKey(it: *Interp, w: *std.ArrayList(u8), key: []const u8) Error!void {
    if (plainKeySafe(key)) {
        try w.appendSlice(it.alloc, key);
    } else {
        try yamlQuoted(it, w, key);
    }
}

/// Emit a scalar-or-inline value after a key/dash prefix.
fn emitItemHead(it: *Interp, w: *std.ArrayList(u8), v: *const Value, cont: usize) Error!void {
    if (isBlockValue(v)) {
        try emitColl(it, w, v, cont, true);
    } else {
        try emitScalar(it, w, v);
    }
}

fn emitColl(it: *Interp, w: *std.ArrayList(u8), v: *const Value, indent: usize, head_inline: bool) Error!void {
    switch (v.*) {
        .array => |a| try emitSeq(it, w, a.items, indent, head_inline),
        .object => |o| try emitMapBlk(it, w, o, indent, head_inline),
        else => try emitScalar(it, w, v),
    }
}

fn emitSeq(it: *Interp, w: *std.ArrayList(u8), items: []const Value, indent: usize, head_inline: bool) Error!void {
    for (items, 0..) |*item, i| {
        if (i > 0) try w.append(it.alloc, '\n');
        if (!(head_inline and i == 0)) try w.appendNTimes(it.alloc, ' ', indent);
        try w.appendSlice(it.alloc, "- ");
        try emitItemHead(it, w, item, indent + 2);
    }
}

fn emitMapBlk(it: *Interp, w: *std.ArrayList(u8), obj: std.json.ObjectMap, indent: usize, head_inline: bool) Error!void {
    const keys = try engine.jsObjectKeys(it.alloc, obj);
    var i: usize = 0;
    for (keys) |key| {
        defer i += 1;
        const entry = obj.getPtr(key).?;
        if (i > 0) try w.append(it.alloc, '\n');
        if (!(head_inline and i == 0)) try w.appendNTimes(it.alloc, ' ', indent);
        try emitKey(it, w, key);
        try w.append(it.alloc, ':');
        const val: *const Value = entry;
        if (isBlockValue(val)) {
            try w.append(it.alloc, '\n');
            try emitColl(it, w, val, indent + 2, false);
        } else {
            try w.append(it.alloc, ' ');
            try emitScalar(it, w, val);
        }
    }
}

fn emitKey(it: *Interp, w: *std.ArrayList(u8), key: []const u8) Error!void {
    if (plainKeySafe(key)) {
        try w.appendSlice(it.alloc, key);
    } else {
        try yamlQuoted(it, w, key);
    }
}

fn emitBlockHead(it: *Interp, w: *std.ArrayList(u8), v: *const Value, indent: usize) Error!void {
    // The `+2` cont in emitItemHead is the continuation column for seq
    // members — the collection itself starts at `indent`, or `indent + 2`
    // only when it sits under a `- ` dash (callers handle that case).
    try emitItemHead(it, w, v, indent);
}

/// Flow style: compact JSON shape — `["a","b"]`, `{"k":1}` — with the same
/// quoting as block scalars.
fn emitFlow(it: *Interp, w: *std.ArrayList(u8), v: *const Value) Error!void {
    switch (v.*) {
        .array => |a| {
            try w.append(it.alloc, '[');
            for (a.items, 0..) |*item, i| {
                if (i > 0) try w.append(it.alloc, ',');
                try emitFlow(it, w, item);
            }
            try w.append(it.alloc, ']');
        },
        .object => |o| {
            try w.append(it.alloc, '{');
            const keys = try engine.jsObjectKeys(it.alloc, o);
            for (keys, 0..) |key, i| {
                if (i > 0) try w.append(it.alloc, ',');
                try yamlQuoted(it, w, key);
                try w.append(it.alloc, ':');
                try emitFlow(it, w, o.getPtr(key).?);
            }
            try w.append(it.alloc, '}');
        },
        else => try emitScalar(it, w, v),
    }
}
