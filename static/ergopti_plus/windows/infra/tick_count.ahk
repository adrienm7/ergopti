; infra/tick_count.ahk

; ==============================================================================
; MODULE: Explicit Monotonic Tick Domains
; DESCRIPTION:
; AutoHotkey v2 A_TickCount uses GetTickCount64. TickElapsed64 and its deadline
; helpers preserve that native monotonic domain. The original TickElapsed,
; TickExpired and TickRemaining retain modulo32 compatibility for DWORD origins.
; Store an origin plus a duration and select the helper for the origin domain.
; ==============================================================================

#Requires AutoHotkey v2.0+

; Existing configuration policy: durations remain within the legacy DWORD cap.
global TICK_MAX_DURATION_MS := 0xFFFFFFFF

/**
 * Converts seconds into the existing UInt32 millisecond configuration policy.
 * This cap remains compatible with legacy DWORD consumers; it is not the width
 * of the native A_TickCount clock or of the explicit 64-bit helpers below.
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

/**
 * Elapsed milliseconds between nonnegative monotonic Integer ticks.
 * A_TickCount uses GetTickCount64 on the supported AutoHotkey v2 runtime.
 * @param {Integer} StartTick - Untruncated origin in the native clock domain.
 * @param {Integer} NowTick - Optional current tick; defaults to A_TickCount.
 * @returns {Integer} Full elapsed duration without UInt32 truncation.
 * @throws {ValueError} On invalid ticks or a backwards clock observation.
 */
TickElapsed64(StartTick, NowTick?) {
	if !IsSet(NowTick)
		NowTick := A_TickCount
	if !(StartTick is Integer) || StartTick < 0
			|| !(NowTick is Integer) || NowTick < StartTick
		throw ValueError("Monotonic ticks must be nonnegative Integers with current tick at or after origin.")
	return NowTick - StartTick
}

/**
 * Inclusive expiry for the native monotonic tick domain.
 * @param {Integer} StartTick - Untruncated monotonic origin.
 * @param {Integer} DurationMs - Nonnegative duration, without a UInt32 cap.
 * @param {Integer} NowTick - Optional current tick; defaults to A_TickCount.
 * @returns {Boolean} True at or after the exact duration boundary.
 * @throws {ValueError} On invalid ticks, duration or backwards observation.
 */
TickExpired64(StartTick, DurationMs, NowTick?) {
	if !(DurationMs is Integer) || DurationMs < 0
		throw ValueError("Monotonic duration must be a nonnegative Integer.")
	return TickElapsed64(StartTick, NowTick?) >= DurationMs
}

/**
 * Remaining milliseconds for the native monotonic tick domain.
 * @param {Integer} StartTick - Untruncated monotonic origin.
 * @param {Integer} DurationMs - Nonnegative duration, without a UInt32 cap.
 * @param {Integer} NowTick - Optional current tick; defaults to A_TickCount.
 * @returns {Integer} Nonnegative remainder, clamped to zero after expiry.
 * @throws {ValueError} On invalid ticks, duration or backwards observation.
 */
TickRemaining64(StartTick, DurationMs, NowTick?) {
	if !(DurationMs is Integer) || DurationMs < 0
		throw ValueError("Monotonic duration must be a nonnegative Integer.")
	return Max(0, DurationMs - TickElapsed64(StartTick, NowTick?))
}
