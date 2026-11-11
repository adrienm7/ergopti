; ui/physical_shortcuts/slots.ahk

; ==============================================================================
; MODULE: Physical Shortcut Slots
; DESCRIPTION:
; Port of _shared/lua/shortcuts/physical_slots.lua for the Windows editor:
; names a physical key position and an exact modifier set in the existing
; shortcuts.keyboard namespace (physical_<mods>_<W3C code>). Native identity is
; the registry's ahk field (SCnnn); this owner never resolves logical text.
; ==============================================================================

; The shared identifiers of the feature, read once.
; @returns {Map} slot_prefix and app_id.
PhysicalShortcutsShared() {
	global _SharedDir
	static Shared := 0
	if !(Shared is Map)
		Shared := JsonParse(FSReadStrict(_SharedDir . "\modules\shortcuts\physical_shortcuts.json"))
	return Shared
}

class PhysicalSlots {
	; The slot prefix every driver names, from _shared/modules/shortcuts/physical_shortcuts.json.
	static PREFIX => PhysicalShortcutsShared()["slot_prefix"]
	static MODIFIER_ORDER := ["ctrl", "alt", "shift", "super"]
	; Modifier positions are held, never bound as a physical shortcut key.
	static MODIFIER_KEYS := Map("ShiftLeft", 1, "ShiftRight", 1, "ControlLeft", 1, "ControlRight", 1,
		"AltLeft", 1, "AltRight", 1, "MetaLeft", 1, "MetaRight", 1, "CapsLock", 1)

	/**
	 * Recognizes this namespace even when its contents are malformed.
	 * @param {Any} Slot Candidate configuration key.
	 * @returns {Integer} 1 when the key starts with the physical prefix.
	 */
	static IsNamespace(Slot) {
		return (Slot is String) && SubStr(Slot, 1, StrLen(PhysicalSlots.PREFIX)) == PhysicalSlots.PREFIX
	}

	/**
	 * Reads the canonical registry once and binds a model to it.
	 * @param {String} Path physical_keys.json; the shared copy by default.
	 * @returns {PhysicalSlots}
	 */
	static Load(Path := "") {
		global _SharedDir
		if (Path == "")
			Path := _SharedDir . "\data\keycodes\physical_keys.json"
		return PhysicalSlots(JsonParse(FileRead(Path, "UTF-8")))
	}

	/**
	 * Binds one registry snapshot without creating any assignment.
	 * @param {Map} Registry Decoded physical_keys.json.
	 */
	__New(Registry) {
		if !(Registry is Map) || Registry.Get("schema_version", 0) != 1
				|| !(Registry.Get("keys", 0) is Map) || !(Registry.Get("forms", 0) is Array)
			throw ValueError("Physical slots require the canonical physical-key registry.")
		this.Native := Map()
		this.Native.CaseSense := "On"
		Codes := ""
		for Code, Record in Registry["keys"] {
			if !RegExMatch(Code, "^[A-Za-z][A-Za-z0-9]*$") || !(Record is Map)
				throw ValueError("Physical-key registry record is invalid.", -1, Code)
			if Record.Get("kind", "") != "key" || PhysicalSlots.MODIFIER_KEYS.Has(Code)
				continue
			Identity := Record.Get("ahk", JSON_NULL)
			if (Identity != JSON_NULL) && (!(Identity is String) || Identity == "" || RegExMatch(Identity, "[\x00-\x1F]"))
				throw ValueError("Physical-key native identity is invalid.", -1, Code)
			this.Native[Code] := Identity == JSON_NULL ? "" : Identity
			Codes .= (Codes == "" ? "" : "`n") . Code
		}
		if (Codes == "")
			throw ValueError("Physical-key registry has no shortcut keys.")
		; The Lua owner sorts by byte order; Sort's case-sensitive mode matches it.
		this.Order := StrSplit(Sort(Codes, "C"), "`n")
	}

