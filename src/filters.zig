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
    // Referential subset: the citation-apparatus filters. These emit knap's
    // documented output verbatim in every format — Textile has no wikilink,
    // footnote-block or fragment-link construct, so passthrough is the only
    // honest mapping.
    .{ .name = "footnote", .takes_arg = false },
    .{ .name = "wikilink", .takes_arg = true },
    .{ .name = "embed", .takes_arg = true },
    .{ .name = "image", .takes_arg = true },
    .{ .name = "fragment_link", .takes_arg = true },
    .{ .name = "yaml", .takes_arg = true },
    .{ .name = "yaml_property", .takes_arg = true },
    .{ .name = "indent", .takes_arg = true },
    .{ .name = "kebab", .takes_arg = false },
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
            return badArg(alloc, d, template, call, "filter 'link' refuses the URL scheme '{s}:', which can execute script in the Textile renderer", .{schemeName(url)});
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

    if (std.mem.eql(u8, call.name, "footnote")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'footnote' takes no arguments", .{});
        return .{ .string = try emitFootnotes(alloc, d, template, call, input) };
    }
    if (std.mem.eql(u8, call.name, "wikilink")) {
        return emitBracketLinks(alloc, d, template, call, input, root, "[[");
    }
    if (std.mem.eql(u8, call.name, "embed")) {
        return emitBracketLinks(alloc, d, template, call, input, root, "![[");
    }
    if (std.mem.eql(u8, call.name, "image")) {
        return emitImages(alloc, d, template, call, input, root);
    }
    if (std.mem.eql(u8, call.name, "fragment_link")) {
        return emitFragmentLinks(alloc, d, template, call, input, root);
    }
    if (std.mem.eql(u8, call.name, "indent")) {
        return .{ .string = try emitIndent(alloc, d, template, call, input, root) };
    }
    if (std.mem.eql(u8, call.name, "kebab")) {
        if (call.arg != null) return badArg(alloc, d, template, call, "filter 'kebab' takes no arguments", .{});
        const text = try phraseText(alloc, d, template, call, input);
        return .{ .string = try slugify(alloc, text) };
    }
    if (std.mem.eql(u8, call.name, "yaml")) {
        return .{ .string = try emitYaml(alloc, d, template, call, input, root) };
    }
    if (std.mem.eql(u8, call.name, "yaml_property")) {
        return .{ .string = try emitYamlProperty(alloc, d, template, call, input, root) };
    }

    // Unreachable: the registry check above guarantees every name is
    // handled by one of the branches.
    unreachable;
}

/// `[[target]]` / `![[target]]` with optional `|alias` argument. Arrays and
/// objects collapse to a JSON-array string, matching knap's documented
/// many-values behavior: arrays take the arg as each alias; objects map
/// target keys to alias values.
fn emitBracketLinks(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
    open: []const u8,
) error{ Template, OutOfMemory }!std.json.Value {
    const alias: ?[]const u8 = if (call.arg) |arg|
        try argText(alloc, d, template, call, arg, root)
    else
        null;
    const one = struct {
        fn go(a: std.mem.Allocator, dd: *diag.Diagnostic, t: []const u8, c: parse.FilterCall, target_v: std.json.Value, al: ?[]const u8, o: []const u8) error{ Template, OutOfMemory }![]u8 {
            const target = (try scalarText(a, target_v)) orelse
                return failRender(a, dd, t, c.offset, "filter '{s}' expects text targets, but got {s}", .{ c.name, typeName(target_v) });
            if (std.mem.indexOfAny(u8, target, "[]|\n") != null)
                return failRender(a, dd, t, c.offset, "filter '{s}' target must not contain '[', ']', '|' or a newline", .{c.name});
            return if (al) |x|
                std.fmt.allocPrint(a, "{s}{s}|{s}]]", .{ o, target, x })
            else
                std.fmt.allocPrint(a, "{s}{s}]]", .{ o, target });
        }
    }.go;
    // Collections return typed arrays — knap 0.6.0 chains preserve typed
    // values, so `wikilink | yaml` sees a list; the engine's output
    // coercion renders a bare array as compact JSON (the corpus form).
    switch (input) {
        .array => |arr| {
            var out: std.json.Array = .init(alloc);
            for (arr.items) |item|
                try out.append(.{ .string = try one(alloc, d, template, call, item, alias, open) });
            return .{ .array = out };
        },
        .object => |obj| {
            var out: std.json.Array = .init(alloc);
            var it = obj.iterator();
            while (it.next()) |e| {
                const al = (try scalarText(alloc, e.value_ptr.*)) orelse
                    return failRender(alloc, d, template, call.offset, "filter '{s}' alias values must be text", .{call.name});
                try out.append(.{ .string = try std.fmt.allocPrint(alloc, "{s}{s}|{s}]]", .{ open, e.key_ptr.*, al }) });
            }
            return .{ .array = out };
        },
        else => return .{ .string = try one(alloc, d, template, call, input, alias, open) },
    }
}

