# Test Coverage Status — Windows (AutoHotkey)

This document is a **honest** account of what the AHK test suite covers, what
it intentionally skips, and the rationale for each deferral.

## Covered (with assertions)

| Module / area                             | Test file                           | Assertions                    |
| ----------------------------------------- | ----------------------------------- | ----------------------------- |
| `lib/logger.ahk`                          | `test_logger.ahk`                   | 59                            |
| `lib/logger.ahk` (contract)               | `test_logger_contract.ahk`          | 1                             |
| `lib/string_utils.ahk`                    | `test_string_utils.ahk`             | 8                             |
| `lib/nav_layer_helpers.ahk`               | `test_nav_layer_helpers.ahk`        | 8                             |
| `lib/window_utils.ahk`                    | `test_window_utils.ahk`             | 3                             |
| `lib/timer_scheduler.ahk`                 | `test_timer_scheduler.ahk`          | 18                            |
| `lib/active_app_cache.ahk`                | `test_active_app_cache.ahk`         | 29                            |
| `lib/config.ahk`                          | `test_config.ahk`                   | 31                            |
| `lib/toml_loader.ahk`                     | `test_toml_loader.ahk`              | 61                            |
| `lib/tap_hold_loader.ahk`                 | `test_tap_hold_loader.ahk`          | 45                            |
| `modules/keymap/layout/`                   | `test_layout_tables.ahk`            | 59                            |
| `lib/personal_toml_editor.ahk`            | `test_personal_toml_editor.ahk`     | 59                            |
| `lib/i18n.ahk`                            | `test_i18n.ahk`                     | 21                            |
| Test framework itself                     | `test_framework.ahk`                | 5                             |
| `modules/keylogger/app_categories.ahk`    | `test_keylogger_app_categories.ahk` | 18                            |
| `modules/keylogger/reader.ahk`            | `test_keylogger_reader.ahk`         | 61                            |
| `modules/keylogger/walker.ahk`            | `test_keylogger_walker.ahk`         | 27                            |
| `modules/llm/api_ollama.ahk`              | `test_llm_api_ollama.ahk`           | 32                            |
| `modules/llm/api_remote.ahk`              | `test_llm_api_remote.ahk`           | 61                            |
| `modules/llm/prediction_engine.ahk`       | `test_llm_prediction_engine.ahk`    | 48                            |
| `modules/llm/profiles.ahk`                | `test_llm_profiles.ahk`             | 21                            |
| `modules/gestures.ahk`                    | `test_gestures.ahk`                 | 42                            |
| `modules/shortcuts.ahk`                   | `test_shortcuts.ahk`                | 35                            |
| Hotstring engine (unit)                   | `test_hotstring_engine.ahk`         | 56                            |
| Hotstring engine (main pipeline)          | `test_hotstring_engine_main.ahk`    | 71                            |
| Hotstrings full (expanded output)         | `test_hotstrings_full.ahk`          | 119                           |
| Hotstrings config reader                  | `test_hotstrings_config.ahk`        | 26                            |
| Domain registry (shared JS spec)          | `test_domain_registry.ahk`          | 27                            |
| Domain expander (shared JS spec)          | `test_domain_expander.ahk`          | 14                            |
| Adapter compliance (port contracts)       | `test_adapter_compliance_new.ahk`   | 26                            |
| Adapter contract vectors (corpus)         | `test_adapter_contract_vectors.ahk` | —                             |
| Registry (AHK-specific)                   | `test_registry.ahk`                 | 8                             |
| Features manifest parity                  | `test_features_manifest.ahk`        | 108                           |
| LLM tray menu → `config.toml` persistence | `test_llm_menu_persistence.ahk`     | 4 (+ 26 contract round-trips) |
| LLM tray menu — fixed-bug regressions     | `test_llm_menu_regressions.ahk`     | 9                             |

**Total: ~1 230+ assertions** across ~34 unit-test files.

### LLM menu persistence (regression guard)

Contract: `_shared/modules/llm/menu_persistence_contract.json` — one row per tray/menu knob that must round-trip to disk.

