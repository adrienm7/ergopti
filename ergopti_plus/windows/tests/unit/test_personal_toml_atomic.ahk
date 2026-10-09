; tests/unit/test_personal_toml_atomic.ahk

; ==============================================================================
; MODULE: Personal TOML Atomic Write Tests
; DESCRIPTION: Exercise staging, authorization, schema validation and cache publication.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 2/ Atomic personal-hotstring writes ========
; =====================================================
; =====================================================

global _PTIO_AtomicStagePath := ""
global _PTIO_AtomicEvents := []

_PTIO_WritePartialStage(StagePath, Content) {
	global _PTIO_AtomicStagePath, _PTIO_AtomicEvents
	_PTIO_AtomicStagePath := StagePath
	_PTIO_AtomicEvents.Push("write")
	FileAppend("partial-candidate", StagePath, "UTF-8-RAW")
	return false
}

_PTIO_WriteCompleteStage(StagePath, Content) {
	global _PTIO_AtomicStagePath, _PTIO_AtomicEvents
	_PTIO_AtomicStagePath := StagePath
	_PTIO_AtomicEvents.Push("write")
	FileAppend(Content, StagePath, "UTF-8-RAW")
	return true
}

_PTIO_RefuseAtomicReplace(StagePath, TargetPath) {
	global _PTIO_AtomicEvents
	_PTIO_AtomicEvents.Push("replace")
	return false
}

_PTIO_ThrowDuringStageWrite(StagePath, Content) {
	global _PTIO_AtomicStagePath, _PTIO_AtomicEvents
	_PTIO_AtomicStagePath := StagePath
	_PTIO_AtomicEvents.Push("write-throw")
	FileAppend("partial-before-throw", StagePath, "UTF-8-RAW")
	throw Error("injected stage failure")
}

_PTIO_ThrowDuringAtomicReplace(StagePath, TargetPath) {
	global _PTIO_AtomicEvents
	_PTIO_AtomicEvents.Push("replace-throw")
	throw Error("injected replace failure")
}

_PTIO_AtomicWriterPreservesOldFileOnEveryPrePublishFailure() {
	global _PTIO_AtomicStagePath, _PTIO_AtomicEvents
	TargetPath := A_Temp . "\\ergopti_personal_atomic_" . A_TickCount . ".toml"
	Original := "old-personal-hotstrings`n"
	Candidate := "new-personal-hotstrings`n"
	try {
		try FileDelete(TargetPath)
		FileAppend(Original, TargetPath, "UTF-8-RAW")

		_PTIO_AtomicStagePath := ""
		_PTIO_AtomicEvents := []
		AssertFalse(_PersonalTomlWriteAtomic(TargetPath, Candidate,
			_PTIO_WritePartialStage.Bind(), _PTIO_RefuseAtomicReplace.Bind()))
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"a partial/refused staging write must never truncate the durable TOML")
		AssertEqual(1, _PTIO_AtomicEvents.Length,
			"a refused staging write must abort before the replace operation")
		AssertEqual("write", _PTIO_AtomicEvents[1])
		AssertTrue(_PTIO_AtomicStagePath != "")
		AssertFalse(FileExist(_PTIO_AtomicStagePath),
			"a failed staging write must clean its unique temporary file")

		_PTIO_AtomicStagePath := ""
		_PTIO_AtomicEvents := []
		AssertFalse(_PersonalTomlWriteAtomic(TargetPath, Candidate,
			_PTIO_WriteCompleteStage.Bind(), _PTIO_RefuseAtomicReplace.Bind()))
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"a refused atomic replace must leave the previous TOML byte-exact")
		AssertEqual(2, _PTIO_AtomicEvents.Length)
		AssertEqual("write", _PTIO_AtomicEvents[1])
		AssertEqual("replace", _PTIO_AtomicEvents[2])
		AssertFalse(FileExist(_PTIO_AtomicStagePath),
			"a refused replace must clean the complete but unpublished stage")

		_PTIO_AtomicStagePath := ""
		_PTIO_AtomicEvents := []
		AssertFalse(_PersonalTomlWriteAtomic(TargetPath, Candidate,
			_PTIO_ThrowDuringStageWrite.Bind(), _PTIO_RefuseAtomicReplace.Bind()))
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"a throwing partial stage writer must preserve the previous TOML")
		AssertEqual("write-throw", _PTIO_AtomicEvents[1])
		AssertFalse(FileExist(_PTIO_AtomicStagePath))

		_PTIO_AtomicStagePath := ""
		_PTIO_AtomicEvents := []
		AssertFalse(_PersonalTomlWriteAtomic(TargetPath, Candidate,
			_PTIO_WriteCompleteStage.Bind(), _PTIO_ThrowDuringAtomicReplace.Bind()))
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"a throwing atomic replace must preserve the previous TOML")
		AssertEqual("replace-throw", _PTIO_AtomicEvents[2])
		AssertFalse(FileExist(_PTIO_AtomicStagePath))

		AssertTrue(_PersonalTomlWriteAtomic(TargetPath, Candidate))
		AssertEqual(Candidate, FileRead(TargetPath, "UTF-8-RAW"),
			"a successful same-directory atomic replace must publish the full candidate")
	} finally {
		try FileDelete(_PTIO_AtomicStagePath)
		try FileDelete(TargetPath)
		_PTIO_AtomicStagePath := ""
		_PTIO_AtomicEvents := []
	}
}
Test("personal-toml-atomic-replace: failures preserve the old durable file",
	_PTIO_AtomicWriterPreservesOldFileOnEveryPrePublishFailure)

