; tests/unit/infra/lifecycle/test_suspend_prefetch_receipt.ahk

; ==============================================================================
; MODULE: Suspend Prefetch Retirement Receipt Tests
; DESCRIPTION:
; Composes the complete suspend reactor with real ledger, navigation, program
; and projection owners. Sixteen unrelated teardown calls are counted passive
; child ports; only the target worker process transport is replaced.
; ==============================================================================

#Requires AutoHotkey v2.0

_LCPC_Done(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_LCPC_PortSymbols() {
	return ["TapHoldReleaseSyntheticKeys", "SIHO_StopAll", "TooltipHide", "LLM_Tooltip_Hide",
		"LLM_Engine_LiveStop", "LLM_Engine_CancelTimer", "LLM_Engine_StopGeneration",
		"LLM_OllamaCancelWarmupRetry", "_LLM_PointerWatch_Stop", "MF_StopFocusRefresh",
		"_Updater_CancelAsyncChecks", "_Updater_QuiesceSelfUpdateForSuspend", "UIASW_Stop",
		"StopActivitySimulation", "GestureReleaseLeftClick", "GestureReleaseRightClick"]
}

_LCPC_Source() {
	global _DriverDir
	; These are external subsystem ports, not replacements for the reactor or
	; cancellation implementation under test. Authenticate actual definitions
	; without loading their desktop hooks, menus or services into this child.
	SplitPath(A_ScriptDir, , &CanonicalRoot)
	for Symbol in _LCPC_PortSymbols() {
		Owner := Symbol == "StopActivitySimulation"
			? CanonicalRoot . "\modules\shortcuts\win.ahk" : _DriverProductionFileForSymbol(Symbol)
		AssertTrue(_DriverIsProductionSource(Owner) && FileExist(Owner) != "")
		Text := FileRead(Owner, "UTF-8")
		Body := _DriverExtractFunctionBody(&Text, Symbol)
		AssertTrue(Body != "", "each passive subsystem port must have a real nonempty owner: " . Symbol)
	}
	Source := '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
	Seen := Map()
	for Symbol in ["Ergopti_OnSuspendEnter", "LLM_NavEventOwner_QuiesceForLifecycle",
		"ProgramActions_Stop", "KLPF_RequestBuild", "KLW_TimingValues", "TimingsLoadShared",
		"ParseTomlFile", "ConfigTransitionNormalizeConfigDir", "_ConfigTransitionNormalizePath",
		"CryptoSha256", "ShellRunner_SpawnTreeOwned", "FSReadUtf8Exact", "KL_JsonEncode",
		"LoggerInfo", "WallClockTimestamp"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the suspend composition requires its genuine whole owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	Fixture := _DriverDir . "\tests\fixtures\suspend_prefetch_receipt_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private suspend composition must exist")
	return Source . "#Include " . Fixture . "`n"
}

_LCPC_Case(Client, Mode) {
	global _DriverDir
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier suspend-prefetch child still owns retirement debt.")
	Directory := A_Temp . "\ergopti_suspend_prefetch_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := { Calls: 0, Code: -1, Output: "", ErrorText: "" }
	Handle := 0, Primary := 0, Retired := false, Nonsettled := false
	PreviousCritical := Critical("Off")
	try {
		Script := Directory . "\subject.ahk"
		AssertEqual(1, FSWriteCreateDurable(Script, Chr(0xFEFF) . _LCPC_Source()),
			"the actual child source must have a durable exclusive receipt")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Client, Mode, Directory, _DriverDir . "\..\_shared"],
			_LCPC_Done.Bind(State))
		AssertEqual(1, Handle.start(), "the private suspend composition must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		Nonsettled := State.Calls == 0
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT suspend-prefetch ") == 1
				_TestPrint("# " . Line)
		AssertEqual(1, State.Calls, "the suspend composition must settle once: " . State.Output)
		AssertEqual("", State.ErrorText, "the process port cannot hide prerequisite errors")
		AssertEqual(0, State.Code, "suspend completion requires target retirement: " . State.Output)
		AssertContains(State.Output, "PASS suspend-prefetch " . Client . " " . Mode)
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

for Client in ["typing", "apps", "range:typing"] {
	Test("Suspend prefetch: " . Client . " absent worker acknowledges quiescence (suspend-prefetch-retirement)",
		_LCPC_Case.Bind(Client, "absent"))
	Test("Suspend prefetch: " . Client . " retained worker refuses transition completion (suspend-prefetch-retirement)",
		_LCPC_Case.Bind(Client, "retained"))
	Test("Suspend prefetch: " . Client . " retry receipt permits transition completion (suspend-prefetch-retirement)",
		_LCPC_Case.Bind(Client, "retry-ack"))
}
