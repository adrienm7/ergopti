; tests/fixtures/idle_activity_publication_owner_body.ahk

; ==============================================================================
; MODULE: Idle Publication and Activity Child
; DESCRIPTION:
; Genuine NoteActivity and IdleTick own all session/idle state mutations. Their
; explicit monotonic Now arguments cross the configured threshold without any
; claim of thirty seconds physically elapsing. The real timestamp body runs
; before one native timer cutpoint; no append, commit or state flag is faked.
; ==============================================================================

#Requires AutoHotkey v2.0

_KIO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Source, Message, Values*) {
	global _KIO
	_KIO.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("error " . Source . " " . Text . "`n", _KIO.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	LoggerError(Source, Message, Values*)
}

; The unchanged actual clock body is retained under its private alias. The
; scheduling port does not claim the default wall-clock implementation pumps.
KL_NowTimestamp() {
	global _KIO
	Stamp := _KIO_NativeTimestamp()
	_KIO.TimeCalls += 1
	if !_KIO.Armed
		return Stamp
	_KIO.Armed := false
	try {
		_KIO_Require(!A_IsCritical && !A_IsSuspended && KLWatch.is_session_active
			&& !KLWatch.is_idle && !KLWatch.session_close_draining
			&& !IsObject(KLWatch.session_close) && !IsObject(KLWatch.idle_close)
			&& !KL_Hook_HasPendingInput(),
			"The old idle publication must be interruptible without a close or pending input owner.")
		_KIO_Require(KLHook.last_tick == _KIO.Origin && KLWatch.last_authorized_tick == _KIO.Origin
			&& Keystats._pending_entries.Length == 1 && Keystats._pending_entries[1]["type"] == "session_start",
			"A real accepted session and the old activity watermark must precede idle preparation.")
		_KIO.BeforeTimer := true
		SetTimer(_KIO.Timer, -1)
		Started := A_TickCount
		while !_KIO.Done && TickElapsed64(Started) < 2000
			Sleep(10)
		_KIO_Require(_KIO.Done, "The real activity timer must settle before the old append resumes.")
	} catch Any as Failure {
		_KIO.Failure := Failure
	}
	return Stamp
}

_KIO_Interrupt() {
	global _KIO
	try {
		_KIO_Require(!A_IsCritical && _KIO.BeforeTimer && !A_IsSuspended,
			"The native timer must interrupt the admitted old publication.")
		_KIO_Require(!KLWatch.session_close_draining && !IsObject(KLWatch.session_close)
			&& !IsObject(KLWatch.idle_close) && !KL_Hook_HasPendingInput(),
			"No close lock or pending-classification refusal may explain the new activity.")
		_KIO.TimerCalls += 1
		_KIO.Delay := KL_Hook_NoteActivity(false, true, _KIO.NewTick)
		_KIO_Require(_KIO.Delay == _KIO.NewTick - _KIO.Origin
			&& KLWatch.last_authorized_tick == _KIO.NewTick && KLHook.last_tick == _KIO.NewTick
			&& KLWatch.is_session_active && !KLWatch.is_idle && !KL_Hook_HasPendingInput()
			&& !KLWatch.session_close_draining && !IsObject(KLWatch.session_close),
			"The genuine producer must accept and publish newer activity before the old frame resumes.")
		_KIO.RowsAtActivity := Keystats._pending_entries.Length
		_KIO.NativeTickAtActivity := A_TickCount
	} catch Any as Failure {
		_KIO.Failure := Failure
	} finally {
		_KIO.Done := true
	}
}

_KIO_Observe(Stage) {
	global _KIO
	FileAppend("RECEIPT idle-activity-owner stage=" . Stage . " mode=" . _KIO.Mode
		. " rows=" . Keystats._pending_entries.Length . " idle=" . KLWatch.is_idle
		. " session=" . KLWatch.is_session_active . " origin=" . _KIO.Origin
		. " observation=" . _KIO.Observation . " new_tick=" . _KIO.NewTick
		. " last_tick=" . KLHook.last_tick . " authorized=" . KLWatch.last_authorized_tick
		. " timer_calls=" . _KIO.TimerCalls . " clock_calls=" . _KIO.TimeCalls
		. " native_tick=" . A_TickCount . " close=" . KLWatch.session_close_draining
		. " pending_input=" . KL_Hook_HasPendingInput() . "`n", "*", "UTF-8")
}

_KIO_Balanced() {
	Starts := 0, Ends := 0
	for Row in Keystats._pending_entries {
		if Row["type"] == "idle_start"
			Starts += 1
		else if Row["type"] == "idle_end" {
			Ends += 1
			_KIO_Require(Starts == Ends && Row["duration_ms"] >= 0,
				"Every historical idle close must have one earlier start and a valid duration.")
		} else
			_KIO_Require(Row["type"] == "session_start", "No unrelated event can explain this bounded interval.")
	}
	_KIO_Require(Starts == Ends, "Newly accepted activity cannot leave a dangling historical idle interval.")
	return Starts
}

_KIO_Exercise() {
	global _KIO
	Keystats.initialized := true
	Keystats.session_app := "private-idle-fixture.exe"
	MetricsFilters.secure_field := false
	MetricsFocusCache.state := {valid: true, process_name: "private-idle-fixture.exe", title: "private fixture", class: "Fixture"}
	_KIO.Origin := A_TickCount
	_KIO.NewTick := _KIO.Origin + KLWatchConst.MICRO_IDLE_TIMEOUT_MS + 2
	_KIO.Observation := _KIO.Origin + KLWatchConst.MICRO_IDLE_TIMEOUT_MS + 1
	_KIO_Require(_KIO.Origin > 0 && _KIO.NewTick - _KIO.Origin < KLWatchConst.SESSION_TIMEOUT_MS,
		"Explicit Now bounds isolate a micro-idle from a session timeout; no physical wait is inferred.")
	_KIO_Require(!IsObject(KLWatch.system_events) && !KL_Hook_HasPendingInput(),
		"The fixture cannot overlap another system drain or physical classification owner.")
	_KIO_Require(KL_Hook_NoteActivity(false, true, _KIO.Origin) == 0,
		"The real first activity must publish the initial session.")
	_KIO_Require(KLWatch.is_session_active && !KLWatch.is_idle
		&& KLWatch.last_authorized_tick == _KIO.Origin && KLHook.last_tick == _KIO.Origin
		&& Keystats._pending_entries.Length == 1 && Keystats._pending_entries[1]["type"] == "session_start",
		"Initial state must come from the genuine append and commit, not assigned session flags.")
	SessionGeneration := KLWatch.session_generation
	if _KIO.Mode == "recent" {
		KL_Hook_NoteActivity(false, true, _KIO.NewTick)
		_KIO.Observation := _KIO.NewTick + KLWatchConst.MICRO_IDLE_TIMEOUT_MS - 1
	}
	_KIO.Armed := _KIO.Mode == "reentrant"
	KL_Watchers_IdleTick(_KIO.Observation)
	if IsObject(_KIO.Failure)
		throw _KIO.Failure
	_KIO_Require(_KIO.Errors == 0 && !KLWatch.session_close_draining
		&& !IsObject(KLWatch.session_close) && !IsObject(KLWatch.idle_close) && !KL_Hook_HasPendingInput(),
		"Diagnostic fallback, close debt or pending input cannot qualify a business result.")
	if _KIO.Mode == "reentrant"
		_KIO_Require(_KIO.BeforeTimer && _KIO.Done && _KIO.TimerCalls == 1
			&& _KIO.RowsAtActivity == 1 && KLHook.last_tick == _KIO.NewTick
			&& KLWatch.last_authorized_tick == _KIO.NewTick,
			"The native timer must really accept newer activity before the old publication resumes.")
	_KIO_Observe("old-return")
	if _KIO.Mode == "current" {
		_KIO_Require(KLWatch.is_idle && KLWatch.idle_started_at == _KIO.Origin
			&& Keystats._pending_entries.Length == 2 && Keystats._pending_entries[2]["type"] == "idle_start",
			"Uninterrupted inactivity must publish its real idle start and current state.")
		KL_Hook_NoteActivity(false, true, _KIO.NewTick)
	} else {
		_KIO_Require(!KLWatch.is_idle,
			"An old idle publication cannot leave the session idle after newer activity was accepted.")
		if _KIO.Mode == "recent"
			_KIO_Require(Keystats._pending_entries.Length == 1, "A sub-threshold recent gap must not invent an idle event.")
	}
	_KIO_Require(KLHook.last_tick == _KIO.NewTick && KLWatch.last_authorized_tick == _KIO.NewTick
		&& KLWatch.is_session_active && KLWatch.session_generation == SessionGeneration,
		"A stale timer cannot erase the accepted watermark or replace the active session.")
	; An implementation may retain a correctly closed historical interval rather
	; than discard it. Only dangling/current state is forbidden after activity.
	History := _KIO_Balanced()
	Rows := Keystats._pending_entries.Length
	NextObservation := _KIO.NewTick + KLWatchConst.MICRO_IDLE_TIMEOUT_MS + 1
	KL_Watchers_IdleTick(NextObservation)
	_KIO_Require(KLWatch.is_idle && KLWatch.idle_started_at == _KIO.NewTick
		&& Keystats._pending_entries.Length == Rows + 1
		&& Keystats._pending_entries[Rows + 1]["type"] == "idle_start",
		"Fresh inactivity must begin at the newer accepted watermark exactly once.")
	KL_Hook_NoteActivity(false, true, NextObservation + 1)
	_KIO_Require(!KLWatch.is_idle && Keystats._pending_entries.Length == Rows + 2
		&& Keystats._pending_entries[Rows + 2]["type"] == "idle_end"
		&& Keystats._pending_entries[Rows + 2]["duration_ms"] == KLWatchConst.MICRO_IDLE_TIMEOUT_MS + 2
		&& _KIO_Balanced() == History + 1,
		"The subsequent genuine activity must close only the fresh interval with its true explicit duration.")
	KL_Hook_NoteActivity(false, true, NextObservation + 2)
	_KIO_Require(Keystats._pending_entries.Length == Rows + 2 && !KLWatch.is_idle
		&& !KL_Hook_HasPendingInput() && !IsObject(KLWatch.idle_close) && !IsObject(KLWatch.session_close),
		"Repeated current activity cannot duplicate a close or retain an interval owner.")
	_KIO_Require(_KIO.Errors == 0, "No swallowed producer error can qualify the late assertions.")
	_KIO_Observe("complete")
}

_KIO_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _KIO := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Timer: _KIO_Interrupt,
		Armed: false, TimeCalls: 0, TimerCalls: 0, BeforeTimer: false, Done: false,
		RowsAtActivity: -1, NativeTickAtActivity: -1, Errors: 0, Failure: 0}
	Primary := 0
	try _KIO_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		SetTimer(_KIO.Timer, 0)
		_KIO.Timer := 0
		Keystats.initialized := false
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_KIO.Log) {
			for Line in StrSplit(FileRead(_KIO.Log, "UTF-8"), "`n", "`r")
				if Line != ""
					FileAppend("DIAG " . Line . "`n", "*", "UTF-8")
		}
		ExitApp(1)
	}
	FileAppend("PASS idle-activity-owner " . _KIO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_KIO_Main()
