; tests/meta/test_uia_probe_bounded.ahk

; ==============================================================================
; MODULE: UIA Probe Bounding Meta Test
; DESCRIPTION:
; UIA.GetFocusedElement is a cross-process COM round-trip made on the single
; thread that also dispatches keystrokes. Windows' own defaults are the only
; ceiling — 2000 ms TransactionTimeout, 20000 ms ConnectionTimeout — so an
; unresponsive foreground app stalls remapping for as long as it likes.
;
; This is the driver's worst MEASURED hot-path segment, not a theory:
;   2026-07-16 15:01:28:231 [WARNING] [HotPath] Slow Tooltip.ResolvePos: 2560.32 ms ().
; 2560 ms is the 2000 ms transaction default plus overhead. Across ten days of
; logs the segment recorded 1764 slow events, 41 of them over 100 ms.
;
; A previous audit REFUTED this, arguing the ~225 ms render debounce was an
; effective idle gate. It is not: a debounce is a coalescing timer that decides
; WHEN deferred work runs, never whether a typing burst is still in flight. The
; logs settle it.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE — an unbounded cross-process wait reachable from the
;    typing path — rather than the symptom of one slow tooltip.
; 2. Enumerates the whole CLASS of UIA probe sites, per
;    project-ahk-guard-tests-must-loop-the-class, so a fourth call site added
;    without guards fails immediately instead of quietly reintroducing the stall.
; 3. Pins the ORDERING of the tooltip guards, because a gate placed after the
;    COM call would pass a naive substring check while fixing nothing.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ The timeout clamp must exist =======
; ===============================================
; ===============================================

_UPB_TimeoutsAreClamped() {
	Body := _DriverFuncBody("_TooltipClampUiaTimeouts")
	Assert(Body != "", "_TooltipClampUiaTimeouts() must exist")

	Assert(InStr(Body, "UIA.TransactionTimeout :=") > 0,
		"the clamp must set UIA.TransactionTimeout — its 2000 ms default is the measured 2560 ms stall")
	Assert(InStr(Body, "UIA.ConnectionTimeout :=") > 0,
		"the clamp must set UIA.ConnectionTimeout — its default is 20000 ms")

	; Both are IUIAutomation2 vtable slots; an older interface must not throw
	; into the caller, which sits on the keystroke-dispatch thread.
	Assert(InStr(Body, "IsIUIAutomation2Available") > 0,
		"the clamp must check IsIUIAutomation2Available before touching IUIAutomation2-only properties")

	; The bound is the whole point, so pin its magnitude, not its exact value.
	Src := _DriverSourceNoComments()
	for Name in ["UIA_TRANSACTION_TIMEOUT_MS", "UIA_CONNECTION_TIMEOUT_MS"] {
		Assert(RegExMatch(Src, "global\s+" . Name . "\s*:=\s*(\d+)", &m) > 0,
			Name . " must be declared as a global constant")
		Assert(m[1] + 0 > 0 and m[1] + 0 <= 250,
			Name . " must bound the COM wait to at most 250 ms (found " . m[1] . ") — anything larger leaves a perceptible stall on the typing thread")
	}
}





; =================================================
; =================================================
; ======= 2/ The tooltip probe is gated ===========
; =================================================
; =================================================

_UPB_TooltipProbeIsGated() {
	Body := _DriverFuncBody("_TooltipResolvePosition")
	Assert(Body != "", "_TooltipResolvePosition() must exist")

	CachePos := InStr(Body, "_TooltipPositionCache")
	IdlePos := InStr(Body, "A_TimeIdlePhysical")
	HostilePos := InStr(Body, "_TooltipUiaProcessIsHostile")
	ClampPos := InStr(Body, "_TooltipClampUiaTimeouts")
	UiaPos := InStr(Body, "UIA.GetFocusedElement")

	Assert(UiaPos > 0, "the UIA probe must still be present")
	Assert(IdlePos > 0,
		"the UIA branch must be gated on A_TimeIdlePhysical — the render debounce coalesces, it does not detect an in-flight typing burst")
	Assert(HostilePos > 0,
		"the UIA branch must consult the per-process hostile cache, or an app that times out pays the full timeout again on every cache expiry")
	Assert(ClampPos > 0,
		"the UIA branch must clamp UIA's own timeouts before probing")

	; Ordering matters more than presence: a guard after the call fixes nothing,
	; and the cache read must stay first so a cheap hit skips all of this.
	Assert(CachePos > 0 and CachePos < IdlePos,
		"the position-cache read must come before the idle gate, so a cache hit costs nothing")
	Assert(IdlePos < UiaPos,
		"the idle gate must come BEFORE UIA.GetFocusedElement, not after it")
	Assert(HostilePos < UiaPos,
		"the hostile-process check must come BEFORE UIA.GetFocusedElement")
	Assert(ClampPos < UiaPos,
		"the timeout clamp must be applied BEFORE the probe it bounds")
}

