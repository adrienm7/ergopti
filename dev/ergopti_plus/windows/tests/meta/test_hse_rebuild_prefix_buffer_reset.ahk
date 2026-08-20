; tests/meta/test_hse_rebuild_prefix_buffer_reset.ahk

; ==============================================================================
; MODULE: HSE Rebuild Prefix Buffer Reset Meta Test
; DESCRIPTION:
; Static source guard for the hse-rebuild-stale-prefix-buffer finding.
;
; The live rebuild intentionally yields for ~1.3 seconds. Its final engine and
; preview resets therefore cannot be two adjacent statements: a queued OnChar
; may run between them and leave the engine one character ahead. Both must flow
; through the short Critical input-context transaction.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Pairing assertion ======================
; ===================================================
; ===================================================

_HRPBR_RebuildResetsPrefixBuffer() {
	Body := _DriverFuncBody("_RebuildHotstringsLiveOnce")
	Assert(Body != "", "the serialized live-rebuild pass must exist in ui/menu/menu_rebuild.ahk")
	Assert(InStr(Body, "_PrefixInvalidateInputContext(0, false)") > 0,
		"the yielded rebuild must atomically reset engine + preview with unknown left context")
	Assert(InStr(Body, "HSE_HardReset") == 0 and InStr(Body, "_ResetPrefixBuffer") == 0,
		"the yielded rebuild must not restore a raw two-statement reset window")
}
Test("menu_rebuild: yielded rebuild resets both buffers atomically (hse-rebuild-stale-prefix-buffer)", _HRPBR_RebuildResetsPrefixBuffer)
