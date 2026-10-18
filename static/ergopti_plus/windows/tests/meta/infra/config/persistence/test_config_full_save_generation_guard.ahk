; tests/meta/infra/config/persistence/test_config_full_save_generation_guard.ahk

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
	MatchPos := InStr(Body, "_ConfigFullSavePathMatches(SelectedPath)")
	if MatchPos {
		SelectedPos := InStr(Body, "SelectedPath := IsSet(ConfigurationFile) ? ConfigurationFile : 0")
		Assert(SelectedPos > BoundPos && SelectedPos < MatchPos,
			"the path match must consume the detached selected-path snapshot")
	} else
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

_CFGFM_ReceiveRecordedBoot(Block, BuildFn := unset, CaseNames := unset) {
	if IsSet(BuildFn) && !HasMethod(BuildFn, "Call")
		throw TypeError("The source-projected child builder must be callable.")
	if IsSet(CaseNames) && (!(CaseNames is Array) || CaseNames.Length == 0)
		throw TypeError("Source-projected child case names must be nonempty.")
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
		Source := IsSet(BuildFn)
			? BuildFn.Call(Block, A_ScriptDir "\test_framework.ahk", Receipt)
			: _CFGFM_RecordedBootScript(Block, A_ScriptDir "\test_framework.ahk", Receipt)
		AssertTrue(FSWriteCreateDurable(Script, Source), "the exact recording script must be durably created")
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Completed,
			, , 65536)
		Quiesced := false
		AssertTrue(Task.start(), "the exact private recording child must start")
		Started := A_TickCount
		while !State["done"] && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(10)
		AssertTrue(State["done"], "the six recording states must finish within their bounded child budget")
		AssertEqual(0, State["code"], RegExReplace(State["output"], "m)^", "# child "))
		AssertTrue(FileExist(Receipt) != "", "the actual registered child must retain its receipt")
		Result := FileRead(Receipt, "UTF-8")
		Names := IsSet(CaseNames) ? CaseNames
			: ["initially terminal", "during admission", "during queue refusal",
				"live genuine queue failure", "nominal queue", "existing schema refusal"]
		AssertContains(Result, "# " . Names.Length . " passed, 0 failed.",
			"all separately named source-projected controls must execute")
		for Name in Names
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

; Read only the genuine production pending/path-admission block. Its predicates
; remain intact in a source-projected child; only one declared scheduler seam is
; inserted after the original Critical release in both preimage and candidate.
_CFGFM_PendingSnapshotBlock(Terminal := false) {
	Body := _DriverFuncBody(Terminal ? "_ConfigFullSaveSettleTerminal" : "SaveFullConfig")
	StartText := "State := _ConfigFullSaveCoordinator()"
	EndText := Terminal ? "Result := _ConfigDrainFullSave" : "if PublicationDebt {"
	Start := InStr(Body, StartText, true)
	AssertTrue(Start > 0 && !InStr(Body, StartText, true, Start + StrLen(StartText)),
		"one genuine pending-generation admission block must exist")
	End := InStr(Body, EndText, true, Start)
	AssertTrue(End > Start, "the projected block stops before collection or native writes")
	Block := SubStr(Body, Start, End - Start)
	Release := "} finally Critical(PreviousCritical)"
	Position := InStr(Block, Release, true)
	AssertTrue(Position > 0, "the first genuine pending-check Critical release defines the interruption seam")
	Block := StrReplace(Block, Release, Release . "`n`t`t_CFGFM_PendingReleaseGap()", true, , 1)
	if !Terminal {
		FinallyStart := InStr(Body, "} finally {`n`t`t`tif !BorrowedOwner", true, End)
		FinallyEnd := InStr(Body, "`n`t`tif _ConfigFullSaveHasPending()", true, FinallyStart)
		AssertTrue(FinallyStart > End && FinallyEnd > FinallyStart,
			"the actual lease release remains the projected continuation owner")
		Block .= "`n`t`t`treturn CONFIG_SAVE_OK`n`t`t" . SubStr(Body, FinallyStart, FinallyEnd - FinallyStart)
	}
	return Block
}

