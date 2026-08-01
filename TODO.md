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
  ~~**The rename is DONE**~~ — 846 files, ~2 490 replacements, all four suites
  green. The blocker was never effort: it was that a wrong replacement could not
  be caught, so `test-packaging-paths-exist.cjs` was built first and immediately
  caught five stale paths in the deb/rpm/bundle scripts. **Five distinct textual
  shapes** had to be handled, each found by a different gate rather than by
  reading: bare `"lib"` with no separator (`DRIVER_ROOT .. "lib"`), the Lua
  pattern `"^lib%."` in `macos/tests/run.lua` PURGE_PREFIXES (invisible — the
  per-file purge silently stopped clearing `infra.*`, leaking a partial keycodes
  stub three files downstream), `tools/build/` being skip-listed, bare
  `lib/<file>.ahk` in 24 tool files, and `"lib.<module>"` strings in 5 gates.
  `tests/lib/` and `tests/unit/lib/` are deliberately untouched — different
  directories. Superseded note follows.
  **Measured cost of the remaining rename, and the reason it was blocked on
  verification rather than on effort.** Full size: **~1 750 references across
  ~800 files** — Windows 120 `#Include` + 731 path refs in 303 files, macOS 525
  `require` + 408 `package.loaded` stubs in 425 files, Linux 69 + 7 in 48 files,
  plus **26 tooling/CI files** carrying 97 `<driver>/lib` paths.
  **The blocker is that a wrong replacement cannot be caught by any suite.** The
  packaging scripts install to `~/.local/lib/ergopti/` and `/usr/lib/ergopti`,
  which must **not** be renamed, on lines adjacent to `linux/lib/locale.lua` in
  the bundler manifest, which **must**. Distinguishing them is easy to specify
  and easy to get subtly wrong, and the install layout is exercised by **no
  test** — the deb/rpm/AppImage would ship a broken tree with all four suites
  green. That is the exact failure mode this backlog exists to eliminate, so the
  rename needs a run of the real packaging builds to be safe, which a Windows dev
  box cannot provide. (The earlier note here called it "churn not worth taking";
  that was a judgement about value. This is a measurement about verifiability,
  and it is the stronger reason.) It also
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
  indistinguishable from a working one from inside the test. All three removed; ~~(c) `ui/`
  dissolves into `modules/<feature>/{menu,window}`~~ — **superseded, and the Linux
  half is done.** The maintainer's call was to align Linux on the other two
  rather than move all three, which is both cheaper and the direction the
  tree-parity report was already pointing: fifteen bridges to
  `ui/<page>/bridge.lua`, the manager to `ui/webview_manager.lua`, the menu to
  `ui/menu/menu_builder.lua`. Page names come from `_shared/ui/`, the canonical
  set. **I1 28.0 % → 46.9 % in one move**, and the union SHRANK — the twelve
  "missing `ui/*`" were never twelve gaps, they were one structural choice
  (Linux organised its UI by mechanism, the others by feature). If the
  `modules/<feature>/window.*` shape is still wanted, it is now one move of three
  identical trees instead of a reconciliation. (d) de-platform `_shared/` and
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
  paths that make up the gap. **Those per-driver counts were wrong-shaped, and
  the report has been fixed.** It listed every non-shared path under "per driver,
  unique to it", so a path held by TWO drivers was printed once under each — the
  strongest promotion candidates read as two separate private directories.
  `modules/dynamic_hotstrings` is the clearest case: macOS and Linux both have
  it, Windows does not, and it appeared as if macOS and Linux each had a private
  folder of that name. The report now separates the two classes, and the real
  shape is far more tractable than 26/22/6 suggested: **14 paths where two
  drivers already agree** and only **23 genuinely single-driver** (macOS 12,
  Windows 8, Linux 3).
  Twelve of the fourteen are `ui/*` absent on Linux, and that is ONE structural
  fact rather than twelve gaps: macOS and Windows organise the UI by feature
  (`ui/<page>/`) while Linux organises it by mechanism
  (`modules/ui/webview_manager.lua` + `modules/ui/bridge_handlers/<page>_bridge.lua`),
  which is also why Linux has two `ui` namespaces. Aligning them is Lot 3 step
  (c) and moves in the direction of `modules/<feature>/window.*` for all three —
  a cross-driver rename that cannot be done one driver at a time, because the I1
  ratchet fails on both the shared count and the union while it is half done.
  The remaining two were the objective, cheap ones. ~~`modules/dynamic_hotstrings`~~
  — **promoted, I1 26.0 % → 28.0 %.** It was section 5 of
  `hotstrings_text_expansion.ahk` on Windows. The move carried six tests with it,
  because the code had **none**: `SpacedPrefix`, the three date formatters and the
  delay resolver had zero references outside their own file, so a pure move could
  have broken any of them with the whole suite green. `SpacedPrefix` is the one
  that matters — "shortest prefix holding exactly N non-space characters" is not
  "first N characters", and an SSN's decorative spaces make the 5-digit trigger 7
  characters wide. What is NOT movable is the call site: registration order feeds
  the collision tiebreak, so the call stays where section 5 sat and a test pins
  that it still precedes the repeat key.
  Left: `infra/toml` (absent on Linux, which uses the shared codec directly) — and
  that one is arguably right as it stands rather than a gap to close.
  Note the baseline is a literal: deriving it from the value it constrains would
  make the comparison `x <= x`, which passes for every input — the exact false
  green this repo ratchets against elsewhere. Still to do: the Convention S stubs.

