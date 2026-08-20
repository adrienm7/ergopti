; tests/meta/test_suspend_lifecycle_logged.ahk

; ==============================================================================
; MODULE: Suspend/Resume Lifecycle Logging Meta Test
; DESCRIPTION:
; "Pause = tout éteint" is the invariant the whole suspend teardown exists to
; uphold: native Suspend disarms hotkeys only, so InputHooks, SetTimer callbacks
; and OnMessage handlers all keep running unless the reactors stop them by hand.
;
; Those reactors emitted nothing whatsoever. A feature still running while paused
; and a feature correctly stopped produced identical output — none — so the
; invariant was unfalsifiable from a log, and every pause defect had to be
; reproduced live rather than read off an artifact. Ten days of real logs contain
; not one line marking a suspend transition.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE: the transition must be BRACKETED, so that a START
;    with no matching SUCCESS marks a teardown that died halfway — which is the
;    exact failure the reactors are most likely to suffer, since each step is
;    individually try-wrapped and a throw would otherwise be invisible.
; 2. Pins ORDER, not just presence: a SUCCESS emitted before the teardown work
;    would satisfy a substring check while asserting something untrue.
;
; SCOPE: source introspection of infra/lifecycle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Both transitions are bracketed ====
; ==============================================
; ==============================================

; Both reactors must open and close a lifecycle pair around their teardown or
; restart work — checked as a class so neither half can be left uninstrumented.
_SLL_ReactorsAreBracketed() {
	for Name in ["Ergopti_OnSuspendEnter", "Ergopti_OnSuspendResume"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in infra/lifecycle.ahk")

		StartPos := InStr(Body, "LoggerStart(")
		SuccessPos := InStr(Body, "LoggerSuccess(")

		Assert(StartPos > 0,
			Name . " must open a lifecycle pair — without it a teardown that dies halfway is indistinguishable from one that never ran, and every step here is individually try-wrapped so a throw is otherwise silent")
		Assert(SuccessPos > 0,
			Name . " must close its lifecycle pair, or it permanently reports a silent failure (conventions 4.2)")
		Assert(StartPos < SuccessPos,
			Name . ": the START must precede the SUCCESS — a SUCCESS emitted first would satisfy a substring check while asserting the transition completed before it began")
	}
}

; The closing line must come after the actual work, not merely exist somewhere.
_SLL_SuccessFollowsTheTeardown() {
	Enter := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Enter != "", "Ergopti_OnSuspendEnter() must exist")

	; TooltipHide is one of the first teardown steps; the LLM deps timer is the
	; last. The closing line must sit beyond both.
	LastWorkPos := InStr(Enter, "_LLM_Deps_PollTimer")
	SuccessPos := InStr(Enter, "LoggerSuccess(")
	Assert(LastWorkPos > 0, "prerequisite: the LLM deps poll timer is still stopped on suspend")
	Assert(SuccessPos > LastWorkPos,
		"the suspend SUCCESS must be emitted after the teardown completes, otherwise it vouches for work that has not happened yet")
}


Test("meta suspend: both suspend reactors bracket their work with a lifecycle pair",
	_SLL_ReactorsAreBracketed)
Test("meta suspend: the closing line follows the teardown it reports",
	_SLL_SuccessFollowsTheTeardown)