_CFGFM_PendingSnapshotScript(Block, Framework, Receipt) {
	Quote(Value) {
		return Chr(34) StrReplace(StrReplace(Value, Chr(96), Chr(96) Chr(96)),
			Chr(34), Chr(96) Chr(34)) Chr(34)
	}
	Header := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
		. 'EnvSet("ERGOPTI_AHK_RESULTS_FILE", ' Quote(Receipt) ')`n'
		. "#Include " Framework "`n"
	; These are the actual source bodies, not copied generation models. Their
	; only external ports below describe selected-path/debt and error recording.
	for Name in ["_ConfigFullSaveCoordinatorDataAdmitted", "_ConfigFullSaveCoordinator",
		"_ConfigFullSaveRequest", "_ConfigFullSaveBoundPath", "_ConfigFullSavePathMatches",
		"_ConfigFullSaveReleaseBindingIfSettled", "_ConfigFullSaveAcknowledge",
		"_ConfigFullSaveCapture", "_ConfigFullSaveAbandonThrough", "_ConfigWriteLeaseDataObject", "_ConfigWriteLeaseKey",
		"FileReadActivityKey"]
		Header .= _DriverFuncBody(Name) . "`n"
	Harness := '
(
global CONFIG_SAVE_OK := 1, CONFIG_SAVE_FAILED := 0, CONFIG_SAVE_DEFERRED := 2
global CONFIG_FULL_SAVE_RETRY_DELAY_MS := -100
global ConfigurationFile := "C:\inert-full-save\config.toml"
global _CFGFM_SnapshotRecord := 0
global _DriverReady := true
_ConfigSchemaEntrySelected(Path) {
	return true
}
_ConfigPublicationHasRecoveryDebt(Path) {
	return false
}
_ConfigWriteTerminalIsActive() {
	return false
}
FileReadActivityBusy(Path) {
	return false
}
_ConfigArmFullSaveRetry(Delay, TimerFn) {
	global _CFGFM_SnapshotRecord
	AssertEqual(-100, Delay, "the preserved branch uses its actual retry constant")
	_CFGFM_SnapshotRecord["retry_arms"] += 1
	return true
}
_ConfigWriteLeaseTryAcquire(Path, Kind) {
	global _CFGFM_SnapshotRecord
	_CFGFM_PendingLeaseGap()
	if _CFGFM_SnapshotRecord["mode"] == "lease_refused"
			|| _CFGFM_SnapshotRecord["mode"] == "relocate_at_release_lease_refused"
		return false
	return {key: Path}
}
_ConfigWriteLeaseSelectOwner(Bundle, Path) {
	global _CFGFM_SnapshotRecord
	_CFGFM_PendingLeaseGap()
	if _CFGFM_SnapshotRecord["mode"] == "lease_refused"
			|| _CFGFM_SnapshotRecord["mode"] == "relocate_at_release_lease_refused"
		return false
	return {key: Path}
}
_ConfigWriteLeaseOwns(Token, Path) {
	return true
}
_ConfigWriteLeaseRelease(Token) {
	global _CFGFM_SnapshotRecord
	_CFGFM_SnapshotRecord["lease_releases"] += 1
	return true
}
LoggerError(Args*) {
	global _CFGFM_SnapshotRecord
	_CFGFM_SnapshotRecord["errors"] += 1
	_CFGFM_SnapshotRecord["last_error"] := Args
}
class _CFGFM_ObjectSelectedPath {
	ToString() {
		global _CFGFM_SnapshotRecord
		_CFGFM_SnapshotRecord["conversions"] += 1
		return "C:\inert-full-save\config.toml"
	}
}
_CFGFM_PendingReleaseGap() {
	global _CFGFM_SnapshotRecord, ConfigurationFile
	AssertEqual(0, A_IsCritical, "the declared scheduler seam follows the genuine Critical release")
	_CFGFM_SnapshotRecord["release_visits"] += 1
	; A completed sibling writer would acknowledge here. Invoke the genuine
	; generation owner and its genuine binding clear, without claiming disk I/O.
	if _CFGFM_SnapshotRecord["mode"] == "settle_at_release"
			|| _CFGFM_SnapshotRecord["mode"] == "settle_then_relocate_at_release" {
		AssertTrue(_ConfigFullSaveAcknowledge(_ConfigFullSaveCapture()))
		AssertEqual("", _ConfigFullSaveBoundPath())
		_CFGFM_SnapshotRecord["settlements"] += 1
	}
	if _CFGFM_SnapshotRecord["mode"] == "relocate_at_release"
			|| _CFGFM_SnapshotRecord["mode"] == "settle_then_relocate_at_release"
			|| _CFGFM_SnapshotRecord["mode"] == "relocate_at_release_unready"
			|| _CFGFM_SnapshotRecord["mode"] == "relocate_at_release_lease_refused"
		ConfigurationFile := "C:\other-selected-config\config.toml"
}
_CFGFM_PendingLeaseGap() {
	global _CFGFM_SnapshotRecord, ConfigurationFile
	_CFGFM_SnapshotRecord["lease_acquires"] += 1
	if _CFGFM_SnapshotRecord["mode"] == "relocate_at_acquire"
		ConfigurationFile := "C:\other-selected-config\config.toml"
}
_CFGFM_ActualPendingSnapshot() {
	global ConfigurationFile, CONFIG_SAVE_OK, CONFIG_SAVE_FAILED, _DriverReady
	global CONFIG_SAVE_DEFERRED, CONFIG_FULL_SAVE_RETRY_DELAY_MS
	ExistingOwner := 0, PublicationDebt := false, TimerFn := 0
PENDING_BLOCK
	return CONFIG_SAVE_OK
}
_CFGFM_ActualTerminalSnapshot() {
	global ConfigurationFile, CONFIG_SAVE_OK, CONFIG_SAVE_FAILED
	OwnerBundle := 0
TERMINAL_BLOCK
	return true
}
_CFGFM_PendingSnapshotCase(Mode, Expected, Errors, ReleaseVisits, Settlements, Terminal := false) {
	global ConfigurationFile, _CFGFM_SnapshotRecord, CONFIG_SAVE_OK, _DriverReady
	State := {requested_generation: 0, committed_generation: 0, settled_generation: 0,
		terminal_required_generation: 0, bound_path: "", bound_path_key: "",
		reload_required: false, timer_armed: false, reported_failure_generation: 0}
	_ConfigFullSaveCoordinator(State)
	ConfigurationFile := "C:\inert-full-save\config.toml"
	_DriverReady := Mode != "unready_same_path" && Mode != "relocate_at_release_unready"
	Generation := _ConfigFullSaveRequest(Terminal && Mode != "optional_unset")
	AssertEqual(1, Generation, "the actual request owner records the controlled obligation")
	if Mode == "relocated"
		ConfigurationFile := "C:\other-selected-config\config.toml"
	if Mode == "settled_before"
		AssertTrue(_ConfigFullSaveAcknowledge(Generation))
	if Mode == "optional_unset"
		ConfigurationFile := unset
	if Mode == "invalid_selected"
		ConfigurationFile := _CFGFM_ObjectSelectedPath()
	_CFGFM_SnapshotRecord := Map("mode", Mode, "errors", 0,
		"release_visits", 0, "settlements", 0, "conversions", 0, "last_error", [],
		"lease_acquires", 0, "lease_releases", 0, "retry_arms", 0)
	if Mode == "invalid_selected" {
		AssertEqual("C:\inert-full-save\config.toml", String(ConfigurationFile),
			"the independent object conversion witness must actually be callable")
		AssertEqual(1, _CFGFM_SnapshotRecord["conversions"])
		_CFGFM_SnapshotRecord["conversions"] := 0
	}
	Before := A_IsCritical
	Result := Terminal ? _CFGFM_ActualTerminalSnapshot() : _CFGFM_ActualPendingSnapshot()
	AssertEqual(Before, A_IsCritical, "every return restores the actual previous Critical state")
	if Mode == "settle_at_release" && Result != Expected {
		AssertEqual(1, _CFGFM_SnapshotRecord["errors"], "the original failure is its real path-refusal branch")
		AssertEqual(Generation, State.committed_generation, "the interrupted request was genuinely acknowledged")
		if !Terminal
			AssertEqual("", _CFGFM_SnapshotRecord["last_error"][3], "the original ordinary refusal observes the cleared binding")
		else
			AssertContains(_CFGFM_SnapshotRecord["last_error"][2], "active configuration path no longer matches",
				"the original terminal refusal rereads the cleared live matching key")
	}
	AssertEqual(Expected, Result, "settling the observed generation cannot become a false relocation refusal")
	AssertEqual(Errors, _CFGFM_SnapshotRecord["errors"])
	AssertEqual(ReleaseVisits, _CFGFM_SnapshotRecord["release_visits"])
	AssertEqual(Settlements, _CFGFM_SnapshotRecord["settlements"])
	AssertEqual(0, _CFGFM_SnapshotRecord["conversions"], "the native-data snapshot never invokes an invalid selected-path conversion")
	AssertEqual(Generation, State.requested_generation, "inspection never creates a fresh generation")
	Committed := Mode == "settle_at_release" || Mode == "settled_before"
		|| Mode == "settle_then_relocate_at_release" ? Generation : 0
	AssertEqual(Committed, State.committed_generation)
	AssertEqual(Mode == "optional_unset" ? Generation : Committed, State.settled_generation)
	if Mode == "relocated"
		AssertEqual("C:\inert-full-save\config.toml", State.bound_path,
			"a genuine old-path pending obligation remains retained")
	if Mode == "relocate_at_acquire" || Mode == "relocate_at_release"
			|| Mode == "settle_then_relocate_at_release" {
		AssertEqual("C:\other-selected-config\config.toml", ConfigurationFile,
			"the declared interruption actually changes the selected path")
		if Mode == "relocate_at_acquire"
			AssertEqual(1, _CFGFM_SnapshotRecord["lease_acquires"],
				"post-acquisition admission must execute, not a synthetic early refusal")
		AssertEqual(Terminal ? 0 : _CFGFM_SnapshotRecord["lease_acquires"], _CFGFM_SnapshotRecord["lease_releases"],
			"ordinary acquired tokens retire through the actual finally on refusal")
	}
	if Mode == "unready_same_path" || (Mode == "lease_refused" && !Terminal)
		AssertEqual(1, _CFGFM_SnapshotRecord["retry_arms"],
			"same-path deferral must actually exercise the original retry branch")
	if Mode == "lease_refused"
		AssertEqual(1, _CFGFM_SnapshotRecord["lease_acquires"],
			"the refusal-configured lease port must be reached in its same-path control")
	if Mode == "relocate_at_release_unready" || Mode == "relocate_at_release_lease_refused" {
		AssertEqual("C:\other-selected-config\config.toml", ConfigurationFile)
		AssertEqual(0, _CFGFM_SnapshotRecord["retry_arms"],
			"a known relocation remains a failure instead of scheduling a retry")
		AssertEqual(0, _CFGFM_SnapshotRecord["lease_acquires"],
			"a known relocation is refused before any lease retry or refusal")
		AssertEqual("C:\inert-full-save\config.toml", State.bound_path)
	}
}
SNAPSHOT_REGISTRATIONS
RunTests()
)'
	; Registrations belong to the isolated child, not the running parent registry.
	Registrations := 'Test("pending snapshot: nominal same-path admission", _CFGFM_PendingSnapshotCase.Bind("normal", 1, 0, 1, 0))'
		. "`n" 'Test("pending snapshot: settlement at original release preserves captured binding", _CFGFM_PendingSnapshotCase.Bind("settle_at_release", 1, 0, 1, 1))'
		. "`n" 'Test("pending snapshot: genuine relocation remains refused", _CFGFM_PendingSnapshotCase.Bind("relocated", 0, 1, 1, 0))'
		. "`n" 'Test("pending snapshot: already acknowledged generation succeeds", _CFGFM_PendingSnapshotCase.Bind("settled_before", 1, 0, 0, 0))'
		. "`n" 'Test("terminal snapshot: nominal same-path admission", _CFGFM_PendingSnapshotCase.Bind("normal", 1, 0, 1, 0, true))'
		. "`n" 'Test("terminal snapshot: settlement at original release preserves captured binding", _CFGFM_PendingSnapshotCase.Bind("settle_at_release", 1, 0, 1, 1, true))'
		. "`n" 'Test("terminal snapshot: genuine relocation remains refused", _CFGFM_PendingSnapshotCase.Bind("relocated", 0, 1, 1, 0, true))'
		. "`n" 'Test("terminal snapshot: already acknowledged generation succeeds", _CFGFM_PendingSnapshotCase.Bind("settled_before", 1, 0, 1, 0, true))'
		. "`n" 'Test("terminal snapshot: optional abandonment never reads unset selected path", _CFGFM_PendingSnapshotCase.Bind("optional_unset", 1, 0, 1, 0, true))'
		. "`n" 'Test("pending snapshot: object selected path refuses before conversion", _CFGFM_PendingSnapshotCase.Bind("invalid_selected", 0, 1, 1, 0))'
		. "`n" 'Test("terminal snapshot: object selected path refuses before conversion", _CFGFM_PendingSnapshotCase.Bind("invalid_selected", 0, 1, 1, 0, true))'
		. "`n" 'Test("pending snapshot: relocation at release remains refused", _CFGFM_PendingSnapshotCase.Bind("relocate_at_release", 0, 1, 1, 0))'
		. "`n" 'Test("terminal snapshot: relocation at release remains refused", _CFGFM_PendingSnapshotCase.Bind("relocate_at_release", 0, 1, 1, 0, true))'
		. "`n" 'Test("pending snapshot: settlement then relocation remains refused", _CFGFM_PendingSnapshotCase.Bind("settle_then_relocate_at_release", 0, 1, 1, 1))'
		. "`n" 'Test("terminal snapshot: settlement then relocation remains refused", _CFGFM_PendingSnapshotCase.Bind("settle_then_relocate_at_release", 0, 1, 1, 1, true))'
		. "`n" 'Test("pending snapshot: relocation during acquisition remains refused", _CFGFM_PendingSnapshotCase.Bind("relocate_at_acquire", 0, 1, 1, 0))'
		. "`n" 'Test("terminal snapshot: relocation during acquisition remains refused", _CFGFM_PendingSnapshotCase.Bind("relocate_at_acquire", 0, 1, 1, 0, true))'
		. "`n" 'Test("pending snapshot: same-path unready genuinely defers", _CFGFM_PendingSnapshotCase.Bind("unready_same_path", 2, 0, 1, 0))'
		. "`n" 'Test("pending snapshot: relocated unready fails before retry", _CFGFM_PendingSnapshotCase.Bind("relocate_at_release_unready", 0, 1, 1, 0))'
		. "`n" 'Test("pending snapshot: same-path refused lease genuinely defers", _CFGFM_PendingSnapshotCase.Bind("lease_refused", 2, 0, 1, 0))'
		. "`n" 'Test("pending snapshot: relocation fails before refused lease", _CFGFM_PendingSnapshotCase.Bind("relocate_at_release_lease_refused", 0, 1, 1, 0))'
		. "`n" 'Test("terminal snapshot: same-path refused owner fails", _CFGFM_PendingSnapshotCase.Bind("lease_refused", 0, 1, 1, 0, true))'
		. "`n" 'Test("terminal snapshot: relocation fails before refused owner", _CFGFM_PendingSnapshotCase.Bind("relocate_at_release_lease_refused", 0, 1, 1, 0, true))'
	Harness := StrReplace(Harness, "SNAPSHOT_REGISTRATIONS", Registrations)
	Harness := StrReplace(Harness, "PENDING_BLOCK", Block)
	return Header . StrReplace(Harness, "TERMINAL_BLOCK", _CFGFM_PendingSnapshotBlock(true))
}

