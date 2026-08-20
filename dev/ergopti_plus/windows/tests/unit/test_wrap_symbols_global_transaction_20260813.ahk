; tests/unit/test_wrap_symbols_global_transaction_20260813.ahk

; ==============================================================================
; MODULE: Wrap-symbol global persistence transaction regression
; DESCRIPTION:
; Drives the real wrap-symbol mutation gateway and its tray callback through
; injected stage, replace, cleanup and rebuild seams. The tests pin process-wide
; terminal admission, detached candidates, post-stage authorization, strict
; adapter statuses, unreadable-state protection and publication ordering.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../ui/menu/menu_shortcuts.ahk

global _WSGT20260813_WriterCalls := 0
global _WSGT20260813_ReplaceCalls := 0
global _WSGT20260813_DeleteCalls := 0
global _WSGT20260813_RebuildCalls := 0
global _WSGT20260813_OwnerReleaseStatus := false
global _WSGT20260813_StagePaths := []
global _WSGT20260813_Contents := []
global _WSGT20260813_Events := []
global _WSGT20260813_ObservedLive := []
global _WSGT20260813_CriticalStates := []

_WSGT20260813_ResetSeams() {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_DeleteCalls, _WSGT20260813_RebuildCalls
	global _WSGT20260813_OwnerReleaseStatus, _WSGT20260813_StagePaths
	global _WSGT20260813_Contents, _WSGT20260813_Events
	global _WSGT20260813_ObservedLive, _WSGT20260813_CriticalStates
	_WSGT20260813_WriterCalls := 0
	_WSGT20260813_ReplaceCalls := 0
	_WSGT20260813_DeleteCalls := 0
	_WSGT20260813_RebuildCalls := 0
	_WSGT20260813_OwnerReleaseStatus := false
	_WSGT20260813_StagePaths := []
	_WSGT20260813_Contents := []
	_WSGT20260813_Events := []
	_WSGT20260813_ObservedLive := []
	_WSGT20260813_CriticalStates := []
}

_WSGT20260813_RecordCritical(Phase) {
	global _WSGT20260813_CriticalStates
	_WSGT20260813_CriticalStates.Push(Map(
		"phase", Phase,
		"critical", A_IsCritical))
}

_WSGT20260813_RecordLive(Phase) {
	global _WS_Disabled, _WS_ACTIVE_PAIRS, _WSGT20260813_ObservedLive
	_WSGT20260813_ObservedLive.Push(Map(
		"phase", Phase,
		"disabled", _WS_Disabled.Has("("),
		"active", _WS_ACTIVE_PAIRS.Has("(")))
}

_WSGT20260813_WriteSuccess(StagePath, Content) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_StagePaths
	global _WSGT20260813_Contents, _WSGT20260813_Events
	_WSGT20260813_WriterCalls += 1
	_WSGT20260813_StagePaths.Push(StagePath)
	_WSGT20260813_Contents.Push(Content)
	_WSGT20260813_Events.Push("write")
	_WSGT20260813_RecordCritical("write")
	_WSGT20260813_RecordLive("write")
	return 1
}

_WSGT20260813_WriteRefused(StagePath, Content) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_StagePaths
	global _WSGT20260813_Contents, _WSGT20260813_Events
	_WSGT20260813_WriterCalls += 1
	_WSGT20260813_StagePaths.Push(StagePath)
	_WSGT20260813_Contents.Push(Content)
	_WSGT20260813_Events.Push("write-refused")
	_WSGT20260813_RecordLive("write-refused")
	return false
}

_WSGT20260813_WriteStringOne(StagePath, Content) {
	global _WSGT20260813_WriterCalls
	_WSGT20260813_WriterCalls += 1
	return "1"
}

_WSGT20260813_WriteAdvanceEpoch(StagePath, Content) {
	global _WS_StateEpoch
	Status := _WSGT20260813_WriteSuccess(StagePath, Content)
	_WS_StateEpoch += 1
	return Status
}

