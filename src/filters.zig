//! The Textile-emitting filter registry.
//!
//! Every filter in this registry emits Textile by construction. The
//! compile-time `-Dengine-mode=markdown` mutant swaps the emitters for
//! Markdown equivalents so the test suite can prove it fails against
//! Markdown-polluted output (README.md -> Verification).
//!
//! Clean-room note: the filter *names* follow Knap's user-facing
//! documentation; the emitted forms follow the Textile specification
//! snapshots (see README.md -> Clean-room record).

const std = @import("std");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const build_options = @import("build_options");

pub const Error = error{ Template, OutOfMemory };

const markdown_mode = std.mem.eql(u8, build_options.engine_mode, "markdown");

pub const Entry = struct {
    name: []const u8,
    takes_arg: bool,
};

/// The complete registry. README.md documents exactly this set, and the
/// test suite asserts every entry has at least one fixture case.
pub const entries = [_]Entry{
    .{ .name = "h1", .takes_arg = false },
    .{ .name = "h2", .takes_arg = false },
    .{ .name = "h3", .takes_arg = false },
    .{ .name = "h4", .takes_arg = false },
    .{ .name = "h5", .takes_arg = false },
    .{ .name = "h6", .takes_arg = false },
    .{ .name = "bold", .takes_arg = false },
    .{ .name = "italic", .takes_arg = false },
    .{ .name = "code", .takes_arg = false },
    .{ .name = "codeblock", .takes_arg = false },
    .{ .name = "blockquote", .takes_arg = false },
    .{ .name = "link", .takes_arg = true },
    .{ .name = "list", .takes_arg = false },
    .{ .name = "numbered", .takes_arg = false },
    .{ .name = "table", .takes_arg = false },
};

pub fn registry() []const Entry {
    return &entries;
}

fn isRegistered(name: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

fn headingLevel(name: []const u8) ?u8 {
    if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') {
        return name[1] - '0';
    }
    return null;
}

pub fn apply(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
) Error!std.json.Value {
    if (!isRegistered(call.name)) {
        return diag.fail(alloc, d, .unknown_filter, template, call.offset, "no filter named \"{s}\"", .{call.name});
    }

    if (headingLevel(call.name)) |level| {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter '{s}' takes no arguments", .{call.name});
        const text = try phraseText(alloc, d, template, call, input);
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "{s} {s}", .{ try repeatChar(alloc, '#', level), text })
        else
            try std.fmt.allocPrint(alloc, "h{d}. {s}", .{ level, text });
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "bold")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'bold' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "**{s}**", .{text})
        else
            try std.fmt.allocPrint(alloc, "*{s}*", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "italic")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'italic' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "*{s}*", .{text})
        else
            try std.fmt.allocPrint(alloc, "_{s}_", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "code")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'code' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "`{s}`", .{text})
        else
            try std.fmt.allocPrint(alloc, "@{s}@", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "blockquote")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'blockquote' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "> {s}", .{text})
        else
            try std.fmt.allocPrint(alloc, "bq. {s}", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "codeblock")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'codeblock' takes no arguments", .{});
        const text = (try scalarText(alloc, input)) orelse
            return failRender(alloc, d, template, call.offset, "filter 'codeblock' expects a text value, but got {s}", .{typeName(input)});
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "```\n{s}\n```", .{text})
        else
            try std.fmt.allocPrint(alloc, "bc. {s}", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "link")) {
        const arg = call.arg orelse
            return badArg(alloc, d, template, call, "filter 'link' requires a URL argument, e.g. link:\"https://example.com/\"", .{});
        const url = try argText(alloc, d, template, call, arg, root);
        if (url.len == 0) return badArg(alloc, d, template, call, "filter 'link' URL must not be empty", .{});
        for (url) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '"') {
                return badArg(alloc, d, template, call, "filter 'link' URL must not contain whitespace or a double quote", .{});
            }
        }
        if (hasBlockedScheme(url)) {
            return badArg(alloc, d, template, call, "filter 'link' refuses the URL scheme '{s}:', which can execute script in the Textile renderer", .{schemeName(url)});
        }
        const text = try phraseText(alloc, d, template, call, input);
        if (std.mem.indexOfScalar(u8, text, '"') != null) {
            return failRender(alloc, d, template, call.offset, "filter 'link' text must not contain a double quote", .{});
        }
        const out = if (markdown_mode)
            try std.fmt.allocPrint(alloc, "[{s}]({s})", .{ text, url })
        else
            try std.fmt.allocPrint(alloc, "\"{s}\":{s}", .{ text, url });
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "list")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'list' takes no arguments", .{});
        return .{ .string = try emitList(alloc, d, template, call, input, false) };
    }
    if (std.mem.eql(u8, call.name, "numbered")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'numbered' takes no arguments", .{});
        return .{ .string = try emitList(alloc, d, template, call, input, true) };
    }
    if (std.mem.eql(u8, call.name, "table")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'table' takes no arguments", .{});
        return .{ .string = try emitTable(alloc, d, template, call, input) };
    }

    // Unreachable: the registry check above guarantees every name is
    // handled by one of the branches.
    unreachable;
}

