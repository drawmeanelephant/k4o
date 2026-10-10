// Deep-value guards (engine side of dogbed#23 and dogbed#24). Interpolating
// a value nested past std.json.Stringify's fixed 256-level stack must fail as
// a template diagnostic — never a panic or an unchecked write — and a
// structural comparison past the compare budget must fail rather than answer
// "not equal" for a value compared with itself. The at-cap inputs keep
// working, so the guards only trip past their documented limits.
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

test "a value equals itself at the compare cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try deepArrayJson(arena, 128);
    try expectOk("{% if a == a %}same{% else %}diff{% endif %}", data, "same");
    try expectOk("{% if a != a %}diff{% else %}same{% endif %}", data, "same");
    try expectOk("{% if a == a %}same{% else %}diff{% endif %}", try deepObjectJson(arena, 128), "same");
}

test "comparison past the cap is a diagnostic, not a wrong answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try deepArrayJson(arena, 129);
    // Returning false here rendered 'diff' — a value stopped equaling itself.
    try expectErr("{% if a == a %}same{% else %}diff{% endif %}", data, "comparison nested too deeply");
    try expectErr("{% if a != a %}diff{% else %}same{% endif %}", data, "comparison nested too deeply");
    try expectErr("{% if a == a %}same{% else %}diff{% endif %}", try deepObjectJson(arena, 129), "comparison nested too deeply");
}

test "contains over an array haystack reports deep comparisons" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // xs holds one member equal to a; at the cap the match still works,
    // past it the comparison must surface the diagnostic.
    var buf: std.ArrayList(u8) = .empty;
    const deep = try deepArrayJson(arena, 128);
    try buf.appendSlice(arena, "{\"xs\":[");
    try buf.appendSlice(arena, deep[5 .. deep.len - 1]);
    try buf.appendSlice(arena, "],\"a\":");
    try buf.appendSlice(arena, deep[5 .. deep.len - 1]);
    try buf.append(arena, '}');
    try expectOk("{% if xs contains a %}hit{% else %}miss{% endif %}", buf.items, "hit");
    const deep129 = try deepArrayJson(arena, 129);
    var buf2: std.ArrayList(u8) = .empty;
    try buf2.appendSlice(arena, "{\"xs\":[");
    try buf2.appendSlice(arena, deep129[5 .. deep129.len - 1]);
    try buf2.appendSlice(arena, "],\"a\":");
    try buf2.appendSlice(arena, deep129[5 .. deep129.len - 1]);
    try buf2.append(arena, '}');
    try expectErr("{% if xs contains a %}hit{% else %}miss{% endif %}", buf2.items, "comparison nested too deeply");
}

test "deep comparisons inside nested loops fail cleanly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try deepArrayJson(arena, 129);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"xs\":[");
    try buf.appendSlice(arena, deep[5 .. deep.len - 1]);
    try buf.appendSlice(arena, "]}");
    try expectErr("{% for x in xs %}{% if x == x %}y{% endif %}{% endfor %}", buf.items, "comparison nested too deeply");
}