_WSGT20260813_WriteReleaseOwner(StagePath, Content) {
	global _WS_Config_Path, _WSGT20260813_OwnerReleaseStatus
	Status := _WSGT20260813_WriteSuccess(StagePath, Content)
	Owner := _ConfigWriteLeaseCurrent(_WS_Config_Path)
	_WSGT20260813_OwnerReleaseStatus := Owner is Object
		? _ConfigWriteLeaseRelease(Owner) : false
	return Status
}

_WSGT20260813_WriteSuspend(StagePath, Content) {
	Status := _WSGT20260813_WriteSuccess(StagePath, Content)
	Suspend(1)
	return Status
}

_WSGT20260813_ReplaceSuccess(StagePath, TargetPath) {
	global _WSGT20260813_ReplaceCalls, _WSGT20260813_Events
	_WSGT20260813_ReplaceCalls += 1
	_WSGT20260813_Events.Push("replace")
	_WSGT20260813_RecordCritical("replace")
	_WSGT20260813_RecordLive("replace")
	return 1
}

_WSGT20260813_ReplaceRefused(StagePath, TargetPath) {
	global _WSGT20260813_ReplaceCalls, _WSGT20260813_Events
	_WSGT20260813_ReplaceCalls += 1
	_WSGT20260813_Events.Push("replace-refused")
	_WSGT20260813_RecordLive("replace-refused")
	return false
}

_WSGT20260813_ReplaceStringOne(StagePath, TargetPath) {
	global _WSGT20260813_ReplaceCalls
	_WSGT20260813_ReplaceCalls += 1
	return "1"
}

_WSGT20260813_DeleteSuccess(StagePath) {
	global _WSGT20260813_DeleteCalls
	_WSGT20260813_DeleteCalls += 1
	return 1
}

_WSGT20260813_DeleteStringOne(StagePath) {
	global _WSGT20260813_DeleteCalls
	_WSGT20260813_DeleteCalls += 1
	return "1"
}

_WSGT20260813_RebuildSuccess() {
	global _WSGT20260813_RebuildCalls, _WSGT20260813_Events
	_WSGT20260813_RebuildCalls += 1
	_WSGT20260813_Events.Push("rebuild")
	_WSGT20260813_RecordCritical("rebuild")
	_WSGT20260813_RecordLive("rebuild")
	return 1
}

_WSGT20260813_LiveIdentity() {
	global _WS_Disabled, _WS_Custom, _WS_ACTIVE_PAIRS
	return {
		disabled: ObjPtr(_WS_Disabled),
		custom: ObjPtr(_WS_Custom),
		active: ObjPtr(_WS_ACTIVE_PAIRS)
	}
}

_WSGT20260813_AssertNoPublication(Before, Context) {
	global _WS_Disabled, _WS_Custom, _WS_ACTIVE_PAIRS
	AssertEqual(Before.disabled, ObjPtr(_WS_Disabled),
		Context . ": disabled state identity changed")
	AssertEqual(Before.custom, ObjPtr(_WS_Custom),
		Context . ": custom state identity changed")
	AssertEqual(Before.active, ObjPtr(_WS_ACTIVE_PAIRS),
		Context . ": active projection identity changed")
}

_WSGT20260813_AssertRefused(Result, Context) {
	AssertTrue((Result is Integer) && Result == 0,
		Context . " must return the exact Integer false status")
}

