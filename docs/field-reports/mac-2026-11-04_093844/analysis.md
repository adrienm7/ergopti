# Field log analysis

Logs: ErgoptiPlus_2026-11-04.log (4502 lines, 4159 records, 337 continuation lines); span 2026-11-04 00:10:31:943 to 2026-11-04 09:49:52:354.
Previous report compared: mac-2026-11-03_102716.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 24 | slow | main_thread.hold over its 250 ms budget | 8 | max 1290 ms at 2026-11-04 09:38:23:033 |
| 2 | 9 | slow | hotpath:preview.rebuild over its 5 ms budget | 3 | max 11.78 ms at 2026-11-04 09:48:45:728 |
| 3 | 3 | warning | [keymap.utils] Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 3 | 2026-11-04 09:26:13:427 [WARNING] [keymap.utils] Slow ignored-window probe 501 ms (watchers=0 focused_window=501 ms). |
| 4 | 3 | slow | hotpath:tooltip.show_predictions over its 5 ms budget | 1 | max 16.39 ms at 2026-11-04 09:42:28:190 |
| 5 | 3 | slow | llm.ttft over its 2000 ms budget | 1 | max 3424 ms at 2026-11-04 09:42:28:174 |
| 6 | 2 | warning | [karabiner.lease] Karabiner lease <*> heartbeat <*> had no clean local CLI transport. | 2 | 2026-11-04 01:29:30:258 [WARNING] [karabiner.lease] Karabiner lease 8a6356806b544a8aa4b96945680e0a25 heartbeat 302 had no clean local CLI transport. |
| 7 | 2 | warning | [karabiner.lease] Lease watchdog <*> stderr: lease worker: HEARTBEAT <*> <*> answered HEARTBEAT_FAILED <*> after <*> s (deadline <*> s). | 2 | 2026-11-04 01:29:30:245 [WARNING] [karabiner.lease] Lease watchdog 8a6356806b544a8aa4b96945680e0a25 stderr: lease worker: HEARTBEAT 1 302 answered HEARTBEAT_FAILED 302 after 1.57 s (deadline 2.50 s). |
| 8 | 1 | warning | [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-04 09:41:07:988 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. |
| 9 | 1 | warning | [adapters.hotkey_registrar] bind(): the OS refused '<*>' — nil. | 1 | 2026-11-04 09:49:49:551 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil. |
| 10 | 1 | warning | [key_event_health] A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a rule switch), <*> key-down(s) and <*> key-up(s) seen <*> ms or more late (max <*> ms), <*> late key event(s) passed untouched, <*> key(s) held across a sleep (<*> released after it), <*> Karabiner lease failure(s). | 1 | 2026-11-04 09:48:48:503 [WARNING] [key_event_health] A character key stayed down 3.2 s with no further event: its key-up was lost before the keymap taps; session totals: 64 key-down(s), 63 key-up(s), 0 key-up(s) without key-down, 0 key-down(s) without key-up, 1 key(s) stuck over 3.0 s, 0 character … |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-11-04 09:41:07:869)
- ✅ owned_runtime: pass (2026-11-04 09:41:07:969)
- ✅ owned_start: pass (2026-11-04 09:41:07:972)
- ✅ network: pass (2026-11-04 09:41:09:327)
- ✅ toolchain: pass (2026-11-04 09:41:10:549)
- ✅ login_items: pass (2026-11-04 09:41:30:688)
- ✅ composer: pass (2026-11-04 09:41:31:996)
- ✅ boot_cost: pass (2026-11-04 09:41:32:002)
- ✅ idle_cost: pass (2026-11-04 09:42:02:072)
- ✅ layout_rows: pass (2026-11-04 09:42:05:493)
- ✅ permissions: pass (2026-11-04 09:42:05:651)
- ✅ event_taps: pass (2026-11-04 09:42:06:394)
- ✅ input_sources: pass (2026-11-04 09:42:06:478)
- ✅ storage: pass (2026-11-04 09:42:11:211)
- ✅ launcher_roles: pass (2026-11-04 09:42:11:308)
- ✅ network_hosts: pass (2026-11-04 09:42:13:216)
- ✅ ollama_blob_host: pass (2026-11-04 09:42:17:107)
- ✅ typing_selftest: pass (2026-11-04 09:42:23:115)
- ✅ capslock_chord: pass (2026-11-04 09:42:23:119)
- ✅ gesture_frames: pass (2026-11-04 09:42:23:123)
- ✅ hotstring_roundtrip: pass (2026-11-04 09:42:25:217)
- ❌ prediction_tooltip: fail (2026-11-04 09:42:25:225)
- ✅ menu_build: pass (2026-11-04 09:42:25:426)
- ✅ pac_fallback: pass (2026-11-04 09:46:17:163)
- ✅ ai_local: pass (2026-11-04 09:46:17:267)
- ✅ slow_lines: pass (2026-11-04 09:46:17:311)
- ✅ fifo_safety: pass (2026-11-04 09:46:18:409)
- ✅ local_servers: pass (2026-11-04 09:46:18:576)
- ✅ app_health: pass (2026-11-04 09:46:20:523)
- ❌ tap_hold_thresholds: fail (2026-11-04 09:46:20:691)
- ✅ tap_copy: pass (2026-11-04 09:46:20:699)
- ✅ apple_shortcuts: pass (2026-11-04 09:46:20:742)
- ✅ owned_pause: pass (2026-11-04 09:46:20:745)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 32 pass, ❌ 2 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

