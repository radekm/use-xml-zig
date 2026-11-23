//! Built-in value parsers. `attr(T, …)` / `text(T)` use them automatically;
//! they can also be called directly, e.g. from custom parsers.

const std = @import("std");
const Timestamp = @import("Timestamp.zig");

/// The only error of the built-in parsers: the string is not a valid value.
pub const Error = error{InvalidValue};

/// Optional sign `+` / `-` followed by one or more decimal digits. Leading zeros are allowed.
/// No `_`, no whitespace. The value must fit into `T`.
pub fn int(comptime T: type, s: []const u8) Error!T {
    if (@typeInfo(T) != .int) @compileError("int expects an integer type, got " ++ @typeName(T));
    var rest = s;
    var negative = false;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    if (rest.len == 0) return error.InvalidValue;
    // At least 8 bits, so that the digits and 10 fit (`T` may be `u1`, `i3`, …).
    const info = @typeInfo(T).int;
    const W = @Int(info.signedness, @max(info.bits, 8));
    var v: W = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') return error.InvalidValue;
        const d: W = @intCast(c - '0');
        v = std.math.mul(W, v, 10) catch return error.InvalidValue;
        // Accumulate negative numbers downwards so that the minimum value can be parsed.
        v = (if (negative) std.math.sub(W, v, d) else std.math.add(W, v, d)) catch return error.InvalidValue;
    }
    return std.math.cast(T, v) orelse error.InvalidValue;
}

/// Optional sign, one or more digits, optionally `.` followed by one or more digits.
/// No exponent, no `inf` / `nan`, no hexadecimal form. Values out of the range of `T` are rejected.
pub fn float(comptime T: type, s: []const u8) Error!T {
    if (@typeInfo(T) != .float) @compileError("float expects a float type, got " ++ @typeName(T));
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == int_start) return error.InvalidValue;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == frac_start) return error.InvalidValue;
    }
    if (i != s.len) return error.InvalidValue;
    const v = std.fmt.parseFloat(T, s) catch return error.InvalidValue;
    if (std.math.isInf(v)) return error.InvalidValue;
    return v;
}

/// Exactly `true` or `false` (case-sensitive).
pub fn boolean(s: []const u8) Error!bool {
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    return error.InvalidValue;
}

/// Exactly the name of one of the tags of enum `E`.
pub fn enumTag(comptime E: type, s: []const u8) Error!E {
    if (@typeInfo(E) != .@"enum") @compileError("enumTag expects an enum type, got " ++ @typeName(E));
    return std.meta.stringToEnum(E, s) orelse error.InvalidValue;
}

/// See `Timestamp.parse`.
pub fn timestamp(s: []const u8) Error!Timestamp {
    return Timestamp.parse(s);
}

/// Returns a parser that accepts only the given strings (and returns the input).
/// Usage: `e.attrWith("unit", use_xml.parse.oneOf(&.{ "kg", "g" }))`.
pub fn oneOf(comptime cases: []const []const u8) fn ([]const u8) Error![]const u8 {
    return struct {
        fn parse(s: []const u8) Error![]const u8 {
            inline for (cases) |c| {
                if (std.mem.eql(u8, s, c)) return s;
            }
            return error.InvalidValue;
        }
    }.parse;
}

const t = std.testing;

test int {
    try t.expectEqual(@as(i32, 4532), try int(i32, "4532"));
    try t.expectEqual(@as(i32, 5), try int(i32, "+5"));
    try t.expectEqual(@as(i32, -12), try int(i32, "-12"));
    try t.expectEqual(@as(u8, 7), try int(u8, "007"));
    try t.expectEqual(@as(u8, 0), try int(u8, "-0"));
    try t.expectEqual(@as(u8, 255), try int(u8, "255"));
    try t.expectEqual(@as(i8, -128), try int(i8, "-128"));
    try t.expectEqual(@as(i8, 127), try int(i8, "127"));
    try t.expectEqual(std.math.maxInt(u64), try int(u64, "18446744073709551615"));
    try t.expectEqual(@as(u1, 1), try int(u1, "1"));

    const invalid = [_][]const u8{ "", "+", "-", "256", "-1", "1_000", " 1", "1 ", "0x10", "1.0", "++1", "١" };
    for (invalid) |s| try t.expectError(error.InvalidValue, int(u8, s));
    try t.expectError(error.InvalidValue, int(i8, "-129"));
    try t.expectError(error.InvalidValue, int(i8, "128"));
    try t.expectError(error.InvalidValue, int(u1, "2"));
}

test float {
    try t.expectEqual(@as(f64, 4532.72), try float(f64, "4532.72"));
    try t.expectEqual(@as(f64, 0.1), try float(f64, "0.1"));
    try t.expectEqual(@as(f64, 0.03), try float(f64, "00.03"));
    try t.expectEqual(@as(f64, 4532), try float(f64, "+4532"));
    try t.expectEqual(@as(f64, -4532), try float(f64, "-4532"));
    try t.expectEqual(@as(f64, 0), try float(f64, "0.0"));
    try t.expectEqual(@as(f32, 1.5), try float(f32, "1.5"));

    const invalid = [_][]const u8{ "", "4532,7", ".5", "5.", "1e3", "inf", "nan", "0x1p3", "1_0", " 1", "+", "-.5", "1.2.3" };
    for (invalid) |s| try t.expectError(error.InvalidValue, float(f64, s));
    var big: [400]u8 = undefined;
    @memset(&big, '9');
    try t.expectError(error.InvalidValue, float(f64, &big));
}

test boolean {
    try t.expectEqual(true, try boolean("true"));
    try t.expectEqual(false, try boolean("false"));
    for ([_][]const u8{ "True", "FALSE", "1", "0", "", " true" }) |s| {
        try t.expectError(error.InvalidValue, boolean(s));
    }
}

test enumTag {
    const E = enum { red, green };
    try t.expectEqual(E.green, try enumTag(E, "green"));
    try t.expectError(error.InvalidValue, enumTag(E, "Green"));
    try t.expectError(error.InvalidValue, enumTag(E, "blue"));
}

test oneOf {
    const unit = oneOf(&.{ "kg", "g" });
    try t.expectEqualStrings("kg", try unit("kg"));
    try t.expectError(error.InvalidValue, unit("t"));
}
