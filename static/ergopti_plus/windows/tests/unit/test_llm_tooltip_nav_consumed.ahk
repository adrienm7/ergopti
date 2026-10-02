; tests/unit/test_llm_tooltip_nav_consumed.ahk

; ==============================================================================
; MODULE: Navigation keys over a visible AI prediction are consumed
; DESCRIPTION:
; Regression coverage for a report on a Windows build of 2026-09-30: the
; prediction tooltip's navigation keys reached the application behind it.
;
; MECHANISM ENCODED (llm-tooltip-nav-consumed): the native navigation owner
; cycled the slot on the configured Up / Down chord, but its plan contract
; (NavPlanIsValid) requires every cycle route to pass the key on, so the caret
; always moved in the application too. macOS consumes the arrows while it shows
; several predictions (handle_llm_keys). Static wildcard hotkeys now cycle and
; swallow the committed chord while the owner routes a multi-slot prediction,
; with exactly its modifiers, at the routes' input level; the native owner no
; longer cycles (test_llm_nav_cycle_windows, llm-nav-cycle-windows).
;
; Left and Right then reached the application while the tooltip showed several
; predictions (maintainer report of 2026-09-30): only Up and Down had a
; consuming hotkey, although the shared label reads ↑/← and ↓/→ and macOS
; cycles on all four arrows. Left now steps back like Up and Right forward like
; Down, under the same chord, and the footer's left and right Shift+Tab (⇧G +
; Tab, ⇧D + Tab), which Windows never handled either, step back and forward
; (llm-nav-left-right-windows).
;
; Section 2 (llm-tooltip-chords-consumed) runs the whole matrix of the rule the
; three drivers share: for every configured modifier set, only the exact
; navigation and validation chords are the tooltip's.
;
; Drives the real binder, render commit and native-owner bridge through the
; deterministic port of the navigation owner tests, and reuses the render and
; hotkey-scan helpers of test_llm_tab_accepts_visible_prediction.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ Navigation keys are consumed =======
; ===============================================
; ===============================================

; Held modifier state stand-in for the consumption criterion.
_LTNC_HeldFn(Held) {
	return (Name) => Held.Has(Name)
}

; The four arrows the navigation chord cycles on: ↑/← the previous prediction,
; ↓/→ the next (menu.llm.nav_label).
_LTNC_NavKeys() {
	return ["Up", "Down", "Left", "Right"]
}

; The #InputLevel directive in force at Pos of Src, "" when none precedes it.
_LTNC_InputLevelAt(Src, Pos) {
	Level := ""
	Start := 1
	while (Found := RegExMatch(Src, "m)^\s*#InputLevel\s+(\d+)", &Match, Start)) {
		if (Found >= Pos)
			break
		Level := Match[1]
		Start := Found + Match.Len
	}
	return Level
}

