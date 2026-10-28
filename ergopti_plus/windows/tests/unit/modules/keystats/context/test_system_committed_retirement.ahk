; tests/unit/modules/keystats/context/test_system_committed_retirement.ahk

; ==============================================================================
; MODULE: Accepted System Event Retirement Tests
; DESCRIPTION:
; A real append commits before a native pause revokes its pending owner. The
; existing drain must consume the accepted head once and retain its suffix.
; This positive control runs on the original bool-only append contract too.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSDC_ChildSource() {
	global _DriverDir
	; Reuse the actual child composition without changing the frozen causal
	; tests. Only its final fixture is replaced; every production body is shared.
	Source := _KSDO_ChildSource()
	Tail := "#Include " . _DriverDir . "\tests\fixtures\keystats_system_delivery_owner_body.ahk`n"
	TailStart := StrLen(Source) - StrLen(Tail) + 1
	AssertTrue(TailStart > 0 && SubStr(Source, TailStart) == Tail,
		"The original real-owner composition must end in its exact fixture include")
	return SubStr(Source, 1, TailStart - 1)
		. "#Include " . _DriverDir . "\tests\fixtures\keystats_system_committed_retirement_body.ahk`n"
}

_KSDC_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KSDC_Case() {
	Mode := "committed-paused"
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_system_committed_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KSDC_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSDC_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact system-committed child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# system-committed-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS system-committed-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Keystats system delivery: committed records retire once after native pause (system-event-committed-retirement)",
	_KSDC_Case)
