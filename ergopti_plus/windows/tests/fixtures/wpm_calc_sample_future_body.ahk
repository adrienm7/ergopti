; tests/fixtures/wpm_calc_sample_future_body.ahk

; A real timer publishes genuine producer rows after Calc captured its clock,
; before that same clock invocation returns. Only fixture scheduling/time is
; controlled: native time is never rewound, and no ring row is fabricated.
#Requires AutoHotkey v2.0

_WPMF_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_WPMF_KeepFailure(Failure) {
	global _WPMF
	if !IsObject(_WPMF.Failure)
		_WPMF.Failure := Failure
}
_WPMF_OnError(Failure, *) {
	_WPMF_KeepFailure(Failure)
	return true
}

; Canonical child generator replaces exactly one native sample in each real
; Push and Calc with this reader. Capture precedes timer publication; returning
; that retained sample after a later producer is not a backwards clock read.
_WPMR_Now() {
	global _WPMF
	Value := _WPMF.Now
	_WPMF_Require(Value is Integer && Value >= 0, "Every sampled clock must be a nonnegative native-width Integer.")
	if _WPMF.Phase == "push" {
		_WPMF.PushReads += 1
		return Value
	}
	_WPMF_Require(_WPMF.Phase == "calc", "The genuine reader must have an explicit producer or calculator phase.")
	_WPMF.CalcReads += 1
	_WPMF.CapturedNow := Value
	if !_WPMF.Armed
		return Value
	_WPMF.Armed := false
	try {
		_WPMF_Require(!A_IsCritical && !A_IsSuspended && WPMWidget._ring.Length == 0,
			"The old calculator sample must precede ring admission on an interruptible empty frame.")
		_WPMF.BoundaryEntered := true
		SetTimer(_WPMF.Timer, -1)
		Started := A_TickCount
		while !_WPMF.TimerDone && TickElapsed64(Started) < 2000
			Sleep(10)
		_WPMF_Require(_WPMF.TimerDone && _WPMF.TimerCalls == 1 && _WPMF.Now == 1500,
			"The genuine producer timer must settle before the old captured sample returns.")
	} catch Any as Failure {
		_WPMF_KeepFailure(Failure)
	}
	return Value
}

_WPMF_PushAt(Tick, Ai, Ac) {
	global _WPMF
	_WPMF_Require(Tick is Integer && Tick >= _WPMF.Now, "Producer samples must advance monotonically, never reset.")
	SavedPhase := _WPMF.Phase
	_WPMF.Now := Tick, _WPMF.Phase := "push"
	Before := WPMWidget._ring.Length
	try {
		WPMWidget_Push(false, Ai, Ac)
		_WPMF_Require(WPMWidget._ring.Length == Before + 1
			&& WPMWidget._ring[Before + 1]["t"] == Tick && WPMWidget._last_tick == Tick,
			"Only the actual admitted producer may publish a row and its clock watermark.")
	} finally {
		_WPMF.Phase := SavedPhase
	}
}

_WPMF_ProducerTimer() {
	global _WPMF
	try {
		_WPMF_Require(!A_IsCritical && !A_IsSuspended && _WPMF.BoundaryEntered
			&& _WPMF.CapturedNow == 1000 && _WPMF.Now == 1000 && WPMWidget._ring.Length == 0,
			"A true native timer must interrupt after the retained sample and before any ring publication.")
		_WPMF.TimerCalls += 1
		_WPMF_PushAt(1500, true, false)
		_WPMF_PushAt(1500, false, true)
		_WPMF.First := WPMWidget._ring[1], _WPMF.Second := WPMWidget._ring[2]
		_WPMF.HeadAtPublication := WPMWidget._ring_head
	} catch Any as Failure {
		_WPMF_KeepFailure(Failure)
	} finally {
		_WPMF.TimerDone := true
	}
}

_WPMF_CheckRows() {
	global _WPMF
	_WPMF_Require(WPMWidget._ring.Length == 2 && WPMWidget._ring_head == _WPMF.HeadAtPublication
		&& WPMWidget._ring[1] == _WPMF.First && WPMWidget._ring[2] == _WPMF.Second,
		"The two exact genuine producer row objects must remain retained in order.")
	_WPMF_Require(_WPMF.First["ai"] && !_WPMF.First["ac"] && !_WPMF.First["hs"]
		&& !_WPMF.Second["ai"] && _WPMF.Second["ac"] && !_WPMF.Second["hs"],
		"The independent affirmative source flags must come from both real producers.")
}

