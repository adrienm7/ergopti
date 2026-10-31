# Field log analysis

Logs: ErgoptiPlus_2026-10-31.log (10047 lines, 9958 records, 75 continuation lines); span 2026-10-31 00:08:36:583 to 2026-10-31 17:44:53:089.
Previous report compared: mac-2026-10-31_150149.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 111 | slow | main_thread.hold over its 250 ms budget | 37 | max 2515 ms at 2026-10-31 14:13:39:139 |
| 2 | 36 | slow | menu.rebuild over its 250 ms budget | 12 | max 472 ms at 2026-10-31 09:59:38:742 |
| 3 | 24 | slow | healthcheck.sync over its 5 ms budget | 8 | max 174 ms at 2026-10-31 09:55:29:675 |
| 4 | 15 | error | [adapters.file_system] append(): destination is not a regular file (named pipe). | 3 | 2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe). |
| 5 | 15 | error | [adapters.file_system] write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 3 | 2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file. |
| 6 | 15 | error | [keystats.context_tracker] Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: Notification has already been registered | 3 | 2026-10-31 14:09:14:863 [ERROR] [keystats.context_tracker] Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:655: Notification has already been registered |
| 7 | 15 | error | [llm.api_ollama] The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 3 | 2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags). |
| 8 | 15 | error | [ollama_deps] Ollama bootstrap failed (exit=<*>) — Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 3 | 2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Ergopti n'a pas pu vérifier sa version épinglée d'Ollama (catalogue de publication ou contrôle d'intégrité) : rien n'a été installé. Envoyez le rapport de diagnostic. |
| 9 | 10 | error | [keymap.layout_rows_build] The number-row layout for '<*>' was not applied (readback_mismatch): key <*> types '<*>', the build holds text '<*>'. | 2 | 2026-10-31 14:13:22:548 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): key 26 types '', the build holds text '&'. |
| 10 | 10 | error | [ollama_deps] Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_download \| # native_http_route kind=direct attempt=<*>/<*> \| # native_http_route kind=direct attempt=<*>/<*> \| {"<*>":true,"<*>":"<*>","<*>":<*>} \| [NATIVE-BOOTSTRAP] stage: python_install \| cpython-<*>-macos-aarch6<*>-none is already installed \| [NATIVE-BOOTSTRAP] stage: python_find \| [OLLAMA-DEPS] stage: runtime_install \| Managed Ollama runtime admission refused. \| [OLLAMA-DEPS] ERROR: stage runtime_install ended with exit <*>. | 2 | 2026-10-31 15:05:10:129 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=562 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \|… |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-10-31 17:38:24:700, last of 4 runs, 1 failed)
- ✅ owned_runtime: pass (2026-10-31 17:38:25:633, last of 4 runs, 0 failed)
- ✅ network: pass (2026-10-31 17:38:31:298, last of 4 runs, 0 failed)
- ✅ toolchain: pass (2026-10-31 17:38:32:609, last of 4 runs, 0 failed)
- ✅ login_items: pass (2026-10-31 17:38:52:756, last of 4 runs, 0 failed)
- ✅ composer: pass (2026-10-31 17:38:54:179, last of 4 runs, 0 failed)
- ✅ boot_cost: pass (2026-10-31 17:38:54:189, last of 4 runs, 0 failed)
- ❌ idle_cost: fail (2026-10-31 17:39:24:268, last of 4 runs, 1 failed)
- ✅ layout_rows: pass (2026-10-31 17:39:28:066, last of 4 runs, 3 failed)
- ✅ permissions: pass (2026-10-31 17:39:28:243, last of 4 runs, 0 failed)
- ❌ event_taps: fail (2026-10-31 17:39:29:103, last of 4 runs, 2 failed)
- ✅ input_sources: pass (2026-10-31 17:39:29:231, last of 4 runs, 0 failed)
- ✅ storage: pass (2026-10-31 17:39:29:763, last of 4 runs, 0 failed)
- ✅ launcher_roles: pass (2026-10-31 17:39:29:865, last of 4 runs, 0 failed)
- ✅ network_hosts: pass (2026-10-31 17:39:32:936, last of 4 runs, 0 failed)
- ✅ ollama_blob_host: pass (2026-10-31 17:39:34:358, last of 4 runs, 0 failed)
- ✅ typing_selftest: pass (2026-10-31 17:39:40:376, last of 4 runs, 0 failed)
- ✅ capslock_chord: pass (2026-10-31 17:39:40:389, last of 4 runs, 0 failed)
- ✅ gesture_frames: pass (2026-10-31 17:39:40:402, last of 4 runs, 0 failed)
- ✅ hotstring_roundtrip: pass (2026-10-31 17:39:42:510, last of 4 runs, 3 failed)
- ✅ prediction_tooltip: pass (2026-10-31 17:39:42:525, last of 4 runs, 1 failed)
- ✅ menu_build: pass (2026-10-31 17:39:42:894, last of 4 runs, 0 failed)
- ✅ ai_local: pass (2026-10-31 17:41:18:039, last of 4 runs, 0 failed)
- ✅ slow_lines: pass (2026-10-31 17:41:18:147, last of 4 runs, 0 failed)
- ✅ fifo_safety: pass (2026-10-31 17:41:19:239, last of 4 runs, 0 failed)
- ✅ local_servers: pass (2026-10-31 17:41:19:378, last of 4 runs, 0 failed)
- ✅ app_health: pass (2026-10-31 17:41:21:068, last of 4 runs, 1 failed)
- ✅ pac_fallback: pass (2026-10-31 17:41:18:024, last of 3 runs, 0 failed)
- ✅ owned_start: pass (2026-10-31 17:38:25:638, last of 2 runs, 0 failed)
- ✅ owned_pause: pass (2026-10-31 17:41:21:074, last of 2 runs, 0 failed)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 29 pass, ❌ 2 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

