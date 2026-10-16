//! CommonMark emitters: headings, emphasis, code, blockquote, lists,
//! links/images, hr, hard breaks, escape_md, fragment_link.
//!
//! Semantics follow the knap 0.6.0 oracle and `knap help` output
//! (tools/differential/oracle-docs/filter-details.txt).

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");
const engine = @import("../engine.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "h1",           "h2",        "h3",          "h4",
    "h5",           "h6",        "bold",        "italic",
    "code",         "code_block", "blockquote", "list",
    "link",         "image",     "hr",          "hard_break",
    "escape_md",    "fragment_link",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    const name = call.name;

    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') {
        try filters.arity(it, call, 0);
        const level = name[1] - '0';
        return filters.mapStrings(it, input, true, level, heading);
    }
    if (std.mem.eql(u8, name, "bold")) {
        const arg = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        const marker: []const u8 = if (arg) |a| blk: {
            if (std.mem.eql(u8, a, "_")) break :blk "__";
            if (a.len == 0) break :blk "**";
            return filters.badArg(it, call, "filter 'bold' accepts '_' or no argument", .{});
        } else "**";
        return filters.mapStrings(it, input, true, marker, emphasis);
    }
    if (std.mem.eql(u8, name, "italic")) {
        const arg = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        const marker: []const u8 = if (arg) |a| blk: {
            if (std.mem.eql(u8, a, "_")) break :blk "_";
            if (a.len == 0) break :blk "*";
            return filters.badArg(it, call, "filter 'italic' accepts '_' or no argument", .{});
        } else "*";
        return filters.mapStrings(it, input, true, marker, emphasis);
    }
    if (std.mem.eql(u8, name, "code")) {
        const lang = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        return filters.mapStrings(it, input, true, lang, code);
    }
    if (std.mem.eql(u8, name, "code_block")) {
        const lang = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        return filters.mapStrings(it, input, true, lang orelse "", codeBlock);
    }
    if (std.mem.eql(u8, name, "blockquote")) {
        try filters.arity(it, call, 0);
        return filters.mapStrings(it, input, true, {}, blockquote);
    }
    if (std.mem.eql(u8, name, "list")) {
        const mode_arg = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        const list_mode: ListMode = if (mode_arg) |m| blk: {
            if (std.mem.eql(u8, m, "numbered")) break :blk .numbered;
            if (std.mem.eql(u8, m, "task")) break :blk .task;
            if (std.mem.eql(u8, m, "numbered-task")) break :blk .numbered_task;
            if (std.mem.eql(u8, m, "bullet") or m.len == 0) break :blk .bullet;
            return filters.badArg(it, call, "filter 'list' accepts bullet, numbered, task or numbered-task", .{});
        } else .bullet;
        return emitList(it, call, input, list_mode);
    }
    if (std.mem.eql(u8, name, "link")) {
        const arg = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        return emitLink(it, call, input, arg);
    }
    if (std.mem.eql(u8, name, "image")) {
        const arg = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        return emitImage(it, call, input, arg);
    }
    if (std.mem.eql(u8, name, "hr")) {
        const arg = try filters.paramText(it, call, 0);
        try filters.arity(it, call, 1);
        const pos: HrPos = if (arg) |a| blk: {
            if (std.mem.eql(u8, a, "before")) break :blk .before;
            if (std.mem.eql(u8, a, "both")) break :blk .both;
            if (std.mem.eql(u8, a, "after") or a.len == 0) break :blk .after;
            return filters.badArg(it, call, "filter 'hr' accepts before, after or both", .{});
        } else .after;
        return filters.mapStrings(it, input, true, pos, hr);
    }
    if (std.mem.eql(u8, name, "hard_break")) {
        try filters.arity(it, call, 0);
        return filters.mapStrings(it, input, true, {}, hardBreak);
    }
    if (std.mem.eql(u8, name, "escape_md")) {
        try filters.arity(it, call, 0);
        return filters.mapStrings(it, input, true, {}, escapeMd);
    }
    if (std.mem.eql(u8, name, "fragment_link")) {
        return filters.failAt(it, call.offset, "filter 'fragment_link' is not implemented yet", .{});
    }
    return null;
}

// --------------------------------------------------------------------

