# Field log analysis

Logs: ErgoptiPlus_2026-11-05.log (15285 lines, 15222 records, 29 continuation lines); span 2026-11-05 10:10:17:169 to 2026-11-05 16:51:12:572.
Previous report compared: mac-2026-11-05_113223.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 90 | slow | main_thread.hold over its 250 ms budget | 30 | max 1581 ms at 2026-11-05 10:10:36:159 |
| 2 | 51 | slow | hotpath:preview.rebuild over its 5 ms budget | 17 | max 10.55 ms at 2026-11-05 11:51:54:869 |
| 3 | 30 | error | [karabiner] Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (layout-settled). | 6 | 2026-11-05 14:11:33:037 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (layout-settled). |
| 4 | 15 | slow | keystats.ingest over its 500 ms budget | 5 | max 960 ms at 2026-11-05 15:48:37:574 |
| 5 | 11 | warning | [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted. | 11 | 2026-11-05 10:10:36:159 [WARNING] [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted. |
| 6 | 8 | warning | [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/RemapRuntime/<*>-ergopti.<*>/payload for the administrator install. | 8 | 2026-11-05 10:10:52:726 [WARNING] [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/… |
| 7 | 6 | warning | [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 6 | 2026-11-05 10:10:36:463 [WARNING] [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=78): refused: RuntimeRefusal at managed_ollama_hint.py:39 candidate |
| 8 | 6 | slow | boot.total over its 2500 ms budget | 2 | max 19115 ms at 2026-11-05 10:10:35:924 |
| 9 | 6 | slow | hotpath:tooltip.show_predictions over its 5 ms budget | 2 | max 14.75 ms at 2026-11-05 14:50:55:205 |
| 10 | 5 | error | [accessibility_wait] Accessibility still not granted after <*> s. | 1 | 2026-11-05 11:01:03:029 [ERROR] [accessibility_wait] Accessibility still not granted after 600 s. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ❌ lease: fail (2026-11-05 11:33:08:102)
- ❌ owned_install: fail (2026-11-05 11:33:08:433)
- ❌ owned_runtime: fail (2026-11-05 11:33:09:985)
- ❌ owned_start: fail (2026-11-05 11:33:10:083)
- ✅ network: pass (2026-11-05 11:33:13:152)
- ✅ toolchain: pass (2026-11-05 11:33:14:525)
- ✅ login_items: pass (2026-11-05 11:33:34:724)
- ✅ composer: pass (2026-11-05 11:33:36:129)
- ✅ boot_cost: pass (2026-11-05 11:33:36:136)
- ✅ idle_cost: pass (2026-11-05 11:34:06:224)
- ✅ layout_rows: pass (2026-11-05 11:34:09:648)
- ✅ permissions: pass (2026-11-05 11:34:09:806)
- ✅ event_taps: pass (2026-11-05 11:34:10:312)
- ✅ input_sources: pass (2026-11-05 11:34:10:408)
- ✅ storage: pass (2026-11-05 11:34:14:782)
- ✅ launcher_roles: pass (2026-11-05 11:34:14:892)
- ✅ network_hosts: pass (2026-11-05 11:34:17:722)
- ✅ ollama_blob_host: pass (2026-11-05 11:34:20:536)
- ❌ typing_selftest: fail (2026-11-05 11:34:26:547)
- ✅ capslock_chord: pass (2026-11-05 11:34:26:558)
- ✅ gesture_frames: pass (2026-11-05 11:34:26:567)
- ❌ hotstring_roundtrip: fail (2026-11-05 11:34:31:712)
- ❌ prediction_tooltip: fail (2026-11-05 11:34:31:722)
- ✅ menu_build: pass (2026-11-05 11:34:31:873)
- ✅ pac_fallback: pass (2026-11-05 11:37:41:014)
- ✅ ai_local: pass (2026-11-05 11:37:41:056)
- ✅ slow_lines: pass (2026-11-05 11:37:41:121)
- ✅ fifo_safety: pass (2026-11-05 11:37:42:227)
- ✅ local_servers: pass (2026-11-05 11:37:42:337)
- ✅ app_health: pass (2026-11-05 11:37:43:965)
- ❌ tap_hold_thresholds: fail (2026-11-05 11:37:43:969)
- ❌ tap_copy: fail (2026-11-05 11:37:43:973)
- ✅ apple_shortcuts: pass (2026-11-05 11:37:44:019)
- ❌ owned_pause: fail (2026-11-05 11:38:29:120)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 25 pass, ❌ 10 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

18 error group(s), 32 warning group(s); 119 occurrence(s); 50 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | karabiner | Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (layout-settled). | 6 | 2026-11-05 14:11:33:037 | 2026-11-05 16:51:11:506 | new |
| ERROR | accessibility_wait | Accessibility still not granted after <*> s. | 1 | 2026-11-05 11:01:03:029 | 2026-11-05 11:01:03:029 | new |
| ERROR | init | ErgoptiPlus runtime dependency failed (accessibility: Accessibility permission was not granted within <*> s) — shutting down embedded Hammerspoon. | 1 | 2026-11-05 11:01:03:030 | 2026-11-05 11:01:03:030 | new |
| ERROR | init | Fatal abort at boot stage '<*>': Accessibility permission was not granted within <*> s. | 1 | 2026-11-05 11:01:03:030 | 2026-11-05 11:01:03:030 | new |
| ERROR | karabiner.lease | '<*>' called before M.init() — lease controller unavailable: caller | 1 | 2026-11-05 11:01:03:045 | 2026-11-05 11:01:03:045 | new |
| ERROR | remap.runtime_install | Owned runtime install refused (install_refused): helper_signature | 1 | 2026-11-05 11:33:08:433 | 2026-11-05 11:33:08:433 | new |
| ERROR | llm.api_ollama | Ollama native lifecycle receipt unsettled left unsettled native ownership; retry fenced. | 1 | 2026-11-05 11:36:52:032 | 2026-11-05 11:36:52:032 | new |
| ERROR | llm.api_ollama | Ollama native lifecycle receipt unsettled did not commit (result: false); launch remains retryable. | 1 | 2026-11-05 11:36:52:032 | 2026-11-05 11:36:52:032 | new |
| ERROR | ollama_deps | Ollama daemon start failed (exit=<*>) — Impossible de lancer le démon Ollama. | 1 | 2026-11-05 11:36:52:032 | 2026-11-05 11:36:52:032 | new |
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 1 | 2026-11-05 11:36:53:073 | 2026-11-05 11:36:53:073 | new |
| ERROR | llm.api_ollama | Ollama startup cleanup remains unsettled; sibling launch fenced. | 1 | 2026-11-05 11:36:53:073 | 2026-11-05 11:36:53:073 | new |
| ERROR | llm.api_ollama | ensure_running() did not commit: false | 1 | 2026-11-05 11:36:53:073 | 2026-11-05 11:36:53:073 | new |
| ERROR | adapters.file_system | read_with_status(): cannot inspect '<*>' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner | 1 | 2026-11-05 11:37:43:969 | 2026-11-05 11:37:43:969 | new |
| ERROR | llm.api_ollama | Ollama warmup resume is waiting for prior cancellation: true. | 1 | 2026-11-05 11:37:44:023 | 2026-11-05 11:37:44:023 | new |
| ERROR | shortcuts.script_control | Pause rollback failed: api_ollama.pause_warmup rollback returned false: nil. | 1 | 2026-11-05 11:37:44:023 | 2026-11-05 11:37:44:023 | new |
| ERROR | shortcuts.script_control | Local pause quiescence failed; restoring native RESUMED before publication: api_ollama.pause_warmup returned false: nil; rollback failures: api_ollama.pause_warmup rollback returned false: nil. | 1 | 2026-11-05 11:37:44:036 | 2026-11-05 11:37:44:036 | new |
| ERROR | shortcuts.script_control | Script pause transaction failed; settled state preserved: api_ollama.pause_warmup returned false: nil; rollback failures: api_ollama.pause_warmup rollback returned false: nil. | 1 | 2026-11-05 11:37:44:038 | 2026-11-05 11:37:44:038 | new |
| ERROR | karabiner | Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (owned-runtime-not-admitted). | 1 | 2026-11-05 13:54:39:307 | 2026-11-05 13:54:39:307 | new |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 17 | 2026-11-05 11:51:54:869 | 2026-11-05 16:41:21:668 | new |
| WARNING | karabiner | Regenerate skipped — the owned Karabiner runtime is not admitted. | 11 | 2026-11-05 10:10:36:159 | 2026-11-05 13:54:39:307 | new |
| WARNING | remap.runtime_owner | Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/RemapRuntime/<*>-ergopti.<*>/payload for the administrat… | 8 | 2026-11-05 10:10:52:726 | 2026-11-05 11:38:42:401 | new |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 6 | 2026-11-05 10:10:36:463 | 2026-11-05 11:33:09:859 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 5 | 2026-11-05 12:09:49:070 | 2026-11-05 14:34:12:900 | new |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; append: lock=<*> journal=<*> prepare=<*> publish=<*> write=<*> clear=<*> settle=<*> release=<*> ms; metadata_commands=<*> in <*> ms; entries=<*> statements=<*>). | 5 | 2026-11-05 15:48:37:574 | 2026-11-05 16:42:52:193 | new |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 4 | 2026-11-05 11:20:45:933 | 2026-11-05 16:51:11:150 | new |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 4 | 2026-11-05 11:20:47:212 | 2026-11-05 16:51:12:152 | new |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 4 | 2026-11-05 11:20:47:212 | 2026-11-05 16:51:12:152 | new |
| WARNING | karabiner | Karabiner lease auto-recovery attempt <*> failed: owned-runtime-not-admitted. | 3 | 2026-11-05 13:53:39:271 | 2026-11-05 13:54:39:307 | new |
| WARNING | key_event_health | A non-character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across … | 3 | 2026-11-05 14:42:56:725 | 2026-11-05 15:44:05:793 | new |
| WARNING | BootProfile | Over budget: boot took <*> ms (budget <*> ms). | 2 | 2026-11-05 10:10:35:925 | 2026-11-05 11:17:06:852 | new |
| WARNING | field_run | Field run mac-<*><*><*>_1<*> cut short by a reload (menu) during step '<*>'; closed as interrupted. | 2 | 2026-11-05 10:10:56:041 | 2026-11-05 11:17:18:190 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 2 | 2026-11-05 11:20:47:206 | 2026-11-05 11:42:10:903 | new |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (owned-runtime-not-admitted). | 2 | 2026-11-05 13:53:39:271 | 2026-11-05 13:54:02:473 | new |
| WARNING | HotPath | Slow tooltip.show_predictions: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 2 | 2026-11-05 14:50:55:205 | 2026-11-05 15:44:02:001 | new |
| WARNING | runtime | An hs.timer.new callback (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=<*> ms, boot.stage_cpu=<*> ms, boot.stage=<*> ms, boot.stage_cpu=… | 1 | 2026-11-05 10:10:36:159 | 2026-11-05 10:10:36:159 | new |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-05 11:33:10:118 | 2026-11-05 11:33:10:118 | new |
| WARNING | keymap.selftest_gate | A field-run selftest key was consumed (no_dev_source); no application received it. | 1 | 2026-11-05 11:34:27:231 | 2026-11-05 11:34:27:231 | new |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: operation. | 1 | 2026-11-05 11:36:52:032 | 2026-11-05 11:36:52:032 | new |
| WARNING | download_window | Progress UI flipped to error state: Impossible de lancer le démon Ollama. | 1 | 2026-11-05 11:36:52:032 | 2026-11-05 11:36:52:032 | new |
| WARNING | karabiner | Karabiner lease could not be provisioned on resume (owned-runtime-not-admitted); resuming without a live lease. | 1 | 2026-11-05 11:37:44:038 | 2026-11-05 11:37:44:038 | new |
| WARNING | init | Over budget: reload took <*> ms (budget <*> ms). | 1 | 2026-11-05 11:38:42:602 | 2026-11-05 11:38:42:602 | new |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (unexpected-worker-loss). | 1 | 2026-11-05 13:53:37:201 | 2026-11-05 13:53:37:201 | new |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (layout-settled). | 1 | 2026-11-05 13:53:45:671 | 2026-11-05 13:53:45:671 | new |
| WARNING | HotPath | Slow hotstring.match: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 1 | 2026-11-05 13:55:20:159 | 2026-11-05 13:55:20:159 | new |
| WARNING | shortcuts.actions.screen_capture | Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime. | 1 | 2026-11-05 14:36:25:603 | 2026-11-05 14:36:25:603 | new |
| WARNING | key_event_health | A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across… | 1 | 2026-11-05 14:42:52:725 | 2026-11-05 14:42:52:725 | new |
| WARNING | HotPath | Slow keydown: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 1 | 2026-11-05 14:51:12:585 | 2026-11-05 14:51:12:585 | new |
| WARNING | key_event_health | A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a ru… | 1 | 2026-11-05 15:13:11:772 | 2026-11-05 15:13:11:772 | new |
| WARNING | key_event_health | A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or … | 1 | 2026-11-05 15:13:12:772 | 2026-11-05 15:13:12:772 | new |
| WARNING | key_event_health | Key events reached the keymap taps <*> ms or more late: the main thread held them (<*> times); session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a rule swi… | 1 | 2026-11-05 16:39:57:842 | 2026-11-05 16:39:57:842 | new |

<details><summary>One example line per group</summary>

```
2026-11-05 14:11:33:037 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (layout-settled).
```
```
2026-11-05 11:01:03:029 [ERROR] [accessibility_wait] Accessibility still not granted after 600 s.
```
```
2026-11-05 11:01:03:030 [ERROR] [init] ErgoptiPlus runtime dependency failed (accessibility: Accessibility permission was not granted within 600 s) — shutting down embedded Hammerspoon.
```
```
2026-11-05 11:01:03:030 [ERROR] [init] Fatal abort at boot stage 'accessibility': Accessibility permission was not granted within 600 s.
```
```
2026-11-05 11:01:03:045 [ERROR] [karabiner.lease] 'status' called before M.init() — lease controller unavailable: caller
```
```
2026-11-05 11:33:08:433 [ERROR] [remap.runtime_install] Owned runtime install refused (install_refused): helper_signature
```
```
2026-11-05 11:36:52:032 [ERROR] [llm.api_ollama] Ollama native lifecycle receipt unsettled left unsettled native ownership; retry fenced.
```
```
2026-11-05 11:36:52:032 [ERROR] [llm.api_ollama] Ollama native lifecycle receipt unsettled did not commit (result: false); launch remains retryable.
```
```
2026-11-05 11:36:52:032 [ERROR] [ollama_deps] Ollama daemon start failed (exit=-1) — Impossible de lancer le démon Ollama.
```
```
2026-11-05 11:36:53:073 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```
```
2026-11-05 11:36:53:073 [ERROR] [llm.api_ollama] Ollama startup cleanup remains unsettled; sibling launch fenced.
```
```
2026-11-05 11:36:53:073 [ERROR] [llm.api_ollama] ensure_running() did not commit: false
```
```
2026-11-05 11:37:43:969 [ERROR] [adapters.file_system] read_with_status(): cannot inspect '~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner
```
```
2026-11-05 11:37:44:023 [ERROR] [llm.api_ollama] Ollama warmup resume is waiting for prior cancellation: true.
```
```
2026-11-05 11:37:44:023 [ERROR] [shortcuts.script_control] Pause rollback failed: api_ollama.pause_warmup rollback returned false: nil.
```
```
2026-11-05 11:37:44:036 [ERROR] [shortcuts.script_control] Local pause quiescence failed; restoring native RESUMED before publication: api_ollama.pause_warmup returned false: nil; rollback failures: api_ollama.pause_warmup rollback returned false: nil.
```
```
2026-11-05 11:37:44:038 [ERROR] [shortcuts.script_control] Script pause transaction failed; settled state preserved: api_ollama.pause_warmup returned false: nil; rollback failures: api_ollama.pause_warmup rollback returned false: nil.
```
```
2026-11-05 13:54:39:307 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (owned-runtime-not-admitted).
```
```
2026-11-05 11:51:54:869 [WARNING] [HotPath] Slow preview.rebuild: 10.55 ms own, 10.55 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-05 10:10:36:159 [WARNING] [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted.
```
```
2026-11-05 10:10:52:726 [WARNING] [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/…
```
```
2026-11-05 10:10:36:463 [WARNING] [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=78): refused: RuntimeRefusal at managed_ollama_hint.py:39 candidate
```
```
2026-11-05 12:09:49:070 [WARNING] [keymap.utils] Slow ignored-window probe 502 ms (watchers=0 focused_window=502 ms).
```
```
2026-11-05 15:48:37:574 [WARNING] [keystats.log_manager] Slow ingest tick 960 ms (drain=0 foreign=0 outbox=2 read=129 build=2 apply=5 commit=0 append=819 notify=0 ms; append: lock=0 journal=0 prepare=0 publish=2 write=807 clear=1 settle=6 release=0 ms; metadata_commands=0 in 0 ms; entries=1 stateme…
```
```
2026-11-05 11:20:45:933 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```
```
2026-11-05 11:20:47:212 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil.
```
```
2026-11-05 11:20:47:212 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried.
```
```
2026-11-05 13:53:39:271 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 1 failed: owned-runtime-not-admitted.
```
```
2026-11-05 14:42:56:725 [WARNING] [key_event_health] A non-character key stayed down 4.0 s with no further event: its key-up was lost before the keymap taps; session totals: 674 key-down(s), 674 key-up(s), 1 key-up(s) without key-down, 0 key-down(s) without key-up, 1 key(s) stuck over 3.0 s, 0 char…
```
```
2026-11-05 10:10:35:925 [WARNING] [BootProfile] Over budget: boot took 19115 ms (budget 2500 ms).
```
```
2026-11-05 10:10:56:041 [WARNING] [field_run] Field run mac-2026-11-05_100853 cut short by a reload (menu) during step 'field_lease'; closed as interrupted.
```
```
2026-11-05 11:20:47:206 [WARNING] [menu] Over budget: menu.rebuild took 352 ms (budget 250 ms).
```
```
2026-11-05 13:53:39:271 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (owned-runtime-not-admitted).
```
```
2026-11-05 14:50:55:205 [WARNING] [HotPath] Slow tooltip.show_predictions: 14.75 ms own, 14.75 ms total, parent none (0 similar since the last line).
```
```
2026-11-05 10:10:36:159 [WARNING] [runtime] An hs.timer.new callback (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:139) held the main thread for 1581 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=491.2 ms, boot.stage…
```
```
2026-11-05 11:33:10:118 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-05 11:34:27:231 [WARNING] [keymap.selftest_gate] A field-run selftest key was consumed (no_dev_source); no application received it.
```
```
2026-11-05 11:36:52:032 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: operation.
```
```
2026-11-05 11:36:52:032 [WARNING] [download_window] Progress UI flipped to error state: Impossible de lancer le démon Ollama.
```
```
2026-11-05 11:37:44:038 [WARNING] [karabiner] Karabiner lease could not be provisioned on resume (owned-runtime-not-admitted); resuming without a live lease.
```
```
2026-11-05 11:38:42:602 [WARNING] [init] Over budget: reload took 13444 ms (budget 4000 ms).
```
```
2026-11-05 13:53:37:201 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
```
```
2026-11-05 13:53:45:671 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (layout-settled).
```
```
2026-11-05 13:55:20:159 [WARNING] [HotPath] Slow hotstring.match: 10.48 ms own, 12.84 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-05 14:36:25:603 [WARNING] [shortcuts.actions.screen_capture] Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime.
```
```
2026-11-05 14:42:52:725 [WARNING] [key_event_health] A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: 669 key-down(s), 669 key-up(s), 1 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 cha…
```
```
2026-11-05 14:51:12:585 [WARNING] [HotPath] Slow keydown: 5.24 ms own, 5.24 ms total, parent none (0 similar since the last line).
```
```
2026-11-05 15:13:11:772 [WARNING] [key_event_health] A character key stayed down 3.0 s with no further event: its key-up was lost before the keymap taps; session totals: 1501 key-down(s), 1498 key-up(s), 1 key-up(s) without key-down, 0 key-down(s) without key-up, 3 key(s) stuck over 3.0 s, 0 charac…
```
```
2026-11-05 15:13:12:772 [WARNING] [key_event_health] A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: 1511 key-down(s), 1508 key-up(s), 1 key-up(s) without key-down, 1 key-down(s) without key-up, 3 key(s) stuck…
```
```
2026-11-05 16:39:57:842 [WARNING] [key_event_health] Key events reached the keymap taps 250 ms or more late: the main thread held them (2 times); session totals: 2387 key-down(s), 2386 key-up(s), 1 key-up(s) without key-down, 1 key-down(s) without key-up, 4 key(s) stuck over 3.0 s, 0 character key(…
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 7 | 1154 | 19115 | 5696 | 19115 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| boot.stage:Accessibility permission | 7 | 0.5 | 17020 | 4433 | 17020 | no budget declared | — |
| boot.cpu | 7 | 716 | 1854 | 923 | 1854 | no budget declared | — |
| boot.stage:UI: karabiner.init | 7 | 95.4 | 491 | 152 | 491 | no budget declared | — |
| boot.stage:Config-dependent module requires | 17 | 152 | 321 | 160 | 321 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 7 | 185 | 294 | 197 | 294 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 7 | 192 | 271 | 204 | 271 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 7 | 128 | 179 | 136 | 179 | no budget declared | — |
| boot.stage:Keymap engine started | 7 | 31 | 57.6 | 37.37 | 57.6 | no budget declared | — |
| boot.stage:Config schema migration | 17 | 26.9 | 46.1 | 27.47 | 46.1 | no budget declared | — |
| boot.stage:File watchers armed | 7 | 7.7 | 39.3 | 12.56 | 39.3 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 7 | 7.2 | 18.2 | 8.3 | 18.2 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 7 | 12.5 | 17.9 | 11.66 | 17.9 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 17 | 6.2 | 11.8 | 7.11 | 11.8 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 17 | 1.8 | 10.4 | 2.57 | 10.4 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 7 | 0.8 | 6.7 | 1.71 | 6.7 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 7 | 5 | 6.3 | 5.19 | 6.3 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 7 | 1 | 4.5 | 1.61 | 4.5 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 7 | 0.3 | 2.9 | 0.8 | 2.9 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 17 | 1.5 | 2.5 | 1.65 | 2.5 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 17 | 1.1 | 2.1 | 1.22 | 2.1 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 17 | 0.2 | 1.7 | 0.32 | 1.7 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 17 | 0.6 | 1.6 | 0.73 | 1.6 | no budget declared | — |
| boot.stage:UI: menu ready | 7 | 0.4 | 0.9 | 0.5 | 0.9 | no budget declared | — |

Worst occurrences:

- boot.total: 19115 ms at 2026-11-05 10:10:35:924, 15224 ms at 2026-11-05 11:17:06:852, 1285 ms at 2026-11-05 11:38:42:602
- boot.stage:Accessibility permission: 17020 ms at 2026-11-05 10:10:34:579, 14002 ms at 2026-11-05 11:17:06:051, 7.6 ms at 2026-11-05 11:32:33:259
- boot.cpu: 1854 ms at 2026-11-05 10:10:35:925, 1083 ms at 2026-11-05 11:17:06:852, 760 ms at 2026-11-05 11:32:33:949
- boot.stage:UI: karabiner.init: 491 ms at 2026-11-05 10:10:35:726, 115 ms at 2026-11-05 11:17:06:687, 104 ms at 2026-11-05 10:10:57:253
- boot.stage:Config-dependent module requires: 321 ms at 2026-11-05 10:10:17:509, 175 ms at 2026-11-05 11:38:41:774, 174 ms at 2026-11-05 10:10:56:692
- boot.stage:Shortcuts pre-start: 294 ms at 2026-11-05 10:10:34:874, 222 ms at 2026-11-05 11:17:06:274, 220 ms at 2026-11-05 11:38:42:027
- boot.stage:Hotstring groups registered (personal + dynamic + common): 271 ms at 2026-11-05 10:10:35:180, 206 ms at 2026-11-05 11:17:06:508, 193 ms at 2026-11-05 11:32:33:653
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 179 ms at 2026-11-05 10:10:35:906, 157 ms at 2026-11-05 11:17:06:844, 147 ms at 2026-11-05 11:38:42:550
- boot.stage:Keymap engine started: 57.6 ms at 2026-11-05 11:17:06:571, 53.1 ms at 2026-11-05 11:32:33:713, 48.8 ms at 2026-11-05 10:10:35:235
- boot.stage:Config schema migration: 46.1 ms at 2026-11-05 10:10:17:556, 29.3 ms at 2026-11-05 11:38:41:804, 29 ms at 2026-11-05 11:15:14:498
- boot.stage:File watchers armed: 39.3 ms at 2026-11-05 11:38:42:592, 13 ms at 2026-11-05 10:10:35:922, 8.4 ms at 2026-11-05 10:10:57:382
- boot.stage:MLX server cleanup started asynchronously: 18.2 ms at 2026-11-05 11:38:42:058, 9.7 ms at 2026-11-05 10:10:34:887, 7.9 ms at 2026-11-05 11:17:18:932

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 4 | 1223 | 13447 | 4308 | 13447 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |
| reload.total | 4 | 1213 | 13444 | 4298 | 13444 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

Worst occurrences:

- reload.request_to_boot: 13447 ms at 2026-11-05 11:38:29:155, 1400 ms at 2026-11-05 10:10:55:983, 1223 ms at 2026-11-05 11:17:18:150
- reload.total: 13444 ms at 2026-11-05 11:38:42:602, 1375 ms at 2026-11-05 10:10:57:383, 1213 ms at 2026-11-05 11:17:19:373

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 9 | 82.5 | 246 | 106 | 246 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| phase:menu.rebuild | 17 | — | — | 132 | 580 | no budget declared | — |
| phase:menu_item.keyboard_layout | 17 | — | — | 45.03 | 485 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 17 | — | — | 32.26 | 415 | no budget declared | — |
| phase:menu_item.shortcuts | 17 | — | — | 51.41 | 320 | no budget declared | — |
| menu.submenu:keyboard_layout | 9 | 9.2 | 162 | 29.67 | 162 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 17 | — | — | 12.01 | 66.58 | no budget declared | — |
| phase:menu_keyboard_layout.number_row | 17 | — | — | 9.49 | 63.27 | no budget declared | — |
| menu.submenu:shortcuts | 9 | 35.9 | 45.3 | 34.96 | 45.3 | no budget declared | — |
| phase:menu_item.gestures | 17 | — | — | 9.29 | 24.98 | no budget declared | — |
| menu.submenu:metrics | 4 | 11.6 | 20 | 12.05 | 20 | no budget declared | — |
| menu.app_exclusions | 9 | 1 | 17.7 | 5 | 17.7 | no budget declared | — |
| phase:menu_item.metrics | 17 | — | — | 1.89 | 13.31 | no budget declared | — |
| menu.submenu:gestures | 9 | 7.5 | 11.2 | 7.68 | 11.2 | no budget declared | — |
| menu.submenu:llm | 9 | 6.3 | 11.2 | 6.82 | 11.2 | no budget declared | — |
| phase:menu_item.llm | 17 | — | — | 6.57 | 10.49 | no budget declared | — |
| phase:menu_item.hotstrings | 17 | — | — | 3.17 | 4.99 | no budget declared | — |
| menu.submenu:hotstrings | 5 | 3.4 | 3.7 | 3.34 | 3.7 | no budget declared | — |
| phase:menu_keyboard_layout.magic_key | 17 | — | — | 0.73 | 3.24 | no budget declared | — |
| phase:menu_item.tap_holds | 17 | — | — | 1.71 | 2.97 | no budget declared | — |
| phase:menu_item.debug | 17 | — | — | 0.46 | 2.32 | no budget declared | — |
| phase:menu_item.about | 17 | — | — | 0.15 | 0.53 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 17 | — | — | 0.22 | 0.31 | no budget declared | — |
| phase:menu_item.apps | 17 | — | — | 0.19 | 0.25 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 17 | — | — | 0.09 | 0.11 | no budget declared | — |
| phase:menu_item.configuration | 17 | — | — | 0.05 | 0.07 | no budget declared | — |
| phase:menu_item.language | 17 | — | — | 0.04 | 0.06 | no budget declared | — |
| phase:menu_item.reload | 17 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.quit | 17 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 246 ms at 2026-11-05 16:51:10:605, 109 ms at 2026-11-05 11:32:36:424, 109 ms at 2026-11-05 11:34:31:873
- menu.submenu:keyboard_layout: 162 ms at 2026-11-05 16:51:10:605, 41.8 ms at 2026-11-05 11:34:31:873, 9.4 ms at 2026-11-05 11:38:44:959
- menu.submenu:shortcuts: 45.3 ms at 2026-11-05 11:32:36:424, 37.2 ms at 2026-11-05 11:38:44:959, 36.7 ms at 2026-11-05 11:33:11:976
- menu.submenu:metrics: 20 ms at 2026-11-05 11:32:36:424, 13.3 ms at 2026-11-05 11:17:21:700, 11.6 ms at 2026-11-05 10:10:59:737
- menu.app_exclusions: 17.7 ms at 2026-11-05 11:32:36:376, 11.2 ms at 2026-11-05 11:17:21:651, 9.8 ms at 2026-11-05 10:10:59:683
- menu.submenu:gestures: 11.2 ms at 2026-11-05 16:51:10:605, 7.7 ms at 2026-11-05 11:32:36:424, 7.6 ms at 2026-11-05 11:34:31:873
- menu.submenu:llm: 11.2 ms at 2026-11-05 16:51:10:605, 7 ms at 2026-11-05 10:10:59:737, 6.5 ms at 2026-11-05 10:10:38:219
- menu.submenu:hotstrings: 3.7 ms at 2026-11-05 16:51:10:605, 3.5 ms at 2026-11-05 11:17:09:257, 3.4 ms at 2026-11-05 10:10:38:219

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 30 | 501 | 992 | 531 | 1581 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (30) |

Worst occurrences:

- main_thread.hold: 1581 ms at 2026-11-05 10:10:36:159 (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:139), 992 ms at 2026-11-05 11:17:07:042 (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:139), 960 ms at 2026-11-05 15:48:37:574 (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2338)

### Hotstrings

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:hotstring.match | 1 | 10.48 | 10.48 | 10.48 | 10.48 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:tooltip.show_predictions | 2 | 6.01 | 14.75 | 10.38 | 14.75 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| hotpath:preview.rebuild | 17 | 6.18 | 10.55 | 6.85 | 10.55 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (17) |

Worst occurrences:

- hotpath:tooltip.show_predictions: 14.75 ms at 2026-11-05 14:50:55:205, 6.01 ms at 2026-11-05 15:44:02:001
- hotpath:preview.rebuild: 10.55 ms at 2026-11-05 11:51:54:869, 10.36 ms at 2026-11-05 16:41:21:668, 8.5 ms at 2026-11-05 14:54:54:446

### LLM requests

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| llm.ttft | 2 | 1100 | 1961 | 1530 | 1961 | 2000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| llm.stream | 2 | 1098 | 1959 | 1528 | 1959 | no budget declared | — |
| llm.parsed:remote | 2 | 1097 | 1957 | 1527 | 1957 | no budget declared | — |

Worst occurrences:

- llm.ttft: 1961 ms at 2026-11-05 14:50:55:191, 1100 ms at 2026-11-05 15:44:01:995
- llm.stream: 1959 ms at 2026-11-05 14:50:55:271, 1098 ms at 2026-11-05 15:44:02:001
- llm.parsed:remote: 1957 ms at 2026-11-05 14:50:55:189, 1097 ms at 2026-11-05 15:44:01:994

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 5 | 582 | 960 | 639 | 960 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (5) |

Worst occurrences:

- keystats.ingest: 960 ms at 2026-11-05 15:48:37:574, 586 ms at 2026-11-05 16:09:47:237, 582 ms at 2026-11-05 16:39:57:242

### Input

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| input.late_key_event | 1 | 586 | 586 | 586 | 586 | 250 ms (stated in the log line) | ❌ over (1) |

### Other hot-path segments

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:keydown | 1 | 5.24 | 5.24 | 5.24 | 5.24 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 1 | — | — | 20012 | 20012 | no budget declared | — |
| phase:process.sqlite3 | 1 | — | — | 4363 | 4363 | no budget declared | — |
| phase:process.python3 | 19 | — | — | 530 | 2973 | no budget declared | — |
| phase:process.defaults | 1611 | — | — | 24.82 | 2331 | no budget declared | — |
| phase:process.vmmap | 1 | — | — | 1587 | 1587 | no budget declared | — |
| phase:process.sh | 6 | — | — | 590 | 1136 | no budget declared | — |
| phase:process.ErgoptiPlus | 83 | — | — | 117 | 700 | no budget declared | — |
| phase:process.spctl | 1 | — | — | 687 | 687 | no budget declared | — |
| phase:boot.stage | 72 | — | — | 44.47 | 258 | no budget declared | — |
| phase:boot.requires | 48 | — | — | 26.86 | 255 | no budget declared | — |
| phase:process.open | 1 | — | — | 204 | 204 | no budget declared | — |
| phase:boot.stage_cpu | 72 | — | — | 28.1 | 183 | no budget declared | — |
| phase:process.codesign | 5 | — | — | 62.1 | 147 | no budget declared | — |
| phase:process.brew | 1 | — | — | 142 | 142 | no budget declared | — |
| phase:process.mkdir | 7 | — | — | 56.7 | 126 | no budget declared | — |
| phase:shell.mkdir | 6 | — | — | 65.46 | 126 | no budget declared | — |
| phase:process.pgrep | 8 | — | — | 67.68 | 122 | no budget declared | — |
| phase:shell.ls | 18 | — | — | 48.88 | 101 | no budget declared | — |
| phase:shell.curl | 1 | — | — | 94.89 | 94.89 | no budget declared | — |
| phase:process.bash | 1 | — | — | 93.63 | 93.63 | no budget declared | — |
| phase:shell.find | 3 | — | — | 64.19 | 82.71 | no budget declared | — |
| phase:shell.sw_vers | 3 | — | — | 76.39 | 80.41 | no budget declared | — |
| phase:process.launchctl | 2 | — | — | 44.82 | 80.14 | no budget declared | — |
| phase:shell.ioreg | 3 | — | — | 56.1 | 78.46 | no budget declared | — |
| phase:process.shortcuts | 2 | — | — | 62.53 | 70.64 | no budget declared | — |
| phase:process.awk | 2 | — | — | 42.1 | 59.41 | no budget declared | — |
| phase:process.tccutil | 1 | — | — | 43.97 | 43.97 | no budget declared | — |
| phase:process.ps | 4 | — | — | 20.36 | 39.89 | no budget declared | — |
| phase:process.plutil | 4 | — | — | 14.09 | 39.73 | no budget declared | — |
| phase:process.grep | 2 | — | — | 27.83 | 36.9 | no budget declared | — |
| phase:process.systemextensionsctl | 1 | — | — | 32.57 | 32.57 | no budget declared | — |
| phase:hotpath.keydown | 2647 | — | — | 2 | 29.97 | no budget declared | — |
| phase:hotpath.preview.rebuild | 2328 | — | — | 1.74 | 26.3 | no budget declared | — |
| phase:preview.total | 2499 | — | — | 1.7 | 26.3 | no budget declared | — |
| phase:process.mkfifo | 1 | — | — | 22.01 | 22.01 | no budget declared | — |
| phase:process.xmllint | 8 | — | — | 5.05 | 20.53 | no budget declared | — |
| phase:hotstring_load.common_file | 6 | — | — | 10.75 | 18.85 | no budget declared | — |
| phase:preview.resolve | 2499 | — | — | 0.28 | 17.02 | no budget declared | — |
| phase:hotpath.tooltip.show_predictions | 4 | — | — | 10.52 | 14.75 | no budget declared | — |
| phase:hotpath.hotstring.match | 2377 | — | — | 0.27 | 12.84 | no budget declared | — |
| phase:toml.parse | 72 | — | — | 1.23 | 8.41 | no budget declared | — |
| phase:process.scutil | 1 | — | — | 8.14 | 8.14 | no budget declared | — |
| phase:preview.providers | 2499 | — | — | 0.37 | 7.86 | no budget declared | — |
| phase:hotpath.hotstring.expand | 49 | — | — | 0.42 | 4.32 | no budget declared | — |
| phase:process.id | 1 | — | — | 3.56 | 3.56 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 14
- counter:runtime.timer_hold_over_250ms: 26

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 17 | 2026-11-05 10:10:17:170 | 2026-11-05 11:38:41:585 |
| stop | 7 | 2026-11-05 10:10:56:012 | 2026-11-05 11:38:29:165 |
| reload | 4 | 2026-11-05 10:10:55:983 | 2026-11-05 11:38:29:155 |
| sleep_wake | 5 | 2026-11-05 13:53:36:501 | 2026-11-05 15:12:32:769 |
| permission_refused | 2 | 2026-11-05 11:01:03:030 | 2026-11-05 11:01:03:030 |
| karabiner_lease_failure | 14 | 2026-11-05 11:37:44:038 | 2026-11-05 16:51:11:506 |
| network_failure | 2 | 2026-11-05 11:33:10:118 | 2026-11-05 11:36:53:073 |
| update_check | 15 | 2026-11-05 10:10:35:816 | 2026-11-05 11:38:42:454 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-05 10:10:17:170 — ErgoptiPlus session opened =====
===== 2026-11-05 10:10:56:502 — ErgoptiPlus session opened =====
===== 2026-11-05 10:42:50:948 — ErgoptiPlus session opened =====
===== 2026-11-05 10:44:53:198 — ErgoptiPlus session opened =====
===== 2026-11-05 10:45:08:996 — ErgoptiPlus session opened =====
===== 2026-11-05 10:45:56:700 — ErgoptiPlus session opened =====
===== 2026-11-05 10:47:40:512 — ErgoptiPlus session opened =====
===== 2026-11-05 10:48:29:415 — ErgoptiPlus session opened =====
===== 2026-11-05 10:49:21:680 — ErgoptiPlus session opened =====
===== 2026-11-05 10:51:02:828 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-05 10:10:56:012 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-05 11:01:03:030 [ERROR] [init] ErgoptiPlus runtime dependency failed (accessibility: Accessibility permission was not granted within 600 s) — shutting down embedded Hammerspoon.
2026-11-05 11:01:03:033 [INFO] [infra.termination_coordinator] Controlled exit requested (reason: runtime_failure_accessibility_Accessibility permission was not granted within 600 s).
2026-11-05 11:01:03:034 [INFO] [init] Hammerspoon local teardown started (exit).
2026-11-05 11:17:18:163 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-05 11:33:08:448 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-05 11:38:29:165 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-05 10:10:55:983 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: menu).
2026-11-05 11:17:18:150 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: menu).
2026-11-05 11:33:08:441 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
2026-11-05 11:38:29:155 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-05 13:53:36:501 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-11-05 14:11:32:413 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-11-05 14:23:44:836 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-11-05 14:35:05:248 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-11-05 15:12:32:769 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**permission_refused**

```
2026-11-05 11:01:03:030 [ERROR] [init] ErgoptiPlus runtime dependency failed (accessibility: Accessibility permission was not granted within 600 s) — shutting down embedded Hammerspoon.
2026-11-05 11:01:03:030 [ERROR] [init] Fatal abort at boot stage 'accessibility': Accessibility permission was not granted within 600 s.
```

**karabiner_lease_failure**

```
2026-11-05 11:37:44:038 [WARNING] [karabiner] Karabiner lease could not be provisioned on resume (owned-runtime-not-admitted); resuming without a live lease.
2026-11-05 13:53:37:201 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
2026-11-05 13:53:39:271 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 1 failed: owned-runtime-not-admitted.
2026-11-05 13:53:39:271 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (owned-runtime-not-admitted).
2026-11-05 13:53:45:671 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (layout-settled).
2026-11-05 13:54:02:473 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 2 failed: owned-runtime-not-admitted.
2026-11-05 13:54:02:473 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 3/3 in 30.0 s (owned-runtime-not-admitted).
2026-11-05 13:54:39:307 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 3 failed: owned-runtime-not-admitted.
2026-11-05 13:54:39:307 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (owned-runtime-not-admitted).
2026-11-05 14:11:33:037 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (layout-settled).
```

**network_failure**

```
2026-11-05 11:33:10:118 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-11-05 11:36:53:073 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```

**update_check**

```
2026-11-05 10:10:35:816 [START] [updater.auto_check] Starting automatic update checks…
2026-11-05 10:10:35:816 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
2026-11-05 10:10:57:304 [START] [updater.auto_check] Starting automatic update checks…
2026-11-05 10:10:57:304 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
2026-11-05 11:17:06:759 [START] [updater.auto_check] Starting automatic update checks…
2026-11-05 11:17:06:759 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
2026-11-05 11:17:19:304 [START] [updater.auto_check] Starting automatic update checks…
2026-11-05 11:17:19:304 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
2026-11-05 11:17:49:305 [INFO] [updater.auto_check] Background update check due (catch_up, channel main).
2026-11-05 11:32:33:871 [START] [updater.auto_check] Starting automatic update checks…
```

</details>
