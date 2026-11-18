# Key combinations and macOS shortcut bindings: Windows, macOS, Linux and shared

Audited source: `01ab90fa` (`dev`). Date: November 17, 2026.

## Scope

The two deep passes the shortcuts campaign left open: macOS `modules/shortcuts/bindings.lua` (tap keys, the layer's
wheel, the wrap of a selection, Cmd+★) and the key combinations: Linux `modules/shortcuts/key_combinations.lua`,
`infra/key_combinations_scope.lua`, engine and menu; shared `_shared/tap_hold/engine/key_combinations.lua`; macOS
`platform/remap` (`config`, `generator`, `init`) and `ui/menu/menu_tap_holds.lua`; Windows `infra/key_combinations.ahk`.
Compared: chord detection and symmetry, tap/hold/chord semantics, « Copy tap → combo », conflicts, persistence, menu
rows, refusals and logging, pause (EDD-1). Source reading with replays through the real Lua modules; no keyboard,
Karabiner or AutoHotkey hook driven.

## Fixed

| Id      | OS            | Severity | Before                                                                                                                                                         | Reference                                                               | Regression                                                                |
| ------- | ------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| KCL-001 | Linux, shared | High     | Shared planner asserted on a tap no chord runs (`key_combinations.lua:237`, `key_combinations_scope.lua:290-296`): nothing copied, generic save-failure dialog | Windows skips, logs, copies the rest (`key_combinations.ahk:1726-1729`) | `kcl-copy-skips-chordless-tap`                                            |
| KCL-002 | Linux         | Medium   | Read refused only `one_shot_shift` (`:140`), menu all three (`:383`)                                                                                           | Windows refuses and logs all three (`:1178-1181`)                       | `kcl-chord-read-refuses-chordless-action`                                 |
| KCL-003 | Linux         | Low      | Unavailable tap/hold and unknown pairs read as none in silence (`:100-107`)                                                                                    | Windows warns (`:199-216`), macOS reports (`config.lua:953-966`)        | `kcl-invalid-pair-slot-logged`                                            |
| KCM-001 | macOS         | High     | Picker, setter, copy and generator took `sticky_shift` in a chord (`menu_tap_holds.lua:382-386`, `init.lua:5059`, `config.lua:1397`, `generator.lua:2256`)     | Decision 2026-11-06; Windows `:1081`, Linux refuse                      | `kcl-chord-refuses-one-shot-shift`, `chord-refused-actions-single-source` |

One list: `CHORD_REFUSED_EVERYWHERE` (shared); the Windows map and the Linux additions are pinned to it by
`chord-refused-actions-single-source`. Commits 2286dc55bb, c156bd5337, 918d8d9308, 1282d7620d, e9c641d0d3.

BNM-1, macOS, Medium, resolved November 18, 2026: the navigation layer's wheel stopped with the Shortcuts switch,
because it was a child of the bindings layer (`bindings.lua:288`) that `pause_bindings` pauses whole. Windows (only
`LayerEnabled` gates the wheel hotkeys, the script pause suspends them) and Linux (the tap-hold engine owns the wheel,
`TapHold.set_paused` holds it back) never tied it to Shortcuts. Its owner is now `modules/shortcuts/layer_wheel.lua`:
started and stopped with the Shortcuts subsystem, left bound by `pause_bindings`, paused and resumed by ScriptControl
as its own `shortcuts.pause_layer_wheel` step. Regression: `test_layer_wheel_owner.lua`.

## Open

KCD-1 to KCD-8, BND-1, BND-2 and KCH-1 as listed in TODO.md « Maintainer decisions pending » and « Parity audit ».

## Refuted

Chord deadline inclusive on every OS; the earlier catalogue order owns a symmetric chord and alone fires; a tap-only
pair fires on press and repeats, a pair with a hold swallows repeats; a chord wins over the ordered pair; clearing a
pair empties tap, hold and the owner chord; pause per EDD-1 on all three, macOS resume keeps `_disabled_set`; Windows
`Symmetric ? 1 : 0` unreachable for a mistyped value at boot (`ConfigTomlBootSnapshotValue` keeps the default);
bindings inventory, defaults and storage consistent; register row on the Windows bulk copy corrected.

## Not reviewed

Pair collisions with tap-hold keys or keyboard slots; a waiting Linux chord key at the moment of a pause. Native
receiving unqualified.
