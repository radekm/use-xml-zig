//! Tests of the extraction API (`Elem`). Many are ported from UseData.Xml's `ElemTest.fs`.

const std = @import("std");
const t = std.testing;
const Document = @import("Document.zig");
const Elem = @import("Elem.zig");
const Diagnostics = @import("Diagnostics.zig");

/// Diagnostics with a buffer, on the heap so that their address doesn't change when the
/// fixture is moved (the document keeps a pointer to them).
const DiagBox = struct {
    buf: [512]u8 = undefined,
    diag: Diagnostics = .{},
};

const Fixture = struct {
    doc: Document,
    box: *DiagBox,

    fn init(input: []const u8) !Fixture {
        const box = try t.allocator.create(DiagBox);
        errdefer t.allocator.destroy(box);
        box.* = .{};
        box.diag = .init(&box.buf);
        return .{ .doc = try Document.parse(t.allocator, input, .{ .diagnostics = &box.diag }), .box = box };
    }

    fn deinit(f: *Fixture) void {
        f.doc.deinit();
        t.allocator.destroy(f.box);
    }

    fn root(f: *Fixture) *Elem {
        return f.doc.root();
    }

    fn expectDiag(f: *Fixture, kind: Diagnostics.Kind, formatted: []const u8) !void {
        try t.expectEqual(kind, f.box.diag.kind);
        var buf: [512]u8 = undefined;
        try t.expectEqualStrings(formatted, try std.fmt.bufPrint(&buf, "{f}", .{f.box.diag}));
    }
};

// ------------------------------------------------------------------ UseData.Xml: Basic

test "child elements" {
    var f = try Fixture.init(
        \\<animals>
        \\    <dog>A</dog>
        \\    <pig>B</pig>
        \\    <dog>D</dog>
        \\</animals>
    );
    defer f.deinit();

    const dogs = try f.root().children("dog");
    try t.expectEqual(2, dogs.len);
    try t.expectEqualStrings("A", try dogs[0].text([]const u8));
    try t.expectEqualStrings("D", try dogs[1].text([]const u8));
    try t.expectEqualStrings("B", try (try f.root().child("pig")).text([]const u8));
    try t.expectEqual(null, try f.root().childOpt("cat"));
}

test "attributes" {
    var f = try Fixture.init(
        \\<people>
        \\    <person name="Pete" />
        \\    <person name="Harry" address="Little Whinging" />
        \\</people>
    );
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
        var f = try Fixture.init(input);
        defer f.deinit();
        const tds = try (try (try f.root().child("table")).child("tr")).children("td");
        try t.expectEqual(1, tds.len);
        try t.expectEqualStrings("Cell", try tds[0].text([]const u8));
    }
}

// ------------------------------------------------------------------ UseData.Xml: Errors

test "multiple children when single child is expected" {
    var f = try Fixture.init("<person><name>Peter</name><name>James</name></person>");
    defer f.deinit();
    try t.expectError(error.TooMany, f.root().child("name"));
    try f.expectDiag(.too_many, "/person: \"name\": expected exactly one child element, found more than one");
}

test "multiple children when at most one child is expected" {
    var f = try Fixture.init("<person><name>Peter</name><name>James</name></person>");
    defer f.deinit();
    try t.expectError(error.TooMany, f.root().childOpt("name"));
    try f.expectDiag(.too_many, "/person: \"name\": expected at most one child element, found more than one");
}

test "no child when one child is expected" {
    var f = try Fixture.init("<dog></dog>");
    defer f.deinit();
    try t.expectError(error.Missing, f.root().child("name"));
    try f.expectDiag(.missing, "/dog: \"name\": expected exactly one child element, found none");
}

test "no attribute when one attribute is expected" {
    var f = try Fixture.init("<city></city>");
    defer f.deinit();
    try t.expectError(error.Missing, f.root().attr([]const u8, "name"));
    try f.expectDiag(.missing, "/city: \"name\": attribute is missing");
}

// ------------------------------------------------------------------ usage rules

