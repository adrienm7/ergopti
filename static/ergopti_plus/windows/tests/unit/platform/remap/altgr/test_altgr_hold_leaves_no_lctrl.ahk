; tests/unit/platform/remap/altgr/test_altgr_hold_leaves_no_lctrl.ahk

; ==============================================================================
; MODULE: A synthetic AltGr hold leaves no LCtrl behind
; DESCRIPTION:
; Issue #109: LAlt tapped as Backspace and held as AltGr deleted a whole word
; (Ctrl+Backspace) on a tap, and Ctrl then stayed down until the driver
; restarted. On a layout whose AltGr adds a fake LCtrl, Windows answers the
; driver's own RAlt with an LCtrl that a SendInput leaves untagged, so no ledger
; owns it; once its paired Up was lost, nothing released it, and the Backspace
; tap went out as {Blind}{BackSpace} under it. The release of a synthetic AltGr
; now lifts an LCtrl that nobody owns. The world below models the keyboard's
; logical state: an RAlt Down adds the fake LCtrl, and its Up removes it unless
; the case loses that Up. The real owner, ledger and LAlt tap run unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

class _AHNL_World {
	__New(LoseFakeUp, Logical := 0, Physical := 0) {
		this.LoseFakeUp := LoseFakeUp
		this.Logical := IsObject(Logical) ? Logical : Map()
		this.Physical := IsObject(Physical) ? Physical : Map()
		this.Sent := []
	}

	OnSend(Keys) {
		this.Sent.Push(Keys)
		Position := 1
		while RegExMatch(Keys, "i)\{(\w+) (Down|Up)\}", &Edge, Position) {
			Position := Edge.Pos + Edge.Len
			Name := Edge[1]
			if (Edge[2] = "Down") {
				this.Logical[Name] := true
				; On every family, so QWERTY proves the layout gate, not the world.
				if (Name == "RAlt")
					this.Logical["LCtrl"] := true
				continue
			}
			if this.Logical.Has(Name)
				this.Logical.Delete(Name)
			if (Name == "RAlt" && !this.LoseFakeUp && this.Logical.Has("LCtrl"))
				this.Logical.Delete("LCtrl")
		}
		return Keys
	}

	Count(Payload) {
		Total := 0
		for _, Keys in this.Sent {
			if (Keys == Payload)
				Total += 1
		}
		return Total
	}

	Wire() {
		Text := ""
		for _, Keys in this.Sent
			Text .= (Text == "" ? "" : "|") . Keys
		return Text
	}
}

