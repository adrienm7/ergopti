# Hammerspoon performance pass: Lua-side boot, menu and hotstring load 2026-11-11

Round 3 of the 2026-11-11 performance pass (after the two Linux rounds), on
branch `claude/ergopti-todo-linux-perf` from `origin/dev` at `6fec42de`. No Mac
was available. Every figure is Lua CPU time measured off-Mac under Lua 5.4.6 (the
Hammerspoon runtime's language version) on a shared 4-core cloud container.
Native costs (AppKit menus, AX, `hs.json`, Karabiner, canvas) are not reproduced;
the field-report plan at the end lists the Mac log lines that confirm or refute
each change.

## Method

- `tests/bench/bench_lua_paths.lua` (existing): the warm hotstring load of the
  four shipped packs, among other pure-Lua paths. Median of 5 to 9 runs.
- `tests/bench/bench_boot_stages.lua` (new): boots the real `init.lua` of a
  staged `ErgoptiPlus.app` through the installed-application scenario harness
  (`tests/e2e/boot`), operating-system edges replaced, and prints each
  BootProfile stage's median CPU. The world's clock is virtual, so only the
  `cpu` figure of each "Boot stage completed" line is meaningful. The harness
  boots arm64 and x86_64 at once; only the arm64 child is read, and the two
  compete for CPU, so a stage moves ±15 ms between runs.
- Attribution: an instruction-count sampling hook (`LUA_INIT_5_4`) over the same
  boots, charging each sample to the caller chain of a chosen function.

## Results

| Path (Lua 5.4 CPU, this host)           | Before                   | After                 | Cause                                                                                        |
| --------------------------------------- | ------------------------ | --------------------- | -------------------------------------------------------------------------------------------- |
| Warm hotstring load, four shipped packs | 157 ms (154-167)         | 111 ms (100-118)      | Trigger ROI index decoded every character through the pure-Lua `compat.utf8`                 |
| Trigger ROI index of 4 300 triggers     | 55 ms per registry build | 7.6 ms                | Same                                                                                         |
| Boot stage `UI: karabiner.init`         | 160 ms (144-169)         | 108 ms (101-116)      | Probing optional `sg_actions.*` keys decoded `en.json` as a fallback, at every boot          |
| Boot stage `Config schema migration`    | 167 ms (142-182)         | 146 ms (137-160)      | A current config was decoded four times and planned once (decode + record scan) for nothing  |
| Gestures menu build, picker name lists  | 36 per build, 3.7 ms     | 0 (1 per picker open) | Each of the 36 slot rows rebuilt the whole translated action list it only needs when clicked |

The `karabiner.init` gain is overstated here: the test world decodes JSON in pure
Lua where the Mac uses `hs.json`. The 2026-10 field measurement of the same
decode (`en.json`, 3 823 keys) was about 20 ms on the Mac (memory: the comment
on `locale/core.lua`'s lazy fallback), which is the expected saving per boot.

## Changes

1. **Trigger ROI keys** (`_shared/lua/keystats/trigger_roi.lua`, also Linux):
   `lower_key` is one `gsub` of every UTF-8 character through the generated
   case table instead of a decode, a re-encode and a lookup per code point;
   `utf16_length` answers an ASCII string by its byte count and otherwise
   validates once and counts the four-byte sequences. Every caller validates the
   text first, so the mapping is the same: 1 027 samples (all 1 013 case-table
   characters, malformed, astral, NUL) agree with the old functions under Lua
   5.4 and LuaJIT, and the qualified Windows lowercase corpus still passes.
2. **Locale probes** (`_shared/lua/locale/core.lua`, `infra/locale.lua`,
   `infra/i18n.lua`, `platform/remap/config.lua`): `has(key)` answers from the
   active catalogue. `test-locale-catalogue-complete` makes every shipped
   catalogue carry exactly `en.json`'s keys, so a key the active one lacks is
   absent from the fallbacks too; only an active catalogue that failed to load is
   answered by them. The Karabiner action labels ask `has` before `get`. A boot
   now decodes only the active locale (traced: `fr` alone, against `fr` then
   `en`).
3. **Current config at boot** (`_shared/lua/config_migrate.lua`, also Linux): the
   strict current-schema judgement is taken first and a current document builds
   no plan, whose outcome it used to replace; the judgement keeps a one-entry
   memo keyed by every input (content, version, stampless flag), so the fresh
   re-read and the admission check of the same bytes decode nothing. Measured on
   the shipped template (11 KB): the skipped plan costs 9.5 ms, each strict
   decode 0.5 ms; a larger user file saves more.
4. **Gesture picker names** (`ui/menu/menu_gestures.lua`): the list is built when
   the picker opens, so it also follows the locale active at that moment.

Regression tests (each fails on the code before its change): the ROI corpus case
counting `compat.utf8` calls (shared, both runtimes), `has()` cases in
`test_locale_lazy_fallback.lua`, an unresolved-key case in
`test_action_labels_localised.lua`, a no-plan case in the shared
`config_migrate_contract` (both runtimes), and name-read counts in
`test_gesture_picker_commit_receipt.lua`.

## Measured, not changed

- **Module compilation** (`Path: config dir + paths.toml` 287 ms and
  `Config-dependent module requires` 105 ms are mostly first requires): the whole
  macOS tree, 890 files and 14 MB, compiles in 331 ms against 38 ms to load the
  same chunks as Lua 5.4 bytecode. Same decision as Linux:
  `docs/design/linux-bytecode-package.md` now carries the macOS figures.
- **The migration registry decode**: `migrations.toml` (74 KB) is parsed and
  validated at every boot, 30 + 3 ms here. Avoiding it needs a generated,
  hash-checked Lua mirror of the registry (codegen owner), or a cheaper reader of
  the three `[registry]` versions that would duplicate the validation; neither is
  proposed without the maintainer.
- **Separator normalisation in the shared menu renderer**: each nested
  `R.build` normalises its subtree, then its parent normalises it again; about
  0.7 % of the boot's samples (under 10 ms), not changed.
- **Cold hotstring parse on a first boot**: the TOML parse of the packs before
  the compiled TOML cache exists (about 18 % of a first boot's samples); a
  second boot reads the cache.

## Field-report measurement plan (a Mac run confirms or refutes each change)

Read from `~/Library/Logs/Ergopti/ErgoptiPlus_<date>.log` (or the configured
logs folder), dating events by line timestamps:

| Claim                                   | Line or phase to read                                                                                    | Expected                                                    |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Locale probe decodes no fallback        | DEBUG `[locale] Locale 'en' loaded` after `Boot timing started.` with a non-English locale               | Absent at boot; `UI: karabiner.init` stage about 20 ms less |
| Current config builds no plan           | `[BootProfile] Boot stage completed: Config schema migration in … ms`                                    | Lower than the previous build's on the same config          |
| ROI index cheaper per registry rebuild  | `Hotstring groups registered (personal + dynamic + common)` stage; `hotstring_load.common_file` phases   | Lower on a warm boot (TOML cache present)                   |
| Gestures menu cheaper                   | `menu_item.gestures` in the Phase summary; `Menu tree rebuilt in … ms … Slowest:`                        | Lower; gestures leaves the slowest list                     |
| Shortcuts hold still unexplained        | `menu_shortcuts.<stage>` phases next to any `main_thread.hold` over 250 ms (2026-11-06 report, 341.9 ms) | Names the stage                                             |
| Hotstring expansion                     | DEBUG `[Span] TRACE/DONE hotstring.expand`, `hotpath:*` phases, `preview.*` phases                       | Unchanged (no change on this path)                          |
| Compile share for the bytecode decision | `Boot stage requires: … loaded N module(s)` and each stage's `cpu` figure                                | The figure the proposal would remove                        |

## Gates

Run in a Linux root container (Lua 5.4.6, LuaJIT 2.1, Node 22.23.4);
`USER=tester` because the logger's privacy identity refuses an account-less
boot. Strict convention lint, format check, codegen and the feature inventory
check: clean. JS checks reading the changed owners (locale catalogue
completeness, fallback path, action-label locale keys, locale resolution single
source, pinned source reads for Lua and Linux, false greens, duplicate
constants, shared helpers, logger scalars, Linux feature parity): pass. Full Lua
suites: see the commit's verification note.
