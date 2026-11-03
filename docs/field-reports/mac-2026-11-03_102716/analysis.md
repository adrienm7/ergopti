# Field log analysis

Logs: ErgoptiPlus_2026-11-03.log (2780 lines, 2773 records, 3 continuation lines); span 2026-11-03 00:07:48:582 to 2026-11-03 10:34:56:553.
Previous report compared: mac-2026-11-02_102408.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 54 | slow | main_thread.hold over its 250 ms budget | 18 | max 1005 ms at 2026-11-03 09:50:58:126 |
| 2 | 5 | error | [llm.api_ollama] The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 1 | 2026-11-03 10:31:17:313 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags). |
| 3 | 5 | error | [ollama_deps] Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_download \| # native_http_route kind=direct attempt=<*>/<*> \| # native_http_route kind=direct attempt=<*>/<*> \| {"<*>":"<*>","<*>":true,"<*>":<*>} \| [NATIVE-BOOTSTRAP] stage: python_install \| cpython-<*>-macos-aarch6<*>-none is already installed \| [NATIVE-BOOTSTRAP] stage: python_find \| [OLLAMA-DEPS] stage: runtime_install \| OLLAMA_MANAGED_CATALOGUE_MISSING \| [OLLAMA-DEPS] ERROR: stage runtime_install ended with exit <*>. | 1 | 2026-11-03 10:31:07:659 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=553 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \|… |
| 4 | 5 | error | [ollama_deps] Ollama bootstrap failed (exit=<*>) — Cette app de développement n'<*>'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xcode sont nécessaires). | 1 | 2026-11-03 10:31:07:659 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Cette app de développement n'a pas encore construit son Ollama épinglé depuis les sources du clone : rien n'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xc… |
| 5 | 3 | slow | healthcheck.sync over its 5 ms budget | 1 | max 21.5 ms at 2026-11-03 10:29:56:544 |
| 6 | 3 | slow | hotpath:preview.rebuild over its 5 ms budget | 1 | max 9.36 ms at 2026-11-03 10:29:54:945 |
| 7 | 1 | warning | [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-03 10:28:30:832 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. |
| 8 | 1 | warning | [download_window] Progress UI flipped to error state: Cette app de développement n'<*>'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xcode sont nécessaires). | 1 | 2026-11-03 10:31:07:659 [WARNING] [download_window] Progress UI flipped to error state: Cette app de développement n'a pas encore construit son Ollama épinglé depuis les sources du clone : rien n'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les out… |
| 9 | 1 | warning | [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-03 10:31:22:947 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. |
| 10 | 1 | warning | [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 1 | 2026-11-03 10:31:22:947 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-11-03 10:28:30:729)
- ✅ owned_runtime: pass (2026-11-03 10:28:30:811)
- ✅ owned_start: pass (2026-11-03 10:28:30:814)
- ✅ network: pass (2026-11-03 10:28:37:753)
- ✅ toolchain: pass (2026-11-03 10:28:39:348)
- ✅ login_items: pass (2026-11-03 10:28:59:493)
- ✅ composer: pass (2026-11-03 10:29:01:150)
- ✅ boot_cost: pass (2026-11-03 10:29:01:165)
- ✅ idle_cost: pass (2026-11-03 10:29:31:260)
- ✅ layout_rows: pass (2026-11-03 10:29:35:346)
- ✅ permissions: pass (2026-11-03 10:29:35:518)
- ❌ event_taps: fail (2026-11-03 10:29:36:319)
- ✅ input_sources: pass (2026-11-03 10:29:36:417)
- ✅ storage: pass (2026-11-03 10:29:40:814)
- ✅ launcher_roles: pass (2026-11-03 10:29:40:910)
- ✅ network_hosts: pass (2026-11-03 10:29:46:114)
- ❌ ollama_blob_host: fail (2026-11-03 10:29:48:156)
- ✅ typing_selftest: pass (2026-11-03 10:29:54:169)
- ✅ capslock_chord: pass (2026-11-03 10:29:54:180)
- ✅ gesture_frames: pass (2026-11-03 10:29:54:195)
- ✅ hotstring_roundtrip: pass (2026-11-03 10:29:56:311)
- ❌ prediction_tooltip: fail (2026-11-03 10:29:56:324)
- ✅ menu_build: pass (2026-11-03 10:29:56:491)
- ✅ pac_fallback: pass (2026-11-03 10:31:17:302)
- ✅ ai_local: pass (2026-11-03 10:31:17:313)
- ✅ slow_lines: pass (2026-11-03 10:31:17:342)
- ✅ fifo_safety: pass (2026-11-03 10:31:18:422)
- ✅ local_servers: pass (2026-11-03 10:31:18:550)
- ✅ app_health: pass (2026-11-03 10:31:20:364)
- ✅ tap_hold_thresholds: pass (2026-11-03 10:31:20:518)
- ✅ apple_shortcuts: pass (2026-11-03 10:31:20:568)
- ✅ owned_pause: pass (2026-11-03 10:31:20:572)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 30 pass, ❌ 3 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

3 error group(s), 7 warning group(s); 10 occurrence(s); 5 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-11-03 10:31:07:659 | 2026-11-03 10:31:07:659 | new |
| ERROR | ollama_deps | Ollama bootstrap failed (exit=<*>) — Cette app de développement n'<*>'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xcode sont nécessaires). | 1 | 2026-11-03 10:31:07:659 | 2026-11-03 10:31:07:659 | new |
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 1 | 2026-11-03 10:31:17:313 | 2026-11-03 10:31:17:313 | new |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-11-03 09:50:58:126 | 2026-11-03 09:50:58:126 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-03 10:28:30:832 | 2026-11-03 10:28:30:832 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 1 | 2026-11-03 10:29:54:945 | 2026-11-03 10:29:54:945 |  |
| WARNING | download_window | Progress UI flipped to error state: Cette app de développement n'<*>'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xcode sont nécessaires). | 1 | 2026-11-03 10:31:07:659 | 2026-11-03 10:31:07:659 | new |
| WARNING | keymap.utils | Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-03 10:31:22:947 | 2026-11-03 10:31:22:947 |  |
| WARNING | keymap | Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 1 | 2026-11-03 10:31:22:947 | 2026-11-03 10:31:22:947 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 1 | 2026-11-03 10:34:54:549 | 2026-11-03 10:34:54:549 | new |

