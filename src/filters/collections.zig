//! collection ops — knap 0.6.0 filter group.
//!
//! compact, first, join, last, length, merge, nth, object, parse_json,
//! reverse, slice, sort, split, sum, unique, where.
//!
//! Oracle-observed semantics (tools/differential probes):
//! - Strings that hold serialized arrays/objects reparse via
//!   `filters.normalizeInput` before any op (the typed-pipeline contract).
//! - `length`, `slice` and `reverse` work on UTF-16 code units like the
//!   JS host: an astral character is two units, and a cut surrogate pair
//!   re-encodes as U+FFFD.
//! - Bare-word arguments resolve against the data; a word that resolves
//!   (even to null) yields its value, a missing word falls back to its
//!   source text. `join:nullVar` -> "null", `merge:missing` -> "missing".
//! - `merge` is argument marshalling, not concatenation: each arg is
//!   JS-Stringified, a lone arg splits on top-level commas (brackets
//!   protect), and a parenthesized array spreads as stringified elements.
//! - `join` with several params CSV-joins them into the separator —
//!   strings containing whitespace, comma or quote get wrapped in `"`.
//! - `split`'s separator is a regex when it is longer than one char and
//!   carries a magic character or a complete `\X` escape; regex compile
//!   failures are a hard filter error.

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");
const engine = @import("../engine.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;
const eql = std.mem.eql;

pub const names = [_][]const u8{
    "compact",
    "first",
    "join",
    "last",
    "length",
    "merge",
    "nth",
    "object",
    "parse_json",
    "reverse",
    "slice",
    "sort",
    "split",
    "sum",
    "unique",
    "where",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    const name = call.name;
    if (eql(u8, name, "compact")) return compact(it, call, input);
    if (eql(u8, name, "first")) return firstLast(it, input, true);
    if (eql(u8, name, "last")) return firstLast(it, input, false);
    if (eql(u8, name, "length")) return length(it, input);
    if (eql(u8, name, "join")) return join(it, call, input);
    if (eql(u8, name, "merge")) return merge(it, call, input);
    if (eql(u8, name, "nth")) return nth(it, call, input);
    if (eql(u8, name, "object")) return objectFilter(it, call, input);
    if (eql(u8, name, "parse_json")) return parseJson(it, call, input);
    if (eql(u8, name, "reverse")) return reverse(it, input);
    if (eql(u8, name, "slice")) return slice(it, call, input);
    if (eql(u8, name, "sort")) return sort(it, call, input);
    if (eql(u8, name, "split")) return splitFilter(it, call, input);
    if (eql(u8, name, "sum")) return sum(it, call, input);
    if (eql(u8, name, "unique")) return unique(it, input);
    if (eql(u8, name, "where")) return where(it, call, input);
    for (names) |n| {
        if (eql(u8, name, n)) unreachable;
    }
    return null;
}

// --------------------------------------------------------------------
// Shared helpers.

fn makeArray(it: *Interp, items: []Value) Error!*const Value {
    var arr = std.json.Array.init(it.alloc);
    try arr.appendSlice(items);
    return it.make(.{ .array = arr });
}

/// JavaScript `String(v)`: like filters.jsToString but `null` stringifies
/// to "null" — join/merge arguments use ToString, while jsToString models
/// `Array#join` where null/undefined stringify to "".
fn jsString(it: *Interp, v: *const Value) Error![]const u8 {
    if (v.* == .null) return "null";
    return filters.jsToString(it.alloc, v);
}

/// Compact JSON.stringify of `v` (the text collections serialize to).
fn jsonText(it: *Interp, v: *const Value) Error![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(it.alloc);
    try it.jsStringify(v, &buf);
    return buf.written();
}

/// Source text of a path: `a.b[0]` — mirrors the engine's pathText.
fn pathText(it: *Interp, p: parse.Path) Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(it.alloc, p.root);
    for (p.steps) |step| {
        switch (step) {
            .key => |k| {
                try buf.append(it.alloc, '.');
                try buf.appendSlice(it.alloc, k);
            },
            .index => |idx| {
                const t = try std.fmt.allocPrint(it.alloc, "[{d}]", .{idx});
                try buf.appendSlice(it.alloc, t);
            },
            .expr => try buf.appendSlice(it.alloc, "[]"),
        }
    }
    return buf.toOwnedSlice(it.alloc);
}

/// Does `p` bind to anything (even null)? Mirrors the engine's resolvePath
/// lookup order — loop variables, loop scopes, globals, then the data
/// root — answering only existence, because resolvePath itself conflates
/// missing with present-null.
fn pathExists(it: *Interp, p: parse.Path) Error!bool {
    var current: ?*const Value = null;
    var frame_index = it.loops.items.len;
    while (frame_index > 0) {
        frame_index -= 1;
        const frame = &it.loops.items[frame_index];
        if (eql(u8, p.root, "loop")) {
            current = try it.make(.{ .object = .empty });
            break;
        }
        if (eql(u8, p.root, frame.name)) {
            current = &frame.items[frame.index];
            break;
        }
        if (eql(u8, p.root, frame.index_name)) return true;
    }
    if (current == null) {
        var scope_index = it.loops.items.len;
        while (scope_index > 0) {
            scope_index -= 1;
            if (it.loops.items[scope_index].scope.get(p.root)) |v| {
                current = v;
                break;
            }
        }
    }
    if (current == null) {
        if (it.globals.get(p.root)) |v| current = v;
    }
    if (current == null) {
        switch (it.root) {
            .object => |obj| current = obj.getPtr(p.root),
            else => {},
        }
    }
    var value = current orelse return false;
    for (p.steps) |step| {
        switch (step) {
            .key => |k| value = switch (value.*) {
                .object => |obj| obj.getPtr(k) orelse return false,
                else => return false,
            },
            .index => |idx| value = switch (value.*) {
                .array => |arr| if (idx < arr.items.len) &arr.items[@intCast(idx)] else return false,
                else => return false,
            },
            .expr => |pipe| {
                const key = try it.evalPipeline(pipe.*);
                value = switch (key.*) {
                    .string => |k| switch (value.*) {
                        .object => |obj| obj.getPtr(k) orelse return false,
                        .array => |arr| blk: {
                            const idx = std.fmt.parseInt(u64, k, 10) catch return false;
                            break :blk if (idx < arr.items.len) &arr.items[@intCast(idx)] else return false;
                        },
                        else => return false,
                    },
                    .integer => |idx| switch (value.*) {
                        .array => |arr| if (idx >= 0 and idx < arr.items.len) &arr.items[@intCast(idx)] else return false,
                        else => return false,
                    },
                    .float => |f| switch (value.*) {
                        .array => |arr| blk: {
                            if (f < 0 or f != @floor(f) or f >= @as(f64, @floatFromInt(arr.items.len))) return false;
                            break :blk &arr.items[@intFromFloat(f)];
                        },
                        else => return false,
                    },
                    else => return false,
                };
            },
        }
    }
    return true;
}