- **Lot 4 — one namespace.** **First slice landed:** the eight `hotstrings`
  sections now declare `linux` alongside `ahk`/`hs`, which is what let the Linux
  driver read the shared magic-key default instead of hardcoding a backslash, and
  produced its first `_generated/config_template.toml`. It cost one line per
  section and no gate moved — worth knowing before the rest, because the fear
  attached to this lot is really about the 223-table RENAME, not about adding a
  platform to a section that already exists. The remaining work below is
  unchanged.
  Migrate the **206 of 335 features (61.5 %)** out of
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
  `linux/infra/menu_host.lua` (~180 l), delete `menu_builder.lua` (**933 l**, not
  833). ~~route its 101 hardcoded French labels through the shared locales~~ —
  **stale: measured 2026-08-01, the file has ZERO hardcoded French literals and
  79 i18n references.** The §3 i18n pass already did that half and this entry was
  never updated, so the item reads as a translation job when what is left is
  purely architectural — one renderer instead of a hand-built tree. Worth the
  correction because the translation framing is what made it look expensive;
  (4) migrate the
  macOS hotstrings then layout submenus — layout needs `platforms:["macos"]` rows
  for the TIS/bundle features first, because `layout_menu` currently describes a
  Windows-only menu that the macOS drift gate pins without macOS implementing it;
  delete `test_menu_hotstrings_layout_drift_gate.lua` **after**, never before;
  (5) move the 1 812 lines of `macos/ui/menu/` that are not menu layout
  (`preferences.lua`, `menu_state.lua`, `menu_watchers.lua`, `shortcut_utils.lua`,
  `menu_paths.lua`) out — ⚠ **the third-driver test yields no destination**:
  measured, **none of the five has a counterpart on Windows or Linux** (28 644 B,
  17 964 B, 8 314 B, 9 355 B and 23 436 B respectively, all macOS-only). So "where
  does the same code live in the other drivers?" — the criterion that made the
  `layout.lua` promotion objective — returns nothing here, and picking a target
  directory is taste rather than evidence. Same answer as the 27 remaining macOS
  `lib/` files. Needs a design call on where they belong before the move is worth
  making; (6) fold `_shared/modules/llm/menu_layout.json` in — ~~its schema is a strict
  subset of v3 with exactly the fields v1 lacked~~ **— measured 2026-08-01, and it
  is not.** The file's 8 rows use 5 fields (`id`, `i18n`, `builder`,
  `disabled_when_off`, `health_dot`) against v3's 12 (`category`, `checked_when`,
  `disabled_when`, `group_label`, `i18n`, `i18n_dynamic`, `i18n_off`, `i18n_on`,
  `id`, `path`, `platforms`, `type`). Three map: `id`, `i18n`, and
  `disabled_when_off` onto `disabled_when` as a predicate rather than a boolean.
  **`builder` and `health_dot` have no v3 counterpart at all**, and `builder` —
  which names the platform function that fills each submenu — is the same need as
  the `provider` capability listed as still-to-build at the head of this very lot.
  So this is not a data merge blocked on nothing; it is blocked on an earlier item
  of its own lot, and doing it first would mean inventing two v3 fields with one
  consumer each. Worth noting the file is not a duplication either: both renderers
  already read it and it IS the single source of truth for the row order and the
  greying policy. The payoff here is consolidation, not a fixed bug; (7) lay the
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
     ~~the terminator path~~ and ~~consumed delimiters~~ — **measured: implemented
     on all three and already covered.** Linux looked thin (1 site) because the
     work is in the shared catalogue: `terminators_mod.is_terminator(ch)` feeds
     `terminator_consumed` into the engine on every keystroke, exactly as macOS
     and Windows do. Both branches of the flag are pinned by the two existing
     `backspace_count` vectors (`= tlen` when not consumed, `= tlen + 1` when it
     is), and the catalogue itself is generated from one source by
     `codegen-terminators.cjs` — the one part of the engine that has never
     drifted. No new vector adds anything here. ·
     ~~the NBSP typographic rule~~ — **measured: Windows and macOS implement the
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
     ~~`case_conform`~~ and ~~`is_case_sensitive_strict`~~ — **DONE, and the
     divergence was not the one recorded here.** This item said the strict flag
     was Windows-only and that macOS and Linux matched case-insensitively. Both
     halves were true, and both were downstream of something simpler: the shared
     TOML reader builds its entry table from a FIXED field list and
     `is_case_sensitive_strict` was not on it, so neither Lua driver ever saw the
     flag as anything but false. Fixed at the reader, with the regression test
     written over the whole flag list rather than this one flag.
     What the fix then exposed is the real finding. The two case flags are
     ORTHOGONAL and only the AutoHotkey loader had it right:
     `is_case_sensitive` selects the REGISTRATION shape (register the trigger
     literally, generate no lower/Title/UPPER family) and
     `is_case_sensitive_strict` selects the COMPARISON. The two Lua drivers read
     the first as "compare exactly" — what its name invites — so **592 shared
     entries**, the acronym autocorrections of the shape `"adn" -> "ADN"`, fired
     on nothing but their exact lower-case spelling. And **1 100 entries** that
     declare neither flag want the cased family, which Linux had no notion of:
     typing "ABIM " corrected to "abîm" instead of "ABÎM". All three drivers now
     produce the same three modes, and the corpus pins the output TEXT, not just
     whether something matched.
     Two neighbouring divergences fell out of the same work, neither of them on
     any list: the word-boundary predicate had **three** different answers
     (this engine counted every non-ASCII codepoint as a word character, macOS
     asked `is_letter_char` so `_` and `★` opened a word there and nowhere else,
     AutoHotkey tests the terminator set) — the two Lua drivers now share one;
     and macOS resolved star-vs-end-char by returning on the first auto hit, so a
     star trigger won unconditionally instead of yielding to a strictly longer
     end-char trigger.
     **The reason none of it was catchable is the part worth keeping.** All three
     corpus harnesses decided the outcome themselves instead of asking the
     driver: macOS compared the buffer tail to the trigger in the test and
     asserted the vector against its own answer; AutoHotkey mapped
     `is_case_sensitive` straight onto the `C` flag rather than routing through
     `HSE_RegisterFromTomlFlags`, so it agreed with the misreading it existed to
     catch; and every one of them built its mapping from a hand-named subset of
     the flags. The Linux e2e harness dropped `auto_expand` and never announced a
     terminator, so **every "match expected" scenario in it had been failing
     since `auto_expand` landed** and nobody was reading it. Each harness now
     drives the real matcher and builds its mapping from the flag LIST. ·
     the NBSP typographic rule, ~~the buffer cap~~ — **done: 3 vectors**, each
     measured against the real engine before being written down. A 257-codepoint
     trigger never matches, one of **exactly 256** still does, and a 300-codepoint
     buffer still matches on its tail because eviction drops the *oldest*
     codepoints. The boundary vector is the load-bearing one: an off-by-one in
     the eviction loop breaks it while leaving the 257 case green.
     One correction to this note: the two implementations do **not** declare the
     same 256. macOS holds 500 (`BUFFER_MAX_CHARS` in `modules/keymap/init.lua`)
     against the shared Lua engine's 256, so the 257-codepoint vector has no
     defined answer there. It now carries a `driver_specific` field and the macOS
     replays skip it by name and say so; the caps themselves stay held by
     `test-hotstring-buffer-cap-parity.cjs`.
     **Adding them exposed a wrong assumption**: the Windows harness asserted
     that a non-matched buffer must not end with its trigger, which held only
     because no vector had reached the cap — there the buffer *does* end with the
     trigger and the engine cannot see it. Now a second documented exemption
     beside the word-boundary one, read from the constant.
  3. Generate the single matcher core into both target languages, modelled on
     `codegen-terminators.cjs` — it already emits both targets in one run and is
     **the only part of the engine that has never drifted**.
  4. Close the eight measured divergences. ~~Linux **never** fires a
     non-`auto_expand` hotstring (its loader does not even read the field), has no
     case propagation and no collision priority~~ — **all three closed**, together
     with `final_result`, the NBSP typographic rule, `is_case_sensitive_strict`,
     the word-boundary predicate and the macOS star-vs-end-char ordering. The
     collision cascade (individual > section > file > source tier) is now one
     shared module instead of two Lua copies plus the AutoHotkey one, and all
     eight collision vectors replay for real on Linux — three of them used to be
     skipped as "priority-blind", and two of those three would have passed a naive
     replay because their expected winner is also the mapping registered first.
     `table.sort` is not stable, so before this the winner of an equal-length
     collision was not even deterministic between runs of the same corpus.
     ~~Still open on this item: the default magic key is `\` on Linux while the
     shared manifest says `★`~~ — **closed, and the cause was a manifest
     omission rather than a hardcoded preference.** `[sections.hotstrings]`
     listed only `["ahk", "hs"]`, and the generator filters per driver, so
     Linux's manifest carried no `trigger_char` entry and the driver had no
     choice but to hardcode — in two places, where the @-tag expansions listened
     for a key nothing else in the product used. The eight hotstrings sections
     now declare `linux` (a first, small slice of Lot 4, and the driver's first
     generated `config_template.toml` comes with it).
     Writing `test-magic-key-single-source.cjs` then found **four more copies**
     agreeing with the manifest by luck and **seven `or "★"` fallbacks** — the
     §5.4 shape, where a user who picks another key still gets the literal
     wherever state is momentarily absent. All read the declaration now. One of
     them would have become a live bug during the fix: the locale
     trigger-provider in `macos/init.lua` sits ~500 lines above the `magic_key`
     local, so naming it there captures the *global* of the same name — nil.
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
  7. **Remap**: ~~a 2.9-5x different threshold (0.2-0.35 s per key vs a flat
     1000 ms global)~~ — **closed.** macOS's 1000 ms was Karabiner-Elements' own
     default for `to_if_alone_timeout_milliseconds`, so it arrived by not being
     decided; it meant every hold waited a full second and any deliberate tap
     that overran a second silently became a hold. Now 250 ms, inside the range
     the other two use, so no key is more than 100 ms from its twin against
     650-800 ms before. `test-tap-hold-threshold-parity.cjs` holds the global
     inside the per-key range AND every value inside the 100-500 ms band a
     tap-hold can usefully occupy — the second half because a pure parity check
     passes when all three drift together.
     Still open here: macOS has ONE global where the others have one value per
     key. The generator already supports the per-manipulator override, so it is
     wiring, blocked on reconciling the id vocabularies. Also still open: a
     shared tap-hold IR + three emitters
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

- **Lot 10 — pruning.** ~~Port the macOS reachability gate to Windows and Linux~~
  — **done** (`test-adapter-reachability.cjs`), and it corrected the figure this lot
  was sized on. Re-measured: **macOS 24 adapters / 0 unreferenced, Windows 21 / 0,
  Linux 23 / 9 (1 549 lines)**. The record said 12 of 21 on Windows and 11 of 21 on
  Linux, i.e. ~3 101 lines; the real total is **half that and confined to one
  driver**. The earlier count almost certainly matched the adapter's NAME rather
  than its module path — "clipboard" appears in three Linux production files and
  every one is prose, a comment about the clipboard injection mode, while nothing
  requires `adapters.clipboard`. Searching for a word finds discussion; searching
  for the require finds wiring.
  **The nine are NOT deleted, and that is a decision waiting rather than an
  oversight.** Two of them (`notifier`, `tooltip_renderer`) are named by
  `test_port_adapter_presence.lua`, which asserts every declared port has an
  adapter file — so they exist because the architecture declares the port, not by
  accident. Removing them means shrinking `contracts.json` to the ports with real
  traffic and superseding ADR-001, which is a call about the hexagonal boundary.
  The count is frozen at 9 so it cannot grow while that call is pending.
   Each deletion carries the measured
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

### ~~Linux: the daemon never grabs the keyboard~~ — **DONE 2026-08-01**

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

**Shipped, on the maintainer's call** ("le driver linux n'a encore jamais ete
teste, donc fais-le et on verra bien le jour ou je testerai"). The daemon now
passes `intercept = opts.grab`, and `opts.grab` defaults to TRUE. `--no-grab` is
the escape hatch, not the default: observe mode is a *known-corrupting* default,
so it is the flag and not the norm.

Two regression tests pin it — the call must pass the option, and the option must
default to true. Removing it goes red by name; before, reverting to observe mode
failed nothing at all, which is why it survived the driver's whole life.

**Still unverified on hardware, deliberately:** the device kanata auto-detects is
not coordinated with the one `device_finder` picks, so on a machine where they
differ the grab may take the wrong keyboard — which is what `--no-grab` exists
for. Confirming the kernel accepts the virtual device also needs real evdev.

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

**Re-measured 2026-08-01, and the collision risk is lower than this reads:** the
two files never meet on disk. Windows writes to the METRICS dir
(`metrics_dir . "\app_categories.json"`, the directory that syncs between
devices); macOS writes to `hs.configdir .. "/data/app_categories.json"`, which
does not. So a user with both drivers does not corrupt one from the other today
— the hazard is a future path change, and the cost is confusion for whoever
reads one module's schema and assumes the other's. Left as a naming collision
with the measurement attached rather than renamed: renaming either file orphans
existing user data for no present benefit.

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

**RECOVERED 2026-08-01.** These 30 findings were carried here by the audit's
retirement commit (64aec676f, +318 lines) and then deleted the next day by
`dcc759e94` — a metrics commit whose message does not mention TODO.md at all.
74 793 characters of adjudicated defect reports disappeared as a side effect,
and the section above went on promising them while the heading below it was
empty. Restored from `dcc759e94^`. The lesson is the one the repo keeps
relearning: nothing said so, because a deleted section fails no test.

### MEDIUM

- [x] **FC-2** — ALREADY FIXED, stale entry. Commit 21c4a0208 ("fix(keymap): restore the clipboard when the hotstring paste throws") added the ok_write pcall, the two-branch restore, the clear of _paste_saved_original and the ERROR log to keymap/utils.perform_paste; its own comment now describes the bug in the past tense. The only deviation from the proposal is that it logs instead of re-raising, which is the better choice here: the caller is an eventtap callback, where a re-raise is swallowed and the ERROR line is the only thing that survives. This is the "one in six is already fixed once you open the file" caveat above. — (fix-collateral) — cab63e623's clipboard-ownership fix landed on the TextSender path that has no production caller and missed keymap/utils.perform_paste, which every real paste goes through
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/modules/keymap/utils.lua:157-182 (perform_paste)`
  - **Cause:** The fix was applied at the site the audit row named (adapters/text_sender.lua) and not to its documented twin. text_sender.lua:66 even says its serialisation "mirrors the keymap/utils.lua paste discipline", so the two were known to be the same code, and only one got the restore-before-rethrow. The asymmetry is upside down in impact: grepping the driver for `TextSender.send` finds exactly two production callers (expander.lua:653 and terminator_replay.lua:128) and both pass `{ mode = "direct" }`, so text_sender's clipboard branch is never reached in production at all, while keymap/utils.perform_paste is on the path of every long/unicode hotstring and every accepted LLM completion.
  - **Fix:** Mirror text_sender.lua:117-125 in perform_paste: bind `local saved = _paste_saved_original` BEFORE mutating the pasteboard, wrap `hs.pasteboard.setContents(value)` + `keyStroke({"cmd"}, "v", 0)` in an inner pcall, and on failure restore `saved` (writeAllData when it is a non-empty table, setContents("") otherwise — the same two-branch restore the timer at :176-180 already performs), clear `_paste_saved_original`, and re-raise so the caller still logs the emission failure. Keep the successful path byte-identical so the happy case pays nothing.
  - **Test:** Widen tests/unit/modules/test_clipboard_ownership.lua section 1 from a single-file source scan to an iteration over BOTH clipboard owners — `helpers.read_driver_source("PASTE_MODIFIER")` (text_sender) and `helpers.read_driver_source("CLIPBOARD_PASTE_GAP_SEC")` (keymap/utils) — asserting for each that between the payload write and the arming of the restore timer there is a restore call plus a clear of the saved original. Better still, add a behavioural case: load km_utils with an `hs.pasteboard` 
