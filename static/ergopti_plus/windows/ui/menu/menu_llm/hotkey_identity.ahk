; ui/menu/menu_llm/hotkey_identity.ahk

; ==============================================================================
; MODULE: LLM Hotkey Identity
; DESCRIPTION:
; Translates the LLM menu's chord settings (navigation and validation
; modifiers) into AutoHotkey specs and resolves each contextual hotkey plan
; (Ctrl+1..9 profiles, prediction navigation) to its native spelling and
; physical identity, so two spellings of one physical chord are one owner.
;
; FEATURES & RATIONALE:
; 1. One grammar: every chord goes through the shared ChordParse and the
;    registrar's native spec, never a private parser.
; 2. Physical identities come from one keyboard-layout snapshot per decision,
;    so a layout switch in the middle of a plan cannot split its owners.
; 3. Plans are enriched all-or-nothing: a duplicate physical owner leaves the
;    caller's plan untouched.
; 4. No dedicated prediction hotkey lives here: a prediction on demand is the
;    llm_generate_prediction action, bound in a keyboard slot (Win+Space
;    recommended) that the shortcuts registrar owns.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Chord Translation =========
; ======================================
; ======================================

_LLM_Menu_ShortcutKeyUsesNativeSyntax(Key) {
	if !(Key is String) || Key == ""
		return true
	; The shared chord grammar deliberately accepts physical VK/SC names for
	; low-level driver shortcuts. LLM chords cannot safely accept raw AHK
	; syntax: VK/SC aliases overlap named contextual variants, wildcard variants
	; cover additional modifiers, and an " Up" suffix adds a release action to
	; the same physical press. Keep that syntax out of these settings. Modifier
	; keys are refused by the shared registrar for every client
	; (HotkeyRegistrarKeyIsModifier).
	if RegExMatch(Key,
			"i)^(?:vk[0-9a-f]+(?:sc[0-9a-f]+)?|sc[0-9a-f]+)$")
		return true
	if HotkeyRegistrarKeyIsModifier(Key)
		return true
	return RegExMatch(Key, "[\s*~$<>^!#&]") != 0
}

LLM_Menu_ShortcutToAhk(raw) {
	if (Type(raw) = "String" && Trim(raw) = "")
		return ""
	Parsed := ChordParse(raw)
	if !Parsed["ok"] {
		try LoggerWarn("LLM", "Rejected LLM shortcut '{1}': {2}.", raw,
			Parsed["err"])
		return ""
	}
	if _LLM_Menu_ShortcutKeyUsesNativeSyntax(Parsed["key"]) {
		try LoggerWarn("LLM",
			"Rejected LLM shortcut '{1}': native AutoHotkey key syntax is not allowed.",
			raw)
		return ""
	}
	; Raw pointer observers own wildcard mouse-button and wheel variants, so every modified or
	; unmodified spelling overlaps their physical surface. An LLM variant would
	; eclipse activity tracking for that chord and must be rejected here.
	if RegExMatch(Parsed["key"],
			"i)^(?:[lrm]button|xbutton[12]|wheel(?:up|down|left|right))$") {
		try LoggerWarn("LLM",
			"Rejected LLM shortcut '{1}': the pointer key is reserved by the input dispatcher.",
			raw)
		return ""
	}
	Native := HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"])
	if (Native = "")
		try LoggerWarn("LLM",
			"Rejected LLM shortcut '{1}': a modifier has no Windows equivalent.", raw)
	return Native
}

LLM_Menu_IsValidModifierString(Raw) {
	if !(Raw is String)
		return false
	Value := Trim(Raw)
	if Value == ""
		return true
	for Token in StrSplit(Value, "+") {
		if Trim(Token) == ""
			return false
	}
	return LLM_Menu_ShortcutToAhk(Value . "+a") != ""
}





; ======================================
; ======================================
; ======= 2/ Physical Identities =======
; ======================================
; ======================================

