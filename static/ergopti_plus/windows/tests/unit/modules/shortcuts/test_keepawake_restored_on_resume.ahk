; tests/unit/modules/shortcuts/test_keepawake_restored_on_resume.ahk

; ==============================================================================
; MODULE: Keep-Awake Restored On Resume
; DESCRIPTION:
; The maintainer's decision of 2026-11-14: a pause stops keep-awake and the
; resume gives it back as it was, as on macOS. Windows stopped it at pause and
; left it off after the resume (paused-keepawake-restore).
; ==============================================================================

_KAR_RestoresWhatRanAtPause() {
	global _LifecycleKeepAwakeAtPause
	Saved := _LifecycleKeepAwakeAtPause
	Starts := Map("count", 0)
	Start := () => (Starts["count"] += 1, true)
	try {
		_LifecycleKeepAwakeAtPause := false
		AssertTrue(_LifecycleRestoreKeepAwake(Start))
		AssertEqual(0, Starts["count"], "keep-awake off at the pause stays off after the resume")
		_LifecycleKeepAwakeAtPause := true
		AssertTrue(_LifecycleRestoreKeepAwake(Start))
		AssertEqual(1, Starts["count"], "keep-awake on at the pause starts again on resume")
		AssertFalse(_LifecycleKeepAwakeAtPause, "the restore happens once")
		AssertTrue(_LifecycleRestoreKeepAwake(Start))
		AssertEqual(1, Starts["count"], "a second resume starts nothing")
		_LifecycleKeepAwakeAtPause := true
		AssertFalse(_LifecycleRestoreKeepAwake(() => false), "a refused restart is reported")
	} finally _LifecycleKeepAwakeAtPause := Saved
}

_KAR_ReactorsRecordAndRestore() {
	Enter := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Resume := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Enter != "" && Resume != "", "both suspend reactors must be readable")
	RecordAt := InStr(Enter, "_LifecycleKeepAwakeAtPause := IsSet(ActivitySimulation) && ActivitySimulation")
	StopAt := InStr(Enter, "() => StopActivitySimulation(), true)")
	Assert(RecordAt > 0 && StopAt > RecordAt, "the pause records keep-awake before stopping it")
	FinishAt := InStr(Resume, "LifecycleTransitionFinish(Transition)")
	RestoreAt := InStr(Resume, "_LifecycleRestoreKeepAwake()")
	Assert(RestoreAt > FinishAt && FinishAt > 0, "the resume restores keep-awake once the transition settled")
}

Test("keep-awake: the resume restores what ran at the pause (paused-keepawake-restore)", _KAR_RestoresWhatRanAtPause)
Test("keep-awake: the suspend reactors record and restore it (paused-keepawake-restore)", _KAR_ReactorsRecordAndRestore)