; A skipped probe must fall through to the coarse window-frame anchor WITHOUT
; caching it. Caching a mid-burst approximation would pin it for the whole
; TOOLTIP_POSITION_CACHE_MS window, so the next idle render — the one that could
; have got a precise anchor — would reuse the coarse one instead.
_UPB_SkippedProbeDoesNotPinCoarseAnchor() {
	Body := _DriverFuncBody("_TooltipResolvePosition")
	Assert(Body != "", "_TooltipResolvePosition() must exist")

	; The reason for skipping has to be a value the fallback stages can read. A
	; single UiaAllowed boolean folds "still mid-burst" together with "hostile
	; app", and those two want opposite caching decisions.
	Assert(InStr(Body, "UiaSkippedForIdle") > 0,
		"_TooltipResolvePosition must distinguish a probe deferred for idle from one skipped because the app is hostile — the fallback stages cache in the second case and must not in the first")

	; Everything from the window-frame stage onwards is a FALLBACK anchor. The
	; earlier assertion only scanned between the idle check and the UIA call, a
	; span that never contained a cache write in the first place, so it passed
	; against the very code it was meant to forbid. Anchor on WinGetPos instead:
	; it is real code (comments are stripped from the body) and it opens stage 3.
	FallbackPos := InStr(Body, "WinGetPos(")
	Assert(FallbackPos > 0, "_TooltipResolvePosition must still fall back to the active window frame")
	Tail := SubStr(Body, FallbackPos)
	Assert(InStr(Tail, "_TooltipCachePosition(") == 0,
		"the fallback stages must not write the position cache directly — a coarse anchor computed while the probe was merely deferred would be pinned for the whole cache window and suppress the probe that would have found the caret")
	Assert(InStr(Tail, "_TooltipCacheUnlessProbePending(") > 0,
		"the fallback stages must route their anchor through _TooltipCacheUnlessProbePending so a deferred probe leaves the cache untouched")

	; The converse must stay true: a native caret and a resolved UIA rect are real
	; measurements, and caching them is what the cache exists for.
	Head := SubStr(Body, 1, FallbackPos - 1)
	Assert(InStr(Head, "_TooltipCachePosition(") > 0,
		"the caret and UIA stages must keep caching unconditionally — they return a measured anchor, not a stand-in")

	Guard := _DriverFuncBody("_TooltipCacheUnlessProbePending")
	Assert(Guard != "", "_TooltipCacheUnlessProbePending() must exist in the driver source")
	Assert(InStr(Guard, "_TooltipCachePosition(") > 0,
		"_TooltipCacheUnlessProbePending must still cache when the probe was not deferred — otherwise a hostile app re-pays a UIA timeout on every cache expiry")
}





; ==================================================
; ==================================================
; ======= 3/ No UIA probe swallows its error =======
; ==================================================
; ==================================================

; Enumerated rather than asserted per-site: the recurring defect in this repo is
; the missed sibling, so the guard has to cover the class.
_UPB_ProbeSites() {
	return ["_TooltipResolvePosition", "UIASW_WorkerHandleRequest", "SFD_ProbeFocusedUia"]
}

_UPB_NoProbeSwallowsFailures() {
	Checked := 0
	for Name in _UPB_ProbeSites() {
		Body := _DriverFuncBody(Name)
		if (Body == "" or InStr(Body, "UIA.GetFocusedElement") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "catch as") > 0,
			Name . " wraps a UIA COM call in a catch-less try, discarding the reason a probe failed — a UIA-hostile app then looks identical to a healthy one with no caret (conventions 5.3)")
	}
	Assert(Checked > 0,
		"the UIA probe-site list must resolve to at least one real function, otherwise this guard is vacuous")
}


Test("meta uia: the probe's own COM timeouts are clamped to a bounded value",
	_UPB_TimeoutsAreClamped)
Test("meta uia: the tooltip probe is idle-gated, cached and clamped before the COM call",
	_UPB_TooltipProbeIsGated)
Test("meta uia: a skipped probe does not pin a coarse anchor in the position cache",
	_UPB_SkippedProbeDoesNotPinCoarseAnchor)
Test("meta uia: no UIA probe site swallows its failure silently",
	_UPB_NoProbeSwallowsFailures)
