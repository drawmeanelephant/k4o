//! Template engine: parse + evaluate into CommonMark (or Oliver-targeted
//! HTML passthrough).
//!
//! Output and all temporary values are allocated with `alloc`; callers
//! typically pass an arena allocator and free everything at once.
//!
//! Values flow through pipelines as `*const std.json.Value` handles: data
//! values are pointers into the parsed tree, produced values are arena
//! slots. Container identity (JS `===` semantics for `==`, `!=`,
//! `contains`) is pointer identity on those handles — two structurally
//! equal but separately parsed objects compare unequal, matching the
//! oracle.

const std = @import("std");
const build_options = @import("build_options");
const diag = @import("diag.zig");
const parse = @import("parse.zig");
const filters = @import("filters.zig");

pub const Error = error{ Template, OutOfMemory };

const mode = build_options.engine_mode;
const passthrough_mode = std.mem.eql(u8, mode, "passthrough");
/// `noeval`: tags emit their literal source instead of evaluating — a
/// red-verification mutant that must fail every test.
const noeval_mode = std.mem.eql(u8, mode, "noeval");
const default_format: filters.Format = if (std.mem.eql(u8, mode, "oliver")) .oliver else .markdown;
pub const Format = filters.Format;

/// Default ceiling on rendered output, in bytes.
///
/// Nested loops multiply: L nested loops over arrays of length N render N^L
/// times, so a short template over modest data can ask for gigabytes. This
/// bounds that with a clear diagnostic instead of letting the arena allocator
/// run out after minutes of work. Override with `renderWithLimit`, or from
/// the CLI with `--max-output`.
pub const default_max_output: usize = 256 * 1024 * 1024;

/// The oracle rejects data (and produced values) nested deeper than this —
/// `LIMIT_EXCEEDED: Template exceeded maxDepth`.
pub const max_value_depth: u32 = 100;

/// Renders `template` with `data` (a JSON object whose properties are the
/// variables) and returns the rendered bytes, allocated with `alloc`.
pub fn render(
    alloc: std.mem.Allocator,
    template: []const u8,
    data: std.json.Value,
    d: *diag.Diagnostic,
) Error![]const u8 {
    return renderFormatWithLimit(alloc, template, data, d, default_format, default_max_output);
}

/// As `render`, but caps the output at `max_output` bytes. Pass 0 for no cap.
pub fn renderWithLimit(
    alloc: std.mem.Allocator,
    template: []const u8,
    data: std.json.Value,
    d: *diag.Diagnostic,
    max_output: usize,
) Error![]const u8 {
    return renderFormatWithLimit(alloc, template, data, d, default_format, max_output);
}

/// Select an output format without changing the template or data semantics.
pub fn renderFormat(
    alloc: std.mem.Allocator,
    template: []const u8,
    data: std.json.Value,
    d: *diag.Diagnostic,
    format: Format,
) Error![]const u8 {
    return renderFormatWithLimit(alloc, template, data, d, format, default_max_output);
}

pub fn renderFormatWithLimit(
    alloc: std.mem.Allocator,
    template: []const u8,
    data: std.json.Value,
    d: *diag.Diagnostic,
    format: Format,
    max_output: usize,
) Error![]const u8 {
    if (passthrough_mode) {
        // Red-verification mutant: a goldbrick engine that returns the
        // template unchanged (no parsing, no validation, no filters).
        // `zig build test -Dengine-mode=passthrough` must fail.
        return try alloc.dupe(u8, template);
    }
    if (noeval_mode) {
        // Red-verification mutant: tags are never evaluated.
        return try alloc.dupe(u8, template);
    }

    const doc = try parse.parseDocument(alloc, template, d);
    var out = std.Io.Writer.Allocating.init(alloc);
    var interp = Interp{
        .alloc = alloc,
        .template = template,
        .diag = d,
        .out = &out,
        .root = data,
        .format = format,
        .max_output = max_output,
    };
    try interp.checkDepth(data, 1);
    try interp.evalNodes(doc.nodes);
    return out.written();
}

const Scope = std.StringArrayHashMapUnmanaged(*const std.json.Value);

const LoopFrame = struct {
    name: []const u8,
    /// `{var}_index` — the back-compat 0-based loop counter.
    index_name: []const u8,
    items: []const std.json.Value,
    index: usize,
    offset: usize,
    loop_obj: ?*std.json.Value = null,
    scope: Scope,
};

