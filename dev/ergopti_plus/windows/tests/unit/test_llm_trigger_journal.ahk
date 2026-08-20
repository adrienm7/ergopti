; tests/unit/test_llm_trigger_journal.ahk

; ==============================================================================
; MODULE: LLM Trigger Durable Journal Regressions
; DESCRIPTION:
; Behavioural proof that a trigger edit remains recoverable after every process
; death boundary, including a writer that mutates before reporting failure.
; Filesystem and config ports are in-memory except for one bounded adapter smoke
; test, so failures can be injected without touching the maintainer's settings.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ In-memory WAL Port =======
; =====================================
; =====================================

global _LTW_Files := Map()
global _LTW_Config := Map()
global _LTW_Results := Map()
global _LTW_Trace := []
global _LTW_ConfigWrites := 0
global _LTW_ConfigMutateRefused := Map()
global _LTW_CriticalStates := []
global _LTW_ConfigPath := "C:\ergopti-tests\config.toml"
global _LTW_JournalPath := "memory://stable-paths.llm-trigger.wal"

_LTW_Reset(Present := 1, Value := "Ctrl+L") {
	global _LTW_Files, _LTW_Config, _LTW_Results, _LTW_Trace
	global _LTW_ConfigWrites, _LTW_ConfigMutateRefused
	global _LTW_CriticalStates
	global _LTW_ConfigPath
	_LTW_Files := Map()
	_LTW_Config := Map(_LTW_ConfigPath,
		Map("present", Present, "value", Value))
	_LTW_Results := Map()
	_LTW_Trace := []
	_LTW_ConfigWrites := 0
	_LTW_ConfigMutateRefused := Map()
	_LTW_CriticalStates := []
	_LLM_TriggerJournalClearReadOnly()
}

_LTW_RecordCritical(Phase) {
	global _LTW_CriticalStates
	_LTW_CriticalStates.Push(Map("phase", Phase, "critical", A_IsCritical))
}

_LTW_Queue(Name, Values*) {
	global _LTW_Results
	if !_LTW_Results.Has(Name)
		_LTW_Results[Name] := []
	for Value in Values
		_LTW_Results[Name].Push(Value)
}

_LTW_Result(Name, Default) {
	global _LTW_Results
	if !_LTW_Results.Has(Name) || _LTW_Results[Name].Length == 0
		return Default
	return _LTW_Results[Name].RemoveAt(1)
}

_LTW_Exists(Path) {
	global _LTW_Files, _LTW_Trace
	_LTW_Trace.Push("exists:" . Path)
	_LTW_RecordCritical("exists")
	return _LTW_Result("exists", _LTW_Files.Has(Path) ? 1 : 0)
}

_LTW_Read(Path, MaxBytes) {
	global _LTW_Files, _LTW_Trace
	_LTW_Trace.Push("read:" . Path)
	_LTW_RecordCritical("read_bounded")
	Default := false
	if _LTW_Files.Has(Path) {
		Content := _LTW_Files[Path]
		if (StrPut(Content, "UTF-8") - 1 <= MaxBytes)
			Default := Content
	}
	return _LTW_Result("read_bounded", Default)
}

_LTW_Write(Path, Content) {
	global _LTW_Files, _LTW_Trace
	_LTW_Trace.Push("write:" . Path)
	_LTW_RecordCritical("write")
	Result := _LTW_Result("write", 1)
	if ((Result is Integer) && Result == 1)
		_LTW_Files[Path] := Content
	return Result
}

_LTW_Move(Source, Destination) {
	global _LTW_Files, _LTW_Trace
	_LTW_Trace.Push("move:" . Source . ">" . Destination)
	_LTW_RecordCritical("move_replace")
	Result := _LTW_Result("move_replace", 1)
	if ((Result is Integer) && Result == 1) && _LTW_Files.Has(Source) {
		_LTW_Files[Destination] := _LTW_Files[Source]
		_LTW_Files.Delete(Source)
	}
	return Result
}

_LTW_Delete(Path) {
	global _LTW_Files, _LTW_Trace
	_LTW_Trace.Push("delete:" . Path)
	_LTW_RecordCritical("delete")
	Result := _LTW_Result("delete", 1)
	if ((Result is Integer) && Result == 1) && _LTW_Files.Has(Path)
		_LTW_Files.Delete(Path)
	return Result
}

_LTW_Port() {
	return Map(
		"exists", _LTW_Exists,
		"read_bounded", _LTW_Read,
		"write", _LTW_Write,
		"move_replace", _LTW_Move,
		"delete", _LTW_Delete)
}

