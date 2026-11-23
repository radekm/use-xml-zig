//! Non-validating XML 1.0 parser that checks well-formedness and builds the element tree.
//!
//! The parser is iterative: open elements are kept on an explicit stack, so deeply
//! nested input can't overflow the call stack.
//!
//! Supported: XML declaration, elements, attributes, text, CDATA, character references,
//! the 5 predefined entities, comments and processing instructions (both skipped),
//! line-ending and attribute-value normalisation.
//! Rejected: DOCTYPE, mixed content, encodings other than UTF-8.
//! Namespaces are not processed; names are split into prefix and local name only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chars = @import("chars.zig");
const ParseDiagnostics = @import("ParseDiagnostics.zig");
const Document = @import("Document.zig");
const Elem = @import("Elem.zig");

const Error = Document.ParseError;

/// Parses `ctx.input` and returns the root element allocated in `ctx.arena`.
pub fn parse(ctx: *Document.Context, max_depth: u32, diagnostics: ?*ParseDiagnostics) Error!*Elem {
    var p: Parser = .{
        .ctx = ctx,
        .diagnostics = diagnostics,
        .input = ctx.input,
        .gpa = ctx.gpa,
        .arena = ctx.arena.allocator(),
        .max_depth = max_depth,
    };
    defer p.deinit();
    const root = try p.parseDocument();
    ctx.elems = try p.arena.dupe(*Elem, p.all.items);
    return root;
}

const RawAttr = struct {
    qname: []const u8,
    name_offset: usize,
    raw_value: []const u8,
    value_offset: usize,
    // Filled in by `buildAttrs`.
    prefix: []const u8 = "",
    local_name: []const u8 = "",
    is_ns: bool = false,
};

const GroupBuilder = struct {
    local_name: []const u8,
    prefix: []const u8,
    elems: std.ArrayList(*Elem) = .empty,
};

/// Text of an open element. Borrows the input while the text is a single
/// unmodified chunk; switches to an owned buffer otherwise.
const TextBuilder = struct {
    borrowed: []const u8 = "",
    owned: std.ArrayList(u8) = .empty,
    is_owned: bool = false,

    fn appendBorrowed(t: *TextBuilder, gpa: Allocator, s: []const u8) Allocator.Error!void {
        if (!t.is_owned and t.borrowed.len == 0) {
            t.borrowed = s;
            return;
        }
        try t.appendCopy(gpa, s);
    }

    fn appendCopy(t: *TextBuilder, gpa: Allocator, s: []const u8) Allocator.Error!void {
        if (!t.is_owned) {
            t.is_owned = true;
            try t.owned.appendSlice(gpa, t.borrowed);
            t.borrowed = "";
        }
        try t.owned.appendSlice(gpa, s);
    }

    fn reset(t: *TextBuilder) void {
        t.borrowed = "";
        t.owned.clearRetainingCapacity();
        t.is_owned = false;
    }

    fn finish(t: *TextBuilder, arena: Allocator) Allocator.Error![]const u8 {
        if (t.is_owned) return arena.dupe(u8, t.owned.items);
        return t.borrowed;
    }

    fn deinit(t: *TextBuilder, gpa: Allocator) void {
        t.owned.deinit(gpa);
    }
};

/// An element whose start tag was read but whose end tag wasn't yet.
const Frame = struct {
    elem: *Elem,
    qname: []const u8,
    groups: std.ArrayList(GroupBuilder) = .empty,
    text: TextBuilder = .{},
    /// Non-whitespace text or CDATA was found.
    significant: bool = false,

    fn deinit(f: *Frame, gpa: Allocator) void {
        for (f.groups.items) |*g| g.elems.deinit(gpa);
        f.groups.deinit(gpa);
        f.text.deinit(gpa);
    }
};

const DecodeMode = enum { text, attr, cdata };

