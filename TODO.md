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
  "no menu row outside the renderer" ratchet.
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
  setting. 19 sites → 3, all inside the resolver, and the gate holds it. Gate:
  `test-shared-root-resolvers.cjs` must **execute** each expression and assert the
  file exists — never merely that the module loaded. (2) Move the macOS
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
  change with its own reds. (6) Generate the three 21-locale tables from `locale_order.json` + a new
  `locale_names.json` (the flag column stays per-driver: flag emoji do not render
  in Windows menus). (7) **Only then** make macOS consume the shared logger core,
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
  `""` stays distinct from `0`, `true` stays `1`, objects stay identity-compared. Skips become data (`_shared/tests/conformance/manifest.json` with `{status, reason, tracked}`), which converts the 6 Linux tautologies and the 7 `AssertTrue(true, "…macOS-only…")` skips into a ledger that cannot rot. Two macOS files (593 lines) replay 36 vectors against a **reimplementation defined inside the test**, with a docstring claiming any divergence fails — no `require` of the module; the AHK twin is 136 lines and calls the real code. 8 files under `windows/tests/` are invoked by nothing, including the **only** Windows consumer of `process_prediction_vectors.json` (17 vectors, zero CI coverage). 20 test files are named after a date or a plan phase (~2 900 lines).

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
  categories but outside its scan). Route the Linux module shell-outs through
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
  against the wrong item. That label is one of the 101 tracked in Lot 5(3). One `npm run gen` regenerating everything
  deterministically in a single Node process, plus `npm run gen:check` writing to a
  temp dir and diffing — which also fixes by construction the fact that
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

`test-driver-tree-parity.cjs` (I1) · `test-shared-root-resolvers.cjs` (executes
every `_shared` resolver) · `test-menu-parity.cjs` (I3) · the "no menu row outside
the renderer" ratchet · "every manifest array key has a reader" ·
`test-logger-scalars-single-source.cjs` · `test-locale-catalogue-complete.cjs` ·
`_shared/tests/corpus/logger/behaviour_vectors.json` ·
`_shared/tests/conformance/manifest.json` + runner · boot-manifest parity gates ·
"no hand-written duplicate of shared logic".

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

