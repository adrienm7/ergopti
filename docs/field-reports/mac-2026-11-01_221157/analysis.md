# Field log analysis

Logs: ErgoptiPlus_2026-11-01.log (994 lines, 992 records, 0 continuation lines); span 2026-11-01 00:07:31:218 to 2026-11-01 22:12:03:645.
Previous report compared: mac-2026-10-31_173736.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 12 | slow | main_thread.hold over its 250 ms budget | 4 | max 1537 ms at 2026-11-01 22:12:02:781 |
| 2 | 5 | error | [keystats.log_manager] Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress. | 1 | 2026-11-01 22:11:59:811 [ERROR] [keystats.log_manager] Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress. |
| 3 | 3 | slow | healthcheck.sync over its 5 ms budget | 1 | max 26.4 ms at 2026-11-01 22:12:00:499 |
| 4 | 3 | slow | keystats.ingest over its 500 ms budget | 1 | max 1047 ms at 2026-11-01 20:27:03:569 |
| 5 | 3 | slow | menu.rebuild over its 250 ms budget | 1 | max 1371 ms at 2026-11-01 22:12:02:773 |
| 6 | 1 | warning | [file_watchers] Git operation in '<*>' still owns the reload fence after <*> checks; reload remains pending. | 1 | 2026-11-01 22:11:53:001 [WARNING] [file_watchers] Git operation in '~/perso/ergopti/static/ergopti_plus/macos/' still owns the reload fence after 120 checks; reload remains pending. |
| 7 | 1 | warning | [keymap.utils] Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-11-01 22:10:33:858 [WARNING] [keymap.utils] Slow ignored-window probe 502 ms (watchers=0 focused_window=502 ms). |
| 8 | 1 | warning | [menu_watchers] Git operation still owns the reload fence after <*> checks on '<*>'; reload remains pending. | 1 | 2026-11-01 22:11:53:003 [WARNING] [menu_watchers] Git operation still owns the reload fence after 120 checks on '~/perso/ergopti/static/ergopti_plus/macos/'; reload remains pending. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 1 pass, ❌ 0 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

1 error group(s), 7 warning group(s); 8 occurrence(s); 6 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | keystats.log_manager | Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress. | 1 | 2026-11-01 22:11:59:811 | 2026-11-01 22:11:59:811 | new |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; append: lock=<*> journal=<*> prepare=<*> publish=<*> write=<*> clear=<*> settle=<*> release=<*> ms; metadata_commands=<*> in <*> ms; entries=<*> statements=<*>). | 1 | 2026-11-01 20:27:03:569 | 2026-11-01 20:27:03:569 | new |
| WARNING | runtime | An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-11-01 20:27:03:569 | 2026-11-01 20:27:03:569 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-11-01 22:10:33:858 | 2026-11-01 22:10:33:858 |  |
| WARNING | file_watchers | Git operation in '<*>' still owns the reload fence after <*> checks; reload remains pending. | 1 | 2026-11-01 22:11:53:001 | 2026-11-01 22:11:53:001 | new |
| WARNING | menu_watchers | Git operation still owns the reload fence after <*> checks on '<*>'; reload remains pending. | 1 | 2026-11-01 22:11:53:003 | 2026-11-01 22:11:53:003 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 1 | 2026-11-01 22:12:02:774 | 2026-11-01 22:12:02:774 |  |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-01 22:12:02:781 | 2026-11-01 22:12:02:781 | new |

<details><summary>One example line per group</summary>

