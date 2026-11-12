# Tap-holds, chords and the navigation layer: follow-up on the drift

Audited source: `c054579d` (`claude/ergopti-todo-parity-audit`), against the
2026-11-10 campaign at `637c017a`. Date: November 12, 2026. Census:
`source-areas.json` beside this report (381 areas; see the register in
`docs/platform-parity-audit.md`).

## Scope

This report covers only what changed in the module since
[the first campaign](../2026-11-10-tap-holds/report.md):

- the shared tap-hold file (`_shared/lua/tap_hold/shared_file.lua`,
  `migrate.lua`, `_shared/tap_hold/{SCHEMA.md,migrations.toml,shared_file.toml}`);
- the Linux writer, loader and engine;
- the Linux key combinations;
- the macOS generator and `tap_hold_file.lua`.

It also covers that campaign's two open macOS rows. THD-1 to 4 are not
repeated.

Context: `9b9ccd07` took the shared tap-hold layout back off `dev`. The series
stays on `wt/taphold-landed` until its macOS and Linux suites pass in CI. So
the 2026-11-11 decision « One configuration layout on every OS for tap-holds »
is not the state of `dev`. Its text sits, misplaced, under « No Linux keyboard
slot runs through a pause » in `docs/memory/maintainer-decisions.md`, and its
own heading is empty.

Checked and kept:

- **Engine:** the `tap_hold_engine.lua` drift is the THL fixes only, with no
  timing change.
- **macOS generator:** `apply_tap_minimum` agrees with the hold-past-threshold
  branch.
- **Delays:** `retired_delays` is one set on all three drivers.
- **Windows migration:** Windows ignores, and does not refuse, `[legacy_imports]`.
- **Defaults:** an absent `[mod_combos] enabled` means on everywhere.

## Fixed

| Id      | OS    | Sequence                                                                                | macOS                | Before                                          | Regression                     |
| ------- | ----- | --------------------------------------------------------------------------------------- | -------------------- | ----------------------------------------------- | ------------------------------ |
| TCL-003 | Linux | One `[mod_combos.config.*]` combo names an action Linux lacks (macOS `mission_control`) | Drops that leaf only | Every Linux key combination off, nothing logged | `tcl-003-foreign-chord-action` |

## Open: the shared tap-hold file (series on `wt/taphold-landed`)

These findings are for the series that owns the file. They are not fixed on
this branch.

- **TCL-001 (high):** the layout at `HEAD` keeps `[tap_holds]` `enabled`,
  `lone_modifier_tap_max_ms` and `sticky_timeout_ms`, and the whole
  `[mod_combos]`, in `tap_hold.toml`. Linux even moves `config.toml`
  `[mod_combos]` there (`import_config_combos`). The decision text puts them in
  `config.toml`, where Windows keeps them. A folder carried between OSes loses
  them.
- **TCL-002 (high):** `shared_file.lua` copies tap, hold and combo action ids
  untranslated. A Linux `enter` / `one_shot_shift` CapsLock read on macOS (which
  writes `return` / `sticky_shift`), and the reverse, types nothing. The
  equivalences already exist in `actions.toml`, and `enter`↔`return` needs a
  row. The corpus uses only `copy` and `backspace`, which hides this.
- **TCL-004 (medium, decision):** the catalogue's Mac thumb keys
  (`left_command`, `left_option`, `right_command`, `right_option`) are separate
  ids from the PC roles they play (`left_alt`, `right_ctrl`, `alt_gr`). Linux
  ignores them, and `left_ctrl` maps keycap to keycap. Positional or role ids
  is a maintainer decision.
- **TCL-005 (low-medium, macOS):**
  - A per-key delay that is not a whole millisecond refuses the whole
    Karabiner build.
  - A global delay above the 10 s bound of `SCHEMA.md` is accepted.
  - A per-key value ≤ 0 becomes the global delay without a warning.
- **TCL-006 (low):** with `inherit_defaults`, a macOS « no hold » or tap `none`
  is written as an absent field, which Linux and Windows fill from the shipped
  default.
- **TCL-007 (low, macOS):** every macOS save re-renders the whole
  `tap_hold.toml`, which drops comments and the Linux header.

## Open: the 2026-11-10 macOS rows (still true at `HEAD`)

- **LAlt's one-shot Shift:**
  - **Now:** with no hold, `generator.lua`'s `#hold_to == 0` path fires at
    key-down, holds no Shift, and accepts every modifier (`optional = ["any"]`).
  - **Windows:** `lalt.ahk` holds LShift and stands down under RCtrl,
    CapsLock, LShift or LCtrl.
  - **Generator fix:** append the held `left_shift`, narrow `optional`, and
    add swallow manipulators on `ke_held_*`, as the Fn blocker does.
  - **Status:** needs native qualification on a Mac.
- **A pair's first key:**
  - **Now:** Karabiner rule order decides. Windows and Linux use press order.
  - **Generator fix:** pairwise precedence variables set by a to-event's own
    conditions (as `apply_tap_minimum` relies on), N² variables.
  - **Status:** needs native qualification.

Native receiving is unqualified.