13 error group(s), 18 warning group(s); 85 occurrence(s); 2 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | adapters.file_system | append(): destination is not a regular file (named pipe). | 3 | 2026-10-31 09:58:46:051 | 2026-10-31 15:05:19:983 |  |
| ERROR | adapters.file_system | write(): cannot preserve metadata for '<*>' — destination is not a regular file. | 3 | 2026-10-31 09:58:46:054 | 2026-10-31 15:05:19:985 |  |
| ERROR | keystats.context_tracker | Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: Notification has already been registered | 3 | 2026-10-31 14:09:14:863 | 2026-10-31 17:37:20:327 |  |
| ERROR | ollama_deps | Ollama bootstrap failed (exit=<*>) — Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 3 | 2026-10-31 14:14:44:840 | 2026-10-31 17:41:08:981 |  |
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 3 | 2026-10-31 14:14:54:078 | 2026-10-31 17:41:18:038 |  |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): key <*> types '<*>', the build holds text '<*>'. | 2 | 2026-10-31 14:13:22:548 | 2026-10-31 15:03:18:699 |  |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 2 | 2026-10-31 15:05:10:129 | 2026-10-31 17:41:08:981 |  |
| ERROR | adapters.keyboard_source_probe | Native keyboard source proof refused: source_changed. | 1 | 2026-10-31 09:55:29:076 | 2026-10-31 09:55:29:076 |  |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (readback_mismatch): the keyboard probe answered source_changed. | 1 | 2026-10-31 09:55:29:429 | 2026-10-31 09:55:29:429 |  |
| ERROR | menu_llm.ollama | Managed model pull retirement is pending (operation_files_not_removed); exact task slot retained. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 |  |
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h ended (code <*>) but its task could not be settled; last output: OLLAMA_PULL_OUTCOME error_row. | 1 | 2026-10-31 09:58:33:523 | 2026-10-31 09:58:33:523 |  |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-10-31 14:14:44:840 | 2026-10-31 14:14:44:840 |  |
| ERROR | keystats.context_tracker | ↑ "Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: Notification has already been registered | 1 | 2026-10-31 15:54:55:871 | 2026-10-31 15:54:55:871 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 16 | 2026-10-31 14:12:24:026 | 2026-10-31 17:44:52:025 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 9 | 2026-10-31 09:53:16:432 | 2026-10-31 17:37:19:838 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 4 | 2026-10-31 09:54:33:379 | 2026-10-31 17:38:25:670 |  |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 3 | 2026-10-31 09:53:15:921 | 2026-10-31 15:39:47:157 |  |
| WARNING | menu.keyboard_layout | Failed to switch active layout to '<*>' / '<*>' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS). | 3 | 2026-10-31 09:55:29:189 | 2026-10-31 15:03:18:565 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 3 | 2026-10-31 14:13:36:620 | 2026-10-31 17:39:41:138 |  |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 3 | 2026-10-31 14:13:40:746 | 2026-10-31 17:39:43:310 |  |
| WARNING | download_window | Progress UI flipped to error state: Ergopti n'<*>'Ollama (catalogue de publication ou contrôle d'<*>'a été installé. Envoyez le rapport de diagnostic. | 3 | 2026-10-31 14:14:44:840 | 2026-10-31 17:41:08:981 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 3 | 2026-10-31 14:18:24:886 | 2026-10-31 17:44:51:638 |  |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 2 | 2026-10-31 14:13:39:139 | 2026-10-31 15:03:34:163 |  |
| WARNING | shortcuts.script_control | Script-control eventtap was disabled by macOS — re-enabling. | 2 | 2026-10-31 14:13:39:656 | 2026-10-31 15:03:34:695 |  |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 2 | 2026-10-31 14:18:26:245 | 2026-10-31 15:08:52:062 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 2 | 2026-10-31 14:18:26:245 | 2026-10-31 15:08:52:062 |  |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-31 09:55:44:252 | 2026-10-31 09:55:44:252 |  |
| WARNING | karabiner.lease | Karabiner lease <*> heartbeat <*> had no clean local CLI transport. | 1 | 2026-10-31 10:48:26:000 | 2026-10-31 10:48:26:000 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> secure_field=<*> destination=<*> ms). | 1 | 2026-10-31 14:17:08:261 | 2026-10-31 14:17:08:261 |  |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; entries=<*> statements=<*>). | 1 | 2026-10-31 14:20:08:381 | 2026-10-31 14:20:08:381 |  |
| WARNING | HotPath | Slow hotstring.expand: <*> ms own, <*> ms total, parent hotstring.match (<*> similar since the last line). | 1 | 2026-10-31 17:39:42:041 | 2026-10-31 17:39:42:041 | new |

