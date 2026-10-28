; tests/unit/ui/webview/test_model_browser_startup_owner.ahk

; ==============================================================================
; MODULE: Native Model Browser Startup Ownership Tests
; DESCRIPTION:
; Actual public opens survive or retire across real native Close callbacks.
; Complete child receipts are captured before cleanup can affect the result.
; ==============================================================================

#Requires AutoHotkey v2.0

_MBSTO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_MBSTO_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier editor child must retire first")
	Directory := A_Temp . "\ergopti_model_browser_startup_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Owners := Map()
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "passive availability marker") != 0)
		Owner := _DriverProductionFileForSymbol("LLM_ModelBrowser_Show")
		AssertTrue(Owner != "", "The public browser must resolve to its actual whole production owner")
		Fixture := _DriverDir . "\tests\fixtures\model_browser_startup_owner_body.ahk"
		AssertTrue(FileExist(Fixture), "The native child fixture must exist")
		Includes := "", Seen := Map()
		for Symbol in ["LLM_GetModelIndex", "JsonStringLiteral", "FSRead", "WMPresentWindow"] {
			Dependency := _DriverProductionFileForSymbol(Symbol)
			AssertTrue(Dependency != "" && !Seen.Has(Dependency), "Every real presentation/catalogue owner must be unique")
			Seen[Dependency] := true
			Owners[Symbol] := Map("path", Dependency, "sha256", CryptoSha256Bytes(FSReadBytesStrict(Dependency)))
			Includes .= "#Include " . Dependency . "`n"
		}
		Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
			. "#Include " . Owner . "`n" . Includes . "#Include " . Fixture . "`n"
		Owners["public_owner"] := Map("path", Owner, "sha256", CryptoSha256Bytes(FSReadBytesStrict(Owner)))
		Owners["fixture"] := Map("path", Fixture, "sha256", CryptoSha256Bytes(FSReadBytesStrict(Fixture)))
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . Code) != 0)
		SourceHash := CryptoSha256Bytes(FSReadBytesStrict(Script))
		RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
		_TestPrint("# model-browser-startup-owner source-built " . KL_JsonEncode(Map("owner", "model-browser", "mode", Mode,
			"source_sha256", SourceHash, "runtime_sha256", RuntimeHash, "owners", Owners)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, _SharedDir], _MBSTO_Complete.Bind(State))
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
			_TestPrint("# model-browser-startup-owner terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# model-browser-startup-owner combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# model-browser-startup-owner completion_error " . Line)
			} else
				_TestPrint("# model-browser-startup-owner combined_native_capture UNKNOWN")
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
	AssertContains(AtDeadline.Output, "PASS model-show " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}


for _MBSTO_Mode in ["current", "reuse", "close", "reopen", "teardown-reopen", "environment", "factory", "view", "settings",
	"subscription", "mapping", "seed", "navigation", "fill"]
	Test("Model browser startup: " . _MBSTO_Mode . " preserves its native owner (model-browser-startup-owner)",
		_MBSTO_Case.Bind(_MBSTO_Mode))
