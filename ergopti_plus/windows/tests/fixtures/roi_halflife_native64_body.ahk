; tests/fixtures/roi_halflife_native64_body.ahk

; ==============================================================================
; MODULE: ROI Half-Life Clock Child
; DESCRIPTION: OnHotstring is the sole writer of the private trigger map. Its
; real A_TickCount read and the timer's read use an explicit typed64 clock port.
; The future control captures an old timer sample, admits a newer real fire on a
; native timer, then resumes that older frame. No map values or SUT math are copied.
; ==============================================================================

#Requires AutoHotkey v2.0

_RHL_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

LoggerError(Source, Message, Values*) {
	global _RHL
	_RHL.Errors += 1
	FileAppend("error " . Source . " " . Format(Message, Values*) . "`n", _RHL.Log, "UTF-8")
}
LoggerWarn(Source, Message, Values*) {
	LoggerError(Source, Message, Values*)
}

_RHL_Now(Producer) {
	global _RHL
	NativeNow := A_TickCount
	_RHL.LastNative := NativeNow
	if Producer == "KL_Roi_OnHotstring" {
		_RHL.PushReads += 1
		return _RHL.PushTick
	}
	_RHL_Require(Producer == "KL_Roi_HalflifeTick", "Only the two authenticated production clock sites can use this port.")
	_RHL.TickReads += 1
	; Retain this frame's first sample, but later reads see the advanced clock.
	Captured := _RHL.CurrentTick
	if !_RHL.Armed
		return Captured
	_RHL.Armed := false
	if A_IsCritical {
		; A native noninterruptible clock read legitimately prevents this cutpoint.
		; Do not force a yield or infer global clock/snapshot atomicity from it.
		_RHL.CutpointProtected := true
		return Captured
	}
	try {
		_RHL_Require(!A_IsCritical && !A_IsSuspended && _RHL.TickReads == 1
			&& KLRoi.trigger_last_use.Count == 1 && KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.Origin,
			"A real timer sample must precede the new fire without a policy or owner refusal.")
		_RHL.CapturedBeforeTimer := Captured
		SetTimer(_RHL.ActivityTimer, -1)
		Started := A_TickCount
		while !_RHL.ActivityDone && TickElapsed64(Started) < 2000
			Sleep(10)
		_RHL_Require(_RHL.ActivityDone && _RHL.ActivityCalls == 1,
			"The genuine newer fire must complete on a native timer before the retained sample returns.")
	} catch Any as Failure {
		_RHL.Failure := Failure
	}
	return Captured
}

_RHL_AdmitNewFire() {
	global _RHL
	try {
		_RHL_Require(!A_IsCritical && !A_IsSuspended && _RHL.CapturedBeforeTimer == _RHL.SampleTick,
			"The newer fire must interrupt the old sample on its actual native timer.")
		_RHL.ActivityCalls += 1
		_RHL.PushTick := _RHL.SampleTick + 500
		_RHL.CurrentTick := _RHL.PushTick
		KL_Roi_OnHotstring(_RHL.Trigger, 7, false)
		_RHL_Require(KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.PushTick
			&& KLRoi.session_fired_count == 2 && KLRoi.session_saved_chars == 14,
			"The real public producer, not a direct map assignment, must admit the future row.")
	} catch Any as Failure {
		_RHL.Failure := Failure
	} finally _RHL.ActivityDone := true
}

_RHL_ObserveTick() {
	global _RHL
	try {
		_RHL.TimerCalls += 1
		KLRoi.halflife_fn.Call()
	} catch Any as Failure {
		_RHL.Failure := Failure
	} finally _RHL.TickDone := true
}

_RHL_Observe(Stage) {
	global _RHL
	LastUse := KLRoi.trigger_last_use[_RHL.Trigger]
	Age := _RHL.SampleTick - LastUse
	RowDays := Keystats._pending_entries.Length ? Keystats._pending_entries[1].Get("days_since_use", -1) : -1
	FileAppend("RECEIPT roi-halflife64-owner stage=" . Stage . " mode=" . _RHL.Mode
		. " now=" . _RHL.SampleTick . " last_use=" . LastUse . " raw_age=" . Age
		. " rows=" . Keystats._pending_entries.Length . " days=" . RowDays
		. " fired=" . KLRoi.session_fired_count . " saved=" . KLRoi.session_saved_chars
		. " push_reads=" . _RHL.PushReads . " tick_reads=" . _RHL.TickReads
		. " timer_calls=" . _RHL.TimerCalls . " activity_calls=" . _RHL.ActivityCalls
		. " cutpoint_protected=" . _RHL.CutpointProtected
		. " native_tick=" . A_TickCount . " errors=" . _RHL.Errors . "`n", "*", "UTF-8")
}

