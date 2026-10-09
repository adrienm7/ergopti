; tests/meta/test_ngram_esrc_json_accumulate.ahk

; ==============================================================================
; MODULE: N-gram UPSERT esrc_json Accumulation Meta Test
; DESCRIPTION:
; Regression guard ensuring the ngram UPSERT accumulates esrc_json counts
; instead of overwriting them.
;
; The bug: the ON CONFLICT clause used `esrc_json=excluded.esrc_json`, which
; replaces the stored JSON object with the new batch's object on every flush.
; A row flushed in cycle 1 with {"hotstring":3} and again in cycle 2 with
; {"hotstring":2} would end up with {"hotstring":2} instead of 5.
;
; The merge enumerates literal keys with json_each and sums old and incoming
; values. Source names must never be interpolated as JSON paths: punctuation
; would create nested members instead of updating the original counter.
;
; SCOPE: source introspection of modules/keylogger/keylogger_walker.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_NEA_CheckNoOverwrite() {
	; Move-resilient: scan the modules/keylogger dir via the framework helper.
	; All esrc_json anchors here are unique to keylogger_walker.ahk within that dir.
	Src := _DriverDirConcat("modules/keylogger")
	Assert(Src != "", "the keylogger sources must be available")

	; The old bare-overwrite form must not appear in the UPSERT for ngram tables
	Assert(!InStr(Src, "esrc_json=excluded.esrc_json"),
		"ngram UPSERT must not overwrite esrc_json with excluded.esrc_json — use KLW_EsrcMergeExpr() to accumulate counts")
}

_NEA_CheckMergeExprExists() {
	Body := _DriverFuncBody("KLW_EsrcMergeExpr")
	Caller := _DriverFuncBody("KLW_BuildBatchSql")
	Assert(Body != "" && Caller != "", "both merge and batch emitter must exist")
	Assert(InStr(Caller, "KLW_EsrcMergeExpr("), "the ngram UPSERT must call the merge helper")
}

_NEA_CheckMergeExprUsesLiteralKeys() {
	Expr := KLW_EsrcMergeExpr(Map("source.v2", 1))
	Assert(InStr(Expr, "json_each(COALESCE(esrc_json,'{}'))")
		&& InStr(Expr, "json_each(excluded.esrc_json)"),
		"both source objects must be enumerated by literal key, with a NULL-safe stored base")
}

_NEA_CheckMergeExprSumsKeys() {
	Expr := KLW_EsrcMergeExpr(Map("source.v2", 1))
	Assert(InStr(Expr, "SUM(value)") && InStr(Expr, "UNION ALL") && InStr(Expr, "GROUP BY key"),
		"each key must accumulate both inputs, including equal-valued contributions")
}


Test("meta ngram-esrc-accumulate: ngram UPSERT does not overwrite esrc_json with excluded value",
	_NEA_CheckNoOverwrite)

Test("meta ngram-esrc-accumulate: KLW_EsrcMergeExpr helper is defined and referenced",
	_NEA_CheckMergeExprExists)

Test("meta ngram-esrc-accumulate: KLW_EsrcMergeExpr enumerates literal keys with a NULL-safe base",
	_NEA_CheckMergeExprUsesLiteralKeys)

Test("meta ngram-esrc-accumulate: KLW_EsrcMergeExpr sums existing and excluded counts per key",
	_NEA_CheckMergeExprSumsKeys)
