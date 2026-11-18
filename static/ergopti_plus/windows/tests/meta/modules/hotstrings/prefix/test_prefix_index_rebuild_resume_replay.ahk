; tests/meta/modules/hotstrings/prefix/test_prefix_index_rebuild_resume_replay.ahk

; ==============================================================================
; MODULE: Prefix-index rebuild replays on resume
; DESCRIPTION:
; HotstringPrefixWatcherRebuildIndex refuses to run while paused, and once
; dropped the request with no re-arm. A live hotstring section toggle made
; while paused rebuilt the ENGINE registry (registration has no pause gate) but
; left the preview INDEX unchanged, so after resume the tooltip kept advertising
; the disabled section's expansion while the engine would not fire it. Every
; other pause-blocked subsystem defers and replays (LLM_Menu_OnResume); the
; index rebuild must too. (F19, audit 2026-07-20.)
;
; The deferral itself (the paused rebuild records _PrefixIndexRebuildPending)
; is called under a real Suspend in
; tests/unit/modules/hotstrings/prefix/test_prefix_deferred_pause.ahk. The
; replay stays a source scan: Ergopti_OnSuspendResume lives in the lifecycle
; owner, which the headless runner cannot include.
; ==============================================================================

#Requires AutoHotkey v2.0

_PIRS_ResumeReplaysDeferredRebuild() {
	Resume := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Resume != "", "Ergopti_OnSuspendResume must exist in core/lifecycle/engine/lifecycle.ahk")
	Assert(InStr(Resume, "_PrefixIndexRebuildPending") > 0 && InStr(Resume, "HotstringPrefixWatcherRebuildIndex") > 0,
		"Ergopti_OnSuspendResume must replay the deferred prefix-index rebuild so the preview index re-syncs with the engine")
}
Test("hotstrings: a prefix-index rebuild deferred by a pause is replayed on resume",
	_PIRS_ResumeReplaysDeferredRebuild)