pub const Interp = struct {
    alloc: std.mem.Allocator,
    template: []const u8,
    diag: *diag.Diagnostic,
    out: *std.Io.Writer.Allocating,
    root: std.json.Value,
    format: Format,
    loops: std.ArrayList(LoopFrame) = .empty,
    globals: Scope = .empty,
    max_output: usize,
    written: usize = 0,
    /// When a standalone `{% for %}` opened the loop, the first emitted
    /// run of spaces/tabs is stripped — and if that run ends at a newline
    /// the newline goes with it.
    strip_leading: bool = false,

    pub fn failRender(
        self: *Interp,
        offset: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) error{Template} {
        return diag.fail(self.alloc, self.diag, .render, self.template, offset, fmt, args);
    }

    /// The oracle's LIMIT_EXCEEDED for values deeper than max_value_depth.
    fn checkDepth(self: *Interp, v: std.json.Value, depth: u32) Error!void {
        switch (v) {
            .array => |a| {
                if (depth > max_value_depth) return self.failRender(0, "value nested deeper than the {d}-level limit", .{max_value_depth});
                for (a.items) |item| try self.checkDepth(item, depth + 1);
            },
            .object => |o| {
                if (depth > max_value_depth) return self.failRender(0, "value nested deeper than the {d}-level limit", .{max_value_depth});
                for (o.values()) |item| try self.checkDepth(item, depth + 1);
            },
            else => {},
        }
    }

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

    fn put(self: *Interp, bytes_in: []const u8) Error!void {
        var bytes = bytes_in;
        if (self.strip_leading) {
            var n: usize = 0;
            while (n < bytes.len and (bytes[n] == ' ' or bytes[n] == '\t')) n += 1;
            if (n > 0) {
                self.strip_leading = false;
                if (n < bytes.len and bytes[n] == '\n') n += 1;
                bytes = bytes[n..];
                if (bytes.len == 0) return;
            }
        }
        try self.charge(bytes.len);
        self.out.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    /// Store a value in the arena and return its handle.
    pub fn make(self: *Interp, v: std.json.Value) error{OutOfMemory}!*const std.json.Value {
        const ptr = try self.alloc.create(std.json.Value);
        ptr.* = v;
        return ptr;
    }

    fn evalNodes(self: *Interp, nodes: []const parse.Node) Error!void {
        for (nodes) |node| {
            switch (node) {
                .text => |t| try self.put(t),
                .output => |pl| try self.evalOutput(pl),
                .ifelse => |chain| try self.evalIf(chain),
                .loop => |ln| try self.evalLoop(ln),
                .set => |sn| try self.evalSet(sn),
            }
        }
    }

    fn evalOutput(self: *Interp, chain: parse.Chain) Error!void {
        const value = try self.evalChain(chain, 0);
        try self.writeValue(value);
    }

    /// First truthy term wins and contributes its value — `a ?? b == c`
    /// is `a ?? (b == c)`, so a truthy `a` yields `a`, not a bool.
    /// Falls back to null when every term is falsy.
    fn boolValue(self: *Interp, b: bool) Error!*const std.json.Value {
        const v = try self.alloc.create(std.json.Value);
        v.* = .{ .bool = b };
        return v;
    }

    fn evalChain(self: *Interp, chain: parse.Chain, offset: usize) Error!*const std.json.Value {
        var depth: u32 = 0;
        for (chain.terms) |term| {
            depth = @max(depth, condDepth(term));
        }
        if (depth > max_eval_depth) {
            return diag.fail(
                self.alloc,
                self.diag,
                .render,
                self.template,
                offset,
                "condition expression is nested too deeply to evaluate (max {d} levels)",
                .{max_eval_depth},
            );
        }
        var last: ?*const std.json.Value = null;
        for (chain.terms) |term| {
            switch (term) {
                .operand => |e| {
                    const v = try self.evalExpr(e);
                    if (truthy(v.*)) return v;
                    last = v;
                },
                else => {
                    const b = try self.evalCond(term, offset);
                    const v = try self.boolValue(b);
                    if (b) return v;
                    last = v;
                },
            }
        }
        // No term was truthy — the chain falls back to its last term.
        return last orelse self.nullValue();
    }

    /// Conservative depth pre-scan for evalChain — the chain's own budget
    /// mirrors evalCondDepth's guard.
    fn condDepth(cond: parse.Cond) u32 {
        return switch (cond) {
            .operand, .cmp => 1,
            .neg => |inner| 1 + condDepth(inner.*),
            .and_ => |ab| 1 + @max(condDepth(ab.lhs.*), condDepth(ab.rhs.*)),
            .or_ => |ab| 1 + @max(condDepth(ab.lhs.*), condDepth(ab.rhs.*)),
        };
    }

    /// `{% set name = expr %}` — ordered assignment into the innermost
    /// scope (inside a loop that is the current iteration's scope; `{% if %}`
    /// does not open a scope).
    fn evalSet(self: *Interp, sn: parse.SetNode) Error!void {
        const value = try self.evalChain(sn.expr, sn.offset);
        const scope = self.currentScope();
        try scope.put(self.alloc, sn.name, value);
    }

    fn currentScope(self: *Interp) *Scope {
        if (self.loops.items.len > 0) {
            return &self.loops.items[self.loops.items.len - 1].scope;
        }
        return &self.globals;
    }

    fn evalIf(self: *Interp, chain: parse.IfChain) Error!void {
        for (chain.branches) |branch| {
            if (branch.cond) |cond_chain| {
                if (truthy((try self.evalChain(cond_chain, branch.offset)).*)) {
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
        const list = try self.evalExpr(ln.list);
        const arr = switch (list.*) {
            .array => |a| a,
            // Missing and null iterate as empty; anything else is an error.
            .null => return,
            else => return diag.fail(
                self.alloc,
                self.diag,
                .render,
                self.template,
                ln.offset,
                "for-loop expects an array to iterate, but got {s}",
                .{valueTypeName(list.*)},
            ),
        };
        const index_name = try std.fmt.allocPrint(self.alloc, "{s}_index", .{ln.var_name});
        const frame = LoopFrame{
            .name = ln.var_name,
            .index_name = index_name,
            .items = arr.items,
            .index = 0,
            .offset = ln.offset,
            .scope = .empty,
        };
        try self.loops.append(self.alloc, frame);
        defer _ = self.loops.pop();
        // Iterations separate with a newline, but the separator only
        // materializes when something precedes it — a loop whose bodies
        // emit nothing (`{% set %}`-only, empty arrays) emits nothing.
        const loop_start = self.out.written().len;
        var i: usize = 0;
        while (i < arr.items.len) : (i += 1) {
            self.loops.items[self.loops.items.len - 1].index = i;
            if (i > 0 and self.out.written().len > loop_start) try self.put("\n");
            // A standalone `{% for %}` strips the body's leading
            // spaces/tabs once — on the first emitted iteration. When the
            // run reaches a newline the newline goes with it.
            if (i == 0 and ln.strip_first) self.strip_leading = true;
            try self.evalNodes(ln.body);
            self.strip_leading = false;
        }
        // Iterations separate with a newline, and a loop trims its
        // trailing spaces/tabs once — the whitespace before `{% endfor
        // %}` lands between iterations, not after the last one.
        var end = self.out.written().len;
        while (end > 0) {
            const c = self.out.written()[end - 1];
            if (c != ' ' and c != '\t') break;
            end -= 1;
        }
        if (end != self.out.written().len) {
            self.written -= self.out.written().len - end;
            self.out.writer.end = end;
        }
    }

    fn evalCond(self: *Interp, cond: parse.Cond, offset: usize) Error!bool {
        return self.evalCondDepth(cond, offset, 0);
    }

    /// Guard on condition evaluation. The parser caps expression depth,
    /// but parenthesised chains multiply (32 paren levels each holding a
    /// max-length chain) and library callers can hand over any parsed AST,
    /// so the recursive walk keeps its own budget and fails with a template
    /// diagnostic instead of overflowing the stack.
    const max_eval_depth: u32 = 512;

    fn evalCondDepth(self: *Interp, cond: parse.Cond, offset: usize, depth: u32) Error!bool {
        if (depth > max_eval_depth) {
            return diag.fail(
                self.alloc,
                self.diag,
                .render,
                self.template,
                offset,
                "condition expression is nested too deeply to evaluate (max {d} levels)",
                .{max_eval_depth},
            );
        }
        return switch (cond) {
            .operand => |e| truthy((try self.evalExpr(e)).*),
            .neg => |inner| !(try self.evalCondDepth(inner.*, offset, depth + 1)),
            .and_ => |ab| (try self.evalCondDepth(ab.lhs.*, offset, depth + 1)) and (try self.evalCondDepth(ab.rhs.*, offset, depth + 1)),
            .or_ => |ab| (try self.evalCondDepth(ab.lhs.*, offset, depth + 1)) or (try self.evalCondDepth(ab.rhs.*, offset, depth + 1)),
            .cmp => |c| self.evalCmp(c.op, c.lhs, c.rhs),
        };
    }

    fn evalCmp(self: *Interp, op: parse.CmpOp, lhs_expr: parse.Expr, rhs_expr: parse.Expr) Error!bool {
        const lhs = try self.evalExpr(lhs_expr);
        const rhs = try self.evalExpr(rhs_expr);
        return switch (op) {
            .eq => self.valueEq(lhs, rhs),
            .ne => !(try self.valueEq(lhs, rhs)),
            .lt, .le, .gt, .ge => orderedCompare(op, lhs.*, rhs.*),
            .contains => self.containsCheck(lhs, rhs),
        };
    }

    /// `a ?? b` — first truthy term wins; filters bind before `??`.
    pub fn evalExpr(self: *Interp, expr: parse.Expr) Error!*const std.json.Value {
        if (expr.terms.len == 1) return self.evalPipeline(expr.terms[0]);
        for (expr.terms) |term| {
            const v = try self.evalPipeline(term);
            if (truthy(v.*)) return v;
        }
        // All terms falsy: the last one is the result (it is already falsy).
        return self.evalPipeline(expr.terms[expr.terms.len - 1]);
    }

    pub fn evalPipeline(self: *Interp, pl: parse.Pipeline) Error!*const std.json.Value {
        var value = try self.evalPrimary(pl.value);
        for (pl.filters) |call| {
            value = try filters.apply(self, call, value);
        }
        return value;
    }

    fn evalPrimary(self: *Interp, primary: parse.Primary) Error!*const std.json.Value {
        return switch (primary) {
            .literal => |lit| self.make(literalValue(lit)),
            .path => |p| self.resolvePath(p),
        };
    }

    /// A missing/null scalar: used where knap reads `undefined`.
    pub fn nullValue(self: *Interp) error{OutOfMemory}!*const std.json.Value {
        return self.make(.{ .null = {} });
    }

    /// The oracle's arrow sentinel — a missing `x => x.path` step renders
    /// as the literal string `"undefined"`. It is not a string primitive:
    /// it serializes quoted inside arrays but does not unwrap a singleton,
    /// matching the oracle's `["undefined"]`.
    fn undefinedValue(self: *Interp) error{OutOfMemory}!*const std.json.Value {
        return self.make(.{ .number_string = "undefined" });
    }

    fn resolvePath(self: *Interp, path: parse.Path) Error!*const std.json.Value {
        var current: ?*const std.json.Value = null;

        // Loop variables shadow scopes and the data root, innermost first.
        // Inside a loop `loop` is always the loop object and `{var}_index`
        // the 0-based counter — a variable with those names is unreachable.
        var frame_index = self.loops.items.len;
        while (frame_index > 0) {
            frame_index -= 1;
            const frame = &self.loops.items[frame_index];
            if (std.mem.eql(u8, path.root, "loop")) {
                current = try self.loopObject(frame);
                break;
            }
            if (std.mem.eql(u8, path.root, frame.name)) {
                current = &frame.items[frame.index];
                break;
            }
            if (std.mem.eql(u8, path.root, frame.index_name)) {
                current = try self.make(.{ .integer = @intCast(frame.index) });
                break;
            }
        }
        if (current == null) {
            var scope_index = self.loops.items.len;
            while (scope_index > 0) {
                scope_index -= 1;
                if (self.loops.items[scope_index].scope.get(path.root)) |v| {
                    current = v;
                    break;
                }
            }
        }
        if (current == null) {
            if (self.globals.get(path.root)) |v| current = v;
        }
        if (current == null) {
            switch (self.root) {
                .object => |obj| current = obj.getPtr(path.root),
                else => {},
            }
        }
        var value = current orelse return self.nullValue();

        for (path.steps) |step| {
            switch (step) {
                .key => |k| value = switch (value.*) {
                    .object => |obj| obj.getPtr(k) orelse return self.nullValue(),
                    .array => |arr| blk: {
                        // `xs["1"]` indexes the array like `xs[1]` does.
                        const idx = std.fmt.parseInt(u64, k, 10) catch return self.nullValue();
                        break :blk if (idx < arr.items.len) &arr.items[@intCast(idx)] else return self.nullValue();
                    },
                    else => return self.nullValue(),
                },
                .index => |idx| value = switch (value.*) {
                    .array => |arr| if (idx < arr.items.len) &arr.items[@intCast(idx)] else return self.nullValue(),
                    else => return self.nullValue(),
                },
                .expr => |pipe| {
                    const key = try self.evalPipeline(pipe.*);
                    value = switch (key.*) {
                        .string => |k| switch (value.*) {
                            .object => |obj| obj.getPtr(k) orelse return self.nullValue(),
                            .array => |arr| blk: {
                                // "0" indexes arrays like 0 does.
                                const idx = std.fmt.parseInt(u64, k, 10) catch return self.nullValue();
                                break :blk if (idx < arr.items.len) &arr.items[@intCast(idx)] else return self.nullValue();
                            },
                            else => return self.nullValue(),
                        },
                        .integer => |idx| switch (value.*) {
                            .array => |arr| if (idx >= 0 and idx < arr.items.len) &arr.items[@intCast(idx)] else return self.nullValue(),
                            else => return self.nullValue(),
                        },
                        .float => |f| switch (value.*) {
                            .array => |arr| blk: {
                                if (f < 0 or f != @floor(f) or f >= @as(f64, @floatFromInt(arr.items.len))) return self.nullValue();
                                break :blk &arr.items[@intFromFloat(f)];
                            },
                            else => return self.nullValue(),
                        },
                        else => return self.nullValue(),
                    };
                },
            }
        }
        return value;
    }

    /// Evaluate an arrow body against one mapped item — `x => x.a.b`,
    /// `x => ({k: x.v})`, `x => "pre/${x}"`, `x => 42`. The arrow's own
    /// variable resolves against the item; other roots fall through to
    /// normal scope resolution.
    pub fn evalArrow(self: *Interp, arrow: parse.Arrow, item: *const std.json.Value) Error!*const std.json.Value {
        return self.evalArrowBody(arrow.body, arrow.var_name, item);
    }

    fn evalArrowBody(self: *Interp, body: parse.ArrowBody, var_name: []const u8, item: *const std.json.Value) Error!*const std.json.Value {
        return switch (body) {
            .path => |p| self.resolveArrowPath(p, var_name, item),
            .literal => |lit| self.make(literalValue(lit)),
            .object => |fields| self.evalArrowObject(fields, var_name, item),
            .interp => |parts| self.evalArrowInterp(parts, var_name, item),
        };
    }

    fn evalArrowObject(self: *Interp, fields: []const parse.ArrowField, var_name: []const u8, item: *const std.json.Value) Error!*const std.json.Value {
        const v = try self.alloc.create(std.json.Value);
        v.* = .{ .object = .empty };
        for (fields) |f| {
            const field_v = switch (f.value) {
                .path => |p| try self.resolveArrowPath(p, var_name, item),
                .literal => |lit| try self.make(literalValue(lit)),
                .interp => |parts| try self.evalArrowInterp(parts, var_name, item),
            };
            try v.object.put(self.alloc, f.name, field_v.*);
        }
        return v;
    }

    fn evalArrowInterp(self: *Interp, parts: []const parse.InterpPart, var_name: []const u8, item: *const std.json.Value) Error!*const std.json.Value {
        var out = std.ArrayList(u8).empty;
        for (parts) |part| {
            switch (part) {
                .text => |t| try out.appendSlice(self.alloc, t),
                .path => |p| {
                    // `${x}` substitutes the item; `${x.name}` stays
                    // literal — arrow strings interpolate only the bare
                    // variable (the oracle emits `${x.name}` verbatim).
                    if (std.mem.eql(u8, p.root, var_name) and p.steps.len == 0) {
                        try out.appendSlice(self.alloc, try filters.jsToString(self.alloc, item));
                    } else {
                        try out.appendSlice(self.alloc, "${");
                        try out.appendSlice(self.alloc, try self.pathText(p));
                        try out.appendSlice(self.alloc, "}");
                    }
                },
            }
        }
        return self.make(.{ .string = out.items });
    }

    /// A path rooted at the arrow variable walks the item; anything else
    /// resolves through the normal scope chain. `x` alone is the
    /// variable's name text (`x => x` renders `"x"` in the oracle), and a
    /// missing step is the literal `"undefined"`, not null.
    fn resolveArrowPath(self: *Interp, path: parse.Path, var_name: []const u8, item: *const std.json.Value) Error!*const std.json.Value {
        if (!std.mem.eql(u8, path.root, var_name)) return self.resolvePath(path);
        if (path.steps.len == 0) return self.make(.{ .string = var_name });
        var value = item;
        for (path.steps) |step| {
            value = switch (step) {
                .key => |k| switch (value.*) {
                    .object => |obj| obj.getPtr(k) orelse return self.undefinedValue(),
                    else => return self.undefinedValue(),
                },
                .index => |idx| switch (value.*) {
                    .array => |arr| if (idx < arr.items.len) &arr.items[@intCast(idx)] else return self.undefinedValue(),
                    else => return self.undefinedValue(),
                },
                .expr => |pipe| blk: {
                    const key = try self.evalPipeline(pipe.*);
                    break :blk switch (key.*) {
                        .string => |k| switch (value.*) {
                            .object => |obj| obj.getPtr(k) orelse return self.undefinedValue(),
                            .array => |arr| inner: {
                                const idx = std.fmt.parseInt(u64, k, 10) catch return self.undefinedValue();
                                break :inner if (idx < arr.items.len) &arr.items[@intCast(idx)] else return self.undefinedValue();
                            },
                            else => return self.undefinedValue(),
                        },
                        .integer => |idx| switch (value.*) {
                            .array => |arr| if (idx >= 0 and idx < arr.items.len) &arr.items[@intCast(idx)] else return self.undefinedValue(),
                            else => return self.undefinedValue(),
                        },
                        else => return self.nullValue(),
                    };
                },
            };
        }
        return value;
    }

    fn loopObject(self: *Interp, frame: *LoopFrame) Error!*const std.json.Value {
        // One object per frame keeps `loop == loop` identity; the
        // index-dependent fields refresh each iteration.
        const v = frame.loop_obj orelse blk: {
            const ptr = try self.alloc.create(std.json.Value);
            ptr.* = .{ .object = .empty };
            frame.loop_obj = ptr;
            break :blk ptr;
        };
        var map = &v.object;
        try map.put(self.alloc, "index", .{ .integer = @intCast(frame.index + 1) });
        try map.put(self.alloc, "index0", .{ .integer = @intCast(frame.index) });
        try map.put(self.alloc, "first", .{ .bool = frame.index == 0 });
        try map.put(self.alloc, "last", .{ .bool = frame.index + 1 == frame.items.len });
        try map.put(self.alloc, "length", .{ .integer = @intCast(frame.items.len) });
        return v;
    }

    /// Evaluate a filter parameter to a value. A bare root word that fails
    /// to resolve becomes its own text (`link:url` -> "url" when `url` is
    /// not in the data); quoted strings and other literals stay literal.
    pub fn evalParam(self: *Interp, expr: *const parse.Expr) Error!*const std.json.Value {
        if (expr.terms.len == 1) {
            const term = expr.terms[0];
            switch (term.value) {
                .path => |p| {
                    const v = try self.resolvePath(p);
                    if (v.* == .null) {
                        return self.make(.{ .string = try self.pathText(p) });
                    }
                    return v;
                },
                else => {},
            }
        }
        return self.evalExpr(expr.*);
    }

    fn pathText(self: *Interp, p: parse.Path) Error![]const u8 {
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(self.alloc, p.root);
        for (p.steps) |step| {
            switch (step) {
                .key => |k| {
                    try buf.append(self.alloc, '.');
                    try buf.appendSlice(self.alloc, k);
                },
                .index => |idx| {
                    const t = try std.fmt.allocPrint(self.alloc, "[{d}]", .{idx});
                    try buf.appendSlice(self.alloc, t);
                },
                .expr => try buf.appendSlice(self.alloc, "[]"),
            }
        }
        return buf.toOwnedSlice(self.alloc);
    }

    /// Write a value at the end of a `{{ }}` pipeline.
    ///
    /// Scalars print JavaScript-style; a single-element array holding a
    /// primitive (string, number, boolean — not null) unwraps to its
    /// element (`{{ ["a"] }}` renders `a`); other containers serialize as
    /// compact JSON.
    fn writeValue(self: *Interp, v: *const std.json.Value) Error!void {
        switch (v.*) {
            .null => {},
            .bool => |b| try self.put(if (b) "true" else "false"),
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return error.OutOfMemory;
                try self.put(text);
            },
            .float => |f| try self.put(try jsFloat(self.alloc, f)),
            .number_string => |s| {
                const f = std.fmt.parseFloat(f64, s) catch {
                    try self.put(s);
                    return;
                };
                try self.put(try jsFloat(self.alloc, f));
            },
            .string => |s| try self.put(s),
            .array => |arr| {
                if (arr.items.len == 1) {
                    const elem = arr.items[0];
                    const is_undefined = elem == .number_string and
                        std.mem.eql(u8, elem.number_string, "undefined");
                    switch (elem) {
                        // The undefined sentinel stays wrapped — `[undefined]`
                        // renders `["undefined"]`, not `undefined`.
                        .bool, .integer, .float, .string => {
                            const single = try self.make(elem);
                            return self.writeValue(single);
                        },
                        .number_string => if (!is_undefined) {
                            const single = try self.make(elem);
                            return self.writeValue(single);
                        },
                        else => {},
                    }
                }
                var buf: std.Io.Writer.Allocating = .init(self.alloc);
                try self.jsStringify(v, &buf);
                try self.put(buf.written());
            },
            .object => {
                var buf: std.Io.Writer.Allocating = .init(self.alloc);
                try self.jsStringify(v, &buf);
                try self.put(buf.written());
            },
        }
    }

    /// Compact JSON.stringify: JS number printing, JS string escaping.
    /// Bounded at max_value_depth like the oracle's serializer.
    pub fn jsStringify(self: *Interp, v: *const std.json.Value, out: *std.Io.Writer.Allocating) Error!void {
        try self.jsStringifyDepth(v, out, 0);
    }

    fn jsStringifyDepth(self: *Interp, v: *const std.json.Value, out: *std.Io.Writer.Allocating, depth: u32) Error!void {
        if (depth > max_value_depth) {
            return self.failRender(0, "value nested deeper than the {d}-level limit", .{max_value_depth});
        }
        const w = &out.writer;
        switch (v.*) {
            .null => w.writeAll("null") catch return error.OutOfMemory,
            .bool => |b| w.writeAll(if (b) "true" else "false") catch return error.OutOfMemory,
            .integer => |i| w.print("{d}", .{i}) catch return error.OutOfMemory,
            .float => |f| w.writeAll(try jsFloat(self.alloc, f)) catch return error.OutOfMemory,
            .number_string => |s| {
                if (std.mem.eql(u8, s, "undefined")) {
                    try jsWriteString(w, s);
                    return;
                }
                const f = std.fmt.parseFloat(f64, s) catch 0;
                w.writeAll(try jsFloat(self.alloc, f)) catch return error.OutOfMemory;
            },
            .string => |s| try jsWriteString(w, s),
            .array => |arr| {
                w.writeByte('[') catch return error.OutOfMemory;
                for (arr.items, 0..) |*item, i| {
                    if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
                    try self.jsStringifyDepth(item, out, depth + 1);
                }
                w.writeByte(']') catch return error.OutOfMemory;
            },
            .object => |obj| {
                w.writeByte('{') catch return error.OutOfMemory;
                const keys = try jsObjectKeys(self.alloc, obj);
                for (keys, 0..) |key, i| {
                    if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
                    try jsWriteString(w, key);
                    w.writeByte(':') catch return error.OutOfMemory;
                    try self.jsStringifyDepth(obj.getPtr(key).?, out, depth + 1);
                }
                w.writeByte('}') catch return error.OutOfMemory;
            },
        }
    }

    /// JS `===` except numbers compare by value. Containers compare by
    /// identity — the Value node address — so `a == b` is true only when
    /// both sides name the same object, matching the oracle.
    fn valueEq(self: *Interp, a: *const std.json.Value, b: *const std.json.Value) Error!bool {
        _ = self;
        return switch (a.*) {
            .array, .object => a == b,
            .null => b.* == .null,
            .bool => |x| switch (b.*) {
                .bool => |y| x == y,
                else => false,
            },
            .integer => |x| switch (b.*) {
                .integer => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            },
            .float => |x| switch (b.*) {
                .float => |y| x == y,
                .integer => |y| x == @as(f64, @floatFromInt(y)),
                else => false,
            },
            .number_string => |x| switch (b.*) {
                .number_string, .string => |y| std.mem.eql(u8, x, y),
                else => false,
            },
            .string => |x| switch (b.*) {
                .string, .number_string => |y| std.mem.eql(u8, x, y),
                else => false,
            },
        };
    }

    fn containsCheck(self: *Interp, haystack: *const std.json.Value, needle: *const std.json.Value) Error!bool {
        switch (haystack.*) {
            .string => |h| switch (needle.*) {
                .string => |n| return std.mem.indexOf(u8, h, n) != null,
                .number_string => |n| return std.mem.indexOf(u8, h, n) != null,
                else => return false,
            },
            .array => |arr| {
                for (arr.items) |*item| {
                    switch (item.*) {
                        // SameValueZero: primitives by value, containers
                        // by identity (Value node address).
                        .array, .object => {
                            if (item == needle) return true;
                        },
                        else => {
                            if (try self.valueEq(item, needle)) return true;
                        },
                    }
                }
                return false;
            },
            else => return false,
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

/// JS property order: canonical array-index keys ("0","2","10") sort
/// numerically first, all other keys keep insertion order. `["0"]` counts
/// (index 0); `"01"` and `"-1"` are plain string keys.
pub fn jsObjectKeys(alloc: std.mem.Allocator, obj: std.json.ObjectMap) error{OutOfMemory}!([]const []const u8) {
    const IndexKey = struct {
        idx: u64,
        key: []const u8,
    };
    var idx_keys = std.ArrayList(IndexKey).empty;
    var keys = try alloc.alloc([]const u8, obj.count());
    var str_i: usize = 0;
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (indexKeyNum(k)) |n| {
            try idx_keys.append(alloc, .{ .idx = n, .key = k });
        } else {
            keys[str_i] = k;
            str_i += 1;
        }
    }
    if (idx_keys.items.len == 0) return keys[0..str_i];
    std.mem.sort(IndexKey, idx_keys.items, {}, struct {
        fn lt(_: void, a: IndexKey, b: IndexKey) bool {
            return a.idx < b.idx;
        }
    }.lt);
    const ordered = try alloc.alloc([]const u8, obj.count());
    for (idx_keys.items, 0..) |ik, i| ordered[i] = ik.key;
    for (keys[0..str_i], 0..) |k, i| ordered[idx_keys.items.len + i] = k;
    return ordered;
}

/// A canonical array-index key — `"0"`, `"2"`, `"10"` — parses cleanly,
/// has no leading zero (except `"0"` itself), and stays below 2^32-1.
fn indexKeyNum(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 10) return null;
    if (s.len > 1 and s[0] == '0') return null;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    if (n >= 4294967295) return null;
    return n;
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

/// JS Number.prototype.toString for a finite or infinite f64: shortest
/// round-trip digits, decimal notation for exponents in [-6, 20], else
/// `d[.ddd]e±E`.
pub fn jsFloat(alloc: std.mem.Allocator, f: f64) error{OutOfMemory}![]const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f > 0) "Infinity" else "-Infinity";
    if (f == 0) return "0"; // covers -0

    // Shortest round-trip: Zig's float formatting is Ryu-style shortest,
    // so format the digits in scientific form and re-emit per JS rules.
    var sci: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&sci, "{e}", .{f}) catch return error.OutOfMemory;
    // text looks like `-d.ddde±XX` or `de±X`.
    const epos = std.mem.indexOfAny(u8, text, "eE") orelse return alloc.dupe(u8, text);
    const mantissa = text[0..epos];
    const exp = std.fmt.parseInt(i32, text[epos + 1 ..], 10) catch return error.OutOfMemory;

    var digits: [32]u8 = undefined;
    var nd: usize = 0;
    for (mantissa) |c| {
        if (c >= '0' and c <= '9') {
            digits[nd] = c;
            nd += 1;
        }
    }
    const digit_count = nd;

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    if (exp >= -6 and exp <= 20) {
        if (f < 0) try buf.append(alloc, '-');
        if (exp >= 0) {
            const e: usize = @intCast(exp);
            if (digit_count > e + 1) {
                try buf.appendSlice(alloc, digits[0 .. e + 1]);
                try buf.append(alloc, '.');
                try buf.appendSlice(alloc, digits[e + 1 .. digit_count]);
            } else {
                try buf.appendSlice(alloc, digits[0..digit_count]);
                var i: usize = digit_count;
                while (i < e + 1) : (i += 1) try buf.append(alloc, '0');
            }
        } else {
            try buf.appendSlice(alloc, "0.");
            var i: i32 = -exp - 1;
            while (i > 0) : (i -= 1) try buf.append(alloc, '0');
            try buf.appendSlice(alloc, digits[0..digit_count]);
        }
    } else {
        if (f < 0) try buf.append(alloc, '-');
        try buf.append(alloc, digits[0]);
        if (digit_count > 1) {
            try buf.append(alloc, '.');
            try buf.appendSlice(alloc, digits[1..digit_count]);
        }
        try buf.append(alloc, 'e');
        if (exp >= 0) try buf.append(alloc, '+');
        const etext = try std.fmt.allocPrint(alloc, "{d}", .{exp});
        try buf.appendSlice(alloc, etext);
    }
    return buf.toOwnedSlice(alloc);
}

/// JSON string escaping per JSON.stringify: `"` and `\` escaped, control
/// characters use the short escapes or `\u00XX`.
fn jsWriteString(w: *std.Io.Writer, s: []const u8) error{OutOfMemory}!void {
    w.writeByte('"') catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => w.writeAll("\\\"") catch return error.OutOfMemory,
            '\\' => w.writeAll("\\\\") catch return error.OutOfMemory,
            '\n' => w.writeAll("\\n") catch return error.OutOfMemory,
            '\r' => w.writeAll("\\r") catch return error.OutOfMemory,
            '\t' => w.writeAll("\\t") catch return error.OutOfMemory,
            0x08 => w.writeAll("\\b") catch return error.OutOfMemory,
            0x0C => w.writeAll("\\f") catch return error.OutOfMemory,
            else => {
                if (c < 0x20) {
                    w.print("\\u{x:0>4}", .{c}) catch return error.OutOfMemory;
                } else {
                    w.writeByte(c) catch return error.OutOfMemory;
                }
            },
        }
    }
    w.writeByte('"') catch return error.OutOfMemory;
}

/// Ordered comparisons work on two numbers or two strings; any other
/// combination is false.
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
    const an = numberOf(a) orelse {
        if (a == .string and b == .string) {
            return std.mem.order(u8, a.string, b.string);
        }
        return null;
    };
    const bn = numberOf(b) orelse return null;
    return std.math.order(an, bn);
}

fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
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