/// `call.params[i]` evaluated the way the oracle resolves arguments: a bare
/// word that resolves (even to null) yields the value; a missing word
/// falls back to its source text.
fn paramVal(it: *Interp, call: parse.FilterCall, i: usize) Error!?*const Value {
    if (i >= call.params.len) return null;
    const expr = switch (call.params[i]) {
        .value => |e| e,
        else => return filters.badArg(it, call, "filter '{s}' does not take a key:value or arrow argument here", .{call.name}),
    };
    if (expr.terms.len == 1) {
        switch (expr.terms[0].value) {
            .path => |p| {
                if (try pathExists(it, p)) return it.evalExpr(expr.*);
                return it.make(.{ .string = try pathText(it, p) });
            },
            else => {},
        }
    }
    return it.evalExpr(expr.*);
}

/// `call.params[i]` as a JS `String()` of its resolved value.
fn paramStr(it: *Interp, call: parse.FilterCall, i: usize) Error!?[]const u8 {
    const v = (try paramVal(it, call, i)) orelse return null;
    return try jsString(it, v);
}

/// The filter's argument list marshalled to one string: a single arg is its
/// `String()`; several args CSV-join — strings holding whitespace, a comma
/// or a quote get wrapped in `"` (unescaped), non-strings stay bare.
fn argListText(it: *Interp, call: parse.FilterCall) Error!?[]const u8 {
    if (call.params.len == 0) return null;
    if (call.params.len == 1) return try paramStr(it, call, 0);
    var out = std.ArrayList(u8).empty;
    for (call.params, 0..) |prm, i| {
        if (i > 0) try out.append(it.alloc, ',');
        if (prm == .value) {
            const v = (try paramVal(it, call, i)).?;
            const s = try jsString(it, v);
            if (v.* == .string and needsCsvQuote(s)) {
                try out.append(it.alloc, '"');
                try out.appendSlice(it.alloc, s);
                try out.append(it.alloc, '"');
            } else {
                try out.appendSlice(it.alloc, s);
            }
        } else {
            return filters.badArg(it, call, "filter '{s}' does not take a key:value or arrow argument here", .{call.name});
        }
    }
    return try out.toOwnedSlice(it.alloc);
}

fn needsCsvQuote(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', ',', '"' => return true,
            else => {},
        }
    }
    return false;
}

/// A dotted property path resolved inside `v`: each segment reads an object
/// key or, on an array, a numeric index (`a.0` hits `a[0]` and `a["0"]`).
/// Returns null when any segment is missing.
fn dottedLookup(v: *const Value, path: []const u8) ?*const Value {
    var cur = v;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        switch (cur.*) {
            .object => |obj| {
                cur = obj.getPtr(part) orelse return null;
            },
            .array => |arr| {
                const idx = std.fmt.parseInt(usize, part, 10) catch return null;
                if (idx >= arr.items.len) return null;
                cur = &arr.items[idx];
            },
            else => return null,
        }
    }
    return cur;
}

/// Strict-ish equality for `where`: numbers compare across int/float,
/// strings and booleans by value, null to null, containers by serialized
/// bytes.
fn whereEq(it: *Interp, a: *const Value, b: *const Value) Error!bool {
    if (numberOf(a.*)) |an| {
        if (numberOf(b.*)) |bn| return an == bn;
        return false;
    }
    return switch (a.*) {
        .string => |x| b.* == .string and eql(u8, x, b.string),
        .number_string => |x| switch (b.*) {
            .number_string => eql(u8, x, b.number_string),
            .string => |y| eql(u8, x, y),
            else => false,
        },
        .bool => |x| b.* == .bool and x == b.bool,
        .null => b.* == .null,
        .array, .object => eql(u8, try jsonText(it, a), try jsonText(it, b)),
        else => false,
    };
}

fn numberOf(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// `Number(v)` — the oracle's numeric-string coercion: trims whitespace,
/// accepts hex/octal/binary prefixes, Infinity, exponents; blank or
/// malformed strings are not numbers.
fn jsNumber(v: *const Value) ?f64 {
    switch (v.*) {
        .integer => |i| return @floatFromInt(i),
        .float => |f| return f,
        .number_string, .string => {},
        else => return null,
    }
    const raw = switch (v.*) {
        .string => |s| s,
        .number_string => |s| s,
        else => unreachable,
    };
    const s = std.mem.trim(u8, raw, " \t\n\r\x0B\x0C");
    if (s.len == 0) return null;
    var body = s;
    var neg = false;
    if (body[0] == '+' or body[0] == '-') {
        neg = body[0] == '-';
        body = body[1..];
        if (body.len == 0) return null;
    }
    if (eql(u8, body, "Infinity")) return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    if (body.len > 2 and body[0] == '0') {
        const rest = body[2..];
        const n: ?f64 = switch (body[1]) {
            'x', 'X' => parseDigits(rest, 16),
            'o', 'O' => parseDigits(rest, 8),
            'b', 'B' => parseDigits(rest, 2),
            else => null,
        };
        if (n) |val| return if (neg) -val else val;
    }
    const f = std.fmt.parseFloat(f64, s) catch return null;
    return f;
}

fn parseDigits(s: []const u8, base: u8) ?f64 {
    if (s.len == 0) return null;
    var value: f64 = 0;
    for (s) |c| {
        const d = std.fmt.charToDigit(c, base) catch return null;
        value = value * @as(f64, base) + d;
    }
    return value;
}

// UTF-16 code-unit helpers: the oracle's string ops run on JS strings.

fn toUnits(it: *Interp, s: []const u8) Error![]u16 {
    var units = std.ArrayList(u16).empty;
    var view = std.unicode.Utf8View.initUnchecked(s);
    var i = view.iterator();
    while (i.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            try units.append(it.alloc, @intCast(cp));
        } else {
            const u = cp - 0x10000;
            try units.append(it.alloc, @intCast(0xD800 + (u >> 10)));
            try units.append(it.alloc, @intCast(0xDC00 + (u & 0x3FF)));
        }
    }
    return units.toOwnedSlice(it.alloc);
}

/// UTF-16 units back to UTF-8; an unpaired surrogate becomes U+FFFD —
/// exactly what the oracle emits when a slice/reverse splits a pair.
fn fromUnits(it: *Interp, units: []const u16) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < units.len) {
        const u = units[i];
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len and
            units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF)
        {
            const cp: u21 = 0x10000 + (@as(u21, u - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(it.alloc, buf[0..n]);
            i += 2;
            continue;
        }
        const cp: u21 = if (u >= 0xD800 and u <= 0xDFFF) 0xFFFD else u;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(it.alloc, buf[0..n]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn toTextScalar(it: *Interp, v: *const Value) Error![]const u8 {
    return (try filters.scalarText(it.alloc, v.*)) orelse try jsonText(it, v);
}

// --------------------------------------------------------------------
// The filters.

/// Drop null and empty/whitespace-only string members — shallowly (nested
/// collections are preserved untouched). Non-collections pass through.
fn compact(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    _ = call;
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .array => |arr| {
            var items = std.ArrayList(Value).empty;
            for (arr.items) |*item| {
                if (!emptyish(item.*)) try items.append(it.alloc, item.*);
            }
            return makeArray(it, items.items);
        },
        .object => |obj| {
            var map: std.json.ObjectMap = .empty;
            try map.ensureTotalCapacity(it.alloc, obj.count());
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!emptyish(entry.value_ptr.*)) {
                    map.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            return it.make(.{ .object = map });
        },
        else => return v,
    }
}

fn emptyish(v: Value) bool {
    return switch (v) {
        .null => true,
        .string, .number_string => |s| std.mem.trim(u8, s, " \t\r\n").len == 0,
        else => false,
    };
}

fn firstLast(it: *Interp, input: *const Value, first: bool) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    return switch (v.*) {
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk it.make(.{ .null = {} });
            const item = if (first) arr.items[0] else arr.items[arr.items.len - 1];
            break :blk it.make(item);
        },
        else => v,
    };
}

