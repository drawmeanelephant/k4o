//! k4o test suite.
//!
//! Organized as:
//!
//! 1. Fixture corpus (`fixtures/*.knap` + `.json` + `.markdown`), compared
//!    byte-for-byte against `.markdown` expected output.
//! 2. Error corpus (`fixtures/errors/*.knap` + `.error`), message-checked.
//! 3. Registry property tests (every filter has a fixture).
//! 4. Lint checks: fixture corpus lints clean; lint corpus maps findings
//!    to stable rule names.
//! 5. Unit tests for engine and filter semantics.
//!
//! The byte corpus pins oracle-faithful output — `.markdown` expectations
//! are regenerated against knap 0.6.0 (tools/differential). Unit tests
//! assert user-visible semantics the corpus does not already pin.
const std = @import("std");
const kt = @import("k4o");
const testing = std.testing;
const engine_mode = @import("build_options").engine_mode;

/// The red-green mutant gate requires every test to fail against a
/// degraded engine — a test that never touches the engine asserts the
/// normal mode is active so the mutants still discriminate it.
fn expectNormalEngine() !void {
    try testing.expectEqualStrings("normal", engine_mode);
}

// Deep-value and hardening tests live under tests/ (issue work batches).
// pub const hardening = @import("tests/hardening.zig");
// pub const deep_nesting = @import("tests/deep_nesting.zig");

const Case = struct {
    name: []const u8,
    template: []const u8,
    data: []const u8,
    expected: []const u8,
};

