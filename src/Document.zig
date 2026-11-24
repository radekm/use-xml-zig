//! A parsed XML document.
//!
//! Not thread-safe, not even for reading: extraction functions change the document (they mark
//! data as used, remember missing names and record diagnostics). Use a document and its elements
//! from one thread at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const ParseDiagnostics = @import("ParseDiagnostics.zig");
const Elem = @import("Elem.zig");
const parser = @import("parser.zig");

const Document = @This();

ctx: *Context,

/// Options for `parse`.
pub const Options = struct {
    /// Filled in when `parse` fails with `error.InvalidXml`.
    diagnostics: ?*ParseDiagnostics = null,
    /// Maximum element nesting depth. Deeper input fails with error.InvalidXml.
    /// The root element has depth 1, so 0 rejects every document.
    /// Printing paths (`Elem.path`, diagnostics) takes time quadratic in the depth.
    max_depth: u32 = 256,
};

/// Errors of `parse`. Details of `InvalidXml` go to `Options.diagnostics`.
pub const ParseError = error{ InvalidXml, OutOfMemory };

/// Internal state shared by the document and its elements.
/// Heap-allocated so that its address stays stable when `Document` is moved.
pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: []const u8,
    /// The last error of an extraction function or of `expectAllUsed`.
    diag: Diagnostics = .{},
    root: *Elem,
    /// All elements in document order.
    elems: []const *Elem,
};

/// Parses the whole input. `input` must stay alive and unchanged until `deinit`.
/// All internal memory comes from `gpa` (through an internal arena).
pub fn parse(gpa: Allocator, input: []const u8, options: Options) ParseError!Document {
    const ctx = try gpa.create(Context);
    errdefer gpa.destroy(ctx);
    ctx.* = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .input = input,
        .root = undefined,
        .elems = &.{},
    };
    errdefer ctx.arena.deinit();
    if (options.diagnostics) |d| d.* = .{};

    ctx.root = try parser.parse(ctx, options.max_depth, options.diagnostics);
    ctx.root.visited = true;
    return .{ .ctx = ctx };
}

/// Frees the document and all its elements. Borrowed values (strings returned without
/// an allocator) and `Diagnostics` pointing into the document become invalid.
pub fn deinit(doc: *Document) void {
    const gpa = doc.ctx.gpa;
    doc.ctx.arena.deinit();
    gpa.destroy(doc.ctx);
    doc.* = undefined;
}

/// The root element.
pub fn root(doc: *Document) *Elem {
    return doc.ctx.root;
}

/// Details about the last error of an extraction function (`attr`, `child`, …) or of
/// `expectAllUsed`. Valid only until `deinit`: report the error before freeing the document.
/// Every error of these functions is recorded (including `OutOfMemory`), successful calls don't
/// change it, so read it right after an error.
pub fn diagnostics(doc: *const Document) Diagnostics {
    return doc.ctx.diag;
}

// ------------------------------------------------------------------ unused data

/// Iterates over visited elements (the root and all elements returned by `child*` / `children`)
/// that have unused content, in document order.
pub fn unused(doc: *Document) UnusedIterator {
    return .{ .elems = doc.ctx.elems };
}

/// Returns error.UnusedData if anything was not used; `diagnostics()` then describes
/// the first unused item (that is the only thing it changes). Call it after extraction.
pub fn expectAllUsed(doc: *Document) error{UnusedData}!void {
    var it = doc.unused();
    const u = it.next() orelse return;
    const d = &doc.ctx.diag;
    d.* = .{ .kind = .unused_data, .elem = u.elem };
    var attrs = u.attrs;
    var children = u.children;
    if (attrs.next()) |a| {
        d.selector = a.name;
        d.input = a.value;
        d.message = "attribute was not used";
    } else if (children.next()) |name| {
        d.selector = name;
        d.message = "child elements were not used";
    } else {
        d.input = u.text;
        d.message = "text was not used";
    }
    return error.UnusedData;
}

/// Returned by `unused`. Call `next` until it returns null.
pub const UnusedIterator = struct {
    elems: []const *Elem,
    index: usize = 0,

    pub fn next(it: *UnusedIterator) ?Unused {
        while (it.index < it.elems.len) {
            const e = it.elems[it.index];
            it.index += 1;
            if (!e.visited) continue;
            const u = Unused.of(e);
            if (u.isEmpty()) continue;
            return u;
        }
        return null;
    }
};

/// Unused content of one visited element.
pub const Unused = struct {
    elem: *const Elem,
    /// Unused attributes (`xmlns` / `xmlns:*` are never reported).
    attrs: UnusedAttrIterator,
    /// Names of child groups that were never requested. Their content is not examined.
    children: UnusedChildNameIterator,
    /// Unused text, or null. Whitespace-only text without CDATA is never reported.
    text: ?[]const u8,

    fn of(e: *const Elem) Unused {
        return .{
            .elem = e,
            .attrs = .{ .attrs = e.attrs },
            .children = .{ .groups = e.groups },
            .text = if (!e.text_used and e.text_significant) e.text_content else null,
        };
    }

    fn isEmpty(u: Unused) bool {
        var attrs = u.attrs;
        var children = u.children;
        return attrs.next() == null and children.next() == null and u.text == null;
    }

    /// Prints e.g. `/company/address[0]: attributes: zip="12345"; child elements: city; text: "x"`.
    pub fn format(u: Unused, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{f}:", .{u.elem.path()});
        var sep: []const u8 = " ";
        var attrs = u.attrs;
        if (attrs.next()) |first| {
            try w.print("{s}attributes: {s}=\"{s}\"", .{ sep, first.name, first.value });
            while (attrs.next()) |a| try w.print(", {s}=\"{s}\"", .{ a.name, a.value });
            sep = "; ";
        }
        var children = u.children;
        if (children.next()) |first| {
            try w.print("{s}child elements: {s}", .{ sep, first });
            while (children.next()) |name| try w.print(", {s}", .{name});
            sep = "; ";
        }
        if (u.text) |text| try w.print("{s}text: \"{s}\"", .{ sep, text });
    }
};

/// An attribute that was not used.
pub const UnusedAttr = struct {
    /// Local name.
    name: []const u8,
    value: []const u8,
};

/// Iterates over unused attributes of one element.
pub const UnusedAttrIterator = struct {
    attrs: []const Elem.Attr,
    index: usize = 0,

    pub fn next(it: *UnusedAttrIterator) ?UnusedAttr {
        while (it.index < it.attrs.len) {
            const a = it.attrs[it.index];
            it.index += 1;
            if (!a.used) return .{ .name = a.local_name, .value = a.value };
        }
        return null;
    }
};

/// Iterates over names of child groups of one element that were never requested.
pub const UnusedChildNameIterator = struct {
    groups: []const Elem.Group,
    index: usize = 0,

    pub fn next(it: *UnusedChildNameIterator) ?[]const u8 {
        while (it.index < it.groups.len) {
            const g = it.groups[it.index];
            it.index += 1;
            if (!g.used) return g.local_name;
        }
        return null;
    }
};
