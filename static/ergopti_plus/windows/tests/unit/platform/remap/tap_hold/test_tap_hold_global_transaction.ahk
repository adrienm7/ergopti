; tests/unit/platform/remap/tap_hold/test_tap_hold_global_transaction.ahk

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
			AssertEqual("", TapHold["keys"]["caps_lock"].Get("hold_modifier", ""),
				"native mode retains no active modifier regardless of inherited defaults")
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


; These public setters own one leaf, while their ordinary writer serializes RAM.
; A later physical edit to another key must survive or cause an unchanged refusal.
_THSO_Source(OtherAction) {
	return "[_meta]`n" . "schema_version = " . TapHoldMigrationRegistry()["current"] . "`n"
		. "[tap_hold]`ninherit_defaults = false`n"
		. '[tap_hold.keys.caps_lock]`ntap_action = "escape"`nhold_modifier = "ctrl"`n'
		. '[tap_hold.keys.tab]`ntap_action = "' . OtherAction . '"`nhold_modifier = "alt"`n'
}

_THSO_ActualSourceOwned(Mode, ReloadCurrent, TargetPath) {
	global TapHold, _TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "the fixture exclusively owns its private directory")
	try {
		SourceA := _THSO_Source("copy")
		SourceB := _THSO_Source("enter")
		AssertEqual(1, FSWriteCreateDurable(TargetPath, SourceA))
		TapHold := LoadTapHoldToml(TargetPath)
		AssertEqual("copy", TapHold["keys"]["tab"]["tap_action"], "the real loader admits source A")
		AssertEqual(1, FSWriteDurable(TargetPath, SourceB))
		Assert(FSUtf8ExactMatches(TargetPath, SourceB), "the independent external edit B is durable before the public setter")
		if ReloadCurrent {
			for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
				if Cache.Has(TargetPath)
					Cache.Delete(TargetPath)
			TapHold := LoadTapHoldToml(TargetPath)
			AssertEqual("enter", TapHold["keys"]["tab"]["tap_action"], "the control really reloads B through the owner")
		}
		Before := TapHold
		Result := Mode == "tap" ? WriteTapHoldTap("caps_lock", "enter")
			: WriteTapHoldGlobalDuration(0.425)
		Actual := FSReadUtf8Exact(TargetPath)
		Document := TOML_ParseDocument(Actual)
		Other := Document["tap_hold"]["keys"]["tab"]["tap_action"]
		try FileAppend("# tap-hold source: mode=" . Mode . ", reload=" . ReloadCurrent
			. ", result=" . Result . ", other=" . Other . ", same_ram=" . (Before == TapHold) . "`n", "*")
		if (Result is Integer) && Result == 1 {
			AssertEqual("enter", Other, "saving one leaf cannot erase the other key's durable external update")
			AssertEqual("enter", TapHold["keys"]["tab"]["tap_action"], "the acknowledged runtime projection agrees with the retained other key")
			if Mode == "tap"
				AssertEqual("enter", Document["tap_hold"]["keys"]["caps_lock"]["tap_action"])
			else
				AssertEqual(0.425, Document["tap_hold"]["time_activation_seconds"])
		} else {
			Assert(!ReloadCurrent, "an explicitly reloaded current source remains writable")
			Assert((Result is Integer) && Result == 0, "a stale owner may refuse strictly")
			Assert(FSUtf8ExactMatches(TargetPath, SourceB), "refusal retains all physical bytes of B")
			Assert(Before == TapHold, "refusal cannot publish a candidate")
		}
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}

_THSO_ActualSource(Mode, ReloadCurrent) {
	return _THHS_WithNativeFixture(_THSO_ActualSourceOwned.Bind(Mode, ReloadCurrent))
}
Test("tap-hold source: public tap preserves another externally edited key (tap-hold-external-source)",
	() => _THSO_ActualSource("tap", false))
