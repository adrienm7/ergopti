; ui/menu/menu_llm/trigger_journal.ahk

; ==============================================================================
; MODULE: LLM Trigger Shortcut Durable Journal
; DESCRIPTION:
; Owns the crash-safe write-ahead record for the user-editable LLM trigger.
; The journal lives beside the stable paths.toml locator, names the physical
; config.toml it protects, and restores the exact previous key representation
; before a replacement process replays native hotkeys.
;
; FEATURES & RATIONALE:
; 1. Strict UTF-8 hex framing keeps empty and Unicode shortcuts unambiguous.
; 2. Same-directory write-through publication makes pending intent durable first.
; 3. Exact old-key presence restores absence instead of inventing a default key.
; 4. Injectable filesystem and config ports expose every crash boundary to tests.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Journal Format and Port =======
; ==========================================
; ==========================================

global LLM_TRIGGER_JOURNAL_HEADER := "ERGOPTI_LLM_TRIGGER_WAL_V1"
global LLM_TRIGGER_JOURNAL_PHASE_PENDING := "pending"
global LLM_TRIGGER_JOURNAL_PHASE_NEW := "committed_new"
global LLM_TRIGGER_JOURNAL_PHASE_OLD := "committed_old"
global LLM_TRIGGER_JOURNAL_MAX_BYTES := 4096
global LLM_TRIGGER_JOURNAL_SUFFIX := ".llm-trigger.wal"
global LLM_TRIGGER_JOURNAL_STAGE_SUFFIX := ".stage"
global _LLM_TriggerJournalReadOnly := false
global _LLM_TriggerJournalReadOnlyKind := ""

_LLM_TriggerJournalDefaultPort() {
	return Map(
		"exists", FSExists,
		"read_bounded", FSReadBounded,
		"write", FSWriteDurable,
		"move_replace", FSAtomicMoveReplace,
		"delete", FSDelete)
}

_LLM_TriggerJournalEnterReadOnly(Kind) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalEnterReadOnly(Kind)
		finally Critical(InheritedCritical)
	}
	global _LLM_TriggerJournalReadOnly, _LLM_TriggerJournalReadOnlyKind
	if !(Kind is String) || Kind == ""
		Kind := "recovery_refused"
	Changed := false
	PreviousCritical := Critical("On")
	try {
		Changed := !_LLM_TriggerJournalReadOnly
		_LLM_TriggerJournalReadOnly := true
		_LLM_TriggerJournalReadOnlyKind := Kind
	} finally Critical(PreviousCritical)
	if Changed
		try LoggerError("LLM", "Trigger journal entered read-only quarantine ({1}); the preserved artifact must recover or be removed before shortcut edits or destructive configuration transitions can continue.", Kind)
	return true
}

_LLM_TriggerJournalClearReadOnly() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalClearReadOnly()
		finally Critical(InheritedCritical)
	}
	global _LLM_TriggerJournalReadOnly, _LLM_TriggerJournalReadOnlyKind
	WasReadOnly := false
	PreviousCritical := Critical("On")
	try {
		WasReadOnly := _LLM_TriggerJournalReadOnly
		_LLM_TriggerJournalReadOnly := false
		_LLM_TriggerJournalReadOnlyKind := ""
	} finally Critical(PreviousCritical)
	if WasReadOnly
		try LoggerInfo("LLM", "Trigger journal left read-only quarantine after durable authority became recoverable.")
	return true
}

LLM_TriggerJournalIsReadOnly() {
	global _LLM_TriggerJournalReadOnly
	PreviousCritical := Critical("On")
	try return _LLM_TriggerJournalReadOnly
	finally Critical(PreviousCritical)
}

LLM_TriggerJournalReadOnlyKind() {
	global _LLM_TriggerJournalReadOnlyKind
	PreviousCritical := Critical("On")
	try return _LLM_TriggerJournalReadOnlyKind
	finally Critical(PreviousCritical)
}

