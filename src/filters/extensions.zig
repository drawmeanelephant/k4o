//! Oliver opt-in syntax extensions — knap 0.6.0 filter group.
//!
//! Semantics follow the knap 0.6.0 oracle (tools/differential) and
//! `knap help` — see KNAP-FIDELITY.md.

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");
const engine = @import("../engine.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "callout",
    "wikilink",
    "footnote",
    "strike",
    "table",
    "table_pretty",
    "highlight",
    "math",
    "math_block",
    "comment",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    const name = call.name;
    if (std.mem.eql(u8, name, "callout")) {
        return emitCallout(it, call, input);
    }
    if (std.mem.eql(u8, name, "wikilink")) {
        return emitWikilink(it, call, input);
    }
    if (std.mem.eql(u8, name, "footnote")) {
        return emitFootnote(it, call, input);
    }
    if (std.mem.eql(u8, name, "strike")) {
        return wrapLeaves(it, input, {}, strikeLeaf);
    }
    if (std.mem.eql(u8, name, "highlight")) {
        const marker = try highlightMarker(it, call);
        return wrapLeaves(it, input, marker, highlightLeaf);
    }
    if (std.mem.eql(u8, name, "math")) {
        return wrapLeaves(it, input, {}, mathLeaf);
    }
    if (std.mem.eql(u8, name, "math_block")) {
        return wrapLeaves(it, input, {}, mathBlockLeaf);
    }
    if (std.mem.eql(u8, name, "comment")) {
        return wrapLeaves(it, input, {}, commentLeaf);
    }
    if (std.mem.eql(u8, name, "table")) {
        return emitTable(it, call, input, false);
    }
    if (std.mem.eql(u8, name, "table_pretty")) {
        return emitTable(it, call, input, true);
    }
    return null;
}

// --------------------------------------------------------------------
// Marker wrappers (strike / highlight / math / math_block / comment)

/// Vectorize a leaf wrap: string leaves inside containers are mapped
/// (object values too, keys preserved), while a top-level number or
/// boolean wraps its scalar text (`42 | strike` -> `~~42~~`). Null and
/// other containers pass through exactly like `mapStrings`.
fn wrapLeaves(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .integer, .float, .bool => {
            const t = (try filters.scalarText(it.alloc, v.*)).?;
            return it.make(.{ .string = try f(ctx, it, t) });
        },
        else => return filters.mapStrings(it, v, true, ctx, f),
    }
}

/// `open..core..close` with surrounding whitespace kept outside; a
/// whitespace-only or empty string is returned untouched.
fn inlineWrap(open: []const u8, close: []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    const w = filters.splitWrap(s);
    if (w.core.len == 0) return s;
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(it.alloc, w.ws_start);
    try out.appendSlice(it.alloc, open);
    try out.appendSlice(it.alloc, w.core);
    try out.appendSlice(it.alloc, close);
    try out.appendSlice(it.alloc, w.ws_end);
    return out.toOwnedSlice(it.alloc);
}

/// `open\ncore\nclose`; whitespace-only leading and trailing LINES ride
/// outside the fences (`"a\n"` -> `"$$\na\n$$\n"`, `"\n"` -> `"\n"`),
/// while other boundary whitespace stays inside — oracle-observed.
fn blockWrap(open: []const u8, close: []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    var lead_end: usize = 0;
    for (s, 0..) |c, i| {
        if (!isWs(c)) break;
        if (c == '\n') lead_end = i + 1;
    }
    var run_start: usize = s.len;
    while (run_start > lead_end and isWs(s[run_start - 1])) run_start -= 1;
    var trail_start: usize = s.len;
    for (run_start..s.len) |j| {
        if (s[j] == '\n') {
            trail_start = j;
            break;
        }
    }
    if (lead_end >= trail_start) return s;
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(it.alloc, s[0..lead_end]);
    try out.appendSlice(it.alloc, open);
    try out.append(it.alloc, '\n');
    try out.appendSlice(it.alloc, s[lead_end..trail_start]);
    try out.append(it.alloc, '\n');
    try out.appendSlice(it.alloc, close);
    try out.appendSlice(it.alloc, s[trail_start..]);
    return out.toOwnedSlice(it.alloc);
}

fn isWs(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        else => false,
    };
}

/// Block fences when the text holds a line break, inline markers
/// otherwise — oracle-observed for `math` and `comment`.
fn autoBlock(open: []const u8, close: []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) {
        return blockWrap(open, close, it, s);
    }
    return inlineWrap(open, close, it, s);
}