<details><summary>One example line per group</summary>

```
2026-10-31 09:58:46:051 [ERROR] [adapters.file_system] append(): destination is not a regular file (named pipe).
```
```
2026-10-31 09:58:46:054 [ERROR] [adapters.file_system] write(): cannot preserve metadata for '/private/var/folders/j8/6707b4c95nz1ygz8g6s7m3fc0000gp/T/ergopti-field-fifo-77295/pipe' — destination is not a regular file.
```
```
2026-10-31 14:09:14:863 [ERROR] [keystats.context_tracker] Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:655: Notification has already been registered
```
```
2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Ergopti n'a pas pu vérifier sa version épinglée d'Ollama (catalogue de publication ou contrôle d'intégrité) : rien n'a été installé. Envoyez le rapport de diagnostic.
```
```
2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```
```
2026-10-31 14:13:22:548 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (readback_mismatch): key 26 types '', the build holds text '&'.
```
```
2026-10-31 15:05:10:129 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=562 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
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
2026-10-31 14:14:44:840 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=562 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
```
```
2026-10-31 15:54:55:871 [ERROR] [keystats.context_tracker] ↑ "Replacement AXValueChanged watcher setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:655: Notification has already been registered
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
2026-10-31 09:53:15:921 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364) held the main thread for 1512 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 51->51 MB.
```
```
2026-10-31 09:55:29:189 [WARNING] [menu.keyboard_layout] Failed to switch active layout to 'Ergopti Field Rows' / 'Ergopti Field Rows' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS).
```
```
2026-10-31 14:13:36:620 [WARNING] [HotPath] Slow preview.rebuild: 7.89 ms own, 7.89 ms total, parent keydown (0 similar since the last line).
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
2026-10-31 14:13:39:139 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236) held the main thread for 2515 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 40->40 MB.
```
```
2026-10-31 14:13:39:656 [WARNING] [shortcuts.script_control] Script-control eventtap was disabled by macOS — re-enabling.
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
```
2026-10-31 17:39:42:041 [WARNING] [HotPath] Slow hotstring.expand: 5.07 ms own, 5.07 ms total, parent hotstring.match (0 similar since the last line).
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 7 | 1674 | 2074 | 1732 | 2074 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 7 | 1206 | 1353 | 1240 | 1353 | no budget declared | — |
| boot.stage:Config-dependent module requires | 7 | 400 | 426 | 396 | 426 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 7 | 197 | 223 | 199 | 223 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 7 | 192 | 216 | 191 | 216 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 7 | 161 | 184 | 157 | 184 | no budget declared | — |
| boot.stage:Config schema migration | 7 | 48 | 103 | 55.64 | 103 | no budget declared | — |
| boot.stage:UI: karabiner.init | 7 | 80.9 | 91.9 | 81.13 | 91.9 | no budget declared | — |
| boot.stage:Keymap engine started | 7 | 53.6 | 63.7 | 46.67 | 63.7 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 7 | 2.1 | 41.5 | 7.73 | 41.5 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 7 | 32.3 | 38.1 | 33.67 | 38.1 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 7 | 10.1 | 13 | 9.46 | 13 | no budget declared | — |
| boot.stage:File watchers armed | 7 | 9.7 | 12.1 | 10.07 | 12.1 | no budget declared | — |
| boot.stage:Accessibility permission | 7 | 7.4 | 8.5 | 4.89 | 8.5 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 7 | 6.5 | 7.4 | 6.34 | 7.4 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 7 | 2.1 | 7.3 | 2.83 | 7.3 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 7 | 5 | 7.2 | 5.39 | 7.2 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 7 | 5.1 | 6.3 | 5.31 | 6.3 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 7 | 4.4 | 5.1 | 4.5 | 5.1 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 7 | 0.4 | 4.2 | 0.96 | 4.2 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 7 | 1.7 | 3.2 | 2.11 | 3.2 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 7 | 2.5 | 2.7 | 2.5 | 2.7 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 7 | 0.7 | 0.9 | 0.69 | 0.9 | no budget declared | — |
| boot.stage:UI: menu ready | 7 | 0.4 | 0.7 | 0.41 | 0.7 | no budget declared | — |

