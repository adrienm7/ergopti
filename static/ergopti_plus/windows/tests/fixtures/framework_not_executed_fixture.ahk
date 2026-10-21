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
#Include host_curl_capability.ahk

_FNEF_Receipt(State) => Map("state", State, "version", "8.21.0")

_FNEF_GatedFailure(State) {
	TestRequireHostCurlNtlm(_FNEF_Receipt.Bind(State))
	throw Error("intentional gated fixture failure")
}

Test("not-executed fixture pass", () => 0)
Test("not-executed fixture host lacks NTLM", _FNEF_GatedFailure.Bind("no_ntlm"))
Test("not-executed fixture capable host still fails", _FNEF_GatedFailure.Bind("ntlm"))
Test("not-executed fixture unknown capability still runs", _FNEF_GatedFailure.Bind("unknown"))
RunTests()
