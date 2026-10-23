; tests/unit/ui/webview/test_hcw_early_show_owner.ahk

; ==============================================================================
; MODULE: Native Hotstrings Config Show Cancellation Tests
; DESCRIPTION:
; Real Gui.Show and its original Close callbacks run in an owned child.
; Browser surfaces are passive only beyond the observed native show boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

_HESO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_HESO_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

; Generated labels are authenticated from the actual suite's complete include owner.
_HESO_LocaleOwner() {
	global _DriverDir
	Runner := FSReadStrict(A_ScriptFullPath)
	Code := _DriverMaskNonCode(&Runner), Owners := Map()
	for Line in StrSplit(Code, "`n", "`r") {
		if !RegExMatch(Line, "i)^\s*#Include\s+(\.\.[\\/]_generated[\\/][A-Za-z0-9_.-]+\.ahk)\s*$", &Include)
			continue
		Target := StrReplace(Include[1], "/", "\")
		Owner := _DriverDir . "\" . SubStr(Target, 4)
		Text := FSReadStrict(Owner)
		OwnerCode := _DriverMaskNonCode(&Text)
		Count := _DriverTopLevelDefinitionCount(&OwnerCode, "LocaleTableData")
		if Count {
			AssertEqual(1, Count, "The actual generated owner must declare LocaleTableData once")
			Owners[Owner] := true
		}
	}
	AssertEqual(1, Owners.Count, "The actual suite must load one canonical generated locale table")
	for Owner in Owners
		return Owner
}


_HESO_ChildSource(Owners, IndexHash) {
	global _DriverDir
	LocaleOwner := _HESO_LocaleOwner()
	Includes := "#Include " . LocaleOwner . "`n", Seen := Map()
	Owners["LocaleTableData"] := Map("path", LocaleOwner, "sha256", CryptoSha256Bytes(FSReadBytesStrict(LocaleOwner)))
	for Symbol in ["JsonStringLiteral", "CryptoSha256Bytes", "TickElapsed", "KL_JsonEncode",
		"OpenHotstringsConfigWindow", "_HCWWeb_TryOpen", "HotstringsLanguagePacks", "ReadTomlFile",
		"TOML_StripInlineComment", "FSReadBytesStrict"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The unique actual child path must resolve: " . Symbol)
		Text := FSReadStrict(Owner)
		AssertTrue(_DriverExtractFunctionBody(&Text, Symbol) != "",
			"The unique actual child owner must be nonempty: " . Symbol)
		Owners[Symbol] := Map("path", Owner, "sha256", CryptoSha256Bytes(FSReadBytesStrict(Owner)))
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Includes .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(10, Seen.Count, "The public/data/lifecycle/clock/codec owners must be genuine whole files")
	Fixture := _DriverDir . "\tests\fixtures\hcw_early_show_owner_body.ahk"
	AssertTrue(FileExist(Fixture))
	Owners["fixture"] := Map("path", Fixture, "sha256", CryptoSha256Bytes(FSReadBytesStrict(Fixture)))
	return "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "global _HESW_SourceIndexHash := " . _HESO_Quote(IndexHash) . "`n"
		. Includes . "#Include " . Fixture . "`n"
}

_HESO_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier editor child must retire first")
	Directory := A_Temp . "\ergopti_hcw_early_show_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Owners := Map()
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		for Relative in ["64bit", "shared", "shared\modules", "shared\modules\hotstrings", "extensions", "personal"]
			FSCreateDirectoryExclusiveStrict(Directory . "\" . Relative)
		SourceIndex := _SharedDir . "\modules\hotstrings\_index.toml"
		IndexHash := CryptoSha256Bytes(FSReadBytesStrict(SourceIndex))
		PrivateIndex := Directory . "\shared\modules\hotstrings\_index.toml"
		AssertTrue(FSWriteCreateDurable(PrivateIndex, FSReadStrict(SourceIndex)) != 0)
		AssertEqual(IndexHash, CryptoSha256Bytes(FSReadBytesStrict(PrivateIndex)), "The private index copy must be exact")
		Owners["language_index"] := Map("path", SourceIndex, "sha256", IndexHash)
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _HESO_ChildSource(Owners, IndexHash)) != 0)
		SourceHash := CryptoSha256Bytes(FSReadBytesStrict(Script))
		RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
		_TestPrint("# hcw-early-show source-built " . KL_JsonEncode(Map("owner", "hcw", "mode", Mode,
			"source_sha256", SourceHash, "runtime_sha256", RuntimeHash, "owners", Owners)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "hcw", Mode, Directory, SourceHash, RuntimeHash], _HESO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact editor child did not settle within 15000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
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
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# hcw-early-show terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# hcw-early-show combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# hcw-early-show completion_error " . Line)
			} else
				_TestPrint("# hcw-early-show combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS hcw-early-show hcw " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _HESO_Mode in ["current", "close", "reopen"]
	Test("Native HCW Show: " . _HESO_Mode . " preserves its owner (hcw-early-show-owner)",
		_HESO_Case.Bind(_HESO_Mode))
