//! Simple benchmark: parsing the M7 message (as in UseData.Xml's benchmark) and a large
//! document made by repeating its order books.
//!
//! Run with `zig build bench` (always built with ReleaseFast).

const std = @import("std");
const Allocator = std.mem.Allocator;
const use_xml = @import("use_xml");
const m7 = @import("m7");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const large = try makeLarge(gpa, 1000);
    defer gpa.free(large);

    try out.print("{s:<34} {s:>10} {s:>12} {s:>10}\n", .{ "benchmark", "size", "time/iter", "MB/s" });
    try run(out, io, gpa, "M7 message: Document.parse", m7.message, parseOnly);
    try run(out, io, gpa, "M7 message: parse + extract", m7.message, parseAndExtract);
    try run(out, io, gpa, "large: Document.parse", large, parseOnly);
    try run(out, io, gpa, "large: parse + extract", large, parseAndExtract);
    try out.flush();
}

fn parseOnly(gpa: Allocator, input: []const u8) !void {
    var doc = try use_xml.Document.parse(gpa, input, .{});
    doc.deinit();
}

fn parseAndExtract(gpa: Allocator, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const deltas = try m7.parseOrderBookDelta(gpa, arena.allocator(), input, null);
    std.mem.doNotOptimizeAway(deltas.len);
}

/// Repeats the order books of the M7 message `n` times.
fn makeLarge(gpa: Allocator, n: usize) ![]u8 {
    const open = "<OrdrbookList>";
    const close = "</OrdrbookList>";
    const start = std.mem.indexOf(u8, m7.message, open).? + open.len;
    const end = std.mem.indexOf(u8, m7.message, close).?;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, m7.message[0..start]);
    for (0..n) |_| try buf.appendSlice(gpa, m7.message[start..end]);
    try buf.appendSlice(gpa, m7.message[end..]);
    return buf.toOwnedSlice(gpa);
}

fn run(
    out: *std.Io.Writer,
    io: std.Io,
    gpa: Allocator,
    name: []const u8,
    input: []const u8,
    comptime f: fn (Allocator, []const u8) anyerror!void,
) !void {
    // Warm up, then run for about 0.5 s, keeping the best of several batches.
    try f(gpa, input);
    var iterations: u64 = 1;
    var best_ns: f64 = std.math.inf(f64);
    var total_ns: i96 = 0;
    while (total_ns < 500 * std.time.ns_per_ms) {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..iterations) |_| try f(gpa, input);
        const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        total_ns += elapsed;
        best_ns = @min(best_ns, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations)));
        if (elapsed < 50 * std.time.ns_per_ms) iterations *= 2;
    }
    const mb_per_s = @as(f64, @floatFromInt(input.len)) / best_ns * 1e9 / 1e6;
    try out.print("{s:<34} {d:>8} B {d:>9.1} us {d:>10.1}\n", .{ name, input.len, best_ns / 1e3, mb_per_s });
}
