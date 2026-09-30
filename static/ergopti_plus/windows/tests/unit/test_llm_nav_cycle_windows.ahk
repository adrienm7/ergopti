; tests/unit/test_llm_nav_cycle_windows.ahk

; ==============================================================================
; MODULE: One prediction cycle per navigation chord, in either hook order
; DESCRIPTION:
; Regression coverage for a maintainer report on a Windows build of 2026-09-30:
; Tab accepted the prediction, but the arrows no longer moved its marker.
;
; MECHANISM ENCODED (llm-nav-cycle-windows): the native owner cycled the slot
; on the configured Up / Down chord and passed the key on, and static wildcard
; hotkeys swallowed it, on the premise that the DLL's hook runs first. Windows
; calls the most recently installed low-level hook first, and AutoHotkey
; reinstalls its keyboard hook around every SendInput: once the driver had typed
; anything, AutoHotkey swallowed the arrow before the native owner saw it, and
; nothing cycled. The hotkeys now perform the cycle, and the native cycle routes
; are parked on an identity no key produces, so a press cycles exactly once
; whichever hook Windows calls first.
;
; A press runs through both hooks in a given order. The AutoHotkey stage is the
; static hotkey: its #HotIf criterion, then its action, whose hotkey swallows
; the key. The native stage matches the event against exactly the routes the
; adapter marshals to the DLL, with the DLL's exact identity rule
; (NavEventMatchesBinding): a cycle route that matches moves the owner and
; passes the key on. Reuses the navigation owner's deterministic port and the
; fixtures of test_llm_tab_accepts_visible_prediction and
; test_llm_tooltip_nav_consumed.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Hook chain model =======
; ===================================
; ===================================

; Both orders in which Windows may call the two keyboard hooks.
_LNCW_Orders() {
	return [
		{ Name: "AutoHotkey first", Stages: ["ahk", "native"] },
		{ Name: "native owner first", Stages: ["native", "ahk"] }
	]
}

; The event the DLL's hook builds for a physical press of Key
; (NavBuildHookEventLocked): its virtual key, its extended scan code and the
; Ctrl / Alt / Shift / Win mask of the held modifiers.
_LNCW_NativeEvent(Key, Held) {
	Modifiers := 0
	for Name, Bit in Map("Ctrl", 0x01, "Alt", 0x02, "Shift", 0x04) {
		if Held.Has(Name)
			Modifiers |= Bit
	}
	if Held.Has("LWin") || Held.Has("RWin")
		Modifiers |= 0x08
	return Map("vk", Key == "Up" ? 0x26 : 0x28,
		"sc", Key == "Up" ? 0x148 : 0x150, "modifiers", Modifiers)
}

; The native cycle routes of the committed plan, as the adapter marshals them
; to the DLL, whose identity is exactly Event's.
_LNCW_NativeCycleRoutes(Event) {
	global _LLM_Menu_NavHotkeysBound
	Routes := _LLM_NavEventOwnerNativeBindings(_LLM_Menu_NavHotkeysBound)
	AssertTrue(Routes is Array && Routes.Length == 12,
		"the committed plan must marshal its twelve native routes")
	Matches := []
	for Route in Routes {
		Code := Route["axis"] == 2 ? Event["sc"] : Event["vk"]
		if Route["action"] == 1 && Code == Route["code"]
				&& Event["modifiers"] == Route["modifiers"]
			Matches.Push(Route)
	}
	return Matches
}

; The native stage: a matching cycle route moves the owner, as the DLL does
; before it passes the key on (NavTryComputeTarget, NavDispatchLocked).
; Returns the number of cycles it performed.
_LNCW_NativeStage(State, Event) {
	Matches := _LNCW_NativeCycleRoutes(Event)
	if Matches.Length == 0
		return 0
	Count := _LLM_TooltipGetCurrentRecord().Slots.Length
	Target := State.OwnerIndices.Get(State.CurrentToken, 1) + Matches[1]["delta"]
	State.OwnerIndices[State.CurrentToken] := Target < 1 ? Count
		: Target > Count ? 1 : Target
	return 1
}

; Stands in for the in-place repaint: records the target slot and republishes
; the prediction there through the real render commit and owner swap, as
; LLM_TooltipSetActiveIdx does.
_LNCW_Repaint(Probe, Target) {
	Probe.Targets.Push(Target)
	_LTAV_RenderPrediction(Probe.Slots, Target, true)
	return true
}

; One press of Key with HeldNames held, through both hooks in Order.
; @returns {Object} Consumed: whether a hook swallowed the key; Cycles: every
;     cycle of the press; NativeCycles: those the native owner performed.
_LNCW_Press(State, Probe, Key, HeldNames, Order) {
	Held := _LTNC_HeldMap(HeldNames)
	Before := Probe.Targets.Length
	NativeCycles := 0
	Consumed := false
	for Stage in Order.Stages {
		if (Stage == "ahk") {
			if LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Held)) {
				LLM_Menu_NavCycleChord(Key, _LNCW_Repaint.Bind(Probe))
				Consumed := true
				break
			}
		} else {
			NativeCycles += _LNCW_NativeStage(State, _LNCW_NativeEvent(Key, Held))
		}
	}
	return { Consumed: Consumed, NativeCycles: NativeCycles,
		Cycles: Probe.Targets.Length - Before + NativeCycles }
}

