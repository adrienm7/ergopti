; tests/unit/modules/llm/servers/test_ollama_webview_flush_owner.ahk

; ==============================================================================
; MODULE: Ollama Locale Flush Owner Tests
; DESCRIPTION:
; The actual locale reader emits a missing-file diagnostic during queue flush.
; A controlled diagnostic callback replaces the session; no flush, locale reader
; or close body is substituted. Child timers remain critical through assertions:
; this qualifies queue admission, not browser execution or timer FIFO delivery.
; ==============================================================================

#Requires AutoHotkey v2.0

_OWFP_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_OWFP_ChildSource() {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("OllamaWV_FlushQueue")
	AssertTrue(Owner != "", "the actual complete WebView owner must be available")
	for Symbol in ["OllamaWV_FlushQueue", "OllamaWV_I18nApplyScript", "OllamaWV_Close"]
		AssertTrue(_DriverFuncBody(Symbol) != "" && _DriverProductionFileForSymbol(Symbol) == Owner,
			"the child must execute the genuine shared owner: " . Symbol)
	ScriptOwner := _DriverProductionFileForSymbol("WebView_RunScriptAsync")
	AssertTrue(ScriptOwner != "" && _DriverFuncBody("WebView_RunScriptAsync") != "",
		"the deferred script callback must retain its actual helper owner")
	Fixture := _DriverDir . "\tests\fixtures\ollama_webview_flush_owner_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the isolated flush fixture must exist")
	return '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
		. "#Include " . Owner . "`n"
		. "#Include " . ScriptOwner . "`n"
		. 'global _SharedDir := A_Args[2], _I18nLocale := "missing"' . "`n"
		. 'LoggerInfo(*) => 0' . "`n"
		. 'LoggerError(Tag, Text, *) => _OWFL_Diagnostic(Text)' . "`n"
		. "#Include " . Fixture . "`n"
}

_OWFP_Case(Mode) {
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier flush-owner child remains unretired.")
	Directory := A_Temp . "\ergopti_ollama_flush_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _OWFP_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory . "\shared"], _OWFP_Complete.Bind(State))
		AssertTrue(Handle.start(), "the isolated actual flush must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1
				_TestPrint("# ollama-flush-owner " . Line)
		AssertEqual(1, State.Calls, "the real child must settle once: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native parser/runtime stderr cannot be hidden: " . State.Output)
		AssertEqual(0, State.Code, "the actual flush violated session ownership: " . State.Output)
		AssertContains(State.Output, "PASS ollama-flush-owner " . Mode)
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

for _OWFP_Mode in ["locale-replace", "current-locale", "current-fallback", "stale-epoch", "entry-paused"]
	Test("Ollama locale flush: " . _OWFP_Mode . " retains queue ownership (ollama-locale-flush-owner)",
		_OWFP_Case.Bind(_OWFP_Mode))
