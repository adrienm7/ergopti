# Test Coverage Status

This document is a **honest** account of what the test suite covers, what it
intentionally skips, and the rationale for each deferral.

## Covered (with assertions)

| Module                                  | Test file                                                                    | Cases |
|-----------------------------------------|------------------------------------------------------------------------------|-------|
| `lib.color_utils`                       | `tests/unit/lib/test_color_utils.lua`                                        | 12    |
| `lib.text_utils`                        | `tests/unit/lib/test_text_utils.lua`                                         | 38    |
| `lib.toml_reader`                       | `tests/unit/lib/test_toml_reader.lua`                                        | 7     |
| `lib.toml_writer`                       | `tests/unit/lib/test_toml_writer.lua`                                        | 16    |
| `lib.toml_reader` ↔ `lib.toml_writer`   | `tests/unit/lib/test_toml_roundtrip.lua`                                     | 7     |
| `lib.logger`                            | `tests/unit/lib/test_logger.lua`                                             | 10    |
| `lib.perf`                              | `tests/unit/lib/test_perf.lua`                                               | 2     |
| `lib.keycodes`                          | `tests/unit/lib/test_keycodes.lua`                                           | 25    |
| `lib.layout`                            | `tests/unit/lib/test_layout.lua`                                             | 8     |
| `lib.notifications`                     | `tests/unit/lib/test_notifications.lua`                                      | 7     |
| `modules.llm.parser`                    | `tests/unit/modules/llm/test_parser.lua` (+ edge cases + helpers)            | 14 + 6 + 11 |
| `modules.llm.backend_detector`          | `tests/unit/modules/llm/test_backend_detector.lua`                           | 7     |
| `modules.llm.profiles`                  | `tests/unit/modules/llm/test_profiles.lua`                                   | 21    |
| `modules.llm.api_common`                | `tests/unit/modules/llm/test_api_common.lua`                                 | 18    |
| `modules.llm.api_ollama`                | `tests/unit/modules/llm/test_api_ollama.lua`                                 | 9     |
| `modules.llm.api_mlx`                   | `tests/unit/modules/llm/test_api_mlx.lua`                                    | 6     |
| `modules.llm` (init)                    | `tests/unit/modules/llm/test_init.lua`                                       | 38    |
| `modules.keymap.terminators`            | `tests/unit/modules/keymap/test_terminators.lua`                             | 14    |
| `modules.keymap.utils`                  | `tests/unit/modules/keymap/test_utils.lua`                                   | 24    |
| `modules.keymap.state`                  | `tests/unit/modules/keymap/test_state.lua`                                   | 14    |
| `modules.keymap.registry`               | `tests/unit/modules/keymap/test_registry.lua`                                | 16    |
| `modules.karabiner.defaults`            | `tests/unit/modules/karabiner/test_defaults.lua`                             | 6     |
| `modules.karabiner.config`              | `tests/unit/modules/karabiner/test_config.lua`                               | 11    |
| `modules.karabiner.generator` (surface) | `tests/unit/modules/karabiner/test_generator_surface.lua`                    | 4     |
| `modules.gestures.conflicts`            | `tests/unit/modules/gestures/test_conflicts.lua`                             | 11    |
| `modules.gestures` (init)               | `tests/unit/modules/gestures/test_init.lua`                                  | 16    |
| `modules.shortcuts.script_control`      | `tests/unit/modules/shortcuts/test_script_control.lua`                       | 15    |
| `modules.dynamic_hotstrings.personal_info` | `tests/unit/modules/dynamic_hotstrings/test_personal_info.lua`            | 6     |
| `modules.keymap.expander` (guards + replacement contract) | `tests/unit/modules/keymap/test_expander.lua`         | 17    |
| `modules.gestures.actions` (lookup tables) | `tests/unit/modules/gestures/test_actions.lua`                            | 18    |
| `modules.shortcuts.bindings`               | `tests/unit/modules/shortcuts/test_bindings.lua`                          | 23    |

**Total: ~430+ test cases** spread across ~33 unit-test files.

## Architectural meta-tests (warning-mode)

| Test file                                            | Purpose                                                  |
|------------------------------------------------------|----------------------------------------------------------|
| `tests/meta/test_file_headers.lua`                   | First-line path comment present in every Lua file        |
| `tests/meta/test_section_headers.lua`                | Banner `=` lengths align with title                      |
| `tests/meta/test_logger_pairing.lua`                 | Logger.start/success and trace/done counts               |
| `tests/meta/test_require_state_pattern.lua`          | Stateful modules expose require_state                    |
| `tests/meta/test_no_duplicate_defaults.lua`          | DEFAULT_STATE values not duplicated across files         |
| `tests/meta/test_no_coauthor_in_commits.lua`         | Last 50 commits free of Co-Authored-By                   |

## Deferred / not yet covered