Test("tap-hold source: public global delay preserves another externally edited key (tap-hold-external-source)",
	() => _THSO_ActualSource("global", false))
Test("tap-hold source: genuinely reloaded tap control stays writable (tap-hold-external-source)",
	() => _THSO_ActualSource("tap", true))
Test("tap-hold source: genuinely reloaded global delay control stays writable (tap-hold-external-source)",
	() => _THSO_ActualSource("global", true))


_THSO_NativeInheritanceOwned(Inherit, TargetPath) {
	global TapHold, _SharedDir, _TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "the native-mode fixture exclusively owns its private root")
	try {
		Defaults := _SharedDir . "\tap_hold\data\defaults.toml"
		Source := "[_meta]`nschema_version = " . TapHoldMigrationRegistry()["current"]
			. "`n[tap_hold]`ninherit_defaults = " . (Inherit ? "true" : "false")
			. '`n[tap_hold.keys.caps_lock]`ntap_action = "enter"`nhold_modifier = "ctrl"`n'
		AssertEqual(1, FSWriteCreateDurable(TargetPath, Source))
		TapHold := LoadTapHoldToml(TargetPath, Defaults)
		AssertEqual("ctrl", TapHold["keys"]["caps_lock"]["hold_modifier"], "the real starting owner has an active hold")
		Result := WriteTapHoldNative("caps_lock")
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		Reloaded := LoadTapHoldToml(TargetPath, Defaults)
		Entry := Reloaded["keys"].Get("caps_lock", Map())
		Tap := Entry.Get("tap_action", ""), Modifier := Entry.Get("hold_modifier", ""), Layer := Entry.Get("hold_layer", "")
		_TestPrint("# tap-hold native inherit=" . Inherit . " result=" . Result . " reloaded_tap=" . Tap
			. " reloaded_modifier=" . Modifier . " reloaded_layer=" . Layer)
		AssertEqual(1, Result, "the real native command must complete before its roundtrip is judged")
		AssertEqual("", Tap, "native mode remains a native tap after reloading the actual file")
		AssertEqual("", Modifier, "native mode cannot revive a modifier from the shipped defaults")
		AssertEqual("", Layer, "native mode cannot revive a layer from the shipped defaults")
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}

_THSO_NativeInheritance(Inherit) {
	return _THHS_WithNativeFixture(_THSO_NativeInheritanceOwned.Bind(Inherit))
}
for _THSO_Inherit in [true, false]
	Test("tap-hold native: actual reload inheritance=" . _THSO_Inherit . " (tap-hold-native-inheritance)",
		_THSO_NativeInheritance.Bind(_THSO_Inherit))


