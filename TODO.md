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

Baseline at hand-off: Node 14/14 + 6/6 · Linux 37/37 · macOS 1531/0 · AHK 1343/0.

### Latest session (runtime perf + hotstring collision PRIORITY)

Landed on `dev` this session (newest last):

- **Runtime perf (Windows/AHK)** — magic-key keystroke `OnChar` went 177 ms → 5.4 ms:
  - `673112c36` perf(hotstrings): index star triggers by string — `HSE_FindMatchAtEnd`
    star path now probes the buffer's own suffixes against `HSE_StarByTriggerCI/CS`
    (O(buffer) instead of scanning the ~2100-entry magic-key bucket). FeedChar 21 ms → <1 ms.
  - `0eb6d4cab` perf(hotstrings): `_PrefixCancelRender()` kills the pending debounce
    preview before a fire, so it can't paint reentrantly inside the send (~35 ms saved).
  - Tooltip render optims (measure-font cache + border band-scan), menu/LLM blocking
    `LLM_OllamaListModels` probe gated on deps-ready (boot 7 s → 2 s), boot bisection mark.
  - `e267fc4f1` perf(hotstrings): personal sections loaded ONCE at boot (the inline
    `#InputLevel 0` loop was a pre-HSE leftover double-registering ~263 specs).

- **Hotstring collision PRIORITY — Windows side DONE** (cascade: individual > section >
  file > source-default; source defaults common 10 / package 30 / personal 50):
  - `04e4331f8` feat: engine tie-break `length → priority → Seq`. New `Spec.Priority`,
    helpers `_HSE_Beats` / `_HSE_EndCharBeats` (the latter preserves the star-wins-tie
    rule), `HSE_MappingsForTail` sort updated. Inert at the default (ties fall to Seq).
  - `4d5e56b43` feat: source defaults `HSE_PRIORITY_COMMON/PACKAGE/PERSONAL` (10/30/50)
    threaded `Options → _MakeHotstringMeta → HSE_Register`; generated/common loaders land
    at 10 with no regen.
  - `3449822f8` feat: per-hotstring `priority = N` key in the TOML inline table
    (`_ParseEntryPriority`, guarded against matching inside the output string).
  - `6c9d935bb` feat: section/category priority via the `HotstringsResolve` override
    cascade (same system as delay/color) + `_HSE_SourcePriority` fallback.

**PRIORITY parity — macOS + cross-driver mutualization: DONE this session.**

1. **macOS priority engine — DONE** (`c7c297852`, `20ca7e45f`): `priority` field on the
   Mapping struct, tie-break inserted into `sort_mappings()` right after length
   (`length → priority → is_word → group_order → seq`), `source_priority(category)`
   (personal 50 / `ext.` 30 / common 10) + `resolve_priority()` cascade in `M.add`/
   `load_toml`. AHK engine tests mirrored in the Lua suite.
2. **macOS priority cascade — DONE**: individual > section > file > source resolved in the
   Lua loader (mirrors delay/color), `[_meta] priority` / `section_priorities`.
3. **Shared corpus — DONE** (`dc322e3da`): `collision_vectors` added to
   `shared/tests/corpus/hotstrings/vectors.json`; BOTH drivers run them through their REAL
   decision logic (AHK `HSE_Register`+`HSE_FeedChar`, Lua `M.add`+`sort_mappings`+tail
   bucket), locking `length > priority > first-registered` identically.
4. **Single source of truth — DONE** (`a80fc6723`): `shared/hotstrings/priority.json` +
   `tools/test/test-priority-parity.cjs` CI gate holds AHK `HSE_PRIORITY_*` and Lua
   `PRIORITY_*` equal to the JSON; can't silently diverge.
