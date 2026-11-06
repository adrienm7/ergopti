; infra/key_combinations.ahk

; ==============================================================================
; MODULE: Key Combinations
; DESCRIPTION:
; « Combinaisons de touches »: what a tap-hold key does while another one is
; held. A combination is an ordered pair of keys of the shared tap-hold
; catalogue, the key held first and the key struck under it, so LAlt then
; CapsLock is not CapsLock then LAlt. Each pair has two slots, as on macOS:
; the action its second key runs on a tap, and the modifier or layer it holds.
; This file holds the assignments, the criterion and the handler of the pair
; hotkeys (platform/remap/key_combination_keys.ahk) and the menu rows.
;
; FEATURES & RATIONALE:
; 1. Logic here, hotkeys apart: the unit suite includes this file without
;    hooking the keyboard, as it does for every module whose hotkeys it tests.
; 2. A pair is decided on the press of its second key, from the physical
;    keys: the first key is the one already down. AutoHotkey records a key's
;    physical state after its hotkey criteria have answered, so while those
;    run the second key still reads as up on its press and as down on its own
;    auto-repeat. A repeat therefore never starts a pair: a key held alone,
;    then joined by another, is the other order.
; 3. A press a pair took stays with it until the key comes up: its repeats
;    run the tap again when the pair has no hold, and are swallowed otherwise,
;    so they never reach the key's own tap-hold.
; 4. The first key's tap is cancelled and the action runs without the
;    modifier that key holds, as Karabiner consumes it on macOS.
; 5. The assignments are read from the two config.toml sections rather than
;    from Features, which the master gates rewrite: the menu shows and edits
;    them while the switch of the combinations is off.
; 6. The third slot, a chord of two keys struck together, is section 6.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\_generated\config_keys.ahk
#Include %A_LineFile%\..\ai_action_gate.ahk
#Include %A_LineFile%\..\number.ahk





; ========================================
; ========================================
; ======= 1/ Pairs and assignments =======
; ========================================
; ========================================

; The config.toml sections of the two slots, keyed by pair id.
global KEY_COMBINATION_TAP_SECTION := "shortcuts.key_combination_taps"
global KEY_COMBINATION_HOLD_SECTION := "shortcuts.key_combination_holds"
; What joins the two key ids of a pair id, first key first:
; "left_alt_then_caps_lock". It keeps a pair id inside the slot grammar of a
; binding id, whose own separator is a double underscore.
global KEY_COMBINATION_PAIR_SEPARATOR := "_then_"
; The value of an empty slot, in both sections.
global KEY_COMBINATION_NONE := "none"
; The scope of a pair's binding id, under which an action stores its parameter.
global KEY_COMBINATION_BINDING_SCOPE := "combination"

; Pair id -> action id run when the second key is tapped, and pair id -> hold
; option held while it stays down. An empty slot has no entry.
global KeyCombinationTaps := Map()
global KeyCombinationHolds := Map()
; Second key id -> the first keys it has a slot under, in catalogue order: the
; criterion of a key's hotkeys reads only this.
global _KeyCombinationFirstKeys := Map()
; Second key id -> the first key of the pair that took its current press, and
; second key id -> true once that press was handled (its repeats follow).
global _KeyCombinationTaken := Map()
global _KeyCombinationHandled := Map()
; A retained key press keeps its admitted slot owners and scalar assignments.
global _KeyCombinationPressAssignments := Map()
; Tap-hold key id -> the name of its scan code ("SC03A"), and back: read once
; with the slots, so the criterion of the pair hotkeys only looks a key up.
global _KeyCombinationScanNames := Map()
global _KeyCombinationKeysByScanName := Map()
; The pair menu last shown. A transient Menu held only by a local dies when
; KeyCombinationShowPairMenu returns, and AHK runs the chosen item's callback
; only after Show returns, so the click found no item: pairs could not be
; changed while the ² key could (report of October 15). The next pair menu
; replaces it.
global _KeyCombinationPairMenu := 0

; The id of the pair « First held, then Second ».
; @param First {String} Tap-hold key id of the key held first.
; @param Second {String} Tap-hold key id of the key struck under it.
; @returns {String}
KeyCombinationPairId(First, Second) {
	global KEY_COMBINATION_PAIR_SEPARATOR
	; Parse-time criteria may run before the canonical slot grammar is assigned.
	if !IsSet(KEY_COMBINATION_PAIR_SEPARATOR)
		return ""
	return First . KEY_COMBINATION_PAIR_SEPARATOR . Second
}

; The tap-hold key ids a pair is made of, in catalogue order.
; @returns {Array}
KeyCombinationKeyIds() {
	Ids := []
	for _, KeyDef in TapHoldKeyDefs()
		Ids.Push(KeyDef["id"])
	return Ids
}

; The two keys of a pair id, or false when it names no ordered pair of two
; different catalogue keys.
; @param PairId {String}
; @returns {Map|Boolean} Map("first", ..., "second", ...), or false.
KeyCombinationParsePair(PairId) {
	global KEY_COMBINATION_PAIR_SEPARATOR
	if !(PairId is String)
		return false
	Known := Map()
	for _, Id in KeyCombinationKeyIds()
		Known[Id] := true
	At := InStr(PairId, KEY_COMBINATION_PAIR_SEPARATOR)
	while (At > 0) {
		First := SubStr(PairId, 1, At - 1)
		Second := SubStr(PairId, At + StrLen(KEY_COMBINATION_PAIR_SEPARATOR))
		if (Known.Has(First) && Known.Has(Second) && First != Second)
			return Map("first", First, "second", Second)
		At := InStr(PairId, KEY_COMBINATION_PAIR_SEPARATOR, , At + 1)
	}
	return false
}

; Whether Value is a hold a pair can take: a modifier combination or a layer of
; the shared hold picker.
; @param Value {String}
; @returns {Boolean}
KeyCombinationHoldIsKnown(Value) {
	if !(Value is String) || Value == ""
		return false
	for _, Option in TapHoldHoldOptions() {
		if (Option["kind"] != "none" && Option["id"] == Value)
			return true
	}
	return false
}

; Whether Value names a layer of the hold picker rather than modifiers.
_KeyCombinationHoldIsLayer(Value) {
	for _, Option in TapHoldHoldOptions() {
		if (Option["kind"] == "layer" && Option["id"] == Value)
			return true
	}
	return false
}

