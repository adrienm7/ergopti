; ui/physical_shortcuts/delivery.ahk

; ==============================================================================
; MODULE: Physical Shortcut Collisions and Delivery (Windows)
; DESCRIPTION:
; The two owners the Windows editor host still lacked: the collision owner the
; scope asks before a save, and the delivery owner that registers each bound
; physical slot's scan code with its exact modifiers and runs its action. Port
; of linux/modules/shortcuts/physical_collisions.lua over the Windows sources.
;
; FEATURES & RATIONALE:
; 1. One policy. PhysicalConflictsCheck is the AutoHotkey port of
;    _shared/shortcuts/engine/physical_conflicts.lua and replays its corpus
;    (_shared/tests/corpus/shortcuts/physical_conflict_vectors.json).
; 2. Claims from what Windows really holds: the other physical slots, the
;    assigned number-row tap keys (plain key only), every live registrar
;    binding resolved to its scan code, and any AutoHotkey variant already
;    registered on the candidate's scan code (tap-holds, key combinations, the
;    layout emulation). A source that cannot be resolved refuses the save.
; 3. Delivery stays off while PhysicalShortcutDeliveryAvailable answers false
;    (maintainer decision of 2026-11-11): nothing is registered until the
;    hardware qualification in TODO-tests-windows.md turns it on.
; 4. A press runs its action only when the key is physically down, the script
;    is not suspended and AltGr is not held; anything else is refused and
;    logged rather than replayed.
; ==============================================================================




; =================================================
; =================================================
; ======= 1/ Shared collision policy ==============
; =================================================
; =================================================

; The modifier roles the policy compares, in the shared order. A function, not
; a global: the boot binds the keyboard slots before this file's include.
; @returns {Array}
_PhysicalConflictRoles() {
	static Roles := ["ctrl", "alt", "shift", "super"]
	return Roles
}

; Whether two modifier sets hold the same roles.
_PhysicalConflictModsEqual(Left, Right) {
	if !(Left is Map) || !(Right is Map)
		return false
	for Role in _PhysicalConflictRoles() {
		if (Left.Get(Role, false) == true) != (Right.Get(Role, false) == true)
			return false
	}
	return true
}

/**
 * Tests one physical request against observed owner claims. Port of
 * physical_conflicts.lua conflicts().
 * @param {Map} Request "slot", "action", "code", "mods", "aliases".
 * @param {Array} Claims Maps of kind chord, logical or prefix with a binding.
 * @param {VarRef} Binding Receives the conflicting binding on a collision.
 * @returns {Integer|String} 1 collision, 0 free, "" malformed or unproven.
 */
PhysicalConflictsCheck(Request, Claims, &Binding := "") {
	Binding := ""
	if !(Request is Map) || !(Claims is Array) || !(Request.Get("slot", 0) is String)
			|| !(Request.Get("action", 0) is String) || !(Request.Get("code", "") is Integer)
			|| !(Request.Get("mods", 0) is Map) || !(Request.Get("aliases", 0) is Map)
		return ""
	if (Request["action"] == "none")
		return false
	for Claim in Claims {
		if !(Claim is Map) || !(Claim.Get("binding", 0) is String)
			return ""
		if (Claim["binding"] == "keyboard__" . Request["slot"])
			continue
		Kind := Claim.Get("kind", "")
		if (Kind == "logical") {
			if !(Claim.Get("key", 0) is String) || !(Claim.Get("mods", 0) is Map)
				return ""
			if Request["aliases"].Has(Claim["key"]) && _PhysicalConflictModsEqual(Request["mods"], Claim["mods"]) {
				Binding := Claim["binding"]
				return true
			}
		} else if (Kind == "chord") {
			if !(Claim.Get("code", "") is Integer) || !(Claim.Get("mods", 0) is Map)
				return ""
			if (Claim["code"] == Request["code"]) && _PhysicalConflictModsEqual(Request["mods"], Claim["mods"]) {
				Binding := Claim["binding"]
				return true
			}
		} else if (Kind == "prefix") {
			if !(Claim.Get("codes", 0) is Array)
				return ""
			for Code in Claim["codes"] {
				if !(Code is Integer)
					return ""
				if (Code == Request["code"]) {
					; Only the plain key is proved; a modified press stays unknown.
					if Claim.Get("unmodified_only", false) == true {
						for Role in _PhysicalConflictRoles() {
							if Request["mods"].Get(Role, false) == true
								return ""
						}
					}
					Binding := Claim["binding"]
					return true
				}
			}
		} else {
			return ""
		}
	}
	return false
}




; =================================================
; =================================================
; ======= 2/ Native identities ====================
; =================================================
; =================================================

