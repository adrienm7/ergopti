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
; ==============================================================================

#Requires AutoHotkey v2.0





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
; Tap-hold key id -> the name of its scan code ("SC03A"), and back: read once
; with the slots, so the criterion of the pair hotkeys only looks a key up.
global _KeyCombinationScanNames := Map()
global _KeyCombinationKeysByScanName := Map()

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
	Taps := Map()
	Holds := Map()
	for _, Entry in ManifestFeaturesForSection(KEY_COMBINATION_TAP_SECTION) {
		if (Entry["default"] != KEY_COMBINATION_NONE)
			Taps[Entry["id"]] := Entry["default"]
	}
	for Section, Target in Map(KEY_COMBINATION_TAP_SECTION, Taps, KEY_COMBINATION_HOLD_SECTION, Holds) {
		if !(Cache is Map) || !Cache.Has(Section)
			continue
		for PairId, Value in Cache[Section] {
			if !(KeyCombinationParsePair(PairId) is Map) {
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
				LoggerWarn("KeyCombinations", "[{1}] '{2}' holds unknown value '{3}' — left empty.", Section, PairId, Value)
				if Target.Has(PairId)
					Target.Delete(PairId)
				continue
			}
			Target[PairId] := Value
		}
	}
	KeyCombinationTaps := Taps
	KeyCombinationHolds := Holds
	_KeyCombinationFirstKeys := _KeyCombinationIndexFirstKeys(Taps, Holds)
	LoggerInfo("KeyCombinations", "Key combinations read: {1} tap slot(s), {2} hold slot(s).", Taps.Count, Holds.Count)
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
	return Second != "" && KeyCombinationOwns(Second)
}

; The handler of the pair hotkeys: runs the pair of the key the hotkey names.
; @param HotkeyName {String} The hotkey that fired; A_ThisHotkey by default.
; @returns {String} As KeyCombinationFire.
KeyCombinationFireHotkey(HotkeyName := unset) {
	Second := KeyCombinationKeyOfHotkey(IsSet(HotkeyName) ? HotkeyName : A_ThisHotkey)
	return Second == "" ? "" : KeyCombinationFire(Second)
}

