# Field log analysis

Logs: ErgoptiPlus_2026-11-01.log (2823 lines, 2795 records, 22 continuation lines); span 2026-11-01 00:07:31:218 to 2026-11-01 23:38:26:400.
Previous report compared: mac-2026-11-01_221157.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 39 | slow | main_thread.hold over its 250 ms budget | 13 | max 1814 ms at 2026-11-01 23:29:28:304 |
| 2 | 12 | slow | menu.rebuild over its 250 ms budget | 4 | max 1371 ms at 2026-11-01 22:12:02:773 |
| 3 | 6 | slow | healthcheck.sync over its 5 ms budget | 2 | max 35.1 ms at 2026-11-01 23:30:46:416 |
| 4 | 5 | error | [keystats.log_manager] Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress. | 1 | 2026-11-01 22:11:59:811 [ERROR] [keystats.log_manager] Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress. |
| 5 | 5 | error | [menu_llm.ollama] The Ollama pull of granite4:<*>m-h failed (code <*>): OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-11-01 23:34:36:085 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed (code 1): OLLAMA_PULL_OUTCOME error_row. |
| 6 | 3 | slow | keystats.ingest over its 500 ms budget | 1 | max 1047 ms at 2026-11-01 20:27:03:569 |
| 7 | 2 | warning | [keystats.log_manager] Typing ids restart at ledger byte <*> (id <*> after rollover bound <*>): rebuilding without day-boundary context resets. | 2 | 2026-11-01 23:30:27:823 [WARNING] [keystats.log_manager] Typing ids restart at ledger byte 68020656 (id 87 after rollover bound 174722): rebuilding without day-boundary context resets. |
| 8 | 1 | warning | [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-01 23:29:30:772 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. |
| 9 | 1 | warning | [file_watchers] Git operation in '<*>' still owns the reload fence after <*> checks; reload remains pending. | 1 | 2026-11-01 22:11:53:001 [WARNING] [file_watchers] Git operation in '~/perso/ergopti/static/ergopti_plus/macos/' still owns the reload fence after 120 checks; reload remains pending. |
| 10 | 1 | warning | [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-01 23:34:57:427 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-11-01 23:29:30:604)
- ✅ owned_runtime: pass (2026-11-01 23:29:30:717)
- ✅ owned_start: pass (2026-11-01 23:29:30:733)
- ✅ network: pass (2026-11-01 23:29:33:246)
- ✅ toolchain: pass (2026-11-01 23:29:34:495)
- ✅ login_items: pass (2026-11-01 23:29:54:591)
- ✅ composer: pass (2026-11-01 23:29:55:877)
- ✅ boot_cost: pass (2026-11-01 23:29:55:892)
- ❌ idle_cost: fail (2026-11-01 23:30:25:958)
- ✅ layout_rows: pass (2026-11-01 23:30:29:231)
- ✅ permissions: pass (2026-11-01 23:30:29:402)
- ✅ event_taps: pass (2026-11-01 23:30:30:137)
- ✅ input_sources: pass (2026-11-01 23:30:30:271)
- ❌ storage: fail (2026-11-01 23:30:32:902)
- ✅ launcher_roles: pass (2026-11-01 23:30:32:997)
- ✅ network_hosts: pass (2026-11-01 23:30:35:531)
- ✅ ollama_blob_host: pass (2026-11-01 23:30:36:808)
- ✅ typing_selftest: pass (2026-11-01 23:30:42:833)
- ✅ capslock_chord: pass (2026-11-01 23:30:42:847)
- ✅ gesture_frames: pass (2026-11-01 23:30:42:852)
- ✅ hotstring_roundtrip: pass (2026-11-01 23:30:44:975)
- ✅ prediction_tooltip: pass (2026-11-01 23:30:44:992)
- ✅ menu_build: pass (2026-11-01 23:30:46:337)
- ✅ pac_fallback: pass (2026-11-01 23:34:45:551)
- ✅ ai_local: pass (2026-11-01 23:34:50:334)
- ✅ slow_lines: pass (2026-11-01 23:34:50:405)
- ✅ fifo_safety: pass (2026-11-01 23:34:51:950)
- ✅ local_servers: pass (2026-11-01 23:34:52:470)
- ✅ app_health: pass (2026-11-01 23:34:54:376)
- ✅ tap_hold_thresholds: pass (2026-11-01 23:34:54:534)
- ✅ apple_shortcuts: pass (2026-11-01 23:34:54:611)
- ✅ owned_pause: pass (2026-11-01 23:34:54:617)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 31 pass, ❌ 2 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

2 error group(s), 17 warning group(s); 27 occurrence(s); 11 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | keystats.log_manager | Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress. | 1 | 2026-11-01 22:11:59:811 | 2026-11-01 22:11:59:811 |  |
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h failed (code <*>): OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-11-01 23:34:36:085 | 2026-11-01 23:34:36:085 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 6 | 2026-11-01 22:12:02:774 | 2026-11-01 23:38:24:916 |  |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 3 | 2026-11-01 22:12:02:781 | 2026-11-01 23:35:01:215 |  |
| WARNING | keystats.log_manager | Typing ids restart at ledger byte <*> (id <*> after rollover bound <*>): rebuilding without day-boundary context resets. | 2 | 2026-11-01 23:30:27:823 | 2026-11-01 23:36:02:839 | new |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; append: lock=<*> journal=<*> prepare=<*> publish=<*> write=<*> clear=<*> settle=<*> release=<*> ms; metadata_commands=<*> in <*> ms; entries=<*> statements=<*>). | 1 | 2026-11-01 20:27:03:569 | 2026-11-01 20:27:03:569 |  |
| WARNING | runtime | An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-11-01 20:27:03:569 | 2026-11-01 20:27:03:569 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-11-01 22:10:33:858 | 2026-11-01 22:10:33:858 |  |
| WARNING | file_watchers | Git operation in '<*>' still owns the reload fence after <*> checks; reload remains pending. | 1 | 2026-11-01 22:11:53:001 | 2026-11-01 22:11:53:001 |  |
| WARNING | menu_watchers | Git operation still owns the reload fence after <*> checks on '<*>'; reload remains pending. | 1 | 2026-11-01 22:11:53:003 | 2026-11-01 22:11:53:003 |  |
| WARNING | runtime | An hs.timer.new callback (...ergopti/static/ergopti_plus/macos/ui/menu/menu_state.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: shell.ioreg=<*> ms. Lua heap <*>-><*> MB. | 1 | 2026-11-01 23:29:28:304 | 2026-11-01 23:29:28:304 | new |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-01 23:29:30:772 | 2026-11-01 23:29:30:772 | new |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-01 23:30:46:345 | 2026-11-01 23:30:46:345 | new |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 1 | 2026-11-01 23:30:46:691 | 2026-11-01 23:30:46:691 | new |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: cancelled. | 1 | 2026-11-01 23:34:55:666 | 2026-11-01 23:34:55:666 | new |
| WARNING | keystats.log_manager | Aggregate cache recovery interrupted after <*> slice(s); it restarts at the next start. | 1 | 2026-11-01 23:34:55:693 | 2026-11-01 23:34:55:693 | new |
| WARNING | keymap.utils | Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-01 23:34:57:427 | 2026-11-01 23:34:57:427 | new |
| WARNING | keymap | Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 1 | 2026-11-01 23:34:57:427 | 2026-11-01 23:34:57:427 | new |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 1 | 2026-11-01 23:38:23:229 | 2026-11-01 23:38:23:229 | new |

<details><summary>One example line per group</summary>

```
2026-11-01 22:11:59:811 [ERROR] [keystats.log_manager] Cannot keep the metrics cache before its rebuild: cannot VACUUM - SQL statements in progress.
```
```
2026-11-01 23:34:36:085 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed (code 1): OLLAMA_PULL_OUTCOME error_row.
```
```
2026-11-01 22:12:02:774 [WARNING] [menu] Over budget: menu.rebuild took 1371 ms (budget 250 ms).
```
```
2026-11-01 22:12:02:781 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1537 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1371.2 ms, menu_i…
```
```
2026-11-01 23:30:27:823 [WARNING] [keystats.log_manager] Typing ids restart at ledger byte 68020656 (id 87 after rollover bound 174722): rebuilding without day-boundary context resets.
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
2026-11-01 23:29:28:304 [WARNING] [runtime] An hs.timer.new callback (...ergopti/static/ergopti_plus/macos/ui/menu/menu_state.lua:541) held the main thread for 1814 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: shell.ioreg=69.9 ms. Lua heap 3…
```
```
2026-11-01 23:29:30:772 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-01 23:30:46:345 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1348 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1305.7 ms, menu_it…
```
```
2026-11-01 23:30:46:691 [WARNING] [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=78): refused: RuntimeRefusal at managed_ollama_hint.py:39 candidate
```
```
2026-11-01 23:34:55:666 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: cancelled.
```
```
2026-11-01 23:34:55:693 [WARNING] [keystats.log_manager] Aggregate cache recovery interrupted after 10315 slice(s); it restarts at the next start.
```
```
2026-11-01 23:34:57:427 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed.
```
```
2026-11-01 23:34:57:427 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false.
```
```
2026-11-01 23:38:23:229 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1519 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1473.8 ms, me…
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 3 | 1722 | 1823 | 1726 | 1823 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 3 | 1219 | 1267 | 1232 | 1267 | no budget declared | — |
| boot.stage:Config-dependent module requires | 3 | 411 | 468 | 423 | 468 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 3 | 204 | 207 | 200 | 207 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 3 | 188 | 191 | 188 | 191 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 3 | 170 | 173 | 151 | 173 | no budget declared | — |
| boot.stage:Config schema migration | 3 | 35.7 | 129 | 64.67 | 129 | no budget declared | — |
| boot.stage:UI: karabiner.init | 3 | 85.7 | 95.8 | 85.43 | 95.8 | no budget declared | — |
| boot.stage:Keymap engine started | 3 | 58.3 | 66.1 | 51.77 | 66.1 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 3 | 30.2 | 33.8 | 30.43 | 33.8 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 3 | 9.9 | 13.8 | 10.57 | 13.8 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 3 | 9.7 | 11 | 9.33 | 11 | no budget declared | — |
| boot.stage:File watchers armed | 3 | 8.9 | 9.2 | 8.93 | 9.2 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 3 | 5.4 | 8.9 | 6.43 | 8.9 | no budget declared | — |
| boot.stage:Accessibility permission | 3 | 0.8 | 7.4 | 2.97 | 7.4 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 3 | 6.9 | 7.1 | 6.6 | 7.1 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 3 | 2.8 | 3.2 | 2.7 | 3.2 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 3 | 2 | 2.7 | 2.2 | 2.7 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 3 | 2 | 2.6 | 2.03 | 2.6 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 3 | 2.4 | 2.6 | 2.47 | 2.6 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 3 | 0.7 | 0.7 | 0.63 | 0.7 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 3 | 0.4 | 0.5 | 0.4 | 0.5 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 3 | 0.5 | 0.5 | 0.5 | 0.5 | no budget declared | — |
| boot.stage:UI: menu ready | 3 | 0.3 | 0.3 | 0.27 | 0.3 | no budget declared | — |

Worst occurrences:

- boot.total: 1823 ms at 2026-11-01 23:34:57:713, 1722 ms at 2026-11-01 22:11:59:263, 1634 ms at 2026-11-01 23:29:26:133
- boot.cpu: 1267 ms at 2026-11-01 22:11:59:263, 1219 ms at 2026-11-01 23:34:57:714, 1210 ms at 2026-11-01 23:29:26:134
- boot.stage:Config-dependent module requires: 468 ms at 2026-11-01 23:34:56:867, 411 ms at 2026-11-01 23:29:25:354, 390 ms at 2026-11-01 22:11:58:424
- boot.stage:Hotstring groups registered (personal + dynamic + common): 207 ms at 2026-11-01 22:11:58:925, 204 ms at 2026-11-01 23:34:57:335, 188 ms at 2026-11-01 23:29:25:793
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 191 ms at 2026-11-01 22:11:59:250, 188 ms at 2026-11-01 23:29:26:121, 185 ms at 2026-11-01 23:34:57:701
- boot.stage:Shortcuts pre-start: 173 ms at 2026-11-01 23:34:57:085, 170 ms at 2026-11-01 23:29:25:567, 110 ms at 2026-11-01 22:11:58:672
- boot.stage:Config schema migration: 129 ms at 2026-11-01 22:11:58:554, 35.7 ms at 2026-11-01 23:34:56:903, 29 ms at 2026-11-01 23:29:25:384
- boot.stage:UI: karabiner.init: 95.8 ms at 2026-11-01 22:11:59:058, 85.7 ms at 2026-11-01 23:34:57:515, 74.8 ms at 2026-11-01 23:29:25:932
- boot.stage:Keymap engine started: 66.1 ms at 2026-11-01 23:34:57:428, 58.3 ms at 2026-11-01 23:29:25:857, 30.9 ms at 2026-11-01 22:11:58:962
- boot.stage:TOML discovery + ordering: 33.8 ms at 2026-11-01 23:34:57:131, 30.2 ms at 2026-11-01 22:11:58:718, 27.3 ms at 2026-11-01 23:29:25:605
- boot.stage:MLX server cleanup started asynchronously: 13.8 ms at 2026-11-01 22:11:58:687, 9.9 ms at 2026-11-01 23:34:57:096, 8 ms at 2026-11-01 23:29:25:576
- boot.stage:Path: native asynchronous logger transport committed: 11 ms at 2026-11-01 23:29:24:938, 9.7 ms at 2026-11-01 23:34:56:391, 7.3 ms at 2026-11-01 22:11:58:027

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 2 | 2424 | 2762 | 2593 | 2762 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 2 | 1944 | 2154 | 2049 | 2154 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 2762 ms at 2026-11-01 23:34:54:951, 2424 ms at 2026-11-01 22:11:56:839
- reload.total: 2154 ms at 2026-11-01 23:34:57:714, 1944 ms at 2026-11-01 22:11:59:263

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 4 | 1272 | 1371 | 1298 | 1371 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (4) |
| phase:menu.rebuild | 2 | — | — | 1275 | 1306 | no budget declared | — |
| menu.submenu:shortcuts | 4 | 1039 | 1111 | 1052 | 1111 | no budget declared | — |
| phase:menu_item.shortcuts | 2 | — | — | 1028 | 1052 | no budget declared | — |
| menu.submenu:keyboard_layout | 4 | 63.2 | 106 | 75.1 | 106 | no budget declared | — |
| phase:menu_item.keyboard_layout | 2 | — | — | 82.54 | 106 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 2 | — | — | 58.44 | 59.95 | no budget declared | — |
| menu.submenu:gestures | 4 | 50.5 | 58.9 | 53.42 | 58.9 | no budget declared | — |
| phase:menu_item.gestures | 2 | — | — | 52.16 | 56.34 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 2 | — | — | 22.83 | 45 | no budget declared | — |
| menu.submenu:llm | 4 | 28.2 | 34.7 | 30.9 | 34.7 | no budget declared | — |
| phase:menu_item.llm | 2 | — | — | 30.35 | 32.98 | no budget declared | — |
| menu.submenu:hotstrings | 3 | 28.5 | 32.9 | 29.9 | 32.9 | no budget declared | — |
| menu.submenu:metrics | 1 | 32.9 | 32.9 | 32.9 | 32.9 | no budget declared | — |
| phase:menu_item.metrics | 2 | — | — | 19.95 | 32.88 | no budget declared | — |
| phase:menu_keyboard_layout.magic_key | 2 | — | — | 31.71 | 32.53 | no budget declared | — |
| phase:menu_item.hotstrings | 2 | — | — | 27.41 | 28.28 | no budget declared | — |
| menu.app_exclusions | 4 | 0.3 | 19.6 | 5.38 | 19.6 | no budget declared | — |
| phase:menu_item.about | 2 | — | — | 12.04 | 18.31 | no budget declared | — |
| phase:menu_keyboard_layout.number_row | 2 | — | — | 11.45 | 11.83 | no budget declared | — |
| phase:menu_item.debug | 2 | — | — | 6.12 | 9.11 | no budget declared | — |
| phase:menu_item.configuration | 2 | — | — | 2.59 | 3.26 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 2 | — | — | 0.78 | 0.91 | no budget declared | — |
| phase:menu_item.tap_holds | 2 | — | — | 0.81 | 0.86 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 2 | — | — | 0.2 | 0.23 | no budget declared | — |
| phase:menu_item.apps | 2 | — | — | 0.17 | 0.18 | no budget declared | — |
| phase:menu_item.language | 2 | — | — | 0.04 | 0.04 | no budget declared | — |
| phase:menu_item.reload | 2 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.quit | 2 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 1371 ms at 2026-11-01 22:12:02:773, 1306 ms at 2026-11-01 23:30:46:337, 1272 ms at 2026-11-01 23:35:01:207
- menu.submenu:shortcuts: 1111 ms at 2026-11-01 22:12:02:773, 1052 ms at 2026-11-01 23:30:46:337, 1039 ms at 2026-11-01 23:35:01:207
- menu.submenu:keyboard_layout: 106 ms at 2026-11-01 23:30:46:337, 72.1 ms at 2026-11-01 22:12:02:773, 63.2 ms at 2026-11-01 23:35:01:207
- menu.submenu:gestures: 58.9 ms at 2026-11-01 22:12:02:773, 56.3 ms at 2026-11-01 23:30:46:337, 50.5 ms at 2026-11-01 23:35:01:207
- menu.submenu:llm: 34.7 ms at 2026-11-01 22:12:02:773, 33 ms at 2026-11-01 23:30:46:337, 28.2 ms at 2026-11-01 23:35:01:207
- menu.submenu:hotstrings: 32.9 ms at 2026-11-01 22:12:02:773, 28.5 ms at 2026-11-01 23:35:01:207, 28.3 ms at 2026-11-01 23:30:46:337
- menu.app_exclusions: 19.6 ms at 2026-11-01 23:29:29:794, 1.3 ms at 2026-11-01 23:30:46:254, 0.3 ms at 2026-11-01 22:12:02:670

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 13 | 1047 | 1814 | 941 | 1814 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (13) |

Worst occurrences:

- main_thread.hold: 1814 ms at 2026-11-01 23:29:28:304 (...ergopti/static/ergopti_plus/macos/ui/menu/menu_state.lua:541), 1537 ms at 2026-11-01 22:12:02:781 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801), 1519 ms at 2026-11-01 23:38:23:229 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746)

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 1 | 1047 | 1047 | 1047 | 1047 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (1) |
| healthcheck.sync | 2 | 26.4 | 35.1 | 30.75 | 35.1 | 5 ms (stated in the log line) | ❌ over (2) |

Worst occurrences:

- healthcheck.sync: 35.1 ms at 2026-11-01 23:30:46:416, 26.4 ms at 2026-11-01 22:12:00:499

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 1 | — | — | 20010 | 20010 | no budget declared | — |
| phase:process.ErgoptiPlus | 16 | — | — | 482 | 3749 | no budget declared | — |
| phase:process.python3 | 19 | — | — | 397 | 2518 | no budget declared | — |
| phase:process.defaults | 2875 | — | — | 23.62 | 1781 | no budget declared | — |
| phase:process.spctl | 1 | — | — | 606 | 606 | no budget declared | — |
| phase:boot.stage | 24 | — | — | 67.7 | 417 | no budget declared | — |
| phase:boot.requires | 16 | — | — | 60.65 | 413 | no budget declared | — |
| phase:boot.stage_cpu | 24 | — | — | 50.11 | 349 | no budget declared | — |
| phase:process.sqlite3 | 2 | — | — | 302 | 317 | no budget declared | — |
| phase:karabiner.deploy | 3 | — | — | 185 | 255 | no budget declared | — |
| phase:process.codesign | 3 | — | — | 83.07 | 151 | no budget declared | — |
| phase:karabiner.merge | 3 | — | — | 147 | 150 | no budget declared | — |
| phase:process.brew | 1 | — | — | 134 | 134 | no budget declared | — |
| phase:karabiner.write | 1 | — | — | 90.16 | 90.16 | no budget declared | — |
| phase:shell.ls | 18 | — | — | 44.59 | 84.13 | no budget declared | — |
| phase:shell.other | 1 | — | — | 79.45 | 79.45 | no budget declared | — |
| phase:shell.sw_vers | 1 | — | — | 72.77 | 72.77 | no budget declared | — |
| phase:shell.ioreg | 1 | — | — | 69.94 | 69.94 | no budget declared | — |
| phase:shell.systemextensionsctl | 1 | — | — | 64.18 | 64.18 | no budget declared | — |
| phase:karabiner.layout_actions | 3 | — | — | 36.58 | 56.38 | no budget declared | — |
| phase:process.Application | 1 | — | — | 54.99 | 54.99 | no budget declared | — |
| phase:process.mkdir | 3 | — | — | 33.26 | 50.35 | no budget declared | — |
| phase:shell.mkdir | 3 | — | — | 33.23 | 50.33 | no budget declared | — |
| phase:process.shortcuts | 2 | — | — | 42.63 | 49.55 | no budget declared | — |
| phase:shell.find | 1 | — | — | 33.65 | 33.65 | no budget declared | — |
| phase:process.memory_pressure | 1 | — | — | 33.3 | 33.3 | no budget declared | — |
| phase:karabiner.inputs | 3 | — | — | 27.57 | 29.06 | no budget declared | — |
| phase:process.xmllint | 8 | — | — | 8.7 | 28.81 | no budget declared | — |
| phase:karabiner.build | 3 | — | — | 26.83 | 27.99 | no budget declared | — |
| phase:process.pgrep | 3 | — | — | 19.01 | 23.76 | no budget declared | — |
| phase:process.ps | 2 | — | — | 19.03 | 21.89 | no budget declared | — |
| phase:karabiner.encode | 1 | — | — | 19.87 | 19.87 | no budget declared | — |
| phase:hotstring_load.common_file | 2 | — | — | 12.13 | 18.94 | no budget declared | — |
| phase:process.systemextensionsctl | 1 | — | — | 17.04 | 17.04 | no budget declared | — |
| phase:process.launchctl | 1 | — | — | 10.82 | 10.82 | no budget declared | — |
| phase:process.plutil | 4 | — | — | 6.58 | 10.61 | no budget declared | — |
| phase:process.grep | 2 | — | — | 6.71 | 10.45 | no budget declared | — |
| phase:process.scutil | 1 | — | — | 10.08 | 10.08 | no budget declared | — |
| phase:hotpath.keydown | 18 | — | — | 2.18 | 7.16 | no budget declared | — |
| phase:hotpath.hotstring.match | 15 | — | — | 0.45 | 6.14 | no budget declared | — |
| phase:hotpath.preview.rebuild | 14 | — | — | 1.04 | 4.12 | no budget declared | — |
| phase:preview.total | 17 | — | — | 0.96 | 4.11 | no budget declared | — |
| phase:hotpath.hotstring.expand | 1 | — | — | 4.05 | 4.05 | no budget declared | — |
| phase:toml.parse | 29 | — | — | 1.13 | 3.83 | no budget declared | — |
| phase:process.id | 1 | — | — | 1.88 | 1.88 | no budget declared | — |
| phase:preview.providers | 17 | — | — | 0.46 | 0.65 | no budget declared | — |
| phase:preview.resolve | 17 | — | — | 0.06 | 0.23 | no budget declared | — |

### Counters

- counter:runtime.timer_hold_over_1000ms: 4
- counter:runtime.timer_hold_over_250ms: 130

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 3 | 2026-11-01 22:11:58:018 | 2026-11-01 23:34:56:380 |
| stop | 2 | 2026-11-01 22:11:57:327 | 2026-11-01 23:34:55:566 |
| reload | 2 | 2026-11-01 22:11:56:839 | 2026-11-01 23:34:54:951 |
| sleep_wake | 1 | 2026-11-01 22:10:33:349 | 2026-11-01 22:10:33:349 |
| network_failure | 1 | 2026-11-01 23:29:30:772 | 2026-11-01 23:29:30:772 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-01 22:11:58:018 — ErgoptiPlus session opened =====
===== 2026-11-01 23:29:24:926 — ErgoptiPlus session opened =====
===== 2026-11-01 23:34:56:380 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-01 22:11:57:327 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-01 23:34:55:566 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-01 22:11:56:839 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-11-01 23:34:54:951 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-01 22:10:33:349 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-11-01 23:29:30:772 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

</details>