fn strikeLeaf(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    return inlineWrap("~~", "~~", it, s);
}

fn commentLeaf(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    return autoBlock("%%", "%%", it, s);
}

fn mathLeaf(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) {
        return blockWrap("$$", "$$", it, s);
    }
    return inlineWrap("$", "$", it, s);
}

fn mathBlockLeaf(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    return blockWrap("$$", "$$", it, s);
}

/// `==..x..==` where the marker carries an optional color emoji.
fn highlightLeaf(open: []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    return inlineWrap(open, "==", it, s);
}

fn highlightMarker(it: *Interp, call: parse.FilterCall) Error![]const u8 {
    var color = std.ArrayList(u8).empty;
    for (0..call.params.len) |i| {
        const pv = (try filters.param(it, call, i)).?;
        if (i > 0) try color.append(it.alloc, ',');
        try color.appendSlice(it.alloc, try filters.jsToString(it.alloc, pv));
    }
    const emoji: []const u8 = if (std.mem.eql(u8, color.items, "red"))
        "🔴"
    else if (std.mem.eql(u8, color.items, "orange"))
        "🟠"
    else if (std.mem.eql(u8, color.items, "yellow"))
        "🟡"
    else if (std.mem.eql(u8, color.items, "green"))
        "🟢"
    else if (std.mem.eql(u8, color.items, "blue"))
        "🔵"
    else if (std.mem.eql(u8, color.items, "purple"))
        "🟣"
    else if (color.items.len == 0)
        ""
    else
        return filters.badArg(it, call, "filter 'highlight' invalid color \"{s}\" (use red, orange, yellow, green, blue, or purple)", .{color.items});
    return std.fmt.allocPrint(it.alloc, "=={s}", .{emoji});
}

// --------------------------------------------------------------------
// callout

/// `> [!type] title` — Obsidian callout; a `true`/`false` third argument
/// adds the `-`/`+` fold marker. Containers render as compact JSON.
fn emitCallout(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    const args = try calloutParams(it, call);
    const typ = if (args.len > 0) blk: {
        const t = try filters.jsToString(it.alloc, args[0]);
        break :blk if (t.len == 0) "info" else t;
    } else "info";
    const title = if (args.len > 1) try filters.jsToString(it.alloc, args[1]) else "";
    const fold: []const u8 = if (args.len > 2) blk: {
        const f = try filters.jsToString(it.alloc, args[2]);
        if (std.ascii.eqlIgnoreCase(f, "true")) break :blk "-";
        if (std.ascii.eqlIgnoreCase(f, "false")) break :blk "+";
        break :blk "";
    } else "";

    const v = try filters.normalizeInput(it, unwrapSingle(input));
    const body = (try filters.scalarText(it.alloc, v.*)) orelse blk: {
        var buf: std.Io.Writer.Allocating = .init(it.alloc);
        try it.jsStringify(v, &buf);
        break :blk buf.written();
    };

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(it.alloc, "> [!");
    try out.appendSlice(it.alloc, typ);
    try out.append(it.alloc, ']');
    try out.appendSlice(it.alloc, fold);
    if (title.len > 0) {
        try out.append(it.alloc, ' ');
        try out.appendSlice(it.alloc, title);
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(it.alloc, "\n> ");
        try out.appendSlice(it.alloc, line);
    }
    return it.make(.{ .string = out.items });
}

/// Evaluate the call's argument values. k4o's scanner folds an unquoted
/// `a,b` into one bare token, while the oracle always treats commas as
/// argument separators (parens or not) — so a lone literal argument that
/// holds a comma and was not quoted in the source is split and each piece
/// evaluated on its own. `(a,"b")`-style mixes still fail in the parser
/// before reaching here; quoted `"a,b"` stays whole, matching the oracle.
fn calloutParams(it: *Interp, call: parse.FilterCall) Error![]const *const Value {
    if (call.params.len == 1 and call.params[0] == .value) {
        const v = try it.evalParam(call.params[0].value);
        if (v.* == .string and
            std.mem.indexOfScalar(u8, v.string, ',') != null and
            rawArgUnquoted(it, call))
        {
            var vals = std.ArrayList(*const Value).empty;
            var pieces = std.mem.splitScalar(u8, v.string, ',');
            while (pieces.next()) |piece| {
                const p = std.mem.trim(u8, piece, " \t\r\n");
                const e = try pieceExpr(it, call.offset, p);
                try vals.append(it.alloc, try it.evalParam(e));
            }
            return vals.items;
        }
        const vals = try it.alloc.alloc(*const Value, 1);
        vals[0] = v;
        return vals;
    }
    const vals = try it.alloc.alloc(*const Value, call.params.len);
    for (call.params, 0..) |prm, i| {
        vals[i] = switch (prm) {
            .value => |e| try it.evalParam(e),
            else => return filters.badArg(it, call, "filter '{s}' does not take a key:value or arrow argument here", .{call.name}),
        };
    }
    return vals;
}

