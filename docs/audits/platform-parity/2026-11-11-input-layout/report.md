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

## Open (not fixed: order of the daemon's key consumers)

- **ILL-001:** Linux runs the layout emulation (`ergopti_hotstrings.lua`
  on-consume chain) before the bound-chord consumer, and the emulation
  consumes every Ctrl/Alt/Super chord on an emulated key, so a keyboard
  shortcut slot bound to that chord never fires; reached, it would also match
  the system layout's key rather than the emulated letter. Windows asks
  `KeyboardShortcutRunLayoutChord` first (`layout.ahk` `_RemapChordEmit`) and
  its slot follows the letter. A fix offers the bound-chord consumer the
  emulated character as its key before `emit_shortcut`.
- **ILL-002:** with the number row emulated, a bare digit is consumed by the
  emulation before `prediction_engine.handle_shortcut`, so the default
  validation chord types the digit instead of accepting the prediction (macOS
  accepts it: the keymap rewrites the text but keeps the key code). Which
  Windows variant wins between the prediction's digit hotkey and the
  emulation's is not established.

Both change the order of the consumer chain in the daemon's main module, which
the coordinator or the maintainer should settle; a regression would drive the
real chain through the main-module harness of
`test_prediction_control_retirement.lua`.

## Decisions pending

- **ILD-1, chords of two modifiers.** Windows' keyboard-layout emulation
  registers only `^ ^+ ! !+ # #+`, so Ctrl+Alt+key reaches the physical key,
  while its built-in remap (`*Sc` with `{Blind}`) sends the logical one; the
  shared engine always uses the Ctrl level (logical on both Lua drivers).
- **ILD-2, Ctrl+AltGr.** Windows types the AltGr level (`SC138 & Sc`); Linux
  sends Ctrl + the logical key with AltGr suspended.

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
