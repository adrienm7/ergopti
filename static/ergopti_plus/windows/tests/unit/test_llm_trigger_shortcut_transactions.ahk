; tests/unit/test_llm_trigger_shortcut_transactions.ahk

; ==============================================================================
; MODULE: LLM Trigger Shortcut Ownership and Persistence
; DESCRIPTION:
; Behavioural proof that an LLM shortcut candidate remains native-Off while its
; config write is in flight, becomes callable only after durability, restores
; the previous durable value after activation refusal, and retains every opaque
; handle when the previous exception-atomic Off transition is refused.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Transaction Fakes =======
; ====================================
; ====================================

global _LTST_Native := Map()
global _LTST_Events := []
global _LTST_WriteOk := true
global _LTST_RollbackWriteOk := true
global _LTST_WriteCalls := 0
global _LTST_WriteBatches := []
global _LTST_NotifyCalls := 0
global _LTST_NotifyOk := true
global _LTST_ObservedRaw := ""
global _LTST_FailNewOn := false
global _LTST_FailNewOff := false
global _LTST_FailOldOff := false
global _LTST_FireCandidateDuringWrite := false
global _LTST_FireCandidateDuringJournalCommit := false
global _LTST_FireOldDuringWrite := false
global _LTST_RetireCandidateDuringWrite := false
global _LTST_LlmCalls := 0
global _LTST_ForeignCalls := 0
global _LTST_AppDeliveries := 0
global _LTST_RecoveryCalls := 0
global _LTST_Scheduled := []
global _LTST_ScheduleDelays := []
global _LTST_ScheduleOk := true
global _LTST_ScheduleThrows := false
global _LTST_NotifyLeaseReacquired := 0
global _LTST_RefreshCalls := 0
global _LTST_RefreshLeaseReacquired := 0
global _LTST_DurablePresent := 1
global _LTST_DurableValue := ""
global _LTST_JournalFiles := Map()
global _LTST_JournalPath := "memory://llm-trigger.wal"
global _LTST_MutateRefusedCalls := Map()
global _LTST_CriticalStates := []

_LTST_Reset(WriteOk := true) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk, _LLM_Menu
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LTST_Native, _LTST_Events, _LTST_WriteOk
	global _LTST_RollbackWriteOk, _LTST_WriteCalls, _LTST_WriteBatches
	global _LTST_NotifyCalls, _LTST_NotifyOk, _LTST_ObservedRaw
	global _LTST_FailNewOn, _LTST_FailNewOff, _LTST_FailOldOff
	global _LTST_FireCandidateDuringWrite, _LTST_FireCandidateDuringJournalCommit
	global _LTST_FireOldDuringWrite
	global _LTST_RetireCandidateDuringWrite
	global _LTST_LlmCalls, _LTST_ForeignCalls, _LTST_AppDeliveries
	global _LTST_RecoveryCalls, _LTST_Scheduled, _LTST_ScheduleDelays
	global _LTST_ScheduleOk, _LTST_ScheduleThrows
	global _LTST_NotifyLeaseReacquired
	global _LTST_RefreshCalls
	global _LTST_RefreshLeaseReacquired
	global _LTST_DurablePresent, _LTST_DurableValue, _LTST_JournalFiles
	global _LTST_MutateRefusedCalls
	global _LTST_CriticalStates
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerRecoveryNextId
	global _LLM_Menu_TriggerFailureNoticeKey

	HOTKEY_REGISTRAR_BINDINGS := Map()
	HOTKEY_REGISTRAR_SPECS := Map()
	HOTKEY_REGISTRAR_NEXT_TOKEN := 0
	_LLM_Menu["trigger_shortcut"] := ""
	_LLM_Menu_TriggerHandle := ""
	_LLM_Menu_TriggerAhk := ""
	_LLM_Menu_TriggerStatus := _LLM_Menu_TriggerStatusForAhk("")
	_LLM_Menu_TriggerRecoveryHandles := []
	_LLM_Menu_TriggerRecovery := false
	_LLM_Menu_TriggerRecoveryNextId := 0
	_LLM_Menu_TriggerFailureNoticeKey := ""
	_LLM_TriggerJournalClearReadOnly()
	_LTST_Native := Map()
	_LTST_Events := []
	_LTST_WriteOk := WriteOk
	_LTST_RollbackWriteOk := true
	_LTST_WriteCalls := 0
	_LTST_WriteBatches := []
	_LTST_NotifyCalls := 0
	_LTST_NotifyOk := true
	_LTST_ObservedRaw := ""
	_LTST_FailNewOn := false
	_LTST_FailNewOff := false
	_LTST_FailOldOff := false
	_LTST_FireCandidateDuringWrite := false
	_LTST_FireCandidateDuringJournalCommit := false
	_LTST_FireOldDuringWrite := false
	_LTST_RetireCandidateDuringWrite := false
	_LTST_LlmCalls := 0
	_LTST_ForeignCalls := 0
	_LTST_AppDeliveries := 0
	_LTST_RecoveryCalls := 0
	_LTST_Scheduled := []
	_LTST_ScheduleDelays := []
	_LTST_ScheduleOk := true
	_LTST_ScheduleThrows := false
	_LTST_NotifyLeaseReacquired := 0
	_LTST_RefreshCalls := 0
	_LTST_RefreshLeaseReacquired := 0
	_LTST_DurablePresent := 1
	_LTST_DurableValue := ""
	_LTST_JournalFiles := Map()
	_LTST_MutateRefusedCalls := Map()
	_LTST_CriticalStates := []
}

_LTST_RecordCritical(Phase) {
	global _LTST_CriticalStates
	_LTST_CriticalStates.Push(Map("phase", Phase, "critical", A_IsCritical))
}

_LTST_JournalExists(Path) {
	global _LTST_JournalFiles
	_LTST_RecordCritical("journal_exists")
	return _LTST_JournalFiles.Has(Path) ? 1 : 0
}

_LTST_JournalRead(Path, MaxBytes) {
	global _LTST_JournalFiles
	_LTST_RecordCritical("journal_read")
	if !_LTST_JournalFiles.Has(Path)
		return false
	Content := _LTST_JournalFiles[Path]
	return (StrPut(Content, "UTF-8") - 1 <= MaxBytes) ? Content : false
}

_LTST_JournalWrite(Path, Content) {
	global _LTST_JournalFiles
	_LTST_RecordCritical("journal_write")
	_LTST_JournalFiles[Path] := Content
	return 1
}

_LTST_JournalMove(Source, Destination) {
	global _LTST_JournalFiles, _LTST_FireCandidateDuringJournalCommit
	_LTST_RecordCritical("journal_move")
	if !_LTST_JournalFiles.Has(Source)
		return 0
	Candidate := _LLM_TriggerJournalParse(_LTST_JournalFiles[Source])
	if _LTST_FireCandidateDuringJournalCommit && Candidate is Map
			&& Candidate["phase"] = "committed_new"
		_LTST_Fire("^n")
	_LTST_JournalFiles[Destination] := _LTST_JournalFiles[Source]
	_LTST_JournalFiles.Delete(Source)
	return 1
}

_LTST_JournalDelete(Path) {
	global _LTST_JournalFiles
	_LTST_RecordCritical("journal_delete")
	if _LTST_JournalFiles.Has(Path)
		_LTST_JournalFiles.Delete(Path)
	return 1
}

_LTST_JournalPort() {
	return Map(
		"exists", _LTST_JournalExists,
		"read_bounded", _LTST_JournalRead,
		"write", _LTST_JournalWrite,
		"move_replace", _LTST_JournalMove,
		"delete", _LTST_JournalDelete)
}

_LTST_ReadTrigger(Path) {
	global _LTST_DurablePresent, _LTST_DurableValue
	_LTST_RecordCritical("config_read")
	return Map("ok", 1, "present", _LTST_DurablePresent,
		"value", _LTST_DurableValue)
}

_LTST_ApplyDurableUpdates(Updates) {
	global _LTST_DurablePresent, _LTST_DurableValue
	for Update in Updates {
		if (Update.Section != "llm" || Update.Key != "trigger_shortcut")
			continue
		DeleteRequested := Update.HasOwnProp("Delete")
			&& (Update.Delete is Integer) && Update.Delete == 1
		if DeleteRequested {
			_LTST_DurablePresent := 0
			_LTST_DurableValue := ""
		} else {
			_LTST_DurablePresent := 1
			_LTST_DurableValue := String(Update.Value)
		}
	}
}

