; tests/unit/modules/hotstrings/personal/test_personal_toml_live_transactions.ahk

; ==============================================================================
; MODULE: Personal TOML Live Transaction Tests
; DESCRIPTION: Keep durable writes and live registry publication under one owner.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================================
; ===========================================================
; ======= 5/ Durable and live publication transaction =======
; ===========================================================
; ===========================================================

global _PTIOCR_LiveRegistry := Map()
global _PTIOCR_NestedData := false
global _PTIOCR_NestedArmed := false
global _PTIOCR_NestedAttempted := false
global _PTIOCR_NestedResult := true
global _PTIOCR_WriteCalls := 0
global _PTIOCR_WriterWasCritical := false
global _PTIOCR_ReloaderWasCritical := false
global _PTIOCR_MutateSource := false
global _PTIOCR_ReloadEvents := []
global _PTIOCR_OwnerIds := []
global _PTIOCR_CompletionResults := []
global _PTIOCR_CompletionOwnerIds := []
global _PTIOCR_FailOutput := ""
global _PTIOCR_FailRemaining := 0

_PTIOCR_FreshCommitState() {
	return {
		next_generation: 0,
		pending: false,
		owner_active: false,
		resync: false,
	}
}

_PTIOCR_RecordCompletion(Result) {
	global _PTIOCR_CompletionResults, _PTIOCR_CompletionOwnerIds
	_PTIOCR_CompletionResults.Push(Result)
	Owner := _ConfigWriteLeaseCurrent(PersonalTomlPath())
	_PTIOCR_CompletionOwnerIds.Push(Owner is Object ? Owner.id : 0)
}

_PTIOCR_Model(Label) {
	Sections := Map()
	for SectionName in ["alpha", "beta"] {
		Sections[SectionName] := Map(
			"description", SectionName,
			"entries", [Map(
				"trigger", Label . "-" . SectionName,
				"output", Label . "-" . SectionName,
				"is_word", false,
				"auto_expand", true,
				"is_case_sensitive", true,
				"final_result", false,
				"is_case_sensitive_strict", false,
				"priority", "",
			)]
		)
	}
	return Map(
		"meta_description", "Durable/live transaction test",
		"sections_order", ["alpha", "beta"],
		"sections", Sections,
	)
}

_PTIOCR_WriteStage(StagePath, Content) {
	global _PTIOCR_WriteCalls, _PTIOCR_WriterWasCritical
	global _PTIOCR_MutateSource, _PTIOCR_OwnerIds
	_PTIOCR_WriteCalls += 1
	_PTIOCR_WriterWasCritical := _PTIOCR_WriterWasCritical || A_IsCritical
	Owner := _ConfigWriteLeaseCurrent(PersonalTomlPath())
	_PTIOCR_OwnerIds.Push(Owner is Object ? Owner.id : 0)
	FileAppend(Content, StagePath, "UTF-8-RAW")
	; Model a native GUI callback mutating its shared editor Map while the stage
	; writer yields. The owning transaction must reload its detached candidate.
	if _PTIOCR_MutateSource is Map {
		_PTIOCR_MutateSource["sections"]["alpha"]["entries"][1]["output"] := "mutated-alias"
		_PTIOCR_MutateSource := false
	}
	return true
}

_PTIOCR_Reload(Data, SectionName, FeatureConfig) {
	global _PTIOCR_LiveRegistry, _PTIOCR_ReloaderWasCritical
	global _PTIOCR_NestedData, _PTIOCR_NestedArmed
	global _PTIOCR_NestedAttempted, _PTIOCR_NestedResult
	global _PTIOCR_ReloadEvents, _PTIOCR_FailOutput, _PTIOCR_FailRemaining
	_PTIOCR_ReloaderWasCritical := _PTIOCR_ReloaderWasCritical || A_IsCritical
	Output := Data["sections"][SectionName]["entries"][1]["output"]
	if (_PTIOCR_FailRemaining > 0 && Output == _PTIOCR_FailOutput) {
		_PTIOCR_FailRemaining -= 1
		throw Error("injected live reload failure")
	}
	_PTIOCR_LiveRegistry[SectionName] := Output
	_PTIOCR_ReloadEvents.Push(Output)
	if _PTIOCR_NestedArmed {
		_PTIOCR_NestedArmed := false
		_PTIOCR_NestedAttempted := true
		_PTIOCR_NestedResult := PersonalTomlCommitAndReload(
			_PTIOCR_NestedData, 0, _PTIOCR_WriteStage.Bind(), 0, 0, 0,
			_PTIOCR_Reload.Bind(), _PTIOCR_RecordCompletion.Bind())
	}
}

_PTIOCR_AssertLiveEqualsDisk(DiskData, Label) {
	global _PTIOCR_LiveRegistry
	for SectionName in ["alpha", "beta"] {
		Expected := DiskData["sections"][SectionName]["entries"][1]["output"]
		AssertEqual(Expected, _PTIOCR_LiveRegistry[SectionName],
			Label . ": live section '" . SectionName
			. "' must describe the latest durable candidate")
	}
}

; A's stage write and reload both yield. B used to enter after A's writer
; released its private lease, durably replace the file, publish B, and return to
; A, whose remaining loop then republished A's stale suffix. The transaction
; seam forces that order without relying on timer timing.
_PTIOCR_ReentrantWriterCannotSplitDurableAndLivePublication() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _PTIOCR_LiveRegistry, _PTIOCR_NestedData, _PTIOCR_NestedArmed
	global _PTIOCR_NestedAttempted, _PTIOCR_NestedResult, _PTIOCR_WriteCalls
	global _PTIOCR_WriterWasCritical, _PTIOCR_ReloaderWasCritical
	global _PTIOCR_MutateSource, _PTIOCR_ReloadEvents, _PTIOCR_OwnerIds
	global _PTIOCR_CompletionResults, _PTIOCR_CompletionOwnerIds
	global _PTIOCR_FailOutput
	global _PTIOCR_FailRemaining
	global PERSONAL_TOML_COMMIT_DEFERRED, PERSONAL_TOML_COMMIT_OK
	Path := A_Temp . "\\ergopti_personal_live_transaction_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	OldCommitState := _PersonalTomlLiveCommitState()
	DataA := _PTIOCR_Model("A")
	DataB := _PTIOCR_Model("B")
	try {
		try FileDelete(Path)
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		_PTIOCR_LiveRegistry := Map()
		_PTIOCR_NestedData := DataB
		_PTIOCR_NestedArmed := true
		_PTIOCR_NestedAttempted := false
		_PTIOCR_NestedResult := true
		_PTIOCR_WriteCalls := 0
		_PTIOCR_WriterWasCritical := false
		_PTIOCR_ReloaderWasCritical := false
		_PTIOCR_MutateSource := DataA
		_PTIOCR_ReloadEvents := []
		_PTIOCR_OwnerIds := []
		_PTIOCR_CompletionResults := []
		_PTIOCR_CompletionOwnerIds := []
		_PTIOCR_FailOutput := ""
		_PTIOCR_FailRemaining := 0

		AssertEqual(PERSONAL_TOML_COMMIT_OK, PersonalTomlCommitAndReload(
			DataA, 0, _PTIOCR_WriteStage.Bind(), 0, 0, 0,
			_PTIOCR_Reload.Bind()))
		AssertTrue(_PTIOCR_NestedAttempted,
			"the injected B transaction must run inside A's live reload")
		AssertEqual(PERSONAL_TOML_COMMIT_DEFERRED, _PTIOCR_NestedResult,
			"B must be accepted for serialized publication while A owns the path")
		AssertEqual(2, _PTIOCR_WriteCalls,
			"A must synchronously drain the accepted B candidate before releasing its owner")
		AssertEqual(2, _PTIOCR_OwnerIds.Length)
		Assert(_PTIOCR_OwnerIds[1] != 0)
		AssertEqual(_PTIOCR_OwnerIds[1], _PTIOCR_OwnerIds[2],
			"A and its admitted B successor must stage under the exact same lease token")
		AssertEqual(1, _PTIOCR_CompletionResults.Length,
			"the caller that received DEFERRED must receive one terminal callback")
		AssertEqual(PERSONAL_TOML_COMMIT_OK, _PTIOCR_CompletionResults[1])
		AssertEqual(_PTIOCR_OwnerIds[1], _PTIOCR_CompletionOwnerIds[1],
			"the terminal callback must run before A releases the retained owner")
		DiskB := ReadPersonalToml()
		_PTIOCR_AssertLiveEqualsDisk(DiskB, "after the A then B interleaving")
		AssertEqual("B-beta", _PTIOCR_LiveRegistry["beta"])
		AssertEqual(4, _PTIOCR_ReloadEvents.Length,
			"both complete two-section candidates must publish without a mixed suffix")
		AssertEqual("A-alpha", _PTIOCR_ReloadEvents[1],
			"a mutation of the caller's model alias during staging must not alter A's detached snapshot")
		AssertEqual("A-beta", _PTIOCR_ReloadEvents[2])
		AssertEqual("B-alpha", _PTIOCR_ReloadEvents[3])
		AssertEqual("B-beta", _PTIOCR_ReloadEvents[4])
		AssertFalse(_PTIOCR_WriterWasCritical,
			"the logical owner must not turn filesystem staging into a Critical span")
		AssertFalse(_PTIOCR_ReloaderWasCritical,
			"the logical owner must not turn live registry publication into a Critical span")
		_PTIOP_AssertLeaseFree(Path,
			"the durable/live transaction must release its path owner")
	} finally {
		try FileDelete(Path)
		try _ParseTomlGroupConfig_InvalidatePath(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
		_PTIOCR_LiveRegistry := Map()
		_PTIOCR_NestedData := false
		_PTIOCR_NestedArmed := false
		_PTIOCR_MutateSource := false
		_PTIOCR_ReloadEvents := []
		_PTIOCR_OwnerIds := []
		_PTIOCR_CompletionResults := []
		_PTIOCR_CompletionOwnerIds := []
		_PTIOCR_FailOutput := ""
		_PTIOCR_FailRemaining := 0
		_PersonalTomlLiveCommitState(OldCommitState)
	}
}
Test("personal-toml-live-transaction: reentry cannot publish a stale registry suffix",
	_PTIOCR_ReentrantWriterCannotSplitDurableAndLivePublication)

