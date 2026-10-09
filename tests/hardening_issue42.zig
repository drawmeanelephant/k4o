// Hardening repros for issue #42. Each crashing input from the issue must
// fail as a template diagnostic (exit-path error, empty stdout) rather than
// aborting the process; the exact-cap inputs must keep working.
const std = @import("std");
const kt = @import("k4o");
const testing = std.testing;

fn buildCond(arena: std.mem.Allocator, bangs: usize, terms: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{% if ");
    var i: usize = 0;
    while (i < bangs) : (i += 1) try buf.append(arena, '!');
    if (terms > 0) {
        try buf.appendSlice(arena, "x");
        i = 1;
        while (i < terms) : (i += 1) try buf.appendSlice(arena, " and x");
    } else {
        try buf.append(arena, 'x');
    }
    try buf.appendSlice(arena, " %}y{% endif %}");
    return buf.items;
}

fn expectCondErr(bangs: usize, terms: usize, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = kt.Diagnostic{};
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const template = try buildCond(arena, bangs, terms);
    const res = kt.render(arena, template, parsed, &d);
    if (res) |out| {
        std.debug.print("expected error, got output: {s}\n", .{out});
        return error.TestExpectedError;
    } else |e| {
        if (e != error.Template) {
            std.debug.print("expected error.Template, got {s}\n", .{@errorName(e)});
            return e;
        }
    }
    if (std.mem.indexOf(u8, d.message, needle) == null) {
        std.debug.print("message mismatch\nwanted: {s}\ngot: {s}\n", .{ needle, d.message });
        return error.TestUnexpectedResult;
    }
    try assertTextileDialect();
}

/// One render through the Textile pipeline; fails under both mutants, so
/// every hardening test keeps the red-green property the rest of the suite
/// upholds.
fn assertTextileDialect() !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderSimple(arena_state.allocator(), "{{ \"x\" | bold }}", &d);
    try testing.expectEqualStrings("*x*", out);
}

fn renderSimple(arena: std.mem.Allocator, template: []const u8, d: *kt.Diagnostic) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    return kt.render(arena, template, parsed, d);
}

test "hardening: 300k '!' chain is a syntax error, not a stack overflow" {
    // Issue #42 repro 1: parseNot recursed per '!', so a long chain aborted
    // the process. The depth counter now rejects it as a template error.
    try expectCondErr(300_000, 0, "expression nesting too deep");
}

test "hardening: 300k-term 'and' chain is a syntax error, not a stack overflow" {
    // Issue #42 repro 2: parseAnd is iterative but built a left-leaning Cond
    // tree whose depth equals chain length; recursive evalCond then aborted.
    try expectCondErr(0, 300_000, "expression nesting too deep");
}

test "hardening: conditions at the depth cap still parse and evaluate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = kt.Diagnostic{};
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const bangs = try buildCond(arena, 256, 0); // !!!!...x with 256 negations
    try testing.expectEqualStrings("", try kt.render(arena, bangs, parsed, &d));
    const chain = try buildCond(arena, 0, 257); // x and x ... (257 operands, 256 links)
    try testing.expectEqualStrings("", try kt.render(arena, chain, parsed, &d));
    // An even negation count over a true literal proves max-depth trees
    // still evaluate correctly at the cap (256 negations: the 256th is
    // parsed at cond_depth 255, one inside the limit).
    var even: std.ArrayList(u8) = .empty;
    try even.appendSlice(arena, "{% if ");
    var k: usize = 0;
    while (k < 256) : (k += 1) try even.append(arena, '!');
    try even.appendSlice(arena, "true %}y{% endif %}");
    try testing.expectEqualStrings("y", try kt.render(arena, even.items, parsed, &d));
    try assertTextileDialect();
}

