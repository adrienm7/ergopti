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
; The fix snapshots the pending requests, clears the registry, then fires each
; on_json("") so consumers (the one-click in-progress flag) reset themselves. Meta-
; static because the updater installs background timers; the source scan asserts the
; cancel path fires on_json.
; ==============================================================================

#Requires AutoHotkey v2.0


_UCFJ_AssertCancelFiresOnJson() {
	Body := _DriverFuncBody("_Updater_CancelAsyncChecks")
	Assert(Body != "", "_Updater_CancelAsyncChecks must exist")
	Assert(InStr(Body, "Clear()") > 0, "_Updater_CancelAsyncChecks must still clear the registry")
	Assert(InStr(Body, "on_json") > 0,
		"_Updater_CancelAsyncChecks must fire each pending request's on_json callback before dropping it, else a consumer-owned flag (the one-click in-progress latch) is never released and the menu item stays disabled until restart (updater-cancel-fires-on-json)")
}
Test("updater: cancel fires each pending on_json so the one-click latch is released (updater-cancel-fires-on-json)", _UCFJ_AssertCancelFiresOnJson)