_LTNC_ChordConsumedWhileTheOwnerCycles() {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, _TooltipGeneration
	Saved := {
		Bound: _LLM_Menu_NavHotkeysBound, SlotPlans: _LLM_Menu_NavSlotPlans,
		ActiveSlot: _LLM_Menu_NavActiveSlot, Generation: _TooltipGeneration
	}
	Checked := 0
	for Mods in ["", "ctrl"] {
		State := 0
		try {
			_LLM_Menu_NavHotkeysBound := []
			_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
			_LLM_Menu_NavActiveSlot := 0
			State := _LNEO_Setup()
			Chord := Mods == "" ? Map() : Map("Ctrl", true)
			Other := Mods == "" ? Map("Shift", true) : Map()
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Up", _LTNC_HeldFn(Chord)),
				Mods . ": no committed plan means no chord, so nothing to consume")
			Bound := LLM_Menu_BindNavHotkeys(
				Map("nav_modifiers", Mods, "val_modifiers", ""), 0, 0,
				_LNEO_CaptureLog.Bind(State), 0,
				_LNEO_ResolveUsPhysicalKey.Bind(State), State.Port)
			AssertTrue((Bound is Integer) && Bound == 1,
				Mods . ": the navigation plan must commit through the native owner")
			_LTAV_RenderPrediction(["alpha", "beta", "gamma"], 1, true)
			for Key in _LTNC_NavKeys() {
				AssertTrue(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Chord)),
					Mods . "+" . Key . ": the committed chord over a multi-slot prediction must be consumed")
				AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Other)),
					Mods . "+" . Key . ": another modifier set is the application's")
				Checked++
			}
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Home", _LTNC_HeldFn(Chord)),
				Mods . ": only the four arrows may be consumed")
			AssertEqual(12, _LLM_Menu_NavHotkeysBound.Length,
				Mods . ": Left and Right share the Up and Down routes, the plan gains no native route")
			_LTAV_RenderPrediction(["solo"], 1, true)
			for Key in _LTNC_NavKeys()
				AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Chord)),
					Mods . "+" . Key . ": a single prediction does not cycle, so the arrow stays the application's")
			_LTAV_RenderPrediction(["alpha", "beta"], 1, true)
			State.GetOwnerMode := "refuse"
			for Key in _LTNC_NavKeys()
				AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Chord)),
					Mods . "+" . Key . ": a record the native owner does not route must not swallow the key")
		} finally {
			_LLM_Menu_NavHotkeysBound := Saved.Bound
			_LLM_Menu_NavSlotPlans := Saved.SlotPlans
			_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
			if IsObject(State)
				_LNEO_Teardown()
			_TooltipGeneration := Saved.Generation
		}
	}
	AssertEqual(8, Checked, "both chords and the four arrows must be checked")
	for Key in _LTNC_NavKeys()
		AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Map())),
			Key . ": a stopped native owner must never let the key be swallowed")
}

Test("LLM nav: the cycle chord is consumed while the owner routes a multi-slot prediction (llm-tooltip-nav-consumed)",
	_LTNC_ChordConsumedWhileTheOwnerCycles)

_LTNC_ChordHotkeysSwallowTheKey() {
	static Registry := JsonParse(FileRead(_SharedDir . "\data\keycodes\physical_keys.json", "UTF-8"))
	Src := _StripFullLineComments(_DriverDirConcat("ui/menu/menu_llm"))
	for Key in _LTNC_NavKeys() {
		; Physical identity is independent of the production declaration.
		Code := Registry["keys"]["Arrow" . Key]["ahk"]
		Found := 0
		for Variant in _LTAV_Variants(Src, Code) {
			if (Variant.HotIf != '#HotIf LLM_Menu_NavCycleChordIsOwned("' . Key . '")')
				continue
			Found++
			AssertEqual("*", Variant.Prefix,
				Key . ": one wildcard hotkey serves every configured modifier; the criterion demands the exact chord")
			; The action cycles: a bare return swallowed the key without moving the
			; marker once this hook ran first (llm-nav-cycle-windows).
			Assert(RegExMatch(Variant.Body,
					"^\*" . Code . '::\s*LLM_Menu_NavCycleChord\("' . Key . '"\)') > 0,
				Key . ": the hotkey must cycle and consume the key, never pass it on: " . Variant.Body)
		}
		AssertEqual(1, Found, Key . " must have exactly one consuming hotkey")
		; The directive order, not the file, decides the level: each consuming
		; hotkey is read at the #InputLevel that precedes its criterion.
		HotIfPos := InStr(Src, '#HotIf LLM_Menu_NavCycleChordIsOwned("' . Key . '")')
		Assert(HotIfPos > 0, Key . ": the consuming criterion must be found")
		AssertEqual("1", _LTNC_InputLevelAt(Src, HotIfPos),
			Key . ": the consuming hotkey must take the native routes' input level")
	}
}

Test("LLM nav: the four arrow chords have consuming hotkeys (llm-tooltip-nav-consumed, llm-nav-left-right-windows)",
	_LTNC_ChordHotkeysSwallowTheKey)

