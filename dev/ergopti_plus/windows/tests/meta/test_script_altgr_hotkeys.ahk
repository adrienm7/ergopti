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
; LCtrl+RAlt of an AltGr layout: without it AltGr+Enter could not unpause
; there (script-altgr-scan-codes-2026-09-26).
_SAH_ChordsAreScanCodesAndPausedOnesWildcard() {
    Body := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
    for _, Dead in ['"RAlt & ', '"^!Enter"', '"^!Backspace"', '"^!Delete"', '"^!Escape"'] {
        AssertFalse(InStr(Body, Dead) > 0, "no script chord may be named by a virtual key: " . Dead)
    }
    Paused := InStr(Body, 'HotIf((*) => ScriptAltGrChordIsLive(A_IsSuspended and GetKeyState("SC138", "P")))')
    AssertTrue(Paused > 0, "the paused chords must still be registered")
    for _, Suffix in ["SC01C", "SC00E", "SC153", "SC001"] {
        AssertTrue(InStr(Body, '_ScriptAltGrHookKey("*' . Suffix . '")', , Paused) > 0,
            "the paused " . Suffix . " chord must admit the modifiers AltGr holds")
    }
}
Test("script altgr: chords by scan code, paused ones admit AltGr's modifiers (script-altgr-scan-codes-2026-09-26)",
    _SAH_ChordsAreScanCodesAndPausedOnesWildcard)

; On QWERTY right Alt is a plain Alt (the boot probe finds no AltGr level), yet
; the always-eligible prefix anchor arms SC138 on its first press: RAlt+Escape
; (Alt+Esc cycles windows) quit the driver, RAlt+Enter paused it,
; RAlt+BackSpace reloaded it and RAlt+Delete opened the personal shortcuts,
; running and paused alike (qwerty-script-chords-2026-09-26). These chords are
; destructive, so they need a layout whose AltGr key is an AltGr: a standard
; AltGr layout or a Kana one. On QWERTY those keys stay native Alt chords.
_SAH_ChordsNeedAnAltGrLayout() {
    for _, Family in ["standard", "qwerty", "kana"] {
        Saved := _TestSetAltGrFamily(Family == "kana", Family == "standard")
        try {
            if (Family == "qwerty")
                AssertFalse(ScriptAltGrChordIsLive(true),
                    "qwerty: RAlt+Escape/Enter/BackSpace/Delete must stay native Alt chords, never quit, pause, reload or open the personal shortcuts")
            else
                AssertTrue(ScriptAltGrChordIsLive(true), Family . ": an AltGr press keeps the script chords")
            AssertFalse(ScriptAltGrChordIsLive(false), Family . ": no chord without its AltGr press")
        } finally _TestRestoreAltGrFamily(Saved)
    }
    Body := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
    Assert(Body != "", "_RegisterScriptAltGrHotkeys must be found")
    AssertTrue(InStr(Body, "HotIf((*) => ScriptAltGrChordIsLive(IsRealAltGrPress()))") > 0,
        "the running chords must go through the layout gate")
    AssertTrue(InStr(Body, 'HotIf((*) => ScriptAltGrChordIsLive(A_IsSuspended and GetKeyState("SC138", "P")))') > 0,
        "the paused chords must go through the layout gate")
    StrReplace(Body, "HotIf((*) =>", , , &Criteria)
    AssertEqual(3, Criteria, "the running, Kana and paused chords are the only registrations")
}
Test("script altgr: the chords need a layout whose AltGr key is an AltGr, on every family (qwerty-script-chords-2026-09-26)",
    _SAH_ChordsNeedAnAltGrLayout)
