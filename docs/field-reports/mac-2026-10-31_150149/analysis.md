# Field log analysis

Logs: ErgoptiPlus_2026-10-31.log (6894 lines, 6844 records, 42 continuation lines); span 2026-10-31 00:08:36:583 to 2026-10-31 15:08:52:096.
Previous report compared: mac-2026-10-31_140931.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 87 | slow | main_thread.hold over its 250 ms budget | 29 | max 2515 ms at 2026-10-31 14:13:39:139 |
| 2 | 27 | slow | menu.rebuild over its 250 ms budget | 9 | max 472 ms at 2026-10-31 09:59:38:742 |
| 3 | 18 | slow | healthcheck.sync over its 5 ms budget | 6 | max 174 ms at 2026-10-31 09:55:29:675 |
| 4 | 15 | error | [adapters.file_system] append(): destination is not a regular file (named pipe). | 3 | 2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe). |
| 5 | 15 | error | [adapters.file_system] write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 3 | 2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file. |
| 6 | 10 | error | [keymap.layout_rows_build] The number-row layout for '<*>' was not applied (readback_mismatch): key <*> types '<*>', the build holds text '<*>'. | 2 | 2026-10-31 14:13:22:548 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): key 26 types '', the build holds text '&'. |
| 7 | 10 | error | [llm.api_ollama] The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 2 | 2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags). |
| 8 | 10 | error | [ollama_deps] Ollama bootstrap failed (exit=<*>) — Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 2 | 2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Ergopti n'a pas pu vérifier sa version épinglée d'Ollama (catalogue de publication ou contrôle d'intégrité) : rien n'a été installé. Envoyez le rapport de diagnostic. |
| 9 | 6 | slow | hotpath:preview.rebuild over its 5 ms budget | 2 | max 8.24 ms at 2026-10-31 15:03:31:646 |
| 10 | 6 | slow | reload.request_to_boot over its 4000 ms budget | 2 | max 169967 ms at 2026-10-31 14:09:31:496 |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-10-31 15:02:16:057, last of 3 runs, 1 failed)
- ✅ owned_runtime: pass (2026-10-31 15:02:16:159, last of 3 runs, 0 failed)
- ✅ network: pass (2026-10-31 15:02:24:136, last of 3 runs, 0 failed)
- ✅ toolchain: pass (2026-10-31 15:02:25:560, last of 3 runs, 0 failed)
- ✅ login_items: pass (2026-10-31 15:02:45:721, last of 3 runs, 0 failed)
- ✅ composer: pass (2026-10-31 15:02:47:058, last of 3 runs, 0 failed)
- ✅ boot_cost: pass (2026-10-31 15:02:47:066, last of 3 runs, 0 failed)
- ✅ idle_cost: pass (2026-10-31 15:03:17:145, last of 3 runs, 0 failed)
- ❌ layout_rows: fail (2026-10-31 15:03:19:316, last of 3 runs, 3 failed)
- ✅ permissions: pass (2026-10-31 15:03:19:515, last of 3 runs, 0 failed)
- ❌ event_taps: fail (2026-10-31 15:03:20:305, last of 3 runs, 1 failed)
- ✅ input_sources: pass (2026-10-31 15:03:20:410, last of 3 runs, 0 failed)
- ✅ storage: pass (2026-10-31 15:03:21:033, last of 3 runs, 0 failed)
- ✅ launcher_roles: pass (2026-10-31 15:03:21:127, last of 3 runs, 0 failed)
- ✅ network_hosts: pass (2026-10-31 15:03:23:579, last of 3 runs, 0 failed)
- ✅ ollama_blob_host: pass (2026-10-31 15:03:24:867, last of 3 runs, 0 failed)
- ✅ typing_selftest: pass (2026-10-31 15:03:30:875, last of 3 runs, 0 failed)
- ✅ capslock_chord: pass (2026-10-31 15:03:30:884, last of 3 runs, 0 failed)
- ✅ gesture_frames: pass (2026-10-31 15:03:30:895, last of 3 runs, 0 failed)
- ❌ hotstring_roundtrip: fail (2026-10-31 15:03:35:092, last of 3 runs, 3 failed)
- ✅ prediction_tooltip: pass (2026-10-31 15:03:35:127, last of 3 runs, 1 failed)
- ✅ menu_build: pass (2026-10-31 15:03:35:445, last of 3 runs, 0 failed)
- ✅ ai_local: pass (2026-10-31 15:05:18:880, last of 3 runs, 0 failed)
- ✅ slow_lines: pass (2026-10-31 15:05:18:960, last of 3 runs, 0 failed)
- ✅ fifo_safety: pass (2026-10-31 15:05:20:047, last of 3 runs, 0 failed)
- ✅ local_servers: pass (2026-10-31 15:05:20:169, last of 3 runs, 0 failed)
- ✅ app_health: pass (2026-10-31 15:05:21:718, last of 3 runs, 1 failed)
- ✅ pac_fallback: pass (2026-10-31 15:05:18:864, last of 2 runs, 0 failed)
- ✅ owned_start: pass (2026-10-31 15:02:16:163)
- ✅ owned_pause: pass (2026-10-31 15:05:21:724)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 28 pass, ❌ 3 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

