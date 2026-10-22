<!-- docs/todo-agents/macos-tap-hold-action-picker.md -->

# Tap-hold actions open the shared action picker

The maintainer's rule (October 21): choosing a tap-hold key's action, or a
key combination's, never opens a submenu of actions; it opens the shared "all
actions" picker (`_shared/ui/action_picker/`) that gestures and keyboard
shortcuts use, on every system.

## Done

Keys: 61ab0fb351 (on origin/dev, pushed by another agent). Key combinations:
1eb85e2b6b, and b4ce3759b6 for the live lease-transition tests that still
picked through the old submenus (CI run 39678425941, seven
`live-tap-hold-transition` reds); both local, not pushed.

- **macOS.** A key's « Tap → … » and « Hold → … » rows are now commands that
  open the shared picker (`open_slot_picker` in
  `macos/ui/menu/menu_tap_holds.lua`). The picker lists the remap catalogue
  the slot accepts (the tap: every tappable action; the hold: the holdable
  ones, that is modifiers, chords, sticky keys and the layer), one heading
  per category, with search; the current action is marked; the picker's own
  « ∅ » row clears the slot. A pick goes through the same owner as the
  former submenu: `set_tap_action` / `set_hold_action`, then the exact
  regeneration and the menu refresh. An id the slot does not offer, or a
  refused setter, keeps the picker open and writes nothing else. The window
  title is « Tap action — <key> » or « Hold action — <key> »
  (presentations `tap_hold_action`, now also on macOS, and
  `tap_hold_hold_action`, new, in `_shared/ui/apps.manifest.json`).
- **Manifest.** `tap_hold_key_tap` is one command row for the three drivers;
  the macOS group rows `tap_hold_key_tap_picker` and `tap_hold_key_hold_picker`
  are gone, replaced for the hold by the command `tap_hold_key_hold_action`
  (macOS only). The `menu.tapholds.tap_arrow` / `hold_arrow` captions are
  retired; their translations moved into `tap_hold.picker.tap` / `hold`,
  which were English in eleven locales on Windows and Linux.
- **Windows.** Already opened the shared picker for the tap
  (`_TH_TapPickerFnObj` → `ShowActionPicker`); unchanged.
- **Linux.** Already opened the shared picker for the tap through its webview
  bridge (`pick_tap` → `ui.action_picker.bridge`); unchanged.
- **macOS key combinations.** Under Shortcuts, a pair's three slots (chord,
  hold 1 + tap 2, hold 1 + hold 2) open the same picker through
  `open_slot_picker`, titled « <slot> — <pair> » (presentations
  `key_combination_chord_action`, `key_combination_tap_action`,
  `key_combination_hold_action`; their prefixes are the slot captions without
  the arrow, in all 21 locales), and save through `set_combo_*_action`. The
  last action submenu builder (`build_action_picker`, its manifest frame
  `tap_hold_action_picker_frame` and `MenuUtils.build_action_picker`) is
  removed. Windows opens the picker for a pair's tap and Linux for its tap and
  chord; their pair hold is the seven hold options (a submenu on Windows, a
  list dialog on Linux), so neither has an action submenu left.
- **Tests.** macOS `test_menu_tap_holds_hand_sections.lua`
  (« the macOS key slots open the shared action picker », cases named
  `tap-hold-action-picker`): both rows open the picker with the key's
  presentation, suffix, current action and slot catalogue; a pick is
  persisted through the key's setter and regenerates; false, nil, truthy or
  throwing setters keep it open with no regeneration; an action the slot does
  not offer is refused; a picker that does not open is reported; no key row
  builds an action row any more. « the macOS key-combination slots open the
  shared action picker » (`key-combination-action-picker`) does the same for
  the three pair slots, and the HS-019 picker routes of
  `test_karabiner_bulk_commands_transaction_manifest_commands.lua` now pick
  through the picker for the five slots. The head, corpus and title tests on
  the three drivers follow the new declarations.

