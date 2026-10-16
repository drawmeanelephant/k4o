//! k4o CLI.
//!
//!     k4o render [template.knap|-] [-t <text>] [--data <file|->] [--data-json <json>]
//!                [--set k=v]... [-o <file|->] [--format markdown|oliver] [--max-output <n>]
//!     k4o batch [template.knap|-] --data <source> --output-dir <dir> [batch options]
//!     k4o validate [template.knap|-] [-t <text>]
//!     k4o lint <template.knap> [<template.knap> ...]
//!     k4o help [syntax|filters|tags|filter <name>|tag <name>]
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
const help = @import("help.zig");
const batch = @import("batch.zig");

const max_input = 16 * 1024 * 1024;

const usage_text =
    \\k4o — a knap template engine that emits CommonMark (Oliver-targeted).
    \\
    \\Usage:
    \\  k4o render [template.knap|-] [options]
    \\  k4o batch [template.knap|-] --data <source> --output-dir <dir> [options]
    \\  k4o validate [template.knap|-] [-t <text>]
    \\  k4o lint <template.knap> [<template.knap> ...]
    \\  k4o help [syntax|filters|tags|filter <name>|tag <name>]
    \\  k4o init
    \\  k4o --help
    \\  k4o --version
    \\
    \\Commands:
    \\  render              Render a template with JSON data. The template
    \\                      comes from a file, `-` (stdin), `-t`, or piped
    \\                      stdin when no file is given.
    \\  batch               Render the template once per data row — a CSV
    \\                      file, a JSON array, or a folder of JSON files —
    \\                      writing one file per row into --output-dir.
    \\  validate            Check a template parses without data or render.
    \\  lint                Check templates against the documented knap
    \\                      language; educational findings on stdout.
    \\  init                Drop the knap teaching files into the working
    \\                      dir (additive only; never overwrites).
    \\  help                Offline language reference.
    \\
    \\Render options:
    \\  -t, --template <text>    Inline template (instead of a file)
    \\  -d, --data <file>        JSON variables file, or `-` for stdin
    \\      --data-json <json>   Inline JSON variables object
    \\      --set <key=value>    Override a top-level variable; repeatable
    \\  -o, --output <file>      Write to file (or `-` for stdout, default)
    \\      --format <format>    markdown (default) or oliver
    \\      --max-output, -m <n> Output byte ceiling (default 256 MiB)
    \\
    \\Batch options:
    \\  -d, --data <source>      CSV file, JSON array file, folder of JSON
    \\                           objects, or `-` for stdin (JSON)
    \\      --format <csv|json>  Input format (overrides extension)
    \\      --data-json <json>   Inline JSON array of objects
    \\      --output-dir <dir>   Destination directory (created if needed)
    \\      --filename <text>    Filename template, e.g. '{{ title | safe_name }}.md'
    \\      --overwrite          Replace existing files (duplicates fail)
    \\      --dry-run            List output paths without writing
    \\
    \\Only one input may use stdin. Data must be a JSON object (render) or
    \\array (batch); defaults to {}. Diagnostics go to stderr; rendering
    \\errors exit 1 without writing output.
    \\
;

pub fn main(init: std.process.Init) !u8 {

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
    if (std.mem.eql(u8, first, "help")) return runHelp(init, args.items[1..]);
    if (std.mem.eql(u8, first, "render")) return runRender(init, args.items[1..]);
    if (std.mem.eql(u8, first, "validate")) return runValidate(init, args.items[1..]);
    if (std.mem.eql(u8, first, "batch")) return runBatch(init, args.items[1..]);
    return usage(init, "unknown command");
}

/// Shared option state for render/validate/batch.
const CommonOpts = struct {
    template_text: ?[]const u8 = null,
    template_path: ?[]const u8 = null,
    data_path: ?[]const u8 = null,
    data_json: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    format: kt.Format = .markdown,
    max_output: usize = kt.default_max_output,
    sets: std.ArrayList([2][]const u8) = .empty,

    const ParseError = error{ Usage, OutOfMemory };
};

