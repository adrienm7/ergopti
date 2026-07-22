; tests/unit/test_text_sender_completion_status.ahk

; ============================================================================== 
; MODULE: TextSender success-aware completion contract test
; DESCRIPTION:
; A failed direct send must report `(false, error)` to its completion callback.
; LLM callers use that status to preserve suggestions/context instead of logging
; a successful acceptance whose text never reached the foreground application.
; ============================================================================== 

#Requires AutoHotkey v2.0

_TSCS_FailingDirectSend(*) {
    throw Error("injected sender failure")
}

_TSCS_ReportsFailedDirectOutput() {
    global _AHK_SendText
    Previous := _AHK_SendText
    SeenOk := true
    SeenError := ""
    try {
        _AHK_SendText := _TSCS_FailingDirectSend
        TextSend("prediction", Map("mode", "direct"), (Ok, ErrorMessage) => (
            SeenOk := Ok,
            SeenError := ErrorMessage
        ))
        AssertEqual(false, SeenOk, "TextSend must report false when direct SendText throws")
        Assert(InStr(SeenError, "injected sender failure") > 0,
            "TextSend must forward the direct-send failure message to its completion callback")
    } finally {
        _AHK_SendText := Previous
    }
}

Test("TextSender: direct injection failure is reported through completion status",
    _TSCS_ReportsFailedDirectOutput)
