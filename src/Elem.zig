//! An element of a parsed document.
//!
//! The fields are internal: use the methods. Elements are owned by their `Document`
//! and are valid until `Document.deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("Document.zig");
const Diagnostics = @import("Diagnostics.zig");
const recording = @import("recording.zig");
const value = @import("value.zig");

const Elem = @This();

ctx: *Document.Context,
local_name: []const u8,
parent_elem: ?*Elem,
/// Index among siblings with the same local name.
same_name_index: u32,
/// Attributes without `xmlns` / `xmlns:*`: local name -> value, in document order.
attrs: std.StringArrayHashMapUnmanaged([]const u8),
/// Child elements grouped by local name: local name -> elements in document order.
/// Groups are in order of the first occurrence.
child_groups: std.StringArrayHashMapUnmanaged([]const *Elem),
/// Requested attribute names (existing or not). Allocated in the document's arena.
attrs_used: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Requested names of child elements (existing or not). Allocated in the document's arena.
child_groups_used: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Text content. Always empty when the element has child elements.
text_content: []const u8,
/// The text contains a non-whitespace character or a CDATA section.
text_significant: bool,
/// The text was requested.
text_used: bool = false,
/// `ignoreAll` was called: everything in the element, including its descendants, is used
/// and any further request fails with `error.AlreadyUsed`.
all_used: bool = false,

/// All errors of the extraction functions. Details go to `Document.Options.diagnostics`.
/// Each function returns only the subset that can actually happen (see below).
pub const Error = error{
    /// A required attribute or child element doesn't exist.
    Missing,
    /// More than one child element with the name, but at most one was expected.
    TooMany,
    /// Text was requested from an element that has child elements.
    HasChildren,
    /// The same attribute / child name / text was requested twice.
    AlreadyUsed,
    /// A value parser rejected the string.
    InvalidValue,
    /// See "Out of memory" in the API documentation.
    OutOfMemory,
};

/// Errors of `child`.
pub const ChildError = error{ Missing, TooMany, AlreadyUsed, OutOfMemory };
/// Errors of `childOpt`.
pub const ChildOptError = error{ TooMany, AlreadyUsed, OutOfMemory };
/// Errors of `children`.
pub const ChildrenError = error{ AlreadyUsed, OutOfMemory };
/// Errors of looking up a required attribute (`attr*` without `Opt`), before parsing the value.
pub const AttrLookupError = error{ Missing, AlreadyUsed, OutOfMemory };
/// Errors of looking up an optional attribute (`attrOpt*`), before parsing the value.
pub const AttrOptLookupError = error{ AlreadyUsed, OutOfMemory };
/// Errors of looking up the text (`text*`), before parsing the value.
pub const TextLookupError = error{ HasChildren, AlreadyUsed };
// `attr(T, …)`, `text(T)`, … add the errors of parsing a value of type `T`, see `value.ValueError`.

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

/// Value of attribute `attr_name` parsed as `T`. Fails with `error.Missing` if the attribute is missing.
/// Strings are borrowed (valid while the document and the input live).
pub fn attr(e: *Elem, comptime T: type, attr_name: []const u8) (AttrLookupError || value.ValueError(T, false))!T {
    const v = try e.requiredAttr(attr_name);
    return e.convert(T, null, v, attr_name);
}

/// Like `attr`, but returns null if the attribute is missing.
pub fn attrOpt(e: *Elem, comptime T: type, attr_name: []const u8) (AttrOptLookupError || value.ValueError(T, false))!?T {
    const v = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.convert(T, null, v, attr_name);
}

/// Value of attribute `attr_name` parsed by `parser`: a function `fn ([]const u8) E!R` (or a pointer
/// to one), or a value with a method `parse(self, []const u8) E!R` (use it for parsers that need
/// state).
pub fn attrWith(e: *Elem, attr_name: []const u8, parser: anytype) WithResult(AttrLookupError, @TypeOf(parser)) {
    const v = try e.requiredAttr(attr_name);
    return e.callParser(parser, .{v}, attr_name, v);
}

/// Like `attrWith`, but returns null if the attribute is missing.
pub fn attrOptWith(e: *Elem, attr_name: []const u8, parser: anytype) OptWithResult(AttrOptLookupError, @TypeOf(parser)) {
    const v = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.callParser(parser, .{v}, attr_name, v);
}

