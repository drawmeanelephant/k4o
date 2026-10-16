//! arithmetic — knap 0.6.0 filter group.
//!
//! calc / number_format / round, matched to the oracle:
//!
//! - calc parses `op + operand` from the comma-joined parameter text
//!   (String(args)), coerces the input with JS `Number` semantics, and
//!   re-parses `result.toFixed(10)` so `0.1 + 0.2` renders `0.3`.
//! - number_format takes positional params (decimals, decimal separator,
//!   thousands separator) and formats with exact JS `toFixed` rounding —
//!   ties land on the larger magnitude (`2.5 -> "3"`, `0.125 -> "0.13"`),
//!   which differs from Zig's `{d:.N}` shortest-digits rounding.
//! - round uses the mantissa/exponent-split trick (`Math.round` on the
//!   shifted significand) so `round:2` on 2.675 gives 2.68 while
//!   `number_format:2` gives 2.67, exactly like the oracle.
//!
//! Warning-only outcomes in the oracle ("Could not parse ...", non-finite
//! results) pass the input through unchanged here — the k4o diagnostic
//! channel is fatal-only, and stdout bytes are the contract.

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");
const engine = @import("../engine.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "calc",
    "number_format",
    "round",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    if (std.mem.eql(u8, call.name, "calc")) return calc(it, call, input);
    if (std.mem.eql(u8, call.name, "number_format")) return numberFormat(it, call, input);
    if (std.mem.eql(u8, call.name, "round")) return round(it, call, input);
    return null;
}

/// The filter's parameter list as the oracle sees it: each evaluated
/// param's JS toString, joined with commas.
fn paramsJoined(it: *Interp, call: parse.FilterCall) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (call.params, 0..) |prm, i| {
        const text = switch (prm) {
            .value => try filters.paramText(it, call, i),
            else => return filters.badArg(it, call, "filter '{s}' does not take a key:value or arrow argument here", .{call.name}),
        };
        if (i > 0) try out.append(it.alloc, ',');
        try out.appendSlice(it.alloc, text.?);
    }
    return out.items;
}

// --------------------------------------------------------------------
// JS number coercion.

const js_ws = " \t\n\r\x0b\x0c";

fn startsDigitAfterSign(t: []const u8) bool {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    return i < t.len and std.ascii.isDigit(t[i]);
}

/// JavaScript `Number(s)`: trims whitespace, then requires the whole
/// string to be a numeric literal — decimal, `Infinity`, or a 0x/0o/0b
/// integer. Returns null for NaN.
fn jsNumber(s: []const u8) ?f64 {
    const t = std.mem.trim(u8, s, js_ws);
    if (t.len == 0) return 0;
    var i: usize = 0;
    var neg = false;
    if (t[0] == '+' or t[0] == '-') {
        neg = t[0] == '-';
        i = 1;
    }
    const body = t[i..];
    if (body.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(body, "infinity"))
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    if (body.len > 2 and body[0] == '0') {
        const digits = body[2..];
        const base: u8 = switch (body[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (base != 0) {
            if (digits.len == 0) return null;
            var value: f64 = 0;
            for (digits) |c| {
                const d = std.fmt.charToDigit(c, base) catch return null;
                value = value * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(d));
            }
            return if (neg) -value else value;
        }
    }
    // Strict decimal grammar: \d*\.?\d*([eE][+-]?\d+)? with >= 1 digit.
    var j: usize = 0;
    var mantissa_digits: usize = 0;
    while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) mantissa_digits += 1;
    if (j < body.len and body[j] == '.') {
        j += 1;
        while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) mantissa_digits += 1;
    }
    if (mantissa_digits == 0) return null;
    if (j < body.len and (body[j] == 'e' or body[j] == 'E')) {
        j += 1;
        if (j < body.len and (body[j] == '+' or body[j] == '-')) j += 1;
        var exp_digits: usize = 0;
        while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) exp_digits += 1;
        if (exp_digits == 0) return null;
    }
    if (j != body.len) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// JavaScript `parseFloat(s)`: leading whitespace plus the longest valid