/// The raw `:`-argument text was written without quotes — the marker that
/// separates an unquoted `a,b` (splittable) from a quoted `"a,b"` (one
/// string, per the oracle).
fn rawArgUnquoted(it: *Interp, call: parse.FilterCall) bool {
    const t = it.template;
    var i = call.offset + call.name.len;
    if (i >= t.len or t[i] != ':') return false;
    i += 1;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    if (i >= t.len or t[i] == '"' or t[i] == '\'') return false;
    if (t[i] != '(') return true;
    i += 1;
    while (i < t.len and t[i] != ')') : (i += 1) {
        if (t[i] == '"' or t[i] == '\'') return false;
    }
    return i < t.len;
}

/// One re-split argument piece as an evaluable expression: booleans, null,
/// numbers, paths (which may resolve against data, `callout:(k,5,true)`
/// -> `[!warn]- 5`), else a literal string — the same classification the
/// param scanner applies to bare tokens.
fn pieceExpr(it: *Interp, offset: usize, piece: []const u8) Error!*const parse.Expr {
    var primary: parse.Primary = undefined;
    if (std.mem.eql(u8, piece, "true")) {
        primary = .{ .literal = .{ .boolean = true } };
    } else if (std.mem.eql(u8, piece, "false")) {
        primary = .{ .literal = .{ .boolean = false } };
    } else if (std.mem.eql(u8, piece, "null")) {
        primary = .{ .literal = .null };
    } else if (std.fmt.parseInt(i64, piece, 10) catch null) |n| {
        primary = .{ .literal = .{ .integer = n } };
    } else if (std.fmt.parseFloat(f64, piece) catch null) |f| {
        primary = .{ .literal = .{ .float = f } };
    } else if (try piecePath(it, piece)) |p| {
        primary = .{ .path = p };
    } else {
        primary = .{ .literal = .{ .string = piece } };
    }
    const terms = try it.alloc.alloc(parse.Pipeline, 1);
    terms[0] = .{ .value = primary, .filters = &.{}, .offset = offset };
    const e = try it.alloc.create(parse.Expr);
    e.* = .{ .terms = terms };
    return e;
}

/// `name`, `a.b`, `a[0]` -> Path, else null (same shape test as
/// `looksLikePath` in parse.zig).
fn piecePath(it: *Interp, piece: []const u8) Error!?parse.Path {
    if (piece.len == 0 or
        !(std.ascii.isAlphabetic(piece[0]) or piece[0] == '_')) return null;
    for (piece) |c| {
        if (!isPieceNameChar(c) and c != '.' and c != '[' and c != ']') return null;
    }
    var steps = std.ArrayList(parse.Step).empty;
    var i: usize = 0;
    while (i < piece.len and isPieceNameChar(piece[i])) i += 1;
    const root = piece[0..i];
    while (i < piece.len) {
        if (piece[i] == '.') {
            i += 1;
            const start = i;
            while (i < piece.len and isPieceNameChar(piece[i])) i += 1;
            if (i == start) return null;
            try steps.append(it.alloc, .{ .key = piece[start..i] });
        } else if (piece[i] == '[') {
            i += 1;
            const start = i;
            while (i < piece.len and std.ascii.isDigit(piece[i])) i += 1;
            if (i == start or i >= piece.len or piece[i] != ']') return null;
            const idx = std.fmt.parseInt(u64, piece[start..i], 10) catch return null;
            i += 1;
            try steps.append(it.alloc, .{ .index = idx });
        } else return null;
    }
    return .{ .root = root, .steps = steps.items };
}

fn isPieceNameChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '.', '[', ']', '|', ':', '(', ')', '!', '=', '<', '>', '&', '\'', '"', '{', '}', '%', ',', '#', '\\', '?', '$', '/', '-' => false,
        else => true,
    };
}

// --------------------------------------------------------------------
// wikilink

