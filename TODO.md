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
| **I1** | One tree. The same folder names under `modules/` on the three drivers; a feature a driver does not implement is a folder with an `init` that says why, never an absence. | `test-driver-tree-parity.cjs` ratchets it: **25/47 directories = 53.2 %**, and now **14/25 canonical features on all three** — the list is machine-readable at last. Still to do: the Convention S stubs, blocked on the `REASON_KEY` reader. |
| **I2** | One feature namespace. A feature lives at its semantic path, never under a driver name. A feature missing on a platform carries a translated `reason_key`. | Namespace half **done** — the ratchet is now an assertion of zero. The `reason_key` half is at 0 of 142 written. |
| **I3** | One menu. The manifest describes what the user sees; the renderer how this OS draws a row; the driver supplies only named actions, state getters and list providers. | `action_id` ↔ handler bijection done. The label-tree diff is not built — see §0.6. |
| **I4** | One action registry. An action is a row of `_shared/modules/actions/actions.toml`. | Bijection and chord-notation gates done, and the `HotkeyRegistrar` port now carries one chord notation across both drivers. The Karabiner catalogue remains; two of Lot 6's rows turned out not to be actionable as written. |
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

The canonical list now lives in **`_shared/core/features.json`**, not here —
`test-driver-tree-parity.cjs` reads it and ratchets how many of the 25 features
are present on all three drivers (**14** today). Each entry carries the `tree` it
belongs to, because the one-line rule above is not quite true: a feature the user
OPERATES is a module, one the user LOOKS AT is a window, and **ten of the 25 are
windows** under `ui/`.

Renames still to do:

| Today | Target | Why |
| --- | --- | --- |
| `windows/modules/keymap/` (physical remap) | `modules/layout/` | the same name means two opposite subsystems depending on the driver |
| `macos/modules/keymap/` (expansion engine) | `modules/hotstrings/` | idem |
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

  ~~Still open: the AHK twin has not had the same treatment~~ — **done, and the
  suspicion was right in both directions.** Its alternation said
  `modules|lib|ui`: `lib` had matched nothing since the rename to `infra/`,
  `adapters/` was never listed although all three drivers have one, and
  `ErgoptiPlus.ahk` is in no sub-tree so no directory arm could reach it — 24
  files and 145 literals had been pinned the whole time. The baseline ALSO
  carried slack the other way (16 files frozen against a measured 7, 326 literals
  against 235), which is why neither error ever surfaced. Honest: **31 files /
  380 literals**, and `platform` is listed ahead of Lot 3 so the extraction could
  not land unseen. The AHK conversion itself is not started; the residue that
  pins deliberately (`run_all.ahk`, a `_generated/` file `_DriverSourceConcat`
  excludes, a runner, an ABSENCE assertion a directory-wide scan would weaken)
  describes a shape, not that number.

