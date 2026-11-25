# Průvodce

Anglická verze: [../en/guide.md](../en/guide.md).

use-xml je knihovna v Zigu pro čtení dat z XML. Její charakteristická vlastnost: když si přečtete,
co potřebujete, řekne vám, **která data v dokumentu jste nepřečetli**. Neočekávané atributy, nové
elementy ani překlepy ve jménech se tak potichu neztratí.

Tento průvodce ukazuje, jak knihovnu používat. Úplný popis API je v [api.md](api.md);
`zig build docs` vygeneruje z doc komentářů HTML dokumentaci do `zig-out/docs`.
Veškerý kód z tohoto průvodce je otestovaný v [examples/guide/guide.zig](../../examples/guide/guide.zig).

## Instalace

Vyžaduje Zig 0.17.1. Přidejte závislost do svého `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/radekm/use-xml-zig
```

a importujte modul v `build.zig`:

```zig
const use_xml = b.dependency("use_xml", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("use_xml", use_xml.module("use_xml"));
```

## Rychlý start

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

Postup je vždy stejný:

1. `use_xml.Document.parse` načte celý vstup (v paměti, UTF-8) do stromu. Nevalidní XML selže
   s `error.InvalidXml`.
2. Od `doc.root()` se ptáte na atributy, podelementy a text. Každý dotaz označí data jako
   *použitá*.
3. `doc.expectAllUsed()` selže s `error.UnusedData`, pokud něco zůstalo nepoužité.
   Kdyby vstup obsahoval třeba `<person name="Bob" age="42" nick="b"/>`, chyba by byla
   `/people/person[1]: "nick": attribute was not used (input: "b")`.

## Čtení dokumentu

| Funkce                       | Vrací                         | Selže, když                                     |
|------------------------------|-------------------------------|-------------------------------------------------|
| `e.attr(T, "a")`             | hodnotu atributu `a`          | `Missing`: atribut chybí                        |
| `e.attrOpt(T, "a")`          | hodnotu nebo `null`           | —                                               |
| `e.child("c")`               | jediný podelement `<c>`       | `Missing`: žádný `<c>`; `TooMany`: dva a více   |
| `e.childOpt("c")`            | podelement `<c>` nebo `null`  | `TooMany`: dva nebo více `<c>`                  |
| `e.children("c")`            | všechny podelementy `<c>` (slice) | —                                           |
| `e.text(T)`                  | text elementu                 | `HasChildren`: element má podelementy           |
| `e.ignoreAll()`              | označí vše v `e` jako použité | —                                 |

Několik pravidel:

- **Každé jméno atributu, jméno podelementu i text lze u elementu vyžádat jen jednou.**
  Druhý dotaz selže s `error.AlreadyUsed`. Platí to i pro jména, která neexistují
  (`attrOpt("x")` dvakrát je chyba). Odhalí se tak kód, který zpracovává stejná data dvakrát.
- **Jména jsou lokální.** Prefixy namespaců se ignorují (`<h:table>` je `"table"`) a atributy
  `xmlns` nejsou vidět. Kolize lokálních jmen jsou chyba: `Document.parse` odmítne dva atributy
  se stejným lokálním jménem (`<a p:x="1" q:x="2"/>`) i podelementy se stejným lokálním jménem
  a různými prefixy (`<p:a/><q:a/>`).
- **Text** je text uvnitř elementu včetně sekcí CDATA, bílé znaky zůstávají, jak jsou.
  Prázdný element má text `""`. Elementy s podelementy text nemají; bílé znaky mezi podelementy se
  ignorují, jiný text vedle podelementů (smíšený obsah) odmítne už parser.
- `children` vrací elementy v pořadí dokumentu; jejich pořadí vůči elementům s jinými jmény
  k dispozici není.

## Hodnoty

`attr(T, …)` a `text(T)` převedou řetězec na `T`:

| `T`                 | Přijímané řetězce |
|---------------------|-------------------|
| `[]const u8`        | cokoli |
| celá čísla          | `42`, `+5`, `-12`, `007` (musí se vejít do `T`) |
| `f32`, `f64`        | `1`, `-0.5`, `+007.25` (bez exponentu, bez `inf` / `nan`) |
| `bool`              | `true`, `false` |
| enumy               | jméno tagu, např. `red` |
| `use_xml.Timestamp`     | `2021-05-31T23:12:04Z`, `2021-05-31 23:12:04.123Z` (jen UTC) |
| vlastní typ         | cokoli, co přijme jeho `parseXml` (viz níže) |

