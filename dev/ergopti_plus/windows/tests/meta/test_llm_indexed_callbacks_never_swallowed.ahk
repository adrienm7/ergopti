; static/ergopti_plus/windows/tests/meta/test_llm_indexed_callbacks_never_swallowed.ahk

; ==============================================================================
; MODULE: Regression — a Map-indexed LLM callback must not be invoked bare either
;         (llm-indexed-callbacks-never-swallowed)
; DESCRIPTION:
; The `llm-callbacks-never-swallowed` fix introduced _LLM_InvokeCallback and
; converted every site where the callback sat in a LOCAL variable literally named
; on_success / on_fail / on_result. Its ratchet scans for exactly that spelling —
; `^try\s+on_[A-Za-z_]\w*\s*\(` — so eight sites that read the callback straight
; out of the job/entry Map (`try job["on_fail"]()`,
; `try _LLM_Ollama_Pending["on_fail"]()`, `try entry["on_fail"]()`,
; `try oldest_entry["on_fail"].Call()`) stayed invisible to it. The companion
; "wrapper is widely used" assertion was satisfied by the converted majority, so
; the suite stayed green while the class survived.
;
; ROOT CAUSE ENCODED: the repo's dominant failure mode — an invariant applied at
; one SHAPE, with the siblings forgotten, and the regression test scoped to the
; shape that was fixed rather than to the guarantee. This test forbids the second
; spelling, and the original test keeps forbidding the first; both must stay.
;
; These eight were not incidental. Every one is on a failure or cancel path
; (payload write failure, curl launch failure, cancel-before-spawn, coalescing
; displacement, registry overflow, remote deadline) — precisely where the driver
; is already degraded and a second silent swallow costs the most.
;
; SCOPE: source-level. `try` without `catch` produces no output by construction,
; so absence of the shape is the only assertable form of the guarantee.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================================
; ========================================================
; ======= 1/ No bare-try indexed callback survives =======
; ========================================================
; ========================================================

_LICS_NoBareTryIndexedCallbackRemains() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))
	Assert(Src != "", "the LLM module sources must be readable")

	Offenders := []
	for Line in StrSplit(Src, "`n", "`r") {
		Trimmed := Trim(Line, " `t")
		if RegExMatch(Trimmed, 'i)^try\s+[\w\.\[\]"]*\["on_\w+"\]\s*(\(|\.Call\s*\()')
			Offenders.Push(Trimmed)
	}
	Report := ""
	for O in Offenders
		Report .= "`n    " . O

	Assert(Offenders.Length == 0,
		"an LLM completion callback is still invoked as a bare try on a Map-indexed handle. The wrapper was applied only to the locally-named form, so every job/entry-indexed failure path still deletes its exception — and these are all failure paths, where a second silent swallow is most expensive. Offending site(s):" . Report)
}

; The scan must be able to see the shape it forbids, or it is a tautology that
; passes because the regex never matches anything at all.
_LICS_TheScanCanActuallyMatchTheForbiddenShape() {
	Samples := ['try job["on_fail"]()',
		'try _LLM_Ollama_Pending["on_fail"]()',
		'try entry["on_fail"]()',
		'try oldest_entry["on_fail"].Call()']
	for _, S in Samples
		Assert(RegExMatch(S, 'i)^try\s+[\w\.\[\]"]*\["on_\w+"\]\s*(\(|\.Call\s*\()') > 0,
			"the offender pattern must match the historical shape it is meant to forbid, or the scan above is green for the wrong reason. Missed: " . S)

	Assert(RegExMatch('_LLM_InvokeCallback(job["on_fail"], "on_fail")',
		'i)^try\s+[\w\.\[\]"]*\["on_\w+"\]\s*(\(|\.Call\s*\()') == 0,
		"and it must NOT match a properly wrapped call, or every fixed site would read as an offender")
}





; ==================================================================
; ==================================================================
; ======= 2/ The displaced-job slot is cleared before firing =======
; ==================================================================
; ==================================================================

; The coalescing slot fires on_fail for the job it is about to overwrite. That
; callback re-enters the engine, so the slot must be reassigned FIRST — otherwise
; a re-entrant dispatch finds the displaced job still parked there and fails it a
; second time, breaking the exactly-once contract the call exists to honour.
_LICS_CoalescingClearsBeforeItFires() {
	; Both displacement sites: the coalescing overwrite on dispatch, and the drop
	; performed when everything is cancelled.
	for _, Fn in ["LLM_OllamaGenerate_Async", "LLM_OllamaCancelAllAsync"] {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist in the driver source")

		ClearAt := InStr(Body, "_LLM_Ollama_Pending :=")
		FireAt  := InStr(Body, "_LLM_InvokeCallback")
		Assert(ClearAt > 0, Fn . " must still reassign the pending slot")
		Assert(FireAt > 0,
			Fn . " must fail the displaced job through the wrapper — a job that is dropped without its on_fail leaves the engine's slot state machine waiting for a callback that will never arrive")
		Assert(ClearAt < FireAt,
			Fn . " must reassign the pending slot BEFORE firing the displaced job's on_fail. That callback re-enters the dispatcher, and a re-entrant fire that still finds the old job parked in the slot fails it a second time — the exactly-once contract this call exists to honour")
	}
}


Test("meta llm-indexed-callbacks-never-swallowed: no bare-try indexed callback survives",
	_LICS_NoBareTryIndexedCallbackRemains)
Test("meta llm-indexed-callbacks-never-swallowed: the scan can match the shape it forbids",
	_LICS_TheScanCanActuallyMatchTheForbiddenShape)
Test("meta llm-indexed-callbacks-never-swallowed: the coalescing slot is cleared before it fires",
	_LICS_CoalescingClearsBeforeItFires)
