//! Tests of the extraction API (`Elem`). Many are ported from UseData.Xml's `ElemTest.fs`.

const std = @import("std");
const t = std.testing;
const Document = @import("Document.zig");
const Elem = @import("Elem.zig");
const Diagnostics = @import("Diagnostics.zig");

const Fixture = struct {
    doc: Document,
    diag: *Diagnostics,

    fn init(input: []const u8, diag: *Diagnostics) !Fixture {
        return .{ .doc = try Document.parse(t.allocator, input, .{ .diagnostics = diag }), .diag = diag };
    }

    fn deinit(f: *Fixture) void {
        f.doc.deinit();
    }

    fn root(f: *Fixture) *Elem {
        return f.doc.root();
    }

    fn expectDiag(f: *Fixture, kind: Diagnostics.Kind, formatted: []const u8) !void {
        try t.expectEqual(kind, f.diag.kind);
        var buf: [256]u8 = undefined;
        try t.expectEqualStrings(formatted, try std.fmt.bufPrint(&buf, "{f}", .{f.diag.*}));
    }
};

// ------------------------------------------------------------------ UseData.Xml: Basic

test "child elements" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init(
        \\<animals>
        \\    <dog>A</dog>
        \\    <pig>B</pig>
        \\    <dog>D</dog>
        \\</animals>
    , &diag);
    defer f.deinit();

    const dogs = try f.root().children("dog");
    try t.expectEqual(2, dogs.len);
    try t.expectEqualStrings("A", try dogs[0].text([]const u8));
    try t.expectEqualStrings("D", try dogs[1].text([]const u8));
    try t.expectEqualStrings("B", try (try f.root().child("pig")).text([]const u8));
    try t.expectEqual(null, try f.root().childOpt("cat"));
}

test "attributes" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init(
        \\<people>
        \\    <person name="Pete" />
        \\    <person name="Harry" address="Little Whinging" />
        \\</people>
    , &diag);
    defer f.deinit();

    const people = try f.root().children("person");
    try t.expectEqualStrings("Pete", try people[0].attr([]const u8, "name"));
    try t.expectEqual(null, try people[0].attrOpt([]const u8, "address"));
    try t.expectEqualStrings("Harry", try people[1].attr([]const u8, "name"));
    try t.expectEqualStrings("Little Whinging", (try people[1].attrOpt([]const u8, "address")).?);
}

test "prefixes and default namespace are ignored" {
    const inputs = [_][]const u8{
        \\<root>
        \\    <h:table xmlns:h="http://www.w3.org/TR/html4/">
        \\        <h:tr><h:td>Cell</h:td></h:tr>
        \\    </h:table>
        \\</root>
        ,
        \\<root>
        \\    <table xmlns="http://www.w3.org/TR/html4/">
        \\        <tr><td>Cell</td></tr>
        \\    </table>
        \\</root>
    };
    for (inputs) |input| {
        var diag: Diagnostics = .{};
        var f = try Fixture.init(input, &diag);
        defer f.deinit();
        const tds = try (try (try f.root().child("table")).child("tr")).children("td");
        try t.expectEqual(1, tds.len);
        try t.expectEqualStrings("Cell", try tds[0].text([]const u8));
    }
}

// ------------------------------------------------------------------ UseData.Xml: Errors

test "multiple children when single child is expected" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<person><name>Peter</name><name>James</name></person>", &diag);
    defer f.deinit();
    try t.expectError(error.WrongCount, f.root().child("name"));
    try f.expectDiag(.wrong_count, "/person: \"name\": expected exactly one child element, found more than one");
}

test "multiple children when at most one child is expected" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<person><name>Peter</name><name>James</name></person>", &diag);
    defer f.deinit();
    try t.expectError(error.WrongCount, f.root().childOpt("name"));
    try f.expectDiag(.wrong_count, "/person: \"name\": expected at most one child element, found more than one");
}

