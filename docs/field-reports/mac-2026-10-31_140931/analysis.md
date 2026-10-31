# Field log analysis

Logs: ErgoptiPlus_2026-10-31.log (4736 lines, 4693 records, 39 continuation lines); span 2026-10-31 00:08:36:583 to 2026-10-31 14:18:26:268.
Previous report compared: mac-2026-10-31_095332.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 57 | slow | main_thread.hold over its 250 ms budget | 19 | max 2515 ms at 2026-10-31 14:13:39:139 |
| 2 | 18 | slow | menu.rebuild over its 250 ms budget | 6 | max 472 ms at 2026-10-31 09:59:38:742 |
| 3 | 12 | slow | healthcheck.sync over its 5 ms budget | 4 | max 174 ms at 2026-10-31 09:55:29:675 |
| 4 | 10 | error | [adapters.file_system] append(): destination is not a regular file (named pipe). | 2 | 2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe). |
| 5 | 10 | error | [adapters.file_system] write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 2 | 2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file. |
| 6 | 6 | slow | reload.request_to_boot over its 4000 ms budget | 2 | max 169967 ms at 2026-10-31 14:09:31:496 |
| 7 | 5 | error | [adapters.keyboard_source_probe] Native keyboard source proof refused: source_changed. | 1 | 2026-10-31 09:55:29:076 [ERROR] [adapters.keyboard_source_probe] Native keyboard source proof refused: source_changed. |
| 8 | 5 | error | [keymap.layout_rows_build] The number-row layout for '<*>' was not applied (readback_mismatch): key <*> types '<*>', the build holds text '<*>'. | 1 | 2026-10-31 14:13:22:548 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): key 26 types '', the build holds text '&'. |
| 9 | 5 | error | [keymap.layout_rows_build] The number-row layout for '<*>' was not applied (readback_mismatch): the keyboard probe answered source_changed. | 1 | 2026-10-31 09:55:29:429 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): the keyboard probe answered source_changed. |
| 10 | 5 | error | [keystats.context_tracker] Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: Notification has already been registered | 1 | 2026-10-31 14:09:14:863 [ERROR] [keystats.context_tracker] Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:655: Notification has already been registered |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ❌ lease: fail (2026-10-31 14:12:23:128, last of 2 runs, 1 failed)
- ✅ owned_runtime: pass (2026-10-31 14:12:24:092, last of 2 runs, 0 failed)
- ✅ network: pass (2026-10-31 14:12:27:626, last of 2 runs, 0 failed)
- ✅ toolchain: pass (2026-10-31 14:12:29:003, last of 2 runs, 0 failed)
- ✅ login_items: pass (2026-10-31 14:12:49:104, last of 2 runs, 0 failed)
- ✅ composer: pass (2026-10-31 14:12:50:589, last of 2 runs, 0 failed)
- ✅ boot_cost: pass (2026-10-31 14:12:50:597, last of 2 runs, 0 failed)
- ✅ idle_cost: pass (2026-10-31 14:13:20:680, last of 2 runs, 0 failed)
- ❌ layout_rows: fail (2026-10-31 14:13:23:227, last of 2 runs, 2 failed)
- ✅ permissions: pass (2026-10-31 14:13:23:757, last of 2 runs, 0 failed)
- ✅ event_taps: pass (2026-10-31 14:13:24:447, last of 2 runs, 0 failed)
- ✅ input_sources: pass (2026-10-31 14:13:24:565, last of 2 runs, 0 failed)
- ✅ storage: pass (2026-10-31 14:13:25:172, last of 2 runs, 0 failed)
- ✅ launcher_roles: pass (2026-10-31 14:13:25:290, last of 2 runs, 0 failed)
- ✅ network_hosts: pass (2026-10-31 14:13:28:442, last of 2 runs, 0 failed)
- ✅ ollama_blob_host: pass (2026-10-31 14:13:29:854, last of 2 runs, 0 failed)
- ✅ typing_selftest: pass (2026-10-31 14:13:35:869, last of 2 runs, 0 failed)
- ✅ capslock_chord: pass (2026-10-31 14:13:35:880, last of 2 runs, 0 failed)
- ✅ gesture_frames: pass (2026-10-31 14:13:35:886, last of 2 runs, 0 failed)
- ❌ hotstring_roundtrip: fail (2026-10-31 14:13:40:050, last of 2 runs, 2 failed)
- ✅ prediction_tooltip: pass (2026-10-31 14:13:40:061, last of 2 runs, 1 failed)
- ✅ menu_build: pass (2026-10-31 14:13:40:399, last of 2 runs, 0 failed)
- ✅ ai_local: pass (2026-10-31 14:14:54:078, last of 2 runs, 0 failed)
- ✅ slow_lines: pass (2026-10-31 14:14:54:130, last of 2 runs, 0 failed)
- ✅ fifo_safety: pass (2026-10-31 14:14:55:220, last of 2 runs, 0 failed)
- ✅ local_servers: pass (2026-10-31 14:14:55:346, last of 2 runs, 0 failed)
- ✅ app_health: pass (2026-10-31 14:14:56:981, last of 2 runs, 1 failed)
- ✅ pac_fallback: pass (2026-10-31 14:14:54:062)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 26 pass, ❌ 3 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

