; static/ergopti_plus/windows/tests/run_hotstrings_config.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off
global _AHK_DRY_RUN := false

#Include test_framework.ahk
#Include test_stubs.ahk
#Include ../_generated/terminators.ahk
#Include ../adapters/file_system.ahk
#Include ../infra/toml/toml_helpers.ahk
#Include ../infra/toml/toml_loader.ahk
#Include ../infra/hotstrings/hotstrings_config.ahk
#Include unit/test_hotstrings_config.ahk

RunTests()
