//! Template engine: parse + evaluate the Knap subset into Textile bytes.
//!
//! Output and all temporary values are allocated with `alloc`; callers
//! typically pass an arena allocator and free everything at once.

const std = @import("std");
const build_options = @import("build_options");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const filters = @import("filters.zig");

pub const Error = error{ Template, OutOfMemory };

const passthrough_mode = std.mem.eql(u8, build_options.engine_mode, "passthrough");

/// Default ceiling on rendered output, in bytes.
///
/// Nested loops multiply: L nested loops over arrays of length N render N^L
/// times, so a short template over modest data can ask for gigabytes. This
/// bounds that with a clear diagnostic instead of letting the arena allocator
/// run out after minutes of work. Override with `renderWithLimit`, or from
/// the CLI with `--max-output`.
pub const default_max_output: usize = 256 * 1024 * 1024;

/// Renders `template` with `data` (a JSON object whose properties are the
/// variables) and returns the rendered bytes, allocated with `alloc`.
pub fn render(
    alloc: std.mem.Allocator,
    template: []const u8,
    data: std.json.Value,
    d: *diag.Diagnostic,
) Error![]const u8 {
    return renderWithLimit(alloc, template, data, d, default_max_output);
}

/// As `render`, but caps the output at `max_output` bytes. Pass 0 for no cap.
pub fn renderWithLimit(
    alloc: std.mem.Allocator,
    template: []const u8,
    data: std.json.Value,
    d: *diag.Diagnostic,
    max_output: usize,
) Error![]const u8 {
    if (passthrough_mode) {
        // Red-verification mutant: a goldbrick engine that returns the
        // template unchanged (no parsing, no validation, no filters).
        // `zig build test -Dengine-mode=passthrough` must fail.
        return try alloc.dupe(u8, template);
    }

    const doc = try parse.parseDocument(alloc, template, d);
    var out = std.Io.Writer.Allocating.init(alloc);
    var interp = Interp{
        .alloc = alloc,
        .template = template,
        .diag = d,
        .out = &out.writer,
        .root = data,
        .max_output = max_output,
    };
    try interp.evalNodes(doc.nodes);
    return out.written();
}

const LoopFrame = struct {
    name: []const u8,
    items: []const std.json.Value,
    index: usize,
    offset: usize,
};

