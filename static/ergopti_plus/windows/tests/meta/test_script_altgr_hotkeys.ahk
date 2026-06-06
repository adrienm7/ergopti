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

opts := "I3 S"
keys := [
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
for key in keys {
    hk := _ScriptAltGrHookKey(key)
    try {
        Hotkey(hk, _DummyHandler, opts)
        Hotkey(hk, "Off")
    } catch as e {
        throw Error('Hotkey("' . hk . '") failed: ' . e.Message, -1, e)
    }
}
FileAppend("test_script_altgr_hotkeys: OK`n", "*")