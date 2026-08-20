; static/ergopti_plus/windows/tests/unit/test_llm_cache_hit_logs_suggested.ahk

; ==============================================================================
; MODULE: Regression — every final render emits llm_suggested, cache hits included
;         (llm-cache-hit-skips-suggested)
; DESCRIPTION:
; `llm_suggested` pairs 1:1 with exactly one `llm_accepted` (Tab) or
; `llm_dismissed` (typed past / timed out), and the acceptance rate is the ratio
; of the two. The event was emitted from _LLM_Engine_FinalizeRequest alone, on
; the assumption — stated in its own comment — that finalization is the only
; producer of a final render.
;
; ROOT CAUSE ENCODED: that assumption was broken by the two prediction-cache
; shortcuts in LLM_Engine_FirePrediction. Both call
; LLM_Engine_OnResults(..., is_final := true) — a full, Tab-acceptable tooltip —
; and return before finalization runs. The acceptance-side events, by contrast,
; hang off the UI lifecycle (_LLM_Bridge_OnInjectComplete, LLM_Tooltip_Hide),
; which the cache path DOES go through. One side of the pair was engine-scoped
; and the other UI-scoped, so a context served N times from cache against a
; single suggestion made accepted/suggested exceed 100 %. The distortion appears
; only as an implausible ratio in an aggregate — no log line, no error.
;
; The fix carries final-render intent into the surface record and emits only
; after the common reveal/publication succeeds. Any future producer inherits the
; lifecycle without counting a refused or stale paint.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ The render is what emits the suggestion =======
; ==========================================================
; ==========================================================

_LCHS_ResetEngineForRender() {
	global _LLM_Engine, _Stub_LlmSuggestedCalls, _Stub_LlmTooltipCalls
	LLM_Engine_Init(Map())
	_LLM_Engine["inline_autotype"] := false
	_Stub_LlmSuggestedCalls := []
	_Stub_LlmTooltipCalls   := []
}

; A final engine render carries lifecycle intent, but only a successful common
; pixel commit may turn it into a suggestion metric.
_LCHS_FinalRenderDelegatesSuggestionToSurfaceCommit() {
	global _Stub_LlmSuggestedCalls, _Stub_LlmTooltipCalls
	_LCHS_ResetEngineForRender()

	LLM_Engine_OnResults(["intelligence", "intelligent"], "intelligen", 1, true)

	AssertEqual(0, _Stub_LlmSuggestedCalls.Length,
		"the engine must not log before the common presenter proves that final pixels committed")
	Assert(_Stub_LlmTooltipCalls.Length > 0
		and _Stub_LlmTooltipCalls[1].meta.Get("is_final", false),
		"every final producer, including both cache shortcuts, must carry final lifecycle intent into the surface transaction")
}
Test("LLM suggested: a final render delegates lifecycle to committed pixels",
	_LCHS_FinalRenderDelegatesSuggestionToSurfaceCommit)

; Streaming partials must not inflate the count: they are not acceptable states.
_LCHS_IntermediateRenderEmitsNothing() {
	global _Stub_LlmSuggestedCalls
	_LCHS_ResetEngineForRender()

	LLM_Engine_OnResults(["intel"], "intelligen", 1, false)

	AssertEqual(0, _Stub_LlmSuggestedCalls.Length,
		"an intermediate (streaming) render must emit nothing — one request paints many partials, and counting them would inflate the denominator of the acceptance rate exactly as skipping the cache hits deflated it")
}
Test("LLM suggested: an intermediate render emits nothing",
	_LCHS_IntermediateRenderEmitsNothing)





; =============================================================
; =============================================================
; ======= 2/ The emission is not engine-scoped any more =======
; =============================================================
; =============================================================

; Placement is the guarantee. Left in the finalizer, the invariant has to be
; re-asserted by hand at every new producer of a final render — which is exactly
; how the cache branches came to skip it.
_LCHS_EmissionLivesAtTheRenderChokePoint() {
	Render := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Render != "", "LLM_Engine_OnResults must exist in the driver source")
	Assert(InStr(Render, "_LLM_Engine_LogSuggested") == 0
		and InStr(Render, '"is_final", is_final ? true : false') > 0,
		"the engine render must carry intent without emitting before pixel commit")
	Presenter := _DriverFuncBody("_TooltipPresentStack")
	Marker := _DriverFuncBody("_LLM_TooltipMarkSurfaceSuggested")
	PublishPos := InStr(Presenter,
		"Published := _TooltipPublishVisibleDecisions(PublishItems)")
	MarkerPos := InStr(Presenter,
		"_LLM_TooltipMarkSurfaceSuggested(PreparedSurface)")
	Assert(PublishPos > 0 and MarkerPos > PublishPos
		and InStr(Marker,
			'_LLM_TooltipQueueMetricUnsafe("suggested", Lifecycle)') > 0,
		"the committed surface must emit exactly after reveal/publication, so refused cache renders remain uncounted")

	Fin := _DriverFuncBody("_LLM_Engine_FinalizeRequest")
	Assert(Fin != "", "_LLM_Engine_FinalizeRequest must exist in the driver source")
	Assert(InStr(Fin, "KL_LogLlmSuggested") == 0 and InStr(Fin, "_LLM_Engine_LogSuggested") == 0,
		"_LLM_Engine_FinalizeRequest must NOT emit the suggestion itself — it is one producer of a final render among several, and owning the event there is what made the two cache branches silent")
}
Test("LLM suggested: the emission lives at the committed surface, not in the finalizer",
	_LCHS_EmissionLivesAtTheRenderChokePoint)





; ===============================================================
; ===============================================================
; ======= 3/ A cache hit cancels the remote transport too =======
; ===============================================================
; ===============================================================

; Same two branches, second defect: their comment claims they cancel the
; in-flight requests, but only the local backend was cancelled. On the api
; backend the superseded request's result is correctly discarded by the
; request-id check, while its curl child and the temp files carrying the typed
; context live on until the poll tick reaps them.
_LCHS_CacheBranchesCancelBothBackends() {
	Body := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(Body != "", "LLM_Engine_FirePrediction must exist in the driver source")

	LocalHits := 0
	Pos := 1
	while (F := InStr(Body, "LLM_OllamaCancelAllAsync(", false, Pos)) {
		Pos := F + 1
		LocalHits += 1
	}
	Remote := 0
	Pos := 1
	while (F := InStr(Body, "LLM_RemoteCancelAllAsync(", false, Pos)) {
		Pos := F + 1
		Remote += 1
	}

	Assert(LocalHits >= 2,
		"both prediction-cache branches must still cancel the in-flight local request before rendering (found " . LocalHits . ")")
	AssertEqual(LocalHits, Remote,
		"every cache branch that cancels the local backend must cancel the remote one too (local: " . LocalHits . ", remote: " . Remote . "). Deriving the count from the sibling rather than naming the branches means a third cache shortcut cannot quietly reopen the gap")
}
Test("LLM cache hit: both cache branches cancel the remote backend as well",
	_LCHS_CacheBranchesCancelBothBackends)
