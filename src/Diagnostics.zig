//! Details about the last error of an extraction function or of `Document.expectAllUsed`.
//! Zig errors can't carry data, so the document records them here; read them with
//! `Document.diagnostics`.
//!
//! Slices point into the input or into the document, so a `Diagnostics` value is valid only
//! until `Document.deinit`. Report the error before freeing the document.
//! Every error returned by an extraction function or by `expectAllUsed` is recorded, including
//! `error.OutOfMemory`. Only the last error is kept; successful calls don't change it, so read it
//! right after an error.

const std = @import("std");
const Elem = @import("Elem.zig");

const Diagnostics = @This();

kind: Kind = .none,
/// Element where the error happened.
elem: ?*const Elem = null,
/// Attribute name, child name, or null (text).
selector: ?[]const u8 = null,
/// The string that failed to parse, the unused value, or null.
input: ?[]const u8 = null,
/// Human-readable message (static string or error name).
message: []const u8 = "",

/// What went wrong. `none` means no error was recorded.
pub const Kind = enum {
    none,
    wrong_count,
    already_used,
    invalid_value,
    unused_data,
    /// The document's internal memory (the allocator passed to `Document.parse`) ran out.
    document_out_of_memory,
    /// Producing the value ran out of memory: the allocator passed to an `...Alloc` function,
    /// or a custom parser / `parseXmlAlloc` hook returned `error.OutOfMemory`.
    value_out_of_memory,
};

/// Prints a one-line description, e.g. `/company/address[0]: "city": attribute is missing`.
pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.kind == .none) return w.writeAll("no error");
    if (d.elem) |e| try w.print("{f}: ", .{e.path()});
    if (d.selector) |s| try w.print("\"{s}\": ", .{s});
    try w.writeAll(d.message);
    if (d.input) |s| try w.print(" (input: \"{s}\")", .{s});
}