/// decimal/Infinity prefix. Returns null for NaN.
fn jsParseFloat(s: []const u8) ?f64 {
    var i: usize = 0;
    while (i < s.len and std.mem.indexOfScalar(u8, js_ws, s[i]) != null) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (std.mem.startsWith(u8, s[i..], "Infinity"))
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    var j = i;
    var mantissa_digits: usize = 0;
    while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) mantissa_digits += 1;
    if (j < s.len and s[j] == '.') {
        j += 1;
        while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) mantissa_digits += 1;
    }
    if (mantissa_digits == 0) return null;
    var end = j;
    if (j < s.len and (s[j] == 'e' or s[j] == 'E')) {
        var k = j + 1;
        if (k < s.len and (s[k] == '+' or s[k] == '-')) k += 1;
        var exp_digits: usize = 0;
        while (k < s.len and std.ascii.isDigit(s[k])) : (k += 1) exp_digits += 1;
        if (exp_digits > 0) end = k;
    }
    return std.fmt.parseFloat(f64, s[0..end]) catch null;
}

/// JavaScript `parseInt(s, 10)`: whitespace, sign, then a digit run.
/// Returns null for NaN. Accumulates in f64 — all callers only need
/// decimal-count precision.
fn jsParseInt(s: []const u8) ?f64 {
    var i: usize = 0;
    while (i < s.len and std.mem.indexOfScalar(u8, js_ws, s[i]) != null) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    var value: f64 = 0;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        value = value * 10 + @as(f64, @floatFromInt(s[i] - '0'));
        digits += 1;
    }
    if (digits == 0) return null;
    return if (neg) -value else value;
}

// --------------------------------------------------------------------
// JS toFixed: exact decimal expansion of the binary value, ties landing
// on the larger magnitude (`|x|` is rounded, sign re-applied — the spec's
// "larger n" is chosen on the magnitude). `f` in 0...100 like the oracle.

fn jsToFixed(alloc: std.mem.Allocator, x: f64, f: u32) Error![]const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (std.math.isInf(x)) return if (x > 0) "Infinity" else "-Infinity";
    if (@abs(x) >= 1e21) return engine.jsFloat(alloc, x);

    const neg = std.math.signbit(x) and x != 0;
    const ax = @abs(x);

    // |x| = m * 2^e with m 53-bit, so |x| * 10^f = m * 5^f * 2^(e+f).
    const bits: u64 = @bitCast(ax);
    const raw_exp: i32 = @intCast((bits >> 52) & 0x7ff);
    const mantissa_field = bits & ((@as(u64, 1) << 52) - 1);
    var num: u512 = undefined;
    var e: i32 = undefined;
    if (raw_exp == 0) {
        num = mantissa_field;
        e = -1074;
    } else {
        num = mantissa_field | (@as(u64, 1) << 52);
        e = raw_exp - 1075;
    }
    var pow5: u512 = 1;
    for (0..f) |_| pow5 *= 5;
    num *= pow5;

    const shift: i32 = e + @as(i32, @intCast(f));
    var n: u512 = undefined;
    if (shift >= 0) {
        n = num << @intCast(shift);
    } else {
        const s: u9 = @intCast(-shift);
        const q = num >> s;
        const rem = num & ((@as(u512, 1) << s) - 1);
        n = if (rem << 1 >= (@as(u512, 1) << s)) q + 1 else q;
    }

    var digit_buf: [400]u8 = undefined;
    var dig = std.Io.Writer.fixed(&digit_buf);
    dig.print("{d}", .{n}) catch return error.OutOfMemory;
    const digits = dig.buffered();

    var out = std.ArrayList(u8).empty;
    if (neg) try out.append(alloc, '-');
    const fd: usize = f;
    if (fd == 0) {
        try out.appendSlice(alloc, digits);
    } else if (digits.len > fd) {
        try out.appendSlice(alloc, digits[0 .. digits.len - fd]);
        try out.append(alloc, '.');
        try out.appendSlice(alloc, digits[digits.len - fd ..]);
    } else {
        try out.appendSlice(alloc, "0.");
        var pad = fd - digits.len;
        while (pad > 0) : (pad -= 1) try out.append(alloc, '0');
        try out.appendSlice(alloc, digits);
    }
    return out.toOwnedSlice(alloc);
}

/// JS `Math.round`: floor(x + 0.5) with -0 collapsing to 0.
fn jsRound(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x)) return x;
    const r = @floor(x + 0.5);
    return if (r == 0) 0 else r;
}

/// Recursively map numeric leaves, keeping everything else unchanged —
/// matching the oracle where non-numeric collection members pass through
/// silently. Serialized-collection strings are re-parsed first.
/// `coerce` picks the leaf's number (each filter uses a different JS
/// coercion) and `f` maps it to the new leaf value — null means the leaf
/// fails the oracle's non-finite check and is kept as-is.
fn mapNumbers(
    it: *Interp,
    input: *const Value,
    ctx: anytype,
    comptime coerce: fn (*Interp, *const Value) Error!?f64,
    comptime f: fn (@TypeOf(ctx), *Interp, f64) Error!?*const Value,
) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    return mapNumbersInner(it, v, ctx, coerce, f);
}

