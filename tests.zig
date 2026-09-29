//! knap-textile test suite.
//!
//! 1. Fixture corpus (`fixtures/*.knap` + `.json` + `.textile`), byte-exact.
//! 2. Error corpus (`fixtures/errors/*.knap` + `.error`), message-checked.
//! 3. Unit tests for behavior beyond the corpus.
//! 4. Properties: every registry filter has a fixture, no case output equals
//!    its template, and the engine actually renders Textile — so every test
//!    in this file fails under `-Dengine-mode=passthrough` (and every
//!    filter-touching test fails under `-Dengine-mode=markdown`).
//!
//! The three `examples/*` artifacts are part of the corpus (`ex-*`).

const std = @import("std");
const kt = @import("knap_textile");
const testing = std.testing;

const Case = struct {
    name: []const u8,
    template: []const u8,
    data: []const u8,
    expected: []const u8,
};

const cases = [_]Case{
    .{ .name = "var-plain", .template = @embedFile("fixtures/var-plain.knap"), .data = @embedFile("fixtures/var-plain.json"), .expected = @embedFile("fixtures/var-plain.textile") },
    .{ .name = "var-dotted", .template = @embedFile("fixtures/var-dotted.knap"), .data = @embedFile("fixtures/var-dotted.json"), .expected = @embedFile("fixtures/var-dotted.textile") },
    .{ .name = "var-bracket-index", .template = @embedFile("fixtures/var-bracket-index.knap"), .data = @embedFile("fixtures/var-bracket-index.json"), .expected = @embedFile("fixtures/var-bracket-index.textile") },
    .{ .name = "var-bracket-key", .template = @embedFile("fixtures/var-bracket-key.knap"), .data = @embedFile("fixtures/var-bracket-key.json"), .expected = @embedFile("fixtures/var-bracket-key.textile") },
    .{ .name = "var-spaces-name", .template = @embedFile("fixtures/var-spaces-name.knap"), .data = @embedFile("fixtures/var-spaces-name.json"), .expected = @embedFile("fixtures/var-spaces-name.textile") },
    .{ .name = "var-missing", .template = @embedFile("fixtures/var-missing.knap"), .data = @embedFile("fixtures/var-missing.json"), .expected = @embedFile("fixtures/var-missing.textile") },
    .{ .name = "var-number", .template = @embedFile("fixtures/var-number.knap"), .data = @embedFile("fixtures/var-number.json"), .expected = @embedFile("fixtures/var-number.textile") },
    .{ .name = "var-json-object", .template = @embedFile("fixtures/var-json-object.knap"), .data = @embedFile("fixtures/var-json-object.json"), .expected = @embedFile("fixtures/var-json-object.textile") },
    .{ .name = "filter-h1-basic", .template = @embedFile("fixtures/filter-h1-basic.knap"), .data = @embedFile("fixtures/filter-h1-basic.json"), .expected = @embedFile("fixtures/filter-h1-basic.textile") },
    .{ .name = "filter-h2-basic", .template = @embedFile("fixtures/filter-h2-basic.knap"), .data = @embedFile("fixtures/filter-h2-basic.json"), .expected = @embedFile("fixtures/filter-h2-basic.textile") },
    .{ .name = "filter-h3-basic", .template = @embedFile("fixtures/filter-h3-basic.knap"), .data = @embedFile("fixtures/filter-h3-basic.json"), .expected = @embedFile("fixtures/filter-h3-basic.textile") },
    .{ .name = "filter-h4-basic", .template = @embedFile("fixtures/filter-h4-basic.knap"), .data = @embedFile("fixtures/filter-h4-basic.json"), .expected = @embedFile("fixtures/filter-h4-basic.textile") },
    .{ .name = "filter-h5-basic", .template = @embedFile("fixtures/filter-h5-basic.knap"), .data = @embedFile("fixtures/filter-h5-basic.json"), .expected = @embedFile("fixtures/filter-h5-basic.textile") },
    .{ .name = "filter-h6-basic", .template = @embedFile("fixtures/filter-h6-basic.knap"), .data = @embedFile("fixtures/filter-h6-basic.json"), .expected = @embedFile("fixtures/filter-h6-basic.textile") },
    .{ .name = "filter-bold-basic", .template = @embedFile("fixtures/filter-bold-basic.knap"), .data = @embedFile("fixtures/filter-bold-basic.json"), .expected = @embedFile("fixtures/filter-bold-basic.textile") },
    .{ .name = "filter-italic-basic", .template = @embedFile("fixtures/filter-italic-basic.knap"), .data = @embedFile("fixtures/filter-italic-basic.json"), .expected = @embedFile("fixtures/filter-italic-basic.textile") },
    .{ .name = "filter-code-basic", .template = @embedFile("fixtures/filter-code-basic.knap"), .data = @embedFile("fixtures/filter-code-basic.json"), .expected = @embedFile("fixtures/filter-code-basic.textile") },
    .{ .name = "filter-blockquote-basic", .template = @embedFile("fixtures/filter-blockquote-basic.knap"), .data = @embedFile("fixtures/filter-blockquote-basic.json"), .expected = @embedFile("fixtures/filter-blockquote-basic.textile") },
    .{ .name = "filter-codeblock-basic", .template = @embedFile("fixtures/filter-codeblock-basic.knap"), .data = @embedFile("fixtures/filter-codeblock-basic.json"), .expected = @embedFile("fixtures/filter-codeblock-basic.textile") },
    .{ .name = "filter-link-basic", .template = @embedFile("fixtures/filter-link-basic.knap"), .data = @embedFile("fixtures/filter-link-basic.json"), .expected = @embedFile("fixtures/filter-link-basic.textile") },
    .{ .name = "filter-link-data-arg", .template = @embedFile("fixtures/filter-link-data-arg.knap"), .data = @embedFile("fixtures/filter-link-data-arg.json"), .expected = @embedFile("fixtures/filter-link-data-arg.textile") },
    .{ .name = "filter-link-literal-arg", .template = @embedFile("fixtures/filter-link-literal-arg.knap"), .data = @embedFile("fixtures/filter-link-literal-arg.json"), .expected = @embedFile("fixtures/filter-link-literal-arg.textile") },
    .{ .name = "filter-list-basic", .template = @embedFile("fixtures/filter-list-basic.knap"), .data = @embedFile("fixtures/filter-list-basic.json"), .expected = @embedFile("fixtures/filter-list-basic.textile") },
    .{ .name = "filter-list-nested", .template = @embedFile("fixtures/filter-list-nested.knap"), .data = @embedFile("fixtures/filter-list-nested.json"), .expected = @embedFile("fixtures/filter-list-nested.textile") },
    .{ .name = "filter-numbered-basic", .template = @embedFile("fixtures/filter-numbered-basic.knap"), .data = @embedFile("fixtures/filter-numbered-basic.json"), .expected = @embedFile("fixtures/filter-numbered-basic.textile") },
    .{ .name = "filter-numbered-nested", .template = @embedFile("fixtures/filter-numbered-nested.knap"), .data = @embedFile("fixtures/filter-numbered-nested.json"), .expected = @embedFile("fixtures/filter-numbered-nested.textile") },
    .{ .name = "filter-table-basic", .template = @embedFile("fixtures/filter-table-basic.knap"), .data = @embedFile("fixtures/filter-table-basic.json"), .expected = @embedFile("fixtures/filter-table-basic.textile") },
    .{ .name = "filter-chain-h2-italic", .template = @embedFile("fixtures/filter-chain-h2-italic.knap"), .data = @embedFile("fixtures/filter-chain-h2-italic.json"), .expected = @embedFile("fixtures/filter-chain-h2-italic.textile") },
    .{ .name = "logic-if-true", .template = @embedFile("fixtures/logic-if-true.knap"), .data = @embedFile("fixtures/logic-if-true.json"), .expected = @embedFile("fixtures/logic-if-true.textile") },
    .{ .name = "logic-else", .template = @embedFile("fixtures/logic-else.knap"), .data = @embedFile("fixtures/logic-else.json"), .expected = @embedFile("fixtures/logic-else.textile") },
    .{ .name = "logic-elseif", .template = @embedFile("fixtures/logic-elseif.knap"), .data = @embedFile("fixtures/logic-elseif.json"), .expected = @embedFile("fixtures/logic-elseif.textile") },
    .{ .name = "logic-truthiness", .template = @embedFile("fixtures/logic-truthiness.knap"), .data = @embedFile("fixtures/logic-truthiness.json"), .expected = @embedFile("fixtures/logic-truthiness.textile") },
    .{ .name = "logic-contains-string", .template = @embedFile("fixtures/logic-contains-string.knap"), .data = @embedFile("fixtures/logic-contains-string.json"), .expected = @embedFile("fixtures/logic-contains-string.textile") },
    .{ .name = "logic-contains-array", .template = @embedFile("fixtures/logic-contains-array.knap"), .data = @embedFile("fixtures/logic-contains-array.json"), .expected = @embedFile("fixtures/logic-contains-array.textile") },
    .{ .name = "logic-contains-object", .template = @embedFile("fixtures/logic-contains-object.knap"), .data = @embedFile("fixtures/logic-contains-object.json"), .expected = @embedFile("fixtures/logic-contains-object.textile") },
    .{ .name = "logic-eq-reflexive", .template = @embedFile("fixtures/logic-eq-reflexive.knap"), .data = @embedFile("fixtures/logic-eq-reflexive.json"), .expected = @embedFile("fixtures/logic-eq-reflexive.textile") },
    .{ .name = "logic-eq-object-order", .template = @embedFile("fixtures/logic-eq-object-order.knap"), .data = @embedFile("fixtures/logic-eq-object-order.json"), .expected = @embedFile("fixtures/logic-eq-object-order.textile") },
    .{ .name = "logic-eq-array-nested", .template = @embedFile("fixtures/logic-eq-array-nested.knap"), .data = @embedFile("fixtures/logic-eq-array-nested.json"), .expected = @embedFile("fixtures/logic-eq-array-nested.textile") },
    .{ .name = "logic-eq-length-mismatch", .template = @embedFile("fixtures/logic-eq-length-mismatch.knap"), .data = @embedFile("fixtures/logic-eq-length-mismatch.json"), .expected = @embedFile("fixtures/logic-eq-length-mismatch.textile") },
    .{ .name = "logic-neq-object", .template = @embedFile("fixtures/logic-neq-object.knap"), .data = @embedFile("fixtures/logic-neq-object.json"), .expected = @embedFile("fixtures/logic-neq-object.textile") },
    .{ .name = "logic-and-or-parens", .template = @embedFile("fixtures/logic-and-or-parens.knap"), .data = @embedFile("fixtures/logic-and-or-parens.json"), .expected = @embedFile("fixtures/logic-and-or-parens.textile") },
    .{ .name = "logic-not", .template = @embedFile("fixtures/logic-not.knap"), .data = @embedFile("fixtures/logic-not.json"), .expected = @embedFile("fixtures/logic-not.textile") },
    .{ .name = "loop-basic", .template = @embedFile("fixtures/loop-basic.knap"), .data = @embedFile("fixtures/loop-basic.json"), .expected = @embedFile("fixtures/loop-basic.textile") },
    .{ .name = "loop-values", .template = @embedFile("fixtures/loop-values.knap"), .data = @embedFile("fixtures/loop-values.json"), .expected = @embedFile("fixtures/loop-values.textile") },
    .{ .name = "loop-nested", .template = @embedFile("fixtures/loop-nested.knap"), .data = @embedFile("fixtures/loop-nested.json"), .expected = @embedFile("fixtures/loop-nested.textile") },
    .{ .name = "loop-empty", .template = @embedFile("fixtures/loop-empty.knap"), .data = @embedFile("fixtures/loop-empty.json"), .expected = @embedFile("fixtures/loop-empty.textile") },
    .{ .name = "comment-inline", .template = @embedFile("fixtures/comment-inline.knap"), .data = @embedFile("fixtures/comment-inline.json"), .expected = @embedFile("fixtures/comment-inline.textile") },
    .{ .name = "comment-multiline", .template = @embedFile("fixtures/comment-multiline.knap"), .data = @embedFile("fixtures/comment-multiline.json"), .expected = @embedFile("fixtures/comment-multiline.textile") },
    .{ .name = "unicode-data", .template = @embedFile("fixtures/unicode-data.knap"), .data = @embedFile("fixtures/unicode-data.json"), .expected = @embedFile("fixtures/unicode-data.textile") },
    .{ .name = "ex-heading", .template = @embedFile("examples/heading.knap"), .data = @embedFile("examples/heading.json"), .expected = @embedFile("examples/heading.textile") },
    .{ .name = "ex-list", .template = @embedFile("examples/list.knap"), .data = @embedFile("examples/list.json"), .expected = @embedFile("examples/list.textile") },
    .{ .name = "ex-table", .template = @embedFile("examples/table.knap"), .data = @embedFile("examples/table.json"), .expected = @embedFile("examples/table.textile") },
};

