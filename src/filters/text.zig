//! 17 text transforms — knap 0.6.0 filter group.
//!
//! Container contract (oracle-observed): the pipeline unwraps a
//! single-element array of primitives before a filter sees it, so
//! `["a b"]|upper` is scalar work. Two container shapes follow.
//! "Stringify" filters (camel, upper, indent, safe_name, unescape)
//! transform `JSON.stringify(input)` — `{"e":null}|upper` renders
//! `{"E":NULL}`. The case filters (capitalize, kebab, lower, snake,
//! title, uncamel) re-parse serialized collections, rewrite string
//! leaves AND object keys, and emit the result as JSON text.
//! truncate/truncatewords/encode_uri/decode_uri re-parse and vectorize
//! over string values only (keys and non-strings preserved). pascal
//! and trim pass containers through untouched.
//!
//! Case folding follows JS `toUpperCase`/`toLowerCase` including
//! multi-codepoint expansions (ß -> SS) and final sigma; the tables at
//! the bottom are generated from V8.

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "camel",
    "capitalize",
    "kebab",
    "lower",
    "pascal",
    "snake",
    "title",
    "uncamel",
    "upper",
    "trim",
    "truncate",
    "truncatewords",
    "indent",
    "unescape",
    "safe_name",
    "encode_uri",
    "decode_uri",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    const name = call.name;
    const eq = std.mem.eql;

    // Stringify group: transform jsText(input).
    if (eq(u8, name, "camel")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, camelText);
    }
    if (eq(u8, name, "upper")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, upperText);
    }
    if (eq(u8, name, "indent")) {
        const w = try indentWidth(it, call);
        try filters.arity(it, call, 1);
        return stringified(it, input, w, indentText);
    }
    if (eq(u8, name, "safe_name")) {
        const mode = try safeNameMode(it, call);
        try filters.arity(it, call, 1);
        return stringified(it, input, mode, safeNameText);
    }
    if (eq(u8, name, "unescape")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, unescapeText);
    }

    // snake/kebab/uncamel/lower are also stringify-model: the oracle
    // transforms JSON.stringify(v), so a \t inside a string leaf stays
    // escaped (\t -> _ for snake would otherwise corrupt the escape).
    if (eq(u8, name, "snake")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, snakeText);
    }
    if (eq(u8, name, "kebab")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, kebabText);
    }
    if (eq(u8, name, "uncamel")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, uncamelText);
    }
    if (eq(u8, name, "lower")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, lowerText);
    }

    // Vectorize group: containers re-parse and transform string leaves
    // plus object keys; non-strings serialize through.
    if (eq(u8, name, "capitalize")) {
        try filters.arity(it, call, 0);
        return vectorizedKeys(it, input, {}, capitalizeText);
    }
    if (eq(u8, name, "title")) {
        try filters.arity(it, call, 0);
        return vectorizedKeys(it, input, {}, titleText);
    }

    // pascal is stringify-model like camel/upper: pascal(true) -> "True".
    if (eq(u8, name, "pascal")) {
        try filters.arity(it, call, 0);
        return stringified(it, input, {}, pascalText);
    }

    // Passthrough group: containers return unchanged.
    if (eq(u8, name, "trim")) {
        try filters.arity(it, call, 0);
        return passthrough(it, input, {}, trimText);
    }

    // Value-vectorizing group: mapStrings over containers.
    if (eq(u8, name, "truncate")) {
        const ctx = try truncateArgs(it, call);
        try filters.arity(it, call, 2);
        return vectorizedValues(it, input, ctx, truncateText);
    }
    if (eq(u8, name, "truncatewords")) {
        const ctx = try truncateArgs(it, call);
        try filters.arity(it, call, 2);
        return vectorizedValues(it, input, ctx, truncateWordsText);
    }
    if (eq(u8, name, "encode_uri")) {
        try filters.arity(it, call, 0);
        return vectorizedValues(it, input, {}, encodeUriText);
    }
    if (eq(u8, name, "decode_uri")) {
        try filters.arity(it, call, 0);
        return vectorizedValues(it, input, {}, decodeUriText);
    }
    return null;
}

// --------------------------------------------------------------------
// Container dispatch shapes.

/// The pipeline hands each filter a single-element array's primitive
/// payload: `{{ ["a b"] | camel }}` sees "a b". Nulls and containers do
/// not unwrap.
fn unwrapSingle(v: *const Value) *const Value {
    return switch (v.*) {
        .array => |arr| if (arr.items.len == 1) switch (arr.items[0]) {
            .bool, .integer, .float, .number_string, .string => &arr.items[0],
            else => v,
        } else v,
        else => v,
    };
}

/// scalarText for scalars, JSON.stringify for containers — the oracle's
/// String()-ish input feeding the stringify group.
fn jsText(it: *Interp, v: *const Value) Error![]const u8 {
    return switch (v.*) {
        .array, .object => blk: {
            var buf = std.Io.Writer.Allocating.init(it.alloc);
            try it.jsStringify(v, &buf);
            break :blk buf.written();
        },
        else => (try filters.scalarText(it.alloc, v.*)) orelse "",
    };
}

/// Stringify group: the transform sees `jsText(input)` wholesale.
fn stringified(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const text = try jsText(it, unwrapSingle(input));
    return it.make(.{ .string = try f(ctx, it, text) });
}

/// Case group: re-parsed containers emit JSON text with every string
/// leaf and object key transformed; non-strings serialize as-is.
fn vectorizedKeys(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const v = try filters.normalizeInput(it, unwrapSingle(input));
    return switch (v.*) {
        .string => |s| it.make(.{ .string = try f(ctx, it, s) }),
        .number_string => |s| it.make(.{ .string = try f(ctx, it, s) }),
        .array, .object => blk: {
            const mapped = try mapKeysAndStrings(it, v, ctx, f);
            var buf = std.Io.Writer.Allocating.init(it.alloc);
            try it.jsStringify(mapped, &buf);
            break :blk it.make(.{ .string = buf.written() });
        },
        else => v,
    };
}

fn mapKeysAndStrings(
    it: *Interp,
    v: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    switch (v.*) {
        .string => |s| return it.make(.{ .string = try f(ctx, it, s) }),
        .number_string => |s| return it.make(.{ .string = try f(ctx, it, s) }),
        .array => |arr| {
            var items = try it.alloc.alloc(Value, arr.items.len);
            for (arr.items, 0..) |*item, i| {
                items[i] = (try mapKeysAndStrings(it, item, ctx, f)).*;
            }
            var list = std.json.Array.init(it.alloc);
            try list.appendSlice(items);
            return it.make(.{ .array = list });
        },
        .object => |obj| {
            var map: std.json.ObjectMap = .empty;
            try map.ensureTotalCapacity(it.alloc, obj.count());
            var it2 = obj.iterator();
            while (it2.next()) |entry| {
                const key = try f(ctx, it, entry.key_ptr.*);
                const mapped = try mapKeysAndStrings(it, entry.value_ptr, ctx, f);
                map.putAssumeCapacity(key, mapped.*);
            }
            return it.make(.{ .object = map });
        },
        else => return v,
    }
}

/// Passthrough group: containers are returned unchanged; scalars are
/// transformed as text (trim(true) -> "true").
fn passthrough(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const v = unwrapSingle(input);
    switch (v.*) {
        .array, .object => return v,
        else => {},
    }
    const s = (try filters.scalarText(it.alloc, v.*)) orelse "";
    return it.make(.{ .string = try f(ctx, it, s) });
}

/// Value-vectorizing group: containers map string leaves (keys and
/// non-strings preserved) after serialized-collection re-parsing;
/// scalars transform as text (truncate:2 on true -> "t…").
fn vectorizedValues(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const v = try filters.normalizeInput(it, unwrapSingle(input));
    return switch (v.*) {
        .array, .object => filters.mapStrings(it, v, true, ctx, f),
        else => blk: {
            const s = (try filters.scalarText(it.alloc, v.*)) orelse "";
            break :blk it.make(.{ .string = try f(ctx, it, s) });
        },
    };
}

// --------------------------------------------------------------------
// Argument handling.

fn indentWidth(it: *Interp, call: parse.FilterCall) Error!usize {
    const n = (try filters.paramNumber(it, call, 0)) orelse return 2;
    if (!isNonNegInt(n) or n > 1000) {
        return filters.badArg(it, call, "filter 'indent' expects an integer width from 0 to 1000", .{});
    }
    return @intFromFloat(n);
}

const TruncCtx = struct { limit: usize, suffix: []const u8 };

fn truncateArgs(it: *Interp, call: parse.FilterCall) Error!TruncCtx {
    const n = (try filters.paramNumber(it, call, 0)) orelse
        return filters.badArg(it, call, "filter '{s}' requires a non-negative limit argument", .{call.name});
    if (!isNonNegInt(n)) {
        return filters.badArg(it, call, "filter '{s}' expects a non-negative integer limit", .{call.name});
    }
    return .{ .limit = @intFromFloat(n), .suffix = (try filters.paramText(it, call, 1)) orelse "…" };
}

fn isNonNegInt(n: f64) bool {
    return n >= 0 and @floor(n) == n and n < 9.0e15;
}

const SafeMode = enum { windows, mac, linux };

fn safeNameMode(it: *Interp, call: parse.FilterCall) Error!SafeMode {
    const arg = (try filters.paramText(it, call, 0)) orelse return .windows;
    if (std.mem.eql(u8, arg, "windows")) return .windows;
    if (std.mem.eql(u8, arg, "mac")) return .mac;
    if (std.mem.eql(u8, arg, "linux")) return .linux;
    return filters.badArg(it, call, "filter 'safe_name' accepts windows, mac or linux", .{});
}

// --------------------------------------------------------------------
// UTF-8 / case helpers.

fn decodeAll(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u21 {
    var cps = std.ArrayList(u21).empty;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try cps.append(alloc, s[i]);
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try cps.append(alloc, s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            try cps.append(alloc, s[i]);
            i += 1;
            continue;
        };
        try cps.append(alloc, cp);
        i += len;
    }
    return cps.toOwnedSlice(alloc);
}

fn appendCp(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) error{OutOfMemory}!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch 1;
    try out.appendSlice(alloc, buf[0..n]);
}

fn appendCps(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cps: []const u21) error{OutOfMemory}!void {
    for (cps) |cp| try appendCp(out, alloc, cp);
}

fn lookupCase(table: []const CaseMap, cp: u21) ?u21 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const e = table[mid];
        if (cp < e.from) hi = mid else if (cp > e.from) lo = mid + 1 else return e.to;
    }
    return null;
}

fn lookupMulti(table: []const MultiMap, cp: u21) ?[]const u21 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const e = table[mid];
        if (cp < e.from) hi = mid else if (cp > e.from) lo = mid + 1 else return case_multi_data[e.off .. e.off + e.len];
    }
    return null;
}

fn lookupRanges(ranges: []const Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = ranges[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return true;
    }
    return false;
}

/// JS toUpperCase of one codepoint — may expand (ß -> SS).
fn appendUpper(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) error{OutOfMemory}!void {
    if (lookupMulti(&upper_multi, cp)) |cps| return appendCps(out, alloc, cps);
    try appendCp(out, alloc, lookupCase(&upper_map, cp) orelse cp);
}

/// JS toLowerCase of one codepoint in the context of `cps` — Σ folds to
/// ς at a word-final cased position (final sigma).
fn appendLowerAt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cps: []const u21, i: usize) error{OutOfMemory}!void {
    const cp = cps[i];
    if (cp == 0x3A3) {
        try appendCp(out, alloc, if (isFinalSigma(cps, i)) 0x3C2 else 0x3C3);
        return;
    }
    if (lookupMulti(&lower_multi, cp)) |m| return appendCps(out, alloc, m);
    try appendCp(out, alloc, lookupCase(&lower_map, cp) orelse cp);
}

fn isFinalSigma(cps: []const u21, i: usize) bool {
    var preceded = false;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (lookupRanges(&caseign_ranges, cps[j])) continue;
        preceded = lookupRanges(&cased_ranges, cps[j]);
        break;
    }
    if (!preceded) return false;
    j = i + 1;
    while (j < cps.len) : (j += 1) {
        if (lookupRanges(&caseign_ranges, cps[j])) continue;
        return !lookupRanges(&cased_ranges, cps[j]);
    }
    return true;
}

/// JS `\s`: WhiteSpace + LineTerminator.
fn isWs(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn isAsciiLetter(cp: u21) bool {
    return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
}

fn isAsciiLower(cp: u21) bool {
    return cp >= 'a' and cp <= 'z';
}

fn isAsciiUpper(cp: u21) bool {
    return cp >= 'A' and cp <= 'Z';
}

fn isAsciiDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn asciiLower(c: u21) u21 {
    return if (isAsciiUpper(c)) c + 32 else c;
}

fn asciiUpper(c: u21) u21 {
    return if (isAsciiLower(c)) c - 32 else c;
}

// --------------------------------------------------------------------
// Scalar transforms (all take cps -> out bytes via it.alloc).

fn camelText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    var cap = false;
    for (cps, 0..) |c, i| {
        if (isAsciiLetter(c)) {
            if (i == 0) {
                try appendCp(&out, it.alloc, asciiLower(c));
                continue;
            }
            try appendCp(&out, it.alloc, if (cap) asciiUpper(c) else c);
            cap = false;
        } else if (isAsciiDigit(c)) {
            try appendCp(&out, it.alloc, c);
            cap = false;
        } else if (isWs(c) or c == '-') {
            cap = true;
        } else if (c == '_') {
            cap = false;
        } else {
            try appendCp(&out, it.alloc, c);
            cap = true;
        }
    }
    return out.toOwnedSlice(it.alloc);
}

fn pascalText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    var cap = true;
    var i: usize = 0;
    while (i < cps.len) {
        const c = cps[i];
        if (isWs(c) or c == '-' or c == '_') {
            var j = i;
            while (j < cps.len and (isWs(cps[j]) or cps[j] == '-' or cps[j] == '_')) j += 1;
            // A trailing separator run keeps its last character.
            if (j == cps.len) try appendCp(&out, it.alloc, cps[j - 1]) else cap = true;
            i = j;
            continue;
        }
        if (cap) {
            try appendUpper(&out, it.alloc, c);
            cap = false;
        } else {
            try appendCp(&out, it.alloc, c);
        }
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn snakeText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    var prev_lower = false;
    var i: usize = 0;
    while (i < cps.len) {
        const c = cps[i];
        if (isWs(c) or c == '-') {
            try out.append(it.alloc, '_');
            while (i < cps.len and (isWs(cps[i]) or cps[i] == '-')) i += 1;
            prev_lower = false;
            continue;
        }
        if (isAsciiUpper(c) and prev_lower) try out.append(it.alloc, '_');
        try appendLowerAt(&out, it.alloc, cps, i);
        prev_lower = isAsciiLower(c);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn kebabText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    var prev_lower = false;
    var i: usize = 0;
    while (i < cps.len) {
        const c = cps[i];
        if (isWs(c) or c == '_') {
            try out.append(it.alloc, '-');
            while (i < cps.len and (isWs(cps[i]) or cps[i] == '_')) i += 1;
            prev_lower = false;
            continue;
        }
        if (c == '-') {
            try out.append(it.alloc, '-');
            prev_lower = false;
            i += 1;
            continue;
        }
        if (isAsciiUpper(c) and prev_lower) try out.append(it.alloc, '-');
        try appendLowerAt(&out, it.alloc, cps, i);
        prev_lower = isAsciiLower(c);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

const title_small_words = [_][]const u8{ "a", "an", "the", "and", "or", "for", "nor", "but", "at", "by", "in", "of", "on", "to", "from" };

fn isTitleSmallWord(word: []const u21) bool {
    for (word) |c| if (c > 0x7F) return false;
    for (title_small_words) |w| {
        if (w.len != word.len) continue;
        var ok = true;
        for (word, 0..) |c, k| {
            if (asciiLower(c) != w[k]) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// knap title-case: collapse whitespace runs, capitalize each word's
/// first character and lowercase the rest — except small words
/// (articles/conjunctions/prepositions) which stay lowercase in
/// non-leading position ("x a y" -> "X a Y", "a x" -> "A X").
fn titleText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    var first = true;
    while (i < cps.len) {
        if (isWs(cps[i])) {
            try out.append(it.alloc, ' ');
            while (i < cps.len and isWs(cps[i])) i += 1;
            first = false;
            continue;
        }
        var j = i;
        while (j < cps.len and !isWs(cps[j])) j += 1;
        const word = cps[i..j];
        if (first or !isTitleSmallWord(word)) {
            try appendUpper(&out, it.alloc, word[0]);
            // The oracle lowers word.slice(1) — sigma context is the
            // slice alone, so "XΣ" yields "Xσ" but "aXΣ" yields "Axς".
            for (1..word.len) |k| try appendLowerAt(&out, it.alloc, word[1..], k - 1);
        } else {
            for (word, 0..) |_, k| try appendLowerAt(&out, it.alloc, word, k);
        }
        first = false;
        i = j;
    }
    return out.toOwnedSlice(it.alloc);
}

fn uncamelText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    for (cps, 0..) |c, i| {
        if (isAsciiUpper(c) and i > 0) {
            const prev = cps[i - 1];
            const boundary = isAsciiLower(prev) or isAsciiDigit(prev) or
                (isAsciiUpper(prev) and i + 1 < cps.len and isAsciiLower(cps[i + 1]));
            if (boundary) try out.append(it.alloc, ' ');
        }
        try appendLowerAt(&out, it.alloc, cps, i);
    }
    return out.toOwnedSlice(it.alloc);
}

fn capitalizeText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    if (cps.len > 0) {
        try appendUpper(&out, it.alloc, cps[0]);
        // upper(s[0]) + lower(s.slice(1)) — sigma context is the slice.
        for (1..cps.len) |i| try appendLowerAt(&out, it.alloc, cps[1..], i - 1);
    }
    return out.toOwnedSlice(it.alloc);
}

fn lowerText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    for (cps, 0..) |_, i| try appendLowerAt(&out, it.alloc, cps, i);
    return out.toOwnedSlice(it.alloc);
}

fn upperText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var out = std.ArrayList(u8).empty;
    for (cps) |c| try appendUpper(&out, it.alloc, c);
    return out.toOwnedSlice(it.alloc);
}

fn trimText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    _ = it;
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b) {
        const n = std.unicode.utf8ByteSequenceLength(s[a]) catch 1;
        const cp = if (a + n <= b) std.unicode.utf8Decode(s[a .. a + n]) catch s[a] else s[a];
        if (!isWs(cp)) break;
        a += n;
    }
    while (b > a) {
        // Walk back over a full UTF-8 sequence.
        var start = b - 1;
        while (start > a and (s[start] & 0xC0) == 0x80) start -= 1;
        const n = std.unicode.utf8ByteSequenceLength(s[start]) catch 1;
        const cp = if (start + n <= b) std.unicode.utf8Decode(s[start .. start + n]) catch s[start] else s[start];
        if (!isWs(cp)) break;
        b = start;
    }
    return s[a..b];
}

// --------------------------------------------------------------------
// Grapheme clusters (approximates UAX-29 — enough for the documented
// emoji/combining/regional-indicator cases).

const Gcb = enum { cr, lf, control, extend, zwj, spacing, prepend, ri, l, v, t, lv, lvt, extpict, other };

const prepend_ranges = [_]Range{
    .{ .lo = 0x600, .hi = 0x605 },   .{ .lo = 0x6DD, .hi = 0x6DD },
    .{ .lo = 0x70F, .hi = 0x70F },   .{ .lo = 0x8E2, .hi = 0x8E2 },
    .{ .lo = 0xD4E, .hi = 0xD4E },   .{ .lo = 0x110BD, .hi = 0x110BD },
    .{ .lo = 0x110CD, .hi = 0x110CD }, .{ .lo = 0x111C2, .hi = 0x111C3 },
    .{ .lo = 0x1193D, .hi = 0x1193D }, .{ .lo = 0x1193E, .hi = 0x1193E },
    .{ .lo = 0x11941, .hi = 0x11941 }, .{ .lo = 0x11A3A, .hi = 0x11A3A },
    .{ .lo = 0x11A84, .hi = 0x11A89 }, .{ .lo = 0x11D46, .hi = 0x11D46 },
};

fn gcbOf(cp: u21) Gcb {
    if (cp == 0x0D) return .cr;
    if (cp == 0x0A) return .lf;
    if (cp == 0x200D) return .zwj;
    if (lookupRanges(&gcb_extend_ranges, cp)) return .extend;
    if (lookupRanges(&gcb_spacing_ranges, cp)) return .spacing;
    if (lookupRanges(&prepend_ranges, cp)) return .prepend;
    if (lookupRanges(&gcb_ri_ranges, cp)) return .ri;
    if (cp >= 0x1100 and cp <= 0x115F) return .l;
    if (cp >= 0xA960 and cp <= 0xA97C) return .l;
    if (cp >= 0x1160 and cp <= 0x11A7) return .v;
    if (cp >= 0xD7B0 and cp <= 0xD7C6) return .v;
    if (cp >= 0x11A8 and cp <= 0x11FF) return .t;
    if (cp >= 0xD7CB and cp <= 0xD7FB) return .t;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return if ((cp - 0xAC00) % 28 == 0) .lv else .lvt;
    if (lookupRanges(&gcb_control_ranges, cp)) return .control;
    if (lookupRanges(&gcb_extpict_ranges, cp)) return .extpict;
    return .other;
}

/// Number of codepoints in the grapheme cluster starting at `start`.
fn clusterEnd(cps: []const u21, start: usize) usize {
    var i = start + 1;
    var ri_odd = gcbOf(cps[start]) == .ri;
    var ext_pict = gcbOf(cps[start]) == .extpict;
    var ext_pict_zwj = false;
    while (i < cps.len) {
        const p = gcbOf(cps[i - 1]);
        const n = gcbOf(cps[i]);
        const nobreak = blk: {
            if (p == .cr and n == .lf) break :blk true;
            if (p == .control or p == .cr or p == .lf) break :blk false;
            if (n == .control or n == .cr or n == .lf) break :blk false;
            if (p == .l and (n == .l or n == .v or n == .lv or n == .lvt)) break :blk true;
            if ((p == .lv or p == .v) and (n == .v or n == .t)) break :blk true;
            if ((p == .lvt or p == .t) and n == .t) break :blk true;
            if (n == .extend or n == .zwj or n == .spacing) break :blk true;
            if (p == .prepend) break :blk true;
            if (n == .extpict and ext_pict_zwj) break :blk true;
            if (p == .ri and n == .ri and ri_odd) break :blk true;
            break :blk false;
        };
        if (!nobreak) break;
        if (n == .ri) ri_odd = !ri_odd else ri_odd = false;
        switch (n) {
            .extpict => ext_pict = true,
            .zwj => {
                if (ext_pict) ext_pict_zwj = true;
            },
            .extend, .spacing => {},
            else => {
                ext_pict = false;
                ext_pict_zwj = false;
            },
        }
        i += 1;
    }
    return i;
}

fn graphemeCount(cps: []const u21) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cps.len) {
        i = clusterEnd(cps, i);
        n += 1;
    }
    return n;
}

fn truncateText(ctx: TruncCtx, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    if (graphemeCount(cps) <= ctx.limit) return s;
    const suf_cps = try decodeAll(it.alloc, ctx.suffix);
    const suf_len = graphemeCount(suf_cps);
    const keep = if (ctx.limit > suf_len) ctx.limit - suf_len else 0;
    const take = @min(suf_len, ctx.limit);
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    var k: usize = 0;
    while (i < cps.len and k < keep) {
        const e = clusterEnd(cps, i);
        try appendCps(&out, it.alloc, cps[i..e]);
        i = e;
        k += 1;
    }
    i = 0;
    k = 0;
    while (i < suf_cps.len and k < take) {
        const e = clusterEnd(suf_cps, i);
        try appendCps(&out, it.alloc, suf_cps[i..e]);
        i = e;
        k += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

fn truncateWordsText(ctx: TruncCtx, it: *Interp, s: []const u8) Error![]const u8 {
    const cps = try decodeAll(it.alloc, s);
    var words: usize = 0;
    var i: usize = 0;
    var cut: usize = 0;
    while (i < cps.len) {
        while (i < cps.len and isWs(cps[i])) i += 1;
        if (i >= cps.len) break;
        while (i < cps.len and !isWs(cps[i])) i += 1;
        words += 1;
        if (words == ctx.limit) cut = i;
    }
    if (words <= ctx.limit) return s;
    if (ctx.limit == 0) return "";
    var out = std.ArrayList(u8).empty;
    try appendCps(&out, it.alloc, cps[0..cut]);
    try out.appendSlice(it.alloc, ctx.suffix);
    return out.toOwnedSlice(it.alloc);
}

fn indentText(w: usize, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var line_start = true;
    for (s) |c| {
        if (line_start and c != '\r' and c != '\n') {
            var k: usize = 0;
            while (k < w) : (k += 1) try out.append(it.alloc, ' ');
            line_start = false;
        }
        try out.append(it.alloc, c);
        if (c == '\r' or c == '\n') line_start = true;
    }
    return out.toOwnedSlice(it.alloc);
}

fn unescapeText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == 'n' or s[i + 1] == '"')) {
            try out.append(it.alloc, if (s[i + 1] == 'n') '\n' else '"');
            i += 2;
            continue;
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

const reserved_names = [_][]const u8{ "CON", "PRN", "AUX", "NUL" };

fn safeNameText(mode: SafeMode, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (s) |c| {
        const unsafe = c < 0x20 or switch (mode) {
            .windows => c == '"' or c == '#' or c == '*' or c == '/' or c == ':' or c == '<' or c == '>' or c == '?' or c == '[' or c == '\\' or c == ']' or c == '^' or c == '|',
            .mac => c == '#' or c == '/' or c == ':' or c == '[' or c == ']' or c == '^' or c == '|',
            .linux => c == '#' or c == '/' or c == '[' or c == ']' or c == '^' or c == '|',
        };
        if (!unsafe) try out.append(it.alloc, c);
    }
    var name = out.items;
    if (mode == .windows) {
        // Reserved device stems take a leading underscore.
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        const stem = name[0..dot];
        var reserved = false;
        for (reserved_names) |r| {
            if (std.ascii.eqlIgnoreCase(stem, r)) {
                reserved = true;
                break;
            }
        }
        if (!reserved and stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT")) and isAsciiDigit(stem[3])) reserved = true;
        if (reserved) {
            var tmp = std.ArrayList(u8).empty;
            try tmp.append(it.alloc, '_');
            try tmp.appendSlice(it.alloc, name);
            name = tmp.items;
        }
        // Trailing dots and whitespace are invalid on Windows.
        var end = name.len;
        while (end > 0) {
            var start = end - 1;
            while (start > 0 and (name[start] & 0xC0) == 0x80) start -= 1;
            const n = std.unicode.utf8ByteSequenceLength(name[start]) catch 1;
            const cp = if (start + n <= end) std.unicode.utf8Decode(name[start .. start + n]) catch name[start] else name[start];
            if (cp != '.' and !isWs(cp)) break;
            end = start;
        }
        name = name[0..end];
    }
    if (name.len > 0 and name[0] == '.') name[0] = '_';
    if (name.len == 0) return "Untitled";
    return name;
}

fn encodeUriText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    const hex = "0123456789ABCDEF";
    var out = std.ArrayList(u8).empty;
    for (s) |c| {
        const keep = std.ascii.isAlphanumeric(c) or switch (c) {
            '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
            else => false,
        };
        if (keep) {
            try out.append(it.alloc, c);
        } else {
            try out.append(it.alloc, '%');
            try out.append(it.alloc, hex[c >> 4]);
            try out.append(it.alloc, hex[c & 0xF]);
        }
    }
    return out.toOwnedSlice(it.alloc);
}

fn decodeUriText(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return s;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return s;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return s;
            try out.append(it.alloc, hi * 16 + lo);
            i += 3;
            continue;
        }
        try out.append(it.alloc, s[i]);
        i += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return s;
    return out.items;
}

// --------------------------------------------------------------------
// Generated Unicode tables (V8-derived: case mappings, cased and
// case-ignorable sets, grapheme cluster break approximations).
// Generated from V8 Unicode tables (see KNAP-FIDELITY.md; regenerated via node).
const CaseMap = struct { from: u21, to: u21 };
const MultiMap = struct { from: u21, off: u32, len: u8 };
const Range = struct { lo: u21, hi: u21 };