; Reads both slots of every pair: the config value when present, the manifest
; default of a declared tap slot otherwise. A pair id that names no pair, an
; action the catalogue does not know and a hold the picker does not offer are
; reported and leave the slot empty, never on another value.
; @param Cache {Map} The parsed config (IniCacheGet's source).
KeyCombinationsReadConfig(Cache) {
	global KeyCombinationTaps, KeyCombinationHolds, _KeyCombinationFirstKeys
	global _KeyCombinationScanNames, _KeyCombinationKeysByScanName
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_HOLD_SECTION, KEY_COMBINATION_NONE
	global GESTURE_ACTIONS
	ScanNames := Map()
	KeysByScanName := Map()
	for _, KeyId in KeyCombinationKeyIds() {
		Name := Format("SC{:03X}", _TapHoldScanCodeOf(KeyId))
		ScanNames[KeyId] := Name
		KeysByScanName[Name] := KeyId
	}
	_KeyCombinationScanNames := ScanNames
	_KeyCombinationKeysByScanName := KeysByScanName
	Taps := _KeyCombinationReadSlots(Cache, KEY_COMBINATION_TAP_SECTION, true)
	Holds := _KeyCombinationReadSlots(Cache, KEY_COMBINATION_HOLD_SECTION, true)
	KeyCombinationTaps := Taps
	KeyCombinationHolds := Holds
	_KeyCombinationFirstKeys := _KeyCombinationIndexFirstKeys(Taps, Holds)
	LoggerInfo("KeyCombinations", "Key combinations read: {1} tap slot(s), {2} hold slot(s).", Taps.Count, Holds.Count)
	KeyCombinationChordsReadConfig(Cache)
}

; The filled slots of one section: the config value when present, the manifest
; default of a declared tap slot otherwise. The boot read reports what it
; drops; a later planner reading the same file passes Warn := false.
; @param Cache {Map} A parsed config (boot cache or decoded snapshot cache).
; @param Section {String} KEY_COMBINATION_TAP_SECTION or KEY_COMBINATION_HOLD_SECTION.
; @param Warn {Boolean} Whether to log the ignored and emptied slots.
; @returns {Map} Pair id -> action or hold id; an empty slot is absent.
_KeyCombinationReadSlots(Cache, Section, Warn) {
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_NONE, GESTURE_ACTIONS
	Target := Map()
	if (Section == KEY_COMBINATION_TAP_SECTION) {
		for _, Entry in ManifestFeaturesForSection(KEY_COMBINATION_TAP_SECTION) {
			if (Entry["default"] != KEY_COMBINATION_NONE)
				Target[Entry["id"]] := Entry["default"]
		}
	}
	if !(Cache is Map) || !Cache.Has(Section)
		return Target
	for PairId, Value in Cache[Section] {
		if !(KeyCombinationParsePair(PairId) is Map) {
			if Warn
				LoggerWarn("KeyCombinations", "[{1}] '{2}' names no pair of tap-hold keys — ignored.", Section, PairId)
			continue
		}
		if (Value == KEY_COMBINATION_NONE) {
			if Target.Has(PairId)
				Target.Delete(PairId)
			continue
		}
		Known := (Section == KEY_COMBINATION_TAP_SECTION)
			? ((Value is String) && GESTURE_ACTIONS.Has(Value))
			: KeyCombinationHoldIsKnown(Value)
		if !Known {
			if Warn
				LoggerWarn("KeyCombinations", "[{1}] '{2}' holds unknown value '{3}' — left empty.", Section, PairId, Value)
			if Target.Has(PairId)
				Target.Delete(PairId)
			continue
		}
		Target[PairId] := Value
	}
	return Target
}

; Second key id -> first key ids with a slot, in catalogue order.
_KeyCombinationIndexFirstKeys(Taps, Holds) {
	Index := Map()
	Ids := KeyCombinationKeyIds()
	for _, Second in Ids {
		Firsts := []
		for _, First in Ids {
			if (First == Second)
				continue
			PairId := KeyCombinationPairId(First, Second)
			if (Taps.Has(PairId) || Holds.Has(PairId))
				Firsts.Push(First)
		}
		if (Firsts.Length > 0)
			Index[Second] := Firsts
	}
	return Index
}

; The action a pair runs on a tap of its second key, or "none".
KeyCombinationTapOf(PairId) {
	global KeyCombinationTaps, KEY_COMBINATION_NONE
	; Parse-time criteria can reach this accessor before its slot owners exist.
	if !IsSet(KeyCombinationTaps) || !IsSet(KEY_COMBINATION_NONE)
		return ""
	return KeyCombinationTaps.Get(PairId, KEY_COMBINATION_NONE)
}

; The hold a pair takes while its second key stays down, or "none".
KeyCombinationHoldOf(PairId) {
	global KeyCombinationHolds, KEY_COMBINATION_NONE
	; Missing boot metadata is refusal, never a guessed canonical hold value.
	if !IsSet(KeyCombinationHolds) || !IsSet(KEY_COMBINATION_NONE)
		return ""
	return KeyCombinationHolds.Get(PairId, KEY_COMBINATION_NONE)
}

; The binding a pair's action runs under and stores its parameter under.
KeyCombinationBindingId(PairId) {
	global KEY_COMBINATION_BINDING_SCOPE
	return GestureBindingId(KEY_COMBINATION_BINDING_SCOPE, PairId)
}





; ==========================================
; ==========================================
; ======= 2/ Criterion and handler =========
; ==========================================
; ==========================================

; Whether the switch of the combinations lets them fire: the KeyCombinations
; gate on and the first-run wizard closed, which leaves every key to the
; system's layout while it is up.
KeyCombinationsAreOn() {
	global CategoryEnabled, _OB_ALTGR_PASSTHROUGH
	if (IsSet(_OB_ALTGR_PASSTHROUGH) && _OB_ALTGR_PASSTHROUGH)
		return false
	; Read by parse-time #HotIf criteria, live before the gates are loaded: the
	; gate is read here, behind its own guard, rather than through
	; IsCategoryGated. A gate the configuration does not name is on.
	if !IsSet(CategoryEnabled) || !(CategoryEnabled is Map)
		return false
	return CategoryEnabled.Get("KeyCombinations", true) ? true : false
}

; Whether the tap-hold key KeyId is physically down. LCtrl excludes the fake
; one a standard AltGr layout adds to every AltGr press: that is AltGr's key.
; @param KeyId {String} Canonical tap-hold key id.
; @returns {Boolean}
_KeyCombinationKeyIsDown(KeyId) {
	global _KeyCombinationScanNames
	if (KeyId == "left_ctrl")
		return TapHoldUserLCtrlHeld() ? true : false
	if !IsSet(_KeyCombinationScanNames) || !_KeyCombinationScanNames.Has(KeyId)
		return false
	return KS_IsDown(_KeyCombinationScanNames[KeyId]) ? true : false
}

; The tap-hold key a pair hotkey is bound to, from the hotkey's own name: its
; scan code, the one the key's tap-hold hotkeys are bound to. "" for a name
; that ends on no scan code of the catalogue.
; @param HotkeyName {String} A hotkey name such as "*SC03A" or "^+SC039".
; @returns {String}
KeyCombinationKeyOfHotkey(HotkeyName) {
	global _KeyCombinationKeysByScanName
	if !IsSet(_KeyCombinationKeysByScanName) || !(HotkeyName is String)
		return ""
	if !RegExMatch(HotkeyName, "i)(SC[0-9A-F]{3})$", &Found)
		return ""
	return _KeyCombinationKeysByScanName.Get(StrUpper(Found[1]), "")
}

; The #HotIf of the pair hotkeys, one criterion for every key: AutoHotkey sets
; A_ThisHotkey to the hotkey whose criterion it is evaluating.
; @param HotkeyName {String} The hotkey being evaluated; A_ThisHotkey by default.
; @returns {Boolean}
KeyCombinationOwnsHotkey(HotkeyName := unset) {
	Second := KeyCombinationKeyOfHotkey(IsSet(HotkeyName) ? HotkeyName : A_ThisHotkey)
	return Second != "" && (KeyCombinationChordOwns(Second) || KeyCombinationOwns(Second))
}

; The handler of the pair hotkeys: runs the pair of the key the hotkey names.
; @param HotkeyName {String} The hotkey that fired; A_ThisHotkey by default.
; @returns {String} As KeyCombinationFire.
KeyCombinationFireHotkey(HotkeyName := unset) {
	Second := KeyCombinationKeyOfHotkey(IsSet(HotkeyName) ? HotkeyName : A_ThisHotkey)
	if (Second == "")
		return ""
	Chord := KeyCombinationChordHandle(Second)
	return Chord != "" ? Chord : KeyCombinationFire(Second)
}

; The press number the native ledger holds for a tap-hold key, 0 when unknown.
; @param KeyId {String} Canonical tap-hold key id.
; @returns {Integer}
_KeyCombinationKeyPressSequence(KeyId) {
	global _KeyCombinationScanNames
	if !IsSet(_KeyCombinationScanNames) || !_KeyCombinationScanNames.Has(KeyId)
		return 0
	return KS_PressSequence(_KeyCombinationScanNames[KeyId])
}

; The first key of the pair a press of Second completes: among the keys down
; that Second has a slot under, the one pressed first. Held alone then joined by
; another, it stays the first whatever the catalogue order. AutoHotkey keeps no
; order of presses: with a key the native ledger did not number (no owner
; running, or a press behind AutoHotkey's hook), the catalogue order decides.
; @param Second {String} Tap-hold key id of the key being pressed.
; @param IsDownFn {Func} Test seam taking a key id, the held keys by default: a first
;        key replayed after a terminal expansion is held only in the ledger.
; @param PressSequenceFn {Func} Test seam taking a key id, the ledger by default.
; @returns {String}
KeyCombinationHeldFirstKey(Second, IsDownFn := 0, PressSequenceFn := 0) {
	global _KeyCombinationFirstKeys
	if !IsSet(_KeyCombinationFirstKeys) || !_KeyCombinationFirstKeys.Has(Second)
		return ""
	if !IsObject(IsDownFn)
		IsDownFn := _KeyCombinationKeyIsHeld
	if !IsObject(PressSequenceFn)
		PressSequenceFn := _KeyCombinationKeyPressSequence
	Held := []
	for _, First in _KeyCombinationFirstKeys[Second] {
		; On a standard AltGr layout every AltGr press begins with a fake LCtrl,
		; which reads as LCtrl held first: that pair cannot be told from AltGr.
		if (First == "left_ctrl" && Second == "alt_gr" && KS_AltGrAddsFakeLCtrl())
			continue
		if IsDownFn.Call(First)
			Held.Push(First)
	}
	if !Held.Length
		return ""
	Earliest := Held[1]
	if Held.Length == 1
		return Earliest
	EarliestSequence := PressSequenceFn.Call(Earliest)
	for _, First in Held {
		Sequence := PressSequenceFn.Call(First)
		if !Sequence || !EarliestSequence
			return Held[1]
		if Sequence < EarliestSequence {
			Earliest := First
			EarliestSequence := Sequence
		}
	}
	return Earliest
}

; The #HotIf of the pair hotkeys of key Second. On a press, whether a first key
; is held with a slot for Second; on Second's own auto-repeat, whether a pair
; took the press that repeats (see the module header, points 2 and 3). It
; records the pair it admits, so the handler runs the pair the criterion saw.
; @param Second {String} Tap-hold key id of the hotkey's key.
; @param IsDownFn {Func} Test seam taking a key id, the physical keys by default.
; @returns {Boolean}
KeyCombinationOwns(Second, IsDownFn := 0) {
	global _KeyCombinationFirstKeys, _KeyCombinationTaken, _KeyCombinationHandled
	global _KeyCombinationPressAssignments, KeyCombinationTaps, KeyCombinationHolds
	; A key no pair ends on costs one lookup, on every press of that key.
	if !IsSet(_KeyCombinationFirstKeys) || !_KeyCombinationFirstKeys.Has(Second)
		return false
	if !IsSet(_KeyCombinationTaken) || !IsSet(_KeyCombinationHandled)
		|| !IsSet(_KeyCombinationPressAssignments) || !IsSet(KeyCombinationTaps)
		|| !IsSet(KeyCombinationHolds)
		return false
	FirstKeyFn := IsDownFn
	if !IsObject(IsDownFn)
		IsDownFn := _KeyCombinationKeyIsDown
	if IsDownFn.Call(Second)
		return _KeyCombinationTaken.Has(Second)
	; A new press: the previous one, and the pair that took it, are over.
	if _KeyCombinationTaken.Has(Second)
		_KeyCombinationTaken.Delete(Second)
	if _KeyCombinationHandled.Has(Second)
		_KeyCombinationHandled.Delete(Second)
	if _KeyCombinationPressAssignments.Has(Second)
		_KeyCombinationPressAssignments.Delete(Second)
	if !KeyCombinationsAreOn()
		return false
	First := KeyCombinationHeldFirstKey(Second, FirstKeyFn)
	if (First == "")
		return false
	PairId := KeyCombinationPairId(First, Second)
	; A pair whose only slot is an AI action is unarmed while the AI is off: the
	; key stays its own, and the switch-on needs no reload.
	if (KeyCombinationHoldOf(PairId) == KEY_COMBINATION_NONE && AiActionBlocked(KeyCombinationTapOf(PairId)))
		return false
	_KeyCombinationTaken[Second] := First
	_KeyCombinationPressAssignments[Second] := { Taken: _KeyCombinationTaken, First: First,
		Taps: KeyCombinationTaps, Holds: KeyCombinationHolds,
		Tap: KeyCombinationTapOf(PairId), Hold: KeyCombinationHoldOf(PairId), Revoked: false }
	return true
}

; Publication may replace a pair's slot while its original press remains held.
; Keep that press suppressed, but never run the replacement assignment. An
; observed withdrawal remains revoked until the next real key-down admission.
_KeyCombinationPressAssignmentCurrent(Second) {
	global _KeyCombinationPressAssignments, _KeyCombinationTaken
	global KeyCombinationTaps, KeyCombinationHolds
	if !IsSet(_KeyCombinationPressAssignments) || !_KeyCombinationPressAssignments.Has(Second)
		return false
	Record := _KeyCombinationPressAssignments[Second]
	if Record.Revoked
		return false
	PairId := KeyCombinationPairId(Record.First, Second)
	Current := Record.Taken == _KeyCombinationTaken && _KeyCombinationTaken.Has(Second)
		&& _KeyCombinationTaken[Second] == Record.First
		&& Record.Taps == KeyCombinationTaps && Record.Holds == KeyCombinationHolds
		&& Record.Tap == KeyCombinationTapOf(PairId) && Record.Hold == KeyCombinationHoldOf(PairId)
	if !Current
		Record.Revoked := true
	return Current
}

; The production effects of the handler, replaced by recorders in the unit
; suite: "own_modifier" and "own_layer" hold until the second key is up and
; return the owner's result, "run_tap" runs the pair's action.
_KeyCombinationPorts() {
	static Ports := Map(
		"own_modifier", (Second, ModKey, Seconds) => TapHoldOwnImmediateModifier(
			Second, _KeyCombinationScanNames[Second], ModKey, Seconds),
		"own_layer", (Second, Seconds) => TapHoldOwnImmediateLayer(
			Second, _KeyCombinationScanNames[Second], Seconds),
		"run_tap", _KeyCombinationRunTap,
		"take_first", _KeyCombinationTakeFirstKey)
	return Ports
}

; Runs the pair that took a press of Second, or its repeat.
; @param Second {String} Tap-hold key id of the hotkey's key.
; @param Ports {Map} Test seams, _KeyCombinationPorts by default.
; @returns {String} What ran: "tap", "hold", "repeat", "swallowed" or "".
KeyCombinationFire(Second, Ports := 0) {
	global _KeyCombinationTaken, _KeyCombinationHandled, KEY_COMBINATION_NONE, TapHold
	if !(Ports is Map)
		Ports := _KeyCombinationPorts()
	if !_KeyCombinationTaken.Has(Second)
		return ""
	; Keep the acquired press suppressed; a disabled category grants no new effect.
	if !KeyCombinationsAreOn() || !_KeyCombinationPressAssignmentCurrent(Second)
		return "swallowed"
	First := _KeyCombinationTaken[Second]
	PairId := KeyCombinationPairId(First, Second)
	Tap := KeyCombinationTapOf(PairId)
	; A hold is a modifier or a layer, never an action: only the tap is gated.
	if AiActionBlocked(Tap)
		Tap := KEY_COMBINATION_NONE
	Hold := KeyCombinationHoldOf(PairId)
	if _KeyCombinationHandled.Has(Second) {
		; The press's own auto-repeat: a pair without a hold types its tap
		; again, as the key held down would.
		if (Hold != KEY_COMBINATION_NONE || Tap == KEY_COMBINATION_NONE)
			return "swallowed"
		Ports["run_tap"].Call(First, Second, Tap)
		return "repeat"
	}
	_KeyCombinationHandled[Second] := true
	Ports["take_first"].Call(First, Second)
	LoggerDebug("KeyCombinations", "Pair '{1}' fired (tap='{2}', hold='{3}').", PairId, Tap, Hold)
	; First-key ownership and logging may yield to a category publication.
	if !KeyCombinationsAreOn() || !_KeyCombinationPressAssignmentCurrent(Second)
		return "swallowed"
	if (Hold == KEY_COMBINATION_NONE) {
		if (Tap == KEY_COMBINATION_NONE)
			return ""
		Ports["run_tap"].Call(First, Second, Tap)
		return "tap"
	}
	Seconds := TapHoldDuration(TapHold, Second)
	if _KeyCombinationHoldIsLayer(Hold) {
		; Duration lookup may log before this original native acquisition.
		if !KeyCombinationsAreOn() || !_KeyCombinationPressAssignmentCurrent(Second)
			return "swallowed"
		Result := Ports["own_layer"].Call(Second, Seconds)
	} else {
		ModKey := ResolveHoldModifierKey(Hold, Second)
		if (ModKey == "") {
			LoggerError("KeyCombinations", "Pair '{1}' names a hold that resolves to no key: '{2}'.", PairId, Hold)
			return ""
		}
		; The real modifier resolver logs before returning its native key(s).
		if !KeyCombinationsAreOn() || !_KeyCombinationPressAssignmentCurrent(Second)
			return "swallowed"
		Result := Ports["own_modifier"].Call(Second, ModKey, Seconds)
	}
	; The hold is taken at key-down, as every tap-hold of this driver takes
	; it; a release inside the second key's threshold makes the press a tap.
	if (Result["tap"] && Tap != KEY_COMBINATION_NONE) {
		; The original owner has already retired; deny only a newly emitted tap.
		if !KeyCombinationsAreOn() || !_KeyCombinationPressAssignmentCurrent(Second)
			return "swallowed"
		Ports["run_tap"].Call(First, Second, Tap)
		return "tap"
	}
	return "hold"
}

; Makes the first key's press a hold: its own tap must not follow on its
; release, and a typing key still undecided between tap and hold is a hold.
; @param First {String} Tap-hold key id of the key held first.
; @param Second {String} Tap-hold key id of the key struck under it, whose own
;        tap the pair may still run.
_KeyCombinationTakeFirstKey(First, Second) {
	global TAPHOLD_CANCEL_BY_OTHER_KEY
	TapHoldMarkPressTakenByCombination(First)
	TapHoldTrackActivityCancel(Second, TAPHOLD_CANCEL_BY_OTHER_KEY)
	_TapHoldRollResolve("hold", First)
}

; Runs a pair's action as the key combination alone: without the modifier the
; first key holds synthetically, which AutoHotkey keeps down around a Send, and
; out of the navigation layer that key may hold. A one-shot Shift the first or
; the second key armed on its press is dropped: the key was part of a
; combination, not a Shift for the next character.
; @param First {String} Tap-hold key id of the key held first.
; @param Second {String} Tap-hold key id of the key struck under it.
; @param ActionId {String} A catalogue action id.
_KeyCombinationRunTap(First, Second, ActionId) {
	global TapHold, LayerEnabled, _TH_OwnedModifiers
	if (ActionId != "one_shot_shift"
			&& (TapHoldTapAction(TapHold, First) == "one_shot_shift"
				|| TapHoldTapAction(TapHold, Second) == "one_shot_shift"))
		OneShotShiftFix()
	if (IsSet(LayerEnabled) && LayerEnabled)
		DisableLayer()
	RunAction := GestureInvokeAction.Bind(ActionId, KeyCombinationBindingId(KeyCombinationPairId(First, Second)))
	Held := _TH_OwnedModifiers.Has(First) ? _TH_SyntheticKeyList(_TH_OwnedModifiers[First]) : []
	return _KeyCombinationRunWithKeysUp(Held, 1, RunAction)
}

; Runs RunFn with every key of Names lifted, each given back afterwards to
; the owner that still holds it.
_KeyCombinationRunWithKeysUp(Names, Index, RunFn) {
	if (Index > Names.Length)
		return RunFn.Call()
	return TapHoldSendWithOwnedKeyUp(Names[Index],
		_KeyCombinationRunWithKeysUp.Bind(Names, Index + 1, RunFn))
}





; =================================
; =================================
; ======= 3/ Assignment ===========
; =================================
; =================================

; Assigns an action to a pair's tap slot, asking for its parameter first when
; it takes one, and persists both in one config batch, then reloads, as every
; other keyboard binding does.
; @param PairId {String} A pair id.
; @param ActionName {String} A catalogue action id, or "none".
; @returns {Boolean} False when nothing was committed.
SetKeyCombinationTap(PairId, ActionName) {
	global KeyCombinationTaps, KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_BINDING_SCOPE
	if !(KeyCombinationParsePair(PairId) is Map)
		throw ValueError("Unknown key combination.", -1, PairId)
	if !GestureAssignConfiguredAction(&KeyCombinationTaps, KEY_COMBINATION_BINDING_SCOPE,
			KEY_COMBINATION_TAP_SECTION, PairId, ActionName)
		return false
	LoggerInfo("KeyCombinations", "Pair '{1}' tap → '{2}'.", PairId, ActionName)
	return ReloadPreservingSuspend()
}

; Assigns a hold to a pair's hold slot and persists it, then reloads.
; @param PairId {String} A pair id.
; @param HoldId {String} A hold option id, or "none".
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Boolean} False when nothing was committed.
SetKeyCombinationHold(PairId, HoldId, Path := "", ReloadFn := 0) {
	global KEY_COMBINATION_HOLD_SECTION, KEY_COMBINATION_NONE, ConfigurationFile
	if !(KeyCombinationParsePair(PairId) is Map)
		throw ValueError("Unknown key combination.", -1, PairId)
	if (HoldId != KEY_COMBINATION_NONE && !KeyCombinationHoldIsKnown(HoldId))
		throw ValueError("Unknown key combination hold.", -1, HoldId)
	Update := (HoldId == KEY_COMBINATION_NONE)
		? { Section: KEY_COMBINATION_HOLD_SECTION, Key: PairId, Delete: 1 }
		: { Section: KEY_COMBINATION_HOLD_SECTION, Key: PairId, Value: HoldId }
	if !ConfigCommitUpdates(Path != "" ? Path : ConfigurationFile, [Update],
			"the hold of key combination '" . PairId . "'")
		return false
	LoggerInfo("KeyCombinations", "Pair '{1}' hold → '{2}'.", PairId, HoldId)
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}

; Empties both slots of a pair in one config batch, then reloads.
; @param PairId {String} A pair id.
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Boolean} False when nothing was committed.
ClearKeyCombination(PairId, Path := "", ReloadFn := 0) {
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_HOLD_SECTION, ConfigurationFile
	if !(KeyCombinationParsePair(PairId) is Map)
		throw ValueError("Unknown key combination.", -1, PairId)
	Updates := [KeyCombinationTapClearRow(PairId),
		{ Section: KEY_COMBINATION_HOLD_SECTION, Key: PairId, Delete: 1 },
		{ Section: "mod_combos.config." . KeyCombinationChordOwnerPair(PairId), Key: "combo", Delete: 1 }]
	if !ConfigCommitUpdates(Path != "" ? Path : ConfigurationFile, Updates,
			"key combination '" . PairId . "'")
		return false
	LoggerInfo("KeyCombinations", "Pair '{1}' cleared.", PairId)
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}

