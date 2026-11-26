; tests/meta/ai/servers/test_deps_fail_restores_priority.ahk

; ==============================================================================
; MODULE: Deps Fail Restores Priority Meta Test
; DESCRIPTION:
; Regression guard for AHK-30: a dependency failure must restore the driver's
; baseline priority, through the shared constant.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TDFRP_CheckFailRestoresPriority() {
	; LLM_Deps_Fail must restore the driver baseline priority
	FailBody := _DriverFuncBody("LLM_Deps_Fail")
	Assert(FailBody != "", "LLM_Deps_Fail must exist in ollama_deps_checker.ahk")
	Assert(InStr(FailBody, "ProcessSetPriority"),
		"AHK-30: LLM_Deps_Fail must pass ProcessSetPriority to the failure publication, the only exit that restores the priority")
	Publisher := _DriverFuncBody("_LLM_Deps_PublishFailure")
	Assert(InStr(Publisher, "DRIVER_BASELINE_PRIORITY_CLASS"),
		"AHK-30 / driver-baseline-priority-reverted-to-normal: the failure publication must restore via the shared DRIVER_BASELINE_PRIORITY_CLASS constant, not a hardcoded Normal literal")
}


Test("meta ahk-30: LLM_Deps_Fail restores the baseline priority after a failed install",
	_TDFRP_CheckFailRestoresPriority)
