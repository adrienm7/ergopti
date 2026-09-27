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
; The fix left one path to the same dead layer: a combination holding AltGr
; (Shift+AltGr, Ctrl+AltGr, Alt+AltGr, AltGr+Win) still took the suppressing
; owner on a standard AltGr layout (std-altgr-combo-passthrough-2026-09-26).
; The criteria now live in altgr_criteria.ahk. The cases evaluate them for
; each family: a standard AltGr layout, QWERTY (the same _ALTGR_KANA_FIXUP and
; labels, no AltGr level in the boot probe) and a Kana layout, and for each
; configuration, and pin which hotkey labels each criterion governs.
; ==============================================================================

#Requires AutoHotkey v2.0

; The owner the criteria pick for Entry (an alt_gr tap_hold.toml row, or 0 for
; none) on layout Family ("standard", "qwerty" or "kana"), with LayerEnabled
; and the wizard as given: "pass-through", "holds", "none", or "both" (a
; defect).
_AOM_Owner(Family, Entry, Layer := false, Wizard := false) {
	global TapHold, LayerEnabled, _OB_ALTGR_PASSTHROUGH
	Kana := (Family == "kana")
	Saved := { TapHold: TapHold, Layer: LayerEnabled, Wizard: _OB_ALTGR_PASSTHROUGH,
		Family: _TestSetAltGrFamily(Kana, Family == "standard") }
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
		["AltGr held as Shift+Ctrl", _AOM_Row("tab", "shift+ctrl"), "holds"],
		["AltGr held as the navigation layer", _AOM_Row("tab", "", "nav"), "holds"],
		["no alt_gr tap-hold", 0, "none"],
	]
	for _, Family in ["standard", "qwerty", "kana"] {
		for _, Row in Cases
			AssertEqual(Row[3], _AOM_Owner(Family, Row[2]), Family . ", " . Row[1])
		Disabled := _AOM_Row("tab", "ctrl")
		Disabled["enabled"] := 0
		AssertEqual("none", _AOM_Owner(Family, Disabled), Family . ": a disabled tap-hold leaves AltGr native")
		AssertEqual("none", _AOM_Owner(Family, _AOM_Row("tab", "ctrl"), true),
			Family . ": in the navigation layer its Escape owns the key")
		AssertEqual("none", _AOM_Owner(Family, _AOM_Row("tab", "ctrl"), false, true),
			Family . ": the first-run wizard gets the host layout's native AltGr")
	}
}
Test("altgr owners: every configuration has one owner on every layout family (altgr-owner-matrix-2026-09-26)",
	_AOM_EveryConfigurationHasItsOwner)

; A combination that holds AltGr, on each family. On a standard AltGr layout
; the suppressing "SC01D & SC138" made AHK send a blocked RAlt-up, Windows
; answered with the fake LCtrl-up, the SC01D prefix was cleared and every
; "SC138 & X" (the AltGr layer, the rolls, AltGr+Enter...) was dead for the
; whole hold: AltGr held as Shift+AltGr then E typed the host layout's
; Shift+AltGr level of the base character. The key must pass through there, as
; with AltGr held as AltGr alone. QWERTY has no fake LCtrl and a Kana AltGr no
; RAlt, so their suppressing owner keeps the layer live and presses the whole
; combination.
_AOM_CombinationHoldingAltGrPassesThroughOnStandard() {
	for _, Hold in ["shift+alt_gr", "ctrl+alt_gr", "alt+alt_gr", "alt_gr+win"] {
		for _, Family in ["standard", "qwerty", "kana"] {
			AssertEqual(Family == "standard" ? "pass-through" : "holds", _AOM_Owner(Family, _AOM_Row("tab", Hold)),
				Family . ": AltGr held as " . Hold)
		}
	}
}
Test("altgr owners: a combination holding AltGr passes the key through on a standard AltGr layout (std-altgr-combo-passthrough-2026-09-26)",
	_AOM_CombinationHoldingAltGrPassesThroughOnStandard)

global _AOM_Sent := []
global _AOM_ClaimedAtDown := []