_LTW_ReadTrigger(Path) {
	global _LTW_Config, _LTW_Results
	_LTW_RecordCritical("config_read")
	if _LTW_Results.Has("config_read")
			&& _LTW_Results["config_read"].Length > 0
		return _LTW_Results["config_read"].RemoveAt(1)
	if !_LTW_Config.Has(Path)
		return Map("ok", 1, "present", 0, "value", "")
	State := _LTW_Config[Path]
	return Map("ok", 1, "present", State["present"],
		"value", State["value"])
}

_LTW_ApplyConfig(Path, Updates) {
	global _LTW_Config
	if !_LTW_Config.Has(Path)
		_LTW_Config[Path] := Map("present", 0, "value", "")
	State := _LTW_Config[Path]
	for Update in Updates {
		if (Update.Section != "llm" || Update.Key != "trigger_shortcut")
			continue
		DeleteRequested := Update.HasOwnProp("Delete")
			&& (Update.Delete is Integer) && Update.Delete == 1
		if DeleteRequested {
			State["present"] := 0
			State["value"] := ""
		} else {
			State["present"] := 1
			State["value"] := String(Update.Value)
		}
	}
}

_LTW_ConfigWriter(Path, Updates) {
	global _LTW_ConfigWrites, _LTW_ConfigMutateRefused, _LTW_Trace
	_LTW_ConfigWrites += 1
	_LTW_RecordCritical("config_write")
	_LTW_Trace.Push("config_write:" . Path)
	Result := _LTW_Result("config_write", 1)
	if ((Result is Integer) && Result == 1)
			|| _LTW_ConfigMutateRefused.Has(_LTW_ConfigWrites)
		_LTW_ApplyConfig(Path, Updates)
	return Result
}

_LTW_Notify(Message, Options) {
	return 1
}

_LTW_Record(Phase := "pending", OldPresent := 1,
		OldValue := "Ctrl+L", NewValue := "Ctrl+N", Owner := "") {
	global _LTW_ConfigPath
	if (Owner == "")
		Owner := _LTW_ConfigPath
	return Map(
		"phase", Phase,
		"tx_id", "test-transaction-1",
		"owner", Owner,
		"old_present", OldPresent,
		"old_value", OldValue,
		"new_value", NewValue)
}

_LTW_Publish(Record) {
	global _LTW_JournalPath
	return _LLM_TriggerJournalPublish(Record, _LTW_Port(),
		_LTW_JournalPath)
}

_LTW_JournalExists() {
	global _LTW_Files, _LTW_JournalPath
	return _LTW_Files.Has(_LTW_JournalPath)
}

_LTW_JournalRecord() {
	global _LTW_Files, _LTW_JournalPath
	if !_LTW_Files.Has(_LTW_JournalPath)
		return false
	return _LLM_TriggerJournalParse(_LTW_Files[_LTW_JournalPath])
}

_LTW_Reconcile(ExistingOwner := 0) {
	global _LTW_JournalPath
	return LLM_TriggerJournalReconcile(_LTW_Port(), _LTW_ReadTrigger,
		_LTW_ConfigWriter, _LTW_JournalPath, ExistingOwner)
}

_LTW_Repeat(Character, Count) {
	Result := ""
	Loop Count
		Result .= Character
	return Result
}





; ====================================
; ====================================
; ======= 2/ Codec Regressions =======
; ====================================
; ====================================

_LTW_CodecRoundTripsUnicodeAndAbsence() {
	for Spec in [
		{ present: 0, old: "", new: "" },
		{ present: 1, old: "Ctrl+É", new: "Alt+Ù" },
		{ present: 1, old: "Ctrl+😀", new: "Shift+œ" }
	] {
		Record := _LTW_Record("pending", Spec.present, Spec.old, Spec.new)
		Encoded := _LLM_TriggerJournalSerialize(Record)
		AssertTrue(Encoded is String and Encoded != "")
		Decoded := _LLM_TriggerJournalParse(Encoded)
		AssertTrue(Decoded is Map)
		AssertEqual(Spec.present, Decoded["old_present"])
		AssertEqual(Spec.old, Decoded["old_value"])
		AssertEqual(Spec.new, Decoded["new_value"])
	}
}
Test("[llm-trigger-wal] codec preserves Unicode, empty values and old-key absence",
	_LTW_CodecRoundTripsUnicodeAndAbsence)