0 error group(s), 16 warning group(s); 22 occurrence(s); 12 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 3 | 2026-11-04 09:26:13:427 | 2026-11-04 09:32:01:354 | new |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 3 | 2026-11-04 09:42:23:860 | 2026-11-04 09:48:45:728 |  |
| WARNING | karabiner.lease | Lease watchdog <*> stderr: lease worker: HEARTBEAT <*> <*> answered HEARTBEAT_FAILED <*> after <*> s (deadline <*> s). | 2 | 2026-11-04 01:29:30:245 | 2026-11-04 09:06:26:857 | new |
| WARNING | karabiner.lease | Karabiner lease <*> heartbeat <*> had no clean local CLI transport. | 2 | 2026-11-04 01:29:30:258 | 2026-11-04 09:06:26:888 | new |
| WARNING | keymap.utils | Secure-field focus watcher setup failed: Accessibility application element is unavailable | 1 | 2026-11-04 09:26:25:443 | 2026-11-04 09:26:25:443 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> ms). | 1 | 2026-11-04 09:26:25:443 | 2026-11-04 09:26:25:443 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> secure_field=<*> destination=<*> ms). | 1 | 2026-11-04 09:36:24:859 | 2026-11-04 09:36:24:859 | new |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-11-04 09:38:23:033 | 2026-11-04 09:38:23:033 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-04 09:41:07:988 | 2026-11-04 09:41:07:988 |  |
| WARNING | tooltip_llm | Over budget: prediction.display took <*> ms (budget <*> ms). | 1 | 2026-11-04 09:42:28:174 | 2026-11-04 09:42:28:174 | new |
| WARNING | HotPath | Slow tooltip.show_predictions: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 1 | 2026-11-04 09:42:28:190 | 2026-11-04 09:42:28:190 | new |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: cancelled. | 1 | 2026-11-04 09:46:21:282 | 2026-11-04 09:46:21:282 | new |
| WARNING | key_event_health | A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a ru… | 1 | 2026-11-04 09:48:48:503 | 2026-11-04 09:48:48:503 | new |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 1 | 2026-11-04 09:49:48:550 | 2026-11-04 09:49:48:550 |  |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 1 | 2026-11-04 09:49:49:551 | 2026-11-04 09:49:49:551 | new |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 1 | 2026-11-04 09:49:49:551 | 2026-11-04 09:49:49:551 | new |

<details><summary>One example line per group</summary>

