; tests/fixtures/ai/debounce_privacy_app.ahk

; Standalone, exactly owned allowed application for native focus provenance.
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
if A_Args.Length != 3
    ExitApp(2)
_LDPA_Ready := A_Args[1], _LDPA_Stop := A_Args[2], _LDPA_Nonce := A_Args[3]
if FileExist(_LDPA_Ready) || FileExist(_LDPA_Ready . ".pending") || FileExist(_LDPA_Stop)
    ExitApp(3)
_LDPA_Gui := Gui(, "Owned allowed app " . _LDPA_Nonce)
_LDPA_Edit := _LDPA_Gui.AddEdit("w360 h100")
_LDPA_Gui.Show("w400 h150")
_LDPA_Gui.OnEvent("Close", (*) => ExitApp(4))
_LDPA_Edit.Focus()
FileAppend(DllCall("Kernel32\GetCurrentProcessId", "UInt") . "|" . _LDPA_Gui.Hwnd
    . "|" . _LDPA_Edit.Hwnd . "|" . _LDPA_Nonce . "`n", _LDPA_Ready . ".pending", "UTF-8-RAW")
FileMove(_LDPA_Ready . ".pending", _LDPA_Ready, false)
SetTimer(_LDPA_Check, 25)
SetTimer((*) => ExitApp(5), -60000)
_LDPA_Check(*) {
    global _LDPA_Stop
    if FileExist(_LDPA_Stop)
        ExitApp(0)
}
