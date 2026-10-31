# Field log analysis

Logs: ErgoptiPlus_2026-10-31.log (2988 lines, 2965 records, 21 continuation lines); span 2026-10-31 00:08:36:583 to 2026-10-31 10:02:13:837.
Previous report compared: mac-2026-10-30_230426.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 27 | slow | main_thread.hold over its 250 ms budget | 9 | max 1810 ms at 2026-10-31 09:55:44:252 |
| 2 | 6 | slow | healthcheck.sync over its 5 ms budget | 2 | max 174 ms at 2026-10-31 09:55:29:675 |
| 3 | 5 | error | [adapters.file_system] append(): destination is not a regular file (named pipe). | 1 | 2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe). |
| 4 | 5 | error | [adapters.file_system] write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 1 | 2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file. |
| 5 | 5 | error | [adapters.keyboard_source_probe] Native keyboard source proof refused: source_changed. | 1 | 2026-10-31 09:55:29:076 [ERROR] [adapters.keyboard_source_probe] Native keyboard source proof refused: source_changed. |
| 6 | 5 | error | [keymap.layout_rows_build] The number-row layout for '<*>' was not applied (readback_mismatch): the keyboard probe answered source_changed. | 1 | 2026-10-31 09:55:29:429 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): the keyboard probe answered source_changed. |
| 7 | 5 | error | [menu_llm.ollama] Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained. | 1 | 2026-10-31 09:58:33:523 [ERROR] [menu_llm.ollama] Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained. |
| 8 | 5 | error | [menu_llm.ollama] The Ollama pull of granite4:<*>m-h ended (code <*>) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-10-31 09:58:33:523 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h ended (code 1) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row. |
| 9 | 1 | warning | [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-10-31 09:54:33:379 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. |
| 10 | 1 | warning | [keymap.utils] Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-10-31 09:53:16:432 [WARNING] [keymap.utils] Slow ignored-window probe 501 ms (watchers=0 focused_window=501 ms). |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-10-31 09:54:33:227)
- ✅ owned_runtime: pass (2026-10-31 09:54:33:336)
- ✅ network: pass (2026-10-31 09:54:34:430)
- ✅ toolchain: pass (2026-10-31 09:54:35:868)
- ✅ login_items: pass (2026-10-31 09:54:55:988)
- ✅ composer: pass (2026-10-31 09:54:57:427)
- ✅ boot_cost: pass (2026-10-31 09:54:57:433)
- ✅ idle_cost: pass (2026-10-31 09:55:27:503)
- ❌ layout_rows: fail (2026-10-31 09:55:30:381)
- ✅ permissions: pass (2026-10-31 09:55:30:839)
- ✅ event_taps: pass (2026-10-31 09:55:31:571)
- ✅ input_sources: pass (2026-10-31 09:55:31:689)
- ✅ storage: pass (2026-10-31 09:55:32:300)
- ✅ launcher_roles: pass (2026-10-31 09:55:32:419)
- ✅ network_hosts: pass (2026-10-31 09:55:35:045)
- ✅ ollama_blob_host: pass (2026-10-31 09:55:36:397)
- ✅ typing_selftest: pass (2026-10-31 09:55:42:414)
- ✅ capslock_chord: pass (2026-10-31 09:55:42:426)
- ✅ gesture_frames: pass (2026-10-31 09:55:42:436)
- ❌ hotstring_roundtrip: fail (2026-10-31 09:55:49:362)
- ❌ prediction_tooltip: fail (2026-10-31 09:55:49:380)
- ✅ menu_build: pass (2026-10-31 09:55:49:691)
- ✅ ai_local: pass (2026-10-31 09:58:44:988)
- ✅ slow_lines: pass (2026-10-31 09:58:45:022)
- ✅ fifo_safety: pass (2026-10-31 09:58:46:112)
- ✅ local_servers: pass (2026-10-31 09:58:46:169)
- ❌ app_health: fail (2026-10-31 09:58:46:195)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 24 pass, ❌ 4 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

