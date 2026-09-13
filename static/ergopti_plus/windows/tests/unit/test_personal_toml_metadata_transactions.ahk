; tests/unit/test_personal_toml_metadata_transactions.ahk

; ==============================================================================
; MODULE: Personal TOML Metadata Transaction Tests
; DESCRIPTION: Verify path ownership, staged failures and atomic metadata publication.
; ==============================================================================

#Requires AutoHotkey v2.0





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