; The config row that empties a pair's tap slot: a declared slot goes back to
; its manifest default, which is "none"; any other is removed from the file.
; @param PairId {String} A pair id.
; @returns {Object} A config update row.
KeyCombinationTapClearRow(PairId) {
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_NONE
	if (ManifestFindEntryByPath(KEY_COMBINATION_TAP_SECTION . "." . PairId) is Map)
		return ManifestSparseOperation(KEY_COMBINATION_TAP_SECTION . "." . PairId, KEY_COMBINATION_NONE)
	return { Section: KEY_COMBINATION_TAP_SECTION, Key: PairId, Delete: 1 }
}

; The rows that remove every pair slot the manifest does not declare, for the
; Shortcuts scope: restoring the preset or clearing it leaves only the
; declared pairs, which the scope owner sets itself.
; @returns {Array} Config update rows.
KeyCombinationScopeRows() {
	global KeyCombinationTaps, KeyCombinationHolds
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_HOLD_SECTION
	Rows := []
	for PairId in KeyCombinationTaps {
		if !(ManifestFindEntryByPath(KEY_COMBINATION_TAP_SECTION . "." . PairId) is Map)
			Rows.Push({ Section: KEY_COMBINATION_TAP_SECTION, Key: PairId, Delete: true })
	}
	for PairId in KeyCombinationHolds
		Rows.Push({ Section: KEY_COMBINATION_HOLD_SECTION, Key: PairId, Delete: true })
	return Rows
}


; Applies the combination-only scope using fresh disk inventory inside the
; admitted lifecycle. Unrecognized slots and other shortcut owners stay intact.
; @param Mode {String} "recommended" or "clear".
; @param Options {Map} Configuration lifecycle ports for tests.
; @returns {Map} The asynchronous scope receipt.
KeyCombinationsApplyScope(Mode, Options := unset) {
	global ConfigurationFile
	OwnedOptions := IsSet(Options) ? Options : Map()
	Path := OwnedOptions.Has("path") ? OwnedOptions["path"] : ConfigurationFile
	return ConfigScopeCommitOperations("key_combinations", Mode,
		KeyCombinationScopedOperations.Bind(Mode, Path), OwnedOptions)
}

