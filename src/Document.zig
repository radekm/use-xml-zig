//! A parsed XML document.
//!
//! Not thread-safe, not even for reading: extraction functions change the document (they mark
//! data as used, remember requested names and write diagnostics). Use a document and its elements
//! from one thread at a time. Different documents may be used from different threads, but
//! extraction functions allocate in the document's arena (from the allocator passed to `parse`),
//! so documents that share an allocator across threads need a thread-safe one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const recording = @import("recording.zig");
const Elem = @import("Elem.zig");
const parser = @import("parser.zig");

const Document = @This();

ctx: *Context,

/// Options for `parse`.
pub const Options = struct {
    /// Description of the last error of `parse`, of the extraction functions and of
    /// `expectAllUsed`. Must stay alive and in place until `deinit`.
    /// Null = nothing is recorded (and nothing is formatted).
    diagnostics: ?*Diagnostics = null,
    /// Maximum element nesting depth. Deeper input fails with error.InvalidXml.
    /// The root element has depth 1, so 0 rejects every document.
    /// Printing paths (`Elem.path`, the report of unused data) takes time quadratic in the depth;
    /// `Diagnostics` print only the end of a long path.
    max_depth: u32 = 256,
};

/// Errors of `parse`. Details go to `Options.diagnostics`.
pub const ParseError = error{ InvalidXml, OutOfMemory };

/// Internal state shared by the document and its elements.
/// Heap-allocated so that its address stays stable when `Document` is moved.
pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: []const u8,
    /// Where errors are described (`Options.diagnostics`).
    diag: ?*Diagnostics,
    root: *Elem,
    /// All elements in document order.
    elems: []const *Elem,
};

/// Parses the whole input. `input` must stay alive and unchanged until `deinit`.
/// All internal memory comes from `gpa` (through an internal arena), also later: extraction
/// functions allocate in the arena. `gpa` must be thread-safe if documents sharing it are used
/// from different threads.
pub fn parse(gpa: Allocator, input: []const u8, options: Options) ParseError!Document {
    if (options.diagnostics) |d| recording.reset(d);
    return parseInner(gpa, input, options) catch |err| {
        if (err == error.OutOfMemory) {
            if (options.diagnostics) |d| recording.record(d, .document_out_of_memory, null, null, null, "document out of memory");
        }
        return err;
    };
}

fn parseInner(gpa: Allocator, input: []const u8, options: Options) ParseError!Document {
    const ctx = try gpa.create(Context);
    errdefer gpa.destroy(ctx);
    ctx.* = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .input = input,
        .diag = options.diagnostics,
        .root = undefined,
        .elems = &.{},
    };
    errdefer ctx.arena.deinit();

    ctx.root = try parser.parse(ctx, options.max_depth);
    return .{ .ctx = ctx };
}

/// Frees the document and all its elements. Borrowed values (strings returned without
/// an allocator) become invalid. `Options.diagnostics` keeps its description.
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

// ------------------------------------------------------------------ unused data

/// Iterates over checked elements that have unused content, in document order.
/// An element is checked if neither it nor any of its ancestors is ignored (`ignoreAll`)
/// and the name of every element on the path from the root was requested from its parent
/// (`child*` / `children`). So the root and all elements returned by the extraction functions
/// are checked; children whose name was never requested are reported only by their parent.
pub fn unused(doc: *const Document) UnusedIterator {
    return .{ .elems = doc.ctx.elems };
}

/// Returns error.UnusedData if anything was not used; `Options.diagnostics` then describes
/// the first unused item (that is the only thing it changes). Call it after extraction.
pub fn expectAllUsed(doc: *Document) error{UnusedData}!void {
    var it = doc.unused();
    const u = it.next() orelse return;
    const d = doc.ctx.diag orelse return error.UnusedData;
    var attrs = u.attrs();
    var children = u.childNames();
    if (attrs.next()) |a| {
        recording.record(d, .unused_data, u.elem, a.name, a.value, "attribute was not used");
    } else if (children.next()) |name| {
        recording.record(d, .unused_data, u.elem, name, null, "child elements were not used");
    } else {
        recording.record(d, .unused_data, u.elem, null, u.text, "text was not used");
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
            if (!isChecked(e)) continue;
            const u = Unused.of(e);
            if (u.isEmpty()) continue;
            return u;
        }
        return null;
    }
};

/// See `unused`. Walks the ancestors, so it takes time linear in the depth of `e`.
fn isChecked(e: *const Elem) bool {
    var it = e;
    while (true) {
        if (it.all_used) return false;
        const p = it.parent_elem orelse return true;
        if (!p.child_groups_used.contains(it.local_name)) return false;
        it = p;
    }
}

/// Unused content of one checked element.
pub const Unused = struct {
    elem: *const Elem,
    /// Unused text, or null. Whitespace-only text without CDATA is never reported.
    text: ?[]const u8,

    fn of(e: *const Elem) Unused {
        return .{
            .elem = e,
            .text = if (!e.text_used and e.text_significant) e.text_content else null,
        };
    }

    /// Iterates over unused attributes (`xmlns` / `xmlns:*` are never reported).
    pub fn attrs(u: Unused) UnusedAttrIterator {
        return .{ .elem = u.elem };
    }

    /// Iterates over names of child groups that were never requested. Their content is not examined.
    pub fn childNames(u: Unused) UnusedChildNameIterator {
        return .{ .elem = u.elem };
    }

    fn isEmpty(u: Unused) bool {
        var attr_it = u.attrs();
        var child_it = u.childNames();
        return attr_it.next() == null and child_it.next() == null and u.text == null;
    }

    /// Prints e.g. `/company/address[0]: attributes: zip="12345"; child elements: city; text: "x"`.
    pub fn format(u: Unused, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{f}:", .{u.elem.path()});
        var sep: []const u8 = " ";
        var attr_it = u.attrs();
        if (attr_it.next()) |first| {
            try w.print("{s}attributes: {s}=\"{s}\"", .{ sep, first.name, first.value });
            while (attr_it.next()) |a| try w.print(", {s}=\"{s}\"", .{ a.name, a.value });
            sep = "; ";
        }
        var child_it = u.childNames();
        if (child_it.next()) |first| {
            try w.print("{s}child elements: {s}", .{ sep, first });
            while (child_it.next()) |name| try w.print(", {s}", .{name});
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
    elem: *const Elem,
    index: usize = 0,

    pub fn next(it: *UnusedAttrIterator) ?UnusedAttr {
        const names = it.elem.attrs.keys();
        while (it.index < names.len) {
            const i = it.index;
            it.index += 1;
            if (!it.elem.attrs_used.contains(names[i])) {
                return .{ .name = names[i], .value = it.elem.attrs.values()[i] };
            }
        }
        return null;
    }
};

/// Iterates over names of child groups of one element that were never requested.
pub const UnusedChildNameIterator = struct {
    elem: *const Elem,
    index: usize = 0,

    pub fn next(it: *UnusedChildNameIterator) ?[]const u8 {
        const names = it.elem.child_groups.keys();
        while (it.index < names.len) {
            const name = names[it.index];
            it.index += 1;
            if (!it.elem.child_groups_used.contains(name)) return name;
        }
        return null;
    }
};
