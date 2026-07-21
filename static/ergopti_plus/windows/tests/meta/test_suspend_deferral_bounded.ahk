; tests/meta/test_suspend_deferral_bounded.ahk

; ==============================================================================
; MODULE: Deferred Suspend Bounding Meta Test
; DESCRIPTION:
; The suspend gate waits for physically held custom-combination prefix keys to
; lift before flipping, because AHK's prefix flags latch across Suspend and no
; synthetic event can clear them. The wait had no bound: _SuspendPendingPoll
; returned every 25 ms and never gave up.
;
; So a stuck key — or one the OS still reports as down after a Reload landed on
; a held modifier — deferred the suspend FOREVER. Pausing is the user's escape
; hatch from a misbehaving driver, which makes a gate that can silently swallow
; it worse than the latched prefix it exists to prevent. Widening the key list
; from 2 to 5 made that state five times easier to reach.
;
; Pressing the toggle again did not help either: with no cancel edge the press
; fell through and simply RE-ARMED the deferral, so the one control the user
; reaches for to escape a wedged gate was the one control that could not.
;
; FEATURES & RATIONALE:
; 1. Encodes both ROOT CAUSES — an unbounded wait, and a toggle that is not a
;    toggle in the pending state.
; 2. Asserts the timeout path still SUSPENDS. A bound that only logs and keeps
;    waiting would satisfy a naive "has a timeout" check while leaving the user
;    exactly as stuck.
; 3. Asserts the offending key is named: a wedged deferral that says only
;    "still waiting" withholds the one fact that would let the user fix it.
;
; SCOPE: source introspection of lib/lifecycle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ The deferral is bounded ========
; ===========================================
; ===========================================

_SDB_DeferralHasADeadline() {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "global\s+SUSPEND_DEFER_TIMEOUT_MS\s*:=\s*(\d+)", &m) > 0,
		"a named SUSPEND_DEFER_TIMEOUT_MS constant must bound the deferred suspend (conventions 5.1)")
	Assert(m[1] + 0 > 0 and m[1] + 0 <= 10000,
		"the suspend deferral bound must be a small positive number of ms (found " . m[1] . ") — the user is waiting on it")

	Body := _DriverFuncBody("_SuspendPendingPoll")
	Assert(Body != "", "_SuspendPendingPoll() must exist")
	Assert(InStr(Body, "SUSPEND_DEFER_TIMEOUT_MS") > 0,
		"_SuspendPendingPoll must compare elapsed time against the deadline — without it the poll returns every 25 ms forever and the suspend never happens")
	Assert(InStr(Body, "_SuspendPendingSince") > 0,
		"the poll needs the arming timestamp to measure elapsed time against")
}

; The timeout must actually resolve the situation. A bound that logs and keeps
; waiting leaves the user precisely as stuck as before.
_SDB_TimeoutSuspendsAnyway() {
	Body := _DriverFuncBody("_SuspendPendingPoll")
	Assert(Body != "", "_SuspendPendingPoll() must exist")

	GuardPos := InStr(Body, "if !_SuspendPrefixesAreClear()")
	Assert(GuardPos > 0, "the poll must still gate on the prefix state")

	Assert(InStr(Body, "_ReleasePhantomModifiers()") > 0,
		"on timeout the poll must first try to clear an OS-level phantom latch — the common cause after a Reload lands on a held modifier")
	Assert(InStr(Body, "LoggerError") > 0,
		"a genuinely stuck prefix key must be reported at ERROR, not swallowed (fail loudly, conventions 5.3)")
	Assert(InStr(Body, "_SuspendHeldPrefixKeys()") > 0,
		"the timeout report must name the offending key(s) — otherwise the user cannot know which key to cycle")

	; Suspend(1) must be reachable from the timeout path, not only from the
	; clean-gate path.
	SuspendPos := InStr(Body, "Suspend(1)")
	Assert(SuspendPos > GuardPos,
		"the timeout path must fall through to Suspend(1) — a latched prefix on one key is strictly better than a driver the user cannot pause")
}




; =============================================
; =============================================
; ======= 2/ The toggle can be aborted ========
; =============================================
; =============================================

_SDB_SecondPressCancelsAPendingSuspend() {
	Body := _DriverFuncBody("ToggleSuspend")
	Assert(Body != "", "ToggleSuspend() must exist")

	CancelPos := InStr(Body, "_SuspendPending")
	Assert(CancelPos > 0, "ToggleSuspend must consult the pending state")

	; The cancel edge must be tested BEFORE the re-arm at the bottom, or the
	; press falls through and re-arms exactly as it used to.
	Assert(RegExMatch(Body, "if\s*\(!A_IsSuspended\s+and\s+_SuspendPending\)") > 0,
		"ToggleSuspend must treat a press while a suspend is PENDING as a cancel — without this edge the press re-arms the deferral, so the control the user reaches for to escape a wedged gate is the one control that cannot")

	ArmPos := InStr(Body, "_SuspendPending := true")
	Assert(ArmPos > 0, "prerequisite: the deferral is still armed at the bottom")
	CancelBranch := InStr(Body, "if (!A_IsSuspended and _SuspendPending)")
	Assert(CancelBranch < ArmPos,
		"the cancel edge must be evaluated before the re-arm, otherwise it is unreachable")

	Assert(InStr(Body, "Pending suspend cancelled") > 0,
		"the cancellation must be logged — a state change the user requested should be visible in the log")
}


Test("meta suspend: the deferred suspend has a named, enforced deadline",
	_SDB_DeferralHasADeadline)
Test("meta suspend: the deadline suspends anyway and names the stuck key",
	_SDB_TimeoutSuspendsAnyway)
Test("meta suspend: a second toggle cancels a pending suspend",
	_SDB_SecondPressCancelsAPendingSuspend)
