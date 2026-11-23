//! Character classes from the XML 1.0 (Fifth Edition) specification.

const std = @import("std");

/// `S` production: space, tab, line feed, carriage return.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// True if `s` consists only of `S` characters (or is empty).
pub fn isAllSpace(s: []const u8) bool {
    for (s) |c| {
        if (!isSpace(c)) return false;
    }
    return true;
}

/// `Char` production.
pub fn isChar(cp: u21) bool {
    return switch (cp) {
        0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
        else => false,
    };
}

/// `NameStartChar` production.
pub fn isNameStartChar(cp: u21) bool {
    return switch (cp) {
        ':', 'A'...'Z', '_', 'a'...'z' => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF, 0x370...0x37D, 0x37F...0x1FFF => true,
        0x200C...0x200D, 0x2070...0x218F, 0x2C00...0x2FEF, 0x3001...0xD7FF => true,
        0xF900...0xFDCF, 0xFDF0...0xFFFD, 0x10000...0xEFFFF => true,
        else => false,
    };
}

/// `NameChar` production.
pub fn isNameChar(cp: u21) bool {
    return switch (cp) {
        '-', '.', '0'...'9', 0xB7, 0x300...0x36F, 0x203F...0x2040 => true,
        else => isNameStartChar(cp),
    };
}

/// Position and description of an invalid character, see `findInvalid`.
pub const Invalid = struct {
    offset: usize,
    message: []const u8,
};

/// Checks that `s` is valid UTF-8 and that every code point is an XML `Char`.
/// Returns the first problem, or null.
pub fn findInvalid(s: []const u8) ?Invalid {
    const invalid_utf8 = "invalid UTF-8";
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (b < 0x20 and b != '\t' and b != '\n' and b != '\r') {
                return .{ .offset = i, .message = "character is not allowed in XML" };
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch
            return .{ .offset = i, .message = invalid_utf8 };
        if (i + n > s.len) return .{ .offset = i, .message = invalid_utf8 };
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch
            return .{ .offset = i, .message = invalid_utf8 };
        if (!isChar(cp)) return .{ .offset = i, .message = "character is not allowed in XML" };
        i += n;
    }
    return null;
}

test findInvalid {
    try std.testing.expectEqual(null, findInvalid("<a>ž\t\r\n</a>"));
    try std.testing.expectEqual(@as(usize, 1), findInvalid("a\x00").?.offset);
    try std.testing.expectEqual(@as(usize, 2), findInvalid("ab\xff").?.offset);
    try std.testing.expectEqual(@as(usize, 0), findInvalid("\xc3").?.offset); // truncated
    try std.testing.expectEqual(@as(usize, 0), findInvalid("\xed\xa0\x80").?.offset); // surrogate
    try std.testing.expectEqual(@as(usize, 0), findInvalid("\xef\xbf\xbe").?.offset); // U+FFFE
}

test "name characters" {
    try std.testing.expect(isNameStartChar('a'));
    try std.testing.expect(isNameStartChar(0x10D)); // č
    try std.testing.expect(!isNameStartChar('-'));
    try std.testing.expect(!isNameStartChar('1'));
    try std.testing.expect(isNameChar('-'));
    try std.testing.expect(isNameChar('1'));
    try std.testing.expect(!isNameChar(' '));
}
