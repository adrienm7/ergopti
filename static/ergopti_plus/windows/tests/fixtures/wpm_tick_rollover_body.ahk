; tests/fixtures/wpm_tick_rollover_body.ahk

; Actual WPM producers and calculation share one controlled native-width uptime clock. This
; does not wait for an OS rollover or create a widget, keyboard hook or timer.
#Requires AutoHotkey v2.0

_WPMR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_WPMR_Now() {
	global _WPMR
	_WPMR_Require(_WPMR.Now is Integer && _WPMR.Now >= 0,
		"The explicit clock must remain a nonnegative native-width integer.")
	_WPMR.Reads += 1
	return _WPMR.Now
}

_WPMR_Push(Tick, Ai := false, Ac := false) {
	global _WPMR
	_WPMR_Require(Tick is Integer && Tick >= _WPMR.Now, "The real producer clock must be monotone, without a DWORD reset.")
	_WPMR.Now := Tick
	Before := WPMWidget._ring.Length
	WPMWidget_Push(false, Ai, Ac)
	_WPMR_Require(WPMWidget._ring.Length == Before + 1
		&& WPMWidget._ring[Before + 1]["t"] == Tick && WPMWidget._last_tick == Tick,
		"The actual admitted producer must own every stored timestamp.")
}

_WPMR_Main() {
	global _WPMR
	if A_Args.Length != 4
		ExitApp(2)
	_WPMR := {Mode: A_Args[1], Now: 0, Reads: 0}
	Primary := 0, PreviousSuspend := A_IsSuspended, PreviousCritical := A_IsCritical
	try {
		Suspend(false)
		WPMWidgetConst.WINDOW_MS := Integer(A_Args[3])
		WPMWidgetConst.WPM_MIN_DURATION_MS := Integer(A_Args[4])
		_WPMR_Require(WPMWidgetConst.WINDOW_MS == 15000 && WPMWidgetConst.WPM_MIN_DURATION_MS == 2000,
			"These fixed vectors require the actual shared 15000/2000 ms timing contract.")
		_WPMR_Require(WPMWidget._ring.Length == 0 && WPMWidget._ring_head == 0,
			"A fresh genuine state class must own an empty ring.")
		WPMWidget.visible := true
		switch _WPMR.Mode {
			case "full64-expired-after-dword-period":
				_WPMR_Push(1000, true)
				_WPMR_Push(1500, false, true)
				_WPMR.Now := 0x100000000 + 2500
				Expected := 0, ExpectedAi := false, ExpectedAc := false, ExpectedRows := 2
			case "full64-across-dword-boundary":
				_WPMR_Push(0x100000000 - 5000, true)
				_WPMR_Push(0x100000000 + 2500, false, true)
				_WPMR.Now := 0x100000000 + 5000
				Expected := 2, ExpectedAi := true, ExpectedAc := true, ExpectedRows := 2
			case "expired-and-minimum":
				_WPMR_Push(4999, true)
				_WPMR_Push(19000)
				_WPMR_Push(19500, false, true)
				_WPMR.Now := 20000
				Expected := 12, ExpectedAi := false, ExpectedAc := true, ExpectedRows := 3
			default:
				throw ValueError("Unknown WPM clock vector")
		}
		_WPMR_Require(WPMWidget._ring.Length == ExpectedRows && _WPMR.Reads == ExpectedRows,
			"Every ring row must come from the genuine producer before calculation.")
		_WPMR_Require(_WPMR.Now >= WPMWidget._last_tick,
			"Calculation must follow the last producer on the same monotone native-width clock.")
		FirstRawAge := _WPMR.Now - WPMWidget._ring[1]["t"]
		SecondRawAge := _WPMR.Now - WPMWidget._ring[2]["t"]
		; The true age prerequisite must not call or copy the SUT's masked helper.
		; Its result below is diagnostic only, permitting a valid full-width fix.
		FirstReportedAge := _WPMWidget_TickDelta(_WPMR.Now, WPMWidget._ring[1]["t"])
		if _WPMR.Mode == "full64-expired-after-dword-period"
			_WPMR_Require(FirstRawAge == 0x100000000 + 1500 && SecondRawAge == 0x100000000 + 1000
				&& FirstRawAge > WPMWidgetConst.WINDOW_MS && SecondRawAge > WPMWidgetConst.WINDOW_MS,
				"Both retained real producer rows must genuinely be older than the rolling window.")
		else if _WPMR.Mode == "expired-and-minimum"
			_WPMR_Require(FirstRawAge == WPMWidgetConst.WINDOW_MS + 1,
				"The AI-only first row must really lie outside the shared rolling window.")
		else
			_WPMR_Require(_WPMR.Now > 0xFFFFFFFF && FirstRawAge == 10000 && SecondRawAge == 2500,
				"Full-width timestamps across the DWORD boundary must retain two legitimate current ages.")
		Result := WPMWidget_Calc()
		_WPMR_Require(Result is Map && Result.Has("wpm") && Result.Has("has_hs")
			&& Result.Has("has_ai") && Result.Has("has_ac") && _WPMR.Reads == ExpectedRows + 1,
			"The actual calculation must read the same clock and return its complete contract.")
		FileAppend("RECEIPT wpm-tick-rollover mode=" . _WPMR.Mode . " now=" . _WPMR.Now
			. " first_raw_age=" . FirstRawAge . " second_raw_age=" . SecondRawAge
			. " first_reported_age=" . FirstReportedAge . " rows=" . WPMWidget._ring.Length . " clock_reads=" . _WPMR.Reads
			. " window_ms=" . WPMWidgetConst.WINDOW_MS . " minimum_ms=" . WPMWidgetConst.WPM_MIN_DURATION_MS
			. " actual_wpm=" . Result["wpm"] . " expected_wpm=" . Expected
			. " has_ai=" . Result["has_ai"] . " has_ac=" . Result["has_ac"] . "`n", "*", "UTF-8-RAW")
		_WPMR_Require(Result["wpm"] == Expected,
			"The real WPM calculation must count only rows whose actual native-width age is inside its window.")
		_WPMR_Require(Result["has_hs"] == false && Result["has_ai"] == ExpectedAi && Result["has_ac"] == ExpectedAc,
			"Only rows inside the rolling window may contribute source flags.")
		_WPMR_Require(WPMWidget._ring.Length == ExpectedRows,
			"Calculation must preserve the producer's ring, including expired history.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		Suspend(PreviousSuspend)
		Critical(PreviousCritical)
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS wpm-tick-rollover " . _WPMR.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_WPMR_Main()
