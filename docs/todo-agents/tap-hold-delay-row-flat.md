# Tap-hold key delay: one clickable row instead of a submenu

Maintainer request of 2026-10-22: the per-key tap delay of each tap-hold key
was a submenu whose single row opened the delay prompt. Clicking the row that
shows the current delay now opens that prompt directly, on the three systems.

## Done

- Shared manifest (`_shared/modules/features/manifest.toml`): the
  `tap_hold_key_delay` row of `tap_hold_key_delay_tail` is a `command` with the
  same label and caption getter as the old submenu caption
  (`menu.tapholds.key_tap_delay`, "Tap delay: %s"). The `tap_hold_key_delay_rows`
  section and its row `tap_hold_key_delay_set` are deleted, and so is the locale
  key `menu.tapholds.key_tap_delay_set` in the 21 locales (no other reader).
- macOS: the "Use global delay (%s)" check, the second row of the old submenu,
  now sits right under the delay row in the key's menu (same id, same
  `checked_when` / `disabled_when`), so no nesting is left on any system.
- Windows (`windows/ui/menu/menu_taphold.ahk`), macOS
  (`macos/ui/menu/menu_tap_holds.lua`) and Linux (`linux/ui/menu/menu_builder.lua`)
  bind their existing prompt owner to the `tap_hold_key_delay` command:
  `_TH_MakeDelayPickerFn(KeyId)`, the AppleScript dialog plus
  `karabiner.set_tap_timeout`, and `ask_delay(key_id, ms)`. The prompts and setters
  are unchanged.
- Other one-row "click to edit" submenus in the tap-hold menus: none. The macOS
  global tap/hold and sticky delays and the combo delay (macOS and Linux, under
  Shortcuts) were already plain rows; Windows and Linux show no global delay row; the hold picker is a real list of
  seven choices and stays a submenu.

## Tests

- `tools/test/test-menu-manifest.cjs`: the delay row is a command on the three
  platforms, `tap_hold_key_delay_rows` and the retired key are gone, each driver
  binds `tap_hold_key_delay` to its prompt owner.
- `_shared/tests/corpus/menus/tap_hold_key_delay.json`, replayed by
  `linux/tests/unit/ui/menu/shortcuts/test_tap_hold_menu_holds.lua` for the three
  platform projections: the row has an action and no submenu, clicking it calls the
  delay command.
- macOS `test_menu_tap_holds_hand_sections.lua`: "opens the delay prompt from the
  row itself, with no submenu" (dialog starts from the current value, saves 375 ms
  through `set_tap_timeout`, regenerates and refreshes).
- Linux `test_tap_hold_menu_native_per_key.lua` and the malformed-source case of
  `test_tap_hold_menu_holds.lua` click the row itself and save through the writer.
- Windows `test_tap_hold_hand_sections.ahk` and
  `test_tap_hold_menu_register_dispatch.ahk`: the row has an action and no items,
  and `_TH_KeyRows` binds `"tap_hold_key_delay", _TH_MakeDelayPickerFn(KeyId)`.
  The prompt-to-setter path stays covered by `test_tap_hold_duration_transaction.ahk`.
- The renderer caption-group contracts (shared Lua and Windows) used the delay
  submenu as their fixture; they now use the hold picker (Windows, Linux) and the
  gesture mode group (macOS).

## Manual checks left

- Windows: tray, Tap-Hold, any key: "Tap delay: N ms" is a plain row; clicking
  it opens the input box with N, OK saves and reloads.
- macOS: same row opens the AppleScript dialog; "Use global delay (…)" is the row
  below it, checked and greyed while the key has no override of its own.
- Linux: same row opens the zenity/kdialog prompt (no Linux machine here).
