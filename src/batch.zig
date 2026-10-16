//! `k4o batch` — render one template against many data rows (CSV file,
//! JSON array, or folder of JSON objects) into an output directory.

const std = @import("std");
const kt = @import("k4o");

pub const Error = error{ Template, OutOfMemory, Source, Output };

pub const Options = struct {
    /// csv|json|dir — inferred from the source when null.
    format: ?Format = null,
    /// Filename template, e.g. `{{ title | safe_name }}.md`.
    filename: ?[]const u8 = null,
    overwrite: bool = false,
    dry_run: bool = false,
    output_dir: []const u8,
    /// `--set key=value` overrides merged into every row.
    sets: []const [2][]const u8,
    output_format: kt.Format,
    max_output: usize,
};

pub const Format = enum { csv, json, dir };

const Row = struct {
    value: std.json.Value,
    /// Basename hint for folder sources ("first" for objs/first.json).
    stem: ?[]const u8 = null,
};

/// Run the batch; returns the number of files written (or listed, for
/// --dry-run, whose paths go to `list`). Errors leave a message on `d`.
pub fn run(
    init: std.process.Init,
    arena: std.mem.Allocator,
    template: []const u8,
    source_path: []const u8,
    source_bytes: ?[]const u8,
    opts: Options,
    d: *kt.Diagnostic,
    list: *std.Io.Writer,
) Error!usize {
    var rows = std.ArrayList(Row).empty;
    const format = opts.format orelse inferFormat(source_path, source_bytes);
    switch (format) {
        .csv => try readCsv(arena, source_bytes orelse try readSource(init, arena, source_path, d), &rows, d),
        .json => try readJsonArray(arena, source_bytes orelse try readSource(init, arena, source_path, d), &rows, d),
        .dir => try readDir(init, arena, source_path, &rows, d),
    }

    var names = try arena.alloc([]const u8, rows.items.len);
    var seen = std.StringHashMap(usize).init(arena);
    for (rows.items, 0..) |row, i| {
        names[i] = try outputName(arena, row, i, opts, d);
        if (seen.get(names[i])) |prior| {
            report(arena, d, "Duplicate output filename \"{s}\" from {s} record {d} and record {d}.", .{ names[i], source_path, i + 1, prior + 1 });
            return error.Source;
        }
        try seen.put(names[i], i);
    }

    var count: usize = 0;
    for (rows.items, 0..) |row, i| {
        const out_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ opts.output_dir, names[i] });
        if (opts.dry_run) {
            list.writeAll(out_path) catch return error.Output;
            list.writeAll("\n") catch return error.Output;
            count += 1;
            continue;
        }
        if (!opts.overwrite and fileExists(init, out_path)) {
            report(arena, d, "Output {s} already exists. Use --overwrite to replace existing files.", .{out_path});
            return error.Output;
        }
        var data = row.value;
        if (opts.sets.len > 0) {
            if (data != .object) {
                report(arena, d, "--set requires object rows in the data source", .{});
                return error.Source;
            }
            for (opts.sets) |kv| try data.object.put(arena, kv[0], .{ .string = kv[1] });
        }
        var rd = kt.Diagnostic{};
        const rendered = kt.renderFormatWithLimit(arena, template, data, &rd, opts.output_format, opts.max_output) catch |e| switch (e) {
            error.Template => {
                report(arena, d, "record {d}: {s}", .{ i + 1, rd.message });
                return error.Template;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try writeFile(init, out_path, rendered);
        count += 1;
    }
    return count;
}

fn inferFormat(source_path: []const u8, source_bytes: ?[]const u8) Format {
    if (source_bytes != null) return .json; // stdin is JSON by default
    if (std.mem.endsWith(u8, source_path, ".csv")) return .csv;
    if (std.mem.endsWith(u8, source_path, ".json")) return .json;
    return .dir;
}

fn readSource(init: std.process.Init, arena: std.mem.Allocator, path: []const u8, d: *kt.Diagnostic) Error![]const u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), init.io, path, arena, .limited(16 * 1024 * 1024)) catch {
        report(arena, d, "Cannot read data source '{s}'.", .{path});
        return error.Source;
    };
}

fn readJsonArray(arena: std.mem.Allocator, bytes: []const u8, rows: *std.ArrayList(Row), d: *kt.Diagnostic) Error!void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
        report(arena, d, "Invalid JSON in data source. Expected a JSON array of objects.", .{});
        return error.Source;
    };
    switch (parsed) {
        .array => |arr| {
            for (arr.items) |*item| try rows.append(arena, .{ .value = item.* });
        },
        .object => {
            // A single object is a one-row batch.
            try rows.append(arena, .{ .value = parsed });
        },
        else => {
            report(arena, d, "Invalid JSON in data source. Expected a JSON array of objects.", .{});
            return error.Source;
        },
    }
}

fn readDir(init: std.process.Init, arena: std.mem.Allocator, path: []const u8, rows: *std.ArrayList(Row), d: *kt.Diagnostic) Error!void {
    var dir = std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true }) catch {
        report(arena, d, "Cannot read data source '{s}'.", .{path});
        return error.Source;
    };
    defer dir.close(init.io);
    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (it.next(init.io) catch {
        report(arena, d, "Cannot read data source '{s}'.", .{path});
        return error.Source;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items) |name| {
        const bytes = dir.readFileAlloc(init.io, name, arena, .limited(16 * 1024 * 1024)) catch return error.Source;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
            report(arena, d, "Invalid JSON in '{s}/{s}'.", .{ path, name });
            return error.Source;
        };
        const stem = name[0 .. name.len - ".json".len];
        try rows.append(arena, .{ .value = parsed, .stem = stem });
    }
}

