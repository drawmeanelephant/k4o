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
        try out.writeAll(tags_addendum);
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
        if (std.mem.eql(u8, name, "raw")) {
            try out.writeAll(raw_tag_doc);
            return true;
        }
        try out.print("k4o: no help entry for tag '{s}'\n", .{name});
        return false;
    }
    return false;
}

/// `{% raw %}` is a k4o extension the oracle lacks, so its reference
/// lives here rather than in the captured tag-details.txt.
const tags_addendum =
    \\
    \\k4o extension:
    \\  raw        Emit content literally, unevaluated (not in knap 0.6.0).
    \\
;

const raw_tag_doc =
    \\raw
    \\
    \\Emit the content between the tags literally — `{{`, `{%` and `{#`
    \\inside are output, not tags. k4o extension: knap 0.6.0 has no
    \\literal-text escape and rejects `{% raw %}` as an unknown tag.
    \\
    \\Syntax:
    \\  {% raw %} ... {% endraw %}
    \\
    \\The first `{% endraw %}` tag closes the block; raw blocks do not
    \\nest. To emit a literal `{% endraw %}`, use an output tag with a
    \\quoted literal: {{ "{% endraw %}" }}.
    \\
    \\The tags follow the standalone-line whitespace rules: a clean-line
    \\`{% raw %}` eats the rest of its line, and a column-0 clean-line
    \\`{% endraw %}` swallows the body's trailing whitespace run.
    \\
    \\Example (JSON strings show exact whitespace):
    \\Document a tag:
    \\  Template: "Use {% raw %}{{ title }}{% endraw %} for the title."
    \\  Output: "Use {{ title }} for the title."
    \\
    \\Reference: k4o help tags | k4o help syntax
    \\
;

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