_PTIO_WritePersonalTomlUsesAtomicPublisher() {
	Body := _DriverFuncBody("WritePersonalToml")
	Assert(Body != "", "WritePersonalToml must exist")
	Assert(InStr(Body, "_PersonalTomlWriteAtomic(FilePath, Content") > 0,
		"WritePersonalToml must publish only through the tested same-directory atomic writer")
	Assert(InStr(Body, 'FileOpen(FilePath, "w"') == 0,
		"WritePersonalToml must never truncate the durable target in place")
}
Test("personal-toml-atomic-replace: production writer routes through atomic publisher",
	_PTIO_WritePersonalTomlUsesAtomicPublisher)

; Logical ownership is path-scoped, so alternate slash/case spellings must not
; bypass it and an already-released token must not evict its successor
_PTIO_PathLeaseRejectsAliasesAndStaleOwners() {
	Path := A_Temp . "\\Ergopti Personal Lease.toml"
	AliasPath := StrUpper(StrReplace(Path, "\", "/"))
	FirstOwner := 0
	NestedOwner := 0
	SecondOwner := 0
	FinalOwner := 0
	FirstReleased := false
	SecondReleased := false
	FinalReleased := false
	try {
		FirstOwner := _PersonalTomlWriteLeaseTryAcquire(Path, "outer")
		try {
			AssertTrue(FirstOwner is Object,
				"the first logical personal TOML writer must acquire the path")
			AssertTrue(_PersonalTomlWriteLeaseOwns(FirstOwner, Path))
			AssertTrue(_PersonalTomlWriteLeaseOwns(FirstOwner, AliasPath),
				"lease ownership must canonicalize slash and case aliases")
			NestedOwner := _PersonalTomlWriteLeaseTryAcquire(AliasPath, "nested")
			AssertFalse(NestedOwner is Object,
				"a same-path alias must not acquire a second logical writer")
		} finally {
			if NestedOwner is Object
				_PersonalTomlWriteLeaseRelease(NestedOwner)
			if FirstOwner is Object
				FirstReleased := _PersonalTomlWriteLeaseRelease(FirstOwner)
		}
		AssertTrue(FirstReleased,
			"the outer owner must release even when its guarded body fails")

		SecondOwner := _PersonalTomlWriteLeaseTryAcquire(AliasPath, "second")
		try {
			AssertTrue(SecondOwner is Object,
				"the canonical path must be acquirable after the first release")
			AssertFalse(_PersonalTomlWriteLeaseRelease(FirstOwner),
				"a stale token must never release a newer owner")
			AssertTrue(_PersonalTomlWriteLeaseOwns(SecondOwner, Path),
				"the newer owner must survive a stale release attempt")
		} finally {
			if SecondOwner is Object
				SecondReleased := _PersonalTomlWriteLeaseRelease(SecondOwner)
		}
		AssertTrue(SecondReleased)

		FinalOwner := _PersonalTomlWriteLeaseTryAcquire(Path, "final")
		try {
			AssertTrue(FinalOwner is Object,
				"every completed transaction must leave the path acquirable")
		} finally {
			if FinalOwner is Object
				FinalReleased := _PersonalTomlWriteLeaseRelease(FinalOwner)
		}
		AssertTrue(FinalReleased,
			"the final proof owner must not leak into later tests")
	} finally {
		if NestedOwner is Object
			_PersonalTomlWriteLeaseRelease(NestedOwner)
		if FirstOwner is Object
			_PersonalTomlWriteLeaseRelease(FirstOwner)
		if SecondOwner is Object
			_PersonalTomlWriteLeaseRelease(SecondOwner)
		if FinalOwner is Object
			_PersonalTomlWriteLeaseRelease(FinalOwner)
	}
}
Test("personal-toml-write-lease: aliases share one owner and stale releases fail",
	_PTIO_PathLeaseRejectsAliasesAndStaleOwners)

global _PTIO_AuthorizeResult := true
global _PTIO_AuthorizeTargetPath := ""
global _PTIO_AuthorizeExpectedTarget := ""
global _PTIO_AuthorizeExpectedStage := ""
global _PTIO_AuthorizeSawCompleteStage := false
global _PTIO_AuthorizeSawOldTarget := false

; A byte-atomic rename still publishes stale editor state unless the session
; guard runs after the yield-capable stage writer and immediately before rename
_PTIO_AuthorizeAtomicPublish() {
	global _PTIO_AtomicEvents, _PTIO_AtomicStagePath
	global _PTIO_AuthorizeResult, _PTIO_AuthorizeTargetPath
	global _PTIO_AuthorizeExpectedTarget, _PTIO_AuthorizeExpectedStage
	global _PTIO_AuthorizeSawCompleteStage, _PTIO_AuthorizeSawOldTarget
	_PTIO_AtomicEvents.Push("authorize")
	_PTIO_AuthorizeSawCompleteStage := _PTIO_AtomicStagePath != ""
		&& FileExist(_PTIO_AtomicStagePath)
		&& FileRead(_PTIO_AtomicStagePath, "UTF-8-RAW") == _PTIO_AuthorizeExpectedStage
	_PTIO_AuthorizeSawOldTarget := FileRead(
		_PTIO_AuthorizeTargetPath, "UTF-8-RAW") == _PTIO_AuthorizeExpectedTarget
	return _PTIO_AuthorizeResult
}

_PTIO_PreRenameAuthorizationOwnsTheLastDecision() {
	global _PTIO_AtomicEvents, _PTIO_AtomicStagePath
	global _PTIO_AuthorizeResult, _PTIO_AuthorizeTargetPath
	global _PTIO_AuthorizeExpectedTarget, _PTIO_AuthorizeExpectedStage
	global _PTIO_AuthorizeSawCompleteStage, _PTIO_AuthorizeSawOldTarget
	TargetPath := A_Temp . "\\ergopti_personal_authorize_" . A_TickCount . ".toml"
	Original := "old-authoritative-personal-toml`n"
	Candidate := "new-complete-personal-toml`n"
	try {
		try FileDelete(TargetPath)
		FileAppend(Original, TargetPath, "UTF-8-RAW")
		_PTIO_AuthorizeTargetPath := TargetPath
		_PTIO_AuthorizeExpectedTarget := Original
		_PTIO_AuthorizeExpectedStage := Candidate
		_PTIO_AtomicEvents := []
		_PTIO_AtomicStagePath := ""
		_PTIO_AuthorizeSawCompleteStage := false
		_PTIO_AuthorizeSawOldTarget := false
		_PTIO_AuthorizeResult := false

		AssertFalse(_PersonalTomlWriteAtomic(TargetPath, Candidate,
			_PTIO_WriteCompleteStage.Bind(), _PTIO_RefuseAtomicReplace.Bind(), 0,
			_PTIO_AuthorizeAtomicPublish.Bind()))
		AssertEqual(2, _PTIO_AtomicEvents.Length)
		AssertEqual("write", _PTIO_AtomicEvents[1])
		AssertEqual("authorize", _PTIO_AtomicEvents[2],
			"authorization must run after the complete stage write")
		AssertTrue(_PTIO_AuthorizeSawCompleteStage,
			"the pre-rename guard must inspect a fully written candidate")
		AssertTrue(_PTIO_AuthorizeSawOldTarget,
			"authorization must run before the durable target changes")
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"a refused authorization must preserve the old durable target byte-exact")
		AssertFalse(FileExist(_PTIO_AtomicStagePath),
			"a refused authorization must clean its unpublished stage")

		_PTIO_AtomicEvents := []
		_PTIO_AtomicStagePath := ""
		_PTIO_AuthorizeResult := true
		AssertFalse(_PersonalTomlWriteAtomic(TargetPath, Candidate,
			_PTIO_WriteCompleteStage.Bind(), _PTIO_RefuseAtomicReplace.Bind(), 0,
			_PTIO_AuthorizeAtomicPublish.Bind()))
		AssertEqual(3, _PTIO_AtomicEvents.Length)
		AssertEqual("write", _PTIO_AtomicEvents[1])
		AssertEqual("authorize", _PTIO_AtomicEvents[2])
		AssertEqual("replace", _PTIO_AtomicEvents[3],
			"no publication attempt may occur before the final authorization")
	} finally {
		try FileDelete(_PTIO_AtomicStagePath)
		try FileDelete(TargetPath)
		_PTIO_AtomicEvents := []
		_PTIO_AtomicStagePath := ""
		_PTIO_AuthorizeResult := true
		_PTIO_AuthorizeTargetPath := ""
		_PTIO_AuthorizeExpectedTarget := ""
		_PTIO_AuthorizeExpectedStage := ""
	}
}
Test("personal-toml-pre-rename-guard: authorization is last and refusal preserves target",
	_PTIO_PreRenameAuthorizationOwnsTheLastDecision)

global _PTIO_GuardEpoch := 0
global _PTIO_GuardExpectedEpoch := 0
global _PTIO_GuardSuspended := false

_PTIO_WriteStageThenAdvanceEpoch(StagePath, Content) {
	global _PTIO_GuardEpoch
	Written := _PTIO_WriteCompleteStage(StagePath, Content)
	_PTIO_GuardEpoch += 1
	return Written
}

_PTIO_WriteStageThenSuspend(StagePath, Content) {
	global _PTIO_GuardSuspended
	Written := _PTIO_WriteCompleteStage(StagePath, Content)
	_PTIO_GuardSuspended := true
	return Written
}

_PTIO_AuthorizeCurrentEditorSession() {
	global _PTIO_AtomicEvents, _PTIO_GuardEpoch
	global _PTIO_GuardExpectedEpoch, _PTIO_GuardSuspended
	_PTIO_AtomicEvents.Push("authorize")
	return _PTIO_GuardEpoch == _PTIO_GuardExpectedEpoch
		&& !_PTIO_GuardSuspended
}

; Both close/reopen and Suspend can happen while the stage writer has yielded
; and either transition must invalidate the candidate before durable publication
_PTIO_SessionChangesDuringWriterRefusePublication() {
	global ScriptInformation, _ReadPersonalTomlCache
	global _PTIO_AtomicEvents, _PTIO_AtomicStagePath
	global _PTIO_GuardEpoch, _PTIO_GuardExpectedEpoch, _PTIO_GuardSuspended
	TargetPath := A_Temp . "\\ergopti_personal_session_guard_" . A_TickCount . ".toml"
	Original := "old-session-personal-toml`n"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		FileAppend(Original, TargetPath, "UTF-8-RAW")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		_PTIO_GuardExpectedEpoch := 41
		_PTIO_GuardEpoch := 41
		_PTIO_GuardSuspended := false
		_PTIO_AtomicEvents := []
		_PTIO_AtomicStagePath := ""

		AssertFalse(WritePersonalToml(_PTIO_RaceModel("epoch-change"),
			_PTIO_WriteStageThenAdvanceEpoch.Bind(), _PTIO_RefuseAtomicReplace.Bind(), 0,
			_PTIO_AuthorizeCurrentEditorSession.Bind()))
		AssertEqual(2, _PTIO_AtomicEvents.Length)
		AssertEqual("write", _PTIO_AtomicEvents[1])
		AssertEqual("authorize", _PTIO_AtomicEvents[2])
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"an epoch change during staging must refuse the stale window's rename")
		AssertFalse(FileExist(_PTIO_AtomicStagePath))

		_PTIO_GuardEpoch := 41
		_PTIO_GuardSuspended := false
		_PTIO_AtomicEvents := []
		_PTIO_AtomicStagePath := ""
		AssertFalse(WritePersonalToml(_PTIO_RaceModel("suspend-change"),
			_PTIO_WriteStageThenSuspend.Bind(), _PTIO_RefuseAtomicReplace.Bind(), 0,
			_PTIO_AuthorizeCurrentEditorSession.Bind()))
		AssertEqual(2, _PTIO_AtomicEvents.Length)
		AssertEqual("write", _PTIO_AtomicEvents[1])
		AssertEqual("authorize", _PTIO_AtomicEvents[2])
		AssertEqual(Original, FileRead(TargetPath, "UTF-8-RAW"),
			"suspend entered during staging must refuse the pending rename")
		AssertFalse(FileExist(_PTIO_AtomicStagePath))
	} finally {
		try FileDelete(_PTIO_AtomicStagePath)
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
		_PTIO_AtomicEvents := []
		_PTIO_AtomicStagePath := ""
		_PTIO_GuardEpoch := 0
		_PTIO_GuardExpectedEpoch := 0
		_PTIO_GuardSuspended := false
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
	}
}
Test("personal-toml-pre-rename-guard: epoch or suspend changes during writer refuse publication",
	_PTIO_SessionChangesDuringWriterRefusePublication)

