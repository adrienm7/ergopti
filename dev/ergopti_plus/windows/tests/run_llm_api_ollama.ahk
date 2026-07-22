; static/ergopti_plus/windows/tests/run_llm_api_ollama.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off
global _AHK_DRY_RUN := false
#Include test_framework.ahk
#Include test_stubs.ahk
#Include ../modules/llm/models.ahk
#Include ../modules/llm/api_common.ahk
#Include ../modules/llm/api_ollama.ahk
#Include unit/test_llm_api_ollama.ahk
RunTests()