/// String length in UTF-16 code units, array item count, or object key
/// count; scalars count their `String()` form, null/missing count 0.
fn length(it: *Interp, input: *const Value) Error!*const Value {
    const v = try filters.reparseCollection(it, input);
    const n: usize = switch (v.*) {
        .array => |arr| arr.items.len,
        .object => |obj| obj.count(),
        .null => 0,
        else => blk: {
            const s = try toTextScalar(it, v);
            break :blk (try toUnits(it, s)).len;
        },
    };
    return it.make(.{ .integer = @intCast(n) });
}

fn join(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    const sep = (try argListText(it, call)) orelse ",";
    return switch (v.*) {
        .array => |arr| blk: {
            var out = std.ArrayList(u8).empty;
            for (arr.items, 0..) |*item, i| {
                if (i > 0) try out.appendSlice(it.alloc, sep);
                // JS Array#join: null/undefined elements stringify to "".
                if (item.* == .null) continue;
                try out.appendSlice(it.alloc, try filters.jsToString(it.alloc, item));
            }
            break :blk it.make(.{ .string = out.items });
        },
        else => v,
    };
}

/// Append arguments to an array. A lone argument is `String()`-ified and
/// split on top-level commas (pieces trimmed; `[](){}` pairs protect);
/// several arguments append whole, except arrays which spread their
/// stringified elements. Null input discards the arguments entirely.
fn merge(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    if (v.* == .null) return makeArray(it, &.{});
    var items = std.ArrayList(Value).empty;
    switch (v.*) {
        .array => |arr| try items.appendSlice(it.alloc, arr.items),
        else => try items.append(it.alloc, .{ .string = try toTextScalar(it, v) }),
    }
    if (call.params.len == 1) {
        const s = try jsString(it, (try paramVal(it, call, 0)).?);
        const pieces = try splitTopCommas(it, s);
        for (pieces) |piece| {
            try items.append(it.alloc, .{ .string = piece });
        }
    } else {
        for (call.params, 0..) |_, i| {
            const pv = try paramVal(it, call, i);
            if (pv.?.* == .array) {
                for (pv.?.array.items) |*elem| {
                    try items.append(it.alloc, .{ .string = try filters.jsToString(it.alloc, elem) });
                }
            } else {
                try items.append(it.alloc, .{ .string = try jsString(it, pv.?) });
            }
        }
    }
    return makeArray(it, items.items);
}