_LLM_TriggerJournalResolvePort(Port := 0) {
	if (Port is Integer) && Port == 0
		Port := _LLM_TriggerJournalDefaultPort()
	if !(Port is Map)
		return false
	for Name in ["exists", "read_bounded", "write", "move_replace", "delete"] {
		if !Port.Has(Name) || !HasMethod(Port[Name], "Call")
			return false
	}
	return Port
}

_LLM_TriggerJournalPath(ExplicitPath := "") {
	if (ExplicitPath is String) && ExplicitPath != ""
		return ExplicitPath
	global _PathsFile, LLM_TRIGGER_JOURNAL_SUFFIX
	if !IsSet(_PathsFile) || !(_PathsFile is String) || _PathsFile == ""
		return ""
	return _PathsFile . LLM_TRIGGER_JOURNAL_SUFFIX
}

_LLM_TriggerJournalPortExists(Port, Path, &Exists) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalPortExists(Port, Path, &Exists)
		finally Critical(InheritedCritical)
	}
	try Result := Port["exists"].Call(Path)
	catch as Err {
		try LoggerError("LLM", "Trigger journal existence probe failed: {1}.", Err.Message)
		return false
	}
	if !(Result is Integer) || (Result != 0 && Result != 1) {
		try LoggerError("LLM", "Trigger journal existence probe returned a malformed status.")
		return false
	}
	Exists := Result
	return true
}

_LLM_TriggerJournalPortRead(Port, Path, &Content) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalPortRead(Port, Path, &Content)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_MAX_BYTES
	try Result := Port["read_bounded"].Call(Path, LLM_TRIGGER_JOURNAL_MAX_BYTES)
	catch as Err {
		try LoggerError("LLM", "Trigger journal bounded read failed: {1}.", Err.Message)
		return false
	}
	if !(Result is String) {
		try LoggerError("LLM", "Trigger journal bounded read was refused.")
		return false
	}
	Content := Result
	return true
}

_LLM_TriggerJournalPortStatus(Port, Method, Args*) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalPortStatus(Port, Method, Args*)
		finally Critical(InheritedCritical)
	}
	try Result := Port[Method].Call(Args*)
	catch as Err {
		try LoggerError("LLM", "Trigger journal filesystem operation '{1}' failed: {2}.",
			Method, Err.Message)
		return false
	}
	if !(Result is Integer) || Result != 1 {
		try LoggerError("LLM", "Trigger journal filesystem operation '{1}' returned a malformed or refused status.",
			Method)
		return false
	}
	return true
}





; =====================================
; =====================================
; ======= 2/ Strict UTF-8 Codec =======
; =====================================
; =====================================

_LLM_TriggerJournalEncodeHex(Text) {
	if !(Text is String)
		return false
	ByteCapacity := StrPut(Text, "UTF-8")
	Bytes := Buffer(ByteCapacity, 0)
	Written := StrPut(Text, Bytes, "UTF-8")
	Hex := ""
	Loop Written - 1
		Hex .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Hex
}

_LLM_TriggerJournalDecodeHex(Hex) {
	if !(Hex is String) || Mod(StrLen(Hex), 2) != 0
		return Map("ok", 0, "value", "")
	if (Hex != "" && !RegExMatch(Hex, "^[0-9A-F]+$"))
		return Map("ok", 0, "value", "")
	ByteCount := StrLen(Hex) // 2
	if (ByteCount == 0)
		return Map("ok", 1, "value", "")
	Bytes := Buffer(ByteCount + 1, 0)
	Loop ByteCount
		NumPut("UChar", Integer("0x" . SubStr(Hex, (A_Index - 1) * 2 + 1, 2)),
			Bytes, A_Index - 1)
	try Value := StrGet(Bytes.Ptr, ByteCount, "UTF-8")
	catch
		return Map("ok", 0, "value", "")
	RoundTrip := _LLM_TriggerJournalEncodeHex(Value)
	if !(RoundTrip is String) || StrCompare(RoundTrip, Hex, true) != 0
		return Map("ok", 0, "value", "")
	return Map("ok", 1, "value", Value)
}

_LLM_TriggerJournalNewId() {
	static Sequence := 0
	Sequence += 1
	return A_ScriptHwnd . "-" . A_TickCount . "-" . Sequence
}

