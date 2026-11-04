; tests/fixtures/keystats_system_committed_retirement_body.ahk

; ==============================================================================
; MODULE: Accepted System Event Retirement Child
; DESCRIPTION:
; A transparent append observer delegates the entire genuine bridge unchanged.
; Only after real canonical publication and Commit does a native timer pause
; the owner, before the original drain receives the successful return value.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSDC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Source, Message, Values*) {
	global _KSDC
	_KSDC.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("error " . Source . " " . Text . "`n", _KSDC.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	LoggerError(Source, Message, Values*)
}

; The shared composer renames only this genuine classifier declaration.
MF_ShouldFilter() {
	return _KSDO_NativeFilter()
}

_KSDC_Capture() {
	global _KSDC
	Frame := _KL_SystemEventClock()
	_KSDC.Frames.Push(Frame.Clone())
	return Frame
}

_KSDC_Append(Entry, Guard, Commit) {
	global _KSDC
	_KSDC.RealCalls += 1
	Accepted := _KSDC.NativeAppend.Call(Entry, Guard, Commit)
	if !_KSDC.Armed
		return Accepted
	_KSDC.Armed := false
	try {
		_KSDC_Require(!A_IsCritical && _KSDC.Owner.Draining && (Accepted is Integer) && Accepted == 1,
			"The genuine bridge must already have returned accepted before native interruption.")
		_KSDC_Require(Keystats._pending_entries.Length == 2 && Keystats.health_events_session == 2
			&& _KSDC.Owner.Pending.Length == 2 && _KSDC.Owner.Pending[1]["committed"],
			"The actual append and commit must precede any lifecycle revocation.")
		_KSDC.Head := _KSDC.Owner.Pending[1]
		_KSDC.Suffix := _KSDC.Owner.Pending[2]
		_KSDC_Require(Entry == _KSDC.Head["entry"] && Keystats._pending_entries[2] == Entry
			&& !_KSDC.Suffix["committed"], "The accepted head and untouched suffix must be the original real objects.")
		_KSDC.OldGeneration := _KSDC.Owner.Intervals.Generation
		_KSDC.OldGuard := Guard
		_KSDC_Require(Guard.Call(), "The accepted owner must still be current before the controlled native pause.")
		_KSDC.Accepted := Accepted
		_KSDC.BeforeTimer := true
		SetTimer(_KSDC.Timer, -1)
		Started := A_TickCount
		while !_KSDC.Done && ((A_TickCount - Started) & 0xFFFFFFFF) < 2000
			Sleep(10)
		_KSDC_Require(_KSDC.Done, "Native revocation must settle before the bridge result reaches Drain.")
	} catch Any as Failure {
		if !IsObject(_KSDC.Failure)
			_KSDC.Failure := Failure
	}
	; Never replace or reinterpret the real port's return value.
	return Accepted
}

_KSDC_Interrupt() {
	global _KSDC
	try {
		_KSDC_Require(!A_IsCritical && _KSDC.BeforeTimer && _KSDC.Owner.Draining,
			"The native timer must run before the active drain resumes.")
		_KSDC_Require(Keystats._pending_entries.Length == 2 && _KSDC.Head["committed"],
			"A queued, committed canonical row must exist before pause.")
		_KSDC.TimerCalls += 1
		Suspend(1)
		_KSDC_Require(KL_Watchers_ResetSystemIntervals(), "The genuine collection boundary must run.")
		_KSDC_Require(_KSDC.Owner.Intervals.Generation > _KSDC.OldGeneration && !_KSDC.OldGuard.Call(),
			"Pause must actually revoke the old guard after its commit.")
		_KSDC_Require(_KSDC.Owner.Pending.Length == 2 && _KSDC.Owner.Pending[1] == _KSDC.Head
			&& _KSDC.Owner.Pending[2] == _KSDC.Suffix && _KSDC.Head["committed"],
			"The lifecycle boundary cannot replace either pending object or undo its acceptance.")
	} catch Any as Failure {
		if !IsObject(_KSDC.Failure)
			_KSDC.Failure := Failure
	} finally {
		_KSDC.Done := true
	}
}

_KSDC_Observe(Stage) {
	global _KSDC
	FileAppend("RECEIPT system-committed-owner stage=" . Stage
		. " rows=" . Keystats._pending_entries.Length . " pending=" . _KSDC.Owner.Pending.Length
		. " committed=" . _KSDC.Head["committed"] . " accepted=" . _KSDC.Accepted
		. " timer_calls=" . _KSDC.TimerCalls . " paused=" . A_IsSuspended
		. " old_generation=" . _KSDC.OldGeneration . " generation=" . _KSDC.Owner.Intervals.Generation
		. " real_calls=" . _KSDC.RealCalls . "`n", "*", "UTF-8")
}

_KSDC_CheckCycle(StartIndex, StartFrame) {
	global _KSDC
	Rows := Keystats._pending_entries
	FirstFrame := _KSDC.Frames[StartFrame]
	LastFrame := _KSDC.Frames[StartFrame + 1]
	_KSDC_Require(Rows[StartIndex]["action"] == "sleep" && Rows[StartIndex + 1]["action"] == "wake"
		&& Rows[StartIndex + 2]["action"] == "passive_period", "Raw observations and the completed interval must keep their original order.")
	_KSDC_Require(Rows[StartIndex + 2]["duration_ms"] == LastFrame["tick"] - FirstFrame["tick"]
		&& Rows[StartIndex + 2]["timestamp"] == LastFrame["timestamp"],
		"Retirement and retry cannot recapture the original native timing inputs.")
}

_KSDC_Exercise() {
	global _KSDC
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	MetricsFocusCache.state := {valid: true, process_name: "private-fixture.exe", title: "private fixture", class: "Fixture"}
	_KSDC_Require(_KL_Watchers_SystemStart(), "The genuine factory must admit its system owner.")
	_KSDC.Owner := KLWatch.system_events
	_KSDC.NativeAppend := _KSDC.Owner.AppendFn
	_KSDC_Require(_KSDC.NativeAppend == _KL_SystemEventAppend, "The observer must delegate the actual factory-installed bridge.")
	_KSDC.Owner.ClockFn := _KSDC_Capture
	_KSDC.Owner.AppendFn := _KSDC_Append
	_KSDC_Require(_KSDC.Owner.Observe("sleep") && Keystats._pending_entries.Length == 1,
		"The real first observation must already be accepted.")
	Sleep(20)
	_KSDC.Armed := true
	Result := _KSDC.Owner.Observe("wake")
	if IsObject(_KSDC.Failure)
		throw _KSDC.Failure
	_KSDC_Require(_KSDC.Done && _KSDC.BeforeTimer && _KSDC.TimerCalls == 1 && A_IsSuspended
		&& _KSDC.Head["committed"] && _KSDC.Accepted == 1 && !_KSDC.OldGuard.Call()
		&& _KSDC.Errors == 0 && _KSDC.Frames.Length == 2,
		"The exact accepted-then-revoked native prerequisite must precede every business oracle.")
	_KSDC_Observe("old-return")
	_KSDC_Require(!Result && Keystats._pending_entries.Length == 2 && Keystats.health_events_session == 2,
		"The accepted row must survive once while the uncommitted suffix remains paused.")
	_KSDC_Require(_KSDC.Owner.Pending.Length == 1 && _KSDC.Owner.Pending[1] == _KSDC.Suffix
		&& !_KSDC.Suffix["committed"] && Keystats._pending_entries[2] == _KSDC.Head["entry"],
		"The committed old head must retire exactly once without removing its untouched successor.")
	_KSDC_Require(!_KSDC.Owner.Drain() && _KSDC.Owner.Pending.Length == 1
		&& _KSDC.Owner.Pending[1] == _KSDC.Suffix && Keystats._pending_entries.Length == 2,
		"A repeated paused drain must preserve only the original uncommitted debt.")
	Suspend(0)
	_KSDC_Require(_KSDC.Owner.Drain() && _KSDC.Owner.Pending.Length == 0
		&& Keystats._pending_entries.Length == 3 && Keystats.health_events_session == 3,
		"Resume must append only the suffix, never replay the already committed head.")
	_KSDC_CheckCycle(1, 1)
	_KSDC_Require(_KSDC.Owner.Observe("sleep"), "A successor observation must remain admissible.")
	Sleep(20)
	_KSDC_Require(_KSDC.Owner.Observe("wake") && _KSDC.Owner.Pending.Length == 0
		&& Keystats._pending_entries.Length == 6 && Keystats.health_events_session == 6,
		"A fresh current cycle must publish exactly once after old-head retirement.")
	_KSDC_CheckCycle(4, 3)
	_KSDC_Require(_KSDC.Owner.Drain() && Keystats._pending_entries.Length == 6,
		"An empty repeated drain cannot duplicate accepted work.")
	_KSDC_Observe("complete")
}

_KSDC_Main() {
	if A_Args.Length != 2 || A_Args[1] != "committed-paused"
		ExitApp(2)
	Persistent(true)
	global _KSDC := {Log: A_Args[2] . "\private.log", Timer: _KSDC_Interrupt, Owner: 0,
		NativeAppend: 0, RealCalls: 0, Frames: [], Armed: false, BeforeTimer: false,
		TimerCalls: 0, Done: false, OldGeneration: -1, OldGuard: 0, Accepted: -1, Errors: 0, Failure: 0}
	Primary := 0
	try _KSDC_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		SetTimer(_KSDC.Timer, 0)
		Suspend(0)
		if IsObject(_KSDC.Owner) {
			_KSDC.Owner.AppendFn := _KSDC.NativeAppend
			_KSDC.Owner.Reset()
			if KLWatch.system_events == _KSDC.Owner
				KLWatch.system_events := false
		}
		_KSDC.OldGuard := 0
		_KSDC.Owner := 0
		_KSDC.NativeAppend := 0
		_KSDC.Timer := 0
		Keystats.initialized := false
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_KSDC.Log) {
			for Line in StrSplit(FileRead(_KSDC.Log, "UTF-8"), "`n", "`r")
				if Line != ""
					FileAppend("DIAG " . Line . "`n", "*", "UTF-8")
		}
		ExitApp(1)
	}
	FileAppend("PASS system-committed-owner committed-paused`n", "*", "UTF-8")
	ExitApp(0)
}

_KSDC_Main()
