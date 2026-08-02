<!-- TODO.md -->

# TODO

What remains. Everything that had shipped was removed on 2026-08-02 — the file
had grown to 232 000 characters, half of it write-ups of finished work, and a
backlog nobody can read to the end is a backlog nobody reads.

Where the finished work went: the reasoning that is still worth knowing is in
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md), the decisions record
("do not re-raise") with it, and the outside-view Q&A in
[docs/IDEAS.md](docs/IDEAS.md). Everything else is in the git history of this
file, which is where a description of work already done belongs.

Working rules: no behaviour change without a regression test, never weaken a
test to make a change pass, and run the gates that cover what you touched —
`node ./tools/test/verify-change.cjs` derives them (see the `verify-change`
skill). Read [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) before starting:
several neighbouring ideas were tried and rejected with reasons.
[docs/ERGOPTI_PLUS.md](docs/ERGOPTI_PLUS.md) describes how the system works
today and holds the "how do I X" runbooks.

**Delete an entry the moment it is done.** This file is the whole remaining
backlog; nothing else tracks it. When it is empty, delete the file.

**Re-measure before you start.** Roughly one entry in six here turns out to be
stale, already fixed, or wrong about its own size once someone opens the file.
Six were corrected on 2026-08-01 and 2026-08-02 alone, including one sized at
"3 101 lines" that measured 1 549, and one whose blocker was an earlier item of
its own lot. A finding is a lead, not a work order.

---

## 0. Simplification programme

The project has the right mechanisms — hexagonal ports, a feature manifest, a
declarative menu manifest, shared Lua, cross-driver corpora, ~130 CI gates. They
are bypassed at the top, so the work is to **finish the abstractions that
already exist and delete what short-circuits them**, not to add a layer.

### The five target invariants

Each is paired with the gate that makes it true. **An invariant without a gate
is a wish.**

| # | Invariant | State |
| --- | --- | --- |
| **I1** | One tree. The same folder names under `modules/` on the three drivers; a feature a driver does not implement is a folder with an `init` that says why, never an absence. | `test-driver-tree-parity.cjs` ratchets it. **23/49 = 46.9 %.** Still to do: the Convention S stubs. |
| **I2** | One feature namespace. A feature lives at its semantic path, never under a driver name. A feature missing on a platform carries a translated `reason_key`. | Namespace half **done** — the ratchet is now an assertion of zero. The `reason_key` half is at 0 of 142 written. |
| **I3** | One menu. The manifest describes what the user sees; the renderer how this OS draws a row; the driver supplies only named actions, state getters and list providers. | `action_id` ↔ handler bijection done. The label-tree diff is not built — see §0.6. |
| **I4** | One action registry. An action is a row of `_shared/modules/actions/actions.toml`. | Bijection and chord-notation gates done. Ports (5) and the Karabiner catalogue (7) remain. |
| **I5** | One implementation per behaviour. Pure logic in `_shared/lua/`; macOS and Linux `require` it; AHK gets generated **data** or a ported twin **pinned by a shared vector corpus**. | Per-behaviour corpora exist for hotstrings, tooltip, logger, ports. The matcher codegen (Lot 8.3) is the open one. |

**The platform seam, in one sentence:** OS-uniqueness may live in exactly two
places — `adapters/` (the *how*) and a per-OS override column in shared data
(the *what*). Anywhere else it is a bug.

### Two logical modifiers, not one

Of the 24 actions implemented as a pure keystroke on both Windows and macOS, 11
are byte-identical, 2 differ only by `ctrl→cmd`, and 11 differ genuinely. A
single `mod` token resolves 2 cases out of 24, which is why there are two:

| Token | Meaning | Windows | macOS | Linux |
| --- | --- | --- | --- | --- |
| `cmdorctrl` | the modifier applications use for their own shortcuts | `ctrl` | `cmd` | `ctrl` |
| `driver` | the modifier reserved for the Ergopti+ layer | `win` | `ctrl` | `super` |

**AHK trap that survives the refactor:** for a chord whose suffix is a
character, the translator must emit `RetrieveScancode(<char>)`, never the bare
character, or the chord lands on the wrong physical key under the Ergopti
emulation. For a named key (`enter`, `home`…) the bare AHK name is correct.

### The canonical tree

> **If it has a user-visible name, it is `modules/<that name>/`. If it has a
> contract in `_shared/core/ports/`, it is `adapters/`. If it is OS-unique, it
> is `platform/`. Everything else is one flat file in `infra/`.**

