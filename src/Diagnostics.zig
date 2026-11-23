//! Details about the last error. Zig errors can't carry data, so functions that fail
//! fill in a `Diagnostics` struct passed in `Document.Options.diagnostics`.
//!
//! Slices point into the input or into the document, so they are valid until
//! `Document.deinit`. When `Document.parse` fails, only `kind`, `message`, `line`
//! and `column` are set.

const std = @import("std");
const Elem = @import("Elem.zig");

const Diagnostics = @This();

kind: Kind = .none,
/// Element where the error happened (null for XML syntax errors).
elem: ?*const Elem = null,
/// Attribute name, child name, or null (text / syntax error).
selector: ?[]const u8 = null,
/// The string that failed to parse (InvalidValue / custom parser errors).
input: ?[]const u8 = null,
/// Human-readable message (static string or error name).
message: []const u8 = "",
/// 1-based position in the input for XML syntax errors.
line: u32 = 0,
/// 1-based position in the input for XML syntax errors (counted in code points).
column: u32 = 0,

/// What went wrong. `none` means no error was recorded.
pub const Kind = enum { none, invalid_xml, wrong_count, already_used, invalid_value, unused_data };

/// Prints a one-line description, e.g. `/company/address[0]: "city": attribute is missing`
/// or `invalid XML at line 2, column 4: end tag does not match start tag`.
/// Must be called before `Document.deinit` (see the struct documentation).
pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (d.kind) {
        .none => try w.writeAll("no error"),
        .invalid_xml => try w.print("invalid XML at line {d}, column {d}: {s}", .{
            d.line,
            d.column,
            d.message,
        }),
        else => {
            if (d.elem) |e| try w.print("{f}: ", .{e.path()});
            if (d.selector) |s| try w.print("\"{s}\": ", .{s});
            try w.writeAll(d.message);
            if (d.input) |s| try w.print(" (input: \"{s}\")", .{s});
        },
    }
}

/// Computes the 1-based line and column of `offset` in `input`.
/// Line breaks are `\n`, `\r\n` and `\r`. Columns count code points.
pub fn lineColumn(input: []const u8, offset: usize) struct { line: u32, column: u32 } {
    const bom = "\xEF\xBB\xBF";
    var line: usize = 1;
    var line_start: usize = if (std.mem.startsWith(u8, input, bom) and offset >= bom.len) bom.len else 0;
    const end = @min(offset, input.len);
    for (input[0..end], 0..) |c, i| {
        if (c == '\n' or (c == '\r' and (i + 1 >= input.len or input[i + 1] != '\n'))) {
            line += 1;
            line_start = i + 1;
        }
    }
    var column: usize = 1;
    if (line_start < end) {
        for (input[line_start..end]) |c| {
            if (c & 0xC0 != 0x80) column += 1;
        }
    }
    return .{
        .line = std.math.cast(u32, line) orelse std.math.maxInt(u32),
        .column = std.math.cast(u32, column) orelse std.math.maxInt(u32),
    };
}

test lineColumn {
    const t = std.testing;
    try t.expectEqual(1, lineColumn("abc", 0).line);
    try t.expectEqual(3, lineColumn("abc", 2).column);
    try t.expectEqual(2, lineColumn("a\nbc", 3).line);
    try t.expectEqual(2, lineColumn("a\nbc", 3).column);
    try t.expectEqual(2, lineColumn("a\r\nbc", 4).line);
    try t.expectEqual(2, lineColumn("a\r\nbc", 4).column);
    try t.expectEqual(3, lineColumn("a\r\rb", 3).line);
    try t.expectEqual(3, lineColumn("žluť", 3).column); // "žl" is 3 bytes, 2 code points
    try t.expectEqual(1, lineColumn("\xEF\xBB\xBF<", 3).column);
}
