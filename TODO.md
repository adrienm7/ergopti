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
| **I2** | One feature namespace. A feature lives at its semantic path, never under a driver name. A feature missing on a platform carries a translated `reason_key`. | Ratcheted at 223 driver-namespaced tables (Lot 4) and at 76 unexplained platform restrictions. |
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
| `_shared/lua/linux/tray_protocol.lua` | `_shared/lua/tray/protocol.lua` | a platform-named node inside `_shared/` |
| `_shared/lua/llm/linux_bridge.lua` | `linux/infra/llm_bridge.lua` | 364 "shared" lines with a single consumer |
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

- **Lot 2 — the safety net.** Residual pinned source reads, both ratchets at
  their floor (macOS 34, AHK 16). The macOS 15 left need a human: their target
  module has no declaration unique to it, so `read_driver_source` would
  concatenate several files and silently change what the test asserts — make the
  assertion order-independent first, as `test_menu_llm_api_backend_probe.lua`
  now is. The AHK 16 each pin deliberately.
  **Known hole:** both ratchets apply `HELPER_RE` per FILE, so one converted read
  hides every remaining pinned read in the same file. Counting per READ is the
  fix.

- **Lot 3 — one tree.** Remaining: (a) extract `platform/`; (b) de-platform
  `_shared/`; (c) the Convention S stubs.
  The `ui/` reorganisation is done on all three drivers. If the
  `modules/<feature>/window.*` shape is still wanted, it is now one move of
  three identical trees rather than a reconciliation.

- **Lot 4 — one namespace.** Migrate the **206 of 335 features (61.5 %)** out of
  the `[ahk.*]` / `[hs.*]` silos to their semantic path with per-entry
  `platforms`. **Approved, config-schema break accepted** — the user deletes
  `config.toml` and the driver regenerates it, as the v1→v2 cut-over already
  established. Add `linux` to the platforms of the features Linux really
  implements and to `KNOWN_PLATFORMS`; extend `test-config-schema.cjs` to the
  Linux template. Merge the duplicated privacy toggles: the three filters exist
  **twice** in the shared manifest (`metrics.*_filter_enabled` **and**
  `ahk.metrics.filter_*`) and the AHK driver reads neither — it hardcodes
  `:= true`. Extreme case: `ahk.gestures` = 11 features vs `hs.gestures` +
  `.modes` + `.sensitivities` = 109, for the same feature, with the same i18n key
  `menu.gestures` on both sides.
  *Sizing note: adding `linux` to the eight `hotstrings` sections cost one line
  each and moved no gate. The fear attached to this lot is the 223-table RENAME,
  not the platform declarations.*