/// Split `s` on commas outside `[]()` `{}` groups; when a top-level comma
/// exists the pieces are trimmed, otherwise the string passes whole.
fn splitTopCommas(it: *Interp, s: []const u8) Error![]const []const u8 {
    var pieces = std.ArrayList([]const u8).empty;
    var depth: usize = 0;
    var start: usize = 0;
    var has = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '[', '(', '{' => depth += 1,
            ']', ')', '}' => depth -|= 1,
            ',' => {
                if (depth == 0) {
                    has = true;
                    try pieces.append(it.alloc, s[start..i]);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    try pieces.append(it.alloc, s[start..]);
    if (!has) return pieces.items;
    for (pieces.items) |*piece| {
        piece.* = std.mem.trim(u8, piece.*, " \t\r\n");
    }
    return pieces.items;
}

/// `nth` pattern grammar: `k`, `kn`, `n+k`, `p[,p]*:g`. Bare-token digits
/// arrive as integer literals; `kn`/`n+k` arrive as bare-token strings.
/// A quoted argument is never a valid pattern (oracle-observed).
fn nth(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    if (input.* == .string and input.string.len > 0 and !filters.jsonParses(it, input.string))
        try filters.warnInput(it, call, "Could not parse value as a JSON array", .{});
    if (call.params.len == 0) return v;
    if (v.* != .array) return v;

    var positions = std.ArrayList(usize).empty;
    var group: ?usize = null;
    var every: ?usize = null;
    var offset: ?usize = null;
    var saw_string = false;
    for (call.params) |prm| {
        switch (prm) {
            .value => |expr| {
                const val = try it.evalExpr(expr.*);
                switch (val.*) {
                    .integer => |n| {
                        if (n < 0 or saw_string) return nthArgsErr(it, call);
                        try positions.append(it.alloc, @intCast(n));
                    },
                    .float => |f| {
                        if (f != @floor(f) or f < 0 or saw_string) return nthArgsErr(it, call);
                        try positions.append(it.alloc, @intFromFloat(f));
                    },
                    .string, .number_string => |s| {
                        // Pattern strings are bare tokens only — a quoted
                        // `nth:"2n"` is rejected by the oracle.
                        if (call.params.len > 1 or positions.items.len > 0 or
                            saw_string or nthArgQuoted(it, call)) return nthArgsErr(it, call);
                        saw_string = true;
                        try parseNthPattern(it, call, s, &every, &offset);
                    },
                    else => return nthArgsErr(it, call),
                }
            },
            .pair => |pair| {
                const k = try it.evalExpr(pair.key.*);
                const g = try it.evalExpr(pair.value.*);
                const ki = nthInt(k.*) orelse return nthArgsErr(it, call);
                const gi = nthInt(g.*) orelse return nthArgsErr(it, call);
                if (ki == 0 or gi == 0) return nthArgsErr(it, call);
                try positions.append(it.alloc, ki);
                group = gi;
            },
            .arrow => return nthArgsErr(it, call),
        }
    }
    if (positions.items.len > 1 and group == null) return nthArgsErr(it, call);
    if (group != null) {
        for (positions.items) |p| {
            if (p == 0) return nthArgsErr(it, call);
        }
    }
    if (positions.items.len == 0 and every == null and offset == null) {
        return nthArgsErr(it, call);
    }

    const arr = v.array;
    var out = std.ArrayList(Value).empty;
    for (arr.items, 0..) |*item, i| {
        const pos = i + 1;
        var take = false;
        if (every) |e| {
            take = e > 0 and pos % e == 0;
        } else if (offset) |o| {
            take = pos >= o;
        } else if (group) |g| {
            const within = (pos - 1) % g + 1;
            for (positions.items) |p| {
                if (within == p) {
                    take = true;
                    break;
                }
            }
        } else {
            for (positions.items) |p| {
                if (pos == p) {
                    take = true;
                    break;
                }
            }
        }
        if (take) try out.append(it.alloc, item.*);
    }
    return makeArray(it, out.items);
}

fn nthInt(v: Value) ?usize {
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f == @floor(f) and f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

/// Does the template source after `name:` start with a quote? Used to keep
/// `nth:2n` (bare) and `nth:"2n"` (quoted) distinct — the AST cannot.
fn nthArgQuoted(it: *Interp, call: parse.FilterCall) bool {
    var i = call.offset + call.name.len;
    while (i < it.template.len and (it.template[i] == ' ' or it.template[i] == '\t')) i += 1;
    if (i < it.template.len and it.template[i] == ':') {
        i += 1;
        while (i < it.template.len and (it.template[i] == ' ' or it.template[i] == '\t')) i += 1;
    }
    return i < it.template.len and (it.template[i] == '"' or it.template[i] == '\'');
}

fn parseNthPattern(
    it: *Interp,
    call: parse.FilterCall,
    s: []const u8,
    every: *?usize,
    offset: *?usize,
) Error!void {
    if (s.len >= 2 and s[s.len - 1] == 'n') {
        const n = std.fmt.parseInt(usize, s[0 .. s.len - 1], 10) catch
            return nthArgsErr(it, call);
        every.* = n;
        return;
    }
    if (s.len >= 3 and s[0] == 'n' and s[1] == '+') {
        const n = std.fmt.parseInt(usize, s[2..], 10) catch
            return nthArgsErr(it, call);
        offset.* = n;
        return;
    }
    return nthArgsErr(it, call);
}

fn nthArgsErr(it: *Interp, call: parse.FilterCall) error{Template} {
    return filters.badArg(it, call, "filter 'nth' invalid syntax. Use number (2), multiplier (5n), offset (n+7), or basis (1,2:5)", .{});
}

/// `object:"keys"|"values"|"array"` — an object maps to its parts; an
/// array's keys are its indices as strings.
fn objectFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    const mode = (try argListText(it, call)) orelse
        return filters.badArg(it, call, "filter 'object' requires a parameter: \"array\", \"keys\", or \"values\"", .{});
    const m: enum { keys, values, array } = blk: {
        if (eql(u8, mode, "keys")) break :blk .keys;
        if (eql(u8, mode, "values")) break :blk .values;
        if (eql(u8, mode, "array")) break :blk .array;
        return filters.badArg(it, call, "filter 'object' invalid parameter \"{s}\". Use \"array\", \"keys\", or \"values\"", .{mode});
    };
    var items = std.ArrayList(Value).empty;
    switch (v.*) {
        .object => |obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                switch (m) {
                    .keys => try items.append(it.alloc, .{ .string = entry.key_ptr.* }),
                    .values => try items.append(it.alloc, entry.value_ptr.*),
                    .array => {
                        const pair = try it.alloc.alloc(Value, 2);
                        pair[0] = .{ .string = entry.key_ptr.* };
                        pair[1] = entry.value_ptr.*;
                        var arr = std.json.Array.init(it.alloc);
                        try arr.appendSlice(pair);
                        try items.append(it.alloc, .{ .array = arr });
                    },
                }
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |*item, i| {
                const key = try std.fmt.allocPrint(it.alloc, "{d}", .{i});
                switch (m) {
                    .keys => try items.append(it.alloc, .{ .string = key }),
                    .values => try items.append(it.alloc, item.*),
                    .array => {
                        const pair = try it.alloc.alloc(Value, 2);
                        pair[0] = .{ .string = key };
                        pair[1] = item.*;
                        var parr = std.json.Array.init(it.alloc);
                        try parr.appendSlice(pair);
                        try items.append(it.alloc, .{ .array = parr });
                    },
                }
            }
        },
        else => {
            const unparsed = switch (v.*) {
                .string => |s| !filters.jsonParses(it, s),
                else => filters.isNullish(v),
            };
            if (unparsed) try filters.warnInput(it, call, "Could not parse value as JSON", .{});
            return v;
        },
    }
    return makeArray(it, items.items);
}

/// JSON text re-parsed into a typed value; anything that does not parse —
/// and any non-string input — passes through unchanged. A string that
/// fails to parse earns the oracle's non-fatal warning.
fn parseJson(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    switch (input.*) {
        .string, .number_string => |s| {
            const parsed = std.json.parseFromSliceLeaky(Value, it.alloc, s, .{}) catch {
                try filters.warnInput(it, call, "Could not parse value as JSON", .{});
                return input;
            };
            return it.make(parsed);
        },
        else => return input,
    }
}

fn reverse(it: *Interp, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .string, .number_string => |s| {
            const units = try toUnits(it, s);
            std.mem.reverse(u16, units);
            return it.make(.{ .string = try fromUnits(it, units) });
        },
        .array => |arr| {
            const items = try it.alloc.alloc(Value, arr.items.len);
            for (arr.items, 0..) |*item, i| {
                items[arr.items.len - 1 - i] = item.*;
            }
            return makeArray(it, items);
        },
        .object => |obj| {
            var map: std.json.ObjectMap = .empty;
            const keys = obj.keys();
            try map.ensureTotalCapacity(it.alloc, obj.count());
            var i = keys.len;
            while (i > 0) {
                i -= 1;
                map.putAssumeCapacity(keys[i], obj.get(keys[i]).?);
            }
            return it.make(.{ .object = map });
        },
        else => return v,
    }
}

/// JS `slice` on an array, or on the text form of anything else (objects
/// slice their compact JSON). String slicing runs on UTF-16 units.
fn slice(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    if (call.params.len == 0) {
        return filters.badArg(it, call, "filter 'slice' requires at least a start index (e.g., slice:0,5)", .{});
    }
    if (call.params.len > 2) {
        return filters.badArg(it, call, "filter 'slice' accepts at most 2 parameters: start and end", .{});
    }
    const start = try sliceIndex(it, call, 0);
    const end = try sliceIndex(it, call, 1);
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .array => |arr| {
            const span = sliceRange(start, end, arr.items.len);
            var items = std.ArrayList(Value).empty;
            try items.appendSlice(it.alloc, arr.items[span[0]..span[1]]);
            return makeArray(it, items.items);
        },
        .null => return v,
        else => {
            if (v.* == .string and v.string.len > 0 and (v.string[0] == '[' or v.string[0] == '{'))
                try filters.warnInput(it, call, "Could not parse structured value as JSON", .{});
            const s = try toTextScalar(it, v);
            const units = try toUnits(it, s);
            const span = sliceRange(start, end, units.len);
            return it.make(.{ .string = try fromUnits(it, units[span[0]..span[1]]) });
        },
    }
}

fn sliceIndex(it: *Interp, call: parse.FilterCall, i: usize) Error!?i64 {
    const v = (try paramVal(it, call, i)) orelse return null;
    const f: f64 = switch (v.*) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => jsNumber(v) orelse
            return filters.badArg(it, call, "filter 'slice' \"{s}\" is not a valid number", .{try jsString(it, v)}),
    };
    return @intFromFloat(@trunc(f));
}

fn sliceRange(start_in: ?i64, end_in: ?i64, len: usize) [2]usize {
    const l: i64 = @intCast(len);
    var start: i64 = start_in orelse 0;
    var end: i64 = end_in orelse l;
    if (start < 0) start = @max(l + start, 0) else start = @min(start, l);
    if (end < 0) end = @max(l + end, 0) else end = @min(end, l);
    if (end < start) end = start;
    return .{ @intCast(start), @intCast(end) };
}

