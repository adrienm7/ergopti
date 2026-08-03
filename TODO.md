<!-- TODO.md -->

# TODO

What actually remains. Everything finished, superseded, or answered was removed
on 2026-08-03 — the reasoning worth keeping went to
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md), which is the canonical memory
shared by every developer, agent and reviewer.

Working rules: no behaviour change without a regression test, never weaken a test
to make a change pass, and run the gates that cover what you touched —
`node ./tools/test/verify-change.cjs` derives them.

**Delete an entry the moment it is done. When this file is empty, delete it.**

> ## What actually blocks this list
>
> Measured 2026-08-03, and it is one dependency, not several. **Three of the five
> sections below are gated by the same thing: user-facing strings in 21 locales
> that only a human can supply.**
>
> - **§1** needs 756 of them (36 actions × 21). The gate is an assertion, and
>   123 of the 125 existing action labels are genuinely translated.
> - **§4 `reason_key`** needs ~3 000 (142 restrictions × 21).
> - **§4 Convention S stubs** need a `REASON_KEY` per unimplemented folder —
>   the same shape, hitting the same wall, which is why its "blocked on the
>   reader" note undersells it.
>
> Every one of those gates says the same thing in its own words: machine-filling
> the strings puts unverifiable text in front of users in nineteen languages,
> which is worse than the silence or the raw identifier it replaces. **This is a
> translator's queue, not an engineering backlog.** Splitting it out is what makes
> the remaining code sections — §2 the matcher core and §3 the menu label trees —
> legible as the code work they are.
>
> **Reading the performance numbers is no longer an entry here.** The
> instrumentation is complete — 20 HotPath segments and 5 pre-logger boot stamps,
> inventoried by `test-hotpath-segments-declared.cjs`. What was left is not work
> to schedule but an operating procedure: run the Windows driver for a day and
> read the lines above the 5 ms floor. It lives with the rest of the operating
> knowledge, in
> [`project-instrumentation-absence-is-invisible`](docs/PROJECT_MEMORY.md), which
> also records where to look first. A backlog entry nobody can action at a
> keyboard is not a backlog entry.

> ⚠ **Re-measure before you start.** Over one long session on 2026-08-03,
> **eleven** entries in the previous version of this file turned out to be wrong
> — not stale by a little, but wrong in a way that inverted the work: a
> prerequisite that was already built, a "1 483-line" job that was six modules of
> which five were done, a "55 rows" job that is really a product decision. The
> pattern and the corrections are in
> [`project-plan-entries-go-stale-faster-than-code`](docs/PROJECT_MEMORY.md).
> A finding is a lead, not a work order — and when you correct one, write the
> correction back here with the number.

---

## 1. One action namespace — remap actions become gesture actions

**Decided 2026-08-03: yes, one namespace.**

`macos/platform/remap/data/actions.json` holds 73 Karabiner actions. 18 are
already rows of `_shared/modules/actions/actions.toml` and carry `sg_actions.*`
labels in all 21 locales — those 18 now read their label from the registry
(`localise_action_labels` in `platform/remap/config.lua`), so the remap picker no
longer shows French to everyone.

**The 55 that remain are not 55 lines of TOML.**
`test-action-registry-bijection.cjs` reports `hs 0/0` declared-with-no-handler
over 126 rows: a declared row requires a handler on every platform it is declared
for. So the work is:

1. **55 rows** in `actions.toml`, `platform = "hs"`.
2. **55 macOS gesture handlers** emitting the corresponding Karabiner action.
   This is the part that makes a swipe able to trigger `layer` hold, `capsword`,
   `cmd_tab` — which is the decision that was taken.