; The footer's Shift+Tab: the left Shift steps back, the right one forward,
; alone and whatever nav_modifiers holds; both Shifts, another modifier, one
; prediction, no routed record or the Tab key's own owners leave the key to the
; application or to that owner.
_LTNC_ShiftTabIsTheFootersChord() {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, _TooltipGeneration, LayerEnabled
	Saved := {
		Bound: _LLM_Menu_NavHotkeysBound, SlotPlans: _LLM_Menu_NavSlotPlans,
		ActiveSlot: _LLM_Menu_NavActiveSlot, Generation: _TooltipGeneration,
		Layer: LayerEnabled
	}
	Checked := 0
	for Mods in ["", "ctrl", "alt+shift"] {
		State := 0
		try {
			_LLM_Menu_NavHotkeysBound := []
			_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
			_LLM_Menu_NavActiveSlot := 0
			State := _LNEO_Setup()
			Bound := LLM_Menu_BindNavHotkeys(
				Map("nav_modifiers", Mods, "val_modifiers", ""), 0, 0,
				_LNEO_CaptureLog.Bind(State), 0,
				_LNEO_ResolveUsPhysicalKey.Bind(State), State.Port)
			AssertTrue((Bound is Integer) && Bound == 1,
				"'" . Mods . "': the navigation plan must commit through the native owner")
			_LTAV_RenderPrediction(["alpha", "beta", "gamma"], 2, true)
			for Row in [
					{ Held: ["LShift"], Side: "LShift" },
					{ Held: ["RShift"], Side: "RShift" },
					{ Held: ["LShift", "RShift"], Side: "" },
					{ Held: ["LShift", "Ctrl"], Side: "" },
					{ Held: ["RShift", "Alt"], Side: "" },
					{ Held: ["LShift", "LWin"], Side: "" },
					{ Held: ["RShift", "RWin"], Side: "" },
					{ Held: [], Side: "" }] {
				Held := _LTNC_HeldFn(_LTNC_HeldMap(Row.Held))
				AssertEqual(Row.Side, LLM_Menu_NavShiftTabSide(Held),
					"'" . Mods . "': the Shift+Tab side of " . _LTNC_Join(Row.Held))
				for Side in ["LShift", "RShift"] {
					AssertEqual(Side == Row.Side,
						LLM_Menu_NavShiftTabIsOwned(Side, Held) ? true : false,
						"'" . Mods . "': " . Side . "+Tab with " . _LTNC_Join(Row.Held)
						. " is consumed only when that Shift alone is held")
					Checked++
				}
			}
			LeftOnly := _LTNC_HeldFn(Map("LShift", true))
			RightOnly := _LTNC_HeldFn(Map("RShift", true))
			; The Tab key's own owners keep the press (platform/remap/tab.ahk).
			LayerEnabled := true
			AssertFalse(LLM_Menu_NavShiftTabIsOwned("LShift", LeftOnly),
				"'" . Mods . "': the navigation layer keeps Tab while it is held")
			LayerEnabled := Saved.Layer
			_TapHoldClaimPress("tab")
			try AssertFalse(LLM_Menu_NavShiftTabIsOwned("RShift", RightOnly),
				"'" . Mods . "': the auto-repeat of a press a Tab tap-hold owns is that owner's")
			finally _TapHoldEndPressClaim("tab")
			AssertFalse(LLM_Menu_NavShiftTabIsOwned("Up", LeftOnly),
				"'" . Mods . "': only the left and right Shift are Shift+Tab sides")
			_LTAV_RenderPrediction(["solo"], 1, true)
			AssertFalse(LLM_Menu_NavShiftTabIsOwned("LShift", LeftOnly),
				"'" . Mods . "': one prediction has nothing to move to, Shift+Tab is the application's")
			_LTAV_RenderPrediction(["alpha", "beta"], 1, true)
			State.GetOwnerMode := "refuse"
			AssertFalse(LLM_Menu_NavShiftTabIsOwned("RShift", RightOnly),
				"'" . Mods . "': a record the native owner does not route must not swallow Shift+Tab")
		} finally {
			_LLM_Menu_NavHotkeysBound := Saved.Bound
			_LLM_Menu_NavSlotPlans := Saved.SlotPlans
			_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
			LayerEnabled := Saved.Layer
			if IsObject(State)
				_LNEO_Teardown()
			_TooltipGeneration := Saved.Generation
		}
	}
	AssertEqual(48, Checked, "every configuration, held set and side must be checked")
	AssertFalse(LLM_Menu_NavShiftTabIsOwned("LShift", _LTNC_HeldFn(Map("LShift", true))),
		"a stopped native owner must never let Shift+Tab be swallowed")
}