const Parser = struct {
    ctx: *Document.Context,
    diagnostics: ?*ParseDiagnostics,
    input: []const u8,
    pos: usize = 0,
    /// For temporary data, freed by `deinit`.
    gpa: Allocator,
    /// For the resulting tree.
    arena: Allocator,
    max_depth: u32,
    stack: std.ArrayList(Frame) = .empty,
    attrs: std.ArrayList(RawAttr) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    /// All elements in document order.
    all: std.ArrayList(*Elem) = .empty,

    fn deinit(p: *Parser) void {
        p.all.deinit(p.gpa);
        for (p.stack.items) |*f| f.deinit(p.gpa);
        p.stack.deinit(p.gpa);
        p.attrs.deinit(p.gpa);
        p.scratch.deinit(p.gpa);
    }

    fn fail(p: *Parser, offset: usize, message: []const u8) error{InvalidXml} {
        if (p.diagnostics) |d| {
            const lc = ParseDiagnostics.lineColumn(p.input, offset);
            d.* = .{ .message = message, .line = lc.line, .column = lc.column };
        }
        return error.InvalidXml;
    }

    fn eof(p: *const Parser) bool {
        return p.pos >= p.input.len;
    }

    fn startsWith(p: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.input[p.pos..], s);
    }

    /// Skips `S*`. Returns whether anything was skipped.
    fn skipSpace(p: *Parser) bool {
        const start = p.pos;
        while (p.pos < p.input.len and chars.isSpace(p.input[p.pos])) p.pos += 1;
        return p.pos > start;
    }

    fn expectByte(p: *Parser, c: u8, message: []const u8) error{InvalidXml}!void {
        if (p.eof() or p.input[p.pos] != c) return p.fail(p.pos, message);
        p.pos += 1;
    }

    fn top(p: *Parser) *Frame {
        return &p.stack.items[p.stack.items.len - 1];
    }

    // ---------------------------------------------------------------- document

    fn parseDocument(p: *Parser) Error!*Elem {
        if (p.startsWith("\xEF\xBB\xBF")) p.pos = 3;
        if (chars.findInvalid(p.input[p.pos..])) |bad| return p.fail(p.pos + bad.offset, bad.message);

        if (p.startsWith("<?xml") and p.pos + 5 < p.input.len and chars.isSpace(p.input[p.pos + 5])) {
            try p.parseXmlDecl();
        }

        // Prolog.
        while (true) {
            _ = p.skipSpace();
            if (p.eof()) return p.fail(p.pos, "missing root element");
            if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<?")) {
                try p.skipPi();
            } else if (p.startsWith("<!DOCTYPE")) {
                return p.fail(p.pos, "DOCTYPE is not supported");
            } else if (p.startsWith("<!")) {
                return p.fail(p.pos, "unexpected markup before root element");
            } else if (p.startsWith("<")) {
                break;
            } else {
                return p.fail(p.pos, "text is not allowed before root element");
            }
        }

        const root = try p.parseElements();

        // Epilog.
        while (true) {
            _ = p.skipSpace();
            if (p.eof()) break;
            if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<?")) {
                try p.skipPi();
            } else if (p.startsWith("<!")) {
                return p.fail(p.pos, "unexpected markup after root element");
            } else if (p.startsWith("<")) {
                return p.fail(p.pos, "only one root element is allowed");
            } else {
                return p.fail(p.pos, "text is not allowed after root element");
            }
        }
        return root;
    }

    /// `<?xml` S version (S encoding)? (S standalone)? S? `?>`
    fn parseXmlDecl(p: *Parser) Error!void {
        const decl_start = p.pos;
        p.pos += "<?xml".len;
        // 0 = nothing, 1 = version, 2 = encoding, 3 = standalone.
        var stage: u8 = 0;
        while (true) {
            const had_space = p.skipSpace();
            if (p.startsWith("?>")) {
                p.pos += 2;
                break;
            }
            if (p.eof()) return p.fail(decl_start, "unterminated XML declaration");
            if (!had_space) return p.fail(p.pos, "expected whitespace in XML declaration");

            const name_start = p.pos;
            const name = try p.parseName();
            _ = p.skipSpace();
            try p.expectByte('=', "expected '=' in XML declaration");
            _ = p.skipSpace();
            const value_start = p.pos + 1;
            const value = try p.parseQuoted();

            if (std.mem.eql(u8, name, "version") and stage == 0) {
                if (!isVersionNum(value)) return p.fail(value_start, "unsupported XML version");
                stage = 1;
            } else if (std.mem.eql(u8, name, "encoding") and stage == 1) {
                if (!std.ascii.eqlIgnoreCase(value, "UTF-8")) {
                    return p.fail(value_start, "unsupported encoding (only UTF-8 is supported)");
                }
                stage = 2;
            } else if (std.mem.eql(u8, name, "standalone") and (stage == 1 or stage == 2)) {
                if (!std.mem.eql(u8, value, "yes") and !std.mem.eql(u8, value, "no")) {
                    return p.fail(value_start, "standalone must be 'yes' or 'no'");
                }
                stage = 3;
            } else {
                return p.fail(name_start, "unexpected pseudo-attribute in XML declaration");
            }
        }
        if (stage == 0) return p.fail(decl_start, "XML declaration must contain version");
    }

    fn isVersionNum(s: []const u8) bool {
        if (s.len < 3 or !std.mem.startsWith(u8, s, "1.")) return false;
        for (s[2..]) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }

    /// Reads `"..."` or `'...'` and returns the content without quotes.
    fn parseQuoted(p: *Parser) Error![]const u8 {
        if (p.eof() or (p.input[p.pos] != '"' and p.input[p.pos] != '\'')) {
            return p.fail(p.pos, "expected quoted value");
        }
        const quote = p.input[p.pos];
        const start = p.pos + 1;
        const end = std.mem.indexOfScalarPos(u8, p.input, start, quote) orelse
            return p.fail(p.pos, "unterminated quoted value");
        p.pos = end + 1;
        return p.input[start..end];
    }

    fn skipComment(p: *Parser) Error!void {
        const start = p.pos;
        const body = p.pos + "<!--".len;
        const dashes = std.mem.indexOfPos(u8, p.input, body, "--") orelse
            return p.fail(start, "unterminated comment");
        if (dashes + 2 >= p.input.len or p.input[dashes + 2] != '>') {
            return p.fail(dashes, "'--' is not allowed in comments");
        }
        p.pos = dashes + 3;
    }

    fn skipPi(p: *Parser) Error!void {
        const start = p.pos;
        p.pos += "<?".len;
        const target = try p.parseName();
        if (std.ascii.eqlIgnoreCase(target, "xml")) {
            return p.fail(start, "XML declaration is only allowed at the start of the document");
        }
        const end = std.mem.indexOfPos(u8, p.input, p.pos, "?>") orelse
            return p.fail(start, "unterminated processing instruction");
        if (end != p.pos and !chars.isSpace(p.input[p.pos])) {
            return p.fail(p.pos, "expected whitespace after processing instruction target");
        }
        p.pos = end + 2;
    }

    fn parseName(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (p.pos < p.input.len) {
            const b = p.input[p.pos];
            var cp: u21 = b;
            var n: usize = 1;
            if (b >= 0x80) {
                // The input was validated, so decoding can't fail; be defensive anyway.
                n = std.unicode.utf8ByteSequenceLength(b) catch return p.fail(p.pos, "invalid UTF-8");
                if (p.pos + n > p.input.len) return p.fail(p.pos, "invalid UTF-8");
                cp = std.unicode.utf8Decode(p.input[p.pos .. p.pos + n]) catch
                    return p.fail(p.pos, "invalid UTF-8");
            }
            const ok = if (p.pos == start) chars.isNameStartChar(cp) else chars.isNameChar(cp);
            if (!ok) break;
            p.pos += n;
        }
        if (p.pos == start) return p.fail(start, "expected a name");
        return p.input[start..p.pos];
    }

    const QName = struct { prefix: []const u8, local_name: []const u8 };

    fn splitQName(p: *Parser, qname: []const u8, offset: usize) Error!QName {
        const colon = std.mem.indexOfScalar(u8, qname, ':') orelse
            return .{ .prefix = "", .local_name = qname };
        const prefix = qname[0..colon];
        const local = qname[colon + 1 ..];
        if (prefix.len == 0 or local.len == 0 or std.mem.indexOfScalar(u8, local, ':') != null) {
            return p.fail(offset, "invalid qualified name");
        }
        // The local name must be a valid name on its own (e.g. `a:1` is not allowed).
        const n = std.unicode.utf8ByteSequenceLength(local[0]) catch return p.fail(offset, "invalid UTF-8");
        if (n > local.len) return p.fail(offset, "invalid UTF-8");
        const first = std.unicode.utf8Decode(local[0..n]) catch return p.fail(offset, "invalid UTF-8");
        if (!chars.isNameStartChar(first)) return p.fail(offset, "invalid qualified name");
        return .{ .prefix = prefix, .local_name = local };
    }

    // ---------------------------------------------------------------- elements

    fn parseElements(p: *Parser) Error!*Elem {
        const root = try p.parseStartTag();
        while (p.stack.items.len > 0) {
            if (p.eof()) {
                return p.fail(p.pos, "unexpected end of input: element is not closed");
            }
            if (p.input[p.pos] != '<') {
                try p.parseCharData();
            } else if (p.startsWith("</")) {
                try p.parseEndTag();
            } else if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<![CDATA[")) {
                try p.parseCdata();
            } else if (p.startsWith("<?")) {
                try p.skipPi();
            } else if (p.startsWith("<!")) {
                return p.fail(p.pos, "unexpected markup in element content");
            } else {
                _ = try p.parseStartTag();
            }
        }
        return root;
    }

    fn parseStartTag(p: *Parser) Error!*Elem {
        const tag_start = p.pos;
        p.pos += 1; // '<'
        const qname = try p.parseName();
        const q = try p.splitQName(qname, tag_start + 1);

        p.attrs.clearRetainingCapacity();
        var empty = false;
        while (true) {
            const had_space = p.skipSpace();
            if (p.eof()) return p.fail(tag_start, "unexpected end of input in start tag");
            if (p.input[p.pos] == '>') {
                p.pos += 1;
                break;
            }
            if (p.startsWith("/>")) {
                p.pos += 2;
                empty = true;
                break;
            }
            if (!had_space) return p.fail(p.pos, "expected whitespace before attribute");

            const name_offset = p.pos;
            const attr_name = try p.parseName();
            _ = p.skipSpace();
            try p.expectByte('=', "expected '=' after attribute name");
            _ = p.skipSpace();
            const value_offset = p.pos + 1;
            const raw_value = try p.parseQuoted();
            try p.attrs.append(p.gpa, .{
                .qname = attr_name,
                .name_offset = name_offset,
                .raw_value = raw_value,
                .value_offset = value_offset,
            });
        }
        const attrs = try p.buildAttrs();

        if (p.stack.items.len >= p.max_depth) {
            return p.fail(tag_start, "maximum nesting depth exceeded");
        }
        const elem = try p.arena.create(Elem);
        try p.all.append(p.gpa, elem);
        var parent: ?*Elem = null;
        var same_name_index: u32 = 0;
        if (p.stack.items.len > 0) {
            const f = p.top();
            if (f.significant) {
                return p.fail(tag_start, "mixed content: element contains both text and child elements");
            }
            // Only whitespace so far; it isn't part of the element's text.
            f.text.reset();
            const group = try p.findOrAddGroup(f, q, tag_start);
            same_name_index = std.math.cast(u32, group.elems.items.len) orelse
                return p.fail(tag_start, "too many child elements with the same name");
            try group.elems.append(p.gpa, elem);
            parent = f.elem;
        }
        elem.* = .{
            .ctx = p.ctx,
            .local_name = q.local_name,
            .prefix = q.prefix,
            .parent_elem = parent,
            .same_name_index = same_name_index,
            .attrs = attrs,
            .groups = &.{},
            .text_content = "",
            .text_significant = false,
        };

        if (!empty) {
            try p.stack.append(p.gpa, .{ .elem = elem, .qname = qname });
        }
        return elem;
    }

    fn findOrAddGroup(p: *Parser, f: *Frame, q: QName, offset: usize) Error!*GroupBuilder {
        for (f.groups.items) |*g| {
            if (std.mem.eql(u8, g.local_name, q.local_name)) {
                if (!std.mem.eql(u8, g.prefix, q.prefix)) {
                    return p.fail(offset, "child elements with the same local name have different prefixes");
                }
                return g;
            }
        }
        try f.groups.append(p.gpa, .{ .local_name = q.local_name, .prefix = q.prefix });
        return &f.groups.items[f.groups.items.len - 1];
    }

    /// Checks the attributes in `p.attrs` and copies them (without `xmlns` ones) to the arena.
    fn buildAttrs(p: *Parser) Error![]Elem.Attr {
        const raws = p.attrs.items;
        if (raws.len == 0) return &.{};

        var count: usize = 0;
        for (raws, 0..) |*a, i| {
            for (raws[0..i]) |b| {
                if (std.mem.eql(u8, a.qname, b.qname)) return p.fail(a.name_offset, "duplicate attribute");
            }
            const q = try p.splitQName(a.qname, a.name_offset);
            a.prefix = q.prefix;
            a.local_name = q.local_name;
            a.is_ns = std.mem.eql(u8, a.qname, "xmlns") or std.mem.eql(u8, q.prefix, "xmlns");
            if (!a.is_ns) count += 1;
        }

        for (raws, 0..) |a, i| {
            if (a.is_ns) continue;
            for (raws[0..i]) |b| {
                if (!b.is_ns and std.mem.eql(u8, a.local_name, b.local_name)) {
                    return p.fail(a.name_offset, "multiple attributes with the same local name");
                }
            }
        }

        const result = try p.arena.alloc(Elem.Attr, count);
        var j: usize = 0;
        for (raws) |a| {
            // Namespace declarations are decoded too, so that they are validated.
            const value = try p.decodeAttrValue(a.raw_value, a.value_offset);
            if (a.is_ns) continue;
            result[j] = .{ .local_name = a.local_name, .prefix = a.prefix, .value = value };
            j += 1;
        }
        return result;
    }

    fn decodeAttrValue(p: *Parser, raw: []const u8, offset: usize) Error![]const u8 {
        if (std.mem.indexOfAny(u8, raw, "&<\t\n\r") == null) return raw;
        // Decoding never makes the value longer.
        const buf = try p.arena.alloc(u8, raw.len);
        const n = try p.decode(raw, offset, .attr, buf);
        return buf[0..n];
    }

    fn parseEndTag(p: *Parser) Error!void {
        const start = p.pos;
        p.pos += "</".len;
        const qname = try p.parseName();
        _ = p.skipSpace();
        try p.expectByte('>', "expected '>' at the end of end tag");
        const f = p.top();
        if (!std.mem.eql(u8, qname, f.qname)) return p.fail(start, "end tag does not match start tag");
        try p.finishFrame(f);
        var popped = p.stack.pop().?;
        popped.deinit(p.gpa);
    }

    fn finishFrame(p: *Parser, f: *Frame) Error!void {
        const elem = f.elem;
        if (f.groups.items.len > 0) {
            const groups = try p.arena.alloc(Elem.Group, f.groups.items.len);
            for (groups, f.groups.items) |*g, b| {
                g.* = .{
                    .local_name = b.local_name,
                    .prefix = b.prefix,
                    .elems = try p.arena.dupe(*Elem, b.elems.items),
                };
            }
            elem.groups = groups;
        } else {
            elem.text_content = try f.text.finish(p.arena);
            elem.text_significant = f.significant;
        }
    }

    fn parseCharData(p: *Parser) Error!void {
        const start = p.pos;
        const end = std.mem.indexOfScalarPos(u8, p.input, start, '<') orelse p.input.len;
        const raw = p.input[start..end];
        if (std.mem.indexOf(u8, raw, "]]>")) |i| return p.fail(start + i, "']]>' is not allowed in text");
        p.pos = end;

        var text = raw;
        const needs_decoding = std.mem.indexOfAny(u8, raw, "&\r") != null;
        if (needs_decoding) {
            try p.scratch.resize(p.gpa, raw.len);
            const n = try p.decode(raw, start, .text, p.scratch.items);
            text = p.scratch.items[0..n];
        }

        const f = p.top();
        const whitespace = chars.isAllSpace(text);
        if (f.groups.items.len > 0) {
            // Whitespace between child elements is ignored.
            if (!whitespace) {
                return p.fail(start, "mixed content: element contains both text and child elements");
            }
            return;
        }
        if (!whitespace) f.significant = true;
        if (needs_decoding) {
            try f.text.appendCopy(p.gpa, text);
        } else {
            try f.text.appendBorrowed(p.gpa, text);
        }
    }

    fn parseCdata(p: *Parser) Error!void {
        const start = p.pos;
        const body = start + "<![CDATA[".len;
        const end = std.mem.indexOfPos(u8, p.input, body, "]]>") orelse
            return p.fail(start, "unterminated CDATA section");
        const raw = p.input[body..end];
        p.pos = end + 3;

        const f = p.top();
        if (f.groups.items.len > 0) {
            return p.fail(start, "mixed content: element contains both text and child elements");
        }
        f.significant = true;
        if (std.mem.indexOfScalar(u8, raw, '\r') != null) {
            try p.scratch.resize(p.gpa, raw.len);
            const n = try p.decode(raw, body, .cdata, p.scratch.items);
            try f.text.appendCopy(p.gpa, p.scratch.items[0..n]);
        } else {
            try f.text.appendBorrowed(p.gpa, raw);
        }
    }

    /// Decodes references (not in CDATA), normalises line endings and, for attribute
    /// values, whitespace. `out` must be at least `raw.len` bytes long.
    /// Returns the number of bytes written.
    fn decode(p: *Parser, raw: []const u8, offset: usize, mode: DecodeMode, out: []u8) Error!usize {
        var i: usize = 0;
        var j: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            switch (c) {
                '\r' => {
                    out[j] = if (mode == .attr) ' ' else '\n';
                    j += 1;
                    i += 1;
                    if (i < raw.len and raw[i] == '\n') i += 1;
                },
                '\t', '\n' => {
                    out[j] = if (mode == .attr) ' ' else c;
                    j += 1;
                    i += 1;
                },
                '<' => {
                    // Only possible in attribute values; text stops at '<'.
                    return p.fail(offset + i, "'<' is not allowed in attribute values");
                },
                '&' => {
                    if (mode == .cdata) {
                        out[j] = c;
                        j += 1;
                        i += 1;
                        continue;
                    }
                    const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse
                        return p.fail(offset + i, "unterminated reference");
                    const n = try p.decodeReference(raw[i + 1 .. semi], offset + i, out[j..]);
                    j += n;
                    i = semi + 1;
                },
                else => {
                    out[j] = c;
                    j += 1;
                    i += 1;
                },
            }
        }
        return j;
    }

    /// Decodes the body of `&body;` into `out` (which has room for the whole reference).
    fn decodeReference(p: *Parser, body: []const u8, offset: usize, out: []u8) Error!usize {
        const entities = [_]struct { []const u8, u8 }{
            .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "apos", '\'' }, .{ "quot", '"' },
        };
        if (body.len == 0 or body[0] != '#') {
            for (entities) |e| {
                if (std.mem.eql(u8, body, e[0])) {
                    out[0] = e[1];
                    return 1;
                }
            }
            return p.fail(offset, "unknown entity (only lt, gt, amp, apos and quot are supported)");
        }

        const hex = body.len > 1 and body[1] == 'x';
        const digits = body[if (hex) 2 else 1..];
        if (digits.len == 0) return p.fail(offset, "invalid character reference");
        var cp: u32 = 0;
        for (digits) |d| {
            const v = std.fmt.charToDigit(d, if (hex) 16 else 10) catch
                return p.fail(offset, "invalid character reference");
            cp = cp * (if (hex) @as(u32, 16) else 10) + v;
            if (cp > 0x10FFFF) return p.fail(offset, "character reference is out of range");
        }
        const c: u21 = @intCast(cp);
        if (!chars.isChar(c)) return p.fail(offset, "character reference to a character not allowed in XML");
        // `&#x…;` is at least 4 bytes long, so a code point (at most 4 bytes) always fits.
        return std.unicode.utf8Encode(c, out) catch p.fail(offset, "invalid character reference");
    }
};