/// `[[target]]` / `[[target|alias]]` — strings and array elements take the
/// joined parameter as alias; containers flatten into `[[key|value]]`
/// entries (object keys, array indexes) returned as an array.
fn emitWikilink(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    var alias = std.ArrayList(u8).empty;
    for (0..call.params.len) |i| {
        const pv = (try filters.param(it, call, i)).?;
        if (i > 0) try alias.append(it.alloc, ',');
        try alias.appendSlice(it.alloc, try filters.jsToString(it.alloc, pv));
    }

    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .string, .number_string => {
            const t = (try filters.scalarText(it.alloc, v.*)).?;
            // Whitespace-only input passes through untouched.
            if (std.mem.trim(u8, t, " \t\r\n").len == 0) return v;
            return it.make(.{ .string = try wikiScalar(it, t, alias.items) });
        },
        .array, .object => {
            var items = std.ArrayList(Value).empty;
            if (v.* == .array) {
                for (v.array.items) |*item| try wikilinkElem(it, item, alias.items, &items);
            } else {
                var it2 = v.object.iterator();
                while (it2.next()) |entry| try wikilinkKeyed(it, entry.key_ptr.*, entry.value_ptr, &items);
            }
            var list = std.json.Array.init(it.alloc);
            try list.appendSlice(items.items);
            // The oracle emits the serialized JSON text, so a single
            // `["[[k|v]]"]` stays bracketed instead of unwrapping.
            const arr = try it.make(.{ .array = list });
            var buf: std.Io.Writer.Allocating = .init(it.alloc);
            try it.jsStringify(arr, &buf);
            return it.make(.{ .string = buf.written() });
        },
        else => return v,
    }
}

/// One array slot: scalars get `[[v]]`/`[[v|alias]]`, null and empty
/// strings collapse to `""`, containers spread into keyed entries.
fn wikilinkElem(it: *Interp, item: *const Value, alias: []const u8, list: *std.ArrayList(Value)) Error!void {
    switch (item.*) {
        .array, .object => try wikilinkSpread(it, item, list),
        .null => try list.append(it.alloc, .{ .string = "" }),
        else => {
            const t = (try filters.scalarText(it.alloc, item.*)).?;
            try list.append(it.alloc, .{ .string = try wikiScalar(it, t, alias) });
        },
    }
}

/// A container appearing where a wikilink element is expected spreads into
/// `[[key|value]]` entries — object keys or array indexes, recursively.
fn wikilinkSpread(it: *Interp, v: *const Value, list: *std.ArrayList(Value)) Error!void {
    switch (v.*) {
        .array => |arr| {
            for (arr.items, 0..) |*item, i| {
                const key = try std.fmt.allocPrint(it.alloc, "{d}", .{i});
                try wikilinkKeyed(it, key, item, list);
            }
        },
        .object => |obj| {
            var it2 = obj.iterator();
            while (it2.next()) |entry| try wikilinkKeyed(it, entry.key_ptr.*, entry.value_ptr, list);
        },
        else => unreachable,
    }
}

fn wikilinkKeyed(it: *Interp, key: []const u8, v: *const Value, list: *std.ArrayList(Value)) Error!void {
    switch (v.*) {
        .array, .object => try wikilinkSpread(it, v, list),
        else => try list.append(it.alloc, .{ .string = try std.fmt.allocPrint(it.alloc, "[[{s}|{s}]]", .{ key, try jsStr(it, v) }) }),
    }
}

fn wikiScalar(it: *Interp, text: []const u8, alias: []const u8) Error![]const u8 {
    if (text.len == 0) return "";
    if (alias.len == 0) return std.fmt.allocPrint(it.alloc, "[[{s}]]", .{text});
    return std.fmt.allocPrint(it.alloc, "[[{s}|{s}]]", .{ text, alias });
}

// --------------------------------------------------------------------
// footnote

