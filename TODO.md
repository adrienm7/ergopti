<!-- TODO.md -->

# TODO

Known, scoped, not done. Everything here was verified against the code on
2026-07-21 — items that turned out to be already delivered were dropped rather
than carried forward.

Working rules: no behaviour change without a regression test, never weaken a
test to make a change pass, and run the gates that cover what you touched —
`node ./tools/test/verify-change.cjs` derives them (see the `verify-change`
skill). Read [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) before starting:
several neighbouring ideas were tried and rejected with reasons.
[docs/ERGOPTI_PLUS.md](docs/ERGOPTI_PLUS.md) describes how the system works today
and holds the "how do I X" runbooks.

**Delete an entry from this file the moment it is done.** This file is the whole
remaining backlog; nothing else tracks it.

---

## 0. Simplification programme

From the 2026-07-30 cross-driver audit. Everything here is measured; every claim
carries a `file:line` that was re-read before being written down.

### 0.0 The diagnosis, in two sentences

The project already has the right mechanisms — hexagonal ports, a feature
manifest, a declarative menu manifest, shared Lua, cross-driver corpora, ~80 CI
gates. They are bypassed at the top, so the work is to **finish the abstractions
that already exist and delete what short-circuits them**, not to add a layer.

Root cause: `_shared/modules/features/manifest.toml` namespaces features by
driver (`[sections.ahk]`, `[sections.hs]`) instead of by meaning, `linux` appears
**0 times** in it and **0 times** in `menu_manifest.json`, and the mechanism that
would have prevented all of this — per-entry `platforms` — exists and is barely
used (116 declarations: 65 AHK-only, 30 macOS-only, 20 shared).

### 0.1 The five target invariants

Each is paired with the gate that makes it true. **An invariant without a gate is
a wish.**

| # | Invariant | Gate to build |
| --- | --- | --- |
| **I1** | One tree. The set of folder names under `modules/` is identical on the three drivers. A feature a driver does not implement is a folder with an `init` that says why, never an absence. | `test-driver-tree-parity.cjs`: identical recursive dir-name sets; no OS/vendor name outside `platform/` and `adapters/`; no platform segment under `_shared/`; every `_shared/ui/<app>` has a host or a STATUS stub |
| **I2** | One feature namespace. A feature lives at its semantic path, never under a driver name. Platforms are `windows \| macos \| linux`. A feature missing on a platform carries a translated `reason_key`. | ~~add `linux` to `KNOWN_PLATFORMS`~~ **done**. ~~lint rejecting any `[sections.ahk*]` / `[sections.hs*]`~~ — **ratcheted instead, at 223** (`test-feature-namespace-ratchet.cjs`): a lint that *rejects* them fails on arrival, since the section path **is** the config key (`ahk.shortcuts.alt_gr_lalt` is what installed `config.toml` files contain, what the menu manifest targets, and what `Features[…]` reads). Renaming 223 tables is Lot 4's schema break and needs a migration for existing users — a decision, not a refactor to slip into a test commit. The count is frozen so the migration stops growing while it waits. Measured: `features.hs` 114, `features.ahk` 92, `sections.ahk` 12, `sections.hs` 5, against **129 already namespaced by meaning** (`features.hotstrings` 69, `llm` 29, `shortcuts` 23, `metrics` 5, `script` 3) — the right pattern is already a third of the file. ~~platform-coverage report requiring a `reason_key`~~ — **report built, requirement ratcheted at 76.** `test-platform-restrictions-explained.cjs --report` prints the inventory. Of 93 single-platform declarations, **17 are namespace artifacts** (a table under `sections.ahk.*` declaring `platforms = ["ahk"]` restates its own namespace) and vanish with the rename; the **76 real** ones (46 menu rows, 30 features) carry **zero** `reason_key` today. Requiring all 76 now means 76 keys × 21 locales = **1 596 strings in 19 languages nobody here can check** — machine-filling them puts unverifiable text in front of users, which is worse than the silence it replaces. So a new restriction must explain itself and the existing 76 are described as they are revisited |
| **I3** | One menu. The manifest describes what the user sees; the renderer describes how this OS draws a row; the driver supplies only named actions, state getters and list providers. | `test-menu-parity` (render for the 3 platforms, diff the label trees); `action_id` ↔ handler bijection both ways; **ratchet "no menu row created outside the renderer"**, baselined at today's 265 AHK + 399 macOS + 101 Linux row-emitting sites |
| **I4** | One action registry. An action is a row of `_shared/modules/actions/actions.toml`: id, i18n keys, platforms, and either `emit` (neutral chord notation) or `native` (`family.function`). | ~~registry ↔ handler bijection~~ **done** (`test-action-registry-bijection.cjs`: Windows 134 declared / **0 unresolved**, macOS 103 / **0**, Linux 94 / **39** — both complete drivers are held at zero so a new unwired action fails on the first one. `ax_actions` are excluded because they are dispatched by composing the key at runtime, `"ax_actions." . _Item`, so their ids never appear as literals — counting them made Windows look 13 short when it is missing none, the same composed-name trap that misjudged two menu-manifest sections); ~~chord-notation validity per driver~~ **done** (`test-action-chord-notation.cjs`: 58 AutoHotkey + 27 Hammerspoon + 26 Linux chords, all well formed today and held by nothing until now — `["control"]` for `["ctrl"]`, or `"ctl+Tab"`, yields a modifier the driver drops, so the keystroke fires without it and the symptom reaches the user as a gesture that pastes instead of copying); a corpus of `neutral notation → native chord` vectors replayed by the three suites — **note the registry has no neutral notation to build that corpus from**: it stores `emit_ahk_key`/`emit_ahk_mods`, `emit_hs_key`/`emit_hs_mods` and `emit_linux` as a single `"ctrl+shift+Tab"` string, which `test-action-emit-is-per-os.cjs` shows is deliberate for the 13 of 24 keystrokes that genuinely differ; what IS shared and now enforced is the modifier vocabulary; boot check that every action declared for this driver resolves |
| **I5** | One implementation per behaviour. Pure logic lives in `_shared/lua/`; macOS and Linux `require` it; AHK gets generated **data** or a ported twin **pinned by a shared vector corpus**. A second hand-written copy with no corpus is forbidden. | per-behaviour corpus replayed by all three suites; lint forbidding a second copy |

**The platform seam, in one sentence:** OS-uniqueness may live in exactly two
places — `adapters/` (the *how*) and a per-OS override column in shared data (the
*what*). Anywhere else it is a bug. That is the whole answer to "how do I do
`cmd+letter` on macOS vs `ctrl+letter` elsewhere": you do not — you write
`driver+w` once and the seam resolves it.

### 0.2 Two logical modifiers, not one

Measured: of the 24 actions implemented as a pure keystroke on **both** Windows
and macOS, **11 are byte-identical**, **2** differ only by `ctrl→cmd`, and **11
differ genuinely** (macOS uses `alt` for word motion, `cmd+↑/↓` for document
bounds, `cmd+w` vs `alt+F4`, `cmd+ctrl+f` vs `F11`). A single `mod` token
therefore resolves 2 cases out of 24.

| Token | Meaning | Windows | macOS | Linux |
| --- | --- | --- | --- | --- |
| `cmdorctrl` | the modifier applications use for their own shortcuts | `ctrl` | `cmd` | `ctrl` |
| `driver` | the modifier reserved for the Ergopti+ layer | `win` | `ctrl` | `super` |

`driver` reproduces today's real behaviour: the driver's own shortcut layer is on
`Win+letter` on Windows and `Ctrl+letter` on macOS, because `Ctrl` is taken by
applications on Windows and `Cmd` is on macOS.

**AHK trap that survives the refactor:** for a chord whose suffix is a character,
the translator must emit `RetrieveScancode(<char>)`, never the bare character, or
the chord lands on the wrong physical key under the Ergopti emulation. For a named
key (`enter`, `home`…) the bare AHK name is correct.

### 0.3 The canonical tree

Rule, printable on one line:

> **If it has a user-visible name, it is `modules/<that name>/`. If it has a
> contract in `_shared/core/ports/`, it is `adapters/`. If it is OS-unique, it is
> `platform/`. Everything else is one flat file in `infra/`.**

```
<driver>/
  main.{ahk,lua}            THE entry point, same basename on the three drivers
  adapters/                 20 ports + shell_runner + driver-local OS helpers
  infra/                    flat; cross-cutting plumbing only (toml/ is the only sub-namespace)
  modules/<feature>/        one folder per feature, SAME NAMES on the three drivers
    init / actions / menu / window / platform  (platform.* is the only place a difference may live)
  platform/                 the ONLY place OS-uniqueness may live
    remap/ launcher/ packaging/ apps/
  _generated/               same filenames on the three drivers
  tests/  vendor/
```

Canonical `modules/` list (becomes a data file, `_shared/core/features.json`, read
by the tree-parity gate, by `new:driver` and by the drivers): `action_picker`,
`apps`, `changelog`, `diagnostics`, `download`, `dynamic_hotstrings`, `gestures`,
`healthcheck`, `hotstring_editor`, `hotstrings`, `hotstrings_config`, `layout`,
`llm`, `menu`, `metrics`, `model_browser`, `onboarding`, `paths`, `personal_info`,
`prompt_editor`, `shortcuts`, `spotlight`, `tooltip`, `updater`, `wpm`.

Non-negotiable renames (these alone unblock "knowing one driver lets you deduce
the others"):

| Today | Target | Why |
| --- | --- | --- |
| `windows/modules/keymap/` (physical remap) | `modules/layout/` | the same name means two opposite subsystems depending on the driver |
| `macos/modules/keymap/` (expansion engine) | `modules/hotstrings/` | idem |
| `windows/lib/hotstrings/` | `modules/hotstrings/` | a feature is not a library |
| `windows/modules/tap_holds/` + `lib/tap_hold/` | `platform/remap/` | plural and singular in the same driver, wired by a `../` include |
| `macos/modules/karabiner/`, `linux/modules/kanata/` | `platform/remap/` | three names, no common parent |
| `modules/keylogger/` | `modules/metrics/` | "keylogger" is the mechanism; `_shared/ui/` already says metrics |
| `linux/modules/menu/`, `linux/modules/ui/` | `modules/menu/`, `modules/<feature>/window.lua` | Linux has **two** `ui` namespaces |
| `windows/ui/personal_toml_editor*` | `modules/hotstring_editor/` | the Windows name means something else on Linux |
| `_shared/lua/linux/tray_protocol.lua` | `_shared/lua/tray/protocol.lua` | a platform-named node inside `_shared/` |
| `_shared/lua/llm/linux_bridge.lua` | `linux/infra/llm_bridge.lua` | 364 "shared" lines with a single consumer |
| `windows/lib/registry.ahk` | `infra/win_registry.ahk` | name collision with the macOS hotstring registry |
| `ErgoptiPlus.ahk` / `init.lua` / `ergopti_hotstrings.lua` | `main.{ahk,lua}` | ⚠ **defer this one** if the smallest safe change set is wanted — 7 consumer families pin these names for near-zero functional payoff |

Two conventions that make asymmetry legible:

- **Convention P** — `platform/` is the only word in the tree meaning "this
  differs by OS". Every driver has the same `platform/` sub-folders; one with
  nothing ships a `README.md` explaining the mechanism used instead. No file
  outside `platform/` and `adapters/` may name an OS or vendor product
  (`karabiner|kanata|webkit|webview2|hammerspoon|gtk|dbus|ydotool|autohotkey`).
  That is one grep, and it is the whole rule.
- **Convention S** — the stub with a reason. Every folder of the canonical list
  exists on every driver; where unimplemented it holds an `init` with a
  `STATUS: not implemented` line and a `REASON_KEY` that feeds the greyed-out menu
  entry's tooltip. Buys three things: `diff <(ls -R windows/modules) <(ls -R
  macos/modules)` becomes empty, "not implemented" becomes visible instead of
  absent, and a junior asked to add a feature knows exactly which file to open.

### 0.4 The lots, in dependency order

Constraints: **paths before moves, moves before content, data before code.**

- **Lot 2 — the safety net before any rename.**
  3. Residual pinned reads, both ratchets now at their floor (macOS 34, AHK 16).
     The macOS 15 left need a human: their target module has no declaration
     unique to it, so `read_driver_source` would concatenate several files and
     silently change what the test asserts — make the assertion
     order-independent first, as `test_menu_llm_api_backend_probe.lua` now is.
     The AHK 16 each pin deliberately (`run_all.ahk` itself, a `_generated/` file
     that `_DriverSourceConcat` excludes, a runner, or a single file carrying an
     ABSENCE assertion a directory-wide scan would weaken).
     **Hole found while doing this:** both ratchets apply `HELPER_RE` per FILE,
     so one converted read hides every remaining pinned read in the same file.
     That is why the macOS count did not move when four more files were
     converted. Counting per READ is the fix; it belongs with the §0.7 work on
     the same gates.

- **Lot 3 — one tree.** Four independently-green steps.
  **Two promotions landed:** `crash_reporter` → `modules/diagnostics/` and
  `updater` → `modules/updater/`, both on macOS and Windows, where **Linux
  already had them**. I1: 21.6 % → 23.5 % → **26.0 %** (11/51 → 13/50).
  The updater move shrank the union as well as raising the shared count, because
  Windows had a whole `lib/updater/` directory rather than a single file — one
  unshared path removed and one shared path gained from the same move. That is
  the shape to look for in the remaining promotions.
  That third driver is what makes these moves objective rather than taste: the
  question "is this a feature or infrastructure?" has no clean answer in the
  abstract, but "where does the same code live in the other drivers?" does, and
  answering it raises I1 by construction. Ratio 21.6 % → **23.5 %** (11 → 12 of
  51); the union did not grow, because the path already existed on one driver.
  Cost, for calibrating the rest. crash_reporter: 5 macOS references across 3
  files, ~10 Windows files, four test files moved to mirror the code, two
  source-text scans re-pointed from `_DriverDirConcat("lib")` to
  `_DriverDirConcat("modules/diagnostics")`, one JS gate that named the file by
  path. updater, roughly double: 11 macOS files, 29 Windows files, six test files
  moved, seven `_DriverDirConcat("lib/updater")` scans re-pointed, and **three**
  JS gates holding hardcoded paths (`test-updater-constants-single-source.cjs`,
  `test-version-compare-contract.cjs`, and the I1 gate's own docstring).
  Two lessons for the bigger moves: `_DriverDirConcat` is move-resilient *within*
  a directory, not across one, so every scan scoped to `lib` needs re-pointing;
  and the `.cjs` gates are where hardcoded paths hide — the Lua and AHK suites
  went green while three JS gates were still reading the old locations.
  **The objective test has now been applied to all 28 macOS `lib/` files, and it
  yields exactly one promotion**: `lib/layout.lua` → `modules/keymap/layout.lua`,
  because Windows keeps its twin at `modules/keymap/layout.ahk` and macOS already
  had the directory. **Done**, test mirrored, 8 stub sites moved with it. The other
  27 have no counterpart outside `lib/` on any driver, so promoting them would be
  taste rather than evidence — which is precisely what the third-driver test
  exists to avoid.
  **Measured cost of the remaining rename, and why it is not churn worth taking
  blind:** the `lib.` → `infra.` prefix touches **935 macOS sites** (453
  production `require` in 180 files, 74 test requires, 408 `package.loaded`
  stubs) and **76 Linux sites**, plus the AHK `#Include` graph, 3 build shell
  scripts and **7 `.cjs` gates with hardcoded `linux/lib/` paths**. It also
  **cannot be done one driver at a time**: `test-driver-tree-parity.cjs` ratchets
  on `shared ≥ 13` and `union ≤ 50`, so renaming one driver drops `lib` out of
  the shared set *and* adds `infra` to the union — it fails on both counts, which
  is the gate working correctly. Done atomically across all three it is
  **I1-neutral** (`lib` leaves the union, `infra` enters; shared stays 13, union
  stays 50), so the ratio gain everyone expects from it does not exist — the gain
  was always in promoting features out, and the evidence supports one file.
  Remaining steps: (a) extract `platform/`;
  (b) `lib/` → `infra/` with features promoted out — ⚠ the macOS `lib.text_utils`
  and `lib/toml/*` shims must keep their basenames, and the `lib.` → `infra.`
  prefix rewrite must touch production **and** the test require/stub sites in the
  same commit or every stub silently stops intercepting.
  **That hazard is now detectable, which is what actually blocked the move.**
  `test-stubs-intercept-something.cjs` fails on any `package.loaded["x.y"] = stub`
  whose module does not resolve. Measured: **1 141 stub assignments across 708
  Lua test files** (the "~1 942" figure counted requires and stubs together).
  Renaming a production module now lists every stub site that would have gone
  quiet — verified by moving `lib/logger.lua` aside and watching the gate name
  them. Host-provided modules (`hs`, `hs.*`, `lgi`, `posix`, `luv`, `ffi`, …) are
  allowlisted, and `= nil` is treated as a cache eviction rather than a stub.
  **Three stubs were already dead before any rename**, which is the best evidence
  the hazard is real rather than theoretical: `test_llm_models_presets.lua`
  stubbed `modules.llm.models_mgr` and `ui.menu.menu_llm.models_mgr` — neither
  module has ever existed, and the module under test requires
  `models_manager_ollama`/`_mlx` instead — and
  `test_build_inserts_missing_timestamp.lua` stubbed `lib.json` where
  `sqlite_writer` requires `hs.json` and nothing in the driver requires
  `lib.json` at all. None made a test fail, because an inert stub is
  indistinguishable from a working one from inside the test. All three removed; (c) `ui/`
  dissolves into `modules/<feature>/{menu,window}`; (d) de-platform `_shared/` and
  ~~repair `tools/codegen/new-driver.js`~~ — **repaired.** All four paths were
  stale, not three: `REPO_ROOT` resolved to `tools/`, `DRIVERS_DIR` pointed at the
  pre-reorg `static/drivers/`, and both spec dirs had moved under
  `_shared/core/`. The tool scanned an empty directory, wrote **zero** adapter
  stubs, generated a README announcing "Ports to implement (0)", **exited 0** and
  printed a "Done. Next steps:" checklist. Nothing about scanning an empty
  directory is an error, and `static/drivers/` still exists on some checkouts as
  a husk of two empty untracked folders, so the path did not look wrong to a
  reader either. It now emits 20 adapters + 5 domain specs, and **refuses** to
  scaffold at all when it finds no ports — an empty scaffold is not a scaffold.
  `test-new-driver-scaffold.cjs` runs the tool for real and counts the files,
  because a structural check would pass on a tool whose other three paths are
  still wrong. Proving it red taught the test one more thing: the broken tool
  wrote to `tools/static/drivers/`, so cleanup aimed only at the correct location
  left a stray tree behind — a cleanup that works only when the tool works is not
  a cleanup, and it now sweeps the mis-rooted locations too.
  ~~Then the I1 gate~~ — **built**, as `test-driver-tree-parity.cjs`.
  **Progress metric: tree-identity ratio, 21.6 % today** — 11 of 51 depth-≤2
  subdirectories present in all three drivers (the earlier 18.9 %/10-of-53 figure
  used a slightly different exclusion set; this counter documents its own rule
  and excludes `tests/`, virtualenvs, caches, `build/`, `bin/` and `.app`
  bundles). Ratcheted in **both** directions: the shared count may not fall, and
  the union may not grow — a new directory in one driver alone dilutes I1 even
  when nothing was removed. `--measure` prints the full breakdown, including the
  26 macOS-only, 22 Windows-only and 6 Linux-only paths that make up the gap.
  Note the baseline is a literal: deriving it from the value it constrains would
  make the comparison `x <= x`, which passes for every input — the exact false
  green this repo ratchets against elsewhere. Still to do: the Convention S stubs.

