//! Details about an XML syntax error, filled in when `Document.parse` fails with
//! `error.InvalidXml`. Pass it in `Document.Options.diagnostics`.
//!
//! It doesn't point into the input or the document, so it stays valid forever.

const std = @import("std");

const ParseDiagnostics = @This();

/// Description of the error (a static string). Empty if no error was recorded.
message: []const u8 = "",
/// 1-based line of the error.
line: u32 = 0,
/// 1-based column of the error, counted in code points.
column: u32 = 0,

/// Prints e.g. `invalid XML at line 2, column 4: end tag does not match start tag`.
pub fn format(d: ParseDiagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.message.len == 0) return w.writeAll("no error");
    try w.print("invalid XML at line {d}, column {d}: {s}", .{ d.line, d.column, d.message });
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

test format {
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings("no error", try std.fmt.bufPrint(&buf, "{f}", .{ParseDiagnostics{}}));
}
