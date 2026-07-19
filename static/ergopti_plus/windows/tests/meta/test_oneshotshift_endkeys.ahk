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
        "OneShotShift must re-send a captured EndKey as one non-text control sequence after the InputHook returns")
    Assert(InStr(Body, 'if (ihvText.EndKey != "")') > 0,
        "OneShotShift must not emit an empty control sequence when InputHook reports no EndKey")
}

Test("tap-holds: OneShotShift re-emits consumed Backspace/Enter/Delete end keys",
    _OSEK_OneShotShiftResendsEndKeys)

