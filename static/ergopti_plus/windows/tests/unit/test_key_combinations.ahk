; static/ergopti_plus/windows/tests/unit/test_key_combinations.ahk

; ==============================================================================
; MODULE: Key Combinations
; DESCRIPTION:
; « Combinaisons de touches » was three fixed chords on Windows (AltGr+LAlt,
; AltGr+CapsLock, LAlt+CapsLock), each one boolean per action, in one order
; only. It is now every ordered pair of tap-hold keys, the key held first then
; the key struck under it, each with a tap slot and a hold slot, as on macOS
; (infra/key_combinations.ahk). These tests drive that module through its
; seams: no keyboard is hooked and no key is sent.
;
; FEATURES & RATIONALE:
; 1. The order of the two keys is the whole feature, so the criterion is
;    replayed press by press over a fake set of physical keys: a first key
;    already down starts a pair, a key held alone and then joined by another
;    does not, and the repeats of a press a pair took stay with that pair.
; 2. The handler is replayed with recording ports for the holds; the actions
;    run for real, through the catalogue, against the suite's stubs.
; 3. The slots are written to a real config.toml in a temporary folder.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================
; ===========================
; ======= 1/ Fixtures =======
; ===========================
; ===========================






; ===========================
; ===========================
; ======= 2/ Pair ids =======
; ===========================
; ===========================

_KCT_PairIds() {
	AssertEqual("left_alt_then_caps_lock", KeyCombinationPairId("left_alt", "caps_lock"),
		"a pair id spells the key held first, then the key struck under it")
	Parsed := KeyCombinationParsePair("left_alt_then_caps_lock")
	Assert(Parsed is Map, "a pair of two catalogue keys parses")
	AssertEqual("left_alt", Parsed["first"])
	AssertEqual("caps_lock", Parsed["second"])
	Reversed := KeyCombinationParsePair("caps_lock_then_left_alt")
	AssertEqual("caps_lock", Reversed["first"], "the other order is another pair")
	for _, Bad in ["left_alt_then_left_alt", "left_alt_then_fn", "left_alt", "left_alt__caps_lock", "", 3]
		AssertFalse(KeyCombinationParsePair(Bad) is Map, "'" . String(Bad) . "' names no pair")
	Ids := KeyCombinationKeyIds()
	AssertEqual(14, Ids.Length, "the pairs are made of the Windows keys of the shared tap-hold catalogue")
	Joined := ""
	for _, Id in Ids
		Joined .= (Joined == "" ? "" : "|") . Id
	AssertEqual(Joined, TomlConfigKeyCombinationKeys(),
		"the configuration loader admits exactly the catalogue's keys, in its order")
	for _, Section in ["shortcuts.key_combination_taps", "shortcuts.key_combination_holds"] {
		AssertEqual("KeyCombinations", TomlConfigForeignOwner(Section, "escape_then_delete"),
			Section . ": a pair the manifest does not declare is an owned key, not an unknown one")
		AssertEqual("", TomlConfigForeignOwner(Section, "escape_then_fn"), Section . ": a key of another driver is unknown")
	}
	AssertTrue(TomlConfigActionParameterIsOwned("combination__left_alt_then_caps_lock__send_text"),
		"a pair's action stores its parameter under the binding grammar")
}
Test("key combinations: a pair id is two catalogue keys in order (key-combinations-2026-10-01)", _KCT_PairIds)

_KCT_ManifestPreset() {
	Expected := Map("alt_gr_then_left_alt", "ctrl_backspace", "alt_gr_then_caps_lock", "ctrl_delete",
		"left_alt_then_caps_lock", "caps_word")
	Declared := 0
	for _, Entry in ManifestFeaturesForSection("shortcuts.key_combination_taps") {
		Declared += 1
		Assert(KeyCombinationParsePair(Entry["id"]) is Map, Entry["id"] . " is a pair of catalogue keys")
		Assert(Expected.Has(Entry["id"]), Entry["id"] . " is one of the three chords the driver always had")
		AssertEqual("none", Entry["default"], Entry["id"] . ": an empty configuration binds no pair")
		AssertEqual(Expected[Entry["id"]], ManifestRecommendedFor(Entry["path"]),
			Entry["id"] . " keeps the action its family recommended")
		Assert(GESTURE_ACTIONS.Has(Expected[Entry["id"]]), "that action is in the catalogue")
	}
	AssertEqual(3, Declared, "the three former families are the declared pairs")
}
Test("key combinations: the three former chords are the recommended pairs (key-combinations-2026-10-01)",
	_KCT_ManifestPreset)





; ====================================
; ====================================
; ======= 3/ Reading the slots =======
; ====================================
; ====================================

_KCT_ReadConfig() {
	Body() {
		Cache := Map(
			"shortcuts.key_combination_taps", Map(
				"left_alt_then_caps_lock", "caps_word",
				"caps_lock_then_left_alt", "caps_lock",
				"alt_gr_then_left_alt", "none",
				"space_then_enter", "no_such_action",
				"left_alt_then_left_alt", "caps_word",
				"left_alt_then_fn", "caps_word"),
			"shortcuts.key_combination_holds", Map(
				"left_alt_then_caps_lock", "ctrl+shift",
				"tab_then_space", "nav",
				"escape_then_tab", "hyper",
				"enter_then_tab", "none"))
		KeyCombinationsReadConfig(Cache)
		AssertEqual("caps_word", KeyCombinationTapOf("left_alt_then_caps_lock"))
		AssertEqual("caps_lock", KeyCombinationTapOf("caps_lock_then_left_alt"), "each order has its own slot")
		AssertEqual("none", KeyCombinationTapOf("alt_gr_then_left_alt"))
		AssertEqual("none", KeyCombinationTapOf("space_then_enter"), "an unknown action leaves the slot empty")
		AssertEqual(2, KeyCombinationTaps.Count, "a pair of one key twice or of an unknown key is ignored")
		AssertEqual("ctrl+shift", KeyCombinationHoldOf("left_alt_then_caps_lock"))
		AssertEqual("nav", KeyCombinationHoldOf("tab_then_space"), "a hold may be a layer")
		AssertEqual("none", KeyCombinationHoldOf("escape_then_tab"), "a hold the picker does not offer is refused")
		AssertEqual(2, KeyCombinationHolds.Count)
		AssertEqual("left_alt", _KeyCombinationFirstKeys["caps_lock"][1], "the index lists the first keys of a second key")
		AssertEqual("caps_lock", _KeyCombinationFirstKeys["left_alt"][1])
		AssertEqual("tab", _KeyCombinationFirstKeys["space"][1], "a hold slot alone makes a pair")
		AssertFalse(_KeyCombinationFirstKeys.Has("enter"), "a key no pair ends on has no entry")
		KeyCombinationsReadConfig(Map())
		AssertEqual(0, KeyCombinationTaps.Count, "an empty configuration binds no pair")
		AssertEqual(0, KeyCombinationHolds.Count)
	}
	_KCT_With(Map(), Map(), Body)
}
Test("key combinations: both slots are read per ordered pair, bad values are refused (key-combinations-2026-10-01)",
	_KCT_ReadConfig)





