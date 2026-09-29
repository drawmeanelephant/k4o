//! knap-textile CLI.
//!
//!     knap-textile render <template.knap> [--data <data.json>]
//!     knap-textile --help
//!     knap-textile --version
//!
//! Exit codes: 0 = success, 1 = any error. On error the message goes to
//! stderr and stdout stays empty — rendering is buffered, so partially
//! rendered output is never emitted.

const std = @import("std");
const kt = @import("knap_textile");
const build_options = @import("build_options");

const max_input = 16 * 1024 * 1024;

const usage_text =
    \\knap-textile — a Knap template engine that emits Textile.
    \\
    \\Usage:
    \\  knap-textile render <template.knap> [--data <data.json>]
    \\  knap-textile --help
    \\  knap-textile --version
    \\
    \\Options:
    \\  --data, -d <file>   JSON object with the template variables
    \\                      (optional; defaults to {}). The --data=<file>
    \\                      form is also accepted.
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
        const text = try std.fmt.bufPrint(&buf, "knap-textile {s}\n", .{build_options.version});
        try printStdout(init, text);
        return 0;
    }
    if (!std.mem.eql(u8, first, "render")) return usage(init, "unknown command");
    if (args.items.len == 1) return usage(init, "missing template file");

    var template_path: ?[]const u8 = null;
    var data_path: ?[]const u8 = null;
    var max_output: usize = kt.default_max_output;
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
    const out = kt.renderWithLimit(arena, template, root, &d, max_output) catch |e| switch (e) {
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
    report("usage: knap-textile render <template.knap> [--data <data.json>]  (see --help)", .{});
    return 1;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("knap-textile: " ++ fmt ++ "\n", args);
}