| Runner               | Command                                                                                               |
| -------------------- | ----------------------------------------------------------------------------------------------------- |
| AHK (focused)        | `AutoHotkey64.exe /ErrorStdOut windows/tests/run_llm_menu_persistence.ahk`                            |
| AHK (full suite)     | `AutoHotkey64.exe /ErrorStdOut windows/tests/run_all.ahk`                                             |
| Hammerspoon          | `lua macos/tests/run.lua` (includes `test_llm_menu_persistence.lua`, `test_llm_menu_regressions.lua`) |
| Contract schema (CI) | `python _shared/modules/llm/validate_menu_persistence_contract.py`                                             |

When adding a new IA menu option: extend the JSON contract, wire `ui/menu/menu_llm/persist.ahk` (sync + append + `BuildSavedOpts`), map `preferences.lua` on macOS, then run the three runners above.

**Regression suite** (`test_llm_menu_regressions.*`): one test per fixed incident — `_AHK_DRY_RUN` / `.Call()`, `val_modifiers` comma split, no `actions.ahk` `#Include persist`, AHK v2 menu closure (`MakeSetNHandler`), macOS `build_num_pred_menu` index capture. Add a matching AHK + HS test when fixing the next menu bug.

## Architectural meta-tests

| Test file                                | Purpose                                             |
| ---------------------------------------- | --------------------------------------------------- |
| `meta/test_file_headers.ahk`             | First-line path comment present in every AHK file   |
| `meta/test_section_headers.ahk`          | Banner `=` lengths align with title                 |
| `meta/test_logger_pairing.ahk`           | Logger.start/success and trace/done counts balanced |
| `meta/test_require_state_pattern.ahk`    | Stateful classes expose `RequireState` guard        |
| `meta/test_no_duplicate_defaults.ahk`    | Default values not duplicated across files          |
| `meta/test_no_coauthor_in_commits.ahk`   | Last 50 commits free of Co-Authored-By trailers     |
| `meta/test_no_pascal_case_in_toml.ahk`   | TOML keys follow snake_case convention              |
| `meta/test_no_class_global_conflict.ahk` | Class names don't shadow AHK built-in globals       |
| `meta/test_port_adapter_coverage.ahk`    | Every shared port has a corresponding AHK adapter   |
| `meta/test_corpus_hotstring_matcher.ahk` | Hotstring corpus golden vectors (25 cases)          |
| `meta/test_corpus_tap_hold.ahk`          | Tap-hold corpus golden vectors (14 cases)           |
| `meta/test_corpus_hotstrings.ahk`        | Hotstrings integration corpus (12 cases)            |

### Audit-fix regression meta-tests (batch-wired, June 2026)