; Commits the navigation plan of NavMods through the native owner, runs
; BodyFn with the port state, and restores the navigation globals.
_LNCW_WithPlan(NavMods, BodyFn) {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, _TooltipGeneration
	Saved := {
		Bound: _LLM_Menu_NavHotkeysBound, SlotPlans: _LLM_Menu_NavSlotPlans,
		ActiveSlot: _LLM_Menu_NavActiveSlot, Generation: _TooltipGeneration
	}
	State := 0
	try {
		_LLM_Menu_NavHotkeysBound := []
		_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
		_LLM_Menu_NavActiveSlot := 0
		State := _LNEO_Setup()
		Bound := LLM_Menu_BindNavHotkeys(
			Map("nav_modifiers", NavMods, "val_modifiers", ""), 0, 0,
			_LNEO_CaptureLog.Bind(State), 0,
			_LNEO_ResolveUsPhysicalKey.Bind(State), State.Port)
		AssertTrue((Bound is Integer) && Bound == 1,
			"'" . NavMods . "': the navigation plan must commit through the native owner")
		return BodyFn.Call(State)
	} finally {
		_LLM_Menu_NavHotkeysBound := Saved.Bound
		_LLM_Menu_NavSlotPlans := Saved.SlotPlans
		_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
		if IsObject(State)
			_LNEO_Teardown()
		_TooltipGeneration := Saved.Generation
	}
}

; The configured chords, with chords that are not theirs.
_LNCW_Chords() {
	return [
		{ Config: "", Held: [], Wrong: [["Shift"], ["Ctrl"], ["LWin"]] },
		{ Config: "ctrl", Held: ["Ctrl"], Wrong: [[], ["Ctrl", "Shift"], ["Alt"]] }
	]
}





; ============================================================
; ============================================================
; ======= 2/ One cycle per chord, in either hook order =======
; ============================================================
; ============================================================

_LNCW_ExactChordBody(Chord, Order, State) {
	Label := "'" . Chord.Config . "', " . Order.Name
	Probe := { Slots: ["alpha", "beta", "gamma"], Targets: [] }
	_LTAV_RenderPrediction(Probe.Slots, 2, true)
	for Step in [{ Key: "Down", Target: 3 }, { Key: "Up", Target: 2 }] {
		Press := _LNCW_Press(State, Probe, Step.Key, Chord.Held, Order)
		AssertTrue(Press.Consumed,
			Label . ": the exact " . Step.Key . " chord must never reach the application")
		AssertEqual(1, Press.Cycles,
			Label . ": the exact " . Step.Key . " chord must move the marker exactly once")
		AssertEqual(0, Press.NativeCycles,
			Label . ": the native owner must never cycle the arrow the hotkey cycles")
		AssertEqual(Step.Target, LLM_TooltipGetActiveIdx(),
			Label . ": " . Step.Key . " must move the marker to slot " . Step.Target)
		AssertEqual(Step.Target, State.OwnerIndices.Get(State.CurrentToken, 0),
			Label . ": the native owner must hold the moved slot for Tab and the digits")
	}
	return 2
}

_LNCW_ExactChordCyclesOnceInEitherOrder() {
	Checked := 0
	for Chord in _LNCW_Chords() {
		for Order in _LNCW_Orders()
			Checked += _LNCW_WithPlan(Chord.Config,
				_LNCW_ExactChordBody.Bind(Chord, Order))
	}
	AssertEqual(8, Checked, "both chords, both keys and both hook orders must be checked")
}

Test("LLM nav: the exact chord cycles once and is consumed whichever hook runs first (llm-nav-cycle-windows)",
	_LNCW_ExactChordCyclesOnceInEitherOrder)

_LNCW_PassBody(Chord, Order, State) {
	global _TooltipActiveSurface
	Label := "'" . Chord.Config . "', " . Order.Name
	Probe := { Slots: ["alpha", "beta", "gamma"], Targets: [] }
	_LTAV_RenderPrediction(Probe.Slots, 2, true)
	Checked := 0
	for Held in Chord.Wrong {
		for Key in ["Up", "Down"] {
			Press := _LNCW_Press(State, Probe, Key, Held, Order)
			AssertFalse(Press.Consumed,
				Label . ": another chord than the configured one reaches the application")
			AssertEqual(0, Press.Cycles, Label . ": another chord moves nothing")
			Checked++
		}
	}
	AssertEqual(2, LLM_TooltipGetActiveIdx(),
		Label . ": the marker stays where it was")
	_LTAV_RenderPrediction(["solo"], 1, true)
	Press := _LNCW_Press(State, Probe, "Down", Chord.Held, Order)
	AssertFalse(Press.Consumed,
		Label . ": one prediction has nothing to move to, the arrow is the application's")
	AssertEqual(0, Press.Cycles, Label . ": one prediction never cycles")
	_TooltipActiveSurface := 0
	Press := _LNCW_Press(State, Probe, "Up", Chord.Held, Order)
	AssertFalse(Press.Consumed, Label . ": no tooltip, the arrow is the application's")
	AssertEqual(0, Press.Cycles, Label . ": no tooltip, nothing cycles")
	return Checked + 2
}