_THST_ForeignStageOwned(Collision, TargetPath) {
	global TapHold, _TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "the staging fixture exclusively owns its private directory")
	Owner := FSWriteReplaceOwned, HadOwn := Owner.HasOwnProp("Call")
	if HadOwn
		SavedCall := Owner.GetOwnPropDesc("Call")
	Installed := false
	State := {hits: 0, stagePath: "", sentinelBytes: 0, createdSentinel: 0,
		originalEntered: 0, originalCompleted: 0, defaultPorts: false}
	Sentinel := "Foreign tap-hold stage: é😀 unchanged"
	Observe(This, Path, Content, Suffix, &Detail := "", StageFn := 0, BeforeFn := 0, AdmissionFn := 0, ReplaceExisting := true, &Publication := 0, FlushFn := 0) {
		StagePath := Path . Suffix
		Prefix := TargetPath . "." . A_ScriptHwnd . "-"
		Mine := (StagePath is String) && SubStr(StagePath, 1, StrLen(Prefix)) == Prefix
			&& RegExMatch(SubStr(StagePath, StrLen(Prefix) + 1), "^\d+\.tmp$")
		if Mine {
			State.hits += 1
			State.stagePath := StagePath
			State.defaultPorts := (StageFn is Integer) && StageFn == 0
				&& (FlushFn is Integer) && FlushFn == 0
				&& HasMethod(BeforeFn, "Call") && HasMethod(AdmissionFn, "Call")
			if Collision {
				State.createdSentinel := FSWriteCreateDurable(StagePath, Sentinel)
				AssertEqual(1, State.createdSentinel, "the competing exact stage must really be created exclusively")
				State.sentinelBytes := FSReadBytesStrict(StagePath)
			}
			State.originalEntered += 1
		}
		NativeResult := Func.Prototype.Call.Call(This, Path, Content, Suffix, &Detail, StageFn, BeforeFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn)
		if Mine
			State.originalCompleted += 1
		return NativeResult
	}
	try {
		Source := _THSO_Source("copy")
		AssertEqual(1, FSWriteCreateDurable(TargetPath, Source))
		TapHold := LoadTapHoldToml(TargetPath)
		AssertEqual("escape", TapHold["keys"]["caps_lock"]["tap_action"], "the production loader establishes the initial live owner")
		BeforeOwner := TapHold, Before := FSReadBytesStrict(TargetPath)
		Owner.DefineProp("Call", {Call: Observe})
		Installed := true
		Result := WriteTapHoldTap("caps_lock", "enter")
		After := FSReadBytesStrict(TargetPath)
		StagePresent := State.stagePath != "" && FSStrictExists(State.stagePath)
		StageBytes := StagePresent ? FSReadBytesStrict(State.stagePath) : Buffer(0)
		_TestPrint("# tap-hold-stage collision=" . Collision . " calls=" . State.hits
			. " sentinel=" . State.createdSentinel . " original_entered=" . State.originalEntered
			. " original_completed=" . State.originalCompleted . " default_ports=" . State.defaultPorts
			. " result=" . Result . " stage_present=" . StagePresent
			. " before_bytes=" . Before.Size . " after_bytes=" . After.Size
			. " live_tap=" . TapHold["keys"]["caps_lock"]["tap_action"])
		AssertEqual(1, State.hits, "the public setter must reach the actual default staging producer")
		AssertTrue(State.defaultPorts, "no custom stage or flush replaces the real default producer; preflight and admission remain bound")
		AssertEqual(1, State.originalEntered, "the original default FSWriteReplaceOwned must really be entered")
		AssertEqual(1, State.originalCompleted, "its genuine return must reach the caller before business assertions")
		AssertEqual(Collision ? 1 : 0, State.createdSentinel)
		if Collision {
			AssertTrue(StagePresent, "the writer cannot adopt, rename, or delete another owner's stage")
			AssertEqual(State.sentinelBytes.Size, StageBytes.Size)
			AssertEqual(StageBytes.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", State.sentinelBytes,
				"Ptr", StageBytes, "UPtr", StageBytes.Size, "UPtr"), "foreign stage bytes remain exact")
			AssertFalse(Result, "a collision must refuse before live publication")
			AssertTrue(BeforeOwner == TapHold, "the refused candidate cannot replace the original runtime owner")
			AssertEqual("escape", TapHold["keys"]["caps_lock"]["tap_action"])
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "a collision cannot replace any target bytes")
		} else {
			AssertEqual(1, Result, "the actual default native publication remains functional without a collision")
			AssertFalse(StagePresent, "a successful move retires only its own complete stage")
			AssertEqual("enter", TapHold["keys"]["caps_lock"]["tap_action"])
			AssertEqual("enter", TOML_ParseDocument(FSReadUtf8Exact(TargetPath))["tap_hold"]["keys"]["caps_lock"]["tap_action"])
		}
	} finally {
		if Installed {
			if HadOwn
				Owner.DefineProp("Call", SavedCall)
			else
				Owner.DeleteProp("Call")
		}
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}