global _PTIOCX_WriteCalls := 0
global _PTIOCX_ReplaceCalls := 0
global _PTIOCX_ReloadCalls := 0
global _PTIOCX_Mode := ""
global _PTIOCX_RelocatedPath := ""
global _PTIOCX_WriterWasCritical := false
global _PTIOCX_ReplacerWasCritical := false
global _PTIOCX_ReloaderWasCritical := false

_PTIOCX_Reset(Mode := "", RelocatedPath := "") {
	global _PTIOCX_WriteCalls, _PTIOCX_ReplaceCalls, _PTIOCX_ReloadCalls
	global _PTIOCX_Mode, _PTIOCX_RelocatedPath
	global _PTIOCX_WriterWasCritical, _PTIOCX_ReplacerWasCritical
	global _PTIOCX_ReloaderWasCritical
	_PTIOCX_WriteCalls := 0
	_PTIOCX_ReplaceCalls := 0
	_PTIOCX_ReloadCalls := 0
	_PTIOCX_Mode := Mode
	_PTIOCX_RelocatedPath := RelocatedPath
	_PTIOCX_WriterWasCritical := false
	_PTIOCX_ReplacerWasCritical := false
	_PTIOCX_ReloaderWasCritical := false
}

_PTIOCX_WriteStage(StagePath, Content) {
	global ScriptInformation
	global _PTIOCX_WriteCalls, _PTIOCX_Mode, _PTIOCX_RelocatedPath
	global _PTIOCX_WriterWasCritical
	_PTIOCX_WriteCalls += 1
	_PTIOCX_WriterWasCritical := _PTIOCX_WriterWasCritical || A_IsCritical
	FileAppend(Content, StagePath, "UTF-8-RAW")
	if (_PTIOCX_Mode == "suspend-stage")
		Suspend(1)
	else if (_PTIOCX_Mode == "relocate-stage")
		ScriptInformation["PersonalTomlPath"] := _PTIOCX_RelocatedPath
	return true
}

_PTIOCX_ReplaceStage(StagePath, TargetPath) {
	global ScriptInformation
	global _PTIOCX_ReplaceCalls, _PTIOCX_Mode, _PTIOCX_RelocatedPath
	global _PTIOCX_ReplacerWasCritical
	_PTIOCX_ReplaceCalls += 1
	_PTIOCX_ReplacerWasCritical := _PTIOCX_ReplacerWasCritical || A_IsCritical
	Replaced := FSAtomicMoveReplace(StagePath, TargetPath)
	if Replaced && (_PTIOCX_Mode == "relocate-replace")
		ScriptInformation["PersonalTomlPath"] := _PTIOCX_RelocatedPath
	return Replaced
}

_PTIOCX_Reload(Data, SectionName, FeatureConfig) {
	global _PTIOCX_ReloadCalls, _PTIOCX_ReloaderWasCritical
	_PTIOCX_ReloadCalls += 1
	_PTIOCX_ReloaderWasCritical := _PTIOCX_ReloaderWasCritical || A_IsCritical
}

; A pause stops typing, not configuration (EDD-1, maintainer decision
; 2026-11-12): Suspend active before admission, or arriving while the complete
; stage is written, still publishes the save (edd1-paused-writes).
_PTIOCX_SuspendStillPublishes() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _PTIOCX_WriteCalls, _PTIOCX_ReplaceCalls, _PTIOCX_ReloadCalls
	global _PTIOCX_WriterWasCritical, _PTIOCX_ReplacerWasCritical
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_OK
	Path := A_Temp . "\\ergopti_personal_suspend_transaction_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Original := '[_meta]`ndescription = "old"`n'
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	OldCommitState := _PersonalTomlLiveCommitState()
	Data := _PTIOCR_Model("suspend")
	try {
		try FileDelete(Path)
		FileAppend(Original, Path, "UTF-8-RAW")
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())

		_PTIOCX_Reset()
		Suspend(1)
		AssertEqual(PERSONAL_TOML_COMMIT_OK,
			PersonalTomlCommitAndReload(Data, 0, _PTIOCX_WriteStage.Bind(),
				_PTIOCX_ReplaceStage.Bind(), 0, 0, _PTIOCX_Reload.Bind()))
		AssertEqual(1, _PTIOCX_WriteCalls,
			"a save received under Suspend is staged")
		AssertEqual(1, _PTIOCX_ReplaceCalls, "and replaces the file")
		AssertTrue(FileRead(Path, "UTF-8-RAW") != Original, "the suspended save is durable")
		Suspend(0)
		FileDelete(Path)
		FileAppend(Original, Path, "UTF-8-RAW")
		_ReadPersonalTomlCache := false

		_PTIOCX_Reset()
		TerminalBundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(TerminalBundle is Object)
		try {
			AssertEqual(PERSONAL_TOML_COMMIT_FAILED,
				PersonalTomlCommitAndReload(Data, 0,
					_PTIOCX_WriteStage.Bind(), _PTIOCX_ReplaceStage.Bind(),
					0, 0, _PTIOCX_Reload.Bind()))
			AssertEqual(0, _PTIOCX_WriteCalls,
				"a terminal barrier collision must fail now, never orphan DEFERRED work")
			AssertFalse(_PersonalTomlLiveCommitState().pending is Object)
		} finally _ConfigWriteTerminalRelease(TerminalBundle)

		_PTIOCX_Reset("suspend-stage")
		AssertEqual(PERSONAL_TOML_COMMIT_OK,
			PersonalTomlCommitAndReload(Data, 0, _PTIOCX_WriteStage.Bind(),
				_PTIOCX_ReplaceStage.Bind(), 0, 0, _PTIOCX_Reload.Bind()))
		AssertTrue(A_IsSuspended,
			"the injected stage seam places the final authorization under Suspend")
		AssertEqual(1, _PTIOCX_WriteCalls)
		AssertEqual(1, _PTIOCX_ReplaceCalls,
			"a suspension observed after staging still replaces the file")
		AssertTrue(FileRead(Path, "UTF-8-RAW") != Original)
		AssertFalse(_PTIOCX_WriterWasCritical,
			"the owner must not make staging Critical")
		AssertFalse(_PTIOCX_ReplacerWasCritical)
		_PTIOP_AssertLeaseFree(Path,
			"every suspended save must release the personal path owner")
	} finally {
		if A_IsSuspended
			Suspend(0)
		try FileDelete(Path)
		try _ParseTomlGroupConfig_InvalidatePath(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
		_PersonalTomlLiveCommitState(OldCommitState)
		_PTIOCX_Reset()
	}
}
Test("personal-toml-live-transaction: Suspend still publishes the save (edd1-paused-writes)",
	_PTIOCX_SuspendStillPublishes)

