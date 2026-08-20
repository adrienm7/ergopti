; tests/meta/test_config_full_save_generation_guard.ahk

; ==============================================================================
; MODULE: Full-save generation structural guard
; DESCRIPTION:
; Pins the production wiring that behaviour injection cannot observe: ownership
; precedes collection, boot records a durable generation before arming a timer,
; and user-facing callers classify all three SaveFullConfig outcomes.
; ==============================================================================

#Requires AutoHotkey v2.0

_CFGFM_OwnerSpansCollectionAndAcknowledgement() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig must exist")
	BoundPos := InStr(Body, "BoundPath := _ConfigFullSaveBoundPath()")
	MatchPos := InStr(Body, "_ConfigFullSavePathMatches(ConfigurationFile)")
	OwnerPos := InStr(Body, "_ConfigWriteLeaseTryAcquire")
	CapturePos := InStr(Body, "TargetGeneration := _ConfigFullSaveCapture()")
	CollectPos := InStr(Body, "_ConfigCollectFullSaveUpdates()")
	WritePos := InStr(Body, "TOML_BatchWrite(BoundPath, Updates,")
	AckPos := InStr(Body, "_ConfigFullSaveAcknowledge(TargetGeneration)")
	ReleasePos := InStr(Body, "_ConfigWriteLeaseRelease(OwnerToken)")
	Assert(BoundPos > 0 and MatchPos > BoundPos and OwnerPos > MatchPos
		and CapturePos > OwnerPos and CollectPos > CapturePos
		and WritePos > CollectPos and AckPos > WritePos and ReleasePos > AckPos,
		"one path-bound config owner must span capture, collection, write and exact acknowledgement")
	Assert(InStr(Body, "WriterFn.Call(BoundPath, Updates)") > 0,
		"both injected and production writers must receive the accepted generation path")
	Assert(InStr(Body, "CONFIG_OBSOLETE_SECTION_PREFIXES", true, WritePos) > 0,
		"the production full writer must retire obsolete driver namespaces")
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
	Assert(InStr(LlmBody, "&RequestedGeneration") > 0
		and InStr(LlmBody, "_ConfigFullSaveResolveFailure(") > 0
		and InStr(LlmBody, "try ReloadAccepted := ReloadPreservingSuspend()") > 0
		and RegExMatch(LlmBody,
			"s)if\s+_ConfigFullSaveResumeRejected\(RequestedGeneration\)\s*\{.*?return\s+true") > 0,
		"LLM failures must resolve the exact generation before Reload and restore it when Reload returns")
}

Test("config full save meta: callers classify all outcomes (config-full-save-generation-meta)",
	_CFGFM_CallersClassifyTypedOutcomes)
