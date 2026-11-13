; tests/unit/metrics/engine/test_context_roi_stale_owner.ahk

; Real ROI word producer with retained canonical getter and native timer.
_KRSC_ChildSource() {
	global _DriverDir
	Source := _KFCD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\final_context_duration_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, -StrLen(Footer)))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	RoiOwner := _DriverProductionFileForSymbol("KL_Roi_OnChar", _DriverDir)
	AssertTrue(RoiOwner != "")
	; _TextCodepointWidth arrives with its whole owner through _KSD_ChildSource.
	Source .= "#Include " . RoiOwner . "`n"
	for Symbol in ["KL_Roi_TextAllowed", "KL_Enc_IsEnabled", "_KL_JournalPendingEntries"] {
		PolicyOwner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(PolicyOwner != "", "The real ROI policy dependency must resolve")
		Source .= "#Include " . PolicyOwner . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\context_roi_stale_owner_body.ahk`n"
}
_KRSC_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired owner prevents a successor")
	Directory := A_Temp . "\ergopti_roi_stale_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The private fixture requires an exclusively acquired directory")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KRSC_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# roi-stale mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS roi-stale " . Mode)
	} catch Any as Failure
		Primary := Failure
	try Retired := !IsObject(Handle) || ((Receipt := Handle.terminate()) is Integer && Receipt == 1)
	catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if Created && !Retired
			RetirementDebt := {Directory: Directory, Handle: Handle}
		else if Created && Retired && !IsObject(Primary)
			DirDelete(Directory, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact owner must retire before recursive cleanup")
}
for _KRSC_Mode in ["stale", "current", "legitimate"]
	Test("Keystats ROI: " . _KRSC_Mode . " preserves current fragment (roi-stale-owner)", _KRSC_Case.Bind(_KRSC_Mode))
