//! Internal: writing descriptions of errors into `Diagnostics`. Not exported from `root.zig`,
//! so that the public API of `Diagnostics` contains only reading.

const std = @import("std");
const Diagnostics = @import("Diagnostics.zig");
const Elem = @import("Elem.zig");

/// Forgets the previous error.
pub fn reset(d: *Diagnostics) void {
    d.* = .init(d.buf);
}

/// Records an XML syntax error at `offset` in `input`.
pub fn recordInvalidXml(d: *Diagnostics, input: []const u8, offset: usize, msg: []const u8) void {
    const lc = lineColumn(input, offset);
    reset(d);
    d.kind = .invalid_xml;
    d.line = lc.line;
    d.column = lc.column;
    var w: std.Io.Writer = .fixed(d.buf);
    const result = w.print("invalid XML at line {d}, column {d}: {s}", .{ lc.line, lc.column, msg });
    finish(d, &w, result);
}

/// Records an error of an extraction function. Prints
/// `<path of elem>: "<selector>": <msg> (input: "<input>")`, leaving out the parts that are null.
pub fn record(
    d: *Diagnostics,
    kind: Diagnostics.Kind,
    elem: ?*const Elem,
    selector: ?[]const u8,
    input: ?[]const u8,
    msg: []const u8,
) void {
    // DO NOT REMOVE: the selector is copied before `d.buf` is overwritten.
    //
    // `selector` is a name passed in by the user (`e.attr(T, name)`, `e.child(name)`, …) and may
    // point anywhere, also into `d.buf` itself, e.g. `e.attr(T, diag.message()[i..j])` or a name
    // kept in the same buffer. Formerly the description was written into `d.buf` while reading
    // the selector from it: the source and the destination of the copy overlapped, so Debug and
    // ReleaseSafe panicked with "@memcpy arguments alias" and ReleaseFast / ReleaseSmall had
    // undefined behaviour (a garbled description). Regression tests: "selector overlapping the
    // diagnostics buffer" here and in `elem_test.zig`.
    //
    // The other inputs can't overlap `d.buf`: `msg` is static, `input` is a value from the
    // document (its arena, or the input, which must not change while the document lives) and
    // `elem` points into the document.
    var selector_buf: [max_shortened_len]u8 = undefined;
    const selector_copy: ?[]const u8 = if (selector) |s| copyShortened(&selector_buf, s) else null;

    reset(d);
    d.kind = kind;
    var w: std.Io.Writer = .fixed(d.buf);
    finish(d, &w, print(&w, elem, selector_copy, input, msg));
}

/// Upper bound of the length of `shortened(s)` printed for any `s`.
const max_shortened_len = Diagnostics.max_input_len + "…".len;

/// Prints `shortened(s)` into `buf` and returns the printed part. Used by `record`, so that the
/// selector is copied out before `Diagnostics.buf` is written.
fn copyShortened(buf: *[max_shortened_len]u8, s: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // `Shortened` never prints more than `max_shortened_len` bytes, so this doesn't fail; if it
    // did, the printed prefix would still be a safe (if shorter) description.
    w.print("{f}", .{shortened(s)}) catch {};
    return w.buffered();
}

/// `shortened_selector` was already shortened by `copyShortened`.
fn print(w: *std.Io.Writer, elem: ?*const Elem, shortened_selector: ?[]const u8, input: ?[]const u8, msg: []const u8) std.Io.Writer.Error!void {
    if (elem) |e| try w.print("{f}: ", .{ShortPath{ .elem = e }});
    if (shortened_selector) |s| try w.print("\"{s}\": ", .{s});
    try w.writeAll(msg);
    if (input) |s| try w.print(" (input: \"{f}\")", .{shortened(s)});
}

/// Prints the path of an element like `Elem.Path`, but names are shortened like values and
/// the path has at most about `Diagnostics.max_input_len` bytes: the start of a longer path is replaced
/// by `/…`. The element itself is always printed. Only the printed part of the path is walked,
/// so the time doesn't depend on the depth of the element.
const ShortPath = struct {
    elem: *const Elem,

    pub fn format(sp: ShortPath, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // The topmost ancestor that still fits, and the number of printed segments.
        var top = sp.elem;
        var count: usize = 1;
        var len = segmentLen(sp.elem);
        while (top.parent_elem) |p| {
            len += segmentLen(p);
            if (len > Diagnostics.max_input_len) break;
            top = p;
            count += 1;
        }
        if (top.parent_elem != null) try w.writeAll("/…");
        var level = count;
        while (level > 0) {
            level -= 1;
            var a = sp.elem;
            for (0..level) |_| a = a.parent_elem.?;
            try w.print("/{f}", .{shortened(a.local_name)});
            if (a.parent_elem != null) try w.print("[{d}]", .{a.index()});
        }
    }

    /// Upper bound of the length of the segment printed for `e`.
    fn segmentLen(e: *const Elem) usize {
        const name_len = @min(e.local_name.len, Diagnostics.max_input_len + "…".len);
        const index_len = if (e.parent_elem != null) "[]".len + std.fmt.count("{d}", .{e.index()}) else 0;
        return "/".len + name_len + index_len;
    }
};

