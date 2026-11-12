# Navigation layer editor host

Audited source: `9a9be774` (`claude/ergopti-todo-parity-audit`). Date:
November 12, 2026.

## Scope

The navigation layer editor window's host on macOS (`macos/ui/layer_editor`)
and Linux (`linux/ui/layer_editor/bridge.lua`) and the shared
`_shared/lua/keymap/layer_editor.lua`, against the Windows reference
(`windows/ui/layer_editor/init.ahk`). Pausing is out of scope: a maintainer
decision (EDD-1) allows configuration writes while paused.

Checked and kept:

- **Page protocol:** the actions are `ready`, `save`, `cancel` and `legends`;
  the replies are `init`, `saveResult` and `setLegends`.
- **Save checks:** the byte bound and the error codes match.
- **BOM:** it is stripped before the file is read.
- **Write:** the save is published atomically, and only while the file still
  holds the bytes read when the window opened.
- **After a save:** a successful apply closes the window; a failed one keeps
  it open.
- **Window:** a reopen focuses the open window, and a second save is ignored
  while one runs.
- **Wiring:** the menu command and the gesture action open the editor on every
  OS, and each host finds the layer keys through its tap-hold owner.

## Fixed

| Id      | OS           | Sequence                                                 | Windows                                                    | Before                                                              | Regression                    |
| ------- | ------------ | -------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------- | ----------------------------- |
| LEH-001 | macOS, Linux | Emulate a layout, open the navigation layer editor       | Keys show what the emulation types (`source: "emulation"`) | Keys showed the system layout's characters                          | `leh-001-emulated-legends`    |
| LEH-002 | Linux        | Save while the configuration folder moves (paths editor) | `saveResult` with `applied: false`                         | No answer: the page stayed in « saving », Close and Escape disabled | `leh-002-stale-folder-answer` |

LEH-001 adds `legend(session, code)` to the shared
`layouts/keylayout_emulation.lua`: what a key types unshifted from rest, with
the row switches and the number-row ordering applied, and a dead key's
terminator. The shared contract holds it to what `decide` types on every key
of two layouts and two settings sets. Each driver's `layout_emulation`
exposes it, and the host falls back to the input source for a key the
emulation passes.

## Open

- **LEH-003 (macOS, low, design):** a save closes the window as soon as
  Karabiner accepts the regeneration request. A regeneration that fails later
  (`on_done(false)`) is only logged, so the layer never takes effect without a
  word to the user. Windows' apply is its synchronous reload. This is the
  documented choice of `macos/ui/layer_editor/init.lua` (note 3). Holding the
  window until `on_done`, or a notice after it closed, is a maintainer
  decision.

Native receiving is unqualified.