_LLM_Menu_ParseHotkeyNativeSpec(Spec) {
	if !(Spec is String)
		return false
	Raw := StrLower(Trim(Spec))
	if Raw == ""
		return false
	; HotIf receives the permanent name established by the first variant. Tilde
	; and hook-forcing dollar prefixes are variant properties, and modifier
	; symbols may be written in any order.
	Modifiers := Map()
	Wildcard := false
	KeyStart := 1
	Loop StrLen(Raw) {
		Ch := SubStr(Raw, A_Index, 1)
		if Ch == "<" || Ch == ">"
			return false
		if Ch == "~" || Ch == "$" {
			KeyStart := A_Index + 1
			continue
		}
		if Ch == "*" {
			Wildcard := true
			KeyStart := A_Index + 1
			continue
		}
		if Ch == "^" || Ch == "!" || Ch == "+" || Ch == "#" {
			Modifiers[Ch] := true
			KeyStart := A_Index + 1
			continue
		}
		break
	}
	Key := SubStr(Raw, KeyStart)
	if Key == "" || InStr(Key, "&")
		return false
	return Map("modifiers", Modifiers, "wildcard", Wildcard, "key", Key)
}

_LLM_Menu_HotkeyIdentityPrefix(Parsed) {
	if !(Parsed is Map) || !(Parsed.Get("modifiers", 0) is Map)
		return false
	Identity := Parsed.Get("wildcard", false) ? "*" : ""
	Modifiers := Parsed["modifiers"]
	for Prefix in ["^", "!", "+", "#"] {
		if Modifiers.Has(Prefix)
			Identity .= Prefix
	}
	return Identity
}

; Textual identity is intentionally retained for HotIf's permanent-name and
; per-plan lookup contract. Cross-owner admission uses the physical identity
; below because distinct character spellings can resolve to one native chord.
_LLM_Menu_HotkeyNativeIdentity(Spec) {
	Parsed := _LLM_Menu_ParseHotkeyNativeSpec(Spec)
	Prefix := _LLM_Menu_HotkeyIdentityPrefix(Parsed)
	if !(Prefix is String)
		return ""
	Key := Parsed["key"]
	if RegExMatch(Key, "^(vk|sc)([0-9a-f]+)$", &Match) {
		Code := Integer("0x" . Match[2])
		if Code <= 0 || (Match[1] == "vk" && Code > 0xFF)
				|| (Match[1] == "sc" && Code > 0x1FF)
			return ""
		Key := Match[1] == "vk" ? "vk" . Format("{:02x}", Code)
			: "sc" . Format("{:03x}", Code)
	}
	return Prefix . Key
}

_LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn := 0) {
	if HasMethod(KeyResolverFn, "Call")
		return KeyResolverFn
	return HotkeyRegistrarNativeKeyResolverSnapshot(
		KeyResolverFn is Map ? KeyResolverFn : 0)
}

; Resolves a key of the navigation plan through the layout snapshot, except
; that a digit names its digit-row key, VK_0 to VK_9, without the modifier the
; layout needs to type it. The validation chord is the key labelled N, as the
; macOS keycodes and the Linux digit-row codes are. The layout's own answer
; bound it to the character: on an AZERTY host '1' is Shift+VK_1, while the
; recommended digit-row emulation (direct_access_digits) types 1 with the bare
; key, so the chord never matched and the digit was typed (llm-accept-inserts).
; The snapshot still answers first: a layout it cannot resolve fails closed.
; @param {Func} LayoutResolver - Resolver snapshot of one keyboard layout.
; @param {String} Key - Key part of a plan spec.
; @returns {Map|Boolean} The physical key descriptor, or the snapshot's refusal.
_LLM_Menu_NavDigitRowKey(LayoutResolver, Key) {
	Resolved := LayoutResolver.Call(Key)
	if !(Resolved is Map) || !(Key is String) || !RegExMatch(Key, "^[0-9]$")
		return Resolved
	return Map("axis", "vk", "code", Ord(Key), "implicit_modifiers", "")
}

_LLM_Menu_HotkeyResolvedDescriptor(Spec, KeyResolverFn := 0) {
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return false
	Descriptor := HotkeyRegistrarResolvedNativeDescriptor(Spec, KeyResolverFn)
	return HotkeyRegistrarResolvedDescriptorIsValid(Descriptor)
		? Descriptor : false
}

_LLM_Menu_HotkeyPhysicalIdentity(Spec, KeyResolverFn := 0) {
	Descriptor := _LLM_Menu_HotkeyResolvedDescriptor(Spec, KeyResolverFn)
	return Descriptor is Map ? Descriptor["identity"] : ""
}

