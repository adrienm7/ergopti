; tests/unit/modules/llm/servers/test_ollama_webview_close_owner.ahk

; ==============================================================================
; MODULE: Ollama Native Close Session Tests
; DESCRIPTION:
; Includes the real close and close-if-epoch owners in an isolated child.
; Controlled subscription/controller boundaries install a successor while
; native hidden HWNDs prove exact destruction without browser COM claims.
; ==============================================================================

#Requires AutoHotkey v2.0

_OWCF_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_OWCF_ChildSource() {
	global _DriverDir
	Owners := Map(), Includes := ""
	for Symbol in ["OllamaWV_Close", "OllamaWV_CloseIfEpoch"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "the child must include the unique actual close owner: " . Symbol)
		AssertTrue(_DriverFuncBody(Symbol) != "", "the production close owner must exist: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Includes .= "#Include " . Owner . "`n"
		}
	}
	Fixture := _DriverDir . "\tests\fixtures\ollama_webview_close_owner_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the registered child must retain its actual behavioral fixture")
	return '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
		. Includes
		. 'LoggerInfo(*) => ""' . "`n"
		. 'WebView_RetireProfile(Path) => _OWCO_Profile(Path)' . "`n"
		. 'LoggerError(Tag, Text, *) {' . "`n throw Error(Text)`n}`n"
		. "#Include " . Fixture . "`n"
}

_OWCF_Case(Mode) {
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier close-owner child remains unretired.")
	Directory := A_Temp . "\ergopti_ollama_close_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _OWCF_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _OWCF_Complete.Bind(State))
		AssertTrue(Handle.start(), "the isolated actual close owner must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1
				_TestPrint("# ollama-close-owner " . Line)
		AssertEqual(1, State.Calls, "the real child must settle once: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native parser/runtime stderr cannot be hidden: " . State.Output)
		AssertEqual(0, State.Code, "the actual close owner violated session ownership: " . State.Output)
		AssertContains(State.Output, "PASS ollama-close-owner " . Mode)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := Handle
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the source directory can be retired only after the exact child terminates")
}

for _OWCF_Mode in ["current-close", "current-close-if-epoch", "stale-close-if-epoch", "reenter-controller",
	"reenter-subscription", "reenter-close-if-epoch", "repeat-close"]
	Test("Ollama close owner: " . _OWCF_Mode . " preserves the successor session (ollama-close-session-owner)",
		_OWCF_Case.Bind(_OWCF_Mode))