global _PTIO_CleanupWarnCalls := 0
global _PTIO_CleanupWarnPath := ""

_PTIO_RefuseStageDelete(StagePath) {
	return false
}

_PTIO_RecordCleanupWarning(StagePath, Detail) {
	global _PTIO_CleanupWarnCalls, _PTIO_CleanupWarnPath
	_PTIO_CleanupWarnCalls += 1
	_PTIO_CleanupWarnPath := StagePath
}

_PTIO_CleanupRefusalIsVisible() {
	global _PTIO_CleanupWarnCalls, _PTIO_CleanupWarnPath
	StagePath := A_Temp . "\\ergopti_personal_cleanup_refused.tmp"
	_PTIO_CleanupWarnCalls := 0
	_PTIO_CleanupWarnPath := ""
	Cleanup := _PersonalTomlCleanupStage
	AssertFalse(Cleanup.Call(StagePath, _PTIO_RefuseStageDelete.Bind(),
		_PTIO_RecordCleanupWarning.Bind()))
	AssertEqual(1, _PTIO_CleanupWarnCalls,
		"a false cleanup result must emit the same residue warning as an exception")
	AssertEqual(StagePath, _PTIO_CleanupWarnPath)
}
Test("personal-toml-stage-hygiene: a refused cleanup is visible",
	_PTIO_CleanupRefusalIsVisible)

