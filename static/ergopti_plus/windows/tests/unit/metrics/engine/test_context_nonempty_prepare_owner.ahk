; tests/unit/metrics/engine/test_context_nonempty_prepare_owner.ahk

; Real nonempty flush, actual central append and public pointer accumulation.
; Scheduling is controlled around the genuine privacy predicate; no clipboard,
; physical pointer injection, app-clock origin or append result is manufactured.
_KCNP_ChildSource() {
	global _DriverDir
	Source := _KMD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\mouse_distance_flush_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, -StrLen(Footer)), "Only the unrelated pointer fixture entry may change")
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Owner := _DriverProductionFileForSymbol("MF_ShouldFilter", _DriverDir)
	Embedded := _KFPO_EmbeddableOwnerSource(Owner)
	Embedded := StrReplace(Embedded, "MF_ShouldFilter() {", "_KCNP_ActualFilter() {", true, &Aliases)
	AssertEqual(1, Aliases, "The entire actual privacy predicate must remain intact behind its scheduling alias")
	Source := StrReplace(Source, "#Include " . Owner . "`n", Embedded . "`n", true, &Includes)
	AssertEqual(1, Includes, "Only the real privacy owner include may be embedded")
	Source := RegExReplace(Source, "m)^KL_LogWindowSwitch\(Values\*\) \{", "$0`n`t_KCNP_ObserveWindow(Values*)", &ObserverCount)
	AssertEqual(1, ObserverCount, "Only the existing delegated window logger receives the read-only observer")
	return Source . "#Include " . _DriverDir . "\tests\fixtures\core\context_nonempty_prepare_owner_body.ahk`n"
}
_KCNP_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired private owner prevents a successor probe")
	Directory := A_Temp . "\ergopti_context_nonempty_prepare_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := 0, Retired := false, Primary := 0
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	PreviousCritical := Critical("Off")
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Directory)
		Created := Creation is Integer && Creation == 1
		AssertTrue(Created, "The probe requires an exclusively acquired native source directory")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KCNP_ChildSource()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact private nonempty context owner must start")
		Started := A_TickCount
		while !State.Calls && TickElapsed64(Started) < 12000 {
			_SR_TreePoll()
			Sleep(10)
		}
		_TestPrint("# context-nonempty-prepare mode=" . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(1, State.Calls)
		AssertEqual(0, State.Code, State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS context-nonempty-prepare " . Mode)
	} catch Any as Failure {
		Primary := Failure
	}
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
	AssertTrue(Retired, "The exact native owner must retire before recursive source cleanup")
}
for _KCNP_Mode in ["ordinary-control", "stop-during-prepare", "existing-retry-stop", "external-active", "abc-deferred", "abc-deferred-stop", "abc-deferred-shift", "abc-deferred-sameapp-shift"]
	Test("Keystats nonempty context prepare: " . _KCNP_Mode . " preserves new input attribution (context-nonempty-prepare-owner)",
		_KCNP_Case.Bind(_KCNP_Mode))
