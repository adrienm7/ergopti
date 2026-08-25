; modules/llm/option_validation.ahk
; Pure validators for option values crossing config, menu, and engine boundaries.

#Requires AutoHotkey v2.0

; Generous but finite admission budgets. These protect boot/config inputs from
; turning canonical signature construction into an unbounded per-request walk.
; Counts are per public option; the character budget includes keys and values.
global LLM_OPTION_MAX_SCALAR_CHARS := 65536
global LLM_OPTION_MAX_COLLECTION_ITEMS := 512
global LLM_OPTION_MAX_PROFILE_ITEMS := 64
global LLM_OPTION_MAX_API_ENTRIES := 64
global LLM_OPTION_MAX_RECORD_FIELDS := 32
global LLM_OPTION_MAX_STOP_SEQUENCES := 64
global LLM_OPTION_MAX_AGGREGATE_CHARS := 1048576

_LLM_Option_TryConsumeString(Value, &AggregateChars, AllowEmpty := true) {
	global LLM_OPTION_MAX_SCALAR_CHARS, LLM_OPTION_MAX_AGGREGATE_CHARS
	if !(Value is String)
		return false
	Length := StrLen(Value)
	if (!AllowEmpty && Length == 0) || Length > LLM_OPTION_MAX_SCALAR_CHARS
		return false
	if AggregateChars > LLM_OPTION_MAX_AGGREGATE_CHARS - Length
		return false
	AggregateChars += Length
	return true
}

/**
 * Returns a detached, normalized string array or false when any element has
 * the wrong type or is empty after trimming. No caller may treat false as an
 * array: AHK's string/false equality rules make an explicit type check
 * mandatory at every boundary.
 */