/// Stable sort. Both operands numeric compares numerically; anything else
/// compares sort keys — a string's raw text, a non-string's compact JSON —
/// with null/missing sorted to the end. `desc` flips the comparison only.
fn sort(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    if (v.* != .array) return v;
    if (call.params.len > 2) {
        return filters.badArg(it, call, "filter 'sort' accepts at most a property and direction", .{});
    }
    var prop: ?[]const u8 = null;
    var desc = false;
    if (call.params.len == 1) {
        const a = (try paramStr(it, call, 0)).?;
        if (eql(u8, a, "desc")) {
            desc = true;
        } else if (!eql(u8, a, "asc")) {
            prop = a;
        }
    } else if (call.params.len == 2) {
        prop = (try paramStr(it, call, 0)).?;
        const d = (try paramStr(it, call, 1)).?;
        if (eql(u8, d, "desc")) {
            desc = true;
        } else if (!eql(u8, d, "asc")) {
            return filters.badArg(it, call, "filter 'sort' invalid direction \"{s}\". Use \"asc\" or \"desc\"", .{d});
        }
    }

    var keys = try it.alloc.alloc([]const u8, v.array.items.len);
    var nums = try it.alloc.alloc(?f64, v.array.items.len);
    var nulls = try it.alloc.alloc(bool, v.array.items.len);
    for (v.array.items, 0..) |*item, i| {
        const sv = if (prop) |p| dottedLookup(item, p) orelse null else item;
        if (sv == null) {
            keys[i] = "";
            nums[i] = null;
            nulls[i] = true;
            continue;
        }
        const svv: *const Value = if (prop != null) sv.? else item;
        if (svv.* == .null) {
            keys[i] = "";
            nums[i] = null;
            nulls[i] = true;
            continue;
        }
        nums[i] = numberOf(svv.*);
        keys[i] = if (svv.* == .string) svv.string else try jsonText(it, svv);
        nulls[i] = false;
    }

    const Ctx = struct {
        keys: []const []const u8,
        nums: []const ?f64,
        nulls: []const bool,
        desc: bool,
    };
    const ctx = Ctx{ .keys = keys, .nums = nums, .nulls = nulls, .desc = desc };
    const items = v.array.items;
    const order = try it.alloc.alloc(usize, items.len);
    for (order, 0..) |*o, i| o.* = i;
    std.sort.block(usize, order, ctx, struct {
        fn lessThan(c: Ctx, ai: usize, bi: usize) bool {
            if (c.nulls[ai] != c.nulls[bi]) return !c.nulls[ai] and !c.desc or c.nulls[ai] and c.desc;
            if (c.nulls[ai]) return false;
            const na = c.nums[ai];
            const nb = c.nums[bi];
            var ord: std.math.Order = undefined;
            if (na != null and nb != null) {
                ord = std.math.order(na.?, nb.?);
            } else {
                ord = std.mem.order(u8, c.keys[ai], c.keys[bi]);
            }
            return if (c.desc) ord == .gt else ord == .lt;
        }
    }.lessThan);
    var items2 = try it.alloc.alloc(Value, items.len);
    for (order, 0..) |src, i| items2[i] = items[src];
    return makeArray(it, items2);
}

/// Split a string into a JSON array. No separator (or an empty one) splits
/// into UTF-16 code units; a multi-char separator with regex syntax
/// compiles as a regular expression (capture groups interleave into the
/// output, compile errors raise a filter error); anything else is literal.
fn splitFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    const text: []const u8 = switch (v.*) {
        .null => "",
        else => try toTextScalar(it, v),
    };
    const sep = try argListText(it, call);
    var pieces = std.ArrayList(Value).empty;
    if (sep == null or sep.?.len == 0) {
        // Empty separator: UTF-16 code units.
        const units = try toUnits(it, text);
        for (units, 0..) |_, i| {
            try pieces.append(it.alloc, .{ .string = try fromUnits(it, units[i..][0..1]) });
        }
        return makeArray(it, pieces.items);
    }
    if (isRegexy(sep.?)) {
        const units = try toUnits(it, text);
        var rx = compileRegex(it.alloc, sep.?) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRegex => return filters.failAt(it, call.offset, "filter 'split' failed: invalid regular expression /{s}/", .{sep.?}),
        };
        try regexSplit(it, &rx, units, &pieces);
    } else {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, text, start, sep.?)) |at| {
            try pieces.append(it.alloc, .{ .string = text[start..at] });
            start = at + sep.?.len;
        }
        try pieces.append(it.alloc, .{ .string = text[start..] });
    }
    return makeArray(it, pieces.items);
}

/// The separator compiles as a regex when it is longer than one unit and
/// carries a magic character, or holds a complete `\X` escape (a trailing
/// backslash alone stays literal — oracle-observed).
fn isRegexy(sep: []const u8) bool {
    if (sep.len < 2) return false;
    for (sep, 0..) |c, i| {
        switch (c) {
            '.', '^', '$', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}' => return true,
            '\\' => if (i + 1 < sep.len) return true,
            else => {},
        }
    }
    return false;
}

/// Sum numeric items (or a property path of object items). `Number()`
/// coercion: finite numbers and nonblank numeric strings count, everything
/// else is ignored. Non-arrays pass through.
fn sum(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    if (call.params.len > 1) {
        return filters.badArg(it, call, "filter 'sum' accepts at most one property path", .{});
    }
    const prop = try paramStr(it, call, 0);
    if (v.* != .array) return v;
    var total: f64 = 0;
    for (v.array.items) |*item| {
        const target = if (prop) |p| dottedLookup(item, p) orelse continue else item;
        if (jsNumber(target)) |n| {
            if (std.math.isFinite(n)) total += n;
        }
    }
    return it.make(.{ .float = total });
}

/// Drop duplicate members. Array items dedupe by their compact JSON text
/// (first occurrence kept); object values dedupe the same way, keeping the
/// LAST key of each distinct value.
fn unique(it: *Interp, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .array => |arr| {
            var seen = std.StringHashMap(void).init(it.alloc);
            var items = std.ArrayList(Value).empty;
            for (arr.items) |*item| {
                const key = try jsonText(it, item);
                if (!seen.contains(key)) {
                    try seen.put(key, {});
                    try items.append(it.alloc, item.*);
                }
            }
            return makeArray(it, items.items);
        },
        .object => |obj| {
            // For each value-serialization keep its LAST key; emit the
            // survivors in order of those last occurrences.
            var last_key: std.StringArrayHashMapUnmanaged(usize) = .empty;
            var keys = std.ArrayList([]const u8).empty;
            var serials = std.ArrayList([]const u8).empty;
            var iter = obj.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| : (i += 1) {
                const serial = try jsonText(it, entry.value_ptr);
                try keys.append(it.alloc, entry.key_ptr.*);
                try serials.append(it.alloc, serial);
                try last_key.put(it.alloc, serial, i);
            }
            var map: std.json.ObjectMap = .empty;
            for (keys.items, 0..) |k, j| {
                if (last_key.get(serials.items[j]).? == j) {
                    try map.put(it.alloc, k, obj.get(k).?);
                }
            }
            return it.make(.{ .object = map });
        },
        else => return v,
    }
}