Canonical `modules/` list (becomes `_shared/core/features.json`, read by the
tree-parity gate, by `new:driver` and by the drivers): `action_picker`, `apps`,
`changelog`, `diagnostics`, `download`, `dynamic_hotstrings`, `gestures`,
`healthcheck`, `hotstring_editor`, `hotstrings`, `hotstrings_config`, `layout`,
`llm`, `menu`, `metrics`, `model_browser`, `onboarding`, `paths`,
`personal_info`, `prompt_editor`, `shortcuts`, `spotlight`, `tooltip`,
`updater`, `wpm`.

Renames still to do:

| Today | Target | Why |
| --- | --- | --- |
| `windows/modules/keymap/` (physical remap) | `modules/layout/` | the same name means two opposite subsystems depending on the driver |
| `macos/modules/keymap/` (expansion engine) | `modules/hotstrings/` | idem |
| `windows/modules/tap_holds/` + `infra/tap_hold/` | `platform/remap/` | plural and singular in the same driver, wired by a `../` include |
| `macos/modules/karabiner/`, `linux/modules/kanata/` | `platform/remap/` | three names, no common parent |
| `modules/keylogger/` | `modules/metrics/` | "keylogger" is the mechanism; `_shared/ui/` already says metrics |
| `windows/ui/personal_toml_editor*` | `modules/hotstring_editor/` | the Windows name means something else on Linux |
| `windows/infra/registry.ahk` | `infra/win_registry.ahk` | name collision with the macOS hotstring registry |
| `ErgoptiPlus.ahk` / `init.lua` / `ergopti_hotstrings.lua` | `main.{ahk,lua}` | ⚠ **defer** — 7 consumer families pin these names for near-zero payoff |

Two conventions that make asymmetry legible:

- **Convention P** — `platform/` is the only word in the tree meaning "this
  differs by OS". Every driver has the same `platform/` sub-folders; one with
  nothing ships a `README.md` explaining the mechanism used instead. No file
  outside `platform/` and `adapters/` may name an OS or vendor product
  (`karabiner|kanata|webkit|webview2|hammerspoon|gtk|dbus|ydotool|autohotkey`).
- **Convention S** — the stub with a reason. Every folder of the canonical list
  exists on every driver; where unimplemented it holds an `init` with a
  `STATUS: not implemented` line and a `REASON_KEY` feeding the greyed-out menu
  entry's tooltip. ⚠ The `REASON_KEY` needs a READER first, or it is decorative
  data that `test-menu-manifest-keys-have-readers.cjs` rejects.

### The lots, in dependency order

Constraints: **paths before moves, moves before content, data before code.**

- **Lot 2 — the safety net.** ~~The per-READ counting.~~ ~~The gate's blind spots.~~
  ~~Widen the fixer and convert.~~ — **done 2026-08-02: 281 reads → 75, 104 files
  → 32.** Four things are worth keeping from it.

  *The gate was measuring a fifth of its own subject, for the third time.* Each
  earlier widening guessed at the syntax people write around `io.open`, and each
  surfaced pins that had always been there. The gate now counts the **path
  literal**, unanchored to any concatenation shape, because what a `git mv` breaks
  is the string naming the file. Fifteen files never called `driver_root()` at
  all — they rebuilt the root from `debug.getinfo`, or opened
  `"modules/keymap/llm_bridge.lua"` relative to the runner's cwd. The definition
  now lives in `tools/lint/pinned-source-read.cjs`, shared with the fixer, which
  is why the two can no longer disagree by a factor of five.

  *Two thirds of the population was never written at the read site.* A file
  declares one `local function read_source(rel)` and calls it a dozen times. The
  first pass converted 44 of 281 and looked like the start of an unbounded
  migration; it was one rewrite applied 147 times, plus 10 more behind a
  second-level wrapper (`assert_gc_pinned` → `read_source`), which only becomes
  visible if the fixer seeds itself with helpers a PREVIOUS run converted.

  *`read_driver_source` had to be made cheap first.* It re-shelled `find` and
  re-read all 201 production files on every one of its 361 call sites — the
  prescribed alternative to naming a path was the slow one. Caching it took the
  macOS suite from 333 s to 171 s.

  **The remaining 75 are a different animal** and should not be forced: tree
  walkers that enumerate the driver root, exemption inventories keyed by path
  (`test_require_state_pattern.lua`), purity ratchets over an explicit file list,
  and entry-point compile checks. For those the path IS the subject. Converting
  them means changing what the test asserts, not how it reads.

  Still open: the **AHK twin has not had the same treatment** —
  `test-no-pinned-source-reads.cjs` still matches a read expression, so its count
  is probably as understated as the macOS one was. The AHK residue each pins
  deliberately (`run_all.ahk` itself, a `_generated/` file `_DriverSourceConcat`
  excludes, a runner, or a single file carrying an ABSENCE assertion a
  directory-wide scan would weaken), but that is a claim about the count it
  reports, not about the count.