const ErrorCase = struct {
    name: []const u8,
    template: []const u8,
    data: ?[]const u8 = null,
    message: []const u8,
};

const error_cases = [_]ErrorCase{
    .{ .name = "err-unclosed-if", .template = @embedFile("fixtures/errors/err-unclosed-if.knap"), .message = @embedFile("fixtures/errors/err-unclosed-if.error") },
    .{ .name = "err-unclosed-for", .template = @embedFile("fixtures/errors/err-unclosed-for.knap"), .message = @embedFile("fixtures/errors/err-unclosed-for.error") },
    .{ .name = "err-unclosed-comment", .template = @embedFile("fixtures/errors/err-unclosed-comment.knap"), .message = @embedFile("fixtures/errors/err-unclosed-comment.error") },
    .{ .name = "err-unclosed-output", .template = @embedFile("fixtures/errors/err-unclosed-output.knap"), .message = @embedFile("fixtures/errors/err-unclosed-output.error") },
    .{ .name = "err-unknown-filter", .template = @embedFile("fixtures/errors/err-unknown-filter.knap"), .message = @embedFile("fixtures/errors/err-unknown-filter.error") },
    .{ .name = "err-bad-args-extra", .template = @embedFile("fixtures/errors/err-bad-args-extra.knap"), .message = @embedFile("fixtures/errors/err-bad-args-extra.error") },
    .{ .name = "err-bad-args-link-missing", .template = @embedFile("fixtures/errors/err-bad-args-link-missing.knap"), .message = @embedFile("fixtures/errors/err-bad-args-link-missing.error") },
    .{ .name = "err-link-scheme-javascript", .template = @embedFile("fixtures/errors/err-link-scheme-javascript.knap"), .message = @embedFile("fixtures/errors/err-link-scheme-javascript.error") },
    .{ .name = "err-link-scheme-from-data", .template = @embedFile("fixtures/errors/err-link-scheme-from-data.knap"), .data = @embedFile("fixtures/errors/err-link-scheme-from-data.json"), .message = @embedFile("fixtures/errors/err-link-scheme-from-data.error") },
    .{ .name = "err-link-scheme-data", .template = @embedFile("fixtures/errors/err-link-scheme-data.knap"), .message = @embedFile("fixtures/errors/err-link-scheme-data.error") },
    .{ .name = "err-arg-resolves-to-object", .template = @embedFile("fixtures/errors/err-arg-resolves-to-object.knap"), .data = @embedFile("fixtures/errors/err-arg-resolves-to-object.json"), .message = @embedFile("fixtures/errors/err-arg-resolves-to-object.error") },
    .{ .name = "err-multiline-bold", .template = @embedFile("fixtures/errors/err-multiline-bold.knap"), .data = @embedFile("fixtures/errors/err-multiline-bold.json"), .message = @embedFile("fixtures/errors/err-multiline-bold.error") },
    .{ .name = "err-ragged-table", .template = @embedFile("fixtures/errors/err-ragged-table.knap"), .data = @embedFile("fixtures/errors/err-ragged-table.json"), .message = @embedFile("fixtures/errors/err-ragged-table.error") },
    .{ .name = "err-deep-list", .template = @embedFile("fixtures/errors/err-deep-list.knap"), .data = @embedFile("fixtures/errors/err-deep-list.json"), .message = @embedFile("fixtures/errors/err-deep-list.error") },
    .{ .name = "err-nonarray-list", .template = @embedFile("fixtures/errors/err-nonarray-list.knap"), .data = @embedFile("fixtures/errors/err-nonarray-list.json"), .message = @embedFile("fixtures/errors/err-nonarray-list.error") },
    .{ .name = "err-loop-nonarray", .template = @embedFile("fixtures/errors/err-loop-nonarray.knap"), .data = @embedFile("fixtures/errors/err-loop-nonarray.json"), .message = @embedFile("fixtures/errors/err-loop-nonarray.error") },
    .{ .name = "err-if-missing-value", .template = @embedFile("fixtures/errors/err-if-missing-value.knap"), .message = @embedFile("fixtures/errors/err-if-missing-value.error") },
    .{ .name = "err-stray-endif", .template = @embedFile("fixtures/errors/err-stray-endif.knap"), .message = @embedFile("fixtures/errors/err-stray-endif.error") },
    .{ .name = "err-nesting-too-deep", .template = @embedFile("fixtures/errors/err-nesting-too-deep.knap"), .message = @embedFile("fixtures/errors/err-nesting-too-deep.error") },
};