Worst occurrences:

- boot.total: 2074 ms at 2026-10-31 14:12:21:463, 1821 ms at 2026-10-31 09:54:29:318, 1753 ms at 2026-10-31 17:37:39:798
- boot.cpu: 1353 ms at 2026-10-31 14:12:21:463, 1320 ms at 2026-10-31 09:54:29:319, 1218 ms at 2026-10-31 17:37:39:798
- boot.stage:Config-dependent module requires: 426 ms at 2026-10-31 17:41:22:605, 409 ms at 2026-10-31 17:38:22:129, 402 ms at 2026-10-31 14:12:20:611
- boot.stage:Hotstring groups registered (personal + dynamic + common): 223 ms at 2026-10-31 09:54:28:927, 209 ms at 2026-10-31 17:37:39:493, 205 ms at 2026-10-31 14:12:21:084
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 216 ms at 2026-10-31 14:12:21:445, 211 ms at 2026-10-31 09:54:29:305, 192 ms at 2026-10-31 15:01:51:952
- boot.stage:Shortcuts pre-start: 184 ms at 2026-10-31 17:41:22:902, 167 ms at 2026-10-31 09:54:28:655, 161 ms at 2026-10-31 14:12:20:835
- boot.stage:Config schema migration: 103 ms at 2026-10-31 17:41:22:709, 52.4 ms at 2026-10-31 09:54:28:471, 50 ms at 2026-10-31 17:37:39:064
- boot.stage:UI: karabiner.init: 91.9 ms at 2026-10-31 09:54:29:093, 86.2 ms at 2026-10-31 17:37:39:614, 83.7 ms at 2026-10-31 14:12:21:229
- boot.stage:Keymap engine started: 63.7 ms at 2026-10-31 17:38:22:631, 62.5 ms at 2026-10-31 09:54:29:000, 58.9 ms at 2026-10-31 15:02:13:091
- boot.stage:TOML hotstring cache wired: 41.5 ms at 2026-10-31 09:54:28:026, 2.7 ms at 2026-10-31 17:38:21:720, 2.3 ms at 2026-10-31 14:12:20:208
- boot.stage:TOML discovery + ordering: 38.1 ms at 2026-10-31 17:37:39:284, 37 ms at 2026-10-31 09:54:28:704, 36 ms at 2026-10-31 17:41:22:951
- boot.stage:Path: native asynchronous logger transport committed: 13 ms at 2026-10-31 14:12:20:191, 10.4 ms at 2026-10-31 09:54:27:981, 10.3 ms at 2026-10-31 17:38:21:714

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 5 | 2475 | 169967 | 46722 | 169967 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| reload.total | 3 | 1875 | 1991 | 1900 | 1991 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 169967 ms at 2026-10-31 14:09:31:496, 56506 ms at 2026-10-31 09:53:32:812, 2475 ms at 2026-10-31 17:37:37:323
- reload.total: 1991 ms at 2026-10-31 17:37:39:799, 1875 ms at 2026-10-31 17:41:23:440, 1835 ms at 2026-10-31 15:01:51:965

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 13 | 302 | 472 | 325 | 472 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (12) |
| phase:menu.rebuild | 36 | — | — | 341 | 687 | no budget declared | — |
| phase:menu_item.keyboard_layout | 36 | — | — | 144 | 463 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 36 | — | — | 37.43 | 375 | no budget declared | — |
| menu.submenu:keyboard_layout | 13 | 102 | 274 | 125 | 274 | no budget declared | — |
| phase:menu_item.shortcuts | 36 | — | — | 52.43 | 242 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 36 | — | — | 105 | 190 | no budget declared | — |
| menu.submenu:gestures | 13 | 41.1 | 70.5 | 43.83 | 70.5 | no budget declared | — |
| phase:menu_item.gestures | 36 | — | — | 45.21 | 70.46 | no budget declared | — |
| menu.submenu:shortcuts | 13 | 47 | 50.3 | 45.04 | 50.3 | no budget declared | — |
| phase:menu_item.hotstrings | 36 | — | — | 30.98 | 40.23 | no budget declared | — |
| menu.submenu:hotstrings | 12 | 32.5 | 40.2 | 32.63 | 40.2 | no budget declared | — |
| menu.submenu:llm | 12 | 30 | 38.2 | 31.24 | 38.2 | no budget declared | — |
| phase:menu_item.llm | 36 | — | — | 32.17 | 38.18 | no budget declared | — |
| phase:menu_item.metrics | 36 | — | — | 8.7 | 33.33 | no budget declared | — |
| menu.submenu:metrics | 2 | 30.6 | 33.3 | 31.95 | 33.3 | no budget declared | — |
| phase:menu_item.about | 36 | — | — | 8.26 | 28.24 | no budget declared | — |
| menu.app_exclusions | 13 | 1 | 18.3 | 5.34 | 18.3 | no budget declared | — |
| phase:menu_item.debug | 36 | — | — | 4.03 | 9.96 | no budget declared | — |
| phase:menu_item.tap_holds | 36 | — | — | 1.09 | 8.24 | no budget declared | — |
| phase:menu_item.configuration | 36 | — | — | 2.22 | 3.44 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 36 | — | — | 0.84 | 1.42 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 36 | — | — | 0.2 | 0.31 | no budget declared | — |
| phase:menu_item.apps | 36 | — | — | 0.17 | 0.21 | no budget declared | — |
| phase:menu_item.language | 36 | — | — | 0.04 | 0.05 | no budget declared | — |
| phase:menu_item.quit | 36 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.reload | 36 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 472 ms at 2026-10-31 09:59:38:742, 415 ms at 2026-10-31 15:08:49:414, 393 ms at 2026-10-31 14:18:21:639
- menu.submenu:keyboard_layout: 274 ms at 2026-10-31 09:59:38:742, 237 ms at 2026-10-31 15:08:49:414, 183 ms at 2026-10-31 14:18:21:639
- menu.submenu:gestures: 70.5 ms at 2026-10-31 14:18:21:639, 51.4 ms at 2026-10-31 09:54:31:785, 49.1 ms at 2026-10-31 15:03:35:444
- menu.submenu:shortcuts: 50.3 ms at 2026-10-31 17:38:25:537, 49.7 ms at 2026-10-31 14:18:21:639, 49 ms at 2026-10-31 14:12:24:025
- menu.submenu:hotstrings: 40.2 ms at 2026-10-31 09:55:30:720, 37.3 ms at 2026-10-31 09:59:38:742, 36.4 ms at 2026-10-31 09:55:29:074
- menu.submenu:llm: 38.2 ms at 2026-10-31 09:59:38:742, 35.4 ms at 2026-10-31 14:13:40:398, 33.2 ms at 2026-10-31 17:39:42:894
- menu.submenu:metrics: 33.3 ms at 2026-10-31 14:12:24:025, 30.6 ms at 2026-10-31 15:02:15:884
- menu.app_exclusions: 18.3 ms at 2026-10-31 14:12:23:923, 17.6 ms at 2026-10-31 15:02:15:790, 15.2 ms at 2026-10-31 17:38:25:440

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 37 | 501 | 2515 | 702 | 2515 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (37) |

