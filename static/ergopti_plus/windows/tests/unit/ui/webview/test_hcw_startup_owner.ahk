; tests/unit/ui/webview/test_hcw_startup_owner.ahk

; ==============================================================================
; MODULE: Hotstrings Config Startup Cancellation Tests
; DESCRIPTION:
; The public config editor runs unchanged in an owned child with real GUI/WM_CLOSE.
; Only browser construction and translation/theming are passive; actual data
; builders consume the delivered language index and generated locale table.
; The shipped Promise pumps real Close after GUI publication, before returning.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCWT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_HCWT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

; Generated locale data is excluded from the production resolver. Authenticate
; its complete unique owner from the actual suite includes, not copied labels.
_HCWT_LocaleOwner() {
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

_HCWT_ChildSource() {
	global _DriverDir, _SharedDir
	Includes := "#Include " . _HCWT_LocaleOwner() . "`n", Owners := Map()
	for Symbol in ["JsonStringLiteral", "OpenHotstringsConfigWindow", "_HCWWeb_TryOpen", "HotstringsLanguagePacks",
		"ReadTomlFile", "TOML_StripInlineComment", "CryptoSha256Bytes", "FSReadBytesStrict"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The config child requires its complete genuine owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Includes .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(8, Owners.Count, "The public/data/lifecycle/codec owners must all be present")
	PromiseOwner := _DriverDir . "\vendor\Promise.ahk"
	Fixture := _DriverDir . "\tests\fixtures\hcw_startup_owner_body.ahk"
	AssertTrue(FileExist(PromiseOwner) && FileExist(Fixture))
	return "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "global _HCWS_SourceShared := " . _HCWT_Quote(_SharedDir) . "`n"
		. "#Include " . PromiseOwner . "`n" . Includes . "#Include " . Fixture . "`n"
}

_HCWT_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier config editor child must retire first")
	Directory := A_Temp . "\ergopti_hcw_startup_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _HCWT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _HCWT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public config editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact config editor child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# hcw-startup terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# hcw-startup combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# hcw-startup completion_error " . Line)
			} else
				_TestPrint("# hcw-startup combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact config editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real config editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS hcw-startup " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _HCWT_Mode in ["current", "close-create", "close-create-reject", "reopen-create", "reopen-create-reject"]
	Test("Hotstrings config startup: " . _HCWT_Mode . " retains only its current owner (hcw-startup-owner)",
		_HCWT_Case.Bind(_HCWT_Mode))
