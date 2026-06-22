; tests/meta/test_color_dropdown_recompute_index.ahk

; ==============================================================================
; MODULE: Color Dropdown Recompute Index Meta Test
; DESCRIPTION:
; Regression guard ensuring _HCW_PopulateFromEntry recomputes the color dropdown
; index AFTER rebuilding the dropdown, not before. Querying the index before
; rebuild and then calling RebuildColorDropdown returns a stale index because
; the rebuild may remove a previously injected custom entry, shifting all
; preset positions.
;
; SCOPE: source introspection of ui/hotstrings_config_window/init.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_CDRI_CheckIndexAfterRebuild() {
	; Move-resilient: scan the config-window folder via the framework helper
	; instead of a pinned path. Both call names are unique to this window, so
	; first-occurrence ordering still encodes the rebuild-then-index invariant
	; regardless of how ui/hotstrings_config_window is internally split.
	Src := _DriverDirConcat("ui/hotstrings_config_window")

	; Locate the color block — find the rebuild call then check that ColorIndexFor
	; is called after (higher byte offset) not before.
	RebuildPos := InStr(Src, "_HCW_RebuildColorDropdown")
	IndexPos   := InStr(Src, "_HCW_ColorIndexFor")

	Assert(RebuildPos > 0, "_HCW_RebuildColorDropdown must be present")
	Assert(IndexPos > 0,   "_HCW_ColorIndexFor must be present")

	; The first _HCW_ColorIndexFor call in _HCW_PopulateFromEntry must appear
	; AFTER the _HCW_RebuildColorDropdown call (higher position in source).
	Assert(IndexPos > RebuildPos,
		"_HCW_ColorIndexFor must be called after _HCW_RebuildColorDropdown — querying before rebuild returns a stale index")
}


Test("meta color-dropdown: index recomputed after rebuild, not before",
	_CDRI_CheckIndexAfterRebuild)