test "each attribute, child name and text can be used once" {
    var f = try Fixture.init("<a x=\"1\"><b><c>t</c></b><b/></a>");
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
    var f = try Fixture.init("<a/>");
    defer f.deinit();
    const a = f.root();

    try t.expectEqual(null, try a.attrOpt([]const u8, "x"));
    try t.expectError(error.AlreadyUsed, a.attrOpt([]const u8, "x"));
    try f.expectDiag(.already_used, "/a: \"x\": attribute was already used");
    try t.expectError(error.AlreadyUsed, a.attr([]const u8, "x"));

    try t.expectEqual(0, (try a.children("x")).len); // attributes and children are separate
    try t.expectError(error.AlreadyUsed, a.childOpt("x"));
    try f.expectDiag(.already_used, "/a: \"x\": child elements were already used");

    try t.expectError(error.Missing, a.attr([]const u8, "y"));
    try t.expectError(error.AlreadyUsed, a.attrOpt([]const u8, "y"));
}

test "the name passed in may be a temporary buffer" {
    var f = try Fixture.init("<a/>");
    defer f.deinit();
    var name_buf = "zz".*;
    try t.expectError(error.Missing, f.root().attr([]const u8, &name_buf));
    name_buf = "qq".*;
    try f.expectDiag(.missing, "/a: \"zz\": attribute is missing");
    try t.expectError(error.AlreadyUsed, f.root().attr([]const u8, "zz"));
}

test "text of an element with child elements" {
    var f = try Fixture.init("<a> <b/> </a>");
    defer f.deinit();
    try t.expectError(error.HasChildren, f.root().text([]const u8));
    try f.expectDiag(.has_children, "/a: element has child elements, so it has no text");
}

test "text keeps whitespace and empty elements have empty text" {
    var f = try Fixture.init("<a><b> x </b><c/><d></d></a>");
    defer f.deinit();
    try t.expectEqualStrings(" x ", try (try f.root().child("b")).text([]const u8));
    try t.expectEqualStrings("", try (try f.root().child("c")).text([]const u8));
    try t.expectEqualStrings("", try (try f.root().child("d")).text([]const u8));
}

test "ignoreAll" {
    var f = try Fixture.init("<a x=\"1\"><b/></a>");
    defer f.deinit();
    f.root().ignoreAll();
    try t.expectError(error.AlreadyUsed, f.root().attr([]const u8, "x"));
    try t.expectError(error.AlreadyUsed, f.root().children("b"));
    try t.expectEqual(null, try f.root().attrOpt([]const u8, "y"));
}

