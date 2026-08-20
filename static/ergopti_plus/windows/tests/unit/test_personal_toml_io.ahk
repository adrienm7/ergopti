; tests/unit/test_personal_toml_io.ahk

; ==============================================================================
; MODULE: Personal Information TOML Tests
; DESCRIPTION:
; Verifies that the personal-information reader loads both serialized sections.
;
; The writer has always emitted [info] and [letters], but the reader previously
; ignored [letters]. This test keeps the alias map and its cache in the same
; atomic contract as the user-visible value map.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ Personal TOML section loading ===========
; =====================================================
; =====================================================

_PTIO_LoadsLettersAtomically() {
	global PersonalInformation, PersonalInformationLetters, _ReadPersonalInfoTomlCache
	Path := A_Temp . "\\ergopti_personal_toml_letters_test.toml"
	SavedInfo := IsSet(PersonalInformation) ? PersonalInformation : Map()
	SavedLetters := IsSet(PersonalInformationLetters) ? PersonalInformationLetters : Map()
	SavedCache := IsSet(_ReadPersonalInfoTomlCache) ? _ReadPersonalInfoTomlCache : false
	Q := Chr(34)
	try {
		try FileDelete(Path)
		FileAppend("[info]`nfirst_name = " . Q . "Ada" . Q . "`n[letters]`nn = " . Q . "first_name" . Q . "`n", Path, "UTF-8")
		PersonalInformation := Map("first_name", "Default")
		PersonalInformationLetters := Map("p", "first_name")
		_ReadPersonalInfoTomlCache := false
		ReadPersonalInfoToml(Path)
		AssertEqual("Ada", PersonalInformation["first_name"], "[info] must load before aliases resolve")
		AssertEqual("first_name", PersonalInformationLetters["n"], "[letters] alias must be loaded")
		AssertFalse(PersonalInformationLetters.Has("p"), "a present [letters] section must atomically replace stale aliases")
		_ReadPersonalInfoTomlCache := false
		PersonalInformation := Map("first_name", "Changed")
		PersonalInformationLetters := Map()
		ReadPersonalInfoToml(Path)
		AssertEqual("first_name", PersonalInformationLetters["n"], "cached read must restore letters with info")
	} finally {
		try FileDelete(Path)
		PersonalInformation := SavedInfo
		PersonalInformationLetters := SavedLetters
		_ReadPersonalInfoTomlCache := SavedCache
	}
}
Test("personal TOML: [letters] aliases load and cache atomically (personal-toml-letters-not-loaded)", _PTIO_LoadsLettersAtomically)

; F06 (audit 2026-07-20): WritePersonalToml evicted only its own editor-model cache
; (_ReadPersonalTomlCache), never the raw-content _TomlFileCache that the engine
; loader and prefix-watcher read. So after an editor save, the next live rebuild
; (any tray hotstring toggle -> RebuildHotstringsLive) re-read the stale boot-time
; file content and silently reverted the saved edit. Source-scan the writer body
; (a behavioural call would write to the real PersonalTomlPath) to assert it evicts
; the reader-shared cache via _ParseTomlGroupConfig_InvalidatePath.
_PTIO_WriteEvictsReaderSharedCache() {
	Body := _DriverFuncBody("WritePersonalToml")
	Assert(Body != "", "WritePersonalToml must exist in infra/hotstrings/personal_toml_io.ahk")
	InvalidateBody := _DriverFuncBody("_PersonalTomlInvalidateCaches")
	Assert(InvalidateBody != "", "the personal TOML cache invalidator must exist")
	Assert(InStr(InvalidateBody, "_ParseTomlGroupConfig_InvalidatePath") > 0,
		"the shared invalidator must evict the reader-shared _TomlFileCache")
	Needle := "_PersonalTomlInvalidateCaches(FilePath)"
	InvalidateCalls := Floor(
		(StrLen(Body) - StrLen(StrReplace(Body, Needle, ""))) / StrLen(Needle))
	Assert(InvalidateCalls >= 2,
		"WritePersonalToml must invalidate before serialization and again after the terminal atomic attempt")
}
Test("personal-toml-cache-race: writer evicts every derived reader cache",
	_PTIO_WriteEvictsReaderSharedCache)





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





