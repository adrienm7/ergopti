; infra/magic_editor.ahk

; ==============================================================================
; MODULE: Physical Magic Editor Shortcut
; DESCRIPTION:
; Windows probes acknowledged plain physical evidence for the shared policy.
; Native brokers acquire one Win chord per physical source and preserve existing
; remap, ordinary assignment and legacy shortcut owners behind that one variant.
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ Physical evidence =======
; ====================================
; ====================================

/** Reads the actual physical registry once, including non-typing key positions. */
MagicEditorPhysicalCatalogue(SharedRoot := unset) {
	global _SharedDir
	static Catalogues := Map()
	Root := IsSet(SharedRoot) ? SharedRoot : _SharedDir
	if !(Root is String) || Root == ""
		throw TypeError("The physical registry requires its actual shared source root.")
	if Catalogues.Has(Root)
		return Catalogues[Root]
	Registry := JsonParse(FSReadStrict(Root . "\data\keycodes\physical_keys.json"))
	if !(Registry is Map) || !(Registry.Get("keys", 0) is Map)
		throw TypeError("The physical magic editor requires the actual key registry.")
	Keys := []
	for Code, Key in Registry["keys"] {
		if Key["kind"] != "key"
			continue
		Scan := Key["ahk"]
		if !RegExMatch(Scan, "i)^SC([0-9a-f]{3})$")
			throw ValueError("The physical key registry contains an invalid Windows identity.")
		Keys.Push(Map("code", Code, "ahk", Scan))
	}
	Catalogues[Root] := Map("keys", Keys)
	return Catalogues[Root]
}

/**
 * Probes all catalogued keys through native or acknowledged effective tap owners.
 * @param {Integer} Hkl Exact foreground keyboard layout, zero when unavailable.
 * @param {String} Trigger Actual trigger, never the historical source character.
 * @param {Integer} Generation Current physical-source owner epoch.
 * @param {Map} Keycodes Actual layout keycode registry, injected in native tests.
 * @param {Func|Integer} TextFn Neutral native probe, optional test seam.
 * @param {Func|Integer} EffectiveFn Effective tap owner projection (Code, Scan, Native).
 * @returns {Map} Detached native evidence for MagicEditorSelectSource.
 */
MagicEditorProbeSource(Hkl, Trigger, Generation, Keycodes := unset, TextFn := 0, EffectiveFn := 0) {
	if !_MagicEditorGeneration(Generation) || !(Hkl is Integer) || !(Trigger is String) || Trigger == ""
		throw TypeError("Magic editor native probing requires exact source inputs.")
	if !IsSet(Keycodes)
		Keycodes := MagicEditorPhysicalCatalogue()
	if !(Keycodes is Map) || !(Keycodes.Get("keys", 0) is Array)
		throw TypeError("Magic editor native probing requires the physical registry.")
	Receipt := Map("generation", Generation, "status", Hkl ? "ready" : "unavailable",
		"candidates", [], "hkl", Hkl)
	if !Hkl
		return Receipt
	Probe := HasMethod(TextFn, "Call") ? TextFn : _MagicEditorNativeText
	for Key in Keycodes["keys"] {
		Scan := Key["ahk"]
		if !RegExMatch(Scan, "i)^SC([0-9a-f]{3})$", &Match)
			throw ValueError("The physical registry contains an invalid native scan.")
		NativeCode := Integer("0x" . Match[1])
		Output := Probe.Call(NativeCode, Hkl)
		if HasMethod(EffectiveFn, "Call")
			Output := EffectiveFn.Call(Key["code"], Scan, Output)
		if !IsObject(Output) || !Output.HasOwnProp("Count") || !Output.HasOwnProp("Text")
			throw TypeError("The physical source owner returned invalid tap evidence.")
		if Output.Count == 0
			continue
		Receipt["candidates"].Push(Map("code", Key["code"], "native_code", NativeCode,
			"identity", _MagicEditorScanIdentity(NativeCode), "text", Output.Text,
			"direct", Output.Count > 0, "dead", Output.Count < 0))
	}
	return Receipt
}

