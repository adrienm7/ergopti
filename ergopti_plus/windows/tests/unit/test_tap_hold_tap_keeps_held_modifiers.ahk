; tests/unit/test_tap_hold_tap_keeps_held_modifiers.ahk

; ==============================================================================
; MODULE: Tap-hold keystroke taps keep the held modifiers
; DESCRIPTION:
; Shift held, then a tap of AltGr (tap = Tab) must give Shift+Tab, as pressing
; Tab would. Every keystroke tap was sent as a bare "{Tab}" without {Blind}, and
; AutoHotkey lifts a modifier held on another key around such a Send: the
; application received a plain Tab (measured in the user's log: 18 of 18 AltGr
; taps under a held Shift dispatched "{Tab}"). A modifier held by another
; tap-hold survived only because AHK never lifts the ones it pressed itself, so
; the result depended on where the modifier came from
; (held-modifier-tap-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================
; =============================================
; ======= 1/ Capture helpers ==================
; =============================================
; =============================================

; Runs Fn with the modifiers in HeldNames reported logically down and returns
; every SendInput payload it produced.
_THKM_Capture(HeldNames, Fn) {
	global _AHK_SendInput, _TapHoldModifierIsHeld
	PreviousSend := _AHK_SendInput
	PreviousHeld := _TapHoldModifierIsHeld
	Sent := []
	Held := Map()
	for _, Name in HeldNames
		Held[Name] := true
	_AHK_SendInput := (Keys) => (Sent.Push(Keys), Keys)
	_TapHoldModifierIsHeld := (Name) => Held.Has(Name)
	try {
		Fn.Call()
	} finally {
		_AHK_SendInput := PreviousSend
		_TapHoldModifierIsHeld := PreviousHeld
	}
	return Sent
}

; Fires KeyId's tap with ActionId configured, through the real dispatch gate.
_THKM_FireTap(KeyId, ActionId, HeldNames) {
	global TapHold, _TH_TapHoldTrackState
	PreviousTapHold := TapHold
	TapHold := Map("keys", Map(KeyId, Map(
		"tap_action", ActionId,
		"time_activation_seconds", 0.2)), "layers", Map())
	_TH_TapHoldTrackState := Map()
	try {
		return _THKM_Capture(HeldNames, () => _TapHoldFireAction(KeyId))
	} finally {
		TapHold := PreviousTapHold
		_TH_TapHoldTrackState := Map()
	}
}

_THKM_Join(Sent) {
	Text := ""
	for _, Keys in Sent
		Text .= (A_Index = 1 ? "" : " | ") . Keys
	return Text
}




; =============================================
; =============================================
; ======= 2/ Keystroke taps ===================
; =============================================
; =============================================

_THKM_ShiftThenAltGrTapIsShiftTab() {
	AssertEqual("{Blind}{Tab}", _THKM_Join(_THKM_FireTap("alt_gr", "tab", ["LShift"])),
		"Shift held then an AltGr tap must type Shift+Tab, not a plain Tab")
	AssertEqual("{Blind}{Tab}", _THKM_Join(_THKM_FireTap("alt_gr", "tab", ["RShift"])),
		"a native right Shift must combine too")
	AssertEqual("{Tab}", _THKM_Join(_THKM_FireTap("alt_gr", "tab", [])),
		"with nothing held the tap stays a bare Tab")
}
Test("tap-hold modifiers: Shift then an AltGr tap gives Shift+Tab (held-modifier-tap-2026-09-25)",
	_THKM_ShiftThenAltGrTapIsShiftTab)

_THKM_EveryKeyAndKeystrokeActionCombines() {
	global _TH_TapHoldScToKeyId
	; Each keystroke action with the payload it must produce under a held
	; modifier: single keys, catalogue shortcuts, a hand-written shortcut and a
	; generated modifier chord all type like the key they name.
	Expected := Map(
		"tab", "{Blind}{Tab}",
		"enter", "{Blind}{Enter}",
		"escape", "{Blind}{Escape}",
		"backspace", "{Blind}{BackSpace}",
		"delete", "{Blind}{Delete}",
		"arrow_left", "{Blind}{Left}",
		"copy", "{Blind}^{c}",
		"tab_next", "{Blind}^{Tab}",
		"ctrl_shift_s", "{Blind}^+{s}")
	Seen := Map()
	Checked := 0
	for _, KeyId in _TH_TapHoldScToKeyId {
		if Seen.Has(KeyId)
			continue
		Seen[KeyId] := true
		for ActionId, Payload in Expected {
			for _, Source in [["LShift"], ["LCtrl"], ["LWin"], ["RCtrl", "LShift"]] {
				AssertEqual(Payload, _THKM_Join(_THKM_FireTap(KeyId, ActionId, Source)),
					"tap '" . ActionId . "' of '" . KeyId . "' must keep the held " . Source[1])
				Checked++
			}
		}
	}
	Assert(Seen.Count >= 14, "every tap-hold key must be covered, got " . Seen.Count)
	Assert(Checked >= 14 * 9 * 4, "the whole matrix must run, got " . Checked)
}
Test("tap-hold modifiers: every key's keystroke tap keeps every held modifier (held-modifier-tap-2026-09-25)",
	_THKM_EveryKeyAndKeystrokeActionCombines)

_THKM_NothingHeldKeepsTheExactPayload() {
	; The hotstring buffer recognizes a plain edit by this exact payload.
	AssertEqual("{BackSpace}", _THKM_Join(_THKM_Capture([], () => TapHoldEmitKeyTap("BackSpace"))),
		"a Backspace tap with nothing held must stay the bare payload")
	AssertEqual("^{c}", _THKM_Join(_THKM_FireTap("left_shift", "copy", [])),
		"a shortcut tap with nothing held must stay the plain shortcut")
}
Test("tap-hold modifiers: nothing held keeps the bare payload (held-modifier-tap-2026-09-25)",
	_THKM_NothingHeldKeepsTheExactPayload)

_THKM_NativeTapsCombine() {
	for _, Key in ["Tab", "Enter", "Escape", "BackSpace", "Delete"] {
		AssertEqual("{Blind}{" . Key . "}",
			_THKM_Join(_THKM_Capture(["LShift"], TapHoldEmitKeyTap.Bind(Key))),
			"the native " . Key . " tap must keep a held Shift")
	}
}
Test("tap-hold modifiers: native keystroke taps keep a held Shift (held-modifier-tap-2026-09-25)",
	_THKM_NativeTapsCombine)




; =============================================
; =============================================
; ======= 3/ Actions with their own meaning ===
; =============================================
; =============================================

global _THKM_StateActionHits := 0

_THKM_RecordStateAction() {
	global _THKM_StateActionHits
	_THKM_StateActionHits += 1
}

_THKM_StateActionsKeepTheirOwnPath() {
	global GESTURE_ACTIONS, _THKM_StateActionHits
	ActionId := "__test_state_action_under_modifier"
	GESTURE_ACTIONS[ActionId] := {Fn: _THKM_RecordStateAction}
	_THKM_StateActionHits := 0
	try {
		Sent := _THKM_FireTap("alt_gr", ActionId, ["LShift"])
		AssertEqual(1, _THKM_StateActionHits,
			"an action with no keystroke must still run its own callback")
		AssertEqual("", _THKM_Join(Sent),
			"an action with no keystroke must not be typed as one")
	} finally {
		GESTURE_ACTIONS.Delete(ActionId)
	}
}
Test("tap-hold modifiers: an action without a keystroke runs its own callback (held-modifier-tap-2026-09-25)",
	_THKM_StateActionsKeepTheirOwnPath)
