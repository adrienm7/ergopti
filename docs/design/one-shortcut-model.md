<!-- docs/design/one-shortcut-model.md -->

# One shortcut data model (plan for PAR-41, not started)

Status: plan only. No code changes belong to this note. Audit rows C12 and C13
of `docs/audits/2026-10-24-cross-os-parity.md` are the evidence.

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
