; tests/unit/test_tap_hold_global_transaction_20260813.ahk

; ==============================================================================
; MODULE: Tap-Hold Global Persistence Transaction Regression
; DESCRIPTION:
; Drives the production tap-hold writers and reset action through injected
; filesystem boundaries. The suite proves that a process-wide terminal config
; transition, a same-path re-entrant writer, a post-stage path rebase, or a
; non-strict adapter result cannot publish stale TapHold state or trigger Reload.
;
; FEATURES & RATIONALE:
; 1. Exercises all four writer entry points through one global admission gate.
; 2. Records staging, authorization, replacement, cleanup and Reload ordering.
; 3. Verifies inherited Critical is defused across every blocking boundary.
; ==============================================================================

#Requires AutoHotkey v2.0

global _THGT_Mode := "ok"
global _THGT_TargetPath := ""
global _THGT_Writes := []
global _THGT_Replaces := []
global _THGT_Deletes := []
global _THGT_AuthorizeCritical := []
global _THGT_Reloads := []
global _THGT_ReentrantResult := unset
global _THGT_FixtureSequence := 0





; ================================
; ================================
; ======= 1/ Test adapters =======
; ================================
; ================================

_THGT_ResetRecords(Mode := "ok") {
	global _THGT_Mode, _THGT_Writes, _THGT_Replaces, _THGT_Deletes
	global _THGT_AuthorizeCritical, _THGT_Reloads, _THGT_ReentrantResult
	_THGT_Mode := Mode
	_THGT_Writes := []
	_THGT_Replaces := []
	_THGT_Deletes := []
	_THGT_AuthorizeCritical := []
	_THGT_Reloads := []
	_THGT_ReentrantResult := unset
}

_THGT_Writer(StagePath, Content) {
	global _THGT_Mode, _THGT_Writes, _THGT_ReentrantResult, _ConfigDir
	_THGT_Writes.Push(Map(
		"path", StagePath,
		"content", Content,
		"critical", A_IsCritical))
	if (_THGT_Mode == "writer_string")
		return "1"
	if (_THGT_Mode == "writer_throw")
		throw Error("injected stage failure")
	if (_THGT_Mode == "writer_rebase")
		_ConfigDir := A_Temp . "\ergopti_thgt_rebased\"
	if (_THGT_Mode == "reenter")
		_THGT_ReentrantResult := WriteTapHoldNative("tab", _THGT_Writer,
			_THGT_Replace, _THGT_Delete, _THGT_Authorize)
	return 1
}

_THGT_Replace(StagePath, TargetPath) {
	global _THGT_Mode, _THGT_Replaces
	_THGT_Replaces.Push(Map(
		"stage", StagePath,
		"target", TargetPath,
		"critical", A_IsCritical))
	if (_THGT_Mode == "replace_string")
		return "1"
	if (_THGT_Mode == "replace_throw")
		throw Error("injected replace failure")
	return 1
}

_THGT_Delete(Path) {
	global _THGT_Mode, _THGT_Deletes
	_THGT_Deletes.Push(Map("path", Path, "critical", A_IsCritical))
	if (_THGT_Mode == "reset_delete_string")
		return "1"
	if (_THGT_Mode == "reset_delete_throw")
		throw Error("injected delete failure")
	return 1
}

_THGT_Authorize() {
	global _THGT_Mode, _THGT_AuthorizeCritical, _ConfigDir
	_THGT_AuthorizeCritical.Push(A_IsCritical)
	if (_THGT_Mode == "authorize_rebase")
		_ConfigDir := A_Temp . "\ergopti_thgt_authorize_rebased\"
	if (_THGT_Mode == "authorize_string")
		return "1"
	return 1
}

_THGT_Reload(Reason, KeyId) {
	global _THGT_Mode, _THGT_Reloads
	_THGT_Reloads.Push(Map(
		"reason", Reason,
		"key", KeyId,
		"critical", A_IsCritical))
	if (_THGT_Mode == "reload_string")
		return "1"
	return 1
}





; ====================================
; ====================================
; ======= 2/ Fixture isolation =======
; ====================================
; ====================================

_THGT_FreshState() {
	return Map(
		"keys", Map(
			"caps_lock", Map(
				"tap_action", "escape",
				"hold_modifier", "ctrl")),
		"inherit_defaults", true)
}

_THGT_WithFixture(TestFn) {
	global _ConfigDir, _AhkSubDir, TapHold
	global _THGT_TargetPath, _THGT_FixtureSequence
	SavedConfigDir := _ConfigDir
	SavedAhkSubDir := _AhkSubDir
	SavedTapHold := TapHold
	LocalSequence := ++_THGT_FixtureSequence
	_ConfigDir := A_Temp . "\ergopti_thgt_" . A_ScriptHwnd
		. "_" . LocalSequence . "\"
	_AhkSubDir := ""
	_THGT_TargetPath := _ConfigDir . "tap_hold.toml"
	TapHold := _THGT_FreshState()
	_THGT_ResetRecords()
	try return TestFn.Call(_THGT_TargetPath)
	finally {
		CurrentOwner := _ConfigWriteLeaseCurrent(_THGT_TargetPath)
		if CurrentOwner is Object
			_ConfigWriteLeaseRelease(CurrentOwner)
		_ConfigDir := SavedConfigDir
		_AhkSubDir := SavedAhkSubDir
		TapHold := SavedTapHold
	}
}

_THGT_WriterCases() {
	return [
		Map("name", "tap", "run", WriteTapHoldTap.Bind("caps_lock", "enter",
			_THGT_Writer, _THGT_Replace, _THGT_Delete, _THGT_Authorize)),
		Map("name", "hold", "run", WriteTapHoldHold.Bind("caps_lock",
			Map("kind", "layer", "id", "nav"),
			_THGT_Writer, _THGT_Replace, _THGT_Delete, _THGT_Authorize)),
		Map("name", "native", "run", WriteTapHoldNative.Bind("caps_lock",
			_THGT_Writer, _THGT_Replace, _THGT_Delete, _THGT_Authorize)),
		Map("name", "disabled", "run", _TH_WriteTapHoldDisabled.Bind(
			_THGT_Writer, _THGT_Replace, _THGT_Delete, _THGT_Authorize))
	]
}





; =======================================
; =======================================
; ======= 3/ Durable writer class =======
; =======================================
; =======================================

