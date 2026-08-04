<!-- TODO.md -->

# TODO

What actually remains. Everything finished, superseded or answered was removed —
the reasoning worth keeping went to
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md), which is the canonical memory
shared by every developer, agent and reviewer.

Working rules: no behaviour change without a regression test, never weaken a test
to make a change pass, and run the gates that cover what you touched —
`node ./tools/test/verify-change.cjs` derives them.

**Delete an entry the moment it is done. When this file is empty, delete it.**

> ⚠ **Re-measure before you start.** Over two long sessions, **eighteen** entries
> in earlier versions of this file turned out to be wrong — not stale by a
> little, but wrong in a way that inverted the work. On 2026-08-04 alone: two of
> the four "features absent from every driver" were the list mis-describing the
> drivers; the plan to lower the menu-row ratchet by migrating three blocks would
> have moved it by zero; and the 34-entry gesture reason that looked like a
> 34-point win would have frozen a falsehood in twenty-one languages.
> A finding is a lead, not a work order — and when you correct one, write the
> correction back here with the number.

---

## 1. Menu label-tree parity (I3) — the last ten rows

**Steps 1 and 2 are done.** The renderer is `_shared/lua/menu/renderer.lua`, a
factory each driver binds with its own decoder, manifest path, i18n, logger and
**platform token** — the parameter a first extraction plan missed while calling
467 lines "verbatim", and without which Linux would have rendered the macOS
projection. Linux now reads the manifest; its metrics submenu is the first on
that driver to render from it, predicates and all.

**Eleven rows turned out never to have been renderable** on the driver they were
declared for, each enumerating features the FEATURE manifest already marks
`["ahk"]`. Restricting them made the two manifests agree and took the
handler-bijection ratchet to **hs 16, linux 10** (from 20 and 27).

### What is left, and why each row needs a person

Ten rows on Linux, sixteen on macOS, and the two lists overlap almost exactly —
these are capabilities BOTH Lua drivers have and implement by hand without ever
naming the manifest id.

| rows | what has to be decided |
| --- | --- |
| `hotstring_categories_{standard,dynamic,ergopti}`, `hotstring_personal`, `hotstring_bulk_actions` | Mechanical, and the groundwork is done: `menu_manifest.hotstring_groups` classifies the groups, and macOS already tolerates the two spellings the repo uses for them (`distances_reduction` against `distancesreduction`) with `id:gsub("_", "")`. Copy that. |
| `hotstring_extensions` | Windows scans a bundled-extensions directory for TOML packs. Whether either Lua driver has an equivalent is unanswered — do not restrict it on the guess that it does not. |
| `hotstrings_params` group: `word_expanders`, `delays_colors`, `magic_key_config` | The blocker for the whole hotstrings migration on Linux. Migrating the five easy rows above without these leaves the group with no builder, so the renderer logs a warning on every menu build — worse than the hand-built menu it replaced. Answer these three first. |
| `edit_shortcuts` | "Open the personal shortcuts file." macOS's own manifest comment says this action is what stands in for the introspectable registry it lacks — so macOS should implement it. Linux needs to know whether it has such a file at all. |
| `active_layouts` (macOS only) | macOS builds the input-source list by hand in `menu_keyboard_layout.lua`; it is one handler away. |
| `gestures_menu` ×6 (macOS only) | `restore_defaults`, `circular_spaces`, `gesture_slots_{2,3,4,5}`. |

**Nothing here is blocked on the renderer any more.** Every remaining row is one
question — *does this driver have this capability, and under what name?* — and
the repository does not contain the answer for most of them.

⚠ **macOS is not a finished target to copy.** Its top-level menubar
(`ui/menu/builder.lua`) does not go through the renderer at all: it iterates the
manifest tail and dispatches through a hardcoded chain, which is what the
extended parity gate now checks.

---

## 2. Incremental by design — do not batch these

- **`reason_key` for platform restrictions (I2).** 138 restrictions carry no
  reason. The rule is the one the two written reasons follow: **a reason is only
  writable when it stays true on the assumption that everything else in this
  repository is finished.** `script.alt_gr_is_kana_remap` (a Windows
  keyboard-driver concept with no counterpart) and `llm.models.mlx` (Apple
  Silicon only) both pass it. Describe one as the feature around it is revisited,
  by someone who knows why it is missing, and lower the baseline then.

  ⚠ **Do not take the gesture shortcut.** One shared key on the 34 hs-only
  `features.gestures` entries would take 138 → 105 for 21 strings. But
  `platforms = ["hs"]` excludes Linux too, and Linux ships the gestures module,
  its menu and its defaults — what it lacks is a touch reader that
  `manager.lua`'s own header calls a TODO. That half of the reason would read
  "not coded yet", which is the one thing the model forbids, and the strings
  would freeze it there. The gate's header now records this.

- **Menu rows outside the renderer (I3).** Frozen at windows 220, macos 301,
  linux 3, and it should stay frozen until someone converts rows to the `list`
  type. Unmoved by the renderer extraction, as predicted: macOS total fell 331 →
  328 and its in-renderer count 30 → 27, because the three rows that moved to
  `_shared` left both sides of the subtraction. **Routing a menu through `ManifestMenu.build` does not lower it** —
  `menu_gestures`, `menu_metrics` and `menu_shortcuts` all do and are all still
  counted, because a `dynamic` handler appends its rows in the driver file. The
  mechanism is written into the gate's header next to the number, along with
  `--measure`, which prints the eight largest bypasses per driver.

- **Gates to retire — retire nothing yet.** Neither precondition is met.
  `test_menu_hotstrings_layout_drift_gate.lua` guards a migration with zero
  progress (`builder.lua` reads four manifest keys, neither of the two it
  guards). `test_menu_top_level_drift_gate.{lua,ahk}` need the tail to be typed
  manifest rows with registry-validated ids, and a Linux twin. The path is
  §1 above plus what already landed: generalising the one gate that reads a real
  builder is what will eventually make both hand-typed canonical lists redundant,
  and that is the right reason to delete them.

---

## 3. Open questions somebody has to answer with a keyboard

- **Does `features.gestures` describe Linux correctly?** 45 rows, 11 `ahk,hs`,
  34 `hs`, **zero** mentioning Linux — against a driver that ships
  `modules/gestures/manager.lua`, a `_build_gestures` menu, Linux-specific
  defaults and a test file, but no touch reader. Either the manifest is wrong in
  the kanata/updates/apps shape, or the platforms field means "can actuate" and
  should say so. This is a maintainer call, not a measurement.

- **The Windows e2e replays 5 of the 34 corpus vectors** (`run_e2e.ahk`), and
  says so nowhere. The macOS and Linux runners replay all of them. Either that
  subset is deliberate and should be declared, or it is a gap.

- **Read the performance numbers.** The instrumentation is complete — 20 HotPath
  segments and 5 pre-logger boot stamps, inventoried by
  `test-hotpath-segments-declared.cjs`. What is missing is a day of real use on a
  Windows machine, not code. See
  [`project-instrumentation-absence-is-invisible`](docs/PROJECT_MEMORY.md).
