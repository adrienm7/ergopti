; tests/meta/test_hotstrings_cache_atomic_write.ahk

; ==============================================================================
; MODULE: Hotstrings Cache Atomic Write Meta Test
; DESCRIPTION:
; Static source guard for the "hotstrings-cache-non-atomic-write" audit finding
; in infra/hotstrings/hotstrings_cache.ahk.
;
; ROOT CAUSE ENCODED:
; _HotstringsCacheWriteTsv called FileDelete(TsvPath) then FileAppend(Content,
; TsvPath). Between these two operations the file is missing entirely. A crash,
; power loss, or concurrent second instance starting at that exact moment would
; leave the cache permanently absent or empty, forcing a cold rebuild from the
; TOML on every subsequent boot — and potentially corrupting the cache if
; FileAppend was partially written.
;
; The fix: write and flush TsvPath.tmp completely, verify its exact UTF-8 bytes,
; then publish it with a write-through atomic replacement. A stage that is only
; a valid prefix must never become a fresh-looking cache.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================================
; ===============================================================
; ======= 1/ HotstringsCacheWriteTsv uses a complete atomic stage ====
; ===============================================================
; ===============================================================

_HCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_HCA_UsesAtomicWrite() {
	Src := _HCA_ReadSource("infra/hotstrings/hotstrings_cache.ahk")
	Body := _DriverFuncBody("_HotstringsCacheWriteTsv")

	Assert(Body != "", "_HotstringsCacheWriteTsv must exist in hotstrings_cache.ahk")

	; The fix writes to a .tmp file first
	Assert(InStr(Body, ".tmp") > 0,
		"_HotstringsCacheWriteTsv must write to a .tmp intermediary (hotstrings-cache-non-atomic-write)")

	WritePos := InStr(Body, "FSWriteDurable(TmpPath, Content)")
	Assert(WritePos > 0,
		"_HotstringsCacheWriteTsv must use the complete durable stage writer (AHK-167)")
	if WritePos <= 0
		return
	VerifyPos := InStr(Body, "FSUtf8ExactMatches(TmpPath, Content)", true, WritePos)
	ReplacePos := InStr(Body, "FSAtomicMoveReplace(TmpPath, TsvPath)", true, VerifyPos)
	Assert(WritePos > 0 && VerifyPos > WritePos && ReplacePos > VerifyPos,
		"_HotstringsCacheWriteTsv must finish and verify its stage before atomic publication (AHK-167)")

	; The old two-step (FileDelete then FileAppend to the live path) must be gone
	Assert(!RegExMatch(Body, "FileDelete\(TsvPath\)\s*\r?\n\s*FileAppend"),
		"_HotstringsCacheWriteTsv must NOT use FileDelete(TsvPath)+FileAppend — use atomic FileMove (hotstrings-cache-non-atomic-write)")
}
Test("hotstrings_cache: a truncated stage cannot become a fresh cache (AHK-167)", _HCA_UsesAtomicWrite)
