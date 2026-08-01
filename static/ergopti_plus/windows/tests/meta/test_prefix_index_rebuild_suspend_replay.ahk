; tests/meta/test_prefix_index_rebuild_suspend_replay.ahk

; ==============================================================================
; MODULE: Prefix-index rebuild defers under suspend and replays on resume
; DESCRIPTION:
; HotstringPrefixWatcherRebuildIndex early-returns on A_IsSuspended (pause
; invariant), but it dropped the request with no re-arm. A live hotstring section
; toggle made while suspended rebuilt the ENGINE registry (registration has no
; suspend gate) but left the preview INDEX unchanged, so after resume the tooltip
; kept advertising the disabled section's expansion while the engine would not fire
; it. Every other suspend-blocked subsystem defers and replays (LLM_Menu_OnResume);
; the index rebuild must too. (F19, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_PIRS_SuspendDefersAndResumeReplays() {
	Rebuild := _DriverFuncBody("HotstringPrefixWatcherRebuildIndex")
	Resume := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Rebuild != "", "HotstringPrefixWatcherRebuildIndex must exist in infra/hotstrings/hotstring_inputhook.ahk")
	Assert(Resume != "", "Ergopti_OnSuspendResume must exist in infra/lifecycle.ahk")

	SuspendPos := InStr(Rebuild, "A_IsSuspended")
	PendPos := InStr(Rebuild, "_PrefixIndexRebuildPending := true")
	Assert(SuspendPos > 0, "HotstringPrefixWatcherRebuildIndex must guard on A_IsSuspended")
	Assert(PendPos > SuspendPos,
		"the suspended rebuild must record _PrefixIndexRebuildPending := true (defer), not silently drop the request")

	Assert(InStr(Resume, "_PrefixIndexRebuildPending") > 0 && InStr(Resume, "HotstringPrefixWatcherRebuildIndex") > 0,
		"Ergopti_OnSuspendResume must replay the deferred prefix-index rebuild so the preview index re-syncs with the engine")
}
Test("hotstrings: prefix-index rebuild during suspend is deferred and replayed on resume",
	_PIRS_SuspendDefersAndResumeReplays)
