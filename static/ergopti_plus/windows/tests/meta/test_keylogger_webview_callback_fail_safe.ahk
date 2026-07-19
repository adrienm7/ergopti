; tests/meta/test_keylogger_webview_callback_fail_safe.ahk

; ==============================================================================
; MODULE: Keylogger WebView callback fail-safe regression test
; DESCRIPTION:
; WebMessageReceived and its deferred range callback bypass hotkey error
; boundaries. A failed prefetch read or SQLite range projection must be logged
; and dropped, never escape into the keyboard driver's global error handler.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLWVFS_CallbacksFailSafe() {
    Push := _DriverFuncBody("KLWV_PushPrefetch")
    Range := _DriverFuncBody("KLWV_PushRangeData")
    First := _DriverFuncBody("KLWV_DelayedFirstPush")
    Full := _DriverFuncBody("KLWV_DelayedFullBuild")

    Assert(Push != "" && Range != "" && First != "" && Full != "",
        "keylogger WebView push/range lifecycle functions must exist")
    Assert(InStr(Push, "try body := FileRead(path, " . Chr(34) . "UTF-8" . Chr(34) . ")") > 0
            && InStr(Push, "LoggerError") > 0,
        "KLWV_PushPrefetch must catch and centrally log a prefetch FileRead failure")
    Assert(InStr(Range, "try {") > 0
            && InStr(Range, "catch as err") > 0
            && InStr(Range, "LoggerError") > 0,
        "KLWV_PushRangeData must contain and log projection failures from its deferred callback")
    Assert(InStr(Range, "A_IsSuspended") > 0,
        "KLWV_PushRangeData must become inert when Suspend occurs after range dispatch")
    Assert(InStr(First, "A_IsSuspended") > 0 && InStr(Full, "A_IsSuspended") > 0,
        "delayed WebView builds must not run while the driver is suspended")
}

Test("keylogger WebView: deferred bridge callbacks contain I/O errors and honour Suspend",
    _KLWVFS_CallbacksFailSafe)
