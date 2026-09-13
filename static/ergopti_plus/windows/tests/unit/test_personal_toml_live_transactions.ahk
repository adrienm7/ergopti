; tests/unit/test_personal_toml_live_transactions.ahk

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
				"strict_case", false,
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
			"a mutation of the native editor alias during staging must not alter A's detached snapshot")
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

; Suspend can be active before admission or arrive while the complete stage is
; being written. Neither sequence may reach atomic replacement or live HSE.
_PTIOCX_SuspendRefusesBeforeDurableAndLivePublication() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _PTIOCX_WriteCalls, _PTIOCX_ReplaceCalls, _PTIOCX_ReloadCalls
	global _PTIOCX_WriterWasCritical, _PTIOCX_ReplacerWasCritical
	global PERSONAL_TOML_COMMIT_FAILED
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
		AssertEqual(PERSONAL_TOML_COMMIT_FAILED,
			PersonalTomlCommitAndReload(Data, 0, _PTIOCX_WriteStage.Bind(),
				_PTIOCX_ReplaceStage.Bind(), 0, 0, _PTIOCX_Reload.Bind()))
		AssertEqual(0, _PTIOCX_WriteCalls,
			"a save received under Suspend must fail before staging")
		AssertEqual(0, _PTIOCX_ReplaceCalls)
		AssertEqual(0, _PTIOCX_ReloadCalls)
		AssertEqual(Original, FileRead(Path, "UTF-8-RAW"))
		Suspend(0)

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
		AssertEqual(PERSONAL_TOML_COMMIT_FAILED,
			PersonalTomlCommitAndReload(Data, 0, _PTIOCX_WriteStage.Bind(),
				_PTIOCX_ReplaceStage.Bind(), 0, 0, _PTIOCX_Reload.Bind()))
		AssertTrue(A_IsSuspended,
			"the injected stage seam must place the final authorization under Suspend")
		AssertEqual(1, _PTIOCX_WriteCalls)
		AssertEqual(0, _PTIOCX_ReplaceCalls,
			"a suspension observed after staging must refuse the atomic replacement")
		AssertEqual(0, _PTIOCX_ReloadCalls,
			"a refused durable publication must never mutate the live registry")
		AssertEqual(Original, FileRead(Path, "UTF-8-RAW"))
		AssertFalse(_PTIOCX_WriterWasCritical,
			"the suspend-aware owner must not make staging Critical")
		AssertFalse(_PTIOCX_ReplacerWasCritical)
		_PTIOP_AssertLeaseFree(Path,
			"every suspended refusal must release the personal path owner")
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
Test("personal-toml-live-transaction: Suspend refuses admission and post-stage publication",
	_PTIOCX_SuspendRefusesBeforeDurableAndLivePublication)

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
	for FunctionName in ["_SaveData", "_HsEdWeb_Save"] {
		Body := _DriverFuncBody(FunctionName)
		Assert(Body != "", FunctionName . " must exist in the driver source")
		Assert(InStr(Body, "PersonalTomlCommitAndReload(") > 0,
			FunctionName . " must delegate durable and live publication to the shared gateway")
		Assert(InStr(Body, "WritePersonalToml(") == 0,
			FunctionName . " must not release path ownership before its live reload")
		Assert(InStr(Body, "ReloadPersonalSection(") == 0,
			FunctionName . " must not own a second, reentrant reload loop")
	}
	NativeBody := _DriverFuncBody("_SaveData")
	Assert(InStr(NativeBody, "CompletionFn") > 0,
		"the native editor must receive a terminal result after DEFERRED")
	Assert(InStr(NativeBody, "PERSONAL_TOML_COMMIT_DEFERRED") > 0
			&& InStr(NativeBody, "return false") > 0,
		"the native editor must not report a DEFERRED admission as saved")
	WebBody := _DriverFuncBody("_HsEdWeb_Save")
	Assert(InStr(WebBody, "_HsEdWeb_DeferredSaveCompleted") > 0,
		"the WebView editor must receive a terminal result after DEFERRED")
	FailureBody := _DriverFuncBody("_HsEdWeb_ReportSaveFailure")
	Assert(FailureBody != "",
		"the WebView deferred failure reporter must exist")
	Assert(InStr(FailureBody, "NotifierSend") > 0,
		"a deferred WebView failure must be user-visible, not only logged")
	WebMessageBody := _DriverFuncBody("_HsEdWeb_OnWebMessage")
	Assert(WebMessageBody != "")
	Assert(InStr(WebMessageBody, "_HsEdWeb_ShowSaveFailure") > 0,
		"a WebView save received under Suspend must surface its refusal")
	ShowFailureBody := _DriverFuncBody("_HsEdWeb_ShowSaveFailure")
	Assert(ShowFailureBody != "")
	Assert(InStr(ShowFailureBody, "save-toast") > 0,
		"the suspended refusal must replace the page's optimistic saved toast")
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
Test("personal-toml-live-transaction: native and WebView saves share one gateway",
	_PTIOCR_AllEditorsUseTheDurableLiveGateway)

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
