//! Oliver opt-in syntax extensions — knap 0.6.0 filter group.
//!
//! table and table_pretty are implemented; the rest render an
//! unimplemented diagnostic until their batch lands (KNAP-FIDELITY.md).

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
    if (std.mem.eql(u8, call.name, "table")) {
        return emitTable(it, call, input, false);
    }
    if (std.mem.eql(u8, call.name, "table_pretty")) {
        return emitTable(it, call, input, true);
    }
    for (names) |n| {
        if (std.mem.eql(u8, call.name, n)) {
            return filters.failAt(it, call.offset, "filter '{s}' is not implemented yet", .{call.name});
        }
    }
    return null;
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
    const v = try filters.normalizeInput(it, input);

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
            return filters.failAt(it, call.offset, "filter '{s}' expects an array or object, but got {s}", .{ call.name, filters.typeName(v.*) });
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
    for (cells, 0..) |cell, i| {
        if (i == 0) {
            try out.appendSlice(it.alloc, "| ");
        } else {
            try out.appendSlice(it.alloc, " | ");
        }
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

/// Cell text: scalars render as themselves with `|` escaped; a single
/// primitive in an array unwraps; other containers serialize compactly.
fn cellText(it: *Interp, v: *const Value) Error![]const u8 {
    if (v.* == .array and v.array.items.len == 1) {
        switch (v.array.items[0]) {
            .bool, .integer, .float, .number_string, .string => return cellText(it, &v.array.items[0]),
            else => {},
        }
    }
    const raw = try filters.scalarText(it.alloc, v.*) orelse blk: {
        var buf: std.Io.Writer.Allocating = .init(it.alloc);
        try it.jsStringify(v, &buf);
        break :blk buf.written();
    };
    if (std.mem.indexOfScalar(u8, raw, '|') == null) return raw;
    var out = std.ArrayList(u8).empty;
    for (raw) |c| {
        if (c == '|') try out.append(it.alloc, '\\');
        try out.append(it.alloc, c);
    }
    return out.toOwnedSlice(it.alloc);
}