fn mapNumbersInner(
    it: *Interp,
    v: *const Value,
    ctx: anytype,
    comptime coerce: fn (*Interp, *const Value) Error!?f64,
    comptime f: fn (@TypeOf(ctx), *Interp, f64) Error!?*const Value,
) Error!*const Value {
    switch (v.*) {
        .array => |arr| {
            var items = try it.alloc.alloc(Value, arr.items.len);
            for (arr.items, 0..) |*item, i| {
                items[i] = (try mapNumbersInner(it, item, ctx, coerce, f)).*;
            }
            var list = std.json.Array.init(it.alloc);
            try list.appendSlice(items);
            return it.make(.{ .array = list });
        },
        .object => |obj| {
            var map: std.json.ObjectMap = .empty;
            try map.ensureTotalCapacity(it.alloc, obj.count());
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const mapped = try mapNumbersInner(it, entry.value_ptr, ctx, coerce, f);
                map.putAssumeCapacity(entry.key_ptr.*, mapped.*);
            }
            return it.make(.{ .object = map });
        },
        else => {
            const n = (try coerce(it, v)) orelse return v;
            return (try f(ctx, it, n)) orelse v;
        },
    }
}

/// `Number()`-style coercion used by calc and round.
fn coerceNumber(it: *Interp, v: *const Value) Error!?f64 {
    return switch (v.*) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| jsNumber(s),
        .string => |s| if (std.mem.trim(u8, s, js_ws).len == 0) null else jsNumber(s),
        .null => null,
        else => jsNumber(try filters.jsToString(it.alloc, v)),
    };
}

/// `parseFloat`-style coercion used by number_format.
fn coerceParseFloat(it: *Interp, v: *const Value) Error!?f64 {
    _ = it;
    return switch (v.*) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| jsParseFloat(s),
        .string => |s| if (std.mem.trim(u8, s, js_ws).len == 0) null else jsParseFloat(s),
        else => null,
    };
}

// --------------------------------------------------------------------
// calc

fn calc(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    if (call.params.len == 0)
        return filters.badArg(it, call, "filter 'calc' requires an operation (e.g., calc:\"+10\", calc:\"*2\")", .{});
    const arg = try paramsJoined(it, call);
    const op_str = std.mem.trim(u8, arg, js_ws);
    if (op_str.len == 0)
        return filters.badArg(it, call, "filter 'calc' operation cannot be empty", .{});

    var op: enum { add, sub, mul, div, pow } = undefined;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, op_str, "**")) {
        op = .pow;
        rest = op_str[2..];
    } else {
        rest = op_str[1..];
        op = switch (op_str[0]) {
            '+' => .add,
            '-' => .sub,
            '*' => .mul,
            '/' => .div,
            '^' => .pow,
            else => |c| return filters.badArg(it, call, "filter 'calc' invalid operator \"{c}\" (use +, -, *, /, ^ or **)", .{c}),
        };
    }

    const operand_text = std.mem.trim(u8, rest, js_ws);
    const rhs = (if (operand_text.len == 0) null else jsNumber(operand_text)) orelse
        return filters.badArg(it, call, "filter 'calc' requires a number after the operator (e.g., \"+10\")", .{});

    const lhs = (try coerceNumber(it, input)) orelse return input;
    var result = switch (op) {
        .add => lhs + rhs,
        .sub => lhs - rhs,
        .mul => lhs * rhs,
        .div => lhs / rhs,
        .pow => std.math.pow(f64, lhs, rhs),
    };
    if (!std.math.isFinite(result)) return input;

    // The oracle rounds through toFixed(10): parse that string back.
    if (@abs(result) < 1e21) {
        const fixed = try jsToFixed(it.alloc, result, 10);
        result = std.fmt.parseFloat(f64, fixed) catch result;
    }
    return it.make(.{ .float = result });
}

// --------------------------------------------------------------------
// number_format