test "visited elements" {
    var f = try Fixture.init("<a><b/><b/><c/><d/></a>");
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
    var f = try Fixture.init("<a c=\"red\" d=\"blue\" w=\"x y\"><b>green</b></a>");
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

test "custom parsers given as function pointers" {
    var f = try Fixture.init("<a c=\"red\" d=\"blue\" w=\"x y\"><b>green</b><e>u v w</e></a>");
    defer f.deinit();
    const a = f.root();

    // A pointer known only at run time, e.g. chosen from a table.
    var parsers = [_]*const fn ([]const u8) error{UnknownColor}!Color{&Color.parse};
    std.mem.doNotOptimizeAway(&parsers);
    const color = parsers[0];
    try t.expectEqual(Color.red, try a.attrWith("c", color));
    try t.expectError(error.UnknownColor, a.attrWith("d", color));
    try f.expectDiag(.invalid_value, "/a: \"d\": UnknownColor (input: \"blue\")");
    try t.expectEqual(null, try a.attrOptWith("z", color));
    try t.expectEqual(Color.green, try (try a.child("b")).textWith(color));

    const split: *const fn (std.mem.Allocator, []const u8) error{OutOfMemory}![][]const u8 = &splitWords;
    const words = try a.attrAllocWith(t.allocator, "w", split);
    defer t.allocator.free(words);
    try t.expectEqual(2, words.len);
    const more = try (try a.child("e")).textAllocWith(t.allocator, split);
    defer t.allocator.free(more);
    try t.expectEqual(3, more.len);
}

test "custom parser for text with allocation" {
    var f = try Fixture.init("<a>one two three</a>");
    defer f.deinit();
    const words = try f.root().textAllocWith(t.allocator, splitWords);
    defer t.allocator.free(words);
    try t.expectEqual(3, words.len);
}

/// A parser with state: accepts only the units given at run time.
const UnitParser = struct {
    allowed: []const []const u8,

    pub fn parse(u: UnitParser, s: []const u8) error{UnknownUnit}![]const u8 {
        for (u.allowed) |a| {
            if (std.mem.eql(u8, a, s)) return s;
        }
        return error.UnknownUnit;
    }
};

/// A parser with mutable state, passed by pointer: counts the values and copies them.
const CountingCopier = struct {
    count: usize = 0,

    pub fn parse(c: *CountingCopier, gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
        c.count += 1;
        return gpa.dupe(u8, s);
    }
};

test "custom parsers with state" {
    var f = try Fixture.init("<a u=\"px\" v=\"pt\" w=\"x\"><b>em</b><c>y</c></a>");
    defer f.deinit();
    const a = f.root();

    var allowed: std.ArrayList([]const u8) = .empty; // known only at run time
    defer allowed.deinit(t.allocator);
    try allowed.appendSlice(t.allocator, &.{ "px", "em" });
    const units: UnitParser = .{ .allowed = allowed.items };

    try t.expectEqualStrings("px", try a.attrWith("u", units));
    try t.expectError(error.UnknownUnit, a.attrWith("v", units));
    try f.expectDiag(.invalid_value, "/a: \"v\": UnknownUnit (input: \"pt\")");
    try t.expectEqual(null, try a.attrOptWith("missing", units));
    try t.expectEqualStrings("em", try (try a.child("b")).textWith(&units)); // a pointer works too

    var copier: CountingCopier = .{};
    const w = try a.attrAllocWith(t.allocator, "w", &copier);
    defer t.allocator.free(w);
    const y = try (try a.child("c")).textAllocWith(t.allocator, &copier);
    defer t.allocator.free(y);
    try t.expectEqualStrings("x", w);
    try t.expectEqualStrings("y", y);
    try t.expectEqual(2, copier.count);
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
    var f = try Fixture.init("<a p=\"1,2\" q=\"3\"/>");
    defer f.deinit();
    try t.expectEqual(Point{ .x = 1, .y = 2 }, try f.root().attr(Point, "p"));
    // Errors of hooks are reported as InvalidValue, with the original error name as message.
    try t.expectError(error.InvalidValue, f.root().attr(Point, "q"));
    try f.expectDiag(.invalid_value, "/a: \"q\": InvalidPoint (input: \"3\")");
}

/// A user type with both hooks: `parseXml` borrows the input, `parseXmlAlloc` copies it.
const Name = struct {
    s: []const u8,
    owned: bool,

    pub fn parseXml(s: []const u8) error{EmptyName}!Name {
        if (s.len == 0) return error.EmptyName;
        return .{ .s = s, .owned = false };
    }

    pub fn parseXmlAlloc(gpa: std.mem.Allocator, s: []const u8) error{ EmptyName, OutOfMemory }!Name {
        if (s.len == 0) return error.EmptyName;
        return .{ .s = try gpa.dupe(u8, s), .owned = true };
    }
};

test "...Alloc variants use parseXmlAlloc" {
    // `a&amp;b` is decoded into the document's memory, so a borrowed value would dangle.
    var f = try Fixture.init("<a x=\"a&amp;b\" y=\"c\"><b>d&amp;e</b></a>");
    const x = try f.root().attrAlloc(t.allocator, Name, "x");
    defer t.allocator.free(x.s);
    const y = try f.root().attr(Name, "y");
    try t.expect(!y.owned);
    const b = try (try f.root().child("b")).textAlloc(t.allocator, Name);
    defer t.allocator.free(b.s);
    f.deinit(); // values outlive the document
    try t.expect(x.owned and b.owned);
    try t.expectEqualStrings("a&b", x.s);
    try t.expectEqualStrings("d&e", b.s);
    // A type with only `parseXml` (e.g. `Point`) can't be used with `...Alloc`:
    // `attrAlloc(gpa, Point, "p")` is a compile error.
}

test "...Alloc variants copy strings" {
    const input = "<a x=\"plain\"><b>text</b></a>";
    var f = try Fixture.init(input);
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
    var f = try Fixture.init("<a x=\"plain\"/>");
    defer f.deinit();
    var failing: std.testing.FailingAllocator = .init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, f.root().attrAlloc(failing.allocator(), []const u8, "x"));
    try f.expectDiag(.value_out_of_memory, "/a: \"x\": out of memory while producing the value");
    try t.expectError(error.AlreadyUsed, f.root().attr([]const u8, "x"));
}