_WPMF_Main() {
	global _WPMF
	if A_Args.Length != 4
		ExitApp(2)
	_WPMF := {Mode: A_Args[1], Now: 0, Phase: "setup", Armed: false, Failure: 0,
		PushReads: 0, CalcReads: 0, CapturedNow: 0, BoundaryEntered: false,
		Timer: _WPMF_ProducerTimer, TimerCalls: 0, TimerDone: false, First: 0, Second: 0, HeadAtPublication: -1}
	Primary := 0, PreviousSuspend := A_IsSuspended, PreviousCritical := Critical("Off")
	Suspend(false)
	Thread("Interrupt", 0)
	OnError(_WPMF_OnError)
	try {
		WPMWidgetConst.WINDOW_MS := Integer(A_Args[3])
		WPMWidgetConst.WPM_MIN_DURATION_MS := Integer(A_Args[4])
		_WPMF_Require(WPMWidgetConst.WINDOW_MS == 15000 && WPMWidgetConst.WPM_MIN_DURATION_MS == 2000,
			"The native child must use the actual shared rolling-window and minimum-duration contract.")
		_WPMF_Require(WPMWidget._ring.Length == 0 && WPMWidget._ring_head == 0,
			"Fresh genuine state must be empty before either public producer runs.")
		WPMWidget.visible := true
		if _WPMF.Mode == "sample-before-producer" {
			_WPMF.Now := 1000, _WPMF.Phase := "calc", _WPMF.Armed := true
		} else {
			_WPMF_Require(_WPMF.Mode == "current", "Only the two declared scheduling modes may run.")
			_WPMF_PushAt(1000, true, false)
			_WPMF_PushAt(1500, false, true)
			_WPMF.First := WPMWidget._ring[1], _WPMF.Second := WPMWidget._ring[2]
			_WPMF.HeadAtPublication := WPMWidget._ring_head
			_WPMF.Now := 2000, _WPMF.Phase := "calc"
		}
		Result := 0, CalculationFailure := 0
		try Result := WPMWidget_Calc()
		catch Any as Failure
			CalculationFailure := Failure
		if IsObject(_WPMF.Failure)
			throw _WPMF.Failure
		_WPMF_CheckRows()
		_WPMF_Require(_WPMF.PushReads == 2 && _WPMF.CalcReads == 1 && !_WPMF.Armed,
			"Two genuine producers and the one genuine calculator must read their exact clock observations.")
		if _WPMF.Mode == "sample-before-producer"
			_WPMF_Require(_WPMF.TimerCalls == 1 && _WPMF.TimerDone && _WPMF.BoundaryEntered
				&& _WPMF.CapturedNow == 1000 && _WPMF.Now == 1500
				&& _WPMF.First["t"] == 1500 && _WPMF.Second["t"] == 1500,
				"Actual timer publication must make both real rows newer than the retained calculator sample.")
		else
			_WPMF_Require(_WPMF.TimerCalls == 0 && _WPMF.CapturedNow == 2000
				&& _WPMF.First["t"] == 1000 && _WPMF.Second["t"] == 1500,
				"The affirmative calculation must sample after both admitted producer rows.")
		FileAppend("RECEIPT wpm-calc-sampled-future mode=" . _WPMF.Mode . " captured=" . _WPMF.CapturedNow
			. " current_clock=" . _WPMF.Now . " first_tick=" . _WPMF.First["t"] . " second_tick=" . _WPMF.Second["t"]
			. " rows=" . WPMWidget._ring.Length . " published_head=" . _WPMF.HeadAtPublication . " head=" . WPMWidget._ring_head
			. " timer_calls=" . _WPMF.TimerCalls
			. " push_reads=" . _WPMF.PushReads . " calc_reads=" . _WPMF.CalcReads
			. " calculation_threw=" . (IsObject(CalculationFailure) ? 1 : 0)
			. " actual_wpm=" . (Result is Map ? Result["wpm"] : -1) . "`n", "*", "UTF-8-RAW")
		_WPMF_Require(!IsObject(CalculationFailure), "A valid retained calculator sample must refuse future rows without throwing.")
		_WPMF_Require(Result is Map && Result.Has("wpm") && Result.Has("has_hs")
			&& Result.Has("has_ai") && Result.Has("has_ac"), "The actual calculator must return its complete contract.")
		Expected := _WPMF.Mode == "current" ? 12 : 0
		_WPMF_Require(Result["wpm"] == Expected && !Result["has_hs"]
			&& Result["has_ai"] == (_WPMF.Mode == "current") && Result["has_ac"] == (_WPMF.Mode == "current"),
			"Only rows admitted by this calculator sample may contribute WPM and source flags.")
		_WPMF_CheckRows()
		; The older frame must not consume future history: a fresh frame can use
		; the same exact producer rows once its actual sample has caught up.
		_WPMF.Now := 2000
		Fresh := WPMWidget_Calc()
		_WPMF_Require(Fresh["wpm"] == 12 && !Fresh["has_hs"] && Fresh["has_ai"] && Fresh["has_ac"]
			&& _WPMF.CalcReads == 2 && _WPMF.PushReads == 2,
			"A fresh genuine calculator must admit the retained two source rows without republishing them.")
		_WPMF_CheckRows()
		FileAppend("COMPLETE wpm-calc-sampled-future fresh_wpm=" . Fresh["wpm"]
			. " rows=" . WPMWidget._ring.Length . " timer_calls=" . _WPMF.TimerCalls . "`n", "*", "UTF-8-RAW")
	} catch Any as Failure {
		Primary := IsObject(_WPMF.Failure) ? _WPMF.Failure : Failure
	} finally {
		try SetTimer(_WPMF.Timer, 0)
		catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_WPMF_OnError, 0)
		Suspend(PreviousSuspend)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_WPMF.Failure)
		Primary := _WPMF.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS wpm-calc-sampled-future " . _WPMF.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_WPMF_Main()
