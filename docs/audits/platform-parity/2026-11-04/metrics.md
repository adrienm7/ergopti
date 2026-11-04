# Metrics, WPM and privacy parity audit

Audit date: 2026-11-04. Scope: production keystats collection, persistence, aggregation, dashboards, WPM and collection privacy under Windows/macOS/Linux. Read AGENTS.md, cross-driver-parity skill, relevant routed memory and existing platform-parity-audit/TODO. No repository files changed. Evidence is source call-chain inspection plus the targeted tests below; no native Windows/macOS desktop or evdev runtime was available.

## Newly confirmed gaps

### 1. Linux lacks the shared append-only metrics ledger and cross-device synchronization

This is a substantial persistence feature gap, not a schema or display difference.

- Linux `static/ergopti_plus/linux/infra/config_paths.lua:216` returns `M.data("metrics.sqlite")`.
- Linux `modules/keystats/keystats.lua:648` selects this path; `:661` identifies its device as `linux-` plus hostname, `:665` registers it and its flush writes this SQLite store.
- Linux `modules/keystats/sqlite_writer.lua:366` explicitly describes why cache migration must preserve the DB: “unlike Windows and macOS there is no ledger”. The header claim at `:14` that cross-device sync works identically is stale.
- Whole production Linux tree search for `by_device|imported_data_sql|data\.sql|foreign.sync|foreign_sync` returns only comments and inherited schema migration columns, no ledger publisher/importer.
- macOS `modules/keystats/export.lua:560` implements `sync_foreign_data_sql`; `:575–585` discovers `by_device/`; `modules/keystats/log_manager.lua:2106` invokes it on the real ingest path and rebuilds derived data.
- Windows `modules/keystats/keystats_reader_ledger_catalog.ahk:32` discovers the `by_device` root and `:53` each `data.sql`; reader DB imports/reconstructs it.

Inventory: “Cross-device metrics ledger and synchronization”: Windows/macOS implemented; Linux absent. TODO: design Linux ledger export/import/replay with per-device durable identity, rather than claiming schema compatibility means synchronization.

### 2. Linux does not count completed passive intervals; sleep measurement is an approximation

- Linux `modules/keystats/system_metrics.lua:235–252` initializes `passive_count=0`; there is no later increment. `:321–389` is the complete sampler.
- macOS `modules/keystats/watchers.lua:556` and `:581` send measured `log_passive_period`; `log_manager.lua:926` emits that event; `aggregator/events.lua:178` counts it.
- Windows `modules/keystats/keystats_system_event_owner.ahk:83` / `:179` queues `passive_period`; `keystats_walker_events.ahk:664–665` counts it.
- Linux `system_metrics.lua:332` defines sleep as any gap over three 30-second sampling periods. `:346–349` credits the entire gap as sleep, so stopping/restarting/stalling the daemon can resemble suspend. This is distinct from OS sleep/wake transitions used on the other drivers.
- Shared dashboard exposes passive count (`_shared/ui/metrics_apps/main.js:972`) and sleep totals.

Inventory: completed passive-period counts unavailable Linux; OS-observed sleep timing partial Linux. TODO: model unknown sampling gaps separately and add supported logind suspend/resume observation, retaining limitations on non-logind desktops.

### 3. Virtual desktop change KPI is currently macOS-only

- macOS `modules/keystats/watchers.lua:661` emits actual `space_change` from its spaces watcher; `aggregator/events.lua:177` increments `space_switches`.
- Linux `modules/keystats/system_metrics.lua:242` always initializes `space_switches=0` and never changes it. Native test `linux/tests/unit/modules/keystats/aggregation/test_system_metrics.lua:419` deliberately asserts zero with a compositor-support explanation.
- Windows `keystats_walker_events.ahk:662` can count `space_change` but no Windows producer emits that action.
- Windows DOES have a different, explicitly heuristic collector: `keystats_window_topology.ahk:336–346` emits `virtual_desktop_switch`; `keystats_sql.ahk:251–252` routes it to `events_window_topo`, not the `events_system` source of this KPI. Therefore do not describe Windows as having no desktop detection at all.
- Shared KPI `metrics_apps/main.js:1017` reads `space_switches` regardless of OS.