/// RFC-4180-ish CSV: quoted fields with `""` escapes, CRLF tolerated.
/// All values stay strings.
fn readCsv(arena: std.mem.Allocator, bytes: []const u8, rows: *std.ArrayList(Row), d: *kt.Diagnostic) Error!void {
    var fields = std.ArrayList([]const u8).empty;
    var records = std.ArrayList([]const []const u8).empty;

    var cur = std.ArrayList(u8).empty;
    var i: usize = 0;
    var quoted = false;
    var at_field_start = true;
    while (i <= bytes.len) : (i += 1) {
        const c: u8 = if (i < bytes.len) bytes[i] else '\n';
        if (quoted) {
            if (c == '"') {
                if (i + 1 < bytes.len and bytes[i + 1] == '"') {
                    try cur.append(arena, '"');
                    i += 1;
                } else {
                    quoted = false;
                }
            } else {
                try cur.append(arena, c);
            }
            continue;
        }
        switch (c) {
            '"' => {
                if (at_field_start) {
                    quoted = true;
                    at_field_start = false;
                } else {
                    try cur.append(arena, c);
                }
            },
            ',' => {
                try fields.append(arena, try cur.toOwnedSlice(arena));
                at_field_start = true;
            },
            '\n' => {
                try fields.append(arena, try cur.toOwnedSlice(arena));
                const slice = try fields.toOwnedSlice(arena);
                // A trailing empty record from a final newline is dropped.
                if (slice.len == 1 and slice[0].len == 0 and records.items.len > 0) continue;
                // Strip a CR left at the field end.
                if (slice.len > 0 and slice[slice.len - 1].len > 0 and
                    slice[slice.len - 1][slice[slice.len - 1].len - 1] == '\r')
                {
                    slice[slice.len - 1] = slice[slice.len - 1][0 .. slice[slice.len - 1].len - 1];
                }
                try records.append(arena, slice);
                at_field_start = true;
            },
            else => {
                if (c != '\r') {
                    try cur.append(arena, c);
                    at_field_start = false;
                }
            },
        }
    }
    if (records.items.len == 0) {
        report(arena, d, "CSV data source is empty.", .{});
        return error.Source;
    }
    const headers = records.items[0];
    for (records.items[1..]) |record| {
        const obj = try arena.create(std.json.Value);
        obj.* = .{ .object = .empty };
        for (headers, 0..) |h, k| {
            const val: []const u8 = if (k < record.len) record[k] else "";
            try obj.object.put(arena, h, .{ .string = val });
        }
        try rows.append(arena, .{ .value = obj.* });
    }
}

/// Resolve the output name for a record: `--filename` template rendered
/// against the row (sanitized to a basename), `N.md` for CSV/JSON rows,
/// `<stem>.md` for folder records.
fn outputName(
    arena: std.mem.Allocator,
    row: Row,
    i: usize,
    opts: Options,
    d: *kt.Diagnostic,
) Error![]const u8 {
    if (opts.filename) |ft| {
        var rd = kt.Diagnostic{};
        const rendered = kt.renderFormatWithLimit(arena, ft, row.value, &rd, .markdown, opts.max_output) catch |e| switch (e) {
            error.Template => {
                report(arena, d, "filename template error: {s}", .{rd.message});
                return error.Template;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return sanitizeFilename(rendered) orelse {
            report(arena, d, "Invalid output filename \"{s}\": filename template produced no name. Use a basename containing more than spaces, dots, hyphens, or underscores; provide a fallback value for missing data.", .{rendered});
            return error.Output;
        };
    }
    if (row.stem) |stem| return try std.fmt.allocPrint(arena, "{s}.md", .{stem});
    return try std.fmt.allocPrint(arena, "{d}.md", .{i + 1});
}

/// A rendered filename must be a non-empty basename with at least one
/// character that is not space/dot/dash/underscore.
fn sanitizeFilename(rendered: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, rendered, " \n\t\r");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '/') != null or
        std.mem.indexOfScalar(u8, trimmed, '\\') != null) return null;
    var good = false;
    for (trimmed) |c| {
        if (c != ' ' and c != '.' and c != '-' and c != '_') {
            good = true;
            break;
        }
    }
    if (!good) return null;
    return trimmed;
}

fn fileExists(init: std.process.Init, path: []const u8) bool {
    std.Io.Dir.cwd().access(init.io, path, .{}) catch return false;
    return true;
}

fn writeFile(init: std.process.Init, path: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch return error.Output;
    }
    const f = std.Io.Dir.cwd().createFile(init.io, path, .{}) catch return error.Output;
    defer f.close(init.io);
    f.writeStreamingAll(init.io, bytes) catch return error.Output;
}

fn report(arena: std.mem.Allocator, d: *kt.Diagnostic, comptime fmt: []const u8, args: anytype) void {
    d.message = std.fmt.allocPrint(arena, fmt, args) catch "batch error";
}