const upper_map = [_]CaseMap{
    .{ .from = 0x61, .to = 0x41 }, .{ .from = 0x62, .to = 0x42 }, .{ .from = 0x63, .to = 0x43 }, .{ .from = 0x64, .to = 0x44 }, 
    .{ .from = 0x65, .to = 0x45 }, .{ .from = 0x66, .to = 0x46 }, .{ .from = 0x67, .to = 0x47 }, .{ .from = 0x68, .to = 0x48 }, 
    .{ .from = 0x69, .to = 0x49 }, .{ .from = 0x6a, .to = 0x4a }, .{ .from = 0x6b, .to = 0x4b }, .{ .from = 0x6c, .to = 0x4c }, 
    .{ .from = 0x6d, .to = 0x4d }, .{ .from = 0x6e, .to = 0x4e }, .{ .from = 0x6f, .to = 0x4f }, .{ .from = 0x70, .to = 0x50 }, 
    .{ .from = 0x71, .to = 0x51 }, .{ .from = 0x72, .to = 0x52 }, .{ .from = 0x73, .to = 0x53 }, .{ .from = 0x74, .to = 0x54 }, 
    .{ .from = 0x75, .to = 0x55 }, .{ .from = 0x76, .to = 0x56 }, .{ .from = 0x77, .to = 0x57 }, .{ .from = 0x78, .to = 0x58 }, 
    .{ .from = 0x79, .to = 0x59 }, .{ .from = 0x7a, .to = 0x5a }, .{ .from = 0xb5, .to = 0x39c }, .{ .from = 0xe0, .to = 0xc0 }, 
    .{ .from = 0xe1, .to = 0xc1 }, .{ .from = 0xe2, .to = 0xc2 }, .{ .from = 0xe3, .to = 0xc3 }, .{ .from = 0xe4, .to = 0xc4 }, 
    .{ .from = 0xe5, .to = 0xc5 }, .{ .from = 0xe6, .to = 0xc6 }, .{ .from = 0xe7, .to = 0xc7 }, .{ .from = 0xe8, .to = 0xc8 }, 
    .{ .from = 0xe9, .to = 0xc9 }, .{ .from = 0xea, .to = 0xca }, .{ .from = 0xeb, .to = 0xcb }, .{ .from = 0xec, .to = 0xcc }, 
    .{ .from = 0xed, .to = 0xcd }, .{ .from = 0xee, .to = 0xce }, .{ .from = 0xef, .to = 0xcf }, .{ .from = 0xf0, .to = 0xd0 }, 
    .{ .from = 0xf1, .to = 0xd1 }, .{ .from = 0xf2, .to = 0xd2 }, .{ .from = 0xf3, .to = 0xd3 }, .{ .from = 0xf4, .to = 0xd4 }, 
    .{ .from = 0xf5, .to = 0xd5 }, .{ .from = 0xf6, .to = 0xd6 }, .{ .from = 0xf8, .to = 0xd8 }, .{ .from = 0xf9, .to = 0xd9 }, 
    .{ .from = 0xfa, .to = 0xda }, .{ .from = 0xfb, .to = 0xdb }, .{ .from = 0xfc, .to = 0xdc }, .{ .from = 0xfd, .to = 0xdd }, 
    .{ .from = 0xfe, .to = 0xde }, .{ .from = 0xff, .to = 0x178 }, .{ .from = 0x101, .to = 0x100 }, .{ .from = 0x103, .to = 0x102 }, 
    .{ .from = 0x105, .to = 0x104 }, .{ .from = 0x107, .to = 0x106 }, .{ .from = 0x109, .to = 0x108 }, .{ .from = 0x10b, .to = 0x10a }, 
    .{ .from = 0x10d, .to = 0x10c }, .{ .from = 0x10f, .to = 0x10e }, .{ .from = 0x111, .to = 0x110 }, .{ .from = 0x113, .to = 0x112 }, 
    .{ .from = 0x115, .to = 0x114 }, .{ .from = 0x117, .to = 0x116 }, .{ .from = 0x119, .to = 0x118 }, .{ .from = 0x11b, .to = 0x11a }, 
    .{ .from = 0x11d, .to = 0x11c }, .{ .from = 0x11f, .to = 0x11e }, .{ .from = 0x121, .to = 0x120 }, .{ .from = 0x123, .to = 0x122 }, 
    .{ .from = 0x125, .to = 0x124 }, .{ .from = 0x127, .to = 0x126 }, .{ .from = 0x129, .to = 0x128 }, .{ .from = 0x12b, .to = 0x12a }, 
    .{ .from = 0x12d, .to = 0x12c }, .{ .from = 0x12f, .to = 0x12e }, .{ .from = 0x131, .to = 0x49 }, .{ .from = 0x133, .to = 0x132 }, 
    .{ .from = 0x135, .to = 0x134 }, .{ .from = 0x137, .to = 0x136 }, .{ .from = 0x13a, .to = 0x139 }, .{ .from = 0x13c, .to = 0x13b }, 
    .{ .from = 0x13e, .to = 0x13d }, .{ .from = 0x140, .to = 0x13f }, .{ .from = 0x142, .to = 0x141 }, .{ .from = 0x144, .to = 0x143 }, 
    .{ .from = 0x146, .to = 0x145 }, .{ .from = 0x148, .to = 0x147 }, .{ .from = 0x14b, .to = 0x14a }, .{ .from = 0x14d, .to = 0x14c }, 
    .{ .from = 0x14f, .to = 0x14e }, .{ .from = 0x151, .to = 0x150 }, .{ .from = 0x153, .to = 0x152 }, .{ .from = 0x155, .to = 0x154 }, 
    .{ .from = 0x157, .to = 0x156 }, .{ .from = 0x159, .to = 0x158 }, .{ .from = 0x15b, .to = 0x15a }, .{ .from = 0x15d, .to = 0x15c }, 
    .{ .from = 0x15f, .to = 0x15e }, .{ .from = 0x161, .to = 0x160 }, .{ .from = 0x163, .to = 0x162 }, .{ .from = 0x165, .to = 0x164 }, 
    .{ .from = 0x167, .to = 0x166 }, .{ .from = 0x169, .to = 0x168 }, .{ .from = 0x16b, .to = 0x16a }, .{ .from = 0x16d, .to = 0x16c }, 
    .{ .from = 0x16f, .to = 0x16e }, .{ .from = 0x171, .to = 0x170 }, .{ .from = 0x173, .to = 0x172 }, .{ .from = 0x175, .to = 0x174 }, 
    .{ .from = 0x177, .to = 0x176 }, .{ .from = 0x17a, .to = 0x179 }, .{ .from = 0x17c, .to = 0x17b }, .{ .from = 0x17e, .to = 0x17d }, 
    .{ .from = 0x17f, .to = 0x53 }, .{ .from = 0x180, .to = 0x243 }, .{ .from = 0x183, .to = 0x182 }, .{ .from = 0x185, .to = 0x184 }, 
    .{ .from = 0x188, .to = 0x187 }, .{ .from = 0x18c, .to = 0x18b }, .{ .from = 0x192, .to = 0x191 }, .{ .from = 0x195, .to = 0x1f6 }, 
    .{ .from = 0x199, .to = 0x198 }, .{ .from = 0x19a, .to = 0x23d }, .{ .from = 0x19b, .to = 0xa7dc }, .{ .from = 0x19e, .to = 0x220 }, 
    .{ .from = 0x1a1, .to = 0x1a0 }, .{ .from = 0x1a3, .to = 0x1a2 }, .{ .from = 0x1a5, .to = 0x1a4 }, .{ .from = 0x1a8, .to = 0x1a7 }, 
    .{ .from = 0x1ad, .to = 0x1ac }, .{ .from = 0x1b0, .to = 0x1af }, .{ .from = 0x1b4, .to = 0x1b3 }, .{ .from = 0x1b6, .to = 0x1b5 }, 
    .{ .from = 0x1b9, .to = 0x1b8 }, .{ .from = 0x1bd, .to = 0x1bc }, .{ .from = 0x1bf, .to = 0x1f7 }, .{ .from = 0x1c5, .to = 0x1c4 }, 
    .{ .from = 0x1c6, .to = 0x1c4 }, .{ .from = 0x1c8, .to = 0x1c7 }, .{ .from = 0x1c9, .to = 0x1c7 }, .{ .from = 0x1cb, .to = 0x1ca }, 
    .{ .from = 0x1cc, .to = 0x1ca }, .{ .from = 0x1ce, .to = 0x1cd }, .{ .from = 0x1d0, .to = 0x1cf }, .{ .from = 0x1d2, .to = 0x1d1 }, 
    .{ .from = 0x1d4, .to = 0x1d3 }, .{ .from = 0x1d6, .to = 0x1d5 }, .{ .from = 0x1d8, .to = 0x1d7 }, .{ .from = 0x1da, .to = 0x1d9 }, 
    .{ .from = 0x1dc, .to = 0x1db }, .{ .from = 0x1dd, .to = 0x18e }, .{ .from = 0x1df, .to = 0x1de }, .{ .from = 0x1e1, .to = 0x1e0 }, 
    .{ .from = 0x1e3, .to = 0x1e2 }, .{ .from = 0x1e5, .to = 0x1e4 }, .{ .from = 0x1e7, .to = 0x1e6 }, .{ .from = 0x1e9, .to = 0x1e8 }, 
    .{ .from = 0x1eb, .to = 0x1ea }, .{ .from = 0x1ed, .to = 0x1ec }, .{ .from = 0x1ef, .to = 0x1ee }, .{ .from = 0x1f2, .to = 0x1f1 }, 
    .{ .from = 0x1f3, .to = 0x1f1 }, .{ .from = 0x1f5, .to = 0x1f4 }, .{ .from = 0x1f9, .to = 0x1f8 }, .{ .from = 0x1fb, .to = 0x1fa }, 
    .{ .from = 0x1fd, .to = 0x1fc }, .{ .from = 0x1ff, .to = 0x1fe }, .{ .from = 0x201, .to = 0x200 }, .{ .from = 0x203, .to = 0x202 }, 
    .{ .from = 0x205, .to = 0x204 }, .{ .from = 0x207, .to = 0x206 }, .{ .from = 0x209, .to = 0x208 }, .{ .from = 0x20b, .to = 0x20a }, 
    .{ .from = 0x20d, .to = 0x20c }, .{ .from = 0x20f, .to = 0x20e }, .{ .from = 0x211, .to = 0x210 }, .{ .from = 0x213, .to = 0x212 }, 
    .{ .from = 0x215, .to = 0x214 }, .{ .from = 0x217, .to = 0x216 }, .{ .from = 0x219, .to = 0x218 }, .{ .from = 0x21b, .to = 0x21a }, 
    .{ .from = 0x21d, .to = 0x21c }, .{ .from = 0x21f, .to = 0x21e }, .{ .from = 0x223, .to = 0x222 }, .{ .from = 0x225, .to = 0x224 }, 
    .{ .from = 0x227, .to = 0x226 }, .{ .from = 0x229, .to = 0x228 }, .{ .from = 0x22b, .to = 0x22a }, .{ .from = 0x22d, .to = 0x22c }, 
    .{ .from = 0x22f, .to = 0x22e }, .{ .from = 0x231, .to = 0x230 }, .{ .from = 0x233, .to = 0x232 }, .{ .from = 0x23c, .to = 0x23b }, 
    .{ .from = 0x23f, .to = 0x2c7e }, .{ .from = 0x240, .to = 0x2c7f }, .{ .from = 0x242, .to = 0x241 }, .{ .from = 0x247, .to = 0x246 }, 
    .{ .from = 0x249, .to = 0x248 }, .{ .from = 0x24b, .to = 0x24a }, .{ .from = 0x24d, .to = 0x24c }, .{ .from = 0x24f, .to = 0x24e }, 
    .{ .from = 0x250, .to = 0x2c6f }, .{ .from = 0x251, .to = 0x2c6d }, .{ .from = 0x252, .to = 0x2c70 }, .{ .from = 0x253, .to = 0x181 }, 
    .{ .from = 0x254, .to = 0x186 }, .{ .from = 0x256, .to = 0x189 }, .{ .from = 0x257, .to = 0x18a }, .{ .from = 0x259, .to = 0x18f }, 
    .{ .from = 0x25b, .to = 0x190 }, .{ .from = 0x25c, .to = 0xa7ab }, .{ .from = 0x260, .to = 0x193 }, .{ .from = 0x261, .to = 0xa7ac }, 
    .{ .from = 0x263, .to = 0x194 }, .{ .from = 0x264, .to = 0xa7cb }, .{ .from = 0x265, .to = 0xa78d }, .{ .from = 0x266, .to = 0xa7aa }, 
    .{ .from = 0x268, .to = 0x197 }, .{ .from = 0x269, .to = 0x196 }, .{ .from = 0x26a, .to = 0xa7ae }, .{ .from = 0x26b, .to = 0x2c62 }, 
    .{ .from = 0x26c, .to = 0xa7ad }, .{ .from = 0x26f, .to = 0x19c }, .{ .from = 0x271, .to = 0x2c6e }, .{ .from = 0x272, .to = 0x19d }, 
    .{ .from = 0x275, .to = 0x19f }, .{ .from = 0x27d, .to = 0x2c64 }, .{ .from = 0x280, .to = 0x1a6 }, .{ .from = 0x282, .to = 0xa7c5 }, 
    .{ .from = 0x283, .to = 0x1a9 }, .{ .from = 0x287, .to = 0xa7b1 }, .{ .from = 0x288, .to = 0x1ae }, .{ .from = 0x289, .to = 0x244 }, 
    .{ .from = 0x28a, .to = 0x1b1 }, .{ .from = 0x28b, .to = 0x1b2 }, .{ .from = 0x28c, .to = 0x245 }, .{ .from = 0x292, .to = 0x1b7 }, 
    .{ .from = 0x29d, .to = 0xa7b2 }, .{ .from = 0x29e, .to = 0xa7b0 }, .{ .from = 0x345, .to = 0x399 }, .{ .from = 0x371, .to = 0x370 }, 
    .{ .from = 0x373, .to = 0x372 }, .{ .from = 0x377, .to = 0x376 }, .{ .from = 0x37b, .to = 0x3fd }, .{ .from = 0x37c, .to = 0x3fe }, 
    .{ .from = 0x37d, .to = 0x3ff }, .{ .from = 0x3ac, .to = 0x386 }, .{ .from = 0x3ad, .to = 0x388 }, .{ .from = 0x3ae, .to = 0x389 }, 
    .{ .from = 0x3af, .to = 0x38a }, .{ .from = 0x3b1, .to = 0x391 }, .{ .from = 0x3b2, .to = 0x392 }, .{ .from = 0x3b3, .to = 0x393 }, 
    .{ .from = 0x3b4, .to = 0x394 }, .{ .from = 0x3b5, .to = 0x395 }, .{ .from = 0x3b6, .to = 0x396 }, .{ .from = 0x3b7, .to = 0x397 }, 
    .{ .from = 0x3b8, .to = 0x398 }, .{ .from = 0x3b9, .to = 0x399 }, .{ .from = 0x3ba, .to = 0x39a }, .{ .from = 0x3bb, .to = 0x39b }, 
    .{ .from = 0x3bc, .to = 0x39c }, .{ .from = 0x3bd, .to = 0x39d }, .{ .from = 0x3be, .to = 0x39e }, .{ .from = 0x3bf, .to = 0x39f }, 
    .{ .from = 0x3c0, .to = 0x3a0 }, .{ .from = 0x3c1, .to = 0x3a1 }, .{ .from = 0x3c2, .to = 0x3a3 }, .{ .from = 0x3c3, .to = 0x3a3 }, 
    .{ .from = 0x3c4, .to = 0x3a4 }, .{ .from = 0x3c5, .to = 0x3a5 }, .{ .from = 0x3c6, .to = 0x3a6 }, .{ .from = 0x3c7, .to = 0x3a7 }, 
    .{ .from = 0x3c8, .to = 0x3a8 }, .{ .from = 0x3c9, .to = 0x3a9 }, .{ .from = 0x3ca, .to = 0x3aa }, .{ .from = 0x3cb, .to = 0x3ab }, 
    .{ .from = 0x3cc, .to = 0x38c }, .{ .from = 0x3cd, .to = 0x38e }, .{ .from = 0x3ce, .to = 0x38f }, .{ .from = 0x3d0, .to = 0x392 }, 
    .{ .from = 0x3d1, .to = 0x398 }, .{ .from = 0x3d5, .to = 0x3a6 }, .{ .from = 0x3d6, .to = 0x3a0 }, .{ .from = 0x3d7, .to = 0x3cf }, 
    .{ .from = 0x3d9, .to = 0x3d8 }, .{ .from = 0x3db, .to = 0x3da }, .{ .from = 0x3dd, .to = 0x3dc }, .{ .from = 0x3df, .to = 0x3de }, 
    .{ .from = 0x3e1, .to = 0x3e0 }, .{ .from = 0x3e3, .to = 0x3e2 }, .{ .from = 0x3e5, .to = 0x3e4 }, .{ .from = 0x3e7, .to = 0x3e6 }, 
    .{ .from = 0x3e9, .to = 0x3e8 }, .{ .from = 0x3eb, .to = 0x3ea }, .{ .from = 0x3ed, .to = 0x3ec }, .{ .from = 0x3ef, .to = 0x3ee }, 
    .{ .from = 0x3f0, .to = 0x39a }, .{ .from = 0x3f1, .to = 0x3a1 }, .{ .from = 0x3f2, .to = 0x3f9 }, .{ .from = 0x3f3, .to = 0x37f }, 
    .{ .from = 0x3f5, .to = 0x395 }, .{ .from = 0x3f8, .to = 0x3f7 }, .{ .from = 0x3fb, .to = 0x3fa }, .{ .from = 0x430, .to = 0x410 }, 
    .{ .from = 0x431, .to = 0x411 }, .{ .from = 0x432, .to = 0x412 }, .{ .from = 0x433, .to = 0x413 }, .{ .from = 0x434, .to = 0x414 }, 
    .{ .from = 0x435, .to = 0x415 }, .{ .from = 0x436, .to = 0x416 }, .{ .from = 0x437, .to = 0x417 }, .{ .from = 0x438, .to = 0x418 }, 
    .{ .from = 0x439, .to = 0x419 }, .{ .from = 0x43a, .to = 0x41a }, .{ .from = 0x43b, .to = 0x41b }, .{ .from = 0x43c, .to = 0x41c }, 
    .{ .from = 0x43d, .to = 0x41d }, .{ .from = 0x43e, .to = 0x41e }, .{ .from = 0x43f, .to = 0x41f }, .{ .from = 0x440, .to = 0x420 }, 
    .{ .from = 0x441, .to = 0x421 }, .{ .from = 0x442, .to = 0x422 }, .{ .from = 0x443, .to = 0x423 }, .{ .from = 0x444, .to = 0x424 }, 
    .{ .from = 0x445, .to = 0x425 }, .{ .from = 0x446, .to = 0x426 }, .{ .from = 0x447, .to = 0x427 }, .{ .from = 0x448, .to = 0x428 }, 
    .{ .from = 0x449, .to = 0x429 }, .{ .from = 0x44a, .to = 0x42a }, .{ .from = 0x44b, .to = 0x42b }, .{ .from = 0x44c, .to = 0x42c }, 
    .{ .from = 0x44d, .to = 0x42d }, .{ .from = 0x44e, .to = 0x42e }, .{ .from = 0x44f, .to = 0x42f }, .{ .from = 0x450, .to = 0x400 }, 
    .{ .from = 0x451, .to = 0x401 }, .{ .from = 0x452, .to = 0x402 }, .{ .from = 0x453, .to = 0x403 }, .{ .from = 0x454, .to = 0x404 }, 
    .{ .from = 0x455, .to = 0x405 }, .{ .from = 0x456, .to = 0x406 }, .{ .from = 0x457, .to = 0x407 }, .{ .from = 0x458, .to = 0x408 }, 
    .{ .from = 0x459, .to = 0x409 }, .{ .from = 0x45a, .to = 0x40a }, .{ .from = 0x45b, .to = 0x40b }, .{ .from = 0x45c, .to = 0x40c }, 
    .{ .from = 0x45d, .to = 0x40d }, .{ .from = 0x45e, .to = 0x40e }, .{ .from = 0x45f, .to = 0x40f }, .{ .from = 0x461, .to = 0x460 }, 
    .{ .from = 0x463, .to = 0x462 }, .{ .from = 0x465, .to = 0x464 }, .{ .from = 0x467, .to = 0x466 }, .{ .from = 0x469, .to = 0x468 }, 
    .{ .from = 0x46b, .to = 0x46a }, .{ .from = 0x46d, .to = 0x46c }, .{ .from = 0x46f, .to = 0x46e }, .{ .from = 0x471, .to = 0x470 }, 
    .{ .from = 0x473, .to = 0x472 }, .{ .from = 0x475, .to = 0x474 }, .{ .from = 0x477, .to = 0x476 }, .{ .from = 0x479, .to = 0x478 }, 
    .{ .from = 0x47b, .to = 0x47a }, .{ .from = 0x47d, .to = 0x47c }, .{ .from = 0x47f, .to = 0x47e }, .{ .from = 0x481, .to = 0x480 }, 
    .{ .from = 0x48b, .to = 0x48a }, .{ .from = 0x48d, .to = 0x48c }, .{ .from = 0x48f, .to = 0x48e }, .{ .from = 0x491, .to = 0x490 }, 
    .{ .from = 0x493, .to = 0x492 }, .{ .from = 0x495, .to = 0x494 }, .{ .from = 0x497, .to = 0x496 }, .{ .from = 0x499, .to = 0x498 }, 
    .{ .from = 0x49b, .to = 0x49a }, .{ .from = 0x49d, .to = 0x49c }, .{ .from = 0x49f, .to = 0x49e }, .{ .from = 0x4a1, .to = 0x4a0 }, 
    .{ .from = 0x4a3, .to = 0x4a2 }, .{ .from = 0x4a5, .to = 0x4a4 }, .{ .from = 0x4a7, .to = 0x4a6 }, .{ .from = 0x4a9, .to = 0x4a8 }, 
    .{ .from = 0x4ab, .to = 0x4aa }, .{ .from = 0x4ad, .to = 0x4ac }, .{ .from = 0x4af, .to = 0x4ae }, .{ .from = 0x4b1, .to = 0x4b0 }, 
    .{ .from = 0x4b3, .to = 0x4b2 }, .{ .from = 0x4b5, .to = 0x4b4 }, .{ .from = 0x4b7, .to = 0x4b6 }, .{ .from = 0x4b9, .to = 0x4b8 }, 
    .{ .from = 0x4bb, .to = 0x4ba }, .{ .from = 0x4bd, .to = 0x4bc }, .{ .from = 0x4bf, .to = 0x4be }, .{ .from = 0x4c2, .to = 0x4c1 }, 
    .{ .from = 0x4c4, .to = 0x4c3 }, .{ .from = 0x4c6, .to = 0x4c5 }, .{ .from = 0x4c8, .to = 0x4c7 }, .{ .from = 0x4ca, .to = 0x4c9 }, 
    .{ .from = 0x4cc, .to = 0x4cb }, .{ .from = 0x4ce, .to = 0x4cd }, .{ .from = 0x4cf, .to = 0x4c0 }, .{ .from = 0x4d1, .to = 0x4d0 }, 
    .{ .from = 0x4d3, .to = 0x4d2 }, .{ .from = 0x4d5, .to = 0x4d4 }, .{ .from = 0x4d7, .to = 0x4d6 }, .{ .from = 0x4d9, .to = 0x4d8 }, 
    .{ .from = 0x4db, .to = 0x4da }, .{ .from = 0x4dd, .to = 0x4dc }, .{ .from = 0x4df, .to = 0x4de }, .{ .from = 0x4e1, .to = 0x4e0 }, 
    .{ .from = 0x4e3, .to = 0x4e2 }, .{ .from = 0x4e5, .to = 0x4e4 }, .{ .from = 0x4e7, .to = 0x4e6 }, .{ .from = 0x4e9, .to = 0x4e8 }, 
    .{ .from = 0x4eb, .to = 0x4ea }, .{ .from = 0x4ed, .to = 0x4ec }, .{ .from = 0x4ef, .to = 0x4ee }, .{ .from = 0x4f1, .to = 0x4f0 }, 
    .{ .from = 0x4f3, .to = 0x4f2 }, .{ .from = 0x4f5, .to = 0x4f4 }, .{ .from = 0x4f7, .to = 0x4f6 }, .{ .from = 0x4f9, .to = 0x4f8 }, 
    .{ .from = 0x4fb, .to = 0x4fa }, .{ .from = 0x4fd, .to = 0x4fc }, .{ .from = 0x4ff, .to = 0x4fe }, .{ .from = 0x501, .to = 0x500 }, 
    .{ .from = 0x503, .to = 0x502 }, .{ .from = 0x505, .to = 0x504 }, .{ .from = 0x507, .to = 0x506 }, .{ .from = 0x509, .to = 0x508 }, 
    .{ .from = 0x50b, .to = 0x50a }, .{ .from = 0x50d, .to = 0x50c }, .{ .from = 0x50f, .to = 0x50e }, .{ .from = 0x511, .to = 0x510 }, 
    .{ .from = 0x513, .to = 0x512 }, .{ .from = 0x515, .to = 0x514 }, .{ .from = 0x517, .to = 0x516 }, .{ .from = 0x519, .to = 0x518 }, 
    .{ .from = 0x51b, .to = 0x51a }, .{ .from = 0x51d, .to = 0x51c }, .{ .from = 0x51f, .to = 0x51e }, .{ .from = 0x521, .to = 0x520 }, 
    .{ .from = 0x523, .to = 0x522 }, .{ .from = 0x525, .to = 0x524 }, .{ .from = 0x527, .to = 0x526 }, .{ .from = 0x529, .to = 0x528 }, 
    .{ .from = 0x52b, .to = 0x52a }, .{ .from = 0x52d, .to = 0x52c }, .{ .from = 0x52f, .to = 0x52e }, .{ .from = 0x561, .to = 0x531 }, 
    .{ .from = 0x562, .to = 0x532 }, .{ .from = 0x563, .to = 0x533 }, .{ .from = 0x564, .to = 0x534 }, .{ .from = 0x565, .to = 0x535 }, 
    .{ .from = 0x566, .to = 0x536 }, .{ .from = 0x567, .to = 0x537 }, .{ .from = 0x568, .to = 0x538 }, .{ .from = 0x569, .to = 0x539 }, 
    .{ .from = 0x56a, .to = 0x53a }, .{ .from = 0x56b, .to = 0x53b }, .{ .from = 0x56c, .to = 0x53c }, .{ .from = 0x56d, .to = 0x53d }, 
    .{ .from = 0x56e, .to = 0x53e }, .{ .from = 0x56f, .to = 0x53f }, .{ .from = 0x570, .to = 0x540 }, .{ .from = 0x571, .to = 0x541 }, 
    .{ .from = 0x572, .to = 0x542 }, .{ .from = 0x573, .to = 0x543 }, .{ .from = 0x574, .to = 0x544 }, .{ .from = 0x575, .to = 0x545 }, 
    .{ .from = 0x576, .to = 0x546 }, .{ .from = 0x577, .to = 0x547 }, .{ .from = 0x578, .to = 0x548 }, .{ .from = 0x579, .to = 0x549 }, 
    .{ .from = 0x57a, .to = 0x54a }, .{ .from = 0x57b, .to = 0x54b }, .{ .from = 0x57c, .to = 0x54c }, .{ .from = 0x57d, .to = 0x54d }, 
    .{ .from = 0x57e, .to = 0x54e }, .{ .from = 0x57f, .to = 0x54f }, .{ .from = 0x580, .to = 0x550 }, .{ .from = 0x581, .to = 0x551 }, 
    .{ .from = 0x582, .to = 0x552 }, .{ .from = 0x583, .to = 0x553 }, .{ .from = 0x584, .to = 0x554 }, .{ .from = 0x585, .to = 0x555 }, 
    .{ .from = 0x586, .to = 0x556 }, .{ .from = 0x10d0, .to = 0x1c90 }, .{ .from = 0x10d1, .to = 0x1c91 }, .{ .from = 0x10d2, .to = 0x1c92 }, 
    .{ .from = 0x10d3, .to = 0x1c93 }, .{ .from = 0x10d4, .to = 0x1c94 }, .{ .from = 0x10d5, .to = 0x1c95 }, .{ .from = 0x10d6, .to = 0x1c96 }, 
    .{ .from = 0x10d7, .to = 0x1c97 }, .{ .from = 0x10d8, .to = 0x1c98 }, .{ .from = 0x10d9, .to = 0x1c99 }, .{ .from = 0x10da, .to = 0x1c9a }, 
    .{ .from = 0x10db, .to = 0x1c9b }, .{ .from = 0x10dc, .to = 0x1c9c }, .{ .from = 0x10dd, .to = 0x1c9d }, .{ .from = 0x10de, .to = 0x1c9e }, 
    .{ .from = 0x10df, .to = 0x1c9f }, .{ .from = 0x10e0, .to = 0x1ca0 }, .{ .from = 0x10e1, .to = 0x1ca1 }, .{ .from = 0x10e2, .to = 0x1ca2 }, 
    .{ .from = 0x10e3, .to = 0x1ca3 }, .{ .from = 0x10e4, .to = 0x1ca4 }, .{ .from = 0x10e5, .to = 0x1ca5 }, .{ .from = 0x10e6, .to = 0x1ca6 }, 
    .{ .from = 0x10e7, .to = 0x1ca7 }, .{ .from = 0x10e8, .to = 0x1ca8 }, .{ .from = 0x10e9, .to = 0x1ca9 }, .{ .from = 0x10ea, .to = 0x1caa }, 
    .{ .from = 0x10eb, .to = 0x1cab }, .{ .from = 0x10ec, .to = 0x1cac }, .{ .from = 0x10ed, .to = 0x1cad }, .{ .from = 0x10ee, .to = 0x1cae }, 
    .{ .from = 0x10ef, .to = 0x1caf }, .{ .from = 0x10f0, .to = 0x1cb0 }, .{ .from = 0x10f1, .to = 0x1cb1 }, .{ .from = 0x10f2, .to = 0x1cb2 }, 
    .{ .from = 0x10f3, .to = 0x1cb3 }, .{ .from = 0x10f4, .to = 0x1cb4 }, .{ .from = 0x10f5, .to = 0x1cb5 }, .{ .from = 0x10f6, .to = 0x1cb6 }, 
    .{ .from = 0x10f7, .to = 0x1cb7 }, .{ .from = 0x10f8, .to = 0x1cb8 }, .{ .from = 0x10f9, .to = 0x1cb9 }, .{ .from = 0x10fa, .to = 0x1cba }, 
    .{ .from = 0x10fd, .to = 0x1cbd }, .{ .from = 0x10fe, .to = 0x1cbe }, .{ .from = 0x10ff, .to = 0x1cbf }, .{ .from = 0x13f8, .to = 0x13f0 }, 
    .{ .from = 0x13f9, .to = 0x13f1 }, .{ .from = 0x13fa, .to = 0x13f2 }, .{ .from = 0x13fb, .to = 0x13f3 }, .{ .from = 0x13fc, .to = 0x13f4 }, 
    .{ .from = 0x13fd, .to = 0x13f5 }, .{ .from = 0x1c80, .to = 0x412 }, .{ .from = 0x1c81, .to = 0x414 }, .{ .from = 0x1c82, .to = 0x41e }, 
    .{ .from = 0x1c83, .to = 0x421 }, .{ .from = 0x1c84, .to = 0x422 }, .{ .from = 0x1c85, .to = 0x422 }, .{ .from = 0x1c86, .to = 0x42a }, 
    .{ .from = 0x1c87, .to = 0x462 }, .{ .from = 0x1c88, .to = 0xa64a }, .{ .from = 0x1c8a, .to = 0x1c89 }, .{ .from = 0x1d79, .to = 0xa77d }, 
    .{ .from = 0x1d7d, .to = 0x2c63 }, .{ .from = 0x1d8e, .to = 0xa7c6 }, .{ .from = 0x1e01, .to = 0x1e00 }, .{ .from = 0x1e03, .to = 0x1e02 }, 
    .{ .from = 0x1e05, .to = 0x1e04 }, .{ .from = 0x1e07, .to = 0x1e06 }, .{ .from = 0x1e09, .to = 0x1e08 }, .{ .from = 0x1e0b, .to = 0x1e0a }, 
    .{ .from = 0x1e0d, .to = 0x1e0c }, .{ .from = 0x1e0f, .to = 0x1e0e }, .{ .from = 0x1e11, .to = 0x1e10 }, .{ .from = 0x1e13, .to = 0x1e12 }, 
    .{ .from = 0x1e15, .to = 0x1e14 }, .{ .from = 0x1e17, .to = 0x1e16 }, .{ .from = 0x1e19, .to = 0x1e18 }, .{ .from = 0x1e1b, .to = 0x1e1a }, 
    .{ .from = 0x1e1d, .to = 0x1e1c }, .{ .from = 0x1e1f, .to = 0x1e1e }, .{ .from = 0x1e21, .to = 0x1e20 }, .{ .from = 0x1e23, .to = 0x1e22 }, 
    .{ .from = 0x1e25, .to = 0x1e24 }, .{ .from = 0x1e27, .to = 0x1e26 }, .{ .from = 0x1e29, .to = 0x1e28 }, .{ .from = 0x1e2b, .to = 0x1e2a }, 
    .{ .from = 0x1e2d, .to = 0x1e2c }, .{ .from = 0x1e2f, .to = 0x1e2e }, .{ .from = 0x1e31, .to = 0x1e30 }, .{ .from = 0x1e33, .to = 0x1e32 }, 
    .{ .from = 0x1e35, .to = 0x1e34 }, .{ .from = 0x1e37, .to = 0x1e36 }, .{ .from = 0x1e39, .to = 0x1e38 }, .{ .from = 0x1e3b, .to = 0x1e3a }, 
    .{ .from = 0x1e3d, .to = 0x1e3c }, .{ .from = 0x1e3f, .to = 0x1e3e }, .{ .from = 0x1e41, .to = 0x1e40 }, .{ .from = 0x1e43, .to = 0x1e42 }, 
    .{ .from = 0x1e45, .to = 0x1e44 }, .{ .from = 0x1e47, .to = 0x1e46 }, .{ .from = 0x1e49, .to = 0x1e48 }, .{ .from = 0x1e4b, .to = 0x1e4a }, 
    .{ .from = 0x1e4d, .to = 0x1e4c }, .{ .from = 0x1e4f, .to = 0x1e4e }, .{ .from = 0x1e51, .to = 0x1e50 }, .{ .from = 0x1e53, .to = 0x1e52 }, 
    .{ .from = 0x1e55, .to = 0x1e54 }, .{ .from = 0x1e57, .to = 0x1e56 }, .{ .from = 0x1e59, .to = 0x1e58 }, .{ .from = 0x1e5b, .to = 0x1e5a }, 
    .{ .from = 0x1e5d, .to = 0x1e5c }, .{ .from = 0x1e5f, .to = 0x1e5e }, .{ .from = 0x1e61, .to = 0x1e60 }, .{ .from = 0x1e63, .to = 0x1e62 }, 
    .{ .from = 0x1e65, .to = 0x1e64 }, .{ .from = 0x1e67, .to = 0x1e66 }, .{ .from = 0x1e69, .to = 0x1e68 }, .{ .from = 0x1e6b, .to = 0x1e6a }, 
    .{ .from = 0x1e6d, .to = 0x1e6c }, .{ .from = 0x1e6f, .to = 0x1e6e }, .{ .from = 0x1e71, .to = 0x1e70 }, .{ .from = 0x1e73, .to = 0x1e72 }, 
    .{ .from = 0x1e75, .to = 0x1e74 }, .{ .from = 0x1e77, .to = 0x1e76 }, .{ .from = 0x1e79, .to = 0x1e78 }, .{ .from = 0x1e7b, .to = 0x1e7a }, 
    .{ .from = 0x1e7d, .to = 0x1e7c }, .{ .from = 0x1e7f, .to = 0x1e7e }, .{ .from = 0x1e81, .to = 0x1e80 }, .{ .from = 0x1e83, .to = 0x1e82 }, 
    .{ .from = 0x1e85, .to = 0x1e84 }, .{ .from = 0x1e87, .to = 0x1e86 }, .{ .from = 0x1e89, .to = 0x1e88 }, .{ .from = 0x1e8b, .to = 0x1e8a }, 
    .{ .from = 0x1e8d, .to = 0x1e8c }, .{ .from = 0x1e8f, .to = 0x1e8e }, .{ .from = 0x1e91, .to = 0x1e90 }, .{ .from = 0x1e93, .to = 0x1e92 }, 
    .{ .from = 0x1e95, .to = 0x1e94 }, .{ .from = 0x1e9b, .to = 0x1e60 }, .{ .from = 0x1ea1, .to = 0x1ea0 }, .{ .from = 0x1ea3, .to = 0x1ea2 }, 
    .{ .from = 0x1ea5, .to = 0x1ea4 }, .{ .from = 0x1ea7, .to = 0x1ea6 }, .{ .from = 0x1ea9, .to = 0x1ea8 }, .{ .from = 0x1eab, .to = 0x1eaa }, 
    .{ .from = 0x1ead, .to = 0x1eac }, .{ .from = 0x1eaf, .to = 0x1eae }, .{ .from = 0x1eb1, .to = 0x1eb0 }, .{ .from = 0x1eb3, .to = 0x1eb2 }, 
    .{ .from = 0x1eb5, .to = 0x1eb4 }, .{ .from = 0x1eb7, .to = 0x1eb6 }, .{ .from = 0x1eb9, .to = 0x1eb8 }, .{ .from = 0x1ebb, .to = 0x1eba }, 
    .{ .from = 0x1ebd, .to = 0x1ebc }, .{ .from = 0x1ebf, .to = 0x1ebe }, .{ .from = 0x1ec1, .to = 0x1ec0 }, .{ .from = 0x1ec3, .to = 0x1ec2 }, 
    .{ .from = 0x1ec5, .to = 0x1ec4 }, .{ .from = 0x1ec7, .to = 0x1ec6 }, .{ .from = 0x1ec9, .to = 0x1ec8 }, .{ .from = 0x1ecb, .to = 0x1eca }, 
    .{ .from = 0x1ecd, .to = 0x1ecc }, .{ .from = 0x1ecf, .to = 0x1ece }, .{ .from = 0x1ed1, .to = 0x1ed0 }, .{ .from = 0x1ed3, .to = 0x1ed2 }, 
    .{ .from = 0x1ed5, .to = 0x1ed4 }, .{ .from = 0x1ed7, .to = 0x1ed6 }, .{ .from = 0x1ed9, .to = 0x1ed8 }, .{ .from = 0x1edb, .to = 0x1eda }, 
    .{ .from = 0x1edd, .to = 0x1edc }, .{ .from = 0x1edf, .to = 0x1ede }, .{ .from = 0x1ee1, .to = 0x1ee0 }, .{ .from = 0x1ee3, .to = 0x1ee2 }, 
    .{ .from = 0x1ee5, .to = 0x1ee4 }, .{ .from = 0x1ee7, .to = 0x1ee6 }, .{ .from = 0x1ee9, .to = 0x1ee8 }, .{ .from = 0x1eeb, .to = 0x1eea }, 
    .{ .from = 0x1eed, .to = 0x1eec }, .{ .from = 0x1eef, .to = 0x1eee }, .{ .from = 0x1ef1, .to = 0x1ef0 }, .{ .from = 0x1ef3, .to = 0x1ef2 }, 
    .{ .from = 0x1ef5, .to = 0x1ef4 }, .{ .from = 0x1ef7, .to = 0x1ef6 }, .{ .from = 0x1ef9, .to = 0x1ef8 }, .{ .from = 0x1efb, .to = 0x1efa }, 
    .{ .from = 0x1efd, .to = 0x1efc }, .{ .from = 0x1eff, .to = 0x1efe }, .{ .from = 0x1f00, .to = 0x1f08 }, .{ .from = 0x1f01, .to = 0x1f09 }, 
    .{ .from = 0x1f02, .to = 0x1f0a }, .{ .from = 0x1f03, .to = 0x1f0b }, .{ .from = 0x1f04, .to = 0x1f0c }, .{ .from = 0x1f05, .to = 0x1f0d }, 
    .{ .from = 0x1f06, .to = 0x1f0e }, .{ .from = 0x1f07, .to = 0x1f0f }, .{ .from = 0x1f10, .to = 0x1f18 }, .{ .from = 0x1f11, .to = 0x1f19 }, 
    .{ .from = 0x1f12, .to = 0x1f1a }, .{ .from = 0x1f13, .to = 0x1f1b }, .{ .from = 0x1f14, .to = 0x1f1c }, .{ .from = 0x1f15, .to = 0x1f1d }, 
    .{ .from = 0x1f20, .to = 0x1f28 }, .{ .from = 0x1f21, .to = 0x1f29 }, .{ .from = 0x1f22, .to = 0x1f2a }, .{ .from = 0x1f23, .to = 0x1f2b }, 
    .{ .from = 0x1f24, .to = 0x1f2c }, .{ .from = 0x1f25, .to = 0x1f2d }, .{ .from = 0x1f26, .to = 0x1f2e }, .{ .from = 0x1f27, .to = 0x1f2f }, 
    .{ .from = 0x1f30, .to = 0x1f38 }, .{ .from = 0x1f31, .to = 0x1f39 }, .{ .from = 0x1f32, .to = 0x1f3a }, .{ .from = 0x1f33, .to = 0x1f3b }, 
    .{ .from = 0x1f34, .to = 0x1f3c }, .{ .from = 0x1f35, .to = 0x1f3d }, .{ .from = 0x1f36, .to = 0x1f3e }, .{ .from = 0x1f37, .to = 0x1f3f }, 
    .{ .from = 0x1f40, .to = 0x1f48 }, .{ .from = 0x1f41, .to = 0x1f49 }, .{ .from = 0x1f42, .to = 0x1f4a }, .{ .from = 0x1f43, .to = 0x1f4b }, 
    .{ .from = 0x1f44, .to = 0x1f4c }, .{ .from = 0x1f45, .to = 0x1f4d }, .{ .from = 0x1f51, .to = 0x1f59 }, .{ .from = 0x1f53, .to = 0x1f5b }, 
    .{ .from = 0x1f55, .to = 0x1f5d }, .{ .from = 0x1f57, .to = 0x1f5f }, .{ .from = 0x1f60, .to = 0x1f68 }, .{ .from = 0x1f61, .to = 0x1f69 }, 
    .{ .from = 0x1f62, .to = 0x1f6a }, .{ .from = 0x1f63, .to = 0x1f6b }, .{ .from = 0x1f64, .to = 0x1f6c }, .{ .from = 0x1f65, .to = 0x1f6d }, 
    .{ .from = 0x1f66, .to = 0x1f6e }, .{ .from = 0x1f67, .to = 0x1f6f }, .{ .from = 0x1f70, .to = 0x1fba }, .{ .from = 0x1f71, .to = 0x1fbb }, 
    .{ .from = 0x1f72, .to = 0x1fc8 }, .{ .from = 0x1f73, .to = 0x1fc9 }, .{ .from = 0x1f74, .to = 0x1fca }, .{ .from = 0x1f75, .to = 0x1fcb }, 
    .{ .from = 0x1f76, .to = 0x1fda }, .{ .from = 0x1f77, .to = 0x1fdb }, .{ .from = 0x1f78, .to = 0x1ff8 }, .{ .from = 0x1f79, .to = 0x1ff9 }, 
    .{ .from = 0x1f7a, .to = 0x1fea }, .{ .from = 0x1f7b, .to = 0x1feb }, .{ .from = 0x1f7c, .to = 0x1ffa }, .{ .from = 0x1f7d, .to = 0x1ffb }, 
    .{ .from = 0x1fb0, .to = 0x1fb8 }, .{ .from = 0x1fb1, .to = 0x1fb9 }, .{ .from = 0x1fbe, .to = 0x399 }, .{ .from = 0x1fd0, .to = 0x1fd8 }, 
    .{ .from = 0x1fd1, .to = 0x1fd9 }, .{ .from = 0x1fe0, .to = 0x1fe8 }, .{ .from = 0x1fe1, .to = 0x1fe9 }, .{ .from = 0x1fe5, .to = 0x1fec }, 
    .{ .from = 0x214e, .to = 0x2132 }, .{ .from = 0x2170, .to = 0x2160 }, .{ .from = 0x2171, .to = 0x2161 }, .{ .from = 0x2172, .to = 0x2162 }, 
    .{ .from = 0x2173, .to = 0x2163 }, .{ .from = 0x2174, .to = 0x2164 }, .{ .from = 0x2175, .to = 0x2165 }, .{ .from = 0x2176, .to = 0x2166 }, 
    .{ .from = 0x2177, .to = 0x2167 }, .{ .from = 0x2178, .to = 0x2168 }, .{ .from = 0x2179, .to = 0x2169 }, .{ .from = 0x217a, .to = 0x216a }, 
    .{ .from = 0x217b, .to = 0x216b }, .{ .from = 0x217c, .to = 0x216c }, .{ .from = 0x217d, .to = 0x216d }, .{ .from = 0x217e, .to = 0x216e }, 
    .{ .from = 0x217f, .to = 0x216f }, .{ .from = 0x2184, .to = 0x2183 }, .{ .from = 0x24d0, .to = 0x24b6 }, .{ .from = 0x24d1, .to = 0x24b7 }, 
    .{ .from = 0x24d2, .to = 0x24b8 }, .{ .from = 0x24d3, .to = 0x24b9 }, .{ .from = 0x24d4, .to = 0x24ba }, .{ .from = 0x24d5, .to = 0x24bb }, 
    .{ .from = 0x24d6, .to = 0x24bc }, .{ .from = 0x24d7, .to = 0x24bd }, .{ .from = 0x24d8, .to = 0x24be }, .{ .from = 0x24d9, .to = 0x24bf }, 
    .{ .from = 0x24da, .to = 0x24c0 }, .{ .from = 0x24db, .to = 0x24c1 }, .{ .from = 0x24dc, .to = 0x24c2 }, .{ .from = 0x24dd, .to = 0x24c3 }, 
    .{ .from = 0x24de, .to = 0x24c4 }, .{ .from = 0x24df, .to = 0x24c5 }, .{ .from = 0x24e0, .to = 0x24c6 }, .{ .from = 0x24e1, .to = 0x24c7 }, 
    .{ .from = 0x24e2, .to = 0x24c8 }, .{ .from = 0x24e3, .to = 0x24c9 }, .{ .from = 0x24e4, .to = 0x24ca }, .{ .from = 0x24e5, .to = 0x24cb }, 
    .{ .from = 0x24e6, .to = 0x24cc }, .{ .from = 0x24e7, .to = 0x24cd }, .{ .from = 0x24e8, .to = 0x24ce }, .{ .from = 0x24e9, .to = 0x24cf }, 
    .{ .from = 0x2c30, .to = 0x2c00 }, .{ .from = 0x2c31, .to = 0x2c01 }, .{ .from = 0x2c32, .to = 0x2c02 }, .{ .from = 0x2c33, .to = 0x2c03 }, 
    .{ .from = 0x2c34, .to = 0x2c04 }, .{ .from = 0x2c35, .to = 0x2c05 }, .{ .from = 0x2c36, .to = 0x2c06 }, .{ .from = 0x2c37, .to = 0x2c07 }, 
    .{ .from = 0x2c38, .to = 0x2c08 }, .{ .from = 0x2c39, .to = 0x2c09 }, .{ .from = 0x2c3a, .to = 0x2c0a }, .{ .from = 0x2c3b, .to = 0x2c0b }, 
    .{ .from = 0x2c3c, .to = 0x2c0c }, .{ .from = 0x2c3d, .to = 0x2c0d }, .{ .from = 0x2c3e, .to = 0x2c0e }, .{ .from = 0x2c3f, .to = 0x2c0f }, 
    .{ .from = 0x2c40, .to = 0x2c10 }, .{ .from = 0x2c41, .to = 0x2c11 }, .{ .from = 0x2c42, .to = 0x2c12 }, .{ .from = 0x2c43, .to = 0x2c13 }, 
    .{ .from = 0x2c44, .to = 0x2c14 }, .{ .from = 0x2c45, .to = 0x2c15 }, .{ .from = 0x2c46, .to = 0x2c16 }, .{ .from = 0x2c47, .to = 0x2c17 }, 
    .{ .from = 0x2c48, .to = 0x2c18 }, .{ .from = 0x2c49, .to = 0x2c19 }, .{ .from = 0x2c4a, .to = 0x2c1a }, .{ .from = 0x2c4b, .to = 0x2c1b }, 
    .{ .from = 0x2c4c, .to = 0x2c1c }, .{ .from = 0x2c4d, .to = 0x2c1d }, .{ .from = 0x2c4e, .to = 0x2c1e }, .{ .from = 0x2c4f, .to = 0x2c1f }, 
    .{ .from = 0x2c50, .to = 0x2c20 }, .{ .from = 0x2c51, .to = 0x2c21 }, .{ .from = 0x2c52, .to = 0x2c22 }, .{ .from = 0x2c53, .to = 0x2c23 }, 
    .{ .from = 0x2c54, .to = 0x2c24 }, .{ .from = 0x2c55, .to = 0x2c25 }, .{ .from = 0x2c56, .to = 0x2c26 }, .{ .from = 0x2c57, .to = 0x2c27 }, 
    .{ .from = 0x2c58, .to = 0x2c28 }, .{ .from = 0x2c59, .to = 0x2c29 }, .{ .from = 0x2c5a, .to = 0x2c2a }, .{ .from = 0x2c5b, .to = 0x2c2b }, 
    .{ .from = 0x2c5c, .to = 0x2c2c }, .{ .from = 0x2c5d, .to = 0x2c2d }, .{ .from = 0x2c5e, .to = 0x2c2e }, .{ .from = 0x2c5f, .to = 0x2c2f }, 
    .{ .from = 0x2c61, .to = 0x2c60 }, .{ .from = 0x2c65, .to = 0x23a }, .{ .from = 0x2c66, .to = 0x23e }, .{ .from = 0x2c68, .to = 0x2c67 }, 
    .{ .from = 0x2c6a, .to = 0x2c69 }, .{ .from = 0x2c6c, .to = 0x2c6b }, .{ .from = 0x2c73, .to = 0x2c72 }, .{ .from = 0x2c76, .to = 0x2c75 }, 
    .{ .from = 0x2c81, .to = 0x2c80 }, .{ .from = 0x2c83, .to = 0x2c82 }, .{ .from = 0x2c85, .to = 0x2c84 }, .{ .from = 0x2c87, .to = 0x2c86 }, 
    .{ .from = 0x2c89, .to = 0x2c88 }, .{ .from = 0x2c8b, .to = 0x2c8a }, .{ .from = 0x2c8d, .to = 0x2c8c }, .{ .from = 0x2c8f, .to = 0x2c8e }, 
    .{ .from = 0x2c91, .to = 0x2c90 }, .{ .from = 0x2c93, .to = 0x2c92 }, .{ .from = 0x2c95, .to = 0x2c94 }, .{ .from = 0x2c97, .to = 0x2c96 }, 
    .{ .from = 0x2c99, .to = 0x2c98 }, .{ .from = 0x2c9b, .to = 0x2c9a }, .{ .from = 0x2c9d, .to = 0x2c9c }, .{ .from = 0x2c9f, .to = 0x2c9e }, 
    .{ .from = 0x2ca1, .to = 0x2ca0 }, .{ .from = 0x2ca3, .to = 0x2ca2 }, .{ .from = 0x2ca5, .to = 0x2ca4 }, .{ .from = 0x2ca7, .to = 0x2ca6 }, 
    .{ .from = 0x2ca9, .to = 0x2ca8 }, .{ .from = 0x2cab, .to = 0x2caa }, .{ .from = 0x2cad, .to = 0x2cac }, .{ .from = 0x2caf, .to = 0x2cae }, 
    .{ .from = 0x2cb1, .to = 0x2cb0 }, .{ .from = 0x2cb3, .to = 0x2cb2 }, .{ .from = 0x2cb5, .to = 0x2cb4 }, .{ .from = 0x2cb7, .to = 0x2cb6 }, 
    .{ .from = 0x2cb9, .to = 0x2cb8 }, .{ .from = 0x2cbb, .to = 0x2cba }, .{ .from = 0x2cbd, .to = 0x2cbc }, .{ .from = 0x2cbf, .to = 0x2cbe }, 
    .{ .from = 0x2cc1, .to = 0x2cc0 }, .{ .from = 0x2cc3, .to = 0x2cc2 }, .{ .from = 0x2cc5, .to = 0x2cc4 }, .{ .from = 0x2cc7, .to = 0x2cc6 }, 
    .{ .from = 0x2cc9, .to = 0x2cc8 }, .{ .from = 0x2ccb, .to = 0x2cca }, .{ .from = 0x2ccd, .to = 0x2ccc }, .{ .from = 0x2ccf, .to = 0x2cce }, 
    .{ .from = 0x2cd1, .to = 0x2cd0 }, .{ .from = 0x2cd3, .to = 0x2cd2 }, .{ .from = 0x2cd5, .to = 0x2cd4 }, .{ .from = 0x2cd7, .to = 0x2cd6 }, 
    .{ .from = 0x2cd9, .to = 0x2cd8 }, .{ .from = 0x2cdb, .to = 0x2cda }, .{ .from = 0x2cdd, .to = 0x2cdc }, .{ .from = 0x2cdf, .to = 0x2cde }, 
    .{ .from = 0x2ce1, .to = 0x2ce0 }, .{ .from = 0x2ce3, .to = 0x2ce2 }, .{ .from = 0x2cec, .to = 0x2ceb }, .{ .from = 0x2cee, .to = 0x2ced }, 
    .{ .from = 0x2cf3, .to = 0x2cf2 }, .{ .from = 0x2d00, .to = 0x10a0 }, .{ .from = 0x2d01, .to = 0x10a1 }, .{ .from = 0x2d02, .to = 0x10a2 }, 
    .{ .from = 0x2d03, .to = 0x10a3 }, .{ .from = 0x2d04, .to = 0x10a4 }, .{ .from = 0x2d05, .to = 0x10a5 }, .{ .from = 0x2d06, .to = 0x10a6 }, 
    .{ .from = 0x2d07, .to = 0x10a7 }, .{ .from = 0x2d08, .to = 0x10a8 }, .{ .from = 0x2d09, .to = 0x10a9 }, .{ .from = 0x2d0a, .to = 0x10aa }, 
    .{ .from = 0x2d0b, .to = 0x10ab }, .{ .from = 0x2d0c, .to = 0x10ac }, .{ .from = 0x2d0d, .to = 0x10ad }, .{ .from = 0x2d0e, .to = 0x10ae }, 
    .{ .from = 0x2d0f, .to = 0x10af }, .{ .from = 0x2d10, .to = 0x10b0 }, .{ .from = 0x2d11, .to = 0x10b1 }, .{ .from = 0x2d12, .to = 0x10b2 }, 
    .{ .from = 0x2d13, .to = 0x10b3 }, .{ .from = 0x2d14, .to = 0x10b4 }, .{ .from = 0x2d15, .to = 0x10b5 }, .{ .from = 0x2d16, .to = 0x10b6 }, 
    .{ .from = 0x2d17, .to = 0x10b7 }, .{ .from = 0x2d18, .to = 0x10b8 }, .{ .from = 0x2d19, .to = 0x10b9 }, .{ .from = 0x2d1a, .to = 0x10ba }, 
    .{ .from = 0x2d1b, .to = 0x10bb }, .{ .from = 0x2d1c, .to = 0x10bc }, .{ .from = 0x2d1d, .to = 0x10bd }, .{ .from = 0x2d1e, .to = 0x10be }, 
    .{ .from = 0x2d1f, .to = 0x10bf }, .{ .from = 0x2d20, .to = 0x10c0 }, .{ .from = 0x2d21, .to = 0x10c1 }, .{ .from = 0x2d22, .to = 0x10c2 }, 
    .{ .from = 0x2d23, .to = 0x10c3 }, .{ .from = 0x2d24, .to = 0x10c4 }, .{ .from = 0x2d25, .to = 0x10c5 }, .{ .from = 0x2d27, .to = 0x10c7 }, 
    .{ .from = 0x2d2d, .to = 0x10cd }, .{ .from = 0xa641, .to = 0xa640 }, .{ .from = 0xa643, .to = 0xa642 }, .{ .from = 0xa645, .to = 0xa644 }, 
    .{ .from = 0xa647, .to = 0xa646 }, .{ .from = 0xa649, .to = 0xa648 }, .{ .from = 0xa64b, .to = 0xa64a }, .{ .from = 0xa64d, .to = 0xa64c }, 
    .{ .from = 0xa64f, .to = 0xa64e }, .{ .from = 0xa651, .to = 0xa650 }, .{ .from = 0xa653, .to = 0xa652 }, .{ .from = 0xa655, .to = 0xa654 }, 
    .{ .from = 0xa657, .to = 0xa656 }, .{ .from = 0xa659, .to = 0xa658 }, .{ .from = 0xa65b, .to = 0xa65a }, .{ .from = 0xa65d, .to = 0xa65c }, 
    .{ .from = 0xa65f, .to = 0xa65e }, .{ .from = 0xa661, .to = 0xa660 }, .{ .from = 0xa663, .to = 0xa662 }, .{ .from = 0xa665, .to = 0xa664 }, 
    .{ .from = 0xa667, .to = 0xa666 }, .{ .from = 0xa669, .to = 0xa668 }, .{ .from = 0xa66b, .to = 0xa66a }, .{ .from = 0xa66d, .to = 0xa66c }, 
    .{ .from = 0xa681, .to = 0xa680 }, .{ .from = 0xa683, .to = 0xa682 }, .{ .from = 0xa685, .to = 0xa684 }, .{ .from = 0xa687, .to = 0xa686 }, 
    .{ .from = 0xa689, .to = 0xa688 }, .{ .from = 0xa68b, .to = 0xa68a }, .{ .from = 0xa68d, .to = 0xa68c }, .{ .from = 0xa68f, .to = 0xa68e }, 
    .{ .from = 0xa691, .to = 0xa690 }, .{ .from = 0xa693, .to = 0xa692 }, .{ .from = 0xa695, .to = 0xa694 }, .{ .from = 0xa697, .to = 0xa696 }, 
    .{ .from = 0xa699, .to = 0xa698 }, .{ .from = 0xa69b, .to = 0xa69a }, .{ .from = 0xa723, .to = 0xa722 }, .{ .from = 0xa725, .to = 0xa724 }, 
    .{ .from = 0xa727, .to = 0xa726 }, .{ .from = 0xa729, .to = 0xa728 }, .{ .from = 0xa72b, .to = 0xa72a }, .{ .from = 0xa72d, .to = 0xa72c }, 
    .{ .from = 0xa72f, .to = 0xa72e }, .{ .from = 0xa733, .to = 0xa732 }, .{ .from = 0xa735, .to = 0xa734 }, .{ .from = 0xa737, .to = 0xa736 }, 
    .{ .from = 0xa739, .to = 0xa738 }, .{ .from = 0xa73b, .to = 0xa73a }, .{ .from = 0xa73d, .to = 0xa73c }, .{ .from = 0xa73f, .to = 0xa73e }, 
    .{ .from = 0xa741, .to = 0xa740 }, .{ .from = 0xa743, .to = 0xa742 }, .{ .from = 0xa745, .to = 0xa744 }, .{ .from = 0xa747, .to = 0xa746 }, 
    .{ .from = 0xa749, .to = 0xa748 }, .{ .from = 0xa74b, .to = 0xa74a }, .{ .from = 0xa74d, .to = 0xa74c }, .{ .from = 0xa74f, .to = 0xa74e }, 
    .{ .from = 0xa751, .to = 0xa750 }, .{ .from = 0xa753, .to = 0xa752 }, .{ .from = 0xa755, .to = 0xa754 }, .{ .from = 0xa757, .to = 0xa756 }, 
    .{ .from = 0xa759, .to = 0xa758 }, .{ .from = 0xa75b, .to = 0xa75a }, .{ .from = 0xa75d, .to = 0xa75c }, .{ .from = 0xa75f, .to = 0xa75e }, 
    .{ .from = 0xa761, .to = 0xa760 }, .{ .from = 0xa763, .to = 0xa762 }, .{ .from = 0xa765, .to = 0xa764 }, .{ .from = 0xa767, .to = 0xa766 }, 
    .{ .from = 0xa769, .to = 0xa768 }, .{ .from = 0xa76b, .to = 0xa76a }, .{ .from = 0xa76d, .to = 0xa76c }, .{ .from = 0xa76f, .to = 0xa76e }, 
    .{ .from = 0xa77a, .to = 0xa779 }, .{ .from = 0xa77c, .to = 0xa77b }, .{ .from = 0xa77f, .to = 0xa77e }, .{ .from = 0xa781, .to = 0xa780 }, 
    .{ .from = 0xa783, .to = 0xa782 }, .{ .from = 0xa785, .to = 0xa784 }, .{ .from = 0xa787, .to = 0xa786 }, .{ .from = 0xa78c, .to = 0xa78b }, 
    .{ .from = 0xa791, .to = 0xa790 }, .{ .from = 0xa793, .to = 0xa792 }, .{ .from = 0xa794, .to = 0xa7c4 }, .{ .from = 0xa797, .to = 0xa796 }, 
    .{ .from = 0xa799, .to = 0xa798 }, .{ .from = 0xa79b, .to = 0xa79a }, .{ .from = 0xa79d, .to = 0xa79c }, .{ .from = 0xa79f, .to = 0xa79e }, 
    .{ .from = 0xa7a1, .to = 0xa7a0 }, .{ .from = 0xa7a3, .to = 0xa7a2 }, .{ .from = 0xa7a5, .to = 0xa7a4 }, .{ .from = 0xa7a7, .to = 0xa7a6 }, 
    .{ .from = 0xa7a9, .to = 0xa7a8 }, .{ .from = 0xa7b5, .to = 0xa7b4 }, .{ .from = 0xa7b7, .to = 0xa7b6 }, .{ .from = 0xa7b9, .to = 0xa7b8 }, 
    .{ .from = 0xa7bb, .to = 0xa7ba }, .{ .from = 0xa7bd, .to = 0xa7bc }, .{ .from = 0xa7bf, .to = 0xa7be }, .{ .from = 0xa7c1, .to = 0xa7c0 }, 
    .{ .from = 0xa7c3, .to = 0xa7c2 }, .{ .from = 0xa7c8, .to = 0xa7c7 }, .{ .from = 0xa7ca, .to = 0xa7c9 }, .{ .from = 0xa7cd, .to = 0xa7cc }, 
    .{ .from = 0xa7cf, .to = 0xa7ce }, .{ .from = 0xa7d1, .to = 0xa7d0 }, .{ .from = 0xa7d3, .to = 0xa7d2 }, .{ .from = 0xa7d5, .to = 0xa7d4 }, 
    .{ .from = 0xa7d7, .to = 0xa7d6 }, .{ .from = 0xa7d9, .to = 0xa7d8 }, .{ .from = 0xa7db, .to = 0xa7da }, .{ .from = 0xa7f6, .to = 0xa7f5 }, 
    .{ .from = 0xab53, .to = 0xa7b3 }, .{ .from = 0xab70, .to = 0x13a0 }, .{ .from = 0xab71, .to = 0x13a1 }, .{ .from = 0xab72, .to = 0x13a2 }, 
    .{ .from = 0xab73, .to = 0x13a3 }, .{ .from = 0xab74, .to = 0x13a4 }, .{ .from = 0xab75, .to = 0x13a5 }, .{ .from = 0xab76, .to = 0x13a6 }, 
    .{ .from = 0xab77, .to = 0x13a7 }, .{ .from = 0xab78, .to = 0x13a8 }, .{ .from = 0xab79, .to = 0x13a9 }, .{ .from = 0xab7a, .to = 0x13aa }, 
    .{ .from = 0xab7b, .to = 0x13ab }, .{ .from = 0xab7c, .to = 0x13ac }, .{ .from = 0xab7d, .to = 0x13ad }, .{ .from = 0xab7e, .to = 0x13ae }, 
    .{ .from = 0xab7f, .to = 0x13af }, .{ .from = 0xab80, .to = 0x13b0 }, .{ .from = 0xab81, .to = 0x13b1 }, .{ .from = 0xab82, .to = 0x13b2 }, 
    .{ .from = 0xab83, .to = 0x13b3 }, .{ .from = 0xab84, .to = 0x13b4 }, .{ .from = 0xab85, .to = 0x13b5 }, .{ .from = 0xab86, .to = 0x13b6 }, 
    .{ .from = 0xab87, .to = 0x13b7 }, .{ .from = 0xab88, .to = 0x13b8 }, .{ .from = 0xab89, .to = 0x13b9 }, .{ .from = 0xab8a, .to = 0x13ba }, 
    .{ .from = 0xab8b, .to = 0x13bb }, .{ .from = 0xab8c, .to = 0x13bc }, .{ .from = 0xab8d, .to = 0x13bd }, .{ .from = 0xab8e, .to = 0x13be }, 
    .{ .from = 0xab8f, .to = 0x13bf }, .{ .from = 0xab90, .to = 0x13c0 }, .{ .from = 0xab91, .to = 0x13c1 }, .{ .from = 0xab92, .to = 0x13c2 }, 
    .{ .from = 0xab93, .to = 0x13c3 }, .{ .from = 0xab94, .to = 0x13c4 }, .{ .from = 0xab95, .to = 0x13c5 }, .{ .from = 0xab96, .to = 0x13c6 }, 
    .{ .from = 0xab97, .to = 0x13c7 }, .{ .from = 0xab98, .to = 0x13c8 }, .{ .from = 0xab99, .to = 0x13c9 }, .{ .from = 0xab9a, .to = 0x13ca }, 
    .{ .from = 0xab9b, .to = 0x13cb }, .{ .from = 0xab9c, .to = 0x13cc }, .{ .from = 0xab9d, .to = 0x13cd }, .{ .from = 0xab9e, .to = 0x13ce }, 
    .{ .from = 0xab9f, .to = 0x13cf }, .{ .from = 0xaba0, .to = 0x13d0 }, .{ .from = 0xaba1, .to = 0x13d1 }, .{ .from = 0xaba2, .to = 0x13d2 }, 
    .{ .from = 0xaba3, .to = 0x13d3 }, .{ .from = 0xaba4, .to = 0x13d4 }, .{ .from = 0xaba5, .to = 0x13d5 }, .{ .from = 0xaba6, .to = 0x13d6 }, 
    .{ .from = 0xaba7, .to = 0x13d7 }, .{ .from = 0xaba8, .to = 0x13d8 }, .{ .from = 0xaba9, .to = 0x13d9 }, .{ .from = 0xabaa, .to = 0x13da }, 
    .{ .from = 0xabab, .to = 0x13db }, .{ .from = 0xabac, .to = 0x13dc }, .{ .from = 0xabad, .to = 0x13dd }, .{ .from = 0xabae, .to = 0x13de }, 
    .{ .from = 0xabaf, .to = 0x13df }, .{ .from = 0xabb0, .to = 0x13e0 }, .{ .from = 0xabb1, .to = 0x13e1 }, .{ .from = 0xabb2, .to = 0x13e2 }, 
    .{ .from = 0xabb3, .to = 0x13e3 }, .{ .from = 0xabb4, .to = 0x13e4 }, .{ .from = 0xabb5, .to = 0x13e5 }, .{ .from = 0xabb6, .to = 0x13e6 }, 
    .{ .from = 0xabb7, .to = 0x13e7 }, .{ .from = 0xabb8, .to = 0x13e8 }, .{ .from = 0xabb9, .to = 0x13e9 }, .{ .from = 0xabba, .to = 0x13ea }, 
    .{ .from = 0xabbb, .to = 0x13eb }, .{ .from = 0xabbc, .to = 0x13ec }, .{ .from = 0xabbd, .to = 0x13ed }, .{ .from = 0xabbe, .to = 0x13ee }, 
    .{ .from = 0xabbf, .to = 0x13ef }, .{ .from = 0xff41, .to = 0xff21 }, .{ .from = 0xff42, .to = 0xff22 }, .{ .from = 0xff43, .to = 0xff23 }, 
    .{ .from = 0xff44, .to = 0xff24 }, .{ .from = 0xff45, .to = 0xff25 }, .{ .from = 0xff46, .to = 0xff26 }, .{ .from = 0xff47, .to = 0xff27 }, 
    .{ .from = 0xff48, .to = 0xff28 }, .{ .from = 0xff49, .to = 0xff29 }, .{ .from = 0xff4a, .to = 0xff2a }, .{ .from = 0xff4b, .to = 0xff2b }, 
    .{ .from = 0xff4c, .to = 0xff2c }, .{ .from = 0xff4d, .to = 0xff2d }, .{ .from = 0xff4e, .to = 0xff2e }, .{ .from = 0xff4f, .to = 0xff2f }, 
    .{ .from = 0xff50, .to = 0xff30 }, .{ .from = 0xff51, .to = 0xff31 }, .{ .from = 0xff52, .to = 0xff32 }, .{ .from = 0xff53, .to = 0xff33 }, 
    .{ .from = 0xff54, .to = 0xff34 }, .{ .from = 0xff55, .to = 0xff35 }, .{ .from = 0xff56, .to = 0xff36 }, .{ .from = 0xff57, .to = 0xff37 }, 
    .{ .from = 0xff58, .to = 0xff38 }, .{ .from = 0xff59, .to = 0xff39 }, .{ .from = 0xff5a, .to = 0xff3a }, .{ .from = 0x10428, .to = 0x10400 }, 
    .{ .from = 0x10429, .to = 0x10401 }, .{ .from = 0x1042a, .to = 0x10402 }, .{ .from = 0x1042b, .to = 0x10403 }, .{ .from = 0x1042c, .to = 0x10404 }, 
    .{ .from = 0x1042d, .to = 0x10405 }, .{ .from = 0x1042e, .to = 0x10406 }, .{ .from = 0x1042f, .to = 0x10407 }, .{ .from = 0x10430, .to = 0x10408 }, 
    .{ .from = 0x10431, .to = 0x10409 }, .{ .from = 0x10432, .to = 0x1040a }, .{ .from = 0x10433, .to = 0x1040b }, .{ .from = 0x10434, .to = 0x1040c }, 
    .{ .from = 0x10435, .to = 0x1040d }, .{ .from = 0x10436, .to = 0x1040e }, .{ .from = 0x10437, .to = 0x1040f }, .{ .from = 0x10438, .to = 0x10410 }, 
    .{ .from = 0x10439, .to = 0x10411 }, .{ .from = 0x1043a, .to = 0x10412 }, .{ .from = 0x1043b, .to = 0x10413 }, .{ .from = 0x1043c, .to = 0x10414 }, 
    .{ .from = 0x1043d, .to = 0x10415 }, .{ .from = 0x1043e, .to = 0x10416 }, .{ .from = 0x1043f, .to = 0x10417 }, .{ .from = 0x10440, .to = 0x10418 }, 
    .{ .from = 0x10441, .to = 0x10419 }, .{ .from = 0x10442, .to = 0x1041a }, .{ .from = 0x10443, .to = 0x1041b }, .{ .from = 0x10444, .to = 0x1041c }, 
    .{ .from = 0x10445, .to = 0x1041d }, .{ .from = 0x10446, .to = 0x1041e }, .{ .from = 0x10447, .to = 0x1041f }, .{ .from = 0x10448, .to = 0x10420 }, 
    .{ .from = 0x10449, .to = 0x10421 }, .{ .from = 0x1044a, .to = 0x10422 }, .{ .from = 0x1044b, .to = 0x10423 }, .{ .from = 0x1044c, .to = 0x10424 }, 
    .{ .from = 0x1044d, .to = 0x10425 }, .{ .from = 0x1044e, .to = 0x10426 }, .{ .from = 0x1044f, .to = 0x10427 }, .{ .from = 0x104d8, .to = 0x104b0 }, 
    .{ .from = 0x104d9, .to = 0x104b1 }, .{ .from = 0x104da, .to = 0x104b2 }, .{ .from = 0x104db, .to = 0x104b3 }, .{ .from = 0x104dc, .to = 0x104b4 }, 
    .{ .from = 0x104dd, .to = 0x104b5 }, .{ .from = 0x104de, .to = 0x104b6 }, .{ .from = 0x104df, .to = 0x104b7 }, .{ .from = 0x104e0, .to = 0x104b8 }, 
    .{ .from = 0x104e1, .to = 0x104b9 }, .{ .from = 0x104e2, .to = 0x104ba }, .{ .from = 0x104e3, .to = 0x104bb }, .{ .from = 0x104e4, .to = 0x104bc }, 
    .{ .from = 0x104e5, .to = 0x104bd }, .{ .from = 0x104e6, .to = 0x104be }, .{ .from = 0x104e7, .to = 0x104bf }, .{ .from = 0x104e8, .to = 0x104c0 }, 
    .{ .from = 0x104e9, .to = 0x104c1 }, .{ .from = 0x104ea, .to = 0x104c2 }, .{ .from = 0x104eb, .to = 0x104c3 }, .{ .from = 0x104ec, .to = 0x104c4 }, 
    .{ .from = 0x104ed, .to = 0x104c5 }, .{ .from = 0x104ee, .to = 0x104c6 }, .{ .from = 0x104ef, .to = 0x104c7 }, .{ .from = 0x104f0, .to = 0x104c8 }, 
    .{ .from = 0x104f1, .to = 0x104c9 }, .{ .from = 0x104f2, .to = 0x104ca }, .{ .from = 0x104f3, .to = 0x104cb }, .{ .from = 0x104f4, .to = 0x104cc }, 
    .{ .from = 0x104f5, .to = 0x104cd }, .{ .from = 0x104f6, .to = 0x104ce }, .{ .from = 0x104f7, .to = 0x104cf }, .{ .from = 0x104f8, .to = 0x104d0 }, 
    .{ .from = 0x104f9, .to = 0x104d1 }, .{ .from = 0x104fa, .to = 0x104d2 }, .{ .from = 0x104fb, .to = 0x104d3 }, .{ .from = 0x10597, .to = 0x10570 }, 
    .{ .from = 0x10598, .to = 0x10571 }, .{ .from = 0x10599, .to = 0x10572 }, .{ .from = 0x1059a, .to = 0x10573 }, .{ .from = 0x1059b, .to = 0x10574 }, 
    .{ .from = 0x1059c, .to = 0x10575 }, .{ .from = 0x1059d, .to = 0x10576 }, .{ .from = 0x1059e, .to = 0x10577 }, .{ .from = 0x1059f, .to = 0x10578 }, 
    .{ .from = 0x105a0, .to = 0x10579 }, .{ .from = 0x105a1, .to = 0x1057a }, .{ .from = 0x105a3, .to = 0x1057c }, .{ .from = 0x105a4, .to = 0x1057d }, 
    .{ .from = 0x105a5, .to = 0x1057e }, .{ .from = 0x105a6, .to = 0x1057f }, .{ .from = 0x105a7, .to = 0x10580 }, .{ .from = 0x105a8, .to = 0x10581 }, 
    .{ .from = 0x105a9, .to = 0x10582 }, .{ .from = 0x105aa, .to = 0x10583 }, .{ .from = 0x105ab, .to = 0x10584 }, .{ .from = 0x105ac, .to = 0x10585 }, 
    .{ .from = 0x105ad, .to = 0x10586 }, .{ .from = 0x105ae, .to = 0x10587 }, .{ .from = 0x105af, .to = 0x10588 }, .{ .from = 0x105b0, .to = 0x10589 }, 
    .{ .from = 0x105b1, .to = 0x1058a }, .{ .from = 0x105b3, .to = 0x1058c }, .{ .from = 0x105b4, .to = 0x1058d }, .{ .from = 0x105b5, .to = 0x1058e }, 
    .{ .from = 0x105b6, .to = 0x1058f }, .{ .from = 0x105b7, .to = 0x10590 }, .{ .from = 0x105b8, .to = 0x10591 }, .{ .from = 0x105b9, .to = 0x10592 }, 
    .{ .from = 0x105bb, .to = 0x10594 }, .{ .from = 0x105bc, .to = 0x10595 }, .{ .from = 0x10cc0, .to = 0x10c80 }, .{ .from = 0x10cc1, .to = 0x10c81 }, 
    .{ .from = 0x10cc2, .to = 0x10c82 }, .{ .from = 0x10cc3, .to = 0x10c83 }, .{ .from = 0x10cc4, .to = 0x10c84 }, .{ .from = 0x10cc5, .to = 0x10c85 }, 
    .{ .from = 0x10cc6, .to = 0x10c86 }, .{ .from = 0x10cc7, .to = 0x10c87 }, .{ .from = 0x10cc8, .to = 0x10c88 }, .{ .from = 0x10cc9, .to = 0x10c89 }, 
    .{ .from = 0x10cca, .to = 0x10c8a }, .{ .from = 0x10ccb, .to = 0x10c8b }, .{ .from = 0x10ccc, .to = 0x10c8c }, .{ .from = 0x10ccd, .to = 0x10c8d }, 
    .{ .from = 0x10cce, .to = 0x10c8e }, .{ .from = 0x10ccf, .to = 0x10c8f }, .{ .from = 0x10cd0, .to = 0x10c90 }, .{ .from = 0x10cd1, .to = 0x10c91 }, 
    .{ .from = 0x10cd2, .to = 0x10c92 }, .{ .from = 0x10cd3, .to = 0x10c93 }, .{ .from = 0x10cd4, .to = 0x10c94 }, .{ .from = 0x10cd5, .to = 0x10c95 }, 
    .{ .from = 0x10cd6, .to = 0x10c96 }, .{ .from = 0x10cd7, .to = 0x10c97 }, .{ .from = 0x10cd8, .to = 0x10c98 }, .{ .from = 0x10cd9, .to = 0x10c99 }, 
    .{ .from = 0x10cda, .to = 0x10c9a }, .{ .from = 0x10cdb, .to = 0x10c9b }, .{ .from = 0x10cdc, .to = 0x10c9c }, .{ .from = 0x10cdd, .to = 0x10c9d }, 
    .{ .from = 0x10cde, .to = 0x10c9e }, .{ .from = 0x10cdf, .to = 0x10c9f }, .{ .from = 0x10ce0, .to = 0x10ca0 }, .{ .from = 0x10ce1, .to = 0x10ca1 }, 
    .{ .from = 0x10ce2, .to = 0x10ca2 }, .{ .from = 0x10ce3, .to = 0x10ca3 }, .{ .from = 0x10ce4, .to = 0x10ca4 }, .{ .from = 0x10ce5, .to = 0x10ca5 }, 
    .{ .from = 0x10ce6, .to = 0x10ca6 }, .{ .from = 0x10ce7, .to = 0x10ca7 }, .{ .from = 0x10ce8, .to = 0x10ca8 }, .{ .from = 0x10ce9, .to = 0x10ca9 }, 
    .{ .from = 0x10cea, .to = 0x10caa }, .{ .from = 0x10ceb, .to = 0x10cab }, .{ .from = 0x10cec, .to = 0x10cac }, .{ .from = 0x10ced, .to = 0x10cad }, 
    .{ .from = 0x10cee, .to = 0x10cae }, .{ .from = 0x10cef, .to = 0x10caf }, .{ .from = 0x10cf0, .to = 0x10cb0 }, .{ .from = 0x10cf1, .to = 0x10cb1 }, 
    .{ .from = 0x10cf2, .to = 0x10cb2 }, .{ .from = 0x10d70, .to = 0x10d50 }, .{ .from = 0x10d71, .to = 0x10d51 }, .{ .from = 0x10d72, .to = 0x10d52 }, 
    .{ .from = 0x10d73, .to = 0x10d53 }, .{ .from = 0x10d74, .to = 0x10d54 }, .{ .from = 0x10d75, .to = 0x10d55 }, .{ .from = 0x10d76, .to = 0x10d56 }, 
    .{ .from = 0x10d77, .to = 0x10d57 }, .{ .from = 0x10d78, .to = 0x10d58 }, .{ .from = 0x10d79, .to = 0x10d59 }, .{ .from = 0x10d7a, .to = 0x10d5a }, 
    .{ .from = 0x10d7b, .to = 0x10d5b }, .{ .from = 0x10d7c, .to = 0x10d5c }, .{ .from = 0x10d7d, .to = 0x10d5d }, .{ .from = 0x10d7e, .to = 0x10d5e }, 
    .{ .from = 0x10d7f, .to = 0x10d5f }, .{ .from = 0x10d80, .to = 0x10d60 }, .{ .from = 0x10d81, .to = 0x10d61 }, .{ .from = 0x10d82, .to = 0x10d62 }, 
    .{ .from = 0x10d83, .to = 0x10d63 }, .{ .from = 0x10d84, .to = 0x10d64 }, .{ .from = 0x10d85, .to = 0x10d65 }, .{ .from = 0x118c0, .to = 0x118a0 }, 
    .{ .from = 0x118c1, .to = 0x118a1 }, .{ .from = 0x118c2, .to = 0x118a2 }, .{ .from = 0x118c3, .to = 0x118a3 }, .{ .from = 0x118c4, .to = 0x118a4 }, 
    .{ .from = 0x118c5, .to = 0x118a5 }, .{ .from = 0x118c6, .to = 0x118a6 }, .{ .from = 0x118c7, .to = 0x118a7 }, .{ .from = 0x118c8, .to = 0x118a8 }, 
    .{ .from = 0x118c9, .to = 0x118a9 }, .{ .from = 0x118ca, .to = 0x118aa }, .{ .from = 0x118cb, .to = 0x118ab }, .{ .from = 0x118cc, .to = 0x118ac }, 
    .{ .from = 0x118cd, .to = 0x118ad }, .{ .from = 0x118ce, .to = 0x118ae }, .{ .from = 0x118cf, .to = 0x118af }, .{ .from = 0x118d0, .to = 0x118b0 }, 
    .{ .from = 0x118d1, .to = 0x118b1 }, .{ .from = 0x118d2, .to = 0x118b2 }, .{ .from = 0x118d3, .to = 0x118b3 }, .{ .from = 0x118d4, .to = 0x118b4 }, 
    .{ .from = 0x118d5, .to = 0x118b5 }, .{ .from = 0x118d6, .to = 0x118b6 }, .{ .from = 0x118d7, .to = 0x118b7 }, .{ .from = 0x118d8, .to = 0x118b8 }, 
    .{ .from = 0x118d9, .to = 0x118b9 }, .{ .from = 0x118da, .to = 0x118ba }, .{ .from = 0x118db, .to = 0x118bb }, .{ .from = 0x118dc, .to = 0x118bc }, 
    .{ .from = 0x118dd, .to = 0x118bd }, .{ .from = 0x118de, .to = 0x118be }, .{ .from = 0x118df, .to = 0x118bf }, .{ .from = 0x16e60, .to = 0x16e40 }, 
    .{ .from = 0x16e61, .to = 0x16e41 }, .{ .from = 0x16e62, .to = 0x16e42 }, .{ .from = 0x16e63, .to = 0x16e43 }, .{ .from = 0x16e64, .to = 0x16e44 }, 
    .{ .from = 0x16e65, .to = 0x16e45 }, .{ .from = 0x16e66, .to = 0x16e46 }, .{ .from = 0x16e67, .to = 0x16e47 }, .{ .from = 0x16e68, .to = 0x16e48 }, 
    .{ .from = 0x16e69, .to = 0x16e49 }, .{ .from = 0x16e6a, .to = 0x16e4a }, .{ .from = 0x16e6b, .to = 0x16e4b }, .{ .from = 0x16e6c, .to = 0x16e4c }, 
    .{ .from = 0x16e6d, .to = 0x16e4d }, .{ .from = 0x16e6e, .to = 0x16e4e }, .{ .from = 0x16e6f, .to = 0x16e4f }, .{ .from = 0x16e70, .to = 0x16e50 }, 
    .{ .from = 0x16e71, .to = 0x16e51 }, .{ .from = 0x16e72, .to = 0x16e52 }, .{ .from = 0x16e73, .to = 0x16e53 }, .{ .from = 0x16e74, .to = 0x16e54 }, 
    .{ .from = 0x16e75, .to = 0x16e55 }, .{ .from = 0x16e76, .to = 0x16e56 }, .{ .from = 0x16e77, .to = 0x16e57 }, .{ .from = 0x16e78, .to = 0x16e58 }, 
    .{ .from = 0x16e79, .to = 0x16e59 }, .{ .from = 0x16e7a, .to = 0x16e5a }, .{ .from = 0x16e7b, .to = 0x16e5b }, .{ .from = 0x16e7c, .to = 0x16e5c }, 
    .{ .from = 0x16e7d, .to = 0x16e5d }, .{ .from = 0x16e7e, .to = 0x16e5e }, .{ .from = 0x16e7f, .to = 0x16e5f }, .{ .from = 0x16ebb, .to = 0x16ea0 }, 
    .{ .from = 0x16ebc, .to = 0x16ea1 }, .{ .from = 0x16ebd, .to = 0x16ea2 }, .{ .from = 0x16ebe, .to = 0x16ea3 }, .{ .from = 0x16ebf, .to = 0x16ea4 }, 
    .{ .from = 0x16ec0, .to = 0x16ea5 }, .{ .from = 0x16ec1, .to = 0x16ea6 }, .{ .from = 0x16ec2, .to = 0x16ea7 }, .{ .from = 0x16ec3, .to = 0x16ea8 }, 
    .{ .from = 0x16ec4, .to = 0x16ea9 }, .{ .from = 0x16ec5, .to = 0x16eaa }, .{ .from = 0x16ec6, .to = 0x16eab }, .{ .from = 0x16ec7, .to = 0x16eac }, 
    .{ .from = 0x16ec8, .to = 0x16ead }, .{ .from = 0x16ec9, .to = 0x16eae }, .{ .from = 0x16eca, .to = 0x16eaf }, .{ .from = 0x16ecb, .to = 0x16eb0 }, 
    .{ .from = 0x16ecc, .to = 0x16eb1 }, .{ .from = 0x16ecd, .to = 0x16eb2 }, .{ .from = 0x16ece, .to = 0x16eb3 }, .{ .from = 0x16ecf, .to = 0x16eb4 }, 
    .{ .from = 0x16ed0, .to = 0x16eb5 }, .{ .from = 0x16ed1, .to = 0x16eb6 }, .{ .from = 0x16ed2, .to = 0x16eb7 }, .{ .from = 0x16ed3, .to = 0x16eb8 }, 
    .{ .from = 0x1e922, .to = 0x1e900 }, .{ .from = 0x1e923, .to = 0x1e901 }, .{ .from = 0x1e924, .to = 0x1e902 }, .{ .from = 0x1e925, .to = 0x1e903 }, 
    .{ .from = 0x1e926, .to = 0x1e904 }, .{ .from = 0x1e927, .to = 0x1e905 }, .{ .from = 0x1e928, .to = 0x1e906 }, .{ .from = 0x1e929, .to = 0x1e907 }, 
    .{ .from = 0x1e92a, .to = 0x1e908 }, .{ .from = 0x1e92b, .to = 0x1e909 }, .{ .from = 0x1e92c, .to = 0x1e90a }, .{ .from = 0x1e92d, .to = 0x1e90b }, 
    .{ .from = 0x1e92e, .to = 0x1e90c }, .{ .from = 0x1e92f, .to = 0x1e90d }, .{ .from = 0x1e930, .to = 0x1e90e }, .{ .from = 0x1e931, .to = 0x1e90f }, 
    .{ .from = 0x1e932, .to = 0x1e910 }, .{ .from = 0x1e933, .to = 0x1e911 }, .{ .from = 0x1e934, .to = 0x1e912 }, .{ .from = 0x1e935, .to = 0x1e913 }, 
    .{ .from = 0x1e936, .to = 0x1e914 }, .{ .from = 0x1e937, .to = 0x1e915 }, .{ .from = 0x1e938, .to = 0x1e916 }, .{ .from = 0x1e939, .to = 0x1e917 }, 
    .{ .from = 0x1e93a, .to = 0x1e918 }, .{ .from = 0x1e93b, .to = 0x1e919 }, .{ .from = 0x1e93c, .to = 0x1e91a }, .{ .from = 0x1e93d, .to = 0x1e91b }, 
    .{ .from = 0x1e93e, .to = 0x1e91c }, .{ .from = 0x1e93f, .to = 0x1e91d }, .{ .from = 0x1e940, .to = 0x1e91e }, .{ .from = 0x1e941, .to = 0x1e91f }, 
    .{ .from = 0x1e942, .to = 0x1e920 }, .{ .from = 0x1e943, .to = 0x1e921 }, 
};
const lower_map = [_]CaseMap{
    .{ .from = 0x41, .to = 0x61 }, .{ .from = 0x42, .to = 0x62 }, .{ .from = 0x43, .to = 0x63 }, .{ .from = 0x44, .to = 0x64 }, 
    .{ .from = 0x45, .to = 0x65 }, .{ .from = 0x46, .to = 0x66 }, .{ .from = 0x47, .to = 0x67 }, .{ .from = 0x48, .to = 0x68 }, 
    .{ .from = 0x49, .to = 0x69 }, .{ .from = 0x4a, .to = 0x6a }, .{ .from = 0x4b, .to = 0x6b }, .{ .from = 0x4c, .to = 0x6c }, 
    .{ .from = 0x4d, .to = 0x6d }, .{ .from = 0x4e, .to = 0x6e }, .{ .from = 0x4f, .to = 0x6f }, .{ .from = 0x50, .to = 0x70 }, 
    .{ .from = 0x51, .to = 0x71 }, .{ .from = 0x52, .to = 0x72 }, .{ .from = 0x53, .to = 0x73 }, .{ .from = 0x54, .to = 0x74 }, 
    .{ .from = 0x55, .to = 0x75 }, .{ .from = 0x56, .to = 0x76 }, .{ .from = 0x57, .to = 0x77 }, .{ .from = 0x58, .to = 0x78 }, 
    .{ .from = 0x59, .to = 0x79 }, .{ .from = 0x5a, .to = 0x7a }, .{ .from = 0xc0, .to = 0xe0 }, .{ .from = 0xc1, .to = 0xe1 }, 
    .{ .from = 0xc2, .to = 0xe2 }, .{ .from = 0xc3, .to = 0xe3 }, .{ .from = 0xc4, .to = 0xe4 }, .{ .from = 0xc5, .to = 0xe5 }, 
    .{ .from = 0xc6, .to = 0xe6 }, .{ .from = 0xc7, .to = 0xe7 }, .{ .from = 0xc8, .to = 0xe8 }, .{ .from = 0xc9, .to = 0xe9 }, 
    .{ .from = 0xca, .to = 0xea }, .{ .from = 0xcb, .to = 0xeb }, .{ .from = 0xcc, .to = 0xec }, .{ .from = 0xcd, .to = 0xed }, 
    .{ .from = 0xce, .to = 0xee }, .{ .from = 0xcf, .to = 0xef }, .{ .from = 0xd0, .to = 0xf0 }, .{ .from = 0xd1, .to = 0xf1 }, 
    .{ .from = 0xd2, .to = 0xf2 }, .{ .from = 0xd3, .to = 0xf3 }, .{ .from = 0xd4, .to = 0xf4 }, .{ .from = 0xd5, .to = 0xf5 }, 
    .{ .from = 0xd6, .to = 0xf6 }, .{ .from = 0xd8, .to = 0xf8 }, .{ .from = 0xd9, .to = 0xf9 }, .{ .from = 0xda, .to = 0xfa }, 
    .{ .from = 0xdb, .to = 0xfb }, .{ .from = 0xdc, .to = 0xfc }, .{ .from = 0xdd, .to = 0xfd }, .{ .from = 0xde, .to = 0xfe }, 
    .{ .from = 0x100, .to = 0x101 }, .{ .from = 0x102, .to = 0x103 }, .{ .from = 0x104, .to = 0x105 }, .{ .from = 0x106, .to = 0x107 }, 
    .{ .from = 0x108, .to = 0x109 }, .{ .from = 0x10a, .to = 0x10b }, .{ .from = 0x10c, .to = 0x10d }, .{ .from = 0x10e, .to = 0x10f }, 
    .{ .from = 0x110, .to = 0x111 }, .{ .from = 0x112, .to = 0x113 }, .{ .from = 0x114, .to = 0x115 }, .{ .from = 0x116, .to = 0x117 }, 
    .{ .from = 0x118, .to = 0x119 }, .{ .from = 0x11a, .to = 0x11b }, .{ .from = 0x11c, .to = 0x11d }, .{ .from = 0x11e, .to = 0x11f }, 
    .{ .from = 0x120, .to = 0x121 }, .{ .from = 0x122, .to = 0x123 }, .{ .from = 0x124, .to = 0x125 }, .{ .from = 0x126, .to = 0x127 }, 
    .{ .from = 0x128, .to = 0x129 }, .{ .from = 0x12a, .to = 0x12b }, .{ .from = 0x12c, .to = 0x12d }, .{ .from = 0x12e, .to = 0x12f }, 
    .{ .from = 0x132, .to = 0x133 }, .{ .from = 0x134, .to = 0x135 }, .{ .from = 0x136, .to = 0x137 }, .{ .from = 0x139, .to = 0x13a }, 
    .{ .from = 0x13b, .to = 0x13c }, .{ .from = 0x13d, .to = 0x13e }, .{ .from = 0x13f, .to = 0x140 }, .{ .from = 0x141, .to = 0x142 }, 
    .{ .from = 0x143, .to = 0x144 }, .{ .from = 0x145, .to = 0x146 }, .{ .from = 0x147, .to = 0x148 }, .{ .from = 0x14a, .to = 0x14b }, 
    .{ .from = 0x14c, .to = 0x14d }, .{ .from = 0x14e, .to = 0x14f }, .{ .from = 0x150, .to = 0x151 }, .{ .from = 0x152, .to = 0x153 }, 
    .{ .from = 0x154, .to = 0x155 }, .{ .from = 0x156, .to = 0x157 }, .{ .from = 0x158, .to = 0x159 }, .{ .from = 0x15a, .to = 0x15b }, 
    .{ .from = 0x15c, .to = 0x15d }, .{ .from = 0x15e, .to = 0x15f }, .{ .from = 0x160, .to = 0x161 }, .{ .from = 0x162, .to = 0x163 }, 
    .{ .from = 0x164, .to = 0x165 }, .{ .from = 0x166, .to = 0x167 }, .{ .from = 0x168, .to = 0x169 }, .{ .from = 0x16a, .to = 0x16b }, 
    .{ .from = 0x16c, .to = 0x16d }, .{ .from = 0x16e, .to = 0x16f }, .{ .from = 0x170, .to = 0x171 }, .{ .from = 0x172, .to = 0x173 }, 
    .{ .from = 0x174, .to = 0x175 }, .{ .from = 0x176, .to = 0x177 }, .{ .from = 0x178, .to = 0xff }, .{ .from = 0x179, .to = 0x17a }, 
    .{ .from = 0x17b, .to = 0x17c }, .{ .from = 0x17d, .to = 0x17e }, .{ .from = 0x181, .to = 0x253 }, .{ .from = 0x182, .to = 0x183 }, 
    .{ .from = 0x184, .to = 0x185 }, .{ .from = 0x186, .to = 0x254 }, .{ .from = 0x187, .to = 0x188 }, .{ .from = 0x189, .to = 0x256 }, 
    .{ .from = 0x18a, .to = 0x257 }, .{ .from = 0x18b, .to = 0x18c }, .{ .from = 0x18e, .to = 0x1dd }, .{ .from = 0x18f, .to = 0x259 }, 
    .{ .from = 0x190, .to = 0x25b }, .{ .from = 0x191, .to = 0x192 }, .{ .from = 0x193, .to = 0x260 }, .{ .from = 0x194, .to = 0x263 }, 
    .{ .from = 0x196, .to = 0x269 }, .{ .from = 0x197, .to = 0x268 }, .{ .from = 0x198, .to = 0x199 }, .{ .from = 0x19c, .to = 0x26f }, 
    .{ .from = 0x19d, .to = 0x272 }, .{ .from = 0x19f, .to = 0x275 }, .{ .from = 0x1a0, .to = 0x1a1 }, .{ .from = 0x1a2, .to = 0x1a3 }, 
    .{ .from = 0x1a4, .to = 0x1a5 }, .{ .from = 0x1a6, .to = 0x280 }, .{ .from = 0x1a7, .to = 0x1a8 }, .{ .from = 0x1a9, .to = 0x283 }, 
    .{ .from = 0x1ac, .to = 0x1ad }, .{ .from = 0x1ae, .to = 0x288 }, .{ .from = 0x1af, .to = 0x1b0 }, .{ .from = 0x1b1, .to = 0x28a }, 
    .{ .from = 0x1b2, .to = 0x28b }, .{ .from = 0x1b3, .to = 0x1b4 }, .{ .from = 0x1b5, .to = 0x1b6 }, .{ .from = 0x1b7, .to = 0x292 }, 
    .{ .from = 0x1b8, .to = 0x1b9 }, .{ .from = 0x1bc, .to = 0x1bd }, .{ .from = 0x1c4, .to = 0x1c6 }, .{ .from = 0x1c5, .to = 0x1c6 }, 
    .{ .from = 0x1c7, .to = 0x1c9 }, .{ .from = 0x1c8, .to = 0x1c9 }, .{ .from = 0x1ca, .to = 0x1cc }, .{ .from = 0x1cb, .to = 0x1cc }, 
    .{ .from = 0x1cd, .to = 0x1ce }, .{ .from = 0x1cf, .to = 0x1d0 }, .{ .from = 0x1d1, .to = 0x1d2 }, .{ .from = 0x1d3, .to = 0x1d4 }, 
    .{ .from = 0x1d5, .to = 0x1d6 }, .{ .from = 0x1d7, .to = 0x1d8 }, .{ .from = 0x1d9, .to = 0x1da }, .{ .from = 0x1db, .to = 0x1dc }, 
    .{ .from = 0x1de, .to = 0x1df }, .{ .from = 0x1e0, .to = 0x1e1 }, .{ .from = 0x1e2, .to = 0x1e3 }, .{ .from = 0x1e4, .to = 0x1e5 }, 
    .{ .from = 0x1e6, .to = 0x1e7 }, .{ .from = 0x1e8, .to = 0x1e9 }, .{ .from = 0x1ea, .to = 0x1eb }, .{ .from = 0x1ec, .to = 0x1ed }, 
    .{ .from = 0x1ee, .to = 0x1ef }, .{ .from = 0x1f1, .to = 0x1f3 }, .{ .from = 0x1f2, .to = 0x1f3 }, .{ .from = 0x1f4, .to = 0x1f5 }, 
    .{ .from = 0x1f6, .to = 0x195 }, .{ .from = 0x1f7, .to = 0x1bf }, .{ .from = 0x1f8, .to = 0x1f9 }, .{ .from = 0x1fa, .to = 0x1fb }, 
    .{ .from = 0x1fc, .to = 0x1fd }, .{ .from = 0x1fe, .to = 0x1ff }, .{ .from = 0x200, .to = 0x201 }, .{ .from = 0x202, .to = 0x203 }, 
    .{ .from = 0x204, .to = 0x205 }, .{ .from = 0x206, .to = 0x207 }, .{ .from = 0x208, .to = 0x209 }, .{ .from = 0x20a, .to = 0x20b }, 
    .{ .from = 0x20c, .to = 0x20d }, .{ .from = 0x20e, .to = 0x20f }, .{ .from = 0x210, .to = 0x211 }, .{ .from = 0x212, .to = 0x213 }, 
    .{ .from = 0x214, .to = 0x215 }, .{ .from = 0x216, .to = 0x217 }, .{ .from = 0x218, .to = 0x219 }, .{ .from = 0x21a, .to = 0x21b }, 
    .{ .from = 0x21c, .to = 0x21d }, .{ .from = 0x21e, .to = 0x21f }, .{ .from = 0x220, .to = 0x19e }, .{ .from = 0x222, .to = 0x223 }, 
    .{ .from = 0x224, .to = 0x225 }, .{ .from = 0x226, .to = 0x227 }, .{ .from = 0x228, .to = 0x229 }, .{ .from = 0x22a, .to = 0x22b }, 
    .{ .from = 0x22c, .to = 0x22d }, .{ .from = 0x22e, .to = 0x22f }, .{ .from = 0x230, .to = 0x231 }, .{ .from = 0x232, .to = 0x233 }, 
    .{ .from = 0x23a, .to = 0x2c65 }, .{ .from = 0x23b, .to = 0x23c }, .{ .from = 0x23d, .to = 0x19a }, .{ .from = 0x23e, .to = 0x2c66 }, 
    .{ .from = 0x241, .to = 0x242 }, .{ .from = 0x243, .to = 0x180 }, .{ .from = 0x244, .to = 0x289 }, .{ .from = 0x245, .to = 0x28c }, 
    .{ .from = 0x246, .to = 0x247 }, .{ .from = 0x248, .to = 0x249 }, .{ .from = 0x24a, .to = 0x24b }, .{ .from = 0x24c, .to = 0x24d }, 
    .{ .from = 0x24e, .to = 0x24f }, .{ .from = 0x370, .to = 0x371 }, .{ .from = 0x372, .to = 0x373 }, .{ .from = 0x376, .to = 0x377 }, 
    .{ .from = 0x37f, .to = 0x3f3 }, .{ .from = 0x386, .to = 0x3ac }, .{ .from = 0x388, .to = 0x3ad }, .{ .from = 0x389, .to = 0x3ae }, 
    .{ .from = 0x38a, .to = 0x3af }, .{ .from = 0x38c, .to = 0x3cc }, .{ .from = 0x38e, .to = 0x3cd }, .{ .from = 0x38f, .to = 0x3ce }, 
    .{ .from = 0x391, .to = 0x3b1 }, .{ .from = 0x392, .to = 0x3b2 }, .{ .from = 0x393, .to = 0x3b3 }, .{ .from = 0x394, .to = 0x3b4 }, 
    .{ .from = 0x395, .to = 0x3b5 }, .{ .from = 0x396, .to = 0x3b6 }, .{ .from = 0x397, .to = 0x3b7 }, .{ .from = 0x398, .to = 0x3b8 }, 
    .{ .from = 0x399, .to = 0x3b9 }, .{ .from = 0x39a, .to = 0x3ba }, .{ .from = 0x39b, .to = 0x3bb }, .{ .from = 0x39c, .to = 0x3bc }, 
    .{ .from = 0x39d, .to = 0x3bd }, .{ .from = 0x39e, .to = 0x3be }, .{ .from = 0x39f, .to = 0x3bf }, .{ .from = 0x3a0, .to = 0x3c0 }, 
    .{ .from = 0x3a1, .to = 0x3c1 }, .{ .from = 0x3a3, .to = 0x3c3 }, .{ .from = 0x3a4, .to = 0x3c4 }, .{ .from = 0x3a5, .to = 0x3c5 }, 
    .{ .from = 0x3a6, .to = 0x3c6 }, .{ .from = 0x3a7, .to = 0x3c7 }, .{ .from = 0x3a8, .to = 0x3c8 }, .{ .from = 0x3a9, .to = 0x3c9 }, 
    .{ .from = 0x3aa, .to = 0x3ca }, .{ .from = 0x3ab, .to = 0x3cb }, .{ .from = 0x3cf, .to = 0x3d7 }, .{ .from = 0x3d8, .to = 0x3d9 }, 
    .{ .from = 0x3da, .to = 0x3db }, .{ .from = 0x3dc, .to = 0x3dd }, .{ .from = 0x3de, .to = 0x3df }, .{ .from = 0x3e0, .to = 0x3e1 }, 
    .{ .from = 0x3e2, .to = 0x3e3 }, .{ .from = 0x3e4, .to = 0x3e5 }, .{ .from = 0x3e6, .to = 0x3e7 }, .{ .from = 0x3e8, .to = 0x3e9 }, 
    .{ .from = 0x3ea, .to = 0x3eb }, .{ .from = 0x3ec, .to = 0x3ed }, .{ .from = 0x3ee, .to = 0x3ef }, .{ .from = 0x3f4, .to = 0x3b8 }, 
    .{ .from = 0x3f7, .to = 0x3f8 }, .{ .from = 0x3f9, .to = 0x3f2 }, .{ .from = 0x3fa, .to = 0x3fb }, .{ .from = 0x3fd, .to = 0x37b }, 
    .{ .from = 0x3fe, .to = 0x37c }, .{ .from = 0x3ff, .to = 0x37d }, .{ .from = 0x400, .to = 0x450 }, .{ .from = 0x401, .to = 0x451 }, 
    .{ .from = 0x402, .to = 0x452 }, .{ .from = 0x403, .to = 0x453 }, .{ .from = 0x404, .to = 0x454 }, .{ .from = 0x405, .to = 0x455 }, 
    .{ .from = 0x406, .to = 0x456 }, .{ .from = 0x407, .to = 0x457 }, .{ .from = 0x408, .to = 0x458 }, .{ .from = 0x409, .to = 0x459 }, 
    .{ .from = 0x40a, .to = 0x45a }, .{ .from = 0x40b, .to = 0x45b }, .{ .from = 0x40c, .to = 0x45c }, .{ .from = 0x40d, .to = 0x45d }, 
    .{ .from = 0x40e, .to = 0x45e }, .{ .from = 0x40f, .to = 0x45f }, .{ .from = 0x410, .to = 0x430 }, .{ .from = 0x411, .to = 0x431 }, 
    .{ .from = 0x412, .to = 0x432 }, .{ .from = 0x413, .to = 0x433 }, .{ .from = 0x414, .to = 0x434 }, .{ .from = 0x415, .to = 0x435 }, 
    .{ .from = 0x416, .to = 0x436 }, .{ .from = 0x417, .to = 0x437 }, .{ .from = 0x418, .to = 0x438 }, .{ .from = 0x419, .to = 0x439 }, 
    .{ .from = 0x41a, .to = 0x43a }, .{ .from = 0x41b, .to = 0x43b }, .{ .from = 0x41c, .to = 0x43c }, .{ .from = 0x41d, .to = 0x43d }, 
    .{ .from = 0x41e, .to = 0x43e }, .{ .from = 0x41f, .to = 0x43f }, .{ .from = 0x420, .to = 0x440 }, .{ .from = 0x421, .to = 0x441 }, 
    .{ .from = 0x422, .to = 0x442 }, .{ .from = 0x423, .to = 0x443 }, .{ .from = 0x424, .to = 0x444 }, .{ .from = 0x425, .to = 0x445 }, 
    .{ .from = 0x426, .to = 0x446 }, .{ .from = 0x427, .to = 0x447 }, .{ .from = 0x428, .to = 0x448 }, .{ .from = 0x429, .to = 0x449 }, 
    .{ .from = 0x42a, .to = 0x44a }, .{ .from = 0x42b, .to = 0x44b }, .{ .from = 0x42c, .to = 0x44c }, .{ .from = 0x42d, .to = 0x44d }, 
    .{ .from = 0x42e, .to = 0x44e }, .{ .from = 0x42f, .to = 0x44f }, .{ .from = 0x460, .to = 0x461 }, .{ .from = 0x462, .to = 0x463 }, 
    .{ .from = 0x464, .to = 0x465 }, .{ .from = 0x466, .to = 0x467 }, .{ .from = 0x468, .to = 0x469 }, .{ .from = 0x46a, .to = 0x46b }, 
    .{ .from = 0x46c, .to = 0x46d }, .{ .from = 0x46e, .to = 0x46f }, .{ .from = 0x470, .to = 0x471 }, .{ .from = 0x472, .to = 0x473 }, 
    .{ .from = 0x474, .to = 0x475 }, .{ .from = 0x476, .to = 0x477 }, .{ .from = 0x478, .to = 0x479 }, .{ .from = 0x47a, .to = 0x47b }, 
    .{ .from = 0x47c, .to = 0x47d }, .{ .from = 0x47e, .to = 0x47f }, .{ .from = 0x480, .to = 0x481 }, .{ .from = 0x48a, .to = 0x48b }, 
    .{ .from = 0x48c, .to = 0x48d }, .{ .from = 0x48e, .to = 0x48f }, .{ .from = 0x490, .to = 0x491 }, .{ .from = 0x492, .to = 0x493 }, 
    .{ .from = 0x494, .to = 0x495 }, .{ .from = 0x496, .to = 0x497 }, .{ .from = 0x498, .to = 0x499 }, .{ .from = 0x49a, .to = 0x49b }, 
    .{ .from = 0x49c, .to = 0x49d }, .{ .from = 0x49e, .to = 0x49f }, .{ .from = 0x4a0, .to = 0x4a1 }, .{ .from = 0x4a2, .to = 0x4a3 }, 
    .{ .from = 0x4a4, .to = 0x4a5 }, .{ .from = 0x4a6, .to = 0x4a7 }, .{ .from = 0x4a8, .to = 0x4a9 }, .{ .from = 0x4aa, .to = 0x4ab }, 
    .{ .from = 0x4ac, .to = 0x4ad }, .{ .from = 0x4ae, .to = 0x4af }, .{ .from = 0x4b0, .to = 0x4b1 }, .{ .from = 0x4b2, .to = 0x4b3 }, 
    .{ .from = 0x4b4, .to = 0x4b5 }, .{ .from = 0x4b6, .to = 0x4b7 }, .{ .from = 0x4b8, .to = 0x4b9 }, .{ .from = 0x4ba, .to = 0x4bb }, 
    .{ .from = 0x4bc, .to = 0x4bd }, .{ .from = 0x4be, .to = 0x4bf }, .{ .from = 0x4c0, .to = 0x4cf }, .{ .from = 0x4c1, .to = 0x4c2 }, 
    .{ .from = 0x4c3, .to = 0x4c4 }, .{ .from = 0x4c5, .to = 0x4c6 }, .{ .from = 0x4c7, .to = 0x4c8 }, .{ .from = 0x4c9, .to = 0x4ca }, 
    .{ .from = 0x4cb, .to = 0x4cc }, .{ .from = 0x4cd, .to = 0x4ce }, .{ .from = 0x4d0, .to = 0x4d1 }, .{ .from = 0x4d2, .to = 0x4d3 }, 
    .{ .from = 0x4d4, .to = 0x4d5 }, .{ .from = 0x4d6, .to = 0x4d7 }, .{ .from = 0x4d8, .to = 0x4d9 }, .{ .from = 0x4da, .to = 0x4db }, 
    .{ .from = 0x4dc, .to = 0x4dd }, .{ .from = 0x4de, .to = 0x4df }, .{ .from = 0x4e0, .to = 0x4e1 }, .{ .from = 0x4e2, .to = 0x4e3 }, 
    .{ .from = 0x4e4, .to = 0x4e5 }, .{ .from = 0x4e6, .to = 0x4e7 }, .{ .from = 0x4e8, .to = 0x4e9 }, .{ .from = 0x4ea, .to = 0x4eb }, 
    .{ .from = 0x4ec, .to = 0x4ed }, .{ .from = 0x4ee, .to = 0x4ef }, .{ .from = 0x4f0, .to = 0x4f1 }, .{ .from = 0x4f2, .to = 0x4f3 }, 
    .{ .from = 0x4f4, .to = 0x4f5 }, .{ .from = 0x4f6, .to = 0x4f7 }, .{ .from = 0x4f8, .to = 0x4f9 }, .{ .from = 0x4fa, .to = 0x4fb }, 
    .{ .from = 0x4fc, .to = 0x4fd }, .{ .from = 0x4fe, .to = 0x4ff }, .{ .from = 0x500, .to = 0x501 }, .{ .from = 0x502, .to = 0x503 }, 
    .{ .from = 0x504, .to = 0x505 }, .{ .from = 0x506, .to = 0x507 }, .{ .from = 0x508, .to = 0x509 }, .{ .from = 0x50a, .to = 0x50b }, 
    .{ .from = 0x50c, .to = 0x50d }, .{ .from = 0x50e, .to = 0x50f }, .{ .from = 0x510, .to = 0x511 }, .{ .from = 0x512, .to = 0x513 }, 
    .{ .from = 0x514, .to = 0x515 }, .{ .from = 0x516, .to = 0x517 }, .{ .from = 0x518, .to = 0x519 }, .{ .from = 0x51a, .to = 0x51b }, 
    .{ .from = 0x51c, .to = 0x51d }, .{ .from = 0x51e, .to = 0x51f }, .{ .from = 0x520, .to = 0x521 }, .{ .from = 0x522, .to = 0x523 }, 
    .{ .from = 0x524, .to = 0x525 }, .{ .from = 0x526, .to = 0x527 }, .{ .from = 0x528, .to = 0x529 }, .{ .from = 0x52a, .to = 0x52b }, 
    .{ .from = 0x52c, .to = 0x52d }, .{ .from = 0x52e, .to = 0x52f }, .{ .from = 0x531, .to = 0x561 }, .{ .from = 0x532, .to = 0x562 }, 
    .{ .from = 0x533, .to = 0x563 }, .{ .from = 0x534, .to = 0x564 }, .{ .from = 0x535, .to = 0x565 }, .{ .from = 0x536, .to = 0x566 }, 
    .{ .from = 0x537, .to = 0x567 }, .{ .from = 0x538, .to = 0x568 }, .{ .from = 0x539, .to = 0x569 }, .{ .from = 0x53a, .to = 0x56a }, 
    .{ .from = 0x53b, .to = 0x56b }, .{ .from = 0x53c, .to = 0x56c }, .{ .from = 0x53d, .to = 0x56d }, .{ .from = 0x53e, .to = 0x56e }, 
    .{ .from = 0x53f, .to = 0x56f }, .{ .from = 0x540, .to = 0x570 }, .{ .from = 0x541, .to = 0x571 }, .{ .from = 0x542, .to = 0x572 }, 
    .{ .from = 0x543, .to = 0x573 }, .{ .from = 0x544, .to = 0x574 }, .{ .from = 0x545, .to = 0x575 }, .{ .from = 0x546, .to = 0x576 }, 
    .{ .from = 0x547, .to = 0x577 }, .{ .from = 0x548, .to = 0x578 }, .{ .from = 0x549, .to = 0x579 }, .{ .from = 0x54a, .to = 0x57a }, 
    .{ .from = 0x54b, .to = 0x57b }, .{ .from = 0x54c, .to = 0x57c }, .{ .from = 0x54d, .to = 0x57d }, .{ .from = 0x54e, .to = 0x57e }, 
    .{ .from = 0x54f, .to = 0x57f }, .{ .from = 0x550, .to = 0x580 }, .{ .from = 0x551, .to = 0x581 }, .{ .from = 0x552, .to = 0x582 }, 
    .{ .from = 0x553, .to = 0x583 }, .{ .from = 0x554, .to = 0x584 }, .{ .from = 0x555, .to = 0x585 }, .{ .from = 0x556, .to = 0x586 }, 
    .{ .from = 0x10a0, .to = 0x2d00 }, .{ .from = 0x10a1, .to = 0x2d01 }, .{ .from = 0x10a2, .to = 0x2d02 }, .{ .from = 0x10a3, .to = 0x2d03 }, 
    .{ .from = 0x10a4, .to = 0x2d04 }, .{ .from = 0x10a5, .to = 0x2d05 }, .{ .from = 0x10a6, .to = 0x2d06 }, .{ .from = 0x10a7, .to = 0x2d07 }, 
    .{ .from = 0x10a8, .to = 0x2d08 }, .{ .from = 0x10a9, .to = 0x2d09 }, .{ .from = 0x10aa, .to = 0x2d0a }, .{ .from = 0x10ab, .to = 0x2d0b }, 
    .{ .from = 0x10ac, .to = 0x2d0c }, .{ .from = 0x10ad, .to = 0x2d0d }, .{ .from = 0x10ae, .to = 0x2d0e }, .{ .from = 0x10af, .to = 0x2d0f }, 
    .{ .from = 0x10b0, .to = 0x2d10 }, .{ .from = 0x10b1, .to = 0x2d11 }, .{ .from = 0x10b2, .to = 0x2d12 }, .{ .from = 0x10b3, .to = 0x2d13 }, 
    .{ .from = 0x10b4, .to = 0x2d14 }, .{ .from = 0x10b5, .to = 0x2d15 }, .{ .from = 0x10b6, .to = 0x2d16 }, .{ .from = 0x10b7, .to = 0x2d17 }, 
    .{ .from = 0x10b8, .to = 0x2d18 }, .{ .from = 0x10b9, .to = 0x2d19 }, .{ .from = 0x10ba, .to = 0x2d1a }, .{ .from = 0x10bb, .to = 0x2d1b }, 
    .{ .from = 0x10bc, .to = 0x2d1c }, .{ .from = 0x10bd, .to = 0x2d1d }, .{ .from = 0x10be, .to = 0x2d1e }, .{ .from = 0x10bf, .to = 0x2d1f }, 
    .{ .from = 0x10c0, .to = 0x2d20 }, .{ .from = 0x10c1, .to = 0x2d21 }, .{ .from = 0x10c2, .to = 0x2d22 }, .{ .from = 0x10c3, .to = 0x2d23 }, 
    .{ .from = 0x10c4, .to = 0x2d24 }, .{ .from = 0x10c5, .to = 0x2d25 }, .{ .from = 0x10c7, .to = 0x2d27 }, .{ .from = 0x10cd, .to = 0x2d2d }, 
    .{ .from = 0x13a0, .to = 0xab70 }, .{ .from = 0x13a1, .to = 0xab71 }, .{ .from = 0x13a2, .to = 0xab72 }, .{ .from = 0x13a3, .to = 0xab73 }, 
    .{ .from = 0x13a4, .to = 0xab74 }, .{ .from = 0x13a5, .to = 0xab75 }, .{ .from = 0x13a6, .to = 0xab76 }, .{ .from = 0x13a7, .to = 0xab77 }, 
    .{ .from = 0x13a8, .to = 0xab78 }, .{ .from = 0x13a9, .to = 0xab79 }, .{ .from = 0x13aa, .to = 0xab7a }, .{ .from = 0x13ab, .to = 0xab7b }, 
    .{ .from = 0x13ac, .to = 0xab7c }, .{ .from = 0x13ad, .to = 0xab7d }, .{ .from = 0x13ae, .to = 0xab7e }, .{ .from = 0x13af, .to = 0xab7f }, 
    .{ .from = 0x13b0, .to = 0xab80 }, .{ .from = 0x13b1, .to = 0xab81 }, .{ .from = 0x13b2, .to = 0xab82 }, .{ .from = 0x13b3, .to = 0xab83 }, 
    .{ .from = 0x13b4, .to = 0xab84 }, .{ .from = 0x13b5, .to = 0xab85 }, .{ .from = 0x13b6, .to = 0xab86 }, .{ .from = 0x13b7, .to = 0xab87 }, 
    .{ .from = 0x13b8, .to = 0xab88 }, .{ .from = 0x13b9, .to = 0xab89 }, .{ .from = 0x13ba, .to = 0xab8a }, .{ .from = 0x13bb, .to = 0xab8b }, 
    .{ .from = 0x13bc, .to = 0xab8c }, .{ .from = 0x13bd, .to = 0xab8d }, .{ .from = 0x13be, .to = 0xab8e }, .{ .from = 0x13bf, .to = 0xab8f }, 
    .{ .from = 0x13c0, .to = 0xab90 }, .{ .from = 0x13c1, .to = 0xab91 }, .{ .from = 0x13c2, .to = 0xab92 }, .{ .from = 0x13c3, .to = 0xab93 }, 
    .{ .from = 0x13c4, .to = 0xab94 }, .{ .from = 0x13c5, .to = 0xab95 }, .{ .from = 0x13c6, .to = 0xab96 }, .{ .from = 0x13c7, .to = 0xab97 }, 
    .{ .from = 0x13c8, .to = 0xab98 }, .{ .from = 0x13c9, .to = 0xab99 }, .{ .from = 0x13ca, .to = 0xab9a }, .{ .from = 0x13cb, .to = 0xab9b }, 
    .{ .from = 0x13cc, .to = 0xab9c }, .{ .from = 0x13cd, .to = 0xab9d }, .{ .from = 0x13ce, .to = 0xab9e }, .{ .from = 0x13cf, .to = 0xab9f }, 
    .{ .from = 0x13d0, .to = 0xaba0 }, .{ .from = 0x13d1, .to = 0xaba1 }, .{ .from = 0x13d2, .to = 0xaba2 }, .{ .from = 0x13d3, .to = 0xaba3 }, 
    .{ .from = 0x13d4, .to = 0xaba4 }, .{ .from = 0x13d5, .to = 0xaba5 }, .{ .from = 0x13d6, .to = 0xaba6 }, .{ .from = 0x13d7, .to = 0xaba7 }, 
    .{ .from = 0x13d8, .to = 0xaba8 }, .{ .from = 0x13d9, .to = 0xaba9 }, .{ .from = 0x13da, .to = 0xabaa }, .{ .from = 0x13db, .to = 0xabab }, 
    .{ .from = 0x13dc, .to = 0xabac }, .{ .from = 0x13dd, .to = 0xabad }, .{ .from = 0x13de, .to = 0xabae }, .{ .from = 0x13df, .to = 0xabaf }, 
    .{ .from = 0x13e0, .to = 0xabb0 }, .{ .from = 0x13e1, .to = 0xabb1 }, .{ .from = 0x13e2, .to = 0xabb2 }, .{ .from = 0x13e3, .to = 0xabb3 }, 
    .{ .from = 0x13e4, .to = 0xabb4 }, .{ .from = 0x13e5, .to = 0xabb5 }, .{ .from = 0x13e6, .to = 0xabb6 }, .{ .from = 0x13e7, .to = 0xabb7 }, 
    .{ .from = 0x13e8, .to = 0xabb8 }, .{ .from = 0x13e9, .to = 0xabb9 }, .{ .from = 0x13ea, .to = 0xabba }, .{ .from = 0x13eb, .to = 0xabbb }, 
    .{ .from = 0x13ec, .to = 0xabbc }, .{ .from = 0x13ed, .to = 0xabbd }, .{ .from = 0x13ee, .to = 0xabbe }, .{ .from = 0x13ef, .to = 0xabbf }, 
    .{ .from = 0x13f0, .to = 0x13f8 }, .{ .from = 0x13f1, .to = 0x13f9 }, .{ .from = 0x13f2, .to = 0x13fa }, .{ .from = 0x13f3, .to = 0x13fb }, 
    .{ .from = 0x13f4, .to = 0x13fc }, .{ .from = 0x13f5, .to = 0x13fd }, .{ .from = 0x1c89, .to = 0x1c8a }, .{ .from = 0x1c90, .to = 0x10d0 }, 
    .{ .from = 0x1c91, .to = 0x10d1 }, .{ .from = 0x1c92, .to = 0x10d2 }, .{ .from = 0x1c93, .to = 0x10d3 }, .{ .from = 0x1c94, .to = 0x10d4 }, 
    .{ .from = 0x1c95, .to = 0x10d5 }, .{ .from = 0x1c96, .to = 0x10d6 }, .{ .from = 0x1c97, .to = 0x10d7 }, .{ .from = 0x1c98, .to = 0x10d8 }, 
    .{ .from = 0x1c99, .to = 0x10d9 }, .{ .from = 0x1c9a, .to = 0x10da }, .{ .from = 0x1c9b, .to = 0x10db }, .{ .from = 0x1c9c, .to = 0x10dc }, 
    .{ .from = 0x1c9d, .to = 0x10dd }, .{ .from = 0x1c9e, .to = 0x10de }, .{ .from = 0x1c9f, .to = 0x10df }, .{ .from = 0x1ca0, .to = 0x10e0 }, 
    .{ .from = 0x1ca1, .to = 0x10e1 }, .{ .from = 0x1ca2, .to = 0x10e2 }, .{ .from = 0x1ca3, .to = 0x10e3 }, .{ .from = 0x1ca4, .to = 0x10e4 }, 
    .{ .from = 0x1ca5, .to = 0x10e5 }, .{ .from = 0x1ca6, .to = 0x10e6 }, .{ .from = 0x1ca7, .to = 0x10e7 }, .{ .from = 0x1ca8, .to = 0x10e8 }, 
    .{ .from = 0x1ca9, .to = 0x10e9 }, .{ .from = 0x1caa, .to = 0x10ea }, .{ .from = 0x1cab, .to = 0x10eb }, .{ .from = 0x1cac, .to = 0x10ec }, 
    .{ .from = 0x1cad, .to = 0x10ed }, .{ .from = 0x1cae, .to = 0x10ee }, .{ .from = 0x1caf, .to = 0x10ef }, .{ .from = 0x1cb0, .to = 0x10f0 }, 
    .{ .from = 0x1cb1, .to = 0x10f1 }, .{ .from = 0x1cb2, .to = 0x10f2 }, .{ .from = 0x1cb3, .to = 0x10f3 }, .{ .from = 0x1cb4, .to = 0x10f4 }, 
    .{ .from = 0x1cb5, .to = 0x10f5 }, .{ .from = 0x1cb6, .to = 0x10f6 }, .{ .from = 0x1cb7, .to = 0x10f7 }, .{ .from = 0x1cb8, .to = 0x10f8 }, 
    .{ .from = 0x1cb9, .to = 0x10f9 }, .{ .from = 0x1cba, .to = 0x10fa }, .{ .from = 0x1cbd, .to = 0x10fd }, .{ .from = 0x1cbe, .to = 0x10fe }, 
    .{ .from = 0x1cbf, .to = 0x10ff }, .{ .from = 0x1e00, .to = 0x1e01 }, .{ .from = 0x1e02, .to = 0x1e03 }, .{ .from = 0x1e04, .to = 0x1e05 }, 
    .{ .from = 0x1e06, .to = 0x1e07 }, .{ .from = 0x1e08, .to = 0x1e09 }, .{ .from = 0x1e0a, .to = 0x1e0b }, .{ .from = 0x1e0c, .to = 0x1e0d }, 
    .{ .from = 0x1e0e, .to = 0x1e0f }, .{ .from = 0x1e10, .to = 0x1e11 }, .{ .from = 0x1e12, .to = 0x1e13 }, .{ .from = 0x1e14, .to = 0x1e15 }, 
    .{ .from = 0x1e16, .to = 0x1e17 }, .{ .from = 0x1e18, .to = 0x1e19 }, .{ .from = 0x1e1a, .to = 0x1e1b }, .{ .from = 0x1e1c, .to = 0x1e1d }, 
    .{ .from = 0x1e1e, .to = 0x1e1f }, .{ .from = 0x1e20, .to = 0x1e21 }, .{ .from = 0x1e22, .to = 0x1e23 }, .{ .from = 0x1e24, .to = 0x1e25 }, 
    .{ .from = 0x1e26, .to = 0x1e27 }, .{ .from = 0x1e28, .to = 0x1e29 }, .{ .from = 0x1e2a, .to = 0x1e2b }, .{ .from = 0x1e2c, .to = 0x1e2d }, 
    .{ .from = 0x1e2e, .to = 0x1e2f }, .{ .from = 0x1e30, .to = 0x1e31 }, .{ .from = 0x1e32, .to = 0x1e33 }, .{ .from = 0x1e34, .to = 0x1e35 }, 
    .{ .from = 0x1e36, .to = 0x1e37 }, .{ .from = 0x1e38, .to = 0x1e39 }, .{ .from = 0x1e3a, .to = 0x1e3b }, .{ .from = 0x1e3c, .to = 0x1e3d }, 
    .{ .from = 0x1e3e, .to = 0x1e3f }, .{ .from = 0x1e40, .to = 0x1e41 }, .{ .from = 0x1e42, .to = 0x1e43 }, .{ .from = 0x1e44, .to = 0x1e45 }, 
    .{ .from = 0x1e46, .to = 0x1e47 }, .{ .from = 0x1e48, .to = 0x1e49 }, .{ .from = 0x1e4a, .to = 0x1e4b }, .{ .from = 0x1e4c, .to = 0x1e4d }, 
    .{ .from = 0x1e4e, .to = 0x1e4f }, .{ .from = 0x1e50, .to = 0x1e51 }, .{ .from = 0x1e52, .to = 0x1e53 }, .{ .from = 0x1e54, .to = 0x1e55 }, 
    .{ .from = 0x1e56, .to = 0x1e57 }, .{ .from = 0x1e58, .to = 0x1e59 }, .{ .from = 0x1e5a, .to = 0x1e5b }, .{ .from = 0x1e5c, .to = 0x1e5d }, 
    .{ .from = 0x1e5e, .to = 0x1e5f }, .{ .from = 0x1e60, .to = 0x1e61 }, .{ .from = 0x1e62, .to = 0x1e63 }, .{ .from = 0x1e64, .to = 0x1e65 }, 
    .{ .from = 0x1e66, .to = 0x1e67 }, .{ .from = 0x1e68, .to = 0x1e69 }, .{ .from = 0x1e6a, .to = 0x1e6b }, .{ .from = 0x1e6c, .to = 0x1e6d }, 
    .{ .from = 0x1e6e, .to = 0x1e6f }, .{ .from = 0x1e70, .to = 0x1e71 }, .{ .from = 0x1e72, .to = 0x1e73 }, .{ .from = 0x1e74, .to = 0x1e75 }, 
    .{ .from = 0x1e76, .to = 0x1e77 }, .{ .from = 0x1e78, .to = 0x1e79 }, .{ .from = 0x1e7a, .to = 0x1e7b }, .{ .from = 0x1e7c, .to = 0x1e7d }, 
    .{ .from = 0x1e7e, .to = 0x1e7f }, .{ .from = 0x1e80, .to = 0x1e81 }, .{ .from = 0x1e82, .to = 0x1e83 }, .{ .from = 0x1e84, .to = 0x1e85 }, 
    .{ .from = 0x1e86, .to = 0x1e87 }, .{ .from = 0x1e88, .to = 0x1e89 }, .{ .from = 0x1e8a, .to = 0x1e8b }, .{ .from = 0x1e8c, .to = 0x1e8d }, 
    .{ .from = 0x1e8e, .to = 0x1e8f }, .{ .from = 0x1e90, .to = 0x1e91 }, .{ .from = 0x1e92, .to = 0x1e93 }, .{ .from = 0x1e94, .to = 0x1e95 }, 
    .{ .from = 0x1e9e, .to = 0xdf }, .{ .from = 0x1ea0, .to = 0x1ea1 }, .{ .from = 0x1ea2, .to = 0x1ea3 }, .{ .from = 0x1ea4, .to = 0x1ea5 }, 
    .{ .from = 0x1ea6, .to = 0x1ea7 }, .{ .from = 0x1ea8, .to = 0x1ea9 }, .{ .from = 0x1eaa, .to = 0x1eab }, .{ .from = 0x1eac, .to = 0x1ead }, 
    .{ .from = 0x1eae, .to = 0x1eaf }, .{ .from = 0x1eb0, .to = 0x1eb1 }, .{ .from = 0x1eb2, .to = 0x1eb3 }, .{ .from = 0x1eb4, .to = 0x1eb5 }, 
    .{ .from = 0x1eb6, .to = 0x1eb7 }, .{ .from = 0x1eb8, .to = 0x1eb9 }, .{ .from = 0x1eba, .to = 0x1ebb }, .{ .from = 0x1ebc, .to = 0x1ebd }, 
    .{ .from = 0x1ebe, .to = 0x1ebf }, .{ .from = 0x1ec0, .to = 0x1ec1 }, .{ .from = 0x1ec2, .to = 0x1ec3 }, .{ .from = 0x1ec4, .to = 0x1ec5 }, 
    .{ .from = 0x1ec6, .to = 0x1ec7 }, .{ .from = 0x1ec8, .to = 0x1ec9 }, .{ .from = 0x1eca, .to = 0x1ecb }, .{ .from = 0x1ecc, .to = 0x1ecd }, 
    .{ .from = 0x1ece, .to = 0x1ecf }, .{ .from = 0x1ed0, .to = 0x1ed1 }, .{ .from = 0x1ed2, .to = 0x1ed3 }, .{ .from = 0x1ed4, .to = 0x1ed5 }, 
    .{ .from = 0x1ed6, .to = 0x1ed7 }, .{ .from = 0x1ed8, .to = 0x1ed9 }, .{ .from = 0x1eda, .to = 0x1edb }, .{ .from = 0x1edc, .to = 0x1edd }, 
    .{ .from = 0x1ede, .to = 0x1edf }, .{ .from = 0x1ee0, .to = 0x1ee1 }, .{ .from = 0x1ee2, .to = 0x1ee3 }, .{ .from = 0x1ee4, .to = 0x1ee5 }, 
    .{ .from = 0x1ee6, .to = 0x1ee7 }, .{ .from = 0x1ee8, .to = 0x1ee9 }, .{ .from = 0x1eea, .to = 0x1eeb }, .{ .from = 0x1eec, .to = 0x1eed }, 
    .{ .from = 0x1eee, .to = 0x1eef }, .{ .from = 0x1ef0, .to = 0x1ef1 }, .{ .from = 0x1ef2, .to = 0x1ef3 }, .{ .from = 0x1ef4, .to = 0x1ef5 }, 
    .{ .from = 0x1ef6, .to = 0x1ef7 }, .{ .from = 0x1ef8, .to = 0x1ef9 }, .{ .from = 0x1efa, .to = 0x1efb }, .{ .from = 0x1efc, .to = 0x1efd }, 
    .{ .from = 0x1efe, .to = 0x1eff }, .{ .from = 0x1f08, .to = 0x1f00 }, .{ .from = 0x1f09, .to = 0x1f01 }, .{ .from = 0x1f0a, .to = 0x1f02 }, 
    .{ .from = 0x1f0b, .to = 0x1f03 }, .{ .from = 0x1f0c, .to = 0x1f04 }, .{ .from = 0x1f0d, .to = 0x1f05 }, .{ .from = 0x1f0e, .to = 0x1f06 }, 
    .{ .from = 0x1f0f, .to = 0x1f07 }, .{ .from = 0x1f18, .to = 0x1f10 }, .{ .from = 0x1f19, .to = 0x1f11 }, .{ .from = 0x1f1a, .to = 0x1f12 }, 
    .{ .from = 0x1f1b, .to = 0x1f13 }, .{ .from = 0x1f1c, .to = 0x1f14 }, .{ .from = 0x1f1d, .to = 0x1f15 }, .{ .from = 0x1f28, .to = 0x1f20 }, 
    .{ .from = 0x1f29, .to = 0x1f21 }, .{ .from = 0x1f2a, .to = 0x1f22 }, .{ .from = 0x1f2b, .to = 0x1f23 }, .{ .from = 0x1f2c, .to = 0x1f24 }, 
    .{ .from = 0x1f2d, .to = 0x1f25 }, .{ .from = 0x1f2e, .to = 0x1f26 }, .{ .from = 0x1f2f, .to = 0x1f27 }, .{ .from = 0x1f38, .to = 0x1f30 }, 
    .{ .from = 0x1f39, .to = 0x1f31 }, .{ .from = 0x1f3a, .to = 0x1f32 }, .{ .from = 0x1f3b, .to = 0x1f33 }, .{ .from = 0x1f3c, .to = 0x1f34 }, 
    .{ .from = 0x1f3d, .to = 0x1f35 }, .{ .from = 0x1f3e, .to = 0x1f36 }, .{ .from = 0x1f3f, .to = 0x1f37 }, .{ .from = 0x1f48, .to = 0x1f40 }, 
    .{ .from = 0x1f49, .to = 0x1f41 }, .{ .from = 0x1f4a, .to = 0x1f42 }, .{ .from = 0x1f4b, .to = 0x1f43 }, .{ .from = 0x1f4c, .to = 0x1f44 }, 
    .{ .from = 0x1f4d, .to = 0x1f45 }, .{ .from = 0x1f59, .to = 0x1f51 }, .{ .from = 0x1f5b, .to = 0x1f53 }, .{ .from = 0x1f5d, .to = 0x1f55 }, 
    .{ .from = 0x1f5f, .to = 0x1f57 }, .{ .from = 0x1f68, .to = 0x1f60 }, .{ .from = 0x1f69, .to = 0x1f61 }, .{ .from = 0x1f6a, .to = 0x1f62 }, 
    .{ .from = 0x1f6b, .to = 0x1f63 }, .{ .from = 0x1f6c, .to = 0x1f64 }, .{ .from = 0x1f6d, .to = 0x1f65 }, .{ .from = 0x1f6e, .to = 0x1f66 }, 
    .{ .from = 0x1f6f, .to = 0x1f67 }, .{ .from = 0x1f88, .to = 0x1f80 }, .{ .from = 0x1f89, .to = 0x1f81 }, .{ .from = 0x1f8a, .to = 0x1f82 }, 
    .{ .from = 0x1f8b, .to = 0x1f83 }, .{ .from = 0x1f8c, .to = 0x1f84 }, .{ .from = 0x1f8d, .to = 0x1f85 }, .{ .from = 0x1f8e, .to = 0x1f86 }, 
    .{ .from = 0x1f8f, .to = 0x1f87 }, .{ .from = 0x1f98, .to = 0x1f90 }, .{ .from = 0x1f99, .to = 0x1f91 }, .{ .from = 0x1f9a, .to = 0x1f92 }, 
    .{ .from = 0x1f9b, .to = 0x1f93 }, .{ .from = 0x1f9c, .to = 0x1f94 }, .{ .from = 0x1f9d, .to = 0x1f95 }, .{ .from = 0x1f9e, .to = 0x1f96 }, 
    .{ .from = 0x1f9f, .to = 0x1f97 }, .{ .from = 0x1fa8, .to = 0x1fa0 }, .{ .from = 0x1fa9, .to = 0x1fa1 }, .{ .from = 0x1faa, .to = 0x1fa2 }, 
    .{ .from = 0x1fab, .to = 0x1fa3 }, .{ .from = 0x1fac, .to = 0x1fa4 }, .{ .from = 0x1fad, .to = 0x1fa5 }, .{ .from = 0x1fae, .to = 0x1fa6 }, 
    .{ .from = 0x1faf, .to = 0x1fa7 }, .{ .from = 0x1fb8, .to = 0x1fb0 }, .{ .from = 0x1fb9, .to = 0x1fb1 }, .{ .from = 0x1fba, .to = 0x1f70 }, 
    .{ .from = 0x1fbb, .to = 0x1f71 }, .{ .from = 0x1fbc, .to = 0x1fb3 }, .{ .from = 0x1fc8, .to = 0x1f72 }, .{ .from = 0x1fc9, .to = 0x1f73 }, 
    .{ .from = 0x1fca, .to = 0x1f74 }, .{ .from = 0x1fcb, .to = 0x1f75 }, .{ .from = 0x1fcc, .to = 0x1fc3 }, .{ .from = 0x1fd8, .to = 0x1fd0 }, 
    .{ .from = 0x1fd9, .to = 0x1fd1 }, .{ .from = 0x1fda, .to = 0x1f76 }, .{ .from = 0x1fdb, .to = 0x1f77 }, .{ .from = 0x1fe8, .to = 0x1fe0 }, 
    .{ .from = 0x1fe9, .to = 0x1fe1 }, .{ .from = 0x1fea, .to = 0x1f7a }, .{ .from = 0x1feb, .to = 0x1f7b }, .{ .from = 0x1fec, .to = 0x1fe5 }, 
    .{ .from = 0x1ff8, .to = 0x1f78 }, .{ .from = 0x1ff9, .to = 0x1f79 }, .{ .from = 0x1ffa, .to = 0x1f7c }, .{ .from = 0x1ffb, .to = 0x1f7d }, 
    .{ .from = 0x1ffc, .to = 0x1ff3 }, .{ .from = 0x2126, .to = 0x3c9 }, .{ .from = 0x212a, .to = 0x6b }, .{ .from = 0x212b, .to = 0xe5 }, 
    .{ .from = 0x2132, .to = 0x214e }, .{ .from = 0x2160, .to = 0x2170 }, .{ .from = 0x2161, .to = 0x2171 }, .{ .from = 0x2162, .to = 0x2172 }, 
    .{ .from = 0x2163, .to = 0x2173 }, .{ .from = 0x2164, .to = 0x2174 }, .{ .from = 0x2165, .to = 0x2175 }, .{ .from = 0x2166, .to = 0x2176 }, 
    .{ .from = 0x2167, .to = 0x2177 }, .{ .from = 0x2168, .to = 0x2178 }, .{ .from = 0x2169, .to = 0x2179 }, .{ .from = 0x216a, .to = 0x217a }, 
    .{ .from = 0x216b, .to = 0x217b }, .{ .from = 0x216c, .to = 0x217c }, .{ .from = 0x216d, .to = 0x217d }, .{ .from = 0x216e, .to = 0x217e }, 
    .{ .from = 0x216f, .to = 0x217f }, .{ .from = 0x2183, .to = 0x2184 }, .{ .from = 0x24b6, .to = 0x24d0 }, .{ .from = 0x24b7, .to = 0x24d1 }, 
    .{ .from = 0x24b8, .to = 0x24d2 }, .{ .from = 0x24b9, .to = 0x24d3 }, .{ .from = 0x24ba, .to = 0x24d4 }, .{ .from = 0x24bb, .to = 0x24d5 }, 
    .{ .from = 0x24bc, .to = 0x24d6 }, .{ .from = 0x24bd, .to = 0x24d7 }, .{ .from = 0x24be, .to = 0x24d8 }, .{ .from = 0x24bf, .to = 0x24d9 }, 
    .{ .from = 0x24c0, .to = 0x24da }, .{ .from = 0x24c1, .to = 0x24db }, .{ .from = 0x24c2, .to = 0x24dc }, .{ .from = 0x24c3, .to = 0x24dd }, 
    .{ .from = 0x24c4, .to = 0x24de }, .{ .from = 0x24c5, .to = 0x24df }, .{ .from = 0x24c6, .to = 0x24e0 }, .{ .from = 0x24c7, .to = 0x24e1 }, 
    .{ .from = 0x24c8, .to = 0x24e2 }, .{ .from = 0x24c9, .to = 0x24e3 }, .{ .from = 0x24ca, .to = 0x24e4 }, .{ .from = 0x24cb, .to = 0x24e5 }, 
    .{ .from = 0x24cc, .to = 0x24e6 }, .{ .from = 0x24cd, .to = 0x24e7 }, .{ .from = 0x24ce, .to = 0x24e8 }, .{ .from = 0x24cf, .to = 0x24e9 }, 
    .{ .from = 0x2c00, .to = 0x2c30 }, .{ .from = 0x2c01, .to = 0x2c31 }, .{ .from = 0x2c02, .to = 0x2c32 }, .{ .from = 0x2c03, .to = 0x2c33 }, 
    .{ .from = 0x2c04, .to = 0x2c34 }, .{ .from = 0x2c05, .to = 0x2c35 }, .{ .from = 0x2c06, .to = 0x2c36 }, .{ .from = 0x2c07, .to = 0x2c37 }, 
    .{ .from = 0x2c08, .to = 0x2c38 }, .{ .from = 0x2c09, .to = 0x2c39 }, .{ .from = 0x2c0a, .to = 0x2c3a }, .{ .from = 0x2c0b, .to = 0x2c3b }, 
    .{ .from = 0x2c0c, .to = 0x2c3c }, .{ .from = 0x2c0d, .to = 0x2c3d }, .{ .from = 0x2c0e, .to = 0x2c3e }, .{ .from = 0x2c0f, .to = 0x2c3f }, 
    .{ .from = 0x2c10, .to = 0x2c40 }, .{ .from = 0x2c11, .to = 0x2c41 }, .{ .from = 0x2c12, .to = 0x2c42 }, .{ .from = 0x2c13, .to = 0x2c43 }, 
    .{ .from = 0x2c14, .to = 0x2c44 }, .{ .from = 0x2c15, .to = 0x2c45 }, .{ .from = 0x2c16, .to = 0x2c46 }, .{ .from = 0x2c17, .to = 0x2c47 }, 
    .{ .from = 0x2c18, .to = 0x2c48 }, .{ .from = 0x2c19, .to = 0x2c49 }, .{ .from = 0x2c1a, .to = 0x2c4a }, .{ .from = 0x2c1b, .to = 0x2c4b }, 
    .{ .from = 0x2c1c, .to = 0x2c4c }, .{ .from = 0x2c1d, .to = 0x2c4d }, .{ .from = 0x2c1e, .to = 0x2c4e }, .{ .from = 0x2c1f, .to = 0x2c4f }, 
    .{ .from = 0x2c20, .to = 0x2c50 }, .{ .from = 0x2c21, .to = 0x2c51 }, .{ .from = 0x2c22, .to = 0x2c52 }, .{ .from = 0x2c23, .to = 0x2c53 }, 
    .{ .from = 0x2c24, .to = 0x2c54 }, .{ .from = 0x2c25, .to = 0x2c55 }, .{ .from = 0x2c26, .to = 0x2c56 }, .{ .from = 0x2c27, .to = 0x2c57 }, 
    .{ .from = 0x2c28, .to = 0x2c58 }, .{ .from = 0x2c29, .to = 0x2c59 }, .{ .from = 0x2c2a, .to = 0x2c5a }, .{ .from = 0x2c2b, .to = 0x2c5b }, 
    .{ .from = 0x2c2c, .to = 0x2c5c }, .{ .from = 0x2c2d, .to = 0x2c5d }, .{ .from = 0x2c2e, .to = 0x2c5e }, .{ .from = 0x2c2f, .to = 0x2c5f }, 
    .{ .from = 0x2c60, .to = 0x2c61 }, .{ .from = 0x2c62, .to = 0x26b }, .{ .from = 0x2c63, .to = 0x1d7d }, .{ .from = 0x2c64, .to = 0x27d }, 
    .{ .from = 0x2c67, .to = 0x2c68 }, .{ .from = 0x2c69, .to = 0x2c6a }, .{ .from = 0x2c6b, .to = 0x2c6c }, .{ .from = 0x2c6d, .to = 0x251 }, 
    .{ .from = 0x2c6e, .to = 0x271 }, .{ .from = 0x2c6f, .to = 0x250 }, .{ .from = 0x2c70, .to = 0x252 }, .{ .from = 0x2c72, .to = 0x2c73 }, 
    .{ .from = 0x2c75, .to = 0x2c76 }, .{ .from = 0x2c7e, .to = 0x23f }, .{ .from = 0x2c7f, .to = 0x240 }, .{ .from = 0x2c80, .to = 0x2c81 }, 
    .{ .from = 0x2c82, .to = 0x2c83 }, .{ .from = 0x2c84, .to = 0x2c85 }, .{ .from = 0x2c86, .to = 0x2c87 }, .{ .from = 0x2c88, .to = 0x2c89 }, 
    .{ .from = 0x2c8a, .to = 0x2c8b }, .{ .from = 0x2c8c, .to = 0x2c8d }, .{ .from = 0x2c8e, .to = 0x2c8f }, .{ .from = 0x2c90, .to = 0x2c91 }, 
    .{ .from = 0x2c92, .to = 0x2c93 }, .{ .from = 0x2c94, .to = 0x2c95 }, .{ .from = 0x2c96, .to = 0x2c97 }, .{ .from = 0x2c98, .to = 0x2c99 }, 
    .{ .from = 0x2c9a, .to = 0x2c9b }, .{ .from = 0x2c9c, .to = 0x2c9d }, .{ .from = 0x2c9e, .to = 0x2c9f }, .{ .from = 0x2ca0, .to = 0x2ca1 }, 
    .{ .from = 0x2ca2, .to = 0x2ca3 }, .{ .from = 0x2ca4, .to = 0x2ca5 }, .{ .from = 0x2ca6, .to = 0x2ca7 }, .{ .from = 0x2ca8, .to = 0x2ca9 }, 
    .{ .from = 0x2caa, .to = 0x2cab }, .{ .from = 0x2cac, .to = 0x2cad }, .{ .from = 0x2cae, .to = 0x2caf }, .{ .from = 0x2cb0, .to = 0x2cb1 }, 
    .{ .from = 0x2cb2, .to = 0x2cb3 }, .{ .from = 0x2cb4, .to = 0x2cb5 }, .{ .from = 0x2cb6, .to = 0x2cb7 }, .{ .from = 0x2cb8, .to = 0x2cb9 }, 
    .{ .from = 0x2cba, .to = 0x2cbb }, .{ .from = 0x2cbc, .to = 0x2cbd }, .{ .from = 0x2cbe, .to = 0x2cbf }, .{ .from = 0x2cc0, .to = 0x2cc1 }, 
    .{ .from = 0x2cc2, .to = 0x2cc3 }, .{ .from = 0x2cc4, .to = 0x2cc5 }, .{ .from = 0x2cc6, .to = 0x2cc7 }, .{ .from = 0x2cc8, .to = 0x2cc9 }, 
    .{ .from = 0x2cca, .to = 0x2ccb }, .{ .from = 0x2ccc, .to = 0x2ccd }, .{ .from = 0x2cce, .to = 0x2ccf }, .{ .from = 0x2cd0, .to = 0x2cd1 }, 
    .{ .from = 0x2cd2, .to = 0x2cd3 }, .{ .from = 0x2cd4, .to = 0x2cd5 }, .{ .from = 0x2cd6, .to = 0x2cd7 }, .{ .from = 0x2cd8, .to = 0x2cd9 }, 
    .{ .from = 0x2cda, .to = 0x2cdb }, .{ .from = 0x2cdc, .to = 0x2cdd }, .{ .from = 0x2cde, .to = 0x2cdf }, .{ .from = 0x2ce0, .to = 0x2ce1 }, 
    .{ .from = 0x2ce2, .to = 0x2ce3 }, .{ .from = 0x2ceb, .to = 0x2cec }, .{ .from = 0x2ced, .to = 0x2cee }, .{ .from = 0x2cf2, .to = 0x2cf3 }, 
    .{ .from = 0xa640, .to = 0xa641 }, .{ .from = 0xa642, .to = 0xa643 }, .{ .from = 0xa644, .to = 0xa645 }, .{ .from = 0xa646, .to = 0xa647 }, 
    .{ .from = 0xa648, .to = 0xa649 }, .{ .from = 0xa64a, .to = 0xa64b }, .{ .from = 0xa64c, .to = 0xa64d }, .{ .from = 0xa64e, .to = 0xa64f }, 
    .{ .from = 0xa650, .to = 0xa651 }, .{ .from = 0xa652, .to = 0xa653 }, .{ .from = 0xa654, .to = 0xa655 }, .{ .from = 0xa656, .to = 0xa657 }, 
    .{ .from = 0xa658, .to = 0xa659 }, .{ .from = 0xa65a, .to = 0xa65b }, .{ .from = 0xa65c, .to = 0xa65d }, .{ .from = 0xa65e, .to = 0xa65f }, 
    .{ .from = 0xa660, .to = 0xa661 }, .{ .from = 0xa662, .to = 0xa663 }, .{ .from = 0xa664, .to = 0xa665 }, .{ .from = 0xa666, .to = 0xa667 }, 
    .{ .from = 0xa668, .to = 0xa669 }, .{ .from = 0xa66a, .to = 0xa66b }, .{ .from = 0xa66c, .to = 0xa66d }, .{ .from = 0xa680, .to = 0xa681 }, 
    .{ .from = 0xa682, .to = 0xa683 }, .{ .from = 0xa684, .to = 0xa685 }, .{ .from = 0xa686, .to = 0xa687 }, .{ .from = 0xa688, .to = 0xa689 }, 
    .{ .from = 0xa68a, .to = 0xa68b }, .{ .from = 0xa68c, .to = 0xa68d }, .{ .from = 0xa68e, .to = 0xa68f }, .{ .from = 0xa690, .to = 0xa691 }, 
    .{ .from = 0xa692, .to = 0xa693 }, .{ .from = 0xa694, .to = 0xa695 }, .{ .from = 0xa696, .to = 0xa697 }, .{ .from = 0xa698, .to = 0xa699 }, 
    .{ .from = 0xa69a, .to = 0xa69b }, .{ .from = 0xa722, .to = 0xa723 }, .{ .from = 0xa724, .to = 0xa725 }, .{ .from = 0xa726, .to = 0xa727 }, 
    .{ .from = 0xa728, .to = 0xa729 }, .{ .from = 0xa72a, .to = 0xa72b }, .{ .from = 0xa72c, .to = 0xa72d }, .{ .from = 0xa72e, .to = 0xa72f }, 
    .{ .from = 0xa732, .to = 0xa733 }, .{ .from = 0xa734, .to = 0xa735 }, .{ .from = 0xa736, .to = 0xa737 }, .{ .from = 0xa738, .to = 0xa739 }, 
    .{ .from = 0xa73a, .to = 0xa73b }, .{ .from = 0xa73c, .to = 0xa73d }, .{ .from = 0xa73e, .to = 0xa73f }, .{ .from = 0xa740, .to = 0xa741 }, 
    .{ .from = 0xa742, .to = 0xa743 }, .{ .from = 0xa744, .to = 0xa745 }, .{ .from = 0xa746, .to = 0xa747 }, .{ .from = 0xa748, .to = 0xa749 }, 
    .{ .from = 0xa74a, .to = 0xa74b }, .{ .from = 0xa74c, .to = 0xa74d }, .{ .from = 0xa74e, .to = 0xa74f }, .{ .from = 0xa750, .to = 0xa751 }, 
    .{ .from = 0xa752, .to = 0xa753 }, .{ .from = 0xa754, .to = 0xa755 }, .{ .from = 0xa756, .to = 0xa757 }, .{ .from = 0xa758, .to = 0xa759 }, 
    .{ .from = 0xa75a, .to = 0xa75b }, .{ .from = 0xa75c, .to = 0xa75d }, .{ .from = 0xa75e, .to = 0xa75f }, .{ .from = 0xa760, .to = 0xa761 }, 
    .{ .from = 0xa762, .to = 0xa763 }, .{ .from = 0xa764, .to = 0xa765 }, .{ .from = 0xa766, .to = 0xa767 }, .{ .from = 0xa768, .to = 0xa769 }, 
    .{ .from = 0xa76a, .to = 0xa76b }, .{ .from = 0xa76c, .to = 0xa76d }, .{ .from = 0xa76e, .to = 0xa76f }, .{ .from = 0xa779, .to = 0xa77a }, 
    .{ .from = 0xa77b, .to = 0xa77c }, .{ .from = 0xa77d, .to = 0x1d79 }, .{ .from = 0xa77e, .to = 0xa77f }, .{ .from = 0xa780, .to = 0xa781 }, 
    .{ .from = 0xa782, .to = 0xa783 }, .{ .from = 0xa784, .to = 0xa785 }, .{ .from = 0xa786, .to = 0xa787 }, .{ .from = 0xa78b, .to = 0xa78c }, 
    .{ .from = 0xa78d, .to = 0x265 }, .{ .from = 0xa790, .to = 0xa791 }, .{ .from = 0xa792, .to = 0xa793 }, .{ .from = 0xa796, .to = 0xa797 }, 
    .{ .from = 0xa798, .to = 0xa799 }, .{ .from = 0xa79a, .to = 0xa79b }, .{ .from = 0xa79c, .to = 0xa79d }, .{ .from = 0xa79e, .to = 0xa79f }, 
    .{ .from = 0xa7a0, .to = 0xa7a1 }, .{ .from = 0xa7a2, .to = 0xa7a3 }, .{ .from = 0xa7a4, .to = 0xa7a5 }, .{ .from = 0xa7a6, .to = 0xa7a7 }, 
    .{ .from = 0xa7a8, .to = 0xa7a9 }, .{ .from = 0xa7aa, .to = 0x266 }, .{ .from = 0xa7ab, .to = 0x25c }, .{ .from = 0xa7ac, .to = 0x261 }, 
    .{ .from = 0xa7ad, .to = 0x26c }, .{ .from = 0xa7ae, .to = 0x26a }, .{ .from = 0xa7b0, .to = 0x29e }, .{ .from = 0xa7b1, .to = 0x287 }, 
    .{ .from = 0xa7b2, .to = 0x29d }, .{ .from = 0xa7b3, .to = 0xab53 }, .{ .from = 0xa7b4, .to = 0xa7b5 }, .{ .from = 0xa7b6, .to = 0xa7b7 }, 
    .{ .from = 0xa7b8, .to = 0xa7b9 }, .{ .from = 0xa7ba, .to = 0xa7bb }, .{ .from = 0xa7bc, .to = 0xa7bd }, .{ .from = 0xa7be, .to = 0xa7bf }, 
    .{ .from = 0xa7c0, .to = 0xa7c1 }, .{ .from = 0xa7c2, .to = 0xa7c3 }, .{ .from = 0xa7c4, .to = 0xa794 }, .{ .from = 0xa7c5, .to = 0x282 }, 
    .{ .from = 0xa7c6, .to = 0x1d8e }, .{ .from = 0xa7c7, .to = 0xa7c8 }, .{ .from = 0xa7c9, .to = 0xa7ca }, .{ .from = 0xa7cb, .to = 0x264 }, 
    .{ .from = 0xa7cc, .to = 0xa7cd }, .{ .from = 0xa7ce, .to = 0xa7cf }, .{ .from = 0xa7d0, .to = 0xa7d1 }, .{ .from = 0xa7d2, .to = 0xa7d3 }, 
    .{ .from = 0xa7d4, .to = 0xa7d5 }, .{ .from = 0xa7d6, .to = 0xa7d7 }, .{ .from = 0xa7d8, .to = 0xa7d9 }, .{ .from = 0xa7da, .to = 0xa7db }, 
    .{ .from = 0xa7dc, .to = 0x19b }, .{ .from = 0xa7f5, .to = 0xa7f6 }, .{ .from = 0xff21, .to = 0xff41 }, .{ .from = 0xff22, .to = 0xff42 }, 
    .{ .from = 0xff23, .to = 0xff43 }, .{ .from = 0xff24, .to = 0xff44 }, .{ .from = 0xff25, .to = 0xff45 }, .{ .from = 0xff26, .to = 0xff46 }, 
    .{ .from = 0xff27, .to = 0xff47 }, .{ .from = 0xff28, .to = 0xff48 }, .{ .from = 0xff29, .to = 0xff49 }, .{ .from = 0xff2a, .to = 0xff4a }, 
    .{ .from = 0xff2b, .to = 0xff4b }, .{ .from = 0xff2c, .to = 0xff4c }, .{ .from = 0xff2d, .to = 0xff4d }, .{ .from = 0xff2e, .to = 0xff4e }, 
    .{ .from = 0xff2f, .to = 0xff4f }, .{ .from = 0xff30, .to = 0xff50 }, .{ .from = 0xff31, .to = 0xff51 }, .{ .from = 0xff32, .to = 0xff52 }, 
    .{ .from = 0xff33, .to = 0xff53 }, .{ .from = 0xff34, .to = 0xff54 }, .{ .from = 0xff35, .to = 0xff55 }, .{ .from = 0xff36, .to = 0xff56 }, 
    .{ .from = 0xff37, .to = 0xff57 }, .{ .from = 0xff38, .to = 0xff58 }, .{ .from = 0xff39, .to = 0xff59 }, .{ .from = 0xff3a, .to = 0xff5a }, 
    .{ .from = 0x10400, .to = 0x10428 }, .{ .from = 0x10401, .to = 0x10429 }, .{ .from = 0x10402, .to = 0x1042a }, .{ .from = 0x10403, .to = 0x1042b }, 
    .{ .from = 0x10404, .to = 0x1042c }, .{ .from = 0x10405, .to = 0x1042d }, .{ .from = 0x10406, .to = 0x1042e }, .{ .from = 0x10407, .to = 0x1042f }, 
    .{ .from = 0x10408, .to = 0x10430 }, .{ .from = 0x10409, .to = 0x10431 }, .{ .from = 0x1040a, .to = 0x10432 }, .{ .from = 0x1040b, .to = 0x10433 }, 
    .{ .from = 0x1040c, .to = 0x10434 }, .{ .from = 0x1040d, .to = 0x10435 }, .{ .from = 0x1040e, .to = 0x10436 }, .{ .from = 0x1040f, .to = 0x10437 }, 
    .{ .from = 0x10410, .to = 0x10438 }, .{ .from = 0x10411, .to = 0x10439 }, .{ .from = 0x10412, .to = 0x1043a }, .{ .from = 0x10413, .to = 0x1043b }, 
    .{ .from = 0x10414, .to = 0x1043c }, .{ .from = 0x10415, .to = 0x1043d }, .{ .from = 0x10416, .to = 0x1043e }, .{ .from = 0x10417, .to = 0x1043f }, 
    .{ .from = 0x10418, .to = 0x10440 }, .{ .from = 0x10419, .to = 0x10441 }, .{ .from = 0x1041a, .to = 0x10442 }, .{ .from = 0x1041b, .to = 0x10443 }, 
    .{ .from = 0x1041c, .to = 0x10444 }, .{ .from = 0x1041d, .to = 0x10445 }, .{ .from = 0x1041e, .to = 0x10446 }, .{ .from = 0x1041f, .to = 0x10447 }, 
    .{ .from = 0x10420, .to = 0x10448 }, .{ .from = 0x10421, .to = 0x10449 }, .{ .from = 0x10422, .to = 0x1044a }, .{ .from = 0x10423, .to = 0x1044b }, 
    .{ .from = 0x10424, .to = 0x1044c }, .{ .from = 0x10425, .to = 0x1044d }, .{ .from = 0x10426, .to = 0x1044e }, .{ .from = 0x10427, .to = 0x1044f }, 
    .{ .from = 0x104b0, .to = 0x104d8 }, .{ .from = 0x104b1, .to = 0x104d9 }, .{ .from = 0x104b2, .to = 0x104da }, .{ .from = 0x104b3, .to = 0x104db }, 
    .{ .from = 0x104b4, .to = 0x104dc }, .{ .from = 0x104b5, .to = 0x104dd }, .{ .from = 0x104b6, .to = 0x104de }, .{ .from = 0x104b7, .to = 0x104df }, 
    .{ .from = 0x104b8, .to = 0x104e0 }, .{ .from = 0x104b9, .to = 0x104e1 }, .{ .from = 0x104ba, .to = 0x104e2 }, .{ .from = 0x104bb, .to = 0x104e3 }, 
    .{ .from = 0x104bc, .to = 0x104e4 }, .{ .from = 0x104bd, .to = 0x104e5 }, .{ .from = 0x104be, .to = 0x104e6 }, .{ .from = 0x104bf, .to = 0x104e7 }, 
    .{ .from = 0x104c0, .to = 0x104e8 }, .{ .from = 0x104c1, .to = 0x104e9 }, .{ .from = 0x104c2, .to = 0x104ea }, .{ .from = 0x104c3, .to = 0x104eb }, 
    .{ .from = 0x104c4, .to = 0x104ec }, .{ .from = 0x104c5, .to = 0x104ed }, .{ .from = 0x104c6, .to = 0x104ee }, .{ .from = 0x104c7, .to = 0x104ef }, 
    .{ .from = 0x104c8, .to = 0x104f0 }, .{ .from = 0x104c9, .to = 0x104f1 }, .{ .from = 0x104ca, .to = 0x104f2 }, .{ .from = 0x104cb, .to = 0x104f3 }, 
    .{ .from = 0x104cc, .to = 0x104f4 }, .{ .from = 0x104cd, .to = 0x104f5 }, .{ .from = 0x104ce, .to = 0x104f6 }, .{ .from = 0x104cf, .to = 0x104f7 }, 
    .{ .from = 0x104d0, .to = 0x104f8 }, .{ .from = 0x104d1, .to = 0x104f9 }, .{ .from = 0x104d2, .to = 0x104fa }, .{ .from = 0x104d3, .to = 0x104fb }, 
    .{ .from = 0x10570, .to = 0x10597 }, .{ .from = 0x10571, .to = 0x10598 }, .{ .from = 0x10572, .to = 0x10599 }, .{ .from = 0x10573, .to = 0x1059a }, 
    .{ .from = 0x10574, .to = 0x1059b }, .{ .from = 0x10575, .to = 0x1059c }, .{ .from = 0x10576, .to = 0x1059d }, .{ .from = 0x10577, .to = 0x1059e }, 
    .{ .from = 0x10578, .to = 0x1059f }, .{ .from = 0x10579, .to = 0x105a0 }, .{ .from = 0x1057a, .to = 0x105a1 }, .{ .from = 0x1057c, .to = 0x105a3 }, 
    .{ .from = 0x1057d, .to = 0x105a4 }, .{ .from = 0x1057e, .to = 0x105a5 }, .{ .from = 0x1057f, .to = 0x105a6 }, .{ .from = 0x10580, .to = 0x105a7 }, 
    .{ .from = 0x10581, .to = 0x105a8 }, .{ .from = 0x10582, .to = 0x105a9 }, .{ .from = 0x10583, .to = 0x105aa }, .{ .from = 0x10584, .to = 0x105ab }, 
    .{ .from = 0x10585, .to = 0x105ac }, .{ .from = 0x10586, .to = 0x105ad }, .{ .from = 0x10587, .to = 0x105ae }, .{ .from = 0x10588, .to = 0x105af }, 
    .{ .from = 0x10589, .to = 0x105b0 }, .{ .from = 0x1058a, .to = 0x105b1 }, .{ .from = 0x1058c, .to = 0x105b3 }, .{ .from = 0x1058d, .to = 0x105b4 }, 
    .{ .from = 0x1058e, .to = 0x105b5 }, .{ .from = 0x1058f, .to = 0x105b6 }, .{ .from = 0x10590, .to = 0x105b7 }, .{ .from = 0x10591, .to = 0x105b8 }, 
    .{ .from = 0x10592, .to = 0x105b9 }, .{ .from = 0x10594, .to = 0x105bb }, .{ .from = 0x10595, .to = 0x105bc }, .{ .from = 0x10c80, .to = 0x10cc0 }, 
    .{ .from = 0x10c81, .to = 0x10cc1 }, .{ .from = 0x10c82, .to = 0x10cc2 }, .{ .from = 0x10c83, .to = 0x10cc3 }, .{ .from = 0x10c84, .to = 0x10cc4 }, 
    .{ .from = 0x10c85, .to = 0x10cc5 }, .{ .from = 0x10c86, .to = 0x10cc6 }, .{ .from = 0x10c87, .to = 0x10cc7 }, .{ .from = 0x10c88, .to = 0x10cc8 }, 
    .{ .from = 0x10c89, .to = 0x10cc9 }, .{ .from = 0x10c8a, .to = 0x10cca }, .{ .from = 0x10c8b, .to = 0x10ccb }, .{ .from = 0x10c8c, .to = 0x10ccc }, 
    .{ .from = 0x10c8d, .to = 0x10ccd }, .{ .from = 0x10c8e, .to = 0x10cce }, .{ .from = 0x10c8f, .to = 0x10ccf }, .{ .from = 0x10c90, .to = 0x10cd0 }, 
    .{ .from = 0x10c91, .to = 0x10cd1 }, .{ .from = 0x10c92, .to = 0x10cd2 }, .{ .from = 0x10c93, .to = 0x10cd3 }, .{ .from = 0x10c94, .to = 0x10cd4 }, 
    .{ .from = 0x10c95, .to = 0x10cd5 }, .{ .from = 0x10c96, .to = 0x10cd6 }, .{ .from = 0x10c97, .to = 0x10cd7 }, .{ .from = 0x10c98, .to = 0x10cd8 }, 
    .{ .from = 0x10c99, .to = 0x10cd9 }, .{ .from = 0x10c9a, .to = 0x10cda }, .{ .from = 0x10c9b, .to = 0x10cdb }, .{ .from = 0x10c9c, .to = 0x10cdc }, 
    .{ .from = 0x10c9d, .to = 0x10cdd }, .{ .from = 0x10c9e, .to = 0x10cde }, .{ .from = 0x10c9f, .to = 0x10cdf }, .{ .from = 0x10ca0, .to = 0x10ce0 }, 
    .{ .from = 0x10ca1, .to = 0x10ce1 }, .{ .from = 0x10ca2, .to = 0x10ce2 }, .{ .from = 0x10ca3, .to = 0x10ce3 }, .{ .from = 0x10ca4, .to = 0x10ce4 }, 
    .{ .from = 0x10ca5, .to = 0x10ce5 }, .{ .from = 0x10ca6, .to = 0x10ce6 }, .{ .from = 0x10ca7, .to = 0x10ce7 }, .{ .from = 0x10ca8, .to = 0x10ce8 }, 
    .{ .from = 0x10ca9, .to = 0x10ce9 }, .{ .from = 0x10caa, .to = 0x10cea }, .{ .from = 0x10cab, .to = 0x10ceb }, .{ .from = 0x10cac, .to = 0x10cec }, 
    .{ .from = 0x10cad, .to = 0x10ced }, .{ .from = 0x10cae, .to = 0x10cee }, .{ .from = 0x10caf, .to = 0x10cef }, .{ .from = 0x10cb0, .to = 0x10cf0 }, 
    .{ .from = 0x10cb1, .to = 0x10cf1 }, .{ .from = 0x10cb2, .to = 0x10cf2 }, .{ .from = 0x10d50, .to = 0x10d70 }, .{ .from = 0x10d51, .to = 0x10d71 }, 
    .{ .from = 0x10d52, .to = 0x10d72 }, .{ .from = 0x10d53, .to = 0x10d73 }, .{ .from = 0x10d54, .to = 0x10d74 }, .{ .from = 0x10d55, .to = 0x10d75 }, 
    .{ .from = 0x10d56, .to = 0x10d76 }, .{ .from = 0x10d57, .to = 0x10d77 }, .{ .from = 0x10d58, .to = 0x10d78 }, .{ .from = 0x10d59, .to = 0x10d79 }, 
    .{ .from = 0x10d5a, .to = 0x10d7a }, .{ .from = 0x10d5b, .to = 0x10d7b }, .{ .from = 0x10d5c, .to = 0x10d7c }, .{ .from = 0x10d5d, .to = 0x10d7d }, 
    .{ .from = 0x10d5e, .to = 0x10d7e }, .{ .from = 0x10d5f, .to = 0x10d7f }, .{ .from = 0x10d60, .to = 0x10d80 }, .{ .from = 0x10d61, .to = 0x10d81 }, 
    .{ .from = 0x10d62, .to = 0x10d82 }, .{ .from = 0x10d63, .to = 0x10d83 }, .{ .from = 0x10d64, .to = 0x10d84 }, .{ .from = 0x10d65, .to = 0x10d85 }, 
    .{ .from = 0x118a0, .to = 0x118c0 }, .{ .from = 0x118a1, .to = 0x118c1 }, .{ .from = 0x118a2, .to = 0x118c2 }, .{ .from = 0x118a3, .to = 0x118c3 }, 
    .{ .from = 0x118a4, .to = 0x118c4 }, .{ .from = 0x118a5, .to = 0x118c5 }, .{ .from = 0x118a6, .to = 0x118c6 }, .{ .from = 0x118a7, .to = 0x118c7 }, 
    .{ .from = 0x118a8, .to = 0x118c8 }, .{ .from = 0x118a9, .to = 0x118c9 }, .{ .from = 0x118aa, .to = 0x118ca }, .{ .from = 0x118ab, .to = 0x118cb }, 
    .{ .from = 0x118ac, .to = 0x118cc }, .{ .from = 0x118ad, .to = 0x118cd }, .{ .from = 0x118ae, .to = 0x118ce }, .{ .from = 0x118af, .to = 0x118cf }, 
    .{ .from = 0x118b0, .to = 0x118d0 }, .{ .from = 0x118b1, .to = 0x118d1 }, .{ .from = 0x118b2, .to = 0x118d2 }, .{ .from = 0x118b3, .to = 0x118d3 }, 
    .{ .from = 0x118b4, .to = 0x118d4 }, .{ .from = 0x118b5, .to = 0x118d5 }, .{ .from = 0x118b6, .to = 0x118d6 }, .{ .from = 0x118b7, .to = 0x118d7 }, 
    .{ .from = 0x118b8, .to = 0x118d8 }, .{ .from = 0x118b9, .to = 0x118d9 }, .{ .from = 0x118ba, .to = 0x118da }, .{ .from = 0x118bb, .to = 0x118db }, 
    .{ .from = 0x118bc, .to = 0x118dc }, .{ .from = 0x118bd, .to = 0x118dd }, .{ .from = 0x118be, .to = 0x118de }, .{ .from = 0x118bf, .to = 0x118df }, 
    .{ .from = 0x16e40, .to = 0x16e60 }, .{ .from = 0x16e41, .to = 0x16e61 }, .{ .from = 0x16e42, .to = 0x16e62 }, .{ .from = 0x16e43, .to = 0x16e63 }, 
    .{ .from = 0x16e44, .to = 0x16e64 }, .{ .from = 0x16e45, .to = 0x16e65 }, .{ .from = 0x16e46, .to = 0x16e66 }, .{ .from = 0x16e47, .to = 0x16e67 }, 
    .{ .from = 0x16e48, .to = 0x16e68 }, .{ .from = 0x16e49, .to = 0x16e69 }, .{ .from = 0x16e4a, .to = 0x16e6a }, .{ .from = 0x16e4b, .to = 0x16e6b }, 
    .{ .from = 0x16e4c, .to = 0x16e6c }, .{ .from = 0x16e4d, .to = 0x16e6d }, .{ .from = 0x16e4e, .to = 0x16e6e }, .{ .from = 0x16e4f, .to = 0x16e6f }, 
    .{ .from = 0x16e50, .to = 0x16e70 }, .{ .from = 0x16e51, .to = 0x16e71 }, .{ .from = 0x16e52, .to = 0x16e72 }, .{ .from = 0x16e53, .to = 0x16e73 }, 
    .{ .from = 0x16e54, .to = 0x16e74 }, .{ .from = 0x16e55, .to = 0x16e75 }, .{ .from = 0x16e56, .to = 0x16e76 }, .{ .from = 0x16e57, .to = 0x16e77 }, 
    .{ .from = 0x16e58, .to = 0x16e78 }, .{ .from = 0x16e59, .to = 0x16e79 }, .{ .from = 0x16e5a, .to = 0x16e7a }, .{ .from = 0x16e5b, .to = 0x16e7b }, 
    .{ .from = 0x16e5c, .to = 0x16e7c }, .{ .from = 0x16e5d, .to = 0x16e7d }, .{ .from = 0x16e5e, .to = 0x16e7e }, .{ .from = 0x16e5f, .to = 0x16e7f }, 
    .{ .from = 0x16ea0, .to = 0x16ebb }, .{ .from = 0x16ea1, .to = 0x16ebc }, .{ .from = 0x16ea2, .to = 0x16ebd }, .{ .from = 0x16ea3, .to = 0x16ebe }, 
    .{ .from = 0x16ea4, .to = 0x16ebf }, .{ .from = 0x16ea5, .to = 0x16ec0 }, .{ .from = 0x16ea6, .to = 0x16ec1 }, .{ .from = 0x16ea7, .to = 0x16ec2 }, 
    .{ .from = 0x16ea8, .to = 0x16ec3 }, .{ .from = 0x16ea9, .to = 0x16ec4 }, .{ .from = 0x16eaa, .to = 0x16ec5 }, .{ .from = 0x16eab, .to = 0x16ec6 }, 
    .{ .from = 0x16eac, .to = 0x16ec7 }, .{ .from = 0x16ead, .to = 0x16ec8 }, .{ .from = 0x16eae, .to = 0x16ec9 }, .{ .from = 0x16eaf, .to = 0x16eca }, 
    .{ .from = 0x16eb0, .to = 0x16ecb }, .{ .from = 0x16eb1, .to = 0x16ecc }, .{ .from = 0x16eb2, .to = 0x16ecd }, .{ .from = 0x16eb3, .to = 0x16ece }, 
    .{ .from = 0x16eb4, .to = 0x16ecf }, .{ .from = 0x16eb5, .to = 0x16ed0 }, .{ .from = 0x16eb6, .to = 0x16ed1 }, .{ .from = 0x16eb7, .to = 0x16ed2 }, 
    .{ .from = 0x16eb8, .to = 0x16ed3 }, .{ .from = 0x1e900, .to = 0x1e922 }, .{ .from = 0x1e901, .to = 0x1e923 }, .{ .from = 0x1e902, .to = 0x1e924 }, 
    .{ .from = 0x1e903, .to = 0x1e925 }, .{ .from = 0x1e904, .to = 0x1e926 }, .{ .from = 0x1e905, .to = 0x1e927 }, .{ .from = 0x1e906, .to = 0x1e928 }, 
    .{ .from = 0x1e907, .to = 0x1e929 }, .{ .from = 0x1e908, .to = 0x1e92a }, .{ .from = 0x1e909, .to = 0x1e92b }, .{ .from = 0x1e90a, .to = 0x1e92c }, 
    .{ .from = 0x1e90b, .to = 0x1e92d }, .{ .from = 0x1e90c, .to = 0x1e92e }, .{ .from = 0x1e90d, .to = 0x1e92f }, .{ .from = 0x1e90e, .to = 0x1e930 }, 
    .{ .from = 0x1e90f, .to = 0x1e931 }, .{ .from = 0x1e910, .to = 0x1e932 }, .{ .from = 0x1e911, .to = 0x1e933 }, .{ .from = 0x1e912, .to = 0x1e934 }, 
    .{ .from = 0x1e913, .to = 0x1e935 }, .{ .from = 0x1e914, .to = 0x1e936 }, .{ .from = 0x1e915, .to = 0x1e937 }, .{ .from = 0x1e916, .to = 0x1e938 }, 
    .{ .from = 0x1e917, .to = 0x1e939 }, .{ .from = 0x1e918, .to = 0x1e93a }, .{ .from = 0x1e919, .to = 0x1e93b }, .{ .from = 0x1e91a, .to = 0x1e93c }, 
    .{ .from = 0x1e91b, .to = 0x1e93d }, .{ .from = 0x1e91c, .to = 0x1e93e }, .{ .from = 0x1e91d, .to = 0x1e93f }, .{ .from = 0x1e91e, .to = 0x1e940 }, 
    .{ .from = 0x1e91f, .to = 0x1e941 }, .{ .from = 0x1e920, .to = 0x1e942 }, .{ .from = 0x1e921, .to = 0x1e943 }, 
};
const upper_multi = [_]MultiMap{
    .{ .from = 0xdf, .off = 0, .len = 2 }, .{ .from = 0x149, .off = 2, .len = 2 }, .{ .from = 0x1f0, .off = 4, .len = 2 }, .{ .from = 0x390, .off = 6, .len = 3 }, 
    .{ .from = 0x3b0, .off = 9, .len = 3 }, .{ .from = 0x587, .off = 12, .len = 2 }, .{ .from = 0x1e96, .off = 14, .len = 2 }, .{ .from = 0x1e97, .off = 16, .len = 2 }, 
    .{ .from = 0x1e98, .off = 18, .len = 2 }, .{ .from = 0x1e99, .off = 20, .len = 2 }, .{ .from = 0x1e9a, .off = 22, .len = 2 }, .{ .from = 0x1f50, .off = 24, .len = 2 }, 
    .{ .from = 0x1f52, .off = 26, .len = 3 }, .{ .from = 0x1f54, .off = 29, .len = 3 }, .{ .from = 0x1f56, .off = 32, .len = 3 }, .{ .from = 0x1f80, .off = 35, .len = 2 }, 
    .{ .from = 0x1f81, .off = 37, .len = 2 }, .{ .from = 0x1f82, .off = 39, .len = 2 }, .{ .from = 0x1f83, .off = 41, .len = 2 }, .{ .from = 0x1f84, .off = 43, .len = 2 }, 
    .{ .from = 0x1f85, .off = 45, .len = 2 }, .{ .from = 0x1f86, .off = 47, .len = 2 }, .{ .from = 0x1f87, .off = 49, .len = 2 }, .{ .from = 0x1f88, .off = 51, .len = 2 }, 
    .{ .from = 0x1f89, .off = 53, .len = 2 }, .{ .from = 0x1f8a, .off = 55, .len = 2 }, .{ .from = 0x1f8b, .off = 57, .len = 2 }, .{ .from = 0x1f8c, .off = 59, .len = 2 }, 
    .{ .from = 0x1f8d, .off = 61, .len = 2 }, .{ .from = 0x1f8e, .off = 63, .len = 2 }, .{ .from = 0x1f8f, .off = 65, .len = 2 }, .{ .from = 0x1f90, .off = 67, .len = 2 }, 
    .{ .from = 0x1f91, .off = 69, .len = 2 }, .{ .from = 0x1f92, .off = 71, .len = 2 }, .{ .from = 0x1f93, .off = 73, .len = 2 }, .{ .from = 0x1f94, .off = 75, .len = 2 }, 
    .{ .from = 0x1f95, .off = 77, .len = 2 }, .{ .from = 0x1f96, .off = 79, .len = 2 }, .{ .from = 0x1f97, .off = 81, .len = 2 }, .{ .from = 0x1f98, .off = 83, .len = 2 }, 
    .{ .from = 0x1f99, .off = 85, .len = 2 }, .{ .from = 0x1f9a, .off = 87, .len = 2 }, .{ .from = 0x1f9b, .off = 89, .len = 2 }, .{ .from = 0x1f9c, .off = 91, .len = 2 }, 
    .{ .from = 0x1f9d, .off = 93, .len = 2 }, .{ .from = 0x1f9e, .off = 95, .len = 2 }, .{ .from = 0x1f9f, .off = 97, .len = 2 }, .{ .from = 0x1fa0, .off = 99, .len = 2 }, 
    .{ .from = 0x1fa1, .off = 101, .len = 2 }, .{ .from = 0x1fa2, .off = 103, .len = 2 }, .{ .from = 0x1fa3, .off = 105, .len = 2 }, .{ .from = 0x1fa4, .off = 107, .len = 2 }, 
    .{ .from = 0x1fa5, .off = 109, .len = 2 }, .{ .from = 0x1fa6, .off = 111, .len = 2 }, .{ .from = 0x1fa7, .off = 113, .len = 2 }, .{ .from = 0x1fa8, .off = 115, .len = 2 }, 
    .{ .from = 0x1fa9, .off = 117, .len = 2 }, .{ .from = 0x1faa, .off = 119, .len = 2 }, .{ .from = 0x1fab, .off = 121, .len = 2 }, .{ .from = 0x1fac, .off = 123, .len = 2 }, 
    .{ .from = 0x1fad, .off = 125, .len = 2 }, .{ .from = 0x1fae, .off = 127, .len = 2 }, .{ .from = 0x1faf, .off = 129, .len = 2 }, .{ .from = 0x1fb2, .off = 131, .len = 2 }, 
    .{ .from = 0x1fb3, .off = 133, .len = 2 }, .{ .from = 0x1fb4, .off = 135, .len = 2 }, .{ .from = 0x1fb6, .off = 137, .len = 2 }, .{ .from = 0x1fb7, .off = 139, .len = 3 }, 
    .{ .from = 0x1fbc, .off = 142, .len = 2 }, .{ .from = 0x1fc2, .off = 144, .len = 2 }, .{ .from = 0x1fc3, .off = 146, .len = 2 }, .{ .from = 0x1fc4, .off = 148, .len = 2 }, 
    .{ .from = 0x1fc6, .off = 150, .len = 2 }, .{ .from = 0x1fc7, .off = 152, .len = 3 }, .{ .from = 0x1fcc, .off = 155, .len = 2 }, .{ .from = 0x1fd2, .off = 157, .len = 3 }, 
    .{ .from = 0x1fd3, .off = 160, .len = 3 }, .{ .from = 0x1fd6, .off = 163, .len = 2 }, .{ .from = 0x1fd7, .off = 165, .len = 3 }, .{ .from = 0x1fe2, .off = 168, .len = 3 }, 
    .{ .from = 0x1fe3, .off = 171, .len = 3 }, .{ .from = 0x1fe4, .off = 174, .len = 2 }, .{ .from = 0x1fe6, .off = 176, .len = 2 }, .{ .from = 0x1fe7, .off = 178, .len = 3 }, 
    .{ .from = 0x1ff2, .off = 181, .len = 2 }, .{ .from = 0x1ff3, .off = 183, .len = 2 }, .{ .from = 0x1ff4, .off = 185, .len = 2 }, .{ .from = 0x1ff6, .off = 187, .len = 2 }, 
    .{ .from = 0x1ff7, .off = 189, .len = 3 }, .{ .from = 0x1ffc, .off = 192, .len = 2 }, .{ .from = 0xfb00, .off = 194, .len = 2 }, .{ .from = 0xfb01, .off = 196, .len = 2 }, 
    .{ .from = 0xfb02, .off = 198, .len = 2 }, .{ .from = 0xfb03, .off = 200, .len = 3 }, .{ .from = 0xfb04, .off = 203, .len = 3 }, .{ .from = 0xfb05, .off = 206, .len = 2 }, 
    .{ .from = 0xfb06, .off = 208, .len = 2 }, .{ .from = 0xfb13, .off = 210, .len = 2 }, .{ .from = 0xfb14, .off = 212, .len = 2 }, .{ .from = 0xfb15, .off = 214, .len = 2 }, 
    .{ .from = 0xfb16, .off = 216, .len = 2 }, .{ .from = 0xfb17, .off = 218, .len = 2 }, 
};
const lower_multi = [_]MultiMap{
    .{ .from = 0x130, .off = 220, .len = 2 }, 
};
const case_multi_data = [_]u21{
    0x53, 0x53, 0x2bc, 0x4e, 
    0x4a, 0x30c, 0x399, 0x308, 
    0x301, 0x3a5, 0x308, 0x301, 
    0x535, 0x552, 0x48, 0x331, 
    0x54, 0x308, 0x57, 0x30a, 
    0x59, 0x30a, 0x41, 0x2be, 
    0x3a5, 0x313, 0x3a5, 0x313, 
    0x300, 0x3a5, 0x313, 0x301, 
    0x3a5, 0x313, 0x342, 0x1f08, 
    0x399, 0x1f09, 0x399, 0x1f0a, 
    0x399, 0x1f0b, 0x399, 0x1f0c, 
    0x399, 0x1f0d, 0x399, 0x1f0e, 
    0x399, 0x1f0f, 0x399, 0x1f08, 
    0x399, 0x1f09, 0x399, 0x1f0a, 
    0x399, 0x1f0b, 0x399, 0x1f0c, 
    0x399, 0x1f0d, 0x399, 0x1f0e, 
    0x399, 0x1f0f, 0x399, 0x1f28, 
    0x399, 0x1f29, 0x399, 0x1f2a, 
    0x399, 0x1f2b, 0x399, 0x1f2c, 
    0x399, 0x1f2d, 0x399, 0x1f2e, 
    0x399, 0x1f2f, 0x399, 0x1f28, 
    0x399, 0x1f29, 0x399, 0x1f2a, 
    0x399, 0x1f2b, 0x399, 0x1f2c, 
    0x399, 0x1f2d, 0x399, 0x1f2e, 
    0x399, 0x1f2f, 0x399, 0x1f68, 
    0x399, 0x1f69, 0x399, 0x1f6a, 
    0x399, 0x1f6b, 0x399, 0x1f6c, 
    0x399, 0x1f6d, 0x399, 0x1f6e, 
    0x399, 0x1f6f, 0x399, 0x1f68, 
    0x399, 0x1f69, 0x399, 0x1f6a, 
    0x399, 0x1f6b, 0x399, 0x1f6c, 
    0x399, 0x1f6d, 0x399, 0x1f6e, 
    0x399, 0x1f6f, 0x399, 0x1fba, 
    0x399, 0x391, 0x399, 0x386, 
    0x399, 0x391, 0x342, 0x391, 
    0x342, 0x399, 0x391, 0x399, 
    0x1fca, 0x399, 0x397, 0x399, 
    0x389, 0x399, 0x397, 0x342, 
    0x397, 0x342, 0x399, 0x397, 
    0x399, 0x399, 0x308, 0x300, 
    0x399, 0x308, 0x301, 0x399, 
    0x342, 0x399, 0x308, 0x342, 
    0x3a5, 0x308, 0x300, 0x3a5, 
    0x308, 0x301, 0x3a1, 0x313, 
    0x3a5, 0x342, 0x3a5, 0x308, 
    0x342, 0x1ffa, 0x399, 0x3a9, 
    0x399, 0x38f, 0x399, 0x3a9, 
    0x342, 0x3a9, 0x342, 0x399, 
    0x3a9, 0x399, 0x46, 0x46, 
    0x46, 0x49, 0x46, 0x4c, 
    0x46, 0x46, 0x49, 0x46, 
    0x46, 0x4c, 0x53, 0x54, 
    0x53, 0x54, 0x544, 0x546, 
    0x544, 0x535, 0x544, 0x53b, 
    0x54e, 0x546, 0x544, 0x53d, 
    0x69, 0x307, 
};
const cased_ranges = [_]Range{
    .{ .lo = 0x41, .hi = 0x5a }, .{ .lo = 0x61, .hi = 0x7a }, .{ .lo = 0xaa, .hi = 0xaa }, .{ .lo = 0xb5, .hi = 0xb5 }, 
    .{ .lo = 0xba, .hi = 0xba }, .{ .lo = 0xc0, .hi = 0xd6 }, .{ .lo = 0xd8, .hi = 0xf6 }, .{ .lo = 0xf8, .hi = 0x1ba }, 
    .{ .lo = 0x1bc, .hi = 0x1bf }, .{ .lo = 0x1c4, .hi = 0x293 }, .{ .lo = 0x296, .hi = 0x2b8 }, .{ .lo = 0x2c0, .hi = 0x2c1 }, 
    .{ .lo = 0x2e0, .hi = 0x2e4 }, .{ .lo = 0x345, .hi = 0x345 }, .{ .lo = 0x370, .hi = 0x373 }, .{ .lo = 0x376, .hi = 0x377 }, 
    .{ .lo = 0x37a, .hi = 0x37d }, .{ .lo = 0x37f, .hi = 0x37f }, .{ .lo = 0x386, .hi = 0x386 }, .{ .lo = 0x388, .hi = 0x38a }, 
    .{ .lo = 0x38c, .hi = 0x38c }, .{ .lo = 0x38e, .hi = 0x3a1 }, .{ .lo = 0x3a3, .hi = 0x3f5 }, .{ .lo = 0x3f7, .hi = 0x481 }, 
    .{ .lo = 0x48a, .hi = 0x52f }, .{ .lo = 0x531, .hi = 0x556 }, .{ .lo = 0x560, .hi = 0x588 }, .{ .lo = 0x10a0, .hi = 0x10c5 }, 
    .{ .lo = 0x10c7, .hi = 0x10c7 }, .{ .lo = 0x10cd, .hi = 0x10cd }, .{ .lo = 0x10d0, .hi = 0x10fa }, .{ .lo = 0x10fc, .hi = 0x10ff }, 
    .{ .lo = 0x13a0, .hi = 0x13f5 }, .{ .lo = 0x13f8, .hi = 0x13fd }, .{ .lo = 0x1c80, .hi = 0x1c8a }, .{ .lo = 0x1c90, .hi = 0x1cba }, 
    .{ .lo = 0x1cbd, .hi = 0x1cbf }, .{ .lo = 0x1d00, .hi = 0x1dbf }, .{ .lo = 0x1e00, .hi = 0x1f15 }, .{ .lo = 0x1f18, .hi = 0x1f1d }, 
    .{ .lo = 0x1f20, .hi = 0x1f45 }, .{ .lo = 0x1f48, .hi = 0x1f4d }, .{ .lo = 0x1f50, .hi = 0x1f57 }, .{ .lo = 0x1f59, .hi = 0x1f59 }, 
    .{ .lo = 0x1f5b, .hi = 0x1f5b }, .{ .lo = 0x1f5d, .hi = 0x1f5d }, .{ .lo = 0x1f5f, .hi = 0x1f7d }, .{ .lo = 0x1f80, .hi = 0x1fb4 }, 
    .{ .lo = 0x1fb6, .hi = 0x1fbc }, .{ .lo = 0x1fbe, .hi = 0x1fbe }, .{ .lo = 0x1fc2, .hi = 0x1fc4 }, .{ .lo = 0x1fc6, .hi = 0x1fcc }, 
    .{ .lo = 0x1fd0, .hi = 0x1fd3 }, .{ .lo = 0x1fd6, .hi = 0x1fdb }, .{ .lo = 0x1fe0, .hi = 0x1fec }, .{ .lo = 0x1ff2, .hi = 0x1ff4 }, 
    .{ .lo = 0x1ff6, .hi = 0x1ffc }, .{ .lo = 0x2071, .hi = 0x2071 }, .{ .lo = 0x207f, .hi = 0x207f }, .{ .lo = 0x2090, .hi = 0x209c }, 
    .{ .lo = 0x2102, .hi = 0x2102 }, .{ .lo = 0x2107, .hi = 0x2107 }, .{ .lo = 0x210a, .hi = 0x2113 }, .{ .lo = 0x2115, .hi = 0x2115 }, 
    .{ .lo = 0x2119, .hi = 0x211d }, .{ .lo = 0x2124, .hi = 0x2124 }, .{ .lo = 0x2126, .hi = 0x2126 }, .{ .lo = 0x2128, .hi = 0x2128 }, 
    .{ .lo = 0x212a, .hi = 0x212d }, .{ .lo = 0x212f, .hi = 0x2134 }, .{ .lo = 0x2139, .hi = 0x2139 }, .{ .lo = 0x213c, .hi = 0x213f }, 
    .{ .lo = 0x2145, .hi = 0x2149 }, .{ .lo = 0x214e, .hi = 0x214e }, .{ .lo = 0x2160, .hi = 0x217f }, .{ .lo = 0x2183, .hi = 0x2184 }, 
    .{ .lo = 0x24b6, .hi = 0x24e9 }, .{ .lo = 0x2c00, .hi = 0x2ce4 }, .{ .lo = 0x2ceb, .hi = 0x2cee }, .{ .lo = 0x2cf2, .hi = 0x2cf3 }, 
    .{ .lo = 0x2d00, .hi = 0x2d25 }, .{ .lo = 0x2d27, .hi = 0x2d27 }, .{ .lo = 0x2d2d, .hi = 0x2d2d }, .{ .lo = 0xa640, .hi = 0xa66d }, 
    .{ .lo = 0xa680, .hi = 0xa69d }, .{ .lo = 0xa722, .hi = 0xa787 }, .{ .lo = 0xa78b, .hi = 0xa78e }, .{ .lo = 0xa790, .hi = 0xa7dc }, 
    .{ .lo = 0xa7f1, .hi = 0xa7f6 }, .{ .lo = 0xa7f8, .hi = 0xa7fa }, .{ .lo = 0xab30, .hi = 0xab5a }, .{ .lo = 0xab5c, .hi = 0xab69 }, 
    .{ .lo = 0xab70, .hi = 0xabbf }, .{ .lo = 0xfb00, .hi = 0xfb06 }, .{ .lo = 0xfb13, .hi = 0xfb17 }, .{ .lo = 0xff21, .hi = 0xff3a }, 
    .{ .lo = 0xff41, .hi = 0xff5a }, .{ .lo = 0x10400, .hi = 0x1044f }, .{ .lo = 0x104b0, .hi = 0x104d3 }, .{ .lo = 0x104d8, .hi = 0x104fb }, 
    .{ .lo = 0x10570, .hi = 0x1057a }, .{ .lo = 0x1057c, .hi = 0x1058a }, .{ .lo = 0x1058c, .hi = 0x10592 }, .{ .lo = 0x10594, .hi = 0x10595 }, 
    .{ .lo = 0x10597, .hi = 0x105a1 }, .{ .lo = 0x105a3, .hi = 0x105b1 }, .{ .lo = 0x105b3, .hi = 0x105b9 }, .{ .lo = 0x105bb, .hi = 0x105bc }, 
    .{ .lo = 0x10780, .hi = 0x10780 }, .{ .lo = 0x10783, .hi = 0x10785 }, .{ .lo = 0x10787, .hi = 0x107b0 }, .{ .lo = 0x107b2, .hi = 0x107ba }, 
    .{ .lo = 0x10c80, .hi = 0x10cb2 }, .{ .lo = 0x10cc0, .hi = 0x10cf2 }, .{ .lo = 0x10d50, .hi = 0x10d65 }, .{ .lo = 0x10d70, .hi = 0x10d85 }, 
    .{ .lo = 0x118a0, .hi = 0x118df }, .{ .lo = 0x16e40, .hi = 0x16e7f }, .{ .lo = 0x16ea0, .hi = 0x16eb8 }, .{ .lo = 0x16ebb, .hi = 0x16ed3 }, 
    .{ .lo = 0x1d400, .hi = 0x1d454 }, .{ .lo = 0x1d456, .hi = 0x1d49c }, .{ .lo = 0x1d49e, .hi = 0x1d49f }, .{ .lo = 0x1d4a2, .hi = 0x1d4a2 }, 
    .{ .lo = 0x1d4a5, .hi = 0x1d4a6 }, .{ .lo = 0x1d4a9, .hi = 0x1d4ac }, .{ .lo = 0x1d4ae, .hi = 0x1d4b9 }, .{ .lo = 0x1d4bb, .hi = 0x1d4bb }, 
    .{ .lo = 0x1d4bd, .hi = 0x1d4c3 }, .{ .lo = 0x1d4c5, .hi = 0x1d505 }, .{ .lo = 0x1d507, .hi = 0x1d50a }, .{ .lo = 0x1d50d, .hi = 0x1d514 }, 
    .{ .lo = 0x1d516, .hi = 0x1d51c }, .{ .lo = 0x1d51e, .hi = 0x1d539 }, .{ .lo = 0x1d53b, .hi = 0x1d53e }, .{ .lo = 0x1d540, .hi = 0x1d544 }, 
    .{ .lo = 0x1d546, .hi = 0x1d546 }, .{ .lo = 0x1d54a, .hi = 0x1d550 }, .{ .lo = 0x1d552, .hi = 0x1d6a5 }, .{ .lo = 0x1d6a8, .hi = 0x1d6c0 }, 
    .{ .lo = 0x1d6c2, .hi = 0x1d6da }, .{ .lo = 0x1d6dc, .hi = 0x1d6fa }, .{ .lo = 0x1d6fc, .hi = 0x1d714 }, .{ .lo = 0x1d716, .hi = 0x1d734 }, 
    .{ .lo = 0x1d736, .hi = 0x1d74e }, .{ .lo = 0x1d750, .hi = 0x1d76e }, .{ .lo = 0x1d770, .hi = 0x1d788 }, .{ .lo = 0x1d78a, .hi = 0x1d7a8 }, 
    .{ .lo = 0x1d7aa, .hi = 0x1d7c2 }, .{ .lo = 0x1d7c4, .hi = 0x1d7cb }, .{ .lo = 0x1df00, .hi = 0x1df09 }, .{ .lo = 0x1df0b, .hi = 0x1df1e }, 
    .{ .lo = 0x1df25, .hi = 0x1df2a }, .{ .lo = 0x1e030, .hi = 0x1e06d }, .{ .lo = 0x1e900, .hi = 0x1e943 }, .{ .lo = 0x1f130, .hi = 0x1f149 }, 
    .{ .lo = 0x1f150, .hi = 0x1f169 }, .{ .lo = 0x1f170, .hi = 0x1f189 }, 
};
const caseign_ranges = [_]Range{
    .{ .lo = 0x27, .hi = 0x27 }, .{ .lo = 0x2e, .hi = 0x2e }, .{ .lo = 0x3a, .hi = 0x3a }, .{ .lo = 0x5e, .hi = 0x5e }, 
    .{ .lo = 0x60, .hi = 0x60 }, .{ .lo = 0xa8, .hi = 0xa8 }, .{ .lo = 0xad, .hi = 0xad }, .{ .lo = 0xaf, .hi = 0xaf }, 
    .{ .lo = 0xb4, .hi = 0xb4 }, .{ .lo = 0xb7, .hi = 0xb8 }, .{ .lo = 0x2b0, .hi = 0x36f }, .{ .lo = 0x374, .hi = 0x375 }, 
    .{ .lo = 0x37a, .hi = 0x37a }, .{ .lo = 0x384, .hi = 0x385 }, .{ .lo = 0x387, .hi = 0x387 }, .{ .lo = 0x483, .hi = 0x489 }, 
    .{ .lo = 0x559, .hi = 0x559 }, .{ .lo = 0x55f, .hi = 0x55f }, .{ .lo = 0x591, .hi = 0x5bd }, .{ .lo = 0x5bf, .hi = 0x5bf }, 
    .{ .lo = 0x5c1, .hi = 0x5c2 }, .{ .lo = 0x5c4, .hi = 0x5c5 }, .{ .lo = 0x5c7, .hi = 0x5c7 }, .{ .lo = 0x5f4, .hi = 0x5f4 }, 
    .{ .lo = 0x600, .hi = 0x605 }, .{ .lo = 0x610, .hi = 0x61a }, .{ .lo = 0x61c, .hi = 0x61c }, .{ .lo = 0x640, .hi = 0x640 }, 
    .{ .lo = 0x64b, .hi = 0x65f }, .{ .lo = 0x670, .hi = 0x670 }, .{ .lo = 0x6d6, .hi = 0x6dd }, .{ .lo = 0x6df, .hi = 0x6e8 }, 
    .{ .lo = 0x6ea, .hi = 0x6ed }, .{ .lo = 0x70f, .hi = 0x70f }, .{ .lo = 0x711, .hi = 0x711 }, .{ .lo = 0x730, .hi = 0x74a }, 
    .{ .lo = 0x7a6, .hi = 0x7b0 }, .{ .lo = 0x7eb, .hi = 0x7f5 }, .{ .lo = 0x7fa, .hi = 0x7fa }, .{ .lo = 0x7fd, .hi = 0x7fd }, 
    .{ .lo = 0x816, .hi = 0x82d }, .{ .lo = 0x859, .hi = 0x85b }, .{ .lo = 0x888, .hi = 0x888 }, .{ .lo = 0x890, .hi = 0x891 }, 
    .{ .lo = 0x897, .hi = 0x89f }, .{ .lo = 0x8c9, .hi = 0x902 }, .{ .lo = 0x93a, .hi = 0x93a }, .{ .lo = 0x93c, .hi = 0x93c }, 
    .{ .lo = 0x941, .hi = 0x948 }, .{ .lo = 0x94d, .hi = 0x94d }, .{ .lo = 0x951, .hi = 0x957 }, .{ .lo = 0x962, .hi = 0x963 }, 
    .{ .lo = 0x971, .hi = 0x971 }, .{ .lo = 0x981, .hi = 0x981 }, .{ .lo = 0x9bc, .hi = 0x9bc }, .{ .lo = 0x9c1, .hi = 0x9c4 }, 
    .{ .lo = 0x9cd, .hi = 0x9cd }, .{ .lo = 0x9e2, .hi = 0x9e3 }, .{ .lo = 0x9fe, .hi = 0x9fe }, .{ .lo = 0xa01, .hi = 0xa02 }, 
    .{ .lo = 0xa3c, .hi = 0xa3c }, .{ .lo = 0xa41, .hi = 0xa42 }, .{ .lo = 0xa47, .hi = 0xa48 }, .{ .lo = 0xa4b, .hi = 0xa4d }, 
    .{ .lo = 0xa51, .hi = 0xa51 }, .{ .lo = 0xa70, .hi = 0xa71 }, .{ .lo = 0xa75, .hi = 0xa75 }, .{ .lo = 0xa81, .hi = 0xa82 }, 
    .{ .lo = 0xabc, .hi = 0xabc }, .{ .lo = 0xac1, .hi = 0xac5 }, .{ .lo = 0xac7, .hi = 0xac8 }, .{ .lo = 0xacd, .hi = 0xacd }, 
    .{ .lo = 0xae2, .hi = 0xae3 }, .{ .lo = 0xafa, .hi = 0xaff }, .{ .lo = 0xb01, .hi = 0xb01 }, .{ .lo = 0xb3c, .hi = 0xb3c }, 
    .{ .lo = 0xb3f, .hi = 0xb3f }, .{ .lo = 0xb41, .hi = 0xb44 }, .{ .lo = 0xb4d, .hi = 0xb4d }, .{ .lo = 0xb55, .hi = 0xb56 }, 
    .{ .lo = 0xb62, .hi = 0xb63 }, .{ .lo = 0xb82, .hi = 0xb82 }, .{ .lo = 0xbc0, .hi = 0xbc0 }, .{ .lo = 0xbcd, .hi = 0xbcd }, 
    .{ .lo = 0xc00, .hi = 0xc00 }, .{ .lo = 0xc04, .hi = 0xc04 }, .{ .lo = 0xc3c, .hi = 0xc3c }, .{ .lo = 0xc3e, .hi = 0xc40 }, 
    .{ .lo = 0xc46, .hi = 0xc48 }, .{ .lo = 0xc4a, .hi = 0xc4d }, .{ .lo = 0xc55, .hi = 0xc56 }, .{ .lo = 0xc62, .hi = 0xc63 }, 
    .{ .lo = 0xc81, .hi = 0xc81 }, .{ .lo = 0xcbc, .hi = 0xcbc }, .{ .lo = 0xcbf, .hi = 0xcbf }, .{ .lo = 0xcc6, .hi = 0xcc6 }, 
    .{ .lo = 0xccc, .hi = 0xccd }, .{ .lo = 0xce2, .hi = 0xce3 }, .{ .lo = 0xd00, .hi = 0xd01 }, .{ .lo = 0xd3b, .hi = 0xd3c }, 
    .{ .lo = 0xd41, .hi = 0xd44 }, .{ .lo = 0xd4d, .hi = 0xd4d }, .{ .lo = 0xd62, .hi = 0xd63 }, .{ .lo = 0xd81, .hi = 0xd81 }, 
    .{ .lo = 0xdca, .hi = 0xdca }, .{ .lo = 0xdd2, .hi = 0xdd4 }, .{ .lo = 0xdd6, .hi = 0xdd6 }, .{ .lo = 0xe31, .hi = 0xe31 }, 
    .{ .lo = 0xe34, .hi = 0xe3a }, .{ .lo = 0xe46, .hi = 0xe4e }, .{ .lo = 0xeb1, .hi = 0xeb1 }, .{ .lo = 0xeb4, .hi = 0xebc }, 
    .{ .lo = 0xec6, .hi = 0xec6 }, .{ .lo = 0xec8, .hi = 0xece }, .{ .lo = 0xf18, .hi = 0xf19 }, .{ .lo = 0xf35, .hi = 0xf35 }, 
    .{ .lo = 0xf37, .hi = 0xf37 }, .{ .lo = 0xf39, .hi = 0xf39 }, .{ .lo = 0xf71, .hi = 0xf7e }, .{ .lo = 0xf80, .hi = 0xf84 }, 
    .{ .lo = 0xf86, .hi = 0xf87 }, .{ .lo = 0xf8d, .hi = 0xf97 }, .{ .lo = 0xf99, .hi = 0xfbc }, .{ .lo = 0xfc6, .hi = 0xfc6 }, 
    .{ .lo = 0x102d, .hi = 0x1030 }, .{ .lo = 0x1032, .hi = 0x1037 }, .{ .lo = 0x1039, .hi = 0x103a }, .{ .lo = 0x103d, .hi = 0x103e }, 
    .{ .lo = 0x1058, .hi = 0x1059 }, .{ .lo = 0x105e, .hi = 0x1060 }, .{ .lo = 0x1071, .hi = 0x1074 }, .{ .lo = 0x1082, .hi = 0x1082 }, 
    .{ .lo = 0x1085, .hi = 0x1086 }, .{ .lo = 0x108d, .hi = 0x108d }, .{ .lo = 0x109d, .hi = 0x109d }, .{ .lo = 0x10fc, .hi = 0x10fc }, 
    .{ .lo = 0x135d, .hi = 0x135f }, .{ .lo = 0x1712, .hi = 0x1714 }, .{ .lo = 0x1732, .hi = 0x1733 }, .{ .lo = 0x1752, .hi = 0x1753 }, 
    .{ .lo = 0x1772, .hi = 0x1773 }, .{ .lo = 0x17b4, .hi = 0x17b5 }, .{ .lo = 0x17b7, .hi = 0x17bd }, .{ .lo = 0x17c6, .hi = 0x17c6 }, 
    .{ .lo = 0x17c9, .hi = 0x17d3 }, .{ .lo = 0x17d7, .hi = 0x17d7 }, .{ .lo = 0x17dd, .hi = 0x17dd }, .{ .lo = 0x180b, .hi = 0x180f }, 
    .{ .lo = 0x1843, .hi = 0x1843 }, .{ .lo = 0x1885, .hi = 0x1886 }, .{ .lo = 0x18a9, .hi = 0x18a9 }, .{ .lo = 0x1920, .hi = 0x1922 }, 
    .{ .lo = 0x1927, .hi = 0x1928 }, .{ .lo = 0x1932, .hi = 0x1932 }, .{ .lo = 0x1939, .hi = 0x193b }, .{ .lo = 0x1a17, .hi = 0x1a18 }, 
    .{ .lo = 0x1a1b, .hi = 0x1a1b }, .{ .lo = 0x1a56, .hi = 0x1a56 }, .{ .lo = 0x1a58, .hi = 0x1a5e }, .{ .lo = 0x1a60, .hi = 0x1a60 }, 
    .{ .lo = 0x1a62, .hi = 0x1a62 }, .{ .lo = 0x1a65, .hi = 0x1a6c }, .{ .lo = 0x1a73, .hi = 0x1a7c }, .{ .lo = 0x1a7f, .hi = 0x1a7f }, 
    .{ .lo = 0x1aa7, .hi = 0x1aa7 }, .{ .lo = 0x1ab0, .hi = 0x1add }, .{ .lo = 0x1ae0, .hi = 0x1aeb }, .{ .lo = 0x1b00, .hi = 0x1b03 }, 
    .{ .lo = 0x1b34, .hi = 0x1b34 }, .{ .lo = 0x1b36, .hi = 0x1b3a }, .{ .lo = 0x1b3c, .hi = 0x1b3c }, .{ .lo = 0x1b42, .hi = 0x1b42 }, 
    .{ .lo = 0x1b6b, .hi = 0x1b73 }, .{ .lo = 0x1b80, .hi = 0x1b81 }, .{ .lo = 0x1ba2, .hi = 0x1ba5 }, .{ .lo = 0x1ba8, .hi = 0x1ba9 }, 
    .{ .lo = 0x1bab, .hi = 0x1bad }, .{ .lo = 0x1be6, .hi = 0x1be6 }, .{ .lo = 0x1be8, .hi = 0x1be9 }, .{ .lo = 0x1bed, .hi = 0x1bed }, 
    .{ .lo = 0x1bef, .hi = 0x1bf1 }, .{ .lo = 0x1c2c, .hi = 0x1c33 }, .{ .lo = 0x1c36, .hi = 0x1c37 }, .{ .lo = 0x1c78, .hi = 0x1c7d }, 
    .{ .lo = 0x1cd0, .hi = 0x1cd2 }, .{ .lo = 0x1cd4, .hi = 0x1ce0 }, .{ .lo = 0x1ce2, .hi = 0x1ce8 }, .{ .lo = 0x1ced, .hi = 0x1ced }, 
    .{ .lo = 0x1cf4, .hi = 0x1cf4 }, .{ .lo = 0x1cf8, .hi = 0x1cf9 }, .{ .lo = 0x1d2c, .hi = 0x1d6a }, .{ .lo = 0x1d78, .hi = 0x1d78 }, 
    .{ .lo = 0x1d9b, .hi = 0x1dff }, .{ .lo = 0x1fbd, .hi = 0x1fbd }, .{ .lo = 0x1fbf, .hi = 0x1fc1 }, .{ .lo = 0x1fcd, .hi = 0x1fcf }, 
    .{ .lo = 0x1fdd, .hi = 0x1fdf }, .{ .lo = 0x1fed, .hi = 0x1fef }, .{ .lo = 0x1ffd, .hi = 0x1ffe }, .{ .lo = 0x200b, .hi = 0x200f }, 
    .{ .lo = 0x2018, .hi = 0x2019 }, .{ .lo = 0x2024, .hi = 0x2024 }, .{ .lo = 0x2027, .hi = 0x2027 }, .{ .lo = 0x202a, .hi = 0x202e }, 
    .{ .lo = 0x2060, .hi = 0x2064 }, .{ .lo = 0x2066, .hi = 0x206f }, .{ .lo = 0x2071, .hi = 0x2071 }, .{ .lo = 0x207f, .hi = 0x207f }, 
    .{ .lo = 0x2090, .hi = 0x209c }, .{ .lo = 0x20d0, .hi = 0x20f0 }, .{ .lo = 0x2c7c, .hi = 0x2c7d }, .{ .lo = 0x2cef, .hi = 0x2cf1 }, 
    .{ .lo = 0x2d6f, .hi = 0x2d6f }, .{ .lo = 0x2d7f, .hi = 0x2d7f }, .{ .lo = 0x2de0, .hi = 0x2dff }, .{ .lo = 0x2e2f, .hi = 0x2e2f }, 
    .{ .lo = 0x3005, .hi = 0x3005 }, .{ .lo = 0x302a, .hi = 0x302d }, .{ .lo = 0x3031, .hi = 0x3035 }, .{ .lo = 0x303b, .hi = 0x303b }, 
    .{ .lo = 0x3099, .hi = 0x309e }, .{ .lo = 0x30fc, .hi = 0x30fe }, .{ .lo = 0xa015, .hi = 0xa015 }, .{ .lo = 0xa4f8, .hi = 0xa4fd }, 
    .{ .lo = 0xa60c, .hi = 0xa60c }, .{ .lo = 0xa66f, .hi = 0xa672 }, .{ .lo = 0xa674, .hi = 0xa67d }, .{ .lo = 0xa67f, .hi = 0xa67f }, 
    .{ .lo = 0xa69c, .hi = 0xa69f }, .{ .lo = 0xa6f0, .hi = 0xa6f1 }, .{ .lo = 0xa700, .hi = 0xa721 }, .{ .lo = 0xa770, .hi = 0xa770 }, 
    .{ .lo = 0xa788, .hi = 0xa78a }, .{ .lo = 0xa7f1, .hi = 0xa7f4 }, .{ .lo = 0xa7f8, .hi = 0xa7f9 }, .{ .lo = 0xa802, .hi = 0xa802 }, 
    .{ .lo = 0xa806, .hi = 0xa806 }, .{ .lo = 0xa80b, .hi = 0xa80b }, .{ .lo = 0xa825, .hi = 0xa826 }, .{ .lo = 0xa82c, .hi = 0xa82c }, 
    .{ .lo = 0xa8c4, .hi = 0xa8c5 }, .{ .lo = 0xa8e0, .hi = 0xa8f1 }, .{ .lo = 0xa8ff, .hi = 0xa8ff }, .{ .lo = 0xa926, .hi = 0xa92d }, 
    .{ .lo = 0xa947, .hi = 0xa951 }, .{ .lo = 0xa980, .hi = 0xa982 }, .{ .lo = 0xa9b3, .hi = 0xa9b3 }, .{ .lo = 0xa9b6, .hi = 0xa9b9 }, 
    .{ .lo = 0xa9bc, .hi = 0xa9bd }, .{ .lo = 0xa9cf, .hi = 0xa9cf }, .{ .lo = 0xa9e5, .hi = 0xa9e6 }, .{ .lo = 0xaa29, .hi = 0xaa2e }, 
    .{ .lo = 0xaa31, .hi = 0xaa32 }, .{ .lo = 0xaa35, .hi = 0xaa36 }, .{ .lo = 0xaa43, .hi = 0xaa43 }, .{ .lo = 0xaa4c, .hi = 0xaa4c }, 
    .{ .lo = 0xaa70, .hi = 0xaa70 }, .{ .lo = 0xaa7c, .hi = 0xaa7c }, .{ .lo = 0xaab0, .hi = 0xaab0 }, .{ .lo = 0xaab2, .hi = 0xaab4 }, 
    .{ .lo = 0xaab7, .hi = 0xaab8 }, .{ .lo = 0xaabe, .hi = 0xaabf }, .{ .lo = 0xaac1, .hi = 0xaac1 }, .{ .lo = 0xaadd, .hi = 0xaadd }, 
    .{ .lo = 0xaaec, .hi = 0xaaed }, .{ .lo = 0xaaf3, .hi = 0xaaf4 }, .{ .lo = 0xaaf6, .hi = 0xaaf6 }, .{ .lo = 0xab5b, .hi = 0xab5f }, 
    .{ .lo = 0xab69, .hi = 0xab6b }, .{ .lo = 0xabe5, .hi = 0xabe5 }, .{ .lo = 0xabe8, .hi = 0xabe8 }, .{ .lo = 0xabed, .hi = 0xabed }, 
    .{ .lo = 0xfb1e, .hi = 0xfb1e }, .{ .lo = 0xfbb2, .hi = 0xfbc2 }, .{ .lo = 0xfe00, .hi = 0xfe0f }, .{ .lo = 0xfe13, .hi = 0xfe13 }, 
    .{ .lo = 0xfe20, .hi = 0xfe2f }, .{ .lo = 0xfe52, .hi = 0xfe52 }, .{ .lo = 0xfe55, .hi = 0xfe55 }, .{ .lo = 0xfeff, .hi = 0xfeff }, 
    .{ .lo = 0xff07, .hi = 0xff07 }, .{ .lo = 0xff0e, .hi = 0xff0e }, .{ .lo = 0xff1a, .hi = 0xff1a }, .{ .lo = 0xff3e, .hi = 0xff3e }, 
    .{ .lo = 0xff40, .hi = 0xff40 }, .{ .lo = 0xff70, .hi = 0xff70 }, .{ .lo = 0xff9e, .hi = 0xff9f }, .{ .lo = 0xffe3, .hi = 0xffe3 }, 
    .{ .lo = 0xfff9, .hi = 0xfffb }, .{ .lo = 0x101fd, .hi = 0x101fd }, .{ .lo = 0x102e0, .hi = 0x102e0 }, .{ .lo = 0x10376, .hi = 0x1037a }, 
    .{ .lo = 0x10780, .hi = 0x10785 }, .{ .lo = 0x10787, .hi = 0x107b0 }, .{ .lo = 0x107b2, .hi = 0x107ba }, .{ .lo = 0x10a01, .hi = 0x10a03 }, 
    .{ .lo = 0x10a05, .hi = 0x10a06 }, .{ .lo = 0x10a0c, .hi = 0x10a0f }, .{ .lo = 0x10a38, .hi = 0x10a3a }, .{ .lo = 0x10a3f, .hi = 0x10a3f }, 
    .{ .lo = 0x10ae5, .hi = 0x10ae6 }, .{ .lo = 0x10d24, .hi = 0x10d27 }, .{ .lo = 0x10d4e, .hi = 0x10d4e }, .{ .lo = 0x10d69, .hi = 0x10d6d }, 
    .{ .lo = 0x10d6f, .hi = 0x10d6f }, .{ .lo = 0x10eab, .hi = 0x10eac }, .{ .lo = 0x10ec5, .hi = 0x10ec5 }, .{ .lo = 0x10efa, .hi = 0x10eff }, 
    .{ .lo = 0x10f46, .hi = 0x10f50 }, .{ .lo = 0x10f82, .hi = 0x10f85 }, .{ .lo = 0x11001, .hi = 0x11001 }, .{ .lo = 0x11038, .hi = 0x11046 }, 
    .{ .lo = 0x11070, .hi = 0x11070 }, .{ .lo = 0x11073, .hi = 0x11074 }, .{ .lo = 0x1107f, .hi = 0x11081 }, .{ .lo = 0x110b3, .hi = 0x110b6 }, 
    .{ .lo = 0x110b9, .hi = 0x110ba }, .{ .lo = 0x110bd, .hi = 0x110bd }, .{ .lo = 0x110c2, .hi = 0x110c2 }, .{ .lo = 0x110cd, .hi = 0x110cd }, 
    .{ .lo = 0x11100, .hi = 0x11102 }, .{ .lo = 0x11127, .hi = 0x1112b }, .{ .lo = 0x1112d, .hi = 0x11134 }, .{ .lo = 0x11173, .hi = 0x11173 }, 
    .{ .lo = 0x11180, .hi = 0x11181 }, .{ .lo = 0x111b6, .hi = 0x111be }, .{ .lo = 0x111c9, .hi = 0x111cc }, .{ .lo = 0x111cf, .hi = 0x111cf }, 
    .{ .lo = 0x1122f, .hi = 0x11231 }, .{ .lo = 0x11234, .hi = 0x11234 }, .{ .lo = 0x11236, .hi = 0x11237 }, .{ .lo = 0x1123e, .hi = 0x1123e }, 
    .{ .lo = 0x11241, .hi = 0x11241 }, .{ .lo = 0x112df, .hi = 0x112df }, .{ .lo = 0x112e3, .hi = 0x112ea }, .{ .lo = 0x11300, .hi = 0x11301 }, 
    .{ .lo = 0x1133b, .hi = 0x1133c }, .{ .lo = 0x11340, .hi = 0x11340 }, .{ .lo = 0x11366, .hi = 0x1136c }, .{ .lo = 0x11370, .hi = 0x11374 }, 
    .{ .lo = 0x113bb, .hi = 0x113c0 }, .{ .lo = 0x113ce, .hi = 0x113ce }, .{ .lo = 0x113d0, .hi = 0x113d0 }, .{ .lo = 0x113d2, .hi = 0x113d2 }, 
    .{ .lo = 0x113e1, .hi = 0x113e2 }, .{ .lo = 0x11438, .hi = 0x1143f }, .{ .lo = 0x11442, .hi = 0x11444 }, .{ .lo = 0x11446, .hi = 0x11446 }, 
    .{ .lo = 0x1145e, .hi = 0x1145e }, .{ .lo = 0x114b3, .hi = 0x114b8 }, .{ .lo = 0x114ba, .hi = 0x114ba }, .{ .lo = 0x114bf, .hi = 0x114c0 }, 
    .{ .lo = 0x114c2, .hi = 0x114c3 }, .{ .lo = 0x115b2, .hi = 0x115b5 }, .{ .lo = 0x115bc, .hi = 0x115bd }, .{ .lo = 0x115bf, .hi = 0x115c0 }, 
    .{ .lo = 0x115dc, .hi = 0x115dd }, .{ .lo = 0x11633, .hi = 0x1163a }, .{ .lo = 0x1163d, .hi = 0x1163d }, .{ .lo = 0x1163f, .hi = 0x11640 }, 
    .{ .lo = 0x116ab, .hi = 0x116ab }, .{ .lo = 0x116ad, .hi = 0x116ad }, .{ .lo = 0x116b0, .hi = 0x116b5 }, .{ .lo = 0x116b7, .hi = 0x116b7 }, 
    .{ .lo = 0x1171d, .hi = 0x1171d }, .{ .lo = 0x1171f, .hi = 0x1171f }, .{ .lo = 0x11722, .hi = 0x11725 }, .{ .lo = 0x11727, .hi = 0x1172b }, 
    .{ .lo = 0x1182f, .hi = 0x11837 }, .{ .lo = 0x11839, .hi = 0x1183a }, .{ .lo = 0x1193b, .hi = 0x1193c }, .{ .lo = 0x1193e, .hi = 0x1193e }, 
    .{ .lo = 0x11943, .hi = 0x11943 }, .{ .lo = 0x119d4, .hi = 0x119d7 }, .{ .lo = 0x119da, .hi = 0x119db }, .{ .lo = 0x119e0, .hi = 0x119e0 }, 
    .{ .lo = 0x11a01, .hi = 0x11a0a }, .{ .lo = 0x11a33, .hi = 0x11a38 }, .{ .lo = 0x11a3b, .hi = 0x11a3e }, .{ .lo = 0x11a47, .hi = 0x11a47 }, 
    .{ .lo = 0x11a51, .hi = 0x11a56 }, .{ .lo = 0x11a59, .hi = 0x11a5b }, .{ .lo = 0x11a8a, .hi = 0x11a96 }, .{ .lo = 0x11a98, .hi = 0x11a99 }, 
    .{ .lo = 0x11b60, .hi = 0x11b60 }, .{ .lo = 0x11b62, .hi = 0x11b64 }, .{ .lo = 0x11b66, .hi = 0x11b66 }, .{ .lo = 0x11c30, .hi = 0x11c36 }, 
    .{ .lo = 0x11c38, .hi = 0x11c3d }, .{ .lo = 0x11c3f, .hi = 0x11c3f }, .{ .lo = 0x11c92, .hi = 0x11ca7 }, .{ .lo = 0x11caa, .hi = 0x11cb0 }, 
    .{ .lo = 0x11cb2, .hi = 0x11cb3 }, .{ .lo = 0x11cb5, .hi = 0x11cb6 }, .{ .lo = 0x11d31, .hi = 0x11d36 }, .{ .lo = 0x11d3a, .hi = 0x11d3a }, 
    .{ .lo = 0x11d3c, .hi = 0x11d3d }, .{ .lo = 0x11d3f, .hi = 0x11d45 }, .{ .lo = 0x11d47, .hi = 0x11d47 }, .{ .lo = 0x11d90, .hi = 0x11d91 }, 
    .{ .lo = 0x11d95, .hi = 0x11d95 }, .{ .lo = 0x11d97, .hi = 0x11d97 }, .{ .lo = 0x11dd9, .hi = 0x11dd9 }, .{ .lo = 0x11ef3, .hi = 0x11ef4 }, 
    .{ .lo = 0x11f00, .hi = 0x11f01 }, .{ .lo = 0x11f36, .hi = 0x11f3a }, .{ .lo = 0x11f40, .hi = 0x11f40 }, .{ .lo = 0x11f42, .hi = 0x11f42 }, 
    .{ .lo = 0x11f5a, .hi = 0x11f5a }, .{ .lo = 0x13430, .hi = 0x13440 }, .{ .lo = 0x13447, .hi = 0x13455 }, .{ .lo = 0x1611e, .hi = 0x16129 }, 
    .{ .lo = 0x1612d, .hi = 0x1612f }, .{ .lo = 0x16af0, .hi = 0x16af4 }, .{ .lo = 0x16b30, .hi = 0x16b36 }, .{ .lo = 0x16b40, .hi = 0x16b43 }, 
    .{ .lo = 0x16d40, .hi = 0x16d42 }, .{ .lo = 0x16d6b, .hi = 0x16d6c }, .{ .lo = 0x16f4f, .hi = 0x16f4f }, .{ .lo = 0x16f8f, .hi = 0x16f9f }, 
    .{ .lo = 0x16fe0, .hi = 0x16fe1 }, .{ .lo = 0x16fe3, .hi = 0x16fe4 }, .{ .lo = 0x16ff2, .hi = 0x16ff3 }, .{ .lo = 0x1aff0, .hi = 0x1aff3 }, 
    .{ .lo = 0x1aff5, .hi = 0x1affb }, .{ .lo = 0x1affd, .hi = 0x1affe }, .{ .lo = 0x1bc9d, .hi = 0x1bc9e }, .{ .lo = 0x1bca0, .hi = 0x1bca3 }, 
    .{ .lo = 0x1cf00, .hi = 0x1cf2d }, .{ .lo = 0x1cf30, .hi = 0x1cf46 }, .{ .lo = 0x1d167, .hi = 0x1d169 }, .{ .lo = 0x1d173, .hi = 0x1d182 }, 
    .{ .lo = 0x1d185, .hi = 0x1d18b }, .{ .lo = 0x1d1aa, .hi = 0x1d1ad }, .{ .lo = 0x1d242, .hi = 0x1d244 }, .{ .lo = 0x1da00, .hi = 0x1da36 }, 
    .{ .lo = 0x1da3b, .hi = 0x1da6c }, .{ .lo = 0x1da75, .hi = 0x1da75 }, .{ .lo = 0x1da84, .hi = 0x1da84 }, .{ .lo = 0x1da9b, .hi = 0x1da9f }, 
    .{ .lo = 0x1daa1, .hi = 0x1daaf }, .{ .lo = 0x1e000, .hi = 0x1e006 }, .{ .lo = 0x1e008, .hi = 0x1e018 }, .{ .lo = 0x1e01b, .hi = 0x1e021 }, 
    .{ .lo = 0x1e023, .hi = 0x1e024 }, .{ .lo = 0x1e026, .hi = 0x1e02a }, .{ .lo = 0x1e030, .hi = 0x1e06d }, .{ .lo = 0x1e08f, .hi = 0x1e08f }, 
    .{ .lo = 0x1e130, .hi = 0x1e13d }, .{ .lo = 0x1e2ae, .hi = 0x1e2ae }, .{ .lo = 0x1e2ec, .hi = 0x1e2ef }, .{ .lo = 0x1e4eb, .hi = 0x1e4ef }, 
    .{ .lo = 0x1e5ee, .hi = 0x1e5ef }, .{ .lo = 0x1e6e3, .hi = 0x1e6e3 }, .{ .lo = 0x1e6e6, .hi = 0x1e6e6 }, .{ .lo = 0x1e6ee, .hi = 0x1e6ef }, 
    .{ .lo = 0x1e6f5, .hi = 0x1e6f5 }, .{ .lo = 0x1e6ff, .hi = 0x1e6ff }, .{ .lo = 0x1e8d0, .hi = 0x1e8d6 }, .{ .lo = 0x1e944, .hi = 0x1e94b }, 
    .{ .lo = 0x1f3fb, .hi = 0x1f3ff }, .{ .lo = 0xe0001, .hi = 0xe0001 }, .{ .lo = 0xe0020, .hi = 0xe007f }, .{ .lo = 0xe0100, .hi = 0xe01ef }, 
};
const gcb_extend_ranges = [_]Range{
    .{ .lo = 0x300, .hi = 0x36f }, .{ .lo = 0x483, .hi = 0x489 }, .{ .lo = 0x591, .hi = 0x5bd }, .{ .lo = 0x5bf, .hi = 0x5bf }, 
    .{ .lo = 0x5c1, .hi = 0x5c2 }, .{ .lo = 0x5c4, .hi = 0x5c5 }, .{ .lo = 0x5c7, .hi = 0x5c7 }, .{ .lo = 0x610, .hi = 0x61a }, 
    .{ .lo = 0x64b, .hi = 0x65f }, .{ .lo = 0x670, .hi = 0x670 }, .{ .lo = 0x6d6, .hi = 0x6dc }, .{ .lo = 0x6df, .hi = 0x6e4 }, 
    .{ .lo = 0x6e7, .hi = 0x6e8 }, .{ .lo = 0x6ea, .hi = 0x6ed }, .{ .lo = 0x711, .hi = 0x711 }, .{ .lo = 0x730, .hi = 0x74a }, 
    .{ .lo = 0x7a6, .hi = 0x7b0 }, .{ .lo = 0x7eb, .hi = 0x7f3 }, .{ .lo = 0x7fd, .hi = 0x7fd }, .{ .lo = 0x816, .hi = 0x819 }, 
    .{ .lo = 0x81b, .hi = 0x823 }, .{ .lo = 0x825, .hi = 0x827 }, .{ .lo = 0x829, .hi = 0x82d }, .{ .lo = 0x859, .hi = 0x85b }, 
    .{ .lo = 0x897, .hi = 0x89f }, .{ .lo = 0x8ca, .hi = 0x8e1 }, .{ .lo = 0x8e3, .hi = 0x902 }, .{ .lo = 0x93a, .hi = 0x93a }, 
    .{ .lo = 0x93c, .hi = 0x93c }, .{ .lo = 0x941, .hi = 0x948 }, .{ .lo = 0x94d, .hi = 0x94d }, .{ .lo = 0x951, .hi = 0x957 }, 
    .{ .lo = 0x962, .hi = 0x963 }, .{ .lo = 0x981, .hi = 0x981 }, .{ .lo = 0x9bc, .hi = 0x9bc }, .{ .lo = 0x9be, .hi = 0x9be }, 
    .{ .lo = 0x9c1, .hi = 0x9c4 }, .{ .lo = 0x9cd, .hi = 0x9cd }, .{ .lo = 0x9d7, .hi = 0x9d7 }, .{ .lo = 0x9e2, .hi = 0x9e3 }, 
    .{ .lo = 0x9fe, .hi = 0x9fe }, .{ .lo = 0xa01, .hi = 0xa02 }, .{ .lo = 0xa3c, .hi = 0xa3c }, .{ .lo = 0xa41, .hi = 0xa42 }, 
    .{ .lo = 0xa47, .hi = 0xa48 }, .{ .lo = 0xa4b, .hi = 0xa4d }, .{ .lo = 0xa51, .hi = 0xa51 }, .{ .lo = 0xa70, .hi = 0xa71 }, 
    .{ .lo = 0xa75, .hi = 0xa75 }, .{ .lo = 0xa81, .hi = 0xa82 }, .{ .lo = 0xabc, .hi = 0xabc }, .{ .lo = 0xac1, .hi = 0xac5 }, 
    .{ .lo = 0xac7, .hi = 0xac8 }, .{ .lo = 0xacd, .hi = 0xacd }, .{ .lo = 0xae2, .hi = 0xae3 }, .{ .lo = 0xafa, .hi = 0xaff }, 
    .{ .lo = 0xb01, .hi = 0xb01 }, .{ .lo = 0xb3c, .hi = 0xb3c }, .{ .lo = 0xb3e, .hi = 0xb3f }, .{ .lo = 0xb41, .hi = 0xb44 }, 
    .{ .lo = 0xb4d, .hi = 0xb4d }, .{ .lo = 0xb55, .hi = 0xb57 }, .{ .lo = 0xb62, .hi = 0xb63 }, .{ .lo = 0xb82, .hi = 0xb82 }, 
    .{ .lo = 0xbbe, .hi = 0xbbe }, .{ .lo = 0xbc0, .hi = 0xbc0 }, .{ .lo = 0xbcd, .hi = 0xbcd }, .{ .lo = 0xbd7, .hi = 0xbd7 }, 
    .{ .lo = 0xc00, .hi = 0xc00 }, .{ .lo = 0xc04, .hi = 0xc04 }, .{ .lo = 0xc3c, .hi = 0xc3c }, .{ .lo = 0xc3e, .hi = 0xc40 }, 
    .{ .lo = 0xc46, .hi = 0xc48 }, .{ .lo = 0xc4a, .hi = 0xc4d }, .{ .lo = 0xc55, .hi = 0xc56 }, .{ .lo = 0xc62, .hi = 0xc63 }, 
    .{ .lo = 0xc81, .hi = 0xc81 }, .{ .lo = 0xcbc, .hi = 0xcbc }, .{ .lo = 0xcbf, .hi = 0xcc0 }, .{ .lo = 0xcc2, .hi = 0xcc2 }, 
    .{ .lo = 0xcc6, .hi = 0xcc8 }, .{ .lo = 0xcca, .hi = 0xccd }, .{ .lo = 0xcd5, .hi = 0xcd6 }, .{ .lo = 0xce2, .hi = 0xce3 }, 
    .{ .lo = 0xd00, .hi = 0xd01 }, .{ .lo = 0xd3b, .hi = 0xd3c }, .{ .lo = 0xd3e, .hi = 0xd3e }, .{ .lo = 0xd41, .hi = 0xd44 }, 
    .{ .lo = 0xd4d, .hi = 0xd4d }, .{ .lo = 0xd57, .hi = 0xd57 }, .{ .lo = 0xd62, .hi = 0xd63 }, .{ .lo = 0xd81, .hi = 0xd81 }, 
    .{ .lo = 0xdca, .hi = 0xdca }, .{ .lo = 0xdcf, .hi = 0xdcf }, .{ .lo = 0xdd2, .hi = 0xdd4 }, .{ .lo = 0xdd6, .hi = 0xdd6 }, 
    .{ .lo = 0xddf, .hi = 0xddf }, .{ .lo = 0xe31, .hi = 0xe31 }, .{ .lo = 0xe34, .hi = 0xe3a }, .{ .lo = 0xe47, .hi = 0xe4e }, 
    .{ .lo = 0xeb1, .hi = 0xeb1 }, .{ .lo = 0xeb4, .hi = 0xebc }, .{ .lo = 0xec8, .hi = 0xece }, .{ .lo = 0xf18, .hi = 0xf19 }, 
    .{ .lo = 0xf35, .hi = 0xf35 }, .{ .lo = 0xf37, .hi = 0xf37 }, .{ .lo = 0xf39, .hi = 0xf39 }, .{ .lo = 0xf71, .hi = 0xf7e }, 
    .{ .lo = 0xf80, .hi = 0xf84 }, .{ .lo = 0xf86, .hi = 0xf87 }, .{ .lo = 0xf8d, .hi = 0xf97 }, .{ .lo = 0xf99, .hi = 0xfbc }, 
    .{ .lo = 0xfc6, .hi = 0xfc6 }, .{ .lo = 0x102d, .hi = 0x1030 }, .{ .lo = 0x1032, .hi = 0x1037 }, .{ .lo = 0x1039, .hi = 0x103a }, 
    .{ .lo = 0x103d, .hi = 0x103e }, .{ .lo = 0x1058, .hi = 0x1059 }, .{ .lo = 0x105e, .hi = 0x1060 }, .{ .lo = 0x1071, .hi = 0x1074 }, 
    .{ .lo = 0x1082, .hi = 0x1082 }, .{ .lo = 0x1085, .hi = 0x1086 }, .{ .lo = 0x108d, .hi = 0x108d }, .{ .lo = 0x109d, .hi = 0x109d }, 
    .{ .lo = 0x135d, .hi = 0x135f }, .{ .lo = 0x1712, .hi = 0x1715 }, .{ .lo = 0x1732, .hi = 0x1734 }, .{ .lo = 0x1752, .hi = 0x1753 }, 
    .{ .lo = 0x1772, .hi = 0x1773 }, .{ .lo = 0x17b4, .hi = 0x17b5 }, .{ .lo = 0x17b7, .hi = 0x17bd }, .{ .lo = 0x17c6, .hi = 0x17c6 }, 
    .{ .lo = 0x17c9, .hi = 0x17d3 }, .{ .lo = 0x17dd, .hi = 0x17dd }, .{ .lo = 0x180b, .hi = 0x180d }, .{ .lo = 0x180f, .hi = 0x180f }, 
    .{ .lo = 0x1885, .hi = 0x1886 }, .{ .lo = 0x18a9, .hi = 0x18a9 }, .{ .lo = 0x1920, .hi = 0x1922 }, .{ .lo = 0x1927, .hi = 0x1928 }, 
    .{ .lo = 0x1932, .hi = 0x1932 }, .{ .lo = 0x1939, .hi = 0x193b }, .{ .lo = 0x1a17, .hi = 0x1a18 }, .{ .lo = 0x1a1b, .hi = 0x1a1b }, 
    .{ .lo = 0x1a56, .hi = 0x1a56 }, .{ .lo = 0x1a58, .hi = 0x1a5e }, .{ .lo = 0x1a60, .hi = 0x1a60 }, .{ .lo = 0x1a62, .hi = 0x1a62 }, 
    .{ .lo = 0x1a65, .hi = 0x1a6c }, .{ .lo = 0x1a73, .hi = 0x1a7c }, .{ .lo = 0x1a7f, .hi = 0x1a7f }, .{ .lo = 0x1ab0, .hi = 0x1add }, 
    .{ .lo = 0x1ae0, .hi = 0x1aeb }, .{ .lo = 0x1b00, .hi = 0x1b03 }, .{ .lo = 0x1b34, .hi = 0x1b3d }, .{ .lo = 0x1b42, .hi = 0x1b44 }, 
    .{ .lo = 0x1b6b, .hi = 0x1b73 }, .{ .lo = 0x1b80, .hi = 0x1b81 }, .{ .lo = 0x1ba2, .hi = 0x1ba5 }, .{ .lo = 0x1ba8, .hi = 0x1bad }, 
    .{ .lo = 0x1be6, .hi = 0x1be6 }, .{ .lo = 0x1be8, .hi = 0x1be9 }, .{ .lo = 0x1bed, .hi = 0x1bed }, .{ .lo = 0x1bef, .hi = 0x1bf3 }, 
    .{ .lo = 0x1c2c, .hi = 0x1c33 }, .{ .lo = 0x1c36, .hi = 0x1c37 }, .{ .lo = 0x1cd0, .hi = 0x1cd2 }, .{ .lo = 0x1cd4, .hi = 0x1ce0 }, 
    .{ .lo = 0x1ce2, .hi = 0x1ce8 }, .{ .lo = 0x1ced, .hi = 0x1ced }, .{ .lo = 0x1cf4, .hi = 0x1cf4 }, .{ .lo = 0x1cf8, .hi = 0x1cf9 }, 
    .{ .lo = 0x1dc0, .hi = 0x1dff }, .{ .lo = 0x200c, .hi = 0x200c }, .{ .lo = 0x20d0, .hi = 0x20f0 }, .{ .lo = 0x2cef, .hi = 0x2cf1 }, 
    .{ .lo = 0x2d7f, .hi = 0x2d7f }, .{ .lo = 0x2de0, .hi = 0x2dff }, .{ .lo = 0x302a, .hi = 0x302f }, .{ .lo = 0x3099, .hi = 0x309a }, 
    .{ .lo = 0xa66f, .hi = 0xa672 }, .{ .lo = 0xa674, .hi = 0xa67d }, .{ .lo = 0xa69e, .hi = 0xa69f }, .{ .lo = 0xa6f0, .hi = 0xa6f1 }, 
    .{ .lo = 0xa802, .hi = 0xa802 }, .{ .lo = 0xa806, .hi = 0xa806 }, .{ .lo = 0xa80b, .hi = 0xa80b }, .{ .lo = 0xa825, .hi = 0xa826 }, 
    .{ .lo = 0xa82c, .hi = 0xa82c }, .{ .lo = 0xa8c4, .hi = 0xa8c5 }, .{ .lo = 0xa8e0, .hi = 0xa8f1 }, .{ .lo = 0xa8ff, .hi = 0xa8ff }, 
    .{ .lo = 0xa926, .hi = 0xa92d }, .{ .lo = 0xa947, .hi = 0xa951 }, .{ .lo = 0xa953, .hi = 0xa953 }, .{ .lo = 0xa980, .hi = 0xa982 }, 
    .{ .lo = 0xa9b3, .hi = 0xa9b3 }, .{ .lo = 0xa9b6, .hi = 0xa9b9 }, .{ .lo = 0xa9bc, .hi = 0xa9bd }, .{ .lo = 0xa9c0, .hi = 0xa9c0 }, 
    .{ .lo = 0xa9e5, .hi = 0xa9e5 }, .{ .lo = 0xaa29, .hi = 0xaa2e }, .{ .lo = 0xaa31, .hi = 0xaa32 }, .{ .lo = 0xaa35, .hi = 0xaa36 }, 
    .{ .lo = 0xaa43, .hi = 0xaa43 }, .{ .lo = 0xaa4c, .hi = 0xaa4c }, .{ .lo = 0xaa7c, .hi = 0xaa7c }, .{ .lo = 0xaab0, .hi = 0xaab0 }, 
    .{ .lo = 0xaab2, .hi = 0xaab4 }, .{ .lo = 0xaab7, .hi = 0xaab8 }, .{ .lo = 0xaabe, .hi = 0xaabf }, .{ .lo = 0xaac1, .hi = 0xaac1 }, 
    .{ .lo = 0xaaec, .hi = 0xaaed }, .{ .lo = 0xaaf6, .hi = 0xaaf6 }, .{ .lo = 0xabe5, .hi = 0xabe5 }, .{ .lo = 0xabe8, .hi = 0xabe8 }, 
    .{ .lo = 0xabed, .hi = 0xabed }, .{ .lo = 0xfb1e, .hi = 0xfb1e }, .{ .lo = 0xfe00, .hi = 0xfe0f }, .{ .lo = 0xfe20, .hi = 0xfe2f }, 
    .{ .lo = 0xff9e, .hi = 0xff9f }, .{ .lo = 0x101fd, .hi = 0x101fd }, .{ .lo = 0x102e0, .hi = 0x102e0 }, .{ .lo = 0x10376, .hi = 0x1037a }, 
    .{ .lo = 0x10a01, .hi = 0x10a03 }, .{ .lo = 0x10a05, .hi = 0x10a06 }, .{ .lo = 0x10a0c, .hi = 0x10a0f }, .{ .lo = 0x10a38, .hi = 0x10a3a }, 
    .{ .lo = 0x10a3f, .hi = 0x10a3f }, .{ .lo = 0x10ae5, .hi = 0x10ae6 }, .{ .lo = 0x10d24, .hi = 0x10d27 }, .{ .lo = 0x10d69, .hi = 0x10d6d }, 
    .{ .lo = 0x10eab, .hi = 0x10eac }, .{ .lo = 0x10efa, .hi = 0x10eff }, .{ .lo = 0x10f46, .hi = 0x10f50 }, .{ .lo = 0x10f82, .hi = 0x10f85 }, 
    .{ .lo = 0x11001, .hi = 0x11001 }, .{ .lo = 0x11038, .hi = 0x11046 }, .{ .lo = 0x11070, .hi = 0x11070 }, .{ .lo = 0x11073, .hi = 0x11074 }, 
    .{ .lo = 0x1107f, .hi = 0x11081 }, .{ .lo = 0x110b3, .hi = 0x110b6 }, .{ .lo = 0x110b9, .hi = 0x110ba }, .{ .lo = 0x110c2, .hi = 0x110c2 }, 
    .{ .lo = 0x11100, .hi = 0x11102 }, .{ .lo = 0x11127, .hi = 0x1112b }, .{ .lo = 0x1112d, .hi = 0x11134 }, .{ .lo = 0x11173, .hi = 0x11173 }, 
    .{ .lo = 0x11180, .hi = 0x11181 }, .{ .lo = 0x111b6, .hi = 0x111be }, .{ .lo = 0x111c0, .hi = 0x111c0 }, .{ .lo = 0x111c9, .hi = 0x111cc }, 
    .{ .lo = 0x111cf, .hi = 0x111cf }, .{ .lo = 0x1122f, .hi = 0x11231 }, .{ .lo = 0x11234, .hi = 0x11237 }, .{ .lo = 0x1123e, .hi = 0x1123e }, 
    .{ .lo = 0x11241, .hi = 0x11241 }, .{ .lo = 0x112df, .hi = 0x112df }, .{ .lo = 0x112e3, .hi = 0x112ea }, .{ .lo = 0x11300, .hi = 0x11301 }, 
    .{ .lo = 0x1133b, .hi = 0x1133c }, .{ .lo = 0x1133e, .hi = 0x1133e }, .{ .lo = 0x11340, .hi = 0x11340 }, .{ .lo = 0x1134d, .hi = 0x1134d }, 
    .{ .lo = 0x11357, .hi = 0x11357 }, .{ .lo = 0x11366, .hi = 0x1136c }, .{ .lo = 0x11370, .hi = 0x11374 }, .{ .lo = 0x113b8, .hi = 0x113b8 }, 
    .{ .lo = 0x113bb, .hi = 0x113c0 }, .{ .lo = 0x113c2, .hi = 0x113c2 }, .{ .lo = 0x113c5, .hi = 0x113c5 }, .{ .lo = 0x113c7, .hi = 0x113c9 }, 
    .{ .lo = 0x113ce, .hi = 0x113d0 }, .{ .lo = 0x113d2, .hi = 0x113d2 }, .{ .lo = 0x113e1, .hi = 0x113e2 }, .{ .lo = 0x11438, .hi = 0x1143f }, 
    .{ .lo = 0x11442, .hi = 0x11444 }, .{ .lo = 0x11446, .hi = 0x11446 }, .{ .lo = 0x1145e, .hi = 0x1145e }, .{ .lo = 0x114b0, .hi = 0x114b0 }, 
    .{ .lo = 0x114b3, .hi = 0x114b8 }, .{ .lo = 0x114ba, .hi = 0x114ba }, .{ .lo = 0x114bd, .hi = 0x114bd }, .{ .lo = 0x114bf, .hi = 0x114c0 }, 
    .{ .lo = 0x114c2, .hi = 0x114c3 }, .{ .lo = 0x115af, .hi = 0x115af }, .{ .lo = 0x115b2, .hi = 0x115b5 }, .{ .lo = 0x115bc, .hi = 0x115bd }, 
    .{ .lo = 0x115bf, .hi = 0x115c0 }, .{ .lo = 0x115dc, .hi = 0x115dd }, .{ .lo = 0x11633, .hi = 0x1163a }, .{ .lo = 0x1163d, .hi = 0x1163d }, 
    .{ .lo = 0x1163f, .hi = 0x11640 }, .{ .lo = 0x116ab, .hi = 0x116ab }, .{ .lo = 0x116ad, .hi = 0x116ad }, .{ .lo = 0x116b0, .hi = 0x116b7 }, 
    .{ .lo = 0x1171d, .hi = 0x1171d }, .{ .lo = 0x1171f, .hi = 0x1171f }, .{ .lo = 0x11722, .hi = 0x11725 }, .{ .lo = 0x11727, .hi = 0x1172b }, 
    .{ .lo = 0x1182f, .hi = 0x11837 }, .{ .lo = 0x11839, .hi = 0x1183a }, .{ .lo = 0x11930, .hi = 0x11930 }, .{ .lo = 0x1193b, .hi = 0x1193e }, 
    .{ .lo = 0x11943, .hi = 0x11943 }, .{ .lo = 0x119d4, .hi = 0x119d7 }, .{ .lo = 0x119da, .hi = 0x119db }, .{ .lo = 0x119e0, .hi = 0x119e0 }, 
    .{ .lo = 0x11a01, .hi = 0x11a0a }, .{ .lo = 0x11a33, .hi = 0x11a38 }, .{ .lo = 0x11a3b, .hi = 0x11a3e }, .{ .lo = 0x11a47, .hi = 0x11a47 }, 
    .{ .lo = 0x11a51, .hi = 0x11a56 }, .{ .lo = 0x11a59, .hi = 0x11a5b }, .{ .lo = 0x11a8a, .hi = 0x11a96 }, .{ .lo = 0x11a98, .hi = 0x11a99 }, 
    .{ .lo = 0x11b60, .hi = 0x11b60 }, .{ .lo = 0x11b62, .hi = 0x11b64 }, .{ .lo = 0x11b66, .hi = 0x11b66 }, .{ .lo = 0x11c30, .hi = 0x11c36 }, 
    .{ .lo = 0x11c38, .hi = 0x11c3d }, .{ .lo = 0x11c3f, .hi = 0x11c3f }, .{ .lo = 0x11c92, .hi = 0x11ca7 }, .{ .lo = 0x11caa, .hi = 0x11cb0 }, 
    .{ .lo = 0x11cb2, .hi = 0x11cb3 }, .{ .lo = 0x11cb5, .hi = 0x11cb6 }, .{ .lo = 0x11d31, .hi = 0x11d36 }, .{ .lo = 0x11d3a, .hi = 0x11d3a }, 
    .{ .lo = 0x11d3c, .hi = 0x11d3d }, .{ .lo = 0x11d3f, .hi = 0x11d45 }, .{ .lo = 0x11d47, .hi = 0x11d47 }, .{ .lo = 0x11d90, .hi = 0x11d91 }, 
    .{ .lo = 0x11d95, .hi = 0x11d95 }, .{ .lo = 0x11d97, .hi = 0x11d97 }, .{ .lo = 0x11ef3, .hi = 0x11ef4 }, .{ .lo = 0x11f00, .hi = 0x11f01 }, 
    .{ .lo = 0x11f36, .hi = 0x11f3a }, .{ .lo = 0x11f40, .hi = 0x11f42 }, .{ .lo = 0x11f5a, .hi = 0x11f5a }, .{ .lo = 0x13440, .hi = 0x13440 }, 
    .{ .lo = 0x13447, .hi = 0x13455 }, .{ .lo = 0x1611e, .hi = 0x16129 }, .{ .lo = 0x1612d, .hi = 0x1612f }, .{ .lo = 0x16af0, .hi = 0x16af4 }, 
    .{ .lo = 0x16b30, .hi = 0x16b36 }, .{ .lo = 0x16f4f, .hi = 0x16f4f }, .{ .lo = 0x16f8f, .hi = 0x16f92 }, .{ .lo = 0x16fe4, .hi = 0x16fe4 }, 
    .{ .lo = 0x16ff0, .hi = 0x16ff1 }, .{ .lo = 0x1bc9d, .hi = 0x1bc9e }, .{ .lo = 0x1cf00, .hi = 0x1cf2d }, .{ .lo = 0x1cf30, .hi = 0x1cf46 }, 
    .{ .lo = 0x1d165, .hi = 0x1d169 }, .{ .lo = 0x1d16d, .hi = 0x1d172 }, .{ .lo = 0x1d17b, .hi = 0x1d182 }, .{ .lo = 0x1d185, .hi = 0x1d18b }, 
    .{ .lo = 0x1d1aa, .hi = 0x1d1ad }, .{ .lo = 0x1d242, .hi = 0x1d244 }, .{ .lo = 0x1da00, .hi = 0x1da36 }, .{ .lo = 0x1da3b, .hi = 0x1da6c }, 
    .{ .lo = 0x1da75, .hi = 0x1da75 }, .{ .lo = 0x1da84, .hi = 0x1da84 }, .{ .lo = 0x1da9b, .hi = 0x1da9f }, .{ .lo = 0x1daa1, .hi = 0x1daaf }, 
    .{ .lo = 0x1e000, .hi = 0x1e006 }, .{ .lo = 0x1e008, .hi = 0x1e018 }, .{ .lo = 0x1e01b, .hi = 0x1e021 }, .{ .lo = 0x1e023, .hi = 0x1e024 }, 
    .{ .lo = 0x1e026, .hi = 0x1e02a }, .{ .lo = 0x1e08f, .hi = 0x1e08f }, .{ .lo = 0x1e130, .hi = 0x1e136 }, .{ .lo = 0x1e2ae, .hi = 0x1e2ae }, 
    .{ .lo = 0x1e2ec, .hi = 0x1e2ef }, .{ .lo = 0x1e4ec, .hi = 0x1e4ef }, .{ .lo = 0x1e5ee, .hi = 0x1e5ef }, .{ .lo = 0x1e6e3, .hi = 0x1e6e3 }, 
    .{ .lo = 0x1e6e6, .hi = 0x1e6e6 }, .{ .lo = 0x1e6ee, .hi = 0x1e6ef }, .{ .lo = 0x1e6f5, .hi = 0x1e6f5 }, .{ .lo = 0x1e8d0, .hi = 0x1e8d6 }, 
    .{ .lo = 0x1e944, .hi = 0x1e94a }, .{ .lo = 0xe0020, .hi = 0xe007f }, .{ .lo = 0xe0100, .hi = 0xe01ef }, 
};
const gcb_spacing_ranges = [_]Range{
    .{ .lo = 0x903, .hi = 0x903 }, .{ .lo = 0x93b, .hi = 0x93b }, .{ .lo = 0x93e, .hi = 0x940 }, .{ .lo = 0x949, .hi = 0x94c }, 
    .{ .lo = 0x94e, .hi = 0x94f }, .{ .lo = 0x982, .hi = 0x983 }, .{ .lo = 0x9be, .hi = 0x9c0 }, .{ .lo = 0x9c7, .hi = 0x9c8 }, 
    .{ .lo = 0x9cb, .hi = 0x9cc }, .{ .lo = 0x9d7, .hi = 0x9d7 }, .{ .lo = 0xa03, .hi = 0xa03 }, .{ .lo = 0xa3e, .hi = 0xa40 }, 
    .{ .lo = 0xa83, .hi = 0xa83 }, .{ .lo = 0xabe, .hi = 0xac0 }, .{ .lo = 0xac9, .hi = 0xac9 }, .{ .lo = 0xacb, .hi = 0xacc }, 
    .{ .lo = 0xb02, .hi = 0xb03 }, .{ .lo = 0xb3e, .hi = 0xb3e }, .{ .lo = 0xb40, .hi = 0xb40 }, .{ .lo = 0xb47, .hi = 0xb48 }, 
    .{ .lo = 0xb4b, .hi = 0xb4c }, .{ .lo = 0xb57, .hi = 0xb57 }, .{ .lo = 0xbbe, .hi = 0xbbf }, .{ .lo = 0xbc1, .hi = 0xbc2 }, 
    .{ .lo = 0xbc6, .hi = 0xbc8 }, .{ .lo = 0xbca, .hi = 0xbcc }, .{ .lo = 0xbd7, .hi = 0xbd7 }, .{ .lo = 0xc01, .hi = 0xc03 }, 
    .{ .lo = 0xc41, .hi = 0xc44 }, .{ .lo = 0xc82, .hi = 0xc83 }, .{ .lo = 0xcbe, .hi = 0xcbe }, .{ .lo = 0xcc0, .hi = 0xcc4 }, 
    .{ .lo = 0xcc7, .hi = 0xcc8 }, .{ .lo = 0xcca, .hi = 0xccb }, .{ .lo = 0xcd5, .hi = 0xcd6 }, .{ .lo = 0xcf3, .hi = 0xcf3 }, 
    .{ .lo = 0xd02, .hi = 0xd03 }, .{ .lo = 0xd3e, .hi = 0xd40 }, .{ .lo = 0xd46, .hi = 0xd48 }, .{ .lo = 0xd4a, .hi = 0xd4c }, 
    .{ .lo = 0xd57, .hi = 0xd57 }, .{ .lo = 0xd82, .hi = 0xd83 }, .{ .lo = 0xdcf, .hi = 0xdd1 }, .{ .lo = 0xdd8, .hi = 0xddf }, 
    .{ .lo = 0xdf2, .hi = 0xdf3 }, .{ .lo = 0xf3e, .hi = 0xf3f }, .{ .lo = 0xf7f, .hi = 0xf7f }, .{ .lo = 0x102b, .hi = 0x102c }, 
    .{ .lo = 0x1031, .hi = 0x1031 }, .{ .lo = 0x1038, .hi = 0x1038 }, .{ .lo = 0x103b, .hi = 0x103c }, .{ .lo = 0x1056, .hi = 0x1057 }, 
    .{ .lo = 0x1062, .hi = 0x1064 }, .{ .lo = 0x1067, .hi = 0x106d }, .{ .lo = 0x1083, .hi = 0x1084 }, .{ .lo = 0x1087, .hi = 0x108c }, 
    .{ .lo = 0x108f, .hi = 0x108f }, .{ .lo = 0x109a, .hi = 0x109c }, .{ .lo = 0x1715, .hi = 0x1715 }, .{ .lo = 0x1734, .hi = 0x1734 }, 
    .{ .lo = 0x17b6, .hi = 0x17b6 }, .{ .lo = 0x17be, .hi = 0x17c5 }, .{ .lo = 0x17c7, .hi = 0x17c8 }, .{ .lo = 0x1923, .hi = 0x1926 }, 
    .{ .lo = 0x1929, .hi = 0x192b }, .{ .lo = 0x1930, .hi = 0x1931 }, .{ .lo = 0x1933, .hi = 0x1938 }, .{ .lo = 0x1a19, .hi = 0x1a1a }, 
    .{ .lo = 0x1a55, .hi = 0x1a55 }, .{ .lo = 0x1a57, .hi = 0x1a57 }, .{ .lo = 0x1a61, .hi = 0x1a61 }, .{ .lo = 0x1a63, .hi = 0x1a64 }, 
    .{ .lo = 0x1a6d, .hi = 0x1a72 }, .{ .lo = 0x1b04, .hi = 0x1b04 }, .{ .lo = 0x1b35, .hi = 0x1b35 }, .{ .lo = 0x1b3b, .hi = 0x1b3b }, 
    .{ .lo = 0x1b3d, .hi = 0x1b41 }, .{ .lo = 0x1b43, .hi = 0x1b44 }, .{ .lo = 0x1b82, .hi = 0x1b82 }, .{ .lo = 0x1ba1, .hi = 0x1ba1 }, 
    .{ .lo = 0x1ba6, .hi = 0x1ba7 }, .{ .lo = 0x1baa, .hi = 0x1baa }, .{ .lo = 0x1be7, .hi = 0x1be7 }, .{ .lo = 0x1bea, .hi = 0x1bec }, 
    .{ .lo = 0x1bee, .hi = 0x1bee }, .{ .lo = 0x1bf2, .hi = 0x1bf3 }, .{ .lo = 0x1c24, .hi = 0x1c2b }, .{ .lo = 0x1c34, .hi = 0x1c35 }, 
    .{ .lo = 0x1ce1, .hi = 0x1ce1 }, .{ .lo = 0x1cf7, .hi = 0x1cf7 }, .{ .lo = 0x302e, .hi = 0x302f }, .{ .lo = 0xa823, .hi = 0xa824 }, 
    .{ .lo = 0xa827, .hi = 0xa827 }, .{ .lo = 0xa880, .hi = 0xa881 }, .{ .lo = 0xa8b4, .hi = 0xa8c3 }, .{ .lo = 0xa952, .hi = 0xa953 }, 
    .{ .lo = 0xa983, .hi = 0xa983 }, .{ .lo = 0xa9b4, .hi = 0xa9b5 }, .{ .lo = 0xa9ba, .hi = 0xa9bb }, .{ .lo = 0xa9be, .hi = 0xa9c0 }, 
    .{ .lo = 0xaa2f, .hi = 0xaa30 }, .{ .lo = 0xaa33, .hi = 0xaa34 }, .{ .lo = 0xaa4d, .hi = 0xaa4d }, .{ .lo = 0xaa7b, .hi = 0xaa7b }, 
    .{ .lo = 0xaa7d, .hi = 0xaa7d }, .{ .lo = 0xaaeb, .hi = 0xaaeb }, .{ .lo = 0xaaee, .hi = 0xaaef }, .{ .lo = 0xaaf5, .hi = 0xaaf5 }, 
    .{ .lo = 0xabe3, .hi = 0xabe4 }, .{ .lo = 0xabe6, .hi = 0xabe7 }, .{ .lo = 0xabe9, .hi = 0xabea }, .{ .lo = 0xabec, .hi = 0xabec }, 
    .{ .lo = 0x11000, .hi = 0x11000 }, .{ .lo = 0x11002, .hi = 0x11002 }, .{ .lo = 0x11082, .hi = 0x11082 }, .{ .lo = 0x110b0, .hi = 0x110b2 }, 
    .{ .lo = 0x110b7, .hi = 0x110b8 }, .{ .lo = 0x1112c, .hi = 0x1112c }, .{ .lo = 0x11145, .hi = 0x11146 }, .{ .lo = 0x11182, .hi = 0x11182 }, 
    .{ .lo = 0x111b3, .hi = 0x111b5 }, .{ .lo = 0x111bf, .hi = 0x111c0 }, .{ .lo = 0x111ce, .hi = 0x111ce }, .{ .lo = 0x1122c, .hi = 0x1122e }, 
    .{ .lo = 0x11232, .hi = 0x11233 }, .{ .lo = 0x11235, .hi = 0x11235 }, .{ .lo = 0x112e0, .hi = 0x112e2 }, .{ .lo = 0x11302, .hi = 0x11303 }, 
    .{ .lo = 0x1133e, .hi = 0x1133f }, .{ .lo = 0x11341, .hi = 0x11344 }, .{ .lo = 0x11347, .hi = 0x11348 }, .{ .lo = 0x1134b, .hi = 0x1134d }, 
    .{ .lo = 0x11357, .hi = 0x11357 }, .{ .lo = 0x11362, .hi = 0x11363 }, .{ .lo = 0x113b8, .hi = 0x113ba }, .{ .lo = 0x113c2, .hi = 0x113c2 }, 
    .{ .lo = 0x113c5, .hi = 0x113c5 }, .{ .lo = 0x113c7, .hi = 0x113ca }, .{ .lo = 0x113cc, .hi = 0x113cd }, .{ .lo = 0x113cf, .hi = 0x113cf }, 
    .{ .lo = 0x11435, .hi = 0x11437 }, .{ .lo = 0x11440, .hi = 0x11441 }, .{ .lo = 0x11445, .hi = 0x11445 }, .{ .lo = 0x114b0, .hi = 0x114b2 }, 
    .{ .lo = 0x114b9, .hi = 0x114b9 }, .{ .lo = 0x114bb, .hi = 0x114be }, .{ .lo = 0x114c1, .hi = 0x114c1 }, .{ .lo = 0x115af, .hi = 0x115b1 }, 
    .{ .lo = 0x115b8, .hi = 0x115bb }, .{ .lo = 0x115be, .hi = 0x115be }, .{ .lo = 0x11630, .hi = 0x11632 }, .{ .lo = 0x1163b, .hi = 0x1163c }, 
    .{ .lo = 0x1163e, .hi = 0x1163e }, .{ .lo = 0x116ac, .hi = 0x116ac }, .{ .lo = 0x116ae, .hi = 0x116af }, .{ .lo = 0x116b6, .hi = 0x116b6 }, 
    .{ .lo = 0x1171e, .hi = 0x1171e }, .{ .lo = 0x11720, .hi = 0x11721 }, .{ .lo = 0x11726, .hi = 0x11726 }, .{ .lo = 0x1182c, .hi = 0x1182e }, 
    .{ .lo = 0x11838, .hi = 0x11838 }, .{ .lo = 0x11930, .hi = 0x11935 }, .{ .lo = 0x11937, .hi = 0x11938 }, .{ .lo = 0x1193d, .hi = 0x1193d }, 
    .{ .lo = 0x11940, .hi = 0x11940 }, .{ .lo = 0x11942, .hi = 0x11942 }, .{ .lo = 0x119d1, .hi = 0x119d3 }, .{ .lo = 0x119dc, .hi = 0x119df }, 
    .{ .lo = 0x119e4, .hi = 0x119e4 }, .{ .lo = 0x11a39, .hi = 0x11a39 }, .{ .lo = 0x11a57, .hi = 0x11a58 }, .{ .lo = 0x11a97, .hi = 0x11a97 }, 
    .{ .lo = 0x11b61, .hi = 0x11b61 }, .{ .lo = 0x11b65, .hi = 0x11b65 }, .{ .lo = 0x11b67, .hi = 0x11b67 }, .{ .lo = 0x11c2f, .hi = 0x11c2f }, 
    .{ .lo = 0x11c3e, .hi = 0x11c3e }, .{ .lo = 0x11ca9, .hi = 0x11ca9 }, .{ .lo = 0x11cb1, .hi = 0x11cb1 }, .{ .lo = 0x11cb4, .hi = 0x11cb4 }, 
    .{ .lo = 0x11d8a, .hi = 0x11d8e }, .{ .lo = 0x11d93, .hi = 0x11d94 }, .{ .lo = 0x11d96, .hi = 0x11d96 }, .{ .lo = 0x11ef5, .hi = 0x11ef6 }, 
    .{ .lo = 0x11f03, .hi = 0x11f03 }, .{ .lo = 0x11f34, .hi = 0x11f35 }, .{ .lo = 0x11f3e, .hi = 0x11f3f }, .{ .lo = 0x11f41, .hi = 0x11f41 }, 
    .{ .lo = 0x1612a, .hi = 0x1612c }, .{ .lo = 0x16f51, .hi = 0x16f87 }, .{ .lo = 0x16ff0, .hi = 0x16ff1 }, .{ .lo = 0x1d165, .hi = 0x1d166 }, 
    .{ .lo = 0x1d16d, .hi = 0x1d172 }, 
};
const gcb_ri_ranges = [_]Range{
    .{ .lo = 0x1f1e6, .hi = 0x1f1ff }, 
};
const gcb_extpict_ranges = [_]Range{
    .{ .lo = 0xa9, .hi = 0xa9 }, .{ .lo = 0xae, .hi = 0xae }, .{ .lo = 0x203c, .hi = 0x203c }, .{ .lo = 0x2049, .hi = 0x2049 }, 
    .{ .lo = 0x2122, .hi = 0x2122 }, .{ .lo = 0x2139, .hi = 0x2139 }, .{ .lo = 0x2194, .hi = 0x2199 }, .{ .lo = 0x21a9, .hi = 0x21aa }, 
    .{ .lo = 0x231a, .hi = 0x231b }, .{ .lo = 0x2328, .hi = 0x2328 }, .{ .lo = 0x23cf, .hi = 0x23cf }, .{ .lo = 0x23e9, .hi = 0x23f3 }, 
    .{ .lo = 0x23f8, .hi = 0x23fa }, .{ .lo = 0x24c2, .hi = 0x24c2 }, .{ .lo = 0x25aa, .hi = 0x25ab }, .{ .lo = 0x25b6, .hi = 0x25b6 }, 
    .{ .lo = 0x25c0, .hi = 0x25c0 }, .{ .lo = 0x25fb, .hi = 0x25fe }, .{ .lo = 0x2600, .hi = 0x2604 }, .{ .lo = 0x260e, .hi = 0x260e }, 
    .{ .lo = 0x2611, .hi = 0x2611 }, .{ .lo = 0x2614, .hi = 0x2615 }, .{ .lo = 0x2618, .hi = 0x2618 }, .{ .lo = 0x261d, .hi = 0x261d }, 
    .{ .lo = 0x2620, .hi = 0x2620 }, .{ .lo = 0x2622, .hi = 0x2623 }, .{ .lo = 0x2626, .hi = 0x2626 }, .{ .lo = 0x262a, .hi = 0x262a }, 
    .{ .lo = 0x262e, .hi = 0x262f }, .{ .lo = 0x2638, .hi = 0x263a }, .{ .lo = 0x2640, .hi = 0x2640 }, .{ .lo = 0x2642, .hi = 0x2642 }, 
    .{ .lo = 0x2648, .hi = 0x2653 }, .{ .lo = 0x265f, .hi = 0x2660 }, .{ .lo = 0x2663, .hi = 0x2663 }, .{ .lo = 0x2665, .hi = 0x2666 }, 
    .{ .lo = 0x2668, .hi = 0x2668 }, .{ .lo = 0x267b, .hi = 0x267b }, .{ .lo = 0x267e, .hi = 0x267f }, .{ .lo = 0x2692, .hi = 0x2697 }, 
    .{ .lo = 0x2699, .hi = 0x2699 }, .{ .lo = 0x269b, .hi = 0x269c }, .{ .lo = 0x26a0, .hi = 0x26a1 }, .{ .lo = 0x26a7, .hi = 0x26a7 }, 
    .{ .lo = 0x26aa, .hi = 0x26ab }, .{ .lo = 0x26b0, .hi = 0x26b1 }, .{ .lo = 0x26bd, .hi = 0x26be }, .{ .lo = 0x26c4, .hi = 0x26c5 }, 
    .{ .lo = 0x26c8, .hi = 0x26c8 }, .{ .lo = 0x26ce, .hi = 0x26cf }, .{ .lo = 0x26d1, .hi = 0x26d1 }, .{ .lo = 0x26d3, .hi = 0x26d4 }, 
    .{ .lo = 0x26e9, .hi = 0x26ea }, .{ .lo = 0x26f0, .hi = 0x26f5 }, .{ .lo = 0x26f7, .hi = 0x26fa }, .{ .lo = 0x26fd, .hi = 0x26fd }, 
    .{ .lo = 0x2702, .hi = 0x2702 }, .{ .lo = 0x2705, .hi = 0x2705 }, .{ .lo = 0x2708, .hi = 0x270d }, .{ .lo = 0x270f, .hi = 0x270f }, 
    .{ .lo = 0x2712, .hi = 0x2712 }, .{ .lo = 0x2714, .hi = 0x2714 }, .{ .lo = 0x2716, .hi = 0x2716 }, .{ .lo = 0x271d, .hi = 0x271d }, 
    .{ .lo = 0x2721, .hi = 0x2721 }, .{ .lo = 0x2728, .hi = 0x2728 }, .{ .lo = 0x2733, .hi = 0x2734 }, .{ .lo = 0x2744, .hi = 0x2744 }, 
    .{ .lo = 0x2747, .hi = 0x2747 }, .{ .lo = 0x274c, .hi = 0x274c }, .{ .lo = 0x274e, .hi = 0x274e }, .{ .lo = 0x2753, .hi = 0x2755 }, 
    .{ .lo = 0x2757, .hi = 0x2757 }, .{ .lo = 0x2763, .hi = 0x2764 }, .{ .lo = 0x2795, .hi = 0x2797 }, .{ .lo = 0x27a1, .hi = 0x27a1 }, 
    .{ .lo = 0x27b0, .hi = 0x27b0 }, .{ .lo = 0x27bf, .hi = 0x27bf }, .{ .lo = 0x2934, .hi = 0x2935 }, .{ .lo = 0x2b05, .hi = 0x2b07 }, 
    .{ .lo = 0x2b1b, .hi = 0x2b1c }, .{ .lo = 0x2b50, .hi = 0x2b50 }, .{ .lo = 0x2b55, .hi = 0x2b55 }, .{ .lo = 0x3030, .hi = 0x3030 }, 
    .{ .lo = 0x303d, .hi = 0x303d }, .{ .lo = 0x3297, .hi = 0x3297 }, .{ .lo = 0x3299, .hi = 0x3299 }, .{ .lo = 0x1f004, .hi = 0x1f004 }, 
    .{ .lo = 0x1f02c, .hi = 0x1f02f }, .{ .lo = 0x1f094, .hi = 0x1f09f }, .{ .lo = 0x1f0af, .hi = 0x1f0b0 }, .{ .lo = 0x1f0c0, .hi = 0x1f0c0 }, 
    .{ .lo = 0x1f0cf, .hi = 0x1f0d0 }, .{ .lo = 0x1f0f6, .hi = 0x1f0ff }, .{ .lo = 0x1f170, .hi = 0x1f171 }, .{ .lo = 0x1f17e, .hi = 0x1f17f }, 
    .{ .lo = 0x1f18e, .hi = 0x1f18e }, .{ .lo = 0x1f191, .hi = 0x1f19a }, .{ .lo = 0x1f1ae, .hi = 0x1f1e5 }, .{ .lo = 0x1f201, .hi = 0x1f20f }, 
    .{ .lo = 0x1f21a, .hi = 0x1f21a }, .{ .lo = 0x1f22f, .hi = 0x1f22f }, .{ .lo = 0x1f232, .hi = 0x1f23a }, .{ .lo = 0x1f23c, .hi = 0x1f23f }, 
    .{ .lo = 0x1f249, .hi = 0x1f25f }, .{ .lo = 0x1f266, .hi = 0x1f321 }, .{ .lo = 0x1f324, .hi = 0x1f393 }, .{ .lo = 0x1f396, .hi = 0x1f397 }, 
    .{ .lo = 0x1f399, .hi = 0x1f39b }, .{ .lo = 0x1f39e, .hi = 0x1f3f0 }, .{ .lo = 0x1f3f3, .hi = 0x1f3f5 }, .{ .lo = 0x1f3f7, .hi = 0x1f3fa }, 
    .{ .lo = 0x1f400, .hi = 0x1f4fd }, .{ .lo = 0x1f4ff, .hi = 0x1f53d }, .{ .lo = 0x1f549, .hi = 0x1f54e }, .{ .lo = 0x1f550, .hi = 0x1f567 }, 
    .{ .lo = 0x1f56f, .hi = 0x1f570 }, .{ .lo = 0x1f573, .hi = 0x1f57a }, .{ .lo = 0x1f587, .hi = 0x1f587 }, .{ .lo = 0x1f58a, .hi = 0x1f58d }, 
    .{ .lo = 0x1f590, .hi = 0x1f590 }, .{ .lo = 0x1f595, .hi = 0x1f596 }, .{ .lo = 0x1f5a4, .hi = 0x1f5a5 }, .{ .lo = 0x1f5a8, .hi = 0x1f5a8 }, 
    .{ .lo = 0x1f5b1, .hi = 0x1f5b2 }, .{ .lo = 0x1f5bc, .hi = 0x1f5bc }, .{ .lo = 0x1f5c2, .hi = 0x1f5c4 }, .{ .lo = 0x1f5d1, .hi = 0x1f5d3 }, 
    .{ .lo = 0x1f5dc, .hi = 0x1f5de }, .{ .lo = 0x1f5e1, .hi = 0x1f5e1 }, .{ .lo = 0x1f5e3, .hi = 0x1f5e3 }, .{ .lo = 0x1f5e8, .hi = 0x1f5e8 }, 
    .{ .lo = 0x1f5ef, .hi = 0x1f5ef }, .{ .lo = 0x1f5f3, .hi = 0x1f5f3 }, .{ .lo = 0x1f5fa, .hi = 0x1f64f }, .{ .lo = 0x1f680, .hi = 0x1f6c5 }, 
    .{ .lo = 0x1f6cb, .hi = 0x1f6d2 }, .{ .lo = 0x1f6d5, .hi = 0x1f6e5 }, .{ .lo = 0x1f6e9, .hi = 0x1f6e9 }, .{ .lo = 0x1f6eb, .hi = 0x1f6f0 }, 
    .{ .lo = 0x1f6f3, .hi = 0x1f6ff }, .{ .lo = 0x1f7da, .hi = 0x1f7ff }, .{ .lo = 0x1f80c, .hi = 0x1f80f }, .{ .lo = 0x1f848, .hi = 0x1f84f }, 
    .{ .lo = 0x1f85a, .hi = 0x1f85f }, .{ .lo = 0x1f888, .hi = 0x1f88f }, .{ .lo = 0x1f8ae, .hi = 0x1f8af }, .{ .lo = 0x1f8bc, .hi = 0x1f8bf }, 
    .{ .lo = 0x1f8c2, .hi = 0x1f8cf }, .{ .lo = 0x1f8d9, .hi = 0x1f8ff }, .{ .lo = 0x1f90c, .hi = 0x1f93a }, .{ .lo = 0x1f93c, .hi = 0x1f945 }, 
    .{ .lo = 0x1f947, .hi = 0x1f9ff }, .{ .lo = 0x1fa58, .hi = 0x1fa5f }, .{ .lo = 0x1fa6e, .hi = 0x1faff }, .{ .lo = 0x1fc00, .hi = 0x1fffd }, 
};
const gcb_control_ranges = [_]Range{
    .{ .lo = 0x0, .hi = 0x1f }, .{ .lo = 0x7f, .hi = 0x9f }, .{ .lo = 0xad, .hi = 0xad }, .{ .lo = 0x600, .hi = 0x605 }, 
    .{ .lo = 0x61c, .hi = 0x61c }, .{ .lo = 0x6dd, .hi = 0x6dd }, .{ .lo = 0x70f, .hi = 0x70f }, .{ .lo = 0x890, .hi = 0x891 }, 
    .{ .lo = 0x8e2, .hi = 0x8e2 }, .{ .lo = 0x180e, .hi = 0x180e }, .{ .lo = 0x200b, .hi = 0x200b }, .{ .lo = 0x200e, .hi = 0x200f }, 
    .{ .lo = 0x202a, .hi = 0x202e }, .{ .lo = 0x2060, .hi = 0x2064 }, .{ .lo = 0x2066, .hi = 0x206f }, .{ .lo = 0xfeff, .hi = 0xfeff }, 
    .{ .lo = 0xfff9, .hi = 0xfffb }, .{ .lo = 0x110bd, .hi = 0x110bd }, .{ .lo = 0x110cd, .hi = 0x110cd }, .{ .lo = 0x13430, .hi = 0x1343f }, 
    .{ .lo = 0x1bca0, .hi = 0x1bca3 }, .{ .lo = 0x1d173, .hi = 0x1d17a }, .{ .lo = 0xe0001, .hi = 0xe0001 }, .{ .lo = 0xe0020, .hi = 0xe007f }, 
};

