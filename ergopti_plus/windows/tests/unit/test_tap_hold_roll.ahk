; tests/unit/test_tap_hold_roll.ahk

; ==============================================================================
; MODULE: A typing key rolled over the next one is a tap
; DESCRIPTION:
; With Shift as the hold of Space, fast typing turned « word, Space, letter »
; into the letter in capitals followed by the space: the hold was pressed as
; soon as Space went down, so a letter struck before Space came up was typed
; under it (« fonctionnerA ussi », 2026-10-01). A typing key that keeps its own
; key on a tap is now decided by the order of the releases
; (platform/remap/tap_hold_roll.ahk). The owner and the thread of the key
; struck during its wait are driven here in the order AutoHotkey runs them:
; the key's thread runs inside the owner's wait, which is where it interrupts.
; ==============================================================================

#Requires AutoHotkey v2.0

; One scenario's world: what is physically down, the clock, and what happened.
class _THR_World {
	Down := Map()
	Now := 1000
	Events := []
	Script := []

	Log(Text) => this.Events.Push(Text)

	Joined() {
		Text := ""
		for Event in this.Events
			Text .= (Text == "" ? "" : " ") . Event
		return Text
	}

	; The ports of the thread of a key struck during the wait. Each look at the
	; physical keys plays the next step of the scenario, as time passing does.
	KeyPorts() {
		World := this
		Step(*) {
			if (World.Script.Length > 0) {
				Action := World.Script.RemoveAt(1)
				Action.Call(World)
			}
		}
		return Map(
			"is_down", (Sc) => World.Down.Has(Sc),
			"tick", () => World.Now,
			"sleep", Step,
			"replay", (ScanCodes) => World.Log("replay:" . _THR_Join(ScanCodes)))
	}
}

_THR_Join(ScanCodes) {
	Text := ""
	for Sc in ScanCodes
		Text .= (Text == "" ? "" : "+") . Format("{:X}", Sc)
	return Text
}

; Runs the owner of Space over one scenario. Inside is what happens during the
; owner's wait; Released is what the wait then reports.
_THR_Run(World, Inside, Released) {
	Waits := Map("count", 0)
	Wait(KeyName, Seconds) {
		; A later wait is the one for a key whose tap is typed to come up.
		Waits["count"] += 1
		if (Waits["count"] > 1)
			return true
		if IsObject(Inside)
			Inside.Call(World)
		return Released
	}
	Ports := Map("wait_release", Wait, "tick", () => World.Now)
	World.Down[0x39] := true
	return TapHoldOwnRoll("space", "SC039", 0.2, () => World.Log("tap"),
		() => (World.Log("press"), true), (Pressed) => World.Log("own:" . (Pressed ? "pressed" : "fresh")), Ports)
}

