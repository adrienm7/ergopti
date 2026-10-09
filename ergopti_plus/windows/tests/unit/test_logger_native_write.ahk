; tests/unit/test_logger_native_write.ahk

; ==============================================================================
; MODULE: Logger Native Write Receipt Tests
; DESCRIPTION:
; Real byte-range locks distinguish buffered acceptance from a persisted batch.
; Retry must append exactly once while preserving the existing UTF-8 BOM format.
; ==============================================================================

_LNW_ActiveAppendWrite(State, NestedPath, FailWrite, Handle, Bytes, ByteCount, &Written) {
	State.Readiness.Push(LoggerPrepareShutdown())
	State.Debts.Push(_LoggerHasPendingDebt())
	if NestedPath != "" {
		AssertTrue(_LoggerAppendComplete(NestedPath, "nested", false, 0, 0, 0,
			_LNW_ActiveAppendWrite.Bind(State, "", false)))
		State.Readiness.Push(LoggerPrepareShutdown())
		State.Debts.Push(_LoggerHasPendingDebt())
	}
	return _FSNativeWrite(Handle, Bytes, FailWrite ? ByteCount - 1 : ByteCount, &Written)
}

_LNW_ShutdownRefusesActiveAppend(Nested, FailWrite := false) {
	global _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_PATH_DATE
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES
	Saved := [_LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS, _LOGGER_PENDING,
		_LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_PATH_DATE,
		_LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES]
	Path := _FSWL_Path()
	NestedPath := Path . ".nested"
	State := {Readiness: [], Debts: []}
	try {
		_LOGGER_APPEND_DEBTS := Map()
		_LOGGER_APPEND_DEBT_REPAIRS := Map()
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		_LOGGER_PATH_DATE := ""
		_LOGGER_FLUSH_ACTIVE := false
		_LOGGER_FORCE_FLUSH_PENDING := false
		_LOGGER_DROPPED_LINES := 0
		FileAppend("prior", Path, "UTF-8-RAW")
		FileAppend("other", NestedPath, "UTF-8-RAW")
		AssertEqual(!FailWrite, _LoggerAppendComplete(Path, "outer", false, 0, 0, 0,
			_LNW_ActiveAppendWrite.Bind(State, Nested ? NestedPath : "", FailWrite)))
		AssertEqual(FailWrite ? "prior" : "priorouter", FileRead(Path, "UTF-8"))
		AssertEqual(Nested ? "othernested" : "other", FileRead(NestedPath, "UTF-8"))
		AssertEqual(Nested ? 3 : 1, State.Readiness.Length)
		for Index, Ready in State.Readiness {
			AssertFalse(Ready, "shutdown must refuse every still-active append scope")
			AssertTrue(State.Debts[Index], "active bytes must have an observable owner")
		}
		AssertTrue(LoggerPrepareShutdown(), "completed native appends must release shutdown")
		AssertFalse(_LoggerHasPendingDebt())
		AssertFalse(_LOGGER_FORCE_FLUSH_PENDING, "an auxiliary owner must not invent deferred flush work")
	} finally {
		for OwnedPath in [Path, NestedPath] {
			_LNW_ReleaseOwnedDebt(OwnedPath)
			if FileExist(OwnedPath)
				FileDelete(OwnedPath)
		}
		_LOGGER_APPEND_DEBTS := Saved[1]
		_LOGGER_APPEND_DEBT_REPAIRS := Saved[2]
		_LOGGER_PENDING := Saved[3]
		_LOGGER_PENDING_ERRORS := Saved[4]
		_LOGGER_SUB_PENDING := Saved[5]
		_LOGGER_PATH_DATE := Saved[6]
		_LOGGER_FLUSH_ACTIVE := Saved[7]
		_LOGGER_FORCE_FLUSH_PENDING := Saved[8]
		_LOGGER_DROPPED_LINES := Saved[9]
	}
}

for Nested in [false, true]
	Test("Logger: shutdown refuses active append nested=" . Nested
		. " (logger-active-append-shutdown)", _LNW_ShutdownRefusesActiveAppend.Bind(Nested))
Test("Logger: compensated short write releases active shutdown ownership"
	. " (logger-active-append-shutdown)", _LNW_ShutdownRefusesActiveAppend.Bind(false, true))

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk

_LNW_AppendDenied(Existing, ForceFlush) {
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	Blob := "étoile😀`r`n"
	try {
		if Existing
			FileAppend("prior:`r`n", Path, "UTF-8")
		Accepted := _LoggerAppendComplete(Path, Blob, ForceFlush, ObjBindMethod(Lock, "Open"))
		Lock.Release()
		AssertTrue(Lock.Acquired, "native denial must be established")
		AssertFalse(Accepted, "a lost buffered batch must not be acknowledged")
		AssertEqual(Existing ? "prior:`r`n" : "", FileRead(Path, "UTF-8"))
		AssertEqual(Existing ? 11 : 0, FileGetSize(Path), "rollback includes any newly introduced BOM")
		AssertTrue(_LoggerAppendComplete(Path, Blob, ForceFlush), "unlocked retry must succeed")
		Expected := (Existing ? "prior:`r`n" : "") . Blob
		AssertEqual(Expected, FileRead(Path, "UTF-8"), "retry must deliver exactly once")
		AssertEqual(StrPut(Expected, "UTF-8") + 2, FileGetSize(Path), "exactly one UTF-8 BOM remains")
	} finally {
		Lock.Release()
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Existing in [false, true] {
	for ForceFlush in [false, true]
		Test("Logger: denied native append existing=" . Existing . " forced=" . ForceFlush
			. " (logger-native-write)", _LNW_AppendDenied.Bind(Existing, ForceFlush))
}

_LNW_QueueRetry(ForceFlush) {
	global LOGGER_LOG_PATH, _LOGGER_PATH_DATE, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global _LOGGER_SUB_PENDING, _LOGGER_DROPPED_LINES
	Saved := [LOGGER_LOG_PATH, _LOGGER_PATH_DATE, _LOGGER_PENDING,
		_LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_DROPPED_LINES]
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	Line := "native-retry-é😀"
	try {
		FileAppend("prior:`r`n", Path, "UTF-8")
		Probe := Lock.Open(Path, "r", "UTF-8-RAW")
		Probe.Close()
		LOGGER_LOG_PATH := Path
		_LOGGER_PATH_DATE := ""
		_LOGGER_PENDING := [Line]
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		_LOGGER_DROPPED_LINES := 0
		_LoggerFlush(ForceFlush)
		AssertEqual(1, _LOGGER_PENDING.Length, "a refused native batch must remain owned by the queue")
		AssertEqual(Line, _LOGGER_PENDING[1])
		AssertEqual("prior:`r`n", FileRead(Path, "UTF-8"))
		Lock.Release()
		_LoggerFlush(ForceFlush)
		AssertEqual(0, _LOGGER_PENDING.Length, "only a real write may retire the batch")
		AssertEqual("prior:`r`n" . Line . "`r`n", FileRead(Path, "UTF-8"))
		_LoggerFlush(ForceFlush)
		AssertEqual("prior:`r`n" . Line . "`r`n", FileRead(Path, "UTF-8"), "empty successor flush must not duplicate delivery")
	} finally {
		LOGGER_LOG_PATH := Saved[1]
		_LOGGER_PATH_DATE := Saved[2]
		_LOGGER_PENDING := Saved[3]
		_LOGGER_PENDING_ERRORS := Saved[4]
		_LOGGER_SUB_PENDING := Saved[5]
		_LOGGER_DROPPED_LINES := Saved[6]
		Lock.Release()
		if FileExist(Path)
			FileDelete(Path)
	}
}

for ForceFlush in [false, true]
	Test("Logger: native queue retry forced=" . ForceFlush . " (logger-native-write)", _LNW_QueueRetry.Bind(ForceFlush))

_LNW_WriteBomPrefix(Count, Handle, Bytes, ByteCount, &Written) {
	return _FSNativeWrite(Handle, Bytes, Count, &Written)
}

_LNW_PartialBom(Count) {
	Path := _FSWL_Path()
	try {
		AssertFalse(_LoggerAppendComplete(Path, "é😀", true, 0, 0, 0,
			_LNW_WriteBomPrefix.Bind(Count)), "an incomplete BOM must reject the entire batch")
		AssertEqual(0, FileGetSize(Path), "rollback must remove the real native BOM prefix")
		AssertTrue(_LoggerAppendComplete(Path, "é😀", true))
		AssertEqual("é😀", FileRead(Path, "UTF-8"))
		AssertEqual(StrPut("é😀", "UTF-8") + 2, FileGetSize(Path))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Count in [1, 2]
	Test("Logger: partial native BOM bytes=" . Count . " (logger-native-write)", _LNW_PartialBom.Bind(Count))

_LNW_RefuseCompensation(FileObject, Boundary, FlushFn) {
	return false
}

_LNW_ReleaseOwnedDebt(Path) {
	global _LOGGER_APPEND_DEBTS
	Key := StrLower(Path)
	if _LOGGER_APPEND_DEBTS.Has(Key) {
		_LOGGER_APPEND_DEBTS[Key].File.Close()
		_LOGGER_APPEND_DEBTS.Delete(Key)
	}
}

_LNW_CompensationDebtBlocksSuccessor() {
	Path := _FSWL_Path()
	PartialBytes := 4
	try {
		AssertFalse(_LoggerAppendComplete(Path, "é😀", true, 0, 0,
			_LNW_RefuseCompensation, _LNW_WriteBomPrefix.Bind(PartialBytes)),
			"a partial native write with refused compensation must not be acknowledged")
		AssertEqual(PartialBytes, FileGetSize(Path),
			"the regression needs a real surviving partial prefix")
		AssertFalse(_LoggerAppendComplete(Path, "successor", true, 0, 0,
			_LNW_RefuseCompensation),
			"a successor must be fenced while the previous rollback is still owed")
		AssertEqual(PartialBytes, FileGetSize(Path),
			"a fenced successor must not add bytes after the un-repaired prefix")
		AssertTrue(_LoggerAppendComplete(Path, "é😀", true),
			"a later healthy append must first repair the exact old boundary")
		AssertEqual("é😀", FileRead(Path, "UTF-8"),
			"repair plus retry must retain exactly one logical batch")
	} finally {
		_LNW_ReleaseOwnedDebt(Path)
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("Logger: failed compensation fences successor writes (logger-compensation-debt)",
	_LNW_CompensationDebtBlocksSuccessor)

_LNW_RepairBeforeRotation(WithDebt) {
	global _LOGGER_DEBUG_ENABLED, _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS
	Saved := [_LOGGER_DEBUG_ENABLED, _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS]
	Path := _FSWL_Path()
	try {
		_LOGGER_DEBUG_ENABLED := true
		_LOGGER_APPEND_DEBTS := Map()
		_LOGGER_APPEND_DEBT_REPAIRS := Map()
		FileAppend(WithDebt ? "12345678" : "123456789012", Path, "UTF-8-RAW")
		if WithDebt {
			AssertFalse(_LoggerAppendComplete(Path, "BROKEN", false, 0, 0,
				_LNW_RefuseCompensation, _LNW_WriteBomPrefix.Bind(4)))
			AssertEqual("12345678BROK", FileRead(Path, "UTF-8"),
				"the fixture must leave a real partial append awaiting repair")
		}
		AssertTrue(LoggerAppendBoundedDebug(Path, "xyz", 16))
		if WithDebt {
			AssertEqual("", FileExist(Path . ".1"),
				"repair must precede the size decision: thirteen bytes need no rotation")
			AssertEqual("12345678xyz`r`n", FileRead(Path, "UTF-8"))
			AssertEqual(13, FileGetSize(Path))
		} else {
			AssertEqual("123456789012", FileRead(Path . ".1", "UTF-8"),
				"a healthy full file must still rotate with its exact original bytes")
			AssertEqual("xyz`r`n", FileRead(Path, "UTF-8"))
			AssertEqual(8, FileGetSize(Path), "the new file has one UTF-8 BOM")
		}
		AssertEqual(0, _LOGGER_APPEND_DEBTS.Count)
	} finally {
		_LNW_ReleaseOwnedDebt(Path)
		_LOGGER_DEBUG_ENABLED := Saved[1]
		_LOGGER_APPEND_DEBTS := Saved[2]
		_LOGGER_APPEND_DEBT_REPAIRS := Saved[3]
		for OwnedPath in [Path, Path . ".1"] {
			if FileExist(OwnedPath)
				FileDelete(OwnedPath)
		}
	}
}

for WithDebt in [true, false]
	Test("Logger: repair precedes bounded rotation debt=" . WithDebt . " (logger-debt-rotation)",
		_LNW_RepairBeforeRotation.Bind(WithDebt))

_LNW_ShutdownRepairsUnqueuedDebt(RefuseOpen) {
	global _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_PATH_DATE
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING
	Saved := [_LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS, _LOGGER_PENDING,
		_LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_PATH_DATE,
		_LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING]
	Path := _FSWL_Path()
	Lock := 0
	Mapping := 0
	View := 0
	try {
		_LOGGER_APPEND_DEBTS := Map()
		_LOGGER_APPEND_DEBT_REPAIRS := Map()
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		_LOGGER_PATH_DATE := ""
		_LOGGER_FLUSH_ACTIVE := false
		_LOGGER_FORCE_FLUSH_PENDING := false
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertFalse(_LoggerAppendComplete(Path, "BROKEN", false, 0, 0,
			_LNW_RefuseCompensation, _LNW_WriteBomPrefix.Bind(3)))
		AssertEqual("priorBRO", FileRead(Path, "UTF-8"))
		if !RefuseOpen {
			_LOGGER_FLUSH_ACTIVE := true
			AssertFalse(LoggerPrepareShutdown(), "an active flush retains terminal ownership")
			AssertTrue(_LOGGER_FORCE_FLUSH_PENDING, "refusal must preserve deferred durability")
			_LOGGER_FLUSH_ACTIVE := false
			_LOGGER_FORCE_FLUSH_PENDING := false
			Debt := 0
			AssertEqual(1, _LoggerClaimAppendDebt(Path, &Debt))
			try AssertFalse(LoggerPrepareShutdown(), "shutdown must not steal an active repair")
			finally _LoggerFinishAppendDebt(Path, Debt, false)
			AssertEqual("priorBRO", FileRead(Path, "UTF-8"))
		}
		if RefuseOpen {
			; A mapped view refuses truncation even while the writer retains its handle
			Lock := FileOpen(Path, "r", "UTF-8-RAW")
			Mapping := DllCall("CreateFileMappingW", "Ptr", Lock.Handle, "Ptr", 0,
				"UInt", 2, "UInt", 0, "UInt", 0, "Ptr", 0, "Ptr")
			AssertTrue(Mapping != 0, "the native mapping must be established")
			View := DllCall("MapViewOfFile", "Ptr", Mapping, "UInt", 4,
				"UInt", 0, "UInt", 0, "UPtr", 0, "Ptr")
			AssertTrue(View != 0, "the native mapped view must be established")
			AssertFalse(LoggerPrepareShutdown(),
				"empty queues do not permit shutdown while native compensation is refused")
			AssertTrue(_LoggerHasPendingDebt(), "refusal must retain the repair obligation")
			AssertTrue(DllCall("UnmapViewOfFile", "Ptr", View, "Int") != 0)
			View := 0
			AssertTrue(DllCall("CloseHandle", "Ptr", Mapping, "Int") != 0)
			Mapping := 0
			Lock.Close()
			Lock := 0
		}
		AssertTrue(LoggerPrepareShutdown(),
			"shutdown must repair an auxiliary append without requiring a new log message")
		AssertEqual("prior", FileRead(Path, "UTF-8"),
			"shutdown may succeed only after removing the actual incomplete prefix")
		AssertEqual(0, _LOGGER_APPEND_DEBTS.Count)
		AssertEqual(0, _LOGGER_APPEND_DEBT_REPAIRS.Count)
		AssertFalse(_LoggerHasPendingDebt())
	} finally {
		if View
			AssertTrue(DllCall("UnmapViewOfFile", "Ptr", View, "Int") != 0)
		if Mapping
			AssertTrue(DllCall("CloseHandle", "Ptr", Mapping, "Int") != 0)
		if IsObject(Lock)
			Lock.Close()
		_LNW_ReleaseOwnedDebt(Path)
		_LOGGER_APPEND_DEBTS := Saved[1]
		_LOGGER_APPEND_DEBT_REPAIRS := Saved[2]
		_LOGGER_PENDING := Saved[3]
		_LOGGER_PENDING_ERRORS := Saved[4]
		_LOGGER_SUB_PENDING := Saved[5]
		_LOGGER_PATH_DATE := Saved[6]
		_LOGGER_FLUSH_ACTIVE := Saved[7]
		_LOGGER_FORCE_FLUSH_PENDING := Saved[8]
		if FileExist(Path)
			FileDelete(Path)
	}
}

for RefuseOpen in [true, false]
	Test("Logger: shutdown repairs unqueued native debt denied=" . RefuseOpen
		. " (logger-shutdown-append-debt)", _LNW_ShutdownRepairsUnqueuedDebt.Bind(RefuseOpen))

_LNW_RepairKeepsOriginalFileOwner(ReplacePath) {
	global _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS
	SavedDebts := _LOGGER_APPEND_DEBTS
	SavedRepairs := _LOGGER_APPEND_DEBT_REPAIRS
	Path := _FSWL_Path()
	DisplacedPath := Path . ".displaced"
	Replacement := "unrelated replacement must remain intact"
	try {
		_LOGGER_APPEND_DEBTS := Map()
		_LOGGER_APPEND_DEBT_REPAIRS := Map()
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertFalse(_LoggerAppendComplete(Path, "BROKEN", false, 0, 0,
			_LNW_RefuseCompensation, _LNW_WriteBomPrefix.Bind(3)))
		AssertEqual("priorBRO", FileRead(Path, "UTF-8"))
		; Preserve the original file identity while its former path is reused
		FileMove(Path, DisplacedPath)
		if ReplacePath
			FileAppend(Replacement, Path, "UTF-8-RAW")
		AssertTrue(_LoggerRepairAppendDebt(Path,
			FSFlushFileBuffers, _LoggerTruncateAppend),
			"repair must retain authority over the original incomplete append")
		if ReplacePath
			AssertEqual(Replacement, FileRead(Path, "UTF-8"),
				"repair must never truncate the replacement at the remembered path")
		else
			AssertFalse(FileExist(Path), "repair must not recreate a vacated path")
		AssertEqual("prior", FileRead(DisplacedPath, "UTF-8"),
			"the displaced original must be repaired before releasing its debt")
		AssertEqual(0, _LOGGER_APPEND_DEBTS.Count)
		AssertEqual(0, _LOGGER_APPEND_DEBT_REPAIRS.Count)
	} finally {
		_LNW_ReleaseOwnedDebt(Path)
		_LOGGER_APPEND_DEBTS := SavedDebts
		_LOGGER_APPEND_DEBT_REPAIRS := SavedRepairs
		for OwnedPath in [Path, DisplacedPath] {
			if FileExist(OwnedPath)
				FileDelete(OwnedPath)
		}
	}
}

for ReplacePath in [true, false]
	Test("Logger: repair retains displaced native owner replacement=" . ReplacePath
		. " (logger-debt-original-owner)", _LNW_RepairKeepsOriginalFileOwner.Bind(ReplacePath))

_LNW_NestedAppendWrite(State, NestedPath, Handle, Bytes, ByteCount, &Written) {
	State.Accepted := _LoggerAppendComplete(NestedPath, "nested", true)
	State.During := FileRead(NestedPath, "UTF-8")
	return _FSNativeWrite(Handle, Bytes, 3, &Written)
}

_LNW_NestedAppendKeepsAcceptedBytes(SameFile, UseAlias := false) {
	Path := _FSWL_Path()
	NestedPath := SameFile ? Path : _FSWL_Path()
	if UseAlias {
		SplitPath(Path, &LeafName, &ParentDir)
		NestedPath := ParentDir . "\.\" . LeafName
	}
	State := {Accepted: false, During: ""}
	try {
		FileAppend("prior", Path, "UTF-8-RAW")
		if !SameFile
			FileAppend("other", NestedPath, "UTF-8-RAW")
		AssertFalse(_LoggerAppendComplete(Path, "BROKEN", false, 0, 0, 0,
			_LNW_NestedAppendWrite.Bind(State, NestedPath)))
		if State.Accepted
			AssertEqual(State.During, FileRead(NestedPath, "UTF-8"),
				"compensation must preserve the actual bytes of an accepted nested batch")
		AssertEqual(!SameFile, State.Accepted,
			"only an independent file can accept a nested append during native ownership")
		AssertEqual(SameFile ? "prior" : "othernested", State.During)
		AssertEqual("prior", FileRead(Path, "UTF-8"),
			"the refused outer append must restore its exact original boundary")
		AssertEqual(SameFile ? "prior" : "othernested", FileRead(NestedPath, "UTF-8"),
			"outer compensation must never erase an accepted nested batch")
		AssertTrue(_LoggerAppendComplete(Path, "retry", true))
		AssertEqual("priorretry", FileRead(Path, "UTF-8"))
	} finally {
		_LNW_ReleaseOwnedDebt(Path)
		if FileExist(Path)
			FileDelete(Path)
		if !SameFile && FileExist(NestedPath)
			FileDelete(NestedPath)
	}
}

for Options in [[true, false], [true, true], [false, false]]
	Test("Logger: nested append preserves accepted bytes same-file=" . Options[1]
		. " alias=" . Options[2] . " (logger-native-writer-ownership)",
		_LNW_NestedAppendKeepsAcceptedBytes.Bind(Options*))

_LNW_ReplacementPartialWrite(State, Handle, Bytes, ByteCount, &Written) {
	State.NestedEntered := true
	return _FSNativeWrite(Handle, Bytes, 3, &Written)
}

_LNW_ReplaceDuringWrite(State, Path, DisplacedPath, Handle, Bytes, ByteCount, &Written) {
	State.OuterHandle := Handle
	FileMove(Path, DisplacedPath)
	FileAppend("replacement", Path, "UTF-8-RAW")
	State.NestedAccepted := _LoggerAppendComplete(Path, "nested", false, 0, 0,
		_LNW_RefuseCompensation, _LNW_ReplacementPartialWrite.Bind(State))
	State.ReplacementDuring := FileRead(Path, "UTF-8")
	return _FSNativeWrite(Handle, Bytes, 3, &Written)
}

_LNW_ReplacementCannotStealDebt() {
	global _LOGGER_APPEND_DEBTS
	Path := _FSWL_Path()
	DisplacedPath := Path . ".displaced"
	State := {OuterHandle: 0, NestedEntered: false, NestedAccepted: true,
		ReplacementDuring: ""}
	try {
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertFalse(_LoggerAppendComplete(Path, "BROKEN", false, 0, 0,
			_LNW_RefuseCompensation, _LNW_ReplaceDuringWrite.Bind(State, Path, DisplacedPath)))
		AssertTrue(State.OuterHandle != 0, "the native replacement callback must run")
		AssertEqual("priorBRO", FileRead(DisplacedPath, "UTF-8"))
		AssertTrue(_LOGGER_APPEND_DEBTS.Has(StrLower(Path)))
		RetainedHandle := _LOGGER_APPEND_DEBTS[StrLower(Path)].File.Handle
		AssertTrue(_LoggerRepairAppendDebt(Path, FSFlushFileBuffers, _LoggerTruncateAppend))
		AssertEqual("prior", FileRead(DisplacedPath, "UTF-8"),
			"repair must not abandon the displaced original's incomplete bytes")
		AssertEqual(State.OuterHandle, RetainedHandle, "the outer native owner must retain its debt")
		AssertFalse(State.NestedAccepted)
		AssertFalse(State.NestedEntered, "a replacement must wait before its native write callback")
		AssertEqual("replacement", State.ReplacementDuring)
		AssertEqual("replacement", FileRead(Path, "UTF-8"))
		AssertTrue(_LoggerAppendComplete(Path, "retry", true), "completed ownership must be released")
		AssertEqual("replacementretry", FileRead(Path, "UTF-8"))
	} finally {
		_LNW_ReleaseOwnedDebt(Path)
		for OwnedPath in [Path, DisplacedPath] {
			if FileExist(OwnedPath)
				FileDelete(OwnedPath)
		}
	}
}
Test("Logger: replacement cannot steal retained append debt (logger-replacement-owner)",
	_LNW_ReplacementCannotStealDebt)
