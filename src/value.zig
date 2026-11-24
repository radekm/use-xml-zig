//! Comptime dispatch from a type `T` to the parser used by `attr(T, …)` / `text(T)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin_parsers = @import("parse.zig");
const Timestamp = @import("Timestamp.zig");

/// Reasons a value can't be produced, before the error is reported in `Diagnostics`.
pub const Failure = union(enum) {
    /// The string is not a valid `T`. The message is static.
    invalid: []const u8,
    out_of_memory,
};

/// Parses `s` into `T`. `gpa` is either `null` (the result may borrow `s`) or an `Allocator`
/// (the result must not borrow `s`: strings are copied and user hooks must be `parseXmlAlloc`).
pub fn parse(comptime T: type, gpa: anytype, s: []const u8, failure: *Failure) error{Failed}!T {
    const owned = comptime isOwned(@TypeOf(gpa));
    if (T == []const u8) {
        if (!owned) return s;
        return gpa.dupe(u8, s) catch {
            failure.* = .out_of_memory;
            return error.Failed;
        };
    }

    if (T == Timestamp) {
        return builtin(Timestamp.parse(s), "expected timestamp YYYY-MM-DDTHH:MM:SS[.fraction]Z", failure);
    }

    switch (@typeInfo(T)) {
        .optional => @compileError("optional types are not supported; use the `Opt` variants"),
        .int => return builtin(builtin_parsers.int(T, s), "expected integer (" ++ @typeName(T) ++ ")", failure),
        .float => return builtin(builtin_parsers.float(T, s), "expected decimal number", failure),
        .bool => return builtin(builtin_parsers.boolean(s), "expected 'true' or 'false'", failure),
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "parseXml") or @hasDecl(T, "parseXmlAlloc")) {
            return parseWithHook(T, gpa, s, failure);
        } else if (@typeInfo(T) == .@"enum") {
            return builtin(builtin_parsers.enumTag(T, s), comptime enumMessage(T), failure);
        },
        else => {},
    }
    @compileError("unsupported type " ++ @typeName(T) ++
        "; add `pub fn parseXml([]const u8) !" ++ @typeName(T) ++ "` or use a custom parser");
}

fn builtin(result: anytype, comptime message: []const u8, failure: *Failure) error{Failed}!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch {
        failure.* = .{ .invalid = message };
        return error.Failed;
    };
}

fn enumMessage(comptime E: type) []const u8 {
    var message: []const u8 = "expected one of:";
    for (std.meta.fieldNames(E), 0..) |name, i| {
        message = message ++ (if (i == 0) " " else ", ") ++ name;
    }
    return message;
}

fn isOwned(comptime G: type) bool {
    if (G == Allocator) return true;
    if (G == @TypeOf(null)) return false;
    @compileError("expected an Allocator or null, got " ++ @typeName(G));
}

fn parseWithHook(comptime T: type, gpa: anytype, s: []const u8, failure: *Failure) error{Failed}!T {
    // `...Alloc` functions promise a result that outlives the document. `parseXml` may return
    // slices of its input, so it is never used for them.
    const result = if (comptime isOwned(@TypeOf(gpa)))
        if (@hasDecl(T, "parseXmlAlloc"))
            T.parseXmlAlloc(gpa, s)
        else
            @compileError(@typeName(T) ++ " has no `parseXmlAlloc`, so it can't be used with `...Alloc` " ++
                "functions; add `pub fn parseXmlAlloc(Allocator, []const u8) !" ++ @typeName(T) ++
                "` or use the variant without `Alloc`")
    else if (@hasDecl(T, "parseXml"))
        T.parseXml(s)
    else
        @compileError(@typeName(T) ++ " has only `parseXmlAlloc`; use an `...Alloc` function");
    return result catch |err| {
        failure.* = if (@as(anyerror, err) == error.OutOfMemory) .out_of_memory else .{ .invalid = @errorName(err) };
        return error.Failed;
    };
}

/// The function called for a custom parser of type `Parser`: the parser itself if it is a
/// function, otherwise its method `parse` (the parser may also be a pointer to such a value).
pub fn ParseFn(comptime Parser: type) type {
    switch (@typeInfo(Parser)) {
        .@"fn" => return Parser,
        .pointer => |ptr| if (ptr.size == .one) return ParseFn(ptr.child),
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(Parser, "parse")) {
            const F = @TypeOf(Parser.parse);
            if (@typeInfo(F) != .@"fn") @compileError(@typeName(Parser) ++ ".parse must be a function");
            return F;
        },
        else => {},
    }
    @compileError("parser must be a function or a value with a method `parse`, got " ++ @typeName(Parser));
}

/// Calls a custom parser (a function, or a value with a method `parse`) with `args`.
pub fn callParser(parser: anytype, args: anytype) @typeInfo(ParseFn(@TypeOf(parser))).@"fn".return_type.? {
    if (@typeInfo(@TypeOf(parser)) == .@"fn") return @call(.auto, parser, args);
    // Method call syntax takes care of `self` being a value or a pointer.
    return switch (args.len) {
        1 => parser.parse(args[0]),
        2 => parser.parse(args[0], args[1]),
        else => @compileError("unexpected number of parser arguments"),
    };
}

/// Return type of a custom parser, split into the error set and the payload.
pub fn ParserResult(comptime Parser: type) struct { type, type } {
    const info = @typeInfo(ParseFn(Parser));
    const R = info.@"fn".return_type orelse @compileError("parser must not have a generic return type");
    return switch (@typeInfo(R)) {
        .error_union => |eu| .{ eu.error_set, eu.payload },
        else => .{ error{}, R },
    };
}