_LLM_Menu_HotkeyPhysicalIdentityIsValid(Identity) {
	if !(Identity is String)
		return false
	if !RegExMatch(Identity,
			"^\*?\^?!?\+?#?(vk|sc)([0-9A-F]{4})$", &Match)
		return false
	Code := Integer("0x" . Match[2])
	return Code > 0 && ((Match[1] == "vk" && Code <= 0xFF)
		|| (Match[1] == "sc" && Code <= 0x1FF))
}

; Compatibility name retained for the profile and navigation predicates.
_LLM_Menu_NavNativeIdentity(Spec) {
	return _LLM_Menu_HotkeyNativeIdentity(Spec)
}

_LLM_Menu_BuildNavModifierPrefixes(MenuState) {
	if !(MenuState is Map)
		return false
	if (MenuState.Has("nav_modifiers")
			&& !(MenuState["nav_modifiers"] is String))
		return false
	if (MenuState.Has("val_modifiers")
			&& !(MenuState["val_modifiers"] is String))
		return false
	NavModifiers := MenuState.Has("nav_modifiers")
		? Trim(MenuState["nav_modifiers"]) : ""
	ValModifiers := MenuState.Has("val_modifiers")
		? Trim(MenuState["val_modifiers"])
		: LLM_Defaults_ModifierString("llm_val_modifiers")
	if (!LLM_Menu_IsValidModifierString(NavModifiers)
			|| !LLM_Menu_IsValidModifierString(ValModifiers))
		return false

	NavPrefix := LLM_Menu_ShortcutToAhk(NavModifiers == ""
		? "a" : NavModifiers . "+a")
	ValPrefix := LLM_Menu_ShortcutToAhk(ValModifiers == ""
		? "a" : ValModifiers . "+a")
	if NavPrefix != ""
		NavPrefix := SubStr(NavPrefix, 1, -1)
	if ValPrefix != ""
		ValPrefix := SubStr(ValPrefix, 1, -1)
	if (NavModifiers != "" && NavPrefix == "")
			|| (ValModifiers != "" && ValPrefix == "")
		return false
	return Map("nav_prefix", NavPrefix, "val_prefix", ValPrefix)
}

_LLM_Menu_PlanEntryDescriptorIsValid(Entry) {
	if !(Entry is Map)
		return false
	Descriptor := Entry.Get("descriptor", 0)
	if !HotkeyRegistrarResolvedDescriptorIsValid(Descriptor)
		return false
	Spec := Entry.Get("spec", "")
	NativeSpec := Entry.Get("native_spec", "")
	NativeId := Entry.Get("native_id", "")
	PhysicalId := Entry.Get("physical_id", "")
	return Spec is String && Spec != ""
		&& Descriptor["logical_spec"] == StrLower(Spec)
		&& Descriptor["native_spec"] == NativeSpec
		&& Descriptor["identity"] == PhysicalId
		&& NativeId != ""
		&& NativeId == _LLM_Menu_NavNativeIdentity(NativeSpec)
}

_LLM_Menu_AttachPlanPhysicalIdentities(Plan, KeyResolverFn := 0) {
	if !(Plan is Array)
		return false
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return false
	Staged := []
	SeenNative := Map()
	SeenPhysical := Map()
	Loop Plan.Length {
		if !Plan.Has(A_Index)
			return false
		Entry := Plan[A_Index]
		if !(Entry is Map)
			return false
		Descriptor := _LLM_Menu_HotkeyResolvedDescriptor(
			Entry.Get("spec", ""), KeyResolverFn)
		if !(Descriptor is Map)
			return false
		NativeId := _LLM_Menu_HotkeyNativeIdentity(
			Descriptor["native_spec"])
		PhysicalId := Descriptor["identity"]
		if NativeId == "" || SeenNative.Has(NativeId)
				|| SeenPhysical.Has(PhysicalId)
			return false
		SeenNative[NativeId] := true
		SeenPhysical[PhysicalId] := true
		Staged.Push(Map("entry", Entry, "physical_id", PhysicalId,
			"native_spec", Descriptor["native_spec"],
			"native_id", NativeId, "descriptor", Descriptor))
	}
	for Item in Staged {
		Entry := Item["entry"]
		Entry["physical_id"] := Item["physical_id"]
		Entry["native_spec"] := Item["native_spec"]
		Entry["native_id"] := Item["native_id"]
		Entry["descriptor"] := Item["descriptor"]
	}
	return true
}
