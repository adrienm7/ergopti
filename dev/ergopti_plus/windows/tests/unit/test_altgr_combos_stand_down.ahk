; tests/unit/test_altgr_combos_stand_down.ahk

; ==============================================================================
; MODULE: The AltGr combinations stand down while AltGr holds something else
; DESCRIPTION:
; Every "SC138 & X" combination (the AltGr layer, the rolls, AltGr+LAlt,
; AltGr+CapsLock, the script chords) is gated on IsRealAltGrPress, which was
; always true on a Kana layout. With the AltGr key held as Ctrl, AltGr+C then
; typed the AltGr layer's character instead of Ctrl+C, and AltGr+Enter ran a
; script chord instead of Ctrl+Enter (kana-altgr-hold-other-2026-09-26). The
; key held as another modifier or a layer is that modifier or layer on every
; layout, so the gate is false then. Tests model the physical port without
; injecting host input; both layout families require a physically held key.
; ==============================================================================

#Requires AutoHotkey v2.0

; IsRealAltGrPress on a Kana layout with the alt_gr row Entry (0 for none).
_ACSD_Gate(Entry) {
	global TapHold
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true) }
	try {
		TapHold := Map("keys", IsObject(Entry) ? Map("alt_gr", Entry) : Map(), "layers", Map())
		; The owner cases model a held key; host input is never injected here.
		return IsRealAltGrPress((Key) => true)
	} finally {
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

_ACSD_Row(Hold := "", Layer := "") {
	Entry := Map("tap_action", "tab", "time_activation_seconds", 0.2)
	if (Hold != "")
		Entry["hold_modifier"] := Hold
	if (Layer != "")
		Entry["hold_layer"] := Layer
	return Entry
}

_ACSD_CombosFollowWhatAltGrHolds() {
	AssertTrue(_ACSD_Gate(0), "with no AltGr tap-hold the key is AltGr")
	AssertTrue(_ACSD_Gate(_ACSD_Row()), "a tap-only AltGr is AltGr while held")
	AssertTrue(_ACSD_Gate(_ACSD_Row("alt_gr")), "AltGr held as AltGr is AltGr")
	AssertTrue(_ACSD_Gate(_ACSD_Row("alt_gr+shift")), "a combination holding AltGr keeps the AltGr combinations")
	AssertFalse(_ACSD_Gate(_ACSD_Row("ctrl")), "AltGr held as Ctrl is Ctrl: AltGr+C must be Ctrl+C")
	AssertFalse(_ACSD_Gate(_ACSD_Row("", "nav")), "AltGr held as the navigation layer maps the layer's keys")
}
Test("altgr combos: they stand down while AltGr holds another modifier or a layer (kana-altgr-hold-other-2026-09-26)",
	_ACSD_CombosFollowWhatAltGrHolds)

; The rule itself (AltGrKeyIsAltGr, which IsRealAltGrPress applies first) on
; every family, with the owner each hold gets: a combination holding AltGr
; keeps the combinations on a standard AltGr layout too, where it now passes
; the key through (std-altgr-combo-passthrough-2026-09-26), so the layer is
; reachable for the whole hold as on QWERTY and Kana.
_ACSD_EveryFamilyKeepsTheCombosForAnAltGrHold() {
	global TapHold
	for _, Family in ["standard", "qwerty", "kana"] {
		Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(Family == "kana", Family == "standard") }
		try {
			for _, Hold in ["alt_gr", "shift+alt_gr", "ctrl+alt_gr", "alt_gr+win"] {
				TapHold := Map("keys", Map("alt_gr", _ACSD_Row(Hold)), "layers", Map())
				AssertTrue(AltGrKeyIsAltGr(), Family . ": AltGr held as " . Hold . " keeps the AltGr combinations")
				AssertTrue(AltGrOwnerPassesThrough(Family == "kana") or AltGrOwnerHolds(Family == "kana"),
					Family . ": AltGr held as " . Hold . " has an owner")
				if (Family == "standard")
					AssertTrue(AltGrOwnerPassesThrough(false),
						"standard: AltGr held as " . Hold . " passes the key through, or the fake LCtrl-up kills the combinations")
			}
			for _, Hold in ["ctrl", "shift+ctrl"] {
				TapHold := Map("keys", Map("alt_gr", _ACSD_Row(Hold)), "layers", Map())
				AssertFalse(AltGrKeyIsAltGr(), Family . ": AltGr held as " . Hold . " is not AltGr")
			}
		} finally {
			TapHold := Saved.TapHold
			_TestRestoreAltGrFamily(Saved.Family)
		}
	}
}
Test("altgr combos: an AltGr combination hold keeps them on every layout family (std-altgr-combo-passthrough-2026-09-26)",
	_ACSD_EveryFamilyKeepsTheCombosForAnAltGrHold)