/// Keep items whose property `path` strictly equals `value`. A bare-word
/// property argument resolves against the data: a resolved string is the
/// path; a resolved non-string tries `String(v)` AND the literal word;
/// a missing word is just its text (oracle-observed).
fn where(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    if (call.params.len == 0 or call.params.len == 1) {
        return filters.badArg(it, call, "filter 'where' requires a property path and value", .{});
    }
    if (call.params.len != 2 or call.params[0] != .value or call.params[1] != .value) {
        return filters.badArg(it, call, "filter 'where' requires exactly a property path and value", .{});
    }
    if (v.* != .array) return v;

    const target = (try paramVal(it, call, 1)).?;

    // Candidate property paths for the first argument.
    var candidates = std.ArrayList([]const u8).empty;
    const expr = call.params[0].value;
    var handled = false;
    if (expr.terms.len == 1) {
        switch (expr.terms[0].value) {
            .path => |p| {
                handled = true;
                const resolved = try it.evalExpr(expr.*);
                if (resolved.* == .string) {
                    try candidates.append(it.alloc, resolved.string);
                } else if (try pathExists(it, p)) {
                    try candidates.append(it.alloc, try jsString(it, resolved));
                    try candidates.append(it.alloc, try pathText(it, p));
                } else {
                    try candidates.append(it.alloc, try pathText(it, p));
                }
            },
            else => {},
        }
    }
    if (!handled) {
        const pv = try it.evalExpr(expr.*);
        try candidates.append(it.alloc, try jsString(it, pv));
    }

    var out = std.ArrayList(Value).empty;
    for (v.array.items) |*item| {
        for (candidates.items) |path| {
            const got = dottedLookup(item, path) orelse continue;
            if (try whereEq(it, got, target)) {
                try out.append(it.alloc, item.*);
                break;
            }
        }
    }
    return makeArray(it, out.items);
}

// --------------------------------------------------------------------
// Minimal backtracking regex for `split` — works on UTF-16 code units like
// the JS host. Supports literals, '.', character classes (\d \D \w \W \s
// \S inside and out), anchors (^ $ \b \B), escapes (\xHH \uHHHH identity
// escapes), groups (), alternation |, and quantifiers * + ? {n} {n,} {n,m}
// with lazy ? variants.

const RxError = error{ InvalidRegex, OutOfMemory };

const RxInsn = union(enum) {
    char: u16,
    any, // '.' — not a line terminator
    cls: usize,
    save: usize,
    jmp: usize,
    fork: usize, // try pc+1 first, fall back to the target
    fork_lazy: usize, // try the target first, fall back to pc+1
    bol,
    eol,
    wordb,
    nwordb,
    match,
};

const RxClass = struct {
    negated: bool,
    ranges: []const [2]u16,
};

const Regex = struct {
    insns: []const RxInsn,
    classes: []const RxClass,
    ncap: usize,
};

const RxNode = union(enum) {
    empty,
    char: u16,
    any, // '.' — not a line terminator
    cls: usize,
    group: struct { index: usize, node: *const RxNode },
    cat: []const RxNode,
    alt: []const RxNode,
    rep: struct { node: *const RxNode, min: usize, max: ?usize, lazy: bool },
    bol,
    eol,
    wordb,
    nwordb,
};