; A path relocation after request capture must be observed both before atomic
; replacement and again before the matching live registry projection.
_PTIOCX_PathIsRevalidatedAfterStageAndBeforeReload() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _PTIOCX_ReplaceCalls, _PTIOCX_ReloadCalls
	global _PTIOCX_WriterWasCritical, _PTIOCX_ReplacerWasCritical
	global _PTIOCX_ReloaderWasCritical, PERSONAL_TOML_COMMIT_FAILED
	Suffix := A_ScriptHwnd . "_" . A_TickCount . ".toml"
	PathA := A_Temp . "\\ergopti_personal_path_a_" . Suffix
	PathB := A_Temp . "\\ergopti_personal_path_b_" . Suffix
	OriginalA := '[_meta]`ndescription = "old-a"`n'
	OriginalB := '[_meta]`ndescription = "old-b"`n'
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	OldCommitState := _PersonalTomlLiveCommitState()
	Data := _PTIOCR_Model("path")
	try {
		for Path in [PathA, PathB]
			try FileDelete(Path)
		FileAppend(OriginalA, PathA, "UTF-8-RAW")
		FileAppend(OriginalB, PathB, "UTF-8-RAW")
		ScriptInformation["PersonalTomlPath"] := PathA
		_ReadPersonalTomlCache := false
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())

		_PTIOCX_Reset("relocate-stage", PathB)
		AssertEqual(PERSONAL_TOML_COMMIT_FAILED,
			PersonalTomlCommitAndReload(Data, 0, _PTIOCX_WriteStage.Bind(),
				_PTIOCX_ReplaceStage.Bind(), 0, 0, _PTIOCX_Reload.Bind()))
		AssertEqual(0, _PTIOCX_ReplaceCalls,
			"a stage produced for the old path must not replace it after relocation")
		AssertEqual(0, _PTIOCX_ReloadCalls)
		AssertEqual(OriginalA, FileRead(PathA, "UTF-8-RAW"))
		AssertEqual(OriginalB, FileRead(PathB, "UTF-8-RAW"))
		AssertFalse(_PersonalTomlLiveCommitState().resync is Object,
			"a pre-replacement refusal has no durable/live mismatch to retry")

		ScriptInformation["PersonalTomlPath"] := PathA
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())
		_PTIOCX_Reset("relocate-replace", PathB)
		AssertEqual(PERSONAL_TOML_COMMIT_FAILED,
			PersonalTomlCommitAndReload(Data, 0, _PTIOCX_WriteStage.Bind(),
				_PTIOCX_ReplaceStage.Bind(), 0, 0, _PTIOCX_Reload.Bind()))
		AssertEqual(1, _PTIOCX_ReplaceCalls,
			"the injected relocation occurs only after the durable atomic replace")
		AssertEqual(0, _PTIOCX_ReloadCalls,
			"bytes committed to an old path must never project into the new path's HSE")
		Assert(FileRead(PathA, "UTF-8-RAW") != OriginalA,
			"the post-replace case must prove a durable commit actually occurred")
		AssertEqual(OriginalB, FileRead(PathB, "UTF-8-RAW"))
		Resync := _PersonalTomlLiveCommitState().resync
		AssertTrue(Resync is Object,
			"a durable commit refused before live reload must retain an owned resync")
		AssertEqual(_ConfigWriteLeaseKey(PathA),
			_ConfigWriteLeaseKey(Resync.FilePath))
		AssertFalse(_PTIOCX_WriterWasCritical)
		AssertFalse(_PTIOCX_ReplacerWasCritical,
			"atomic filesystem replacement must remain outside Critical")
		AssertFalse(_PTIOCX_ReloaderWasCritical)
		_PTIOP_AssertLeaseFree(PathA,
			"the path-change failure must release its exact owner")
	} finally {
		for Path in [PathA, PathB] {
			try FileDelete(Path)
			try _ParseTomlGroupConfig_InvalidatePath(Path)
		}
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
		_PersonalTomlLiveCommitState(OldCommitState)
		_PTIOCX_Reset()
	}
}
Test("personal-toml-live-transaction: exact path is revalidated after every durable yield",
	_PTIOCX_PathIsRevalidatedAfterStageAndBeforeReload)

; B receives DEFERRED while A owns the callback stack. If B's durable commit is
; followed by a persistent reload failure, its UI completion must receive FAILED
; once and the candidate must remain available for an owned resync on next use.
_PTIOCR_DeferredReloadFailureIsVisibleAndRetryable() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _PTIOCR_LiveRegistry, _PTIOCR_NestedData, _PTIOCR_NestedArmed
	global _PTIOCR_NestedAttempted, _PTIOCR_NestedResult, _PTIOCR_WriteCalls
	global _PTIOCR_WriterWasCritical, _PTIOCR_ReloaderWasCritical
	global _PTIOCR_MutateSource, _PTIOCR_ReloadEvents, _PTIOCR_OwnerIds
	global _PTIOCR_CompletionResults, _PTIOCR_CompletionOwnerIds
	global _PTIOCR_FailOutput
	global _PTIOCR_FailRemaining
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_DEFERRED
	global PERSONAL_TOML_COMMIT_OK
	Path := A_Temp . "\\ergopti_personal_reload_recovery_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	OldCommitState := _PersonalTomlLiveCommitState()
	DataA := _PTIOCR_Model("A")
	DataB := _PTIOCR_Model("B")
	DataC := _PTIOCR_Model("C")
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		_ReadPersonalTomlCache := false
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())
		_PTIOCR_LiveRegistry := Map()
		_PTIOCR_NestedData := DataB
		_PTIOCR_NestedArmed := true
		_PTIOCR_NestedAttempted := false
		_PTIOCR_NestedResult := true
		_PTIOCR_WriteCalls := 0
		_PTIOCR_WriterWasCritical := false
		_PTIOCR_ReloaderWasCritical := false
		_PTIOCR_MutateSource := false
		_PTIOCR_ReloadEvents := []
		_PTIOCR_OwnerIds := []
		_PTIOCR_CompletionResults := []
		_PTIOCR_CompletionOwnerIds := []
		_PTIOCR_FailOutput := "B-beta"
		_PTIOCR_FailRemaining := 2

		AssertEqual(PERSONAL_TOML_COMMIT_OK, PersonalTomlCommitAndReload(
			DataA, 0, _PTIOCR_WriteStage.Bind(), 0, 0, 0,
			_PTIOCR_Reload.Bind()))
		AssertEqual(PERSONAL_TOML_COMMIT_DEFERRED, _PTIOCR_NestedResult)
		AssertEqual(1, _PTIOCR_CompletionResults.Length,
			"a deferred reload failure must not disappear into the file logger")
		AssertEqual(PERSONAL_TOML_COMMIT_FAILED,
			_PTIOCR_CompletionResults[1])
		AssertEqual(_PTIOCR_OwnerIds[1], _PTIOCR_CompletionOwnerIds[1],
			"the FAILED callback must run while the same owner still fences terminal reload")
		AssertEqual(2, _PTIOCR_WriteCalls)
		AssertEqual(_PTIOCR_OwnerIds[1], _PTIOCR_OwnerIds[2],
			"the failed B reload must still run under A's retained owner")
		AssertEqual("A-beta", _PTIOCR_LiveRegistry["beta"],
			"the injected failure must leave an observable disk/live mismatch")
		DiskB := ReadPersonalToml()
		AssertEqual("B-beta",
			DiskB["sections"]["beta"]["entries"][1]["output"])
		State := _PersonalTomlLiveCommitState()
		AssertTrue(State.resync is Object,
			"a persistent reload failure must retain the exact durable snapshot")
		AssertFalse(State.HasOwnProp("timer_armed"),
			"resync and deferred publication must not poll on a timer")

		_PTIOCR_NestedArmed := false
		_PTIOCR_FailRemaining := 0
		AssertEqual(PERSONAL_TOML_COMMIT_OK, PersonalTomlCommitAndReload(
			DataC, 0, _PTIOCR_WriteStage.Bind(), 0, 0, 0,
			_PTIOCR_Reload.Bind()))
		AssertFalse(_PersonalTomlLiveCommitState().resync is Object,
			"the next owned action must reconcile the retained durable snapshot before publishing C")
		DiskC := ReadPersonalToml()
		_PTIOCR_AssertLiveEqualsDisk(DiskC,
			"after the owned resync and subsequent C publication")
		AssertEqual("C-beta", _PTIOCR_LiveRegistry["beta"])
		AssertEqual(3, _PTIOCR_WriteCalls,
			"resync reloads retained bytes without rewriting them, then commits C once")
		AssertFalse(_PTIOCR_WriterWasCritical)
		AssertFalse(_PTIOCR_ReloaderWasCritical)
		_PTIOP_AssertLeaseFree(Path,
			"reload recovery must release the retained path owner")
	} finally {
		try FileDelete(Path)
		try _ParseTomlGroupConfig_InvalidatePath(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
		_PTIOCR_LiveRegistry := Map()
		_PTIOCR_NestedData := false
		_PTIOCR_NestedArmed := false
		_PTIOCR_MutateSource := false
		_PTIOCR_ReloadEvents := []
		_PTIOCR_OwnerIds := []
		_PTIOCR_CompletionResults := []
		_PTIOCR_CompletionOwnerIds := []
		_PTIOCR_FailOutput := ""
		_PTIOCR_FailRemaining := 0
		_PersonalTomlLiveCommitState(OldCommitState)
	}
}
Test("personal-toml-live-transaction: deferred reload failure is visible and retains owned resync",
	_PTIOCR_DeferredReloadFailureIsVisibleAndRetryable)

