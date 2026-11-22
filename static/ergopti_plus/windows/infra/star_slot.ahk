; infra/star_slot.ahk

; ==============================================================================
; MODULE: The ★ Key's Win Slot and the Physical Win Broker
; DESCRIPTION:
; Windows probes acknowledged plain physical evidence for the shared ★ key
; slot (_shared/shortcuts/data/star_slot.ahk): Win+★ (meta_star) on the key
; that types the real ★ at its base level, whose default opens the hotstrings
; editor (maintainer's decision of 2026-11-21). The native broker acquires one
; Win chord per physical key and preserves existing remap, ordinary assignment
; and legacy shortcut owners behind that one variant.
; ==============================================================================

#Include %A_LineFile%\..\..\_generated\config_keys.ahk
#Include %A_LineFile%\..\..\ai\engine\action_gate.ahk





; ====================================
; ====================================
; ======= 1/ Physical evidence =======
; ====================================
; ====================================

/** Reads the actual physical registry once, including non-typing key positions. */
StarSlotPhysicalCatalogue(SharedRoot := unset) {
	global _SharedDir
	static Catalogues := Map()
	Root := IsSet(SharedRoot) ? SharedRoot : _SharedDir
	if !(Root is String) || Root == ""
		throw TypeError("The physical registry requires its actual shared source root.")
	if Catalogues.Has(Root)
		return Catalogues[Root]
	RegistryPath := Root . "\layouts\data\keycodes\physical_keys.json"
	Registry := JsonParseShared(RegistryPath, FSReadStrict(RegistryPath))
	if !(Registry is Map) || !(Registry.Get("keys", 0) is Map)
		throw TypeError("The ★ key slot requires the actual key registry.")
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
 * @param {Integer} Generation Current physical-source owner epoch.
 * @param {Map} Keycodes Actual layout keycode registry, injected in native tests.
 * @param {Func|Integer} TextFn Neutral native probe, optional test seam.
 * @param {Func|Integer} EffectiveFn Effective tap owner projection (Code, Scan, Native).
 * @returns {Map} Detached native evidence for StarSlotSelectSource.
 */
StarSlotProbeSource(Hkl, Generation, Keycodes := unset, TextFn := 0, EffectiveFn := 0) {
	if !_StarSlotGeneration(Generation) || !(Hkl is Integer)
		throw TypeError("The ★ key slot's native probing requires exact source inputs.")
	if !IsSet(Keycodes)
		Keycodes := StarSlotPhysicalCatalogue()
	if !(Keycodes is Map) || !(Keycodes.Get("keys", 0) is Array)
		throw TypeError("The ★ key slot's native probing requires the physical registry.")
	Receipt := Map("generation", Generation, "status", Hkl ? "ready" : "unavailable",
		"candidates", [], "hkl", Hkl)
	if !Hkl
		return Receipt
	Probe := HasMethod(TextFn, "Call") ? TextFn : _StarSlotNativeText
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
			"identity", _StarSlotScanIdentity(NativeCode), "text", Output.Text,
			"direct", Output.Count > 0, "dead", Output.Count < 0))
	}
	return Receipt
}

/** Reads neutral Win32 output without touching Shift, CapsLock or dead state. */
_StarSlotNativeText(Scan, Hkl) {
	return KS_KeyTextNoStateChange(KS_ScancodeToVk(Scan, Hkl), Scan, Hkl, false, false)
}

/** Returns one canonical physical Win-chord identity, independent of its VK. */
_StarSlotScanIdentity(Scan) {
	return "win:" . Format("SC{:03X}", Scan)
}





; ====================================
; ====================================
; ======= 2/ Native Win broker =======
; ====================================
; ====================================

/** Returns the sole broker lifecycle owner, initialized by the boot cohort. */
StarSlotState() {
	static State := Map("initialized", false, "layouts", Map(), "legacy", Map(),
		"ordinary_handles", Map(), "ordinary_physical", Map(), "native_handles", Map(), "ordinary_restore", Map(), "configuration_generation", 0,
		"source_generation", 0, "source_signature", "", "hkl", 0, "decision", 0, "ordinary_claim", 0)
	return State
}

