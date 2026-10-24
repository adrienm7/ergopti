; modules/keystats/keystats_collection.ahk

; ==============================================================================
; MODULE: Keystats Collection Pause And Session Reset
; DESCRIPTION:
; The user's two session controls from the Metrics menu, with the semantics every
; driver shares (docs/design/metrics-suspend-and-reset-session.md and
; _shared/tests/corpus/metrics/collection_session_vectors.json):
;
; 1. PAUSE. A state of its own, held apart from the driver pause (A_IsSuspended)
;    and from the privacy filters (secure field, private window, excluded app).
;    No focus change or filter toggle ends it, and ending it clears none of
;    them. It is never persisted, so every start records as the settings say.
; 2. SESSION RESET. Ends the current typing session as the idle timeout would,
;    after the pending text is stored, then restarts the live typing-speed
;    figures from zero. Nothing stored is deleted.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ==============================
; ======= 1/ Pause state =======
; ==============================
; ==============================

class KLCollection {
	; True while the user's pause is active. One boolean read per captured event.
	static suspended := false

	; Rows that close an interval accepted before the pause. Refusing them would
	; leave a session_start with no session_end, which poisons every active-time
	; aggregate downstream; the driver pause exempts the same lifecycle markers.
	static CLOSING_TYPES := Map("system_event", true, "session_end", true, "idle_end", true)

	; Whether the pause refuses a row of this type. Called only while paused.
	static Rejects(EntryType) {
		return !KLCollection.CLOSING_TYPES.Has(EntryType)
	}
}

; Reports whether the user paused metrics collection.
KL_IsCollectionSuspended() {
	return KLCollection.suspended
}

; Whether the capture sources must stay silent: the driver pause or the user's
; pause. The sources bypass native Suspend, so each checks this itself.
KL_CaptureHeld() {
	return (A_IsSuspended || KLCollection.suspended) ? true : false
}

; Pauses metrics collection. Idempotent. Text already typed is stored first, so
; the boundary never splits or discards it.
; @param FlushFn {Func} Test seam replacing KL_FlushBuffer.
; @return {Boolean} True once paused.
KL_SuspendCollection(FlushFn := 0) {
	if KLCollection.suspended
		return true
	if Keystats.initialized {
		try {
			if HasMethod(FlushFn, "Call")
				FlushFn.Call()
			else
				KL_FlushBuffer()
		} catch as Err {
			try LoggerWarn("Keystats", "Pending text could not be stored before the pause: {1}.", Err.Message)
		}
	}
	PreviousCritical := Critical("On")
	try KLCollection.suspended := true
	finally Critical(PreviousCritical)
	try LoggerInfo("Keystats", "Metrics collection suspended by the user.")
	return true
}

; Ends the user's pause. Nothing typed meanwhile is recovered. Idempotent.
; @return {Boolean} True once recording again.
KL_ResumeCollection() {
	if !KLCollection.suspended
		return true
	PreviousCritical := Critical("On")
	try KLCollection.suspended := false
	finally Critical(PreviousCritical)
	try LoggerInfo("Keystats", "Metrics collection resumed by the user.")
	return true
}





; ================================
; ================================
; ======= 2/ Session reset =======
; ================================
; ================================

; Ends the current typing session and restarts the live figures from zero.
; Works while paused; it changes neither the pause nor any privacy filter.
; @param FlushFn {Func} Test seam replacing KL_FlushBuffer.
; @param CloseFn {Func} Test seam replacing the session closer; receives the
;        tick of the last keystroke and the current tick.
; @param WpmFn {Func} Test seam replacing the typing-speed reset.
; @return {Boolean} False when nothing is running to end, or the session close
;         was refused (the idle tick retries it).
KL_ResetSession(FlushFn := 0, CloseFn := 0, WpmFn := 0) {
	if !Keystats.initialized {
		try LoggerWarn("Keystats", "Session reset ignored: metrics are not running.")
		return false
	}
	try LoggerStart("Keystats", "Resetting the metrics session...")
	try {
		if HasMethod(FlushFn, "Call")
			FlushFn.Call()
		else
			KL_FlushBuffer()
	} catch as Err {
		try LoggerError("Keystats", "Session reset refused: pending text could not be stored: {1}.", Err.Message)
		return false
	}
	if KLWatch.is_session_active {
		LastTick := KLHook.last_tick
		Closed := HasMethod(CloseFn, "Call")
			? CloseFn.Call(LastTick, A_TickCount)
			: _KL_Watchers_CloseSession(LastTick, A_TickCount)
		if !Closed {
			try LoggerError("Keystats", "Session reset refused: the session close was not accepted.")
			return false
		}
	}
	if HasMethod(WpmFn, "Call")
		WpmFn.Call()
	else if IsSet(_WPMWidget_ResetRolling)
		_WPMWidget_ResetRolling()
	try LoggerDone("Keystats", "Metrics session reset.")
	return true
}