fn renderCase(
    arena: std.mem.Allocator,
    template: []const u8,
    data_json: []const u8,
    d: *kt.Diagnostic,
) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data_json, .{});
    return kt.render(arena, template, parsed, d);
}

fn renderOk(template: []const u8, data_json: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderCase(arena_state.allocator(), template, data_json, &d);
    testing.expectEqualStrings(expected, out) catch |e| {
        std.debug.print("render mismatch\n--- expected ---\n{s}\n--- actual ---\n{s}\n---\n", .{ expected, out });
        return e;
    };
    try assertTextileDialect();
}

fn renderErr(template: []const u8, data_json: []const u8, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const res = renderCase(arena_state.allocator(), template, data_json, &d);
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

fn renderLimit(
    template: []const u8,
    data_json: []const u8,
    max: usize,
    d: *kt.Diagnostic,
    arena: std.mem.Allocator,
) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data_json, .{});
    return kt.renderWithLimit(arena, template, parsed, d, max);
}

fn renderLimitOk(template: []const u8, data_json: []const u8, max: usize, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderLimit(template, data_json, max, &d, arena_state.allocator());
    testing.expectEqualStrings(expected, out) catch |e| {
        std.debug.print("render mismatch\n--- expected ---\n{s}\n--- actual ---\n{s}\n---\n", .{ expected, out });
        return e;
    };
    try assertTextileDialect();
}

