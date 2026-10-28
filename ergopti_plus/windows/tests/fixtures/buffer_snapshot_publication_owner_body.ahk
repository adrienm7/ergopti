; tests/fixtures/buffer_snapshot_publication_owner_body.ahk

; ==============================================================================
; MODULE: Detached Snapshot Publication Owner Child
; DESCRIPTION:
; Real public mouse counters seed a mouse-only typing snapshot, without OS input
; injection. The genuine fire drain flushes it before its two real fire records.
; Clock/privacy ports delegate their complete real bodies and only control one
; native timer cutpoint; canonical append and snapshot restoration are unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

_KBSP_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerDebug(Source, Message, Values*) {
	global _KBSP
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("debug " . Source . " " . Text . "`n", _KBSP.Log, "UTF-8")
}
LoggerError(Source, Message, Values*) {
	global _KBSP
	_KBSP.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend("error " . Source . " " . Text . "`n", _KBSP.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	LoggerError(Source, Message, Values*)
}
KL_Roi_OnHotstring(Trigger, Saved, Private) {
	global _KBSP
	_KBSP.Roi.Push(Trigger)
}
WPMWidget_Push(*) {
	global _KBSP
	_KBSP.Wpm += 1
}

; The public name delegates the exact native body retained by the existing
; fire child composer. Default clocks are not claimed to pump on every call.
KL_NowTimestamp() {
	global _KBSP
	Stamp := _KFPO_NativeTimestamp()
	_KBSP.TimeCalls += 1
	if _KBSP.Armed && _KBSP.Mode != "current" && _KBSP.Mode != "privacy-resumed"
		_KBSP_Cutpoint()
	return Stamp
}

MF_ShouldFilter() {
	global _KBSP
	Filtered := _KBSP_NativeFilter()
	if _KBSP.Armed && _KBSP.Mode == "privacy-resumed" {
		try _KBSP_Require(Filtered, "The private positive must retain a genuine terminal privacy decision.")
		catch Any as Failure
			_KBSP.Failure := Failure
		_KBSP_Cutpoint()
	}
	return Filtered
}

_KBSP_Cutpoint() {
	global _KBSP
	_KBSP.Armed := false
	try {
		_KBSP_Require(!A_IsCritical && Keystats._flush_in_progress,
			"The real detached snapshot must own the interruptible append cutpoint.")
		_KBSP_Require(_PrefixDeferredCanPublish(_KBSP.OldGeneration)
			&& Keystats._pending_entries.Length == 0 && Keystats.session_clicks == 0,
			"The old owner must still be valid after detachment and before canonical publication.")
		_KBSP_Require(Keystats.buffer_events != _KBSP.OldEvents
			&& Keystats.next_event_id == _KBSP.OldEventId + 1,
			"A real reference swap and reserved event id must precede revocation.")
		_KBSP.BeforeTimer := true
		SetTimer(_KBSP.Timer, -1)
		Started := A_TickCount
		while !_KBSP.Done && ((A_TickCount - Started) & 0xFFFFFFFF) < 2000
			Sleep(10)
		_KBSP_Require(_KBSP.Done, "The native revocation must settle before append resumes.")
	} catch Any as Failure {
		_KBSP.Failure := Failure
	}
}

_KBSP_Interrupt() {
	global _KBSP, _PrefixDeferredGeneration
	try {
		_KBSP_Require(!A_IsCritical && _KBSP.BeforeTimer && Keystats._flush_in_progress,
			"The native timer must interrupt the actual detached publication owner.")
		_KBSP_Require(Keystats._pending_entries.Length == 0,
			"Revocation must win before the first canonical row.")
		_KBSP.TimerCalls += 1
		Suspend(1)
		_PrefixInvalidateDeferredEffects()
		if _KBSP.Mode != "paused" {
			Suspend(0)
			HotstringPrefixWatcherOnResume()
		}
		_KBSP_Require(_PrefixDeferredGeneration > _KBSP.OldGeneration
			&& !_PrefixDeferredCanPublish(_KBSP.OldGeneration),
			"Pause and the real invalidator must revoke the captured generation after resume too.")
		_KBSP.RowsAtRevocation := Keystats._pending_entries.Length
	} catch Any as Failure {
		_KBSP.Failure := Failure
	} finally {
		_KBSP.Done := true
	}
}

_KBSP_Input(App) {
	KL_SetSessionApp(App)
	KL_SetSessionTitle("private fixture " . App)
	KL_SetSessionLayout("fixture-layout")
	KL_SetSessionUrl("fixture://" . App)
	KL_SetSessionFieldRole("fixture-role")
	KL_BumpMouseClick()
}

_KBSP_Queue(Trigger, Replacement) {
	_KBSP_Require(_HSE_QueueFireLog(Trigger, Replacement, "endchar", "fixture", "fixture"),
		"The genuine producer must admit the private fixture fire.")
}

_KBSP_Observe(Stage) {
	global _KBSP, _HSE_FireLogQueue, _PrefixDeferredGeneration
	FileAppend("RECEIPT snapshot-owner stage=" . Stage . " mode=" . _KBSP.Mode
		. " rows=" . Keystats._pending_entries.Length . " retries=" . Keystats._retry_snapshots.Length
		. " fires=" . _HSE_FireLogQueue.Length . " clicks=" . Keystats.session_clicks
		. " old_generation=" . _KBSP.OldGeneration . " generation=" . _PrefixDeferredGeneration
		. " timer_calls=" . _KBSP.TimerCalls . " clock_calls=" . _KBSP.TimeCalls
		. " paused=" . A_IsSuspended . " roi=" . _KBSP.Roi.Length . " wpm=" . _KBSP.Wpm . "`n", "*", "UTF-8")
}

_KBSP_Typing(Row, App, Events) {
	_KBSP_Require(Row["type"] == "typing" && Row["app"] == App
		&& Row["title"] == "private fixture " . App && Row["url"] == "fixture://" . App
		&& Row["field_role"] == "fixture-role" && Row["layout"] == "fixture-layout"
		&& Row["app_category"] == "fixture-known" && Row["mouse_clicks"] == 1
		&& Row["events"] == Events && Row["text"] == "",
		"The real mouse-only snapshot must retain its origin, category and exact detached event array.")
}

_KBSP_Exercise() {
	global _KBSP, _HSE_FireLogQueue, _HSE_FireLogTimer, _PrefixDeferredGeneration
	Keystats.initialized := true
	; Private known categories exercise the real lookup without scheduling a save
	; or requiring a metrics store. No category lookup is replaced by a fake port.
	KLAppCat.file_path := _KBSP.Log . ".categories"
	for App in ["old-fixture.exe", "new-fixture.exe", "later-fixture.exe"]
		KLAppCat.categories[App] := "fixture-known"
	MetricsFilters.secure_field := false
	MetricsFocusCache.state := {valid: true, process_name: "old-fixture.exe", title: "private fixture", class: "Fixture"}
	if _KBSP.Mode == "privacy-resumed"
		MetricsFilters.disabled_apps["old-fixture.exe"] := true
	_KBSP_Input("old-fixture.exe")
	_KBSP.OldEvents := Keystats.buffer_events
	_KBSP.OldEventId := Keystats.next_event_id
	_KBSP.OldGeneration := _PrefixDeferredGeneration
	_KBSP_Queue("first", "first-result")
	_KBSP_Queue("suffix", "suffix-result")
	_KBSP.First := _HSE_FireLogQueue[1], _KBSP.Suffix := _HSE_FireLogQueue[2]
	_KBSP.Armed := true
	Result := _HSE_DrainFireLog(_KBSP.OldGeneration)
	TimerCancel(_HSE_FireLogTimer)
	if IsObject(_KBSP.Failure)
		throw _KBSP.Failure
	_KBSP_Require(_KBSP.Errors == 0 && !KLAppCat.dirty && !Keystats._flush_in_progress,
		"Every reached dependency must complete without diagnostic fallback or retained flush ownership.")
	if _KBSP.Mode != "current" {
		_KBSP_Require(_KBSP.BeforeTimer && _KBSP.Done && _KBSP.TimerCalls == 1
			&& _KBSP.RowsAtRevocation == 0 && !_PrefixDeferredCanPublish(_KBSP.OldGeneration),
			"The exact native lifecycle prerequisite must pass before any business oracle.")
		_KBSP_Require(A_IsSuspended == (_KBSP.Mode == "paused"), "Native pause state must match the cutpoint.")
	}
	_KBSP_Observe("old-return")
	if _KBSP.Mode == "current" {
		_KBSP_Require(Result && Keystats._pending_entries.Length == 3 && _HSE_FireLogQueue.Length == 0,
			"An uninterrupted drain must publish its snapshot before both fires.")
		_KBSP_Require(Keystats._retry_snapshots.Length == 0, "A current accepted snapshot cannot remain retryable.")
		_KBSP_Typing(Keystats._pending_entries[1], "old-fixture.exe", _KBSP.OldEvents)
		FirstIndex := 2
	} else {
		_KBSP_Require(Keystats._pending_entries.Length == 0,
			"The revoked snapshot owner must not publish a typing row after the native cutpoint.")
		_KBSP_Require(!Result && _HSE_FireLogQueue.Length == 2
			&& _HSE_FireLogQueue[1] == _KBSP.First && _HSE_FireLogQueue[2] == _KBSP.Suffix,
			"Both exact pre-pause fires must remain queued for a fresh owner.")
		_KBSP_Require(_KBSP.Roi.Length == 0 && _KBSP.Wpm == 0,
			"A revoked callback cannot publish realtime fire metrics.")
		Private := _KBSP.Mode == "privacy-resumed"
		_KBSP_Require(Keystats._retry_snapshots.Length == (Private ? 0 : 1),
			"Only a lifecycle refusal retains the detached snapshot; privacy remains terminal.")
		if !Private {
			Snapshot := Keystats._retry_snapshots[1]
			_KBSP_Require(Snapshot.Events == _KBSP.OldEvents && Snapshot.EventId == _KBSP.OldEventId
				&& Snapshot.App == "old-fixture.exe" && Snapshot.Clicks == 1,
				"The same reserved snapshot must survive without merging into the live buffer.")
		}
		Suspend(0)
		HotstringPrefixWatcherOnResume()
		MetricsFilters.disabled_apps := Map()
		MetricsFocusCache.state := {valid: true, process_name: "new-fixture.exe", title: "private fixture", class: "Fixture"}
		_KBSP_Input("new-fixture.exe")
		NewEvents := Keystats.buffer_events
		_KBSP_Require(NewEvents != _KBSP.OldEvents && Keystats.session_clicks == 1,
			"A genuine new public counter must have a separate live buffer.")
		_KBSP_Require(_HSE_DrainFireLog(_PrefixDeferredGeneration), "A fresh generation must flush and drain the retained fires.")
		_KBSP_Require(Keystats._retry_snapshots.Length == 0 && Keystats.session_clicks == 0
			&& _HSE_FireLogQueue.Length == 0 && Keystats._pending_entries.Length == (Private ? 3 : 4),
			"The retry must flush old and live snapshots separately before consuming both fires.")
		if !Private {
			_KBSP_Typing(Keystats._pending_entries[1], "old-fixture.exe", _KBSP.OldEvents)
			_KBSP_Require(Keystats._pending_entries[1]["_event_id"] == _KBSP.OldEventId,
				"Retry preserves the reserved event id; timestamp generation remains the real publication clock.")
		}
		_KBSP_Typing(Keystats._pending_entries[Private ? 1 : 2], "new-fixture.exe", NewEvents)
		FirstIndex := Private ? 2 : 3
	}
	_KBSP_Require(Keystats._pending_entries[FirstIndex]["trigger"] == "first"
		&& Keystats._pending_entries[FirstIndex + 1]["trigger"] == "suffix"
		&& _KBSP.Roi.Length == 2 && _KBSP.Wpm == 25,
		"The two original fires and their legitimate metrics must publish in order exactly once.")
	Count := Keystats._pending_entries.Length
	_KBSP_Input("later-fixture.exe")
	LaterEvents := Keystats.buffer_events
	_KBSP_Queue("new", "new-result")
	NewFire := _HSE_FireLogQueue[1]
	if _KBSP.Mode != "current" {
		_KBSP_Require(!_HSE_DrainFireLog(_KBSP.OldGeneration), "A late old drain cannot impersonate the fresh owner.")
		_KBSP_Require(_HSE_FireLogQueue.Length == 1 && _HSE_FireLogQueue[1] == NewFire
			&& Keystats.session_clicks == 1 && Keystats._pending_entries.Length == Count,
			"Old delivery cannot consume the successor fire, counter or canonical rows.")
	}
	_KBSP_Require(_HSE_DrainFireLog(_PrefixDeferredGeneration), "Current successor data must remain publishable.")
	_KBSP_Require(Keystats._pending_entries.Length == Count + 2 && _HSE_FireLogQueue.Length == 0
		&& Keystats._pending_entries[Count + 2]["trigger"] == "new"
		&& _KBSP.Roi.Length == 3 && _KBSP.Wpm == 35,
		"A later real snapshot and current fire must both publish exactly once.")
	_KBSP_Typing(Keystats._pending_entries[Count + 1], "later-fixture.exe", LaterEvents)
	PreviousId := 0
	for Row in Keystats._pending_entries {
		_KBSP_Require(Row["_event_id"] > PreviousId && Row.Has("timestamp"),
			"Canonical ordering must retain unique increasing reserved ids and real publication timestamps.")
		PreviousId := Row["_event_id"]
	}
	_KBSP_Observe("complete")
}

_KBSP_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _KBSP := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Timer: _KBSP_Interrupt,
		Armed: false, TimeCalls: 0, TimerCalls: 0, BeforeTimer: false, Done: false,
		RowsAtRevocation: -1, OldGeneration: -1, Errors: 0, Failure: 0, Roi: [], Wpm: 0}
	Primary := 0
	try _KBSP_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		SetTimer(_KBSP.Timer, 0)
		_PrefixInvalidateDeferredEffects()
		TimerCancelAll()
		Suspend(0)
		Keystats.initialized := false
		_KBSP.Timer := 0
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_KBSP.Log) {
			for Line in StrSplit(FileRead(_KBSP.Log, "UTF-8"), "`n", "`r")
				if Line != ""
					FileAppend("DIAG " . Line . "`n", "*", "UTF-8")
		}
		ExitApp(1)
	}
	FileAppend("PASS snapshot-owner " . _KBSP.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_KBSP_Main()
