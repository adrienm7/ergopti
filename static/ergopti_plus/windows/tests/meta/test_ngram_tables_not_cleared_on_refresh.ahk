; tests/meta/test_ngram_tables_not_cleared_on_refresh.ahk

; ==============================================================================
; MODULE: N-gram Tables Preservation Meta Test
; DESCRIPTION:
; Regression guard ensuring KLR_ClearAggregates does not delete ngram_* rows.
;
; The bug: KLR_ClearAggregates cleared ngram_chars, ngram_bigrams, etc. along
; with the agg_* tables.  KLR_RebuildAggregates does not repopulate ngrams
; (they come from data.sql + KLR_InjectKlwBatch).  Clearing them on every
; refresh therefore wiped the entire stored ngram history between reload cycles.
;
; The fix: remove ngram_* tables from the KLR_ClearAggregates list so that
; historical data loaded from data.sql survives the refresh.
; KLR_InjectKlwBatch continues to merge the current in-RAM KLW.batch on top.
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

_NTNC_FuncBody(Src, FnDecl) {
	FnPos := InStr(Src, FnDecl)
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_NTNC_CheckNgramNotInClear() {
	Src := _NTNC_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Assert(Src != "", "modules/keylogger/keylogger_reader.ahk must be readable")

	Body := _DriverFuncBody("KLR_ClearAggregates")
	Assert(Body != "", "KLR_ClearAggregates must be present in keylogger_reader.ahk")

	; None of the ngram tables must appear in the clear list
	for _, Tbl in ["ngram_chars", "ngram_bigrams", "ngram_trigrams",
	               "ngram_quadgrams", "ngram_words", "ngram_keycodes",
	               "ngram_shortcuts"] {
		Assert(!InStr(Body, '"' . Tbl . '"'),
			"KLR_ClearAggregates must not delete " . Tbl . " — ngram history survives from data.sql")
	}
}

_NTNC_CheckAggStillCleared() {
	Src := _NTNC_ReadSource("modules/keylogger/keylogger_reader.ahk")
	Assert(Src != "", "modules/keylogger/keylogger_reader.ahk must be readable")

	Body := _DriverFuncBody("KLR_ClearAggregates")
	Assert(Body != "", "KLR_ClearAggregates must be present in keylogger_reader.ahk")

	; The agg_* tables must still be cleared
	Assert(InStr(Body, '"agg_app_day"'),
		"KLR_ClearAggregates must still clear agg_app_day (only ngrams are exempt)")
}


Test("meta ngram-not-cleared: KLR_ClearAggregates does not delete ngram_* tables on refresh",
	_NTNC_CheckNgramNotInClear)

Test("meta ngram-not-cleared: KLR_ClearAggregates still clears agg_* tables",
	_NTNC_CheckAggStillCleared)