_THST_ForeignStage(Collision) {
	return _THHS_WithNativeFixture(_THST_ForeignStageOwned.Bind(Collision))
}
for _THST_Collision in [true, false]
	Test("tap-hold stage: foreign collision=" . _THST_Collision . " (tap-hold-stage-ownership)",
		_THST_ForeignStage.Bind(_THST_Collision))


_THSO_ExtraOwned(Mode, Scenario, TargetPath) {
	global TapHold, _SharedDir, _TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "the extra fixture exclusively owns its private root")
	StageCalls := 0, StageWritten := 0, SourceChanged := 0
	SourceC := _THSO_Source("escape")
	Stage(Path, Content) {
		StageCalls += 1
		StageWritten := FSWriteDurable(Path, Content)
		if (StageWritten is Integer) && StageWritten == 1
			SourceChanged := FSWriteDurable(TargetPath, SourceC)
		return StageWritten
	}
	try {
		Defaults := _SharedDir . "\tap_hold\data\defaults.toml"
		Source := Scenario == "inherited"
			? "[_meta]`nschema_version = " . TapHoldMigrationRegistry()["current"]
				. "`n[tap_hold]`ninherit_defaults = true`n"
			: _THSO_Source("copy")
		AssertEqual(1, FSWriteCreateDurable(TargetPath, Source))
		TapHold := LoadTapHoldToml(TargetPath, Defaults)
		Before := TapHold
		if Scenario == "inherited" {
			AssertEqual("enter", TapHold["keys"]["caps_lock"]["tap_action"], "the shipped tap really is inherited")
			AssertEqual("ctrl", TapHold["keys"]["caps_lock"]["hold_modifier"], "the shipped hold really is inherited")
			Result := Mode == "tap" ? WriteTapHoldTap("caps_lock", "enter")
				: WriteTapHoldHold("caps_lock", Map("kind", "modifier", "id", "ctrl"))
			Document := TOML_ParseDocument(FSReadUtf8Exact(TargetPath))
			_TestPrint("# tap-hold intent mode=" . Mode . " result=" . Result . " physical_key=" . Document["tap_hold"].Has("keys"))
			AssertEqual(1, Result)
			Field := Mode == "tap" ? "tap_action" : "hold_modifier"
			AssertEqual(Mode == "tap" ? "enter" : "ctrl", Document["tap_hold"]["keys"]["caps_lock"][Field],
				"choosing the inherited value still persists an explicit override")
			AssertEqual("alt_tab_monitor", TapHold["keys"]["tab"]["tap_action"], "publishing the sparse edit retains other inherited runtime keys")
		} else {
			SourceB := _THSO_Source("enter")
			AssertEqual(1, FSWriteDurable(TargetPath, SourceB))
			Result := Mode == "tap" ? WriteTapHoldTap("caps_lock", "enter", Stage)
				: WriteTapHoldGlobalDuration(0.425, Stage)
			_TestPrint("# tap-hold stage source mode=" . Mode . " result=" . Result . " calls=" . StageCalls
				. " staged=" . StageWritten . " changed=" . SourceChanged . " same_ram=" . (Before == TapHold))
			AssertEqual(1, StageCalls, "the actual public writer must reach the physical stage cutpoint")
			AssertEqual(1, StageWritten, "the fixture really writes the complete candidate stage")
			AssertEqual(1, SourceChanged, "the independent successor C really becomes durable during staging")
			AssertFalse(Result, "the B candidate cannot acknowledge over successor C")
			Assert(FSUtf8ExactMatches(TargetPath, SourceC), "the actual C bytes remain untouched")
			Assert(Before == TapHold, "a physically refused candidate cannot publish RAM")
		}
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}

_THSO_Extra(Mode, Scenario) {
	return _THHS_WithNativeFixture(_THSO_ExtraOwned.Bind(Mode, Scenario))
}
for _THSO_Mode in ["tap", "hold"]
	Test("tap-hold source: explicit inherited " . _THSO_Mode . " remains persisted (tap-hold-source-intent)",
		_THSO_Extra.Bind(_THSO_Mode, "inherited"))