; =====================================================
; =====================================================
; ======= 3/ Metadata-preserving round trips =========
; =====================================================
; =====================================================

; The personal editor persists the complete model returned by ReadPersonalToml.
; If that model omits a known [_meta] or [_meta.sections.<name>] override, the
; otherwise-successful full rewrite silently deletes configuration owned by the
; hotstring config window. Exercise the public read/write pair against the real
; configured path and verify the resulting file semantically through the normal
; group-config parser, while also proving that the hotstring payload survives.
_PTIO_ReadWritePreservesKnownMetadataOverrides() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\\ergopti_personal_meta_roundtrip_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	Q := Chr(34)
	Content := "[_meta]`n"
		. "description = " . Q . "Metadata round-trip" . Q . "`n"
		. "sections_order = [" . Q . "alpha" . Q . "]`n"
		. "delay = 0.61`n"
		. "color = " . Q . "#112233" . Q . "`n"
		. "priority = 41`n"
		. "show_tooltip = false`n"
		. "`n[_meta.sections.alpha]`n"
		. "delay = 0.17`n"
		. "color = " . Q . "#AABBCC" . Q . "`n"
		. "priority = 73`n"
		. "show_tooltip = true`n"
		. "`n[[alpha]]`n"
		. Q . "zz" . Q . " = { output = " . Q . "KEPT" . Q
		. ", is_word = false, auto_expand = true"
		. ", is_case_sensitive = false, final_result = false }`n"
	try {
		try FileDelete(TargetPath)
		FileAppend(Content, TargetPath, "UTF-8")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false

		Model := ReadPersonalToml()
		AssertTrue(WritePersonalToml(Model),
			"the full-model personal TOML rewrite must succeed")

		Config := ParseTomlGroupConfig("", TargetPath)
		AssertEqual(0.61, Config.Delay,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] delay")
		AssertEqual("#112233", Config.Color,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] color")
		AssertEqual(41, Config.Priority,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] priority")
		AssertEqual(false, Config.ShowTooltip,
			"ReadPersonalToml -> WritePersonalToml must preserve [_meta] show_tooltip=false")
		SectionConfig := Config.Sections.Get("alpha",
			{ Delay: "", Color: "", Priority: "", ShowTooltip: "" })
		AssertEqual(0.17, SectionConfig.Delay,
			"the rewrite must preserve [_meta.sections.alpha] delay")
		AssertEqual("#AABBCC", SectionConfig.Color,
			"the rewrite must preserve [_meta.sections.alpha] color")
		AssertEqual(73, SectionConfig.Priority,
			"the rewrite must preserve [_meta.sections.alpha] priority")
		AssertEqual(true, SectionConfig.ShowTooltip,
			"the rewrite must preserve [_meta.sections.alpha] show_tooltip=true")

		_ReadPersonalTomlCache := false
		RoundTripped := ReadPersonalToml()
		EntrySignature := ""
		if RoundTripped["sections"].Has("alpha")
			&& RoundTripped["sections"]["alpha"]["entries"].Length == 1 {
			Entry := RoundTripped["sections"]["alpha"]["entries"][1]
			EntrySignature := Entry["trigger"] . "=>" . Entry["output"]
		}
		AssertEqual("zz=>KEPT", EntrySignature,
			"the existing hotstring entry must remain intact through the same rewrite")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-toml-meta-roundtrip: known overrides and entries survive a full rewrite",
	_PTIO_ReadWritePreservesKnownMetadataOverrides)

