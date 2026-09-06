; tests/meta/test_shutdown_veto_bounded.ahk

; ==============================================================================
; MODULE: Bounded Shutdown Veto (lifecycle-shutdown-veto-unbounded)
; DESCRIPTION:
; Ergopti_OnShutdown is an OnExit handler: returning 1 vetoes the exit. It holds
; nineteen independent gates -- held mouse buttons, native keyboard receipts,
; config transactions, durable saves, worker trees -- and every one of them used
; to veto by returning a bare 1 with no attempt bound.
;
; That is correct exactly once. A gate that can never be satisfied turns "quit"
; into a process the user cannot close. On 2026-09-05 a wedged LLM profile
; receipt did precisely that: six consecutive exit attempts between 23:05:42 and
; 23:06:23 were all refused with "native keyboard receipts or holds remain
; owned", and only killing the process ended the driver.
;
; ROOT CAUSE ENCODED: the veto needs a ceiling, and the ceiling has to cover the
; WHOLE class -- the recurring defect in this repository is the one sibling site
; that kept the old behaviour, and nineteen sites are eighteen chances to miss
; one. So this guard does not check the gate that failed in the field; it checks
; that NO gate can return a bare 1, and that the shared refusal actually has an
; escape rather than a counter nobody reads.
;
; infra/lifecycle.ahk registers top-level OnExit/tray handlers and is not
; included by run_all.ahk, so the invariant is asserted against driver source.
; ==============================================================================

#Requires AutoHotkey v2.0

_SVB_CountOccurrences(Haystack, Needle) {
	Count := 0
	Offset := 1
	loop {
		Found := InStr(Haystack, Needle, , Offset)
		if !Found
			break
		Count += 1
		Offset := Found + StrLen(Needle)
	}
	return Count
}





; ============================================================
; ============================================================
; ======= 1/ No gate may veto the exit unbounded =============
; ============================================================
; ============================================================

_SVB_EveryVetoRoutesThroughTheBudget() {
	Body := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(Body != "",
		"Ergopti_OnShutdown must be readable -- a renamed handler would make every "
		. "assertion here pass vacuously (lifecycle-shutdown-veto-unbounded)")
	Stripped := _StripFullLineComments(Body)

	Routed := _SVB_CountOccurrences(Stripped, "_LifecycleRefuseShutdown(")
	Assert(Routed >= 15,
		"the shutdown handler must still hold its full set of gates; found only "
		. Routed . " routed veto(es), which means the class was not enumerated "
		. "(lifecycle-shutdown-veto-unbounded)")

	Bare := _SVB_CountOccurrences(Stripped, "return 1")
	AssertEqual(0, Bare,
		"a bare `return 1` vetoes the exit forever: it is an OnExit refusal with no "
		. "attempt counter, so a gate that can never be satisfied leaves the user "
		. "with a driver they cannot close. Every veto must go through "
		. "_LifecycleRefuseShutdown (lifecycle-shutdown-veto-unbounded)")
}

Test("lifecycle: every shutdown veto routes through the bounded refusal (lifecycle-shutdown-veto-unbounded)",
	_SVB_EveryVetoRoutesThroughTheBudget)





; ============================================================
; ============================================================
; ======= 2/ The budget is a ceiling, not a counter ==========
; ============================================================
; ============================================================

; A budget that only ever returns 1 is decoration. The refusal must have a path
; that lets the exit proceed, and it must be governed by the declared constant
; rather than an inline number nobody can find.
_SVB_TheRefusalHasARealEscape() {
	Body := _DriverFuncBody("_LifecycleRefuseShutdown")
	Assert(Body != "",
		"_LifecycleRefuseShutdown must exist -- without it the guard above is "
		. "asserting about a function that never runs")
	Stripped := _StripFullLineComments(Body)

	AssertContains(Stripped, "LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS",
		"the ceiling must come from the declared constant, so it is greppable and "
		. "cannot drift into an inline literal")
	AssertContains(Stripped, "_LifecycleShutdownVetoAttempts += 1",
		"each refused exit must be counted, or the ceiling is never reached")
	AssertContains(Stripped, "return 1",
		"the refusal must still be able to veto while budget remains")
	AssertContains(Stripped, "return 0",
		"the refusal MUST have a path that lets the exit proceed -- a counter with "
		. "no escape is exactly the unbounded veto this fix removes "
		. "(lifecycle-shutdown-veto-unbounded)")

	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable")
	AssertContains(Src, "global LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS :=",
		"the ceiling must be declared as a global with the other lifecycle budgets")
	AssertContains(Src, "global _LifecycleShutdownVetoAttempts := 0",
		"the attempt counter must start at zero for each driver process")
}

Test("lifecycle: the shutdown refusal has a real escape (lifecycle-shutdown-veto-unbounded)",
	_SVB_TheRefusalHasARealEscape)





; =============================================================
; =============================================================
; ======= 3/ A forced exit still releases OS-held input =======
; =============================================================
; =============================================================

; Exiting past the gates is a deliberate trade, but a latched modifier or mouse
; button outlives the driver and breaks the user's whole session -- that harm is
; worse than the one this fix prevents. The forced path must therefore re-attempt
; every OS-level release, even though the gate that owns it already failed.
_SVB_ForcedExitReleasesHeldInput() {
	Refusal := _DriverFuncBody("_LifecycleRefuseShutdown")
	Assert(Refusal != "", "_LifecycleRefuseShutdown must exist")
	AssertContains(_StripFullLineComments(Refusal),
		"_LifecycleForceReleaseHeldInput()",
		"the exhausted budget must release OS-held input before letting the exit "
		. "proceed (lifecycle-shutdown-veto-unbounded)")

	Release := _DriverFuncBody("_LifecycleForceReleaseHeldInput")
	Assert(Release != "", "_LifecycleForceReleaseHeldInput must exist")
	Stripped := _StripFullLineComments(Release)
	; The whole class of OS state this process can still own on the way out.
	Owners := ["GestureReleaseLeftClick", "GestureReleaseRightClick",
		"TapHoldReleaseSyntheticKeys"]
	Checked := 0
	for Owner in Owners {
		AssertContains(Stripped, Owner,
			"the forced release must re-attempt " . Owner
			. " -- anything it still holds outlives the process")
		Checked += 1
	}
	AssertEqual(Owners.Length, Checked,
		"every OS-level hold owner must have been inspected")
}

Test("lifecycle: a forced exit still releases OS-held input (lifecycle-shutdown-veto-unbounded)",
	_SVB_ForcedExitReleasesHeldInput)
