; static/ergopti_plus/windows/tests/meta/test_keylogger_webview_range_bridge.ahk

; ============================================================================== 
; MODULE: Keylogger WebView Selected-Range Bridge Regression Test
; DESCRIPTION:
; Pins the Windows date/app filter request path. The shared dashboard must send
; a native WebView2 range request, the host must defer its SQLite projection off
; the callback stack, and the response must flow back as range_data rather than
; leaving the n-gram table on the first all-time payload forever.
; ============================================================================== 

#Requires AutoHotkey v2.0+

_KLWVRange_CheckSelectedRangeBridge() {
    Body := _DriverFuncBody("KLWV_OnWebMessage")
    Assert(Body != "", "KLWV_OnWebMessage must exist in modules/keylogger/keylogger_webview.ahk")
    Assert(InStr(Body, 'case "range"') > 0,
        "KLWV_OnWebMessage must handle the metrics typing range action")
    Assert(InStr(Body, "KLPF_RequestRange(") > 0,
        "range projection must be delegated to a detached worker, never deferred onto the same AHK thread")

    NormalizeBody := _DriverFuncBody("KLWV_NormalizeRangeRequest")
    Assert(NormalizeBody != "", "KLWV_NormalizeRangeRequest must exist")
    Assert(InStr(NormalizeBody, "KLWV_IsIsoDate") > 0,
        "range requests must validate date strings before SQLite projection")
    Assert(InStr(NormalizeBody, "seen.Has(app_name)") > 0,
        "range requests must de-duplicate selected applications")

    TerminalBody := _DriverFuncBody("KLWV_OnRangeBuildTerminal")
    Assert(TerminalBody != "", "KLWV_OnRangeBuildTerminal must exist")
    ScriptBody := _DriverFuncBody("KLWV_BuildRangeScript")
    Assert(ScriptBody != "", "the native range script builder must exist")
    Assert(InStr(TerminalBody, "WebView_RunScriptAsync") > 0
            && InStr(TerminalBody, "KLWV_BuildRangeScript") > 0
            && InStr(ScriptBody, "fetch(") > 0 && InStr(ScriptBody, "r.json()") > 0
            && InStr(ScriptBody, "window.receive_range_data") > 0
            && InStr(TerminalBody, "request_id") > 0,
        "WebView must fetch and parse the staged range JSON in its own process")
    Assert(!RegExMatch(TerminalBody, "SetTimer\s*\(\s*KLWV_DeleteRangeStage\b"),
        "elapsed time must not delete a stage whose asynchronous read may still be pending")
    Assert(InStr(TerminalBody, "FileRead") = 0 && InStr(ScriptBody, "FileRead") = 0,
        "the AHK driver must not synchronously read a selected-range JSON payload")
	SendBody := _DriverFuncBody("KLWV_SendRangeTerminal")
	Assert(InStr(SendBody, '"range_terminal"') > 0 && InStr(SendBody, '"request_id"') > 0,
		"every Windows range failure/cancel must send the owning request id back to the page")
}
Test("keylogger_webview: date/app range changes use a detached projection instead of retaining the initial all-time n-grams (metrics-range-bridge-stale-filter)",
    _KLWVRange_CheckSelectedRangeBridge)