/// Like `attr`, but the result is allocated with `gpa` (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) (AttrLookupError || value.ValueError(T, true))!T {
    const v = try e.requiredAttr(attr_name);
    return e.convert(T, gpa, v, attr_name);
}

/// Like `attrOpt`, but the result is allocated with `gpa` (strings are copied).
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) (AttrOptLookupError || value.ValueError(T, true))!?T {
    const v = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.convert(T, gpa, v, attr_name);
}

/// Value of attribute `attr_name` parsed by `parser`, which gets `gpa`: a function
/// `fn (Allocator, []const u8) E!R` (or a pointer to one), or a value with a method `parse(self, Allocator, []const u8) E!R`.
pub fn attrAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, parser: anytype) WithResult(AttrLookupError, @TypeOf(parser)) {
    const v = try e.requiredAttr(attr_name);
    return e.callParser(parser, .{ gpa, v }, attr_name, v);
}

/// Like `attrAllocWith`, but returns null if the attribute is missing.
pub fn attrOptAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, parser: anytype) OptWithResult(AttrOptLookupError, @TypeOf(parser)) {
    const v = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.callParser(parser, .{ gpa, v }, attr_name, v);
}

// ------------------------------------------------------------------ child elements

/// The only child element named `child_name`. Fails with `error.Missing` if there is none
/// and with `error.TooMany` if there are more.
pub fn child(e: *Elem, child_name: []const u8) ChildError!*Elem {
    const elems = try e.children(child_name);
    if (elems.len == 0) {
        e.report(.missing, child_name, null, "expected exactly one child element, found none");
        return error.Missing;
    }
    if (elems.len > 1) {
        e.report(.too_many, child_name, null, "expected exactly one child element, found more than one");
        return error.TooMany;
    }
    return elems[0];
}

/// The child element named `child_name`, or null. Fails with `error.TooMany` if there are more.
pub fn childOpt(e: *Elem, child_name: []const u8) ChildOptError!?*Elem {
    const elems = try e.children(child_name);
    if (elems.len > 1) {
        e.report(.too_many, child_name, null, "expected at most one child element, found more than one");
        return error.TooMany;
    }
    if (elems.len == 0) return null;
    return elems[0];
}

/// All child elements named `child_name` in document order (possibly none).
/// The slice is owned by the document.
pub fn children(e: *Elem, child_name: []const u8) ChildrenError![]const *Elem {
    const i = try e.useName(.child, child_name) orelse return &.{};
    return e.child_groups.values()[i];
}

// ------------------------------------------------------------------ text

/// Text of the element parsed as `T`. Strings are borrowed.
/// Fails with `error.HasChildren` if the element has child elements.
pub fn text(e: *Elem, comptime T: type) (TextLookupError || value.ValueError(T, false))!T {
    try e.useText();
    return e.convert(T, null, e.text_content, null);
}

/// Text of the element parsed by `parser` (a function or a value with `parse`, see `attrWith`).
pub fn textWith(e: *Elem, parser: anytype) WithResult(TextLookupError, @TypeOf(parser)) {
    try e.useText();
    return e.callParser(parser, .{e.text_content}, null, e.text_content);
}

/// Like `text`, but the result is allocated with `gpa` (strings are copied).
pub fn textAlloc(e: *Elem, gpa: Allocator, comptime T: type) (TextLookupError || value.ValueError(T, true))!T {
    try e.useText();
    return e.convert(T, gpa, e.text_content, null);
}

/// Text of the element parsed by `parser`, which gets `gpa` (see `attrAllocWith`).
pub fn textAllocWith(e: *Elem, gpa: Allocator, parser: anytype) WithResult(TextLookupError, @TypeOf(parser)) {
    try e.useText();
    return e.callParser(parser, .{ gpa, e.text_content }, null, e.text_content);
}

// ------------------------------------------------------------------ ignoring

/// Marks everything in `e` as used: attributes, child elements and the text, including
/// the content of all descendants. Afterwards every request on `e` (even for a name that
/// doesn't exist) fails with `error.AlreadyUsed`.
pub fn ignoreAll(e: *Elem) void {
    e.all_used = true;
}

// ------------------------------------------------------------------ internals

/// Result of a `...With` function: errors of the lookup and of the custom parser.
fn WithResult(comptime LookupError: type, comptime Parser: type) type {
    const r = value.ParserResult(Parser);
    return (LookupError || r[0])!r[1];
}

fn OptWithResult(comptime LookupError: type, comptime Parser: type) type {
    const r = value.ParserResult(Parser);
    return (LookupError || r[0])!?r[1];
}

