; tests/meta/suite/test_adapter_contract_exception_delivery.ahk

; ==============================================================================
; MODULE: Adapter Contract Exception Delivery
; DESCRIPTION: Actual adapter vector callbacks must propagate every exception to
; the runner. An empty Error.Message cannot certify a throwing adapter as healthy.
; A healthy child prevents a fixture that fails unconditionally from qualifying.
; ==============================================================================

#Requires AutoHotkey v2.0

_ACED_Receive(Mode, FixtureLeaf, ExpectedCases, ExpectedCode) {
	global _StaticDir
	Directory := A_Temp . "\ergopti-contract-exception-" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "-" . A_TickCount
	if !DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Cannot acquire the owned contract exception fixture")
	Receipt := Directory . "\receipt.tap"
	Fixture := _StaticDir . "\ergopti_plus\windows\tests\fixtures\" . FixtureLeaf
	Observation := {Calls: 0, Code: -1, Output: "", Errors: ""}
	Handle := 0
	CanRetire := true
	Completed(Code, Output, Errors) {
		Observation.Calls += 1
		Observation.Code := Code
		Observation.Output := Output
		Observation.Errors := Errors
	}
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Fixture, Mode, Receipt], Completed)
		AssertTrue(Handle.start(), "the actual adapter contract child must start")
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while !Observation.Calls && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observation.Calls, "the child must reach one terminal receipt")
		AssertEqual("", Observation.Errors, "fixture warnings or parse errors cannot qualify: " . Observation.Output)
		StrReplace(Observation.Output, "# adapter-fixture-endpoint", , , &EndpointCalls)
		AssertEqual(ExpectedCases, EndpointCalls, "every actual callback must reach the injected adapter endpoint")
		AssertTrue(FileExist(Receipt), "the actual runner must publish its owned receipt")
		Tap := FileRead(Receipt, "UTF-8")
		; A child transcript is diagnostic data, never additional parent TAP rows.
		TapDetail := StrReplace(StrReplace(Tap, "`r", ""), "`n", " | ")
		AssertContains(Tap, "1.." . ExpectedCases, "every unchanged registered contract callback must execute")
		AssertEqual(ExpectedCode, Observation.Code, "the actual callbacks must preserve their " . Mode . " outcome: " . TapDetail)
		ExpectedPasses := ExpectedCode == 0 ? ExpectedCases : 0
		ExpectedFailures := ExpectedCases - ExpectedPasses
		AssertContains(Tap, "# " . ExpectedPasses . " passed, " . ExpectedFailures . " failed",
			"every actual callback must retain its independent contract result")
	} finally {
		if IsObject(Handle) {
			CanRetire := Handle.terminate()
			AssertTrue(CanRetire, "the exact child must retire before its owned receipt")
		}
		if CanRetire {
			if FileExist(Receipt)
				FileDelete(Receipt)
			DirDelete(Directory)
		}
	}
}

Test("adapter contract throw: healthy callbacks still pass (empty-message-contract)", _ACED_Receive.Bind("healthy", "adapter_contract_empty_message.ahk", 2, 0))
Test("adapter contract throw: blank-message failures stay red (empty-message-contract)", _ACED_Receive.Bind("empty-error", "adapter_contract_empty_message.ahk", 2, 1))