_LLM_TriggerJournalNewRecord(ConfigPath, OldSnapshot, NewValue) {
	global LLM_TRIGGER_JOURNAL_PHASE_PENDING
	if !(OldSnapshot is Map) || !_LLM_TriggerJournalSnapshotIsValid(OldSnapshot)
		return false
	if !(ConfigPath is String) || ConfigPath == "" || !(NewValue is String)
		return false
	return Map(
		"phase", LLM_TRIGGER_JOURNAL_PHASE_PENDING,
		"tx_id", _LLM_TriggerJournalNewId(),
		"owner", ConfigPath,
		"old_present", OldSnapshot["present"],
		"old_value", OldSnapshot["value"],
		"new_value", NewValue)
}

_LLM_TriggerJournalSerialize(Record) {
	global LLM_TRIGGER_JOURNAL_HEADER, LLM_TRIGGER_JOURNAL_PHASE_PENDING
	global LLM_TRIGGER_JOURNAL_PHASE_NEW, LLM_TRIGGER_JOURNAL_PHASE_OLD
	global LLM_TRIGGER_JOURNAL_MAX_BYTES
	if !(Record is Map)
		return false
	for Key in ["phase", "tx_id", "owner", "old_present", "old_value", "new_value"] {
		if !Record.Has(Key)
			return false
	}
	Phase := Record["phase"]
	if !(Phase is String)
			|| (StrCompare(Phase, LLM_TRIGGER_JOURNAL_PHASE_PENDING, true) != 0
			&& StrCompare(Phase, LLM_TRIGGER_JOURNAL_PHASE_NEW, true) != 0
			&& StrCompare(Phase, LLM_TRIGGER_JOURNAL_PHASE_OLD, true) != 0)
		return false
	TxId := Record["tx_id"]
	if !(TxId is String) || !RegExMatch(TxId, "^[A-Za-z0-9._-]{1,80}$")
		return false
	if !(Record["owner"] is String) || Record["owner"] == ""
		return false
	Present := Record["old_present"]
	if !(Present is Integer) || (Present != 0 && Present != 1)
		return false
	OwnerHex := _LLM_TriggerJournalEncodeHex(Record["owner"])
	OldHex := _LLM_TriggerJournalEncodeHex(Record["old_value"])
	NewHex := _LLM_TriggerJournalEncodeHex(Record["new_value"])
	if !(OwnerHex is String) || !(OldHex is String) || !(NewHex is String)
		return false
	Content := LLM_TRIGGER_JOURNAL_HEADER . "`n" . Phase . "`n" . TxId . "`n"
		. OwnerHex . "`n" . Present . "`n" . OldHex . "`n" . NewHex
	return (StrPut(Content, "UTF-8") - 1 <= LLM_TRIGGER_JOURNAL_MAX_BYTES)
		? Content : false
}

_LLM_TriggerJournalParse(Content) {
	global LLM_TRIGGER_JOURNAL_HEADER, LLM_TRIGGER_JOURNAL_MAX_BYTES
	global LLM_TRIGGER_JOURNAL_PHASE_PENDING, LLM_TRIGGER_JOURNAL_PHASE_NEW
	global LLM_TRIGGER_JOURNAL_PHASE_OLD
	if !(Content is String) || Content == ""
		return false
	if InStr(Content, "`r") || StrPut(Content, "UTF-8") - 1 > LLM_TRIGGER_JOURNAL_MAX_BYTES
		return false
	Fields := StrSplit(Content, "`n")
	if Fields.Length != 7 || Fields[1] !== LLM_TRIGGER_JOURNAL_HEADER
		return false
	Phase := Fields[2]
	if (StrCompare(Phase, LLM_TRIGGER_JOURNAL_PHASE_PENDING, true) != 0
			&& StrCompare(Phase, LLM_TRIGGER_JOURNAL_PHASE_NEW, true) != 0
			&& StrCompare(Phase, LLM_TRIGGER_JOURNAL_PHASE_OLD, true) != 0)
		return false
	if !RegExMatch(Fields[3], "^[A-Za-z0-9._-]{1,80}$")
		return false
	if (Fields[5] !== "0" && Fields[5] !== "1")
		return false
	Owner := _LLM_TriggerJournalDecodeHex(Fields[4])
	OldValue := _LLM_TriggerJournalDecodeHex(Fields[6])
	NewValue := _LLM_TriggerJournalDecodeHex(Fields[7])
	if !Owner["ok"] || !OldValue["ok"] || !NewValue["ok"] || Owner["value"] == ""
		return false
	return Map(
		"phase", Phase,
		"tx_id", Fields[3],
		"owner", Owner["value"],
		"old_present", Integer(Fields[5]),
		"old_value", OldValue["value"],
		"new_value", NewValue["value"])
}





