# API design

Czech version: [../cs/api.md](../cs/api.md).

This is the API reference with design decisions. For an introduction, read the [guide](guide.md).

> Status: **approved** (2026-11-23). Changes must be approved by the owner.

## Idea

The library parses a whole XML document into a tree. The user then walks the tree and pulls out
exactly the data they need. The library records what was used. After extraction it can report
every attribute, child element and text **that nobody asked for**. This catches surprises in input
data (new fields, typos in element names, data that the code silently ignores).

This is the same idea as in [UseData.Xml](https://github.com/radekm/UseData.Xml). The differences
come from Zig:

| UseData.Xml (F#)                                  | use-xml-zig                                                  |
|---------------------------------------------------|--------------------------------------------------------------|
| `child "a" (fun e -> …)` callback                 | `child("a")` returns `*Elem` and the code continues with it  |
| `children "a" (fun e -> …)` returns `'T[]`        | `children("a")` returns `[]const *Elem` (a `for` loop)       |
| `StringParser<'T>` closure                        | type `T` known at comptime, or a function `fn([]const u8) !T` |
| `Dispose` + `ITracer` per element                 | `doc.unused()` / `doc.expectAllUsed()` after extraction      |
| exceptions with data (`WrongCount`, `ParseError`) | Zig errors + `doc.diagnostics()` / `ParseDiagnostics` with the details |
| GC                                                | borrowed values, or `...Alloc` variants with the caller's allocator |

## Example

```zig
const std = @import("std");
const use_xml = @import("use_xml");

const Person = struct {
    name: []const u8, // owned by `gpa`
    address: ?[]const u8, // owned by `gpa`
    age: u8,
    born: use_xml.Timestamp,
};

fn readPeople(gpa: std.mem.Allocator, input: []const u8) ![]Person {
    var parse_diag: use_xml.ParseDiagnostics = .{};
    var doc = use_xml.Document.parse(gpa, input, .{ .diagnostics = &parse_diag }) catch |err| {
        std.log.err("{s}: {f}", .{ @errorName(err), parse_diag });
        return err;
    };
    defer doc.deinit();
    // Runs before `doc.deinit()`, while the diagnostics are still valid.
    errdefer std.log.err("{f}", .{doc.diagnostics()});

    const root = doc.root(); // <people>
    const persons = try root.children("person");

    const result = try gpa.alloc(Person, persons.len);
    // (freeing of partial results on error omitted for brevity)
    for (persons, result) |p, *out| {
        out.* = .{
            .name = try p.attrAlloc(gpa, []const u8, "name"),
            .address = try p.attrOptAlloc(gpa, []const u8, "address"),
            .age = try p.attr(u8, "age"),
            .born = try (try p.child("born")).text(use_xml.Timestamp),
        };
    }

    // Fails with error.UnusedData if something in the input was not used;
    // `doc.diagnostics()` then describes the first unused item.
    try doc.expectAllUsed();
    return result;
}
```

## Types

### `Document`

```zig
pub const Document = struct {
    pub const Options = struct {
        /// Filled in when `parse` fails with error.InvalidXml.
        diagnostics: ?*ParseDiagnostics = null,
        /// Maximum element nesting depth. Deeper input fails with error.InvalidXml.
        /// The root element has depth 1, so 0 rejects every document.
        /// Printing paths (`Elem.path`, diagnostics) takes time quadratic in the depth.
        max_depth: u32 = 256,
    };

    /// Parses the whole input. `input` must stay alive and unchanged until `deinit`.
    /// All internal memory comes from `gpa` (through an internal arena).
    pub fn parse(gpa: Allocator, input: []const u8, options: Options) ParseError!Document;
    pub fn deinit(doc: *Document) void;

    /// The root element.
    pub fn root(doc: *Document) *Elem;

    /// Details about the last error of an extraction function or of `expectAllUsed`.
    /// Valid only until `deinit`.
    pub fn diagnostics(doc: *const Document) Diagnostics;

    /// Iterates over elements that have unused content (see "Unused data").
    pub fn unused(doc: *const Document) UnusedIterator;
    /// Returns error.UnusedData if anything was not used; `diagnostics()` describes it.
    pub fn expectAllUsed(doc: *Document) error{UnusedData}!void;
};

pub const ParseError = error{ InvalidXml, OutOfMemory };
```

### `Elem`

All functions take `e: *Elem`. Every lookup function marks what it looked at as **used**.

#### Element info

```zig
pub fn name(e: *const Elem) []const u8;      // local name (without prefix)
pub fn parent(e: *const Elem) ?*Elem;
/// Index among siblings with the same name (0-based). Used in paths: /company/address[0].
pub fn index(e: *const Elem) u32;
/// Printable path from the root, e.g. `/company/address[0]/city[0]` (use with "{f}").
/// Printing doesn't allocate and takes time quadratic in the depth of `e`.
pub fn path(e: *const Elem) Path;
```

#### Attributes

```zig
// Borrowed result (no allocation; strings point into the input or into the document).
pub fn attr(e: *Elem, comptime T: type, attr_name: []const u8) AttrError!T;
pub fn attrOpt(e: *Elem, comptime T: type, attr_name: []const u8) AttrOptError!?T;

// Custom parser without allocation (see "Custom parsers" below).
pub fn attrWith(e: *Elem, attr_name: []const u8, parser: anytype) (AttrLookupError || E)!R;
pub fn attrOptWith(e: *Elem, attr_name: []const u8, parser: anytype) (AttrOptLookupError || E)!?R;

// Result allocated with the caller's allocator (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) AttrError!T;
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) AttrOptError!?T;

// Custom parser that allocates and gets `gpa` (see "Custom parsers" below).
pub fn attrAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, parser: anytype) (AttrLookupError || E)!R;
pub fn attrOptAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, parser: anytype) (AttrOptLookupError || E)!?R;
```

- `attr*` fails with `error.Missing` if the attribute is missing.
- `attrOpt*` returns `null` if the attribute is missing.

#### Child elements

```zig
pub fn child(e: *Elem, child_name: []const u8) ChildError!*Elem;               // exactly one
pub fn childOpt(e: *Elem, child_name: []const u8) ChildOptError!?*Elem;        // zero or one
pub fn children(e: *Elem, child_name: []const u8) ChildrenError![]const *Elem; // any number, document order
```

- `child` fails with `error.Missing` if there is no child with that name and with `error.TooMany`
  if there are two or more.
- `childOpt` fails with `error.TooMany` if there are two or more.
- The returned slice and elements are owned by the document (valid until `deinit`).

#### Text

```zig
pub fn text(e: *Elem, comptime T: type) TextError!T;
pub fn textWith(e: *Elem, parser: anytype) (TextLookupError || E)!R;
pub fn textAlloc(e: *Elem, gpa: Allocator, comptime T: type) TextError!T;
pub fn textAllocWith(e: *Elem, gpa: Allocator, parser: anytype) (TextLookupError || E)!R;
```

Text is the concatenation of all text and CDATA sections directly inside the element. Comments
and processing instructions between them are dropped. Whitespace is kept as it is (no trimming).
An empty element (`<a/>`, `<a></a>`) has the text `""`.

Calling `text*` on an element that has child elements fails with `error.HasChildren`.
(UseData.Xml returns `""` there; asking for text in that place is almost certainly a bug.)

#### Ignoring

```zig
/// Marks all attributes, child names and the text of `e` as used.
/// Child elements are not visited, so their content is not reported either.
pub fn ignoreAll(e: *Elem) void;
```

#### Error set

```zig
/// All errors of the extraction functions; also available as `use_xml.Error`.
pub const Error = error{
    Missing,      // a required attribute or child element doesn't exist
    TooMany,      // more child elements with the name than expected
    HasChildren,  // text was requested from an element with child elements
    AlreadyUsed,  // the same attribute / child name / text was requested twice
    InvalidValue, // a built-in parser or a `parseXml` hook rejected the string
    OutOfMemory,  // see "Out of memory"
};

// Each function returns only the errors that can happen, so `switch` on them stays short.
pub const ChildError = error{ Missing, TooMany, AlreadyUsed, OutOfMemory };     // child
pub const ChildOptError = error{ TooMany, AlreadyUsed, OutOfMemory };           // childOpt
pub const ChildrenError = error{ AlreadyUsed, OutOfMemory };                    // children
pub const AttrLookupError = error{ Missing, AlreadyUsed, OutOfMemory };         // finding a required attribute
pub const AttrOptLookupError = error{ AlreadyUsed, OutOfMemory };               // finding an optional attribute
pub const TextLookupError = error{ HasChildren, AlreadyUsed };                  // finding the text
pub const ValueError = error{ InvalidValue, OutOfMemory };                      // built-in value parsing
pub const AttrError = AttrLookupError || ValueError;                            // attr, attrAlloc
pub const AttrOptError = AttrOptLookupError || ValueError;                      // attrOpt, attrOptAlloc
pub const TextError = TextLookupError || ValueError;                            // text, textAlloc
```

#### Custom parsers

`parser` in the `...With` functions is either a **function** or a **value with a method `parse`**.
A value can carry state known only at run time (allowed values from a configuration, a lookup
table, a counter, …). It can also be a pointer, e.g. when `parse` changes the state.

| Functions             | Function                         | Value with a method                            |
|-----------------------|----------------------------------|------------------------------------------------|
| `attrWith`, `attrOptWith`, `textWith` | `fn ([]const u8) E!R` | `pub fn parse(self, []const u8) E!R`  |
| `attrAllocWith`, `attrOptAllocWith`, `textAllocWith` | `fn (Allocator, []const u8) E!R` | `pub fn parse(self, Allocator, []const u8) E!R` |

```zig
const opacity = try img.attrWith("opacity", parsePercent); // a function

const UnitParser = struct {
    allowed: []const []const u8,
    pub fn parse(u: UnitParser, s: []const u8) error{UnknownUnit}![]const u8 { … }
};
const unit = try img.attrWith("unit", UnitParser{ .allowed = config.units }); // a value
```

Custom parsers (`...With`) may return any error (or no error at all). The error is passed through
unchanged and is recorded in `doc.diagnostics()` (the message is the error name).
Errors of `parseXml` / `parseXmlAlloc` hooks are returned as `error.InvalidValue` (except
`error.OutOfMemory`), so that `attr(T, …)` always has the error set `AttrError`. The original error
name is the message in `doc.diagnostics()`.

## Usage rules

1. Each **attribute name**, each **child name** and the **text** of an element can be requested
   **at most once**. A second request fails with `error.AlreadyUsed`. This also holds for names
   that don't exist (`attrOpt("x")` twice is an error). Such names are
   remembered in the document; this catches code that processes the same thing twice. This prevents double processing and
   matches UseData.Xml.
2. `child`, `childOpt` and `children` mark the **whole group** of children with that name as used.
   Each returned element is then *visited*: its own content is checked by the unused report.
3. Asking for a name that is not present is fine (`attrOpt`, `childOpt`, `children` return
   `null` / an empty slice). Only `attr` and `child` fail.
4. The order of requests doesn't matter.

### Threads

A document is **not thread-safe**, not even for reading: every extraction function changes it
(it marks data as used, remembers missing names in the document's arena and records
`doc.diagnostics()`). Use a document and its elements from one thread at a time. Different
documents can be used from different threads.

## Unused data

After extraction, `doc.unused()` walks all *visited* elements (the root and all elements returned
by `child*` / `children`) in document order. It yields one entry for each element that has
something unused:

```zig
pub const Unused = struct {
    elem: *const Elem,                    // where (use elem.path() for a printable path)
    text: ?[]const u8,                    // unused text, or null

    /// Unused attributes: `next() ?UnusedAttr{ .name, .value }`.
    pub fn attrs(u: Unused) UnusedAttrIterator;
    /// Names of child groups that were never requested: `next() ?[]const u8`.
    pub fn childNames(u: Unused) UnusedChildNameIterator;

    /// Prints e.g. `/company/address[0]: attributes: zip="1"; child elements: city; text: "x"`.
    pub fn format(u: Unused, w: *std.Io.Writer) std.Io.Writer.Error!void;
};

var it = doc.unused();
while (it.next()) |u| std.log.warn("unused: {f}", .{u});
```

- Unused child elements are reported **only by name in their parent**. Their content is not
  examined, because nobody looked at them.
- Text that contains only whitespace and no CDATA is never reported. The same is true for
  whitespace between child elements. Only literal whitespace counts: a character reference such
  as `&#32;` is text (and between child elements it is rejected as mixed content).
- `xmlns` / `xmlns:*` attributes are never reported.
- `doc.expectAllUsed()` is a shortcut that fails with `error.UnusedData` on the first entry and
  describes it in `doc.diagnostics()`.
- Neither function allocates nor changes what is marked as used, so they can be called
  repeatedly; the result always reflects the current state. `unused()` changes nothing at all;
  `expectAllUsed()` only records its description in `doc.diagnostics()`.

Example (from the UseData.Xml tests):

```xml
<company>
    <address>
        <street>Baker Street</street>
        <city>London</city>
    </address>
</company>
```

```zig
const street = try (try (try doc.root().child("address")).child("street")).text([]const u8);
// doc.unused() yields one entry: elem = /company/address[0], children = { "city" }
```

## Values (`T` in `attr` / `text`)

Built-in types:

| `T`                     | Accepted input |
|-------------------------|----------------|
| `[]const u8`            | any string (borrowed; `...Alloc` copies) |
| signed / unsigned ints  | optional sign `+` / `-`, then one or more decimal digits; leading zeros are allowed (`007`, `+5`, `-12`); no `_`, no whitespace; must fit into `T` |
| `f32`, `f64`            | optional sign, digits, optionally `.` followed by digits (`1`, `-0.5`, `+007.25`); no exponent, no `inf` / `nan`, no hexadecimal form, no `.5` or `5.` |
| `bool`                  | exactly `true` or `false` (case-sensitive) |
| `enum`                  | exactly the name of one of the tags (`@tagName`); enums with more than about 1000 tags don't compile (the error message lists all tags), use `attrWith` with `use_xml.parse.enumTag` |
| `use_xml.Timestamp`         | see below |
| `?T`                    | not allowed. Use the `Opt` variants instead. |

User types can define a hook that `attr` / `text` find automatically:

```zig
pub fn parseXml(s: []const u8) !@This();                         // used by attr / text
pub fn parseXmlAlloc(gpa: Allocator, s: []const u8) !@This();    // used by ...Alloc
```

A hook takes precedence over the built-in parsing (so an enum with `parseXml` is not parsed by tag
name).

`...Alloc` functions use only `parseXmlAlloc`. A type with a hook but without `parseXmlAlloc` can't
be used with them (compile error), because `parseXml` may return slices of its input, which would
not outlive the document. A type with only `parseXmlAlloc` can be used only with `...Alloc`.

The module `use_xml.parse` contains the built-in parsers as plain functions returning
`error{InvalidValue}!T`, so they can be combined in custom parsers:
`use_xml.parse.int(u32, s)`, `use_xml.parse.float(f64, s)`, `use_xml.parse.boolean(s)`,
`use_xml.parse.enumTag(E, s)`, `use_xml.parse.timestamp(s)` and `use_xml.parse.oneOf(&.{ "a", "b" })`
(returns a parser for `attrWith` / `textWith`).

### `Timestamp`

```zig
/// A point in time in UTC with nanosecond precision.
pub const Timestamp = struct {
    seconds: i64, // since 1970-01-01T00:00:00Z
    nanos: u32,   // 0 ..< 1_000_000_000
};
```

`Timestamp` also has `parse(s)` and `format` (prints the same format, so `"{f}"` round-trips).

Accepted format (like UseData.Xml's `dateTimeOffset`):
`YYYY-MM-DDTHH:MM:SS[.f…]Z`, where `T` may also be a single space and the fraction has 1–9
digits. The date and time are validated (month lengths, leap years). Years are 0000–9999.

## `ParseDiagnostics` and `Diagnostics`

```zig
/// Errors of `Document.parse`. Doesn't point anywhere, so it is valid forever.
pub const ParseDiagnostics = struct {
    message: []const u8 = "", // static string; empty = no error
    line: u32 = 0, // 1-based
    column: u32 = 0, // 1-based, in code points

    /// Prints e.g. `invalid XML at line 2, column 4: end tag does not match start tag`.
    pub fn format(d: ParseDiagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void;
};

/// Errors of extraction functions and of `expectAllUsed`, recorded by the document.
pub const Diagnostics = struct {
    kind: Kind = .none,
    /// Element where the error happened.
    elem: ?*const Elem = null,
    /// Attribute name, child name, or null (text).
    selector: ?[]const u8 = null,
    /// The string that failed to parse, the unused value, or null.
    input: ?[]const u8 = null,
    /// Human-readable message (static string or error name).
    message: []const u8 = "",

    pub const Kind = enum {
        none,
        missing,
        too_many,
        has_children,
        already_used,
        invalid_value,
        unused_data,
        /// The document's internal memory (the allocator passed to `Document.parse`) ran out.
        document_out_of_memory,
        /// Producing the value ran out of memory: the allocator passed to an `...Alloc` function,
        /// or a custom parser / `parseXmlAlloc` hook returned `error.OutOfMemory`.
        value_out_of_memory,
    };

    /// Prints e.g. `/company/address[0]: "city": attribute is missing`.
    pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void;
};
```

Errors are described in two places:

- **XML syntax errors** go to a `ParseDiagnostics` passed in `Options.diagnostics` (when
  `parse` fails, there is no document to store them in). It contains no pointers, so it stays
  valid forever.
- **Errors of extraction functions and of `expectAllUsed`** are recorded by the document itself;
  `doc.diagnostics()` returns the last one. Its slices point into the input or into the document,
  so it is valid only until `doc.deinit()`. Being part of the document makes this lifetime
  obvious. Every error these functions return is recorded, `error.OutOfMemory` too, so after an
  error of the library `doc.diagnostics()` always describes it. Two kinds tell where the memory
  ran out: `document_out_of_memory` (the document's internal memory, used only to remember
  requested names that don't exist) and `value_out_of_memory` (producing the value: the allocator
  of an `...Alloc` function, or a custom parser or `parseXmlAlloc` hook that returned
  `error.OutOfMemory`).

  It holds only the **last** error: every error overwrites it, and nothing else changes it. Calls
  that succeed leave the previous error in place, so read `doc.diagnostics()` right after an error
  (in `catch` or `errdefer`). `kind != .none` only says that *some* earlier call failed. Errors
  that don't come from the library (e.g. from your own allocations between the calls) are not
  recorded, of course: an `errdefer` that logs `doc.diagnostics()` then logs an older error.

**Report extraction errors before calling `doc.deinit()`.** The code that parses the document is
responsible for that. Typical pattern:

```zig
var parse_diag: use_xml.ParseDiagnostics = .{};
var doc = use_xml.Document.parse(gpa, input, .{ .diagnostics = &parse_diag }) catch |err| {
    std.log.err("{s}: {f}", .{ @errorName(err), parse_diag });
    return err;
};
defer doc.deinit();
// `errdefer` declared after `defer doc.deinit()` runs before it.
errdefer std.log.err("{f}", .{doc.diagnostics()});
```

The example `examples/m7/m7.zig` shows the same with a writer passed in by the caller.

## Out of memory

- `Document.parse`: on `error.OutOfMemory` everything allocated so far is freed and no document is
  returned. `ParseDiagnostics` is not filled in (the error itself says enough).
- Lookups by name (`attr*`, `child*`, `children`) can return `error.OutOfMemory` **only when the
  name doesn't exist in the element**: the name is then copied into the document's internal arena
  so that a second request can be detected. Existing names need no allocation.
- `text*` without an allocator, `ignoreAll`, `unused`, `expectAllUsed` and `Diagnostics.format`
  never allocate.
- `...Alloc` functions return `error.OutOfMemory` when the caller's allocator fails. Nothing is
  leaked: memory allocated for the failed value is freed before returning. Values returned by
  earlier calls belong to the caller, who frees them as usual (`errdefer`).
- Every `error.OutOfMemory` of an extraction function is recorded in `doc.diagnostics()` (kind
  `document_out_of_memory` or `value_out_of_memory`, see above); recording it doesn't allocate.
- The value is marked as used before parsing. So even when parsing fails (invalid value, out of
  memory) a second request for the same name fails with `error.AlreadyUsed`.

## Resolved questions (2026-11-23)

1. Integers: `+` and leading zeros are allowed.
2. Floats: only the plain decimal form without exponent.
3. `bool`: only `true` / `false`, case-sensitive.
4. `Timestamp`: only the `Z` suffix, no offsets.
5. `text*` on an element with child elements fails with `error.HasChildren` (originally
   `error.WrongCount`, split into `Missing` / `TooMany` / `HasChildren` on 2026-11-24).
6. Separate functions for the variants (no options struct).
7. Names that were requested but don't exist are remembered, and a second request fails with
   `error.AlreadyUsed`. That is why lookups by name may return `error.OutOfMemory`.

## Open questions

None at the moment.
