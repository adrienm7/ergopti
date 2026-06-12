# Ergopti+ — Cross-driver mutualization TODO

> **Goal**: maximise shared code between the existing drivers so a fix/feature on
> one propagates to the others, and eliminate every hardcoded/fallback value in
> driver code (common values live in `shared/`, a missing value **fails fast**).
> **Order of work**: finish mutualizing the **two existing drivers (AHK + macOS)
> first**, even where it is complex. **Linux comes strictly last.**

This file is the hand-off for a fresh session. Read it top to bottom before
starting; it captures the plan **and** the hard-won gotchas.

---

## 0. Where things stand

A first wave of 13 fixes already landed on `dev` (see `git log`). In short:

- `shared/ports/contracts.json` is now the **single source** for the 20 port
  contracts, projected from `shared/ports/*.spec.js` (`npm run codegen:contracts`)
  and enforced by `tools/test/test-port-compliance.cjs` (freshness gate + AHK
  `ADAPTER_*` parity) and the macOS/AHK presence meta-tests (now incl. a Linux arm).
- Every hardcoded LLM default/fallback mirror was deleted and replaced with
  **fail-fast** reads of `shared/llm/defaults.json` / `inference.json`:
  AHK `_LLM_DEFAULTS_FALLBACK` + `LLM_COMMON_FALLBACK`, macOS `_BASE_DEFAULTS`,
  `profiles.lua` `or 4/20`. Locked by `tools/test/test-no-fallback-literals.cjs`.
- macOS Ollama port is configurable from one source (`get_base_url()`); MLX boot
  sweep no longer falls back to the forbidden port 8080.
- Linux phase 0: fail-fast terminators, installer paths repaired, metrics timings
  reconciled to the canonical values.

### How to run the suites (all must stay green)

```bash
# from repo root, with node_modules available (see gotcha G1)
node ./tools/test/test-port-compliance.cjs        # 14 checks
node ./tools/test/test-no-fallbacks                # via: npm run test:no-fallbacks
( cd static/ergopti_plus/linux && lua tests/run.lua )   # Linux Lua suite
( cd static/ergopti_plus/macos && lua tests/run.lua )   # macOS Lua suite (~1500 tests)
# AHK suite (Windows): run windows/tests/run_all.ahk with AutoHotkey64.exe,
#   then read the TAP report at %TEMP%\ergopti_test_results.txt (NOT stdout).
npm run lint:conventions                           # banners / spacing / encoding
```

Baseline at hand-off: Node 14/14 + 6/6 · Linux 37/37 · macOS 1509/0 · AHK 1305/0.

---

## PRIORITY 1 — Mutualize the two existing drivers (AHK ↔ macOS)

Do these first, top to bottom (roughly increasing risk).

### A1. Lift `parser.lua` into `shared/lua/llm/parser.lua`  *(M, fort levier)*

The LLM output parser (`macos/modules/llm/parser.lua`, ~820 lines) is ~95% pure
(2-tier semantic token-diff, French typography, NFD→NFC, filler cleanup,
TAIL_CORRECTED / NEXT_WORDS extraction, gray/green/orange chunk classification).
The only OS coupling is two `hs.settings.get(min/max_words)` reads.

- Move the two settings reads to **caller-supplied params** (the prediction
  engine already knows min/max words), then move the body to
  `shared/lua/llm/parser.lua`; macOS `parser.lua` becomes a thin
  `return require("llm.parser")` shim (like `lib/text_utils.lua`).
- Author the missing **TokenParser golden corpus** from
  `shared/domain/TokenParser.js` (currently consumed by zero driver) at
  `shared/tests/corpus/llm/parser_test_vectors.json`, and assert macOS + AHK
  (`windows/modules/llm/parser.ahk`) both pass it row-by-row.
- **Why**: pins the only completely-unguarded LLM domain, and the future Linux
  LLM module gets parsing for free.
