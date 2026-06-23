; static/ergopti_plus/windows/tests/run_hotstrings_config.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off
global _AHK_DRY_RUN := false

#Include test_framework.ahk
#Include test_stubs.ahk
#Include ../_generated/terminators.ahk
#Include ../lib/toml/toml_helpers.ahk
#Include ../lib/toml/toml_loader.ahk
#Include ../lib/hotstrings/hotstrings_config.ahk
#Include unit/test_hotstrings_config.ahk

RunTests()