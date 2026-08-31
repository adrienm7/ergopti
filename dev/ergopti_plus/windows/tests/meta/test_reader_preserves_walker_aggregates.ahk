; static/ergopti_plus/windows/tests/meta/test_reader_preserves_walker_aggregates.ahk

#Requires AutoHotkey v2.0

_ReaderPreservesWalkerAggregates_WarmRefreshDoesNotClear() {
	Body := _DriverFuncBody("KLR_BuildDatabase")
	Assert(Body != "", "KLR_BuildDatabase must exist")
	CachePos := InStr(Body, "if KLRCache.db")
	Assert(CachePos > 0, "KLR_BuildDatabase must have a warm-cache branch")
	RebuildPos := InStr(Body, "KLR_RebuildAggregates(KLRCache.db)", true, CachePos)
	InjectPos := InStr(Body, "KLR_InjectKlwBatch(KLRCache.db)", true, CachePos)
	ClearPos := InStr(Body, "KLR_ClearAggregates(KLRCache.db)", true, CachePos)
	Assert(ClearPos = 0 or ClearPos > InjectPos,
		"warm refresh must retain walker-owned aggregate rows instead of clearing them")
	Assert(RebuildPos > CachePos,
		"warm refresh must still project SQL-owned event aggregates")
	Assert(InjectPos > RebuildPos,
		"warm refresh must merge the new walker batch after the SQL projection")
}

_ReaderPreservesWalkerAggregates_RawProjectionReplacesOnlySqlFields() {
	Body := _DriverFuncBody("KLR_RebuildAggregates")
	Assert(Body != "", "KLR_RebuildAggregates must exist")
	for Index, Token in ["chars=excluded.chars", "hs_chars=excluded.hs_chars",
		"hs_suggested=excluded.hs_suggested", "llm_suggested=excluded.llm_suggested",
		"app_time_ms=excluded.app_time_ms", "c=excluded.c", "count=excluded.count"] {
		Assert(InStr(Body, Token) > 0,
			"raw SQL projection must replace its owned value: " . Token)
	}
	Assert(!InStr(Body, "time_ms=excluded.time_ms"),
		"raw projection must not overwrite the walker-owned time_ms metric")
}

Test("keylogger reader: warm cache retains walker aggregates while refreshing raw projections (reader-warm-cache-walker-loss)",
	_ReaderPreservesWalkerAggregates_WarmRefreshDoesNotClear)
Test("keylogger reader: raw projections replace only SQL-owned aggregate fields (reader-warm-cache-walker-loss)",
	_ReaderPreservesWalkerAggregates_RawProjectionReplacesOnlySqlFields)
