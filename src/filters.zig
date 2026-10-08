//! Format-specific emitters for the shared Knap filter registry.
//!
//! The filter names, arguments, value validation and diagnostics are shared.
//! Only the emitted markup depends on the selected format. The compile-time
//! markdown mutant still changes the default format for red-green verification.
//!
//! Clean-room note: the filter *names* follow Knap's user-facing
//! documentation; the emitted forms follow the Textile specification
//! snapshots (see README.md -> Clean-room record).

const std = @import("std");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
pub const Error = error{ Template, OutOfMemory };
pub const Format = enum { textile, markdown, gfm };

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
    format: Format,
    input_is_markup: bool,
) Error!std.json.Value {
    if (!isRegistered(call.name)) {
        return diag.fail(alloc, d, .unknown_filter, template, call.offset, "no filter named \"{s}\"", .{call.name});
    }

    if (headingLevel(call.name)) |level| {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter '{s}' takes no arguments", .{call.name});
        const text = try phraseText(alloc, d, template, call, input);
        const content = if (format != .textile and !input_is_markup) try escapeMarkdown(alloc, text) else text;
        const out = if (format != .textile)
            try std.fmt.allocPrint(alloc, "{s} {s}", .{ try repeatChar(alloc, '#', level), content })
        else
            try std.fmt.allocPrint(alloc, "h{d}. {s}", .{ level, text });
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "bold")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'bold' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const content = if (format != .textile and !input_is_markup) try escapeMarkdown(alloc, text) else text;
        const out = if (format != .textile)
            try markdownEmphasis(alloc, content, "**")
        else
            try std.fmt.allocPrint(alloc, "*{s}*", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "italic")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'italic' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const content = if (format != .textile and !input_is_markup) try escapeMarkdown(alloc, text) else text;
        const out = if (format != .textile)
            try markdownEmphasis(alloc, content, "*")
        else
            try std.fmt.allocPrint(alloc, "_{s}_", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "code")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'code' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const out = if (format != .textile)
            try inlineCode(alloc, text)
        else
            try std.fmt.allocPrint(alloc, "@{s}@", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "blockquote")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'blockquote' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        const content = if (format != .textile and !input_is_markup) try escapeMarkdown(alloc, text) else text;
        const out = if (format != .textile)
            try std.fmt.allocPrint(alloc, "> {s}", .{content})
        else
            try std.fmt.allocPrint(alloc, "bq. {s}", .{text});
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "codeblock")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'codeblock' takes no arguments", .{});
        const text = (try scalarText(alloc, input)) orelse
            return failRender(alloc, d, template, call.offset, "filter 'codeblock' expects a text value, but got {s}", .{typeName(input)});
        const out = if (format != .textile)
            try codeFence(alloc, text)
        else if (hasContentAfterBlankLine(text))
            try std.fmt.allocPrint(alloc, "bc.. {s}", .{text})
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
            return badArg(alloc, d, template, call, "filter 'link' refuses the URL scheme '{s}:', which can execute script in the Textile renderer", .{try schemeName(alloc, url)});
        }
        const text = try phraseText(alloc, d, template, call, input);
        const content = if (format != .textile and !input_is_markup) try escapeMarkdown(alloc, text) else text;
        if (std.mem.indexOfScalar(u8, text, '"') != null) {
            return failRender(alloc, d, template, call.offset, "filter 'link' text must not contain a double quote", .{});
        }
        const out = if (format != .textile)
            try std.fmt.allocPrint(alloc, "[{s}]({s})", .{ content, try escapeUrl(alloc, url) })
        else
            try std.fmt.allocPrint(alloc, "\"{s}\":{s}", .{ text, url });
        return .{ .string = out };
    }

    if (std.mem.eql(u8, call.name, "list")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'list' takes no arguments", .{});
        return .{ .string = try emitList(alloc, d, template, call, input, false, format) };
    }
    if (std.mem.eql(u8, call.name, "numbered")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'numbered' takes no arguments", .{});
        return .{ .string = try emitList(alloc, d, template, call, input, true, format) };
    }
    if (std.mem.eql(u8, call.name, "table")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'table' takes no arguments", .{});
        return .{ .string = try emitTable(alloc, d, template, call, input, format) };
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
/// `&`). Semicolon-terminated only, per CommonMark 0.31.2 §6.2.
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
                value = value * 16 + @as(u32, std.fmt.charToDigit(s[i], 16) catch return null);
                digits += 1;
            }
        } else {
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                value = value * 10 + (s[i] - '0');
                digits += 1;
            }
        }
        if (digits == 0 or digits > 8 or i >= s.len or s[i] != ';') return null;
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