6 error group(s), 5 warning group(s); 11 occurrence(s); 9 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | adapters.keyboard_source_probe | Native keyboard source proof refused: source_changed. | 1 | 2026-10-31 09:55:29:076 | 2026-10-31 09:55:29:076 | new |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): the keyboard probe answered source_changed. | 1 | 2026-10-31 09:55:29:429 | 2026-10-31 09:55:29:429 | new |
| ERROR | menu_llm.ollama | Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 | new |
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h ended (code <*>) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 | new |
| ERROR | adapters.file_system | append(): destination is not a regular file (named pipe). | 1 | 2026-10-31 09:58:46:051 | 2026-10-31 09:58:46:051 | new |
| ERROR | adapters.file_system | write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 1 | 2026-10-31 09:58:46:054 | 2026-10-31 09:58:46:054 | new |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 09:53:15:921 | 2026-10-31 09:53:15:921 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-10-31 09:53:16:432 | 2026-10-31 09:53:16:432 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-10-31 09:54:33:379 | 2026-10-31 09:54:33:379 |  |
| WARNING | menu.keyboard_layout | Failed to switch active layout to '<*>' / '<*>' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS). | 1 | 2026-10-31 09:55:29:189 | 2026-10-31 09:55:29:189 | new |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 09:55:44:252 | 2026-10-31 09:55:44:252 | new |

<details><summary>One example line per group</summary>

