; tests/unit/platform/input/dispatch/test_timer_delay_ceiling.ahk

; ==============================================================================
; MODULE: Timer Delay Ceiling Contract (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/timer/delay_ceiling_vectors.json against the
; Windows policy and native timer boundaries, as
; _shared/tests/lua/timer_delay_ceiling_contract.lua does on macOS and Linux.
;
; ROOT CAUSE ENCODED:
; SetTimer never refuses a period: it keeps 32 bits of it, so 2^53, 1e300,
; infinity and NaN armed a one-shot that fired at once, and TimerArmOneShotMs
; passed them through. A year's delay also became another delay. Below the shared ceiling
; the native range is narrower: such a delay is refused, never truncated.
; ==============================================================================

#Requires AutoHotkey v2.0

; Decodes the values JSON cannot spell.
_TDC_Value(Value) {
	if !(Value is String)
		return Value
	Infinity := 1e308 * 10
	switch Value {
		case "inf": return Infinity
		case "-inf": return -Infinity
		case "nan": return Infinity - Infinity
	}
	throw ValueError("Unknown corpus value.", -1, Value)
}

; Rows of one vector list, each with its decoded delay under "value". JsonParse
; refuses an integer literal past 2^63, which Lua reads as a float: spell the
; corpus's one such literal as the float it stands for.
_TDC_Rows(ListName, Unit) {
	global _SharedDir
	Text := FileRead(_SharedDir . "\tests\corpus\timer\delay_ceiling_vectors.json", "UTF-8")
	Text := RegExReplace(Text, '(:\s*\d{19,})(\s*,)', "$1.0$2", &Spelled)
	AssertEqual(1, Spelled, "the corpus holds its integer literal past 2^63")
	Rows := JsonParse(Text)[ListName]
	Assert(Rows.Length >= 6, "the corpus holds its " . ListName)
	for Row in Rows
		Row["value"] := _TDC_Value(Row[Unit])
	return Rows
}

_TDC_Mark(Fired, *) {
	Fired.Count += 1
}

; A shared ceiling kept in step with its Lua owner.
_TDC_OneCeiling() {
	global TIMER_MAX_DELAY_MS, _SharedDir
	AssertEqual(9007199254740992, TIMER_MAX_DELAY_MS, "the ceiling is 2^53 ms")
	Assert(InStr(FileRead(_SharedDir . "\core\text\engine\number_policy.lua", "UTF-8"), "M.MAX_TIMER_DELAY_MS = 2 ^ 53") > 0,
		"the Lua policy declares the same ceiling")
}
Test("timer-delay-ceiling: one named ceiling of 2^53 ms", _TDC_OneCeiling)

_TDC_PolicyMilliseconds() {
	for Row in _TDC_Rows("millisecond_vectors", "milliseconds")
		AssertEqual(Row["admitted"] ? 1 : 0, TimerDelayWithinCeiling(Row["value"]) ? 1 : 0, "policy " . Row["id"])
	Assert(!TimerDelayWithinCeiling("5"), "a numeric string is not a number here")
}
Test("timer-delay-ceiling: policy replays the millisecond vectors", _TDC_PolicyMilliseconds)

_TDC_PolicySeconds() {
	for Row in _TDC_Rows("second_vectors", "seconds") {
		Ms := TimerDelayMsFromSeconds(Row["value"])
		AssertEqual(Row["admitted"] ? 1 : 0, (Ms is Number) ? 1 : 0, "seconds conversion " . Row["id"])
		if (Ms is Number)
			Assert(Ms >= 0, "an admitted corpus delay stays positive: " . Row["id"])
	}
}
Test("timer-delay-ceiling: seconds conversion replays the second vectors", _TDC_PolicySeconds)

; The one-shot boundary: a refused delay raises and never fires, an admitted one
; within the native range arms. The delays under the wait really fire.
_TDC_OneShotBoundary() {
	global TIMER_ADAPTER_MAX_INTERVAL_MS
	Refused := 0, Armed := 0
	for Row in _TDC_Rows("millisecond_vectors", "milliseconds") {
		Value := Row["value"]
		FitsNative := Row["admitted"] && Abs(Value) <= TIMER_ADAPTER_MAX_INTERVAL_MS
		Fired := { Count: 0 }
		Callback := _TDC_Mark.Bind(Fired)
		Raised := false
		try TimerArmOneShotMs(Callback, Value)
		catch ValueError
			Raised := true
		AssertEqual(FitsNative ? 0 : 1, Raised ? 1 : 0, "one-shot verdict of " . Row["id"])
		ExpectFire := FitsNative && Abs(Value) < 20
		if FitsNative && !ExpectFire
			SetTimer(Callback, 0)
		Sleep(60)
		SetTimer(Callback, 0)
		AssertEqual(ExpectFire ? 1 : 0, Fired.Count, "one-shot delivery of " . Row["id"])
		Refused += Raised ? 1 : 0
		Armed += Raised ? 0 : 1
	}
	Assert(Refused >= 6 && Armed >= 4, "the replay covers both verdicts")
}
Test("timer-delay-ceiling: TimerArmOneShotMs refuses before the native timer", _TDC_OneShotBoundary)

; TimerAfter and TimerEvery keep their lower bound: zero seconds is refused.
_TDC_SecondsBoundaries() {
	global TIMER_ADAPTER_MAX_INTERVAL_MS
	for Row in _TDC_Rows("second_vectors", "seconds") {
		Value := Row["value"]
		Expected := Row["admitted"] && Value > 0 && Value * 1000.0 <= TIMER_ADAPTER_MAX_INTERVAL_MS
		for Boundary in [TimerAfter, TimerEvery] {
			Handle := 0
			try Handle := Boundary.Call(Value, _TDC_Mark.Bind({ Count: 0 }))
			catch ValueError
				Handle := 0
			AssertEqual(Expected ? 1 : 0, IsObject(Handle) ? 1 : 0, Boundary.Name . " verdict of " . Row["id"])
			if IsObject(Handle)
				AssertTrue(TimerCancel(Handle), "the armed fixture timer retires")
		}
	}
}
Test("timer-delay-ceiling: TimerAfter and TimerEvery refuse before the native timer", _TDC_SecondsBoundaries)

; The lowest Integer is its own Abs: a magnitude test would have admitted it.
_TDC_RawPeriodBoundary() {
	for Period in [-0x100000000, -(2 ** 53), -0x7FFFFFFFFFFFFFFF - 1, 2 ** 53] {
		Fired := { Count: 0 }
		Callback := _TDC_Mark.Bind(Fired)
		AssertThrows(TimerSetCallback.Bind(Callback, Period))
		AssertThrows(TimerRequireDelayMs.Bind(Period, "test"))
		Sleep(30)
		AssertEqual(0, Fired.Count, "a refused period never fires")
	}
}
Test("timer-delay-ceiling: raw periods past 32 bits are refused", _TDC_RawPeriodBoundary)
