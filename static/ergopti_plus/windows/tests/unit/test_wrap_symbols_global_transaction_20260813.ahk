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


; Independent provider expectations complement the existing native transaction ports.
; Only declared-menu cases need the actual shared catalogue. The existing
; transaction tests retain their two-pair fixture and every old assertion.
_WSGT20260813_WithControlCatalogue(TestFn, Path) {
	global _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS, _WS_ACTIVE_PAIRS, _WS_Disabled, _WS_Custom
	SavedPairs := _WS_BUILTIN_PAIRS, SavedGroups := _WS_BUILTIN_GROUPS
	SavedActive := _WS_ACTIVE_PAIRS
	try {
		_WS_LoadBuiltinCatalogue()
		Corpus := _WSGT20260813_WrapControlsCorpus()
		AssertEqual(7, Corpus["catalogue_groups"].Length, "the independent corpus describes all seven native groups")
		AssertEqual(Corpus["catalogue_groups"].Length, _WS_BUILTIN_GROUPS.Length,
			"the actual production loader must admit the complete shared catalogue")
		_WS_ACTIVE_PAIRS := _WS_BuildActivePairs(_WS_Disabled, _WS_Custom)
		return TestFn.Call(Path)
	} finally {
		_WS_BUILTIN_PAIRS := SavedPairs
		_WS_BUILTIN_GROUPS := SavedGroups
		_WS_ACTIVE_PAIRS := SavedActive
	}
}

_WSGT20260813_WithControls(TestFn) {
	return _WSGT20260813_WithState((Path) => _WSGT20260813_WithControlCatalogue(TestFn, Path))
}

_WSGT20260813_WrapControlsCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "/tests/corpus/menus/wrap_symbol_controls.json", "UTF-8"))
}

_WSGT20260813_ControlLabelAt(MenuObj, Position) {
	Length := DllCall("GetMenuStringW", "ptr", MenuObj.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", 0x400, "int")
	Label := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", MenuObj.Handle, "uint", Position,
		"ptr", Label.Ptr, "int", Length + 1, "uint", 0x400, "int")
	return StrGet(Label, "UTF-16")
}

_WSGT20260813_ControlDeclarationAndDrawing(Path) {
	global _WS_BUILTIN_GROUPS, _WS_Custom
	Corpus := _WSGT20260813_WrapControlsCorpus()
	Rows := _WS_BuildSymbolRows()
	AssertEqual(4 + Corpus["catalogue_groups"].Length + 1 + _WS_Custom.Length + 2,
		Rows.Length, "complete fixed head, catalogue groups, custom data and tail")
	AssertEqual(t("menu.shortcuts.wrap_symbols_check_all"), Rows[1]["label"])
	AssertEqual(t("menu.shortcuts.wrap_symbols_uncheck_all"), Rows[2]["label"])
	AssertEqual(t("common.restore_recommended"), Rows[3]["label"])
	AssertTrue(Rows[4]["separator"])
	for Index, Expected in Corpus["catalogue_groups"] {
		Group := Rows[Index + 4]
		AssertEqual(t(Expected["i18n"]), Group["label"])
		AssertEqual(t("menu.shortcuts.wrap_symbols_check_all"), Group["items"][1]["label"])
		AssertEqual(t("menu.shortcuts.wrap_symbols_uncheck_all"), Group["items"][2]["label"])
		AssertTrue(Group["items"][3]["separator"])
		AssertEqual(Expected["lefts"].Length + 3, Group["items"].Length)
		for PairIndex, Left in Expected["lefts"]
			AssertEqual(Left, _WS_BUILTIN_GROUPS[Index]["pairs"][PairIndex]["left"], "original shared symbol order")
	}
	AssertTrue(Rows[12]["separator"])
	AssertEqual(t("button.delete"), Rows[13]["items"][1]["label"], "custom delete consumes its declaration")
	AssertTrue(Rows[Rows.Length - 1]["separator"])
	AssertEqual(t("menu.shortcuts.wrap_symbols_add_custom"), Rows[Rows.Length]["label"])
	Rendered := Menu()
	try {
		; Renderer receipts count labelled rows; native separators remain real items.
		AssertEqual(Rows.Length - 3, _MR_RenderRows(Rendered, Rows, "wrap_controls_native_test", 1),
			"actual native owner acknowledges every labelled row")
		AssertEqual(Rows.Length, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"),
			"actual Win32 item count retains all fifteen rows including three separators")
		for Index, Expected in Corpus["catalogue_groups"]
			AssertEqual(t(Expected["i18n"]), _WSGT20260813_ControlLabelAt(Rendered, Index + 3),
				"every actual native catalogue group keeps its independent caption and position")
		AssertTrue(TrayMenuIsSeparatorAt(Rendered, 11), "the native custom separator remains in position")
		AssertTrue(TrayMenuIsSeparatorAt(Rendered, Rows.Length - 2), "the native add-control separator remains in position")
		AssertEqual(Rows[1]["label"], _WSGT20260813_ControlLabelAt(Rendered, 0))
		AssertTrue(TrayMenuIsSeparatorAt(Rendered, 3))
		AssertEqual(Rows[Rows.Length]["label"], _WSGT20260813_ControlLabelAt(Rendered, Rows.Length - 1))
	} finally {
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
	}
}
Test("wrap symbols: actual provider consumes complete declared controls and native drawing (wrap-controls)",
	() => _WSGT20260813_WithControls(_WSGT20260813_ControlDeclarationAndDrawing))