_AOM_Tick() => 1000
_AOM_Released(KeyName, TimeoutSec) => true
_AOM_KeyIsDown(KeyName) => false
_AOM_NoCancel(KeyId, GuardMs) => ""
_AOM_NotSuspended() => false

_AOM_Down(Key) {
	global _AOM_Sent, _AOM_ClaimedAtDown
	_AOM_Sent.Push("down " . _TH_SyntheticKeyLabel(Key))
	_AOM_ClaimedAtDown.Push(TapHoldPressIsOwned("alt_gr"))
	return true
}

_AOM_Up(Key) {
	global _AOM_Sent
	_AOM_Sent.Push("up " . _TH_SyntheticKeyLabel(Key))
	return true
}

; What the owner presses for a pass-through AltGr key whose hold is ModKey:
; its Downs and Ups, joined.
_AOM_PassThroughOwnerSends(ModKey) {
	global _TH_OwnedPresses, _AOM_Sent, _AOM_ClaimedAtDown
	_AOM_Sent := []
	_AOM_ClaimedAtDown := []
	Saved := _TH_OwnedPresses
	_TH_OwnedPresses := Map()
	try {
		Result := TapHoldOwnImmediateModifier("alt_gr", "SC138", ModKey, 0.2,
			_AOM_Released, _AOM_KeyIsDown, _AOM_Tick, _AOM_Down, _AOM_Up, _AOM_NoCancel, "RAlt", _AOM_NotSuspended)
		AssertTrue(Result["activated"] and Result["released"], "the pass-through hold must activate and end")
		AssertFalse(TapHoldPressIsOwned("alt_gr"), "no claim may remain after the press")
	} finally _TH_OwnedPresses := Saved
	for _, Owned in _AOM_ClaimedAtDown
		AssertFalse(Owned, "a pass-through press is never claimed: its repeat swallower would strand AltGr down")
	Out := ""
	for _, Line in _AOM_Sent
		Out .= (Out == "" ? "" : "|") . Line
	return Out
}

; The pass-through owner of a combination presses only the members the key is
; not: the physical AltGr (fake LCtrl + RAlt) already reached the system.
_AOM_PassThroughComboPressesOnlyTheOtherMembers() {
	AssertEqual("down LShift|up LShift", _AOM_PassThroughOwnerSends(["LShift", "RAlt"]),
		"AltGr held as Shift+AltGr presses Shift only")
	AssertEqual("down LCtrl+LWin|up LCtrl+LWin", _AOM_PassThroughOwnerSends(["LCtrl", "RAlt", "LWin"]),
		"every member but AltGr is pressed")
	AssertEqual("", _AOM_PassThroughOwnerSends("RAlt"), "AltGr held as AltGr alone presses nothing")
	AssertEqual("", _AOM_PassThroughOwnerSends(""), "a tap-only AltGr presses nothing")
	Owner := _DriverFuncBody("_AltGrHandleHold")
	AssertTrue(Owner != "", "the AltGr owner must be found")
	AssertTrue(InStr(Owner, "Passthrough ? KS_AltGrKeyName() : false)") > 0,
		"a pass-through AltGr owner must tell TapHoldOwnImmediateModifier that the key itself is the AltGr member")
}
Test("altgr owners: a pass-through combination presses only its other members (std-altgr-combo-passthrough-2026-09-26)",
	_AOM_PassThroughComboPressesOnlyTheOtherMembers)

; Each criterion governs the labels of its family and nothing else, with ~ on
; the pass-through ones and on every SC01D prefix (see test_altgr_takes_its_lctrl.ahk): a standard layout's AltGr arrives as "SC01D & SC138",
; QWERTY's RAlt and the Kana AltGr as "*SC138" alone.
_AOM_CriteriaGovernTheirLabels() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Expected := Map(
		"#HotIf AltGrOwnerPassesThrough(false)", ["~SC01D & ~SC138::", "~*SC138::"],
		"#HotIf AltGrOwnerPassesThrough(true)", ["~*$SC138::"],
		"#HotIf AltGrOwnerHolds(false)", ["~SC01D & SC138::", "*SC138::"],
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