_PTIO_DuplicateOrderToml() {
	Q := Chr(34)
	return "[_meta]`n"
		. "description = " . Q . "Duplicate order" . Q . "`n"
		. "sections_order = [" . Q . "alpha" . Q . ", "
		. Q . "ALPHA" . Q . ", " . Q . "alpha" . Q . "]`n"
		. "`n[_meta.sections]`n"
		. "alpha = " . Q . "Alpha" . Q . "`n"
		. "`n[[alpha]]`n"
		. Q . "once" . Q . " = { output = " . Q . "ONE" . Q
		. ", is_word = false, auto_expand = true"
		. ", is_case_sensitive = false, final_result = false }`n"
}

_PTIO_DuplicateMetaOrderParsesOneCanonicalSection() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\ergopti_personal_duplicate_order_read_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		FileAppend(_PTIO_DuplicateOrderToml(), TargetPath, "UTF-8")
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false

		Model := ReadPersonalToml()
		AssertEqual(1, Model["sections_order"].Length,
			"duplicate and case-equivalent metadata names must collapse at parse time")
		AssertEqual("alpha", Model["sections_order"][1])
		AssertEqual(1, Model["sections"].Count,
			"one extant section must have one canonical order position")
		AssertEqual(1, Model["sections"]["alpha"]["entries"].Length,
			"metadata duplication must not duplicate the section payload")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-toml-order-dedup: duplicate metadata parses one canonical section",
	_PTIO_DuplicateMetaOrderParsesOneCanonicalSection)

_PTIO_DuplicateCandidateOrderStaysCanonicalAcrossTwoCycles() {
	global ScriptInformation, _ReadPersonalTomlCache
	TargetPath := A_Temp . "\ergopti_personal_duplicate_order_write_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	OldCache := _ReadPersonalTomlCache
	try {
		try FileDelete(TargetPath)
		ScriptInformation["PersonalTomlPath"] := TargetPath
		_ReadPersonalTomlCache := false
		Candidate := _PTIO_RaceModel("once")
		Candidate["sections_order"] := ["race", "RACE", "race"]

		AssertTrue(WritePersonalToml(Candidate),
			"the writer must accept and canonicalize duplicate order metadata")
		FirstCycle := ReadPersonalToml()
		AssertEqual(1, FirstCycle["sections_order"].Length)
		AssertEqual(1, FirstCycle["sections"]["race"]["entries"].Length,
			"the first write must emit the section and its entry exactly once")

		AssertTrue(WritePersonalToml(FirstCycle),
			"a second parse/write cycle must remain writable")
		SecondCycle := ReadPersonalToml()
		AssertEqual(1, SecondCycle["sections_order"].Length,
			"two cycles must not reintroduce duplicate order tokens")
		AssertEqual(1, SecondCycle["sections"]["race"]["entries"].Length,
			"two cycles must not multiply a duplicated section entry")

		Raw := FileRead(TargetPath, "UTF-8")
		BlockNeedle := "[[race]]"
		BlockCount := Floor((StrLen(Raw)
			- StrLen(StrReplace(Raw, BlockNeedle, ""))) / StrLen(BlockNeedle))
		MetaNeedle := 'race = "Race"'
		MetaCount := Floor((StrLen(Raw)
			- StrLen(StrReplace(Raw, MetaNeedle, ""))) / StrLen(MetaNeedle))
		AssertEqual(1, BlockCount,
			"the durable candidate must contain one [[race]] block")
		AssertEqual(1, MetaCount,
			"the durable candidate must contain one race description metadata row")
	} finally {
		try FileDelete(TargetPath)
		try _ParseTomlGroupConfig_InvalidatePath(TargetPath)
		ScriptInformation["PersonalTomlPath"] := OldPath
		_ReadPersonalTomlCache := OldCache
	}
}
Test("personal-toml-order-dedup: two cycles keep one section and one entry",
	_PTIO_DuplicateCandidateOrderStaysCanonicalAcrossTwoCycles)





; =============================================================
; =============================================================
; ======= 4/ Metadata patch transactions =====================
; =============================================================
; =============================================================

