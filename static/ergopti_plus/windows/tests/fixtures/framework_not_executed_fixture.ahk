; static/ergopti_plus/windows/tests/fixtures/framework_not_executed_fixture.ahk

; ==============================================================================
; MODULE: Framework Not-Executed Fixture
; DESCRIPTION: Run the real test runner over a passing case, a case the host
; cannot run, a capability-gated case on a capable host that fails, and a
; capability-gated case whose probe is unknown, without the driver or hooks.
; ==============================================================================

#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn VarUnset, Off
#Include ../test_framework.ahk
#Include host_capability_gate.ahk

_FNEF_Receipt(State) => Map("state", State, "name", "example", "why", "the fixture probe reports it missing")

_FNEF_GatedFailure(State) {
	TestRequireHostCapability(_FNEF_Receipt.Bind(State))
	throw Error("intentional gated fixture failure")
}

Test("not-executed fixture pass", () => 0)
Test("not-executed fixture host lacks the capability", _FNEF_GatedFailure.Bind("absent"))
Test("not-executed fixture capable host still fails", _FNEF_GatedFailure.Bind("present"))
Test("not-executed fixture unknown capability still runs", _FNEF_GatedFailure.Bind("unknown"))
RunTests()