const cases = [_]Case{
    .{ .name = "comment-inline", .template = @embedFile("fixtures/comment-inline.knap"), .data = @embedFile("fixtures/comment-inline.json"), .expected = @embedFile("fixtures/comment-inline.markdown") },
    .{ .name = "comment-multiline", .template = @embedFile("fixtures/comment-multiline.knap"), .data = @embedFile("fixtures/comment-multiline.json"), .expected = @embedFile("fixtures/comment-multiline.markdown") },
    .{ .name = "filter-blockquote-basic", .template = @embedFile("fixtures/filter-blockquote-basic.knap"), .data = @embedFile("fixtures/filter-blockquote-basic.json"), .expected = @embedFile("fixtures/filter-blockquote-basic.markdown") },
    .{ .name = "filter-blockquote-ordered-marker", .template = @embedFile("fixtures/filter-blockquote-ordered-marker.knap"), .data = @embedFile("fixtures/filter-blockquote-ordered-marker.json"), .expected = @embedFile("fixtures/filter-blockquote-ordered-marker.markdown") },
    .{ .name = "filter-blockquote-tilde-fence", .template = @embedFile("fixtures/filter-blockquote-tilde-fence.knap"), .data = @embedFile("fixtures/filter-blockquote-tilde-fence.json"), .expected = @embedFile("fixtures/filter-blockquote-tilde-fence.markdown") },
    .{ .name = "filter-bold-basic", .template = @embedFile("fixtures/filter-bold-basic.knap"), .data = @embedFile("fixtures/filter-bold-basic.json"), .expected = @embedFile("fixtures/filter-bold-basic.markdown") },
    .{ .name = "filter-calc-basic", .template = @embedFile("fixtures/filter-calc-basic.knap"), .data = @embedFile("fixtures/filter-calc-basic.json"), .expected = @embedFile("fixtures/filter-calc-basic.markdown") },
    .{ .name = "filter-callout-args", .template = @embedFile("fixtures/filter-callout-args.knap"), .data = @embedFile("fixtures/filter-callout-args.json"), .expected = @embedFile("fixtures/filter-callout-args.markdown") },
    .{ .name = "filter-callout-basic", .template = @embedFile("fixtures/filter-callout-basic.knap"), .data = @embedFile("fixtures/filter-callout-basic.json"), .expected = @embedFile("fixtures/filter-callout-basic.markdown") },
    .{ .name = "filter-callout-fold", .template = @embedFile("fixtures/filter-callout-fold.knap"), .data = @embedFile("fixtures/filter-callout-fold.json"), .expected = @embedFile("fixtures/filter-callout-fold.markdown") },
    .{ .name = "filter-camel-basic", .template = @embedFile("fixtures/filter-camel-basic.knap"), .data = @embedFile("fixtures/filter-camel-basic.json"), .expected = @embedFile("fixtures/filter-camel-basic.markdown") },
    .{ .name = "filter-capitalize-basic", .template = @embedFile("fixtures/filter-capitalize-basic.knap"), .data = @embedFile("fixtures/filter-capitalize-basic.json"), .expected = @embedFile("fixtures/filter-capitalize-basic.markdown") },
    .{ .name = "filter-chain-h2-italic", .template = @embedFile("fixtures/filter-chain-h2-italic.knap"), .data = @embedFile("fixtures/filter-chain-h2-italic.json"), .expected = @embedFile("fixtures/filter-chain-h2-italic.markdown") },
    .{ .name = "filter-code-basic", .template = @embedFile("fixtures/filter-code-basic.knap"), .data = @embedFile("fixtures/filter-code-basic.json"), .expected = @embedFile("fixtures/filter-code-basic.markdown") },
    .{ .name = "filter-codeblock-basic", .template = @embedFile("fixtures/filter-codeblock-basic.knap"), .data = @embedFile("fixtures/filter-codeblock-basic.json"), .expected = @embedFile("fixtures/filter-codeblock-basic.markdown") },
    .{ .name = "filter-codeblock-blank-lines", .template = @embedFile("fixtures/filter-codeblock-blank-lines.knap"), .data = @embedFile("fixtures/filter-codeblock-blank-lines.json"), .expected = @embedFile("fixtures/filter-codeblock-blank-lines.markdown") },
    .{ .name = "filter-comment-basic", .template = @embedFile("fixtures/filter-comment-basic.knap"), .data = @embedFile("fixtures/filter-comment-basic.json"), .expected = @embedFile("fixtures/filter-comment-basic.markdown") },
    .{ .name = "filter-comment-multiline", .template = @embedFile("fixtures/filter-comment-multiline.knap"), .data = @embedFile("fixtures/filter-comment-multiline.json"), .expected = @embedFile("fixtures/filter-comment-multiline.markdown") },
    .{ .name = "filter-compact-basic", .template = @embedFile("fixtures/filter-compact-basic.knap"), .data = @embedFile("fixtures/filter-compact-basic.json"), .expected = @embedFile("fixtures/filter-compact-basic.markdown") },
    .{ .name = "filter-date-basic", .template = @embedFile("fixtures/filter-date-basic.knap"), .data = @embedFile("fixtures/filter-date-basic.json"), .expected = @embedFile("fixtures/filter-date-basic.markdown") },
    .{ .name = "filter-date_modify-basic", .template = @embedFile("fixtures/filter-date_modify-basic.knap"), .data = @embedFile("fixtures/filter-date_modify-basic.json"), .expected = @embedFile("fixtures/filter-date_modify-basic.markdown") },
    .{ .name = "filter-decode_uri-basic", .template = @embedFile("fixtures/filter-decode_uri-basic.knap"), .data = @embedFile("fixtures/filter-decode_uri-basic.json"), .expected = @embedFile("fixtures/filter-decode_uri-basic.markdown") },
    .{ .name = "filter-duration-basic", .template = @embedFile("fixtures/filter-duration-basic.knap"), .data = @embedFile("fixtures/filter-duration-basic.json"), .expected = @embedFile("fixtures/filter-duration-basic.markdown") },
    .{ .name = "filter-embed-alias", .template = @embedFile("fixtures/filter-embed-alias.knap"), .data = @embedFile("fixtures/filter-embed-alias.json"), .expected = @embedFile("fixtures/filter-embed-alias.markdown") },
    .{ .name = "filter-embed-basic", .template = @embedFile("fixtures/filter-embed-basic.knap"), .data = @embedFile("fixtures/filter-embed-basic.json"), .expected = @embedFile("fixtures/filter-embed-basic.markdown") },
    .{ .name = "filter-encode_uri-basic", .template = @embedFile("fixtures/filter-encode_uri-basic.knap"), .data = @embedFile("fixtures/filter-encode_uri-basic.json"), .expected = @embedFile("fixtures/filter-encode_uri-basic.markdown") },
    .{ .name = "filter-escape_md-basic", .template = @embedFile("fixtures/filter-escape_md-basic.knap"), .data = @embedFile("fixtures/filter-escape_md-basic.json"), .expected = @embedFile("fixtures/filter-escape_md-basic.markdown") },
    .{ .name = "filter-first-basic", .template = @embedFile("fixtures/filter-first-basic.knap"), .data = @embedFile("fixtures/filter-first-basic.json"), .expected = @embedFile("fixtures/filter-first-basic.markdown") },
    .{ .name = "filter-footnote-basic", .template = @embedFile("fixtures/filter-footnote-basic.knap"), .data = @embedFile("fixtures/filter-footnote-basic.json"), .expected = @embedFile("fixtures/filter-footnote-basic.markdown") },
    .{ .name = "filter-footnote-object", .template = @embedFile("fixtures/filter-footnote-object.knap"), .data = @embedFile("fixtures/filter-footnote-object.json"), .expected = @embedFile("fixtures/filter-footnote-object.markdown") },
    .{ .name = "filter-fragment_link-basic", .template = @embedFile("fixtures/filter-fragment_link-basic.knap"), .data = @embedFile("fixtures/filter-fragment_link-basic.json"), .expected = @embedFile("fixtures/filter-fragment_link-basic.markdown") },
    .{ .name = "filter-fragment_link-scalar", .template = @embedFile("fixtures/filter-fragment_link-scalar.knap"), .data = @embedFile("fixtures/filter-fragment_link-scalar.json"), .expected = @embedFile("fixtures/filter-fragment_link-scalar.markdown") },
    .{ .name = "filter-h1-basic", .template = @embedFile("fixtures/filter-h1-basic.knap"), .data = @embedFile("fixtures/filter-h1-basic.json"), .expected = @embedFile("fixtures/filter-h1-basic.markdown") },
    .{ .name = "filter-h2-basic", .template = @embedFile("fixtures/filter-h2-basic.knap"), .data = @embedFile("fixtures/filter-h2-basic.json"), .expected = @embedFile("fixtures/filter-h2-basic.markdown") },
    .{ .name = "filter-h3-basic", .template = @embedFile("fixtures/filter-h3-basic.knap"), .data = @embedFile("fixtures/filter-h3-basic.json"), .expected = @embedFile("fixtures/filter-h3-basic.markdown") },
    .{ .name = "filter-h4-basic", .template = @embedFile("fixtures/filter-h4-basic.knap"), .data = @embedFile("fixtures/filter-h4-basic.json"), .expected = @embedFile("fixtures/filter-h4-basic.markdown") },
    .{ .name = "filter-h5-basic", .template = @embedFile("fixtures/filter-h5-basic.knap"), .data = @embedFile("fixtures/filter-h5-basic.json"), .expected = @embedFile("fixtures/filter-h5-basic.markdown") },
    .{ .name = "filter-h6-basic", .template = @embedFile("fixtures/filter-h6-basic.knap"), .data = @embedFile("fixtures/filter-h6-basic.json"), .expected = @embedFile("fixtures/filter-h6-basic.markdown") },
    .{ .name = "filter-hard_break-basic", .template = @embedFile("fixtures/filter-hard_break-basic.knap"), .data = @embedFile("fixtures/filter-hard_break-basic.json"), .expected = @embedFile("fixtures/filter-hard_break-basic.markdown") },
    .{ .name = "filter-highlight-args", .template = @embedFile("fixtures/filter-highlight-args.knap"), .data = @embedFile("fixtures/filter-highlight-args.json"), .expected = @embedFile("fixtures/filter-highlight-args.markdown") },
    .{ .name = "filter-highlight-basic", .template = @embedFile("fixtures/filter-highlight-basic.knap"), .data = @embedFile("fixtures/filter-highlight-basic.json"), .expected = @embedFile("fixtures/filter-highlight-basic.markdown") },
    .{ .name = "filter-hr-basic", .template = @embedFile("fixtures/filter-hr-basic.knap"), .data = @embedFile("fixtures/filter-hr-basic.json"), .expected = @embedFile("fixtures/filter-hr-basic.markdown") },
    .{ .name = "filter-hr-empty", .template = @embedFile("fixtures/filter-hr-empty.knap"), .data = @embedFile("fixtures/filter-hr-empty.json"), .expected = @embedFile("fixtures/filter-hr-empty.markdown") },
    .{ .name = "filter-image-basic", .template = @embedFile("fixtures/filter-image-basic.knap"), .data = @embedFile("fixtures/filter-image-basic.json"), .expected = @embedFile("fixtures/filter-image-basic.markdown") },
    .{ .name = "filter-indent-args", .template = @embedFile("fixtures/filter-indent-args.knap"), .data = @embedFile("fixtures/filter-indent-args.json"), .expected = @embedFile("fixtures/filter-indent-args.markdown") },
    .{ .name = "filter-indent-basic", .template = @embedFile("fixtures/filter-indent-basic.knap"), .data = @embedFile("fixtures/filter-indent-basic.json"), .expected = @embedFile("fixtures/filter-indent-basic.markdown") },
    .{ .name = "filter-italic-basic", .template = @embedFile("fixtures/filter-italic-basic.knap"), .data = @embedFile("fixtures/filter-italic-basic.json"), .expected = @embedFile("fixtures/filter-italic-basic.markdown") },
    .{ .name = "filter-join-args", .template = @embedFile("fixtures/filter-join-args.knap"), .data = @embedFile("fixtures/filter-join-args.json"), .expected = @embedFile("fixtures/filter-join-args.markdown") },
    .{ .name = "filter-join-basic", .template = @embedFile("fixtures/filter-join-basic.knap"), .data = @embedFile("fixtures/filter-join-basic.json"), .expected = @embedFile("fixtures/filter-join-basic.markdown") },
    .{ .name = "filter-kebab-basic", .template = @embedFile("fixtures/filter-kebab-basic.knap"), .data = @embedFile("fixtures/filter-kebab-basic.json"), .expected = @embedFile("fixtures/filter-kebab-basic.markdown") },
    .{ .name = "filter-last-basic", .template = @embedFile("fixtures/filter-last-basic.knap"), .data = @embedFile("fixtures/filter-last-basic.json"), .expected = @embedFile("fixtures/filter-last-basic.markdown") },
    .{ .name = "filter-length-basic", .template = @embedFile("fixtures/filter-length-basic.knap"), .data = @embedFile("fixtures/filter-length-basic.json"), .expected = @embedFile("fixtures/filter-length-basic.markdown") },
    .{ .name = "filter-link-basic", .template = @embedFile("fixtures/filter-link-basic.knap"), .data = @embedFile("fixtures/filter-link-basic.json"), .expected = @embedFile("fixtures/filter-link-basic.markdown") },
    .{ .name = "filter-link-data-arg", .template = @embedFile("fixtures/filter-link-data-arg.knap"), .data = @embedFile("fixtures/filter-link-data-arg.json"), .expected = @embedFile("fixtures/filter-link-data-arg.markdown") },
    .{ .name = "filter-link-literal-arg", .template = @embedFile("fixtures/filter-link-literal-arg.knap"), .data = @embedFile("fixtures/filter-link-literal-arg.json"), .expected = @embedFile("fixtures/filter-link-literal-arg.markdown") },
    .{ .name = "filter-list-basic", .template = @embedFile("fixtures/filter-list-basic.knap"), .data = @embedFile("fixtures/filter-list-basic.json"), .expected = @embedFile("fixtures/filter-list-basic.markdown") },
    .{ .name = "filter-list-nested", .template = @embedFile("fixtures/filter-list-nested.knap"), .data = @embedFile("fixtures/filter-list-nested.json"), .expected = @embedFile("fixtures/filter-list-nested.markdown") },
    .{ .name = "filter-list-tilde-fence", .template = @embedFile("fixtures/filter-list-tilde-fence.knap"), .data = @embedFile("fixtures/filter-list-tilde-fence.json"), .expected = @embedFile("fixtures/filter-list-tilde-fence.markdown") },
    .{ .name = "filter-lower-basic", .template = @embedFile("fixtures/filter-lower-basic.knap"), .data = @embedFile("fixtures/filter-lower-basic.json"), .expected = @embedFile("fixtures/filter-lower-basic.markdown") },
    .{ .name = "filter-map-basic", .template = @embedFile("fixtures/filter-map-basic.knap"), .data = @embedFile("fixtures/filter-map-basic.json"), .expected = @embedFile("fixtures/filter-map-basic.markdown") },
    .{ .name = "filter-math-basic", .template = @embedFile("fixtures/filter-math-basic.knap"), .data = @embedFile("fixtures/filter-math-basic.json"), .expected = @embedFile("fixtures/filter-math-basic.markdown") },
    .{ .name = "filter-math-multiline", .template = @embedFile("fixtures/filter-math-multiline.knap"), .data = @embedFile("fixtures/filter-math-multiline.json"), .expected = @embedFile("fixtures/filter-math-multiline.markdown") },
    .{ .name = "filter-math_block-basic", .template = @embedFile("fixtures/filter-math_block-basic.knap"), .data = @embedFile("fixtures/filter-math_block-basic.json"), .expected = @embedFile("fixtures/filter-math_block-basic.markdown") },
    .{ .name = "filter-merge-args", .template = @embedFile("fixtures/filter-merge-args.knap"), .data = @embedFile("fixtures/filter-merge-args.json"), .expected = @embedFile("fixtures/filter-merge-args.markdown") },
    .{ .name = "filter-merge-basic", .template = @embedFile("fixtures/filter-merge-basic.knap"), .data = @embedFile("fixtures/filter-merge-basic.json"), .expected = @embedFile("fixtures/filter-merge-basic.markdown") },
    .{ .name = "filter-nth-args", .template = @embedFile("fixtures/filter-nth-args.knap"), .data = @embedFile("fixtures/filter-nth-args.json"), .expected = @embedFile("fixtures/filter-nth-args.markdown") },
    .{ .name = "filter-nth-basic", .template = @embedFile("fixtures/filter-nth-basic.knap"), .data = @embedFile("fixtures/filter-nth-basic.json"), .expected = @embedFile("fixtures/filter-nth-basic.markdown") },
    .{ .name = "filter-number_format-basic", .template = @embedFile("fixtures/filter-number_format-basic.knap"), .data = @embedFile("fixtures/filter-number_format-basic.json"), .expected = @embedFile("fixtures/filter-number_format-basic.markdown") },
    .{ .name = "filter-numbered-basic", .template = @embedFile("fixtures/filter-numbered-basic.knap"), .data = @embedFile("fixtures/filter-numbered-basic.json"), .expected = @embedFile("fixtures/filter-numbered-basic.markdown") },
    .{ .name = "filter-numbered-nested", .template = @embedFile("fixtures/filter-numbered-nested.knap"), .data = @embedFile("fixtures/filter-numbered-nested.json"), .expected = @embedFile("fixtures/filter-numbered-nested.markdown") },
    .{ .name = "filter-object-args", .template = @embedFile("fixtures/filter-object-args.knap"), .data = @embedFile("fixtures/filter-object-args.json"), .expected = @embedFile("fixtures/filter-object-args.markdown") },
    .{ .name = "filter-object-basic", .template = @embedFile("fixtures/filter-object-basic.knap"), .data = @embedFile("fixtures/filter-object-basic.json"), .expected = @embedFile("fixtures/filter-object-basic.markdown") },
    .{ .name = "filter-parse_json-basic", .template = @embedFile("fixtures/filter-parse_json-basic.knap"), .data = @embedFile("fixtures/filter-parse_json-basic.json"), .expected = @embedFile("fixtures/filter-parse_json-basic.markdown") },
    .{ .name = "filter-pascal-basic", .template = @embedFile("fixtures/filter-pascal-basic.knap"), .data = @embedFile("fixtures/filter-pascal-basic.json"), .expected = @embedFile("fixtures/filter-pascal-basic.markdown") },
    .{ .name = "filter-remove_attr-args", .template = @embedFile("fixtures/filter-remove_attr-args.knap"), .data = @embedFile("fixtures/filter-remove_attr-args.json"), .expected = @embedFile("fixtures/filter-remove_attr-args.markdown") },
    .{ .name = "filter-remove_attr-basic", .template = @embedFile("fixtures/filter-remove_attr-basic.knap"), .data = @embedFile("fixtures/filter-remove_attr-basic.json"), .expected = @embedFile("fixtures/filter-remove_attr-basic.markdown") },
    .{ .name = "filter-remove_tags-args", .template = @embedFile("fixtures/filter-remove_tags-args.knap"), .data = @embedFile("fixtures/filter-remove_tags-args.json"), .expected = @embedFile("fixtures/filter-remove_tags-args.markdown") },
    .{ .name = "filter-remove_tags-basic", .template = @embedFile("fixtures/filter-remove_tags-basic.knap"), .data = @embedFile("fixtures/filter-remove_tags-basic.json"), .expected = @embedFile("fixtures/filter-remove_tags-basic.markdown") },
    .{ .name = "filter-replace-basic", .template = @embedFile("fixtures/filter-replace-basic.knap"), .data = @embedFile("fixtures/filter-replace-basic.json"), .expected = @embedFile("fixtures/filter-replace-basic.markdown") },
    .{ .name = "filter-replace_tags-args", .template = @embedFile("fixtures/filter-replace_tags-args.knap"), .data = @embedFile("fixtures/filter-replace_tags-args.json"), .expected = @embedFile("fixtures/filter-replace_tags-args.markdown") },
    .{ .name = "filter-replace_tags-basic", .template = @embedFile("fixtures/filter-replace_tags-basic.knap"), .data = @embedFile("fixtures/filter-replace_tags-basic.json"), .expected = @embedFile("fixtures/filter-replace_tags-basic.markdown") },
    .{ .name = "filter-reverse-basic", .template = @embedFile("fixtures/filter-reverse-basic.knap"), .data = @embedFile("fixtures/filter-reverse-basic.json"), .expected = @embedFile("fixtures/filter-reverse-basic.markdown") },
    .{ .name = "filter-round-basic", .template = @embedFile("fixtures/filter-round-basic.knap"), .data = @embedFile("fixtures/filter-round-basic.json"), .expected = @embedFile("fixtures/filter-round-basic.markdown") },
    .{ .name = "filter-safe_name-args", .template = @embedFile("fixtures/filter-safe_name-args.knap"), .data = @embedFile("fixtures/filter-safe_name-args.json"), .expected = @embedFile("fixtures/filter-safe_name-args.markdown") },
    .{ .name = "filter-safe_name-basic", .template = @embedFile("fixtures/filter-safe_name-basic.knap"), .data = @embedFile("fixtures/filter-safe_name-basic.json"), .expected = @embedFile("fixtures/filter-safe_name-basic.markdown") },
    .{ .name = "filter-slice-args", .template = @embedFile("fixtures/filter-slice-args.knap"), .data = @embedFile("fixtures/filter-slice-args.json"), .expected = @embedFile("fixtures/filter-slice-args.markdown") },
    .{ .name = "filter-slice-basic", .template = @embedFile("fixtures/filter-slice-basic.knap"), .data = @embedFile("fixtures/filter-slice-basic.json"), .expected = @embedFile("fixtures/filter-slice-basic.markdown") },
    .{ .name = "filter-snake-basic", .template = @embedFile("fixtures/filter-snake-basic.knap"), .data = @embedFile("fixtures/filter-snake-basic.json"), .expected = @embedFile("fixtures/filter-snake-basic.markdown") },
    .{ .name = "filter-sort-args", .template = @embedFile("fixtures/filter-sort-args.knap"), .data = @embedFile("fixtures/filter-sort-args.json"), .expected = @embedFile("fixtures/filter-sort-args.markdown") },
    .{ .name = "filter-sort-basic", .template = @embedFile("fixtures/filter-sort-basic.knap"), .data = @embedFile("fixtures/filter-sort-basic.json"), .expected = @embedFile("fixtures/filter-sort-basic.markdown") },
    .{ .name = "filter-split-args", .template = @embedFile("fixtures/filter-split-args.knap"), .data = @embedFile("fixtures/filter-split-args.json"), .expected = @embedFile("fixtures/filter-split-args.markdown") },
    .{ .name = "filter-split-basic", .template = @embedFile("fixtures/filter-split-basic.knap"), .data = @embedFile("fixtures/filter-split-basic.json"), .expected = @embedFile("fixtures/filter-split-basic.markdown") },
    .{ .name = "filter-strike-basic", .template = @embedFile("fixtures/filter-strike-basic.knap"), .data = @embedFile("fixtures/filter-strike-basic.json"), .expected = @embedFile("fixtures/filter-strike-basic.markdown") },
    .{ .name = "filter-strip_attr-args", .template = @embedFile("fixtures/filter-strip_attr-args.knap"), .data = @embedFile("fixtures/filter-strip_attr-args.json"), .expected = @embedFile("fixtures/filter-strip_attr-args.markdown") },
    .{ .name = "filter-strip_attr-basic", .template = @embedFile("fixtures/filter-strip_attr-basic.knap"), .data = @embedFile("fixtures/filter-strip_attr-basic.json"), .expected = @embedFile("fixtures/filter-strip_attr-basic.markdown") },
    .{ .name = "filter-strip_md-basic", .template = @embedFile("fixtures/filter-strip_md-basic.knap"), .data = @embedFile("fixtures/filter-strip_md-basic.json"), .expected = @embedFile("fixtures/filter-strip_md-basic.markdown") },
    .{ .name = "filter-strip_tags-args", .template = @embedFile("fixtures/filter-strip_tags-args.knap"), .data = @embedFile("fixtures/filter-strip_tags-args.json"), .expected = @embedFile("fixtures/filter-strip_tags-args.markdown") },
    .{ .name = "filter-strip_tags-basic", .template = @embedFile("fixtures/filter-strip_tags-basic.knap"), .data = @embedFile("fixtures/filter-strip_tags-basic.json"), .expected = @embedFile("fixtures/filter-strip_tags-basic.markdown") },
    .{ .name = "filter-stripmd-basic", .template = @embedFile("fixtures/filter-stripmd-basic.knap"), .data = @embedFile("fixtures/filter-stripmd-basic.json"), .expected = @embedFile("fixtures/filter-stripmd-basic.markdown") },
    .{ .name = "filter-sum-args", .template = @embedFile("fixtures/filter-sum-args.knap"), .data = @embedFile("fixtures/filter-sum-args.json"), .expected = @embedFile("fixtures/filter-sum-args.markdown") },
    .{ .name = "filter-sum-basic", .template = @embedFile("fixtures/filter-sum-basic.knap"), .data = @embedFile("fixtures/filter-sum-basic.json"), .expected = @embedFile("fixtures/filter-sum-basic.markdown") },
    .{ .name = "filter-table-basic", .template = @embedFile("fixtures/filter-table-basic.knap"), .data = @embedFile("fixtures/filter-table-basic.json"), .expected = @embedFile("fixtures/filter-table-basic.markdown") },
    .{ .name = "filter-table_pretty-basic", .template = @embedFile("fixtures/filter-table_pretty-basic.knap"), .data = @embedFile("fixtures/filter-table_pretty-basic.json"), .expected = @embedFile("fixtures/filter-table_pretty-basic.markdown") },
    .{ .name = "filter-template-basic", .template = @embedFile("fixtures/filter-template-basic.knap"), .data = @embedFile("fixtures/filter-template-basic.json"), .expected = @embedFile("fixtures/filter-template-basic.markdown") },
    .{ .name = "filter-title-basic", .template = @embedFile("fixtures/filter-title-basic.knap"), .data = @embedFile("fixtures/filter-title-basic.json"), .expected = @embedFile("fixtures/filter-title-basic.markdown") },
    .{ .name = "filter-trim-basic", .template = @embedFile("fixtures/filter-trim-basic.knap"), .data = @embedFile("fixtures/filter-trim-basic.json"), .expected = @embedFile("fixtures/filter-trim-basic.markdown") },
    .{ .name = "filter-truncate-args", .template = @embedFile("fixtures/filter-truncate-args.knap"), .data = @embedFile("fixtures/filter-truncate-args.json"), .expected = @embedFile("fixtures/filter-truncate-args.markdown") },
    .{ .name = "filter-truncate-basic", .template = @embedFile("fixtures/filter-truncate-basic.knap"), .data = @embedFile("fixtures/filter-truncate-basic.json"), .expected = @embedFile("fixtures/filter-truncate-basic.markdown") },
    .{ .name = "filter-truncatewords-args", .template = @embedFile("fixtures/filter-truncatewords-args.knap"), .data = @embedFile("fixtures/filter-truncatewords-args.json"), .expected = @embedFile("fixtures/filter-truncatewords-args.markdown") },
    .{ .name = "filter-truncatewords-basic", .template = @embedFile("fixtures/filter-truncatewords-basic.knap"), .data = @embedFile("fixtures/filter-truncatewords-basic.json"), .expected = @embedFile("fixtures/filter-truncatewords-basic.markdown") },
    .{ .name = "filter-uncamel-basic", .template = @embedFile("fixtures/filter-uncamel-basic.knap"), .data = @embedFile("fixtures/filter-uncamel-basic.json"), .expected = @embedFile("fixtures/filter-uncamel-basic.markdown") },
    .{ .name = "filter-unescape-basic", .template = @embedFile("fixtures/filter-unescape-basic.knap"), .data = @embedFile("fixtures/filter-unescape-basic.json"), .expected = @embedFile("fixtures/filter-unescape-basic.markdown") },
    .{ .name = "filter-unique-basic", .template = @embedFile("fixtures/filter-unique-basic.knap"), .data = @embedFile("fixtures/filter-unique-basic.json"), .expected = @embedFile("fixtures/filter-unique-basic.markdown") },
    .{ .name = "filter-upper-basic", .template = @embedFile("fixtures/filter-upper-basic.knap"), .data = @embedFile("fixtures/filter-upper-basic.json"), .expected = @embedFile("fixtures/filter-upper-basic.markdown") },
    .{ .name = "filter-where-args", .template = @embedFile("fixtures/filter-where-args.knap"), .data = @embedFile("fixtures/filter-where-args.json"), .expected = @embedFile("fixtures/filter-where-args.markdown") },
    .{ .name = "filter-where-basic", .template = @embedFile("fixtures/filter-where-basic.knap"), .data = @embedFile("fixtures/filter-where-basic.json"), .expected = @embedFile("fixtures/filter-where-basic.markdown") },
    .{ .name = "filter-wikilink-args", .template = @embedFile("fixtures/filter-wikilink-args.knap"), .data = @embedFile("fixtures/filter-wikilink-args.json"), .expected = @embedFile("fixtures/filter-wikilink-args.markdown") },
    .{ .name = "filter-wikilink-basic", .template = @embedFile("fixtures/filter-wikilink-basic.knap"), .data = @embedFile("fixtures/filter-wikilink-basic.json"), .expected = @embedFile("fixtures/filter-wikilink-basic.markdown") },
    .{ .name = "filter-wikilink-object", .template = @embedFile("fixtures/filter-wikilink-object.knap"), .data = @embedFile("fixtures/filter-wikilink-object.json"), .expected = @embedFile("fixtures/filter-wikilink-object.markdown") },
    .{ .name = "filter-yaml-basic", .template = @embedFile("fixtures/filter-yaml-basic.knap"), .data = @embedFile("fixtures/filter-yaml-basic.json"), .expected = @embedFile("fixtures/filter-yaml-basic.markdown") },
    .{ .name = "filter-yaml_property-basic", .template = @embedFile("fixtures/filter-yaml_property-basic.knap"), .data = @embedFile("fixtures/filter-yaml_property-basic.json"), .expected = @embedFile("fixtures/filter-yaml_property-basic.markdown") },
    .{ .name = "lit-string-escapes", .template = @embedFile("fixtures/lit-string-escapes.knap"), .data = @embedFile("fixtures/lit-string-escapes.json"), .expected = @embedFile("fixtures/lit-string-escapes.markdown") },
    .{ .name = "logic-and-or-parens", .template = @embedFile("fixtures/logic-and-or-parens.knap"), .data = @embedFile("fixtures/logic-and-or-parens.json"), .expected = @embedFile("fixtures/logic-and-or-parens.markdown") },
    .{ .name = "logic-contains-array", .template = @embedFile("fixtures/logic-contains-array.knap"), .data = @embedFile("fixtures/logic-contains-array.json"), .expected = @embedFile("fixtures/logic-contains-array.markdown") },
    .{ .name = "logic-contains-object", .template = @embedFile("fixtures/logic-contains-object.knap"), .data = @embedFile("fixtures/logic-contains-object.json"), .expected = @embedFile("fixtures/logic-contains-object.markdown") },
    .{ .name = "logic-contains-string", .template = @embedFile("fixtures/logic-contains-string.knap"), .data = @embedFile("fixtures/logic-contains-string.json"), .expected = @embedFile("fixtures/logic-contains-string.markdown") },
    .{ .name = "logic-else", .template = @embedFile("fixtures/logic-else.knap"), .data = @embedFile("fixtures/logic-else.json"), .expected = @embedFile("fixtures/logic-else.markdown") },
    .{ .name = "logic-elseif", .template = @embedFile("fixtures/logic-elseif.knap"), .data = @embedFile("fixtures/logic-elseif.json"), .expected = @embedFile("fixtures/logic-elseif.markdown") },
    .{ .name = "logic-eq-array-nested", .template = @embedFile("fixtures/logic-eq-array-nested.knap"), .data = @embedFile("fixtures/logic-eq-array-nested.json"), .expected = @embedFile("fixtures/logic-eq-array-nested.markdown") },
    .{ .name = "logic-eq-length-mismatch", .template = @embedFile("fixtures/logic-eq-length-mismatch.knap"), .data = @embedFile("fixtures/logic-eq-length-mismatch.json"), .expected = @embedFile("fixtures/logic-eq-length-mismatch.markdown") },
    .{ .name = "logic-eq-object-order", .template = @embedFile("fixtures/logic-eq-object-order.knap"), .data = @embedFile("fixtures/logic-eq-object-order.json"), .expected = @embedFile("fixtures/logic-eq-object-order.markdown") },
    .{ .name = "logic-eq-reflexive", .template = @embedFile("fixtures/logic-eq-reflexive.knap"), .data = @embedFile("fixtures/logic-eq-reflexive.json"), .expected = @embedFile("fixtures/logic-eq-reflexive.markdown") },
    .{ .name = "logic-if-true", .template = @embedFile("fixtures/logic-if-true.knap"), .data = @embedFile("fixtures/logic-if-true.json"), .expected = @embedFile("fixtures/logic-if-true.markdown") },
    .{ .name = "logic-neq-object", .template = @embedFile("fixtures/logic-neq-object.knap"), .data = @embedFile("fixtures/logic-neq-object.json"), .expected = @embedFile("fixtures/logic-neq-object.markdown") },
    .{ .name = "logic-not", .template = @embedFile("fixtures/logic-not.knap"), .data = @embedFile("fixtures/logic-not.json"), .expected = @embedFile("fixtures/logic-not.markdown") },
    .{ .name = "logic-truthiness", .template = @embedFile("fixtures/logic-truthiness.knap"), .data = @embedFile("fixtures/logic-truthiness.json"), .expected = @embedFile("fixtures/logic-truthiness.markdown") },
    .{ .name = "loop-basic", .template = @embedFile("fixtures/loop-basic.knap"), .data = @embedFile("fixtures/loop-basic.json"), .expected = @embedFile("fixtures/loop-basic.markdown") },
    .{ .name = "loop-empty", .template = @embedFile("fixtures/loop-empty.knap"), .data = @embedFile("fixtures/loop-empty.json"), .expected = @embedFile("fixtures/loop-empty.markdown") },
    .{ .name = "loop-nested", .template = @embedFile("fixtures/loop-nested.knap"), .data = @embedFile("fixtures/loop-nested.json"), .expected = @embedFile("fixtures/loop-nested.markdown") },
    .{ .name = "loop-values", .template = @embedFile("fixtures/loop-values.knap"), .data = @embedFile("fixtures/loop-values.json"), .expected = @embedFile("fixtures/loop-values.markdown") },
    .{ .name = "loop-var-named-loop", .template = @embedFile("fixtures/loop-var-named-loop.knap"), .data = @embedFile("fixtures/loop-var-named-loop.json"), .expected = @embedFile("fixtures/loop-var-named-loop.markdown") },
    .{ .name = "render-arg-resolves-to-object", .template = @embedFile("fixtures/render-arg-resolves-to-object.knap"), .data = @embedFile("fixtures/render-arg-resolves-to-object.json"), .expected = @embedFile("fixtures/render-arg-resolves-to-object.markdown") },
    .{ .name = "render-bad-args-link-missing", .template = @embedFile("fixtures/render-bad-args-link-missing.knap"), .data = "{}", .expected = @embedFile("fixtures/render-bad-args-link-missing.markdown") },
    .{ .name = "render-deep-list", .template = @embedFile("fixtures/render-deep-list.knap"), .data = @embedFile("fixtures/render-deep-list.json"), .expected = @embedFile("fixtures/render-deep-list.markdown") },
    .{ .name = "render-link-angle-url", .template = @embedFile("fixtures/render-link-angle-url.knap"), .data = "{}", .expected = @embedFile("fixtures/render-link-angle-url.markdown") },
    .{ .name = "render-link-control-char", .template = @embedFile("fixtures/render-link-control-char.knap"), .data = @embedFile("fixtures/render-link-control-char.json"), .expected = @embedFile("fixtures/render-link-control-char.markdown") },
    .{ .name = "render-link-missing-arg", .template = @embedFile("fixtures/render-link-missing-arg.knap"), .data = @embedFile("fixtures/render-link-missing-arg.json"), .expected = @embedFile("fixtures/render-link-missing-arg.markdown") },
    .{ .name = "render-link-scheme-colon-entity", .template = @embedFile("fixtures/render-link-scheme-colon-entity.knap"), .data = "{}", .expected = @embedFile("fixtures/render-link-scheme-colon-entity.markdown") },
    .{ .name = "render-link-scheme-data", .template = @embedFile("fixtures/render-link-scheme-data.knap"), .data = "{}", .expected = @embedFile("fixtures/render-link-scheme-data.markdown") },
    .{ .name = "render-link-scheme-entity", .template = @embedFile("fixtures/render-link-scheme-entity.knap"), .data = "{}", .expected = @embedFile("fixtures/render-link-scheme-entity.markdown") },
    .{ .name = "render-link-scheme-from-data", .template = @embedFile("fixtures/render-link-scheme-from-data.knap"), .data = @embedFile("fixtures/render-link-scheme-from-data.json"), .expected = @embedFile("fixtures/render-link-scheme-from-data.markdown") },
    .{ .name = "render-link-scheme-hex-entity", .template = @embedFile("fixtures/render-link-scheme-hex-entity.knap"), .data = "{}", .expected = @embedFile("fixtures/render-link-scheme-hex-entity.markdown") },
    .{ .name = "render-link-scheme-javascript", .template = @embedFile("fixtures/render-link-scheme-javascript.knap"), .data = "{}", .expected = @embedFile("fixtures/render-link-scheme-javascript.markdown") },
    .{ .name = "render-multiline-bold", .template = @embedFile("fixtures/render-multiline-bold.knap"), .data = @embedFile("fixtures/render-multiline-bold.json"), .expected = @embedFile("fixtures/render-multiline-bold.markdown") },
    .{ .name = "render-nonarray-list", .template = @embedFile("fixtures/render-nonarray-list.knap"), .data = @embedFile("fixtures/render-nonarray-list.json"), .expected = @embedFile("fixtures/render-nonarray-list.markdown") },
    .{ .name = "render-ragged-table", .template = @embedFile("fixtures/render-ragged-table.knap"), .data = @embedFile("fixtures/render-ragged-table.json"), .expected = @embedFile("fixtures/render-ragged-table.markdown") },
    .{ .name = "unicode-data", .template = @embedFile("fixtures/unicode-data.knap"), .data = @embedFile("fixtures/unicode-data.json"), .expected = @embedFile("fixtures/unicode-data.markdown") },
    .{ .name = "var-bracket-index", .template = @embedFile("fixtures/var-bracket-index.knap"), .data = @embedFile("fixtures/var-bracket-index.json"), .expected = @embedFile("fixtures/var-bracket-index.markdown") },
    .{ .name = "var-bracket-key", .template = @embedFile("fixtures/var-bracket-key.knap"), .data = @embedFile("fixtures/var-bracket-key.json"), .expected = @embedFile("fixtures/var-bracket-key.markdown") },
    .{ .name = "var-dotted", .template = @embedFile("fixtures/var-dotted.knap"), .data = @embedFile("fixtures/var-dotted.json"), .expected = @embedFile("fixtures/var-dotted.markdown") },
    .{ .name = "var-float-large", .template = @embedFile("fixtures/var-float-large.knap"), .data = @embedFile("fixtures/var-float-large.json"), .expected = @embedFile("fixtures/var-float-large.markdown") },
    .{ .name = "var-json-object", .template = @embedFile("fixtures/var-json-object.knap"), .data = @embedFile("fixtures/var-json-object.json"), .expected = @embedFile("fixtures/var-json-object.markdown") },
    .{ .name = "var-missing", .template = @embedFile("fixtures/var-missing.knap"), .data = @embedFile("fixtures/var-missing.json"), .expected = @embedFile("fixtures/var-missing.markdown") },
    .{ .name = "var-number", .template = @embedFile("fixtures/var-number.knap"), .data = @embedFile("fixtures/var-number.json"), .expected = @embedFile("fixtures/var-number.markdown") },
    .{ .name = "var-plain", .template = @embedFile("fixtures/var-plain.knap"), .data = @embedFile("fixtures/var-plain.json"), .expected = @embedFile("fixtures/var-plain.markdown") },
    .{ .name = "var-spaces-name", .template = @embedFile("fixtures/var-spaces-name.knap"), .data = @embedFile("fixtures/var-spaces-name.json"), .expected = @embedFile("fixtures/var-spaces-name.markdown") },
};

