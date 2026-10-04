; tests/unit/test_tap_hold_hand_sections.ahk

; ==============================================================================
; MODULE: Tap-Hold Keys Listed By Hand
; DESCRIPTION:
; The Tap-Hold submenu lists its keys under « Main gauche (tap/hold) » and
; « Main droite (tap/hold) », with a separator between the two hands. Which
; key goes under which hand is the shared key catalogue's ([tap_hold.catalog]
; in _shared/tap_hold/defaults.toml), read by TapHoldKeyDefs().
;
; ROOT CAUSE ENCODED: _TH_KeyDefs was a hardcoded array claiming to mirror a
; menu-manifest `tap_hold_keys_catalog` that never existed, and this menu had
; one undivided key list with no hand at all. The real manifest is rendered
; here with rows named by key id, so the headers, the separator and the order
; are the ones the tray draws.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Native menu readers =======
; ======================================
; ======================================

; The text of the row at a zero-based position.
_THHS_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Buffer_ := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Buffer_, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Buffer_, "UTF-16")
}

; Zero-based position of the first row labelled exactly Label, or -1.
_THHS_PositionOf(TargetMenu, Label) {
	loop TrayMenuItemCount(TargetMenu) {
		if !TrayMenuIsSeparatorAt(TargetMenu, A_Index - 1)
				&& _THHS_LabelAt(TargetMenu, A_Index - 1) == Label
			return A_Index - 1
	}
	return -1
}

; Renders the real tap_holds_menu declaration with one inert row per key,
; labelled by the key's id, under the provider of its hand.
_THHS_Render() {
	Inert := (*) => ""
	Providers := Map(
		"tap_hold_keys_left", (*) => _THHS_KeyIdRows("left", Inert),
		"tap_hold_keys_right", (*) => _THHS_KeyIdRows("right", Inert))
	Commands := Map("tapholds_toggle", Inert, "scope_restore", Inert,
		"scope_clear", Inert, "edit_nav_layer", Inert)
	return MenuRenderer_Build("tap_holds_menu", "TapHolds", "", "", Providers, Commands,
		Map("tapholds_enabled", () => false))
}

; One row per key of a hand, labelled by its id.
_THHS_KeyIdRows(Hand, Action) {
	Out := []
	for _, KeyDef in TapHoldKeyDefsOfHand(Hand)
		Out.Push(Map("label", KeyDef["id"], "action", Action))
	return Out
}





; ===========================================
; ===========================================
; ======= 2/ The catalogue's hands ==========
; ===========================================
; ===========================================

_THHS_CatalogueSplitsTheHands() {
	LeftKeys := TapHoldKeyDefsOfHand("left")
	RightKeys := TapHoldKeyDefsOfHand("right")
	AssertEqual(14, TapHoldKeyDefs().Length, "the Windows column of [tap_hold.catalog]")
	AssertEqual(TapHoldKeyDefs().Length, LeftKeys.Length + RightKeys.Length, "every key has a hand")
	AssertEqual("space", LeftKeys[LeftKeys.Length]["id"], "Space ends the left hand")
	AssertEqual("alt_gr", RightKeys[1]["id"], "AltGr opens the right hand")
	for _, KeyDef in TapHoldKeyDefs()
		Assert(InStr(KeyDef["i18n"], "tap_hold.group.") == 1, "key '" . KeyDef["id"] . "' is labelled from the catalogue")
}
Test("tap-holds: the shared key catalogue gives every Windows key a hand (tap-hold-hand-sections)",
	_THHS_CatalogueSplitsTheHands)

_THHS_MenuSeparatesTheHands() {
	Rendered := _THHS_Render()
	try {
		LeftHeader := _THHS_PositionOf(Rendered, MenuSectionTitle(t("menu.tapholds.left_hand_tap_hold")))
		RightHeader := _THHS_PositionOf(Rendered, MenuSectionTitle(t("menu.tapholds.right_hand_tap_hold")))
		Assert(LeftHeader >= 0, "the « Main gauche (tap/hold) » header is drawn")
		Assert(RightHeader > LeftHeader, "the « Main droite (tap/hold) » header follows it")
		SpaceRow := _THHS_PositionOf(Rendered, "space")
		Assert(SpaceRow > LeftHeader && SpaceRow < RightHeader, "Space is listed under the left hand")
		Assert(TrayMenuIsSeparatorAt(Rendered, SpaceRow + 1),
			"the row after the last left-hand key (Space) is a separator")
		AssertEqual(RightHeader, SpaceRow + 2, "the right-hand header follows that separator")
		AssertEqual("alt_gr", _THHS_LabelAt(Rendered, RightHeader + 1),
			"the first right-hand key row is AltGr")
		Assert(_THHS_PositionOf(Rendered, MenuSectionTitle("Tap / Hold")) < 0,
			"no « — Tap / Hold — » header of its own")
	} finally {
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
	}
}
Test("tap-holds: the submenu separates the left-hand keys from the right-hand keys (tap-hold-hand-sections)",
	_THHS_MenuSeparatesTheHands)