- [x] **karabiner-defaults-load-error-aborts-boot** — **DONE 2026-08-02.** Half was already fixed when re-checked: `init.lua` pcalls the require chain, so a raise there costs one feature and not the session. The other half was live — `shared_defaults_path()` still hand-rolled a four-level parent walk while its sibling `config.lua` asked `infra.paths`. It now asks the resolver first and keeps the walk as a fallback, requiring the resolver LAZILY because this file's body runs at require time. Three tests: the resolver is asked AND its answer is used, the walk survives when the resolver returns nil, and `init.lua` still pcalls. Original finding follows.
- [ ] ~~**karabiner-defaults-load-error-aborts-boot**~~ (karabiner) — defaults.lua raises at require time, aborting the whole boot 23 lines before hs.shutdownCallback is armed — KE keeps remapping with zero teardown
  - `static/ergopti_plus/macos/modules/karabiner/defaults.lua:44-51`
  - **Cause:** TomlReader.parse() returns an EMPTY result table for a missing file (_shared/lua/toml_codec/reader.lua:374-399), so defaults.lua's first check passes and require_section(sections,"hs_timeouts") hits `error(...)` at defaults.lua:71 — at MODULE LOAD time (defaults.lua:86-89 run at the top level). The whole chain to init.lua is un-pcall'd: defaults.lua <- config.lua:30 <- karabiner/init.lua:31-32 <- init.lua:231 `local karabiner = require("modules.karabiner")`. Two compounding causes: (a) defaults.lua hand-rolls its own fixed 4-level parent walk instead of lib.paths.shared(), which exists precisely to survive symlink/packaged layouts and which the SIBLING file config.lua:93 already uses (`Paths
  - **Fix:** Two small changes. (1) defaults.lua shared_defaults_path(): try `require("lib.paths").shared("tap_hold/defaults.toml")` first and keep the existing walk-up only as a last-resort fallback, so the symlink/packaged layouts resolve. (2) init.lua:231: `local ok_kb, karabiner = pcall(require, "modules.karabiner"); if not ok_kb then Logger.error(LOG, "modules.karabiner failed to load: %s — Karabiner bridge disabled for this session.", tostring(karabiner)); karabiner = nil end` — the shutdown callback at init.lua:282-287 already nil-checks `karabiner`, and shortcuts.start_script_control(…, karabiner) at init.lua:397 accepts nil (script_control.lua:510 type-checks it). Do NOT move hs.shutdownCallback
  - **Test:** New tests/meta/test_init_risky_requires_pcalled.lua: read macos/init.lua, strip comments, and assert that every `require(` appearing between the `Logger.install_runtime_error_capture()` line and the `hs.shutdownCallback = function()` line is inside a `pcall(require, …)` form — fails today on `local karabiner = require("modules.karabiner")`. Plus tests/unit/modules/karabiner/test_defaults_missing_shared_toml.lua: stub lib.toml.reader so parse() returns the empty-sections result, then `helpers.ass
- [ ] **ke-prime-force-claims-and-kills-unowned-bridge** — PARTLY DONE (the read-only status probe no longer claims ownership, and the poll timeout no longer disowns a bridge we launched. STILL OPEN: mark_hs_owned_bridge() at the top of prime_ke_for_session claims a bridge before any launch, the two force-path re-marks, and the un-gated KILL_FAST_CMD. Left open deliberately: moving the mark into launch_headless_once() changes quit-time teardown for the force path, and a previous attempt in this area was reverted for exactly that kind of unverifiable side effect. It needs a real driver to confirm, not a unit test.) — (karabiner) — prime_ke_for_session marks HS ownership unconditionally and fires KILL_FAST_CMD with no is_hs_owned_bridge gate
  - `static/ergopti_plus/macos/modules/karabiner/ke_lifecycle.lua:773-774 (mark_hs_owned_bridge before any launch) and :921-922 (un-gated pkill); consumers: ui/menu/menu_karabiner.lua:899-905 and :870-883; modules/karabiner/init.lua:571-586; gate that later trusts the marker: modules/karabiner/init.lua:886-896`
  - **Cause:** Ownership is asserted at the START of the prime cycle rather than at the moment HS actually launches the bridge (launch_headless_once(), ke_lifecycle.lua:779-787). And KILL_FAST_CMD at :922 is the one kill in the module with no is_hs_owned_bridge() gate — set_enabled(false) (karabiner/init.lua:200-209) and M.kill() (:886-896) both have one. The non-forced paths are correct: a running user bridge short-circuits at :752-757 BEFORE mark_hs_owned_bridge(), which is exactly why the gap only shows on force=true.
  - **Fix:** (1) Gate ke_lifecycle.lua:922 on `M.is_hs_owned_bridge()` (log and skip otherwise), mirroring karabiner/init.lua:200-209. (2) Move mark_hs_owned_bridge() out of :774 and into launch_headless_once() on the branch where hs.execute(KE_PRIME_HEADLESS_CMD) actually ran, so the marker only ever means "HS spawned this bridge". The three existing success sites (:800, :894, :913) already re-call it, so the happy path is unaffected.
  - **Test:** Extend tests/unit/modules/karabiner/test_ke_lifecycle.lua: stub hs.execute so is_ipc_bridge_running() reports a live bridge and is_cli_roundtrip_ready() reports failure, ensure no owner marker exists, call KE.prime_ke_for_session(function() end, true), then assert (a) `helpers.assert_eq(KE.is_hs_owned_bridge(), false, "a forced prime must not claim ownership of a bridge HS did not start")` and (b) the recorded hs.execute command list contains no KILL_FAST_CMD. Both fail today.
- [ ] **karabiner-press-never-reaches-keycode-heatmap** (keylogger) — kc_bridge's physical presses are logged then dropped: with the shipped defaults Return, Backspace, Tab and Delete vanish from the keycode heatmap entirely
  - `static/ergopti_plus/macos/modules/keylogger/aggregator/events.lua:472; static/ergopti_plus/macos/modules/keylogger/aggregator/events.lua:377; static/ergopti_plus/macos/modules/keylogger/init.lua:719; static/ergopti_plus/macos/modules/keylogger/aggregator/sql.lua:203`
  - **Cause:** Two halves of the bridge were built and never joined. (a) init.lua:719 sets `kc = KcBridge.is_ke_managed_output_kc(keycode) and nil or keycode`; the managed set is built from the OUTPUT key_codes of the user's tap/hold actions (kc_bridge.lua:142-179), with no provenance check, so it also suppresses genuine physical presses of those same keys. With defaults the set contains 36/51/48/117/55/56/59/61/63/64. (b) The compensating physical event IS produced -- drain_log calls _log_manager.log_karabiner_press (kc_bridge.lua:251) -> events_system row action='karabiner_press'. But aggregator/events.lua:446-499 has branches only for manifest_increment, focus_first_key, modifier_hold and karabiner_rele
  - **Fix:** Add a `karabiner_press` branch to aggregator/events.lua walk_system_event that credits S.agg_batch.kc_ngram exactly as walk_typing does: `if action == "karabiner_press" and type(entry.keycode) == "number" then local app = entry.app or "Unknown"; local kk = date_str.."\1"..app.."\1"..tostring(entry.keycode); S.agg_batch.kc_ngram[kk] = S.agg_batch.kc_ngram[kk] or { date=date_str, app=app, keycode=entry.keycode, count=0 }; S.agg_batch.kc_ngram[kk].count = S.agg_batch.kc_ngram[kk].count + 1 end`. Add the same to the AHK walker for parity. Separately consider narrowing is_ke_managed_output_kc so it only suppresses when the bridge actually claimed a press within the last few ms, rather than blanke
  - **Test:** New tests/unit/modules/keylogger/test_karabiner_press_feeds_keycode_heatmap.lua, modelled on the db-stub harness in tests/unit/modules/keylogger/test_aggregator.lua: stub SqliteWriter.get_db to record every SQL string passed to db:exec, then Aggregator.init{device_id="D"}; Aggregator.walk_system_event({ timestamp="2026-07-29 10:00:00.000", action="karabiner_press", keycode=57, app="TestApp" }); Aggregator.flush(). Assertion that fails before / passes after: `assert_true(any recorded statement ma
- [ ] **kc-bridge-writers-ungated-by-pause-and-privacy** (keylogger) — kc_bridge is a fourth keylogger writer with no pause guard and no privacy guard: physical key press/release events keep reaching today.log while a password field is focused
  - `static/ergopti_plus/macos/modules/keylogger/kc_bridge.lua:204-277 (writers at :246 and :251`
  - **Cause:** kc_bridge.lua contains no reference to a pause predicate or to any privacy flag (verified by grep for paus/secure/private/disabled across the file -- zero hits). Its two drain triggers are torn down only by M.stop(), which is called only from keylogger.M.stop() -- pause never calls it, and focusing a secure field never calls it. Its two writers go log_karabiner_press/release -> LogManager.append_log -> Rotation.append_log -> today.log; log_manager.lua:411-419 carries only `_require_state`, which checks initialisation, never pause or context. The pause axis is partly narrowed because script_control.pause_all deploys a reduced KE config (karabiner/init.lua:592-608) -- but that redeploy is defe
  - **Fix:** Inject the same `_is_paused` predicate the watcher and context-tracker layers already receive (keylogger/init.lua wires it at :1361 and :1364) into KcBridge.init, and gate drain_log's two `_log_manager.*` calls on `not _is_paused()` AND on the same context predicate proposed for finding notify-synthetic-bypasses-every-privacy-guard -- while still advancing _file_offset and _pending_down, exactly as the existing _log_manager==nil path does (kc_bridge.lua:242-247), so no backlog replay is created.
  - **Test:** Two parts. (1) Extend PAUSE_GATED_ENTRY_POINTS in tests/unit/modules/keylogger/test_pause_guard_position.lua with `{ label="kc_bridge drain_log", file="modules/keylogger/kc_bridge.lua", decl="local function drain_log", writer="_log_manager.log_karabiner_press" }`; the existing `assert_true(guard ~= nil, ...)` fails today because drain_log contains no is_paused() at all. (2) Behavioural, modelled on tests/unit/modules/keylogger/test_kc_bridge_offset_advances_while_disabled.lua (which already buil
- [ ] **shortcut-and-mouse-flush-skip-baseline-reseed** (keylogger) — The shortcut and mouse flush sites in handle_key bypass flush_keeping_baseline, so the keystroke after every shortcut or click records delay 0 and can be swallowed as synthetic
  - `static/ergopti_plus/macos/modules/keylogger/init.lua:563; static/ergopti_plus/macos/modules/keylogger/init.lua:495; static/ergopti_plus/macos/modules/keylogger/init.lua:500; static/ergopti_plus/macos/modules/keylogger/init.lua:596-599; static/ergopti_plus/macos/modules/keylogger/log_manager.lua:363`
  - **Cause:** LogManager.flush_buffer sets `_state.last_time = 0` (log_manager.lua:363). handle_key computes `delay = CoreState.last_time > 0 and math.floor(now - CoreState.last_time) or 0` (:586), so the next keystroke measures against 0. The 2026 fix introduced `flush_keeping_baseline()` (:596-599) and routed the seven keystroke-driven branches through it -- but the shortcut branch flushes at :563 and returns at :570, and the two mouse branches flush at :495/:500 and return at :497/:501, all BEFORE line 587 ever assigns `CoreState.last_time = now`. The helper is also declared at :596, textually below those three branches, so they could not call it as written. Second-order: with delay==0 the stale-queue 
  - **Fix:** In handle_key, assign `CoreState.last_time = now` immediately after each of the three flushes (`now` is already in scope from :479), or hoist the `flush_keeping_baseline` declaration above the mouse branch and call it there and in the shortcut branch. Note the mouse branches guard the flush on `#CoreState.buffer_events > 0` while the shortcut branch does not, so the seed must be unconditional at the shortcut site.
  - **Test:** Two parts. (1) Cheap source ratchet: add "leftMouseDown" and "is_shortcut_candidate" to KEYSTROKE_FLUSH_MARKERS in tests/unit/modules/keylogger/test_flush_preserves_delay_baseline.lua -- its existing case "no keystroke-driven branch still calls flush_buffer directly" then fails on both new markers and passes after the fix. (2) Behavioural, in the tests/unit/modules/keylogger/test_keylogger_privacy.lua harness (its absoluteTime stub already advances 80 ms per call): type "a", deliver a leftMouseD
- [ ] **eventtap-does-ax-and-tis-work-once-per-word** (keylogger) — handle_key performs a cross-process AX window-title read and a Carbon TIS layout query on the first keystroke of every word, inside the eventtap callback
  - `static/ergopti_plus/macos/modules/keylogger/init.lua:617-626; static/ergopti_plus/macos/modules/keylogger/init.lua:531; static/ergopti_plus/macos/modules/keylogger/init.lua:537`
  - **Cause:** The context snapshot was written as a direct query instead of a read of already-cached state. CoreState.active_app_name / active_app_bundle are maintained by context_tracker.app_watcher_cb (context_tracker.lua:472-476) on every activation, and the focused window title is already tracked in context_tracker's `_last_win_title` (:407). Nothing in handle_key consults either. hs.window title reads go through AXUIElementCopyAttributeValue, which blocks on the target process; macOS answers a slow tap with kCGEventTapDisabledByTimeout, which turns a lag problem into a dead keylogger tap (the watchdog at init.lua:1424-1432 would restart it 5 s later, losing everything typed in between). The driver al
  - **Fix:** Replace the per-word snapshot with cached reads: `CoreState.session_app_name = CoreState.active_app_name or "Unknown"`, `CoreState.session_win_title = <title cached by context_tracker.update_private_status>`, and cache the layout in a module local refreshed by the existing layout-change watcher rather than calling hs.keycodes.currentLayout() inline. At :531/:537 use CoreState.active_app_name instead of frontmostApplication():title(). If a live read is genuinely wanted, take it in an hs.timer.doAfter(0, ...) that writes into CoreState for the NEXT buffer.
  - **Test:** New tests/meta/test_keylogger_tap_defers_blocking_context.lua, modelled on tests/meta/test_pause_path_defers_blocking_work.lua's function_slice helper: slice `local function handle_key` out of modules/keylogger/init.lua and assert the slice contains none of ":mainWindow()", "hs.keycodes.currentLayout(", "hs.application.frontmostApplication(" outside an `hs.timer.doAfter(0,` wrapper. Fails today on all three; passes once the snapshot reads CoreState. Pair it with a behavioural case in the test_ke
- [ ] **perform-paste-clipboard-io-inside-eventtap** (keymap-core) — perform_paste() reads and rewrites the whole pasteboard synchronously inside the keyDown eventtap callback
  - `static/ergopti_plus/macos/modules/keymap/utils.lua:157-182 (perform_paste; :167 hs.pasteboard.readAllData()`
  - **Cause:** The expander's design note (expander.lua:14-16) justifies running expansions inline because "CGEventPost() is non-blocking, so keyStroke() calls return immediately". That is true of the key posts but not of the clipboard transaction that precedes them. perform_paste performs unbounded cross-process I/O whose cost is proportional to the SIZE OF THE USER'S CLIPBOARD — a quantity the driver neither controls nor bounds — on the hottest path in the driver.
  - **Fix:** Defer the clipboard transaction one tick with the driver's own idiom: wrap the save / setContents / Cmd+V body of perform_paste in hs.timer.doAfter(0, function() ... end) so it leaves the eventtap callback (the same DEFER_TOKEN pattern pinned by tests/meta/test_pause_path_defers_blocking_work.lua:47). _paste_ops_pending must stay incremented synchronously at utils.lua:258/:328 so take_paste_ops() still arms expected_synthetic_pastes before perform_text_replacement returns, and emit_text must keep returning a non-zero order_delay so the terminator fence still applies. Stronger fix: keep an off-tap clipboard snapshot refreshed by an hs.pasteboard changeCount poll / watcher, so readAllData neve
  - **Test:** New tests/meta/test_paste_defers_clipboard_io.lua, modelled on tests/meta/test_pause_path_defers_blocking_work.lua: slice `local function perform_paste` out of modules/keymap/utils.lua (bounded by the next top-level declaration) and assert, for each of "hs.pasteboard.readAllData()" and "hs.pasteboard.setContents(", that a "hs.timer.doAfter(0," token appears earlier in the slice — with the message naming the tap-disable consequence. Fails today (neither call is wrapped); passes after the deferral
- [ ] **ignored-window-ax-probe-inside-tap-after-focus-change** (keymap-core) — The first keystroke after every app switch does two synchronous accessibility round-trips inside the keyDown eventtap
  - `static/ergopti_plus/macos/modules/keymap/utils.lua:470-499 (dirty-cache probe; :478 hs.window.focusedWindow`
  - **Cause:** The TTL-expiry branch was deliberately moved off the tap (utils.lua:450-468, with a comment naming "a cross-process AX round-trip inside the keyDown tap" as the reason) but the DIRTY branch was left synchronous on the grounds that "that one really did change". A focus change is precisely the moment the newly-focused process is most likely to be busy. hs.window.timeout() is never called anywhere in the driver (grepped modules/, lib/, adapters/, ui/ and root init.lua — zero hits), so those AX calls inherit the system messaging timeout rather than a short driver-chosen one.
  - **Fix:** Serve the last known value on the tap for the dirty case too, and refresh off-tap: reuse the existing _ignored_win_refresh_armed / TimerScheduler.after(0, ...) path (utils.lua:457-468) for the dirty branch, accepting exactly one stale keystroke after a focus change — the same trade already accepted for TTL expiry. Better: resolve the answer inside the watcher callbacks themselves (utils.lua:381-386 and :406-410), which already run off the tap, so onKeyDownRaw only ever reads a cached boolean and never touches AX. Additionally, do not mark the cache clean when the probe bailed early — leave it dirty so the next refresh retries.
  - **Test:** tests/unit/modules/keymap/test_utils.lua, new case "is_ignored_window never probes AX synchronously": load keymap.utils with a stubbed hs whose window.focusedWindow increments a counter and whose timer.doAfter records handles; call M.is_ignored_window(t, p, 1000) to warm the cache; invoke the recorded application-watcher callback with hs.application.watcher.activated to set the dirty flag; call M.is_ignored_window(t, p, 1001) and assert the focusedWindow counter is UNCHANGED and that exactly one
- [ ] **LIBCORE-1** (lib-core) — The logger's topical sub-file fan-out does a synchronous io.open/write/close per DEBUG line, inside the keystroke eventtap — defeating the level-aware flush that exists precisely to keep blocking I/O out of the tap
  - `static/ergopti_plus/macos/lib/logger.lua:654-687 (_write_to_file)`
  - **Cause:** The level-aware flush was applied to the main handle only. The fan-out immediately below it was left unconditional and per-line, and its open/close pair costs strictly MORE than the single `fh:flush()` that was optimised away. The `immediate` parameter is threaded into the `fh:write` branch (658-670) but never consulted by the sub-file loop (675-686). Root cause is scope, not mechanism: the fix addressed one of the two sinks _write_to_file owns.
  - **Fix:** Apply the SAME level decision to the fan-out that already applies to the main handle: buffer DEBUG-class routed lines per sub-file in memory and drain them (one open/write/close per sub-file) when a non-DEBUG line routes there or when FLUSH_EVERY_N_DEBUG accumulates — reusing the existing counter so the crash-exposure bound is unchanged. `_sub_file_mode(path, today)` keeps its exact contract (decided once per file per calendar date, before anything is appended), so the daily-reset behaviour is untouched. Secondary: hoist the second `os.date("%Y-%m-%d")` at line 674 — `_ensure_log_file()` already computed today's date one line earlier, so every log line reads the clock-to-string twice for the
  - **Test:** New `tests/unit/lib/test_logger_subfile_debug_deferred.lua`: install an io.open spy exactly as `tests/unit/lib/test_logger_subfile_daily_reset.lua` does, `Logger.set_level("DEBUG")`, emit N=100 DEBUG lines carrying a routed tag, and assert the number of opens of that sub-file is <= ceil(N / FLUSH_EVERY_N_DEBUG) + 1, NOT N. Assertion text must state the root cause ("a DEBUG line comes from inside the eventtap; an open/write/close there is more expensive than the fsync the deferral removed"). Add 
- [ ] **LIBCORE-3** (lib-core) — Every dialog schedules a blocking `hs.execute("open …")` on the main run loop that — for the two BLOCKING wrappers — can only fire AFTER the dialog is dismissed, so it cannot serve its stated purpose and instead steals focus back while stalling the run loop
  - `static/ergopti_plus/macos/lib/dialog_util.lua:64-72 (the deferred `pcall(hs.execute`
  - **Cause:** focus_hammerspoon() implements three focus mechanisms; the third contradicts its own premise. For M.alert (non-blocking) the deferred `open` does fire 100 ms later and does raise the app, but `hs.execute` is `io.popen` read-to-EOF — fully synchronous on the main run loop (PROJECT_MEMORY project-hs-partial-fixes-and-false-green-tests records exactly this about ShellRunner.exec). For M.block_alert and M.text_prompt the timer is structurally unable to run before dismissal, so the call is dead with respect to its purpose while retaining both side effects: a main-thread stall and a focus steal. The two synchronous `do_focus()` calls at 55-56 are what actually focuses the dialog; the shell-out add
  - **Fix:** Delete the deferred `hs.execute` block (64-72) entirely: `hs.focus(true)` + `app:activate(true)`, already called twice, is the supported way to bring Hammerspoon forward, and the shell-out demonstrably cannot help the blocking wrappers. If an extra nudge is genuinely wanted for the non-blocking M.alert path only, route it through `adapters.shell_runner.spawn` (async, GC-pinned) and gate it on the non-blocking wrapper — never on block_alert/text_prompt.
  - **Test:** New `tests/unit/lib/test_dialog_util_no_blocking_shell.lua`: stub `hs.execute` with a spy and `hs.timer.doAfter` with a recorder that fires immediately, call M.block_alert / M.text_prompt / M.alert, and assert `#exec_calls == 0`. Per PROJECT_MEMORY's own rule for this class, the assertion must be the ABSENCE of the harmful operation, never the presence of the scheduling call. This keeps tests/unit/meta/test_gc_retention.lua:337 green — that test only asserts `hs.task.new` is absent from dialog_u
- [ ] **mlx-discovery-restart-storm** (llm-backends) — A failed MLX discovery cycle restarts itself on the very next run-loop tick with the backoff reset — a per-tick curl+HTTP storm on the main thread
  - `static/ergopti_plus/macos/modules/llm/api_mlx_discovery.lua:271-289`
  - **Cause:** finish_discovery(false) (api_mlx_discovery.lua:271-289) clears the `_endpoint_probe_in_flight` mutex and then synchronously fires every queued callback. Each queued callback is `function() M.warmup(model_name, profile) end` (api_mlx.lua:549). M.warmup re-tests `ApiMlxDiscovery.is_discovered()`, which is still false on the failure path, and calls `ApiMlxDiscovery.discover()` again inline with no cooldown (api_mlx.lua:544-551). discover() then arms `poll_timer = TimerScheduler.after(0, do_poll)` (:484) and re-initialises BOTH pacing variables of the new cycle: `poll_delay_sec = DISCOVERY_POLL_INITIAL_SEC` (:386) and `started_at = TimerScheduler.now()` (:269). The exponential backoff and the DI
  - **Fix:** Add inter-cycle pacing owned by api_mlx_discovery. Record `_last_cycle_finished_at = TimerScheduler.now()` inside finish_discovery(), and in M.discover() refuse to arm a new probe cycle while `now - _last_cycle_finished_at < DISCOVERY_RETRY_COOLDOWN_SEC` — instead schedule the cycle through `TimerScheduler.after(remaining, ...)` so the caller's on_done is still honoured, just later. Equivalently (and less invasively) change api_mlx.lua:549 so the warmup callback re-enters through `TimerScheduler.after(DISCOVERY_RETRY_COOLDOWN_SEC, function() M.warmup(model_name, profile) end)` rather than calling discover() inline. The cooldown constant must come from lib.timings, not a literal. IMPORTANT: d
  - **Test:** New file tests/unit/llm/test_api_mlx_discovery_restart_cooldown.lua. Stub adapters.timer_scheduler so `after(delay, fn)` only RECORDS {delay, fn} (never runs it) and `now()` returns a controllable clock; stub adapters.shell_runner so `spawn()` returns a handle whose `start()` increments `spawn_count` and synchronously invokes on_done(0, '{"data":[]}'); stub adapters.http_client's `new().post` to call back synchronously with `{status = 404, body = ""}`. Then call `ApiMlxDiscovery.discover(functio
- [x] **shortcut-actions-block-main-runloop** — DONE (shipped: all 24 interactive-layer sites are async subprocesses now) — (shortcuts-gestures) — Ctrl+P / Ctrl+X / Ctrl+D run blocking hs.execute and hs.osascript inline on the main run loop, stalling every CGEventTap
  - `static/ergopti_plus/macos/modules/shortcuts/actions/system_mouse.lua:190; static/ergopti_plus/macos/modules/shortcuts/actions/system_pixel.lua:56; static/ergopti_plus/macos/modules/shortcuts/actions/system_pixel.lua:83; static/ergopti_plus/macos/modules/shortcuts/actions/apps.lua:222; static/ergopti_plus/macos/modules/shortcuts/actions/apps.lua:240; static/ergopti_plus/macos/modules/shortcuts/actions/apps.lua:253; bound at static/ergopti_plus/macos/modules/shortcuts/bindings.lua:205`
  - **Cause:** The driver's own model, stated verbatim in three files (`KEYSTROKE_NO_DELAY_US` comments at apps.lua:36-40, system.lua:40-44, text.lua:29-33), is that stalling the main run loop lets macOS disable the tap it services with kCGEventTapDisabledByTimeout. Every other subsystem obeys it: gestures/actions.lua wraps EVERY hs.execute and every hs.osascript.applescript in `hs.timer.doAfter(0, ...)` (lines 270, 388, 394, 440-456, 461, 477-506); script_control defers `_karabiner.pause()/resume()` for the same reason and has a dedicated meta-test. modules/shortcuts/actions/ was never converted. The asymmetry is visible inside a single function: apps.lua:243 defers the `open` call in the else-branch whil
  - **Fix:** Resolve every argument synchronously (paths, mouse position, window id -- the pattern bind_instant_screenshot already uses at system.lua:479-493) and move the hs.execute / hs.osascript.applescript itself into `hs.timer.doAfter(0, function() ... end)`, exactly as gestures/actions.lua does. For copy_pixel_color, prefer ShellRunner.spawn (async hs.task, pinned) over two blocking hs.execute, since it already has a completion callback shape. focus_existing_finder_window must become async or be dropped -- an AppleScript round-trip to Finder cannot be bounded.
  - **Test:** New tests/meta/test_shortcut_actions_defer_blocking_work.lua, a direct sibling of tests/meta/test_pause_path_defers_blocking_work.lua, reusing its 200-char backward-window technique: for every occurrence of `hs.execute` and `hs.osascript.applescript` under modules/shortcuts/actions/, assert `hs.timer.doAfter(0,` appears in the preceding window. Plus a behavioural case in tests/unit/modules/shortcuts/test_actions_system.lua that cannot false-green: `hs.__reset(); sys_acts.copy_pixel_color(); help
- [x] **shortcut-gesture-taps-no-tap-disabled-recovery** — DONE (shipped: shared adapters/event_tap_guard re-engages all 13 tap owners) — (shortcuts-gestures) — Ten long-lived eventtaps in this zone never handle tapDisabledByTimeout and have no watchdog, so one stall kills them permanently
  - `static/ergopti_plus/macos/modules/shortcuts/actions/system.lua:464`
  - **Cause:** The recovery pattern exists in this driver in four places -- script_control.lua:529-534 (2 s doEvery + isEnabled check), modules/keymap/init.lua:1224-1261 (tap_watchdog over three taps), modules/keylogger/init.lua:1421-1432, and gestures/init.lua:744-748 where the gesture primer re-engages itself on `ev.tapDisabledByTimeout`. `grep -rn tapDisabled` over modules/, ui/, lib/, init.lua returns exactly ONE hit (gestures/init.lua:744). Every other tap in this zone is created, started once and never checked again. This is the project's own recurring shape: the guard exists, the sibling sites were missed.
  - **Fix:** Two complementary changes. (1) In each callback, first-line: `local t = e:getType(); if t == hs.eventtap.event.types.tapDisabledByTimeout or t == hs.eventtap.event.types.tapDisabledByUserInput then tap:start(); return false end` -- the gesture-primer shape, using the forward-declared-local form so the closure captures the handle. (2) Extend the existing script-control watchdog idea into a single shared re-arm helper the bindings registry ticks over its live tap objects, so a tap disabled while its callback is not being invoked is still recovered. Note the constraint documented at engine.lua:873-875: the scrollBlocker must only be :start()ed when isEnabled() is false, never toggled unconditio
  - **Test:** New tests/unit/modules/shortcuts/test_shortcut_taps_recover_from_tap_disable.lua. Reuse the eventtap-capture stub already written at tests/unit/modules/shortcuts/test_actions_system.lua:363-372 (hs.eventtap.new records the callback and returns a handle whose start() increments a counter). Call sys_acts.bind_wrap_text_if_selected(nil), then invoke the captured callback with a fake event whose getType() returns hs.eventtap.event.types.tapDisabledByTimeout, and assert start() was called a second ti
- [ ] **UML-3** (ui-menu-llm) — The boot 'backup' check dispatches a duplicate force_mlx_check while the primary is still in flight — two stacked hardware dialogs and two downloads of the same model on first run
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:275 and :279-307`
  - **Cause:** The F-MED-32 fix guards the *resolution* of the two chains (each success re-checks the generation) but not their *dispatch*. There is no 'primary already dispatched and not yet resolved' flag, so the backup, whose stated purpose is 'in case the primary callback chain was skipped', fires whenever the primary is merely slow — which is the normal case for a model that must be downloaded or a server that takes 60 s to load weights.
  - **Fix:** Track dispatch, not just resolution: set a `_primary_in_flight = true` immediately before `check_fn(...)` (cleared in both of its callbacks) and have the 3 s backup return early when it is set, in addition to the existing generation check. That preserves the backup's real purpose (the primary chain never dispatched at all) while removing the duplicate.
  - **Test:** Add a case to tests/unit/ui/menu/menu_llm/test_startup_controller_generation_guard.lua asserting `#captured_checks == 1` after `fire_all_timers` when the primary's callbacks have not yet been invoked. Note this INVERTS the current `assert_eq(#captured_checks, 2, …)` used as setup in the existing cases, so those three cases must be re-plumbed to fire the primary's dispatch explicitly rather than relying on the duplicate — do not delete them.
- [x] **UIW-1** — DONE (shipped: one branch decision, one setKind, no resetUI on a fresh page) — (ui-windows) — download_window: the fresh-open path throws away its own JS queue and force-flags the page "ready" before it has loaded — setKind/resetUI/setModel are lost on every first open
  - `static/ergopti_plus/macos/ui/download_window/init.lua:409-447 (wipe at 423-424; unreachable code at 438-447); frontend contract at static/ergopti_plus/_shared/ui/download_window/script.js:63-85 and style.css:94-116`
  - **Cause:** The `if _wv then` reset block at 420-436 was written for the window-reuse case (its comment says "Window already open"), but the else-branch at 412-415 makes _wv non-nil before control reaches it, so the fresh-open path falls into the reuse block. The genuine fresh-open path at 438-447 is dead code — it can only run if ui_builder.show_webview() returned nil, in which case eval() early-returns on `not _wv` anyway. The queue+_ready mechanism exists precisely to defer JS until didFinishNavigation; this block defeats it exactly when it is needed.
  - **Fix:** Delete the dead fresh-open tail (438-447) and gate the reset block on whether the window was pre-existing rather than on `_wv`: capture `local reused = _wv ~= nil` before line 409, then only run `_queued = {}; _ready = true` when `reused` is true. On a fresh window leave _ready=false so resetUI/setKind/setModel queue and are flushed by the on_navigation didFinishNavigation handler (or by the 1 s safety timer in ensure_webview).
  - **Test:** Extend tests/unit/ui/test_download_window_setmodel_js_escaping.lua's stub harness (it already captures evaluateJavaScript and the navigationCallback). New case: call DownloadWindow.show({ kind = "mlx_install", title = "T", subtitle = "S" }); assert get_evaluated() is EMPTY at that point (everything must still be queued); then fire_navigation() and assert the flushed calls contain, in order, `setKind("mlx_install","T","S")` and `resetUI()`. Fails today (setKind-with-title is discarded and the res
- [ ] **ADAPT-4** (adapters) — toml_cache's staleness defence is unguarded: CACHE_VERSION is a hand-maintained constant with no test tying it to the reader's output shape, and the "content fingerprint" only hashes the first 512 bytes
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/adapters/toml_cache.lua:51 (CACHE_VERSION = 2)`
  - **Cause:** Both defences are weaker than the docstring claims. CACHE_VERSION is the only thing standing between a shape change in a SHARED cross-driver module and an incompatible snapshot, yet nothing in the suite couples the two — the bump is pure discipline, and the code that would need bumping lives in _shared/, a different tree from the adapter that owns the constant. The fingerprint was added (version 1→2, per :50) specifically to catch a same-second edit whose size did not change, but reading only the first FINGERPRINT_READ_BYTES bytes means it covers the file's metadata header and none of the hotstring entries — i.e. it cannot detect the only edit it exists for.
  - **Fix:** (1) Replace the manual CACHE_VERSION with (or add to it) a shape signature computed at store() time from the parsed table — e.g. a sorted, recursive key-path digest of the top two levels — stored beside `ver` and re-derived from a freshly parsed reference at load time, or at minimum a meta-test that hashes _shared/lua/toml_codec/reader.lua and fails when it changes without CACHE_VERSION moving. (2) Fingerprint the WHOLE file, not the first 512 bytes: the read only happens after mtime+size already matched, and hashing a few tens of kB in pure Lua is far cheaper than the byte-by-byte parse it is protecting. If a full read is judged too costly, hash the first AND last 512 bytes plus the total b
  - **Test:** Add tests/meta/test_toml_cache_version_tracks_reader_shape.lua: read _shared/lua/toml_codec/reader.lua, compute a digest, and assert it equals a constant checked in beside CACHE_VERSION — so any reader edit forces an explicit decision to bump or re-pin. Add to tests/unit/adapters/test_toml_cache.lua a case that writes a source file > 512 bytes, stores a snapshot, then rewrites bytes 600-610 in place keeping mtime and size fixed, and asserts cache.load() returns nil. That case fails today.
- [ ] **BS-1** (boot-shutdown) — The menu's config pathwatcher — a SECOND recursive watcher on the same base_dir — has neither the TOML-cache exclusion nor the self-written-file exclusion that init.lua so carefully passes to lib/file_watchers
  - `ui/menu/menu_watchers.lua:110-138 (reload_config filter)`
  - **Cause:** Two recursive pathwatchers cover base_dir: lib/file_watchers' project_watcher and ui/menu/menu_watchers' configWatcher. init.lua computes TOML_CACHE_DIR once (line 214) precisely so 'the writer and the watcher cannot drift apart again' and threads it plus the self-written paths into lib/file_watchers.start (863-877). menu.start() arms the second watcher with only (base_dir, on_reload, get_suppress_until, ui_restore) — no ignored_dirs, no self_written_files. The exclusion was applied to one of the two watchers on the same tree.
  - **Fix:** Thread the same context into MenuWatchers.start_config_watcher: pass ignored_dirs (init.lua's TOML_CACHE_DIR) and self_written_files (menu_paths ConfigTomlPath + KarabinerConfigPath) down from menu.start, and apply the exact is_runtime_artefact / is_self_written predicates from lib/file_watchers.lua:110-134 inside reload_config. Better still: delete the duplicate watcher entirely and let lib/file_watchers own base_dir — it already watches the same tree with a strictly stronger filter, a boot-suppress window, the adaptive settle, multi-repo git gating and fire-time re-checking.
  - **Test:** New tests/unit/ui/menu/test_menu_watchers_runtime_artefacts.lua, mirroring section 3 of tests/unit/lib/test_file_watchers_reload_gate_coverage.lua: stub hs.pathwatcher/hs.timer, arm start_config_watcher on /fake/driver/, fire '/fake/driver/cache/toml_hotstrings/x_1.lua', assert no debounce timer was armed and reloads()==0; then fire '/fake/driver/modules/keymap/init.lua' and assert exactly one reload, so an exclusion that swallows the whole tree also fails.
- [ ] **BS-2** (boot-shutdown) — On the boot that installs/updates the VS Code extension, vscode_bridge.setup() throws before start_server(), so the caret bridge HTTP server never starts for that session — and it steals focus and forks a subprocess with the typing eventtap already armed
  - `init.lua:817-822 (call site`
  - **Cause:** Two independent defects compounding. (a) lib/dialog_util.M.alert wraps hs.dialog.alert but both call sites pass the hs.alert.show(message, duration) argument shape — the wrapper was written against the wrong Hammerspoon module. (b) setup() (lib/vscode_bridge.lua:349-352) chains install_extension() and start_server() with no isolation, so a throw in the cosmetic notification kills the functional half. Separately, even when it does not throw, focus_hammerspoon() (dialog_util.lua:41-70) calls hs.focus(true) and app:activate(true) twice and schedules hs.execute("open '<bundlePath>'") — a focus steal plus a fork, during boot, at a point where the typing eventtap armed at init.lua:785 is already l
  - **Fix:** In lib/vscode_bridge.M.setup, call start_server() FIRST (or wrap install_extension in its own pcall) so a notification failure can never take the server down. Fix lib/dialog_util.M.alert to forward to hs.alert.show(message, duration) — matching what both call sites pass — or fix the two call sites to the real hs.dialog.alert signature. Move install_extension() off the boot critical path (hs.timer.doAfter(0, …), the pattern init.lua already uses at lines 434 and 500) so neither the fork nor the focus steal lands while the typing tap is armed, and replace the os.execute mkdir with adapters/file_system's ensure_dir.
  - **Test:** tests/unit/lib/test_vscode_bridge_setup_isolation.lua: stub lib.dialog_util with an alert() that raises, stub the extension files so already_ok is false, stub hs.httpserver, call vscode_bridge.setup() and assert hs.httpserver.new was still called — i.e. a throwing notification cannot prevent the server from starting. Plus a meta-test asserting lib/dialog_util.M.alert and its call sites agree on one signature.
- [ ] **BS-4** (boot-shutdown) — file_watchers arms one FSEvents stream per directory AND per .toml file in the personal tree — all redundant with the recursive parent watchers, all created synchronously after the typing eventtap is already armed
  - `lib/file_watchers.lua:291-338 (watch_personal_hotstrings_dir: one hs.pathwatcher per directory at :309-317 AND one per .toml at :327-331) and :368-377 (one more per .toml in hotstrings_dir); armed from init.lua:852-877`
  - **Cause:** The per-file and per-sub-directory watchers are documented as 'a safety net for in-place edits that directory watchers may miss' (file_watchers.lua:367) — but hs.pathwatcher is already recursive and already reports individual file paths, so the parent watcher covers every one of them. The redundancy also defeats the module's own hygiene: the sub-directory watcher (:309-315) filters only `^/tmp/`, and the per-file watcher (:327-329) filters nothing at all — neither applies is_self_written or is_runtime_artefact, unlike dir_watcher and project_watcher.
  - **Fix:** Delete the recursion entirely and arm ONE recursive hs.pathwatcher on the personal-hotstrings root, routing it through the same extension + is_self_written + is_runtime_artefact filter dir_watcher uses (file_watchers.lua:272-281). Likewise drop the per-file loop at :368-377, which duplicates dir_watcher on the same directory. Cost goes from 2+D+N+M streams to 3, the boot walk (fs_dir.entries plus one hs.fs.attributes per entry) disappears, and every changed path gets the strong filter instead of the weak one. If the safety net is genuinely needed on some macOS version, arm it lazily from a doAfter(0) tick after boot rather than inline at init.lua:852.
  - **Test:** Extend tests/unit/lib/test_file_watchers.lua: with hs.fs.attributes reporting a personal tree of one directory containing three .toml files, assert #_G.script_watchers stays at a small constant (3) rather than growing with the file count — encoding 'watcher count must not scale with the corpus'. The existing stub already counts armed watchers, so the assertion drops straight in.
- [x] **FC-3** — DONE (shipped: applescript_format makes the escape structural; guard corpus is now behaviour-derived) — (fix-collateral) — f54bed73c's applescript_escape fix missed two sibling AppleScript interpolations, and its guard is a hardcoded two-symbol allowlist that cannot see them
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/menu_paths.lua:411-419 (pick_dir)`
  - **Cause:** The commit fixed the three sites the audit row named (ui/onboarding/init.lua, ui/download_window/init.lua, modules/llm/api_ollama.lua) and introduced text_utils.applescript_escape as the shared owner of the rule, but the rest of the driver was never swept for the same construct. menu_paths.pick_dir is not merely similar to the fixed ui/onboarding picker — it is the same `choose folder with prompt ... default location ((POSIX file ...) as alias)` script with the same user-configurable seed, i.e. exactly the value the commit message singles out as "the value most likely to contain one".
  - **Fix:** Route both values at menu_paths.lua:411-419 through `text_utils.applescript_escape` (the seed AND the i18n prompt), exactly as ui/onboarding/init.lua now does, and do the same for `pkg_path` at modules/karabiner/onboarding.lua:359. Then sweep the remaining quote-only escapes that land in AppleScript literals — modules/keymap/input_sources.lua:440, :682, :687, :694 use the same `gsub('"', '\\"')` on TIS identifiers — and convert them, so the rule keeps one owner.
  - **Test:** Replace the hardcoded `sources` allowlist in tests/unit/lib/test_applescript_escaping.lua:91-94 with a whole-driver walk (the same all_driver_sources helper tests/unit/meta/test_gc_retention.lua uses): strip comments, and for every line that contains an AppleScript interpolation marker (`osascript`, `hs.osascript.applescript`, `do shell script`, `choose folder`) in the enclosing function, assert that no line escaping a double quote does so without also handling the backslash or delegating to app
- [x] **hotstrings-config-save-clobbers-global-section** — DONE (shipped: [__global__] is serialised in the shape the parser reads) — (hotstrings-dynamic) — save_to_disk rewrites the shared override file from the category table only, silently erasing the [__global__] delimiter block the AHK driver wrote
  - `static/ergopti_plus/macos/modules/hotstrings/hotstrings_config.lua:220`
  - **Cause:** parse_overrides deliberately keeps [__global__] OUT of the category table — it returns word_delimiters as a separate second value (hotstrings_config.lua:97, 124-135) and `goto continue`s so nothing lands in `result`. serialize_overrides (line 220-283) iterates only `overrides`, and save_to_disk (line 288-304) truncates the file and writes that output. So a section the module parsed, holds in memory (_state.word_delimiters) and can write through a completely separate code path (set_word_delimiters' line-based in-place patcher at line 693-780) is destroyed by the OTHER writer. The AHK driver hit exactly this and fixed it — _SaveOverrides re-emits [__global__] before the categories (hotstrings_
  - **Fix:** Mirror the AHK fix in serialize_overrides: emit a `[__global__]` block first when _state.word_delimiters (and a newly parsed _state.consumed_delimiters) is non-nil, escaping through the same TOML escaper set_word_delimiters already uses (its local toml_escape at line 730), then skip any category literally named "__global__". Add `consumed_delimiters` to parse_overrides so the key round-trips instead of being dropped.
  - **Test:** New file tests/unit/modules/test_hotstrings_config_preserves_global.lua, the macOS mirror of windows/tests/unit/test_hotstrings_config.ahk §TestHotstringsConfig_SaveOverridesPreservesGlobalDelimiters. Init the module against a temp override path, call M.set_word_delimiters(" \t.,#SENTINEL#"), then M.set_override("rolls", nil, "delay", 0.5), then read the file back with io.open and assert: `helpers.assert_true(content:find("[__global__]", 1, true) ~= nil, "a delay edit must not erase the cross-dr
- [x] **resolve-not-memoised-on-preview-path** — DONE 2026-08-02. (hotstrings-dynamic) — hotstrings_config.resolve allocates a fresh closure and re-walks the cascade on every preview candidate on every keystroke; the AHK sibling memoises it
  - `static/ergopti_plus/macos/modules/hotstrings/hotstrings_config.lua:379`
  - **Cause:** The resolution result for a (category, section) pair is static between override/TOML changes, but M.resolve is written as a pure recomputation with a per-call inner closure. The AHK driver reached the opposite conclusion and added a memo: windows/lib/hotstrings/hotstrings_config.ahk:86-93 declares _HSResolveCache/_HSResolveGen with the comment "the prefix watcher resolves it per candidate on every keystroke while a tooltip is eligible. Results are cached and invalidated by bumping a generation counter on any override or group-config change". macOS has no equivalent, so the two drivers pay different costs for the same cascade.
  - **Fix:** Hoist `first_set` to a module-level local (it closes over nothing). Then add the AHK-equivalent memo: a `_state.resolve_cache` keyed by category.."\0"..(section or ""), populated in M.resolve/M.resolve_ext and cleared in M.set_override, M.clear_override and M.reload — the three writers that can change the answer. Keep it inside _state so M.init resets it naturally.
  - **Test:** New file tests/unit/modules/test_hotstrings_config_resolve_cache.lua. Init against a temp override file with a counting toml_resolver; call M.resolve("rolls", nil) twice and assert the resolver/parse was consulted once, then call M.set_override("rolls", nil, "delay", 0.25) and assert the very next M.resolve returns 0.25 — `helpers.assert_eq(mod.resolve("rolls", nil).delay, 0.25, "a memo must be invalidated by every writer, or the config window silently shows the pre-edit delay")`. The second ass
- [ ] **karabiner-stale-layout-actions-on-resume** (karabiner) — Layout rebuild re-resolves every logical_char action BEFORE the pause guard, and regenerate() never re-resolves — so resume deploys a KE config built for the pause layout
  - `static/ergopti_plus/macos/modules/karabiner/init.lua:759-777 (reload at 761-762`
  - **Cause:** The refresh of the layout-dependent action table and the consumer of that table live on different code paths. The refresh (init.lua:761-762) sits on a path that then refuses to act (the pause guard is 11 lines BELOW it), and the consumer M.regenerate() -> Generator.build_karabiner_json(_state, M.AVAILABLE_ACTIONS, …) never refreshes. Secondary: mutating M.AVAILABLE_ACTIONS while paused is itself a « pause = tout éteint » violation — a paused script rebuilds 673 action tables and writes 548 DEBUG log lines.
  - **Fix:** Hoist the `shortcuts.is_paused()` block (init.lua:773-777) ABOVE the Config.load_available_actions() call at init.lua:761-762. That makes the paused branch mutate nothing, so M.AVAILABLE_ACTIONS keeps its pre-pause (Ergopti) resolution, which is exactly what the resume redeploy needs. Optional hardening: have M.resume() arm the regenerate on LAYOUT_TIS_SETTLE_SEC instead of doAfter(0), so the TIS keycode map has settled after the resume-layout switch.
  - **Test:** New tests/unit/modules/karabiner/test_layout_rebuild_no_reload_while_paused.lua, built on the existing load_karabiner(paused) harness in test_regenerate_pause_guard.lua: additionally stub modules.karabiner.config so load_available_actions increments a counter, capture the on_change callback that karabiner/init passes to Watchers.start_input_source_watcher (and the doAfter callback it arms), drive them with shortcuts.is_paused() == true, then assert `helpers.assert_eq(reloads.count, 0, "a paused 
- [ ] **karabiner-actions-rebuilt-673-per-layout-change** (karabiner) — load_available_actions() re-decodes modifier_chords.json and rebuilds 673 action tables + 548 DEBUG log lines on every layout change
  - `static/ergopti_plus/macos/modules/karabiner/config.lua:89-130 (append_shared_modifier_chords)`
  - **Cause:** The layout-dependent part of an action is only its karabiner_to[1].key_code. The whole catalogue (file read, JSON decode, 600 table constructions, 673 label concatenations) is rebuilt to refresh that one field, and the per-action debug line was written for a handful of hand-authored actions before the 600-entry shared chord matrix was appended in front of it.
  - **Fix:** Memoise the decoded modifier_chords.json and the generated chord skeleton at module scope; on a layout change only re-run the key_code_for_char resolution over the entries that carry logical_char, mutating karabiner_to[1].key_code in place. Replace the 548 per-action Logger.debug calls with one aggregate `Logger.debug(LOG, "Resolved %d layout-dependent action(s) for the current layout.", n)`.
  - **Test:** New tests/unit/modules/karabiner/test_load_actions_memoises_chords.lua: stub the JSON loader to count how many times the shared modifier_chords.json path is opened, call Config.load_available_actions twice, then `helpers.assert_eq(chord_reads, 1, "the shared modifier-chord catalogue must be decoded once per session")`. Fails today (2), passes after memoisation.
- [ ] **capsword-probe-missing-generation-guard** (karabiner) — A terminated CapsWord probe's late callback clears the successor probe's pending flag and cancels its watchdog — the exact race the sibling layout read was generation-gated to fix
  - `static/ergopti_plus/macos/modules/karabiner/watchers.lua:162-232 (probe callback at 163-169`
  - **Cause:** The probe callback has no identity check. watchers.lua:94-105 documents this exact defect for the layout read ('Terminating a read does not cancel its completion callback … That late callback then cleared read #2's handle, released read #2's pending guard, and cancelled read #2's watchdog outright') and fixes it with _layout_read_generation; the CapsWord probe 200 lines above was never given the same guard. Note the harm is bounded: because the stale callback clears the flag and the watchdog together, _capsword_check_pending cannot latch true forever — the damage is concurrent karabiner_cli spawns plus an unprotected in-flight probe, not a permanently dead feature.
  - **Fix:** Mirror the sibling: add `local _capsword_probe_generation = 0` above deactivate_capsword; bump it at probe start and again in the watchdog before terminate(); capture `local my_gen = _capsword_probe_generation` in the closure and make line 164 `if my_gen ~= _capsword_probe_generation then Logger.debug(LOG, "Ignoring completion of superseded CapsWord probe (gen %d, current %d).", my_gen, _capsword_probe_generation); return end`.
  - **Test:** tests/unit/modules/karabiner/test_watchers_capsword_release_race.lua:196-231 already builds this exact scenario and its own comment says the assertion 'must be updated to assert #spy.tasks stays at 2 here' once callbacks become generation-gated. Do exactly that: replace `helpers.assert_true(#spy.tasks >= 2, …)` with `helpers.assert_eq(#spy.tasks, 2, "a stale terminated probe's callback must not release the in-flight probe's guard")`, and add `helpers.assert_true(watchdogs[2].fired ~= "cancelled"
- [ ] **app-category-lookup-uncached-inside-ingest-transaction** (keylogger) — Every ingest tick re-resolves each app's macOS category with a running-app scan plus an Info.plist disk read, inside the open SQLite write transaction
  - `static/ergopti_plus/macos/modules/keylogger/aggregator/sql.lua:135; static/ergopti_plus/macos/modules/keylogger/aggregator/sql.lua:158; static/ergopti_plus/macos/modules/keylogger/export.lua:123-142`
  - **Cause:** get_native_app_category is a pure function of the app name for the lifetime of the process, but export.lua:123-142 has no cache. Its result is also only used as a COALESCE fallback in the UPSERT (`category=COALESCE(agg_app_day.category, excluded.category)`, sql.lua:147 and :163), so after the first successful write the value is discarded by SQL anyway -- the disk read is pure waste on every tick but the first.
  - **Fix:** Memoise in export.lua: `local _category_cache = {}` keyed by app name, populated on first resolution, with the i18n fallback cached too so an unresolvable app is not retried every tick. Optionally skip the lookup entirely when the aggregate row already has a category -- pass a flag from sql.lua so the call is made only for genuinely new (device, date, app) triples.
  - **Test:** Extend tests/unit/modules/keylogger/test_export.lua: stub hs.application.get with a counter, call Export.get_native_app_category("Mail") twice, and assert `assert_eq(get_call_count, 1)` -- today it is 2. Add a second case asserting the negative result (app not running) is cached too, so the fallback path cannot re-scan on every tick.
- [ ] **classify-trigger-full-corpus-scan-in-eventtap** (keymap-registry) — classify_trigger linearly scans the entire ~10-15k mapping corpus with two string allocations per entry, synchronously inside the eventtap callback, on every `@` keypress — an index for two of its three answers already exists
  - `modules/keymap/registry.lua:361-377`
  - **Cause:** classify_trigger is the only per-keystroke registry entry point that does NOT use an index. Every other hot path already goes through the tail-char buckets: run_trigger_checks (keymap/init.lua:560, 585) and the preview (llm_bridge.lua:502, 546) call mappings_for_tail / mappings_for_star_tail. Two of classify_trigger's three answers are directly derivable from the existing index: `suffix` ("str is a suffix of some trigger") requires the candidate trigger's LAST codepoint to equal str's last codepoint, which is exactly the mappings_by_tail_char bucket key; `exact` is a strictly narrower case of the same bucket. Only `prefix` needs a scan, and it needs a first-codepoint index that does not exis
  - **Fix:** Keep the classify_trigger(str) -> exact, prefix, suffix contract (the existing test pins the shape and the three delegating wrappers), but source the answers from indexes: derive the last codepoint of `str`, take mappings_for_tail(that codepoint) and test only that bucket for `exact` and `suffix`; add a mappings_by_first_char index built alongside mappings_by_tail_char in rebuild_tail_indexes (registry.lua:262-290) and test only that bucket for `prefix`. Both buckets are rebuilt at the same choke point, so no new staleness surface is created. Keep the `break` once all three are known.
  - **Test:** New tests/unit/modules/keymap/test_classify_trigger_uses_index.lua. Build a registry with ~5000 case-sensitive triggers, none ending or starting with "@", plus one that does; call Registry.sort_mappings(). Then replace _state.mappings with a proxy table carrying an __index metamethod that increments a counter, call Registry.classify_trigger("foo@"), and assert: helpers.assert_true(reads < 100, "classify_trigger must consult the tail/first-char indexes, not re-scan the whole corpus on the eventta
- [ ] **LIBCORE-5** (lib-core) — app_picker.discover_apps() runs a blocking `find` subprocess plus one Info.plist read and one icon rasterisation per installed app on the main run loop, reached only through hs.timer.doAfter — which is not a thread hop
  - `static/ergopti_plus/macos/lib/app_picker.lua:34-73 — `pcall(hs.execute`
  - **Cause:** Both call sites use `hs.timer.doAfter` as if it moved the work off the thread. It does not — PROJECT_MEMORY project-hs-partial-fixes-and-false-green-tests states it verbatim ("doAfter(0) is not a thread hop"), and the same lesson is the reason ShellRunner/spawn exists and the reason network_info.lua (adapters/network_info.lua:18-25) explicitly refuses a synchronous hs.execute for its ping probe. app_picker predates that policy and was never migrated. Secondary, same file: M.build_menu:101-231 loads and resizes one icon per ALREADY-EXCLUDED app on every menu-tree rebuild (its own comment at 223-224 notes it runs twice per rebuild), so the icon cost is paid on every updateMenu(), not only when
  - **Fix:** Give discover_apps a callback and route the enumeration through `adapters.shell_runner.spawn` (async, GC-pinned in M._active_tasks) instead of `hs.execute`; populate the chooser from the completion callback. Resolve bundle IDs and icons lazily — hs.chooser renders rows on demand, so the per-app infoForBundlePath/imageFromAppBundle loop can be replaced by a memoised per-bundle lookup, and the results cached for the process lifetime (the installed-app set does not change between two clicks of the same menu). For build_menu, memoise `imageFromAppBundle(bundleID)` in a module-level table so a menu rebuild re-uses the images instead of re-rasterising them.
  - **Test:** New `tests/unit/lib/test_app_picker_no_blocking_exec.lua`: stub `hs.execute` with a spy and assert `#exec_calls == 0` after calling M.discover_apps (asserting absence of the harmful operation, per the project's own rule for this class), plus a behaviour case proving the async path still yields the full choice list through its callback. Add a second case pinning the icon memo: call build_menu twice with the same excluded list and assert `hs.image.imageFromAppBundle` was invoked once per distinct 
- [ ] **LIBCORE-6** (lib-core) — `_last_notified_tag` gates the update STATE and the menu refresh, not just the notification — so after any channel or interval change the "Update to vX" menu entry silently disappears while a release is cached
  - `static/ergopti_plus/macos/lib/updater.lua:316-328 — `notify_new_version` early-returns at line 317 when the tag matches `_last_notified_tag``
  - **Cause:** One flag serves two different jobs. Its documented job is idempotence for the user-facing toast (do not re-notify about the same release). It also, by position, gates the two state mutations that the menu label reads. The channel-switch fix (pinned by test_updater_channel_switch.lua) correctly resets `_cached_release` and `_update_state` but did not reset the flag that guards their re-population — so the reset created the exact state the guard mis-handles.
  - **Fix:** Separate the two concerns. Move `_update_state = "available"` and `update_menu_fn()` ABOVE the de-dup gate so they run on every poll that finds a newer release, and keep only `Notifier.send` behind the `_last_notified_tag` check. Additionally reset `_last_notified_tag = ""` inside M.clear_cached_release, since that function already declares itself the point at which the update state is discarded — a caller that clears the cache must not keep a guard that refers to it.
  - **Test:** Extend `tests/unit/lib/test_updater_channel_switch.lua` (or a new test_updater_renotify_after_restart.lua): with hs.http.asyncGet stubbed to return the same newer tag on demand, (1) run one poll and assert state == "available", (2) call start_background_checks again, (3) run a second poll with the SAME tag, and assert `get_update_state() == "available"` AND that the update_menu_fn spy fired — while asserting the Notifier spy fired exactly ONCE across both polls, so the toast de-dup that the flag
- [ ] **mlx-never-load-failed-when-discovery-never-succeeds** (llm-backends) — The MLX give-up backstop never starts its clock when discovery never succeeds — a server that never answers leaves the status dot orange forever and grows the pending-callback queue without bound
  - `static/ergopti_plus/macos/modules/llm/api_mlx.lua:544-564 (the discovery short-circuit returns before `_warmup_started_at` is ever stamped); static/ergopti_plus/macos/modules/llm/api_mlx_discovery.lua:271-289`
  - **Cause:** `_warmup_started_at` and the `warmup_elapsed >= WARMUP_GIVE_UP_SEC` check sit AFTER the `if not ApiMlxDiscovery.is_discovered() then … return end` short-circuit (api_mlx.lua:544-564). That placement is deliberate and pinned (see existing_test_checked) so a slow weight load is not falsely failed — but it means the give-up budget measures post-discovery warmup time ONLY. A permanent discovery failure is on no clock at all, and no other counter bounds it: the launcher's fast path (ui/menu/menu_llm/models_manager_mlx_server.lua:520-541) calls mark_load_failed only when it recognises a Python traceback in the server's stdout, which never happens if the server was never ours or never started.
  - **Fix:** Bound discovery on its own clock. Stamp `_discovery_first_attempt_at` on the first discover() of a (server, model) identity — cleared by reset() — and in api_mlx.warmup's discovery branch, before calling discover(), check that elapsed discovery time against a DISCOVERY_GIVE_UP_SEC budget read from lib.timings; on exceed call `M.mark_load_failed(model_name, true)` once and return. Also clear the budget in reset_endpoints() alongside `_warmup_started_at`. Do NOT fix this by moving the `_warmup_started_at` stamp above the short-circuit: tests/unit/llm/test_api_mlx_warmup_giveup_after_discovery.lua asserts that exact source ordering and such a change would regress it.
  - **Test:** New file tests/unit/llm/test_api_mlx_giveup_when_discovery_never_succeeds.lua. Capture notifications by installing a lib.notifications stub BEFORE the fresh `require("modules.llm.api_mlx")` (the exact technique used by tests/unit/modules/llm/test_api_mlx_load_failure.lua). Stub adapters.timer_scheduler with a controllable `now()`; stub modules.llm.api_mlx_discovery with `is_discovered = function() return false end` and `discover = function(cb) if cb then cb() end end` (a discovery that always fa
- [ ] **ollama-serve-wrapper-orphaned-on-quit** (llm-backends) — The `ollama serve` shell wrapper Ergopti launches survives every quit path and keeps appending to the Ergopti log after Hammerspoon is gone
  - `static/ergopti_plus/macos/modules/llm/api_ollama.lua:148-181; static/ergopti_plus/macos/ui/menu/menu_llm/init.lua:186-209; static/ergopti_plus/macos/init.lua:305-317; static/ergopti_plus/macos/ui/menu/init.lua:748-781; static/ergopti_plus/macos/modules/gestures/actions.lua:573-616`
  - **Cause:** MLX's detached server got explicit reaping at all three teardown sites (stop_mlx_server + terminate_helper_processes + terminate_orphan_mlx_server, replicated in the shutdown callback and in both os.exit paths). The Ollama launcher never got an equivalent. terminate_helper_processes() (ui/menu/menu_llm/init.lua:186-189) pkills only `ergopti_plus_expander` and `ergopti_plus_http_server`; terminate_orphan_mlx_server() (:198-209) targets only `mlx_lm.*server` and whatever LISTENs on the MLX port. hs.task children are not killed when the parent process exits, and os.exit() bypasses hs.shutdownCallback entirely, so nothing at all reaps this subtree. (A subsequent Hammerspoon start does clean it u
  - **Fix:** Add an ownership-gated Ollama kill to the ONE shared function all three teardown sites already call. Have api_ollama record that it actually launched the daemon (set a module flag inside the successful branch of ensure_ollama_running and expose `M.is_hs_owned_server()`), then in terminate_helper_processes() add `pcall(hs.execute, "pkill -f '[o]llama serve'", true)` behind that flag — the same is_hs_owned_bridge discipline karabiner.kill() uses so a user-managed `ollama serve` daemon is left untouched. Putting it in terminate_helper_processes() means the shutdown callback and both os.exit paths inherit it and cannot drift.
  - **Test:** New file tests/meta/test_quit_ollama_teardown.lua, modelled on tests/meta/test_menu_quit_mlx_teardown.lua. Section 1 (source): assert `helpers.read_driver_source("terminate_helper_processes")` contains an ollama kill pattern, and that all three quit sites (init.lua's shutdownCallback, ui/menu/init.lua's quit action, modules/gestures/actions.lua's script_quit) call terminate_helper_processes — so the kill can never be added to one path only. Section 2 (behavioural): load api_ollama with a ShellRu
- [ ] **preview-flushes-keylogger-on-hid-thread** (tooltip-engine-divergence) — update_preview performs two synchronous file write+flush pairs inside the keyDown eventtap callback — the exact cost the repo already deleted from the expander for this reason
  - `modules/keymap/llm_bridge.lua:748-751 and 816-822; modules/keylogger/init.lua:1232-1243`
  - **Cause:** The suggestion telemetry sits inline in the preview path instead of being deferred. This is a known cost in this codebase: tests/unit/modules/keymap/test_terminator_suggested_telemetry.lua names it explicitly in its own header — "It also cost two synchronous write+flush pairs inside the HID callback" — and the fix there was to delete the expander's duplicate call while blessing "the LEGITIMATE call … in llm_bridge.update_preview". The legitimacy of the call was settled; its placement on the eventtap thread was not. The write target is ~/.config/ergopti_plus/.../today.log, whose latency is not bounded by anything the driver controls (encrypted volume, cloud-synced config directory, a stalled 
  - **Fix:** Defer both telemetry calls off the tap: wrap them in `TimerScheduler.after(0, …)` with the values captured into locals first (the same one-tick deferral llm_bridge already uses for the render at lines 705-710, and the same shape expander.perform_text_replacement uses for its deferred update_preview at expander.lua:157-168). Because the deferral moves the throw off the eventtap stack where Hammerspoon would eat it, wrap the deferred body in a pcall with a Logger.error, exactly as expander.lua:163-166 does. A stronger variant, if the telemetry rate justifies it: give LogManager a small in-memory append queue flushed on a timer, so no telemetry call site can ever block a callback.
  - **Test:** tests/unit/modules/keymap/test_preview_telemetry_off_hid_thread.lua — modelled on the existing tests/unit/modules/keymap/test_preview_render_off_hid_thread.lua. Load llm_bridge with stubs; install a keylogger stub whose log_hotstring_suggested records the current "tick" (a counter the TimerScheduler stub increments when it drains doAfter(0) callbacks); call update_preview with a matching buffer and assert the recorded tick is > 0, i.e. the call happened on a later runloop turn, not inside the sy
- [ ] **UIMENU-7** (ui-menu) — Every pause toggle rebuilds the menubar icon TWICE (disk read + PNG decode + off-screen canvas render) synchronously inside the script-control eventtap callback
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:646-647 (pause listener) together with :881-882 (updateMenu's own first statement); body at :172-246`
  - **Cause:** `update_icon` is not a cheap setter: per invocation it does an `io.open` probe for logo_simple_disabled.png, an uncached `hs.image.imageFromPath` (file read + PNG decode), a full `hs.canvas.new` → `imageFromCanvas()` → `delete()` off-screen render round-trip to the window server, plus `setIcon`/`setTitle`. None of it is memoised — the same two PNGs are re-decoded on every call — and the pause listener duplicates the call that updateMenu already makes. Current cost: 2 × (1 file stat + 1 file open + 1 PNG decode + 1 canvas alloc/render/free + 2 menubar setters) on the eventtap-synchronous path; target: 0 on that path in the common case (icon unchanged), 1 when the variant/pause state actually 
  - **Fix:** Two zero-risk steps. (1) Delete the bare `update_icon()` at ui/menu/init.lua:646 — `updateMenu()` on the next line already calls it under pcall, so the second call is pure waste (same for the theme watcher at :1030-1033). (2) Memoise the rendered icon per (variant, paused) pair in a module-level table so the file read, PNG decode and canvas render happen at most four times per session instead of on every pause toggle, theme change and state refresh; keep the `setIcon` call itself, which is cheap. Optionally wrap the whole icon refresh in `hs.timer.doAfter(0, …)` from the pause listener so the tap callback returns immediately — but the deduplication and cache are the load-bearing part.
  - **Test:** tests/unit/ui/menu/test_pause_icon_render_once.lua: stub hs.image.imageFromPath and hs.canvas.new with counters, start the menu, invoke the registered on_pause_change callback once, and assert imageFromPath was called at most once (not twice); invoke it a second time with the same pause state and assert the counter did not grow (cache hit). Pairs with tests/unit/ui/menu/test_pause_checked_state.lua, which already covers the correctness half of the pause listener.
- [ ] **UML-6** (ui-menu-llm) — After a reload, the reattached download shows a per-file percentage as the overall progress and never a total or ETA
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua:624-643`
  - **Cause:** The reattach path was written as a stripped-down copy of `process_stream` (:346-409) but dropped the two pieces that make the number meaningful: the persistent `_bytes_done`/`_bytes_total` upvalues and the `estimated_bytes_total` lookup from `m.hardware_requirements.mlx.download_gb` in the preset tree. The session JSON carries `repo` and `model`, so the estimate is recoverable — it just is not recomputed.
  - **Fix:** Hoist `_bytes_done`/`_bytes_total`/`_current_pct` to upvalues of `reattach_download`, seed `_bytes_total` from the preset `download_gb` for `session.model` (the same lookup as :118-133), and compute the percentage from `_bytes_done / _bytes_total` exactly as `process_stream` does instead of regexing a tqdm bar. Drop the unused `_current_pct` local.
  - **Test:** New case in a tests/unit/ui/menu/menu_llm/test_mlx_reattach_progress.lua: feed `process_stream_reattached` two successive chunks `__BYTES__:1000000000` then `__BYTES__:2000000000` with a preset whose `download_gb = 4`, capture `download_window.update`'s arguments and assert the reported percentage increases monotonically and that `bytes_total > 0`. Fails today (0 and 0).
- [ ] **UIW-6** (ui-windows) — metrics_apps has two competing sources for the default app category and one hardcoded French chooser prompt, so on any non-French locale the category picker's "current" tick never matches
  - `static/ergopti_plus/macos/ui/metrics_apps/init.lua:73 (DEFAULT_APP_CATEGORY = "Général")`
  - **Cause:** The ui-windows-b-1 fix de-duplicated two literal "Général" strings into a named constant but kept it as a literal instead of pointing it at the i18n key that the sibling function already reads, so one source became two. Line 244 predates i18n adoption in this file and was never migrated.
  - **Fix:** Make the constant derive from the single source: `local function default_app_category() return i18n.get("metrics_apps.general_category") end` and use it at :241 and :258 (a module-level constant cannot be used because i18n is locale-dependent and the file is required before the locale is settled). Move the line 244 placeholder to an i18n key (e.g. metrics_apps.pick_app_placeholder) added to en.json and all 21 locales.
  - **Test:** Extend tests/unit/ui/test_metrics_apps_default_category.lua: assert the source contains no bare "Général" literal at all (the constant must be i18n-derived), and assert no `chooser:placeholderText("` call in the file takes a string literal rather than an i18n.get(...) expression. Both fail today.
