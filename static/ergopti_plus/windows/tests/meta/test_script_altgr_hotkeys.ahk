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
    "SC138 & SC01C",
    "SC138 & SC00E",
    "SC138 & SC038",
    "SC138 & SC03A",
    "SC01C",
    "SC00E",
    "*SC01C",
    "*SC00E",
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

; The script chords are registered by scan code only. "RAlt & Enter" and
; "^!Enter" twins were dead: the SC138 hotkeys route every right Alt event to
; the scan code's record and the SC01C/SC00E/SC153/SC001 hotkeys route those
; keys' events to theirs, so a twin named by a virtual key was never looked up.
; The paused chords run from the suffix alone and need * to match under the
; LCtrl+RAlt of an AltGr layout (the RAlt of QWERTY): without it AltGr+Enter
; could not unpause there (script-altgr-scan-codes-2026-09-26).
_SAH_ChordsAreScanCodesAndPausedOnesWildcard() {
    Body := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
    for _, Dead in ['"RAlt & ', '"^!Enter"', '"^!Backspace"', '"^!Delete"', '"^!Escape"'] {
        AssertFalse(InStr(Body, Dead) > 0, "no script chord may be named by a virtual key: " . Dead)
    }
    Paused := InStr(Body, 'HotIf((*) => A_IsSuspended and GetKeyState("SC138", "P"))')
    AssertTrue(Paused > 0, "the paused chords must still be registered")
    for _, Suffix in ["SC01C", "SC00E", "SC153", "SC001"] {
        AssertTrue(InStr(Body, '_ScriptAltGrHookKey("*' . Suffix . '")', , Paused) > 0,
            "the paused " . Suffix . " chord must admit the modifiers AltGr holds")
    }
}
Test("script altgr: chords by scan code, paused ones admit AltGr's modifiers (script-altgr-scan-codes-2026-09-26)",
    _SAH_ChordsAreScanCodesAndPausedOnesWildcard)
