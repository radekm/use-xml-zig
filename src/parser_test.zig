//! Tests of the XML parser and of the resulting element tree.

const std = @import("std");
const t = std.testing;
const Document = @import("Document.zig");
const Elem = @import("Elem.zig");
const ParseDiagnostics = @import("ParseDiagnostics.zig");

// These helpers read the fields directly, so that the tests don't mark anything as used.

fn group(e: *const Elem, name: []const u8) []const *Elem {
    for (e.groups) |g| {
        if (std.mem.eql(u8, g.local_name, name)) return g.elems;
    }
    return &.{};
}

fn attrValue(e: *const Elem, name: []const u8) ?[]const u8 {
    for (e.attrs) |a| {
        if (std.mem.eql(u8, a.local_name, name)) return a.value;
    }
    return null;
}

fn isInside(outer: []const u8, inner: []const u8) bool {
    const o = @intFromPtr(outer.ptr);
    const i = @intFromPtr(inner.ptr);
    return i >= o and i + inner.len <= o + outer.len;
}

fn expectInvalid(input: []const u8, message: []const u8, line: u32, column: u32) !void {
    return expectInvalidWithDepth(input, 256, message, line, column);
}

fn expectInvalidWithDepth(input: []const u8, max_depth: u32, message: []const u8, line: u32, column: u32) !void {
    var diag: ParseDiagnostics = .{};
    const options: Document.Options = .{ .diagnostics = &diag, .max_depth = max_depth };
    try t.expectError(error.InvalidXml, Document.parse(t.allocator, input, options));
    try t.expectEqualStrings(message, diag.message);
    try t.expectEqual(line, diag.line);
    try t.expectEqual(column, diag.column);
}

// ------------------------------------------------------------------ valid documents

test "xml declaration and BOM" {
    const inputs = [_][]const u8{
        "<animals/>",
        "<?xml version=\"1.0\"?><animals />",
        "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<animals></animals>",
        "\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"UTF-8\"?><animals/>",
        "<!-- c --><?pi data?>\n<animals/>\n<!-- after --><?pi?>\n",
    };
    for (inputs) |input| {
        var doc = try Document.parse(t.allocator, input, .{});
        defer doc.deinit();
        try t.expectEqualStrings("animals", doc.root().name());
        try t.expectEqual(null, doc.root().parent());
    }
}

test "child elements are grouped by name in document order" {
    const input =
        \\<animals>
        \\    <dog>A</dog>
        \\    <pig>B</pig>
        \\    <dog>D</dog>
        \\</animals>
    ;
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    const root = doc.root();

    try t.expectEqual(2, root.groups.len);
    try t.expectEqualStrings("dog", root.groups[0].local_name);
    try t.expectEqualStrings("pig", root.groups[1].local_name);
    try t.expectEqualStrings("", root.text_content);

    const dogs = group(root, "dog");
    try t.expectEqual(2, dogs.len);
    try t.expectEqualStrings("A", dogs[0].text_content);
    try t.expectEqualStrings("D", dogs[1].text_content);
    try t.expectEqual(0, dogs[0].index());
    try t.expectEqual(1, dogs[1].index());
    try t.expectEqual(root, dogs[1].parent().?);
    try t.expect(dogs[0].text_significant);

    const pigs = group(root, "pig");
    try t.expectEqual(1, pigs.len);
    try t.expectEqual(0, pigs[0].index());
    // Text without references is borrowed from the input.
    try t.expect(isInside(input, pigs[0].text_content));
}

test "attributes" {
    const input =
        \\<people>
        \\    <person name="Pete" />
        \\    <person name='Harry' address="Little &amp; Whinging" />
        \\</people>
    ;
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    const people = group(doc.root(), "person");
    try t.expectEqual(2, people.len);
    try t.expectEqualStrings("Pete", attrValue(people[0], "name").?);
    try t.expectEqual(null, attrValue(people[0], "address"));
    try t.expectEqualStrings("Harry", attrValue(people[1], "name").?);
    try t.expectEqualStrings("Little & Whinging", attrValue(people[1], "address").?);
    try t.expect(isInside(input, attrValue(people[0], "name").?));
}

