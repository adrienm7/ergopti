; tests/unit/test_freshness_same_second_edit_window.ahk

; ==============================================================================
; MODULE: Cache Same-Second Freshness Test
; DESCRIPTION:
; Regression test for finding freshness-same-second-edit-window.
;
; _HotstringsCacheIsFresh compared mtimes with a strict `>`: a bundled TOML
; re-saved in the SAME wall-clock second the .tsv was written tied the comparison
; and lost the freshness race, so the cache was served STALE and a legitimate
; TOML edit was silently ignored until a later boot where the mtimes differed.
;
; The fix flips the comparison to `>=` (a TOML whose mtime equals the .tsv's is
; treated as stale, forcing a rebuild - the safe direction). This test creates a
; temp shared tree with one bundled TOML and the cache .tsv, forces both mtimes to
; the identical second via FileSetTime, and asserts _HotstringsCacheIsFresh returns
; false (rebuild). Before the fix the strict `>` returned true (served stale).
;
; Behavioural: _HotstringsCacheIsFresh / _HotstringsCacheTomlPath /
; _HotstringsCacheTsvPath live in hotstrings_cache.ahk (in the run_all.ahk include
; graph) and only touch the filesystem on a temp path - no OS/COM/hotkey effects.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ Same-second tie must be judged stale ==========
; ==========================================================
; ==========================================================

_FreshSameSec_TieIsStale() {
	; Build an isolated temp shared tree so the real bundled TOMLs are untouched.
	; Only distancesreduction.toml exists here; _HotstringsCacheIsFresh skips the
	; other bundled categories via FileExist, so one TOML controls the verdict.
	Base := A_Temp . "\ergopti_freshness_samesecond_test"
	HsDir := Base . "\modules\hotstrings"
	try DirCreate(HsDir)

	global _SharedDir := Base
	TsvPath := _HotstringsCacheTsvPath()
	TomlPath := _HotstringsCacheTomlPath("distancesreduction")

	try {
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		FileAppend("# temp toml`n", TomlPath, "UTF-8")
		FileAppend("# temp tsv`n", TsvPath, "UTF-8")

		; Force both files to the EXACT same modification second (YYYYMMDDHH24MISS).
		SameSecond := "20240101120000"
		FileSetTime(SameSecond, TomlPath, "M")
		FileSetTime(SameSecond, TsvPath, "M")

		; A same-second TOML edit must NOT be served from the (equally old) cache:
		; the verdict must be "not fresh" so HotstringsCacheEnsure rebuilds.
		AssertFalse(_HotstringsCacheIsFresh(TsvPath),
			"a bundled TOML mtime equal to the .tsv mtime must be judged stale (rebuild) - the strict > comparison served a same-second edit stale")
	} finally {
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		try DirDelete(HsDir)
		try DirDelete(Base)
	}
}
Test("hotstrings cache: same-second TOML edit is judged stale, not fresh (freshness-same-second-edit-window)", _FreshSameSec_TieIsStale)


; ==========================================================
; ==========================================================
; ======= 2/ A strictly newer .tsv is still fresh ==========
; ==========================================================
; ==========================================================

_FreshSameSec_NewerTsvStillFresh() {
	; The fix must only catch the equal-second tie, not regress the normal case:
	; a .tsv strictly newer than every TOML is still fresh (no needless rebuild).
	Base := A_Temp . "\ergopti_freshness_newer_test"
	HsDir := Base . "\modules\hotstrings"
	try DirCreate(HsDir)

	global _SharedDir := Base
	TsvPath := _HotstringsCacheTsvPath()
	TomlPath := _HotstringsCacheTomlPath("distancesreduction")

	try {
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		FileAppend("# temp toml`n", TomlPath, "UTF-8")
		FileAppend("# temp tsv`n", TsvPath, "UTF-8")

		FileSetTime("20240101120000", TomlPath, "M")   ; older
		FileSetTime("20240101120005", TsvPath, "M")     ; 5 s newer

		AssertTrue(_HotstringsCacheIsFresh(TsvPath),
			"a .tsv strictly newer than the TOML must still be fresh (no spurious rebuild)")
	} finally {
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		try DirDelete(HsDir)
		try DirDelete(Base)
	}
}
Test("hotstrings cache: a strictly-newer .tsv is still fresh (freshness-same-second-edit-window)", _FreshSameSec_NewerTsvStillFresh)