11 error group(s), 16 warning group(s); 37 occurrence(s); 16 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | adapters.file_system | append(): destination is not a regular file (named pipe). | 2 | 2026-10-31 09:58:46:051 | 2026-10-31 14:14:55:159 |  |
| ERROR | adapters.file_system | write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 2 | 2026-10-31 09:58:46:054 | 2026-10-31 14:14:55:162 |  |
| ERROR | adapters.keyboard_source_probe | Native keyboard source proof refused: source_changed. | 1 | 2026-10-31 09:55:29:076 | 2026-10-31 09:55:29:076 |  |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): the keyboard probe answered source_changed. | 1 | 2026-10-31 09:55:29:429 | 2026-10-31 09:55:29:429 |  |
| ERROR | menu_llm.ollama | Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 |  |
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h ended (code <*>) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 |  |
| ERROR | keystats.context_tracker | Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: Notification has already been registered | 1 | 2026-10-31 14:09:14:863 | 2026-10-31 14:09:14:863 | new |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): key <*> types '<*>', the build holds text '<*>'. | 1 | 2026-10-31 14:13:22:548 | 2026-10-31 14:13:22:548 | new |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-10-31 14:14:44:840 | 2026-10-31 14:14:44:840 | new |
| ERROR | ollama_deps | Ollama bootstrap failed (exit=<*>) — Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 1 | 2026-10-31 14:14:44:840 | 2026-10-31 14:14:44:840 | new |
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 1 | 2026-10-31 14:14:54:078 | 2026-10-31 14:14:54:078 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 5 | 2026-10-31 14:12:24:026 | 2026-10-31 14:18:26:238 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 3 | 2026-10-31 09:53:16:432 | 2026-10-31 10:19:57:157 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 2 | 2026-10-31 09:54:33:379 | 2026-10-31 14:12:24:122 |  |
| WARNING | menu.keyboard_layout | Failed to switch active layout to '<*>' / '<*>' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS). | 2 | 2026-10-31 09:55:29:189 | 2026-10-31 14:13:22:319 |  |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 09:53:15:921 | 2026-10-31 09:53:15:921 |  |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 09:55:44:252 | 2026-10-31 09:55:44:252 |  |
| WARNING | karabiner.lease | Karabiner lease <*> heartbeat <*> had no clean local CLI transport. | 1 | 2026-10-31 10:48:26:000 | 2026-10-31 10:48:26:000 | new |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 1 | 2026-10-31 14:13:36:620 | 2026-10-31 14:13:36:620 | new |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 14:13:39:139 | 2026-10-31 14:13:39:139 | new |
| WARNING | shortcuts.script_control | Script-control eventtap was disabled by macOS — re-enabling. | 1 | 2026-10-31 14:13:39:656 | 2026-10-31 14:13:39:656 | new |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 1 | 2026-10-31 14:13:40:746 | 2026-10-31 14:13:40:746 | new |
| WARNING | download_window | Progress UI flipped to error state: Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 1 | 2026-10-31 14:14:44:840 | 2026-10-31 14:14:44:840 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> secure_field=<*> destination=<*> ms). | 1 | 2026-10-31 14:17:08:261 | 2026-10-31 14:17:08:261 | new |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 1 | 2026-10-31 14:18:24:886 | 2026-10-31 14:18:24:886 | new |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 1 | 2026-10-31 14:18:26:245 | 2026-10-31 14:18:26:245 | new |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 1 | 2026-10-31 14:18:26:245 | 2026-10-31 14:18:26:245 | new |