_LTST_Commit(raw, WriterFn := 0, NotifyFn := 0, HotkeyFn := 0,
		ProbeFn := 0, CallbackFn := 0, SchedulerFn := 0, RefreshFn := 0) {
	global _LTST_JournalPath
	return LLM_Menu_CommitTriggerShortcut(raw, WriterFn, NotifyFn,
		HotkeyFn, ProbeFn, CallbackFn, SchedulerFn, RefreshFn,
		_LTST_JournalPort(), _LTST_ReadTrigger, _LTST_JournalPath)
}

_LTST_Hotkey(Name, Action := unset, Options := unset) {
	global _LTST_Native, _LTST_Events, _LTST_FailNewOn
	global _LTST_FailNewOff, _LTST_FailOldOff
	_LTST_RecordCritical("hotkey")
	if !IsSet(Action)
		return _LTST_Native.Has(Name)
	if IsSet(Options) {
		_LTST_Events.Push(Name . " " . Options)
		if (Options != "Off" && Options != "On")
			throw Error("unexpected fake Hotkey registration option")
		; AHK Hotkey registration is exception-atomic. Injected failures occur
		; before the fake mutates native callback or enabled state
		if (_LTST_FailNewOn && Options = "On" && Name = "^n")
			throw Error("injected activation failure before native mutation")
		_LTST_Native[Name] := { callback: Action, enabled: Options = "On" }
		return true
	}
	if (Action = "Off") {
		_LTST_Events.Push(Name . " Off")
		if (_LTST_FailNewOff && Name = "^n")
			throw Error("injected candidate-Off failure before native mutation")
		if (_LTST_FailOldOff && Name = "^l")
			throw Error("injected previous-Off failure before native mutation")
		if _LTST_Native.Has(Name)
			_LTST_Native[Name].enabled := false
		return true
	}
	if (Action = "On") {
		_LTST_Events.Push(Name . " On")
		if (_LTST_FailNewOn && Name = "^n")
			throw Error("injected activation failure before native mutation")
		if _LTST_Native.Has(Name)
			_LTST_Native[Name].enabled := true
		return true
	}
	throw Error("unexpected fake Hotkey action")
}

_LTST_Probe(Name) {
	global _LTST_Native
	_LTST_RecordCritical("probe")
	return _LTST_Native.Has(Name)
}

_LTST_Fire(Name) {
	global _LTST_Native, _LTST_AppDeliveries
	if _LTST_Native.Has(Name) && _LTST_Native[Name].enabled {
		_LTST_Native[Name].callback.Call("fake-hotkey")
		return true
	}
	_LTST_AppDeliveries += 1
	return false
}

; Deliberately zero-arity: the shared registrar port must hide AHK's native
; HotkeyName argument instead of requiring every consumer to accept Args*
_LTST_LlmCallback() {
	global _LTST_LlmCalls
	_LTST_LlmCalls += 1
}

_LTST_ForeignCallback() {
	global _LTST_ForeignCalls
	_LTST_ForeignCalls += 1
}

_LTST_Writer(Path, Updates) {
	global _LTST_WriteOk, _LTST_RollbackWriteOk, _LTST_WriteCalls
	global _LTST_WriteBatches, _LTST_Events, _LTST_ObservedRaw, _LLM_Menu
	global _LTST_FireCandidateDuringWrite, _LTST_FireOldDuringWrite
	global _LTST_RetireCandidateDuringWrite, HOTKEY_REGISTRAR_SPECS
	global _LTST_MutateRefusedCalls
	_LTST_RecordCritical("config_write")

	_LTST_WriteCalls += 1
	_LTST_WriteBatches.Push(Updates)
	_LTST_Events.Push("write")
	if (_LTST_WriteCalls = 1) {
		_LTST_ObservedRaw := _LLM_Menu["trigger_shortcut"]
		if _LTST_RetireCandidateDuringWrite && HOTKEY_REGISTRAR_SPECS.Has("^n") {
			_LTST_RetireCandidateDuringWrite := false
			Candidate := HOTKEY_REGISTRAR_SPECS["^n"]
			_HotkeyRegistrarRetire(Candidate["handle"], _LTST_Hotkey)
		}
		if _LTST_FireOldDuringWrite
			_LTST_Fire("^l")
		if _LTST_FireCandidateDuringWrite
			_LTST_Fire("^n")
	}
	Result := (_LTST_WriteCalls = 1) ? _LTST_WriteOk : _LTST_RollbackWriteOk
	if Result || _LTST_MutateRefusedCalls.Has(_LTST_WriteCalls)
		_LTST_ApplyDurableUpdates(Updates)
	return Result
}

_LTST_Notify(Message, Options) {
	global _LTST_NotifyCalls, _LTST_NotifyOk
	global _LTST_Events, _LTST_NotifyLeaseReacquired
	global ConfigurationFile
	_LTST_RecordCritical("notify")
	_LTST_NotifyCalls += 1
	_LTST_Events.Push("notify")
	Token := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "llm-test-notify")
	if (Token is Object) {
		_LTST_NotifyLeaseReacquired += 1
		_ConfigWriteLeaseRelease(Token)
	}
	return _LTST_NotifyOk
}

_LTST_Schedule(Callback, DelayMs) {
	global _LTST_Scheduled, _LTST_ScheduleDelays
	global _LTST_ScheduleOk, _LTST_ScheduleThrows
	global _LTST_RecoveryCalls, _LTST_Events
	_LTST_RecordCritical("schedule")
	_LTST_RecoveryCalls += 1
	_LTST_Events.Push("schedule")
	_LTST_ScheduleDelays.Push(DelayMs)
	if _LTST_ScheduleThrows
		throw Error("injected recovery scheduling failure")
	if !_LTST_ScheduleOk
		return false
	_LTST_Scheduled.Push(Callback)
	return true
}

_LTST_RunScheduled() {
	global _LTST_Scheduled
	AssertTrue(_LTST_Scheduled.Length > 0,
		"a pending recovery must own a post-lease callback")
	Callback := _LTST_Scheduled.RemoveAt(1)
	return Callback.Call()
}

_LTST_Refresh() {
	global _LTST_RefreshCalls, _LTST_Events, _LTST_RefreshLeaseReacquired
	global ConfigurationFile
	_LTST_RecordCritical("refresh")
	_LTST_RefreshCalls += 1
	_LTST_Events.Push("refresh")
	Token := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "llm-test-refresh")
	if (Token is Object) {
		_LTST_RefreshLeaseReacquired += 1
		_ConfigWriteLeaseRelease(Token)
	}
	return true
}

_LTST_WithFixture(TestFn, WriteOk := true) {
	global ConfigurationFile, _SaveFullConfigReady
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN
	global _LLM_Menu, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerRecoveryNextId
	global _LLM_Menu_TriggerFailureNoticeKey

	HadPath := IsSet(ConfigurationFile)
	SavedPath := HadPath ? ConfigurationFile : ""
	HadReady := IsSet(_SaveFullConfigReady)
	SavedReady := HadReady ? _SaveFullConfigReady : false
	SavedBindings := HOTKEY_REGISTRAR_BINDINGS
	SavedSpecs := HOTKEY_REGISTRAR_SPECS
	SavedToken := HOTKEY_REGISTRAR_NEXT_TOKEN
	SavedRaw := _LLM_Menu["trigger_shortcut"]
	SavedHandle := _LLM_Menu_TriggerHandle
	SavedAhk := _LLM_Menu_TriggerAhk
	SavedStatus := _LLM_Menu_TriggerStatus
	SavedRecovery := _LLM_Menu_TriggerRecoveryHandles
	SavedRecoveryRecord := _LLM_Menu_TriggerRecovery
	SavedRecoveryId := _LLM_Menu_TriggerRecoveryNextId
	SavedFailureNotice := _LLM_Menu_TriggerFailureNoticeKey
	ConfigurationFile := A_Temp . "\ergopti_llm_trigger_transaction.toml"
	_SaveFullConfigReady := true
	_LTST_Reset(WriteOk)
	try return TestFn.Call()
	finally {
		ConfigurationFile := HadPath ? SavedPath : unset
		_SaveFullConfigReady := HadReady ? SavedReady : unset
		HOTKEY_REGISTRAR_BINDINGS := SavedBindings
		HOTKEY_REGISTRAR_SPECS := SavedSpecs
		HOTKEY_REGISTRAR_NEXT_TOKEN := SavedToken
		_LLM_Menu["trigger_shortcut"] := SavedRaw
		_LLM_Menu_TriggerHandle := SavedHandle
		_LLM_Menu_TriggerAhk := SavedAhk
		_LLM_Menu_TriggerStatus := SavedStatus
		_LLM_Menu_TriggerRecoveryHandles := SavedRecovery
		_LLM_Menu_TriggerRecovery := SavedRecoveryRecord
		_LLM_Menu_TriggerRecoveryNextId := SavedRecoveryId
		_LLM_Menu_TriggerFailureNoticeKey := SavedFailureNotice
	}
}