/// Escape user text inside Markdown constructs, but not the markup emitted by
/// an earlier filter in the same pipeline (`italic | h2`, `code | bold`).
fn escapeMarkdown(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    return escapeMarkdownInContext(alloc, text, .inline_text);
}

const MarkdownContext = enum { inline_text, list_item };

fn escapeMarkdownInContext(alloc: std.mem.Allocator, text: []const u8, context: MarkdownContext) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var ordered_marker = if (context == .list_item) orderedListMarker(text) else null;
    for (text, 0..) |c, i| {
        if (c == '&') {
            try out.appendSlice(alloc, "&amp;");
        } else {
            const at_line_start = out.items.len == 0 or out.items[out.items.len - 1] == '\n';
            if (std.mem.indexOfScalar(u8, "\\`*_[]<>", c) != null or
                (at_line_start and std.mem.indexOfScalar(u8, "#+-", c) != null) or
                ordered_marker == i)
                try out.append(alloc, '\\');
            try out.append(alloc, c);
        }
        if (context == .list_item and (c == '\n' or c == '\r')) {
            const start = i + 1;
            ordered_marker = if (orderedListMarker(text[start..])) |offset| start + offset else null;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// CommonMark ordered markers have 1–9 digits, a '.' or ')', then whitespace
/// or end-of-line, with at most three leading spaces. Escape the delimiter in
/// scalar list text so only the array structure can introduce nested lists.
fn orderedListMarker(text: []const u8) ?usize {
    var i: usize = 0;
    while (i < text.len and i < 3 and text[i] == ' ') : (i += 1) {}
    const digits_start = i;
    while (i < text.len and i - digits_start < 9 and std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i == digits_start or i == text.len or (text[i] != '.' and text[i] != ')')) return null;
    if (i + 1 < text.len and std.mem.indexOfScalar(u8, " \t\r\n", text[i + 1]) == null) return null;
    return i;
}

/// Percent- and entity-safe destination for the `[text](url)` form.
///
/// `(`, `)` and `\` are backslash-escaped per CommonMark 0.31.2 §6.6.
/// `&` is emitted as `&amp;` so that entity or numeric character
/// references in the source URL (`&#106;avascript:`, `javascript&colon;`,
/// `&#x6a;`) cannot survive into the resolved destination: CommonMark
/// decodes references inside link destinations, and a decoded
/// `javascript:`-family scheme would bypass the blocklist checked against
/// the raw argument. `&amp;` round-trips to a literal `&`, so legitimate
/// URLs with query strings render unchanged.
fn escapeUrl(alloc: std.mem.Allocator, url: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (url) |c| {
        switch (c) {
            '(', ')', '\\' => try out.append(alloc, '\\'),
            '&' => {
                try out.appendSlice(alloc, "&amp;");
                continue;
            },
            else => {},
        }
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn markdownEmphasis(alloc: std.mem.Allocator, text: []const u8, marker: []const u8) error{OutOfMemory}![]u8 {
    const start = std.mem.indexOfNone(u8, text, " \t") orelse return alloc.dupe(u8, text);
    const end = (std.mem.lastIndexOfNone(u8, text, " \t") orelse unreachable) + 1;
    return std.fmt.allocPrint(alloc, "{s}{s}{s}{s}{s}", .{
        text[0..start], marker, text[start..end], marker, text[end..],
    });
}

/// Delimiters must be longer than any run of backticks in the content. Empty
/// spans have no CommonMark representation; all-space spans must not be padded
/// because CommonMark only strips boundary padding from non-all-space content.
fn inlineCode(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    if (text.len == 0) return alloc.dupe(u8, text);
    const ticks = try repeatChar(alloc, '`', @max(@as(usize, 1), longestRun(text, '`') + 1));
    const pad = std.mem.indexOfNone(u8, text, " ") != null and
        (text[0] == '`' or text[0] == ' ' or text[text.len - 1] == '`' or text[text.len - 1] == ' ');
    return if (pad)
        std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ ticks, text, ticks })
    else
        std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ ticks, text, ticks });
}

