; infra/tick_count.ahk

; ==============================================================================
; MODULE: Wrap-Safe Monotonic Tick Arithmetic
; DESCRIPTION:
; Canonical elapsed-time operations for A_TickCount's unsigned 32-bit rollover.
; Store an origin tick plus a duration; never store or compare an absolute
; ``A_TickCount + duration`` deadline.
; ==============================================================================

#Requires AutoHotkey v2.0+

global TICK_MAX_DURATION_MS := 0xFFFFFFFF

/**
 * Converts seconds into the exact millisecond domain represented by
 * TickElapsed. Values outside that unsigned 32-bit domain cannot be compared
 * correctly after A_TickCount wraps and are rejected before multiplication.
 */
TickTryDurationMsFromSeconds(Seconds, &DurationMs) {
	global TICK_MAX_DURATION_MS
	DurationMs := 0
	if !(Seconds is Integer || Seconds is Float) || Seconds < 0
			|| Seconds > TICK_MAX_DURATION_MS / 1000
		return false
	Candidate := Round(Seconds * 1000)
	if (Candidate < 0 || Candidate > TICK_MAX_DURATION_MS)
		return false
	DurationMs := Candidate
	return true
}

TickElapsed(StartTick, NowTick?) {
	if !IsSet(NowTick)
		NowTick := A_TickCount
	return (NowTick - StartTick) & 0xFFFFFFFF
}

TickExpired(StartTick, DurationMs, NowTick?) {
	if !IsSet(NowTick)
		NowTick := A_TickCount
	return TickElapsed(StartTick, NowTick) >= DurationMs
}

TickRemaining(StartTick, DurationMs, NowTick?) {
	if !IsSet(NowTick)
		NowTick := A_TickCount
	return Max(0, DurationMs - TickElapsed(StartTick, NowTick))
}
