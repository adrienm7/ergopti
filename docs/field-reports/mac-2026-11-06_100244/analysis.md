# Field log analysis

Logs: ErgoptiPlus_2026-11-06.log (6063 lines, 5754 records, 303 continuation lines); span 2026-11-06 00:11:43:324 to 2026-11-06 10:12:40:109.
Previous report compared: mac-2026-11-05_200642.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 21 | slow | hotpath:preview.rebuild over its 5 ms budget | 7 | max 9.29 ms at 2026-11-06 09:51:29:215 |
| 2 | 21 | slow | main_thread.hold over its 250 ms budget | 7 | max 537 ms at 2026-11-06 10:12:36:167 |
| 3 | 6 | warning | [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted. | 6 | 2026-11-06 09:43:26:752 [WARNING] [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted. |
| 4 | 6 | slow | hotpath:tooltip.show_predictions over its 5 ms budget | 2 | max 12.02 ms at 2026-11-06 09:49:15:077 |
| 5 | 5 | error | [adapters.file_system] read_with_status(): cannot inspect '<*>' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner | 1 | 2026-11-06 10:09:05:770 [ERROR] [adapters.file_system] read_with_status(): cannot inspect '~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner |
| 6 | 5 | error | [karabiner] Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (owned-runtime-not-admitted). | 1 | 2026-11-06 09:44:28:890 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (owned-runtime-not-admitted). |
| 7 | 5 | error | [remap.runtime_install] Owned runtime install refused (install_failed): administrator shell status <*> | 1 | 2026-11-06 10:04:29:136 [ERROR] [remap.runtime_install] Owned runtime install refused (install_failed): administrator shell status 1 |
| 8 | 3 | warning | [karabiner] Karabiner lease auto-recovery attempt <*> failed: owned-runtime-not-admitted. | 3 | 2026-11-06 09:43:26:752 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 1 failed: owned-runtime-not-admitted. |
| 9 | 3 | warning | [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/RemapRuntime/<*>-ergopti.<*>/payload for the administrator install. | 3 | 2026-11-06 10:03:54:368 [WARNING] [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/… |
| 10 | 3 | slow | healthcheck.sync over its 5 ms budget | 1 | max 10.2 ms at 2026-11-06 10:05:50:065 |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ❌ lease: fail (2026-11-06 10:04:27:728)
- ❌ owned_install: fail (2026-11-06 10:04:29:136)
- ❌ owned_runtime: fail (2026-11-06 10:04:31:010)
- ❌ owned_start: fail (2026-11-06 10:04:31:038)
- ✅ network: pass (2026-11-06 10:04:34:327)
- ✅ toolchain: pass (2026-11-06 10:04:35:871)
- ✅ login_items: pass (2026-11-06 10:04:56:030)
- ✅ composer: pass (2026-11-06 10:04:57:304)
- ✅ boot_cost: pass (2026-11-06 10:04:57:310)
- ✅ idle_cost: pass (2026-11-06 10:05:27:384)
- ✅ layout_rows: pass (2026-11-06 10:05:30:728)
- ✅ permissions: pass (2026-11-06 10:05:30:930)
- ✅ event_taps: pass (2026-11-06 10:05:31:448)
- ✅ input_sources: pass (2026-11-06 10:05:31:556)
- ✅ storage: pass (2026-11-06 10:05:36:096)
- ✅ launcher_roles: pass (2026-11-06 10:05:36:213)
- ✅ network_hosts: pass (2026-11-06 10:05:38:989)
- ✅ ollama_blob_host: pass (2026-11-06 10:05:41:574)
- ❌ typing_selftest: fail (2026-11-06 10:05:47:582)
- ✅ capslock_chord: pass (2026-11-06 10:05:47:589)
- ✅ gesture_frames: pass (2026-11-06 10:05:47:598)
- ✅ hotstring_roundtrip: pass (2026-11-06 10:05:49:848)
- ✅ prediction_tooltip: pass (2026-11-06 10:05:49:856)
- ✅ menu_build: pass (2026-11-06 10:05:50:023)
- ✅ pac_fallback: pass (2026-11-06 10:09:02:184)
- ✅ ai_local: pass (2026-11-06 10:09:02:283)
- ✅ slow_lines: pass (2026-11-06 10:09:02:358)
- ✅ fifo_safety: pass (2026-11-06 10:09:03:445)
- ✅ local_servers: pass (2026-11-06 10:09:03:634)
- ✅ app_health: pass (2026-11-06 10:09:05:766)
- ❌ tap_hold_thresholds: fail (2026-11-06 10:09:05:770)
- ❌ tap_copy: fail (2026-11-06 10:09:05:774)
- ✅ apple_shortcuts: pass (2026-11-06 10:09:05:825)
- ✅ owned_pause: pass (2026-11-06 10:09:06:330)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 28 pass, ❌ 7 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

3 error group(s), 23 warning group(s); 45 occurrence(s); 3 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | karabiner | Karabiner lease auto-recovery exhausted after <*> attempt(s); rules remain fail-closed (owned-runtime-not-admitted). | 1 | 2026-11-06 09:44:28:890 | 2026-11-06 09:44:28:890 |  |
| ERROR | remap.runtime_install | Owned runtime install refused (install_failed): administrator shell status <*> | 1 | 2026-11-06 10:04:29:136 | 2026-11-06 10:04:29:136 |  |
| ERROR | adapters.file_system | read_with_status(): cannot inspect '<*>' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner | 1 | 2026-11-06 10:09:05:770 | 2026-11-06 10:09:05:770 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 7 | 2026-11-06 09:44:22:562 | 2026-11-06 10:05:48:492 |  |
| WARNING | karabiner | Regenerate skipped — the owned Karabiner runtime is not admitted. | 6 | 2026-11-06 09:43:26:752 | 2026-11-06 10:09:08:065 |  |
| WARNING | karabiner | Karabiner lease auto-recovery attempt <*> failed: owned-runtime-not-admitted. | 3 | 2026-11-06 09:43:26:752 | 2026-11-06 09:44:28:890 |  |
| WARNING | remap.runtime_owner | Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/RemapRuntime/<*>-ergopti.<*>/payload for the administrat… | 3 | 2026-11-06 10:03:54:368 | 2026-11-06 10:09:07:731 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (owned-runtime-not-admitted). | 2 | 2026-11-06 09:43:26:752 | 2026-11-06 09:43:36:853 |  |
| WARNING | key_event_health | A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across… | 2 | 2026-11-06 09:43:50:628 | 2026-11-06 09:53:55:628 |  |
| WARNING | HotPath | Slow tooltip.show_predictions: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 2 | 2026-11-06 09:49:15:077 | 2026-11-06 10:05:51:226 |  |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: RuntimeRefusal at managed_ollama_hint.py:<*> candidate | 2 | 2026-11-06 10:03:55:085 | 2026-11-06 10:04:30:978 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-11-06 09:43:25:113 | 2026-11-06 09:43:25:113 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (unexpected-worker-loss). | 1 | 2026-11-06 09:43:25:661 | 2026-11-06 09:43:25:661 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (layout-settled). | 1 | 2026-11-06 09:43:51:808 | 2026-11-06 09:43:51:808 |  |
| WARNING | gestures.engine | commitGesture x1: BLOCKED — same slot+sign as previous live fire (slot=swipe_4_left sign=<*>) | 1 | 2026-11-06 09:48:41:004 | 2026-11-06 09:48:41:004 |  |
| WARNING | key_event_health | A non-character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across … | 1 | 2026-11-06 09:54:02:629 | 2026-11-06 09:54:02:629 |  |
| WARNING | key_event_health | A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a ru… | 1 | 2026-11-06 09:55:26:629 | 2026-11-06 09:55:26:629 |  |
| WARNING | key_event_health | A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or … | 1 | 2026-11-06 09:55:32:629 | 2026-11-06 09:55:32:629 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 1 | 2026-11-06 10:04:31:058 | 2026-11-06 10:04:31:058 |  |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: cancelled. | 1 | 2026-11-06 10:09:06:400 | 2026-11-06 10:09:06:400 | new |
| WARNING | keymap.utils | Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-06 10:09:07:613 | 2026-11-06 10:09:07:613 | new |
| WARNING | keymap | Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 1 | 2026-11-06 10:09:07:613 | 2026-11-06 10:09:07:613 | new |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 1 | 2026-11-06 10:12:36:167 | 2026-11-06 10:12:36:167 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 1 | 2026-11-06 10:12:36:699 | 2026-11-06 10:12:36:699 |  |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 1 | 2026-11-06 10:12:40:089 | 2026-11-06 10:12:40:089 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 1 | 2026-11-06 10:12:40:089 | 2026-11-06 10:12:40:089 |  |

<details><summary>One example line per group</summary>

```
2026-11-06 09:44:28:890 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (owned-runtime-not-admitted).
```
```
2026-11-06 10:04:29:136 [ERROR] [remap.runtime_install] Owned runtime install refused (install_failed): administrator shell status 1
```
```
2026-11-06 10:09:05:770 [ERROR] [adapters.file_system] read_with_status(): cannot inspect '~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json' safely — missing path prefix: ~/Library/Application Support/ErgoptiPlus/karabiner
```
```
2026-11-06 09:44:22:562 [WARNING] [HotPath] Slow preview.rebuild: 9.02 ms own, 9.02 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-06 09:43:26:752 [WARNING] [karabiner] Regenerate skipped — the owned Karabiner runtime is not admitted.
```
```
2026-11-06 09:43:26:752 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 1 failed: owned-runtime-not-admitted.
```
```
2026-11-06 10:03:54:368 [WARNING] [remap.runtime_owner] Owned runtime unavailable (runtime_not_installed): The owned runtime is not installed: /Library/Application Support/ErgoptiPlus/Runtime/bin/ergoptiplus_remap_cli is missing. The verified artifact waits at ~/Library/Application Support/Ergopti/…
```
```
2026-11-06 09:43:26:752 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (owned-runtime-not-admitted).
```
```
2026-11-06 09:43:50:628 [WARNING] [key_event_health] A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: 0 key-down(s), 1 key-up(s), 1 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 charact…
```
```
2026-11-06 09:49:15:077 [WARNING] [HotPath] Slow tooltip.show_predictions: 12.02 ms own, 12.02 ms total, parent none (0 similar since the last line).
```
```
2026-11-06 10:03:55:085 [WARNING] [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=78): refused: RuntimeRefusal at managed_ollama_hint.py:39 candidate
```
```
2026-11-06 09:43:25:113 [WARNING] [keymap.utils] Slow ignored-window probe 501 ms (watchers=0 focused_window=501 ms).
```
```
2026-11-06 09:43:25:661 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
```
```
2026-11-06 09:43:51:808 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 3/3 in 30.0 s (layout-settled).
```
```
2026-11-06 09:48:41:004 [WARNING] [gestures.engine] commitGesture x1: BLOCKED — same slot+sign as previous live fire (slot=swipe_4_left sign=-1)
```
```
2026-11-06 09:54:02:629 [WARNING] [key_event_health] A non-character key stayed down 7.0 s with no further event: its key-up was lost before the keymap taps; session totals: 613 key-down(s), 614 key-up(s), 2 key-up(s) without key-down, 0 key-down(s) without key-up, 1 key(s) stuck over 3.0 s, 0 char…
```
```
2026-11-06 09:55:26:629 [WARNING] [key_event_health] A character key stayed down 3.1 s with no further event: its key-up was lost before the keymap taps; session totals: 786 key-down(s), 785 key-up(s), 2 key-up(s) without key-down, 0 key-down(s) without key-up, 2 key(s) stuck over 3.0 s, 0 characte…
```
```
2026-11-06 09:55:32:629 [WARNING] [key_event_health] A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: 816 key-down(s), 814 key-up(s), 2 key-up(s) without key-down, 1 key-down(s) without key-up, 2 key(s) stuck o…
```
```
2026-11-06 10:04:31:058 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-06 10:09:06:400 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: cancelled.
```
```
2026-11-06 10:09:07:613 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed.
```
```
2026-11-06 10:09:07:613 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false.
```
```
2026-11-06 10:12:36:167 [WARNING] [menu] Over budget: menu.rebuild took 495 ms (budget 250 ms).
```
```
2026-11-06 10:12:36:699 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```
```
2026-11-06 10:12:40:089 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil.
```
```
2026-11-06 10:12:40:089 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 3 | 1353 | 1415 | 1360 | 1415 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| boot.cpu | 3 | 895 | 1054 | 946 | 1054 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 3 | 239 | 339 | 270 | 339 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 3 | 166 | 237 | 188 | 237 | no budget declared | — |
| boot.stage:Config-dependent module requires | 3 | 175 | 234 | 192 | 234 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 3 | 169 | 176 | 166 | 176 | no budget declared | — |
| boot.stage:UI: karabiner.init | 3 | 119 | 124 | 120 | 124 | no budget declared | — |
| boot.stage:Keymap engine started | 3 | 31.4 | 51.5 | 37.1 | 51.5 | no budget declared | — |
| boot.stage:Config schema migration | 3 | 31.1 | 31.7 | 31.27 | 31.7 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 3 | 12.3 | 14 | 11.57 | 14 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 3 | 9.1 | 11.3 | 8.97 | 11.3 | no budget declared | — |
| boot.stage:Accessibility permission | 3 | 0.6 | 10.1 | 3.77 | 10.1 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 3 | 6.9 | 9.8 | 7.43 | 9.8 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 3 | 7.6 | 8 | 7.6 | 8 | no budget declared | — |
| boot.stage:File watchers armed | 3 | 3.5 | 5.9 | 4.3 | 5.9 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 3 | 2.8 | 3.3 | 2.53 | 3.3 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 3 | 1.7 | 2.4 | 1.9 | 2.4 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 3 | 0.5 | 2.3 | 1 | 2.3 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 3 | 1.5 | 2.3 | 1.73 | 2.3 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 3 | 1.1 | 1.6 | 1.13 | 1.6 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 3 | 0.7 | 1.1 | 0.83 | 1.1 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 3 | 0.4 | 0.8 | 0.47 | 0.8 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 3 | 0.3 | 0.7 | 0.43 | 0.7 | no budget declared | — |
| boot.stage:UI: menu ready | 3 | 0.2 | 0.4 | 0.27 | 0.4 | no budget declared | — |

Worst occurrences:

- boot.total: 1415 ms at 2026-11-06 10:03:54:543, 1353 ms at 2026-11-06 10:04:30:692, 1313 ms at 2026-11-06 10:09:07:915
- boot.cpu: 1054 ms at 2026-11-06 10:03:54:543, 895 ms at 2026-11-06 10:09:07:915, 890 ms at 2026-11-06 10:04:30:692
- boot.stage:Hotstring groups registered (personal + dynamic + common): 339 ms at 2026-11-06 10:03:54:185, 239 ms at 2026-11-06 10:09:07:576, 232 ms at 2026-11-06 10:04:30:376
- boot.stage:Shortcuts pre-start: 237 ms at 2026-11-06 10:04:30:127, 166 ms at 2026-11-06 10:03:53:825, 161 ms at 2026-11-06 10:09:07:307
- boot.stage:Config-dependent module requires: 234 ms at 2026-11-06 10:04:29:855, 175 ms at 2026-11-06 10:09:07:110, 167 ms at 2026-11-06 10:03:53:613
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 176 ms at 2026-11-06 10:09:07:909, 169 ms at 2026-11-06 10:03:54:538, 152 ms at 2026-11-06 10:04:30:683
- boot.stage:UI: karabiner.init: 124 ms at 2026-11-06 10:03:54:369, 119 ms at 2026-11-06 10:09:07:733, 116 ms at 2026-11-06 10:04:30:532
- boot.stage:Keymap engine started: 51.5 ms at 2026-11-06 10:03:54:244, 31.4 ms at 2026-11-06 10:04:30:415, 28.4 ms at 2026-11-06 10:09:07:613
- boot.stage:Config schema migration: 31.7 ms at 2026-11-06 10:09:07:142, 31.1 ms at 2026-11-06 10:03:53:644, 31 ms at 2026-11-06 10:04:29:886
- boot.stage:TOML discovery + ordering: 14 ms at 2026-11-06 10:09:07:337, 12.3 ms at 2026-11-06 10:03:53:846, 8.4 ms at 2026-11-06 10:04:30:143
- boot.stage:Path: native asynchronous logger transport committed: 11.3 ms at 2026-11-06 10:03:53:443, 9.1 ms at 2026-11-06 10:04:29:615, 6.5 ms at 2026-11-06 10:09:06:927
- boot.stage:Accessibility permission: 10.1 ms at 2026-11-06 10:03:53:657, 0.6 ms at 2026-11-06 10:04:29:889, 0.6 ms at 2026-11-06 10:09:07:146

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 2 | 1542 | 1569 | 1556 | 1569 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 2 | 1540 | 1567 | 1554 | 1567 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 1569 ms at 2026-11-06 10:09:06:346, 1542 ms at 2026-11-06 10:04:29:150
- reload.total: 1567 ms at 2026-11-06 10:09:07:915, 1540 ms at 2026-11-06 10:04:30:692

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 5 | 97.3 | 126 | 101 | 126 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| menu.submenu:keyboard_layout | 5 | 10.6 | 57.4 | 19.84 | 57.4 | no budget declared | — |
| menu.submenu:shortcuts | 5 | 33 | 33.4 | 32.36 | 33.4 | no budget declared | — |
| menu.submenu:metrics | 2 | 4.1 | 18.3 | 11.2 | 18.3 | no budget declared | — |
| menu.app_exclusions | 5 | 1.1 | 15.3 | 3.92 | 15.3 | no budget declared | — |
| menu.submenu:llm | 5 | 8.2 | 9.2 | 8.1 | 9.2 | no budget declared | — |
| menu.submenu:gestures | 5 | 8.3 | 8.6 | 8.2 | 8.6 | no budget declared | — |
| menu.submenu:debug | 1 | 5.1 | 5.1 | 5.1 | 5.1 | no budget declared | — |
| menu.submenu:hotstrings | 2 | 3.9 | 3.9 | 3.9 | 3.9 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 126 ms at 2026-11-06 10:05:50:023, 104 ms at 2026-11-06 10:03:56:904, 97.3 ms at 2026-11-06 10:04:33:004
- menu.submenu:keyboard_layout: 57.4 ms at 2026-11-06 10:05:50:023, 10.9 ms at 2026-11-06 10:09:10:220, 10.6 ms at 2026-11-06 10:03:56:904
- menu.submenu:shortcuts: 33.4 ms at 2026-11-06 10:04:33:004, 33.3 ms at 2026-11-06 10:03:56:904, 33 ms at 2026-11-06 10:09:10:220
- menu.submenu:metrics: 18.3 ms at 2026-11-06 10:03:56:904, 4.1 ms at 2026-11-06 10:09:10:220
- menu.app_exclusions: 15.3 ms at 2026-11-06 10:03:56:845, 1.5 ms at 2026-11-06 10:05:49:966, 1.1 ms at 2026-11-06 10:09:05:950
- menu.submenu:llm: 9.2 ms at 2026-11-06 10:09:06:019, 8.4 ms at 2026-11-06 10:05:50:023, 8.2 ms at 2026-11-06 10:03:56:904
- menu.submenu:gestures: 8.6 ms at 2026-11-06 10:09:06:019, 8.3 ms at 2026-11-06 10:03:56:904, 8.3 ms at 2026-11-06 10:04:33:004
- menu.submenu:hotstrings: 3.9 ms at 2026-11-06 10:05:50:023, 3.9 ms at 2026-11-06 10:09:06:019

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 7 | 376 | 537 | 398 | 537 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (7) |

Worst occurrences:

- main_thread.hold: 537 ms at 2026-11-06 10:12:36:167 (...nts/Resources/static/ergopti_plus/macos/ui/menu/init.lua:1746), 501 ms at 2026-11-06 09:43:25:113 (...urces/static/ergopti_plus/macos/modules/keymap/utils.lua:1567), 469 ms at 2026-11-06 09:43:25:597 (...ources/static/ergopti_plus/macos/platform/remap/init.lua:3152)

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:tooltip.show_predictions | 2 | 10.99 | 12.02 | 11.5 | 12.02 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| hotpath:preview.rebuild | 7 | 5.93 | 9.29 | 6.98 | 9.29 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (7) |

Worst occurrences:

- hotpath:tooltip.show_predictions: 12.02 ms at 2026-11-06 09:49:15:077, 10.99 ms at 2026-11-06 10:05:51:226
- hotpath:preview.rebuild: 9.29 ms at 2026-11-06 09:51:29:215, 9.02 ms at 2026-11-06 09:44:22:562, 7.75 ms at 2026-11-06 10:05:48:492

### LLM requests

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| llm.ttft | 2 | 1839 | 1869 | 1854 | 1869 | 2000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| llm.stream | 2 | 1837 | 1867 | 1852 | 1867 | no budget declared | — |
| llm.parsed:remote | 2 | 1836 | 1861 | 1848 | 1861 | no budget declared | — |

Worst occurrences:

- llm.ttft: 1869 ms at 2026-11-06 09:49:15:065, 1839 ms at 2026-11-06 10:05:51:215
- llm.stream: 1867 ms at 2026-11-06 09:49:15:097, 1837 ms at 2026-11-06 10:05:51:245
- llm.parsed:remote: 1861 ms at 2026-11-06 09:49:15:064, 1836 ms at 2026-11-06 10:05:51:214

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| healthcheck.sync | 1 | 10.2 | 10.2 | 10.2 | 10.2 | 5 ms (stated in the log line) | ❌ over (1) |

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.ErgoptiPlus | 25 | — | — | 125 | 1065 | no budget declared | — |
| phase:process.defaults | 428 | — | — | 17.98 | 472 | no budget declared | — |
| phase:hotpath.tooltip.show_predictions | 3 | — | — | 8.64 | 12.02 | no budget declared | — |
| phase:hotpath.keydown | 957 | — | — | 2.07 | 9.95 | no budget declared | — |
| phase:hotpath.preview.rebuild | 857 | — | — | 1.77 | 9.29 | no budget declared | — |
| phase:preview.total | 923 | — | — | 1.74 | 9.28 | no budget declared | — |
| phase:toml.parse | 3 | — | — | 4.48 | 6.88 | no budget declared | — |
| phase:hotpath.hotstring.match | 872 | — | — | 0.28 | 6.26 | no budget declared | — |
| phase:preview.providers | 923 | — | — | 0.38 | 5.12 | no budget declared | — |
| phase:hotpath.hotstring.expand | 15 | — | — | 0.43 | 3.66 | no budget declared | — |
| phase:preview.resolve | 923 | — | — | 0.27 | 2.95 | no budget declared | — |

### Counters

- counter:runtime.timer_hold_over_250ms: 3

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 3 | 2026-11-06 10:03:53:430 | 2026-11-06 10:09:06:919 |
| stop | 2 | 2026-11-06 10:04:29:156 | 2026-11-06 10:09:06:352 |
| reload | 2 | 2026-11-06 10:04:29:150 | 2026-11-06 10:09:06:346 |
| sleep_wake | 1 | 2026-11-06 09:43:24:597 | 2026-11-06 09:43:24:597 |
| karabiner_lease_failure | 8 | 2026-11-06 09:43:25:661 | 2026-11-06 09:44:28:890 |
| network_failure | 1 | 2026-11-06 10:04:31:058 | 2026-11-06 10:04:31:058 |
| update_check | 6 | 2026-11-06 10:03:54:455 | 2026-11-06 10:09:07:809 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-06 10:03:53:430 — ErgoptiPlus session opened =====
===== 2026-11-06 10:04:29:605 — ErgoptiPlus session opened =====
===== 2026-11-06 10:09:06:919 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-06 10:04:29:156 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-06 10:09:06:352 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-06 10:04:29:150 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
2026-11-06 10:09:06:346 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-06 09:43:24:597 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**karabiner_lease_failure**

```
2026-11-06 09:43:25:661 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
2026-11-06 09:43:26:752 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 1 failed: owned-runtime-not-admitted.
2026-11-06 09:43:26:752 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 2/3 in 10.0 s (owned-runtime-not-admitted).
2026-11-06 09:43:36:852 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 2 failed: owned-runtime-not-admitted.
2026-11-06 09:43:36:853 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 3/3 in 30.0 s (owned-runtime-not-admitted).
2026-11-06 09:43:51:808 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 3/3 in 30.0 s (layout-settled).
2026-11-06 09:44:28:890 [WARNING] [karabiner] Karabiner lease auto-recovery attempt 3 failed: owned-runtime-not-admitted.
2026-11-06 09:44:28:890 [ERROR] [karabiner] Karabiner lease auto-recovery exhausted after 3 attempt(s); rules remain fail-closed (owned-runtime-not-admitted).
```

**network_failure**

```
2026-11-06 10:04:31:058 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

**update_check**

```
2026-11-06 10:03:54:455 [START] [updater.auto_check] Starting automatic update checks…
2026-11-06 10:03:54:455 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
2026-11-06 10:04:30:593 [START] [updater.auto_check] Starting automatic update checks…
2026-11-06 10:04:30:593 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
2026-11-06 10:09:07:809 [START] [updater.auto_check] Starting automatic update checks…
2026-11-06 10:09:07:809 [SUCCESS] [updater.auto_check] Automatic update checks started (every 86400s).
```

</details>