/** Reads neutral Win32 output without touching Shift, CapsLock or dead state. */
_MagicEditorNativeText(Scan, Hkl) {
	return KS_KeyTextNoStateChange(KS_ScancodeToVk(Scan, Hkl), Scan, Hkl, false, false)
}

/** Returns one canonical physical Win-chord identity, independent of its VK. */
_MagicEditorScanIdentity(Scan) {
	return "win:" . Format("SC{:03X}", Scan)
}





; ====================================
; ====================================
; ======= 2/ Native Win broker =======
; ====================================
; ====================================

/** Returns the sole broker lifecycle owner, initialized by the boot cohort. */
MagicEditorState() {
	static State := Map("initialized", false, "layouts", Map(), "legacy", Map(),
		"ordinary_handles", Map(), "ordinary_physical", Map(), "native_handles", Map(), "configuration_generation", 0,
		"source_generation", 0, "source_signature", "", "hkl", 0, "decision", 0, "ordinary_claim", 0)
	return State
}

/** Retains the exact ordinary registrar handle for an acknowledged collision handoff. */
MagicEditorRecordOrdinaryHandle(Slot, Handle) {
	State := MagicEditorState()
	if State["initialized"]
		throw Error("Ordinary keyboard registration cannot mutate an initialized Win broker.")
	if SubStr(Slot, 1, 4) == "win_" && Handle != ""
		State["ordinary_handles"][Slot] := Handle
}

/**
 * Registers a layout fallback with the broker before native acquisition.
 * A later write of the same context replaces its callback, matching AHK's exact
 * variant semantics; distinct contexts retain their established ordering.
 * @param {String} Scan Physical registry SC identity.
 * @param {Func} Callback Existing native layout owner callback.
 * @param {Func|Integer} Criterion Existing layout admission predicate, zero if global.
 */
MagicEditorRecordLayoutFallback(Scan, Callback, Criterion := 0, Keycodes := unset) {
	State := MagicEditorState()
	if State["initialized"] || !HasMethod(Callback, "Call")
		throw Error("A layout fallback requires an unstarted Win broker and its actual callback.")
	Scan := MagicEditorNormalizeScan(Scan, IsSet(Keycodes) ? Keycodes : MagicEditorPhysicalCatalogue())
	if !State["layouts"].Has(Scan)
		State["layouts"][Scan] := []
	for Existing in State["layouts"][Scan] {
		if Existing["criterion"] == Criterion {
			Existing["callback"] := Callback
			return
		}
	}
	State["layouts"][Scan].Push(Map("callback", Callback, "criterion", Criterion))
}

/** Normalizes native scan aliases before one physical owner is indexed. */
MagicEditorNormalizeScan(Scan, Keycodes := unset) {
	if !(Scan is String) || !RegExMatch(Scan, "i)^SC([0-9a-f]{1,3})$", &Match)
		throw ValueError("A physical shortcut requires an actual native scan identity.")
	Numeric := Integer("0x" . Match[1])
	if Numeric <= 0 || Numeric > 0x1FF
		throw ValueError("A physical shortcut scan is outside the native identity range.")
	Canonical := Format("SC{:03X}", Numeric)
	if IsSet(Keycodes) {
		for Key in Keycodes["keys"] {
			if StrUpper(Key["ahk"]) == Canonical
				return Canonical
		}
		throw ValueError("The physical shortcut scan is not present in the actual key registry.")
	}
	return Canonical
}

/**
 * Joins a previously supported explicit SC slot without a competing native owner.
 * @param {String} Slot Existing ordinary win_scNNN identity.
 * @param {String} Action Validated ordinary action, without inventing assignments.
 * @param {Map} Keycodes Actual physical catalogue, optional fixture root seam.
 * @returns {Boolean} Whether this exact existing slot is physical.
 */