- **Lot 4 — one namespace.** Migrate the **206 of 335 features (61.5 %)** out of
  the `[ahk.*]` / `[hs.*]` silos to their semantic path with per-entry
  `platforms`. **Approved by the maintainer, config-schema break accepted** — the
  user deletes `config.toml` and the driver regenerates it, as the v1→v2 cut-over
  already established. Add `linux` to the platforms of the features Linux really
  implements and to `KNOWN_PLATFORMS`. Create `linux/_generated/features_manifest.lua`
  + `linux/infra/manifest_reader.lua`; extend `test-config-schema.cjs` to the Linux
  template. Merge the duplicated privacy toggles: the three filters exist **twice**
  in the shared manifest (`metrics.*_filter_enabled` **and** `ahk.metrics.filter_*`)
  and the AHK driver reads neither — it hardcodes `:= true`.
  The extreme case: `ahk.gestures` = 11 features vs `hs.gestures` + `.modes` +
  `.sensitivities` = 109, for the same feature, with the **same i18n key**
  `menu.gestures` on both sides.

- **Lot 5 — one menu.** The manifest must gain the 14 capabilities that explain
  every hand-written row: ~~`checked_when` (~14 rows)~~ — **done, and shipped
  used**: the three metrics filter rows declare it, their handlers read the
  predicate instead of restating `MetricsFilters.<field>`, and the getters map
  gained the three state reads. It **fails OPEN where `disabled_when` fails
  CLOSED**: a checkmark asserts to the user that something is on, so inventing
  one when the state cannot be read says a privacy filter is active when it is
  not — they stop looking for the setting while the data they believed excluded
  keeps being recorded. Both directions pick the answer that does not overstate
  what is enabled, and 7 tests pin that asymmetry because "make it consistent
  with its sibling" is the obvious-looking change that breaks it. The remaining
  ~11 rows are a mechanical repeat of this shape. ·
  resolvable `action` id (12),
  `label.format` + `args` with live values (~20), `provider` for dynamic lists
  (~15 slots), `radio_group` (~5), `toggle_shape` (`parent` on macOS/Linux,
  `first_row` on AHK — already solved for the IA submenu only), declarative
  `prompt` (~12 twenty-line bodies), counts/badges (~12), the `linux` token,
  groups nested beyond one level (~4), separator semantics (re-implemented 3
  times), an `emoji` field, `visible_when` (~8), and a real top-level section list
  (the 9 head ids are read by nobody).
  Order: (1) pilot on the metrics menu — best-covered, and ~280 lines of handlers
  across two drivers become ~26 manifest rows + ~26 registry entries; ~~(2) kill
  the dead-manifest-key duplications and add the "every key has a reader"
  gate~~ — **done, and the count was two, not five.**
  `dynamic_hotstrings_order` duplicated `_DYNAMIC_HOTSTRINGS_ORDER` in
  `windows/ui/tray_menu.ahk` and DISAGREED with it, spelling the separator
  `"---"` where the live one spells `"-"`; `word_delimiter_defs` carried 20
  entries no driver asked for. Both removed at their source in
  `features/manifest.toml`, since the JSON is generated.
  The other three are alive, and each shows a way a manifest key is legitimately
  reached — worth knowing before writing this kind of check again:
  `gesture_slots` via Lua dot access, quoted nowhere; `modifier_combos_group` and
  `accented_letters_group` dispatched BY VALUE, the id arriving from the manifest
  at runtime and never appearing as a literal in the handling code. The first
  version of the guard reported all five;
  `test-menu-manifest-keys-have-readers.cjs` is deliberately generous for that
  reason, because a gate that cries wolf on working code gets deleted and then
  guards nothing; (3) make Linux a first-class platform —
  write `_shared/lua/menu/render.lua` (shared macOS+Linux, ~230 l) and
  `linux/infra/menu_host.lua` (~180 l), delete `menu_builder.lua` (833 l), route
  its 101 hardcoded French labels through the shared locales; (4) migrate the
  macOS hotstrings then layout submenus — layout needs `platforms:["macos"]` rows
  for the TIS/bundle features first, because `layout_menu` currently describes a
  Windows-only menu that the macOS drift gate pins without macOS implementing it;
  delete `test_menu_hotstrings_layout_drift_gate.lua` **after**, never before;
  (5) move the 1 812 lines of `macos/ui/menu/` that are not menu layout
  (`preferences.lua`, `menu_state.lua`, `menu_watchers.lua`, `shortcut_utils.lua`,
  `menu_paths.lua`) out; (6) fold `_shared/modules/llm/menu_layout.json` in — its
  schema is a strict subset of v3 with exactly the fields v1 lacked; (7) lay the
  ~~"no menu row outside the renderer" ratchet~~ — **done**
  (`test-menu-rows-outside-renderer.cjs`, windows 222 / macos 301 / linux 3).
  Measured payoff anchor: the layout submenu is **721 lines on macOS vs 41 on
  Windows (17.6×)** — and Windows is 41 lines *because the manifest does the work*.
  Nothing to invent: do on macOS what Windows already does.

- **Lot 6 — one action registry.** ~~(1) Fix the actions mis-declared
  `platform = "ahk"` that are fully implemented on macOS.~~ Done, and the count
  was **four**, not twelve: `select_line`, `teleport_mouse`, `spotlight_mouse`,
  `toggle_capslock`. The others on the original list (`pick_color`,
  `paste_plain`, `uppercase_selection`, `titlecase_selection`,
  `surround_parens`…) have no macOS implementation at all — they were counted from
  the LABEL table in `macos/modules/gestures/actions.lua`, which lists them but
  registers no handler, so the label is dead weight rather than evidence.

  The fix needed both halves. Flipping the TOML alone would have put four dead
  rows in the macOS picker, because `execute_single()` refuses an action it has no
  handler for — so each is now registered into the gesture registry, delegating
  (lazily, to keep the shortcuts tree out of boot) to the shortcut-layer function
  that already existed. `test-action-platform-truth.cjs` holds both directions:
  a declaration claiming macOS with no handler, and a handler hidden by its
  declaration. The second is what these four were.
  ~~(2) Move `_shared/modules/gestures/actions.toml` to
  `_shared/modules/actions/actions.toml`~~ — **moved**, together with
  `modifier_chords.json`, which had to travel with it: the Linux loader derives
  the JSON path by rewriting the FILENAME of `actions.toml`
  (`gsub("actions%.toml$", "modifier_chords.json")`), so the two files are
  coupled as siblings with nothing on either side saying so. Leaving the JSON
  behind resolved it to a file that does not exist, and the only symptom was the
  modifier-chord labels quietly vanishing from the action picker. That coupling
  is now stated in a comment where the derivation happens.
  The catalogue is read per-driver rather than generated, so all three had to
  follow: 8 files by path string, plus **two more the first sweep could not
  see** — `test-action-platform-truth.cjs` builds its path from separate
  `path.join` segments, and Windows builds its two with **backslashes**. Both
  left their suites green while still reading the old location, which is the
  updater move's lesson in a second form.
  ~~Still open on this item: the `emit` / `emit_<os>` … schema fields~~ — **the
  `emit` half is in.** 62 actions now carry a declarative keystroke, and the
  backlog's count of 62 is exactly right while its *mechanism* was not: only
  **four** are bare `Send(literal)` lambdas. The other **58** call
  `TextPressKey("c", ["Ctrl"])` — a key plus a modifier list — which is why the
  portable shape is `emit_key` + `emit_mods` and a raw send-string would not have
  fitted. The four genuine raw sequences are `emit_ahk`, since
  `{Home}{Shift Down}{End}{Shift Up}` has no portable form. `Win` is stored as
  `super`, each driver mapping it to its own physical key.
  The rows were **derived from the registry, not transcribed**: 62 hand-copied
  key/modifier pairs would carry errors nothing catches until a user makes the
  gesture and the wrong shortcut fires — `copy` sending Ctrl+X is not a crash,
  not a failing test, and not visible in review.
  `test-action-emit-rows-match-code.cjs` re-derives them independently and
  compares in **both** directions: a declared row whose handler is not a plain
  keystroke is caught too, because converting that would silently replace
  whatever the handler really does. That gate is what makes the data trustworthy
  enough to delete the code against in (3).
  **Found while doing it — a real defect in the shared TOML codec:** an inline
  table containing a *multi-element* nested array (`{ key = "Left", mods =
  ["ctrl", "super"] }`) makes `decode` return **nil**, with no error. Single
  element works; a top-level multi-element array works; two scalar keys work.
  The Linux gesture suite lost 14 tests to it. Flat keys sidestep it and suit
  the AHK and Lua hand-parsers that read this file too — and the codec bug is
  now **fixed** as well. Cause: the inline-table splitter tracked quoted regions
  but not bracket depth, so a comma inside a nested value split the pair list
  into fragments with no `=`, `split_kv` rejected them, and `decode` returned nil
  for the entire document. Exactly the logger sub-files shape: a scanner that
  tracks quotes but not nesting. Quotes alone are never enough when the delimiter
  being searched for can also appear one level down.
  Six regression cases in `test_toml_codec_edge_cases.lua`; three go red without
  the fix (2-element, 3-element, nested inline table) and three guard behaviour
  that already worked and must keep working — a comma inside a string, and the
  trailing-comma rejection that depth tracking must not soften. ~~(3) Convert the **62 measured pure-keystroke Windows actions** to `emit` rows~~
  — **the Windows half is done.** All 62 hand-written lambdas are gone from
  `modules/gestures/actions.ahk`; the handlers are now built at static-init from
  `_generated/gesture_emit_actions.ahk`, itself generated from the shared
  catalogue. The macOS closures and Linux `elseif` branches are still to follow —
  and **measurement says they cannot reuse the Windows rows**, which is the most
  important thing this item turned up.
  Of the **24 actions both drivers implement as a bare keystroke, 15 use a
  different key or modifier.** `close_window` is alt+F4 on Windows and cmd+w on
  macOS; `fullscreen` is F11 against cmd+ctrl+f; `word_next` is ctrl+Right
  against alt+right (macOS moves by word with Option, Windows with Control);
  `doc_start` is ctrl+Home against cmd+up. Several more differ in key-name
  spelling alone — `BackSpace`/`delete`, `Enter`/`return`,
  `Delete`/`forwarddelete`.
  These are the platforms' own conventions, not accidents to normalise away. So
  the rows are `emit_ahk_*` and `emit_hs_*`, never one portable `emit`. They were
  briefly named `emit_key`/`emit_mods`, which reads as portable and invites
  exactly one change — "map super→cmd and share them" — that would compile, pass
  every existing test, and silently give macOS the wrong keystroke for more than
  half of them. `word_next` sending ctrl+Right on macOS does nothing at all, and
  no test in the suite invokes a gesture handler, so nothing would have caught
  it. `test-action-emit-is-per-os.cjs` records the divergence as data, refuses a
  portable row, and fails if a recorded divergence quietly disappears.
  ~~The 27 macOS rows are already in the catalogue … that conversion is now
  mechanical~~ — **and it landed.** The 27 hand-written
  `sg("id", function() postKeyStroke({mods}, "key") end)` registrations are gone;
  macOS registers them in a loop over `_generated/gesture_emit_actions.lua`.
  One language difference worth knowing before the Linux conversion: the AHK side
  must build its emitters in helper functions because an AHK loop closure
  captures the loop VARIABLE, while Lua's generic `for` binds fresh locals each
  iteration, so the Lua loop can register directly. Same invariant, different
  mechanism, and only one of the two needs the indirection.
  Two gates had to follow the refactor, both for the same reason — they detect
  handlers by scanning source text, and a loop is not a literal call:
  `test-action-platform-truth.cjs` reported `sel_word_prev`/`sel_word_next` as
  "declared but macOS registers no handler" when both work perfectly, so it now
  counts generated rows as registrations. And the first draft of the macOS test
  reached for the private `SG` registry, could not find it, and fell back to
  `assert_true(true, …)` — a tautology that would have passed forever while
  testing nothing. **The false-green ratchet caught it**, which is the clearest
  demonstration this session that the gate earns its keep: it caught its author.
  ~~Linux's `elseif` branches remain.~~ — **all three drivers are converted.**
  Linux's 26 single-`xdotool key` branches now resolve through a lookup in
  `_generated/gesture_emit_actions.lua`.
  Its rows are stored as the **verbatim xdotool combo**, not split into key +
  modifiers, because a split would imply a portability that does not exist: X11
  keysyms (`Return`, `BackSpace`) are neither AHK's names nor Hammerspoon's
  (`return`, `delete`), so every driver rebuilds the string from its own
  vocabulary regardless.
  **What the three sets of rows finally show:** Linux and Windows agree far more
  often than either agrees with macOS — `close_window` is alt+F4 on both,
  `word_next` is ctrl+Right on both, against cmd+w and alt+right. The divergence
  is macOS-versus-the-rest, not three-way, which is what two PC-convention
  platforms and one Mac-convention platform should look like. That was invisible
  while the same facts sat in three registries.
  One placement trap, recorded because the next such conversion will meet it:
  dropping the branches and inserting the lookup where the first one *was* put it
  **inside the preceding branch's body** — the file still parsed, the suite still
  ran, and the lookup fired for exactly one action. It belongs before the chain
  begins, next to the existing modifier-command lookup.
  **Generated rather than registered at runtime, for a measured reason:** the
  obvious move is to let `_GestureLoadActionCatalog()` install them while it
  already has the TOML parsed — but that loader is deliberately deferred off the
  boot path (a `SetTimer` with a negative period, worth ~100 ms), so building
  handlers there opens a window in which a gesture fires and finds nothing
  registered. Generation keeps registration where it was and adds no boot-path
  parse.
  **The bug this shape avoids:** a closure created inside an AHK loop captures
  the LOOP VARIABLE, so building the emitters inline would have given all 62 the
  final iteration's values — every gesture emitting one keystroke, with the
  registry still reporting the right count and nothing thrown. The emitters are
  built by helper functions taking the values as parameters, and
  `test_gesture_emit_actions.ahk` pins that construction.
  The old `test-action-emit-rows-match-code.cjs` was **retired, not weakened**:
  once the code is generated from the catalogue, comparing them is circular. It
  had already done its job — making the data trustworthy enough to delete the
  code against — and its own floor check reported that it had nothing left to
  compare. Its replacement asserts registration completeness and the binding
  construction. What it deliberately does **not** do is invoke a handler and
  observe the keystroke: AHK v2 resolves function names at compile time, so that
  needs a recorder seam in `adapters/text_sender.ahk` that nothing else in the
  suite currently requires. (4) Write `chord.{ahk,lua}` and add the **21st port, `HotkeyRegistrar`** —
  none of the 20 has a "bind a chord to a callback" operation, which is why each
  driver invented its own. (5) Replace Windows layers A+B, which bind the same
  intent to two different physical keys because layer B is registered *before*
  `modules/keymap/layout.ahk` and therefore resolves against the OS layout instead
  of Ergopti's. (6) Give macOS the binding UI it lacks — **measured and
  confirmed, still to build.** `M.DEFAULTS` is empty by design; `get_action`,
  `get_slot_label` and `get_assignments` have **0** production callers;
  `set_action` has exactly one, writing the literal `"none"`. `start`/`stop` do
  real work, so the module is not dead — its *configuration* is.
  Worse than "unused": that single writer is `clear_keyboard_shortcut_settings()`
  in `ui/menu/init.lua`, a reset routine that walks `hs.settings` for the
  `keyboard_shortcut_` prefix and clears each match. **Nothing in the driver ever
  writes a key with that prefix**, and DEFAULTS is empty — so it is a reset path
  for a feature that cannot be configured, iterating over keys that cannot exist.
  Not deleted: the module runs, and removing the reset would strand settings the
  day the UI lands. `test-keyboard-slot-surface-is-dead.cjs` holds the
  measurement instead — it fails if a reader appears (the UI landed: replace the
  gate with tests of it), if `DEFAULTS` gains an entry (slots would start bound
  on a fresh install), if the writer gains a second caller, or if that caller
  starts writing anything other than `"none"`. It also stops the dead surface
  growing, which is the shape of the 136 unreachable label entries and the
  16-of-21 locale table already found here. (7) Merge
  `karabiner/data/actions.json` (73 actions, hardcoded French, no i18n keys) into
  the one registry, `holdable` becoming a per-action flag. ~~(8) Fix the Linux `action_picker` bridge~~ — mostly done. It answered
  `execute`/`search` with three hardcoded French labels; the page posts
  `confirm`/`cancel`/`ready` and nothing else, so neither end matched and the
  picker was inert while both sides looked implemented. It now speaks the page's
  protocol, passes `none` and `__native__` through unchanged rather than deciding
  what they mean, and `build_init_payload()` produces exactly the shape
  `init(data)` reads, with the SAME locale keys macOS uses so the two hosts show
  the same words. The contract test covers three hosts now and, as importantly,
  asserts that no host answers a message the page never sends — a handler branch
  for an invented action is indistinguishable from a working feature until
  somebody tries it.

  **What is left is one structural gap:** the host→page push. `init(data)` has to
  be evaluated IN the webview after `ready`, and a Linux bridge handler is given
  only `(payload, state)` — no webview reference — so the channel does not exist.
  (`webview_manager` has a `__hostBridgeResponse` reply path, but no page in
  `_shared/ui/` defines that hook, so it is dead too.) The payload is built and
  tested, so the day the channel lands the content is already right. (9) Replace the macOS-only `ctrl_shortcuts`/`cmd_shortcuts` and the
  AHK-only `modifier_combos` groups with one `chord_bindings` group rendered
  identically everywhere. ~~(10) Delete the 136-line macOS hardcoded label fallback~~ — done. All 132 of
  its entries had a locale key, so it was unreachable: a second copy of the
  translations, free to drift from the real ones with no symptom, because
  unreachable code shows none. Its premise is now a gate
  (`test-action-labels-have-locale-keys.cjs`): all 102 registered actions resolve
  a label in all 21 locales, and `get_label` returns the raw id rather than
  papering over an omission.

  The `shortcuts.label_*` half does **not** hold up. There are 23 such keys and
  **4**, not 13, say the same thing as an `sg_actions.*` key — and those four
  differ by an emoji prefix (`"Select line"` vs `"☰ Select line"`), which is a
  real distinction between the two menus rather than redundancy. Deleting them
  would strip the emoji from the shortcuts menu or add it where it does not
  belong. Left alone deliberately; the 273-string figure does not survive
  measurement.