_LTNC_Join(Names) {
	Text := ""
	for Name in Names
		Text .= (Text == "" ? "" : "+") . Name
	return Text == "" ? "nothing" : Text
}

Test("LLM nav: the left and right Shift+Tab of the footer are consumed exactly (llm-nav-left-right-windows)",
	_LTNC_ShiftTabIsTheFootersChord)

; The physical Tab is SC00F. A side-specific Shift makes each hotkey the most
; specific SC00F hotkey under its Shift, at the native routes' input level, and
; its action cycles.
_LTNC_ShiftTabHotkeysSwallowTheKey() {
	Src := _StripFullLineComments(_DriverDirConcat("ui/menu/menu_llm"))
	for Pair in [["LShift", "<+"], ["RShift", ">+"]] {
		Found := 0
		for Variant in _LTAV_Variants(Src, "SC00F") {
			if (Variant.HotIf != '#HotIf LLM_Menu_NavShiftTabIsOwned("' . Pair[1] . '")')
				continue
			Found++
			AssertEqual(Pair[2], Variant.Prefix,
				Pair[1] . ": the hotkey must name that Shift alone, without the wildcard")
			Assert(RegExMatch(Variant.Body, "^\Q" . Pair[2] . "\ESC00F::\s*"
					. 'LLM_Menu_NavShiftTabCycle\("' . Pair[1] . '"\)') > 0,
				Pair[1] . ": the hotkey must cycle and consume Shift+Tab: " . Variant.Body)
		}
		AssertEqual(1, Found, Pair[1] . "+Tab must have exactly one consuming hotkey")
		HotIfPos := InStr(Src, '#HotIf LLM_Menu_NavShiftTabIsOwned("' . Pair[1] . '")')
		AssertEqual("1", _LTNC_InputLevelAt(Src, HotIfPos),
			Pair[1] . ": the consuming hotkey must take the native routes' input level")
	}
}

Test("LLM nav: the left and right Shift+Tab have consuming SC00F hotkeys (llm-nav-left-right-windows)",
	_LTNC_ShiftTabHotkeysSwallowTheKey)

; A tap-hold's Tab tapped under one Shift is the user's Shift+Tab (the
; recommended AltGr taps Tab): it moves the marker like the physical chord,
; types nothing, and the Tab wrapper asks it before acceptance.
_LTNC_TapHoldShiftTabNavigates() {
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
			Map("nav_modifiers", "", "val_modifiers", ""), 0, 0,
			_LNEO_CaptureLog.Bind(State), 0,
			_LNEO_ResolveUsPhysicalKey.Bind(State), State.Port)
		AssertTrue((Bound is Integer) && Bound == 1,
			"the navigation plan must commit through the native owner")
		Slots := ["alpha", "beta", "gamma"]
		for Step in [{ Held: "LShift", From: 1, Target: 3 },
				{ Held: "RShift", From: 3, Target: 1 },
				{ Held: "RShift", From: 1, Target: 2 },
				{ Held: "LShift", From: 2, Target: 1 }] {
			_LTAV_RenderPrediction(Slots, Step.From, true)
			; The in-place repaint stand-in of test_llm_nav_cycle_windows.
			Probe := { Slots: Slots, Targets: [] }
			AssertTrue(LLM_Menu_NavShiftTabTap(_LTNC_HeldFn(Map(Step.Held, true)),
					_LNCW_Repaint.Bind(Probe)),
				Step.Held . "+tapped Tab from slot " . Step.From . " must be consumed")
			AssertEqual(1, Probe.Targets.Length, Step.Held . ": the tap must cycle exactly once")
			AssertEqual(Step.Target, LLM_TooltipGetActiveIdx(),
				Step.Held . "+tapped Tab must move the marker from slot " . Step.From
				. " to slot " . Step.Target)
		}
		for Held in [Map(), Map("LShift", true, "RShift", true),
				Map("LShift", true, "Ctrl", true)] {
			AssertFalse(LLM_Menu_NavShiftTabTap(_LTNC_HeldFn(Held), (*) => true),
				"a tap without exactly one Shift is left to acceptance or the typed Tab")
		}
		_LTAV_RenderPrediction(["solo"], 1, true)
		AssertFalse(LLM_Menu_NavShiftTabTap(_LTNC_HeldFn(Map("LShift", true)), (*) => true),
			"over one prediction the tapped Shift+Tab is typed")
	} finally {
		_LLM_Menu_NavHotkeysBound := Saved.Bound
		_LLM_Menu_NavSlotPlans := Saved.SlotPlans
		_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
		if IsObject(State)
			_LNEO_Teardown()
		_TooltipGeneration := Saved.Generation
	}
	Body := _DriverFuncBody("LLM_Tooltip_FireTabOrAccept")
	NavAt := InStr(Body, "LLM_Menu_NavShiftTabTap(ModifierIsHeldFn)")
	Assert(NavAt > 0 && InStr(Body, "_LLM_Accept_TapHoldTapKey(TabProvenance)") > 0,
		"the Tab wrapper must offer a tap-hold's Tab to the Shift+Tab chord: " . Body)
	Assert(NavAt < InStr(Body, "LLM_Tooltip_TryAcceptTab("),
		"the Shift+Tab chord must be asked before acceptance and the typed Tab")
}

