# healthcheck (AHK)

## Purpose

The diagnostics window of the Debug menu. It collects a version 2 snapshot
(`_shared/modules/diagnostics/schema.json`) and shows it in the shared page
(`_shared/ui/healthcheck/`) through WebView2. Without WebView2 it shows the
snapshot as plain text in a read-only field.

Collection runs in two phases. Phase A reads registry values, Win32 calls,
memory and small files only, under the schema's 5 ms budget, because the AHK
thread also serves the keyboard hook. Phase B runs the probes (api.github.com
and the local AI backend as curl children harvested by timers, and the
processor load from two samples of the system and process times taken on a
timer), and pushes each answer into the open page. The page can collect again, with or without the
opt-in details.

## Key files

| File          | Description                                                                     |
| ------------- | ------------------------------------------------------------------------------- |
| `init.ahk`    | Index: includes the files below                                                 |
| `core.ahk`    | Session counters, `HealthCheck_Run()` (phase A), the window and its messages    |
| `helpers.ahk` | One synchronous collector per section, and the recent warnings and errors       |
| `probes.ahk`  | The asynchronous probes, each answering once: its result, a timeout or an error |
| `report.ahk`  | The page's actions (copy, save, report, open) and the Debug menu's reports      |
| `actions.ahk` | Validation of the page's messages against the schema's allowlist                |

## Usage

```ahk
HealthCheck_ShowWindow()          ; Debug > Diagnostics
HealthCheck_ReportBug()           ; Debug > Report a bug (opens the preview)
HealthCheck_SuggestFeature()      ; Debug > Suggest a feature
```