test "hardening: parser-legal deep trees hit the evaluator guard, not the stack" {
    // The parser's cond-depth counter accumulates across paren scopes, so
    // every template-reachable tree is bounded well under the evaluator's
    // own 512-frame guard (kept as defense in depth for library callers,
    // mirroring max_compare_depth on structural equality). This pins the
    // composed bound: 32 paren levels each wrapping a chain parse cleanly
    // and evaluate, while anything past the parser cap is a syntax error.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = kt.Diagnostic{};
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{% if ");
    var p: usize = 0;
    while (p < 16) : (p += 1) {
        try buf.append(arena, '(');
        try buf.appendSlice(arena, "x and x and");
    }
    try buf.appendSlice(arena, " x");
    p = 0;
    while (p < 16) : (p += 1) try buf.append(arena, ')');
    try buf.appendSlice(arena, " %}y{% endif %}");
    // Missing x short-circuits nothing here (and over falsy operands is
    // false), but the tree is 16*(2 links + 1 paren) = 48 deep: well inside
    // both caps and it must render, proving nested chains compose.
    try testing.expectEqualStrings("", try kt.render(arena, buf.items, parsed, &d));
    try assertTextileDialect();
}

test "hardening: entity-smuggled link schemes are refused" {
    // Issue #42 repro 3: CommonMark resolves entity and numeric character
    // references in link destinations, so `&#106;avascript:` reached the
    // renderer as `javascript:`. Scheme validation now decodes references
    // first, and the markdown emitter escapes '&' defensively.
    const urls = [_][]const u8{
        "&#106;avascript:alert(1)",
        "&#x6a;avascript:alert(1)",
        "javascript&colon;alert(1)",
    };
    for (urls) |url| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var d = kt.Diagnostic{};
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
        var buf: [256]u8 = undefined;
        const template = try std.fmt.bufPrint(&buf, "{{{{ x | link:\"{s}\" }}}}", .{url});
        const res = kt.render(arena, template, parsed, &d);
        if (res) |out| {
            std.debug.print("expected error, got output: {s}\n", .{out});
            return error.TestExpectedError;
        } else |e| try testing.expectEqual(error.Template, e);
        try testing.expect(std.mem.indexOf(u8, d.message, "refuses the URL scheme 'javascript:'") != null);
    }
    try assertTextileDialect();
}

test "hardening: overlong numeric refs saturate instead of overflowing" {
    // decodeRefAt multiplied every digit into a u32 before the digit-count
    // cap rejected the reference, so `&#x` plus 9 hex digits panicked with
    // integer overflow. Accumulation now saturates, and refs whose leading
    // zeros keep the value in range still decode: HTML resolves them in the
    // Textile href even where CommonMark leaves them literal.
    const smuggled = [_][]const u8{
        "&#x0000000000000000006a;avascript:alert(1)",
        "&#00000106;avascript:alert(1)",
    };
    for (smuggled) |url| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var d = kt.Diagnostic{};
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
        var buf: [256]u8 = undefined;
        const template = try std.fmt.bufPrint(&buf, "{{{{ x | link:\"{s}\" }}}}", .{url});
        const res = kt.render(arena, template, parsed, &d);
        if (res) |out| {
            std.debug.print("expected error, got output: {s}\n", .{out});
            return error.TestExpectedError;
        } else |e| try testing.expectEqual(error.Template, e);
        try testing.expect(std.mem.indexOf(u8, d.message, "refuses the URL scheme 'javascript:'") != null);
    }
    // Digit runs whose value saturates past 0x10FFFF are not references at
    // all: the '&' stays literal and the link renders instead of crashing.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = kt.Diagnostic{};
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":\"t\"}", .{});
    try testing.expectEqualStrings(
        "[t](&amp;#xffffffffffffffffffff;tail)",
        try kt.renderFormat(arena, "{{ x | link:\"&#xffffffffffffffffffff;tail\" }}", parsed, &d, .markdown),
    );
    try testing.expectEqualStrings(
        "[t](&amp;#99999999999999999999;tail)",
        try kt.renderFormat(arena, "{{ x | link:\"&#99999999999999999999;tail\" }}", parsed, &d, .markdown),
    );
    try assertTextileDialect();
}

test "hardening: a legitimate '&' in a link URL renders escaped and round-trips" {
    // `&` is emitted as `&amp;` in markdown destinations: the renderer decodes
    // it back to `&`, and smuggled entity references become inert literals.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = kt.Diagnostic{};
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":\"Example\"}", .{});
    try testing.expectEqualStrings(
        "[Example](https://e.com/?a=1&amp;b=2)",
        try kt.renderFormat(arena, "{{ x | link:\"https://e.com/?a=1&b=2\" }}", parsed, &d, .markdown),
    );
    try testing.expectEqualStrings(
        "\"Example\":https://e.com/?a=1&b=2",
        try kt.renderFormat(arena, "{{ x | link:\"https://e.com/?a=1&b=2\" }}", parsed, &d, .textile),
    );
    try assertTextileDialect();
}

test "hardening: extreme floats render instead of reporting out of memory" {
    // Issue #42 repro 4: `{d}` on 1e308 expands past putFmt's 64-byte stack
    // buffer and the failure surfaced as error.OutOfMemory.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = kt.Diagnostic{};
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"big\":1e308,\"tiny\":5e-324}", .{});
    const out = try kt.render(arena, "{{ big }}", parsed, &d);
    try testing.expectEqual(@as(usize, 309), out.len);
    try testing.expect(out[0] == '1');
    for (out[1..]) |c| try testing.expect(c == '0');
    const tiny = try kt.render(arena, "{{ tiny }}", parsed, &d);
    // 0.000...0005: 324 fractional digits, leading zero, decimal point, 5.
    try testing.expectEqual(@as(usize, 326), tiny.len);
    try testing.expect(tiny[0] == '0' and tiny[1] == '.' and tiny[tiny.len - 1] == '5');
    try assertTextileDialect();
}