_LTW_CodecRejectsNonCanonicalFrames() {
	Valid := _LLM_TriggerJournalSerialize(_LTW_Record())
	AssertFalse(_LLM_TriggerJournalParse(Valid . "`n"),
		"a terminal newline is an extra field, not equivalent framing")
	AssertFalse(_LLM_TriggerJournalParse(StrReplace(Valid,
		"ERGOPTI_LLM_TRIGGER_WAL_V1", "ERGOPTI_LLM_TRIGGER_WAL_V2")))
	AssertFalse(_LLM_TriggerJournalParse(StrReplace(Valid,
		"`npending`n", "`ncommitted`n")))
	AssertFalse(_LLM_TriggerJournalParse(StrReplace(Valid,
		"`npending`n", "`nPENDING`n")),
		"phase spelling is part of the canonical durable protocol")
	AssertFalse(_LLM_TriggerJournalSerialize(
		_LTW_Record("PENDING", 1, "Ctrl+L", "Ctrl+N")))
	AssertFalse(_LLM_TriggerJournalParse(StrReplace(Valid, "`n1`n", "`n2`n")))
	Fields := StrSplit(Valid, "`n")
	Fields[6] := "C0AF"
	MalformedUtf8 := ""
	for Index, Field in Fields
		MalformedUtf8 .= (Index == 1 ? "" : "`n") . Field
	AssertFalse(_LLM_TriggerJournalParse(MalformedUtf8),
		"overlong UTF-8 must not decode through a replacement character")
	AssertFalse(_LLM_TriggerJournalParse(Valid . _LTW_Repeat("A", 4097)))
	AssertFalse(_LLM_TriggerJournalSerialize(_LTW_Record("pending", 1,
		_LTW_Repeat("A", 4097), "Ctrl+N")),
		"oversized records must be rejected before stage-file I/O")
}
Test("[llm-trigger-wal] codec rejects noncanonical and oversized frames",
	_LTW_CodecRejectsNonCanonicalFrames)





; =============================================
; =============================================
; ======= 3/ Atomic Storage Regressions =======
; =============================================
; =============================================

_LTW_PublishNeverReplacesLiveOnMoveRefusal() {
	global _LTW_Files, _LTW_JournalPath
	_LTW_Reset()
	OldRecord := _LTW_Record("committed_old", 1, "Ctrl+K", "Ctrl+L")
	NewRecord := _LTW_Record("pending", 1, "Ctrl+L", "Ctrl+N")
	OldContent := _LLM_TriggerJournalSerialize(OldRecord)
	_LTW_Files[_LTW_JournalPath] := OldContent
	_LTW_Queue("move_replace", 0)
	AssertFalse(_LTW_Publish(NewRecord))
	AssertEqual(OldContent, _LTW_Files[_LTW_JournalPath],
		"a refused replace must leave the previous live frame authoritative")
	AssertTrue(_LTW_Files.Has(_LTW_JournalPath . ".stage"),
		"a failed promotion may leave only non-authoritative stage debris")
	AssertTrue(_LTW_Publish(NewRecord))
	AssertEqual(_LLM_TriggerJournalSerialize(NewRecord),
		_LTW_Files[_LTW_JournalPath])
	AssertFalse(_LTW_Files.Has(_LTW_JournalPath . ".stage"))
}
Test("[llm-trigger-wal] atomic publish preserves live authority on move refusal",
	_LTW_PublishNeverReplacesLiveOnMoveRefusal)

_LTW_PostMoveReadCannotRevokeCommittedPhase() {
	global _LTW_Files, _LTW_JournalPath
	_LTW_Reset()
	Record := _LTW_Record("pending", 1, "Ctrl+L", "Ctrl+N")
	AssertTrue(_LTW_Publish(Record))
	Candidate := Record.Clone()
	Candidate["phase"] := "committed_new"
	CommittedContent := _LLM_TriggerJournalSerialize(Candidate)
	; The first queued read verifies the stage. The second value represents the
	; old post-rename readback seam: after MoveFileEx succeeded it was too late to
	; reclassify publication as failed merely because a new read was refused.
	_LTW_Queue("read_bounded", CommittedContent, false)
	AssertTrue(_LLM_TriggerJournalCommitNew(Record, _LTW_Port(),
		_LTW_JournalPath))
	AssertEqual("committed_new", Record["phase"])
	AssertEqual(CommittedContent, _LTW_Files[_LTW_JournalPath])
}
Test("[llm-trigger-wal] post-move read refusal cannot revoke a committed phase",
	_LTW_PostMoveReadCannotRevokeCommittedPhase)