; Guard the sibling call sites as a class: a correct gateway is inert if one
; editor returns to the old write-then-reload split sequence.
_PTIOCR_AllEditorsUseTheDurableLiveGateway() {
	; The WebView editor is the only personal-hotstring editor on Windows.
	WebBody := _DriverFuncBody("_HsEdWeb_Save")
	Assert(WebBody != "", "_HsEdWeb_Save must exist in the driver source")
	Assert(InStr(WebBody, "PersonalTomlCommitAndReload(") > 0,
		"_HsEdWeb_Save must delegate durable and live publication to the shared gateway")
	Assert(InStr(WebBody, "WritePersonalToml(") == 0,
		"_HsEdWeb_Save must not release path ownership before its live reload")
	Assert(InStr(WebBody, "ReloadPersonalSection(") == 0,
		"_HsEdWeb_Save must not own a second, reentrant reload loop")
	Assert(InStr(WebBody, "_HsEdWeb_DeferredSaveCompleted") > 0,
		"the WebView editor must receive a terminal result after DEFERRED")
	FailureBody := _DriverFuncBody("_HsEdWeb_ReportSaveFailure")
	Assert(FailureBody != "",
		"the WebView deferred failure reporter must exist")
	Assert(InStr(FailureBody, "NotifierSend") > 0,
		"a deferred WebView failure must be user-visible, not only logged")
	WebMessageBody := _DriverFuncBody("_HsEdWeb_OnWebMessage")
	Assert(WebMessageBody != "")
	; A pause stops typing, not configuration (EDD-1, edd1-paused-writes).
	Assert(InStr(WebMessageBody, "A_IsSuspended") == 0,
		"a WebView save received under Suspend is handled like any other")
	ShowFailureBody := _DriverFuncBody("_HsEdWeb_ShowSaveFailure")
	Assert(ShowFailureBody != "")
	; The failure script is built by one owner the reporter delegates to.
	FailureJsBody := _DriverFuncBody("_HsEdWeb_SaveFailureJs")
	Assert(InStr(ShowFailureBody, "_HsEdWeb_SaveFailureJs(") > 0 && InStr(FailureJsBody, "save-toast") > 0,
		"a refused save must replace the page's optimistic saved toast")
	for FunctionName in ["_PersonalTomlQueueLiveRequest",
			"_PersonalTomlTryPublishRequest",
			"_PersonalTomlPublishRequestOwned"] {
		Body := _DriverFuncBody(FunctionName)
		Assert(Body != "", FunctionName . " must exist")
		Assert(InStr(Body, "SetTimer") == 0,
			FunctionName . " must not turn accepted save or resync work into timer polling")
	}
	QueueBody := _DriverFuncBody("_PersonalTomlQueueLiveRequest")
	Assert(InStr(QueueBody, "Request.CompletionFn") > 0,
		"the gateway must refuse DEFERRED when no terminal callback can report its outcome")
}
Test("personal-toml-live-transaction: the WebView save uses the shared gateway",
	_PTIOCR_AllEditorsUseTheDurableLiveGateway)

; The refusal toast script must splice the complete JSON literal bare: a second
; pair of quotes turned it into `e.textContent=""..."";`, a SyntaxError that left
; the optimistic "Saved" toast visible after a refused save (audit WVB-001).
_PTIOCR_SaveFailureScriptIsValidJs() {
	Message := 'Écriture "refusée"\n'
	Script := _HsEdWeb_SaveFailureJs(Message)
	Assert(InStr(Script, "e.textContent=" . JsonStringLiteral(Message) . ";", true) > 0,
		"the refusal toast must assign the exact message as one string literal: " . Script)
	Assert(InStr(Script, '=""', true) == 0 && InStr(Script, '"";', true) == 0,
		"the refusal toast must not wrap the literal in a second pair of quotes: " . Script)
	ShowBody := _DriverFuncBody("_HsEdWeb_ShowSaveFailure")
	Assert(ShowBody != "", "_HsEdWeb_ShowSaveFailure must exist")
	Assert(InStr(ShowBody, "_HsEdWeb_SaveFailureJs(") > 0,
		"the displayed refusal must use the tested script builder")
}
Test("personal-toml-live-transaction: refused-save toast script is valid JavaScript (wvb-001)",
	_PTIOCR_SaveFailureScriptIsValidJs)

_PTIO_PriorityDomainRejectsInvalidCandidate() {
	global ScriptInformation, _ReadPersonalTomlCache
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	Path := A_Temp . "\ergopti_personal_priority_domain_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	try {
		try FileDelete(Path)
		ScriptInformation["PersonalTomlPath"] := Path
		for Invalid in [101, "50", 1.5] {
			Candidate := _PTIOCR_Model("invalid-priority")
			Candidate["sections"]["alpha"]["entries"][1]["priority"] := Invalid
			AssertFalse(WritePersonalToml(Candidate),
				"the full-model writer must reject an invalid per-entry priority")
			AssertFalse(FileExist(Path),
				"an invalid priority candidate must not create durable bytes")
		}
	} finally {
		try FileDelete(Path)
		try _ParseTomlGroupConfig_InvalidatePath(Path)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal TOML: priority domain rejects invalid writer candidates",
	_PTIO_PriorityDomainRejectsInvalidCandidate)

; Opening-source consent uses actual private files, the ordinary durable owner,
; and a hidden Gui as the WebView editor window. Callback bodies collect facts,
; never assert.
_PT102_CaptureOpening(Source) {
	if ReadPersonalToml.MaxParams >= 2
		return ReadPersonalToml(false, Source)
	; Original-driver comparison port: the old reader is called exactly as it
	; was by the editor. This test-only receipt is never consumed by old code.
	Data := ReadPersonalToml()
	Present := FSStrictExists(PersonalTomlPath())
	Source["admitted"] := true
	Source["path"] := PersonalTomlPath()
	Source["present"] := Present
	Source["content"] := Present ? FSReadUtf8Exact(PersonalTomlPath()) : ""
	return Data
}

_PT102_Stage(Context, StagePath, Content) {
	Context.stages += 1
	Context.stage_critical := Context.stage_critical || A_IsCritical
	Context.stage_paths.Push(StagePath)
	Written := FSWriteDurable(StagePath, Content)
	if Context.mode == "stage-foreign"
		Context.foreign_ack := FSWriteDurable(Context.path, Context.foreign)
	else if Context.mode == "stage-close"
		_HsEdWeb_Close(Context.window)
	return Written
}