fn heading(level: u8, it: *Interp, s: []const u8) Error![]const u8 {
    // Each nonempty data line becomes a heading.
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!first) try out.append(it.alloc, '\n');
        first = false;
        var i: usize = 0;
        while (i < level) : (i += 1) try out.append(it.alloc, '#');
        try out.append(it.alloc, ' ');
        try out.appendSlice(it.alloc, line);
    }
    return out.toOwnedSlice(it.alloc);
}

fn emphasis(marker: []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    const w = filters.splitWrap(s);
    return std.fmt.allocPrint(it.alloc, "{s}{s}{s}{s}{s}", .{ w.ws_start, marker, w.core, marker, w.ws_end });
}

/// `code`: backticks grow past the longest run in the text; a language or
/// multiline content becomes a fenced block. A space pads the delimiters
/// only when the content itself starts or ends with a backtick.
fn code(lang: ?[]const u8, it: *Interp, s: []const u8) Error![]const u8 {
    if (lang) |l| {
        if (l.len > 0) return codeBlock(l, it, s);
    }
    if (s.len == 0) return "";
    if (std.mem.indexOfScalar(u8, s, '\n') != null) {
        return codeBlock("", it, s);
    }
    var ticks: usize = 1;
    var run: usize = 0;
    for (s) |c| {
        if (c == '`') {
            run += 1;
            if (run >= ticks) ticks = run + 1;
        } else run = 0;
    }
    var fence = std.ArrayList(u8).empty;
    try fence.appendNTimes(it.alloc, '`', ticks);
    const pad = s[0] == '`' or s[s.len - 1] == '`';
    return std.fmt.allocPrint(it.alloc, "{s}{s}{s}{s}{s}", .{ fence.items, if (pad) " " else "", s, if (pad) " " else "", fence.items });
}

fn codeBlock(lang: []const u8, it: *Interp, s: []const u8) Error![]const u8 {
    var ticks: usize = 3;
    var run: usize = 0;
    for (s) |c| {
        if (c == '`') {
            run += 1;
            if (run >= ticks) ticks = run + 1;
        } else run = 0;
    }
    var fence = std.ArrayList(u8).empty;
    try fence.appendNTimes(it.alloc, '`', ticks);
    return std.fmt.allocPrint(it.alloc, "{s}{s}\n{s}\n{s}", .{ fence.items, lang, s, fence.items });
}

fn blockquote(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(it.alloc, '\n');
        first = false;
        if (line.len == 0) {
            try out.append(it.alloc, '>');
        } else {
            try out.appendSlice(it.alloc, "> ");
            try out.appendSlice(it.alloc, line);
        }
    }
    return out.toOwnedSlice(it.alloc);
}

const ListMode = enum { bullet, numbered, task, numbered_task };

fn emitList(it: *Interp, call: parse.FilterCall, input: *const Value, mode: ListMode) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    var out = std.ArrayList(u8).empty;
    try listValue(it, call, v, mode, &out, 0);
    return it.make(.{ .string = out.items });
}

fn listValue(
    it: *Interp,
    call: parse.FilterCall,
    v: *const Value,
    mode: ListMode,
    out: *std.ArrayList(u8),
    depth: usize,
) Error!void {
    switch (v.*) {
        .array => |arr| {
            var n: usize = 0;
            for (arr.items) |*item| {
                switch (item.*) {
                    .array => try listValue(it, call, item, mode, out, depth + 1),
                    else => {
                        n += 1;
                        if (out.items.len > 0) try out.append(it.alloc, '\n');
                        const text = (try filters.scalarText(it.alloc, item.*)) orelse
                            return filters.failAt(it, call.offset, "filter 'list' expects text items, but got {s}", .{filters.typeName(item.*)});
                        // Nested items indent one tab per level and a
                        // nested ordered list numbers every item "1." —
                        // oracle-observed.
                        for (0..depth) |_| try out.append(it.alloc, '\t');
                        const marker: []const u8 = switch (mode) {
                            .bullet => "- ",
                            .numbered => if (depth > 0) "1. " else try std.fmt.allocPrint(it.alloc, "{d}. ", .{n}),
                            .task => "- [ ] ",
                            .numbered_task => if (depth > 0) "1. [ ] " else try std.fmt.allocPrint(it.alloc, "{d}. [ ] ", .{n}),
                        };
                        try out.appendSlice(it.alloc, marker);
                        try out.appendSlice(it.alloc, text);
                    },
                }
            }
        },
        else => {
            const text = (try filters.scalarText(it.alloc, v.*)) orelse
                return filters.failAt(it, call.offset, "filter 'list' expects a value or array, but got {s}", .{filters.typeName(v.*)});
            if (out.items.len > 0) try out.append(it.alloc, '\n');
            const marker: []const u8 = switch (mode) {
                .bullet => "- ",
                .numbered => "1. ",
                .task => "- [ ] ",
                .numbered_task => "1. [ ] ",
            };
            try out.appendSlice(it.alloc, marker);
            try out.appendSlice(it.alloc, text);
        },
    }
}