_LTST_SeedOld() {
	global _LTST_Events, _LTST_DurablePresent, _LTST_DurableValue
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Ctrl+L", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback))
	_LTST_DurablePresent := 1
	_LTST_DurableValue := "Ctrl+L"
	_LTST_Events := []
}

_LTST_AssertEvents(Expected, Message) {
	global _LTST_Events
	AssertEqual(Expected.Length, _LTST_Events.Length, Message . " (event count)")
	for Index, Event in Expected
		AssertEqual(Event, _LTST_Events[Index], Message . " (event " . Index . ")")
}

_LTST_AssertCriticalStates(RequiredPhases, Message) {
	global _LTST_CriticalStates
	Seen := Map()
	AssertTrue(_LTST_CriticalStates.Length > 0,
		Message . " (the fixture must cross an adapter boundary)")
	for Sample in _LTST_CriticalStates {
		Seen[Sample["phase"]] := true
		AssertEqual(0, Sample["critical"],
			Message . " (" . Sample["phase"] . ")")
	}
	for Phase in RequiredPhases
		AssertTrue(Seen.Has(Phase), Message . " (missing " . Phase . ")")
}





; ==========================================
; ==========================================
; ======= 2/ Transaction Regressions =======
; ==========================================
; ==========================================

_LTST_SharedGrammar() {
	AssertEqual("^space", LLM_Menu_ShortcutToAhk("control+space"))
	AssertEqual("^m", LLM_Menu_ShortcutToAhk("ctrl+ctrl+m"))
	AssertEqual("", LLM_Menu_ShortcutToAhk("crtl+space"))
}
Test("[llm-trigger-tx] translation delegates to the shared chord grammar",
	_LTST_SharedGrammar)

_LTST_ZeroArityCore() {
	global _LTST_LlmCalls
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("Ctrl+L", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback))
	_LTST_Fire("^l")
	AssertEqual(1, _LTST_LlmCalls,
		"the registrar must invoke the zero-arity consumer without native arguments")
}

_LTST_ZeroArity() {
	return _LTST_WithFixture(_LTST_ZeroArityCore)
}
Test("[llm-trigger-tx] callback keeps the shared zero-arity contract",
	_LTST_ZeroArity)

