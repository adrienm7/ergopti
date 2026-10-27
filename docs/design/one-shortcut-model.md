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

## Why saved bindings are migrated (supersedes "no migration")

The first draft of this note said the repository has no users, so old keys
would be neither read nor converted. That is superseded (maintainer's
decision, 2026-10-27): a setting a user chose is kept. The retired slot ids and
the redundant booleans of macOS and Linux are converted into the neutral slot
ids by one step of the shared config migration registry
(`_shared/core/config_schema/migrations.toml`, the same closed op set the
Windows engine already runs: `rename`, `copy_if_absent`, `map_value`,
`delete`, `set_if_absent`). No new op kind and no runtime alias exist: after the
step, only neutral ids are read. A leftover key that no slot owns is reported
through `ConfigOutdated` and offered by the cleanup, on macOS and Linux.

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

## Status after the macOS and Linux adoption

- Step 3 done for macOS and Linux: the 18 macOS Ctrl-letter switches
  (`ctrl_a` ... `ctrl_quote`, `cmd_shift_v`) are declared as
  `shortcuts.keyboard` slots (`secondary_a` ... `secondary_quote`,
  `primary_shift_v`) with their catalogue action as the recommendation; the
  shipped slots are `secondary_space` (macOS), `primary_g` and `meta_space`
  (Linux). Windows keeps its ids until step 4.
- Steps 5 and 6 done: macOS and Linux build their slot prefixes from
  `shortcuts.slot_roles` (families in menu order, longest prefix matched
  first). macOS also accepts Caps Lock and the apostrophe in slots
  (`extra_keys`), which `modifier_chords.json` does not carry because it also
  feeds every driver's chord actions.
- Step 8 done for macOS and Linux: the 18 hotkey factories and their menu rows
  are deleted. `ctrl_g` (open ChatGPT with `shortcuts.chatgpt_url`), `cmd_star`
  and `wrap_text_if_selected` stay as fixed switches: ChatGPT needs a per-binding
  URL parameter and a shared `chatgpt_url` retirement, the other two are not
  catalogue actions.
- Migration: schema v15 (`migrations.toml`, `v14_to_v15`). Every retired slot
  id is renamed, each switch becomes its slot and action (`false` becomes
  `none`), and a slot the user set wins over the switch of the same chord. Only
  the closed op set is used. Not converted: the per-slot action parameters
  (`gestures.action_parameters` keys `keyboard__<slot>__<action>`), because a
  rename op names one key and there are about 3,000 slot-and-action pairs per
  driver; a parameter of a renamed slot stays under its old name, is reported as
  outdated and offered by the cleanup, and the user re-enters it.
- Known edge: a user who cleared a slot to `none` and kept the switch of the
  same chord on had the switch win in the old runtime; after the step the
  cleared slot wins. This is the "existing target keeps its value" rule of
  `copy_if_absent`.
- A key under `[shortcuts.keyboard]` that no slot owns is reported through
  `ConfigOutdated` at boot on macOS and Linux. (The cleanup already listed it;
  only the boot warning was missing.)
- Chord action ids (`cmd_a`, `hs_ctrl_a`, `ctrl_a` ... the modifier chords of
  `modifier_chords.json`) are actions, not slots, and keep their names; the
  macOS `shortcut_groups` prefixes of that file build them.
