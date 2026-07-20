; tests/meta/test_oneshotshift_endkeys.ahk

; ==============================================================================
; MODULE: OneShotShift InputHook EndKey regression test
; DESCRIPTION:
; Backspace, Enter, and Delete end OneShotShift's suppressive InputHook. They
; must be re-emitted as control keys, never converted to text or dropped.
; ==============================================================================

#Requires AutoHotkey v2.0

_OSEK_OneShotShiftResendsEndKeys() {
    Body := _DriverFuncBody("OneShotShift")
    Assert(Body != "", "OneShotShift() must exist in modules/tap_holds/one_shot_shift.ahk")

    Assert(InStr(Body, 'KeyOpt("{BackSpace}{Enter}{Delete}", "E")') > 0,
        "OneShotShift must explicitly classify Backspace, Enter, and Delete as InputHook end keys")

    EndReasonPos := InStr(Body, 'ihvText.EndReason == "EndKey"')
    SendPos := InStr(Body, 'SendNewResult("{" . ihvText.EndKey . "}", False, False)')
    Assert(EndReasonPos > 0 && SendPos > EndReasonPos,
        "OneShotShift must re-send a captured control EndKey as one non-text control sequence after the InputHook returns")

    ; The raw re-emit branch must be RESTRICTED to the three KeyOpt("E") control
    ; keys. The punctuation/magic end keys (= % $ . , ' space + magic key) are ALSO
    ; EndKey terminations; if this branch catches them, every SpecialCharacter
    ; mapping (. -> ' :', = -> masculine ordinal, etc.) becomes dead code. That is
    ; exactly what commit 866341cb4 did until this restriction was added.
    Segment := SubStr(Body, EndReasonPos, SendPos - EndReasonPos)
    Assert(InStr(Segment, "BackSpace") > 0 && InStr(Segment, "Enter") > 0 && InStr(Segment, "Delete") > 0,
        "the EndKey re-emit branch must be restricted to BackSpace/Enter/Delete so punctuation end keys fall through to the SpecialCharacter dispatch")

    Assert(InStr(Body, 'SpecialCharacter != ""') > 0,
        "OneShotShift must retain the SpecialCharacter dispatch reachable for punctuation/magic end keys")
}

Test("tap-holds: OneShotShift re-emits consumed Backspace/Enter/Delete end keys",
    _OSEK_OneShotShiftResendsEndKeys)

