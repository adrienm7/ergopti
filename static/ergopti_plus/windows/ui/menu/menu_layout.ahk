; ui/menu/menu_layout.ahk

; ==============================================================================
; MODULE: Tray Menu / Layout Submenu
; DESCRIPTION:
; Builds the Layout category entries (base layout features and AltGr layer features) straight into the parent menu from the manifest.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; List provider: Ergopti base-layer feature only (ergopti_base).
;
; A `list` since 2026-08-07, where both blocks were `dynamic` handlers handed the
; menu object. Every row here is a manifest feature — label, tick and greying all
; derived from the declaration by MenuRowFromManifest — so there was never
; anything for a handler to decide that data could not carry.
_LAY_LayoutFeatureBaseRows() {
	Rows := []
	for _, LayoutEntry in ManifestFeaturesForSection("layout") {
		if (LayoutEntry["id"] == "ergopti_base") {
			Row := MenuRowFromManifest(LayoutEntry, "Layout")
			if (Row != "") {
				Rows.Push(Row)
			}
		}
	}
	return Rows
}

; List provider: the Ergopti AltGr features (ergopti_alt_gr, ergopti_plus).
; The rows that work on any layout are declared on their own in the manifest's
; « any layout » section: direct_access_digits, and ctrl_magic_save after the
; magic-key replace option it depends on.
_LAY_LayoutFeatureAltGrRows() {
	static STANDALONE_IDS := Map("ergopti_base", true, "ctrl_magic_save", true,
		"direct_access_digits", true)
	Rows := []
	for _, LayoutEntry in ManifestFeaturesForSection("layout") {
		if !STANDALONE_IDS.Has(LayoutEntry["id"]) {
			Row := MenuRowFromManifest(LayoutEntry, "Layout")
			if (Row != "") {
				Rows.Push(Row)
			}
		}
	}
	return Rows
}


; ── Hotstrings dynamic handlers ────────────────────────────────────────────────

