; tests/unit/test_llm_tooltip_nav_consumed.ahk

; ==============================================================================
; MODULE: Navigation keys over a visible AI prediction are consumed
; DESCRIPTION:
; Regression coverage for a report on a Windows build of 2026-09-30: the
; prediction tooltip's navigation keys reached the application behind it.
;
; MECHANISM ENCODED (llm-tooltip-nav-consumed): the native navigation owner
; cycles the slot on the configured Up / Down chord, but its plan contract
; (NavPlanIsValid) requires every cycle route to pass the key on, so the caret
; always moved in the application too. macOS consumes the arrows while it shows
; several predictions (handle_llm_keys). Static wildcard hotkeys, next in the
; hook chain, now swallow the committed cycle chord while the owner cycles a
; multi-slot prediction, with exactly its modifiers, at the routes' input level.
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
				Mods . ": no committed plan means no native cycle, so nothing to consume")
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

Test("LLM nav: the cycle chord is consumed while the owner cycles a multi-slot prediction (llm-tooltip-nav-consumed)",
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
			Assert(RegExMatch(Variant.Body, "^\*" . Key . "::\s*return\b") > 0,
				Key . ": the hotkey must consume the key, never pass it on: " . Variant.Body)
		}
		AssertEqual(1, Found, Key . " must have exactly one consuming hotkey")
	}
	Assert(RegExMatch(Src,
			'#InputLevel 1\s+#HotIf LLM_Menu_NavCycleChordIsOwned\("Up"\)') > 0,
		"the consuming hotkeys must take the native routes' input level")
}

Test("LLM nav: the Up and Down chords have consuming hotkeys (llm-tooltip-nav-consumed)",
	_LTNC_ChordHotkeysSwallowTheKey)
