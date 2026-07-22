; tests/meta/test_ngram_tables_not_cleared_on_refresh.ahk

; ==============================================================================
; MODULE: N-gram Cold-Rebuild Meta Test
; DESCRIPTION:
; Regression guard for durable cold-cache reconstruction of ngram tables.
;
; The Windows writer persists raw events only.  A fresh reader cache must clear
; stale derived rows then replay events_* through the walker; otherwise speed,
; n-grams and correction metrics disappear after restart.
;
; A warm refresh must still retain the rebuilt tables and merge only the live
; walker delta, never replay the full history on each update.
;
; SCOPE: source introspection of modules/keylogger/keylogger_reader.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_NTNC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_NTNC_CheckNgramClearedForColdReplay() {
	Src := _NTNC_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Assert(Src != "", "modules/keylogger/keylogger_reader.ahk must be readable")

	Body := _DriverFuncBody("KLR_ClearAggregates")
	Assert(Body != "", "KLR_ClearAggregates must be present in keylogger_reader.ahk")

	; Every ngram table must be cleared before the raw replay, otherwise stale
	; rows loaded from an older aggregate-persisting writer would be doubled.
	for _, Tbl in ["ngram_chars", "ngram_bigrams", "ngram_trigrams",
	               "ngram_quadgrams", "ngram_pentagrams", "ngram_hexagrams",
	               "ngram_heptagrams", "ngram_words", "ngram_word_bigrams",
	               "ngram_keycodes", "ngram_scancodes", "ngram_shortcuts"] {
		Assert(InStr(Body, '"' . Tbl . '"'),
			"KLR_ClearAggregates must delete stale " . Tbl . " before durable raw replay")
	}
}

_NTNC_CheckAggStillCleared() {
	Src := _NTNC_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Assert(Src != "", "modules/keylogger/keylogger_reader.ahk must be readable")

	Body := _DriverFuncBody("KLR_ClearAggregates")
	Assert(Body != "", "KLR_ClearAggregates must be present in keylogger_reader.ahk")

	; The agg_* tables must still be cleared
	Assert(InStr(Body, '"agg_app_day"'),
		"KLR_ClearAggregates must still clear agg_app_day")
}

_NTNC_CheckReplayRunsOnlyOnColdBuild() {
	Body := _DriverFuncBody("KLR_BuildDatabase")
	Assert(Body != "", "KLR_BuildDatabase must be present")
	ColdPos := InStr(Body, "replayed := KLR_RebuildWalkerAggregates(db)")
	Assert(ColdPos > 0, "cold database construction must replay walker-owned metrics from raw events")
	WarmPos := InStr(Body, "if KLRCache.db")
	WarmBranch := SubStr(Body, WarmPos, 900)
	Assert(!InStr(WarmBranch, "KLR_RebuildWalkerAggregates(KLRCache.db)"),
		"warm refresh must retain existing walker aggregates instead of replaying all history")
}


Test("meta ngram-cold-rebuild: KLR_ClearAggregates removes stale ngram_* rows before raw replay",
	_NTNC_CheckNgramClearedForColdReplay)

Test("meta ngram-cold-rebuild: KLR_ClearAggregates still clears agg_* tables",
	_NTNC_CheckAggStillCleared)

Test("meta ngram-cold-rebuild: raw walker replay runs only for a cold cache",
	_NTNC_CheckReplayRunsOnlyOnColdBuild)
