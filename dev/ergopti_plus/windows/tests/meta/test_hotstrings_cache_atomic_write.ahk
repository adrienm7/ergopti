; tests/meta/test_hotstrings_cache_atomic_write.ahk

; ==============================================================================
; MODULE: Hotstrings Cache Atomic Write Meta Test
; DESCRIPTION:
; Static source guard for the "hotstrings-cache-non-atomic-write" audit finding
; in lib/hotstrings/hotstrings_cache.ahk.
;
; ROOT CAUSE ENCODED:
; _HotstringsCacheWriteTsv called FileDelete(TsvPath) then FileAppend(Content,
; TsvPath). Between these two operations the file is missing entirely. A crash,
; power loss, or concurrent second instance starting at that exact moment would
; leave the cache permanently absent or empty, forcing a cold rebuild from the
; TOML on every subsequent boot — and potentially corrupting the cache if
; FileAppend was partially written.
;
; The fix: write to TsvPath.tmp first, then FileMove(TmpPath, TsvPath, 1)
; which is an atomic OS rename on Windows NTFS — the cache file is always
; either old or new, never absent.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================================
; ===============================================================
; ======= 1/ HotstringsCacheWriteTsv uses atomic FileMove =======
; ===============================================================
; ===============================================================

_HCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_HCA_UsesAtomicWrite() {
	Src := _HCA_ReadSource("lib/hotstrings/hotstrings_cache.ahk")
	Body := _DriverFuncBody("_HotstringsCacheWriteTsv")

	Assert(Body != "", "_HotstringsCacheWriteTsv must exist in hotstrings_cache.ahk")

	; The fix writes to a .tmp file first
	Assert(InStr(Body, ".tmp") > 0,
		"_HotstringsCacheWriteTsv must write to a .tmp intermediary (hotstrings-cache-non-atomic-write)")

	; Then atomically renames with FileMove
	Assert(InStr(Body, "FileMove") > 0,
		"_HotstringsCacheWriteTsv must call FileMove to atomically replace the TSV (hotstrings-cache-non-atomic-write)")

	; The old two-step (FileDelete then FileAppend to the live path) must be gone
	Assert(!RegExMatch(Body, "FileDelete\(TsvPath\)\s*\r?\n\s*FileAppend"),
		"_HotstringsCacheWriteTsv must NOT use FileDelete(TsvPath)+FileAppend — use atomic FileMove (hotstrings-cache-non-atomic-write)")
}
Test("hotstrings_cache: _HotstringsCacheWriteTsv uses atomic .tmp + FileMove (hotstrings-cache-non-atomic-write)", _HCA_UsesAtomicWrite)
