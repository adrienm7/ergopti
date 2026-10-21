; tests/unit/modules/llm/servers/test_ollama_webview_deferred_delivery.ahk

; ==============================================================================
; MODULE: Ollama Deferred Script Delivery Tests
; DESCRIPTION:
; Runs the real deferred script timers under native Suspend and the actual
; resume reactor in a private child. Browser submission and installation stay
; passive; neither JavaScript DOM execution nor the full suspend teardown is run.
; ==============================================================================

#Requires AutoHotkey v2.0

_ODLP_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_ODLP_ChildSource() {
	global _DriverDir
	Source := '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
	Seen := Map()
	for Symbol in ["OllamaWV_FlushQueue", "Ergopti_OnSuspendResume", "_TrayRootErrorIsSilent",
		"LLM_Menu_ApplySharedDefaults",
		"LLM_Deps_Cancel", "LLM_Ollama_SetPort", "LLM_Option_TryNormalizeOllamaPort",
		"WebView_SameCore", "LoggerInfo", "WallClockTimestamp", "TickElapsed", "JsonStringLiteral"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the deferred-delivery child requires the whole real owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	Fixture := _DriverDir . "\tests\fixtures\ollama_webview_deferred_delivery_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private deferred-delivery fixture must exist")
	return Source . "#Include " . Fixture . "`n"
}

_ODLP_Case(Mode) {
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier deferred-delivery child remains unretired.")
	Directory := A_Temp . "\ergopti_ollama_delivery_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _ODLP_ChildSource()) == 1)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _ODLP_Complete.Bind(State))
		AssertTrue(Handle.start(), "the isolated real resume owners must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1
				_TestPrint("# ollama-deferred-delivery " . Line)
		AssertEqual(1, State.Calls, "the isolated component must settle once: " . State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText, "native prerequisites cannot be hidden: " . State.Output)
		AssertEqual(0, State.Code, "the real deferred delivery lost its current scripts: " . State.Output)
		AssertContains(State.Output, "PASS ollama-deferred-delivery " . Mode)
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
	AssertTrue(Retired, "private source retirement requires an exact child acknowledgment")
}

for _ODLP_Mode in ["current-flush", "early-resume", "paused-flush", "paused-ready",
	"successor", "settled-before-pause", "observer-error"]
	Test("Ollama deferred scripts: " . _ODLP_Mode . " (ollama-deferred-delivery)", _ODLP_Case.Bind(_ODLP_Mode))
