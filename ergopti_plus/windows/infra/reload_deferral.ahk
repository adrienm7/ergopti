; infra/reload_deferral.ahk

; ==============================================================================
; MODULE: Reload Deferral
; DESCRIPTION:
; A reload asked while a configuration write is in progress waits for that
; write to end instead of failing.
;
; FEATURES & RATIONALE:
; 1. The reload needs the configuration lease, and so does every write. A
;    hotkey or a tray click runs as a new thread that interrupts the writer:
;    the writer cannot finish, and so cannot release its lease, until that
;    thread returns. Waiting inside the request can therefore never succeed;
;    the request arms a one-shot timer and returns, the writer resumes, and
;    the timer asks again.
; 2. Seen on 2026-10-01: the start-up write of config.toml took 2 360 ms on a
;    loaded machine, the reload shortcut was pressed during it, and the reload
;    was refused with an error window (reload-during-config-write).
; 3. One reload is queued at a time: a second request joins it. The wait is
;    bounded, so a lease that is never released still ends in the refusal and
;    its report.
; ==============================================================================

#Requires AutoHotkey v2.0

; Delay between two attempts and how many are made: ten seconds in all, four
; times the slowest configuration write measured.
global RELOAD_DEFERRAL_RETRY_MS := 100
global RELOAD_DEFERRAL_MAX_ATTEMPTS := 100

; The queue's state. "armed": a retry is scheduled. "attempts": retries made
; since the last reload that got its lease. Owned here and reached through
; this accessor only, so it exists whatever the include order.
_ReloadDeferralState() {
	static State := Map("armed", false, "attempts", 0)
	return State
}

; Queues RetryFn behind the configuration write in progress.
; @param RetryFn {Func} Asks for the reload again; called with no argument.
; @param ArmFn {Func} Test seam for the one-shot timer, TimerArmOneShotMs by default.
; @returns {Boolean} true when the reload is queued (or joins the queued one),
;          false once the wait is exhausted: the caller then refuses.
ReloadDeferralQueue(RetryFn, ArmFn := 0) {
	global RELOAD_DEFERRAL_RETRY_MS, RELOAD_DEFERRAL_MAX_ATTEMPTS
	State := _ReloadDeferralState()
	if !HasMethod(RetryFn, "Call")
		throw TypeError("A deferred reload needs a callable retry.")
	First := false
	PreviousCritical := Critical("On")
	try {
		if State["armed"]
			return true
		if (State["attempts"] >= RELOAD_DEFERRAL_MAX_ATTEMPTS) {
			State["attempts"] := 0
			return false
		}
		State["attempts"] += 1
		State["armed"] := true
		First := State["attempts"] == 1
	} finally Critical(PreviousCritical)
	if First
		try LoggerInfo("Lifecycle", "Reload deferred: a configuration write is in progress; it runs when that write ends.")
	Arm := HasMethod(ArmFn, "Call") ? ArmFn : TimerArmOneShotMs
	try Arm.Call(_ReloadDeferralFire.Bind(RetryFn), RELOAD_DEFERRAL_RETRY_MS)
	catch as Err {
		; No timer, no retry: the request must not be reported as queued.
		State["armed"] := false
		State["attempts"] := 0
		try LoggerError("Lifecycle", "The deferred reload could not be scheduled: {1}.", Err.Message)
		return false
	}
	return true
}

; The one-shot timer's callback: the queue is free again before the retry asks.
_ReloadDeferralFire(RetryFn, *) {
	_ReloadDeferralState()["armed"] := false
	RetryFn.Call()
}

; A reload that got its lease ends the wait: the next busy lease starts a new one.
ReloadDeferralSettle() {
	_ReloadDeferralState()["attempts"] := 0
}
