//! Code from the guide (`docs/en/guide.md`, `docs/cs/guide.md`), kept here so that it is tested.
//! When you change an example in the guide, change it here too (and vice versa).

const std = @import("std");
const Allocator = std.mem.Allocator;
const use_xml = @import("use_xml");
const t = std.testing;

// ------------------------------------------------------------------ Quick start

const Person = struct {
    name: []const u8, // owned by `arena`
    age: u8,
    email: ?[]const u8, // owned by `arena`
};

/// Reads `<people><person name="…" age="…"><email>…</email></person>…</people>`.
/// The result is allocated in `arena`.
/// On an error of the library, `diag` describes it.
fn readPeople(gpa: Allocator, arena: Allocator, input: []const u8, diag: *use_xml.Diagnostics) ![]Person {
    var doc = try use_xml.Document.parse(gpa, input, .{ .diagnostics = diag });
    defer doc.deinit();

    const persons = try doc.root().children("person");
    const result = try arena.alloc(Person, persons.len);
    for (persons, result) |p, *out| {
        out.* = .{
            .name = try p.attrAlloc(arena, []const u8, "name"),
            .age = try p.attr(u8, "age"),
            .email = if (try p.childOpt("email")) |e| try e.textAlloc(arena, []const u8) else null,
        };
    }

    try doc.expectAllUsed();
    return result;
}

/// The caller owns the diagnostics, so it can report the error after the document is freed.
fn printPeople(gpa: Allocator, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag_buf: [4096]u8 = undefined;
    var diag: use_xml.Diagnostics = .init(&diag_buf);
    const people = readPeople(gpa, arena.allocator(), input, &diag) catch |err| {
        std.log.err("{s}: {f}", .{ @errorName(err), diag });
        return err;
    };
    for (people) |p| std.log.info("{s} ({d})", .{ p.name, p.age });
}

test "quick start" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var diag_buf: [4096]u8 = undefined;
    var diag: use_xml.Diagnostics = .init(&diag_buf);
    const people = try readPeople(t.allocator, arena.allocator(),
        \\<people>
        \\  <person name="Alice" age="31"><email>alice@example.com</email></person>
        \\  <person name="Bob" age="42"/>
        \\</people>
    , &diag);
    try t.expectEqual(2, people.len);
    try t.expectEqualStrings("Alice", people[0].name);
    try t.expectEqualStrings("alice@example.com", people[0].email.?);
    try t.expectEqual(42, people[1].age);
    try t.expectEqual(null, people[1].email);

    // An unused attribute: the description is valid after `readPeople` freed the document.
    try t.expectError(error.UnusedData, readPeople(t.allocator, arena.allocator(),
        \\<people><person name="Bob" age="42" nick="b"/></people>
    , &diag));
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings(
        \\/people/person[0]: "nick": attribute was not used (input: "b")
    , try std.fmt.bufPrint(&buf, "{f}", .{diag}));
    try printPeople(t.allocator, "<people/>");
}

// ------------------------------------------------------------------ Values

/// A user type with a `parseXml` hook: `attr(Size, …)` uses it automatically.
const Size = struct {
    width: u32,
    height: u32,

    pub fn parseXml(s: []const u8) !Size {
        const x = std.mem.indexOfScalar(u8, s, 'x') orelse return error.InvalidSize;
        return .{
            .width = try use_xml.parse.int(u32, s[0..x]),
            .height = try use_xml.parse.int(u32, s[x + 1 ..]),
        };
    }
};

/// A custom parser for `attrWith` / `textWith`.
fn parsePercent(s: []const u8) !f64 {
    if (s.len == 0 or s[s.len - 1] != '%') return error.MissingPercentSign;
    return try use_xml.parse.float(f64, s[0 .. s.len - 1]) / 100;
}

const Fit = enum { contain, cover };

test "values" {
    var doc = try use_xml.Document.parse(t.allocator,
        \\<image size="640x480" fit="cover" opacity="25%" unit="px" created="2026-11-23T10:00:00Z"/>
    , .{});
    defer doc.deinit();
    const img = doc.root();

    const size = try img.attr(Size, "size"); // hook
    const fit = try img.attr(Fit, "fit"); // enum by tag name
    const opacity = try img.attrWith("opacity", parsePercent); // custom parser
    const unit = try img.attrWith("unit", use_xml.parse.oneOf(&.{ "px", "em" }));
    const created = try img.attr(use_xml.Timestamp, "created");

    try t.expectEqual(Size{ .width = 640, .height = 480 }, size);
    try t.expectEqual(Fit.cover, fit);
    try t.expectEqual(0.25, opacity);
    try t.expectEqualStrings("px", unit);
    try t.expectEqual(1795428000, created.seconds);
    try doc.expectAllUsed();
}

/// A custom parser with state: a value with a method `parse`.
const UnitParser = struct {
    allowed: []const []const u8,

    pub fn parse(u: UnitParser, s: []const u8) ![]const u8 {
        for (u.allowed) |a| {
            if (std.mem.eql(u8, a, s)) return s;
        }
        return error.UnknownUnit;
    }
};

test "parser with state" {
    var doc = try use_xml.Document.parse(t.allocator, "<image unit=\"px\"/>", .{});
    defer doc.deinit();
    const img = doc.root();
    const allowed_units: []const []const u8 = &.{ "px", "em" }; // e.g. from a configuration

    const unit = try img.attrWith("unit", UnitParser{ .allowed = allowed_units });
    try t.expectEqualStrings("px", unit);
}

// ------------------------------------------------------------------ Unused data

test "unused data" {
    var doc = try use_xml.Document.parse(t.allocator,
        \\<config version="2">
        \\  <server host="localhost" port="8080" tls="true"/>
        \\  <logging level="debug"/>
        \\</config>
    , .{});
    defer doc.deinit();
    const server = try doc.root().child("server");
    _ = try server.attr([]const u8, "host");
    _ = try server.attr(u16, "port");

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var it = doc.unused();
    while (it.next()) |u| try w.print("{f}\n", .{u});
    try t.expectEqualStrings(
        \\/config: attributes: version="2"; child elements: logging
        \\/config/server[0]: attributes: tls="true"
        \\
    , w.buffered());

    // Data we intentionally don't care about:
    (try doc.root().child("logging")).ignoreAll();
    _ = try doc.root().attr([]const u8, "version");
    _ = try server.attr(bool, "tls");
    try doc.expectAllUsed();
}

// ------------------------------------------------------------------ Errors

test "errors" {
    var diag_buf: [4096]u8 = undefined;
    var diag: use_xml.Diagnostics = .init(&diag_buf);
    var doc = try use_xml.Document.parse(t.allocator, "<server port=\"80x\"/>", .{ .diagnostics = &diag });
    defer doc.deinit();

    try t.expectError(error.InvalidValue, doc.root().attr(u16, "port"));
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings(
        "/server: \"port\": expected integer (u16) (input: \"80x\")",
        try std.fmt.bufPrint(&buf, "{f}", .{diag}),
    );

    try t.expectError(error.InvalidXml, use_xml.Document.parse(t.allocator, "<a>\n<b></a>", .{ .diagnostics = &diag }));
    try t.expectEqual(.invalid_xml, diag.kind);
    try t.expectEqual(2, diag.line);
    try t.expectEqualStrings(
        "invalid XML at line 2, column 4: end tag does not match start tag",
        try std.fmt.bufPrint(&buf, "{f}", .{diag}),
    );
}