test "long element names and deep paths are shortened in diagnostics" {
    const gpa = t.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    var diag_buf: [4096]u8 = undefined;
    var diag: Diagnostics = .init(&diag_buf);

    // A long element name doesn't push the rest of the description out of the buffer.
    try input.append(gpa, '<');
    try input.appendNTimes(gpa, 'n', 5000);
    try input.appendSlice(gpa, "/>");
    {
        var doc = try Document.parse(gpa, input.items, .{ .diagnostics = &diag });
        defer doc.deinit();
        try t.expectError(error.Missing, doc.root().attr(u8, "x"));
        try t.expect(!diag.truncated);
        try t.expect(std.mem.startsWith(u8, diag.message(), "/nnnn"));
        try t.expect(std.mem.endsWith(u8, diag.message(), "n…: \"x\": attribute is missing"));
    }

    // A deep path is shortened from the start; the end (the element itself) is kept.
    const depth = 3000;
    input.clearRetainingCapacity();
    for (0..depth) |_| try input.appendSlice(gpa, "<a>");
    for (0..depth) |_| try input.appendSlice(gpa, "</a>");
    {
        var doc = try Document.parse(gpa, input.items, .{ .diagnostics = &diag, .max_depth = depth });
        defer doc.deinit();
        var e = doc.root();
        for (1..depth) |_| e = try e.child("a");
        try t.expectError(error.Missing, e.attr(u8, "x"));
        try t.expect(!diag.truncated);
        try t.expect(std.mem.startsWith(u8, diag.message(), "/…/a[0]/a[0]"));
        try t.expect(std.mem.endsWith(u8, diag.message(), "/a[0]/a[0]: \"x\": attribute is missing"));
        try t.expect(diag.message().len < 2 * Diagnostics.max_input_len);
    }
}

test "out of memory is recorded in diagnostics" {
    // A custom parser that runs out of memory.
    {
        var f = try Fixture.init("<a w=\"x y\"><b/></a>");
        defer f.deinit();
        _ = try f.root().child("b"); // diagnostics must not keep an older state
        var failing: std.testing.FailingAllocator = .init(t.allocator, .{ .fail_index = 0 });
        try t.expectError(error.OutOfMemory, f.root().attrAllocWith(failing.allocator(), "w", splitWords));
        try f.expectDiag(.value_out_of_memory, "/a: \"w\": out of memory while producing the value");
    }
    // A parser without an allocator from us may still return OutOfMemory, and so may a hook.
    {
        var f = try Fixture.init("<a w=\"x\" n=\"y\"/>");
        defer f.deinit();
        const S = struct {
            fn fixedBuffer(s: []const u8) error{OutOfMemory}![]u8 {
                var buf: [0]u8 = undefined;
                var fba: std.heap.FixedBufferAllocator = .init(&buf);
                return fba.allocator().dupe(u8, s);
            }
        };
        try t.expectError(error.OutOfMemory, f.root().attrWith("w", S.fixedBuffer));
        try f.expectDiag(.value_out_of_memory, "/a: \"w\": out of memory while producing the value");
        var failing: std.testing.FailingAllocator = .init(t.allocator, .{ .fail_index = 0 });
        try t.expectError(error.OutOfMemory, f.root().attrAlloc(failing.allocator(), Name, "n"));
        try f.expectDiag(.value_out_of_memory, "/a: \"n\": out of memory while producing the value");
    }
    // Remembering a missing name in the document's arena fails.
    {
        var failing: std.testing.FailingAllocator = .init(t.allocator, .{});
        var diag_buf: [2048]u8 = undefined;
        var diag: Diagnostics = .init(&diag_buf);
        var doc = try Document.parse(failing.allocator(), "<a/>", .{ .diagnostics = &diag });
        defer doc.deinit();
        _ = doc.root().attr(u8, "x") catch {}; // an older error
        failing.fail_index = failing.alloc_index; // fail from now on
        // A name that doesn't fit into the arena's current buffer.
        const long_name = try t.allocator.alloc(u8, 100_000);
        defer t.allocator.free(long_name);
        @memset(long_name, 'n');
        try t.expectError(error.OutOfMemory, doc.root().attrOpt(u8, long_name));
        try t.expectEqual(Diagnostics.Kind.document_out_of_memory, diag.kind);
        // The name is shortened in the description.
        try t.expect(std.mem.startsWith(u8, diag.message(), "/a: \"nnnn"));
        try t.expect(std.mem.endsWith(u8, diag.message(), "n…\": document out of memory"));
        try t.expect(!diag.truncated);
    }
}

