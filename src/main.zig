//! k4o CLI.
//!
//!     k4o render <template.knap> [--data <data.json>] [--format markdown|oliver]
//!     k4o lint <template.knap> [<template.knap> ...]
//!     k4o init
//!     k4o --help
//!     k4o --version
//!
//! Exit codes: 0 = success, 1 = any error. On error the message goes to
//! stderr and stdout stays empty — rendering is buffered, so partially
//! rendered output is never emitted. `lint` reports findings on stdout and
//! exits 0 when every file is clean, 1 otherwise. `init` reports what it
//! created, left untouched, or archived, and exits 0 unless the filesystem
//! fails.

const std = @import("std");
const kt = @import("k4o");
const build_options = @import("build_options");

const max_input = 16 * 1024 * 1024;

const usage_text =
    \\k4o — a knap template engine that emits CommonMark (Oliver-targeted).
    \\
    \\Usage:
    \\  k4o render <template.knap> [--data <data.json>] [--format markdown|oliver]
    \\  k4o lint <template.knap> [<template.knap> ...]
    \\  k4o init
    \\  k4o --help
    \\  k4o --version
    \\
    \\Commands:
    \\  render              Render a template with JSON data (see --data).
    \\  lint                Check templates against the documented knap
    \\                      subset without data. Every finding names the
    \\                      offending construct, explains the rule, and shows
    \\                      an example of right. Exit 0 when every file is
    \\                      clean, 1 when any file has findings or cannot be
    \\                      read. Findings go to stdout.
    \\  init                Drop the knap teaching files (language tour,
    \\                      templates, examples, gotchas) into the working
    \\                      dir so an agent can pull knap-into-context.
    \\                      Strictly additive: only files that do not exist
    \\                      are created, and a superseded init file is
    \\                      archived (never overwritten, never deleted).
    \\
    \\Options:
    \\  --data, -d <file>   JSON object with the template variables
    \\                      (optional; defaults to {}). The --data=<file>
    \\                      form is also accepted.
    \\  --format <format>   Output format: markdown (default, byte-faithful
    \\                      to the knap oracle) or oliver (markdown plus HTML
    \\                      passthrough for highlight, math and comment).
    \\                      The --format=<format> form is also accepted.
    \\  --max-output, -m <bytes>
    \\                      Ceiling on rendered output, in bytes. Nested
    \\                      loops multiply, so a small template over modest
    \\                      data can ask for far more than you expect.
    \\                      Default 268435456 (256 MiB); 0 means no limit.
    \\  --help, -h          Show this help.
    \\  --version, -v       Show the version.
    \\
    \\Exit codes: 0 = success, 1 = any error (message on stderr).
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(init.gpa);
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next(); // program name
    while (it.next()) |arg| try args.append(init.gpa, arg);

    if (args.items.len == 0) return usage(init, "missing command");
    const first = args.items[0];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        try printStdout(init, usage_text);
        return 0;
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "k4o {s}\n", .{build_options.version});
        try printStdout(init, text);
        return 0;
    }
    if (std.mem.eql(u8, first, "lint")) return runLint(init, args.items[1..]);
    if (std.mem.eql(u8, first, "init")) return runInit(init, args.items[1..]);
    if (!std.mem.eql(u8, first, "render")) return usage(init, "unknown command");
    if (args.items.len == 1) return usage(init, "missing template file");

    var template_path: ?[]const u8 = null;
    var data_path: ?[]const u8 = null;
    var max_output: usize = kt.default_max_output;
    var format: kt.Format = .markdown;
    var seen_format = false;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printStdout(init, usage_text);
            return 0;
        } else if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --data");
            if (data_path != null) return usage(init, "duplicate --data");
            data_path = args.items[i];
        } else if (std.mem.startsWith(u8, arg, "--data=") or std.mem.startsWith(u8, arg, "-d=")) {
            // `--data=FILE` / `-d=FILE`. The bare `--data` form is matched
            // above, so this is only reached with an `=` in the argument.
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --data");
            if (data_path != null) return usage(init, "duplicate --data");
            data_path = value;
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --format");
            if (seen_format) return usage(init, "duplicate --format");
            format = parseFormat(args.items[i]) orelse return usage(init, "invalid --format: expected markdown or oliver");
            seen_format = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            if (seen_format) return usage(init, "duplicate --format");
            format = parseFormat(arg["--format=".len..]) orelse return usage(init, "invalid --format: expected markdown or oliver");
            seen_format = true;
        } else if (std.mem.eql(u8, arg, "--max-output") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --max-output");
            max_output = parseSize(args.items[i]) catch |e| return usage(init, switch (e) {
                error.NotANumber => "invalid value for --max-output: not a number",
                error.Negative => "invalid value for --max-output: must not be negative",
            });
        } else if (std.mem.startsWith(u8, arg, "--max-output=") or std.mem.startsWith(u8, arg, "-m=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --max-output");
            max_output = parseSize(value) catch |e| return usage(init, switch (e) {
                error.NotANumber => "invalid value for --max-output: not a number",
                error.Negative => "invalid value for --max-output: must not be negative",
            });
        } else if (arg.len > 1 and arg[0] == '-') {
            return usage(init, "unknown option");
        } else {
            if (template_path != null) return usage(init, "multiple template files (did you mean --data <file>?)");
            template_path = arg;
        }
    }
    const tpl_path = template_path orelse return usage(init, "missing template file");

    const template = std.Io.Dir.readFileAlloc(.cwd(), init.io, tpl_path, arena, .limited(max_input)) catch |e| {
        report("{s} '{s}': {s}", .{ "cannot read template file", tpl_path, @errorName(e) });
        return 1;
    };

    var root: std.json.Value = .{ .object = .empty };
    if (data_path) |dp| {
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), init.io, dp, arena, .limited(max_input)) catch |e| {
            report("{s} '{s}': {s}", .{ "cannot read data file", dp, @errorName(e) });
            return 1;
        };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |e| {
            report("{s} '{s}': {s}", .{ "invalid JSON in data file", dp, @errorName(e) });
            return 1;
        };
        switch (parsed) {
            .object => root = parsed,
            else => {
                report("data file '{s}' must contain a JSON object", .{dp});
                return 1;
            },
        }
    }

    var d = kt.Diagnostic{};
    const out = kt.renderFormatWithLimit(arena, template, root, &d, format, max_output) catch |e| switch (e) {
        error.Template => {
            report("{s}", .{if (d.message.len > 0) d.message else "template error"});
            return 1;
        },
        error.OutOfMemory => {
            report("out of memory", .{});
            return 1;
        },
    };

    // Buffered render complete: emit in one write so that an error never
    // produces half-rendered output.
    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    w.interface.writeAll(out) catch return 1;
    w.flush() catch return 1;
    return 0;
}