fn codeFence(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const ticks = try repeatChar(alloc, '`', @max(@as(usize, 3), longestRun(text, '`') + 1));
    const separator = if (text.len == 0 or std.mem.endsWith(u8, text, "\n")) "" else "\n";
    return std.fmt.allocPrint(alloc, "{s}\n{s}{s}{s}", .{ ticks, text, separator, ticks });
}

/// True when `text` has a blank line — a line holding only spaces, tabs or
/// carriage returns — followed by non-whitespace content. A single-block
/// `bc. ` signature "ends with a blank line" (textile-spec, Block
/// quotations), so the tail would reach the downstream parser as ordinary
/// Textile; only that shape needs the extended `bc..` signature, which holds
/// until the next block signature or EOF. Content whose blank lines trail
/// into nothing survives the single form, so it keeps emitting it.
fn hasContentAfterBlankLine(text: []const u8) bool {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!isBlankLine(line)) continue;
        for (rest) |c| {
            if (c != ' ' and c != '\t' and c != '\r' and c != '\n') return true;
        }
    }
    return false;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

fn longestRun(text: []const u8, char: u8) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (text) |c| {
        run = if (c == char) run + 1 else 0;
        longest = @max(longest, run);
    }
    return longest;
}

fn emitList(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    ordered: bool,
    format: Format,
) error{ Template, OutOfMemory }![]u8 {
    const arr = switch (input) {
        .array => |a| a,
        else => return failRender(alloc, d, template, call.offset, "filter '{s}' expects an array, but got {s}", .{ call.name, typeName(input) }),
    };
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    try emitListLevel(alloc, d, template, call, arr.items, ordered, format, 1, 0, &buf);
    return buf.toOwnedSlice(alloc);
}

