# Input and layout engine joins: Windows, macOS, Linux and shared

Audited source: `e0a801ef` (`claude/ergopti-todo-parity-audit`). Date:
November 11, 2026.

The register's next module after the AI flows. Windows (`windows/` layout
emulation, keyboard-layout emulation and shortcut hotkeys) is the read-only
reference; the Linux and macOS layout emulations
(`modules/keymap/layout_emulation.lua`), the Linux keyboard hook, the macOS
keymap tap and the shared emulation engine (`_shared/lua/keymap/`) were
compared on shortcuts under an emulated layout, the number row, synthetic
output order, modifier and source currency and several devices. Candidates
were replayed through the real Lua modules with each driver's test fixtures;
no X11/Wayland, NSEvent or Windows HKL receiving ran.

## Fixed (macOS and Linux)

| Id      | Sequence                                                                   | Windows                                    | Before                                                                                   | Regression                  |
| ------- | -------------------------------------------------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------- | --------------------------- |
| ILM-001 | macOS, Ergopti emulated, Cmd + physical Q (Ergopti z): press, then release | `SendEvent "^{z}"`: a matched down and up  | The press went out on Z, the release on Q: z never released, a Q release without a press | `cmd-chord-release`         |
| ILL-003 | Linux, a Cyrillic session layout, Ctrl + the key where Ergopti has c       | `_KLE_OnShortcut` sends the logical `^{c}` | The fallback was the physical key: Ctrl+X (cut) instead of copy                          | `emulation-shortcut-us-key` |
| ILM-002 | macOS, a non-Latin input source, Cmd + an emulated key                     | Logical, as above                          | `hs.keycodes.map` has no Latin letter: the chord silently kept the physical key code     | `cmd-chord-us-key`          |
| ILL-004 | Linux, hold Ctrl + emulated z (undo)                                       | `^SCxxx` hotkeys fire on every auto-repeat | No repeat callback: the hook swallowed every repeat, undo fired once                     | `emulation-shortcut-repeat` |

ILL-003 and ILM-002 fall back to the character's US key, where GTK, Qt and
macOS resolve a shortcut under a non-Latin layout; a character with no US key
keeps the physical one.

## Fixed by order of the daemon's key consumers

Decided by the coordinator on 2026-11-11, to review by the maintainer: the
Linux on-consume chain now runs `prediction_engine.handle_shortcut`, then the
bound-chord consumer, then the layout emulation (regression
`emulation-consume-order` in `test_prediction_control_retirement.lua`).

- **ILL-001:** the emulation ran before the bound-chord consumer and consumed
  every Ctrl/Alt/Super chord on an emulated key, so a keyboard shortcut slot
  bound to that chord never fired. Windows asks
  `KeyboardShortcutRunLayoutChord` first (`layout.ahk` `_RemapChordEmit`).
  Still open: the slot matches the system layout's key, where Windows' slot
  follows the emulated letter; offering the consumer the emulated character
  needs the emulation to expose its mapping.
- **ILL-002:** with the number row emulated, a bare digit was consumed by the
  emulation before `prediction_engine.handle_shortcut`, so the default
  validation chord typed the digit instead of accepting the prediction, as
  macOS does. Which Windows variant wins between the prediction's digit hotkey
  and the emulation's is not established.

## Decided

- **ILD-1, chords of two modifiers** (decided by the maintainer on
  2026-11-11): a chord of two modifiers sends the key of the layout's
  character, like a single-modifier chord. The shared engine resolves every
  Ctrl/Alt/Win chord at the Ctrl level whatever else is held, so macOS and
  Linux already do it, with the held modifiers kept; regression
  `two-modifier-chord` on each (`test_layout_emulation.lua`). Windows'
  keyboard-layout emulation registers only `^ ^+ ! !+ # #+`, so Ctrl+Alt+key
  reaches the physical key. Windows counterpart, for the maintainer
  (`modules/keymap/keylayout/keylayout_emulation.ahk`): add `"<^<!"` and
  `"<^<!+"` to `KLE_SHORTCUT_PREFIXES` (the left keys only, so AltGr, which
  Windows reports as LCtrl+RAlt, stays on `_KLE_OnAltGr`); in
  `_KLE_OnShortcut` and `KeylayoutEmulation_ShortcutChar`, strip the `<`
  side markers before reading the level and before `SendEvent`
  (`StrReplace(Mods, "<")`, so the level is Ctrl and the chord goes out as
  `^!{z}`); register a prefix with `!` in it at `KLE_ALT_INPUT_LEVEL` (test
  `InStr(Prefix, "!")`, not its first character); and add a Ctrl+Alt
  assertion beside the Ctrl+Shift one in `test_layout_composer_host.ahk`.
  To qualify on the PC: under a system layout with an AltGr level, Windows
  also reads a physical LCtrl+LAlt as AltGr, so the chord must be checked in
  an application that types AltGr symbols.

- **ILD-2, Ctrl+AltGr** (decided by the maintainer on 2026-11-11): Linux's
  rule on every OS, against the recommendation: Ctrl and the key's logical
  character (its Ctrl level), AltGr suspended. Linux already did it (the
  shared engine, `emit_shortcut` leaving AltGr out); macOS now clears Option
  from a Ctrl+Option shortcut (`layout_emulation.lua` `key_down`, Cmd+Option
  unchanged: decided by the coordinator on 2026-11-11, to review by the
  maintainer). Shared vector `ctrl_altgr_sends_ctrl_and_the_logical_key`;
  regressions `ctrl-altgr-logical` on each. Windows counterpart, for the
  maintainer (`modules/keymap/keylayout/keylayout_emulation.ahk`): in
  `_KLE_OnAltGr(Sc, *)`, when a Ctrl other than AltGr's own is physically
  held (`GetKeyState("RCtrl", "P")`, or `GetKeyState("LCtrl", "P")` beyond the
  LCtrl AltGr synthesises), call `_KLE_OnShortcut(Sc, "^")` (with `+` when
  Shift is held) instead of `_KLE_Emit`, so `SendEvent("^{" Char "}")`
  releases AltGr's RAlt around the chord; `_KLT_OptionsDecide` in
  `test_keylayout_emulation.ahk` routes a press holding both `ctrl` and
  `altgr` the same way, so the shared vector replays there.

## Refuted

A modifier and a key on different keyboards (the Linux hook's held modifiers
and Caps Lock are global, as on Windows); clipboard-route text overtaken by the
next key (the injection is synchronous); a lost Shift level in the Linux
shortcut; a reload leaving tap-hold modifiers held.

## Remaining work

- **Linux:** a modifier a tap-hold holds over a passed key (`emit_key`) still
  repeats nothing (the second half of ILL-004).
- **Not checked:** macOS Carbon `hs.hotkey` slots against the tap rewrite;
  Windows `_KLE_DigitsOwnKey` under Caps Lock; native receiving.