/// `k4o lint <template.knap> [...]`: education-grade diagnostics over the
/// shared parser. Findings go to stdout; exit 0 when every file is clean,
/// 1 when any file has findings or cannot be read.
fn runLint(init: std.process.Init, args: [][]const u8) !u8 {
    const arena = init.arena.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(init.gpa);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printStdout(init, usage_text);
            return 0;
        } else if (arg.len > 1 and arg[0] == '-') {
            return usage(init, "unknown option");
        } else {
            try paths.append(init.gpa, arg);
        }
    }
    if (paths.items.len == 0) return usage(init, "missing template file");

    var report_buf: std.ArrayList(u8) = .empty;
    defer report_buf.deinit(init.gpa);
    var problems: usize = 0;
    var findings_files: usize = 0;
    var unreadable: usize = 0;
    for (paths.items) |path| {
        const template = std.Io.Dir.readFileAlloc(.cwd(), init.io, path, arena, .limited(max_input)) catch |e| {
            report("cannot read template file '{s}': {s}", .{ path, @errorName(e) });
            unreadable += 1;
            continue;
        };
        var d = kt.Diagnostic{};
        const findings = kt.lintDocument(arena, template, &d) catch {
            report("out of memory", .{});
            return 1;
        };
        if (findings.len == 0) continue;
        findings_files += 1;
        problems += findings.len;
        for (findings) |f| {
            const block = try std.fmt.allocPrint(
                arena,
                "{s}:{d}:{d}: {s}: {s}\n  construct: {s}\n  why: {s}\n  example: {s}\n\n",
                .{ path, f.line, f.column, f.kind.label(), f.detail, f.construct, f.why, f.example },
            );
            try report_buf.appendSlice(init.gpa, block);
        }
    }

    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    if (problems == 0 and unreadable == 0) {
        const summary = try std.fmt.allocPrint(arena, "k4o lint: {d} file(s) clean\n", .{paths.items.len});
        try report_buf.appendSlice(init.gpa, summary);
    } else {
        var summary_buf: [256]u8 = undefined;
        const summary = if (unreadable > 0)
            try std.fmt.bufPrint(&summary_buf, "k4o lint: {d} problem(s) in {d} of {d} file(s); {d} file(s) unreadable\n", .{ problems, findings_files, paths.items.len, unreadable })
        else
            try std.fmt.bufPrint(&summary_buf, "k4o lint: {d} problem(s) in {d} of {d} file(s)\n", .{ problems, findings_files, paths.items.len });
        try report_buf.appendSlice(init.gpa, summary);
    }
    w.interface.writeAll(report_buf.items) catch return 1;
    w.flush() catch return 1;
    return if (problems == 0 and unreadable == 0) 0 else 1;
}