; The first key of the pair a press of Second completes: the first catalogue
; key physically down that Second has a slot under, or "".
; @param Second {String} Tap-hold key id of the key being pressed.
; @param IsDownFn {Func} Test seam taking a key id, the physical keys by default.
; @returns {String}
KeyCombinationHeldFirstKey(Second, IsDownFn := 0) {
	global _KeyCombinationFirstKeys
	if !IsSet(_KeyCombinationFirstKeys) || !_KeyCombinationFirstKeys.Has(Second)
		return ""
	if !IsObject(IsDownFn)
		IsDownFn := _KeyCombinationKeyIsDown
	for _, First in _KeyCombinationFirstKeys[Second] {
		; On a standard AltGr layout every AltGr press begins with a fake LCtrl,
		; which reads as LCtrl held first: that pair cannot be told from AltGr.
		if (First == "left_ctrl" && Second == "alt_gr" && KS_AltGrAddsFakeLCtrl())
			continue
		if IsDownFn.Call(First)
			return First
	}
	return ""
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
	; A key no pair ends on costs one lookup, on every press of that key.
	if !IsSet(_KeyCombinationFirstKeys) || !_KeyCombinationFirstKeys.Has(Second)
		return false
	if !IsSet(_KeyCombinationTaken) || !IsSet(_KeyCombinationHandled)
		return false
	if !IsObject(IsDownFn)
		IsDownFn := _KeyCombinationKeyIsDown
	if IsDownFn.Call(Second)
		return _KeyCombinationTaken.Has(Second)
	; A new press: the previous one, and the pair that took it, are over.
	if _KeyCombinationTaken.Has(Second)
		_KeyCombinationTaken.Delete(Second)
	if _KeyCombinationHandled.Has(Second)
		_KeyCombinationHandled.Delete(Second)
	if !KeyCombinationsAreOn()
		return false
	First := KeyCombinationHeldFirstKey(Second, IsDownFn)
	if (First == "")
		return false
	_KeyCombinationTaken[Second] := First
	return true
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
	First := _KeyCombinationTaken[Second]
	PairId := KeyCombinationPairId(First, Second)
	Tap := KeyCombinationTapOf(PairId)
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
	if (Hold == KEY_COMBINATION_NONE) {
		if (Tap == KEY_COMBINATION_NONE)
			return ""
		Ports["run_tap"].Call(First, Second, Tap)
		return "tap"
	}
	Seconds := TapHoldDuration(TapHold, Second)
	if _KeyCombinationHoldIsLayer(Hold) {
		Result := Ports["own_layer"].Call(Second, Seconds)
	} else {
		ModKey := ResolveHoldModifierKey(Hold, Second)
		if (ModKey == "") {
			LoggerError("KeyCombinations", "Pair '{1}' names a hold that resolves to no key: '{2}'.", PairId, Hold)
			return ""
		}
		Result := Ports["own_modifier"].Call(Second, ModKey, Seconds)
	}
	; The hold is taken at key-down, as every tap-hold of this driver takes
	; it; a release inside the second key's threshold makes the press a tap.
	if (Result["tap"] && Tap != KEY_COMBINATION_NONE) {
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
	PairActionFn := GestureInvokeAction.Bind(ActionId, KeyCombinationBindingId(KeyCombinationPairId(First, Second)))
	Held := _TH_OwnedModifiers.Has(First) ? _TH_SyntheticKeyList(_TH_OwnedModifiers[First]) : []
	return _KeyCombinationRunWithKeysUp(Held, 1, PairActionFn)
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
		{ Section: KEY_COMBINATION_HOLD_SECTION, Key: PairId, Delete: 1 }]
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
	Stored := TOML_ParseFreshFile(Path)
	if TOML_ReadFailed(Path)
		throw Error("Key combination configuration could not be read.")
	Parameters := []
	for Key in Stored.Get("action_parameters", Map()) {
		ParameterPath := "action_parameters." . Key
		if ConfigScopeActionParameterDomain(ParameterPath) == "combination"
			&& (KeyCombinationParsePair(StrSplit(Key, "__")[2]) is Map)
			Parameters.Push(ParameterPath)
	}
	Plan := ManifestScopePlan("key_combinations", Mode, Parameters,
		Map("action_parameter_domain", ConfigScopeActionParameterDomain))
	for Section in [KEY_COMBINATION_TAP_SECTION, KEY_COMBINATION_HOLD_SECTION] {
		for PairId in Stored.Get(Section, Map()) {
			if !(KeyCombinationParsePair(PairId) is Map)
				continue
			SlotPath := Section . "." . PairId
			if !(ManifestFindEntryByPath(SlotPath) is Map)
				Plan.operations.Push(ManifestConfigRow(SlotPath, , true))
		}
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
	ActionLabel := _KeyCombinationTapLabel(PairId)
	if KeyCombinationHoldOf(PairId) != KEY_COMBINATION_NONE
		ActionLabel := KeyCombinationTapOf(PairId) == KEY_COMBINATION_NONE
			? _KeyCombinationHoldLabel(PairId) : ActionLabel . " / " . _KeyCombinationHoldLabel(PairId)
	Label := PairLabel . " : " . ActionLabel
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
	Commands := Map("key_combination_clear", (*) => ClearKeyCombination(PairId))
	ListProviders := Map("key_combination_slots", () => KeyCombinationSlotRows(PairId, PairLabel))
	global KEY_COMBINATION_NONE
	Getters := Map("key_combination_pair_assigned", () => KeyCombinationTapOf(PairId) != KEY_COMBINATION_NONE
		or KeyCombinationHoldOf(PairId) != KEY_COMBINATION_NONE)
	PairMenu := MenuRenderer_Build("key_combination_pair_menu", "Shortcuts", "", "", ListProviders, Commands, Getters)
	if HasMethod(ShowFn, "Call")
		return ShowFn.Call(PairMenu)
	PairMenu.Show()
}

; The list provider of the manifest's "key_combination_slots" entry: the tap
; slot, which opens the shared action picker, and the hold slot, which lists
; the shared hold options.
; @param PairId {String} A pair id.
; @param PairLabel {String} « First + Second », the title of the action picker.
; @returns {Array} Two rows.
KeyCombinationSlotRows(PairId, PairLabel) {
	TapRow := Map("action", (*) => ShowActionPicker(PairLabel, KeyCombinationTapOf(PairId),
		(ActionName) => SetKeyCombinationTap(PairId, ActionName), false, KeyCombinationBindingId(PairId)))
	TapRow["label"] := StrReplace(t("menu.shortcuts.key_combinations_hold_tap"), "%s", _KeyCombinationTapLabel(PairId))
	HoldRow := Map("items", KeyCombinationHoldPickerRows(PairId))
	HoldRow["label"] := StrReplace(t("menu.shortcuts.key_combinations_hold_hold"), "%s", _KeyCombinationHoldLabel(PairId))
	return [TapRow, HoldRow]
}

; The rows of a pair's hold picker: every option of the shared hold picker,
; the current one ticked.
; @param PairId {String} A pair id.
; @returns {Array} Rows of Map("label", ..., "checked", ..., "action", ...).
KeyCombinationHoldPickerRows(PairId) {
	global KEY_COMBINATION_NONE
	Current := KeyCombinationHoldOf(PairId)
	Rows := []
	for _, Option in TapHoldHoldOptions()
		Rows.Push(_KeyCombinationHoldOptionRow(PairId, Option, Current))
	return Rows
}

; One row of the hold picker; its own function so its click keeps its option.
_KeyCombinationHoldOptionRow(PairId, Option, Current) {
	global KEY_COMBINATION_NONE
	HoldId := (Option["kind"] == "none") ? KEY_COMBINATION_NONE : Option["id"]
	Label := (Option["i18n"] != "") ? t(Option["i18n"]) : _TH_HoldOptionLabel(Option["id"])
	return Map("label", Label, "checked", HoldId == Current,
		"action", (*) => SetKeyCombinationHold(PairId, HoldId))
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
