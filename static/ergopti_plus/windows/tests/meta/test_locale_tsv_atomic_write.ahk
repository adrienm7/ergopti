; tests/meta/test_locale_tsv_atomic_write.ahk

; ==============================================================================
; MODULE: TSV Cache Atomic-Publication Meta Test
; DESCRIPTION:
; Static source guard for the locale-tsv-non-atomic-write finding.
;
; _I18nWriteTsvCache published its ~130 KB locale cache directly over the live
; path in two steps: `if FileExist(TsvPath) FileDelete(TsvPath)` followed by
; `FileAppend(Content, TsvPath, ...)`. A Reload landing between the two calls
; (the layout-change watcher reloads on any Windows keyboard-layout switch, the
; tray offers a Reload item, and #SingleInstance replacement kills the process
; outright) leaves the live cache absent or truncated at an arbitrary byte.
; That damage is PERMANENT and silent: _I18nTsvIsFresh is a pure mtime compare,
; so the torn file is newer than its .json and is declared fresh forever, and
; A reader without a terminal sentinel happily parses the surviving prefix.
; Every key past the truncation renders as the EN fallback or
; as its raw dotted name, and the "No translation for" warning only fires on a
; total miss, so nothing in the logs ever names the cause.
;
; The identical defect was found and fixed once already, in the sibling
; _HotstringsCacheWriteTsv, whose own docstring says it "mirrors
; _I18nWriteTsvCache" - the repair went to the copy and was never carried back
; to the original. Its guard test asserts only on that one function body, so it
; stayed green while the original stayed broken.
;
; This guard therefore pins the invariant to the CLASS, not to whichever
; function the bug was last found in: the writer set is DERIVED from driver
; source (every top-level function whose name contains "WriteTsv"), so a third
; TSV writer added tomorrow joins this test automatically instead of shipping
; the same two-step publication a third time.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Derive the TSV-writer class =======
; ==============================================
; ==============================================

; Returns the names of every top-level driver function that writes a .tsv cache,
; derived from source rather than enumerated by hand.
_LTAW_TsvWriterNames() {
	Src := _DriverSourceNoComments()
	Names := []
	Seen := Map()
	Pos := 1
	while (Found := RegExMatch(Src, "m)^([A-Za-z_][A-Za-z0-9_]*WriteTsv[A-Za-z0-9_]*)\([^\r\n]*\)\s*\{", &M, Pos)) {
		if !Seen.Has(M[1]) {
			Seen[M[1]] := true
			Names.Push(M[1])
		}
		Pos := M.Pos + M.Len
	}
	return Names
}





; ====================================================
; ====================================================
; ======= 2/ Every writer publishes atomically =======
; ====================================================
; ====================================================

_LTAW_EveryTsvWriterStagesThenRenames() {
	Names := _LTAW_TsvWriterNames()

	; A scan that matches nothing must not pass. Both known writers
	; (_HotstringsCacheWriteTsv, _I18nWriteTsvCache) must be found, or the
	; derivation broke and this guard is certifying an unchecked property.
	Assert(Names.Length >= 2,
		"the TSV-writer scan must find every *WriteTsv* function (found " . Names.Length . "): a hand-scoped guard is exactly how the locale writer kept its two-step publication after the hotstrings writer was fixed")

	Found := Map()
	for _, Fn in Names {
		Found[Fn] := true
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . "() was found by the source scan but its body could not be resolved")

		Assert(InStr(Body, ".tmp") > 0,
			Fn . " must stage the new cache into a .tmp intermediary instead of writing over the live path (locale-tsv-non-atomic-write)")
		Assert(InStr(Body, "FileMove") > 0,
			Fn . " must FileMove the staged file over the cache: an NTFS rename is atomic, so the cache is always either the old file or the new one, never a truncated prefix that a mtime-only freshness check then serves forever")
		Assert(RegExMatch(Body, "FileDelete\(TsvPath\)\s*\r?\n\s*FileAppend") == 0,
			Fn . " must NOT delete the live cache and then append to it: a Reload or a #SingleInstance replacement landing between the two calls leaves the authoritative file absent or half-written")
	}

	Assert(Found.Has("_I18nWriteTsvCache"),
		"the locale cache writer _I18nWriteTsvCache must still be part of the derived TSV-writer class")
	Assert(Found.Has("_HotstringsCacheWriteTsv"),
		"the hotstrings cache writer _HotstringsCacheWriteTsv must still be part of the derived TSV-writer class")
}
Test("locale: every .tsv cache writer publishes atomically, not FileDelete+FileAppend (locale-tsv-non-atomic-write)", _LTAW_EveryTsvWriterStagesThenRenames)





; ===================================================
; ===================================================
; ======= 3/ A torn cache can still self-heal =======
; ===================================================
; ===================================================

; Defence in depth for the read side. A non-empty prefix is still damaged, so
; fast-path acceptance must require the writer's terminal completeness proof.
_LTAW_FastCacheRequiresCompletenessProof() {
	Body := _DriverFuncBody("_I18nLoadLocaleMap")
	Assert(Body != "", "_I18nLoadLocaleMap() must exist in the driver source")
	Assert(InStr(Body, "ParseStatus.Complete") > 0,
		"_I18nLoadLocaleMap must require the terminal TSV completeness proof before accepting any fast-cache prefix")
}
Test("locale: .tsv fast-cache acceptance requires a completeness proof (locale-tsv-non-atomic-write)",
	_LTAW_FastCacheRequiresCompletenessProof)
