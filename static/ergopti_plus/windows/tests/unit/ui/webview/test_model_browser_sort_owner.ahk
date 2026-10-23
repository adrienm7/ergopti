; tests/unit/ui/webview/test_model_browser_sort_owner.ahk

; ==============================================================================
; MODULE: Model Browser Native Array Sort Tests
; DESCRIPTION:
; Exercises the actual whole browser owner and genuine cached model catalogue in
; private native children. Reuses the canonical component projection and private
; assets; no comparator stub, Array prototype patch, backend, GUI or COM port.
; ==============================================================================

#Requires AutoHotkey v2.0

_MBSO_ChildSource(Directory) {
	global _DriverDir
	Code := _MBPT_ChildSource(Directory)
	Previous := "#Include " . _DriverDir . "\tests\fixtures\model_browser_close_pause_owner_body.ahk`n"
	Fixture := _DriverDir . "\tests\fixtures\model_browser_sort_owner_body.ahk"
	AssertTrue(FileExist(Fixture), "The private sorting body must be present")
	AssertTrue(SubStr(Code, StrLen(Code) - StrLen(Previous) + 1) == Previous,
		"Only the canonical component projection's final fixture include may change")
	Code := StrReplace(Code, Previous, "#Include " . Fixture . "`n", true, &Count)
	AssertEqual(1, Count, "The genuine projection must retain every production owner")
	return Code
}

_MBSO_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier model browser child must retire first")
	Directory := A_Temp . "\ergopti_model_browser_sort_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		_MBPT_StageAssets(Directory)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _MBSO_ChildSource(Directory)) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _MBPT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine model catalogue sorting child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact model browser child did not settle within 15000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
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
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# model-browser-sort-owner terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# model-browser-sort-owner combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# model-browser-sort-owner completion_error " . Line)
			} else
				_TestPrint("# model-browser-sort-owner combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact model browser child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real model browser sorting helper violated its contract: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS model-browser-sort-owner " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _MBSO_Mode in ["edges", "order", "clone"]
	Test("Model browser sort: " . _MBSO_Mode . " preserves native array ordering (model-browser-sort-owner)",
		_MBSO_Case.Bind(_MBSO_Mode))
