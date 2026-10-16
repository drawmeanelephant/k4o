//! `k4o help [syntax|filters|tags|filter <name>|tag <name>]` — the
//! offline language reference, captured from `knap help` output (public
//! documentation; the oracle stays a black box for internals).

const std = @import("std");

const syntax_doc = @embedFile("help/syntax.txt");
const filters_doc = @embedFile("help/filters.txt");
const tags_doc = @embedFile("help/tags.txt");
const filter_details = @embedFile("help/filter-details.txt");
const tag_details = @embedFile("help/tag-details.txt");

/// Print the requested help topic; returns false for an unknown one.
pub fn print(out: *std.Io.Writer, args: []const []const u8) !bool {
    if (args.len == 0) {
        try out.writeAll(topic_index);
        return true;
    }
    const topic = args[0];
    if (std.mem.eql(u8, topic, "syntax")) {
        try out.writeAll(syntax_doc);
        return true;
    }
    if (std.mem.eql(u8, topic, "filters")) {
        try out.writeAll(filters_doc);
        return true;
    }
    if (std.mem.eql(u8, topic, "tags")) {
        try out.writeAll(tags_doc);
        return true;
    }
    if (args.len < 2) {
        try out.writeAll(topic_index);
        return true;
    }
    const name = args[1];
    if (std.mem.eql(u8, topic, "filter")) {
        if (sliceSection(filter_details, name)) |section| {
            try out.writeAll(section);
            return true;
        }
        try out.print("k4o: no help entry for filter '{s}'\n", .{name});
        return false;
    }
    if (std.mem.eql(u8, topic, "tag")) {
        if (sliceSection(tag_details, name)) |section| {
            try out.writeAll(section);
            return true;
        }
        try out.print("k4o: no help entry for tag '{s}'\n", .{name});
        return false;
    }
    return false;
}

/// Sections in the detail files are headed `=== <name> ===` lines.
fn sliceSection(doc: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < doc.len) {
        const line_end = std.mem.indexOfScalarPos(u8, doc, pos, '\n') orelse doc.len;
        const line = doc[pos..line_end];
        var wanted_buf: [128]u8 = undefined;
        const wanted = std.fmt.bufPrint(&wanted_buf, "=== {s} ===", .{name}) catch continue;
        if (std.mem.eql(u8, line, wanted)) {
            const body_start = line_end + 1;
            var scan = body_start;
            while (scan < doc.len) {
                if (std.mem.startsWith(u8, doc[scan..], "=== ")) {
                    return doc[body_start..scan];
                }
                const nl = std.mem.indexOfScalarPos(u8, doc, scan, '\n') orelse doc.len;
                scan = nl + 1;
            }
            return doc[body_start..];
        }
        pos = line_end + 1;
    }
    return null;
}

const topic_index =
    \\Usage: k4o help [syntax|filters|tags|filter <name>|tag <name>]
    \\
    \\  syntax            Variables, filter chaining, logic, whitespace
    \\  filters           Every filter with a short description
    \\  tags              Every logic tag with a short description
    \\  filter <name>     Full reference for one filter
    \\  tag <name>        Syntax and examples for a logic tag
    \\
;