12 error group(s), 17 warning group(s); 62 occurrence(s); 2 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | adapters.file_system | append(): destination is not a regular file (named pipe). | 3 | 2026-10-31 09:58:46:051 | 2026-10-31 15:05:19:983 |  |
| ERROR | adapters.file_system | write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 3 | 2026-10-31 09:58:46:054 | 2026-10-31 15:05:19:985 |  |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): key <*> types '<*>', the build holds text '<*>'. | 2 | 2026-10-31 14:13:22:548 | 2026-10-31 15:03:18:699 |  |
| ERROR | ollama_deps | Ollama bootstrap failed (exit=<*>) — Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 2 | 2026-10-31 14:14:44:840 | 2026-10-31 15:05:10:129 |  |
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 2 | 2026-10-31 14:14:54:078 | 2026-10-31 15:05:18:880 |  |
| ERROR | adapters.keyboard_source_probe | Native keyboard source proof refused: source_changed. | 1 | 2026-10-31 09:55:29:076 | 2026-10-31 09:55:29:076 |  |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): the keyboard probe answered source_changed. | 1 | 2026-10-31 09:55:29:429 | 2026-10-31 09:55:29:429 |  |
| ERROR | menu_llm.ollama | Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 |  |
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h ended (code <*>) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 |  |
| ERROR | keystats.context_tracker | Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: Notification has already been registered | 1 | 2026-10-31 14:09:14:863 | 2026-10-31 14:09:14:863 |  |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-10-31 14:14:44:840 | 2026-10-31 14:14:44:840 |  |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-10-31 15:05:10:129 | 2026-10-31 15:05:10:129 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 10 | 2026-10-31 14:12:24:026 | 2026-10-31 15:08:51:513 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 5 | 2026-10-31 09:53:16:432 | 2026-10-31 15:01:35:268 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 3 | 2026-10-31 09:54:33:379 | 2026-10-31 15:02:16:192 |  |
| WARNING | menu.keyboard_layout | Failed to switch active layout to '<*>' / '<*>' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS). | 3 | 2026-10-31 09:55:29:189 | 2026-10-31 15:03:18:565 |  |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 2 | 2026-10-31 09:53:15:921 | 2026-10-31 15:01:36:785 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 2 | 2026-10-31 14:13:36:620 | 2026-10-31 15:03:31:646 |  |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 2 | 2026-10-31 14:13:39:139 | 2026-10-31 15:03:34:163 |  |
| WARNING | shortcuts.script_control | Script-control eventtap was disabled by macOS — re-enabling. | 2 | 2026-10-31 14:13:39:656 | 2026-10-31 15:03:34:695 |  |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 2 | 2026-10-31 14:13:40:746 | 2026-10-31 15:03:35:701 |  |
| WARNING | download_window | Progress UI flipped to error state: Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 2 | 2026-10-31 14:14:44:840 | 2026-10-31 15:05:10:129 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 2 | 2026-10-31 14:18:24:886 | 2026-10-31 15:08:51:058 |  |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 2 | 2026-10-31 14:18:26:245 | 2026-10-31 15:08:52:062 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 2 | 2026-10-31 14:18:26:245 | 2026-10-31 15:08:52:062 |  |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 09:55:44:252 | 2026-10-31 09:55:44:252 |  |
| WARNING | karabiner.lease | Karabiner lease <*> heartbeat <*> had no clean local CLI transport. | 1 | 2026-10-31 10:48:26:000 | 2026-10-31 10:48:26:000 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> secure_field=<*> destination=<*> ms). | 1 | 2026-10-31 14:17:08:261 | 2026-10-31 14:17:08:261 |  |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; entries=<*> statements=<*>). | 1 | 2026-10-31 14:20:08:381 | 2026-10-31 14:20:08:381 | new |

