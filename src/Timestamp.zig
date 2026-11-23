//! A point in time in UTC with nanosecond precision.

const std = @import("std");

const Timestamp = @This();

/// Seconds since 1970-01-01T00:00:00Z (negative before).
seconds: i64,
/// 0 ..< 1_000_000_000
nanos: u32,

/// Error of `parse`.
pub const ParseError = error{InvalidValue};

/// Parses `YYYY-MM-DDTHH:MM:SS[.f…]Z` where `T` may also be a single space and the fraction
/// has 1–9 digits. Years are 0000–9999. The date and time are validated.
pub fn parse(s: []const u8) ParseError!Timestamp {
    if (s.len < 20) return error.InvalidValue;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') {
        return error.InvalidValue;
    }
    const year = try digits(s[0..4]);
    const month = try digits(s[5..7]);
    const day = try digits(s[8..10]);
    const hour = try digits(s[11..13]);
    const minute = try digits(s[14..16]);
    const second = try digits(s[17..19]);

    var nanos: u32 = 0;
    if (s.len == 20) {
        if (s[19] != 'Z') return error.InvalidValue;
    } else {
        const frac = s[20 .. s.len - 1];
        if (s[19] != '.' or s[s.len - 1] != 'Z' or frac.len < 1 or frac.len > 9) return error.InvalidValue;
        nanos = try digits(frac);
        for (frac.len..9) |_| nanos *= 10;
    }

    if (month < 1 or month > 12) return error.InvalidValue;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidValue;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidValue;

    const days = daysFromCivil(year, month, day);
    return .{
        .seconds = days * std.time.s_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second,
        .nanos = nanos,
    };
}

/// Hook used by `attr(Timestamp, …)` / `text(Timestamp)`; same as `parse`.
pub fn parseXml(s: []const u8) ParseError!Timestamp {
    return parse(s);
}

/// Prints the timestamp as `YYYY-MM-DDTHH:MM:SS[.f…]Z` (trailing zeros of the fraction omitted).
/// Only years 0000–9999 can be printed; other values are printed as raw numbers.
pub fn format(ts: Timestamp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const days = @divFloor(ts.seconds, std.time.s_per_day);
    const secs: u32 = @intCast(@mod(ts.seconds, std.time.s_per_day));
    const date = civilFromDays(days);
    if (date.year < 0 or date.year > 9999 or ts.nanos >= std.time.ns_per_s) {
        return w.print("Timestamp{{ .seconds = {d}, .nanos = {d} }}", .{ ts.seconds, ts.nanos });
    }
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(date.year)), date.month,     date.day,
        secs / 3600,                   secs / 60 % 60, secs % 60,
    });
    if (ts.nanos != 0) {
        var buf: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{ts.nanos}) catch unreachable;
        try w.print(".{s}", .{std.mem.trimEnd(u8, &buf, "0")});
    }
    try w.writeByte('Z');
}

fn digits(s: []const u8) ParseError!u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidValue;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
fn daysFromCivil(year: u32, month: u32, day: u32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Inverse of `daysFromCivil`.
fn civilFromDays(days: i64) struct { year: i64, month: u32, day: u32 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}

const t = std.testing;

fn expectRoundTrip(s: []const u8) !void {
    var buf: [40]u8 = undefined;
    try t.expectEqualStrings(s, try std.fmt.bufPrint(&buf, "{f}", .{try parse(s)}));
}

test parse {
    try t.expectEqual(Timestamp{ .seconds = 0, .nanos = 0 }, try parse("1970-01-01T00:00:00Z"));
    // Same values as in UseData.Xml's tests.
    try t.expectEqual(Timestamp{ .seconds = 1622502724, .nanos = 0 }, try parse("2021-05-31T23:12:04Z"));
    try t.expectEqual(Timestamp{ .seconds = 1622502724, .nanos = 0 }, try parse("2021-05-31 23:12:04Z"));
    try t.expectEqual(Timestamp{ .seconds = 1622502724, .nanos = 999_000_000 }, try parse("2021-05-31T23:12:04.999Z"));
    try t.expectEqual(Timestamp{ .seconds = 1658728800, .nanos = 400_000_000 }, try parse("2022-07-25T06:00:00.4Z"));
    try t.expectEqual(Timestamp{ .seconds = 1658728800, .nanos = 134_014_400 }, try parse("2022-07-25T06:00:00.1340144Z"));
    try t.expectEqual(Timestamp{ .seconds = 1658728800, .nanos = 123_456_789 }, try parse("2022-07-25T06:00:00.123456789Z"));
    try t.expectEqual(Timestamp{ .seconds = -1, .nanos = 0 }, try parse("1969-12-31T23:59:59Z"));
    try t.expectEqual(Timestamp{ .seconds = -62167219200, .nanos = 0 }, try parse("0000-01-01T00:00:00Z"));
    try t.expectEqual(Timestamp{ .seconds = 951782400, .nanos = 0 }, try parse("2000-02-29T00:00:00Z"));
}

test "parse rejects invalid timestamps" {
    const invalid = [_][]const u8{
        "",                                "2021-05-31T23:12:04",      "2021-05-31T23:12:04+01:00",
        "2021-13-31 23:12:04Z",            "2021-00-10 23:12:04Z",     "2021-04-31T00:00:00Z",
        "2021-02-29T00:00:00Z",            "1900-02-29T00:00:00Z",     "2021-05-31T24:00:00Z",
        "2021-05-31T23:60:00Z",            "2021-05-31T23:59:60Z",     "2021-05-31T23:12:04.Z",
        "2021-05-31T23:12:04.1234567890Z", "2021-05-31t23:12:04Z",     "2021/05/31T23:12:04Z",
        "21-05-31T23:12:04Z",              "2021-05-31T23:12:04.12aZ", " 2021-05-31T23:12:04Z",
        "2021-05-31T23:12:04Zx",           "+021-05-31T23:12:04Z",
    };
    for (invalid) |s| {
        t.expectError(error.InvalidValue, parse(s)) catch |err| {
            std.debug.print("accepted: \"{s}\"\n", .{s});
            return err;
        };
    }
}

test format {
    try expectRoundTrip("2022-07-25T06:01:02.1340144Z");
    try expectRoundTrip("2021-05-31T23:12:04Z");
    try expectRoundTrip("0000-01-01T00:00:00Z");
    try expectRoundTrip("9999-12-31T23:59:59.999999999Z");
    try expectRoundTrip("1969-12-31T23:59:59.5Z");
}