const Interp = struct {
    alloc: std.mem.Allocator,
    template: []const u8,
    diag: *diag.Diagnostic,
    out: *std.Io.Writer,
    root: std.json.Value,
    loops: std.ArrayList(LoopFrame) = .empty,
    max_output: usize,
    written: usize = 0,

    /// Charges `add` bytes against the output budget. Every byte reaches the
    /// output through here, so the cap trips at the moment it is crossed
    /// rather than when the allocator is exhausted.
    fn charge(self: *Interp, add: usize) Error!void {
        if (self.max_output == 0) return;
        const next = self.written + add;
        if (next > self.max_output) {
            const depth = self.loops.items.len;
            const offset = if (depth > 0) self.loops.items[depth - 1].offset else 0;
            return diag.fail(
                self.alloc,
                self.diag,
                .render,
                self.template,
                offset,
                "output exceeded the {d} byte limit at loop depth {d} after {d} bytes already written: nested loops multiply, so check the loop nesting (currently {d} deep)",
                .{ self.max_output, depth, self.written, depth },
            );
        }
        self.written = next;
    }

    fn put(self: *Interp, bytes: []const u8) Error!void {
        try self.charge(bytes.len);
        self.out.writeAll(bytes) catch return error.OutOfMemory;
    }

    fn putFmt(self: *Interp, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
        try self.put(text);
    }

    fn evalNodes(self: *Interp, nodes: []const parse.Node) Error!void {
        for (nodes) |node| {
            switch (node) {
                .text => |t| try self.put(t),
                .output => |pl| try self.evalOutput(pl),
                .ifelse => |chain| try self.evalIf(chain),
                .loop => |ln| try self.evalLoop(ln),
            }
        }
    }

    fn evalOutput(self: *Interp, pl: parse.Pipeline) Error!void {
        var value = try self.resolveExpr(pl.value);
        for (pl.filters) |call| {
            value = try filters.apply(self.alloc, self.diag, self.template, call, value, self.root);
        }
        try self.writeValue(value);
    }

    fn evalIf(self: *Interp, chain: parse.IfChain) Error!void {
        for (chain.branches) |branch| {
            if (branch.cond) |cond| {
                if (try self.evalCond(cond)) {
                    try self.evalNodes(branch.body);
                    return;
                }
            } else {
                try self.evalNodes(branch.body);
                return;
            }
        }
    }

    fn evalLoop(self: *Interp, ln: parse.LoopNode) Error!void {
        const list = try self.resolveExpr(ln.list);
        const arr = switch (list) {
            .array => |a| a,
            else => return diag.fail(
                self.alloc,
                self.diag,
                .render,
                self.template,
                ln.offset,
                "for-loop expects an array to iterate, but got {s}",
                .{valueTypeName(list)},
            ),
        };
        try self.loops.append(self.alloc, .{
            .name = ln.var_name,
            .items = arr.items,
            .index = 0,
            .offset = ln.offset,
        });
        defer _ = self.loops.pop();
        var i: usize = 0;
        while (i < arr.items.len) : (i += 1) {
            self.loops.items[self.loops.items.len - 1].index = i;
            try self.evalNodes(ln.body);
        }
    }

    fn evalCond(self: *Interp, cond: parse.Cond) Error!bool {
        return switch (cond) {
            .operand => |e| truthy(try self.resolveExpr(e)),
            .neg => |inner| !(try self.evalCond(inner.*)),
            .and_ => |ab| (try self.evalCond(ab.lhs.*)) and (try self.evalCond(ab.rhs.*)),
            .or_ => |ab| (try self.evalCond(ab.lhs.*)) or (try self.evalCond(ab.rhs.*)),
            .cmp => |c| self.evalCmp(c.op, c.lhs, c.rhs),
        };
    }

    fn evalCmp(self: *Interp, op: parse.CmpOp, lhs_expr: parse.Expr, rhs_expr: parse.Expr) Error!bool {
        const lhs = try self.resolveExpr(lhs_expr);
        const rhs = try self.resolveExpr(rhs_expr);
        return switch (op) {
            .eq => valueEq(lhs, rhs),
            .ne => !valueEq(lhs, rhs),
            .lt, .le, .gt, .ge => orderedCompare(op, lhs, rhs),
            .contains => containsCheck(lhs, rhs),
        };
    }

    fn resolveExpr(self: *Interp, expr: parse.Expr) Error!std.json.Value {
        return switch (expr) {
            .literal => |lit| literalValue(lit),
            .path => |p| self.resolvePath(p),
        };
    }

    fn resolvePath(self: *Interp, path: parse.Path) Error!std.json.Value {
        var current: std.json.Value = .{ .null = {} };
        var found = false;

        // Loop variables shadow the data root, innermost first.
        var frame_index = self.loops.items.len;
        while (frame_index > 0) {
            frame_index -= 1;
            const frame = &self.loops.items[frame_index];
            if (std.mem.eql(u8, path.root, frame.name)) {
                current = frame.items[frame.index];
                found = true;
                break;
            }
            if (std.mem.eql(u8, path.root, "loop")) {
                current = try self.loopObject(frame);
                found = true;
                break;
            }
        }
        if (!found) {
            switch (self.root) {
                .object => |obj| current = obj.get(path.root) orelse .{ .null = {} },
                else => current = .{ .null = {} },
            }
        }

        for (path.steps) |step| {
            current = switch (step) {
                .key => |k| switch (current) {
                    .object => |obj| obj.get(k) orelse .{ .null = {} },
                    else => .{ .null = {} },
                },
                .index => |idx| switch (current) {
                    .array => |arr| if (idx < arr.items.len) arr.items[@intCast(idx)] else .{ .null = {} },
                    else => .{ .null = {} },
                },
            };
        }
        return current;
    }

    fn loopObject(self: *Interp, frame: *const LoopFrame) Error!std.json.Value {
        var map: std.json.ObjectMap = .empty;
        try map.put(self.alloc, "index", .{ .integer = @intCast(frame.index + 1) });
        try map.put(self.alloc, "index0", .{ .integer = @intCast(frame.index) });
        try map.put(self.alloc, "first", .{ .bool = frame.index == 0 });
        try map.put(self.alloc, "last", .{ .bool = frame.index + 1 == frame.items.len });
        try map.put(self.alloc, "length", .{ .integer = @intCast(frame.items.len) });
        return .{ .object = map };
    }

    fn writeValue(self: *Interp, v: std.json.Value) Error!void {
        switch (v) {
            .null => {},
            .bool => |b| try self.put(if (b) "true" else "false"),
            .integer => |i| try self.putFmt("{d}", .{i}),
            .float => |f| try self.putFmt("{d}", .{f}),
            .number_string => |s| try self.put(s),
            .string => |s| try self.put(s),
            .array, .object => {
                // Buffer then `put`, so structured values are charged against
                // the output budget instead of writing straight past it.
                var buf: std.Io.Writer.Allocating = .init(self.alloc);
                std.json.Stringify.value(v, .{}, &buf.writer) catch return error.OutOfMemory;
                try self.put(buf.written());
            },
        }
    }
};

