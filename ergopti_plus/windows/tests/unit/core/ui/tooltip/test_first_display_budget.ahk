; tests/unit/core/ui/tooltip/test_first_display_budget.ahk

; ==============================================================================
; MODULE: Prediction First Display Budget (Windows)
; DESCRIPTION:
; macOS judges a prediction's first display (chain start to the first tooltip,
; TTFT) against [budgets] prediction_display_ms. The Windows tooltip froze the
; same TTFT for its info bar but wrote no budget line, so a slow first display
; never reached the log or tools/dev/field-log-analyse.py (windows-display-budget,
; timing parity campaign TIM-04). The chain start is moved back so the real
; A_TickCount reads a TTFT past or within the budget.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body(Lines) with the log lines captured and the chain reset after.
_FDB_WithLog(Body) {
	global _LOGGER_TEST_SINK, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED, _TimingsCache, _LOGGER_DEDUP_KEY
	Saved := { Sink: _LOGGER_TEST_SINK, Warn: _LOGGER_WARN_ENABLED, Error: _LOGGER_ERROR_ENABLED }
	if (Type(_TimingsCache) != "Map")
		TimingsLoadShared()
	Lines := []
	try {
		_LOGGER_WARN_ENABLED := true, _LOGGER_ERROR_ENABLED := true
		; A line equal to the previous test's would be withheld by the consecutive dedup.
		_LOGGER_DEDUP_KEY := ""
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Body.Call(Lines)
	} finally {
		_LOGGER_TEST_SINK := Saved.Sink
		_LOGGER_WARN_ENABLED := Saved.Warn
		_LOGGER_ERROR_ENABLED := Saved.Error
		_LLM_TooltipResetChain()
	}
}

; How many captured lines contain Needle.
_FDB_Count(Lines, Needle) {
	Count := 0
	for Line in Lines
		if InStr(Line, Needle)
			Count += 1
	return Count
}

; Starts a chain whose start lies AgoMs in the past.
_FDB_StartChain(AgoMs) {
	global _LLM_Tooltip_Chain
	LLM_TooltipSetChainStart()
	_LLM_Tooltip_Chain.StartTick := A_TickCount - AgoMs
}

_FDB_StreamedOverBudget(Lines) {
	Budget := TimingsGet("budgets", "prediction_display_ms")
	_FDB_StartChain(Budget + 500)
	LLM_TooltipRefreshChainTiming()
	LLM_TooltipRefreshChainTiming()
	AssertEqual(1, _FDB_Count(Lines, "Over budget: prediction.display took "),
		"a first display past prediction_display_ms writes the shared overrun line, once per chain")
	AssertEqual(1, _FDB_Count(Lines, "(budget " . Budget . " ms)."))
}
Test("LLM tooltip: a slow first display is judged against prediction_display_ms (windows-display-budget, TIM-04)",
	() => _FDB_WithLog(_FDB_StreamedOverBudget))

_FDB_BatchOverBudget(Lines) {
	Budget := TimingsGet("budgets", "prediction_display_ms")
	_FDB_StartChain(Budget + 500)
	LLM_TooltipMarkChainTimingOnly(A_TickCount)
	LLM_TooltipRefreshChainTiming()
	AssertEqual(1, _FDB_Count(Lines, "Over budget: prediction.display took "),
		"the batch path, whose first display is the final one, is judged once too")
}
Test("LLM tooltip: a batch prediction's first display is judged once (windows-display-budget, TIM-04)",
	() => _FDB_WithLog(_FDB_BatchOverBudget))

_FDB_WithinBudget(Lines) {
	_FDB_StartChain(0)
	LLM_TooltipRefreshChainTiming()
	AssertEqual(0, _FDB_Count(Lines, "Over budget"), "a first display within its budget writes no warning")
	AssertEqual(0, _FDB_Count(Lines, "could not be judged"), "and reads its budget")
}
Test("LLM tooltip: a first display within its budget writes nothing (windows-display-budget, TIM-04)",
	() => _FDB_WithLog(_FDB_WithinBudget))
