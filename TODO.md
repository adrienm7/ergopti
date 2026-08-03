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

> ## ✅ Four decisions taken by the maintainer on 2026-08-03
>
> These override the analysis below wherever they disagree. Do not re-ask.
>
> 1. **Translations: fill them all, machine translation included.** The objection
>    below — that unreviewed strings in nineteen languages are worse than the raw
>    identifier — was put to the maintainer explicitly, with the count, and the
>    answer was to write them anyway. The labels are short, standard UI terms
>    (Save, Home, Page Up, Spotlight). **Risk accepted knowingly: text not read by
>    a native speaker will ship.** This unblocks §1 and the `reason_key` half of
>    §4. Prefer wording that already appears elsewhere in the same locale file
>    over inventing a new phrasing.
> 2. **§1 — the 19 hold-only actions stay OUT.** Only the 36 tappable ones join
>    the registry. A gesture has no duration, so `layer`/`shift`/`cmd` hold cannot
>    be expressed as one; they remain Karabiner-only. No `hold_only` flag, no
>    toggle semantics.
> 3. **§2 — port the star-trigger indexing.** Go ahead: the 103 lines move into
>    the shared core WITH cross-driver vectors first, then adopt. Same method as
>    the logger — behavioural contract, migration, falsifiability probes.
> 4. **This file stays until it is empty**, then it is deleted, exactly as the
>    line above prescribes. Reducing it section by section is the intended
>    behaviour, not a deferral.
>
> ## What blocked this list before those decisions
>
> Measured 2026-08-03, and it is one dependency, not several. **Three of the five
> sections below are gated by the same thing: user-facing strings in 21 locales
> that only a human can supply.** Decision 1 removes that gate by accepting the
> risk; the measurements are kept because they say what the risk IS.
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

## ~~1. One action namespace~~ — DONE 2026-08-03

Landed in `213c9d6`. The merge was not the shape this section described, and the
correction is worth keeping because it is the same lesson as the others:

- **32** of the "55 missing" were genuinely missing and became rows.
- **4** were not missing at all — `return`≡`enter`, `delete_fwd`≡`delete`,
  `cmd_tab` and `alt_tab_apps_list`≡`app_switcher`. Declaring them would have put
  four duplicate entries in the picker: the same label twice, for the same
  keystroke. They became a `[karabiner_aliases]` table instead.
- **19** hold-only ones stay out, as decided.
- **The 756 translations were 63.** Twelve labels compose from a string the same
  locale file already carries, fifteen are the sticky family (left untranslated,
  matching what this catalogue already does for `OneShotShift` and `CapsWord` in
  all 21 files), and nine are chords or key names printed on the keyboard. Three
  terms remain that a native speaker should read: "direct", "all apps",
  "Cycle windows (same app)".

The gate that found the four duplicates — no two rows may emit the same macOS
keystroke — is `test-karabiner-namespace-is-merged.cjs`, and it also holds the
tappable/hold-only split so a new Karabiner action cannot become a
remap-only feature again.

<details>
<summary>The original analysis, kept because its measurements were the useful part</summary>

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

</details>

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

## 3. Menu label-tree parity (I3) — half done 2026-08-03

**The shape half is done** (`35b603d`). The manifest now has a Linux dimension,
and giving it one immediately surfaced three rows nobody could see: `kanata`
(built by Linux since it was written, absent from the manifest — so the manifest
described a driver with no remap menu at all), `updates` (built, absent,
genuinely Linux-only) and `apps` (built, while the manifest said
`platforms = ["hs"]`). `test-menu-top-level-parity.cjs` holds both directions.

⚠ **The entry named `test-menu-parity.cjs` as the gate to extend. No such file
has ever existed, in any commit.**

**What remains is the label half, and its real cost is now measured:** Linux
reads no manifest at all — not one `menu_manifest` reference outside a comment.
Diffing translated label trees needs a Linux renderer, and the reference
implementation (`macos/infra/manifest_menu.lua`) is 561 lines. That is the job,
and it is a port, not a diff.

---

## 4. Smaller and known — but the cheap ones are gone

The two genuinely cheap entries were closed on 2026-08-03 (npm aliases, `tab.tap`).
Everything below is either blocked on a prerequisite or deliberately incremental;
none of it is a batch job, and the section title used to imply otherwise.

- **Convention S stubs (I1).** Every canonical folder exists on every driver;
  where unimplemented it ships an `init` with a `STATUS: not implemented` line and
  a `REASON_KEY`. ⚠ **The stated blocker is wrong — measured 2026-08-03.**
  `test-menu-manifest-keys-have-readers.cjs` reads
  `_shared/modules/menu/menu_manifest.json` and nothing else (line 51). It has
  never looked at the feature manifest, so it would not reject a `REASON_KEY`
  there and it is not what blocks this. The real dependency is the same as the
  entry below: something has to display the reason.