fn literalValue(lit: parse.Literal) std.json.Value {
    return switch (lit) {
        .string => |s| .{ .string = s },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .boolean => |b| .{ .bool = b },
        .null => .{ .null = {} },
    };
}

fn truthy(v: std.json.Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => |s| s.len > 0,
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => true,
    };
}

/// Guard on structural comparison. `std.json` parsing already bounds nesting,
/// but values built by the engine (loop objects) are not depth-checked, so this
/// keeps equality from becoming unbounded recursion.
const max_compare_depth: u32 = 128;

/// Equality over the whole value tree. Arrays and objects compare
/// structurally, so a value is always equal to itself and two objects are equal
/// regardless of key order. Used by `==`/`!=` and by `contains` when the
/// haystack is an array.
fn valueEq(a: std.json.Value, b: std.json.Value) bool {
    return valueEqDepth(a, b, 0);
}

fn valueEqDepth(a: std.json.Value, b: std.json.Value, depth: u32) bool {
    if (depth > max_compare_depth) return false;
    return switch (a) {
        .null => switch (b) {
            .null => true,
            else => false,
        },
        .bool => |x| switch (b) {
            .bool => |y| x == y,
            else => false,
        },
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| switch (b) {
            .number_string => |y| std.mem.eql(u8, x, y),
            .string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            .number_string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .array => |x| switch (b) {
            .array => |y| blk: {
                if (x.items.len != y.items.len) break :blk false;
                for (x.items, y.items) |xi, yi| {
                    if (!valueEqDepth(xi, yi, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |x| switch (b) {
            // Key order is not significant: look each key up in the other map
            // rather than walking both in step.
            .object => |y| blk: {
                if (x.count() != y.count()) break :blk false;
                var it = x.iterator();
                while (it.next()) |entry| {
                    const other = y.get(entry.key_ptr.*) orelse break :blk false;
                    if (!valueEqDepth(entry.value_ptr.*, other, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

/// Ordered comparisons work on two numbers or two strings; any other
/// combination is false (documented subset).
fn orderedCompare(op: parse.CmpOp, a: std.json.Value, b: std.json.Value) bool {
    const ord = compareOrdered(a, b) orelse return false;
    return switch (op) {
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
        else => unreachable,
    };
}

fn compareOrdered(a: std.json.Value, b: std.json.Value) ?std.math.Order {
    switch (a) {
        .integer => |x| switch (b) {
            .integer => |y| return std.math.order(x, y),
            .float => |y| return std.math.order(@as(f64, @floatFromInt(x)), y),
            else => return null,
        },
        .float => |x| switch (b) {
            .float => |y| return std.math.order(x, y),
            .integer => |y| return std.math.order(x, @as(f64, @floatFromInt(y))),
            else => return null,
        },
        .string => |x| switch (b) {
            .string => |y| return std.mem.order(u8, x, y),
            else => return null,
        },
        else => return null,
    }
}

fn containsCheck(haystack: std.json.Value, needle: std.json.Value) bool {
    switch (haystack) {
        .string => |h| switch (needle) {
            .string => |n| return std.mem.indexOf(u8, h, n) != null,
            .number_string => |n| return std.mem.indexOf(u8, h, n) != null,
            else => return false,
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (valueEq(item, needle)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn valueTypeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}
