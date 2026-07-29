; tests/meta/test_uia_clamp_every_probe_site.ahk

; ==============================================================================
; MODULE: UIA Timeout Clamp Coverage Meta Test
; DESCRIPTION:
; UIA.TransactionTimeout (2000 ms) and UIA.ConnectionTimeout (20000 ms) are
; Windows' defaults, and the driver's worst measured hot-path stall is exactly
; the first of them plus overhead:
;   2026-07-16 15:01:28:231 [WARNING] [HotPath] Slow Tooltip.ResolvePos: 2560.32 ms ().
; The bounded-wait fix that killed it was written as a private helper of the
; tooltip module and wired into ONE of the driver's UIA.GetFocusedElement call
; sites. The others are all main-thread callbacks too — a 500 ms repeating
; selection poll, a per-focus-change one-shot in the secure-field adapter, and
; the keylogger's own password classifier — and they kept Windows' defaults.
;
; The clamp writes process-wide singleton properties, so in a session where any
; one site runs, the rest inherit the bound. That is precisely why per-site
; coverage was never noticed as missing, and precisely why it is not a
; guarantee: a session in which only the unclamped site ever probes runs
; unbounded on the thread that dispatches keystrokes.
;
; FEATURES & RATIONALE:
; 1. Enumerates the CLASS. The site list is checked against the number of real
;    UIA.GetFocusedElement occurrences in the driver, so a fifth call site added
;    tomorrow fails here instead of quietly reintroducing the stall.
; 2. Pins ORDERING, not presence: a clamp applied after the round-trip it is
;    meant to bound satisfies a substring check and fixes nothing.
; 3. Spelling-independent. Three layers own three copies of the clamp (an
;    adapter must not reach into ui/, a module must not reach into an adapter
;    for a UI concern, and the headless runner loads those trees selectively),
;    so the guarantee asserted is "this function bounds the wait before making
;    it", matched on shape rather than on one canonical helper name.
; 4. The pending table can only SHRINK — see _UCP_UnclampedPending.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ The class of UIA probe sites =======
; ===============================================
; ===============================================

; Every driver function that performs the UIA.GetFocusedElement round-trip.
; Kept as a literal list rather than derived by parsing, because the completeness
; check below is what makes the list trustworthy: it compares this list against
; the real number of call sites in the driver source, so the list cannot silently
; fall behind.
_UCP_ProbeSites() {
	return ["_TooltipResolvePosition", "_UIA_SelectionPollTick",
		"SFD_ProbeFocusedUia", "KL_DetectPasswordFor"]
}

; Probe sites that do NOT bound their own wait yet, each with the reason.
;
; This table may only ever SHRINK. _UCP_EveryProbeSiteClampsFirst asserts that a
; listed site really is still unclamped, so the moment its owner adds the clamp
; this test goes red and forces the entry out — a stale exemption cannot survive
; and quietly suppress a guarantee that has since been met.
_UCP_UnclampedPending() {
	return Map(
		"KL_DetectPasswordFor",
		"modules/keylogger/keylogger_password.ahk, layer 3 of the keylogger's own password classifier. It inherits the bound in practice because the properties are process-wide and the secure-field adapter clamps on every focus change, but it does not guarantee it for a session in which no sibling probe ever runs."
	)
}

; The site list must account for every real call site. Comments are stripped
; first: four of the driver's explanatory comments name this API, and a raw
; substring count over them would inflate the total and pass by accident.
_UCP_EveryCallSiteIsEnumerated() {
	Src := _DriverSourceNoComments()
	Found := 0
	Pos := 1
	while (Pos := InStr(Src, "UIA.GetFocusedElement", , Pos)) {
		Found += 1
		Pos += 1
	}

	Assert(Found > 0,
		"UIA.GetFocusedElement must still be reachable in the driver, otherwise this whole guard is vacuous")
	Assert(Found == _UCP_ProbeSites().Length,
		"the UIA probe-site list is out of date: the driver contains " . Found . " UIA.GetFocusedElement call site(s) but _UCP_ProbeSites() names " . _UCP_ProbeSites().Length . ". Add the new site to the list AND give it a timeout clamp — an unbounded cross-process wait on the message thread that dispatches keystrokes is a measured multi-second stall, not a theoretical one")
}





; =================================================
; =================================================
; ======= 2/ Every site bounds its own wait =======
; =================================================
; =================================================

; Position of the call that bounds UIA's own waits, or 0 when the body has none.
; Matched on shape (…Clamp…Timeouts) rather than on one canonical helper name:
; the three owners live in three layers that must not depend on one another, so
; there are deliberately three identically-shaped one-shot helpers.
_UCP_ClampPos(Body) {
	return RegExMatch(Body, "i)[_A-Za-z0-9]*Clamp[_A-Za-z0-9]*Timeouts\(")
}

_UCP_EveryProbeSiteClampsFirst() {
	Pending := _UCP_UnclampedPending()
	Checked := 0
	for Name in _UCP_ProbeSites() {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		UiaPos := InStr(Body, "UIA.GetFocusedElement")
		Assert(UiaPos > 0,
			Name . " no longer performs the UIA round-trip — remove it from _UCP_ProbeSites() rather than leaving a site the guard can never check")
		Checked += 1
		ClampPos := _UCP_ClampPos(Body)
		if Pending.Has(Name) {
			Assert(ClampPos == 0,
				Name . " now bounds its own UIA waits — delete its entry from _UCP_UnclampedPending(). An exemption that outlives the gap it records silently suppresses the guarantee for every future change to this function")
			continue
		}
		Assert(ClampPos > 0,
			Name . " must bound UIA's own transaction/connection timeouts before the COM round-trip. Windows' 2000 ms default is the driver's worst measured stall (2560 ms), and this call runs on the single thread that also dispatches keystrokes")
		Assert(ClampPos < UiaPos,
			Name . " applies the timeout clamp AFTER the round-trip it is meant to bound, which fixes nothing while satisfying a naive substring check")
	}
	Assert(Checked == _UCP_ProbeSites().Length,
		"every enumerated probe site must have been checked (checked " . Checked . " of " . _UCP_ProbeSites().Length . ")")
	Assert(Pending.Count <= 1,
		"the unclamped-probe exemption list must not grow: a new UIA probe site is expected to bound its own wait, not to be added here (found " . Pending.Count . " entries)")
}


Test("meta uia-clamp: the probe-site list covers every UIA.GetFocusedElement call site",
	_UCP_EveryCallSiteIsEnumerated)
Test("meta uia-clamp: every UIA probe bounds its own wait before making it",
	_UCP_EveryProbeSiteClampsFirst)