fn report(e: *Elem, kind: Diagnostics.Kind, selector: ?[]const u8, input: ?[]const u8, message: []const u8) void {
    if (e.ctx.diag) |d| recording.record(d, kind, e, selector, input, message);
}

const document_oom_message = "document out of memory";
const value_oom_message = "out of memory while producing the value";

/// Records that the document's internal memory ran out while remembering `wanted_name`.
fn reportDocumentOutOfMemory(e: *Elem, wanted_name: []const u8) error{OutOfMemory} {
    e.report(.document_out_of_memory, wanted_name, null, document_oom_message);
    return error.OutOfMemory;
}

const NameKind = enum { attr, child };

/// Marks the attribute or child name `wanted` as used (it may not exist in `e`).
/// Returns its index in `attrs` / `child_groups`, or null if `e` doesn't have it.
fn useName(e: *Elem, comptime kind: NameKind, wanted: []const u8) error{ AlreadyUsed, OutOfMemory }!?usize {
    const message = switch (kind) {
        .attr => "attribute was already used",
        .child => "child elements were already used",
    };
    if (e.all_used) {
        e.report(.already_used, wanted, null, message);
        return error.AlreadyUsed;
    }
    const names = switch (kind) {
        .attr => e.attrs.keys(),
        .child => e.child_groups.keys(),
    };
    const found = switch (kind) {
        .attr => e.attrs.getIndex(wanted),
        .child => e.child_groups.getIndex(wanted),
    };
    const used = switch (kind) {
        .attr => &e.attrs_used,
        .child => &e.child_groups_used,
    };
    if (used.contains(wanted)) {
        e.report(.already_used, wanted, null, message);
        return error.AlreadyUsed;
    }
    const arena = e.ctx.arena.allocator();
    // The key must not point to the caller's memory.
    const key = if (found) |i| names[i] else arena.dupe(u8, wanted) catch
        return e.reportDocumentOutOfMemory(wanted);
    used.putNoClobber(arena, key, {}) catch return e.reportDocumentOutOfMemory(wanted);
    return found;
}

/// Marks attribute `attr_name` as used and returns its value, or null if it doesn't exist.
fn optionalAttr(e: *Elem, attr_name: []const u8) AttrOptLookupError!?[]const u8 {
    const i = try e.useName(.attr, attr_name) orelse return null;
    return e.attrs.values()[i];
}

fn requiredAttr(e: *Elem, attr_name: []const u8) AttrLookupError![]const u8 {
    return try e.optionalAttr(attr_name) orelse {
        e.report(.missing, attr_name, null, "attribute is missing");
        return error.Missing;
    };
}

fn useText(e: *Elem) TextLookupError!void {
    if (e.text_used or e.all_used) {
        e.report(.already_used, null, null, "text was already used");
        return error.AlreadyUsed;
    }
    e.text_used = true;
    if (e.child_groups.count() > 0) {
        e.report(.has_children, null, null, "element has child elements, so it has no text");
        return error.HasChildren;
    }
}

/// `gpa` is `null` (borrowed result) or an `Allocator` (owned result), see `value.parse`.
fn convert(e: *Elem, comptime T: type, gpa: anytype, s: []const u8, selector: ?[]const u8) value.ValueError(T, value.isOwned(@TypeOf(gpa)))!T {
    var message: []const u8 = undefined;
    return value.parse(T, gpa, s, &message) catch |err| {
        if (@as(anyerror, err) == error.OutOfMemory) {
            e.report(.value_out_of_memory, selector, null, value_oom_message);
        } else {
            e.report(.invalid_value, selector, s, message);
        }
        return err;
    };
}

fn callParser(e: *Elem, parser: anytype, args: anytype, selector: ?[]const u8, s: []const u8) WithResult(error{}, @TypeOf(parser)) {
    const R = @typeInfo(value.ParseFn(@TypeOf(parser))).@"fn".return_type.?;
    if (@typeInfo(R) == .error_union) {
        return value.callParser(parser, args) catch |err| {
            if (@as(anyerror, err) == error.OutOfMemory) {
                // The parser can't use the document's memory, so it is the value's.
                e.report(.value_out_of_memory, selector, null, value_oom_message);
            } else {
                e.report(.invalid_value, selector, s, @errorName(err));
            }
            return err;
        };
    } else {
        return value.callParser(parser, args);
    }
}
