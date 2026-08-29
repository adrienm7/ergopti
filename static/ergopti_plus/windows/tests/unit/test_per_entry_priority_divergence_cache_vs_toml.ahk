; tests/unit/test_per_entry_priority_divergence_cache_vs_toml.ahk

; ==============================================================================
; MODULE: Cache Per-Entry Priority Round-Trip Test
; DESCRIPTION:
; Regression test for finding per-entry-priority-divergence-cache-vs-toml.
;
; The .tsv cache was a lossy projection of the TOML: it dropped the per-entry
; `priority = N` override that the TOML fallback computes via _ParseEntryPriority.
; A cached entry therefore registered at the section/source default while the same
; TOML served by the fallback registered at its override value, so two boots of
; the SAME TOML could resolve different HSE collision priorities.
;
; The fix adds a 9th priority column to the cache row + .tsv. This test builds a
; row carrying a per-entry priority, round-trips it through the real
; _HotstringsCacheWriteTsv / _HotstringsCacheReadTsv, and asserts the override
; survives the cache I/O and equals what _ParseEntryPriority reads from the same
; TOML line. Before the fix the round-trip dropped the override (the row had only
; 6 columns and the writer emitted no priority field), so the assertions fail.
;
; Behavioural (not meta-static): hotstrings_cache.ahk and toml_loader.ahk are both
; in the run_all.ahk include graph, and these three functions are pure (FileRead /
; FileAppend on a temp path, no OS/COM/hotkey side effects).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ Round-trip preserves per-entry priority =======
; ==========================================================
; ==========================================================

_PriorityDivergence_RoundTripKeepsOverride() {
	; A section with two equal-length colliding triggers; the second carries an
	; inline `priority = 60` override (column 7), the first has none ("").
	Rows := Map()
	Rows["distancesreduction.assign"] := [
		["", "ab", "first", true, false, true, ""],
		["", "cd", "second", true, false, true, 60]
	]

	TmpTsv := A_Temp . "\ergopti_priority_divergence_test.tsv"
	_HotstringsCacheWriteTsv(TmpTsv, Rows)
	Back := _HotstringsCacheReadTsv(FileRead(TmpTsv, "UTF-8"))
	try FileDelete(TmpTsv)

	Assert(Back.Has("distancesreduction.assign"), "round-trip must keep the section")
	RT := Back["distancesreduction.assign"]
	Assert(RT.Length == 2, "round-trip must keep both rows (got " . RT.Length . ")")
	; The priority override must survive the .tsv round-trip in column 7.
	AssertEqual(RT[2].Length >= 7 ? (RT[2][7] . "") : "", "60",
		"the per-entry priority override must survive the cache round-trip (was dropped before the 9-column fix)")
	; The entry without an override must round-trip as empty (registrar then uses
	; the resolved section/source priority it receives).
	AssertEqual(RT[1].Length >= 7 ? (RT[1][7] . "") : "MISSING", "",
		"an entry without a priority override must round-trip as an empty column")
}
Test("hotstrings cache: per-entry priority survives the .tsv round-trip (per-entry-priority-divergence-cache-vs-toml)", _PriorityDivergence_RoundTripKeepsOverride)





; =======================================================
; =======================================================
; ======= 2/ Cache priority matches the TOML path =======
; =======================================================
; =======================================================

_PriorityDivergence_MatchesTomlFallback() {
	; The TOML fallback resolves an entry's priority via _ParseEntryPriority(Line,
	; ResolvedPriority): an inline `priority = N` beats the resolved default. The
	; cache build stores exactly that override (or "" when absent), so both paths
	; must agree on the same line.
	Line := Chr(34) . "cd" . Chr(34) . " = { output = " . Chr(34) . "second" . Chr(34)
		. ", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true, priority = 60 }"
	; _ParseEntryPriority is defined in toml_loader.ahk (in the include graph).
	AssertEqual(_ParseEntryPriority(Line, 10) . "", "60",
		"TOML fallback must read priority = 60 from the line")
	; The cache build stores the SAME override (using "" as the no-override sentinel).
	AssertEqual(_ParseEntryPriority(Line, "") . "", "60",
		"cache build must capture the same per-entry priority override the TOML fallback uses")
	; An entry without the key yields the empty sentinel for the cache and the
	; passed fallback for the TOML path - agreeing once the registrar applies the
	; resolved priority to the empty sentinel.
	NoOverride := Chr(34) . "ab" . Chr(34) . " = { output = " . Chr(34) . "first" . Chr(34)
		. ", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true }"
	AssertEqual(_ParseEntryPriority(NoOverride, "") . "", "",
		"cache build must store an empty sentinel when no per-entry priority is set")
}
Test("hotstrings cache: cached priority matches the TOML fallback (per-entry-priority-divergence-cache-vs-toml)", _PriorityDivergence_MatchesTomlFallback)

_PriorityDivergence_RejectsOverflowAliases() {
	Overflow := "18446744073709552116"
	Line := '"cd" = { output = "second", is_word = true, auto_expand = true, '
		. 'is_case_sensitive = true, final_result = true, priority = ' . Overflow . ' }'
	AssertEqual(10, _ParseEntryPriority(Line, 10),
		"an overflowing entry priority must use the caller's fallback")
	for BadPriority in [Overflow, "-1", "not-a-number"] {
		BadCache := "rolls`tassign`t`tcd`tsecond`t1`t0`t1`t" . BadPriority . "`n"
		AssertThrows(() => _HotstringsCacheReadTsv(BadCache),
			"an invalid derived-cache priority must force a TOML rebuild")
	}
}
Test("hotstrings priority: overflow cannot alias entry or cache rank",
	_PriorityDivergence_RejectsOverflowAliases)
