; tests/meta/test_config_full_save_generation_guard.ahk

; ==============================================================================
; MODULE: Full-save generation structural guard
; DESCRIPTION:
; Pins the production wiring that behaviour injection cannot observe: ownership
; precedes collection, boot records a durable generation before arming a timer,
; and user-facing callers classify all three SaveFullConfig outcomes.
; ==============================================================================

#Requires AutoHotkey v2.0

_CFGFM_CapturedPublisherPosition(Body) {
	Position := RegExMatch(Body, 'm)^[ \t]*Written := _TOML_BatchWriteImpl\(BoundPath, Updates, \[\], "write",[ \t]*\n[ \t]*SourceImage\["source_content"\], SourceImage\["source_present"\], true\)[ \t]*$', &Matched)
	Code := _DriverMaskNonCode(&Body)
	return Position && SubStr(Code, Position + InStr(Matched[0], "Written", true) - 1, 7) == "Written" ? Position : 0
}

_CFGFM_OwnerSpansCollectionAndAcknowledgement() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig must exist")
	BoundPos := InStr(Body, "BoundPath := _ConfigFullSaveBoundPath()")
	MatchPos := InStr(Body, "_ConfigFullSavePathMatches(ConfigurationFile)")
	OwnerPos := InStr(Body, "_ConfigWriteLeaseTryAcquire")
	CapturePos := InStr(Body, "TargetGeneration := _ConfigFullSaveCapture()")
	SourcePos := InStr(Body, "SourceImage := TOML_BuildConfigUpdatedContent(BoundPath, [])")
	ClassifyPos := InStr(Body, 'ObsoleteSource := ConfigFullSnapshotCaptureObsoleteSource(SourceImage["source_content"])')
	CollectPos := InStr(Body, "_ConfigCollectFullSaveUpdates()")
	WritePos := _CFGFM_CapturedPublisherPosition(Body)
	AckPos := InStr(Body, "_ConfigFullSaveAcknowledge(TargetGeneration)")
	ReleasePos := InStr(Body, "_ConfigWriteLeaseRelease(OwnerToken)")
	Assert(BoundPos > 0 and MatchPos > BoundPos and OwnerPos > MatchPos
		and CapturePos > OwnerPos and SourcePos > CapturePos
		and ClassifyPos > SourcePos and CollectPos > ClassifyPos
		and WritePos > CollectPos and AckPos > WritePos and ReleasePos > AckPos,
		"one path-bound config owner must span capture, collection, write and exact acknowledgement")
	Assert(InStr(Body, "WriterFn.Call(BoundPath, Updates)") > 0,
		"both injected and production writers must receive the accepted generation path")
	Assert(InStr(Body, "CONFIG_OBSOLETE_SECTION_PREFIXES", true) = 0,
		"ordinary full saves must not own automatic obsolete-namespace deletion")
	Assert(InStr(Body, "Written is Integer") > 0,
		"durability acknowledgement must reject truthy non-boolean statuses")
}

Test("config full save meta: owner spans collection and acknowledgement (config-full-save-generation-meta)",
	_CFGFM_OwnerSpansCollectionAndAcknowledgement)

_CFGFM_BootRecordsGenerationBeforeWakeup() {
	Entry := FileRead(A_ScriptDir . "\..\ErgoptiPlus.ahk", "UTF-8")
	QueuePos := InStr(Entry,
		"_ConfigQueueFullSave(CONFIG_FULL_SAVE_BOOT_DELAY_MS, 0, false)")
	Assert(QueuePos > 0,
		"boot must record an explicitly terminal-optional generation before relying on a one-shot timer")
	Assert(InStr(Entry, "SetTimer(SaveFullConfig") = 0,
		"boot must not entrust the save obligation to an untracked timer callback")
	_CFGFM_ReceiveRecordedBoot(_CFGFM_OptionalBootSaveBlock(Entry))
}

Test("config full save meta: boot records generation before wake-up (config-full-save-generation-meta)",
	_CFGFM_BootRecordsGenerationBeforeWakeup)

