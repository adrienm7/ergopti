; tests/fixtures/keylogger_fire_publication_owner_body.ahk

; ==============================================================================
; MODULE: Deferred Fire Publication Owner Child
; DESCRIPTION:
; Actual queue, lifecycle invalidation, privacy and append bodies run unchanged.
; The timestamp port delegates the real clock and controls only a native timer
; cutpoint permitted by AHK's between-line scheduler. It never writes a queue.
; ==============================================================================

#Requires AutoHotkey v2.0

_KFPO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerDebug(Source, Message, Values*) {
	global _KFPO
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("debug " . Source . " " . Text . "`n", _KFPO.Log, "UTF-8")
}
LoggerError(Source, Message, Values*) {
	global _KFPO
	_KFPO.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("error " . Source . " " . Text . "`n", _KFPO.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	global _KFPO
	_KFPO.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("warning " . Source . " " . Text . "`n", _KFPO.Log, "UTF-8")
}
KL_Roi_OnHotstring(Trigger, Saved, Private) {
	global _KFPO
	_KFPO.Roi.Push(Trigger)
}
WPMWidget_Push(*) {
	global _KFPO
	_KFPO.Wpm += 1
}

; The real function's body is retained as _KFPO_NativeTimestamp in the child.
; This port does not claim that the default wall clock pumps messages itself.
KL_NowTimestamp() {
	global _KFPO
	Stamp := _KFPO_NativeTimestamp()
	_KFPO.TimeCalls += 1
	if _KFPO.TimeCalls != 1 || _KFPO.Mode == "current"
		return Stamp
	try {
		_KFPO_Require(!A_IsCritical, "The timestamp cutpoint must remain interruptible.")
		_KFPO_Require(_PrefixDeferredCanPublish(_KFPO.OldGeneration),
			"The real old guard must still be current when the append requests its timestamp.")
		_KFPO_Require(Keystats._pending_entries.Length == 0,
			"No canonical row may precede the controlled native interruption.")
		_KFPO.BeforeTimer := true
		SetTimer(_KFPO.Timer, -1)
		Started := A_TickCount
		while !_KFPO.Done && ((A_TickCount - Started) & 0xFFFFFFFF) < 2000
			Sleep(10)
		_KFPO_Require(_KFPO.Done, "The real revocation timer must settle before append resumes.")
	} catch Any as Failure {
		_KFPO.Failure := Failure
	}
	return Stamp
}

_KFPO_Interrupt() {
	global _KFPO, _PrefixDeferredGeneration
	try {
		_KFPO_Require(!A_IsCritical && _KFPO.BeforeTimer,
			"The native timer must run after the admitted guard and before append mutation.")
		_KFPO_Require(Keystats._pending_entries.Length == 0,
			"The timer must win before any old row is published.")
		_KFPO.TimerCalls += 1
		Suspend(1)
		_KFPO.RevokedGeneration := _PrefixInvalidateDeferredEffects()
		_KFPO_Require(_PrefixDeferredGeneration > _KFPO.OldGeneration,
			"The genuine lifecycle invalidator must revoke the original generation.")
		if _KFPO.Mode == "resumed" {
			Suspend(0)
			HotstringPrefixWatcherOnResume()
		}
		_KFPO_Require(!_PrefixDeferredCanPublish(_KFPO.OldGeneration),
			"A resumed native driver cannot restore the old generation's authority.")
		_KFPO.RowsAtRevocation := Keystats._pending_entries.Length
	} catch Any as Failure {
		_KFPO.Failure := Failure
	} finally {
		_KFPO.Done := true
	}
}

_KFPO_Queue(Trigger, Replacement) {
	_KFPO_Require(_HSE_QueueFireLog(Trigger, Replacement, "endchar", "fixture", "fixture"),
		"The actual producer must admit every private fixture fire.")
}

_KFPO_Observe(Stage) {
	global _KFPO, _HSE_FireLogQueue, _PrefixDeferredGeneration
	FileAppend("RECEIPT keylogger-fire-owner stage=" . Stage . " mode=" . _KFPO.Mode
		. " rows=" . Keystats._pending_entries.Length . " fires=" . _HSE_FireLogQueue.Length
		. " old_generation=" . _KFPO.OldGeneration . " generation=" . _PrefixDeferredGeneration
		. " timer_calls=" . _KFPO.TimerCalls . " clock_calls=" . _KFPO.TimeCalls
		. " paused=" . A_IsSuspended . " roi=" . _KFPO.Roi.Length . " wpm=" . _KFPO.Wpm . "`n", "*", "UTF-8")
}

_KFPO_Exercise() {
	global _KFPO, _HSE_FireLogQueue, _HSE_FireLogTimer, _PrefixDeferredGeneration
	Keystats.initialized := true
	Keystats.session_app := "private-fixture.exe"
	MetricsFilters.secure_field := false
	MetricsFocusCache.state := {valid: true, process_name: "private-fixture.exe", title: "private fixture", class: "Fixture"}
	_KFPO.OldGeneration := _PrefixDeferredGeneration
	_KFPO_Queue("first", "first-result")
	_KFPO_Queue("suffix", "suffix-result")
	_KFPO.First := _HSE_FireLogQueue[1], _KFPO.Suffix := _HSE_FireLogQueue[2]
	_KFPO.DrainResult := _HSE_DrainFireLog(_KFPO.OldGeneration)
	; A retained suffix may have armed its real fresh 90 ms timer. Keep that
	; owned callback dormant while observing, then invoke the actual drain below.
	TimerCancel(_HSE_FireLogTimer)
	if IsObject(_KFPO.Failure)
		throw _KFPO.Failure
	_KFPO_Require(_KFPO.Errors == 0, "An unrelated diagnostic cannot qualify as business refusal.")
	if _KFPO.Mode != "current" {
		_KFPO_Require(_KFPO.BeforeTimer && _KFPO.Done && _KFPO.TimerCalls == 1
			&& _KFPO.RowsAtRevocation == 0 && !_PrefixDeferredCanPublish(_KFPO.OldGeneration),
			"The exact native revocation prerequisite must precede every business oracle.")
		_KFPO_Require(A_IsSuspended == (_KFPO.Mode == "paused"), "Native pause state must match the requested cutpoint.")
	}
	if _KFPO.Mode == "resumed" {
		BeforeReference := Keystats._pending_entries.Length
		Rejected := false
		_KFPO_Require(!KL_AppendLog(Map("type", "hotstring", "trigger", "stale-control"),
			&Rejected, _PrefixDeferredCanPublish.Bind(_KFPO.OldGeneration)),
			"The unchanged central owner fence must reject the old generation after native resume.")
		_KFPO_Require(Keystats._pending_entries.Length == BeforeReference,
			"The central negative reference cannot mutate the queue.")
	}
	_KFPO_Observe("old-return")
	if _KFPO.Mode == "current" {
		_KFPO_Require(_KFPO.DrainResult && Keystats._pending_entries.Length == 2,
			"An uninterrupted real drain must publish both current fires.")
		_KFPO_Require(_HSE_FireLogQueue.Length == 0 && _KFPO.Roi.Length == 2 && _KFPO.Wpm == 25,
			"Current publication must consume once and preserve the legitimate metrics.")
	} else {
		_KFPO_Require(Keystats._pending_entries.Length == 0,
			"A revoked old fire must not enter the canonical queue after its timestamp returns.")
		_KFPO_Require(!_KFPO.DrainResult && _HSE_FireLogQueue.Length == 2
			&& _HSE_FireLogQueue[1] == _KFPO.First && _HSE_FireLogQueue[2] == _KFPO.Suffix,
			"The real drain must retain the exact pre-pause fire and untouched suffix once.")
		_KFPO_Require(_KFPO.Roi.Length == 0 && _KFPO.Wpm == 0,
			"The revoked callback must not mutate the live metric observers.")
		; The central optional owner fence is an unchanged positive reference:
		; even after resume, an explicitly guarded append refuses the old owner.
		Suspend(0)
		Rejected := false
		_KFPO_Require(!KL_AppendLog(Map("type", "hotstring", "trigger", "stale-control"),
			&Rejected, _PrefixDeferredCanPublish.Bind(_KFPO.OldGeneration)),
			"The genuine central owner guard must still reject its revoked generation.")
		_KFPO_Require(Keystats._pending_entries.Length == 0, "The central reference cannot publish a stale row.")
		HotstringPrefixWatcherOnResume()
		_KFPO_Require(_HSE_DrainFireLog(_PrefixDeferredGeneration), "A fresh owner must drain the actual retained batch.")
		_KFPO_Require(Keystats._pending_entries.Length == 2 && _HSE_FireLogQueue.Length == 0,
			"Fresh transfer must consume both retained fires exactly once.")
		_KFPO_Require(_KFPO.Roi.Length == 2 && _KFPO.Wpm == 25,
			"The fresh owner must retain the legitimate pre-pause metrics.")
	}
	_KFPO_Require(Keystats._pending_entries[1]["trigger"] == "first"
		&& Keystats._pending_entries[2]["trigger"] == "suffix", "Retained fire order cannot change.")
	_KFPO_Queue("new", "new-result")
	NewFire := _HSE_FireLogQueue[1]
	if _KFPO.Mode != "current" {
		_KFPO_Require(!_HSE_DrainFireLog(_KFPO.OldGeneration), "Late old delivery must remain inert.")
		_KFPO_Require(_HSE_FireLogQueue.Length == 1 && _HSE_FireLogQueue[1] == NewFire,
			"A late old callback cannot consume the successor's queued fire.")
	}
	_KFPO_Require(_HSE_DrainFireLog(_PrefixDeferredGeneration), "The actual new fire must reach its current drain.")
	_KFPO_Require(Keystats._pending_entries.Length == 3 && _HSE_FireLogQueue.Length == 0
		&& Keystats._pending_entries[3]["trigger"] == "new" && _KFPO.Roi.Length == 3 && _KFPO.Wpm == 35,
		"A current successor fire and its metrics must publish exactly once.")
	_KFPO_Observe("complete")
}

_KFPO_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _KFPO := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Timer: _KFPO_Interrupt,
		TimeCalls: 0, TimerCalls: 0, Done: false, BeforeTimer: false, RowsAtRevocation: -1,
		OldGeneration: -1, RevokedGeneration: -1, Errors: 0, Failure: 0, Roi: [], Wpm: 0}
	Primary := 0
	try _KFPO_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		SetTimer(_KFPO.Timer, 0)
		_PrefixInvalidateDeferredEffects()
		TimerCancelAll()
		Suspend(0)
		Keystats.initialized := false
		_KFPO.Timer := 0
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_KFPO.Log) {
			for Line in StrSplit(FileRead(_KFPO.Log, "UTF-8"), "`n", "`r")
				if Line != ""
					FileAppend("DIAG " . Line . "`n", "*", "UTF-8")
		}
		ExitApp(1)
	}
	FileAppend("PASS keylogger-fire-owner " . _KFPO.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_KFPO_Main()