test "attribute value normalisation" {
    var doc = try Document.parse(t.allocator, "<a v=\"x\ty\r\nz\rw\n&#10;&#x9;\"/>", .{});
    defer doc.deinit();
    try t.expectEqualStrings("x y z w \n\t", attrValue(doc.root(), "v").?);
}

test "namespace declarations are skipped and prefixes ignored" {
    const input =
        \\<root xmlns="urn:default" xmlns:h="http://www.w3.org/TR/html4/" id="1">
        \\    <h:table h:border="1">
        \\        <h:tr><h:td>Cell</h:td></h:tr>
        \\    </h:table>
        \\</root>
    ;
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    const root = doc.root();
    try t.expectEqual(1, root.attrs.len);
    try t.expectEqualStrings("1", attrValue(root, "id").?);

    const table = group(root, "table")[0];
    try t.expectEqualStrings("table", table.name());
    try t.expectEqualStrings("h", table.prefix);
    try t.expectEqualStrings("1", attrValue(table, "border").?);
    const td = group(group(table, "tr")[0], "td")[0];
    try t.expectEqualStrings("Cell", td.text_content);
}

test "text: references, CDATA, comments, line endings" {
    const input = "<a>x &lt;&gt;&amp;&apos;&quot; &#65;&#x10D;<!-- c -->y<?pi?><![CDATA[<z>&amp;]]>\r\nend\r</a>";
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    try t.expectEqualStrings("x <>&'\" Ačy<z>&amp;\nend\n", doc.root().text_content);
    try t.expect(doc.root().text_significant);
}

test "CDATA with a CR may contain '<' and '&'" {
    const input = "<a><![CDATA[\r\n<b>&amp;\r]]></a>";
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    try t.expectEqualStrings("\n<b>&amp;\n", doc.root().text_content);
}

test "whitespace" {
    const input = "<a>\n  <b>  </b>\n  <c><![CDATA[ ]]></c>\n  <d/>\n  <e></e>\n</a>";
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    const a = doc.root();
    // Whitespace around child elements is not text.
    try t.expectEqualStrings("", a.text_content);
    try t.expect(!a.text_significant);

    // Whitespace-only text of a leaf element is kept but isn't significant.
    const b = group(a, "b")[0];
    try t.expectEqualStrings("  ", b.text_content);
    try t.expect(!b.text_significant);

    // CDATA is always significant.
    const c = group(a, "c")[0];
    try t.expectEqualStrings(" ", c.text_content);
    try t.expect(c.text_significant);

    for ([_][]const u8{ "d", "e" }) |name| {
        const e = group(a, name)[0];
        try t.expectEqualStrings("", e.text_content);
        try t.expect(!e.text_significant);
    }
}

test "many attributes and many groups of children (hash map lookup)" {
    const gpa = t.allocator;
    const n = 2000; // well above the threshold of the hash map
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Many attributes.
    try buf.appendSlice(gpa, "<r xmlns:p=\"u\"");
    for (0..n) |i| try buf.print(gpa, " a{d}=\"{d}\"", .{ i, i });
    try buf.appendSlice(gpa, ">");
    // Many groups of children; every name occurs twice.
    for (0..2) |_| {
        for (0..n) |i| try buf.print(gpa, "<c{d}/>", .{i});
    }
    try buf.appendSlice(gpa, "</r>");
    {
        var doc = try Document.parse(gpa, buf.items, .{});
        defer doc.deinit();
        const r = doc.root();
        try t.expectEqual(n, r.attrs.len);
        try t.expectEqualStrings("1234", attrValue(r, "a1234").?);
        try t.expectEqual(n, r.groups.len);
        for (r.groups, 0..) |g, i| {
            var name_buf: [16]u8 = undefined;
            try t.expectEqualStrings(try std.fmt.bufPrint(&name_buf, "c{d}", .{i}), g.local_name);
            try t.expectEqual(2, g.elems.len);
            try t.expectEqual(1, g.elems[1].same_name_index);
        }
    }

    // Errors are found at the same place as with linear lookup.
    // `marker` is where the error is reported.
    const cases = [_]struct { tail: []const u8, marker: []const u8, message: []const u8 }{
        .{ .tail = " a7=\"x\"/>", .marker = "a7=\"x\"", .message = "duplicate attribute" },
        .{ .tail = " p:a7=\"x\"/>", .marker = "p:a7", .message = "multiple attributes with the same local name" },
        .{ .tail = "><c7/><c7/><p:c7/></r>", .marker = "<p:c7", .message = "child elements with the same local name have different prefixes" },
    };
    for (cases) |c| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, "<r xmlns:p=\"u\"");
        for (0..n) |i| try buf.print(gpa, " a{d}=\"\"", .{i});
        if (std.mem.startsWith(u8, c.tail, ">")) {
            // Children instead of extra attributes.
            try buf.appendSlice(gpa, ">");
            for (0..n) |i| try buf.print(gpa, "<c{d}/>", .{i});
            try buf.appendSlice(gpa, c.tail[1..]);
        } else {
            try buf.appendSlice(gpa, c.tail);
        }
        const offset = std.mem.lastIndexOf(u8, buf.items, c.marker).?;
        var diag: ParseDiagnostics = .{};
        try t.expectError(error.InvalidXml, Document.parse(gpa, buf.items, .{ .diagnostics = &diag }));
        try t.expectEqualStrings(c.message, diag.message);
        try t.expectEqual(ParseDiagnostics.lineColumn(buf.items, offset).column, diag.column);
    }
}

