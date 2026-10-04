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

; Opening-source consent uses actual private files, the ordinary durable owner,
; and hidden native Gui identities. Callback bodies collect facts, never assert.
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
	else if Context.mode == "stage-close" {
		if _OnEditorClose.MaxParams >= 2
			_OnEditorClose(Context.window, Context.source["epoch"])
		else
			_OnEditorClose()
		Context.window.Destroy()
	}
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

_PT102_WithCase(Mode, Body) {
	global ScriptInformation, _ReadPersonalTomlCache, _TomlUnreadableFiles
	global _PersonalEditorGui, _PersonalEditorData, _PersonalEditorSection, _PersonalEditorPrioCtrl
	global _PersonalEditorOpeningSource, _PersonalEditorSessionEpoch
	global _HsEdWeb_Gui, _HsEdWeb_OpeningSource, _HsEdWeb_SessionEpoch
	static Sequence := 0, RetainedHandles := Map()
	if RetainedHandles.Count
		throw Error("controlled native handle debt blocks successor fixture")
	Sequence += 1
	Path := A_Temp . "\ergopti_opening_source_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Sequence . ".toml"
	Names := ["_ReadPersonalTomlCache", "_TomlUnreadableFiles", "_PersonalEditorGui",
		"_PersonalEditorData", "_PersonalEditorSection", "_PersonalEditorPrioCtrl",
		"_PersonalEditorOpeningSource", "_PersonalEditorSessionEpoch",
		"_HsEdWeb_Gui", "_HsEdWeb_OpeningSource", "_HsEdWeb_SessionEpoch"]
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
		Suspend(false)
		ScriptInformation["PersonalTomlPath"] := Path
		_TomlUnreadableFiles := _TomlUnreadableFiles.Clone()
		_ReadPersonalTomlCache := false
		_PersonalTomlLiveCommitState(_PTIOCR_FreshCommitState())
		if Mode != "appeared"
			if !WritePersonalToml(_PTIOCR_Model("seed"))
				throw Error("opening-source fixture failed to seed its private file")
		if Mode == "metadata" {
			RawSeed := Chr(0xFEFF) . FSReadUtf8Exact(Path)
			RawSeed := StrReplace(RawSeed, "[_meta]`r`n",
				'[_meta]`r`ndelay = 0.125`r`ncolor = "#123456"`r`npriority = 23`r`nshow_tooltip = false`r`n', , , 1)
			RawSeed := StrReplace(RawSeed, "[_meta.sections.alpha]`r`n",
				'[_meta.sections.alpha]`r`ndelay = 0.75`r`ncolor = "#ABCDEF"`r`npriority = 42`r`nshow_tooltip = true`r`n', , , 1)
			if !FSWriteDurable(Path, RawSeed)
				throw Error("opening-source fixture metadata publication refused")
		}
		if Mode == "cached"
			_ReadPersonalTomlCache := _PTIOCR_Model("cached")
		_PersonalEditorGui := Window
		_PersonalEditorSessionEpoch := IsSet(_PersonalEditorSessionEpoch) ? _PersonalEditorSessionEpoch + 1 : 1
		Context.opening_data := _PT102_CaptureOpening(Context.source)
		Context.source["kind"] := "native"
		Context.source["window"] := Window
		Context.source["epoch"] := _PersonalEditorSessionEpoch
		_PersonalEditorOpeningSource := Context.source
		_PersonalEditorData := Context.opening_data
		_PersonalEditorSection := "alpha"
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
		for StagePath in Context.stage_paths
			try FileDelete(StagePath)
		try FileDelete(Path)
		try _ParseTomlGroupConfig_InvalidatePath(Path)
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
	global _PersonalEditorOpeningSource, _PersonalEditorSessionEpoch
	global PERSONAL_TOML_COMMIT_FAILED
	Original := FSReadUtf8Exact(Context.path)
	if Context.mode == "deleted"
		FileDelete(Context.path)
	else if Context.mode == "new-session"
		_PersonalEditorSessionEpoch += 1
	else if Context.mode == "copied-receipt"
		_PersonalEditorOpeningSource := Context.source.Clone()
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