Test("LLM nav: a tap-hold's Tab under one Shift navigates like the physical Shift+Tab (llm-nav-left-right-windows)",
	_LTNC_TapHoldShiftTabNavigates)

; The footer advertises every chord the hotkeys consume: Shift+Tab on either
; side, then the arrows with the configured modifiers, bare by default, as the
; macOS footer does. It showed the arrows only under a modifier, so the default
; bare arrows were never advertised. Distinct tokens stand for the shared
; strings, which this harness does not load (UiStyle_LoadSharedConst).
_LTNC_FooterAdvertisesEveryChord() {
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_HINT_ACCEPT_SINGLE, UI_LLM_HINT_NAV_LEFT
	global UI_LLM_HINT_NAV_RIGHT, UI_LLM_HINT_ACCEPT_CENTER, UI_LLM_HINT_ARROW_LEFT
	global UI_LLM_HINT_ARROW_RIGHT, UI_LLM_HINT_OR, UI_LLM_HINT_ARROW_SEP_LEFT
	global UI_LLM_HINT_ARROW_SEP_RIGHT
	Saved := [UI_LLM_FOOTER_SPACE_DIV, UI_LLM_HINT_ACCEPT_SINGLE, UI_LLM_HINT_NAV_LEFT,
		UI_LLM_HINT_NAV_RIGHT, UI_LLM_HINT_ACCEPT_CENTER, UI_LLM_HINT_ARROW_LEFT,
		UI_LLM_HINT_ARROW_RIGHT, UI_LLM_HINT_OR, UI_LLM_HINT_ARROW_SEP_LEFT,
		UI_LLM_HINT_ARROW_SEP_RIGHT]
	try {
		UI_LLM_FOOTER_SPACE_DIV := "|"
		UI_LLM_HINT_ACCEPT_SINGLE := "[single]"
		UI_LLM_HINT_NAV_LEFT := "[left shift+tab]"
		UI_LLM_HINT_NAV_RIGHT := "[right shift+tab]"
		UI_LLM_HINT_ACCEPT_CENTER := "[accept]"
		UI_LLM_HINT_ARROW_LEFT := "[up/left]"
		UI_LLM_HINT_ARROW_RIGHT := "[down/right]"
		UI_LLM_HINT_OR := " or "
		UI_LLM_HINT_ARROW_SEP_LEFT := "<"
		UI_LLM_HINT_ARROW_SEP_RIGHT := ">"
		AssertEqual("[single]", _LLM_BuildNavHint(1, ""),
			"one prediction only offers Tab")
		AssertEqual("[left shift+tab] or [up/left]|<|[accept]|>|[right shift+tab] or [down/right]",
			_LLM_BuildNavHint(3, ""),
			"the bare arrows, the default chord, must be advertised beside Shift+Tab")
		AssertEqual("[left shift+tab] or Ctrl + [up/left]|<|[accept]|>|[right shift+tab] or Ctrl + [down/right]",
			_LLM_BuildNavHint(3, "ctrl"),
			"the arrows carry the configured modifiers")
		AssertEqual("[left shift+tab]|<|[accept]|>|[right shift+tab]",
			_LLM_BuildNavHint(2, "none"),
			"'none' hides the arrows, as on macOS")
	} finally {
		UI_LLM_FOOTER_SPACE_DIV := Saved[1]
		UI_LLM_HINT_ACCEPT_SINGLE := Saved[2]
		UI_LLM_HINT_NAV_LEFT := Saved[3]
		UI_LLM_HINT_NAV_RIGHT := Saved[4]
		UI_LLM_HINT_ACCEPT_CENTER := Saved[5]
		UI_LLM_HINT_ARROW_LEFT := Saved[6]
		UI_LLM_HINT_ARROW_RIGHT := Saved[7]
		UI_LLM_HINT_OR := Saved[8]
		UI_LLM_HINT_ARROW_SEP_LEFT := Saved[9]
		UI_LLM_HINT_ARROW_SEP_RIGHT := Saved[10]
	}
}

