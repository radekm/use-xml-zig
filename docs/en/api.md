# API design (draft for M1)

Czech version: [../cs/api.md](../cs/api.md).

> Status: **draft**, waiting for the owner's approval. Names and signatures may still change.

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
| exceptions with data (`WrongCount`, `ParseError`) | Zig errors + a `Diagnostics` struct with the details         |
| GC                                                | borrowed values, or `...Alloc` variants with the caller's allocator |

## Example

```zig
const std = @import("std");
const xml = @import("use_xml");

const Person = struct {
    name: []const u8, // owned by `gpa`
    address: ?[]const u8, // owned by `gpa`
    age: u8,
    born: xml.Timestamp,
};

fn readPeople(gpa: std.mem.Allocator, input: []const u8) ![]Person {
    var diag: xml.Diagnostics = .{};
    var doc = xml.Document.parse(gpa, input, .{ .diagnostics = &diag }) catch |err| {
        std.log.err("{f}", .{diag});
        return err;
    };
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
            .born = try (try p.child("born")).text(xml.Timestamp),
        };
    }

    // Fails with error.UnusedData if something in the input was not used;
    // `diag` then describes the first unused item.
    try doc.expectAllUsed();
    return result;
}
```

## Types

### `Document`

```zig
pub const Document = struct {
    pub const Options = struct {
        /// Filled in when `parse` or any extraction function fails.
        diagnostics: ?*Diagnostics = null,
        /// Maximum element nesting depth. Deeper input fails with error.InvalidXml.
        max_depth: u32 = 256,
    };

    /// Parses the whole input. `input` must stay alive and unchanged until `deinit`.
    /// All internal memory comes from `gpa` (through an internal arena).
    pub fn parse(gpa: Allocator, input: []const u8, options: Options) ParseError!Document;
    pub fn deinit(doc: *Document) void;

    /// The root element.
    pub fn root(doc: *Document) *Elem;

    /// Iterates over elements that have unused content (see "Unused data").
    pub fn unused(doc: *Document) UnusedIterator;
    /// Returns error.UnusedData (and fills `diagnostics`) if anything was not used.
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
pub fn path(e: *const Elem) Path;
```

#### Attributes

```zig
// Borrowed result (no allocation; strings point into the input or into the document).
pub fn attr(e: *Elem, comptime T: type, name: []const u8) Error!T;
pub fn attrOpt(e: *Elem, comptime T: type, name: []const u8) Error!?T;

// Custom parser without allocation: `parser: fn ([]const u8) E!R`.
pub fn attrWith(e: *Elem, name: []const u8, comptime parser: anytype) (Error || E)!R;
pub fn attrOptWith(e: *Elem, name: []const u8, comptime parser: anytype) (Error || E)!?R;

// Result allocated with the caller's allocator (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, name: []const u8) Error!T;
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, name: []const u8) Error!?T;

// Custom parser that allocates: `parser: fn (Allocator, []const u8) E!R`, gets `gpa`.
pub fn attrAllocWith(e: *Elem, gpa: Allocator, name: []const u8, comptime parser: anytype) (Error || E)!R;
pub fn attrOptAllocWith(e: *Elem, gpa: Allocator, name: []const u8, comptime parser: anytype) (Error || E)!?R;
```

- `attr*` fails with `error.WrongCount` if the attribute is missing.
- `attrOpt*` returns `null` if the attribute is missing.

#### Child elements

```zig
pub fn child(e: *Elem, name: []const u8) Error!*Elem;            // exactly one
pub fn childOpt(e: *Elem, name: []const u8) Error!?*Elem;        // zero or one
pub fn children(e: *Elem, name: []const u8) Error![]const *Elem; // any number, document order
```

- `child` fails with `error.WrongCount` unless there is exactly one child with that name.
- `childOpt` fails with `error.WrongCount` if there are two or more.
- The returned slice and elements are owned by the document (valid until `deinit`).

#### Text

```zig
pub fn text(e: *Elem, comptime T: type) Error!T;
pub fn textWith(e: *Elem, comptime parser: anytype) (Error || E)!R;
pub fn textAlloc(e: *Elem, gpa: Allocator, comptime T: type) Error!T;
pub fn textAllocWith(e: *Elem, gpa: Allocator, comptime parser: anytype) (Error || E)!R;
```

Text is the concatenation of all text and CDATA sections directly inside the element. Comments
and processing instructions between them are dropped. Whitespace is kept as it is (no trimming).
An empty element (`<a/>`, `<a></a>`) has the text `""`.

#### Ignoring

```zig
/// Marks all attributes, child names and the text of `e` as used.
/// Child elements are not visited, so their content is not reported either.
pub fn ignoreAll(e: *Elem) void;
```

#### Error set

```zig
pub const Error = error{
    WrongCount,   // missing attribute/child, or too many children
    AlreadyUsed,  // the same attribute / child name / text was requested twice
    InvalidValue, // a built-in value parser rejected the string
    OutOfMemory,  // only from ...Alloc variants
};
```

Custom parsers may return any error. It is passed through unchanged and is recorded in
`Diagnostics` (the message is the error name).

