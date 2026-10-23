; tests/unit/modules/keystats/test_clipboard_provenance_owner.ahk

; ==============================================================================
; MODULE: Clipboard Provenance Publication Tests
; DESCRIPTION:
; A tree-owned child drives actual copy/paste handlers, MF and central append.
; Controlled native focus ports and a real timer change source ownership during
; classification. Handler type 2 never accesses or mutates the OS clipboard.
; ==============================================================================

#Requires AutoHotkey v2.0

_KCPO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["MF_ShouldFilter", "CB_ConsumeOwnedChange", "KL_Clip_OnChange", "WallClockTimestamp", "TickElapsed64"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The child requires the unique real owner of " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	for Spec in [["KL_AppendLog", "Keystats"], ["KL_Hook_RefreshContext", "KLHook"],
		["KL_Hook_RefreshContext", "KLHookConst"], ["KL_CommitPwCache", "KLPasswordCache"]] {
		Owner := _DriverProductionFileForSymbol(Spec[1], _DriverDir)
		AssertTrue(Owner != "", "The real state owner must resolve: " . Spec[1])
		OwnerSource := FileRead(Owner, "UTF-8")
		AssertTrue(RegExMatch(OwnerSource, "ms)^class " . Spec[2] . " \{.*?^\}", &StateClass) > 0,
			"State must come from its genuine class declaration: " . Spec[2])
		Source .= StateClass[0] . "`n"
	}
	for Symbol in ["KL_AppendLog", "KL_AssignStableEventId", "KL_AllocEventId", "KL_RecordPrivacyHit",
		"KL_NowTimestamp", "KL_FlushBuffer", "KL_LogAppSwitch", "KL_LogWindowSwitch", "KL_Hook_RefreshContext",
		"KL_Hook_AdvanceContextWatermarks", "KL_IsFocusedFieldPassword", "KL_TryGetPwCachedVerdict",
		"KL_PasswordFocusSnapshot", "KL_CommitPwCache", "KL_JsonEncode", "KL_JsonEncodeMap",
		"KL_JsonEncodeArray", "KL_JsonEncodeString", "KL_JoinArray", "JsonStringLiteral", "_JsonEscapeNulFreeRun"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every genuine reached function must be nonempty: " . Symbol)
		Source .= Body . "`n"
	}
	for Spec in [["WICaptureBoundedFocusSnapshot", "WI_FOCUS_TITLE_TIMEOUT_MS"],
		["KL_CommitPwCache", "KLPW_CACHE_TTL_MS"]] {
		Owner := _DriverProductionFileForSymbol(Spec[1], _DriverDir)
		AssertTrue(Owner != "", "A native policy declaration must have its genuine owner: " . Spec[1])
		OwnerSource := FileRead(Owner, "UTF-8")
		AssertTrue(RegExMatch(OwnerSource, "m)^global " . Spec[2] . " :=[^`n]+", &Declaration) > 0,
			"Every reached native policy must use its canonical declaration: " . Spec[2])
		Source .= Declaration[0] . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\clipboard_provenance_owner_body.ahk`n"
}

_KCPO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KCPO_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_clipboard_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KCPO_ChildSource()) != 0)
		_TestPrint("# clipboard-provenance-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\clipboard_provenance_owner_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KCPO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact clipboard-provenance child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# clipboard-provenance-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS clipboard-provenance-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Clipboard provenance: current copy remains paired (clipboard-provenance-owner)", _KCPO_Case.Bind("current"))
Test("Clipboard provenance: private copy stays unknown (clipboard-provenance-owner)", _KCPO_Case.Bind("private-entry"))
Test("Clipboard provenance: late private source cannot escape (clipboard-provenance-owner)", _KCPO_Case.Bind("late-focus"))
Test("Clipboard provenance: public pre-pause copy survives resume (clipboard-provenance-owner)", _KCPO_Case.Bind("pause-preserve"))