; The pair catalogue owns slot identities; the shared manifest owns presets.
; Read after admission so edits made since boot participate in this scope.
KeyCombinationScopedOperations(Mode, Path) {
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_HOLD_SECTION
	; Keep the admitted document's namespace identity: dotted assignments,
	; inline tables and quoted headers can all describe these same slots.
	Content := FileExist(Path) ? FSReadStrict(Path) : ""
	Stored := ConfigTomlDecodeSnapshot(Content).Document
	ParameterTable := _TOML_DocumentLookup(Stored, ["action_parameters"])
	Parameters := []
	for Key in (ParameterTable.Get("value", 0) is Map ? ParameterTable["value"] : Map()) {
		ParameterPath := "action_parameters." . Key
		if ConfigScopeActionParameterDomain(ParameterPath) == "combination"
			&& (KeyCombinationParsePair(StrSplit(Key, "__")[2]) is Map)
			Parameters.Push(ParameterPath)
	}
	Plan := ManifestScopePlan("key_combinations", Mode, Parameters,
		Map("action_parameter_domain", ConfigScopeActionParameterDomain))
	for Section in [KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_HOLD_SECTION] {
		Table := _TOML_DocumentLookup(Stored, TOML_ParseKeyPath(Section, true))
		for PairId in (Table.Get("value", 0) is Map ? Table["value"] : Map()) {
			if !(KeyCombinationParsePair(PairId) is Map)
				continue
			SlotPath := Section . "." . PairId
			if !(ManifestFindEntryByPath(SlotPath) is Map)
				Plan.operations.Push(ManifestConfigRow(SlotPath, , true))
		}
	}
	; The chord slots are never declared: restoring the preset or clearing empties them.
	Table := _TOML_DocumentLookup(Stored, [ConfigLeaf.MOD_COMBOS, "config"])
	for PairId in (Table.Get("value", 0) is Map ? Table["value"] : Map()) {
		if (KeyCombinationParsePair(PairId) is Map)
			Plan.operations.Push({ Section: "mod_combos.config." . PairId, Key: "combo", Delete: 1 })
	}
	return Plan.operations
}





; ===============================
; ===============================
; ======= 4/ Menu rows ==========
; ===============================
; ===============================

; The label of a pair's tap slot: its action, or the picker's « disabled ».
_KeyCombinationTapLabel(PairId) {
	global GESTURE_ACTIONS, KEY_COMBINATION_NONE
	Action := KeyCombinationTapOf(PairId)
	if (Action == KEY_COMBINATION_NONE || !GESTURE_ACTIONS.Has(Action))
		return t("dialog.action_picker.disabled")
	return GestureActionDisplayLabel(Action, KeyCombinationBindingId(PairId))
}

; The label of a pair's hold slot, as the Tap-Hold submenu names a hold.
_KeyCombinationHoldLabel(PairId) {
	global KEY_COMBINATION_NONE
	Hold := KeyCombinationHoldOf(PairId)
	if (Hold == KEY_COMBINATION_NONE)
		return t("tap_hold.hold.none")
	for _, Option in TapHoldHoldOptions() {
		if (Option["id"] == Hold && Option["i18n"] != "")
			return t(Option["i18n"])
	}
	return _TH_HoldOptionLabel(Hold)
}

; The list provider of the manifest's "key_combination_rows_left" and
; "key_combination_rows_right" entries: one group per first key of that hand,
; as the shared catalogue assigns it (Space is a left-hand key), holding one
; row per second key, « First + Second : action », ticked when assigned.
; Empty pairs name their disabled action. The manifest declares the two lists
; and their separator: the provider builds only the pairs themselves.
; A click on a pair opens its own menu (KeyCombinationShowPairMenu).
; @param Hand {String} "left" or "right": the hand of the key held first.
; @returns {Array} Rows of Map("label", ..., "checked", ..., "items", ...).
KeyCombinationRows(Hand) {
	if (Hand != "left" && Hand != "right")
		throw ValueError("A key combination list is one hand's.", -1, Hand)
	Rows := []
	for _, First in TapHoldKeyDefsOfHand(Hand) {
		Items := []
		AnySet := false
		for _, Second in TapHoldKeyDefs() {
			if (Second["id"] == First["id"])
				continue
			Pair := _KeyCombinationPairRow(First, Second)
			AnySet := AnySet || Pair["checked"]
			Items.Push(Pair)
		}
		Rows.Push(Map("label", t(First["i18n"]), "checked", AnySet, "items", Items))
	}
	return Rows
}

; Every pair names its current action before the user opens its picker.
_KeyCombinationPairRow(First, Second) {
	global KEY_COMBINATION_NONE
	PairId := KeyCombinationPairId(First["id"], Second["id"])
	PairLabel := t(First["i18n"]) . " + " . t(Second["i18n"])
	IsAssigned := KeyCombinationTapOf(PairId) != KEY_COMBINATION_NONE
		|| KeyCombinationHoldOf(PairId) != KEY_COMBINATION_NONE
		|| KeyCombinationChordOf(PairId) != KEY_COMBINATION_NONE
	ActionLabel := _KeyCombinationTapLabel(PairId)
	if KeyCombinationHoldOf(PairId) != KEY_COMBINATION_NONE
		ActionLabel := KeyCombinationTapOf(PairId) == KEY_COMBINATION_NONE
			? _KeyCombinationHoldLabel(PairId) : ActionLabel . " / " . _KeyCombinationHoldLabel(PairId)
	Label := LabelValue(PairLabel, ActionLabel)
	return Map("label", Label, "checked", IsAssigned, "action", _KeyCombinationPairMenuOpener(PairId, PairLabel))
}

_KeyCombinationPairMenuOpener(PairId, PairLabel) {
	return (*) => KeyCombinationShowPairMenu(PairId, PairLabel)
}

; Shows the menu of one pair at the pointer, as the manifest declares it
; (key_combination_pair_menu): its clear row, then its two slots.
; @param PairId {String} A pair id.
; @param PairLabel {String} « First + Second », the title of its action picker.
; @param ShowFn {Func} Test seam taking the built menu; shown by default.
KeyCombinationShowPairMenu(PairId, PairLabel, ShowFn := 0) {
	Commands := Map(MenuCommand.KEY_COMBINATION_CLEAR, (*) => ClearKeyCombination(PairId))
	ListProviders := Map("key_combination_slots", () => KeyCombinationSlotRows(PairId, PairLabel))
	global KEY_COMBINATION_NONE
	Getters := Map("key_combination_pair_assigned", () => KeyCombinationTapOf(PairId) != KEY_COMBINATION_NONE
		or KeyCombinationHoldOf(PairId) != KEY_COMBINATION_NONE
		or KeyCombinationChordOf(PairId) != KEY_COMBINATION_NONE)
	PairMenu := MenuRenderer_Build("key_combination_pair_menu", "Shortcuts", "", "", ListProviders, Commands, Getters)
	global _KeyCombinationPairMenu
	_KeyCombinationPairMenu := PairMenu
	if HasMethod(ShowFn, "Call")
		return ShowFn.Call(PairMenu)
	PairMenu.Show()
}

; The list provider of the manifest's "key_combination_slots" entry: the tap
; slot and the hold slot, which both open the shared action picker, the hold
; on the shared hold options (the maintainer's decision of 2026-10-22).
; @param PairId {String} A pair id.
; @param PairLabel {String} « First + Second », the title of the action picker.
; @returns {Array} Two rows.
KeyCombinationSlotRows(PairId, PairLabel) {
	TapRow := Map("action", (*) => ShowActionPicker(PairLabel, KeyCombinationTapOf(PairId),
		(ActionName) => SetKeyCombinationTap(PairId, ActionName), false, KeyCombinationBindingId(PairId)))
	TapRow["label"] := StrReplace(t("menu.shortcuts.key_combinations_hold_tap"), "%s", _KeyCombinationTapLabel(PairId))
	HoldRow := Map("action", (*) => KeyCombinationShowHoldPicker(PairId, PairLabel))
	HoldRow["label"] := StrReplace(t("menu.shortcuts.key_combinations_hold_hold"), "%s", _KeyCombinationHoldLabel(PairId))
	; AltGr cannot be part of a chord (section 6, point 5): its row says so.
	if !KeyCombinationChordPairIsAllowed(PairId)
		return [TapRow, HoldRow, Map("label", StrReplace(t("menu.shortcuts.key_combinations_chord"), "%s", t("dialog.action_picker.disabled")),
			"disabled", true, "disabled_reason_key", "menu.shortcuts.key_combinations_chord_no_altgr")]
	ChordRow := Map("action", (*) => ShowActionPicker(t("menu.shortcuts.key_combinations_chord_title_prefix") . PairLabel,
		KeyCombinationChordOf(PairId), (ActionName) => SetKeyCombinationChord(PairId, ActionName),
		false, KeyCombinationBindingId(KeyCombinationChordOwnerPair(PairId))))
	ChordRow["label"] := StrReplace(t("menu.shortcuts.key_combinations_chord"), "%s", _KeyCombinationChordLabel(PairId))
	return [TapRow, HoldRow, ChordRow]
}

; Opens the shared action picker on a pair's hold slot: the shared hold
; options, the current one marked, the window titled by the slot and the pair.
; A pick is committed while the picker is open; the script reloads once it
; has closed.
; @param PairId {String} A pair id.
; @param PairLabel {String} « First + Second ».
; @param OpenFn {Func} Replaces ShowActionPicker in tests.
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Any} What the picker returns.
KeyCombinationShowHoldPicker(PairId, PairLabel, OpenFn := 0, Path := "", ReloadFn := 0) {
	if !(KeyCombinationParsePair(PairId) is Map)
		throw ValueError("Unknown key combination.", -1, PairId)
	Slot := Map("items", TapHoldHoldPickerItems(),
		"after_close", (*) => HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend())
	Open := HasMethod(OpenFn, "Call") ? OpenFn : ShowActionPicker
	return Open.Call(t("menu.shortcuts.key_combinations_hold_hold_title_prefix") . PairLabel,
		KeyCombinationHoldOf(PairId), KeyCombinationCommitHoldPick.Bind(PairId, Path), false, "", Slot)
}

; Writes a hold picked for a pair, without reloading: the picker reloads
; once it has closed.
; @param PairId {String} A pair id.
; @param Path {String} The config.toml to write; ConfigurationFile when "".
; @param PickId {String} The picked id ("none" empties the slot).
; @returns {Integer|Boolean} 1 when written, false to keep the picker open.
KeyCombinationCommitHoldPick(PairId, Path, PickId) {
	global KEY_COMBINATION_NONE
	Option := TapHoldHoldOptionForPick(PickId)
	if !(Option is Map) {
		LoggerError("KeyCombinations", "The hold of pair '{1}' does not offer the picked action '{2}'.",
			PairId, (PickId is String) ? PickId : Type(PickId))
		return false
	}
	HoldId := (Option["kind"] == "none") ? KEY_COMBINATION_NONE : Option["id"]
	Written := SetKeyCombinationHold(PairId, HoldId, Path, (*) => 1)
	return ((Written is Integer) && Written == 1) ? 1 : false
}

