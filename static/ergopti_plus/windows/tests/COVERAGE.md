# Test Coverage Status — Windows (AutoHotkey)

This document is a **honest** account of what the AHK test suite covers, what
it intentionally skips, and the rationale for each deferral.

## Covered (with assertions)

| Module / area                              | Test file                                      | Assertions |
|--------------------------------------------|------------------------------------------------|------------|
| `lib/logger.ahk`                           | `test_logger.ahk`                              | 59         |
| `lib/logger.ahk` (contract)                | `test_logger_contract.ahk`                     | 1          |
| `lib/string_utils.ahk`                     | `test_string_utils.ahk`                        | 8          |
| `lib/nav_layer_helpers.ahk`                | `test_nav_layer_helpers.ahk`                   | 8          |
| `lib/window_utils.ahk`                     | `test_window_utils.ahk`                        | 3          |
| `lib/timer_scheduler.ahk`                  | `test_timer_scheduler.ahk`                     | 18         |
| `lib/active_app_cache.ahk`                 | `test_active_app_cache.ahk`                    | 29         |
| `lib/config.ahk`                           | `test_config.ahk`                              | 31         |
| `lib/toml_loader.ahk`                      | `test_toml_loader.ahk`                         | 61         |
| `lib/tap_hold_loader.ahk`                  | `test_tap_hold_loader.ahk`                     | 45         |
| `lib/layout_tables.ahk`                    | `test_layout_tables.ahk`                       | 59         |
| `lib/personal_toml_editor.ahk`             | `test_personal_toml_editor.ahk`                | 59         |
| `lib/i18n.ahk`                             | `test_i18n.ahk`                                | 21         |
| Test framework itself                      | `test_framework.ahk`                           | 5          |
| `modules/keylogger/app_categories.ahk`     | `test_keylogger_app_categories.ahk`            | 18         |
| `modules/keylogger/reader.ahk`             | `test_keylogger_reader.ahk`                    | 61         |
| `modules/keylogger/walker.ahk`             | `test_keylogger_walker.ahk`                    | 27         |
| `modules/llm/api_ollama.ahk`               | `test_llm_api_ollama.ahk`                      | 32         |
| `modules/llm/api_remote.ahk`               | `test_llm_api_remote.ahk`                      | 61         |
| `modules/llm/prediction_engine.ahk`        | `test_llm_prediction_engine.ahk`               | 48         |
| `modules/llm/profiles.ahk`                 | `test_llm_profiles.ahk`                        | 21         |
| `modules/gestures.ahk`                     | `test_gestures.ahk`                            | 42         |
| `modules/shortcuts.ahk`                    | `test_shortcuts.ahk`                           | 35         |
| Hotstring engine (unit)                    | `test_hotstring_engine.ahk`                    | 56         |
| Hotstring engine (main pipeline)           | `test_hotstring_engine_main.ahk`               | 71         |
| Hotstrings full (expanded output)          | `test_hotstrings_full.ahk`                     | 119        |
| Hotstrings config reader                   | `test_hotstrings_config.ahk`                   | 26         |
| Domain registry (shared JS spec)           | `test_domain_registry.ahk`                     | 27         |
| Domain expander (shared JS spec)           | `test_domain_expander.ahk`                     | 14         |
| Adapter compliance (port contracts)        | `test_adapter_compliance_new.ahk`              | 26         |
| Adapter contract vectors (corpus)          | `test_adapter_contract_vectors.ahk`            | —          |
| Registry (AHK-specific)                    | `test_registry.ahk`                            | 8          |
| Features manifest parity                   | `test_features_manifest.ahk`                   | 108        |

**Total: ~1 230+ assertions** across ~33 unit-test files.

## Architectural meta-tests

| Test file                                  | Purpose                                                     |
|--------------------------------------------|-------------------------------------------------------------|
| `meta/test_file_headers.ahk`               | First-line path comment present in every AHK file           |
| `meta/test_section_headers.ahk`            | Banner `=` lengths align with title                         |
| `meta/test_logger_pairing.ahk`             | Logger.start/success and trace/done counts balanced         |
| `meta/test_require_state_pattern.ahk`      | Stateful classes expose `RequireState` guard                |
| `meta/test_no_duplicate_defaults.ahk`      | Default values not duplicated across files                  |
| `meta/test_no_coauthor_in_commits.ahk`     | Last 50 commits free of Co-Authored-By trailers             |
| `meta/test_no_pascal_case_in_toml.ahk`     | TOML keys follow snake_case convention                      |
| `meta/test_no_class_global_conflict.ahk`   | Class names don't shadow AHK built-in globals               |
| `meta/test_port_adapter_coverage.ahk`      | Every shared port has a corresponding AHK adapter           |
| `meta/test_corpus_hotstring_matcher.ahk`   | Hotstring corpus golden vectors (25 cases)                  |
| `meta/test_corpus_tap_hold.ahk`            | Tap-hold corpus golden vectors (14 cases)                   |
| `meta/test_corpus_hotstrings.ahk`          | Hotstrings integration corpus (12 cases)                    |

