; tests/meta/test_kl_refresh_context_blocks_on_keystroke.ahk

; ==============================================================================
; MODULE: Keylogger Canonical Focus Projection Guard
; DESCRIPTION:
; Repairs the false-green test that called a SetTimer context refresh
; "off-thread". Every AHK timer runs on the same cooperative script thread as
; keyboard dispatch. A dedicated timer only becomes safe when its callback is
; memory-only, not merely because the WinGetTitle call moved there.
;
; KL_Hook_RefreshContext now consumes MetricsFocusCache’s canonical bounded
; snapshot. It retains the app/window transition ordering and suspend watermark
; logic, but contains no WinGet, DllCall or second acquisition path. Invalid
; snapshots are refused before any session or transition state mutates.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Keystroke callbacks remain memory-only ===
; =====================================================
; =====================================================

_KRCB_KeystrokeCallbacksDoNotRefreshContext() {
	for FunctionName in ["KL_Hook_OnChar", "KL_Hook_OnKeyDown"] {
		Body := _StripFullLineComments(_DriverFuncBody(FunctionName))
		Assert(Body != "", FunctionName . " must exist in keylogger_hook.ahk")
		Assert(InStr(Body, "KL_Hook_RefreshContext") = 0,
			FunctionName . " must not refresh focus in the in-flight keystroke callback")
		Assert(InStr(Body, "filtered := true") > 0
			&& InStr(Body, "catch as FilterErr") > 0,
			FunctionName . " must default a throwing privacy classification to filtered and log the failure")
	}
}

Test("keylogger focus: keystroke callbacks never refresh context (focus-refresh-bounded-resident)",
	_KRCB_KeystrokeCallbacksDoNotRefreshContext)





; ==========================================================
; ==========================================================
; ======= 2/ Resident projection performs no OS work =======
; ==========================================================
; ==========================================================

_KRCB_ContextProjectionReadsCanonicalMemoryOnly() {
	Body := _StripFullLineComments(_DriverFuncBody("KL_Hook_RefreshContext"))
	Assert(Body != "", "KL_Hook_RefreshContext must exist")
	Assert(InStr(Body, "MF_GetFocusSnapshot()") > 0,
		"KL_Hook_RefreshContext must read the metrics module's canonical focus snapshot")
	for Forbidden in ["WinGetTitle(", "WinGetProcessName(", "WinGetClass(",
		"WinGetID(", "DllCall(", "WICaptureBoundedFocusSnapshot("] {
		Assert(InStr(Body, Forbidden) = 0,
			"the resident keylogger projection must be memory-only; found " . Forbidden)
	}
	ValidPos := InStr(Body, "Snapshot.valid")
	SessionPos := InStr(Body, "Keylogger.session_title := NewTitle")
	Assert(ValidPos > 0 && SessionPos > ValidPos,
		"an invalid canonical snapshot must be rejected before keylogger session context mutates")
}

Test("keylogger focus: resident context timer reads canonical memory only (focus-refresh-bounded-resident)",
	_KRCB_ContextProjectionReadsCanonicalMemoryOnly)





; ===========================================================
; ===========================================================
; ======= 3/ Timer owns projection, never acquisition =======
; ===========================================================
; ===========================================================

_KRCB_ProjectionTimerLifecycleIsPaired() {
	StartBody := _StripFullLineComments(_DriverFuncBody("KL_Hook_Start"))
	StopBody := _StripFullLineComments(_DriverFuncBody("KL_Hook_Stop"))
	Assert(StartBody != "" && StopBody != "",
		"keylogger hook start/stop lifecycle functions must exist")
	Assert(InStr(StartBody, "KL_Hook_RefreshContext.Bind()") > 0
		&& InStr(StartBody, "SetTimer(KLHook.context_timer") > 0,
		"KL_Hook_Start must arm the memory-only context projection timer")
	Assert(InStr(StopBody, "SetTimer(KLHook.context_timer, 0)") > 0,
		"KL_Hook_Stop must cancel the resident projection timer")
	Assert(InStr(StartBody, "WICaptureBoundedFocusSnapshot") = 0,
		"the keylogger lifecycle must not create a second focus acquisition owner")

	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "static CONTEXT_REFRESH_MS :=") > 0,
		"the resident memory-only projection cadence must remain a named constant")
}

Test("keylogger focus: resident projection timer has paired lifecycle (focus-refresh-bounded-resident)",
	_KRCB_ProjectionTimerLifecycleIsPaired)