/// `[text](url)` — input is the URL; the optional parameter is link text.
/// Arrays emit one link per item joined by newlines; objects use keys as
/// URLs and values as text.
fn emitLink(it: *Interp, call: parse.FilterCall, input: *const Value, arg: ?[]const u8) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .object => |obj| {
            var out = std.ArrayList(u8).empty;
            var it2 = obj.iterator();
            var first = true;
            while (it2.next()) |entry| {
                if (!first) try out.append(it.alloc, '\n');
                first = false;
                const text = (try filters.scalarText(it.alloc, entry.value_ptr.*)) orelse
                    return filters.failAt(it, call.offset, "filter 'link' object values must be text, but got {s}", .{filters.typeName(entry.value_ptr.*)});
                try linkMarkdown(it, call, entry.key_ptr.*, text, &out);
            }
            return it.make(.{ .string = out.items });
        },
        .array => |arr| {
            var out = std.ArrayList(u8).empty;
            for (arr.items) |*item| {
                const url = (try filters.scalarText(it.alloc, item.*)) orelse
                    return filters.failAt(it, call.offset, "filter 'link' expects a URL text value, but got {s}", .{filters.typeName(item.*)});
                if (out.items.len > 0) try out.append(it.alloc, '\n');
                try linkMarkdown(it, call, url, arg orelse "link", &out);
            }
            return it.make(.{ .string = out.items });
        },
        else => {
            const url = (try filters.scalarText(it.alloc, v.*)) orelse
                return filters.failAt(it, call.offset, "filter 'link' expects a URL text value, but got {s}", .{filters.typeName(v.*)});
            var out = std.ArrayList(u8).empty;
            try linkMarkdown(it, call, url, arg orelse "link", &out);
            return it.make(.{ .string = out.items });
        },
    }
}

/// `[text](url)` — an empty URL emits nothing. A dangerous scheme
/// (`javascript:`, `vbscript:`, `data:`) strips the destination, matching
/// the oracle's `[T]()`. Other URLs are percent-encoded the way the oracle
/// encodes them and the text is Markdown-escaped.
fn linkMarkdown(it: *Interp, call: parse.FilterCall, url: []const u8, text: []const u8, out: *std.ArrayList(u8)) Error!void {
    _ = call;
    if (url.len == 0) return;
    const dest = if (filters.hasBlockedScheme(url)) "" else try encodeLinkUrl(it.alloc, url);
    const label = try escapeMdText(it.alloc, text);
    try out.append(it.alloc, '[');
    try out.appendSlice(it.alloc, label);
    try out.appendSlice(it.alloc, "](");
    try out.appendSlice(it.alloc, dest);
    try out.append(it.alloc, ')');
}

