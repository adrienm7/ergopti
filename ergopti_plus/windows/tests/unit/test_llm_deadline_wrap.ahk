; tests/unit/test_llm_deadline_wrap.ahk

; ==============================================================================
; MODULE: Explicit Tick-Domain Regression Tests
; DESCRIPTION:
; The historical vectors below exercise modulo32 compatibility for truncated
; DWORD clocks, not native A_TickCount rollover. New vectors qualify the native
; GetTickCount64 domain without discarding its high words. Existing test names
; executable UInt32 cases remain unchanged; titles identify their DWORD domain.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================================
; ========================================================
; ======= 1/ Inline arithmetic helpers for testing =======
; ========================================================
; ========================================================

; Route every assertion through the production timing primitive.  The former
; version duplicated the formula locally, so it could not detect a change in
; the production primitive. These cases exercise TickExpired, not an LLM owner.
_TDW_DeadlineExpired(start_tick, timeout_ms, now_tick) {
	return TickExpired(start_tick, timeout_ms, now_tick)
}

; Absolute comparison is incompatible with truncated DWORD samples after wrap.
_TDW_DeadlineExpiredNaive(start_tick, timeout_ms, now_tick) {
	return now_tick >= (start_tick + timeout_ms)
}





; ===================================================
; ===================================================
; ======= 2/ Post-wrap expiry detection tests =======
; ===================================================
; ===================================================