; =========================================
; =========================================
; ======= 3/ Atomic Journal Storage =======
; =========================================
; =========================================

_LLM_TriggerJournalPublish(Record, Port := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalPublish(Record, Port, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_STAGE_SUFFIX
	Port := _LLM_TriggerJournalResolvePort(Port)
	Path := _LLM_TriggerJournalPath(ExplicitPath)
	if !(Port is Map) || Path == ""
		return false
	Content := _LLM_TriggerJournalSerialize(Record)
	if !(Content is String)
		return false
	StagePath := Path . LLM_TRIGGER_JOURNAL_STAGE_SUFFIX
	if !_LLM_TriggerJournalPortStatus(Port, "write", StagePath, Content)
		return false
	if !_LLM_TriggerJournalPortRead(Port, StagePath, &Staged)
		return false
	if StrCompare(Staged, Content, true) != 0 {
		try LoggerError("LLM", "Trigger journal staging verification failed.")
		return false
	}
	; The stage bytes are already verified and FSAtomicMoveReplace uses
	; MOVEFILE_WRITE_THROUGH. Once that atomic rename reports success, the live
	; frame is authoritative. A second read cannot revoke the completed mutation:
	; doing so left memory at the old phase while disk held the new phase, making
	; a crash during compensation unrecoverable.
	if !_LLM_TriggerJournalPortStatus(Port, "move_replace", StagePath, Path)
		return false
	return true
}

_LLM_TriggerJournalRead(Port := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalRead(Port, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	Port := _LLM_TriggerJournalResolvePort(Port)
	Path := _LLM_TriggerJournalPath(ExplicitPath)
	if !(Port is Map) || Path == ""
		return Map("ok", 0, "exists", 0, "kind", "invalid_arguments")
	if !_LLM_TriggerJournalPortExists(Port, Path, &Exists)
		return Map("ok", 0, "exists", 0, "kind", "probe_failed")
	if !Exists
		return Map("ok", 1, "exists", 0, "kind", "absent")
	if !_LLM_TriggerJournalPortRead(Port, Path, &Content)
		return Map("ok", 0, "exists", 1, "kind", "unreadable")
	Record := _LLM_TriggerJournalParse(Content)
	if !(Record is Map) {
		try LoggerError("LLM", "Trigger journal is malformed; recovery was refused without changing configuration.")
		return Map("ok", 0, "exists", 1, "kind", "malformed")
	}
	return Map("ok", 1, "exists", 1, "kind", "ready", "record", Record)
}

; Read-only preflight for a global lifecycle bundle. The journal is re-read
; after every listed owner is atomically acquired; this hint merely ensures a
; retained terminal record naming an old config path is part of the dry bundle.
LLM_TriggerJournalOwnerHint(Port := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_TriggerJournalOwnerHint(Port, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	ReadResult := _LLM_TriggerJournalRead(Port, ExplicitPath)
	if !ReadResult["ok"] {
		if ReadResult["kind"] == "invalid_arguments"
			return false
		_LLM_TriggerJournalEnterReadOnly(ReadResult["kind"])
		; A quarantined frame has no trustworthy owner path to add. Returning an
		; empty hint lets Exit acquire the known current owner; destructive callers
		; still fail later at strict reconciliation.
		return ""
	}
	if !ReadResult["exists"] {
		_LLM_TriggerJournalClearReadOnly()
		return ""
	}
	return ReadResult["record"]["owner"]
}

_LLM_TriggerJournalDelete(Port := 0, ExplicitPath := "", IncludeStage := true) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalDelete(Port, ExplicitPath, IncludeStage)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_STAGE_SUFFIX
	Port := _LLM_TriggerJournalResolvePort(Port)
	Path := _LLM_TriggerJournalPath(ExplicitPath)
	if !(Port is Map) || Path == ""
		return false
	Candidates := IncludeStage ? [Path . LLM_TRIGGER_JOURNAL_STAGE_SUFFIX, Path] : [Path]
	for Candidate in Candidates {
		if !_LLM_TriggerJournalPortStatus(Port, "delete", Candidate)
			return false
		if !_LLM_TriggerJournalPortExists(Port, Candidate, &StillExists)
			return false
		if StillExists {
			try LoggerError("LLM", "Trigger journal delete reported success but the artifact remains.")
			return false
		}
	}
	return true
}

_LLM_TriggerJournalDeleteTerminalBestEffort(Port := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalDeleteTerminalBestEffort(Port,
			ExplicitPath)
		finally Critical(InheritedCritical)
	}
	if _LLM_TriggerJournalDelete(Port, ExplicitPath)
		return true
	try LoggerWarn("LLM", "A terminal trigger journal could not be removed; the next boot will clean the replay-safe artifact.")
	return true
}





; =================================================
; =================================================
; ======= 4/ Durable Trigger Reconciliation =======
; =================================================
; =================================================

_LLM_TriggerJournalSnapshotIsValid(Snapshot) {
	if !(Snapshot is Map)
		return false
	for Key in ["ok", "present", "value"] {
		if !Snapshot.Has(Key)
			return false
	}
	if !(Snapshot["ok"] is Integer) || Snapshot["ok"] != 1
		return false
	if !(Snapshot["present"] is Integer)
			|| (Snapshot["present"] != 0 && Snapshot["present"] != 1)
		return false
	return Snapshot["value"] is String
}

_LLM_TriggerJournalReadSnapshot(Path, ReadTriggerFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalReadSnapshot(Path, ReadTriggerFn)
		finally Critical(InheritedCritical)
	}
	if HasMethod(ReadTriggerFn, "Call") {
		try Snapshot := ReadTriggerFn.Call(Path)
		catch as Err {
			try LoggerError("LLM", "Trigger journal config reader failed: {1}.", Err.Message)
			return Map("ok", 0, "present", 0, "value", "")
		}
		if !_LLM_TriggerJournalSnapshotIsValid(Snapshot) {
			try LoggerError("LLM", "Trigger journal config reader returned a malformed snapshot.")
			return Map("ok", 0, "present", 0, "value", "")
		}
		return Snapshot
	}
	if !FSExists(Path)
		return Map("ok", 1, "present", 0, "value", "")
	Sections := ParseTomlFile(Path)
	if TOML_ReadFailed(Path) {
		try LoggerError("LLM", "Trigger journal could not read its owner configuration.")
		return Map("ok", 0, "present", 0, "value", "")
	}
	if !Sections.Has("llm") || !Sections["llm"].Has("trigger_shortcut")
		return Map("ok", 1, "present", 0, "value", "")
	Value := Sections["llm"]["trigger_shortcut"]
	if !(Value is String) {
		try LoggerError("LLM", "Trigger journal found a non-string durable shortcut value.")
		return Map("ok", 0, "present", 0, "value", "")
	}
	return Map("ok", 1, "present", 1, "value", Value)
}

