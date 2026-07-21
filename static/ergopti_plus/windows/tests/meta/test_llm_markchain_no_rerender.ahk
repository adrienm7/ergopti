; tests/meta/test_llm_markchain_no_rerender.ahk

; ==============================================================================
; MODULE: LLM Chain-Timing Single-Render Meta Test
; DESCRIPTION:
; Regression guard for the double tooltip render found by the 2026-07-21
; performance audit. Marking an LLM prediction chain complete used to re-render
; the whole tooltip so the info bar could pick up the TTLT it had just frozen.
; AHK has no partial-update path -- _TooltipBuildGuiLlm tears both windows down,
; re-measures every row, repaints the border DIB and pushes a layered-window
; update -- so the most visible moment of the LLM flow paid two full rebuilds
; back to back, and the pointer-dismissal path paid one that was painted and
; thrown away in the same breath.
;
; The fix freezes the timings WITHOUT painting and moves the call to just BEFORE
; the final render, which reads TtftMs / TtltMs synchronously while building the
; info bar.
;
; WHY THIS TEST IS SOURCE-SCANNING AND NOT BEHAVIOURAL:
; Every production call site is wrapped in `try`, and in AHK v2 a call to a
; function that does not exist is NOT a load-time error -- the name resolves as a
; variable, and the resulting failure is swallowed by that `try`. A rename that
; missed the wrapper layer would therefore produce a completely silent
; regression: no TTLT in the info bar, no error, no log line. The stub harness
; cannot see it either (tests/test_stubs.ahk stubs the Show wrapper, and
; ui/tooltip/init.ahk does not include tooltip_llm.ahk at all), so a behavioural
; test here would assert nothing.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================================
; ========================================================
; ======= 1/ Freezing the timings must not repaint =======
; ========================================================
; ========================================================

_LMNR_TimingOnlyDoesNotRender() {
	Body := _DriverFuncBody("LLM_TooltipMarkChainTimingOnly")
	Assert(Body != "", "LLM_TooltipMarkChainTimingOnly() must exist in the driver source")

	Assert(InStr(Body, "LLM_TooltipShow(") == 0,
		"LLM_TooltipMarkChainTimingOnly must not repaint -- a full rebuild whose only purpose is to print a duration doubles the cost of the moment the user is actually looking at")
	Assert(InStr(Body, "TtltMs") > 0 and InStr(Body, "TtftMs") > 0,
		"LLM_TooltipMarkChainTimingOnly must still freeze both chain timings")
}
Test("LLM tooltip: freezing the chain timings does not repaint the surface (llm-markchain-double-render)",
	_LMNR_TimingOnlyDoesNotRender)





; =========================================================
; =========================================================
; ======= 2/ TTFT must not overtake the frozen TTLT =======
; =========================================================
; =========================================================

; On the batch path every intermediate render is a placeholder, so LLM_TooltipShow
; bails into its loading branch before it ever refreshes the chain: FirstShowTick
; is still 0 when the timings are frozen. Because the freeze now happens BEFORE
; the final render, that render would take the first-show branch in
; LLM_TooltipRefreshChainTiming and overwrite TtftMs with a LATER value -- an info
; bar printing a time-to-first-token greater than its time-to-last-token.
; Claiming the first-show slot during the freeze is what prevents it.
_LMNR_TimingOnlyClaimsFirstShow() {
	Body := _DriverFuncBody("LLM_TooltipMarkChainTimingOnly")
	Assert(Body != "", "LLM_TooltipMarkChainTimingOnly() must exist in the driver source")
	Assert(InStr(Body, "FirstShowTick") > 0,
		"LLM_TooltipMarkChainTimingOnly must claim FirstShowTick when it back-fills TtftMs -- otherwise the render that follows overwrites TtftMs with a later value and the info bar shows TTFT > TTLT")

	Refresh := _DriverFuncBody("LLM_TooltipRefreshChainTiming")
	Assert(Refresh != "", "LLM_TooltipRefreshChainTiming() must exist in the driver source")
	Assert(InStr(Refresh, "if !_LLM_Tooltip_Chain.FirstShowTick") > 0,
		"LLM_TooltipRefreshChainTiming must keep gating its TtftMs write on an unset FirstShowTick -- that gate is what the freeze above relies on")
}
Test("LLM tooltip: freezing the timings claims the first-show slot so TTFT cannot overtake TTLT (llm-markchain-double-render)",
	_LMNR_TimingOnlyClaimsFirstShow)





; =================================================
; =================================================
; ======= 3/ The freeze precedes the render =======
; =================================================
; =================================================

_LMNR_FreezePrecedesFinalRender() {
	; Scan the ENCLOSING function, not the whole driver: an ordering assertion
	; made across the concatenated source compares the first occurrence of each
	; token anywhere, which can land in unrelated files and quietly stop meaning
	; what it says.
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Body != "", "LLM_Engine_OnResults() must exist in the driver source")

	FreezePos := InStr(Body, "LLM_Tooltip_MarkChainTimingOnly(")
	ShowPos := InStr(Body, "LLM_Tooltip_Show(display_slots")
	Assert(FreezePos > 0,
		"the final-prediction path must freeze the chain timings via LLM_Tooltip_MarkChainTimingOnly")
	Assert(ShowPos > 0, "the final-prediction path must still render the slots")
	Assert(FreezePos < ShowPos,
		"the timings must be frozen BEFORE the final render -- the info bar reads TtftMs/TtltMs while it builds, so freezing afterwards is what forced a second full rebuild")
}
Test("LLM tooltip: the final prediction freezes its timings before rendering, not after (llm-markchain-double-render)",
	_LMNR_FreezePrecedesFinalRender)





; ===============================================================
; ===============================================================
; ======= 4/ The wrapper must call a function that exists =======
; ===============================================================
; ===============================================================

; In AHK v2 an undefined function call is not a parse error: the name resolves as
; a variable, and the failure only surfaces at runtime, where every call site's
; `try` swallows it. A wrapper left pointing at a renamed implementation is
; therefore invisible -- no error, no log, just a silently missing TTLT. Pair the
; two names by comparing them explicitly.
_LMNR_WrapperTargetExists() {
	Wrapper := _DriverFuncBody("LLM_Tooltip_MarkChainTimingOnly")
	Assert(Wrapper != "", "the LLM_Tooltip_MarkChainTimingOnly wrapper must exist in the driver source")
	Assert(InStr(Wrapper, "LLM_TooltipMarkChainTimingOnly(") > 0,
		"the wrapper must delegate to LLM_TooltipMarkChainTimingOnly -- a stale name here fails only at runtime and is eaten by the caller's try")

	Impl := _DriverFuncBody("LLM_TooltipMarkChainTimingOnly")
	Assert(Impl != "", "the wrapper's target LLM_TooltipMarkChainTimingOnly must be a real function -- AHK v2 resolves an unknown call as a variable, so a dangling wrapper never fails at load")

	; The old name must be gone everywhere, wrapper included: leaving one behind
	; would mean one of the two layers still points at a function that no longer
	; exists, which is exactly the silent failure described above.
	Assert(InStr(_DriverSourceNoComments(), "MarkChainComplete") == 0,
		"no driver code may still reference MarkChainComplete -- the rename must cover the implementation, the wrapper and every call site together")
}
Test("LLM tooltip: the chain-timing wrapper delegates to a function that actually exists (llm-markchain-double-render)",
	_LMNR_WrapperTargetExists)