_RHL_Exercise() {
	global _RHL
	Keystats.initialized := true
	Keystats.session_app := "roi-clock-fixture.exe"
	MetricsFilters.secure_field := false
	MetricsFocusCache.state := {valid: true, process_name: "roi-clock-fixture.exe", title: "private ROI fixture", class: "Fixture"}
	_RHL_Require(!A_IsSuspended && KLRoi.trigger_last_use.Count == 0
		&& KLRoi.session_fired_count == 0 && Keystats._pending_entries.Length == 0,
		"Fresh real state, not historical persisted dates or a previous run, must own the fixture.")
	_RHL_Require(!MF_ShouldFilter() && !MF_ShouldFilterFor(Keystats.session_app, "private ROI fixture"),
		"The genuine public privacy predicates must admit this fixture before any business result.")
	_RHL.Origin := 1000
	_RHL.PushTick := _RHL.Origin
	_RHL.CurrentTick := _RHL.Origin
	DayMs := 86400000
	_RHL.SampleTick := _RHL.Origin + 31 * DayMs
	if _RHL.Mode == "days46"
		_RHL.SampleTick := _RHL.Origin + 46 * DayMs
	else if _RHL.Mode == "era31"
		_RHL.SampleTick := _RHL.Origin + 0x100000000 + 31 * DayMs
	else if _RHL.Mode == "future"
		_RHL.SampleTick := _RHL.Origin + 1000
	else
		_RHL_Require(_RHL.Mode == "days31", "The test must select one declared mode.")
	_RHL_Require(_RHL.SampleTick is Integer && _RHL.SampleTick > _RHL.Origin
		&& KLRoiConst.HALFLIFE_WARN_DAYS == 30 && KLRoiConst.ROI_SNAPSHOT_EVERY > 2,
		"Actual timing and snapshot constants must isolate one half-life event from periodic ROI snapshots.")
	KL_Roi_OnHotstring(_RHL.Trigger, 7, false)
	_RHL_Require(_RHL.PushReads == 1 && KLRoi.trigger_last_use.Count == 1
		&& KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.Origin
		&& KLRoi.session_saved_chars == 7 && KLRoi.session_fired_count == 1
		&& Keystats._pending_entries.Length == 0,
		"The genuine admitted public fire must own the exact full-width timestamp and savings.")
	_RHL_Require(KL_Roi_Start() && KLRoi.HasOwnProp("halflife_fn"),
		"The genuine public lifecycle must admit its actual timer identity.")
	; Run that genuine callback once now, with a native scheduling owner which
	; retains any exception before the business oracles. No simulated tick loop.
	_RHL.CurrentTick := _RHL.SampleTick
	_RHL.Armed := _RHL.Mode == "future"
	SetTimer(_RHL.TickTimer, -1)
	Started := A_TickCount
	while !_RHL.TickDone && TickElapsed64(Started) < 3000
		Sleep(10)
	if IsObject(_RHL.Failure)
		throw _RHL.Failure
	_RHL_Require(_RHL.TickDone && _RHL.TimerCalls == 1 && _RHL.TickReads >= 1 && _RHL.Errors == 0,
		"A real timer must settle without a hidden producer or privacy fallback error.")
	_RHL_Require(_RHL.PushReads == (_RHL.Mode == "future" && !_RHL.CutpointProtected ? 2 : 1)
		&& KLRoi.trigger_last_use.Count == 1,
		"Every map entry must still come from its genuine public producer.")
	_RHL_Observe("old-return")
	if _RHL.Mode == "future" {
		if _RHL.CutpointProtected {
			_RHL_Require(_RHL.ActivityCalls == 0 && !_RHL.ActivityDone
				&& _RHL.CapturedBeforeTimer == -1 && _RHL.PushReads == 1
				&& KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.Origin
				&& KLRoi.session_fired_count == 1 && KLRoi.session_saved_chars == 7,
				"A genuinely protected cutpoint must preserve the admitted initial fire without pretending an interruption occurred.")
		} else {
			_RHL_Require(_RHL.ActivityCalls == 1 && _RHL.ActivityDone
				&& _RHL.CapturedBeforeTimer == _RHL.SampleTick
				&& KLRoi.trigger_last_use[_RHL.Trigger] > _RHL.SampleTick,
				"An interruptible old sample requires the genuine native timer and newer real fire.")
		}
		_RHL_Require(Keystats._pending_entries.Length == 0,
			"A fire newer than the sampled timer cannot be reported as a stale trigger.")
	} else {
		_RHL_Require(Keystats._pending_entries.Length == 1,
			"Every admitted public trigger unused beyond the warning threshold must emit its half-life record.")
		Row := Keystats._pending_entries[1]
		ExpectedDays := Round((_RHL.SampleTick - _RHL.Origin) / DayMs, 1)
		_RHL_Require(Row["type"] == "trigger_halflife" && Row["trigger"] == _RHL.Trigger
			&& Row["app"] == Keystats.session_app && Row["days_since_use"] == ExpectedDays
			&& Row.Has("timestamp") && Row["timestamp"] != "" && Row["_event_id"] > 0,
			"The true central queue must preserve the trigger's complete monotonic age, not its 32-bit remainder.")
	}
	_RHL_Require(KLRoi.trigger_last_use[_RHL.Trigger] == _RHL.PushTick
		&& _RHL.Errors == 0, "Publication cannot rewrite the admitted fire timestamp or hide an error.")
	_RHL_Observe("complete")
}

_RHL_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _RHL := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Trigger: "private-fixture-trigger",
		Origin: 0, PushTick: 0, SampleTick: 0, CurrentTick: 0, Armed: false, PushReads: 0, TickReads: 0,
		LastNative: 0, TimerCalls: 0, TickDone: false, CapturedBeforeTimer: -1,
		ActivityCalls: 0, ActivityDone: false, CutpointProtected: false, TickTimer: _RHL_ObserveTick, ActivityTimer: _RHL_AdmitNewFire,
		Failure: 0, Errors: 0}
	Primary := 0
	try _RHL_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		try {
			SetTimer(_RHL.TickTimer, 0)
			SetTimer(_RHL.ActivityTimer, 0)
			_RHL_Require(KL_Roi_Stop() && !KLRoi.HasOwnProp("halflife_fn") && _RHL.Errors == 0,
				"The exact admitted native timer must retire through the real lifecycle owner.")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			_RHL.TickTimer := 0
			_RHL.ActivityTimer := 0
			Keystats.initialized := false
		}
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_RHL.Log)
			FileAppend("DIAG " . FileRead(_RHL.Log, "UTF-8") . "`n", "*", "UTF-8")
		ExitApp(1)
	}
	FileAppend("PASS roi-halflife64-owner " . _RHL.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_RHL_Main()