## Deferred / not yet covered

| Module / area                        | Reason for deferral                                                                                                   |
|--------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `lib/tooltip.ahk` / `ui/tooltip_*.ahk` | GDI+ drawing calls; visual output not assertable headlessly. Manual QA only.                                       |
| `lib/ui_style.ahk`                   | Pure constants file. No logic. Verified by `test_tooltip_tint_contract.ahk` for the tint math only.                  |
| `lib/ui_utils.ahk`                   | GUI layout helpers (`Gui_HarmoniseButtonWidths`). Requires a live Gui object.                                         |
| `modules/llm/token_parser.ahk`       | Diff-coloring pass; requires an integration test driving a full tooltip repaint. Deferred until TokenParser is ported. |
| `modules/llm/api_mlx.ahk`            | Hammerspoon-only backend (macOS MLX). AHK driver does not expose this API.                                            |
| `modules/hotkeys.ahk`                | Hot-key registration depends on a live AHK message pump; headless execution cannot simulate `Hotkey` side-effects.    |
| `modules/dynamic_hotstrings/`        | Public `start()`/`inject_data()` mainly mutate the registry; full coverage needs a seeded registry fixture.            |
| `modules/keylogger/kc_bridge.ahk`    | File-tail watcher around an external Karabiner log file; no equivalent on Windows. N/A.                               |
| `lib/bundle.ahk`                     | Version/update constants stamped at compile time. No runtime logic.                                                   |
| `lib/wpm_widget.ahk`                 | Renders a live GUI overlay. Manual QA only.                                                                           |
| Shared corpus: `prompt_builder/`     | AHK-side corpus consumer not yet written — see roadmap item 1.                                                        |
| Shared corpus: `llm/parser_test_vectors` | AHK-side corpus consumer not yet written — see roadmap item 1.                                                  |
| Shared corpus: `toml/fuzz_corpus`    | AHK-side TOML fuzz harness not yet written — see roadmap item 2.                                                      |
| Shared corpus: `security/keylogger_no_persist` | AHK privacy test exists but does not yet load the JSON corpus — see roadmap item 3.                      |

## Estimated coverage

Of the **testable** surface (excluding GUI rendering and code that fundamentally
requires a live AHK message pump or Windows OS interaction):

- `lib/` core utilities: ~80% covered. Remaining gaps are `ui_style.ahk` (constants only), `ui_utils.ahk` (GUI helpers), `wpm_widget.ahk` (GUI overlay), and `bundle.ahk` (compile-time stamp).
- `modules/llm/`: ~70% covered. `api_ollama`, `api_remote`, `prediction_engine`, and `profiles` covered; `token_parser` (diff-coloring) and `api_mlx` deferred.
- `modules/keylogger/`: ~70% covered. `app_categories`, `reader`, and `walker` covered; `kc_bridge` is macOS-only (N/A on Windows).
- `modules/gestures/`: ~65% covered. Guards and state machine covered; OS-dispatch (key posting, window manipulation) requires a live AHK message pump.
- `modules/hotstrings/`: ~85% covered. Engine, main pipeline, config, and full expansion output covered.
- Shared domain contracts: covered via `test_domain_registry.ahk` and `test_domain_expander.ahk`.
- Shared corpus vectors: hotstrings and tap-hold corpus loaded; `prompt_builder`, `llm_parser`, `toml_fuzz`, and `security` corpus consumers pending.

## Roadmap for follow-up sprints

1. Add AHK corpus consumers for `shared/tests/corpus/prompt_builder/`, `llm/parser_test_vectors.json`, and `security/keylogger_no_persist_vectors.json` — mirrors the macOS `test_keylogger_privacy.lua` approach.
2. Build a TOML fuzz harness that iterates `shared/tests/corpus/toml/fuzz_corpus.json` and verifies the AHK TOML loader does not crash on adversarial inputs.
3. Port `modules/llm/token_parser.ahk` diff-coloring (green/orange/gray chunks) from the macOS renderer; add unit tests on the `TokenParser` class in isolation before wiring it into tooltip repaint.
4. Add `test_tooltip_tint_contract.ahk` assertions: the tint mixing math (`_TooltipMixTintHex`) should be verified against the shared `[tint]` constants in `tooltip/constants.toml`.
