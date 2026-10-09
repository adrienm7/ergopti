; tests/unit/test_logger_shutdown_sinks.ahk

; ==============================================================================
; MODULE: Logger Shutdown Sink Tests
; DESCRIPTION:
; Native sharing denial verifies terminal debt independently for every queue.
; The fixture restores borrowed state even when an assertion fails.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk

_LSS_Queue(Sink) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	return Sink == "main" ? _LOGGER_PENDING
		: Sink == "errors" ? _LOGGER_PENDING_ERRORS : _LOGGER_SUB_PENDING.Get("fixture", [])
}

_LSS_Shutdown(Sink) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_SUB_PATHS, _LOGGER_PATH_DATE
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES
	Saved := {
		Queues: [_LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING],
		Paths: [LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_SUB_PATHS, _LOGGER_PATH_DATE],
		Flags: [_LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES]
	}
	Path := _FSWL_Path()
	Seed := "existing-shutdown-log`r`n"
	Line := "retained-" . Sink . "-shutdown-debt"
	Owned := false
	Lock := 0
	try {
		Owned := FSWriteCreateDurable(Path, Seed)
		AssertTrue(Owned, "the fixture must exclusively create its sink")
		Lock := FileOpen(Path, "r-w", "UTF-8")
		AssertTrue(IsObject(Lock), "the real read handle must deny concurrent writers")
		_LOGGER_PENDING := Sink == "main" ? [Line] : []
		_LOGGER_PENDING_ERRORS := Sink == "errors" ? [Line] : []
		_LOGGER_SUB_PENDING := Sink == "topical" ? Map("fixture", [Line]) : Map()
		LOGGER_LOG_PATH := Sink == "main" ? Path : ""
		LOGGER_ERRORS_LOG_PATH := Sink == "errors" ? Path : ""
		_LOGGER_SUB_PATHS := Sink == "topical" ? Map("fixture", Path) : Map()
		; An empty date preserves the exact fixture paths without a rollover.
		_LOGGER_PATH_DATE := ""
		_LOGGER_DROPPED_LINES := 0
		_LOGGER_FORCE_FLUSH_PENDING := false
		_LOGGER_FLUSH_ACTIVE := true
		AssertFalse(LoggerPrepareShutdown(), "an active flush must retain shutdown ownership")
		AssertEqual(1, _LSS_Queue(Sink).Length)
		AssertEqual(Line, _LSS_Queue(Sink)[1])

		_LOGGER_FLUSH_ACTIVE := false
		AssertFalse(LoggerPrepareShutdown(), "a denied " . Sink . " sink must prevent shutdown")
		AssertEqual(1, _LSS_Queue(Sink).Length, "refused delivery must retain the exact debt")
		AssertEqual(Line, _LSS_Queue(Sink)[1])
		AssertEqual(Seed, FileRead(Path, "UTF-8"), "denied delivery must leave existing bytes intact")
		AssertEqual(StrPut(Seed, "UTF-8") - 1, FileGetSize(Path))

		Lock.Close()
		Lock := 0
		AssertTrue(LoggerPrepareShutdown(), "released sharing denial must permit durable shutdown")
		AssertEqual(0, _LOGGER_PENDING.Length)
		AssertEqual(0, _LOGGER_PENDING_ERRORS.Length)
		AssertEqual(0, _LOGGER_SUB_PENDING.Count)
		Expected := Seed . Line . "`r`n"
		AssertEqual(Expected, FileRead(Path, "UTF-8"), "the exact debt must reach its own sink once")
		AssertEqual(StrPut(Expected, "UTF-8") - 1, FileGetSize(Path))
		AssertTrue(LoggerPrepareShutdown(), "a repeated preflight must remain successful")
		AssertEqual(Expected, FileRead(Path, "UTF-8"), "a repeated preflight must not duplicate delivery")
	} finally {
		try {
			if IsObject(Lock)
				Lock.Close()
			if Owned
				FileDelete(Path)
		} finally {
			_LOGGER_PENDING := Saved.Queues[1]
			_LOGGER_PENDING_ERRORS := Saved.Queues[2]
			_LOGGER_SUB_PENDING := Saved.Queues[3]
			LOGGER_LOG_PATH := Saved.Paths[1]
			LOGGER_ERRORS_LOG_PATH := Saved.Paths[2]
			_LOGGER_SUB_PATHS := Saved.Paths[3]
			_LOGGER_PATH_DATE := Saved.Paths[4]
			_LOGGER_FLUSH_ACTIVE := Saved.Flags[1]
			_LOGGER_FORCE_FLUSH_PENDING := Saved.Flags[2]
			_LOGGER_DROPPED_LINES := Saved.Flags[3]
		}
	}
}
Test("Logger: shutdown refuses active or non-durable flush debt (AHK-090)",
	_LSS_Shutdown.Bind("main"))
