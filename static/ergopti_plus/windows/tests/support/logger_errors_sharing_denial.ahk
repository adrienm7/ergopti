; tests/support/logger_errors_sharing_denial.ahk

; ==============================================================================
; MODULE: Logger Error Sink Sharing Denial Fixture
; DESCRIPTION:
; Establishes real native write refusal and verifies retained, exactly-once retry.
; Both callers share setup while retaining distinct independent-sink coverage.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include filesystem_write_lock.ahk

_LoggerErrorsSharingDenial(DenyMain := false) {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE
	global LOGGER_SUB_FILES, _LOGGER_SUB_PATHS, _LOGGER_SUB_PENDING, _LOGGER_TEST_SINK
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	global _LOGGER_ERROR_ENABLED, _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING
	global _LOGGER_DROPPED_LINES, _HealthCheckLastError, _HealthCheckErrCount
	Saved := {
		Ring: [LOGGER_RING_BUFFER, LOGGER_RING_CURSOR],
		Queues: [_LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING],
		Paths: [LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE],
		Fanout: [LOGGER_SUB_FILES, _LOGGER_SUB_PATHS, _LOGGER_TEST_SINK],
		Dedup: [_LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime],
		Flags: [_LOGGER_ERROR_ENABLED, _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_DROPPED_LINES],
		Health: [_HealthCheckLastError, _HealthCheckErrCount]
	}
	Path := _FSWL_Path()
	MainPath := _FSWL_Path()
	Seed := "existing-error-log`r`n"
	Message := "sharing-denied-error-must-survive"
	Owned := false
	MainOwned := false
	Lock := 0
	MainLock := 0
	try {
		Owned := FSWriteCreateDurable(Path, Seed)
		AssertTrue(Owned, "the errors fixture must exclusively create its file")
		Lock := FileOpen(Path, "r-w", "UTF-8")
		AssertTrue(IsObject(Lock), "a real read handle must deny concurrent writers")
		if DenyMain {
			MainOwned := FSWriteCreateDurable(MainPath, Seed)
			AssertTrue(MainOwned, "the main fixture must exclusively create its file")
			MainLock := FileOpen(MainPath, "r-w", "UTF-8")
			AssertTrue(IsObject(MainLock), "the main sink must also deny concurrent writers")
		}
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		LOGGER_LOG_PATH := DenyMain ? MainPath : ""
		LOGGER_ERRORS_LOG_PATH := Path
		; The supported empty date disables rollover and preserves the exact fixture path.
		_LOGGER_PATH_DATE := ""
		LOGGER_SUB_FILES := []
		_LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_LEVEL := ""
		_LOGGER_DEDUP_COUNT := 0
		_LastErrTime := 0
		_LOGGER_ERROR_ENABLED := true
		_LOGGER_FLUSH_ACTIVE := false
		_LOGGER_FORCE_FLUSH_PENDING := false
		_LOGGER_DROPPED_LINES := 0

		LoggerError("FSFail", Message)
		AssertEqual(1, LOGGER_RING_BUFFER.Length, "the failure must remain visible in the crash ring")
		Line := LOGGER_RING_BUFFER[1]
		AssertContains(Line, "[ERROR] [FSFail] " . Message)
		AssertTrue(_LoggerFlush(true), "another denied attempt must preserve delivery ownership")
		AssertEqual(Seed, FileRead(Path, "UTF-8"), "the locked sink must remain byte-for-byte unchanged")
		AssertEqual(StrPut(Seed, "UTF-8") - 1, FileGetSize(Path))
		AssertEqual(1, _LOGGER_PENDING_ERRORS.Length, "refused delivery must retain the exact error")
		AssertEqual(Line, _LOGGER_PENDING_ERRORS[1])
		AssertEqual(1, _LOGGER_PENDING.Length, "the independent main queue must retain its undelivered copy")
		AssertEqual(Line, _LOGGER_PENDING[1])

		if DenyMain {
			AssertEqual(Seed, FileRead(MainPath, "UTF-8"), "the locked main sink must remain unchanged")
			MainLock.Close()
			MainLock := 0
		}
		Lock.Close()
		Lock := 0
		AssertTrue(_LoggerFlush(true), "retry must run after the real sharing denial is released")
		AssertEqual(0, _LOGGER_PENDING_ERRORS.Length, "successful retry must retire errors queue ownership")
		Expected := Seed . Line . "`r`n"
		AssertEqual(Expected, FileRead(Path, "UTF-8"), "retry must deliver the exact line once")
		AssertEqual(StrPut(Expected, "UTF-8") - 1, FileGetSize(Path))
		AssertEqual(DenyMain ? 0 : 1, _LOGGER_PENDING.Length, "main ownership follows its own delivery receipt")
		if DenyMain {
			AssertEqual(Expected, FileRead(MainPath, "UTF-8"), "the main sink must recover independently")
			AssertEqual(StrPut(Expected, "UTF-8") - 1, FileGetSize(MainPath))
		}
		AssertTrue(_LoggerFlush(true))
		if DenyMain
			AssertEqual(Expected, FileRead(MainPath, "UTF-8"), "main retry must not duplicate delivery")
		return {Expected: Expected, Errors: FileRead(Path, "UTF-8"),
			Main: DenyMain ? FileRead(MainPath, "UTF-8") : ""}
	} finally {
		; Restore borrowed state even if native handle closure or removal fails.
		try {
			try {
				if IsObject(Lock)
					Lock.Close()
				if Owned
					FileDelete(Path)
			} finally {
				if IsObject(MainLock)
					MainLock.Close()
				if MainOwned
					FileDelete(MainPath)
			}
		} finally {
			LOGGER_RING_BUFFER := Saved.Ring[1]
			LOGGER_RING_CURSOR := Saved.Ring[2]
			_LOGGER_PENDING := Saved.Queues[1]
			_LOGGER_PENDING_ERRORS := Saved.Queues[2]
			_LOGGER_SUB_PENDING := Saved.Queues[3]
			LOGGER_LOG_PATH := Saved.Paths[1]
			LOGGER_ERRORS_LOG_PATH := Saved.Paths[2]
			_LOGGER_PATH_DATE := Saved.Paths[3]
			LOGGER_SUB_FILES := Saved.Fanout[1]
			_LOGGER_SUB_PATHS := Saved.Fanout[2]
			_LOGGER_TEST_SINK := Saved.Fanout[3]
			_LOGGER_DEDUP_KEY := Saved.Dedup[1]
			_LOGGER_DEDUP_LEVEL := Saved.Dedup[2]
			_LOGGER_DEDUP_COUNT := Saved.Dedup[3]
			_LastErrTime := Saved.Dedup[4]
			_LOGGER_ERROR_ENABLED := Saved.Flags[1]
			_LOGGER_FLUSH_ACTIVE := Saved.Flags[2]
			_LOGGER_FORCE_FLUSH_PENDING := Saved.Flags[3]
			_LOGGER_DROPPED_LINES := Saved.Flags[4]
			_HealthCheckLastError := Saved.Health[1]
			_HealthCheckErrCount := Saved.Health[2]
		}
	}
}