5. **macOS source-naming + dedup correctness — DONE** (`eebf9c9ef`, `2a1d4b7a9`):
   `personal_ext_*` groups now score the package tier (30) like Windows `ext.*` (were
   silently 10); and the registry dedup key now includes the owning group, so a personal
   hotstring sharing a common trigger is no longer overwritten in place — it competes and
   wins by priority (the feature's headline case, previously a no-op on macOS).

**Section-priority editing in the delays/colors window — FULL cross-driver, DONE this session.**

The delays/colors window (Windows `hotstrings_config_window.ahk`, macOS
`ui/hotstrings_config_window/*`) now edits per-category and per-section collision
**priority** next to delay/color/tooltip, writing to the SHARED override file
(`hotstrings_config.toml`) — and both engines actually consume it. Landed (uncommitted
as of this note — awaiting live validation):

1. **AHK data layer** (`lib/hotstrings/hotstrings_config.ahk`): `HotstringsSetOverride` /
   `HotstringsClearOverride` accept `priority`; `HotstringsResolveExt` exposes it (package
   tier 30 default). `_ParseOverrides` / `_SaveOverrides` / `HotstringsResolve` already
   carried it from the section-cascade commit.
2. **AHK TOML defaults** (`lib/toml/toml_loader.ahk`): `ParseTomlGroupConfig` now parses
   `[_meta] priority` + `[_meta.sections.x] priority` (the package-shipped default layer).
3. **AHK Phase 3 — SOLVED without codegen** (`lib/hotstrings/hotstring_engine.ahk`): new
   `_HSE_ResolveRegistrationPriority(Category, Section)`; when a caller passes no explicit
   `Priority`, the factories resolve the override cascade via `HotstringsResolve`. The
   generated loaders carry Category/Section but no Priority, so the ~3000 bundled hotstrings
   now honour a user's per-section override (were stuck at the common tier 10). No codegen
   change needed — DRY and auto-covers future generated categories.
   ⚠ **Crash fixed (regression test added)**: the first cut passed the unset `options`
   variable into the helper → AHK v2 `UnsetError` at the call site crashed
   `RegisterAllHotstrings` at boot. The `IsSet(options)` guard MUST live at the caller; the
   helper takes Category/Section only. Pinned by `test_hotstring_engine_main.ahk`
   "factories register with no options".
4. **AHK window UI**: Priority row (Edit + UpDown 0-100 + default hint + ↺ reset) mirroring
   the delay row; full read/defaults/override/reset wiring; `_HCW_TomlValue` formats priority
   as a bare integer; `_HCW_FallbackPriority` shows the source tier.
5. **macOS shared reader** (`shared/lua/toml_codec/reader.lua`): parses `[_meta] priority`
   (file) + per-section `[_meta.sections.x] priority` — these were never parsed, so the
   macOS engine's section/file-priority path was dormant.
6. **macOS data layer** (`macos/modules/hotstrings_config.lua`): priority through
   parse/serialize/set/clear/get_user_override/get_toml_defaults (bare integer).
7. **macOS engine** (`macos/modules/keymap/registry.lua` `load_toml`): now consults the
   shared override file (`hotstrings_config.get_user_override`) + reader meta priority,
   flattened to match AHK's order (user-section > user-file > meta-section > meta-file >
   source). Replaced the dead `data.meta.section_priorities` read.
8. **macOS window UI** (`init.lua` + `index.html` + `script.js` + `style.css`): Priority
   field + `set_priority`/`clear_priority` for common/personal/ext; source default read from
   `keymap.source_priority` (no 4th hardcoded copy of 10/30/50).
9. **Locales**: `hs_config.label_priority` added to all 21 files (parity verified, 2196 keys).
10. **Tests** (all green — macOS 1531, AHK 1339): AHK no-options crash regression + Phase 3
    cascade + set/clear round-trip + ResolveExt + ParseTomlGroupConfig priority; macOS reader
    `[_meta]` priority + new `test_hotstrings_config.lua` round-trip + registry
    engine-consumes-override-priority (3 cascade cases).

**Hotstring collision PRIORITY — feature COMPLETE (all phases, both drivers).**

Phase 5 landed this session: the prefix-watcher live preview now ranks colliding
candidates by the engine's tie-break (length > priority > registration order) so the
non-dimmed row is exactly the mapping the engine fires — `_AddTriggerToIndex` threads the
resolved priority (individual `priority = N` else the override cascade) onto each index
entry, and `_LookupAndRender` sorts via `_PrefixSortCandidates` before the end-char/star
split. macOS has no equivalent live preview, so nothing to mirror. With Phases 1-5 + the
delays/colors section-priority UI all done, the priority feature is complete end-to-end on
Windows and macOS (engine, cascade, source defaults, per-hotstring + per-section editing,
generated-loader honouring, and the live preview).