- **Risk**: medium — keep the macOS `test_parser*.lua` suites green; the shim must
  re-export the full surface. Watch the `hs.*` count tripwire (gotcha G2): the
  shared file must contain **zero** `hs.` (even in comments).

### A2. Resolve the orphaned macOS codegen  *(L, the AHK-vs-macOS divergence)*

`macos/_generated/{expander,registry,shortcuts_bindings,features_manifest}.lua`
are emitted by real generators (`tools/codegen/codegen-*-hs.cjs`,
`build-features-manifest.js`) but **required by zero macOS module** — macOS runs a
hand-written twin while Windows runs the generated truth (verified:
`grep -rn "_generated" macos/ --include=*.lua | grep require` is empty). Two
implementations of the same contract = guaranteed drift.

Decide **per artifact**:
- `features_manifest.lua`: build a `macos/lib/manifest_reader.lua` mirroring
  `windows/lib/manifest_reader.ahk` so macOS reads defaults from the generated
  manifest instead of hand-written `DEFAULT_STATE` tables. **This is the single
  biggest macOS-specific lever** — Windows already has its reader, macOS doesn't.
- `expander.lua` / `registry.lua` / `shortcuts_bindings.lua`: either wire macOS to
  consume the generated tables behind the hand-written `hs.*` glue, **or** accept
  the hand-written modules as canonical and **stop emitting** the dead Lua (the
  no-op `codegen-prompt-builder-hs.cjs` is the precedent for "macOS uses Lua
  directly" being a legitimate documented choice). Either way: no generator should
  emit output nothing consumes.
- **Risk**: high — `expander`/`registry` carry HS-specific glue (i18n,
  `hs.settings`, `hs.eventtap`) intertwined with pure logic. Gate behind the
  Expander/Registry golden corpora before retiring any hand-written twin.

### A3. Wire both drivers to `shared/timings/constants.toml`  *(L, needs care)*

`shared/timings/constants.toml` self-documents ~80 constants (and even names the
exact AHK + HS constant duplicating each), but today only a few UI sites read it
(WPM widget, `tooltip/config.lua`, `ui_style.ahk`). keylogger / LLM / gestures /
tap-hold each hardcode their timings independently in 2-3 drivers.

- Extend the **existing** working reader (the WPM widget reads it via
  `toml_codec` on HS and `TOML_Read` on AHK; `ui_style.ahk` is the fail-fast
  reference) into `keylogger/init.lua`, `llm/prediction_engine.lua`,
  `gestures/engine.lua`, `windows/.../keylogger_walker.ahk`,
  `tap_holds/constants.ahk`, … reading at boot, then **delete** the local literals.
- **Reconcile only true divergences** — do NOT blindly "fix" values that are
  actually different concepts. Verified non-issue: `tooltip.llm_display_ttl_ms`
  (12000 = tooltip visible duration) is **not** the same as a request timeout.
  Verify each constant's meaning before changing it.
- **Risk**: medium-high, and **needs live validation** — reading TOML at boot
  introduces an ordering dependency (the TOML must load before the module that
  needs it). Pair every wiring change with a `require_key`-style fail-fast so a
  too-early read errors loudly instead of returning `nil`. Test both suites; then
  the maintainer must smoke-test on real hardware.

### A4. Shared hotstring colors / delays  *(S-M, watch boot order)*

`GLOBAL_DEFAULT_COLOR` `#1e88e5`, `personal` `#6e6e73`, `GLOBAL_DEFAULT_DELAY`
`0.75` are hardcoded identically in `macos/modules/hotstrings_config.lua` and
`windows/lib/hotstrings/hotstrings_config.ahk` (each claiming to be "the single
source"). Add a `[hotstrings.colors]` / `[hotstrings.delays]` block to `shared/`
(e.g. `shared/tooltip/constants.toml` or new `shared/hotstrings/colors.toml`) read
by both like they already read `accent_colors`.

- Also: AHK `#AD61FF` in `hotstrings_config.ahk` re-types the canonical
  `ai_loading_hex` already loaded as `UI_AI_LOADING_HEX`.
  **Gotcha**: `UI_AI_LOADING_HEX` is `""` until `UiStyleLoad()` runs at boot, so a
  top-level `Map(...)` reference would capture the empty value. Either build the
  `COLORS` map lazily (in a function called after boot) or read the shared TOML at
  resolve time. Confirm the boot order before wiring.

### A5. Thread the PromptBuilder `max_tokens` through the backends  *(M)*

The shared PromptBuilder computes `max_tokens = max(15, max_words*6+10)` (default
150) and macOS honours it, but AHK `api_ollama.ahk` re-derives
`num_predict := Max(24, Min(96, mw*4))` and `api_remote.ahk` hardcodes
`max_tokens:256` in three provider branches; macOS `api_mlx.lua` also clamps
`min(0.60,…)+0.10` diverging from `inference.json`.

- Thread `params["max_tokens"]` from `pb.Build()` through to every backend payload
  builder; delete the inline re-derivations. **First confirm** these are real
  divergences and not intentional per-backend budgets (Ollama `num_predict` ≠
  prompt budget;
  remote providers may want a larger cap) — **needs a behavioural decision**.
- Add a diversity-temp golden corpus covering the bracket boundaries.

### A6. Tooling / enforcement  *(S-M, low runtime risk)*

- **Codegen freshness gate** (extends A2's spirit): a meta-test that re-runs every
  `tools/codegen/*` generator into a temp dir and diffs against the committed
  `_generated/*` and `contracts.json`, so a hand-edited generated artifact fails
  CI. (The `contracts.json` half already exists in `test-port-compliance.cjs`.)
- **`config.schema.json` validation**: wire a JSON-schema validation step over the
  generated `config_template.toml` / user `config.toml`
  (`shared/config_schema/config.schema.json` is consumed by zero tests today).
  Note: there is no JSON-schema validator in `node_modules` yet — add one or
  hand-roll a minimal check.
- **Flip the AHK shared/-purity meta-test from warn-only to hard-fail**
  (`windows/tests/meta/test_port_adapter_coverage.ahk`, §4). The macOS twin
  already hard-fails. **First** audit the current warn-only violations (pre-existing
  shared webview UI files that reference `hs.` for the bridge) and confirm
  `shared/` JS is clean, else this turns the suite red.
- **Tooltip sentinels** (fail-fast sweep remainder): the dead `0.2`/`0.05`
  tooltip-timeout initializers in `windows/lib/tooltip.ahk` and
  `macos/ui/tooltip/dequeue.lua` should initialise to a sentinel (`0`) so a missing
  shared load is detected loudly rather than masked.

---

## PRIORITY 2 — Linux (do this **strictly last**)

Only start after Priority 1 is substantially done. Most of it is write-heavy code
that can be authored on Windows but **only validated on a Linux box** (the
maintainer's workflow: code here, test/debug on Linux).

### L1. Harvest the already-loadable `shared/lua` modules

- Add an **encoder** to `shared/lua/json.lua` (it is **decode-only** today —
  `M.decode` exists, no `M.encode`). Then refactor `linux/adapters/storage.lua`
  `_encode`/`_decode` to use the shared JSON (the current minimal one silently
  corrupts nested/unicode values). Add a round-trip test.
- Replace `linux/modules/hotstrings/loader.lua`'s bespoke TOML parser with
  `require("toml_codec")`, and `input_reader.lua`'s keycode tables with the shared
  `keycodes` data. All already on the Linux `package.path`.
- Add `linux/modules/dynamic_hotstrings` consuming
  `shared/lua/dynamic_hotstrings/init.lua` (already used by macOS).

### L2. Async backbone — `luv` TimerScheduler + HttpClient

Vendor `lua-luv` under `linux/vendor/`; implement `TimerScheduler` (after/every/
cancel/cancelAll/activeCount) and `HttpClient` (async POST) per their `spec.js`
contracts, integrating the event loop with the blocking evdev read loop.

### L3. KeyboardHook (evdev/uinput) + shared keymap expander

Promote `input_reader`'s evdev path into the `KeyboardHook` adapter with
`EVIOCGRAB`/uinput intercept; consume the shared expander (lifted in A2) through
`KeyboardHook` + `TextSender`.

### L4. LLM module

`linux/modules/llm` consuming the shared `prompt_builder` + `profile_selector`
(already on path) + the newly-shared `parser.lua` (A1) + an Ollama HttpClient call.
Convert the two SKIP marks in `linux/tests/.../test_corpus_cross_driver.lua`
(llm/parser, prompt_builder) into real assertions as the acceptance gate.

### L5. UI surfaces — TooltipRenderer (X11/cairo) + TrayMenu (D-Bus)

X11 override-redirect/cairo (or wlr-layer-shell) tooltip honouring the shared
`tooltip` draw-call schema and `timings/constants.toml` TTLs; a D-Bus
StatusNotifierItem tray. Expand the Linux compliance test from 9 to all 20 ports.

---

## Gotchas / environment notes (READ THESE — they cost real time)

- **G1 — node_modules in the worktree**: the worktree shares `.git` but not
  ignored files, so `node_modules` is absent. Create a junction once:
  `cmd /c mklink /J node_modules ..\..\..\node_modules` (from the worktree root),
  or `npm install`. Needed for `smol-toml`/`fast-check` and the husky pre-commit hook.
- **G2 — macOS `hs.*` count tripwire**: `macos/tests/meta/test_port_adapter_coverage.lua`
  fails if the count of `hs.` occurrences in **modules+lib** rises above its baseline
  (currently 900). **It counts comments too.** When adding code that touches OS
  settings, route it through a **port adapter** (`adapters/storage.lua` `Storage.get`
  — adapters are excluded from the count) instead of `hs.settings` directly, and
  avoid the literal `hs.` in comments (write "the OS settings store").
- **G3 — AHK encoding**: `.ahk` files must be **UTF-8 BOM + CRLF** or the parser
  silently aborts mid-file (tests vanish with no error). Use the Edit tool (never
  `cat >>`); for new files the pre-commit hook auto-fixes BOM/CRLF, but convert
  before running the suite: PowerShell
  `[IO.File]::WriteAllText($p, ($c -replace "`r`n","`n" -replace "`n","`r`n"), (New-Object Text.UTF8Encoding $true))`.
  Inside AHK double-quoted strings the escape for `"` is `` `" `` (backtick-quote),
  not `""`.
- **G4 — banners**: run `npm run fix:all` (banners + spacing + unbalanced) before
  every commit; the pre-commit hook rejects banner/blank-line violations. Major
  sections = 5 blank lines + 7 `=` each side; subsections = 3 blank lines + 5 `=`.
- **G5 — generated JSON line endings**: `contracts.json` has no explicit
  `.gitattributes` eol rule, so it is checked out CRLF on Windows while codegen
  writes LF. Any freshness gate comparing generated vs committed must
  **normalise line endings** first (see `test-port-compliance.cjs`).
- **G6 — circular requires**: `init.lua` requires the api_* modules, so an api_*
  module that needs `DEFAULT_STATE` must `pcall(require, "modules.llm.init")`
  **lazily inside the function**, never at module load (see `api_ollama.lua`
  `resolve_ollama_port` / `profiles.lua`).
- **G7 — path resolution in tests**: resolve shared files **relative to the source
  file** via `debug.getinfo(1, "S").source` (deterministic in prod + headless
  tests), not via `hs.configdir` (see `init.lua` `load_shared_defaults`).
- **G8 — running tests writes artifacts**: the AHK suite rewrites
  `windows/tests/test_config.ini`; `git checkout --` it before committing.

---

## Suggested commit cadence

One logical change per commit, conventional-commit messages in English, **every
bug fix ships with a regression test that fails before / passes after**, no
`Co-Authored-By` trailers. Keep `main`/`dev` linear. Don't push without explicit
ask.
