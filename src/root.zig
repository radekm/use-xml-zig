//! use-xml: extract data from XML and detect data that was not used.
//!
//! Parse a document with `Document.parse`, walk it from `Document.root` with `Elem.child`,
//! `Elem.children`, `Elem.attr` and `Elem.text`, then call `Document.expectAllUsed` (or iterate
//! `Document.unused`) to find data you didn't read.
//!
//! Guide: `docs/en/guide.md`. API reference: `docs/en/api.md`.

const std = @import("std");

/// A parsed XML document; the entry point of the library.
pub const Document = @import("Document.zig");
/// An element of a document; has the extraction functions.
pub const Elem = @import("Elem.zig");
/// All errors of the extraction functions (each function returns only a subset, see `Elem`).
pub const Error = Elem.Error;
/// Description of the last error, see `Document.Options.diagnostics`.
pub const Diagnostics = @import("Diagnostics.zig");
/// Errors of `Document.parse`.
pub const ParseError = Document.ParseError;
/// A point in time in UTC with nanosecond precision.
pub const Timestamp = @import("Timestamp.zig");
/// Built-in value parsers, usable in custom parsers.
pub const parse = @import("parse.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("chars.zig");
    _ = @import("recording.zig");
    _ = @import("parser.zig");
    _ = @import("parser_test.zig");
    _ = @import("elem_test.zig");
    _ = @import("unused_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("Timestamp.zig");
    _ = @import("parse.zig");
}