; Standard AltGr reaches AHK as fake SC01D followed by SC138. Its custom
; combination outranks the ordinary SC138 hotkeys, even though those were
; created first. These two early custom variants share the existing pair
; admission and effects; QWERTY and Kana keep their existing standalone paths.
; @param Passthrough {Boolean} Which custom variant is being evaluated.
; @param IsDownFn {Func} Physical-key port used by the registered unit cases.
KeyCombinationOwnsAltGrSuffix(Passthrough, IsDownFn := 0) {
	global _KeyCombinationTaken, KeyCombinationHolds, KEY_COMBINATION_NONE
	global KEY_COMBINATION_PAIR_SEPARATOR, LayerEnabled
	; Another key's layer owns AltGr before a new pair can claim its press.
	if !IsSet(LayerEnabled) || LayerEnabled
		return false
	; #HotIf is armed before the first extraction pump initializes these owners.
	; Refuse before KeyCombinationOwns can publish a partial pair admission.
	if !IsSet(_KeyCombinationTaken) || !IsSet(KeyCombinationHolds)
		|| !IsSet(KEY_COMBINATION_NONE) || !IsSet(KEY_COMBINATION_PAIR_SEPARATOR)
		|| TapHoldHoldOptions().Length == 0
		return false
	if !KS_AltGrAddsFakeLCtrl() || !KeyCombinationOwns("alt_gr", IsDownFn)
		return false
	PairId := KeyCombinationPairId(_KeyCombinationTaken["alt_gr"], "alt_gr")
	Hold := KeyCombinationHoldOf(PairId)
	Native := Hold != KEY_COMBINATION_NONE && !_KeyCombinationHoldIsLayer(Hold)
		&& _AltGrHoldHoldsAltGr(ResolveHoldModifierKey(Hold, "alt_gr"))
	return Native == Passthrough
}

; The physical RAlt is already Down for a native AltGr hold. Its owner sends
; only the other members; suppressing/reinjecting RAlt clears AHK's SC01D
; prefix when Windows generates the fake LCtrl-up and kills AltGr suffixes.
_KeyCombinationAltGrSuffixPorts(Passthrough) {
	Ports := _KeyCombinationPorts().Clone()
	if Passthrough
		Ports["own_modifier"] := (Second, ModKey, Seconds) => TapHoldOwnImmediateModifier(
			Second, _KeyCombinationScanNames[Second], ModKey, Seconds,
			,,,,,, KS_AltGrKeyName())
	return Ports
}

; The ordinary AltGr owner is bypassed by this admitted pair. Hand its fake
; LCtrl back before publishing the pair's hold or invoking its action, so a
; remapped left_ctrl hold cannot survive as an unrelated pair modifier. The
; original LCtrl owner retains its release debt and cancels its own tap.
; @param Passthrough {Boolean} Whether the selected pair holds native AltGr.
; @param Ports {Map} Effects port; production uses the native suffix owner.
KeyCombinationFireAltGrSuffix(Passthrough, Ports := 0) {
	global _KeyCombinationTaken
	if !_KeyCombinationTaken.Has("alt_gr")
		return ""
	TapHoldAltGrTakesItsLCtrl(Passthrough)
	return KeyCombinationFire("alt_gr", Ports is Map ? Ports
		: _KeyCombinationAltGrSuffixPorts(Passthrough))
}





; =============================================
; =============================================
; ======= 5/ Simultaneous chord policy ========
; =============================================
; =============================================

; The pure third-slot policy that _shared/lua/tap_hold/key_combinations.lua owns
; on macOS and Linux: which pair a press of two keys within the simultaneous
; delay selects. _shared/tests/corpus/tap_hold/key_combination_chords.json holds
; the cases. The engine that buffers a first key for it is section 6.

; Refuses chord settings that are not a positive finite delay and an exact
; boolean. AutoHotkey's booleans are the Integers 0 and 1.
; @param DelayMs {Number} The simultaneous delay in milliseconds.
; @param Symmetric {Integer} Whether both orders of a pair select one owner.
; @returns {Map} Map("simultaneous_threshold_ms", ..., "combo_symmetric", ...).
KeyCombinationChordSettings(DelayMs, Symmetric) {
	if !(DelayMs is Number) || !(DelayMs - DelayMs == 0) || DelayMs <= 0
		throw ValueError("The chord delay must be a positive finite number.", -1, String(DelayMs))
	if !(Symmetric is Integer) || (Symmetric != 0 && Symmetric != 1)
		throw ValueError("The chord symmetry must be an exact boolean.", -1, IsObject(Symmetric) ? Type(Symmetric) : Symmetric)
	return Map(ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS, DelayMs, MenuCommand.COMBO_SYMMETRIC, Symmetric)
}

; A chord identifier, the shared id grammar. The separator of a direction key is
; a tab, which no token holds.
_KeyCombinationChordToken(Value) {
	return (Value is String) && RegExMatch(Value, "^[a-z][a-z0-9_]*\z")
}

class KeyCombinationChordPolicy {
	; @param Pairs {Array} Rows Map("id", ..., "first", ..., "second", ...), in catalogue order.
	; @param Chords {Map} Pair id -> validated action id; an absent pair is "none".
	; @param Settings {Map} As KeyCombinationChordSettings returns.
	__New(Pairs, Chords, Settings) {
		global KEY_COMBINATION_NONE
		if !(Pairs is Array) || !(Chords is Map) || !(Settings is Map)
			throw TypeError("A chord policy requires its declared catalogue, slots and settings.")
		this.Settings := KeyCombinationChordSettings(
			Settings[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS], Settings[MenuCommand.COMBO_SYMMETRIC])
		this.Directions := Map()
		this.Canonical := Map()
		SeenPairs := Map()
		for Entry in Pairs {
			if !(Entry is Map) || !_KeyCombinationChordToken(Entry.Get("id", 0))
				|| !_KeyCombinationChordToken(Entry.Get("first", 0))
				|| !_KeyCombinationChordToken(Entry.Get("second", 0))
				|| Entry["first"] == Entry["second"] || SeenPairs.Has(Entry["id"])
				throw ValueError("A chord catalogue requires distinct pairs.")
			Direction := Entry["first"] . "`t" . Entry["second"]
			Reverse := Entry["second"] . "`t" . Entry["first"]
			if this.Directions.Has(Direction)
				throw ValueError("A chord catalogue holds a duplicate direction.", -1, Entry["id"])
			Action := Chords.Get(Entry["id"], KEY_COMBINATION_NONE)
			if !_KeyCombinationChordToken(Action)
				throw ValueError("A chord action must already be validated.", -1, Entry["id"])
			Row := Map("id", Entry["id"], "first", Entry["first"], "second", Entry["second"], "action", Action)
			this.Directions[Direction] := Row
			SeenPairs[Entry["id"]] := Row
			this.Canonical[Entry["id"]] := this.Directions.Has(Reverse)
				? this.Canonical[this.Directions[Reverse]["id"]] : Row
		}
	}

	; The pair that owns PairId under symmetry, the earlier of its two orders.
	; @returns {String} A pair id, or "" for an unknown one.
	CanonicalPair(PairId) {
		return this.Canonical.Has(PairId) ? this.Canonical[PairId]["id"] : ""
	}

	; The pair a press of First then Second, ElapsedMs apart, selects.
	; @returns {Map|Boolean} Map("pair_id", "first", "second", "action", "binding"), or false.
	Choose(First, Second, ElapsedMs) {
		global KEY_COMBINATION_NONE, KEY_COMBINATION_BINDING_SCOPE
		if !(ElapsedMs is Number) || !(ElapsedMs - ElapsedMs == 0) || ElapsedMs < 0
			|| ElapsedMs > this.Settings[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS]
			return false
		if !_KeyCombinationChordToken(First) || !_KeyCombinationChordToken(Second)
			return false
		Direction := First . "`t" . Second
		if !this.Directions.Has(Direction)
			return false
		Row := this.Directions[Direction]
		if this.Settings[MenuCommand.COMBO_SYMMETRIC]
			Row := this.Canonical[Row["id"]]
		if (Row["action"] == KEY_COMBINATION_NONE)
			return false
		return Map("pair_id", Row["id"], "first", First, "second", Second, "action", Row["action"],
			"binding", GestureBindingId(KEY_COMBINATION_BINDING_SCOPE, Row["id"]))
	}
}





; =============================================
; =============================================
; ======= 6/ Simultaneous chord engine ========
; =============================================
; =============================================

; The engine of the third slot, as platform/remap/key_combination_engine.lua is on
; Linux. A key that begins a chord, pressed with no other catalogue key held, waits:
; its hotkey swallows the press and nothing reaches its tap-hold. A second key within
; the delay that selects a chord runs the action, and both keys stay consumed until
; they come up. Anything else ends the wait: the delay passing, the key coming up, or
; another key. The first key is then sent again and handled exactly as if just struck.
;
; 1. Plain typing pays one read of a boolean per character, and only while no key is
;    waiting: with no chord assigned no key ever waits, so nothing changes at all.
; 2. A character struck during the wait must not overtake the key: it joins the queue
;    through the roll block (tap_hold_roll_keys.ahk), and is sent after it.
; 3. The queue is drained from a timer, not from the hotkey that filled it: a hotkey
;    thread cannot resume under the thread of the key it sends (project-ahk-an-
;    undecided-key-is-decided-by-the-thread-that-interrupts-it), and that key's
;    tap-hold must run first. A typing key then finds it undecided, as when typed.
; 4. Sent at level 1: below every driver hotkey (level 2), and the hotstring watcher
;    (I1) sees it. A key's physical state stays true: only its press was swallowed.
; 5. AltGr is never part of a chord. On a standard layout it arrives as a fake LCtrl
;    then RAlt, and suppressing either kills it (project-ahk-altgr-fake-lctrl), so
;    there LCtrl is out too. On a Kana layout SC138 is the AltGr prefix every "SC138 & X"
;    needs to see on its press, and a Send of it is not that key (KS_AltGrSendKey).

; How often the wait looks at its key, and the level the keys are sent again at.
global KEY_COMBINATION_CHORD_POLL_MS := 5
global KEY_COMBINATION_CHORD_REPLAY_LEVEL := 1
; Actions a chord cannot hold: they need the key's own press or release. As Linux.
global KEY_COMBINATION_CHORD_REFUSED_ACTIONS := Map("one_shot_shift", true, "run_program", true, "alt_tab_monitor", true)

; Pair id -> action, the delay and symmetry in force, and the switch of the chords.
global KeyCombinationChords := Map()
global KeyCombinationChordConfig := 0
global _KeyCombinationChordPolicy := 0
; Key id -> true for a key some chord begins: the only keys that ever wait.
global _KeyCombinationChordFirsts := Map()
; The key waiting ("" for none) and the tick of its press.
global _KeyCombinationChordWaiting := ""
global _KeyCombinationChordWaitAt := 0
; Key id -> true while a chord consumes that key's press.
global _KeyCombinationChordTaken := Map()
; Keys to send again after the first key, as "key:<id>" or a scan code.
global _KeyCombinationChordQueue := []
; The one read of plain typing (point 1): a key waits, or keys are queued.
global _KeyCombinationChordBusy := false
; The key being sent again: its own chord variants stand aside.
global _KeyCombinationChordReplaying := ""
global _KeyCombinationChordTimerFn := 0
; The waiting/queued batch keeps the lifecycle authority admitted before probes.
global _KeyCombinationChordOwner := 0

; The production effects of the engine, replaced by recorders in the unit suite.
_KeyCombinationChordPorts() {
	static Ports := Map(
		"tick", () => A_TickCount,
		"is_held", _KeyCombinationKeyIsHeld,
		"send", (Keys) => SendEvent(Keys),
		"run_action", _KeyCombinationRunTap,
		"arm_poll", _KeyCombinationChordArmPoll,
		"arm_drain", () => SetTimer(KeyCombinationChordDrain, -1))
	return Ports
}

