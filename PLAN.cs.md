# PLAN.cs.md — use-xml-zig

Anglická verze: [PLAN.md](PLAN.md).

## Cíl

Knihovna v Zigu pro extrakci dat z XML v duchu
[UseData.Xml](https://github.com/radekm/UseData.Xml). Charakteristická vlastnost: po extrakci umí říct,
**která data v XML nebyla použita** (atributy, podelementy, text).

Na rozdíl od UseData.Xml (která stojí na `System.Xml`) obsahuje tato knihovna i vlastní XML parser.
API UseData.Xml je postavené na closures a `IDisposable`, takže ho nejde přímo portovat. Proto vzniklo
nové API: [docs/cs/api.md](docs/cs/api.md).

## Rozsah (v1)

- Celý vstup je v paměti jako `[]const u8`, pouze UTF-8 (UTF-8 BOM je povolen).
- Nevalidující parser XML 1.0, který kontroluje well-formedness:
  - XML deklarace (verze 1.0; kódování chybí nebo je UTF-8),
  - elementy, atributy (duplicity se odmítnou), text, CDATA,
  - reference na znaky `&#…;` / `&#x…;` a 5 předdefinovaných entit,
  - normalizace konců řádků (`\r\n`, `\r` → `\n`) a hodnot atributů,
  - komentáře a processing instructions se přeskakují,
  - `<!DOCTYPE …>` se odmítne,
  - smíšený obsah (neprázdný text vedle podelementů) se odmítne.
- Namespacy se ignorují: elementy a atributy se hledají podle lokálního jména; atributy `xmlns`
  a `xmlns:*` se přeskakují. Dva sourozenecké elementy (nebo dva atributy jednoho elementu) se
  stejným lokálním jménem a různými prefixy jsou chyba.
- API pro extrakci: `attr`, `child`, `children`, `text` a jejich varianty (`Opt`, `With`, `Alloc`),
  `ignoreAll`; podrobné informace o chybách v `doc.diagnostics()` / `ParseDiagnostics`.
- Hlášení nepoužitých dat po extrakci (`Document.unused()`, `Document.expectAllUsed()`).
- Parsery hodnot: řetězce, celá čísla, floaty, `bool`, enumy, `Timestamp` (UTC) a uživatelské typy.

## Mimo rozsah (zatím)

- Streamovaný vstup, jiná kódování než UTF-8.
- DTD, vlastní entity, validace (XSD).
- Porovnávání se zohledněním namespaců.
- `decimal` (zatím jen floaty).
- Deklarativní mapování na struktury přes comptime reflexi (`decode(MyStruct, elem)`).
- Zápis / serializace XML.

## Rozhodnutí

| Datum      | Rozhodnutí |
|------------|------------|
| 2026-11-23 | Vstup je celý v paměti, pouze UTF-8. |
| 2026-11-23 | Nepoužitá data se kontrolují jednou, po extrakci, průchodem stromem (žádná obdoba `Dispose`). Lze je vypsat (iterátor) nebo převést na chybu. |
| 2026-11-23 | Namespacy / prefixy se ignorují jako v UseData.Xml. |
| 2026-11-23 | Žádný `decimal`; čísla s desetinnou částí se parsují do floatů. Součástí knihovny je typ `Timestamp` (UTC). |
| 2026-11-23 | Ve v1 žádné comptime mapování na struktury. |
| 2026-11-23 | Paměť: arena dokumentu nikdy neopustí knihovnu. Hodnoty bez alokátoru jsou vypůjčené (platí, dokud žije dokument a vstup). Varianty `...Alloc` kopírují / alokují alokátorem volajícího; vlastní parsery, které alokují, dostanou alokátor volajícího. |
| 2026-11-23 | Celá čísla: volitelné `+` / `-`, úvodní nuly povoleny. Floaty: jen běžný desetinný zápis (bez exponentu, `inf`, `nan`). `bool`: `true` / `false`, záleží na velikosti písmen. `Timestamp`: jen přípona `Z`. |
| 2026-11-23 | `text*` na elementu s podelementy selže s `error.WrongCount`. |
| 2026-11-23 | Varianty jsou samostatné funkce (`attr`, `attrWith`, `attrAlloc`, …), ne struktura s volbami. |
| 2026-11-23 | Vyžádaná jména, která neexistují, se pamatují (druhé vyžádání selže s `AlreadyUsed`); vyhledávání podle jména proto může vrátit `OutOfMemory`. |
| 2026-11-23 | Chyby extrakce si zaznamenává dokument (`doc.diagnostics()`), takže je zřejmé, že po `doc.deinit()` neplatí; kdo parsuje, nahlásí je předtím. Syntaktické chyby XML jdou do samostatné `ParseDiagnostics` (bez ukazatelů) předané v `Options`. |
| 2026-11-23 | Používá se pouze větev `master`. |

## Milníky

- [x] **M0 — Založení projektu:** `AGENTS`, `PLAN`, `README` (EN + CS), kostra `build.zig`.
- [x] **M1 — Návrh API:** `docs/en/api.md` + `docs/cs/api.md`, schválené vlastníkem.
- [x] **M2 — XML parser:** tokenizer + stavba stromu (iterativně, bez rekurze na úroveň zanoření),
      řádek/sloupec v diagnostice chyb, testy well-formedness (včetně nevalidních vstupů z testů
      UseData.Xml).
- [x] **M3 — API elementu:** vyhledávání, sledování použití (každý atribut / jméno podelementu / text
      lze použít jednou), chyby `WrongCount` / `AlreadyUsed`, cesta k elementu v `Diagnostics`.
- [x] **M4 — Parsery hodnot:** řetězce, celá čísla, floaty, bool, enumy, hook `parseXml`, `Timestamp`.
- [x] **M5 — Hlášení nepoužitých dat:** `Document.unused()`, `Document.expectAllUsed()`, `ignoreAll`.
- [x] **M6 — Port testů a příklad:** portovat všechny testy UseData.Xml, přidat příklad se zprávou M7
      jako test a jednoduchý benchmark (`zig build bench`).
- [x] **CI:** GitHub Actions (`mlugg/setup-zig`, Zig 0.17.1) spouští `zig fmt --check` a testy
      (Debug + ReleaseSafe) na Linuxu, macOS a Windows.
- [x] **M7 — Dokončení:** průvodce v `docs/en` + `docs/cs` (kód otestovaný v `examples/guide`), doc
      komentáře, `zig build docs`.

## Otevřené otázky

Momentálně žádné.