| Module                              | Reason for deferral                                                                                                      |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `modules.keymap.expander` (full keystroke pipeline) | Guard pattern, init validation, perform_text_replacement, and try_repeat_feature early-returns are now covered. The full auto-/terminator-expand keystroke pipeline still requires a richer eventtap simulator. |
| `modules.keymap.llm_bridge`         | Debounce state machine reads real timer ticks; meaningful tests need a fake-clock helper that controls `hs.timer.doAfter`. |
| `modules.llm.prediction_engine`     | Stale-callback invariants require an async-fake `hs.http` that runs callbacks deterministically.                          |
| `modules.karabiner.generator` (full)| The 800-line `build_karabiner_json` requires a recorded fixture corpus from a live macOS run (see `tests/fixtures/karabiner_configs/README.md`).|
| `modules.karabiner.ke_lifecycle`    | Wraps `launchctl`, `pkill`, and AppleScript; only meaningful with a live Karabiner-Elements install.                      |
| `modules.karabiner.watchers`        | macOS file-system + AX observer integration; not unit-testable.                                                           |
| `modules.gestures.engine`           | Tightly bound to the undocumented `hs._asm.undocumented.touchdevice` callback flow.                                       |
| `modules.gestures.actions` (OS dispatch) | Lookup-table data and labels are now covered. The actual OS dispatch (key posting, AppleScript, dictionary lookup) still needs a live macOS host. |
| `modules.keylogger.log_manager`     | 2k+ LoC file with file rotation, manifest aggregation, and async DB merges. Needs fake-clock + tmp-dir test harness.      |
| `modules.keylogger.context_tracker` | Wraps `hs.application.watcher` and AX observer events; not unit-testable.                                                 |
| `modules.keylogger.kc_bridge`       | File-tail watcher around an external Karabiner log file.                                                                  |
| `modules.shortcuts.actions.*`       | OS interaction wrappers (Finder, screenshot, mouse). Manual QA only.                                                      |
| `modules.dynamic_hotstrings.rules_engine` | Local helpers (`spaced_prefix`, `compute_prefix_counts`) are private; the public `start()`/`add_rule()`/`inject_data()` mainly mutate the keymap registry.|
| `lib.dialog_util`                   | Pure forwarding wrapper around `hs.dialog.*` — no logic.                                                                  |
| `lib.app_picker`, `lib.ui_restore`  | UI glue — exercised manually.                                                                                             |
| `lib.vscode_bridge`                 | Spawns `code` CLI; manual smoke only.                                                                                     |
| `lib.mlx_deps_checker`, `lib.ollama_deps_checker` | Run `pip` / `brew` checks on the host; not unit-testable.                                                  |
| `ui.*`                              | Pure WebKit rendering. The menu builder data structure remains a candidate for snapshot tests, deferred for now.           |

## Estimated coverage

Of the **testable** surface (excluding pure UI rendering and code that
fundamentally requires a live Hammerspoon runtime), this sprint covers
roughly **55–60%** by file count and a slightly higher share of the public
function surface in the covered modules:

- `lib/`: ~90% covered. Remaining gaps are pure glue: `vscode_bridge`, `app_picker`, `dialog_util`, `ui_restore`, the `*_deps_checker` modules.
- `modules/llm/`: ~80% covered. `prediction_engine` and the live HTTP/streaming paths in `api_ollama` / `api_mlx` are the remaining gap; `init`, `parser`, `profiles`, `api_common`, `backend_detector`, and the model-heuristics in the backend controllers are covered.
- `modules/keymap/`: ~65% covered. `utils`, `state`, `registry`, `terminators` covered; `expander` guards and replacement contract covered; the full keystroke pipeline and `llm_bridge` still depend on the live event-tap loop.
- `modules/karabiner/`: ~45% covered. `defaults`, `config`, generator surface covered; the full JSON snapshot, `ke_lifecycle`, and `watchers` deferred.
- `modules/gestures/`: ~60% covered. `conflicts`, the data-shape portion of `init`, and the `actions` lookup tables / labels covered; `engine` and the OS-dispatch side of `actions` deferred.
- `modules/shortcuts/`: ~70% covered. `script_control` and `bindings` registry / lifecycle covered; the per-action helpers (`actions.text`, `actions.system`, `actions.apps`) deferred.
- `modules/dynamic_hotstrings/`: ~30% covered. Public surface of `personal_info` covered; `rules_engine` private helpers remain internal.
- `modules/keylogger/`: 0% covered (deferred — see above).
- `ui/`: 0% covered (intentional).

## Roadmap for follow-up sprints

1. Build a deterministic fake-clock helper to unblock `keymap.llm_bridge`, `prediction_engine`, and `keylogger.log_manager`.
2. Record real HTTP fixtures for Ollama / MLX and add response-shape tests on top of `post_and_parse`.
3. Capture a live `build_karabiner_json` snapshot during a Mac session, commit the JSON to `tests/fixtures/karabiner_configs/`, and add diff-style tests.
4. Build a keystroke-simulator harness over `hs.eventtap` so `keymap.expander` can be tested at the integration level.
5. Add a snapshot test for `ui.menu.builder` (data structure only — labels, callbacks, separators) once the schema settles.