fn emitListLevel(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    items: []const std.json.Value,
    ordered: bool,
    format: Format,
    depth: usize,
    ordered_indent: usize,
    buf: *std.ArrayList(u8),
) error{ Template, OutOfMemory }!void {
    var first = true;
    var has_parent = false;
    var number: usize = 0;
    var child_indent = ordered_indent;
    for (items) |item| {
        switch (item) {
            .array => |sub| {
                if (depth >= 3) return failRender(alloc, d, template, call.offset, "filter '{s}' supports at most 3 levels of nesting", .{call.name});
                if (sub.items.len == 0) continue;
                if (!first) try buf.append(alloc, '\n');
                first = false;
                // A nested array with no preceding parent item cannot form a
                // nested CommonMark list; promote its items to this level.
                const child_depth = if (format != .textile and !has_parent) depth else depth + 1;
                try emitListLevel(alloc, d, template, call, sub.items, ordered, format, child_depth, child_indent, buf);
            },
            .object => return failRender(alloc, d, template, call.offset, "filter '{s}' expects list items to be text or nested arrays", .{call.name}),
            else => {
                if (!first) try buf.append(alloc, '\n');
                first = false;
                has_parent = true;
                if (format != .textile) {
                    if (ordered) {
                        try buf.appendNTimes(alloc, ' ', ordered_indent);
                        number += 1;
                        const marker = try std.fmt.allocPrint(alloc, "{d}. ", .{number});
                        // Children start at this parent's content column,
                        // which moves when its number gains another digit.
                        child_indent = ordered_indent + marker.len;
                        try buf.appendSlice(alloc, marker);
                    } else {
                        var indent = depth;
                        while (indent > 1) : (indent -= 1) try buf.append(alloc, '\t');
                        try buf.appendSlice(alloc, "- ");
                    }
                } else {
                    const marker: u8 = if (ordered) '#' else '*';
                    var count = depth;
                    while (count > 0) : (count -= 1) try buf.append(alloc, marker);
                    try buf.append(alloc, ' ');
                }
                const t = (try scalarText(alloc, item)).?;
                try buf.appendSlice(alloc, if (format != .textile) try escapeMarkdownInContext(alloc, t, .list_item) else t);
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
    format: Format,
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

    if (format == .gfm) {
        // Match knap 0.6.0's no-argument table: an empty header, plain
        // single-hyphen delimiters (valid GFM), and all input rows in the body.
        try buf.append(alloc, '|');
        for (0..width) |_| try buf.appendSlice(alloc, "  |");
        try buf.appendSlice(alloc, "\n|");
        for (0..width) |_| try buf.appendSlice(alloc, " - |");
        try buf.append(alloc, '\n');
    }

    for (rows.items, 0..) |row_value, r| {
        if (r > 0) try buf.append(alloc, '\n');
        const row = switch (row_value) {
            .array => |a| a,
            else => return failRender(alloc, d, template, call.offset, "filter 'table' expects each row to be an array of cells", .{}),
        };
        if (row.items.len != width) {
            return failRender(alloc, d, template, call.offset, "filter 'table' expects every row to have the same number of cells (row {d} has {d}, expected {d})", .{ r + 1, row.items.len, width });
        }
        if (format == .textile) {
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
        } else {
            if (format == .gfm) {
                try buf.append(alloc, '|');
            } else {
                // Strict CommonMark has no pipe tables; retain HTML tables.
                if (r == 0) {
                    try buf.appendSlice(alloc, "<table>\n<thead>\n");
                } else if (r == 1) {
                    try buf.appendSlice(alloc, "</thead>\n<tbody>\n");
                }
                try buf.appendSlice(alloc, "<tr>");
            }
            for (row.items) |cell| {
                const t = (try scalarText(alloc, cell)) orelse
                    return failRender(alloc, d, template, call.offset, "filter 'table' expects text cells", .{});
                if (std.mem.indexOfAny(u8, t, "|\n") != null) {
                    return failRender(alloc, d, template, call.offset, "filter 'table' cell must not contain '|' or a newline", .{});
                }
                if (format == .gfm) {
                    try buf.append(alloc, ' ');
                    try buf.appendSlice(alloc, try escapeMarkdown(alloc, t));
                    try buf.appendSlice(alloc, " |");
                } else {
                    try buf.appendSlice(alloc, if (r == 0) "<th>" else "<td>");
                    for (t) |c| {
                        try buf.appendSlice(alloc, switch (c) {
                            '&' => "&amp;",
                            '<' => "&lt;",
                            '>' => "&gt;",
                            '"' => "&quot;",
                            else => &.{c},
                        });
                    }
                    try buf.appendSlice(alloc, if (r == 0) "</th>" else "</td>");
                }
            }
            if (format == .markdown) try buf.appendSlice(alloc, "</tr>");
        }
    }
    if (format == .markdown) {
        try buf.appendSlice(alloc, if (rows.items.len > 1) "\n</tbody>\n</table>" else "\n</thead>\n</table>");
    }
    return buf.toOwnedSlice(alloc);
}