**Still remaining (genuine hand-off):**

A. **Boot perf (Windows)** — bisected. A headless micro-bench
   (`tests/bench_boot_hotstrings.ahk`, run via AutoHotkey64) reproduces the exact
   production registration path (`CreateHotstring` → `_MirrorRegistrationToHSE` →
   `HSE_Register` + memoised `HotstringsResolve`; `_HotstringRegistrar` is 0 in
   production, so no native `Hotstring()` is involved). Cold-run breakdown (~5400
   total registrations):
   - **magic-key text expansion ~410 ms / 3149 regs** — by far the heaviest, and a
     higher per-reg cost (~0.13 ms vs ~0.086 ms) because every star trigger walks all
     its prefixes in `_HSE_IndexStarPrefixes`.
   - **autocorrection ~148 ms / 1715 regs** — dominated by `accents` (~95 ms / 1157).
   - distances+SFBs ~50 ms, rolls ~5 ms.

   Two safe, zero-behaviour optimisations landed (suite green 1348/0, 5 new pins in
   `test_hotstring_engine_main.ahk` §3.1): `_HSE_IndexStarPrefixes` now lowercases the
   trigger once and builds prefixes incrementally (was O(len²) slicing + per-char
   StrLower); `_MirrorRegistrationToHSE` parses `:flags:abbrev` with InStr instead of a
   per-registration RegExMatch. The boot log now splits the former single mark into
   three (`Layout/shortcuts/tap-holds`, `Hotstrings registered (HSE)`, `Prefix watcher
   index armed`) so a real boot bisects on the user's machine.

   **Remaining lever is architectural, not micro:** the ~600–800 ms is dominated by the
   sheer count (~5400) of per-registration object/closure constructions, which is
   largely inherent. Material further wins require doing LESS at boot — defer the
   non-critical magic-key emoji/symbol categories to a post-boot idle pass, or reduce
   the registration count — both change time-to-availability / collision ordering, so
   they need a deliberate decision before implementing. Prefix-watcher index ~205 ms +
   layout layers ~85 ms remain likely inherent.

---

## PRIORITY 1 — Mutualize the two existing drivers (AHK ↔ macOS)

Do these first, top to bottom (roughly increasing risk).

### A1. Lift `parser.lua` into `shared/lua/llm/parser.lua`  *(M, fort levier)*

**STATUS (in progress):**
- ✅ **Lift done.** `macos/modules/llm/parser.lua` is now a 37-line shim over the
  pure `shared/lua/llm/parser.lua`; `process_prediction` takes min/max words via
  an `opts` table. macOS 1531/0, Linux 37/0.
