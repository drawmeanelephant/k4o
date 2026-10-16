//! mini-languages and yaml — knap 0.6.0 filter group.
//!
//! Stub: the registry knows these names; each renders an
//! unimplemented diagnostic until its batch lands (KNAP-FIDELITY.md).

const std = @import("std");
const filters = @import("../filters.zig");
const parse = @import("../parse.zig");

const Interp = filters.Interp;
const Value = filters.Value;
const Error = filters.Error;

pub const names = [_][]const u8{
    "map",
    "template",
    "replace",
    "yaml",
    "yaml_property",
};

pub fn apply(
    it: *Interp,
    call: parse.FilterCall,
    input: *const Value,
) Error!?*const Value {
    _ = input;
    for (names) |n| {
        if (std.mem.eql(u8, call.name, n)) {
            return filters.failAt(it, call.offset, "filter '{s}' is not implemented yet", .{call.name});
        }
    }
    return null;
}