_LLM_TriggerJournalSnapshotMatches(Snapshot, Present, Value) {
	return _LLM_TriggerJournalSnapshotIsValid(Snapshot)
		&& Snapshot["present"] == Present
		&& (!Present || StrCompare(Snapshot["value"], Value, true) == 0)
}

_LLM_TriggerJournalInvokeWriter(Path, Updates, WriterFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalInvokeWriter(Path, Updates, WriterFn)
		finally Critical(InheritedCritical)
	}
	try {
		if HasMethod(WriterFn, "Call")
			Written := WriterFn.Call(Path, Updates)
		else
			Written := TOML_BatchWrite(Path, Updates)
	} catch as Err {
		try LoggerError("LLM", "Trigger journal configuration writer failed: {1}.", Err.Message)
		return false
	}
	if !(Written is Integer) || Written != 1 {
		try LoggerError("LLM", "Trigger journal configuration writer returned a malformed or refused status.")
		return false
	}
	return true
}

_LLM_TriggerJournalWriteOld(Record, WriterFn := 0, ReadTriggerFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalWriteOld(Record, WriterFn,
			ReadTriggerFn)
		finally Critical(InheritedCritical)
	}
	Updates := Record["old_present"]
		? [{ Section: "llm", Key: "trigger_shortcut",
			Value: Record["old_value"] }]
		: [{ Section: "llm", Key: "trigger_shortcut", Delete: true }]
	if !_LLM_TriggerJournalInvokeWriter(Record["owner"], Updates, WriterFn)
		return false
	Verified := _LLM_TriggerJournalReadSnapshot(Record["owner"], ReadTriggerFn)
	if !_LLM_TriggerJournalSnapshotMatches(Verified,
			Record["old_present"], Record["old_value"]) {
		try LoggerError("LLM", "Trigger journal rollback verification failed.")
		return false
	}
	return true
}

