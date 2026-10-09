; static/ergopti_plus/windows/tests/meta/test_script_altgr_hotkeys.ahk
#Requires AutoHotkey v2.0
; Smoke-test: every hotkey name ScriptAltGrChordPlan builds must be a valid
; Hotkey() name with the registrar's options.

_DummyHandler(*) {
}

_ScriptAltGrValidationOptions := "I3 S"
_ScriptAltGrValidationSlots := ["script_altgr_enter", "script_altgr_backspace",
    "script_altgr_delete", "script_altgr_escape"]
_ScriptAltGrValidationCodes := Map("script_altgr_enter", "SC01C", "script_altgr_backspace", "SC00E",
    "script_altgr_delete", "SC153", "script_altgr_escape", "SC001")
for _ScriptAltGrValidationRow in ScriptAltGrChordPlan(_ScriptAltGrValidationSlots, _ScriptAltGrValidationCodes) {
    _ScriptAltGrValidationHotkey := _ScriptAltGrValidationRow["hotkey"]
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
    ; The registrar registers the rows of ScriptAltGrChordPlan, whose names are
    ; built from the slots' scan codes (script-chord-slot-2026-09-30).
    for _, Name in ["_RegisterScriptAltGrHotkeys", "ScriptAltGrChordPlan"] {
        Body := _DriverFuncBody(Name)
        for _, Dead in ['"RAlt & ', '"^!Enter"', '"^!Backspace"', '"^!Delete"', '"^!Escape"', '"^!"'] {
            AssertFalse(InStr(Body, Dead) > 0, Name . ": no script chord may be named by a virtual key: " . Dead)
        }
    }
    AssertTrue(InStr(_DriverFuncBody("_RegisterScriptAltGrHotkeys"), "SCRIPT_SHORTCUT_SCAN_CODES") > 0,
        "the chords must be named by the slots' scan codes")
    AssertTrue(InStr(_DriverFuncBody("ScriptAltGrChordPlan"), '"$*" . Sc, "criterion", ScriptAltGrPausedChordRunsSlot.Bind(Slot)') > 0,
        "the paused chords must still be registered, under the paused criterion")
    Paused := 0
    for Index, Row in ScriptAltGrChordPlan(["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete",
            "script_altgr_escape"], Map("script_altgr_enter", "SC01C", "script_altgr_backspace", "SC00E",
            "script_altgr_delete", "SC153", "script_altgr_escape", "SC001")) {
        ; Each slot's third row is its paused twin.
        if (Mod(Index, 3) == 0) {
            Paused += 1
            AssertEqual("$*" . Row["scan_code"], Row["hotkey"],
                "the paused " . Row["scan_code"] . " chord must admit the modifiers AltGr holds")
        }
    }
    AssertEqual(4, Paused, "the paused chords must still be registered")
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
    AssertTrue(InStr(_DriverFuncBody("ScriptAltGrChordRunsSlot"), "ScriptAltGrChordIsLive(IsRealAltGrPress())") > 0,
        "the running chords must go through the layout gate")
    AssertTrue(InStr(_DriverFuncBody("ScriptAltGrPausedChordRunsSlot"), 'ScriptAltGrChordIsLive(A_IsSuspended and GetKeyState("SC138", "P"))') > 0,
        "the paused chords must go through the layout gate")
    Body := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
    StrReplace(Body, "HotIf(", , , &Criteria)
    AssertEqual(2, Criteria, "the plan's criterion and the reset are the registrar's only HotIf calls")
    StrReplace(_DriverFuncBody("ScriptAltGrChordPlan"), "RunsSlot.Bind(Slot)", , , &Bound)
    AssertEqual(3, Bound, "the running, Kana and paused chords are the only registrations")
}
Test("script altgr: the chords need a layout whose AltGr key is an AltGr, on every family (qwerty-script-chords-2026-09-26)",
    _SAH_ChordsNeedAnAltGrLayout)
