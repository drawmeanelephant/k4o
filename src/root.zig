//! k4o: a Knap template engine that emits CommonMark (Oliver-targeted).
//!
//! Public API surface:
//!
//!     const kt = @import("k4o");
//!
//!     var d: kt.Diagnostic = .{};
//!     const out = try kt.render(arena, template_bytes, json_value, &d);

pub const diag = @import("diag.zig");
pub const parse = @import("parse.zig");
pub const filters = @import("filters.zig");
pub const engine = @import("engine.zig");
pub const lint = @import("lint.zig");
pub const init = @import("init.zig");

pub const Diagnostic = diag.Diagnostic;
pub const render = engine.render;
pub const renderWithLimit = engine.renderWithLimit;
pub const renderFormat = engine.renderFormat;
pub const renderFormatWithLimit = engine.renderFormatWithLimit;
pub const Format = engine.Format;
pub const default_max_output = engine.default_max_output;
pub const Error = engine.Error;
pub const lintDocument = lint.lintDocument;
pub const Finding = lint.Finding;
