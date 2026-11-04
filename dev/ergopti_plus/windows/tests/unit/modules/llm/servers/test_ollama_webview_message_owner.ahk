; tests/unit/modules/llm/servers/test_ollama_webview_message_owner.ahk

; ==============================================================================
; MODULE: Ollama Web Message Session Tests
; DESCRIPTION:
; Runs the complete production WebView module in an isolated AHK child because
; run_all does not include its global UI state. Payload and native teardown
; boundaries reenter the genuine handler without a browser or terminal launch.
; ==============================================================================

#Requires AutoHotkey v2.0

_OWMO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_OWMO_ChildSource() {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("OllamaWV_OnWebMessage")
	AssertTrue(Owner != "", "the child must include the unique actual message-handler owner")
	Body := _DriverFuncBody("OllamaWV_OnWebMessage")
	AssertTrue(Body != "", "the production handler must exist before its owner is included")
	IdentityOwner := _DriverProductionFileForSymbol("WebView_SameCore")
	AssertTrue(IdentityOwner != "" && _DriverFuncBody("WebView_SameCore") != "",
		"the child must include its actual shared Core-identity owner")
	Fixture := _DriverDir . "\tests\fixtures\ollama_webview_message_owner_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the registered child must retain its actual behavioral fixture")
	return '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
		. "#Include " . Owner . "`n"
		. "#Include " . IdentityOwner . "`n"
		. 'global _SharedDir := A_Args[2], _I18nLocale := "fr"' . "`n"
		. 'LoggerInfo(*) => _OWMB_Log()' . "`n"
		. 'LoggerError(Tag, Text, *) {' . "`n throw Error(Text)`n}`n"
		. "#Include " . Fixture . "`n"
}

_OWMO_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier message-owner child remains unretired.")
	Directory := A_Temp . "\ergopti_ollama_message_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _OWMO_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, _SharedDir], _OWMO_Complete.Bind(State))
		AssertTrue(Handle.start(), "the isolated actual handler must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1
				_TestPrint("# ollama-message-owner " . Line)
		AssertEqual(1, State.Calls, "the real child must settle once: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native parser/runtime stderr cannot be hidden: " . State.Output)
		AssertEqual(0, State.Code, "the actual handler violated session ownership: " . State.Output)
		AssertContains(State.Output, "PASS ollama-message-owner " . Mode)
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

for _OWMO_Mode in ["replace-ready", "replace-retry", "replace-cancel", "current-ready", "current-retry",
	"current-cancel", "wrong-sender", "entry-paused", "pause-on-read", "epoch-on-read", "cancel-callback-swap", "logger-replacement"]
	Test("Ollama message owner: " . _OWMO_Mode . " preserves the admitted session (ollama-message-read-owner)",
		_OWMO_Case.Bind(_OWMO_Mode))

#Include test_ollama_webview_flush_owner.ahk