_WSGT20260813_WithState(TestFn) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed
	global _WS_StateEpoch, _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS
	Saved := {
		config_path: _WS_Config_Path,
		disabled: _WS_Disabled,
		custom: _WS_Custom,
		load_failed: _WS_LoadFailed,
		epoch: _WS_StateEpoch,
		active: _WS_ACTIVE_PAIRS,
		builtins: _WS_BUILTIN_PAIRS
	}
	Path := A_Temp . "\ergopti_wrap_symbols_global_transaction_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	AssertFalse(A_IsSuspended,
		"the wrap-symbol transaction fixture must start unsuspended")
	_WS_Config_Path := Path
	_WS_BUILTIN_PAIRS := [
		Map("left", "(", "right", ")"),
		Map("left", "[", "right", "]")
	]
	_WS_Disabled := Map("[", true)
	_WS_Custom := [Map("left", "a", "right", "b")]
	_WS_LoadFailed := false
	_WS_StateEpoch := 2026081300
	_WS_ACTIVE_PAIRS := _WS_BuildActivePairs(_WS_Disabled, _WS_Custom)
	_WSGT20260813_ResetSeams()
	try TestFn.Call(Path)
	finally {
		if A_IsSuspended
			Suspend(0)
		CurrentOwner := _ConfigWriteLeaseCurrent(Path)
		if CurrentOwner is Object
			_ConfigWriteLeaseRelease(CurrentOwner)
		_WS_Config_Path := Saved.config_path
		_WS_Disabled := Saved.disabled
		_WS_Custom := Saved.custom
		_WS_LoadFailed := Saved.load_failed
		_WS_StateEpoch := Saved.epoch
		_WS_ACTIVE_PAIRS := Saved.active
		_WS_BUILTIN_PAIRS := Saved.builtins
		try FileDelete(Path)
	}
}

_WSGT20260813_TerminalBarrierBody(Path) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	Terminal := _ConfigWriteTerminalTryAcquire(
		Path . ".unrelated-terminal-target")
	AssertTrue(Terminal is Object,
		"the fixture must own the process-wide terminal barrier")
	try Result := _WS_MenuToggle("(", _WSGT20260813_WriteSuccess,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	finally _ConfigWriteTerminalRelease(Terminal)
	_WSGT20260813_AssertRefused(Result,
		"an unrelated terminal barrier refusal")
	AssertEqual(0, _WSGT20260813_WriterCalls,
		"terminal refusal must happen before detached staging")
	AssertEqual(0, _WSGT20260813_ReplaceCalls)
	AssertEqual(0, _WSGT20260813_RebuildCalls,
		"a refused commit must not rebuild the tray")
	_WSGT20260813_AssertNoPublication(Before, "terminal refusal")
}

_WSGT20260813_TerminalBarrier() {
	_WSGT20260813_WithState(_WSGT20260813_TerminalBarrierBody)
}
Test("wrap-symbols-global-transaction-20260813: unrelated terminal barrier refuses before staging and tray rebuild",
	_WSGT20260813_TerminalBarrier)

_WSGT20260813_StageRefusalBody(Path) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_DeleteCalls, _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	Result := _WS_MenuToggle("(", _WSGT20260813_WriteRefused,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(Result, "a refused stage")
	AssertEqual(1, _WSGT20260813_WriterCalls)
	AssertEqual(0, _WSGT20260813_ReplaceCalls,
		"a refused stage must not reach atomic replacement")
	AssertEqual(1, _WSGT20260813_DeleteCalls,
		"a refused stage must attempt private-stage cleanup")
	AssertEqual(0, _WSGT20260813_RebuildCalls,
		"a refused stage must not rebuild the tray")
	_WSGT20260813_AssertNoPublication(Before, "stage refusal")
}

_WSGT20260813_StageRefusal() {
	_WSGT20260813_WithState(_WSGT20260813_StageRefusalBody)
}
Test("wrap-symbols-global-transaction-20260813: stage refusal preserves disk projection RAM and tray",
	_WSGT20260813_StageRefusal)

_WSGT20260813_ReplaceRefusalBody(Path) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_DeleteCalls, _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	Result := _WS_MenuToggle("(", _WSGT20260813_WriteSuccess,
		_WSGT20260813_ReplaceRefused, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(Result, "a refused atomic replace")
	AssertEqual(1, _WSGT20260813_WriterCalls)
	AssertEqual(1, _WSGT20260813_ReplaceCalls)
	AssertEqual(1, _WSGT20260813_DeleteCalls,
		"a refused replacement must clean the private stage")
	AssertEqual(0, _WSGT20260813_RebuildCalls,
		"a refused replacement must not rebuild the tray")
	_WSGT20260813_AssertNoPublication(Before, "replace refusal")
}

_WSGT20260813_ReplaceRefusal() {
	_WSGT20260813_WithState(_WSGT20260813_ReplaceRefusalBody)
}
Test("wrap-symbols-global-transaction-20260813: replace refusal leaves live state and tray untouched",
	_WSGT20260813_ReplaceRefusal)