- **Lot 5 — one menu.** The manifest must gain the capabilities that explain
  every hand-written row: a resolvable `action` id (12), `label.format` + `args`
  with live values (~20), `provider` for dynamic lists (~15 slots), `radio_group`
  (~5), `toggle_shape` (`parent` on macOS/Linux, `first_row` on AHK — solved for
  the IA submenu only), declarative `prompt` (~12 twenty-line bodies),
  counts/badges (~12), the `linux` token, groups nested beyond one level (~4),
  separator semantics (re-implemented 3 times), an `emoji` field, `visible_when`
  (~8), and a real top-level section list (the 9 head ids are read by nobody).
  `checked_when` is done and shipped used; the remaining ~11 rows are a
  mechanical repeat of that shape.
  Order: (1) pilot on the metrics menu — best-covered, and ~280 lines of handlers
  across two drivers become ~26 manifest rows + ~26 registry entries;
  (2) write `_shared/lua/menu/render.lua` (shared macOS+Linux, ~230 l) and
  `linux/infra/menu_host.lua` (~180 l), delete `menu_builder.lua` (933 l — it is
  already fully i18n'd, so this is architecture, not translation);
  (3) migrate the macOS hotstrings then layout submenus — layout needs
  `platforms:["macos"]` rows for the TIS/bundle features first, because
  `layout_menu` currently describes a Windows-only menu that the macOS drift gate
  pins without macOS implementing it; delete
  `test_menu_hotstrings_layout_drift_gate.lua` **after**, never before;
  (4) move the 1 812 lines of `macos/ui/menu/` that are not menu layout
  (`preferences.lua`, `menu_state.lua`, `menu_watchers.lua`,
  `shortcut_utils.lua`, `menu_paths.lua`) out — ⚠ **the third-driver test yields
  no destination**: none of the five has a counterpart on Windows or Linux, so
  picking a target directory is taste rather than evidence. Needs a design call;
  (5) fold `_shared/modules/llm/menu_layout.json` in — ⚠ **blocked on (2)**: of
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
  keyed to ids that are about to change; (5) the host→page push for the Linux
  `action_picker` — `init(data)` must be evaluated IN the webview after `ready`,
  and a Linux bridge handler is given only `(payload, state)`, so the channel does
  not exist (the payload is built and tested); (6) replace the macOS-only
  `ctrl_shortcuts`/`cmd_shortcuts` and the AHK-only `modifier_combos` groups with
  one `chord_bindings` group rendered identically everywhere.

- **Lot 7 — the cross-cutting layer.** Remaining: (1) move the macOS config-path
  SSOT out of `ui/menu/menu_paths.lua` (25 call sites) — today `infra/` depends on
  `ui/menu/`; (2) **only then** make macOS consume the shared logger core, and
  only after writing `_shared/tests/corpus/logger/behaviour_vectors.json` — this
  is the module with the worst bug history in the repo.

- **Lot 8 — the engines.** One matcher, not one engine: the genuinely
  platform-agnostic core is ~350 lines; the other ~14 000 are emission,
  buffer/screen sync, suppression bookkeeping, TOML I/O, tooltip preview and OS
  quirks, legitimately per-driver.
  1. Generate the single matcher core into both target languages, modelled on
     `codegen-terminators.cjs` — it already emits both targets in one run and is
     the only part of the engine that has never drifted.
  2. **LLM**: fold the prompt-builder constants into one JSON. All 10 agree
     across the three declarations today and
     `test-prompt-builder-constants-parity.cjs` holds them, but three
     declarations agreeing is not one declaration.
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
  promise the suites mutualise like the drivers. Achievable: **≈ −11 500 lines.**

  | Target | Today | After | Mechanism |
  | --- | ---: | ---: | --- |
  | Corpus consumers (16 corpora, 258 vectors) | 9 122 | ~1 900 | one JSON replay schema per corpus + a ~120-line generic runner per driver |
  | Port contract vectors (129) | 2 001 | ~700 | generate `_shared/tests/corpus/ports/<Port>_vectors.json` from `contractTestVectors()` |
  | e2e harnesses | 1 319 | ~750 | one corpus-driven harness that fails loudly on a missing corpus |
  | Convention invariants | 1 594 | ~450 | one `.cjs` gate per invariant — the shared linter already IS that gate |
  | Port presence/compliance | 1 575 | ~500 | one JS gate over `contracts.json` × the three `adapters/` trees |

- **Lot 10 — pruning.** The reachability gate is built and the figure it was
  sized on was wrong: **macOS 0, Windows 0, Linux 9 (1 549 lines)** unreferenced,
  against a recorded "12 of 21 Windows and 11 of 21 Linux, ~3 101 lines".
  ⚠ **Needs a decision, not a cleanup.** Two of the nine (`notifier`,
  `tooltip_renderer`) are named by `test_port_adapter_presence.lua`, which
  asserts every declared port HAS an adapter file — they exist because the
  architecture declares the port. Deleting them means shrinking `contracts.json`
  to the ports with real traffic and superseding ADR-001. Honest demotion
  candidates: `AppLauncher`, `Crypto`, `Storage`, `ProcessLifecycle`,
  `MouseControl`, `TooltipRenderer`.

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
- `linux/tests/unit/meta/test_port_adapter_presence.lua` (9 hardcoded names)
- `windows/tests/COVERAGE.md` and `macos/tests/COVERAGE.md` — hand-written
  inventories, already stale. `docs/TESTING.md` states the right principle: the
  inventory of checks is the run itself.

---

## 1. Tests that certify nothing

The highest-leverage cluster, because a false green is worse than a missing
test: it actively deters anyone from writing the real one.

`tools/test/find-false-greens.cjs` runs inside `npm run test:js` and ratchets six
classes — tautology, vacuous-absence, dead-test, pcall-only, `corpus-skip` and
`unfloored-scan`. It only turns down. Current floors: tautology 45, pcall-only
213, unfloored-scan 24, the other three at 0.

The work is burning those three floors down. Each occurrence is either a real
false green to fix or a justified shape to document in the test itself —
`--update-baseline` after saying why.

Two shapes the detector **cannot** see, to hunt by hand:

- a harness that stubs the very function the test claims to verify;
- a source-grep pinning the current SPELLING of the code, not the invariant.

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

Also pending from the doc triage: rewrite `docs/STATE_TRANSITION_MATRIX.md`
against the current PowerShell-worker architecture (the two dangerous
prescriptions are fixed, but the surrounding symbol names are still stale), and
refresh the "It bundles:" list in `docs/TESTING.md`, which names four checks
where `run-js-suite.cjs` now declares about 130.

---

## 4. Hammerspoon audit 2026-07-29 — findings still open

The audit report was retired once its findings were adjudicated: 111 candidates,
92 confirmed, 17 refuted, 2 hypotheses. Everything at CRITICAL and HIGH severity
shipped, along with roughly half the rest — each with a regression test proven red
before the fix and green after.

5 did not ship. They are carried here verbatim so nothing was lost with the
file: location, root cause, proposed fix and proposed test. Two caveats that the
pass itself established, and that apply to every line below:

**Verified against the tree on 2026-08-02.** Fourteen of the original thirty are
gone: eleven closed earlier that day, three more here after reading the code
they name. The proportion is the point — the caveat above says one in six turns
out stale, and in this batch it was closer to one in two. Two cheap signals sort
them faster than reading all of them: whether the test the finding PROPOSES now
exists (the repo's rule is a test per fix), and whether a distinctive identifier
from its **Fix** paragraph appears in the source it names. Neither is a verdict —
`karabiner-actions-rebuilt-673` scored zero on both and was fully done — but
together they say which to read first.

**Verified against the tree on 2026-08-02.** Fourteen of the original thirty are
gone: eleven closed earlier that day, three more here after reading the code
they name. The proportion is the point — the caveat above says one in six turns
out stale, and in this batch it was closer to one in two. Two cheap signals sort
them faster than reading all of them: whether the test the finding PROPOSES now
exists (the repo's rule is a test per fix), and whether a distinctive identifier
from its **Fix** paragraph appears in the source it names. Neither is a verdict —
`karabiner-actions-rebuilt-673` scored zero on both and was fully done — but
together they say which to read first.

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

- [ ] **LIBCORE-3** (lib-core) — Every dialog schedules a blocking `hs.execute("open …")` on the main run loop that — for the two BLOCKING wrappers — can only fire AFTER the dialog is dismissed, so it cannot serve its stated purpose and instead steals focus back while stalling the run loop
  - `static/ergopti_plus/macos/lib/dialog_util.lua:64-72 (the deferred `pcall(hs.execute`
  - **Cause:** focus_hammerspoon() implements three focus mechanisms; the third contradicts its own premise. For M.alert (non-blocking) the deferred `open` does fire 100 ms later and does raise the app, but `hs.execute` is `io.popen` read-to-EOF — fully synchronous on the main run loop (PROJECT_MEMORY project-hs-partial-fixes-and-false-green-tests records exactly this about ShellRunner.exec). For M.block_alert and M.text_prompt the timer is structurally unable to run before dismissal, so the call is dead with respect to its purpose while retaining both side effects: a main-thread stall and a focus steal. The two synchronous `do_focus()` calls at 55-56 are what actually focuses the dialog; the shell-out add
  - **Fix:** Delete the deferred `hs.execute` block (64-72) entirely: `hs.focus(true)` + `app:activate(true)`, already called twice, is the supported way to bring Hammerspoon forward, and the shell-out demonstrably cannot help the blocking wrappers. If an extra nudge is genuinely wanted for the non-blocking M.alert path only, route it through `adapters.shell_runner.spawn` (async, GC-pinned) and gate it on the non-blocking wrapper — never on block_alert/text_prompt.
  - **Test:** New `tests/unit/lib/test_dialog_util_no_blocking_shell.lua`: stub `hs.execute` with a spy and `hs.timer.doAfter` with a recorder that fires immediately, call M.block_alert / M.text_prompt / M.alert, and assert `#exec_calls == 0`. Per PROJECT_MEMORY's own rule for this class, the assertion must be the ABSENCE of the harmful operation, never the presence of the scheduling call. This keeps tests/unit/meta/test_gc_retention.lua:337 green — that test only asserts `hs.task.new` is absent from dialog_u
- [ ] **BS-1** (boot-shutdown) — The menu's config pathwatcher — a SECOND recursive watcher on the same base_dir — has neither the TOML-cache exclusion nor the self-written-file exclusion that init.lua so carefully passes to lib/file_watchers
  - `ui/menu/menu_watchers.lua:110-138 (reload_config filter)`
  - **Cause:** Two recursive pathwatchers cover base_dir: lib/file_watchers' project_watcher and ui/menu/menu_watchers' configWatcher. init.lua computes TOML_CACHE_DIR once (line 214) precisely so 'the writer and the watcher cannot drift apart again' and threads it plus the self-written paths into lib/file_watchers.start (863-877). menu.start() arms the second watcher with only (base_dir, on_reload, get_suppress_until, ui_restore) — no ignored_dirs, no self_written_files. The exclusion was applied to one of the two watchers on the same tree.
  - **Fix:** Thread the same context into MenuWatchers.start_config_watcher: pass ignored_dirs (init.lua's TOML_CACHE_DIR) and self_written_files (menu_paths ConfigTomlPath + KarabinerConfigPath) down from menu.start, and apply the exact is_runtime_artefact / is_self_written predicates from lib/file_watchers.lua:110-134 inside reload_config. Better still: delete the duplicate watcher entirely and let lib/file_watchers own base_dir — it already watches the same tree with a strictly stronger filter, a boot-suppress window, the adaptive settle, multi-repo git gating and fire-time re-checking.
  - **Test:** New tests/unit/ui/menu/test_menu_watchers_runtime_artefacts.lua, mirroring section 3 of tests/unit/lib/test_file_watchers_reload_gate_coverage.lua: stub hs.pathwatcher/hs.timer, arm start_config_watcher on /fake/driver/, fire '/fake/driver/cache/toml_hotstrings/x_1.lua', assert no debounce timer was armed and reloads()==0; then fire '/fake/driver/modules/keymap/init.lua' and assert exactly one reload, so an exclusion that swallows the whole tree also fails.
  - **Re-measured 2026-08-02: the first half shipped, the second did not.**
    `menu_watchers.start_config_watcher` now takes `ignored_dirs` and applies it
    (`:52`, `:114`), with a comment naming the snapshot-cache reload loop it was
    written for. What is still missing is `self_written_files`: the filter reloads
    on any `.toml` change outside the ignored dirs, `config.toml` is a `.toml` the
    driver rewrites on every preference toggle, and the only suppression on this
    path is a BOOT window (`file_watchers.lua:162 BOOT_SUPPRESS_SEC`), not a
    per-write one. Either something else prevents the reload — in which case say
    what, because it is not visible from this file — or every menu toggle arms a
    reload. Check before fixing: a reload on every toggle would be loud, so the
    likeliest answer is that a third mechanism exists and is undocumented.
- [ ] **BS-2** (boot-shutdown) — On the boot that installs/updates the VS Code extension, vscode_bridge.setup() throws before start_server(), so the caret bridge HTTP server never starts for that session — and it steals focus and forks a subprocess with the typing eventtap already armed
  - `init.lua:817-822 (call site`
  - **Cause:** Two independent defects compounding. (a) lib/dialog_util.M.alert wraps hs.dialog.alert but both call sites pass the hs.alert.show(message, duration) argument shape — the wrapper was written against the wrong Hammerspoon module. (b) setup() (lib/vscode_bridge.lua:349-352) chains install_extension() and start_server() with no isolation, so a throw in the cosmetic notification kills the functional half. Separately, even when it does not throw, focus_hammerspoon() (dialog_util.lua:41-70) calls hs.focus(true) and app:activate(true) twice and schedules hs.execute("open '<bundlePath>'") — a focus steal plus a fork, during boot, at a point where the typing eventtap armed at init.lua:785 is already l
  - **Fix:** In lib/vscode_bridge.M.setup, call start_server() FIRST (or wrap install_extension in its own pcall) so a notification failure can never take the server down. Fix lib/dialog_util.M.alert to forward to hs.alert.show(message, duration) — matching what both call sites pass — or fix the two call sites to the real hs.dialog.alert signature. Move install_extension() off the boot critical path (hs.timer.doAfter(0, …), the pattern init.lua already uses at lines 434 and 500) so neither the fork nor the focus steal lands while the typing tap is armed, and replace the os.execute mkdir with adapters/file_system's ensure_dir.
  - **Test:** tests/unit/lib/test_vscode_bridge_setup_isolation.lua: stub lib.dialog_util with an alert() that raises, stub the extension files so already_ok is false, stub hs.httpserver, call vscode_bridge.setup() and assert hs.httpserver.new was still called — i.e. a throwing notification cannot prevent the server from starting. Plus a meta-test asserting lib/dialog_util.M.alert and its call sites agree on one signature.
- [ ] **karabiner-stale-layout-actions-on-resume** (karabiner) — Layout rebuild re-resolves every logical_char action BEFORE the pause guard, and regenerate() never re-resolves — so resume deploys a KE config built for the pause layout
  - `static/ergopti_plus/macos/modules/karabiner/init.lua:759-777 (reload at 761-762`
  - **Cause:** The refresh of the layout-dependent action table and the consumer of that table live on different code paths. The refresh (init.lua:761-762) sits on a path that then refuses to act (the pause guard is 11 lines BELOW it), and the consumer M.regenerate() -> Generator.build_karabiner_json(_state, M.AVAILABLE_ACTIONS, …) never refreshes. Secondary: mutating M.AVAILABLE_ACTIONS while paused is itself a « pause = tout éteint » violation — a paused script rebuilds 673 action tables and writes 548 DEBUG log lines.
  - **Fix:** Hoist the `shortcuts.is_paused()` block (init.lua:773-777) ABOVE the Config.load_available_actions() call at init.lua:761-762. That makes the paused branch mutate nothing, so M.AVAILABLE_ACTIONS keeps its pre-pause (Ergopti) resolution, which is exactly what the resume redeploy needs. Optional hardening: have M.resume() arm the regenerate on LAYOUT_TIS_SETTLE_SEC instead of doAfter(0), so the TIS keycode map has settled after the resume-layout switch.
  - **Test:** New tests/unit/modules/karabiner/test_layout_rebuild_no_reload_while_paused.lua, built on the existing load_karabiner(paused) harness in test_regenerate_pause_guard.lua: additionally stub modules.karabiner.config so load_available_actions increments a counter, capture the on_change callback that karabiner/init passes to Watchers.start_input_source_watcher (and the doAfter callback it arms), drive them with shortcuts.is_paused() == true, then assert `helpers.assert_eq(reloads.count, 0, "a paused 
- [ ] **UML-6** (ui-menu-llm) — After a reload, the reattached download shows a per-file percentage as the overall progress and never a total or ETA
  - `D:/Documents/GitHub/ergopti/static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_mlx_download.lua:624-643`
  - **Cause:** The reattach path was written as a stripped-down copy of `process_stream` (:346-409) but dropped the two pieces that make the number meaningful: the persistent `_bytes_done`/`_bytes_total` upvalues and the `estimated_bytes_total` lookup from `m.hardware_requirements.mlx.download_gb` in the preset tree. The session JSON carries `repo` and `model`, so the estimate is recoverable — it just is not recomputed.
  - **Fix:** Hoist `_bytes_done`/`_bytes_total`/`_current_pct` to upvalues of `reattach_download`, seed `_bytes_total` from the preset `download_gb` for `session.model` (the same lookup as :118-133), and compute the percentage from `_bytes_done / _bytes_total` exactly as `process_stream` does instead of regexing a tqdm bar. Drop the unused `_current_pct` local.
  - **Test:** New case in a tests/unit/ui/menu/menu_llm/test_mlx_reattach_progress.lua: feed `process_stream_reattached` two successive chunks `__BYTES__:1000000000` then `__BYTES__:2000000000` with a preset whose `download_gb = 4`, capture `download_window.update`'s arguments and assert the reported percentage increases monotonically and that `bytes_total > 0`. Fails today (0 and 0).