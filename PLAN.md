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
  `ignoreAll`; detailed error information in `Diagnostics` (with a buffer from the caller).
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
| 2026-11-23 | `text*` on an element with child elements fails with `error.WrongCount` (now `error.HasChildren`, see 2026-11-24). |
| 2026-11-23 | Variants are separate functions (`attr`, `attrWith`, `attrAlloc`, …), not an options struct. |
| 2026-11-23 | Requested names that don't exist are remembered (a second request fails with `AlreadyUsed`); lookups by name may therefore return `OutOfMemory`. |
| 2026-11-23 | Extraction errors are recorded by the document (`doc.diagnostics()`), so it is obvious they are invalid after `doc.deinit()`; whoever parses reports them before that. XML syntax errors go to a separate `ParseDiagnostics` (no pointers) passed in `Options`. (Replaced on 2026-11-24.) |
| 2026-11-23 | License: zlib. |
| 2026-11-24 | Diagnostics are passed in `Options.diagnostics` and copy the description into a buffer from the caller (`Diagnostics.init(&buf)`), so they stay valid after `doc.deinit()`. One `Diagnostics` type for syntax and extraction errors (`ParseDiagnostics` and `doc.diagnostics()` are removed); long names/values are shortened, a description that doesn't fit is cut (`truncated`). Replaces the decision of 2026-11-23 about diagnostics stored in the document. |
| 2026-11-24 | `Diagnostics` also record `error.OutOfMemory`, so it describes every error returned by the extraction functions. Kind `document_out_of_memory` = the document's internal memory, `value_out_of_memory` = producing the value (allocator of `...Alloc`, custom parser, `parseXmlAlloc`). |
| 2026-11-24 | `error.WrongCount` is split into `Missing`, `TooMany` and `HasChildren`. Every extraction function returns only the errors that can happen (`ChildError`, `AttrLookupError`, …); `use_xml.Error` is the union of all. |
| 2026-11-24 | A custom parser in `...With` functions is a function or a value (or pointer) with a method `parse`; the value carries run-time state. No separate context functions. |
| 2026-11-24 | `...Alloc` functions use only the `parseXmlAlloc` hook; a type with only `parseXml` can't be used with them (compile error), so an owned result never borrows the document. |
| 2026-11-24 | After the review: a custom parser may also be a pointer to a function; a `parseXml` / `parseXmlAlloc` hook may return a value without an error. Diagnostics shorten long element paths from the start (`/…/b[0]`), replace invalid UTF-8 in names passed in by U+FFFD, and `"{f}"` prints the kind when nothing of the description fits into the buffer. |
| 2026-11-24 | Errors of the value in `attr*` / `text*` without `With` depend on `T` (e.g. `text([]const u8)` can't fail with `InvalidValue` or `OutOfMemory`). The constants `AttrError`, `AttrOptError`, `TextError` and `ValueError` are removed; the rule is a table in `api.md`. |
| 2026-11-24 | Writing into `Diagnostics` (`reset`, `record`, `recordInvalidXml`, `lineColumn`) lives in the internal `recording.zig`, which `root.zig` doesn't export. The public API of `Diagnostics` is only `init`, `message`, `format` and the fields; `reset` is not public. |
| 2026-11-24 | The `...With` variants stay, although strings from `attr` / `text` are already decoded and could be parsed afterwards: they exist so that a parser's error is recorded in `Diagnostics` with the path, the name and the input. |
| 2026-11-23 | Only the `master` branch is used. |
| 2026-11-25 | Names are looked up in hash maps (`std.StringArrayHashMapUnmanaged`): an element has `attrs` and `child_groups`; used names are kept in the sets `attrs_used` and `child_groups_used` (also for names that don't exist; the separate list of missing names is removed). So lookups allocate in the document's arena. The unused `prefix` was removed from elements. |
| 2026-11-25 | `visited` is replaced by `all_used`: `ignoreAll` only sets it (no allocation, returns `void`); afterwards every request on the element fails with `AlreadyUsed`, even for names that don't exist. The unused report checks an element if no ancestor (or the element) is ignored and every name on the path from the root was requested; so the children of a group that failed with `TooMany` are checked too. |
| 2026-11-25 | Elements don't store their index among siblings with the same name; `index()` searches for the element in its parent's group (linear in the size of the group). |
| 2026-11-25 | Bug fix (review): `recording.record` copies the selector (a name passed in by the user) into a stack buffer before it overwrites `Diagnostics.buf`. Before, a name pointing into that buffer (e.g. a part of `diag.message()`) made the copy overlap: a panic "@memcpy arguments alias" in Debug / ReleaseSafe, undefined behaviour in ReleaseFast / ReleaseSmall. The copy must stay; regression tests "selector overlapping the diagnostics buffer" in `recording.zig` and `elem_test.zig`. |
| 2026-11-25 | Documentation (review): different documents may be used from different threads, but extraction functions allocate in the document's arena from the allocator passed to `Document.parse`; documents sharing an allocator across threads therefore need a thread-safe allocator (`api.md`, `guide.md`, doc comments of `Document`). |

## Milestones

- [x] **M0 — Project setup:** `AGENTS`, `PLAN`, `README` (EN + CS), `build.zig` skeleton.
- [x] **M1 — API design:** `docs/en/api.md` + `docs/cs/api.md`, approved by the owner.
- [x] **M2 — XML parser:** tokenizer + tree builder (iterative, no recursion per nesting level),
      line/column in error diagnostics, well-formedness tests (incl. invalid inputs from
      UseData.Xml tests).
- [x] **M3 — Element API:** lookups, usage tracking (each attribute / child name / text may be used
      once), `WrongCount` / `AlreadyUsed` errors, element path in `Diagnostics`.
- [x] **M4 — Value parsers:** strings, ints, floats, bool, enums, `parseXml` hook, `Timestamp`.
- [x] **M5 — Unused reporting:** `Document.unused()`, `Document.expectAllUsed()`, `ignoreAll`.
- [x] **M6 — Port tests & example:** port all tests of UseData.Xml, add the M7 message example
      as a test and a simple benchmark (`zig build bench`).
- [x] **CI:** GitHub Actions (`mlugg/setup-zig`, Zig 0.17.1) runs `zig fmt --check` and the tests
      (Debug + ReleaseSafe) on Linux, macOS and Windows.
- [x] **M7 — Polish:** guide in `docs/en` + `docs/cs` (code tested in `examples/guide`), doc comments,
      `zig build docs`.

## Open questions

None at the moment.