/// Parse one option pair; returns false when `arg` is not a known
/// shared option (caller treats it as the positional template path or
/// a batch-specific option).
fn parseSharedOpt(
    init: std.process.Init,
    args: [][]const u8,
    i: *usize,
    opts: *CommonOpts,
    batch_format: ?*?batch.Format,
) CommonOpts.ParseError!bool {
    const arg = args[i.*];
    const next = struct {
        fn take(aa: [][]const u8, ii: *usize) ![]const u8 {
            ii.* += 1;
            if (ii.* >= aa.len) return error.Usage;
            return aa[ii.*];
        }
    }.take;
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        printStdout(init, usage_text) catch {};
        std.process.exit(0);
    } else if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) {
        opts.template_text = next(args, i) catch return error.Usage;
    } else if (std.mem.startsWith(u8, arg, "--template=") or std.mem.startsWith(u8, arg, "-t=")) {
        opts.template_text = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
    } else if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
        if (opts.data_path != null) return error.Usage;
        opts.data_path = next(args, i) catch return error.Usage;
    } else if (std.mem.startsWith(u8, arg, "--data=") or std.mem.startsWith(u8, arg, "-d=")) {
        if (opts.data_path != null) return error.Usage;
        opts.data_path = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
    } else if (std.mem.eql(u8, arg, "--data-json")) {
        if (opts.data_json != null) return error.Usage;
        opts.data_json = next(args, i) catch return error.Usage;
    } else if (std.mem.startsWith(u8, arg, "--data-json=")) {
        if (opts.data_json != null) return error.Usage;
        opts.data_json = arg["--data-json=".len..];
    } else if (std.mem.eql(u8, arg, "--set")) {
        const kv = next(args, i) catch return error.Usage;
        try appendSet(init, opts, kv);
    } else if (std.mem.startsWith(u8, arg, "--set=")) {
        try appendSet(init, opts, arg["--set=".len..]);
    } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
        opts.output_path = next(args, i) catch return error.Usage;
    } else if (std.mem.startsWith(u8, arg, "--output=") or std.mem.startsWith(u8, arg, "-o=")) {
        opts.output_path = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
    } else if (std.mem.eql(u8, arg, "--format")) {
        const v = next(args, i) catch return error.Usage;
        if (batch_format != null) {
            if (std.mem.eql(u8, v, "csv")) {
                batch_format.?.* = .csv;
                return true;
            }
            if (std.mem.eql(u8, v, "json")) {
                batch_format.?.* = .json;
                return true;
            }
        }
        opts.format = parseFormat(v) orelse return error.Usage;
    } else if (std.mem.startsWith(u8, arg, "--format=")) {
        const v = arg["--format=".len..];
        if (batch_format != null) {
            if (std.mem.eql(u8, v, "csv")) {
                batch_format.?.* = .csv;
                return true;
            }
            if (std.mem.eql(u8, v, "json")) {
                batch_format.?.* = .json;
                return true;
            }
        }
        opts.format = parseFormat(v) orelse return error.Usage;
    } else if (std.mem.eql(u8, arg, "--max-output") or std.mem.eql(u8, arg, "-m")) {
        const v = next(args, i) catch return error.Usage;
        opts.max_output = parseSize(v) catch return error.Usage;
    } else if (std.mem.startsWith(u8, arg, "--max-output=") or std.mem.startsWith(u8, arg, "-m=")) {
        const v = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
        opts.max_output = parseSize(v) catch return error.Usage;
    } else {
        return false;
    }
    return true;
}

/// `--set key=value` — splits at the first `=`, key required.
fn appendSet(init: std.process.Init, opts: *CommonOpts, kv: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.Usage;
    if (eq == 0) return error.Usage;
    try opts.sets.append(init.arena.allocator(), .{ kv[0..eq], kv[eq + 1 ..] });
}

/// Resolve the template source: `-t`, a positional path, `-`, or piped
/// stdin. `stdin_used` records when stdin was consumed so `--data -` can
/// refuse a second read.
fn resolveTemplate(
    init: std.process.Init,
    arena: std.mem.Allocator,
    opts: *const CommonOpts,
    stdin_used: *bool,
) ![]const u8 {
    if (opts.template_text) |t| return t;
    if (opts.template_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            stdin_used.* = true;
            return readStdin(init, arena);
        }
        return std.Io.Dir.readFileAlloc(.cwd(), init.io, path, arena, .limited(max_input)) catch |e| {
            report("{s} '{s}': {s}", .{ "cannot read template file", path, @errorName(e) });
            return error.Template;
        };
    }
    stdin_used.* = true;
    return readStdin(init, arena);
}

