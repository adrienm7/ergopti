# Tooltips and WPM widget: Windows, macOS and Linux

Audited source: `claude/ergopti-todo-parity` (worker H), on `dev`.
Date: November 13, 2026.

## Scope

The editors campaign's last rows: the preview and AI suggestion bubbles and the
WPM widget with its tray readout. Windows is the reference unless a shared
contract or a maintainer decision says otherwise. Source reading with replays
through the real Linux modules; no desktop was rendered.

## Fixed (Linux)

| Id      | Sequence                                                     | Windows / macOS                                                        | Linux before                                                | Regression                 |
| ------- | ------------------------------------------------------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------- | -------------------------- |
| TWL-001 | Type a prefix whose trigger has a delay, wait for the bubble | The bubble hides `timeout_decrement_sec` before the window, floor kept | One timer of the raw delay: the bubble outlived its trigger | `preview-expiry-decrement` |
| TWL-002 | Type, then pause the script; or type a key while paused      | Widget and tray readout hide at once and stay hidden                   | Both kept ticking: a fading speed, the widget back on a key | `wpm-pause-hides`          |

## Open

- **TWL-003, the Linux AI suggestion bubble never times out.** Windows
  (`windows/ui/tooltip/llm.ahk`) and macOS (`macos/ui/tooltip/tooltip_llm.lua`)
  give a prediction the shared `[timing] llm_timeout_sec` (20 s) or the user's
  `llm_prediction` delay; Linux keeps it until the next activity and offers no
  such delay. Needs a timer and the Delays row on Linux.
- **TWD-1, a preview with no delay.** Windows hides it after a typed 3.0 s
  (`_TOOLTIP_SAFETY_SEC`); macOS and Linux keep it until the next key. The
  shared `safety_timeout_sec = 3.0` has no reader on any OS. A decision: read
  the shared value everywhere, or keep the bubble.
- **TWD-2, the WPM widget on a key that types nothing.** macOS and Linux show
  « 0 » for 3 s after a shortcut or an arrow key; Windows requires a speed or a
  recent source. Possibly deliberate (the 2026-11-06 pointer alignment).
- Per-row expiry inside a stacked Linux bubble (Windows and macOS dequeue each
  row at its own delay) is not ported.