fn numberFormat(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    var decimals: f64 = 0;
    var dec_sep: []const u8 = ".";
    var thou_sep: []const u8 = ",";
    if (try filters.paramText(it, call, 0)) |t|
        decimals = jsParseInt(t) orelse std.math.nan(f64);
    if (try filters.paramText(it, call, 1)) |t| dec_sep = t;
    if (try filters.paramText(it, call, 2)) |t| thou_sep = t;

    const ctx = NfCtx{ .dec_sep = dec_sep, .thou_sep = thou_sep };
    // toFixed coerces digits through ToIntegerOrInfinity: NaN -> 0 and
    // truncation for fractions; outside 0..100 the oracle warns and keeps
    // the input.
    var d = if (std.math.isNan(decimals)) 0 else @trunc(decimals);
    if (d < 0 or d > 100) return input;
    const places: u32 = @intFromFloat(d);
    _ = &d;
    const wrapped = Wrapped{ .places = places, .ctx = ctx };
    return mapNumbers(it, input, wrapped, coerceParseFloat, formatLeaf);
}

const NfCtx = struct {
    dec_sep: []const u8,
    thou_sep: []const u8,
};

const Wrapped = struct { places: u32, ctx: NfCtx };

fn formatLeaf(w: Wrapped, it: *Interp, n: f64) Error!?*const Value {
    const fixed = try jsToFixed(it.alloc, n, w.places);
    const text = if (@abs(n) >= 1e21 or !std.math.isFinite(n))
        fixed
    else
        try applySeparators(it.alloc, fixed, w.ctx.dec_sep, w.ctx.thou_sep);
    return it.make(.{ .string = text });
}

fn applySeparators(
    alloc: std.mem.Allocator,
    fixed: []const u8,
    dec_sep: []const u8,
    thou_sep: []const u8,
) Error![]const u8 {
    const dot = std.mem.indexOfScalar(u8, fixed, '.');
    const int_part = fixed[0 .. dot orelse fixed.len];
    var start: usize = 0;
    if (int_part.len > 0 and (int_part[0] == '-' or int_part[0] == '+')) start = 1;
    const digits = int_part[start..];
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, int_part[0..start]);
    for (digits, 0..) |c, i| {
        const remaining = digits.len - i;
        if (i > 0 and remaining % 3 == 0) try out.appendSlice(alloc, thou_sep);
        try out.append(alloc, c);
    }
    if (dot) |d| {
        try out.appendSlice(alloc, dec_sep);
        try out.appendSlice(alloc, fixed[d + 1 ..]);
    }
    return out.toOwnedSlice(alloc);
}

// --------------------------------------------------------------------
// round

fn round(it: *Interp, call: parse.FilterCall, input: *const Value) Error!*const Value {
    var decimals: f64 = 0;
    if (call.params.len > 0) {
        const t = (try filters.paramText(it, call, 0)).?;
        if (t.len == 0)
            return filters.badArg(it, call, "filter 'round' decimal places must be a number (e.g., round:2)", .{});
        if (jsNumber(t) == null) {
            // Strings that start with a digit but fail Number() pass the
            // input through silently in the oracle ("2x", "2e", "0x"...);
            // the rest are argument errors ("abc", "-x", "2 x" is silent).
            if (startsDigitAfterSign(t)) return input;
            return filters.badArg(it, call, "filter 'round' decimal places must be a number (e.g., round:2)", .{});
        }
        decimals = jsParseInt(t) orelse std.math.nan(f64);
        if (decimals < 0)
            return filters.badArg(it, call, "filter 'round' decimal places must be non-negative (e.g., round:2)", .{});
    }

    return mapNumbers(it, input, decimals, coerceNumber, roundLeaf);
}

/// The oracle's decimal-shift round: split the JS number string on 'e',
/// shift the exponent by `d`, Math.round, then shift back. Matches
/// `Number(Math.round(Number(mantissa + "e" + (exp + d))) + "e" + (-d))`.
fn roundLeaf(decimals: f64, it: *Interp, n: f64) Error!?*const Value {
    const d = decimals;
    if (!std.math.isFinite(n)) return null;
    const text = try engine.jsFloat(it.alloc, n);
    var mantissa = text;
    var exp: f64 = 0;
    if (std.mem.indexOfAny(u8, text, "eE")) |epos| {
        mantissa = text[0..epos];
        exp = std.fmt.parseFloat(f64, text[epos + 1 ..]) catch 0;
    }
    const scaled_str = try std.fmt.allocPrint(it.alloc, "{s}e{d}", .{ mantissa, exp + d });
    const scaled = std.fmt.parseFloat(f64, scaled_str) catch std.math.nan(f64);
    const rounded = jsRound(scaled);
    const result_str = try std.fmt.allocPrint(it.alloc, "{d}e{d}", .{ rounded, -d });
    const result = std.fmt.parseFloat(f64, result_str) catch std.math.nan(f64);
    if (!std.math.isFinite(result)) return null;
    return it.make(.{ .float = result });
}