```
2026-11-01 22:11:59:811 [ERROR] [keystats.log_manager] Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress.
```
```
2026-11-01 20:27:03:569 [WARNING] [keystats.log_manager] Slow ingest tick 1047 ms (drain=0 foreign=0 outbox=83 read=21 build=0 apply=119 commit=24 append=797 notify=0 ms; append: lock=1 journal=19 prepare=0 publish=324 write=16 clear=42 settle=391 release=0 ms; metadata_commands=0 in 0 ms; entries=…
```
```
2026-11-01 20:27:03:569 [WARNING] [runtime] An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2123) held the main thread for 1047 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 52->53 MB.
```
```
2026-11-01 22:10:33:858 [WARNING] [keymap.utils] Slow ignored-window probe 502 ms (watchers=0 focused_window=502 ms).
```
```
2026-11-01 22:11:53:001 [WARNING] [file_watchers] Git operation in '~/perso/ergopti/static/ergopti_plus/macos/' still owns the reload fence after 120 checks; reload remains pending.
```
```
2026-11-01 22:11:53:003 [WARNING] [menu_watchers] Git operation still owns the reload fence after 120 checks on '~/perso/ergopti/static/ergopti_plus/macos/'; reload remains pending.
```
```
2026-11-01 22:12:02:774 [WARNING] [menu] Over budget: menu.rebuild took 1371 ms (budget 250 ms).
```
```
2026-11-01 22:12:02:781 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1537 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1371.2 ms, menu_i…
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 1 | 1722 | 1722 | 1722 | 1722 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 1 | 1267 | 1267 | 1267 | 1267 | no budget declared | — |
| boot.stage:Config-dependent module requires | 1 | 390 | 390 | 390 | 390 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 1 | 207 | 207 | 207 | 207 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 1 | 191 | 191 | 191 | 191 | no budget declared | — |
| boot.stage:Config schema migration | 1 | 129 | 129 | 129 | 129 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 1 | 110 | 110 | 110 | 110 | no budget declared | — |
| boot.stage:UI: karabiner.init | 1 | 95.8 | 95.8 | 95.8 | 95.8 | no budget declared | — |
| boot.stage:Keymap engine started | 1 | 30.9 | 30.9 | 30.9 | 30.9 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 1 | 30.2 | 30.2 | 30.2 | 30.2 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 1 | 13.8 | 13.8 | 13.8 | 13.8 | no budget declared | — |
| boot.stage:File watchers armed | 1 | 9.2 | 9.2 | 9.2 | 9.2 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 1 | 7.3 | 7.3 | 7.3 | 7.3 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 1 | 6.9 | 6.9 | 6.9 | 6.9 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 1 | 5.4 | 5.4 | 5.4 | 5.4 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 1 | 2.8 | 2.8 | 2.8 | 2.8 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 1 | 2.7 | 2.7 | 2.7 | 2.7 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 1 | 2.6 | 2.6 | 2.6 | 2.6 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 1 | 2 | 2 | 2 | 2 | no budget declared | — |
| boot.stage:Accessibility permission | 1 | 0.7 | 0.7 | 0.7 | 0.7 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 1 | 0.5 | 0.5 | 0.5 | 0.5 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 1 | 0.5 | 0.5 | 0.5 | 0.5 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 1 | 0.4 | 0.4 | 0.4 | 0.4 | no budget declared | — |
| boot.stage:UI: menu ready | 1 | 0.2 | 0.2 | 0.2 | 0.2 | no budget declared | — |

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 1 | 2424 | 2424 | 2424 | 2424 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 1 | 1944 | 1944 | 1944 | 1944 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 1 | 1371 | 1371 | 1371 | 1371 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |
| menu.submenu:shortcuts | 1 | 1111 | 1111 | 1111 | 1111 | no budget declared | — |
| menu.submenu:keyboard_layout | 1 | 72.1 | 72.1 | 72.1 | 72.1 | no budget declared | — |
| menu.submenu:gestures | 1 | 58.9 | 58.9 | 58.9 | 58.9 | no budget declared | — |
| menu.submenu:llm | 1 | 34.7 | 34.7 | 34.7 | 34.7 | no budget declared | — |
| menu.submenu:hotstrings | 1 | 32.9 | 32.9 | 32.9 | 32.9 | no budget declared | — |
| menu.app_exclusions | 1 | 0.3 | 0.3 | 0.3 | 0.3 | no budget declared | — |

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 4 | 502 | 1537 | 845 | 1537 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (4) |

Worst occurrences:

- main_thread.hold: 1537 ms at 2026-11-01 22:12:02:781 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801), 1047 ms at 2026-11-01 20:27:03:569 (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2123), 502 ms at 2026-11-01 22:10:33:858 (...gopti/static/ergopti_plus/macos/modules/keymap/utils.lua:1567)

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 1 | 1047 | 1047 | 1047 | 1047 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (1) |
| healthcheck.sync | 1 | 26.4 | 26.4 | 26.4 | 26.4 | 5 ms (stated in the log line) | ❌ over (1) |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.defaults | 2850 | — | — | 22.38 | 1458 | no budget declared | — |

### Counters

- counter:runtime.timer_hold_over_1000ms: 1

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 1 | 2026-11-01 22:11:58:018 | 2026-11-01 22:11:58:018 |
| stop | 1 | 2026-11-01 22:11:57:327 | 2026-11-01 22:11:57:327 |
| reload | 1 | 2026-11-01 22:11:56:839 | 2026-11-01 22:11:56:839 |
| sleep_wake | 1 | 2026-11-01 22:10:33:349 | 2026-11-01 22:10:33:349 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-01 22:11:58:018 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-01 22:11:57:327 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-01 22:11:56:839 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
```

**sleep_wake**

```
2026-11-01 22:10:33:349 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

</details>
