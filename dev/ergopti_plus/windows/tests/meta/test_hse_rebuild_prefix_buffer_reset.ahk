; tests/meta/test_hse_rebuild_prefix_buffer_reset.ahk

; ==============================================================================
; MODULE: HSE Rebuild Prefix Buffer Reset Meta Test
; DESCRIPTION:
; Static source guard for the hse-rebuild-stale-prefix-buffer finding.
;
; Every production call site that invokes HSE_HardReset() must pair it with
; _ResetPrefixBuffer() (see LLM_Bridge_OnAccept and the inline auto-type block
; in modules/llm) so the tooltip preview buffer never diverges from the real
; HSE matching engine. RebuildHotstringsLive() was the sole call site missing
; the pairing, desyncing the tooltip preview after any live hotstring-section
; toggle.
;
; The fix adds a _ResetPrefixBuffer() call immediately alongside the existing
; HSE_HardReset() call in RebuildHotstringsLive() (ui/menu/menu_rebuild.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Pairing assertion ======================
; ===================================================
; ===================================================

_HRPBR_RebuildResetsPrefixBuffer() {
	Body := _DriverFuncBody("RebuildHotstringsLive")
	Assert(Body != "", "RebuildHotstringsLive must exist in ui/menu/menu_rebuild.ahk")
	Assert(InStr(Body, "HSE_HardReset") > 0,
		"RebuildHotstringsLive must call HSE_HardReset() after re-registering the hotstrings")
	Assert(InStr(Body, "_ResetPrefixBuffer") > 0,
		"RebuildHotstringsLive must call _ResetPrefixBuffer() alongside HSE_HardReset() so the tooltip preview buffer does not desync from the rebuilt matching engine (hse-rebuild-stale-prefix-buffer)")
}
Test("menu_rebuild: RebuildHotstringsLive pairs HSE_HardReset with _ResetPrefixBuffer (hse-rebuild-stale-prefix-buffer)", _HRPBR_RebuildResetsPrefixBuffer)