/// Percent-encode the characters a CommonMark link destination cannot
/// hold plus whitespace and non-ASCII bytes (each UTF-8 byte -> %XX).
fn encodeLinkUrl(alloc: std.mem.Allocator, url: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (url) |c| {
        switch (c) {
            ' ', '"', '<', '>', '[', ']', '(', ')', '\\', '`' => {
                try appendPct(&out, alloc, c);
            },
            else => {
                if (c < 0x20 or c == 0x7F or c >= 0x80) {
                    try appendPct(&out, alloc, c);
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Link-label escaping, oracle-observed: `&` becomes `&amp;` while the
/// inline-dangerous set `<>_*[]` takes a backslash; every other byte —
/// including `"`, parentheses and `#` — stays literal.
fn escapeMdText(alloc: std.mem.Allocator, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<', '>', '_', '*', '[', ']' => {
                try out.append(alloc, '\\');
                try out.append(alloc, c);
            },
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `![alt](url)` — like `link`, but arrays and objects produce a JSON
/// array of image strings rather than a joined block.
fn emitImage(it: *Interp, call: parse.FilterCall, input: *const Value, arg: ?[]const u8) Error!*const Value {
    const v = try filters.normalizeInput(it, input);
    switch (v.*) {
        .object => |obj| {
            var items = std.ArrayList(Value).empty;
            var it2 = obj.iterator();
            while (it2.next()) |entry| {
                const alt = (try filters.scalarText(it.alloc, entry.value_ptr.*)) orelse
                    return filters.failAt(it, call.offset, "filter 'image' object values must be text, but got {s}", .{filters.typeName(entry.value_ptr.*)});
                try items.append(it.alloc, .{ .string = try imageMarkdown(it, call, entry.key_ptr.*, alt) });
            }
            return makeArray(it, items.items);
        },
        .array => |arr| {
            var items = std.ArrayList(Value).empty;
            for (arr.items) |*item| {
                const url = (try filters.scalarText(it.alloc, item.*)) orelse
                    return filters.failAt(it, call.offset, "filter 'image' expects a URL text value, but got {s}", .{filters.typeName(item.*)});
                try items.append(it.alloc, .{ .string = try imageMarkdown(it, call, url, arg orelse "") });
            }
            return makeArray(it, items.items);
        },
        else => {
            const url = (try filters.scalarText(it.alloc, v.*)) orelse
                return filters.failAt(it, call.offset, "filter 'image' expects a URL text value, but got {s}", .{filters.typeName(v.*)});
            return it.make(.{ .string = try imageMarkdown(it, call, url, arg orelse "") });
        },
    }
}

fn imageMarkdown(it: *Interp, call: parse.FilterCall, url: []const u8, alt: []const u8) Error![]const u8 {
    if (filters.hasBlockedScheme(url)) {
        return filters.badArg(it, call, "filter 'image' refuses the URL scheme '{s}:', which can execute script in the renderer", .{try filters.schemeName(it.alloc, url)});
    }
    return std.fmt.allocPrint(it.alloc, "![{s}]({s})", .{ alt, url });
}

fn makeArray(it: *Interp, items: []Value) Error!*const Value {
    var arr = std.json.Array.init(it.alloc);
    try arr.appendSlice(items);
    return it.make(.{ .array = arr });
}

const HrPos = enum { before, after, both };

fn hr(pos: HrPos, it: *Interp, s: []const u8) Error![]const u8 {
    return switch (pos) {
        .before => try std.fmt.allocPrint(it.alloc, "---\n\n{s}", .{s}),
        .after => try std.fmt.allocPrint(it.alloc, "{s}\n\n---", .{s}),
        .both => try std.fmt.allocPrint(it.alloc, "---\n\n{s}\n\n---", .{s}),
    };
}

/// Single newlines gain two trailing spaces; blank lines stay as they are.
fn hardBreak(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\n' and
            (i == 0 or s[i - 1] != '\n') and
            (i + 1 >= s.len or s[i + 1] != '\n'))
        {
            try out.appendSlice(it.alloc, "  \n");
        } else {
            try out.append(it.alloc, c);
        }
        i += 1;
    }
    return out.toOwnedSlice(it.alloc);
}

/// Every ASCII punctuation character that Markdown backslash escapes can
/// quote gets a backslash — CommonMark 0.31.2 §2.4.
fn escapeMd(_: void, it: *Interp, s: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (s) |c| {
        if (isMdPunct(c)) try out.append(it.alloc, '\\');
        try out.append(it.alloc, c);
    }
    return out.toOwnedSlice(it.alloc);
}

fn isMdPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

fn appendPct(out: *std.ArrayList(u8), alloc: std.mem.Allocator, c: u8) Error!void {
    const hex = "0123456789ABCDEF";
    try out.append(alloc, '%');
    try out.append(alloc, hex[c >> 4]);
    try out.append(alloc, hex[c & 0xF]);
}