_PT102_Replace(Context, StagePath, TargetPath) {
	Context.replaces += 1
	Context.replace_critical := Context.replace_critical || A_IsCritical
	if Context.mode == "rename-lock" {
		Handle := DllCall("Kernel32\CreateFileW", "Str", TargetPath, "UInt", 0x80000000,
			"UInt", 1, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		Context.lock_acquired := Handle != -1 && Handle != 0
		Context.lock_handle := Context.lock_acquired ? Handle : 0
		if Context.lock_acquired
			Context.handle_owner[Context.path] := Handle
		if !Context.lock_acquired
			return false
		try return FSAtomicMoveReplace(StagePath, TargetPath)
		finally {
			Context.lock_closed := DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
			if Context.lock_closed {
				Context.lock_handle := 0
				Context.handle_owner.Delete(Context.path)
			}
		}
	}
	return FSAtomicMoveReplace(StagePath, TargetPath)
}

_PT102_Authorize(Context) {
	Context.authorizes += 1
	if Context.mode == "authorize-foreign"
		Context.foreign_ack := FSWriteDurable(Context.path, Context.foreign)
	return true
}

_PT102_Terminal(Context, Result) {
	Context.terminals.Push(Result)
	Owner := _ConfigWriteLeaseCurrent(Context.path)
	Context.terminal_owner_ids.Push(Owner is Object ? Owner.id : 0)
}

_PT102_Reload(Context, Data, SectionName, FeatureConfig) {
	Context.reloads += 1
	Context.reload_critical := Context.reload_critical || A_IsCritical
	if Context.fail_remaining > 0 {
		Context.fail_remaining -= 1
		throw Error("controlled opening-source reload refusal")
	}
	Context.live[SectionName] := Data["sections"][SectionName]["entries"][1]["output"]
	if Context.queue_pending {
		Context.queue_pending := false
		Context.queued_result := _PT102_Commit(Context, _PTIOCR_Model("B"), true)
	}
}

_PT102_Commit(Context, Data, Deferred := false) {
	Args := [Data, 0, _PT102_Stage.Bind(Context), _PT102_Replace.Bind(Context),
		0, _PT102_Authorize.Bind(Context), _PT102_Reload.Bind(Context),
		Deferred ? _PT102_Terminal.Bind(Context) : 0, 0]
	if PersonalTomlCommitAndReload.MaxParams >= 10
		Args.Push(Context.source)
	return PersonalTomlCommitAndReload(Args*)
}

_PT102_WithCase(Mode, Body, OwnDirectory := false) {
	global ScriptInformation, _ReadPersonalTomlCache, _TomlUnreadableFiles
	global _HsEdWeb_Gui, _HsEdWeb_OpeningSource, _HsEdWeb_SessionEpoch, _HsEdWeb_ResetDone
	global _HsEdWeb_Controller, _HsEdWeb_WebView, _HsEdWeb_MsgSub, _HsEdWeb_NavSub
	static Sequence := 0, RetainedHandles := Map()
	if RetainedHandles.Count
		throw Error("controlled native handle debt blocks successor fixture")
	Sequence += 1
	Path := A_Temp . "\ergopti_opening_source_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Sequence . ".toml"
	Root := "", CreatedRoot := false
	if OwnDirectory {
		Root := A_Temp . "\ergopti_opening_owned_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Sequence
		Path := Root . "\personal_hotstrings.toml"
	}
	Names := ["_ReadPersonalTomlCache", "_TomlUnreadableFiles",
		"_HsEdWeb_Gui", "_HsEdWeb_OpeningSource", "_HsEdWeb_SessionEpoch", "_HsEdWeb_ResetDone",
		"_HsEdWeb_Controller", "_HsEdWeb_WebView", "_HsEdWeb_MsgSub", "_HsEdWeb_NavSub"]
	Saved := Map()
	for Name in Names {
		Had := IsSet(%Name%)
		Saved[Name] := Had ? {had: true, value: %Name%} : {had: false}
	}
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldState := _PersonalTomlLiveCommitState()
	OldSuspended := A_IsSuspended
	OldCritical := Critical("Off")
	Window := Gui()
	Context := {path: Path, window: Window, source: Map(), mode: Mode,
		foreign: "# independently changed source`r`n[_meta]`r`nfuture = 'preserve-me'`r`n",
		stages: 0, replaces: 0, reloads: 0, authorizes: 0, stage_paths: [],
		stage_critical: false, replace_critical: false, reload_critical: false,
		foreign_ack: false, terminals: [], terminal_owner_ids: [],
		lock_acquired: false, lock_closed: false, lock_handle: 0, handle_owner: RetainedHandles,
		live: Map(), fail_remaining: 0, queue_pending: false, queued_result: "unreached"}
	try {
		if OwnDirectory {
			Creation := FSCreateDirectoryExclusiveStrict(Root)
			CreatedRoot := (Creation is Integer) && Creation == 1
			AssertTrue(CreatedRoot, "The native partial-effect fixture owns its private directory exclusively")
		}
		Suspend(false)
		ScriptInformation["PersonalTomlPath"] := Path
		_TomlUnreadableFiles := _TomlUnreadableFiles.Clone()
		_ReadPersonalTomlCache := false
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())
		if Mode != "appeared"
			if !WritePersonalToml(_PTIOCR_Model("seed"))
				throw Error("opening-source fixture failed to seed its private file")
		if Mode == "metadata" {
			; This vector deliberately receives BOM and CRLF preservation, while
			; the neutral production writer emits LF. Normalize before inserting.
			RawSeed := StrReplace(FSReadUtf8Exact(Path), "`r`n", "`n")
			RawSeed := Chr(0xFEFF) . StrReplace(RawSeed, "`n", "`r`n")
			AssertEqual(Chr(0xFEFF), SubStr(RawSeed, 1, 1), "the seed must own its BOM")
			AssertTrue(InStr(RawSeed, "`r`n") > 0, "the seed must contain CRLF")
			AssertEqual(0, InStr(StrReplace(RawSeed, "`r`n", ""), "`n"),
				"the seed must not mix neutral LF with explicit CRLF")
			RawSeed := StrReplace(RawSeed, "[_meta]`r`n",
				'[_meta]`r`ndelay = 0.125`r`ncolor = "#123456"`r`npriority = 23`r`nshow_tooltip = false`r`n', , &FileInsertions, 1)
			; The neutral writer stores a scalar description. Move it into the new
			; override table so the fixture cannot declare a table over that scalar.
			RawSeed := StrReplace(RawSeed, 'alpha = "alpha"`r`n', "", , &DescriptionMoves, 1)
			AssertEqual(1, DescriptionMoves, "the existing description must move exactly once")
			RawSeed := StrReplace(RawSeed, "[[alpha]]`r`n",
				'[_meta.sections.alpha]`r`ndescription = "alpha"`r`ndelay = 0.75`r`ncolor = "#ABCDEF"`r`npriority = 42`r`nshow_tooltip = true`r`n[[alpha]]`r`n', , &SectionInsertions, 1)
			AssertEqual(1, FileInsertions, "opening-source fixture must seed its file overrides")
			AssertEqual(1, SectionInsertions, "opening-source fixture must seed its section overrides")
			SeedDocument := TOML_ParseDocument(RawSeed)
			AssertEqual("alpha", SeedDocument["_meta"]["sections"]["alpha"]["description"])
			AssertEqual("beta", SeedDocument["_meta"]["sections"]["beta"],
				"the neighboring scalar description must stay intact")
			if !FSWriteDurable(Path, RawSeed)
				throw Error("opening-source fixture metadata publication refused")
			SeedOverrides := _PersonalTomlCaptureOverrides(Path)
			AssertTrue(SeedOverrides["ok"], "opening-source metadata seed must be readable")
			AssertTrue(SeedOverrides["sections"].Has("alpha"), "opening-source metadata seed must own alpha")
			for Field, Literal in Map("delay", "0.125", "color", '"#123456"', "priority", "23", "show_tooltip", "false")
				AssertEqual(Literal, SeedOverrides["file"][Field], "file metadata must exist before the editor opens")
			for Field, Literal in Map("delay", "0.75", "color", '"#ABCDEF"', "priority", "42", "show_tooltip", "true")
				AssertEqual(Literal, SeedOverrides["sections"]["alpha"][Field], "section metadata must exist before the editor opens")
		}
		if Mode == "cached"
			_ReadPersonalTomlCache := _PTIOCR_Model("cached")
		; A hidden Gui stands in for the WebView editor window: these cases own
		; the file consent, not the page, so no browser is created.
		_HsEdWeb_Controller := unset, _HsEdWeb_WebView := unset
		_HsEdWeb_MsgSub := unset, _HsEdWeb_NavSub := unset
		_HsEdWeb_ResetDone := false
		_HsEdWeb_Gui := Window
		_HsEdWeb_SessionEpoch := IsSet(_HsEdWeb_SessionEpoch) ? _HsEdWeb_SessionEpoch + 1 : 1
		Context.opening_data := _PT102_CaptureOpening(Context.source)
		Context.source["kind"] := "webview"
		Context.source["window"] := Window
		Context.source["epoch"] := _HsEdWeb_SessionEpoch
		Context.source["ready"] := true
		_HsEdWeb_OpeningSource := Context.source
		Body.Call(Context)
	} finally {
		CleanupDebt := false
		if Context.lock_handle {
			if DllCall("Kernel32\CloseHandle", "Ptr", Context.lock_handle, "Int") {
				Context.lock_handle := 0
				RetainedHandles.Delete(Context.path)
			} else
				CleanupDebt := true
		}
		try Window.Destroy()
		if !OwnDirectory || CreatedRoot {
			for StagePath in Context.stage_paths
				try FileDelete(StagePath)
			try FileDelete(Path)
			try _ParseTomlGroupConfig_InvalidatePath(Path)
		}
		ScriptInformation["PersonalTomlPath"] := OldPath
		_PersonalTomlLiveCommitState(OldState)
		for Name, State in Saved {
			if State.had
				%Name% := State.value
			else
				%Name% := unset
		}
		Suspend(OldSuspended)
		Critical(OldCritical)
		if CreatedRoot && !CleanupDebt
			DirDelete(Root, true)
		if CleanupDebt
			throw Error("controlled native handle cleanup debt retained")
	}
}

