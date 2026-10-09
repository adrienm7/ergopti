; static/ergopti_plus/windows/tests/fixtures/framework_timings_fixture.ahk

; ==============================================================================
; MODULE: Framework Timing Fixture
; DESCRIPTION: Run the real test runner without the driver or any input hooks.
; ==============================================================================

#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn VarUnset, Off
#Include ../test_framework.ahk

_FTF_DelayedFailure() {
	Sleep(40)
	throw Error("intentional timing fixture failure")
}
Test("timing fixture fast", () => 0)
Test("timing fixture delayed", () => Sleep(80))
Test("timing fixture failure", _FTF_DelayedFailure)

_FTF_CriticalFailure() {
	Critical("On")
	throw Error("intentional Critical fixture failure")
}

_FTF_CheckTimerIsolation() {
	AssertEqual(0, A_IsCritical, "the previous callback must not poison the next test's Critical state")
	TimerReceipt := { Fired: false }
	Callback := () => TimerReceipt.Fired := true
	try {
		SetTimer(Callback, -10)
		Sleep(60)
		AssertTrue(TimerReceipt.Fired, "a following test must receive native timer callbacks")
	} finally {
		SetTimer(Callback, 0)
	}
}

Test("isolation fixture throwing Critical", _FTF_CriticalFailure)
Test("isolation fixture timer after exception", _FTF_CheckTimerIsolation)
Test("isolation fixture returned Critical", () => Critical("On"))
Test("isolation fixture timer after return", _FTF_CheckTimerIsolation)
RunTests()