MagicEditorRecordOrdinaryPhysical(Slot, Action, Keycodes := unset) {
	if !RegExMatch(Slot, "i)^win_(SC[0-9a-f]{3})$", &Match)
		return false
	State := MagicEditorState(), Scan := MagicEditorNormalizeScan(Match[1]), Known := false
	Catalogue := IsSet(Keycodes) ? Keycodes : MagicEditorPhysicalCatalogue()
	for Key in Catalogue["keys"] {
		if StrUpper(Key["ahk"]) == Scan {
			Known := true
			break
		}
	}
	if !Known || State["initialized"]
		throw ValueError("An existing physical Win assignment must name an actual unacquired key.")
	State["ordinary_physical"][Scan] := Map("slot", Slot, "action", Action)
	return true
}

/** Retains an effective legacy feature's Win callback without a parallel variant. */
MagicEditorRecordLegacy(Scan, Callback, Keycodes := unset) {
	State := MagicEditorState()
	if State["initialized"] || !HasMethod(Callback, "Call")
		throw Error("A legacy Win shortcut requires an unstarted broker and its actual callback.")
	State["legacy"][MagicEditorNormalizeScan(Scan, IsSet(Keycodes) ? Keycodes : MagicEditorPhysicalCatalogue())] := Callback
	return true
}

/** Invalidates queued contextual delivery after an acknowledged ordinary write. */
MagicEditorConfigurationChanged() {
	State := MagicEditorState()
	State["configuration_generation"] += 1
}

/** Returns current admission, including the actual suppressive-input owners. */
_MagicEditorAdmission() {
	global LayerEnabled
	return Map("master", IsCategoryGated("Shortcuts") ? true : false,
		"paused", A_IsSuspended ? true : false,
		"inhibited", (SIHO_HasActive() || (IsSet(LayerEnabled) && LayerEnabled) || !_EmitReachedScreen()) ? true : false)
}

/** Reads plain effective output without advancing the registry dead-key machine. */
_MagicEditorEffectivePlain(Code, Scan, Native) {
	global Features, ScriptInformation, KLE_Model, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE, TapHold
	Numeric := Integer("0x" . SubStr(Scan, 3))
	TapId := TapHoldResolveKeyIdFromVkSc(0, Numeric)
	if TapId != "" && TapHoldIsActive(TapHold, TapId)
		return { Count: 0, Text: "" }
	if Features["hotstrings"]["magic_key"]["replace"]["enabled"]
			&& StrUpper(Scan) == StrUpper(ScriptInformation["MagicKeySourceScan"])
		return { Count: StrLen(ScriptInformation["MagicKey"]), Text: ScriptInformation["MagicKey"] }
	if NumberRowEffectiveMode() == "digits" {
		if Numeric >= 0x02 && Numeric <= 0x0B
			return { Count: 1, Text: Numeric == 0x0B ? "0" : String(Numeric - 1) }
		Edges := ErgoptiNumberRowEdgeMapping()
		if Edges.Has(Numeric)
			return { Count: StrLen(Edges[Numeric]), Text: Edges[Numeric] }
	}
	if _KLE_BaseCriterion(Scan, false) && KLE_KeyCodes.Has(Scan) {
		Shift := false
		if NumberRowEffectiveMode() == "symbols" && NumberRowSymbolsCapable(false) {
			Level := NumberRowSymbolsLevel(Numeric, false)
			if Level["supported"]
				Shift := Level["shift"]
		}
		Step := Keylayout_Step(KLE_Model, KEYLAYOUT_NEUTRAL_STATE,
			KLE_LevelIndex[_KLE_ComboKey(Shift, false, false)], KLE_KeyCodes[Scan])
		return { Count: Step["Next"] != "" && Step["Next"] != KEYLAYOUT_NEUTRAL_STATE ? -1 : StrLen(Step["Output"]),
			Text: Step["Output"] }
	}
	if Features["layout"]["ergopti_base"] {
		if ErgoptiBaseDeadKeys().Has(Scan)
			return { Count: -1, Text: ErgoptiBaseDeadKeys()[Scan]["chain"] }
		Base := ErgoptiBaseMapping()
		if Base.Has(Numeric) {
			Entry := Base[Numeric]
			Text := (Entry is String) ? Entry : (Entry.HasOwnProp("alt") && Entry.alt != "" ? Entry.alt : Entry.c)
			return { Count: StrLen(Text), Text: Text }
		}
	}
	return Native
}

