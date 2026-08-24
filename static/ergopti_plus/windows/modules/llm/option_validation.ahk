; modules/llm/option_validation.ahk
; Pure validators for option values crossing config, menu, and engine boundaries.

#Requires AutoHotkey v2.0

/**
 * Returns a detached, normalized string array or false when any element has
 * the wrong type or is empty after trimming. No caller may treat false as an
 * array: AHK's string/false equality rules make an explicit type check
 * mandatory at every boundary.
 */
LLM_Option_NormalizeStringArray(Value, Lowercase := false) {
	if !(Value is Array)
		return false
	Out := []
	Seen := Map()
	for Item in Value {
		if !(Item is String)
			return false
		Normalized := Trim(Item)
		if (Normalized == "")
			return false
		if Lowercase
			Normalized := StrLower(Normalized)
		if Seen.Has(Normalized)
			continue
		Seen[Normalized] := true
		Out.Push(Normalized)
	}
	return Out
}

/**
 * Canonicalizes a modifier array through the shared chord grammar. The dummy
 * terminal key lets ChordParse validate aliases/order without duplicating its
 * modifier table here.
 */
LLM_Option_NormalizeModifierArray(Value) {
	global CHORD_SEPARATOR
	Items := LLM_Option_NormalizeStringArray(Value, true)
	if !(Items is Array)
		return false
	if (Items.Length == 0)
		return []
	Chord := ""
	for Index, Item in Items
		Chord .= (Index == 1 ? "" : CHORD_SEPARATOR) . Item
	Parsed := ChordParse(Chord . CHORD_SEPARATOR . "a")
	return Parsed["ok"] ? Parsed["mods"] : false
}

/**
 * Returns the canonical '+'-separated modifier spelling, accepts the retired
 * comma spelling as a migration input, or false for a malformed/non-string
 * value.
 */
LLM_Option_NormalizeModifierString(Value) {
	global CHORD_SEPARATOR
	if !(Value is String)
		return false
	Value := Trim(Value)
	if (Value == "")
		return ""
	Parts := StrSplit(StrReplace(Value, ",", CHORD_SEPARATOR), CHORD_SEPARATOR)
	Parts := LLM_Option_NormalizeModifierArray(Parts)
	if !(Parts is Array)
		return false
	Out := ""
	for Index, Item in Parts
		Out .= (Index == 1 ? "" : CHORD_SEPARATOR) . Item
	return Out
}

/** Returns a detached, schema-safe custom-profile array or false. */
LLM_Option_NormalizeUserProfiles(Value) {
	if !(Value is Array)
		return false
	Out := []
	SeenIds := Map()
	for Profile in Value {
		if !(Profile is Map) || !Profile.Has("id")
				|| !(Profile["id"] is String) || Profile["id"] == ""
				|| SeenIds.Has(Profile["id"])
			return false
		Copy := Map()
		for Key, Item in Profile {
			if !(Key is String)
				return false
			if (Key == "stop_sequences") {
				if !(Item is Array)
					return false
				Sequences := []
				for Sequence in Item {
					if !(Sequence is String) || Sequence == ""
						return false
					Sequences.Push(Sequence)
				}
				Copy[Key] := Sequences
				continue
			}
			if IsObject(Item)
				return false
			Copy[Key] := Item
		}
		for Key in ["id", "label", "system_single", "system_multi",
			"system_multi_template", "raw_prompt"]
			if Copy.Has(Key) && !(Copy[Key] is String)
				return false
		if Copy.Has("batch") {
			Batch := Copy["batch"]
			if !(Batch is Integer) || (Batch != 0 && Batch != 1)
				return false
			Copy["batch"] := Batch == 1
		}
		SeenIds[Copy["id"]] := true
		Out.Push(Copy)
	}
	return Out
}