- **Lot 3 — one tree.** ~~(b) de-platform `_shared/`~~ — **done** by `4dd7b6d51`;
  both rows are out of the rename table above. Remaining: (a) extract
  `platform/`; (c) the Convention S stubs.
  The `ui/` reorganisation is done on all three drivers. If the
  `modules/<feature>/window.*` shape is still wanted, it is now one move of
  three identical trees rather than a reconciliation.

  **(a) measured 2026-08-02, and it cannot be staged by driver.** The Linux move
  was done and reverted to establish that: `git mv linux/modules/kanata
  linux/platform/remap` plus 22 reference edits is a 20-minute job and every
  Linux test stayed green — and then `test-driver-tree-parity.cjs` failed,
  correctly, because `platform/` now existed on one driver of three. Its own
  error message offers "raise this deliberately with a note saying why the
  structure is genuinely per-driver", which would be a lie: the structure is not
  per-driver, the migration is unfinished. One third of an atomic rename leaves
  the tree worse than either end, exactly as Lot 4 found.

  **The lot is gated by Windows, and Windows is 4× the estimate.** The recorded
  "34 tracked `#Include` lines" counts only includes. Counting PATH references —
  `modules/tap_holds/`, `modules/tap_holds.ahk`, `infra/tap_hold/` — gives
  **583 across 249 files**: every file's own path header comment, and a large
  set of meta-tests that assert on the include path itself
  (`test_taphold_timings_load_order.ahk` pins the literal
  `#Include modules/tap_holds/constants.ahk`). Careful: the bare identifier
  `tap_holds` is also a FEATURE id (`category_enabled.tap_holds`, the menu
  manifest, `timings/constants.toml`) and must not be renamed with the path.

  Per driver, and all three in one commit:
  - `windows`: `modules/tap_holds.ahk` → `platform/remap.ahk`,
    `modules/tap_holds/` (17 files) + `infra/tap_hold/` (2) → `platform/remap/`.
    This is also what dissolves the "plural and singular in the same driver,
    wired by a `../` include" complaint. Relative includes need per-file rules,
    not one global replace.
  - `macos`: `modules/karabiner` (14 files, 12 154 lines, 10 require sites).
  - `linux`: `modules/kanata` (2 files, 577 lines) — the known-good recipe is in
    the reverted commit's script.

  Two files are Convention P violations *by path* but are UI rather than remap —
  `linux/ui/webkit_host.lua` (249 l) and `macos/ui/menu/menu_karabiner.lua`
  (1 072 l); they need a placement decision, not a mechanical move. And
  Convention P has **no gate**: without a test asserting the forbidden-word list
  against paths it is decoration.

  ⚠ **(c) is blocked and the TODO said otherwise.** `_shared/core/features.json`
  **does not exist**, so the canonical 25-name list above has no machine-readable
  form and the tree-parity gate cannot read it. Someone must create it and teach
  the gate to use it, or Convention S stays unenforceable. The `REASON_KEY`
  reader is likewise still at zero, which
  `test-menu-manifest-keys-have-readers.cjs` rejects by design.