global _PTIOP_Path := ""
global _PTIOP_Original := ""
global _PTIOP_Candidate := ""
global _PTIOP_BuildInput := ""
global _PTIOP_Events := []
global _PTIOP_NestedResult := true
global _PTIOP_NestedReaderCalls := 0
global _PTIOP_NestedWriterCalls := 0
global _PTIOP_ReplaceCalls := 0
global _PTIOP_StagePath := ""
global _PTIOP_ReaderSawOwner := false
global _PTIOP_WriterSawOldTarget := false
global _PTIOP_ReplaceSawOldTarget := false
global _PTIOP_StageSameDirectory := false
global _PTIOP_StageIsDistinct := false

_PTIOP_Reset(Path, Original, Candidate) {
	global _PTIOP_Path, _PTIOP_Original, _PTIOP_Candidate
	global _PTIOP_BuildInput, _PTIOP_Events, _PTIOP_NestedResult
	global _PTIOP_NestedReaderCalls, _PTIOP_NestedWriterCalls
	global _PTIOP_ReplaceCalls, _PTIOP_StagePath, _PTIOP_ReaderSawOwner
	global _PTIOP_WriterSawOldTarget, _PTIOP_ReplaceSawOldTarget
	global _PTIOP_StageSameDirectory, _PTIOP_StageIsDistinct
	_PTIOP_Path := Path
	_PTIOP_Original := Original
	_PTIOP_Candidate := Candidate
	_PTIOP_BuildInput := ""
	_PTIOP_Events := []
	_PTIOP_NestedResult := true
	_PTIOP_NestedReaderCalls := 0
	_PTIOP_NestedWriterCalls := 0
	_PTIOP_ReplaceCalls := 0
	_PTIOP_StagePath := ""
	_PTIOP_ReaderSawOwner := false
	_PTIOP_WriterSawOldTarget := false
	_PTIOP_ReplaceSawOldTarget := false
	_PTIOP_StageSameDirectory := false
	_PTIOP_StageIsDistinct := false
}

_PTIOP_BuildCandidate(CurrentContent) {
	global _PTIOP_BuildInput, _PTIOP_Candidate, _PTIOP_Events
	_PTIOP_Events.Push("build")
	_PTIOP_BuildInput := CurrentContent
	return _PTIOP_Candidate
}

_PTIOP_NestedBuildCandidate(CurrentContent) {
	return CurrentContent . "nested-writer-must-not-run`n"
}

_PTIOP_NestedReader(Path) {
	global _PTIOP_NestedReaderCalls
	_PTIOP_NestedReaderCalls += 1
	return FileRead(Path, "UTF-8-RAW")
}

_PTIOP_NestedWriter(StagePath, Content) {
	global _PTIOP_NestedWriterCalls
	_PTIOP_NestedWriterCalls += 1
	FileAppend(Content, StagePath, "UTF-8-RAW")
	return true
}

_PTIOP_AtomicReplace(StagePath, TargetPath) {
	return FSAtomicMoveReplace(StagePath, TargetPath)
}