_LTW_PortStatusesAreStrictIntegers() {
	global _LTW_Files, _LTW_JournalPath
	_LTW_Reset()
	_LTW_Queue("write", "1")
	AssertFalse(_LTW_Publish(_LTW_Record()),
		"the string '1' is not a filesystem success status")

	_LTW_Reset()
	_LTW_Queue("move_replace", "1")
	AssertFalse(_LTW_Publish(_LTW_Record()),
		"the string '1' is not an atomic-move success status")

	_LTW_Reset()
	_LTW_Files[_LTW_JournalPath] := _LLM_TriggerJournalSerialize(_LTW_Record())
	_LTW_Queue("exists", "0")
	ReadResult := _LLM_TriggerJournalRead(_LTW_Port(), _LTW_JournalPath)
	AssertFalse(ReadResult["ok"],
		"the string '0' must not masquerade as file absence")

	_LTW_Reset()
	_LTW_Files[_LTW_JournalPath] := _LLM_TriggerJournalSerialize(_LTW_Record())
	_LTW_Queue("delete", "1")
	AssertFalse(_LLM_TriggerJournalDelete(_LTW_Port(), _LTW_JournalPath),
		"the string '1' is not a delete success status")
	AssertTrue(_LTW_JournalExists())
}
Test("[llm-trigger-wal] port statuses reject truthy strings",
	_LTW_PortStatusesAreStrictIntegers)

_LTW_RealFilesystemAdapterRoundTrip() {
	Path := A_Temp . "\ergopti_llm_trigger_wal_" . A_ScriptHwnd
		. "_" . A_TickCount . ".wal"
	StagePath := Path . ".stage"
	try {
		FSDelete(StagePath)
		FSDelete(Path)
		Record := _LTW_Record("pending", 1, "Ctrl+É", "Alt+Ù",
			A_Temp . "\ergopti-owner.toml")
		AssertTrue(_LLM_TriggerJournalPublish(Record, 0, Path))
		ReadResult := _LLM_TriggerJournalRead(0, Path)
		AssertTrue(ReadResult["ok"] && ReadResult["exists"])
		AssertEqual("Ctrl+É", ReadResult["record"]["old_value"])
		AssertEqual("Alt+Ù", ReadResult["record"]["new_value"])
		AssertTrue(_LLM_TriggerJournalDelete(0, Path))
		AssertFalse(FSExists(Path))
		AssertFalse(FSExists(StagePath))
	} finally {
		FSDelete(StagePath)
		FSDelete(Path)
	}
}
Test("[llm-trigger-wal] real filesystem adapter publishes and deletes one frame",
	_LTW_RealFilesystemAdapterRoundTrip)





; ========================================
; ========================================
; ======= 4/ Reconciliation Matrix =======
; ========================================
; ========================================

_LTW_PendingOldPromotesWithoutConfigWrite() {
	global _LTW_ConfigWrites
	_LTW_Reset(1, "Ctrl+L")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 1, "Ctrl+L", "Ctrl+N")))
	AssertTrue(_LTW_Reconcile())
	AssertEqual(0, _LTW_ConfigWrites)
	AssertFalse(_LTW_JournalExists())
}
Test("[llm-trigger-wal] pending plus old authority promotes without rewriting config",
	_LTW_PendingOldPromotesWithoutConfigWrite)

_LTW_PendingNewRestoresExactOldValue() {
	global _LTW_Config, _LTW_ConfigPath, _LTW_ConfigWrites
	_LTW_Reset(1, "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 1, "Ctrl+L", "Ctrl+N")))
	AssertTrue(_LTW_Reconcile())
	AssertEqual(1, _LTW_ConfigWrites)
	AssertEqual(1, _LTW_Config[_LTW_ConfigPath]["present"])
	AssertEqual("Ctrl+L", _LTW_Config[_LTW_ConfigPath]["value"])
	AssertFalse(_LTW_JournalExists())
}
Test("[llm-trigger-wal] pending plus new authority restores the old value",
	_LTW_PendingNewRestoresExactOldValue)

_LTW_PendingNewRestoresOldAbsence() {
	global _LTW_Config, _LTW_ConfigPath
	_LTW_Reset(1, "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 0, "", "Ctrl+N")))
	AssertTrue(_LTW_Reconcile())
	AssertEqual(0, _LTW_Config[_LTW_ConfigPath]["present"],
		"rollback must delete a key that was physically absent")
	AssertEqual("", _LTW_Config[_LTW_ConfigPath]["value"])
}
Test("[llm-trigger-wal] rollback restores physical key absence",
	_LTW_PendingNewRestoresOldAbsence)

_LTW_PendingNewRestoresLiteralDeleteSentinel() {
	global _LTW_Config, _LTW_ConfigPath
	_LTW_Reset(1, "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 1,
		"_DELETE_", "Ctrl+N")))
	AssertTrue(_LTW_Reconcile())
	AssertEqual(1, _LTW_Config[_LTW_ConfigPath]["present"])
	AssertEqual("_DELETE_", _LTW_Config[_LTW_ConfigPath]["value"],
		"a user value equal to the former sentinel must round-trip literally")
}
Test("[llm-trigger-wal] rollback preserves a literal former delete sentinel "
	. "(llm-trigger-literal-sentinel)",
	_LTW_PendingNewRestoresLiteralDeleteSentinel)