fn badArg(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    comptime fmt: []const u8,
    args: anytype,
) error{Template} {
    return diag.fail(alloc, d, .bad_argument, template, call.offset, fmt, args);
}

fn failRender(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    offset: usize,
    comptime fmt: []const u8,
    args: anytype,
) error{Template} {
    return diag.fail(alloc, d, .render, template, offset, fmt, args);
}

/// Renders a scalar value to text; returns null for arrays and objects
/// (callers decide how to report that).
fn scalarText(alloc: std.mem.Allocator, v: std.json.Value) error{OutOfMemory}!?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .null => "",
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .array, .object => null,
    };
}

fn typeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

fn phraseText(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
) error{ Template, OutOfMemory }![]const u8 {
    const text = (try scalarText(alloc, input)) orelse
        return failRender(alloc, d, template, call.offset, "filter '{s}' expects a text value, but got {s}", .{ call.name, typeName(input) });
    if (std.mem.indexOfScalar(u8, text, '\n') != null) {
        return failRender(alloc, d, template, call.offset, "filter '{s}' expects single-line text", .{call.name});
    }
    return text;
}

/// Schemes that can execute script in whatever renders the Textile. Blocked
/// because the README's premise is that a downstream Textile parser renders
/// this output. Navigational schemes (`mailto:`, `ftp:`, `file:`, and relative
/// paths) are the caller's business and are left alone.
const blocked_schemes = [_][]const u8{ "javascript", "vbscript", "data" };

/// True when `url` starts with a blocked scheme. The scheme grammar is
/// `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`, so a colon that is not
/// preceded by a well-formed scheme belongs to the path, not a scheme, and
/// `:leading-colon` and `a/b:c` are not treated as schemes.
fn hasBlockedScheme(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..colon];
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    for (blocked_schemes) |bad| {
        if (std.ascii.eqlIgnoreCase(scheme, bad)) return true;
    }
    return false;
}

fn schemeName(url: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return url;
    return url[0..colon];
}

/// Resolves a filter argument to text.
///
/// A quoted or numeric argument is a literal. A *bare* word is looked up in
/// the data root first, so `link:url` means the value of `url` rather than
/// the four characters `url`; with no such key it stays a literal, which
/// preserves the documented bare-word behaviour. Quoting forces the literal
/// (`link:"url"`).
fn argText(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    arg: parse.Arg,
    root: std.json.Value,
) Error![]const u8 {
    return switch (arg) {
        .string => |s| s,
        .number => |n| try std.fmt.allocPrint(alloc, "{d}", .{n}),
        .bare => |name| blk: {
            const resolved = switch (root) {
                .object => |obj| obj.get(name),
                else => null,
            } orelse break :blk name;
            break :blk switch (resolved) {
                .string => |s| s,
                .number_string => |s| s,
                .integer => |n| try std.fmt.allocPrint(alloc, "{d}", .{n}),
                .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
                .bool => |b| if (b) "true" else "false",
                // Null, object and array have no text form, so falling back to
                // the bare word here would be silent nonsense again.
                else => badArg(alloc, d, template, call, "filter argument '{s}' resolves to {s}, but filter arguments must be text", .{ name, typeName(resolved) }),
            };
        },
    };
}

fn repeatChar(alloc: std.mem.Allocator, c: u8, n: usize) error{OutOfMemory}![]u8 {
    const out = try alloc.alloc(u8, n);
    @memset(out, c);
    return out;
}

