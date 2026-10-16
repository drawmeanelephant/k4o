//! `map` and `template` — the transform filters.
//!
//! `map:"path"` selects a property path on each array item (missing →
//! `null`); `map:x => expr` runs the arrow mini-language per item.
//! `template:"${path}"` interpolates one object, or each array item
//! joined by blank lines; `${str}` interpolates the item itself and a
//! `${arr}` value comma-joins.

const std = @import("std");
const parse = @import("../parse.zig");
const filters = @import("../filters.zig");
const engine = @import("../engine.zig");
const diag = @import("../diag.zig");

const Interp = engine.Interp;
const Value = std.json.Value;
const Error = filters.Error;

pub const names = [_][]const u8{ "map", "template" };

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    if (std.mem.eql(u8, call.name, "map")) return mapFilter(it, call, input);
    if (std.mem.eql(u8, call.name, "template")) return templateFilter(it, call, input);
    return null;
}

fn mapFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!?*const Value {
    const v = input.*;
    if (v != .array) return input;
    if (call.params.len == 0) {
        return filters.failAt(it, call.offset, "filter 'map' needs an argument: a quoted property path or an arrow expression", .{});
    }
    var out = std.json.Array.init(it.alloc);
    for (v.array.items) |*item| {
        const mapped = try mapItem(it, call, item);
        try out.append(mapped.*);
    }
    const arr = try it.alloc.create(Value);
    arr.* = .{ .array = out };
    return arr;
}

fn mapItem(it: *Interp, call: parse.FilterCall, item: *const Value) Error!*const Value {
    const prm = call.params[0];
    switch (prm) {
        .arrow => |arrow| return it.evalArrow(arrow, item),
        .value => |expr| {
            const arg = try it.evalParam(expr);
            if (arg.* != .string) {
                return filters.failAt(it, call.offset, "filter 'map' needs a quoted property path or an arrow expression", .{});
            }
            return selectPath(it, item, arg.string);
        },
        .pair => return filters.failAt(it, call.offset, "filter 'map' needs a quoted property path or an arrow expression", .{}),
    }
}

/// Resolve `a.b.c` against one item — quoted-path selection yields real
/// `null` for a missing key (the arrow body's `"undefined"` string is a
/// different sentinel).
fn selectPath(it: *Interp, item: *const Value, spec: []const u8) Error!*const Value {
    var cur = item;
    var steps = std.mem.splitScalar(u8, spec, '.');
    while (steps.next()) |key| {
        if (key.len == 0) continue;
        cur = switch (cur.*) {
            .object => |obj| obj.getPtr(key) orelse return it.nullValue(),
            else => return it.nullValue(),
        };
    }
    return cur;
}

fn templateFilter(it: *Interp, call: parse.FilterCall, input: *const Value) Error!?*const Value {
    if (call.params.len == 0) {
        return filters.failAt(it, call.offset, "filter 'template' needs a quoted template like \"${{name}}\"", .{});
    }
    const prm = call.params[0];
    if (prm != .value) {
        return filters.failAt(it, call.offset, "filter 'template' needs a quoted template like \"${{name}}\"", .{});
    }
    const arg = try it.evalParam(prm.value);
    if (arg.* != .string) {
        return filters.failAt(it, call.offset, "filter 'template' needs a quoted template like \"${{name}}\"", .{});
    }

    switch (input.*) {
        .array => |arr| {
            var out = std.ArrayList(u8).empty;
            for (arr.items, 0..) |*item, i| {
                if (i > 0) try out.appendSlice(it.alloc, "\n\n");
                try renderTemplate(it, arg.string, item, &out);
            }
            const v = try it.alloc.create(Value);
            v.* = .{ .string = out.items };
            return v;
        },
        else => {
            var out = std.ArrayList(u8).empty;
            try renderTemplate(it, arg.string, input, &out);
            const v = try it.alloc.create(Value);
            v.* = .{ .string = out.items };
            return v;
        },
    }
}

/// Walk the template text and substitute `${...}` expressions against the
/// item. `str` is the item itself (JS-coerced), `arr` comma-joins, and a
/// missing path renders empty.
fn renderTemplate(
    it: *Interp,
    tmpl: []const u8,
    item: *const Value,
    out: *std.ArrayList(u8),
) Error!void {
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '$' and i + 1 < tmpl.len and tmpl[i + 1] == '{') {
            const close = std.mem.indexOfPos(u8, tmpl, i + 2, "}") orelse {
                try out.appendSlice(it.alloc, tmpl[i..]);
                break;
            };
            const key = std.mem.trim(u8, tmpl[i + 2 .. close], " \t");
            if (std.mem.eql(u8, key, "str")) {
                try out.appendSlice(it.alloc, try filters.jsToString(it.alloc, item));
            } else {
                const v = try selectPath(it, item, key);
                if (v.* != .null) {
                    try out.appendSlice(it.alloc, try filters.jsToString(it.alloc, v));
                }
            }
            i = close + 1;
        } else {
            try out.append(it.alloc, tmpl[i]);
            i += 1;
        }
    }
}
