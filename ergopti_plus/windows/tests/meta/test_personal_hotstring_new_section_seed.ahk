; tests/meta/test_personal_hotstring_new_section_seed.ahk

; ==============================================================================
; MODULE: Personal-Hotstring New-Section Live-Toggle Seed Meta Test
; DESCRIPTION:
; Static source guard for finding F4 (personal-hotstring-live-toggle-seed).
;
; A personal-hotstring section created live via the editor's "Nouvelle section"
; button was never seeded into Features["hotstrings"]["personal"] — only the
; boot-time pass (ErgoptiPlus.ahk) and the bulk enable/disable-all path
; (HS_TogglePersonalAllSections) called EnsurePersonalHotstringFeature. Reopening
; the tray menu and toggling the brand-new section's checkbox therefore called
; _HS_TryLiveToggleV2 -> WriteFeatureV2 on an unresolved v2 path: WriteFeatureV2
; returned false with ZERO logging, and the caller ignored the return value,
; rebuilt the (unchanged) hotstring engine, and reported success.
;
; The fix seeds the Features node right where the section is created
; (_NewSection), and adds two defensive backstops mirroring the existing
; manifest-driven code path: WriteFeatureV2 now logs a WARNING on an unresolved
; path (like its sibling WriteFeatureBatchV2 already does), and
; MenuRowWithLabel now skips (with a WARNING) an item whose feature does not
; resolve, mirroring MenuRowFromManifest's guard.
; ==============================================================================

#Requires AutoHotkey v2.0




_PHNS_AssertNewSectionSeeds() {
	Body := _DriverFuncBody("_NewSection")
	Assert(Body != "", "_NewSection() declaration must exist in ui/personal_toml_editor.ahk")
	Assert(InStr(Body, "EnsurePersonalHotstringFeature(SecName)") > 0,
		"_NewSection must seed the brand-new section into Features before the tray menu can ever toggle it live (personal-hotstring-live-toggle-seed)")
}
Test("editor: _NewSection seeds the Features node for a brand-new section (personal-hotstring-live-toggle-seed)",
	_PHNS_AssertNewSectionSeeds)

_PHNS_AssertMenuRowWithLabelGuarded() {
	Body := _DriverFuncBody("MenuRowWithLabel")
	Assert(Body != "", "MenuRowWithLabel() declaration must exist in ui/menu/menu_engine.ahk")
	Assert(InStr(Body, "FeatureLocateV2(Features, V2Path) == false") > 0,
		"MenuRowWithLabel must skip an item whose feature does not resolve, mirroring MenuRowFromManifest's guard (personal-hotstring-live-toggle-seed)")
}
Test("menu: MenuRowWithLabel skips an unresolved v2 path instead of wiring a dead toggle (personal-hotstring-live-toggle-seed)",
	_PHNS_AssertMenuRowWithLabelGuarded)