_CFGFM_CallersClassifyTypedOutcomes() {
	for FuncName in ["LLM_Menu_SaveConfig", "CS_Save"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist")
		Assert(RegExMatch(Body, "\b\w+\s*:=\s*SaveFullConfig\s*\("),
			FuncName . " must capture the typed full-save result")
		Assert(InStr(Body, "CONFIG_SAVE_OK") > 0
			and InStr(Body, "CONFIG_SAVE_DEFERRED") > 0,
			FuncName . " must distinguish durable, deferred and failed outcomes")
	}
	LlmBody := _DriverFuncBody("LLM_Menu_SaveConfig")
	ResumeBody := _DriverFuncBody("_LLM_Menu_ResumeAfterRefusedReload")
	Assert(ResumeBody != "", "the refused-reload resume must exist")
	; A launched Reload is refused only later, so the same resume must run both
	; when no successor launched and from the refusal callback after launch.
	Assert(InStr(LlmBody, "&RequestedGeneration") > 0
		and InStr(LlmBody, "_ConfigFullSaveResolveFailure(") > 0
		and InStr(LlmBody, "try ReloadAccepted := ReloadPreservingSuspend(0, 0,") > 0
		and InStr(LlmBody,
			"_LLM_Menu_ResumeAfterRefusedReload.Bind(RequestedGeneration)") > 0
		and InStr(LlmBody,
			"return _LLM_Menu_ResumeAfterRefusedReload(RequestedGeneration)") > 0
		and RegExMatch(ResumeBody,
			"s)if\s+_ConfigFullSaveResumeRejected\(RequestedGeneration\)\s*\{.*?return\s+true") > 0,
		"LLM failures must resolve the exact generation before Reload and restore it whenever Reload is refused")
}

Test("config full save meta: callers classify all outcomes (config-full-save-generation-meta)",
	_CFGFM_CallersClassifyTypedOutcomes)

; The optional old-boot canonicalizer must not report the terminal owner's refusal.
_CFGFM_OptionalBootSaveBlock(Entry) {
	StartText := 'BootProfile_StageEnd("magic key source", _MagicKeySource["origin"])'
	EndText := 'BootProfile_StageBegin("keyboard hook")'
	Start := InStr(Entry, StartText, true)
	if !Start || InStr(Entry, StartText, true, Start + StrLen(StartText))
		return ""
	End := InStr(Entry, EndText, true, Start + StrLen(StartText))
	if !End
		return ""
	Code := _DriverMaskNonCode(&Entry)
	if SubStr(Code, Start, 17) != "BootProfile_Stage"
		return ""
	return Trim(_StripFullLineComments(SubStr(Entry, Start + StrLen(StartText),
		End - Start - StrLen(StartText))), " `t`r`n")
}


; Only the source block's controlled recording ports may execute in the child.
_CFGFM_RecordedBootScript(Block, Framework, Receipt) {
	AssertTrue(Block != "", "the genuine optional boot block must be present")
	Code := _DriverMaskNonCode(&Block)
	Allowed := Map("if", true, "true", true, "false", true,
		"CONFIG_FULL_SAVE_BOOT_DELAY_MS", true, "_ConfigWriteTerminalIsActive", true,
		"ConfigFullStateCanPersist", true, "_ConfigQueueFullSave", true,
		"ConfigReportPersistenceFailure", true)
	Position := 1, Scanned := 0
	while Found := RegExMatch(Code, "[A-Za-z_][A-Za-z0-9_]*", &Token, Position) {
		Scanned += 1
		AssertTrue(Allowed.Has(Token[0]), "the recording child refuses an uncontrolled effect: " Token[0])
		Position := Found + StrLen(Token[0])
	}
	AssertTrue(Scanned > 0, "the actual boot block must contain executable tokens")
	Quote(Value) {
		return Chr(34) StrReplace(StrReplace(Value, Chr(96), Chr(96) Chr(96)),
			Chr(34), Chr(96) Chr(34)) Chr(34)
	}
	Header := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
		. 'EnvSet("ERGOPTI_AHK_RESULTS_FILE", ' Quote(Receipt) ')`n'
		. "#Include " Framework "`n"
	Harness := '
(
global CONFIG_FULL_SAVE_BOOT_DELAY_MS := 100
global _CFGFM_RecordingState := 0
_ConfigWriteTerminalIsActive() {
	global _CFGFM_RecordingState
	_CFGFM_RecordingState["terminal_checks"] += 1
	return _CFGFM_RecordingState["terminal"]
}
ConfigFullStateCanPersist() {
	global _CFGFM_RecordingState
	_CFGFM_RecordingState["admissions"] += 1
	if _CFGFM_RecordingState["mode"] == "during_admission"
		_CFGFM_RecordingState["terminal"] := true
	return _CFGFM_RecordingState["can_persist"]
}
_ConfigQueueFullSave(Delay, Timer, Required) {
	global _CFGFM_RecordingState
	_CFGFM_RecordingState["queue"].Push([Delay, Timer, Required])
	if _CFGFM_RecordingState["mode"] == "during_queue"
		_CFGFM_RecordingState["terminal"] := true
	_CFGFM_RecordingState["queued"] := _CFGFM_RecordingState["queue_ok"] && !_CFGFM_RecordingState["terminal"]
	return _CFGFM_RecordingState["queued"]
}
ConfigReportPersistenceFailure(Context) {
	global _CFGFM_RecordingState
	_CFGFM_RecordingState["reports"].Push(Context)
	return false
}
_CFGFM_RecordingCase(Mode, InitiallyTerminal, CanPersist, QueueOk, Admissions, Queues, Reports, Queued) {
	global _CFGFM_RecordingState, CONFIG_FULL_SAVE_BOOT_DELAY_MS
	_CFGFM_RecordingState := Map("mode", Mode, "terminal", InitiallyTerminal,
		"can_persist", CanPersist, "queue_ok", QueueOk, "terminal_checks", 0,
		"admissions", 0, "queue", [], "reports", [], "queued", false)
	_CFGFM_ActualBootBlock()
	AssertEqual(Admissions, _CFGFM_RecordingState["admissions"])
	AssertEqual(Queues, _CFGFM_RecordingState["queue"].Length)
	AssertEqual(Reports, _CFGFM_RecordingState["reports"].Length)
	AssertEqual(Queued, _CFGFM_RecordingState["queued"], "retirement cannot become a queued success")
	for Args in _CFGFM_RecordingState["queue"] {
		AssertEqual(CONFIG_FULL_SAVE_BOOT_DELAY_MS, Args[1])
		AssertEqual(0, Args[2])
		AssertEqual(false, Args[3], "the boot obligation remains terminal-optional")
	}
	for Context in _CFGFM_RecordingState["reports"]
		AssertEqual("the boot full-configuration save wake-up", Context)
}
BOOT_REGISTRATIONS
_CFGFM_ActualBootBlock() {
	global CONFIG_FULL_SAVE_BOOT_DELAY_MS
BOOT_BLOCK
}
RunTests()
)'
	; Registrations belong to the isolated child, not this running parent registry.
	Registrations := 'Test("recorded boot: initially terminal avoids schema admission", _CFGFM_RecordingCase.Bind("start", true, true, false, 0, 0, 0, false))'
		. "`n" 'Test("recorded boot: terminal during admission refuses queue without error", _CFGFM_RecordingCase.Bind("during_admission", false, true, true, 1, 1, 0, false))'
		. "`n" 'Test("recorded boot: terminal during queue refusal is not a save failure", _CFGFM_RecordingCase.Bind("during_queue", false, true, false, 1, 1, 0, false))'
		. "`n" 'Test("recorded boot: live genuine queue failure is reported", _CFGFM_RecordingCase.Bind("live_failure", false, true, false, 1, 1, 1, false))'
		. "`n" 'Test("recorded boot: nominal queue retains the optional request", _CFGFM_RecordingCase.Bind("normal", false, true, true, 1, 1, 0, true))'
		. "`n" 'Test("recorded boot: existing schema refusal still prevents queue", _CFGFM_RecordingCase.Bind("schema_refusal", false, false, true, 1, 0, 0, false))'
	Harness := StrReplace(Harness, "BOOT_REGISTRATIONS", Registrations)
	return Header StrReplace(Harness, "BOOT_BLOCK", Block)
}

