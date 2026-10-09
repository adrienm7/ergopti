; tests/meta/test_metrics_focus_off_thread.ahk

; ==============================================================================
; MODULE: Metrics Focus Non-blocking Resident Refresh Guard
; DESCRIPTION:
; Guards the root cause of the Metrics.FocusRefresh stall. AHK SetTimer does
; not create a background thread: its callback interrupts the same cooperative
; script thread that dispatches keyboard input. Moving WinGetTitle from the
; keystroke callback into a 20 Hz timer therefore preserved the blocking
; WM_GETTEXT wait and made the old "off-thread" regression test false-green.
;
; The resident poll now has exactly one OS acquisition owner. Its title read
; uses GetWindowTextW's system-owned top-level caption path, never a target
; WM_GETTEXT. Process identity is retained behind one live kernel handle, so
; OpenProcess and QueryFullProcessImageNameW run only when the PID changes or
; exits. Metrics and keylogger consume the same atomic snapshot from memory.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Resident acquisition cannot message target
; =====================================================
; =====================================================

_MFO_ResidentAcquisitionUsesLocalMetadata() {
	TitleBody := _StripFullLineComments(
		_DriverFuncBody("_WIReadForegroundTitleLocal"))
	CaptureBody := _StripFullLineComments(
		_DriverFuncBody("WICaptureBoundedFocusSnapshot"))
	CacheBody := _StripFullLineComments(
		_DriverFuncBody("_WIReadProcessIdentityCached"))
	AcquireBody := _StripFullLineComments(
		_DriverFuncBody("_WIAcquireProcessIdentity"))
	Assert(TitleBody != "" && CaptureBody != "" && CacheBody != ""
		&& AcquireBody != "",
		"the focus adapter, local title read and process cache must exist")
	Assert(InStr(TitleBody, "GetWindowTextW") > 0,
		"the resident poll must read the system-owned top-level caption")
	for Forbidden in ["SendMessage", "WinGetTitle("]
		Assert(InStr(TitleBody, Forbidden) = 0,
			"the resident title path must never enter the target window procedure through " . Forbidden)
	Assert(InStr(CaptureBody, "_WIReadForegroundTitleLocal") > 0,
		"the complete focus acquisition must route its title through the local primitive")
	Assert(InStr(CaptureBody, "_WIReadProcessIdentityCached") > 0,
		"the 20 Hz acquisition must resolve process metadata through the identity cache")
	Assert(InStr(CacheBody, "_WIFocusProcessHandleAlive") > 0
		&& InStr(CacheBody, "WIFocusProcessCache.process_id = ProcessId") > 0,
		"cache hits must require the same PID and a still-live retained handle")
	Assert(InStr(AcquireBody, "OpenProcess") > 0
		&& InStr(AcquireBody, "QueryFullProcessImageNameW") > 0
		&& InStr(AcquireBody, "WI_PROCESS_SYNCHRONIZE") > 0,
		"the cold identity resolver must query the process and retain a waitable handle")
	for Forbidden in ["OpenProcess", "QueryFullProcessImageNameW",
		"SendMessageTimeoutW"] {
		Assert(InStr(CaptureBody, Forbidden) = 0,
			"the resident capture body must not directly execute " . Forbidden)
	}
	Detach := InStr(CaptureBody, 'Critical("Off")')
	Native := InStr(CaptureBody, "GetForegroundWindow")
	Assert(Detach > 0 && Native > Detach,
		"the adapter itself must detach inherited Critical before any native acquisition so an outer caller cannot recreate a non-interruptible wait")
}

Test("metrics focus: resident acquisition uses local cached metadata (focus-refresh-resident-stall)",
	_MFO_ResidentAcquisitionUsesLocalMetadata)





; =======================================================
; =======================================================
; ======= 2/ Consumers never reacquire focus ============
; =======================================================
; =======================================================

_MFO_ConsumersReadOneCanonicalSnapshot() {
	FilterBody := _StripFullLineComments(_DriverFuncBody("MF_ShouldFilter"))
	RefreshBody := _StripFullLineComments(
		_DriverFuncBody("_MF_RefreshFocusNonCritical"))
	KeyloggerBody := _StripFullLineComments(
		_DriverFuncBody("KL_Hook_RefreshContext"))
	Assert(FilterBody != "" && RefreshBody != "" && KeyloggerBody != "",
		"metrics and keylogger focus consumers must all be discoverable")
	Assert(InStr(FilterBody, "MF_GetFocusSnapshot()") > 0,
		"MF_ShouldFilter must consume the canonical published snapshot")
	Assert(InStr(KeyloggerBody, "MF_GetFocusSnapshot()") > 0,
		"KL_Hook_RefreshContext must consume the same canonical snapshot")
	Assert(InStr(RefreshBody, "WICaptureBoundedFocusSnapshot") > 0,
		"the metrics refresh owner must be the sole caller of the bounded OS adapter")
	for Body in [FilterBody, KeyloggerBody] {
		for Forbidden in ["WinGetTitle(", "WinGetProcessName(", "WinGetClass(",
			"WinGetID(", "WICaptureBoundedFocusSnapshot("] {
			Assert(InStr(Body, Forbidden) = 0,
				"a focus consumer must read memory only, never reacquire through " . Forbidden)
		}
	}
}

Test("metrics focus: metrics and keylogger share one acquisition owner (focus-refresh-bounded-resident)",
	_MFO_ConsumersReadOneCanonicalSnapshot)





; =========================================================
; =========================================================
; ======= 3/ Native work escapes inherited Critical =======
; =========================================================
; =========================================================

_MFO_NativeProbeIsOutsideCritical() {
	Wrapper := _StripFullLineComments(_DriverFuncBody("MF_RefreshFocus"))
	Native := _StripFullLineComments(
		_DriverFuncBody("_MF_RefreshFocusNonCritical"))
	Assert(Wrapper != "" && Native != "",
		"focus refresh wrapper and native implementation must exist")
	Assert(InStr(Wrapper, 'Critical("Off")') > 0,
		"MF_RefreshFocus must explicitly detach an inherited Critical span before native acquisition")
	Assert(InStr(Native, "WICaptureBoundedFocusSnapshot") > 0,
		"the non-Critical implementation must own the native acquisition")
	Assert(InStr(Native, 'Critical("On")') = 0,
		"the function containing the native acquisition must not open a Critical span")
}

Test("metrics focus: native acquisition cannot inherit Critical (focus-refresh-bounded-resident)",
	_MFO_NativeProbeIsOutsideCritical)