Test("LLM nav: the footer advertises Shift+Tab and the arrows, bare by default (llm-nav-left-right-windows)",
	_LTNC_FooterAdvertisesEveryChord)





; =======================================================
; =======================================================
; ======= 2/ Only the configured chords are owned =======
; =======================================================
; =======================================================

; The maintainer's rule, on every OS: while a prediction is shown, the
; configured navigation chord (nav_modifiers + an arrow) and validation chord
; (val_modifiers + 1..9, 0) are the tooltip's, and every other chord (bare, a
; superset, a subset or another modifier set) reaches the application
; (llm-tooltip-chords-consumed). Each row configures one modifier set; Mods
; names it by the criterion's modifier names, Win standing for either Win key.
_LTNC_ModifierSets() {
	return [
		{ Name: "none", Config: "", Mods: [],
			Superset: ["Shift"], Other: ["Alt"], Subset: 0 },
		{ Name: "shift", Config: "shift", Mods: ["Shift"],
			Superset: ["Shift", "Ctrl"], Other: ["Alt"], Subset: 0 },
		{ Name: "ctrl", Config: "ctrl", Mods: ["Ctrl"],
			Superset: ["Ctrl", "Shift"], Other: ["Alt"], Subset: 0 },
		{ Name: "alt", Config: "alt", Mods: ["Alt"],
			Superset: ["Alt", "Shift"], Other: ["Ctrl"], Subset: 0 },
		{ Name: "win", Config: "win", Mods: ["Win"],
			Superset: ["Win", "Shift"], Other: ["Alt"], Subset: 0 },
		{ Name: "ctrl+shift", Config: "ctrl+shift", Mods: ["Ctrl", "Shift"],
			Superset: ["Ctrl", "Shift", "Alt"], Other: ["Alt"], Subset: ["Shift"] }
	]
}

; The chords pressed against one row: held key names for the criterion, where
; Win is pressed as the left Win key, and once more as the right one.
_LTNC_ChordsFor(Row) {
	Chords := [
		{ Label: "exact", Held: _LTNC_HeldNames(Row.Mods, "LWin") },
		{ Label: "bare", Held: [] },
		{ Label: "superset", Held: _LTNC_HeldNames(Row.Superset, "LWin") },
		{ Label: "other", Held: _LTNC_HeldNames(Row.Other, "LWin") }
	]
	if IsObject(Row.Subset)
		Chords.Push({ Label: "subset", Held: _LTNC_HeldNames(Row.Subset, "LWin") })
	for Name in Row.Mods {
		if (Name == "Win")
			Chords.Push({ Label: "exact, right Win", Held: _LTNC_HeldNames(Row.Mods, "RWin") })
	}
	return Chords
}

_LTNC_HeldNames(Mods, WinKey) {
	Held := []
	for Name in Mods
		Held.Push(Name == "Win" ? WinKey : Name)
	return Held
}

_LTNC_HeldMap(Names) {
	Held := Map()
	for Name in Names
		Held[Name] := true
	return Held
}