/// `[^label]: text` definitions joined by blank lines. Array labels are
/// one-based numbers; object keys are kebab-cased. Non-containers pass
/// through, as do single-element arrays holding a primitive — but only
/// when the array was typed input, not a serialized-collection string
/// (oracle: `["a"]` -> `a`, `"[\"a\"]"` -> `[^1]: a`).
fn emitFootnote(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    _ = call;
    const unwrapped = unwrapSingle(input);
    if (unwrapped != input) return unwrapped;
    const v = try filters.normalizeInput(it, input);
    var out = std.ArrayList(u8).empty;
    switch (v.*) {
        .array => |arr| {
            for (arr.items, 0..) |*item, i| {
                if (out.items.len > 0) try out.appendSlice(it.alloc, "\n\n");
                try out.appendSlice(it.alloc, "[^");
                try out.appendSlice(it.alloc, try std.fmt.allocPrint(it.alloc, "{d}", .{i + 1}));
                try out.appendSlice(it.alloc, "]: ");
                try out.appendSlice(it.alloc, try jsStr(it, item));
            }
        },
        .object => |obj| {
            var it2 = obj.iterator();
            while (it2.next()) |entry| {
                if (out.items.len > 0) try out.appendSlice(it.alloc, "\n\n");
                try out.appendSlice(it.alloc, "[^");
                try out.appendSlice(it.alloc, try kebabKey(it, entry.key_ptr.*));
                try out.appendSlice(it.alloc, "]: ");
                try out.appendSlice(it.alloc, try jsStr(it, entry.value_ptr));
            }
        },
        else => return v,
    }
    return it.make(.{ .string = out.items });
}

/// The shared input contract seen across the oracle: a single-element
/// array holding a primitive (string, number, boolean — JS `typeof`
/// makes null an object) unwraps to the element before filtering.
fn unwrapSingle(input: *const Value) *const Value {
    if (input.* != .array) return input;
    const items = input.array.items;
    if (items.len != 1) return input;
    return switch (items[0]) {
        .array, .object, .null => input,
        else => &items[0],
    };
}

/// JavaScript's `String(v)`: null is `"null"` as a value but collapses
/// inside array joins (`[1,null]` -> `"1,"`), objects are
/// "[object Object]".
fn jsStr(it: *Interp, v: *const Value) Error![]const u8 {
    switch (v.*) {
        .null => return "null",
        .object => return "[object Object]",
        .array => |arr| {
            var out = std.ArrayList(u8).empty;
            for (arr.items, 0..) |*item, i| {
                if (i > 0) try out.append(it.alloc, ',');
                if (item.* != .null) {
                    try out.appendSlice(it.alloc, try jsStr(it, item));
                }
            }
            return out.toOwnedSlice(it.alloc);
        },
        else => return (try filters.scalarText(it.alloc, v.*)).?,
    }
}

/// `First Note` -> `first-note`: a `-` at lower-to-upper boundaries,
/// whitespace and `_` runs collapse to one `-`, then all-lowercase.
fn kebabKey(it: *Interp, key: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var prev_lower = false;
    for (key) |c| {
        if (c == '_' or std.ascii.isWhitespace(c)) {
            if (out.items.len == 0 or out.items[out.items.len - 1] != '-') {
                try out.append(it.alloc, '-');
            }
            prev_lower = false;
        } else if (std.ascii.isUpper(c)) {
            if (prev_lower) try out.append(it.alloc, '-');
            try out.append(it.alloc, std.ascii.toLower(c));
            prev_lower = false;
        } else {
            try out.append(it.alloc, c);
            prev_lower = std.ascii.isLower(c);
        }
    }
    return out.toOwnedSlice(it.alloc);
}

