# use-xml-zig

Anglická verze: [README.md](README.md).

Knihovna v Zigu pro extrakci dat z XML, která vám řekne, **která data jste nepoužili**.
Je inspirovaná knihovnou [UseData.Xml](https://github.com/radekm/UseData.Xml) a obsahuje vlastní XML parser.

```zig
var diag: xml.Diagnostics = .{};
var doc = try xml.Document.parse(gpa, input, .{ .diagnostics = &diag });
defer doc.deinit();
errdefer std.log.err("{f}", .{diag}); // e.g. /people/person[1]: "nick": attribute was not used (input: "b")

for (try doc.root().children("person")) |p| {
    const name = try p.attr([]const u8, "name");
    const age = try p.attr(u8, "age");
    _ = .{ name, age };
}
try doc.expectAllUsed(); // fails if the input contains anything we didn't read
```

## Vlastnosti

- API pro extrakci: `attr`, `child`, `childOpt`, `children`, `text`, s typovanými hodnotami (celá
  čísla, floaty, `bool`, enumy, časové značky v UTC, vlastní typy) a vlastními parsery.
- Hlášení nepoužitých atributů, elementů a textu; každý údaj lze vyžádat jen jednou.
- Podrobné chyby s cestou k elementu (`/company/address[0]: "city": attribute is missing`).
- Vlastní nevalidující parser XML 1.0 (UTF-8, bez DTD), bez rekurze, s řádkem a sloupcem
  v chybových hlášeních.
- Žádné závislosti kromě standardní knihovny Zigu; žádné alokace mimo alokátory, které předáte.

## Požadavky

- Zig 0.17.1

## Dokumentace

- [Průvodce](docs/cs/guide.md): instalace, použití, paměť, chyby.
- [Popis API](docs/cs/api.md).
- `zig build docs` vygeneruje z doc komentářů HTML dokumentaci do `zig-out/docs`.
- [Příklad](examples/m7/m7.zig): extrakce knih objednávek ze zprávy M7.

## Vývoj

```sh
zig build test    # testy (knihovna + příklady)
zig build bench   # benchmark (vždy ReleaseFast)
zig build docs    # HTML dokumentace
```

Pravidla pro přispěvatele (i AI agenty) jsou v [AGENTS.cs.md](AGENTS.cs.md), plán v [PLAN.cs.md](PLAN.cs.md).
