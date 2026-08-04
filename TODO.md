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

## 1. Menu label-tree parity (I3) — the label half

**The shape half is done.** The manifest has a Linux dimension,
`test-menu-top-level-parity.cjs` holds it in both directions, and since
2026-08-04 it also reads the two hardcoded dispatch chains on macOS and Windows —
the direction nobody was checking, because "those drivers render from the
manifest" is true and misleading: they iterate it and dispatch each id through an
if/elseif chain, so the manifest supplies the ORDER and the driver supplies every
ROW.

**What remains is the label half, and it is three steps of very unequal size.**

### Step 1 — extract the renderer to `_shared/lua/menu/`

`macos/infra/manifest_menu.lua` is 561 lines and makes **one** Hammerspoon call
(`hs.json.decode`). 519 of the 561 relocate; the precedent for the dependency
shape is `_shared/lua/keycodes/evdev.lua`, whose docstring already describes
injecting a JSON decoder for exactly this reason.

⚠ **A first measurement said "lines 93-559 move verbatim" and it is wrong.**
Line 237 is `if not is_for_hs(item)` and lines 119-122 define that macOS-only
alias. Followed literally, Linux would render the **hs** projection and drop
`kanata`, `updates` and `apps` — the three rows the parity gate was written to
expose. **The module needs a platform token injected**, alongside the decoder,
paths, i18n and logger. AutoHotkey hardcodes its own the same way
(`_MI_IsForAhk`), which is the concrete reason the two 561-line files were never
shareable as written.

Inject the decoder rather than replacing it: macOS keeps `hs.json.decode` on the
boot path. macOS then keeps a ~25-line shim, which `test-name-parity.cjs`
requires — it asserts the path still exists.

🚩 **This trips the menu-row ratchet, and that needs deciding, not patching.**
`test-menu-rows-outside-renderer.cjs` counts `infra/manifest_menu.lua` as one of
macOS's two renderers. Move the rows to `_shared` and macOS's in-renderer count
falls to zero, which the gate reports as "the renderer path is wrong". Extending
its `renderers` set to the shared module is defensible — the renderer moved — but
it must be an explicit decision recorded in the gate, not a quiet edit.

### Step 2 — wire Linux in

~30 lines. `_shared/lua` is already on Linux's `package.path`, `Paths.shared` has
the identical signature, `i18n.get` exists, and `i18n.section` is two lines
wrapping the already-shared `decorate_section`.

### Step 3 — the handlers, and this is the real work

The renderer only DISPATCHES. `test-menu-action-handler-bijection.cjs` measures
Linux at **27** unresolved `action`/`dynamic` rows, and `M.build` skips `toggle`
(6 rows) and `feature` (7) entirely — so **40**, not 27. That is the label half.

**Steps 1-2 change nothing a user sees.** They make Linux *capable* of manifest
rendering; not one label moves until step 3. Anyone measuring "is the label half
done" after them will find the menus identical, and the honest framing is that
they remove duplication and unblock, rather than deliver, the goal.

⚠ **macOS is not a finished target to copy.** Its own top-level menubar
(`ui/menu/builder.lua`, 644 lines) does not go through the renderer at all, and
it still has 20 unresolved rows of its own.

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
  type. **Routing a menu through `ManifestMenu.build` does not lower it** —
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
