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
; ======= 3/ Ratchet on keys with no hold gate at all =================
; =====================================================================
; =====================================================================

; Left Shift, Left Ctrl and Right Shift never read TapHoldHoldModifier /
; TapHoldHoldLayer: their hold is whatever the `~` passthrough gives, i.e. the
; key's own native modifier. Alt Gr has no hold concept at all (its gate is
; TapHoldIsConfigured). The picker still offers all 32 hold options for them,
; which is a real open defect — closing it means either honouring the choice
; (dropping the `~` and suppressing the physical modifier on three very hot
; keys) or filtering the picker in platform/remap + ui/menu. Until that is
; decided, this ratchet at least stops the class from GROWING: a new key added
; to the picker without a hold gate fails here.
_THG_KnownKeysWithoutHoldGate() {
	return Map("left_shift", true, "left_ctrl", true, "right_shift", true, "alt_gr", true)
}

_THG_NoNewKeyWithoutAHoldGate() {
	Src := _DriverDirConcat("platform/remap")
	Known := _THG_KnownKeysWithoutHoldGate()
	Ids := _THG_PickerKeyIds()
	Assert(Ids.Length > 0, "prerequisite: the picker key ids must be derivable from _TH_KeyDefs")

	Covered := 0
	for _, Id in Ids {
		Reads := (InStr(Src, 'TapHoldHoldModifier(TapHold, "' . Id . '")') > 0
			or InStr(Src, 'TapHoldHoldLayer(TapHold, "' . Id . '")') > 0)
		if Reads {
			Covered += 1
			continue
		}
		Assert(Known.Has(Id),
			"key '" . Id . "' is offered a hold picker in the tray menu but no #HotIf in platform/remap reads TapHoldHoldModifier or TapHoldHoldLayer for it — the selection persists, gets a checkmark and does nothing (taphold-hold-option-unreachable)")
	}
	Assert(Covered > 0,
		"prerequisite: at least one key must actually read its hold configuration")
}
Test("tap-holds: no new picker key ships without a hold gate (taphold-hold-option-unreachable)",
	_THG_NoNewKeyWithoutAHoldGate)




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