; AutoHotkey modifier prefix of each physical-slot modifier role.
; @returns {Map}
_PhysicalSpecPrefixes() {
	static Prefixes := Map("ctrl", "^", "alt", "!", "shift", "+", "super", "#")
	return Prefixes
}

/**
 * The AutoHotkey hotkey name of a physical slot: its exact modifiers, then
 * its scan code.
 * @param {Map} Parsed From PhysicalSlots.Parse: "code" and "mods".
 * @param {PhysicalSlots} Model The slot model, for the scan code.
 * @returns {String} Such as "^+SC010", or "" without a Windows identity.
 */
PhysicalShortcutSpec(Parsed, Model) {
	if !(Parsed is Map) || !Model.Native.Has(Parsed["code"])
		return ""
	Scan := Model.Native[Parsed["code"]]
	if !RegExMatch(Scan, "i)^SC[0-9A-F]{3}$")
		return ""
	Prefix := ""
	for Role in _PhysicalConflictRoles() {
		if Parsed["mods"].Has(Role)
			Prefix .= _PhysicalSpecPrefixes()[Role]
	}
	return Prefix . StrUpper(Scan)
}

/**
 * Reads a hotkey name back into its scan code and modifier roles.
 * @param {String} Spec Such as "^+SC010", "*SC03A" or "^a".
 * @param {Func} ScanOf Resolves a key name to its scan code (GetKeySC).
 * @returns {Map|Integer} Map("code", n, "mods", Map, "wildcard", 0/1), with
 *   "mouse" for a mouse hotkey (code 0), or 0 when the key has no scan code.
 */
PhysicalShortcutParseSpec(Spec, ScanOf) {
	if !(Spec is String) || !RegExMatch(Spec, "^([~$*<>^!+#]*)(.+)$", &Parts)
		return 0
	Mods := Map()
	Wildcard := InStr(Parts[1], "*") ? true : false
	for Role, Prefix in _PhysicalSpecPrefixes() {
		if InStr(Parts[1], Prefix)
			Mods[Role] := true
	}
	Key := Parts[2]
	; A mouse button or wheel has no scan code and cannot hold a keyboard key.
	if RegExMatch(Key, "i)^(?:[LRM]Button|XButton[12]|Wheel(?:Up|Down|Left|Right))$")
		return Map("code", 0, "mods", Mods, "wildcard", Wildcard, "mouse", true)
	if RegExMatch(Key, "i)^(?:VK[0-9A-F]{2})?SC([0-9A-F]{3})$", &Scan)
		Code := Integer("0x" . Scan[1])
	else {
		try Code := ScanOf.Call(Key)
		catch as Err {
			LoggerWarn("PhysicalShortcuts", "The key of hotkey '{1}' could not be resolved: {2}.", Spec, Err.Message)
			return 0
		}
	}
	if !(Code is Integer) || Code <= 0
		return 0
	return Map("code", Code, "mods", Mods, "wildcard", Wildcard)
}




; =================================================
; =================================================
; ======= 3/ Collision owner ======================
; =================================================
; =================================================

/**
 * The Windows collision owner the scope asks before a physical save.
 */
class PhysicalShortcutCollisions {
	/**
	 * @param {Map} Ports Test seams: "model", "assignments", "tap_keys",
	 *   "registrar", "probe", "scan_of". Production reads the live driver.
	 */
	__New(Ports := unset) {
		this.Ports := IsSet(Ports) ? Ports : Map()
	}

	_Port(Name, Default) {
		return this.Ports.Get(Name, Default)
	}

	; The configured keyboard slots, by slot.
	_Assignments() {
		global KeyboardShortcutAssignments
		if this.Ports.Has("assignments")
			return this.Ports["assignments"].Call()
		return IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : Map()
	}

	; The assigned number-row tap keys: Array of Map("code", n, "binding", id).
	_TapKeys() {
		global TapKeyAssignments, TAP_KEY_ORDER, TAP_KEY_SCANCODES
		if this.Ports.Has("tap_keys")
			return this.Ports["tap_keys"].Call()
		Keys := []
		if !IsSet(TapKeyAssignments) || !IsSet(TAP_KEY_ORDER)
			return Keys
		for Id in TAP_KEY_ORDER {
			if TapKeyAssignments.Get(Id, "none") != "none"
				Keys.Push(Map("code", TAP_KEY_SCANCODES[Id], "binding", TapKeyBindingId(Id)))
		}
		return Keys
	}

	; The live registrar bindings: Array of Map("spec", s, "owner", o).
	_Registrar() {
		if this.Ports.Has("registrar")
			return this.Ports["registrar"].Call()
		return HotkeyRegistrarLiveSpecs()
	}