_PTIO_EachInvocationCapturesItsStageSequence() {
	Body := _DriverFuncBody("_PersonalTomlWriteAtomic")
	Assert(Body != "", "the personal TOML atomic writer must exist")
	Assert(InStr(Body, "LocalSeq := ++WriteSeq") > 0,
		"each invocation must atomically capture the sequence it incremented")
	Assert(InStr(Body, 'A_ScriptHwnd . "-" . LocalSeq . ".tmp"') > 0,
		"the staging path must derive from the invocation-local sequence")
}
Test("personal-toml-stage-hygiene: every invocation owns a unique local sequence",
	_PTIO_EachInvocationCapturesItsStageSequence)

global _PTIO_ReentrantReadTrigger := ""

_PTIO_WriteStageAfterRepopulatingOldCache(StagePath, Content) {
	global _PTIO_ReentrantReadTrigger
	FileAppend(Content, StagePath, "UTF-8-RAW")
	Reentrant := ReadPersonalToml()
	_PTIO_ReentrantReadTrigger := Reentrant["sections"]["race"]["entries"][1]["trigger"]
	return true
}

_PTIO_RaceModel(Trigger) {
	return Map(
		"meta_description", "Race test",
		"sections_order", ["race"],
		"sections", Map("race", Map(
			"description", "Race",
			"entries", [Map(
				"trigger", Trigger,
				"output", Trigger,
				"is_word", false,
				"auto_expand", true,
				"is_case_sensitive", false,
				"final_result", false
			)]
		))
	)
}

