//! Comptime dispatch from a type `T` to the parser used by `attr(T, …)` / `text(T)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin_parsers = @import("parse.zig");
const Timestamp = @import("Timestamp.zig");

/// Errors of parsing a value of type `T` (`owned`: for an `...Alloc` function); only the errors
/// that can happen:
/// - `[]const u8`: none, or `OutOfMemory` when it is copied (`owned`),
/// - numbers, `bool`, enums and `Timestamp`: `InvalidValue`,
/// - hooks: `InvalidValue` if the hook can fail with an error other than `OutOfMemory`,
///   and `OutOfMemory` if the hook can fail with it.
pub fn ValueError(comptime T: type, comptime owned: bool) type {
    if (T == []const u8) return if (owned) error{OutOfMemory} else error{};
    if (T == Timestamp) return error{InvalidValue};
    switch (@typeInfo(T)) {
        .int, .float, .bool => return error{InvalidValue},
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "parseXml") or @hasDecl(T, "parseXmlAlloc")) {
            return HookError(T, owned);
        } else if (@typeInfo(T) == .@"enum") {
            return error{InvalidValue};
        },
        else => {},
    }
    return error{}; // An unsupported type: `parse` reports it.
}

fn HookError(comptime T: type, comptime owned: bool) type {
    const hook_name = if (owned) "parseXmlAlloc" else "parseXml";
    if (!@hasDecl(T, hook_name)) return error{}; // `parseWithHook` reports it.
    const R = @typeInfo(@TypeOf(@field(T, hook_name))).@"fn".return_type orelse
        @compileError(@typeName(T) ++ "." ++ hook_name ++ " must not be generic");
    if (@typeInfo(R) != .error_union) return error{};
    const names = @typeInfo(@typeInfo(R).error_union.error_set).error_set.error_names orelse
        return error{ InvalidValue, OutOfMemory }; // anyerror
    var oom = false;
    var other = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "OutOfMemory")) oom = true else other = true;
    }
    return switch (@as(u2, @intFromBool(oom)) << 1 | @intFromBool(other)) {
        0b00 => error{},
        0b01 => error{InvalidValue},
        0b10 => error{OutOfMemory},
        0b11 => error{ InvalidValue, OutOfMemory },
    };
}

/// Parses `s` into `T`. `gpa` is either `null` (the result may borrow `s`) or an `Allocator`
/// (the result must not borrow `s`: strings are copied and user hooks must be `parseXmlAlloc`).
/// On `error.InvalidValue`, `message` is set to a static description.
pub fn parse(comptime T: type, gpa: anytype, s: []const u8, message: *[]const u8) ValueError(T, isOwned(@TypeOf(gpa)))!T {
    const owned = comptime isOwned(@TypeOf(gpa));
    if (T == []const u8) {
        if (!owned) return s;
        return gpa.dupe(u8, s);
    }

    if (T == Timestamp) {
        return builtin(Timestamp.parse(s), "expected timestamp YYYY-MM-DDTHH:MM:SS[.fraction]Z", message);
    }

    switch (@typeInfo(T)) {
        .optional => @compileError("optional types are not supported; use the `Opt` variants"),
        .int => return builtin(builtin_parsers.int(T, s), "expected integer (" ++ @typeName(T) ++ ")", message),
        .float => return builtin(builtin_parsers.float(T, s), "expected decimal number", message),
        .bool => return builtin(builtin_parsers.boolean(s), "expected 'true' or 'false'", message),
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "parseXml") or @hasDecl(T, "parseXmlAlloc")) {
            return parseWithHook(T, gpa, s, message);
        } else if (@typeInfo(T) == .@"enum") {
            return builtin(builtin_parsers.enumTag(T, s), comptime enumMessage(T), message);
        },
        else => {},
    }
    @compileError("unsupported type " ++ @typeName(T) ++
        "; add `pub fn parseXml([]const u8) !" ++ @typeName(T) ++ "` or use a custom parser");
}

fn builtin(result: anytype, comptime description: []const u8, message: *[]const u8) error{InvalidValue}!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch {
        message.* = description;
        return error.InvalidValue;
    };
}

fn enumMessage(comptime E: type) []const u8 {
    var message: []const u8 = "expected one of:";
    for (std.meta.fieldNames(E), 0..) |name, i| {
        message = message ++ (if (i == 0) " " else ", ") ++ name;
    }
    return message;
}

pub fn isOwned(comptime G: type) bool {
    if (G == Allocator) return true;
    if (G == @TypeOf(null)) return false;
    @compileError("expected an Allocator or null, got " ++ @typeName(G));
}

fn parseWithHook(comptime T: type, gpa: anytype, s: []const u8, message: *[]const u8) ValueError(T, isOwned(@TypeOf(gpa)))!T {
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
    // A hook may also return `T` without an error.
    if (@typeInfo(@TypeOf(result)) != .error_union) return result;
    const E = ValueError(T, isOwned(@TypeOf(gpa)));
    return result catch |err| {
        // `E` contains exactly the branches below that can happen.
        if (comptime errorIn(E, "OutOfMemory")) {
            if (@as(anyerror, err) == error.OutOfMemory) return error.OutOfMemory;
        }
        if (comptime errorIn(E, "InvalidValue")) {
            message.* = @errorName(err);
            return error.InvalidValue;
        }
        unreachable;
    };
}

fn errorIn(comptime E: type, comptime name: []const u8) bool {
    for (@typeInfo(E).error_set.error_names.?) |err_name| {
        if (std.mem.eql(u8, err_name, name)) return true;
    }
    return false;
}

/// The function called for a custom parser of type `Parser`: the parser itself if it is a
/// function (or a pointer to a function), otherwise its method `parse` (the parser may also be
/// a pointer to such a value).
pub fn ParseFn(comptime Parser: type) type {
    switch (@typeInfo(Parser)) {
        .@"fn" => return Parser,
        .pointer => |ptr| if (ptr.size == .one) {
            if (@typeInfo(ptr.child) == .@"fn") return ptr.child;
            switch (@typeInfo(ptr.child)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => return ParseFn(ptr.child),
                else => {},
            }
        },
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(Parser, "parse")) {
            const F = @TypeOf(Parser.parse);
            if (@typeInfo(F) != .@"fn") @compileError(@typeName(Parser) ++ ".parse must be a function");
            return F;
        },
        else => {},
    }
    @compileError("parser must be a function or a value with a method `parse`, got " ++ @typeName(Parser));
}

/// Calls a custom parser (a function, a pointer to a function, or a value with a method `parse`)
/// with `args`.
pub fn callParser(parser: anytype, args: anytype) @typeInfo(ParseFn(@TypeOf(parser))).@"fn".return_type.? {
    if (comptime isFunction(@TypeOf(parser))) return @call(.auto, parser, args);
    // Method call syntax takes care of `self` being a value or a pointer.
    return switch (args.len) {
        1 => parser.parse(args[0]),
        2 => parser.parse(args[0], args[1]),
        else => @compileError("unexpected number of parser arguments"),
    };
}

fn isFunction(comptime P: type) bool {
    return switch (@typeInfo(P)) {
        .@"fn" => true,
        .pointer => |ptr| ptr.size == .one and @typeInfo(ptr.child) == .@"fn",
        else => false,
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
