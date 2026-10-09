; tests/meta/test_updater_cancel_fires_on_json.ahk

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
; Non-leased owners Abort and receive one typed callback immediately; a leased
; owner stores the terminal and converges on the same Abort -> callback path when
; its operation lease releases. The guard follows that transitive route instead
; of requiring on_json to remain textually inside the top-level cancel wrapper.
; ==============================================================================

#Requires AutoHotkey v2.0


_UCFJ_AssertCancelFiresOnJson() {
	Cancel := _DriverFuncBody("_Updater_CancelAsyncChecks")
	Direct := _DriverFuncBody("_Updater_DeliverAsyncCancellationRecord")
	Abort := _DriverFuncBody("_Updater_AbortAsyncTransport")
	Release := _DriverFuncBody("_Updater_ReleaseAsyncSendLease")
	DispatchFailure := _DriverFuncBody("_Updater_FailOwnedAsyncDispatch")
	Assert(Cancel != "" and Direct != "" and Abort != "" and Release != ""
		and DispatchFailure != "",
		"cancel, direct delivery, setup failure, Abort and leased release helpers must all exist")
	DrainAt := InStr(Cancel, "_Updater_SwapAsyncRequestsForBoundary(")
	Batch := _DriverFuncBodyOrEmpty("_Updater_DeliverCancelledAsyncRequests")
	Route := Cancel . Batch
	Assert(DrainAt > 0
		and InStr(Cancel, "_UpdaterAsyncRequests.Clear()") == 0
		and InStr(Route, "_Updater_DeferLeasedAsyncCancellation(") > 0
		and InStr(Route, "_Updater_DeliverAsyncCancellationRecord(") > 0,
		"cancel must atomically replace registry ownership, then route every leased or direct terminal outside that live Map")
	AbortAt := InStr(Direct, "_Updater_AbortAsyncTransport(")
	DispatcherAt := InStr(Direct, "_Updater_InvokeAsyncOnJson(", , AbortAt)
	Assert(AbortAt > 0 and DispatcherAt > AbortAt
		and InStr(Direct, "Cancellation", , DispatcherAt) > DispatcherAt
		and InStr(Abort, ".Abort()") > 0,
		"direct cancellation must best-effort Abort before the shared typed terminal dispatcher")
	Assert(InStr(Direct, '["on_json"](') == 0
		and InStr(Direct, '["on_json"].Call(') == 0,
		"direct cancellation must never retain an obsolete raw callback alternative")
	Dispatcher := _DriverFuncBodyOrEmpty("_Updater_InvokeAsyncOnJson")
	Assert(Dispatcher != "" and InStr(Dispatcher, "OnJson.Call(") > 0,
		"the centralized terminal dispatcher must invoke the owned callback")
	Assert(InStr(Release,
		"_Updater_DeliverAsyncCancellationRecord(Record, Cancellation)") > 0,
		"leased cancellation must converge on the same Abort and callback contract after COM returns")
	Assert(InStr(DispatchFailure, "_Updater_InvokeAsyncOnJson(") > 0,
		"async setup failure must converge on the same terminal dispatcher")
}
Test("updater AHK-31: cancellation fires typed on_json after direct or leased retirement (updater-cancel-fires-on-json) (updater-operation-lease)",
	_UCFJ_AssertCancelFiresOnJson)
