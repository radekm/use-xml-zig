//! An element of a parsed document.
//!
//! The fields are internal: use the methods. Elements are owned by their `Document`
//! and are valid until `Document.deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("Document.zig");
const Diagnostics = @import("Diagnostics.zig");
const value = @import("value.zig");

const Elem = @This();

ctx: *Document.Context,
local_name: []const u8,
prefix: []const u8,
parent_elem: ?*Elem,
/// Index among siblings with the same local name.
same_name_index: u32,
/// Attributes without `xmlns` / `xmlns:*`, in document order.
attrs: []Attr,
/// Child elements grouped by local name, in order of the first occurrence.
groups: []Group,
/// Text content. Always empty when the element has child elements.
text_content: []const u8,
/// The text contains a non-whitespace character or a CDATA section.
text_significant: bool,
/// The text was requested (or `ignoreAll` was called).
text_used: bool = false,
/// The element was returned by `child*` / `children` (or is the root).
/// Only visited elements are examined when reporting unused data.
visited: bool = false,
/// Names that were requested but don't exist in this element.
missing: ?*Missing = null,

/// Errors of the extraction functions. Details are in `Document.diagnostics()`.
pub const Error = error{
    /// Missing attribute/child, too many children, or text of an element with children.
    WrongCount,
    /// The same attribute / child name / text was requested twice.
    AlreadyUsed,
    /// A value parser rejected the string.
    InvalidValue,
    OutOfMemory,
};

/// Internal: a requested name that doesn't exist in the element.
pub const Missing = struct {
    kind: enum { attr, child },
    /// Copy owned by the document.
    name: []const u8,
    next: ?*Missing,
};

/// Internal: an attribute and its usage flag.
pub const Attr = struct {
    local_name: []const u8,
    prefix: []const u8,
    value: []const u8,
    used: bool = false,
};

/// Internal: child elements with the same local name and their usage flag.
pub const Group = struct {
    local_name: []const u8,
    prefix: []const u8,
    elems: []const *Elem,
    used: bool = false,
};

/// Local name (without prefix).
pub fn name(e: *const Elem) []const u8 {
    return e.local_name;
}

/// Parent element, or null for the root.
pub fn parent(e: *const Elem) ?*Elem {
    return e.parent_elem;
}

/// Index among siblings with the same name (0-based). Used in paths: /company/address[0].
pub fn index(e: *const Elem) u32 {
    return e.same_name_index;
}

/// Printable path from the root, e.g. `/company/address[0]/city[0]` (use with "{f}").
/// Printing doesn't allocate and takes time quadratic in the depth of `e`.
pub fn path(e: *const Elem) Path {
    return .{ .elem = e };
}

/// Printable path of an element, returned by `path`.
pub const Path = struct {
    elem: *const Elem,

    pub fn format(p: Path, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Error paths only: quadratic in depth, but without recursion and allocation.
        var depth: usize = 0;
        var it: ?*const Elem = p.elem;
        while (it) |e| : (it = e.parent_elem) depth += 1;

        var level: usize = 0;
        while (level < depth) : (level += 1) {
            var a = p.elem;
            var up = depth - 1 - level;
            while (up > 0) : (up -= 1) a = a.parent_elem.?;
            try w.writeByte('/');
            try w.writeAll(a.local_name);
            if (a.parent_elem != null) try w.print("[{d}]", .{a.same_name_index});
        }
    }
};

// ------------------------------------------------------------------ attributes

/// Value of attribute `attr_name` parsed as `T`. Fails with `error.WrongCount` if the attribute is missing.
/// Strings are borrowed (valid while the document and the input live).
pub fn attr(e: *Elem, comptime T: type, attr_name: []const u8) Error!T {
    const a = try e.requiredAttr(attr_name);
    return e.convert(T, null, a.value, a.local_name);
}

/// Like `attr`, but returns null if the attribute is missing.
pub fn attrOpt(e: *Elem, comptime T: type, attr_name: []const u8) Error!?T {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.convert(T, null, a.value, a.local_name);
}

/// Value of attribute `attr_name` parsed by `parser: fn ([]const u8) E!R`.
pub fn attrWith(e: *Elem, attr_name: []const u8, comptime parser: anytype) WithResult(parser) {
    const a = try e.requiredAttr(attr_name);
    return e.callParser(parser, .{a.value}, a.local_name, a.value);
}

