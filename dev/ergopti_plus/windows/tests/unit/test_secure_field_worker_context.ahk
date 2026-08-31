; tests/unit/test_secure_field_worker_context.ahk

; ============================================================================
; MODULE: Secure-field UIA Worker Context Tests
; DESCRIPTION:
; Behavioral regression coverage for the host-window/control-token boundary
; used by the secure-field UIA worker. A worker request belongs to the focused
; control HWND; the top-level HWND supplies the independent window identity.
; ============================================================================

#Requires AutoHotkey v2.0+





; ====================================
; ====================================
; ======= 1/ Worker dispatch seam ====
; ====================================
; ====================================

global _SFDWCTest_RequestCount := 0
global _SFDWCTest_ReceivedContext := 0
global _SFDWCTest_StartCount := 0

_SFDWCTest_CurrentHwnd() {
	return 61002
}

_SFDWCTest_Context() {
	return Map(
		"Hwnd", 61001,
		"Control", 61002,
		"InputEpoch", 61003,
		"ProcName", "secure-field-fixture.exe"
	)
}

_SFDWCTest_Request(Context, Terminal) {
	global _SFDWCTest_RequestCount, _SFDWCTest_ReceivedContext
	_SFDWCTest_RequestCount += 1
	_SFDWCTest_ReceivedContext := Context
	return true
}

_SFDWCTest_Start() {
	global _SFDWCTest_StartCount
	_SFDWCTest_StartCount += 1
	return true
}

_SFDWCTest_ContextMatches(WorkerContext, Result, LiveContext) {
	return true
}





; ====================================
; ====================================
; ======= 2/ Dispatch contract =======
; ====================================
; ====================================

_SFDWCTest_ProbeAcceptsChildControlContext() {
	global SFD_FIELD_CACHE, SFD_UIA_IDLE_REQUIRED_MS
	global _SFDWCTest_RequestCount, _SFDWCTest_ReceivedContext
	global _SFDWCTest_StartCount
	SavedCache := SFD_FIELD_CACHE
	SavedIdleRequiredMs := SFD_UIA_IDLE_REQUIRED_MS
	try {
		; Make the probe immediately eligible without depending on ambient mouse
		; input while the complete suite is running.
		SFD_UIA_IDLE_REQUIRED_MS := 0
		SFD_FIELD_CACHE := Map(
			"hwnd", 0,
			"secure", true,
			"at", 0,
			"element_id", "",
			"focus_generation", 61004,
			"verdict_generation", 0,
			"current_element_id", "",
			"focus_hook", 0,
			"focus_callback", 0,
			"focus_tracking_active", false,
			"pending_hwnd", 0,
			"pending_generation", 0
		)
		_SFDWCTest_RequestCount := 0
		_SFDWCTest_ReceivedContext := 0
		_SFDWCTest_StartCount := 0

		AssertTrue(SFD_ProbeFocusedUia(61002, 61004,
			_SFDWCTest_CurrentHwnd, _SFDWCTest_Context, _SFDWCTest_Request,
			_SFDWCTest_Start, _SFDWCTest_ContextMatches),
			"a UIA probe must accept a focused-control owner with a distinct parent HWND")
		AssertEqual(1, _SFDWCTest_RequestCount,
			"the accepted worker request must receive the complete focused-control context")
		AssertTrue(_SFDWCTest_ReceivedContext is Map
			&& _SFDWCTest_ReceivedContext["Hwnd"] = 61001
			&& _SFDWCTest_ReceivedContext["Control"] = 61002,
			"the worker must preserve distinct top-level and child-control identities")
		AssertEqual(0, _SFDWCTest_StartCount,
			"the worker startup fallback must not run when dispatch accepts the request")
	} finally {
		SFD_FIELD_CACHE := SavedCache
		SFD_UIA_IDLE_REQUIRED_MS := SavedIdleRequiredMs
	}
}

Test("SecureField: UIA probe accepts a distinct focused-control token (secure-field-worker-context)",
	_SFDWCTest_ProbeAcceptsChildControlContext)
