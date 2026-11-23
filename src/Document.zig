//! A parsed XML document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const Elem = @import("Elem.zig");
const parser = @import("parser.zig");

const Document = @This();

ctx: *Context,

pub const Options = struct {
    /// Filled in when `parse` or any extraction function fails.
    diagnostics: ?*Diagnostics = null,
    /// Maximum element nesting depth. Deeper input fails with error.InvalidXml.
    max_depth: u32 = 256,
};

pub const ParseError = error{ InvalidXml, OutOfMemory };

/// Internal state shared by the document and its elements.
/// Heap-allocated so that its address stays stable when `Document` is moved.
pub const Context = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    input: []const u8,
    diagnostics: ?*Diagnostics,
    root: *Elem,
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
        .diagnostics = options.diagnostics,
        .root = undefined,
    };
    errdefer ctx.arena.deinit();
    if (options.diagnostics) |d| d.* = .{};

    ctx.root = try parser.parse(ctx, options.max_depth);
    return .{ .ctx = ctx };
}

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
