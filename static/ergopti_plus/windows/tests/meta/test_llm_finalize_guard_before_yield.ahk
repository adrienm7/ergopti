; static/ergopti_plus/windows/tests/meta/test_llm_finalize_guard_before_yield.ahk

; ==============================================================================
; MODULE: Regression — the staleness guard must sit BELOW the yielding work
;         (llm-finalize-guard-before-yield)
; DESCRIPTION:
; _LLM_Engine_FinalizeRequest re-checked the request id immediately after its
; entry check. On the non-empty-slot path nothing runs between the two but an
; array-length read, so the second check was a no-op — while every operation the
; guard was written for (the summary log, two WIGetFocused() calls, the keylogger
; generation write and the suggestion event) ran AFTERWARDS, in front of the
; render.
;
; ROOT CAUSE ENCODED: a guard is only worth the yields it stands in front of.
; The completion runs on a SetTimer thread past AHK's initial uninterruptible
; window, so the InputHook can pre-empt it there; the keystroke bumps request_id
; and arms a deferred tooltip hide against the CURRENT tooltip generation, then
; the finalize thread resumes and paints anyway. LLM_TooltipShow bumps that
; generation, so the deferred hide silently returns on the epoch mismatch and a
; prediction for text the user has already left stays on screen for its full
; auto-hide — undismissable by the very keystroke that superseded it. Worse, the
; cache seed above it hands that stale context to the next fire, which then
; replays it instead of querying the model.
;
; SCOPE: source-level. The chain runs from an HTTP-completion timer tick and the
; failure needs a real pre-emption mid-function, which the headless harness
; cannot schedule; the ORDER of the statements is the invariant, and it is
; checkable exactly.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================================
; ====================================================================
; ======= 1/ Nothing that yields sits between guard and render =======
; ====================================================================
; ====================================================================

; The window between the last staleness guard and the render must contain no
; call that can hand the thread to the keyboard.
_LFGY_NoYieldBetweenGuardAndRender() {
	Body := _DriverFuncBody("_LLM_Engine_FinalizeRequest")
	Assert(Body != "", "_LLM_Engine_FinalizeRequest must exist in the driver source")

	RenderAt := InStr(Body, "LLM_Engine_OnResults(state[")
	Assert(RenderAt > 0,
		"_LLM_Engine_FinalizeRequest must still end in a final render — a guard test that no longer finds the thing it guards is vacuous")

	; The LAST guard before the render is the only one that protects it.
	GuardAt := 0
	Pos := 1
	while (F := InStr(Body, "_LLM_Engine_IsCurrent(state)", false, Pos)) {
		if (F >= RenderAt)
			break
		GuardAt := F
		Pos := F + 1
	}
	Assert(GuardAt > 0,
		"the final render must be preceded by a staleness guard — without one, a request superseded while the callback was running still paints")

	Between := SubStr(Body, GuardAt, RenderAt - GuardAt)
	for _, Yielder in ["LLM_ApiCommon_LogSummary", "WIGetFocused", "KL_LogLlm", "KL_LogLlmSuggested"] {
		Assert(InStr(Between, Yielder) == 0,
			"'" . Yielder . "' runs between the last staleness guard and the render. Any of these yields; a keystroke landing in that window bumps request_id and arms a deferred tooltip hide against the current generation, and the render then paints a prediction for text the user has already left — with that hide silently skipped on the epoch mismatch the paint itself creates (llm-finalize-guard-before-yield)")
	}
}

; And the guard must still stand in front of the CACHE SEED too: seeding
; last_ctx from a superseded request makes the next fire replay it.
_LFGY_GuardAlsoPrecedesTheCacheSeed() {
	Body := _DriverFuncBody("_LLM_Engine_FinalizeRequest")
	Assert(Body != "", "_LLM_Engine_FinalizeRequest must exist in the driver source")

	SeedAt := InStr(Body, '_LLM_Engine["last_ctx"]')
	Assert(SeedAt > 0, "the prediction cache seed must still exist")

	GuardAt := 0
	Pos := 1
	while (F := InStr(Body, "_LLM_Engine_IsCurrent(state)", false, Pos)) {
		if (F >= SeedAt)
			break
		GuardAt := F
		Pos := F + 1
	}
	Assert(GuardAt > 0,
		"the cache seed must be preceded by a staleness guard — a stale last_ctx is inherited by the NEXT request, which then serves it from cache instead of querying the model")
}





; =============================================================
; =============================================================
; ======= 2/ The render gates once more on its own side =======
; =============================================================
; =============================================================

; LLM_Diff_Compute and the display-opts resolution run inside the render, after
; the caller's guard. The render therefore needs its own final check, and the
; caller has to hand it the id to check against.
_LFGY_RenderCarriesItsOwnGuard() {
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Body != "", "LLM_Engine_OnResults must exist in the driver source")

	ShowAt := InStr(Body, "LLM_Tooltip_Show(display_slots")
	Assert(ShowAt > 0, "the tooltip render must still exist")

	GuardAt := InStr(Body, "_LLM_Engine_IsCurrent(")
	Assert(GuardAt > 0 and GuardAt < ShowAt,
		"LLM_Engine_OnResults must re-check staleness before it paints. LLM_Diff_Compute runs a RegExMatch per character over every slot and the display-opts resolution queries the focused window, so the caller's check is already stale by the time the paint happens")

	Fin := _DriverFuncBody("_LLM_Engine_FinalizeRequest")
	Fin := RegExReplace(Fin, "\s+", " ")
	Assert(InStr(Fin,
		'LLM_Engine_OnResults(state["slots"], state["ctx"], 1, true, state["request_id"], state["semantic_signature"])',
		true) > 0,
		'_LLM_Engine_FinalizeRequest must thread request and semantic identities into the render — a guard inside the render with nothing to compare against is decoration')
}


Test("meta llm-finalize-guard-before-yield: no yielding call sits between the guard and the render",
	_LFGY_NoYieldBetweenGuardAndRender)
Test("meta llm-finalize-guard-before-yield: the guard also precedes the cache seed",
	_LFGY_GuardAlsoPrecedesTheCacheSeed)
Test("meta llm-finalize-guard-before-yield: the render gates once more on its own side",
	_LFGY_RenderCarriesItsOwnGuard)