/** Builds actual current source evidence, honoring an effective explicit source owner. */
_MagicEditorCurrentSource(Generation, Keycodes, Hkl) {
	global Features, ScriptInformation
	Source := MagicEditorProbeSource(Hkl, ScriptInformation["MagicKey"], Generation, Keycodes,
		0, _MagicEditorEffectivePlain)
	if ScriptInformation["MagicKeySourceChosen"] && Features["hotstrings"]["magic_key"]["replace"]["enabled"] {
		Chosen := StrUpper(ScriptInformation["MagicKeySourceScan"])
		Owned := []
		for Candidate in Source["candidates"] {
			if Format("SC{:03X}", Candidate["native_code"]) == Chosen
				Owned.Push(Candidate)
		}
		Source["candidates"] := Owned
	}
	return Source
}

/** Resolves only present ordinary Win settings against one exact native source. */
_MagicEditorExplicitClaim(Source, Hkl) {
	global _IniCache, KeyboardShortcutAssignments
	if !(Source is Map) || !IsSet(_IniCache) || !_IniCache.Has("shortcuts.keyboard")
		return 0
	Resolver := HotkeyRegistrarNativeKeyResolverSnapshot(Map("get_layout", (*) => Hkl))
	if !HasMethod(Resolver, "Call")
		throw Error("The ordinary Win source identity could not be resolved.")
	SourceVk := KS_ScancodeToVk(Source["native_code"], Hkl)
	Selected := 0, Slots := []
	for Slot in _IniCache["shortcuts.keyboard"] {
		if SubStr(Slot, 1, 4) != "win_" || !KeyboardShortcutAssignments.Has(Slot)
			continue
		Chord := ChordParse(_KeyboardSlotChord(Slot))
		if !Chord["ok"]
			continue
		Key := Resolver.Call(Chord["key"])
		if !(Key is Map) || Key["implicit_modifiers"] != ""
			continue
		if !((Key["axis"] == "vk" && Key["code"] == SourceVk)
				|| (Key["axis"] == "sc" && Key["code"] == Source["native_code"]))
			continue
		Slots.Push(Slot)
		; A native SC owner has priority over a VK alias, exactly as AHK does.
		if !(Selected is Map) || Key["axis"] == "sc"
			Selected := Map("slot", Slot, "action", KeyboardShortcutAssignments[Slot], "axis", Key["axis"])
	}
	if Selected is Map
		Selected["slots"] := Slots
	return Selected
}

/** Captures the actual immutable recipe that proved this physical source. */
_MagicEditorSourceSignature() {
	global Features, ScriptInformation, KLE_Id
	Layout := Features["layout"]
	return ScriptInformation["MagicKey"] . "|" . ScriptInformation["MagicKeySourceScan"]
		. "|" . ScriptInformation["MagicKeySourceChosen"] . "|" . ScriptInformation["MagicKeySourceOverridesEmulation"]
		. "|" . Features["hotstrings"]["magic_key"]["replace"]["enabled"]
		. "|" . Layout["ergopti_base"] . "|" . Layout["direct_access_digits"]
		. "|" . Layout["emulated_layout"] . "|" . KLE_Id
}