/// `![alt](url)`. Arg is the alt text; arrays take it for every item,
/// objects map url keys to alt values.
fn emitImages(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
) error{ Template, OutOfMemory }!std.json.Value {
    const alt: []const u8 = if (call.arg) |arg|
        try argText(alloc, d, template, call, arg, root)
    else
        "";
    const one = struct {
        fn go(a: std.mem.Allocator, dd: *diag.Diagnostic, t: []const u8, c: parse.FilterCall, url_v: std.json.Value, al: []const u8) error{ Template, OutOfMemory }![]u8 {
            const url = (try scalarText(a, url_v)) orelse
                return failRender(a, dd, t, c.offset, "filter '{s}' expects text urls, but got {s}", .{ c.name, typeName(url_v) });
            if (std.mem.indexOfAny(u8, url, "()\n") != null)
                return failRender(a, dd, t, c.offset, "filter '{s}' url must not contain '(', ')' or a newline", .{c.name});
            return std.fmt.allocPrint(a, "![{s}]({s})", .{ al, url });
        }
    }.go;
    switch (input) {
        .array => |arr| {
            var out: std.json.Array = .init(alloc);
            for (arr.items) |item|
                try out.append(.{ .string = try one(alloc, d, template, call, item, alt) });
            return .{ .array = out };
        },
        .object => |obj| {
            var out: std.json.Array = .init(alloc);
            var it = obj.iterator();
            while (it.next()) |e| {
                const item_alt = (try scalarText(alloc, e.value_ptr.*)) orelse
                    return failRender(alloc, d, template, call.offset, "filter 'image' alt values must be text", .{});
                try out.append(.{ .string = try std.fmt.allocPrint(alloc, "![{s}]({s})", .{ item_alt, e.key_ptr.* }) });
            }
            return .{ .array = out };
        },
        else => return .{ .string = try one(alloc, d, template, call, input, alt) },
    }
}

/// `[^n]: text` blocks separated by a blank line. Arrays number 1..N;
/// objects slugify each key (kebab rules) for `[^slug]:`.
fn emitFootnotes(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
) error{ Template, OutOfMemory }![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var first = true;
    switch (input) {
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                const text = (try scalarText(alloc, item)) orelse
                    return failRender(alloc, d, template, call.offset, "filter 'footnote' expects text items, but got {s}", .{typeName(item)});
                if (!first) try buf.appendSlice(alloc, "\n\n");
                first = false;
                try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "[^{d}]: {s}", .{ i + 1, text }));
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                const text = (try scalarText(alloc, e.value_ptr.*)) orelse
                    return failRender(alloc, d, template, call.offset, "filter 'footnote' expects text values", .{});
                if (!first) try buf.appendSlice(alloc, "\n\n");
                first = false;
                const slug = try slugify(alloc, e.key_ptr.*);
                try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "[^{s}]: {s}", .{ slug, text }));
            }
        },
        else => return failRender(alloc, d, template, call.offset, "filter 'footnote' expects an array or an object, but got {s}", .{typeName(input)}),
    }
    return buf.toOwnedSlice(alloc);
}

