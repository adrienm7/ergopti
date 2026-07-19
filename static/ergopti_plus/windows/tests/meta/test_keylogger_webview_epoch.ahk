; tests/meta/test_keylogger_webview_epoch.ahk

; ============================================================================== 
; MODULE: Keylogger WebView ownership-epoch regression test
; DESCRIPTION:
; A delayed first/full dashboard build must belong to the exact WebView instance
; that armed it. Reopening the same "typing" or "apps" key must make the old
; timer and old bridge callback inert rather than targeting the replacement.
; ============================================================================== 

#Requires AutoHotkey v2.0

_KLWVE_OldTimersAndBridgeCallbacksCannotReachReplacement() {
    Open := _DriverFuncBody("KLWV_Open")
    First := _DriverFuncBody("KLWV_DelayedFirstPush")
    Full := _DriverFuncBody("KLWV_DelayedFullBuild")
    Bridge := _DriverFuncBody("KLWV_OnWebMessage")
    Range := _DriverFuncBody("KLWV_OnRangeBuildReady")
    Current := _DriverFuncBody("KLWV_IsCurrent")

    Assert(InStr(Open, "Epoch := ++KLWV.epoch") > 0,
        "each KLWV_Open must allocate a monotonic instance epoch")
    Assert(InStr(Open, '"epoch", Epoch') > 0,
        "the published KLWV window entry must retain its owning epoch")
    Assert(InStr(Open, "KLWV_DelayedFirstPush.Bind(which, Epoch)") > 0,
        "the delayed first-push timer must capture the owner epoch")
    Assert(InStr(First, "KLWV_IsCurrent(which, Epoch)") > 0
            && InStr(First, "KLWV_DelayedFullBuild.Bind(which, Epoch)") > 0,
        "first-push must validate and propagate the owner epoch to full build")
    Assert(InStr(Full, "KLWV_IsCurrent(which, Epoch)") > 0,
        "full build must reject a timer from a closed/reopened host")
    Assert(InStr(Bridge, "KLWV_IsCurrent(which, Epoch)") > 0
            && InStr(Bridge, 'sender == entry["webview"]') > 0,
        "WebMessage callbacks must verify both epoch and controller identity")
	Assert(InStr(Bridge, "KLPF_RequestRange(which, KLWV.metrics_dir, query, Epoch") > 0
			&& InStr(Range, "KLWV_IsCurrent(which, Epoch)") > 0,
		"range worker completion must capture and validate its originating dashboard epoch")
    Assert(InStr(Current, 'entry["epoch"] = Epoch') > 0,
        "KLWV_IsCurrent must compare against the live entry epoch")
}

Test("keylogger WebView: old timers and messages cannot mutate a reopened dashboard",
    _KLWVE_OldTimersAndBridgeCallbacksCannotReachReplacement)