## Windows and Linux hold (decided 2026-10-22)

A key's « Hold → … » row and a pair's « Hold 1 + hold 2 → … » row open the
shared picker too, on Windows and Linux, listing only what a hold can be: the
options of `[tap_hold.hold_picker]` (every modifier and combination of
modifiers, then the navigation layer), without the « none » sentinel, which
the picker's own « ∅ » row stands for. `tap_hold_key_hold_action` is now one
command row for the three drivers; the group `tap_hold_key_hold` is gone.

- **Windows.** `_TH_OpenHoldPicker` (`ui/menu/menu_taphold.ahk`) and
  `KeyCombinationShowHoldPicker` (`infra/key_combinations.ahk`) call
  `ShowActionPicker` with a `Slot` (`items` from `TapHoldHoldPickerItems()`,
  `after_close` = the reload). In that mode the pick is committed while the
  window is open (`TapHoldSetHold` with the configuration folder, or
  `SetKeyCombinationHold` without its reload); the integer 1 closes the
  window and then reloads, anything else keeps it open. Titles:
  `tap_hold.picker.hold_title_prefix` + key,
  `menu.shortcuts.key_combinations_hold_hold_title_prefix` + pair.
- **Linux.** `pick_hold` (`ui/menu/menu_builder.lua`) opens the bridge with
  the presentation `tap_hold_hold_action` and writes through
  `tap_hold_writer.set_hold`; a pair's hold goes through the `open_hold_picker`
  port with `key_combination_hold_action` (both presentations now declare
  `linux`). The items come from `HoldOptions.picker_items`
  (`_shared/lua/tap_hold/hold_options.lua`). The bridge keeps a refused pick
  open.

## Remaining

- The macOS tap catalogue is Karabiner's (`platform/remap/data/actions.json`):
  it has no action with a parameter, so the picker's parameter editor never
  shows there. Windows' tap offers the gesture catalogue instead; giving a
  Karabiner tap a Hammerspoon action would need a dispatch bridge.

## Check on the Mac

1. Reload ErgoptiPlus with Karabiner on and Tap-Holds on.
2. Menu bar → Tap-Holds → a key (for example Caps Lock) → « Tap → … »: a
   window titled « ErgoptiPlus — Tap action — Caps Lock » opens, with a
   search field, category headings and the current tap highlighted. No
   submenu unfolds.
3. Type « esc » in the search, pick Escape: the window closes, the key row
   reads « Caps Lock : Escape / … », and a tap of Caps Lock types Escape.
4. Same key → « Hold → … »: the window is titled « Hold action — Caps Lock »
   and lists only modifiers, chords, sticky keys and the layer; pick Ctrl and
   check that holding the key acts as Ctrl.
5. Reopen « Tap → … » and pick « ∅ »: the tap goes back to the key's own
   character.
6. Menu bar → Shortcuts → « Combinaisons de touches » → a pair (for example
   Left Shift + Right Shift) → each of its three slots: a window titled with
   the slot and the pair opens (no submenu); the hold slot lists only
   holdable actions. Pick an action in « Hold 1 + tap 2 », check the pair row
   shows it, then hold the first key and tap the second.

## Check on Windows and Linux

1. Tray → Tap-Holds → CapsLock → « Hold → … »: a window titled « Hold
   action — CapsLock » opens (no submenu), listing Ctrl, Ctrl + Shift, …,
   the navigation layer; the current hold is highlighted.
2. Type « nav », pick the navigation layer: the window closes, the driver
   reloads, the key row reads « … / Nav layer », and holding CapsLock enters
   the layer (on Windows a missing layers.toml is created from the
   recommended one).
3. Reopen it and pick « ∅ »: the key holds nothing.
4. Shortcuts → « Combinaisons de touches » → a pair → « Hold 1 + hold 2 → … »:
   a window titled « Hold 1 + hold 2 — <pair> » lists the same holds; pick
   Shift, then hold the first key and the second: Shift is held.
