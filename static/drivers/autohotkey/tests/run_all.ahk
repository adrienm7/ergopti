; static/drivers/autohotkey/tests/run_all.ahk

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
#Warn All
#Warn VarUnset, Off

; Test framework first — Assert / Test / RunTests must exist before any
; subsequent file registers its cases or invokes assertions inside lambdas.
#Include test_framework.ahk

; Stubs second — they define ScriptInformation, Features, SendNewResult,
; WrapTextIfSelected, DeadKey, ToggleCapsLock, etc., which lib/ files
; reference at definition (Bind) time or at call time during tests.
#Include test_stubs.ahk

; ── Production lib files in dependency order ──
#Include ..\lib\logger.ahk
#Include ..\lib\ini_helpers.ahk
#Include ..\lib\active_app_cache.ahk
#Include ..\lib\hotstring_engine.ahk
#Include ..\lib\toml_loader.ahk
#Include ..\lib\personal_toml_editor.ahk
#Include ..\lib\dispatchers.ahk
#Include ..\lib\layout_altgr.ahk
#Include ..\lib\layout_shift_caps.ahk

; ── Per-module test files (each registers Test() cases) ──
#Include test_logger.ahk
#Include test_hotstring_engine.ahk
#Include test_toml_loader.ahk
#Include test_personal_toml_editor.ahk
#Include test_dispatchers.ahk
#Include test_layout_tables.ahk
#Include test_active_app_cache.ahk
#Include test_config.ahk

; Drive everything. RunTests prints a TAP-style report to stdout and exits
; with the appropriate code — control never returns from this call.
RunTests()
