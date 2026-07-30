; tests/meta/test_tooltip_present_subsegmented.ahk

; ==============================================================================
; MODULE: Tooltip.Present Sub-segmentation Meta Test
; DESCRIPTION:
; Since the UIA bounded-wait fix, Tooltip.Present is the driver's dominant
; hot-path offender — 102 of 194 slow lines on the first day after that fix,
; ~12.9 ms mean, min 6.14 ms — and every proposal aimed at it was speculation,
; because the segment aggregates six steps and attributes none of them.
;
; The reason attribution was missing is structural, not an oversight: the
; profiler only prints a segment once it exceeds _HOTPATH_SLOW_MS (5 ms), and
; every sub-step of Present measures between 0.02 ms and 4.4 ms. Giving each one
; its own HotPath_LogIfSlow would therefore have produced exactly nothing. The
; sub-steps instead accumulate into a buffer that the PARENT renders into its
; own, already-gated line.
;
; ROOT CAUSE ENCODED: a composite segment whose parts are individually below the
; reporting floor is unmeasurable, and an unmeasurable segment gets optimised by
; guesswork. Two failure modes make it silently unmeasurable again:
;   1. a step added to the sequence without its own mark, so its cost is folded
;      into a neighbour and the breakdown lies rather than being absent;
;   2. a presenting call site that never drains the buffer, which both loses the
;      attribution and leaks stale marks into whichever segment prints next.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Every step is attributed =======
; ===========================================
; ===========================================

; Positions of every step _TooltipPresentStack performs, derived from the body
; rather than named here: a step is a call to one of the module's own helpers.
; Derivation is the point — a sixth helper spliced into the sequence joins this
; list automatically and must earn its own mark, instead of silently inflating
; whichever neighbouring mark happens to bracket it.
; @param Body {String} _TooltipPresentStack's body.
; @returns {Array} 1-based positions within Body, in call order.
_TPS_StepPositions(Body) {
	Positions := []
	; Skip the definition line, whose own name would otherwise count as a step.
	Pos := InStr(Body, "{")
	while (Pos := RegExMatch(Body, "_Tooltip[_A-Za-z0-9]*\(", , Pos + 1)) {
		Positions.Push(Pos)
	}
	return Positions
}

_TPS_EveryStepCarriesItsOwnMark() {
	Body := _DriverFuncBody("_TooltipPresentStack")
	Assert(Body != "", "_TooltipPresentStack() must exist in the driver source")

	BeginPos := InStr(Body, "HotPath_BreakdownBegin(")
	Assert(BeginPos > 0,
		"_TooltipPresentStack must clear the sub-step accumulator before it starts. Without the reset, marks left by an earlier render — or by the destack rebuild, which presents through the same function — are attributed to this one")

	Steps := _TPS_StepPositions(Body)
	Assert(Steps.Length >= 4,
		"_TooltipPresentStack must still perform its rendering steps (found " . Steps.Length . ") — a derivation that finds none would make this guard vacuous")

	Assert(BeginPos < Steps[1],
		"the accumulator reset must come before the first step, or that step's cost is measured into whatever the previous render left behind")

	; A mark must separate each pair of consecutive steps, and one must follow the
	; last: two steps sharing an interval means one of them is billed to the other.
	Marks := []
	Pos := 1
	while (Pos := InStr(Body, "HotPath_BreakdownMark(", , Pos)) {
		Marks.Push(Pos)
		Pos += 1
	}
	Assert(Marks.Length >= Steps.Length,
		"every step of _TooltipPresentStack must close its own sub-segment: found " . Steps.Length . " step(s) but only " . Marks.Length . " mark(s). An unmarked step is folded into a neighbour, which is worse than no breakdown at all because the number then looks precise and is wrong")

	for Idx, StepPos in Steps {
		Boundary := (Idx < Steps.Length) ? Steps[Idx + 1] : StrLen(Body)
		Separated := false
		for , MarkPos in Marks {
			if (MarkPos > StepPos and MarkPos <= Boundary) {
				Separated := true
				break
			}
		}
		Assert(Separated,
			"step " . Idx . " of _TooltipPresentStack is not followed by its own HotPath_BreakdownMark before the next step. Tooltip.Present aggregates six sub-steps that are each below the profiler's 5 ms reporting floor, so an unattributed step is invisible on its own and silently inflates its neighbour")
	}
}





; ====================================================
; ====================================================
; ======= 2/ Every presenter drains the buffer =======
; ====================================================
; ====================================================

; Every driver function that presents a tooltip stack. Verified complete by the
; call-site count below, so a fourth presenter cannot join without being noticed.
_TPS_Presenters() {
	return ["_TooltipShowNow", "_TooltipDequeueRebuild", "_TooltipBuildGuiLlm"]
}

_TPS_EveryPresenterIsMeasuredAndDrains() {
	Src := _DriverSourceNoComments()
	Calls := 0
	Pos := 1
	while (Pos := InStr(Src, "_TooltipPresentStack(", , Pos)) {
		Calls += 1
		Pos += 1
	}
	; One occurrence is the definition itself; the rest are the call sites.
	Assert(Calls - 1 == _TPS_Presenters().Length,
		"the presenter list is out of date: the driver has " . (Calls - 1) . " _TooltipPresentStack call site(s) but _TPS_Presenters() names " . _TPS_Presenters().Length . ". A presenting path with no segment renders exactly the same pixels at exactly the same cost and reports nothing")

	for Name in _TPS_Presenters() {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Assert(InStr(Body, "_TooltipPresentStack(") > 0,
			Name . " no longer presents a stack — remove it from _TPS_Presenters() rather than leaving an entry the guard cannot check")
		Assert(InStr(Body, "HotPath_LogIfSlow(") > 0,
			Name . " must wrap its present in a HotPath segment, or the dominant slow segment in the driver has a path that never reports")
		Assert(InStr(Body, "HotPath_BreakdownDetail()") > 0,
			Name . " must drain the sub-step accumulator into its own log line. A presenter that never drains loses the attribution AND leaves stale marks in the buffer, which the next segment to print would then report as its own")
	}
}


Test("meta tooltip-present: every sub-step of the present sequence carries its own mark",
	_TPS_EveryStepCarriesItsOwnMark)
Test("meta tooltip-present: every presenting path is profiled and drains its sub-step attribution",
	_TPS_EveryPresenterIsMeasuredAndDrains)