/// Like `attrWith`, but returns null if the attribute is missing.
pub fn attrOptWith(e: *Elem, attr_name: []const u8, comptime parser: anytype) OptWithResult(parser) {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.callParser(parser, .{a.value}, a.local_name, a.value);
}

/// Like `attr`, but the result is allocated with `gpa` (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) Error!T {
    const a = try e.requiredAttr(attr_name);
    return e.convert(T, gpa, a.value, a.local_name);
}

/// Like `attrOpt`, but the result is allocated with `gpa` (strings are copied).
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) Error!?T {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.convert(T, gpa, a.value, a.local_name);
}

/// Value of attribute `attr_name` parsed by `parser: fn (Allocator, []const u8) E!R`, which gets `gpa`.
pub fn attrAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, comptime parser: anytype) WithResult(parser) {
    const a = try e.requiredAttr(attr_name);
    return e.callParser(parser, .{ gpa, a.value }, a.local_name, a.value);
}

/// Like `attrAllocWith`, but returns null if the attribute is missing.
pub fn attrOptAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, comptime parser: anytype) OptWithResult(parser) {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.callParser(parser, .{ gpa, a.value }, a.local_name, a.value);
}

// ------------------------------------------------------------------ child elements

/// The only child element named `child_name`. Fails with `error.WrongCount` unless there is exactly one.
pub fn child(e: *Elem, child_name: []const u8) Error!*Elem {
    const g = try e.useGroup(child_name);
    if (g.elems.len != 1) {
        e.report(.wrong_count, g.name, null, if (g.elems.len == 0)
            "expected exactly one child element, found none"
        else
            "expected exactly one child element, found more than one");
        return error.WrongCount;
    }
    g.elems[0].visited = true;
    return g.elems[0];
}

/// The child element named `child_name`, or null. Fails with `error.WrongCount` if there are more.
pub fn childOpt(e: *Elem, child_name: []const u8) Error!?*Elem {
    const g = try e.useGroup(child_name);
    if (g.elems.len > 1) {
        e.report(.wrong_count, g.name, null, "expected at most one child element, found more than one");
        return error.WrongCount;
    }
    if (g.elems.len == 0) return null;
    g.elems[0].visited = true;
    return g.elems[0];
}

/// All child elements named `child_name` in document order (possibly none).
/// The slice is owned by the document.
pub fn children(e: *Elem, child_name: []const u8) Error![]const *Elem {
    const g = try e.useGroup(child_name);
    for (g.elems) |c| c.visited = true;
    return g.elems;
}

// ------------------------------------------------------------------ text

/// Text of the element parsed as `T`. Strings are borrowed.
/// Fails with `error.WrongCount` if the element has child elements.
pub fn text(e: *Elem, comptime T: type) Error!T {
    try e.useText();
    return e.convert(T, null, e.text_content, null);
}

/// Text of the element parsed by `parser: fn ([]const u8) E!R`.
pub fn textWith(e: *Elem, comptime parser: anytype) WithResult(parser) {
    try e.useText();
    return e.callParser(parser, .{e.text_content}, null, e.text_content);
}

/// Like `text`, but the result is allocated with `gpa` (strings are copied).
pub fn textAlloc(e: *Elem, gpa: Allocator, comptime T: type) Error!T {
    try e.useText();
    return e.convert(T, gpa, e.text_content, null);
}

/// Text of the element parsed by `parser: fn (Allocator, []const u8) E!R`, which gets `gpa`.
pub fn textAllocWith(e: *Elem, gpa: Allocator, comptime parser: anytype) WithResult(parser) {
    try e.useText();
    return e.callParser(parser, .{ gpa, e.text_content }, null, e.text_content);
}

// ------------------------------------------------------------------ ignoring

/// Marks all attributes, child names and the text of `e` as used.
/// Child elements are not visited, so their content is not reported either.
pub fn ignoreAll(e: *Elem) void {
    for (e.attrs) |*a| a.used = true;
    for (e.groups) |*g| g.used = true;
    e.text_used = true;
}

// ------------------------------------------------------------------ internals

fn WithResult(comptime parser: anytype) type {
    const r = value.ParserResult(parser);
    return (Error || r[0])!r[1];
}

fn OptWithResult(comptime parser: anytype) type {
    const r = value.ParserResult(parser);
    return (Error || r[0])!?r[1];
}