test "each function returns only the errors that can happen" {
    var f = try Fixture.init("<a x=\"1\"><b/><b/></a>");
    defer f.deinit();
    const a = f.root();
    // These switches are exhaustive, so they don't compile if an error set gets bigger.
    _ = a.child("b") catch |err| switch (err) {
        error.Missing, error.TooMany, error.AlreadyUsed, error.OutOfMemory => null,
    };
    _ = a.childOpt("c") catch |err| switch (err) {
        error.TooMany, error.AlreadyUsed, error.OutOfMemory => null,
    };
    _ = a.children("d") catch |err| switch (err) {
        error.AlreadyUsed, error.OutOfMemory => null,
    };
    _ = a.attrOpt(u8, "x") catch |err| switch (err) {
        error.AlreadyUsed, error.InvalidValue, error.OutOfMemory => null,
    };
    _ = a.text([]const u8) catch |err| switch (err) {
        error.HasChildren, error.AlreadyUsed, error.InvalidValue, error.OutOfMemory => null,
    };
    // The alias in the root module.
    try t.expect(@import("root.zig").Error == Elem.Error);
}

// ------------------------------------------------------------------ built-in value types

const Timestamp = @import("Timestamp.zig");

test "built-in value types" {
    var f = try Fixture.init(
        \\<v i="-42" u="007" f="+1.25" b="true" e="green" ts="2021-05-31T23:12:04.5Z">3.5</v>
    );
    defer f.deinit();
    const v = f.root();
    try t.expectEqual(@as(i32, -42), try v.attr(i32, "i"));
    try t.expectEqual(@as(u8, 7), try v.attr(u8, "u"));
    try t.expectEqual(@as(f64, 1.25), try v.attr(f64, "f"));
    try t.expectEqual(true, try v.attr(bool, "b"));
    try t.expectEqual(Color.green, try v.attr(Color, "e"));
    try t.expectEqual(Timestamp{ .seconds = 1622502724, .nanos = 500_000_000 }, try v.attr(Timestamp, "ts"));
    try t.expectEqual(@as(f32, 3.5), try v.text(f32));
}

test "built-in value types report invalid values" {
    var f = try Fixture.init(
        \\<v i="300" f="1e3" b="True" e="blue" ts="2021-02-29T00:00:00Z">x</v>
    );
    defer f.deinit();
    const v = f.root();

    try t.expectError(error.InvalidValue, v.attr(u8, "i"));
    try f.expectDiag(.invalid_value, "/v: \"i\": expected integer (u8) (input: \"300\")");
    try t.expectError(error.InvalidValue, v.attr(f64, "f"));
    try f.expectDiag(.invalid_value, "/v: \"f\": expected decimal number (input: \"1e3\")");
    try t.expectError(error.InvalidValue, v.attr(bool, "b"));
    try f.expectDiag(.invalid_value, "/v: \"b\": expected 'true' or 'false' (input: \"True\")");
    try t.expectError(error.InvalidValue, v.attr(Color, "e"));
    try f.expectDiag(.invalid_value, "/v: \"e\": expected one of: red, green (input: \"blue\")");
    try t.expectError(error.InvalidValue, v.attr(Timestamp, "ts"));
    try f.expectDiag(.invalid_value, "/v: \"ts\": expected timestamp YYYY-MM-DDTHH:MM:SS[.fraction]Z (input: \"2021-02-29T00:00:00Z\")");
    try t.expectError(error.InvalidValue, v.text(i64));
    try f.expectDiag(.invalid_value, "/v: expected integer (i64) (input: \"x\")");
}
