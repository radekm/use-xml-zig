# Návrh API

Anglická verze: [../en/api.md](../en/api.md).

Toto je popis API s rozhodnutími o návrhu. Pro úvod si přečtěte [průvodce](guide.md).

> Stav: **schváleno** (2026-11-23). Změny musí schválit vlastník.

## Myšlenka

Knihovna naparsuje celý XML dokument do stromu. Uživatel pak strom prochází a vytahuje přesně ta
data, která potřebuje. Knihovna si zaznamenává, co bylo použito. Po extrakci umí nahlásit každý
atribut, podelement a text, **o který si nikdo neřekl**. Tak se odhalí překvapení ve vstupních datech
(nová pole, překlepy ve jménech elementů, data, která kód potichu ignoruje).

Je to stejná myšlenka jako v [UseData.Xml](https://github.com/radekm/UseData.Xml). Rozdíly plynou
ze Zigu:

| UseData.Xml (F#)                                    | use-xml-zig                                                     |
|-----------------------------------------------------|-----------------------------------------------------------------|
| callback `child "a" (fun e -> …)`                   | `child("a")` vrátí `*Elem` a kód pokračuje s ním                |
| `children "a" (fun e -> …)` vrací `'T[]`            | `children("a")` vrací `[]const *Elem` (smyčka `for`)            |
| closure `StringParser<'T>`                          | typ `T` známý v comptime, nebo funkce `fn([]const u8) !T`       |
| `Dispose` + `ITracer` u každého elementu            | `doc.unused()` / `doc.expectAllUsed()` po extrakci              |
| výjimky s daty (`WrongCount`, `ParseError`)         | Zig chyby + `doc.diagnostics()` / `ParseDiagnostics` s podrobnostmi |
| GC                                                  | vypůjčené hodnoty, nebo varianty `...Alloc` s alokátorem volajícího |

## Příklad

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

## Typy

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

Všechny funkce berou `e: *Elem`. Každá vyhledávací funkce označí to, na co se podívala, jako **použité**.

#### Informace o elementu

```zig
pub fn name(e: *const Elem) []const u8;      // local name (without prefix)
pub fn parent(e: *const Elem) ?*Elem;
/// Index among siblings with the same name (0-based). Used in paths: /company/address[0].
pub fn index(e: *const Elem) u32;
/// Printable path from the root, e.g. `/company/address[0]/city[0]` (use with "{f}").
/// Printing doesn't allocate and takes time quadratic in the depth of `e`.
pub fn path(e: *const Elem) Path;
```

#### Atributy

```zig
// Borrowed result (no allocation; strings point into the input or into the document).
pub fn attr(e: *Elem, comptime T: type, attr_name: []const u8) Error!T;
pub fn attrOpt(e: *Elem, comptime T: type, attr_name: []const u8) Error!?T;

// Custom parser without allocation: `parser: fn ([]const u8) E!R`.
pub fn attrWith(e: *Elem, attr_name: []const u8, comptime parser: anytype) (Error || E)!R;
pub fn attrOptWith(e: *Elem, attr_name: []const u8, comptime parser: anytype) (Error || E)!?R;

// Result allocated with the caller's allocator (strings are copied).
pub fn attrAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) Error!T;
pub fn attrOptAlloc(e: *Elem, gpa: Allocator, comptime T: type, attr_name: []const u8) Error!?T;

// Custom parser that allocates: `parser: fn (Allocator, []const u8) E!R`, gets `gpa`.
pub fn attrAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, comptime parser: anytype) (Error || E)!R;
pub fn attrOptAllocWith(e: *Elem, gpa: Allocator, attr_name: []const u8, comptime parser: anytype) (Error || E)!?R;
```

- `attr*` selže s `error.WrongCount`, když atribut chybí.
- `attrOpt*` vrátí `null`, když atribut chybí.

#### Podelementy

```zig
pub fn child(e: *Elem, child_name: []const u8) Error!*Elem;            // exactly one
pub fn childOpt(e: *Elem, child_name: []const u8) Error!?*Elem;        // zero or one
pub fn children(e: *Elem, child_name: []const u8) Error![]const *Elem; // any number, document order
```

- `child` selže s `error.WrongCount`, pokud neexistuje právě jeden podelement s daným jménem.
- `childOpt` selže s `error.WrongCount`, pokud jsou dva nebo víc.
- Vrácený slice i elementy vlastní dokument (platí do `deinit`).

#### Text

```zig
pub fn text(e: *Elem, comptime T: type) Error!T;
pub fn textWith(e: *Elem, comptime parser: anytype) (Error || E)!R;
pub fn textAlloc(e: *Elem, gpa: Allocator, comptime T: type) Error!T;
pub fn textAllocWith(e: *Elem, gpa: Allocator, comptime parser: anytype) (Error || E)!R;
```

Text je spojení všech textových a CDATA sekcí přímo uvnitř elementu. Komentáře a processing
instructions mezi nimi se zahodí. Bílé znaky zůstávají tak, jak jsou (žádné ořezávání). Prázdný
element (`<a/>`, `<a></a>`) má text `""`.

Volání `text*` na elementu, který má podelementy, selže s `error.WrongCount`.
(UseData.Xml tam vrací `""`; ptát se na tom místě na text je téměř jistě chyba v kódu.)

#### Ignorování

```zig
/// Marks all attributes, child names and the text of `e` as used.
/// Child elements are not visited, so their content is not reported either.
pub fn ignoreAll(e: *Elem) void;
```

#### Množina chyb

```zig
pub const Error = error{
    WrongCount,   // missing attribute/child, or too many children
    AlreadyUsed,  // the same attribute / child name / text was requested twice
    InvalidValue, // a built-in parser or a `parseXml` hook rejected the string
    OutOfMemory,  // see "Out of memory"
};
```

Vlastní parsery (`...With`) smí vracet libovolnou chybu (nebo žádnou). Chyba projde beze změny
a zaznamená se do `doc.diagnostics()` (zprávou je název chyby).
Chyby hooků `parseXml` / `parseXmlAlloc` se vrací jako `error.InvalidValue` (kromě
`error.OutOfMemory`), aby `attr(T, …)` měla vždy množinu chyb `Error`. Původní název chyby je
zprávou v `doc.diagnostics()`.

## Pravidla použití

1. Každé **jméno atributu**, každé **jméno podelementu** i **text** elementu lze vyžádat
   **nejvýše jednou**. Druhé vyžádání selže s `error.AlreadyUsed`. Platí to i pro jména, která
   neexistují (`attrOpt("x")` dvakrát je chyba). Taková jména si
   dokument pamatuje; odhalí se tak kód, který zpracovává stejnou věc dvakrát. Brání to dvojímu zpracování a odpovídá to UseData.Xml.
2. `child`, `childOpt` a `children` označí za použitou **celou skupinu** podelementů s tím jménem.
   Každý vrácený element je pak *navštívený*: jeho vlastní obsah kontroluje hlášení nepoužitých dat.
3. Ptát se na jméno, které neexistuje, je v pořádku (`attrOpt`, `childOpt`, `children` vrátí
   `null` / prázdný slice). Selžou jen `attr` a `child`.
4. Na pořadí dotazů nezáleží.

### Vlákna

Dokument **není thread-safe**, a to ani pro čtení: každá extrakční funkce ho mění (označuje data
jako použitá, pamatuje si chybějící jména v areně dokumentu a zapisuje `doc.diagnostics()`).
Dokument a jeho elementy používej vždy jen z jednoho vlákna naráz. Různé dokumenty lze používat
z různých vláken.

## Nepoužitá data

Po extrakci projde `doc.unused()` všechny *navštívené* elementy (kořen a všechny elementy vrácené
z `child*` / `children`) v pořadí dokumentu. Pro každý element, ve kterém zůstalo něco nepoužitého,
vrátí jednu položku:

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

- Nepoužité podelementy se hlásí **jen jménem v rodiči**. Jejich obsah se nezkoumá, protože se na
  ně nikdo nedíval.
- Text, který obsahuje jen bílé znaky a žádnou CDATA, se nikdy nehlásí. Totéž platí pro bílé znaky
  mezi podelementy. Počítají se jen bílé znaky zapsané přímo: znaková reference jako `&#32;` je
  text (a mezi podelementy se odmítne jako smíšený obsah).
- Atributy `xmlns` / `xmlns:*` se nikdy nehlásí.
- `doc.expectAllUsed()` je zkratka, která selže s `error.UnusedData` u první položky a popíše ji
  v `doc.diagnostics()`.
- Žádná z obou funkcí nealokuje ani nemění, co je označené jako použité, takže je lze volat
  opakovaně; výsledek vždy odpovídá aktuálnímu stavu. `unused()` nemění vůbec nic;
  `expectAllUsed()` jen zapíše svůj popis do `doc.diagnostics()`.

Příklad (z testů UseData.Xml):

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

## Hodnoty (`T` v `attr` / `text`)

Vestavěné typy:

| `T`                       | Přijímaný vstup |
|---------------------------|-----------------|
| `[]const u8`              | libovolný řetězec (vypůjčený; `...Alloc` kopíruje) |
| celá čísla se znaménkem i bez | volitelné znaménko `+` / `-`, pak jedna nebo více desítkových číslic; úvodní nuly jsou povoleny (`007`, `+5`, `-12`); žádné `_`, žádné bílé znaky; musí se vejít do `T` |
| `f32`, `f64`              | volitelné znaménko, číslice, volitelně `.` následovaná číslicemi (`1`, `-0.5`, `+007.25`); žádný exponent, žádné `inf` / `nan`, žádný šestnáctkový tvar, žádné `.5` ani `5.` |
| `bool`                    | přesně `true` nebo `false` (záleží na velikosti písmen) |
| `enum`                    | přesně jméno jednoho z tagů (`@tagName`); enumy s víc než zhruba 1000 tagy nejdou přeložit (chybová zpráva vypisuje všechny tagy), použij `attrWith` s `use_xml.parse.enumTag` |
| `use_xml.Timestamp`           | viz níže |
| `?T`                      | není povoleno. Použij varianty `Opt`. |

Uživatelské typy mohou definovat hook, který `attr` / `text` najdou automaticky:

```zig
pub fn parseXml(s: []const u8) !@This();                         // used by attr / text
pub fn parseXmlAlloc(gpa: Allocator, s: []const u8) !@This();    // used by ...Alloc
```

Hook má přednost před vestavěným parsováním (enum s `parseXml` se tedy neparsuje podle jména tagu).

Funkce `...Alloc` používají jen `parseXmlAlloc`. Typ s hookem, ale bez `parseXmlAlloc` s nimi
použít nejde (chyba překladu), protože `parseXml` může vracet řezy svého vstupu, které by
dokument nepřežily. Typ jen s `parseXmlAlloc` jde použít jen s `...Alloc`.

Modul `use_xml.parse` obsahuje vestavěné parsery jako obyčejné funkce vracející
`error{InvalidValue}!T`, takže je lze kombinovat ve vlastních parserech:
`use_xml.parse.int(u32, s)`, `use_xml.parse.float(f64, s)`, `use_xml.parse.boolean(s)`,
`use_xml.parse.enumTag(E, s)`, `use_xml.parse.timestamp(s)` a `use_xml.parse.oneOf(&.{ "a", "b" })`
(vrací parser pro `attrWith` / `textWith`).

### `Timestamp`

```zig
/// A point in time in UTC with nanosecond precision.
pub const Timestamp = struct {
    seconds: i64, // since 1970-01-01T00:00:00Z
    nanos: u32,   // 0 ..< 1_000_000_000
};
```

`Timestamp` má také `parse(s)` a `format` (tiskne stejný formát, takže `"{f}"` dá zpět původní řetězec).

Přijímaný formát (jako `dateTimeOffset` v UseData.Xml):
`YYYY-MM-DDTHH:MM:SS[.f…]Z`, kde `T` může být i jedna mezera a desetinná část má 1–9 číslic.
Datum i čas se validují (délky měsíců, přestupné roky). Roky jsou 0000–9999.

## `ParseDiagnostics` a `Diagnostics`

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
        wrong_count,
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

Chyby se popisují na dvou místech:

- **Syntaktické chyby XML** jdou do `ParseDiagnostics` předané v `Options.diagnostics` (když
  `parse` selže, žádný dokument, kam je uložit, není). Neobsahuje žádné ukazatele, takže platí
  navždy.
- **Chyby extrakčních funkcí a `expectAllUsed`** si zaznamenává sám dokument; `doc.diagnostics()`
  vrátí tu poslední. Její slicy ukazují do vstupu nebo do dokumentu, takže platí jen do
  `doc.deinit()`. Protože je součástí dokumentu, je tato doba platnosti zřejmá.
  Zaznamenává se každá chyba, kterou tyto funkce vrátí, i `error.OutOfMemory`, takže po chybě
  knihovny ji `doc.diagnostics()` vždy popisuje. Dva druhy říkají, kde paměť došla:
  `document_out_of_memory` (interní paměť dokumentu, používaná jen k zapamatování vyžádaných
  jmen, která neexistují) a `value_out_of_memory` (vytváření hodnoty: alokátor funkce `...Alloc`,
  nebo vlastní parser či hook `parseXmlAlloc`, který vrátil `error.OutOfMemory`).

  Drží jen **poslední** chybu: každá chyba ji přepíše a nic jiného ji nemění. Volání, která
  uspějí, v ní nechají předchozí chybu, proto `doc.diagnostics()` čti hned po chybě (v `catch`
  nebo `errdefer`). `kind != .none` říká jen to, že *nějaké* dřívější volání selhalo. Chyby, které
  nepochází z knihovny (např. z vlastních alokací mezi voláními), se pochopitelně nezaznamenají:
  `errdefer`, který loguje `doc.diagnostics()`, pak vypíše starší chybu.

**Chyby extrakce nahlas dřív, než zavoláš `doc.deinit()`.** Odpovídá za to kód, který dokument
parsuje. Typický vzor:

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

Příklad `examples/m7/m7.zig` ukazuje totéž s writerem, který předá volající.

## Nedostatek paměti

- `Document.parse`: při `error.OutOfMemory` se uvolní vše, co se do té doby alokovalo, a žádný
  dokument se nevrátí. `ParseDiagnostics` se nevyplní (samotná chyba říká dost).
- Vyhledávání podle jména (`attr*`, `child*`, `children`) může vrátit `error.OutOfMemory` **jen
  tehdy, když jméno v elementu neexistuje**: jméno se pak zkopíruje do interní areny dokumentu,
  aby šlo odhalit druhé vyžádání. Existující jména žádnou alokaci nepotřebují.
- `text*` bez alokátoru, `ignoreAll`, `unused`, `expectAllUsed` a `Diagnostics.format` nikdy
  nealokují.
- Funkce `...Alloc` vrátí `error.OutOfMemory`, když selže alokátor volajícího. Nic neunikne: paměť
  alokovaná pro neúspěšnou hodnotu se před návratem uvolní. Hodnoty vrácené dřívějšími voláními
  patří volajícímu, který je uvolní jako obvykle (`errdefer`).
- Každá chyba `error.OutOfMemory` extrakční funkce se zaznamená do `doc.diagnostics()` (druh
  `document_out_of_memory` nebo `value_out_of_memory`, viz výše); zaznamenání nic nealokuje.
- Hodnota se označí jako použitá ještě před parsováním. I když parsování selže (nevalidní hodnota,
  nedostatek paměti), druhé vyžádání stejného jména selže s `error.AlreadyUsed`.

## Zodpovězené otázky (2026-11-23)

1. Celá čísla: `+` i úvodní nuly jsou povoleny.
2. Floaty: jen běžný desetinný zápis bez exponentu.
3. `bool`: jen `true` / `false`, záleží na velikosti písmen.
4. `Timestamp`: jen přípona `Z`, žádné offsety.
5. `text*` na elementu s podelementy selže s `error.WrongCount`.
6. Samostatné funkce pro varianty (žádná struktura s volbami).
7. Jména, na která se někdo ptal, ale neexistují, si dokument pamatuje a druhé vyžádání selže
   s `error.AlreadyUsed`. Proto vyhledávání podle jména smí vrátit `error.OutOfMemory`.

## Otevřené otázky

Momentálně žádné.