_LTW_PrepareAcceptsLiteralDeleteSentinel() {
	global _LTW_ConfigPath, _LTW_JournalPath
	_LTW_Reset(1, "_DELETE_")
	Owner := _ConfigWriteLeaseTryAcquire(_LTW_ConfigPath,
		"llm-trigger-literal-sentinel-test")
	AssertTrue(Owner is Object)
	try {
		Record := _LLM_TriggerJournalPrepareTransaction(_LTW_ConfigPath,
			"Ctrl+N", Owner, _LTW_Port(), _LTW_ReadTrigger,
			_LTW_ConfigWriter, _LTW_JournalPath)
		AssertTrue(Record is Map,
			"a literal value must not collide with a persistence operation")
		AssertEqual("_DELETE_", Record["old_value"])
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}
}
Test("[llm-trigger-wal] prepare accepts a literal former delete sentinel "
	. "(llm-trigger-literal-sentinel)",
	_LTW_PrepareAcceptsLiteralDeleteSentinel)

_LTW_MutatingRefusalRemainsReplayable() {
	global _LTW_Config, _LTW_ConfigPath, _LTW_ConfigWrites
	global _LTW_ConfigMutateRefused
	_LTW_Reset(1, "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 1, "Ctrl+L", "Ctrl+N")))
	_LTW_ConfigMutateRefused[1] := true
	_LTW_Queue("config_write", 0)
	AssertFalse(_LTW_Reconcile(),
		"a writer refusal remains ambiguous even when it changed durable state")
	AssertEqual("Ctrl+L", _LTW_Config[_LTW_ConfigPath]["value"])
	AssertTrue(_LTW_JournalExists(),
		"pending intent must survive the ambiguous writer result")
	AssertTrue(_LTW_Reconcile())
	AssertEqual(1, _LTW_ConfigWrites,
		"the next process observes old authority and must not rewrite it")
	AssertFalse(_LTW_JournalExists())
}
Test("[llm-trigger-wal] writer mutation followed by refusal is recoverable",
	_LTW_MutatingRefusalRemainsReplayable)

_LTW_TerminalMarkersRequireMatchingAuthority() {
	for Spec in [
		{ phase: "committed_new", durable: "Ctrl+N" },
		{ phase: "committed_old", durable: "Ctrl+L" }
	] {
		_LTW_Reset(1, Spec.durable)
		AssertTrue(_LTW_Publish(_LTW_Record(Spec.phase,
			1, "Ctrl+L", "Ctrl+N")))
		AssertTrue(_LTW_Reconcile())
		AssertFalse(_LTW_JournalExists())
	}
}
Test("[llm-trigger-wal] matching terminal markers clean without configuration writes",
	_LTW_TerminalMarkersRequireMatchingAuthority)

_LTW_ThirdAuthorityFailsClosedForEveryPhase() {
	global _LTW_ConfigWrites
	for Phase in ["pending", "committed_new", "committed_old"] {
		_LTW_Reset(1, "Ctrl+X")
		AssertTrue(_LTW_Publish(_LTW_Record(Phase,
			1, "Ctrl+L", "Ctrl+N")))
		AssertFalse(_LTW_Reconcile(),
			"third-state authority must block phase " . Phase)
		AssertEqual(0, _LTW_ConfigWrites)
		AssertTrue(_LTW_JournalExists())
	}
}
Test("[llm-trigger-wal] third durable authority fails closed in every phase",
	_LTW_ThirdAuthorityFailsClosedForEveryPhase)

_LTW_MalformedAndOversizedFramesStayUntouched() {
	global _LTW_Files, _LTW_JournalPath, _LTW_ConfigWrites
	for Content in ["malformed", _LTW_Repeat("A", 4097)] {
		_LTW_Reset()
		_LTW_Files[_LTW_JournalPath] := Content
		AssertFalse(_LTW_Reconcile())
		AssertEqual(Content, _LTW_Files[_LTW_JournalPath])
		AssertEqual(0, _LTW_ConfigWrites)
	}
}
Test("[llm-trigger-wal] malformed and oversized live frames fail closed",
	_LTW_MalformedAndOversizedFramesStayUntouched)

_LTW_TerminalDeleteRefusalIsReplaySafe() {
	global _LTW_Files, _LTW_JournalPath
	_LTW_Reset(1, "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("committed_new",
		1, "Ctrl+L", "Ctrl+N")))
	_LTW_Queue("delete", 1, 0)
	AssertTrue(_LTW_Reconcile(),
		"terminal cleanup refusal must not undo an already-authoritative commit")
	AssertTrue(_LTW_Files.Has(_LTW_JournalPath))
	AssertTrue(_LTW_Reconcile())
	AssertFalse(_LTW_JournalExists())
}
Test("[llm-trigger-wal] terminal delete refusal is safe to replay",
	_LTW_TerminalDeleteRefusalIsReplaySafe)

