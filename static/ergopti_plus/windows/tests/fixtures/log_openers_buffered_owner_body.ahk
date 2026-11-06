; tests/fixtures/log_openers_buffered_owner_body.ahk

; ==============================================================================
; MODULE: Buffered Log Reader Child
; DESCRIPTION:
; A genuine initialized logger owns private native files. Launch and notification
; are observation ports; sharing denial uses a real native read handle.
; ==============================================================================

#Requires AutoHotkey v2.0

_EDOS_Phase(*) {
}
_EDOS_BootError(Failure, *) {
	FileAppend("FAIL child boundary: " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}
_LOB_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_LOB_Launch(Command) {
	global _LOB
	_LOB.Launches += 1
	_LOB_Require(Command == 'notepad.exe "' . _LOB.Path . '"', "The actual action must launch the exact dated log resolver path.")
	Text := FileRead(_LOB.Path, "UTF-8")
	_LOB_Require(InStr(Text, _LOB.Message) > 0, "The real warning must already be on disk at the launch boundary.")
	_LOB_Require(InStr(Text, _LOB.Message, , InStr(Text, _LOB.Message) + StrLen(_LOB.Message)) == 0,
		"Retry must deliver the retained warning exactly once.")
}
_LOB_Notify(*) {
	global _LOB
	_LOB.Notices += 1
	return true
}
_LOB_Open() {
	global _LOB
	if InStr(_LOB.Mode, "daylog") == 1 {
		; The real diagnostic attachment reader shares this native logger.
		Read := _DayLog_ReadToday(HealthCheck_Config()["day_log"]["max_bytes"])
		HasWarning := Read["found"] && InStr(Read["text"], _LOB.Message) > 0
		FileAppend("RECEIPT day-log-buffered mode=" . _LOB.Mode . " found=" . Read["found"]
			. " has_buffered_warning=" . HasWarning . "`n", "*", "UTF-8-RAW")
		if !Read["found"] {
			_LOB_Require(Read.Get("reason", "") == "failed", "An unsettled diagnostic reader must report delivery failure, not missing log.")
			return false
		}
		_LOB_Require(HasWarning, "The actual diagnostic log reader must not accept stale native contents before its queued warning is durable.")
		_LOB_Require(InStr(Read["text"], _LOB.Message, , InStr(Read["text"], _LOB.Message) + StrLen(_LOB.Message)) == 0,
			"A retried diagnostic attachment must contain the real warning exactly once.")
		_LOB.Launches += 1
		return true
	}
	return _LOB.Errors ? LogOpeners_OpenTodayErrors(_LOB_Launch, _LOB_Notify) : LogOpeners_OpenTodayLog(_LOB_Launch)
}
_LOB_Exercise() {
	global _LOB, _LOGGER_PENDING_ERRORS, _LOGGER_PENDING, _LOGGER_FLUSH_ACTIVE
	global _LOGGER_FLUSH_TIMER_STARTED
	_LOB_Require(LoggerFlushForRead(), "The actual initialized logger must first settle its startup output.")
	SetTimer(_LoggerFlush, 0)
	_LOB_Require(_LOGGER_FLUSH_TIMER_STARTED, "The genuine initializer must have armed the production flush timer before this test disarms it.")
	_LOB.Path := _LOB.Errors ? LoggerTodayErrorsPath() : LoggerTodayLogPath()
	if _LOB.Errors && FileExist(_LOB.Path)
		FileDelete(_LOB.Path)
	Lock := 0
	try {
		if InStr(_LOB.Mode, "-denied") {
			if !FileExist(_LOB.Path)
				_LOB_Require(FSWriteCreateDurable(_LOB.Path, "private sharing-denial seed`r`n"), "Create the private native locked sink exclusively.")
			Lock := FileOpen(_LOB.Path, "r-w", "UTF-8")
			_LOB_Require(IsObject(Lock), "A genuine native reader must deny concurrent writes.")
		}
		LoggerWarn("LogReadOwner", _LOB.Message)
		_LOB_Require(_LOGGER_PENDING_ERRORS.Length == 1 && _LOGGER_PENDING.Length == 1,
			"The genuine warning must be buffered in both queues with its ordinary periodic flush disarmed.")
		if FileExist(_LOB.Path)
			_LOB_Require(!InStr(FileRead(_LOB.Path, "UTF-8"), _LOB.Message), "The warning must not already be on disk before the action.")
		if InStr(_LOB.Mode, "-busy") {
			; This explicitly controls the ownership observation, not native I/O.
			_LOGGER_FLUSH_ACTIVE := true
			try _LOB_Require(!_LOB_Open(), "An interrupted flush owner must refuse a synchronous read without waiting.")
			finally _LOGGER_FLUSH_ACTIVE := false
			_LOB_Require(_LOB.Launches == 0 && _LOB.Notices == 0
				&& _LOGGER_PENDING_ERRORS.Length == 1 && _LOGGER_PENDING.Length == 1,
				"An unsettled owner must retain both queues without opening or announcing no errors.")
		} else if IsObject(Lock) {
			_LOB_Require(!_LOB_Open(), "A refused native append must refuse the action even though the flush completed.")
			_LOB_Require(_LOB.Launches == 0 && _LOB.Notices == 0,
				"A write refusal must not open stale contents or announce that nothing warned.")
			_LOB_Require((_LOB.Errors ? _LOGGER_PENDING_ERRORS.Length : _LOGGER_PENDING.Length) == 1,
				"The exact refused sink must retain its genuine warning for a retry.")
			Lock.Close(), Lock := 0
		}
		_LOB_Require(_LOB_Open(), "The ordinary action must settle the real native sink after any refusal ends.")
		_LOB_Require(_LOB.Launches == 1 && _LOB.Notices == 0
			&& _LOGGER_PENDING_ERRORS.Length == 0 && _LOGGER_PENDING.Length == 0,
			"Exactly one launch must observe the warning already written; no no-errors notice is permitted.")
		FileAppend("RECEIPT log-openers-buffered mode=" . _LOB.Mode . " launches=" . _LOB.Launches
			. " notices=" . _LOB.Notices . "`n", "*", "UTF-8-RAW")
	} finally {
		if IsObject(Lock)
			Lock.Close()
	}
}
_LOB_Main() {
	global _LOB, _EDOS_Root, _DriverBootPhase, _DriverStartupSmokeDir, Features
	if A_Args.Length != 2 || A_Args[2] != _EDOS_Root
		ExitApp(2)
	_LOB := {Mode: A_Args[1], Errors: InStr(A_Args[1], "errors") == 1, Path: "",
		Message: "owned buffered warning must precede the user read", Launches: 0, Notices: 0}
	Primary := 0
	try {
		_DriverBootPhase := "ready", _DriverStartupSmokeDir := ""
		Features := ManifestBuildFeaturesMap()
		LoggerInit()
		_LOB_Exercise()
	} catch Any as Failure
		Primary := Failure
	finally {
		try {
			_LOB_Require(LoggerPrepareShutdown(), "The actual private logger must retain no delivery debt at child exit.")
			SetTimer(_LoggerFlush, 0)
			OnExit(_LoggerOnExitFlush, 0)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_EDOS_BootError, 0)
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS log-openers-buffered " . _LOB.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_LOB_Main()