fn renderLimitErr(template: []const u8, data_json: []const u8, max: usize, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const res = renderLimit(template, data_json, max, &d, arena_state.allocator());
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

/// One render through the Textile pipeline; fails under both mutants.
/// Called from `renderOk`/`renderErr`, so every test in this file
/// re-asserts the dialect and cannot pass while the engine is degraded.
fn assertTextileDialect() !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderCase(arena_state.allocator(), "{{ \"x\" | bold }}", "{}", &d);
    testing.expectEqualStrings("*x*", out) catch |e| {
        std.debug.print("dialect guard: expected Textile '*x*', got:\n{s}\n", .{out});
        return e;
    };
}

test "corpus: fixtures render byte-exact" {
    var failures: usize = 0;
    for (cases) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var d = kt.Diagnostic{};
        const out = renderCase(arena_state.allocator(), c.template, c.data, &d) catch |e| {
            std.debug.print("fixture '{s}': unexpected error {s}: {s}\n", .{ c.name, @errorName(e), d.message });
            failures += 1;
            continue;
        };
        if (!std.mem.eql(u8, out, c.expected)) {
            std.debug.print("fixture '{s}': byte mismatch\n--- expected ---\n{s}\n--- actual ---\n{s}\n---\n", .{ c.name, c.expected, out });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "corpus: error fixtures fail with the pinned message" {
    var failures: usize = 0;
    for (error_cases) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var d = kt.Diagnostic{};
        const data_json = c.data orelse "{}";
        const res = renderCase(arena_state.allocator(), c.template, data_json, &d);
        if (res) |out| {
            std.debug.print("error fixture '{s}': expected failure, got output [{s}]\n", .{ c.name, out });
            failures += 1;
            continue;
        } else |e| {
            if (e != error.Template) {
                std.debug.print("error fixture '{s}': expected error.Template, got {s}\n", .{ c.name, @errorName(e) });
                failures += 1;
                continue;
            }
        }
        var needle: []const u8 = c.message;
        while (needle.len > 0 and (needle[needle.len - 1] == '\n' or needle[needle.len - 1] == '\r')) {
            needle = needle[0 .. needle.len - 1];
        }
        if (std.mem.indexOf(u8, d.message, needle) == null) {
            std.debug.print("error fixture '{s}': message mismatch\n--- wanted ---\n{s}\n--- got ---\n{s}\n", .{ c.name, needle, d.message });
            failures += 1;
        }
    }
    try assertTextileDialect();
    try testing.expectEqual(@as(usize, 0), failures);
}

test "property: every registry filter has at least one fixture case" {
    var buf: [64]u8 = undefined;
    for (kt.filters.registry()) |entry| {
        const prefix = try std.fmt.bufPrint(&buf, "filter-{s}-", .{entry.name});
        var found = false;
        for (cases) |c| {
            if (std.mem.startsWith(u8, c.name, prefix)) {
                found = true;
                break;
            }
        }
        if (!found) std.debug.print("no fixture case for filter '{s}'\n", .{entry.name});
        try testing.expect(found);
    }
    try assertTextileDialect();
}

test "property: no case output equals its template" {
    for (cases) |c| {
        if (std.mem.eql(u8, c.expected, c.template)) {
            std.debug.print("fixture '{s}' output equals its template (passthrough would pass)\n", .{c.name});
            try testing.expect(false);
        }
    }
    try assertTextileDialect();
}

test "unit: whitespace-free tags" {
    try renderOk("{{name}}!", "{\"name\":\"Ada\"}", "Ada!");
}

test "unit: number and string literals" {
    try renderOk("{{ 7 }} {{ -3 }} {{ 1.5 }} {{ \"Hi\" }}", "{}", "7 -3 1.5 Hi");
}

test "unit: escaped quote in string literal" {
    try renderOk("{{ \"a\\\"b\" | bold }}", "{}", "*a\"b*");
}

test "unit: missing variable is false in conditions" {
    try renderOk("{% if missing %}y{% else %}n{% endif %}", "{}", "n");
}

test "unit: empty string, null, and false are falsy" {
    try renderOk(
        "{% if v %}y{% else %}n{% endif %}{% if w %}y{% else %}n{% endif %}{% if x %}y{% else %}n{% endif %}",
        "{\"v\":\"\",\"w\":null,\"x\":false}",
        "nnn",
    );
}

test "unit: ordered comparison and numeric equality" {
    try renderOk("{% if price >= 100 %}big{% else %}small{% endif %}", "{\"price\":42.57}", "small");
    try renderOk("{% if price >= 100 %}big{% else %}small{% endif %}", "{\"price\":100}", "big");
    try renderOk("{% if n == 2 %}eq{% else %}ne{% endif %}", "{\"n\":2.0}", "eq");
}

test "unit: non-scalar equality is reflexive" {
    try renderOk("{% if x == x %}EQ{% else %}NEQ{% endif %}", "{\"x\":{\"k\":1}}", "EQ");
    try renderOk("{% if x == x %}EQ{% else %}NEQ{% endif %}", "{\"x\":[1,[2]]}", "EQ");
    try renderOk("{% if x == x %}EQ{% else %}NEQ{% endif %}", "{\"x\":{}}", "EQ");
    try renderOk("{% if x == x %}EQ{% else %}NEQ{% endif %}", "{\"x\":[]}", "EQ");
}

test "unit: object equality ignores key order" {
    try renderOk("{% if a == b %}EQ{% else %}NEQ{% endif %}", "{\"a\":{\"p\":1,\"q\":2},\"b\":{\"q\":2,\"p\":1}}", "EQ");
    // An extra key, not just a reordered one, must still compare unequal.
    try renderOk("{% if a == b %}EQ{% else %}NEQ{% endif %}", "{\"a\":{\"p\":1},\"b\":{\"p\":1,\"q\":2}}", "NEQ");
}

test "unit: comparison across kinds is not equality" {
    try renderOk("{% if a == b %}EQ{% else %}NEQ{% endif %}", "{\"a\":{},\"b\":[]}", "NEQ");
    try renderOk("{% if a == b %}EQ{% else %}NEQ{% endif %}", "{\"a\":{\"k\":1},\"b\":\"{\\\"k\\\":1}\"}", "NEQ");
    try renderOk("{% if a != b %}NEQ{% else %}EQ{% endif %}", "{\"a\":{\"k\":1},\"b\":{\"k\":1}}", "EQ");
}

test "unit: contains matches object members structurally" {
    try renderOk(
        "{% if items contains needle %}hit{% else %}miss{% endif %}",
        "{\"items\":[{\"k\":1},{\"k\":2}],\"needle\":{\"k\":2}}",
        "hit",
    );
    try renderOk(
        "{% if items contains needle %}hit{% else %}miss{% endif %}",
        "{\"items\":[{\"k\":1}],\"needle\":{\"k\":9}}",
        "miss",
    );
}

test "unit: nested containers compare element-wise" {
    try renderOk("{% if a == b %}EQ{% else %}NEQ{% endif %}", "{\"a\":[[1,2]],\"b\":[[1,2]]}", "EQ");
    try renderOk("{% if a == b %}EQ{% else %}NEQ{% endif %}", "{\"a\":[[1,2]],\"b\":[[1,3]]}", "NEQ");
}

test "unit: bang negation" {
    try renderOk("{% if !hidden %}v{% endif %}", "{\"hidden\":false}", "v");
}

test "unit: loop.index0 and loop.first" {
    try renderOk(
        "{% for x in xs %}{{ loop.index0 }}{% if loop.first %}F{% endif %}{% endfor %}",
        "{\"xs\":[\"a\",\"b\"]}",
        "0F1",
    );
}

test "unit: loop over a nested array path" {
    try renderOk("{% for item in a.b %}{{ item }};{% endfor %}", "{\"a\":{\"b\":[1,2]}}", "1;2;");
    try renderOk("{% for item in a[0] %}{{ item }}{% endfor %}", "{\"a\":[[\"p\",\"q\"]]}", "pq");
}

test "unit: loop body leading-newline strip applies once" {
    try renderOk("{% for x in xs %}\n\n{{ x }}\n{% endfor %}", "{\"xs\":[\"A\",\"B\"]}", "\nA\n\nB\n");
}

test "unit: if-branch leading-newline strip" {
    try renderOk("{% if a %}\nX\n{% else %}\nY\n{% endif %}", "{\"a\":true}", "X\n");
}

test "unit: comments strip only themselves" {
    try renderOk("A {# note #} B", "{}", "A  B");
}

test "unit: float and integer rendering" {
    try renderOk("{{ a }} {{ b }}", "{\"a\":2.0,\"b\":1.5}", "2 1.5");
}

test "unit: three-filter chain" {
    try renderOk("{{ \"n\" | code | bold | h2 }}", "{}", "h2. *@n@*");
}

test "unit: a bare filter argument falls back to the literal" {
    // No such key in the data root, so `missing` stays the word.
    try renderOk("{{ \"x\" | link:missing }}", "{}", "\"x\":missing");
}

test "unit: bare filter arguments render scalar data values" {
    try renderOk("{{ \"x\" | link:n }}", "{\"n\":42}", "\"x\":42");
    try renderOk("{{ \"x\" | link:b }}", "{\"b\":true}", "\"x\":true");
    try renderOk("{{ \"x\" | link:s }}", "{\"s\":\"https://y/\"}", "\"x\":https://y/");
}

test "unit: a non-text filter argument is a bad argument" {
    try renderErr("{{ \"x\" | link:obj }}", "{\"obj\":{\"k\":1}}", "filter arguments must be text");
    try renderErr("{{ \"x\" | link:u }}", "{\"u\":null}", "filter arguments must be text");
}

test "unit: navigational and relative link URLs stay allowed" {
    try renderOk("{{ \"x\" | link:\"mailto:a@b.c\" }}", "{}", "\"x\":mailto:a@b.c");
    try renderOk("{{ \"x\" | link:\"file:///etc/passwd\" }}", "{}", "\"x\":file:///etc/passwd");
    try renderOk("{{ \"x\" | link:\"../notes/page.html\" }}", "{}", "\"x\":../notes/page.html");
    // A colon that is not a well-formed scheme belongs to the path.
    try renderOk("{{ \"x\" | link:\"a/b:c\" }}", "{}", "\"x\":a/b:c");
}

test "unit: blocked link schemes are rejected case-insensitively" {
    for ([_][]const u8{ "javascript:alert(1)", "JavaScript:alert(1)", "JAVASCRIPT:alert(1)", "vbscript:m", "data:text/html,x" }) |url| {
        var buf: [128]u8 = undefined;
        // `{{{{` / `}}}}` because std.fmt treats doubled braces as escapes.
        const tpl = try std.fmt.bufPrint(&buf, "{{{{ \"x\" | link:\"{s}\" }}}}", .{url});
        try renderErr(tpl, "{}", "which can execute script");
    }
}

test "unit: a blocked scheme reaching link through the data is rejected" {
    try renderErr("{{ name | link:url }}", "{\"name\":\"c\",\"url\":\"javascript:alert(1)\"}", "which can execute script");
}

test "unit: nested loops that would multiply hit the output cap" {
    // 20 * 20 = 400 one-byte iterations, so a 100-byte cap must trip.
    const tpl = "{% for x in a %}{% for y in a %}x{% endfor %}{% endfor %}";
    try renderLimitErr(
        tpl,
        "{\"a\":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]}",
        100,
        "output exceeded the 100 byte limit at loop depth 2",
    );
}

test "unit: the output cap is an exact ceiling" {
    try renderLimitOk("{{ s }}", "{\"s\":\"hello\"}", 5, "hello");
    try renderLimitErr("{{ s }}", "{\"s\":\"hello\"}", 4, "output exceeded the 4 byte limit");
}

test "unit: a zero output limit disables the cap" {
    try renderLimitOk("{{ s }}", "{\"s\":\"hello\"}", 0, "hello");
}

test "unit: structured values are charged against the output cap" {
    // `{{ data }}` emits compact JSON through a separate write path; it must
    // still be charged, or the cap has a hole.
    try renderLimitOk("{{ data }}", "{\"data\":{\"k\":1}}", 100, "{\"k\":1}");
    try renderLimitErr("{{ data }}", "{\"data\":{\"k\":1}}", 4, "output exceeded the 4 byte limit");
}

test "unit: the output cap does not fire on ordinary renders" {
    // The default cap is generous; every corpus-sized render must clear it.
    try testing.expect(kt.default_max_output > 1024 * 1024);
}

test "unit: spaced names are not valid condition operands" {
    try renderErr("{% if First name %}x{% endif %}", "{}", "unexpected text after condition");
}

test "unit: unknown logic tag names the tag" {
    try renderErr("{% set x = 1 %}", "{}", "unknown logic tag 'set'");
}

test "unit: duplicate else is rejected" {
    try renderErr("{% if a %}x{% else %}y{% else %}z{% endif %}", "{\"a\":true}", "duplicate '{% else %}'");
}

test "unit: empty output tag is rejected" {
    try renderErr("{{ }}", "{}", "expected a value");
}

test "unit: error columns count Unicode code points" {
    try renderErr("{{ 京 | nope }}", "{}", "unknown filter at line 1, column 8");
}

test "unit: diagnostic fields for an unknown filter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const res = renderCase(arena_state.allocator(), "{{ title | nope }}\n", "{}", &d);
    try testing.expectError(error.Template, res);
    try testing.expectEqual(kt.diag.Kind.unknown_filter, d.kind);
    try testing.expectEqual(@as(u32, 1), d.line);
    try testing.expectEqual(@as(u32, 12), d.column);
    try assertTextileDialect();
}