_LTW_StageOnlyDebrisHasNoRecoveryAuthority() {
	global _LTW_Files, _LTW_JournalPath, _LTW_ConfigWrites
	_LTW_Reset(1, "Ctrl+L")
	_LTW_Files[_LTW_JournalPath . ".stage"] :=
		_LLM_TriggerJournalSerialize(_LTW_Record())
	AssertTrue(_LTW_Reconcile())
	AssertFalse(_LTW_Files.Has(_LTW_JournalPath . ".stage"))
	AssertEqual(0, _LTW_ConfigWrites)
}
Test("[llm-trigger-wal] stage-only debris is ignored and cleaned",
	_LTW_StageOnlyDebrisHasNoRecoveryAuthority)

_LTW_BorrowedLeaseRemainsOwned() {
	global _LTW_ConfigPath
	_LTW_Reset(1, "Ctrl+L")
	AssertTrue(_LTW_Publish(_LTW_Record()))
	Owner := _ConfigWriteLeaseTryAcquire(_LTW_ConfigPath,
		"llm-trigger-wal-test")
	AssertTrue(Owner is Object)
	try {
		AssertTrue(_LTW_Reconcile(Owner))
		AssertTrue(_ConfigWriteLeaseOwns(Owner, _LTW_ConfigPath),
			"reconciliation must not release a lease borrowed from its caller")
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}
}
Test("[llm-trigger-wal] reconciliation preserves borrowed lease ownership",
	_LTW_BorrowedLeaseRemainsOwned)

_LTW_BorrowedWriterRetainsTransitionLease() {
	global _LTW_ConfigPath, _LTW_Config
	_LTW_Reset(1, "Ctrl+L")
	Owner := _ConfigWriteLeaseTryAcquire(_LTW_ConfigPath,
		"llm-trigger-borrowed-writer-test")
	AssertTrue(Owner is Object)
	try {
		Updates := [{ Section: "llm", Key: "trigger_shortcut",
			Value: "Ctrl+N" }]
		AssertTrue(ConfigCommitBorrowedUpdates(Owner, _LTW_ConfigPath,
			Updates, "the test trigger", _LTW_ConfigWriter, _LTW_Notify))
		AssertTrue(_ConfigWriteLeaseOwns(Owner, _LTW_ConfigPath),
			"the borrowed writer must return ownership to its transition caller")
		AssertEqual("Ctrl+N", _LTW_Config[_LTW_ConfigPath]["value"])
		AssertFalse(ConfigCommitBorrowedUpdates(Owner,
			_LTW_ConfigPath . ".other", Updates, "the wrong-path test",
			_LTW_ConfigWriter, _LTW_Notify))
		AssertTrue(_ConfigWriteLeaseOwns(Owner, _LTW_ConfigPath))
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}
}
Test("[llm-trigger-wal] borrowed writer retains its transition lease",
	_LTW_BorrowedWriterRetainsTransitionLease)

_LTW_RecordOwnerSurvivesLocatorRelocation() {
	global _LTW_Config, _LTW_ConfigPath
	OldOwner := "D:\old-config\config.toml"
	NewTarget := _LTW_ConfigPath
	_LTW_Reset(1, "Ctrl+Z")
	_LTW_Config[OldOwner] := Map("present", 1, "value", "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 1,
		"Ctrl+L", "Ctrl+N", OldOwner)))
	AssertTrue(_LTW_Reconcile())
	AssertEqual("Ctrl+L", _LTW_Config[OldOwner]["value"])
	AssertEqual("Ctrl+Z", _LTW_Config[NewTarget]["value"],
		"a relocated current target must never receive an old WAL rollback")
}
Test("[llm-trigger-wal] journal owner survives paths relocation",
	_LTW_RecordOwnerSurvivesLocatorRelocation)