	; Whether AutoHotkey already holds a variant of this hotkey name.
	_Probe(Name) {
		if this.Ports.Has("probe")
			return this.Ports["probe"].Call(Name) ? true : false
		return _HotkeyRegistrarNativeExists(Name)
	}

	/**
	 * Checks scope rows against every claim Windows holds.
	 * @param {Array} Rows Scope rows ({ Section, Key, Value } or Delete).
	 * @returns {Integer|String} 1 free, "collision", "unavailable" or "source_changed".
	 */
	Call(Rows) {
		Model := this._Port("model", 0)
		if !(Model is PhysicalSlots)
			Model := PhysicalSlots.Load()
		ScanOf := this._Port("scan_of", GetKeySC)
		; The configuration after the rows: slot -> action.
		Planned := Map()
		Planned.CaseSense := "On"
		for Slot, Action in this._Assignments() {
			if PhysicalSlots.IsNamespace(Slot)
				Planned[Slot] := Action
		}
		Requests := []
		for Row in Rows {
			if (Row.Section != ConfigKey.SHORTCUTS_KEYBOARD) || !PhysicalSlots.IsNamespace(Row.Key)
				continue
			if Row.HasOwnProp("Delete") && Row.Delete {
				if Planned.Has(Row.Key)
					Planned.Delete(Row.Key)
				continue
			}
			Planned[Row.Key] := Row.Value
			if (Row.Value != "none")
				Requests.Push(Row.Key)
		}
		if (Requests.Length == 0)
			return "unavailable"
		Claims := []
		for Slot, Action in Planned {
			if (Action == "none")
				continue
			Parsed := Model.Parse(Slot)
			Spec := Parsed ? PhysicalShortcutSpec(Parsed, Model) : ""
			if (Spec == "")
				return "source_changed"
			Read := PhysicalShortcutParseSpec(Spec, ScanOf)
			Claims.Push(Map("kind", "chord", "binding", "keyboard__" . Slot, "code", Read["code"], "mods", Read["mods"]))
		}
		for Key in this._TapKeys()
			Claims.Push(Map("kind", "prefix", "binding", Key["binding"], "codes", [Key["code"]], "unmodified_only", true))
		for Entry in this._Registrar() {
			; The delivery owner's own registrations are the slots' chord claims above.
			if SubStr(Entry["owner"], 1, 19) == "physical_shortcuts:"
				continue
			Read := PhysicalShortcutParseSpec(Entry["spec"], ScanOf)
			if !(Read is Map)
				return "unavailable"
			if Read.Get("mouse", false)
				continue
			Kind := Read["wildcard"] ? "prefix" : "chord"
			Claim := Map("kind", Kind, "binding", "hotkey__" . Entry["owner"])
			if Read["wildcard"]
				Claim["codes"] := [Read["code"]]
			else
				Claim["code"] := Read["code"], Claim["mods"] := Read["mods"]
			Claims.Push(Claim)
		}
		for Slot in Requests {
			Parsed := Model.Parse(Slot)
			Spec := Parsed ? PhysicalShortcutSpec(Parsed, Model) : ""
			if (Spec == "")
				return "source_changed"
			Read := PhysicalShortcutParseSpec(Spec, ScanOf)
			Request := Map("slot", Slot, "action", Planned[Slot], "code", Read["code"],
				"mods", Read["mods"], "aliases", Map())
			Found := PhysicalConflictsCheck(Request, Claims, &Binding)
			if (Found == "")
				return "unavailable"
			if Found {
				LoggerInfo("PhysicalShortcuts", "Slot '{1}' collides with '{2}'.", Slot, Binding)
				return "collision"
			}
			; A static or dynamic AutoHotkey variant on the same key wins over a
			; later registration: the layout, a tap-hold or a key combination.
			Bare := StrReplace(StrReplace(StrReplace(StrReplace(Spec, "^"), "!"), "+"), "#")
			for Name in [Spec, "*" . Bare, "$" . Spec, "~" . Spec] {
				if this._Probe(Name) && !PhysicalShortcutDelivery.Owns(Name) {
					LoggerInfo("PhysicalShortcuts", "Slot '{1}' collides with the existing hotkey '{2}'.", Slot, Name)
					return "collision"
				}
			}
		}
		return true
	}
}




; =================================================
; =================================================
; ======= 4/ Delivery owner =======================
; =================================================
; =================================================

/**
 * Registers each bound physical slot and runs its action on a physical press.
 */
class PhysicalShortcutDelivery {
	; Hotkey name -> registrar handle, for the slots this owner bound.
	static Handles := Map()

	/**
	 * Whether this owner registered a hotkey name.
	 * @param {String} Name
	 * @returns {Integer}
	 */
	static Owns(Name) {
		for Spec, Handle in PhysicalShortcutDelivery.Handles {
			if (Spec == Name)
				return true
		}
		return false
	}

