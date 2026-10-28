; tests/unit/ui/wpm/test_wpm_region_target.ahk

; ==============================================================================
; MODULE: WPM Region Target Tests
; DESCRIPTION:
; Issue #103: the compact widget is built hidden, and its rounded region was
; applied through an "ahk_id N" WinTitle search that skips hidden windows, so
; every start-up raised an uncaught TargetError. Building a never-shown widget
; must succeed, a destroyed window must be a reported no-op, and a failure on a
; window that still exists must still surface.
; ==============================================================================

#Requires AutoHotkey v2.0

global _WRT_SavedProps := ["_gui", "_lbl_wpm", "_lbl_unit", "_lbl_strip"]

_WRT_NeverShownCompactBuildsWithHiddenWindowsOff() {
	AssertTrue(WPMWidget_LoadSharedConst(), "every canon key must load")
	Saved := Map()
	for Name in _WRT_SavedProps
		if WPMWidget.HasOwnProp(Name)
			Saved[Name] := WPMWidget.%Name%
	PriorHidden := A_DetectHiddenWindows
	Built := 0
	try {
		DetectHiddenWindows(false)
		WPMWidget._gui := false
		WPMWidget_BuildCompact()
		Built := WPMWidget._gui
		AssertTrue(Built is Gui, "a never-shown compact widget must be built and published")
		AssertTrue(DllCall("User32\IsWindow", "Ptr", Built.Hwnd, "Int") != 0,
			"the published compact widget must own a live window")
	} finally {
		DetectHiddenWindows(PriorHidden)
		; BuildCompact registers the production drag-end handler; the headless
		; runner never does, so the fixture releases it with the window.
		OnMessage(0x0232, WPMWidget_DragEnd, 0)
		if Built is Gui
			Built.Destroy()
		for Name in _WRT_SavedProps
			if Saved.Has(Name)
				WPMWidget.%Name% := Saved[Name]
			else if WPMWidget.HasOwnProp(Name)
				WPMWidget.DeleteProp(Name)
	}
}
Test("WPM region: a never-shown compact widget builds with hidden windows off (wpm-region-target)",
	_WRT_NeverShownCompactBuildsWithHiddenWindowsOff)

_WRT_DestroyedWindowIsAReportedNoOp() {
	Surface := Gui("-Caption +ToolWindow")
	Hwnd := Surface.Hwnd
	Surface.Destroy()
	Calls := 0
	CountRegion(*) {
		Calls += 1
	}
	AssertFalse(_WPMWidget_ApplyRoundedRegion(Hwnd, 80, 40, 16, CountRegion),
		"a destroyed window must be reported as not clipped instead of raising")
	AssertEqual(0, Calls, "no region call may reach a window that is gone")
}
Test("WPM region: a destroyed window is a reported no-op (wpm-region-target)",
	_WRT_DestroyedWindowIsAReportedNoOp)

_WRT_NeverShownWindowIsClipped() {
	Surface := Gui("-Caption +ToolWindow")
	PriorHidden := A_DetectHiddenWindows
	try {
		DetectHiddenWindows(false)
		AssertTrue(_WPMWidget_ApplyRoundedRegion(Surface.Hwnd, 80, 40, 16),
			"a never-shown window this driver owns must be clipped")
	} finally {
		DetectHiddenWindows(PriorHidden)
		Surface.Destroy()
	}
}
Test("WPM region: a never-shown window is clipped (wpm-region-target)",
	_WRT_NeverShownWindowIsClipped)

_WRT_CloseRaceIsAReportedNoOp() {
	Surface := Gui("-Caption +ToolWindow")
	CloseThenRefuse(*) {
		Surface.Destroy()
		throw TargetError("Target window not found.")
	}
	AssertFalse(_WPMWidget_ApplyRoundedRegion(Surface.Hwnd, 80, 40, 16, CloseThenRefuse),
		"a window closed during the region call must be reported as not clipped")
}
Test("WPM region: a window closed mid-call is a reported no-op (wpm-region-target)",
	_WRT_CloseRaceIsAReportedNoOp)

; Returns the Type of the error Callback raised, or "" when it returned.
_WRT_ThrownType(Callback) {
	try Callback()
	catch as Err
		return Type(Err)
	return ""
}

_WRT_FailuresOnALiveWindowSurface() {
	Surface := Gui("-Caption +ToolWindow")
	try {
		RefuseTarget(*) {
			throw TargetError("Target window not found.")
		}
		RefuseOs(*) {
			throw OSError(5)
		}
		AssertEqual("TargetError",
			_WRT_ThrownType(() => _WPMWidget_ApplyRoundedRegion(Surface.Hwnd, 80, 40, 16, RefuseTarget)),
			"a TargetError on a window that still exists must surface")
		AssertEqual("OSError",
			_WRT_ThrownType(() => _WPMWidget_ApplyRoundedRegion(Surface.Hwnd, 80, 40, 16, RefuseOs)),
			"a non-target failure must surface")
		AssertEqual("TypeError",
			_WRT_ThrownType(() => _WPMWidget_ApplyRoundedRegion("ahk_id " . Surface.Hwnd, 80, 40, 16)),
			"a WinTitle string must be rejected: it skips hidden windows")
	} finally Surface.Destroy()
}
Test("WPM region: failures on a live window still surface (wpm-region-target)",
	_WRT_FailuresOnALiveWindowSurface)

; The ownership check lives in the window adapter (the OS-purity ratchet keeps
; raw DllCall out of ui/); its three outcomes are what the region relies on.
_WRT_OwnershipCheckIsTheAdapters() {
	Surface := Gui("-Caption +ToolWindow")
	Hwnd := Surface.Hwnd
	PriorHidden := A_DetectHiddenWindows
	try {
		DetectHiddenWindows(false)
		AssertTrue(WMHandleOwnedByThisProcess(Hwnd), "a hidden window this process created is its own")
	} finally {
		DetectHiddenWindows(PriorHidden)
		Surface.Destroy()
	}
	AssertFalse(WMHandleOwnedByThisProcess(Hwnd), "a destroyed window is no longer owned")
	Desktop := DllCall("User32\GetDesktopWindow", "Ptr")
	AssertTrue(DllCall("User32\IsWindow", "Ptr", Desktop, "Int") != 0, "the desktop window must exist")
	AssertFalse(WMHandleOwnedByThisProcess(Desktop), "a live window of another process is not owned")
}
Test("WPM region: window ownership goes through the window adapter (wpm-region-target)",
	_WRT_OwnershipCheckIsTheAdapters)