_LTST_ForeignOwnerCore() {
	global _LTST_WriteCalls, _LTST_ForeignCalls, _LTST_NotifyCalls
	global _LTST_NotifyLeaseReacquired, _LTST_Events
	ForeignHandle := _HotkeyRegistrarBindOwned("Ctrl+N", _LTST_ForeignCallback,
		"metrics:typing", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(ForeignHandle != "")
	_LTST_Events := []
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual(0, _LTST_WriteCalls)
	AssertEqual(1, _LTST_NotifyCalls)
	AssertEqual(1, _LTST_NotifyLeaseReacquired,
		"the collision terminal must run only after config ownership is released")
	_LTST_AssertEvents(["notify"],
		"an owned chord must be refused before native mutation and reported once")
	_LTST_Fire("^n")
	AssertEqual(1, _LTST_ForeignCalls)
}

_LTST_ForeignOwner() {
	return _LTST_WithFixture(_LTST_ForeignOwnerCore)
}
Test("[llm-trigger-tx] a foreign registrar owner cannot be clobbered",
	_LTST_ForeignOwner)

_LTST_WriteFailureCore() {
	global _LLM_Menu, _LLM_Menu_TriggerAhk, _LLM_Menu_TriggerRecoveryHandles
	global _LTST_ObservedRaw, _LTST_FireCandidateDuringWrite
	global _LTST_FireOldDuringWrite, _LTST_LlmCalls, _LTST_AppDeliveries
	_LTST_SeedOld()
	_LTST_FireCandidateDuringWrite := true
	_LTST_FireOldDuringWrite := true
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual("Ctrl+L", _LTST_ObservedRaw)
	AssertEqual("Ctrl+L", _LLM_Menu["trigger_shortcut"])
	AssertEqual("^l", _LLM_Menu_TriggerAhk)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	_LTST_AssertEvents(["^n Off", "write", "notify"],
		"a refused write must discard the inert reservation")
	_LTST_Fire("^l")
	_LTST_Fire("^n")
	AssertEqual(2, _LTST_LlmCalls,
		"the old callback must remain authoritative throughout the failure")
	AssertEqual(2, _LTST_AppDeliveries,
		"the disabled candidate must pass through during and after the write")
}

_LTST_WriteFailure() {
	return _LTST_WithFixture(_LTST_WriteFailureCore, false)
}
Test("[llm-trigger-tx] writer failure keeps the candidate inert",
	_LTST_WriteFailure)

_LTST_ClearWriteFailureCore() {
	global _LLM_Menu, _LLM_Menu_TriggerAhk, _LTST_LlmCalls
	_LTST_SeedOld()
	AssertFalse(_LTST_Commit("", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual("Ctrl+L", _LLM_Menu["trigger_shortcut"])
	AssertEqual("^l", _LLM_Menu_TriggerAhk)
	_LTST_AssertEvents(["write", "notify"],
		"a refused clear must leave the old native binding armed throughout")
	_LTST_Fire("^l")
	AssertEqual(1, _LTST_LlmCalls)
}

_LTST_ClearWriteFailure() {
	return _LTST_WithFixture(_LTST_ClearWriteFailureCore, false)
}
Test("[llm-trigger-tx] refused clear preserves the old callback",
	_LTST_ClearWriteFailure)

_LTST_SuccessCore() {
	global _LLM_Menu, _LLM_Menu_TriggerAhk, _LLM_Menu_TriggerStatus
	global _LLM_Menu_TriggerRecoveryHandles, LLM_TRIGGER_STATUS_ACTIVE
	global _LTST_ObservedRaw, _LTST_WriteBatches
	global _LTST_FireCandidateDuringWrite, _LTST_FireOldDuringWrite
	global _LTST_LlmCalls, _LTST_AppDeliveries
	_LTST_SeedOld()
	_LTST_FireCandidateDuringWrite := true
	_LTST_FireOldDuringWrite := true
	AssertTrue(_LTST_Commit("control+n", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual("Ctrl+L", _LTST_ObservedRaw,
		"the writer must observe the previous live value")
	AssertEqual("control+n", _LLM_Menu["trigger_shortcut"])
	AssertEqual("^n", _LLM_Menu_TriggerAhk)
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertEqual("llm", _LTST_WriteBatches[1][1].Section)
	AssertEqual("trigger_shortcut", _LTST_WriteBatches[1][1].Key)
	AssertEqual("control+n", _LTST_WriteBatches[1][1].Value)
	_LTST_AssertEvents(["^n Off", "write", "^n On", "^l Off"],
		"success must reserve Off, write, activate, then retire")
	_LTST_Fire("^l")
	_LTST_Fire("^n")
	AssertEqual(2, _LTST_LlmCalls)
	AssertEqual(2, _LTST_AppDeliveries)
}

_LTST_Success() {
	return _LTST_WithFixture(_LTST_SuccessCore)
}
Test("[llm-trigger-tx] success activates only after durability",
	_LTST_Success)

_LTST_CandidateCannotFireBeforeCommittedJournalCore() {
	global _LTST_FireCandidateDuringJournalCommit
	global _LTST_LlmCalls, _LTST_AppDeliveries
	_LTST_SeedOld()
	_LTST_FireCandidateDuringJournalCommit := true
	AssertTrue(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual(0, _LTST_LlmCalls,
		"the candidate callback must stay native-Off during committed-new publication")
	AssertEqual(1, _LTST_AppDeliveries,
		"a chord injected at the WAL boundary must pass through to the application")
	AssertTrue(_LTST_Fire("^n"))
	AssertEqual(1, _LTST_LlmCalls,
		"the callback must become live after the journal is durably committed")
}

_LTST_CandidateCannotFireBeforeCommittedJournal() {
	return _LTST_WithFixture(_LTST_CandidateCannotFireBeforeCommittedJournalCore)
}
Test("[llm-trigger-wal] candidate stays inert through committed-new publication "
	. "(llm-trigger-wal-causal-activation)",
	_LTST_CandidateCannotFireBeforeCommittedJournal)

_LTST_ActivationFailureCore() {
	global _LTST_FailNewOn, _LTST_WriteCalls, _LTST_WriteBatches
	global _LLM_Menu, _LLM_Menu_TriggerAhk, _LLM_Menu_TriggerStatus
	global LLM_TRIGGER_STATUS_ACTIVE, _LTST_LlmCalls
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual(2, _LTST_WriteCalls,
		"activation refusal must synchronously reverse the durable candidate")
	AssertEqual("Ctrl+L", _LTST_WriteBatches[2][1].Value)
	AssertEqual("Ctrl+L", _LLM_Menu["trigger_shortcut"])
	AssertEqual("^l", _LLM_Menu_TriggerAhk)
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	_LTST_AssertEvents(["^n Off", "write", "^n On", "write", "notify"],
		"exception-before-mutation On refusal must Abort then reverse-write")
	_LTST_Fire("^l")
	_LTST_Fire("^n")
	AssertEqual(1, _LTST_LlmCalls)
}

_LTST_ActivationFailure() {
	return _LTST_WithFixture(_LTST_ActivationFailureCore)
}
Test("[llm-trigger-tx] activation failure restores the old durable value",
	_LTST_ActivationFailure)

_LTST_RollbackWriteFailureCore() {
	global _LTST_FailNewOn, _LTST_RollbackWriteOk, _LTST_RecoveryCalls
	global _LLM_Menu_TriggerStatus, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global _LLM_Menu_TriggerRecoveryHandles, LLM_TRIGGER_STATUS_ACTIVE
	global _LTST_WriteCalls, _LTST_NotifyCalls, _LTST_NotifyLeaseReacquired
	global _LTST_Events, _LTST_LlmCalls, _LTST_RefreshLeaseReacquired
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	_LTST_RollbackWriteOk := false
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertEqual(1, _LTST_RecoveryCalls)
	AssertEqual(LLM_TRIGGER_STATUS_ROLLBACK_PENDING, _LLM_Menu_TriggerStatus)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length,
		"successful Abort leaves no native handle to recover")
	AssertTrue(LLM_Menu_TriggerNeedsAttention())
	AssertEqual(1, InStr(LLM_Menu_TriggerDisplayValue(), Chr(0x26A0)))
	_LTST_AssertEvents(["^n Off", "write", "^n On", "write", "schedule", "notify"],
		"failed reverse write must retain visible durable recovery")

	WritesBeforeBlockedEdit := _LTST_WriteCalls
	_LTST_Events := []
	AssertFalse(_LTST_Commit("Ctrl+P", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertEqual(WritesBeforeBlockedEdit, _LTST_WriteCalls,
		"an already-scheduled callback retains exclusive recovery ownership")
	AssertEqual(2, _LTST_NotifyCalls,
		"a recovery-blocked edit must produce one additional terminal")
	AssertEqual(2, _LTST_NotifyLeaseReacquired,
		"each refusal terminal must reacquire only after the lease is released")
	_LTST_AssertEvents(["notify"],
		"an edit must not duplicate a queued recovery callback")

	_LTST_FailNewOn := false
	_LTST_RollbackWriteOk := true
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled(),
		"the post-lease callback must complete the old durable rewrite")
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertFalse(LLM_Menu_TriggerNeedsAttention())
	AssertEqual(1, _LTST_RefreshLeaseReacquired,
		"the warning refresh must run only after recovery releases config ownership")
	_LTST_AssertEvents(["write", "refresh"],
		"rollback recovery must retry once, then refresh its cleared warning")

	_LTST_Events := []
	AssertTrue(_LTST_Commit("Ctrl+P", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule), "a completed rollback must permit the next edit")
	_LTST_AssertEvents(["^p Off", "write", "^p On", "^l Off"],
		"the first post-recovery edit must complete normally")
	_LTST_Fire("^l")
	_LTST_Fire("^p")
	AssertEqual(1, _LTST_LlmCalls)
}

_LTST_RollbackWriteFailure() {
	return _LTST_WithFixture(_LTST_RollbackWriteFailureCore)
}
Test("[llm-trigger-tx] failed reverse write exposes durable recovery "
	. "(llm-trigger-rollback-retry)",
	_LTST_RollbackWriteFailure)

_LTST_RollbackRecoveryRetiresRetainedCandidateCore() {
	global _LTST_Events, _LLM_Menu_TriggerRecovery
	global LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	_LTST_SeedOld()
	Candidate := _HotkeyRegistrarReserveOwned("Ctrl+N", _LTST_LlmCallback,
		"llm:trigger", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(Candidate != "")
	State := Map(
		"old_string", "Ctrl+L",
		"recovery_handles", [Candidate])
	_LLM_Menu_PublishTriggerRecovery(LLM_TRIGGER_STATUS_ROLLBACK_PENDING,
		[Candidate])
	AssertTrue(_LLM_Menu_InstallTriggerRecovery("rollback", State,
		_LTST_Writer, _LTST_Hotkey, _LTST_Schedule, _LTST_Refresh))

	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled(),
		"a successful durable retry must finish every retained obligation")
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual("", HotkeyRegistrarChordOf(Candidate),
		"rollback completion must not erase the record before retiring its handle")
	Replacement := _HotkeyRegistrarReserveOwned("Ctrl+N", _LTST_LlmCallback,
		"llm:trigger:replacement", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(Replacement != "",
		"the recovered chord must be immediately reservable by a new owner")
	AssertTrue(_HotkeyRegistrarAbort(Replacement))
	_LTST_AssertEvents(["write", "refresh", "^n Off"],
		"rollback recovery must retire its handle before clearing the warning")
}

_LTST_RollbackRecoveryRetiresRetainedCandidate() {
	return _LTST_WithFixture(
		_LTST_RollbackRecoveryRetiresRetainedCandidateCore)
}
Test("[llm-trigger-tx] rollback retry retires retained candidate",
	_LTST_RollbackRecoveryRetiresRetainedCandidate)

_LTST_OldOffFailureCore() {
	global _LTST_FailOldOff, _LTST_WriteCalls, _LTST_LlmCalls
	global _LLM_Menu, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING, LLM_TRIGGER_STATUS_ACTIVE
	global _LTST_Events, _LTST_NotifyCalls, _LTST_NotifyLeaseReacquired
	global _LTST_AppDeliveries, _LTST_RefreshLeaseReacquired
	_LTST_SeedOld()
	OldHandle := _LLM_Menu_TriggerHandle
	_LTST_FailOldOff := true
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertEqual("Ctrl+N", _LLM_Menu["trigger_shortcut"])
	AssertEqual("^n", _LLM_Menu_TriggerAhk)
	AssertTrue(_LLM_Menu_TriggerHandle != "")
	AssertEqual(LLM_TRIGGER_STATUS_CLEANUP_PENDING, _LLM_Menu_TriggerStatus)
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertEqual(OldHandle, _LLM_Menu_TriggerRecoveryHandles[1])
	AssertEqual(1, InStr(LLM_Menu_TriggerDisplayValue(), Chr(0x26A0)))
	_LTST_Fire("^l")
	_LTST_Fire("^n")
	AssertEqual(2, _LTST_LlmCalls,
		"exception-before-mutation Off leaves both tracked callbacks live")
	_LTST_AssertEvents(["^n Off", "write", "^n On", "^l Off", "schedule", "notify"],
		"cleanup refusal must publish forward authority plus the old handle")
	AssertEqual(1, _LTST_NotifyCalls)
	AssertEqual(1, _LTST_NotifyLeaseReacquired)

	_LTST_FailOldOff := false
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled(),
		"cleanup recovery must retire the old exception-atomic handle")
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertFalse(LLM_Menu_TriggerNeedsAttention())
	AssertEqual(1, _LTST_RefreshLeaseReacquired,
		"cleanup refresh must run after the recovery lease is released")
	_LTST_AssertEvents(["^l Off", "refresh"],
		"cleanup recovery must retire the old handle, then clear the tray warning")
	_LTST_Fire("^l")
	_LTST_Fire("^n")
	AssertEqual(3, _LTST_LlmCalls,
		"the recovered old chord must stop firing while the candidate remains live")
	AssertEqual(1, _LTST_AppDeliveries)

	_LTST_Events := []
	AssertTrue(_LTST_Commit("Ctrl+P", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule), "cleanup completion must permit the next edit")
	_LTST_AssertEvents(["^p Off", "write", "^p On", "^n Off"],
		"the next edit must replace the recovered primary normally")
}

_LTST_OldOffFailure() {
	return _LTST_WithFixture(_LTST_OldOffFailureCore)
}
Test("[llm-trigger-tx] old-Off failure retains both live handles",
	_LTST_OldOffFailure)

_LTST_ClearOldOffFailureCore() {
	global _LTST_FailOldOff, _LTST_LlmCalls
	global _LLM_Menu, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING, LLM_TRIGGER_STATUS_INACTIVE
	global _LTST_Events
	_LTST_SeedOld()
	OldHandle := _LLM_Menu_TriggerHandle
	_LTST_FailOldOff := true
	AssertFalse(_LTST_Commit("", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertEqual("", _LLM_Menu["trigger_shortcut"])
	AssertEqual("", _LLM_Menu_TriggerHandle)
	AssertEqual("", _LLM_Menu_TriggerAhk)
	AssertEqual(LLM_TRIGGER_STATUS_CLEANUP_PENDING, _LLM_Menu_TriggerStatus)
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertEqual(OldHandle, _LLM_Menu_TriggerRecoveryHandles[1])
	_LTST_Fire("^l")
	AssertEqual(1, _LTST_LlmCalls)
	_LTST_AssertEvents(["write", "^l Off", "schedule", "notify"],
		"a refused clear must retain the still-live old handle")
	_LTST_FailOldOff := false
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled())
	AssertEqual(LLM_TRIGGER_STATUS_INACTIVE, _LLM_Menu_TriggerStatus)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	_LTST_AssertEvents(["^l Off", "refresh"],
		"clear recovery must retire the retained callback and rebuild its row")
	_LTST_Fire("^l")
	AssertEqual(1, _LTST_LlmCalls,
		"the cleared shortcut must no longer fire after recovery")
}

_LTST_ClearOldOffFailure() {
	return _LTST_WithFixture(_LTST_ClearOldOffFailureCore)
}
Test("[llm-trigger-tx] clear old-Off failure keeps a recovery handle",
	_LTST_ClearOldOffFailure)

_LTST_StaleCompensationCore() {
	global _LTST_RetireCandidateDuringWrite
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_ACTIVE
	global _LTST_Events
	_LTST_SeedOld()
	_LTST_RetireCandidateDuringWrite := true
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus)
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length,
		"a refused Abort must retain the exact opaque candidate token")
	AssertTrue(LLM_Menu_TriggerNeedsAttention())
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled(),
		"an already-retired stale token must be a terminal cleanup outcome")
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	AssertEqual(0, _LLM_Menu_TriggerRecoveryHandles.Length)
	_LTST_AssertEvents(["refresh"],
		"stale compensation recovery must clear its warning without native I/O")
}

_LTST_StaleCompensation() {
	return _LTST_WithFixture(_LTST_StaleCompensationCore, false)
}
Test("[llm-trigger-tx] refused compensation never loses its handle",
	_LTST_StaleCompensation)

_LTST_InvalidRawCore() {
	global _LTST_WriteCalls, _LTST_NotifyCalls, _LTST_NotifyLeaseReacquired
	_LTST_SeedOld()
	AssertFalse(_LTST_Commit("crtl+n", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback))
	AssertEqual(0, _LTST_WriteCalls)
	AssertEqual(1, _LTST_NotifyCalls)
	AssertEqual(1, _LTST_NotifyLeaseReacquired,
		"invalid grammar must notify only after the builder lease is free")
	_LTST_AssertEvents(["notify"],
		"malformed input must stop before mutation and report exactly once")
}

_LTST_InvalidRaw() {
	return _LTST_WithFixture(_LTST_InvalidRawCore)
}
Test("[llm-trigger-tx] malformed raw input has zero side effects",
	_LTST_InvalidRaw)

_LTST_BootCollisionNoticeCore() {
	global _LTST_Events, _LTST_NotifyCalls, _LTST_NotifyLeaseReacquired
	global _LTST_ForeignCalls, _LLM_Menu_TriggerStatus
	global LLM_TRIGGER_STATUS_ERROR
	ForeignHandle := _HotkeyRegistrarBindOwned("Ctrl+N", _LTST_ForeignCallback,
		"metrics:typing", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(ForeignHandle != "")
	_LTST_Events := []
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+N", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+N", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertEqual(LLM_TRIGGER_STATUS_ERROR, _LLM_Menu_TriggerStatus)
	AssertEqual(1, _LTST_NotifyCalls,
		"repeated menu rebuilds must emit one non-modal failure notice")
	AssertEqual(1, _LTST_NotifyLeaseReacquired)
	_LTST_AssertEvents(["notify"],
		"boot collision reporting must not mutate the foreign native owner")
	_LTST_Fire("^n")
	AssertEqual(1, _LTST_ForeignCalls)
}

_LTST_BootCollisionNotice() {
	return _LTST_WithFixture(_LTST_BootCollisionNoticeCore)
}
Test("[llm-trigger-tx] boot collision notifies once and preserves the owner",
	_LTST_BootCollisionNotice)

_LTST_NotifierRefusalRetriesCore() {
	global _LTST_NotifyOk, _LTST_NotifyCalls, _LTST_Events
	ForeignHandle := _HotkeyRegistrarBindOwned("Ctrl+N", _LTST_ForeignCallback,
		"metrics:typing", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(ForeignHandle != "")
	_LTST_Events := []
	_LTST_NotifyOk := false
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+N", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertEqual(1, _LTST_NotifyCalls)
	_LTST_NotifyOk := true
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+N", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertEqual(2, _LTST_NotifyCalls,
		"a refused notifier result must leave the warning eligible for retry")
	AssertFalse(LLM_Menu_ApplyTriggerShortcut("Ctrl+N", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertEqual(2, _LTST_NotifyCalls,
		"a delivered notice must deduplicate later identical rebuilds")
	_LTST_AssertEvents(["notify", "notify"],
		"notification ownership must publish only after acknowledged delivery")
}

_LTST_NotifierRefusalRetries() {
	return _LTST_WithFixture(_LTST_NotifierRefusalRetriesCore)
}
Test("[llm-trigger-tx] refused notifier delivery stays retryable",
	_LTST_NotifierRefusalRetries)

_LTST_SchedulerRefusalCore() {
	global _LTST_FailNewOn, _LTST_RollbackWriteOk, _LTST_ScheduleOk
	global _LTST_RecoveryCalls, _LTST_Scheduled, _LTST_Events
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerStatus
	global LLM_TRIGGER_STATUS_ROLLBACK_PENDING, LLM_TRIGGER_STATUS_ACTIVE
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	_LTST_RollbackWriteOk := false
	_LTST_ScheduleOk := false
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertTrue(_LLM_Menu_TriggerRecovery is Map,
		"a refused wake-up must not discard the retained recovery record")
	AssertFalse(_LLM_Menu_TriggerRecovery["scheduled"])
	AssertEqual(LLM_TRIGGER_STATUS_ROLLBACK_PENDING,
		_LLM_Menu_TriggerStatus)
	AssertEqual(1, _LTST_RecoveryCalls)
	AssertEqual(0, _LTST_Scheduled.Length)
	_LTST_AssertEvents(["^n Off", "write", "^n On", "write", "schedule", "notify"],
		"scheduler refusal must remain a visible retained failure")

	_LTST_FailNewOn := false
	_LTST_RollbackWriteOk := true
	_LTST_ScheduleOk := true
	_LTST_Events := []
	AssertTrue(_LTST_Commit("Ctrl+P", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh),
		"the next explicit edit must recover even though no timer was armed")
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	_LTST_AssertEvents(["write", "refresh", "^p Off", "write", "^p On", "^l Off"],
		"the edit must repair durability before reserving its candidate")
}

_LTST_SchedulerRefusal() {
	return _LTST_WithFixture(_LTST_SchedulerRefusalCore)
}
Test("[llm-trigger-tx] scheduler refusal is retried by the next edit",
	_LTST_SchedulerRefusal)

_LTST_SchedulerExceptionCore() {
	global _LTST_FailNewOn, _LTST_RollbackWriteOk, _LTST_ScheduleThrows
	global _LTST_RecoveryCalls, _LTST_Scheduled, _LTST_Events
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerStatus
	global LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	_LTST_RollbackWriteOk := false
	_LTST_ScheduleThrows := true
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertTrue(_LLM_Menu_TriggerRecovery is Map,
		"a throwing wake-up must not discard the retained recovery record")
	AssertFalse(_LLM_Menu_TriggerRecovery["scheduled"],
		"a scheduler exception must release timer ownership for watchdog retry")
	AssertEqual(LLM_TRIGGER_STATUS_ROLLBACK_PENDING,
		_LLM_Menu_TriggerStatus)
	AssertEqual(1, _LTST_RecoveryCalls)
	AssertEqual(0, _LTST_Scheduled.Length)
	_LTST_AssertEvents(["^n Off", "write", "^n On", "write", "schedule", "notify"],
		"scheduler exceptions must normalize to the same visible retained failure")
}

_LTST_SchedulerException() {
	return _LTST_WithFixture(_LTST_SchedulerExceptionCore)
}
Test("[llm-trigger-tx] scheduler exception retains watchdog recovery",
	_LTST_SchedulerException)

_LTST_DirectRecoveryClaimExcludesWatchdogCore() {
	global _LTST_FailNewOn, _LTST_RollbackWriteOk, _LTST_ScheduleOk
	global _LTST_RecoveryCalls, _LTST_Scheduled, _LTST_WriteCalls
	global _LTST_Events, _LLM_Menu_TriggerRecovery
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	_LTST_RollbackWriteOk := false
	_LTST_ScheduleOk := false
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertTrue(_LLM_Menu_TriggerRecovery is Map)
	AssertFalse(_LLM_Menu_TriggerRecovery["scheduled"])
	AssertFalse(_LLM_Menu_TriggerRecovery["running"])

	_LTST_FailNewOn := false
	_LTST_RollbackWriteOk := true
	_LTST_ScheduleOk := true
	_LTST_Events := []
	WritesBeforeClaim := _LTST_WriteCalls
	SchedulesBeforeClaim := _LTST_RecoveryCalls
	Record := _LLM_Menu_ClaimTriggerRecovery(0, false)
	AssertTrue(Record is Map,
		"the direct path must atomically claim an unscheduled record")
	AssertTrue(Record["running"])
	AssertTrue(LLM_Menu_ServiceTriggerRecovery(),
		"watchdog service must accept an already-owned recovery")
	AssertEqual(SchedulesBeforeClaim, _LTST_RecoveryCalls,
		"watchdog service must not queue behind a direct in-flight owner")
	AssertEqual(0, _LTST_Scheduled.Length)
	AssertTrue(_LLM_Menu_RunClaimedTriggerRecovery(Record))
	AssertEqual(WritesBeforeClaim + 1, _LTST_WriteCalls,
		"the claimed durable recovery must execute exactly once")
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual(SchedulesBeforeClaim, _LTST_RecoveryCalls)
	AssertEqual(0, _LTST_Scheduled.Length,
		"completion must leave no stale same-id timer owner")
	_LTST_AssertEvents(["write", "refresh"],
		"one claimed recovery must own the whole terminal sequence")
}

_LTST_DirectRecoveryClaimExcludesWatchdog() {
	return _LTST_WithFixture(_LTST_DirectRecoveryClaimExcludesWatchdogCore)
}
Test("[llm-trigger-tx] direct recovery claim excludes watchdog scheduling",
	_LTST_DirectRecoveryClaimExcludesWatchdog)

_LTST_RecoveryRetryCapCore() {
	global _LTST_FailNewOn, _LTST_RollbackWriteOk
	global _LTST_RecoveryCalls, _LTST_Scheduled, _LTST_ScheduleDelays
	global _LTST_Events, _LLM_Menu_TriggerRecovery
	global _LLM_Menu_TriggerStatus, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_ACTIVE, LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS
	global LLM_TRIGGER_RECOVERY_DELAY_MS, LLM_TRIGGER_RECOVERY_MAX_DELAY_MS
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	_LTST_RollbackWriteOk := false
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	Runs := 0
	while (_LTST_Scheduled.Length > 0) {
		AssertFalse(_LTST_RunScheduled())
		Runs += 1
		AssertTrue(Runs <= LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS,
			"automatic recovery must not rearm beyond its declared cap")
	}
	AssertEqual(LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS, Runs)
	AssertEqual(LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS, _LTST_RecoveryCalls)
	AssertTrue(_LLM_Menu_TriggerRecovery is Map)
	AssertFalse(_LLM_Menu_TriggerRecovery["scheduled"])
	AssertEqual(LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS,
		_LLM_Menu_TriggerRecovery["attempts"])
	AssertEqual(LLM_TRIGGER_STATUS_ROLLBACK_PENDING,
		_LLM_Menu_TriggerStatus)
	for Attempt, DelayMs in _LTST_ScheduleDelays {
		ExpectedDelay := Min(LLM_TRIGGER_RECOVERY_DELAY_MS
			* (2 ** (Attempt - 1)), LLM_TRIGGER_RECOVERY_MAX_DELAY_MS)
		AssertEqual(ExpectedDelay, DelayMs,
			"automatic recovery must use bounded exponential backoff")
	}

	_LTST_FailNewOn := false
	_LTST_RollbackWriteOk := true
	_LTST_Events := []
	AssertTrue(_LTST_Commit("Ctrl+P", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh),
		"retry exhaustion must retain a user-driven recovery path")
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	_LTST_AssertEvents(["write", "refresh", "^p Off", "write", "^p On", "^l Off"],
		"manual recovery after exhaustion must precede the replacement")
}

_LTST_RecoveryRetryCap() {
	return _LTST_WithFixture(_LTST_RecoveryRetryCapCore)
}
Test("[llm-trigger-tx] automatic recovery is capped without latching edits",
	_LTST_RecoveryRetryCap)

_LTST_SuspendedRecoveryCore() {
	global _LTST_FailNewOn, _LTST_RollbackWriteOk
	global _LTST_WriteCalls, _LTST_Scheduled, _LTST_Events
	global _LTST_RefreshCalls, _LLM_Menu_TriggerRecovery
	global _LLM_Menu_TriggerStatus, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_ACTIVE
	_LTST_SeedOld()
	_LTST_FailNewOn := true
	_LTST_RollbackWriteOk := false
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	WritesBeforePause := _LTST_WriteCalls
	_LTST_Events := []
	Suspend(1)
	try {
		AssertFalse(_LTST_RunScheduled(),
			"a queued recovery callback must refuse observable work while paused")
		AssertEqual(WritesBeforePause, _LTST_WriteCalls)
		AssertEqual(0, _LTST_RefreshCalls)
		AssertTrue(_LLM_Menu_TriggerRecovery is Map)
		AssertFalse(_LLM_Menu_TriggerRecovery["scheduled"])
		AssertEqual(LLM_TRIGGER_STATUS_ROLLBACK_PENDING,
			_LLM_Menu_TriggerStatus)
		_LTST_AssertEvents([], "suspended recovery must perform no side effect")
	} finally Suspend(0)

	_LTST_FailNewOn := false
	_LTST_RollbackWriteOk := true
	AssertTrue(LLM_Menu_ServiceTriggerRecovery(),
		"resume service must transfer the retained record to one fresh timer")
	AssertEqual(1, _LTST_Scheduled.Length)
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled())
	AssertFalse(_LLM_Menu_TriggerRecovery is Map)
	AssertEqual(LLM_TRIGGER_STATUS_ACTIVE, _LLM_Menu_TriggerStatus)
	_LTST_AssertEvents(["write", "refresh"],
		"resumed recovery must finish durability then refresh once")
}

_LTST_SuspendedRecovery() {
	return _LTST_WithFixture(_LTST_SuspendedRecoveryCore)
}
Test("[llm-trigger-tx] suspended recovery is retained until resume",
	_LTST_SuspendedRecovery)

_LTST_StaleSavedOptsCannotRollbackLiveCore() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedLoaded := _LLM_Menu_Loaded
	HadRaw := _LLM_Menu.Has("trigger_shortcut")
	SavedRaw := _LLM_Menu.Get("trigger_shortcut", "")
	HadPort := _LLM_Menu.Has("ollama_port")
	SavedPort := _LLM_Menu.Get("ollama_port", 0)
	try {
		_LLM_Menu_Loaded := false
		_LLM_Menu["trigger_shortcut"] := "Ctrl+Space"
		_LLM_Menu["ollama_port"] := 11434
		BootSnapshot := Map("trigger_shortcut", "Ctrl+L", "ollama_port", 12000)
		AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(BootSnapshot))
		AssertEqual("Ctrl+L", _LLM_Menu["trigger_shortcut"])
		AssertEqual(12000, _LLM_Menu["ollama_port"])
		; Simulate the first init terminal, then a successful live menu edit.
		_LLM_Menu_Loaded := true
		_LLM_Menu["trigger_shortcut"] := "Ctrl+N"
		_LLM_Menu["ollama_port"] := 13000
		AssertFalse(_LLM_Menu_RestoreSavedOptsOnce(BootSnapshot),
			"a root tray rebuild must not replay its stale boot snapshot")
		AssertEqual("Ctrl+N", _LLM_Menu["trigger_shortcut"])
		AssertEqual(13000, _LLM_Menu["ollama_port"],
			"the one-shot guard must protect the whole saved-options class")
	} finally {
		_LLM_Menu_Loaded := SavedLoaded
		if HadRaw
			_LLM_Menu["trigger_shortcut"] := SavedRaw
		else
			_LLM_Menu.Delete("trigger_shortcut")
		if HadPort
			_LLM_Menu["ollama_port"] := SavedPort
		else
			_LLM_Menu.Delete("ollama_port")
	}
}

_LTST_StaleSavedOptsCannotRollbackLive() {
	return _LTST_WithFixture(_LTST_StaleSavedOptsCannotRollbackLiveCore)
}
Test("[llm-trigger-tx] tray rebuild cannot replay stale boot options",
	_LTST_StaleSavedOptsCannotRollbackLive)

_LTST_EmptyReplayClearsExistingHandleCore() {
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LTST_LlmCalls, _LTST_AppDeliveries
	_LTST_SeedOld()
	AssertTrue(LLM_Menu_ApplyTriggerShortcut("", _LTST_Hotkey,
		_LTST_Probe, _LTST_LlmCallback, _LTST_Schedule, _LTST_Refresh,
		_LTST_Notify))
	AssertEqual("", _LLM_Menu_TriggerHandle)
	AssertEqual("", _LLM_Menu_TriggerAhk)
	_LTST_Fire("^l")
	AssertEqual(0, _LTST_LlmCalls)
	AssertEqual(1, _LTST_AppDeliveries,
		"an empty authoritative replay must retire a stale live callback")
}

_LTST_EmptyReplayClearsExistingHandle() {
	return _LTST_WithFixture(_LTST_EmptyReplayClearsExistingHandleCore)
}
Test("[llm-trigger-tx] empty replay retires an existing trigger handle",
	_LTST_EmptyReplayClearsExistingHandle)





; ============================================
; ============================================
; ======= 3/ Process-Death Regressions =======
; ============================================
; ============================================

_LTST_MutatingWriterCrashRecoveryCore() {
	global _LTST_WriteOk, _LTST_RollbackWriteOk
	global _LTST_MutateRefusedCalls, _LTST_DurableValue
	global _LTST_JournalFiles, _LTST_JournalPath
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerRecoveryHandles
	_LTST_SeedOld()
	_LTST_WriteOk := false
	_LTST_RollbackWriteOk := false
	_LTST_MutateRefusedCalls[1] := true
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertEqual("Ctrl+N", _LTST_DurableValue,
		"the injected writer mutates before returning its refusal")
	AssertTrue(_LTST_JournalFiles.Has(_LTST_JournalPath),
		"ambiguous durability must retain the stable pending record")
	Pending := _LLM_TriggerJournalParse(_LTST_JournalFiles[_LTST_JournalPath])
	AssertTrue(Pending is Map)
	AssertEqual("pending", Pending["phase"])

	; Native handles and timers disappear with the process. Only the stable WAL
	; is allowed to carry authority into the replacement process.
	_LLM_Menu_TriggerRecovery := false
	_LLM_Menu_TriggerRecoveryHandles := []
	_LTST_RollbackWriteOk := true
	AssertTrue(LLM_TriggerJournalRecoverAtBoot(_LTST_JournalPort(),
		_LTST_ReadTrigger, _LTST_Writer, _LTST_JournalPath))
	AssertEqual("Ctrl+L", _LTST_DurableValue)
	AssertFalse(_LTST_JournalFiles.Has(_LTST_JournalPath))
}

_LTST_MutatingWriterCrashRecovery() {
	return _LTST_WithFixture(_LTST_MutatingWriterCrashRecoveryCore)
}
Test("[llm-trigger-wal] process restart repairs a mutating writer refusal",
	_LTST_MutatingWriterCrashRecovery)

_LTST_CommittedNewPromotionFailureCore() {
	global _LTW_JournalPath, _LTW_Files
	global _LTST_DurableValue, _LTST_Native
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	_LTST_SeedOld()
	_LTW_Reset()
	; pending succeeds, committed_new fails, committed_old compensation succeeds.
	_LTW_Queue("move_replace", 1, 0, 1)
	AssertFalse(LLM_Menu_CommitTriggerShortcut("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh, _LTW_Port(), _LTST_ReadTrigger,
		_LTW_JournalPath))
	AssertEqual("Ctrl+L", _LTST_DurableValue,
		"failed commit-marker publication must restore durable old authority")
	AssertTrue(HOTKEY_REGISTRAR_SPECS.Has("^n"),
		"the registrar retains a native-Off tombstone for safe spec reuse")
	Candidate := HOTKEY_REGISTRAR_SPECS["^n"]
	AssertEqual("retired", Candidate["state"]["phase"],
		"a candidate whose commit marker failed must be aborted before activation")
	AssertFalse(HOTKEY_REGISTRAR_BINDINGS.Has(Candidate["handle"]))
	AssertTrue(_LTST_Native.Has("^n"))
	AssertFalse(_LTST_Native["^n"].enabled)
	AssertTrue(_LTW_Files.Has(_LTW_JournalPath))
	Terminal := _LLM_TriggerJournalParse(_LTW_Files[_LTW_JournalPath])
	AssertTrue(Terminal is Map)
	AssertEqual("committed_old", Terminal["phase"])
	_LTST_AssertEvents(["^n Off", "write", "write", "notify"],
		"marker refusal must rollback durability without ever activating native")
	AssertTrue(LLM_TriggerJournalRecoverAtBoot(_LTW_Port(),
		_LTST_ReadTrigger, _LTST_Writer, _LTW_JournalPath))
	AssertFalse(_LTW_Files.Has(_LTW_JournalPath))
}

_LTST_CommittedNewPromotionFailure() {
	return _LTST_WithFixture(_LTST_CommittedNewPromotionFailureCore)
}
Test("[llm-trigger-wal] failed committed-new marker never activates candidate",
	_LTST_CommittedNewPromotionFailure)

_LTST_SeedCommittedNewRollbackRecovery() {
	global ConfigurationFile, _LTST_JournalPath
	global _LTST_DurablePresent, _LTST_DurableValue, _LTST_Events
	global LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	Candidate := _HotkeyRegistrarReserveOwned("Ctrl+N", _LTST_LlmCallback,
		"llm:trigger", _LTST_Hotkey, _LTST_Probe)
	AssertTrue(Candidate != "")
	AssertTrue(_HotkeyRegistrarActivate(Candidate, _LTST_Hotkey))
	_LTST_DurablePresent := 1
	_LTST_DurableValue := "Ctrl+N"
	JournalRecord := _LLM_TriggerJournalNewRecord(ConfigurationFile,
		Map("ok", 1, "present", 1, "value", "Ctrl+L"), "Ctrl+N")
	AssertTrue(JournalRecord is Map)
	JournalRecord["phase"] := "committed_new"
	JournalPort := _LTST_JournalPort()
	AssertTrue(_LLM_TriggerJournalPublish(JournalRecord, JournalPort,
		_LTST_JournalPath))
	State := Map(
		"old_string", "Ctrl+L",
		"recovery_handles", [Candidate],
		"journal_port", JournalPort,
		"journal_read", _LTST_ReadTrigger,
		"journal_path", _LTST_JournalPath,
		"journal_record", JournalRecord)
	_LLM_Menu_PublishTriggerRecovery(LLM_TRIGGER_STATUS_ROLLBACK_PENDING,
		[Candidate])
	AssertTrue(_LLM_Menu_InstallTriggerRecovery("journal_rollback", State,
		_LTST_Writer, _LTST_Hotkey, _LTST_Schedule, _LTST_Refresh))
	_LTST_Events := []
	return Candidate
}

_LTST_JournalRetryRetiresBeforeDurableRollbackCore() {
	global _LTST_DurableValue, _LTST_FailNewOff
	global _LTST_Events
	global _LLM_Menu_TriggerRecoveryHandles
	_LTST_SeedOld()
	_LTW_Reset()
	_LTST_SeedCommittedNewRollbackRecovery()
	_LTST_FailNewOff := true
	AssertEqual("Ctrl+N", _LTST_DurableValue)
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length)
	AssertFalse(_LTST_RunScheduled())
	AssertEqual("Ctrl+N", _LTST_DurableValue,
		"a refused native-Off must leave committed-new durability untouched")
	_LTST_AssertEvents(["^n Off", "schedule"],
		"a refused native-Off must stop before the durable writer")

	_LTST_FailNewOff := false
	_LTST_Events := []
	AssertTrue(_LTST_RunScheduled())
	AssertEqual("Ctrl+L", _LTST_DurableValue)
	_LTST_AssertEvents(["^n Off", "write", "refresh"],
		"recovery must suppress the active candidate before restoring old durability")
}

_LTST_JournalRetryRetiresBeforeDurableRollback() {
	return _LTST_WithFixture(
		_LTST_JournalRetryRetiresBeforeDurableRollbackCore)
}
Test("[llm-trigger-wal] retry retires active candidate before durable rollback "
	. "(llm-trigger-journal-retry-order)",
	_LTST_JournalRetryRetiresBeforeDurableRollback)

_LTST_LifecycleQuiesceRetiresBeforeWalDrainCore() {
	global ConfigurationFile, _LTW_JournalPath
	global _LTST_DurableValue, _LTST_FailNewOff
	global _LTST_Events
	global _LLM_Menu_TriggerRecoveryHandles
	_LTST_SeedOld()
	_LTW_Reset()
	_LTST_SeedCommittedNewRollbackRecovery()
	_LTST_FailNewOff := true
	AssertEqual("Ctrl+N", _LTST_DurableValue)
	AssertEqual(1, _LLM_Menu_TriggerRecoveryHandles.Length)

	OwnerToken := _ConfigWriteLeaseTryAcquire(ConfigurationFile,
		"llm-test-lifecycle")
	AssertTrue(OwnerToken is Object)
	try {
		_LTST_Events := []
		AssertFalse(LLM_Menu_QuiesceTriggerForLifecycle(OwnerToken,
			_LTW_Port(), _LTST_ReadTrigger, _LTST_Writer,
			_LTW_JournalPath))
		AssertEqual("Ctrl+N", _LTST_DurableValue,
			"a refused native-Off must prevent lifecycle disk rollback")
		_LTST_AssertEvents(["^n Off", "schedule"],
			"lifecycle quiescence must stop before touching durable authority")

		_LTST_FailNewOff := false
		_LTST_Events := []
		AssertTrue(LLM_Menu_QuiesceTriggerForLifecycle(OwnerToken,
			_LTW_Port(), _LTST_ReadTrigger, _LTST_Writer,
			_LTW_JournalPath))
		AssertEqual("Ctrl+L", _LTST_DurableValue)
		_LTST_AssertEvents(["^n Off", "write"],
			"lifecycle quiescence must retire native before WAL rollback")
	} finally _ConfigWriteLeaseRelease(OwnerToken)
}

_LTST_LifecycleQuiesceRetiresBeforeWalDrain() {
	return _LTST_WithFixture(
		_LTST_LifecycleQuiesceRetiresBeforeWalDrainCore)
}
Test("[llm-trigger-wal] lifecycle quiesces native authority before WAL drain "
	. "(llm-trigger-lifecycle-drain-order)",
	_LTST_LifecycleQuiesceRetiresBeforeWalDrain)

_LTST_QuarantinedJournalRefusesEditWithoutRecoveryTimerCore() {
	global _LTST_JournalFiles, _LTST_JournalPath
	global _LTST_WriteCalls, _LTST_RecoveryCalls, _LTST_Scheduled
	global _LTST_DurableValue
	_LTST_SeedOld()
	_LTST_JournalFiles[_LTST_JournalPath] := "malformed"
	AssertFalse(_LTST_Commit("Ctrl+N", _LTST_Writer,
		_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
		_LTST_Schedule, _LTST_Refresh))
	AssertTrue(LLM_TriggerJournalIsReadOnly())
	AssertTrue(LLM_Menu_TriggerNeedsAttention(),
		"the menu must expose preserved authority that blocks edits")
	AssertEqual("Ctrl+L", _LTST_DurableValue)
	AssertEqual(0, _LTST_WriteCalls)
	AssertEqual(0, _LTST_RecoveryCalls,
		"a stable malformed artifact must not create an infinite timer retry")
	AssertEqual(0, _LTST_Scheduled.Length)
}

_LTST_QuarantinedJournalRefusesEditWithoutRecoveryTimer() {
	try return _LTST_WithFixture(
		_LTST_QuarantinedJournalRefusesEditWithoutRecoveryTimerCore)
	finally _LLM_TriggerJournalClearReadOnly()
}
Test("[llm-trigger-wal] quarantined edit is loud without an infinite retry "
	. "(llm-trigger-wal-readonly-edit)",
	_LTST_QuarantinedJournalRefusesEditWithoutRecoveryTimer)

_LTST_InheritedCriticalCannotWrapTriggerCommitCore() {
	global _LTST_CriticalStates
	_LTST_SeedOld()
	_LTST_CriticalStates := []
	PreviousCritical := Critical("On")
	try {
		AssertTrue(_LTST_Commit("Ctrl+N", _LTST_Writer,
			_LTST_Notify, _LTST_Hotkey, _LTST_Probe, _LTST_LlmCallback,
			_LTST_Schedule, _LTST_Refresh))
		AssertTrue(A_IsCritical,
			"the trigger action must restore its caller's Critical state")
	} finally Critical(PreviousCritical)
	_LTST_AssertCriticalStates(["journal_read", "journal_write",
		"journal_move", "config_read", "config_write", "hotkey", "probe"],
		"trigger persistence and native registration must remain interruptible")
}

_LTST_InheritedCriticalCannotWrapTriggerCommit() {
	return _LTST_WithFixture(_LTST_InheritedCriticalCannotWrapTriggerCommitCore)
}
Test("[llm-trigger-tx] inherited Critical cannot wrap WAL config or Hotkey adapters "
	. "(llm-trigger-inherited-critical)",
	_LTST_InheritedCriticalCannotWrapTriggerCommit)

_LTST_InheritedCriticalCannotWrapRecoveryCore() {
	global _LTST_CriticalStates
	_LTST_SeedOld()
	_LTW_Reset()
	_LTST_SeedCommittedNewRollbackRecovery()
	_LTST_CriticalStates := []
	PreviousCritical := Critical("On")
	try {
		AssertTrue(_LTST_RunScheduled())
		AssertTrue(A_IsCritical,
			"the recovery timer must restore its caller's Critical state")
	} finally Critical(PreviousCritical)
	_LTST_AssertCriticalStates(["hotkey", "config_read", "config_write",
		"journal_write", "journal_move", "refresh"],
		"recovery adapters and UI refresh must remain interruptible")
}

_LTST_InheritedCriticalCannotWrapRecovery() {
	return _LTST_WithFixture(_LTST_InheritedCriticalCannotWrapRecoveryCore)
}
Test("[llm-trigger-wal] inherited Critical cannot wrap recovery IO or refresh "
	. "(llm-trigger-recovery-inherited-critical)",
	_LTST_InheritedCriticalCannotWrapRecovery)
