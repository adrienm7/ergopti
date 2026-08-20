; tests/meta/test_tap_hold_picker_catalog_path.ahk

; ==============================================================================
; MODULE: Tap-Hold Picker Catalogue Path Guard
; DESCRIPTION:
; Guards the shared hold-picker path against a literal tab replacing the
; leading `\t` of `\tap_hold`. That typo makes every modifier/layer read return
; an empty array, leaving only the "none" row in the user-visible picker.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Structural regression =======
; ========================================
; ========================================

_THPCP_SharedCataloguePathIsExact() {
	Body := _DriverFuncBody("_TH_ReadHoldPickerArray")
	Assert(Body != "",
		"_TH_ReadHoldPickerArray must remain source-visible")
	Body := _StripFullLineComments(Body)
	AssertContains(Body, '_SharedDir . "\tap_hold\defaults.toml"',
		"the Windows hold picker must read the real shared tap_hold catalogue")
	Assert(InStr(Body, Chr(9) . 'ap_hold\defaults.toml') == 0,
		"a literal tab in the catalogue suffix silently empties every hold option")

	global _SharedDir
	CataloguePath := _SharedDir . "\tap_hold\defaults.toml"
	Assert(FileExist(CataloguePath) != 0,
		"the exact production catalogue path must resolve to the shared defaults")
	Content := FileRead(CataloguePath, "UTF-8")
	Assert(InStr(Content, "[tap_hold.hold_picker]") > 0,
		"the resolved file must contain the hold-picker source section")
	Assert(RegExMatch(Content, "m)^modifiers\s*=\s*\[") > 0,
		"the resolved catalogue must expose modifier options")
	Assert(RegExMatch(Content, "m)^layers\s*=\s*\[") > 0,
		"the resolved catalogue must expose layer options")
}
Test("tap-hold picker: shared catalogue path cannot contain a literal tab "
	. "(tap-hold-picker-catalog-path)",
	_THPCP_SharedCataloguePathIsExact)
