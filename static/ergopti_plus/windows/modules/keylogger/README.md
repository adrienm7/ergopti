# keylogger (AHK)

## Purpose

Windows port of the Hammerspoon keylogger. Intercepts every keystroke via the AHK keyboard hook, persists events to an append-only `data.sql` file and a hot-path `today.log` JSONL file. Mirrors the on-disk schema from `_shared/data/KEYLOGGER_SPEC.md` byte-for-byte so a Mac and a PC sharing a cloud folder accumulate data naturally.

Rich aggregation (n-grams, bursts, ergonomic streaks) is not yet ported; the Mac-side Hammerspoon walker handles those tables for any synced Windows device.

## Ports used (`_shared/ports/`)

| Port | Usage |
|---|---|
| `KeyboardHook` | Raw keystroke interception via AHK's built-in hook |
| `FileSystem` | Writing `today.log`, `data.sql`, `state.json`, and `device.json` |
| `WindowInfo` | Active app and window title for app-switch / window-switch events |
| `TimerScheduler` | Ingest tick, idle detection, and flush scheduling |

## Domain module (`_shared/domain/`)

No direct domain spec. Implements the schema defined in `_shared/data/KEYLOGGER_SPEC.md`. Per-device isolation uses a UUID derived from the Windows `MachineGuid` registry key.

## Public API

| Function | Description |
|---|---|
| `KL_Init(config_dir)` | Initialize the keylogger for the given config root directory |
| `KL_Start()` | Arm the keystroke hook and start the ingest timer |
| `KL_Stop()` | Disarm the hook and flush all pending buffers |
| `KL_AppendLog(event_map)` | Append a single event to the in-memory buffer (hot path) |
| `KL_MarkSynthetic()` | Signal that upcoming keystrokes are expander output, not human |

## Init pattern

```ahk
KL_Init(A_AppData "\\ergopti_plus")
KL_Start()
```

The hot path (`KL_AppendLog`) uses a cached `FileObject` handle and a pre-encoded device-ID literal to keep per-keystroke overhead under one allocation. `state.json` is updated on every successful ingest tick so replay after a crash is idempotent.
