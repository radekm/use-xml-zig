//! An element of a parsed document.
//!
//! The fields are internal: use the methods. Elements are owned by their `Document`
//! and are valid until `Document.deinit`.

const std = @import("std");
const Document = @import("Document.zig");

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

pub const Attr = struct {
    local_name: []const u8,
    prefix: []const u8,
    value: []const u8,
    used: bool = false,
};

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

pub fn parent(e: *const Elem) ?*Elem {
    return e.parent_elem;
}

/// Index among siblings with the same name (0-based). Used in paths: /company/address[0].
pub fn index(e: *const Elem) u32 {
    return e.same_name_index;
}

/// Printable path from the root, e.g. `/company/address[0]/city[0]` (use with "{f}").
pub fn path(e: *const Elem) Path {
    return .{ .elem = e };
}

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

/// Internal: finds a group of children by local name.
pub fn findGroup(e: *const Elem, local_name: []const u8) ?*Group {
    for (e.groups) |*g| {
        if (std.mem.eql(u8, g.local_name, local_name)) return g;
    }
    return null;
}

/// Internal: finds an attribute by local name.
pub fn findAttr(e: *const Elem, local_name: []const u8) ?*Attr {
    for (e.attrs) |*a| {
        if (std.mem.eql(u8, a.local_name, local_name)) return a;
    }
    return null;
}
