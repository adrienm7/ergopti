# Field log analysis

Logs: ErgoptiPlus_2026-11-02.log (7031 lines, 6776 records, 243 continuation lines); span 2026-11-02 00:11:36:458 to 2026-11-02 10:32:54:810.
Previous report compared: mac-2026-11-02_080500.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 66 | slow | main_thread.hold over its 250 ms budget | 22 | max 1735 ms at 2026-11-02 10:29:27:791 |
| 2 | 30 | slow | menu.rebuild over its 250 ms budget | 10 | max 1530 ms at 2026-11-02 10:32:51:418 |
| 3 | 24 | warning | [keystats.log_manager] day_rollover: ingest stalled at offset <*> — preserving today.log. | 24 | 2026-11-02 00:11:36:461 [WARNING] [keystats.log_manager] day_rollover: ingest stalled at offset 4907 — preserving today.log. |
| 4 | 24 | warning | [keystats.log_manager] day_rollover: today.log not fully drained — file preserved, rotation skipped. | 24 | 2026-11-02 00:11:36:461 [WARNING] [keystats.log_manager] day_rollover: today.log not fully drained — file preserved, rotation skipped. |
| 5 | 24 | warning | [keystats.watchers] Midnight rotation stalled — will retry on next maintenance tick. | 24 | 2026-11-02 00:11:36:461 [WARNING] [keystats.watchers] Midnight rotation stalled — will retry on next maintenance tick. |
| 6 | 21 | slow | hotpath:preview.rebuild over its 5 ms budget | 7 | max 12.21 ms at 2026-11-02 10:18:13:715 |
| 7 | 20 | error | [menu_llm.ollama] The Ollama pull of granite4:<*>m-h failed (code <*>): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest. | 4 | 2026-11-02 08:09:29:740 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed (code 1): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest. |
| 8 | 15 | slow | healthcheck.sync over its 5 ms budget | 5 | max 248 ms at 2026-11-02 10:21:23:737 |
| 9 | 9 | slow | hotpath:hotstring.expand over its 5 ms budget | 3 | max 11.57 ms at 2026-11-02 10:18:42:462 |
| 10 | 9 | slow | preferences.save over its 250 ms budget | 3 | max 2048 ms at 2026-11-02 10:02:11:959 |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-11-02 10:25:17:098, last of 2 runs, 0 failed)
- ✅ owned_runtime: pass (2026-11-02 10:25:17:242, last of 2 runs, 0 failed)
- ✅ owned_start: pass (2026-11-02 10:25:17:248, last of 2 runs, 0 failed)
- ✅ network: pass (2026-11-02 10:25:19:992, last of 2 runs, 0 failed)
- ✅ toolchain: pass (2026-11-02 10:25:21:211, last of 2 runs, 0 failed)
- ✅ login_items: pass (2026-11-02 10:25:41:364, last of 2 runs, 0 failed)
- ✅ composer: pass (2026-11-02 10:25:42:746, last of 2 runs, 0 failed)
- ✅ boot_cost: pass (2026-11-02 10:25:42:756, last of 2 runs, 0 failed)
- ❌ idle_cost: fail (2026-11-02 10:26:13:160, last of 2 runs, 1 failed)
- ❌ layout_rows: fail (2026-11-02 10:26:16:383, last of 2 runs, 1 failed)
- ✅ permissions: pass (2026-11-02 10:26:16:622, last of 2 runs, 0 failed)
- ✅ event_taps: pass (2026-11-02 10:26:17:137, last of 2 runs, 1 failed)
- ✅ input_sources: pass (2026-11-02 10:26:17:262, last of 2 runs, 0 failed)
- ✅ storage: pass (2026-11-02 10:26:23:489, last of 2 runs, 0 failed)
- ✅ launcher_roles: pass (2026-11-02 10:26:23:597, last of 2 runs, 0 failed)
- ✅ network_hosts: pass (2026-11-02 10:26:25:526, last of 2 runs, 0 failed)
- ✅ ollama_blob_host: pass (2026-11-02 10:26:26:524, last of 2 runs, 0 failed)
- ❌ typing_selftest: fail (2026-11-02 10:26:32:539, last of 2 runs, 1 failed)
- ✅ capslock_chord: pass (2026-11-02 10:26:32:551, last of 2 runs, 0 failed)
- ✅ gesture_frames: pass (2026-11-02 10:26:32:563, last of 2 runs, 0 failed)
- ✅ hotstring_roundtrip: pass (2026-11-02 10:26:34:689, last of 2 runs, 0 failed)
- ❌ prediction_tooltip: fail (2026-11-02 10:26:34:697, last of 2 runs, 1 failed)
- ✅ menu_build: pass (2026-11-02 10:26:36:187, last of 2 runs, 0 failed)
- ✅ pac_fallback: pass (2026-11-02 10:29:11:417, last of 2 runs, 0 failed)
- ✅ ai_local: pass (2026-11-02 10:29:17:120, last of 2 runs, 0 failed)
- ✅ slow_lines: pass (2026-11-02 10:29:17:218, last of 2 runs, 0 failed)
- ✅ fifo_safety: pass (2026-11-02 10:29:18:343, last of 2 runs, 0 failed)
- ✅ local_servers: pass (2026-11-02 10:29:18:563, last of 2 runs, 0 failed)
- ✅ app_health: pass (2026-11-02 10:29:20:859, last of 2 runs, 0 failed)
- ✅ tap_hold_thresholds: pass (2026-11-02 10:29:21:028, last of 2 runs, 0 failed)
- ✅ apple_shortcuts: pass (2026-11-02 10:29:21:113, last of 2 runs, 0 failed)
- ✅ owned_pause: pass (2026-11-02 10:29:21:120, last of 2 runs, 0 failed)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 29 pass, ❌ 4 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

