; tests/meta/test_addshortcut_registration_guard.ahk

; ============================================================================== 
; MODULE: AddShortcut Registration Guard Regression Test
; DESCRIPTION:
; AddShortcut is the central registration gateway for Win/Ctrl shortcut groups.
; AHK can reject a hotkey at startup; that must be contained and logged instead
; of aborting the rest of the driver registration pass.
; ============================================================================== 

#Requires AutoHotkey v2.0

_ASRG_HotkeyRegistrationIsContained() {
    Body := _DriverFuncBody("AddShortcut")
    Assert(Body != "", "AddShortcut must exist in modules/shortcuts/utils.ahk")
    TryPos := InStr(Body, "try")
    HotkeyPos := InStr(Body, "Hotkey(")
    CatchPos := InStr(Body, "catch as Err")
    Assert(TryPos > 0 && HotkeyPos > TryPos && CatchPos > HotkeyPos,
        "AddShortcut must wrap scan-code resolution and Hotkey registration in try/catch")
    Assert(InStr(Body, "LoggerError") > CatchPos,
        "a failed AddShortcut registration must leave an error log")
    Assert(InStr(Body, "return false") > CatchPos,
        "AddShortcut must report a rejected registration without throwing")
    Assert(InStr(Body, "return true") > HotkeyPos,
        "AddShortcut must only report success after Hotkey registration completes")
}
Test("shortcuts: AddShortcut contains Hotkey registration failures", _ASRG_HotkeyRegistrationIsContained)