	/**
	 * Normalizes a closed boolean modifier set or a dense modifier-name array.
	 * @param {Map|Array|String} Modifiers "" for an empty set.
	 * @returns {Map|Integer} Detached exact set, or 0 when malformed.
	 */
	static ModifierSet(Modifiers) {
		ModSet := Map()
		if (Modifiers is String) && Modifiers == ""
			return ModSet
		if Modifiers is Array {
			for Name in Modifiers {
				if !(Name is String) || !PhysicalSlots._IsModifier(Name) || ModSet.Has(Name)
					return 0
				ModSet[Name] := true
			}
			return ModSet
		}
		if !(Modifiers is Map)
			return 0
		for Name, Held in Modifiers {
			if !(Name is String) || !PhysicalSlots._IsModifier(Name) || !(Held is Integer) || (Held != 0 && Held != 1)
				return 0
			if Held
				ModSet[Name] := true
		}
		return ModSet
	}

	static _IsModifier(Name) {
		for Known in PhysicalSlots.MODIFIER_ORDER {
			if (Known == Name)
				return true
		}
		return false
	}

	/**
	 * Builds a canonical slot from a registry code and exact modifiers.
	 * @param {String} Code W3C physical-key code.
	 * @param {Map|Array|String} Modifiers See ModifierSet.
	 * @returns {String} The slot, or "" when the code or modifiers are invalid.
	 */
	Encode(Code, Modifiers := "") {
		if !(Code is String) || !this.Native.Has(Code)
			return ""
		ModSet := PhysicalSlots.ModifierSet(Modifiers)
		if !(ModSet is Map)
			return ""
		Token := ""
		for Name in PhysicalSlots.MODIFIER_ORDER {
			if ModSet.Has(Name)
				Token .= (Token == "" ? "" : "_") . Name
		}
		return PhysicalSlots.PREFIX . (Token == "" ? "none" : Token) . "_" . Code
	}

	/**
	 * Parses only the canonical spelling of a physical slot.
	 * @param {Any} Slot Stored configuration key.
	 * @returns {Map|Integer} Map("slot", "code", "mods") or 0.
	 */
	Parse(Slot) {
		if !PhysicalSlots.IsNamespace(Slot)
			return 0
		if !RegExMatch(SubStr(Slot, StrLen(PhysicalSlots.PREFIX) + 1), "^(.*?)_([A-Za-z][A-Za-z0-9]*)$", &Parts)
			return 0
		Code := Parts[2]
		if !this.Native.Has(Code)
			return 0
		ModSet := Map()
		if (Parts[1] != "none") {
			for Name in StrSplit(Parts[1], "_") {
				if !PhysicalSlots._IsModifier(Name) || ModSet.Has(Name)
					return 0
				ModSet[Name] := true
			}
		}
		if (this.Encode(Code, ModSet) !== Slot)
			return 0
		return Map("slot", Slot, "code", Code, "mods", ModSet)
	}

	/**
	 * @param {Any} Slot Configuration key.
	 * @returns {Integer} 1 when the slot is a valid owned physical slot.
	 */
	Owns(Slot) {
		return this.Parse(Slot) is Map
	}

	/**
	 * Lists the registry positions that have a Windows identity, sorted.
	 * @returns {Array} W3C codes.
	 */
	Candidates() {
		Result := []
		for Code in this.Order {
			if (this.Native[Code] != "")
				Result.Push(Code)
		}
		return Result
	}

	/**
	 * Resolves a captured Windows identity only when the registry is unambiguous.
	 * @param {String} Identity SCnnn scan-code name proved by the adapter.
	 * @returns {String} The unique W3C code, or "".
	 */
	CodeFor(Identity) {
		if !(Identity is String) || Identity == ""
			return ""
		Matched := ""
		for Code in this.Order {
			if (this.Native[Code] = Identity) {
				if (Matched != "")
					return ""
				Matched := Code
			}
		}
		return Matched
	}
}