	/**
	 * Binds every assigned physical slot when delivery is qualified.
	 * @param {Map} Ports Test seams: "available", "assignments", "model",
	 *   "collisions", "bind", "run".
	 * @returns {Integer} The number of slots bound.
	 */
	static BindAll(Ports := unset) {
		global KeyboardShortcutAssignments
		Ports := IsSet(Ports) ? Ports : Map()
		if !PhysicalAvailabilityReady(Ports.Get("available", PhysicalShortcutDeliveryAvailable)) {
			LoggerDebug("PhysicalShortcuts", "Physical delivery is not qualified; no physical slot is bound.")
			return 0
		}
		Assignments := Ports.Has("assignments") ? Ports["assignments"].Call()
			: (IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : Map())
		Model := Ports.Get("model", 0)
		if !(Model is PhysicalSlots)
			Model := PhysicalSlots.Load()
		Collisions := Ports.Get("collisions", PhysicalShortcutCollisions())
		Bind := Ports.Get("bind", (Chord, Callback, Owner) => _HotkeyRegistrarBindOwned(Chord, Callback, Owner))
		RunAction := Ports.Get("run", RunKeyboardShortcutAction)
		LoggerStart("PhysicalShortcuts", "Registering physical shortcut slots…")
		Bound := 0
		for Slot, Action in Assignments {
			if !PhysicalSlots.IsNamespace(Slot) || Action == "none"
				continue
			Parsed := Model.Parse(Slot)
			Spec := Parsed ? PhysicalShortcutSpec(Parsed, Model) : ""
			if (Spec == "") {
				LoggerWarn("PhysicalShortcuts", "Slot '{1}' names no Windows key; skipped.", Slot)
				continue
			}
			Free := Collisions.Call([{ Section: ConfigKey.SHORTCUTS_KEYBOARD, Key: Slot, Value: Action }])
			if (Free != true) {
				LoggerWarn("PhysicalShortcuts", "Slot '{1}' not bound: {2}.", Slot, Free)
				continue
			}
			Chord := PhysicalShortcutChord(Parsed, Model)
			Handle := Bind.Call(Chord, ObjBindMethod(PhysicalShortcutDelivery, "_Press", Slot, Spec, RunAction),
				"physical_shortcuts:" . Slot)
			if (Handle == "") {
				LoggerWarn("PhysicalShortcuts", "Slot '{1}' could not be registered ({2}).", Slot, Spec)
				continue
			}
			PhysicalShortcutDelivery.Handles[Spec] := Handle
			Bound++
		}
		LoggerSuccess("PhysicalShortcuts", "Physical shortcut slots registered ({1} active).", Bound)
		return Bound
	}

	/**
	 * One press of a bound slot. Runs the action only for a physical press of
	 * the key, the script running and AltGr up.
	 * @param {String} Slot
	 * @param {String} Spec Its hotkey name.
	 * @param {Func} RunAction Runs the slot's action.
	 * @param {Map} Ports Test seams: "suspended", "physical", "altgr".
	 * @returns {Integer} 1 when the action ran.
	 */
	static _Press(Slot, Spec, RunAction, Ports := unset, *) {
		Ports := (IsSet(Ports) && Ports is Map) ? Ports : Map()
		Suspended := Ports.Has("suspended") ? Ports["suspended"] : A_IsSuspended
		RegExMatch(Spec, "i)(SC[0-9A-F]{3})$", &Scan)
		Physical := Ports.Has("physical") ? Ports["physical"] : GetKeyState(Scan[1], "P")
		AltGr := Ports.Has("altgr") ? Ports["altgr"] : GetKeyState("RAlt", "P")
		if Suspended || !Physical || AltGr {
			LoggerDebug("PhysicalShortcuts", "Slot '{1}' press refused (suspended={2}, physical={3}, altgr={4}).",
				Slot, Suspended ? 1 : 0, Physical ? 1 : 0, AltGr ? 1 : 0)
			return false
		}
		RunAction.Call(Slot)
		return true
	}
}

/**
 * The registrar chord of a physical slot: its modifiers and its scan code.
 * @param {Map} Parsed From PhysicalSlots.Parse.
 * @param {PhysicalSlots} Model
 * @returns {String} Such as "ctrl+shift+sc010".
 */
PhysicalShortcutChord(Parsed, Model) {
	Names := Map("ctrl", "ctrl", "alt", "alt", "shift", "shift", "super", "cmd")
	Chord := ""
	for Role in _PhysicalConflictRoles() {
		if Parsed["mods"].Has(Role)
			Chord .= Names[Role] . "+"
	}
	return Chord . StrLower(Model.Native[Parsed["code"]])
}