/// `text [link](url#:~:text=encoded)` — the text-fragment deep link. The
/// argument is `url`, or `linktext:url` split at the first colon. Arrays
/// collapse to a JSON-array string like wikilink.
fn emitFragmentLinks(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
) error{ Template, OutOfMemory }!std.json.Value {
    const arg = call.arg orelse
        return badArg(alloc, d, template, call, "filter 'fragment_link' requires a URL argument, e.g. fragment_link:\"https://example.com\"", .{});
    const spec = try argText(alloc, d, template, call, arg, root);
    var link_text: []const u8 = "link";
    var url = spec;
    if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
        // "Source:https://…" splits link text from URL; a ':' that opens
        // a scheme ("://") is part of the URL, not a separator.
        if (!std.mem.startsWith(u8, spec[colon..], "://") and colon > 0) {
            link_text = spec[0..colon];
            url = spec[colon + 1 ..];
        }
    }
    const one = struct {
        fn go(a: std.mem.Allocator, dd: *diag.Diagnostic, t: []const u8, c: parse.FilterCall, item_v: std.json.Value, lt: []const u8, u: []const u8) error{ Template, OutOfMemory }![]u8 {
            const text = (try scalarText(a, item_v)) orelse
                return failRender(a, dd, t, c.offset, "filter '{s}' expects text items, but got {s}", .{ c.name, typeName(item_v) });
            const enc = try percentEncode(a, text);
            return std.fmt.allocPrint(a, "{s} [{s}]({s}#:~:text={s})", .{ text, lt, u, enc });
        }
    }.go;
    switch (input) {
        .array => |arr| {
            var out: std.json.Array = .init(alloc);
            for (arr.items) |item|
                try out.append(.{ .string = try one(alloc, d, template, call, item, link_text, url) });
            return .{ .array = out };
        },
        else => return .{ .string = try one(alloc, d, template, call, input, link_text, url) },
    }
}

/// `indent:N` prefixes every line with N spaces (default 2).
fn emitIndent(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
) error{ Template, OutOfMemory }![]u8 {
    var width: usize = 2;
    if (call.arg) |arg| {
        const t = try argText(alloc, d, template, call, arg, root);
        width = std.fmt.parseInt(usize, t, 10) catch
            return badArg(alloc, d, template, call, "filter 'indent' expects a numeric width, e.g. indent:4", .{});
    }
    const text = (try scalarText(alloc, input)) orelse
        return failRender(alloc, d, template, call.offset, "filter 'indent' expects a text value, but got {s}", .{typeName(input)});
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var at_line_start = true;
    for (text) |c| {
        if (at_line_start and c != '\n') {
            try buf.appendNTimes(alloc, ' ', width);
            at_line_start = false;
        }
        try buf.append(alloc, c);
        if (c == '\n') at_line_start = true;
    }
    return buf.toOwnedSlice(alloc);
}

/// YAML emission, the documented knap forms: strings always double-quoted,
/// numbers/booleans/null bare, arrays as `- item` lines, objects as
/// `key: value` / `key:` + indented children (2 spaces per level). The
/// `flow` argument switches arrays to `["a","b"]`.
fn emitYaml(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
) error{ Template, OutOfMemory }![]u8 {
    var flow = false;
    if (call.arg) |arg| {
        const t = try argText(alloc, d, template, call, arg, root);
        if (std.mem.eql(u8, t, "flow")) {
            flow = true;
        } else return badArg(alloc, d, template, call, "filter 'yaml' accepts only the 'flow' argument", .{});
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try yamlValue(alloc, d, template, call, input, &buf, 0, flow);
    return buf.toOwnedSlice(alloc);
}

fn yamlValue(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    v: std.json.Value,
    buf: *std.ArrayList(u8),
    depth: usize,
    flow: bool,
) error{ Template, OutOfMemory }!void {
    switch (v) {
        .string => |s| try writeJsonString(alloc, s, buf),
        .number_string => |s| try buf.appendSlice(alloc, s),
        .integer => |n| try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{n})),
        .float => |f| try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{f})),
        .bool => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .null => try buf.appendSlice(alloc, "null"),
        .array => |arr| {
            if (arr.items.len == 0) {
                try buf.appendSlice(alloc, "[]");
                return;
            }
            if (flow) {
                try buf.append(alloc, '[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try buf.append(alloc, ',');
                    try yamlFlowScalar(alloc, d, template, call, item, buf);
                }
                try buf.append(alloc, ']');
            } else {
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try buf.append(alloc, '\n');
                    try buf.appendNTimes(alloc, ' ', depth * 2);
                    try buf.appendSlice(alloc, "- ");
                    switch (item) {
                        .array, .object => {
                            try buf.append(alloc, '\n');
                            try yamlValue(alloc, d, template, call, item, buf, depth + 1, flow);
                        },
                        else => try yamlFlowScalar(alloc, d, template, call, item, buf),
                    }
                }
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                if (i > 0) try buf.append(alloc, '\n');
                try buf.appendNTimes(alloc, ' ', depth * 2);
                try buf.appendSlice(alloc, e.key_ptr.*);
                switch (e.value_ptr.*) {
                    .array, .object => {
                        // Empty containers stay inline; nonempty nest.
                        const is_empty = switch (e.value_ptr.*) {
                            .array => |a| a.items.len == 0,
                            .object => |o| o.count() == 0,
                            else => unreachable,
                        };
                        if (is_empty) {
                            try buf.appendSlice(alloc, ": []");
                        } else {
                            try buf.append(alloc, ':');
                            try buf.append(alloc, '\n');
                            try yamlValue(alloc, d, template, call, e.value_ptr.*, buf, depth + 1, flow);
                        }
                    },
                    else => {
                        try buf.appendSlice(alloc, ": ");
                        try yamlFlowScalar(alloc, d, template, call, e.value_ptr.*, buf);
                    },
                }
            }
        },
    }
}