_THGT_AllWritersStageAuthorizeReplaceThenPublishOwned(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces, _THGT_Deletes
	global _THGT_AuthorizeCritical
	SeenStages := Map()
	for WriterCase in _THGT_WriterCases() {
		TapHold := _THGT_FreshState()
		Before := TapHold
		_THGT_ResetRecords()
		Result := WriterCase["run"].Call()
		Assert((Result is Integer) && Result == 1,
			WriterCase["name"] . " writer must report strict success")
		AssertEqual(1, _THGT_Writes.Length,
			WriterCase["name"] . " writer must create exactly one complete stage")
		AssertEqual(1, _THGT_Replaces.Length,
			WriterCase["name"] . " writer must atomically replace exactly once")
		AssertEqual(0, _THGT_Deletes.Length,
			WriterCase["name"] . " writer must not clean a successfully published stage")
		StagePath := _THGT_Writes[1]["path"]
		SplitPath(StagePath, , &StageDir)
		SplitPath(TargetPath, , &TargetDir)
		AssertEqual(TargetDir, StageDir,
			"the private stage must share the target directory for atomic replacement")
		Assert(StagePath != TargetPath . ".tmp",
			"the writer must never reuse the process-independent fixed .tmp path")
		Assert(InStr(StagePath, "." . A_ScriptHwnd . "-") > 0,
			"the private stage must include the process identity and a sequence")
		Assert(!SeenStages.Has(StagePath),
			"each writer transaction must receive a unique stage path")
		SeenStages[StagePath] := true
		AssertEqual(StagePath, _THGT_Replaces[1]["stage"],
			"the complete stage must be the source of atomic replacement")
		AssertEqual(TargetPath, _THGT_Replaces[1]["target"],
			"atomic replacement must target the exact path admitted before cloning")
		AssertEqual(0, _THGT_Writes[1]["critical"],
			"durable staging must run outside Critical")
		AssertEqual(0, _THGT_Replaces[1]["critical"],
			"atomic replacement must run outside Critical")
		Assert(_THGT_AuthorizeCritical.Length == 1
			&& _THGT_AuthorizeCritical[1] != 0,
			"post-stage owner/path authorization must run in a short Critical span")
		Assert(ObjPtr(TapHold) != ObjPtr(Before),
			"successful persistence must publish one detached TapHold candidate")

		switch WriterCase["name"] {
		case "tap":
			AssertEqual("enter", TapHold["keys"]["caps_lock"]["tap_action"])
		case "hold":
			AssertEqual("nav", TapHold["keys"]["caps_lock"]["hold_layer"])
			AssertFalse(TapHold["keys"]["caps_lock"].Has("hold_modifier"))
		case "native":
			AssertEqual("", TapHold["keys"]["caps_lock"]["tap_action"])
			AssertFalse(TapHold["keys"]["caps_lock"].Has("hold_modifier"))
		case "disabled":
			AssertEqual(0, TapHold["keys"].Count)
			AssertFalse(TapHold.Has("layers"), "layer bindings are not tap-hold state")
			AssertFalse(TapHold["inherit_defaults"])
		}
	}
}

_THGT_AllWritersStageAuthorizeReplaceThenPublish() {
	return _THGT_WithFixture(
		_THGT_AllWritersStageAuthorizeReplaceThenPublishOwned)
}
Test("tap-hold transaction: all writers stage, authorize, replace, then publish "
	. "(tap-hold-global-transaction)",
	_THGT_AllWritersStageAuthorizeReplaceThenPublish)

_THGT_StrictAdapterFailuresDoNotPublishOwned(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces, _THGT_Deletes
	for Mode in ["writer_string", "replace_string", "writer_throw", "replace_throw"] {
		TapHold := _THGT_FreshState()
		Before := TapHold
		_THGT_ResetRecords(Mode)
		Result := WriteTapHoldTap("caps_lock", "enter", _THGT_Writer,
			_THGT_Replace, _THGT_Delete, _THGT_Authorize)
		AssertFalse(Result,
			Mode . " must refuse the transaction instead of coercing adapter output")
		AssertEqual(ObjPtr(Before), ObjPtr(TapHold),
			Mode . " must leave the live TapHold identity untouched")
		AssertEqual(1, _THGT_Deletes.Length,
			Mode . " must clean the unpublished private stage")
		if InStr(Mode, "writer_")
			AssertEqual(0, _THGT_Replaces.Length,
				"a refused stage must abort before atomic replacement")
	}
}

_THGT_StrictAdapterFailuresDoNotPublish() {
	return _THGT_WithFixture(_THGT_StrictAdapterFailuresDoNotPublishOwned)
}
Test("tap-hold transaction: string success and throws cannot publish "
	. "(tap-hold-global-transaction)",
	_THGT_StrictAdapterFailuresDoNotPublish)

_THGT_UnknownTapActionNeverStagesOwned(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces
	Before := TapHold
	_THGT_ResetRecords()
	Result := WriteTapHoldTap("caps_lock", "__audit_unknown_action__",
		_THGT_Writer, _THGT_Replace, _THGT_Delete, _THGT_Authorize)
	AssertFalse(Result,
		"a tap action absent from GESTURE_ACTIONS must be rejected")
	AssertEqual(0, _THGT_Writes.Length,
		"a rejected tap action must not create a durable stage")
	AssertEqual(0, _THGT_Replaces.Length,
		"a rejected tap action must not replace the tap-hold configuration")
	AssertEqual(ObjPtr(Before), ObjPtr(TapHold),
		"a rejected tap action must leave the live TapHold object unchanged")
}

_THGT_UnknownTapActionNeverStages() {
	return _THGT_WithFixture(_THGT_UnknownTapActionNeverStagesOwned)
}
Test("tap-hold transaction: unknown tap action is rejected before staging (AHK-149)",
	_THGT_UnknownTapActionNeverStages)

_THGT_PostStagePathRebaseIsRejectedOwned(TargetPath) {
	global TapHold, _ConfigDir, _THGT_Replaces, _THGT_Deletes
	FixtureConfigDir := _ConfigDir
	for Mode in ["writer_rebase", "authorize_rebase", "authorize_string"] {
		_ConfigDir := FixtureConfigDir
		TapHold := _THGT_FreshState()
		Before := TapHold
		_THGT_ResetRecords(Mode)
		Result := WriteTapHoldTap("caps_lock", "enter", _THGT_Writer,
			_THGT_Replace, _THGT_Delete, _THGT_Authorize)
		AssertFalse(Result,
			Mode . " must fail post-stage authorization")
		AssertEqual(0, _THGT_Replaces.Length,
			Mode . " must abort before replacing either old or rebased target")
		AssertEqual(1, _THGT_Deletes.Length,
			Mode . " must remove its rejected private stage")
		AssertEqual(ObjPtr(Before), ObjPtr(TapHold),
			Mode . " must preserve the exact live TapHold object")
	}
}

_THGT_PostStagePathRebaseIsRejected() {
	return _THGT_WithFixture(_THGT_PostStagePathRebaseIsRejectedOwned)
}
Test("tap-hold transaction: post-stage path rebase is rejected "
	. "(tap-hold-global-transaction)",
	_THGT_PostStagePathRebaseIsRejected)

