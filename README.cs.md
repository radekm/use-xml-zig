# use-xml-zig

Anglická verze: [README.md](README.md).

Knihovna v Zigu pro extrakci dat z XML, která vám řekne, **která data jste nepoužili**.
Je inspirovaná knihovnou [UseData.Xml](https://github.com/radekm/UseData.Xml) a obsahuje vlastní XML parser.

> **Stav:** fáze návrhu. Zatím není nic implementováno. Viz [PLAN.cs.md](PLAN.cs.md) a navržené API
> v [docs/cs/api.md](docs/cs/api.md).

## Plánované použití

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

## Požadavky

- Zig 0.17.1
- Žádné závislosti kromě standardní knihovny Zigu.

## Vývoj

```sh
zig build test
```

Pravidla pro přispěvatele (i AI agenty) jsou v [AGENTS.cs.md](AGENTS.cs.md).
