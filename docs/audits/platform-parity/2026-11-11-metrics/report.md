# Metrics beyond the WPM widget: Windows, macOS, Linux and shared

Audited source: `f6044e52` (`claude/ergopti-todo-parity-audit`). Date:
November 11, 2026.

The register's next module after gestures. Windows
(`windows/modules/keystats/`, `windows/infra/sqlite3.ahk`) is the read-only
reference; the Linux recorder, device ledger import and rebuild
(`linux/modules/keystats/`), the macOS watchers, log manager and aggregator
(`macos/modules/keystats/`) and the shared collectors
(`_shared/lua/keystats/`, `_shared/lua/sqlite/literal.lua`) were followed from
the raw producer to the SQL row, the device ledger and the day aggregates.
Candidates were replayed through the real Linux recorder and importer under
LuaJIT and the real macOS watchers and rebuild under Lua 5.4 (the rebuild over
a real SQLite through `rebuild_sqlite_bridge.py`). No AHK, Hammerspoon or
desktop session ran. The 2026-11-04 metrics findings and the TODO items for the
raw telemetry families were not recounted.

## Fixed (macOS, Linux and shared)

| Id                | Sequence                                                                                                 | Windows                                                                                        | Before                                                                                                  | Regression                                        |
| ----------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| KML-001           | A sibling records text with a CR or a NUL (a window title, an AI output)                                 | `SQLite_Q` and the shared escaper write `'l1'\|\|char(13)\|\|'…'`; the reader runs it          | The Linux importer refused the statement and retried the same batch on every tick: the device was stuck | `linux-import-control-bytes`                      |
| KML-002 / KMM-003 | A Windows device's Wi-Fi poll (`network_change` rows) is imported                                        | Its rebuild counts the connectivity and SSID transitions (`keystats_reader_db.ahk` "wifi-day") | Both Lua rebuilds read only `events_system wifi_change`: zero Wi-Fi changes                             | `linux-import-wifi-changes`, `macos-rebuild-wifi` |
| KML-003           | Linux, an app on the disabled list focused, the Internet drops                                           | `KL_AppendLog` refuses every entry while the context is filtered                               | `events_network` stored the transition under the excluded app's name, and the ledger exported it        | `linux-network-excluded-app`                      |
| KMM-002           | macOS, a disabled app, a secure field or a system-auth prompt; a window moves, OBS starts or Wi-Fi drops | Refused, as above                                                                              | Topology checked only the private-window flag; the capture scan and the network watcher checked nothing | `macos-topology-private`, `macos-network-private` |
| KML-004 (part)    | A Linux sibling in New York sleeps at 23:30 local (ts 04:30 UTC the next day)                            | (Windows and macOS stamp local time)                                                           | The Linux rebuild put its system row on the next day                                                    | `linux-import-system-date`                        |

KML-002 and KMM-003: the Windows rule is ported once,
`network_transitions.is_wifi_change`; the macOS rebuild gains a resumable
network stage after the system one.

## Decisions pending (behaviour left unchanged)

- **KMD-1, a Linux sibling's UTC timestamps in the other rebuilds.** Linux
  stamps raw `ts` in UTC (memory `shared-architecture`, purge tombstones),
  Windows and macOS local time. The night-wake test and the hourly slot read
  `ts`'s clock on every rebuild, and the macOS (`aggregator/events.lua`) and
  Windows (`keystats_walker_events.ahk`) rebuilds also take the day from `ts`:
  an imported Linux device's night wakes and hourly heatmap shift by its UTC
  offset. No row carries that offset; a fix needs a recorded offset or local
  `ts` on Linux, a cross-device contract decision.
- **KMD-2, excluded-app scope for telemetry that is not typing.** The fixes
  above follow Windows (refuse the row). Decided by the maintainer on
  2026-11-11: refused on every OS, no neutral label. Verified on dev: Linux
  d379d11a (network; topology and capture already refused, now pinned by
  `linux-topology-excluded-app`), macOS ed0d90e9 (`macos-network-private`,
  `macos-topology-private`); Windows already refuses in `KL_AppendLog`.
  Closed.
- **KMD-3, Linux `awake_ms`.** Sampled unlocked uptime on Linux, keep-awake
  sessions on Windows and macOS (raised by the 2026-11-04 deep review, no TODO
  item). Decided by the maintainer on 2026-11-11: Linux follows Windows and
  macOS. A finished keep-awake session is the day's `awake_ms` and a
  `passive_period` row of kind `awake`; old Linux days are cleared once and
  marked (`meta.linux_awake_ms_definition`, `linux_awake_ms_since`; regressions
  `linux-awake-definition`). No Windows change.

## Refuted

Windows sleep and lock durations at zero (the SQL rebuild owns them); a `wake`
plus `passive_period` double count on import; field drift in the topology,
capture and ROI collectors against `KL_Topo_*`, `KL_AV_ReduceCaptureSample` and
`keystats_trigger_roi.ahk`; the clipboard burst rule, chord set and provenance
invalidation; shared-schema tables refused on import.

## Remaining work

- **macOS:** an imported Linux sibling's system rows take their day from `ts`
  (`aggregator/events.lua`), the KML-004 part fixed on Linux; it rides on
  KMD-1.
- **Windows (report only):** the same for `keystats_walker_events.ahk`, and
  Windows' reader of a Linux ledger stays unverified.
- **Not checked:** whether Windows typed text carries a raw CR for Enter (how
  often KML-001 triggers), the Linux Ctrl+V identity under the remap, a macOS
  VPN answer arriving after a pause starts.
- **Native receiving:** no Hammerspoon, AHK or desktop run.