_KeyCombinationChordDeclaredSettings() {
	return KeyCombinationChordSettings(ManifestDefaultFor(ConfigKey.MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS),
		ManifestDefaultFor(ConfigKey.MOD_COMBOS_SYMMETRIC) ? 1 : 0)
}

; The delay and symmetry the menu shows: what the boot read, else the manifest's
; declared values, since a menu can be built by a caller that loaded no config.
; @returns {Map} KeyCombinationChordSettings's shape.
KeyCombinationChordCurrentSettings() {
	global KeyCombinationChordConfig
	return IsObject(KeyCombinationChordConfig) ? KeyCombinationChordConfig : _KeyCombinationChordDeclaredSettings()
}

; Reads the third slots with the other two: an action is admitted as on Linux, and
; the delay and symmetry fall to the manifest's declared values when absent.
; @param Cache {Map} The parsed config.

; This private compatibility switch is not a feature-manifest leaf. Its owner
; defaults to on, with native booleans and the old writer's exact bare0/1
; spellings admitted; other source types retain that default.
_KeyCombinationChordBootEnabled(Snapshot) {
	for Row in Snapshot.Rows {
		if Row.Section != ConfigLeaf.MOD_COMBOS || Row.Key != "enabled"
			continue
		if Row.Typed is TOML_Bool
			return !!Row.Typed.Value
		Raw := Trim(TOML_StripInlineComment(Row.Raw), " `t")
		if Row.Typed is Integer && (Raw == "0" || Raw == "1")
			return Row.Typed == 1
		return true
	}
	return true
}

KeyCombinationChordsReadConfig(Cache) {
	global KeyCombinationChords, KeyCombinationChordConfig, _KeyCombinationChordPolicy, _KeyCombinationChordFirsts
	global KEY_COMBINATION_NONE, GESTURE_ACTIONS, KEY_COMBINATION_CHORD_REFUSED_ACTIONS
	Stored := (Cache is Map) && Cache.Has(ConfigLeaf.MOD_COMBOS) ? Cache[ConfigLeaf.MOD_COMBOS] : Map()
	Delay := Stored.Get(ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS, ManifestDefaultFor(ConfigKey.MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS))
	Symmetric := Stored.Get("symmetric", ManifestDefaultFor(ConfigKey.MOD_COMBOS_SYMMETRIC))
	Enabled := Stored.Get("enabled", true)
	Snapshot := ConfigTomlBootSnapshot(Cache)
	if IsObject(Snapshot) {
		ConfigTomlBootSnapshotValue(Snapshot, ConfigLeaf.MOD_COMBOS, ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS, &Delay)
		ConfigTomlBootSnapshotValue(Snapshot, ConfigLeaf.MOD_COMBOS, "symmetric", &Symmetric)
		Enabled := _KeyCombinationChordBootEnabled(Snapshot)
	}
	try KeyCombinationChordConfig := KeyCombinationChordSettings(
		IsNumber(Delay) ? Delay + 0 : Delay, Symmetric ? 1 : 0)
	catch as Err {
		LoggerWarn("KeyCombinations", "[mod_combos] is refused ({1}): the declared delay and symmetry apply.", Err.Message)
		KeyCombinationChordConfig := _KeyCombinationChordDeclaredSettings()
	}
	Chords := Map()
	if (Cache is Map) {
		for Section, Row in Cache {
			if !RegExMatch(Section, "^mod_combos\.config\.(.+)$", &Found) || !(Row is Map) || !Row.Has("combo")
				continue
			Action := Row["combo"]
			if !(KeyCombinationParsePair(Found[1]) is Map) {
				LoggerWarn("KeyCombinations", "[{1}] names no pair of tap-hold keys — ignored.", Section)
			} else if (Action != KEY_COMBINATION_NONE) {
				if ((Action is String) && GESTURE_ACTIONS.Has(Action) && !KEY_COMBINATION_CHORD_REFUSED_ACTIONS.Has(Action))
					Chords[Found[1]] := Action
				else
					LoggerWarn("KeyCombinations", "[{1}] holds unusable chord action '{2}' — left empty.", Section, Action)
			}
		}
	}
	KeyCombinationChords := Chords
	_KeyCombinationChordPolicy := 0
	_KeyCombinationChordFirsts := Map()
	if !Enabled || Chords.Count == 0
		return
	Pairs := []
	Ids := KeyCombinationKeyIds()
	for _, First in Ids {
		for _, Second in Ids {
			if (First != Second)
				Pairs.Push(Map("id", KeyCombinationPairId(First, Second), "first", First, "second", Second))
		}
	}
	_KeyCombinationChordPolicy := KeyCombinationChordPolicy(Pairs, Chords, KeyCombinationChordConfig)
	for _, First in Ids {
		for _, Second in Ids {
			if (First != Second && _KeyCombinationChordPolicy.Choose(First, Second, 0)) {
				_KeyCombinationChordFirsts[First] := true
				break
			}
		}
	}
	LoggerInfo("KeyCombinations", "Key chords read: {1} chord(s), {2} ms, symmetric={3}.", Chords.Count,
		KeyCombinationChordConfig[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS], KeyCombinationChordConfig[MenuCommand.COMBO_SYMMETRIC])
}

; Whether a key can be part of a chord on the layout in force (point 5).
; @param KeyId {String} Canonical tap-hold key id.
; @returns {Boolean}
KeyCombinationChordKeyIsAllowed(KeyId) {
	if (KeyId == "alt_gr")
		return false
	return KeyId != "left_ctrl" || !KS_AltGrAddsFakeLCtrl()
}

; Whether a pair can hold a chord on the layout in force, for its menu row.
; @param PairId {String} A pair id.
; @returns {Boolean}
KeyCombinationChordPairIsAllowed(PairId) {
	Pair := KeyCombinationParsePair(PairId)
	return (Pair is Map) && KeyCombinationChordKeyIsAllowed(Pair["first"]) && KeyCombinationChordKeyIsAllowed(Pair["second"])
}

; Whether a tap-hold key is held for the user, a press replayed by the native owner
; included. The criterion of a press still reads its own key through
; _KeyCombinationKeyIsDown: a held replay would read as its own auto-repeat there.
; @param KeyId {String} Canonical tap-hold key id.
; @returns {Boolean}
_KeyCombinationKeyIsHeld(KeyId) {
	global _KeyCombinationScanNames
	if (KeyId == "left_ctrl")
		return TapHoldUserLCtrlHeld(KS_IsHeld) ? true : false
	if !IsSet(_KeyCombinationScanNames) || !_KeyCombinationScanNames.Has(KeyId)
		return false
	return KS_IsHeld(_KeyCombinationScanNames[KeyId]) ? true : false
}

; The #HotIf of the chord side of the pair hotkeys. The handler decides, and
; AutoHotkey may ask this several times for one event. Admitting a wait turns Busy
; on here: the hook asks about the second key before the first key's handler has
; run, and a second key struck that close would otherwise pass untouched. Handlers
; run in order; a queue drain clears a Busy no handler followed.
; @param KeyId {String} Tap-hold key id of the hotkey's key.
; @param Ports {Map} Test seams, _KeyCombinationChordPorts by default.
; @returns {Boolean}
KeyCombinationChordOwns(KeyId, Ports := 0) {
	global _KeyCombinationChordFirsts, _KeyCombinationChordTaken, _KeyCombinationChordBusy, _KeyCombinationChordReplaying
	global _KeyCombinationChordOwner
	if !IsSet(_KeyCombinationChordBusy) || !IsSet(_KeyCombinationChordFirsts) || !IsSet(_KeyCombinationChordTaken)
			|| !IsSet(_KeyCombinationChordReplaying) || !IsSet(_KeyCombinationChordOwner)
		return false
	if !(Ports is Map)
		Ports := _KeyCombinationChordPorts()
	Owner := _KeyCombinationChordCurrentOwner(Ports)
	if A_IsSuspended || _KeyCombinationChordReplaying == KeyId
		return false
	if _KeyCombinationChordTaken.Has(KeyId)
		return true
	if _KeyCombinationChordBusy
		return KeyCombinationChordKeyIsAllowed(KeyId)
	if !_KeyCombinationChordFirsts.Has(KeyId) || !KeyCombinationChordKeyIsAllowed(KeyId)
		return false
	Candidate := IsObject(Owner) ? Owner : TapHoldNewOwner()
	if !_KeyCombinationChordCanWait(KeyId, Ports)
		return false
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || !TapHoldOwnerCurrent(Candidate) || _KeyCombinationChordOwner != Owner
			return false
		_KeyCombinationChordOwner := Candidate
		_KeyCombinationChordBusy := true
		return true
	} finally Critical(PreviousCritical)
}


; A retired batch cannot intercept fresh typing before its old timer delivers.
KeyCombinationChordIsBusy() {
	global _KeyCombinationChordBusy, _KeyCombinationChordOwner
	return IsSet(_KeyCombinationChordBusy) && _KeyCombinationChordBusy
		&& IsSet(_KeyCombinationChordOwner) && _KeyCombinationChordIsCurrent(_KeyCombinationChordOwner)
}

; Exact batch identity prevents an old callback from mutating resumed input.
_KeyCombinationChordIsCurrent(Owner) {
	global _KeyCombinationChordOwner
	return IsObject(Owner) && _KeyCombinationChordOwner == Owner
		&& TapHoldOwnerCurrent(Owner) && !A_IsSuspended
}

_KeyCombinationChordRetire(Owner, Ports) {
	global _KeyCombinationChordOwner, _KeyCombinationChordWaiting, _KeyCombinationChordWaitAt
	global _KeyCombinationChordTaken, _KeyCombinationChordQueue, _KeyCombinationChordBusy, _KeyCombinationChordReplaying
	PreviousCritical := Critical("On")
	try {
		if _KeyCombinationChordOwner != Owner
			return false
		_KeyCombinationChordOwner := 0
		_KeyCombinationChordWaiting := "", _KeyCombinationChordWaitAt := 0
		_KeyCombinationChordTaken := Map(), _KeyCombinationChordQueue := []
		_KeyCombinationChordBusy := false, _KeyCombinationChordReplaying := ""
		; This batch has no owned native Down: discard only its unsent replay.
		Ports["arm_poll"].Call(false)
		return true
	} finally Critical(PreviousCritical)
}

_KeyCombinationChordCurrentOwner(Ports) {
	global _KeyCombinationChordOwner
	if !IsSet(_KeyCombinationChordOwner)
		return 0
	Owner := _KeyCombinationChordOwner
	if !IsObject(Owner)
		return 0
	if !_KeyCombinationChordIsCurrent(Owner) {
		_KeyCombinationChordRetire(Owner, Ports)
		return 0
	}
	return Owner
}

; Whether a press of KeyId begins a wait: the chords are on, nothing owns the keyboard
; (a layer, a pause, an undecided typing key), and no other catalogue key is held.
_KeyCombinationChordCanWait(KeyId, Ports) {
	global LayerEnabled
	if A_IsSuspended || !KeyCombinationsAreOn() || (IsSet(LayerEnabled) && LayerEnabled) || _TapHoldRollState()["key"] != ""
		return false
	IsHeld := Ports["is_held"]
	for _, Other in KeyCombinationKeyIds() {
		; Its own hold is read too: a held key's auto-repeat never begins a wait.
		if IsHeld.Call(Other)
			return false
	}
	return true
}