LLM_Option_NormalizeStringArray(Value, Lowercase := false) {
	global LLM_OPTION_MAX_COLLECTION_ITEMS
	if !(Value is Array)
		return false
	if Value.Length > LLM_OPTION_MAX_COLLECTION_ITEMS
		return false
	Out := []
	Seen := Map()
	AggregateChars := 0
	for Item in Value {
		if !(Item is String)
			return false
		Normalized := Trim(Item)
		if !_LLM_Option_TryConsumeString(Normalized, &AggregateChars, false)
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
	AggregateChars := 0
	if !_LLM_Option_TryConsumeString(Value, &AggregateChars)
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
	global LLM_OPTION_MAX_PROFILE_ITEMS, LLM_OPTION_MAX_RECORD_FIELDS,
		LLM_OPTION_MAX_STOP_SEQUENCES
	if !(Value is Array)
		return false
	if Value.Length > LLM_OPTION_MAX_PROFILE_ITEMS
		return false
	Out := []
	SeenIds := Map()
	AggregateChars := 0
	for Profile in Value {
		if !(Profile is Map) || !Profile.Has("id")
				|| !(Profile["id"] is String) || Profile["id"] == ""
				|| SeenIds.Has(Profile["id"])
			return false
		if Profile.Count > LLM_OPTION_MAX_RECORD_FIELDS
			return false
		Copy := Map()
		for Key, Item in Profile {
			if !_LLM_Option_TryConsumeString(Key, &AggregateChars, false)
				return false
			if (Key == "stop_sequences") {
				if !(Item is Array)
						|| Item.Length > LLM_OPTION_MAX_STOP_SEQUENCES
					return false
				Sequences := []
				for Sequence in Item {
					if !_LLM_Option_TryConsumeString(
							Sequence, &AggregateChars, false)
						return false
					Sequences.Push(Sequence)
				}
				Copy[Key] := Sequences
				continue
			}
			if IsObject(Item)
				return false
			if (Item is String)
					&& !_LLM_Option_TryConsumeString(Item, &AggregateChars)
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
	global LLM_OPTION_MAX_API_ENTRIES, LLM_OPTION_MAX_RECORD_FIELDS
	if !(Value is Array)
		return false
	if Value.Length > LLM_OPTION_MAX_API_ENTRIES
		return false
	Out := []
	SeenIds := Map()
	AggregateChars := 0
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
		FieldCount := 0
		for Key, Item in Properties {
			FieldCount += 1
			if FieldCount > LLM_OPTION_MAX_RECORD_FIELDS
				return false
			if !_LLM_Option_TryConsumeString(Key, &AggregateChars, false)
					|| IsObject(Item)
				return false
			if (Item is String)
					&& !_LLM_Option_TryConsumeString(Item, &AggregateChars)
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
	global LLM_OPTION_MAX_COLLECTION_ITEMS
	if !(Value is Map)
		return false
	if Value.Count > LLM_OPTION_MAX_COLLECTION_ITEMS
		return false
	Out := Map()
	Out.CaseSense := Value.CaseSense
	AggregateChars := 0
	for AppName, ProfileId in Value {
		if !_LLM_Option_TryConsumeString(AppName, &AggregateChars, false)
				|| !_LLM_Option_TryConsumeString(
					ProfileId, &AggregateChars, false)
			return false
		Out[AppName] := ProfileId
	}
	return Out
}

global LLM_OLLAMA_PORT_MIN := 1024
global LLM_OLLAMA_PORT_MAX := 65535

/** Normalizes the one Ollama port domain shared by menu, engine and client. */
LLM_Option_TryNormalizeOllamaPort(Value, &Normalized) {
	global LLM_OLLAMA_PORT_MIN, LLM_OLLAMA_PORT_MAX
	Normalized := false
	if !IsInteger(Value)
		return false
	try Candidate := Integer(Value)
	catch
		return false
	if Candidate < LLM_OLLAMA_PORT_MIN || Candidate > LLM_OLLAMA_PORT_MAX
		return false
	Normalized := Candidate
	return true
}

LLM_Option_TryNormalizeTemperature(Value, &Normalized) {
	Normalized := false
	if Value is String {
		; Only unsigned ordinary decimal notation is a stable configuration
		; image. IsNumber also accepts hexadecimal, exponent, sign and surrounding
		; whitespace, which changes meaning when persistence rewrites the value.
		if !RegExMatch(Value, "^(?:0|1|2)(?:\.\d{1,2})?$")
			return false
		try Candidate := Float(Value)
		catch
			return false
	} else if (Value is Integer) || (Value is Float) {
		try Candidate := Value + 0.0
		catch
			return false
	} else {
		return false
	}
	; This comparison also rejects non-finite/NaN candidates because they cannot
	; satisfy both ordered bounds.
	if !(Candidate >= 0.0 && Candidate <= 2.0)
		return false
	Rounded := Round(Candidate, 2)
	if Abs(Candidate - Rounded) > 0.0000000001
		return false
	Normalized := Format("{:.2f}", Rounded)
	return true
}

/**
 * Validates and normalizes one public LLM option. Unknown keys fail closed so
 * every caller must consciously extend this schema when it adds a new option.
 */
LLM_Option_TryNormalize(Key, Value, &Normalized) {
	static StringKeys := Map(
		"model", true, "profile_id", true, "language", true,
		"trigger_shortcut", true, "backend", true, "api_entry_id", true)
	; These are semantic consumer bounds, not merely storage types. Keep every
	; public integer in this one table so boot restore, menu persistence, runtime
	; publication and interactive setters cannot disagree. max_words=0 is the
	; documented unlimited sentinel; the finite ceiling bounds token arithmetic.
	static IntegerRanges := Map(
		"n_predictions", [1, 10],
		"min_words", [1, 20],
		"max_words", [0, 10000],
		"debounce_ms", [50, 10000],
		"ctx_chars", [50, 10000],
		"pred_indent", [-7, 7])
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
		AggregateChars := 0
		if !_LLM_Option_TryConsumeString(Value, &AggregateChars)
			return false
		Normalized := Value
		return true
	}
	if (Key == "temperature")
		return LLM_Option_TryNormalizeTemperature(Value, &Normalized)
	if (Key == "nav_modifiers" || Key == "val_modifiers") {
		Normalized := LLM_Option_NormalizeModifierString(Value)
		return Normalized is String
	}
	if (Key == "ollama_port")
		return LLM_Option_TryNormalizeOllamaPort(Value, &Normalized)
	if IntegerRanges.Has(Key) {
		if !(Value is Integer) && !(Value is Float)
			return false
		try Candidate := Integer(Value)
		catch
			return false
		if (Candidate != Value)
			return false
		Range := IntegerRanges[Key]
		if (Candidate < Range[1] || Candidate > Range[2])
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

/**
 * Converts a validated debounce delay into AutoHotkey's one-shot SetTimer
 * period. A negative configured value must never be negated into a repeating
 * timer; reject any value outside the same public option boundary first.
 */
LLM_Option_DebounceTimerPeriod(Value) {
	if !LLM_Option_TryNormalize("debounce_ms", Value, &Normalized)
		throw ValueError("Invalid LLM debounce delay.")
	return -Normalized
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