_LTW_RelocationBundleOwnsRetainedWalPath() {
	global ConfigurationFile, _LTW_ConfigPath, _LTW_JournalPath, _LTW_Files
	HadPath := IsSet(ConfigurationFile)
	SavedPath := HadPath ? ConfigurationFile : ""
	CandidatePath := "C:\ergopti-tests\relocated\config.toml"
	Bundle := false
	_LTW_Reset()
	ConfigurationFile := CandidatePath
	Record := _LTW_Record("committed_old", 1, "Ctrl+L", "Ctrl+N",
		_LTW_ConfigPath)
	_LTW_Files[_LTW_JournalPath] := _LLM_TriggerJournalSerialize(Record)
	; Terminal delete failure is replay-safe and intentionally nonfatal. It also
	; means the old owner must remain part of the Reload/OnExit bundle.
	_LTW_Queue("delete", 0)
	Bundle := LLM_Menu_AcquireLifecycleBundle(0, _LTW_Port(),
		_LTW_JournalPath)
	try {
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle,
			CandidatePath) is Object)
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle,
			_LTW_ConfigPath) is Object,
			"a retained terminal WAL must contribute its old owner to relocation")
		AssertTrue(LLM_Menu_QuiesceTriggerForLifecycle(Bundle,
			_LTW_Port(), _LTW_ReadTrigger, _LTW_ConfigWriter,
			_LTW_JournalPath),
			"OnExit must reconcile the old WAL owner without reacquiring under the global barrier")
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		ConfigurationFile := HadPath ? SavedPath : unset
	}
}
Test("[llm-trigger-wal] relocation bundle carries retained old WAL owner",
	_LTW_RelocationBundleOwnsRetainedWalPath)

_LTW_ConfigSnapshotRejectsTruthyStringStatus() {
	_LTW_Reset()
	AssertTrue(_LTW_Publish(_LTW_Record()))
	_LTW_Queue("config_read",
		Map("ok", 1, "present", "0", "value", "Ctrl+L"))
	AssertFalse(_LTW_Reconcile())
	AssertTrue(_LTW_JournalExists())
}
Test("[llm-trigger-wal] config snapshots reject truthy string presence",
	_LTW_ConfigSnapshotRejectsTruthyStringStatus)





; ============================================
; ============================================
; ======= 5/ Read-only Boot Quarantine =======
; ============================================
; ============================================

_LTW_DefaultPortUsesDurableStageWrites() {
	Port := _LLM_TriggerJournalDefaultPort()
	AssertEqual("FSWriteDurable", Port["write"].Name,
		"the WAL stage must be flushed before write-through publication")
}
Test("[llm-trigger-wal] default port durably stages every frame "
	. "(llm-trigger-wal-durable-stage)",
	_LTW_DefaultPortUsesDurableStageWrites)

_LTW_InheritedCriticalCannotWrapRecoveryAdapters() {
	global _LTW_CriticalStates
	_LTW_Reset(1, "Ctrl+N")
	AssertTrue(_LTW_Publish(_LTW_Record("pending", 1,
		"Ctrl+L", "Ctrl+N")))
	_LTW_CriticalStates := []
	PreviousCritical := Critical("On")
	try {
		AssertTrue(_LTW_Reconcile())
		AssertTrue(A_IsCritical,
			"journal recovery must restore its caller's Critical state")
	} finally Critical(PreviousCritical)
	Seen := Map()
	for Sample in _LTW_CriticalStates {
		Seen[Sample["phase"]] := true
		AssertEqual(0, Sample["critical"],
			Sample["phase"] . " must remain interruptible during WAL recovery")
	}
	for Phase in ["exists", "read_bounded", "config_read", "config_write",
			"write", "move_replace", "delete"]
		AssertTrue(Seen.Has(Phase), "the recovery fixture must exercise " . Phase)
}
Test("[llm-trigger-wal] inherited Critical cannot wrap journal or config adapters "
	. "(llm-trigger-wal-inherited-critical)",
	_LTW_InheritedCriticalCannotWrapRecoveryAdapters)

