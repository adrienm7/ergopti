; tests/unit/infra/config/persistence/test_freshness_same_second_edit_window.ahk

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
; The cache now verifies captured source receipts. Reproduce a real source
; edit while retaining an equal timestamp: timestamp equality alone neither
; admits stale rows nor invalidates unchanged rows. Both fixtures publish their
; initial candidate through the genuine source builder and durable TSV writer.
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
	; Only magickey.toml exists here; the genuine builder captures every other
	; declared source as absent in the same canonical inventory.
	Base := A_Temp . "\ergopti_freshness_samesecond_test"
	HsDir := Base . "\modules\hotstrings"
	try DirCreate(HsDir)

	; Save the real shared root: this global is process-wide, and every later
	; test that resolves a bundled file through it would otherwise be pointed at
	; this temp tree for the rest of the suite.
	global _SharedDir
	_FreshSameSec_PrevShared := _SharedDir
	_SharedDir := Base
	; The cache paths resolve through the language index, so it must exist first.
	IndexPath := HsDir . "\_index.toml"
	FileCopy(_FreshSameSec_PrevShared . "\modules\hotstrings\_index.toml", IndexPath, true)
	FileSetTime("20240101115900", IndexPath, "M")
	TsvPath := _HotstringsCacheTsvPath()
	TomlPath := _HotstringsCacheTomlPath("magickey")

	try {
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		FileAppend('[[ct]]`n"beforeprobe" = { output = "Before", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = true }`n', TomlPath, "UTF-8")
		_HotstringsCacheWriteTsv(TsvPath, _HotstringsCacheBuildRows())

		; Physically edit the source after its old rule has entered the real cache.
		AssertTrue(_HotstringsCacheIsFresh(TsvPath), "the initial complete receipt must admit its unchanged source")
		AssertTrue(FSWriteDurable(TomlPath,
			'[[ct]]`n"afterprobe" = { output = "After", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = true }`n'))
		; Force both files to the EXACT same modification second (YYYYMMDDHH24MISS).
		SameSecond := "20240101120000"
		FileSetTime(SameSecond, TomlPath, "M")
		FileSetTime(SameSecond, TsvPath, "M")

		; A same-second TOML edit must NOT be served from the (equally old) cache:
		; the verdict must be "not fresh" so HotstringsCacheEnsure rebuilds.
		AssertFalse(_HotstringsCacheIsFresh(TsvPath),
			"a changed authoritative source must invalidate its real earlier cache even when the timestamps are equal")
	} finally {
		_SharedDir := _FreshSameSec_PrevShared
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		try FileDelete(IndexPath)
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

	; Save the real shared root: this global is process-wide, and every later
	; test that resolves a bundled file through it would otherwise be pointed at
	; this temp tree for the rest of the suite.
	global _SharedDir
	_FreshSameSec_PrevShared := _SharedDir
	_SharedDir := Base
	; The cache paths resolve through the language index, so it must exist first.
	IndexPath := HsDir . "\_index.toml"
	FileCopy(_FreshSameSec_PrevShared . "\modules\hotstrings\_index.toml", IndexPath, true)
	FileSetTime("20240101115900", IndexPath, "M")
	TsvPath := _HotstringsCacheTsvPath()
	TomlPath := _HotstringsCacheTomlPath("magickey")

	try {
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		FileAppend('[[ct]]`n"beforeprobe" = { output = "Before", is_word = true, auto_expand = false, is_case_sensitive = false, final_result = true }`n', TomlPath, "UTF-8")
		_HotstringsCacheWriteTsv(TsvPath, _HotstringsCacheBuildRows())

		FileSetTime("20240101120000", TomlPath, "M")   ; older
		FileSetTime("20240101120005", TsvPath, "M")     ; 5 s newer

		AssertTrue(_HotstringsCacheIsFresh(TsvPath),
			"a .tsv strictly newer than the TOML must still be fresh (no spurious rebuild)")
	} finally {
		_SharedDir := _FreshSameSec_PrevShared
		try FileDelete(TsvPath)
		try FileDelete(TomlPath)
		try FileDelete(IndexPath)
		try DirDelete(HsDir)
		try DirDelete(Base)
	}
}
Test("hotstrings cache: a strictly-newer .tsv is still fresh (freshness-same-second-edit-window)", _FreshSameSec_NewerTsvStillFresh)
