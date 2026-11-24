//! Description of the last error of `Document.parse`, of an extraction function or of
//! `Document.expectAllUsed`. Pass a pointer to it in `Document.Options.diagnostics`.
//!
//! Zig errors can't carry data, so the description is written here as text, into a buffer
//! given by the caller. It doesn't point into the input or the document, so it stays valid
//! after `Document.deinit` (as long as the buffer lives):
//!
//! ```zig
//! var diag_buf: [4096]u8 = undefined;
//! var diag: use_xml.Diagnostics = .init(&diag_buf);
//! var doc = try use_xml.Document.parse(gpa, input, .{ .diagnostics = &diag });
//! ```
//!
//! Every error returned by the library is recorded. Only the last one is kept; successful calls
//! don't change it, so read it right after an error. The `Diagnostics` value and its buffer must
//! stay alive and in place until `Document.deinit`, because the document writes into them.

const std = @import("std");

const Diagnostics = @This();

/// What went wrong. `none` means that no error was recorded.
kind: Kind = .none,
/// 1-based line of the error in the input; only for `invalid_xml`, otherwise 0.
line: u32 = 0,
/// 1-based column of the error (in code points); only for `invalid_xml`, otherwise 0.
column: u32 = 0,
/// The description didn't fit into the buffer and was cut.
truncated: bool = false,
/// Internal: the buffer given to `init` and the length of the description in it
/// (written by `recording.zig`).
buf: []u8 = &.{},
len: usize = 0,

/// Kinds of errors.
pub const Kind = enum {
    none,
    /// `error.InvalidXml` from `Document.parse`; `line` and `column` say where.
    invalid_xml,
    /// `error.Missing`: a required attribute or child element doesn't exist.
    missing,
    /// `error.TooMany`: more child elements than expected.
    too_many,
    /// `error.HasChildren`: text of an element with child elements.
    has_children,
    /// `error.AlreadyUsed`: the same attribute / child name / text was requested twice.
    already_used,
    /// `error.InvalidValue` or an error of a custom parser: the string is not a valid value.
    invalid_value,
    /// `error.UnusedData` from `expectAllUsed`; describes the first unused item.
    unused_data,
    /// The document's internal memory (the allocator passed to `Document.parse`) ran out,
    /// also during `Document.parse`.
    document_out_of_memory,
    /// Producing the value ran out of memory: the allocator passed to an `...Alloc` function,
    /// or a custom parser / `parseXmlAlloc` hook returned `error.OutOfMemory`.
    value_out_of_memory,
};

/// Values and names longer than this (in bytes) are cut in descriptions, so that the rest fits.
pub const max_input_len = 1024;

/// Diagnostics writing descriptions into `buf`. An empty buffer is allowed: then only
/// `kind` (and `line` / `column`) is recorded.
pub fn init(buf: []u8) Diagnostics {
    return .{ .buf = buf };
}

/// The description of the last error, e.g. `/a: "x": attribute is missing` or
/// `invalid XML at line 2, column 4: end tag does not match start tag`. Empty if there is none.
pub fn message(d: *const Diagnostics) []const u8 {
    return d.buf[0..d.len];
}

/// Prints `message()` (followed by `…` if it was truncated), or `no error`. If nothing of the
/// description fits into the buffer (e.g. an empty buffer), prints the kind instead, e.g.
/// `missing` or `invalid XML at line 2, column 4`.
pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.kind == .none) return w.writeAll("no error");
    if (d.len == 0) {
        if (d.kind == .invalid_xml) return w.print("invalid XML at line {d}, column {d}", .{ d.line, d.column });
        return w.writeAll(@tagName(d.kind));
    }
    try w.writeAll(d.message());
    if (d.truncated) try w.writeAll("…");
}