_PT102_Refusal(Context) {
	global PERSONAL_TOML_COMMIT_FAILED
	if Context.mode == "foreign" || Context.mode == "appeared"
		AssertTrue(FSWriteDurable(Context.path, Context.foreign), "independent physical mutation must occur")
	Expected := (Context.mode == "stage-foreign" || Context.mode == "authorize-foreign")
		? Context.foreign : FSReadUtf8Exact(Context.path)
	Result := _PT102_Commit(Context, _PTIOCR_Model("candidate"))
	AssertEqual(PERSONAL_TOML_COMMIT_FAILED, Result)
	AssertEqual(Expected, FSReadUtf8Exact(Context.path), "refused stale source must remain byte exact")
	AssertEqual(0, Context.replaces)
	AssertEqual(0, Context.reloads)
	if Context.mode == "foreign" || Context.mode == "appeared"
		AssertEqual(0, Context.stages, "preflight refusal must happen before any staging")
	if Context.mode == "stage-foreign" || Context.mode == "authorize-foreign"
		AssertTrue(Context.foreign_ack, "the controlled callback must really replace the source")
	for StagePath in Context.stage_paths
		AssertFalse(FileExist(StagePath), "refused owned stages must be retired")
	_PTIOP_AssertLeaseFree(Context.path, "source refusal must release its actual native path owner")
}
for Mode in ["foreign", "appeared", "stage-foreign", "authorize-foreign", "stage-close"]
	Test("personal-opening-source: actual owner refuses " . Mode,
		_PT102_WithCase.Bind(Mode, _PT102_Refusal))

_PT102_CacheBypass(Context) {
	AssertEqual("seed-alpha", Context.opening_data["sections"]["alpha"]["entries"][1]["output"],
		"opening source and model must come from the same fresh image, not the old untagged cache")
	AssertEqual(FSReadUtf8Exact(Context.path), Context.source["content"])
	AssertTrue(Context.source["present"])
}
Test("personal-opening-source: opening model bypasses stale ordinary cache",
	_PT102_WithCase.Bind("cached", _PT102_CacheBypass))

_PT102_Coalescing(Context) {
	global PERSONAL_TOML_COMMIT_OK, PERSONAL_TOML_COMMIT_DEFERRED
	Context.queue_pending := true
	Result := _PT102_Commit(Context, _PTIOCR_Model("A"))
	AssertEqual(PERSONAL_TOML_COMMIT_OK, Result)
	AssertEqual(PERSONAL_TOML_COMMIT_DEFERRED, Context.queued_result)
	AssertEqual(2, Context.stages)
	AssertEqual(2, Context.replaces)
	AssertEqual(1, Context.terminals.Length)
	AssertEqual(PERSONAL_TOML_COMMIT_OK, Context.terminals[1])
	AssertTrue(Context.terminal_owner_ids[1] > 0)
	AssertEqual(FSReadUtf8Exact(Context.path), Context.source["content"],
		"the receipt must advance to the exact staged own publication")
	Disk := ReadPersonalToml(true)
	AssertEqual("B-alpha", Disk["sections"]["alpha"]["entries"][1]["output"])
	AssertEqual("B-beta", Context.live["beta"])
	AssertFalse(Context.stage_critical)
	AssertFalse(Context.replace_critical)
	AssertFalse(Context.reload_critical)
	_PTIOP_AssertLeaseFree(Context.path, "coalesced publication retains and finally releases its owner")
}
Test("personal-opening-source: own A then deferred B keeps exact publication lineage",
	_PT102_WithCase.Bind("coalesced", _PT102_Coalescing))

_PT102_ReloadRefusal(Context) {
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_OK
	Context.fail_remaining := 2
	Result := _PT102_Commit(Context, _PTIOCR_Model("saved"))
	AssertEqual(PERSONAL_TOML_COMMIT_FAILED, Result)
	AssertEqual(1, Context.replaces, "reload refusal must not masquerade as rolled-back disk")
	AssertEqual(FSReadUtf8Exact(Context.path), Context.source["content"])
	AssertTrue(_PersonalTomlLiveCommitState().resync is Object)
	Context.mode := "retry"
	Retry := _PT102_Commit(Context, _PTIOCR_Model("retry"))
	AssertEqual(PERSONAL_TOML_COMMIT_OK, Retry)
	AssertFalse(_PersonalTomlLiveCommitState().resync is Object)
	AssertEqual(2, Context.replaces, "resync must reload the retained image without rewriting it")
	AssertEqual("retry-beta", Context.live["beta"])
	AssertEqual(FSReadUtf8Exact(Context.path), Context.source["content"])
}
Test("personal-opening-source: saved but reload refused retains own image for resync retry",
	_PT102_WithCase.Bind("reload-refusal", _PT102_ReloadRefusal))

_PT102_ForeignBeforeResync(Context) {
	global PERSONAL_TOML_COMMIT_FAILED
	Context.fail_remaining := 2
	First := _PT102_Commit(Context, _PTIOCR_Model("saved"))
	AssertEqual(PERSONAL_TOML_COMMIT_FAILED, First)
	Retained := _PersonalTomlLiveCommitState().resync
	AssertTrue(Retained is Object)
	AssertTrue(FSWriteDurable(Context.path, Context.foreign))
	BeforeReload := Context.reloads
	BeforeStages := Context.stages
	Retry := _PT102_Commit(Context, _PTIOCR_Model("unsafe-retry"))
	AssertEqual(PERSONAL_TOML_COMMIT_FAILED, Retry)
	AssertEqual(Context.foreign, FSReadUtf8Exact(Context.path))
	AssertEqual(BeforeReload, Context.reloads, "stale source must refuse before replaying old resync")
	AssertEqual(BeforeStages, Context.stages)
	AssertEqual(ObjPtr(Retained), ObjPtr(_PersonalTomlLiveCommitState().resync),
		"foreign refusal must retain the acknowledged old recovery obligation")
}
Test("personal-opening-source: foreign replacement refuses before owned resync mutates runtime",
	_PT102_WithCase.Bind("foreign-resync", _PT102_ForeignBeforeResync))

_PT102_ActualRenameRefusal(Context) {
	global PERSONAL_TOML_COMMIT_FAILED, PERSONAL_TOML_COMMIT_OK
	Original := FSReadUtf8Exact(Context.path)
	Result := _PT102_Commit(Context, _PTIOCR_Model("rename-refused"))
	AssertTrue(Context.lock_acquired, "the native replacement boundary must acquire the actual no-delete handle")
	AssertTrue(Context.lock_closed, "only the exact acquired handle must be closed")
	AssertEqual(PERSONAL_TOML_COMMIT_FAILED, Result)
	AssertEqual(1, Context.replaces)
	AssertEqual(0, Context.reloads)
	AssertEqual(Original, FSReadUtf8Exact(Context.path))
	AssertEqual(Original, Context.source["content"], "failed replacement cannot advance own-image lineage")
	Context.mode := "rename-retry"
	Retry := _PT102_Commit(Context, _PTIOCR_Model("retry"))
	AssertEqual(PERSONAL_TOML_COMMIT_OK, Retry)
	AssertEqual(FSReadUtf8Exact(Context.path), Context.source["content"])
	AssertFalse(Context.replace_critical)
}
Test("personal-opening-source: actual no-delete handle refuses rename without source advancement",
	_PT102_WithCase.Bind("rename-lock", _PT102_ActualRenameRefusal))

_PT102_ConsentIdentityRefusal(Context) {
	global _HsEdWeb_OpeningSource, _HsEdWeb_SessionEpoch
	global PERSONAL_TOML_COMMIT_FAILED
	Original := FSReadUtf8Exact(Context.path)
	if Context.mode == "deleted"
		FileDelete(Context.path)
	else if Context.mode == "new-session"
		_HsEdWeb_SessionEpoch += 1
	else if Context.mode == "copied-receipt"
		_HsEdWeb_OpeningSource := Context.source.Clone()
	else if Context.mode == "invalid-presence"
		Context.source["present"] := "true"
	Result := _PT102_Commit(Context, _PTIOCR_Model("unowned"))
	AssertEqual(PERSONAL_TOML_COMMIT_FAILED, Result)
	if Context.mode == "deleted"
		AssertFalse(FSStrictExists(Context.path), "a deleted opening image cannot be recreated by stale consent")
	else
		AssertEqual(Original, FSReadUtf8Exact(Context.path))
	AssertEqual(0, Context.stages)
	AssertEqual(0, Context.replaces)
	AssertEqual(0, Context.reloads)
	_PTIOP_AssertLeaseFree(Context.path, "invalid opening consent must leave no publication owner")
}
for Mode in ["deleted", "new-session", "copied-receipt", "invalid-presence"]
	Test("personal-opening-source: actual owner refuses " . Mode . " consent",
		_PT102_WithCase.Bind(Mode, _PT102_ConsentIdentityRefusal))

