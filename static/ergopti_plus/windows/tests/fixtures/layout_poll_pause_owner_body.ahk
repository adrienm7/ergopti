; tests/fixtures/layout_poll_pause_owner_body.ahk

; Actual native timers drive the poll and Suspend. The declared reload port
; records a request and refuses dispatch: no successor or restart is created.
; HKL values are abstract port inputs and never reach a native layout API.
#Requires AutoHotkey v2.0

global _LAST_KEYBOARD_HKL := 0
global _PENDING_KEYBOARD_HKL := 0

_LPPO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_LPPO_Error(Failure, Mode) {
	global _LPPO
	if !IsObject(_LPPO.AsyncFailure)
		_LPPO.AsyncFailure := Failure
	return true
}

_LPPO_Pulse(*) {
	global _LPPO
	_LPPO.Pulses += 1
}

_LPPO_Pause(*) {
	global _LPPO
	Suspend(true)
	_LPPO.PauseCalls += 1
}

_LPPO_Request(RefusedFn) {
	global _LPPO
	_LPPO.Requests.Push({Paused: A_IsSuspended, Phase: _LPPO.Phase})
	; Exercise the real synchronous refusal path, never synthesize launch success.
	return false
}

_LPPO_Port() {
	return Map("needs_reload", (Hkl) => true, "reload", _LPPO_Request, "pending", () => false,
		"veto_honored", () => true, "now", () => A_TickCount, "notify", () => 0)
}

_LPPO_Observe() {
	global _LPPO
	Before := _LPPO.Pulses, Started := A_TickCount
	while _LPPO.Pulses - Before < 3 && TickElapsed(Started) < 1000
		Sleep(10)
	_LPPO_Require(_LPPO.Pulses - Before >= 3, "Every observation must deliver fresh independent native timer pulses.")
	if IsObject(_LPPO.AsyncFailure)
		throw _LPPO.AsyncFailure
}

_LPPO_Log(Line) {
	global _LPPO
	if !_LPPO.PauseAtLog || !InStr(Line, "[INFO] [ErgoptiPlus] Keyboard layout changed to HKL ")
		return
	_LPPO.PauseAtLog := false
	try {
		_LPPO_Require(IsObject(_LPPO.Current) && _LPPO.Current.Calls == 1 && !_LPPO.Current.Done,
			"The actual poll timer must reach the real logger before its request handoff.")
		_LPPO.LogCalls += 1
		SetTimer(_LPPO_Pause, -1)
		Started := A_TickCount
		while _LPPO.PauseCalls == 0 && TickElapsed(Started) < 1000
			Sleep(10)
		_LPPO_Require(_LPPO.PauseCalls == 1 && A_IsSuspended,
			"An independent native timer must actually suspend before the old logger frame continues.")
		_LPPO.PauseObserved := true
	} catch Any as Failure {
		if !IsObject(_LPPO.BoundaryFailure)
			_LPPO.BoundaryFailure := Failure
	}
}

_LPPO_Tick(Record) {
	global _LPPO
	Record.Calls += 1
	_LPPO.Current := Record
	Record.EntryPaused := A_IsSuspended
	try {
		Record.Returned := LayoutPollTick(0x200, A_IsSuspended, false, 0, 0, 5000, false, _LPPO_Port())
	} catch Any as Failure {
		if !IsObject(_LPPO.AsyncFailure)
			_LPPO.AsyncFailure := Failure
	} finally {
		Record.ExitPaused := A_IsSuspended
		Record.Done := true
		_LPPO.Current := 0
	}
}

_LPPO_RunTick(Phase) {
	global _LPPO
	_LPPO.Phase := Phase
	Record := {Calls: 0, Done: false, EntryPaused: false, ExitPaused: false, Returned: false, Timer: 0}
	Record.Timer := _LPPO_Tick.Bind(Record)
	_LPPO.Records.Push(Record)
	SetTimer(Record.Timer, -1)
	Started := A_TickCount
	while !Record.Done && TickElapsed(Started) < 2000
		Sleep(10)
	if IsObject(_LPPO.BoundaryFailure)
		throw _LPPO.BoundaryFailure
	if IsObject(_LPPO.AsyncFailure)
		throw _LPPO.AsyncFailure
	_LPPO_Require(Record.Done && Record.Calls == 1,
		"The exact production poll invocation must settle once on its real native timer.")
	return Record
}

