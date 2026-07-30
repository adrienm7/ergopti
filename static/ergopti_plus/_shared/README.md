# `_shared/` — cross-driver shared tree

Everything here is consumed by **more than one** driver (`windows/` AHK,
`macos/` Hammerspoon/Lua, `linux/` Lua/kanata). The single most common point of
confusion is the difference between `lua/` and `modules/` — they look like they
overlap (both have `llm/`, `logger/`) but they are **different kinds of thing**.
This file is the invariant.

## Folder boundary (the rule)

| Folder | Contains | Consumed by | Example |
|---|---|---|---|
| **`lua/`** | **Runtime Lua code** — modules `require`d at runtime by the Lua drivers. | macOS + Linux Lua drivers, via `require("…")`. | `lua/hotstring_engine/`, `lua/logger/init.lua`, `lua/toml_codec/`, `lua/keymap/terminators_catalogue.lua` |
| **`modules/<sub>/`** | **Data + specs + scripts** — JSON/TOML data, JS `*.spec.js`, `SPEC.md`, install/validation scripts (`.ps1`/`.sh`/`.py`). **No runtime `.lua`.** | Every driver (parsed as data), plus the JS test/codegen tooling. | `modules/features/manifest.toml`, `modules/menu/menu_manifest.json`, `modules/llm/*.json` + `install/*.{ps1,sh}`, `modules/logger/SPEC.md` + `test_vectors.json` |
| **`core/`** | **JS contracts** — the hexagonal port/domain specs (`ports/*.spec.js`, `domain/*.spec.js`), `contracts.json`, and `config_schema/`. The contract *is* the cross-driver test. | JS test suite (`test:port-compliance`, `test:config-schema`, …). | `core/ports/contracts.json`, `core/config_schema/config.schema.json` |
| **`data/`** | **Pure data** — no code. | All drivers + the website. | `data/locales/*.json`, `data/keycodes/azerty.json`, `data/db/schema.sql` |
| **`ui/`** | **Shared webview frontends** — host-agnostic `index.html`/`script.js`/`style.css` rendered by WebView2 (Windows) and WKWebView (macOS). | Windows + macOS UI hosts. | `ui/model_browser/`, `ui/onboarding/`, `ui/metrics_typing/` |
| **`tap_hold/`** | Shared tap-hold defaults TOML (FEAT A single source). | AHK boot loader + macOS Karabiner generator. | `tap_hold/defaults.toml` |
| **`tests/`** | Cross-driver shared **corpora & fixtures** — run identically by every driver's suite to certify parity. | AHK + Lua test suites. | `tests/corpus/toml/fuzz_corpus.json`, `tests/corpus/llm/` |

## Why two homes for `llm/` and `logger/`

There is **no overlap**, only a naming coincidence:

- `_shared/lua/llm/` and `_shared/lua/logger/` hold the **runtime Lua** (`parser.lua`,
  `prompt_builder.lua`, `logger/init.lua`) that the Lua drivers `require`.
- `_shared/modules/llm/` and `_shared/modules/logger/` hold **data + specs +
  scripts** (`defaults.json`, model install scripts, `SPEC.md`, `test_vectors.json`)
  — zero `.lua` files.

## How the AHK driver gets shared logic — no transpilation exists

**Nothing in this repository is transpiled.** Every generator under `tools/codegen/`
and `tools/build/` emits **data** in the target language; none translates Lua to AHK.
Two of them additionally carry hand-written AHK inside a JS template string, which
is what creates the illusion of transpilation — and one of those never even opens
the Lua file it names as its source.

The prior claim that "AHK cannot read the shared data" is also false:
`windows/lib/json.ahk` and `windows/lib/toml/` exist, and the AHK driver already
reads `menu_manifest.json`, `priority.json`, the 21 locale JSONs, every hotstrings
TOML and `profiles.json` **at runtime**. Codegen here is therefore never about
capability — only about boot cost and pre-resolution.

So a behaviour shared with the AHK driver reaches it in exactly one of two ways:

1. **Generated data** — the shared source is collapsed into a pre-resolved literal
   (`_generated/features_manifest.ahk`, `_generated/terminators.ahk`).
2. **A hand-written twin pinned by a shared vector corpus** — `_shared/tests/corpus/`
   is then the contract, and a divergence fails CI on both drivers.

A third hand-maintained copy with no corpus between it and its twin is not allowed.

## Invariants

> 1. No runtime `.lua` belongs under `modules/`; no data-only catalogue belongs under
>    `lua/` (the `.lua` files in `lua/` are all executable modules, e.g. `lua/json.lua`).
> 2. **Generate only** when the driver cannot read the source, or when reading it at
>    boot would cost measurable milliseconds. Otherwise read the data at runtime — and
>    when you do generate, generate *data*, never *logic*.
> 3. No node under `_shared/` may be named after a platform. Two current violations
>    (`lua/linux/`, `lua/llm/linux_bridge.lua`) are tracked in
>    [`docs/PLAN_SIMPLIFICATION.md`](../../../docs/PLAN_SIMPLIFICATION.md) §5.5.
> 4. `_shared/lua/` is **not** automatically shared: measured, only 37.7 % of its
>    8 473 lines are required in production by both Lua drivers. Check the real
>    consumers before assuming an edit reaches macOS *and* Linux.
>
> Keep new files on the correct side of these lines.