for _THSO_Mode in ["tap", "global"]
	Test("tap-hold source: stage-time successor blocks " . _THSO_Mode . " (tap-hold-source-successor)",
		_THSO_Extra.Bind(_THSO_Mode, "successor"))

; The live model can still inherit after an external deletion of its old file.
; Creating the first replacement must not revive the disabled default hold.
_THSO_FirstSaveNativeOwned(TargetPath) {
	global TapHold, _SharedDir, _TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots
	SplitPath(TargetPath, , &Root)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	Assert((Created is Integer) && Created == 1, "The private first-save directory must be acquired exclusively")
	try {
		Defaults := _SharedDir . "\tap_hold\data\defaults.toml"
		DefaultBytes := FSReadUtf8Exact(Defaults)
		AssertTrue(DefaultBytes is String && DefaultBytes != "", "The actual shared defaults must exist")
		AssertFalse(FileExist(TargetPath), "The actual target must be absent before the first save")
		TapHold := LoadTapHoldToml(Defaults)
		TapHold["inherit_defaults"] := true
		AssertEqual("enter", TapHold["keys"]["caps_lock"]["tap_action"])
		AssertEqual("ctrl", TapHold["keys"]["caps_lock"]["hold_modifier"], "The RAM model starts with the real inherited modifier")
		OtherTap := TapHold["keys"]["tab"]["tap_action"]
		Result := WriteTapHoldNative("caps_lock")
		Runtime := TapHold["keys"].Get("caps_lock", Map())
		RuntimeTap := Runtime.Get("tap_action", ""), RuntimeHold := Runtime.Get("hold_modifier", "")
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		Source := FSReadUtf8Exact(TargetPath)
		Document := TOML_ParseDocument(Source)
		Reloaded := LoadTapHoldToml(TargetPath, Defaults)
		Entry := Reloaded["keys"].Get("caps_lock", Map())
		_TestPrint("# tap-hold first-save-native result=" . Result . " runtime_tap=" . RuntimeTap
			. " runtime_hold=" . RuntimeHold . " reload_tap=" . Entry.Get("tap_action", "")
			. " reload_hold=" . Entry.Get("hold_modifier", "") . " defaults_unchanged=" . FSUtf8ExactMatches(Defaults, DefaultBytes))
		AssertEqual(1, Result, "The real native command must acknowledge the absent-target publication")
		AssertTrue(Document["tap_hold"]["inherit_defaults"] is TOML_Bool
			&& Document["tap_hold"]["inherit_defaults"].Value, "The actual first image retains inherited defaults")
		AssertEqual("", RuntimeTap, "The published runtime owns a native tap")
		AssertEqual("", RuntimeHold, "The published runtime owns no modifier")
		AssertEqual("", Runtime.Get("hold_layer", ""), "The published runtime owns no layer")
		AssertEqual("", Entry.Get("tap_action", ""), "The actual reload retains a native tap")
		AssertEqual("", Entry.Get("hold_modifier", ""), "The actual reload cannot inherit the old modifier")
		AssertEqual("", Entry.Get("hold_layer", ""), "The actual reload cannot inherit a layer")
		AssertEqual(OtherTap, Reloaded["keys"]["tab"]["tap_action"], "An unrelated recommended mapping remains intact")
		AssertTrue(FSUtf8ExactMatches(Defaults, DefaultBytes), "The shared defaults are read-only during this private test")
	} finally {
		for Cache in [_TomlFileCache, _ParseTomlCache, _ConfigTomlSnapshots]
			if Cache.Has(TargetPath)
				Cache.Delete(TargetPath)
		if Created
			DirDelete(Root, true)
	}
}
Test("tap-hold native: absent first save retains inherited neighbours without reviving the disabled hold (tap-hold-native-first-save)",
	() => _THHS_WithNativeFixture(_THSO_FirstSaveNativeOwned))
