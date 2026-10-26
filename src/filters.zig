//! The knap filter registry: dispatch, shared helpers, per-group modules.
//!
//! Filter names, arguments, value handling and diagnostics are shared;
//! markup emitters live in filters/markup.zig and friends. Semantics follow
//! the knap 0.6.0 oracle (tools/differential) and `knap help` — see
//! KNAP-FIDELITY.md.
//!
//! Typed pipeline contract: filters receive `*const std.json.Value` and
//! return handles into the arena. Strings that look like serialized
//! collections are parsed first ("serialized arrays and objects produced by
//! another filter are recognized automatically"). Text filters recurse over
//! arrays (and, per filter, object values) while non-strings pass through —
//! `["a","b"] | bold` -> `["**a**","**b**"]`.

const std = @import("std");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const engine = @import("engine.zig");

pub const markup = @import("filters/markup.zig");
pub const text = @import("filters/text.zig");
pub const numbers = @import("filters/numbers.zig");
pub const dates = @import("filters/dates.zig");
pub const collections = @import("filters/collections.zig");
pub const extensions = @import("filters/extensions.zig");
pub const advanced = @import("filters/advanced.zig");
const transform = @import("filters/transform.zig");
pub const html = @import("filters/html.zig");

pub const Error = error{ Template, OutOfMemory };
pub const Format = enum { markdown, oliver };

pub const Interp = engine.Interp;
pub const Value = std.json.Value;

// transform runs ahead of advanced so `map`/`template` — which live in
// advanced's registry names — hit the implemented module first.
const modules = .{ markup, text, numbers, dates, collections, extensions, transform, advanced, html };

/// The complete registry: every filter name the oracle's CLI knows. Each
/// implemented name needs at least one fixture case; the blocked set below
/// renders a documented diagnostic instead.
pub const entries = markup.names ++ text.names ++ numbers.names ++
    dates.names ++ collections.names ++ extensions.names ++
    advanced.names ++ html.names ++ blocked_names;

/// Filters that exist in the oracle but cannot work in an embeddable
/// engine: DOM-dependent (upstream segregates them into `knap/html`) or a

pub const blocked_names = [_][]const u8{ "html_to_json", "remove_html" };

/// Registered names whose implementations have not landed yet — the
/// property test skips these. Empty: every registered filter has an
/// implementation and a fixture.
pub const pending = [_][]const u8{};

pub fn registry() []const []const u8 {
    return &entries;
}

pub fn isRegistered(name: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e, name)) return true;
    }
    return false;
}

fn isBlocked(name: []const u8) bool {
    for (blocked_names) |e| {
        if (std.mem.eql(u8, e, name)) return true;
    }
    return false;
}

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!*const Value {
    inline for (modules) |m| {
        if (try m.apply(it, call, input)) |v| return v;
    }
    if (isBlocked(call.name)) {
        return diag.fail(it.alloc, it.diag, .render, it.template, call.offset, "filter '{s}' is not supported by k4o (it needs a host environment)", .{call.name});
    }
    return diag.fail(it.alloc, it.diag, .unknown_filter, it.template, call.offset, "no filter named \"{s}\"", .{call.name});
}

// --------------------------------------------------------------------
// Shared helpers for the filter modules.

/// Fail with a bad-argument diagnostic positioned at the filter call.
pub fn badArg(
    it: *Interp,
    call: parse.FilterCall,
    comptime fmt: []const u8,
    args: anytype,
) error{Template} {
    return diag.fail(it.alloc, it.diag, .bad_argument, it.template, call.offset, fmt, args);
}

/// Fail with a render diagnostic positioned at the filter call.
pub fn failAt(
    it: *Interp,
    offset: usize,
    comptime fmt: []const u8,
    args: anytype,
) error{Template} {
    return diag.fail(it.alloc, it.diag, .render, it.template, offset, fmt, args);
}

/// Reject params beyond `max` for filters with a fixed arity.
pub fn arity(
    it: *Interp,
    call: parse.FilterCall,
    max: usize,
) error{Template}!void {
    if (call.params.len > max) {
        return badArg(it, call, "filter '{s}' takes at most {d} argument(s)", .{ call.name, max });
    }
}