; ========================================
; ========================================
; ======= 4/ The order of the keys =======
; ========================================
; ========================================

_KCT_FirstKeyHeldStartsThePair() {
	Body() {
		global _KeyCombinationTaken
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])),
			"LAlt held, then CapsLock pressed: the pair LAlt then CapsLock")
		AssertEqual("left_alt", _KeyCombinationTaken["caps_lock"], "the criterion records the pair it admits")
		AssertFalse(KeyCombinationOwns("left_alt", _KCT_Keys(["caps_lock"])),
			"CapsLock held, then LAlt pressed: the other order, which holds no slot")
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys([])), "CapsLock alone is CapsLock")
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys(["tab"])), "another key held is not this pair's first key")
		Calls := []
		AssertFalse(KeyCombinationOwns("enter", _KCT_Keys(["left_alt"], Calls)), "a key no pair ends on")
		AssertEqual(0, Calls.Length, "such a key costs no look at the keyboard: it is asked on every press")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map(), Body)
}
Test("key combinations: the key already down is the first key (key-combinations-2026-10-01)",
	_KCT_FirstKeyHeldStartsThePair)

; A key held alone repeats; another key pressed during that hold makes the
; repeats arrive with both down. That is the other order, never this pair.
_KCT_RepeatNeverStartsAPair() {
	Body() {
		global _KeyCombinationTaken
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys([])), "CapsLock pressed alone")
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys(["caps_lock", "left_alt"])),
			"its repeat, LAlt pressed meanwhile: CapsLock was first, the pair LAlt then CapsLock must not fire")
		AssertFalse(_KeyCombinationTaken.Has("caps_lock"))
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])), "a real press under LAlt")
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt", "caps_lock"])),
			"the repeat of a press the pair took stays with the pair")
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["caps_lock"])),
			"even once LAlt is up: the repeat must not reach CapsLock's own tap-hold")
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys([])), "the next press alone is CapsLock again")
		AssertFalse(_KeyCombinationTaken.Has("caps_lock"), "a new press ends the pair of the previous one")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map(), Body)
}
Test("key combinations: a repeat never starts a pair, and follows the pair that took its press (key-combinations-2026-10-01)",
	_KCT_RepeatNeverStartsAPair)

_KCT_SwitchAndWizardStandDown() {
	Off() {
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])),
			"the switch of the combinations off leaves every pair to the keys")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map(), Off, false)
	Wizard() {
		global _OB_ALTGR_PASSTHROUGH
		_OB_ALTGR_PASSTHROUGH := true
		AssertFalse(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])),
			"the first-run wizard leaves every key to the system")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map(), Wizard)
}
Test("key combinations: the switch off and the wizard leave the keys alone (key-combinations-2026-10-01)",
	_KCT_SwitchAndWizardStandDown)

; On a standard AltGr layout every AltGr press begins with a fake LCtrl: LCtrl
; then AltGr cannot be told from AltGr alone there. A Kana-style AltGr has none.
_KCT_FakeLCtrlIsNotAFirstKey() {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	Saved := { Kana: _ALTGR_KANA_FIXUP, Probe: _ALTGR_LAYOUT_PROBE }
	Body() {
		global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
		_ALTGR_KANA_FIXUP := false
		_ALTGR_LAYOUT_PROBE := Map("hkl", 1, "rmenu_sc", 0xE038, "altgr_vk", 0xA5, "valid", true,
			"kana", false, "altgr_level", true, "source", "probe")
		AssertFalse(KeyCombinationOwns("alt_gr", _KCT_Keys(["left_ctrl"])),
			"standard AltGr layout: LCtrl read as held is AltGr's own")
		_ALTGR_KANA_FIXUP := true
		_ALTGR_LAYOUT_PROBE := Map("hkl", 1, "rmenu_sc", 0, "altgr_vk", 0xDF, "valid", true,
			"kana", true, "altgr_level", false, "source", "probe")
		AssertTrue(KeyCombinationOwns("alt_gr", _KCT_Keys(["left_ctrl"])),
			"Kana-style layout: LCtrl held, then AltGr, is the user's pair")
	}
	try _KCT_With(Map("left_ctrl_then_alt_gr", "caps_word"), Map(), Body)
	finally {
		_ALTGR_KANA_FIXUP := Saved.Kana
		_ALTGR_LAYOUT_PROBE := Saved.Probe
	}
}
Test("key combinations: AltGr's fake LCtrl is not a first key (key-combinations-2026-10-01)",
	_KCT_FakeLCtrlIsNotAFirstKey)





; ==============================
; ==============================
; ======= 5/ The handler =======
; ==============================
; ==============================

_KCT_TapSlotRunsAndRepeats() {
	Body() {
		Events := []
		Ports := _KCT_Ports(Events)
		AssertEqual("", KeyCombinationFire("caps_lock", Ports), "no press taken: nothing runs")
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])))
		AssertEqual("tap", KeyCombinationFire("caps_lock", Ports))
		AssertEqual(2, Events.Length)
		AssertEqual("take:left_alt", Events[1], "the first key's press becomes a hold before the action runs")
		AssertEqual("tap:left_alt>caps_lock:caps_word", Events[2])
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt", "caps_lock"])))
		AssertEqual("repeat", KeyCombinationFire("caps_lock", Ports), "a tap without a hold repeats with the key")
		AssertEqual(3, Events.Length, "the repeat runs the tap again and takes the first key only once")
		AssertEqual("tap:left_alt>caps_lock:caps_word", Events[3])
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map(), Body)
}
Test("key combinations: hold 1 + tap 2 runs the tap slot, and repeats it (key-combinations-2026-10-01)",
	_KCT_TapSlotRunsAndRepeats)