fn report(e: *Elem, kind: Diagnostics.Kind, selector: ?[]const u8, input: ?[]const u8, message: []const u8) void {
    e.ctx.diag = .{ .kind = kind, .elem = e, .selector = selector, .input = input, .message = message };
}

/// Records that `wanted` (which doesn't exist) was requested. Returns the stored copy of `wanted`.
fn useMissing(e: *Elem, kind: @FieldType(Missing, "kind"), wanted: []const u8, message: []const u8) Error![]const u8 {
    var it = e.missing;
    while (it) |m| : (it = m.next) {
        if (m.kind == kind and std.mem.eql(u8, m.name, wanted)) {
            e.report(.already_used, m.name, null, message);
            return error.AlreadyUsed;
        }
    }
    const arena = e.ctx.arena.allocator();
    const node = try arena.create(Missing);
    node.* = .{ .kind = kind, .name = try arena.dupe(u8, wanted), .next = e.missing };
    e.missing = node;
    return node.name;
}

const attr_used_message = "attribute was already used";

/// Marks attribute `attr_name` as used. Returns null and remembers the name if it doesn't exist.
fn optionalAttr(e: *Elem, attr_name: []const u8) Error!?*Attr {
    if (e.findAttr(attr_name)) |a| {
        if (a.used) {
            e.report(.already_used, a.local_name, null, attr_used_message);
            return error.AlreadyUsed;
        }
        a.used = true;
        return a;
    }
    _ = try e.useMissing(.attr, attr_name, attr_used_message);
    return null;
}

fn requiredAttr(e: *Elem, attr_name: []const u8) Error!*Attr {
    if (e.findAttr(attr_name)) |a| {
        if (a.used) {
            e.report(.already_used, a.local_name, null, attr_used_message);
            return error.AlreadyUsed;
        }
        a.used = true;
        return a;
    }
    const stored = try e.useMissing(.attr, attr_name, attr_used_message);
    e.report(.wrong_count, stored, null, "attribute is missing");
    return error.WrongCount;
}

const GroupUse = struct { name: []const u8, elems: []const *Elem };

/// Marks the group of children named `child_name` as used (or remembers the missing name).
fn useGroup(e: *Elem, child_name: []const u8) Error!GroupUse {
    const message = "child elements were already used";
    if (e.findGroup(child_name)) |g| {
        if (g.used) {
            e.report(.already_used, g.local_name, null, message);
            return error.AlreadyUsed;
        }
        g.used = true;
        return .{ .name = g.local_name, .elems = g.elems };
    }
    return .{ .name = try e.useMissing(.child, child_name, message), .elems = &.{} };
}

fn useText(e: *Elem) Error!void {
    if (e.text_used) {
        e.report(.already_used, null, null, "text was already used");
        return error.AlreadyUsed;
    }
    e.text_used = true;
    if (e.groups.len > 0) {
        e.report(.wrong_count, null, null, "element has child elements, so it has no text");
        return error.WrongCount;
    }
}

/// `gpa` is `null` (borrowed result) or an `Allocator` (owned result), see `value.parse`.
fn convert(e: *Elem, comptime T: type, gpa: anytype, s: []const u8, selector: ?[]const u8) Error!T {
    var failure: value.Failure = undefined;
    return value.parse(T, gpa, s, &failure) catch switch (failure) {
        .out_of_memory => error.OutOfMemory,
        .invalid => |message| {
            e.report(.invalid_value, selector, s, message);
            return error.InvalidValue;
        },
    };
}

fn callParser(e: *Elem, comptime parser: anytype, args: anytype, selector: ?[]const u8, s: []const u8) WithResult(parser) {
    const R = @typeInfo(@TypeOf(parser)).@"fn".return_type.?;
    if (@typeInfo(R) == .error_union) {
        return @call(.auto, parser, args) catch |err| {
            if (@as(anyerror, err) != error.OutOfMemory) e.report(.invalid_value, selector, s, @errorName(err));
            return err;
        };
    } else {
        return @call(.auto, parser, args);
    }
}

/// Finds a group of children by local name.
fn findGroup(e: *const Elem, local_name: []const u8) ?*Group {
    for (e.groups) |*g| {
        if (std.mem.eql(u8, g.local_name, local_name)) return g;
    }
    return null;
}

/// Finds an attribute by local name.
fn findAttr(e: *const Elem, local_name: []const u8) ?*Attr {
    for (e.attrs) |*a| {
        if (std.mem.eql(u8, a.local_name, local_name)) return a;
    }
    return null;
}
