//! Comptime dispatch from a type `T` to the parser used by `attr(T, …)` / `text(T)`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Reasons a value can't be produced, before the error is reported in `Diagnostics`.
pub const Failure = union(enum) {
    /// The string is not a valid `T`. The message is static.
    invalid: []const u8,
    out_of_memory,
};

/// Parses `s` into `T`. When `gpa` is null, strings are borrowed; otherwise they are
/// copied into `gpa` and user hooks get `gpa` (`parseXmlAlloc`).
pub fn parse(comptime T: type, gpa: ?Allocator, s: []const u8, failure: *Failure) error{Failed}!T {
    if (T == []const u8) {
        const allocator = gpa orelse return s;
        return allocator.dupe(u8, s) catch {
            failure.* = .out_of_memory;
            return error.Failed;
        };
    }

    switch (@typeInfo(T)) {
        .optional => @compileError("optional types are not supported; use the `Opt` variants"),
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "parseXml") or @hasDecl(T, "parseXmlAlloc")) {
            return parseWithHook(T, gpa, s, failure);
        },
        else => {},
    }
    @compileError("unsupported type " ++ @typeName(T) ++
        "; add `pub fn parseXml([]const u8) !" ++ @typeName(T) ++ "` or use a custom parser");
}

fn parseWithHook(comptime T: type, gpa: ?Allocator, s: []const u8, failure: *Failure) error{Failed}!T {
    const result = if (gpa != null and @hasDecl(T, "parseXmlAlloc"))
        T.parseXmlAlloc(gpa.?, s)
    else if (@hasDecl(T, "parseXml"))
        T.parseXml(s)
    else
        @compileError(@typeName(T) ++ " has only `parseXmlAlloc`; use an `...Alloc` function");
    return result catch |err| {
        failure.* = if (@as(anyerror, err) == error.OutOfMemory) .out_of_memory else .{ .invalid = @errorName(err) };
        return error.Failed;
    };
}

/// Return type of a custom parser, split into the error set and the payload.
pub fn ParserResult(comptime parser: anytype) struct { type, type } {
    const info = @typeInfo(@TypeOf(parser));
    if (info != .@"fn") @compileError("parser must be a function");
    const R = info.@"fn".return_type orelse @compileError("parser must not have a generic return type");
    return switch (@typeInfo(R)) {
        .error_union => |eu| .{ eu.error_set, eu.payload },
        else => .{ error{}, R },
    };
}