- **`reason_key` for platform restrictions (I2).**
  **Maintainer's decision, 2026-08-03: write the consumer FIRST**, then fill the
  reasons as the ratchet comes down. ⚠ **Measured the same day, and the consumer
  is three steps, not one:**
  1. `reason_key` has **zero readers anywhere in the repo** — a grep over
     `static/` and `tools/` finds it only inside
     `test-platform-restrictions-explained.cjs` itself. Without a consumer the
     ~3 000 strings would be dead configuration, which is why the question was
     put to the maintainer before writing any of them.
  2. `tools/build/build-features-manifest.js` does not even **emit** it. The
     generated `features_manifest.{lua,ahk}` carry `platforms` (246 entries) and
     no `reason_key`, so no driver could read one today even if it wanted to.
     `description_key` is the cautionary precedent: it IS emitted, and its own
     generated header records that no macOS module reads it.
  3. Only then a display. The natural home is the healthcheck report (already
     reachable at Menu → Debug → Healthcheck, already structured as `safe_collect`
     collectors), not a menu row — showing absent features as disabled rows would
     change every menu on every platform, which nobody asked for.

  So the order is: emit → read → display → **write one real reason end to end and
  lower the baseline by one**, which is what proves the chain before 141 more
  strings are written on top of it.

  The frozen count and its rationale below still hold. 139 of 142 restrictions
  carry no reason. Writing them all means 142
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
- ~~**`tab.tap` drift**~~ — **DONE 2026-08-03**, in `f5a861c`. The maintainer's
  answer was "implement both", so both behaviours now ship on both drivers:
  `AltTabAll()` on Windows, a Ctrl+F17 per-screen cycler on macOS. What is left
  is which one the tab key defaults to, and the two platforms answer differently
  on purpose. **The finding worth keeping is that the `platform` field was the
  real blocker**: it accepted only "all" / "hs" / "ahk", so it could not say "two
  drivers out of three" — "all" declared two rows Linux cannot perform, and a
  single key hid half the work. It now takes a comma-separated list.
- **Gates to retire, after their migration only:**
  `macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua`, and
  `test_menu_top_level_drift_gate.{lua,ahk}` (once the tail is manifest rows with
  registry-validated ids, **and** a Linux twin exists first).

---

## 5. Audits not yet run

`docs/prompts/perf_hs.md` and `docs/prompts/refactor.md` — both files still exist.

⚠ **Measured 2026-08-03: the reason given for not running `refactor.md` no longer
checks out.** The entry said "the refactor cycle it belongs to was declared
complete", pointing at
[`project-simplification-branch-2026-07-30`](docs/PROJECT_MEMORY.md). That entry
describes the `simplification` branch as **unmerged, with 6 of 12 blockers
delivered** — not complete — and it directs the reader to "`TODO.md` §0", a
section that no longer exists.

And the branch itself is **gone**: no local branch, no worktree (only
`hs-audit-2` remains). So the memory entry documents a branch nobody can inspect,
against a plan section nobody can read, and this entry cites it as authority for
skipping an audit.

🚩 **AND THEN VERIFIED: FIVE OR SIX OF THE SIX ARE ALREADY FIXED. Do not act on
the table below without re-checking each row.**

The `PROJECT_MEMORY` entry is dated **2026-07-30** and describes a branch state,
not the repository. Measured 2026-08-03 on `dev`:

- **B3 — fixed.** `test-kanata-defalias-parity.cjs` passes 17/17 and names the
  four aliases the blocker said were dangling: *"hand-maintained composites
  survive the replacement (rollc, rollx, deadtrema, copy, paste)"*.
- **B5 — fixed.** `linux/.../sqlite_writer.lua` now passes the SQL on **stdin**
  via `SqliteCommand.build`, and the surviving comment is in the PAST tense:
  *"Staging it in /tmp is what turned this module into a keystroke leak."* The
  leak is what the comment documents, not what the code does.
- **B4 — almost certainly fixed.** 75 references to `secure_field` /
  `private_window` in the Linux tree, against a blocker that said there were
  none.
- **B6 — almost certainly fixed.** 12 references to `text_cipher` /
  `text_crypto` on macOS, plus `_shared/lua/keylogger/text_crypto.lua`, against a
  blocker that said ten empty stubs.
