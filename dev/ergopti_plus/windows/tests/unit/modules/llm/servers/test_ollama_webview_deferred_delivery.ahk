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
	Diagnostic := _DriverDir . "\tests\fixtures\ollama_child_startup_diagnostics.ahk"
	AssertTrue(FileExist(Diagnostic) != "", "the private startup observer must exist")
	Source .= "#Include " . Diagnostic . "`n"
	Seen := Map()
	for Symbol in ["OllamaWV_FlushQueue", "Ergopti_OnSuspendResume", "_TrayRootErrorIsSilent",
		"ManifestFindEntryByPath", "LLM_DisplayIndentValues", "LLM_Menu_ApplySharedDefaults",
		"LLM_Deps_Cancel", "LLM_Ollama_SetPort", "LLM_Option_TryNormalizeOllamaPort",
		"WebView_SameCore", "LoggerInfo", "WallClockTimestamp", "TickElapsed", "JsonStringLiteral"] {
		OwnerRoot := Symbol == "LLM_DisplayIndentValues" ? _DriverDir . "\..\_shared" : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, OwnerRoot)
		AssertTrue(Owner != "" && FileExist(Owner) != "",
			"the deferred-delivery child requires the whole real owner: " . Symbol)
		if !Seen.Has(Owner) {
			Seen[Owner] := true
			Source .= '_OCSD_Checkpoint("before-owner-' . Seen.Count . '")' . "`n"
			Source .= "#Include " . Owner . "`n"
			Source .= '_OCSD_Checkpoint("after-owner-' . Seen.Count . '")' . "`n"
		}
	}
	Fixture := _DriverDir . "\tests\fixtures\ollama_webview_deferred_delivery_body.ahk"
	AssertTrue(FileExist(Fixture) != "", "the private deferred-delivery fixture must exist")
	return Source . "_OCSD_Stop()`n#Include " . Fixture . "`n"
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
	Nonsettled := false, ParentSuspended := false, ParentCritical := 0
	LaunchSuspended := false, LaunchCritical := 0, StartupTrace := "", TraceFailure := ""
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _ODLP_ChildSource()) == 1)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _ODLP_Complete.Bind(State))
		LaunchSuspended := A_IsSuspended, LaunchCritical := A_IsCritical
		AssertTrue(Handle.start(), "the isolated real resume owners must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		Nonsettled := State.Calls == 0, ParentSuspended := A_IsSuspended, ParentCritical := A_IsCritical
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
			; Preserve the original nonsettlement failure, but let the canonical
			; owner deliver its combined native capture before cleanup deletes it.
			Receipt := IsObject(Handle)
				? (Nonsettled ? Handle.requestTerminate() : Handle.terminate()) : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired {
				try {
					if FSStrictExists(Directory . "\startup.trace")
						StartupTrace := FSReadUtf8Exact(Directory . "\startup.trace")
				} catch as Failure {
					TraceFailure := Type(Failure)
					if !IsObject(Primary)
						Primary := Failure
				}
				DirDelete(Directory, true)
			}
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := Handle
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary) {
		try {
			_TestPrint("# ollama-child-startup-diagnostic nonsettled_at_deadline=" . Nonsettled
				. " retired_ack=" . Retired . " parent_launch_suspended=" . LaunchSuspended
				. " parent_launch_critical=" . LaunchCritical . " parent_deadline_suspended=" . ParentSuspended
				. " parent_deadline_critical=" . ParentCritical . " postcleanup_calls=" . State.Calls
				. " postcleanup_code=" . State.Code . " native_capture_delivered=" . (State.Calls > 0)
				. " trace_read_error=" . TraceFailure . " trace=" . JsonStringLiteral(SubStr(StartupTrace, 1, 8192))
				. " port_combined_output=" . JsonStringLiteral(State.Calls > 0 ? SubStr(State.Output, 1, 8192)
					: "UNKNOWN: no terminal callback was delivered"))
		} finally {
			; A diagnostic printing failure cannot replace the original outcome.
			throw Primary
		}
	}
	AssertTrue(Retired, "private source retirement requires an exact child acknowledgment")
}

for _ODLP_Mode in ["current-flush", "early-resume", "paused-flush", "paused-ready",
	"successor", "settled-before-pause", "observer-error"]
	Test("Ollama deferred scripts: " . _ODLP_Mode . " (ollama-deferred-delivery)", _ODLP_Case.Bind(_ODLP_Mode))