_THGT_ReentrantWriterCannotBuildFromStaleStateOwned(TargetPath) {
	global TapHold, _THGT_ReentrantResult, _THGT_Writes, _THGT_Replaces
	_THGT_ResetRecords("reenter")
	Result := WriteTapHoldTap("caps_lock", "enter", _THGT_Writer,
		_THGT_Replace, _THGT_Delete, _THGT_Authorize)
	AssertTrue(Result, "the admitted outer writer must still complete")
	AssertFalse(_THGT_ReentrantResult,
		"a same-path writer re-entered from staging must be refused by the global owner")
	AssertEqual(1, _THGT_Writes.Length,
		"the refused inner writer must never create its own stage")
	AssertEqual(1, _THGT_Replaces.Length,
		"only the admitted outer transaction may replace the target")
	AssertFalse(TapHold["keys"].Has("tab"),
		"the refused inner native mutation must not reach live state")
	AssertEqual("enter", TapHold["keys"]["caps_lock"]["tap_action"])
}

_THGT_ReentrantWriterCannotBuildFromStaleState() {
	return _THGT_WithFixture(_THGT_ReentrantWriterCannotBuildFromStaleStateOwned)
}
Test("tap-hold transaction: re-entrant writer is refused before snapshot "
	. "(tap-hold-global-transaction)",
	_THGT_ReentrantWriterCannotBuildFromStaleState)





; ====================================================
; ====================================================
; ======= 4/ Terminal barrier and reset action =======
; ====================================================
; ====================================================

_THGT_TerminalBarrierRefusesEveryActionOwned(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces, _THGT_Deletes, _THGT_Reloads
	Bundle := _ConfigWriteTerminalTryAcquire([TargetPath])
	Assert(Bundle is Object,
		"the fixture must acquire the process-wide terminal barrier")
	try {
		for WriterCase in _THGT_WriterCases() {
			TapHold := _THGT_FreshState()
			Before := TapHold
			_THGT_ResetRecords()
			AssertFalse(WriterCase["run"].Call(),
				WriterCase["name"] . " must refuse admission while a terminal transition owns the process")
			AssertEqual(ObjPtr(Before), ObjPtr(TapHold),
				WriterCase["name"] . " must not publish on terminal refusal")
			AssertEqual(0, _THGT_Writes.Length)
			AssertEqual(0, _THGT_Replaces.Length)
		}
		_THGT_ResetRecords()
		AssertFalse(_TH_ResetTapHoldConfig(_THGT_Delete,
			_THGT_Authorize, _THGT_Reload),
			"reset must share the same process-wide terminal admission gate")
		AssertEqual(0, _THGT_Deletes.Length,
			"terminal refusal must abort reset before deleting the target")
		AssertEqual(0, _THGT_Reloads.Length,
			"terminal refusal must not request Reload")
	} finally {
		AssertTrue(_ConfigWriteTerminalRelease(Bundle),
			"the fixture must release the terminal barrier")
	}
}

_THGT_TerminalBarrierRefusesEveryAction() {
	return _THGT_WithFixture(_THGT_TerminalBarrierRefusesEveryActionOwned)
}
Test("tap-hold transaction: terminal barrier refuses all writers and reset "
	. "(tap-hold-global-transaction)",
	_THGT_TerminalBarrierRefusesEveryAction)

_THGT_ResetRefusalsNeverReloadOwned(TargetPath) {
	global _ConfigDir, _THGT_Deletes, _THGT_Reloads
	FixtureConfigDir := _ConfigDir
	for Mode in ["reset_delete_string", "reset_delete_throw",
			"authorize_rebase", "authorize_string"] {
		_ConfigDir := FixtureConfigDir
		_THGT_ResetRecords(Mode)
		Result := _TH_ResetTapHoldConfig(_THGT_Delete,
			_THGT_Authorize, _THGT_Reload)
		AssertFalse(Result, Mode . " must refuse reset")
		AssertEqual(0, _THGT_Reloads.Length,
			Mode . " must never Reload after a refused reset")
		if InStr(Mode, "authorize_")
			AssertEqual(0, _THGT_Deletes.Length,
				Mode . " must refuse before deleting the target")
	}
}

_THGT_ResetRefusalsNeverReload() {
	return _THGT_WithFixture(_THGT_ResetRefusalsNeverReloadOwned)
}
Test("tap-hold transaction: reset refusals never delete or reload late "
	. "(tap-hold-global-transaction)",
	_THGT_ResetRefusalsNeverReload)





; ===========================================
; ===========================================
; ======= 5/ Inherited Critical state =======
; ===========================================
; ===========================================

