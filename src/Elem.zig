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
/// The text was requested (or `ignoreAll` was called).
text_used: bool = false,
/// The element was returned by `child*` / `children` (or is the root).
/// Only visited elements are examined when reporting unused data.
visited: bool = false,

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

/// Errors of `ignoreAll`.
pub const IgnoreError = error{OutOfMemory};

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
    const a = try e.requiredAttr(attr_name);
    return e.convert(T, null, a.value, a.name);
}

/// Like `attr`, but returns null if the attribute is missing.
pub fn attrOpt(e: *Elem, comptime T: type, attr_name: []const u8) (AttrOptLookupError || value.ValueError(T, false))!?T {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.convert(T, null, a.value, a.name);
}

/// Value of attribute `attr_name` parsed by `parser`: a function `fn ([]const u8) E!R` (or a pointer
/// to one), or a value with a method `parse(self, []const u8) E!R` (use it for parsers that need
/// state).
pub fn attrWith(e: *Elem, attr_name: []const u8, parser: anytype) WithResult(AttrLookupError, @TypeOf(parser)) {
    const a = try e.requiredAttr(attr_name);
    return e.callParser(parser, .{a.value}, a.name, a.value);
}

/// Like `attrWith`, but returns null if the attribute is missing.
pub fn attrOptWith(e: *Elem, attr_name: []const u8, parser: anytype) OptWithResult(AttrOptLookupError, @TypeOf(parser)) {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.callParser(parser, .{a.value}, a.name, a.value);
}

/// Like `attr`, but the result is allocated with `gpa` (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) (AttrLookupError || value.ValueError(T, true))!T {
    const a = try e.requiredAttr(attr_name);
    return e.convert(T, gpa, a.value, a.name);
}

/// Like `attrOpt`, but the result is allocated with `gpa` (strings are copied).
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) (AttrOptLookupError || value.ValueError(T, true))!?T {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.convert(T, gpa, a.value, a.name);
}

/// Value of attribute `attr_name` parsed by `parser`, which gets `gpa`: a function
/// `fn (Allocator, []const u8) E!R` (or a pointer to one), or a value with a method `parse(self, Allocator, []const u8) E!R`.
pub fn attrAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, parser: anytype) WithResult(AttrLookupError, @TypeOf(parser)) {
    const a = try e.requiredAttr(attr_name);
    return e.callParser(parser, .{ gpa, a.value }, a.name, a.value);
}

/// Like `attrAllocWith`, but returns null if the attribute is missing.
pub fn attrOptAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, parser: anytype) OptWithResult(AttrOptLookupError, @TypeOf(parser)) {
    const a = (try e.optionalAttr(attr_name)) orelse return null;
    return try e.callParser(parser, .{ gpa, a.value }, a.name, a.value);
}

// ------------------------------------------------------------------ child elements

/// The only child element named `child_name`. Fails with `error.Missing` if there is none
/// and with `error.TooMany` if there are more.
pub fn child(e: *Elem, child_name: []const u8) ChildError!*Elem {
    const g = try e.useGroup(child_name);
    if (g.elems.len == 0) {
        e.report(.missing, g.name, null, "expected exactly one child element, found none");
        return error.Missing;
    }
    if (g.elems.len > 1) {
        e.report(.too_many, g.name, null, "expected exactly one child element, found more than one");
        return error.TooMany;
    }
    g.elems[0].visited = true;
    return g.elems[0];
}

/// The child element named `child_name`, or null. Fails with `error.TooMany` if there are more.
pub fn childOpt(e: *Elem, child_name: []const u8) ChildOptError!?*Elem {
    const g = try e.useGroup(child_name);
    if (g.elems.len > 1) {
        e.report(.too_many, g.name, null, "expected at most one child element, found more than one");
        return error.TooMany;
    }
    if (g.elems.len == 0) return null;
    g.elems[0].visited = true;
    return g.elems[0];
}

