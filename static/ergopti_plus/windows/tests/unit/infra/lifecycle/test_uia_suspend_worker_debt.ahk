; tests/unit/infra/lifecycle/test_uia_suspend_worker_debt.ahk

; ==============================================================================
; MODULE: UIA Suspend Worker Debt Tests
; DESCRIPTION:
; Composes complete suspend with real ledger and UIA worker ownership. Only
; process creation/termination and unrelated subsystem ports are passive;
; retained cleanup receipts are not a claim of native process liveness.
; ==============================================================================

#Requires AutoHotkey v2.0

_USWD_Done(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_USWD_PortSymbols() {
	return ["TapHoldReleaseSyntheticKeys", "SIHO_StopAll", "TooltipHide", "LLM_Tooltip_Hide",
		"LLM_Engine_LiveStop", "LLM_Engine_CancelTimer", "LLM_Engine_StopGeneration",
		"LLM_OllamaCancelWarmupRetry", "_LLM_PointerWatch_Stop", "MF_StopFocusRefresh",
		"_Updater_CancelAsyncChecks", "_Updater_QuiesceSelfUpdateForSuspend",
		"GestureReleaseLeftClick", "GestureReleaseRightClick"]
}

_USWD_Source() {
	global _DriverDir
	; These are external subsystem ports, not replacements for the reactor or
	; cancellation implementation under test. Authenticate actual definitions
	; without loading their desktop hooks, menus or services into this child.
	for Symbol in _USWD_PortSymbols() {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(_DriverIsProductionSource(Owner) && FileExist(Owner) != "")
		Text := FileRead(Owner, "UTF-8")
		Body := _DriverExtractFunctionBody(&Text, Symbol)
		AssertTrue(Body != "", "each passive subsystem port must have a real nonempty owner: " . Symbol)
	}
	; This definition is nested in its real feature container, so authenticate
	; the whole authored owner without pretending it is a top-level free function.
	SplitPath(A_ScriptDir, , &CanonicalRoot)
	WinOwner := CanonicalRoot . "\modules\shortcuts\win.ahk"
	AssertTrue(_DriverIsProductionSource(WinOwner) && FileExist(WinOwner) != "")
	Text := FileRead(WinOwner, "UTF-8")
	AssertTrue(_DriverExtractFunctionBody(&Text, "StopActivitySimulation") != "")
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
		"LoggerInfo", "WallClockTimestamp", "UIASW_Start", "UIAW_CloseProcessHandle"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the suspend composition requires its genuine whole owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	Fixture := _DriverDir . "\tests\fixtures\uia_suspend_worker_debt_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private suspend composition must exist")
	return Source . "#Include " . Fixture . "`n"
}

_USWD_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier uia-suspend-worker-debt child still owns retirement debt.")
	Directory := A_Temp . "\ergopti_uia_suspend_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := { Calls: 0, Code: -1, Output: "", ErrorText: "" }
	Handle := 0, Primary := 0, Retired := false, Nonsettled := false
	PreviousCritical := Critical("Off")
	try {
		Script := Directory . "\subject.ahk"
		AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _USWD_Source()),
			"the actual child source must have a durable exclusive receipt")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory],
			_USWD_Done.Bind(State))
		AssertEqual(1, Handle.start(), "the private suspend composition must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		Nonsettled := State.Calls == 0
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT uia-suspend-worker-debt ") == 1
				_TestPrint("# " . Line)
		AssertEqual(1, State.Calls, "the suspend composition must settle once: " . State.Output)
		AssertEqual("", State.ErrorText, "the process port cannot hide prerequisite errors")
		AssertEqual(0, State.Code, "suspend completion requires worker retirement: " . State.Output)
		AssertContains(State.Output, "PASS uia-suspend-worker-debt " . Mode)
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

Test("UIA suspend: retained worker debt refuses transition completion (uia-suspend-worker-debt)",
	_USWD_Case.Bind("retained"))
Test("UIA suspend: absent worker acknowledges quiescence (uia-suspend-worker-debt)",
	_USWD_Case.Bind("absent"))
Test("UIA suspend: exact cleanup retry permits completion (uia-suspend-worker-debt)",
	_USWD_Case.Bind("retry"))