- **Lot 3 — one tree.** ~~(b) de-platform `_shared/`~~ and ~~(a) extract
  `platform/`~~ — **both done.** Remaining: (c) the Convention S stubs.

  **(a) done 2026-08-02, all three drivers in one commit** — 516 references
  across 172 files. Tree parity 23/49 → **25/47 (53.2 %)**.
  `macos/ui/menu/menu_karabiner.lua` became `menu_remap.lua` in the same pass:
  the menu is about remapping, not about a vendor. Convention P now has the gate
  it lacked — `test-convention-p-platform-only.cjs` ratchets vendor-named paths
  outside `platform/`, `adapters/` and `vendor/` (**3 remain**) and asserts
  `platform/` is symmetrical across the drivers.

  The recorded size was wrong: "583 references across 249 Windows files" counted
  the bare identifier `tap_holds`, which is also a FEATURE id. The paths measured
  **490 across all three drivers**.

  **Two silent holes the move exposed, both now gated — this is the part worth
  keeping.** The AHK suite went from 3626 tests to 3607 **with zero failures**:
  twenty scanners enumerate a driver's source by a hardcoded list of top-level
  folders, and `test_ahk_brace_balance` registers one case per file under
  `["infra", "modules", "ui"]`, so nineteen cases stopped existing and nothing
  said so — its own floor could not fire, because the other trees still had
  files. And `test_tap_hold_suspend_boundary` scanned its directory with a raw
  `Loop Files` on a hardcoded path, so when the pattern stopped matching its
  per-file assertions became unreachable.
  `test-source-trees-are-scanned.cjs` now requires any list naming `modules/` or
  `infra/` to name `platform/` too, because that is where things move *out of*.

  `linux/ui/webkit_host.lua` (249 l) is the last Convention P violation that
  needs a decision rather than a move: it is genuinely OS-unique, so it belongs
  under `platform/` once the other two drivers have a `platform/webview/` to be
  symmetrical with. Windows has WebView2, macOS WKWebView — the same concern
  under three vendor names, exactly like remap was.

  **(c): the list half is done 2026-08-03, the stub half is still blocked.**
  `_shared/core/features.json` now exists and `test-driver-tree-parity.cjs` reads
  it, so I1 finally has the measurement it was missing — comparing the drivers to
  EACH OTHER says nothing about a feature none of them has, and cannot tell a
  deliberate absence from an oversight. **14 of 25 canonical features are present
  on all three drivers**, 5 partial, 6 nowhere; frozen, and red if a feature
  loses its canonical path.

  *Writing the file corrected the list.* The prose said every named feature is
  `modules/<name>/`. The tree disagrees and the tree is right: a feature the user
  OPERATES is a module (gestures, llm, shortcuts), one the user LOOKS AT is a
  window in `ui/` (action_picker, changelog, model_browser) — **ten of the 25 are
  windows**. Forcing them into `modules/` would have been a rename in service of
  a sentence, so each entry carries its `tree`.

  *And it named the six that Convention S cannot stub.* `apps`, `download`,
  `hotstrings_config`, `layout`, `metrics` and `personal_info` have no folder
  under their canonical name on ANY driver — the capability exists, spread
  through another module, so there is nothing to stub *around*: the work is
  extraction, not a README.

  ⚠ **The stubs themselves are still blocked**, on the `REASON_KEY` reader:
  `test-menu-manifest-keys-have-readers.cjs` rejects a manifest field before its
  reader exists, and ~50 stub folders whose reason nothing displays is exactly
  the decorative data it refuses. Order: reader, then stubs.

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

  1. ⚠ **"No feature carries `linux`, 0 of 324" is true and describes the wrong
     thing — re-measured 2026-08-02.** It reads like a labelling job. It is not:
     of the **ten config surfaces the Linux driver actually reads or writes,
     ZERO are declared for it**, and most do not exist in the manifest at all.

     | Surface | State |
     | --- | --- |
     | `script.locale`, `llm.enabled` | declared for `ahk`+`hs` only — Linux writes them anyway |
     | `script.layout`, `script.onboarding_done` | no manifest entry |
     | `llm.model` | no entry, **and `llm.models.ollama` already means this** |
     | `llm.ollama_url`, `llm.prompt` | no entry |
     | `paths.*` | no section at all |
     | `linux.gestures`, `linux.action_parameters` | a **driver-namespaced silo** — the exact shape Lot 4 dissolved for `[ahk.*]` and `[hs.*]`, read as a TABLE so no key-level scan ever saw it |

     So adding `linux` tokens to existing features would not have fixed it. The
     work is: dissolve the `[linux.*]` silo (I2, and it needs `[sections.gestures]`
     to gain `linux` plus the slot vocabulary reconciled), re-point `llm.model` at
     the canonical `llm.models.*` rather than declaring a second name for it, and
     declare the rest with `platforms = ["linux"]` so only the Linux template
     grows.
     ⚠ Do not guess the semantics. `llm.models.ollama` is a MODEL NAME while
     Linux's `ollama_url` is an endpoint — they are not the same key under two
     names, and mapping one onto the other silently breaks the Linux LLM.

     `test-driver-config-surface-is-declared.cjs` ratchets this at **11** (the
     eleventh is macOS: `ui/onboarding/init.lua` persists `[hotstrings] enabled`,
     which the manifest has never declared — its own comment says so). Each row
     driven to zero is one setting that gains a default, a type, a schema entry
     and a menu row.

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

