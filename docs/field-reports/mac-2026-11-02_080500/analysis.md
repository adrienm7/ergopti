# Field log analysis

Logs: ErgoptiPlus_2026-11-02.log (2658 lines, 2626 records, 26 continuation lines); span 2026-11-02 00:11:36:458 to 2026-11-02 08:15:39:011.
Previous report compared: mac-2026-11-01_232832.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 24 | warning | [keystats.log_manager] day_rollover: ingest stalled at offset <*> — preserving today.log. | 24 | 2026-11-02 00:11:36:461 [WARNING] [keystats.log_manager] day_rollover: ingest stalled at offset 4907 — preserving today.log. |
| 2 | 24 | warning | [keystats.log_manager] day_rollover: today.log not fully drained — file preserved, rotation skipped. | 24 | 2026-11-02 00:11:36:461 [WARNING] [keystats.log_manager] day_rollover: today.log not fully drained — file preserved, rotation skipped. |
| 3 | 24 | warning | [keystats.watchers] Midnight rotation stalled — will retry on next maintenance tick. | 24 | 2026-11-02 00:11:36:461 [WARNING] [keystats.watchers] Midnight rotation stalled — will retry on next maintenance tick. |
| 4 | 21 | slow | main_thread.hold over its 250 ms budget | 7 | max 1540 ms at 2026-11-02 08:05:31:827 |
| 5 | 10 | error | [menu_llm.ollama] The Ollama pull of granite4:<*>m-h failed (code <*>): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest. | 2 | 2026-11-02 08:09:29:740 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed (code 1): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest. |
| 6 | 9 | slow | menu.rebuild over its 250 ms budget | 3 | max 1314 ms at 2026-11-02 08:06:46:991 |
| 7 | 3 | slow | healthcheck.sync over its 5 ms budget | 1 | max 38.1 ms at 2026-11-02 08:06:47:066 |
| 8 | 3 | slow | hotpath:preview.rebuild over its 5 ms budget | 1 | max 6.29 ms at 2026-11-02 08:06:44:245 |
| 9 | 1 | warning | [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-02 08:05:32:126 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. |
| 10 | 1 | warning | [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-02 08:12:08:221 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-11-02 08:05:31:985)
- ✅ owned_runtime: pass (2026-11-02 08:05:32:091)
- ✅ owned_start: pass (2026-11-02 08:05:32:095)
- ✅ network: pass (2026-11-02 08:05:34:605)
- ✅ toolchain: pass (2026-11-02 08:05:35:915)
- ✅ login_items: pass (2026-11-02 08:05:56:068)
- ✅ composer: pass (2026-11-02 08:05:57:473)
- ✅ boot_cost: pass (2026-11-02 08:05:57:480)
- ✅ idle_cost: pass (2026-11-02 08:06:27:540)
- ✅ layout_rows: pass (2026-11-02 08:06:31:044)
- ✅ permissions: pass (2026-11-02 08:06:31:213)
- ❌ event_taps: fail (2026-11-02 08:06:32:052)
- ✅ input_sources: pass (2026-11-02 08:06:32:192)
- ✅ storage: pass (2026-11-02 08:06:32:754)
- ✅ launcher_roles: pass (2026-11-02 08:06:32:866)
- ✅ network_hosts: pass (2026-11-02 08:06:35:446)
- ✅ ollama_blob_host: pass (2026-11-02 08:06:37:451)
- ✅ typing_selftest: pass (2026-11-02 08:06:43:468)
- ✅ capslock_chord: pass (2026-11-02 08:06:43:481)
- ✅ gesture_frames: pass (2026-11-02 08:06:43:494)
- ✅ hotstring_roundtrip: pass (2026-11-02 08:06:45:616)
- ✅ prediction_tooltip: pass (2026-11-02 08:06:45:630)
- ✅ menu_build: pass (2026-11-02 08:06:46:992)
- ✅ pac_fallback: pass (2026-11-02 08:11:57:935)
- ✅ ai_local: pass (2026-11-02 08:12:02:394)
- ✅ slow_lines: pass (2026-11-02 08:12:02:448)
- ✅ fifo_safety: pass (2026-11-02 08:12:03:549)
- ✅ local_servers: pass (2026-11-02 08:12:03:710)
- ✅ app_health: pass (2026-11-02 08:12:05:409)
- ✅ tap_hold_thresholds: pass (2026-11-02 08:12:05:646)
- ✅ apple_shortcuts: pass (2026-11-02 08:12:05:703)
- ✅ owned_pause: pass (2026-11-02 08:12:05:708)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 32 pass, ❌ 1 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

1 error group(s), 15 warning group(s); 90 occurrence(s); 9 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h failed (code <*>): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest. | 2 | 2026-11-02 08:09:29:740 | 2026-11-02 08:11:48:416 | new |
| WARNING | keystats.log_manager | day_rollover: ingest stalled at offset <*> — preserving today.log. | 24 | 2026-11-02 00:11:36:461 | 2026-11-02 00:44:21:076 | new |
| WARNING | keystats.log_manager | day_rollover: today.log not fully drained — file preserved, rotation skipped. | 24 | 2026-11-02 00:11:36:461 | 2026-11-02 00:44:21:076 | new |
| WARNING | keystats.watchers | Midnight rotation stalled — will retry on next maintenance tick. | 24 | 2026-11-02 00:11:36:461 | 2026-11-02 00:44:21:076 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 5 | 2026-11-02 08:05:31:820 | 2026-11-02 08:15:38:109 |  |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-11-02 08:04:47:494 | 2026-11-02 08:04:47:494 | new |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 08:05:31:827 | 2026-11-02 08:05:31:827 | new |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-02 08:05:32:126 | 2026-11-02 08:05:32:126 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 1 | 2026-11-02 08:06:44:245 | 2026-11-02 08:06:44:245 | new |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 08:06:46:996 | 2026-11-02 08:06:46:996 | new |
| WARNING | menu_llm.ollama | The Ollama pull of granite4:<*>m-h failed its digest check; Ollama removed the layer, so it is pulled once more. | 1 | 2026-11-02 08:09:29:740 | 2026-11-02 08:09:29:740 | new |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: cancelled. | 1 | 2026-11-02 08:12:06:289 | 2026-11-02 08:12:06:289 |  |
| WARNING | keymap.utils | Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-02 08:12:08:221 | 2026-11-02 08:12:08:221 |  |
| WARNING | keymap | Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 1 | 2026-11-02 08:12:08:221 | 2026-11-02 08:12:08:221 |  |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 08:12:11:893 | 2026-11-02 08:12:11:893 |  |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 1 | 2026-11-02 08:15:36:713 | 2026-11-02 08:15:36:713 |  |

<details><summary>One example line per group</summary>

```
2026-11-02 08:09:29:740 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed (code 1): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest.
```
```
2026-11-02 00:11:36:461 [WARNING] [keystats.log_manager] day_rollover: ingest stalled at offset 4907 — preserving today.log.
```
```
2026-11-02 00:11:36:461 [WARNING] [keystats.log_manager] day_rollover: today.log not fully drained — file preserved, rotation skipped.
```
```
2026-11-02 00:11:36:461 [WARNING] [keystats.watchers] Midnight rotation stalled — will retry on next maintenance tick.
```
```
2026-11-02 08:05:31:820 [WARNING] [menu] Over budget: menu.rebuild took 1247 ms (budget 250 ms).
```
```
2026-11-02 08:04:47:494 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364) held the main thread for 1382 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 48->48 MB.
```
```
2026-11-02 08:05:31:827 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1540 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1247.4 ms, menu_i…
```
```
2026-11-02 08:05:32:126 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-02 08:06:44:245 [WARNING] [HotPath] Slow preview.rebuild: 6.29 ms own, 6.29 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-02 08:06:46:996 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1357 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1313.7 ms, menu_it…
```
```
2026-11-02 08:09:29:740 [WARNING] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed its digest check; Ollama removed the layer, so it is pulled once more.
```
```
2026-11-02 08:12:06:289 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: cancelled.
```
```
2026-11-02 08:12:08:221 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed.
```
```
2026-11-02 08:12:08:221 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false.
```
```
2026-11-02 08:12:11:893 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1410 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1197.7 ms, menu_i…
```
```
2026-11-02 08:15:36:713 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1488 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1453.2 ms, me…
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 3 | 1630 | 1977 | 1741 | 1977 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 3 | 1228 | 1250 | 1230 | 1250 | no budget declared | — |
| boot.stage:Config-dependent module requires | 3 | 386 | 614 | 460 | 614 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 3 | 203 | 223 | 208 | 223 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 3 | 146 | 198 | 155 | 198 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 3 | 186 | 193 | 188 | 193 | no budget declared | — |
| boot.stage:UI: karabiner.init | 3 | 75.8 | 79.1 | 75.63 | 79.1 | no budget declared | — |
| boot.stage:Keymap engine started | 3 | 33 | 59.7 | 40.3 | 59.7 | no budget declared | — |
| boot.stage:Config schema migration | 3 | 37.2 | 46.4 | 38.83 | 46.4 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 3 | 35.1 | 43.3 | 37.27 | 43.3 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 3 | 10.3 | 12 | 10 | 12 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 3 | 10 | 11.4 | 9.87 | 11.4 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 3 | 6.1 | 9.7 | 7.27 | 9.7 | no budget declared | — |
| boot.stage:File watchers armed | 3 | 8.8 | 9.3 | 8.93 | 9.3 | no budget declared | — |
| boot.stage:Accessibility permission | 3 | 1.9 | 7.9 | 3.5 | 7.9 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 3 | 5.3 | 5.3 | 5.27 | 5.3 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 3 | 3.4 | 5.2 | 3.77 | 5.2 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 3 | 0.7 | 4.5 | 1.93 | 4.5 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 3 | 1.9 | 3.8 | 2.43 | 3.8 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 3 | 2.8 | 3 | 2.67 | 3 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 3 | 2.6 | 2.8 | 2.6 | 2.8 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 3 | 0.8 | 1.3 | 0.87 | 1.3 | no budget declared | — |
| boot.stage:UI: menu ready | 3 | 0.3 | 0.4 | 0.3 | 0.4 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 3 | 0.2 | 0.3 | 0.23 | 0.3 | no budget declared | — |

Worst occurrences:

- boot.total: 1977 ms at 2026-11-02 08:12:08:503, 1630 ms at 2026-11-02 08:05:28:254, 1617 ms at 2026-11-02 08:05:04:077
- boot.cpu: 1250 ms at 2026-11-02 08:12:08:503, 1228 ms at 2026-11-02 08:05:04:077, 1211 ms at 2026-11-02 08:05:28:254
- boot.stage:Config-dependent module requires: 614 ms at 2026-11-02 08:12:07:648, 386 ms at 2026-11-02 08:05:03:351, 381 ms at 2026-11-02 08:05:27:467
- boot.stage:Hotstring groups registered (personal + dynamic + common): 223 ms at 2026-11-02 08:12:08:187, 203 ms at 2026-11-02 08:05:27:917, 198 ms at 2026-11-02 08:05:03:758
- boot.stage:Shortcuts pre-start: 198 ms at 2026-11-02 08:12:07:906, 146 ms at 2026-11-02 08:05:27:661, 121 ms at 2026-11-02 08:05:03:517
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 193 ms at 2026-11-02 08:12:08:491, 186 ms at 2026-11-02 08:05:04:063, 185 ms at 2026-11-02 08:05:28:241
- boot.stage:UI: karabiner.init: 79.1 ms at 2026-11-02 08:05:03:877, 75.8 ms at 2026-11-02 08:12:08:297, 72 ms at 2026-11-02 08:05:28:055
- boot.stage:Keymap engine started: 59.7 ms at 2026-11-02 08:05:27:983, 33 ms at 2026-11-02 08:05:03:797, 28.2 ms at 2026-11-02 08:12:08:221
- boot.stage:Config schema migration: 46.4 ms at 2026-11-02 08:12:07:696, 37.2 ms at 2026-11-02 08:05:03:389, 32.9 ms at 2026-11-02 08:05:27:500
- boot.stage:TOML discovery + ordering: 43.3 ms at 2026-11-02 08:12:07:964, 35.1 ms at 2026-11-02 08:05:27:714, 33.4 ms at 2026-11-02 08:05:03:560
- boot.stage:Path: native asynchronous logger transport committed: 12 ms at 2026-11-02 08:05:27:075, 10.3 ms at 2026-11-02 08:12:07:027, 7.7 ms at 2026-11-02 08:05:02:955
- boot.stage:MLX server cleanup started asynchronously: 11.4 ms at 2026-11-02 08:12:07:919, 10 ms at 2026-11-02 08:05:27:677, 8.2 ms at 2026-11-02 08:05:03:526

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 2 | 2337 | 2779 | 2558 | 2779 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 2 | 1860 | 2288 | 2074 | 2288 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 2779 ms at 2026-11-02 08:12:05:724, 2337 ms at 2026-11-02 08:05:01:740
- reload.total: 2288 ms at 2026-11-02 08:12:08:504, 1860 ms at 2026-11-02 08:05:04:077

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 3 | 1247 | 1314 | 1253 | 1314 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (3) |
| phase:menu.rebuild | 2 | — | — | 1281 | 1314 | no budget declared | — |
| phase:menu_item.shortcuts | 2 | — | — | 1033 | 1061 | no budget declared | — |
| menu.submenu:shortcuts | 3 | 1006 | 1061 | 1015 | 1061 | no budget declared | — |
| menu.submenu:keyboard_layout | 3 | 63.5 | 117 | 79.07 | 117 | no budget declared | — |
| phase:menu_item.keyboard_layout | 2 | — | — | 90.32 | 117 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 2 | — | — | 59.88 | 61.92 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 2 | — | — | 29.2 | 57.94 | no budget declared | — |
| menu.submenu:gestures | 3 | 49.5 | 51.5 | 48.93 | 51.5 | no budget declared | — |
| phase:menu_item.gestures | 2 | — | — | 47.7 | 49.55 | no budget declared | — |
| phase:menu_keyboard_layout.magic_key | 2 | — | — | 35.36 | 37.81 | no budget declared | — |
| phase:menu_item.llm | 2 | — | — | 30.17 | 31.01 | no budget declared | — |
| menu.submenu:llm | 3 | 29.3 | 31 | 29.07 | 31 | no budget declared | — |
| menu.submenu:metrics | 1 | 29.2 | 29.2 | 29.2 | 29.2 | no budget declared | — |
| phase:menu_item.metrics | 2 | — | — | 17.93 | 29.18 | no budget declared | — |
| phase:menu_item.hotstrings | 2 | — | — | 26.87 | 27.93 | no budget declared | — |
| menu.submenu:hotstrings | 2 | 25.3 | 27.9 | 26.6 | 27.9 | no budget declared | — |
| phase:menu_item.about | 2 | — | — | 12.1 | 18.64 | no budget declared | — |
| menu.app_exclusions | 3 | 1.2 | 15.5 | 5.63 | 15.5 | no budget declared | — |
| phase:menu_keyboard_layout.number_row | 2 | — | — | 9.63 | 10.66 | no budget declared | — |
| phase:menu_item.debug | 2 | — | — | 6.03 | 8.91 | no budget declared | — |
| phase:menu_item.configuration | 2 | — | — | 2.6 | 3.3 | no budget declared | — |
| phase:menu_item.tap_holds | 2 | — | — | 1.14 | 1.17 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 2 | — | — | 0.78 | 0.92 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 2 | — | — | 0.19 | 0.21 | no budget declared | — |
| phase:menu_item.apps | 2 | — | — | 0.15 | 0.15 | no budget declared | — |
| phase:menu_item.language | 2 | — | — | 0.04 | 0.04 | no budget declared | — |
| phase:menu_item.reload | 2 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.quit | 2 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 1314 ms at 2026-11-02 08:06:46:991, 1247 ms at 2026-11-02 08:05:31:820, 1198 ms at 2026-11-02 08:12:11:885
- menu.submenu:shortcuts: 1061 ms at 2026-11-02 08:06:46:991, 1006 ms at 2026-11-02 08:05:31:820, 979 ms at 2026-11-02 08:12:11:885
- menu.submenu:keyboard_layout: 117 ms at 2026-11-02 08:06:46:991, 63.5 ms at 2026-11-02 08:05:31:820, 56.5 ms at 2026-11-02 08:12:11:885
- menu.submenu:gestures: 51.5 ms at 2026-11-02 08:12:11:885, 49.5 ms at 2026-11-02 08:06:46:991, 45.8 ms at 2026-11-02 08:05:31:820
- menu.submenu:llm: 31 ms at 2026-11-02 08:05:31:820, 29.3 ms at 2026-11-02 08:06:46:991, 26.9 ms at 2026-11-02 08:12:11:885
- menu.submenu:hotstrings: 27.9 ms at 2026-11-02 08:06:46:991, 25.3 ms at 2026-11-02 08:12:11:885
- menu.app_exclusions: 15.5 ms at 2026-11-02 08:05:31:721, 1.2 ms at 2026-11-02 08:06:46:914, 0.2 ms at 2026-11-02 08:12:11:794

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 7 | 1382 | 1540 | 1150 | 1540 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (7) |

Worst occurrences:

- main_thread.hold: 1540 ms at 2026-11-02 08:05:31:827 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801), 1488 ms at 2026-11-02 08:15:36:713 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746), 1410 ms at 2026-11-02 08:12:11:893 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801)

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:preview.rebuild | 1 | 6.29 | 6.29 | 6.29 | 6.29 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| healthcheck.sync | 1 | 38.1 | 38.1 | 38.1 | 38.1 | 5 ms (stated in the log line) | ❌ over (1) |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 1 | — | — | 20047 | 20047 | no budget declared | — |
| phase:process.python3 | 19 | — | — | 444 | 2569 | no budget declared | — |
| phase:process.defaults | 72 | — | — | 77.47 | 1463 | no budget declared | — |
| phase:process.ErgoptiPlus | 16 | — | — | 262 | 1376 | no budget declared | — |
| phase:process.spctl | 1 | — | — | 553 | 553 | no budget declared | — |
| phase:process.sqlite3 | 1 | — | — | 543 | 543 | no budget declared | — |
| phase:boot.stage | 24 | — | — | 67.4 | 426 | no budget declared | — |
| phase:boot.requires | 16 | — | — | 60.15 | 422 | no budget declared | — |
| phase:boot.stage_cpu | 24 | — | — | 50.1 | 333 | no budget declared | — |
| phase:karabiner.deploy | 3 | — | — | 239 | 277 | no budget declared | — |
| phase:karabiner.merge | 3 | — | — | 195 | 223 | no budget declared | — |
| phase:process.codesign | 3 | — | — | 90.76 | 172 | no budget declared | — |
| phase:process.brew | 1 | — | — | 143 | 143 | no budget declared | — |
| phase:shell.other | 1 | — | — | 124 | 124 | no budget declared | — |
| phase:karabiner.write | 1 | — | — | 109 | 109 | no budget declared | — |
| phase:shell.ls | 18 | — | — | 42.65 | 97.29 | no budget declared | — |
| phase:process.shortcuts | 2 | — | — | 76.62 | 93.57 | no budget declared | — |
| phase:shell.systemextensionsctl | 1 | — | — | 85.62 | 85.62 | no budget declared | — |
| phase:karabiner.layout_actions | 3 | — | — | 51.22 | 79.24 | no budget declared | — |
| phase:shell.sw_vers | 1 | — | — | 62.45 | 62.45 | no budget declared | — |
| phase:shell.ioreg | 1 | — | — | 61.91 | 61.91 | no budget declared | — |
| phase:process.Application | 1 | — | — | 53.48 | 53.48 | no budget declared | — |
| phase:process.mkdir | 3 | — | — | 32.01 | 50.93 | no budget declared | — |
| phase:shell.mkdir | 3 | — | — | 31.99 | 50.91 | no budget declared | — |
| phase:shell.find | 1 | — | — | 48.95 | 48.95 | no budget declared | — |
| phase:karabiner.inputs | 3 | — | — | 37.65 | 45.62 | no budget declared | — |
| phase:process.grep | 2 | — | — | 21.32 | 31.15 | no budget declared | — |
| phase:process.xmllint | 8 | — | — | 7.28 | 31.03 | no budget declared | — |
| phase:karabiner.build | 3 | — | — | 28.66 | 30.47 | no budget declared | — |
| phase:process.systemextensionsctl | 1 | — | — | 19.16 | 19.16 | no budget declared | — |
| phase:process.ps | 2 | — | — | 16.09 | 19.12 | no budget declared | — |
| phase:hotstring_load.common_file | 2 | — | — | 11.31 | 18.88 | no budget declared | — |
| phase:karabiner.encode | 1 | — | — | 18.69 | 18.69 | no budget declared | — |
| phase:process.pgrep | 3 | — | — | 16.17 | 17.23 | no budget declared | — |
| phase:hotpath.keydown | 18 | — | — | 3 | 8.85 | no budget declared | — |
| phase:hotpath.hotstring.match | 15 | — | — | 0.55 | 7.48 | no budget declared | — |
| phase:process.scutil | 1 | — | — | 6.93 | 6.93 | no budget declared | — |
| phase:process.launchctl | 1 | — | — | 6.66 | 6.66 | no budget declared | — |
| phase:hotpath.preview.rebuild | 14 | — | — | 1.45 | 6.29 | no budget declared | — |
| phase:preview.total | 17 | — | — | 1.38 | 6.29 | no budget declared | — |
| phase:process.plutil | 4 | — | — | 4.35 | 5.18 | no budget declared | — |
| phase:hotpath.hotstring.expand | 1 | — | — | 4.95 | 4.95 | no budget declared | — |
| phase:toml.parse | 29 | — | — | 1.26 | 3.91 | no budget declared | — |
| phase:process.memory_pressure | 1 | — | — | 3.46 | 3.46 | no budget declared | — |
| phase:process.id | 1 | — | — | 2.05 | 2.05 | no budget declared | — |
| phase:preview.providers | 17 | — | — | 0.7 | 1.93 | no budget declared | — |
| phase:preview.resolve | 17 | — | — | 0.08 | 0.38 | no budget declared | — |

### Counters

- counter:runtime.timer_hold_over_1000ms: 3
- counter:runtime.timer_hold_over_250ms: 111

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 3 | 2026-11-02 08:05:02:946 | 2026-11-02 08:12:07:016 |
| stop | 2 | 2026-11-02 08:05:02:222 | 2026-11-02 08:12:06:218 |
| reload | 2 | 2026-11-02 08:05:01:740 | 2026-11-02 08:12:05:724 |
| sleep_wake | 1 | 2026-11-02 08:04:47:494 | 2026-11-02 08:04:47:494 |
| network_failure | 1 | 2026-11-02 08:05:32:126 | 2026-11-02 08:05:32:126 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-02 08:05:02:946 — ErgoptiPlus session opened =====
===== 2026-11-02 08:05:27:062 — ErgoptiPlus session opened =====
===== 2026-11-02 08:12:07:016 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-02 08:05:02:222 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-02 08:12:06:218 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-02 08:05:01:740 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-11-02 08:12:05:724 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-02 08:04:47:494 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-11-02 08:05:32:126 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

</details>
