; lib/layout_poll_helper.ahk

; ==============================================================================
; MODULE: Layout Poll Helper
; DESCRIPTION:
; Pure decision helper for the foreground keyboard-layout poll. The 1 s timer in
; ErgoptiPlus.ahk used to Reload() the moment the HKL differed, which discarded
; any in-flight typing on a transient flicker (layout-poll-blind-reload).
;
; _ShouldReloadForHkl isolates the "should we reload now?" logic so it is exercised
; headlessly by tests/meta/test_layout_quiescence.ahk. It has no OS dependency and
; never reloads — it only reports the decision and advances the caller's tracking
; refs. Reloading is deferred until the new layout is stable across two consecutive
; polls AND the user is physically idle AND no expansion is in flight, turning a
; transient flicker into a no-op while still adapting to a genuine layout switch.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Reload quiescence decision ===========
; =================================================
; =================================================

; Returns true only when a genuine, sustained layout switch warrants a Reload().
; @param curHkl        Current foreground HKL (0 when unknown).
; @param lastHkl       ByRef tracker of the last layout we reloaded for; advanced on a true result.
; @param pendingHkl    ByRef debounce tracker; holds the candidate HKL awaiting a second confirming poll.
; @param suspended     True when the driver is paused (A_IsSuspended) — must never reload.
; @param isBlacklisted True when the foreground app is blacklisted (game / private) — must never reload.
; @param hseSuppressed Hotstring-engine suppression depth (>0 means an expansion is in flight).
; @param pwSuppressed  Prefix-watcher suppression depth (>0 means an expansion is in flight).
; @param idleMs        Physical idle time in ms (A_TimeIdlePhysical) — must clear the typing threshold.
; @returns True if the caller should Reload() now, false otherwise.
_ShouldReloadForHkl(curHkl, &lastHkl, &pendingHkl, suspended, isBlacklisted, hseSuppressed, pwSuppressed, idleMs) {
	; A paused driver or a blacklisted app must never auto-reload.
	if suspended
		return false
	if isBlacklisted
		return false
	; No change (or unknown layout) — clear any pending candidate and bail.
	if (curHkl == 0 || curHkl == lastHkl) {
		pendingHkl := 0
		return false
	}
	; First sighting of a changed layout — record it and wait for a confirming poll.
	if (pendingHkl != curHkl) {
		pendingHkl := curHkl
		return false
	}
	; Confirmed across two polls — require full quiescence before disrupting typing.
	if (idleMs < 400)
		return false
	if (hseSuppressed > 0)
		return false
	if (pwSuppressed > 0)
		return false
	lastHkl := curHkl
	return true
}
