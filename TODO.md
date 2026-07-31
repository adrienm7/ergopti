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
| **I2** | One feature namespace. A feature lives at its semantic path, never under a driver name. Platforms are `windows \| macos \| linux`. A feature missing on a platform carries a translated `reason_key`. | lint rejecting any `[sections.ahk*]` / `[sections.hs*]`; add `linux` to `KNOWN_PLATFORMS` (`tools/test/test-menu-manifest.cjs:36`); platform-coverage report requiring a `reason_key` |
| **I3** | One menu. The manifest describes what the user sees; the renderer describes how this OS draws a row; the driver supplies only named actions, state getters and list providers. | `test-menu-parity` (render for the 3 platforms, diff the label trees); `action_id` ↔ handler bijection both ways; **ratchet "no menu row created outside the renderer"**, baselined at today's 265 AHK + 399 macOS + 101 Linux row-emitting sites |
| **I4** | One action registry. An action is a row of `_shared/modules/actions/actions.toml`: id, i18n keys, platforms, and either `emit` (neutral chord notation) or `native` (`family.function`). | registry ↔ handler bijection; chord-notation validity per driver; a corpus of `neutral notation → native chord` vectors replayed by the three suites; boot check that every action declared for this driver resolves |
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

- **Lot 3 — one tree.** Four independently-green steps: (a) extract `platform/`;
  (b) `lib/` → `infra/` with features promoted out — ⚠ the macOS `lib.text_utils`
  and `lib/toml/*` shims must keep their basenames, and the `lib.` → `infra.`
  prefix rewrite must touch production **and** the ~1 942 test require/stub sites
  in the same commit or every stub silently stops intercepting; (c) `ui/`
  dissolves into `modules/<feature>/{menu,window}`; (d) de-platform `_shared/` and
  repair `tools/codegen/new-driver.js` (`REPO_ROOT` resolves to `tools/`, the
  three spec paths are pre-reorg, it emits **zero** adapters and a README saying
  "Ports to implement (0)"). Then the I1 gate and the Convention S stubs.
  **Progress metric: tree-identity ratio, 18.9 % today** (10 of 53 depth-≤2
  subdirectories present in all three drivers).

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
  every hand-written row: `checked_when` (~14 rows), resolvable `action` id (12),
  `label.format` + `args` with live values (~20), `provider` for dynamic lists
  (~15 slots), `radio_group` (~5), `toggle_shape` (`parent` on macOS/Linux,
  `first_row` on AHK — already solved for the IA submenu only), declarative
  `prompt` (~12 twenty-line bodies), counts/badges (~12), the `linux` token,
  groups nested beyond one level (~4), separator semantics (re-implemented 3
  times), an `emoji` field, `visible_when` (~8), and a real top-level section list
  (the 9 head ids are read by nobody).
  Order: (1) pilot on the metrics menu — best-covered, and ~280 lines of handlers
  across two drivers become ~26 manifest rows + ~26 registry entries; (2) kill the
  five dead-manifest-key duplications and add the gate "every array key in the
  manifest has at least one reader"; (3) make Linux a first-class platform —
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
  "no menu row outside the renderer" ratchet.
  Measured payoff anchor: the layout submenu is **721 lines on macOS vs 41 on
  Windows (17.6×)** — and Windows is 41 lines *because the manifest does the work*.
  Nothing to invent: do on macOS what Windows already does.