/** Rejects source changes and an actual tap-hold owner before stale delivery. */
_MagicEditorSourceIsCurrent() {
	global TapHold
	State := MagicEditorState()
	if KS_ResolveKeyboardLayout() != State["hkl"] || _MagicEditorSourceSignature() !== State["source_signature"]
		return false
	Decision := State["decision"]
	if (Decision is Map) && (Decision["source"] is Map) {
		KeyId := TapHoldResolveKeyIdFromVkSc(0, Decision["source"]["native_code"])
		if KeyId != "" && TapHoldIsActive(TapHold, KeyId)
			return false
	}
	return true
}

/** Returns live delivery gates with the exact source and configuration epochs. */
_MagicEditorDeliveryState() {
	global KeyboardShortcutAssignments
	State := MagicEditorState()
	Admission := _MagicEditorAdmission()
	Admission["source_generation"] := _MagicEditorSourceIsCurrent() ? State["source_generation"] : -1
	Admission["configuration_generation"] := State["configuration_generation"]
	Admission["action"] := KeyboardShortcutAssignments.Get(MagicEditorSlot()["id"], "none")
	return Admission
}

/** Selects the live callback owner without running it from a native criterion. */
_MagicEditorBrokerWinner(Scan) {
	global KeyboardShortcutAssignments
	State := MagicEditorState()
	if !State["initialized"] || A_IsSuspended
		return 0
	Admission := _MagicEditorAdmission()
	if Admission["master"] && !Admission["inhibited"] && State["ordinary_physical"].Has(Scan) {
		Physical := State["ordinary_physical"][Scan]
		if KeyboardShortcutAssignments.Get(Physical["slot"], "none") != "none"
			return Map("kind", "ordinary", "slot", Physical["slot"])
	}
	Decision := State["decision"]
	SourceScan := (Decision is Map) && (Decision["source"] is Map)
		? Format("SC{:03X}", Decision["source"]["native_code"]) : ""
	if Scan == SourceScan && Admission["master"] && !Admission["inhibited"]
			&& _MagicEditorSourceIsCurrent() {
		Claim := State["ordinary_claim"]
		if (Claim is Map) && KeyboardShortcutAssignments.Get(Claim["slot"], "none") != "none"
			return Map("kind", "ordinary", "slot", Claim["slot"])
	}
	if Admission["master"] && !Admission["inhibited"] && State["legacy"].Has(Scan)
		return Map("kind", "legacy", "callback", State["legacy"][Scan])
	if Scan == SourceScan && MagicEditorCanDeliver(Decision, _MagicEditorDeliveryState())
		return Map("kind", "contextual", "decision", Decision)
	for Fallback in State["layouts"].Get(Scan, []) {
		if !HasMethod(Fallback["criterion"], "Call") || Fallback["criterion"].Call()
			return Map("kind", "layout", "callback", Fallback["callback"])
	}
	return 0
}

/** Native admission consumes input only while one live owner needs this variant. */
_MagicEditorBrokerCriterion(Scan, ConfigurationGeneration, SourceGeneration, *) {
	State := MagicEditorState()
	if State["configuration_generation"] != ConfigurationGeneration || State["source_generation"] != SourceGeneration
		return false
	return _MagicEditorBrokerWinner(Scan) is Map
}

/** Dispatches once through the same live arbitration used by the criterion. */
_MagicEditorBrokerDispatch(Scan, ConfigurationGeneration, SourceGeneration, *) {
	State := MagicEditorState()
	if State["configuration_generation"] != ConfigurationGeneration || State["source_generation"] != SourceGeneration
		return
	Winner := _MagicEditorBrokerWinner(Scan)
	if !(Winner is Map)
		return
	switch Winner["kind"] {
		case "ordinary": RunKeyboardShortcutAction(Winner["slot"])
		case "contextual":
			if MagicEditorCanDeliver(Winner["decision"], _MagicEditorDeliveryState())
				RunKeyboardShortcutAction(MagicEditorSlot()["id"])
		default: Winner["callback"].Call()
	}
}