/// All child elements named `child_name` in document order (possibly none).
/// The slice is owned by the document.
pub fn children(e: *Elem, child_name: []const u8) ChildrenError![]const *Elem {
    const g = try e.useGroup(child_name);
    for (g.elems) |c| c.visited = true;
    return g.elems;
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

/// Marks all attributes, child names and the text of `e` as used.
/// Child elements are not visited, so their content is not reported either.
/// Fails with `error.OutOfMemory` (and changes nothing) if the document's internal memory runs out.
pub fn ignoreAll(e: *Elem) IgnoreError!void {
    const arena = e.ctx.arena.allocator();
    e.attrs_used.ensureUnusedCapacity(arena, e.attrs.count()) catch
        return e.reportDocumentOutOfMemory(null);
    e.child_groups_used.ensureUnusedCapacity(arena, e.child_groups.count()) catch
        return e.reportDocumentOutOfMemory(null);
    for (e.attrs.keys()) |k| e.attrs_used.putAssumeCapacity(k, {});
    for (e.child_groups.keys()) |k| e.child_groups_used.putAssumeCapacity(k, {});
    e.text_used = true;
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

/// Records that the document's internal memory ran out (while remembering `wanted_name`).
fn reportDocumentOutOfMemory(e: *Elem, wanted_name: ?[]const u8) error{OutOfMemory} {
    e.report(.document_out_of_memory, wanted_name, null, document_oom_message);
    return error.OutOfMemory;
}

/// Adds `wanted` to the set of used names `used`. `stored` is the name as stored in the element,
/// or null if the element doesn't have it (then `wanted` is copied to the document's arena).
/// Returns the name as stored in `used`.
fn markUsed(
    e: *Elem,
    used: *std.StringArrayHashMapUnmanaged(void),
    wanted: []const u8,
    stored: ?[]const u8,
    message: []const u8,
) error{ AlreadyUsed, OutOfMemory }![]const u8 {
    const arena = e.ctx.arena.allocator();
    const gop = used.getOrPut(arena, wanted) catch return e.reportDocumentOutOfMemory(wanted);
    if (gop.found_existing) {
        e.report(.already_used, gop.key_ptr.*, null, message);
        return error.AlreadyUsed;
    }
    // The key must not point to the caller's memory.
    gop.key_ptr.* = stored orelse arena.dupe(u8, wanted) catch {
        _ = used.pop();
        return e.reportDocumentOutOfMemory(wanted);
    };
    return gop.key_ptr.*;
}

const attr_used_message = "attribute was already used";

const AttrUse = struct { name: []const u8, value: []const u8 };

/// Marks attribute `attr_name` as used. Returns null if it doesn't exist.
fn optionalAttr(e: *Elem, attr_name: []const u8) AttrOptLookupError!?AttrUse {
    const i = e.attrs.getIndex(attr_name);
    const stored = if (i) |j| e.attrs.keys()[j] else null;
    const used_name = try e.markUsed(&e.attrs_used, attr_name, stored, attr_used_message);
    const j = i orelse return null;
    return .{ .name = used_name, .value = e.attrs.values()[j] };
}

fn requiredAttr(e: *Elem, attr_name: []const u8) AttrLookupError!AttrUse {
    const i = e.attrs.getIndex(attr_name);
    const stored = if (i) |j| e.attrs.keys()[j] else null;
    const used_name = try e.markUsed(&e.attrs_used, attr_name, stored, attr_used_message);
    const j = i orelse {
        e.report(.missing, used_name, null, "attribute is missing");
        return error.Missing;
    };
    return .{ .name = used_name, .value = e.attrs.values()[j] };
}

const GroupUse = struct { name: []const u8, elems: []const *Elem };

/// Marks the group of children named `child_name` as used (it may not exist).
fn useGroup(e: *Elem, child_name: []const u8) ChildrenError!GroupUse {
    const i = e.child_groups.getIndex(child_name);
    const stored = if (i) |j| e.child_groups.keys()[j] else null;
    const used_name = try e.markUsed(&e.child_groups_used, child_name, stored, "child elements were already used");
    const elems = if (i) |j| e.child_groups.values()[j] else &.{};
    return .{ .name = used_name, .elems = elems };
}

fn useText(e: *Elem) TextLookupError!void {
    if (e.text_used) {
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
