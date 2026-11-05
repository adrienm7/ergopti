# Field log analysis

Logs: ErgoptiPlus_2026-11-05.log (21190 lines, 21118 records, 32 continuation lines); span 2026-11-05 10:10:17:169 to 2026-11-05 17:57:56:709.
Previous report compared: mac-2026-11-05_164607.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 114 | slow | main_thread.hold over its 250 ms budget | 38 | max 1581 ms at 2026-11-05 10:10:36:159 |
| 2 | 69 | slow | hotpath:preview.rebuild over its 5 ms budget | 23 | max 10.55 ms at 2026-11-05 11:51:54:869 |
| 3 | 35 | error | [karabiner] Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (layout-settled). | 7 | 2026-11-05 14:11:33:037 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (layout-settled). |
| 4 | 18 | slow | keystats.ingest over its 500 ms budget | 6 | max 1159 ms at 2026-11-05 16:57:32:826 |
| 5 | 15 | warning | [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted. | 15 | 2026-11-05 10:10:36:159 [WARNING] [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted. |
| 6 | 15 | slow | hotpath:tooltip.show_predictions over its 5 ms budget | 5 | max 15.85 ms at 2026-11-05 17:49:54:469 |
| 7 | 12 | warning | [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/RemapRuntime/<*>-ergopti.<*>/payload for the administrator install. | 12 | 2026-11-05 10:10:52:726 [WARNING] [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/… |
| 8 | 10 | error | [adapters.file_system] read_with_status(): cannot inspect '<*>' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner | 2 | 2026-11-05 11:37:43:969 [ERROR] [adapters.file_system] read_with_status(): cannot inspect '~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner |
| 9 | 10 | error | [llm.api_ollama] Ollama native lifecycle receipt unsettled did not commit (result: false); launch remains retryable. | 2 | 2026-11-05 11:36:52:032 [ERROR] [llm.api_ollama] Ollama native lifecycle receipt unsettled did not commit (result: false); launch remains retryable. |
| 10 | 10 | error | [llm.api_ollama] Ollama native lifecycle receipt unsettled left unsettled native ownership; retry fenced. | 2 | 2026-11-05 11:36:52:032 [ERROR] [llm.api_ollama] Ollama native lifecycle receipt unsettled left unsettled native ownership; retry fenced. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ❌ lease: fail (2026-11-05 17:48:25:612, last of 2 runs, 2 failed)
- ❌ owned_install: fail (2026-11-05 17:48:27:235, last of 2 runs, 2 failed)
- ❌ owned_runtime: fail (2026-11-05 17:48:29:122, last of 2 runs, 2 failed)
- ❌ owned_start: fail (2026-11-05 17:48:29:155, last of 2 runs, 2 failed)
- ✅ network: pass (2026-11-05 17:48:33:866, last of 2 runs, 0 failed)
- ✅ toolchain: pass (2026-11-05 17:48:35:600, last of 2 runs, 0 failed)
- ✅ login_items: pass (2026-11-05 17:48:55:745, last of 2 runs, 0 failed)
- ✅ composer: pass (2026-11-05 17:48:57:258, last of 2 runs, 0 failed)
- ✅ boot_cost: pass (2026-11-05 17:48:57:263, last of 2 runs, 0 failed)
- ✅ idle_cost: pass (2026-11-05 17:49:27:326, last of 2 runs, 0 failed)
- ✅ layout_rows: pass (2026-11-05 17:49:30:694, last of 2 runs, 0 failed)
- ✅ permissions: pass (2026-11-05 17:49:30:876, last of 2 runs, 0 failed)
- ✅ event_taps: pass (2026-11-05 17:49:31:424, last of 2 runs, 0 failed)
- ✅ input_sources: pass (2026-11-05 17:49:31:572, last of 2 runs, 0 failed)
- ✅ storage: pass (2026-11-05 17:49:36:332, last of 2 runs, 0 failed)
- ✅ launcher_roles: pass (2026-11-05 17:49:36:437, last of 2 runs, 0 failed)
- ✅ network_hosts: pass (2026-11-05 17:49:39:612, last of 2 runs, 0 failed)
- ✅ ollama_blob_host: pass (2026-11-05 17:49:42:660, last of 2 runs, 0 failed)
- ❌ typing_selftest: fail (2026-11-05 17:49:48:672, last of 2 runs, 2 failed)
- ✅ capslock_chord: pass (2026-11-05 17:49:48:680, last of 2 runs, 0 failed)
- ✅ gesture_frames: pass (2026-11-05 17:49:48:689, last of 2 runs, 0 failed)
- ❌ hotstring_roundtrip: fail (2026-11-05 17:49:53:827, last of 2 runs, 2 failed)
- ✅ prediction_tooltip: pass (2026-11-05 17:49:53:837, last of 2 runs, 1 failed)
- ✅ menu_build: pass (2026-11-05 17:49:54:001, last of 2 runs, 0 failed)
- ✅ pac_fallback: pass (2026-11-05 17:53:21:157, last of 2 runs, 0 failed)
- ✅ ai_local: pass (2026-11-05 17:53:21:344, last of 2 runs, 0 failed)
- ✅ slow_lines: pass (2026-11-05 17:53:21:603, last of 2 runs, 0 failed)
- ✅ fifo_safety: pass (2026-11-05 17:53:22:723, last of 2 runs, 0 failed)
- ✅ local_servers: pass (2026-11-05 17:53:22:909, last of 2 runs, 0 failed)
- ✅ app_health: pass (2026-11-05 17:53:25:199, last of 2 runs, 0 failed)
- ❌ tap_hold_thresholds: fail (2026-11-05 17:53:25:203, last of 2 runs, 2 failed)
- ❌ tap_copy: fail (2026-11-05 17:53:25:209, last of 2 runs, 2 failed)
- ✅ apple_shortcuts: pass (2026-11-05 17:53:25:259, last of 2 runs, 0 failed)
- ❌ owned_pause: fail (2026-11-05 17:54:10:328, last of 2 runs, 2 failed)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 26 pass, ❌ 9 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

19 error group(s), 36 warning group(s); 165 occurrence(s); 5 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | karabiner | Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (layout-settled). | 7 | 2026-11-05 14:11:33:037 | 2026-11-05 16:51:12:632 |  |
| ERROR | llm.api_ollama | Ollama native lifecycle receipt unsettled left unsettled native ownership; retry fenced. | 2 | 2026-11-05 11:36:52:032 | 2026-11-05 17:52:32:144 |  |
| ERROR | llm.api_ollama | Ollama native lifecycle receipt unsettled did not commit (result: false); launch remains retryable. | 2 | 2026-11-05 11:36:52:032 | 2026-11-05 17:52:32:144 |  |
| ERROR | ollama_deps | Ollama daemon start failed (exit=<*>) — Impossible de lancer le démon Ollama. | 2 | 2026-11-05 11:36:52:032 | 2026-11-05 17:52:32:144 |  |
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 2 | 2026-11-05 11:36:53:073 | 2026-11-05 17:52:33:161 |  |
| ERROR | llm.api_ollama | Ollama startup cleanup remains unsettled; sibling launch fenced. | 2 | 2026-11-05 11:36:53:073 | 2026-11-05 17:52:33:161 |  |
| ERROR | llm.api_ollama | ensure_running() did not commit: false | 2 | 2026-11-05 11:36:53:073 | 2026-11-05 17:52:33:161 |  |
| ERROR | adapters.file_system | read_with_status(): cannot inspect '<*>' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner | 2 | 2026-11-05 11:37:43:969 | 2026-11-05 17:53:25:203 |  |
| ERROR | llm.api_ollama | Ollama warmup resume is waiting for prior cancellation: true. | 2 | 2026-11-05 11:37:44:023 | 2026-11-05 17:53:25:266 |  |
| ERROR | shortcuts.script_control | Pause rollback failed: api_ollama.pause_warmup rollback returned false: nil. | 2 | 2026-11-05 11:37:44:023 | 2026-11-05 17:53:25:266 |  |
| ERROR | shortcuts.script_control | Local pause quiescence failed; restoring native RESUMED before publication: api_ollama.pause_warmup returned false: nil; rollback failures: api_ollama.pause_warmup rollback returned false: nil. | 2 | 2026-11-05 11:37:44:036 | 2026-11-05 17:53:25:284 |  |
| ERROR | shortcuts.script_control | Script pause transaction failed; settled state preserved: api_ollama.pause_warmup returned false: nil; rollback failures: api_ollama.pause_warmup rollback returned false: nil. | 2 | 2026-11-05 11:37:44:038 | 2026-11-05 17:53:25:287 |  |
| ERROR | accessibility_wait | Accessibility still not granted after <*> s. | 1 | 2026-11-05 11:01:03:029 | 2026-11-05 11:01:03:029 |  |
| ERROR | init | ErgoptiPlus runtime dependency failed (accessibility: Accessibility permission was not granted within <*> s) — shutting down embedded Hammerspoon. | 1 | 2026-11-05 11:01:03:030 | 2026-11-05 11:01:03:030 |  |
| ERROR | init | Fatal abort at boot stage '<*>': Accessibility permission was not granted within <*> s. | 1 | 2026-11-05 11:01:03:030 | 2026-11-05 11:01:03:030 |  |
| ERROR | karabiner.lease | '<*>' called before M.init() — lease controller unavailable: caller | 1 | 2026-11-05 11:01:03:045 | 2026-11-05 11:01:03:045 |  |
| ERROR | remap.runtime_install | Owned runtime install refused (install_refused): helper_signature | 1 | 2026-11-05 11:33:08:433 | 2026-11-05 11:33:08:433 |  |
| ERROR | karabiner | Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (owned-runtime-not-admitted). | 1 | 2026-11-05 13:54:39:307 | 2026-11-05 13:54:39:307 |  |
| ERROR | remap.runtime_install | Owned runtime install refused (install_failed): administrator shell status <*> | 1 | 2026-11-05 17:48:27:235 | 2026-11-05 17:48:27:235 | new |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 23 | 2026-11-05 11:51:54:869 | 2026-11-05 17:57:40:741 |  |
| WARNING | karabiner | Regenerate skipped — the owned Karabiner runtime is not admitted. | 15 | 2026-11-05 10:10:36:159 | 2026-11-05 17:54:24:177 |  |
| WARNING | remap.runtime_owner | Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/RemapRuntime/<*>-ergopti.<*>/payload for the administrat… | 12 | 2026-11-05 10:10:52:726 | 2026-11-05 17:54:23:605 |  |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 8 | 2026-11-05 10:10:36:463 | 2026-11-05 17:48:29:039 |  |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; append: lock=<*> journal=<*> prepare=<*> publish=<*> write=<*> clear=<*> settle=<*> release=<*> ms; metadata_commands=<*> in <*> ms; entries=<*> statements=<*>). | 6 | 2026-11-05 15:48:37:574 | 2026-11-05 16:57:32:826 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 5 | 2026-11-05 11:20:45:933 | 2026-11-05 17:57:54:676 |  |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 5 | 2026-11-05 11:20:47:212 | 2026-11-05 17:57:55:903 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 5 | 2026-11-05 11:20:47:212 | 2026-11-05 17:57:55:903 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 5 | 2026-11-05 12:09:49:070 | 2026-11-05 14:34:12:900 |  |
| WARNING | HotPath | Slow tooltip.show_predictions: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 5 | 2026-11-05 14:50:55:205 | 2026-11-05 17:54:03:814 |  |
| WARNING | karabiner | Karabiner lease auto-recovery attempt <*> failed: owned-runtime-not-admitted. | 3 | 2026-11-05 13:53:39:271 | 2026-11-05 13:54:39:307 |  |
| WARNING | key_event_health | A non-character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across … | 3 | 2026-11-05 14:42:56:725 | 2026-11-05 15:44:05:793 |  |
| WARNING | BootProfile | Over budget: boot took <*> ms (budget <*> ms). | 2 | 2026-11-05 10:10:35:925 | 2026-11-05 11:17:06:852 |  |
| WARNING | field_run | Field run mac-<*><*><*>_1<*> cut short by a reload (menu) during step '<*>'; closed as interrupted. | 2 | 2026-11-05 10:10:56:041 | 2026-11-05 11:17:18:190 |  |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 2 | 2026-11-05 11:20:47:206 | 2026-11-05 11:42:10:903 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 2 | 2026-11-05 11:33:10:118 | 2026-11-05 17:48:29:175 |  |
| WARNING | download_window | Progress UI flipped to error state: Impossible de lancer le démon Ollama. | 2 | 2026-11-05 11:36:52:032 | 2026-11-05 17:52:32:144 |  |
| WARNING | karabiner | Karabiner lease could not be provisioned on resume (owned-runtime-not-admitted); resuming without a live lease. | 2 | 2026-11-05 11:37:44:038 | 2026-11-05 17:53:25:287 |  |
| WARNING | init | Over budget: reload took <*> ms (budget <*> ms). | 2 | 2026-11-05 11:38:42:602 | 2026-11-05 17:54:23:772 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (owned-runtime-not-admitted). | 2 | 2026-11-05 13:53:39:271 | 2026-11-05 13:54:02:473 |  |
| WARNING | shortcuts.actions.screen_capture | Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime. | 2 | 2026-11-05 14:36:25:603 | 2026-11-05 17:22:15:573 |  |
| WARNING | tooltip_llm | Over budget: prediction.display took <*> ms (budget <*> ms). | 2 | 2026-11-05 17:49:54:453 | 2026-11-05 17:53:51:716 | new |
| WARNING | runtime | An hs.timer.new callback (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=<*> ms, boot.stage_cpu=<*> ms, boot.stage=<*> ms, boot.stage_cpu=… | 1 | 2026-11-05 10:10:36:159 | 2026-11-05 10:10:36:159 |  |
| WARNING | keymap.selftest_gate | A field-run selftest key was consumed (no_dev_source); no application received it. | 1 | 2026-11-05 11:34:27:231 | 2026-11-05 11:34:27:231 |  |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: operation. | 1 | 2026-11-05 11:36:52:032 | 2026-11-05 11:36:52:032 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (unexpected-worker-loss). | 1 | 2026-11-05 13:53:37:201 | 2026-11-05 13:53:37:201 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (layout-settled). | 1 | 2026-11-05 13:53:45:671 | 2026-11-05 13:53:45:671 |  |
| WARNING | HotPath | Slow hotstring.match: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 1 | 2026-11-05 13:55:20:159 | 2026-11-05 13:55:20:159 |  |
| WARNING | key_event_health | A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across… | 1 | 2026-11-05 14:42:52:725 | 2026-11-05 14:42:52:725 |  |
| WARNING | HotPath | Slow keydown: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 1 | 2026-11-05 14:51:12:585 | 2026-11-05 14:51:12:585 |  |
| WARNING | key_event_health | A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a ru… | 1 | 2026-11-05 15:13:11:772 | 2026-11-05 15:13:11:772 |  |
| WARNING | key_event_health | A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or … | 1 | 2026-11-05 15:13:12:772 | 2026-11-05 15:13:12:772 |  |
| WARNING | key_event_health | Key events reached the keymap taps <*> ms or more late: the main thread held them (<*> times); session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a rule swi… | 1 | 2026-11-05 16:39:57:842 | 2026-11-05 16:39:57:842 |  |
| WARNING | runtime | An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-11-05 16:57:32:826 | 2026-11-05 16:57:32:826 | new |
| WARNING | key_event_health | Key events reached the keymap taps <*> ms or more late: the main thread held them; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a rule switch), <*> ke… | 1 | 2026-11-05 17:01:12:851 | 2026-11-05 17:01:12:851 | new |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> secure_field=<*> destination=<*> ms). | 1 | 2026-11-05 17:42:10:931 | 2026-11-05 17:42:10:931 | new |

<details><summary>One example line per group</summary>

```
2026-11-05 14:11:33:037 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (layout-settled).
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
2026-11-05 13:54:39:307 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (owned-runtime-not-admitted).
```
```
2026-11-05 17:48:27:235 [ERROR] [remap.runtime_install] Owned runtime install refused (install_failed): administrator shell status 1
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
2026-11-05 12:09:49:070 [WARNING] [keymap.utils] Slow ignored-window probe 502 ms (watchers=0 focused_window=502 ms).
```
```
2026-11-05 14:50:55:205 [WARNING] [HotPath] Slow tooltip.show_predictions: 14.75 ms own, 14.75 ms total, parent none (0 similar since the last line).
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
2026-11-05 11:33:10:118 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
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
2026-11-05 13:53:39:271 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (owned-runtime-not-admitted).
```
```
2026-11-05 14:36:25:603 [WARNING] [shortcuts.actions.screen_capture] Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime.
```
```
2026-11-05 17:49:54:453 [WARNING] [tooltip_llm] Over budget: prediction.display took 4110 ms (budget 2000 ms).
```
```
2026-11-05 10:10:36:159 [WARNING] [runtime] An hs.timer.new callback (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:139) held the main thread for 1581 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=491.2 ms, boot.stage…
```
```
2026-11-05 11:34:27:231 [WARNING] [keymap.selftest_gate] A field-run selftest key was consumed (no_dev_source); no application received it.
```
```
2026-11-05 11:36:52:032 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: operation.
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
```
2026-11-05 16:57:32:826 [WARNING] [runtime] An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2338) held the main thread for 1159 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 60->61 MB.
```
```
2026-11-05 17:01:12:851 [WARNING] [key_event_health] Key events reached the keymap taps 250 ms or more late: the main thread held them; session totals: 3115 key-down(s), 3114 key-up(s), 1 key-up(s) without key-down, 1 key-down(s) without key-up, 4 key(s) stuck over 3.0 s, 0 character key(s) held 50…
```
```
2026-11-05 17:42:10:931 [WARNING] [keymap.utils] Slow ignored-window probe 323 ms (watchers=0 focused_window=321 application=0 app_name=0 title=0 context_watchers=1 secure_field=0 destination=0 ms).
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 10 | 1253 | 19115 | 4376 | 19115 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| boot.stage:Accessibility permission | 10 | 0.5 | 17020 | 3104 | 17020 | no budget declared | — |
| boot.cpu | 10 | 760 | 1854 | 912 | 1854 | no budget declared | — |
| boot.stage:UI: karabiner.init | 10 | 104 | 491 | 138 | 491 | no budget declared | — |
| boot.stage:Config-dependent module requires | 20 | 152 | 190 | 163 | 321 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 10 | 172 | 294 | 189 | 294 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 10 | 193 | 288 | 216 | 288 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 10 | 147 | 192 | 147 | 192 | no budget declared | — |
| boot.stage:Keymap engine started | 10 | 29.2 | 57.6 | 37.05 | 57.6 | no budget declared | — |
| boot.stage:Config schema migration | 20 | 27 | 34.2 | 27.89 | 46.1 | no budget declared | — |
| boot.stage:File watchers armed | 10 | 6.7 | 39.3 | 10.42 | 39.3 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 10 | 11.7 | 37.1 | 14.2 | 37.1 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 10 | 5.7 | 18.2 | 8.67 | 18.2 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 20 | 7 | 11.4 | 7.33 | 11.8 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 20 | 1.8 | 4.1 | 2.46 | 10.4 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 10 | 5 | 7.6 | 5.76 | 7.6 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 10 | 0.5 | 6.7 | 1.52 | 6.7 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 10 | 1 | 4.7 | 1.85 | 4.7 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 20 | 1.5 | 2.5 | 1.81 | 4.5 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 20 | 1.2 | 2.1 | 1.34 | 3.4 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 10 | 0.3 | 2.9 | 0.67 | 2.9 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 20 | 0.2 | 0.4 | 0.32 | 1.7 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 20 | 0.6 | 1.5 | 0.77 | 1.6 | no budget declared | — |
| boot.stage:UI: menu ready | 10 | 0.4 | 0.9 | 0.51 | 0.9 | no budget declared | — |

Worst occurrences:

- boot.total: 19115 ms at 2026-11-05 10:10:35:924, 15224 ms at 2026-11-05 11:17:06:852, 1381 ms at 2026-11-05 17:47:52:578
- boot.stage:Accessibility permission: 17020 ms at 2026-11-05 10:10:34:579, 14002 ms at 2026-11-05 11:17:06:051, 11.4 ms at 2026-11-05 17:47:51:684
- boot.cpu: 1854 ms at 2026-11-05 10:10:35:925, 1083 ms at 2026-11-05 11:17:06:852, 968 ms at 2026-11-05 17:47:52:578
- boot.stage:UI: karabiner.init: 491 ms at 2026-11-05 10:10:35:726, 115 ms at 2026-11-05 11:17:06:687, 107 ms at 2026-11-05 17:47:52:380
- boot.stage:Config-dependent module requires: 321 ms at 2026-11-05 10:10:17:509, 190 ms at 2026-11-05 17:54:23:039, 188 ms at 2026-11-05 17:48:27:886
- boot.stage:Shortcuts pre-start: 294 ms at 2026-11-05 10:10:34:874, 222 ms at 2026-11-05 17:47:51:907, 222 ms at 2026-11-05 11:17:06:274
- boot.stage:Hotstring groups registered (personal + dynamic + common): 288 ms at 2026-11-05 17:47:52:214, 271 ms at 2026-11-05 10:10:35:180, 222 ms at 2026-11-05 17:48:28:352
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 192 ms at 2026-11-05 17:47:52:572, 179 ms at 2026-11-05 10:10:35:906, 168 ms at 2026-11-05 17:48:28:665
- boot.stage:Keymap engine started: 57.6 ms at 2026-11-05 11:17:06:571, 53.1 ms at 2026-11-05 11:32:33:713, 51.1 ms at 2026-11-05 17:47:52:273
- boot.stage:Config schema migration: 46.1 ms at 2026-11-05 10:10:17:556, 34.2 ms at 2026-11-05 17:54:23:074, 29.3 ms at 2026-11-05 11:38:41:804
- boot.stage:File watchers armed: 39.3 ms at 2026-11-05 11:38:42:592, 13 ms at 2026-11-05 10:10:35:922, 8.4 ms at 2026-11-05 10:10:57:382
- boot.stage:TOML discovery + ordering: 37.1 ms at 2026-11-05 17:48:28:129, 17.9 ms at 2026-11-05 10:10:34:908, 16.9 ms at 2026-11-05 11:38:42:089

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 6 | 1400 | 13447 | 5342 | 13447 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| reload.total | 6 | 1375 | 13444 | 5335 | 13444 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |

Worst occurrences:

- reload.request_to_boot: 13447 ms at 2026-11-05 11:38:29:155, 13395 ms at 2026-11-05 17:54:10:377, 1429 ms at 2026-11-05 17:48:27:251
- reload.total: 13444 ms at 2026-11-05 11:38:42:602, 13393 ms at 2026-11-05 17:54:23:772, 1428 ms at 2026-11-05 17:48:28:681

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 14 | 89.5 | 246 | 110 | 246 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| phase:menu.rebuild | 23 | — | — | 129 | 580 | no budget declared | — |
| phase:menu_item.keyboard_layout | 23 | — | — | 43.62 | 485 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 23 | — | — | 30.98 | 415 | no budget declared | — |
| phase:menu_item.shortcuts | 23 | — | — | 48.09 | 320 | no budget declared | — |
| menu.submenu:keyboard_layout | 14 | 9.4 | 162 | 31.27 | 162 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 23 | — | — | 11.89 | 66.58 | no budget declared | — |
| phase:menu_keyboard_layout.number_row | 23 | — | — | 9.16 | 63.27 | no budget declared | — |
| menu.submenu:shortcuts | 14 | 33.5 | 45.3 | 34.91 | 45.3 | no budget declared | — |
| phase:menu_item.gestures | 23 | — | — | 9.12 | 24.98 | no budget declared | — |
| menu.submenu:metrics | 6 | 11.6 | 20 | 11.5 | 20 | no budget declared | — |
| menu.submenu:debug | 1 | 18 | 18 | 18 | 18 | no budget declared | — |
| phase:menu_item.debug | 23 | — | — | 1.14 | 17.97 | no budget declared | — |
| menu.app_exclusions | 14 | 1 | 17.7 | 4.58 | 17.7 | no budget declared | — |
| phase:menu_item.metrics | 23 | — | — | 1.88 | 13.31 | no budget declared | — |
| phase:menu_item.llm | 23 | — | — | 7.24 | 13.11 | no budget declared | — |
| menu.submenu:llm | 14 | 6.5 | 13.1 | 7.51 | 13.1 | no budget declared | — |
| menu.submenu:gestures | 14 | 7.5 | 11.2 | 7.72 | 11.2 | no budget declared | — |
| phase:menu_item.about | 23 | — | — | 0.39 | 5.85 | no budget declared | — |
| phase:menu_item.hotstrings | 23 | — | — | 3.27 | 4.99 | no budget declared | — |
| menu.submenu:hotstrings | 7 | 3.4 | 3.7 | 3.34 | 3.7 | no budget declared | — |
| phase:menu_keyboard_layout.magic_key | 23 | — | — | 0.74 | 3.46 | no budget declared | — |
| phase:menu_item.apps | 23 | — | — | 0.33 | 3.43 | no budget declared | — |
| phase:menu_item.tap_holds | 23 | — | — | 1.63 | 2.97 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 23 | — | — | 0.23 | 0.31 | no budget declared | — |
| phase:menu_item.configuration | 23 | — | — | 0.05 | 0.15 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 23 | — | — | 0.09 | 0.14 | no budget declared | — |
| phase:menu_item.language | 23 | — | — | 0.04 | 0.06 | no budget declared | — |
| phase:menu_item.reload | 23 | — | — | 0.01 | 0.02 | no budget declared | — |
| phase:menu_item.quit | 23 | — | — | 0.01 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 246 ms at 2026-11-05 16:51:10:605, 159 ms at 2026-11-05 17:57:54:131, 119 ms at 2026-11-05 17:49:54:000
- menu.submenu:keyboard_layout: 162 ms at 2026-11-05 16:51:10:605, 87.5 ms at 2026-11-05 17:57:54:131, 52.5 ms at 2026-11-05 17:49:54:000
- menu.submenu:shortcuts: 45.3 ms at 2026-11-05 11:32:36:424, 44.8 ms at 2026-11-05 17:47:54:905, 37.2 ms at 2026-11-05 11:38:44:959
- menu.submenu:metrics: 20 ms at 2026-11-05 11:32:36:424, 16.7 ms at 2026-11-05 17:47:54:905, 13.3 ms at 2026-11-05 11:17:21:700
- menu.app_exclusions: 17.7 ms at 2026-11-05 11:32:36:376, 14.1 ms at 2026-11-05 17:47:54:851, 11.2 ms at 2026-11-05 11:17:21:651
- menu.submenu:llm: 13.1 ms at 2026-11-05 17:48:31:071, 11.2 ms at 2026-11-05 16:51:10:605, 9 ms at 2026-11-05 17:57:54:131
- menu.submenu:gestures: 11.2 ms at 2026-11-05 16:51:10:605, 8.5 ms at 2026-11-05 17:54:26:078, 8.4 ms at 2026-11-05 17:48:31:071
- menu.submenu:hotstrings: 3.7 ms at 2026-11-05 16:51:10:605, 3.5 ms at 2026-11-05 11:17:09:257, 3.4 ms at 2026-11-05 10:10:38:219

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 38 | 488 | 1159 | 523 | 1581 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (38) |

Worst occurrences:

- main_thread.hold: 1581 ms at 2026-11-05 10:10:36:159 (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:139), 1159 ms at 2026-11-05 16:57:32:826 (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2338), 992 ms at 2026-11-05 11:17:07:042 (...s/static/ergopti_plus/macos/infra/accessibility_wait.lua:139)

### Hotstrings

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:hotstring.match | 1 | 10.48 | 10.48 | 10.48 | 10.48 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:tooltip.show_predictions | 5 | 11.65 | 15.85 | 11.06 | 15.85 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (5) |
| hotpath:preview.rebuild | 23 | 6.64 | 10.36 | 6.99 | 10.55 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (23) |

Worst occurrences:

- hotpath:tooltip.show_predictions: 15.85 ms at 2026-11-05 17:49:54:469, 14.75 ms at 2026-11-05 14:50:55:205, 11.65 ms at 2026-11-05 17:53:51:728
- hotpath:preview.rebuild: 10.55 ms at 2026-11-05 11:51:54:869, 10.36 ms at 2026-11-05 16:41:21:668, 9.31 ms at 2026-11-05 17:54:10:237

### LLM requests

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| llm.ttft | 4 | 1961 | 4110 | 2598 | 4110 | 2000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| llm.stream | 5 | 1959 | 4109 | 2412 | 4109 | no budget declared | — |
| llm.parsed:remote | 4 | 1957 | 4108 | 2594 | 4108 | no budget declared | — |

Worst occurrences:

- llm.ttft: 4110 ms at 2026-11-05 17:49:54:453, 3220 ms at 2026-11-05 17:53:51:716, 1961 ms at 2026-11-05 14:50:55:191
- llm.stream: 4109 ms at 2026-11-05 17:49:54:489, 3218 ms at 2026-11-05 17:53:51:752, 1959 ms at 2026-11-05 14:50:55:271
- llm.parsed:remote: 4108 ms at 2026-11-05 17:49:54:452, 3213 ms at 2026-11-05 17:53:51:715, 1957 ms at 2026-11-05 14:50:55:189

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 6 | 582 | 1159 | 726 | 1159 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (6) |
| healthcheck.sync | 1 | 5.2 | 5.2 | 5.2 | 5.2 | 5 ms (stated in the log line) | ❌ over (1) |

Worst occurrences:

- keystats.ingest: 1159 ms at 2026-11-05 16:57:32:826, 960 ms at 2026-11-05 15:48:37:574, 586 ms at 2026-11-05 16:09:47:237

### Input

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| input.late_key_event | 2 | 586 | 586 | 586 | 586 | 250 ms (stated in the log line) | ❌ over (2) |

Worst occurrences:

- input.late_key_event: 586 ms at 2026-11-05 16:39:57:842, 586 ms at 2026-11-05 17:01:12:851

### Other hot-path segments

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:keydown | 1 | 5.24 | 5.24 | 5.24 | 5.24 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 2 | — | — | 20010 | 20012 | no budget declared | — |
| phase:process.sqlite3 | 2 | — | — | 4555 | 4748 | no budget declared | — |
| phase:process.python3 | 38 | — | — | 597 | 4602 | no budget declared | — |
| phase:process.defaults | 3140 | — | — | 18.82 | 2331 | no budget declared | — |
| phase:process.vmmap | 2 | — | — | 1929 | 2270 | no budget declared | — |
| phase:process.sh | 10 | — | — | 563 | 1136 | no budget declared | — |
| phase:process.spctl | 2 | — | — | 712 | 736 | no budget declared | — |
| phase:process.ErgoptiPlus | 102 | — | — | 118 | 700 | no budget declared | — |
| phase:process.brew | 2 | — | — | 278 | 414 | no budget declared | — |
| phase:boot.stage | 96 | — | — | 46.15 | 258 | no budget declared | — |
| phase:boot.requires | 64 | — | — | 28.12 | 255 | no budget declared | — |
| phase:process.awk | 4 | — | — | 107 | 252 | no budget declared | — |
| phase:boot.stage_cpu | 96 | — | — | 29.78 | 209 | no budget declared | — |
| phase:process.open | 1 | — | — | 204 | 204 | no budget declared | — |
| phase:process.codesign | 10 | — | — | 86.96 | 172 | no budget declared | — |
| phase:process.pgrep | 14 | — | — | 67.01 | 166 | no budget declared | — |
| phase:process.bash | 2 | — | — | 126 | 158 | no budget declared | — |
| phase:process.mkdir | 10 | — | — | 56.28 | 133 | no budget declared | — |
| phase:shell.mkdir | 8 | — | — | 69.38 | 133 | no budget declared | — |
| phase:shell.ls | 32 | — | — | 47.61 | 101 | no budget declared | — |
| phase:shell.curl | 2 | — | — | 83.56 | 94.89 | no budget declared | — |
| phase:shell.sw_vers | 4 | — | — | 80.75 | 93.81 | no budget declared | — |
| phase:shell.find | 4 | — | — | 59.14 | 82.71 | no budget declared | — |
| phase:process.launchctl | 4 | — | — | 24.95 | 80.14 | no budget declared | — |
| phase:shell.ioreg | 4 | — | — | 51.15 | 78.46 | no budget declared | — |
| phase:process.shortcuts | 4 | — | — | 61 | 72.09 | no budget declared | — |
| phase:process.tccutil | 1 | — | — | 43.97 | 43.97 | no budget declared | — |
| phase:process.xmllint | 16 | — | — | 6.99 | 41.39 | no budget declared | — |
| phase:process.ps | 8 | — | — | 14.73 | 39.89 | no budget declared | — |
| phase:process.plutil | 8 | — | — | 10.16 | 39.73 | no budget declared | — |
| phase:process.systemextensionsctl | 2 | — | — | 35.44 | 38.3 | no budget declared | — |
| phase:process.grep | 4 | — | — | 21.49 | 36.9 | no budget declared | — |
| phase:hotpath.keydown | 5532 | — | — | 1.24 | 29.97 | no budget declared | — |
| phase:hotpath.preview.rebuild | 2956 | — | — | 1.73 | 26.3 | no budget declared | — |
| phase:preview.total | 3172 | — | — | 1.7 | 26.3 | no budget declared | — |
| phase:process.mkfifo | 1 | — | — | 22.01 | 22.01 | no budget declared | — |
| phase:hotstring_load.common_file | 8 | — | — | 11.04 | 20.89 | no budget declared | — |
| phase:preview.resolve | 3172 | — | — | 0.28 | 17.02 | no budget declared | — |
| phase:hotpath.tooltip.show_predictions | 7 | — | — | 9.91 | 15.85 | no budget declared | — |
| phase:hotpath.hotstring.match | 3014 | — | — | 0.26 | 12.84 | no budget declared | — |
| phase:toml.parse | 100 | — | — | 1.32 | 8.41 | no budget declared | — |
| phase:process.scutil | 2 | — | — | 8.14 | 8.15 | no budget declared | — |
| phase:preview.providers | 3172 | — | — | 0.37 | 7.86 | no budget declared | — |
| phase:hotpath.hotstring.expand | 58 | — | — | 0.39 | 4.32 | no budget declared | — |
| phase:process.id | 2 | — | — | 3.12 | 3.56 | no budget declared | — |
| phase:process.rm | 1 | — | — | 2.91 | 2.91 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 19
- counter:runtime.timer_hold_over_1000ms: 1
- counter:runtime.timer_hold_over_250ms: 30

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 20 | 2026-11-05 10:10:17:170 | 2026-11-05 17:54:22:836 |
| stop | 9 | 2026-11-05 10:10:56:012 | 2026-11-05 17:54:10:381 |
| reload | 6 | 2026-11-05 10:10:55:983 | 2026-11-05 17:54:10:377 |
| sleep_wake | 5 | 2026-11-05 13:53:36:501 | 2026-11-05 15:12:32:769 |
| permission_refused | 2 | 2026-11-05 11:01:03:030 | 2026-11-05 11:01:03:030 |
| karabiner_lease_failure | 15 | 2026-11-05 11:37:44:038 | 2026-11-05 17:53:25:287 |
| network_failure | 4 | 2026-11-05 11:33:10:118 | 2026-11-05 17:52:33:161 |
| update_check | 21 | 2026-11-05 10:10:35:816 | 2026-11-05 17:54:23:669 |

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
2026-11-05 17:48:27:255 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-05 17:54:10:381 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-05 10:10:55:983 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: menu).
2026-11-05 11:17:18:150 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: menu).
2026-11-05 11:33:08:441 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
2026-11-05 11:38:29:155 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
2026-11-05 17:48:27:251 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
2026-11-05 17:54:10:377 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
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
2026-11-05 17:48:29:175 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-11-05 17:52:33:161 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
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