const ErrorCase = struct {
    name: []const u8,
    template: []const u8,
    data: ?[]const u8 = null,
    message: []const u8,
};

const error_cases = [_]ErrorCase{
    .{ .name = "err-bad-args-extra", .template = @embedFile("fixtures/errors/err-bad-args-extra.knap"), .data = null, .message = @embedFile("fixtures/errors/err-bad-args-extra.error") },
    .{ .name = "err-cond-and-chain", .template = @embedFile("fixtures/errors/err-cond-and-chain.knap"), .data = null, .message = @embedFile("fixtures/errors/err-cond-and-chain.error") },
    .{ .name = "err-cond-depth-boundary", .template = @embedFile("fixtures/errors/err-cond-depth-boundary.knap"), .data = null, .message = @embedFile("fixtures/errors/err-cond-depth-boundary.error") },
    .{ .name = "err-cond-not-chain", .template = @embedFile("fixtures/errors/err-cond-not-chain.knap"), .data = null, .message = @embedFile("fixtures/errors/err-cond-not-chain.error") },
    .{ .name = "err-deep-serialize", .template = @embedFile("fixtures/errors/err-deep-serialize.knap"), .data = @embedFile("fixtures/errors/err-deep-serialize.json"), .message = @embedFile("fixtures/errors/err-deep-serialize.error") },
    .{ .name = "err-if-missing-value", .template = @embedFile("fixtures/errors/err-if-missing-value.knap"), .data = null, .message = @embedFile("fixtures/errors/err-if-missing-value.error") },
    .{ .name = "err-loop-nonarray", .template = @embedFile("fixtures/errors/err-loop-nonarray.knap"), .data = @embedFile("fixtures/errors/err-loop-nonarray.json"), .message = @embedFile("fixtures/errors/err-loop-nonarray.error") },
    .{ .name = "err-nesting-too-deep", .template = @embedFile("fixtures/errors/err-nesting-too-deep.knap"), .data = null, .message = @embedFile("fixtures/errors/err-nesting-too-deep.error") },
    .{ .name = "err-stray-endfor", .template = @embedFile("fixtures/errors/err-stray-endfor.knap"), .data = null, .message = @embedFile("fixtures/errors/err-stray-endfor.error") },
    .{ .name = "err-stray-endif", .template = @embedFile("fixtures/errors/err-stray-endif.knap"), .data = null, .message = @embedFile("fixtures/errors/err-stray-endif.error") },
    .{ .name = "err-unclosed-comment", .template = @embedFile("fixtures/errors/err-unclosed-comment.knap"), .data = null, .message = @embedFile("fixtures/errors/err-unclosed-comment.error") },
    .{ .name = "err-unclosed-for", .template = @embedFile("fixtures/errors/err-unclosed-for.knap"), .data = null, .message = @embedFile("fixtures/errors/err-unclosed-for.error") },
    .{ .name = "err-unclosed-if", .template = @embedFile("fixtures/errors/err-unclosed-if.knap"), .data = null, .message = @embedFile("fixtures/errors/err-unclosed-if.error") },
    .{ .name = "err-unclosed-output", .template = @embedFile("fixtures/errors/err-unclosed-output.knap"), .data = null, .message = @embedFile("fixtures/errors/err-unclosed-output.error") },
    .{ .name = "err-unknown-filter", .template = @embedFile("fixtures/errors/err-unknown-filter.knap"), .data = null, .message = @embedFile("fixtures/errors/err-unknown-filter.error") },
    .{ .name = "err-value-depth", .template = @embedFile("fixtures/errors/err-value-depth.knap"), .data = @embedFile("fixtures/errors/err-value-depth.json"), .message = @embedFile("fixtures/errors/err-value-depth.error") },
};