for Sink in ["errors", "topical"]
	Test("Logger: shutdown retains independent " . Sink . " sink debt (AHK-090)",
		_LSS_Shutdown.Bind(Sink))

; The new privacy fixture owns an explicit topical key, unlike the older fixture.
_LSS_ReceiptQueue(Sink, Name) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	return Sink == "main" ? _LOGGER_PENDING
		: Sink == "errors" ? _LOGGER_PENDING_ERRORS : _LOGGER_SUB_PENDING[Name]
}

; Refusal evidence observes the real shutdown owner without owning its queues.
_LSS_RefusalReceipt(Sink) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_SUB_PATHS, _LOGGER_PATH_DATE
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES
	global _LOGGER_APPEND_OWNERS, _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS
	Saved := {
		Queues: [_LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING],
		Paths: [LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_SUB_PATHS, _LOGGER_PATH_DATE],
		Flags: [_LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES],
		Owners: [_LOGGER_APPEND_OWNERS, _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS]
	}
	Path := _FSWL_Path()
	Seed := "existing-refusal-receipt`r`n"
	PrivateMarker := "private-receipt-marker-never-emitted"
	Owned := false
	Lock := 0
	try {
		Owned := FSWriteCreateDurable(Path, Seed)
		AssertTrue(Owned)
		Lock := FileOpen(Path, "r-w", "UTF-8")
		AssertTrue(IsObject(Lock))
		_LOGGER_PENDING := Sink == "main" ? [PrivateMarker] : []
		_LOGGER_PENDING_ERRORS := Sink == "errors" ? [PrivateMarker] : []
		_LOGGER_SUB_PENDING := Sink == "topical" ? Map(PrivateMarker, [PrivateMarker]) : Map()
		LOGGER_LOG_PATH := Sink == "main" ? Path : ""
		LOGGER_ERRORS_LOG_PATH := Sink == "errors" ? Path : ""
		_LOGGER_SUB_PATHS := Sink == "topical" ? Map(PrivateMarker, Path) : Map()
		_LOGGER_PATH_DATE := ""
		_LOGGER_DROPPED_LINES := 0
		_LOGGER_FORCE_FLUSH_PENDING := false
		_LOGGER_APPEND_OWNERS := Map()
		_LOGGER_APPEND_DEBTS := Map()
		_LOGGER_APPEND_DEBT_REPAIRS := Map()
		_LOGGER_FLUSH_ACTIVE := true
		Queue := _LSS_ReceiptQueue(Sink, PrivateMarker)
		Ready := LoggerPrepareShutdown(&Active)
		AssertFalse(Ready)
		AssertEqual("repair", Active["phase"])
		AssertEqual(1, Active["flush_active"])
		AssertEqual(1, Active["force_flush_pending"])
		AssertTrue(_LOGGER_FLUSH_ACTIVE, "sampling must not release the active owner")
		AssertTrue(_LSS_ReceiptQueue(Sink, PrivateMarker) == Queue, "sampling must retain the actual queue identity")
		AssertEqual(0, Active["append_owners"])
		AssertEqual(0, Active["append_debts"])
		AssertEqual(0, Active["append_repairs"])

		_LOGGER_FLUSH_ACTIVE := false
		_LOGGER_APPEND_OWNERS[PrivateMarker] := true
		Ready := LoggerPrepareShutdown(&Appending)
		AssertFalse(Ready)
		AssertEqual(1, Appending["append_owners"])
		AssertEqual(1, _LOGGER_APPEND_OWNERS.Count, "the observation cannot retire an append")
		_LOGGER_APPEND_OWNERS := Map()
		_LOGGER_APPEND_DEBT_REPAIRS[PrivateMarker] := true
		Ready := LoggerPrepareShutdown(&Repairing)
		AssertFalse(Ready)
		AssertEqual(1, Repairing["append_repairs"])
		AssertEqual(1, _LOGGER_APPEND_DEBT_REPAIRS.Count)
		_LOGGER_APPEND_DEBT_REPAIRS := Map()
		_LOGGER_FORCE_FLUSH_PENDING := false
		Ready := LoggerPrepareShutdown(&Denied)
		AssertFalse(Ready, "native sharing denial must remain a durability refusal")
		AssertEqual("pending_debt", Denied["phase"])
		AssertEqual(0, Denied["flush_active"])
		AssertEqual(0, Denied["force_flush_pending"])
		AssertEqual(Sink == "main" ? 1 : 0, Denied["main_lines"])
		AssertEqual(Sink == "errors" ? 1 : 0, Denied["error_lines"])
		AssertEqual(Sink == "topical" ? 1 : 0, Denied["topical_queues"])
		AssertEqual(Sink == "topical" ? 1 : 0, Denied["topical_lines"])
		AssertEqual(Seed, FileRead(Path, "UTF-8"))
		AssertEqual(1, _LSS_ReceiptQueue(Sink, PrivateMarker).Length)
		AssertEqual(PrivateMarker, _LSS_ReceiptQueue(Sink, PrivateMarker)[1])
		AssertEqual(10, Denied.Count, "only the closed primitive schema may leave the logger")
		ExpectedKeys := Map("phase", true, "flush_active", true, "force_flush_pending", true,
			"append_owners", true, "append_debts", true, "append_repairs", true,
			"main_lines", true, "error_lines", true, "topical_queues", true, "topical_lines", true)
		for Key, Value in Denied {
			AssertTrue(ExpectedKeys.Has(Key))
			AssertFalse(InStr(Key, PrivateMarker))
			if Key == "phase"
				AssertEqual("pending_debt", Value)
			else {
				AssertTrue(Value is Integer)
				AssertTrue(Value >= 0)
			}
		}
		_LSS_ReceiptQueue(Sink, PrivateMarker).Push(PrivateMarker)
		AssertEqual(1, Denied[Sink == "main" ? "main_lines"
			: Sink == "errors" ? "error_lines" : "topical_lines"], "receipt must be detached")
		_LSS_ReceiptQueue(Sink, PrivateMarker).Pop()
		Denied["main_lines"] := 999
		AssertEqual(1, _LSS_ReceiptQueue(Sink, PrivateMarker).Length, "caller changes cannot mutate a logger queue")
		Lock.Close()
		Lock := 0
		Ready := LoggerPrepareShutdown(&Released)
		AssertTrue(Ready, "the actual native sink must become durable after releasing its lock")
		AssertEqual(0, Released, "success cannot retain a stale refusal packet")
		AssertEqual(Seed . PrivateMarker . "`r`n", FileRead(Path, "UTF-8"))
	} finally {
		try {
			if IsObject(Lock)
				Lock.Close()
			if Owned
				FileDelete(Path)
		} finally {
			_LOGGER_PENDING := Saved.Queues[1]
			_LOGGER_PENDING_ERRORS := Saved.Queues[2]
			_LOGGER_SUB_PENDING := Saved.Queues[3]
			LOGGER_LOG_PATH := Saved.Paths[1]
			LOGGER_ERRORS_LOG_PATH := Saved.Paths[2]
			_LOGGER_SUB_PATHS := Saved.Paths[3]
			_LOGGER_PATH_DATE := Saved.Paths[4]
			_LOGGER_FLUSH_ACTIVE := Saved.Flags[1]
			_LOGGER_FORCE_FLUSH_PENDING := Saved.Flags[2]
			_LOGGER_DROPPED_LINES := Saved.Flags[3]
			_LOGGER_APPEND_OWNERS := Saved.Owners[1]
			_LOGGER_APPEND_DEBTS := Saved.Owners[2]
			_LOGGER_APPEND_DEBT_REPAIRS := Saved.Owners[3]
		}
	}
}
for Sink in ["main", "errors", "topical"]
	Test("Logger: refusal evidence keeps " . Sink . " ownership and private data intact (AHK-090)",
		_LSS_RefusalReceipt.Bind(Sink))
