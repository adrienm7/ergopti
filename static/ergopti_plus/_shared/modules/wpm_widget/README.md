# wpm_widget (shared constants)

## Purpose

The one description of how the typing-speed readouts look on every driver:
the floating pill, its real-time graph mode, and the menu bar (macOS) or tray
(Linux) readout. Windows has no menu bar readout. No driver restates a value
from `constants.toml`: each reads it at runtime and refuses to draw when a key
is missing.

Refresh rates, the colour hold and the idle hide are timings, and live in
`_shared/modules/timings/constants.toml` (`[ui]` and `[keylogger]`).

## Key files

| File             | Description                                                                  |
| ---------------- | ---------------------------------------------------------------------------- |
| `constants.toml` | Pill and graph geometry, colours, neutral sources, opacity, menu bar style   |

## Driver implementations

| Driver  | Consumer                                                                                   |
| ------- | ------------------------------------------------------------------------------------------ |
| macOS   | `macos/ui/wpm/{wpm_widget,wpm_menubar,shared}.lua` through `_shared/lua/wpm_widget/model.lua` |
| Linux   | `linux/ui/wpm/{widget,tray_readout}.lua` through `_shared/lua/wpm_widget/model.lua`         |
| Windows | `windows/ui/wpm/wpm_config.ahk` (`WPMWidget_LoadSharedConst`)                              |

The two Lua drivers also share every decision the readouts make — colours per
source, the graph's curve, when to show, the default place — in
`_shared/lua/wpm_widget/model.lua`, and the live speed in
`_shared/lua/keylogger/live_wpm.lua` (Linux; macOS keeps its keylogger's own
buffers over the same timings).
