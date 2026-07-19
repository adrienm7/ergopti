; tests/unit/test_hotstring_send_failure_containment.ahk

; ============================================================================== 
; MODULE: Hotstring Send Failure Containment Tests
; DESCRIPTION:
; The shared SendNewResult/SendFinalResult primitives run on keyboard-facing
; paths.  A failed sender must not escape the callback, and SendNewResult must
; not mutate the last-sent ring as if its output reached the application.
; ============================================================================== 

#Requires AutoHotkey v2.0

_HSFC_FailingSendHook(*) {
    throw Error("injected hotstring send failure")
}

_HSFC_SendFailuresDoNotEscapeOrAdvanceRing() {
    global _SendHook
    PreviousHook := _SendHook
    try {
        _SendHook := _HSFC_FailingSendHook
        Before := GetLastSentCharacterAt(-1)
        AssertEqual(false, SendNewResult("Q"),
            "SendNewResult must return false when its send primitive throws")
        AssertEqual(Before, GetLastSentCharacterAt(-1),
            "failed SendNewResult must not advance the last-sent ring")
        AssertEqual(false, SendFinalResult("Q"),
            "SendFinalResult must return false instead of propagating a send failure")
    } finally {
        _SendHook := PreviousHook
    }
}
Test("hotstrings: failed common send primitives are contained and do not corrupt output state",
    _HSFC_SendFailuresDoNotEscapeOrAdvanceRing)