test "no child when one child is expected" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<dog></dog>", &diag);
    defer f.deinit();
    try t.expectError(error.WrongCount, f.root().child("name"));
    try f.expectDiag(.wrong_count, "/dog: \"name\": expected exactly one child element, found none");
    try t.expectEqual(f.root(), diag.elem.?);
}

test "no attribute when one attribute is expected" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<city></city>", &diag);
    defer f.deinit();
    try t.expectError(error.WrongCount, f.root().attr([]const u8, "name"));
    try f.expectDiag(.wrong_count, "/city: \"name\": attribute is missing");
}

// ------------------------------------------------------------------ usage rules

test "each attribute, child name and text can be used once" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a x=\"1\"><b><c>t</c></b><b/></a>", &diag);
    defer f.deinit();
    const a = f.root();

    _ = try a.attr([]const u8, "x");
    try t.expectError(error.AlreadyUsed, a.attrOpt([]const u8, "x"));
    try f.expectDiag(.already_used, "/a: \"x\": attribute was already used");

    const bs = try a.children("b");
    try t.expectError(error.AlreadyUsed, a.child("b"));
    try f.expectDiag(.already_used, "/a: \"b\": child elements were already used");

    const c = try bs[0].child("c");
    _ = try c.text([]const u8);
    try t.expectError(error.AlreadyUsed, c.textWith(identity));
    try f.expectDiag(.already_used, "/a/b[0]/c[0]: text was already used");
}

test "requesting a missing name twice fails" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a/>", &diag);
    defer f.deinit();
    const a = f.root();

    try t.expectEqual(null, try a.attrOpt([]const u8, "x"));
    try t.expectError(error.AlreadyUsed, a.attrOpt([]const u8, "x"));
    try f.expectDiag(.already_used, "/a: \"x\": attribute was already used");
    try t.expectError(error.AlreadyUsed, a.attr([]const u8, "x"));

    try t.expectEqual(0, (try a.children("x")).len); // attributes and children are separate
    try t.expectError(error.AlreadyUsed, a.childOpt("x"));
    try f.expectDiag(.already_used, "/a: \"x\": child elements were already used");

    try t.expectError(error.WrongCount, a.attr([]const u8, "y"));
    try t.expectError(error.AlreadyUsed, a.attrOpt([]const u8, "y"));
}

test "the name passed in may be a temporary buffer" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a/>", &diag);
    defer f.deinit();
    var name_buf = "zz".*;
    try t.expectError(error.WrongCount, f.root().attr([]const u8, &name_buf));
    name_buf = "qq".*;
    try t.expectEqualStrings("zz", diag.selector.?);
    try t.expectError(error.AlreadyUsed, f.root().attr([]const u8, "zz"));
}

test "text of an element with child elements" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a> <b/> </a>", &diag);
    defer f.deinit();
    try t.expectError(error.WrongCount, f.root().text([]const u8));
    try f.expectDiag(.wrong_count, "/a: element has child elements, so it has no text");
}

test "text keeps whitespace and empty elements have empty text" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a><b> x </b><c/><d></d></a>", &diag);
    defer f.deinit();
    try t.expectEqualStrings(" x ", try (try f.root().child("b")).text([]const u8));
    try t.expectEqualStrings("", try (try f.root().child("c")).text([]const u8));
    try t.expectEqualStrings("", try (try f.root().child("d")).text([]const u8));
}

test "ignoreAll" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a x=\"1\"><b/></a>", &diag);
    defer f.deinit();
    f.root().ignoreAll();
    try t.expectError(error.AlreadyUsed, f.root().attr([]const u8, "x"));
    try t.expectError(error.AlreadyUsed, f.root().children("b"));
    try t.expectEqual(null, try f.root().attrOpt([]const u8, "y"));
}

test "visited elements" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a><b/><b/><c/><d/></a>", &diag);
    defer f.deinit();
    const a = f.root();
    try t.expect(a.visited);
    const bs = try a.children("b");
    const c = try a.child("c");
    try t.expect(bs[0].visited and bs[1].visited and c.visited);
    try t.expect(!a.groups[2].elems[0].visited); // d
}