/** Retains the exact ordinary registrar handle for an acknowledged collision handoff. */
StarSlotRecordOrdinaryHandle(Slot, Handle) {
	State := StarSlotState()
	if State["initialized"]
		throw Error("Ordinary keyboard registration cannot mutate an initialized Win broker.")
	if SubStr(Slot, 1, 5) == "meta_" && Handle != ""
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
StarSlotRecordLayoutFallback(Scan, Callback, Criterion := 0, Keycodes := unset) {
	State := StarSlotState()
	if State["initialized"] || !HasMethod(Callback, "Call")
		throw Error("A layout fallback requires an unstarted Win broker and its actual callback.")
	Scan := StarSlotNormalizeScan(Scan, IsSet(Keycodes) ? Keycodes : StarSlotPhysicalCatalogue())
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
StarSlotNormalizeScan(Scan, Keycodes := unset) {
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
 * @param {String} Slot Existing ordinary meta_scNNN identity.
 * @param {String} Action Validated ordinary action, without inventing assignments.
 * @param {Map} Keycodes Actual physical catalogue, optional fixture root seam.
 * @returns {Boolean} Whether this exact existing slot is physical.
 */
StarSlotRecordOrdinaryPhysical(Slot, Action, Keycodes := unset) {
	if !RegExMatch(Slot, "i)^meta_(SC[0-9a-f]{3})$", &Match)
		return false
	State := StarSlotState(), Scan := StarSlotNormalizeScan(Match[1]), Known := false
	Catalogue := IsSet(Keycodes) ? Keycodes : StarSlotPhysicalCatalogue()
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

/**
 * Joins an ordinary Win slot whose letter lives on a key the layout owner decides,
 * so the slot shares that key's one Win variant with its remap.
 * @param {String} Scan Canonical physical scan.
 * @param {String} Slot The ordinary slot.
 * @param {String} Action Its validated action.
 * @param {Map} Keycodes Actual physical catalogue, optional fixture root seam.
 */
StarSlotRecordOrdinaryScan(Scan, Slot, Action, Keycodes := unset) {
	State := StarSlotState()
	if State["initialized"]
		throw Error("An ordinary Win slot requires an unstarted broker.")
	Canonical := StarSlotNormalizeScan(Scan, IsSet(Keycodes) ? Keycodes : StarSlotPhysicalCatalogue())
	; Two slots can name one key (Win+4 and Win+' on AZERTY); only one can answer.
	if State["ordinary_physical"].Has(Canonical)
		LoggerWarn("StarSlot", "Win slot '{1}' replaces '{2}' on the key {3}: both name the same key.",
			Slot, State["ordinary_physical"][Canonical]["slot"], Canonical)
	State["ordinary_physical"][Canonical] := Map("slot", Slot, "action", Action)
}

/** Retains an effective legacy feature's Win callback without a parallel variant. */
StarSlotRecordLegacy(Scan, Callback, Keycodes := unset) {
	State := StarSlotState()
	if State["initialized"] || !HasMethod(Callback, "Call")
		throw Error("A legacy Win shortcut requires an unstarted broker and its actual callback.")
	State["legacy"][StarSlotNormalizeScan(Scan, IsSet(Keycodes) ? Keycodes : StarSlotPhysicalCatalogue())] := Callback
	return true
}

/** Invalidates queued contextual delivery after an acknowledged ordinary write. */
StarSlotConfigurationChanged() {
	State := StarSlotState()
	State["configuration_generation"] += 1
}

/** Returns current admission, including the actual suppressive-input owners. */
_StarSlotAdmission() {
	global LayerEnabled
	return Map("master", IsCategoryGated("Shortcuts") ? true : false,
		"paused", A_IsSuspended ? true : false,
		"inhibited", (SIHO_HasActive() || (IsSet(LayerEnabled) && LayerEnabled) || !_EmitReachedScreen()) ? true : false)
}

/**
 * Reads plain effective output without advancing the registry dead-key machine.
 * @param {Map} Probe - One probe's memo: the number-row mode and the Ergopti base
 *   tables do not change between the keys of a probe, so each is read once, when
 *   a key first needs it, instead of once per catalogue key.
 */
_StarSlotEffectivePlain(Probe, Code, Scan, Native) {
	global Features, KLE_Model, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE, TapHold
	Numeric := Integer("0x" . SubStr(Scan, 3))
	TapId := TapHoldResolveKeyIdFromVkSc(0, Numeric)
	if TapId != "" && TapHoldIsActive(TapHold, TapId)
		return { Count: 0, Text: "" }
	; « Also reorder the three edge keys » types the other level.
	Edge := NumberRowEdgeText(Numeric, false, NumberRowForegroundLayout(), false)
	if Edge != ""
		return { Count: StrLen(Edge), Text: Edge }
	if !Probe.Has("effective_number_row")
		Probe["effective_number_row"] := NumberRowEffectiveMode()
	if Probe["effective_number_row"] == "digits" {
		if Numeric >= 0x02 && Numeric <= 0x0B
			return { Count: 1, Text: Numeric == 0x0B ? "0" : String(Numeric - 1) }
	} else if !KeylayoutEmulation_LayerIsActive(ConfigLeaf.ERGOPTI_BASE) {
		; « Symbols first » on the native or built-in row (NumberRowSymbolsFirstText).
		Swapped := NumberRowSymbolsFirstText(Numeric, false, NumberRowForegroundLayout(), false)
		if Swapped != ""
			return { Count: StrLen(Swapped), Text: Swapped }
	}
	if _KLE_BaseCriterion(Scan, false) && KLE_KeyCodes.Has(Scan) {
		Shift := false
		if Probe["effective_number_row"] == "symbols" && NumberRowSymbolsCapable(false) {
			Level := NumberRowSymbolsLevel(Numeric, false)
			if Level["supported"]
				Shift := Level["shift"]
		}
		Step := Keylayout_Step(KLE_Model, KEYLAYOUT_NEUTRAL_STATE,
			KLE_LevelIndex[_KLE_ComboKey(Shift, false, false)], KLE_KeyCodes[Scan])
		return { Count: Step["Next"] != "" && Step["Next"] != KEYLAYOUT_NEUTRAL_STATE ? -1 : StrLen(Step["Output"]),
			Text: Step["Output"] }
	}
	if Features["layout"][ConfigLeaf.ERGOPTI_BASE] && LayoutRowIsEmulated(Scan) {
		; The built-in emulation types its own number row (RegisterBuiltinNumberRow).
		Row := NumberRowEmulatedBase(StrUpper(Scan))
		if Row != ""
			return { Count: StrLen(Row), Text: Row }
		if !Probe.Has("base_dead_keys")
			Probe["base_dead_keys"] := ErgoptiBaseDeadKeys()
		if Probe["base_dead_keys"].Has(Scan)
			return { Count: -1, Text: Probe["base_dead_keys"][Scan]["chain"] }
		if !Probe.Has("base_mapping")
			Probe["base_mapping"] := ErgoptiBaseMapping()
		Base := Probe["base_mapping"]
		if Base.Has(Numeric) {
			Entry := Base[Numeric]
			Text := (Entry is String) ? Entry : (Entry.HasOwnProp("alt") && Entry.alt != "" ? Entry.alt : Entry.c)
			return { Count: StrLen(Text), Text: Text }
		}
	}
	return Native
}

/** Builds actual current source evidence through the effective plain owners. */
_StarSlotCurrentSource(Generation, Keycodes, Hkl) {
	return StarSlotProbeSource(Hkl, Generation, Keycodes, 0, _StarSlotEffectivePlain.Bind(Map()))
}

/** Resolves only present ordinary Win settings against one exact native source. */
_StarSlotExplicitClaim(Source, Hkl) {
	global _IniCache, KeyboardShortcutAssignments
	if !(Source is Map) || !IsSet(_IniCache) || !_IniCache.Has(ConfigKey.SHORTCUTS_KEYBOARD)
		return 0
	Resolver := HotkeyRegistrarNativeKeyResolverSnapshot(Map("get_layout", (*) => Hkl))
	if !HasMethod(Resolver, "Call")
		throw Error("The ordinary Win source identity could not be resolved.")
	SourceVk := KS_ScancodeToVk(Source["native_code"], Hkl)
	Selected := 0, Slots := []
	for Slot in _IniCache[ConfigKey.SHORTCUTS_KEYBOARD] {
		if SubStr(Slot, 1, 5) != "meta_" || !KeyboardShortcutAssignments.Has(Slot)
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
_StarSlotSourceSignature() {
	global Features, KLE_Id
	Layout := Features["layout"]
	return Layout[ConfigLeaf.ERGOPTI_BASE] . "|" . Layout[ConfigLeaf.DIRECT_ACCESS_DIGITS]
		. "|" . Layout[ConfigLeaf.EMULATED_LAYOUT] . "|" . KLE_Id
}

/** Rejects source changes and an actual tap-hold owner before stale delivery. */
_StarSlotSourceIsCurrent() {
	global TapHold
	State := StarSlotState()
	if KS_ResolveKeyboardLayout() != State["hkl"] || _StarSlotSourceSignature() !== State["source_signature"]
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
_StarSlotDeliveryState() {
	State := StarSlotState()
	Admission := _StarSlotAdmission()
	Admission["source_generation"] := _StarSlotSourceIsCurrent() ? State["source_generation"] : -1
	Admission["configuration_generation"] := State["configuration_generation"]
	Admission["action"] := _StarSlotArmedAction(StarSlot()["id"])
	return Admission
}

/** Returns a slot's action as armed now: an AI action is not while the AI is off. */
_StarSlotArmedAction(Slot) {
	global KeyboardShortcutAssignments
	Action := KeyboardShortcutAssignments.Get(Slot, "none")
	return AiActionBlocked(Action) ? "none" : Action
}

/** Whether the broker took this ordinary slot, whose native hotkey it keeps disabled. */
StarSlotOwnsOrdinarySlot(Slot) {
	State := StarSlotState()
	Claim := State["ordinary_claim"]
	if !State["initialized"] || !(Claim is Map)
		return false
	for Taken in Claim["slots"] {
		if Taken == Slot
			return true
	}
	return false
}

/** Selects the live callback owner without running it from a native criterion. */
_StarSlotBrokerWinner(Scan) {
	State := StarSlotState()
	if !State["initialized"] || A_IsSuspended
		return 0
	Admission := _StarSlotAdmission()
	if Admission["master"] && !Admission["inhibited"] && State["ordinary_physical"].Has(Scan) {
		Physical := State["ordinary_physical"][Scan]
		if _StarSlotArmedAction(Physical["slot"]) != "none"
			return Map("kind", "ordinary", "slot", Physical["slot"])
	}
	Decision := State["decision"]
	SourceScan := (Decision is Map) && (Decision["source"] is Map)
		? Format("SC{:03X}", Decision["source"]["native_code"]) : ""
	if Scan == SourceScan && Admission["master"] && !Admission["inhibited"]
			&& _StarSlotSourceIsCurrent() {
		Claim := State["ordinary_claim"]
		if (Claim is Map) && _StarSlotArmedAction(Claim["slot"]) != "none"
			return Map("kind", "ordinary", "slot", Claim["slot"])
	}
	if Admission["master"] && !Admission["inhibited"] && State["legacy"].Has(Scan)
		return Map("kind", "legacy", "callback", State["legacy"][Scan])
	if Scan == SourceScan && StarSlotCanDeliver(Decision, _StarSlotDeliveryState())
		return Map("kind", "contextual", "decision", Decision)
	for Fallback in State["layouts"].Get(Scan, []) {
		if !HasMethod(Fallback["criterion"], "Call") || Fallback["criterion"].Call()
			return Map("kind", "layout", "callback", Fallback["callback"])
	}
	return 0
}

/** Native admission consumes input only while one live owner needs this variant. */
_StarSlotBrokerCriterion(Scan, ConfigurationGeneration, SourceGeneration, *) {
	State := StarSlotState()
	if State["configuration_generation"] != ConfigurationGeneration || State["source_generation"] != SourceGeneration
		return false
	return _StarSlotBrokerWinner(Scan) is Map
}

/** Dispatches once through the same live arbitration used by the criterion. */
_StarSlotBrokerDispatch(Scan, ConfigurationGeneration, SourceGeneration, *) {
	State := StarSlotState()
	if State["configuration_generation"] != ConfigurationGeneration || State["source_generation"] != SourceGeneration
		return
	Winner := _StarSlotBrokerWinner(Scan)
	if !(Winner is Map)
		return
	switch Winner["kind"] {
		case "ordinary": RunKeyboardShortcutAction(Winner["slot"])
		case "contextual":
			if StarSlotCanDeliver(Winner["decision"], _StarSlotDeliveryState())
				RunKeyboardShortcutAction(StarSlot()["id"])
		default: Winner["callback"].Call()
	}
}

/**
 * Acquires the complete native Win cohort after every existing producer joins it.
 * Source/ordinary handoff is backup-free because it transfers only native handles;
 * ordinary settings remain under their existing lease and WAL persistence owner.
 * @returns {Integer} Number of owned physical Win variants.
 */
StarSlotStart() {
	global ScriptInformation, KeyboardShortcutAssignments, GESTURE_ACTIONS
	State := StarSlotState()
	if State["initialized"]
		throw Error("The physical Win broker is already initialized.")
	if State["native_handles"].Count || State["ordinary_restore"].Count
		throw Error("The physical Win broker still owns unsettled cohort compensation.")
	LoggerStart("StarSlot", "Acquiring the shared physical shortcut cohort…")
	State["hkl"] := KS_ResolveKeyboardLayout()
	State["source_generation"] += 1
	State["source_signature"] := _StarSlotSourceSignature()
	Keycodes := StarSlotPhysicalCatalogue(), Known := Map()
	for Key in Keycodes["keys"]
		Known[Key["code"]] := true
	Source := _StarSlotCurrentSource(State["source_generation"], Keycodes, State["hkl"])
	Selected := StarSlotSelectSource(Source, Known)
	State["ordinary_claim"] := _StarSlotExplicitClaim(Selected["source"], State["hkl"])
	Claims := Map()
	if Selected["source"] is Map {
		Identity := Selected["source"]["identity"]
		Scan := Format("SC{:03X}", Selected["source"]["native_code"])
		if State["ordinary_claim"] is Map
			Claims[Identity] := State["ordinary_claim"]
		else if State["legacy"].Has(Scan)
			Claims[Identity] := Map("legacy", true)
	}
	Slot := StarSlot()
	State["decision"] := StarSlotResolve(Map("default_action", ManifestDefaultFor(Slot["path"]),
		"stored_action", KeyboardShortcutAssignments.Get(Slot["id"], ManifestDefaultFor(Slot["path"])),
		"is_action", (Id) => GESTURE_ACTIONS.Has(Id), "source", Source,
		"known_codes", Known, "explicit_claims", Claims,
		"configuration_generation", State["configuration_generation"], "admission", _StarSlotAdmission()))
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
	StarSlotAcquireCohort(Scans, OrdinaryHandles, State["native_handles"], Map(
		"reserve", (Scan) => HotkeyRegistrarReservePhysicalBroker("Cmd+" . Scan,
			_StarSlotBrokerDispatch.Bind(Scan, State["configuration_generation"], State["source_generation"]),
			"keyboard-win-broker", HotkeyRegistrarResolvedNativeDescriptor("#" . Scan),
			_StarSlotBrokerCriterion.Bind(Scan, State["configuration_generation"], State["source_generation"])),
		"activate", _HotkeyRegistrarActivate, "retire", HotkeyRegistrarUnbind,
		"set_enabled", HotkeyRegistrarSetEnabled), State["ordinary_restore"])
	; Every native On is acknowledged while admission is still false. Publish
	; authority once, only after the full cohort and the personal handoff exist.
	State["initialized"] := true
	LoggerSuccess("StarSlot", "Physical shortcut cohort acquired ({1} variant(s), contextual action: {2}).",
		State["native_handles"].Count, State["decision"]["action"])
	return State["native_handles"].Count
}

/**
 * Acquires a cohort while its caller keeps every admission criterion inactive.
 * @param {Map} Scans Physical keys requiring a single broker owner.
 * @param {Array} OrdinaryHandles Existing personal aliases to suspend reversibly.
 * @param {Map} Handles Exact acknowledged handles, including any retirement debt.
 * @param {Map} Ports Registrar reserve, activate, retire and set_enabled owners.
 * @param {Map} RestoreDebt Retained exact personal handles awaiting restoration.
 * @returns {Boolean} True only after every native acquisition is acknowledged.
 */
StarSlotAcquireCohort(Scans, OrdinaryHandles, Handles, Ports, RestoreDebt := unset) {
	if !IsSet(RestoreDebt)
		RestoreDebt := StarSlotState()["ordinary_restore"]
	if !(Handles is Map) || !(RestoreDebt is Map)
		throw TypeError("The physical broker requires explicit native and personal custody maps.")
	if Handles.Count || RestoreDebt.Count
		throw Error("The physical broker cannot acquire over unsettled cohort compensation.")
	for Name in ["reserve", "activate", "retire", "set_enabled"] {
		if !Ports.Has(Name) || !HasMethod(Ports[Name], "Call")
			throw TypeError("The physical broker requires its exact registrar ports.")
	}
	try {
		for Scan in Scans {
			Handle := Ports["reserve"].Call(Scan)
			if !(Handle is String) || Handle == ""
				throw Error("The physical Win broker refused native acquisition: " . Scan)
			Handles[Scan] := Handle
		}
		for Handle in OrdinaryHandles {
			; The native call can change state before returning false or throwing.
			; Claim its exact restoration duty before crossing that effect boundary.
			RestoreDebt[Handle] := true
			Disabled := Ports["set_enabled"].Call(Handle, false)
			if !((Disabled is Integer) && Disabled == true)
				throw Error("The ordinary Win owner refused its physical broker handoff.")
		}
		for Scan, Handle in Handles {
			Activated := Ports["activate"].Call(Handle)
			if !((Activated is Integer) && Activated == true)
				throw Error("The physical Win broker refused native activation: " . Scan)
		}
	} catch as Err {
		Resolution := StarSlotSettleCohortDebt(Handles, RestoreDebt, Ports)
		if Resolution["status"] != "settled"
			throw Error(Err.Message . " Unacknowledged compensation: " . Resolution["detail"])
		throw Err
	}
	; The acknowledged complete broker now owns the intentional personal handoff.
	RestoreDebt.Clear()
	return true
}

/**
 * Retries only the exact retained native and personal compensation obligations.
 * Callers keep all cohort criteria inactive until this receipt is settled.
 * A refusal, malformed acknowledgement or exception never drops handle custody.
 * @param {Map} Handles Native handles keyed by their original physical scans.
 * @param {Map} RestoreDebt Exact personal handles retained before disable.
 * @param {Map} Ports Matching retire and set_enabled native owners.
 * @returns {Map} Settled or retained receipt with fixed operation/handle details.
 */
StarSlotSettleCohortDebt(Handles, RestoreDebt, Ports) {
	if !(Handles is Map) || !(RestoreDebt is Map) || !(Ports is Map)
		throw TypeError("Cohort compensation requires its exact custody and native ports.")
	for Name in ["retire", "set_enabled"] {
		if !Ports.Has(Name) || !HasMethod(Ports[Name], "Call")
			throw TypeError("Cohort compensation requires its exact native owners.")
	}
	Debt := [], Retired := [], Restored := []
	for Scan, Handle in Handles {
		try {
			Accepted := Ports["retire"].Call(Handle)
			if (Accepted is Integer) && Accepted == true
				Retired.Push(Scan)
			else
				Debt.Push("retire " . Scan)
		} catch as Refusal {
			Debt.Push("retire " . Scan . ": " . Refusal.Message)
		}
	}
	for Scan in Retired
		Handles.Delete(Scan)
	for Handle in RestoreDebt {
		try {
			Accepted := Ports["set_enabled"].Call(Handle, true)
			if (Accepted is Integer) && Accepted == true
				Restored.Push(Handle)
			else
				Debt.Push("restore " . Handle)
		} catch as Refusal {
			Debt.Push("restore " . Handle . ": " . Refusal.Message)
		}
	}
	for Handle in Restored
		RestoreDebt.Delete(Handle)
	Detail := ""
	for Item in Debt
		Detail .= (Detail == "" ? "" : "; ") . Item
	return Map("status", Handles.Count || RestoreDebt.Count ? "retained" : "settled", "detail", Detail)
}

/** Reloads the physical cohort on an actual native input-source switch. */
StarSlotNeedsLayoutReload(Hkl) {
	State := StarSlotState()
	return State["initialized"] && Hkl != State["hkl"]
}

/** Returns the slot's chord as its modifier group names its rows (« Win + ★ »). */
StarSlotLabel() {
	global STAR_SLOT_MARKER
	return KeyNameLabel("win") . " + " . STAR_SLOT_MARKER
}

/** Draws the ordinary action picker even when its native chord is unavailable. */
StarSlotRows() {
	global KeyboardShortcutAssignments, GESTURE_ACTIONS
	Slot := StarSlot()
	Action := KeyboardShortcutAssignments.Get(Slot["id"], ManifestDefaultFor(Slot["path"]))
	Label := LabelValue(StarSlotLabel(), GESTURE_ACTIONS.Has(Action)
		? GestureActionDisplayLabel(Action, Slot["binding_id"]) : t("dialog.action_picker.disabled"))
	Decision := StarSlotState()["decision"]
	if (Decision is Map) && Decision["reason"] != ""
		Label .= " — " . t("menu.shortcuts.keyboard.star_slot_reason." . Decision["reason"])
	return [Map("label", Label, "action", (*) => ShowKeyboardShortcutPicker(Slot["id"]))]
}
