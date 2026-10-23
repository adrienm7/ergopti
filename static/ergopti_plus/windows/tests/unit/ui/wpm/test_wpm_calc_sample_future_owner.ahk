; tests/unit/ui/wpm/test_wpm_calc_sample_future_owner.ahk

; Canonical authentic WPM composition is reused without altering its classes,
; function bodies or controlled-clock token replacements. Only fixture suffix
; changes, so both regression cohorts keep their original bytes and budgets.
#Requires AutoHotkey v2.0

_WPMF_ChildSource() {
	Code := _WPMR_ChildSource()
	Code := StrReplace(Code, "\tests\fixtures\wpm_tick_rollover_body.ahk",
		"\tests\fixtures\wpm_calc_sample_future_body.ahk", &Changed)
	AssertEqual(1, Changed, "Exactly the canonical fixture include may change")
	return Code
}

_WPMF_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired WPM child cannot be replaced")
	Timings := _WPMR_Timings()
	Directory := A_Temp . "\ergopti_wpm_future_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _WPMF_ChildSource()) != 0)
		_TestPrint("# wpm-calc-sampled-future-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath)) . " timings=" . Timings.Digest
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\wpm_calc_sample_future_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, String(Timings.Window), String(Timings.Minimum)], _WPMR_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private WPM child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact WPM child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Receipt is Integer && Receipt == 1
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
		if State.Calls == 1
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# wpm-calc-sampled-future-child " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	; The adapter merges native stdout/stderr; ErrorText is a completion diagnostic.
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS wpm-calc-sampled-future " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}


Test("WPM calculator: a retained sample excludes later real producer rows (wpm-calc-sampled-future-owner)",
	_WPMF_Case.Bind("sample-before-producer"))
Test("WPM calculator: current real producer rows remain admitted (wpm-calc-sampled-future-owner)",
	_WPMF_Case.Bind("current"))