// ------------------------------------------------------------------ custom parsers and allocation

fn identity(s: []const u8) []const u8 {
    return s;
}

const Color = enum {
    red,
    green,

    fn parse(s: []const u8) error{UnknownColor}!Color {
        if (std.mem.eql(u8, s, "red")) return .red;
        if (std.mem.eql(u8, s, "green")) return .green;
        return error.UnknownColor;
    }
};

fn splitWords(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |w| try list.append(gpa, w);
    return list.toOwnedSlice(gpa);
}

test "custom parsers" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a c=\"red\" d=\"blue\" w=\"x y\"><b>green</b></a>", &diag);
    defer f.deinit();
    const a = f.root();

    try t.expectEqual(Color.red, try a.attrWith("c", Color.parse));
    try t.expectError(error.UnknownColor, a.attrWith("d", Color.parse));
    try f.expectDiag(.invalid_value, "/a: \"d\": UnknownColor (input: \"blue\")");
    try t.expectEqual(null, try a.attrOptWith("e", Color.parse));
    try t.expectEqual(Color.green, try (try a.child("b")).textWith(Color.parse));

    const words = try a.attrAllocWith(t.allocator, "w", splitWords);
    defer t.allocator.free(words);
    try t.expectEqual(2, words.len);
    try t.expectEqual(null, try a.attrOptAllocWith(t.allocator, "v", splitWords));
}

test "custom parser for text with allocation" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a>one two three</a>", &diag);
    defer f.deinit();
    const words = try f.root().textAllocWith(t.allocator, splitWords);
    defer t.allocator.free(words);
    try t.expectEqual(3, words.len);
}

/// A user type with a `parseXml` hook.
const Point = struct {
    x: i32,
    y: i32,

    pub fn parseXml(s: []const u8) error{InvalidPoint}!Point {
        const comma = std.mem.indexOfScalar(u8, s, ',') orelse return error.InvalidPoint;
        return .{
            .x = std.fmt.parseInt(i32, s[0..comma], 10) catch return error.InvalidPoint,
            .y = std.fmt.parseInt(i32, s[comma + 1 ..], 10) catch return error.InvalidPoint,
        };
    }
};

test "parseXml hook" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a p=\"1,2\" q=\"3\"/>", &diag);
    defer f.deinit();
    try t.expectEqual(Point{ .x = 1, .y = 2 }, try f.root().attr(Point, "p"));
    // Errors of hooks are reported as InvalidValue, with the original error name as message.
    try t.expectError(error.InvalidValue, f.root().attr(Point, "q"));
    try f.expectDiag(.invalid_value, "/a: \"q\": InvalidPoint (input: \"3\")");
}

test "...Alloc variants copy strings" {
    var diag: Diagnostics = .{};
    const input = "<a x=\"plain\"><b>text</b></a>";
    var f = try Fixture.init(input, &diag);
    const x = try f.root().attrAlloc(t.allocator, []const u8, "x");
    defer t.allocator.free(x);
    const y = try f.root().attrOptAlloc(t.allocator, []const u8, "y");
    try t.expectEqual(null, y);
    const b = try (try f.root().child("b")).textAlloc(t.allocator, []const u8);
    defer t.allocator.free(b);
    f.deinit(); // values outlive the document
    try t.expectEqualStrings("plain", x);
    try t.expectEqualStrings("text", b);
}

test "...Alloc variants report out of memory" {
    var diag: Diagnostics = .{};
    var f = try Fixture.init("<a x=\"plain\"/>", &diag);
    defer f.deinit();
    var failing: std.testing.FailingAllocator = .init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, f.root().attrAlloc(failing.allocator(), []const u8, "x"));
    try t.expectEqual(Diagnostics.Kind.none, diag.kind);
    try t.expectError(error.AlreadyUsed, f.root().attr([]const u8, "x"));
}