Inventory should distinguish actual desktop-change count (macOS), heuristic raw desktop-switch events (Windows), unavailable Linux. TODO: availability-aware KPI and supported compositor collection rather than presenting zero as a measurement.

### 4. Linux pointer metrics have reduced coverage and incompatible distance units

- `linux/modules/keystats/pointer_metrics.lua:11–21` accurately documents omitted tap-to-click (synthesized above evdev) and raw device-unit movement; `:73–80` sums REL_X/REL_Y frames.
- Real collector `linux/modules/keystats/keystats.lua:1170` records tracker deltas; daemon `linux/ergopti_hotstrings.lua:2120` calls it.
- `linux/modules/keystats/keystats.lua:2274` persists those device units as `mouse_distance_px`.
- macOS `modules/keystats/watchers.lua:152–158` measures `hs.mouse.absolutePosition()` differences; `init.lua:833–836` counts post-desktop mouse-down events, including synthesized tap-to-click.
- Windows `modules/keystats/keystats_mouse.ahk:637–645` computes differences of screen cursor positions before calling the pixel-distance accumulator.

Inventory: pointer collection partial Linux; device-unit distance is not comparable with screen-pixel distance. TODO: declare units/capture mode and distinguish unsupported tap-to-click, or add a supported desktop-level source.

### 5. Extra raw metrics collection is Windows-only (separate from shared dashboard features)

Production startup `windows/ErgoptiPlus.ahk:1366–1373` starts topology, AV, network, clipboard and ROI collectors after keystats initialization. SQL dispatcher `windows/modules/keystats/keystats_sql.ahk:251–262` routes their events into dedicated tables. Searching complete macOS/Linux production trees finds no corresponding telemetry collectors, even though both have clipboard/action APIs for unrelated user actions.

The separate feature rows should be:

| Raw collection feature                                                                           | Windows production evidence                                                                                                                                        | macOS                                | Linux                                |
| ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------ | ------------------------------------ |
| Clipboard copy metadata, paste chord events, paste bursts                                        | `keystats_clipboard.ahk:19–39`, actual `KL_Clip_Start()` at boot `:1372`; SQL `:259–260`                                                                           | absent                               | absent                               |
| Internet reachability transition events                                                          | `keystats_network.ahk:260–264`; boot `:1371`; SQL `:257–258`                                                                                                       | absent                               | absent                               |
| VPN adapter transition events                                                                    | `keystats_network.ahk:302`; same boot/SQL                                                                                                                          | absent                               | absent                               |
| Capture/conferencing-process presence start/end (heuristic; NOT proof screen capture is active)  | `keystats_av_state.ahk:234`; boot `:1370`; SQL `:255–256`                                                                                                          | absent                               | absent                               |
| Window resize, move, state and monitor-focus events                                              | `keystats_window_topology.ahk`, boot `:1369`; SQL `:251–252`                                                                                                       | no equivalent raw event family found | no equivalent raw event family found |
| Trigger ROI snapshots, repeated manual-word candidate events, trigger inactivity/halflife events | `keystats_trigger_roi.ahk:193`, `:263`, `:349`; boot `:1373`; `keystats_hotstring_log.ahk:157` calls ROI, `keystats_hook.ahk:602` feeds characters; SQL `:261–262` | absent                               | absent                               |

Do NOT claim these raw tables are visualized in current dashboard: the shared dashboard uses its established aggregate payload, and these extra event families are not thereby product UI features. Existing hotstring savings/dashboard automation counts on other OS are not the richer ROI telemetry family.

System-load sampling is another partial gap: Windows `keystats_sensors.ahk:176` emits native CPU/RAM/battery samples; macOS `watchers.lua:166–200` launches `top` and emits `system_load` with CPU-user and memory values; Linux `system_metrics.lua` samples battery/network/lock/mute only, no CPU/RAM producer. CPU semantics differ (Windows overall utilization, macOS user utilization), and Windows “thermal” is a CPU-load heuristic, not a measured temperature. Inventory must not promise comparable thermal sensors.

## Refutations and shared features verified

