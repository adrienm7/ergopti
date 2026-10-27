<!-- docs/design/one-shortcut-model.md -->

# One shortcut data model (plan for PAR-41, in progress)

Status: steps 1, 2 and the shared part of step 7 are done (see "Progress").
Audit rows C12 and C13 of `docs/audits/2026-10-24-cross-os-parity.md` are the
evidence.

## What exists today

The three drivers store a keyboard shortcut in three different shapes:

| Driver  | Shape in `config.toml`                                                            | Ids                                |
| ------- | --------------------------------------------------------------------------------- | ---------------------------------- |
| Windows | 16 legacy booleans, 16 `shortcuts.keyboard.win_*` slots, 5 `shortcuts.personal.*` | `win_a`, `win_g`, `win_space`, ... |
| macOS   | 21 `shortcuts.keys.ctrl_*` booleans                                               | `ctrl_*`, `hs_ctrl_space`          |
| Linux   | `shortcuts.keyboard.<slot>` holding an action id (`ctrl_g`, `super_space`, ...)   | modifier-prefixed, no OS name      |

Two of the three models bind a key to a feature switch (a boolean), the third
(Linux, and the `win_*` slots) binds a key to a catalogue action. Ids carry the
OS (`win_`, `hs_`) where the key is the same physical chord.

## Target model

One slot, one action, one neutral id, on every driver:

- Slot id: `<modifiers>_<key>` in a fixed modifier order, with the primary
  modifier named by role, not by OS (`primary_g` is Ctrl on Windows and Linux,
  Cmd on macOS). Roles: `primary`, `secondary`, `alt`, `meta`.
- Value: a catalogue action id from `_shared/modules/actions/actions.toml`
  (`none` clears the slot). A feature that was a boolean becomes the action
  that toggles it.
- One section, `shortcuts.keyboard`, declared once in the manifest with
  `platforms` per slot where an OS cannot honour the chord (with a
  `reason_key`, see PAR-37).
- Personal shortcuts stay a separate surface (a script on Windows and macOS, a
  set of slots on Linux, see the reason text of `edit_shortcuts`).

## Why no migration

The repository has no users (memory note `project-no-users-no-backcompat`).
Old keys are not read, not converted and not aliased. A leftover key is
reported by the unused-key scan and offered for removal.

## Steps

1. Inventory: list every legacy boolean, `win_*` slot and `ctrl_*` boolean with
   its action, in one table checked into `docs/audits/`.
2. Define the neutral id grammar and the role-to-key mapping in one shared data
   file; add a single-source test that each driver resolves a role to its key.
3. Declare the slots in the manifest, generate the three config templates and
   feature maps (`npm run build:manifest`).
4. Windows: replace the boolean readers by slot readers in the config loader and
   the hotkey registrar. The menu rows come from the manifest.
5. macOS: same for `modules/shortcuts`; remove the `hs_*` ids.
6. Linux: rename slots to the neutral grammar (already action-valued).
7. Tests per driver, plus a corpus of (slot, action) pairs replayed by all
   three. Run the full AHK suite before the Windows commit (meta tests pin call
   spellings).
8. Delete the retired readers and their tests in the same commit as each
   driver's switch, so no shim survives.

## Risks

- A chord means different things per OS (Win+G, Cmd+space). The role mapping
  must keep OS-reserved chords out of the shared set; those stay per-OS slots
  with a stated reason.
- AltGr and Kana layouts: every Windows chord change must work on AZERTY-style
  AltGr (LCtrl+RAlt) and Kana (SC138/VK_OEM_8). Keep that as an explicit test
  column.
- Menu churn: the shortcuts submenu is built from these rows on all three
  drivers, so the menu manifest, the locale labels and the healthcheck feature
  list change together. Land the manifest and the three drivers in one series.
- Size: the Windows legacy readers are the largest part; plan several atomic
  commits, one per driver, each green on its own suite.

## Progress

- Step 1 done: `docs/audits/2026-10-27-shortcut-inventory.json` lists every
  legacy boolean, keyboard slot, personal toggle and slot prefix family;
  `tools/test/test-shortcut-inventory-matches-sources.cjs` re-derives it from the
  manifest and the driver sources.
- Step 2 done: `_shared/modules/actions/slot_roles.json` holds the roles
  (`primary`, `secondary`, `alt`, `meta`, `shift`), generated to
  `_shared/lua/shortcuts/slot_roles_data.lua` and resolved by
  `_shared/lua/shortcuts/slot_roles.lua`. `secondary` is the Mac's Ctrl next to
  Cmd; `meta` is the Win/Super key and has no Mac equivalent.
  `tools/test/test-slot-roles-single-source.cjs` holds the table to
  `modifier_chords.json` and to the slot prefix families.
- Step 7, shared part done: `_shared/tests/corpus/shortcuts/neutral_slots.json`
  is replayed by the macOS and Linux unit gates through
  `_shared/lua/test/slot_roles_contract.lua`. Windows replays it when it adopts.
- Key catalogue gap: Win+', Win+CapsLock, Ctrl+CapsLock, Ctrl+' and Cmd+\* use keys
  (`quote`, `capslock`, `star`, `sc029`) that `modifier_chords.json` lacks; add
  them in step 3 before those chords become slots.

## Blocker for steps 5 and 6 (found while preparing them)

Renaming a macOS or Linux slot id drops the saved binding without a word. The
macOS owner (`keyboard_shortcuts.lua`, `walk_assignments`) consumes only slots
it owns and reports only malformed `physical_` ids; any other key under
`[shortcuts.keyboard]` is skipped, and `shortcuts.keyboard` is a declared
dynamic namespace, so the unused-key scan never offers it for removal. A probe
with a stored `secondary_space = "llm_generate_prediction"` left
`hs_ctrl_space` at `none` and bound nothing, with no warning. The same holds for
removing the 21 `shortcuts.keys.ctrl_*` booleans: a saved `true` is ignored
and the chord stops working. "No migration" therefore needs one explicit
decision before step 5 or 6: either every retired key is reported and listed
by the cleanup (a reader that names it, not a conversion), or a one-off
conversion is accepted. Nothing was renamed.