3. **756 translations** (36 × 21) — and this is the BINDING constraint, not a
   mechanical follow-up. Measured 2026-08-03: `test-action-labels-have-locale-keys.cjs`
   is an **assertion**, not a ratchet, so a registered row with no key fails in all
   21 locales at once. And the labels are genuinely translated: **123 of the 125
   existing ones carry up to 21 distinct values**. (`one_shot_shift` is one of the
   two that do not — do not generalise from it, as was done once already.) **Zero
   of the 36 has a key today.**

   So finishing §1 means writing 756 strings in 19 languages nobody here can
   check — the same objection `test-platform-restrictions-explained.cjs` states
   for `reason_key`, and the same answer applies: machine-filling them puts
   unverifiable text in front of users, which is worse than the identifier the
   picker shows now. **This needs a human translator or a review pass, not an
   agent.** Steps 1 and 2 can land first; step 3 is what gates the feature.

The picker itself is driven by `sg_order`, not by the row set, so the rows alone
are invisible in the UI — the handlers are not. Decide whether the 55 also join
`sg_order` (visible in the gesture picker) or stay registry-only.

⚠ **Measured 2026-08-03, and it splits the 55 in two.** Nineteen of them are
`tappable: false` — hold-only: `layer`, `shift`, `ctrl`, `cmd`, `alt`, `altgr`,
`fn`, and twelve modifier combinations. **A gesture has no duration**: a swipe
happens and ends, so "hold Shift" cannot be expressed as one. Applied literally,
the decision would create nineteen gesture actions that cannot work.

So the shape is:
- **36 tappable actions** → rows + handlers, straightforward.
- **19 hold-only actions** → decide one of: (a) rows without handlers, which
  needs the bijection gate to learn about a `hold_only` flag; (b) handlers with
  TOGGLE semantics (gesture enters the layer/modifier, a second gesture leaves
  it), which is the only meaningful reading of "swipe to hold"; or (c) they stay
  out of the registry and only the 36 merge.

⚠ **The "reconcile the two spellings first" instruction was wrong — measured
2026-08-03.** `one_shot_shift`/`sticky_shift` and `alt_gr`/`altgr` are indeed one
action under two spellings, and they are **already reconciled**: the `SYNONYMS`
table in `test-tap-hold-namespace-correspondence.cjs` pairs them and a gate holds
the pairing. What was wrong is the cost. That table called itself "a rename, no
behaviour change"; `one_shot_shift` is in fact a key in the shared timing registry
(`[tap_hold] one_shot_shift_timeout_ms`), the FILENAME of an AutoHotkey module,
a global constant, three `shortcuts.*` paths in the feature manifest with matching
config-template rows, a `tap_action` in the Linux kanata defaults, and a locale
key in all 21 locales — **roughly eighty sites across three drivers**.

So do NOT rename. Key the new rows on the **Karabiner ids** (`sticky_shift`,
`altgr`), leave the AutoHotkey vocabulary alone, and let the `SYNONYMS` table
remain what ties them. Two vocabularies pairing by meaning under a gate cost one
table; collapsing them costs a rename through every driver and buys nothing the
table does not already give.

**Measured overlap, 2026-08-03:** 73 Karabiner actions, 126 `sg_actions` rows, 18
in common, 55 missing — 36 tappable, 19 hold-only. The counts above hold.

---

## 2. macOS + Windows onto the shared matcher core

**Decided 2026-08-03: do it.** A 526-line shared core already exists and reaches
Linux only, so this is adoption, not generation. 29 cross-driver vectors
(`_shared/tests/corpus/hotstrings/vectors.json`) are already replayed by all three
suites, unit and e2e.

**Blocker, measured:** Windows carries **103 lines** of star-trigger indexing
under `infra/hotstrings/` against **6** mentions in the whole shared core.
Adopting it as-is would lose the feature. **Port star-trigger handling into the
core first**, with vectors, then adopt.

macOS's `would_fire()` is no longer a blocker: it has four consumers (the
expansion path, the tooltip preview, two LLM-bridge sites) and
`test_would_fire_single_source.lua` now asserts every one reaches the predicate,
and that the predicate refuses a buffer whose TAIL is not the trigger — the case a
length-only reimplementation gets wrong, and how a preview comes to promise an
expansion that never fires.