_WSGT20260813_StrictStatusesBody(Path) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_DeleteCalls, _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	WriterResult := _WS_MenuToggle("(", _WSGT20260813_WriteStringOne,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(WriterResult,
		"a string-lookalike writer status")
	AssertEqual(1, _WSGT20260813_WriterCalls)
	AssertEqual(0, _WSGT20260813_ReplaceCalls)
	AssertEqual(0, _WSGT20260813_RebuildCalls)
	_WSGT20260813_AssertNoPublication(Before,
		"malformed writer status")

	_WSGT20260813_ResetSeams()
	ReplaceResult := _WS_MenuToggle("(", _WSGT20260813_WriteSuccess,
		_WSGT20260813_ReplaceStringOne, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(ReplaceResult,
		"a string-lookalike replace status")
	AssertEqual(1, _WSGT20260813_WriterCalls)
	AssertEqual(1, _WSGT20260813_ReplaceCalls)
	AssertEqual(0, _WSGT20260813_RebuildCalls)
	_WSGT20260813_AssertNoPublication(Before,
		"malformed replace status")

	_WSGT20260813_ResetSeams()
	DeleteResult := _WS_CleanupStage(Path . ".malformed.tmp",
		_WSGT20260813_DeleteStringOne)
	_WSGT20260813_AssertRefused(DeleteResult,
		"a string-lookalike cleanup status")
	AssertEqual(1, _WSGT20260813_DeleteCalls)
	RebuildResult := _WS_MenuRebuildAfterCommit("1",
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(RebuildResult,
		"a string-lookalike commit status")
	AssertEqual(0, _WSGT20260813_RebuildCalls,
		"malformed commit acknowledgement must not rebuild")
}

_WSGT20260813_StrictStatuses() {
	_WSGT20260813_WithState(_WSGT20260813_StrictStatusesBody)
}
Test("wrap-symbols-global-transaction-20260813: every adapter and callback requires exact Integer one",
	_WSGT20260813_StrictStatuses)

_WSGT20260813_EpochRevalidationBody(Path) {
	global _WSGT20260813_ReplaceCalls, _WSGT20260813_DeleteCalls
	global _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	Result := _WS_MenuToggle("(", _WSGT20260813_WriteAdvanceEpoch,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(Result,
		"an epoch advanced while staging")
	AssertEqual(0, _WSGT20260813_ReplaceCalls,
		"stale epoch must be detected before durable replacement")
	AssertEqual(1, _WSGT20260813_DeleteCalls)
	AssertEqual(0, _WSGT20260813_RebuildCalls)
	_WSGT20260813_AssertNoPublication(Before,
		"post-stage epoch invalidation")
}

_WSGT20260813_EpochRevalidation() {
	_WSGT20260813_WithState(_WSGT20260813_EpochRevalidationBody)
}
Test("wrap-symbols-global-transaction-20260813: final authorization rejects a stale state epoch",
	_WSGT20260813_EpochRevalidation)

_WSGT20260813_OwnerRevalidationBody(Path) {
	global _WSGT20260813_OwnerReleaseStatus, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_DeleteCalls, _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	Result := _WS_MenuToggle("(", _WSGT20260813_WriteReleaseOwner,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	AssertTrue((_WSGT20260813_OwnerReleaseStatus is Integer)
		&& _WSGT20260813_OwnerReleaseStatus == 1,
		"the interleave must revoke the exact path owner after staging")
	_WSGT20260813_AssertRefused(Result,
		"an owner revoked while staging")
	AssertEqual(0, _WSGT20260813_ReplaceCalls)
	AssertEqual(1, _WSGT20260813_DeleteCalls)
	AssertEqual(0, _WSGT20260813_RebuildCalls)
	_WSGT20260813_AssertNoPublication(Before,
		"post-stage owner invalidation")
}

_WSGT20260813_OwnerRevalidation() {
	_WSGT20260813_WithState(_WSGT20260813_OwnerRevalidationBody)
}
Test("wrap-symbols-global-transaction-20260813: final authorization rejects a revoked global lease",
	_WSGT20260813_OwnerRevalidation)

_WSGT20260813_SuspendRevalidationBody(Path) {
	global _WSGT20260813_ReplaceCalls, _WSGT20260813_DeleteCalls
	global _WSGT20260813_RebuildCalls
	Before := _WSGT20260813_LiveIdentity()
	try Result := _WS_MenuToggle("(", _WSGT20260813_WriteSuspend,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	finally {
		if A_IsSuspended
			Suspend(0)
	}
	_WSGT20260813_AssertRefused(Result,
		"a suspend transition which landed while staging")
	AssertEqual(0, _WSGT20260813_ReplaceCalls,
		"suspend must be rechecked before durable replacement")
	AssertEqual(1, _WSGT20260813_DeleteCalls)
	AssertEqual(0, _WSGT20260813_RebuildCalls)
	_WSGT20260813_AssertNoPublication(Before,
		"post-stage suspend invalidation")
}

_WSGT20260813_SuspendRevalidation() {
	_WSGT20260813_WithState(_WSGT20260813_SuspendRevalidationBody)
}
Test("wrap-symbols-global-transaction-20260813: suspend after staging refuses replace publication and rebuild",
	_WSGT20260813_SuspendRevalidation)

_WSGT20260813_UnreadableResetBody(Path) {
	global _WS_LoadFailed, _WS_Disabled, _WS_Custom, _WS_ACTIVE_PAIRS
	global _WSGT20260813_WriterCalls, _WSGT20260813_RebuildCalls
	_WS_LoadFailed := true
	Before := _WSGT20260813_LiveIdentity()
	Result := _WS_MenuReset(_WSGT20260813_WriteSuccess,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	_WSGT20260813_AssertRefused(Result,
		"reset while the unreadable-state latch is set")
	AssertEqual(0, _WSGT20260813_WriterCalls,
		"unreadable state must reject reset before candidate staging")
	AssertEqual(0, _WSGT20260813_RebuildCalls)
	AssertTrue(_WS_Disabled.Has("["),
		"reset refusal must preserve disabled symbols")
	AssertEqual(1, _WS_Custom.Length,
		"reset refusal must preserve custom pairs")
	AssertTrue(_WS_ACTIVE_PAIRS.Has("a"),
		"reset refusal must preserve the live active projection")
	_WSGT20260813_AssertNoPublication(Before,
		"unreadable reset refusal")
}

_WSGT20260813_UnreadableReset() {
	_WSGT20260813_WithState(_WSGT20260813_UnreadableResetBody)
}
Test("wrap-symbols-global-transaction-20260813: unreadable latch protects reset and every live projection",
	_WSGT20260813_UnreadableReset)

_WSGT20260813_ExactPublicationBody(Path) {
	global _WS_Disabled, _WS_Custom, _WS_ACTIVE_PAIRS, _WS_StateEpoch
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls
	global _WSGT20260813_RebuildCalls, _WSGT20260813_StagePaths
	global _WSGT20260813_Contents, _WSGT20260813_Events
	global _WSGT20260813_ObservedLive
	Before := _WSGT20260813_LiveIdentity()
	StartEpoch := _WS_StateEpoch
	Result := _WS_MenuToggle("(", _WSGT20260813_WriteSuccess,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	AssertTrue((Result is Integer) && Result == 1,
		"durability plus tray publication must return exact Integer one")
	AssertEqual(1, _WSGT20260813_WriterCalls)
	AssertEqual(1, _WSGT20260813_ReplaceCalls)
	AssertEqual(1, _WSGT20260813_RebuildCalls)
	AssertEqual("write", _WSGT20260813_Events[1])
	AssertEqual("replace", _WSGT20260813_Events[2])
	AssertEqual("rebuild", _WSGT20260813_Events[3])
	AssertFalse(_WSGT20260813_ObservedLive[1]["disabled"],
		"the stage writer must observe only the old live state")
	AssertTrue(_WSGT20260813_ObservedLive[1]["active"])
	AssertFalse(_WSGT20260813_ObservedLive[2]["disabled"],
		"the replacer must run before candidate publication")
	AssertTrue(_WSGT20260813_ObservedLive[2]["active"])
	AssertTrue(_WSGT20260813_ObservedLive[3]["disabled"],
		"the tray rebuild must observe the committed candidate")
	AssertFalse(_WSGT20260813_ObservedLive[3]["active"])
	AssertTrue(_WS_Disabled.Has("("))
	AssertTrue(_WS_Disabled.Has("["))
	AssertEqual(2, _WS_Disabled.Count,
		"the published disabled set must equal the serialized candidate")
	AssertEqual(1, _WS_Custom.Length)
	AssertEqual("a", _WS_Custom[1]["left"])
	AssertEqual("b", _WS_Custom[1]["right"])
	AssertFalse(_WS_ACTIVE_PAIRS.Has("("))
	AssertFalse(_WS_ACTIVE_PAIRS.Has(")"))
	AssertTrue(_WS_ACTIVE_PAIRS.Has("a"))
	AssertTrue(_WS_ACTIVE_PAIRS.Has("b"))
	AssertEqual(StartEpoch + 1, _WS_StateEpoch,
		"one live publication must advance the state epoch exactly once")
	AssertTrue(ObjPtr(_WS_Disabled) != Before.disabled)
	AssertTrue(ObjPtr(_WS_Custom) != Before.custom)
	AssertTrue(ObjPtr(_WS_ACTIVE_PAIRS) != Before.active)
	DisabledNeedle := "char = " . Chr(0x22) . "(" . Chr(0x22)
	AssertTrue(InStr(_WSGT20260813_Contents[1], DisabledNeedle) > 0,
		"the staged TOML must contain the exact value published to RAM")
	AssertTrue(InStr(_WSGT20260813_StagePaths[1], Path . ".") == 1,
		"the private stage must be a same-directory sibling of the target")
	AssertTrue(RegExMatch(_WSGT20260813_StagePaths[1], "\.tmp$") > 0)

	SecondResult := _WS_MenuToggle("(", _WSGT20260813_WriteSuccess,
		_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
		_WSGT20260813_RebuildSuccess)
	AssertTrue((SecondResult is Integer) && SecondResult == 1)
	AssertEqual(2, _WSGT20260813_StagePaths.Length)
	AssertTrue(_WSGT20260813_StagePaths[1]
		!= _WSGT20260813_StagePaths[2],
		"consecutive transactions must never share a staging path")
	AssertFalse(_WS_Disabled.Has("("))
	AssertTrue(_WS_ACTIVE_PAIRS.Has("("))
	AssertFalse(_ConfigWriteLeaseCurrent(Path) is Object,
		"successful publication must release the exact global lease")
}

_WSGT20260813_ExactPublication() {
	_WSGT20260813_WithState(_WSGT20260813_ExactPublicationBody)
}
Test("wrap-symbols-global-transaction-20260813: unique durable stages precede exact RAM and tray publication",
	_WSGT20260813_ExactPublication)

_WSGT20260813_InheritedCriticalBody(Path) {
	global _WSGT20260813_CriticalStates
	PreviousCritical := Critical("On")
	try {
		Result := _WS_MenuToggle("(", _WSGT20260813_WriteSuccess,
			_WSGT20260813_ReplaceSuccess, _WSGT20260813_DeleteSuccess,
			_WSGT20260813_RebuildSuccess)
		AssertTrue(A_IsCritical,
			"the transaction must restore the caller's Critical state")
	} finally Critical(PreviousCritical)
	AssertTrue((Result is Integer) && Result == 1)
	AssertEqual(3, _WSGT20260813_CriticalStates.Length,
		"stage, replace and tray rebuild must all expose their Critical state")
	for Sample in _WSGT20260813_CriticalStates {
		AssertEqual(0, Sample["critical"],
			Sample["phase"] . " must remain interruptible under an inherited caller Critical")
	}
}

_WSGT20260813_InheritedCritical() {
	_WSGT20260813_WithState(_WSGT20260813_InheritedCriticalBody)
}
Test("wrap-symbols-global-transaction-20260813: inherited Critical cannot wrap disk IO or tray rebuild",
	_WSGT20260813_InheritedCritical)