## Usage rules

1. Each **attribute name**, each **child name** and the **text** of an element can be requested
   **at most once**. A second request fails with `error.AlreadyUsed`. This also holds for names
   that don't exist (`attrOpt("x")` twice is an error). This prevents double processing and
   matches UseData.Xml.
2. `child`, `childOpt` and `children` mark the **whole group** of children with that name as used.
   Each returned element is then *visited*: its own content is checked by the unused report.
3. Asking for a name that is not present is fine (`attrOpt`, `childOpt`, `children` return
   `null` / an empty slice). Only `attr` and `child` fail.
4. The order of requests doesn't matter.

## Unused data

After extraction, `doc.unused()` walks all *visited* elements (the root and all elements returned
by `child*` / `children`) in document order. It yields one entry for each element that has
something unused:

```zig
pub const Unused = struct {
    elem: *const Elem,                    // where (use elem.path() for a printable path)
    attrs: UnusedAttrIterator,            // unused attributes (name + value)
    children: UnusedChildNameIterator,    // names of child groups that were never requested
    text: ?[]const u8,                    // unused text, or null
};
```

- Unused child elements are reported **only by name in their parent**. Their content is not
  examined, because nobody looked at them.
- Text that contains only whitespace and no CDATA is never reported. The same is true for
  whitespace between child elements.
- `xmlns` / `xmlns:*` attributes are never reported.
- `doc.expectAllUsed()` is a shortcut that fails with `error.UnusedData` on the first entry and
  describes it in `Diagnostics`.

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
| signed / unsigned ints  | decimal digits with an optional sign (`-`; `+` see open questions); must fit into `T` |
| `f32`, `f64`            | decimal number, optional fraction and exponent (`1`, `-0.5`, `1.5e3`) |
| `bool`                  | `true`, `false` |
| `enum`                  | exactly the name of one of the tags (`@tagName`) |
| `xml.Timestamp`         | see below |
| `?T`                    | not allowed. Use the `Opt` variants instead. |

User types can define a hook that `attr` / `text` find automatically:

```zig
pub fn parseXml(s: []const u8) !@This();                         // used by attr / text
pub fn parseXmlAlloc(gpa: Allocator, s: []const u8) !@This();    // used by ...Alloc
```

The module `xml.parse` contains the built-in parsers as plain functions, so they can be combined
in custom parsers (`xml.parse.int(u32, s)`, `xml.parse.float(f64, s)`, `xml.parse.timestamp(s)`,
`xml.parse.oneOf(&.{ "a", "b" })` …).

### `Timestamp`

```zig
/// A point in time in UTC with nanosecond precision.
pub const Timestamp = struct {
    seconds: i64, // since 1970-01-01T00:00:00Z
    nanos: u32,   // 0 ..< 1_000_000_000
};
```

Accepted format (proposal, like UseData.Xml's `dateTimeOffset`):
`YYYY-MM-DDTHH:MM:SS[.f…]Z`, where `T` may also be a single space and the fraction has 1–9
digits. The date and time are validated (month lengths, leap years). Years are 0000–9999.

## `Diagnostics`

```zig
pub const Diagnostics = struct {
    kind: Kind = .none,
    /// Element where the error happened (null for XML syntax errors).
    elem: ?*const Elem = null,
    /// Attribute name, child name, or null (text / syntax error).
    selector: ?[]const u8 = null,
    /// The string that failed to parse (InvalidValue / custom parser errors).
    input: ?[]const u8 = null,
    /// Human-readable message (static string or error name).
    message: []const u8 = "",
    /// 1-based position in the input for XML syntax errors.
    line: u32 = 0,
    column: u32 = 0,

    pub const Kind = enum { none, invalid_xml, wrong_count, already_used, invalid_value, unused_data };

    /// Prints e.g. `/company/address[0]: attribute "city": expected exactly one`.
    pub fn format(d: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void;
};
```

Fields with slices point into the input or into the document, so they are valid until
`doc.deinit()`. When `Document.parse` fails, only `kind`, `message`, `line` and `column` are set.

## Open questions

1. **Integers:** accept a leading `+`? Leading zeros (`007`)? (Zig's `std.fmt.parseInt` also
   accepts `_` between digits. We don't want that; we will use our own strict parser.)
2. **Floats:** allow `inf` / `nan` / hexadecimal floats? Proposal: no, only the decimal form above.
3. **`bool`:** only `true` / `false`, or also `1` / `0` (XML Schema)? Case-sensitive?
4. **`Timestamp`:** only the `Z` suffix, or also offsets (`+01:00`) that are converted to UTC?
5. **`text()` on an element with child elements:** return `""` (like UseData.Xml) or fail with
   an error? Proposal: an error (`error.WrongCount`), because asking for text there is almost
   certainly a bug.
6. **Number of variants:** 4 variants × (`attr`, `attrOpt`, `text`) give 12 functions. An
   alternative is an options struct (`e.attr(T, "x", .{ .gpa = gpa })`). Proposal: keep the
   separate functions; they are explicit and greppable.