- **Lot 4 — one namespace.** ~~Migrate the 223 driver-namespaced tables out of the
  `[ahk.*]` / `[hs.*]` silos to their semantic path with per-entry
  `platforms`.~~ — **done 2026-08-02.** The ratchet is now an assertion of zero,
  and the config-schema break landed as approved. ~~Merge the duplicated privacy
  toggles~~ — **done**, and worse than described: there were three spellings, not
  two, and the one the driver persisted matched neither manifest id.
  ~~Extend `test-config-schema.cjs` to the Linux template~~ and ~~add `linux` to
  `KNOWN_PLATFORMS`~~ — both were **already done** before the lot was written
  (`1a3c572c2`, `4b8c635cf`).

  Two corrections worth keeping, because both cost time:

  *The reader surface was 7x the estimate.* The entry counted manifest path
  strings (22) and missed that **the section path IS the TOML section name** —
  154 further literals across 30 Windows files, plus 6 macOS `default_for("hs.…")`
  call sites that raised at load. Grepping for the *config* sections, not only
  the manifest paths, is what finds them.

  *"It cannot be staged" was right.* The manifest, the generated files, the config
  templates and the menu manifest describe the same paths. Regenerate before
  running anything — the drift guard compares the working tree against the index,
  so an unstaged regeneration reads as a failure of the change rather than of the
  sequence.

  ~~`KNOWN_GAPS.linux`~~ — **decided and closed 2026-08-02.** `[sections.script]`
  does NOT gain `linux`; the gap was in the gate. The schema hardcoded
  `"required": ["script"]` while the manifest already said `["ahk", "hs"]`, and
  the declaration that was wrong is the one that could not know about Linux.
  Presence is now derived per driver from the manifest, so the gate checks all
  eight top-level sections against each driver instead of one against all three,
  and `KNOWN_GAPS` is empty.

  ~~153 `description_key`s carry a driver name~~ — **done 2026-08-02, and it was
  not cosmetic.** The entry said "nothing is broken today". Something was:
  no locale catalogue has ever held a key under a driver prefix, so
  `menu.ahk.shortcuts.personal` missed, the fallback chain in
  `infra/manifest_descriptions.ahk` ran to its last step, and the Windows tray
  menu showed the literal word "personal" — while all 21 catalogues carried
  `menu.shortcuts.personal` for that exact row. The rename is label-preserving
  everywhere else (verified by replaying the candidate chain over 1701
  resolutions). `test-menu-labels-resolve.cjs` now holds both halves: an
  assertion of zero on driver-namespaced keys, and a **new ratchet nothing had
  ever counted — 110 of 243 manifest entries have no translated label at all**
  and fall through to their raw path tail. That failure mode is invisible by
  construction: the chain always returns something, so a missing translation
  shows up as an English identifier inside a translated menu, never as an error.
  Lot 5's menu migration is what drives that number down.

  **Still open, and it is the `linux` half:**

  1. **No feature carries `linux`.** 0 of 324. The 73 features Linux sees, it sees
     by inheriting one of 9 sections. Meanwhile the driver really implements
     `linux/modules/gestures` (858 l), `linux/modules/llm` (988 l) and
     `linux/modules/shortcuts` (385 l) — none of which the manifest admits, so per
     top-level section it reads gestures 0/109, shortcuts 0/82, llm 0/29,
     metrics 5/18. This is the data half of the problem Lot 5's menu migration
     hits from the other side.
     ⚠ Not a data-only edit: adding `linux` to a feature adds it to the Linux
     `config_template.toml`, and the config-schema gate now checks section
     presence per driver, so the template and the driver's reader move together.

