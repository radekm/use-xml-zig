# AGENTS.md — rules for contributors and AI agents

Czech version: [AGENTS.cs.md](AGENTS.cs.md).

Read this file and [PLAN.md](PLAN.md) before starting any work.

## Communication

- Talk to the project owner in **Czech**.
- When you are not sure about something, **ask the owner** instead of guessing.

## Languages

- Code, identifiers and code comments are in **English**.
- Documentation is written in **both English and Czech**:
  - `README.md` / `README.cs.md`, `PLAN.md` / `PLAN.cs.md`, `AGENTS.md` / `AGENTS.cs.md`,
  - `docs/en/*` / `docs/cs/*` (same file names in both directories).
- Both language versions must always say the same thing. Change them together in the same commit.

## Toolchain and dependencies

- Zig **0.17.1** exactly. Don't use features from other versions.
- Only the Zig standard library. **Don't add any dependency without the owner's permission.**
- Before committing, run `zig fmt --check .` and `zig build test`. Both must pass.

## Git

- Use only the `master` branch. Don't create other branches.
- Keep commits small and focused. Write commit messages in English in the imperative mood
  ("Add attribute lookup").

## Design rules

- The goal of the library is to extract data from XML and to **detect data that was not used**
  (see [docs/en/api.md](docs/en/api.md)). Every feature must keep this property.
- Public API changes must first be reflected in `docs/en/api.md` and `docs/cs/api.md`
  and approved by the owner.
- Memory:
  - The document's internal arena never leaves the library. Values returned without an allocator
    are *borrowed*: they are valid only while the document and the input buffer are alive.
  - Values that must outlive the document are allocated with an allocator passed in by the caller
    (`...Alloc` functions).
  - No hidden global state. No allocation outside the allocators the caller passed in.
- Invalid input must never cause a panic, undefined behaviour or a stack overflow. Return an error
  and fill in `Diagnostics`. In particular, parsing must not recurse once per nesting level of
  the input (use an explicit stack or a configurable depth limit).
- Prefer simple, readable code over clever code. Optimise only with a benchmark.

## Tests

- Every feature and every bug fix comes with tests.
- Tests live next to the code (`test` blocks) or in `tests/`. `zig build test` runs all of them.

## Plan maintenance

- When a milestone or task in `PLAN.md` is finished, tick it off (in both language versions).
- Record new decisions made with the owner in the "Decisions" section of `PLAN.md`.
