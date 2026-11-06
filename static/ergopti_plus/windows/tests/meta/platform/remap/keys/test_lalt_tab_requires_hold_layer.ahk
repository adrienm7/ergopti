; tests/meta/platform/remap/keys/test_lalt_tab_requires_hold_layer.ahk

; ==============================================================================
; MODULE: LAlt Tab Tap Hold-Layer Gate Meta Test
; DESCRIPTION:
; Regression for AHK-002 / WI-001. Left Alt with tap "tab" and hold "none"
; (hold_modifier and hold_layer both empty) must behave as a plain tap, not
; activate navigation through TapHoldOwnImmediateLayer. The special Tab
; mechanics therefore require a configured hold layer, and the generic
; tap-only branch takes the key otherwise.
;
; Source scan: lalt.ahk registers top-level hotkeys and is not in the
; run_all.ahk include graph.
; ==============================================================================

#Requires AutoHotkey v2.0

_TMLT_TabSpecialRequiresHoldLayer() {
	Src := _DriverFileSource("lalt.ahk")
	Head := "#HotIf TapHoldTapAction(TapHold, " . Chr(34) . "left_alt" . Chr(34) . ") == " . Chr(34) . "tab" . Chr(34)
	Idx := InStr(Src, Head)
	Assert(Idx > 0, "lalt.ahk tab+layer block must exist")
	Line := SubStr(Src, Idx, InStr(Src, "`n", , Idx) - Idx)
	Assert(InStr(Line, "TapHoldHoldLayer(TapHold, " . Chr(34) . "left_alt" . Chr(34) . ") != " . Chr(34) . Chr(34)) > 0,
		"the Tab immediate-layer hotkey must require a configured hold layer")
	Fn := SubStr(Src, InStr(Src, "_LAltIsSpecialTap() {"), 600)
	Assert(RegExMatch(Fn, 'action == "tab" and TapHoldHoldLayer\(TapHold, "left_alt"\) != ""') > 0,
		"Tab is a special tap only with a hold layer; otherwise the generic tap-only branch handles it")
}
Test("tap_holds: lalt tab tap with hold none is a plain tap, not an immediate navigation layer (WI-001)", _TMLT_TabSpecialRequiresHoldLayer)