fn emitList(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    ordered: bool,
) error{ Template, OutOfMemory }![]u8 {
    const arr = switch (input) {
        .array => |a| a,
        else => return failRender(alloc, d, template, call.offset, "filter '{s}' expects an array, but got {s}", .{ call.name, typeName(input) }),
    };
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    try emitListLevel(alloc, d, template, call, arr.items, ordered, 1, &buf);
    return buf.toOwnedSlice(alloc);
}

fn emitListLevel(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    items: []const std.json.Value,
    ordered: bool,
    depth: usize,
    buf: *std.ArrayList(u8),
) error{ Template, OutOfMemory }!void {
    var first = true;
    for (items) |item| {
        switch (item) {
            .array => |sub| {
                if (depth >= 3) return failRender(alloc, d, template, call.offset, "filter '{s}' supports at most 3 levels of nesting", .{call.name});
                if (sub.items.len == 0) continue;
                if (!first) try buf.append(alloc, '\n');
                first = false;
                try emitListLevel(alloc, d, template, call, sub.items, ordered, depth + 1, buf);
            },
            .object => return failRender(alloc, d, template, call.offset, "filter '{s}' expects list items to be text or nested arrays", .{call.name}),
            else => {
                if (!first) try buf.append(alloc, '\n');
                first = false;
                if (markdown_mode) {
                    var indent = depth;
                    while (indent > 1) : (indent -= 1) try buf.appendSlice(alloc, "  ");
                    try buf.appendSlice(alloc, if (ordered) "1. " else "- ");
                } else {
                    const marker: u8 = if (ordered) '#' else '*';
                    var count = depth;
                    while (count > 0) : (count -= 1) try buf.append(alloc, marker);
                    try buf.append(alloc, ' ');
                }
                const t = (try scalarText(alloc, item)).?;
                try buf.appendSlice(alloc, t);
            },
        }
    }
}

fn emitTable(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
) error{ Template, OutOfMemory }![]u8 {
    const rows = switch (input) {
        .array => |a| a,
        else => return failRender(alloc, d, template, call.offset, "filter 'table' expects an array of rows, but got {s}", .{typeName(input)}),
    };
    if (rows.items.len == 0) return failRender(alloc, d, template, call.offset, "filter 'table' expects at least one row", .{});
    const first_row = switch (rows.items[0]) {
        .array => |a| a,
        else => return failRender(alloc, d, template, call.offset, "filter 'table' expects each row to be an array of cells", .{}),
    };
    const width = first_row.items.len;
    if (width == 0) return failRender(alloc, d, template, call.offset, "filter 'table' expects at least one cell per row", .{});

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    for (rows.items, 0..) |row_value, r| {
        if (r > 0) try buf.append(alloc, '\n');
        const row = switch (row_value) {
            .array => |a| a,
            else => return failRender(alloc, d, template, call.offset, "filter 'table' expects each row to be an array of cells", .{}),
        };
        if (row.items.len != width) {
            return failRender(alloc, d, template, call.offset, "filter 'table' expects every row to have the same number of cells (row {d} has {d}, expected {d})", .{ r + 1, row.items.len, width });
        }
        if (markdown_mode) {
            try buf.append(alloc, '|');
            for (row.items) |cell| {
                const t = (try scalarText(alloc, cell)) orelse
                    return failRender(alloc, d, template, call.offset, "filter 'table' expects text cells", .{});
                try buf.append(alloc, ' ');
                try buf.appendSlice(alloc, t);
                try buf.appendSlice(alloc, " |");
            }
            if (r == 0) {
                try buf.append(alloc, '\n');
                var col: usize = 0;
                while (col < width) : (col += 1) try buf.appendSlice(alloc, "|---");
                try buf.append(alloc, '|');
            }
        } else {
            try buf.append(alloc, '|');
            for (row.items) |cell| {
                const t = (try scalarText(alloc, cell)) orelse
                    return failRender(alloc, d, template, call.offset, "filter 'table' expects text cells", .{});
                if (std.mem.indexOfScalar(u8, t, '|') != null) {
                    return failRender(alloc, d, template, call.offset, "filter 'table' cell must not contain '|'", .{});
                }
                if (std.mem.indexOfScalar(u8, t, '\n') != null) {
                    return failRender(alloc, d, template, call.offset, "filter 'table' cell must not contain a newline", .{});
                }
                if (r == 0) try buf.appendSlice(alloc, "_. ");
                try buf.appendSlice(alloc, t);
                try buf.append(alloc, '|');
            }
        }
    }
    return buf.toOwnedSlice(alloc);
}
