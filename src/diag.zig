//! Structured diagnostics for template errors.
//!
//! Every failure carries a kind, a 1-based line/column position (columns
//! count Unicode code points), a short detail, and a fully formatted
//! message of the shape:
//!
//!     <kind> at line <L>, column <C>: <detail>

const std = @import("std");

pub const Kind = enum {
    syntax,
    unknown_filter,
    bad_argument,
    render,

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .syntax => "syntax error",
            .unknown_filter => "unknown filter",
            .bad_argument => "bad argument",
            .render => "render error",
        };
    }
};

pub const Diagnostic = struct {
    kind: Kind = .render,
    line: u32 = 1,
    column: u32 = 1,
    detail: []const u8 = "",
    message: []const u8 = "",
};

pub const Pos = struct {
    line: u32,
    column: u32,
};

/// A non-fatal filter warning — the oracle's stderr channel
/// (INVALID_FILTER_INPUT / FILTER_WARNING). The render continues with the
/// filter's input passed through unchanged; the warning rides alongside.
pub const Warning = struct {
    pub const Code = enum {
        invalid_filter_input,
        filter_warning,

        pub fn label(code: Code) []const u8 {
            return switch (code) {
                .invalid_filter_input => "INVALID_FILTER_INPUT",
                .filter_warning => "FILTER_WARNING",
            };
        }
    };

    code: Code,
    /// Name of the filter that warned.
    filter: []const u8,
    /// Absolute byte offset of the filter name in the template.
    offset: usize,
    detail: []const u8,

    /// `warning <CODE> at line <L>, column <C>: <filter>: <detail>` — the
    /// CLI prefixes this with `k4o: ` like any other diagnostic.
    pub fn message(self: Warning, alloc: std.mem.Allocator, template: []const u8) error{OutOfMemory}![]const u8 {
        const pos = positionOf(template, self.offset);
        return std.fmt.allocPrint(alloc, "warning {s} at line {d}, column {d}: {s}: {s}", .{ self.code.label(), pos.line, pos.column, self.filter, self.detail });
    }
};

/// 1-based position of `offset` in `template`. Columns count Unicode code
/// points (UTF-8 lead bytes), so one multi-byte character occupies one
/// column.
pub fn positionOf(template: []const u8, offset: usize) Pos {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    const end = @min(offset, template.len);
    while (i < end) : (i += 1) {
        const b = template[i];
        if (b == '\n') {
            line += 1;
            col = 1;
        } else if ((b & 0xC0) != 0x80) {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

/// Records a failure into `d` and returns `error.Template`. Allocation
/// failures while formatting degrade to static text so the original error
/// kind is never masked.
pub fn fail(
    alloc: std.mem.Allocator,
    d: *Diagnostic,
    kind: Kind,
    template: []const u8,
    offset: usize,
    comptime fmt: []const u8,
    args: anytype,
) error{Template} {
    const pos = positionOf(template, offset);
    const detail = std.fmt.allocPrint(alloc, fmt, args) catch "(out of memory while formatting detail)";
    d.kind = kind;
    d.line = pos.line;
    d.column = pos.column;
    d.detail = detail;
    d.message = std.fmt.allocPrint(alloc, "{s} at line {d}, column {d}: {s}", .{ kind.label(), pos.line, pos.column, detail }) catch "(template error)";
    return error.Template;
}

test "positionOf counts codepoints" {
    const t = "ab\ncdé\nf";
    try std.testing.expectEqual(Pos{ .line = 1, .column = 1 }, positionOf(t, 0));
    try std.testing.expectEqual(Pos{ .line = 1, .column = 3 }, positionOf(t, 2));
    try std.testing.expectEqual(Pos{ .line = 2, .column = 1 }, positionOf(t, 3));
    try std.testing.expectEqual(Pos{ .line = 2, .column = 4 }, positionOf(t, 6));
    // offset past end clamps.
    try std.testing.expectEqual(Pos{ .line = 3, .column = 2 }, positionOf(t, 999));
}
