; tests/unit/test_altgr_owner_matrix.ahk

; ==============================================================================
; MODULE: One owner for every AltGr press, on every layout family
; DESCRIPTION:
; The standalone AltGr hotkeys (platform/remap/altgr.ahk) had inline #HotIf
; criteria no test could evaluate, and their text was only pinned by substring
; (altgr-owner-matrix-2026-09-26). Three defects hid there:
; - a standard AltGr layout held the key as AltGr with the suppressing
;   "SC01D & SC138": AHK's blocked RAlt-up made Windows release the fake LCtrl,
;   which cleared the prefix, so the whole AltGr layer was dead during the hold
;   (std-altgr-hold-passthrough-2026-09-26);
; - a tap-only AltGr passed through on AltGr layouts but was swallowed on
;   QWERTY and Kana layouts (altgr-tap-only-passthrough-2026-09-26);
; - a hold_layer offered by the hold picker had no AltGr owner at all.
; The criteria now live in altgr_criteria.ahk. The cases evaluate them for
; each family (_ALTGR_KANA_FIXUP; QWERTY shares the standard criteria and
; differs only in which label fires) and each configuration, and pin which
; hotkey labels each criterion governs.
; ==============================================================================

#Requires AutoHotkey v2.0

; The owner the criteria pick for Entry (an alt_gr tap_hold.toml row, or 0 for
; none) on a Kana (true) or standard (false) layout, with LayerEnabled and the
; wizard as given: "pass-through", "holds", "none", or "both" (a defect).
_AOM_Owner(Kana, Entry, Layer := false, Wizard := false) {
	global TapHold, LayerEnabled, _OB_ALTGR_PASSTHROUGH
	Saved := { TapHold: TapHold, Layer: LayerEnabled, Wizard: _OB_ALTGR_PASSTHROUGH,
		Family: _TestSetAltGrFamily(Kana) }
	try {
		TapHold := Map("keys", IsObject(Entry) ? Map("alt_gr", Entry) : Map(), "layers", Map())
		LayerEnabled := Layer
		_OB_ALTGR_PASSTHROUGH := Wizard
		Passes := AltGrOwnerPassesThrough(Kana)
		Holds := AltGrOwnerHolds(Kana)
		OtherFamily := AltGrOwnerPassesThrough(!Kana) or AltGrOwnerHolds(!Kana)
	} finally {
		TapHold := Saved.TapHold
		LayerEnabled := Saved.Layer
		_OB_ALTGR_PASSTHROUGH := Saved.Wizard
		_TestRestoreAltGrFamily(Saved.Family)
	}
	AssertFalse(OtherFamily, "the other family's variants must never own this family's AltGr press")
	return (Passes and Holds) ? "both" : Passes ? "pass-through" : Holds ? "holds" : "none"
}

_AOM_Row(Tap, Hold := "", Layer := "") {
	Entry := Map("time_activation_seconds", 0.2)
	if (Tap != "")
		Entry["tap_action"] := Tap
	if (Hold != "")
		Entry["hold_modifier"] := Hold
	if (Layer != "")
		Entry["hold_layer"] := Layer
	return Entry
}

_AOM_EveryConfigurationHasItsOwner() {
	global GESTURE_ACTIONS
	Assert(GESTURE_ACTIONS.Has("tab"), "prerequisite: the tab tap action must be in the catalogue")
	Cases := [
		["tap-only", _AOM_Row("tab"), "pass-through"],
		["AltGr held as AltGr (the default)", _AOM_Row("tab", "alt_gr"), "pass-through"],
		["AltGr held as AltGr, no tap", _AOM_Row("", "alt_gr"), "pass-through"],
		["AltGr held as Ctrl", _AOM_Row("tab", "ctrl"), "holds"],
		["AltGr held as Ctrl+AltGr", _AOM_Row("tab", "ctrl+alt_gr"), "holds"],
		["AltGr held as the navigation layer", _AOM_Row("tab", "", "nav"), "holds"],
		["no alt_gr tap-hold", 0, "none"],
	]
	for _, Kana in [false, true] {
		Family := Kana ? "Kana layout" : "standard AltGr layout or QWERTY"
		for _, Row in Cases
			AssertEqual(Row[3], _AOM_Owner(Kana, Row[2]), Family . ", " . Row[1])
		Disabled := _AOM_Row("tab", "ctrl")
		Disabled["enabled"] := 0
		AssertEqual("none", _AOM_Owner(Kana, Disabled), Family . ": a disabled tap-hold leaves AltGr native")
		AssertEqual("none", _AOM_Owner(Kana, _AOM_Row("tab", "ctrl"), true),
			Family . ": in the navigation layer its Escape owns the key")
		AssertEqual("none", _AOM_Owner(Kana, _AOM_Row("tab", "ctrl"), false, true),
			Family . ": the first-run wizard gets the host layout's native AltGr")
	}
}
Test("altgr owners: every configuration has one owner on every layout family (altgr-owner-matrix-2026-09-26)",
	_AOM_EveryConfigurationHasItsOwner)

; Each criterion governs the labels of its family and nothing else, with ~ on
; the pass-through ones: a standard layout's AltGr arrives as "SC01D & SC138",
; QWERTY's RAlt and the Kana AltGr as "*SC138" alone.
_AOM_CriteriaGovernTheirLabels() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Expected := Map(
		"#HotIf AltGrOwnerPassesThrough(false)", ["SC01D & ~SC138::", "~*SC138::"],
		"#HotIf AltGrOwnerPassesThrough(true)", ["~*$SC138::"],
		"#HotIf AltGrOwnerHolds(false)", ["SC01D & SC138::", "*SC138::"],
		"#HotIf AltGrOwnerHolds(true)", ["*$SC138::"])
	for HotIf, Labels in Expected {
		At := InStr(Src, HotIf . "`n")
		AssertTrue(At > 0, "altgr.ahk must declare " . HotIf)
		Next := InStr(Src, "#HotIf", , At + StrLen(HotIf))
		Block := SubStr(Src, At + StrLen(HotIf), Next - At - StrLen(HotIf))
		Found := []
		Pos := 1
		while RegExMatch(Block, "m)^([^\s;][^\r\n]*?::)", &M, Pos) {
			Found.Push(M[1])
			Pos := M.Pos + M.Len
		}
		AssertEqual(Labels.Length, Found.Length, HotIf . " must govern exactly its family's labels")
		for Index, Label in Labels
			AssertEqual(Label, Found[Index], HotIf . " label " . Index)
	}
}
Test("altgr owners: each criterion governs its family's labels, ~ on the pass-through ones (altgr-owner-matrix-2026-09-26)",
	_AOM_CriteriaGovernTheirLabels)

; A lone RAlt passed through is a plain Alt: its release would open the window
; menu, where the tap output lands, unless the mask goes out while it is down.
_AOM_LoneRAltIsMaskedWhileDown() {
	Body := _DriverFuncBody("_AltGrHandleLonePassThrough")
	MaskAt := InStr(Body, "TextSendMenuMask()")
	HoldAt := InStr(Body, "_AltGrHandleHold(true)")
	AssertTrue(MaskAt > 0 and HoldAt > MaskAt,
		"the lone RAlt must be masked before its owner waits for the release")
}
Test("altgr owners: a lone RAlt passed through is masked while it is down (altgr-tap-only-passthrough-2026-09-26)",
	_AOM_LoneRAltIsMaskedWhileDown)