/// `call.params[i]` evaluated, or null when absent. Bare words resolve
/// against the data root and fall back to their text (`link:url`).
pub fn param(it: *Interp, call: parse.FilterCall, i: usize) Error!?*const Value {
    if (i >= call.params.len) return null;
    return switch (call.params[i]) {
        .value => |e| it.evalParam(e),
        else => badArg(it, call, "filter '{s}' does not take a key:value or arrow argument here", .{call.name}),
    };
}

/// `call.params[i]` as text, or null when absent. Containers coerce the
/// JavaScript way — an object becomes "[object Object]" and an array
/// joins with commas — matching how the oracle treats arguments.
pub fn paramText(it: *Interp, call: parse.FilterCall, i: usize) Error!?[]const u8 {
    const v = (try param(it, call, i)) orelse return null;
    return try jsToString(it.alloc, v);
}

/// JavaScript's implicit toString: scalars render as themselves, an
/// object is always "[object Object]", and arrays join their elements'
/// toStrings with commas.
pub fn jsToString(alloc: std.mem.Allocator, v: *const Value) Error![]const u8 {
    switch (v.*) {
        .object => return "[object Object]",
        .null => return "null",
        .array => |arr| {
            var out = std.ArrayList(u8).empty;
            for (arr.items, 0..) |*item, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try jsToString(alloc, item));
            }
            return out.toOwnedSlice(alloc);
        },
        else => return (try scalarText(alloc, v.*)).?,
    }
}

/// `call.params[i]` as a f64, or null when absent.
pub fn paramNumber(it: *Interp, call: parse.FilterCall, i: usize) Error!?f64 {
    const v = (try param(it, call, i)) orelse return null;
    return switch (v.*) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch
            return badArg(it, call, "filter '{s}' argument must be a number", .{call.name}),
        .string => |s| std.fmt.parseFloat(f64, s) catch
            return badArg(it, call, "filter '{s}' argument must be a number", .{call.name}),
        else => badArg(it, call, "filter '{s}' argument must be a number", .{call.name}),
    };
}

/// Record the oracle's non-fatal INVALID_FILTER_INPUT warning, positioned
/// at the filter call.
pub fn warnInput(it: *Interp, call: parse.FilterCall, comptime fmt: []const u8, args: anytype) Error!void {
    const detail = std.fmt.allocPrint(it.alloc, fmt, args) catch return error.OutOfMemory;
    return it.warn(.invalid_filter_input, call.name, call.offset, detail);
}

/// The undefined sentinel and null both pass through numeric filters
/// silently in the oracle — no warning, no coercion.
pub fn isNullish(v: *const Value) bool {
    return switch (v.*) {
        .null => true,
        .number_string => |s| std.mem.eql(u8, s, "undefined"),
        else => false,
    };
}

/// Does `s` parse as a complete JSON document?
pub fn jsonParses(it: *Interp, s: []const u8) bool {
    _ = std.json.parseFromSliceLeaky(Value, it.alloc, s, .{}) catch return false;
    return true;
}

/// The oracle's warning interpolation of a value: scalars render as their
/// JS text, containers serialize to compact JSON, and a single-element
/// primitive array unwraps to its element first (`["zz"]` quotes as `zz`).
pub fn inspectValue(it: *Interp, v: *const Value) Error![]const u8 {
    var cur = v;
    if (v.* == .array) {
        const items = v.array.items;
        if (items.len == 1) {
            switch (items[0]) {
                .array, .object => {},
                else => cur = &items[0],
            }
        }
    }
    switch (cur.*) {
        .array, .object => {
            var buf = std.Io.Writer.Allocating.init(it.alloc);
            try it.jsStringify(cur, &buf);
            return buf.written();
        },
        .null => return "null",
        else => return (try scalarText(it.alloc, cur.*)).?,
    }
}

/// Renders a scalar value to text; returns null for arrays and objects.
pub fn scalarText(alloc: std.mem.Allocator, v: Value) error{OutOfMemory}!?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .null => "",
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| try engine.jsFloat(alloc, f),
        .array, .object => null,
    };
}

