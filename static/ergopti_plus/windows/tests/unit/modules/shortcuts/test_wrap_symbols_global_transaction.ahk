; tests/unit/modules/shortcuts/test_wrap_symbols_global_transaction.ahk

; ==============================================================================
; MODULE: Wrap-symbol global persistence transaction regression
; DESCRIPTION:
; Drives the real wrap-symbol mutation gateway and its tray callback through
; injected stage, replace, cleanup and rebuild seams. The tests pin process-wide
; terminal admission, detached candidates, post-stage authorization, strict
; adapter statuses, unreadable-state protection and publication ordering.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../ui/menu/menu_shortcuts.ahk
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
	return FSWriteDurable(StagePath, Content)
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
	return FSAtomicMoveReplace(StagePath, TargetPath)
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
	return FileExist(StagePath) ? FSDeleteStrict(StagePath) : 1
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
	return _WSSA_WithOwnedSource(_WSGT20260813_WithAdmittedState.Bind(TestFn))
}
_WSGT20260813_WithAdmittedState(TestFn, Root, Path, Source) {
	global _WS_StateEpoch, _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS, _WS_Disabled, _WS_Custom
	; The outer scope already called genuine Init on the physical seed. Keep
	; the historic small catalogue while retaining the actual admitted objects.
	_WS_BUILTIN_PAIRS := [Map("left", "(", "right", ")"), Map("left", "[", "right", "]")]
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

; Reported on v1.0.1: the guillemets could not be changed from the tray. The
; catalogue spells them "« " with their space, and every built-in validator
; required a single character, so the toggle, the Quotes group actions and the
; global "uncheck all" were refused with only a log line.
_WSGT20260813_GuillemetsBody(Path) {
	global _WS_BUILTIN_GROUPS, _WS_Disabled, _WS_Custom, _WSGT20260813_Contents
	Guillemet := Chr(0xAB) . " "
	Group := 0
	for Candidate in _WS_BUILTIN_GROUPS {
		for Pair in Candidate["pairs"] {
			if Pair["left"] == Guillemet
				Group := Candidate
		}
	}
	AssertTrue(IsObject(Group), "the shared catalogue must still spell the guillemets with their space")
	Lefts := []
	for Pair in Group["pairs"]
		Lefts.Push(Pair["left"])
	Seams := [_WSGT20260813_WriteSuccess, _WSGT20260813_ReplaceSuccess,
		_WSGT20260813_DeleteSuccess, _WSGT20260813_RebuildSuccess]

	AssertEqual(1, _WS_MenuToggle(Guillemet, Seams*), "toggling the guillemets must commit")
	AssertTrue(_WS_Disabled.Has(Guillemet))
	AssertFalse(WrapSymbols_IsEnabled(Guillemet))
	AssertEqual(1, _WS_MenuSetGroup(Lefts, true, Seams*), "checking the whole Quotes group must commit")
	AssertFalse(_WS_Disabled.Has(Guillemet))
	AssertEqual(1, _WS_MenuSetGroup(Lefts, false, Seams*), "unchecking the whole Quotes group must commit")
	AssertTrue(_WS_Disabled.Has(Guillemet))
	AssertEqual(1, _WS_MenuSetAll(false, Seams*), "the global uncheck all must commit")
	Content := _WSGT20260813_Contents[_WSGT20260813_Contents.Length]
	AssertTrue(InStr(Content, "char = " . Chr(0x22) . Guillemet . Chr(0x22)) > 0,
		"the staged TOML keeps the exact spaced guillemet")

	; Successful ports performed real I/O. Reload those actual acknowledged
	; bytes rather than appending a second complete serialization to the file.
	AssertEqual(Content, FSReadUtf8Exact(Path))
	SplitPath(Path, &FileName, &Directory)
	AssertTrue(WrapSymbols_Init(Directory . "\"))
	AssertTrue(_WS_Disabled.Has(Guillemet), "a reload keeps the guillemets disabled")
}
Test("wrap symbols: the spaced guillemets toggle, group and global actions commit (wrap-guillemets-length)",
	() => _WSGT20260813_WithControls(_WSGT20260813_GuillemetsBody))

; Independent semantic decode accepts TOML comments. The owner's legacy ';'
; full-line banner is translated only for this independent test oracle; this is
; not the production reader and does not implement another string parser.
_WSIC_Document(Text) {
	Lines := []
	loop parse, Text, "`n", "`r" {
		Line := A_LoopField
		if RegExMatch(Line, "^[ `t]*;")
			Line := RegExReplace(Line, ";", "#", , 1)
		Lines.Push(Line)
	}
	return TOML_ParseDocument(ArrayJoin(Lines, "`n"))
}
_WSIC_HasPair(Custom, Left, Right) {
	for Pair in Custom
		if Pair["left"] == Left && Pair["right"] == Right
			return true
	return false
}
_WSIC_DiskDisabled(Document, Character) {
	if !Document.Has("disabled")
		return false
	for Entry in Document["disabled"]
		if Entry.Has("char") && Entry["char"] == Character
			return true
	return false
}
_WSIC_CommentRoundTrip(Mode) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed, _WS_StateEpoch
	global _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
	Saved := {path: _WS_Config_Path, disabled: _WS_Disabled, custom: _WS_Custom,
		failed: _WS_LoadFailed, epoch: _WS_StateEpoch, active: _WS_ACTIVE_PAIRS,
		builtins: _WS_BUILTIN_PAIRS, groups: _WS_BUILTIN_GROUPS}
	Root := A_Temp . "\ergopti_wrap_comments_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\wrap_symbols.toml"
	try {
		AssertFalse(A_IsSuspended)
		Left := Mode == "quoted-hash-control" ? "#" : (Mode == "escaped-quote-control" ? Chr(34)
			: (Mode == "legacy-semicolon-control" ? ";" : "a"))
		Right := Mode == "escaped-quote-control" ? "#" : "b"
		HeaderTail := Mode == "header-comment" ? ' # annotation "quoted"' : ""
		DisabledTail := Mode == "disabled-field-comment" ? ' # annotation "quoted"' : ""
		CustomTail := Mode == "custom-field-comment" ? ' # annotation "quoted"' : ""
		Source := (Mode == "legacy-semicolon-control" ? "; supported legacy full-line comment`n" : "")
			. "[[disabled]]" . HeaderTail . "`nchar = " . TOML_RenderString("(") . DisabledTail . "`n"
			. "[[custom]]" . HeaderTail . "`nleft = " . TOML_RenderString(Left) . "`n"
			. "right = " . TOML_RenderString(Right) . CustomTail . "`n"
		if Mode == "custom-before-disabled"
			Source := "[[custom]]`nleft = " . TOML_RenderString(Left) . "`nright = " . TOML_RenderString(Right)
				. "`n[[disabled]]`nchar = " . TOML_RenderString("(") . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		PhysicalSource := FSReadStrict(Path)
		if Mode == "custom-before-disabled"
			AssertTrue(InStr(PhysicalSource, "[[custom]]") > 0
				&& InStr(PhysicalSource, "[[custom]]") < InStr(PhysicalSource, "[[disabled]]"),
				"the genuine source must put its custom block before the disabled block")
		Independent := _WSIC_Document(PhysicalSource)
		AssertTrue(_WSIC_DiskDisabled(Independent, "("), "the authored source really disables its one-character builtin")
		AssertTrue(_WSIC_HasPair(Independent["custom"], Left, Right), "the independent semantic decoder must admit the original pair")
		AssertTrue(WrapSymbols_Init(Root . "\"), "the real public initializer must accept the private source")
		BeforeHadPair := _WSIC_HasPair(_WS_Custom, Left, Right)
		BeforeDisabled := _WS_Disabled.Has("(")
		Committed := WrapSymbols_AddCustom("c", "d")
		AssertTrue(Committed, "a valid annotated source must allow the actual public writer to persist an unrelated new pair")
		Disk := _WSIC_Document(FSReadStrict(Path))
		AssertTrue(_WSIC_HasPair(Disk["custom"], "c", "d"), "the unrelated new pair must genuinely reach disk")
		AssertTrue(_WSIC_HasPair(Disk["custom"], Left, Right), "the acknowledged unrelated save must not delete the original annotated pair")
		AssertTrue(_WSIC_DiskDisabled(Disk, "("), "the writer must not serialize comment text in place of the original disabled symbol")
		AssertTrue(WrapSymbols_Init(Root . "\"), "reload must use the actual persisted file")
		AssertTrue(_WSIC_HasPair(_WS_Custom, Left, Right))
		AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
		AssertFalse(WrapSymbols_IsEnabled("("), "the same builtin must remain disabled after an actual save and reload")
		AssertTrue(BeforeHadPair)
		AssertTrue(BeforeDisabled)
	} finally {
		_WS_Config_Path := Saved.path, _WS_Disabled := Saved.disabled, _WS_Custom := Saved.custom
		_WS_LoadFailed := Saved.failed, _WS_StateEpoch := Saved.epoch, _WS_ACTIVE_PAIRS := Saved.active
		_WS_BUILTIN_PAIRS := Saved.builtins, _WS_BUILTIN_GROUPS := Saved.groups
		DirDelete(Root, true)
	}
}
for _WSIC_Mode in ["canonical-control", "header-comment", "disabled-field-comment", "custom-field-comment",
	"quoted-hash-control", "escaped-quote-control", "legacy-semicolon-control"]
	Test("wrap symbols TOML inline comments: " . _WSIC_Mode, _WSIC_CommentRoundTrip.Bind(_WSIC_Mode))

_WSC_Field(Name, Value, Style) {
	if Style == "literal"
		return Name . " = " . Chr(39) . Value . Chr(39) . "`n"
	if Style == "multiline-basic" || Style == "multiline-literal" || Style == "one-line-multiline" {
		Quote := Style == "multiline-literal" ? Chr(39) : Chr(34)
		Delimiter := Quote . Quote . Quote
		return Name . " = " . Delimiter . (Style == "one-line-multiline" ? "" : "`n") . Value . Delimiter . "`n"
	}
	return Name . " = " . TOML_RenderString(Value) . "`n"
}
_WSC_RecognizedSource(Mode) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed, _WS_StateEpoch
	global _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
	Saved := {path: _WS_Config_Path, disabled: _WS_Disabled, custom: _WS_Custom,
		failed: _WS_LoadFailed, epoch: _WS_StateEpoch, active: _WS_ACTIVE_PAIRS,
		builtins: _WS_BUILTIN_PAIRS, groups: _WS_BUILTIN_GROUPS}
	Root := A_Temp . "\ergopti_wrap_canonical_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\wrap_symbols.toml"
	try {
		AssertFalse(A_IsSuspended)
		Style := Mode == "literal" ? "literal" : (InStr(Mode, "multiline-basic") == 1 ? "multiline-basic"
			: (InStr(Mode, "multiline-literal") == 1 ? "multiline-literal"
				: (Mode == "one-line-multiline" ? "one-line-multiline" : "basic")))
		Left := InStr(Mode, "semicolon-data") ? ";" : "a"
		Right := Left == ";" ? ":" : "b"
		Disabled := "[[disabled]]`n" . (Mode == "bad-disabled-type" ? "char = 1`n" : _WSC_Field("char", "(", Style))
		if Mode == "legacy-disabled-map"
			Disabled := '[disabled]`nchars = "(,["`n'
		Body := Disabled . "[[custom]]`n" . _WSC_Field("left", Left, Style)
		if Mode == "bad-custom-type"
			Body .= "right = true`n"
		else if Mode != "symmetric-custom"
			Body .= _WSC_Field("right", Right, Style)
		else
			Right := Left
		; The independent decoder gets precisely the semantic body. Known legacy
		; comments below are deliberate source decoration, not fixture data.
		Expected := TOML_ParseDocument(Body)
		Source := Body
		if Mode == "legacy-comment-control"
			Source := '; legacy = "unterminated comment quote`n' . Source
		if Mode == "legacy-inline-comment-control"
			Source := StrReplace(Source, 'char = "("', 'char = "("' . " " . Chr(59) . " legacy inline note")
		AssertTrue(FSWriteCreateDurable(Path, Source))
		Initialized := WrapSymbols_Init(Root . "\")
		if Mode == "bad-disabled-type" || Mode == "bad-custom-type" {
			if Mode == "bad-disabled-type"
				AssertTrue(Expected["disabled"][1]["char"] is Integer)
			else
				AssertTrue(Expected["custom"][1]["right"] is TOML_Bool)
			Committed := WrapSymbols_AddCustom("c", "d")
			AssertFalse(Committed, "a recognized unprojectable owned leaf must refuse the actual unrelated write")
			AssertEqual(Source, FSReadStrict(Path), "a rejected owned projection must retain all exact source bytes")
			AssertTrue(_WS_LoadFailed, "the source's unprojectable known leaf must remain latched")
			return
		}
		AssertTrue(Initialized)
		AssertFalse(_WS_LoadFailed)
		AssertTrue(WrapSymbols_AddCustom("c", "d"), "the actual public writer must persist an unrelated new pair")
		; The writer's legacy semicolon banner has no assignment. The canonical
		; semantic decoder reports it as opaque trivia and still decodes the data;
		; no test-side quote or multiline scanner is used.
		Disk := TOML_ParseDocument(FSReadStrict(Path))
		AssertTrue(_WSIC_HasPair(Disk["custom"], Left, Right), "a valid literal/multiline original must survive the actual native save")
		AssertTrue(_WSIC_HasPair(Disk["custom"], "c", "d"))
		AssertTrue(_WSIC_DiskDisabled(Disk, "("), "source disabled choice must survive native persistence")
		AssertTrue(WrapSymbols_Init(Root . "\"))
		AssertTrue(_WSIC_HasPair(_WS_Custom, Left, Right))
		AssertFalse(WrapSymbols_IsEnabled("("))
		if Mode == "legacy-disabled-map"
			AssertFalse(WrapSymbols_IsEnabled("["), "the legacy CSV map remains supported")
	} finally {
		_WS_Config_Path := Saved.path, _WS_Disabled := Saved.disabled, _WS_Custom := Saved.custom
		_WS_LoadFailed := Saved.failed, _WS_StateEpoch := Saved.epoch, _WS_ACTIVE_PAIRS := Saved.active
		_WS_BUILTIN_PAIRS := Saved.builtins, _WS_BUILTIN_GROUPS := Saved.groups
		DirDelete(Root, true)
	}
}
for _WSC_Mode in ["literal", "multiline-basic", "multiline-literal", "one-line-multiline",
	"multiline-basic-semicolon-data", "multiline-literal-semicolon-data", "legacy-comment-control",
	"legacy-inline-comment-control", "legacy-disabled-map", "symmetric-custom", "bad-disabled-type", "bad-custom-type"]
	Test("wrap symbols canonical owned source: " . _WSC_Mode, _WSC_RecognizedSource.Bind(_WSC_Mode))

_WSSA_WithOwnedSource(Body) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed, _WS_StateEpoch
	global _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
	Saved := {path: _WS_Config_Path, disabled: _WS_Disabled, custom: _WS_Custom,
		failed: _WS_LoadFailed, epoch: _WS_StateEpoch, active: _WS_ACTIVE_PAIRS,
		builtins: _WS_BUILTIN_PAIRS, groups: _WS_BUILTIN_GROUPS}
	Root := A_Temp . "\ergopti_wrap_source_admission_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\wrap_symbols.toml", Created := false
	try {
		AssertFalse(A_IsSuspended)
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created, "a wrap fixture must affirmatively acquire its directory")
		Source := '[[disabled]]`nchar = "["`n[[custom]]`nleft = "a"`nright = "b"`n'
		AssertTrue(FSWriteCreateDurable(Path, Source))
		AssertTrue(WrapSymbols_Init(Root . "\"))
		Body.Call(Root, Path, Source)
	} finally {
		_WS_Config_Path := Saved.path, _WS_Disabled := Saved.disabled, _WS_Custom := Saved.custom
		_WS_LoadFailed := Saved.failed, _WS_StateEpoch := Saved.epoch, _WS_ACTIVE_PAIRS := Saved.active
		_WS_BUILTIN_PAIRS := Saved.builtins, _WS_BUILTIN_GROUPS := Saved.groups
		if Created
			DirDelete(Root, true)
	}
}
_WSSA_ExternalSource(Mode, Root, Path, SourceA) {
	global _WS_Disabled, _WS_Custom, _WS_ACTIVE_PAIRS, _WS_StateEpoch
	SourceB := SourceA . '[[disabled]]`nchar = "("`n[[custom]]`nleft = "e"`nright = "f"`n'
	AssertTrue(FSWriteDurable(Path, SourceB))
	IndependentB := _WSIC_Document(FSReadUtf8Exact(Path))
	AssertTrue(_WSIC_HasPair(IndependentB["custom"], "e", "f"))
	AssertTrue(_WSIC_DiskDisabled(IndependentB, "("))
	Reloaded := InStr(Mode, "reload-") == 1
	if Reloaded
		AssertTrue(WrapSymbols_Init(Root . "\"))
	Before := {custom: _WS_Custom, disabled: _WS_Disabled, active: _WS_ACTIVE_PAIRS, epoch: _WS_StateEpoch}
	IsAdd := InStr(Mode, "add") > 0
	Result := IsAdd ? WrapSymbols_AddCustom("c", "d") : WrapSymbols_Toggle("(")
	if !Reloaded {
		AssertFalse(Result, "a full-state writer must refuse a source no longer represented by its loaded RAM")
		AssertEqual(SourceB, FSReadUtf8Exact(Path), "an unrelated mutation cannot erase an external custom pair or disabled choice")
		AssertTrue(_WS_Custom == Before.custom && _WS_Disabled == Before.disabled && _WS_ACTIVE_PAIRS == Before.active)
		AssertEqual(Before.epoch, _WS_StateEpoch)
	} else {
		AssertTrue(Result, "reloading the actual B owner must admit a subsequent ordinary public mutation")
		Disk := _WSIC_Document(FSReadUtf8Exact(Path))
		AssertTrue(_WSIC_HasPair(Disk["custom"], "a", "b"))
		AssertTrue(_WSIC_HasPair(Disk["custom"], "e", "f"))
		if IsAdd
			AssertTrue(_WSIC_HasPair(Disk["custom"], "c", "d"))
		else
			AssertFalse(_WSIC_DiskDisabled(Disk, "("))
		AssertTrue(WrapSymbols_Init(Root . "\"))
		AssertTrue(_WSIC_HasPair(_WS_Custom, "e", "f"))
		if IsAdd
			AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
		else
			AssertTrue(WrapSymbols_IsEnabled("("))
	}
}
for _WSSA_Mode in ["stale-add", "stale-toggle", "reload-add-control", "reload-toggle-control"]
	Test("wrap source ownership: " . _WSSA_Mode, _WSSA_WithOwnedSource.Bind(_WSSA_ExternalSource.Bind(_WSSA_Mode)))

_WSSA_NativeForward(State, This, Args*) {
	AssertEqual(11, Args.Length, "the actual public mutation must forward its captured source receipt to the private save")
	Args[10] := _WSSA_NativeCutpoint.Bind(State)
	return Func.Prototype.Call.Call(This, Args*)
}
_WSSA_NativeCutpoint(State) {
	global _WS_Custom, _WS_Disabled, _WS_ACTIVE_PAIRS, _WS_StateEpoch
	State.Fired += 1
	AssertEqual(1, State.Fired)
	AssertFalse(A_IsCritical, "the native boundary must remain outside the preceding memory-only Critical span")
	Stages := []
	Loop Files, State.path . ".*.tmp"
		Stages.Push(A_LoopFileFullPath)
	AssertEqual(1, Stages.Length, "a genuine complete private stage must exist before revocation")
	Stage := _WSIC_Document(_WSHS_ReadHeldStage(Stages[1]))
	AssertTrue(_WSIC_HasPair(Stage["custom"], "c", "d"))
	if State.mode == "suspend"
		Suspend(true)
	else if State.mode == "reinitialize"
		AssertTrue(WrapSymbols_Init(State.root . "\"), "a genuine successor init retires the old publication epoch")
	else if State.mode == "source-edit" {
		State.external := State.source . '[[custom]]`nleft = "e"`nright = "f"`n'
		AssertTrue(FSWriteDurable(State.path, State.external))
	} else if State.mode == "source-same-image-control"
		AssertTrue(FSWriteDurable(State.path, State.source), "an actual new write of the same source image does not revoke its semantic owner")
	State.retained := {custom: _WS_Custom, disabled: _WS_Disabled, active: _WS_ACTIVE_PAIRS, epoch: _WS_StateEpoch}
}
_WSSA_FinalNative(Mode, Root, Path, Source) {
	global _WS_Custom, _WS_Disabled, _WS_ACTIVE_PAIRS, _WS_StateEpoch
	State := {mode: Mode, root: Root, path: Path, source: Source, external: "", Fired: 0, retained: 0}
	Owner := _WS_Save
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
	WasSuspended := A_IsSuspended
	try {
		Object.Prototype.DefineProp.Call(Owner, "Call", {Call: _WSSA_NativeForward.Bind(State)})
		Result := WrapSymbols_AddCustom("c", "d")
		AssertEqual(1, State.Fired, "the actual public mutation must reach the private final native observation")
		if Mode == "live-control" || Mode == "source-same-image-control" {
			AssertTrue(Result)
			AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
			AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
		} else {
			ExpectedSource := Mode == "source-edit" ? State.external : Source
			AssertEqual(ExpectedSource, FSReadUtf8Exact(Path), "a retired publication cannot alter its native durable source")
			AssertFalse(Result)
			AssertTrue(_WS_Custom == State.retained.custom && _WS_Disabled == State.retained.disabled && _WS_ACTIVE_PAIRS == State.retained.active,
				"the actual retained or successor RAM projection must remain attached")
			AssertEqual(State.retained.epoch, _WS_StateEpoch)
		}
	} finally {
		if HadCall
			Object.Prototype.DefineProp.Call(Owner, "Call", SavedCall)
		else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			Object.Prototype.DeleteProp.Call(Owner, "Call")
		Suspend(WasSuspended)
	}
}
for _WSSA_NativeMode in ["suspend", "reinitialize", "live-control", "source-edit", "source-same-image-control"]
	Test("wrap final native admission: " . _WSSA_NativeMode, _WSSA_WithOwnedSource.Bind(_WSSA_FinalNative.Bind(_WSSA_NativeMode)))

_WSSA_ObserveAckRead(State, This, Args*) {
	Read := Func.Prototype.Call.Call(This, Args*)
	if !State.Fired && Args.Length > 0 && Args[1] == State.path && Read is Map && Read.Get("status", "") == "ok" {
		Document := _WSIC_Document(Read["content"])
		if Document.Has("custom") && _WSIC_HasPair(Document["custom"], "c", "d") {
			State.Fired := true
			AssertFalse(A_IsCritical, "the genuine post-rename readback must execute outside a memory Critical span")
			if State.mode == "pause-after-ack"
				Suspend(true)
		}
	}
	return Read
}
_WSSA_PostAck(Mode, Root, Path, Source) {
	global _WS_Custom, _WS_ACTIVE_PAIRS
	State := {mode: Mode, path: Path, Fired: false}
	Owner := FSReadWithStatus
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
	WasSuspended := A_IsSuspended
	try {
		AssertFalse(HadCall, "the post-ACK observer must not bypass an unknown read owner")
		Object.Prototype.DefineProp.Call(Owner, "Call", {Call: _WSSA_ObserveAckRead.Bind(State)})
		Result := WrapSymbols_AddCustom("c", "d")
		AssertTrue(State.Fired, "the real native rename must precede the observed readback of its new exact bytes")
		AssertTrue(Result, "a later pause cannot revoke a write that already became durable")
		AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"), "the acknowledged projection must publish even if pause follows the native commit")
		AssertTrue(_WS_ACTIVE_PAIRS.Has("c"))
		AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
	} finally {
		if HadCall
			Object.Prototype.DefineProp.Call(Owner, "Call", SavedCall)
		else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			Object.Prototype.DeleteProp.Call(Owner, "Call")
		Suspend(WasSuspended)
	}
}
for _WSSA_AckMode in ["pause-after-ack", "live-after-ack-control"]
	Test("wrap acknowledged publication: " . _WSSA_AckMode, _WSSA_WithOwnedSource.Bind(_WSSA_PostAck.Bind(_WSSA_AckMode)))

; A prior real successful save reveals only the implementation-owned stage name.
; The tested save itself uses all default stage/native/cleanup adapters.
_WSST_StageCollision(Mode, Root, Path, Source) {
	global _WS_Custom
	Observed := {path: "", calls: 0}
	Observe(Stage, Content) {
		Observed.calls += 1
		Observed.path := Stage
		return FSWriteDurable(Stage, Content)
	}
	AssertTrue(WrapSymbols_AddCustom("c", "d", Observe), "the observation delegates the actual durable stage writer")
	AssertEqual(1, Observed.calls)
	AssertFalse(FSStrictExists(Observed.path), "the real first native rename must consume its stage")
	AssertTrue(RegExMatch(Observed.path, "^(.*-)([0-9]+)(\.tmp)$", &Parts) > 0,
		"the fixture observes the production stage namespace rather than controlling its allocator")
	NextStage := Parts[1] . (Integer(Parts[2]) + 1) . Parts[3]
	Before := FSReadUtf8Exact(Path)
	Foreign := "foreign-stage-owned-by-another-writer`n"
	if Mode == "collision"
		AssertTrue(FSWriteCreateDurable(NextStage, Foreign), "the independent stage already exists before the tested public transaction")
	else
		AssertFalse(FSStrictExists(NextStage))
	Result := WrapSymbols_AddCustom("e", "f")
	Present := FSStrictExists(NextStage)
	AfterStage := Present ? FSReadUtf8Exact(NextStage) : "<missing>"
	After := FSReadUtf8Exact(Path)
	Disk := _WSIC_Document(After)
	FileAppend("# wrap-stage-collision mode=" . Mode . " ack=" . Result . " foreign-present=" . Present
		. " foreign-preserved=" . ((AfterStage == Foreign) ? 1 : 0) . "`n", "*")
	if Mode == "collision" {
		AssertTrue(Present, "a pre-existing unowned stage must never be consumed by this save")
		AssertEqual(Foreign, AfterStage, "a pre-existing unowned stage must never be overwritten or cleaned")
		if !Result {
			AssertEqual(Before, After, "a refused stage admission leaves the live source unchanged")
			AssertFalse(_WSIC_HasPair(_WS_Custom, "e", "f"))
		}
	} else
		AssertTrue(Result, "the ordinary default writer must still perform a real successful save")
	if Result {
		AssertTrue(_WSIC_HasPair(Disk["custom"], "e", "f"))
		AssertTrue(_WSIC_HasPair(_WS_Custom, "e", "f"))
	}
	AssertTrue(_WSIC_HasPair(Disk["custom"], "a", "b"))
	AssertTrue(_WSIC_HasPair(Disk["custom"], "c", "d"))
}
for _WSST_Mode in ["collision", "ordinary-control"]
	Test("wrap symbols native stage ownership: " . _WSST_Mode . " (wrap-stage-ownership)",
		_WSSA_WithOwnedSource.Bind(_WSST_StageCollision.Bind(_WSST_Mode)))

; This fixture reads an explicitly held writer's immutable private stage. Its
; read handle must share the original WRITE/DELETE access as well as READ.
_WSHS_ReadHeldStage(Path) {
	Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
		"UInt", 7, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
	AssertTrue(Handle != 0 && Handle != -1, "acquire an actual read-only stage observation handle")
	try {
		Content := _FSReadUtf8ExactHandle(Handle, 0, false)
		AssertTrue(Content is String)
		return Content
	} finally AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") != 0)
}

_WSHS_StageForward(State, This, Args*) {
	AssertEqual(11, Args.Length)
	Args[10] := _WSHS_InspectHeldStage.Bind(State)
	return Func.Prototype.Call.Call(This, Args*)
}
_WSHS_InspectHeldStage(State) {
	State.fired += 1
	AssertFalse(A_IsCritical, "native stage observations must precede the memory-only final span")
	Stages := []
	Loop Files, State.path . ".*.tmp"
		Stages.Push(A_LoopFileFullPath)
	AssertEqual(1, Stages.Length)
	State.stage := Stages[1]
	State.before := _WSHS_ReadHeldStage(State.stage)
	State.write := FSWriteDurable(State.stage, "foreign replacement")
	State.move := FSMove(State.stage, State.root . "\unowned-moved-stage.tmp")
	State.delete := FSDelete(State.stage)
	State.after := FSStrictExists(State.stage) ? _WSHS_ReadHeldStage(State.stage) : "<missing>"
}
_WSHS_Custody(Root, Path, Source) {
	global _WS_Custom
	State := {root: Root, path: Path, fired: 0, stage: "", before: "", after: "", write: false, move: false, delete: false}
	Owner := _WS_Save
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
	try {
		Object.Prototype.DefineProp.Call(Owner, "Call", {Call: _WSHS_StageForward.Bind(State)})
		Result := WrapSymbols_AddCustom("c", "d")
		_TestPrint("# wrap-held-stage ack=" . Result . " fired=" . State.fired
			. " foreign-write=" . State.write . " foreign-move=" . State.move . " foreign-delete=" . State.delete)
		AssertEqual(1, State.fired)
		AssertFalse(State.write, "an unrelated pathname writer cannot overwrite the retained stage")
		AssertFalse(State.move, "an unrelated pathname mover cannot substitute the retained stage")
		AssertFalse(State.delete, "an unrelated pathname deleter cannot retire the retained stage")
		AssertEqual(State.before, State.after, "READ-only inspection remains compatible with the existing final cutpoint tests")
		AssertTrue(Result, "the original held owner must still publish after all rejected competing operations")
		AssertFalse(FSStrictExists(State.stage), "the actual successful rename consumes only the original owned stage")
		AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
		AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
	} finally {
		if HadCall
			Object.Prototype.DefineProp.Call(Owner, "Call", SavedCall)
		else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			Object.Prototype.DeleteProp.Call(Owner, "Call")
	}
}
Test("wrap native held stage: pathname substitution is refused while real publication succeeds (wrap-stage-ownership)",
	_WSSA_WithOwnedSource.Bind(_WSHS_Custody))

_WSHS_RefusalRetry(Root, Path, Source) {
	global _WS_Custom
	Handle := 0, ProbeOwned := false
	try {
		Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
			"UInt", 3, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Handle != 0 && Handle != -1, "the fixture must acquire the target's actual no-delete-share handle")
		Probe := Root . "\owned-sharing-control.tmp"
		ProbeOwned := FSWriteCreateDurable(Probe, Source)
		AssertTrue(ProbeOwned)
		try {
			AssertFalse(FSAtomicMoveReplace(Probe, Path, &NativeError))
			AssertTrue(NativeError == 5 || NativeError == 32,
				"the access/sharing refusal is qualified only by the same inverse rename after hold release")
			AssertTrue(FSStrictExists(Probe))
			Result := WrapSymbols_AddCustom("c", "d")
			Stages := []
			Loop Files, Path . ".*.tmp"
				Stages.Push(A_LoopFileFullPath)
			_TestPrint("# wrap-held-refusal ack=" . Result . " native-sharing=" . NativeError . " retained-stages=" . Stages.Length)
			AssertFalse(Result)
			AssertEqual(Source, FSReadUtf8Exact(Path))
			AssertFalse(_WSIC_HasPair(_WS_Custom, "c", "d"))
			AssertEqual(0, Stages.Length, "only the failed attempt's retained owned object is discarded")
		} finally {
			ClosedHold := DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
			if ClosedHold
				Handle := 0
			AssertTrue(ClosedHold, "close the exact no-delete-share handle before the inverse witness")
			if ProbeOwned {
				AssertTrue(FSStrictExists(Probe), "retain the same owned probe even when a business oracle fails")
				Released := FSAtomicMoveReplace(Probe, Path, &ReleasedError)
				_TestPrint("# wrap-held-refusal-inverse blocked-error=" . NativeError
					. " released-ack=" . Released . " released-error=" . ReleasedError)
				AssertTrue(Released, "the same actual native rename must ACK after the exact hold closes")
				ProbeOwned := false
				AssertFalse(FSStrictExists(Probe))
				AssertEqual(Source, FSReadUtf8Exact(Path), "the inverse uses the original complete image, preserving genuine source admission")
			}
		}
		AssertTrue(WrapSymbols_AddCustom("c", "d"), "a genuine released-target retry must succeed")
		AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
		AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
	} finally {
		if Handle && Handle != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
	}
}
Test("wrap native held stage: refused target retires its own stage and permits a real retry (wrap-stage-ownership)",
	_WSSA_WithOwnedSource.Bind(_WSHS_RefusalRetry))

_WSHS_AbsentCreate(Root, Path, Source) {
	global _WS_Custom
	AssertTrue(FSDeleteStrict(Path))
	AssertTrue(WrapSymbols_Init(Root . "\"), "the genuine missing-source loader must establish a new absent receipt")
	AssertFalse(FSStrictExists(Path))
	Result := WrapSymbols_AddCustom("c", "d")
	_TestPrint("# wrap-held-absent ack=" . Result . " created=" . FSStrictExists(Path))
	AssertTrue(Result, "the held owner must retain the ordinary no-replace create route")
	AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
	AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
}
Test("wrap native held stage: a genuinely absent source can still be created (wrap-stage-ownership)",
	_WSSA_WithOwnedSource.Bind(_WSHS_AbsentCreate))

_WSHP_Flush(State, Handle, Phase) {
	State.flushes.Push(Phase)
	AssertFalse(A_IsCritical, "file flushing must remain outside final memory admission")
	if Phase == "stage"
		State.stageHandle := Handle
	if Phase == "published" && (State.mode == "post-flush-refusal" || State.mode == "new-reload-after-refusal")
		return false ; explicit typed adapter refusal, not a claimed native Win32 failure
	return DllCall("Kernel32\FlushFileBuffers", "Ptr", Handle, "Int") != 0
}
_WSHP_Forward(State, This, Path, Content, Suffix, &Detail, StageFn,
		BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication) {
	global _WS_Custom, _WS_StateEpoch
	Result := Func.Prototype.Call.Call(This, Path, Content, Suffix, &Detail,
		StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication,
		_WSHP_Flush.Bind(State))
	; Query immediately, before diagnostics/reload could recycle this value.
	Info := Buffer(52, 0)
	State.retired := DllCall("Kernel32\GetFileInformationByHandle", "Ptr", State.stageHandle,
		"Ptr", Info, "Int") == 0
	State.retirementError := A_LastError
	State.receipt := {renamed: Publication.renamed, durable: Publication.durable}
	if State.mode == "new-reload-after-refusal" {
		State.reloaded := WrapSymbols_Init(State.root . "\")
		State.newOwner := _WS_Custom, State.newEpoch := _WS_StateEpoch
	}
	return Result
}
_WSHP_Notice(State, This, Message, Options) {
	State.messages.Push(Message)
	return true ; feedback-only observer; no persistence or policy SUT is replaced
}
_WSHP_RoundTrip(Mode, Root, Path, Source) {
	global _WS_Custom, _WS_LoadFailed, _WS_StateEpoch
	State := {mode: Mode, root: Root, flushes: [], stageHandle: 0, retired: false,
		retirementError: 0, receipt: 0, messages: [], reloaded: false, newOwner: 0, newEpoch: -1}
	Owner := FSWriteReplaceOwned, Notifier := NotifierSend
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
	HadNotice := Object.Prototype.HasOwnProp.Call(Notifier, "Call")
	SavedNotice := HadNotice ? Object.Prototype.GetOwnPropDesc.Call(Notifier, "Call") : false
	try {
		Object.Prototype.DefineProp.Call(Owner, "Call", {Call: _WSHP_Forward.Bind(State)})
		Object.Prototype.DefineProp.Call(Notifier, "Call", {Call: _WSHP_Notice.Bind(State)})
		Result := WrapSymbols_AddCustom("c", "d")
	} finally {
		if HadCall
			Object.Prototype.DefineProp.Call(Owner, "Call", SavedCall)
		else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			Object.Prototype.DeleteProp.Call(Owner, "Call")
		if HadNotice
			Object.Prototype.DefineProp.Call(Notifier, "Call", SavedNotice)
		else if Object.Prototype.HasOwnProp.Call(Notifier, "Call")
			Object.Prototype.DeleteProp.Call(Notifier, "Call")
	}
	Physical := FSReadUtf8Exact(Path)
	Disk := _WSIC_Document(Physical)
	_TestPrint("# wrap-partial-publication mode=" . Mode . " result=" . Result
		. " renamed=" . (State.receipt ? State.receipt.renamed : -1)
		. " durable=" . (State.receipt ? State.receipt.durable : -1)
		. " latch=" . _WS_LoadFailed . " notices=" . State.messages.Length
		. " flushes=" . State.flushes.Length . " retired=" . State.retired
		. " retirement-error=" . State.retirementError . " reloaded=" . State.reloaded)
	Assert(State.receipt is Object)
	AssertTrue(State.receipt.renamed, "the original actual held native rename must have succeeded")
	AssertTrue(_WSIC_HasPair(Disk["custom"], "c", "d"), "the physical target really contains the new candidate")
	AssertEqual(2, State.flushes.Length)
	AssertEqual("stage", State.flushes[1])
	AssertEqual("published", State.flushes[2])
	AssertTrue(State.retired, "the real stage handle must already be closed when its adapter returns")
	AssertEqual(6, State.retirementError, "the retirement proof must be actual ERROR_INVALID_HANDLE")
	if Mode == "native-control" {
		AssertTrue(Result)
		AssertTrue(State.receipt.durable)
		AssertFalse(_WS_LoadFailed)
		AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
		AssertEqual(0, State.messages.Length)
		return
	}
	AssertFalse(Result, "a refused post-rename flush cannot be weakened into a successful durability ACK")
	AssertFalse(State.receipt.durable)
	if Mode == "new-reload-after-refusal" {
		AssertTrue(State.reloaded)
		Assert(_WS_Custom == State.newOwner, "the older failed completion cannot replace the independently reloaded model")
		AssertEqual(State.newEpoch, _WS_StateEpoch)
		AssertFalse(_WS_LoadFailed, "a partial failure from the previous owner cannot poison a genuine newer reload")
		AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
		AssertTrue(WrapSymbols_AddCustom("e", "f"))
		AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
		AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "e", "f"))
		return
	}
	AssertTrue(_WS_LoadFailed, "the old incomplete live projection must be fenced until a genuine reload")
	AssertFalse(_WSIC_HasPair(_WS_Custom, "c", "d"), "RAM must not falsely advertise a durably acknowledged candidate")
	AssertEqual(1, State.messages.Length)
	AssertFalse(State.messages[1] == t("dialog.bulk_toggle.save_failed"), "feedback must not claim the already replaced file was reverted")
	AssertFalse(WrapSymbols_AddCustom("e", "f"), "another save cannot reconstruct over the pending physical candidate")
	AssertEqual(Physical, FSReadUtf8Exact(Path))
	AssertTrue(WrapSymbols_Init(Root . "\"), "a real reload reconciles the actual new physical candidate")
	AssertFalse(_WS_LoadFailed)
	AssertTrue(_WSIC_HasPair(_WS_Custom, "c", "d"))
	AssertTrue(WrapSymbols_AddCustom("e", "f"), "a genuinely reconciled model can save again")
	AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "c", "d"))
	AssertTrue(_WSIC_HasPair(_WSIC_Document(FSReadUtf8Exact(Path))["custom"], "e", "f"))
}
for _WSHP_Mode in ["post-flush-refusal", "new-reload-after-refusal", "native-control"]
	Test("wrap native partial publication: " . _WSHP_Mode . " (wrap-stage-ownership)",
		_WSSA_WithOwnedSource.Bind(_WSHP_RoundTrip.Bind(_WSHP_Mode)))

_WSSA_Case(Kind) {
	global _WS_Config_Path, _WS_Disabled, _WS_Custom, _WS_LoadFailed, _WS_StateEpoch
	global _WS_ACTIVE_PAIRS, _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
	Saved := {path: _WS_Config_Path, disabled: _WS_Disabled, custom: _WS_Custom,
		failed: _WS_LoadFailed, epoch: _WS_StateEpoch, active: _WS_ACTIVE_PAIRS,
		builtins: _WS_BUILTIN_PAIRS, groups: _WS_BUILTIN_GROUPS}
	Root := A_Temp . "\ergopti_wrap_scalar_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\wrap_symbols.toml", Created := false
	try {
		AssertFalse(A_IsSuspended)
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		Source := '[[disabled]]`nchar = "("`n[[custom]]`nleft = "a"`nright = "b"`n'
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		AssertTrue(WrapSymbols_Init(Root . "\"))
		AssertFalse(_WS_LoadFailed)
		AssertTrue(_WSIC_HasPair(_WS_Custom, "a", "b"))
		Before := FSReadBytesStrict(Path)
		OpeningCustom := _WS_Custom, OpeningDisabled := _WS_Disabled, OpeningActive := _WS_ACTIVE_PAIRS
		OpeningEpoch := _WS_StateEpoch
		Left := Kind == "left-nul" ? Chr(0) : Chr(1)
		Right := Kind == "right-nul" ? Chr(0) : ")"
		AssertEqual(1, StrLen(Left)), AssertEqual(1, StrLen(Right))
		Result := WrapSymbols_AddCustom(Left, Right)
		After := FSReadBytesStrict(Path)
		SameProjection := _WS_Custom == OpeningCustom && _WS_Disabled == OpeningDisabled
			&& _WS_ACTIVE_PAIRS == OpeningActive && _WS_StateEpoch == OpeningEpoch
		Parsed := false
		try {
			Disk := _WSIC_Document(FSReadUtf8Exact(Path))
			Parsed := true
		}
		Reloaded := WrapSymbols_Init(Root . "\")
		_TestPrint("# wrap-scalar kind=" . Kind . " result=" . Result . " parsed=" . Parsed
			. " same-projection=" . SameProjection . " reloaded=" . Reloaded . " latched=" . _WS_LoadFailed
			. " before-bytes=" . Before.Size . " after-bytes=" . After.Size)
		if Kind != "control" {
			AssertFalse(Result, "public wrap mutations must refuse a scalar their canonical reader cannot represent")
			AssertTrue(SameProjection, "a refused scalar must not publish a replacement live owner")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "the original complete durable source must remain exact")
		} else {
			AssertTrue(Result, "a non-NUL escaped control remains a representable one-unit symbol")
			AssertTrue(Parsed)
			AssertTrue(_WSIC_HasPair(Disk["custom"], Left, Right))
			AssertTrue(_WSIC_HasPair(_WS_Custom, Left, Right))
		}
		AssertTrue(Reloaded)
		AssertFalse(_WS_LoadFailed, "the actual acknowledged/refused native file must remain reloadable")
		AssertTrue(_WSIC_HasPair(_WS_Custom, "a", "b"))
		AssertTrue(_WS_Disabled.Has("("))
	} finally {
		_WS_Config_Path := Saved.path, _WS_Disabled := Saved.disabled, _WS_Custom := Saved.custom
		_WS_LoadFailed := Saved.failed, _WS_StateEpoch := Saved.epoch, _WS_ACTIVE_PAIRS := Saved.active
		_WS_BUILTIN_PAIRS := Saved.builtins, _WS_BUILTIN_GROUPS := Saved.groups
		if Created
			DirDelete(Root, true)
	}
}
for _WSSA_Kind in ["left-nul", "right-nul", "control"]
	Test("wrap symbols public scalar admission: " . _WSSA_Kind . " (wrap-scalar-admission)", _WSSA_Case.Bind(_WSSA_Kind))