; The Kana script chords that need no prefix (Enter, BackSpace, Delete, Escape
; under the physical SC138) follow the same rule, and the standard family's
; gate applies it before the physical check.
_ACSD_EveryAltGrGateAppliesIt() {
	Body := _DriverFuncBody("IsRealAltGrPress")
	Assert(Body != "", "the eligibility function must exist")
	Gate := InStr(Body, "AltGrKeyIsAltGr()")
	AssertTrue(Gate > 0 and Gate < InStr(Body, 'Query.Call("SC138")'),
		"IsRealAltGrPress must stand down for a non-AltGr hold before its physical-state query")
	Script := _DriverFuncBody("ScriptAltGrKanaChordRunsSlot")
	AssertTrue(InStr(Script, 'ScriptAltGrKanaChordIsLive(GetKeyState("SC138", "P"))') > 0,
		"the Kana suffix-only script chords must be gated by their criterion")
	global TapHold
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true) }
	try {
		TapHold := Map("keys", Map("alt_gr", _ACSD_Row("ctrl")), "layers", Map())
		AssertFalse(ScriptAltGrKanaChordIsLive(true),
			"the Kana suffix-only script chords must stand down with the combinations")
		TapHold := Map("keys", Map("alt_gr", _ACSD_Row("alt_gr")), "layers", Map())
		AssertTrue(ScriptAltGrKanaChordIsLive(true), "AltGr held as AltGr keeps the Kana script chords")
	} finally {
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}
Test("altgr combos: every AltGr gate applies the rule (kana-altgr-hold-other-2026-09-26)",
	_ACSD_EveryAltGrGateAppliesIt)

_ACSD_PhysicalEligibility(Family, Pressed) {
	global TapHold
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(Family == "kana", Family == "standard") }
	try {
		TapHold := Map("keys", Map(), "layers", Map())
		Queries := []
		ReadPhysical(Key) {
			Queries.Push(Key)
			return Pressed
		}
		AssertEqual(Pressed, IsRealAltGrPress(ReadPhysical),
			Family . ": a latched prefix without a physical press must never admit a suffix")
		AssertEqual(1, Queries.Length, "eligibility must read one physical key")
		AssertEqual(Family == "kana" ? "SC138" : "RAlt", Queries[1])
	} finally {
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}
for Family in ["standard", "qwerty", "kana"]
	for Pressed in [false, true]
		Test("altgr combos: physical eligibility on " . Family . " held=" . Pressed . " (altgr-physical-eligibility)",
			_ACSD_PhysicalEligibility.Bind(Family, Pressed))

; Exercises the production query with a released host key. This covers the
; diagnostic's Kana ghost criterion: it used to return true without reading SC138.
_ACSD_ReleasedKanaNeverAdmitsSuffixes() {
	global TapHold
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true) }
	try {
		TapHold := Map("keys", Map(), "layers", Map())
		AssertFalse(GetKeyState("SC138", "P"), "this non-injecting case requires a released host key")
		AssertFalse(IsRealAltGrPress(), "a Kana layout alone must never authorize an AltGr suffix")
	} finally {
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}
Test("altgr combos: a released Kana key never admits suffixes (altgr-physical-eligibility)",
	_ACSD_ReleasedKanaNeverAdmitsSuffixes)