- **Lot 5 — one menu.** The manifest must gain the capabilities that explain
  every hand-written row: a resolvable `action` id (12), `label.format` + `args`
  with live values (~20), `provider` for dynamic lists (~15 slots), `radio_group`
  (~5), `toggle_shape` (`parent` on macOS/Linux, `first_row` on AHK — solved for
  the IA submenu only), declarative `prompt` (~12 twenty-line bodies),
  counts/badges (~12), the `linux` token, groups nested beyond one level (~4),
  separator semantics (re-implemented 3 times), an `emoji` field, `visible_when`
  (~8), and a real top-level section list (the 9 head ids are read by nobody).

  ~~`checked_when` is done on WINDOWS only~~ — **macOS ported 2026-08-02.**
  `ManifestMenu.resolve_checked_when` mirrors `resolve_disabled_when` and keeps
  the deliberate asymmetry (`disabled_when` fails closed, `checked_when` fails
  open — both refuse to overstate what is enabled). Its test pins the pair in one
  case: both resolvers are asked about the same missing id and must disagree.
  Linux still has no manifest renderer at all, so "the remaining rows are a
  mechanical repeat" now holds for two drivers of three.

  ⚠ **Nothing here can be staged data-first.**
  `test-menu-manifest-keys-have-readers.cjs` forbids landing a manifest field
  before its reader exists, and comment-only mentions are explicitly excluded.
  Each capability is an atomic change: field + reader + rows, or nothing.
  There is also **no schema for the menu manifest**, unlike the feature manifest.

  Order: (1) pilot on the metrics menu — best-covered, and ~280 lines of handlers
  across two drivers become ~26 manifest rows + ~26 registry entries. Port
  `resolve_checked_when` to macOS first: it is the one capability that is already
  half-built, and it unblocks the three metrics filter rows that carry
  `checked_when` in the shared manifest today and are read by one driver;
  (2) write `_shared/lua/menu/render.lua` (shared macOS+Linux, ~230 l) and
  `linux/infra/menu_host.lua` (~180 l), delete `menu_builder.lua` (933 l — it is
  already fully i18n'd, so this is architecture, not translation);
  (3) migrate the macOS hotstrings then layout submenus — layout needs
  `platforms:["macos"]` rows for the TIS/bundle features first, because
  `layout_menu` currently describes a Windows-only menu that the macOS drift gate
  pins without macOS implementing it; delete
  `test_menu_hotstrings_layout_drift_gate.lua` **after**, never before;
  ~~(4) move the 1 812 lines of `macos/ui/menu/` that are not menu layout out~~ —
  **decided and measured 2026-08-02, and the premise was wrong for three of the
  five.** "Not menu layout" is not the same as "not menu". Applying the canonical
  rule — everything that is not a named feature, a port adapter or OS-unique is a
  flat file in `infra/` — needs one fact per file: is it used from outside the
  menu?

  | File | Consumers outside `ui/menu/` | Verdict |
  | --- | --- | --- |
  | `preferences.lua` (592 l) | `init.lua`, `ui/onboarding/init.lua` | **moved to `infra/`** |
  | `menu_paths.lua` (656 l) | 2 in `infra/`, several elsewhere | **split** — see Lot 7 (1) |
  | `shortcut_utils.lua` (265 l) | none — all 6 are `ui/menu/*` | **stays** |
  | `menu_state.lua` (349 l) | none — one, `ui/menu/init.lua` | **stays** |
  | `menu_watchers.lua` (222 l) | none — one, `ui/menu/init.lua` | **stays** |

  A shortcut formatter used only by menu rows is menu code, however little it
  looks like layout. Moving it would have bought a longer require path and
  nothing else.
  The `preferences` move surfaced the purity ratchet's per-tree design working:
  the modules+infra io/os baseline rose by one and the `ui/` one fell by one, so
  a relocation cannot launder an OS call in either direction. That hole is
  documented in the ratchet's own comment as having cost two bumps before each
  tree got its own frozen pair; (5) fold `_shared/modules/llm/menu_layout.json` in — ⚠ **blocked on (2)**: of
  its five row fields, `builder` and `health_dot` have no v3 counterpart, and
  `builder` is the same need as `provider` above. The file is not a duplication:
  both renderers already read it.
  Measured payoff anchor: the layout submenu is **721 lines on macOS vs 41 on
  Windows (17.6×)** — and Windows is 41 lines *because the manifest does the
  work*.

- **Lot 6 — one action registry.** Remaining: (1) write `chord.{ahk,lua}` and add
  the **21st port, `HotkeyRegistrar`** — none of the 20 has a "bind a chord to a
  callback" operation, which is why each driver invented its own; (2) replace
  Windows layers A+B, which bind the same intent to two different physical keys
  because layer B is registered *before* `modules/keymap/layout.ahk` and
  therefore resolves against the OS layout instead of Ergopti's; (3) give macOS
  the binding UI it lacks — `M.DEFAULTS` is empty by design, `get_action` /
  `get_slot_label` / `get_assignments` have **0** production callers, and the one
  writer is a reset routine for a feature that cannot be configured
  (`test-keyboard-slot-surface-is-dead.cjs` holds the measurement); (4) merge
  `macos/modules/karabiner/data/actions.json` (73 actions, hardcoded French, no
  i18n keys) into the one registry, `holdable` becoming a per-action flag —
  **18 of the 73 already have `sg_actions.*` keys in all 21 languages, 55 do
  not**, and the merge must come before the translations or ~1 700 strings get
  keyed to ids that are about to change; ~~(5) the host→page push for the Linux
  `action_picker`~~ — **done.** `webview_manager.eval_js(app, js)` is the channel,
  addressed by app name so a handler never holds a webview past its window's
  life. Worth reusing: it is the only host→page direction on Linux, and any other
  shared page that needs to be HANDED its data now has one; (6) replace the
  macOS-only `ctrl_shortcuts`/`cmd_shortcuts` and the AHK-only `modifier_combos`
  groups with one `chord_bindings` group rendered identically everywhere.

- **Lot 7 — the cross-cutting layer.** Remaining: (1) move the macOS config-path
  SSOT out of `ui/menu/menu_paths.lua` — today `infra/` depends on `ui/menu/`.
  **Re-measured 2026-08-02, and it can be staged rather than done in one cut.**
  The file is 656 lines and holds TWO concerns: path resolution (`init`, `get`,
  `get_config_dir`, the paths.toml bootstrap load/save — roughly lines 78-350)
  and a webview form panel (`open_editor`, `build_menu_item`). Only the first
  belongs in `infra/`.
  The dependency INVERSION the item names is narrower than the 63 references
  suggest: exactly **two** `infra/` files import it — `personal_hotstrings.lua`
  and `personal_shortcuts.lua` — and both use only `get(key)`. So step one is
  extracting the resolution half into `infra/config_paths.lua` (the name Linux
  already uses, so this converges the two drivers as well) and re-pointing those
  two; `ui/menu/menu_paths.lua` then requires it, which is the correct direction.
  Every other caller can move afterwards, or never.
  ⚠ **It is not a pure cut, and the boundary is wider than "lines 78-350".**
  Re-read 2026-08-02: resolution is lines 30-379, and that includes
  `persist_config_dir_for_wizard` (l.364-379), which sits past the stated
  boundary and is called from `ui/onboarding/init.lua:413`. The GUI half
  (`apply_and_reload`, `inject_init_data`, `handle_message`, `pick_dir`,
  `open_editor`) writes `_bootstrap` and calls `save_bootstrap()` / `ensure_dir()`
  directly, so `infra/config_paths.lua` must expose a WRITE api, not only
  `get`/`get_config_dir`. The upside is real: `apply_and_reload` is a near-
  duplicate of `persist_config_dir_for_wizard`, so the extraction collapses two
  writers of paths.toml into one. `M.init`'s two arguments also split across the
  two modules, so `init.lua:191` and `ui/menu/init.lua:136-137` must be
  reconciled in the same commit.
  ⚠ Do it on a fresh context, not at the end of a long pass: this resolves the
  config directory for every personal file, and the failure mode is a path that
  resolves to a directory that EXISTS and holds nothing — silent, and the shape
  of five separate wrong-depth bugs already recorded in this repo. `test-shared-root-resolvers.cjs`
  executes the resolvers for real and stats every answer, so build the equivalent
  coverage for this one before moving it, not after — a macOS phase modelled on
  its §3, stat every `get(key)` plus `get_config_dir()` and
  `get_default_config_dir()`, HOME set and unset, paths.toml present and absent;
  (2) **only then** make macOS consume the shared logger core, and
  only after writing `_shared/tests/corpus/logger/behaviour_vectors.json` — this
  is the module with the worst bug history in the repo.

- **Lot 8 — the engines.** One matcher, not one engine: the genuinely
  platform-agnostic core is ~350 lines; the other ~14 000 are emission,
  buffer/screen sync, suppression bookkeeping, TOML I/O, tooltip preview and OS
  quirks, legitimately per-driver.
  1. **Adopt the shared matcher core** — re-measured 2026-08-02 and the framing
     was wrong twice. A 526-line shared core already exists; it reaches Linux
     only, so the work is bringing macOS and Windows onto it, not generating a
     new one. And `codegen-terminators.cjs` is not a usable model: its Lua output
     is 44 lines of *data*, and no generator in this repo emits a Lua function.
     Two obstacles the entry omitted: Windows carries ~100 lines of star-trigger
     indexing with no counterpart in the shared engine, and macOS's `would_fire()`
     is documented as the single source of truth used by the tooltip preview as
     well — replacing it risks the exact divergence its docstring says was
     already fixed once.
  2. **LLM**: fold the prompt-builder constants into one JSON.
     **Re-measured 2026-08-02, and the priority is lower than it reads.** Of the
     three declarations one is GENERATED (`windows/_generated/prompt_builder.ahk`),
     so the hand-maintained duplication is two, not three: `_shared/lua/llm/`
     and `_shared/core/domain/PromptBuilder.js`. And
     `test-prompt-builder-constants-parity.cjs` catches BOTH classes of drift,
     verified by probe: a changed VALUE, and a constant added to one declaration
     and not the others ("declared in 1 of 3 language(s) — absent from shared
     Lua, generated AHK").
     So this is consolidation for its own sake rather than risk reduction — the
     purity argument ("three declarations agreeing is not one declaration")
     stands, the exposure does not. Doing it properly means a JSON plus a
     generator emitting the Lua as well as the AHK, on the
     `codegen-terminators.cjs` pattern, and wiring both into the generator
     registry and the drift guard. Worth doing when that machinery is already
     being touched; not worth a dedicated risky pass.
  3. **Metrics**: shared aggregation core — two ~1 330-line walkers whose
     function names map 1:1, one of which says in a comment that it "MIRRORS" the
     other; eight constants declared three times where the shared copy exists
     only to be shadowed.
  4. **Remap**: a shared tap-hold IR + three emitters (`emit_kanata` /
     `emit_karabiner` / `emit_ahk`) — today only a kanata emitter parked in
     `_shared/`. And `_shared/tap_hold/defaults.toml` must become **one**
     namespace: it describes the same seven physical keys under two headers with
     different ids (`left_ctrl`/`left_control`, `left_alt`/`left_option`) and
     different actions (`caps_lock` holds **ctrl** under `[tap_hold.*]` and
     **cmd** under `[hs_tap_hold]` — that one is the genuine `cmdorctrl`
     distinction, not drift; `tab` taps `alt_tab_monitor` vs `alt_tab_windows` —
     that one is drift). The AHK loader ignores every `[hs_*]` header and the
     macOS reader ignores every `[tap_hold.*]` header. `right_ctrl` has **no
     macOS counterpart at all**, so the key that taps `one_shot_shift` on Windows
     and Linux is simply unconfigured there.
     The threshold half is closed: macOS was 1000 ms against 200–350 ms, now 250,
     held by `test-tap-hold-threshold-parity.cjs`. What remains is that macOS has
     ONE global where the others have one value per key; the generator already
     supports the per-manipulator override, so it is wiring, blocked on the id
     vocabularies above.
  5. **Tooltip**: wire the 1 483 lines of shared JS as an ORACLE (vector
     generator + conformance harness), not as runtime.
     ⚠ Known latent divergence, deliberately left: the macOS renderer branches
     two ways (`caret`, and everything else as a window anchor) where the shared
     JS branches four. `resolve_anchor()` only ever produces the four the
     renderer agrees on, so it is latent, not live — adding the missing branches
     would add dead code.
     ⚠ `anchor_cascade` in `[positioning]` is read by **no driver**, is labelled
     "informative", and its own neighbouring comment says AHK adds a step it does
     not list. An informative constant that contradicts the prose beside it is
     worse than prose alone.

- **Lot 9 — the tests.** Honest ceiling: `meta/` directories alone are **84 956
  lines (44 %)** and each asserts on one driver's source text; the plan must not
  promise the suites mutualise like the drivers. Achievable: **≈ −13 400 lines.**

  Re-measured 2026-08-02 — every row's "today" figure had drifted, and one row's
  mechanism is already built:

  | Target | Today | After | Mechanism |
  | --- | ---: | ---: | --- |
  | ~~Convention invariants~~ | ~~392~~ | **0** | **done** — `lint-conventions.js --fail-on-violations` |
  | Corpus consumers (16 corpora, 258 vectors) | 7 650 | ~1 900 | one JSON replay schema per corpus + a ~120-line generic runner per driver |
  | Port contract vectors (129) | 2 138 | ~700 | generate `_shared/tests/corpus/ports/<Port>_vectors.json` from `contractTestVectors()` |
  | Port presence/compliance | 1 473 | ~500 | one JS gate over `contracts.json` × the three `adapters/` trees |
  | e2e harnesses | 1 374 | ~750 | one corpus-driven harness that fails loudly on a missing corpus |

  **Convention row closed 2026-08-02.** The four
  `test_{file,section}_headers.{lua,ahk}` went first — the alignment pair could
  only fail if it could not read a file. `test_no_pascal_case_in_toml.{lua,ahk}`
  (239 l) followed, and the check to run first was the right one: the JS gate did
  NOT reach the same files. It scanned `_shared/` only, while the driver tests
  scanned their own trees — between them four effective files, and **Linux had no
  such gate at all**. Widening the linter to the three driver trees (carrying the
  `paths.toml` exclusion over rather than inventing it) is what made the deletion
  a net gain in coverage instead of a loss.

  Every other row means writing the replacement first.

- **Lot 10 — pruning.** ~~Port the macOS reachability gate to Windows and Linux,
  then delete the dead adapter code~~ — **done.** Kept here only for the rule it
  established: all three drivers are held at **zero** unreferenced adapters, and
  `contracts.json` is deliberately NOT shrunk — all twenty ports have real
  traffic on macOS, Windows or both, so the ports were never the thing that was
  wrong. See [ADR-008](static/ergopti_plus/docs/adr/008-ports-are-contracts-not-a-checklist.md).

### Gates to build

`test-menu-parity.cjs` (I3), the label-tree half: render for the three platforms
and diff the label trees. **Blocked, deliberately:** the menu manifest carries no
`linux` platform value anywhere — 27 rows are `[ahk]`, 19 `[hs]`, 2 both — so
Linux "sees" 76 rows only because an unrestricted row defaults to every platform,
while `menu_builder.lua` builds its rows by hand. Diffing the three trees today
would report that migration, not a defect. It follows Lot 5 (2).

### Gates to retire — after migration only

- `macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua` (after Lot 5.3)
- `test_menu_top_level_drift_gate.{lua,ahk}` (once the tail is manifest rows with
  registry-validated ids — **and a Linux twin exists first**)
- ~~`linux/tests/unit/meta/test_port_adapter_presence.lua` (9 hardcoded names)~~ —
  **already rewritten** under ADR-008: it enumerates from the filesystem and
  asserts every shipped adapter loads, which is the direction that was silent.
- ~~`windows/tests/COVERAGE.md` and `macos/tests/COVERAGE.md`~~ — **deleted.** They
  claimed "keylogger: 0% covered" against 66 keylogger test files and "ui/: 0%
  covered (intentional)" against 118, and every roadmap item in the Windows one
  had shipped. `docs/TESTING.md` states the rule they broke: the inventory of
  checks is the run itself.

---

## 1. Tests that certify nothing

The highest-leverage cluster, because a false green is worse than a missing
test: it actively deters anyone from writing the real one.

`tools/test/find-false-greens.cjs` runs inside `npm run test:js` and ratchets six
classes — tautology, vacuous-absence, dead-test, pcall-only, `corpus-skip` and
`unfloored-scan`. It only turns down. Frozen 2026-08-02 at tautology **45**,
pcall-only **203**, unfloored-scan **4**, the other three at 0.

The work is burning those floors down. Each occurrence is either a real false
green to fix or a justified shape to document in the test itself —
`--update-baseline` after saying why. Use `--list` for file:line, `--pattern=<key>`
to filter.

**Where the real work is, measured rather than assumed:**

- **tautology (45 → 35): the sole-assertion ones are the real find**, and ten are
  now done. 32 of the original 45 were the ONLY assertion in their case, so the
  whole case certified nothing; 15 of those mention "pause".

  The pattern in every one fixed so far: the case was a **design claim written as
  a test** — "this module is pure, the pause gate lives higher" — asserted with
  `assert_true(true)` and that sentence as the message. The claim is true and
  worth holding; what it needed was to be checked. Each became an assertion that
  the pause coupling is absent from the module's source, or that the guard is the
  first statement of the keystroke path, and each was proved red by reintroducing
  the coupling.

  ⚠ **One of them was blocked by the harness, not by the test.**
  `test_actions_system.lua` said in a comment that it "cannot easily assert the
  exact watch_types without deep introspection of the eventtap stub". The stub
  was the problem: `hs.eventtap.new` discarded both arguments, and
  `event.types` carried 5 of the 12 types the driver names. Because keep-awake
  builds its watch list as a table constructor starting at `ev.scrollWheel`, a
  missing type left a nil at index 1 and `ipairs` yielded NOTHING — the watcher
  was created watching an empty set in every test run. When a test says it cannot
  assert something, check whether the harness is what made it impossible.
- ~~**unfloored-scan (24): only a handful are genuine** — the rest already carry a
  floor in a shape the detector does not recognise.~~ — **detector fixed, 24 → 4.**
  Four blind spots closed: a Lua collector `t[#t+1] = v` (the regex required AHK
  `:=`), an assertion wrapped across lines (the pattern forbade `\n`),
  `assert_eq(#x, n)` in either argument order (a comma, not an operator), and a
  scan whose subject came from `read_driver_source()` and is asserted `~= nil` —
  which is not a null check but the statement "the selector matched a real file".
  The four survivors are the honest ones. Two negative probes confirm the
  recognisers do not over-clear, and a synthetic unfloored scan is still caught.

Two shapes the detector **cannot** see, to hunt by hand:

- a harness that stubs the very function the test claims to verify;
- a source-grep pinning the current SPELLING of the code, not the invariant.
  ~~`test_pause_checked_state.lua`~~ — **fixed**: it ANDed two spellings no single
  line can carry, so the count was structurally 0. Worth knowing as a *shape*: an
  AND across alternative spellings is a tautology the detector cannot see, and
  this file had one. Grep the suites for `find(…) and …find(…)` on the same line.

---

## 2. Performance — instrumentation first

What is left is mostly **unmeasured**, and silence reads as "optimal".

**Prerequisite before any further tooltip work:** sub-segment
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

---

## 3. Audits

Prompts live in [`docs/prompts/`](docs/prompts/) — work from the prompt, not from
a summary.

**`audit_mise_en_commun_et_simplification.md` has never been run.** It covers
pushing everything non-platform-specific into `_shared/` and reducing mass: are
the `_generated/` trees still earning their committed size, can `_shared/` be
flattened, god-files, orphan tooling. One correction to apply when running it: it
says to confront your conclusions against `docs/REFACTOR_PLAN.md`, which no
longer exists — `PROJECT_MEMORY.md` is now the only canonical memory.

`perf_hs.md` and `refactor.md` — check PROJECT_MEMORY before running; the
refactor cycle the latter belongs to was declared complete.