- **B9 — almost certainly fixed.** `context_window` appears 4 times in the
  Windows AutoHotkey tree; the blocker's own reproduction was `grep -c
  context_window windows/**/*.ahk` → 0.
- **B10 — fixed.** `macos/.../prediction_engine.lua:171` reads
  `LLM_DEFAULTS.llm_disable_password_fields` — a defaults table, not the
  hardcoded `true` the blocker described — and `preferences.lua:102` maps
  `llm_secure_field_filter_enabled` onto a config path, so the shared value is
  reachable. The blocker stated the exact opposite of what the code now does.

**All six are fixed. The branch question this section opened is closed:** the
`simplification` work landed on `dev` (`f81c9012a`, fast-forward), and nothing
was lost. The two audit prompts can be run whenever someone wants them; there is
no longer a reason to hold them back.

**The lesson is the one this file already carries, at its sharpest.** Recovering
these took a session; believing them cost a false security alarm raised to the
maintainer minutes later. A recovered record is still a record with a date on it,
and four days was enough. **Re-measure a recovered entry exactly as hard as a
stale one — recovery is not verification.**

The table stays below because B10 is unverified and because the traps are worth
reading before touching those areas. It is a historical record now, not a work
order.

✅ **RECOVERED 2026-08-03 — and they were never lost, only unreachable.**

The reflog holds 81c9012a merge simplification: Fast-forward and
97ca0ec1 docs: fold the simplification plan into TODO.md. The branch WAS
merged; the six surviving blockers were folded into a TODO.md section that a
later rewrite of this file dropped. git show 297ca0ec1:TODO.md still has them,
and they are restored below verbatim. **Two are plaintext data leaks.**

| # | Blocker | Note before starting |
| --- | --- | --- |
| **B5** | Linux writes every typed character, in plaintext, into a world-readable `/tmp` file on every keylogger flush (`linux/modules/keylogger/sqlite_writer.lua:96-112`, `:127-139`) | the temp name comes from `tmpnam(3)` then is mutated, so it is not the reserved file — a symlink/TOCTOU target. Stop shelling SQL through a file; the `sqlite3` CLI reads a script on stdin |
| **B4** | Linux keylogger is always on, in plaintext, with no off switch, no private-browsing and no system-auth filter | ⚠ **do NOT simply wire `adapters/secure_field_detector.lua`** — `modules/keylogger/keylogger.lua:90-98` documents that its exact `WM_CLASS` match on a shorter list would *narrow* coverage and leak `gpg`/`ssh-agent`/`polkit`/`sudo`, and a test guard locks "coverage must never narrow". The fix is **additive** |
| **B3** | The generated kanata config is unloadable: the generator emits 7 of the 12 aliases the template defines, leaving `@copy`, `@paste`, `@rollx`, `@deadtrema` dangling | `test:kanata-defalias-parity` never runs the generator against the template — extend it first, then fix the generator. The generator's own docstring also warns `ralt` needs hand-merging, which `manager.lua` does not do |
| **B6** | The macOS "Chiffrement" menu item is a complete no-op (ten empty stubs) and `docs/security/keylogger_privacy.md:93` tells users to enable it for at-rest privacy | the `type(...) == "function"` guard is always true because the stub exists, so the flow raises inside the stub's own `pcall`, the progress canvas is never deleted and no dialog appears. Decide: implement, or delete the feature **and** the doc sentence together |
| **B9** | `llm_context_length` has no effect on the Windows automatic path — the `context_window_chars` fix was never ported into the AHK generator (`grep -c context_window windows/**/*.ahk` → 0) | add a corpus vector that sets `context_window_chars`: none of the 12 existing vectors does, which is why the corpus cannot catch it |
| **B10** | Opposite secure-field defaults for LLM predictions: macOS hardcodes `true` (contradicting `defaults.json`, and both keys are absent from `_SHARED_SCALAR_KEYS` so the shared value is unreachable); Windows sends context from password fields | security posture — pick the default deliberately, then make both drivers read it from `defaults.json` |

Recovery route, for the next time a plan section vanishes: git reflog --all\nfinds the merge, git log --all --oneline -- <file> finds the versions, and
git show <sha>:<file> reads one. Searching git log --grep for the identifiers
finds nothing, because they only ever appeared in a file body — which is what made
this look like lost work rather than buried work.

Do that before running either prompt. An audit that reports findings while six
known defects sit unrecorded is an audit measuring the wrong thing.

`audit_mise_en_commun_et_simplification.md` **was run on 2026-08-03** — report at
[`docs/audits/2026-08-03-mise-en-commun-et-simplification.md`](docs/audits/2026-08-03-mise-en-commun-et-simplification.md).
Its findings are either fixed or folded into the sections above.
