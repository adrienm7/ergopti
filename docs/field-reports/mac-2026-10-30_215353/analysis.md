# Field log analysis

Logs: ErgoptiPlus_2026-10-30.log (42963 lines, 42142 records, 713 continuation lines); span 2026-10-30 00:00:00:313 to 2026-10-30 22:01:21:980.
Previous report compared: none of this OS tag in this folder.

## What to fix first

| # | Score | Kind | What | Count | Detail |
|---|---|---|---|---|---|
| 1 | 438 | slow | main_thread.hold over its 250 ms budget | 146 | max 17260 ms at 2026-10-30 10:10:43:816 |
| 2 | 261 | slow | hotpath:preview.rebuild over its 5 ms budget | 87 | max 12.56 ms at 2026-10-30 12:02:20:504 |
| 3 | 100 | error | [llm.api_ollama] The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 20 | 2026-10-30 17:37:35:422 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags). |
| 4 | 90 | slow | healthcheck.sync over its 5 ms budget | 30 | max 230 ms at 2026-10-30 01:13:33:243 |
| 5 | 54 | slow | hotpath:keydown over its 5 ms budget | 18 | max 12.5 ms at 2026-10-30 10:37:57:906 |
| 6 | 51 | slow | hotpath:hotstring.expand over its 5 ms budget | 17 | max 15.35 ms at 2026-10-30 11:58:29:509 |
| 7 | 39 | slow | input.late_key_event over its 250 ms budget | 13 | max 2050 ms at 2026-10-30 00:54:14:761 |
| 8 | 35 | error | [ollama_deps] Ollama daemon start failed (exit=<*>) — Impossible de lancer le démon Ollama. | 7 | 2026-10-30 16:29:57:670 [ERROR] [ollama_deps] Ollama daemon start failed (exit=-1) — Impossible de lancer le démon Ollama. |
| 9 | 30 | slow | preferences.save over its 250 ms budget | 10 | max 2141 ms at 2026-10-30 01:18:43:317 |
| 10 | 25 | error | [config_migrate] Config migration of '<*>' refused (newer): canonical schema version is newer than this build. The file is left untouched and this session will not write it. | 5 | 2026-10-30 01:12:46:423 [ERROR] [config_migrate] Config migration of '~/perso/config/ergopti_plus/hammerspoon/config.toml' refused (newer): canonical schema version is newer than this build. The file is left untouched and this session will not write it. |

Score: crash x10, error x5, measure over budget x3, warning x1, times the occurrences.

## Check verdicts

- ✅ lease: pass (2026-10-30 21:54:10:506, last of 13 runs, 0 failed)
- ✅ owned_runtime: pass (2026-10-30 21:54:10:609, last of 13 runs, 0 failed)
- ✅ network: pass (2026-10-30 21:54:11:802, last of 13 runs, 0 failed)
- ✅ toolchain: pass (2026-10-30 21:54:13:092, last of 13 runs, 1 failed)
- ✅ login_items: pass (2026-10-30 21:54:33:250, last of 13 runs, 0 failed)
- ✅ composer: pass (2026-10-30 21:54:34:778, last of 13 runs, 0 failed)
- ✅ permissions: pass (2026-10-30 21:54:34:879, last of 3 runs, 0 failed)
- ✅ event_taps: pass (2026-10-30 21:54:35:388, last of 3 runs, 0 failed)
- ❌ input_sources: fail (2026-10-30 21:54:35:575, last of 3 runs, 3 failed)
- ✅ storage: pass (2026-10-30 21:54:36:228, last of 3 runs, 0 failed)
- ❌ launcher_roles: fail (2026-10-30 21:54:36:306, last of 3 runs, 3 failed)
- ✅ network_hosts: pass (2026-10-30 21:54:39:181, last of 3 runs, 2 failed)
- ✅ typing_selftest: pass (2026-10-30 21:54:45:197, last of 3 runs, 0 failed)
- ✅ menu_build: pass (2026-10-30 21:54:45:556, last of 3 runs, 0 failed)
- ✅ ai_local: pass (2026-10-30 21:57:52:669, last of 3 runs, 0 failed)
- ❌ app_health: fail (2026-10-30 21:57:52:689, last of 3 runs, 3 failed)
- ⚠️ privacy_pane_urls: info (privacy_pane_urls)
- ✅ system_bash: pass (system_bash)

Check verdicts summary: ✅ 14 pass, ❌ 3 fail, ⏭️ 0 skip, ⌨️ 0 needs_typing, ⚠️ 1 other.

## Errors and warnings

46 error group(s), 79 warning group(s); 451 occurrence(s); no previous report, so none marked new since the previous report.