test "character references to whitespace are text" {
    var doc = try Document.parse(t.allocator, "<a>&#32;&#x9;&#10;</a>", .{});
    defer doc.deinit();
    try t.expectEqualStrings(" \t\n", doc.root().text_content);
    try t.expect(doc.root().text_significant);

    try expectInvalid("<a>&#32;<b/></a>", "mixed content: element contains both text and child elements", 1, 9);
    try expectInvalid("<a><b/>&#x20;</a>", "mixed content: element contains both text and child elements", 1, 8);
}

test "non-ASCII names" {
    var doc = try Document.parse(t.allocator, "<město název=\"Brno\"><ulice/></město>", .{});
    defer doc.deinit();
    try t.expectEqualStrings("město", doc.root().name());
    try t.expectEqualStrings("Brno", attrValue(doc.root(), "název").?);
    try t.expectEqual(1, group(doc.root(), "ulice").len);
}

test "deep nesting does not use the call stack" {
    const depth = 100_000;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    for (0..depth) |_| try buf.appendSlice(t.allocator, "<a>");
    for (0..depth) |_| try buf.appendSlice(t.allocator, "</a>");

    var doc = try Document.parse(t.allocator, buf.items, .{ .max_depth = depth });
    defer doc.deinit();
    var e = doc.root();
    var n: usize = 1;
    while (e.groups.len > 0) : (n += 1) e = e.groups[0].elems[0];
    try t.expectEqual(depth, n);

    try t.expectError(error.InvalidXml, Document.parse(t.allocator, buf.items, .{ .max_depth = depth - 1 }));
}

test "path" {
    const input =
        \\<company>
        \\    <address><city>Prague</city></address>
        \\    <address><street>Baker Street</street><city>London</city></address>
        \\</company>
    ;
    var doc = try Document.parse(t.allocator, input, .{});
    defer doc.deinit();
    var buf: [100]u8 = undefined;

    try t.expectEqualStrings("/company", try std.fmt.bufPrint(&buf, "{f}", .{doc.root().path()}));
    const city = group(group(doc.root(), "address")[1], "city")[0];
    try t.expectEqualStrings("/company/address[1]/city[0]", try std.fmt.bufPrint(&buf, "{f}", .{city.path()}));
}

test "out of memory never leaks" {
    const input =
        \\<?xml version="1.0"?>
        \\<root xmlns:p="urn:x" a="1&amp;2">
        \\  <p:x b="v">text &amp; more<![CDATA[ cdata ]]></p:x>
        \\  <p:x/><y>a</y><y>b</y>
        \\</root>
    ;
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(gpa: std.mem.Allocator, in: []const u8) !void {
            var doc = Document.parse(gpa, in, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidXml => unreachable,
            };
            doc.deinit();
        }
    }.run, .{input});
}

// ------------------------------------------------------------------ invalid documents

