; tests/unit/menu/builder/test_tray_suspend_checkmark.ahk

; ==============================================================================
; MODULE: Tray Suspend Checkmark Behaviour Tests
; DESCRIPTION:
; Regression guard for tray-suspend-checkmark-cleared-by-rebuild, replacing a
; source read of _MI_StageSuspend with its real behaviour under a real pause.
;
; TrayMenuStage_Publish deletes and replays the whole tray root, and the state
; watchdog only reacts to pause transitions, so a rebuild while paused left
; « Suspendre » unchecked on a paused driver; clicking it then resumed. The row
; must carry its own checked state at its single construction point. Why the
; row has to own it (publication wipes the root, the watchdog returns early)
; stays a source read in tests/meta/menu, since those owners mutate the real
; tray or are not loaded by this runner.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================================
; ========================================================
; ======= 1/ Staging the suspend row under a pause =======
; ========================================================
; ========================================================

; Stages the suspend row alone into a private stage, with the native pause set
; to Paused, and restores the runner's stage and pause state after.
; @param {Boolean} Paused - Whether the driver is paused while the row stages.
; @returns {Array} The records the real staging owner pushed.
_TSCB_StageSuspendRow(Paused) {
	global _TrayMenuStage
	SavedStage := _TrayMenuStage
	WasSuspended := A_IsSuspended
	try {
		_TrayMenuStage := false
		Stage := TrayMenuStage_Begin()
		Suspend(Paused ? 1 : 0)
		try _MI_StageSuspend()
		finally Suspend(WasSuspended ? 1 : 0)
		return Stage
	} finally _TrayMenuStage := SavedStage
}

_TSCB_PausedRowStagesItsCheck() {
	global MenuSuspend
	Stage := _TSCB_StageSuspendRow(true)
	AssertEqual(2, Stage.Length, "a paused rebuild stages the row and its checkmark")
	AssertEqual("action", Stage[1]["kind"], "the row itself is staged first")
	AssertEqual(MenuSuspend, Stage[1]["label"], "the staged row is the suspend row")
	AssertEqual("check", Stage[2]["kind"],
		"a paused rebuild must re-assert the suspend checkmark, or clicking the row resumes the driver")
	AssertEqual(MenuSuspend, Stage[2]["label"], "the checkmark addresses the suspend row")
}
Test("tray: the staged suspend row re-asserts its checkmark when paused (tray-suspend-checkmark-cleared-by-rebuild)",
	_TSCB_PausedRowStagesItsCheck)

_TSCB_RunningRowStagesNoCheck() {
	global MenuSuspend
	Stage := _TSCB_StageSuspendRow(false)
	AssertEqual(1, Stage.Length, "a running rebuild stages the row alone")
	AssertEqual("action", Stage[1]["kind"], "the row is an action")
	AssertEqual(MenuSuspend, Stage[1]["label"], "the staged row is the suspend row")
}
Test("tray: the staged suspend row is unchecked while running (tray-suspend-checkmark-cleared-by-rebuild)",
	_TSCB_RunningRowStagesNoCheck)
