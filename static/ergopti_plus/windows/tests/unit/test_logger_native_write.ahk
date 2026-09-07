; tests/unit/test_logger_native_write.ahk

; ==============================================================================
; MODULE: Logger Native Write Receipt Tests
; DESCRIPTION:
; Real byte-range locks distinguish buffered acceptance from a persisted batch.
; Retry must append exactly once while preserving the existing UTF-8 BOM format.
; ==============================================================================

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
			Boundary := 0
			AssertEqual(1, _LoggerClaimAppendDebt(Path, &Boundary))
			try AssertFalse(LoggerPrepareShutdown(), "shutdown must not steal an active repair")
			finally _LoggerFinishAppendDebt(Path, Boundary, false)
			AssertEqual("priorBRO", FileRead(Path, "UTF-8"))
		}
		if RefuseOpen {
			Lock := FileOpen(Path, "r-rwd", "UTF-8-RAW")
			AssertTrue(IsObject(Lock), "the native sharing denial must be established")
			AssertFalse(LoggerPrepareShutdown(),
				"empty queues do not permit shutdown while native compensation is refused")
			AssertTrue(_LoggerHasPendingDebt(), "refusal must retain the repair obligation")
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
		if IsObject(Lock)
			Lock.Close()
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
