; tests/unit/infra/lifecycle/test_external_suspend_program_owner.ahk

; ==============================================================================
; MODULE: External Suspend Program Ownership Tests
; DESCRIPTION:
; Runs the real suspend entry, navigation preflight and program owner in a
; private child. Control reactors exercise the same real program latch and
; transition ledger without claiming the complete driver's resume graph.
; ==============================================================================

#Requires AutoHotkey v2.0

_ESPO_Done(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_ESPO_Source() {
	global _DriverDir
	Source := '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
	Seen := Map()
	for Symbol in ["Ergopti_OnSuspendEnter", "LLM_NavEventOwner_QuiesceForLifecycle",
		"ProgramActions_Stop", "ShellRunner_SpawnTreeOwned", "FSReadUtf8Exact",
		"TOML_UnescapeBasicStringContents", "ProgramParameterParse", "GestureGetActionParameter",
		"ConfigWriteLeaseBusy", "JsonStringLiteral", "LoggerInfo", "WallClockTimestamp"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the isolated suspension requires its genuine whole owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	Fixture := _DriverDir . "\tests\fixtures\external_suspend_program_owner_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private suspend component must exist")
	return Source . "#Include " . Fixture . "`n"
}

_ESPO_Case(Mode) {
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier external-suspend child still owns retirement debt.")
	Directory := A_Temp . "\ergopti_external_suspend_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := { Calls: 0, Code: -1, Output: "", ErrorText: "" }
	Handle := 0, Primary := 0, Retired := false, Nonsettled := false
	PreviousCritical := Critical("Off")
	try {
		Script := Directory . "\subject.ahk"
		AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _ESPO_Source()),
			"the exact child source must have a durable exclusive receipt")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _ESPO_Done.Bind(State))
		AssertEqual(1, Handle.start(), "the private suspension component must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		Nonsettled := State.Calls == 0
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT external-suspend-program ") == 1
				_TestPrint("# " . Line)
		AssertEqual(1, State.Calls, "the isolated suspension must settle once: " . State.Output)
		AssertEqual("", State.ErrorText, "the process port cannot hide prerequisite errors")
		AssertEqual(0, State.Code, "the external transition must restore program admission: " . State.Output)
		AssertContains(State.Output, "PASS external-suspend-program " . Mode)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			Receipt := IsObject(Handle)
				? (Nonsettled ? Handle.requestTerminate() : Handle.terminate()) : 1
			Retired := Receipt is Integer && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := { Handle: Handle, Directory: Directory }
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "only strict native retirement authorizes private source removal")
}

Test("External suspend: navigation refusal preserves program admission (external-suspend-program-owner)",
	_ESPO_Case.Bind("refused"))
Test("External suspend: administrative refusal preserves program admission (external-suspend-program-owner)",
	_ESPO_Case.Bind("preflight"))
Test("External suspend: partial teardown compensates the real program owner (external-suspend-program-owner)",
	_ESPO_Case.Bind("partial"))
Test("External suspend: nominal resume releases the real program owner (external-suspend-program-owner)",
	_ESPO_Case.Bind("nominal"))
