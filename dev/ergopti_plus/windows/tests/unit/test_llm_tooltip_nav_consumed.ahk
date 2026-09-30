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
			for Key in ["Up", "Down"] {
				AssertTrue(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Chord)),
					Mods . "+" . Key . ": the committed chord over a multi-slot prediction must be consumed")
				AssertFalse(LLM_Menu_NavCycleChordIsOwned(Key, _LTNC_HeldFn(Other)),
					Mods . "+" . Key . ": another modifier set is the application's")
				Checked++
			}
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Left", _LTNC_HeldFn(Chord)),
				Mods . ": only the two cycle routes may be consumed")
			_LTAV_RenderPrediction(["solo"], 1, true)
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Up", _LTNC_HeldFn(Chord)),
				Mods . ": a single prediction does not cycle, so the arrow stays the application's")
			_LTAV_RenderPrediction(["alpha", "beta"], 1, true)
			State.GetOwnerMode := "refuse"
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Down", _LTNC_HeldFn(Chord)),
				Mods . ": a record the native owner does not route must not swallow the key")
		} finally {
			_LLM_Menu_NavHotkeysBound := Saved.Bound
			_LLM_Menu_NavSlotPlans := Saved.SlotPlans
			_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
			if IsObject(State)
				_LNEO_Teardown()
			_TooltipGeneration := Saved.Generation
		}
	}
	AssertEqual(4, Checked, "both chords and both keys must be checked")
	AssertFalse(LLM_Menu_NavCycleChordIsOwned("Up", _LTNC_HeldFn(Map())),
		"a stopped native owner must never let the key be swallowed")
}

Test("LLM nav: the cycle chord is consumed while the owner routes a multi-slot prediction (llm-tooltip-nav-consumed)",
	_LTNC_ChordConsumedWhileTheOwnerCycles)

_LTNC_ChordHotkeysSwallowTheKey() {
	Src := _StripFullLineComments(_DriverDirConcat("ui/menu/menu_llm"))
	for Key in ["Up", "Down"] {
		Found := 0
		for Variant in _LTAV_Variants(Src, Key) {
			if (Variant.HotIf != '#HotIf LLM_Menu_NavCycleChordIsOwned("' . Key . '")')
				continue
			Found++
			AssertEqual("*", Variant.Prefix,
				Key . ": one wildcard hotkey serves every configured modifier; the criterion demands the exact chord")
			; The action cycles: a bare return swallowed the key without moving the
			; marker once this hook ran first (llm-nav-cycle-windows).
			Assert(RegExMatch(Variant.Body,
					"^\*" . Key . '::\s*LLM_Menu_NavCycleChord\("' . Key . '"\)') > 0,
				Key . ": the hotkey must cycle and consume the key, never pass it on: " . Variant.Body)
		}
		AssertEqual(1, Found, Key . " must have exactly one consuming hotkey")
	}
	Assert(RegExMatch(Src,
			'#InputLevel 1\s+#HotIf LLM_Menu_NavCycleChordIsOwned\("Up"\)') > 0,
		"the consuming hotkeys must take the native routes' input level")
}

Test("LLM nav: the Up and Down chords have consuming hotkeys (llm-tooltip-nav-consumed)",
	_LTNC_ChordHotkeysSwallowTheKey)





; =======================================================
; =======================================================
; ======= 2/ Only the configured chords are owned =======
; =======================================================
; =======================================================

; The maintainer's rule, on every OS: while a prediction is shown, the
; configured navigation chord (nav_modifiers + Up / Down) and validation chord
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
				for Key in ["Up", "Down"] {
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
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Down", Exact),
				Row.Name . ": one prediction has nothing to move to, the arrow is the application's")
			_TooltipActiveSurface := 0
			AssertFalse(LLM_Menu_NavCycleChordIsOwned("Up", Exact),
				Row.Name . ": no tooltip, nothing is consumed")
		} finally {
			_LLM_Menu_NavHotkeysBound := Saved.Bound
			_LLM_Menu_NavSlotPlans := Saved.SlotPlans
			_LLM_Menu_NavActiveSlot := Saved.ActiveSlot
			if IsObject(State)
				_LNEO_Teardown()
			_TooltipGeneration := Saved.Generation
		}
	}
	AssertEqual(52, Checked, "every modifier set, chord and key must be checked")
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