fn readStdin(init: std.process.Init, arena: std.mem.Allocator) ![]const u8 {
    var buf: [8192]u8 = undefined;
    var r = std.Io.File.stdin().reader(init.io, &buf);
    return r.interface.allocRemaining(arena, .limited(max_input)) catch
        return error.Template;
}

/// Resolve the data root: `--data-json`, `--data file`, `--data -`, or
/// `{}`. `--set` overrides merge last. `require_object` keeps render's
/// contract while batch accepts arrays.
fn resolveData(
    init: std.process.Init,
    arena: std.mem.Allocator,
    opts: *const CommonOpts,
    stdin_used: *bool,
    require_object: bool,
) !std.json.Value {
    var root: std.json.Value = .{ .object = .empty };
    if (opts.data_json) |js| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, js, .{}) catch {
            report("{s}", .{"invalid JSON in --data-json"});
            return error.Template;
        };
        root = parsed;
    } else if (opts.data_path) |dp| {
        const bytes = if (std.mem.eql(u8, dp, "-")) blk: {
            if (stdin_used.*) {
                report("{s}", .{"template and data cannot both read stdin"});
                return error.Template;
            }
            stdin_used.* = true;
            break :blk try readStdin(init, arena);
        } else std.Io.Dir.readFileAlloc(.cwd(), init.io, dp, arena, .limited(max_input)) catch |e| {
            report("{s} '{s}': {s}", .{ "cannot read data file", dp, @errorName(e) });
            return error.Template;
        };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
            report("{s} '{s}'", .{ "invalid JSON in data file", dp });
            return error.Template;
        };
        root = parsed;
    }
    if (require_object and root != .object) {
        report("{s}", .{"data must be a JSON object"});
        return error.Template;
    }
    if (opts.sets.items.len > 0) {
        if (root != .object) {
            report("{s}", .{"--set requires a JSON object data root"});
            return error.Template;
        }
        for (opts.sets.items) |kv| {
            try root.object.put(arena, kv[0], .{ .string = kv[1] });
        }
    }
    return root;
}

fn runRender(init: std.process.Init, args: [][]const u8) !u8 {
    const arena = init.arena.allocator();
    var opts = CommonOpts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseSharedOpt(init, args, &i, &opts, null) catch return usage(init, "invalid render option")) continue;
        const arg = args[i];
        if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            return usage(init, "unknown render option");
        }
        if (opts.template_path != null) return usage(init, "multiple template files");
        opts.template_path = arg;
    }

    var stdin_used = false;
    const template = resolveTemplate(init, arena, &opts, &stdin_used) catch return 1;
    const root = resolveData(init, arena, &opts, &stdin_used, true) catch return 1;

    var d = kt.Diagnostic{};
    const out = kt.renderFormatWithLimit(arena, template, root, &d, opts.format, opts.max_output) catch |e| switch (e) {
        error.Template => {
            report("{s}", .{if (d.message.len > 0) d.message else "template error"});
            return 1;
        },
        error.OutOfMemory => {
            report("out of memory", .{});
            return 1;
        },
    };

    return writeOutput(init, arena, opts.output_path, out);
}

/// `-o`: write buffered output to a file (creating parent dirs) or to
/// stdout. Errors reach here only after the render completed, so a
/// failed render never touches the destination.
fn writeOutput(init: std.process.Init, arena: std.mem.Allocator, path_opt: ?[]const u8, bytes: []const u8) !u8 {
    _ = arena;
    if (path_opt) |path| {
        if (!std.mem.eql(u8, path, "-")) {
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(init.io, dir) catch {
                    report("cannot create output directory for '{s}'", .{path});
                    return 1;
                };
            }
            const f = std.Io.Dir.cwd().createFile(init.io, path, .{}) catch {
                report("cannot write output file '{s}'", .{path});
                return 1;
            };
            defer f.close(init.io);
            f.writeStreamingAll(init.io, bytes) catch {
                report("cannot write output file '{s}'", .{path});
                return 1;
            };
            return 0;
        }
    }
    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    w.interface.writeAll(bytes) catch return 1;
    w.flush() catch return 1;
    return 0;
}