```
2026-11-04 09:26:13:427 [WARNING] [keymap.utils] Slow ignored-window probe 501 ms (watchers=0 focused_window=501 ms).
```
```
2026-11-04 09:42:23:860 [WARNING] [HotPath] Slow preview.rebuild: 8.00 ms own, 8.00 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-04 01:29:30:245 [WARNING] [karabiner.lease] Lease watchdog 8a6356806b544a8aa4b96945680e0a25 stderr: lease worker: HEARTBEAT 1 302 answered HEARTBEAT_FAILED 302 after 1.57 s (deadline 2.50 s).
```
```
2026-11-04 01:29:30:258 [WARNING] [karabiner.lease] Karabiner lease 8a6356806b544a8aa4b96945680e0a25 heartbeat 302 had no clean local CLI transport.
```
```
2026-11-04 09:26:25:443 [WARNING] [keymap.utils] Secure-field focus watcher setup failed: Accessibility application element is unavailable
```
```
2026-11-04 09:26:25:443 [WARNING] [keymap.utils] Slow ignored-window probe 2847 ms (watchers=0 focused_window=12 application=0 app_name=0 title=12 context_watchers=2821 ms).
```
```
2026-11-04 09:36:24:859 [WARNING] [keymap.utils] Slow ignored-window probe 357 ms (watchers=0 focused_window=5 application=0 app_name=0 title=0 context_watchers=0 secure_field=10 destination=340 ms).
```
```
2026-11-04 09:38:23:033 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:376) held the main thread for 1290 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 43->43 MB.
```
```
2026-11-04 09:41:07:988 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-04 09:42:28:174 [WARNING] [tooltip_llm] Over budget: prediction.display took 3424 ms (budget 2000 ms).
```
```
2026-11-04 09:42:28:190 [WARNING] [HotPath] Slow tooltip.show_predictions: 16.39 ms own, 16.39 ms total, parent none (0 similar since the last line).
```
```
2026-11-04 09:46:21:282 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: cancelled.
```
```
2026-11-04 09:48:48:503 [WARNING] [key_event_health] A character key stayed down 3.2 s with no further event: its key-up was lost before the keymap taps; session totals: 64 key-down(s), 63 key-up(s), 0 key-up(s) without key-down, 0 key-down(s) without key-up, 1 key(s) stuck over 3.0 s, 0 character …
```
```
2026-11-04 09:49:48:550 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```
```
2026-11-04 09:49:49:551 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil.
```
```
2026-11-04 09:49:49:551 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 3 | 1340 | 1355 | 1316 | 1355 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 3 | 806 | 835 | 797 | 835 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 3 | 222 | 234 | 224 | 234 | no budget declared | — |
| boot.stage:Config-dependent module requires | 3 | 194 | 200 | 190 | 200 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 3 | 145 | 186 | 159 | 186 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 3 | 161 | 162 | 155 | 162 | no budget declared | — |
| boot.stage:UI: karabiner.init | 3 | 83.8 | 90.1 | 85.07 | 90.1 | no budget declared | — |
| boot.stage:Keymap engine started | 3 | 25.9 | 48.3 | 32.37 | 48.3 | no budget declared | — |
| boot.stage:Config schema migration | 3 | 28.8 | 29.4 | 28.23 | 29.4 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 3 | 16.3 | 18.6 | 16.53 | 18.6 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 3 | 7.7 | 14.4 | 9.47 | 14.4 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 3 | 6.3 | 8.6 | 6.7 | 8.6 | no budget declared | — |
| boot.stage:Accessibility permission | 3 | 0.6 | 7.8 | 2.97 | 7.8 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 3 | 6.9 | 7 | 6.67 | 7 | no budget declared | — |
| boot.stage:File watchers armed | 3 | 6.4 | 7 | 6.1 | 7 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 3 | 2.5 | 3.9 | 2.93 | 3.9 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 3 | 2 | 2.2 | 2.03 | 2.2 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 3 | 1.5 | 1.8 | 1.5 | 1.8 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 3 | 0.9 | 1.3 | 1.03 | 1.3 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 3 | 1 | 1 | 0.9 | 1 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 3 | 0.6 | 0.8 | 0.63 | 0.8 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 3 | 0.3 | 0.8 | 0.43 | 0.8 | no budget declared | — |
| boot.stage:UI: menu ready | 3 | 0.7 | 0.8 | 0.7 | 0.8 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 3 | 0.2 | 0.3 | 0.23 | 0.3 | no budget declared | — |

Worst occurrences:

- boot.total: 1355 ms at 2026-11-04 09:41:05:124, 1340 ms at 2026-11-04 09:38:47:598, 1253 ms at 2026-11-04 09:46:22:741
- boot.cpu: 835 ms at 2026-11-04 09:41:05:124, 806 ms at 2026-11-04 09:38:47:598, 749 ms at 2026-11-04 09:46:22:741
- boot.stage:Hotstring groups registered (personal + dynamic + common): 234 ms at 2026-11-04 09:38:47:284, 222 ms at 2026-11-04 09:41:04:822, 215 ms at 2026-11-04 09:46:22:473
- boot.stage:Config-dependent module requires: 200 ms at 2026-11-04 09:38:46:837, 194 ms at 2026-11-04 09:41:04:374, 177 ms at 2026-11-04 09:46:22:038
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 186 ms at 2026-11-04 09:38:47:586, 145 ms at 2026-11-04 09:41:05:114, 144 ms at 2026-11-04 09:46:22:732
- boot.stage:Shortcuts pre-start: 162 ms at 2026-11-04 09:46:22:231, 161 ms at 2026-11-04 09:41:04:577, 143 ms at 2026-11-04 09:38:47:014
- boot.stage:UI: karabiner.init: 90.1 ms at 2026-11-04 09:41:04:968, 83.8 ms at 2026-11-04 09:46:22:587, 81.3 ms at 2026-11-04 09:38:47:399
- boot.stage:Keymap engine started: 48.3 ms at 2026-11-04 09:41:04:878, 25.9 ms at 2026-11-04 09:38:47:318, 22.9 ms at 2026-11-04 09:46:22:503
- boot.stage:Config schema migration: 29.4 ms at 2026-11-04 09:38:46:867, 28.8 ms at 2026-11-04 09:41:04:403, 26.5 ms at 2026-11-04 09:46:22:065
- boot.stage:TOML discovery + ordering: 18.6 ms at 2026-11-04 09:38:47:049, 16.3 ms at 2026-11-04 09:46:22:258, 14.7 ms at 2026-11-04 09:41:04:600
- boot.stage:MLX server cleanup started asynchronously: 14.4 ms at 2026-11-04 09:38:47:029, 7.7 ms at 2026-11-04 09:46:22:240, 6.3 ms at 2026-11-04 09:41:04:585
- boot.stage:Path: native asynchronous logger transport committed: 8.6 ms at 2026-11-04 09:41:04:177, 6.3 ms at 2026-11-04 09:38:46:632, 5.2 ms at 2026-11-04 09:46:21:857

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 2 | 1981 | 2099 | 2040 | 2099 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 2 | 1511 | 1624 | 1568 | 1624 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 2099 ms at 2026-11-04 09:38:45:499, 1981 ms at 2026-11-04 09:46:20:760
- reload.total: 1624 ms at 2026-11-04 09:38:47:598, 1511 ms at 2026-11-04 09:46:22:741

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 6 | 107 | 204 | 133 | 204 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| phase:menu.rebuild | 5 | — | — | 116 | 162 | no budget declared | — |
| menu.submenu:keyboard_layout | 6 | 13.3 | 128 | 48.13 | 128 | no budget declared | — |
| phase:menu_item.keyboard_layout | 5 | — | — | 30.95 | 79.56 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 5 | — | — | 14.41 | 69.27 | no budget declared | — |
| phase:menu_item.shortcuts | 5 | — | — | 41.05 | 53.44 | no budget declared | — |
| menu.submenu:shortcuts | 6 | 30.7 | 51.1 | 37.85 | 51.1 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 5 | — | — | 15.48 | 38.19 | no budget declared | — |
| menu.submenu:metrics | 2 | 3.9 | 25.7 | 14.8 | 25.7 | no budget declared | — |
| menu.app_exclusions | 6 | 1.1 | 22.9 | 5.13 | 22.9 | no budget declared | — |
| phase:menu_item.llm | 5 | — | — | 9.77 | 15.9 | no budget declared | — |
| menu.submenu:llm | 6 | 8 | 10.5 | 8.38 | 10.5 | no budget declared | — |
| phase:menu_keyboard_layout.number_row | 5 | — | — | 4.78 | 8.71 | no budget declared | — |
| menu.submenu:gestures | 6 | 7.3 | 8.7 | 7.6 | 8.7 | no budget declared | — |
| phase:menu_item.gestures | 5 | — | — | 7.73 | 8.66 | no budget declared | — |
| menu.submenu:about | 2 | 6.5 | 6.9 | 6.7 | 6.9 | no budget declared | — |
| phase:menu_item.about | 5 | — | — | 3.51 | 6.55 | no budget declared | — |
| phase:menu_item.metrics | 5 | — | — | 1.81 | 4.4 | no budget declared | — |
| phase:menu_item.tap_holds | 5 | — | — | 1.8 | 4.34 | no budget declared | — |
| phase:menu_item.hotstrings | 5 | — | — | 3.59 | 3.86 | no budget declared | — |
| menu.submenu:hotstrings | 2 | 3.5 | 3.6 | 3.55 | 3.6 | no budget declared | — |
| phase:menu_keyboard_layout.magic_key | 5 | — | — | 0.85 | 3.41 | no budget declared | — |
| phase:menu_item.debug | 5 | — | — | 0.87 | 3.25 | no budget declared | — |
| phase:menu_item.apps | 5 | — | — | 0.4 | 1.27 | no budget declared | — |
| phase:menu_item.language | 5 | — | — | 0.21 | 0.89 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 5 | — | — | 0.33 | 0.77 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 5 | — | — | 0.23 | 0.76 | no budget declared | — |
| phase:menu_item.configuration | 5 | — | — | 0.23 | 0.51 | no budget declared | — |
| phase:menu_item.reload | 5 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.quit | 5 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 204 ms at 2026-11-04 09:49:47:584, 162 ms at 2026-11-04 09:42:25:426, 115 ms at 2026-11-04 09:41:07:556
- menu.submenu:keyboard_layout: 128 ms at 2026-11-04 09:49:47:584, 79.6 ms at 2026-11-04 09:42:25:426, 42.4 ms at 2026-11-04 09:26:16:003
- menu.submenu:shortcuts: 51.1 ms at 2026-11-04 09:41:07:556, 46.5 ms at 2026-11-04 09:42:25:426, 43.7 ms at 2026-11-04 09:46:25:065
- menu.submenu:metrics: 25.7 ms at 2026-11-04 09:38:49:897, 3.9 ms at 2026-11-04 09:49:47:584
- menu.app_exclusions: 22.9 ms at 2026-11-04 09:38:49:842, 3.6 ms at 2026-11-04 09:49:47:523, 1.3 ms at 2026-11-04 09:26:15:947
- menu.submenu:llm: 10.5 ms at 2026-11-04 09:49:47:584, 8.8 ms at 2026-11-04 09:42:25:426, 8 ms at 2026-11-04 09:26:16:003
- menu.submenu:gestures: 8.7 ms at 2026-11-04 09:26:16:003, 7.9 ms at 2026-11-04 09:41:07:556, 7.9 ms at 2026-11-04 09:49:47:584
- menu.submenu:about: 6.9 ms at 2026-11-04 09:46:25:065, 6.5 ms at 2026-11-04 09:41:07:556
- menu.submenu:hotstrings: 3.6 ms at 2026-11-04 09:26:16:003, 3.5 ms at 2026-11-04 09:42:25:426

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 8 | 412 | 1290 | 527 | 1290 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (8) |

Worst occurrences:

- main_thread.hold: 1290 ms at 2026-11-04 09:38:23:033 (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:376), 501 ms at 2026-11-04 09:26:13:428 (...gopti/static/ergopti_plus/macos/modules/keymap/utils.lua:1567), 501 ms at 2026-11-04 09:31:09:405 (...gopti/static/ergopti_plus/macos/modules/keymap/utils.lua:1567)

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:tooltip.show_predictions | 1 | 16.39 | 16.39 | 16.39 | 16.39 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |
| hotpath:preview.rebuild | 3 | 8 | 11.78 | 9.24 | 11.78 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (3) |

Worst occurrences:

- hotpath:preview.rebuild: 11.78 ms at 2026-11-04 09:48:45:728, 8 ms at 2026-11-04 09:42:23:860, 7.95 ms at 2026-11-04 09:48:27:543

### LLM requests

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| llm.ttft | 1 | 3424 | 3424 | 3424 | 3424 | 2000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |
| llm.stream | 1 | 3422 | 3422 | 3422 | 3422 | no budget declared | — |
| llm.parsed:remote | 1 | 3421 | 3421 | 3421 | 3421 | no budget declared | — |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 1 | — | — | 20007 | 20007 | no budget declared | — |
| phase:process.sqlite3 | 1 | — | — | 4718 | 4718 | no budget declared | — |
| phase:process.python3 | 19 | — | — | 450 | 3866 | no budget declared | — |
| phase:process.defaults | 244 | — | — | 42.74 | 1542 | no budget declared | — |
| phase:process.ErgoptiPlus | 24 | — | — | 219 | 1537 | no budget declared | — |
| phase:process.sh | 1 | — | — | 767 | 767 | no budget declared | — |
| phase:boot.stage | 24 | — | — | 56.02 | 385 | no budget declared | — |
| phase:boot.requires | 16 | — | — | 40.38 | 382 | no budget declared | — |
| phase:process.spctl | 1 | — | — | 373 | 373 | no budget declared | — |
| phase:karabiner.deploy | 8 | — | — | 243 | 365 | no budget declared | — |
| phase:karabiner.merge | 8 | — | — | 227 | 363 | no budget declared | — |
| phase:karabiner.layout_actions | 8 | — | — | 58.35 | 244 | no budget declared | — |
| phase:boot.stage_cpu | 24 | — | — | 34.5 | 232 | no budget declared | — |
| phase:process.codesign | 3 | — | — | 92.64 | 180 | no budget declared | — |
| phase:process.brew | 1 | — | — | 162 | 162 | no budget declared | — |
| phase:process.shortcuts | 2 | — | — | 99.95 | 128 | no budget declared | — |
| phase:process.pgrep | 4 | — | — | 40.33 | 123 | no budget declared | — |
| phase:karabiner.write | 1 | — | — | 92.43 | 92.43 | no budget declared | — |
| phase:shell.systemextensionsctl | 1 | — | — | 91.44 | 91.44 | no budget declared | — |
| phase:shell.ls | 18 | — | — | 43.94 | 89.25 | no budget declared | — |
| phase:shell.other | 1 | — | — | 71.17 | 71.17 | no budget declared | — |
| phase:process.mkdir | 3 | — | — | 47.32 | 68.97 | no budget declared | — |
| phase:shell.mkdir | 3 | — | — | 47.3 | 68.94 | no budget declared | — |
| phase:shell.sw_vers | 1 | — | — | 59.99 | 59.99 | no budget declared | — |
| phase:shell.ioreg | 1 | — | — | 55.71 | 55.71 | no budget declared | — |
| phase:process.Application | 1 | — | — | 55.15 | 55.15 | no budget declared | — |
| phase:shell.find | 1 | — | — | 53.66 | 53.66 | no budget declared | — |
| phase:karabiner.inputs | 8 | — | — | 29.92 | 47.5 | no budget declared | — |
| phase:karabiner.build | 8 | — | — | 34.73 | 41.12 | no budget declared | — |
| phase:process.systemextensionsctl | 1 | — | — | 34.14 | 34.14 | no budget declared | — |
| phase:process.memory_pressure | 1 | — | — | 32.88 | 32.88 | no budget declared | — |
| phase:process.ps | 2 | — | — | 22.38 | 31.37 | no budget declared | — |
| phase:process.grep | 2 | — | — | 18.59 | 23.51 | no budget declared | — |
| phase:karabiner.encode | 1 | — | — | 21.68 | 21.68 | no budget declared | — |
| phase:process.xmllint | 8 | — | — | 4.77 | 20.86 | no budget declared | — |
| phase:hotstring_load.common_file | 2 | — | — | 14.47 | 16.63 | no budget declared | — |
| phase:hotpath.tooltip.show_predictions | 1 | — | — | 16.39 | 16.39 | no budget declared | — |
| phase:process.plutil | 4 | — | — | 5.28 | 9.04 | no budget declared | — |
| phase:hotpath.keydown | 25 | — | — | 1.07 | 8.57 | no budget declared | — |
| phase:hotpath.preview.rebuild | 19 | — | — | 0.86 | 8 | no budget declared | — |
| phase:preview.total | 26 | — | — | 0.76 | 8 | no budget declared | — |
| phase:toml.parse | 29 | — | — | 1.8 | 7.43 | no budget declared | — |
| phase:process.scutil | 1 | — | — | 6.3 | 6.3 | no budget declared | — |
| phase:process.launchctl | 1 | — | — | 4.71 | 4.71 | no budget declared | — |
| phase:process.id | 1 | — | — | 1.73 | 1.73 | no budget declared | — |
| phase:hotpath.hotstring.match | 20 | — | — | 0.11 | 1.18 | no budget declared | — |
| phase:preview.providers | 26 | — | — | 0.1 | 0.3 | no budget declared | — |
| phase:preview.resolve | 26 | — | — | 0.06 | 0.27 | no budget declared | — |
| phase:hotpath.hotstring.expand | 1 | — | — | 0.22 | 0.22 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 3
- counter:runtime.timer_hold_over_1000ms: 1
- counter:runtime.timer_hold_over_250ms: 5

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 3 | 2026-11-04 09:38:46:624 | 2026-11-04 09:46:21:851 |
| stop | 2 | 2026-11-04 09:38:45:976 | 2026-11-04 09:46:21:233 |
| reload | 2 | 2026-11-04 09:38:45:499 | 2026-11-04 09:46:20:760 |
| sleep_wake | 3 | 2026-11-04 09:26:09:236 | 2026-11-04 09:38:23:820 |
| karabiner_lease_failure | 2 | 2026-11-04 01:29:30:245 | 2026-11-04 09:06:26:857 |
| network_failure | 1 | 2026-11-04 09:41:07:988 | 2026-11-04 09:41:07:988 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-04 09:38:46:624 — ErgoptiPlus session opened =====
===== 2026-11-04 09:41:04:167 — ErgoptiPlus session opened =====
===== 2026-11-04 09:46:21:851 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-04 09:38:45:976 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-04 09:46:21:233 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-04 09:38:45:499 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-11-04 09:46:20:760 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-04 09:26:09:236 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-11-04 09:31:10:739 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-11-04 09:38:23:820 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
```

**karabiner_lease_failure**

```
2026-11-04 01:29:30:245 [WARNING] [karabiner.lease] Lease watchdog 8a6356806b544a8aa4b96945680e0a25 stderr: lease worker: HEARTBEAT 1 302 answered HEARTBEAT_FAILED 302 after 1.57 s (deadline 2.50 s).
2026-11-04 09:06:26:857 [WARNING] [karabiner.lease] Lease watchdog 8a6356806b544a8aa4b96945680e0a25 stderr: lease worker: HEARTBEAT 1 600 answered HEARTBEAT_FAILED 600 after 1.84 s (deadline 2.50 s).
```

**network_failure**

```
2026-11-04 09:41:07:988 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

</details>
