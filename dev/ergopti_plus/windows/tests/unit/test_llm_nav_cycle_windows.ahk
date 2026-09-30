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
; Left and Right reached the application instead (maintainer report of the
; same evening): only Up and Down had a consuming hotkey. They now step back
; and forward like Up and Down, under the same chord, and so do the footer's
; left and right Shift+Tab; the native owner matches none of them
; (llm-nav-left-right-windows).
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

; The virtual key and scan code of each navigation key (WinUser.h, and the
; scan code AutoHotkey resolves the key name to).
_LNCW_KeyCodes() {
	return Map("Up", [0x26, 0x148], "Down", [0x28, 0x150],
		"Left", [0x25, 0x14B], "Right", [0x27, 0x14D], "Tab", [0x09, 0x00F])
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
	if Held.Has("LShift") || Held.Has("RShift")
		Modifiers |= 0x04
	if Held.Has("LWin") || Held.Has("RWin")
		Modifiers |= 0x08
	Codes := _LNCW_KeyCodes()[Key]
	return Map("vk", Codes[1], "sc", Codes[2], "modifiers", Modifiers)
}

; The native routes of the committed plan, as the adapter marshals them to the
; DLL, whose identity is exactly Event's: its cycle routes only, or every route
; when AnyAction is set.
_LNCW_NativeCycleRoutes(Event, AnyAction := false) {
	global _LLM_Menu_NavHotkeysBound
	Routes := _LLM_NavEventOwnerNativeBindings(_LLM_Menu_NavHotkeysBound)
	AssertTrue(Routes is Array && Routes.Length == 12,
		"the committed plan must marshal its twelve native routes")
	Matches := []
	for Route in Routes {
		Code := Route["axis"] == 2 ? Event["sc"] : Event["vk"]
		if (AnyAction || Route["action"] == 1) && Code == Route["code"]
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

; One press of Tab with HeldNames held, through both hooks in Order. The
; AutoHotkey stage is the SC00F hotkey of the held Shift's side, whose criterion
; demands that Shift alone; no other hotkey of this module matches the press.
; @returns {Object} As _LNCW_Press.
_LNCW_PressShiftTab(State, Probe, HeldNames, Order) {
	HeldFn := _LTNC_HeldFn(_LTNC_HeldMap(HeldNames))
	Before := Probe.Targets.Length
	NativeCycles := 0
	Consumed := false
	for Stage in Order.Stages {
		if (Stage == "ahk") {
			for Side in ["LShift", "RShift"] {
				if LLM_Menu_NavShiftTabIsOwned(Side, HeldFn) {
					LLM_Menu_NavShiftTabCycle(Side, _LNCW_Repaint.Bind(Probe))
					Consumed := true
					break
				}
			}
			if Consumed
				break
		} else {
			NativeCycles += _LNCW_NativeStage(State,
				_LNCW_NativeEvent("Tab", _LTNC_HeldMap(HeldNames)))
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
	for Step in [{ Key: "Down", Target: 3 }, { Key: "Up", Target: 2 },
			{ Key: "Right", Target: 3 }, { Key: "Left", Target: 2 }] {
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
	return 4
}

_LNCW_ExactChordCyclesOnceInEitherOrder() {
	Checked := 0
	for Chord in _LNCW_Chords() {
		for Order in _LNCW_Orders()
			Checked += _LNCW_WithPlan(Chord.Config,
				_LNCW_ExactChordBody.Bind(Chord, Order))
	}
	AssertEqual(16, Checked, "both chords, the four arrows and both hook orders must be checked")
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
		for Key in _LTNC_NavKeys() {
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
	for Key in _LTNC_NavKeys() {
		Press := _LNCW_Press(State, Probe, Key, Chord.Held, Order)
		AssertFalse(Press.Consumed, Label . ", " . Key
			. ": one prediction has nothing to move to, the arrow is the application's")
		AssertEqual(0, Press.Cycles, Label . ", " . Key . ": one prediction never cycles")
		Checked++
	}
	_TooltipActiveSurface := 0
	for Key in _LTNC_NavKeys() {
		Press := _LNCW_Press(State, Probe, Key, Chord.Held, Order)
		AssertFalse(Press.Consumed, Label . ", " . Key
			. ": no tooltip, the arrow is the application's")
		AssertEqual(0, Press.Cycles, Label . ", " . Key . ": no tooltip, nothing cycles")
		Checked++
	}
	return Checked
}

_LNCW_OtherChordsReachTheApplication() {
	Checked := 0
	for Chord in _LNCW_Chords() {
		for Order in _LNCW_Orders()
			Checked += _LNCW_WithPlan(Chord.Config,
				_LNCW_PassBody.Bind(Chord, Order))
	}
	AssertEqual(80, Checked, "every other chord, arrow and hook order must be checked")
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
				{ Key: "Down", From: Count, Target: 1 },
				{ Key: "Left", From: 1, Target: Count },
				{ Key: "Right", From: Count, Target: 1 }] {
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
	AssertEqual(16, Checked, "both ends, both sizes, the four arrows and both hook orders must be checked")
}

Test("LLM nav: the marker wraps around at both ends (llm-nav-cycle-windows)",
	_LNCW_MarkerWrapsAroundAtBothEnds)

_LNCW_ShiftTabBody(Chord, Order, State) {
	global _TooltipActiveSurface
	Label := "'" . Chord.Config . "', " . Order.Name
	Checked := 0
	for Count in [2, 3] {
		Probe := { Slots: [], Targets: [] }
		Loop Count
			Probe.Slots.Push("slot" . A_Index)
		for Step in [{ Held: ["LShift"], From: 2, Target: 1 },
				{ Held: ["RShift"], From: 1, Target: 2 },
				{ Held: ["LShift"], From: 1, Target: Count },
				{ Held: ["RShift"], From: Count, Target: 1 }] {
			Name := Label . ", " . Count . " slots, " . Step.Held[1] . "+Tab from slot " . Step.From
			_LTAV_RenderPrediction(Probe.Slots, Step.From, true)
			Press := _LNCW_PressShiftTab(State, Probe, Step.Held, Order)
			AssertTrue(Press.Consumed, Name . ": Shift+Tab must never reach the application")
			AssertEqual(1, Press.Cycles, Name . ": Shift+Tab must move the marker exactly once")
			AssertEqual(0, Press.NativeCycles, Name . ": the native owner never cycles on Tab")
			AssertEqual(Step.Target, LLM_TooltipGetActiveIdx(),
				Name . ": the marker must land on slot " . Step.Target)
			Checked++
		}
	}
	Probe := { Slots: ["alpha", "beta", "gamma"], Targets: [] }
	_LTAV_RenderPrediction(Probe.Slots, 2, true)
	for Held in [["LShift", "RShift"], ["LShift", "Ctrl"], ["RShift", "Alt"],
			["LShift", "LWin"], []] {
		Press := _LNCW_PressShiftTab(State, Probe, Held, Order)
		AssertFalse(Press.Consumed, Label . ": Tab with " . _LTNC_Join(Held)
			. " is not the Shift+Tab chord and reaches its other owners")
		AssertEqual(0, Press.Cycles, Label . ": Tab with " . _LTNC_Join(Held) . " moves nothing")
		Checked++
	}
	_LTAV_RenderPrediction(["solo"], 1, true)
	for Side in ["LShift", "RShift"] {
		Press := _LNCW_PressShiftTab(State, Probe, [Side], Order)
		AssertFalse(Press.Consumed, Label . ", " . Side
			. "+Tab: one prediction has nothing to move to, Shift+Tab is the application's")
		Checked++
	}
	_TooltipActiveSurface := 0
	for Side in ["LShift", "RShift"] {
		Press := _LNCW_PressShiftTab(State, Probe, [Side], Order)
		AssertFalse(Press.Consumed, Label . ", " . Side . "+Tab: no tooltip, the key is the application's")
		AssertEqual(0, Press.Cycles, Label . ", " . Side . "+Tab: no tooltip, nothing cycles")
		Checked++
	}
	return Checked
}

_LNCW_ShiftTabCyclesOnceInEitherOrder() {
	Checked := 0
	for Chord in _LNCW_Chords() {
		for Order in _LNCW_Orders()
			Checked += _LNCW_WithPlan(Chord.Config,
				_LNCW_ShiftTabBody.Bind(Chord, Order))
	}
	AssertEqual(68, Checked, "both configurations, sides, sizes, refusals and hook orders must be checked")
}

Test("LLM nav: the left Shift+Tab steps back and the right one forward, once, whichever hook runs first (llm-nav-left-right-windows)",
	_LNCW_ShiftTabCyclesOnceInEitherOrder)





; =========================================================
; =========================================================
; ======= 3/ The native owner never cycles an arrow =======
; =========================================================
; =========================================================

_LNCW_NativeRoutesBody(Config, State) {
	global _LLM_Menu_NavHotkeysBound
	Checked := 0
	for Key in ["Up", "Down", "Left", "Right", "Tab"] {
		Loop 16 {
			Event := _LNCW_NativeEvent(Key, Map())
			Event["modifiers"] := A_Index - 1
			; No native route of any kind: the DLL passes every arrow on, and only
			; the AutoHotkey hotkey decides whether it cycles.
			AssertEqual(0, _LNCW_NativeCycleRoutes(Event, true).Length,
				"'" . Config . "': no native route may match " . Key
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
	AssertEqual(480, Checked, "every configuration, navigation key and modifier mask must be checked")
}

Test("LLM nav: the native owner never matches an arrow, so a press never cycles twice (llm-nav-cycle-windows)",
	_LNCW_NativeOwnerNeverCyclesAnArrow)
