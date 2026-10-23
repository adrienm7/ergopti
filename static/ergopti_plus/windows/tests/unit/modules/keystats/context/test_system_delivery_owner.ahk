; tests/unit/modules/keystats/context/test_system_delivery_owner.ahk

; ==============================================================================
; MODULE: System Event Publication Lifecycle Tests
; DESCRIPTION:
; A tree-owned child runs the real system owner, central append and privacy
; classifier. A genuine timer pauses after classification, distinguishing an
; invalidated publication from a terminal privacy refusal without a fake append.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSDO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	ClockOwner := _DriverProductionFileForSymbol("WallClockTimestamp", _DriverDir)
	AssertTrue(ClockOwner != "", "The child needs the actual wall-clock owner")
	Source .= "#Include " . ClockOwner . "`n"
	for Definition in ["Keystats", "KLWatch"] {
		Symbol := Definition == "Keystats" ? "KL_AppendLog" : "KL_Watchers_OnPowerBroadcast"
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The real state owner must resolve")
		OwnerSource := FileRead(Owner, "UTF-8")
		AssertTrue(RegExMatch(OwnerSource, "ms)^class " . Definition . " \{.*?^\}", &StateClass) > 0,
			"The child must use the actual state class " . Definition)
		Source .= StateClass[0] . "`n"
	}
	PrivacyOwner := _DriverProductionFileForSymbol("MF_ShouldFilter", _DriverDir)
	AssertTrue(PrivacyOwner != "", "The actual privacy classifier must resolve")
	PrivacySource := FileRead(PrivacyOwner, "UTF-8")
	AssertFalse(RegExMatch(PrivacySource, "im)^#Include\b"),
		"An embedded owner with relative imports requires an explicit child composition")
	PrivacySource := StrReplace(PrivacySource, "MF_ShouldFilter() {", "_KSDO_NativeFilter() {", true, &Replaced)
	AssertEqual(1, Replaced, "Only the genuine classifier declaration may receive the scheduling alias")
	Source .= PrivacySource . "`n"
	SystemOwner := _DriverProductionFileForSymbol("_KL_Watchers_SystemStart", _DriverDir)
	AssertTrue(SystemOwner != "", "The genuine system factory and its whole owner must resolve")
	Source .= "#Include " . SystemOwner . "`n"
	for Symbol in ["KL_AppendLog", "KL_AssignStableEventId", "KL_AllocEventId",
		"KL_RecordPrivacyHit", "KL_NowTimestamp"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every real append dependency needs a nonempty body: " . Symbol)
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\keystats_system_delivery_owner_body.ahk`n"
}

_KSDO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KSDO_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_system_delivery_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KSDO_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSDO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact system-delivery child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# system-delivery-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS system-delivery-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _KSDO_Mode in ["current", "paused", "privacy-paused"]
	Test("Keystats system delivery: " . _KSDO_Mode . " preserves terminal classification (system-event-publication-owner)",
		_KSDO_Case.Bind(_KSDO_Mode))
