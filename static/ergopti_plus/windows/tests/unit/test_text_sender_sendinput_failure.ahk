; tests/unit/test_text_sender_sendinput_failure.ahk

; ============================================================================== 
; MODULE: TextSender SendInput Failure Containment Tests
; DESCRIPTION:
; A failed low-level SendInput must not escape from a keyboard-facing adapter
; method.  In particular, a partially sent multi-modifier Down transaction must
; release every earlier modifier instead of leaving it logically held.
; ============================================================================== 

#Requires AutoHotkey v2.0

_TSSIF_AlwaysFail(*) {
    throw Error("injected SendInput failure")
}

global _TSSIF_SentKeys := []

_TSSIF_FailSecondModifier(Keys) {
    global _TSSIF_SentKeys
    _TSSIF_SentKeys.Push(Keys)
    if (Keys = "{LShift Down}")
        throw Error("injected second modifier failure")
}

_TSSIF_AdapterMethodsContainSendInputFailure() {
    global _AHK_SendInput
    Previous := _AHK_SendInput
    try {
        _AHK_SendInput := _TSSIF_AlwaysFail
        Err := ""
        try {
            TextEraseChars(1)
            TextPressKey("Tab", "Shift")
        } catch as Failure {
            Err := Failure.Message
        }
        AssertEqual("", Err,
            "TextEraseChars/TextPressKey must contain injected SendInput failures")
    } finally {
        _AHK_SendInput := Previous
    }
}
Test("TextSender: keyboard-facing SendInput failures are contained",
    _TSSIF_AdapterMethodsContainSendInputFailure)

_TSSIF_HoldFailureRollsBackEarlierModifiers() {
	global _AHK_SendInput, _TSSIF_SentKeys
    Previous := _AHK_SendInput
    try {
		_TSSIF_SentKeys := []
		_AHK_SendInput := _TSSIF_FailSecondModifier
        Ok := TextPressKey(["LCtrl", "LShift"], "Down")
        AssertEqual(false, Ok, "a failed modifier Down transaction must report failure")
		AssertEqual("{LCtrl Down}", _TSSIF_SentKeys[1], "the first modifier should be sent before the injected failure")
		AssertEqual("{LShift Down}", _TSSIF_SentKeys[2], "the failing modifier send must be attempted exactly once")
		AssertEqual("{LCtrl Up}", _TSSIF_SentKeys[3], "a failed multi-key Down must roll back earlier modifiers in reverse order")
		AssertEqual(3, _TSSIF_SentKeys.Length, "rollback must not issue unrelated key injections")
    } finally {
        _AHK_SendInput := Previous
    }
}
Test("TextSender: failed multi-modifier Down rolls back already-held keys",
    _TSSIF_HoldFailureRollsBackEarlierModifiers)