- **Lot 6 — one action registry.** (1) Fix the **12 actions mis-declared
  `platform = "ahk"`** that are fully implemented on macOS (`select_line`,
  `teleport_mouse`, `pick_color`, `paste_plain`, `toggle_capslock`, …) — they live
  in `macos/modules/shortcuts/actions/*.lua` instead of the gesture registry, so
  the shared catalogue actively asserts the feature does not exist on macOS.
  (2) Move `_shared/modules/gestures/actions.toml` to
  `_shared/modules/actions/actions.toml` and add `emit` / `emit_<os>` / `native` /
  `default_chord` / `ports`. (3) Convert the **62 measured pure-keystroke Windows
  actions** to `emit` rows — deletes 62 AHK lambdas, 27 Lua closures and ~30 Linux
  `elseif` branches (54 % of the Windows action registry is data pretending to be
  code). (4) Write `chord.{ahk,lua}` and add the **21st port, `HotkeyRegistrar`** —
  none of the 20 has a "bind a chord to a callback" operation, which is why each
  driver invented its own. (5) Replace Windows layers A+B, which bind the same
  intent to two different physical keys because layer B is registered *before*
  `modules/keymap/layout.ahk` and therefore resolves against the OS layout instead
  of Ergopti's. (6) Give macOS the binding UI it lacks — its keyboard-slot module
  is dead machinery: `M.DEFAULTS` is empty by design and the only production
  caller of `set_action` writes `"none"`. (7) Merge
  `karabiner/data/actions.json` (73 actions, hardcoded French, no i18n keys) into
  the one registry, `holdable` becoming a per-action flag. (8) Fix the Linux
  `action_picker` bridge, which implements a **different, fictional** protocol
  (`execute`/`search`/`ready`/`close` + three hardcoded French labels) and never
  calls `init(...)`, so the page renders empty; the contract test covers 2 hosts
  of 3. (9) Replace the macOS-only `ctrl_shortcuts`/`cmd_shortcuts` and the
  AHK-only `modifier_combos` groups with one `chord_bindings` group rendered
  identically everywhere. (10) Delete the 136-line macOS hardcoded label fallback
  and the 13 `shortcuts.label_*` locale keys that duplicate an `sg_actions.*` key
  (13 pairs × 21 locales = **273 redundant translation strings**).