/// A scalar in YAML value position. Strings are double-quoted always —
/// knap's documented output, and unambiguous against bool/null/number
/// lookalikes like "true" or "123".
fn yamlFlowScalar(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    v: std.json.Value,
    buf: *std.ArrayList(u8),
) error{ Template, OutOfMemory }!void {
    switch (v) {
        .string => |s| try writeJsonString(alloc, s, buf),
        .array, .object => return failRender(alloc, d, template, call.offset, "filter 'yaml' cannot place {s} here", .{typeName(v)}),
        else => try yamlValue(alloc, d, template, call, v, buf, 0, false),
    }
}

/// `key: <yaml>` — yaml_property wraps yaml() under a named property,
/// nesting children one level deeper.
fn emitYamlProperty(
    alloc: std.mem.Allocator,
    d: *diag.Diagnostic,
    template: []const u8,
    call: parse.FilterCall,
    input: std.json.Value,
    root: std.json.Value,
) error{ Template, OutOfMemory }![]u8 {
    const arg = call.arg orelse
        return badArg(alloc, d, template, call, "filter 'yaml_property' requires a key argument, e.g. yaml_property:\"title\"", .{});
    const key = try argText(alloc, d, template, call, arg, root);
    if (key.len == 0 or std.mem.indexOfScalar(u8, key, '\n') != null)
        return badArg(alloc, d, template, call, "filter 'yaml_property' key must be a single line", .{});
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, key);
    switch (input) {
        .array, .object => {
            const is_empty = switch (input) {
                .array => |a| a.items.len == 0,
                .object => |o| o.count() == 0,
                else => unreachable,
            };
            if (is_empty) {
                try buf.appendSlice(alloc, ": []");
            } else {
                try buf.appendSlice(alloc, ":\n");
                try yamlValue(alloc, d, template, call, input, &buf, 1, false);
            }
        },
        else => {
            try buf.appendSlice(alloc, ": ");
            try yamlValue(alloc, d, template, call, input, &buf, 0, false);
        },
    }
    return buf.toOwnedSlice(alloc);
}

/// JSON-string escape into a raw byte buffer (`"` and `\` and control
/// chars); used both for YAML quoting and JSON-array item strings.
fn writeJsonString(alloc: std.mem.Allocator, s: []const u8, buf: *std.ArrayList(u8)) error{OutOfMemory}!void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c}));
                } else try buf.append(alloc, c);
            },
        }
    }
    try buf.append(alloc, '"');
}

/// Percent-encode per the text-fragment rule: unreserved chars
/// (A-Z a-z 0-9 - _ . ~) pass through; everything else becomes %XX on the
/// UTF-8 bytes.
fn percentEncode(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(alloc, c);
        } else {
            try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "%{X:0>2}", .{c}));
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// lowercase, non-alnum runs collapse to single dashes, edges trimmed.
fn slugify(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var pending_dash = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and buf.items.len > 0) try buf.append(alloc, '-');
            pending_dash = false;
            try buf.append(alloc, std.ascii.toLower(c));
        } else {
            pending_dash = true;
        }
    }
    return buf.toOwnedSlice(alloc);
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
/// `:leading-colon` and `a/b:c` are not treated as schemes. Public because
/// lint statically checks literal `link` arguments with the same rule.
pub fn hasBlockedScheme(url: []const u8) bool {
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

/// The scheme prefix of `url`, or `url` itself when there is no colon.
/// Public for lint's teaching output.
pub fn schemeName(url: []const u8) []const u8 {
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

fn escapeUrl(alloc: std.mem.Allocator, url: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (url) |c| {
        if (c == '(' or c == ')' or c == '\\') try out.append(alloc, '\\');
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
