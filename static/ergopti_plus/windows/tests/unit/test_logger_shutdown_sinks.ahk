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