/// Parse `data_json` and render `template` against it. The diagnostic
/// must be reused when checking `d.message` on the error path.
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
        try testing.expectEqual(error.Template, e);
        testing.expect(std.mem.indexOf(u8, d.message, needle) != null) catch |e2| {
            std.debug.print("expected diagnostic containing '{s}', got '{s}'\n", .{ needle, d.message });
            return e2;
        };
    }
}

fn renderLimit(
    template: []const u8,
    data_json: []const u8,
    d: *kt.Diagnostic,
    arena: std.mem.Allocator,
    max: usize,
) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data_json, .{});
    return kt.renderWithLimit(arena, template, parsed, d, max);
}

fn renderLimitOk(template: []const u8, data_json: []const u8, max: usize, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const out = try renderLimit(template, data_json, &d, arena_state.allocator(), max);
    try testing.expectEqualStrings(expected, out);
}

fn renderLimitErr(template: []const u8, data_json: []const u8, max: usize, needle: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var d = kt.Diagnostic{};
    const res = renderLimit(template, data_json, &d, arena_state.allocator(), max);
    if (res) |out| {
        std.debug.print("expected limit error, got {d} bytes:\n{s}\n", .{ out.len, out[0..@min(64, out.len)] });
        return error.TestExpectedError;
    } else |e| {
        try testing.expectEqual(error.Template, e);
        try testing.expect(std.mem.indexOf(u8, d.message, needle) != null);
    }
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

// oliver differs from markdown only on `comment` — Oliver ≥1.3 parses
// `==…==`, `$…$`/`$$…$$` natively, so the markers are knap-faithful in
// both formats now. `comment` keeps `<!-- -->` because a `%%` block only
// opens at line start; those fixtures intentionally drift.
const oliver_drift_names = [_][]const u8{
    "filter-comment-basic", "filter-comment-multiline",
};

test "corpus: oliver format renders without drift where the output has no extension filters" {
    // The oliver format only differs from markdown on `comment`'s
    // HTML passthrough; the corpus must render identically under it.
    var failures: usize = 0;
    outer: for (cases) |c| {
        for (oliver_drift_names) |dn| {
            if (std.mem.eql(u8, c.name, dn)) continue :outer;
        }
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, c.data, .{});
        var d = kt.Diagnostic{};
        if (kt.renderFormat(arena, c.template, parsed, &d, .oliver)) |out| {
            if (!std.mem.eql(u8, out, c.expected)) {
                std.debug.print("oliver fixture '{s}': byte mismatch\nexpected: {s}\nactual: {s}\n", .{ c.name, c.expected, out });
                failures += 1;
            }
        } else |e| {
            std.debug.print("oliver fixture '{s}': error {s}: {s}\n", .{ c.name, @errorName(e), d.message });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "corpus: error cases produce the pinned message" {
    var failures: usize = 0;
    for (error_cases) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var d = kt.Diagnostic{};
        const res = renderCase(arena_state.allocator(), c.template, c.data orelse "{}", &d);
        if (res) |out| {
            std.debug.print("error fixture '{s}': expected error, got output\n{s}\n", .{ c.name, out });
            failures += 1;
        } else |e| {
            if (e != error.Template) {
                std.debug.print("error fixture '{s}': expected error.Template, got {s}\n", .{ c.name, @errorName(e) });
                failures += 1;
            } else if (!std.mem.eql(u8, d.message, c.message)) {
                std.debug.print("error fixture '{s}': message drift\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ c.name, c.message, d.message });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "property: every registered filter has a fixture" {
    try expectNormalEngine();
    var missing: usize = 0;
    outer: for (kt.filters.registry()) |name| {
        for (kt.filters.pending) |pend| {
            if (std.mem.eql(u8, pend, name)) continue :outer;
        }
        for (kt.filters.blocked_names) |b| {
            if (std.mem.eql(u8, b, name)) continue :outer;
        }
        var found = false;
        for (cases) |c| {
            const needle = std.fmt.allocPrint(testing.allocator, "| {s}", .{name}) catch continue;
            defer testing.allocator.free(needle);
            if (std.mem.indexOf(u8, c.template, needle) != null) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("no fixture covers filter '{s}'\n", .{name});
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "property: no fixture output equals its template" {
    // Catches the passthrough mutant: a real engine never echoes the raw
    // template for a corpus that covers every construct.
    var identical: usize = 0;
    for (cases) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var d = kt.Diagnostic{};
        const out = renderCase(arena_state.allocator(), c.template, c.data, &d) catch continue;
        if (std.mem.eql(u8, out, c.template)) {
            std.debug.print("fixture '{s}': output equals template\n", .{c.name});
            identical += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), identical);
}

test "corpus: fixture corpus lints clean" {
    try expectNormalEngine();
    var dirty: usize = 0;
    for (cases) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var d = kt.Diagnostic{};
        const findings = kt.lintDocument(arena_state.allocator(), c.template, &d) catch |e| {
            std.debug.print("lint '{s}': unexpected failure {s}\n", .{ c.name, @errorName(e) });
            dirty += 1;
            continue;
        };
        if (findings.len > 0) {
            for (findings) |f| {
                std.debug.print("lint '{s}': [{s}] {s} at {d}:{d}\n", .{ c.name, f.rule, f.detail, f.line, f.column });
            }
            dirty += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), dirty);
}

// --------------------------------------------------------------------
// Unit tests — semantics the corpus does not already pin.

test "unit: set assigns in order and shadows data" {
    try renderOk("{% set x = 1 %}{{ x }}", "{}", "1");
    try renderOk("{% set x = 1 %}{% set x = 2 %}{{ x }}", "{}", "2");
    try renderOk("{% set x = y %}{{ x }}", "{\"y\":\"data\"}", "data");
    try renderOk("{% set x = 9 %}{{ x }}", "{\"x\":\"orig\"}", "9");
}

test "unit: if-leak set and loop-scoped set" {
    try renderOk("{% if t %}{% set x = \"in\" %}{% endif %}[{{ x }}]", "{\"t\":true}", "[in]");
    try renderOk("{% for i in xs %}{% set x = i %}{{ x }}{% endfor %}|{{ x }}", "{\"xs\":[\"a\",\"b\"],\"x\":\"out\"}", "a\nb|out");
}

test "unit: fallback chooses the first truthy value" {
    try renderOk("{{ a ?? \"X\" }}", "{}", "X");
    try renderOk("{{ a ?? \"X\" }}", "{\"a\":\"v\"}", "v");
    try renderOk("{{ a ?? \"X\" }}", "{\"a\":0}", "X");
    try renderOk("{{ a ?? \"X\" }}", "{\"a\":\"\"}", "X");
    try renderOk("{{ a ?? \"X\" }}", "{\"a\":[]}", "X");
    try renderOk("{{ a ?? b ?? \"X\" }}", "{\"b\":0}", "X");
}

test "unit: fallback binds looser than filters" {
    try renderOk("{{ x | bold ?? \"none\" }}", "{\"x\":\"v\"}", "**v**");
}

test "unit: item_index is the 0-based loop counter" {
    try renderOk("{% for i in xs %}{{ i_index }}:{{ loop.index0 }}:{{ loop.index }}:{{ loop.first }}:{{ loop.last }};{% endfor %}", "{\"xs\":[\"a\",\"b\"]}", "0:0:1:true:false;\n1:1:2:false:true;");
}

test "unit: dynamic bracket access" {
    try renderOk("{% for i in xs %}{{ xs[loop.index0] }};{% endfor %}", "{\"xs\":[\"a\",\"b\"]}", "a;\nb;");
    try renderOk("{% for k in ks %}{{ obj[k] }};{% endfor %}", "{\"ks\":[\"a\",\"b\"],\"obj\":{\"a\":1,\"b\":2}}", "1;\n2;");
}

test "unit: container equality is identity" {
    try renderOk("{% if a == b %}EQ{% else %}NE{% endif %}", "{\"a\":[1],\"b\":[1]}", "NE");
    try renderOk("{% if a == a %}EQ{% else %}NE{% endif %}", "{\"a\":[1]}", "EQ");
    try renderOk("{% if a != b %}NE{% else %}EQ{% endif %}", "{\"a\":{},\"b\":{}}", "NE");
}

test "unit: contains is SameValueZero" {
    try renderOk("{% if xs contains 1 %}Y{% else %}N{% endif %}", "{\"xs\":[1,2]}", "Y");
    try renderOk("{% if xs contains s %}Y{% else %}N{% endif %}", "{\"xs\":[\"a\"],\"s\":\"a\"}", "Y");
    try renderOk("{% if xs contains o %}Y{% else %}N{% endif %}", "{\"xs\":[{\"k\":1}],\"o\":{\"k\":1}}", "N");
}

test "unit: JavaScript number rendering" {
    try renderOk("{{ x }}", "{\"x\":1e308}", "1e+308");
    try renderOk("{{ x }}", "{\"x\":0.000001}", "0.000001");
    try renderOk("{{ x }}", "{\"x\":1e-7}", "1e-7");
    try renderOk("{{ x }}", "{\"x\":0.30000000000000004}", "0.30000000000000004");
    try renderOk("{{ x }}", "{\"x\":-0.5}", "-0.5");
}

test "unit: singleton primitive arrays unwrap" {
    try renderOk("{{ xs }}", "{\"xs\":[\"a\"]}", "a");
    try renderOk("{{ xs }}", "{\"xs\":[1]}", "1");
    try renderOk("{{ xs }}", "{\"xs\":[{\"k\":1}]}", "[{\"k\":1}]");
    try renderOk("{{ xs }}", "{\"xs\":[[1]]}", "[[1]]");
    try renderOk("{{ xs }}", "{\"xs\":[null]}", "[null]");
}

test "unit: loop over non-array is a render error" {
    try renderErr("{% for x in s %}a{% endfor %}", "{\"s\":\"abc\"}", "for-loop expects an array");
    try renderErr("{% for x in o %}a{% endfor %}", "{\"o\":{\"k\":1}}", "for-loop expects an array");
}

test "unit: missing and null loop collections are empty" {
    try renderOk("A{% for x in missing %}b{% endfor %}Z", "{}", "AZ");
    try renderOk("A{% for x in n %}b{% endfor %}Z", "{\"n\":null}", "AZ");
}

test "unit: dash whitespace-control syntax is rejected" {
    try renderErr("{{- x -}}", "{\"x\":1}", "expected a variable name");
    try renderErr("{%- if x -%}a{%- endif -%}", "{\"x\":true}", "empty logic tag");
}

test "unit: blocked host filters error at render" {
    try renderErr("{{ x | html_to_json }}", "{\"x\":\"<p>a</p>\"}", "not supported");
    try renderErr("{{ x | remove_html }}", "{\"x\":\"<p>a</p>\"}", "not supported");
}

test "unit: nested loops multiply against the output cap" {
    const template = "{% for a in xs %}{% for b in xs %}{{ a }}{{ b }};{% endfor %}{% endfor %}";
    try renderLimitErr(template, "{\"xs\":[1,2,3,4,5,6,7,8,9,0]}", 32, "output exceeded");
}

test "unit: the output cap is an exact ceiling" {
    try renderLimitOk("{{ x }}", "{\"x\":\"12345\"}", 5, "12345");
    try renderLimitErr("{{ x }}", "{\"x\":\"123456\"}", 5, "output exceeded");
}

test "unit: a zero output limit disables the cap" {
    try renderLimitOk("{% for a in xs %}{{ a }};{% endfor %}", "{\"xs\":[1,2,3]}", 0, "1;\n2;\n3;");
}