`codegen-terminators.cjs` is **not** a usable model: its Lua output is 44 lines of
data, and no generator in this repo emits a Lua function.

## 3. Menu label-tree parity (I3)

`test-menu-parity.cjs`, the label-tree half: render for the three platforms and
diff the label trees. **Blocked, deliberately:** the menu manifest carries no
`linux` platform value anywhere — 27 rows are `[ahk]`, 19 `[hs]`, 2 both — so
Linux "sees" 76 rows only because an unrestricted row defaults to every platform,
while `menu_builder.lua` builds its rows by hand. Diffing the three trees today
would report that migration, not a defect.

Follows the menu-capability work: the manifest needs `provider`/`builder` before
a declarative group can absorb a driver-supplied builder.

---

## 4. Smaller and known — but the cheap ones are gone

The two genuinely cheap entries were closed on 2026-08-03 (npm aliases, `tab.tap`).
Everything below is either blocked on a prerequisite or deliberately incremental;
none of it is a batch job, and the section title used to imply otherwise.

- **Convention S stubs (I1).** Every canonical folder exists on every driver;
  where unimplemented it ships an `init` with a `STATUS: not implemented` line and
  a `REASON_KEY`. Blocked on the reader:
  `test-menu-manifest-keys-have-readers.cjs` rejects a manifest field before its
  reader exists, so write the reader first.
- **`reason_key` for platform restrictions (I2) — NOT a batch job, and the gate
  says so.** 139 of 142 restrictions carry no reason. Writing them all means 142
  locale keys × 21 locales ≈ **3 000 translated strings in 19 languages nobody
  here can check**, and `test-platform-restrictions-explained.cjs` is explicit
  that machine-filling them "would put unverifiable text in front of users in
  every language, which is worse than the silence it replaces". It is frozen as a
  ratchet on purpose: a NEW restriction must explain itself, and the existing ones
  get described **as the feature around them is revisited** — one at a time, by
  someone who knows why that feature is missing. Lower the baseline then. This
  entry was filed under "cheap"; it is the opposite, deliberately.
- **Menu rows outside the renderer (I3).** windows 220, macos 301, linux 3. The
  gate names the biggest offenders (`menu_remap.lua` 36,
  `menu_llm/models_selector.lua` 32, `menu_keyboard_layout.lua` 26). Lower it;
  never raise it.
- **`tab.tap` drift — measured 2026-08-03, and it is a product question.**
  Windows `AltTabMonitor()` reads the mouse position, resolves the monitor under
  the cursor, and cycles only the windows **on that monitor**. macOS
  `start_alt_tab_windows_hotkey` binds Shift+F17 to `focus_previous_window_global`
  — the previously focused window, unscoped (itself migrated away from `cmd_tab`
  so it switches windows rather than apps). Two behaviours, not two names, so
  renaming either side would be the wrong fix. What remains is a decision: should
  macOS scope to the display under the cursor as well? The full finding is in
  `test-tap-hold-namespace-correspondence.cjs`, which no longer says "nothing
  recorded why".
- **Gates to retire, after their migration only:**
  `macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua`, and
  `test_menu_top_level_drift_gate.{lua,ahk}` (once the tail is manifest rows with
  registry-validated ids, **and** a Linux twin exists first).

---

## 5. Audits not yet run

`docs/prompts/perf_hs.md` and `docs/prompts/refactor.md` — check
`PROJECT_MEMORY.md` before running either; the refactor cycle the latter belongs
to was declared complete.

`audit_mise_en_commun_et_simplification.md` **was run on 2026-08-03** — report at
[`docs/audits/2026-08-03-mise-en-commun-et-simplification.md`](docs/audits/2026-08-03-mise-en-commun-et-simplification.md).
Its findings are either fixed or folded into the sections above.