Worst occurrences:

- main_thread.hold: 2515 ms at 2026-10-31 14:13:39:139 (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236), 2515 ms at 2026-10-31 15:03:34:163 (.../static/ergopti_plus/macos/modules/keymap/llm_bridge.lua:236), 1810 ms at 2026-10-31 09:55:44:252 (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610)

### Hotstrings

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:hotstring.expand | 1 | 5.07 | 5.07 | 5.07 | 5.07 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:preview.rebuild | 3 | 7.89 | 8.24 | 7.07 | 8.24 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (3) |

Worst occurrences:

- hotpath:preview.rebuild: 8.24 ms at 2026-10-31 15:03:31:646, 7.89 ms at 2026-10-31 14:13:36:620, 5.07 ms at 2026-10-31 17:39:41:138

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 1 | 691 | 691 | 691 | 691 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (1) |
| healthcheck.sync | 8 | 108 | 174 | 125 | 174 | 5 ms (stated in the log line) | ❌ over (8) |

Worst occurrences:

- healthcheck.sync: 174 ms at 2026-10-31 09:55:29:675, 153 ms at 2026-10-31 14:13:23:040, 150 ms at 2026-10-31 17:39:43:080

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 3 | — | — | 20010 | 20013 | no budget declared | — |
| phase:process.python3 | 42 | — | — | 685 | 7889 | no budget declared | — |
| phase:process.ErgoptiPlus | 87 | — | — | 299 | 3325 | no budget declared | — |
| phase:process.defaults | 3533 | — | — | 24.14 | 1733 | no budget declared | — |
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
| phase:shell.ls | 57 | — | — | 42.73 | 95.68 | no budget declared | — |
| phase:shell.ioreg | 3 | — | — | 65.29 | 94.24 | no budget declared | — |
| phase:shell.curl | 3 | — | — | 81.17 | 93.82 | no budget declared | — |
| phase:process.shortcuts | 6 | — | — | 66.69 | 91.89 | no budget declared | — |
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