- Windows rich ngrams, bursts, sessions and ergonomic aggregation are implemented. Stale `keystats.ahk:27–35` claims otherwise. `keystats_reader_db.ahk:1567` onward reconstructs walker state from raw events, and `keystats_walker*.ahk` performs aggregation; shared aggregation corpus exists. No missing Windows aggregation feature should be filed from that header.
- Windows password UIA is implemented and fails closed: `keystats_password.ahk:481–510` uses cheap Win32 classification followed by scheduled UIA when inconclusive; unknown verdict suppresses collection. The main keystats header's TODO_UIA is stale.
- Linux per-app exclusions, collection pause/session reset, encryption and both dashboards are implemented. Existing audit correctly identifies stale exclusion reason text. No second exclusion gap is justified.
- Floating WPM widget exists all three. Shared constants and characters-per-word gates pass. macOS/Linux bar readout versus Windows floating-only is already tracked.
- All three use shared privacy setting declarations and collection control semantics; targeted gates pass. Runtime privacy coverage still depends on accessible focus identity (AT-SPI/UIA/AX) and available compositor app identity; no blanket runtime guarantee follows from a static pass.
- `night_wake_count` is initialized/transported/displayed but no producer increments it on ANY OS. Linux system_metrics header falsely claims macOS derives it from wake reasons. This is a common inert KPI, not a Linux-only parity gap. Shared UI `metrics_apps/main.js:1023` reads it. TODO: implement deliberately on supported OS or hide/mark unavailable.

## Validation executed

Pass:

- `node tools/test/test-metrics-collection-controls.cjs`
- `node tools/test/test-metrics-privacy-single-source.cjs`
- `node tools/test/test-metrics-manifest-contract.cjs`
- `node tools/test/test-metrics-speed-source-filters.cjs`
- `node tools/test/test-keystats-timings-single-source.cjs`
- `node tools/test/test-metrics-category-ids.cjs` (27 loaded cases)
- `node tools/test/test-wpm-constants-single-source.cjs`
- `node tools/test/test-wpm-chars-per-word-single-source.cjs`

Not green in supplied environment (Node 24.22.1 rather than pinned 22.22.2):

- `node tools/test/test-keystats-query-catalogue.cjs`: 18 native-dialect fixture mismatches. Actual node:sqlite retains text after NUL; fixtures and `cutAtNul` assumption (`:102–106`, assertions `:135–144`) expect truncation. Generated Lua/AHK freshness checks pass. This is not established production parity failure; rerun under pinned Node and distinguish binding-version expectations from driver behavior.
- `node tools/test/test-keystats-write-catalogue.cjs`: one analogous metadata assertion, actual `v\0w` versus expected `v`; remaining write vector/SQL cases pass.
- Lua/LuaJIT/sqlite3 executables unavailable, so native Linux/macOS unit suites were not run; Windows AHK unavailable. No desktop hardware tests performed.

An initial guessed filename `test-wpm-widget-single-source.cjs` did not exist; corrected to the real WPM test names above.

## Reproducible source checks

```sh
rg -n 'by_device|imported_data_sql|data\.sql|foreign.sync|foreign_sync' static/ergopti_plus/linux --glob '!**/tests/**' --glob '!**/_generated/**'
rg -n 'night_wake_count|space_switches|passive_count' static/ergopti_plus/{macos,linux,windows}/modules/keystats
rg -n 'clipboard_copy|paste_burst|internet_up|vpn_connected|screen_recording_start|roi_snapshot|new_trigger_candidate|trigger_halflife' static/ergopti_plus/{macos,linux}/modules/keystats
rg -n 'KL_(Net|Clip|Roi|Topo|AV|Sensors)_Start' static/ergopti_plus/windows/ErgoptiPlus.ahk
```

## Coverage and limits

Compared manifest settings, WPM shared data, shared dashboard KPI consumers, OS collection startup, native privacy admission, pointer measurement, passive/system accounting, SQL event routing, ledger discovery and aggregate ownership. This covers the audited subsystem's discovered functional surfaces; it cannot certify all timing/interoperability behaviors without the native suites and desktops. Automated declaration inventory needs separate rows for telemetry producers and prerequisites: an equal SQL schema or shared HTML is insufficient proof a platform collects a value.