<details><summary>One example line per group</summary>

```
2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe).
```
```
2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file.
```
```
2026-10-31 14:13:22:548 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): key 26 types '', the build holds text '&'.
```
```
2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Ergopti n'a pas pu vérifier sa version épinglée d'Ollama (catalogue de publication ou contrôle d'intégrité) : rien n'a été installé. Envoyez le rapport de diagnostic.
```
```
2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
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
2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=562 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
```
```
2026-10-31 15:05:10:129 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=562 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
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
2026-10-31 14:18:24:886 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```
```
2026-10-31 14:18:26:245 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil.
```
```
2026-10-31 14:18:26:245 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried.
```
```
2026-10-31 09:55:44:252 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1810 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 32->32 MB.
```
```
2026-10-31 10:48:26:000 [WARNING] [karabiner.lease] Karabiner lease 0adf0f18109444b7b9f632389103396a heartbeat 253 had no clean local CLI transport.
```
```
2026-10-31 14:17:08:261 [WARNING] [keymap.utils] Slow ignored-window probe 266 ms (watchers=0 focused_window=265 application=0 app_name=0 title=0 context_watchers=0 secure_field=0 destination=0 ms).
```
```
2026-10-31 14:20:08:381 [WARNING] [keystats.log_manager] Slow ingest tick 691 ms (drain=0 foreign=0 outbox=690 read=0 build=0 apply=0 commit=0 append=0 notify=0 ms; entries=0 statements=0).
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 4 | 1609 | 2074 | 1768 | 2074 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 4 | 1200 | 1353 | 1267 | 1353 | no budget declared | — |
| boot.stage:Config-dependent module requires | 4 | 374 | 402 | 385 | 402 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 4 | 185 | 223 | 199 | 223 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 4 | 192 | 216 | 202 | 216 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 4 | 154 | 167 | 153 | 167 | no budget declared | — |
| boot.stage:UI: karabiner.init | 4 | 80.9 | 91.9 | 82.6 | 91.9 | no budget declared | — |
| boot.stage:Keymap engine started | 4 | 53.6 | 62.5 | 52.05 | 62.5 | no budget declared | — |
| boot.stage:Config schema migration | 4 | 47.7 | 52.4 | 47.62 | 52.4 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 4 | 1.8 | 41.5 | 11.82 | 41.5 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 4 | 32 | 37 | 32.62 | 37 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 4 | 10.1 | 13 | 10.5 | 13 | no budget declared | — |
| boot.stage:File watchers armed | 4 | 9.3 | 11.4 | 9.72 | 11.4 | no budget declared | — |
| boot.stage:Accessibility permission | 4 | 7.4 | 8 | 6.05 | 8 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 4 | 2.2 | 7.3 | 3.48 | 7.3 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 4 | 5 | 7.2 | 5.67 | 7.2 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 4 | 5.9 | 7.1 | 6.3 | 7.1 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 4 | 5.1 | 5.3 | 4.97 | 5.3 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 4 | 4.2 | 4.8 | 4.35 | 4.8 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 4 | 0.6 | 4.2 | 1.45 | 4.2 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 4 | 1.7 | 3.2 | 2.27 | 3.2 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 4 | 2.4 | 2.6 | 2.45 | 2.6 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 4 | 0.6 | 0.7 | 0.6 | 0.7 | no budget declared | — |
| boot.stage:UI: menu ready | 4 | 0.4 | 0.5 | 0.4 | 0.5 | no budget declared | — |

Worst occurrences:

- boot.total: 2074 ms at 2026-10-31 14:12:21:463, 1821 ms at 2026-10-31 09:54:29:318, 1609 ms at 2026-10-31 15:01:51:964
- boot.cpu: 1353 ms at 2026-10-31 14:12:21:463, 1320 ms at 2026-10-31 09:54:29:319, 1200 ms at 2026-10-31 15:01:51:965
- boot.stage:Config-dependent module requires: 402 ms at 2026-10-31 14:12:20:611, 392 ms at 2026-10-31 09:54:28:418, 374 ms at 2026-10-31 15:01:51:230
- boot.stage:Hotstring groups registered (personal + dynamic + common): 223 ms at 2026-10-31 09:54:28:927, 205 ms at 2026-10-31 14:12:21:084, 185 ms at 2026-10-31 15:01:51:647
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 216 ms at 2026-10-31 14:12:21:445, 211 ms at 2026-10-31 09:54:29:305, 192 ms at 2026-10-31 15:01:51:952
- boot.stage:Shortcuts pre-start: 167 ms at 2026-10-31 09:54:28:655, 161 ms at 2026-10-31 14:12:20:835, 154 ms at 2026-10-31 15:02:12:804
- boot.stage:UI: karabiner.init: 91.9 ms at 2026-10-31 09:54:29:093, 83.7 ms at 2026-10-31 14:12:21:229, 80.9 ms at 2026-10-31 15:02:13:172
- boot.stage:Keymap engine started: 62.5 ms at 2026-10-31 09:54:29:000, 58.9 ms at 2026-10-31 15:02:13:091, 53.6 ms at 2026-10-31 14:12:21:145
- boot.stage:Config schema migration: 52.4 ms at 2026-10-31 09:54:28:471, 48 ms at 2026-10-31 15:01:51:279, 47.7 ms at 2026-10-31 14:12:20:659
- boot.stage:TOML hotstring cache wired: 41.5 ms at 2026-10-31 09:54:28:026, 2.3 ms at 2026-10-31 14:12:20:208, 1.8 ms at 2026-10-31 15:01:50:856
- boot.stage:TOML discovery + ordering: 37 ms at 2026-10-31 09:54:28:704, 32.3 ms at 2026-10-31 14:12:20:878, 32 ms at 2026-10-31 15:01:51:461
- boot.stage:Path: native asynchronous logger transport committed: 13 ms at 2026-10-31 14:12:20:191, 10.4 ms at 2026-10-31 09:54:27:981, 10.1 ms at 2026-10-31 15:02:12:215

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 3 | 56506 | 169967 | 76260 | 169967 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| reload.total | 1 | 1835 | 1835 | 1835 | 1835 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 169967 ms at 2026-10-31 14:09:31:496, 56506 ms at 2026-10-31 09:53:32:812, 2308 ms at 2026-10-31 15:01:49:656

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 10 | 291 | 472 | 327 | 472 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (9) |
| phase:menu.rebuild | 33 | — | — | 339 | 687 | no budget declared | — |
| phase:menu_item.keyboard_layout | 33 | — | — | 142 | 463 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 33 | — | — | 38.78 | 375 | no budget declared | — |
| menu.submenu:keyboard_layout | 10 | 80.4 | 274 | 130 | 274 | no budget declared | — |
| phase:menu_item.shortcuts | 33 | — | — | 52.73 | 242 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 33 | — | — | 102 | 190 | no budget declared | — |
| menu.submenu:gestures | 10 | 41.1 | 70.5 | 45.18 | 70.5 | no budget declared | — |
| phase:menu_item.gestures | 33 | — | — | 45.44 | 70.46 | no budget declared | — |
| menu.submenu:shortcuts | 10 | 47 | 49.7 | 44.31 | 49.7 | no budget declared | — |
| phase:menu_item.hotstrings | 33 | — | — | 30.74 | 40.23 | no budget declared | — |
| menu.submenu:hotstrings | 9 | 32.5 | 40.2 | 32.57 | 40.2 | no budget declared | — |
| menu.submenu:llm | 9 | 30.2 | 38.2 | 31.43 | 38.2 | no budget declared | — |
| phase:menu_item.llm | 33 | — | — | 32 | 38.18 | no budget declared | — |
| phase:menu_item.metrics | 33 | — | — | 8.82 | 33.33 | no budget declared | — |
| menu.submenu:metrics | 2 | 30.6 | 33.3 | 31.95 | 33.3 | no budget declared | — |
| phase:menu_item.about | 33 | — | — | 8.45 | 28.24 | no budget declared | — |
| menu.app_exclusions | 10 | 0.9 | 18.3 | 5.2 | 18.3 | no budget declared | — |
| phase:menu_item.debug | 33 | — | — | 4.05 | 9.96 | no budget declared | — |
| phase:menu_item.tap_holds | 33 | — | — | 1.11 | 8.24 | no budget declared | — |
| phase:menu_item.configuration | 33 | — | — | 2.22 | 3.44 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 33 | — | — | 0.84 | 1.42 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 33 | — | — | 0.21 | 0.31 | no budget declared | — |
| phase:menu_item.apps | 33 | — | — | 0.17 | 0.21 | no budget declared | — |
| phase:menu_item.language | 33 | — | — | 0.04 | 0.05 | no budget declared | — |
| phase:menu_item.quit | 33 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.reload | 33 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 472 ms at 2026-10-31 09:59:38:742, 415 ms at 2026-10-31 15:08:49:414, 393 ms at 2026-10-31 14:18:21:639
- menu.submenu:keyboard_layout: 274 ms at 2026-10-31 09:59:38:742, 237 ms at 2026-10-31 15:08:49:414, 183 ms at 2026-10-31 14:18:21:639
- menu.submenu:gestures: 70.5 ms at 2026-10-31 14:18:21:639, 51.4 ms at 2026-10-31 09:54:31:785, 49.1 ms at 2026-10-31 15:03:35:444
- menu.submenu:shortcuts: 49.7 ms at 2026-10-31 14:18:21:639, 49 ms at 2026-10-31 14:12:24:025, 47.7 ms at 2026-10-31 09:59:38:742
- menu.submenu:hotstrings: 40.2 ms at 2026-10-31 09:55:30:720, 37.3 ms at 2026-10-31 09:59:38:742, 36.4 ms at 2026-10-31 09:55:29:074
- menu.submenu:llm: 38.2 ms at 2026-10-31 09:59:38:742, 35.4 ms at 2026-10-31 14:13:40:398, 32.1 ms at 2026-10-31 15:03:35:444
- menu.submenu:metrics: 33.3 ms at 2026-10-31 14:12:24:025, 30.6 ms at 2026-10-31 15:02:15:884
- menu.app_exclusions: 18.3 ms at 2026-10-31 14:12:23:923, 17.6 ms at 2026-10-31 15:02:15:790, 9.5 ms at 2026-10-31 09:54:31:685

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 29 | 502 | 2515 | 721 | 2515 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (29) |

Worst occurrences:

- main_thread.hold: 2515 ms at 2026-10-31 14:13:39:139 (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236), 2515 ms at 2026-10-31 15:03:34:163 (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236), 1810 ms at 2026-10-31 09:55:44:252 (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610)

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:preview.rebuild | 2 | 7.89 | 8.24 | 8.06 | 8.24 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |

Worst occurrences:

- hotpath:preview.rebuild: 8.24 ms at 2026-10-31 15:03:31:646, 7.89 ms at 2026-10-31 14:13:36:620

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 1 | 691 | 691 | 691 | 691 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (1) |
| healthcheck.sync | 6 | 95.1 | 174 | 124 | 174 | 5 ms (stated in the log line) | ❌ over (6) |

Worst occurrences:

- healthcheck.sync: 174 ms at 2026-10-31 09:55:29:675, 153 ms at 2026-10-31 14:13:23:040, 145 ms at 2026-10-31 15:03:19:143

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 3 | — | — | 20010 | 20013 | no budget declared | — |
| phase:process.python3 | 42 | — | — | 685 | 7889 | no budget declared | — |
| phase:process.ErgoptiPlus | 80 | — | — | 280 | 3325 | no budget declared | — |
| phase:process.defaults | 2322 | — | — | 27.33 | 1733 | no budget declared | — |
| phase:process.vmmap | 2 | — | — | 1567 | 1608 | no budget declared | — |
| phase:process.sh | 9 | — | — | 386 | 1056 | no budget declared | — |
| phase:boot.stage | 72 | — | — | 75.17 | 760 | no budget declared | — |
| phase:boot.requires | 48 | — | — | 68.31 | 757 | no budget declared | — |
| phase:process.spctl | 3 | — | — | 684 | 752 | no budget declared | — |
| phase:process.sqlite3 | 3 | — | — | 598 | 608 | no budget declared | — |
| phase:process.pgrep | 12 | — | — | 84.11 | 591 | no budget declared | — |
| phase:boot.stage_cpu | 72 | — | — | 53.44 | 442 | no budget declared | — |
| phase:process.systemextensionsctl | 3 | — | — | 105 | 276 | no budget declared | — |
| phase:process.brew | 3 | — | — | 152 | 167 | no budget declared | — |
| phase:process.codesign | 10 | — | — | 82.15 | 165 | no budget declared | — |
| phase:shell.other | 3 | — | — | 106 | 115 | no budget declared | — |
| phase:shell.systemextensionsctl | 3 | — | — | 90.3 | 113 | no budget declared | — |
| phase:process.bash | 3 | — | — | 92.11 | 106 | no budget declared | — |
| phase:shell.ioreg | 3 | — | — | 65.29 | 94.24 | no budget declared | — |
| phase:shell.curl | 3 | — | — | 81.17 | 93.82 | no budget declared | — |
| phase:process.shortcuts | 6 | — | — | 66.69 | 91.89 | no budget declared | — |
| phase:shell.ls | 53 | — | — | 42.22 | 87.92 | no budget declared | — |
| phase:process.awk | 5 | — | — | 38.05 | 72.73 | no budget declared | — |
| phase:shell.cp | 13 | — | — | 41.96 | 71.86 | no budget declared | — |
| phase:shell.sw_vers | 3 | — | — | 63.37 | 68.82 | no budget declared | — |
| phase:process.mkdir | 12 | — | — | 31.41 | 64.82 | no budget declared | — |
| phase:shell.mkdir | 9 | — | — | 40.36 | 64.77 | no budget declared | — |
| phase:process.Application | 3 | — | — | 58.93 | 61.13 | no budget declared | — |
| phase:process.open | 1 | — | — | 50.96 | 50.96 | no budget declared | — |
| phase:shell.find | 3 | — | — | 38.57 | 49.6 | no budget declared | — |
| phase:process.ps | 11 | — | — | 14.98 | 38.15 | no budget declared | — |
| phase:process.grep | 6 | — | — | 13.23 | 33.52 | no budget declared | — |
| phase:process.xmllint | 24 | — | — | 6.03 | 32.87 | no budget declared | — |
| phase:process.memory_pressure | 2 | — | — | 22.69 | 31.79 | no budget declared | — |
| phase:hotstring_load.common_file | 6 | — | — | 11.88 | 20.65 | no budget declared | — |
| phase:process.plutil | 12 | — | — | 6.39 | 14.49 | no budget declared | — |
| phase:hotpath.keydown | 29 | — | — | 2.28 | 10.4 | no budget declared | — |
| phase:process.launchctl | 3 | — | — | 7.49 | 9.11 | no budget declared | — |
| phase:process.scutil | 3 | — | — | 8.17 | 8.71 | no budget declared | — |
| phase:hotpath.preview.rebuild | 8 | — | — | 2.49 | 8.24 | no budget declared | — |
| phase:preview.total | 12 | — | — | 1.88 | 8.24 | no budget declared | — |
| phase:process.mkfifo | 1 | — | — | 7.27 | 7.27 | no budget declared | — |
| phase:toml.parse | 86 | — | — | 1.26 | 5.6 | no budget declared | — |
| phase:preview.providers | 12 | — | — | 0.56 | 1.34 | no budget declared | — |
| phase:hotpath.hotstring.match | 8 | — | — | 0.04 | 0.1 | no budget declared | — |
| phase:preview.resolve | 12 | — | — | 0.01 | 0.04 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 33
- counter:runtime.timer_hold_over_1000ms: 3
- counter:runtime.timer_hold_over_250ms: 45

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 4 | 2026-10-31 09:54:27:969 | 2026-10-31 15:02:12:204 |
| stop | 1 | 2026-10-31 15:01:50:134 | 2026-10-31 15:01:50:134 |
| reload | 3 | 2026-10-31 09:53:32:812 | 2026-10-31 15:01:49:656 |
| sleep_wake | 4 | 2026-10-31 09:53:15:921 | 2026-10-31 15:01:34:668 |
| network_failure | 5 | 2026-10-31 09:54:33:379 | 2026-10-31 15:05:18:880 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-10-31 09:54:27:969 — ErgoptiPlus session opened =====
===== 2026-10-31 14:12:20:177 — ErgoptiPlus session opened =====
===== 2026-10-31 15:01:50:841 — ErgoptiPlus session opened =====
===== 2026-10-31 15:02:12:204 — ErgoptiPlus session opened =====
```

**stop**

```
2026-10-31 15:01:50:134 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-10-31 09:53:32:812 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-31 14:09:31:496 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-31 15:01:49:656 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
```

**sleep_wake**

```
2026-10-31 09:53:15:921 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 10:19:38:422 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 14:09:13:841 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 15:01:34:668 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-10-31 09:54:33:379 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 14:12:24:122 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
2026-10-31 15:02:16:192 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 15:05:18:880 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```

</details>
