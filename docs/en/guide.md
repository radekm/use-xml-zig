# Guide

Czech version: [../cs/guide.md](../cs/guide.md).

use-xml is a Zig library for reading data from XML. Its distinguishing feature: after you have read
what you need, it tells you **which data in the document you did not read**. Unexpected attributes,
new elements or typos in names don't get silently ignored.

This guide shows how to use the library. The complete API description is in [api.md](api.md);
`zig build docs` generates HTML documentation from the doc comments into `zig-out/docs`.
All code from this guide is tested in [examples/guide/guide.zig](../../examples/guide/guide.zig).

## Installation

Requires Zig 0.17.1. Add the dependency to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/radekm/use-xml-zig
```

and import the module in `build.zig`:

```zig
const use_xml = b.dependency("use_xml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("use_xml", use_xml.module("use_xml"));
```

## Quick start

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const use_xml = @import("use_xml");

const Person = struct {
    name: []const u8, // owned by `arena`
    age: u8,
    email: ?[]const u8, // owned by `arena`
};

/// Reads `<people><person name="…" age="…"><email>…</email></person>…</people>`.
/// The result is allocated in `arena`.
/// On an error of the library, `diag` describes it.
fn readPeople(gpa: Allocator, arena: Allocator, input: []const u8, diag: *use_xml.Diagnostics) ![]Person {
    var doc = try use_xml.Document.parse(gpa, input, .{ .diagnostics = diag });
    defer doc.deinit();

    const persons = try doc.root().children("person");
    const result = try arena.alloc(Person, persons.len);
    for (persons, result) |p, *out| {
        out.* = .{
            .name = try p.attrAlloc(arena, []const u8, "name"),
            .age = try p.attr(u8, "age"),
            .email = if (try p.childOpt("email")) |e| try e.textAlloc(arena, []const u8) else null,
        };
    }

    try doc.expectAllUsed();
    return result;
}

/// The caller owns the diagnostics, so it can report the error after the document is freed.
fn printPeople(gpa: Allocator, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diag_buf: [4096]u8 = undefined;
    var diag: use_xml.Diagnostics = .init(&diag_buf);
    const people = readPeople(gpa, arena.allocator(), input, &diag) catch |err| {
        std.log.err("{s}: {f}", .{ @errorName(err), diag });
        return err;
    };
    for (people) |p| std.log.info("{s} ({d})", .{ p.name, p.age });
}
```

The steps are always the same:

1. `use_xml.Document.parse` reads the whole input (in memory, UTF-8) into a tree. Invalid XML fails
   with `error.InvalidXml`.
2. Starting from `doc.root()`, you ask for attributes, child elements and text. Each request
   marks the data as *used*.
3. `doc.expectAllUsed()` fails with `error.UnusedData` if something was left unused.
   If the input contained e.g. `<person name="Bob" age="42" nick="b"/>`, the error would be
   `/people/person[1]: "nick": attribute was not used (input: "b")`.

## Reading the document

| Function                     | Returns                     | Fails when                                    |
|------------------------------|-----------------------------|-----------------------------------------------|
| `e.attr(T, "a")`             | value of attribute `a`      | `Missing`: the attribute is missing           |
| `e.attrOpt(T, "a")`          | value or `null`             | —                                             |
| `e.child("c")`               | the only child `<c>`        | `Missing`: no `<c>`; `TooMany`: two or more   |
| `e.childOpt("c")`            | the child `<c>` or `null`   | `TooMany`: two or more `<c>`                  |
| `e.children("c")`            | all children `<c>` (slice)  | —                                             |
| `e.text(T)`                  | text of the element         | `HasChildren`: the element has child elements |
| `e.ignoreAll()`              | marks everything in `e` as used | —                           |

A few rules:

- **Each attribute name, child name and the text can be requested only once** per element.
  A second request fails with `error.AlreadyUsed`. This also applies to names that don't exist
  (`attrOpt("x")` twice is an error). It catches code that processes the same data twice.
- **Names are local names.** Namespace prefixes are ignored (`<h:table>` is `"table"`), and
  `xmlns` attributes are invisible. Collisions of local names are an error: `Document.parse`
  rejects two attributes with the same local name (`<a p:x="1" q:x="2"/>`) and child elements
  with the same local name and different prefixes (`<p:a/><q:a/>`).
- **Text** is the text inside the element including CDATA sections, with whitespace kept as it is.
  An empty element has the text `""`. Elements with child elements have no text; whitespace
  between child elements is ignored, other text next to child elements (mixed content) is
  rejected already by the parser.
- `children` returns the elements in document order; their order relative to elements with
  other names is not available.

## Values

`attr(T, …)` and `text(T)` convert the string to `T`:

| `T`                 | Accepted strings |
|---------------------|------------------|
| `[]const u8`        | anything |
| integers            | `42`, `+5`, `-12`, `007` (must fit into `T`) |
| `f32`, `f64`        | `1`, `-0.5`, `+007.25` (no exponent, no `inf` / `nan`) |
| `bool`              | `true`, `false` |
| enums               | the name of a tag, e.g. `red` |
| `use_xml.Timestamp`     | `2021-05-31T23:12:04Z`, `2021-05-31 23:12:04.123Z` (UTC only) |
| your own type       | anything its `parseXml` accepts (see below) |

Other conversions are done by custom parsers:

```zig
/// A user type with a `parseXml` hook: `attr(Size, …)` uses it automatically.
const Size = struct {
    width: u32,
    height: u32,

    pub fn parseXml(s: []const u8) !Size {
        const x = std.mem.indexOfScalar(u8, s, 'x') orelse return error.InvalidSize;
        return .{
            .width = try use_xml.parse.int(u32, s[0..x]),
            .height = try use_xml.parse.int(u32, s[x + 1 ..]),
        };
    }
};

/// A custom parser for `attrWith` / `textWith`.
fn parsePercent(s: []const u8) !f64 {
    if (s.len == 0 or s[s.len - 1] != '%') return error.MissingPercentSign;
    return try use_xml.parse.float(f64, s[0 .. s.len - 1]) / 100;
}

const Fit = enum { contain, cover };

// <image size="640x480" fit="cover" opacity="25%" unit="px" created="2026-11-23T10:00:00Z"/>
const size = try img.attr(Size, "size"); // hook
const fit = try img.attr(Fit, "fit"); // enum by tag name
const opacity = try img.attrWith("opacity", parsePercent); // custom parser
const unit = try img.attrWith("unit", use_xml.parse.oneOf(&.{ "px", "em" }));
const created = try img.attr(use_xml.Timestamp, "created");
```

- `attrWith` / `textWith` take any function `fn ([]const u8) E!R`, also as a pointer
  (`*const fn ([]const u8) E!R`). Its error is returned unchanged.
- Prefer `attrWith(name, parser)` to `parser(try attr([]const u8, name))`: only an error inside
  `attrWith` is recorded in `Diagnostics` together with the path, the name and the input.
- A parser that needs state (e.g. values known only at run time) is a value with a method
  `pub fn parse(self, []const u8) E!R`; pass the value (or a pointer to it) instead of a function:

  ```zig
  const UnitParser = struct {
      allowed: []const []const u8,

      pub fn parse(u: UnitParser, s: []const u8) ![]const u8 {
          for (u.allowed) |a| {
              if (std.mem.eql(u8, a, s)) return s;
          }
          return error.UnknownUnit;
      }
  };

  const unit = try img.attrWith("unit", UnitParser{ .allowed = allowed_units });
  ```
- A type with `pub fn parseXml([]const u8) !T` can be used directly as `T`. Errors of the hook are
  returned as `error.InvalidValue`; a hook that can't fail may return just `T`. To use the type
  with `...Alloc` functions, it also needs `pub fn parseXmlAlloc(Allocator, []const u8) !T`, which
  must not return slices of its input.
- The built-in parsers are available as `use_xml.parse.int`, `float`, `boolean`, `enumTag`,
  `timestamp` and `oneOf`, so custom parsers can reuse them.

## Memory

`Document.parse(gpa, input, …)` allocates everything it needs from `gpa` and frees it in
`doc.deinit()`. The input must stay alive and unchanged until then.

Values come in two flavours:

- **Borrowed** (`attr`, `text`, `attrWith`, …): strings point into the input or into the document.
  No allocation, but they are valid only until `doc.deinit()`.
- **Owned** (`attrAlloc`, `textAlloc`, `attrAllocWith`, `textAllocWith`, and the `Opt` variants):
  allocated with the allocator you pass in, so they outlive the document. Custom parsers used with
  `...AllocWith` get that allocator: `fn (Allocator, []const u8) E!R`.

The usual pattern is to parse in a function, copy what you need into your own structures with an
arena (as in the quick start), and free the document before returning.

A document is **not thread-safe**, not even for reading: every extraction function (`attr`,
`child`, `text`, …) changes it, because it records what was used. Use one document from one thread
at a time; different documents can be used in parallel, each with its own `Diagnostics`.

## Errors

Zig errors can't carry data, so the description is written into a `use_xml.Diagnostics` passed in
`Document.Options.diagnostics`, with a buffer you provide (as in the quick start). Every error of
the library is recorded there; it holds only the last one:

| Error            | `Diagnostics.kind` | Example of `"{f}"` |
|------------------|--------------------|--------------------|
| `InvalidXml`     | `invalid_xml`      | `invalid XML at line 2, column 4: end tag does not match start tag` |
| `Missing`        | `missing`          | `/person: "name": expected exactly one child element, found none` |
| `TooMany`        | `too_many`         | `/person: "name": expected at most one child element, found more than one` |
| `HasChildren`    | `has_children`     | `/person: element has child elements, so it has no text` |
| `AlreadyUsed`    | `already_used`     | `/a: "x": attribute was already used` |
| `InvalidValue`   | `invalid_value`    | `/server: "port": expected integer (u16) (input: "80x")` |
| custom parser's  | `invalid_value`    | `/a: "d": UnknownColor (input: "blue")` |
| `UnusedData`     | `unused_data`      | `/config/server[0]: "tls": attribute was not used (input: "true")` |
| `OutOfMemory`    | `value_out_of_memory` | `/a: "x": out of memory while producing the value` |
| `OutOfMemory`    | `document_out_of_memory` | `/a: "x": document out of memory` |

`value_out_of_memory` means that producing the value ran out of memory (the allocator passed to
`...Alloc`, or your parser); `document_out_of_memory` means that the document's own memory ran out.

The description is copied into your buffer, so it stays valid after `doc.deinit()`: report the
error where it is convenient, e.g. in the caller. Keep the `Diagnostics` (and its buffer) alive
until `doc.deinit()`, because the document writes into it. Descriptions that don't fit into the
buffer are cut (`truncated` is set); 4096 bytes is plenty for typical documents. Without
`Options.diagnostics` nothing is recorded.

## Unused data

After extraction, `doc.unused()` lists elements with unused content:

```zig
// <config version="2">
//   <server host="localhost" port="8080" tls="true"/>
//   <logging level="debug"/>
// </config>
const server = try doc.root().child("server");
_ = try server.attr([]const u8, "host");
_ = try server.attr(u16, "port");

var it = doc.unused();
while (it.next()) |u| std.debug.print("{f}\n", .{u});
// /config: attributes: version="2"; child elements: logging
// /config/server[0]: attributes: tls="true"
```

What is reported:

- Only elements you actually reached (the root and elements returned by `child`, `childOpt` or
  `children`) are examined. An unused child element is reported by name in its parent; its content
  is not examined.
- Text is reported only if it contains something other than whitespace (or a CDATA section).
- `xmlns` attributes and names you asked for that don't exist are never reported.

To mark data you intentionally don't need, request it and ignore the result
(`_ = try e.attrOpt([]const u8, "comment")`) — this also validates its format — or call
`e.ignoreAll()`, which marks everything in `e` as used, including the content of all
descendants. After that, any request on `e` fails with `error.AlreadyUsed`.

`doc.expectAllUsed()` is a shortcut: it fails with `error.UnusedData` and describes the first
unused item in the diagnostics.

## Supported XML

- XML 1.0, UTF-8 only (a UTF-8 BOM is allowed), the whole document in memory.
- Elements, attributes, text, CDATA, character references (`&#…;`, `&#x…;`) and the entities
  `&lt;`, `&gt;`, `&amp;`, `&apos;`, `&quot;`.
- Comments and processing instructions are skipped.
- Not supported (rejected as `InvalidXml`): `<!DOCTYPE …>` and custom entities, mixed content
  (text next to child elements), other encodings.
- Elements may be nested at most `Options.max_depth` levels deep (default 256; the root has depth
  1, so 0 rejects every document). The parser doesn't use recursion, so even a large limit can't
  overflow the stack. Printing an element path takes time quadratic in its depth, so with a very
  large limit (hundreds of thousands) `Elem.path` and the report of unused data get slow for deep
  elements. Descriptions in `Diagnostics` print only the end of a long path, so they stay fast.

## Differences from UseData.Xml

The idea is the same as in [UseData.Xml](https://github.com/radekm/UseData.Xml), the API is
adapted to Zig:

- Instead of callbacks (`child "a" (fun e -> …)`), `child("a")` returns the element.
- Unused data is checked once after extraction (`doc.unused()`, `doc.expectAllUsed()`), not when
  each element is disposed.
- Errors are Zig errors plus a `Diagnostics` with a description instead of exceptions.
- `text` on an element with child elements is an error, not `""`.
- `decimal` is not supported; numbers with a fraction are parsed as floats.

## More

- [api.md](api.md): API reference and design decisions.
- [examples/m7/m7.zig](../../examples/m7/m7.zig): a real-world example (port of UseData.Xml's
  benchmark), which also shows a function that takes `?*Diagnostics` from its caller, and how the
  caller reports the error.
- `zig build bench`: benchmark.
