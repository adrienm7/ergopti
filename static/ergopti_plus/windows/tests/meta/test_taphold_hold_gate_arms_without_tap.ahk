; tests/meta/test_taphold_hold_gate_arms_without_tap.ahk

; ==============================================================================
; MODULE: Tap-Hold Hold-Gate Reachability (taphold-hold-option-unreachable)
; DESCRIPTION:
; The tray picker offers the same 32 hold options for every tap-hold key, and
; the writer, the loader, the persisted TOML and the menu checkmark all agree on
; what was chosen. Only the #HotIf gate disagreed: six hold gates additionally
; required a non-empty tap action, so picking « Natif / Rien » as the tap and a
; modifier (or the nav layer) as the hold matched NO variant at all. The choice
; persisted, got its checkmark, and the key stayed fully native.
;
; ROOT CAUSE ENCODED: tap and hold are independent settings, so a hold must arm
; on the hold alone. Eight keys (CapsLock, Space, Escape, Enter, Backspace,
; Delete, Win) always did; Left Alt, Right Ctrl and Tab carried the conjunct.
;
; SCOPE: source introspection. platform/remap/*.ahk register #HotIf hotkeys
; at load and cannot be #Included by the headless runner, so the gate text is
; scanned instead of being exercised.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================================
; =====================================================================
; ======= 1/ Derive the key set from source ===========================
; =====================================================================
; =====================================================================

; The picker's key ids come from _TH_KeyDefs. Reading them from source rather
; than hardcoding today's fourteen means a key added to the picker tomorrow is
; checked the day it is added — the failure mode this repo hits most often is
; an invariant fixed at one site with one sibling forgotten.
_THG_PickerKeyIds() {
	Src := _DriverSourceNoComments()
	Ids := []
	Pos := 1
	while (Pos := RegExMatch(Src, 'Map\("id",\s*"([a-z_]+)",\s*"i18n",\s*"tap_hold\.group\.', &M, Pos)) {
		Ids.Push(M[1])
		Pos += M.Len
	}
	return Ids
}




; =====================================================================
; =====================================================================
; ======= 2/ A hold gate must arm on the hold alone ===================
; =====================================================================
; =====================================================================

_THG_HoldGatesDoNotRequireATapAction() {
	Src := _DriverDirConcat("platform/remap")
	Ids := _THG_PickerKeyIds()
	Assert(Ids.Length > 0,
		"prerequisite: the tap-hold picker key ids must be derivable from _TH_KeyDefs — with none found this guard would check nothing")

	Examined := 0
	for Line in StrSplit(Src, "`n", "`r") {
		Gate := Trim(Line)
		if (SubStr(Gate, 1, 6) != "#HotIf")
			continue
		for _, Id in Ids {
			ModGate := 'TapHoldHoldModifier(TapHold, "' . Id . '") != ""'
			LayGate := 'TapHoldHoldLayer(TapHold, "' . Id . '") != ""'
			if (InStr(Gate, ModGate) = 0 and InStr(Gate, LayGate) = 0)
				continue
			Examined += 1
			TapGate := 'TapHoldTapAction(TapHold, "' . Id . '") != ""'
			Assert(InStr(Gate, TapGate) = 0,
				"key '" . Id . "': a hold gate must arm on the hold alone. Requiring a non-empty tap action makes tap = « Natif / Rien » + hold = <modifier|nav> match no #HotIf variant, so the hold the tray menu just persisted and checkmarked does nothing at all (taphold-hold-option-unreachable). Offending gate: " . Gate)
		}
	}
	Assert(Examined > 0,
		"prerequisite: at least one hold gate must have been examined — a scan that matches nothing proves nothing")
}
Test("tap-holds: a hold gate never requires a configured tap action (taphold-hold-option-unreachable)",
	_THG_HoldGatesDoNotRequireATapAction)




; =====================================================================
; =====================================================================
; ======= 3/ Every picker key owns its modifier immediately ===========
; =====================================================================
; =====================================================================

_THG_KeySourceFiles() {
	return Map(
		"escape", "escape.ahk", "tab", "tab.ahk",
		"caps_lock", "capslock.ahk", "left_shift", "lshift_lctrl.ahk",
		"left_ctrl", "lshift_lctrl.ahk", "win", "win.ahk",
		"left_alt", "lalt.ahk", "space", "space.ahk",
		"alt_gr", "altgr.ahk", "right_ctrl", "rctrl.ahk",
		"right_shift", "rshift.ahk", "enter", "enter.ahk",
		"backspace", "backspace.ahk", "delete", "delete.ahk")
}

_THG_KeyModifierResolvers() {
	return Map(
		"escape", "_EscapeHoldModKey()", "tab", "_TabHoldModKey()",
		"caps_lock", "_CapsLockHoldModKey()", "left_shift", "_LShiftHoldModKey()",
		"left_ctrl", "_LCtrlHoldModKey()", "win", "_WinHoldModKey()",
		"left_alt", "_LAltHoldModKey()", "space", "_SpaceHoldModKey()",
		"alt_gr", "_AltGrHoldModKey()", "right_ctrl", "_RCtrlHoldModKey()",
		"right_shift", "_RShiftHoldModKey()", "enter", "_EnterHoldModKey()",
		"backspace", "_BackspaceHoldModKey()", "delete", "_DeleteHoldModKey()")
}

_THG_EveryPickerKeyUsesTheImmediateModifierOwner() {
	Ids := _THG_PickerKeyIds()
	Assert(Ids.Length > 0, "prerequisite: the picker key ids must be derivable from _TH_KeyDefs")
	Files := _THG_KeySourceFiles()
	Resolvers := _THG_KeyModifierResolvers()
	SplitPath(A_ScriptDir, , &DriverRoot)
	AssertEqual(Ids.Length, Files.Count,
		"the immediate-modifier source inventory must name every picker key")
	for _, Id in Ids {
		Assert(Files.Has(Id), "missing source inventory for picker key '" . Id . "'")
		KeySrc := _StripFullLineComments(FileRead(DriverRoot . "\platform\remap\" . Files[Id], "UTF-8"))
		Assert(InStr(KeySrc, 'TapHoldHoldModifier(TapHold, "' . Id . '")') > 0,
			"key '" . Id . "' offers modifier holds but never reads the configured modifier")
		Assert(InStr(KeySrc, 'TapHoldOwnImmediateModifier("' . Id . '",') > 0,
			"key '" . Id . "' must synchronously enter the common modifier owner on physical key-down")
		OwnerPos := InStr(KeySrc, 'TapHoldOwnImmediateModifier("' . Id . '",')
		OwnerCall := SubStr(KeySrc, OwnerPos, 300)
		ResolverIsDirect := InStr(OwnerCall, Resolvers[Id]) > 0
		ResolverIsLocal := InStr(OwnerCall, ", ModKey,") > 0
			and InStr(SubStr(KeySrc, Max(1, OwnerPos - 200), 200), "ModKey := " . Resolvers[Id]) > 0
		Assert(ResolverIsDirect or ResolverIsLocal,
			"key '" . Id . "' must pass the live configured resolver into the common owner, not a hard-coded modifier")
	}
}
Test("tap-holds: every picker key uses immediate configured-modifier ownership (tap-hold-modifier-immediate)",
	_THG_EveryPickerKeyUsesTheImmediateModifierOwner)

_THG_SpecialTapBranchesYieldToConfiguredModifiers() {
	Cases := [
		{File: "lalt.ahk", Id: "left_alt", Action: "one_shot_shift"},
		{File: "lalt.ahk", Id: "left_alt", Action: "tab"},
		{File: "lalt.ahk", Id: "left_alt", Action: "alt_tab_monitor"},
		{File: "rctrl.ahk", Id: "right_ctrl", Action: "backspace"},
		{File: "rctrl.ahk", Id: "right_ctrl", Action: "tab"},
		{File: "rctrl.ahk", Id: "right_ctrl", Action: "one_shot_shift"},
		{File: "tab.ahk", Id: "tab", Action: "alt_tab_monitor"}
	]
	SplitPath(A_ScriptDir, , &DriverRoot)
	for Item in Cases {
		Src := _StripFullLineComments(FileRead(DriverRoot . "\platform\remap\" . Item.File, "UTF-8"))
		Needle := '#HotIf TapHoldTapAction(TapHold, "' . Item.Id . '") == "' . Item.Action . '"'
		Pos := InStr(Src, Needle)
		Assert(Pos > 0, Item.File . " must retain the special tap branch for " . Item.Action)
		GateEnd := InStr(Src, "`n", , Pos)
		Gate := SubStr(Src, Pos, GateEnd - Pos)
		Assert(InStr(Gate, 'TapHoldHoldModifier(TapHold, "' . Item.Id . '") == ""') > 0,
			Item.File . " special tap '" . Item.Action . "' must yield to a configured modifier owner instead of hard-coding its legacy hold")
	}
}
Test("tap-holds: special taps cannot bypass the configured modifier (tap-hold-modifier-immediate)",
	_THG_SpecialTapBranchesYieldToConfiguredModifiers)




; =====================================================================
; =====================================================================
; ======= 4/ Tab keeps its native tap =================================
; =====================================================================
; =====================================================================

; Tab's hold gates now arm without a configured tap, so _TabDispatch owns the
; native fallback: without it the SC00F hotkey would swallow the keystroke
; entirely whenever a hold is configured and the tap is « Natif / Rien ».
; Escape, Enter, Backspace, Delete and Space already resolve their tap this way.
_THG_TabDispatchFallsBackToNative() {
	Body := _DriverFuncBody("_TabDispatch")
	Assert(Body != "", "_TabDispatch must exist in platform/remap/tab.ahk")
	Assert(InStr(Body, "TextPressKey") > 0,
		"_TabDispatch must emit the native Tab when no tap action is configured — its hold gates arm on the hold alone, so an unhandled empty action turns the tap into a silent no-op instead of a Tab (taphold-hold-option-unreachable)")
	Assert(InStr(Body, "_TapHoldFireAction") > 0,
		"_TabDispatch must still route a configured tap action through the shared dispatcher")
}
Test("tap-holds: Tab still emits a native Tab when no tap action is configured (taphold-hold-option-unreachable)",
	_THG_TabDispatchFallsBackToNative)