; The oracle: whether held keys name exactly the configured modifiers.
_LTNC_SameMods(Held, Mods) {
	Wanted := Map()
	for Name in Mods
		Wanted[Name] := true
	Seen := Map()
	for Name in Held {
		Modifier := (Name == "LWin" || Name == "RWin") ? "Win" : Name
		if !Wanted.Has(Modifier)
			return false
		Seen[Modifier] := true
	}
	return Seen.Count == Wanted.Count
}

; The hotkey prefix of a modifier set, in the native identity's ^!+# order.
_LTNC_Prefix(Mods) {
	Prefix := ""
	for Pair in [["Ctrl", "^"], ["Alt", "!"], ["Shift", "+"], ["Win", "#"]] {
		for Name in Mods {
			if (Name == Pair[1])
				Prefix .= Pair[2]
		}
	}
	return Prefix
}

_LTNC_OnlyTheConfiguredChordsAreOwned() {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot, _TooltipGeneration, _TooltipActiveSurface
	Saved := {
		Bound: _LLM_Menu_NavHotkeysBound, SlotPlans: _LLM_Menu_NavSlotPlans,
		ActiveSlot: _LLM_Menu_NavActiveSlot, Generation: _TooltipGeneration
	}
	Checked := 0
	for Row in _LTNC_ModifierSets() {
		State := 0
		try {
			_LLM_Menu_NavHotkeysBound := []
			_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
			_LLM_Menu_NavActiveSlot := 0
			State := _LNEO_Setup()
			Bound := LLM_Menu_BindNavHotkeys(
				Map("nav_modifiers", Row.Config, "val_modifiers", Row.Config), 0, 0,
				_LNEO_CaptureLog.Bind(State), 0,
				_LNEO_ResolveUsPhysicalKey.Bind(State), State.Port)
			AssertTrue((Bound is Integer) && Bound == 1,
				Row.Name . ": the navigation plan must commit through the native owner")

			; The native owner matches a route's modifiers exactly, either side of a
			; modifier alike, so the committed plan must carry exactly this chord.
			Prefix := _LTNC_Prefix(Row.Mods)
			AssertEqual(Prefix . "sc0148", _LLM_Menu_NavHotkeysBound[1]["physical_id"],
				Row.Name . ": the Up route is the configured chord")
			AssertEqual(Prefix . "sc0150", _LLM_Menu_NavHotkeysBound[2]["physical_id"],
				Row.Name . ": the Down route is the configured chord")
			AssertEqual(12, _LLM_Menu_NavHotkeysBound.Length,
				Row.Name . ": Left and Right add no native route to the plan")
			Loop 10 {
				Digit := A_Index == 10 ? "0" : String(A_Index)
				Entry := _LLM_Menu_NavHotkeysBound[A_Index + 2]
				AssertEqual(Prefix . Format("vk{:04X}", Ord(Digit)), Entry["physical_id"],
					Row.Name . "+" . Digit . ": the validation route is the configured chord")
				AssertEqual(A_Index, Entry["jump_idx"],
					Row.Name . "+" . Digit . ": the validation route inserts slot " . A_Index)
			}

			_LTAV_RenderPrediction(["alpha", "beta", "gamma"], 2, true)
			for Chord in _LTNC_ChordsFor(Row) {
				Owned := _LTNC_SameMods(Chord.Held, Row.Mods)
				for Key in _LTNC_NavKeys() {
					Consumed := LLM_Menu_NavCycleChordIsOwned(Key,
						_LTNC_HeldFn(_LTNC_HeldMap(Chord.Held))) ? true : false
					AssertEqual(Owned, Consumed,
						Row.Name . ": " . Chord.Label . " " . Key
						. " is consumed only when it is the configured chord")
					Checked++
				}
			}
			Exact := _LTNC_HeldFn(_LTNC_HeldMap(_LTNC_HeldNames(Row.Mods, "LWin")))
			_LTAV_RenderPrediction(["solo"], 1, true)
			for Key in _LTNC_NavKeys()
				AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, Exact),
					Row.Name . "+" . Key . ": one prediction has nothing to move to, the arrow is the application's")
			_TooltipActiveSurface := 0
			for Key in _LTNC_NavKeys()
				AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, Exact),
					Row.Name . "+" . Key . ": no tooltip, nothing is consumed")
		} finally {
			_LLM_Menu_NavHotkeysBound := Saved.Bound
			_LLM_Menu_NavSlotPlans := Saved.SlotPlans
			_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
			if IsObject(State)
				_LNEO_Teardown()
			_TooltipGeneration := Saved.Generation
		}
	}
	AssertEqual(104, Checked, "every modifier set, chord and arrow must be checked")
}

