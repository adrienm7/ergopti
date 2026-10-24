; tests/unit/modules/hotstrings/personal/test_user_hotstring_loader_lifetime.ahk

; ==============================================================================
; MODULE: Programmable Loader Native Lifetime Tests
; DESCRIPTION:
; Public metadata reloads use real staged source, native workers and tree ACKs.
; An acyclic destruction marker is observed after every completion frame returns.
; No rule callback, synthesized input, native input hook or GUI is exercised.
; ==============================================================================

#Requires AutoHotkey v2.0

_UHLT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)),
		Chr(34), Chr(96) . Chr(34)), "`r", Chr(96) . "r"), "`n", Chr(96) . "n") . Chr(34)
}

_UHLT_Generated(Symbol) {
	global _DriverDir
	Found := ""
	loop files _DriverDir . "\_generated\*.ahk" {
		Text := FSReadStrict(A_LoopFileFullPath), Code := _DriverMaskNonCode(&Text)
		Count := _DriverTopLevelDefinitionCount(&Code, Symbol)
		if Count {
			AssertTrue(Count == 1 && Found == "", "A generated collaborator must have one real owner: " . Symbol)
			Found := A_LoopFileFullPath
		}
	}
	AssertTrue(Found != "", "The real generated collaborator must be present: " . Symbol)
	return Found
}

_UHLT_Source(Root) {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "OnError(_UHLC_BootError)`n"
		. "global _UHLC_Root := " . _UHLT_Quote(Root) . "`n"
		. "global _ConfigDir := " . _UHLT_Quote(Root . "\config\") . "`n"
		. "global _SharedDir := " . _UHLT_Quote(Root . "\shared") . "`n"
		. "global _VendorDir := " . _UHLT_Quote(Root . "\vendor") . "`n"
		. "global _LogsDir := " . _UHLT_Quote(Root . "\logs\") . "`n"
		. "global ConfigurationFile := " . _UHLT_Quote(Root . "\config\absent.toml") . "`n"
		. 'global _AhkSubDir := "autohotkey\"' . "`n"
		. "EnvSet(" . _UHLT_Quote("LOCALAPPDATA") . ", " . _UHLT_Quote(Root . "\localappdata") . ")`n"
	CategoryOwner := _DriverProductionFileForSymbol("_CategoryEnabledKey", _DriverDir)
	CategoryText := FSReadStrict(CategoryOwner)
	CategoryFunction := _DriverExtractFunctionBody(&CategoryText, "_CategoryEnabledKey")
	AssertTrue(CategoryFunction != "", "The real category normalizer is required by actual feature defaults.")
	Code := _DriverMaskNonCode(&CategoryFunction)
	AssertEqual(1, _DriverTopLevelDefinitionCount(&Code, "_CategoryEnabledKey"))
	Source .= CategoryFunction . "`n"
	Owners := Map()
	for Symbol in ["JsonStringLiteral", "CryptoSha256Bytes", "FSReadStrict", "WallClockTimestamp", "ManifestBuildFeaturesMap",
		"IsCategoryGated", "LoggerInit", "Redact_Apply", "PLC_CreateProcessWithInheritedHandles", "ShellRunner_SpawnTreeOwned",
		"_HSE_RunOwnedTerminalTransaction", "UserHotstringsReload"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The child must load its genuine source owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	for Symbol in ["AppDirsFolderName", "LoggerSubFilesData"]
		Source .= "#Include " . _UHLT_Generated(Symbol) . "`n"
	return Chr(0xFEFF) . Source . "#Include " . _DriverDir . "\tests\fixtures\user_hotstring_loader_lifetime_body.ahk`n"
}

_UHLT_Assets(Root) {
	global _SharedDir, _VendorDir
	for Subdir in ["config", "logs", "vendor", "shared", "shared\modules", "shared\modules\hotstrings",
		"shared\modules\diagnostics", "localappdata"]
		FSCreateDirectoryExclusiveStrict(Root . "\" . Subdir)
	for Pair in [[_SharedDir . "\modules\hotstrings\user_code.ahk", Root . "\shared\modules\hotstrings\user_code.ahk"],
		[_SharedDir . "\modules\diagnostics\redaction.json", Root . "\shared\modules\diagnostics\redaction.json"],
		[_VendorDir . "\ergopti_user_hotstrings.ahk", Root . "\vendor\ergopti_user_hotstrings.ahk"]] {
		FileCopy(Pair[1], Pair[2], false)
		AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(Pair[1])), CryptoSha256Bytes(FSReadBytesStrict(Pair[2])),
			"Private worker and policy assets must retain their actual bytes.")
	}
}

_UHLT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_UHLT_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "A previous unretired child tree prevents another loader case.")
	Root := A_Temp . "\ergopti_loader_lifetime_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_UHLT_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _UHLT_Source(Root)))
		_TestPrint("# loader-lifetime emitted_sha256=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root], _UHLT_Done.Bind(State))
		AssertTrue(Handle.start(), "The real private loader component must start.")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed64(Started) < 30000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The native loader component did not settle within 30000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Ack := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Ack is Integer && Ack == 1
			if Retired
				DirDelete(Root, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				Debt := {Handle: Handle, Root: Root}
			Critical(PreviousCritical)
		}
	}
	try {
		_TestPrint("# loader-lifetime terminal calls=" . State.Calls . " code=" . State.Code . " tree_ack=" . Retired
			. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
		if State.Calls == 1 {
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# loader-lifetime combined_native_capture " . Line)
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The parent must receive exact child-tree retirement.")
	AssertEqual(1, AtDeadline.Calls, "One actual native completion must precede the deadline: " . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "The native completion diagnostic must remain empty: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real loader component violated lifetime: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS user-hotstring-loader-lifetime " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("programmable loader lifetime: explicit owner retains the completed native load (user-hotstring-loader-lifetime)",
	_UHLT_Case.Bind("retained"))
Test("programmable loader lifetime: completed public reload releases its worker (user-hotstring-loader-lifetime)",
	_UHLT_Case.Bind("released"))
