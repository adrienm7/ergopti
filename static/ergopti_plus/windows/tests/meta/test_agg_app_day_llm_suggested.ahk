; static/ergopti_plus/windows/tests/meta/test_agg_app_day_llm_suggested.ahk

#Requires AutoHotkey v2.0

_AggLlmSuggested_RebuildAggregatesWiresEventsLlm() {
	; KLR_RebuildAggregates must feed agg_app_day.llm_suggested from
	; events_llm the same way it feeds hs_suggested from events_hotstring —
	; otherwise events_llm stays permanently unused end-to-end (F19).
	Body := _DriverFuncBody("KLR_RebuildAggregates")
	Assert(InStr(Body, "llm_suggested") > 0, "KLR_RebuildAggregates must write agg_app_day.llm_suggested (events-llm-never-aggregated)")
	Assert(InStr(Body, "FROM events_llm") > 0, "KLR_RebuildAggregates must read from events_llm (events-llm-never-aggregated)")
}
Test("keylogger: KLR_RebuildAggregates wires events_llm into agg_app_day.llm_suggested (events-llm-never-aggregated)", _AggLlmSuggested_RebuildAggregatesWiresEventsLlm)
