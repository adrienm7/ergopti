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
RunTests()
