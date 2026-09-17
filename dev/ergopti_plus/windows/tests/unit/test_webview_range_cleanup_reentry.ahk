; tests/unit/test_webview_range_cleanup_reentry.ahk

; ==============================================================================
; MODULE: WebView Range Cleanup Reentry Tests
; DESCRIPTION: Native deletion refusal cannot let an older delivery overwrite a successor.
; ==============================================================================

#Requires AutoHotkey v2.0

_WRCR_Replace(View, Lines, Unhandled, Failure) {
	global _KLPF_CLEANUP_DEBTS, _KLPF_CLEANUP_TIMER
	SavedDebts := _KLPF_CLEANUP_DEBTS
	SavedTimer := _KLPF_CLEANUP_TIMER
	SavedSchedule := KLPFWorker.cleanup_schedule_fn
	First := _CTU_NewPath()
	Second := _CTU_NewPath()
	Third := _CTU_NewPath()
	Entry := Map("epoch", 51, "webview", View)
	KLWV.windows := Map("typing", Entry)
	Callbacks := []
	Lock := 0
	Schedule(Callback, Delay) {
		Callbacks.Push(Callback)
		AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 44, "ok", Third))
		return true
	}
	try {
		_KLPF_CLEANUP_DEBTS := Map()
		_KLPF_CLEANUP_TIMER := 0
		KLPFWorker.cleanup_schedule_fn := Schedule
		for Stage in [First, Second, Third]
			AssertTrue(FSWrite(Stage, "{}"))
		AssertTrue(KLWV_OnRangeBuildTerminal("typing", 51, 42, "ok", First))
		MountedFirst := Entry["range_stage"]["stage"]
		Lock := FileOpen(MountedFirst, "r-d", "UTF-8-RAW")
		AssertTrue(IsObject(Lock), "deny deletion through a real Windows file handle")
		AssertFalse(KLWV_OnRangeBuildTerminal("typing", 51, 43, "ok", Second),
			"a delivery replaced during cleanup must not submit its stale script")
		AssertEqual(Third . ".mount\range.json", Entry["range_stage"]["stage"])
		AssertFalse(FSExists(Second))
		AssertTrue(FSExists(Third . ".mount\range.json"))
		AssertTrue(FSExists(MountedFirst))
		AssertTrue(_KLPF_CLEANUP_DEBTS.Has(MountedFirst), "a native lock keeps exact retry ownership")
		AssertEqual(2, View.Scripts.Length, "only the original and latest scripts may be submitted")
		AssertEqual(1, Callbacks.Length)
		Lock.Close()
		Lock := 0
		Callbacks[1].Call()
		AssertFalse(FSExists(MountedFirst))
		AssertFalse(DirExist(First . ".mount"))
		AssertEqual(0, _KLPF_CLEANUP_DEBTS.Count)
		AssertEqual(0, _KLPF_CLEANUP_TIMER)
		KLWV_Close("typing")
		AssertFalse(DirExist(Third . ".mount"))
	} finally {
		if IsObject(Lock)
			Lock.Close()
		KLWV_RetireRangeStage(Entry)
		for Stage in [First, Second, Third]
			FSDelete(Stage)
		_KLPF_CLEANUP_DEBTS := SavedDebts
		_KLPF_CLEANUP_TIMER := SavedTimer
		KLPFWorker.cleanup_schedule_fn := SavedSchedule
	}
}
Test("WebView range stage: locked cleanup preserves reentrant successor (range-stage-owner)",
	_WVSO_WithFixture.Bind(_WRCR_Replace))