<details><summary>One example line per group</summary>

```
2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe).
```
```
2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file.
```
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
2026-10-31 14:09:14:863 [ERROR] [keystats.context_tracker] Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:655: Notification has already been registered
```
```
2026-10-31 14:13:22:548 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): key 26 types '', the build holds text '&'.
```
```
2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=562 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
```
```
2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Ergopti n'a pas pu vérifier sa version épinglée d'Ollama (catalogue de publication ou contrôle d'intégrité) : rien n'a été installé. Envoyez le rapport de diagnostic.
```
```
2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```
```
2026-10-31 14:12:24:026 [WARNING] [menu] Over budget: menu.rebuild took 314 ms (budget 250 ms).
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
2026-10-31 09:53:15:921 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364) held the main thread for 1512 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 51->51 MB.
```
```
2026-10-31 09:55:44:252 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1810 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 32->32 MB.
```
```
2026-10-31 10:48:26:000 [WARNING] [karabiner.lease] Karabiner lease 0adf0f18109444b7b9f632389103396a heartbeat 253 had no clean local CLI transport.
```
```
2026-10-31 14:13:36:620 [WARNING] [HotPath] Slow preview.rebuild: 7.89 ms own, 7.89 ms total, parent keydown (0 similar since the last line).
```
```
2026-10-31 14:13:39:139 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236) held the main thread for 2515 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 40->40 MB.
```
```
2026-10-31 14:13:39:656 [WARNING] [shortcuts.script_control] Script-control eventtap was disabled by macOS — re-enabling.
```
```
2026-10-31 14:13:40:746 [WARNING] [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=78): refused: RuntimeRefusal at managed_ollama_hint.py:39 candidate
```
```
2026-10-31 14:14:44:840 [WARNING] [download_window] Progress UI flipped to error state: Ergopti n'a pas pu vérifier sa version épinglée d'Ollama (catalogue de publication ou contrôle d'intégrité) : rien n'a été installé. Envoyez le rapport de diagnostic.
```
```
2026-10-31 14:17:08:261 [WARNING] [keymap.utils] Slow ignored-window probe 266 ms (watchers=0 focused_window=265 application=0 app_name=0 title=0 context_watchers=0 secure_field=0 destination=0 ms).
```
```
2026-10-31 14:18:24:886 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```
```
2026-10-31 14:18:26:245 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil.
```
```
2026-10-31 14:18:26:245 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 2 | 1821 | 2074 | 1948 | 2074 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 2 | 1320 | 1353 | 1336 | 1353 | no budget declared | — |
| boot.stage:Config-dependent module requires | 2 | 392 | 402 | 397 | 402 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 2 | 205 | 223 | 214 | 223 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 2 | 211 | 216 | 213 | 216 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 2 | 161 | 167 | 164 | 167 | no budget declared | — |
| boot.stage:UI: karabiner.init | 2 | 83.7 | 91.9 | 87.8 | 91.9 | no budget declared | — |
| boot.stage:Keymap engine started | 2 | 53.6 | 62.5 | 58.05 | 62.5 | no budget declared | — |
| boot.stage:Config schema migration | 2 | 47.7 | 52.4 | 50.05 | 52.4 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 2 | 2.3 | 41.5 | 21.9 | 41.5 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 2 | 32.3 | 37 | 34.65 | 37 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 2 | 10.4 | 13 | 11.7 | 13 | no budget declared | — |
| boot.stage:File watchers armed | 2 | 9.7 | 11.4 | 10.55 | 11.4 | no budget declared | — |
| boot.stage:Accessibility permission | 2 | 7.4 | 8 | 7.7 | 8 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 2 | 2.2 | 7.3 | 4.75 | 7.3 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 2 | 5.8 | 7.2 | 6.5 | 7.2 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 2 | 5.9 | 7.1 | 6.5 | 7.1 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 2 | 5.1 | 5.3 | 5.2 | 5.3 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 2 | 4.2 | 4.4 | 4.3 | 4.4 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 2 | 0.2 | 4.2 | 2.2 | 4.2 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 2 | 1.7 | 3.2 | 2.45 | 3.2 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 2 | 2.4 | 2.5 | 2.45 | 2.5 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 2 | 0.5 | 0.6 | 0.55 | 0.6 | no budget declared | — |
| boot.stage:UI: menu ready | 2 | 0.5 | 0.5 | 0.5 | 0.5 | no budget declared | — |

Worst occurrences:

- boot.total: 2074 ms at 2026-10-31 14:12:21:463, 1821 ms at 2026-10-31 09:54:29:318
- boot.cpu: 1353 ms at 2026-10-31 14:12:21:463, 1320 ms at 2026-10-31 09:54:29:319
- boot.stage:Config-dependent module requires: 402 ms at 2026-10-31 14:12:20:611, 392 ms at 2026-10-31 09:54:28:418
- boot.stage:Hotstring groups registered (personal + dynamic + common): 223 ms at 2026-10-31 09:54:28:927, 205 ms at 2026-10-31 14:12:21:084
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 216 ms at 2026-10-31 14:12:21:445, 211 ms at 2026-10-31 09:54:29:305
- boot.stage:Shortcuts pre-start: 167 ms at 2026-10-31 09:54:28:655, 161 ms at 2026-10-31 14:12:20:835
- boot.stage:UI: karabiner.init: 91.9 ms at 2026-10-31 09:54:29:093, 83.7 ms at 2026-10-31 14:12:21:229
- boot.stage:Keymap engine started: 62.5 ms at 2026-10-31 09:54:29:000, 53.6 ms at 2026-10-31 14:12:21:145
- boot.stage:Config schema migration: 52.4 ms at 2026-10-31 09:54:28:471, 47.7 ms at 2026-10-31 14:12:20:659
- boot.stage:TOML hotstring cache wired: 41.5 ms at 2026-10-31 09:54:28:026, 2.3 ms at 2026-10-31 14:12:20:208
- boot.stage:TOML discovery + ordering: 37 ms at 2026-10-31 09:54:28:704, 32.3 ms at 2026-10-31 14:12:20:878
- boot.stage:Path: native asynchronous logger transport committed: 13 ms at 2026-10-31 14:12:20:191, 10.4 ms at 2026-10-31 09:54:27:981

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 2 | 56506 | 169967 | 113237 | 169967 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |

Worst occurrences:

- reload.request_to_boot: 169967 ms at 2026-10-31 14:09:31:496, 56506 ms at 2026-10-31 09:53:32:812

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 7 | 301 | 472 | 330 | 472 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (6) |
| phase:menu.rebuild | 27 | — | — | 339 | 687 | no budget declared | — |
| phase:menu_item.keyboard_layout | 27 | — | — | 147 | 463 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 27 | — | — | 43.66 | 375 | no budget declared | — |
| menu.submenu:keyboard_layout | 7 | 102 | 274 | 130 | 274 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 27 | — | — | 102 | 190 | no budget declared | — |
| menu.submenu:gestures | 7 | 41.1 | 70.5 | 46.26 | 70.5 | no budget declared | — |
| phase:menu_item.shortcuts | 27 | — | — | 47.3 | 66.21 | no budget declared | — |
| phase:menu_item.gestures | 27 | — | — | 44.59 | 51.46 | no budget declared | — |
| menu.submenu:shortcuts | 7 | 47.5 | 49.7 | 44.43 | 49.7 | no budget declared | — |
| phase:menu_item.hotstrings | 27 | — | — | 31.28 | 40.23 | no budget declared | — |
| menu.submenu:hotstrings | 7 | 34.1 | 40.2 | 33.77 | 40.2 | no budget declared | — |
| menu.submenu:llm | 6 | 30 | 38.2 | 32.08 | 38.2 | no budget declared | — |
| phase:menu_item.llm | 27 | — | — | 32.08 | 38.18 | no budget declared | — |
| phase:menu_item.metrics | 27 | — | — | 8.44 | 33.33 | no budget declared | — |
| menu.submenu:metrics | 1 | 33.3 | 33.3 | 33.3 | 33.3 | no budget declared | — |
| phase:menu_item.about | 27 | — | — | 8.58 | 28.24 | no budget declared | — |
| menu.app_exclusions | 7 | 0.9 | 18.3 | 4.74 | 18.3 | no budget declared | — |
| phase:menu_item.debug | 27 | — | — | 3.98 | 9.96 | no budget declared | — |
| phase:menu_item.tap_holds | 27 | — | — | 1.12 | 8.24 | no budget declared | — |
| phase:menu_item.configuration | 27 | — | — | 2.21 | 3.44 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 27 | — | — | 0.84 | 1.42 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 27 | — | — | 0.2 | 0.31 | no budget declared | — |
| phase:menu_item.apps | 27 | — | — | 0.17 | 0.21 | no budget declared | — |
| phase:menu_item.language | 27 | — | — | 0.04 | 0.05 | no budget declared | — |
| phase:menu_item.quit | 27 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.reload | 27 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 472 ms at 2026-10-31 09:59:38:742, 393 ms at 2026-10-31 14:18:21:639, 314 ms at 2026-10-31 14:12:24:025
- menu.submenu:keyboard_layout: 274 ms at 2026-10-31 09:59:38:742, 183 ms at 2026-10-31 14:18:21:639, 132 ms at 2026-10-31 09:55:29:074
- menu.submenu:gestures: 70.5 ms at 2026-10-31 14:18:21:639, 51.4 ms at 2026-10-31 09:54:31:785, 44 ms at 2026-10-31 14:13:40:398
- menu.submenu:shortcuts: 49.7 ms at 2026-10-31 14:18:21:639, 49 ms at 2026-10-31 14:12:24:025, 47.7 ms at 2026-10-31 09:59:38:742
- menu.submenu:hotstrings: 40.2 ms at 2026-10-31 09:55:30:720, 37.3 ms at 2026-10-31 09:59:38:742, 36.4 ms at 2026-10-31 09:55:29:074
- menu.submenu:llm: 38.2 ms at 2026-10-31 09:59:38:742, 35.4 ms at 2026-10-31 14:13:40:398, 30.6 ms at 2026-10-31 09:55:30:720
- menu.app_exclusions: 18.3 ms at 2026-10-31 14:12:23:923, 9.5 ms at 2026-10-31 09:54:31:685, 3.2 ms at 2026-10-31 09:55:28:999

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 19 | 501 | 2515 | 665 | 2515 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (19) |

Worst occurrences:

- main_thread.hold: 2515 ms at 2026-10-31 14:13:39:139 (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236), 1810 ms at 2026-10-31 09:55:44:252 (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610), 1512 ms at 2026-10-31 09:53:15:921 (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364)

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:preview.rebuild | 1 | 7.89 | 7.89 | 7.89 | 7.89 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| healthcheck.sync | 4 | 95.1 | 174 | 127 | 174 | 5 ms (stated in the log line) | ❌ over (4) |

Worst occurrences:

- healthcheck.sync: 174 ms at 2026-10-31 09:55:29:675, 153 ms at 2026-10-31 14:13:23:040, 95.1 ms at 2026-10-31 14:13:40:506

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 2 | — | — | 20009 | 20012 | no budget declared | — |
| phase:process.python3 | 28 | — | — | 567 | 3397 | no budget declared | — |
| phase:process.ErgoptiPlus | 58 | — | — | 315 | 3325 | no budget declared | — |
| phase:process.vmmap | 1 | — | — | 1608 | 1608 | no budget declared | — |
| phase:process.defaults | 2001 | — | — | 26.08 | 1072 | no budget declared | — |
| phase:process.sh | 6 | — | — | 387 | 1056 | no budget declared | — |
| phase:boot.stage | 48 | — | — | 80.35 | 760 | no budget declared | — |
| phase:boot.requires | 32 | — | — | 74.52 | 757 | no budget declared | — |
| phase:process.spctl | 2 | — | — | 650 | 677 | no budget declared | — |
| phase:process.sqlite3 | 2 | — | — | 593 | 594 | no budget declared | — |
| phase:process.pgrep | 8 | — | — | 106 | 591 | no budget declared | — |
| phase:boot.stage_cpu | 48 | — | — | 55.39 | 442 | no budget declared | — |
| phase:process.systemextensionsctl | 2 | — | — | 148 | 276 | no budget declared | — |
| phase:process.brew | 2 | — | — | 161 | 167 | no budget declared | — |
| phase:process.codesign | 7 | — | — | 80.03 | 165 | no budget declared | — |
| phase:shell.other | 2 | — | — | 105 | 115 | no budget declared | — |
| phase:process.bash | 2 | — | — | 92.33 | 106 | no budget declared | — |
| phase:shell.ioreg | 2 | — | — | 82.06 | 94.24 | no budget declared | — |
| phase:shell.curl | 2 | — | — | 76.25 | 93.82 | no budget declared | — |
| phase:process.shortcuts | 4 | — | — | 74.46 | 91.89 | no budget declared | — |
| phase:shell.ls | 33 | — | — | 40.74 | 86.76 | no budget declared | — |
| phase:shell.systemextensionsctl | 2 | — | — | 78.97 | 86.33 | no budget declared | — |
| phase:shell.cp | 11 | — | — | 42.02 | 71.86 | no budget declared | — |
| phase:shell.sw_vers | 2 | — | — | 65.41 | 68.82 | no budget declared | — |
| phase:process.mkdir | 8 | — | — | 34.38 | 64.82 | no budget declared | — |
| phase:shell.mkdir | 6 | — | — | 44.07 | 64.77 | no budget declared | — |
| phase:process.Application | 2 | — | — | 59.77 | 61.13 | no budget declared | — |
| phase:shell.find | 2 | — | — | 44.78 | 49.6 | no budget declared | — |
| phase:process.awk | 3 | — | — | 29.51 | 42.07 | no budget declared | — |
| phase:process.ps | 7 | — | — | 15.46 | 38.15 | no budget declared | — |
| phase:process.xmllint | 16 | — | — | 6.28 | 32.87 | no budget declared | — |
| phase:process.memory_pressure | 2 | — | — | 22.69 | 31.79 | no budget declared | — |
| phase:hotstring_load.common_file | 4 | — | — | 12.52 | 20.65 | no budget declared | — |
| phase:process.grep | 4 | — | — | 8.36 | 13.75 | no budget declared | — |
| phase:process.plutil | 8 | — | — | 5.12 | 10.84 | no budget declared | — |
| phase:hotpath.keydown | 23 | — | — | 2 | 9.94 | no budget declared | — |
| phase:process.launchctl | 2 | — | — | 6.96 | 9.11 | no budget declared | — |
| phase:process.scutil | 2 | — | — | 8.49 | 8.71 | no budget declared | — |
| phase:hotpath.preview.rebuild | 4 | — | — | 2.53 | 7.89 | no budget declared | — |
| phase:preview.total | 6 | — | — | 1.95 | 7.89 | no budget declared | — |
| phase:process.mkfifo | 1 | — | — | 7.27 | 7.27 | no budget declared | — |
| phase:toml.parse | 57 | — | — | 1.37 | 5.6 | no budget declared | — |
| phase:preview.providers | 6 | — | — | 0.59 | 0.84 | no budget declared | — |
| phase:hotpath.hotstring.match | 4 | — | — | 0.03 | 0.05 | no budget declared | — |
| phase:preview.resolve | 6 | — | — | 0.02 | 0.03 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 29
- counter:runtime.timer_hold_over_1000ms: 2
- counter:runtime.timer_hold_over_250ms: 35

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 2 | 2026-10-31 09:54:27:969 | 2026-10-31 14:12:20:177 |
| reload | 2 | 2026-10-31 09:53:32:812 | 2026-10-31 14:09:31:496 |
| sleep_wake | 3 | 2026-10-31 09:53:15:921 | 2026-10-31 14:09:13:841 |
| network_failure | 3 | 2026-10-31 09:54:33:379 | 2026-10-31 14:14:54:078 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-10-31 09:54:27:969 — ErgoptiPlus session opened =====
===== 2026-10-31 14:12:20:177 — ErgoptiPlus session opened =====
```

**reload**

```
2026-10-31 09:53:32:812 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-31 14:09:31:496 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
```

**sleep_wake**

```
2026-10-31 09:53:15:921 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 10:19:38:422 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 14:09:13:841 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-10-31 09:54:33:379 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 14:12:24:122 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```

</details>