Jiné převody zajistí vlastní parsery:

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

- `attrWith` / `textWith` berou libovolnou funkci `fn ([]const u8) E!R`, i jako ukazatel
  (`*const fn ([]const u8) E!R`). Její chyba se vrátí beze změny.
- Místo `parser(try attr([]const u8, name))` pište `attrWith(name, parser)`: jen chyba uvnitř
  `attrWith` se zaznamená do `Diagnostics` i s cestou, jménem a vstupem.
- Parser, který potřebuje stav (např. hodnoty známé až za běhu), je hodnota s metodou
  `pub fn parse(self, []const u8) E!R`; místo funkce se předá tato hodnota (nebo ukazatel na ni):

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
- Typ s `pub fn parseXml([]const u8) !T` lze použít přímo jako `T`. Chyby hooku se vrací jako
  `error.InvalidValue`; hook, který nemůže selhat, smí vracet jen `T`. Aby šel typ použít
  s funkcemi `...Alloc`, potřebuje navíc `pub fn parseXmlAlloc(Allocator, []const u8) !T`, který
  nesmí vracet řezy svého vstupu.
- Vestavěné parsery jsou k dispozici jako `use_xml.parse.int`, `float`, `boolean`, `enumTag`,
  `timestamp` a `oneOf`, takže je vlastní parsery mohou využít.

## Paměť

`Document.parse(gpa, input, …)` alokuje vše potřebné z `gpa` a uvolní to v `doc.deinit()`. Vstup
musí do té doby zůstat platný a nezměněný.

Hodnoty jsou dvojího druhu:

- **Vypůjčené** (`attr`, `text`, `attrWith`, …): řetězce ukazují do vstupu nebo do dokumentu.
  Žádná alokace, ale platí jen do `doc.deinit()`.
- **Vlastněné** (`attrAlloc`, `textAlloc`, `attrAllocWith`, `textAllocWith` a varianty `Opt`):
  alokované alokátorem, který předáte, takže přežijí dokument. Vlastní parsery použité s
  `...AllocWith` dostanou tento alokátor: `fn (Allocator, []const u8) E!R`.

Obvyklý postup je parsovat ve funkci, potřebná data zkopírovat do vlastních struktur pomocí areny
(jako v rychlém startu) a dokument před návratem uvolnit.

Dokument **není thread-safe**, a to ani pro čtení: každá extrakční funkce (`attr`, `child`,
`text`, …) ho mění, protože zaznamenává, co bylo použito. Jeden dokument používejte vždy jen
z jednoho vlákna naráz; různé dokumenty lze zpracovávat paralelně, každý s vlastní `Diagnostics`.

## Chyby

Chyby v Zigu nemohou nést data, proto se popis zapisuje do `use_xml.Diagnostics` předané
v `Document.Options.diagnostics`, s bufferem, který dodáte (jako v rychlém startu). Zaznamená se
tam každá chyba knihovny; drží se jen ta poslední:

| Chyba             | `Diagnostics.kind` | Příklad `"{f}"` |
|-------------------|--------------------|-----------------|
| `InvalidXml`      | `invalid_xml`      | `invalid XML at line 2, column 4: end tag does not match start tag` |
| `Missing`         | `missing`          | `/person: "name": expected exactly one child element, found none` |
| `TooMany`         | `too_many`         | `/person: "name": expected at most one child element, found more than one` |
| `HasChildren`     | `has_children`     | `/person: element has child elements, so it has no text` |
| `AlreadyUsed`     | `already_used`     | `/a: "x": attribute was already used` |
| `InvalidValue`    | `invalid_value`    | `/server: "port": expected integer (u16) (input: "80x")` |
| z vlastního parseru | `invalid_value`  | `/a: "d": UnknownColor (input: "blue")` |
| `UnusedData`      | `unused_data`      | `/config/server[0]: "tls": attribute was not used (input: "true")` |
| `OutOfMemory`     | `value_out_of_memory` | `/a: "x": out of memory while producing the value` |
| `OutOfMemory`     | `document_out_of_memory` | `/a: "x": document out of memory` |

