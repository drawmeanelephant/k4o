// Deep-value guards (engine side of dogbed#23 and dogbed#24, k4o issues
// #47/#48). Interpolating a value nested past std.json.Stringify's fixed
// 256-level stack fails as a template diagnostic — never a panic or an
// unchecked write — and structural comparison walks the value iteratively,
// so a value always equals itself at any depth the parser accepts.
const std = @import("std");
const kt = @import("k4o");
const testing = std.testing;

/// {"a": [[[...1...]]]} with `depth` arrays under "a" (open/close alternate).
fn deepArrayJson(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"a\":");
    for (0..depth) |_| try buf.append(arena, '[');
    try buf.append(arena, '1');
    for (0..depth) |_| try buf.append(arena, ']');
    try buf.append(arena, '}');
    return buf.items;
}

/// {"a": {"k": {"k": ...1...}}} with `depth` objects under "a".
fn deepObjectJson(arena: std.mem.Allocator, depth: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"a\":");
    for (0..depth) |_| try buf.appendSlice(arena, "{\"k\":");
    try buf.append(arena, '1');
    for (0..depth) |_| try buf.append(arena, '}');
    try buf.append(arena, '}');
    return buf.items;
}

fn renderJson(arena: std.mem.Allocator, template: []const u8, data_json: []const u8, d: *kt.Diagnostic) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data_json, .{});
    return kt.render(arena, template, parsed, d);
}

fn expectOk(template: []const u8, data_json: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderJson(arena_state.allocator(), template, data_json, &d);
    testing.expectEqualStrings(expected, out) catch |e| {
        std.debug.print("render mismatch\n--- expected ---\n{s}\n--- actual ---\n{s}\n---\n", .{ expected, out });
        return e;
    };
    try assertTextileDialect();
}

fn expectErr(template: []const u8, data_json: []const u8, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const res = renderJson(arena_state.allocator(), template, data_json, &d);
    if (res) |out| {
        std.debug.print("expected error, got output:\n{s}\n", .{out});
        return error.TestExpectedError;
    } else |e| {
        if (e != error.Template) {
            std.debug.print("expected error.Template, got {s}\n", .{@errorName(e)});
            return e;
        }
    }
    if (std.mem.indexOf(u8, d.message, needle) == null) {
        std.debug.print("message mismatch\n--- wanted (substring) ---\n{s}\n--- got ---\n{s}\n", .{ needle, d.message });
        return error.TestUnexpectedResult;
    }
    try assertTextileDialect();
}

/// One render through the Textile pipeline; fails under both mutants, so
/// every deep-nesting test keeps the red-green property the suite upholds.
fn assertTextileDialect() !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderJson(arena_state.allocator(), "{{ \"x\" | bold }}", "{}", &d);
    try testing.expectEqualStrings("*x*", out);
}

test "deep value interpolates at the serialize cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Exactly 256 nested arrays is the deepest value Stringify can take.
    const data = try deepArrayJson(arena, 256);
    var expected: std.ArrayList(u8) = .empty;
    for (0..256) |_| try expected.append(arena, '[');
    try expected.append(arena, '1');
    for (0..256) |_| try expected.append(arena, ']');
    var d = kt.Diagnostic{};
    const out = try renderJson(arena, "{{ a }}", data, &d);
    try testing.expectEqualStrings(expected.items, out);
    try assertTextileDialect();
}

test "deep value interpolation is a diagnostic past the serialize cap" {
    // 257 nested arrays used to panic inside Stringify's fixed bit stack.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectErr("{{ a }}", try deepArrayJson(arena, 257), "value nested too deeply to serialize");
    try expectErr("{{ a }}", try deepObjectJson(arena, 257), "value nested too deeply to serialize");
}

test "deep value interpolation inside a loop body fails cleanly" {
    // writeValue is the single choke point, so the guard holds under {% for %}.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"xs\":[");
    const deep = try deepArrayJson(arena, 257);
    try buf.appendSlice(arena, deep[5 .. deep.len - 1]); // the inner array alone
    try buf.appendSlice(arena, "]}");
    try expectErr("{% for x in xs %}{{ x }}{% endfor %}", buf.items, "value nested too deeply to serialize");
}

test "a value equals itself at any depth" {
    // Issue #47's acceptance threshold: the old recursion budget mis-answered
    // past 128 levels. The iterative walk has no ceiling the parser can
    // exceed — 129 was the first wrong depth, 200 is the reported repro,
    // and 100k sits orders of magnitude past any reasonable input.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]usize{ 128, 129, 200 }) |depth| {
        const data = try deepArrayJson(arena, depth);
        try expectOk("{% if a == a %}same{% else %}diff{% endif %}", data, "same");
        try expectOk("{% if a != a %}diff{% else %}same{% endif %}", data, "same");
    }
    try expectOk("{% if a == a %}same{% else %}diff{% endif %}", try deepArrayJson(arena, 100_000), "same");
    try expectOk("{% if a == a %}same{% else %}diff{% endif %}", try deepObjectJson(arena, 200), "same");
    // The issue's `contains` repro: a's only member is a[0].
    try expectOk(
        "{% if a contains a[0] %}member{% else %}not-member{% endif %}",
        try deepArrayJson(arena, 200),
        "member",
    );
}

test "deep values that differ still compare unequal" {
    // Correctness runs both ways: the work list must find a real difference
    // at depth, not just prove identity. The leaf differs (1 vs 2) under 200
    // shared levels of nesting.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"a\":");
    for (0..200) |_| try buf.append(arena, '[');
    try buf.append(arena, '1');
    for (0..200) |_| try buf.append(arena, ']');
    try buf.appendSlice(arena, ",\"b\":");
    for (0..200) |_| try buf.append(arena, '[');
    try buf.append(arena, '2');
    for (0..200) |_| try buf.append(arena, ']');
    try buf.append(arena, '}');
    try expectOk("{% if a == b %}same{% else %}diff{% endif %}", buf.items, "diff");
    try expectOk("{% if a != b %}diff{% else %}same{% endif %}", buf.items, "diff");
    try expectOk("{% if a contains b %}member{% else %}not-member{% endif %}", buf.items, "not-member");
}

test "contains over an array haystack matches deep members" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // xs holds one member equal to a; the match works at any depth now.
    for ([_]usize{ 128, 129, 200 }) |depth| {
        var buf: std.ArrayList(u8) = .empty;
        const deep = try deepArrayJson(arena, depth);
        try buf.appendSlice(arena, "{\"xs\":[");
        try buf.appendSlice(arena, deep[5 .. deep.len - 1]);
        try buf.appendSlice(arena, "],\"a\":");
        try buf.appendSlice(arena, deep[5 .. deep.len - 1]);
        try buf.append(arena, '}');
        try expectOk("{% if xs contains a %}hit{% else %}miss{% endif %}", buf.items, "hit");
    }
}

test "deep comparisons inside nested loops evaluate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try deepArrayJson(arena, 129);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"xs\":[");
    try buf.appendSlice(arena, deep[5 .. deep.len - 1]);
    try buf.appendSlice(arena, "]}");
    try expectOk("{% for x in xs %}{% if x == x %}y{% endif %}{% endfor %}", buf.items, "y");
}