- **Lot 6 — one action registry.** ~~(1) write `chord.{ahk,lua}` and add the
  **21st port, `HotkeyRegistrar`**~~ — **done 2026-08-03.** `_shared/lua/chord`
  (macOS + Linux) and `windows/infra/chord.ahk` are pinned to one corpus,
  `_shared/lua/chord/vectors.json`, run by both suites. Both drivers' configurable
  shortcut slots now resolve through it. The two Windows `Hotkey()` calls that
  depend on `InputLevel` were deliberately left out: the port has no notion of
  AutoHotkey event routing and inventing one would have been a plausible-sounding
  abstraction that is wrong. Two finds along the way — the `hs.hotkey` stub
  returned `{delete = noop}`, making every lifecycle assertion against it
  vacuously true, and `KEYBOARD_SHORTCUT_SEND_CODES` held one override the
  generic path already produced.
  ⚠ **(2) could not be located, re-measured 2026-08-02.** Nothing in the Windows
  driver is named "layer A" or "layer B", and the ordering the entry blames is
  already the other way round: `ErgoptiPlus.ahk` includes
  `modules/keymap/layout.ahk` (l.897) *before* `modules/shortcuts.ahk` (l.898).
  Either the names come from a vocabulary that no longer exists, or the bug went
  away with the include order. Whoever remembers what A and B were should rewrite
  this row or delete it; as written it cannot be acted on;
  ~~(3) give macOS the binding UI it lacks~~ — **done 2026-08-03.** Five modifier
  groups in the Shortcuts menu, wired to the shared webview picker twice (which
  chord, then what it does), over the same 40-key catalogue the gesture actions
  and the Windows driver already read. The renderer gained a `list` item type so
  this could land without regressing I3: the manifest names the section, the
  driver hands over row DATA, and the renderer alone turns it into menu rows —
  rows built outside the renderer stayed at 301. The dead-surface gate was
  replaced by `test-keyboard-slot-surface-is-live.cjs`, which asserts the
  opposite invariant. The Windows follow-up landed the same day: its
  `InsertKeyboardShortcutGroups` splice is gone, both drivers read the section
  from one manifest entry, and Windows rows built outside the renderer went
  222 → 220. Both of that splice's regression tests were re-encoded against the
  new structure, not retired;
  (4) merge
  `macos/platform/remap/data/actions.json` (73 actions, hardcoded French, no
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
  ⚠ **(6) re-measured 2026-08-02: it conflates two things and is blocked.** The
  three groups are not the same shape or the same subject. `modifier_combos` is a
  manifest group with three declared feature rows (`shortcuts.alt_gr_lalt`,
  `alt_gr_caps_lock`, `lalt_caps_lock`) — *which modifier pairs activate a
  layer*. `ctrl_shortcuts` / `cmd_shortcuts` have no manifest rows at all: they
  are `group_builders` supplied by `macos/ui/menu/menu_shortcuts.lua`, listing
  *the ctrl/cmd emulation shortcuts*. Merging them is not a rename, it is a
  decision about whether those two subjects are one; and even if they are, a
  declarative group cannot absorb a builder until Lot 5's `provider`/`builder`
  capability exists. It follows Lot 5 (1), not the rest of Lot 6.

- **Lot 7 — the cross-cutting layer.** ~~(1) move the macOS config-path SSOT out of
  `ui/menu/menu_paths.lua`~~ — **done 2026-08-02.** `infra/config_paths.lua` holds
  resolution; `menu_paths.lua` keeps the webview form and delegates; `init.lua`
  initialises the resolver directly and the editor's reload callback is wired by
  `ui/menu/init.lua`, the only caller that can act on it. **One writer** of
  paths.toml where there were two: `set_config_dir` returns whether anything
  moved, and reloading is the caller's decision — which is the entire difference
  between the wizard (must not reload, or it restarts mid-flow) and the editor.

  *The coverage came first, and writing it found a lying stub.* `hs.fs.mkdir`
  returned `true` and created nothing, so production code that verifies its own
  mkdir with `hs.fs.attributes` — as `ensure_dir` does deliberately, because
  LuaFileSystem returns nil rather than raising — saw the create succeed and the
  directory stay missing. **No directory-creation invariant was testable at all.**
  That is the harness-stubs-the-subject false green, the one class the detector
  cannot see, and it is why this coverage did not already exist. The stub is
  honest now and nothing else needed changing for it.

  The purity ratchet moved 5 calls from the `ui/` pair to the modules+infra pair,
  exactly as the `preferences` relocation did: the driver total is unchanged and
  neither tree can launder an OS call through the other.

  Remaining: (2) make macOS consume the shared logger core. **The corpus
  prerequisite is done, 2026-08-03.**
  `_shared/tests/corpus/logger/behaviour_vectors.json` exists and all three
  suites replay it: severity filtering, the lifecycle-pair rule, and the ring
  buffer including both boundaries either side of capacity. Writing it found the
  divergence that made the prerequisite worth insisting on — macOS used levels
  1/2/3/4 against the spec's, AutoHotkey's and the core's 10/20/30/40, so a level
  NUMBER meant two different things and the adoption would have silently changed
  every threshold. macOS is on the spec numbering now, and gained the
  `ring_buffer_clear` / `ring_buffer_size` it never had. What remains is the
  adoption itself.

  ⚠ **Attempted 2026-08-03 and reverted; here is what it costs, measured.** The
  rewiring is small — five edits to declarations, plus one replacing `_log`'s
  body with a call into the core and moving console/file/errors-only into a sink.
  It took the file from 994 to 943 lines and left **31 failing tests**, in three
  families:
  1. **Ring lifetime.** The ring moves into a DIFFERENT module, so a test that
     re-requires `infra.logger` no longer gets a fresh buffer: three cases that
     expected 0 entries saw 200. The fix is a decision about whether the ring is
     per-driver-instance or per-process, not a patch.
  2. **Source-scanning tests.** `test_hot_path_costs` asserts the emit path
     passes its level decision to the writer by matching
     `_write_to_file(stamp, line, variant.level ~= …)`; the signature became one
     composed line, so the scan missed. `test_logger_dedup_errors_mirror` names
     `_flush_dedup_summary`, which no longer exists here — the invariant still
     holds, in the sink. Both need re-encoding against the new home. Legitimate
     work, but eight files of it, and never a weakening.
  3. **The error-notification handler** stopped receiving the module name: it
     read values `_log` used to compute and the core now computes.

  **Next pass, in this order:** decide the ring's lifetime; re-encode the two
  source-scanning families; then rewire. The behaviour corpus already covers
  filtering, the lifecycle-pair rule, dedup and the ring, so the parts most
  likely to break silently are guarded. What is NOT guarded — and what all 31
  failures were about — is the driver half: file writing, sub-file fan-out, the
  errors-only mirror and the print() tee. Coverage for those comes first.

  What landed instead is everything the adoption depends on: the spec numbering,
  the dedup the core was missing, `ring_buffer_clear` / `ring_buffer_size` /
  `reset_dedup` / `dedup_suppressed_count` on both sides, and `LEVELS` /
  `level_of` / `label_of` on the core so a sink can express its own policy in the
  core's vocabulary instead of keeping a private copy of the numbers — which is
  exactly how this driver came to use 1/2/3/4 in the first place.

  <details><summary>The measurement that planned (1), kept for the next
  extraction of the same shape</summary>
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
  `get_default_config_dir()`, HOME set and unset, paths.toml present and absent.
  </details>

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
     other. ~~Eight constants declared three times where the shared copy exists
     only to be shadowed.~~ — **the constants half is done, 2026-08-03.**
     `test-walker-constants-single-source.cjs` holds all eight: the shared
     helpers own them, the AutoHotkey walker re-declares 7 as class statics and
     the macOS aggregator all 8, and every value must agree. Scalars compare as
     numbers, bucket arrays element by element. They agreed already, so this
     freezes a correct state rather than fixing a wrong one — a bucket edge
     changed in the shared file would previously have reached macOS and left
     Windows aggregating against the old edges, producing two histograms nobody
     can compare and no failure anywhere. Falsified five ways (a scalar drifting,
     a bucket edge drifting, the shared value drifting, and both parsers
     breaking). The six AHK constants filled at boot from the timing registry are
     deliberately excluded — asserting `0 == the registry value` would be
     asserting the placeholder, and `test-keylogger-timings-single-source.cjs`
     already holds that path.
     What remains is the expensive half: the two walkers themselves.
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
     supports the per-manipulator override, so it is wiring.
     ⚠ **The id-vocabulary measurement above was wrong, re-measured 2026-08-03.**
     The correspondence is by PHYSICAL POSITION, not by name: a Mac bottom row
     carries fn/control/option/command where a PC carries ctrl/win/alt. Read that
     way `left_alt`↔`left_command` match exactly (backspace/backspace, nav
     layer/layer) and `left_ctrl`↔`fn` match on tap (paste/paste); read as
     `left_ctrl`↔`left_control` and `left_alt`↔`left_option`, nothing matches at
     all. `right_ctrl` DOES have a counterpart — `right_option` — and its drift\n     is one action under two spellings (`one_shot_shift`/`sticky_shift`), as is
     `alt_gr`/`altgr`. `test-tap-hold-namespace-correspondence.cjs` now holds the
     whole mapping: 7 paired keys, 3 synonym pairs, 7 macOS-only keys, and **5
     recorded divergences of which exactly ONE is genuine drift** — `tab.tap`,
     `alt_tab_monitor` vs `alt_tab_windows`, with nothing recorded about why. The
     other four are the cmdorctrl distinction (twice), one layer named at two
     levels of indirection, and a Mac fn key with no PC equivalent. The gate
     fails if a pair silently starts agreeing, so the exception list can only
     shrink. What is still blocked is the RENAME itself: the ids are read at boot
     by three loaders and the synonym pairs must be reconciled in
     `macos/platform/remap/data/actions.json` first, which is Lot 6 (4).
  5. **Tooltip**: wire the 1 483 lines of shared JS as an ORACLE (vector
     generator + conformance harness), not as runtime.
     ⚠ Known latent divergence, deliberately left: the macOS renderer branches
     two ways (`caret`, and everything else as a window anchor) where the shared
     JS branches four. `resolve_anchor()` only ever produces the four the
     renderer agrees on, so it is latent, not live — adding the missing branches
     would add dead code.
     ~~`anchor_cascade` in `[positioning]` is read by no driver and contradicts
     the prose beside it~~ — **deleted 2026-08-02.** It is prose now, with the
     AHK-only mouse-cursor step in its right place, and
     `test-tooltip-positioning-reach.cjs` asserts it does not come back. A
     constant nothing consumes cannot go stale loudly, so it went stale quietly.

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
  | Port presence/compliance | 1 493 | ~500 | ⚠ see below — the mechanism as written is a downgrade |
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

  ⚠ **The port presence/compliance row, re-measured 2026-08-02: "one JS gate over
  `contracts.json` × the three `adapters/` trees" would WEAKEN what is there.**
  All three drivers' compliance tests `require`/load the adapter and inspect the
  real method table — macOS 141 l, Linux 115 l, Windows 458 l calling the
  functions through `HasMethod` with zero `FileRead`. A JS gate can only read
  source text, so it cannot catch an adapter that fails to LOAD, which is the
  failure these actually catch. Swapping a runtime check for a textual one to
  save lines is the thing the working rules forbid.
  What a JS gate genuinely does better is the part that spans trees and is pure
  filesystem fact: which ports a driver ships an adapter for, and ADR-008's
  reachability. Split the row that way — the cross-tree half to JS, the loading
  half stays where the loading happens — or drop it.

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

**Closed 2026-08-03. All six classes are at zero** and the baseline says so, so
`find-false-greens.cjs` is now an assertion rather than a ratchet: tautology,
vacuous-absence, dead-test, pcall-only, corpus-skip and unfloored-scan.

The reasoning worth keeping is in [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md);
what belongs here is only the operating rule, because the gate now defends a
floor of zero and the next false green is the one someone is about to write:

- **A pcall status is not a result.** Where the call is not expected to raise,
  delete the pcall — a raise then fails with the real error instead of a boolean.
  Where the containment IS the subject, capture the second return and assert it:
  contained and swallowed are the same observation until you look at what came
  back.
- **Floor every scan.** A loop whose body asserts per item proves nothing over an
  empty match. A boolean flag asserted afterwards is a floor too, and a stricter
  one than a count.
- **A conditional skip that never fires is worse than no skip**, because the day
  it does fire it turns a broken module into a green suite.
- Run the detector **after every batch**. One conversion in this campaign
  introduced `assert_true(X ~= nil or true)` — a tautology created while
  removing tautologies.

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

~~**`audit_mise_en_commun_et_simplification.md` has never been run.**~~ — **run
2026-08-03**, report at
[`docs/audits/2026-08-03-mise-en-commun-et-simplification.md`](docs/audits/2026-08-03-mise-en-commun-et-simplification.md).
Its sharpest finding is fixed already: three gates existed, passed, had an npm
alias and were run by NOTHING — including `test-port-compliance.cjs`, the
freshness gate for the whole port layer. They are in the suite now (140 → 144
checks) and `test-npm-aliases-match-the-suite.cjs` asserts no alias can name a
gate the suite skips. It also closes the prompt’s central question: `_generated/`
is **not** reducible — all 21 artefacts (200.3 KB) have a runtime reader, a
generator and drift-guard coverage. What it leaves open is what `TODO.md`
already holds, plus 11 hardcoded French UI strings in two `ui/` files. It covers
pushing everything non-platform-specific into `_shared/` and reducing mass: are
the `_generated/` trees still earning their committed size, can `_shared/` be
flattened, god-files, orphan tooling. One correction to apply when running it: it
says to confront your conclusions against `docs/REFACTOR_PLAN.md`, which no
longer exists — `PROJECT_MEMORY.md` is now the only canonical memory.

Its two durable conclusions are in `PROJECT_MEMORY.md`:
`project-generated-trees-are-not-reducible` (so the question is not re-opened) and
an update to `project-gate-scripts-must-be-wired` recording that the dark-gate
problem RECURRED — the advice there was right and was not enough, because an
instruction nobody can check is a habit, and habits lapse. It is an assertion now.

`perf_hs.md` and `refactor.md` — check PROJECT_MEMORY before running; the
refactor cycle the latter belongs to was declared complete.