/**
 * Acquires the complete native Win cohort after every existing producer joins it.
 * Source/ordinary handoff is backup-free because it transfers only native handles;
 * ordinary settings remain under their existing lease and WAL persistence owner.
 * @returns {Integer} Number of owned physical Win variants.
 */
MagicEditorStart() {
	global ScriptInformation, KeyboardShortcutAssignments, GESTURE_ACTIONS
	State := MagicEditorState()
	if State["initialized"]
		throw Error("The physical Win broker is already initialized.")
	LoggerStart("MagicEditor", "Acquiring the shared physical shortcut cohort…")
	State["hkl"] := KS_ResolveKeyboardLayout()
	State["source_generation"] += 1
	State["source_signature"] := _MagicEditorSourceSignature()
	Keycodes := MagicEditorPhysicalCatalogue(), Known := Map()
	for Key in Keycodes["keys"]
		Known[Key["code"]] := true
	Source := _MagicEditorCurrentSource(State["source_generation"], Keycodes, State["hkl"])
	Selected := MagicEditorSelectSource(Source, ScriptInformation["MagicKey"], Known)
	State["ordinary_claim"] := _MagicEditorExplicitClaim(Selected["source"], State["hkl"])
	Claims := Map()
	if Selected["source"] is Map {
		Identity := Selected["source"]["identity"]
		Scan := Format("SC{:03X}", Selected["source"]["native_code"])
		if State["ordinary_claim"] is Map
			Claims[Identity] := State["ordinary_claim"]
		else if State["legacy"].Has(Scan)
			Claims[Identity] := Map("legacy", true)
	}
	Slot := MagicEditorSlot()
	State["decision"] := MagicEditorResolve(Map("default_action", ManifestDefaultFor(Slot["path"]),
		"stored_action", KeyboardShortcutAssignments.Get(Slot["id"], ManifestDefaultFor(Slot["path"])),
		"is_action", (Id) => GESTURE_ACTIONS.Has(Id), "source", Source,
		"trigger", ScriptInformation["MagicKey"], "known_codes", Known, "explicit_claims", Claims,
		"configuration_generation", State["configuration_generation"], "admission", _MagicEditorAdmission()))
	Scans := Map()
	for Scan in State["layouts"]
		Scans[Scan] := true
	for Scan in State["legacy"]
		Scans[Scan] := true
	for Scan, Assignment in State["ordinary_physical"] {
		if Assignment["action"] != "none"
			Scans[Scan] := true
	}
	if Selected["source"] is Map
		Scans[Format("SC{:03X}", Selected["source"]["native_code"])] := true
	OrdinaryHandles := []
	Claim := State["ordinary_claim"]
	if Claim is Map {
		for SlotId in Claim["slots"] {
			if State["ordinary_handles"].Has(SlotId)
				OrdinaryHandles.Push(State["ordinary_handles"][SlotId])
		}
	}
	MagicEditorAcquireCohort(Scans, OrdinaryHandles, State["native_handles"], Map(
		"reserve", (Scan) => HotkeyRegistrarReservePhysicalBroker("Cmd+" . Scan,
			_MagicEditorBrokerDispatch.Bind(Scan, State["configuration_generation"], State["source_generation"]),
			"keyboard-win-broker", HotkeyRegistrarResolvedNativeDescriptor("#" . Scan),
			_MagicEditorBrokerCriterion.Bind(Scan, State["configuration_generation"], State["source_generation"])),
		"activate", _HotkeyRegistrarActivate, "retire", HotkeyRegistrarUnbind,
		"set_enabled", HotkeyRegistrarSetEnabled))
	; Every native On is acknowledged while admission is still false. Publish
	; authority once, only after the full cohort and the personal handoff exist.
	State["initialized"] := true
	LoggerSuccess("MagicEditor", "Physical shortcut cohort acquired ({1} variant(s), contextual action: {2}).",
		State["native_handles"].Count, State["decision"]["action"])
	return State["native_handles"].Count
}