- ✅ **The orphaned `shared/domain/TokenParser.js` is removed (2026-06-13).** It was a
  *simpler* word-level prefix diff with colors that didn't even match production
  (#22c55e/#f97316 vs the canonical #40E666/#FF9E1A), consumed by zero driver, yet
  SPEC.md called it "canonical reference". Its algorithm was superseded by the
  deployed `process_prediction` (intra-word diff), whose cross-driver parity the
  corpus below already pins — so a TokenParser corpus would have meant dead parallel
  parsers. Deleted the file and corrected every doc (SPEC.md / SCHEMA.md / glossary /
  both `llm/README.md` / COVERAGE.md / stryker.config) to name `shared/lua/llm/parser.lua`
  (+ AHK `parser.ahk`) as the canonical diff-colorer, pinned by
  `process_prediction_vectors.json`. (`parser_test_vectors.json` is a DIFFERENT, real
  corpus — the response parsers, ollama/remote JSON→text — left untouched.)
- ✅ **Built** `tools/build/gen-process-prediction-corpus.lua` (Lua oracle →
  `shared/tests/corpus/llm/process_prediction_vectors.json`) and an AHK parity probe
  (`tests/bench_parity_process_prediction.ahk`). The probe **found + fixed a P0 bug**:
  the AHK `_LLM_Parser_CharLev` used 0-based array indices (illegal in AHK) and
  indexed `a` by the inner loop var, so it **threw "Invalid index" on every
  advanced-format prediction** — and `parser.ahk` was in **no** suite. Now wired into
  run_all with regression tests (AHK 1354/0).
- ✅ **Full row-by-row parity DONE.** Ported the shared intra-word token diff
  (get_chars / tokenize / token_sub_cost / token_diff_ops / intra_word_diff +
  the physical-injection and visual sections) into `LLM_Parser_ProcessPrediction`,
  replacing the old simple prefix-diff (which left `deletes` at 0 and dropped the
  inter-word space). The corpus now has 17 vectors (accents, apostrophes, overlap
  stripping, 60-char window, punctuation, word caps) and **both drivers pass it
  row-by-row** on the physical contract (deletes / to_type / nw / has_corrections /
  disable_bold): AHK 1371/0 (`test_llm_parser.ahk` §3), macOS 1549/0
  (`test_process_prediction_vectors.lua`, the oracle-drift tripwire). A1 is
  complete end-to-end.

The LLM output parser (`macos/modules/llm/parser.lua`, ~820 lines) is ~95% pure
(2-tier semantic token-diff, French typography, NFD→NFC, filler cleanup,
TAIL_CORRECTED / NEXT_WORDS extraction, gray/green/orange chunk classification).
The only OS coupling is two `hs.settings.get(min/max_words)` reads.

- Move the two settings reads to **caller-supplied params** (the prediction
  engine already knows min/max words), then move the body to
  `shared/lua/llm/parser.lua`; macOS `parser.lua` becomes a thin
  `return require("llm.parser")` shim (like `lib/text_utils.lua`).
- ~~Author a TokenParser golden corpus from `shared/domain/TokenParser.js`~~ —
  dropped: that reference impl was superseded/orphaned and has been deleted (see
  STATUS above). The real parity target is `process_prediction_vectors.json`.
- **Why**: pins the only completely-unguarded LLM domain, and the future Linux
  LLM module gets parsing for free.
- **Risk**: medium — keep the macOS `test_parser*.lua` suites green; the shim must
  re-export the full surface. Watch the `hs.*` count tripwire (gotcha G2): the
  shared file must contain **zero** `hs.` (even in comments).

### A2. Resolve the orphaned macOS codegen  *(L, the AHK-vs-macOS divergence)*

**STATUS: ✅ DONE (2026-06-13).** A 4-agent investigation confirmed all four
`macos/_generated/*.lua` were orphaned (zero runtime + zero test consumers).
Resolved per artifact:

- ✅ **expander / registry / shortcuts_bindings → deleted (dead code).** The
  generated files were never `require`'d and could not replace the hand-written
  `modules/keymap/{registry,expander}.lua` (which diverged far past the pure
  contract — TOML loading, `hs.settings`, priority cascade, case-variant
  generation, i18n). Removed `macos/_generated/{expander,registry,shortcuts_bindings}.lua`,
  `codegen-{expander,registry}-hs.cjs`, the wholly-dead `codegen-shortcuts.cjs`
  (+ its dead `windows/_generated/shortcuts_bindings.ahk`), and the 3 npm scripts.
  Kept the AHK `expander.ahk`/`registry.ahk` tested adapters + the shared specs
  (the cross-driver contract). Fixed both `_generated/README.md` (false "✅ Wired"
  claims).
- ✅ **features_manifest → wired (the real mutualization win).** Built
  `macos/lib/manifest_reader.lua` (the counterpart of the AHK `manifest_reader.ahk`,
  which already does `Features := ManifestBuildFeaturesMap()` in production) and
  wired `modules/keymap/init.lua` `DEFAULT_STATE` to read its hotstring/preview
  defaults from the shared manifest via `Manifest.default_for(...)` — fail-fast on
  a missing path. macOS keymap defaults now come from the same
  `shared/features/manifest.toml` single source as the AHK driver, with a
  tripwire test (`tests/unit/lib/test_manifest_reader.lua`) pinning the wired
  values. Re-anchored the `LUA_HS_BASELINE` purity baseline 900→905 (the +5 are
  manifest PATH literals, not OS calls). LLM (runtime JSON layering) and Karabiner
  (no manifest entries) left unwired by design.
- Verified: macOS **1562/0**, AHK **1372/0**, `build:domain` 4/4, no-fallbacks /
  port-compliance / priority-parity / ahk-encoding / banners / prettier all green.
- **Follow-up (separate item):** extend the manifest reader to the other macOS
  modules (gestures nesting, shortcuts, dynamic_hotstrings, keylogger) so they
  too drop their hand-written `DEFAULT_STATE`. Needs hardware smoke-test per module.

---

Original plan, for reference:

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

**STATUS: ✅ READER + REPRESENTATIVE MODULES DONE (2026-06-13). Broad sweep is a
documented follow-up (per-module + hardware smoke-test), mirroring A2.**

- ✅ **Dedicated fail-fast timings readers on BOTH drivers** (the reusable lever,
  mirroring `manifest_reader`): `macos/lib/timings.lua` (`M.ms` / `M.sec`,
  cwd-independent `debug.getinfo` load, `require_key`-style throw) and
  `windows/lib/timings/timings_config.ahk` (`TimingsLoadShared` / `TimingsGet` /
  `TimingsGetSec`, THROW on miss → CI-safe via run_all's OnError). Both read
  `shared/timings/constants.toml` (values are integer ms; `_sec` accessors divide
  by 1000). No driver-side fallbacks (rules 5.2 / 5.4).
- ✅ **macOS modules wired** (`498c5684e`): `keylogger/init.lua` (9 thresholds),
  `llm/prediction_engine.lua` (debounce min/max + chain fallback),
  `gestures/engine.lua` (6 timing constants; the spatial thresholds stay local).
  Local literals deleted.
- ✅ **AHK modules wired** (`0a11476ee`): `keylogger_walker.ahk` `KLWConst` (6) and
  `tap_holds/constants.ahk` (4). **Boot order solved + empirically verified**: AHK
  v2 runs static/global initializers BEFORE the auto-execute body (probe: global
  init → static-class init → auto-exec body → explicit call), so a consumer cannot
  call `TimingsGet` from its own initializer. Each constant starts at sentinel 0
  and a reassign loader (`KeyloggerWalkerLoadTimings` / `TapHoldsLoadTimings`)
  sources it at boot in `ErgoptiPlus.ahk`, right after the hotstring defaults load
  and well before the keylogger hook / tap-hold hotkeys arm. The old
  `TapMinDurationMs()` magic `: 50` fallback is gone.
- ✅ **Tripwire tests both drivers**: `macos/tests/unit/lib/test_timings.lua`
  (accessor + fail-fast + a parity tripwire on every consumed key) and
  `windows/tests/test_timings_config.ahk` (same + asserts the reassign loaders
  replaced the sentinels with the canonical values). macOS **1585/0**, AHK
  **1378/0**; lint / ahk-encoding / no-fallbacks / priority-parity green.
- ⏭️ **Follow-up (separate item, needs hardware smoke-test per module):** extend
  the readers to the remaining timing sites — the other `keylogger_*.ahk`
  (watchers / hook / network / av_state / sensors / mouse / ergonomics), the
  keep-awake (`win.ahk` / `system.lua`), `gestures/init.lua` probe timers, the
  UI / menu / Karabiner timers, and the MLX/LLM warmup / discovery / streaming
  watchdogs. Also fold in the A6 tooltip-sentinel cleanup. Reconcile only true
  divergences (e.g. `llm_display_ttl_ms` ≠ a request timeout). Each wiring needs
  the maintainer's live boot validation, exactly as flagged below.

---

Original plan, for reference:

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

**STATUS: ✅ DONE.**
- ✅ Created `shared/hotstrings/defaults.toml` (`[colors] global_default / personal`,
  `[delays] default_sec`) — the SINGLE cross-driver source. Both drivers read it at
  boot with a fail-fast `require_key` (AHK `HotstringsConfigLoadSharedDefaults` in
  `hotstrings_config.ahk`, called in `ErgoptiPlus.ahk` before the tray menu build /
  any resolve; HS `load_shared_defaults` at `modules/hotstrings_config.lua`
  require-time). The three literals (`#1e88e5` / `#6e6e73` / `0.75`) are gone from
  both drivers.
- ✅ Boot order handled by NOT auto-loading at the AHK file's top level (the
  `test_hotstring_aggregation` harness sets `_SharedDir` *after* its include) —
  explicit loader like `ui_style.ahk`. A missing key THROWS: in production the
  unhandled error surfaces the fatal dialog and exits; in CI `run_all` the OnError
  handler turns it into `not ok 0` (no hung MsgBox).
- ✅ Single-source tripwire tests on BOTH drivers assert the loaded values equal the
  file AND pin the canonical literals (`test_hotstrings_config.ahk` §SharedDefaults,
  `macos/.../unit/modules/test_hotstrings_defaults.lua`). AHK **1372/0**, macOS
  **1551/0**; cross-platform no-fallbacks / port-compliance / priority-parity /
  ahk-encoding / banners all green. `shared/timings/constants.toml` comment now
  points at `defaults.toml` as authoritative for `hotstring_expansion_ms`.
- ⚠️ Deferred (still AHK-only, out of A4 scope): `llm_prediction #AD61FF` (no HS
  equivalent — mirrors tooltip `ai_loading_hex`) and `DYN_HOTSTRINGS_DEFAULT_DELAY`
  `2.0`. The follow-up bullet below (reading `UI_AI_LOADING_HEX` for
  `llm_prediction`) is unaddressed; its boot-order gotcha is exactly why the
  explicit-loader pattern was chosen.

---

Original plan, for reference:

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

**STATUS: ✅ DONE (2026-06-13). Needs the maintainer's live-model sanity check
(token caps changed on the Windows backends — see below).**

- ✅ **Divergence confirmed real.** A 2-driver investigation showed the AHK engine
  *computes* `params["max_tokens"]` (the shared `max(15, max_words*6+10)`, default
  150) and then **drops it on the floor**, while each backend re-derived its own
  cap: Ollama `num_predict := Max(24, Min(96, mw*4))`, remote a hardcoded
  `max_tokens:256` / `maxOutputTokens:256` in all three provider branches. macOS
  already threads the value (as `max_predict`). So the AHK side was an *incomplete*
  implementation, not an intentional per-backend budget — unifying completes the
  design rather than overriding tuning.
- ✅ **`api_mlx.lua` `min(0.60,…)+0.10` is TEMPERATURE retry clamping, NOT tokens**
  (it raises the variant temp on a retry) — out of A5's scope. Removed from the
  description; no change made there.
- ✅ **Threaded `params["max_tokens"]` through the AHK backends**
  (`prediction_engine.ahk` → `api_ollama.ahk` / `api_remote.ahk`): the Ollama
  `mw*4` and the three remote `256` literals are gone; the payload builders now
  serialize the threaded per-prediction budget verbatim (default 150 / 256 only
  for an out-of-range value). These are output ceilings the generation rarely
  reaches (predictions stop at the stop-sequence / line boundary), so the
  practical effect is small, but the Windows backend caps *did* change
  (Ollama ~60→100 at max_words=15, remote flat 256→the user's budget) — **the
  maintainer should sanity-check prediction length/latency on a live model**.
- ✅ **Diversity-temp / token golden corpus already exists and covers the
  boundaries**: `shared/tests/corpus/prompt_builder/vectors.json` pins
  `max_tokens` (150 default, `mw*6+10`, floor 16) AND temperature (greedy snap at
  0.15, auto-raise, diversity cap 1.0) and BOTH drivers run it
  (AHK `meta/test_corpus_prompt_builder.ahk`, macOS twin). Added AHK payload-builder
  regression tests pinning that the threaded value reaches the wire
  (`test_llm_api_ollama.ahk` num_predict, `test_llm_api_remote.ahk` openai/gemini/
  anthropic max_tokens). AHK **1384/0**.
- ⏭️ **Follow-up (macOS parity, not blocking):** the AHK *batch* path still uses a
  single per-prediction cap rather than macOS's `max_predict * num_predictions +
  num_predictions*5` scaling — left unchanged to avoid expanding the rare opt-in
  batch path's behavior in this pass. Unify the batch budget formula across
  drivers when the maintainer next validates batch profiles on a live model.

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
