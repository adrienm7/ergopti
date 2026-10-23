; tests/unit/modules/gestures/test_take_note_native64_deadline.ahk

; ==============================================================================
; MODULE: Take-Note Native64 Deadline Tests
; DESCRIPTION:
; Exercises the public deferred job with its existing logical OS/timer ports.
; Full-width monotonic clock gaps are controlled; no real Notepad is launched.
; ==============================================================================

#Requires AutoHotkey v2.0+

class _TN64_Ops extends _TakeNoteFakeOps {
	static Cut := ""
	static Arm := false
	static CaptureNext := false
	static BoundaryHits := 0
	static Advanced := false
	static AdvancedReads := 0
	static TargetTick := 0

	static ResetBoundary(Cut, TargetTick) {
		_TN64_Ops.Cut := Cut
		_TN64_Ops.Arm := false
		_TN64_Ops.CaptureNext := false
		_TN64_Ops.BoundaryHits := 0
		_TN64_Ops.Advanced := false
		_TN64_Ops.AdvancedReads := 0
		_TN64_Ops.TargetTick := TargetTick
	}

	static NowTick() {
		Captured := _TakeNoteFakeOps.NowTick()
		if _TN64_Ops.Advanced
			_TN64_Ops.AdvancedReads += 1
		if _TN64_Ops.CaptureNext {
			_TN64_Ops.CaptureNext := false
			; This sample remains the earlier observation. Every later sample
			; sees the advanced clock, never a synthetic backwards rollover.
			_TakeNoteFakeOps.now_tick := _TN64_Ops.TargetTick
			_TN64_Ops.Advanced := true
		}
		return Captured
	}

	static FindWindow(FileName) {
		Result := _TakeNoteFakeOps.FindWindow(FileName)
		if (_TN64_Ops.Arm and _TN64_Ops.Cut == "reschedule") {
			_TN64_Ops.Arm := false
			_TN64_Ops.BoundaryHits += 1
			_TN64_Ops.CaptureNext := true
		}
		return Result
	}

	static Activate(Hwnd) {
		Result := _TakeNoteFakeOps.Activate(Hwnd)
		if (_TN64_Ops.Arm and _TN64_Ops.Cut == "after-activate") {
			_TN64_Ops.Arm := false
			_TN64_Ops.BoundaryHits += 1
			_TakeNoteFakeOps.now_tick := _TN64_Ops.TargetTick
			_TN64_Ops.Advanced := true
		}
		return Result
	}
}

