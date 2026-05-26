# keylogger

## Purpose

Low-level event tap daemon that intercepts, timestamps, and stores every human keystroke globally across the operating system. Drives context tracking (app focus, secure-field guard), hardware telemetry (battery, WiFi, mouse distance, system load), and persists everything to an SQLite database and a hot-path JSONL log.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | Global keystroke interception |
| `WindowInfo` | Active app and window title for context tracking |
| `SecureFieldDetector` | AX observer that marks password fields |
| `FileSystem` | Writing `today.log` (JSONL) and reading state |
| `Storage` | SQLite writes via `sqlite_writer` and `sqlite_reader` |
| `TimerScheduler` | Idle check, maintenance, and flush timers |

## Domain module (`_shared/domain/`)

No domain spec directly — the keylogger implements the on-disk schema described in `_shared/data/KEYLOGGER_SPEC.md`. The `kc_bridge` sub-module exposes keycode translation consumed by `karabiner`.

## Public API

| Function | Description |
|---|---|
| `M.init(state)` | Initialize with the shared core state table |
| `M.start()` | Arm the eventtap and start all maintenance timers |
| `M.stop()` | Disarm the eventtap and flush pending buffers |
| `M.mark_synthetic()` | Signal that the next N keystrokes are expander output (not human) |
| `M.flush()` | Force an immediate flush of the in-memory buffer to disk |

## Init pattern

```lua
local Keylogger = require("modules.keylogger")
Keylogger.init(shared_state)
Keylogger.start()
```

The module differentiates synthetic (expander-injected) from human keystrokes automatically via inter-key delay heuristics (`SYNTH_MATCH_DELAY_MS`). The `kc_bridge` sub-module must be initialized before `karabiner` calls into it.