```
2026-10-31 09:55:29:076 [ERROR] [adapters.keyboard_source_probe] Native keyboard source proof refused: source_changed.
```
```
2026-10-31 09:55:29:429 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): the keyboard probe answered source_changed.
```
```
2026-10-31 09:58:33:523 [ERROR] [menu_llm.ollama] Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained.
```
```
2026-10-31 09:58:33:523 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h ended (code 1) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row.
```
```
2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe).
```
```
2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file.
```
```
2026-10-31 09:53:15:921 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364) held the main thread for 1512 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 51->51 MB.
```
```
2026-10-31 09:53:16:432 [WARNING] [keymap.utils] Slow ignored-window probe 501 ms (watchers=0 focused_window=501 ms).
```
```
2026-10-31 09:54:33:379 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-10-31 09:55:29:189 [WARNING] [menu.keyboard_layout] Failed to switch active layout to 'Ergopti Field Rows' / 'Ergopti Field Rows' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS).
```
```
2026-10-31 09:55:44:252 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1810 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 32->32 MB.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 1 | 1821 | 1821 | 1821 | 1821 | no budget declared | — |
| boot.cpu | 1 | 1320 | 1320 | 1320 | 1320 | no budget declared | — |
| boot.stage:Config-dependent module requires | 1 | 392 | 392 | 392 | 392 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 1 | 223 | 223 | 223 | 223 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 1 | 211 | 211 | 211 | 211 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 1 | 167 | 167 | 167 | 167 | no budget declared | — |
| boot.stage:UI: karabiner.init | 1 | 91.9 | 91.9 | 91.9 | 91.9 | no budget declared | — |
| boot.stage:Keymap engine started | 1 | 62.5 | 62.5 | 62.5 | 62.5 | no budget declared | — |
| boot.stage:Config schema migration | 1 | 52.4 | 52.4 | 52.4 | 52.4 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 1 | 41.5 | 41.5 | 41.5 | 41.5 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 1 | 37 | 37 | 37 | 37 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 1 | 10.4 | 10.4 | 10.4 | 10.4 | no budget declared | — |
| boot.stage:File watchers armed | 1 | 9.7 | 9.7 | 9.7 | 9.7 | no budget declared | — |
| boot.stage:Accessibility permission | 1 | 8 | 8 | 8 | 8 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 1 | 7.2 | 7.2 | 7.2 | 7.2 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 1 | 7.1 | 7.1 | 7.1 | 7.1 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 1 | 5.3 | 5.3 | 5.3 | 5.3 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 1 | 4.2 | 4.2 | 4.2 | 4.2 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 1 | 2.5 | 2.5 | 2.5 | 2.5 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 1 | 2.2 | 2.2 | 2.2 | 2.2 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 1 | 1.7 | 1.7 | 1.7 | 1.7 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 1 | 0.5 | 0.5 | 0.5 | 0.5 | no budget declared | — |
| boot.stage:UI: menu ready | 1 | 0.5 | 0.5 | 0.5 | 0.5 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 1 | 0.2 | 0.2 | 0.2 | 0.2 | no budget declared | — |

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.total | 1 | 56506 | 56506 | 56506 | 56506 | no budget declared | — |

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 4 | 289 | 472 | 327 | 472 | no budget declared | — |
| phase:menu.rebuild | 4 | — | — | 275 | 301 | no budget declared | — |
| menu.submenu:keyboard_layout | 4 | 72.8 | 274 | 135 | 274 | no budget declared | — |
| phase:menu_item.keyboard_layout | 4 | — | — | 86.55 | 132 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 4 | — | — | 83.58 | 129 | no budget declared | — |
| phase:menu_item.gestures | 4 | — | — | 43.11 | 51.41 | no budget declared | — |
| menu.submenu:gestures | 4 | 40.1 | 51.4 | 42.67 | 51.4 | no budget declared | — |
| menu.submenu:shortcuts | 4 | 35.1 | 47.7 | 41.2 | 47.7 | no budget declared | — |
| phase:menu_item.shortcuts | 4 | — | — | 40.6 | 46.98 | no budget declared | — |
| phase:menu_item.hotstrings | 4 | — | — | 32.82 | 40.23 | no budget declared | — |
| menu.submenu:hotstrings | 4 | 36.4 | 40.2 | 35.02 | 40.2 | no budget declared | — |
| menu.submenu:llm | 4 | 29.5 | 38.2 | 31.78 | 38.2 | no budget declared | — |
| phase:menu_item.llm | 4 | — | — | 31.63 | 37.6 | no budget declared | — |
| phase:menu_item.metrics | 4 | — | — | 11.42 | 24.03 | no budget declared | — |
| phase:menu_item.about | 4 | — | — | 9.28 | 20.31 | no budget declared | — |
| phase:menu_item.debug | 4 | — | — | 4.85 | 9.89 | no budget declared | — |
| menu.app_exclusions | 4 | 0.9 | 9.5 | 3.48 | 9.5 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 4 | — | — | 1.76 | 3.4 | no budget declared | — |
| phase:menu_item.configuration | 4 | — | — | 2.24 | 3.28 | no budget declared | — |
| phase:menu_item.tap_holds | 4 | — | — | 0.83 | 1.16 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 4 | — | — | 0.74 | 0.83 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 4 | — | — | 0.19 | 0.21 | no budget declared | — |
| phase:menu_item.apps | 4 | — | — | 0.16 | 0.17 | no budget declared | — |
| phase:menu_item.language | 4 | — | — | 0.03 | 0.04 | no budget declared | — |
| phase:menu_item.quit | 4 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.reload | 4 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 472 ms at 2026-10-31 09:59:38:742, 301 ms at 2026-10-31 09:55:29:074, 289 ms at 2026-10-31 09:54:31:785
- menu.submenu:keyboard_layout: 274 ms at 2026-10-31 09:59:38:742, 132 ms at 2026-10-31 09:55:29:074, 72.8 ms at 2026-10-31 09:55:30:720
- menu.submenu:gestures: 51.4 ms at 2026-10-31 09:54:31:785, 41.1 ms at 2026-10-31 09:59:38:742, 40.1 ms at 2026-10-31 09:55:30:720
- menu.submenu:shortcuts: 47.7 ms at 2026-10-31 09:59:38:742, 47 ms at 2026-10-31 09:54:31:785, 35.1 ms at 2026-10-31 09:55:29:074
- menu.submenu:hotstrings: 40.2 ms at 2026-10-31 09:55:30:720, 37.3 ms at 2026-10-31 09:59:38:742, 36.4 ms at 2026-10-31 09:55:29:074
- menu.submenu:llm: 38.2 ms at 2026-10-31 09:59:38:742, 30.6 ms at 2026-10-31 09:55:30:720, 29.5 ms at 2026-10-31 09:54:31:785
- menu.app_exclusions: 9.5 ms at 2026-10-31 09:54:31:685, 3.2 ms at 2026-10-31 09:55:28:999, 0.9 ms at 2026-10-31 09:59:38:650

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 9 | 501 | 1810 | 699 | 1810 | 250 ms (static/ergopti_plus/macos/infra/logger.lua) | ❌ over (9) |

Worst occurrences:

- main_thread.hold: 1810 ms at 2026-10-31 09:55:44:252 (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610), 1512 ms at 2026-10-31 09:53:15:921 (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364), 512 ms at 2026-10-31 09:59:38:742 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1740)

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| healthcheck.sync | 2 | 85.2 | 174 | 129 | 174 | 5 ms (stated in the log line) | ❌ over (2) |

Worst occurrences:

- healthcheck.sync: 174 ms at 2026-10-31 09:55:29:675, 85.2 ms at 2026-10-31 09:55:49:784

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 1 | — | — | 20007 | 20007 | no budget declared | — |
| phase:process.ErgoptiPlus | 16 | — | — | 391 | 3325 | no budget declared | — |
| phase:process.python3 | 14 | — | — | 468 | 2617 | no budget declared | — |
| phase:process.sh | 3 | — | — | 386 | 1056 | no budget declared | — |
| phase:process.defaults | 1060 | — | — | 23.79 | 838 | no budget declared | — |
| phase:process.spctl | 1 | — | — | 677 | 677 | no budget declared | — |
| phase:process.sqlite3 | 1 | — | — | 594 | 594 | no budget declared | — |
| phase:boot.stage | 24 | — | — | 75.29 | 461 | no budget declared | — |
| phase:boot.requires | 16 | — | — | 66.38 | 459 | no budget declared | — |
| phase:boot.stage_cpu | 24 | — | — | 54.71 | 343 | no budget declared | — |
| phase:process.brew | 1 | — | — | 167 | 167 | no budget declared | — |
| phase:process.codesign | 4 | — | — | 74.34 | 151 | no budget declared | — |
| phase:shell.other | 1 | — | — | 95.63 | 95.63 | no budget declared | — |
| phase:process.bash | 1 | — | — | 78.7 | 78.7 | no budget declared | — |
| phase:process.shortcuts | 2 | — | — | 75.81 | 76.16 | no budget declared | — |
| phase:shell.systemextensionsctl | 1 | — | — | 71.62 | 71.62 | no budget declared | — |
| phase:shell.ioreg | 1 | — | — | 69.88 | 69.88 | no budget declared | — |
| phase:shell.sw_vers | 1 | — | — | 68.82 | 68.82 | no budget declared | — |
| phase:shell.curl | 1 | — | — | 58.67 | 58.67 | no budget declared | — |
| phase:process.Application | 1 | — | — | 58.4 | 58.4 | no budget declared | — |
| phase:shell.ls | 15 | — | — | 36.02 | 51.54 | no budget declared | — |
| phase:process.mkdir | 4 | — | — | 31.51 | 51.42 | no budget declared | — |
| phase:shell.mkdir | 3 | — | — | 40.48 | 51.4 | no budget declared | — |
| phase:process.pgrep | 4 | — | — | 24.93 | 46.98 | no budget declared | — |
| phase:shell.cp | 5 | — | — | 36.16 | 46.7 | no budget declared | — |
| phase:shell.find | 1 | — | — | 39.97 | 39.97 | no budget declared | — |
| phase:process.ps | 3 | — | — | 16.16 | 33.77 | no budget declared | — |
| phase:process.xmllint | 8 | — | — | 6.76 | 32.87 | no budget declared | — |
| phase:process.awk | 1 | — | — | 25.08 | 25.08 | no budget declared | — |
| phase:process.systemextensionsctl | 1 | — | — | 20.2 | 20.2 | no budget declared | — |
| phase:hotstring_load.common_file | 2 | — | — | 12.48 | 17.19 | no budget declared | — |
| phase:process.grep | 2 | — | — | 9.59 | 13.75 | no budget declared | — |
| phase:process.memory_pressure | 1 | — | — | 13.59 | 13.59 | no budget declared | — |
| phase:process.plutil | 4 | — | — | 6.66 | 10.84 | no budget declared | — |
| phase:process.scutil | 1 | — | — | 8.71 | 8.71 | no budget declared | — |
| phase:process.mkfifo | 1 | — | — | 7.27 | 7.27 | no budget declared | — |
| phase:process.launchctl | 1 | — | — | 4.81 | 4.81 | no budget declared | — |
| phase:toml.parse | 28 | — | — | 1.35 | 4.54 | no budget declared | — |
| phase:hotpath.keydown | 17 | — | — | 1.51 | 4.01 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 2
- counter:runtime.timer_hold_over_1000ms: 1
- counter:runtime.timer_hold_over_250ms: 6

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 1 | 2026-10-31 09:54:27:969 | 2026-10-31 09:54:27:969 |
| reload | 1 | 2026-10-31 09:53:32:812 | 2026-10-31 09:53:32:812 |
| sleep_wake | 1 | 2026-10-31 09:53:15:921 | 2026-10-31 09:53:15:921 |
| network_failure | 1 | 2026-10-31 09:54:33:379 | 2026-10-31 09:54:33:379 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-10-31 09:54:27:969 — ErgoptiPlus session opened =====
```

**reload**

```
2026-10-31 09:53:32:812 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
```

**sleep_wake**

```
2026-10-31 09:53:15:921 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-10-31 09:54:33:379 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

</details>