/// `table`/`table_pretty`: pipes are compact (`| ` and ` |`), pretty
/// pads every column to its widest cell (minimum 3) with a `---`
/// separator row.
fn emitTable(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
    pretty: bool,
) Error!*const Value {
    const unwrapped = unwrapSingle(input);
    const v = try filters.normalizeInput(it, unwrapped);

    var headers = std.ArrayList([]const u8).empty;
    var rows = std.ArrayList([]const []const u8).empty;
    var width: usize = 0;

    var param_headers = std.ArrayList([]const u8).empty;
    for (call.params) |prm| {
        switch (prm) {
            .value => |e| {
                const pv = try it.evalParam(e);
                const t = (try filters.scalarText(it.alloc, pv.*)) orelse
                    return filters.badArg(it, call, "filter '{s}' column names must be text", .{call.name});
                try param_headers.append(it.alloc, t);
            },
            else => {},
        }
    }

    switch (v.*) {
        .object => |obj| {
            // An object becomes [key, value] row pairs with the first
            // entry acting as the header — oracle-observed.
            var it2 = obj.iterator();
            var first = true;
            while (it2.next()) |entry| {
                const val = try cellText(it, entry.value_ptr);
                if (first) {
                    try headers.append(it.alloc, entry.key_ptr.*);
                    try headers.append(it.alloc, val);
                    first = false;
                } else {
                    const row = try it.alloc.alloc([]const u8, 2);
                    row[0] = entry.key_ptr.*;
                    row[1] = val;
                    try rows.append(it.alloc, row);
                }
            }
            width = 2;
        },
        .array => |arr| {
            var all_obj = arr.items.len > 0;
            var all_arr = arr.items.len > 0;
            for (arr.items) |item| {
                if (item != .object) all_obj = false;
                if (item != .array) all_arr = false;
            }
            if (all_obj) {
                // Headers come from the first object's keys only.
                const first = arr.items[0].object;
                var it2 = first.iterator();
                while (it2.next()) |entry| try headers.append(it.alloc, entry.key_ptr.*);
                width = headers.items.len;
                for (arr.items) |*item| {
                    const row = try it.alloc.alloc([]const u8, width);
                    for (headers.items, 0..) |h, i| {
                        const obj = item.object;
                        row[i] = if (obj.get(h)) |val| try cellText(it, &val) else "";
                    }
                    try rows.append(it.alloc, row);
                }
            } else if (all_arr) {
                for (arr.items) |item| {
                    width = @max(width, item.array.items.len);
                }
                if (param_headers.items.len > 0) {
                    headers = param_headers;
                } else {
                    for (0..width) |_| try headers.append(it.alloc, "");
                }
                for (arr.items) |item| {
                    const row = try it.alloc.alloc([]const u8, width);
                    for (0..width) |i| {
                        row[i] = if (i < item.array.items.len)
                            try cellText(it, &item.array.items[i])
                        else
                            "";
                    }
                    try rows.append(it.alloc, row);
                }
            } else {
                width = 1;
                if (param_headers.items.len > 0) {
                    headers = param_headers;
                } else {
                    try headers.append(it.alloc, "Value");
                }
                for (arr.items) |*item| {
                    const row = try it.alloc.alloc([]const u8, 1);
                    row[0] = try cellText(it, item);
                    try rows.append(it.alloc, row);
                }
            }
        },
        else => {
            // Non-container input passes through untouched — scalars and
            // non-JSON strings render as themselves (oracle-observed).
            return v;
        },
    }

    while (headers.items.len < width) try headers.append(it.alloc, "");

    var out = std.ArrayList(u8).empty;
    if (!pretty) {
        try writeRow(&out, it, headers.items, false, null);
        const sep = try it.alloc.alloc([]const u8, width);
        for (0..width) |i| sep[i] = "-";
        try writeRow(&out, it, sep, false, null);
        for (rows.items) |row| try writeRow(&out, it, row, false, null);
    } else {
        const widths = try it.alloc.alloc(usize, width);
        @memset(widths, 3);
        for (headers.items, 0..) |h, i| widths[i] = @max(widths[i], h.len);
        for (rows.items) |row| {
            for (row, 0..) |cell, i| widths[i] = @max(widths[i], cell.len);
        }
        try writeRow(&out, it, headers.items, true, widths);
        const seps = try it.alloc.alloc([]const u8, width);
        for (0..width) |i| {
            const dashes = try it.alloc.alloc(u8, widths[i]);
            @memset(dashes, '-');
            seps[i] = dashes;
        }
        try writeRow(&out, it, seps, true, widths);
        for (rows.items) |row| try writeRow(&out, it, row, true, widths);
    }
    return it.make(.{ .string = out.items });
}

fn writeRow(
    out: *std.ArrayList(u8),
    it: *Interp,
    cells: []const []const u8,
    pretty: bool,
    widths: ?[]const usize,
) Error!void {
    if (out.items.len > 0) try out.append(it.alloc, '\n');
    try out.appendSlice(it.alloc, "| ");
    for (cells, 0..) |cell, i| {
        if (i != 0) try out.appendSlice(it.alloc, " | ");
        try out.appendSlice(it.alloc, cell);
        if (pretty) {
            if (i < widths.?.len) {
                var pad = widths.?[i] -| cell.len;
                while (pad > 0) : (pad -= 1) try out.append(it.alloc, ' ');
            }
        }
    }
    try out.appendSlice(it.alloc, " |");
}

/// Cell text: scalars render as themselves with `|` escaped; containers
/// take JavaScript's `String(v)` — `[object Object]` for objects,
/// comma-joins for arrays, `null` for null.
fn cellText(it: *Interp, v: *const Value) Error![]const u8 {
    const raw = try jsStr(it, v);
    if (std.mem.indexOfScalar(u8, raw, '|') == null) return raw;
    var out = std.ArrayList(u8).empty;
    for (raw) |c| {
        if (c == '|') try out.append(it.alloc, '\\');
        try out.append(it.alloc, c);
    }
    return out.toOwnedSlice(it.alloc);
}
