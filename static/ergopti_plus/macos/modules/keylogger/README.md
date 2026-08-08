# keylogger

## Purpose

Low-level event tap daemon that intercepts, timestamps, and stores every human keystroke globally across the operating system. Drives context tracking (app focus, secure-field guard), hardware telemetry (battery, WiFi, mouse distance, system load), and persists everything to an SQLite database and a hot-path JSONL log.

## Ports used (`_shared/core/ports/`)

| Port                  | Usage                                                 |
| --------------------- | ----------------------------------------------------- |
| `KeyboardHook`        | Global keystroke interception                         |
| `WindowInfo`          | Active app and window title for context tracking      |
| `SecureFieldDetector` | AX observer that marks password fields                |
| `FileSystem`          | Writing `today.log` (JSONL) and reading state         |
| `Storage`             | SQLite writes via `sqlite_writer` and `sqlite_reader` |
| `TimerScheduler`      | Idle check, maintenance, and flush timers             |

## Domain module (`_shared/core/domain/`)

No domain spec directly — the keylogger implements the on-disk schema described in `_shared/data/KEYLOGGER_SPEC.md`. The `kc_bridge` sub-module exposes keycode translation consumed by `karabiner`.

## Public API

| Function               | Description                                                                     |
| ---------------------- | ------------------------------------------------------------------------------- |
| `M.start(control)`     | Arm the eventtap and daemons with the runtime pause-state provider               |
| `M.stop()`             | Disarm the eventtap, stop maintenance, and flush pending buffers                 |
| `M.resync_context()`   | Drop transient modifier/application context after an observation gap            |
| `M.notify_synthetic()` | Record a replacement's logical result; the optional privacy flag redacts content |

## Init pattern

```lua
local Keylogger = require("modules.keylogger")
local ScriptControl = require("modules.shortcuts.script_control")
Keylogger.start(ScriptControl)
```

The module classifies synthetic input only through the immutable
`eventSourceUserData` tags issued by `adapters.synthetic_input`; timing,
characters, modifiers, and source PID are not identity. `M.notify_synthetic()`
records logical replacement content but does not arm physical-event heuristics.
The `kc_bridge` sub-module must be initialized before `karabiner` calls into it.