_KCT_HoldSlotHoldsItsModifier() {
	Body() {
		Events := []
		Ports := _KCT_Ports(Events)
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])))
		AssertEqual("hold", KeyCombinationFire("caps_lock", Ports))
		AssertEqual("take:left_alt", Events[1])
		AssertEqual("modifier:caps_lock:LCtrl", Events[2], "the hold slot's modifier is held while the second key is down")
		AssertEqual(2, Events.Length)
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt", "caps_lock"])))
		AssertEqual("swallowed", KeyCombinationFire("caps_lock", Ports), "the repeat of a held pair does nothing")
		AssertEqual(2, Events.Length)
	}
	_KCT_With(Map(), Map("left_alt_then_caps_lock", "ctrl"), Body)
	Combination() {
		Events := []
		AssertTrue(KeyCombinationOwns("space", _KCT_Keys(["tab"])))
		AssertEqual("hold", KeyCombinationFire("space", _KCT_Ports(Events)))
		AssertEqual("modifier:space:combination", Events[2], "a hold may be several modifiers")
	}
	_KCT_With(Map(), Map("tab_then_space", "ctrl+shift"), Combination)
	Layer() {
		Events := []
		AssertTrue(KeyCombinationOwns("space", _KCT_Keys(["tab"])))
		AssertEqual("hold", KeyCombinationFire("space", _KCT_Ports(Events)))
		AssertEqual("layer:space", Events[2], "a hold may be the navigation layer")
	}
	_KCT_With(Map(), Map("tab_then_space", "nav"), Layer)
}
Test("key combinations: hold 1 + hold 2 holds the hold slot (key-combinations-2026-10-01)",
	_KCT_HoldSlotHoldsItsModifier)

; Both slots set: the hold is taken at key-down, as every tap-hold of the
; driver takes it, and a release inside the threshold makes the press a tap.
_KCT_BothSlotsSplitOnTheRelease() {
	Tapped() {
		Events := []
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])))
		AssertEqual("tap", KeyCombinationFire("caps_lock", _KCT_Ports(Events, true)))
		AssertEqual("modifier:caps_lock:LShift", Events[2])
		AssertEqual("tap:left_alt>caps_lock:caps_word", Events[3], "a quick release runs the tap slot")
	}
	Held() {
		Events := []
		AssertTrue(KeyCombinationOwns("caps_lock", _KCT_Keys(["left_alt"])))
		AssertEqual("hold", KeyCombinationFire("caps_lock", _KCT_Ports(Events, false)))
		AssertEqual(2, Events.Length, "a long hold runs no tap")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map("left_alt_then_caps_lock", "shift"), Tapped)
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map("left_alt_then_caps_lock", "shift"), Held)
}
Test("key combinations: a pair with both slots is a tap on a quick release, a hold otherwise (key-combinations-2026-10-01)",
	_KCT_BothSlotsSplitOnTheRelease)

; The actions run for real through the catalogue, as the three former
; dispatchers ran them: against the stubs of the suite.
_KCT_ActionsRunThroughTheCatalogue() {
	global _Stub_SentText, _Stub_OneShotShiftFixCalls, TapHold, LayerEnabled, _TH_OwnedModifiers
	SavedTapHold := TapHold
	SavedLayer := IsSet(LayerEnabled) ? LayerEnabled : false
	Kinds := Map("caps_lock", "toggle_capslock", "caps_word", "toggle_capsword", "one_shot_shift", "one_shot_shift")
	try {
		TapHold := Map("keys", Map())
		LayerEnabled := false
		Actions := ["caps_lock", "caps_word", "one_shot_shift"]
		Loop 250 {
			Action := Actions[Mod(A_Index - 1, Actions.Length) + 1]
			_Stub_SentText := []
			_KeyCombinationRunTap("alt_gr", "left_alt", Action)
			AssertEqual(1, _Stub_SentText.Length, "run " . A_Index . " (" . Action . ") runs exactly one action")
			AssertEqual(Kinds[Action], _Stub_SentText[1].kind, "run " . A_Index . " runs the slot's action")
		}
		for _, Action in ["enter", "escape", "tab", "ctrl_delete", "delete", "ctrl_backspace", "backspace"] {
			Assert(GESTURE_ACTIONS.Has(Action), Action . " is a catalogue action")
			_KeyCombinationRunTap("alt_gr", "caps_lock", Action)
		}
		; A first key that armed a one-shot Shift on its press was part of a
		; combination: the Shift is dropped, unless the pair's action is it.
		TapHold := Map("keys", Map("left_alt", Map("tap_action", "one_shot_shift")))
		Before := _Stub_OneShotShiftFixCalls
		_KeyCombinationRunTap("left_alt", "caps_lock", "caps_word")
		AssertEqual(Before + 1, _Stub_OneShotShiftFixCalls, "the first key's one-shot Shift is dropped")
		_KeyCombinationRunTap("left_alt", "caps_lock", "one_shot_shift")
		AssertEqual(Before + 1, _Stub_OneShotShiftFixCalls, "a pair that runs the one-shot Shift keeps it")
		; The navigation layer a first key holds ends before the action, as it
		; did for LAlt then CapsLock.
		LayerEnabled := true
		_KeyCombinationRunTap("left_alt", "caps_lock", "caps_word")
		AssertFalse(LayerEnabled, "the action runs out of the layer the first key held")
		; A modifier the first key holds synthetically does not stop the action.
		_TH_OwnedModifiers["caps_lock"] := ["LCtrl", "LShift"]
		_Stub_SentText := []
		try _KeyCombinationRunTap("caps_lock", "left_alt", "caps_word")
		finally _TH_OwnedModifiers.Delete("caps_lock")
		AssertEqual("toggle_capsword", _Stub_SentText[_Stub_SentText.Length].kind)
	} finally {
		TapHold := SavedTapHold
		LayerEnabled := SavedLayer
		_Stub_SentText := []
	}
}
Test("key combinations: a pair's action runs through the catalogue (key-combinations-2026-10-01)",
	_KCT_ActionsRunThroughTheCatalogue)

; The first key of a pair is held, not tapped: its own tap must not follow on
; its release. The mark is read once, and only by the press it was made for.
_KCT_FirstKeyTapIsCancelled() {
	global _TH_PressesTakenByCombination, TAPHOLD_CANCEL_BY_COMBINATION
	Saved := _TH_PressesTakenByCombination
	try {
		_TH_PressesTakenByCombination := Map()
		TapHoldMarkPressTakenByCombination("left_alt")
		AssertEqual(TAPHOLD_CANCEL_BY_COMBINATION, TapHoldShouldCancelTap("left_alt", 250),
			"the first key's tap is cancelled on its release")
		AssertFalse(_TH_PressesTakenByCombination.Has("left_alt"), "the mark is read once")
		AssertFalse(_TH_TakePressTakenByCombination("left_alt", 250), "the next press of the key is its own")
		TapHoldMarkPressTakenByCombination("left_alt", 1000)
		AssertFalse(_TH_TakePressTakenByCombination("left_alt", 250, 5000),
			"a mark older than the longest tap belongs to a press nobody asked about")
		AssertFalse(_TH_PressesTakenByCombination.Has("left_alt"), "and is dropped")
		TapHoldMarkPressTakenByCombination("left_alt", 1000)
		AssertTrue(_TH_TakePressTakenByCombination("left_alt", 250, 1200), "a mark inside the tap window counts")
		AssertFalse(_TH_TakePressTakenByCombination("caps_lock", 250), "another key was not taken")
	} finally _TH_PressesTakenByCombination := Saved
}
Test("key combinations: the first key's own tap is cancelled, once (key-combinations-2026-10-01)",
	_KCT_FirstKeyTapIsCancelled)





