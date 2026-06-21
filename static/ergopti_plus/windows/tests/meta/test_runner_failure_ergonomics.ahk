; tests/meta/test_runner_failure_ergonomics.ahk

; ==============================================================================
; MODULE: Test Runner Failure-Ergonomics Meta Test
; DESCRIPTION:
; Behaviour guard for _TestCallSite (test_framework.ahk): when a test fails, the
; reported ``[file:line]`` must point at the TEST's own call site — the first
; stack frame outside test_framework.ahk — not at the assert helper where the
; throw physically happened. Without this a red test reads ``[test_framework.ahk:78]``
; for every failure, which locates nothing.
;
; These are real behaviour tests: they call _TestCallSite directly with synthetic
; stack strings and assert the parsed result, rather than scanning source.
; ==============================================================================

#Requires AutoHotkey v2.0

_TRFE_PicksTestFrameNotFramework() {
	Stack := "C:\drv\windows\tests\test_framework.ahk (78) : [Assert] throw Error(Message)`n"
		. "C:\drv\windows\tests\meta\test_foo.ahk (42) : [_Foo] Assert(cond, msg)`n"
		. "C:\drv\windows\tests\run_all.ahk (300) : [RunTests] TestEntry.callback.Call()"
	Got := _TestCallSite(Stack)
	Assert(Got == "test_foo.ahk:42",
		"_TestCallSite must return the first frame outside test_framework.ahk - got <" . Got . ">")
}
Test("runner failure: [file:line] points at the test, not the assert helper", _TRFE_PicksTestFrameNotFramework)

_TRFE_EmptyStackFallsBack() {
	Assert(_TestCallSite("") == "",
		"an empty stack must yield an empty call site so RunTests falls back to the raw throw location")
}
Test("runner failure: empty stack yields empty call site (caller falls back)", _TRFE_EmptyStackFallsBack)

_TRFE_HandlesWindowsPathWithSpaces() {
	Stack := "C:\Program Files\drv\tests\meta\test_bar.ahk (7) : [_Bar] Assert(x)"
	Got := _TestCallSite(Stack)
	Assert(Got == "test_bar.ahk:7",
		"_TestCallSite must handle a Windows path containing spaces - got <" . Got . ">")
}
Test("runner failure: call site parses a path containing spaces", _TRFE_HandlesWindowsPathWithSpaces)