_PTIOP_OuterReaderAttemptsNestedCommit(Path) {
	global _PTIOP_Events, _PTIOP_NestedResult, _PTIOP_ReaderSawOwner
	_PTIOP_Events.Push("read")
	Probe := _PersonalTomlWriteLeaseTryAcquire(Path, "reader-probe")
	_PTIOP_ReaderSawOwner := !(Probe is Object)
	if Probe is Object
		_PersonalTomlWriteLeaseRelease(Probe)
	AliasPath := StrUpper(StrReplace(Path, "\", "/"))
	_PTIOP_NestedResult := _PersonalTomlCommitPatch(AliasPath,
		_PTIOP_NestedBuildCandidate.Bind(), _PTIOP_NestedReader.Bind(),
		_PTIOP_NestedWriter.Bind(), _PTIOP_AtomicReplace.Bind(), 0, 0)
	return FileRead(Path, "UTF-8-RAW")
}

_PTIOP_ReadCurrent(Path) {
	global _PTIOP_Events
	_PTIOP_Events.Push("read")
	return FileRead(Path, "UTF-8-RAW")
}

_PTIOP_WriteCompleteStage(StagePath, Content) {
	global _PTIOP_Path, _PTIOP_Original, _PTIOP_Events, _PTIOP_StagePath
	global _PTIOP_WriterSawOldTarget, _PTIOP_StageSameDirectory
	global _PTIOP_StageIsDistinct
	_PTIOP_Events.Push("write")
	_PTIOP_StagePath := StagePath
	_PTIOP_WriterSawOldTarget := FileRead(
		_PTIOP_Path, "UTF-8-RAW") == _PTIOP_Original
	SplitPath(StagePath, , &StageDir)
	SplitPath(_PTIOP_Path, , &TargetDir)
	_PTIOP_StageSameDirectory := StrLower(StageDir) == StrLower(TargetDir)
	_PTIOP_StageIsDistinct := StrLower(StagePath) != StrLower(_PTIOP_Path)
	FileAppend(Content, StagePath, "UTF-8-RAW")
	return true
}

_PTIOP_WritePartialThenRefuse(StagePath, Content) {
	global _PTIOP_StagePath, _PTIOP_Events
	_PTIOP_Events.Push("write-false")
	_PTIOP_StagePath := StagePath
	FileAppend("partial-stage", StagePath, "UTF-8-RAW")
	return false
}

_PTIOP_WritePartialThenThrow(StagePath, Content) {
	global _PTIOP_StagePath, _PTIOP_Events
	_PTIOP_Events.Push("write-throw")
	_PTIOP_StagePath := StagePath
	FileAppend("partial-stage-before-throw", StagePath, "UTF-8-RAW")
	throw Error("injected metadata patch stage failure")
}

_PTIOP_RefuseReplace(StagePath, TargetPath) {
	global _PTIOP_ReplaceCalls, _PTIOP_Events
	_PTIOP_ReplaceCalls += 1
	_PTIOP_Events.Push("replace-false")
	return false
}

_PTIOP_ReplaceCompleteStage(StagePath, TargetPath) {
	global _PTIOP_Candidate, _PTIOP_Original, _PTIOP_Events
	global _PTIOP_ReplaceCalls, _PTIOP_ReplaceSawOldTarget
	_PTIOP_ReplaceCalls += 1
	_PTIOP_Events.Push("replace")
	_PTIOP_ReplaceSawOldTarget := FileRead(
		TargetPath, "UTF-8-RAW") == _PTIOP_Original
	if (FileRead(StagePath, "UTF-8-RAW") != _PTIOP_Candidate)
		return false
	return FSAtomicMoveReplace(StagePath, TargetPath)
}

_PTIOP_BuffersEqual(Expected, Actual) {
	if !(Expected is Buffer) || !(Actual is Buffer)
		return false
	if (Expected.Size != Actual.Size)
		return false
	loop Expected.Size {
		Offset := A_Index - 1
		if (NumGet(Expected, Offset, "UChar") != NumGet(Actual, Offset, "UChar"))
			return false
	}
	return true
}

_PTIOP_AssertTargetBytes(Path, Expected, Message) {
	AssertTrue(_PTIOP_BuffersEqual(Expected, FileRead(Path, "RAW")), Message)
}

_PTIOP_AssertLeaseFree(Path, Message) {
	Token := _PersonalTomlWriteLeaseTryAcquire(Path, "post-transaction-test")
	try {
		AssertTrue(Token is Object, Message)
	} finally {
		if Token is Object
			_PersonalTomlWriteLeaseRelease(Token)
	}
}

; The read is part of the read-modify-write transaction. Acquiring ownership
; after it leaves a window where a sibling can publish another candidate that
; the first reader then overwrites with its stale snapshot
_PTIOP_MetadataPatchOwnsPathBeforeReading() {
	global _PTIOP_NestedResult, _PTIOP_NestedReaderCalls
	global _PTIOP_NestedWriterCalls, _PTIOP_ReaderSawOwner
	global _PTIOP_BuildInput, _PTIOP_Events
	Path := A_Temp . "\\ergopti_hcw_patch_owner_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	Original := "[_meta]`npriority = 1`n"
	Candidate := "[_meta]`npriority = 2`n"
	try {
		try FileDelete(Path)
		FileAppend(Original, Path, "UTF-8-RAW")
		_PTIOP_Reset(Path, Original, Candidate)
		AssertTrue(_PersonalTomlCommitPatch(Path,
			_PTIOP_BuildCandidate.Bind(),
			_PTIOP_OuterReaderAttemptsNestedCommit.Bind(),
			_PTIOP_WriteCompleteStage.Bind(),
			_PTIOP_ReplaceCompleteStage.Bind(), 0, 0))
		AssertTrue(_PTIOP_ReaderSawOwner,
			"the personal-path lease must already exist when the reader starts")
		AssertFalse(_PTIOP_NestedResult,
			"a same-path transaction injected by the reader must be refused")
		AssertEqual(0, _PTIOP_NestedReaderCalls,
			"the losing nested transaction must stop before reading stale state")
		AssertEqual(0, _PTIOP_NestedWriterCalls,
			"the losing nested transaction must never enter its writer")
		AssertEqual(Original, _PTIOP_BuildInput,
			"the owning transaction must build from the content its reader returned")
		AssertEqual(4, _PTIOP_Events.Length)
		AssertEqual("read", _PTIOP_Events[1])
		AssertEqual("build", _PTIOP_Events[2])
		AssertEqual("write", _PTIOP_Events[3])
		AssertEqual("replace", _PTIOP_Events[4])
		AssertEqual(Candidate, FileRead(Path, "UTF-8-RAW"))
		_PTIOP_AssertLeaseFree(Path,
			"a successful metadata patch must release its personal-path owner")
	} finally {
		try FileDelete(Path)
	}
}
Test("hcw-personal-meta-transaction: ownership precedes the read and rejects reentry",
	_PTIOP_MetadataPatchOwnsPathBeforeReading)

; Every fallible pre-publication step must operate on a disposable stage. The
; byte comparison deliberately includes a BOM, CRLF and non-ASCII content so a
; truncate-and-rewrite implementation cannot pass through text equivalence
_PTIOP_MetadataPatchFailuresPreserveTargetBytes() {
	global _PTIOP_ReplaceCalls, _PTIOP_StagePath
	Path := A_Temp . "\\ergopti_hcw_patch_failure_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	Q := Chr(34)
	Original := Chr(0xFEFF) . "[_meta]`r`ndescription = " . Q
		. "café durable" . Q . "`r`npriority = 7`r`n"
	Candidate := "[_meta]`npriority = 99`n"
	try {
		try FileDelete(Path)
		FileAppend(Original, Path, "UTF-8-RAW")
		OriginalBytes := FileRead(Path, "RAW")

		_PTIOP_Reset(Path, Original, Candidate)
		AssertFalse(_PersonalTomlCommitPatch(Path,
			_PTIOP_BuildCandidate.Bind(), _PTIOP_ReadCurrent.Bind(),
			_PTIOP_WritePartialThenRefuse.Bind(), _PTIOP_RefuseReplace.Bind(),
			0, 0))
		_PTIOP_AssertTargetBytes(Path, OriginalBytes,
			"a false stage writer must preserve the durable target byte-exact")
		AssertEqual(0, _PTIOP_ReplaceCalls,
			"a false stage writer must abort before atomic replacement")
		AssertFalse(FileExist(_PTIOP_StagePath),
			"a false stage writer must not leave its partial candidate behind")
		_PTIOP_AssertLeaseFree(Path,
			"a false stage writer must release personal-path ownership")

		_PTIOP_Reset(Path, Original, Candidate)
		AssertFalse(_PersonalTomlCommitPatch(Path,
			_PTIOP_BuildCandidate.Bind(), _PTIOP_ReadCurrent.Bind(),
			_PTIOP_WritePartialThenThrow.Bind(), _PTIOP_RefuseReplace.Bind(),
			0, 0))
		_PTIOP_AssertTargetBytes(Path, OriginalBytes,
			"a throwing stage writer must preserve the durable target byte-exact")
		AssertEqual(0, _PTIOP_ReplaceCalls,
			"a throwing stage writer must abort before atomic replacement")
		AssertFalse(FileExist(_PTIOP_StagePath),
			"a throwing stage writer must clean its partial candidate")
		_PTIOP_AssertLeaseFree(Path,
			"a throwing stage writer must release personal-path ownership")

		_PTIOP_Reset(Path, Original, Candidate)
		AssertFalse(_PersonalTomlCommitPatch(Path,
			_PTIOP_BuildCandidate.Bind(), _PTIOP_ReadCurrent.Bind(),
			_PTIOP_WriteCompleteStage.Bind(), _PTIOP_RefuseReplace.Bind(), 0, 0))
		_PTIOP_AssertTargetBytes(Path, OriginalBytes,
			"a refused atomic replace must preserve the durable target byte-exact")
		AssertEqual(1, _PTIOP_ReplaceCalls)
		AssertFalse(FileExist(_PTIOP_StagePath),
			"a refused replace must clean its complete unpublished candidate")
		_PTIOP_AssertLeaseFree(Path,
			"a refused replace must release personal-path ownership")
	} finally {
		try FileDelete(_PTIOP_StagePath)
		try FileDelete(Path)
	}
}
Test("hcw-personal-meta-transaction: every pre-publish failure preserves target bytes",
	_PTIOP_MetadataPatchFailuresPreserveTargetBytes)

; The only successful publication is a same-directory atomic rename. The
; writer and replacement seams observe the old durable file on both sides of
; staging, proving no in-place target handle was opened first
_PTIOP_MetadataPatchPublishesOnlyFromSameDirectoryStage() {
	global _PTIOP_WriterSawOldTarget, _PTIOP_ReplaceSawOldTarget
	global _PTIOP_StageSameDirectory, _PTIOP_StageIsDistinct
	global _PTIOP_ReplaceCalls, _PTIOP_Events
	Path := A_Temp . "\\ergopti_hcw_patch_success_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	Original := "[_meta]`nshow_tooltip = true`n"
	Candidate := "[_meta]`nshow_tooltip = false`n"
	try {
		try FileDelete(Path)
		FileAppend(Original, Path, "UTF-8-RAW")
		_PTIOP_Reset(Path, Original, Candidate)
		AssertTrue(_PersonalTomlCommitPatch(Path,
			_PTIOP_BuildCandidate.Bind(), _PTIOP_ReadCurrent.Bind(),
			_PTIOP_WriteCompleteStage.Bind(),
			_PTIOP_ReplaceCompleteStage.Bind(), 0, 0))
		AssertTrue(_PTIOP_StageSameDirectory,
			"the candidate stage must share the durable target directory")
		AssertTrue(_PTIOP_StageIsDistinct,
			"the stage must never alias the durable target")
		AssertTrue(_PTIOP_WriterSawOldTarget,
			"the target must remain intact while the stage is written")
		AssertTrue(_PTIOP_ReplaceSawOldTarget,
			"the target must remain intact until the atomic replace callback")
		AssertEqual(1, _PTIOP_ReplaceCalls,
			"one successful patch must publish through exactly one atomic replace")
		AssertEqual(Candidate, FileRead(Path, "UTF-8-RAW"))
		AssertEqual(4, _PTIOP_Events.Length)
		AssertEqual("read", _PTIOP_Events[1])
		AssertEqual("build", _PTIOP_Events[2])
		AssertEqual("write", _PTIOP_Events[3])
		AssertEqual("replace", _PTIOP_Events[4])
		_PTIOP_AssertLeaseFree(Path,
			"a successful atomic publication must release personal-path ownership")
	} finally {
		try FileDelete(Path)
	}
}
Test("hcw-personal-meta-transaction: success uses one same-directory atomic replace",
	_PTIOP_MetadataPatchPublishesOnlyFromSameDirectoryStage)





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