_LLM_TriggerJournalPromote(Record, Phase, Port := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalPromote(Record, Phase, Port,
			ExplicitPath)
		finally Critical(InheritedCritical)
	}
	Candidate := Record.Clone()
	Candidate["phase"] := Phase
	if !_LLM_TriggerJournalPublish(Candidate, Port, ExplicitPath)
		return false
	Record["phase"] := Phase
	return true
}

_LLM_TriggerJournalReconcileRecord(Record, Port := 0, ReadTriggerFn := 0,
		WriterFn := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalReconcileRecord(Record, Port,
			ReadTriggerFn, WriterFn, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_PHASE_PENDING, LLM_TRIGGER_JOURNAL_PHASE_NEW
	global LLM_TRIGGER_JOURNAL_PHASE_OLD
	Current := _LLM_TriggerJournalReadSnapshot(Record["owner"], ReadTriggerFn)
	if !_LLM_TriggerJournalSnapshotIsValid(Current)
		return false
	MatchesOld := _LLM_TriggerJournalSnapshotMatches(Current,
		Record["old_present"], Record["old_value"])
	MatchesNew := _LLM_TriggerJournalSnapshotMatches(Current, 1, Record["new_value"])
	if (Record["phase"] == LLM_TRIGGER_JOURNAL_PHASE_PENDING) {
		if !MatchesOld && !MatchesNew {
			try LoggerError("LLM", "Pending trigger journal conflicts with a third durable value; recovery was refused.")
			return false
		}
		if MatchesNew && !_LLM_TriggerJournalWriteOld(Record, WriterFn, ReadTriggerFn)
			return false
		if !_LLM_TriggerJournalPromote(Record,
				LLM_TRIGGER_JOURNAL_PHASE_OLD, Port, ExplicitPath)
			return false
		_LLM_TriggerJournalDeleteTerminalBestEffort(Port, ExplicitPath)
		try LoggerInfo("LLM", "Recovered a pending trigger shortcut transaction to its previous durable authority.")
		return true
	}
	if (Record["phase"] == LLM_TRIGGER_JOURNAL_PHASE_NEW) {
		if !MatchesNew {
			try LoggerError("LLM", "Committed-new trigger journal conflicts with durable configuration; cleanup was refused.")
			return false
		}
		return _LLM_TriggerJournalDeleteTerminalBestEffort(Port, ExplicitPath)
	}
	if (Record["phase"] == LLM_TRIGGER_JOURNAL_PHASE_OLD) {
		if !MatchesOld {
			try LoggerError("LLM", "Committed-old trigger journal conflicts with durable configuration; cleanup was refused.")
			return false
		}
		return _LLM_TriggerJournalDeleteTerminalBestEffort(Port, ExplicitPath)
	}
	return false
}

LLM_TriggerJournalReconcile(Port := 0, ReadTriggerFn := 0,
		WriterFn := 0, ExplicitPath := "", ExistingOwner := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_TriggerJournalReconcile(Port, ReadTriggerFn,
			WriterFn, ExplicitPath, ExistingOwner)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_STAGE_SUFFIX
	Port := _LLM_TriggerJournalResolvePort(Port)
	JournalPath := _LLM_TriggerJournalPath(ExplicitPath)
	if !(Port is Map) || JournalPath == ""
		return false
	ReadResult := _LLM_TriggerJournalRead(Port, ExplicitPath)
	if !ReadResult["ok"] {
		_LLM_TriggerJournalEnterReadOnly(ReadResult["kind"])
		return false
	}
	if !ReadResult["exists"] {
		; A stage never became authoritative. Its cleanup is deliberately best
		; effort because a live WAL is the only recovery fact.
		try Port["delete"].Call(JournalPath . LLM_TRIGGER_JOURNAL_STAGE_SUFFIX)
		_LLM_TriggerJournalClearReadOnly()
		return true
	}
	Record := ReadResult["record"]
	OwnerPath := Record["owner"]
	BorrowedOwner := _ConfigWriteLeaseSelectOwner(ExistingOwner, OwnerPath)
	Borrowed := BorrowedOwner is Object
	if Borrowed {
		OwnerToken := BorrowedOwner
	} else {
		OwnerToken := _ConfigWriteLeaseTryAcquire(OwnerPath,
			"llm-trigger-journal")
		if !(OwnerToken is Object) {
			try LoggerError("LLM", "Trigger journal recovery could not acquire its owner configuration lease.")
			return false
		}
	}
	try {
		; Re-read only after ownership. A callback may have yielded between the
		; locator probe and the lease, and recovery must act on the latest record.
		OwnedRead := _LLM_TriggerJournalRead(Port, ExplicitPath)
		if !OwnedRead["ok"] {
			_LLM_TriggerJournalEnterReadOnly(OwnedRead["kind"])
			return false
		}
		if !OwnedRead["exists"] {
			_LLM_TriggerJournalClearReadOnly()
			return true
		}
		OwnedRecord := OwnedRead["record"]
		if _ConfigWriteLeaseKey(OwnedRecord["owner"])
				!= _ConfigWriteLeaseKey(OwnerPath) {
			try LoggerError("LLM", "Trigger journal owner changed while recovery was acquiring its lease.")
			return false
		}
		Reconciled := _LLM_TriggerJournalReconcileRecord(OwnedRecord, Port,
			ReadTriggerFn, WriterFn, ExplicitPath)
		if Reconciled
			_LLM_TriggerJournalClearReadOnly()
		else
			_LLM_TriggerJournalEnterReadOnly("recovery_refused")
		return Reconciled
	} finally {
		if !Borrowed
			_ConfigWriteLeaseRelease(OwnerToken)
	}
}

_LLM_TriggerJournalPrepareTransaction(ConfigPath, NewValue, ExistingOwner,
		Port := 0, ReadTriggerFn := 0, WriterFn := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalPrepareTransaction(ConfigPath, NewValue,
			ExistingOwner, Port, ReadTriggerFn, WriterFn, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	if !_ConfigWriteLeaseOwns(ExistingOwner, ConfigPath) {
		try LoggerError("LLM", "Trigger journal preparation refused a stale configuration owner.")
		return false
	}
	if !LLM_TriggerJournalReconcile(Port, ReadTriggerFn,
			WriterFn, ExplicitPath, ExistingOwner)
		return false
	OldSnapshot := _LLM_TriggerJournalReadSnapshot(ConfigPath, ReadTriggerFn)
	if !_LLM_TriggerJournalSnapshotIsValid(OldSnapshot)
		return false
	Record := _LLM_TriggerJournalNewRecord(ConfigPath, OldSnapshot, NewValue)
	if !(Record is Map) || !_LLM_TriggerJournalPublish(Record, Port, ExplicitPath)
		return false
	return Record
}

_LLM_TriggerJournalVerifyNew(Record, ReadTriggerFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalVerifyNew(Record, ReadTriggerFn)
		finally Critical(InheritedCritical)
	}
	Snapshot := _LLM_TriggerJournalReadSnapshot(Record["owner"], ReadTriggerFn)
	return _LLM_TriggerJournalSnapshotMatches(Snapshot, 1, Record["new_value"])
}

_LLM_TriggerJournalCommitNew(Record, Port := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalCommitNew(Record, Port, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_PHASE_NEW
	return _LLM_TriggerJournalPromote(Record,
		LLM_TRIGGER_JOURNAL_PHASE_NEW, Port, ExplicitPath)
}

_LLM_TriggerJournalRollback(Record, Port := 0, ReadTriggerFn := 0,
		WriterFn := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_TriggerJournalRollback(Record, Port, ReadTriggerFn,
			WriterFn, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	global LLM_TRIGGER_JOURNAL_PHASE_OLD
	Current := _LLM_TriggerJournalReadSnapshot(Record["owner"], ReadTriggerFn)
	if !_LLM_TriggerJournalSnapshotIsValid(Current)
		return false
	if !_LLM_TriggerJournalSnapshotMatches(Current,
			Record["old_present"], Record["old_value"]) {
		if !_LLM_TriggerJournalSnapshotMatches(Current, 1, Record["new_value"]) {
			try LoggerError("LLM", "Trigger journal rollback found a third durable value and refused to overwrite it.")
			return false
		}
		if !_LLM_TriggerJournalWriteOld(Record, WriterFn, ReadTriggerFn)
			return false
	}
	return _LLM_TriggerJournalPromote(Record,
		LLM_TRIGGER_JOURNAL_PHASE_OLD, Port, ExplicitPath)
}

LLM_TriggerJournalRecoverAtBoot(Port := 0, ReadTriggerFn := 0,
		WriterFn := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_TriggerJournalRecoverAtBoot(Port, ReadTriggerFn,
			WriterFn, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	ResolvedPort := _LLM_TriggerJournalResolvePort(Port)
	JournalPath := _LLM_TriggerJournalPath(ExplicitPath)
	if !(ResolvedPort is Map) || JournalPath == ""
		return false
	if LLM_TriggerJournalReconcile(ResolvedPort, ReadTriggerFn,
			WriterFn, ExplicitPath)
		return true
	; A user-controlled malformed, unreadable or conflicting frame is preserved
	; byte-for-byte and disables only future trigger/config mutations. Booting the
	; rest of the keyboard driver is safe because current config remains untouched.
	if !LLM_TriggerJournalIsReadOnly()
		_LLM_TriggerJournalEnterReadOnly("boot_recovery_refused")
	return true
}

LLM_TriggerJournalPrepareDestructive(ConfigPath, ExistingOwners,
		Port := 0, ReadTriggerFn := 0, WriterFn := 0, ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_TriggerJournalPrepareDestructive(ConfigPath,
			ExistingOwners, Port, ReadTriggerFn, WriterFn, ExplicitPath)
		finally Critical(InheritedCritical)
	}
	ConfigOwner := _ConfigWriteLeaseSelectOwner(ExistingOwners, ConfigPath)
	if !(ConfigOwner is Object)
		return false
	if !LLM_TriggerJournalReconcile(Port, ReadTriggerFn,
			WriterFn, ExplicitPath, ExistingOwners)
		return false
	return _LLM_TriggerJournalDelete(Port, ExplicitPath)
}

LLM_TriggerJournalDrainForShutdown(Port := 0, ReadTriggerFn := 0,
		WriterFn := 0, ExplicitPath := "", ExistingOwner := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_TriggerJournalDrainForShutdown(Port, ReadTriggerFn,
			WriterFn, ExplicitPath, ExistingOwner)
		finally Critical(InheritedCritical)
	}
	if LLM_TriggerJournalReconcile(Port, ReadTriggerFn,
			WriterFn, ExplicitPath, ExistingOwner)
		return true
	; Process exit cannot overwrite configuration. Keeping a quarantined frame
	; for the next boot is safer than trapping the user in an unclosable driver.
	return LLM_TriggerJournalIsReadOnly()
}