_PT102_KnownOverrides(Context) {
	global PERSONAL_TOML_COMMIT_OK
	AssertEqual(Chr(0xFEFF), SubStr(Context.source["content"], 1, 1))
	Result := _PT102_Commit(Context, _PTIOCR_Model("updated"))
	AssertEqual(PERSONAL_TOML_COMMIT_OK, Result)
	Captured := _PersonalTomlCaptureOverrides(Context.path)
	AssertTrue(Captured["ok"])
	for Field, Literal in Map("delay", "0.125", "color", '"#123456"', "priority", "23", "show_tooltip", "false")
		AssertEqual(Literal, Captured["file"][Field])
	for Field, Literal in Map("delay", "0.75", "color", '"#ABCDEF"', "priority", "42", "show_tooltip", "true")
		AssertEqual(Literal, Captured["sections"]["alpha"][Field])
	AssertEqual(FSReadUtf8Exact(Context.path), Context.source["content"])
	AssertEqual("updated-beta", Context.live["beta"])
}
Test("personal-opening-source: own image preserves all four file and section metadata neighbors",
	_PT102_WithCase.Bind("metadata", _PT102_KnownOverrides))

; Append to test_personal_toml_live_transactions.ahk. Existing _PT102_WithCase
; owns the real private personal file, editor Gui identity and global cleanup.
; Callbacks record facts only: assertions happen after the actual transaction.
_PTA_FinalHotstring(Context) {
	global ScriptInformation
	Original := FSReadBytesStrict(Context.path)
	Candidate := FSReadUtf8Exact(Context.path) . "`n# final native admission candidate`n"
	Owner := _PersonalTomlWriteLeaseTryAcquire(Context.path, "final-admission-regression")
	AssertTrue(Owner is Object)
	Facts := {hooks: 0, hook_critical: false, admitted_before: false, stage: "", published: 0, close_called: false}
	Writer(Stage, Content) {
		Facts.stage := Stage
		return FSWriteDurable(Stage, Content)
	}
	Publish() {
		Facts.published += 1
		return true
	}
	BeforeNative() {
		global ScriptInformation
		Facts.hooks += 1
		Facts.hook_critical := A_IsCritical
		Facts.admitted_before := _PersonalTomlOpeningAuthority(Context.source, Context.path, Owner)
		switch Context.mode {
			case "close":
				_HsEdWeb_Close(Context.window)
				Facts.close_called := true
			case "pause": Suspend(true)
			case "released": _PersonalTomlWriteLeaseRelease(Owner)
			case "relocated": ScriptInformation["PersonalTomlPath"] := Context.path . ".other"
		}
	}
	try {
		Result := _PersonalTomlWriteAtomic(Context.path, Candidate, Writer, 0, 0,
			_PersonalTomlAuthorizeOwnedWrite.Bind(Owner, Context.path), Publish,
			Context.source, Owner, Context.source, BeforeNative)
		AssertEqual(1, Facts.hooks, "the genuine native cutpoint follows all earlier admission checks")
		AssertFalse(Facts.hook_critical, "revocation must execute outside the protected native span")
		AssertTrue(Facts.admitted_before, "the live genuine session must pass before the cutpoint revokes it")
		AssertTrue(Facts.stage != "")
		AssertFalse(FileExist(Facts.stage), "success consumes the stage; refusal cleans it")
		; A pause stops typing, not configuration (EDD-1): a paused rename publishes (edd1-paused-writes).
		if Context.mode == "live" || Context.mode == "pause" {
			AssertTrue(Result)
			AssertTrue(FSUtf8ExactMatches(Context.path, Candidate))
			AssertEqual(1, Facts.published)
		} else {
			AssertFalse(Result)
			AssertTrue(_PersonalInfoSourceBytesEqual(Original, FSReadBytesStrict(Context.path)),
				"a late withdrawal must preserve the entire original native file")
			AssertEqual(0, Facts.published, "a refused native rename cannot publish the candidate")
		}
		if Context.mode == "close"
			AssertTrue(Facts.close_called)
	} finally {
		_PersonalTomlWriteLeaseRelease(Owner)
	}
}
for _PTA_Mode in ["live", "close", "pause", "released", "relocated"]
	Test("personal native final admission: " . _PTA_Mode,
		_PT102_WithCase.Bind(_PTA_Mode, _PTA_FinalHotstring))

; Metadata shares the same atomic producer but may target an additional personal
; source. Do not impose the primary file's configured-path identity on this API.
_PTA_FinalMetadata(Context) {
	Original := FSReadBytesStrict(Context.path)
	Candidate := FSReadUtf8Exact(Context.path) . "`n# late metadata candidate`n"
	Facts := {hooks: 0, hook_critical: false, leased: false, stage: ""}
	Build(Content) {
		return Candidate
	}
	Writer(Stage, Content) {
		Facts.stage := Stage
		return FSWriteDurable(Stage, Content)
	}
	BeforeNative() {
		Facts.hooks += 1
		Facts.hook_critical := A_IsCritical
		Unexpected := _PersonalTomlWriteLeaseTryAcquire(Context.path, "late-probe")
		Facts.leased := !IsObject(Unexpected)
		if Unexpected is Object
			_PersonalTomlWriteLeaseRelease(Unexpected)
		if Context.mode == "pause"
			Suspend(true)
	}
	Result := _PersonalTomlCommitPatch(Context.path, Build, 0, Writer, 0, 0, 0, BeforeNative)
	AssertEqual(1, Facts.hooks)
	AssertFalse(Facts.hook_critical)
	AssertTrue(Facts.leased, "the genuine patch holds its existing owner through the cutpoint")
	AssertFalse(FileExist(Facts.stage))
	; A pause stops typing, not configuration (EDD-1): a paused rename publishes (edd1-paused-writes).
	if Context.mode == "live" || Context.mode == "pause" {
		AssertTrue(Result)
		AssertTrue(FSUtf8ExactMatches(Context.path, Candidate))
	} else {
		AssertFalse(Result)
		AssertTrue(_PersonalInfoSourceBytesEqual(Original, FSReadBytesStrict(Context.path)))
	}
	Probe := _PersonalTomlWriteLeaseTryAcquire(Context.path, "after-final-patch")
	AssertTrue(Probe is Object)
	try AssertTrue(_PersonalTomlWriteLeaseOwns(Probe, Context.path))
	finally _PersonalTomlWriteLeaseRelease(Probe)
}
for _PTA_Mode in ["live", "pause"]
	Test("personal metadata native final admission: " . _PTA_Mode,
		_PT102_WithCase.Bind(_PTA_Mode, _PTA_FinalMetadata))