/// Scalar text or a diagnostic naming the filter.
pub fn textValue(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error![]const u8 {
    return (try scalarText(it.alloc, input.*)) orelse
        failAt(it, call.offset, "filter '{s}' expects a text value, but got {s}", .{ call.name, typeName(input.*) });
}

/// A serialized-collection string reparsed into its value. Strings that do
/// not parse as a JSON array or object pass through unchanged — the
/// oracle's "serialized collections from another filter are recognized
/// automatically" rule.
pub fn normalizeInput(it: *Interp, input: *const Value) Error!*const Value {
    switch (input.*) {
        .string => return reparseCollection(it, input),
        // Filters see a single-element primitive array as the element —
        // `["A b"] | fragment_link` is a scalar passthrough, matching the
        // same unwrap `{{ ["a"] }}` applies at output. Null, containers
        // and the undefined sentinel stay wrapped.
        .array => |arr| {
            if (arr.items.len != 1) return input;
            const elem = arr.items[0];
            return switch (elem) {
                .bool, .integer, .float, .string => it.make(elem),
                .number_string => |ns| if (!std.mem.eql(u8, ns, "undefined"))
                    it.make(elem)
                else
                    input,
                else => input,
            };
        },
        else => return input,
    }
}

/// normalizeInput without the single-primitive unwrap: `length`, `yaml`
/// and `yaml_property` see the collection as written, so `["notes"]`
/// counts 1 and serializes as a list.
pub fn reparseCollection(it: *Interp, input: *const Value) Error!*const Value {
    const s = switch (input.*) {
        .string => |s| s,
        else => return input,
    };
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len < 2 or (t[0] != '[' and t[0] != '{')) return input;
    const parsed = std.json.parseFromSliceLeaky(Value, it.alloc, t, .{}) catch return input;
    return it.make(parsed);
}

/// Recursively map the string leaves of a value: arrays map per element,
/// objects map per value (keys preserved) when `map_object_values`, and
/// non-strings pass through. Serialized-collection input is parsed first.
/// This is the vectorization contract documented for most markup and text
/// filters.
pub fn mapStrings(
    it: *Interp,
    input: *const Value,
    map_object_values: bool,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    const v = try normalizeInput(it, input);
    return mapStringsInner(it, v, map_object_values, ctx, f);
}

fn mapStringsInner(
    it: *Interp,
    v: *const Value,
    map_object_values: bool,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *Interp, []const u8) Error![]const u8,
) Error!*const Value {
    switch (v.*) {
        .string => |s| return it.make(.{ .string = try f(ctx, it, s) }),
        .number_string => |s| return it.make(.{ .string = try f(ctx, it, s) }),
        .array => |arr| {
            var items = try it.alloc.alloc(Value, arr.items.len);
            for (arr.items, 0..) |*item, i| {
                items[i] = (try mapStringsInner(it, item, map_object_values, ctx, f)).*;
            }
            var list = std.json.Array.init(it.alloc);
            try list.appendSlice(items);
            return it.make(.{ .array = list });
        },
        .object => |obj| {
            if (!map_object_values) return v;
            var map: std.json.ObjectMap = .empty;
            try map.ensureTotalCapacity(it.alloc, obj.count());
            var it2 = obj.iterator();
            while (it2.next()) |entry| {
                const mapped = try mapStringsInner(it, entry.value_ptr, map_object_values, ctx, f);
                map.putAssumeCapacity(entry.key_ptr.*, mapped.*);
            }
            return it.make(.{ .object = map });
        },
        else => return v,
    }
}

/// The leading/trailing whitespace of `s`, kept outside inline markers:
/// `"  pad  "` bolds as `"  **pad**  "`.
pub fn splitWrap(s: []const u8) struct { ws_start: []const u8, core: []const u8, ws_end: []const u8 } {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\n' or s[b - 1] == '\r')) b -= 1;
    return .{ .ws_start = s[0..a], .core = s[a..b], .ws_end = s[b..] };
}

pub fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

/// Schemes that can execute script in whatever renders the Markdown.
/// Blocked because a downstream parser renders this output. Navigational
/// schemes (`mailto:`, `ftp:`, `file:`, and relative paths) are the
/// caller's business and are left alone.
const blocked_schemes = [_][]const u8{ "javascript", "vbscript", "data" };

