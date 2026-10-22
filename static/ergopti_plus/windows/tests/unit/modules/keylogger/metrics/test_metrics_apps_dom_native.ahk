; tests/unit/modules/keylogger/metrics/test_metrics_apps_dom_native.ahk

; ==============================================================================
; MODULE: Native Apps DOM Integration Regression
; DESCRIPTION:
; An isolated real WebView2 child keeps vendors out of the common test graph.
; The complete shared document owns its bridge payloads and real native UI.
; ==============================================================================

#Requires AutoHotkey v2.0

_MAD_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

; Generated data is intentionally outside _DriverProductionFileForSymbol's
; authored-code census. Resolve only complete owners actually included by the
; delivered suite, with its genuine lexical/definition helpers and no body copy.
_MAD_GeneratedOwner(Name) {
	global _DriverDir
	; This builder executes in the actual run_all script, before any child spawn.
	Runner := FSReadStrict(A_ScriptFullPath)
	Code := _DriverMaskNonCode(&Runner)
	Owners := Map()
	Owners.CaseSense := "Off"
	for Line in StrSplit(Code, "`n", "`r") {
		if !RegExMatch(Line, "i)^\s*#Include\s+(\.\.[\\/]_generated[\\/][A-Za-z0-9_.-]+\.ahk)\s*$", &Include)
			continue
		Target := StrReplace(Include[1], "/", "\")
		Owner := _DriverDir . "\" . SubStr(Target, 4)
		Text := FSReadStrict(Owner)
		OwnerCode := _DriverMaskNonCode(&Text)
		Count := _DriverTopLevelDefinitionCount(&OwnerCode, Name)
		if Count {
			AssertEqual(1, Count, "the generated owner must declare exactly one global function: " . Name)
			Owners[Owner] := true
		}
	}
	AssertEqual(1, Owners.Count, "the actual suite must include one complete generated owner: " . Name)
	for Owner in Owners
		return Owner
}

_MAD_Source(Root, OwnerReceipt) {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. 'OnError(_MAD_InitializationError)' . "`n"
		. 'global _MAD_DriverDir := ' . _MAD_Quote(_DriverDir) . "`n"
		. 'global _MAD_SourceShared := ' . _MAD_Quote(_DriverDir . "\..\_shared") . "`n"
		. 'global _MAD_ExpectedRoot := ' . _MAD_Quote(Root) . "`n"
		. 'global _MAD_Flag := KLPF_WorkerFlagIndex()' . "`n"
		. 'global _MAD_Root := _MAD_Flag ? A_Args[_MAD_Flag + 2] : A_Args[1]' . "`n"
		. 'global _SharedDir := _MAD_Root . "\shared"' . "`n"
		. 'global _ConfigDir := _MAD_Root . "\config\"' . "`n"
		. 'global _LogsDir := _MAD_Root . "\logs\"' . "`n"
		. 'global _VendorDir := _MAD_DriverDir . "\vendor"' . "`n"
	for Vendor in ["ComVar.ahk", "Promise.ahk", "WebView2.ahk"]
		Source .= "#Include " . _DriverDir . "\vendor\" . Vendor . "`n"
	ButtonHelper := _DriverDir . "\tests\fixtures\native_owned_button.ahk"
	AssertTrue(FSStrictExists(ButtonHelper), "the standalone child must include its actual native button transport")
	Source .= "#Include " . ButtonHelper . "`n"
	Seen := Map()
	for Symbol in ["LocaleTableData", "WindowTitle"] {
		Owner := _MAD_GeneratedOwner(Symbol)
		AssertFalse(_DriverIsProductionSource(Owner), "generated data must remain outside the production resolver: " . Symbol)
		OwnerReceipt.Push(Map("symbol", Symbol, "path", Owner, "scope", "generated"))
		if !Seen.Has(Owner) {
			Source .= "#Include " . Owner . "`n"
			Seen[Owner] := true
		}
	}
	; The detached entry also loads the genuine inactive hook/watchers state
	; consumed by the reader; a function-only call graph cannot infer classes.
	for Symbol in ["LoggerTrace", "WallClockTimestamp", "Redact_Apply", "JsonParse",
		"FSReadStrict", "CryptoSha256Bytes", "WebView_WatchProfile", "WebView_RunScriptAsync", "WebView_SameCore",
		"ConfigTransitionNormalizeConfigDir", "ConfigTransitionPrepare", "ReloadTerminalHandoffActive", "ShellRunner_SpawnTreeOwned",
		"PLC_CreateProcessWithInheritedHandles", "WMHandleExists",
		"ParseTomlFile", "IniCacheGet", "TimingsLoadShared", "t", "I18nGetLocale", "Gui_Create", "AppPicker_Show",
		"KL_WriteAtomic", "KL_AppCat_Init", "KL_Hook_HasPendingInput", "KL_Watchers_IdleTick", "SQLite_Open", "KeyloggerWalkerLoadTimings", "KLW_WalkTypingEntry",
		"KLW_BuildBatchSql", "KLR_ListLedgerPaths", "KLR_BuildDatabase", "KLR_CacheAttach", "KLR_BeginPartialRead",
		"KLR_BuildColdCandidateAuto", "KLR_ReadManifest", "KLR_BuildManifestJson", "KLR_BuildRangeSplitTodayJson",
		"KLPF_RequestBuild", "KLWV_OnWebMessage", "TimerSetCallback", "HotPath_Now"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the native integration requires one actual owner: " . Symbol)
		AssertTrue(_DriverIsProductionSource(Owner), "the authored owner must satisfy the actual production census: " . Symbol)
		OwnerReceipt.Push(Map("symbol", Symbol, "path", Owner, "scope", "production"))
		if !Seen.Has(Owner) {
			Source .= "#Include " . Owner . "`n"
			Seen[Owner] := true
		}
	}
	; Reuse actual test-only custody bodies, without loading that fixture's
	; auto-execute routine or changing either frozen sender probe.
	Custody := FSReadStrict(_DriverDir . "\tests\fixtures\webview_metrics_sender_fixture.ahk")
	for Name in ["_MVSP_Require", "_MVSP_Hash", "_MVSP_Deadline", "_MVSP_CloseOther", "_MVSP_RetireOtherBrowser", "_MVSP_Close"] {
		Body := _DriverExtractFunctionBody(&Custody, Name)
		AssertTrue(Body != "", "the genuine native custody body must exist: " . Name)
		Source .= Body . "`n"
	}
	Body := FSReadStrict(_DriverDir . "\tests\fixtures\webview_metrics_apps_dom_body.ahk")
	AssertTrue(Body != "", "the native Apps integration body must exist")
	return Chr(0xFEFF) . Source . Body
}

_MAD_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_MAD_Native() {
	static Serial := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "a prior unretired native integration forbids another launch")
	Root := A_Temp . "\ergopti_apps_dom_parent_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	Script := Root . "\subject.ahk"
	SourceOwners := []
	AssertTrue(FSWriteCreateDurable(Script, _MAD_Source(Root . "\store", SourceOwners)))
	AssertEqual(44, SourceOwners.Length, "all generated and authored owner lookups must finish before native launch")
	Hash := CryptoSha256Bytes(FSReadBytesStrict(Script))
	RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
	_TestPrint("# apps-dom-source-built " . KL_JsonEncode(Map("source_sha256", Hash,
		"runtime_sha256", RuntimeHash, "owners", SourceOwners)))
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Root . "\store", Hash, RuntimeHash], _MAD_Complete.Bind(State))
		AssertTrue(Handle.start(), "the exact native integration child must start")
		Pid := Handle.processId()
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 90000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the actual native integration did not settle: " . State.ErrorText . State.Output)
		Receipt := 0
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1 {
				_TestPrint("# apps-dom-native " . Line)
				AssertFalse(IsObject(Receipt), "the native integration must emit one terminal receipt")
				Receipt := JsonParse(SubStr(Line, 9))
			}
		AssertEqual(0, State.Code, "the actual DOM/dialog/store/worker integration failed: " . State.ErrorText . State.Output)
		AssertTrue(Receipt is Map, "a complete native integration receipt is required")
		AssertEqual(Pid, Receipt["host_pid"])
		AssertEqual(Hash, Receipt["source_sha256"])
		AssertEqual(RuntimeHash, Receipt["runtime_sha256"])
		for Key in ["browser_retired", "profile_retired", "jobs_retired"]
			AssertTrue(Receipt[Key], "native ownership cleanup was not acknowledged: " . Key)
		AssertFalse(Receipt["worker_substituted"])
		AssertEqual(3, Receipt["real_workers"])
		AssertEqual(3, Receipt["worker_receipts"].Length)
		for Worker in Receipt["worker_receipts"] {
			AssertTrue(Worker["pid"] != Pid)
			AssertEqual(Hash, Worker["script_sha256"])
			AssertEqual(RuntimeHash, Worker["runtime_sha256"])
			AssertEqual(0, Worker["exit_code"])
			AssertEqual("KLPF_WorkerMain", Worker["worker_main"])
			AssertEqual(Root . "\store", Worker["root"])
			AssertEqual(Root . "\store\config\", Worker["config_dir"])
			AssertEqual("full", Worker["mode"])
		}
		AssertEqual(1, Receipt["real_pickers"])
		AssertEqual(4, Receipt["real_prompts"])
		AssertEqual("semantic-native-bm-click", Receipt["button_transport"])
		AssertEqual(5, Receipt["native_button_receipts"].Length)
		for ButtonReceipt in Receipt["native_button_receipts"] {
			AssertEqual("semantic-native-bm-click", ButtonReceipt["transport"])
			AssertEqual(1, ButtonReceipt["send_ack"], "send acknowledgement alone does not replace the dialog/store/DOM assertions")
		}
		AssertEqual("", State.ErrorText)
	} catch as Failure {
		Primary := Failure
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if !Retired
			RetirementDebt := Handle
		else if !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the actual host and all detached workers must physically retire")
}

Test("Metrics Apps native DOM: pick and edit round-trip through real dialogs, store and projection workers (metrics-apps-dom-native)",
	_MAD_Native)
