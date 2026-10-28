; tests/unit/infra/lifecycle/test_keepawake_suspend_owner.ahk

; ==============================================================================
; MODULE: Keep-Awake Suspend Ownership Tests
; DESCRIPTION:
; Composes the complete suspend reactor with real ledger, navigation, program
; and observer owners. Fifteen unrelated teardown calls are counted passive
; child ports; the native observer Stop exception is explicitly modeled.
; ==============================================================================

#Requires AutoHotkey v2.0

_KASO_Done(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KASO_PortSymbols() {
	return ["TapHoldReleaseSyntheticKeys", "SIHO_StopAll", "TooltipHide", "LLM_Tooltip_Hide",
		"LLM_Engine_LiveStop", "LLM_Engine_CancelTimer", "LLM_Engine_StopGeneration",
		"LLM_OllamaCancelWarmupRetry", "_LLM_PointerWatch_Stop", "MF_StopFocusRefresh",
		"_Updater_CancelAsyncChecks", "_Updater_QuiesceSelfUpdateForSuspend", "UIASW_Stop",
		"GestureReleaseLeftClick", "GestureReleaseRightClick"]
}

_KASO_Source() {
	global _DriverDir
	; These are external subsystem ports, not replacements for the reactor or
	; cancellation implementation under test. Authenticate actual definitions
	; without loading their desktop hooks, menus or services into this child.
	SplitPath(A_ScriptDir, , &CanonicalRoot)
	for Symbol in _KASO_PortSymbols() {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(_DriverIsProductionSource(Owner) && FileExist(Owner) != "")
		Text := FileRead(Owner, "UTF-8")
		Body := _DriverExtractFunctionBody(&Text, Symbol)
		AssertTrue(Body != "", "each passive subsystem port must have a real nonempty owner: " . Symbol)
	}
	Source := '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
	Source .= 'global Features := Map("shortcuts", Map())' . "`n"
	Source .= 'Features["shortcuts"].Default := false' . "`n"
	for Nested in ["gpt", "take_note", "search"]
		Source .= 'Features["shortcuts"]["' . Nested . '"] := Map("enabled", false)' . "`n"
	Seen := Map()
	for Symbol in ["Ergopti_OnSuspendEnter", "LLM_NavEventOwner_QuiesceForLifecycle",
		"ProgramActions_Stop", "KLPF_RequestBuild", "KLW_TimingValues", "TimingsLoadShared",
		"ParseTomlFile", "ConfigTransitionNormalizeConfigDir", "_ConfigTransitionNormalizePath",
		"CryptoSha256", "ShellRunner_SpawnTreeOwned", "FSReadUtf8Exact", "KL_JsonEncode",
		"LoggerInfo", "WallClockTimestamp", "KS_AltGrKeyName"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the suspend composition requires its genuine whole owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	WinOwners := []
	; These global functions are declared inside a runtime feature block, so the
	; top-level-only resolver intentionally cannot select their whole owner.
	Loop Files, CanonicalRoot . "\*.ahk", "FR" {
		Path := A_LoopFileFullPath
		if !_DriverIsProductionSource(Path)
			continue
		Candidate := FileRead(Path, "UTF-8")
		Definition := _DriverFindFunctionDefinition(&Candidate, "StopActivitySimulation")
		if !IsObject(Definition)
			continue
		AssertFalse(IsObject(_DriverFindFunctionDefinition(&Candidate,
			"StopActivitySimulation", Definition.OpenPos + 1)), "the shortcut owner cannot contain duplicate definitions")
		WinOwners.Push(Path)
	}
	AssertEqual(1, WinOwners.Length, "the conditional shortcut function must have exactly one authored owner")
	WinOwner := WinOwners[1]
	AssertTrue(_DriverIsProductionSource(WinOwner), "the whole shortcut module must be authored production")
	Text := FileRead(WinOwner, "UTF-8")
	for Name in ["StopActivitySimulation", "AwakeStopCancellationHook", "AwakeCreateCancellationHook"]
		AssertTrue(_DriverExtractFunctionBody(&Text, Name) != "", "the whole shortcut owner must define: " . Name)
	AssertFalse(Seen.Has(WinOwner))
	Source .= "#Include " . WinOwner . "`n"
	Fixture := _DriverDir . "\tests\fixtures\keepawake_suspend_owner_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private suspend composition must exist")
	return Source . "#Include " . Fixture . "`n"
}

_KASO_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier keepawake-suspend child still owns retirement debt.")
	Directory := A_Temp . "\ergopti_keepawake_suspend_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := { Calls: 0, Code: -1, Output: "", ErrorText: "" }
	Handle := 0, Primary := 0, Retired := false, Nonsettled := false
	PreviousCritical := Critical("Off")
	try {
		Script := Directory . "\subject.ahk"
		AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _KASO_Source()),
			"the actual child source must have a durable exclusive receipt")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory],
			_KASO_Done.Bind(State))
		AssertEqual(1, Handle.start(), "the private suspend composition must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		Nonsettled := State.Calls == 0
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT keepawake-suspend ") == 1
				_TestPrint("# " . Line)
		AssertEqual(1, State.Calls, "the suspend composition must settle once: " . State.Output)
		AssertEqual("", State.ErrorText, "the process port cannot hide prerequisite errors")
		AssertEqual(0, State.Code, "suspend completion requires observer retirement: " . State.Output)
		AssertContains(State.Output, "PASS keepawake-suspend " . Mode)
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
	AssertTrue(Retired, "only strict native retirement permits private source removal")
}

Test("Keep-awake suspend: retained observer refuses transition completion (keepawake-suspend-owner)",
	_KASO_Case.Bind("retained"))
Test("Keep-awake suspend: absent observer acknowledges quiescence (keepawake-suspend-owner)",
	_KASO_Case.Bind("absent"))
Test("Keep-awake suspend: native retry releases the exact observer (keepawake-suspend-owner)",
	_KASO_Case.Bind("retry"))
