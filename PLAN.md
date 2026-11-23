# PLAN.md — use-xml-zig

Czech version: [PLAN.cs.md](PLAN.cs.md).

## Goal

A Zig library for extracting data from XML in the spirit of
[UseData.Xml](https://github.com/radekm/UseData.Xml). Its distinguishing feature: after extraction
it can tell **which data in the XML was not used** (attributes, child elements, text).

Unlike UseData.Xml (which relies on `System.Xml`), this library also contains its own XML parser.
UseData.Xml's API is built on closures and `IDisposable`, so it can't be ported directly. A new API
was designed instead: [docs/en/api.md](docs/en/api.md).

## Scope (v1)

- The whole input is in memory as `[]const u8`, UTF-8 only (a UTF-8 BOM is allowed).
- A non-validating XML 1.0 parser that checks well-formedness:
  - XML declaration (version 1.0; encoding absent or UTF-8),
  - elements, attributes (duplicates are rejected), text, CDATA,
  - character references `&#…;` / `&#x…;` and the 5 predefined entities,
  - line-ending normalisation (`\r\n`, `\r` → `\n`) and attribute-value normalisation,
  - comments and processing instructions are skipped,
  - `<!DOCTYPE …>` is rejected,
  - mixed content (non-whitespace text next to child elements) is rejected.
- Namespaces are ignored: elements and attributes are matched by local name; `xmlns` and
  `xmlns:*` attributes are skipped. Two sibling elements (or two attributes of one element) with
  the same local name but different prefixes are an error.
- Extraction API: `attr`, `child`, `children`, `text` and their variants (`Opt`, `With`, `Alloc`),
  `ignoreAll`; detailed error information in `Diagnostics`.
- Reporting unused data after extraction (`Document.unused()`, `Document.expectAllUsed()`).
- Value parsers: strings, integers, floats, `bool`, enums, `Timestamp` (UTC) and user types.

## Non-goals (for now)

- Streaming input, encodings other than UTF-8.
- DTD, custom entities, validation (XSD).
- Namespace-aware matching.
- `decimal` (floats only for now).
- Declarative mapping to structs via comptime reflection (`decode(MyStruct, elem)`).
- Writing / serialising XML.

## Decisions

| Date       | Decision |
|------------|----------|
| 2026-11-23 | Input is fully in memory, UTF-8 only. |
| 2026-11-23 | Unused data is checked once, after extraction, by walking the tree (no `Dispose` equivalent). It can be reported (iterator) or turned into an error. |
| 2026-11-23 | Namespaces / prefixes are ignored like in UseData.Xml. |
| 2026-11-23 | No `decimal`; numbers with a fraction are parsed into floats. A UTC `Timestamp` type is part of the library. |
| 2026-11-23 | No comptime struct mapping in v1. |
| 2026-11-23 | Memory: the document's arena never leaves the library. Values without an allocator are borrowed (valid while the document and the input live). `...Alloc` variants copy / allocate with the caller's allocator; custom parsers that allocate get the caller's allocator. |
| 2026-11-23 | Integers: optional `+` / `-`, leading zeros allowed. Floats: plain decimal form only (no exponent, `inf`, `nan`). `bool`: `true` / `false`, case-sensitive. `Timestamp`: `Z` suffix only. |
| 2026-11-23 | `text*` on an element with child elements fails with `error.WrongCount`. |
| 2026-11-23 | Variants are separate functions (`attr`, `attrWith`, `attrAlloc`, …), not an options struct. |
| 2026-11-23 | Requested names that don't exist are remembered (a second request fails with `AlreadyUsed`); lookups by name may therefore return `OutOfMemory`. |
| 2026-11-23 | Only the `master` branch is used. |

## Milestones

- [x] **M0 — Project setup:** `AGENTS`, `PLAN`, `README` (EN + CS), `build.zig` skeleton.
- [x] **M1 — API design:** `docs/en/api.md` + `docs/cs/api.md`, approved by the owner.
- [x] **M2 — XML parser:** tokenizer + tree builder (iterative, no recursion per nesting level),
      line/column in error diagnostics, well-formedness tests (incl. invalid inputs from
      UseData.Xml tests).
- [x] **M3 — Element API:** lookups, usage tracking (each attribute / child name / text may be used
      once), `WrongCount` / `AlreadyUsed` errors, element path in `Diagnostics`.
- [ ] **M4 — Value parsers:** strings, ints, floats, bool, enums, `parseXml` hook, `Timestamp`.
- [ ] **M5 — Unused reporting:** `Document.unused()`, `Document.expectAllUsed()`, `ignoreAll`.
- [ ] **M6 — Port tests & example:** port all tests of UseData.Xml, add the M7 message example
      as a test and a simple benchmark (`zig build bench`).
- [x] **CI:** GitHub Actions (`mlugg/setup-zig`, Zig 0.17.1) runs `zig fmt --check` and the tests
      (Debug + ReleaseSafe) on Linux, macOS and Windows.
- [ ] **M7 — Polish:** documentation in `docs/en` + `docs/cs`, doc comments.

## Open questions

None at the moment.
