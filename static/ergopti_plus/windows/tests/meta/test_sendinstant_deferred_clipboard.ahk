; tests/meta/test_sendinstant_deferred_clipboard.ahk

#Requires AutoHotkey v2.0

_SDC_AssertDeferredRestore() {
	; Move-resilient: locate SendInstant() across the whole driver source via the
	; framework helper instead of a pinned lib path
	Body := _DriverFuncBody("SendInstant")

	SleepIdx := InStr(Body, "Sleep(")
	Assert(!SleepIdx, "SendInstant must NOT call Sleep() inline (wraptext-sendinstant-sleep-hotpath)")
	
	SetTimerIdx := InStr(Body, "SetTimer(")
	Assert(SetTimerIdx > 0, "SendInstant must use SetTimer to defer clipboard restore (wraptext-sendinstant-sleep-hotpath)")
}

Test("hotstring_engine: SendInstant defers clipboard restore (wraptext-sendinstant-sleep-hotpath)", _SDC_AssertDeferredRestore)
