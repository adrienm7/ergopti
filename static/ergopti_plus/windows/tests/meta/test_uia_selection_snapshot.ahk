; tests/meta/test_uia_selection_snapshot.ahk
#Requires AutoHotkey v2.0

Test_UIASelectionCacheIsWindowBoundAndSingleUse() {
	Getter := _DriverFuncBody("GetUIASelection")
	Publisher := _DriverFuncBody("_UIA_OnSelectionWorkerTerminal")
	Watcher := _DriverFuncBody("_OnPrefixChar")
	Assert(InStr(Publisher, "Hwnd: Context") > 0
		and InStr(Publisher, "Control: Context") > 0
		and InStr(Publisher, "InputEpoch: Context") > 0
		and InStr(Publisher, "CapturedAt: A_TickCount") > 0,
		"UIA worker terminal must publish a window/control/input-generation-bound timestamped snapshot")
	Assert(InStr(Publisher, "UIASW_ContextMatches") > 0,
		"UIA worker result must be compared against both requested and live context before publication")
	CriticalPos := InStr(Publisher, 'Critical("On")')
	ContextPos := InStr(Publisher, "UIASW_ContextMatches")
	PublishPos := InStr(Publisher, "_UIA_SelectionCache := {")
	RestorePos := InStr(Publisher, 'Critical(PreviousCritical ? PreviousCritical : "Off")')
	Assert(CriticalPos > 0 && ContextPos > CriticalPos && PublishPos > ContextPos
		&& RestorePos > PublishPos,
		"live-context validation and cache publication must share one Critical transaction, or a physical character can clear the old cache between them and have stale UIA text republished afterward")
	Assert(InStr(Getter, "Snapshot.Hwnd != WIGetForegroundHwnd") > 0,
		"UIA consumer must reject a selection from a different foreground window")
	Assert(InStr(Getter, "Snapshot.Control != WIGetFocusedControlToken") > 0,
		"UIA consumer must reject a selection from a different focused control")
	Assert(InStr(Getter, "Elapsed > UIA_SELECTION_MAX_AGE_MS") > 0,
		"UIA consumer must reject expired selection snapshots")
	Assert(InStr(Getter, "Snapshot.Consumed := true") > 0,
		"UIA consumer must consume a selection exactly once")
	Assert(InStr(Watcher, "_UIA_SelectionCache := 0") > 0,
		"a non-wrapping physical character must invalidate a pending UIA selection")
}
Test("UIA selection: snapshot is fresh, window-bound, and single-use", Test_UIASelectionCacheIsWindowBoundAndSingleUse)