const RxParser = struct {
    alloc: std.mem.Allocator,
    pat: []const u16,
    pos: usize = 0,
    classes: std.ArrayList(RxClass) = .empty,
    ncap: usize = 0,

    fn peek(s: *RxParser) ?u16 {
        if (s.pos >= s.pat.len) return null;
        return s.pat[s.pos];
    }

    fn peekAt(s: *RxParser, k: usize) ?u16 {
        if (s.pos + k >= s.pat.len) return null;
        return s.pat[s.pos + k];
    }

    fn node(s: *RxParser, n: RxNode) RxError!*const RxNode {
        const p = try s.alloc.create(RxNode);
        p.* = n;
        return p;
    }

    fn parseAlt(s: *RxParser) RxError!*const RxNode {
        var branches = std.ArrayList(RxNode).empty;
        while (true) {
            try branches.append(s.alloc, (try s.parseCat()).*);
            if (s.peek() == null or s.peek().? != '|') break;
            s.pos += 1;
        }
        if (branches.items.len == 1) return s.node(branches.items[0]);
        return s.node(.{ .alt = branches.items });
    }

    fn parseCat(s: *RxParser) RxError!*const RxNode {
        var nodes = std.ArrayList(RxNode).empty;
        while (s.peek()) |c| {
            if (c == '|' or c == ')') break;
            try nodes.append(s.alloc, (try s.parseRep()).*);
        }
        if (nodes.items.len == 0) return s.node(.empty);
        if (nodes.items.len == 1) return s.node(nodes.items[0]);
        return s.node(.{ .cat = nodes.items });
    }

    fn parseRep(s: *RxParser) RxError!*const RxNode {
        var n = try s.parseAtom();
        while (s.peek()) |c| {
            if (c != '*' and c != '+' and c != '?' and c != '{') break;
            var min: usize = 0;
            var max: ?usize = null;
            if (c == '*') {
                s.pos += 1;
                min = 0;
            } else if (c == '+') {
                s.pos += 1;
                min = 1;
            } else if (c == '?') {
                s.pos += 1;
                min = 0;
                max = 1;
            } else {
                // {n} {n,} {n,m}; a malformed brace is a literal char.
                const save = s.pos;
                s.pos += 1;
                const lo = s.takeUint();
                var ok = lo != null;
                var hi: ?usize = lo;
                if (ok and s.peek() != null and s.peek().? == ',') {
                    s.pos += 1;
                    if (s.peek() != null and s.peek().? == '}') {
                        hi = null;
                    } else {
                        hi = s.takeUint();
                        if (hi == null) ok = false;
                    }
                }
                if (ok and (s.peek() == null or s.peek().? != '}')) ok = false;
                if (!ok) {
                    s.pos = save;
                    break;
                }
                s.pos += 1;
                min = lo.?;
                max = hi;
                if (max != null and max.? < min) return error.InvalidRegex;
            }
            var lazy = false;
            if (s.peek() != null and s.peek().? == '?') {
                s.pos += 1;
                lazy = true;
            }
            if (n.* == .empty) return error.InvalidRegex; // nothing to repeat
            if (max != null and max.? == 0) {
                n = try s.node(.empty);
                continue;
            }
            const rep = RxNode{ .rep = .{ .node = n, .min = min, .max = max, .lazy = lazy } };
            n = try s.node(rep);
        }
        return n;
    }

    fn takeUint(s: *RxParser) ?usize {
        var n: usize = 0;
        var digits: usize = 0;
        while (s.peek()) |c| {
            if (c < '0' or c > '9') break;
            n = n * 10 + (c - '0');
            digits += 1;
            s.pos += 1;
        }
        return if (digits == 0) null else n;
    }

    fn parseAtom(s: *RxParser) RxError!*const RxNode {
        const c = s.peek() orelse return error.InvalidRegex;
        switch (c) {
            '(' => {
                s.pos += 1;
                var cap: ?usize = null;
                if (s.peek() != null and s.peek().? == '?') {
                    s.pos += 1;
                    if (s.peek() == null or s.peek().? != ':') return error.InvalidRegex;
                    s.pos += 1;
                } else {
                    s.ncap += 1;
                    cap = s.ncap;
                }
                const inner = try s.parseAlt();
                if (s.peek() == null or s.peek().? != ')') return error.InvalidRegex;
                s.pos += 1;
                if (cap) |g| return s.node(.{ .group = .{ .index = g, .node = inner } });
                return inner;
            },
            '[' => {
                s.pos += 1;
                return s.parseClass();
            },
            '.' => {
                s.pos += 1;
                return s.node(.any);
            },
            '^' => {
                s.pos += 1;
                return s.node(.bol);
            },
            '$' => {
                s.pos += 1;
                return s.node(.eol);
            },
            '\\' => {
                s.pos += 1;
                return s.parseEscape();
            },
            '*', '+', '?', '|', ')' => return error.InvalidRegex,
            else => {
                s.pos += 1;
                return s.node(.{ .char = c });
            },
        }
    }

    fn parseClass(s: *RxParser) RxError!*const RxNode {
        var ranges = std.ArrayList([2]u16).empty;
        var negated = false;
        if (s.peek() != null and s.peek().? == '^') {
            negated = true;
            s.pos += 1;
        }
        var first = true;
        while (true) {
            const c = s.peek() orelse return error.InvalidRegex;
            if (c == ']' and !first) {
                s.pos += 1;
                break;
            }
            first = false;
            var lo: u16 = undefined;
            if (c == '\\') {
                s.pos += 1;
                const e = s.peek() orelse return error.InvalidRegex;
                s.pos += 1;
                if (classEscapeRanges(e)) |rs| {
                    for (rs) |r| try ranges.append(s.alloc, r);
                    continue;
                }
                lo = try s.escapeValue(e);
            } else {
                s.pos += 1;
                lo = c;
            }
            if (s.peek() != null and s.peek().? == '-' and
                s.peekAt(1) != null and s.peekAt(1).? != ']')
            {
                s.pos += 1;
                var hi: u16 = undefined;
                if (s.peek().? == '\\') {
                    s.pos += 1;
                    const e = s.peek() orelse return error.InvalidRegex;
                    s.pos += 1;
                    hi = try s.escapeValue(e);
                } else {
                    hi = s.peek().?;
                    s.pos += 1;
                }
                if (lo > hi) return error.InvalidRegex;
                try ranges.append(s.alloc, .{ lo, hi });
            } else {
                try ranges.append(s.alloc, .{ lo, lo });
            }
        }
        const idx = s.classes.items.len;
        try s.classes.append(s.alloc, .{ .negated = negated, .ranges = ranges.items });
        return s.node(.{ .cls = idx });
    }

    fn escapeValue(s: *RxParser, c: u16) RxError!u16 {
        switch (c) {
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'f' => return 0x0C,
            'v' => return 0x0B,
            '0' => return 0,
            'x', 'u' => {
                s.pos -= 1;
                const ch = (try s.hexEscape()) orelse return c;
                return ch;
            },
            else => return c,
        }
    }

    /// At an 'x' or 'u': \xHH, \uHHHH, \u{...}; a malformed form yields
    /// null and the caller treats the letter literally.
    fn hexEscape(s: *RxParser) RxError!?u16 {
        const c = s.peek().?;
        s.pos += 1;
        var digits: usize = if (c == 'x') 2 else 4;
        if (c == 'u' and s.peek() != null and s.peek().? == '{') {
            s.pos += 1;
            var v: u32 = 0;
            var n: usize = 0;
            while (s.peek() != null and s.peek().? != '}') {
                const h = hexVal(s.peek().?) orelse return error.InvalidRegex;
                v = v * 16 + h;
                if (v > 0xFFFF) return error.InvalidRegex;
                n += 1;
                s.pos += 1;
            }
            if (s.peek() == null or n == 0) return error.InvalidRegex;
            s.pos += 1;
            return @intCast(v);
        }
        var v: u16 = 0;
        var n: usize = 0;
        while (n < digits and s.peek() != null and hexVal(s.peek().?) != null) : (n += 1) {
            v = v * 16 + hexVal(s.peek().?).?;
            s.pos += 1;
        }
        _ = &digits;
        if (n == 0) return null;
        return v;
    }

    fn parseEscape(s: *RxParser) RxError!*const RxNode {
        const c = s.peek() orelse return error.InvalidRegex;
        s.pos += 1;
        if (classEscapeRanges(c)) |rs| {
            const idx = s.classes.items.len;
            try s.classes.append(s.alloc, .{
                .negated = c == 'D' or c == 'W' or c == 'S',
                .ranges = rs,
            });
            return s.node(.{ .cls = idx });
        }
        switch (c) {
            'b' => return s.node(.wordb),
            'B' => return s.node(.nwordb),
            'x', 'u' => {
                s.pos -= 1;
                if (try s.hexEscape()) |ch| return s.node(.{ .char = ch });
                s.pos += 1;
                return s.node(.{ .char = c });
            },
            '1'...'9' => return error.InvalidRegex, // backrefs unsupported
            else => return s.node(.{ .char = try s.escapeValue(c) }),
        }
    }
};

fn classEscapeRanges(c: u16) ?[]const [2]u16 {
    const digits = [_][2]u16{.{ '0', '9' }};
    const word = [_][2]u16{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };
    const space = [_][2]u16{
        .{ 0x09, 0x0D },     .{ 0x20, 0x20 },     .{ 0xA0, 0xA0 },     .{ 0x1680, 0x1680 },
        .{ 0x2000, 0x200A }, .{ 0x2028, 0x2029 }, .{ 0x202F, 0x202F }, .{ 0x205F, 0x205F },
        .{ 0x3000, 0x3000 }, .{ 0xFEFF, 0xFEFF },
    };
    return switch (c) {
        'd', 'D' => &digits,
        'w', 'W' => &word,
        's', 'S' => &space,
        else => null,
    };
}

fn hexVal(c: u16) ?u16 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