; The handler of the chord side of a pair hotkey.
; @param KeyId {String} Tap-hold key id of the hotkey's key.
; @param Ports {Map} Test seams, _KeyCombinationChordPorts by default.
; @returns {String} "wait", "chord", "queued", "swallowed", or "" for a key that is
;          no chord's: its pair may still take it.
KeyCombinationChordHandle(KeyId, Ports := 0) {
	global _KeyCombinationChordPolicy, _KeyCombinationChordWaiting, _KeyCombinationChordWaitAt
	global _KeyCombinationChordTaken, _KeyCombinationChordBusy, _KeyCombinationChordQueue
	if !(Ports is Map)
		Ports := _KeyCombinationChordPorts()
	Owner := _KeyCombinationChordCurrentOwner(Ports)
	if !IsObject(Owner) {
		if !KeyCombinationChordOwns(KeyId, Ports)
			return ""
		Owner := _KeyCombinationChordCurrentOwner(Ports)
		if !IsObject(Owner)
			return ""
	}
	if _KeyCombinationChordTaken.Has(KeyId)
		return "swallowed"
	if (_KeyCombinationChordWaiting == "" && _KeyCombinationChordQueue.Length == 0) {
		global _KeyCombinationChordFirsts
		if !_KeyCombinationChordFirsts.Has(KeyId) || !KeyCombinationChordOwns(KeyId, Ports) {
			_KeyCombinationChordEndWait(Owner)
			return ""
		}
		Now := Ports["tick"].Call()
		if !_KeyCombinationChordIsCurrent(Owner)
			return ""
		PreviousCritical := Critical("On")
		try {
			if !_KeyCombinationChordIsCurrent(Owner)
				return ""
			_KeyCombinationChordWaiting := KeyId
			_KeyCombinationChordWaitAt := Now
			_KeyCombinationChordBusy := true
		} finally Critical(PreviousCritical)
		Ports["arm_poll"].Call(true)
		return _KeyCombinationChordIsCurrent(Owner) ? "wait" : ""
	}
	if (_KeyCombinationChordWaiting == KeyId)
		return "swallowed"
	if (_KeyCombinationChordWaiting != "") {
		First := _KeyCombinationChordWaiting
		WaitAt := _KeyCombinationChordWaitAt
		Now := Ports["tick"].Call()
		if !_KeyCombinationChordIsCurrent(Owner)
			return ""
		Chosen := _KeyCombinationChordPolicy.Choose(First, KeyId, TickElapsed(WaitAt, Now))
		if ((Chosen is Map) && !AiActionBlocked(Chosen["action"])) {
			PreviousCritical := Critical("On")
			try {
				if !_KeyCombinationChordIsCurrent(Owner)
					return ""
				_KeyCombinationChordEndWait(Owner)
				_KeyCombinationChordTaken[First] := true
				_KeyCombinationChordTaken[KeyId] := true
			} finally Critical(PreviousCritical)
			Ports["arm_poll"].Call(true)
			if !_KeyCombinationChordIsCurrent(Owner)
				return ""
			Pair := KeyCombinationParsePair(Chosen["pair_id"])
			LoggerInfo("KeyCombinations", "Chord '{1}' fired.", Chosen["pair_id"])
			if !_KeyCombinationChordIsCurrent(Owner)
				return ""
			Ports["run_action"].Call(Pair["first"], Pair["second"], Chosen["action"])
			return "chord"
		}
		_KeyCombinationChordFlush(Ports)
	}
	PreviousCritical := Critical("On")
	try {
		if !_KeyCombinationChordIsCurrent(Owner)
			return ""
		_KeyCombinationChordQueue.Push("key:" . KeyId)
		_KeyCombinationChordBusy := true
	} finally Critical(PreviousCritical)
	Ports["arm_drain"].Call()
	return "queued"
}

; A character struck while the chords are busy: it follows the keys before it.
; @param Sc {Integer} Its scan code.
; @param Ports {Map} Test seams, _KeyCombinationChordPorts by default.
KeyCombinationChordInterrupt(Sc, Ports := 0) {
	global _KeyCombinationChordQueue, _KeyCombinationChordBusy
	if !(Ports is Map)
		Ports := _KeyCombinationChordPorts()
	Owner := _KeyCombinationChordCurrentOwner(Ports)
	if !IsObject(Owner)
		return
	_KeyCombinationChordFlush(Ports)
	PreviousCritical := Critical("On")
	try {
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		_KeyCombinationChordQueue.Push(Sc)
		_KeyCombinationChordBusy := true
	} finally Critical(PreviousCritical)
	Ports["arm_drain"].Call()
}

; Marks the wait over; the queue may still keep the chords busy.
_KeyCombinationChordEndWait(Owner := 0) {
	global _KeyCombinationChordWaiting, _KeyCombinationChordBusy, _KeyCombinationChordQueue
	PreviousCritical := Critical("On")
	try {
		if IsObject(Owner) && !_KeyCombinationChordIsCurrent(Owner)
			return
		_KeyCombinationChordWaiting := ""
		_KeyCombinationChordBusy := _KeyCombinationChordQueue.Length > 0
	} finally Critical(PreviousCritical)
}

; Ends a wait with no chord: the first key is sent again, as a press when it is
; still held (its physical release follows) and as a tap when it already came up.
_KeyCombinationChordFlush(Ports) {
	global _KeyCombinationChordWaiting, _KeyCombinationChordQueue
	Owner := _KeyCombinationChordCurrentOwner(Ports)
	if !IsObject(Owner)
		return
	PreviousCritical := Critical("On")
	try {
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		First := _KeyCombinationChordWaiting
		if (First == "")
			return
		Queue := _KeyCombinationChordQueue
		Queue.Push("key:" . First)
		_KeyCombinationChordEndWait(Owner)
	} finally Critical(PreviousCritical)
	Held := Ports["is_held"].Call(First)
	if !_KeyCombinationChordIsCurrent(Owner)
		return
	_KeyCombinationChordSendKey(First, Held, Ports, Owner)
	PreviousCritical := Critical("On")
	try {
		if !_KeyCombinationChordIsCurrent(Owner) || _KeyCombinationChordQueue != Queue
			return
		if Queue.Length > 0 && Queue[1] == "key:" . First
			Queue.RemoveAt(1)
		_KeyCombinationChordEndWait(Owner)
	} finally Critical(PreviousCritical)
}

; Sends one catalogue key again, past its own chord variants.
_KeyCombinationChordSendKey(KeyId, Held, Ports, Owner := 0) {
	global _KeyCombinationChordReplaying, _KeyCombinationScanNames, KEY_COMBINATION_CHORD_REPLAY_LEVEL
	if !IsObject(Owner)
		Owner := _KeyCombinationChordCurrentOwner(Ports)
	; Only this one replay edge is atomic with its admission, never the queue.
	PreviousCritical := Critical("On")
	try {
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		Name := _KeyCombinationScanNames[KeyId]
		PreviousLevel := A_SendLevel
		SendLevel(KEY_COMBINATION_CHORD_REPLAY_LEVEL)
		_KeyCombinationChordReplaying := KeyId
		try Ports["send"].Call("{Blind}{" . Name . (Held ? " down" : "") . "}")
		finally {
			if _KeyCombinationChordIsCurrent(Owner)
				_KeyCombinationChordReplaying := ""
			SendLevel(PreviousLevel)
		}
	} finally Critical(PreviousCritical)
}

; Sends the queued keys, in the order they were struck. A catalogue key struck under
; a held first key is first offered to its pair, as its press would have been.
; @param Ports {Map} Test seams, _KeyCombinationChordPorts by default.
KeyCombinationChordDrain(Ports := 0) {
	global _KeyCombinationChordQueue, KEY_COMBINATION_CHORD_REPLAY_LEVEL, _KeyCombinationChordWaiting
	if !(Ports is Map)
		Ports := _KeyCombinationChordPorts()
	Owner := _KeyCombinationChordCurrentOwner(Ports)
	if !IsObject(Owner)
		return
	Queue := _KeyCombinationChordQueue
	while (Queue.Length > 0) {
		PreviousCritical := Critical("On")
		try {
			if !_KeyCombinationChordIsCurrent(Owner) || _KeyCombinationChordQueue != Queue
				return
			Item := Queue.RemoveAt(1)
		} finally Critical(PreviousCritical)
		if !(Item is String) {
			PreviousCritical := Critical("On")
			try {
				if !_KeyCombinationChordIsCurrent(Owner)
					return
				PreviousLevel := A_SendLevel
				SendLevel(KEY_COMBINATION_CHORD_REPLAY_LEVEL)
				try Ports["send"].Call("{Blind}{" . Format("SC{:03X}", Item) . "}")
				finally SendLevel(PreviousLevel)
			} finally Critical(PreviousCritical)
			continue
		}
		KeyId := SubStr(Item, 5)
		IsHeld := Ports["is_held"]
		Taken := KeyCombinationOwns(KeyId, (Name) => Name == KeyId ? false : IsHeld.Call(Name))
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		if Taken {
			_KeyCombinationChordEndWait(Owner)
			KeyCombinationFire(KeyId)
		} else {
			Held := IsHeld.Call(KeyId)
			if !_KeyCombinationChordIsCurrent(Owner)
				return
			_KeyCombinationChordSendKey(KeyId, Held, Ports, Owner)
		}
	}
	_KeyCombinationChordEndWait(Owner)
}

; One look at the wait and at the keys a chord took.
; @param Ports {Map} Test seams, _KeyCombinationChordPorts by default.
KeyCombinationChordTick(Ports := 0) {
	global _KeyCombinationChordWaiting, _KeyCombinationChordWaitAt, _KeyCombinationChordTaken, KeyCombinationChordConfig
	if !(Ports is Map)
		Ports := _KeyCombinationChordPorts()
	Owner := _KeyCombinationChordCurrentOwner(Ports)
	if !IsObject(Owner)
		return
	IsHeld := Ports["is_held"]
	if (_KeyCombinationChordWaiting != "") {
		Waiting := _KeyCombinationChordWaiting, WaitAt := _KeyCombinationChordWaitAt
		Now := Ports["tick"].Call()
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		Elapsed := TickElapsed(WaitAt, Now)
		Held := IsHeld.Call(Waiting)
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		if (Elapsed > KeyCombinationChordConfig[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS] || !Held || KS_IsDown("SC138"))
			_KeyCombinationChordFlush(Ports)
	}
	if !_KeyCombinationChordIsCurrent(Owner)
		return
	Taken := _KeyCombinationChordTaken, Done := []
	for KeyId in Taken {
		Held := IsHeld.Call(KeyId)
		if !_KeyCombinationChordIsCurrent(Owner)
			return
		if !Held
			Done.Push(KeyId)
	}
	PreviousCritical := Critical("On")
	try {
		if !_KeyCombinationChordIsCurrent(Owner) || _KeyCombinationChordTaken != Taken
			return
		for _, KeyId in Done
			Taken.Delete(KeyId)
		Disarm := _KeyCombinationChordWaiting == "" && Taken.Count == 0
	} finally Critical(PreviousCritical)
	if Disarm && _KeyCombinationChordIsCurrent(Owner)
		Ports["arm_poll"].Call(false)
}