_LTW_MalformedBootQuarantinesWithoutMutatingBytes() {
	global _LTW_Files, _LTW_JournalPath, _LTW_ConfigWrites, _LTW_Trace
	for Content in ["malformed", _LTW_Repeat("A", 4097)] {
		_LTW_Reset()
		_LTW_Files[_LTW_JournalPath] := Content
		AssertTrue(LLM_TriggerJournalRecoverAtBoot(_LTW_Port(),
			_LTW_ReadTrigger, _LTW_ConfigWriter, _LTW_JournalPath),
			"user-controlled WAL corruption must not trap the driver in a boot loop")
		AssertTrue(LLM_TriggerJournalIsReadOnly())
		AssertTrue(LLM_TriggerJournalReadOnlyKind() != "")
		AssertEqual(Content, _LTW_Files[_LTW_JournalPath],
			"quarantine must preserve the exact forensic artifact")
		AssertEqual(0, _LTW_ConfigWrites)
		for Entry in _LTW_Trace {
			AssertFalse(InStr(Entry, "write:", true) == 1
				|| InStr(Entry, "move:", true) == 1
				|| InStr(Entry, "delete:", true) == 1,
				"boot quarantine must be observational after the bounded read")
		}
	}
}
Test("[llm-trigger-wal] malformed boot is byte-preserving and quit-safe "
	. "(llm-trigger-wal-readonly-boot)",
	_LTW_MalformedBootQuarantinesWithoutMutatingBytes)

_LTW_ReadOnlyBlocksDestructionButAllowsShutdown() {
	global _LTW_Files, _LTW_ConfigPath, _LTW_JournalPath
	_LTW_Reset()
	Content := "malformed"
	_LTW_Files[_LTW_JournalPath] := Content
	AssertTrue(LLM_TriggerJournalRecoverAtBoot(_LTW_Port(),
		_LTW_ReadTrigger, _LTW_ConfigWriter, _LTW_JournalPath))
	Owner := _ConfigWriteLeaseTryAcquire(_LTW_ConfigPath,
		"llm-trigger-readonly-test")
	AssertTrue(Owner is Object)
	try {
		AssertFalse(LLM_TriggerJournalPrepareDestructive(_LTW_ConfigPath,
			Owner, _LTW_Port(), _LTW_ReadTrigger, _LTW_ConfigWriter,
			_LTW_JournalPath),
			"destructive transitions must remain strict while authority is unknown")
		AssertTrue(LLM_TriggerJournalDrainForShutdown(_LTW_Port(),
			_LTW_ReadTrigger, _LTW_ConfigWriter, _LTW_JournalPath, Owner),
			"plain process exit must remain possible without changing config")
		AssertEqual(Content, _LTW_Files[_LTW_JournalPath])
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}
}
Test("[llm-trigger-wal] quarantine blocks destruction but never traps Exit "
	. "(llm-trigger-wal-readonly-shutdown)",
	_LTW_ReadOnlyBlocksDestructionButAllowsShutdown)

_LTW_QuarantineSelfHealsWhenAuthorityDisappears() {
	global _LTW_Files, _LTW_JournalPath
	_LTW_Reset()
	_LTW_Files[_LTW_JournalPath] := "malformed"
	AssertTrue(LLM_TriggerJournalRecoverAtBoot(_LTW_Port(),
		_LTW_ReadTrigger, _LTW_ConfigWriter, _LTW_JournalPath))
	AssertTrue(LLM_TriggerJournalIsReadOnly())
	_LTW_Files.Delete(_LTW_JournalPath)
	AssertTrue(_LTW_Reconcile())
	AssertFalse(LLM_TriggerJournalIsReadOnly(),
		"an absent artifact is unambiguous and must release the edit latch")
	AssertEqual("", LLM_TriggerJournalReadOnlyKind())
}
Test("[llm-trigger-wal] read-only quarantine self-heals after authority is fixed "
	. "(llm-trigger-wal-readonly-self-heal)",
	_LTW_QuarantineSelfHealsWhenAuthorityDisappears)

_LTW_ThirdAuthorityBootPreservesEveryAuthority() {
	global _LTW_Files, _LTW_JournalPath, _LTW_ConfigWrites
	_LTW_Reset(1, "Ctrl+X")
	Record := _LTW_Record("pending", 1, "Ctrl+L", "Ctrl+N")
	Content := _LLM_TriggerJournalSerialize(Record)
	_LTW_Files[_LTW_JournalPath] := Content
	AssertTrue(LLM_TriggerJournalRecoverAtBoot(_LTW_Port(),
		_LTW_ReadTrigger, _LTW_ConfigWriter, _LTW_JournalPath))
	AssertTrue(LLM_TriggerJournalIsReadOnly())
	AssertEqual(Content, _LTW_Files[_LTW_JournalPath])
	AssertEqual(0, _LTW_ConfigWrites,
		"a conflicting third value must never be guessed or overwritten")
	_LLM_TriggerJournalClearReadOnly()
}
Test("[llm-trigger-wal] conflicting boot authority enters non-destructive quarantine "
	. "(llm-trigger-wal-third-authority-boot)",
	_LTW_ThirdAuthorityBootPreservesEveryAuthority)