- **Lot 7 — the cross-cutting layer.** ~~(1) the shared-tree resolver~~ — **done**,
  as `linux/lib/paths.lua` (the name mirrors macOS `lib/paths.lua` rather than the
  proposed `infra/`, since `infra/` does not exist yet — that rename belongs to
  Lot 3). Every module now asks it, and
  `test-linux-shared-path-resolver.cjs` fails on any hand-counted hop.

  **Five wrong depths, not two.** Beyond the language menu (`../../`, one level
  too high, which is why it offered 2 locales of 21 — the scan found nothing and
  the `{"en","fr"}` fallback took over) and the CWD-dependent schema load
  (`../../../`), the same file also got the locale DISPLAY-ORDER path wrong, so
  the two survivors sorted alphabetically; `ergopti_hotstrings.lua`'s bundled-
  hotstrings fallback overshot by one; and `hotstrings_config.lua`'s bundled
  fallback overshot by one. Every one of them failed by finding nothing and
  quietly using a default, which is why none had ever been reported.

  Two bootstraps genuinely cannot use the resolver — they set `package.path`,
  which is the thing they are computing — so the gate asserts their depth
  directly instead of exempting them on trust. `engine.lua` was one of the five.

  ~~The `$HOME` half~~ is done too, as `linux/lib/config_paths.lua`. The count
  was **19 call sites across 15 files**, with **six different answers** for a
  missing HOME — `"/tmp"`, `"~"`, `""`, `"."`, `"/home/user"`, and one bare
  concatenation with no fallback at all. Two of those are broken rather than
  merely inconsistent: the bare concat THROWS on a nil HOME and took the whole
  menu build with it, and `"~"` is never expanded by `io.open` (Lua does no tilde
  expansion), so those paths addressed a literal directory named `~` beside the
  process — the keylogger wrote its database there. `"/home/user"`, in five
  webview bridges, is the worst of the three: a plausible path belonging to
  nobody, so a write there looks like it worked.

  One policy now, applied everywhere: fall back to `TMPDIR` (or `/tmp`), which is
  honest — obviously not the user's home, writable, and nothing there is mistaken
  for durable state. `adapters/storage.lua` keeps its `ergopti_plus/` directory
  name rather than being "corrected" to `ergopti/`: that is where existing
  installs have their `storage.json`, and renaming it would orphan every stored
  setting. 19 sites → 3, all inside the resolver, and the gate holds it.
  ~~Gate: `test-shared-root-resolvers.cjs` must **execute** each expression and
  assert the file exists — never merely that the module loaded.~~ **done.** It
  runs both drivers' `lib/paths.lua` under a real interpreter (the macOS one
  under the driver's own `hs` stub, not a bespoke one), asks each for all 59
  `_shared` paths the code requests, and stats every answer; `shared_root()` must
  land on the tree itself, since a walk that stops one level early still returns
  something that exists. `config_paths.lua` is executed under three environments
  — HOME set, HOME absent, HOME and TMPDIR absent — because the fallback is the
  part that shipped wrong, and `"~"` vs `"/home/user"` vs `"/tmp"` are
  indistinguishable by type. When no interpreter is present the gate **fails**
  rather than skips, so CI's `validate-js` job now installs `lua5.4`. Six
  mutation probes confirm it fires: a wrong literal, each driver's root walking
  to the wrong place, both bad HOME fallbacks, and the missing interpreter.
  (2) Move the macOS
  config-path SSOT out of `ui/menu/menu_paths.lua` (25 call sites): today `lib/`
  depends on `ui/menu/`. ~~(3) **Generate the logger sub-file routing tables** from `sub_files.toml`~~ —
  **done.** Both hand-rolled `[[array_of_tables]]` parsers are gone (≈120 lines of
  Lua, ≈112 of AutoHotkey), replaced by
  `tools/codegen/codegen-logger-sub-files.cjs` emitting
  `macos/_generated/logger_sub_files.lua` and
  `windows/_generated/logger_sub_files.ahk`. The "`]` inside a quoted pattern
  closes the array early" bug is now structurally impossible: the generator uses
  a real TOML library, and there is no second copy of the grammar to fix twice.
  **Found while doing it:** each parser also carried a *hardcoded fallback list*
  for when the shared file is unreachable — a second copy of the routing data,
  and the macOS one had **already drifted**: it routed `gestures` on one pattern
  where the canonical file declares two (`"[gestures"` and `"gesture"`), so a
  stripped build silently stopped collecting every bare `gesture` line. Both
  fallbacks are deleted; a committed generated file has no "unavailable" branch
  to diverge in, which is the convention `terminators.ahk` already followed.
  Four regression tests guarded the removed parsers. None were deleted — each was
  re-pointed at the artifact that can still regress: the generated table compared
  against the canonical TOML. Two of them had already decayed into pinning a
  spelling (`src:find("strip_quoted(line)")`, `InStr(Body, "_ArrayIsClosed(")`),
  which is exactly the failure mode the false-green skill warns about; asserting
  the loaded data instead means no rename can make them vacuous. The bracket bug
  is now proven end-to-end by probe: inserting `"PROBE_SENTINEL]"` before
  `"gesture"` in the TOML leaves both patterns in both drivers' output.
  The drift gate takes a **list** of generators now rather than one hardcoded
  path — the same shape of mistake as the hardcoded file list it already had.
  ~~(4) `[logger]` section in `_shared/modules/timings/constants.toml` + single-source
  gate~~ — **done.** Measured counts: retention 14 in **3** copies (not 4 — AHK
  `LOGGER_RETENTION_DAYS` plus the macOS `max_age_days or 14` default written
  twice in one file), ring 200 in 3 (AHK, macOS, shared core `RING_CAPACITY`),
  flush 500 ms in 1 (AHK only — a single-source candidate, not a drift risk).
  **The dedup window was the bad one**, and worse than "2 magic literals"
  suggests: it existed ONLY as a bare literal on both sides, in different units
  — `< 5` seconds on macOS, `< 5000` milliseconds on Windows — with each site
  carrying a comment asserting it matched the other ("the window matches the AHK
  driver so both drivers dedup identically" / "Mirrors the macOS driver") and
  nothing checking it. Two unnamed numbers in two units, each documented as equal
  to the other, are indistinguishable from two that have drifted apart. Both are
  now named constants (`DEDUP_WINDOW_SEC`, `LOGGER_DEDUP_WINDOW_MS`) and
  `test-logger-scalars-single-source.cjs` asserts the s↔ms conversion explicitly
  rather than leaving it asserted in prose. The gate checks **every** occurrence
  rather than the first — the macOS retention default is written twice, and a
  first-match gate would have let the second drift freely — and refuses a bare
  literal creeping back into the comparison. All five mutation probes (one per
  guarded value) go red. Duplication is still duplication: the drivers do not yet
  READ the registry at runtime, so the gate is the guarantee, exactly as with
  `test-keylogger-timings-single-source.cjs`. ~~(5) Add the `active → en → fr` cascade to `_shared/ui/i18n.js`~~ — **done**,
  and the premise needed correcting twice. All 21 locales are key-complete today
  (2 339 keys, 0 missing, 0 blank), so "a partially translated locale" was not the
  live failure; and the native menus do not cascade either — they fall back to the
  raw key name. The real hole was worse than described: **368 `data-i18n` elements
  across the eleven shared webviews all ship with an EMPTY body**, so the loader's
  single `if (strings) apply(strings)` meant one failed fetch — an unshipped
  locale code, a `file://` restriction, malformed JSON — rendered the **entire
  window blank**, with nothing but a `console.warn` in a webview that has no
  visible console. A blank window reads as a hang; the native raw-key fallback is
  at least legible. The chain is now consulted lazily, so a complete active locale
  still costs exactly one request — a cascade that always fetched three would have
  tripled every request to fix a case that never happens.
  `test-webview-i18n-cascade.cjs` executes the real `i18n.js` in a DOM stub
  (a source grep would pass on a cascade that is written but never reached) and
  asserts the fetch **count** as well as the text.
  Left alone deliberately: the **12 copies of `_t()`** in two flavours — 3 return
  `null` on a miss so callers can write `_t(k) || "French default"`, 3 return the
  key. Unifying them would silently disable those `||` fallbacks; it is a separate
  change with its own reds. ~~(6) Generate the three 21-locale tables from `locale_order.json` + a new
  `locale_names.json`~~ — **done, and it was hiding a live user-facing gap.** The
  display ORDER was already single-sourced and gated; the NAMES were not, and one
  of the three hand-maintained tables had silently fallen behind.
  `linux/lib/i18n.lua`'s `display_name()` held **16 of the 21** shipped locales
  and ended in `return names[code] or code`, so **`da`, `no`, `cs`, `he` and
  `hi` rendered in the Linux language menu as those bare two-letter codes**,
  sitting between "Nederlands" and "Русский" while the other sixteen showed their
  native names. Nothing failed: `or code` is a perfectly good fallback for an
  unknown locale and indistinguishable from a forgotten one.
  macOS and Windows agreed on all 21 names, which is what made
  `_shared/data/locale_names.json` derivable rather than a judgement call about
  whose spelling was right. `codegen-locale-tables.cjs` now emits all three
  tables. The flag column does stay per-driver as predicted — Windows gets a
  `[XX]` tag because flag emoji do not render in Win32 menus — but the tag is
  *derived from the code*, so it carries no data that can drift.
  `test-locale-names-single-source.cjs` holds three properties: every ordered
  locale is named, every shipped `locales/*.json` is ordered, and **no driver
  spells the names out again** — that last one is what prevents the regression
  rather than re-detecting it, since a fourth copy is how the third one drifted.
  `test-locale-order-single-source.cjs` was re-pointed at the generated tables
  in the same commit. Watch for one trap when regenerating: the hand-written
  tables aligned their columns with padding *after* the closing quote, and
  padding inside the string literal puts trailing spaces into the name the menu
  actually renders — invisible in a diff, visible in the UI. (7) **Only then** make macOS consume the shared logger core,
  and only after writing `_shared/tests/corpus/logger/behaviour_vectors.json` —
  this is the module with the worst bug history in the repo.

- **Lot 8 — the engines.** Promise **one matcher, not one engine**: the genuinely
  platform-agnostic core is ~350 lines (tail-char bucketing, suffix equality with
  case folding, the word-boundary predicate, the collision tiebreak). The other
  ~14 000 are emission, buffer/screen sync, suppression bookkeeping, TOML I/O,
  tooltip preview and OS quirks, legitimately per-driver.
  1. ~~**Fix the corpus contract first.** `backspace_count` cannot be a
     cross-driver assertion…~~ — **the premise was wrong; measured and closed.**
     The corpus is correct and macOS already conforms: its e2e replays all 13
     matched vectors against the real expander and passes 39/39 today.
     `backspace_count` is a **logical** count — how many codepoints the expansion
     replaces — not the number of backspace keystrokes emitted. macOS keeps the
     longest common prefix shared by trigger and replacement, so it emits fewer
     keystrokes (`btw → by the way`: 2 emitted, not 3, and **not 1** — the figure
     previously recorded here was neither the logical nor the physical count),
     but it replaces the same codepoints. The macOS e2e harness reconstructs the
     logical count from the screen precisely so the optimisation cannot change
     the answer. Measured: **6 of the 13** matched vectors would give a different
     number under the physical reading.
     What was actually missing was that **nothing said so anywhere** — the field
     name reads as physical, which is how this got recorded as a macOS
     conformance bug in the first place. The corpus now carries a
     `field_semantics.backspace_count` entry, and
     `test-corpus-backspace-count-semantics.cjs` keeps it honest: it pins the
     logical formula in one place instead of three near-identical per-driver
     copies, and fails if no vector distinguishes the two readings — otherwise a
     driver could satisfy the corpus by emitting either number.
     The failure this prevents is the plausible one: someone "simplifies" the e2e
     harness to count emitted backspaces, macOS goes red against a corpus that is
     right, and the corpus gets "fixed" to match one driver's optimisation.
  2. Extend the corpus to the branches measured as absent: ~~`auto_expand`,
     `final_result`~~ — **measured, and neither can become a passing vector yet:
     the Linux engine reads NEITHER.** Both reach only its hotstring-editor
     bridges (0 engine-side references, 2 UI references each), so a user ticks
     them, they are written to the TOML, and the matcher ignores them. Windows
     turns `auto_expand` into AHK's `*` and macOS reads it in
     `keymap/registry.lua`; unread, Linux fires every entry the moment its
     trigger completes, so an entry written to wait for a terminator expands
     mid-word. `final_result` suppresses the rescan of an expansion, so unread,
     entries marked final can chain. **The flag-support record claimed Linux
     supported both** — it decided support by finding the flag name anywhere in
     the driver, counting the settings panel as engine support. Scope is now
     engine-side and the record corrected; the exclusion is probed as
     load-bearing. Same shape as `is_case_sensitive_strict`: a vector is only
     writable once the engines agree. ·
     the terminator path, ~~the
     NBSP typographic rule~~ — **measured: Windows and macOS implement the
     strip-and-require rule (`hotstring_match.ahk`, `expander.lua:426-436` +
     `:503-512`, both adding the extra backspace for the stripped nbsp); **Linux
     has none**. So it joins `auto_expand` and `final_result` as a Linux feature
     gap rather than a corpus gap. (First pass wrongly called it Windows-only: a
     regex requiring the nbsp and the `:` on one line missed macOS, whose
     implementation spans the two blocks above. Third time a narrow pattern
     misled me in this item — measured again before recording.) ·
     ~~star/magic-key triggers~~ — **done: 3 vectors.** The
     load-bearing one is `backspace_count = 3` for trigger `"td★"`: the star is
     **one codepoint and three UTF-8 bytes**, and a harness reaching for a byte
     length would say 5 (probed — claiming 5 fails Linux and macOS). The third
     pins a rule that existed only as a comment: `is_word_char` treats **every**
     non-ASCII codepoint as a word character, so a word-boundary trigger typed
     straight after the star is blocked. Defensible rule, surprising consequence,
     and until now "improving" `is_word_char` to consult Unicode categories would
     have kept accented letters working while silently changing the star. ·
     `case_conform`,
     `is_case_sensitive_strict` (**1 302 entries use it**, and the figure is exact —
     1 300 in `magickey.toml`, one each in `autocorrection.toml` and
     `rolls.toml`). **Now documented, and the divergence measured:** the flag is
     implemented in **Windows only**, where it becomes AutoHotkey's `C`
     hotstring flag. macOS and Linux read the same shared TOML and have **zero**
     production references to it, so all 1 302 entries match case-insensitively
     there. The consequence is behavioural: `"OUi" → "Oui"` exists so that typing
     `oui` does NOT autocorrect, and on two of three drivers it does.
     Not fixed here on purpose — implementing it changes the matching path of
     both engines, and the vectors that would make that safe are the very thing
     this item asks for. `test-hotstring-flag-support-per-driver.cjs` records
     which driver honours which flag and fails in both directions: a driver
     gaining support (good news, update the record) and a flag declared in shared
     data that no engine reads at all), the
     NBSP typographic rule, ~~the buffer cap~~ — **done: 3 vectors**, each
     measured against the real engine before being written down. A 257-codepoint
     trigger never matches, one of **exactly 256** still does, and a 300-codepoint
     buffer still matches on its tail because eviction drops the *oldest*
     codepoints. The boundary vector is the load-bearing one: an off-by-one in
     the eviction loop breaks it while leaving the 257 case green. Both
     implementations declare the same 256 independently
     (`BUFFER_MAX_CHARS` / `HSE_MAX_BUFFER_LEN`).
     **Adding them exposed a wrong assumption**: the Windows harness asserted
     that a non-matched buffer must not end with its trigger, which held only
     because no vector had reached the cap — there the buffer *does* end with the
     trigger and the engine cannot see it. Now a second documented exemption
     beside the word-boundary one, read from the constant. ·
     ~~`case_conform`~~ — **covered as a negative: 3 vectors** pin that the
     default mode folds case (an all-caps buffer matches a lower-case trigger),
     that a folded match returns the replacement **verbatim** — the matcher does
     *not* conform case, so `case_conform` is a driver concern and this pins that
     it does not silently happen — and that folding does not bypass the
     word-boundary rule. **All three harnesses failed on arrival**, each
     asserting a matched buffer ends with its trigger *exactly*; true of every
     vector that existed, false of the fold. Now compared the way the vector
     declares itself. That is the **second** harness assumption a new branch
     broke in a row (the buffer cap was the first), so the pattern is recorded in
     `PROJECT_MEMORY.md`: a consistency check must model the matching rule, not
     assume the strictest one. ·
     consumed delimiters, ~~the
     `individual > section > file` priority levels~~ — **measured, and the Linux
     skip was too broad.** Of the 6 collision vectors, the shared engine
     genuinely decides **3** (length primacy via the longest-first sort,
     first-registered fallback, no-match); those are now replayed on Linux, and a
     probe reversing the sort is caught by them — nothing on Linux caught that
     before. The other 3 need priority, and **2 would pass by accident** if
     replayed naively, because their expected winner happens to be registered
     first: "just enable the rest" would read as Linux honouring priority when it
     is blind to it. The skip now **asserts its own premise** (the engine always
     yields the first-registered mapping) instead of `assert_true(true)`, so it
     fails the day priority arrives. Tautology ratchet 283 → 282. ·
     ~~`is_word` as a tiebreaker~~ — **it is a FILTER, not a tie-break**, and
     asserting it found a harness bug. Mid-word the word-bounded mapping is
     blocked, so the unbounded one wins in **either** registration order (both
     replayed, which is what makes it assertable); at a boundary both are
     eligible and first-registered wins, which is order-dependent and therefore
     deliberately not a vector. **Windows disagreed** — and it was the harness:
     the AHK collision replay registered every mapping with hardcoded flags
     `"*?"`, and `?` means *no word boundary*, so `is_word` was silently
     discarded for all six existing collision vectors. None of them used it as a
     discriminator, so nothing had noticed. Flags now derive from the mapping;
     probed by restoring the hardcoded pair.
     **Corpus hygiene, found while extending it:** every field a vector carries
     must now be read by a replay or documented — `test-corpus-fields-are-read.cjs`,
     74 fields across 16 corpora. One was genuinely inert (`notes` in
     `toml/coercion_vectors.json`). The guard's own development is the lesson: a
     consumer scan scoped to files named `*corpus*` reported **11** inert fields,
     all false, and the last survivor (`terminator`) turned out to be injected by
     all three **e2e** runners — a narrow reader scan over-reports, and each false
     positive invites deleting something load-bearing.
  **Item 2, measured in full — the framing was wrong.** It reads as a corpus
  gap ("extend the corpus to the branches measured as absent"), and half of it
  is not. Of the branches listed, **four are Linux FEATURE gaps**, where a
  correct vector fails because the behaviour does not exist:
  `auto_expand`, `final_result`, the NBSP typographic rule (all three
  implemented on Windows **and** macOS), and `is_case_sensitive_strict`
  (Windows only). Writing those vectors is the easy half; making them pass means
  changing the Linux matching path, which alters expansion behaviour for every
  existing Linux user's hotstrings — a decision, not a test.
  The genuinely writable branches **are now written**: buffer cap (3),
  `case_conform` (3), magic key (3), `is_word` as a filter (1), priority levels
  (3 replayed), plus corpus-field hygiene. **Twelve vectors, and every one of
  the six branches exposed a defect in the test infrastructure rather than in an
  engine** — two harness assumptions true only until a new branch existed, an
  over-broad skip hiding a coincidence that would have read as Linux honouring
  priority, a corpus field misdiagnosed as inert, a gate counting a settings
  panel as engine support, and a collision harness discarding `is_word` outright
  for all six of its vectors. That is the argument for item 2 preceding items
  3–4: generating a shared matcher core against harnesses in that state would
  have encoded their blind spots.
  3. Generate the single matcher core into both target languages, modelled on
     `codegen-terminators.cjs` — it already emits both targets in one run and is
     **the only part of the engine that has never drifted**.
  4. Close the eight measured divergences, notably: Linux **never** fires a
     non-`auto_expand` hotstring (its loader does not even read the field), has no
     case propagation and no collision priority, and its default magic key is `\`
     while the shared manifest says `★`.
  5. **LLM**: ~~prompt-builder constants from one JSON (5 hand-maintained copies
     today, already diverged)~~ — **the "already diverged" is stale, and the
     reason is worth keeping.** Measured: all **10** constants agree across the
     three declarations (shared Lua, shared JS, generated AHK), because the
     AutoHotkey copy became a **generator output** — which removed the copy that
     had drifted. What was left was three declarations agreeing today with
     nothing checking they still would; `test-max-tokens-single-source.cjs`
     covers exactly one of the ten, and only for backend adapters.
     `test-prompt-builder-constants-parity.cjs` now compares all ten across all
     three. Divergence here is unusually quiet: these shape a *prompt*, so a
     context window of 40 chars/word on one driver and 30 on another does not
     error, does not fail a test and does not look wrong — it just predicts
     slightly worse on one platform, indefinitely. Folding them into one JSON is
     still worth doing; the parity check is what makes the interim safe. ·
     route the **six** implementations of "POST a
     completion" through the `HttpClient` port — macOS-MLX already proves the port
     suffices; generate the settings map, which deletes
     `menu_persistence_contract.json` (436 l) and its two unwired Python
     validators. Note `menu_persistence_contract.json` documents that the two
     drivers write **different keys, units and types** for the same three settings,
     so a `config.toml` is not portable — normalising that is part of the job.
  6. **Metrics**: shared aggregation core (two ~1 330-line walkers whose function
     names map 1:1, one of which says in a comment that it "MIRRORS" the other);
     eight constants declared three times where the shared copy exists only to be
     shadowed; ~~the WPM formula written **seven** times~~ — **the divisor half is
     fixed.** Measured: the shared module already defined
     `DEFAULT_CHARS_PER_WORD` *and* the exact batch formula, its docstring even
     claimed macOS used it, and **macOS divided by a literal 5 in two places
     while Linux consumed the module correctly** — the shared copy existing only
     to be shadowed, precisely as this line predicted. macOS now calls
     `Metrics.compute_wpm_from_events`, verified equivalent on five sample pairs
     *before* substituting so the reported numbers do not move.
     `test-wpm-chars-per-word-single-source.cjs` bans the literal in Lua on every
     driver and freezes the **5** WebView copies, which cannot `require` a Lua
     module — generating a JS constant is the remaining half.
  7. **Remap**: a shared tap-hold IR + three emitters
     (`emit_kanata` / `emit_karabiner` / `emit_ahk`) — today only a kanata emitter
     parked in `_shared/`. And `_shared/tap_hold/defaults.toml` must become **one**
     namespace: it is currently two unrelated files in one, describing the same
     seven physical keys with different ids (`left_ctrl`/`left_control`,
     `left_alt`/`left_option`), different actions (`caps_lock` holds **ctrl**
     under `[tap_hold.*]` and **cmd** under `[hs_tap_hold]`; `tab` taps
     `alt_tab_monitor` vs `alt_tab_windows`) and a 2.9–5× different threshold
     (0.2–0.35 s per key vs a flat 1000 ms global); the AHK loader ignores every
     `[hs_*]` header and the macOS reader ignores every `[tap_hold.*]` header.
     **Found while measuring:** `right_ctrl` has **no macOS counterpart at all** —
     `[hs_tap_hold]` carries right_command/right_option/right_shift but no
     right-control slot, so the key that taps `one_shot_shift` on Windows and
     Linux is simply unconfigured on macOS. Now recorded in the gate's
     `KNOWN_UNPAIRED` so the list cannot grow silently.
     ~~Also: four documents claim "no runtime merge" while the code merges on
     every boot.~~ — **the documentation half is fixed**, and it was worse than
     "the code merges": the three loaders do not agree with **each other**, and
     each one's own comments claim it matches the others.
     *Windows* parses the shared defaults first and merges the user file on top
     **per key** — its docstring says "editing `defaults.toml` takes effect on
     every reload even when the user file exists". *Linux* reads the same
     sections but lets a user file **replace** them wholesale, describing this as
     "mirroring the other drivers", which is the opposite of Windows. *macOS*
     reads `[hs_*]` in a **module body at require time**, unconditionally, with no
     user file for those sections at all.
     Against that, `SCHEMA.md` — the config-schema contract — said in three
     places that the file is "a generation template only", that the per-driver
     copy is "the complete config", and that "the shared file is never read again
     at runtime"; its own header repeated it. So a maintainer tuning a threshold
     would believe the edit could not reach an installed driver, when on Windows
     and macOS it reaches every one at the next reload. Both documents now state
     the three real lifecycles, and `test-tap-hold-defaults-lifecycle.cjs` fails
     if any document re-asserts the old claim while a loader still reads the file,
     if a loader stops reading it without the docs changing in the same commit, or
     if the two namespaces stop covering the same physical keys.
  8. **Tooltip**: wire the 1 483 lines of shared JS **as an oracle** (vector
     generator + conformance harness), not as runtime. ~~Today the gate named
     "tooltip corpus parity" requires neither JS module it claims to compare~~ —
     **fixed, and the reason it could not was systemic.** `package.json` declares
     `"type": "module"`, which makes every bare `.js` file ESM — so a file whose
     only export mechanism is `module.exports = {…}` exports **nothing**:
     `require()` rejects it and `import()` returns an empty namespace, silently.
     Measured across `_shared/`: **32 modules are in that state**, including
     every `core/ports/*.spec.js` and the entire `modules/tooltip/` set.
     The port specs escaped the consequences only because
     `codegen-contracts-json.cjs` carried a **private** CommonJS-in-ESM loader.
     The tooltip modules had no such consumer, so `layoutTestVectors()` and
     `dequeueTestVectors()` — the declared source of truth — were unreachable
     from every tool in the repo. The gate checked that the JSON had 6 and 3
     vectors of the right field types; those numbers came from the JS once and
     had become plain literals.
     **Follow-up, and the guard caught its own author.** A gate now refuses any
     `_shared` module that exports via `module.exports` and has no loader — the
     state that made the tooltip modules unreachable. Its first version passed
     with a deliberately-planted orphan sitting in the tree: its "is this
     directory swept?" heuristic matched **its own source**, because the file
     names the spec-only modules and contains the very tokens the heuristic
     looked for. Tightening it to recognise the one real sweep by name then
     surfaced **three more** unreachable modules the loose version had hidden
     (`Expander.spec.js`, `GestureRecognizer.spec.js`, `ProfileSelector.js` —
     cited only by `SPEC.md`/`SCHEMA.md`, executed by nothing). Six are now
     recorded as specification-only with reasons, which is a legitimate role;
     being unread because of a module-system detail is not, and the two are
     indistinguishable from outside unless written down.
     The loader is now `tools/lib/load-cjs-module.cjs` (one copy, and it throws
     rather than returning `{}` when a file exports nothing — the empty result
     being the failure itself), the codegen uses it, and the gate now compares
     **ids, order and every expected value** field by field. Verified by drifting
     one coordinate: the old gate saw nothing, the new one names the vector and
     the field.
     Still open on this item: the
     ~~macOS test replays a clone defined inside the test file instead of the
     renderer~~ — **fixed, and it was concealing a real divergence.** The file
     defined its own `CONSTANTS`, `clamp_to_screen` and `resolve_position` and
     replayed all 6 vectors against that, while its docstring claimed it pinned
     the math "so any divergence in clamping or positioning is caught
     immediately". It pinned the clone: the renderer could have drifted
     arbitrarily and every vector would still have passed.
     The maths was inline in `M.render()`, tangled with `hs.window`/`hs.screen`,
     which is why it had never been extracted. It is now
     `renderer.compute_position(anchor, canvas, screen_frame)` — those two are
     its only OS-derived inputs — and the test drives the real function.
     Behaviour-neutral: the suite sat at 3 768 before and after.
     **What the clone was hiding:** it branched four ways, faithfully mirroring
     the shared JS (`caret`/`screen` → caret offsets; `input_box`/`window` →
     centred with a bottom-flip; anything else → centre-bottom). The renderer
     branches **two** ways: `caret`, and everything else as a window anchor. So
     the renderer diverges from the declared source of truth on `type ==
     "screen"` and on unknown types — and the test that promised to catch
     exactly that could not, because it never loaded the renderer.
     Left as-is deliberately: `resolve_anchor()` produces only `caret`,
     `input_box`, `window` or nil, and for all four the renderer agrees with the
     shared implementation. The divergence is **latent, not live**, and adding
     the missing branches would add dead code. The behaviour is pinned as it is,
     with the reason recorded in the test.
     Verified by drifting `caret_offset_x` 6 px in the renderer: two corpus
     vectors now fail by name and axis, where before nothing would have. ~~and the AHK test never compares the 6 golden values~~ — **now it does, and
     the reason it could not is the interesting part.** The test loaded the JSON,
     asserted that every vector *had* an expected x and y, and never compared one
     — so a Windows clamp that disagreed with the shared implementation would
     have passed every assertion in the file.
     It was not laziness: `_TooltipClampToScreen` reads the real monitor work
     area via `MonitorGetWorkArea`, so nothing could drive it with the corpus's
     synthetic `screenFrame`. The maths is now split into `_TooltipClampRect`,
     which takes the bounds as parameters, with the OS-reading wrapper
     delegating to it — behaviour-neutral, suite unchanged at 3 815 before the
     new tests.
     All 6 vectors are replayed: re-clamping each expected position must be a
     **no-op**, since the shared clamp is idempotent and any difference in the
     Windows formula or margin moves the point. A second test drives positions
     deliberately outside the corpus frame, because the idempotence check alone
     would pass on a clamp that did nothing at all. Verified by drifting the
     right-edge term 4 px: both tests fail, naming the vector and the axis. Two
     ~~`[positioning]` constants never reach Windows, with three comments
     asserting the opposite.~~ — **measured, and the shape differs from the
     note.** Of the 7 `[positioning]` keys: three are genuinely shared
     (`caret_offset_x`, `caret_offset_y`, `max_caret_height`); two are per-driver
     **by name** and so not divergences at all (`window_bottom_inset_ahk`,
     `window_bottom_inset_hs`); `window_offset_y` is **macOS-only**, though its
     comment describes it as a general layout rule with no caveat; and
     `anchor_cascade` is read by **no driver whatsoever**.
     `anchor_cascade` is the one worth reading twice. It is honestly labelled
     "(informative — drivers implement this)", so nobody consuming it is not a
     bug — but it is a four-element array, and the comment three lines above it
     says *"AHK adds a step between 2 and 3: mouse cursor coordinates"*. The data
     is therefore **already wrong for one driver according to its own
     documentation**, and no code path could ever notice. An informative constant
     that contradicts the prose beside it is worse than prose alone.
     Linux reads none of the seven: its tooltip renderer shares no positioning
     maths.
     Not "fixed": making Windows read `window_offset_y` would move where tooltips
     appear, and the separate bottom-inset constants exist precisely because the
     two anchors differ — a placement decision, not a cleanup.
     `test-tooltip-positioning-reach.cjs` records which driver reads which value
     and fails in both directions, so the asymmetry stops being invisible.

- **Lot 9 — the tests.** Honest ceiling: `meta/` directories alone are **84 956
  lines (44 %)** and each asserts on one driver's source text; the plan must not
  promise the suites mutualise like the drivers. Achievable: **≈ −11 500 lines**.
  | Target | Today | After | Mechanism |
  | --- | ---: | ---: | --- |
  | Corpus consumers (16 corpora, 258 vectors) | 9 122 | ~1 900 | one JSON replay schema per corpus + a ~120-line generic runner per driver |
  | Port contract vectors (129) | 2 001 | ~700 | generate `_shared/tests/corpus/ports/<Port>_vectors.json` from `contractTestVectors()` |
  | e2e harnesses | 1 319 | ~750 | one corpus-driven harness that fails loudly on a missing corpus |
  | ~~Lua assertion library~~ **done** | 737 | 767 | one shared `test/assertions.lua`; see below |
  | Convention invariants | 1 594 | ~450 | one `.cjs` gate per invariant — **the shared linter already IS that gate**; see below |
  | Port presence/compliance | 1 575 | ~500 | one JS gate over `contracts.json` × the three `adapters/` trees |
  **Found while widening the convention scan — `gsub` was returning two values in
20 places.** `return x:gsub(...)` hands the caller the string *and* gsub's
replacement COUNT. Measured in the interpreter rather than assumed, because the
intuition is backwards: `string.format(fmt, x:gsub(..), y)` truncates to one
value (safe) and `string.format(fmt, y, x:gsub(..))` expands but format ignores
extras (also safe) — while `{ first, x:gsub(..) }` gives `#t == 3` and a bare
`return` propagates the count to every caller. The two shapes that look most
dangerous are fine; the innocuous-looking one is what leaks.
The codebase already knew the fix — **16 sites used `return (x:gsub(...))` and
20 did not.** A convention applied to 44 % of its sites is not a convention, and
the difference is invisible in review because the parentheses read as
decorative. All 26 single-line cases are wrapped (both suites unchanged at 3 768
and 1 370), 23 multi-line ones are left for hand review rather than rewritten
mechanically, and `test-lua-gsub-single-return.cjs` holds the line.

**Convention invariants — "Linux gains 6 it does not have" is stale; the real
gap was elsewhere.** `tools/lint/lint-conventions.js` is already the one `.cjs`
gate per invariant, and it already scans the Linux tree (a previous fix widened
it from macOS-only). What it did **not** scan was `adapters/` on macOS and
Windows — `linux/adapters` had made it into the list and the other two had not,
leaving **45 files, the entire port layer of two drivers, held to no convention
check** while the third was held to all of them. A scan set assembled by hand
drifts exactly that way, one directory at a time, and the gap is invisible
because the linter still reports a large file count and passes.
Widening it surfaced **36 real violations** across 10 adapter files — banner
misalignment, wrong blank-line counts before major sections, an unbalanced rule
line. `npm run fix:all` cleared most; the residue was a five-line banner whose
*outer* rule pair the autofixer leaves alone, in three files.
The last one was the linter's own bug: the AHK backtick-quote rule matched the
whole FILE, so `shell_runner.ahk` was flagged for a **comment documenting a past
bug** involving that very escape — the rule firing on prose explaining the
hazard it exists to prevent. It is line-based and comment-aware now, and reports
a line number, which the whole-file form could not.
**Lua assertion library — consolidated, and the line count went UP.** Measured
body by body: **six of the seven** assertion functions were byte-identical once
whitespace was normalised, and the seventh (`assert_throws`) differed by a single
**comment line** — so the backlog's "62 lines, all comments, banners and
declaration order" is exactly right. They now live in
`_shared/lua/test/assertions.lua`, built per harness.
The totals moved 737 → 767 lines, and that is the honest result rather than a
disappointing one: the shared module carries the rationale the two copies never
had, and consolidation was never about line count — it was about an `assert_eq`
that could be fixed on one driver and not the other, with every other test's
credibility resting on it.
**One regression found by checking, not by the suites.** Both suites stayed green
(1 370 and 3 768) while assertion failures started reporting
`assertions.lua:57` — the assertion library's line instead of the failing test's.
`fail_msg_for` skips stack frames matching the harness's own filename, and the
newly-shared file was not in that pattern. Diagnostics silently pointing at the
wrong file is invisible to a passing suite and only shows up when someone is
already debugging. `fail_msg_for` now takes a LIST of patterns, and
`assertions.build()` takes the harness pattern and adds its own — putting that
knowledge in the shared module rather than in each caller.
Also: **assertion argument order is inverted** between AHK (`AssertEqual(expected, actual)`) and Lua (`assert_eq(actual, expected)`) across **1 587 sites** — still open.
~~`AssertEqual` is **case-insensitive** (AHK v2 `!=`), so `AssertEqual("BTW","btw")` passes~~ — **fixed**, and `AssertContains` had the identical defect (`InStr` defaults to a case-INSENSITIVE search, so an upper-case needle was satisfied by lower-case output). Both now use the case-sensitive forms (`!==`, `InStr(…, true)`).
  **There were no reds to triage: 3 803 passing before, 3 803 after.** Not a
  disappointing result — a revealing one. Case is the *subject* of large parts of
  this suite (case propagation, `is_case_sensitive_strict` on 1 302 entries,
  trigger matching, layout key names), and not one of those assertions had ever
  exercised the distinction it was written to make; an implementation that
  lower-cased its entire output would have gone green.
  It also means the suite cannot demonstrate its own bug, so the operator would
  silently regress the day somebody "simplified" it back. `meta/test_assertions_are_case_sensitive.ahk`
  is the only thing preventing that, and it pins the four behaviours that must
  NOT change with the narrower operator — verified against the interpreter first:
  numbers still compare numerically (`1 == "1"`, `1 == 1.0`, `255 == "0xFF"`),
  `""` stays distinct from `0`, `true` stays `1`, objects stay identity-compared. Skips become data (`_shared/tests/conformance/manifest.json` with `{status, reason, tracked}`) — **and the AHK half turned out to be nearly done already.** Of 16 `AssertTrue(true` matches in the Windows suite, **13 are comments** recording placeholders somebody has already replaced; only **3 were live**, and all three are now real assertions rather than a ledger entry:
`test_personal_toml_editor.ahk` claimed *"personal toml roundtrip must preserve complex French input"* — the single most load-bearing property in a French-first product, asserted by nothing. It now checks that accents pass through untouched, that quotes and backslashes are escaped, and that the escape ORDER holds (escaping the backslash after the quote would double-escape the one the quote just introduced).
Its sibling claimed *"personal toml editor must respect full pause silence"*; the checkable half at that layer is that the serialisation helpers emit nothing, since a helper that typed or wrote would fire during a pause.
`test_tap_hold_loader.ahk` claimed *"tap_hold must respect full pause silence"*. That guard is real — four `A_IsSuspended` checks in `modules/tap_holds/constants.ahk` — so the test now pins all four dispatch entry points by name. Neutralising one makes it fail, verified.
Tautology ratchet **49 → 46**. The remaining Linux ones are genuine capability skips (`menu_builder not available`) and are what the `{status, reason, tracked}` ledger is actually for. ~~Two macOS files (593 lines) replay 36 vectors against a **reimplementation
defined inside the test**~~ — **measured, and the diagnosis was wrong in the way
that matters.** `test_adapter_contract_vectors.lua` loads the **real** adapters
through `load_with_stubs` and calls them directly; it is not a reimplementation,
and its 100 tests are genuine behavioural coverage.
The real defect is narrower and was hiding behind that description: the
docstring promised *"When the JS vectors are updated the Lua mirrors must be
updated to match — the tests will fail until they are synchronised, making drift
immediately visible."* **Nothing made that true.** The file reads no `.spec.js`,
so a vector changed on the JS side leaves the Lua mirror passing against the old
expectation. Measured: **138 vectors across 20 ports, 61 referenced here by id**
— 77 could drift unnoticed, and TooltipRenderer (0/12), Notifier (0/7) and
TimerScheduler (0/7) had *no* traceable vector while their sections looked fully
populated.
The docstring now says what is actually true, and
`test-port-vector-traceability.cjs` ratchets the link at 61/138 so it can only
improve — adding an id to a test is a one-line change. A requirement of all 138
would have failed on arrival and been deleted within the week. ~~8 files under `windows/tests/` are invoked by nothing, including the **only**
Windows consumer of `process_prediction_vectors.json` (17 vectors, zero CI
coverage).~~ — **measured: both halves were wrong, and the residue was worth
finding.** `test-ahk-test-coverage.cjs` already proves all **838**
`test_*.ahk` files are reachable from `run_all.ahk`. Only **two** files sit
outside it, and one — `e2e/run_e2e.ahk` — is a separate runner CI invokes
explicitly. `process_prediction_vectors.json` is fully covered: its Windows
consumer is `tests/unit/test_llm_parser.ahk`, which IS in `run_all.ahk` and
registers one test per vector — **all 17 execute**, confirmed by counting them
in a suite run.
The genuine orphan was **one** file: `startup/feature_state_boot_smoke.ahk`,
which nothing invoked. It escapes the coverage gate on a technicality — that
gate scopes to `test_*.ahk` and this is named `feature_state_boot_smoke.ahk` —
and it cannot be `#Include`d into `run_all.ahk` without destroying its purpose:
it boots the production include graph **in its own process with no stubs**,
so a dependency or boot-order failure surfaces as a non-zero exit code.
It had never run. Invoking it by hand shows why that matters: with no argument
it throws `expected exactly one startup fixture name` and exits 1 — which from
outside is indistinguishable from a broken boot, so a naive CI wiring would have
produced a permanent red for the wrong reason. It takes a fixture name; all
**four** (`parsed`, `missing`, `malformed`, `non_map`) pass.
`test-feature-state-boot-smoke.cjs` now drives all four and fails if the harness
stops handling one — a fixture silently removed is coverage silently lost. It
skips loudly, rather than passing, on machines without AutoHotkey. 20 test files are named after a date or a plan phase (~2 900 lines).

- **Lot 10 — pruning.** Port the macOS reachability gate to Windows and Linux, then
  delete the **3 101 lines of dead adapter code** (12 of 21 Windows adapters and 11
  of 21 Linux ones have no production caller; the 11 Linux files come from a single
  commit written to green a presence gate). Each deletion carries the measured
  zero-consumer proof in the commit body. Shrink `contracts.json` to the ports with
  real traffic and supersede ADR-001 with the measured reality; honest demotion
  candidates: `AppLauncher`, `Crypto`, `Storage`, `ProcessLifecycle`,
  `MouseControl`, `TooltipRenderer`. Extend both purity ratchets to `ui/` and the
  entry point and ~~add the unwatched AHK families~~ — **done.**
  Measured with the enforcing counter itself: **1 064 lines across three trees**
  (modules+lib 773, ui 280, entry 11), broken down as Binding 330, Timer 277,
  GuiMenu 219, KeyState 105, Window 74, Process 59. The earlier estimate of 874
  was low, mostly on the binding family.
  Kept as a **second, separate** ratchet rather than folded into the OS-call one,
  because the two mean different things: `DllCall`/`COM`/`FileIO` are impurity
  whose target is zero, while a keyboard driver legitimately binds hotkeys and
  arms timers — telling it to stop would be telling it to stop being a keyboard
  driver. What makes those families worth bounding is that they are where the
  driver's *behaviour* is declared, and 312 binding lines plus 193 timer lines in
  modules+lib is behaviour spelled out in code that the other drivers express as
  manifest rows. The number should fall on its own as Lot 6 migrates them.
  **A cross-check earned its keep here:** the same tally written in another
  language counted `ui` at 271 where the AHK counter reports 280, because AHK's
  `InStr` is **case-insensitive**. In this counter that is correct rather than a
  bug — AHK resolves function names case-insensitively too, so `gui(` and `Gui(`
  are the same call — but a baseline taken from the case-sensitive tally would
  have frozen a number the enforcing rule can never produce, and the ratchet
  would have been red on arrival. Every baseline is now read from the counter
  that enforces it. (Same property, opposite verdict, as the `AssertEqual` fix
  earlier in this file's history: case-insensitivity was wrong there and is right
  here, which is exactly why it has to be decided per call site rather than
  assumed.) Route the Linux module shell-outs through
  `shell_runner` — it exists, its docstring explains exactly why
  (`string.format("%q")` is a Lua literal quoter, not a shell one), and **no
  module requires it** (the `adapters/` do; in `modules/` the measured count is
  **56 sites across 15 files, 0 requiring it**).
  **Measured, and the quoting is mostly not the problem.** 25 of the 28
  interpolating sites already hand-roll the correct `gsub("'", "'\''")` — the
  same four-character escape written out 25 times, which is duplication, not a
  defect. Only **3** interpolate unescaped, and 2 of those quote at the call site
  instead (`gestures/manager.lua`, `hotstrings/injector.lua` — both only append
  redirection to an already-quoted command).
  ~~The third was a live bug~~ — **fixed.** The tray Reload item ran
  `"kill -HUP " .. tostring(os.getpid and os.getpid() or "$$")`, wrong twice
  over: `os.getpid` **does not exist in Lua**, so the guard always fell through
  to the literal `"$$"`; and `os.execute` runs its string in a NEW `/bin/sh`,
  where `$$` is that shell's pid, never the caller's. The daemon told a throwaway
  shell to reload, the shell killed itself, and the item logged
  `"Reload requested — sending SIGHUP."` while reloading nothing. It could not
  fail visibly — `os.execute` does not raise on a command that runs successfully
  and does the wrong thing, so any "does it crash?" test passes on it forever.
  Reload now goes through `ctx.on_reload` into the daemon's own reload path, the
  same shape the quit item already used: no subprocess, no signal, no pid. The
  regression test asserts `os.execute` is **not reached**, which is the only
  assertion that could have caught this shape.
  Found while measuring: the test's search had to be made non-recursive, because
  the Hotstrings submenu carries its own hardcoded-French `"Recharger les
  hotstrings"` entry that a recursive match finds first — the first cut passed
  against the wrong item. That label is one of the 101 tracked in Lot 5(3). ~~One `npm run gen` regenerating everything
  deterministically in a single Node process, plus `npm run gen:check`~~ —
  **done**, with one deviation from the plan and a measured reason for it.
  `gen:check` does **not** write to a temp dir: no generator accepts an
  output-dir override (`build-features-manifest.js` writes hardcoded paths, and
  so do the other eleven), so a temp-dir check would mean adding a parameter to
  twelve scripts to gain nothing snapshot-restore already gives. Instead
  `tools/build/generators.cjs` is a registry — **12 generators, 20 distinct
  outputs, each generator declaring the files it writes** — read by both
  `npm run gen` and the no-drift gate, so "what gets regenerated" and "what gets
  checked" cannot disagree.
  **The measurement that forced the registry:** the drift gate had just been
  fixed from a hand-written 2-file list to a scan of the three `_generated/`
  trees. That is still a guess, and wrong for generators writing outside them —
  `build-domain.cjs` writes twelve files, two of them
  (`_shared/lua/keymap/terminators_catalogue.lua`,
  `_shared/modules/menu/menu_manifest.json`) nowhere near a `_generated/` folder,
  and `gen-architecture-diagram.cjs` writes `docs/architecture.md`. Adding those
  generators to a directory-scoped gate would have silently overwritten those
  three in the working tree and never restored them — the identical bug, one
  layer up. Verified after the fix: editing `terminators_catalogue.lua` makes the
  gate go red **and leaves the edit in place**.
  Also worth knowing: `npm run codegen` was only ever `build:domain`, which
  covers most generators but not the metrics category aliases, the port
  contracts, the logger sub-file tables, the locale tables or the architecture
  diagram — so someone running the documented command and committing would still
  ship a stale file. `gen-all.cjs` additionally fails when a declared output does
  not exist after a full run, so the registry cannot quietly fall behind reality.
  This also fixed by construction the fact that
  ~~`test-features-manifest-no-drift.cjs` **silently rewrites three files it does not
  guard**~~ — **fixed**, and the real count was **four of six**, not three of five:
  the generator writes a features manifest AND a `config_template.toml` for each
  of the three drivers, and the guard listed two files. The consequence was worse
  than the missed drift. Appending a line to
  `linux/_generated/config_template.toml` and running the guard printed
  `"[OK] … no drift"` and left `git status` **completely clean** — the
  uncommitted edit was silently reverted by the test itself. A test that discards
  your working-tree changes and then reports success is worse than no test,
  because you trust it. The guard no longer names files at all: it snapshots
  every file under all three `_generated/` trees (13 today) and compares each
  one, so a seventh generator output is covered without anybody remembering.
  `test-drift-guard-covers-every-output.cjs` perturbs each previously unguarded
  output for real and asserts both halves — the guard goes red, and the edit is
  still there afterwards. A static check ("does the guard mention
  config_template?") would pass on a guard that mentions it and still restores
  nothing. One
  `_generated/` convention: same first line, same banner, no timestamps, a
  generated `README.md`, and runtime-written files moved to `_runtime/`.

### 0.6 Gates to build

`test-driver-tree-parity.cjs` (I1) · ~~`test-shared-root-resolvers.cjs` (executes
every `_shared` resolver)~~ **done** · `test-menu-parity.cjs` (I3) — **the
`action_id` ↔ handler half is done**
(`test-menu-action-handler-bijection.cjs`): every `action`/`dynamic` row the
manifest declares for a platform must have its id named in that driver. Windows
is held at **zero** unresolved and cannot regress; macOS (20) and Linux (27) are
frozen. The label-tree diff half is **not** built, and deliberately: the manifest
carries **no `linux` platform value anywhere** — 27 rows are `[ahk]`, 19 `[hs]`,
2 both — so Linux "sees" 76 rows only because an unrestricted row defaults to
every platform, while `menu_builder.lua` builds its 97 rows by hand. Diffing the
three trees today reports that migration, not a defect. Note the bijection check
is a **necessary, not sufficient** condition: a tighter "id bound to a callable"
rule was tried and rejected because it flagged `"tap_hold_keys", _TH_DynKeys` —
a function reference rather than a lambda — and a gate that flags correct
bindings demands rewriting working code. · the "no menu row outside
the renderer" ratchet~~ **done** — `test-menu-rows-outside-renderer.cjs` freezes
the bypass count per driver: **windows 222, macos 301, linux 3**. The three
drivers are in completely different places — Linux already builds 97 of its 100
rows inside `menu_builder.lua`, Windows 8 of 230, macOS 29 of 330 — so banning
the bypass today would mean rewriting two menu layers in one change. A ratchet
lets the migration proceed row by row while nothing new accumulates. Each driver
gets its **own** row predicate: one predicate for all three is how a first
attempt produced meaningless numbers (`.Add(` matched every AutoHotkey object,
`title =` matched dialog titles, and Linux scored 6 because it does not use
`label =` at all). Floors on the total catch a predicate that stops matching,
which would otherwise drive the bypass count to zero and pass. ·
~~"every manifest array key has a reader"~~ **done** — a
guard existed but could not catch the three live cases: it checked **top-level
keys only** (so `i18n_dynamic`, with zero readers repo-wide, was never examined)
and counted a mention in a **comment** as a reader — `manifest_menu.ahk` names
both dead sections in one. It now checks entry fields too, ignores comments, and
excludes tests, since a test naming a section proves the section exists, not that
anything renders from it. The three declarations it surfaced were each duplicated
in AutoHotkey source and are now the actual source of the render; `group_label`
moved the last hardcoded piece (the V1 submenu titles) into
`manifest.toml [menu.*]`. ·
`test-logger-scalars-single-source.cjs` · ~~`test-locale-catalogue-complete.cjs`~~
**done** — all 21 catalogues carry en.json key-for-key (2 339 today), no value
renders blank, each declares its own `_meta.locale`/name/flag. Four locale gates
already existed and **none compared two catalogues**: the translations audit
walks the code and checks each key exists in `en.json` alone, the order gate
matches the file set against `locale_order.json`, the names gate checks every
ordered locale is named. So "a key added to `en.json` exists in all 21" was held
by discipline, not by a gate — and the fallback chain hides a breach, since a key
missing from `de.json` renders the English string with nothing logged. A
placeholder-parity rule was measured and **rejected**: it fires on correct work
(Czech drops the `%s` that only pluralises an English noun; `{pct}% du focus`
reads as a `% d` conversion to a regex and is a literal percent sign). Lua's
`string.format` tolerates surplus arguments, so there is no defect to gate. ·
~~`_shared/tests/corpus/logger/behaviour_vectors.json`~~ **done, in the file that
already existed** — `_shared/modules/logger/test_vectors.json` holds 17 vectors
and was replayed by **two suites out of three**; its own header said "shared by
AHK and Hammerspoon test suites". Linux now replays all 17 through the shared
logger core. Since Linux and macOS run the *same* core, a divergence there could
only come from the sink, level or timestamp function the driver installs around
it — the layer each driver owns and nothing was checking. The per-vector
overrides moved from `message_hs`/`expected_hs` to `message_lua`/`expected_lua`:
the difference is the **language** (Lua's `%s` vs AutoHotkey's `{1}`), not the
driver, so keying them by driver name was this backlog's own root cause and left
no name a second Lua driver could use. A false docstring was corrected too —
`test_shared_logger.lua` claimed to exercise the corpus while never opening the
file. ·
~~`_shared/tests/conformance/manifest.json` + runner~~ **done** — the nine
skipped cases across the three suites are now seven ledger rows, each naming a
status that carries the distinction the prose lost: **5 `platform_gap`** (all
Linux — tap-hold, LLM parser, prompt builder, locale cascade, tooltip layout),
**1 `by_design`** (hotstring collision resolution, which the shared engine
delegates to its caller), **1 `environment`** (`stat(1)` for mtime detection —
skips on one host, runs on another including CI). Each site names its row
inline, so the link is exact. `test-conformance-skips-declared.cjs` fails on a
skip with no row, a row nothing references (a stale excuse claims coverage is
missing when it may have been restored), a `platform_gap` with nothing tracking
the work, and a row missing its reason. It does **not** try to verify a reason is
still true — that is a statement about the product, not something a regex can
check. · boot-manifest parity gates ·
~~"no hand-written duplicate of shared logic"~~ — **measured, and not built.**
A name-based lint (a driver file sharing a name with a `_shared/lua` module)
finds **36 candidates and all 36 are legitimate**: most are `init.lua` collisions
that exist in every module directory, several are documented delegation shims —
`macos/lib/toml/codec.lua` is literally `return require("toml_codec")` — and the
substantial ones are OS-specific wiring *around* shared pure logic. Both
`text_migration.lua` copies require the shared `keylogger.text_migration` for the
plan and add only their driver's I/O, which is the intended architecture rather
than a violation. Separately, **every one of the 38 shared Lua modules is
required by name somewhere** (a first pass reported `linux.tray_protocol` as an
orphan; it is required as `pcall(require, "linux.tray_protocol")`, which the
regex missed). Detecting a genuine reimplementation needs semantic comparison,
not name matching, and the mechanism that actually enforces I5 already exists:
per-behaviour corpora replayed by all three suites, which is what the logger
corpus item above extended to its third driver.

### 0.7 Gates to extend (each hole measured)

**Done 2026-07-31:** `test-git-mv-resilience.cjs` (193 → 799 pins, all three
suites) · `test_jsstr_cr_escaped.ahk` (now discovers all 11 helpers from source;
the three that were still deleting `\r` are fixed — including the changelog
renderer, whose input is a GitHub release body, so it was never dormant) ·
`test-ahk-test-coverage.cjs` (walks `tests/` at any depth; no orphan was hiding
there, so prevention rather than a fix) · **new** `test-ahk-runners-are-invoked.cjs`
(three runners were referenced by nothing; two carried ten tests that had never
run, one of which had rotted out of the code it stubs) ·
`test-no-pinned-source-reads*.cjs` (now ratchets the PINS, not the files: AHK
**326** pins behind a file count of 16 — `_DriverFuncBody` takes a symbol, not a
path, so one call exempted every raw path beside it; macOS 40 behind 31) ·
`test-dev-tool-paths.cjs` (now rejects a hardcoded checkout anywhere under
`tools/`; the 2 absolute paths were both in the prediction-corpus generator,
which therefore ran on exactly one machine — fixed).

**§0.7 is closed.** The remaining nine gates were extended the same day. Each
one is listed with what it was blind to and what the blindness was hiding —
because in five cases it was hiding a live defect, not just a coverage gap:

| Gate | Was blind to | What that hid |
| --- | --- | --- |
| AHK purity ratchet | `ui/` and the entry point | 138 uncounted OS calls, 108 of them `DllCall` in the WebView2 hosts; one combined total also let one tree's improvement pay for another's regression. Now three frozen numbers |
| macOS purity ratchet | `macos/ui/` and `init.lua` | 630 `hs.*` + 65 io/os lines. Its own history comment says "ui/ is outside this scan" twice, both times *raising* the baseline for code moved out of ui/ — the ratchet could be satisfied by moving OS calls to where nobody counts them |
| `test-webview-geometry-single-source.cjs` | 4 of 14 apps, all of Linux | **the macOS diagnostic opened at 700x600 while Windows opened it at the manifest's 740x560**; the macOS download window held its own 460x380 copy. Coverage now derives from the manifest, with reasoned exclusions |
| `test-webview-teardown-order.cjs` | 6 of 13 hosts | and for the 7 it watched it compared the FIRST occurrence of each handle — the top-of-file declaration — so **deleting the teardown release entirely still passed** |
| `test-config-schema.cjs` | the Linux template; a missing file "skipped" | the Linux template violates the schema (no `[script]`), now pinned with its reason. Drivers are discovered by their `adapters/` tree |
| `test-updater-constants-single-source.cjs` | Linux, and both `_DEFAULTS_FALLBACK` tables | a drifted fallback queries the wrong repo and reports "no update" forever, silently — the copy least likely to be exercised was the one least likely to be caught |
| `test-menu-labels-single-source.cjs` | anything it did not name | **two macOS menu files carried their own `fmt_count`**. Now an exclusion ratchet: the AHK copies are pinned, and a pin whose duplicate is gone fails too |
| `test-priority-parity.cjs` | use sites; Linux; the cascade order | **Windows defaulted a priority-less candidate to 50 (personal) where macOS uses 10 (common)** — the two drivers ranked the same collision differently |
| `gen-architecture-diagram.cjs` | Linux | 22 adapters absent from the map of the system. Drivers are discovered; every one gets a subgraph |
| `test-dev-tool-paths.cjs` | everything outside `tools/dev/` | the prediction-corpus generator ran on exactly one machine |

### 0.8 Gates to retire — after migration only

`macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua` (after lot 5.4) ·
`test_menu_top_level_drift_gate.{lua,ahk}` (once the tail is manifest rows with
registry-validated ids — **and a Linux twin exists first**) ·
`linux/tests/unit/meta/test_port_adapter_presence.lua` (9 hardcoded names, 13
behind) · `windows/tests/COVERAGE.md` and `macos/tests/COVERAGE.md` (hand-written
inventories, already stale — `docs/TESTING.md` states the right principle: the
inventory of checks is the run itself).

### 0.9 Smaller carried-over items — **all delivered 2026-07-31**

Kept only as a pointer to what now guards each one, because every fix here was a
gate that had a blind spot rather than a one-off correction:

| Was | Now guarded by |
| --- | --- |
| Lua conventions scanned macOS only | `lint-conventions.js` walks all three drivers + `_shared/lua`, and FATALs on an empty tree |
| `_shared/core` + `_shared/modules` outside the header audit | both trees in `audit-file-headers.cjs` |
| banner rule-line count never checked | `checkBannerAlignment` walks the whole run; the fixer inserts and never deletes |
| 78 space-indented production files | converted; `git diff -w` was empty |
| dead `codegen-prompt-builder-hs.cjs` | deleted; the asymmetry is explained in `macos/_generated/README.md` |
| dead plan tokens (`P5 refactor`, `P0 SSoT`…) | `test-no-plan-refs-in-source.cjs` now matches bare tokens, not only `P#.#` |
| glossaries disagreeing with the code | `test-glossary-matches-code.cjs`, deriving the port list from disk |

### 0.10 Risks

- **R1** — the tree move silently disables 220 assertions. Entirely mitigated by
  lot 2.1; do that first.
- **R2** — the macOS stubs stop intercepting unless the `lib.` → `infra.` rewrite
  touches production and the ~1 942 test sites in one commit.
- **R3** — the entry-point rename is the most dangerous move in the programme for
  near-zero payoff (7 consumer families pin those names). Defer it.
- **R4** — `_shared/` internal moves are **not** covered by the per-layer SSOT;
  several sites bypass the resolver, so only the suites catch a rename. Every such
  move needs a test asserting the resolver found a **real file**.
- **R5** — never weaken a ratchet to permit a move; a pure relocation bump carries
  an explicit "relocation, not new OS calls" note in the commit.
- **R6** — the hotstrings corpus would today reject a correct implementation
  (`backspace_count`); fix the contract before generating the matcher.
- **R7** — land the "no hand-written duplicate" gate last: it generates findings,
  and a finding-generating gate landed mid-refactor is noise.
- **R8** — line numbers here are true as of 2026-07-30. Re-read the site before
  editing and match by symbol, never by line.

---

## 1. A real user-facing bug

### Linux: the daemon never grabs the keyboard — this is the root cause of `abcd` → `acd`

`static/ergopti_plus/linux/adapters/keyboard_hook.lua:65` defaults `_intercept`
to false, and `:396` only flips it when the caller passes `intercept = true` —
which `ergopti_hotstrings.lua` does not. In observe mode the daemon runs
`libinput debug-events`, which never takes `EVIOCGRAB`, so **every physical
keystroke reaches the application in real time regardless of what the daemon is
doing**. During the erase-then-type window of an expansion (~90 ms for six
characters via ydotool) physical keys interleave with the backspaces and the
synthetic text, and the result on screen is corrupted non-deterministically.

Consequence worth knowing before touching it: the plumbing added for this
(`keyboard_hook.get_mode()`, the injector's internal queue) is **dead code in
observe mode** — `inject()` blocks the thread, so the queue path is never
reached.

Flipping the default is not enough on its own. Intercept mode makes the daemon
the sole path to the application, so it must re-emit **every** event — modifiers,
control keys, key-repeat, releases — in order and without loss, or the keyboard
becomes unusable.

**The harness half is already delivered** (re-derived 2026-07-31):
`tests/unit/meta/test_keyboard_hook_intercept_passthrough.lua` drives a fake
evdev source into a fake injector and pins the modifier down/up pair, the
autorepeat (value 2), the release, a two-underscore key name, arrival order,
EV_KEY-only filtering, and silence in observe mode. The pass-through itself, the
`onEmitRaw` wiring and the `can_capture` refusal all exist. The daemon simply
never passes `intercept = true`.

**What actually blocks the flip** — two measured reasons, both named in
`ergopti_hotstrings.lua` at the `keyboard_hook.start` call:

1. ~~`injector.emit_key` shells out **once per event**~~ — **delivered.**
   `adapters/uinput_writer.lua` writes `struct input_event` straight to
   `/dev/uinput` via LuaJIT FFI, and `emit_key` prefers it whenever
   `open_fast_channel()` has succeeded. The fork per physical keystroke is gone,
   so the cost that made a grab unaffordable is gone with it.
2. The device kanata auto-detects is not coordinated with the one `device_finder`
   picks here. **Still open** — genuinely a hardware question.

**Do not propose batching the pass-through.** `ydotool key` does accept several
`code:value` pairs in one call, so collapsing a pump batch into one fork looks
obvious — and it is wrong. `_pump_one` re-emits an event and then dispatches it,
so an injection triggered by event N would run BEFORE the re-emit of N itself.
That is precisely the interleaving this whole item exists to remove. (Now
recorded in the adapter's own header as well, since the batched version is the
mistake a reader arrives at independently.)

**How the channel is verified without hardware.** Every syscall goes through a
swappable backend table, so the tests bind a recorder and assert the *bytes*:
the 24-byte `struct input_event` with its fields at the 64-bit offsets,
little-endian packing (a byte-swapped keycode is a different key), two's
complement for the `__s32` value, the 92-byte `uinput_setup`, and the
`SYN_REPORT` that must follow every key — without which the kernel buffers the
event and the application sees nothing while every write still returns success.
The ioctl ORDER is pinned too: capabilities must precede `UI_DEV_CREATE`,
because the kernel freezes the capability bits at creation and a key registered
afterwards succeeds while doing nothing, surfacing only as one key that quietly
stops working. Encoding is hand-rolled little-endian rather than `string.pack`,
because LuaJIT is 5.1 and has none — one code path on every interpreter beats a
version branch that only one side of CI ever executes.
Four mutation probes confirm the assertions are live: a 4-byte `timeval` → 5
reds, a dropped `SYN_REPORT` → 3, `UI_DEV_CREATE` moved before the keybits → 1,
autorepeat collapsed → 1.

The injector half has its own test, and its assertion is the unusual one: not
"emit_key works" — it always did — but **"emit_key does not fork"**. That cannot
be read from a return value, since `os.execute` reports the same thing whether
it ran once or not at all, so both spawn paths are made observable and required
not to fire. Removing the channel check makes it print the exact two forks.

Autorepeat is now passed through as `2` rather than collapsed to a press: the
ydotool wire format has no representation for a repeat, `/dev/uinput` does, and
a pass-through that rewrites what it passes is not one. The divergence between
the two channels is deliberate and pinned on both sides.

**What still needs real evdev + ydotool hardware:** flipping `intercept = true`,
the device-coordination question in (2) above, and confirming the kernel accepts
the virtual device. The code and its contract no longer do.

---

## 2. Tests that certify nothing

This is the highest-leverage cluster in the file, because a false green is worse
than a missing test: it actively deters anyone from writing the real one. The
repo has documented this failure mode three times already.

### Burning down the false-green baseline

The gate is delivered: `tools/test/find-false-greens.cjs` runs inside
`npm run test:js` and ratchets six classes — tautology, vacuous-absence,
dead-test, pcall-only, `corpus-skip` and `unfloored-scan` (the last two added
2026-07-31). It only turns down.

**`unfloored-scan` is the newest and came out of a live bug.** A test that loops
over regex matches and asserts only INSIDE the loop passes for free when the
pattern matches nothing — zero matches and only-good matches are
indistinguishable from outside the loop. The AltGr number-row guard had been
scanning nothing since it was written, through the `[^)]*` trap: the real
registration is `HotIf((*) => Features[…]["ergopti_alt_gr"] and IsRealAltGrPress())`
and `[^)]` stops dead at the `)` of `(*)`. Same trap as the first version of
`test-ahk-loop-capture.cjs`. Recorded as `project-source-scan-loops-need-a-floor`.

Calibrating that detector was most of the work, and the lesson generalises:
**precision matters more than reach for a gate nobody owns yet.** Every finding
was read against its source, and four shapes turned out to be real floors written
differently — a Map keyed in the loop and sized after it, `Count++`, a floor
compared against a variable rather than a literal, and a collector helper floored
by its CALLER under a different variable name. 84 reported → 34 real.

**549 → 298 so far**, over six classes rather than the original five. `dead-test` is at **0**: the two placeholders spliced into
the body of `_DE_Add()` are gone, and the two Linux skips with empty bodies now
assert the reason they skipped for. `tautology` is 153 → **49**, and `pcall-only` 367 → **225**.

The pcall-only burn-down is where the live hazards were. Every adapter whose job
is to BUILD A SHELL COMMAND had its tests written as "does not crash" — and
os.execute does not raise on a malformed command, it runs it, so an injection
hole and correct behaviour are indistinguishable to a pcall. Six adapters
converted so far (app launcher, notifier, text sender, tray, keyboard hook, timer
scheduler, plus the macOS port-contract vectors), each proven by breaking the
production code: removing Shell.quote, dropping the `!` doubling yad needs,
deleting the ydotool quote escape, changing an `intercept == true` to a
truthiness test that would GRAB the keyboard.

`vacuous-absence` is at **0**, and that one is a detector correction rather than
a burn-down: it flagged absence assertions on `_DriverFuncBody`, which used to
return `""` on a miss. That helper now throws, naming the symbol — the guarantee
moved out of each individual test, where it had to be remembered, and into the
helper, where it cannot be forgotten. The detector watches `_DriverFuncBodyOrEmpty`
now, the deliberate escape hatch and the only thing that can still produce an
empty body. Verified by dropping a probe file of exactly that shape into the tree.

**The skip-shaped false greens are the ones worth hunting first.** Three cases
found so far, each of which reported a pass for something that had never run:
`test_build_inserts_missing_timestamp.lua` loaded its module with a bare
`pcall(require, …)` on a module that pulls in `hs.fs` — so the require ALWAYS
failed outside Hammerspoon and all three cases took their skip branch on every
run since the file was written, for a crash that stalled the whole ingest loop
permanently; `test_timer_scheduler_suspend.ahk` read its adapter by hardcoded
path inside a `try` whose `catch` asserted true, so a rename silenced the canary
instead of failing it; and the two keystroke-injection vectors asserted `true`
in CI, where the behaviour genuinely cannot run — they now assert what CI *can*
check, that the entry point exists and reaches a real send primitive.

**The biggest thing the pass found is not counted by the ratchet at all.** Four
corpus consumers were replaying only their LAST vector. AHK v2 closures capture
by reference, and the `VecCopy := Vec` idiom — commented "capture loop variables
for the closure" — freezes nothing: one slot, shared by every closure, all
reading the final value after the loop ends. Measured: dropping a keystroke from
the first of 13 aggregation vectors produced 13 green tests. And because those
runners dispatch on `Vec["id"]`, twelve of the thirteen took no branch and
asserted nothing. `test_corpus_prompt_builder.ahk` had already hit this and
documented the fix in a comment; nothing enforced it, so three more files were
written the same way afterwards. `test-ahk-loop-capture.cjs` now enforces it at
0, and PROJECT_MEMORY carries the trap as
`project_ahk_loop_capture_copy_freezes_nothing`.

The method that worked, in case it helps the next pass:

1. **Read what the placeholder PROMISED.** The title is usually a real
   invariant; only the assertion was missing.
2. **Ask whether it is a property of THIS module.** Seven aggregator
   placeholders restated "the callers gate on pause" — untestable there, because
   the aggregator has no knowledge of suspend. Those get deleted and asserted at
   the caller, once, not restated seven times.
3. **Assert the post-condition, not the return.** `PLC_Start(); AssertTrue(1)`
   became `PLC_Running` must be true; `on_keydown(); assert_true(true)` became
   the app's counter must go up by exactly one.
4. **Prove it red.** Every replacement above was verified by breaking the
   production code it covers — dropping `I1`, removing a suspend guard, making
   `on_keydown` return immediately (14 tests red, previously 0).

A fifth step earned its place after the corpus find:

5. **Ask what the test would do if the code were absent.** A per-item loop whose
   items all assert the same value cannot tell a correct binding from a broken
   one; a runner that dispatches on an id asserts nothing for an id it does not
   handle. Both look like coverage in the count.

What is left: 95 tautologies, thinly spread, and the 367 `pcall-only` sites —
the largest class and the one lot 9 has a plan for.


---

## 3. Correctness and completeness

### i18n: the remaining hardcoded surfaces

Delivered so far: the macOS model switcher and models manager (power profile,
RAM/disk block, model-type badge), the gesture parameter prompt on macOS **and**
Windows (it was hardcoded in three copies with two different wordings), the
Windows LLM model menu, deps checker, `config_io.ahk` key names and the tooltip's
three French fallbacks, and the Linux gesture action labels — which needed no
translation at all, because the shared `sg_actions.*` catalogue already held all
42 in 21 languages and only Linux was not reading it.

The whole Linux driver is done too: the menu labels, the updater menu, the 30
dead `i18n_safe(key, "<French>")` fallbacks, and the pre-i18n CLI surfaces
(`--help` and the two startup errors, which are now **English** — they run at
`parse_args` before `i18n.init()`, and that init cannot move earlier because the
config directory it reads the locale from is itself settable with `--config`).
Two gates hold the line: `test-linux-menu-keys-exist.cjs` asserts every key the
menu asks for is defined in `en.json`, and ratchets hardcoded French literals at
**1** — the "Français" row of the language picker, correctly in its own language.

**What is left is one item, and it is not a string problem.**

### The metrics app picker needs category IDs before it can be translated

`_shared/ui/metrics_apps/script.js` holds ~88 French literals, but replacing
them is not the work. The French label **is** the internal key:

- `MAC_CATEGORIES_FR` maps the macOS native English category to a French label,
  and that label is then used as the category `type` throughout — charts,
  tables, the hourly ribbon.
- `FIXED_CAT_COLORS` is keyed by the FRENCH label (`Productivité`, `Développement`,
  `Santé & Forme`…), so translating the label silently loses every fixed colour.
- Worse, the value is **persisted**: a user category override is written to
  `app_categories.json`, and `macos/ui/metrics_apps/init.lua:82` supplies the
  default as `i18n.get("metrics_apps.general_category")` — a LOCALISED string.
  So the stored data already depends on the language that was active when it was
  written, and a user who switches language finds their overrides orphaned.

The fix is a data-model change, not a translation pass. **Step one is done:**
`FIXED_CAT_COLORS` is keyed by the stable English id, and `categoryId()` resolves
any id, French label or historical spelling back to it, so nothing already on
disk is orphaned. `test-metrics-category-ids.cjs` asserts the identity model
rather than the spelling.

Doing that surfaced a bug that was already live: `'Graphics design'` displays as
"Design graphique" while the colour table held `"Design"`, so that category had
silently lost its lavender and fell through to the hash palette. Neither spelling
looks wrong on its own, which is exactly why a label-keyed table hides it.

**Step two is done too, and it is a read-side normalisation rather than a file
rewrite** — which is the safer shape: nothing on disk is touched, so there is no
half-migrated state and no rollback to design.

The default category is the only value the picker itself writes, and it writes it
LOCALISED. All 19 distinct spellings across the 21 locales are generated into
`_shared/data/metrics_general_category_aliases.json` and resolve to one id, so a
user who switches from French to German no longer grows a second "General" with
their old overrides stranded under the first. The generator is checked against
the locale files on every run, so adding a locale or correcting a translation
cannot silently leave a spelling unrecognised.

`_shared/tests/corpus/metrics/app_categories_vectors.json` holds one stored
`app_categories.json` per shipped language plus a user-invented category and the
historical `"Design"` spelling — 23 vectors, each asserting the id its stored
value must resolve to.

**And the display text is done.** The "~88 French literals" figure predated the
earlier i18n passes; measured, only three were still user-visible and not part of
the category tables. The chart series label and the edit-category hint are now
locale keys in all 21 languages; the 12-entry `MONTHS_FR_SHORT` array is gone in
favour of `Intl.DateTimeFormat`, which the browser already localises correctly —
including the languages where a short month is not the first three letters
(`ja`/`zh` render 1月…12月, `ar` renders يناير…) — and which needs no translation
keys that could drift.

Also worth recording while here: the two drivers write DIFFERENT vocabularies to
files of the same name. Windows `app_categories.json` holds a five-token
productivity scale (`productive` / `distracting` / `communication` / `neutral` /
`unknown`) keyed by process name; macOS holds free-text user categories keyed by
app name. Neither is wrong, but nothing says so anywhere, and "migrate
app_categories.json" means two different things depending on the driver.

---

## 4. Performance — instrumentation first

The 2026-07-21 campaign shipped the levers it could prove. What is left is mostly
**unmeasured**, and silence reads as "optimal".

**Prerequisite, before any further tooltip work:** sub-segment
`_TooltipPresentStack` (`windows/ui/tooltip/helpers.ahk`). Since the UIA fix,
`Tooltip.Present` is the dominant offender (102 of 194 slow lines on the first
post-fix day, ~12.9 ms mean) and has **no surviving lever** — every candidate was
rejected in verification or forbidden by PROJECT_MEMORY. It aggregates six
sub-steps with no attribution, so anything proposed before this exists is
speculation.

Then, in value order: `LLM.FeedChar` (prime suspect for the ~600 slow `OnChar`
events with no matching slow `HSE.FeedChar`); `RemapEmit`, the first stage of
every keystroke, with no segment at all; the keylogger fan-out and
`Hook.KeyDown`, which close the per-keystroke budget; exit counters for
`_TooltipResolvePosition` plus a total render counter, without which the
slow-render ratio is incalculable; five retroactive boot marks before
`BootProfile_Begin`; and for idle, `UIA.SelectionPoll`, `Metrics.FocusRefresh`
(a `WinGetTitle` on a Not Responding window blocks 20×/s with no trace) and
`KL.Ingest`.

**The `SetTimer` inventory is delivered** (`test-fast-timer-inventory.cjs`). Four
repeating sub-second timers exist and each now carries what it polls and why its
interval is what it is; a fifth cannot appear without writing that down. One-shots
are deliberately excluded — `SetTimer(Fn, -50)` fires once and stops, and the
driver uses it 101 times as a "run this off the current thread" idiom, so
inventorying those would bury the four that matter.

### Follow-ups found while implementing

- ~~**Five independent decodes of the same manifest at boot (~200 ms).**~~ Done:
  one `_MM_MANIFEST_ROOT_CACHE`, one `FileRead`, one `JsonParse`, and all six
  call sites route through `_MM_GetManifestRoot()`. A failure is deliberately
  NOT cached, so a transient I/O error cannot pin the hard-coded fallback lists
  for the rest of the session. `test_menu_manifest_single_decode.ahk` holds it.
- ~~**Dead Ollama WinHTTP path.**~~ Done: both functions and the
  `entry.Has("http")` branches are gone, and
  `test_ollama_async_registry_is_curl_only.ahk` holds the line. The write-up
  there is worth keeping in mind — the poll re-armed itself, so a "who calls
  this?" search found a caller, and the only test that touched the shape
  fabricated the `"http"` key it was checking for.
- **Magic numbers around the LLM health probe**: the 3 s throttle is inline and
  the 10 s interval is duplicated between `menu_llm/init.ahk` and
  `menu_llm/actions.ahk`. Name them next to `LLM_HEALTH_PROBE_IDLE_MAX_MS`.
- ~~**Regex per keylogger event.**~~ Done: memoized on the title itself, with the
  same build-then-swap discipline as `MetricsFocusCache` — title and verdict are
  published together through one reference assignment, so a timer interrupting
  mid-scan can never expose a new title paired with the old verdict. The compare
  is case-SENSITIVE on purpose: two titles differing only in case are two
  different titles, and the patterns are already case-insensitive.

**All four §4 follow-ups are now closed.** What remains in this section is the
instrumentation itself, which needs a running driver and a day of real typing to
produce numbers — not something that can be written blind.

---

## 5. Audits

Prompts live in [`docs/prompts/`](docs/prompts/) — work from the prompt, not from
a summary. **`audit_mise_en_commun_et_simplification.md` has never been run**: it
covers pushing everything non-platform-specific into `_shared/` and reducing mass
(are the `_generated/` trees still earning their committed size, can `_shared/`
be flattened, god-files, orphan tooling). One correction to apply when running
it: it says to confront your conclusions against `docs/REFACTOR_PLAN.md`, which
no longer exists — that plan was consolidated and then deleted when its cycle
completed. `PROJECT_MEMORY.md` is now the only canonical memory.

`perf_ahk.md` ran on 2026-07-21 (fixes shipped, leftovers in §4). The `bugs_*`
prompts have run repeatedly; outcomes are in PROJECT_MEMORY. `perf_hs.md` and
`refactor.md` — check PROJECT_MEMORY before running; the refactor cycle the
latter belongs to was declared complete.

Also pending from the doc triage: rewrite `docs/STATE_TRANSITION_MATRIX.md`
against the current PowerShell-worker architecture (the two dangerous
prescriptions are fixed, but the surrounding symbol names are still stale), and
refresh the "It bundles:" list in `docs/TESTING.md`, which names four checks
where `run-js-suite.cjs` now declares about sixty.

### AHK adversarial audit, 2026-07-29 — closed

The 13-lens adversarial pass confirmed 96 defects (each survived an independent
refute-by-default verifier) and refuted 8 more. **All 96 are now fixed and
committed**, each with a regression test encoding its root cause, so the list
itself has been removed rather than left here reading as outstanding work.

Two notes worth keeping:

- The last three to land were `ADP-05` (the clipboard bail-out that could not
  prove ownership returned without restoring, leaving the injected payload —
  possibly a password — for the next Ctrl+V), `G5-D` (synthetic key presses now
  declare their buffer effect at the send funnel instead of at 3 of ~40 call
  sites) and `G5-C` (extension packs are enumerated once and shared by the
  engine and the preview index, so a pack can no longer expand without ever
  being previewable).
- The audit list was itself badly stale before this cleanup: it claimed 91 open
  findings when all but three had already shipped. A finding list that outlives
  its fixes reads as a backlog and gets re-worked. Prune it as each fix lands.

---

## 6. Decided — do not re-raise

Evidence in `docs/PROJECT_MEMORY.md`.

- **Moving the KE ownership mark into `launch_headless_once()`** (the last leg of
  `ke-prime-force-claims-and-kills-unowned-bridge`): everything else in that finding
  shipped — the read-only status probe no longer claims the bridge, the poll timeout
  no longer disowns one we launched, and the settle path's pkill is ownership-gated
  like every other kill in the driver.
  What is left is moving `mark_hs_owned_bridge()` from the top of
  `prime_ke_for_session` into the branch where a headless launch actually ran, plus
  the two force-path re-marks. It stays undone deliberately. Ownership is what
  authorises the quit-time bootout, so narrowing it narrows teardown too: a force
  prime that finds a live, responsive bridge would stop claiming it and would
  therefore stop tearing it down at quit — which may be right, or may reopen the
  post-quit-remapping class recorded in PROJECT_MEMORY. The two readings cannot be
  separated by a unit test, and a previous attempt in this exact area was reverted
  for precisely that kind of unverifiable side effect. It needs one session on a real
  machine: force-prime with a foreign bridge alive, quit, and check whether the
  keyboard is still remapped.
- **Moving the clipboard transaction off the keystroke tap** (raised as
  `perform-paste-clipboard-io-inside-eventtap`): the deferral was tried and reverted
  because it breaks the paste-ordering contract pinned by
  `tests/unit/modules/keymap/test_emit_tokens_multi_paste.lua`. The two remaining
  candidates turn out to be already done, which closes the item.
  One round trip per EXPANSION rather than per token: already the case. The
  expensive `hs.pasteboard.readAllData()` runs only on the branch where no restore
  is pending (`keymap/utils.lua` `perform_paste`); every later paste in the same
  expansion cancels the pending restore and KEEPS the captured original, precisely
  so it does not re-read and capture its own payload.
  Moving the RESTORE off the hot path: also already the case — it runs from the
  `CLIPBOARD_RESTORE_SEC` timer, and its throw-path restore landed in 21c4a0208.
  What is left inside the tap is one `setContents` plus the Cmd+V, which IS the
  paste, and one `readAllData` per expansion. Neither can move without breaking the
  ordering the pinned test exists to protect.
- **Re-seeding the delay baseline at every remaining flush site** (raised as
  `shortcut-and-mouse-flush-skip-baseline-reseed`): the three keystroke-path sites
  were real and 17286ec2e fixed them. Widening it to the rest of the tree is
  refuted on its stated consequence AND on the semantics.
  The claim was that a zeroed baseline makes the next keystroke record a
  zero-millisecond gap and be "recognised as synthetic". It is not: synthetic is
  carried by the explicit `meta.s` flag (`aggregator/events.lua:101`), never
  inferred from a delay. The real effect is the one the code's own comment states —
  the inter-word gap vanishes from the timing data — which is why only the
  keystroke-path sites needed it.
  And `last_time == 0` is a deliberate sentinel: `init.lua:631` reads
  `last_time > 0 and (now - last_time) or 0`, i.e. "no previous keystroke in this
  buffer". Every remaining flush site is a boundary where that is the correct
  answer — session end after an idle timeout, the midnight day rollover, native
  autocorrect, and the stop/teardown paths. Re-seeding there would invent a typing
  interval across a gap that was not typing.
- **A resolve memo bypassed on the dynamic-hotstring preview path** (raised as
  `resolve-not-memoised-on-preview-path`): refuted by reading the file.
  `_shared/lua/dynamic_hotstrings/init.lua` holds exactly one state table,
  `local _rules = {}` — there is no cache anywhere in it. `match_buffer` calls
  `pcall(rule.resolver)` unconditionally on every suffix hit and `M.preview` is a
  three-line delegation to that same function, so there is no memo for the preview
  to bypass. The defect shape needs two divergent resolution paths and there is
  one: `rules_engine.lua`'s interceptor and its preview provider both call the
  identical `SharedEngine.match_buffer`.
- **Per-tail cap on the end-char match loop**: five synchronised sites where
  missing one silently shortens the bound — a hotstring that stops firing — for a
  sub-microsecond gain four orders of magnitude below the profiler threshold.
  The same mechanism on the hotter STAR loop was already refuted.
- **Tooltip window reuse**, **chunking the emoji registration**, **timing tricks
  around the WebView2 cold start**: tried, reverted, or rejected with blockers.
- **Reconciling the three word-boundary predicates**: the AHK/Hammerspoon
  divergence is deliberate — do not fix without a concrete user need.
- **Descending-index iteration in `HookDispatcher`**: rejected in the code
  itself; it underflows and skips a subscriber that unsubscribes itself.
- **Idle-gating the keylogger network ticks** and the AV WMI scan: cost accepted
  explicitly — in-process, and they only emit on a state change.
- **Removing the 75 ms tooltip render debounce** as "pure added latency on every
  preview" (raised as `G4B-02`): refuted by the fix to `G4B-01`. The preview must
  land after `TOOLTIP_UIA_IDLE_REQUIRED_MS` of physical idle for stage 2 of the
  position cascade to be reachable, and `_PREFIX_RENDER_DEBOUNCE_MS` (150) plus
  `TOOLTIP_RENDER_DEBOUNCE_MS` (75) is exactly what clears the 200 ms gate, with
  25 ms of margin. Dropping the 75 ms puts the render back under the gate and
  silently disables the position cache. The relationship is pinned by
  `tests/meta/test_tooltip_debounce_is_load_bearing.ahk`.

## Other

### Donne moi ton avis sur mon projet. pas besoin d’aller lire des fichers ou autre, utilise ta mémoire et dis moi ce que tu en penses

Avec plaisir — avis franc, pas de flatterie.

#### Ce qui m'a réellement impressionné

La rigueur d'ingénierie est très au-dessus de la norme — pas seulement pour un projet solo, au-dessus de beaucoup d'équipes professionnelles. 3 377 tests Lua, 3 386 tests AHK, 1 146 Linux, des gates JS, des tests de parité cross-driver, des méta-tests qui testent les tests (la chasse aux faux-verts, les ratchets qui comptent même les commentaires…). La règle « chaque bug corrigé = un test de régression qui encode la cause racine » est appliquée pour de vrai — je l'ai vécue aujourd'hui : mon propre test m'a attrapé sur CI Linux quelques heures après que je l'ai écrit. C'est exactement le but, et presque personne ne tient cette discipline.

L'architecture _shared/ est la bonne réponse au bon problème. Trois drivers sur trois OS, ça dérive toujours. Ici, la source unique + les tests de parité rendent la dérive structurellement difficile. Le travail sur l'ordre des langues aujourd'hui s'est inséré dans un pattern déjà établi — signe d'une architecture saine.

PROJECT_MEMORY.md est une idée brillante. Une mémoire institutionnelle in-repo, partagée entre humains et agents, avec les leçons chèrement acquises. La plupart des projets perdent ce savoir à chaque contributeur ou session qui part. C'est le workflow augmenté par IA fait intelligemment.

Le produit est réellement singulier. Espanso fait les snippetspayant, personne ne combine hotstrings + IA 100 % locale +tap-holds + gestes + métriques, gratuit, sur trois OS. Le positionnement vie privée est un vrai différenciateur au moment où tout le monde envoie sa
frappe dans le cloud.

#### Ce qui me préoccupe — honnêtement

Le goulot n'est plus le code, c'est la distribution. 14 étoileent d'ingénierie, c'est un ratio effort/adoption extrême. Leproduit mérite 100× son audience actuelle. La page refaite et l'anglais sont des pas dans le bon sens, mais il faut aller chercher les gens : Hacker News
(l'angle « IA locale qui complète ta frappe » est taillé pour)mmunautés Bépo/Ergo-L. C'est inconfortable comparé à écrire ducode — c'est pourtant là qu'est le levier maintenant.

La friction d'installation tue des conversions. Le xattr macOS (app non notarisée) et l'exe Windows probablement flaggé SmartScreen éliminent les
utilisateurs non techniques — précisément ceux à qui les hotstice. Signer/notariser est à mon avis le meilleur euro investidu projet.

Le driver Linux est un risque d'inventaire. « Complet sur le papier, jamais exécuté en conditions réelles » — 16 000 lignes qui dorment. Je ne mettrais
plus une heure dedans avant d'avoir 2-3 testeurs réels ; sinon.

La méticulosité a un coût. Les 335 réglages, l'alignement des les conventions extrêmement strictes… c'est aussi ce qui rendle code survivable en solo, donc je ne dis pas d'arrêter — mais chaque heure de ratchet est une heure qui n'atteint pas un utilisateur. L'équilibre actuel
penche très fort côté interne.

Un conseil stratégique : Ergopti+ est le produit qui a un marcssion qui a une niche. Le découplage est déjà fait (« marchesur toute disposition ») — assume-le jusqu'au bout dans le discours. Et un jour, ose un v1.0 : v0.0.0-dev.87 raconte « pas fini » à des gens à qui tu
demandes de confier leur frappe.

#### En une phrase

C'est un projet d'artisan — rare, cohérent, construit pour dur n'est pas technique : c'est que personne ne le découvre. Lecode est prêt pour dix fois plus d'utilisateurs ; la prochaine bataille se gagne hors du repo.

### Aurais-tu des idées de features encore à ajouter ?

Oui, plusieurs — et je les classe par effet de levier : le projet a déjà des infrastructures (métriques SQLite, pont LLM, index de préfixes, catalogue
partagé) qui rendent certaines features quasi « gratuites » aljets entiers ailleurs.

#### Les évidences à fort levier

1. Le coach de frappe — ta feature signature possible. Les métmots et n-grammes les plus tapés. Croise-les avec le moteur dehotstrings : « Tu as tapé “cordialement” 47 fois ce mois-ci → créer cor★ ? » en un clic depuis le menu. Et l'inverse : quand l'utilisateur tape en entier
un mot qui a déjà une hotstring, un petit rappel « pex★ existee personne n'a les données ET le moteur dans le même produit.C'est la boucle qui rend la suite plus utile chaque semaine.

2. IA sur sélection. Tu as déjà le modèle local, les profils de prompt, et des actions de sélection (casse, etc.). Ajoute : corriger / reformuler /
traduire / résumer la sélection via un geste ou tap-hold. C'esud — très visible en démo, et ~80 % de la plomberie existedéjà.

3. Importeurs Espanso / TextExpander / aText. Faible effort, gros levier d'adoption : les gens ne migrent pas s'ils doivent retaper 200 snippets. «
Importez vos snippets en un clic » lève la barrière n°1 au swi

4. Sync locale multi-machines. Toi-même tu jongles Windows/macmieux : un dossier de config surveillé, synchronisable pariCloud/Syncthing/Dropbox — sans serveur, fidèle à la philosophie. Les hotstrings perso qui suivent l'utilisateur partout, c'est de la rétention pure.

#### Le cœur du métier à approfondir

5. Variables et formulaires dans les snippets — {date}, {clipboard}, position du curseur après expansion, champs à remplir. C'est LA feature la plus
demandée des expandeurs (si pas déjà couverte par tes hotstrinant).

6. Profils par application. La détection d'app existe déjà (testrings/réglages par contexte — l'expansion ;; en éditeur decode mais pas dans le terminal — c'est la feature « power user » qui fidélise.

7. Packs communautaires de hotstrings. Un dépôt de packs TOML (médecine, droit, dev, LaTeX…) installables depuis le menu. Techniquement trivial vu ton
format ; stratégiquement malin : chaque pack est une porte d'e

#### Le pari plus ambitieux

8. Dictée locale (whisper.cpp / MLX-Whisper). Gros morceau, maaux et de catalogue de modèles se généralise directement, et «dictée 100 % locale » s'insère parfaitement dans le positionnement vie privée — c'est un marché en pleine explosion, avec très peu d'offres locales
sérieuses.

#### Ce que je ne ferais pas

Palette de commandes/launcher (Raycast/Alfred ont gagné), gestmplet (encombré, faible différenciation), et toutinvestissement Linux supplémentaire avant d'avoir des testeurs réels.

#### Conclusion

Si je devais en choisir trois : le coach (1) — différenciationIA sur sélection (2) — démo spectaculaire, plomberie existante; les importeurs (3) — parce que ton vrai problème est l'adoption, et c'est la feature qui la débloque. Et je le redis en une ligne : une feature de plus convertira toujours moins qu'une app notarisée/signée et un po



## Hammerspoon audit 2026-07-29 — findings still open

The audit report was retired once its findings were adjudicated: 111 candidates,
92 confirmed, 17 refuted, 2 hypotheses. Everything at CRITICAL and HIGH severity
shipped, along with roughly half the rest — each with a regression test proven red
before the fix and green after.

These 36 did not ship. They are carried here verbatim so nothing was lost with the
file: location, root cause, proposed fix and proposed test. Two caveats that the
pass itself established, and that apply to every line below:

- **They are leads, not work orders.** Roughly one in six audit findings on this
  repo turns out to be false, stale, or already fixed once someone opens the
  file. Three were refuted that way while working through this list — including
  one whose "obvious" guard would have broken first-run Karabiner priming, and
  one where the code's own call-site comment explained why the thing called dead
  is a deliberate safety net.
- **Two were attempted and deliberately reverted**, because a test that must not
  be weakened said the fix was wrong: deferring the clipboard transaction off the
  keystroke tap breaks the paste serialisation contract, and gating the LLM
  startup backup check on an in-flight marker defeats the backup's entire purpose.
  Both need a different approach, not a retry of the same one.


### Verifier corrections — read these before touching the findings they name

A second adversarial pass (28 agents, each re-deriving the artefacts and each
finding then handed to a refuter told to kill it) confirmed 17 of the open items
and refuted 4. Every confirmed one came back with its proposed fix amended. The
three amendments that will otherwise cost a reverted commit:

- **UML-3** — do NOT gate the 3 s backup check on a dispatch flag.
  `tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua`
  asserts `#captured_checks == 2` in THREE places, under the proposed test's own
  setup: the naive fix turns them red and the proposed test is their negation.
  The real defect is that `_startup_check_generation` is an OUTCOME guard asked an
  IN-FLIGHT question — on the MLX path a terminal outcome is 60-90 s away, so at
  t=3 s the generation always still matches and the backup always double-dispatches.
  Fix the SINK instead: promote readiness in `models_manager_mlx_server.lua` from a
  per-invocation local to module state plus a waiter list, so a duplicate check
  joins the in-flight one instead of starting a second. That is below the seam the
  pinned test stubs, so it stays green.
- **perform-paste-clipboard-io-inside-eventtap** — deferring the paste was already
  tried and reverted; it breaks the ordering contract pinned by
  `test_emit_tokens_multi_paste.lua`. Evaluate instead: one pasteboard round trip
  per EXPANSION rather than per token, or moving only the RESTORE off the hot path.
  Do not re-propose the deferral.
- **ADAPT-4** is two claims and only one survives. 4a ("CACHE_VERSION never
  validated") is REFUTED: `adapters/toml_cache.lua` validates it as the first
  clause of its invalidation guard, and a snapshot from an older version is
  rejected. What remains is the 512-byte fingerprint window, which covers the
  `[_meta]` header and none of the entries — so do not close the item with 4a.

Refuted outright and not to be re-raised: `adapt-4b` as stated,
`karabiner-delay-dialogs-never-open-newline-in-applescript` (the mechanics
reproduce but the AppleScript grammar model behind the conclusion is wrong),
`dynhs-preview-resolve-memo-bypass`, and `UIW-6`.

### MEDIUM

