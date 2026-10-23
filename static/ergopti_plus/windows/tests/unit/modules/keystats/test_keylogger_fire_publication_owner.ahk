; tests/unit/modules/keylogger/test_keylogger_fire_publication_owner.ahk

; ==============================================================================
; MODULE: Deferred Fire Publication Lifecycle Tests
; DESCRIPTION:
; A tree-owned child executes actual fire/flush/privacy/append/lifecycle bodies.
; Native Suspend and a genuine timer revoke the owner after its final precheck;
; a real-clock scheduling port controls that eligible between-line cutpoint.
; ==============================================================================

#Requires AutoHotkey v2.0

_KFPO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["MF_ShouldFilter", "TimerAfter", "WallClockTimestamp"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The child needs the unique actual owner of " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	StateOwner := _DriverProductionFileForSymbol("KL_AppendLog", _DriverDir)
	StateSource := FileRead(StateOwner, "UTF-8")
	AssertTrue(RegExMatch(StateSource, "ms)^class Keylogger \{.*?^\}", &StateClass) > 0,
		"The actual Keylogger class, not a copied state mirror, must seed the child")
	Source .= StateClass[0] . "`n"
	for Symbol in ["_HSE_QueueFireLog", "_HSE_ArmFireLogDrain", "_HSE_DrainFireLog",
		"_HSE_RestoreFireLogSuffix", "_PrefixDeferredCanPublish", "_PrefixInvalidateDeferredEffects",
		"HotstringPrefixWatcherOnResume", "KL_LogHotstring", "KL_FlushBuffer", "KL_AppendLog",
		"KL_AssignStableEventId", "KL_AllocEventId", "KL_RecordPrivacyHit"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every selected real function must have a nonempty body: " . Symbol)
		Source .= Body . "`n"
	}
	; Only the public name is rebound to the scheduling port. The original
	; timestamp function's entire body still delegates the real wall-clock owner.
	TimeBody := _DriverFuncBody("KL_NowTimestamp")
	AssertTrue(RegExMatch(TimeBody, "^KL_NowTimestamp\(\)\s*\{") > 0)
	Source .= "_KFPO_NativeTimestamp() " . SubStr(TimeBody, InStr(TimeBody, "{")) . "`n"
	PrefixOwner := _DriverProductionFileForSymbol("_HSE_QueueFireLog", _DriverDir)
	PrefixSource := FileRead(PrefixOwner, "UTF-8")
	for Name in ["HSE_FIRE_LOG_DEFER_MS", "_HSE_FireLogQueue", "_HSE_FireLogScheduled",
		"_HSE_FireLogScheduledGeneration", "_HSE_FireLogTimer", "_PrefixDeferredGeneration",
		"_PrefixRenderScheduledGeneration", "_PrefixRenderTimer"] {
		AssertTrue(RegExMatch(PrefixSource, "m)^global " . Name . "\s*:=.*$", &Declaration) > 0,
			"Lifecycle state must use its real declaration: " . Name)
		Source .= Declaration[0] . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\keylogger_fire_publication_owner_body.ahk`n"
}

_KFPO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KFPO_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_fire_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KFPO_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KFPO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact fire-publication child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# fire-publication-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS keylogger-fire-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _KFPO_Mode in ["current", "paused", "resumed"]
	Test("Keylogger fire publication: " . _KFPO_Mode . " retains its lifecycle owner (keylogger-fire-publication-owner)",
		_KFPO_Case.Bind(_KFPO_Mode))
