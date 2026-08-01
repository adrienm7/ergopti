; tests/meta/test_metrics_focus_off_thread.ahk

; ==============================================================================
; MODULE: Metrics Focus Off-Thread Refresh Guard
; DESCRIPTION:
; Guards that MF_ShouldFilter() does NOT call a synchronous focus acquisition
; (no MF_RefreshFocus, no WinGetTitle/WinGetID/WinGetProcessName/WinGetClass
; inside the predicate). The focus cache must be refreshed off the keystroke
; thread via the periodic timer started by MF_StartFocusRefresh().
;
; Before the fix, MF_ShouldFilter called MF_RefreshFocus() as its first line,
; which did blocking Win32 window queries on the low-level keyboard hook thread
; — contradicting the codebase's own invariant that WinGetTitle/WinGetProcessName
; must never land on a keystroke callback (they send WM_GETTEXT to the foreground
; window and block when that window is busy/Not-Responding).
; ==============================================================================

#Requires AutoHotkey v2.0


_MetaCheckMetricsFocusOffThread() {
	Body := _DriverFuncBody("MF_ShouldFilter")
	Assert(Body != "", "MF_ShouldFilter() must exist in metrics_filters.ahk")

	; Must NOT call MF_RefreshFocus synchronously.
	Assert(!InStr(Body, "MF_RefreshFocus("),
		"MF_ShouldFilter must NOT call MF_RefreshFocus() — the focus cache is refreshed off-thread by the periodic timer")

	; Must NOT contain any blocking WinGet* call inline.
	for fn in ["WinGetTitle", "WinGetID", "WinGetProcessName", "WinGetClass"] {
		Assert(!InStr(Body, fn . "("),
			"MF_ShouldFilter must NOT call " . fn . "() on the keystroke thread")
	}

	; The file must register the refresh off-thread.
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\infra\metrics\metrics_filters.ahk")
	Assert(Src != "", "metrics_filters.ahk must be readable")
	Assert(InStr(Src, "SetTimer(MF_RefreshFocus") > 0,
		"metrics_filters.ahk must set a periodic timer on MF_RefreshFocus (off-thread focus cache refresh)")
	Assert(InStr(Src, "MF_StartFocusRefresh") > 0,
		"metrics_filters.ahk must define MF_StartFocusRefresh() to arm the off-thread refresh timer")
}

Test("meta metrics filters: MF_ShouldFilter does not block on WinGet* (focus cache refreshed off-thread)",
	_MetaCheckMetricsFocusOffThread)