_THGT_InheritedCriticalIsDefusedOwned(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces, _THGT_Deletes
	global _THGT_AuthorizeCritical, _THGT_Reloads
	for WriterCase in _THGT_WriterCases() {
		TapHold := _THGT_FreshState()
		_THGT_ResetRecords()
		PreviousCritical := Critical("On")
		try {
			AssertTrue(WriterCase["run"].Call(),
				WriterCase["name"] . " must complete under an inherited Critical caller")
			Assert(A_IsCritical != 0,
				WriterCase["name"] . " must restore the caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _THGT_Writes[1]["critical"],
			WriterCase["name"] . " staging must be defused")
		AssertEqual(0, _THGT_Replaces[1]["critical"],
			WriterCase["name"] . " replacement must be defused")
		Assert(_THGT_AuthorizeCritical[1] != 0,
			WriterCase["name"] . " authorization remains a short memory-only Critical span")
	}

	_THGT_ResetRecords()
	PreviousCritical := Critical("On")
	try {
		AssertTrue(_TH_ResetTapHoldConfig(_THGT_Delete,
			_THGT_Authorize, _THGT_Reload),
			"reset must complete under an inherited Critical caller")
		Assert(A_IsCritical != 0,
			"reset must restore the caller's Critical state")
	} finally Critical(PreviousCritical)
	AssertEqual(0, _THGT_Deletes[1]["critical"],
		"reset deletion must run outside Critical")
	AssertEqual(0, _THGT_Reloads[1]["critical"],
		"reset Reload must run outside Critical")
	Assert(_THGT_AuthorizeCritical[1] != 0,
		"reset authorization must stay inside its short memory-only span")
}

_THGT_InheritedCriticalIsDefused() {
	return _THGT_WithFixture(_THGT_InheritedCriticalIsDefusedOwned)
}
Test("tap-hold transaction: inherited Critical is defused and restored "
	. "(tap-hold-global-transaction)",
	_THGT_InheritedCriticalIsDefused)






; ==================================================
; ==================================================
; ======= 6/ Per-key timing native ownership =======
; ==================================================
; ==================================================

global _THD_Phase := ""
global _THD_Result := 0
global _THD_Answer := { Result: "OK", Value: "375.4" }
global _THD_Prompts := []
global _THD_Setters := []
global _THD_Reloads := []
global _THD_Mode := "ok"

_THD_Reset() {
	global _THD_Phase, _THD_Result, _THD_Answer, _THD_Prompts, _THD_Setters, _THD_Reloads, _THD_Mode
	_THD_Phase := ""
	_THD_Result := 0
	_THD_Answer := { Result: "OK", Value: "375.4" }
	_THD_Prompts := []
	_THD_Setters := []
	_THD_Reloads := []
	_THD_Mode := "ok"
	_THGT_ResetRecords()
}

_THD_Port(Phase, Args*) {
	global _THD_Phase, _THD_Result
	if Phase == _THD_Phase {
		if _THD_Result == "throw"
			throw Error("injected duration " . Phase . " refusal")
		return _THD_Result
	}
	switch Phase {
	case "write": return _THGT_Writer(Args*)
	case "replace": return _THGT_Replace(Args*)
	case "authorize": return _THGT_Authorize()
	}
	throw Error("Unknown duration test port.")
}

_THD_Write(KeyId := "caps_lock", Seconds := 0.375, SourceWitness := 0) {
	return WriteTapHoldDuration(KeyId, Seconds, _THD_Port.Bind("write"),
		_THD_Port.Bind("replace"), _THGT_Delete, _THD_Port.Bind("authorize"), SourceWitness)
}

_THD_OnlyThresholdChanges(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces
	_THD_Reset()
	TapHold["keys"]["caps_lock"]["enabled"] := false
	TapHold["keys"]["caps_lock"]["future_note"] := "keep"
	TapHold["keys"]["tab"] := Map("tap_action", "copy", "time_activation_seconds", 0.45)
	Before := TapHold
	AssertEqual(1, _THD_Write(), "duration uses the actual detached native owner")
	Assert(ObjPtr(TapHold) != ObjPtr(Before), "only accepted persistence replaces the live model")
	Key := TapHold["keys"]["caps_lock"]
	AssertEqual(0.375, Key["time_activation_seconds"])
	AssertEqual("escape", Key["tap_action"])
	AssertEqual("ctrl", Key["hold_modifier"])
	AssertEqual(false, Key["enabled"], "duration does not enable a disabled key")
	AssertEqual("keep", Key["future_note"], "existing future per-key scalar survives")
	AssertEqual(0.45, TapHold["keys"]["tab"]["time_activation_seconds"], "neighbor threshold survives")
	AssertEqual(1, _THGT_Writes.Length)
	AssertEqual(1, _THGT_Replaces.Length)
	AssertEqual(0, _THGT_Writes[1]["critical"], "staging occurs outside Critical")
	AssertEqual(1, _THD_Write("left_ctrl", 0.251))
	NewKey := TapHold["keys"]["left_ctrl"]
	AssertEqual(1, NewKey.Count, "a duration-only entry creates no tap, hold or enable assignment")
	AssertEqual(0.251, NewKey["time_activation_seconds"])
}
Test("tap-hold duration: detached publication changes only one threshold (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_OnlyThresholdChanges))

_THD_InvalidInputNeverStages(TargetPath) {
	global TapHold, _THGT_Writes
	_THD_Reset()
	Before := TapHold
	for KeyId in ["", "unknown_physical_key", "caps_lock.injected", "CAPS_LOCK"]
		AssertEqual(false, _THD_Write(KeyId), "unknown section identities cannot reach serialization")
	NonFiniteBits := Buffer(8, 0)
	NumPut("Int64", 0x7FF8000000000000, NonFiniteBits)
	NaN := NumGet(NonFiniteBits, "Double")
	AssertEqual("Float", Type(NaN), "the controlled input is an actual native IEEE float")
	Assert(DllCall("msvcrt\_isnan", "double", NaN, "cdecl int"), "the fixture actually supplies NaN")
	NumPut("Int64", 0x7FF0000000000000, NonFiniteBits)
	Infinity := NumGet(NonFiniteBits, "Double")
	AssertEqual(0, DllCall("msvcrt\_finite", "double", Infinity, "cdecl int"),
		"the fixture actually supplies non-finite positive infinity")
	for Value in [0, -1, 10.001, "0.375", Map(), NaN, Infinity]
		AssertEqual(false, _THD_Write("caps_lock", Value), "invalid/non-finite thresholds are refused")
	AssertEqual(ObjPtr(Before), ObjPtr(TapHold), "all invalid input preserves the actual model")
	AssertEqual(0, _THGT_Writes.Length)
}
Test("tap-hold duration: invalid physical keys and non-finite values never stage (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_InvalidInputNeverStages))

_THD_StrictTransactionPorts(TargetPath) {
	global TapHold, _THD_Phase, _THD_Result, _THGT_Replaces
	for Phase in ["write", "authorize", "replace"] {
		for Value in [0, "", "1", 2, 1.0, "throw"] {
			_THD_Reset()
			TapHold := _THGT_FreshState()
			Before := TapHold
			_THD_Phase := Phase
			_THD_Result := Value
			AssertEqual(false, _THD_Write(), "only strict integer1 admits " . Phase)
			AssertEqual(ObjPtr(Before), ObjPtr(TapHold), "refused adapter cannot publish runtime state")
			Assert(!Before["keys"]["caps_lock"].Has("time_activation_seconds"))
			if Phase != "replace"
				AssertEqual(0, _THGT_Replaces.Length, "refusal cannot reach replacement")
			Assert(!FileExist(TargetPath), "controlled failure leaves the private target absent")
		}
	}
}
Test("tap-hold duration: stage authorization and replace require strict receipts (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_StrictTransactionPorts))

_THD_RevokingWriter(StagePath, Content) {
	global TapHold
	_THGT_Writer(StagePath, Content)
	TapHold := _THGT_FreshState()
	TapHold["foreign_owner"] := true
	return 1
}

_THD_AdmissionAndRevocation(TargetPath) {
	global TapHold, ConfigurationFile, _THGT_Writes, _THGT_Mode
	_THD_Reset()
	Before := TapHold
	for Path in [ConfigurationFile, TargetPath] {
		Lease := _ConfigWriteLeaseTryAcquire(Path, "duration-competing-test")
		Assert(Lease is Object)
		try AssertEqual(false, _THD_Write(), "both master and child leases gate duration changes")
		finally _ConfigWriteLeaseRelease(Lease)
		AssertEqual(ObjPtr(Before), ObjPtr(TapHold))
	}
	Terminal := _ConfigWriteTerminalTryAcquire([TargetPath])
	Assert(Terminal is Object)
	try AssertEqual(false, _THD_Write(), "the terminal barrier rejects duration before staging")
	finally _ConfigWriteTerminalRelease(Terminal)
	AssertEqual(0, _THGT_Writes.Length)
	_THGT_Mode := "writer_rebase"
	AssertEqual(false, _THD_Write(), "post-stage target rebase cannot publish")
	AssertEqual(ObjPtr(Before), ObjPtr(TapHold))
}
Test("tap-hold duration: leases terminal barrier and captured path survive refusal (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_AdmissionAndRevocation))

_THD_LiveOwnerRevocation(TargetPath) {
	global TapHold
	_THD_Reset()
	AssertEqual(false, WriteTapHoldDuration("caps_lock", 0.375, _THD_RevokingWriter,
		_THGT_Replace, _THGT_Delete, _THGT_Authorize))
	AssertEqual(true, TapHold["foreign_owner"], "foreign replacement state stays authoritative")
	Assert(!TapHold["keys"]["caps_lock"].Has("time_activation_seconds"))
}
Test("tap-hold duration: live owner withdrawal cannot publish a stale threshold (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_LiveOwnerRevocation))

_THD_PhysicalFileRoundtrip(TargetPath) {
	global TapHold
	_THD_Reset()
	SplitPath(TargetPath, , &Directory)
	DirCreate(Directory)
	try {
		TapHold["keys"]["tab"] := Map("tap_action", "copy", "time_activation_seconds", 0.45)
		AssertEqual(1, WriteTapHoldDuration("caps_lock", 0.375), "real native filesystem publishes the threshold")
		Assert(FileExist(TargetPath), "the real native writer creates the private physical file")
		ReadBack := LoadTapHoldToml(TargetPath)
		AssertEqual(0.375, ReadBack["keys"]["caps_lock"]["time_activation_seconds"])
		AssertEqual("escape", ReadBack["keys"]["caps_lock"]["tap_action"])
		AssertEqual("ctrl", ReadBack["keys"]["caps_lock"]["hold_modifier"])
		AssertEqual(0.45, ReadBack["keys"]["tab"]["time_activation_seconds"])
	} finally {
		if FileExist(TargetPath)
			FileDelete(TargetPath)
		DirDelete(Directory)
	}
}
Test("tap-hold duration: real private native file survives loader roundtrip (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_PhysicalFileRoundtrip))

_THD_Prompt(Prompt, Title, Options, CurrentMs) {
	global _THD_Prompts, _THD_Answer, _THD_Mode, TapHold, _ConfigDir, ConfigurationFile
	_THD_Prompts.Push(Map("prompt", Prompt, "current", CurrentMs, "critical", A_IsCritical))
	if _THD_Mode == "prompt_throw"
		throw Error("injected prompt refusal")
	if _THD_Mode == "prompt_rebase"
		_ConfigDir := A_Temp . "\ergopti_duration_prompt_rebased\"
	if _THD_Mode == "prompt_revoke"
		TapHold := _THGT_FreshState()
	if _THD_Mode == "prompt_master_rebase"
		ConfigurationFile := A_Temp . "\ergopti_duration_successor_master.toml"
	if _THD_Mode == "prompt_keys_revoke"
		TapHold["keys"] := _TH_CloneData(TapHold["keys"])
	if _THD_Mode == "prompt_entry_revoke"
		TapHold["keys"]["caps_lock"] := _TH_CloneData(TapHold["keys"]["caps_lock"])
	if _THD_Mode == "prompt_entry_mutate"
		TapHold["keys"]["caps_lock"]["tap_action"] := "copy"
	if _THD_Mode == "prompt_source_delete"
		FileDelete(_TH_TapHoldConfigPath())
	if _THD_Mode == "prompt_source_replace" || _THD_Mode == "prompt_source_create"
		AssertEqual(1, FSWriteDurable(_TH_TapHoldConfigPath(), Chr(0xFEFF) . 'future.owner = "successor"`n'))
	return _THD_Answer
}

_THD_Setter(KeyId, Seconds, SourceWitness := 0) {
	global _THD_Setters, _THD_Mode, _THD_Result
	_THD_Setters.Push(Map("key", KeyId, "seconds", Seconds))
	if _THD_Mode == "setter_throw"
		throw Error("injected setter refusal")
	if _THD_Mode == "setter_result"
		return _THD_Result
	Published := _THD_Mode == "setter_physical_source_after"
		? WriteTapHoldDuration(KeyId, Seconds, 0, 0, 0, 0, SourceWitness)
		: _THD_Write(KeyId, Seconds, SourceWitness)
	if _THD_Mode == "setter_rebase_after" {
		global _ConfigDir
		_ConfigDir := A_Temp . "\ergopti_duration_after_save_rebased\"
	}
	if _THD_Mode == "setter_successor_after" {
		global TapHold
		TapHold["keys"][KeyId] := Map("tap_action", "copy")
	}
	if _THD_Mode == "setter_same_threshold_entry"
		TapHold["keys"][KeyId] := _TH_CloneData(TapHold["keys"][KeyId])
	if _THD_Mode == "setter_same_threshold_keys"
		TapHold["keys"] := _TH_CloneData(TapHold["keys"])
	if _THD_Mode == "setter_same_threshold_parent"
		TapHold := _TH_CloneData(TapHold)
	if _THD_Mode == "setter_physical_source_after"
		AssertEqual(1, FSWriteDurable(_TH_TapHoldConfigPath(), Chr(0xFEFF) . 'future.owner = "successor"`n'))
	return Published
}

_THD_Reload(Reason, KeyId) {
	global _THD_Reloads, _THD_Mode, _THD_Result
	_THD_Reloads.Push(Map("reason", Reason, "key", KeyId, "critical", A_IsCritical))
	if _THD_Mode == "reload_throw"
		throw Error("injected reload refusal")
	return _THD_Mode == "reload_result" ? _THD_Result : 1
}

_THD_Ask(KeyId := "caps_lock") {
	return _TH_PromptKeyDelay(KeyId, _THD_Prompt, _THD_Setter, _THD_Reload)
}

_THD_PromptAndBoundKey(TargetPath) {
	global TapHold, _THD_Prompts, _THD_Setters, _THD_Reloads
	_THD_Reset()
	TapHold["keys"]["caps_lock"]["time_activation_seconds"] := 0.35
	Bound := _TH_MakeDelayPickerFn("caps_lock", _THD_Prompt, _THD_Setter, _THD_Reload)
	PriorCritical := Critical("On")
	try {
		AssertEqual(1, Bound.Call("tab", 999, "fake-menu"), "native event arguments cannot redirect the captured key")
		Assert(A_IsCritical != 0, "the prompt preserves its caller's Critical posture")
	} finally Critical(PriorCritical)
	AssertEqual(1, _THD_Prompts.Length)
	AssertEqual(350, _THD_Prompts[1]["current"], "effective per-key350ms is not guessed global200ms")
	Assert(!InStr(_THD_Prompts[1]["prompt"], "%d"), "the native prompt substitutes its printf placeholder")
	Assert(InStr(_THD_Prompts[1]["prompt"], "350"), "the translated prompt displays the effective value")
	AssertEqual(0, _THD_Prompts[1]["critical"])
	AssertEqual(1, _THD_Setters.Length)
	AssertEqual("caps_lock", _THD_Setters[1]["key"])
	AssertEqual(0.375, _THD_Setters[1]["seconds"], "native rounding matches the Linux positive-ms picker")
	AssertEqual(1, _THD_Reloads.Length)
	AssertEqual("caps_lock", _THD_Reloads[1]["key"])
	AssertEqual(0, _THD_Reloads[1]["critical"])
}
Test("tap-hold duration: translated prompt binds the key and reloads once after acceptance (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_PromptAndBoundKey))

_THD_PromptRefusesMalformed(TargetPath) {
	global _THD_Answer, _THD_Mode, _THD_Setters, _THD_Reloads
	for Answer in [0, Map(), { Result: "Cancel", Value: "375" }, { Result: "OK" },
		{ Result: "OK", Value: 375 }, { Result: "OK", Value: "0" }, { Result: "OK", Value: "0.49" },
		{ Result: "OK", Value: "-1" }, { Result: "OK", Value: "10000.1" },
		{ Result: "OK", Value: "nan" }, { Result: "OK", Value: "1e309" }, { Result: "OK", Value: "invalid" }] {
		_THD_Reset()
		_THD_Answer := Answer
		AssertEqual(false, _THD_Ask())
		AssertEqual(0, _THD_Setters.Length, "invalid/cancelled answers invoke no owner")
		AssertEqual(0, _THD_Reloads.Length)
	}
	_THD_Reset()
	_THD_Mode := "prompt_throw"
	AssertEqual(false, _THD_Ask())
	AssertEqual(0, _THD_Setters.Length)
}
Test("tap-hold duration: cancellation and malformed prompt shapes have no effects (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_PromptRefusesMalformed))

_THD_PromptRefusesNonStrictOwners(TargetPath) {
	global _THD_Mode, _THD_Result, _THD_Setters, _THD_Reloads
	for Mode in ["setter_result", "reload_result"] {
		for Value in [0, "", "1", 2, 1.0] {
			_THD_Reset()
			_THD_Mode := Mode
			_THD_Result := Value
			AssertEqual(false, _THD_Ask(), "native acknowledgement stays strict after " . Mode)
			AssertEqual(1, _THD_Setters.Length)
			AssertEqual(Mode == "setter_result" ? 0 : 1, _THD_Reloads.Length)
		}
	}
	for Mode in ["setter_throw", "reload_throw"] {
		_THD_Reset()
		_THD_Mode := Mode
		AssertEqual(false, _THD_Ask(), "throwing owner is refused without duplicate effects")
		AssertEqual(1, _THD_Setters.Length)
		AssertEqual(Mode == "setter_throw" ? 0 : 1, _THD_Reloads.Length)
	}
}
Test("tap-hold duration: prompt refuses non-strict publication and reload receipts (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_PromptRefusesNonStrictOwners))

_THD_PromptSourceWithdrawal(TargetPath) {
	global _THD_Mode, _THD_Setters, _THD_Reloads, _ConfigDir, TapHold
	OriginalPath := _ConfigDir
	for Mode in ["prompt_rebase", "prompt_revoke"] {
		_THD_Reset()
		_ConfigDir := OriginalPath
		TapHold := _THGT_FreshState()
		_THD_Mode := Mode
		AssertEqual(false, _THD_Ask(), "held prompt cannot move to a new native source")
		AssertEqual(0, _THD_Setters.Length)
		AssertEqual(0, _THD_Reloads.Length)
	}
}
Test("tap-hold duration: held prompt rejects replaced source and rebased target (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_PromptSourceWithdrawal))

; ==========================================================
; ==========================================================
; ======= 7/ Physical one-leaf source preservation ==========
; ==========================================================
; ==========================================================

_THD_FutureSource() {
	return Chr(0xFEFF)
		. '# the unknown root is user data`nfuture.version = "001" # keep root spelling`n'
		. '[tap_hold]`ninherit_defaults = false # explicit opt-out`n'
		. '[tap_hold.keys.caps_lock] # keep key header`n'
		. 'enabled = false # keep the literal Boolean`n'
		. 'tap_action = "escape"`nhold_modifier = "ctrl"`n'
		. 'time_activation_seconds = 0.2 # only this field is owned`n'
		. 'future_inline = { code = "001", active = false, values = [1, "2"] } # retained`n'
		. '[tap_hold.keys.tab]`nenabled = true # neighbor Boolean`n'
		. 'time_activation_seconds = 0.45`ntap_action = "copy"`n'
		. '[[future.audit]] # first generation`nname = "first"`n'
		. '[[future.audit]] # second generation`nname = "second"`n'
}

_THD_WithPhysicalSource(TargetPath, Source, RunFn) {
	SplitPath(TargetPath, , &Directory)
	DirCreate(Directory)
	try {
		AssertEqual(1, FSWriteDurable(TargetPath, Source), "the fixture writes actual source bytes")
		return RunFn.Call(TargetPath)
	} finally {
		if FileExist(TargetPath)
			FileDelete(TargetPath)
		DirDelete(Directory)
	}
}

_THD_FuturePhysicalLeafOwned(TargetPath) {
	global TapHold
	_THD_Reset()
	TapHold["keys"]["caps_lock"]["enabled"] := false
	Source := _THD_FutureSource()
	Expected := StrReplace(Source, 'time_activation_seconds = 0.2 # only this field is owned`n',
		'time_activation_seconds = 0.375`n')
	AssertEqual(1, WriteTapHoldDuration("caps_lock", 0.375), "the real native owner persists the one leaf")
	Assert(FSUtf8ExactMatches(TargetPath, Expected), "every unowned physical record remains byte-exact")
	Document := TOML_ParseDocument(FSReadUtf8Exact(TargetPath))
	Assert(Document["tap_hold"]["keys"]["caps_lock"]["enabled"] is TOML_Bool)
	AssertEqual(false, Document["tap_hold"]["keys"]["caps_lock"]["enabled"].Value,
		"false never becomes numeric zero")
	AssertEqual(true, Document["tap_hold"]["keys"]["tab"]["enabled"].Value)
	AssertEqual(2, Document["future"]["audit"].Length, "both future table-array generations survive")
	AssertEqual("001", Document["future"]["version"])
	AssertEqual(false, TapHold["keys"]["caps_lock"]["enabled"])
	AssertEqual(0.375, TapHold["keys"]["caps_lock"]["time_activation_seconds"])
	ReadBack := LoadTapHoldToml(TargetPath)
	AssertEqual(false, ReadBack["keys"]["caps_lock"]["enabled"], "the actual loader retains explicit disable")
	AssertEqual(0.375, ReadBack["keys"]["caps_lock"]["time_activation_seconds"])
	Assert(!InStr(FSReadUtf8Exact(TargetPath), "`r"), "a source written in LF remains LF")
}
Test("tap-hold duration: real one-leaf publication preserves Boolean and future physical namespaces (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture((Path) => _THD_WithPhysicalSource(Path, _THD_FutureSource(),
		_THD_FuturePhysicalLeafOwned)))

_THD_InitialBooleanImage(TargetPath) {
	global TapHold
	_THD_Reset()
	TapHold["keys"]["caps_lock"]["enabled"] := false
	TapHold["keys"]["tab"] := Map("enabled", true, "tap_action", "copy", "hold_modifier", "alt",
		"time_activation_seconds", 0.45)
	SplitPath(TargetPath, , &Directory)
	DirCreate(Directory)
	try {
		AssertEqual(1, WriteTapHoldDuration("caps_lock", 0.375))
		Source := FSReadUtf8Exact(TargetPath)
		AssertEqual(Chr(0xFEFF), SubStr(Source, 1, 1), "a newly created complete image includes its BOM")
		Assert(!InStr(Source, "`r"), "the initial image uses LF")
		Document := TOML_ParseDocument(Source)
		Assert(Document["tap_hold"]["keys"]["caps_lock"]["enabled"] is TOML_Bool)
		AssertEqual(false, Document["tap_hold"]["keys"]["caps_lock"]["enabled"].Value)
		AssertEqual(true, Document["tap_hold"]["keys"]["tab"]["enabled"].Value)
		ReadBack := LoadTapHoldToml(TargetPath)
		AssertEqual("escape", ReadBack["keys"]["caps_lock"]["tap_action"], "missing-file creation retains the modeled tap")
		AssertEqual("ctrl", ReadBack["keys"]["caps_lock"]["hold_modifier"])
		AssertEqual("copy", ReadBack["keys"]["tab"]["tap_action"], "a first threshold edit preserves neighboring mappings")
		AssertEqual("alt", ReadBack["keys"]["tab"]["hold_modifier"])
	} finally {
		if FileExist(TargetPath)
			FileDelete(TargetPath)
		DirDelete(Directory)
	}
}
Test("tap-hold duration: absent-file publication preserves complete mappings and strict Boolean intent (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_InitialBooleanImage))

_THD_AliasAndNoOpSources(TargetPath) {
	global TapHold
	_THD_Reset()
	Sources := [
		Chr(0xFEFF) . '# root dotted leaf`ntap_hold.keys.caps_lock.time_activation_seconds = 0.2`nfuture = "001"`n',
		Chr(0xFEFF) . '["tap_hold"."keys"."caps_lock"] # quoted exact owner`ntime_activation_seconds = 0.2`nfuture_note = "001"`n',
		Chr(0xFEFF) . '[tap_hold]`nkeys = { caps_lock = { time_activation_seconds = 0.2, enabled = false }, tab = { tap_action = "copy" } }`n'
	]
	for Source in Sources {
		TapHold := _THGT_FreshState()
		AssertEqual(1, FSWriteDurable(TargetPath, Source))
		Expected := TOML_ParseDocument(Source)
		Expected["tap_hold"]["keys"]["caps_lock"]["time_activation_seconds"] := 0.375
		AssertEqual(1, WriteTapHoldDuration("caps_lock", 0.375), "quoted/dotted/inline source owners retain actual semantics")
		Assert(TOML_SameValue(Expected, TOML_ParseDocument(FSReadUtf8Exact(TargetPath))), "only the independent declared leaf changes")
		ReadBack := LoadTapHoldToml(TargetPath)
		AssertEqual(0.375, ReadBack["keys"]["caps_lock"]["time_activation_seconds"],
			"the actual restart-facing native reader recovers every admitted owned leaf")
		if Expected["tap_hold"]["keys"]["caps_lock"].Has("enabled")
			AssertEqual(false, ReadBack["keys"]["caps_lock"]["enabled"], "the inline Boolean is loaded from its own source")
		BeforeNoOp := FSReadUtf8Exact(TargetPath)
		AssertEqual(1, WriteTapHoldDuration("caps_lock", 0.375))
		Assert(FSUtf8ExactMatches(TargetPath, BeforeNoOp), "a true physical no-op preserves complete lexical bytes")
	}
}
Test("tap-hold duration: shared semantic owner qualifies aliases and byte-exact no-ops (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture((Path) => _THD_WithPhysicalSource(Path, _THD_FutureSource(),
		_THD_AliasAndNoOpSources)))

_THD_InvalidPhysicalSource(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces
	for Source in [
		Chr(0xFEFF) . 'tap_hold = 7 # retained scalar cannot become a table`n',
		Chr(0xFEFF) . '[[tap_hold.keys.caps_lock]]`nfuture = "generation"`n',
		Chr(0xFEFF) . '[tap_hold.keys.caps_lock]`ntime_activation_seconds = 0.2`ntime_activation_seconds = 0.3`n',
		Chr(0xFEFF) . '[tap_hold.keys.caps_lock]`ntime_activation_seconds = 0.2`nunclassified future record`n'
	] {
		_THD_Reset()
		TapHold := _THGT_FreshState()
		Before := TapHold
		AssertEqual(1, FSWriteDurable(TargetPath, Source))
		AssertEqual(false, _THD_Write(), "unsupported or malformed source has no admitted image")
		Assert(FSUtf8ExactMatches(TargetPath, Source), "source refusal preserves actual bytes")
		AssertEqual(ObjPtr(Before), ObjPtr(TapHold))
		AssertEqual(0, _THGT_Writes.Length, "source refusal precedes even the controlled stage")
		AssertEqual(0, _THGT_Replaces.Length)
	}
}
Test("tap-hold duration: source scalar/array collisions and opaque malformed records refuse before staging (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture((Path) => _THD_WithPhysicalSource(Path, _THD_FutureSource(),
		_THD_InvalidPhysicalSource)))

_THD_SourceRaceWriter(StagePath, Content) {
	global _THD_Mode
	_THGT_Writer(StagePath, Content)
	TargetPath := _TH_TapHoldConfigPath()
	if _THD_Mode == "source_delete"
		FileDelete(TargetPath)
	else
		AssertEqual(1, FSWriteDurable(TargetPath, Chr(0xFEFF) . 'future.owner = "successor"`n'))
	return 1
}

_THD_SourceRaceOwned(TargetPath) {
	global TapHold, _THD_Mode, _THGT_Replaces, _THGT_Deletes
	for Mode in ["source_replace", "source_delete", "source_create"] {
		_THD_Reset()
		TapHold := _THGT_FreshState()
		Before := TapHold
		if Mode == "source_create" {
			if FileExist(TargetPath)
				FileDelete(TargetPath)
		} else
			AssertEqual(1, FSWriteDurable(TargetPath, _THD_FutureSource()))
		_THD_Mode := Mode
		AssertEqual(false, WriteTapHoldDuration("caps_lock", 0.375, _THD_SourceRaceWriter,
			_THGT_Replace, _THGT_Delete, _THGT_Authorize))
		AssertEqual(0, _THGT_Replaces.Length, "stage callbacks cannot grant authority over foreign physical bytes")
		AssertEqual(1, _THGT_Deletes.Length, "the refused stage is retired through its owner")
		AssertEqual(ObjPtr(Before), ObjPtr(TapHold))
		if Mode == "source_delete"
			Assert(!FileExist(TargetPath), "the foreign deletion stays authoritative")
		else
			Assert(FSUtf8ExactMatches(TargetPath, Chr(0xFEFF) . 'future.owner = "successor"`n'))
	}
}
Test("tap-hold duration: physical create/delete/replace during staging cannot publish over a successor (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture((Path) => _THD_WithPhysicalSource(Path, _THD_FutureSource(),
		_THD_SourceRaceOwned)))

_THD_PromptParentAndPhysicalWithdrawal(TargetPath) {
	global TapHold, _THD_Mode, _THD_Setters, _THD_Reloads
	for Mode in ["prompt_keys_revoke", "prompt_entry_revoke", "prompt_entry_mutate",
		"prompt_source_replace", "prompt_source_delete", "prompt_source_create", "prompt_master_rebase"] {
		_THD_Reset()
		TapHold := _THGT_FreshState()
		if Mode == "prompt_source_create" {
			if FileExist(TargetPath)
				FileDelete(TargetPath)
		} else
			AssertEqual(1, FSWriteDurable(TargetPath, _THD_FutureSource()))
		_THD_Mode := Mode
		AssertEqual(false, _THD_Ask(), "open prompts cannot target a successor key/parent/source")
		AssertEqual(0, _THD_Setters.Length)
		AssertEqual(0, _THD_Reloads.Length)
	}
}
Test("tap-hold duration: open prompts preserve key/parent identity and actual physical source authority (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture((Path) => _THD_WithPhysicalSource(Path, _THD_FutureSource(),
		_THD_PromptParentAndPhysicalWithdrawal)))






_THD_WitnessCannotRedirectKey(TargetPath) {
	global TapHold, _THGT_Writes, _THGT_Replaces
	_THD_Reset()
	Before := TapHold
	Witness := _TH_CaptureDurationContext(_TH_CaptureDurationSource(TargetPath), "caps_lock")
	AssertEqual(false, WriteTapHoldDuration("tab", 0.375, _THGT_Writer,
		_THGT_Replace, _THGT_Delete, _THGT_Authorize, Witness),
		"a captured key witness cannot authorize a different catalogued key")
	AssertEqual(0, _THGT_Writes.Length)
	AssertEqual(0, _THGT_Replaces.Length)
	AssertEqual(ObjPtr(Before), ObjPtr(TapHold))
	Assert(!TapHold["keys"].Has("tab"))
}
Test("tap-hold duration: physical witness remains bound to its captured catalogue key (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_WitnessCannotRedirectKey))

_THD_AcknowledgementCannotReloadSuccessor(TargetPath) {
	global _ConfigDir, _THD_Mode, _THD_Result, _THD_Reloads
	OriginalDir := _ConfigDir
	try {
		for Mode in ["setter_rebase_after", "setter_successor_after", "setter_result",
			"setter_same_threshold_entry", "setter_same_threshold_keys", "setter_same_threshold_parent"] {
			_ConfigDir := OriginalDir
			_THD_Reset()
			_THD_Mode := Mode
			_THD_Result := 1
			AssertEqual(false, _THD_Ask(), "strict acknowledgement does not grant reload authority over a successor")
			AssertEqual(0, _THD_Reloads.Length)
		}
	} finally _ConfigDir := OriginalDir
}
Test("tap-hold duration: post-save acknowledgement cannot reload a successor key or parent (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_AcknowledgementCannotReloadSuccessor))






_THD_PhysicalSuccessorDoesNotReload(TargetPath) {
	global _THD_Mode, _THD_Reloads
	_THD_Reset()
	_THD_Mode := "setter_physical_source_after"
	AssertEqual(false, _THD_Ask(), "native publication cannot authorize reload of foreign replacement bytes")
	AssertEqual(0, _THD_Reloads.Length)
	Assert(FSUtf8ExactMatches(TargetPath, Chr(0xFEFF) . 'future.owner = "successor"`n'))
}
Test("tap-hold duration: real post-save source replacement withdraws reload authority (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture((Path) => _THD_WithPhysicalSource(Path, _THD_FutureSource(),
		_THD_PhysicalSuccessorDoesNotReload)))



_THD_ReceiptPhysicalGate(Receipt, Path) {
	global TapHold, _THD_Mode, _THD_Result
	AssertEqual(0, A_IsCritical, "the physical admission seam executes outside Critical")
	AssertEqual(Path, Receipt["path"])
	if _THD_Mode == "receipt_entry_successor"
		TapHold["keys"]["caps_lock"] := _TH_CloneData(TapHold["keys"]["caps_lock"])
	if _THD_Mode == "receipt_keys_successor"
		TapHold["keys"] := _TH_CloneData(TapHold["keys"])
	if _THD_Mode == "receipt_parent_successor"
		TapHold := _TH_CloneData(TapHold)
	if _THD_Mode == "receipt_throw"
		throw Error("injected physical admission failure")
	return _THD_Result
}

_THD_ReceiptRepeatsOwnerAfterPhysicalAdmission(TargetPath) {
	global TapHold, _THD_Mode, _THD_Result
	for Mode in ["ok", "receipt_entry_successor", "receipt_keys_successor", "receipt_parent_successor",
		"receipt_false", "receipt_nil", "receipt_string", "receipt_throw"] {
		_THD_Reset()
		TapHold := _THGT_FreshState()
		Source := _TH_CaptureDurationContext(_TH_CaptureDurationSource(TargetPath), "caps_lock")
		AssertEqual(1, _THD_Write("caps_lock", 0.375, Source), "the actual publisher produces the exact owner receipt")
		Assert(Source.Has("published_context"))
		Source["published_context"]["physical"] := 1
		_THD_Mode := Mode
		_THD_Result := Mode == "receipt_false" ? 0 : Mode == "receipt_nil" ? "" : Mode == "receipt_string" ? "1" : 1
		AssertEqual(Mode == "ok", _TH_DurationReceiptMatches(Source, TargetPath, "caps_lock", 0.375,
			_THD_ReceiptPhysicalGate), "same-value successors during physical admission withdraw reload authority")
		AssertEqual(0.375, TapHold["keys"]["caps_lock"]["time_activation_seconds"], "value equality alone does not certify ownership")
	}
}
Test("tap-hold duration: final physical admission repeats exact published owner checks (tap-hold-key-delay)",
	() => _THHS_WithNativeFixture(_THD_ReceiptRepeatsOwnerAfterPhysicalAdmission))
