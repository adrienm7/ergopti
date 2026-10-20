; tests/meta/platform/remap/keys/test_oneshotshift_endkeys.ahk

; ==============================================================================
; MODULE: OneShotShift InputHook EndKey regression test
; DESCRIPTION:
; Backspace, Enter, and Delete end OneShotShift's suppressive InputHook. They
; must be re-emitted as control keys, never converted to text or dropped.
; ==============================================================================

#Requires AutoHotkey v2.0

_OSEK_OneShotShiftResendsEndKeys() {
    Body := _DriverFuncBody("OneShotShift")
    Assert(Body != "", "OneShotShift() must exist in platform/remap/one_shot_shift.ahk")

    Assert(InStr(Body, 'NamedKeys := "{BackSpace}{Enter}{Delete}"') > 0
        && InStr(Body, 'KeyOpt(NamedKeys, "E")') > 0,
        "the same explicit control list must classify native completion and decoder admission")
    ReadPos := InStr(Body, 'Capture := _SIHO_ReadScalar(ihvText, NamedKeys)')
    GuardPos := InStr(Body, 'if Capture.Kind == "control"')
    SendPos := InStr(Body, 'SendNewResult("{" . Capture.Name . "}", False, False)')
    SpecialPos := InStr(Body, 'SpecialCharacter := TapHoldOneShotResult(Scalar, MagicKey)')
    Assert(ReadPos > 0 && GuardPos > ReadPos && SendPos > GuardPos && SpecialPos > SendPos,
        "only named controls may replay as keys, while complete scalar punctuation/magic remains reachable")
    Assert(InStr(Body, 'Scalar := Capture.Text') > 0,
        "one-shot results must use the complete scalar, not an isolated low EndKey or empty Input")

    Assert(InStr(Body, 'SpecialCharacter != ""') > 0,
        "OneShotShift must retain the SpecialCharacter dispatch reachable for punctuation/magic end keys")
}

Test("tap-holds: OneShotShift re-emits consumed Backspace/Enter/Delete end keys",
    _OSEK_OneShotShiftResendsEndKeys)

