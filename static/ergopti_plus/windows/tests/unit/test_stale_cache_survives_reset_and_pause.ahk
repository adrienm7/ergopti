; static/ergopti_plus/windows/tests/unit/test_stale_cache_survives_reset_and_pause.ahk

; ==============================================================================
; MODULE: Stale-Cache Reset/Pause Regression Test
; DESCRIPTION:
; Behavioural regression test for finding ``stale-cache-survives-reset-and-pause``.
;
; The prediction cache (_LLM_Engine["last_ctx"] / ["last_results"] /
; ["last_result"]) is keyed only on context-string equality, not on a
; still-valid generation. Before the fix, LLM_Engine_StopGeneration bumped
; request_id (invalidating in-flight async callbacks) but left the cache intact.
; So a context the user returned to -- or rebuilt after a pause/resume -- would
; instantly REPLAY a prediction they had already dismissed via navigation,
; surfacing as a "ghost" suggestion.
;
; The fix clears last_ctx / last_results / last_result inside
; LLM_Engine_StopGeneration so an explicit reset / pause drops the cache and the
; next fire on that context takes the network path instead of the cache branch.
;
; LLM_Engine_StopGeneration is in the run_all include graph and only calls
; LLM_Engine_CancelTimer plus try-wrapped cancel helpers (all present in the
; LLM modules the runner includes), so this is a headless-safe behavioural test.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Cache cleared on stop ==================
; ===================================================
; ===================================================

_SCSP_StopGenerationClearsCache() {
	global _LLM_Engine
	; Prime the cache as if a prediction had just been shown for "bonjour".
	_LLM_Engine := Map(
		"request_id",   7,
		"last_ctx",     "bonjour",
		"last_results", ["!"],
		"last_result",  "!"
	)

	LLM_Engine_StopGeneration()

	; The cache must be wiped so a returned-to / rebuilt context cannot replay a
	; dismissed prediction. last_ctx empty + zero results forces the next
	; FirePrediction onto the network path rather than the exact-match cache.
	AssertEqual("", _LLM_Engine["last_ctx"],
		"StopGeneration must clear last_ctx so a dismissed prediction cannot replay on the same context")
	AssertEqual(0, _LLM_Engine["last_results"].Length,
		"StopGeneration must clear last_results so the cache cannot re-render across a reset/pause")
	AssertEqual("", _LLM_Engine["last_result"],
		"StopGeneration must clear last_result (singular) so the legacy cache field cannot replay either")
}
Test("prediction_engine: StopGeneration clears the prediction cache (stale-cache-survives-reset-and-pause)", _SCSP_StopGenerationClearsCache)


_SCSP_StopGenerationBumpsRequestId() {
	global _LLM_Engine
	_LLM_Engine := Map("request_id", 3, "last_ctx", "x", "last_results", ["y"], "last_result", "y")
	before := _LLM_Engine["request_id"]
	LLM_Engine_StopGeneration()
	; request_id still advances (kills stale in-flight callbacks) -- the cache
	; clear is additive, it must not regress the existing invalidation.
	Assert(_LLM_Engine["request_id"] > before,
		"StopGeneration must still bump request_id to invalidate in-flight callbacks")
}
Test("prediction_engine: StopGeneration still bumps request_id alongside the cache clear (stale-cache-survives-reset-and-pause)", _SCSP_StopGenerationBumpsRequestId)