_CFGFM_PendingSnapshotReceivesReleaseInterruption() {
	_CFGFM_ReceiveRecordedBoot(_CFGFM_PendingSnapshotBlock(), _CFGFM_PendingSnapshotScript,
		["pending snapshot: nominal same-path admission", "pending snapshot: settlement at original release",
			"pending snapshot: genuine relocation remains refused", "pending snapshot: already acknowledged generation",
			"terminal snapshot: nominal same-path admission", "terminal snapshot: settlement at original release",
			"terminal snapshot: genuine relocation remains refused", "terminal snapshot: already acknowledged generation",
			"terminal snapshot: optional abandonment", "pending snapshot: object selected path",
			"terminal snapshot: object selected path", "pending snapshot: relocation at release",
			"terminal snapshot: relocation at release", "pending snapshot: settlement then relocation",
			"terminal snapshot: settlement then relocation", "pending snapshot: relocation during acquisition",
			"terminal snapshot: relocation during acquisition", "pending snapshot: same-path unready",
			"pending snapshot: relocated unready", "pending snapshot: same-path refused lease",
			"pending snapshot: relocation fails before refused lease", "terminal snapshot: same-path refused owner",
			"terminal snapshot: relocation fails before refused owner"])
}

Test("config full save meta: pending/path snapshot survives same-gap settlement "
	. "(config-full-save-snapshot-interruption)", _CFGFM_PendingSnapshotReceivesReleaseInterruption)