_LPPO_Receipt(Phase) {
	global _LPPO
	PausedRequests := 0
	for Request in _LPPO.Requests
		PausedRequests += Request.Paused ? 1 : 0
	FileAppend("RECEIPT layout-poll-pause-owner mode=" . _LPPO.Mode . " phase=" . Phase
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " requests=" . _LPPO.Requests.Length
		. " paused_requests=" . PausedRequests . " pause_calls=" . _LPPO.PauseCalls
		. " log_calls=" . _LPPO.LogCalls . " pause_observed=" . (_LPPO.PauseObserved ? 1 : 0)
		. " timer_records=" . _LPPO.Records.Length . " pulses=" . _LPPO.Pulses
		. " native_paused=" . (A_IsSuspended ? 1 : 0) . " dispatch_port=passive_refusal`n", "*", "UTF-8-RAW")
}

_LPPO_Run() {
	global _LPPO, _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL
	; The genuine unknown-baseline and first-sighting routes establish the
	; tracker. No private retry/attempt/pending record is fabricated.
	_LPPO_Require(!LayoutPollTick(0x100, false, false, 0, 0, 5000, false, _LPPO_Port())
		&& _LAST_KEYBOARD_HKL == 0x100 && _PENDING_KEYBOARD_HKL == 0,
		"The genuine first observation must adopt its unknown baseline without a reload.")
	_LPPO_Require(!LayoutPollTick(0x200, false, false, 0, 0, 5000, false, _LPPO_Port())
		&& _PENDING_KEYBOARD_HKL == 0x200 && _LPPO.Requests.Length == 0,
		"The genuine first changed observation must wait for confirmation.")
	if _LPPO.Mode == "late-pause"
		_LPPO.PauseAtLog := true
	else if _LPPO.Mode == "paused-entry" {
		SetTimer(_LPPO_Pause, -1)
		_LPPO_Observe()
		_LPPO_Require(_LPPO.PauseCalls == 1 && A_IsSuspended, "The entry control must already be natively suspended.")
	}
	Record := _LPPO_RunTick("initial")
	_LPPO_Receipt("after-initial")
	if _LPPO.Mode == "current" {
		_LPPO_Require(!Record.EntryPaused && !Record.ExitPaused && _LPPO.Requests.Length == 1
			&& !_LPPO.Requests[1].Paused, "The current quiet confirmed switch must request reload exactly once.")
		return
	}
	if _LPPO.Mode == "late-pause"
		_LPPO_Require(!Record.EntryPaused && Record.ExitPaused && _LPPO.LogCalls == 1 && _LPPO.PauseObserved,
			"The logger boundary must prove an actual pause after the old tick entered active.")
	else
		_LPPO_Require(Record.EntryPaused && Record.ExitPaused && _LPPO.LogCalls == 0,
			"The paused-entry control must refuse before the reload logger boundary.")
	_LPPO_Require(_LPPO.Requests.Length == 0,
		"A natively paused driver must not hand off an automatic layout reload request.")
	Suspend(false)
	_LPPO_Observe()
	_LPPO_Receipt("after-resume-without-new-tick")
	_LPPO_Require(_LPPO.Requests.Length == 0 && Record.Calls == 1 && _LPPO.Records.Length == 1,
		"Resuming alone must not replay the retired old automatic request.")
	; A new observation is different from replaying an old frame. Two fresh
	; ticks allow either legitimate retained or reset confirmation state.
	_LPPO_RunTick("fresh-first")
	_LPPO_RunTick("fresh-confirm")
	_LPPO_Receipt("after-fresh-observations")
	_LPPO_Require(_LPPO.Requests.Length == 1 && !_LPPO.Requests[1].Paused,
		"Fresh active observations after resume must still request their own reload once.")
}

_LPPO_Main() {
	global _LPPO
	_LPPO := {Mode: A_Args[1], Phase: "setup", Requests: [], Records: [], Pulses: 0, PauseCalls: 0,
		LogCalls: 0, PauseAtLog: false, PauseObserved: false, Current: 0, AsyncFailure: 0, BoundaryFailure: 0}
	_LPPO_Require(_LPPO.Mode == "current" || _LPPO.Mode == "late-pause" || _LPPO.Mode == "paused-entry",
		"The layout poll mode must be explicit.")
	Primary := 0, WasSuspended := A_IsSuspended, PreviousCritical := Critical("Off")
	Thread("Interrupt", 0)
	OnError(_LPPO_Error)
	LoggerSetTestSink(_LPPO_Log)
	try {
		Suspend(false)
		SetTimer(_LPPO_Pulse, 10)
		_LPPO_Run()
	} catch Any as Failure {
		Primary := Failure
	} finally {
		for Callback in [_LPPO_Pause, _LPPO_Pulse] {
			try SetTimer(Callback, 0)
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		for Record in _LPPO.Records {
			try SetTimer(Record.Timer, 0)
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
			Record.Timer := 0
		}
		LoggerClearTestSink()
		OnError(_LPPO_Error, 0)
		Suspend(WasSuspended)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_LPPO.AsyncFailure)
		Primary := _LPPO.AsyncFailure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS layout-poll-pause-owner " . _LPPO.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_LPPO_Main()
