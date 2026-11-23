//! Tests of reporting unused data. The first tests are ported from UseData.Xml's
//! `TracingUnusedContent` tests.

const std = @import("std");
const t = std.testing;
const Document = @import("Document.zig");
const Diagnostics = @import("Diagnostics.zig");

/// Formats all entries of `doc.unused()`, one per line.
fn unusedReport(doc: *Document, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var it = doc.unused();
    while (it.next()) |u| try w.print("{f}\n", .{u});
    return w.buffered();
}

fn expectReport(doc: *Document, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try t.expectEqualStrings(expected, try unusedReport(doc, &buf));
}

const company_input =
    \\<company>
    \\    <address>
    \\        <street>Baker Street</street>
    \\        <city>London</city>
    \\    </address>
    \\</company>
;

test "unused element" {
    var doc = try Document.parse(t.allocator, company_input, .{});
    defer doc.deinit();
    const street = try (try (try doc.root().child("address")).child("street")).text([]const u8);
    try t.expectEqualStrings("Baker Street", street);

    var it = doc.unused();
    const u = it.next().?;
    try t.expectEqualStrings("address", u.elem.name());
    var attrs = u.attrs;
    try t.expectEqual(null, attrs.next());
    var children = u.children;
    try t.expectEqualStrings("city", children.next().?);
    try t.expectEqual(null, children.next());
    try t.expectEqual(null, u.text);
    try t.expectEqual(null, it.next());
}

test "unused attribute" {
    var doc = try Document.parse(t.allocator,
        \\<company>
        \\    <address street="Baker Street" city="London" />
        \\</company>
    , .{});
    defer doc.deinit();
    const city = try (try doc.root().child("address")).attr([]const u8, "city");
    try t.expectEqualStrings("London", city);
    try expectReport(&doc, "/company/address[0]: attributes: street=\"Baker Street\"\n");
}

test "unused text" {
    var doc = try Document.parse(t.allocator, company_input, .{});
    defer doc.deinit();
    const address = try doc.root().child("address");
    _ = try address.child("city"); // visited, but its text is not used
    _ = try (try address.child("street")).text([]const u8);
    try expectReport(&doc, "/company/address[0]/city[0]: text: \"London\"\n");
}

test "nothing unused" {
    var diag: Diagnostics = .{};
    var doc = try Document.parse(t.allocator, company_input, .{ .diagnostics = &diag });
    defer doc.deinit();
    const address = try doc.root().child("address");
    _ = try (try address.child("city")).text([]const u8);
    _ = try (try address.child("street")).text([]const u8);
    try expectReport(&doc, "");
    try doc.expectAllUsed();
    try t.expectEqual(Diagnostics.Kind.none, diag.kind);
}

test "nothing requested: only the root is reported" {
    var doc = try Document.parse(t.allocator, "<a x=\"1\" y=\"2\"><b><c/></b><d/><b/></a>", .{});
    defer doc.deinit();
    try expectReport(&doc, "/a: attributes: x=\"1\", y=\"2\"; child elements: b, d\n");
}

test "report is in document order and covers attributes, children and text" {
    const input =
        \\<r>
        \\  <p a="1"><q>x</q></p>
        \\  <p><s>y</s></p>
        \\  <t>  </t>
        \\  <u><![CDATA[ ]]></u>
        \\</r>
    ;
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    const r = doc.root();
    for (try r.children("p")) |p| _ = try p.childOpt("q");
    _ = try r.child("t");
    _ = try r.child("u");
    try expectReport(&doc,
        \\/r/p[0]: attributes: a="1"
        \\/r/p[0]/q[0]: text: "x"
        \\/r/p[1]: child elements: s
        \\/r/u[0]: text: " "
        \\
    );
}

test "whitespace and namespace declarations are never reported" {
    var doc = try Document.parse(t.allocator, "<r xmlns=\"urn:a\" xmlns:p=\"urn:b\">\n  <p:x>  \n </p:x>\n</r>", .{});
    defer doc.deinit();
    _ = try doc.root().child("x");
    try expectReport(&doc, "");
}

test "ignoreAll hides the element and everything below it" {
    var doc = try Document.parse(t.allocator, "<r><a x=\"1\"><b>t</b>  </a><c>x</c></r>", .{});
    defer doc.deinit();
    (try doc.root().child("a")).ignoreAll();
    try expectReport(&doc, "/r: child elements: c\n");
    doc.root().ignoreAll();
    try expectReport(&doc, "");
}

test "requested missing names are not reported" {
    var doc = try Document.parse(t.allocator, "<r/>", .{});
    defer doc.deinit();
    try t.expectEqual(null, try doc.root().attrOpt([]const u8, "x"));
    try t.expectEqual(0, (try doc.root().children("y")).len);
    try expectReport(&doc, "");
}

test "the report can be produced repeatedly and reflects later use" {
    var doc = try Document.parse(t.allocator, "<r x=\"1\"/>", .{});
    defer doc.deinit();
    try expectReport(&doc, "/r: attributes: x=\"1\"\n");
    try expectReport(&doc, "/r: attributes: x=\"1\"\n");
    _ = try doc.root().attr(u8, "x");
    try expectReport(&doc, "");
}

test "expectAllUsed describes the first unused item" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "<r x=\"1\"><a/></r>", "/r: \"x\": attribute was not used (input: \"1\")" },
        .{ "<r><a/></r>", "/r: \"a\": child elements were not used" },
        .{ "<r>hello</r>", "/r: text was not used (input: \"hello\")" },
    };
    for (cases) |case| {
        var diag: Diagnostics = .{};
        var doc = try Document.parse(t.allocator, case[0], .{ .diagnostics = &diag });
        defer doc.deinit();
        try t.expectError(error.UnusedData, doc.expectAllUsed());
        try t.expectEqual(Diagnostics.Kind.unused_data, diag.kind);
        var buf: [256]u8 = undefined;
        try t.expectEqualStrings(case[1], try std.fmt.bufPrint(&buf, "{f}", .{diag}));
    }
}

test "children of an element with a failed child() are not reported" {
    var doc = try Document.parse(t.allocator, "<r><a>1</a><a>2</a></r>", .{});
    defer doc.deinit();
    try t.expectError(error.WrongCount, doc.root().child("a"));
    try expectReport(&doc, "");
}
