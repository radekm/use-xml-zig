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
| exceptions with data (`WrongCount`, `ParseError`) | Zig errors + `Diagnostics` (caller's buffer) with the details |
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

/// On an error of the library, `diag` describes it (valid also after this function returns).
fn readPeople(gpa: std.mem.Allocator, input: []const u8, diag: *use_xml.Diagnostics) ![]Person {
    var doc = try use_xml.Document.parse(gpa, input, .{ .diagnostics = diag });
    defer doc.deinit();

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
    // `diag` then describes the first unused item.
    try doc.expectAllUsed();
    return result;
}

// The caller:
var diag_buf: [4096]u8 = undefined;
var diag: use_xml.Diagnostics = .init(&diag_buf);
const people = readPeople(gpa, input, &diag) catch |err| {
    std.log.err("{s}: {f}", .{ @errorName(err), diag });
    return err;
};
```

## Types

### `Document`

```zig
pub const Document = struct {
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

    /// Parses the whole input. `input` must stay alive and unchanged until `deinit`.
    /// All internal memory comes from `gpa` (through an internal arena).
    pub fn parse(gpa: Allocator, input: []const u8, options: Options) ParseError!Document;
    pub fn deinit(doc: *Document) void;

    /// The root element.
    pub fn root(doc: *Document) *Elem;

    /// Iterates over elements that have unused content (see "Unused data").
    pub fn unused(doc: *const Document) UnusedIterator;
    /// Returns error.UnusedData if anything was not used; `Options.diagnostics` describes it.
    pub fn expectAllUsed(doc: *Document) error{UnusedData}!void;
};

/// Details go to `Options.diagnostics`.
pub const ParseError = error{ InvalidXml, OutOfMemory };
```

### `Elem`

All functions take `e: *Elem`. Every lookup function marks what it looked at as **used**.

#### Element info

```zig
pub fn name(e: *const Elem) []const u8;      // local name (without prefix)
pub fn parent(e: *const Elem) ?*Elem;
/// Index among siblings with the same name (0-based). Used in paths: /company/address[0].
/// Takes time linear in the number of those siblings (it is searched for among them).
pub fn index(e: *const Elem) u32;
/// Printable path from the root, e.g. `/company/address[0]/city[0]` (use with "{f}").
/// Printing doesn't allocate and takes time quadratic in the depth of `e`, plus the time of `index`
/// for every element on the path.
pub fn path(e: *const Elem) Path;
```

#### Attributes

```zig
// Borrowed result (no allocation; strings point into the input or into the document).
pub fn attr(e: *Elem, comptime T: type, attr_name: []const u8) (AttrLookupError || V)!T;
pub fn attrOpt(e: *Elem, comptime T: type, attr_name: []const u8) (AttrOptLookupError || V)!?T;

// Custom parser without allocation (see "Custom parsers" below).
pub fn attrWith(e: *Elem, attr_name: []const u8, parser: anytype) (AttrLookupError || E)!R;
pub fn attrOptWith(e: *Elem, attr_name: []const u8, parser: anytype) (AttrOptLookupError || E)!?R;

// Result allocated with the caller's allocator (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) (AttrLookupError || V)!T;
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) (AttrOptLookupError || V)!?T;

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
pub fn text(e: *Elem, comptime T: type) (TextLookupError || V)!T;
pub fn textWith(e: *Elem, parser: anytype) (TextLookupError || E)!R;
pub fn textAlloc(e: *Elem, gpa: Allocator, comptime T: type) (TextLookupError || V)!T;
pub fn textAllocWith(e: *Elem, gpa: Allocator, parser: anytype) (TextLookupError || E)!R;
```

Text is the concatenation of all text and CDATA sections directly inside the element. Comments
and processing instructions between them are dropped. Whitespace is kept as it is (no trimming).
An empty element (`<a/>`, `<a></a>`) has the text `""`.

Calling `text*` on an element that has child elements fails with `error.HasChildren`.
(UseData.Xml returns `""` there; asking for text in that place is almost certainly a bug.)

#### Ignoring

```zig
/// Marks everything in `e` as used: attributes, child elements and the text, including
/// the content of all descendants. Afterwards every request on `e` (even for a name that
/// doesn't exist) fails with `error.AlreadyUsed`.
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
```

`attr*`, `attrOpt*` and `text*` without `With` return the errors of the lookup plus `V`, the errors
of parsing a value of type `T`. `V` contains only the errors that can happen for `T`:

| `T`                                      | `V` (`attr`, `text`, …)   | `V` (`attrAlloc`, `textAlloc`, …) |
|------------------------------------------|---------------------------|-----------------------------------|
| `[]const u8`                             | none                      | `OutOfMemory`                     |
| integers, floats, `bool`, enums, `Timestamp` | `InvalidValue`        | `InvalidValue`                    |
| type with a hook                         | by the errors of `parseXml` | by the errors of `parseXmlAlloc` |

A hook adds `InvalidValue` if it can fail with an error other than `OutOfMemory`, and `OutOfMemory`
if it can fail with it. So `text([]const u8)` fails only with `HasChildren` or `AlreadyUsed`, and
`text(u32)` never fails with `OutOfMemory`. `attr*` can always fail with `OutOfMemory`, because
the document remembers requested names.

#### Custom parsers

Strings are decoded already by `Document.parse`, so `attr([]const u8, …)` / `text([]const u8)`
return the final value and it could be parsed afterwards by any function. The `...With` variants
(and the built-in types and hooks) exist **for error reporting**: when the parser fails inside
them, the library records the path, the attribute name and the input in `Options.diagnostics`
(`/a/b[0]: "x": UnknownUnit (input: "pt")`). An error of a function called afterwards is not
recorded (the library doesn't see it), so the caller would have to build such a description itself.

`parser` in the `...With` functions is either a **function** (also a pointer to a function, e.g.
one chosen at run time) or a **value with a method `parse`**. A value can carry state known only
at run time (allowed values from a configuration, a lookup table, a counter, …). It can also be a
pointer, e.g. when `parse` changes the state.

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
unchanged and is recorded in `Options.diagnostics` (the message is the error name).
Errors of `parseXml` / `parseXmlAlloc` hooks are returned as `error.InvalidValue` (except
`error.OutOfMemory`), so that `attr(T, …)` returns only the errors of the library. The original
error name is the message in `Options.diagnostics`. A hook must not be generic (its error set has
to be known).

## Usage rules

1. Each **attribute name**, each **child name** and the **text** of an element can be requested
   **at most once**. A second request fails with `error.AlreadyUsed`. This also holds for names
   that don't exist (`attrOpt("x")` twice is an error): such names are remembered in the document.
   This catches code that processes the same thing twice and matches UseData.Xml.
2. `child`, `childOpt` and `children` mark the **whole group** of children with that name as used.
   The content of the elements in the group is then checked by the unused report (even when
   `child` / `childOpt` failed with `error.TooMany`).
3. Asking for a name that is not present is fine (`attrOpt`, `childOpt`, `children` return
   `null` / an empty slice). Only `attr` and `child` fail.
4. The order of requests doesn't matter.
5. Names are **local names**: namespace prefixes are ignored and `xmlns` attributes are invisible.
   So that every name is unambiguous, **collisions of local names are an error**: `Document.parse`
   fails with `error.InvalidXml` if an element has two attributes with the same local name
   (`<a p:x="1" q:x="2"/>`, "multiple attributes with the same local name") or child elements
   with the same local name and different prefixes (`<r><p:a/><q:a/></r>`, "child elements with
   the same local name have different prefixes"). Children with the same name and the same prefix
   are fine; they form one group for `children`.

### Threads

A document is **not thread-safe**, not even for reading: every extraction function changes it
(it marks data as used, remembers requested names in the document's arena and records
`Options.diagnostics`). Use a document and its elements from one thread at a time. Different
documents can be used from different threads, each with its own `Diagnostics`.

## Unused data

After extraction, `doc.unused()` walks all *checked* elements in document order. An element is
checked if neither it nor any of its ancestors was ignored (`ignoreAll`) and the name of every
element on the path from the root was requested from its parent (`child*` / `children`). Children
whose name was never requested are reported only as a name by their parent; their content is not
examined. Checking an element walks its ancestors, so the walk takes time proportional to
the number of elements times the depth (limited by `Options.max_depth`). It yields one entry for each element that has
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
  describes it in `Options.diagnostics`.
- Neither function allocates nor changes what is marked as used, so they can be called
  repeatedly; the result always reflects the current state. `unused()` changes nothing at all;
  `expectAllUsed()` only records its description in `Options.diagnostics`.

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

A hook that can't fail may also return `@This()` without an error. A hook takes precedence over
the built-in parsing (so an enum with `parseXml` is not parsed by tag name).

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

## `Diagnostics`

```zig
/// Description of the last error. The text is copied into a buffer from the caller,
/// so it stays valid after `doc.deinit()` (as long as the buffer lives).
pub const Diagnostics = struct {
    kind: Kind = .none,
    /// 1-based position in the input; only for `invalid_xml`, otherwise 0.
    line: u32 = 0,
    column: u32 = 0, // in code points
    /// True if the description didn't fit into the buffer.
    truncated: bool = false,
    // internal: buf: []u8, len: usize

    pub const Kind = enum {
        none,
        invalid_xml,            // Document.parse: error.InvalidXml
        missing,
        too_many,
        has_children,
        already_used,
        invalid_value,          // also errors of custom parsers
        unused_data,            // expectAllUsed: the first unused item
        /// The document's internal memory (the allocator passed to `Document.parse`) ran out,
        /// also in `Document.parse` itself.
        document_out_of_memory,
        /// Producing the value ran out of memory: the allocator passed to an `...Alloc` function,
        /// or a custom parser / `parseXmlAlloc` hook returned `error.OutOfMemory`.
        value_out_of_memory,
    };

    pub fn init(buf: []u8) Diagnostics;
    /// The description, e.g. `/company/address[0]: "city": attribute is missing` or
    /// `invalid XML at line 2, column 4: end tag does not match start tag`.
    pub fn message(d: *const Diagnostics) []const u8;
    /// Prints `message()`, plus `…` if it was truncated (or `no error`). If nothing of the
    /// description fits, prints the kind (e.g. `missing`, `invalid XML at line 2, column 4`).
    pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void;
};
```

Zig errors can't carry data, so the description of an error is written as text into a
`Diagnostics` passed in `Options.diagnostics`, with a buffer from the caller:

```zig
var diag_buf: [4096]u8 = undefined;
var diag: use_xml.Diagnostics = .init(&diag_buf);
var doc = try use_xml.Document.parse(gpa, input, .{ .diagnostics = &diag });
```

- **Every error returned by the library is recorded**: XML syntax errors of `parse` (with `line`
  and `column`), errors of the extraction functions and of `expectAllUsed`, and
  `error.OutOfMemory`. Two kinds tell where the memory ran out: `document_out_of_memory` (the
  document's internal memory: in `parse`, and when remembering requested names)
  and `value_out_of_memory` (producing the value: the allocator of an `...Alloc` function, or a
  custom parser or `parseXmlAlloc` hook that returned `error.OutOfMemory`).
- It holds only the **last** error: every error overwrites it, and nothing else changes it.
  `parse` resets it at the start; calls that succeed leave the previous error in place, so read it
  right after an error. `kind != .none` only says that *some* earlier call failed. Errors that
  don't come from the library (e.g. from your own allocations between the calls) are not
  recorded, of course.
- The text **doesn't point into the input or into the document**, so it can be reported after
  `doc.deinit()`, typically by the caller of the function that parses (see the example at the
  top). The `Diagnostics` value and its buffer must stay alive and in place until `doc.deinit()`,
  because the document writes into them.
- Names and values longer than 1024 bytes are shortened (`…`) so that the rest of the description
  fits. A path longer than about 1024 bytes is shortened from the start (`/…/b[0]/c[1]`). If the
  whole description doesn't fit into the buffer, it is cut at a UTF-8 character boundary and
  `truncated` is set. With an empty buffer (`.init(&.{})`) only `kind`, `line` and `column` are
  recorded, and `"{f}"` prints the kind. The description is always valid UTF-8: invalid UTF-8 in
  names you pass in is replaced by U+FFFD.
- A name you pass in (`attr`, `child`, …) may point anywhere, **also into the `Diagnostics`
  buffer** (e.g. a part of `diag.message()` from a previous error): it is copied before the
  description is written. Earlier versions wrote the description while reading the name from the
  same buffer, which panicked in Debug / ReleaseSafe and was undefined behaviour in ReleaseFast /
  ReleaseSmall.
- Without `Options.diagnostics` nothing is recorded or formatted, so errors cost nothing extra
  (e.g. when `childOpt` / `catch` is used for control flow).

The example `examples/m7/m7.zig` shows a function that takes `?*Diagnostics` from its caller.

## Out of memory

- `Document.parse`: on `error.OutOfMemory` everything allocated so far is freed and no document is
  returned. The diagnostics get the kind `document_out_of_memory`.
- Lookups by name (`attr*`, `child*`, `children`) can return `error.OutOfMemory`: every requested
  name is added to a set of used names (a hash map in the document's internal arena) so that
  a second request can be detected. A name that doesn't exist in the element is also copied into
  the arena. When this fails, the name is not marked as used.
- `text*` without an allocator, `ignoreAll`, `unused`, `expectAllUsed` and `Diagnostics.format`
  never allocate.
- `...Alloc` functions return `error.OutOfMemory` when the caller's allocator fails. Nothing is
  leaked: memory allocated for the failed value is freed before returning. Values returned by
  earlier calls belong to the caller, who frees them as usual (`errdefer`).
- Every `error.OutOfMemory` is recorded in `Options.diagnostics` (kind `document_out_of_memory`
  or `value_out_of_memory`, see above); recording it doesn't allocate.
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