_CFGFM_ReceiveRecordedBoot(Block) {
	static Retained := []
	Directory := A_Temp "\ergopti-optional-boot-" A_ScriptHwnd "-" A_TickCount "-" Random(100000, 999999)
	AssertTrue(DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int"),
		"the recording child needs an exclusively acquired private root")
	Task := 0, Quiesced := true
	State := Map("done", false, "code", -1, "output", "")
	Completed(ExitCode, Output, Errors) {
		State["code"] := ExitCode
		State["output"] := Output
		State["done"] := true
	}
	try {
		Script := Directory "\recorded.ahk", Receipt := Directory "\results.tap"
		Source := _CFGFM_RecordedBootScript(Block, A_ScriptDir "\test_framework.ahk", Receipt)
		AssertTrue(FSWriteCreateDurable(Script, Source), "the exact recording script must be durably created")
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Completed,
			, , 65536)
		Quiesced := false
		AssertTrue(Task.start(), "the exact private recording child must start")
		Started := A_TickCount
		while !State["done"] && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(10)
		AssertTrue(State["done"], "the six recording states must finish within their bounded child budget")
		AssertEqual(0, State["code"], State["output"])
		AssertTrue(FileExist(Receipt) != "", "the actual registered child must retain its receipt")
		Result := FileRead(Receipt, "UTF-8")
		AssertContains(Result, "# 6 passed, 0 failed.", "all six behavior controls must execute")
		for Name in ["initially terminal", "during admission", "during queue refusal",
			"live genuine queue failure", "nominal queue", "existing schema refusal"]
			AssertContains(Result, Name, "the child must reach every distinct refusal/positive path")
	} finally {
		if IsObject(Task) {
			try Quiesced := Task.requestTerminate() == true
			catch
				Quiesced := false
		}
		if Quiesced
			DirDelete(Directory, true)
		else {
			; A refused physical retirement retains both the exact task and its files.
			Retained.Push({ task: Task, directory: Directory, state: State })
			throw Error("The optional boot recording child retains physical retirement debt.")
		}
	}
}