; Runs the look while a key waits or a chord holds its keys, and only then.
_KeyCombinationChordArmPoll(Armed) {
	global _KeyCombinationChordTimerFn, KEY_COMBINATION_CHORD_POLL_MS
	if !IsObject(_KeyCombinationChordTimerFn)
		_KeyCombinationChordTimerFn := KeyCombinationChordTick
	if !Armed {
		SetTimer(_KeyCombinationChordTimerFn, 0)
		return
	}
	SetTimer(_KeyCombinationChordTimerFn, KEY_COMBINATION_CHORD_POLL_MS)
}

; Assigns a chord to a pair and persists it, then reloads. Under symmetry the pair's
; canonical order owns the slot, as the policy reads it.
; @param PairId {String} A pair id.
; @param ActionName {String} A catalogue action id, or "none".
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Boolean} False when nothing was committed.
SetKeyCombinationChord(PairId, ActionName, Path := "", ReloadFn := 0) {
	global KEY_COMBINATION_NONE, GESTURE_ACTIONS, KEY_COMBINATION_CHORD_REFUSED_ACTIONS, ConfigurationFile
	if !KeyCombinationChordPairIsAllowed(PairId)
		throw ValueError("This key combination cannot hold a chord.", -1, PairId)
	if (ActionName != KEY_COMBINATION_NONE
			&& (!GESTURE_ACTIONS.Has(ActionName) || KEY_COMBINATION_CHORD_REFUSED_ACTIONS.Has(ActionName)))
		throw ValueError("This action cannot be a chord.", -1, ActionName)
	Row := { Section: "mod_combos.config." . KeyCombinationChordOwnerPair(PairId), Key: "combo" }
	if (ActionName == KEY_COMBINATION_NONE)
		Row.Delete := 1
	else
		Row.Value := ActionName
	if !ConfigCommitUpdates(Path != "" ? Path : ConfigurationFile, [Row], "the chord of key combination '" . PairId . "'")
		return false
	LoggerInfo("KeyCombinations", "Pair '{1}' chord → '{2}'.", PairId, ActionName)
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}

; The pair whose slot holds PairId's chord: itself, or under symmetry the earlier of
; its two orders in the catalogue, as the policy's canonical pair.
; @param PairId {String} A pair id.
; @returns {String} A pair id.
KeyCombinationChordOwnerPair(PairId) {
	global KeyCombinationChordConfig
	if !IsObject(KeyCombinationChordConfig)
		return PairId
	return _KeyCombinationChordOwnerPairFor(PairId, KeyCombinationChordConfig[MenuCommand.COMBO_SYMMETRIC])
}

; The owner pair of PairId's chord under an explicit symmetry, for a planner
; reading a configuration other than the one in force.
; @param PairId {String} A pair id.
; @param Symmetric {Boolean} Whether both orders of a pair share one chord.
; @returns {String} A pair id.
_KeyCombinationChordOwnerPairFor(PairId, Symmetric) {
	Pair := KeyCombinationParsePair(PairId)
	if !(Pair is Map) || !Symmetric
		return PairId
	for _, Id in KeyCombinationKeyIds() {
		if (Id == Pair["first"])
			return PairId
		if (Id == Pair["second"])
			return KeyCombinationPairId(Pair["second"], Pair["first"])
	}
	return PairId
}

; The action a pair's chord runs, or "none".
; @param PairId {String} A pair id.
; @returns {String}
KeyCombinationChordOf(PairId) {
	global KeyCombinationChords, KEY_COMBINATION_NONE
	if !IsSet(KeyCombinationChords) || !IsSet(KEY_COMBINATION_NONE)
		return ""
	return KeyCombinationChords.Get(KeyCombinationChordOwnerPair(PairId), KEY_COMBINATION_NONE)
}

; The label of a pair's chord slot: its action, or the picker's « disabled ».
_KeyCombinationChordLabel(PairId) {
	global GESTURE_ACTIONS, KEY_COMBINATION_NONE
	Action := KeyCombinationChordOf(PairId)
	if (Action == KEY_COMBINATION_NONE || !GESTURE_ACTIONS.Has(Action))
		return t("dialog.action_picker.disabled")
	return GestureActionDisplayLabel(Action, KeyCombinationBindingId(KeyCombinationChordOwnerPair(PairId)))
}

; Flips the symmetry of the chords, then reloads.
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Boolean} False when nothing was committed.
KeyCombinationChordToggleSymmetric(Path := "", ReloadFn := 0) {
	global ConfigurationFile
	Rows := [ManifestSparseOperation(ConfigKey.MOD_COMBOS_SYMMETRIC, !KeyCombinationChordCurrentSettings()[MenuCommand.COMBO_SYMMETRIC])]
	if !ConfigCommitUpdates(Path != "" ? Path : ConfigurationFile, Rows, "the symmetry of the key chords")
		return false
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}

; The rows that copy every pair's tap slot into its chord slot, planned from one
; decoded configuration as macOS and Linux plan their bulk copy: the chord takes
; the tap's action and an empty tap empties the chord. Under symmetry a chord
; slot belongs to the earlier order of its pair, so only that order's tap is
; copied. A pair that cannot hold a chord on the layout in force is skipped, and
; so is a tap action no chord can run (KEY_COMBINATION_CHORD_REFUSED_ACTIONS),
; which is logged with its pair.
; @param Snapshot {Object} A ConfigTomlDecodeSnapshot result.
; @param AllowedFn {Func} Replaces KeyCombinationChordPairIsAllowed in tests.
; @returns {Array} Config update rows; empty when every chord already matches.
KeyCombinationChordCopyRows(Snapshot, AllowedFn := 0) {
	global KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_NONE, KEY_COMBINATION_CHORD_REFUSED_ACTIONS
	Cache := Snapshot.Cache
	Taps := _KeyCombinationReadSlots(Cache, KEY_COMBINATION_TAP_SECTION, false)
	ConfigTomlBootSnapshotValue(Snapshot, ConfigLeaf.MOD_COMBOS, "symmetric", &Symmetric)
	Allowed := HasMethod(AllowedFn, "Call") ? AllowedFn : KeyCombinationChordPairIsAllowed
	Rows := []
	Ids := KeyCombinationKeyIds()
	for _, First in Ids {
		for _, Second in Ids {
			if (First == Second)
				continue
			PairId := KeyCombinationPairId(First, Second)
			if (_KeyCombinationChordOwnerPairFor(PairId, Symmetric) != PairId) || !Allowed.Call(PairId)
				continue
			Tap := Taps.Get(PairId, KEY_COMBINATION_NONE)
			if KEY_COMBINATION_CHORD_REFUSED_ACTIONS.Has(Tap) {
				LoggerWarn("KeyCombinations", "Pair '{1}' tap '{2}' cannot run as a chord — its chord is left as it is.",
					PairId, Tap)
				continue
			}
			Section := "mod_combos.config." . PairId
			Stored := Cache.Get(Section, 0)
			Current := (Stored is Map) && Stored.Has("combo") ? Stored["combo"] : KEY_COMBINATION_NONE
			if (Current == Tap)
				continue
			if (Tap == KEY_COMBINATION_NONE)
				Rows.Push({ Section: Section, Key: "combo", Delete: 1 })
			else
				Rows.Push({ Section: Section, Key: "combo", Value: Tap })
		}
	}
	return Rows
}

; Reads the configuration only once the commit owns it, so a sibling write
; cannot slip between the plan and its batch.
_KeyCombinationBuildChordCopyPlan(Path, Outcome, AllowedFn := 0) {
	Content := FileExist(Path) ? FSReadStrict(Path) : ""
	Rows := KeyCombinationChordCopyRows(ConfigTomlDecodeSnapshot(Content), AllowedFn)
	Outcome.rows := Rows.Length
	return Rows.Length ? { updates: Rows } : { noop: true }
}

; The « Copy tap → combo » command, as on macOS and Linux: every pair's chord
; slot takes its tap action in one config batch, then the driver reloads.
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @param AllowedFn {Func} Replaces KeyCombinationChordPairIsAllowed in tests.
; @returns {Boolean} False when nothing was committed.
KeyCombinationCopyTapsToChords(Path := "", ReloadFn := 0, AllowedFn := 0) {
	global ConfigurationFile
	Target := Path != "" ? Path : ConfigurationFile
	Outcome := { rows: 0 }
	if !ConfigCommitBuilt(Target, "the copy of the key combination taps into their chords",
			_KeyCombinationBuildChordCopyPlan.Bind(Target, Outcome, AllowedFn))
		return false
	if (Outcome.rows == 0) {
		LoggerInfo("KeyCombinations", "Every chord already runs its pair's tap: nothing to copy.")
		return true
	}
	LoggerInfo("KeyCombinations", "{1} chord slot(s) copied from their tap.", Outcome.rows)
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}

; The list provider of the manifest's "combo_timings" entry: the delay of the chords.
; @returns {Array} One row.
KeyCombinationChordTimingRows() {
	Delay := KeyCombinationChordCurrentSettings()[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS]
	Row := Map("action", (*) => KeyCombinationChordPromptDelay())
	Row["label"] := StrReplace(t("menu.tapholds.simultaneous_title"), "%s", Delay . " ms")
	return [Row]
}

; Asks for the delay of the chords and persists a positive number, then reloads.
; @returns {Boolean} False when nothing was committed.
KeyCombinationChordPromptDelay() {
	global ConfigurationFile
	Default := ManifestDefaultFor(ConfigKey.MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS)
	Box := Ui_InputBox(StrReplace(t("menu.tapholds.simultaneous_dialog_prompt"), "%d", Default),
		t("menu.tapholds.simultaneous_dialog_title"), "w420 h220", KeyCombinationChordCurrentSettings()[ConfigLeaf.SIMULTANEOUS_THRESHOLD_MS])
	if (Box.Result != "OK")
		return false
	return KeyCombinationChordCommitDelay(Trim(Box.Value))
}

; Persists a delay typed by the user, then reloads; anything but a positive number
; is reported and changes nothing.
; @param Text {String} What was typed.
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @returns {Boolean} False when nothing was committed.
KeyCombinationChordCommitDelay(Text, Path := "", ReloadFn := 0) {
	global ConfigurationFile
	Parsed := ""
	Valid := RegExMatch(Text, "^\d+(\.\d+)?$")
		&& (InStr(Text, ".") ? NumberTryParseFiniteFloat(Text, &Parsed) : NumberTryParseInputInteger(Text, &Parsed))
	if !Valid || Parsed <= 0 {
		LoggerWarn("KeyCombinations", "The chord delay '{1}' is no positive number: nothing changes.", Text)
		return false
	}
	Rows := [ManifestSparseOperation(ConfigKey.MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS, Parsed)]
	if !ConfigCommitUpdates(Path != "" ? Path : ConfigurationFile, Rows, "the delay of the key chords")
		return false
	return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}