test "invalid: from UseData.Xml tests" {
    try expectInvalid("<?xml version=\"1.0\" encoding=\"utf-8\"?>", "missing root element", 1, 39);
    try expectInvalid("\n<root>\n  <a></b>\n</root>\n", "end tag does not match start tag", 3, 6);
    try expectInvalid("<root><person>", "unexpected end of input: element is not closed", 1, 15);
    try expectInvalid(
        \\<country>
        \\  Czech Republic
        \\  <president>Vaclav Havel</president>
        \\</country>
    , "mixed content: element contains both text and child elements", 3, 3);
}

test "invalid: prolog and epilog" {
    try expectInvalid("", "missing root element", 1, 1);
    try expectInvalid("  \n ", "missing root element", 2, 2);
    try expectInvalid("<!DOCTYPE a><a/>", "DOCTYPE is not supported", 1, 1);
    try expectInvalid("x<a/>", "text is not allowed before root element", 1, 1);
    try expectInvalid("<a/>x", "text is not allowed after root element", 1, 5);
    try expectInvalid("<a/><b/>", "only one root element is allowed", 1, 5);
    try expectInvalid(" <?xml version=\"1.0\"?><a/>", "XML declaration is only allowed at the start of the document", 1, 2);
    try expectInvalid("<?xml version=\"1.0\" encoding=\"utf-16\"?><a/>", "unsupported encoding (only UTF-8 is supported)", 1, 31);
    try expectInvalid("<?xml version=\"2.0\"?><a/>", "unsupported XML version", 1, 16);
    try expectInvalid("<?xml encoding=\"utf-8\"?><a/>", "unexpected pseudo-attribute in XML declaration", 1, 7);
    try expectInvalid("<?xml version=\"1.0\" standalone=\"maybe\"?><a/>", "standalone must be 'yes' or 'no'", 1, 33);
    try expectInvalid("<?xml version=\"1.0\"", "unterminated XML declaration", 1, 1);
    try expectInvalid("<?xml", "unterminated XML declaration", 1, 1);
    try expectInvalid("<?xml?><a/>", "XML declaration must contain version", 1, 1);
    try expectInvalid("<?xml?version='1.0'?><a/>", "expected whitespace in XML declaration", 1, 6);
}

test "invalid: characters" {
    try expectInvalid("<a>\x01</a>", "character is not allowed in XML", 1, 4);
    try expectInvalid("<a>\nž\xff</a>", "invalid UTF-8", 2, 2);
    try expectInvalid("<a>&#0;</a>", "character reference to a character not allowed in XML", 1, 4);
    try expectInvalid("<a>&#x110000;</a>", "character reference is out of range", 1, 4);
    try expectInvalid("<a>&#xZ;</a>", "invalid character reference", 1, 4);
    try expectInvalid("<a>&#;</a>", "invalid character reference", 1, 4);
    try expectInvalid("<a>&nbsp;</a>", "unknown entity (only lt, gt, amp, apos and quot are supported)", 1, 4);
    try expectInvalid("<a>a & b</a>", "unterminated reference", 1, 6);
    try expectInvalid("<a>]]></a>", "']]>' is not allowed in text", 1, 4);
}