/** Returns detached API-entry records whose consumer-visible fields are typed. */
LLM_Option_NormalizeApiEntries(Value) {
	if !(Value is Array)
		return false
	Out := []
	SeenIds := Map()
	for Entry in Value {
		if (Entry is Map) {
			if !Entry.Has("Id")
				return false
			EntryId := Entry["Id"]
			Properties := Entry
		} else if (Type(Entry) == "Object") {
			if !Entry.HasOwnProp("Id")
				return false
			EntryId := Entry.Id
			Properties := Entry.OwnProps()
		} else
			return false
		if !(EntryId is String) || EntryId == "" || SeenIds.Has(EntryId)
			return false
		Copy := Map()
		for Key, Item in Properties {
			if !(Key is String) || IsObject(Item)
				return false
			Copy[Key] := Item
		}
		for Key in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
			if Copy.Has(Key) && !(Copy[Key] is String)
				return false
		SeenIds[EntryId] := true
		Out.Push(Copy)
	}
	return Out
}

/** Returns a detached app -> profile-id map or false for any invalid pair. */
LLM_Option_NormalizeAppProfileOverrides(Value) {
	if !(Value is Map)
		return false
	Out := Map()
	Out.CaseSense := Value.CaseSense
	for AppName, ProfileId in Value {
		if !(AppName is String) || AppName == ""
				|| !(ProfileId is String) || ProfileId == ""
			return false
		Out[AppName] := ProfileId
	}
	return Out
}

/**
 * Validates and normalizes one public LLM option. Unknown keys fail closed so
 * every caller must consciously extend this schema when it adds a new option.
 */
LLM_Option_TryNormalize(Key, Value, &Normalized) {
	static StringKeys := Map(
		"model", true, "profile_id", true, "language", true,
		"trigger_shortcut", true, "backend", true, "api_entry_id", true)
	static IntegerKeys := Map(
		"n_predictions", true, "min_words", true, "max_words", true,
		"debounce_ms", true, "ctx_chars", true, "pred_indent", true,
		"ollama_port", true)
	static BooleanKeys := Map(
		"enabled", true, "auto_profile_for_model", true,
		"instant_on_word_end", true, "after_hotstring", true,
		"reset_on_nav", true, "disable_url_bars", true,
		"disable_password_fields", true, "show_info_bar", true,
		"streaming", true, "show_all_at_once", true,
		"auto_raise_temp", true, "onboarding_seen", true,
		"inline_autotype", true)
	Normalized := false
	if StringKeys.Has(Key) {
		if !(Value is String)
			return false
		Normalized := Value
		return true
	}
	if (Key == "temperature") {
		if (Value is String) {
			if !IsNumber(Value)
				return false
			Normalized := Value
			return true
		}
		if !(Value is Integer) && !(Value is Float)
			return false
		try Normalized := Format("{:.17g}", Value + 0.0)
		catch
			return false
		return true
	}
	if (Key == "nav_modifiers" || Key == "val_modifiers") {
		Normalized := LLM_Option_NormalizeModifierString(Value)
		return Normalized is String
	}
	if IntegerKeys.Has(Key) {
		if !(Value is Integer) && !(Value is Float)
			return false
		try Candidate := Integer(Value)
		catch
			return false
		if (Candidate != Value)
			return false
		Normalized := Candidate
		return true
	}
	if BooleanKeys.Has(Key) {
		if !(Value is Integer) || (Value != 0 && Value != 1)
			return false
		Normalized := Value == 1
		return true
	}
	if (Key == "disabled_apps") {
		Normalized := LLM_Option_NormalizeStringArray(Value, true)
		return Normalized is Array
	}
	if (Key == "user_profiles") {
		Normalized := LLM_Option_NormalizeUserProfiles(Value)
		return Normalized is Array
	}
	if (Key == "api_entries") {
		Normalized := LLM_Option_NormalizeApiEntries(Value)
		return Normalized is Array
	}
	if (Key == "app_profile_overrides") {
		Normalized := LLM_Option_NormalizeAppProfileOverrides(Value)
		return Normalized is Map
	}
	return false
}

/** Parses a persisted Boolean without comparing an object to scalar sentinels. */
LLM_Option_TryParseConfigBoolean(Value, &Normalized) {
	Normalized := false
	if (Value is Integer) {
		if (Value != 0 && Value != 1)
			return false
		Normalized := Value == 1
		return true
	}
	if !(Value is String)
		return false
	Value := StrLower(Trim(Value))
	if (Value == "1" || Value == "true") {
		Normalized := true
		return true
	}
	if (Value == "0" || Value == "false") {
		Normalized := false
		return true
	}
	return false
}