; ====================================
; ====================================
; ======= 6/ Writing the slots =======
; ====================================
; ====================================

_KCT_SlotsAreWrittenToTheConfiguration() {
	Fixture := _ScopeOwnerFixture()
	Reloads := []
	Reload := () => (Reloads.Push("reload"), true)
	Section() {
		Parsed := TOML_ParseFreshFile(Fixture.path)
		return Parsed.Has("shortcuts.key_combination_holds") ? Parsed["shortcuts.key_combination_holds"] : Map()
	}
	try {
		AssertTrue(SetKeyCombinationHold("left_alt_then_caps_lock", "ctrl+shift", Fixture.path, Reload))
		AssertEqual("ctrl+shift", Section().Get("left_alt_then_caps_lock", ""), "the hold slot is written")
		AssertEqual(1, Reloads.Length, "the driver reloads so the pair hotkeys read it")
		AssertTrue(SetKeyCombinationHold("left_alt_then_caps_lock", "none", Fixture.path, Reload))
		AssertFalse(Section().Has("left_alt_then_caps_lock"), "an empty hold slot leaves no key")
		AssertThrows(() => SetKeyCombinationHold("left_alt_then_caps_lock", "hyper", Fixture.path, Reload),
			"a hold the picker does not offer is refused")
		AssertThrows(() => SetKeyCombinationHold("left_alt_then_left_alt", "ctrl", Fixture.path, Reload),
			"a pair of one key twice is refused")
		Assert(FSWriteDurable(Fixture.path, '[shortcuts.key_combination_taps]`nspace_then_enter = "caps_word"`n'
			. 'left_alt_then_caps_lock = "caps_lock"`n[shortcuts.key_combination_holds]`nspace_then_enter = "ctrl"`n'))
		AssertTrue(ClearKeyCombination("space_then_enter", Fixture.path, Reload))
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Taps := Parsed.Has("shortcuts.key_combination_taps") ? Parsed["shortcuts.key_combination_taps"] : Map()
		AssertFalse(Taps.Has("space_then_enter"), "the clear row empties the tap slot")
		AssertEqual("caps_lock", Taps.Get("left_alt_then_caps_lock", ""), "and leaves the other pairs")
		AssertFalse(Section().Has("space_then_enter"), "the clear row empties the hold slot")
		AssertTrue(ClearKeyCombination("left_alt_then_caps_lock", Fixture.path, Reload))
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Taps := Parsed.Has("shortcuts.key_combination_taps") ? Parsed["shortcuts.key_combination_taps"] : Map()
		AssertFalse(Taps.Has("left_alt_then_caps_lock"), "a declared pair goes back to its empty default")
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("key combinations: the slots are written to config.toml and reload the driver (key-combinations-2026-10-01)",
	_KCT_SlotsAreWrittenToTheConfiguration)

_KCT_ScopeRemovesUndeclaredSlots() {
	Body() {
		Rows := KeyCombinationScopeRows()
		Seen := Map()
		for _, Row in Rows {
			AssertTrue(Row.Delete ? true : false, "a scope row removes a slot")
			Seen[Row.Section . "." . Row.Key] := true
		}
		AssertEqual(2, Rows.Length)
		Assert(Seen.Has("shortcuts.key_combination_taps.space_then_enter"), "a pair the manifest does not declare is removed")
		Assert(Seen.Has("shortcuts.key_combination_holds.left_alt_then_caps_lock"), "every hold slot is removed: none is recommended")
		AssertFalse(Seen.Has("shortcuts.key_combination_taps.left_alt_then_caps_lock"),
			"a declared pair is the scope owner's: it sets it from the manifest")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_lock", "space_then_enter", "caps_word"),
		Map("left_alt_then_caps_lock", "ctrl"), Body)
}
Test("key combinations: restoring or clearing Shortcuts removes the undeclared slots (key-combinations-2026-10-01)",
	_KCT_ScopeRemovesUndeclaredSlots)





; ===========================
; ===========================
; ======= 7/ The menu =======
; ===========================
; ===========================

_KCT_MenuListsEveryOrderedPair() {
	Body() {
		Left := KeyCombinationRows("left")
		Right := KeyCombinationRows("right")
		LeftDefs := TapHoldKeyDefsOfHand("left")
		RightDefs := TapHoldKeyDefsOfHand("right")
		All := TapHoldKeyDefs()
		AssertEqual(All.Length, LeftDefs.Length + RightDefs.Length, "every key belongs to a hand")
		AssertEqual(LeftDefs.Length, Left.Length, "one group per left-hand first key")
		AssertEqual(RightDefs.Length, Right.Length, "one group per right-hand first key")
		AssertThrows(() => KeyCombinationRows("both"), "a list is one hand's")
		Groups := Map()
		Pairs := 0
		for _, Side in [[Left, LeftDefs], [Right, RightDefs]] {
			for Index, Group in Side[1] {
				Assert(!Group.Has("separator"), "the provider builds no separator: the manifest declares it")
				AssertEqual(t(Side[2][Index]["i18n"]), Group["label"], "a group is named by its first key, in catalogue order")
				Groups[Side[2][Index]["id"]] := Group
				AssertEqual(All.Length - 1, Group["items"].Length, "a first key pairs with every other key")
				Pairs += Group["items"].Length
				for _, Pair in Group["items"] {
					Assert(!Pair.Has("separator"), "nor between the pairs of a group")
					Assert(InStr(Pair["label"], " : ") > 0, "every pair exposes its action without opening the picker")
					Assert(HasMethod(Pair["action"], "Call"), "a pair's row opens its menu")
					Assert(!Pair.Has("items"), "and carries no submenu of its own: 182 of them at every start")
				}
			}
		}
		AssertEqual(All.Length * (All.Length - 1), Pairs, "every ordered pair is listed")
		Assert(Groups.Has("space") and Left[Left.Length]["label"] == t("tap_hold.group.space"),
			"Space is a left-hand key, the last of its hand")
		Forward := "", Backward := ""
		for _, Pair in Groups["left_alt"]["items"] {
			if InStr(Pair["label"], t("tap_hold.group.left_alt") . " + " . t("tap_hold.group.caps_lock")) == 1
				Forward := Pair
		}
		for _, Pair in Groups["caps_lock"]["items"] {
			if InStr(Pair["label"], t("tap_hold.group.caps_lock") . " + " . t("tap_hold.group.left_alt")) == 1
				Backward := Pair
		}
		Assert(Forward is Map and Backward is Map, "LAlt + CapsLock and CapsLock + LAlt are two rows")
		AssertTrue(Forward["checked"], "a pair with a slot is ticked")
		Assert(InStr(Forward["label"], GestureActionDisplayLabel("caps_word")) > 0, "and names its tap")
		Assert(InStr(Forward["label"], _TH_HoldOptionLabel("ctrl")) > 0, "and its hold")
		AssertFalse(Backward["checked"], "the other order has its own, empty, slots")
		AssertEqual(t("tap_hold.group.caps_lock") . " + " . t("tap_hold.group.left_alt") . " : "
			. t("dialog.action_picker.disabled"), Backward["label"], "an empty pair explicitly names its disabled action")
		AssertTrue(Groups["left_alt"]["checked"], "a first key with a pair is ticked")
		AssertFalse(Groups["caps_lock"]["checked"])
		; The menu a pair opens is the manifest's: its clear row, a separator,
		; then the two slots this provider supplies.
		Slots := KeyCombinationSlotRows("left_alt_then_caps_lock", "LAlt + CapsLock")
		AssertEqual(2, Slots.Length, "a pair has a tap slot and a hold slot")
		Assert(HasMethod(Slots[1]["action"], "Call"), "the tap slot opens the action picker")
		Assert(InStr(Slots[1]["label"], GestureActionDisplayLabel("caps_word")) > 0, "and names its action")
		AssertEqual(TapHoldHoldOptions().Length, Slots[2]["items"].Length, "the hold slot lists the shared hold options")
		Assert(InStr(Slots[2]["label"], _TH_HoldOptionLabel("ctrl")) > 0, "and names its hold")
		Shown := []
		KeyCombinationShowPairMenu("left_alt_then_caps_lock", "LAlt + CapsLock", (Built) => Shown.Push(Built))
		AssertEqual(1, Shown.Length, "the pair's menu is built from the manifest and handed over to be shown")
		try AssertEqual(4, DllCall("GetMenuItemCount", "ptr", Shown[1].Handle, "int"),
			"the clear row, the separator, the tap slot and the hold slot")
		finally Shown[1].Delete()
		Picker := KeyCombinationHoldPickerRows("left_alt_then_caps_lock")
		AssertEqual(TapHoldHoldOptions().Length, Picker.Length, "the hold picker offers the shared hold options")
		Ticked := 0
		for _, Row in Picker
			Ticked += Row["checked"] ? 1 : 0
		AssertEqual(1, Ticked, "exactly the current hold is ticked")
		Empty := KeyCombinationHoldPickerRows("caps_lock_then_left_alt")
		AssertTrue(Empty[1]["checked"], "an empty hold slot ticks « none »")
	}
	_KCT_With(Map("left_alt_then_caps_lock", "caps_word"), Map("left_alt_then_caps_lock", "ctrl"), Body)
	; The two hands and the separator between them are the manifest's, shared
	; with macOS (the maintainer's request of 2026-10-02).
	Def := _MR_GetMenuDef("key_combinations_group")
	LeftAt := 0
	for Position, Row in Def {
		Assert(_MR_Get(Row, "type") != "feature", "no fixed family row remains: the pairs are a list")
		if (_MR_Get(Row, "type") == "list" && _MR_Get(Row, "id") == "key_combination_rows_left")
			LeftAt := Position
	}
	Assert(LeftAt > 0 && LeftAt + 2 <= Def.Length, "the manifest lists the left-hand pairs, then two more rows")
	AssertEqual("---", _MR_Get(Def[LeftAt + 1], "type"), "a separator follows the left hand")
	AssertEqual("key_combination_rows_right", _MR_Get(Def[LeftAt + 2], "id"), "then the right hand")
	for Offset in [0, 1, 2]
		Assert(_MR_IsForAhk(Def[LeftAt + Offset]), "the three rows are drawn on Windows")
	PairMenu := _MR_GetMenuDef("key_combination_pair_menu")
	AssertEqual(3, PairMenu.Length, "a pair's menu is declared: its clear row, a separator, its slots")
	AssertEqual("key_combination_clear", _MR_Get(PairMenu[1], "id"))
	AssertEqual("---", _MR_Get(PairMenu[2], "type"))
	AssertEqual("key_combination_slots", _MR_Get(PairMenu[3], "id"))
}
Test("key combinations: the menu lists every ordered pair by hand, with its two slots (key-combinations-2026-10-01)",
	_KCT_MenuListsEveryOrderedPair)





; ==============================
; ==============================
; ======= 8/ The hotkeys =======
; ==============================
; ==============================

; Every catalogue key has its pair hotkeys, named by the key's own scan code,
; under the one criterion that reads the key from the hotkey's name, and they
; are created before every other hotkey of a tap-hold key: the earliest-created
; eligible variant of a hotkey fires.
_KCT_EveryKeyHasItsPairHotkeys() {
	Path := A_ScriptDir . "\..\platform\remap\key_combination_keys.ahk"
	Src := _StripFullLineComments(FileRead(Path, "UTF-8"))
	Start := InStr(Src, "#HotIf KeyCombinationOwnsHotkey()`n")
	Assert(Start > 0, "the pair hotkeys stand under the criterion that reads the key from the hotkey's name")
	Finish := InStr(Src, "`n#HotIf`n", , Start + 1)
	Assert(Finish > Start, "the criterion must be closed")
	Block := SubStr(Src, Start, Finish - Start)
	Assert(InStr(Block, "KeyCombinationFireHotkey()") > 0, "they run the pair of the key their name spells")
	StrReplace(Block, "::", , , &Labels)
	Typing := Map("escape", true, "tab", true, "space", true, "enter", true, "backspace", true, "delete", true)
	Chords := ["", "^", "!", "^!", "+", "^+", "!+", "^!+", "#", "^#", "!#", "^!#", "+#", "^+#", "!+#", "^!+#"]
	Expected := 0
	Body() {
		for _, KeyId in KeyCombinationKeyIds() {
			Sc := Format("SC{:03X}", _TapHoldScanCodeOf(KeyId))
			Assert(InStr(Block, "`n*" . Sc . "::") > 0, KeyId . " is declared under any modifier, by its scan code " . Sc)
			Assert(InStr(Block, "`n" . Sc . "::") > 0, KeyId . " is declared bare: an exact hotkey beats the wildcard")
			AssertEqual(KeyId, KeyCombinationKeyOfHotkey("*" . Sc), "the criterion reads " . KeyId . " from *" . Sc)
			AssertEqual(KeyId, KeyCombinationKeyOfHotkey("^!+#" . StrLower(Sc)), "whatever the chord and the case")
			Expected += 2
			if !Typing.Has(KeyId)
				continue
			for _, Chord in Chords
				Assert(InStr(Block, "`n" . Chord . Sc . "::") > 0,
					KeyId . " is declared under '" . Chord . "': the first key of a pair often holds a modifier")
			Expected += Chords.Length - 1
		}
		AssertEqual("", KeyCombinationKeyOfHotkey("*SC010"), "a key outside the catalogue is no pair's key")
		AssertEqual("", KeyCombinationKeyOfHotkey("Tab"), "a hotkey named by a key name spells no scan code")
		AssertFalse(KeyCombinationOwnsHotkey("*SC010"))
		AssertFalse(KeyCombinationOwnsHotkey("*SC03A"), "CapsLock alone: no first key is physically down in a test")
		AssertEqual("", KeyCombinationFireHotkey("*SC03A"), "and nothing runs for a press no pair took")
	}
	; The scan codes are read with the slots, as at boot.
	_KCT_With(Map(), Map(), () => (KeyCombinationsReadConfig(Map(
		"shortcuts.key_combination_taps", Map("left_alt_then_caps_lock", "caps_word"))), Body()))
	AssertEqual(Expected, Labels, "no pair hotkey beyond the catalogue's keys")
	Remap := FileRead(A_ScriptDir . "\..\platform\remap.ahk", "UTF-8")
	Mine := InStr(Remap, "#Include remap/key_combination_keys.ahk")
	Assert(Mine > 0, "platform/remap.ahk must include the pair hotkeys")
	Later := 0
	Loop Parse, Remap, "`n", "`r" {
		if !RegExMatch(A_LoopField, "^#Include remap/(\w+)\.ahk$", &Found)
			continue
		Other := Found[1]
		if (Other == "constants" || Other == "tap_hold_roll" || Other == "key_combination_keys")
			continue
		Assert(InStr(Remap, A_LoopField) > Mine, Other . ".ahk declares hotkeys and must come after the pair hotkeys")
		Later += 1
	}
	Assert(Later >= 16, "every key file, the rolled keys and the layer follow the pair hotkeys")
}
Test("key combinations: every key has its pair hotkeys, created first (key-combinations-2026-10-01)",
	_KCT_EveryKeyHasItsPairHotkeys)

_KCT_PairClearAvailability(Assigned) {
	PairId := "left_alt_then_caps_lock"
	Taps := Assigned ? Map(PairId, "caps_word") : Map()
	_KCT_With(Taps, Map(), Inspect)
	Inspect() {
		Shown := []
		KeyCombinationShowPairMenu(PairId, "LAlt + CapsLock", (Built) => Shown.Push(Built))
		AssertEqual(1, Shown.Length)
		try {
			Flags := DllCall("GetMenuState", "ptr", Shown[1].Handle, "uint", 0, "uint", 0x400, "uint")
			Assert(Flags != 0xFFFFFFFF, "the declared clear command must exist")
			AssertEqual(!Assigned, (Flags & 3) != 0, "an empty pair has nothing to clear on either driver")
		} finally Shown[1].Delete()
	}
}
for Assigned in [false, true]
	Test("key combinations: shared clear availability assigned=" . Assigned . " (key-combination-pair-menu)",
		_KCT_PairClearAvailability.Bind(Assigned))

; The actual shared menu commands change only their native combination owner.
; Fresh disk slots deliberately differ from the runtime maps in the fixture.
_KCT_GroupScope(Mode) {
	global _MenuDispatchCallbacks
	Fixture := _ScopeOwnerFixture()
	Source := '[shortcuts.key_combination_taps]`nleft_alt_then_caps_lock = "open_url"`nspace_then_enter = "caps_word"`nfuture_pair = "keep"`n'
		. '[shortcuts.key_combination_holds]`nspace_then_enter = "ctrl"`nfuture_pair = "keep"`n'
		. '[shortcuts.keyboard]`nwin_b = "copy"`n[category_enabled]`nkey_combinations = false`nshortcuts = false`n'
		. '[action_parameters]`ncombination__left_alt_then_caps_lock__open_url = "https://pair.test"`n'
		. 'combination__future_pair__open_url = "keep"`nkeyboard__win_b__open_url = "keep"`n'
	Assert(FSWriteDurable(Fixture.path, Source))
	Bundle := 0, Refusal := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	Rendered := Menu()
	try {
		Commands := _SC_KeyCombinationCommands(Fixture.options)
		Id := Mode == "recommended" ? "scope_restore" : "scope_clear"
		AssertEqual(1, MenuRenderer_AppendCommand(Rendered, "key_combinations_group", Id, Commands),
			"the shared combination submenu declares its own bulk command")
		ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
		Receipt := (_MenuDispatchCallbacks[ItemId])()
		AssertEqual("pending", Receipt["status"])
		AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]), "backup contains the exact previous bytes")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		Taps := Parsed.Get("shortcuts.key_combination_taps", Map())
		Holds := Parsed.Get("shortcuts.key_combination_holds", Map())
		Expected := Map("alt_gr_then_left_alt", "ctrl_backspace", "alt_gr_then_caps_lock", "ctrl_delete",
			"left_alt_then_caps_lock", "caps_word")
		for PairId, Action in Expected {
			AssertEqual(Mode == "recommended" ? Action : "none", Taps.Get(PairId, "none"), PairId)
		}
		Assert(!Taps.Has("space_then_enter"), "a valid pair absent from runtime is still owned")
		Assert(!Holds.Has("space_then_enter"), "the clear and preset remove custom holds")
		AssertEqual("keep", Taps["future_pair"], "an unknown slot remains outside this owner")
		AssertEqual("keep", Holds["future_pair"])
		Assert(!Parsed["action_parameters"].Has("combination__left_alt_then_caps_lock__open_url"))
		AssertEqual("keep", Parsed["action_parameters"]["combination__future_pair__open_url"])
		AssertEqual("keep", Parsed["action_parameters"]["keyboard__win_b__open_url"])
		AssertEqual("copy", Parsed["shortcuts.keyboard"]["win_b"])
		AssertEqual(false, Parsed["category_enabled"]["shortcuts"])
		AssertEqual(Mode == "recommended", Parsed["category_enabled"].Get("key_combinations",
			ManifestDefaultFor("category_enabled.key_combinations")), "clear preserves the disabled switch")
		Refusal.Call("native close refused")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "late refusal restores the complete owner image")
	} finally {
		Rendered.Delete()
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("key combinations: restore the three shared recommendations and recover refusal", _KCT_GroupScope.Bind("recommended"))
Test("key combinations: clear only owned pairs and preserve the group switch", _KCT_GroupScope.Bind("clear"))

#Include ../support/altgr_suffix_cohort.ahk

; The custom suffix is a new press owner, so another key's active layer must
; win before pair admission or fake-Ctrl handback. These are real criteria and
; configured pair maps under explicit layer state, with no OS injection.
_KCT_AltGrSuffixStandsDownOnLayer() {
	global LayerEnabled
	SavedLayer := LayerEnabled
	SavedFamily := _TestSetAltGrFamily(false, true)
	try {
		for _, Hold in ["none", "nav", "ctrl+shift", "alt_gr", "ctrl+alt_gr"]
			_KCT_With(Map("left_alt_then_alt_gr", "caps_word"),
				Hold == "none" ? Map() : Map("left_alt_then_alt_gr", Hold), Inspect.Bind(Hold))
	} finally {
		LayerEnabled := SavedLayer
		_TestRestoreAltGrFamily(SavedFamily)
	}
	Inspect(Hold) {
		global LayerEnabled, _KeyCombinationTaken
		Calls := []
		Effects := []
		LayerEnabled := true
		for _, Pass in [false, true] {
			AssertFalse(KeyCombinationOwnsAltGrSuffix(Pass, _KCT_Keys(["left_alt"], Calls)),
				Hold . ": another key's layer excludes both actual custom suffix owners")
			AssertFalse(_KeyCombinationTaken.Has("alt_gr"), "layer refusal cannot publish a pair claim")
			AssertEqual("", KeyCombinationFireAltGrSuffix(Pass, _KCT_Ports(Effects)),
				"an unclaimed layer suffix cannot retract Ctrl or dispatch an effect")
		}
		AssertEqual(0, Calls.Length, "the layer fence precedes physical-key pair admission")
		AssertEqual(0, Effects.Length, "another holder's layer receives no pair effect")
		LayerEnabled := false
		AssertTrue(KeyCombinationOwnsAltGrSuffix(InStr(Hold, "alt_gr") > 0, _KCT_Keys(["left_alt"], Calls)),
			"the same configured pair resumes its unchanged native/suppressing variant after the layer closes")
		AssertTrue(Calls.Length > 0, "the positive control reaches actual pair admission")
	}
}
Test("key combinations: another layer holder wins before AltGr suffix pair admission (altgr-suffix-layer-boot)",
	_KCT_AltGrSuffixStandsDownOnLayer)

; Deliberately unset actual module globals after installing a valid pair. Each
; independent case restores every owner in finally; no pre-pump seed list or
; source scanner exemption substitutes for executing the callable predicate.
_KCT_AltGrSuffixUnsetState(Missing) {
	global KEY_COMBINATION_PAIR_SEPARATOR, KEY_COMBINATION_NONE, _TH_HoldOptions, LayerEnabled
	Saved := { Separator: KEY_COMBINATION_PAIR_SEPARATOR, None: KEY_COMBINATION_NONE,
		Options: _TH_HoldOptions, Layer: LayerEnabled, Family: _TestSetAltGrFamily(false, true) }
	try _KCT_With(Map("left_alt_then_alt_gr", "caps_word"), Map(), Inspect)
	finally {
		KEY_COMBINATION_PAIR_SEPARATOR := Saved.Separator
		KEY_COMBINATION_NONE := Saved.None
		_TH_HoldOptions := Saved.Options
		LayerEnabled := Saved.Layer
		_TestRestoreAltGrFamily(Saved.Family)
	}
	Inspect() {
		global KEY_COMBINATION_PAIR_SEPARATOR, KEY_COMBINATION_NONE, _TH_HoldOptions, LayerEnabled
		global KeyCombinationHolds, _KeyCombinationTaken
		LayerEnabled := false
		switch Missing {
		case "separator":
			KEY_COMBINATION_PAIR_SEPARATOR := unset
			AssertEqual("", KeyCombinationPairId("left_alt", "alt_gr"), "unassigned pair grammar refuses")
		case "none":
			KEY_COMBINATION_NONE := unset
			AssertEqual("", KeyCombinationHoldOf("left_alt_then_alt_gr"), "an unassigned canonical empty value is never guessed")
		case "holds":
			KeyCombinationHolds := unset
			AssertEqual("", KeyCombinationHoldOf("left_alt_then_alt_gr"), "an unassigned hold owner refuses")
		case "catalogue":
			_TH_HoldOptions := unset
			AssertEqual(0, TapHoldHoldOptions().Length, "a hold catalogue is unavailable before its shared source is read")
		case "taken":
			_KeyCombinationTaken := unset
		case "layer":
			LayerEnabled := unset
		default:
			throw ValueError("Unknown independent boot control", -1, Missing)
		}
		Calls := []
		for _, Pass in [false, true]
			AssertFalse(KeyCombinationOwnsAltGrSuffix(Pass, _KCT_Keys(["left_alt"], Calls)),
				Missing . ": parse-time suffix admission refuses without initialized owners")
		AssertEqual(0, Calls.Length, "missing boot metadata cannot probe or publish a partial pair")
		if IsSet(_KeyCombinationTaken)
			AssertFalse(_KeyCombinationTaken.Has("alt_gr"), "boot refusal leaves no pair claim")
	}
}
for Missing in ["separator", "none", "holds", "catalogue", "taken", "layer"]
	Test("key combinations: unset " . Missing . " refuses parse-time AltGr suffix ownership (altgr-suffix-layer-boot)",
		_KCT_AltGrSuffixUnsetState.Bind(Missing))


_KCT_ObservationClosedFacts() {
	Nonce := "suffix-123456-7319"
	Row := Nonce . "|7319|8291|9472|1|1|8|1|1|0|0|0|-1`n"
	Expected := " [observation records=1,phase=8,scenario=1,owned=1,error=0,source=0,line=0,exit=-1]"
	AssertEqual(Expected, _KCT_ObservationFacts(Row, 7319, Nonce, "candidate", 9472))
	AssertEqual(Expected, _KCT_ObservationFacts(StrReplace(Row, "`n", "`r`n"), 7319, Nonce, "candidate", 9472))
	EndRow := Nonce . "|7319|8291|9472|1|2|14|1|0|0|0|0|124`n"
	AssertEqual(" [observation records=2,phase=14,scenario=1,owned=0,error=0,source=0,line=0,exit=124]",
		_KCT_ObservationFacts(Row . EndRow, 7319, Nonce, "candidate", 9472))
	ErrorRow := Nonce . "|7319|8291|9472|1|1|16|1|1|5|2|143|-1`n"
	AssertEqual(" [observation records=1,phase=16,scenario=1,owned=1,error=5,source=2,line=143,exit=-1]",
		_KCT_ObservationFacts(ErrorRow, 7319, Nonce, "candidate", 9472))
	Invalid := " [observation invalid=1]"
	for _, Args in [[Row, 7320, Nonce, "candidate", 9472], [Row, 7319, "suffix-other", "candidate", 9472],
		[Row, 7319, Nonce, "bypass", 9472], [Row, 7319, Nonce, "candidate", 9473],
		[Row, 0, Nonce, "candidate", 9472], [Row, 7319, Nonce, "unknown", 9472], [Row, 7319, Nonce, "Candidate", 9472],
		[StrReplace(Row, "suffix", "SUFFIX"), 7319, Nonce, "candidate", 9472],
		[Row, 7319, Nonce, "candidate", 1000000000], [{Private: "PRIVATE"}, 7319, Nonce, "candidate", 9472]]
		AssertEqual(Invalid, _KCT_ObservationFacts(Args*), "a mismatched owner cannot publish child facts")
	for _, Text in [SubStr(Row, 1, -1), Row . Row, Row . StrReplace(EndRow, "|2|14|", "|3|14|"),
		Row . StrReplace(EndRow, "|8291|", "|8292|"), Row . "PRIVATE`n", Chr(0xFEFF) . Row,
		StrReplace(Row, "|8|1|1|", "|17|1|1|"), StrReplace(Row, "|8|1|1|", "|8|4|1|"),
		StrReplace(Row, "|8|1|1|", "|8|1|3|"), StrReplace(ErrorRow, "|5|2|143|", "|9|2|143|"),
		StrReplace(ErrorRow, "|5|2|143|", "|5|4|143|"), StrReplace(ErrorRow, "|5|2|143|", "|5|2|65536|"),
		StrReplace(ErrorRow, "|5|2|143|", "|5|0|143|"), StrReplace(ErrorRow, "|5|2|143|", "|5|2|0|"),
		StrReplace(Row, "|-1`n", "|124`n"), StrReplace(EndRow, "|2|14|", "|1|14|"),
		StrReplace(Row, "|8291|", "|4294967296|"), StrReplace(Row, "|0|0|0|-1", "|5|2|143|-1"),
		StrReplace(Row, "|8291|", "|PRIVATE|"), StrReplace(Row, "|8291|", "|" . Chr(0x100) . "|"),
		Row . Chr(0) . "PRIVATE`n", Row . "|`n"] {
		Fact := _KCT_ObservationFacts(Text, 7319, Nonce, "candidate", 9472)
		AssertEqual(Invalid, Fact, "untrusted observation bytes refuse without reproducing their text")
		AssertEqual(0, InStr(Fact, "PRIVATE"), "closed refusal contains no child payload")
	}
	ManyRows := ""
	Loop 129
		ManyRows .= StrReplace(Row, "|1|8|", "|" . A_Index . "|8|")
	AssertEqual(Invalid, _KCT_ObservationFacts(ManyRows, 7319, Nonce, "candidate", 9472))
	Oversize := ""
	Loop 32769
		Oversize .= "x"
	AssertEqual(Invalid, _KCT_ObservationFacts(Oversize, 7319, Nonce, "candidate", 9472))
}
Test("key combinations: optional child observations refuse identity and private payload substitution (altgr-observation-contract)",
	_KCT_ObservationClosedFacts)


_KCT_ObservationActualFile() {
	Root := A_Temp . "\ergopti-kct-observation-" . DllCall("GetCurrentProcessId", "uint")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	AssertTrue(DllCall("CreateDirectoryW", "str", Root, "ptr", 0, "int"), "the observation fixture owns a fresh directory")
	Path := Root . "\owned.txt"
	Lease := _KCT_ObservationOpen(Path)
	Released := false
	try {
		Assert(Lease.Handle != 0, "the native diagnostic file is created and pinned before the child starts")
		AssertEqual(0, _KCT_ObservationOpen(Path).Handle, "a preexisting diagnostic path is never adopted")
		Row := "suffix-123456-7319|7319|8291|9472|1|1|8|1|1|0|0|0|-1`n"
		AppendRefused := false
		try FileAppend(Row, Path, "UTF-8-RAW")
		catch OSError as Err
			AppendRefused := Err.Number == 32
		AssertTrue(AppendRefused, "the original FileAppend sharing ABI refuses while the native parent pin is held")
		AppendStream := FileOpen(Path, "a-d", "UTF-8-RAW")
		try AssertEqual(StrLen(Row), AppendStream.Write(Row), "the shared append writes every independent ASCII observation byte")
		finally AppendStream.Close()
		AssertEqual(" [observation records=1,phase=8,scenario=1,owned=1,error=0,source=0,line=0,exit=-1]",
			_KCT_ObservationRead(Lease, 7319, "suffix-123456-7319", "candidate", 9472))
		RenameRefused := false
		try FileMove(Path, Root . "\substituted.txt")
		catch OSError
			RenameRefused := true
		AssertTrue(RenameRefused, "the exact native file remains pinned without delete sharing")
		NulBytes := Buffer(9, 0)
		Loop 8
			NumPut("UChar", Ord(SubStr("PRIVATE`n", A_Index, 1)), NulBytes, A_Index)
		NativeStream := FileOpen(Path, "a", "UTF-8-RAW")
		try AssertEqual(9, NativeStream.RawWrite(NulBytes), "the native oracle writes an actual embedded NUL byte")
		finally NativeStream.Close()
		AssertEqual(" [observation invalid=1]", _KCT_ObservationRead(Lease, 7319, "suffix-123456-7319", "candidate", 9472),
			"native bytes after NUL cannot disappear during string decoding")
	} finally {
		Released := _KCT_ObservationClose(Lease)
		if Released
			DirDelete(Root, true)
	}
	AssertTrue(Released, "native handle debt must be retired before deleting owned fixture evidence")
}
Test("key combinations: native observation identity remains pinned through a bounded stable read (altgr-observation-file)",
	_KCT_ObservationActualFile)
