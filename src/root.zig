//! use-xml: extract data from XML and detect data that was not used.
//!
//! See `docs/en/api.md` for the API description.

const std = @import("std");

pub const Document = @import("Document.zig");
pub const Elem = @import("Elem.zig");
pub const Diagnostics = @import("Diagnostics.zig");
pub const ParseError = Document.ParseError;

test {
    std.testing.refAllDecls(@This());
    _ = @import("chars.zig");
    _ = @import("parser.zig");
    _ = @import("parser_test.zig");
}
