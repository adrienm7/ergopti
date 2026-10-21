; tests/unit/modules/llm/servers/test_ollama_webview_pause_readiness.ahk

; ==============================================================================
; MODULE: Ollama Paused Readiness Component Tests
; DESCRIPTION:
; Runs the real resume/menu/bootstrap owners in a private child. Readiness and
; the source-bound safety callback are controlled deliveries, not browser DOM
; or elapsed two-second observations. Native process and COM work stays passive.
; ==============================================================================

#Requires AutoHotkey v2.0

_OPRP_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_OPRP_ChildSource() {
	global _DriverDir
	Source := '#Requires AutoHotkey v2.0' . "`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
	Seen := Map()
	for Symbol in ["OllamaWV_FlushQueue", "Ergopti_OnSuspendResume", "LLM_Menu_ApplySharedDefaults",
		"LLM_Deps_Cancel", "LLM_Ollama_SetPort", "LLM_Option_TryNormalizeOllamaPort",
		"WebView_SameCore", "LoggerInfo", "WallClockTimestamp", "TickElapsed", "JsonStringLiteral"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the paused-readiness child requires the whole real owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	Create := _DriverFuncBody("OllamaWV_Create")
	AssertTrue(Create != "", "the real safety producer must be present")
	Pattern := 'SetTimer\(\s*([A-Za-z_]\w*\.Bind\(captured_epoch\))\s*,\s*-2000\s*\)'
	At := RegExMatch(Create, Pattern, &Safety)
	AssertTrue(At > 0 && RegExMatch(Create, Pattern, , At + Safety.Len) == 0,
		"Create must publish one source-authenticated epoch-bound safety callback")
	Source .= "_OPR_SafetyCallback(captured_epoch) {`n`treturn " . Safety[1] . "`n}`n"
	Fixture := _DriverDir . "\tests\fixtures\ollama_webview_pause_readiness_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private paused-readiness fixture must exist")
	return Source . "#Include " . Fixture . "`n"
}

_OPRP_Case(Mode) {
	static RetirementDebt := 0
	if IsObject(RetirementDebt)
		throw Error("An earlier paused-readiness child remains unretired.")
	Directory := A_Temp . "\ergopti_ollama_pause_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	Handle := 0, Primary := 0, Retired := false
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _OPRP_ChildSource()) == 1)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _OPRP_Complete.Bind(State))
		AssertTrue(Handle.start(), "the isolated real resume owners must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT ") == 1
				_TestPrint("# ollama-paused-readiness " . Line)
		AssertEqual(1, State.Calls, "the isolated component must settle once: " . State.Output . State.ErrorText)
		AssertEqual("", State.ErrorText, "native prerequisites cannot be hidden: " . State.Output)
		AssertEqual(0, State.Code, "the real resume lifecycle stranded its current queue: " . State.Output)
		AssertContains(State.Output, "PASS ollama-paused-readiness " . Mode)
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

for _OPRP_Mode in ["current-ready", "paused-ready-safety", "bootstrap-tick", "early-resume"]
	Test("Ollama readiness after pause: " . _OPRP_Mode . " (ollama-paused-readiness)", _OPRP_Case.Bind(_OPRP_Mode))
