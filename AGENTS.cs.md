# AGENTS.cs.md — pravidla pro přispěvatele a AI agenty

Anglická verze: [AGENTS.md](AGENTS.md).

Než začneš cokoli dělat, přečti si tento soubor a [PLAN.cs.md](PLAN.cs.md).

## Komunikace

- S vlastníkem projektu komunikuj **česky**.
- Když si něčím nejsi jistý, **zeptej se vlastníka** a nehádej.

## Jazyky

- Kód, identifikátory a komentáře v kódu jsou **anglicky**.
- Dokumentace se píše **anglicky i česky**:
  - `README.md` / `README.cs.md`, `PLAN.md` / `PLAN.cs.md`, `AGENTS.md` / `AGENTS.cs.md`,
  - `docs/en/*` / `docs/cs/*` (stejné názvy souborů v obou adresářích).
- Obě jazykové verze musí vždy říkat totéž. Měň je společně ve stejném commitu.

## Nástroje a závislosti

- Přesně Zig **0.17.1**. Nepoužívej vlastnosti jiných verzí.
- Jen standardní knihovna Zigu. **Bez svolení vlastníka nepřidávej žádnou závislost.**
- Před commitem spusť `zig fmt --check .` a `zig build test`. Obojí musí projít.

## Git

- Používej pouze větev `master`. Jiné větve nezakládej.
- Commity drž malé a zaměřené na jednu věc. Commit zprávy piš anglicky v rozkazovacím způsobu
  („Add attribute lookup“).

## Pravidla návrhu

- Cílem knihovny je vytáhnout data z XML a **odhalit data, která nebyla použita**
  (viz [docs/cs/api.md](docs/cs/api.md)). Každá funkce musí tuto vlastnost zachovat.
- Změny veřejného API se musí nejdřív promítnout do `docs/en/api.md` a `docs/cs/api.md`
  a schválit je vlastník.
- Paměť:
  - Interní arena dokumentu nikdy neopouští knihovnu. Hodnoty vrácené bez alokátoru jsou
    *vypůjčené*: platí jen dokud žije dokument a vstupní buffer.
  - Hodnoty, které mají přežít dokument, se alokují alokátorem, který předá volající
    (funkce `...Alloc`).
  - Žádný skrytý globální stav. Žádné alokace mimo alokátory předané volajícím.
- Nevalidní vstup nikdy nesmí způsobit panic, nedefinované chování ani přetečení zásobníku.
  Vrať chybu a vyplň `Diagnostics`. Parsování hlavně nesmí rekurzivně volat funkci pro každou úroveň
  zanoření ve vstupu (použij explicitní zásobník nebo nastavitelný limit hloubky).
- Preferuj jednoduchý a čitelný kód před chytrým. Optimalizuj jen na základě benchmarku.

## Testy

- Každá funkce i každá oprava chyby přichází s testy.
- Testy jsou vedle kódu (bloky `test`) nebo v `tests/`. `zig build test` spustí všechny.

## Údržba plánu

- Když je milník nebo úkol v `PLAN.md` hotový, odškrtni ho (v obou jazykových verzích).
- Nová rozhodnutí dohodnutá s vlastníkem zapiš do sekce „Rozhodnutí“ v `PLAN.cs.md`
  (a „Decisions“ v `PLAN.md`).