/**
 * Acquires a cohort while its caller keeps every admission criterion inactive.
 * @param {Map} Scans Physical keys requiring a single broker owner.
 * @param {Array} OrdinaryHandles Existing personal aliases to suspend reversibly.
 * @param {Map} Handles Exact acknowledged handles, including any retirement debt.
 * @param {Map} Ports Registrar reserve, activate, retire and set_enabled owners.
 * @returns {Boolean} True only after every native acquisition is acknowledged.
 */
MagicEditorAcquireCohort(Scans, OrdinaryHandles, Handles, Ports) {
	for Name in ["reserve", "activate", "retire", "set_enabled"] {
		if !Ports.Has(Name) || !HasMethod(Ports[Name], "Call")
			throw TypeError("The physical broker requires its exact registrar ports.")
	}
	Disabled := []
	try {
		for Scan in Scans {
			Handle := Ports["reserve"].Call(Scan)
			if !(Handle is String) || Handle == ""
				throw Error("The physical Win broker refused native acquisition: " . Scan)
			Handles[Scan] := Handle
		}
		for Handle in OrdinaryHandles {
			if !Ports["set_enabled"].Call(Handle, false)
				throw Error("The ordinary Win owner refused its physical broker handoff.")
			Disabled.Push(Handle)
		}
		for Scan, Handle in Handles {
			if !Ports["activate"].Call(Handle)
				throw Error("The physical Win broker refused native activation: " . Scan)
		}
	} catch as Err {
		Debt := []
		Retired := []
		for Scan, Handle in Handles {
			try {
				if Ports["retire"].Call(Handle)
					Retired.Push(Scan)
				else
					Debt.Push("retire " . Scan)
			} catch as Refusal {
				Debt.Push("retire " . Scan . ": " . Refusal.Message)
			}
		}
		for Scan in Retired
			Handles.Delete(Scan)
		for Handle in Disabled {
			try {
				if !Ports["set_enabled"].Call(Handle, true)
					Debt.Push("restore " . Handle)
			} catch as Refusal {
				Debt.Push("restore " . Handle . ": " . Refusal.Message)
			}
		}
		if Debt.Length {
			Detail := ""
			for Item in Debt
				Detail .= (Detail == "" ? "" : "; ") . Item
			throw Error(Err.Message . " Unacknowledged compensation: " . Detail)
		}
		throw Err
	}
	return true
}

/** Reloads the physical cohort on an actual native input-source switch. */
MagicEditorNeedsLayoutReload(Hkl) {
	State := MagicEditorState()
	return State["initialized"] && Hkl != State["hkl"]
}

/** Returns a translated editable slot label with its actual physical chord. */
MagicEditorSlotLabel() {
	Decision := MagicEditorState()["decision"]
	Label := t("menu.shortcuts.keyboard.magic_editor")
	if (Decision is Map) && (Decision["source"] is Map)
		Label .= " (Win + " . Decision["source"]["text"] . ")"
	return Label
}

/** Draws the ordinary action picker even when its native chord is unavailable. */
MagicEditorSlotRows() {
	global KeyboardShortcutAssignments, GESTURE_ACTIONS
	Slot := MagicEditorSlot()
	Action := KeyboardShortcutAssignments.Get(Slot["id"], ManifestDefaultFor(Slot["path"]))
	Label := MagicEditorSlotLabel() . " : " . (GESTURE_ACTIONS.Has(Action)
		? GestureActionDisplayLabel(Action, Slot["binding_id"]) : t("dialog.action_picker.disabled"))
	Decision := MagicEditorState()["decision"]
	if (Decision is Map) && Decision["reason"] != ""
		Label .= " — " . t("menu.shortcuts.keyboard.magic_editor_reason." . Decision["reason"])
	return [Map("label", Label, "action", (*) => ShowKeyboardShortcutPicker(Slot["id"]))]
}
