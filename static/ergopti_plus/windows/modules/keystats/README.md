# keystats (AHK)

## Purpose

Windows port of the Hammerspoon keystats. Intercepts every keystroke via the AHK keyboard hook, persists events to an append-only `data.sql` file and a hot-path `today.log` JSONL file. Mirrors the on-disk schema from `_shared/data/KEYSTATS_SPEC.md` byte-for-byte so a Mac and a PC sharing a cloud folder accumulate data naturally.

Rich aggregation (n-grams, bursts, ergonomic streaks) is ported: the walker (`keystats_walker*.ahk`), the n-gram reader (`keystats_reader_ngrams.ahk`) and the ergonomic collector (`keystats_ergonomics.ahk`) fill the same tables as the macOS walker.

## Ports used (`_shared/core/ports/`)

| Port             | Usage                                                             |
| ---------------- | ----------------------------------------------------------------- |
| `KeyboardHook`   | Raw keystroke interception via AHK's built-in hook                |
| `FileSystem`     | Writing `today.log`, `data.sql`, `state.json`, and `device.json`  |
| `WindowInfo`     | Active app and window title for app-switch / window-switch events |
| `TimerScheduler` | Ingest tick, idle detection, and flush scheduling                 |

## Domain module (`_shared/core/domain/`)

No direct domain spec. Implements the schema defined in `_shared/data/KEYSTATS_SPEC.md`. Per-device isolation uses a UUID derived from the Windows `MachineGuid` registry key.

## Public API

| Function                  | Description                                                    |
| ------------------------- | -------------------------------------------------------------- |
| `KL_Init(metrics_dir)`    | Initialize the keystats for the given metrics directory        |
| `KL_Start()`              | Arm the keystroke hook and start the ingest timer              |
| `KL_Stop()`               | Disarm the hook and flush all pending buffers                  |
| `KL_AppendLog(event_map)` | Append a single event to the in-memory buffer (hot path)       |
| `KL_MarkSynthetic()`      | Signal that upcoming keystrokes are expander output, not human |

## Init pattern

```ahk
KL_Init(KL_MetricsDirFor(_ConfigDir))
KL_Start()
```

The hot path (`KL_AppendLog`) uses a cached `FileObject` handle and a pre-encoded device-ID literal to keep per-keystroke overhead under one allocation. `state.json` is updated on every successful ingest tick so replay after a crash is idempotent.

### Window title counters on Windows

The applications dashboard labels `win_titles[title].c` as manual keystrokes.
The reader derives it from the existing typing count projection grouped by each
accepted typing row's device, day, application and title. Synthetic events are
excluded and physical backspaces are included; committed text length and focus
visit counts are different measurements. Empty titles contribute no title row.

The walker separately attributes `ms` to the outgoing application's previous
title when a window interval ends. The existing per-app/day cap ranks titles
using `c + ms`. Both fields keep the canonical producer's privacy decisions;
the reader does not collect new window text or reclassify history from live focus.
