; static/ergopti_plus/windows/tests/run_all.ahk

; ==============================================================================
; MODULE: Test Runner Entry Point
; DESCRIPTION:
; Single ``AutoHotkey.exe`` entry point for the ErgoptiPlus AHK test suite.
; Loads the framework, the stubs, every production lib and every per-module
; test file in dependency order, then calls ``RunTests`` to execute all
; registered ``Test`` cases. Exits with code 0 on full pass, 1 on any failure
; — the contract the GitHub Actions workflow relies on to fail the CI build.
;
; FEATURES & RATIONALE:
; 1. The runner #Includes the production ``lib/`` files directly. This means
;    a refactor in a lib file is immediately exercised by the corresponding
;    test_*.ahk file with no per-test glue to maintain.
; 2. ``modules/`` files are deliberately NOT included — they register hotkeys
;    at top level and would prevent the runner from exiting cleanly. The
;    behaviour exposed by modules (layer / shortcuts / hotstrings) is tested
;    through the lib/ helpers it shares with production.
; 3. AHK v2 directives at the top mirror those in ErgoptiPlus.ahk so that
;    parser quirks (#Warn VarUnset, encoding) are identical between test
;    runs and production startup.
; ==============================================================================

#Requires Autohotkey v2.0+
#SingleInstance Force
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off
global _AHK_DRY_RUN := (A_Args.Length > 0 && A_Args[1] == "--dry-run")

; Test framework first — Assert / Test / RunTests must exist before any
; subsequent file registers its cases or invokes assertions inside lambdas.
#Include test_framework.ahk

; Stubs second — they define ScriptInformation, Features, SendNewResult,
; WrapTextIfSelected, DeadKey, ToggleCapsLock, etc., which lib/ files
; reference at definition (Bind) time or at call time during tests.
#Include test_stubs.ahk

; ── Production lib files in dependency order ──
#Include ../lib/app_state.ahk
#Include ../lib/ui_style.ahk
#Include ../lib/logger.ahk
#Include ../lib/toml/toml_helpers.ahk
#Include ../lib/active_app_cache.ahk
#Include ../lib/window_utils.ahk
#Include ../lib/string_utils.ahk
#Include ../lib/nav_layer_helpers.ahk
#Include ../lib/hotstrings/hotstring_engine.ahk
#Include ../lib/hotstrings/hotstring_engine_main.ahk
#Include ../lib/toml/toml_loader.ahk
#Include ../lib/toml/toml_config_loader.ahk
#Include ../lib/tap_hold/tap_hold_loader.ahk
#Include ../_generated/features_manifest.ahk
#Include ../lib/manifest_reader.ahk
#Include ../lib/hotstrings/hotstrings_config.ahk
#Include ../lib/hotstrings/personal_toml_editor.ahk
#Include ../lib/layout/layout_altgr.ahk
#Include ../lib/layout/layout_shift_caps.ahk
#Include ../lib/tooltip.ahk
; json.ahk must precede i18n.ahk — _I18nLoadFile now delegates to JsonParse.
#Include ../lib/registry.ahk
#Include ../lib/json.ahk
; i18n is included here because gestures.ahk calls t() at the top level
; when building GESTURE_SLOT_LABELS; without this the process blocks on
; an AHK runtime-error MsgBox and the CI job times out.
#Include ../lib/i18n.ahk

; Install the hotstring hooks for the entire test process so neither real
; ``Hotstring()`` registrations nor real ``SendEvent`` keystrokes ever escape
; into the CI environment. Stubs that need raw send semantics still observe
; UpdateLastSentCharacter (the hook only intercepts the lower-level emission).
InstallHotstringHooks()

; ── Adapter contract: include all port adapters so contract vector tests can call them ──
#Include ../adapters/notifier.ahk
#Include ../adapters/timer_scheduler.ahk
#Include ../adapters/file_system.ahk
#Include ../adapters/window_info.ahk
#Include ../adapters/tray_menu.ahk
#Include ../adapters/text_sender.ahk
#Include ../adapters/http_client.ahk
#Include ../adapters/secure_field_detector.ahk
#Include ../adapters/clipboard.ahk
#Include ../adapters/storage.ahk
#Include ../adapters/process_lifecycle.ahk
#Include ../adapters/key_state.ahk
#Include ../adapters/app_launcher.ahk

; Lock _AHK_SendText / _AHK_SendInput to no-ops AFTER the adapter has been
; included (the adapter sets them to real lambdas; InstallSendNoOps overwrites
; them so no keystroke can escape into the OS during test execution).
InstallSendNoOps()

; ── Per-module test files (each registers Test() cases) ──
#Include test_adapter_compliance_new.ahk
#Include test_adapter_contract_vectors.ahk
#Include test_timer_scheduler.ahk
#Include test_logger.ahk
#Include test_logger_contract.ahk
#Include test_tooltip_tint_contract.ahk
#Include test_hotstring_engine.ahk
#Include test_hotstring_engine_main.ahk
#Include test_domain_registry.ahk
#Include test_domain_expander.ahk
#Include test_toml_loader.ahk
#Include test_hotstrings_config.ahk
#Include test_personal_toml_editor.ahk
#Include test_layout_tables.ahk
#Include test_active_app_cache.ahk
#Include test_config.ahk
#Include test_features_manifest.ahk
#Include test_hotstrings_full.ahk
#Include test_tap_hold_loader.ahk
#Include test_i18n.ahk
#Include test_window_utils.ahk
#Include test_string_utils.ahk
#Include test_registry.ahk
#Include test_nav_layer_helpers.ahk

; Shortcuts modules — dispatcher logic is testable without real hotkeys firing;
; the module files are #Include'd from within test_shortcuts.ahk itself so the
; include paths are resolved relative to the tests/ directory.
#Include test_shortcuts.ahk

; LLM modules — pure-logic subset (profiles, models, api_common, api_ollama,
; api_remote, prediction_engine) included here to test JSON parsing, profile
; lookup, payload building, response parsing, cancel helpers, and engine
; debounce / cache logic without any real network calls.
; models.ahk defines LLM_GetSharedPath which profiles.ahk depends on.
#Include ../modules/llm/models.ahk
#Include ../modules/llm/profiles.ahk
#Include test_llm_profiles.ahk
#Include ../modules/llm/api_common.ahk
#Include ../modules/llm/api_ollama.ahk
#Include ../modules/llm/api_remote.ahk
#Include test_llm_api_ollama.ahk
#Include test_llm_api_remote.ahk
#Include ../modules/llm/prediction_engine.ahk
#Include test_llm_prediction_engine.ahk

; Gestures module — included here because its pure logic (assignments, action
; registry, dispatch) is testable. The hotkeys it registers are harmless since
; RunTests() calls ExitApp immediately after completion.
#Include ../modules/gestures.ahk
#Include test_gestures.ahk

; Keylogger sub-modules — pure-logic subsets included here to test category
; lookup, character classification, and burst helpers without OS hooks or I/O.
; sqlite3.ahk needs _VendorDir (set by ErgoptiPlus.ahk at runtime); stub it
; here so the class static initialiser does not crash the test runner.
global _VendorDir := A_ScriptDir . "\..\vendor"
#Include ../lib/sqlite3.ahk
#Include ../modules/keylogger/keylogger_walker.ahk
#Include ../modules/keylogger/keylogger_app_categories.ahk
#Include ../modules/keylogger/keylogger_reader.ahk
#Include test_keylogger_walker.ahk
#Include test_keylogger_app_categories.ahk
#Include test_keylogger_reader.ahk

; ── Meta tests (codebase hygiene, no production includes needed) ──
#Include meta/test_file_headers.ahk
#Include meta/test_section_headers.ahk
#Include meta/test_logger_pairing.ahk
#Include meta/test_no_duplicate_defaults.ahk
#Include meta/test_require_state_pattern.ahk
#Include meta/test_no_coauthor_in_commits.ahk
#Include meta/test_no_pascal_case_in_toml.ahk
#Include meta/test_port_adapter_coverage.ahk
; ── Cross-driver corpus consumers ──
#Include meta/test_corpus_hotstrings.ahk
#Include meta/test_corpus_tap_hold.ahk
#Include meta/test_corpus_hotstring_matcher.ahk

; Drive everything. RunTests prints a TAP-style report to stdout and exits
; with the appropriate code — control never returns from this call.
RunTests()