/// Prints at most `Diagnostics.max_input_len` bytes of a string, followed by `…` if it is longer. The string
/// is cut between UTF-8 sequences. Invalid UTF-8 (possible in names passed in by the user) is
/// replaced by U+FFFD, so that the description is always valid UTF-8.
const Shortened = struct {
    s: []const u8,

    pub fn format(sh: Shortened, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Only the printed part is examined, so long values cost nothing extra.
        const replacement = "\u{FFFD}";
        var i: usize = 0;
        var printed: usize = 0; // bytes printed (or about to be printed) so far
        var valid_start: usize = 0; // start of the run of valid sequences not yet written
        while (i < sh.s.len) {
            const n = validSequenceLen(sh.s[i..]);
            const out_len = if (n == 0) replacement.len else n;
            if (printed + out_len > Diagnostics.max_input_len) {
                try w.writeAll(sh.s[valid_start..i]);
                return w.writeAll("…");
            }
            printed += out_len;
            if (n == 0) {
                try w.writeAll(sh.s[valid_start..i]);
                try w.writeAll(replacement);
                i += 1;
                valid_start = i;
            } else {
                i += n;
            }
        }
        try w.writeAll(sh.s[valid_start..]);
    }
};

/// Length of the valid UTF-8 sequence at the start of `s`, or 0 if it is invalid.
fn validSequenceLen(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (n > s.len) return 0;
    _ = std.unicode.utf8Decode(s[0..n]) catch return 0;
    return n;
}

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

test "format of recorded errors" {
    var buf: [100]u8 = undefined;
    var d: Diagnostics = .init(&buf);
    var out: [100]u8 = undefined;
    try t.expectEqualStrings("no error", try std.fmt.bufPrint(&out, "{f}", .{d}));
    record(&d, .missing, null, "x", "v", "attribute is missing");
    try t.expectEqualStrings("\"x\": attribute is missing (input: \"v\")", try std.fmt.bufPrint(&out, "{f}", .{d}));
    try t.expect(!d.truncated);

    // Nothing of the description fits: the kind is printed instead.
    d = .init(&.{});
    record(&d, .too_many, null, "x", null, "too many");
    try t.expectEqualStrings("too_many", try std.fmt.bufPrint(&out, "{f}", .{d}));
    recordInvalidXml(&d, "<a>\n<b>", 5, "unexpected end of input");
    try t.expectEqualStrings("invalid XML at line 2, column 2", try std.fmt.bufPrint(&out, "{f}", .{d}));
    var one: [1]u8 = undefined;
    d = .init(&one);
    record(&d, .missing, null, null, null, "ž"); // the first character doesn't fit
    try t.expectEqualStrings("missing", try std.fmt.bufPrint(&out, "{f}", .{d}));
}

test "long inputs and small buffers are cut at UTF-8 boundaries" {
    // A long input is shortened, so that the message stays complete.
    var big: [Diagnostics.max_input_len + 100]u8 = undefined;
    @memset(&big, 'a');
    big[Diagnostics.max_input_len - 1] = 0xC5; // "ž" = C5 BE crosses the limit
    big[Diagnostics.max_input_len] = 0xBE;
    var buf: [2 * Diagnostics.max_input_len]u8 = undefined;
    var d: Diagnostics = .init(&buf);
    record(&d, .invalid_value, null, null, &big, "bad");
    try t.expect(!d.truncated);
    try t.expect(std.mem.endsWith(u8, d.message(), "a…\")"));
    try t.expect(std.unicode.utf8ValidateSlice(d.message()));

    // A buffer that is too small: the description is cut and marked.
    var small: [6]u8 = undefined;
    d = .init(&small);
    record(&d, .missing, null, "žžžžž", null, "attribute is missing"); // cut inside a "ž"
    try t.expect(d.truncated);
    try t.expect(d.message().len <= small.len);
    try t.expect(std.unicode.utf8ValidateSlice(d.message()));
    try t.expectEqual(Diagnostics.Kind.missing, d.kind);

    // A description that fits exactly is not truncated.
    var exact: [12]u8 = undefined;
    d = .init(&exact);
    record(&d, .missing, null, null, null, "exactly 12 b");
    try t.expect(!d.truncated);
    try t.expectEqualStrings("exactly 12 b", d.message());

    // Names passed in by the user may be invalid UTF-8: invalid bytes are replaced by U+FFFD.
    d = .init(&buf);
    record(&d, .missing, null, "a\xffb\xc5", null, "attribute is missing");
    try t.expectEqualStrings("\"a\u{FFFD}b\u{FFFD}\": attribute is missing", d.message());
    var bad: [Diagnostics.max_input_len + 100]u8 = undefined;
    @memset(&bad, 0xFF);
    record(&d, .missing, null, &bad, null, "attribute is missing");
    try t.expect(!d.truncated);
    try t.expect(std.unicode.utf8ValidateSlice(d.message()));
    try t.expect(std.mem.endsWith(u8, d.message(), "\u{FFFD}…\": attribute is missing"));

    // An empty buffer records only the kind.
    d = .init(&.{});
    record(&d, .too_many, null, "x", null, "too many");
    try t.expectEqual(Diagnostics.Kind.too_many, d.kind);
    try t.expectEqualStrings("", d.message());
}

test "selector overlapping the diagnostics buffer" {
    // Regression test, see the comment in `record`: the selector is read from the buffer that the
    // description is written into.
    var buf: [2 * Diagnostics.max_input_len]u8 = undefined;
    var d: Diagnostics = .init(&buf);
    record(&d, .missing, null, "abc", null, "first");
    try t.expectEqualStrings("\"abc\": first", d.message());
    record(&d, .missing, null, d.message()[1..4], null, "second");
    try t.expectEqualStrings("\"abc\": second", d.message());

    // A long selector in the buffer is shortened like any other.
    @memset(&buf, 'x');
    record(&d, .missing, null, &buf, null, "third");
    try t.expect(!d.truncated);
    try t.expect(std.mem.endsWith(u8, d.message(), "x…\": third"));
    try t.expectEqual(1 + Diagnostics.max_input_len + "…\": third".len, d.message().len);
}