_WSGT20260813_ControlMetadataMutations(Path) {
	Definition := _MR_GetMenuDef("wrap_symbols_global_controls")
	First := Definition[1], Second := Definition[2]
	OriginalKey := First["i18n"], OriginalPlatforms := First["platforms"]
	try {
		First["i18n"] := "button.delete"
		Definition[1] := Second, Definition[2] := First
		Rows := _WS_BuildSymbolRows()
		AssertEqual(t("menu.shortcuts.wrap_symbols_uncheck_all"), Rows[1]["label"])
		AssertEqual(t("button.delete"), Rows[2]["label"], "actual provider reads caption and shared source order")
		First["platforms"] := ["hs"]
		Rows := _WS_BuildSymbolRows()
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"], "only the hidden command retires")
	} finally {
		First["i18n"] := OriginalKey, First["platforms"] := OriginalPlatforms
		Definition[1] := First, Definition[2] := Second
	}
}
Test("wrap symbols: actual provider reads order caption and platform metadata mutations (wrap-controls)",
	() => _WSGT20260813_WithControls(_WSGT20260813_ControlMetadataMutations))

_WSGT20260813_ControlNativeRefusal(Path) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls, _WSGT20260813_RebuildCalls
	Rows := _WS_BuildSymbolRows()
	Before := _WSGT20260813_LiveIdentity()
	Terminal := _ConfigWriteTerminalTryAcquire(Path . ".wrap-control-terminal")
	AssertTrue(Terminal is Object)
	try {
		for Index in [1, 2, 3]
			_WSGT20260813_AssertRefused(Rows[Index]["action"].Call("discarded menu arg", 99), "actual global control")
		for Index in [1, 2]
			_WSGT20260813_AssertRefused(Rows[5]["items"][Index]["action"].Call("discarded menu arg", 99), "captured group control")
		_WSGT20260813_AssertRefused(Rows[13]["items"][1]["action"].Call("discarded menu arg", 99), "captured custom delete")
		_WSGT20260813_AssertNoPublication(Before, "actual provider callbacks under terminal admission refusal")
		AssertFalse(FileExist(Path), "no record can be written by a refused native owner")
		AssertEqual(0, _WSGT20260813_WriterCalls + _WSGT20260813_ReplaceCalls + _WSGT20260813_RebuildCalls)
	} finally _ConfigWriteTerminalRelease(Terminal)
}
Test("wrap symbols: actual declared callbacks retain native admission refusal and Bind payloads (wrap-controls)",
	() => _WSGT20260813_WithControls(_WSGT20260813_ControlNativeRefusal))

_WSGT20260813_ControlMissingOwnership(Path) {
	Corpus := _WSGT20260813_WrapControlsCorpus()
	for Section in Corpus["sections"] {
		Definition := _MR_GetMenuDef(Section["section"])
		if Definition[1]["type"] == "---" {
			OriginalType := Definition[1]["type"]
			try {
				Definition[1]["type"] := "unowned_fixed_control"
				AssertEqual(0, _WS_BuildSymbolRows().Length, "a broken declared section cannot return a partial picker")
			} finally Definition[1]["type"] := OriginalType
		} else {
			OriginalId := Definition[1]["id"]
			try {
				Definition[1]["id"] := "unowned_wrap_command"
				AssertEqual(0, _WS_BuildSymbolRows().Length, "a missing native command refuses the complete picker")
			} finally Definition[1]["id"] := OriginalId
		}
	}
}
Test("wrap symbols: actual provider refuses every broken fixed section without partial rows (wrap-controls)",
	() => _WSGT20260813_WithControls(_WSGT20260813_ControlMissingOwnership))

_WSGT20260813_ControlReadiness(Path) {
	global _WSGT20260813_WriterCalls, _WSGT20260813_ReplaceCalls, _WSGT20260813_RebuildCalls
	Definition := _MR_GetMenuDef("wrap_symbols_global_controls")[1]
	Original := Definition["disabled_when"]
	Rows := _WS_BuildSymbolRows()
	Before := _WSGT20260813_LiveIdentity()
	try {
		Definition["disabled_when"] := ["missing_native_wrap_readiness"]
		Current := _WS_BuildSymbolRows()
		AssertTrue(Current[1]["disabled"], "absent readiness getter refuses drawing eligibility")
		_WSGT20260813_AssertRefused(Rows[1]["action"].Call(), "retained declared callback rechecks current readiness metadata")
		_WSGT20260813_AssertNoPublication(Before, "retained callback cannot bypass current declaration")
		AssertEqual(0, _WSGT20260813_WriterCalls + _WSGT20260813_ReplaceCalls + _WSGT20260813_RebuildCalls)
	} finally Definition["disabled_when"] := Original
}
Test("wrap symbols: retained actual command rechecks declared native readiness (wrap-controls)",
	() => _WSGT20260813_WithControls(_WSGT20260813_ControlReadiness))