`value_out_of_memory` znamená, že paměť došla při vytváření hodnoty (alokátor předaný do
`...Alloc` nebo váš parser); `document_out_of_memory` znamená, že došla vlastní paměť dokumentu.

Popis se kopíruje do vašeho bufferu, takže platí i po `doc.deinit()`: chybu nahlaste tam, kde se
to hodí, např. ve volajícím. `Diagnostics` (i její buffer) musí žít až do `doc.deinit()`, protože
do ní dokument zapisuje. Popisy, které se do bufferu nevejdou, se oříznou (nastaví se
`truncated`); 4096 bajtů na běžné dokumenty bohatě stačí. Bez `Options.diagnostics` se nic
nezaznamená.

## Nepoužitá data

Po extrakci vypíše `doc.unused()` elementy s nepoužitým obsahem:

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

Co se hlásí:

- Zkoumají se jen elementy, ke kterým jste se skutečně dostali (kořen a elementy vrácené z
  `child`, `childOpt` nebo `children`). Nepoužitý podelement se hlásí jménem v rodiči; jeho obsah
  se nezkoumá.
- Text se hlásí, jen když obsahuje něco jiného než bílé znaky (nebo sekci CDATA).
- Atributy `xmlns` a jména, na která jste se ptali a neexistují, se nikdy nehlásí.

Data, která záměrně nepotřebujete, buď vyžádejte a výsledek zahoďte
(`_ = try e.attrOpt([]const u8, "comment")`) — tím se zároveň ověří jejich formát — nebo zavolejte
`e.ignoreAll()`, které označí jako použité vše v `e` včetně obsahu všech potomků. Potom každý
dotaz na `e` selže s `error.AlreadyUsed`.

`doc.expectAllUsed()` je zkratka: selže s `error.UnusedData` a první nepoužitou položku popíše
v diagnostice.

## Podporované XML

- XML 1.0, jen UTF-8 (UTF-8 BOM je povolen), celý dokument v paměti.
- Elementy, atributy, text, CDATA, reference na znaky (`&#…;`, `&#x…;`) a entity
  `&lt;`, `&gt;`, `&amp;`, `&apos;`, `&quot;`.
- Komentáře a processing instructions se přeskakují.
- Nepodporováno (odmítne se jako `InvalidXml`): `<!DOCTYPE …>` a vlastní entity, smíšený obsah
  (text vedle podelementů), jiná kódování.
- Elementy smí být zanořené nejvýše `Options.max_depth` úrovní (výchozí 256; kořen má hloubku 1,
  takže 0 odmítne každý dokument). Parser nepoužívá rekurzi, takže ani velký limit nemůže přetéct
  zásobník. Výpis cesty k elementu trvá čas kvadratický v jeho hloubce, takže s velmi vysokým
  limitem (stovky tisíc) jsou `Elem.path` a hlášení nepoužitých dat u hluboko zanořených elementů
  pomalé. Popisy v `Diagnostics` vypisují jen konec dlouhé cesty, takže zůstávají rychlé.

## Rozdíly oproti UseData.Xml

Myšlenka je stejná jako v [UseData.Xml](https://github.com/radekm/UseData.Xml), API je
přizpůsobené Zigu:

- Místo callbacků (`child "a" (fun e -> …)`) vrací `child("a")` přímo element.
- Nepoužitá data se kontrolují jednou po extrakci (`doc.unused()`, `doc.expectAllUsed()`), ne při
  uvolnění každého elementu.
- Místo výjimek jsou chyby Zigu a `Diagnostics` s popisem.
- `text` na elementu s podelementy je chyba, ne `""`.
- `decimal` není podporován; čísla s desetinnou částí se parsují jako floaty.

## Další informace

- [api.md](api.md): popis API a rozhodnutí o návrhu.
- [examples/m7/m7.zig](../../examples/m7/m7.zig): příklad z praxe (port benchmarku z UseData.Xml),
  který ukazuje i funkci, která dostane `?*Diagnostics` od volajícího, a jak volající chybu
  nahlásí.
- `zig build bench`: benchmark.