; Run Body(World) with the keyboard state and the synthetic ledger swapped
; for World's, on the given layout family.
_AHNL_With(World, Kana, AltGrLevel, Body) {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TapHoldModifierIsHeld, TapHold
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_AltGrFoundLCtrlDown, _TH_TapHoldTrackState
	Saved := { Send: _AHK_SendInput, KeyIsDown: _TapHoldKeyIsDown, Held: _TapHoldModifierIsHeld,
		TapHold: TapHold, Synth: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys,
		User: _TH_SyntheticUserHeldKeys, Found: _TH_AltGrFoundLCtrlDown, Track: _TH_TapHoldTrackState,
		Family: _TestSetAltGrFamily(Kana, AltGrLevel) }
	_TH_SyntheticHeldKeys := Map(), _TH_SyntheticReleasePendingKeys := Map(), _TH_SyntheticUserHeldKeys := Map()
	_TH_AltGrFoundLCtrlDown := false, _TH_TapHoldTrackState := Map()
	TapHold := Map("keys", Map("left_alt", Map("enabled", true, "tap_action", "backspace",
		"hold_modifier", "alt_gr", "hold_layer", "", "time_activation_seconds", 0.2)), "layers", Map())
	_AHK_SendInput := (Keys) => World.OnSend(Keys)
	_TapHoldKeyIsDown := (Name, Mode) => (Mode == "P") ? World.Physical.Has(Name) : World.Logical.Has(Name)
	_TapHoldModifierIsHeld := (Name) => World.Logical.Has(Name)
	try
		return Body.Call(World)
	finally {
		_AHK_SendInput := Saved.Send
		_TapHoldKeyIsDown := Saved.KeyIsDown
		_TapHoldModifierIsHeld := Saved.Held
		TapHold := Saved.TapHold
		_TH_SyntheticHeldKeys := Saved.Synth
		_TH_SyntheticReleasePendingKeys := Saved.Pending
		_TH_SyntheticUserHeldKeys := Saved.User
		_TH_AltGrFoundLCtrlDown := Saved.Found
		_TH_TapHoldTrackState := Saved.Track
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

; One LAlt tap through the real owner holding the layout's AltGr, then the
; real LAlt Backspace tap when the owner calls it a tap (lalt.ahk 4.6).
_AHNL_TapLAlt(World) {
	Clock := 900
	; A press of 100 ms: a tap, above the shared minimum and below the threshold.
	Result := TapHoldOwnImmediateModifier("left_alt", "SC038", ResolveHoldModifierKey("alt_gr", "left_alt"), 0.2,
		(*) => true, (*) => false, (*) => (Clock += 100), , , (*) => "")
	if Result["tap"]
		_LAltBackspaceTap()
	return Result
}

_AHNL_TapIsAPlainBackspace() {
	World := _AHNL_World(true)
	Result := _AHNL_With(World, false, true, _AHNL_TapLAlt)
	AssertTrue(Result["tap"], "a 100 ms LAlt press is a tap")
	AssertTrue(Result["released"], "the AltGr hold and its leftover LCtrl must both be released")
	AssertEqual(1, World.Count("{LCtrl Up}"), "the LCtrl the AltGr left down must be released once: " . World.Wire())
	AssertTrue(InStr(World.Wire(), "{RAlt Up}|{LCtrl Up}") > 0, "the LCtrl goes after the AltGr, before the tap: " . World.Wire())
	AssertEqual("{BackSpace}", World.Sent[-1], "the tap must be a plain Backspace, never Ctrl+Backspace: " . World.Wire())
	AssertFalse(World.Logical.Has("LCtrl"), "no LCtrl may stay down after the tap")
	AssertEqual(0, _AHNL_With(_AHNL_World(true), false, true, (W) => (_AHNL_TapLAlt(W), W.Logical.Count)),
		"nothing at all stays logically down after the gesture")
}
Test("altgr hold: LAlt tapped as Backspace and held as AltGr types one Backspace and leaves no Ctrl (issue-109-lalt-altgr-lctrl)",
	_AHNL_TapIsAPlainBackspace)

_AHNL_OnlyAnUnownedLCtrlIsReleased() {
	World := _AHNL_World(false)
	_AHNL_With(World, false, true, _AHNL_TapLAlt)
	AssertEqual(0, World.Count("{LCtrl Up}"), "the fake LCtrl that went up with the RAlt needs no second release")
	AssertEqual("{BackSpace}", World.Sent[-1])
	World := _AHNL_World(true, Map("LCtrl", true))
	_AHNL_With(World, false, true, _AHNL_TapLAlt)
	AssertEqual(0, World.Count("{LCtrl Up}"), "an LCtrl already down before the AltGr belongs to someone else")
	World := _AHNL_World(true, 0, Map("SC01D", true))
	_AHNL_With(World, false, true, _AHNL_TapLAlt)
	AssertEqual(0, World.Count("{LCtrl Up}"), "an LCtrl the user physically holds is the user's")
	World := _AHNL_World(true, 0, Map("RAlt", true))
	_AHNL_With(World, false, true, _AHNL_TapLAlt)
	AssertEqual(0, World.Count("{LCtrl Up}"), "the fake LCtrl of an AltGr the user physically holds is that AltGr's")
	World := _AHNL_World(true)
	_AHNL_With(World, false, false, _AHNL_TapLAlt)
	AssertEqual(0, World.Count("{LCtrl Up}"), "QWERTY: right Alt adds no LCtrl, any LCtrl is someone else's")
	World := _AHNL_World(true)
	_AHNL_With(World, true, false, _AHNL_TapLAlt)
	AssertEqual(0, World.Count("{LCtrl Up}"), "Kana: the AltGr key adds no LCtrl")
}
Test("altgr hold: only an LCtrl nobody owns is released after a synthetic AltGr (issue-109-lalt-altgr-lctrl)",
	_AHNL_OnlyAnUnownedLCtrlIsReleased)

_AHNL_AnotherAltGrOwnerKeepsIt() {
	World := _AHNL_World(true)
	Wire := _AHNL_With(World, false, true, _AHNL_TwoOwners)
	AssertEqual(1, World.Count("{LCtrl Up}"), "the LCtrl goes once, with the last AltGr owner: " . Wire)
	AssertTrue(InStr(Wire, "{RAlt Up}|{LCtrl Up}") > 0, "and only after the RAlt itself is up: " . Wire)
}
_AHNL_TwoOwners(World) {
	A := TapHoldNewOwner(), B := TapHoldNewOwner()
	AssertTrue(TapHoldSyntheticKeyDown("RAlt", A))
	AssertTrue(TapHoldSyntheticKeyDown("RAlt", B))
	AssertTrue(TapHoldSyntheticKeyUp("RAlt", A))
	AssertEqual(0, World.Count("{LCtrl Up}"), "a second owner still holds AltGr, and its LCtrl with it")
	AssertTrue(TapHoldSyntheticKeyUp("RAlt", B))
	return World.Wire()
}
Test("altgr hold: the leftover LCtrl waits for the last AltGr owner (issue-109-lalt-altgr-lctrl)",
	_AHNL_AnotherAltGrOwnerKeepsIt)

_AHNL_LifecycleCleanupReleasesIt() {
	World := _AHNL_World(true)
	_AHNL_With(World, false, true, _AHNL_SuspendMidHold)
	AssertEqual(1, World.Count("{LCtrl Up}"), "Suspend, reload and exit end the AltGr hold and its LCtrl: " . World.Wire())
	AssertFalse(World.Logical.Has("LCtrl"), "no LCtrl may survive the lifecycle cleanup")
	AssertFalse(World.Logical.Has("RAlt"), "nor the AltGr itself")
}
_AHNL_SuspendMidHold(World) {
	AssertTrue(TapHoldSyntheticKeyDown("RAlt", TapHoldNewOwner()))
	AssertTrue(TapHoldReleaseSyntheticKeys(), "the lifecycle cleanup must prove every release")
}
Test("altgr hold: the lifecycle cleanup releases the LCtrl a synthetic AltGr left (issue-109-lalt-altgr-lctrl)",
	_AHNL_LifecycleCleanupReleasesIt)
