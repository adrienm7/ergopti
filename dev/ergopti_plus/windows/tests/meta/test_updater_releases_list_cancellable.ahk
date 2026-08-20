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
	Assert(InStr(Cancel, "_Updater_SwapAsyncRequestsForBoundary(") > 0
		and InStr(Cancel, "_UpdaterAsyncRequests.Clear()") == 0,
		"prerequisite: cancellation atomically replaces _UpdaterAsyncRequests before delivering the retired registry, so reentrant work cannot be abandoned")
	Fetches := _URLC_MatchingFunctions("m)^(_Updater_Fetch[A-Za-z0-9_]*Async)\([^\r\n]*\)\s*\{")
	Assert(Fetches.Length >= 2,
		"the async-fetch scan must find every _Updater_Fetch*Async function (found " . Fetches.Length . "): a scan that matches nothing must not be able to pass")

	for _, Fn in Fetches {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . "() was found by the source scan but its body could not be resolved")
		RegisterAt := InStr(Body, "_Updater_RegisterAsyncRequestOwner(")
		SendAt := RegisterAt > 0
			? InStr(Body, "_Updater_SendOwnedAsyncRequest(", , RegisterAt)
			: 0
		Assert(RegisterAt > 0 and SendAt > RegisterAt,
			Fn . " must publish an exact owner in the shared registry before transport preparation and Send: an unregistered request survives suspend and keeps talking to the network while the driver is paused (updater-releases-list-uncancellable)")
		for _, Effect in [
				"ComObject(", ".Open(", ".SetRequestHeader(",
				".SetTimeouts(", ".Send("] {
			EffectAt := InStr(Body, Effect)
			Assert(EffectAt == 0 or EffectAt > RegisterAt,
				Fn . " performs " . Effect
				. " before publishing its exact owner; source ordering must make every yielding transport effect cancellable (updater-owner-before-preparation)")
		}
	}
	Registrar := _DriverFuncBody("_Updater_RegisterAsyncRequestOwner")
	Assert(Registrar != "",
		"the exact async-owner registrar must exist")
	CriticalAt := InStr(Registrar, 'Critical("On")')
	PolicyAt := CriticalAt > 0
		? InStr(Registrar, "_Updater_RequestPolicy(Request)", , CriticalAt)
		: 0
	PublishAt := PolicyAt > 0
		? InStr(Registrar, "_UpdaterAsyncRequests[Owner.Id] := Record", , PolicyAt)
		: 0
	Assert(CriticalAt > 0 and PolicyAt > CriticalAt and PublishAt > PolicyAt,
		"the shared registrar must publish each exact transport owner under the request-policy Critical boundary")
}
Test("updater AHK-31: every async fetch owns registry membership before Send (updater-owner-before-preparation)",
	_URLC_EveryAsyncFetchRegisters)





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
		LookupAt := InStr(Body, "_UpdaterAsyncRequests.Has(")
		AcquireAt := LookupAt > 0
			? InStr(Body, "_Updater_AcquireAsyncSendLease(", , LookupAt)
			: 0
		WaitAt := AcquireAt > 0
			? InStr(Body, "WaitForResponse", , AcquireAt)
			: 0
		StatusAt := WaitAt > 0 ? InStr(Body, ".Status", , WaitAt) : 0
		BodyAt := WaitAt > 0 ? InStr(Body, ".ResponseText", , WaitAt) : 0
		FinallyAt := WaitAt > 0 ? InStr(Body, "finally", , WaitAt) : 0
		ReleaseAt := FinallyAt > 0
			? InStr(Body, "_Updater_ReleaseAsyncSendLease(Owner)", , FinallyAt)
			: 0
		TakeAt := ReleaseAt > 0
			? InStr(Body, "_Updater_TakeAsyncRequest(", , ReleaseAt)
			: 0
		Assert(LookupAt > 0 and AcquireAt > LookupAt
			and WaitAt > AcquireAt
			and StatusAt > WaitAt and StatusAt < FinallyAt
			and BodyAt > WaitAt and BodyAt < FinallyAt
			and ReleaseAt > FinallyAt
			and TakeAt > ReleaseAt,
			Fn . " must lease its exact record across WaitForResponse/Status/ResponseText, release in finally, then exact-take completion; otherwise cancellation can Abort/callback while COM is on the stack (updater-operation-lease)")
	}
	Assert(Checked >= 2,
		"at least both WinHTTP completion polls must have been checked (checked " . Checked . "): a filter that excludes everything must not be able to pass")
}
Test("updater: every WinHTTP completion poll no-ops once cancelled (updater-releases-list-uncancellable)", _URLC_EveryWinHttpPollHonoursCancellation)

_URLC_SendTransactionUsesOneLease() {
	Sender := _DriverFuncBody("_Updater_SendOwnedAsyncRequest")
	Assert(Sender != "", "_Updater_SendOwnedAsyncRequest() must exist")
	AcquireAt := InStr(Sender, "_Updater_AcquireAsyncSendLease(Owner)")
	PrepareAt := AcquireAt > 0
		? InStr(Sender, "PrepareFn.Call(Owner)", , AcquireAt)
		: 0
	CommitAt := PrepareAt > 0
		? InStr(Sender, "_Updater_CommitAsyncSendLease(Owner)", , PrepareAt)
		: 0
	SendAt := CommitAt > 0 ? InStr(Sender, "Http.Send()", , CommitAt) : 0
	FinallyAt := SendAt > 0 ? InStr(Sender, "finally", , SendAt) : 0
	ReleaseAt := FinallyAt > 0
		? InStr(Sender, "_Updater_ReleaseAsyncSendLease(Owner)", , FinallyAt)
		: 0
	Assert(AcquireAt > 0 and PrepareAt > AcquireAt and CommitAt > PrepareAt
		and SendAt > CommitAt and FinallyAt > SendAt and ReleaseAt > FinallyAt,
		"one exact operation lease must cover preparation, Send commit, COM Send and finally release (updater-operation-lease)")
}
Test("updater AHK-31: one lease covers preparation through Send return (updater-operation-lease)",
	_URLC_SendTransactionUsesOneLease)
