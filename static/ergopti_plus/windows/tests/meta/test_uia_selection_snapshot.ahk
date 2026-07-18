; tests/meta/test_uia_selection_snapshot.ahk
#Requires AutoHotkey v2.0

Test_UIASelectionCacheIsWindowBoundAndSingleUse() {
	Getter := _DriverFuncBody("GetUIASelection")
	Poller := _DriverFuncBody("_UIA_SelectionPollTick")
	Watcher := _DriverFuncBody("_OnPrefixChar")
	Assert(InStr(Poller, "Hwnd: WinExist") > 0 and InStr(Poller, "CapturedAt: A_TickCount") > 0,
		"UIA poll must publish a window-bound, timestamped selection snapshot")
	Assert(InStr(Getter, "Snapshot.Hwnd != WinExist") > 0,
		"UIA consumer must reject a selection from a different foreground window")
	Assert(InStr(Getter, "Elapsed > UIA_SELECTION_MAX_AGE_MS") > 0,
		"UIA consumer must reject expired selection snapshots")
	Assert(InStr(Getter, "Snapshot.Consumed := true") > 0,
		"UIA consumer must consume a selection exactly once")
	Assert(InStr(Watcher, "_UIA_SelectionCache := 0") > 0,
		"a non-wrapping physical character must invalidate a pending UIA selection")
}
Test("UIA selection: snapshot is fresh, window-bound, and single-use", Test_UIASelectionCacheIsWindowBoundAndSingleUse)
