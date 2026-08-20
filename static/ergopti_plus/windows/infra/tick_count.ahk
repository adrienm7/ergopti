; infra/tick_count.ahk

; ==============================================================================
; MODULE: Wrap-Safe Monotonic Tick Arithmetic
; DESCRIPTION:
; Canonical elapsed-time operations for A_TickCount's unsigned 32-bit rollover.
; Store an origin tick plus a duration; never store or compare an absolute
; ``A_TickCount + duration`` deadline.
; ==============================================================================

#Requires AutoHotkey v2.0+

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
