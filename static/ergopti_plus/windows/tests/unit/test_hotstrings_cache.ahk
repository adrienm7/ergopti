; static/ergopti_plus/windows/tests/unit/test_hotstrings_cache.ahk

; ==============================================================================
; MODULE: Hotstrings Self-Healing Cache Tests
; DESCRIPTION:
; Pins the behaviour of infra/hotstrings/hotstrings_cache.ahk — the gitignored .tsv
; cache that replaced the committed generated_*.ahk bundle. The bundled-hotstring
; registration path had NO end-to-end coverage in the headless suite before this;
; these tests are that safety net.
;
; WHY THIS MATTERS (the regressions this encodes):
;   1. Build parity: _HotstringsCacheBuildRows must extract the SAME rows the old
;      generated bundle did. It parses the real bundled TOMLs with the identical
;      line scan + _HOTSTRING_ENTRY_PATTERN the runtime TOML fallback uses, so a
;      regex / flag-logic drift would silently drop or mis-flag thousands of
;      everyday expansions. A specific stable entry and a non-trivial total floor
;      catch that.
;   2. Lossless round-trip: write -> read of the .tsv must preserve every row
;      exactly, including triggers/outputs carrying backslashes and quotes. A
;      broken escape/unescape would corrupt expansions only on the FAST (cached)
;      path — invisible on first launch — so it is pinned here.
;
; SCOPE: drives the real cache module against the real shared TOMLs through the
;   test harness (which supplies UnescapeTomlString, the entry pattern and a
;   ScriptInformation stub). ASCII-only per the suite convention.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Test helpers =======
; ===============================
; ===============================

; Point the cache at the real shared hotstrings tree (static/ergopti_plus/_shared)
; resolved relative to the tests directory, so the build reads the genuine TOMLs.
_HsCacheTestSharedDir() {
	SplitPath(A_ScriptDir, , &WindowsDir)   ; ...\windows
	SplitPath(WindowsDir, , &DriversDir)    ; ...\ergopti_plus
	return DriversDir . "\_shared"
}

; Deep-compare two cache rows ([flags, trigger, output, final, repeat, caseSens]).
_HsCacheRowsEqual(A, B) {
	if (A.Length != B.Length)
		return false
	for Idx, Val in A {
		if (B[Idx] != Val)
			return false
	}
	return true
}





; =====================================
; =====================================
; ======= 2/ Test registrations =======
; =====================================
; =====================================

TestHsCache_BuildExtractsKnownEntry() {
	global _SharedDir := _HsCacheTestSharedDir()
	Rows := _HotstringsCacheBuildRows()

	Assert(Rows.Count > 0, "cache build must yield at least one section")
	Assert(Rows.Has("rolls.assign"), "cache build must contain the stable rolls.assign section")

	AssignRows := Rows["rolls.assign"]
	Assert(AssignRows.Length == 4, "rolls.assign must register exactly 4 entries (got " . AssignRows.Length . ")")
	; First TOML entry is  ' #!' = { output = ' := ', is_word=false, auto_expand=true,
	; is_case_sensitive=true, final_result=true }  -> flags *? and caseSens true.
	; The 7th element is the per-entry priority override, empty here (no `priority =`).
	Expected := ["*?", " #!", " := ", true, false, true, ""]
	Assert(_HsCacheRowsEqual(AssignRows[1], Expected),
		"rolls.assign first row must extract as [*?, ' #!', ' := ', final, !repeat, caseSens, no-priority-override]")
}

TestHsCache_BuildCoversEveryBundledCategory() {
	global _SharedDir := _HsCacheTestSharedDir()
	Rows := _HotstringsCacheBuildRows()

	; Sum rows per top-level category and assert each bundled category contributed.
	Totals := Map()
	Grand := 0
	for Key, RowList in Rows {
		Cat := StrSplit(Key, ".", , 2)[1]
		Totals[Cat] := (Totals.Has(Cat) ? Totals[Cat] : 0) + RowList.Length
		Grand += RowList.Length
	}
	for Cat in ["distancesreduction", "sfbsreduction", "rolls", "autocorrection", "magickey"]
		Assert(Totals.Has(Cat) and Totals[Cat] > 0, "bundled category '" . Cat . "' must contribute rows")
	; Floor well below the ~2992 current total: a builder that silently drops most
	; entries (regex/flag regression) fails here, while legitimate TOML edits pass.
	Assert(Grand > 2000, "cache build total must stay in the thousands (got " . Grand . ")")
}

TestHsCache_TsvRoundTripIsLossless() {
	global _SharedDir := _HsCacheTestSharedDir()
	Rows := _HotstringsCacheBuildRows()

	TmpTsv := A_Temp . "\ergopti_hscache_test.tsv"
	_HotstringsCacheWriteTsv(TmpTsv, Rows)
	Back := _HotstringsCacheReadTsv(FileRead(TmpTsv, "UTF-8"))
	try FileDelete(TmpTsv)

	Assert(Back.Count == Rows.Count,
		"round-trip must preserve every section (" . Back.Count . " vs " . Rows.Count . ")")
	; Deep-check rolls.assign survived byte-for-byte (its outputs contain spaces).
	Assert(Back.Has("rolls.assign"), "round-trip must keep rolls.assign")
	Orig := Rows["rolls.assign"]
	RT := Back["rolls.assign"]
	Assert(RT.Length == Orig.Length, "rolls.assign row count must survive round-trip")
	AllEqual := true
	for Idx, Row in Orig {
		if !_HsCacheRowsEqual(Row, RT[Idx])
			AllEqual := false
	}
	Assert(AllEqual, "every rolls.assign row must be identical after a write/read round-trip")
}

TestHsCache_EscapeUnescapeHandlesSpecials() {
	; A value carrying every escape-sensitive character must survive the round-trip:
	; backslash (escaped first), tab (the column delimiter), CR and LF.
	Original := "a\b" . Chr(9) . "c" . Chr(13) . "d" . Chr(10) . "e"
	Escaped := _HsCacheEscape(Original)
	Assert(!InStr(Escaped, Chr(9)), "escaped value must not contain a raw tab (would break the column split)")
	Assert(!InStr(Escaped, Chr(10)), "escaped value must not contain a raw newline")
	Assert(_HsCacheUnescape(Escaped) == Original, "unescape(escape(x)) must equal x for all special characters")
}

TestHsCache_PriorityDomainRejectsCorruptRow() {
	Corrupt := "rolls`tassign`t*?`ta`tb`t0`t0`t0`t101`n"
	AssertThrows(() => _HotstringsCacheReadTsv(Corrupt),
		"cache priority above 100 must invalidate the cache instead of reaching registration")
}

Test("hotstrings cache: build extracts a known entry with correct flags", TestHsCache_BuildExtractsKnownEntry)
Test("hotstrings cache: build covers every bundled category", TestHsCache_BuildCoversEveryBundledCategory)
Test("hotstrings cache: .tsv write/read round-trip is lossless", TestHsCache_TsvRoundTripIsLossless)
Test("hotstrings cache: escape/unescape handles tab, CR, LF and backslash", TestHsCache_EscapeUnescapeHandlesSpecials)
Test("hotstrings cache: priority domain rejects a corrupt row",
	TestHsCache_PriorityDomainRejectsCorruptRow)