- counter:menu.refresh_requested: 38
- counter:runtime.timer_hold_over_1000ms: 4
- counter:runtime.timer_hold_over_250ms: 51

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 7 | 2026-10-31 09:54:27:969 | 2026-10-31 17:41:22:164 |
| stop | 3 | 2026-10-31 15:01:50:134 | 2026-10-31 17:41:21:568 |
| reload | 5 | 2026-10-31 09:53:32:812 | 2026-10-31 17:41:21:088 |
| sleep_wake | 6 | 2026-10-31 09:53:15:921 | 2026-10-31 17:37:17:779 |
| network_failure | 7 | 2026-10-31 09:54:33:379 | 2026-10-31 17:41:18:038 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-10-31 09:54:27:969 — ErgoptiPlus session opened =====
===== 2026-10-31 14:12:20:177 — ErgoptiPlus session opened =====
===== 2026-10-31 15:01:50:841 — ErgoptiPlus session opened =====
===== 2026-10-31 15:02:12:204 — ErgoptiPlus session opened =====
===== 2026-10-31 17:37:38:600 — ErgoptiPlus session opened =====
===== 2026-10-31 17:38:21:703 — ErgoptiPlus session opened =====
===== 2026-10-31 17:41:22:164 — ErgoptiPlus session opened =====
```

**stop**

```
2026-10-31 15:01:50:134 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-31 17:37:37:815 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-31 17:41:21:568 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-10-31 09:53:32:812 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-31 14:09:31:496 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-31 15:01:49:656 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-31 17:37:37:323 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-31 17:41:21:088 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-10-31 09:53:15:921 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 10:19:38:422 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 14:09:13:841 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 15:01:34:668 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 15:39:22:507 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-31 17:37:17:779 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-10-31 09:54:33:379 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 14:12:24:122 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 14:14:54:078 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
2026-10-31 15:02:16:192 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 15:05:18:880 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
2026-10-31 17:38:25:670 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-31 17:41:18:038 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```

</details>