| Level | Module | Template | Count | First | Last | New |
|---|---|---|---|---|---|---|
| ERROR | llm.api_ollama | The local server's model list is unavailable: HTTP <*> (Network request failed: Connection failed: Could not connect to the server. - http://<*>/api/tags). | 20 | 2026-10-30 17:37:35:422 | 2026-10-30 17:38:13:499 |  |
| ERROR | ollama_deps | Ollama daemon start failed (exit=<*>) — Impossible de lancer le démon Ollama. | 7 | 2026-10-30 16:29:57:670 | 2026-10-30 18:39:55:692 |  |
| ERROR | config_migrate | Config migration of '<*>' refused (newer): canonical schema version is newer than this build. The file is left untouched and this session will not write it. | 5 | 2026-10-30 01:12:46:423 | 2026-10-30 10:13:30:619 |  |
| ERROR | karabiner.lease | '<*>' called before M.init() — lease controller unavailable. | 5 | 2026-10-30 01:12:47:129 | 2026-10-30 10:13:31:032 |  |
| ERROR | llm.api_ollama | Ollama ollama_server_exited_before_publication did not commit (result: false); launch remains retryable. | 5 | 2026-10-30 17:37:35:409 | 2026-10-30 18:39:55:692 |  |
| ERROR | menu_llm.ollama | Managed model pull retirement is pending; exact task slot retained. | 4 | 2026-10-30 20:47:10:697 | 2026-10-30 21:57:41:763 |  |
| ERROR | menu_llm.ollama | The Ollama pull of granite4:<*>m-h ended (code <*>) but its task could not be settled. | 4 | 2026-10-30 20:47:10:697 | 2026-10-30 21:57:41:763 |  |
| ERROR | llm.api_mlx | MLX model '<*>' marked as failed to load — status dot will show red. | 3 | 2026-10-30 01:03:46:462 | 2026-10-30 01:59:49:563 |  |
| ERROR | llm.api_ollama | ensure_running() did not commit: false | 3 | 2026-10-30 16:29:57:674 | 2026-10-30 17:20:46:729 |  |
| ERROR | llm.prediction_engine | Chain rescan suppression did not commit: nil | 2 | 2026-10-30 00:19:09:420 | 2026-10-30 00:23:41:641 |  |
| ERROR | keymap.llm_bridge | Prediction applied, but LLM chain ownership did not commit (result: false). | 2 | 2026-10-30 00:19:09:420 | 2026-10-30 00:23:41:641 |  |
| ERROR | karabiner.lease | Karabiner lease <*> failed; fencing before publishing failure: timeout waiting for PONG <*> | 2 | 2026-10-30 00:58:10:319 | 2026-10-30 01:22:17:829 |  |
| ERROR | llm.api_mlx | MLX discovery for '<*>' gave up after <*>s — surfacing as load failure. | 2 | 2026-10-30 01:03:46:462 | 2026-10-30 01:59:49:563 |  |
| ERROR | menu_llm.mlx | MLX packages are not importable from the installed runtime ~/Library/Application Support/Ergopti/mlx-venv/bin/python (exit=<*>, cause=import_failed, path=nil): (no output) | 2 | 2026-10-30 01:18:35:233 | 2026-10-30 10:10:24:191 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c6<*>), enabled=false). | 2 | 2026-10-30 10:07:38:814 | 2026-10-30 10:07:39:829 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c3ea7<*>b8), enabled=false). | 2 | 2026-10-30 10:07:39:827 | 2026-10-30 10:07:39:828 |  |
| ERROR | hotstring_editor | Personal hotstrings were saved but the live group reload rolled back. | 2 | 2026-10-30 11:37:12:920 | 2026-10-30 11:37:53:444 |  |
| ERROR | llm.api_ollama | Ollama server executable resolution did not commit (result: Ergopti's own Ollama runtime is not installed); launch remains retryable. | 2 | 2026-10-30 17:06:56:036 | 2026-10-30 17:20:46:724 |  |
| ERROR | fs_dir | Cannot iterate directory '<*>' — ...perso/ergopti/static/ergopti_plus/macos/infra/fs_dir.lua:<*>: cannot open ~/perso/ergopti/ergopti_plus/crash_reports: No such file or directory. | 2 | 2026-10-30 20:56:56:292 | 2026-10-30 21:06:02:260 |  |
| ERROR | menu | Failed to load "<*>" (ui.menu.menu_llm): ...erso/ergopti/static/ergopti_plus/_shared/lua/timings.lua:<*>: [timings] missing or non-numeric key [llm].ai_health_watch_ms in constants.toml. | 1 | 2026-10-30 00:15:58:965 | 2026-10-30 00:15:58:965 |  |
| ERROR | llm.core | set_user_profiles(): profiles_table must be a table. | 1 | 2026-10-30 00:15:59:702 | 2026-10-30 00:15:59:702 |  |
| ERROR | menu_state | sync_state_to_modules: feature '<*>' was not fully applied: llm.set_user_profiles did not commit — false. | 1 | 2026-10-30 00:15:59:702 | 2026-10-30 00:15:59:702 |  |
| ERROR | menu_state | Feature '<*>' is OFF for this session because llm.set_user_profiles was refused; config.toml keeps its saved value. | 1 | 2026-10-30 00:15:59:703 | 2026-10-30 00:15:59:703 |  |
| ERROR | llm.api_mlx | Discovery reset POST-probe cancellation retained exact HTTP debt: false. | 1 | 2026-10-30 01:11:38:665 | 2026-10-30 01:11:38:665 |  |
| ERROR | llm.api_mlx | Endpoint reset retained predecessor debt (discovery=false, warmup=true, pgid=true). | 1 | 2026-10-30 01:11:38:665 | 2026-10-30 01:11:38:665 |  |
| ERROR | menu_llm.mlx | Server settlement refused MLX endpoint reset: false. | 1 | 2026-10-30 01:11:38:665 | 2026-10-30 01:11:38:665 |  |
| ERROR | menu_llm.mlx | MLX server for ‘<*>’ crashed — giving up. Reason: <*> [MLX-SERVER] ModuleNotFoundError: No module named '<*>' | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| ERROR | menu_llm.mlx | MLX crash for ‘<*>’ — last <*> line(s) from MLX server stdout (full trace in ~/perso/ergopti/ergopti_plus/ErgoptiPlus_2<*><*><*>.log): | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| ERROR | startup_ctrl | Disabling LLM (requirements check failed: server_start_failed). | 1 | 2026-10-30 01:18:41:073 | 2026-10-30 01:18:41:073 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c6<*>f5<*>), enabled=false). | 1 | 2026-10-30 10:07:38:814 | 2026-10-30 10:07:38:814 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c6<*>fbb8), enabled=false). | 1 | 2026-10-30 10:07:38:814 | 2026-10-30 10:07:38:814 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c6<*>ffb8), enabled=false). | 1 | 2026-10-30 10:07:38:814 | 2026-10-30 10:07:38:814 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c6<*>eb8), enabled=false). | 1 | 2026-10-30 10:07:39:829 | 2026-10-30 10:07:39:829 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c2ff1<*>), enabled=false). | 1 | 2026-10-30 10:07:42:832 | 2026-10-30 10:07:42:832 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c2a2<*>), enabled=false). | 1 | 2026-10-30 10:07:42:836 | 2026-10-30 10:07:42:836 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c2a2<*>b8), enabled=false). | 1 | 2026-10-30 10:07:42:836 | 2026-10-30 10:07:42:836 |  |
| ERROR | shortcuts.actions.system | Eventtap '<*>' activation did not commit (start=hs.eventtap: Eventtap Mask: <*>x4<*> (<*>x8c2a2<*>d3<*>), enabled=false). | 1 | 2026-10-30 10:07:42:837 | 2026-10-30 10:07:42:837 |  |
| ERROR | karabiner | Remap guardian status is '<*>': the background helper is not registered, so tap-holds and remaps stay inert; ~/Library/Logs/ergopti_plus/launcher.log names the registration cause. | 1 | 2026-10-30 10:10:43:827 | 2026-10-30 10:10:43:827 |  |
| ERROR | shortcuts.actions.screenshot_save | Screenshot capture failed: screencapture exited with code <*> but produced no image. | 1 | 2026-10-30 10:15:30:849 | 2026-10-30 10:15:30:849 |  |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-10-30 12:09:11:851 | 2026-10-30 12:09:11:851 |  |
| ERROR | ollama_deps | Ollama bootstrap failed (exit=<*>) — [OLLAMA-DEPS] ERROR: stage python_download ended with exit <*>. | 1 | 2026-10-30 12:09:11:851 | 2026-10-30 12:09:11:851 |  |
| ERROR | model_selector_page | The ollama runtime install from the model selector page failed. | 1 | 2026-10-30 12:09:11:872 | 2026-10-30 12:09:11:872 |  |
| ERROR | ollama_deps | Ollama bootstrap ended with exit=<*> (no signal, path=native_runtime_pty); output received: streamed stdout=<*> stderr=<*> bytes, final stdout=<*> stderr=<*> bytes; last <*> line(s): [OLLAMA-DEPS] stage: python_bootstrap \| [NATIVE-BOOTSTRAP] stage: uv_extract \| [NATIVE-BOOTSTRAP] stage: python_down… | 1 | 2026-10-30 13:44:59:856 | 2026-10-30 13:44:59:856 |  |
| ERROR | ollama_deps | Ollama bootstrap failed (exit=<*>) — Cette app de développement n'<*>'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xcode sont nécessaires). | 1 | 2026-10-30 13:44:59:856 | 2026-10-30 13:44:59:856 |  |
| ERROR | llm.api_ollama | Ollama server executable resolution did not commit (result: managed runtime metadata is pending); launch remains retryable. | 1 | 2026-10-30 16:29:57:670 | 2026-10-30 16:29:57:670 |  |
| ERROR | keystats.log_manager | Ingest batch rolled back: cannot commit ingest transaction: database is locked. | 1 | 2026-10-30 20:52:44:430 | 2026-10-30 20:52:44:430 |  |
| WARNING | HotPath | Slow preview.rebuild: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 87 | 2026-10-30 00:16:22:594 | 2026-10-30 14:19:57:479 |  |
| WARNING | HotPath | Slow keydown: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 18 | 2026-10-30 10:16:05:745 | 2026-10-30 11:38:26:144 |  |
| WARNING | HotPath | Slow hotstring.expand: <*> ms own, <*> ms total, parent hotstring.match (<*> similar since the last line). | 16 | 2026-10-30 00:19:05:563 | 2026-10-30 11:58:29:509 |  |
| WARNING | adapters.hotkey_registrar | bind(): the OS refused '<*>' — nil. | 15 | 2026-10-30 13:52:08:328 | 2026-10-30 21:00:23:563 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried. | 14 | 2026-10-30 13:52:08:328 | 2026-10-30 21:00:23:563 |  |
| WARNING | adapters.field_check_ports | PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found. | 13 | 2026-10-30 13:42:55:257 | 2026-10-30 21:54:10:639 |  |
| WARNING | shortcuts.keyboard_shortcuts | Shortcut Ctrl+. (slot '<*>') could not be registered (key '<*>' is not in the active keyboard layout); the other shortcuts stay active and it is retried. | 12 | 2026-10-30 13:52:05:792 | 2026-10-30 21:00:22:279 |  |
| WARNING | key_event_health | A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across… | 11 | 2026-10-30 00:19:09:642 | 2026-10-30 15:32:55:137 |  |
| WARNING | preferences | Slow preferences save <*> ms (prepare=<*> write=<*> ms; operations=<*>; prepare: snapshot=<*> decode=<*> models=<*> sparse=<*> wrap=<*> rows=<*> gestures=<*> llm=<*> shortcuts=<*> hotstrings=<*> ms; proposed=<*>; metadata_commands=<*> in <*> ms; lua_heap=<*>-><*> MB). | 10 | 2026-10-30 00:53:56:018 | 2026-10-30 10:12:29:002 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> ms). | 10 | 2026-10-30 01:08:56:498 | 2026-10-30 20:42:03:918 |  |
| WARNING | keymap.utils | Slow ignored-window probe <*> ms (watchers=<*> focused_window=<*> application=<*> app_name=<*> title=<*> context_watchers=<*> secure_field=<*> destination=<*> ms). | 9 | 2026-10-30 01:18:03:152 | 2026-10-30 18:39:53:753 |  |
| WARNING | download_window | Progress UI flipped to error state: Impossible de lancer le démon Ollama. | 7 | 2026-10-30 16:29:57:670 | 2026-10-30 18:39:55:733 |  |
| WARNING | llm.api_mlx | MLX endpoint discovery: all candidates returned <*> — model may still be loading. Will retry on next warmup. | 5 | 2026-10-30 01:08:55:558 | 2026-10-30 01:20:02:926 |  |
| WARNING | key_event_health | A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or … | 5 | 2026-10-30 10:28:33:121 | 2026-10-30 11:44:48:251 |  |
| WARNING | key_event_health | Key events reached the keymap taps <*> ms or more late: the main thread held them; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a rule switch), <*> ke… | 4 | 2026-10-30 00:54:14:761 | 2026-10-30 11:44:09:255 |  |
| WARNING | keymap.utils | Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed. | 4 | 2026-10-30 00:58:28:019 | 2026-10-30 13:48:42:013 |  |
| WARNING | keymap | Ignored-window watcher preparation incomplete; tracking remains fail-closed: false. | 4 | 2026-10-30 00:58:28:020 | 2026-10-30 13:48:42:013 |  |
| WARNING | llm.api_mlx | Endpoint discovery: gave up waiting for MLX server after <*>s. Falling back to default routes; warmup will keep retrying. | 4 | 2026-10-30 01:01:42:389 | 2026-10-30 02:16:58:409 |  |
| WARNING | llm.api_mlx | Endpoint discovery: expected model '<*>' not visible in /v1/models cache list — POST may <*> if mlx_lm cannot resolve it. | 4 | 2026-10-30 01:08:55:554 | 2026-10-30 01:14:37:909 |  |
| WARNING | shortcuts.actions.screen_capture | Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime. | 4 | 2026-10-30 10:06:50:067 | 2026-10-30 10:14:32:888 |  |
| WARNING | shortcuts.bindings | Hotkey '<*>' could not be registered (its factory returned no hotkey); the other shortcuts stay active and it is retried. | 4 | 2026-10-30 10:07:38:814 | 2026-10-30 10:07:38:815 |  |
| WARNING | HotPath | Slow tooltip.show_predictions: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 3 | 2026-10-30 00:19:08:174 | 2026-10-30 00:45:24:830 |  |
| WARNING | keystats | Keystats event tap found disabled — restarting. | 3 | 2026-10-30 00:53:58:065 | 2026-10-30 17:24:42:361 |  |
| WARNING | keystats.log_manager | Slow ingest tick <*> ms (drain=<*> foreign=<*> outbox=<*> read=<*> build=<*> apply=<*> commit=<*> append=<*> notify=<*> ms; append: lock=<*> journal=<*> prepare=<*> publish=<*> write=<*> clear=<*> settle=<*> release=<*> ms; metadata_commands=<*> in <*> ms; entries=<*> statements=<*>). | 3 | 2026-10-30 00:54:06:072 | 2026-10-30 10:47:30:590 |  |
| WARNING | menu_llm.mlx | MLX model Qwen3.<*><*>B not detected as installed. Starting download flow… | 3 | 2026-10-30 00:56:02:438 | 2026-10-30 00:58:37:722 |  |
| WARNING | adapters.http_client | Request timed out after <*>ms. | 3 | 2026-10-30 01:16:40:451 | 2026-10-30 01:17:40:452 |  |
| WARNING | HotPath | Slow hotstring.match: <*> ms own, <*> ms total, parent keydown (<*> similar since the last line). | 3 | 2026-10-30 10:16:29:428 | 2026-10-30 11:38:11:156 |  |
| WARNING | karabiner.lease | Karabiner lease <*>: task output stayed unread for <*> s after the PONG <*> deadline. | 2 | 2026-10-30 00:58:10:318 | 2026-10-30 01:22:17:829 |  |
| WARNING | karabiner.lease | Karabiner lease <*> waited <*> s for PONG <*>; the deadline timer fired <*> s late. | 2 | 2026-10-30 00:58:10:319 | 2026-10-30 01:22:17:829 |  |
| WARNING | key_event_health | A Karabiner lease failed (pong); session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a rule switch), <*> key-down(s) and <*> key-up(s) seen <*> ms or more la… | 2 | 2026-10-30 00:58:10:319 | 2026-10-30 01:22:17:829 |  |
| WARNING | karabiner.lease | Starting detached fallback revoker for lease <*> (timeout waiting for PONG <*>). | 2 | 2026-10-30 00:58:10:319 | 2026-10-30 01:22:17:829 |  |
| WARNING | karabiner | Karabiner lease failed after exact fencing; fresh-generation recovery attempt <*>/<*> in <*> s (unexpected-worker-loss). | 2 | 2026-10-30 00:58:10:990 | 2026-10-30 01:22:18:503 |  |
| WARNING | runtime | An hs.timer.new callback (...gopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: shell.ls=<*> ms, shell.cp=<*> ms, shell.ls=<*> ms, shell.ls=<*> ms. Lua heap… | 2 | 2026-10-30 00:58:19:875 | 2026-10-30 10:12:29:002 |  |
| WARNING | llm.core | warmup_model: backend warmup did not commit: false | 2 | 2026-10-30 01:03:46:470 | 2026-10-30 01:59:49:565 |  |
| WARNING | llm.api_mlx | PGID pending timeout (<*>s) — unblocking zombie kills. | 2 | 2026-10-30 01:16:14:982 | 2026-10-30 10:10:43:856 |  |
| WARNING | mlx_deps | MLX runtime invalidated; the next MLX selection repairs ~/Library/Application Support/Ergopti/mlx-venv. | 2 | 2026-10-30 01:18:35:234 | 2026-10-30 10:10:24:192 |  |
| WARNING | startup_ctrl | Startup MLX backup check failed for Qwen3.<*><*>B. | 2 | 2026-10-30 01:18:35:235 | 2026-10-30 10:10:24:193 |  |
| WARNING | menu_llm.mlx_repair_offer | Offering the MLX repair action for a import_failed failure. | 2 | 2026-10-30 01:18:35:238 | 2026-10-30 10:10:24:196 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in _get_module | 2 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in _gcd_import | 2 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in _find_and_load | 2 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in _find_and_load_unlocked | 2 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | karabiner.lease | Karabiner lease <*> heartbeat <*> had no clean local CLI transport. | 2 | 2026-10-30 03:13:08:919 | 2026-10-30 08:40:26:021 |  |
| WARNING | shortcuts.keyboard_shortcuts | Some shortcuts are still unregistered after <*> retries; the next keyboard-layout change retries them. | 2 | 2026-10-30 13:52:51:338 | 2026-10-30 18:30:54:035 |  |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: NativeHTTPError at native_http.py:<*> _read_exact, from managed_ollama_serve.py:<*> discover, reason=protocol, stage=native_first_frame, native_child_status=<*>, cleanup=confirmed. | 2 | 2026-10-30 18:38:20:258 | 2026-10-30 18:39:55:692 |  |
| WARNING | llm.streaming_handler | Watchdog triggered: stream produced no visible result for <*>s. | 1 | 2026-10-29 23:50:59:228 | 2026-10-29 23:50:59:228 |  |
| WARNING | menu | Saved preferences applied except <*> refused step(s), isolated to their feature. | 1 | 2026-10-30 00:15:59:739 | 2026-10-30 00:15:59:739 |  |
| WARNING | builder | LLM handler missing or incomplete — AI component ignored. | 1 | 2026-10-30 00:16:02:158 | 2026-10-30 00:16:02:158 |  |
| WARNING | HotPath | Slow hotstring.expand: <*> ms own, <*> ms total, parent none (<*> similar since the last line). | 1 | 2026-10-30 00:23:41:630 | 2026-10-30 00:23:41:630 |  |
| WARNING | keymap | macOS disabled the loopbackKeyUp event tap — re-enabling. | 1 | 2026-10-30 00:54:14:761 | 2026-10-30 00:54:14:761 |  |
| WARNING | startup_ctrl | Disabling LLM: the mlx backend (startup_model_download_declined: Qwen3.<*><*>B). | 1 | 2026-10-30 00:58:17:639 | 2026-10-30 00:58:17:639 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER] Traceback (most recent call last): | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in __getattr__ | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in import_module | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]     return _bootstrap._gcd_import(name[level:], package, level) | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]            ~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER]   File "<*>", line <*>, in _call_with_frames_removed | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | menu_llm.mlx | \| <*> [MLX-SERVER] ModuleNotFoundError: No module named '<*>' | 1 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |  |
| WARNING | runtime | An hs.timer.new callback (...gopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: shell.ls=<*> ms, shell.ls=<*> ms, shell.cp=<*> ms, shell.ls=<*> ms. Lua heap… | 1 | 2026-10-30 01:18:43:318 | 2026-10-30 01:18:43:318 |  |
| WARNING | keystats.context_tracker | Accessibility observer setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:<*>: The accessibility API is disabled | 1 | 2026-10-30 10:07:36:253 | 2026-10-30 10:07:36:253 |  |
| WARNING | runtime | An hs.timer.new callback (...i/static/ergopti_plus/macos/infra/accessibility_wait.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=<*> ms, boot.stage=<*> ms, boot.stage_cpu=<*> ms, boot.requires=<… | 1 | 2026-10-30 10:10:21:380 | 2026-10-30 10:10:21:380 |  |
| WARNING | runtime | An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-30 10:10:43:816 | 2026-10-30 10:10:43:816 |  |
| WARNING | karabiner | Karabiner regeneration remains fail-closed after guardian status '<*>' (regeneration-preflight). | 1 | 2026-10-30 10:10:43:833 | 2026-10-30 10:10:43:833 |  |
| WARNING | menu_llm.runtime_offer | The mlx runtime is not installed; its notice offers the install. | 1 | 2026-10-30 10:12:24:991 | 2026-10-30 10:12:24:991 |  |
| WARNING | mlx_deps | MLX runtime is not installed; no bootstrap without an MLX backend selection. | 1 | 2026-10-30 10:12:26:969 | 2026-10-30 10:12:26:969 |  |
| WARNING | startup_ctrl | Disabling LLM: the mlx backend (startup_runtime_not_installed). | 1 | 2026-10-30 10:12:27:150 | 2026-10-30 10:12:27:150 |  |
| WARNING | runtime | An hs.timer.new callback (...i/static/ergopti_plus/macos/infra/accessibility_wait.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=<*> ms, boot.stage=<*> ms, boot.stage_cpu=<*> ms, boot.stage_cpu=… | 1 | 2026-10-30 10:14:12:452 | 2026-10-30 10:14:12:452 |  |
| WARNING | key_event_health | A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps; session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*> across a ru… | 1 | 2026-10-30 10:15:07:604 | 2026-10-30 10:15:07:604 |  |
| WARNING | key_event_health | A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream (<*> times); session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more… | 1 | 2026-10-30 11:44:09:255 | 2026-10-30 11:44:09:255 |  |
| WARNING | key_event_health | A character key stayed down <*> s with no further event: its key-up was lost before the keymap taps (<*> times); session totals: <*> key-down(s), <*> key-up(s), <*> key-up(s) without key-down, <*> key-down(s) without key-up, <*> key(s) stuck over <*> s, <*> character key(s) held <*> ms or more (<*>… | 1 | 2026-10-30 11:44:15:252 | 2026-10-30 11:44:15:252 |  |
| WARNING | karabiner.lease | Starting detached fallback revoker for lease <*> (watchdog completion). | 1 | 2026-10-30 11:55:34:625 | 2026-10-30 11:55:34:625 |  |
| WARNING | download_window | Progress UI flipped to error state: [OLLAMA-DEPS] ERROR: stage python_download ended with exit <*>. | 1 | 2026-10-30 12:09:11:872 | 2026-10-30 12:09:11:872 |  |
| WARNING | download_window | Progress UI flipped to error state: Cette app de développement n'<*>'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xcode sont nécessaires). | 1 | 2026-10-30 13:44:59:856 | 2026-10-30 13:44:59:856 |  |
| WARNING | menu_watchers | Menu source reload held while the developer field run runs (<*> file(s): ~/perso/ergopti/static/ergopti_plus/macos/modules/keymap/expander.lua, ~/perso/ergopti/static/ergopti_plus/macos/modules/keymap/init.lua, ~/perso/ergopti/static/ergopti_plus/macos/tests/unit/modules/keymap/preview/test_preview… | 1 | 2026-10-30 13:45:16:293 | 2026-10-30 13:45:16:293 |  |
| WARNING | logger | ↑ <*> identical line suppressed | 1 | 2026-10-30 13:52:51:338 | 2026-10-30 13:52:51:338 |  |
| WARNING | field_run | A stale field run request was left by an earlier session; removed. | 1 | 2026-10-30 15:02:36:076 | 2026-10-30 15:02:36:076 |  |
| WARNING | managed_ollama_hint | Owned Ollama runtime metadata refused (exit=<*>): refused: TypeError at ollama_hint_metadata.py:<*> read_regular | 1 | 2026-10-30 17:19:31:251 | 2026-10-30 17:19:31:251 |  |
| WARNING | runtime | An hs.timer.new callback (...opti/static/ergopti_plus/macos/modules/keystats/init.lua:<*>) held the main thread for <*> ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap <*>-><*> MB. | 1 | 2026-10-30 17:24:44:375 | 2026-10-30 17:24:44:375 |  |
| WARNING | managed_ollama_daemon | Managed Ollama daemon exited (status=<*>): Managed Ollama daemon admission refused: NativeHTTPError at native_http.py:<*> _read_exact. | 1 | 2026-10-30 18:26:39:407 | 2026-10-30 18:26:39:407 |  |

<details><summary>One example line per group</summary>

```
2026-10-30 17:37:35:422 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
```
```
2026-10-30 16:29:57:670 [ERROR] [ollama_deps] Ollama daemon start failed (exit=-1) — Impossible de lancer le démon Ollama.
```
```
2026-10-30 01:12:46:423 [ERROR] [config_migrate] Config migration of '~/perso/config/ergopti_plus/hammerspoon/config.toml' refused (newer): canonical schema version is newer than this build. The file is left untouched and this session will not write it.
```
```
2026-10-30 01:12:47:129 [ERROR] [karabiner.lease] 'status' called before M.init() — lease controller unavailable.
```
```
2026-10-30 17:37:35:409 [ERROR] [llm.api_ollama] Ollama ollama_server_exited_before_publication did not commit (result: false); launch remains retryable.
```
```
2026-10-30 20:47:10:697 [ERROR] [menu_llm.ollama] Managed model pull retirement is pending; exact task slot retained.
```
```
2026-10-30 20:47:10:697 [ERROR] [menu_llm.ollama] The Ollama pull of granite4:350m-h ended (code 78) but its task could not be settled.
```
```
2026-10-30 01:03:46:462 [ERROR] [llm.api_mlx] MLX model 'Qwen3.5-2B-4bit' marked as failed to load — status dot will show red.
```
```
2026-10-30 16:29:57:674 [ERROR] [llm.api_ollama] ensure_running() did not commit: false
```
```
2026-10-30 00:19:09:420 [ERROR] [llm.prediction_engine] Chain rescan suppression did not commit: nil
```
```
2026-10-30 00:19:09:420 [ERROR] [keymap.llm_bridge] Prediction applied, but LLM chain ownership did not commit (result: false).
```
```
2026-10-30 00:58:10:319 [ERROR] [karabiner.lease] Karabiner lease 1d5543ecc55c40d5b82c8d50b1bea79f failed; fencing before publishing failure: timeout waiting for PONG 1
```
```
2026-10-30 01:03:46:462 [ERROR] [llm.api_mlx] MLX discovery for 'Qwen3.5-2B-4bit' gave up after 310s — surfacing as load failure.
```
```
2026-10-30 01:18:35:233 [ERROR] [menu_llm.mlx] MLX packages are not importable from the installed runtime ~/Library/Application Support/Ergopti/mlx-venv/bin/python (exit=9, cause=import_failed, path=nil): (no output)
```
```
2026-10-30 10:07:38:814 [ERROR] [shortcuts.actions.system] Eventtap 'layer wheel' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400000 (0x8c6674738), enabled=false).
```
```
2026-10-30 10:07:39:827 [ERROR] [shortcuts.actions.system] Eventtap 'Cmd+star' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c3ea72b8), enabled=false).
```
```
2026-10-30 11:37:12:920 [ERROR] [hotstring_editor] Personal hotstrings were saved but the live group reload rolled back.
```
```
2026-10-30 17:06:56:036 [ERROR] [llm.api_ollama] Ollama server executable resolution did not commit (result: Ergopti's own Ollama runtime is not installed); launch remains retryable.
```
```
2026-10-30 20:56:56:292 [ERROR] [fs_dir] Cannot iterate directory '~/perso/ergopti/ergopti_plus/crash_reports' — ...perso/ergopti/static/ergopti_plus/macos/infra/fs_dir.lua:48: cannot open ~/perso/ergopti/ergopti_plus/crash_reports: No such file or directory.
```
```
2026-10-30 00:15:58:965 [ERROR] [menu] Failed to load "AI menu" (ui.menu.menu_llm): ...erso/ergopti/static/ergopti_plus/_shared/lua/timings.lua:85: [timings] missing or non-numeric key [llm].ai_health_watch_ms in constants.toml.
```
```
2026-10-30 00:15:59:702 [ERROR] [llm.core] set_user_profiles(): profiles_table must be a table.
```
```
2026-10-30 00:15:59:702 [ERROR] [menu_state] sync_state_to_modules: feature 'ai' was not fully applied: llm.set_user_profiles did not commit — false.
```
```
2026-10-30 00:15:59:703 [ERROR] [menu_state] Feature 'ai' is OFF for this session because llm.set_user_profiles was refused; config.toml keeps its saved value.
```
```
2026-10-30 01:11:38:665 [ERROR] [llm.api_mlx] Discovery reset POST-probe cancellation retained exact HTTP debt: false.
```
```
2026-10-30 01:11:38:665 [ERROR] [llm.api_mlx] Endpoint reset retained predecessor debt (discovery=false, warmup=true, pgid=true).
```
```
2026-10-30 01:11:38:665 [ERROR] [menu_llm.mlx] Server settlement refused MLX endpoint reset: false.
```
```
2026-10-30 01:18:41:070 [ERROR] [menu_llm.mlx] MLX server for ‘Qwen3.5-2B’ crashed — giving up. Reason: 01:18:41 [MLX-SERVER] ModuleNotFoundError: No module named 'transformers.models.auto'
```
```
2026-10-30 01:18:41:070 [ERROR] [menu_llm.mlx] MLX crash for ‘Qwen3.5-2B’ — last 15 line(s) from MLX server stdout (full trace in ~/perso/ergopti/ergopti_plus/ErgoptiPlus_2026-10-30.log):
```
```
2026-10-30 01:18:41:073 [ERROR] [startup_ctrl] Disabling LLM (requirements check failed: server_start_failed).
```
```
2026-10-30 10:07:38:814 [ERROR] [shortcuts.actions.system] Eventtap 'tap keys' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c666f538), enabled=false).
```
```
2026-10-30 10:07:38:814 [ERROR] [shortcuts.actions.system] Eventtap 'Cmd+star' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c666fbb8), enabled=false).
```
```
2026-10-30 10:07:38:814 [ERROR] [shortcuts.actions.system] Eventtap 'selection wrapping' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c666ffb8), enabled=false).
```
```
2026-10-30 10:07:39:829 [ERROR] [shortcuts.actions.system] Eventtap 'tap keys' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c6610eb8), enabled=false).
```
```
2026-10-30 10:07:42:832 [ERROR] [shortcuts.actions.system] Eventtap 'Cmd+star' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c2ff1838), enabled=false).
```
```
2026-10-30 10:07:42:836 [ERROR] [shortcuts.actions.system] Eventtap 'layer wheel' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400000 (0x8c2a29838), enabled=false).
```
```
2026-10-30 10:07:42:836 [ERROR] [shortcuts.actions.system] Eventtap 'tap keys' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c2a296b8), enabled=false).
```
```
2026-10-30 10:07:42:837 [ERROR] [shortcuts.actions.system] Eventtap 'selection wrapping' activation did not commit (start=hs.eventtap: Eventtap Mask: 0x400 (0x8c2a29d38), enabled=false).
```
```
2026-10-30 10:10:43:827 [ERROR] [karabiner] Remap guardian status is 'unavailable': the background helper is not registered, so tap-holds and remaps stay inert; ~/Library/Logs/ergopti_plus/launcher.log names the registration cause.
```
```
2026-10-30 10:15:30:849 [ERROR] [shortcuts.actions.screenshot_save] Screenshot capture failed: screencapture exited with code 0 but produced no image.
```
```
2026-10-30 12:09:11:851 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=1 (no signal, path=native_runtime_pty); output received: streamed stdout=253 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 5 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract | […
```
```
2026-10-30 12:09:11:851 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=1) — [OLLAMA-DEPS] ERROR: stage python_download ended with exit 1.
```
```
2026-10-30 12:09:11:872 [ERROR] [model_selector_page] The ollama runtime install from the model selector page failed.
```
```
2026-10-30 13:44:59:856 [ERROR] [ollama_deps] Ollama bootstrap ended with exit=78 (no signal, path=native_runtime_pty); output received: streamed stdout=463 stderr=0 bytes, final stdout=0 stderr=0 bytes; last 10 line(s): [OLLAMA-DEPS] stage: python_bootstrap | [NATIVE-BOOTSTRAP] stage: uv_extract |…
```
```
2026-10-30 13:44:59:856 [ERROR] [ollama_deps] Ollama bootstrap failed (exit=78) — Cette app de développement n'a pas encore construit son Ollama épinglé depuis les sources du clone : rien n'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les outils Xc…
```
```
2026-10-30 16:29:57:670 [ERROR] [llm.api_ollama] Ollama server executable resolution did not commit (result: managed runtime metadata is pending); launch remains retryable.
```
```
2026-10-30 20:52:44:430 [ERROR] [keystats.log_manager] Ingest batch rolled back: cannot commit ingest transaction: database is locked.
```
```
2026-10-30 00:16:22:594 [WARNING] [HotPath] Slow preview.rebuild: 5.45 ms own, 5.45 ms total, parent keydown (0 similar since the last line).
```
```
2026-10-30 10:16:05:745 [WARNING] [HotPath] Slow keydown: 5.35 ms own, 5.35 ms total, parent none (0 similar since the last line).
```
```
2026-10-30 00:19:05:563 [WARNING] [HotPath] Slow hotstring.expand: 6.86 ms own, 6.86 ms total, parent hotstring.match (0 similar since the last line).
```
```
2026-10-30 13:52:08:328 [WARNING] [adapters.hotkey_registrar] bind(): the OS refused 'Ctrl+.' — nil.
```
```
2026-10-30 13:52:08:328 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (the registrar or macOS refused the registration); the other shortcuts stay active and it is retried.
```
```
2026-10-30 13:42:55:257 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```
```
2026-10-30 13:52:05:792 [WARNING] [shortcuts.keyboard_shortcuts] Shortcut Ctrl+. (slot 'secondary_period') could not be registered (key '.' is not in the active keyboard layout); the other shortcuts stay active and it is retried.
```
```
2026-10-30 00:19:09:642 [WARNING] [key_event_health] A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream; session totals: 12 key-down(s), 13 key-up(s), 1 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 chara…
```
```
2026-10-30 00:53:56:018 [WARNING] [preferences] Slow preferences save 2086 ms (prepare=1268 write=817 ms; operations=293; prepare: snapshot=7 decode=0 models=0 sparse=287 wrap=1 rows=0 gestures=1 llm=1 shortcuts=1 hotstrings=965 ms; proposed=295; metadata_commands=4 in 189 ms; lua_heap=53->33 MB).
```
```
2026-10-30 01:08:56:498 [WARNING] [keymap.utils] Slow ignored-window probe 501 ms (watchers=0 focused_window=500 ms).
```
```
2026-10-30 01:18:03:152 [WARNING] [keymap.utils] Slow ignored-window probe 506 ms (watchers=0 focused_window=4 application=0 app_name=0 title=0 context_watchers=0 secure_field=0 destination=501 ms).
```
```
2026-10-30 16:29:57:670 [WARNING] [download_window] Progress UI flipped to error state: Impossible de lancer le démon Ollama.
```
```
2026-10-30 01:08:55:558 [WARNING] [llm.api_mlx] MLX endpoint discovery: all candidates returned 404 — model may still be loading. Will retry on next warmup.
```
```
2026-10-30 10:28:33:121 [WARNING] [key_event_health] A character key was pressed again while its previous key-down had no key-up: that key-up was lost before the keymap taps; session totals: 1470 key-down(s), 1471 key-up(s), 2 key-up(s) without key-down, 1 key-down(s) without key-up, 0 key(s) stuck…
```
```
2026-10-30 00:54:14:761 [WARNING] [key_event_health] Key events reached the keymap taps 250 ms or more late: the main thread held them; session totals: 257 key-down(s), 260 key-up(s), 3 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 character key(s) held 500 …
```
```
2026-10-30 00:58:28:019 [WARNING] [keymap.utils] Ignored-window prewarm incomplete (probe stage focused_window, TTL refresh armed); tracking remains fail-closed.
```
```
2026-10-30 00:58:28:020 [WARNING] [keymap] Ignored-window watcher preparation incomplete; tracking remains fail-closed: false.
```
```
2026-10-30 01:01:42:389 [WARNING] [llm.api_mlx] Endpoint discovery: gave up waiting for MLX server after 185.9s. Falling back to default routes; warmup will keep retrying.
```
```
2026-10-30 01:08:55:554 [WARNING] [llm.api_mlx] Endpoint discovery: expected model 'Qwen3.5-2B-4bit' not visible in /v1/models cache list — POST may 404 if mlx_lm cannot resolve it.
```
```
2026-10-30 10:06:50:067 [WARNING] [shortcuts.actions.screen_capture] Clipboard screenshot refused: Screen Recording is not granted to the ErgoptiPlus runtime.
```
```
2026-10-30 10:07:38:814 [WARNING] [shortcuts.bindings] Hotkey 'tap_keys' could not be registered (its factory returned no hotkey); the other shortcuts stay active and it is retried.
```
```
2026-10-30 00:19:08:174 [WARNING] [HotPath] Slow tooltip.show_predictions: 13.36 ms own, 13.36 ms total, parent none (0 similar since the last line).
```
```
2026-10-30 00:53:58:065 [WARNING] [keystats] Keystats event tap found disabled — restarting.
```
```
2026-10-30 00:54:06:072 [WARNING] [keystats.log_manager] Slow ingest tick 513 ms (drain=0 foreign=0 outbox=278 read=1 build=0 apply=1 commit=1 append=229 notify=0 ms; append: lock=0 journal=0 prepare=0 publish=2 write=154 clear=8 settle=62 release=0 ms; metadata_commands=0 in 0 ms; entries=1 statem…
```
```
2026-10-30 00:56:02:438 [WARNING] [menu_llm.mlx] MLX model Qwen3.5-2B not detected as installed. Starting download flow…
```
```
2026-10-30 01:16:40:451 [WARNING] [adapters.http_client] Request timed out after 30000ms.
```
```
2026-10-30 10:16:29:428 [WARNING] [HotPath] Slow hotstring.match: 12.21 ms own, 21.70 ms total, parent keydown (0 similar since the last line).
```
```
2026-10-30 00:58:10:318 [WARNING] [karabiner.lease] Karabiner lease 1d5543ecc55c40d5b82c8d50b1bea79f: task output stayed unread for 120.0 s after the PONG 1 deadline.
```
```
2026-10-30 00:58:10:319 [WARNING] [karabiner.lease] Karabiner lease 1d5543ecc55c40d5b82c8d50b1bea79f waited 124.50 s for PONG 1; the deadline timer fired 0.00 s late.
```
```
2026-10-30 00:58:10:319 [WARNING] [key_event_health] A Karabiner lease failed (pong); session totals: 2 key-down(s), 2 key-up(s), 0 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 character key(s) held 500 ms or more (0 across a rule switch), 0 key-down(s) and…
```
```
2026-10-30 00:58:10:319 [WARNING] [karabiner.lease] Starting detached fallback revoker for lease 1d5543ecc55c40d5b82c8d50b1bea79f (timeout waiting for PONG 1).
```
```
2026-10-30 00:58:10:990 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
```
```
2026-10-30 00:58:19:875 [WARNING] [runtime] An hs.timer.new callback (...gopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:263) held the main thread for 2072 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: shell.ls=55.8 ms, shell.cp=39.7…
```
```
2026-10-30 01:03:46:470 [WARNING] [llm.core] warmup_model: backend warmup did not commit: false
```
```
2026-10-30 01:16:14:982 [WARNING] [llm.api_mlx] PGID pending timeout (15s) — unblocking zombie kills.
```
```
2026-10-30 01:18:35:234 [WARNING] [mlx_deps] MLX runtime invalidated; the next MLX selection repairs ~/Library/Application Support/Ergopti/mlx-venv.
```
```
2026-10-30 01:18:35:235 [WARNING] [startup_ctrl] Startup MLX backup check failed for Qwen3.5-2B.
```
```
2026-10-30 01:18:35:238 [WARNING] [menu_llm.mlx_repair_offer] Offering the MLX repair action for a import_failed failure.
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "~/Library/Application Support/Ergopti/mlx-venv/lib/python3.13/site-packages/transformers/utils/import_utils.py", line 2794, in _get_module
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "<frozen importlib._bootstrap>", line 1387, in _gcd_import
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "<frozen importlib._bootstrap>", line 1360, in _find_and_load
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "<frozen importlib._bootstrap>", line 1310, in _find_and_load_unlocked
```
```
2026-10-30 03:13:08:919 [WARNING] [karabiner.lease] Karabiner lease 41f76e8f91874db28cbdae98a3409773 heartbeat 72 had no clean local CLI transport.
```
```
2026-10-30 13:52:51:338 [WARNING] [shortcuts.keyboard_shortcuts] Some shortcuts are still unregistered after 4 retries; the next keyboard-layout change retries them.
```
```
2026-10-30 18:38:20:258 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: NativeHTTPError at native_http.py:490 _read_exact, from managed_ollama_serve.py:470 discover, reason=protocol, stage=native_first_frame, native_child_status=6…
```
```
2026-10-30 00:00:00:313 [WARNING] [llm.streaming_handler] ↑ "Watchdog triggered: stream produced no visible result for 12s." repeated 1 more time between 2026-10-29 23:50:59:228 and 2026-10-29 23:50:59:228.
```
```
2026-10-30 00:15:59:739 [WARNING] [menu] Saved preferences applied except 1 refused step(s), isolated to their feature.
```
```
2026-10-30 00:16:02:158 [WARNING] [builder] LLM handler missing or incomplete — AI component ignored.
```
```
2026-10-30 00:23:41:630 [WARNING] [HotPath] Slow hotstring.expand: 11.79 ms own, 11.79 ms total, parent none (0 similar since the last line).
```
```
2026-10-30 00:54:14:761 [WARNING] [keymap] macOS disabled the loopbackKeyUp event tap — re-enabling.
```
```
2026-10-30 00:58:17:639 [WARNING] [startup_ctrl] Disabling LLM: the mlx backend (startup_model_download_declined: Qwen3.5-2B).
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER] Traceback (most recent call last):
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "~/Library/Application Support/Ergopti/mlx-venv/lib/python3.13/site-packages/transformers/utils/import_utils.py", line 2560, in __getattr__
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "/Library/Frameworks/Python.framework/Versions/3.13/lib/python3.13/importlib/__init__.py", line 88, in import_module
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]     return _bootstrap._gcd_import(name[level:], package, level)
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]            ~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER]   File "<frozen importlib._bootstrap>", line 488, in _call_with_frames_removed
```
```
2026-10-30 01:18:41:070 [WARNING] [menu_llm.mlx]   | 01:18:41 [MLX-SERVER] ModuleNotFoundError: No module named 'transformers.models.auto'
```
```
2026-10-30 01:18:43:318 [WARNING] [runtime] An hs.timer.new callback (...gopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:263) held the main thread for 2144 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: shell.ls=58.0 ms, shell.ls=46.9…
```
```
2026-10-30 10:07:36:253 [WARNING] [keystats.context_tracker] Accessibility observer setup failed: .../ergopti_plus/macos/modules/keystats/context_tracker.lua:749: The accessibility API is disabled
```
```
2026-10-30 10:10:21:380 [WARNING] [runtime] An hs.timer.new callback (...i/static/ergopti_plus/macos/infra/accessibility_wait.lua:139) held the main thread for 1595 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=355.9 ms, boot.stage…
```
```
2026-10-30 10:10:43:816 [WARNING] [runtime] An hs.timer.new callback (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2123) held the main thread for 17260 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 52->342 MB.
```
```
2026-10-30 10:10:43:833 [WARNING] [karabiner] Karabiner regeneration remains fail-closed after guardian status 'unavailable' (regeneration-preflight).
```
```
2026-10-30 10:12:24:991 [WARNING] [menu_llm.runtime_offer] The mlx runtime is not installed; its notice offers the install.
```
```
2026-10-30 10:12:26:969 [WARNING] [mlx_deps] MLX runtime is not installed; no bootstrap without an MLX backend selection.
```
```
2026-10-30 10:12:27:150 [WARNING] [startup_ctrl] Disabling LLM: the mlx backend (startup_runtime_not_installed).
```
```
2026-10-30 10:14:12:452 [WARNING] [runtime] An hs.timer.new callback (...i/static/ergopti_plus/macos/infra/accessibility_wait.lua:139) held the main thread for 1312 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Phases inside the hold: boot.stage=228.5 ms, boot.stage…
```
```
2026-10-30 10:15:07:604 [WARNING] [key_event_health] A character key stayed down 3.8 s with no further event: its key-up was lost before the keymap taps; session totals: 3 key-down(s), 2 key-up(s), 0 key-up(s) without key-down, 0 key-down(s) without key-up, 1 key(s) stuck over 3.0 s, 0 character ke…
```
```
2026-10-30 11:44:09:255 [WARNING] [key_event_health] A key-up reached the keymap taps with no key-down before it: that key-down was lost or consumed upstream (2 times); session totals: 3 key-down(s), 2 key-up(s), 2 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s,…
```
```
2026-10-30 11:44:15:252 [WARNING] [key_event_health] A character key stayed down 5.1 s with no further event: its key-up was lost before the keymap taps (2 times); session totals: 10 key-down(s), 10 key-up(s), 2 key-up(s) without key-down, 0 key-down(s) without key-up, 2 key(s) stuck over 3.0 s, 0 …
```
```
2026-10-30 11:55:34:625 [WARNING] [karabiner.lease] Starting detached fallback revoker for lease 9b5e0fe253c44c43afd493904017df2b (watchdog completion).
```
```
2026-10-30 12:09:11:872 [WARNING] [download_window] Progress UI flipped to error state: [OLLAMA-DEPS] ERROR: stage python_download ended with exit 1.
```
```
2026-10-30 13:44:59:856 [WARNING] [download_window] Progress UI flipped to error state: Cette app de développement n'a pas encore construit son Ollama épinglé depuis les sources du clone : rien n'a été installé. Relancez tools/dev/run-macos-dev-app.sh et lisez la raison qu'il affiche (Go et les out…
```
```
2026-10-30 13:45:16:293 [WARNING] [menu_watchers] Menu source reload held while the developer field run runs (3 file(s): ~/perso/ergopti/static/ergopti_plus/macos/modules/keymap/expander.lua, ~/perso/ergopti/static/ergopti_plus/macos/modules/keymap/init.lua, ~/perso/ergopti/static/ergopti_plus/maco…
```
```
2026-10-30 13:52:51:338 [WARNING] [logger] ↑ 1 identical line suppressed
```
```
2026-10-30 15:02:36:076 [WARNING] [field_run] A stale field run request was left by an earlier session; removed.
```
```
2026-10-30 17:19:31:251 [WARNING] [managed_ollama_hint] Owned Ollama runtime metadata refused (exit=78): refused: TypeError at ollama_hint_metadata.py:51 read_regular
```
```
2026-10-30 17:24:44:375 [WARNING] [runtime] An hs.timer.new callback (...opti/static/ergopti_plus/macos/modules/keystats/init.lua:2321) held the main thread for 2014 ms; event taps, the Karabiner lease heartbeat and typed keys waited meanwhile. Lua heap 30->30 MB.
```
```
2026-10-30 18:26:39:407 [WARNING] [managed_ollama_daemon] Managed Ollama daemon exited (status=78): Managed Ollama daemon admission refused: NativeHTTPError at native_http.py:490 _read_exact.
```

</details>

## Performance

Budgets are the values the code declares (source named per row); a measure without one says so. Hot-path lines are only written for a slow occurrence, so their p50 is the median of the slow ones; the phase summaries and the Windows latency lines give the whole distribution (mean and max).

### Boot

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| boot.total | 42 | 1649 | 2834 | 3033 | 32634 | no budget declared | — |
| boot.stage:Accessibility permission | 42 | 1 | 14.9 | 1291 | 30018 | no budget declared | — |
| boot.cpu | 42 | 1190 | 1448 | 1252 | 2208 | no budget declared | — |
| boot.stage:Config-dependent module requires | 47 | 402 | 701 | 422 | 786 | no budget declared | — |
| boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler) | 42 | 189 | 240 | 196 | 356 | no budget declared | — |
| boot.stage:Shortcuts pre-start | 42 | 174 | 297 | 180 | 335 | no budget declared | — |
| boot.stage:Hotstring groups registered (personal + dynamic + common) | 42 | 209 | 241 | 213 | 278 | no budget declared | — |
| boot.stage:Config schema migration | 47 | 47 | 93.1 | 55.47 | 219 | no budget declared | — |
| boot.stage:UI: karabiner.init | 42 | 84.3 | 109 | 87.91 | 127 | no budget declared | — |
| boot.stage:Keymap engine started | 42 | 42.2 | 94.1 | 48.69 | 122 | no budget declared | — |
| boot.stage:TOML discovery + ordering | 42 | 28.6 | 53.2 | 32.44 | 87.7 | no budget declared | — |
| boot.stage:Path: native asynchronous logger transport committed | 48 | 9.1 | 17.4 | 11.23 | 68.6 | no budget declared | — |
| boot.stage:First-launch guard (onboarding check) | 47 | 5.9 | 12.6 | 7.1 | 27.9 | no budget declared | — |
| boot.stage:File watchers armed | 42 | 9.1 | 17.1 | 10.61 | 27 | no budget declared | — |
| boot.stage:TOML hotstring cache wired | 48 | 1.8 | 4.8 | 2.59 | 25.2 | no budget declared | — |
| boot.stage:Script control engine started (panic-button eventtap) | 42 | 0.6 | 2.4 | 1.27 | 21.8 | no budget declared | — |
| boot.stage:Path: log file open (retention purge deferred) | 53 | 1.9 | 9.3 | 2.97 | 18 | no budget declared | — |
| boot.stage:LLM backend bootstrap | 42 | 4.6 | 9.5 | 5.49 | 15.2 | no budget declared | — |
| boot.stage:Factory-reset recovery reconciled | 48 | 2.1 | 4.8 | 2.65 | 11.4 | no budget declared | — |
| boot.stage:Final mapping sort + tail-index rebuild | 42 | 5.5 | 6.5 | 5.69 | 8.6 | no budget declared | — |
| boot.stage:MLX server cleanup started asynchronously | 42 | 5.6 | 7.6 | 5.84 | 8.3 | no budget declared | — |
| boot.stage:Boot complete (post-init deferrals scheduled) | 42 | 2.4 | 3.1 | 2.59 | 5.5 | no budget declared | — |
| boot.stage:Path: runtime error capture installed | 48 | 0.3 | 2.3 | 0.55 | 3.9 | no budget declared | — |
| boot.stage:UI: menu ready | 42 | 0.3 | 0.7 | 0.34 | 0.9 | no budget declared | — |

Worst occurrences:

- boot.total: 32634 ms at 2026-10-30 10:10:20:945, 25794 ms at 2026-10-30 10:14:12:087, 2834 ms at 2026-10-30 11:44:06:593
- boot.stage:Accessibility permission: 30018 ms at 2026-10-30 10:10:19:786, 24017 ms at 2026-10-30 10:14:11:142, 14.9 ms at 2026-10-30 01:09:31:798
- boot.cpu: 2208 ms at 2026-10-30 10:10:20:946, 1877 ms at 2026-10-30 10:14:12:087, 1448 ms at 2026-10-30 11:44:06:593
- boot.stage:Config-dependent module requires: 786 ms at 2026-10-30 11:37:27:268, 754 ms at 2026-10-30 11:44:05:514, 701 ms at 2026-10-30 11:38:01:393
- boot.stage:UI: menu.start (menubar + state sync + engines + LLM handler): 356 ms at 2026-10-30 10:10:20:924, 244 ms at 2026-10-30 11:44:06:580, 240 ms at 2026-10-30 01:14:28:548
- boot.stage:Shortcuts pre-start: 335 ms at 2026-10-30 11:37:27:697, 325 ms at 2026-10-30 01:09:32:128, 297 ms at 2026-10-30 11:44:05:886
- boot.stage:Hotstring groups registered (personal + dynamic + common): 278 ms at 2026-10-30 11:38:02:029, 255 ms at 2026-10-30 11:37:28:045, 241 ms at 2026-10-30 11:44:06:203
- boot.stage:Config schema migration: 219 ms at 2026-10-30 16:27:54:977, 99.7 ms at 2026-10-30 00:06:41:594, 93.1 ms at 2026-10-30 00:01:06:499
- boot.stage:UI: karabiner.init: 127 ms at 2026-10-30 10:10:20:568, 112 ms at 2026-10-30 10:14:11:840, 109 ms at 2026-10-30 00:55:59:809
- boot.stage:Keymap engine started: 122 ms at 2026-10-30 10:10:20:440, 118 ms at 2026-10-30 00:55:59:696, 94.1 ms at 2026-10-30 10:14:11:728
- boot.stage:TOML discovery + ordering: 87.7 ms at 2026-10-30 11:38:01:751, 57.4 ms at 2026-10-30 11:37:27:789, 53.2 ms at 2026-10-30 11:44:05:961
- boot.stage:Path: native asynchronous logger transport committed: 68.6 ms at 2026-10-30 10:09:49:203, 24.5 ms at 2026-10-30 11:38:00:659, 17.4 ms at 2026-10-30 11:44:04:741

### Reload

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| reload.total | 31 | 2539 | 459295 | 113142 | 2878328 | no budget declared | — |

Worst occurrences:

- reload.total: 2878328 ms at 2026-10-30 21:06:02:293, 459295 ms at 2026-10-30 14:54:56:452, 25853 ms at 2026-10-30 11:55:56:130

### Menus

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:menu.rebuild | 195 | — | — | 304 | 942 | no budget declared | — |
| menu.rebuild | 64 | 285 | 420 | 309 | 889 | no budget declared | — |
| phase:menu_item.keyboard_layout | 195 | — | — | 107 | 755 | no budget declared | — |
| menu.submenu:hotstrings | 53 | 33.9 | 47.6 | 43.69 | 558 | no budget declared | — |
| phase:menu_item.hotstrings | 195 | — | — | 33.02 | 557 | no budget declared | — |
| phase:menu_item.llm | 195 | — | — | 34.69 | 533 | no budget declared | — |
| menu.submenu:keyboard_layout | 64 | 67.4 | 205 | 89.27 | 423 | no budget declared | — |
| phase:menu_item.shortcuts | 195 | — | — | 51.15 | 380 | no budget declared | — |
| phase:menu_item.metrics | 195 | — | — | 8.63 | 82.73 | no budget declared | — |
| menu.submenu:metrics | 15 | 30.4 | 82.7 | 34.45 | 82.7 | no budget declared | — |
| menu.submenu:shortcuts | 64 | 47.3 | 59.8 | 47.29 | 63 | no budget declared | — |
| phase:menu_item.gestures | 195 | — | — | 43.2 | 61.12 | no budget declared | — |
| menu.app_exclusions | 61 | 1 | 18.2 | 6.58 | 59.3 | no budget declared | — |
| menu.submenu:gestures | 63 | 40.9 | 52.9 | 41.97 | 59.3 | no budget declared | — |
| menu.submenu:llm | 59 | 30.7 | 55.1 | 33.04 | 57.4 | no budget declared | — |
| menu.submenu:about | 2 | 20.5 | 37.1 | 28.8 | 37.1 | no budget declared | — |
| phase:menu_item.about | 195 | — | — | 7.23 | 37.1 | no budget declared | — |
| phase:menu_item.debug | 195 | — | — | 4.2 | 20.51 | no budget declared | — |
| phase:menu_item.configuration | 195 | — | — | 2.21 | 10.34 | no budget declared | — |
| phase:menu_item.tap_holds | 195 | — | — | 1.13 | 9.36 | no budget declared | — |
| phase:menu_item.apps | 195 | — | — | 0.19 | 3.46 | no budget declared | — |
| phase:menu_item.language | 195 | — | — | 0.04 | 0.56 | no budget declared | — |
| phase:menu_item.reload | 195 | — | — | 0.01 | 0.25 | no budget declared | — |
| phase:menu_item.quit | 195 | — | — | 0.01 | 0.02 | no budget declared | — |

Worst occurrences:

- menu.rebuild: 889 ms at 2026-10-30 17:08:12:752, 612 ms at 2026-10-30 20:57:48:776, 422 ms at 2026-10-30 17:39:43:684
- menu.submenu:hotstrings: 558 ms at 2026-10-30 17:08:12:752, 48.4 ms at 2026-10-30 17:22:07:731, 47.6 ms at 2026-10-30 21:58:46:052
- menu.submenu:keyboard_layout: 423 ms at 2026-10-30 20:57:48:776, 221 ms at 2026-10-30 17:39:43:684, 206 ms at 2026-10-30 17:22:07:731
- menu.submenu:metrics: 82.7 ms at 2026-10-30 11:44:09:217, 42.4 ms at 2026-10-30 10:15:27:035, 36.2 ms at 2026-10-30 00:16:28:181
- menu.submenu:shortcuts: 63 ms at 2026-10-30 13:48:44:913, 60.3 ms at 2026-10-30 11:37:31:082, 60.2 ms at 2026-10-30 17:05:14:063
- menu.app_exclusions: 59.3 ms at 2026-10-30 11:44:09:067, 21.5 ms at 2026-10-30 00:16:28:078, 21.1 ms at 2026-10-30 01:09:35:057
- menu.submenu:gestures: 59.3 ms at 2026-10-30 19:37:57:710, 58.8 ms at 2026-10-30 00:16:02:225, 56.8 ms at 2026-10-30 13:48:39:637
- menu.submenu:llm: 57.4 ms at 2026-10-30 01:16:08:795, 55.8 ms at 2026-10-30 11:44:09:217, 55.1 ms at 2026-10-30 13:48:39:637
- menu.submenu:about: 37.1 ms at 2026-10-30 11:38:05:292, 20.5 ms at 2026-10-30 00:16:02:225

### Main thread

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| main_thread.hold | 146 | 389 | 924 | 588 | 17260 | 250 ms (static/ergopti_plus/macos/infra/logger.lua) | ❌ over (146) |

Worst occurrences:

- main_thread.hold: 17260 ms at 2026-10-30 10:10:43:816 (...atic/ergopti_plus/macos/modules/keystats/log_manager.lua:2123), 2144 ms at 2026-10-30 01:18:43:318 (...gopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:263), 2072 ms at 2026-10-30 00:58:19:875 (...gopti_plus/macos/ui/menu/menu_llm/startup_controller.lua:263)

### Hotstrings

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:hotstring.expand | 17 | 6.71 | 15.35 | 7.78 | 15.35 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (17) |
| hotpath:hotstring.match | 3 | 8.44 | 12.21 | 8.71 | 12.21 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (3) |

Worst occurrences:

- hotpath:hotstring.expand: 15.35 ms at 2026-10-30 11:58:29:509, 12.08 ms at 2026-10-30 00:55:32:898, 11.79 ms at 2026-10-30 00:23:41:630
- hotpath:hotstring.match: 12.21 ms at 2026-10-30 10:16:29:428, 8.44 ms at 2026-10-30 10:21:51:079, 5.49 ms at 2026-10-30 11:38:11:156

### Tooltip and prediction

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:tooltip.show_predictions | 3 | 14.73 | 15.59 | 14.56 | 15.59 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (3) |
| hotpath:preview.rebuild | 87 | 5.6 | 11.21 | 6.31 | 12.56 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (87) |

Worst occurrences:

- hotpath:tooltip.show_predictions: 15.59 ms at 2026-10-30 00:45:24:830, 14.73 ms at 2026-10-30 00:23:39:740, 13.36 ms at 2026-10-30 00:19:08:174
- hotpath:preview.rebuild: 12.56 ms at 2026-10-30 12:02:20:504, 11.79 ms at 2026-10-30 01:20:04:549, 11.58 ms at 2026-10-30 11:44:31:411

### LLM requests

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| llm.stream | 1 | 3052 | 3052 | 3052 | 3052 | no budget declared | — |
| llm.ttft | 3 | 1573 | 1582 | 1546 | 1582 | no budget declared | — |
| llm.request:remote | 3 | 737 | 1479 | 974 | 1479 | no budget declared | — |

Worst occurrences:

- llm.ttft: 1582 ms at 2026-10-30 00:23:39:726, 1573 ms at 2026-10-30 00:45:24:815, 1484 ms at 2026-10-30 00:19:08:160
- llm.request:remote: 1479 ms at 2026-10-30 00:19:08:159, 737 ms at 2026-10-30 00:45:24:813, 706 ms at 2026-10-30 00:23:39:724

### Storage

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| keystats.ingest | 3 | 579 | 17260 | 6117 | 17260 | 500 ms (static/ergopti_plus/macos/modules/keystats/ingest_trace.lua) | ❌ over (3) |
| preferences.save | 10 | 2038 | 2141 | 2034 | 2141 | 250 ms (static/ergopti_plus/macos/infra/preferences.lua) | ❌ over (10) |
| healthcheck.sync | 30 | 157 | 200 | 155 | 230 | 5 ms (stated in the log line) | ❌ over (30) |

Worst occurrences:

- keystats.ingest: 17260 ms at 2026-10-30 10:10:43:816, 579 ms at 2026-10-30 10:47:30:590, 513 ms at 2026-10-30 00:54:06:072
- preferences.save: 2141 ms at 2026-10-30 01:18:43:317, 2126 ms at 2026-10-30 01:19:50:467, 2119 ms at 2026-10-30 00:54:13:641
- healthcheck.sync: 230 ms at 2026-10-30 01:13:33:243, 200 ms at 2026-10-30 18:24:40:883, 186 ms at 2026-10-30 12:09:12:380

### Input

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| input.late_key_event | 13 | 302 | 2050 | 592 | 2050 | 250 ms (stated in the log line) | ❌ over (13) |

Worst occurrences:

- input.late_key_event: 2050 ms at 2026-10-30 00:54:14:761, 1341 ms at 2026-10-30 10:15:07:604, 1341 ms at 2026-10-30 10:15:07:604

### Other hot-path segments

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| hotpath:keydown | 18 | 5.35 | 12.5 | 6.11 | 12.5 | 5 ms (static/ergopti_plus/_shared/modules/timings/constants.toml) | ❌ over (18) |

Worst occurrences:

- hotpath:keydown: 12.5 ms at 2026-10-30 10:37:57:906, 7.72 ms at 2026-10-30 11:38:15:668, 6.86 ms at 2026-10-30 10:22:11:243

### Phase summaries

| Measure | Count | p50 | p95 | Mean | Max | Budget | Verdict |
|---|---|---|---|---|---|---|---|
| phase:process.ErgoptiPlus | 300 | — | — | 1340 | 225280 | no budget declared | — |
| phase:process.cat | 4 | — | — | 52549 | 120002 | no budget declared | — |
| phase:process.brew | 14 | — | — | 2637 | 20018 | no budget declared | — |
| phase:process.sfltool | 12 | — | — | 20012 | 20017 | no budget declared | — |
| phase:process.screencapture | 7 | — | — | 3414 | 4913 | no budget declared | — |
| phase:process.open | 3 | — | — | 1491 | 3549 | no budget declared | — |
| phase:process.python3 | 62 | — | — | 365 | 3505 | no budget declared | — |
| phase:process.sqlite3 | 2 | — | — | 1923 | 3208 | no budget declared | — |
| phase:process.defaults | 16365 | — | — | 23.53 | 2037 | no budget declared | — |
| phase:process.bash | 8 | — | — | 346 | 2011 | no budget declared | — |
| phase:boot.stage | 480 | — | — | 72.83 | 933 | no budget declared | — |
| phase:boot.requires | 320 | — | — | 63.23 | 930 | no budget declared | — |
| phase:process.spctl | 12 | — | — | 556 | 697 | no budget declared | — |
| phase:boot.stage_cpu | 480 | — | — | 50.65 | 430 | no budget declared | — |
| phase:process.pgrep | 40 | — | — | 28.89 | 376 | no budget declared | — |
| phase:process.osascript | 1 | — | — | 346 | 346 | no budget declared | — |
| phase:process.curl | 87 | — | — | 33.71 | 278 | no budget declared | — |
| phase:process.codesign | 18 | — | — | 125 | 220 | no budget declared | — |
| phase:shell.sw_vers | 20 | — | — | 84.17 | 179 | no budget declared | — |
| phase:shell.systemextensionsctl | 20 | — | — | 85 | 169 | no budget declared | — |
| phase:shell.other | 20 | — | — | 99.8 | 167 | no budget declared | — |
| phase:process.sh | 5 | — | — | 91.51 | 160 | no budget declared | — |
| phase:shell.ls | 258 | — | — | 41.62 | 147 | no budget declared | — |
| phase:process.mkdir | 52 | — | — | 47.24 | 133 | no budget declared | — |
| phase:shell.mkdir | 52 | — | — | 47.22 | 133 | no budget declared | — |
| phase:shell.cp | 86 | — | — | 41.78 | 110 | no budget declared | — |
| phase:shell.ioreg | 20 | — | — | 64.02 | 110 | no budget declared | — |
| phase:shell.curl | 9 | — | — | 85.34 | 103 | no budget declared | — |
| phase:shell.find | 20 | — | — | 51.89 | 101 | no budget declared | — |
| phase:process.shortcuts | 24 | — | — | 67.81 | 88.52 | no budget declared | — |
| phase:process.Application | 12 | — | — | 57.78 | 67.05 | no budget declared | — |
| phase:process.grep | 24 | — | — | 25.82 | 54.12 | no budget declared | — |
| phase:process.systemextensionsctl | 12 | — | — | 22.4 | 48.01 | no budget declared | — |
| phase:process.xmllint | 16 | — | — | 9.85 | 44.22 | no budget declared | — |
| phase:hotpath.keydown | 6181 | — | — | 2.6 | 30.29 | no budget declared | — |
| phase:hotpath.preview.rebuild | 4149 | — | — | 2.97 | 28.72 | no budget declared | — |
| phase:preview.total | 4537 | — | — | 2.91 | 28.71 | no budget declared | — |
| phase:hotpath.hotstring.match | 4268 | — | — | 0.47 | 21.7 | no budget declared | — |
| phase:hotstring_load.common_file | 40 | — | — | 10.62 | 20.49 | no budget declared | — |
| phase:process.df | 1 | — | — | 19.54 | 19.54 | no budget declared | — |
| phase:preview.providers | 4537 | — | — | 1.72 | 16.11 | no budget declared | — |
| phase:process.plutil | 28 | — | — | 8.55 | 15.79 | no budget declared | — |
| phase:hotpath.tooltip.show_predictions | 7 | — | — | 11.2 | 15.59 | no budget declared | — |
| phase:hotpath.hotstring.expand | 121 | — | — | 3.8 | 15.35 | no budget declared | — |
| phase:toml.parse | 503 | — | — | 1.38 | 14.5 | no budget declared | — |
| phase:process.launchctl | 12 | — | — | 8.04 | 12.63 | no budget declared | — |
| phase:process.scutil | 12 | — | — | 7.67 | 11.78 | no budget declared | — |
| phase:preview.resolve | 4537 | — | — | 0.25 | 10.22 | no budget declared | — |
| phase:process.ps | 2 | — | — | 6.91 | 7.22 | no budget declared | — |
| phase:process.id | 12 | — | — | 2.3 | 3.03 | no budget declared | — |
| phase:process.sysctl | 1 | — | — | 2.33 | 2.33 | no budget declared | — |

### Counters

- counter:menu.refresh_requested: 243
- counter:runtime.timer_hold_over_1000ms: 2
- counter:runtime.timer_hold_over_250ms: 225

## Lifecycle

| Event | Count | First | Last |
|---|---|---|---|
| start | 54 | 2026-10-30 00:01:05:952 | 2026-10-30 21:53:59:471 |
| stop | 29 | 2026-10-30 00:01:05:361 | 2026-10-30 19:13:35:958 |
| crash | 2 | 2026-10-30 01:18:41:070 | 2026-10-30 01:18:41:070 |
| reload | 31 | 2026-10-30 00:01:04:881 | 2026-10-30 21:06:02:293 |
| sleep_wake | 11 | 2026-10-30 00:41:33:408 | 2026-10-30 20:42:03:269 |
| karabiner_lease_failure | 10 | 2026-10-30 00:58:10:318 | 2026-10-30 01:22:18:503 |
| network_failure | 15 | 2026-10-30 01:16:40:451 | 2026-10-30 21:54:10:639 |
| event_tap_disabled | 3 | 2026-10-30 00:53:58:065 | 2026-10-30 17:24:42:361 |

<details><summary>First lines of each event</summary>

**start**

```
===== 2026-10-30 00:01:05:952 — ErgoptiPlus session opened =====
===== 2026-10-30 00:01:22:499 — ErgoptiPlus session opened =====
===== 2026-10-30 00:02:09:360 — ErgoptiPlus session opened =====
===== 2026-10-30 00:02:22:652 — ErgoptiPlus session opened =====
===== 2026-10-30 00:06:41:007 — ErgoptiPlus session opened =====
===== 2026-10-30 00:15:58:546 — ErgoptiPlus session opened =====
===== 2026-10-30 00:16:24:591 — ErgoptiPlus session opened =====
===== 2026-10-30 00:17:32:044 — ErgoptiPlus session opened =====
===== 2026-10-30 00:17:48:182 — ErgoptiPlus session opened =====
===== 2026-10-30 00:17:48:641 — ErgoptiPlus session opened =====
```

**stop**

```
2026-10-30 00:01:05:361 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:01:21:890 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:02:08:831 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:02:22:146 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:06:40:433 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:15:57:916 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:16:24:085 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:17:31:441 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:17:48:128 [INFO] [init] Hammerspoon local teardown started (reload).
2026-10-30 00:18:28:200 [INFO] [init] Hammerspoon local teardown started (reload).
```

**crash**

```
2026-10-30 01:18:41:070 [ERROR] [menu_llm.mlx] MLX server for ‘Qwen3.5-2B’ crashed — giving up. Reason: 01:18:41 [MLX-SERVER] ModuleNotFoundError: No module named 'transformers.models.auto'
2026-10-30 01:18:41:070 [ERROR] [menu_llm.mlx] MLX crash for ‘Qwen3.5-2B’ — last 15 line(s) from MLX server stdout (full trace in ~/perso/ergopti/ergopti_plus/ErgoptiPlus_2026-10-30.log):
```

**reload**

```
2026-10-30 00:01:04:881 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-30 00:01:21:412 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-30 00:02:08:358 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-30 00:02:21:649 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-30 00:06:39:959 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-30 00:15:57:438 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-30 00:16:23:602 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: watcher).
2026-10-30 00:17:30:966 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-30 00:17:47:663 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
2026-10-30 00:18:27:724 [INFO] [infra.termination_coordinator] Controlled reload requested (reason: hammerspoon_reload).
```

**sleep_wake**

```
2026-10-30 00:41:33:408 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-30 09:57:29:359 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-30 10:07:37:886 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-10-30 11:15:33:108 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-10-30 13:07:04:250 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-30 13:41:48:229 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-30 14:03:30:955 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
2026-10-30 15:18:23:608 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-30 18:23:27:711 [INFO] [gestures] Wake-from-sleep detected (event=0) — recycling watchers
2026-10-30 19:39:37:857 [INFO] [gestures] Wake-from-sleep detected (event=11) — recycling watchers
```

**karabiner_lease_failure**

```
2026-10-30 00:58:10:318 [WARNING] [karabiner.lease] Karabiner lease 1d5543ecc55c40d5b82c8d50b1bea79f: task output stayed unread for 120.0 s after the PONG 1 deadline.
2026-10-30 00:58:10:319 [WARNING] [karabiner.lease] Karabiner lease 1d5543ecc55c40d5b82c8d50b1bea79f waited 124.50 s for PONG 1; the deadline timer fired 0.00 s late.
2026-10-30 00:58:10:319 [ERROR] [karabiner.lease] Karabiner lease 1d5543ecc55c40d5b82c8d50b1bea79f failed; fencing before publishing failure: timeout waiting for PONG 1
2026-10-30 00:58:10:319 [WARNING] [key_event_health] A Karabiner lease failed (pong); session totals: 2 key-down(s), 2 key-up(s), 0 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 character key(s) held 500 ms or more (0 across a rule switch), 0 key-down(s) and…
2026-10-30 00:58:10:990 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
2026-10-30 01:22:17:829 [WARNING] [karabiner.lease] Karabiner lease 554cdd2c504645b99d32c4549c501c37: task output stayed unread for 120.0 s after the PONG 20 deadline.
2026-10-30 01:22:17:829 [WARNING] [karabiner.lease] Karabiner lease 554cdd2c504645b99d32c4549c501c37 waited 124.50 s for PONG 20; the deadline timer fired 0.00 s late.
2026-10-30 01:22:17:829 [ERROR] [karabiner.lease] Karabiner lease 554cdd2c504645b99d32c4549c501c37 failed; fencing before publishing failure: timeout waiting for PONG 20
2026-10-30 01:22:17:829 [WARNING] [key_event_health] A Karabiner lease failed (pong); session totals: 15 key-down(s), 15 key-up(s), 0 key-up(s) without key-down, 0 key-down(s) without key-up, 0 key(s) stuck over 3.0 s, 0 character key(s) held 500 ms or more (0 across a rule switch), 0 key-down(s) a…
2026-10-30 01:22:18:503 [WARNING] [karabiner] Karabiner lease failed after exact fencing; fresh-generation recovery attempt 1/3 in 1.0 s (unexpected-worker-loss).
```

**network_failure**

```
2026-10-30 01:16:40:451 [WARNING] [adapters.http_client] Request timed out after 30000ms.
2026-10-30 13:42:55:257 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 16:28:06:085 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 17:05:21:778 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 17:19:06:761 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 17:36:02:261 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 17:37:35:422 [ERROR] [llm.api_ollama] The local server's model list is unavailable: HTTP 0 (Network request failed: Connection failed: Could not connect to the server. - http://127.0.0.1:11435/api/tags).
2026-10-30 18:24:16:710 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 18:36:06:008 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
2026-10-30 18:39:26:780 [WARNING] [adapters.field_check_ports] PAC download failed: Network request failed: Connection failed: A server with the specified hostname could not be found.
```

**event_tap_disabled**

```
2026-10-30 00:53:58:065 [WARNING] [keystats] Keystats event tap found disabled — restarting.
2026-10-30 10:10:43:848 [WARNING] [keystats] Keystats event tap found disabled — restarting.
2026-10-30 17:24:42:361 [WARNING] [keystats] Keystats event tap found disabled — restarting.
```

</details>