test "invalid: tags and attributes" {
    try expectInvalid("<1a/>", "expected a name", 1, 2);
    try expectInvalid("<a:b:c/>", "invalid qualified name", 1, 2);
    try expectInvalid("<:a/>", "invalid qualified name", 1, 2);
    try expectInvalid("<a x=\"1\" x=\"2\"/>", "duplicate attribute", 1, 10);
    try expectInvalid("<a p:x=\"1\" q:x=\"2\"/>", "multiple attributes with the same local name", 1, 12);
    try expectInvalid("<a x=\"1\"y=\"2\"/>", "expected whitespace before attribute", 1, 9);
    try expectInvalid("<a x=1/>", "expected quoted value", 1, 6);
    try expectInvalid("<a/ >", "expected '>' after '/'", 1, 3);
    try expectInvalid("<a x='1' / >", "expected '>' after '/'", 1, 10);
    try expectInvalid("<a x/>", "expected '=' after attribute name", 1, 5);
    try expectInvalid("<a x=\"1/>", "unterminated quoted value", 1, 6);
    try expectInvalid("<a x=\"<\"/>", "'<' is not allowed in attribute values", 1, 7);
    try expectInvalid("<a x=\"&foo;\"/>", "unknown entity (only lt, gt, amp, apos and quot are supported)", 1, 7);
    try expectInvalid("<a", "unexpected end of input in start tag", 1, 1);
    try expectInvalid("<a></a", "expected '>' at the end of end tag", 1, 7);
    try expectInvalid("<r><p:a/><q:a/></r>", "child elements with the same local name have different prefixes", 1, 10);
    try expectInvalid("<a><b/>text</a>", "mixed content: element contains both text and child elements", 1, 8);
    try expectInvalid("<a><![CDATA[x]]><b/></a>", "mixed content: element contains both text and child elements", 1, 17);
    try expectInvalid("<a><b/><![CDATA[x]]></a>", "mixed content: element contains both text and child elements", 1, 8);
    try expectInvalid("<a><!ELEMENT a></a>", "unexpected markup in element content", 1, 4);
}

test "invalid: comments, CDATA, processing instructions" {
    try expectInvalid("<a><!-- x -- y --></a>", "'--' is not allowed in comments", 1, 11);
    try expectInvalid("<a><!-- x </a>", "unterminated comment", 1, 4);
    try expectInvalid("<a><![CDATA[x</a>", "unterminated CDATA section", 1, 4);
    try expectInvalid("<a><?pi x</a>", "unterminated processing instruction", 1, 4);
    try expectInvalid("<a><?pi?x?></a>", "expected whitespace after processing instruction target", 1, 8);
}

test "invalid: nesting depth" {
    try expectInvalidWithDepth("<a><b><c/></b></a>", 2, "maximum nesting depth exceeded", 1, 7);
    try expectInvalidWithDepth("<a/>", 0, "maximum nesting depth exceeded", 1, 1);
    var doc = try Document.parse(t.allocator, "<a><b><c/></b></a>", .{ .max_depth = 3 });
    doc.deinit();
}

test "diagnostics format" {
    var diag: ParseDiagnostics = .{};
    try t.expectError(error.InvalidXml, Document.parse(t.allocator, "<a>\n</b>", .{ .diagnostics = &diag }));
    var buf: [100]u8 = undefined;
    try t.expectEqualStrings(
        "invalid XML at line 2, column 1: end tag does not match start tag",
        try std.fmt.bufPrint(&buf, "{f}", .{diag}),
    );
}

test "randomly corrupted input never crashes" {
    const seeds = [_][]const u8{
        "<?xml version=\"1.0\"?><r a=\"1&amp;2\" xmlns:p=\"u\"><p:x b='&#x10D;'>t&lt;<![CDATA[c]]></p:x><!-- c --><y/></r>",
        "<a><b>text\r\n</b><b/><?pi d?></a>",
    };
    const alphabet = "<>/=\"'&;#x![]-?: \n\r\tCDATAabp\xc5\xbe\xff";
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var buf: [256]u8 = undefined;
    for (0..20_000) |_| {
        const seed = seeds[random.uintLessThan(usize, seeds.len)];
        var len = seed.len;
        @memcpy(buf[0..len], seed);
        for (0..random.uintAtMost(usize, 4)) |_| {
            const i = random.uintLessThan(usize, len);
            switch (random.uintLessThan(u8, 3)) {
                0 => buf[i] = alphabet[random.uintLessThan(usize, alphabet.len)],
                1 => len = i, // truncate
                else => if (len < buf.len) {
                    std.mem.copyBackwards(u8, buf[i + 1 .. len + 1], buf[i..len]);
                    buf[i] = alphabet[random.uintLessThan(usize, alphabet.len)];
                    len += 1;
                },
            }
            if (len == 0) break;
        }
        var diag: ParseDiagnostics = .{};
        if (Document.parse(t.allocator, buf[0..len], .{ .diagnostics = &diag })) |doc_const| {
            var doc = doc_const;
            doc.deinit();
        } else |err| {
            try t.expectEqual(error.InvalidXml, err);
            try t.expect(diag.line >= 1 and diag.column >= 1);
        }
    }
}
