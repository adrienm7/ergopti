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
    Assert(InStr(Body, "SetTimer(KLWV_PushRangeData.Bind") > 0,
        "range projection must be deferred off the WebMessageReceived callback stack")

    NormalizeBody := _DriverFuncBody("KLWV_NormalizeRangeRequest")
    Assert(NormalizeBody != "", "KLWV_NormalizeRangeRequest must exist")
    Assert(InStr(NormalizeBody, "KLWV_IsIsoDate") > 0,
        "range requests must validate date strings before SQLite projection")
    Assert(InStr(NormalizeBody, "seen.Has(app_name)") > 0,
        "range requests must de-duplicate selected applications")

    PushBody := _DriverFuncBody("KLWV_PushRangeData")
    Assert(PushBody != "", "KLWV_PushRangeData must exist")
    Assert(InStr(PushBody, "KLR_ReadRangeSplitToday") > 0,
        "range bridge must query the selected date/app n-gram projection")
    Assert(InStr(PushBody, '"type":"range_data"') > 0,
        "range bridge must respond with a range_data message")
}
Test("keylogger_webview: date/app range changes use a deferred native projection instead of retaining the initial all-time n-grams (metrics-range-bridge-stale-filter)",
    _KLWVRange_CheckSelectedRangeBridge)