; Separate private fixture for personal_info.toml. Its actual public loader
; captures the original byte receipt and actual editor-source owner. The outer
; atomic helper dispatches its ordinary injected ReplaceFn ABI; that callback
; delegates to the real _PersonalInfoReplaceUnchanged DEFAULT native branch.
_PTA_FinalInformation(Mode) {
	global ScriptInformation, PersonalInformation, PersonalInformationLetters
	global _ReadPersonalInfoTomlCache, _TomlUnreadableFiles
	Directory := A_Temp . "\ergopti_info_final_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Path := Directory . "\personal_info.toml"
	Saved := {had_path: ScriptInformation.Has("PersonalInfoTomlPath"), path: ScriptInformation.Get("PersonalInfoTomlPath", ""),
		had_info: IsSet(PersonalInformation), had_letters: IsSet(PersonalInformationLetters), cache: _ReadPersonalInfoTomlCache,
		suspended: A_IsSuspended, critical: A_IsCritical}
	Saved.info := Saved.had_info ? PersonalInformation : 0
	Saved.letters := Saved.had_letters ? PersonalInformationLetters : 0
	Owner := 0
	Facts := {hooks: 0, hook_critical: false, admitted_before: false, stage: "", published: 0, replace_critical: false}
	try {
		Critical("Off")
		Suspend(false)
		ScriptInformation["PersonalInfoTomlPath"] := Path
		PersonalInformation := Map("first_name", "Default", "last_name", "Default")
		PersonalInformationLetters := Map("p", "first_name")
		_ReadPersonalInfoTomlCache := false
		OriginalText := '[info]`nfirst_name = "Alice"`nlast_name = "Original"`n[letters]`np = "first_name"`n'
		Candidate := StrReplace(OriginalText, '"Original"', '"Changed"')
		AssertTrue(FSWriteDurable(Path, OriginalText))
		ReadPersonalInfoToml(Path)
		Editor := _PersonalInfoCaptureEditorSource(Path)
		AssertTrue(_PersonalInfoEditorSourceCurrent(Editor, Path))
		Owner := _PersonalTomlWriteLeaseTryAcquire(Path, "information-final-admission")
		AssertTrue(Owner is Object)
		Source := _PersonalInfoReadWriteSource(Path)
		Source["editor_owner"] := Editor
		AssertTrue(_PersonalInfoWriteSourceCurrent(Source, Owner, Path))
		Original := FSReadBytesStrict(Path)
		Writer(Stage, Content) {
			Facts.stage := Stage
			return FSWriteDurable(Stage, Content)
		}
		Publish() {
			Facts.published += 1
			return true
		}
		BeforeNative() {
			global ScriptInformation, PersonalInformation
			Facts.hooks += 1
			Facts.hook_critical := A_IsCritical
			Facts.admitted_before := _PersonalInfoWriteSourceCurrent(Source, Owner, Path)
			switch Mode {
				case "pause": Suspend(true)
				case "released": _PersonalTomlWriteLeaseRelease(Owner)
				case "relocated": ScriptInformation["PersonalInfoTomlPath"] := Path . ".other"
				case "retired-editor": Editor["active"] := false
				case "new-resident": PersonalInformation := PersonalInformation.Clone()
			}
		}
		Replace(Stage, Target) {
			Facts.replace_critical := A_IsCritical
			return _PersonalInfoReplaceUnchanged(Source, Owner, 0, Stage, Target, BeforeNative)
		}
		Result := _PersonalTomlWriteAtomic(Path, Candidate, Writer, Replace, 0,
			_PersonalTomlAuthorizeOwnedWrite.Bind(Owner, Path), Publish)
		AssertEqual(1, Facts.hooks, "the real source bytes and pure precheck must pass before revocation")
		AssertFalse(Facts.hook_critical)
		AssertFalse(Facts.replace_critical, "the existing arbitrary two-argument ReplaceFn ABI stays outside Critical")
		AssertTrue(Facts.admitted_before)
		AssertFalse(FileExist(Facts.stage))
		; A pause stops typing, not configuration (EDD-1): a paused rename publishes (edd1-paused-writes).
		if Mode == "live" || Mode == "pause" {
			AssertTrue(Result)
			AssertTrue(FSUtf8ExactMatches(Path, Candidate))
			AssertEqual(1, Facts.published)
		} else {
			AssertFalse(Result)
			AssertTrue(_PersonalInfoSourceBytesEqual(Original, FSReadBytesStrict(Path)))
			AssertEqual(0, Facts.published)
		}
	} finally {
		if Owner is Object
			_PersonalTomlWriteLeaseRelease(Owner)
		PersonalInformation := Saved.had_info ? Saved.info : unset
		PersonalInformationLetters := Saved.had_letters ? Saved.letters : unset
		_ReadPersonalInfoTomlCache := Saved.cache
		if Saved.had_path
			ScriptInformation["PersonalInfoTomlPath"] := Saved.path
		else
			ScriptInformation.Delete("PersonalInfoTomlPath")
		if IsSet(_TomlUnreadableFiles) && _TomlUnreadableFiles.Has(Path)
			_TomlUnreadableFiles.Delete(Path)
		Suspend(Saved.suspended)
		try DirDelete(Directory, true)
		finally Critical(Saved.critical)
	}
}
for _PTA_Mode in ["live", "pause", "released", "relocated", "retired-editor", "new-resident"]
	Test("personal information native final admission: " . _PTA_Mode,
		_PTA_FinalInformation.Bind(_PTA_Mode))

; Actual rename effects remain visible when a later logical/durability ACK refuses.
_PTHP_Case(Mode, Context) {
	Owner := 0, Original := Context.source["content"]
	Data := _PTIOCR_Model("held-partial")
	Order := _PersonalTomlCanonicalSectionOrder(Data, &Detail)
	AssertTrue(Order is Array)
	Content := _PersonalTomlPreserveModel(Original, Data, Order)
	Facts := {owned_calls: 0, published_flushes: 0, actual_flush_ok: false,
		publisher_calls: 0, saw_original: false, reports: [], receipt: 0}
	WriteOwner := FSWriteReplaceOwned, ReportOwner := ConfigReportPersistenceFailure
	HadWrite := WriteOwner.HasOwnProp("Call"), HadReport := ReportOwner.HasOwnProp("Call")
	if HadWrite
		OldWrite := WriteOwner.GetOwnPropDesc("Call")
	if HadReport
		OldReport := ReportOwner.GetOwnPropDesc("Call")
	WriteInstalled := false, ReportInstalled := false
	ObserveReport(This, Action, NotifyFn := 0, Message := "", Unchanged := true) {
		if InStr(Action, "personal") == 1
			Facts.reports.Push(Unchanged)
		return Func.Prototype.Call.Call(This, Action, NotifyFn, Message, Unchanged)
	}
	ObserveWrite(This, Target, Text, Suffix, &StageDetail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Mine := StrCompare(Target, Context.path, true) == 0
		FlushOriginal := HasMethod(FlushFn, "Call") ? FlushFn : _FSFlushOwnedText
		FlushOwned(Handle, Phase) {
			Result := FlushOriginal.Call(Handle, Phase)
			if Phase == "published" {
				Facts.published_flushes += 1
				Facts.actual_flush_ok := (Result is Integer) && Result == 1
				; Explicit ACK refusal after the genuine flush, not a claimed
				; native FlushFileBuffers failure. All real handles still close.
				return false
			}
			return Result
		}
		if Mine
			Facts.owned_calls += 1
		Result := Func.Prototype.Call.Call(This, Target, Text, Suffix, &StageDetail,
			StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication,
			Mine && Mode == "published-flush-refused" ? FlushOwned : FlushFn)
		if Mine
			Facts.receipt := Publication
		return Result
	}
	Publish() {
		Facts.publisher_calls += 1
		Facts.saw_original := StrCompare(Context.source["content"], Original, true) == 0
		return Mode != "publisher-refused"
	}
	try {
		Owner := _PersonalTomlWriteLeaseTryAcquire(Context.path, "held-partial-test")
		AssertTrue(Owner is Object)
		WriteOwner.DefineProp("Call", {Call: ObserveWrite}), WriteInstalled := true
		ReportOwner.DefineProp("Call", {Call: ObserveReport}), ReportInstalled := true
		Result := _PersonalTomlWriteAtomic(Context.path, Content, 0, 0, 0,
			_PersonalTomlAuthorizeOwnedWrite.Bind(Owner, Context.path), Publish,
			Context.source, Owner, Context.source)
		AssertEqual(1, Facts.owned_calls, "The actual held writer must run once")
		AssertTrue(Facts.receipt.renamed, "The real native rename must happen before the refused acknowledgement")
		AssertTrue(FSUtf8ExactMatches(Context.path, Content), "The real rename's exact forward bytes remain at the target")
		AssertFalse(Result)
		AssertEqual(Original, Context.source["content"], "An unacknowledged live/durable effect cannot advance the reusable opening receipt")
		AssertTrue(Facts.reports.Length > 0, "The actual error reporter must receive the partial effect")
		for Unchanged in Facts.reports
			AssertFalse(Unchanged, "A real rename cannot be described as unchanged source state")
		if Mode == "publisher-refused" {
			AssertTrue(Facts.receipt.durable)
			AssertEqual(1, Facts.publisher_calls)
			AssertTrue(Facts.saw_original, "The publisher must acknowledge before source lineage advances")
		} else {
			AssertEqual(1, Facts.published_flushes)
			AssertTrue(Facts.actual_flush_ok)
			AssertFalse(Facts.receipt.durable)
			AssertEqual(0, Facts.publisher_calls, "Without complete durable ACK no live publisher may run")
		}
		BeforeRetry := FSReadBytesStrict(Context.path)
		AssertFalse(WritePersonalToml(_PTIOCR_Model("old-opening-retry"), 0, 0, 0, 0, Owner, Context.source),
			"The old opening cannot overwrite the forward image after a partial terminal effect")
		AssertTrue(_PersonalInfoSourceBytesEqual(BeforeRetry, FSReadBytesStrict(Context.path)))
	} finally {
		if ReportInstalled {
			if HadReport
				ReportOwner.DefineProp("Call", OldReport)
			else
				ReportOwner.DeleteProp("Call")
		}
		if WriteInstalled {
			if HadWrite
				WriteOwner.DefineProp("Call", OldWrite)
			else
				WriteOwner.DeleteProp("Call")
		}
		if Owner is Object
			_PersonalTomlWriteLeaseRelease(Owner)
	}
}
for _PTHP_Mode in ["publisher-refused", "published-flush-refused"]
	Test("personal held publication: " . _PTHP_Mode . " retains truthful forward effects (personal-held-partial)",
		_PT102_WithCase.Bind("held-partial", _PTHP_Case.Bind(_PTHP_Mode), true))
