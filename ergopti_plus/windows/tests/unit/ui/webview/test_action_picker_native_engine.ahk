; tests/unit/ui/webview/test_action_picker_native_engine.ahk

; ==============================================================================
; MODULE: Action Picker Installed WebView Lifecycle Tests
; DESCRIPTION:
; An owned standalone child loads actual vendors, private assets and profile.
; Real DOM readiness, WM_CLOSE and reopened page confirmation precede cleanup.
; No installed runtime is downloaded and no physical-input claim is made.
; ==============================================================================

#Requires AutoHotkey v2.0

_APNT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_APNT_Source(Root) {
	global _DriverDir, _SharedDir
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "global _APNR_Driver := " . _APNT_Quote(_DriverDir) . "`n"
		. "global _APNR_SourceShared := " . _APNT_Quote(_SharedDir) . "`n"
		. "global _SharedDir := " . _APNT_Quote(Root . "\shared") . "`n"
	for Vendor in ["ComVar.ahk", "Promise.ahk", "WebView2.ahk"]
		Source .= "#Include " . _DriverDir . "\vendor\" . Vendor . "`n"
	Owners := Map()
	for Symbol in ["JsonStringLiteral", "ProgramProviderCatalogue", "_ActPickWeb_TryOpen", "ShowActionPicker",
		"WebView_SharedEnvironment", "CryptoSha256Bytes", "FSReadBytesStrict", "KL_JsonEncode"] {
		OwnerRoot := Symbol == "ProgramProviderCatalogue" ? _SharedDir : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, OwnerRoot)
		AssertTrue(Owner != "", "The native child needs its complete real owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(8, Owners.Count, "The native child must retain every distinct lifecycle/codec/data owner")
	Fixture := _DriverDir . "\tests\fixtures\action_picker_native_engine_body.ahk"
	AssertTrue(FSStrictExists(Fixture), "The installed-engine child must exist")
	return Chr(0xFEFF) . Source . "#Include " . Fixture . "`n"
}

_APNT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_APNT_Case() {
	static Serial := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An earlier unretired native child forbids a new browser")
	Directory := A_Temp . "\ergopti_action_picker_parent_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Directory)
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	Handle := 0, Primary := 0, ExportFailure := 0, AtDeadline := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _APNT_Source(Directory)), "The measured native source must be durably published")
		SourceHash := CryptoSha256Bytes(FSReadBytesStrict(Script))
		RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Directory, SourceHash, RuntimeHash], _APNT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact real-engine child must start")
		NativePid := Handle.processId()
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 90000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if AtDeadline.Calls == 0
			Primary := Error("The exact native picker child did not settle within 90000 ms.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Receipt is Integer && Receipt == 1
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if Retired {
			_TestPrint("# action-picker-native terminal calls=" . State.Calls . " code=" . State.Code
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# action-picker-native combined_native_capture " . Line)
			} else
				_TestPrint("# action-picker-native combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	; A physical AHK-tree ACK alone cannot certify a COM-created browser. Keep
	; all private inputs on every unqualified outcome, including missing receipt.
	try {
		if IsObject(Primary)
			throw Primary
		AssertTrue(Retired, "The assigned child process tree must physically retire before PASS")
		AssertEqual(1, AtDeadline.Calls, "The real browser child must settle once")
		AssertEqual("", AtDeadline.ErrorText, "Completion diagnostics cannot replace native business assertions")
		AssertEqual(0, AtDeadline.Code, "Real browser, public picker or cleanup failed: " . AtDeadline.Output)
		Receipts := []
		for Line in StrSplit(AtDeadline.Output, "`n", "`r")
			if InStr(Line, "RECEIPT action-picker-native ") == 1
				Receipts.Push(JsonParse(SubStr(Line, StrLen("RECEIPT action-picker-native ") + 1)))
		AssertEqual(1, Receipts.Length, "One complete post-cleanup business receipt is required")
		Receipt := Receipts[1]
		AssertEqual(NativePid, Receipt["child_pid"])
		AssertEqual(SourceHash, Receipt["source_sha256"])
		AssertEqual(RuntimeHash, Receipt["runtime_sha256"])
		for Key in ["native_close", "reopened_confirmed", "browser_retired", "profile_retired", "private_folder"]
			AssertTrue(Receipt[Key], "A real lifecycle or cleanup proof is missing: " . Key)
		AssertTrue(Receipt["browser_version"] != "", "The installed engine version must be observed")
		AssertEqual(3, Receipt["browser_handles"], "Keeper and both native page cores must be individually supervised")
		AssertEqual(2, Receipt["windows"])
		AssertEqual(1, Receipt["confirmed"])
		AssertEqual(2, Receipt["frames"].Length)
		AssertEqual(7, Receipt["assets"].Count)
		AssertTrue(Receipt["frames"][2]["epoch"] > Receipt["frames"][1]["epoch"])
		if IsObject(ExportFailure)
			throw ExportFailure
		DirDelete(Directory, true)
	} catch as Failure {
		RetirementDebt := {Handle: Handle, Directory: Directory}
		throw Failure
	}
}

Test("Action picker native WebView: current close and reopen preserve the real page and private browser (action-picker-native-engine)",
	_APNT_Case)
