; tests/fixtures/keystats_system_delivery_owner_body.ahk

; ==============================================================================
; MODULE: System Event Publication Owner Child
; DESCRIPTION:
; The genuine native clock supplies timestamps and observed interval inputs.
; The privacy port delegates its unchanged real body, then controls one native
; timer cutpoint. It never changes a queue or substitutes an append verdict.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSDO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Source, Message, Values*) {
	global _KSDO
	_KSDO.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("error " . Source . " " . Text . "`n", _KSDO.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	LoggerError(Source, Message, Values*)
}

_KSDO_Capture() {
	global _KSDO
	Frame := _KL_SystemEventClock()
	_KSDO.Frames.Push(Frame.Clone())
	return Frame
}

; Only the classifier's declaration is renamed in the generated child. Its
; actual result is retained across scheduling, including the private positive.
MF_ShouldFilter() {
	global _KSDO
	Filtered := _KSDO_NativeFilter()
	if !_KSDO.Armed || _KSDO.Mode == "current"
		return Filtered
	_KSDO.Armed := false
	try {
		_KSDO_Require(!A_IsCritical && _KSDO.Owner.Draining,
			"The real central classifier must run inside an interruptible active drain.")
		_KSDO_Require(_KSDO.Owner.Pending.Length == 2 && Keystats._pending_entries.Length == 1,
			"The real wake and completed interval must precede the interruption.")
		_KSDO_Require(Filtered == (_KSDO.Mode == "privacy-paused"),
			"The genuine privacy decision must distinguish the two refusal causes.")
		_KSDO.First := _KSDO.Owner.Pending[1]
		_KSDO.Suffix := _KSDO.Owner.Pending[2]
		_KSDO.OldGeneration := _KSDO.Owner.Intervals.Generation
		_KSDO.OldGuard := _KSDO.Owner.IsCurrent.Bind(_KSDO.Owner, _KSDO.First, _KSDO.OldGeneration)
		_KSDO_Require(_KSDO.OldGuard.Call(), "The publication must still own its actual queue head before pause.")
		_KSDO.BeforeTimer := true
		SetTimer(_KSDO.Timer, -1)
		Started := A_TickCount
		while !_KSDO.Done && ((A_TickCount - Started) & 0xFFFFFFFF) < 2000
			Sleep(10)
		_KSDO_Require(_KSDO.Done, "The native pause must finish before classification returns.")
	} catch Any as Failure {
		_KSDO.Failure := Failure
	}
	return Filtered
}

_KSDO_Interrupt() {
	global _KSDO
	try {
		_KSDO_Require(!A_IsCritical && _KSDO.BeforeTimer && _KSDO.Owner.Draining,
			"The native timer must interrupt the admitted publication before its append guard.")
		_KSDO.TimerCalls += 1
		Suspend(1)
		_KSDO_Require(KL_Watchers_ResetSystemIntervals(), "The real collection boundary must invalidate intervals.")
		_KSDO_Require(_KSDO.Owner.Intervals.Generation > _KSDO.OldGeneration && !_KSDO.OldGuard.Call(),
			"Native pause and the actual invalidator must revoke the captured owner.")
		_KSDO_Require(_KSDO.Owner.Pending.Length == 2
			&& _KSDO.Owner.Pending[1] == _KSDO.First && _KSDO.Owner.Pending[2] == _KSDO.Suffix,
			"Pause itself must retain both exact completed records.")
		_KSDO_Require(Keystats._pending_entries.Length == 1,
			"No old wake or interval may publish before the controlled pause.")
		_KSDO.PendingAtPause := _KSDO.Owner.Pending.Length
	} catch Any as Failure {
		_KSDO.Failure := Failure
	} finally {
		_KSDO.Done := true
	}
}

_KSDO_Observe(Stage) {
	global _KSDO
	FileAppend("RECEIPT system-delivery-owner stage=" . Stage . " mode=" . _KSDO.Mode
		. " rows=" . Keystats._pending_entries.Length . " pending=" . _KSDO.Owner.Pending.Length
		. " timer_calls=" . _KSDO.TimerCalls . " paused=" . A_IsSuspended
		. " old_generation=" . _KSDO.OldGeneration . " generation=" . _KSDO.Owner.Intervals.Generation
		. " privacy_hits=" . Keystats.health_privacy_hits . "`n", "*", "UTF-8")
}

_KSDO_CheckCycle(StartIndex, StartFrame) {
	global _KSDO
	Rows := Keystats._pending_entries
	FirstFrame := _KSDO.Frames[StartFrame]
	LastFrame := _KSDO.Frames[StartFrame + 1]
	_KSDO_Require(Rows[StartIndex]["action"] == "sleep" && Rows[StartIndex + 1]["action"] == "wake"
		&& Rows[StartIndex + 2]["action"] == "passive_period", "Sleep/wake observations must preserve their raw order and one completed interval.")
	_KSDO_Require(Rows[StartIndex + 2]["kind"] == "sleep"
		&& Rows[StartIndex + 2]["duration_ms"] == LastFrame["tick"] - FirstFrame["tick"]
		&& Rows[StartIndex + 2]["timestamp"] == LastFrame["timestamp"],
		"The accepted interval must keep its actual observed clock inputs across retries.")
}

_KSDO_Exercise() {
	global _KSDO
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	MetricsFocusCache.state := {valid: true, process_name: "private-fixture.exe", title: "private fixture", class: "Fixture"}
	_KSDO_Require(_KL_Watchers_SystemStart(), "The actual system event factory must admit its owner.")
	_KSDO.Owner := KLWatch.system_events
	_KSDO.Owner.ClockFn := _KSDO_Capture
	_KSDO_Require(_KSDO.Owner.Observe("sleep"), "The first real observation must publish through the genuine append bridge.")
	_KSDO_Require(Keystats._pending_entries.Length == 1 && _KSDO.Owner.Pending.Length == 0,
		"The admitted seed cannot leave technical debt.")
	if _KSDO.Mode == "privacy-paused"
		MetricsFilters.disabled_apps["private-fixture.exe"] := true
	Sleep(20)
	_KSDO.Armed := true
	_KSDO.WakeResult := _KSDO.Owner.Observe("wake")
	if IsObject(_KSDO.Failure)
		throw _KSDO.Failure
	_KSDO_Require(_KSDO.Errors == 0 && _KSDO.Frames.Length == 2,
		"An unrelated diagnostic or clock omission cannot count as a business failure.")
	if _KSDO.Mode != "current" {
		_KSDO_Require(_KSDO.Done && _KSDO.BeforeTimer && _KSDO.TimerCalls == 1
			&& _KSDO.PendingAtPause == 2 && A_IsSuspended && !_KSDO.OldGuard.Call(),
			"The exact native revocation prerequisite must precede business assertions.")
		_KSDO_Require(_KSDO.First["entry"]["action"] == "wake"
			&& _KSDO.Suffix["entry"]["action"] == "passive_period", "The retained objects must be the real raw edge and completed interval.")
	}
	_KSDO_Observe("old-return")
	if _KSDO.Mode == "current" {
		_KSDO_Require(_KSDO.WakeResult && Keystats._pending_entries.Length == 3 && _KSDO.Owner.Pending.Length == 0,
			"An uninterrupted owner must accept both real records exactly once.")
	} else {
		_KSDO_Require(!_KSDO.WakeResult && Keystats._pending_entries.Length == 1,
			"The paused call cannot append either old wake record.")
		if _KSDO.Mode == "paused" {
			_KSDO_Require(_KSDO.Owner.Pending.Length == 2 && _KSDO.Owner.Pending[1] == _KSDO.First
				&& _KSDO.Owner.Pending[2] == _KSDO.Suffix,
				"An exact owner refusal must preserve the completed head and untouched suffix, not become a privacy drop.")
			_KSDO_Require(Keystats.health_privacy_hits == 0, "Public pending records cannot acquire a privacy refusal.")
		} else {
			_KSDO_Require(_KSDO.Owner.Pending.Length == 1 && _KSDO.Owner.Pending[1] == _KSDO.Suffix
				&& Keystats.health_privacy_hits == 1, "A genuine privacy refusal stays terminal even when pause invalidates the same attempt.")
		}
		Suspend(0)
		_KSDO_Require(_KSDO.Owner.Drain(), "A current drain must settle the actual retained records.")
		_KSDO_Require(_KSDO.Owner.Pending.Length == 0, "Resume must settle the retained owner without new debt.")
	}
	if _KSDO.Mode == "privacy-paused" {
		_KSDO_Require(Keystats._pending_entries.Length == 1 && Keystats.health_privacy_hits == 2,
			"Neither private record may reappear after the paused publication resumes.")
		MetricsFilters.disabled_apps.Delete("private-fixture.exe")
	} else {
		_KSDO_Require(Keystats._pending_entries.Length == 3, "Both public records must reach the queue once after current delivery.")
		_KSDO_CheckCycle(1, 1)
	}
	BeforeNew := Keystats._pending_entries.Length
	_KSDO_Require(_KSDO.Owner.Observe("sleep"), "A new current edge must remain admissible.")
	Sleep(20)
	_KSDO_Require(_KSDO.Owner.Observe("wake"), "The new current interval must still publish.")
	_KSDO_Require(Keystats._pending_entries.Length == BeforeNew + 3 && _KSDO.Owner.Pending.Length == 0,
		"A fresh public cycle must publish once without reviving or duplicating old debt.")
	_KSDO_CheckCycle(BeforeNew + 1, 3)
	_KSDO_Require(_KSDO.Owner.Drain() && Keystats._pending_entries.Length == BeforeNew + 3,
		"An empty repeated drain cannot duplicate previously accepted rows.")
	_KSDO_Observe("complete")
}

_KSDO_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _KSDO := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Timer: _KSDO_Interrupt,
		Owner: 0, Frames: [], Armed: false, TimerCalls: 0, BeforeTimer: false, Done: false,
		PendingAtPause: -1, OldGeneration: -1, OldGuard: 0, Failure: 0, Errors: 0}
	Primary := 0
	try _KSDO_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		SetTimer(_KSDO.Timer, 0)
		Suspend(0)
		if IsObject(_KSDO.Owner)
			_KSDO.Owner.Reset()
		KLWatch.system_events := false
		_KSDO.OldGuard := 0
		_KSDO.Owner := 0
		_KSDO.Timer := 0
		Keystats.initialized := false
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_KSDO.Log) {
			for Line in StrSplit(FileRead(_KSDO.Log, "UTF-8"), "`n", "`r")
				if Line != ""
					FileAppend("DIAG " . Line . "`n", "*", "UTF-8")
		}
		ExitApp(1)
	}
	FileAppend("PASS system-delivery-owner " . _KSDO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_KSDO_Main()