6 error group(s), 42 warning group(s); 160 occurrence(s); 32 new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h failed (code <*>): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest. | 4 | 2026-11-02 08:09:29:740 | 2026-11-02 10:29:01:809 |  |
| ERROR | llm.api_mlx | MLX discovery for '<*>' gave up after <*>s — surfacing as load failure. | 1 | 2026-11-02 10:08:21:995 | 2026-11-02 10:08:21:995 | new |
| ERROR | llm.api_mlx | MLX model '<*>' marked as failed to load — status dot will show red. | 1 | 2026-11-02 10:08:21:995 | 2026-11-02 10:08:21:995 | new |
| ERROR | config_migrate | Config migration of '<*>' refused (newer): canonical schema version is newer than this build. The file is left untouched and this session will not write it. | 1 | 2026-11-02 10:21:22:849 | 2026-11-02 10:21:22:849 | new |
| ERROR | karabiner.lease | '<*>' called before M.init() — lease controller unavailable. | 1 | 2026-11-02 10:21:23:501 | 2026-11-02 10:21:23:501 | new |
| ERROR | keymap.layout_rows_build | The number-row layout for '<*>' was not applied (select_refused): a fresh process does not see the build selected (org.unknown.keylayout.ErgoptiFieldRows1<*>). | 1 | 2026-11-02 10:26:15:425 | 2026-11-02 10:26:15:425 | new |
| WARNING | keystats.log_manager | day_rollover: ingest stalled at offset <*> — preserving today.log. | 24 | 2026-11-02 00:11:36:461 | 2026-11-02 00:44:21:076 |  |
| WARNING | keystats.log_manager | day_rollover: today.log not fully drained — file preserved, rotation skipped. | 24 | 2026-11-02 00:11:36:461 | 2026-11-02 00:44:21:076 |  |
| WARNING | keystats.watchers | Midnight rotation stalled — will retry on next maintenance tick. | 24 | 2026-11-02 00:11:36:461 | 2026-11-02 00:44:21:076 |  |
| WARNING | menu | Over budget: menu.rebuild took <*> ms (budget <*> ms). | 15 | 2026-11-02 08:05:31:820 | 2026-11-02 10:32:53:276 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 7 | 2026-11-02 08:06:44:245 | 2026-11-02 10:29:06:872 |  |
| WARNING | key_event_health | A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across… | 6 | 2026-11-02 10:01:09:890 | 2026-11-02 10:26:38:797 | new |
| WARNING | preferences | Slow preferences save <*> ms (prepare=<*> write=<*> ms; operations=<*>; prepare: snapshot=<*> decode=<*> models=<*> sparse=<*> wrap=<*> rows=<*> gestures=<*> llm=<*> shortcuts=<*> hotstrings=<*> ms; proposed=<*>; metadata_commands=<*> in <*> ms; lua_heap=<*>-><*> MB). | 3 | 2026-11-02 10:02:11:959 | 2026-11-02 10:08:51:539 | new |
| WARNING | llm.api_remote | Remote API ping failed (status=<*>) for provider=omlx. | 3 | 2026-11-02 10:08:52:945 | 2026-11-02 10:10:22:209 | new |
| WARNING | runtime | An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 2 | 2026-11-02 08:04:47:494 | 2026-11-02 09:57:25:569 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 2 | 2026-11-02 08:05:32:126 | 2026-11-02 10:25:17:276 |  |
| WARNING | menu_llm.ollama | The Ollama pull of granite4:<*>m-h failed its digest check; Ollama removed the layer, so it is pulled once more. | 2 | 2026-11-02 08:09:29:740 | 2026-11-02 10:27:58:365 |  |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: cancelled. | 2 | 2026-11-02 08:12:06:289 | 2026-11-02 10:29:21:694 |  |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 2 | 2026-11-02 08:12:11:893 | 2026-11-02 10:25:16:827 |  |
| WARNING | keystats | Keystats event tap found disabled — restarting. | 2 | 2026-11-02 10:08:51:565 | 2026-11-02 10:08:52:944 | new |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 2 | 2026-11-02 10:11:24:238 | 2026-11-02 10:29:30:069 | new |
| WARNING | HotPath | Slow hotstring.expand: <*> ms own, <*> ms total, parent hotstring.match (<*> similar since the last line). | 2 | 2026-11-02 10:18:27:714 | 2026-11-02 10:18:42:462 | new |
| WARNING | HotPath | Slow hotstring.match: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 2 | 2026-11-02 10:18:27:714 | 2026-11-02 10:26:34:222 | new |
| WARNING | tooltip_llm | Over budget: prediction.display took <*> ms (budget <*> ms). | 2 | 2026-11-02 10:18:36:025 | 2026-11-02 10:18:45:900 | new |
| WARNING | HotPath | Slow tooltip.show_predictions: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 2 | 2026-11-02 10:18:36:038 | 2026-11-02 10:26:36:201 | new |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 08:05:31:827 | 2026-11-02 08:05:31:827 |  |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 08:06:46:996 | 2026-11-02 08:06:46:996 |  |
| WARNING | keymap.utils | Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 1 | 2026-11-02 08:12:08:221 | 2026-11-02 08:12:08:221 |  |
| WARNING | keymap | Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 1 | 2026-11-02 08:12:08:221 | 2026-11-02 08:12:08:221 |  |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 1 | 2026-11-02 08:15:36:713 | 2026-11-02 08:15:36:713 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 1 | 2026-11-02 10:00:21:603 | 2026-11-02 10:00:21:603 | new |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 1 | 2026-11-02 10:02:13:543 | 2026-11-02 10:02:13:543 | new |
| WARNING | llm.api_mlx | Endpoint discovery: expected model '<*>' not visible in /v1/models cache list — POST may <*> if mlx_lm cannot resolve it. | 1 | 2026-11-02 10:02:22:123 | 2026-11-02 10:02:22:123 | new |
| WARNING | llm.api_mlx | MLX endpoint discovery: all candidates returned <*> — model may still be loading. Will retry on next warmup. | 1 | 2026-11-02 10:02:22:126 | 2026-11-02 10:02:22:126 | new |
| WARNING | llm.api_mlx | Endpoint discovery: gave up waiting for MLX server after <*>s. Falling back to default routes; warmup will keep retrying. | 1 | 2026-11-02 10:05:46:692 | 2026-11-02 10:05:46:692 | new |
| WARNING | llm.core | warmup_model: backend warmup did not commit: false | 1 | 2026-11-02 10:08:22:003 | 2026-11-02 10:08:22:003 | new |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 1 | 2026-11-02 10:08:52:925 | 2026-11-02 10:08:52:925 | new |
| WARNING | llm.local_servers | Local server '<*>' request failed: not_running (HTTP <*>). | 1 | 2026-11-02 10:08:52:945 | 2026-11-02 10:08:52:945 | new |
| WARNING | llm.prediction_engine | Fallback chain triggered — F1<*> signal was missed. | 1 | 2026-11-02 10:18:47:836 | 2026-11-02 10:18:47:836 | new |
| WARNING | llm.streaming_handler | LLM request failed — loading indicator dismissed. | 1 | 2026-11-02 10:18:48:891 | 2026-11-02 10:18:48:891 | new |
| WARNING | shortcuts.actions.screen_capture | Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime. | 1 | 2026-11-02 10:21:10:503 | 2026-11-02 10:21:10:503 | new |
| WARNING | BootProfile | Over budget: boot took <*> ms (budget <*> ms). | 1 | 2026-11-02 10:25:13:208 | 2026-11-02 10:25:13:208 | new |
| WARNING | runtime | An hs.timer.new callback (...i/static/ergopti_plus/macos/infra/accessibility_wait.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=<*> ms, boot.stage=<*> ms, boot.stage_cpu=<*> ms, boot.stage_cpu=… | 1 | 2026-11-02 10:25:13:469 | 2026-11-02 10:25:13:469 | new |
| WARNING | menu.keyboard_layout | Failed to switch active layout to '<*>' / '<*>' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS). | 1 | 2026-11-02 10:26:15:129 | 2026-11-02 10:26:15:129 | new |
| WARNING | runtime | An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 10:26:36:192 | 2026-11-02 10:26:36:192 | new |
| WARNING | HotPath | Slow hotstring.expand: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 1 | 2026-11-02 10:26:37:822 | 2026-11-02 10:26:37:822 | new |
| WARNING | runtime | An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layout=<… | 1 | 2026-11-02 10:29:27:791 | 2026-11-02 10:29:27:791 | new |
| WARNING | runtime | An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=<*> ms, menu_item.shortcuts=<*> ms, menu_item.keyboard_layo… | 1 | 2026-11-02 10:32:51:419 | 2026-11-02 10:32:51:419 | new |