_TN64_Case(Cut, Age, Expired) {
	global _TakeNotePending, TAKE_NOTE_LAUNCH_TIMEOUT_MS
	Start := 0x100000000 + 1000
	AssertTrue(Age is Integer and Age >= 0)
	AssertEqual(Expired, Age >= TAKE_NOTE_LAUNCH_TIMEOUT_MS,
		"the independent full-width age must agree with the scenario")
	Fields := StrSplit("now_tick suspended file_exists window_exists active "
		. "focus_after_activate suspend_after_launch schedule_ok timers calls "
		. "launch_count maximize_count send_count warning_count errors windows "
		. "last_pattern last_file_name last_target last_send "
		. "replacement_title_after_activate", " ")
	Saved := Map()
	Owned := Map()
	PreviousCritical := Critical("On")
	Claimed := false
	try {
		AssertEqual(0, _TakeNotePending.Count,
			"the fixture must not park an active foreign take-note job")
		SavedPending := _TakeNotePending
		for Name in Fields
			Saved[Name] := _TakeNoteFakeOps.%Name%
		_TakeNotePending := Owned
		Claimed := true
		_TakeNoteFakeOps.Reset(Start)
		_TN64_Ops.ResetBoundary(Cut, Start + Age)
		Critical("Off")

		JobId := TakeNoteRequest(false, "C:\TN64-private-model", true, _TN64_Ops)
		AssertTrue(JobId > 0 and Owned.Has(JobId),
			"the public request must admit the exact deferred job")
		AssertEqual(1, _TakeNoteFakeOps.timers.Length)
		AssertFalse(_TakeNoteFakeOps.file_exists)
		AssertEqual(0, _TakeNoteFakeOps.launch_count)
		AssertEqual(Start, Owned[JobId]["started_tick"])
		AssertEqual(TAKE_NOTE_LAUNCH_TIMEOUT_MS, Owned[JobId]["timeout_ms"])

		if Cut == "queued" {
			_TakeNoteFakeOps.now_tick := Start + Age
			_TN64_Ops.Advanced := true
		} else {
			; The first genuine callback establishes a waiting job. Its existing
			; file/launch effects precede the later expiry and are not rolled back.
			_TakeNoteFakeOps.RunNext()
			AssertEqual(0, _TakeNoteFakeOps.errors.Length)
			AssertTrue(Owned.Has(JobId))
			AssertEqual("waiting", Owned[JobId]["phase"])
			AssertEqual(1, _TakeNoteFakeOps.timers.Length)
			AssertTrue(_TakeNoteFakeOps.file_exists)
			AssertEqual(1, _TakeNoteFakeOps.launch_count)
			AssertEqual(0, _TakeNoteFakeOps.maximize_count)
			AssertEqual(0, _TakeNoteFakeOps.send_count)
			_TN64_Ops.Arm := true
			_TakeNoteFakeOps.window_exists := Cut == "after-activate"
		}

		_TakeNoteFakeOps.RunNext()
		AssertEqual(0, _TakeNoteFakeOps.errors.Length,
			"a caught production/port exception cannot stand in for expiry")
		AssertTrue(_TN64_Ops.Advanced and _TN64_Ops.AdvancedReads > 0,
			"the real state machine must observe the advanced monotonic clock")
		if Cut != "queued"
			AssertEqual(1, _TN64_Ops.BoundaryHits,
				"the selected genuine OS-port return must be crossed once")
		AssertEqual(Start + Age, _TakeNoteFakeOps.now_tick)
		FileAppend("TAKE_NOTE64_RECEIPT cut=" . Cut . " age=" . Age
			. " timeout=" . TAKE_NOTE_LAUNCH_TIMEOUT_MS
			. " pending=" . Owned.Has(JobId)
			. " file=" . _TakeNoteFakeOps.file_exists
			. " launches=" . _TakeNoteFakeOps.launch_count
			. " maximizes=" . _TakeNoteFakeOps.maximize_count
			. " sends=" . _TakeNoteFakeOps.send_count
			. " warnings=" . _TakeNoteFakeOps.warning_count
			. " timers=" . _TakeNoteFakeOps.timers.Length . "`n", "*")

		if Expired {
			if Cut == "queued" {
				AssertFalse(_TakeNoteFakeOps.file_exists,
					"an expired queued job must not mutate the logical filesystem")
				AssertEqual(0, _TakeNoteFakeOps.launch_count)
			}
			AssertEqual(0, _TakeNoteFakeOps.maximize_count,
				"no window mutation may follow the observed expiry")
			AssertEqual(0, _TakeNoteFakeOps.send_count,
				"no final input may follow the observed expiry")
			AssertFalse(Owned.Has(JobId),
				"the expired owner must retire rather than re-arm itself")
			AssertEqual(0, _TakeNoteFakeOps.timers.Length)
			AssertEqual(1, _TakeNoteFakeOps.warning_count)
		} else {
			AssertEqual(0, _TakeNoteFakeOps.warning_count)
			if Cut != "after-activate" {
				AssertTrue(Owned.Has(JobId))
				AssertEqual(1, _TakeNoteFakeOps.timers.Length)
				_TakeNoteFakeOps.window_exists := true
				_TakeNoteFakeOps.RunNext()
			}
			AssertEqual(0, _TakeNoteFakeOps.errors.Length)
			AssertFalse(Owned.Has(JobId))
			AssertEqual(0, _TakeNoteFakeOps.timers.Length)
			AssertTrue(_TakeNoteFakeOps.file_exists)
			AssertEqual(1, _TakeNoteFakeOps.launch_count)
			AssertEqual(1, _TakeNoteFakeOps.maximize_count)
			AssertEqual(1, _TakeNoteFakeOps.send_count)
			AssertEqual("^{End}{Enter}", _TakeNoteFakeOps.last_send)
		}
	} finally {
		Critical("On")
		if Claimed {
			; Only logical fixture callbacks exist. Retire exact private jobs,
			; release their controlled queue, then restore all parked references.
			for JobId in Owned.Clone()
				_TakeNoteFinish(JobId)
			_TakeNoteFakeOps.timers := []
			_TakeNotePending := SavedPending
			for Name, Value in Saved
				_TakeNoteFakeOps.%Name% := Value
			_TN64_Ops.ResetBoundary("", 0)
		}
		Critical(PreviousCritical)
	}
}

_TN64_Run(Cut) {
	global TAKE_NOTE_LAUNCH_TIMEOUT_MS
	_TN64_Case(Cut, TAKE_NOTE_LAUNCH_TIMEOUT_MS - 1, false)
	_TN64_Case(Cut, TAKE_NOTE_LAUNCH_TIMEOUT_MS, true)
	_TN64_Case(Cut, 0x100000001, true)
}

Test("take note native64: queued expiry prevents file and launch work "
	. "(takenote-native64-deadline)", _TN64_Run.Bind("queued"))
Test("take note native64: expiry prevents re-arming a waiting job "
	. "(takenote-native64-deadline)", _TN64_Run.Bind("reschedule"))
Test("take note native64: expiry after activation prevents window and input work "
	. "(takenote-native64-deadline)", _TN64_Run.Bind("after-activate"))
