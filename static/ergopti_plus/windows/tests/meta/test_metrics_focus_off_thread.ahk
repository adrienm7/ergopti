; tests/meta/test_metrics_focus_off_thread.ahk

; ==============================================================================
; MODULE: Metrics Focus Bounded Resident Refresh Guard
; DESCRIPTION:
; Guards the root cause of the Metrics.FocusRefresh stall. AHK SetTimer does
; not create a background thread: its callback interrupts the same cooperative
; script thread that dispatches keyboard input. Moving WinGetTitle from the
; keystroke callback into a 20 Hz timer therefore preserved the blocking
; WM_GETTEXT wait and made the old "off-thread" regression test false-green.
;
; The resident poll now has exactly one OS acquisition owner. Its title read
; uses SendMessageTimeoutW with BLOCK, ABORTIFHUNG and ERRORONEXIT, never
; NOTIMEOUTIFNOTHUNG, and a deadline no greater than the 5 ms profiler budget.
; Process and class identity use local APIs. Metrics and keylogger then consume
; the same atomically published snapshot from memory.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Resident acquisition is bounded =========
; =====================================================
; =====================================================

_MFO_BoundedNativeTitleTransaction() {
	TitleBody := _StripFullLineComments(_DriverFuncBody("_WIReadTitleBounded"))
	CaptureBody := _StripFullLineComments(
		_DriverFuncBody("WICaptureBoundedFocusSnapshot"))
	Assert(TitleBody != "" && CaptureBody != "",
		"the bounded focus adapter and its title transaction must exist")
	Assert(InStr(TitleBody, "SendMessageTimeoutW") > 0,
		"the resident focus poll must read WM_GETTEXT through SendMessageTimeoutW, not an unbounded WinGetTitle call")
	Assert(InStr(TitleBody, "TimeoutMs") > 0,
		"the title transaction must receive its requested deadline explicitly")
	Assert(InStr(TitleBody,
		"Min(Round(TimeoutMs), WI_FOCUS_TITLE_TIMEOUT_MS)") > 0
		&& InStr(TitleBody, '"UInt", BoundedTimeoutMs') > 0,
		"the actual SendMessageTimeoutW argument must clamp every caller to the canonical hard deadline")
	Assert(InStr(CaptureBody, "_WIReadTitleBounded") > 0,
		"the complete focus acquisition must route its title through the bounded transaction")
	Detach := InStr(CaptureBody, 'Critical("Off")')
	Native := InStr(CaptureBody, "GetForegroundWindow")
	Assert(Detach > 0 && Native > Detach,
		"the adapter itself must detach inherited Critical before any native acquisition so an outer caller cannot recreate a non-interruptible wait")

	for Forbidden in ["WinGetTitle(", "WinGetProcessName(", "WinGetClass(",
		"WinGetID("] {
		Assert(InStr(TitleBody . CaptureBody, Forbidden) = 0,
			"the canonical resident acquisition must not contain the unbounded " . Forbidden . " API")
	}

	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "WI_FOCUS_TITLE_TIMEOUT_MS\s*:=\s*(\d+)", &Timeout),
		"the bounded focus adapter must declare a numeric title deadline")
	Assert(Integer(Timeout[1]) > 0 && Integer(Timeout[1]) <= 5,
		"the title deadline must be positive and no greater than the 5 ms hot-path profiler budget")
	Assert(RegExMatch(Src, "WI_SMTO_BOUNDED_FLAGS\s*:=\s*(0x[0-9A-Fa-f]+|\d+)",
		&FlagsMatch), "the bounded SendMessageTimeout flags must be explicit")
	Flags := Integer(FlagsMatch[1])
	Assert((Flags & 0x0001) && (Flags & 0x0002) && (Flags & 0x0020),
		"SendMessageTimeoutW must use BLOCK, ABORTIFHUNG and ERRORONEXIT")
	Assert((Flags & 0x0008) = 0,
		"SMTO_NOTIMEOUTIFNOTHUNG must stay absent because it disables the deadline while the target pumps messages")
}

Test("metrics focus: resident WM_GETTEXT has a hard OS deadline (focus-refresh-bounded-resident)",
	_MFO_BoundedNativeTitleTransaction)





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