| Test file                                           | Fix guarded                                                                       |
| --------------------------------------------------- | --------------------------------------------------------------------------------- |
| `meta/test_generated_substr_minus_one.ahk`          | `SubStr(Trigger, -0)` → `SubStr(Trigger, -1)` tail-char bug in the live engine `lib/hotstrings/hotstring_engine_main.ahk` (retargeted from the deleted `_generated/{registry,expander}.ahk`) |
| `meta/test_toml_multiline_array_depth.ahk`          | Multi-line TOML array uses bracket-depth counter + quote state (not naive `InStr(Line, "]")`) |
| `meta/test_toml_unescape_ordering.ahk`              | `_WS_UnescapeToml` replaces `\\` before `\"` to avoid corrupting `\\"` sequences |
| `meta/test_clipboard_sentinel.ahk`                  | `CB_Save` returns `"__CB_SAVE_ERROR__"` sentinel; `CB_Restore` skips on sentinel |
| `meta/test_textsend_callback_wired.ahk`             | `_TextSendClipboard` receives and fires `Callback` after paste (not before)       |
| `meta/test_is_category_all_enabled_loop.ahk`        | `IsCategoryAllEnabled` loops over ALL categories (not just `Categories[1]`)       |
| `meta/test_regread_no_type_arg.ahk`                 | `Reg_ReadBinary` calls `RegRead` with 2 args only (no v1 `REG_BINARY` third arg) |
| `meta/test_logger_dedup_tick.ahk`                   | Logger error dedup uses `_LastErrTime` + 5000 ms window (not permanent suppression) |
| `meta/test_hse_endchar_consumed_delimiters.ahk`     | `HSE_ApplyExpansion` guards `EndChar` with `!InStr(HSE_CONSUMED_DELIMITERS, EndChar)` |
| `meta/test_prefix_watcher_magic_suffix.ahk`         | `HasMagic` uses trailing-suffix `SubStr(Trigger, -MkLen) == MagicKey`, not `InStr` |
| `meta/test_deadkey_uses_dynamic_magic_key.ahk`      | `ShouldActivateDeadkey` reads `ScriptInformation["MagicKey"]` at runtime (not hardcoded star) |
| `meta/test_parse_overrides_seen_sections.ahk`       | `_ParseOverrides` tracks `SeenSections` and warns via `LoggerWarn` on duplicates  |
| `meta/test_llm_getactiveprofile_arg.ahk`            | All `LLM_GetActiveProfile` calls pass `user_profiles` as second argument          |
| `meta/test_tickcount_wrap_safe.ahk`                 | TickCount deltas use `(now - last + 0x100000000) & 0xFFFFFFFF` in prediction engine + bridge |
| `meta/test_llm_token_budget_min5.ahk`               | `_LLM_Engine_CallTokenBudget` returns `Max(5, ...)` to guarantee minimum budget   |
| `meta/test_llm_parser_nul_strip.ahk`                | `_LLM_Parser_CleanModelOutput` strips `[\x00-\x08\x0B\x0C\x0E-\x1F]` via `RegExReplace` |
| `meta/test_altgr_hotif_dynamic.ahk`                 | `IsAltGrLAltEnabled` delegates to `_AnyShortcutEnabled` (runtime, not boot-time global) |
| `meta/test_ergo_pinky_modifier_skip.ahk`            | `KL_Ergo_UpdatePinky` early-returns for modifier VKs 0x10-0x12, 0xA0-0xA5, 0x5B/0x5C |
| `meta/test_watchers_idle_end_ordering.ahk`          | `KL_Watchers_IdleTick` emits `idle_end` before `session_end`                     |
| `meta/test_timer_scheduler_ms_guard.ahk`            | `TimerEvery` clamps `Ms := 1` when `Ms <= 0` to prevent silent timer removal     |
| `meta/test_http_cancel_aborts.ahk`                  | `HTTPCancel` calls `.Abort()` before zeroing `_HTTP_ACTIVE_REQUEST := 0`         |
| `meta/test_keyboard_hook_vk_format.ahk`             | VK codes formatted with `{:02X}` (zero-padded), not single-digit `{1:X}`         |
| `meta/test_plc_stop_clears_callbacks.ahk`           | `PLC_Stop` clears all three callback arrays to `[]` to prevent duplicate fires   |
| `meta/test_toml_coerce_quoted_commas.ahk`           | `TomlCoerceValueExt` uses quote-aware character scanner (not naive `StrSplit(Inner, ",")`) |
| `meta/test_i18n_setlocale_resets_fallback.ahk`      | `I18nSetLocale` resets `_I18nFallbacksWarmed := false` so next `t()` rebuilds    |
| `meta/test_ws_save_atomic.ahk`                      | `_WS_Save` stages write to `.tmp` then renames via `FileMove` (atomic write)     |
| `meta/test_tapholdwriter_int_before_bool.ahk`       | `_TH_TomlFormatLine` checks `Integer/Float` before `== true` (AHK 0 falsiness)  |
| `meta/test_llm_menu_toggle_reentrancy.ahk`          | `LLM_Menu_OnToggle` guards with `static _Toggling := false` for re-entrancy     |
| `meta/test_llm_menu_tab_source_hwnd.ahk`            | `LLM_Menu_TryAcceptTabGuarded` checks `source_hwnd` + `WinExist` before accepting |
| `meta/test_modelbrowser_sort_callback.ahk`          | `_LLM_ModelBrowser_Sort` uses `Array.Sort(comparator)` O(n log n), not bubble sort |
| `meta/test_space_taphold_configurable.ahk`          | `SPACE_HOLD_INPUT_TIMEOUT_FACTOR` constant replaces hardcoded `T3` in space tap-hold |
| `meta/test_terminators_requires_directive.ahk`      | `_generated/terminators.ahk` has `#Requires AutoHotkey v2.0` near top of file    |
| `meta/test_layout_poll_pending_hkl.ahk`             | `_ShouldReloadForHkl` preserves `pendingHkl` when `curHkl == 0` (transient unreadable) |
| `meta/test_llmbridge_stop_order.ahk`                | `LLM_Bridge_Stop` calls `StopGeneration()` before `SetEnabled(false)`            |
| `meta/test_llmdiff_has_corrections_ltrim.ahk`       | `HasCorrections` evaluated AFTER `LTrim(chunks[1].text)` so whitespace chunks excluded |