const RxEmitter = struct {
    alloc: std.mem.Allocator,
    insns: std.ArrayList(RxInsn) = .empty,

    fn emit(s: *RxEmitter, insn: RxInsn) RxError!usize {
        try s.insns.append(s.alloc, insn);
        return s.insns.items.len - 1;
    }

    fn gen(s: *RxEmitter, n: *const RxNode) RxError!void {
        switch (n.*) {
            .empty => {},
            .char => |c| _ = try s.emit(.{ .char = c }),
            .any => _ = try s.emit(.any),
            .cls => |ci| _ = try s.emit(.{ .cls = ci }),
            .bol => _ = try s.emit(.bol),
            .eol => _ = try s.emit(.eol),
            .wordb => _ = try s.emit(.wordb),
            .nwordb => _ = try s.emit(.nwordb),
            .group => |g| {
                _ = try s.emit(.{ .save = g.index * 2 });
                try s.gen(g.node);
                _ = try s.emit(.{ .save = g.index * 2 + 1 });
            },
            .cat => |nodes| for (nodes) |*child| try s.gen(child),
            .alt => |branches| try s.genAlt(branches),
            .rep => |r| try s.genRep(r),
        }
    }

    fn genAlt(s: *RxEmitter, branches: []const RxNode) RxError!void {
        const f = try s.emit(.{ .fork = 0 });
        try s.gen(&branches[0]);
        const j = try s.emit(.{ .jmp = 0 });
        s.insns.items[f] = .{ .fork = s.insns.items.len };
        if (branches.len == 2) {
            try s.gen(&branches[1]);
        } else {
            try s.genAlt(branches[1..]);
        }
        s.insns.items[j] = .{ .jmp = s.insns.items.len };
    }

    fn genRep(s: *RxEmitter, r: anytype) RxError!void {
        var i: usize = 0;
        while (i < r.min) : (i += 1) try s.gen(r.node);
        if (r.max == null) {
            // Unbounded tail: `L: fork(END); body; jmp L` (lazy swaps the
            // preference so the exit is tried first).
            const l = s.insns.items.len;
            _ = try s.emit(if (r.lazy) .{ .fork_lazy = 0 } else .{ .fork = 0 });
            try s.gen(r.node);
            _ = try s.emit(.{ .jmp = l });
            const end = s.insns.items.len;
            if (r.lazy) {
                s.insns.items[l] = .{ .fork_lazy = end };
            } else {
                s.insns.items[l] = .{ .fork = end };
            }
        } else {
            // (max-min) nested optionals: `a{2,4}` = a a (a (a)?)?
            const extra = r.max.? - r.min;
            var forks = std.ArrayList(usize).empty;
            for (0..extra) |_| {
                const f = try s.emit(if (r.lazy) .{ .fork_lazy = 0 } else .{ .fork = 0 });
                try forks.append(s.alloc, f);
                try s.gen(r.node);
            }
            const end = s.insns.items.len;
            for (forks.items) |f| {
                switch (s.insns.items[f]) {
                    .fork => s.insns.items[f] = .{ .fork = end },
                    .fork_lazy => s.insns.items[f] = .{ .fork_lazy = end },
                    else => unreachable,
                }
            }
        }
    }
};

fn compileRegex(alloc: std.mem.Allocator, pat: []const u8) RxError!Regex {
    // Parse on UTF-16 units so pattern escapes line up with the unit-based
    // haystack.
    var units = std.ArrayList(u16).empty;
    var view = std.unicode.Utf8View.initUnchecked(pat);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            try units.append(alloc, @intCast(cp));
        } else {
            const u = cp - 0x10000;
            try units.append(alloc, @intCast(0xD800 + (u >> 10)));
            try units.append(alloc, @intCast(0xDC00 + (u & 0x3FF)));
        }
    }
    var parser = RxParser{ .alloc = alloc, .pat = units.items };
    const ast = try parser.parseAlt();
    if (parser.pos != parser.pat.len) return error.InvalidRegex;
    var emitter = RxEmitter{ .alloc = alloc };
    try emitter.gen(ast);
    _ = try emitter.emit(.match);
    return .{
        .insns = emitter.insns.items,
        .classes = parser.classes.items,
        .ncap = parser.ncap,
    };
}

fn classHas(class: RxClass, u: u16) bool {
    var inside = false;
    for (class.ranges) |r| {
        if (u >= r[0] and u <= r[1]) {
            inside = true;
            break;
        }
    }
    return inside != class.negated;
}

fn isLineTerm(u: u16) bool {
    return u == '\n' or u == '\r' or u == 0x2028 or u == 0x2029;
}

fn isWordUnit(u: u16) bool {
    return (u >= '0' and u <= '9') or (u >= 'A' and u <= 'Z') or u == '_' or (u >= 'a' and u <= 'z');
}

fn isBoundary(t: []const u16, pos: usize) bool {
    const before = pos > 0 and isWordUnit(t[pos - 1]);
    const after = pos < t.len and isWordUnit(t[pos]);
    return before != after;
}

/// Leftmost match at-or-after `from`: saves[0]/[1] hold the match bounds,
/// group g's bounds sit at saves[2g]/[2g+1]. Returns the match end.
fn rxMatch(rx: *const Regex, t: []const u16, from: usize, saves: []usize) ?usize {
    var start = from;
    while (start <= t.len) : (start += 1) {
        @memset(saves, std.math.maxInt(usize));
        if (rxRun(rx, 0, t, start, saves)) |end| {
            saves[0] = start;
            saves[1] = end;
            return end;
        }
    }
    return null;
}

fn rxRun(rx: *const Regex, pc: usize, t: []const u16, sp: usize, saves: []usize) ?usize {
    return switch (rx.insns[pc]) {
        .match => sp,
        .char => |c| if (sp < t.len and t[sp] == c) rxRun(rx, pc + 1, t, sp + 1, saves) else null,
        .any => if (sp < t.len and !isLineTerm(t[sp])) rxRun(rx, pc + 1, t, sp + 1, saves) else null,
        .cls => |ci| if (sp < t.len and classHas(rx.classes[ci], t[sp])) rxRun(rx, pc + 1, t, sp + 1, saves) else null,
        .save => |slot| blk: {
            const old = saves[slot];
            saves[slot] = sp;
            const r = rxRun(rx, pc + 1, t, sp, saves);
            if (r == null) saves[slot] = old;
            break :blk r;
        },
        .jmp => |target| rxRun(rx, target, t, sp, saves),
        .fork => |target| rxRun(rx, pc + 1, t, sp, saves) orelse rxRun(rx, target, t, sp, saves),
        .fork_lazy => |target| rxRun(rx, target, t, sp, saves) orelse rxRun(rx, pc + 1, t, sp, saves),
        .bol => if (sp == 0) rxRun(rx, pc + 1, t, sp, saves) else null,
        .eol => if (sp == t.len) rxRun(rx, pc + 1, t, sp, saves) else null,
        .wordb => if (isBoundary(t, sp)) rxRun(rx, pc + 1, t, sp, saves) else null,
        .nwordb => if (!isBoundary(t, sp)) rxRun(rx, pc + 1, t, sp, saves) else null,
    };
}

/// JS `String.split(regex)`: scan with exec semantics — emit the text
/// before each match plus each match's captures; an empty match adjacent
/// to the cursor skips ahead one unit.
fn regexSplit(it: *Interp, rx: *const Regex, t: []const u16, pieces: *std.ArrayList(Value)) Error!void {
    const saves = try it.alloc.alloc(usize, 2 * (rx.ncap + 1));
    var p: usize = 0;
    var q: usize = 0;
    while (q < t.len) {
        const mend = rxMatch(rx, t, q, saves) orelse break;
        const mstart = saves[0];
        if (mend == p) {
            q += 1;
            continue;
        }
        try pieces.append(it.alloc, .{ .string = try fromUnits(it, t[p..mstart]) });
        var g: usize = 1;
        while (g <= rx.ncap) : (g += 1) {
            const gs = saves[g * 2];
            const ge = saves[g * 2 + 1];
            if (gs <= ge and gs != std.math.maxInt(usize)) {
                try pieces.append(it.alloc, .{ .string = try fromUnits(it, t[gs..ge]) });
            } else {
                // An unmatched group is JS undefined — serialized as null.
                try pieces.append(it.alloc, .{ .null = {} });
            }
        }
        p = mend;
        q = mend;
    }
    try pieces.append(it.alloc, .{ .string = try fromUnits(it, t[p..]) });
}
