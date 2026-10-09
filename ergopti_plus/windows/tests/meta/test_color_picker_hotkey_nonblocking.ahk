; tests/meta/test_color_picker_hotkey_nonblocking.ahk

; ============================================================================== 
; MODULE: Color Picker Hotkey Nonblocking Regression Test
; DESCRIPTION:
; Win+X and the matching gesture used unguarded desktop/clipboard calls followed
; by a modal MsgBox.  Since both run on the driver's sole message thread, the
; dialog stalled keyboard dispatch and a clipboard failure escaped the callback.
; ============================================================================== 

#Requires AutoHotkey v2.0

_CPHNB_KeyboardAndGesturePickersFailFast() {
    ShortcutBody := _DriverFuncBody("GetHexValue")
    GestureBody := _DriverFuncBody("GesturePickColor")
    Assert(ShortcutBody != "", "GetHexValue must exist for the Win+X color hotkey")
    Assert(GestureBody != "", "GesturePickColor must exist for the matching gesture action")

    for Name, Body in Map("GetHexValue", ShortcutBody, "GesturePickColor", GestureBody) {
        Assert(InStr(Body, "try") > 0 && InStr(Body, "catch as Err") > 0,
            Name . " must contain desktop and clipboard failures")
        Assert(InStr(Body, "CB_Write(HexColor)") > 0,
            Name . " must use the guarded clipboard adapter")
        Assert(InStr(Body, "LoggerError") > 0,
            Name . " must log a failed color copy instead of silently losing the action")
        Assert(InStr(Body, "TrayTip") > 0,
            Name . " must give nonblocking user feedback")
        Assert(InStr(Body, "MsgBox") = 0,
            Name . " must not open a modal dialog on the driver message thread")
        Assert(InStr(Body, "A_Clipboard :=") = 0,
            Name . " must not write the clipboard outside the guarded adapter")
    }
}
Test("color picker: Win+X and gesture feedback are guarded and nonblocking",
    _CPHNB_KeyboardAndGesturePickersFailFast)