## Deferred / not yet covered

| Module / area                                  | Reason for deferral                                                                                                |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `lib/tooltip.ahk` / `ui/tooltip_*.ahk`         | GDI+ drawing calls; visual output not assertable headlessly. Manual QA only.                                       |
| `lib/ui_style.ahk`                             | Pure constants file. No logic. Verified by `test_tooltip_tint_contract.ahk` for the tint math only.                |
| `lib/ui_utils.ahk`                             | GUI layout helpers (`Gui_HarmoniseButtonWidths`). Requires a live Gui object.                                      |
| `modules/llm/api_mlx.ahk`                      | Hammerspoon-only backend (macOS MLX). AHK driver does not expose this API.                                         |
| `modules/hotkeys.ahk`                          | Hot-key registration depends on a live AHK message pump; headless execution cannot simulate `Hotkey` side-effects. |
| `modules/dynamic_hotstrings/`                  | Public `start()`/`inject_data()` mainly mutate the registry; full coverage needs a seeded registry fixture.        |
| `modules/keylogger/kc_bridge.ahk`              | File-tail watcher around an external Karabiner log file; no equivalent on Windows. N/A.                            |
| `lib/bundle.ahk`                               | Version/update constants stamped at compile time. No runtime logic.                                                |
| `ui/wpm_widget.ahk`                            | Renders a live GUI overlay. Manual QA only.                                                                        |
| Shared corpus: `prompt_builder/`               | AHK-side corpus consumer not yet written — see roadmap item 1.                                                     |
| Shared corpus: `llm/parser_test_vectors`       | AHK-side corpus consumer not yet written — see roadmap item 1.                                                     |
| Shared corpus: `toml/fuzz_corpus`              | AHK-side TOML fuzz harness not yet written — see roadmap item 2.                                                   |
| Shared corpus: `security/keylogger_no_persist` | AHK privacy test exists but does not yet load the JSON corpus — see roadmap item 3.                                |

## Estimated coverage

Of the **testable** surface (excluding GUI rendering and code that fundamentally
requires a live AHK message pump or Windows OS interaction):

- `lib/` core utilities: ~80% covered. Remaining gaps are `ui_style.ahk` (constants only), `ui_utils.ahk` (GUI helpers), `wpm_widget.ahk` (GUI overlay), and `bundle.ahk` (compile-time stamp).
- `modules/llm/`: ~75% covered. `api_ollama`, `api_remote`, `prediction_engine`, `profiles`, and `parser` (the `process_prediction` diff-coloring, via `test_llm_parser.ahk`) covered; `api_mlx` deferred.
- `modules/keylogger/`: ~70% covered. `app_categories`, `reader`, and `walker` covered; `kc_bridge` is macOS-only (N/A on Windows).
- `modules/gestures/`: ~65% covered. Guards and state machine covered; OS-dispatch (key posting, window manipulation) requires a live AHK message pump.
- `modules/hotstrings/`: ~85% covered. Engine, main pipeline, config, and full expansion output covered.
- Shared domain contracts: covered via `test_domain_registry.ahk` and `test_domain_expander.ahk`.
- Shared corpus vectors: hotstrings and tap-hold corpus loaded; `prompt_builder`, `llm_parser`, `toml_fuzz`, and `security` corpus consumers pending.

## Roadmap for follow-up sprints

1. Add AHK corpus consumers for `_shared/tests/corpus/prompt_builder/`, `llm/parser_test_vectors.json`, and `security/keylogger_no_persist_vectors.json` — mirrors the macOS `test_keylogger_privacy.lua` approach.
2. Build a TOML fuzz harness that iterates `_shared/tests/corpus/toml/fuzz_corpus.json` and verifies the AHK TOML loader does not crash on adversarial inputs.
3. Add `test_tooltip_tint_contract.ahk` assertions: the tint mixing math (`_TooltipMixTintHex`) should be verified against the shared `[tint]` constants in `tooltip/constants.toml`.