_THR_AloneTapAndHold() {
	World := _THR_World()
	Result := _THR_Run(World, 0, true)
	AssertEqual("tap", World.Joined(), "a lone quick press types its tap, once")
	AssertEqual("tap", Result["decision"])
	AssertFalse(Result["tap"], "the owner typed the tap itself: the caller must not type it again")
	AssertFalse(TapHoldRollUndecided(), "nothing is left undecided")

	World := _THR_World()
	Result := _THR_Run(World, 0, false)
	AssertEqual("press own:pressed", World.Joined(),
		"past its threshold the key is its hold: pressed once, then owned until the release")
	AssertTrue(Result["activated"])
	AssertFalse(TapHoldRollUndecided())
}
Test("tap-hold roll: a lone press is a tap before its threshold and its hold after (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_AloneTapAndHold)

; Space down, a down, Space up, a up: the maintainer's « fonctionnerA ussi ».
_THR_RollIsATap() {
	World := _THR_World()
	Inside(W) {
		W.Down[0x10] := true
		W.Script := [(X) => X.Down.Delete(0x39)]
		TapHoldRollOtherKey("*SC010", W.KeyPorts())
	}
	Result := _THR_Run(World, Inside, true)
	AssertEqual("tap replay:10", World.Joined(), "the space is typed first, then the letter, and no hold is pressed")
	AssertEqual("tap", Result["decision"])
	AssertFalse(Result["activated"])
}
Test("tap-hold roll: a key rolled over the next one types its tap, then the next key (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_RollIsATap)

; Space down, a down, a up, Space up: a quick chord stays a chord.
_THR_NestedIsAHold() {
	World := _THR_World()
	Inside(W) {
		W.Down[0x10] := true
		W.Script := [(X) => X.Down.Delete(0x10)]
		TapHoldRollOtherKey("*SC010", W.KeyPorts())
	}
	Result := _THR_Run(World, Inside, true)
	AssertEqual("press replay:10 own:pressed", World.Joined(),
		"the hold is pressed before the letter is sent again, and its owner lifts it without pressing it twice")
	AssertEqual("hold", Result["decision"])
}
Test("tap-hold roll: a key struck and let go under it is typed under its hold (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_NestedIsAHold)

_THR_ThresholdIsAHold() {
	World := _THR_World()
	Inside(W) {
		W.Down[0x10] := true
		W.Script := [(X) => X.Now += 100, (X) => X.Now += 150]
		TapHoldRollOtherKey("*SC010", W.KeyPorts())
	}
	_THR_Run(World, Inside, false)
	AssertEqual("press replay:10 own:pressed", World.Joined(), "both keys still down at the threshold: the hold")
}
Test("tap-hold roll: both keys still down at the threshold are the hold (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_ThresholdIsAHold)

_THR_ThresholdAcrossTickWrap() {
	World := _THR_World()
	World.Now := 0xFFFFFFF0
	Inside(W) {
		W.Down[0x10] := true
		W.Script := [(X) => X.Now := 0xF0, _THR_WrapThresholdMissed]
		TapHoldRollOtherKey("*SC010", W.KeyPorts())
	}
	Result := _THR_Run(World, Inside, false)
	AssertEqual("press replay:10 own:pressed", World.Joined(),
		"256 elapsed milliseconds across wrap must press the hold and replay exactly once")
	AssertEqual("hold", Result["decision"])
	AssertTrue(Result["activated"])
	AssertFalse(TapHoldRollUndecided(), "a wrapped clock must not leave a key waiting")
}

_THR_WrapThresholdMissed(*) {
	throw Error("the roll threshold must resolve before another poll after tick rollover")
}
Test("tap-hold roll: hold threshold survives unsigned tick rollover (tap-hold-roll-tick-wrap)",
	_THR_ThresholdAcrossTickWrap)

; Space down, a down, b down: a second key before either came up is typing.
_THR_SecondKeyIsTyping() {
	World := _THR_World()
	Inside(W) {
		W.Down[0x10] := true
		W.Script := [(X) => (X.Down[0x11] := true, TapHoldRollOtherKey("SC011", X.KeyPorts()))]
		TapHoldRollOtherKey("*SC010", W.KeyPorts())
	}
	_THR_Run(World, Inside, true)
	AssertEqual("tap replay:10+11", World.Joined(), "the space, then both letters in the order they were struck, once")
}
Test("tap-hold roll: a second key struck before either came up is typing (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_SecondKeyIsTyping)

_THR_OwnRepeatAndLateKey() {
	World := _THR_World()
	Inside(W) {
		TapHoldRollOtherKey("*SC039", W.KeyPorts())
		AssertEqual(0, _TapHoldRollState()["queue"].Length, "the key's own auto-repeat waits for nothing")
	}
	_THR_Run(World, Inside, true)
	AssertEqual("tap", World.Joined(), "and decides nothing")

	World := _THR_World()
	TapHoldRollOtherKey("+SC010", World.KeyPorts())
	AssertEqual("replay:10", World.Joined(), "a key whose hotkey fired after the decision is sent again at once")
	AssertThrows(() => TapHoldRollOtherKey("a", World.KeyPorts()), "a roll hotkey is named by its scan code")
}
Test("tap-hold roll: the key's own repeat and a key that arrives after the decision (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_OwnRepeatAndLateKey)

; Which keys follow the rule: a typing key of the shared list whose tap is itself.
_THR_Scope() {
	global TapHold, TAPHOLD_ROLL_KEYS
	Saved := TapHold
	try {
		Listed := ""
		for KeyId in ["backspace", "delete", "enter", "escape", "space", "tab"] {
			Assert(TAPHOLD_ROLL_KEYS.Has(KeyId), KeyId . " is a typing key of the shared list")
			Listed .= KeyId
		}
		AssertEqual(6, TAPHOLD_ROLL_KEYS.Count, "and no other key is")
		TapHold := Map("keys", Map(
			"space", Map("hold_modifier", "shift"),
			"enter", Map("tap_action", "enter", "hold_modifier", "ctrl"),
			"tab", Map("tap_action", "alt_tab_monitor", "hold_modifier", "alt"),
			"caps_lock", Map("tap_action", "enter", "hold_modifier", "ctrl")), "inherit_defaults", false)
		AssertTrue(TapHoldKeyRolls("space"), "Space that is itself on a tap")
		AssertTrue(TapHoldKeyRolls("enter"), "Enter tapping Enter")
		AssertFalse(TapHoldKeyRolls("tab"), "Tab tapping an action is not typed text: its hold stays immediate")
		AssertFalse(TapHoldKeyRolls("caps_lock"), "CapsLock is not a typing key")
	} finally TapHold := Saved
}
Test("tap-hold roll: only a typing key that is itself on a tap follows the order of the releases (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_Scope)

; The keys struck around a roll tap are typing: they do not cancel it, as they
; cancel the tap of a key held as a modifier. The wheel still does.
_THR_KeyboardActivityDoesNotCancelARollTap() {
	global _TH_TapHoldTrackState, TAPHOLD_CANCEL_BY_OTHER_KEY
	State := _TapHoldRollState()
	Saved := _TH_TapHoldTrackState.Has("space") ? _TH_TapHoldTrackState["space"] : 0
	Typed := Map("count", 0)
	Track(Reason) {
		_TH_TapHoldTrackState["space"] := Map("down", false, "down_at", A_TickCount, "canceled_by_activity", true,
			"canceled_by_scroll", false, "cancel_reason", Reason, "last_vk", 0, "last_sc", 0, "last_seen", 0)
	}
	try {
		Track(TAPHOLD_CANCEL_BY_OTHER_KEY)
		AssertFalse(TapHoldDispatchTap("space", () => Typed["count"] += 1), "another key cancels the tap of a key held as a modifier")
		Track(TAPHOLD_CANCEL_BY_OTHER_KEY)
		State["tapping"] := "space"
		AssertTrue(TapHoldDispatchTap("space", () => Typed["count"] += 1), "and does not cancel the tap of a typing key")
		AssertEqual(1, Typed["count"])
		Track("wheel/trackpad during hold")
		AssertFalse(TapHoldDispatchTap("space", () => Typed["count"] += 1), "the wheel makes the press something else than typing")
	} finally {
		State["tapping"] := ""
		if Saved is Map
			_TH_TapHoldTrackState["space"] := Saved
		else if _TH_TapHoldTrackState.Has("space")
			_TH_TapHoldTrackState.Delete("space")
	}
}
Test("tap-hold roll: the keys struck around a roll tap do not cancel it (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_KeyboardActivityDoesNotCancelARollTap)

; The call sites and the block of hotkeys, held by source.
_THR_Wiring() {
	Root := A_ScriptDir . "\..\platform\"
	for KeyId, Dispatch in Map("space", "_SpaceTapOrDispatch", "enter", "_EnterDispatch", "tab", "_TabDispatch",
			"backspace", "_BackspaceDispatch", "delete", "_DeleteDispatch", "escape", "_EscapeDispatch") {
		Source := FSReadStrict(Root . "remap\" . KeyId . ".ahk")
		Assert(RegExMatch(Source, 'TapHoldOwnHoldModifier\("' . KeyId . '",[^`n]*`n?[^`n]*' . Dispatch . "\)"),
			KeyId . ".ahk must own its modifier hold through TapHoldOwnHoldModifier with its tap dispatch")
		Assert(RegExMatch(Source, 'TapHoldOwnHoldLayer\("' . KeyId . '",[^`n]*' . Dispatch . "\)"),
			KeyId . ".ahk must own its layer hold through TapHoldOwnHoldLayer with its tap dispatch")
		Assert(!InStr(Source, "TapHoldOwnImmediate"), KeyId . ".ahk must not take its hold at key-down by itself")
	}
	; Space's layer hold records « Space » as the last key once the layer was
	; held; a press typed as a tap recorded its own space and must keep it.
	SpaceLayer := _DriverFuncBody("SpaceTapHoldLayer")
	TapReturnAt := InStr(SpaceLayer, 'Result.Get("decision", "") == "tap"')
	Assert(TapReturnAt > 0 and TapReturnAt < InStr(SpaceLayer, 'UpdateLastSentCharacter("Space")'),
		"a Space the roll owner typed as a tap must not be recorded as a held layer key")
	Remap := FSReadStrict(Root . "remap.ahk")
	RollAt := InStr(Remap, "#Include remap/tap_hold_roll_keys.ahk")
	Assert(RollAt > 0 and RollAt < InStr(Remap, "#Include remap/capslock.ahk"),
		"the roll hotkeys must be created before every key file's own: the earliest-created eligible variant fires")
	Roll := FSReadStrict(Root . "remap\tap_hold_roll_keys.ahk")
	Assert(InStr(Roll, "#HotIf TapHoldRollUndecided() and not LayerEnabled`n") > 0,
		"the character keys wait only while a key is undecided, and stand down under the layer")
	NativeAt := InStr(Roll, "#HotIf TapHoldRollUndecided() and not LayerEnabled and not TapHoldKanaAltGrHeld()`n")
	Assert(NativeAt > 0, "the six native keys also stand down under the Kana AltGr")
	for Sc in ["SC010", "SC002", "SC035", "SC056"] {
		for Prefix in ["*", "", "+"] {
			At := InStr(Roll, "`n" . Prefix . Sc . "::`n")
			Assert(At > 0 and At < NativeAt, Prefix . Sc . " must wait for the decision")
		}
	}
	; Under a held modifier the six keys are the key itself, at once (Ctrl+Tab).
	for Sc in ["SC039", "SC01C", "SC00E", "SC00F", "SC001", "SC153"] {
		for Prefix in ["", "+"]
			Assert(InStr(Roll, "`n" . Prefix . Sc . "::`n") > NativeAt, Prefix . Sc . " must wait for the decision")
		Assert(!InStr(Roll, "*" . Sc . "::"), Sc . " must stay native under a held modifier")
	}
	for Sc in ["SC148", "SC150", "SC14B", "SC14D", "SC02A", "SC01D", "SC038"]
		Assert(!InStr(Roll, Sc . "::"), Sc . " is bound by name elsewhere or is a modifier: no scan-code hotkey may shadow it")
}
Test("tap-hold roll: the six typing keys own their hold through the roll owner (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_Wiring)

; The hold itself is still the shared immediate owner's, whichever way the key
; is decided: it guards suspension, bounds every wait for the release and
; lifts what it pressed in a finally. The roll owner adds the decision and
; nothing that captures or waits unbounded.
_THR_HoldStaysTheSharedOwners() {
	Modifier := _DriverFuncBody("TapHoldOwnHoldModifier")
	Assert(InStr(Modifier, "return TapHoldOwnImmediateModifier(KeyId, KeyName, ModKey, TapThresholdSec)") > 0,
		"a key that is not a typing key takes its modifier at key-down through the shared owner")
	Assert(InStr(_DriverFuncBody("_TapHoldRollOwnModifier"), "TapHoldOwnImmediateModifier(KeyId, KeyName, ModKey, TapThresholdSec,") > 0,
		"a decided typing key hands its modifier to the same shared owner")
	Layer := _DriverFuncBody("TapHoldOwnHoldLayer")
	Assert(InStr(Layer, "return TapHoldOwnImmediateLayer(KeyId, KeyName, TapThresholdSec)") > 0,
		"a key that is not a typing key enters the layer at key-down through the shared owner")
	Assert(InStr(_DriverFuncBody("_TapHoldRollOwnLayer"), "TapHoldOwnImmediateLayer(KeyId, KeyName, TapThresholdSec,") > 0,
		"a decided typing key hands the layer to the same shared owner")
	for Name in ["TapHoldOwnRoll", "TapHoldRollOtherKey", "_TapHoldRollResolve", "TapHoldOwnHoldModifier", "TapHoldOwnHoldLayer"] {
		Body := _DriverFuncBody(Name)
		Assert(!InStr(Body, "InputHook(") and !InStr(Body, "KeyWait("),
			Name . " must neither capture input nor wait on a key by itself")
	}
	Resolve := _DriverFuncBody("_TapHoldRollResolve")
	SuspendAt := InStr(Resolve, "if A_IsSuspended")
	Assert(SuspendAt > 0 and SuspendAt < InStr(Resolve, "PressFn.Call()") and SuspendAt < InStr(Resolve, "TapFn.Call()"),
		"a decision reached while the driver is paused types no tap and presses no hold")
	Assert(InStr(_DriverFuncBody("_TapHoldRollWaitUp"), "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
		"the wait for a key whose tap is typed is bounded like every release wait")
}
Test("tap-hold roll: the hold of a typing key is still the shared owner's (tap-hold-roll-is-a-tap-2026-10-01)",
	_THR_HoldStaysTheSharedOwners)