<details><summary>One example line per group</summary>

```
2026-11-02 08:09:29:740 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed (code 1): OLLAMA_PULL_ERROR digest_mismatch after verifying_digest.
```
```
2026-11-02 10:08:21:995 [ERROR] [llm.api_mlx] MLX discovery for 'Qwen3.5-2B-4bit' gave up after 340s — surfacing as load failure.
```
```
2026-11-02 10:08:21:995 [ERROR] [llm.api_mlx] MLX model 'Qwen3.5-2B-4bit' marked as failed to load — status dot will show red.
```
```
2026-11-02 10:21:22:849 [ERROR] [config_migrate] Config migration of '~/perso/config/ergopti_plus/hammerspoon/config.toml' refused (newer): canonical schema version is newer than this build. The file is left untouched and this session will not write it.
```
```
2026-11-02 10:21:23:501 [ERROR] [karabiner.lease] 'status' called before M.init() — lease controller unavailable.
```
```
2026-11-02 10:26:15:425 [ERROR] [keymap.layout_rows_build] The number-row layout for 'ergol' was not applied (select_refused): a fresh process does not see the build selected (org.unknown.keylayout.ErgoptiFieldRows10).
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
2026-11-02 08:06:44:245 [WARNING] [HotPath] Slow preview.rebuild: 6.29 ms own, 6.29 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-02 10:01:09:890 [WARNING] [key_event_health] A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: 0 key-down(s), 1 key-up(s), 1 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 charact…
```
```
2026-11-02 10:02:11:959 [WARNING] [preferences] Slow preferences save 2048 ms (prepare=1272 write=776 ms; operations=292; prepare: snapshot=6 decode=0 models=0 sparse=260 wrap=10 rows=0 gestures=1 llm=1 shortcuts=1 hotstrings=989 ms; proposed=294; metadata_commands=2 in 157 ms; lua_heap=34->47 MB).
```
```
2026-11-02 10:08:52:945 [WARNING] [llm.api_remote] Remote API ping failed (status=0) for provider=omlx.
```
```
2026-11-02 08:04:47:494 [WARNING] [runtime] An hs.timer.new callback (.../static/ergopti_plus/macos/modules/keystats/watchers.lua:364) held the main thread for 1382 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 48->48 MB.
```
```
2026-11-02 08:05:32:126 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-11-02 08:09:29:740 [WARNING] [menu_llm.ollama] The Ollama pull of granite4:350m-h failed its digest check; Ollama removed the layer, so it is pulled once more.
```
```
2026-11-02 08:12:06:289 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: cancelled.
```
```
2026-11-02 08:12:11:893 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1410 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1197.7 ms, menu_i…
```
```
2026-11-02 10:08:51:565 [WARNING] [keystats] Keystats event tap found disabled — restarting.
```
```
2026-11-02 10:11:24:238 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1368 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1329.3 ms, me…
```
```
2026-11-02 10:18:27:714 [WARNING] [HotPath] Slow hotstring.expand: 9.40 ms own, 9.40 ms total, parent hotstring.match (0 similar since the last line).
```
```
2026-11-02 10:18:27:714 [WARNING] [HotPath] Slow hotstring.match: 5.02 ms own, 14.42 ms total, parent keydown (0 similar since the last line).
```
```
2026-11-02 10:18:36:025 [WARNING] [tooltip_llm] Over budget: prediction.display took 7021 ms (budget 2000 ms).
```
```
2026-11-02 10:18:36:038 [WARNING] [HotPath] Slow tooltip.show_predictions: 14.51 ms own, 14.51 ms total, parent none (0 similar since the last line).
```
```
2026-11-02 08:05:31:827 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1540 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1247.4 ms, menu_i…
```
```
2026-11-02 08:06:46:996 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1357 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1313.7 ms, menu_it…
```
```
2026-11-02 08:12:08:221 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed.
```
```
2026-11-02 08:12:08:221 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false.
```
```
2026-11-02 08:15:36:713 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1488 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1453.2 ms, me…
```
```
2026-11-02 10:00:21:603 [WARNING] [keymap.utils] Slow ignored-window probe 528 ms (watchers=0 focused_window=528 ms).
```
```
2026-11-02 10:02:13:543 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1488 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1450.4 ms, me…
```
```
2026-11-02 10:02:22:123 [WARNING] [llm.api_mlx] Endpoint discovery: expected model 'Qwen3.5-2B-4bit' not visible in /v1/models cache list — POST may 404 if mlx_lm cannot resolve it.
```
```
2026-11-02 10:02:22:126 [WARNING] [llm.api_mlx] MLX endpoint discovery: all candidates returned 404 — model may still be loading. Will retry on next warmup.
```
```
2026-11-02 10:05:46:692 [WARNING] [llm.api_mlx] Endpoint discovery: gave up waiting for MLX server after 184.7s. Falling back to default routes; warmup will keep retrying.
```
```
2026-11-02 10:08:22:003 [WARNING] [llm.core] warmup_model: backend warmup did not commit: false
```
```
2026-11-02 10:08:52:925 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1334 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1296.9 ms, me…
```
```
2026-11-02 10:08:52:945 [WARNING] [llm.local_servers] Local server 'omlx' request failed: not_running (HTTP 0).
```
```
2026-11-02 10:18:47:836 [WARNING] [llm.prediction_engine] Fallback chain triggered — F16 signal was missed.
```
```
2026-11-02 10:18:48:891 [WARNING] [llm.streaming_handler] LLM request failed — loading indicator dismissed.
```
```
2026-11-02 10:21:10:503 [WARNING] [shortcuts.actions.screen_capture] Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime.
```
```
2026-11-02 10:25:13:208 [WARNING] [BootProfile] Over budget: boot took 58020 ms (budget 2500 ms).
```
```
2026-11-02 10:25:13:469 [WARNING] [runtime] An hs.timer.new callback (...i/static/ergopti_plus/macos/infra/accessibility_wait.lua:139) held the main thread for 1279 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=270.3 ms, boot.stage…
```
```
2026-11-02 10:26:15:129 [WARNING] [menu.keyboard_layout] Failed to switch active layout to 'Ergopti Field Rows' / 'Ergopti Field Rows' (tis_id=Ergopti Field Rows, reason=invalid_output, result=MISS).
```
```
2026-11-02 10:26:36:192 [WARNING] [runtime] An hs.timer.new callback (...so/ergopti/static/ergopti_plus/macos/infra/field_run.lua:610) held the main thread for 1489 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1443.1 ms, menu_it…
```
```
2026-11-02 10:26:37:822 [WARNING] [HotPath] Slow hotstring.expand: 10.89 ms own, 10.89 ms total, parent none (0 similar since the last line).
```
```
2026-11-02 10:29:27:791 [WARNING] [runtime] An hs.timer.new callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801) held the main thread for 1735 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1466.6 ms, menu_i…
```
```
2026-11-02 10:32:51:419 [WARNING] [runtime] An hs.timer.doAfter callback (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746) held the main thread for 1573 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: menu.rebuild=1530.3 ms, me…
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 5 | 1977 | 58020 | 13079 | 58020 | 2500 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |
| boot.stage:Accessibility permission | 5 | 1.9 | 56014 | 11205 | 56014 | no budget declared | — |
| boot.cpu | 5 | 1250 | 2344 | 1470 | 2344 | no budget declared | — |
| boot.stage:Config-dependent module requires | 6 | 394 | 614 | 462 | 614 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 5 | 223 | 290 | 233 | 290 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 5 | 193 | 270 | 214 | 270 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 5 | 198 | 226 | 182 | 226 | no budget declared | — |
| boot.stage:UI: karabiner.init | 5 | 79.1 | 136 | 96.34 | 136 | no budget declared | — |
| boot.stage:Config schema migration | 6 | 33.7 | 72.8 | 42.23 | 72.8 | no budget declared | — |
| boot.stage:Keymap engine started | 5 | 59.7 | 72.1 | 51.18 | 72.1 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 5 | 35.1 | 43.3 | 37.16 | 43.3 | no budget declared | — |
| boot.stage:File watchers armed | 5 | 9.3 | 20.3 | 12.2 | 20.3 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 5 | 11.4 | 19.6 | 12.82 | 19.6 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 6 | 10.3 | 18.1 | 11.63 | 18.1 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 5 | 5.3 | 14.9 | 7.4 | 14.9 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 6 | 6.1 | 9.7 | 6.95 | 9.7 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 6 | 2.7 | 5.2 | 3.22 | 5.2 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 5 | 1 | 4.5 | 1.58 | 4.5 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 6 | 2 | 3.8 | 2.35 | 3.8 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 5 | 2.8 | 3.4 | 2.84 | 3.4 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 6 | 2.2 | 3 | 2.37 | 3 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 5 | 0.8 | 1.3 | 0.88 | 1.3 | no budget declared | — |
| boot.stage:UI: menu ready | 5 | 0.4 | 0.7 | 0.46 | 0.7 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 6 | 0.2 | 0.3 | 0.25 | 0.3 | no budget declared | — |

Worst occurrences:

- boot.total: 58020 ms at 2026-11-02 10:25:13:207, 2149 ms at 2026-11-02 10:29:24:075, 1977 ms at 2026-11-02 08:12:08:503
- boot.stage:Accessibility permission: 56014 ms at 2026-11-02 10:25:12:190, 7.9 ms at 2026-11-02 08:05:27:514, 1.9 ms at 2026-11-02 08:12:07:708
- boot.cpu: 2344 ms at 2026-11-02 10:25:13:207, 1315 ms at 2026-11-02 10:29:24:075, 1250 ms at 2026-11-02 08:12:08:503
- boot.stage:Config-dependent module requires: 614 ms at 2026-11-02 08:12:07:648, 542 ms at 2026-11-02 10:21:22:781, 457 ms at 2026-11-02 10:29:22:955
- boot.stage:Hotstring groups registered (personal + dynamic + common): 290 ms at 2026-11-02 10:29:23:575, 250 ms at 2026-11-02 10:25:12:726, 223 ms at 2026-11-02 08:12:08:187
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 270 ms at 2026-11-02 10:25:13:185, 236 ms at 2026-11-02 10:29:24:049, 193 ms at 2026-11-02 08:12:08:491
- boot.stage:Shortcuts pre-start: 226 ms at 2026-11-02 10:29:23:224, 221 ms at 2026-11-02 10:25:12:412, 198 ms at 2026-11-02 08:12:07:906
- boot.stage:UI: karabiner.init: 136 ms at 2026-11-02 10:29:23:811, 118 ms at 2026-11-02 10:25:12:915, 79.1 ms at 2026-11-02 08:05:03:877
- boot.stage:Config schema migration: 72.8 ms at 2026-11-02 10:21:22:855, 46.4 ms at 2026-11-02 08:12:07:696, 37.2 ms at 2026-11-02 08:05:03:389
- boot.stage:Keymap engine started: 72.1 ms at 2026-11-02 10:29:23:669, 62.9 ms at 2026-11-02 10:25:12:796, 59.7 ms at 2026-11-02 08:05:27:983
- boot.stage:TOML discovery + ordering: 43.3 ms at 2026-11-02 08:12:07:964, 40.9 ms at 2026-11-02 10:25:12:475, 35.1 ms at 2026-11-02 08:05:27:714
- boot.stage:File watchers armed: 20.3 ms at 2026-11-02 10:29:24:070, 13.9 ms at 2026-11-02 10:25:13:202, 9.3 ms at 2026-11-02 08:05:04:074

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.request_to_boot | 3 | 2779 | 2936 | 2684 | 2936 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |
| reload.total | 3 | 2288 | 2462 | 2203 | 2462 | 4000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ✅ within |

Worst occurrences:

- reload.request_to_boot: 2936 ms at 2026-11-02 10:29:21:139, 2779 ms at 2026-11-02 08:12:05:724, 2337 ms at 2026-11-02 08:05:01:740
- reload.total: 2462 ms at 2026-11-02 10:29:24:076, 2288 ms at 2026-11-02 08:12:08:504, 1860 ms at 2026-11-02 08:05:04:077

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| menu.rebuild | 10 | 1329 | 1530 | 1367 | 1530 | 250 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (10) |
| phase:menu.rebuild | 9 | — | — | 1314 | 1453 | no budget declared | — |
| menu.submenu:shortcuts | 10 | 1102 | 1205 | 1102 | 1205 | no budget declared | — |
| phase:menu_item.shortcuts | 9 | — | — | 1075 | 1174 | no budget declared | — |
| menu.submenu:keyboard_layout | 10 | 70.9 | 210 | 91.95 | 210 | no budget declared | — |
| phase:menu_item.keyboard_layout | 9 | — | — | 87.24 | 196 | no budget declared | — |
| phase:menu_keyboard_layout.rows | 9 | — | — | 62.74 | 109 | no budget declared | — |
| phase:menu_keyboard_layout.sources | 9 | — | — | 22.77 | 85.22 | no budget declared | — |
| menu.submenu:gestures | 10 | 51.5 | 69.2 | 54.65 | 69.2 | no budget declared | — |
| menu.submenu:about | 1 | 65.9 | 65.9 | 65.9 | 65.9 | no budget declared | — |
| phase:menu_item.gestures | 9 | — | — | 51.17 | 60.06 | no budget declared | — |
| phase:menu_keyboard_layout.number_row | 9 | — | — | 13.88 | 57.65 | no budget declared | — |
| menu.submenu:llm | 10 | 31.6 | 52.6 | 35.11 | 52.6 | no budget declared | — |
| phase:menu_item.llm | 9 | — | — | 33.04 | 52.57 | no budget declared | — |
| phase:menu_keyboard_layout.magic_key | 9 | — | — | 32.16 | 37.81 | no budget declared | — |
| menu.submenu:hotstrings | 8 | 28.6 | 35.1 | 29.3 | 35.1 | no budget declared | — |
| phase:menu_item.hotstrings | 9 | — | — | 27.12 | 29.27 | no budget declared | — |
| menu.submenu:metrics | 1 | 29.2 | 29.2 | 29.2 | 29.2 | no budget declared | — |
| phase:menu_item.metrics | 9 | — | — | 10.84 | 29.18 | no budget declared | — |
| phase:menu_item.about | 9 | — | — | 8.63 | 18.71 | no budget declared | — |
| menu.app_exclusions | 10 | 0.9 | 15.5 | 2.45 | 15.5 | no budget declared | — |
| phase:menu_item.debug | 9 | — | — | 5.23 | 9.62 | no budget declared | — |
| phase:menu_item.configuration | 9 | — | — | 2.98 | 8.81 | no budget declared | — |
| phase:menu_keyboard_layout.bundles | 9 | — | — | 1.16 | 4.21 | no budget declared | — |
| phase:menu_item.tap_holds | 9 | — | — | 1 | 1.45 | no budget declared | — |
| phase:menu_item.language | 9 | — | — | 0.11 | 0.68 | no budget declared | — |
| phase:menu_keyboard_layout.variants | 9 | — | — | 0.2 | 0.24 | no budget declared | — |
| phase:menu_item.apps | 9 | — | — | 0.17 | 0.21 | no budget declared | — |
| phase:menu_item.reload | 9 | — | — | 0.01 | 0.01 | no budget declared | — |
| phase:menu_item.quit | 9 | — | — | 0 | 0.01 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 1530 ms at 2026-11-02 10:32:51:418, 1467 ms at 2026-11-02 10:29:27:783, 1450 ms at 2026-11-02 10:02:13:542
- menu.submenu:shortcuts: 1205 ms at 2026-11-02 10:26:36:187, 1174 ms at 2026-11-02 10:02:13:542, 1157 ms at 2026-11-02 10:29:27:783
- menu.submenu:keyboard_layout: 210 ms at 2026-11-02 10:32:51:418, 117 ms at 2026-11-02 08:06:46:991, 108 ms at 2026-11-02 10:02:13:542
- menu.submenu:gestures: 69.2 ms at 2026-11-02 10:32:51:418, 60.1 ms at 2026-11-02 10:02:13:542, 58.1 ms at 2026-11-02 10:25:16:819
- menu.submenu:llm: 52.6 ms at 2026-11-02 10:08:52:924, 47 ms at 2026-11-02 10:26:36:187, 36.5 ms at 2026-11-02 10:32:51:418
- menu.submenu:hotstrings: 35.1 ms at 2026-11-02 10:32:51:418, 31 ms at 2026-11-02 10:26:36:187, 29.8 ms at 2026-11-02 10:25:16:819
- menu.app_exclusions: 15.5 ms at 2026-11-02 08:05:31:721, 1.9 ms at 2026-11-02 10:11:24:157, 1.8 ms at 2026-11-02 10:26:36:085

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 22 | 1357 | 1676 | 1114 | 1735 | 250 ms (static/ergopti_plus/macos/infra/main_thread_hold.lua) | ❌ over (22) |

Worst occurrences:

- main_thread.hold: 1735 ms at 2026-11-02 10:29:27:791 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801), 1676 ms at 2026-11-02 10:25:16:827 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1801), 1573 ms at 2026-11-02 10:32:51:419 (...perso/ergopti/static/ergopti_plus/macos/ui/menu/init.lua:1746)

### Hotstrings

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:hotstring.expand | 3 | 10.89 | 11.57 | 10.62 | 11.57 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (3) |
| hotpath:hotstring.match | 2 | 5.02 | 5.07 | 5.04 | 5.07 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |

Worst occurrences:

- hotpath:hotstring.expand: 11.57 ms at 2026-11-02 10:18:42:462, 10.89 ms at 2026-11-02 10:26:37:822, 9.4 ms at 2026-11-02 10:18:27:714
- hotpath:hotstring.match: 5.07 ms at 2026-11-02 10:26:34:222, 5.02 ms at 2026-11-02 10:18:27:714

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:tooltip.show_predictions | 2 | 6.01 | 14.51 | 10.26 | 14.51 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (2) |
| hotpath:preview.rebuild | 7 | 6.48 | 12.21 | 7.66 | 12.21 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (7) |

Worst occurrences:

- hotpath:tooltip.show_predictions: 14.51 ms at 2026-11-02 10:18:36:038, 6.01 ms at 2026-11-02 10:26:36:201
- hotpath:preview.rebuild: 12.21 ms at 2026-11-02 10:18:13:715, 10.99 ms at 2026-11-02 10:25:58:168, 6.51 ms at 2026-11-02 10:26:54:627

### LLM requests

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| llm.ttft | 2 | 1701 | 7021 | 4361 | 7021 | 2000 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (1) |
| llm.stream | 3 | 2353 | 7018 | 3690 | 7018 | no budget declared | — |
| llm.parsed:remote | 2 | 1699 | 7007 | 4353 | 7007 | no budget declared | — |

Worst occurrences:

- llm.ttft: 7021 ms at 2026-11-02 10:18:36:023, 1701 ms at 2026-11-02 10:26:36:195
- llm.stream: 7018 ms at 2026-11-02 10:18:36:062, 2353 ms at 2026-11-02 10:18:45:949, 1699 ms at 2026-11-02 10:26:36:202
- llm.parsed:remote: 7007 ms at 2026-11-02 10:18:36:022, 1699 ms at 2026-11-02 10:26:36:195

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| preferences.save | 3 | 2039 | 2048 | 1980 | 2048 | 250 ms (static/ergopti_plus/macos/infra/preferences.lua) | ❌ over (3) |
| healthcheck.sync | 5 | 38.1 | 248 | 76.3 | 248 | 5 ms (stated in the log line) | ❌ over (5) |

Worst occurrences:

- preferences.save: 2048 ms at 2026-11-02 10:02:11:959, 2039 ms at 2026-11-02 10:08:51:539, 1853 ms at 2026-11-02 10:08:49:349
- healthcheck.sync: 248 ms at 2026-11-02 10:21:23:737, 39 ms at 2026-11-02 10:26:15:942, 38.1 ms at 2026-11-02 08:06:47:066

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.sfltool | 1 | — | — | 20047 | 20047 | no budget declared | — |
| phase:process.cat | 1 | — | — | 5285 | 5285 | no budget declared | — |
| phase:process.python3 | 19 | — | — | 444 | 2569 | no budget declared | — |
| phase:process.curl | 40 | — | — | 69.92 | 1499 | no budget declared | — |
| phase:process.ErgoptiPlus | 30 | — | — | 476 | 1494 | no budget declared | — |
| phase:process.defaults | 253 | — | — | 51.91 | 1463 | no budget declared | — |
| phase:process.pgrep | 8 | — | — | 269 | 1383 | no budget declared | — |
| phase:boot.stage | 48 | — | — | 74.63 | 614 | no budget declared | — |
| phase:boot.requires | 32 | — | — | 69 | 601 | no budget declared | — |
| phase:process.spctl | 1 | — | — | 553 | 553 | no budget declared | — |
| phase:process.sqlite3 | 1 | — | — | 543 | 543 | no budget declared | — |
| phase:karabiner.deploy | 9 | — | — | 203 | 354 | no budget declared | — |
| phase:boot.stage_cpu | 48 | — | — | 50.96 | 333 | no budget declared | — |
| phase:karabiner.merge | 9 | — | — | 172 | 223 | no budget declared | — |
| phase:shell.sw_vers | 2 | — | — | 128 | 193 | no budget declared | — |
| phase:process.codesign | 3 | — | — | 90.76 | 172 | no budget declared | — |
| phase:process.brew | 1 | — | — | 143 | 143 | no budget declared | — |
| phase:karabiner.write | 2 | — | — | 120 | 131 | no budget declared | — |
| phase:shell.other | 2 | — | — | 106 | 124 | no budget declared | — |
| phase:process.bash | 1 | — | — | 122 | 122 | no budget declared | — |
| phase:shell.ls | 24 | — | — | 50.36 | 112 | no budget declared | — |
| phase:process.shortcuts | 2 | — | — | 76.62 | 93.57 | no budget declared | — |
| phase:shell.systemextensionsctl | 2 | — | — | 84.4 | 85.62 | no budget declared | — |
| phase:karabiner.layout_actions | 9 | — | — | 28.41 | 79.24 | no budget declared | — |
| phase:shell.ioreg | 2 | — | — | 53.69 | 61.91 | no budget declared | — |
| phase:shell.curl | 1 | — | — | 60.14 | 60.14 | no budget declared | — |
| phase:karabiner.inputs | 9 | — | — | 36.36 | 56.32 | no budget declared | — |
| phase:process.Application | 1 | — | — | 53.48 | 53.48 | no budget declared | — |
| phase:process.mkdir | 5 | — | — | 32.36 | 50.93 | no budget declared | — |
| phase:shell.mkdir | 5 | — | — | 32.35 | 50.91 | no budget declared | — |
| phase:shell.find | 2 | — | — | 44.81 | 48.95 | no budget declared | — |
| phase:karabiner.build | 9 | — | — | 30.81 | 44.8 | no budget declared | — |
| phase:process.grep | 2 | — | — | 21.32 | 31.15 | no budget declared | — |
| phase:process.xmllint | 8 | — | — | 7.28 | 31.03 | no budget declared | — |
| phase:hotstring_load.common_file | 4 | — | — | 11.97 | 20.79 | no budget declared | — |
| phase:process.systemextensionsctl | 1 | — | — | 19.16 | 19.16 | no budget declared | — |
| phase:process.ps | 2 | — | — | 16.09 | 19.12 | no budget declared | — |
| phase:karabiner.encode | 2 | — | — | 18.6 | 18.69 | no budget declared | — |
| phase:toml.parse | 53 | — | — | 1.46 | 11.73 | no budget declared | — |
| phase:hotpath.keydown | 51 | — | — | 1.3 | 8.85 | no budget declared | — |
| phase:hotpath.hotstring.match | 18 | — | — | 0.46 | 7.48 | no budget declared | — |
| phase:process.scutil | 1 | — | — | 6.93 | 6.93 | no budget declared | — |
| phase:process.launchctl | 1 | — | — | 6.66 | 6.66 | no budget declared | — |
| phase:hotpath.preview.rebuild | 17 | — | — | 1.55 | 6.29 | no budget declared | — |
| phase:preview.total | 20 | — | — | 1.48 | 6.29 | no budget declared | — |
| phase:process.plutil | 4 | — | — | 4.35 | 5.18 | no budget declared | — |
| phase:hotpath.hotstring.expand | 1 | — | — | 4.95 | 4.95 | no budget declared | — |
| phase:process.memory_pressure | 1 | — | — | 3.46 | 3.46 | no budget declared | — |
| phase:process.id | 1 | — | — | 2.05 | 2.05 | no budget declared | — |
| phase:preview.providers | 20 | — | — | 0.73 | 1.93 | no budget declared | — |
| phase:preview.resolve | 20 | — | — | 0.07 | 0.38 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 10
- counter:runtime.timer_hold_over_1000ms: 11
- counter:runtime.timer_hold_over_250ms: 114

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 6 | 2026-11-02 08:05:02:946 | 2026-11-02 10:29:22:481 |
| stop | 3 | 2026-11-02 08:05:02:222 | 2026-11-02 10:29:21:618 |
| reload | 3 | 2026-11-02 08:05:01:740 | 2026-11-02 10:29:21:139 |
| sleep_wake | 4 | 2026-11-02 08:04:47:494 | 2026-11-02 10:16:51:742 |
| network_failure | 2 | 2026-11-02 08:05:32:126 | 2026-11-02 10:25:17:276 |
| event_tap_disabled | 1 | 2026-11-02 10:08:51:565 | 2026-11-02 10:08:51:565 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-11-02 08:05:02:946 — ErgoptiPlus session opened =====
===== 2026-11-02 08:05:27:062 — ErgoptiPlus session opened =====
===== 2026-11-02 08:12:07:016 — ErgoptiPlus session opened =====
===== 2026-11-02 10:21:22:214 — ErgoptiPlus session opened =====
===== 2026-11-02 10:24:15:724 — ErgoptiPlus session opened =====
===== 2026-11-02 10:29:22:481 — ErgoptiPlus session opened =====
```

**stop**

```
2026-11-02 08:05:02:222 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-02 08:12:06:218 [INFO] [init] Hammerspoon local teardown started (reload).
2026-11-02 10:29:21:618 [INFO] [init] Hammerspoon local teardown started (reload).
```

**reload**

```
2026-11-02 08:05:01:740 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-11-02 08:12:05:724 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
2026-11-02 10:29:21:139 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: field_run_timed_reload).
```

**sleep_wake**

```
2026-11-02 08:04:47:494 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-11-02 08:16:11:695 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-11-02 09:57:25:569 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-11-02 10:16:51:742 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
```

**network_failure**

```
2026-11-02 08:05:32:126 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-11-02 10:25:17:276 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

**event_tap_disabled**

```
2026-11-02 10:08:51:565 [WARNING] [keystats] Keystats event tap found disabled — restarting.
```

</details>