; start_tick near the 32-bit ceiling; timeout pushes the absolute deadline
; past 0xFFFFFFFF; now_tick has wrapped to a small positive value.
; elapsed = (now_tick - start_tick + 2^32) & 0xFFFFFFFF
;         = (120000 - 0xFFFF0000 + 0x100000000) & 0xFFFFFFFF
;         = (120000 + 65536) & 0xFFFFFFFF
;         = 185536
; 185536 >= 180000 => true (expired)
_TDW_PostWrapExpired() {
	start := 0xFFFF0000
	tms   := 180000
	now   := 120000
	Assert(_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must detect expiry when now has wrapped past start_tick (llm-deadline-wrap)")
}
Test("DWORD TickExpired: detects expiry after a truncated sample rollover (llm-deadline-wrap)", _TDW_PostWrapExpired)





; =====================================================
; =====================================================
; ======= 3/ Naive form fails on the same input =======
; =====================================================
; =====================================================

; In AHK integer arithmetic, 0xFFFF0000 + 180000 equals 4295081760;
; it does not overflow. The synthetic current DWORD sample is only 120000,
; so absolute comparison returns false while the modulo32 elapsed interval is
; 185536. Mixing a full absolute deadline with a truncated current sample is
; the error illustrated here, not native A_TickCount overflow.
_TDW_NaiveFailsPostWrap() {
	start := 0xFFFF0000
	tms   := 180000
	now   := 120000
	Assert(!_TDW_DeadlineExpiredNaive(start, tms, now),
		"naive form must NOT detect expiry on post-wrap values -- documents the overflow bug (llm-deadline-wrap)")
}
Test("DWORD absolute comparison: misses expiry after truncated sample rollover (llm-deadline-wrap)", _TDW_NaiveFailsPostWrap)





; =================================================
; =================================================
; ======= 4/ Normal (no-wrap) sanity checks =======
; =================================================
; =================================================

; Both forms must agree when no wrap occurs and the timeout has elapsed.
_TDW_NoWrapExpired() {
	start := 1000000
	tms   := 5000
	now   := 1006000
	Assert(_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must detect expiry in the normal no-wrap case (llm-deadline-wrap)")
	Assert(_TDW_DeadlineExpiredNaive(start, tms, now),
		"naive check must also detect expiry in the normal no-wrap case (llm-deadline-wrap)")
}
Test("DWORD TickExpired: both forms agree when timeout elapsed without rollover (llm-deadline-wrap)", _TDW_NoWrapExpired)


; Both forms must agree when no wrap occurs and the timeout has NOT elapsed.
_TDW_NoWrapNotExpired() {
	start := 1000000
	tms   := 5000
	now   := 1003000
	Assert(!_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must return false when timeout has not elapsed (llm-deadline-wrap)")
	Assert(!_TDW_DeadlineExpiredNaive(start, tms, now),
		"naive check must also return false when timeout has not elapsed (llm-deadline-wrap)")
}
Test("DWORD TickExpired: both forms agree before timeout without rollover (llm-deadline-wrap)", _TDW_NoWrapNotExpired)


; Exact boundary: elapsed == timeout_ms must count as expired.
_TDW_ExactBoundary() {
	start := 500000
	tms   := 3000
	now   := 503000
	Assert(_TDW_DeadlineExpired(start, tms, now),
		"wrap-safe check must treat elapsed == timeout_ms as expired (llm-deadline-wrap)")
}
Test("DWORD TickExpired: exact timeout boundary expires (llm-deadline-wrap)", _TDW_ExactBoundary)


_TDW_SharedPrimitiveVectors() {
	start := 0xFFFFFFD0
	now := 40
	AssertEqual(88, TickElapsed(start, now),
		"TickElapsed must preserve elapsed time across rollover (llm-deadline-wrap)")
	AssertEqual(112, TickRemaining(start, 200, now),
		"TickRemaining must preserve the pre-expiry remainder across rollover (llm-deadline-wrap)")
	Assert(!TickExpired(start, 200, now),
		"TickExpired must not expire a live interval after rollover (llm-deadline-wrap)")

	start := 0xFFFFFF9C
	now := 150
	AssertEqual(250, TickElapsed(start, now),
		"TickElapsed must report the full post-rollover duration (llm-deadline-wrap)")
	AssertEqual(0, TickRemaining(start, 200, now),
		"TickRemaining must clamp expired intervals to zero (llm-deadline-wrap)")
	Assert(TickExpired(start, 200, now),
		"TickExpired must expire a post-rollover interval (llm-deadline-wrap)")
}
Test("DWORD tick primitives: elapsed, remaining and expiry across truncated rollover (llm-deadline-wrap)", _TDW_SharedPrimitiveVectors)

; Native A_TickCount is monotonic 64-bit. These literal vectors deliberately
; retain its high words; the older synthetic DWORD cases above stay unchanged.
_TD64_Vector(Start, Now, Expected) {
	AssertEqual(Expected, TickElapsed64(Start, Now), "native elapsed time must retain every high word")
}
for Row in [[100, 131, 31], [4294967280, 4294967311, 31],
		[100, 4294967396, 4294967296], [100, 4294967427, 4294967327],
		[4294967280, 8589934613, 4294967333],
		[9007199254740992, 9007199254741023, 31],
		[0, 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF],
		[0x7FFFFFFFFFFFFFF8, 0x7FFFFFFFFFFFFFFF, 7]]
	Test("tick64: full monotonic interval " . Row[1] . " to " . Row[2] . " (native-tick64)",
		_TD64_Vector.Bind(Row[1], Row[2], Row[3]))

_TD64_Boundary(Now, Expired, Remaining) {
	AssertEqual(Expired, TickExpired64(0, 4294967346, Now), "expiry must use the full monotonic duration")
	AssertEqual(Remaining, TickRemaining64(0, 4294967346, Now), "remaining must preserve the full duration boundary")
}
for Row in [[4294967345, false, 1], [4294967346, true, 0], [4294967347, true, 0]]
	Test("tick64: long duration boundary at " . Row[1] . " (native-tick64)", _TD64_Boundary.Bind(Row*))

_TD64_ZeroAndLongGap() {
	AssertEqual(0, TickElapsed64(0, 0), "zero is a valid origin and current tick")
	AssertTrue(TickExpired64(0, 0, 0), "zero duration expires at its valid origin")
	AssertEqual(0, TickRemaining64(0, 0, 0), "zero duration has no remaining time")
	AssertTrue(TickExpired64(100, 50, 4294967396), "a full cycle cannot make an expired interval live again")
	AssertEqual(0, TickRemaining64(100, 50, 4294967396), "a full cycle cannot restore a remaining duration")
	AssertEqual(0x7FFFFFFFFFFFFFFF, TickRemaining64(0, 0x7FFFFFFFFFFFFFFF, 0), "the largest representable duration is retained")
	AssertTrue(TickExpired64(0, 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF), "the largest exact boundary is representable")
}
Test("tick64: zero, full-cycle gap and maximum duration stay exact (native-tick64)", _TD64_ZeroAndLongGap)

_TD64_Refused(Call) {
	Caught := false
	try Call.Call()
	catch as Err
		Caught := Err is ValueError
	AssertTrue(Caught, "invalid monotonic clocks and durations must fail with ValueError")
}
_TD64_InvalidTick(Value) {
	_TD64_Refused(() => TickElapsed64(Value, 100))
	_TD64_Refused(() => TickElapsed64(0, Value))
	_TD64_Refused(() => TickExpired64(Value, 1, 100))
	_TD64_Refused(() => TickRemaining64(0, 1, Value))
}
for Row in [["negative", -1], ["float", 1.0], ["string", "1"], ["array", []], ["map", Map()]]
	Test("tick64: rejects " . Row[1] . " tick values (native-tick64)", _TD64_InvalidTick.Bind(Row[2]))

_TD64_InvalidDuration(Value) {
	_TD64_Refused(() => TickExpired64(0, Value, 1))
	_TD64_Refused(() => TickRemaining64(0, Value, 1))
}
for Row in [["negative", -1], ["float", 1.0], ["string", "1"], ["array", []], ["map", Map()]]
	Test("tick64: rejects " . Row[1] . " duration values (native-tick64)", _TD64_InvalidDuration.Bind(Row[2]))

_TD64_Backwards() {
	_TD64_Refused(() => TickElapsed64(4294967280, 15))
	_TD64_Refused(() => TickExpired64(100, 0, 99))
	_TD64_Refused(() => TickRemaining64(100, 1000, 99))
}
Test("tick64: rejects backwards clock instead of inventing rollover (native-tick64)", _TD64_Backwards)

_TD64_NativeDefaults() {
	Started := A_TickCount
	Before := A_TickCount
	Elapsed := TickElapsed64(Started)
	After := A_TickCount
	AssertTrue(Elapsed >= Before - Started && Elapsed <= After - Started, "default elapsed reads the actual native clock")
	AssertTrue(TickExpired64(Started, 0), "native default clock expires a zero duration")
	Before := A_TickCount
	Remaining := TickRemaining64(0, 0x7FFFFFFFFFFFFFFF)
	After := A_TickCount
	AssertTrue(Remaining >= 0x7FFFFFFFFFFFFFFF - After && Remaining <= 0x7FFFFFFFFFFFFFFF - Before,
		"default remaining retains the full native monotonic origin")
}
Test("tick64: optional current ticks retain actual native defaults (native-tick64)", _TD64_NativeDefaults)


; The real LLM deadline owner must retain native time, independently of the
; DWORD compatibility vectors above. No transport or request lifecycle runs.
_TDLLM64_Deadline(Start, Duration, Now, Expected) {
	AssertEqual(Expected, _LLM_DeadlineExpired(Start, Duration, Now),
		"the actual LLM deadline must preserve the native monotonic interval")
}
for Row in [[100, 50, 149, false], [100, 50, 150, true],
	[100, 50, 151, true], [4294967280, 50, 4294967330, true],
	[100, 50, 4294967396, true], [100, 50, 4294967445, true],
	[100, 50, 8589934692, true], [0, 0, 0, true],
	[0, 4294967346, 4294967345, false],
	[0, 4294967346, 4294967346, true],
	[0x7FFFFFFFFFFFFFF8, 7, 0x7FFFFFFFFFFFFFFF, true]]
	Test("llm-native64: actual deadline at " . Row[3] . " for budget " . Row[2],
		_TDLLM64_Deadline.Bind(Row*))

_TDLLM64_DefaultClock() {
	Started := A_TickCount
	AssertTrue(_LLM_DeadlineExpired(Started, 0),
		"ordinary two-argument calls retain the actual native current clock")
	Before := A_TickCount
	Observed := _LLM_DeadlineExpired(0, 0x7FFFFFFFFFFFFFFF)
	After := A_TickCount
	Assert(Before <= After && After < 0x7FFFFFFFFFFFFFFF,
		"the bounded native observation must fit the maximum supported duration")
	AssertFalse(Observed, "the omitted current tick must not invent a native maximum expiry")
}
Test("llm-native64: existing arity uses the actual native current tick", _TDLLM64_DefaultClock)

_TDLLM64_Invalid(Start, Duration, Now) {
	Failure := 0
	try _LLM_DeadlineExpired(Start, Duration, Now)
	catch as Err
		Failure := Err
	AssertTrue(Failure is ValueError,
		"the actual LLM owner rejects invalid native observations with ValueError")
}
for Row in [[100, 50, 99], [-1, 50, 100], [0, -1, 100]]
	Test("llm-native64: refuses invalid native clock or budget " . Row[1] . "/" . Row[2] . "/" . Row[3],
		_TDLLM64_Invalid.Bind(Row*))
