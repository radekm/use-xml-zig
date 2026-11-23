# use-xml-zig

Czech version: [README.cs.md](README.cs.md).

A Zig library for extracting data from XML that tells you **which data you did not use**.
It is inspired by [UseData.Xml](https://github.com/radekm/UseData.Xml) and contains its own XML parser.

```zig
var doc = try xml.Document.parse(gpa, input, .{});
defer doc.deinit();
errdefer std.log.err("{f}", .{doc.diagnostics()}); // e.g. /people/person[1]: "nick": attribute was not used (input: "b")

for (try doc.root().children("person")) |p| {
    const name = try p.attr([]const u8, "name");
    const age = try p.attr(u8, "age");
    _ = .{ name, age };
}
try doc.expectAllUsed(); // fails if the input contains anything we didn't read
```

## Features

- Extraction API: `attr`, `child`, `childOpt`, `children`, `text`, with typed values (integers,
  floats, `bool`, enums, UTC timestamps, your own types) and custom parsers.
- Reporting of unused attributes, elements and text; each piece of data can be requested only once.
- Detailed errors with the path to the element (`/company/address[0]: "city": attribute is missing`).
- Own non-validating XML 1.0 parser (UTF-8, no DTD), without recursion, with line and column in
  error messages.
- No dependencies besides the Zig standard library; no allocation outside the allocators you pass in.

## Requirements

- Zig 0.17.1

## Documentation

- [Guide](docs/en/guide.md): installation, usage, memory, errors.
- [API reference](docs/en/api.md).
- `zig build docs` generates HTML documentation from doc comments into `zig-out/docs`.
- [Example](examples/m7/m7.zig): extracting order books from an M7 message.

## Development

```sh
zig build test    # tests (library + examples)
zig build bench   # benchmark (always ReleaseFast)
zig build docs    # HTML documentation
```

Rules for contributors (and AI agents) are in [AGENTS.md](AGENTS.md), the plan in [PLAN.md](PLAN.md).

## License

[zlib](LICENSE)
