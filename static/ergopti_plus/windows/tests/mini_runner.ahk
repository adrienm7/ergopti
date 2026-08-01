; static/ergopti_plus/windows/tests/mini_runner.ahk

; ==============================================================================
; MODULE: Mini Test Runner
; DESCRIPTION:
; Lightweight runner for quick syntax and logic verification of core modules.
; ==============================================================================

#Requires Autohotkey v2.0+
SetWorkingDir("static\ergopti_plus\windows\tests")
global _AHK_DRY_RUN := true
#Include test_framework.ahk
#Include test_stubs.ahk
#Include ../infra/logger.ahk
#Include ../infra/toml/toml_helpers.ahk
#Include ../infra/toml/toml_loader.ahk
#Include unit/test_toml_loader.ahk

RunTests()
