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
const Elem = @import("Elem.zig");

const Diagnostics = @This();

/// What went wrong. `none` means that no error was recorded.
kind: Kind = .none,
/// 1-based line of the error in the input; only for `invalid_xml`, otherwise 0.
line: u32 = 0,
/// 1-based column of the error (in code points); only for `invalid_xml`, otherwise 0.
column: u32 = 0,
/// The description didn't fit into the buffer and was cut.
truncated: bool = false,
/// Internal: the buffer given to `init` and the length of the description in it.
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

/// Prints `message()` (followed by `…` if it was truncated), or `no error`.
pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.kind == .none) return w.writeAll("no error");
    try w.writeAll(d.message());
    if (d.truncated) try w.writeAll("…");
}

// ------------------------------------------------------------------ internal

/// Internal: forgets the previous error.
pub fn reset(d: *Diagnostics) void {
    d.* = .init(d.buf);
}

/// Internal: records an XML syntax error at `offset` in `input`.
pub fn recordInvalidXml(d: *Diagnostics, input: []const u8, offset: usize, msg: []const u8) void {
    const lc = lineColumn(input, offset);
    d.reset();
    d.kind = .invalid_xml;
    d.line = lc.line;
    d.column = lc.column;
    var w: std.Io.Writer = .fixed(d.buf);
    const result = w.print("invalid XML at line {d}, column {d}: {s}", .{ lc.line, lc.column, msg });
    d.finish(&w, result);
}

/// Internal: records an error of an extraction function. Prints
/// `<path of elem>: "<selector>": <msg> (input: "<input>")`, leaving out the parts that are null.
pub fn record(
    d: *Diagnostics,
    kind: Kind,
    elem: ?*const Elem,
    selector: ?[]const u8,
    input: ?[]const u8,
    msg: []const u8,
) void {
    d.reset();
    d.kind = kind;
    var w: std.Io.Writer = .fixed(d.buf);
    d.finish(&w, print(&w, elem, selector, input, msg));
}

fn print(w: *std.Io.Writer, elem: ?*const Elem, selector: ?[]const u8, input: ?[]const u8, msg: []const u8) std.Io.Writer.Error!void {
    if (elem) |e| try w.print("{f}: ", .{e.path()});
    if (selector) |s| try w.print("\"{f}\": ", .{shortened(s)});
    try w.writeAll(msg);
    if (input) |s| try w.print(" (input: \"{f}\")", .{shortened(s)});
}

/// Prints at most `max_input_len` bytes of a string, followed by `…` if it is longer.
const Shortened = struct {
    s: []const u8,

    pub fn format(sh: Shortened, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (sh.s.len <= max_input_len) return w.writeAll(sh.s);
        try w.writeAll(sh.s[0..charBoundary(sh.s, max_input_len)]);
        try w.writeAll("…");
    }
};

fn shortened(s: []const u8) Shortened {
    return .{ .s = s };
}

/// Sets the length of the description written by `w`. If it didn't fit (the fixed writer
/// failed), it is marked as truncated and cut so that it doesn't end inside a UTF-8 sequence.
fn finish(d: *Diagnostics, w: *std.Io.Writer, result: std.Io.Writer.Error!void) void {
    const written = w.buffered();
    if (result) |_| {
        d.len = written.len;
    } else |_| {
        d.truncated = true;
        d.len = completePrefix(written);
    }
}

/// The largest `end <= max` such that `s[0..end]` doesn't end inside a UTF-8 sequence.
/// Requires `max < s.len`.
fn charBoundary(s: []const u8, max: usize) usize {
    var end = max;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

/// Length of `s` without an incomplete UTF-8 sequence at its end (`s` was cut at an arbitrary byte).
fn completePrefix(s: []const u8) usize {
    var start = s.len;
    while (start > 0 and s.len - start < 4) {
        start -= 1;
        if (s[start] & 0xC0 != 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(s[start]) catch return s.len;
            return if (start + n > s.len) start else s.len;
        }
    }
    return s.len;
}

/// Internal: computes the 1-based line and column of `offset` in `input`.
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

const t = std.testing;

test lineColumn {
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
    var d: Diagnostics = .init(&buf);
    var out: [100]u8 = undefined;
    try t.expectEqualStrings("no error", try std.fmt.bufPrint(&out, "{f}", .{d}));
    d.record(.missing, null, "x", "v", "attribute is missing");
    try t.expectEqualStrings("\"x\": attribute is missing (input: \"v\")", try std.fmt.bufPrint(&out, "{f}", .{d}));
    try t.expect(!d.truncated);
}

test "long inputs and small buffers are cut at UTF-8 boundaries" {
    // A long input is shortened, so that the message stays complete.
    var big: [max_input_len + 100]u8 = undefined;
    @memset(&big, 'a');
    big[max_input_len - 1] = 0xC5; // "ž" = C5 BE crosses the limit
    big[max_input_len] = 0xBE;
    var buf: [2 * max_input_len]u8 = undefined;
    var d: Diagnostics = .init(&buf);
    d.record(.invalid_value, null, null, &big, "bad");
    try t.expect(!d.truncated);
    try t.expect(std.mem.endsWith(u8, d.message(), "a…\")"));
    try t.expect(std.unicode.utf8ValidateSlice(d.message()));

    // A buffer that is too small: the description is cut and marked.
    var small: [6]u8 = undefined;
    d = .init(&small);
    d.record(.missing, null, "žžžžž", null, "attribute is missing"); // cut inside a "ž"
    try t.expect(d.truncated);
    try t.expect(d.message().len <= small.len);
    try t.expect(std.unicode.utf8ValidateSlice(d.message()));
    try t.expectEqual(Kind.missing, d.kind);

    // A description that fits exactly is not truncated.
    var exact: [12]u8 = undefined;
    d = .init(&exact);
    d.record(.missing, null, null, null, "exactly 12 b");
    try t.expect(!d.truncated);
    try t.expectEqualStrings("exactly 12 b", d.message());

    // An empty buffer records only the kind.
    d = .init(&.{});
    d.record(.too_many, null, "x", null, "too many");
    try t.expectEqual(Kind.too_many, d.kind);
    try t.expectEqualStrings("", d.message());
}