fn runValidate(init: std.process.Init, args: [][]const u8) !u8 {
    const arena = init.arena.allocator();
    var opts = CommonOpts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseSharedOpt(init, args, &i, &opts, null) catch return usage(init, "invalid validate option")) continue;
        const arg = args[i];
        if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            return usage(init, "unknown validate option");
        }
        if (opts.template_path != null) return usage(init, "multiple template files");
        opts.template_path = arg;
    }
    var stdin_used = false;
    const template = resolveTemplate(init, arena, &opts, &stdin_used) catch return 1;

    var d = kt.Diagnostic{};
    const name = opts.template_path orelse "<template>";
    _ = kt.parse.parseDocument(arena, template, &d) catch |e| switch (e) {
        error.Template => {
            report("{s}:{d}:{d}: error: {s}", .{ name, d.line, d.column, d.detail });
            return 1;
        },
        error.OutOfMemory => {
            report("out of memory", .{});
            return 1;
        },
    };
    const msg = try std.fmt.allocPrint(arena, "{s}: Template is valid (static checks only; runtime values are not checked).\n", .{name});
    try printStdout(init, msg);
    return 0;
}

fn runBatch(init: std.process.Init, args: [][]const u8) !u8 {
    const arena = init.arena.allocator();
    var opts = CommonOpts{};
    var output_dir: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var overwrite = false;
    var dry_run = false;
    var source_format: ?batch.Format = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (parseSharedOpt(init, args, &i, &opts, &source_format) catch return usage(init, "invalid batch option")) continue;
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output-dir")) {
            i += 1;
            if (i >= args.len) return usage(init, "missing value for --output-dir");
            output_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output-dir=")) {
            output_dir = arg["--output-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--filename")) {
            i += 1;
            if (i >= args.len) return usage(init, "missing value for --filename");
            filename = args[i];
        } else if (std.mem.startsWith(u8, arg, "--filename=")) {
            filename = arg["--filename=".len..];
        } else if (std.mem.eql(u8, arg, "--overwrite")) {
            overwrite = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            return usage(init, "unknown batch option");
        } else {
            if (opts.template_path != null) return usage(init, "multiple template files");
            opts.template_path = arg;
        }
    }

    const dir = output_dir orelse return usage(init, "batch requires --output-dir <dir>");
    if (opts.data_path == null and opts.data_json == null) {
        return usage(init, "batch requires --data <source> or --data-json <json>");
    }
    // --data on batch is a source (file, dir, or -), not a JSON file.
    const source_path: []const u8 = opts.data_path orelse "";

    var stdin_used = false;
    const template = resolveTemplate(init, arena, &opts, &stdin_used) catch return 1;

    // Source resolution: --data-json inline, --data - from stdin,
    // --data <path> file/dir.
    var source_bytes: ?[]const u8 = null;
    if (opts.data_json) |js| {
        source_bytes = js;
        if (source_format == null) source_format = .json;
    } else if (std.mem.eql(u8, source_path, "-")) {
        if (stdin_used) {
            report("{s}", .{"template and data cannot both read stdin"});
            return 1;
        }
        stdin_used = true;
        source_bytes = readStdin(init, arena) catch {
            report("{s}", .{"cannot read stdin"});
            return 1;
        };
        if (source_format == null) source_format = .json;
    }

    var d = kt.Diagnostic{};
    var list_buf: [8192]u8 = undefined;
    var listw = std.Io.File.stdout().writer(init.io, &list_buf);
    const count = batch.run(init, arena, template, source_path, source_bytes, .{
        .format = source_format,
        .filename = filename,
        .overwrite = overwrite,
        .dry_run = dry_run,
        .output_dir = dir,
        .sets = opts.sets.items,
        .output_format = opts.format,
        .max_output = opts.max_output,
    }, &d, &listw.interface) catch |e| {
        report("{s}", .{if (d.message.len > 0) d.message else @errorName(e)});
        return 1;
    };
    listw.flush() catch return 1;
    // Summaries go to stderr, like the oracle.
    if (dry_run) {
        report("Would write {d} files to {s}.", .{ count, dir });
    } else {
        report("Wrote {d} files to {s}.", .{ count, dir });
    }
    return 0;
}

fn runHelp(init: std.process.Init, args: [][]const u8) !u8 {
    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    const ok = help.print(&w.interface, args) catch return 1;
    w.flush() catch return 1;
    return if (ok) 0 else 1;
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
