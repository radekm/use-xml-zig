//! Example: extracting order book deltas from an M7 message
//! (port of UseData.Xml's benchmark `M7Message.fs`).
//!
//! The M7 specification "DFS180 - M7 - Public Message Interface" can be found at
//! https://www.semopx.com/documents/general-publications/DFS180-API-Specifications-M7-6.13-v1.0.pdf

const std = @import("std");
const Allocator = std.mem.Allocator;
const use_xml = @import("use_xml");

pub const message = @embedFile("message.xml");

pub const Order = struct {
    order_id: u64,
    price: i64,
    quantity: u32,
    entry_time: use_xml.Timestamp,
};

pub const OrderBookDelta = struct {
    contract_id: u64,
    area_id: []const u8,
    revision: u32,
    buy: []const Order,
    sell: []const Order,
};

/// Extracts order book deltas from `input`.
///
/// `gpa` is used for the document, which is freed before returning. The result is allocated
/// in `out`; pass an arena, because partial results are not freed on error.
/// Fails with `error.UnusedData` if the message contains data this function doesn't read.
///
/// On an error of the library, `diag` (if given) describes it; the caller reports it.
pub fn parseOrderBookDelta(
    gpa: Allocator,
    out: Allocator,
    input: []const u8,
    diag: ?*use_xml.Diagnostics,
) ![]OrderBookDelta {
    var doc = try use_xml.Document.parse(gpa, input, .{ .diagnostics = diag });
    defer doc.deinit();
    return extract(&doc, out);
}

fn extract(doc: *use_xml.Document, out: Allocator) ![]OrderBookDelta {
    const root = doc.root();

    // The header is not needed.
    _ = try (try root.child("StandardHeader")).attr([]const u8, "marketId");

    const books = if (try root.childOpt("OrdrbookList")) |list| try list.children("OrdrBook") else &.{};
    const result = try out.alloc(OrderBookDelta, books.len);
    for (books, result) |book, *delta| {
        // Values we don't need, but which must be valid.
        _ = try book.attrOpt(i64, "lastPx");
        _ = try book.attrOpt(u32, "lastQty");
        _ = try book.attrOpt(u32, "totalQty");
        _ = try book.attrOpt(use_xml.Timestamp, "lastTradeTime");
        _ = try book.attrOpt(i32, "pxDir");
        _ = try book.attrOpt(i64, "highPx");
        _ = try book.attrOpt(i64, "lowPx");

        delta.* = .{
            .contract_id = try book.attr(u64, "contractId"),
            .area_id = try book.attrAllocWith(out, "dlvryAreaId", dupeNonWhitespace),
            .revision = try book.attr(u32, "revisionNo"),
            .buy = try parseOrders(out, try book.childOpt("BuyOrdrList")),
            .sell = try parseOrders(out, try book.childOpt("SellOrdrList")),
        };
    }

    try doc.expectAllUsed();
    return result;
}

fn parseOrders(out: Allocator, list: ?*use_xml.Elem) ![]const Order {
    const entries = if (list) |l| try l.children("OrdrBookEntry") else return &.{};
    const orders = try out.alloc(Order, entries.len);
    for (entries, orders) |e, *order| {
        order.* = .{
            .order_id = try e.attr(u64, "ordrId"),
            .price = try e.attr(i64, "px"),
            .quantity = try e.attr(u32, "qty"),
            .entry_time = try e.attr(use_xml.Timestamp, "ordrEntryTime"),
        };
    }
    return orders;
}

/// Custom parser with allocation: accepts strings with at least one non-whitespace character.
fn dupeNonWhitespace(gpa: Allocator, s: []const u8) error{ OutOfMemory, WhitespaceOnly }![]const u8 {
    if (std.mem.trim(u8, s, " \t\r\n").len == 0) return error.WhitespaceOnly;
    return gpa.dupe(u8, s);
}

const t = std.testing;

test "parse the M7 message" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const deltas = try parseOrderBookDelta(t.allocator, arena.allocator(), message, null);

    try t.expectEqual(14, deltas.len);
    const first = deltas[0];
    try t.expectEqual(1790055, first.contract_id);
    try t.expectEqualStrings("10YDE-EON------1", first.area_id);
    try t.expectEqual(1973, first.revision);
    try t.expectEqual(0, first.sell.len);
    try t.expectEqual(1, first.buy.len);
    try t.expectEqual(Order{
        .order_id = 505982385,
        .price = 57,
        .quantity = 0,
        .entry_time = try use_xml.Timestamp.parse("2022-11-12T10:02:54.553Z"),
    }, first.buy[0]);

    const third = deltas[2];
    try t.expectEqual(1790073, third.contract_id);
    try t.expectEqual(1, third.buy.len);
    try t.expectEqual(1, third.sell.len);
    try t.expectEqual(30058, third.sell[0].price);

    var buy_orders: usize = 0;
    var sell_orders: usize = 0;
    for (deltas) |d| {
        buy_orders += d.buy.len;
        sell_orders += d.sell.len;
    }
    try t.expectEqual(14, buy_orders);
    try t.expectEqual(4, sell_orders);
}

/// Checks that `input` fails with `expected` and that the error is described as `report`
/// (error name, then the diagnostics), as a caller would log it.
fn expectError(expected: anyerror, input: []const u8, report: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var diag_buf: [4096]u8 = undefined;
    var diag: use_xml.Diagnostics = .init(&diag_buf);
    const err = if (parseOrderBookDelta(t.allocator, arena.allocator(), input, &diag)) |_|
        return error.TestExpectedError
    else |err|
        err;
    try t.expectEqual(expected, err);
    // The document is already freed here, but the description is still valid.
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(report, try std.fmt.bufPrint(&buf, "{s}: {f}", .{ @errorName(err), diag }));
}

test "unexpected data in the message is detected" {
    const input =
        \\<PblcOrdrBooksDeltaRprt>
        \\  <StandardHeader marketId="EPEX"/>
        \\  <OrdrbookList>
        \\    <OrdrBook contractId="1" dlvryAreaId="A" revisionNo="2" newAttr="?"/>
        \\  </OrdrbookList>
        \\</PblcOrdrBooksDeltaRprt>
    ;
    try expectError(error.UnusedData, input,
        \\UnusedData: /PblcOrdrBooksDeltaRprt/OrdrbookList[0]/OrdrBook[0]: "newAttr": attribute was not used (input: "?")
    );
}

test "invalid values are reported" {
    const input =
        \\<PblcOrdrBooksDeltaRprt>
        \\  <StandardHeader marketId="EPEX"/>
        \\  <OrdrbookList>
        \\    <OrdrBook contractId="1" dlvryAreaId="  " revisionNo="2"/>
        \\  </OrdrbookList>
        \\</PblcOrdrBooksDeltaRprt>
    ;
    try expectError(error.WhitespaceOnly, input,
        \\WhitespaceOnly: /PblcOrdrBooksDeltaRprt/OrdrbookList[0]/OrdrBook[0]: "dlvryAreaId": WhitespaceOnly (input: "  ")
    );
}

test "invalid XML is reported" {
    try expectError(error.InvalidXml, "<a>\n<b></a>", "InvalidXml: invalid XML at line 2, column 4: end tag does not match start tag");
}

test "out of memory" {
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try parseOrderBookDelta(gpa, arena.allocator(), message, null);
        }
    }.run, .{});
}
