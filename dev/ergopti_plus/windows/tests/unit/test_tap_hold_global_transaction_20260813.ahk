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
		"layers", Map(
			"nav", Map("description_key", "tap_hold.layer.nav")),
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
			AssertEqual(0, TapHold["layers"].Count)
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
