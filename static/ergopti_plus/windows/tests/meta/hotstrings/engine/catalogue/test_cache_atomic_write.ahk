; tests/meta/hotstrings/engine/catalogue/test_cache_atomic_write.ahk

; ==============================================================================
; MODULE: Hotstrings Cache Atomic Write Meta Test
; DESCRIPTION:
; Static source guard for the "hotstrings-cache-non-atomic-write" audit finding
; in hotstrings/engine/catalogue/cache.ahk.
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

_HCA_ReadSource(FileName) {
	return _DriverFileSource(FileName)
}

_HCA_UsesAtomicWrite() {
	; Real public cold Ensure, original stage factory, native prefix write and
	; SetEndOfFile(1), then the actual held-stage verifier and rename owner.
	; Valid TOML must still load while that corrupt cache publication refuses.
	_HCOW_PublicEnsure(false, true)
}
Test("hotstrings_cache: a truncated stage cannot become a fresh cache (AHK-167)", _HCA_UsesAtomicWrite)
