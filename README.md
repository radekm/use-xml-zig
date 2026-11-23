# use-xml-zig

Czech version: [README.cs.md](README.cs.md).

A Zig library for extracting data from XML that tells you **which data you did not use**.
It is inspired by [UseData.Xml](https://github.com/radekm/UseData.Xml) and contains its own XML parser.

> **Status:** design phase. Nothing is implemented yet. See [PLAN.md](PLAN.md) and the proposed API
> in [docs/en/api.md](docs/en/api.md).

## Planned usage

```zig
var doc = try xml.Document.parse(gpa, input, .{ .diagnostics = &diag });
defer doc.deinit();

for (try doc.root().children("person")) |p| {
    const name = try p.attr([]const u8, "name");
    const age = try p.attr(u8, "age");
    _ = .{ name, age };
}
try doc.expectAllUsed(); // fails if the input contains anything we didn't read
```

## Requirements

- Zig 0.17.1
- No dependencies besides the Zig standard library.

## Development

```sh
zig build test
```

Rules for contributors (and AI agents) are in [AGENTS.md](AGENTS.md).