- **Lot 7 — the cross-cutting layer.** Order matters: (1) `linux/infra/shared_paths.lua`
  + `config_paths.lua` mirroring macOS and `windows/lib/boot.ahk` — Linux has
  **no resolver at all**: 12 independent expressions with 4 different depths and
  14 files deriving `$HOME` separately, which is why the language menu offers
  **2 locales of 21** (`../../` is one level too high) and the keylogger schema
  load is CWD-dependent (two levels too high). Gate:
  `test-shared-root-resolvers.cjs` must **execute** each expression and assert the
  file exists — never merely that the module loaded. (2) Move the macOS
  config-path SSOT out of `ui/menu/menu_paths.lua` (25 call sites): today `lib/`
  depends on `ui/menu/`. (3) **Generate the logger sub-file routing tables** from
  `sub_files.toml` — deletes two hand-rolled TOML array-of-tables parsers (150 +
  112 lines) carrying **the same fix for the same bug** ("a `]` inside a quoted
  pattern closed the array early"), and makes that bug structurally impossible.
  (4) `[logger]` section in `_shared/modules/timings/constants.toml` + single-source
  gate: retention 14 (4 copies), ring 200 (3), dedup 5 s (2 magic literals), flush
  500 ms. (5) Add the `active → en → fr` cascade to `_shared/ui/i18n.js` — it
  fetches one file and leaves missing keys **blank**, so a partially translated
  locale renders empty labels in every shared webview while all three native menus
  cascade. (6) Generate the three 21-locale tables from `locale_order.json` + a new
  `locale_names.json` (the flag column stays per-driver: flag emoji do not render
  in Windows menus). (7) **Only then** make macOS consume the shared logger core,
  and only after writing `_shared/tests/corpus/logger/behaviour_vectors.json` —
  this is the module with the worst bug history in the repo.

- **Lot 8 — the engines.** Promise **one matcher, not one engine**: the genuinely
  platform-agnostic core is ~350 lines (tail-char bucketing, suffix equality with
  case folding, the word-boundary predicate, the collision tiebreak). The other
  ~14 000 are emission, buffer/screen sync, suppression bookkeeping, TOML I/O,
  tooltip preview and OS quirks, legitimately per-driver.
  1. **Fix the corpus contract first.** `backspace_count` cannot be a cross-driver
     assertion: Windows and Linux let the triggering keystroke reach the screen
     before erasing, macOS consumes it and applies a common-prefix optimisation.
     For `btw → by the way` the right answer is 3 on Windows/Linux and 1 on macOS.
     **The corpus is wrong, not macOS** — and until this is fixed the corpus would
     reject a correct implementation.
  2. Extend the corpus to the branches measured as absent: `auto_expand`,
     `final_result`, the terminator path, star/magic-key triggers, `case_conform`,
     `is_case_sensitive_strict` (**1 302 entries use it**, documented nowhere), the
     NBSP typographic rule, the buffer cap, consumed delimiters, the
     `individual > section > file` priority levels, `is_word` as a tiebreaker.
  3. Generate the single matcher core into both target languages, modelled on
     `codegen-terminators.cjs` — it already emits both targets in one run and is
     **the only part of the engine that has never drifted**.
  4. Close the eight measured divergences, notably: Linux **never** fires a
     non-`auto_expand` hotstring (its loader does not even read the field), has no
     case propagation and no collision priority, and its default magic key is `\`
     while the shared manifest says `★`.
  5. **LLM**: prompt-builder constants from one JSON (5 hand-maintained copies
     today, already diverged); route the **six** implementations of "POST a
     completion" through the `HttpClient` port — macOS-MLX already proves the port
     suffices; generate the settings map, which deletes
     `menu_persistence_contract.json` (436 l) and its two unwired Python
     validators. Note `menu_persistence_contract.json` documents that the two
     drivers write **different keys, units and types** for the same three settings,
     so a `config.toml` is not portable — normalising that is part of the job.
  6. **Metrics**: shared aggregation core (two ~1 330-line walkers whose function
     names map 1:1, one of which says in a comment that it "MIRRORS" the other);
     eight constants declared three times where the shared copy exists only to be
     shadowed; the WPM formula written **seven** times.
  7. **Remap**: a shared tap-hold IR + three emitters
     (`emit_kanata` / `emit_karabiner` / `emit_ahk`) — today only a kanata emitter
     parked in `_shared/`. And `_shared/tap_hold/defaults.toml` must become **one**
     namespace: it is currently two unrelated files in one, describing the same
     seven physical keys with different ids, different actions and a 3–5× different
     threshold; the AHK loader ignores every `[hs_*]` header and the macOS reader
     ignores every `[tap_hold.*]` header. Also: four documents claim "no runtime
     merge" while the code merges on every boot.
  8. **Tooltip**: wire the 1 483 lines of shared JS **as an oracle** (vector
     generator + conformance harness), not as runtime. Today the gate named
     "tooltip corpus parity" requires neither JS module it claims to compare, the
     macOS test replays a clone defined inside the test file instead of the
     renderer, and the AHK test never compares the 6 golden values. Two
     `[positioning]` constants never reach Windows, with three comments asserting
     the opposite.

- **Lot 9 — the tests.** Honest ceiling: `meta/` directories alone are **84 956
  lines (44 %)** and each asserts on one driver's source text; the plan must not
  promise the suites mutualise like the drivers. Achievable: **≈ −11 500 lines**.
  | Target | Today | After | Mechanism |
  | --- | ---: | ---: | --- |
  | Corpus consumers (16 corpora, 258 vectors) | 9 122 | ~1 900 | one JSON replay schema per corpus + a ~120-line generic runner per driver |
  | Port contract vectors (129) | 2 001 | ~700 | generate `_shared/tests/corpus/ports/<Port>_vectors.json` from `contractTestVectors()` |
  | e2e harnesses | 1 319 | ~750 | one corpus-driven harness that fails loudly on a missing corpus |
  | Lua assertion library | 352 | 176 | the diff of the two files is **62 lines, all comments, banners and declaration order** |
  | Convention invariants (8, in 2–3 languages) | 1 594 | ~450 | one `.cjs` gate per invariant over the three trees — and Linux gains 6 it does not have |
  | Port presence/compliance | 1 575 | ~500 | one JS gate over `contracts.json` × the three `adapters/` trees |
  Also: **assertion argument order is inverted** between AHK (`AssertEqual(expected, actual)`) and Lua (`assert_eq(actual, expected)`) across **1 587 sites**, and `AssertEqual` is **case-insensitive** (AHK v2 `!=`), so `AssertEqual("BTW","btw")` passes — fix in a dedicated commit with the reds triaged. Skips become data (`_shared/tests/conformance/manifest.json` with `{status, reason, tracked}`), which converts the 6 Linux tautologies and the 7 `AssertTrue(true, "…macOS-only…")` skips into a ledger that cannot rot. Two macOS files (593 lines) replay 36 vectors against a **reimplementation defined inside the test**, with a docstring claiming any divergence fails — no `require` of the module; the AHK twin is 136 lines and calls the real code. 8 files under `windows/tests/` are invoked by nothing, including the **only** Windows consumer of `process_prediction_vectors.json` (17 vectors, zero CI coverage). 20 test files are named after a date or a plan phase (~2 900 lines).

- **Lot 10 — pruning.** Port the macOS reachability gate to Windows and Linux, then
  delete the **3 101 lines of dead adapter code** (12 of 21 Windows adapters and 11
  of 21 Linux ones have no production caller; the 11 Linux files come from a single
  commit written to green a presence gate). Each deletion carries the measured
  zero-consumer proof in the commit body. Shrink `contracts.json` to the ports with
  real traffic and supersede ADR-001 with the measured reality; honest demotion
  candidates: `AppLauncher`, `Crypto`, `Storage`, `ProcessLifecycle`,
  `MouseControl`, `TooltipRenderer`. Extend both purity ratchets to `ui/` and the
  entry point and add the unwatched AHK families (`SetTimer` 264 lines,
  `Hotkey/Hotstring/HotIf` 203, `Gui/Menu` 162, `Run` 59, `Win*` 54, `GetKeyState`
  45 — **874 unwatched lines**, plus 130 in `ui/` that are inside the ratchet's own
  categories but outside its scan). Route the 61 Linux module shell-outs and 54
  hand-quoting sites through `shell_runner` — it exists, its docstring explains
  exactly why (`string.format("%q")` is a Lua literal quoter, not a shell one), and
  **no module requires it**. One `npm run gen` regenerating everything
  deterministically in a single Node process, plus `npm run gen:check` writing to a
  temp dir and diffing — which also fixes by construction the fact that
  `test-features-manifest-no-drift.cjs` **silently rewrites three files it does not
  guard** (it snapshots 2 targets, runs a generator that writes 5, restores 2). One
  `_generated/` convention: same first line, same banner, no timestamps, a
  generated `README.md`, and runtime-written files moved to `_runtime/`.

### 0.6 Gates to build

`test-driver-tree-parity.cjs` (I1) · `test-shared-root-resolvers.cjs` (executes
every `_shared` resolver) · `test-menu-parity.cjs` (I3) · the "no menu row outside
the renderer" ratchet · "every manifest array key has a reader" ·
`test-logger-scalars-single-source.cjs` · `test-locale-catalogue-complete.cjs` ·
`_shared/tests/corpus/logger/behaviour_vectors.json` ·
`_shared/tests/conformance/manifest.json` + runner · boot-manifest parity gates ·
"no hand-written duplicate of shared logic".

### 0.7 Gates to extend (each hole measured)

`test-git-mv-resilience.cjs` (macOS only) · `test-no-pinned-source-reads*.cjs`
(its `HELPER_RE` certifies 139 directory-pinned files as move-resilient) · the AHK
purity ratchet (3 families of ~12; ignores `ui/` and the entry point) · the macOS
purity ratchet (ignores `macos/ui/`, 636 `hs.*` lines) ·
`test-webview-geometry-single-source.cjs` (zero Linux coverage, 3 Windows apps
absent) · `test-webview-teardown-order.cjs` (7 hosts of 12, and it pins exact
internal whitespace) · `test_jsstr_cr_escaped.ahk` (names 2 helpers of 12; **3
siblings still delete `\r` instead of escaping it**) · `test-config-schema.cjs`
(2 templates of 3) · `test-updater-constants-single-source.cjs` (excludes Linux) ·
`test-menu-labels-single-source.cjs` (blind to Linux; should become an exclusion
ratchet, which would immediately flag the AHK copy) · `test-priority-parity.cjs`
(a text scan of 3 declarations; sees neither Linux, nor the comparison-site
fallback, nor the tiebreak chain) · `gen-architecture-diagram.cjs` (**0
occurrences of "linux"** in a document titled "three-layer hexagonal
architecture") · `test-ahk-test-coverage.cjs` (`readdirSync` depth 1; ignores
`run_*.ahk` and `bench_*.ahk`) · `test-dev-tool-paths.cjs` (scoped to `tools/dev/`
while `tools/build/` carries 2 absolute machine paths).

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

1. `injector.emit_key` shells out **once per event** (`ydotool key <code>:<value>`,
   `injector.lua:227`). Under a grab that is a fork on every physical keystroke.
2. The device kanata auto-detects is not coordinated with the one `device_finder`
   picks here.

**Do not propose batching the pass-through.** `ydotool key` does accept several
`code:value` pairs in one call, so collapsing a pump batch into one fork looks
obvious — and it is wrong. `_pump_one` re-emits an event and then dispatches it,
so an injection triggered by event N would run BEFORE the re-emit of N itself.
That is precisely the interleaving this whole item exists to remove. A cheap
channel has to be non-forking, not batched: `/dev/uinput` via LuaJIT FFI, or a
persistent ydotoold client.

The remaining verification needs real evdev + ydotool hardware.

---

## 2. Tests that certify nothing

This is the highest-leverage cluster in the file, because a false green is worse
than a missing test: it actively deters anyone from writing the real one. The
repo has documented this failure mode three times already.

### Burning down the false-green baseline

The gate is delivered: `tools/test/find-false-greens.cjs` runs inside
`npm run test:js` and ratchets five classes — tautology, vacuous-absence,
dead-test, pcall-only, and `corpus-skip` (added 2026-07-31). It only turns down.

**549 → 479 so far.** `dead-test` is at **0**: the two placeholders spliced into
the body of `_DE_Add()` are gone, and the two Linux skips with empty bodies now
assert the reason they skipped for. `tautology` is 153 → 95.

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

The fix is a data-model change, not a translation pass: give each category a
stable id (the English key is already one), key `FIXED_CAT_COLORS` by id, look
the label up at render time — and migrate `app_categories.json`, mapping every
known localised spelling back to its id so existing overrides survive. Do the
migration first and prove it with a corpus of stored files in several languages.

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
`KL.Ingest` — plus a meta-test inventorying every `SetTimer` under 1000 ms
against a whitelist, so a fast poller cannot reappear silently.

### Follow-ups found while implementing

- **Five independent decodes of the same manifest at boot (~200 ms).** The four
  `_MM_*` loaders in `lib/menu_manifest.ahk` each keep their own cache, and
  `_MR_MANIFEST_CACHE` is a fifth — all decoding the same 12.5 KB file, benched
  at 44 ms per decode. Consolidating them behind `_MR_GetManifestRoot()` follows
  the per-item fix already shipped, but touches five sites and four caches:
  separate commit, and only after measuring the shipped fix in isolation.
- **Dead Ollama WinHTTP path.** `LLM_OllamaCancelAsync` has no production
  callers and `_LLM_Ollama_PollRequest` is never armed; both carry an
  `entry.Has("http")` branch that cannot be true, since the only creation site
  writes no `"http"` key. curl is the live transport. Remove under §5.6.
- **Magic numbers around the LLM health probe**: the 3 s throttle is inline and
  the 10 s interval is duplicated between `menu_llm/init.ahk` and
  `menu_llm/actions.ahk`. Name them next to `LLM_HEALTH_PROBE_IDLE_MAX_MS`.
- **Regex per keylogger event.** `MF_ShouldFilter` runs 7 `RegExMatch` over the
  window title on every logged event when `private_browsing` is on — the only
  real per-event regex site, never instructed. Either memoize per focus-cache
  generation (the title only changes on refresh, 50 ms TTL) or discard it
  explicitly with the measurement that justifies it.

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