<details><summary>One example line per group</summary>

```
2026-11-03 10:31:07:659 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=553 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 12 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
```
```
2026-11-03 10:31:07:659 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Cette app de développement n'a pas encore construit son Ollama épinglé depuis les sources du clone : rien n'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xc…
```
```
2026-11-03 10:31:17:313 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```
```
2026-11-03 09:50:58:126 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364) held the main thread for 1005 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 384->384 MB.
```
```
2026-11-03 10:28:30:832 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-03 10:29:54:945 [WARNING] [HotPath] Slow preview.rebuild: 9.36 ms own, 9.36 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-03 10:31:07:659 [WARNING] [download_window] Progress UI flipped to error state: Cette app de développement n'a pas encore construit son Ollama épinglé depuis les sources du clone : rien n'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les out…
```
```
2026-11-03 10:31:22:947 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed.
```
```
2026-11-03 10:31:22:947 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false.
```
```
2026-11-03 10:34:54:549 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 2 | 1337 | 1828 | 1582 | 1828 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 2 | 729 | 740 | 734 | 740 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 2 | 205 | 692 | 448 | 692 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 2 | 200 | 254 | 227 | 254 | no budget declared | — |
| boot.stage:Config-dependent module requires | 2 | 193 | 223 | 208 | 223 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 2 | 134 | 136 | 135 | 136 | no budget declared | — |
| boot.stage:UI: karabiner.init | 2 | 75.5 | 77.9 | 76.7 | 77.9 | no budget declared | — |
| boot.stage:Keymap engine started | 2 | 17.6 | 53.7 | 35.65 | 53.7 | no budget declared | — |
| boot.stage:Config schema migration | 2 | 26.3 | 33.1 | 29.7 | 33.1 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 2 | 12.3 | 16.9 | 14.6 | 16.9 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 2 | 6.2 | 10.1 | 8.15 | 10.1 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 2 | 6.6 | 8.7 | 7.65 | 8.7 | no budget declared | — |
| boot.stage:Accessibility permission | 2 | 0.4 | 7 | 3.7 | 7 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 2 | 5.5 | 6.6 | 6.05 | 6.6 | no budget declared | — |
| boot.stage:File watchers armed | 2 | 4.2 | 4.4 | 4.3 | 4.4 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 2 | 0.6 | 2.5 | 1.55 | 2.5 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 2 | 1.8 | 2.3 | 2.05 | 2.3 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 2 | 1.8 | 2.1 | 1.95 | 2.1 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 2 | 1.2 | 1.9 | 1.55 | 1.9 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 2 | 0.7 | 1 | 0.85 | 1 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 2 | 0.3 | 0.9 | 0.6 | 0.9 | no budget declared | — |
| boot.stage:UI: menu ready | 2 | 0.5 | 0.6 | 0.55 | 0.6 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 2 | 0.2 | 0.5 | 0.35 | 0.5 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 2 | 0.2 | 0.3 | 0.25 | 0.3 | no budget declared | — |

Worst occurrences:

- boot.total: 1828 ms at 2026-11-03 10:31:23:166, 1337 ms at 2026-11-03 10:28:27:964
- boot.cpu: 740 ms at 2026-11-03 10:28:27:964, 729 ms at 2026-11-03 10:31:23:166
- boot.stage:Shortcuts pre-start: 692 ms at 2026-11-03 10:31:22:610, 205 ms at 2026-11-03 10:28:27:462
- boot.stage:Hotstring groups registered (personal + dynamic + common): 254 ms at 2026-11-03 10:31:22:922, 200 ms at 2026-11-03 10:28:27:683
- boot.stage:Config-dependent module requires: 223 ms at 2026-11-03 10:28:27:221, 193 ms at 2026-11-03 10:31:21:881
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 136 ms at 2026-11-03 10:31:23:159, 134 ms at 2026-11-03 10:28:27:956
- boot.stage:UI: karabiner.init: 77.9 ms at 2026-11-03 10:28:27:821, 75.5 ms at 2026-11-03 10:31:23:023
- boot.stage:Keymap engine started: 53.7 ms at 2026-11-03 10:28:27:743, 17.6 ms at 2026-11-03 10:31:22:947
- boot.stage:Config schema migration: 33.1 ms at 2026-11-03 10:31:21:915, 26.3 ms at 2026-11-03 10:28:27:248
- boot.stage:TOML discovery + ordering: 16.9 ms at 2026-11-03 10:31:22:667, 12.3 ms at 2026-11-03 10:28:27:483
- boot.stage:MLX server cleanup started asynchronously: 10.1 ms at 2026-11-03 10:31:22:648, 6.2 ms at 2026-11-03 10:28:27:470
- boot.stage:Path: native asynchronous logger transport committed: 8.7 ms at 2026-11-03 10:28:26:994, 6.6 ms at 2026-11-03 10:31:21:685

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 1 | 2580 | 2580 | 2580 | 2580 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 1 | 2097 | 2097 | 2097 | 2097 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 3 | 116 | 123 | 113 | 123 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| menu.submenu:keyboard_layout | 3 | 13.9 | 51.4 | 26.07 | 51.4 | no budget declared | — |
| menu.submenu:shortcuts | 3 | 39.8 | 40.2 | 39.43 | 40.2 | no budget declared | — |
| menu.submenu:metrics | 1 | 19.8 | 19.8 | 19.8 | 19.8 | no budget declared | — |
| menu.app_exclusions | 3 | 1.2 | 16.2 | 5.87 | 16.2 | no budget declared | — |
| menu.submenu:llm | 3 | 8.5 | 8.7 | 8.5 | 8.7 | no budget declared | — |
| menu.submenu:about | 2 | 6.9 | 7.8 | 7.35 | 7.8 | no budget declared | — |
| menu.submenu:gestures | 2 | 5.9 | 5.9 | 5.9 | 5.9 | no budget declared | — |
| menu.submenu:hotstrings | 1 | 3.1 | 3.1 | 3.1 | 3.1 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 123 ms at 2026-11-03 10:29:56:491, 116 ms at 2026-11-03 10:28:30:563, 98.7 ms at 2026-11-03 10:31:25:543
- menu.submenu:keyboard_layout: 51.4 ms at 2026-11-03 10:29:56:491, 13.9 ms at 2026-11-03 10:31:25:543, 12.9 ms at 2026-11-03 10:28:30:563
- menu.submenu:shortcuts: 40.2 ms at 2026-11-03 10:31:25:543, 39.8 ms at 2026-11-03 10:28:30:563, 38.3 ms at 2026-11-03 10:29:56:491
- menu.app_exclusions: 16.2 ms at 2026-11-03 10:28:30:506, 1.2 ms at 2026-11-03 10:29:56:439, 0.2 ms at 2026-11-03 10:31:25:490
- menu.submenu:llm: 8.7 ms at 2026-11-03 10:28:30:563, 8.5 ms at 2026-11-03 10:29:56:491, 8.3 ms at 2026-11-03 10:31:25:543
- menu.submenu:about: 7.8 ms at 2026-11-03 10:28:30:563, 6.9 ms at 2026-11-03 10:31:25:543
- menu.submenu:gestures: 5.9 ms at 2026-11-03 10:29:56:491, 5.9 ms at 2026-11-03 10:31:25:543

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 18 | 277 | 1005 | 336 | 1005 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (18) |

Worst occurrences:

- main_thread.hold: 1005 ms at 2026-11-03 09:50:58:126 (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364), 458 ms at 2026-11-03 01:04:23:146 (...so/ergopti/static/ergopti_plus/macos/infra/paced_job.lua:121), 351 ms at 2026-11-03 09:33:17:824 (...so/ergopti/static/ergopti_plus/macos/infra/paced_job.lua:121)

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:preview.rebuild | 1 | 9.36 | 9.36 | 9.36 | 9.36 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| healthcheck.sync | 1 | 21.5 | 21.5 | 21.5 | 21.5 | 5 ms (stated in the log line) | ❌ over (1) |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.defaults | 100 | — | — | 33.85 | 279 | no budget declared | — |
| phase:karabiner.layout_actions | 2 | — | — | 121 | 232 | no budget declared | — |
| phase:karabiner.deploy | 2 | — | — | 171 | 177 | no budget declared | — |
| phase:karabiner.merge | 2 | — | — | 170 | 176 | no budget declared | — |
| phase:process.ErgoptiPlus | 2 | — | — | 71.57 | 84.33 | no budget declared | — |
| phase:karabiner.build | 2 | — | — | 35.73 | 36.16 | no budget declared | — |
| phase:karabiner.inputs | 2 | — | — | 31.62 | 34 | no budget declared | — |
| phase:preview.total | 2 | — | — | 2.27 | 2.84 | no budget declared | — |
| phase:hotpath.keydown | 2 | — | — | 1.19 | 2.13 | no budget declared | — |
| phase:hotpath.preview.rebuild | 1 | — | — | 1.71 | 1.71 | no budget declared | — |
| phase:preview.providers | 2 | — | — | 1.29 | 1.66 | no budget declared | — |
| phase:hotpath.hotstring.match | 1 | — | — | 0.05 | 0.05 | no budget declared | — |
| phase:preview.resolve | 2 | — | — | 0.01 | 0.01 | no budget declared | — |

### Counters

- counter:runtime.timer_hold_over_1000ms: 1
- counter:runtime.timer_hold_over_250ms: 27

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 2 | 2026-11-03 10:28:26:983 | 2026-11-03 10:31:21:678 |
| stop | 4 | 2026-11-03 09:59:23:791 | 2026-11-03 10:31:21:079 |
| reload | 1 | 2026-11-03 10:31:20:586 | 2026-11-03 10:31:20:586 |
| sleep_wake | 1 | 2026-11-03 09:50:55:545 | 2026-11-03 09:50:55:545 |
| network_failure | 2 | 2026-11-03 10:28:30:832 | 2026-11-03 10:31:17:313 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-03 10:28:26:983 — ErgoptiPlus session opened =====
===== 2026-11-03 10:31:21:678 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-03 09:59:23:791 [INFO] [infra.termination_coordinator] User exit 'menu_quit' requested; hard deadline 12.0 s.
2026-11-03 09:59:23:791 [INFO] [infra.termination_coordinator] Controlled exit requested (reason: menu_quit).
2026-11-03 09:59:24:272 [INFO] [init] Hammerspoon local teardown started (exit).
2026-11-03 10:31:21:079 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-03 10:31:20:586 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-03 09:50:55:545 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-11-03 10:28:30:832 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-11-03 10:31:17:313 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```

</details>