_PTIO_RejectsStructuralSectionIdentifiers() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\\ergopti_personal_section_identifier_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	InjectedName := "evil]]`n[injected]`n[[tail"
	try {
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		Candidate := _PTIO_RaceModel("section-id")
		Candidate["sections_order"] := [InjectedName]
		Candidate["sections"] := Map(InjectedName,
			Candidate["sections"]["race"])

		AssertFalse(WritePersonalToml(Candidate),
			"a section identifier must not be able to inject TOML headers")
		AssertFalse(FileExist(TargetPath),
			"an invalid section identifier must fail before durable publication")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal TOML: structural section identifiers are rejected",
	_PTIO_RejectsStructuralSectionIdentifiers)

_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, Label) {
	try FileDelete(TargetPath)
	AssertFalse(WritePersonalToml(Candidate),
		Label . ": the full-model writer must reject the malformed schema")
	AssertFalse(FileExist(TargetPath),
		Label . ": schema rejection must happen before durable publication")
}

_PTIO_RejectsWrongTypedFullModelPayloads() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\\ergopti_personal_model_schema_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false

		Candidate := _PTIO_RaceModel("boolean")
		Candidate["sections"]["race"]["entries"][1]["is_word"] := "false"
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "string Boolean")

		Candidate := _PTIO_RaceModel("trigger")
		Candidate["sections"]["race"]["entries"][1]["trigger"] := 42
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "numeric trigger")

		Candidate := _PTIO_RaceModel("output")
		Candidate["sections"]["race"]["entries"][1]["output"] := 42
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "numeric output")

		Candidate := _PTIO_RaceModel("description")
		Candidate["sections"]["race"]["description"] := 42
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "numeric description")

		Candidate := _PTIO_RaceModel("entries")
		Candidate["sections"]["race"]["entries"] := "not-an-array"
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "non-array entries")

		Candidate := _PTIO_RaceModel("entry")
		Candidate["sections"]["race"]["entries"] := ["not-a-map"]
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "non-map entry")

		Candidate := _PTIO_RaceModel("required")
		Candidate["sections"]["race"]["entries"][1].Delete("final_result")
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "missing Boolean")

		Candidate := _PTIO_RaceModel("strict")
		Candidate["sections"]["race"]["entries"][1]["strict_case"] := "false"
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "string strict_case")

		Candidate := _PTIO_RaceModel("meta")
		Candidate["meta_description"] := 42
		_PTIO_AssertInvalidModelRejected(Candidate, TargetPath, "numeric metadata")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal TOML: full-model payload enforces its field schema",
	_PTIO_RejectsWrongTypedFullModelPayloads)

_PTIO_PostPublishInvalidationRejectsReentrantOldCache() {
	global ScriptInformation, _ReadPersonalTomlCache, _PTIO_ReentrantReadTrigger
	TargetPath := A_Temp . "\\ergopti_personal_cache_race_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		AssertTrue(WritePersonalToml(_PTIO_RaceModel("old")))
		AssertEqual("old", ReadPersonalToml()["sections"]["race"]["entries"][1]["trigger"])

		_PTIO_ReentrantReadTrigger := ""
		Writer := WritePersonalToml
		AssertTrue(Writer.Call(_PTIO_RaceModel("new"),
			_PTIO_WriteStageAfterRepopulatingOldCache.Bind()))
		AssertEqual("old", _PTIO_ReentrantReadTrigger,
			"the injected read must prove it repopulated from the old target before rename")
		AssertEqual("new", ReadPersonalToml()["sections"]["race"]["entries"][1]["trigger"],
			"post-publish invalidation must reject the old model cached during staging")
	} finally {
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
		_PTIO_ReentrantReadTrigger := ""
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
	}
}
Test("personal-toml-cache-race: a pre-publish read cannot survive the rename",
	_PTIO_PostPublishInvalidationRejectsReentrantOldCache)
