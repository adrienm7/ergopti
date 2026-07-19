; static/ergopti_plus/windows/tests/meta/test_script_altgr_hotkeys.ahk
#Requires AutoHotkey v2.0
; Smoke-test: _ScriptAltGrHookKey must not produce invalid Hotkey() names.

_ScriptAltGrHookKey(KeyName) {
    if (SubStr(KeyName, 1, 1) = "$")
        return KeyName
    if InStr(KeyName, " & ")
        return KeyName
    return "$" . KeyName
}

_DummyHandler(*) {
}

_ScriptAltGrValidationOptions := "I3 S"
_ScriptAltGrValidationKeys := [
    "RAlt & Enter",
    "SC138 & SC01C",
    "RAlt & BackSpace",
    "SC138 & SC00E",
    "SC138 & SC038",
    "SC138 & SC03A",
    "^!Enter",
    "^!Backspace",
    "SC01C",
    "SC00E",
]
for _ScriptAltGrValidationKey in _ScriptAltGrValidationKeys {
    _ScriptAltGrValidationHotkey := _ScriptAltGrHookKey(_ScriptAltGrValidationKey)
    try {
        Hotkey(_ScriptAltGrValidationHotkey, _DummyHandler, _ScriptAltGrValidationOptions)
        Hotkey(_ScriptAltGrValidationHotkey, "Off")
    } catch as _ScriptAltGrValidationError {
        throw Error('Hotkey("' . _ScriptAltGrValidationHotkey . '") failed: ' . _ScriptAltGrValidationError.Message, -1, _ScriptAltGrValidationError)
    }
}
; Do not write directly to stdout here: AutoHotkey64.exe is a GUI subsystem
; binary, so the `*` descriptor is invalid in a headless run. The registered
; assertions are reported by test_framework.ahk once all includes complete.