_LNCW_OtherChordsReachTheApplication() {
	Checked := 0
	for Chord in _LNCW_Chords() {
		for Order in _LNCW_Orders()
			Checked += _LNCW_WithPlan(Chord.Config,
				_LNCW_PassBody.Bind(Chord, Order))
	}
	AssertEqual(32, Checked, "every other chord, key and hook order must be checked")
}

Test("LLM nav: another chord, one prediction or no tooltip reaches the application uncycled (llm-nav-cycle-windows)",
	_LNCW_OtherChordsReachTheApplication)

_LNCW_WrapBody(Order, State) {
	Checked := 0
	for Count in [2, 3] {
		Probe := { Slots: [], Targets: [] }
		Loop Count
			Probe.Slots.Push("slot" . A_Index)
		for Step in [{ Key: "Up", From: 1, Target: Count },
				{ Key: "Down", From: Count, Target: 1 }] {
			Label := Order.Name . ", " . Count . " slots, " . Step.Key
				. " from slot " . Step.From
			_LTAV_RenderPrediction(Probe.Slots, Step.From, true)
			Press := _LNCW_Press(State, Probe, Step.Key, [], Order)
			AssertTrue(Press.Consumed, Label . ": the chord must be consumed")
			AssertEqual(1, Press.Cycles, Label . ": the chord must cycle once")
			AssertEqual(Step.Target, LLM_TooltipGetActiveIdx(),
				Label . ": the marker must wrap around to slot " . Step.Target)
			Checked++
		}
	}
	return Checked
}

_LNCW_MarkerWrapsAroundAtBothEnds() {
	Checked := 0
	for Order in _LNCW_Orders()
		Checked += _LNCW_WithPlan("", _LNCW_WrapBody.Bind(Order))
	AssertEqual(8, Checked, "both ends, both sizes and both hook orders must be checked")
}

Test("LLM nav: the marker wraps around at both ends (llm-nav-cycle-windows)",
	_LNCW_MarkerWrapsAroundAtBothEnds)





; =========================================================
; =========================================================
; ======= 3/ The native owner never cycles an arrow =======
; =========================================================
; =========================================================

_LNCW_NativeRoutesBody(Config, State) {
	global _LLM_Menu_NavHotkeysBound
	Checked := 0
	for Key in ["Up", "Down"] {
		Loop 16 {
			Event := _LNCW_NativeEvent(Key, Map())
			Event["modifiers"] := A_Index - 1
			AssertEqual(0, _LNCW_NativeCycleRoutes(Event).Length,
				"'" . Config . "': no native cycle route may match " . Key
				. " with modifier mask " . (A_Index - 1))
			Checked++
		}
	}
	Routes := _LLM_NavEventOwnerNativeBindings(_LLM_Menu_NavHotkeysBound)
	for Index, Delta in [-1, 1] {
		Route := Routes[Index]
		; The DLL contract (NavPlanIsValid) still receives one pass-through cycle
		; route per direction.
		AssertEqual(1, Route["action"], "'" . Config . "': route " . Index . " stays a cycle route")
		AssertEqual(Delta, Route["delta"], "'" . Config . "': route " . Index . " keeps its direction")
		AssertEqual(1, Route["pass_through"], "'" . Config . "': a cycle route passes its key on")
		AssertEqual(0x100, Route["code"], "'" . Config . "': a cycle route is parked on extended scan code zero")
	}
	Digit := Routes[3]
	AssertEqual(2, Digit["action"], "'" . Config . "': the validation routes stay jumps")
	AssertEqual(0x31, Digit["code"], "'" . Config . "': a validation route keeps its digit-row key")
	AssertEqual(0, Digit["pass_through"], "'" . Config . "': a validation route is consumed natively")
	AssertEqual(1, Digit["target"], "'" . Config . "': digit 1 still inserts slot 1")
	return Checked
}

_LNCW_NativeOwnerNeverCyclesAnArrow() {
	Checked := 0
	for Config in ["", "ctrl", "alt", "shift", "win", "ctrl+shift"]
		Checked += _LNCW_WithPlan(Config, _LNCW_NativeRoutesBody.Bind(Config))
	AssertEqual(192, Checked, "every configuration, key and modifier mask must be checked")
}

Test("LLM nav: the native owner never cycles an arrow, so a press never cycles twice (llm-nav-cycle-windows)",
	_LNCW_NativeOwnerNeverCyclesAnArrow)
