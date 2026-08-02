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




; Dynamic handler: Ergopti base-layer feature only (ergopti_base).
_LAY_LayoutFeaturesBase(M, _Cat) {
	for _, LayoutEntry in ManifestFeaturesForSection("layout") {
		if (LayoutEntry["id"] == "ergopti_base") {
			MenuAddItemFromManifest(M, LayoutEntry, "Layout")
		}
	}
}

; Dynamic handler: AltGr / digit-shift features (direct_access_digits,
; ergopti_alt_gr, ergopti_plus) — usable without the Ergopti base layer.
; ctrl_magic_save is excluded here: it is placed explicitly at the bottom of
; the layout menu, after the magic-key replace option it depends on.
_LAY_LayoutFeaturesAltGr(M, _Cat) {
	static STANDALONE_IDS := Map("ergopti_base", true, "ctrl_magic_save", true)
	for _, LayoutEntry in ManifestFeaturesForSection("layout") {
		if !STANDALONE_IDS.Has(LayoutEntry["id"]) {
			MenuAddItemFromManifest(M, LayoutEntry, "Layout")
		}
	}
}


; ── Hotstrings dynamic handlers ────────────────────────────────────────────────

