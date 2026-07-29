; tests/meta/test_updater_releases_list_cancellable.ahk

; ==============================================================================
; MODULE: Updater Async-Cancellation Coverage Meta Test
; DESCRIPTION:
; Static source guard for updater-releases-list-uncancellable.
;
; The updater had TWO structurally identical async fetch/poll pairs and only one
; of them was cancellable. _Updater_FetchLatestJsonAsync registers each request
; in the shared _UpdaterAsyncRequests map and _Updater_PollAsync no-ops once its
; id has been dropped — that map IS the whole cancellation mechanism, since
; _Updater_CancelAsyncChecks cancels by snapshotting and Clear()ing it and does
; nothing else. _Updater_FetchReleasesListJsonAsync / _Updater_PollReleasesList-
; Async were written as a standalone pair carrying their state in closure
; arguments instead, so there was no registry entry to delete: the
; `try _Updater_CancelAsyncChecks()` that Ergopti_OnSuspendEnter runs to honour
; "pause = tout eteint" was a no-op for the changelog fetch, and its 250 ms poll
; timer plus a live WinHTTP request kept running for the whole poll budget
; (UPDATER_ASYNC_MAX_POLLS x UPDATER_ASYNC_POLL_MS, about 85 s) through a pause.
;
; Nothing user-visible happened while paused (the terminal callback IS guarded),
; so the only symptoms were a background timer and network traffic during a
; pause — neither of which is logged above DEBUG, and neither of which reaches
; the errors-only sink.
;
; This guard is derived from source rather than naming today's functions: the
; request class is "every _Updater_Fetch*Async" and the poll class is "every
; _Updater_Poll*Async that waits on a WinHTTP response", so a third async pair
; added tomorrow is enrolled automatically instead of quietly repeating the same
; omission. Meta-static because reproducing it needs a real WinHTTP request and
; a real suspend.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Derive the async request classes =======
; ===================================================
; ===================================================

; Names of every top-level function matching Pattern, derived from driver source.
_URLC_MatchingFunctions(Pattern) {
	Src := _DriverSourceNoComments()
	Names := []
	Seen := Map()
	Pos := 1
	while (Found := RegExMatch(Src, Pattern, &M, Pos)) {
		if !Seen.Has(M[1]) {
			Seen[M[1]] := true
			Names.Push(M[1])
		}
		Pos := M.Pos + M.Len
	}
	return Names
}





; ===================================================
; ===================================================
; ======= 2/ Every async fetch is cancellable =======
; ===================================================
; ===================================================

_URLC_EveryAsyncFetchRegisters() {
	; Prerequisite: cancellation really is registry-based. If this stops being
	; true the assertions below are pinning the wrong mechanism.
	Cancel := _DriverFuncBody("_Updater_CancelAsyncChecks")
	Assert(Cancel != "", "_Updater_CancelAsyncChecks() must exist in the driver source")
	Assert(InStr(Cancel, "_UpdaterAsyncRequests.Clear()") > 0,
		"prerequisite: async cancellation works by draining _UpdaterAsyncRequests, so anything absent from that map cannot be cancelled at all")

	Fetches := _URLC_MatchingFunctions("m)^(_Updater_Fetch[A-Za-z0-9_]*Async)\([^\r\n]*\)\s*\{")
	Assert(Fetches.Length >= 2,
		"the async-fetch scan must find every _Updater_Fetch*Async function (found " . Fetches.Length . "): a scan that matches nothing must not be able to pass")

	for _, Fn in Fetches {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . "() was found by the source scan but its body could not be resolved")
		Assert(InStr(Body, "_UpdaterAsyncRequests[") > 0,
			Fn . " must register its request in the shared _UpdaterAsyncRequests map: _Updater_CancelAsyncChecks drains only that map, so an unregistered request survives the suspend teardown and keeps polling and talking to the network while the driver is paused (updater-releases-list-uncancellable)")
	}
}
Test("updater: every async fetch registers in the shared cancellation registry (updater-releases-list-uncancellable)", _URLC_EveryAsyncFetchRegisters)





; ====================================================
; ====================================================
; ======= 3/ Every WinHTTP poll honours cancel =======
; ====================================================
; ====================================================

_URLC_EveryWinHttpPollHonoursCancellation() {
	Polls := _URLC_MatchingFunctions("m)^(_Updater_Poll[A-Za-z0-9_]*Async)\([^\r\n]*\)\s*\{")
	Assert(Polls.Length >= 2,
		"the async-poll scan must find every _Updater_Poll*Async function (found " . Polls.Length . ")")

	Checked := 0
	for _, Fn in Polls {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . "() was found by the source scan but its body could not be resolved")
		; Only the WinHTTP completion polls belong to this class; the staging-worker
		; callback shares the name shape but is owned by ShellRunner, not by the
		; async registry.
		if (InStr(Body, "WaitForResponse") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "_UpdaterAsyncRequests.Has(") > 0,
			Fn . " must no-op once its registry entry has been cancelled: without that check the re-armed 250 ms timer keeps running through a pause for the whole poll budget, which is exactly the state _Updater_CancelAsyncChecks exists to prevent (updater-releases-list-uncancellable)")
	}
	Assert(Checked >= 2,
		"at least both WinHTTP completion polls must have been checked (checked " . Checked . "): a filter that excludes everything must not be able to pass")
}
Test("updater: every WinHTTP completion poll no-ops once cancelled (updater-releases-list-uncancellable)", _URLC_EveryWinHttpPollHonoursCancellation)
