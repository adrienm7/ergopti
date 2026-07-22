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
; The fix: KLW_EsrcMergeExpr() builds a SQLite json_set() expression that
; sums each key individually:
;   json_set(COALESCE(esrc_json,'{}'),
;     '$.hotstring', COALESCE(json_extract(esrc_json,'$.hotstring'),0)
;                  + COALESCE(json_extract(excluded.esrc_json,'$.hotstring'),0))
; so every flush adds to the running total rather than replacing it.
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

	; The old bare-overwrite form must not appear in the UPSERT for ngram tables
	Assert(!InStr(Src, "esrc_json=excluded.esrc_json"),
		"ngram UPSERT must not overwrite esrc_json with excluded.esrc_json — use KLW_EsrcMergeExpr() to accumulate counts")
}

_NEA_CheckMergeExprExists() {
	Src := _DriverDirConcat("modules/keylogger")

	Assert(InStr(Src, "KLW_EsrcMergeExpr"),
		"KLW_EsrcMergeExpr must be defined and used in keylogger_walker.ahk")
}

_NEA_CheckMergeExprUsesJsonSet() {
	Src := _DriverDirConcat("modules/keylogger")

	Assert(InStr(Src, "json_set(COALESCE(esrc_json"),
		"KLW_EsrcMergeExpr must build a json_set() expression starting from COALESCE(esrc_json,'{}') to handle NULL rows")
}

_NEA_CheckMergeExprSumsKeys() {
	Src := _DriverDirConcat("modules/keylogger")

	; The expression must sum existing + excluded values for each key
	Assert(InStr(Src, "json_extract(esrc_json,") && InStr(Src, "json_extract(excluded.esrc_json,"),
		"KLW_EsrcMergeExpr must sum json_extract(esrc_json,...) + json_extract(excluded.esrc_json,...) for each key")
}


Test("meta ngram-esrc-accumulate: ngram UPSERT does not overwrite esrc_json with excluded value",
	_NEA_CheckNoOverwrite)

Test("meta ngram-esrc-accumulate: KLW_EsrcMergeExpr helper is defined and referenced",
	_NEA_CheckMergeExprExists)

Test("meta ngram-esrc-accumulate: KLW_EsrcMergeExpr uses json_set with COALESCE base",
	_NEA_CheckMergeExprUsesJsonSet)

Test("meta ngram-esrc-accumulate: KLW_EsrcMergeExpr sums existing and excluded counts per key",
	_NEA_CheckMergeExprSumsKeys)
