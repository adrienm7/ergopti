; tests/meta/modules/updater/test_updater_cancel_fires_on_json.ahk

; ==============================================================================
; MODULE: Updater Cancel Fires Pending on_json Meta Test
; DESCRIPTION:
; Static source guard for finding updater-cancel-fires-on-json (F-M08).
;
; _Updater_CancelAsyncChecks dropped in-flight requests with a bare
; _UpdaterAsyncRequests.Clear(), never firing each request's stored on_json
; callback. So when a one-click update check was cancelled mid-flight — on EVERY
; suspend transition (including the automatic password-field auto-suspend) or a
; frequency-submenu change (which, unlike a channel change, does not Reload) — the
; poll's `if !Has(id) return` no-op meant _Updater_OneClickUpdateCallback never ran
; and _UpdaterCheckInProgress latched true forever, leaving the "check for updates"
; menu item stuck disabled until a full restart.
;
; AHK-31 keeps that terminal contract while a COM effect is on the stack.
; Non-leased owners Abort and receive one typed callback immediately, which the
; real cancellation proves below; a leased owner stores the terminal and converges
; on the same Abort -> callback path when its operation lease releases, which
; only a live COM effect can stage, so that route stays a source guard.
; ==============================================================================

#Requires AutoHotkey v2.0


_UCFJ_Terminal(State, Json, Request, Terminal := 0) {
	State.Events.Push("callback")
	State.Terminal := Terminal
	State.Registered := _UpdaterAsyncRequests.Count
}

; The real registry and cancellation; only the transport is an in-memory owner.
_UCFJ_AssertCancelFiresOnJson() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := {Events: [], Terminal: 0, Registered: -1}
		Http := {}
		Http.DefineProp("Abort", {Call: (*) => State.Events.Push("abort")})
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_Updater_RegisterAsyncRequestOwner(Http, "main", _UCFJ_Terminal.Bind(State), "test://cancel", Request)
		AssertEqual(1, _UpdaterAsyncRequests.Count, "the owner is registered before the cancel")
		_Updater_CancelAsyncChecks("test cancel")
		AssertEqual(2, State.Events.Length, "the transport is aborted and the owner called, once each")
		AssertEqual("abort", State.Events[1], "the transport is aborted before the owner hears of it")
		AssertEqual("callback", State.Events[2], "a cancelled request must fire its stored on_json")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal), "the owner receives a typed cancellation")
		AssertEqual(0, State.Registered, "the registry entry is gone before the callback runs")
		_Updater_CancelAsyncChecks("test cancel again")
		AssertEqual(2, State.Events.Length, "a second cancel cannot deliver the terminal twice")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("updater AHK-31: cancellation fires typed on_json after direct retirement (updater-cancel-fires-on-json) (updater-operation-lease)",
	_UCFJ_AssertCancelFiresOnJson)

_UCFJ_LeasedAndSetupFailuresConverge() {
	Release := _DriverFuncBody("_Updater_ReleaseAsyncSendLease")
	DispatchFailure := _DriverFuncBody("_Updater_FailOwnedAsyncDispatch")
	Assert(InStr(Release, "_Updater_DeliverAsyncCancellationRecord(Record, Cancellation)") > 0,
		"leased cancellation must converge on the same Abort and callback contract after COM returns")
	Assert(InStr(DispatchFailure, "_Updater_InvokeAsyncOnJson(") > 0,
		"async setup failure must converge on the same terminal dispatcher")
}
Test("updater AHK-31: leased and setup failures converge on one terminal (updater-cancel-fires-on-json) (updater-operation-lease)",
	_UCFJ_LeasedAndSetupFailuresConverge)