/// Decodes the entity and numeric character references that CommonMark
/// resolves inside link destinations (`&#106;`, `&#x6a;`, `&colon;`) while
/// copying `url`'s scheme-prefix region into `out`: everything up to and
/// including the first decoded `:`, or the whole URL when it has none.
///
/// The table is deliberately tiny and complete: no HTML5 named reference
/// resolves to a plain ASCII letter, so a smuggled *scheme* can only be
/// built from numeric references plus `&colon;` for the separating colon.
/// Returns null when the decoded prefix cannot fit `out` (no blocked scheme
/// name is anywhere near that long).
fn decodeEntityPrefix(url: []const u8, out: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < url.len) {
        const c = url[i];
        if (c != ':') {
            if (c != '&') {
                if (n == out.len) return null;
                out[n] = c;
                n += 1;
                i += 1;
                continue;
            }
            if (decodeRefAt(url[i..])) |r| {
                if (r.codepoint > 127) return null; // cannot be a scheme character
                if (n == out.len) return null;
                out[n] = @intCast(r.codepoint);
                n += 1;
                i += r.len;
                continue;
            }
            if (n == out.len) return null;
            out[n] = '&';
            n += 1;
            i += 1;
            continue;
        }
        if (n == out.len) return null;
        out[n] = ':';
        return out[0 .. n + 1];
    }
    return out[0..n];
}

const DecodedRef = struct { codepoint: u21, len: usize };

/// Decodes one character reference at the start of `s` (which begins with
/// `&`). Semicolon-terminated only, per CommonMark 0.31.2 §6.2. The digit
/// run is uncapped and accumulates with saturation: HTML resolves overlong
/// zero-padded references (`&#x000000006a;`) in attribute values, while
/// CommonMark leaves them literal — so decoding them here only ever
/// over-blocks, and saturating keeps a long digit run from overflowing the
/// u32.
fn decodeRefAt(s: []const u8) ?DecodedRef {
    if (s.len < 3 or s[0] != '&') return null;
    if (s[1] == '#') {
        if (s.len < 4) return null;
        var value: u32 = 0;
        var i: usize = 2;
        var digits: usize = 0;
        if (s[i] == 'x' or s[i] == 'X') {
            i += 1;
            while (i < s.len and std.ascii.isHex(s[i])) : (i += 1) {
                value = value *| 16 +| @as(u32, std.fmt.charToDigit(s[i], 16) catch return null);
                digits += 1;
            }
        } else {
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                value = value *| 10 +| (s[i] - '0');
                digits += 1;
            }
        }
        if (digits == 0 or i >= s.len or s[i] != ';') return null;
        if (value == 0 or value > 0x10FFFF) return null;
        return .{ .codepoint = @intCast(value), .len = i + 1 };
    }
    if (std.mem.startsWith(u8, s, "&colon;")) return .{ .codepoint = ':', .len = "&colon;".len };
    return null;
}

/// True when `url` starts with a blocked scheme, after resolving the entity
/// and numeric character references a CommonMark renderer would resolve in
/// the destination (`&#106;avascript:` is `javascript:`). The scheme grammar
/// is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`, so a colon that is not
/// preceded by a well-formed scheme belongs to the path, not a scheme, and
/// `:leading-colon` and `a/b:c` are not treated as schemes. Public because
/// lint statically checks literal `link` arguments with the same rule.
pub fn hasBlockedScheme(url: []const u8) bool {
    var buf: [64]u8 = undefined;
    const decoded = decodeEntityPrefix(url, &buf) orelse return false;
    return blockedSchemeIn(decoded);
}

fn blockedSchemeIn(decoded: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
    const scheme = decoded[0..colon];
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    for (blocked_schemes) |bad| {
        if (std.ascii.eqlIgnoreCase(scheme, bad)) return true;
    }
    return false;
}

/// The scheme prefix of `url` as it will be seen by the renderer, with
/// entity references resolved, or `url` itself when there is no colon.
/// Allocated because entity smuggling can stretch the prefix. Public for
/// lint's teaching output.
pub fn schemeName(alloc: std.mem.Allocator, url: []const u8) error{OutOfMemory}![]const u8 {
    var buf: [64]u8 = undefined;
    if (decodeEntityPrefix(url, &buf)) |decoded| {
        if (std.mem.indexOfScalar(u8, decoded, ':')) |colon| {
            return alloc.dupe(u8, decoded[0..colon]);
        }
        return alloc.dupe(u8, decoded);
    }
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return url;
    return url[0..colon];
}