/// `k4o init`: drop the knap teaching files into the working dir.
/// Strictly additive — existing files are never overwritten (an older
/// init-marked file is archived first). Exit 0 unless the filesystem fails.
fn runInit(init: std.process.Init, args: [][]const u8) !u8 {
    const arena = init.arena.allocator();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printStdout(init, usage_text);
            return 0;
        }
        return usage(init, "init takes no arguments");
    }

    var reports: std.ArrayList(kt.init.Report) = .empty;
    defer reports.deinit(arena);
    kt.init.scaffold(arena, init.io, .cwd(), &reports) catch |e| {
        report("init failed: {s}", .{@errorName(e)});
        return 1;
    };

    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    var created: usize = 0;
    var untouched: usize = 0;
    var archived: usize = 0;
    for (reports.items) |r| {
        switch (r.action) {
            .created => {
                created += 1;
                try w.interface.print("created {s}\n", .{r.file});
            },
            .up_to_date => {
                untouched += 1;
                try w.interface.print("{s} is current (v{d})\n", .{ r.file, r.disk_version.? });
            },
            .left_untouched => {
                untouched += 1;
                try w.interface.print("{s} exists, left untouched\n", .{r.file});
            },
            .archived => {
                archived += 1;
                try w.interface.print("{s} superseded (v{d} -> v{d}); old copy archived to {s}\n", .{ r.file, r.disk_version.?, kt.init.set_version, r.archive_path.? });
            },
        }
    }
    var summary_buf: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(&summary_buf, "k4o init: {d} created, {d} untouched, {d} archived\n", .{ created, untouched, archived });
    try w.interface.writeAll(summary);
    try w.flush();
    return 0;
}

fn parseFormat(name: []const u8) ?kt.Format {
    if (std.mem.eql(u8, name, "markdown")) return .markdown;
    if (std.mem.eql(u8, name, "oliver")) return .oliver;
    return null;
}

/// Parses a byte count, accepting a `k`/`m`/`g` suffix (case-insensitive).
fn parseSize(text: []const u8) error{ NotANumber, Negative }!usize {
    if (text.len == 0) return error.NotANumber;
    var digits = text;
    var scale: usize = 1;
    switch (std.ascii.toLower(text[text.len - 1])) {
        'k' => {
            digits = text[0 .. text.len - 1];
            scale = 1024;
        },
        'm' => {
            digits = text[0 .. text.len - 1];
            scale = 1024 * 1024;
        },
        'g' => {
            digits = text[0 .. text.len - 1];
            scale = 1024 * 1024 * 1024;
        },
        else => {},
    }
    if (digits.len == 0) return error.NotANumber;
    if (digits[0] == '-') return error.Negative;
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.NotANumber;
    const scaled = std.math.mul(u64, n, scale) catch return error.NotANumber;
    return std.math.cast(usize, scaled) orelse error.NotANumber;
}

fn printStdout(init: std.process.Init, text: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    try w.interface.writeAll(text);
    try w.flush();
}

fn usage(init: std.process.Init, msg: []const u8) u8 {
    _ = init;
    report("{s}", .{msg});
    report("usage: k4o render <template.knap> [--data <data.json>]  (see --help)", .{});
    return 1;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("k4o: " ++ fmt ++ "\n", args);
}
