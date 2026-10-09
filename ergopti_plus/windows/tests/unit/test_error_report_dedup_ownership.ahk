; tests/unit/test_error_report_dedup_ownership.ahk

; ==============================================================================
; MODULE: Error Report Dedup Ownership Tests
; DESCRIPTION: Deferred report failures may release only their own admission.
; ==============================================================================

#Requires AutoHotkey v2.0

_ERDO_StaleFailure(ClearAndReuseTick) {
	Cache := Map()
	OldRelease := _ErgoptiRememberErrorReport(Cache, "synthetic-error", 10)
	if ClearAndReuseTick
		Cache.Clear()
	NewRelease := _ErgoptiRememberErrorReport(Cache, "synthetic-error", ClearAndReuseTick ? 10 : 70000)
	Current := Cache["synthetic-error"]
	; Exercise the actual failed-worker completion path without starting a worker
	; or entering the global handler's modifier/notification paths.
	_CrashReport_WorkerDone(OldRelease, 1, "", "synthetic report refusal")
	AssertTrue(Cache.Has("synthetic-error"),
		"a stale worker failure must preserve the newer report's throttle")
	AssertTrue(Cache["synthetic-error"] == Current,
		"the exact newer admission must survive, even when ticks are equal")
	NewRelease.Call()
	AssertFalse(Cache.Has("synthetic-error"),
		"the current failed report must remain able to release its own throttle")
}

_ERDO_CurrentAndRepeatedFailure() {
	Cache := Map()
	PreviousCritical := A_IsCritical
	Release := _ErgoptiRememberErrorReport(Cache, "synthetic-error", 10)
	OtherRelease := _ErgoptiRememberErrorReport(Cache, "other-error", 10)
	Release.Call()
	AssertEqual(PreviousCritical, A_IsCritical, "release must restore the caller's interruptibility")
	AssertFalse(Cache.Has("synthetic-error"))
	AssertTrue(Cache.Has("other-error"), "a failed report must not clear other signatures")
	; Startup refusal and eventual worker failure can both report the same owner.
	Release.Call()
	AssertEqual(PreviousCritical, A_IsCritical, "an obsolete release must restore interruptibility too")
	AssertTrue(Cache.Has("other-error"), "duplicate release must be harmless")
	OtherRelease.Call()
	AssertEqual(0, Cache.Count)
}

for ClearAndReuseTick in [false, true]
	Test("error report: stale failure preserves admission reuse=" . ClearAndReuseTick
		. " (error-report-dedup-ownership)", _ERDO_StaleFailure.Bind(ClearAndReuseTick))
Test("error report: current and repeated failures preserve unrelated admissions "
	. "(error-report-dedup-ownership)", _ERDO_CurrentAndRepeatedFailure)