Test("LLM nav: only the configured navigation and validation chords are owned (llm-tooltip-chords-consumed)",
	_LTNC_OnlyTheConfiguredChordsAreOwned)





; ============================================================
; ============================================================
; ======= 3/ The validation digit is the digit-row key =======
; ============================================================
; ============================================================

; A French AZERTY host: its digit row types & é " ' ( - è _ ç à, and each digit
; needs Shift on the key that bears it, as VkKeyScanExW reports.
_LTNC_ResolveFrenchPhysicalKey(Key) {
	LowerKey := StrLower(Key)
	if LowerKey == "up"
		return Map("axis", "sc", "code", 0x148, "implicit_modifiers", "")
	if LowerKey == "down"
		return Map("axis", "sc", "code", 0x150, "implicit_modifiers", "")
	if RegExMatch(LowerKey, "^[0-9]$")
		return Map("axis", "vk", "code", Ord(LowerKey), "implicit_modifiers", "+")
	return false
}

; The recommended preset's digit-row emulation (direct_access_digits) types 1
; with the bare digit-row key on an AZERTY host. The validation chord was
; resolved by the character, Shift+VK_1 there, so the key the user presses to
; type 1 never matched the native route and the digit was typed instead of
; inserting slot 1 (llm-accept-inserts). The chord now names the digit-row key,
; VK_0 to VK_9, with exactly the configured modifiers, as macOS and Linux do.
_LTNC_ValChordIsTheDigitRowKey() {
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavSlotPlans
	global _LLM_Menu_NavActiveSlot
	Saved := {
		Bound: _LLM_Menu_NavHotkeysBound, SlotPlans: _LLM_Menu_NavSlotPlans,
		ActiveSlot: _LLM_Menu_NavActiveSlot
	}
	Checked := 0
	for Row in [{ Config: "", Prefix: "" }, { Config: "alt", Prefix: "!" },
			{ Config: "ctrl+shift", Prefix: "^+" }] {
		State := 0
		try {
			_LLM_Menu_NavHotkeysBound := []
			_LLM_Menu_NavSlotPlans := Map(1, [], 2, [])
			_LLM_Menu_NavActiveSlot := 0
			State := _LNEO_Setup()
			Bound := LLM_Menu_BindNavHotkeys(
				Map("nav_modifiers", "", "val_modifiers", Row.Config), 0, 0,
				_LNEO_CaptureLog.Bind(State), 0,
				_LTNC_ResolveFrenchPhysicalKey, State.Port)
			AssertTrue((Bound is Integer) && Bound == 1,
				"'" . Row.Config . "': the plan must commit on an AZERTY host")
			AssertEqual(ObjPtr(State.PreparedPlan), ObjPtr(_LLM_Menu_NavHotkeysBound),
				"'" . Row.Config . "': the native owner must receive exactly the published plan")
			Loop 10 {
				Digit := A_Index == 10 ? "0" : String(A_Index)
				Entry := _LLM_Menu_NavHotkeysBound[A_Index + 2]
				AssertEqual(Row.Prefix . Format("vk{:04X}", Ord(Digit)),
					Entry["physical_id"],
					"'" . Row.Config . "'+" . Digit
					. ": the chord is the digit-row key, never the Shift AZERTY needs to type the digit")
				AssertEqual(A_Index, Entry["jump_idx"])
				Checked++
			}
		} finally {
			_LLM_Menu_NavHotkeysBound := Saved.Bound
			_LLM_Menu_NavSlotPlans := Saved.SlotPlans
			_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
			if IsObject(State)
				_LNEO_Teardown()
		}
	}
	AssertEqual(30, Checked, "every configured chord and digit must be checked")
}

Test("LLM nav: a validation digit is the digit-row key the Ergopti layout types it with (llm-accept-inserts)",
	_LTNC_ValChordIsTheDigitRowKey)
