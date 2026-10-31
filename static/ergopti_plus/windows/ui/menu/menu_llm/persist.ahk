; ui/menu/menu_llm/persist.ahk
; Tray state <-> Features["llm"] <-> config.toml (no menu handlers / hotkeys).

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk

; Foreign scalar/array preferences belong to this owner, not the Features map.
; Removing their overrides reuses this owner's existing load-time defaults.
; A key the Windows manifest also declares is already planned by the manifest
; scope, and a second row for it makes the scope refuse as overlapping owners.
_LLM_Menu_ScopeResetOperations(ScopeId, Mode) {
	if ScopeId != "llm" || !(Mode == "recommended" || Mode == "clear")
		throw ValueError("LLM persistence cannot reset another configuration scope.")
	Rows := []
	for Section, Keys in TomlConfigForeignOwnershipRegistry() {
		for Key, Owner in Keys {
			if Owner != "LLMMenu"
				continue
			if !(Section == "llm" || SubStr(Section, 1, 4) == "llm.")
				throw ValueError("An LLM preference escaped its owned configuration namespace.")
			if ManifestFindEntryByPath(Section . "." . Key) is Map
				continue
			Rows.Push({ Section: Section, Key: Key, Delete: true })
		}
	}
	return Rows
}

_LLM_Menu_ModifiersStringToArray(s) {
	global CHORD_SEPARATOR
	Canonical := LLM_Option_NormalizeModifierString(s)
	if !(Canonical is String)
		return false
	if (Canonical == "")
		return []
	return StrSplit(Canonical, CHORD_SEPARATOR)
}

_LLM_Menu_ModifiersArrayToString(arr) {
	Normalized := LLM_Option_NormalizeModifierArray(arr)
	if !(Normalized is Array)
		return false
	global CHORD_SEPARATOR
	Out := ""
	for Index, Value in Normalized
		Out .= (Index == 1 ? "" : CHORD_SEPARATOR) . Value
	return Out
}

_LLM_Menu_CoerceIniArray(raw) {
	if (raw is Array)
		return LLM_Option_NormalizeStringArray(raw)
	if !(raw is String)
		return false
	if (raw == "_" or raw == "")
		return []
	s := Trim(raw)
	if (s == "")
		return []
	if (SubStr(s, 1, 1) = "[" and SubStr(s, -1) = "]") {
		inner := SubStr(s, 2, StrLen(s) - 2)
		out := []
		for part in StrSplit(inner, ",") {
			part := Trim(part)
			part := Trim(part, '"')
			if (part != "")
				out.Push(part)
		}
		return LLM_Option_NormalizeStringArray(out)
	}
	return [s]
}

_LLM_Menu_SyncToFeatures(FeaturesTarget := 0, MenuState := 0) {
	global _LLM_Menu, Features, LLM_AGENT_SETTING_KEYS
	if !(MenuState is Map) {
		if !IsSet(_LLM_Menu)
			return false
		MenuState := _LLM_Menu
	}
	if !(FeaturesTarget is Map) {
		if !IsSet(Features) or !(Features is Map)
			return false
		FeaturesTarget := Features
	}
	if !FeaturesTarget.Has("llm") or !(FeaturesTarget["llm"] is Map)
		return false
	Validated := Map()
	for Key in ["enabled", "model", "backend", "profile_id", "n_predictions",
		"auto_profile_for_model", "temperature", "min_words", "max_words",
		"ctx_chars", ConfigLeaf.AUTO_RAISE_TEMP, ConfigLeaf.RESET_ON_NAV, ConfigLeaf.SHOW_INFO_BAR,
		"streaming", "show_all_at_once", ConfigLeaf.PRED_INDENT, ConfigLeaf.DEBOUNCE_MS, ConfigLeaf.MIN_REQUEST_INTERVAL_MS,
		ConfigLeaf.INSTANT_ON_WORD_END, ConfigLeaf.AFTER_HOTSTRING, ConfigLeaf.INLINE_AUTOTYPE,
		"disable_url_bars", "disable_password_fields", ConfigLeaf.VAL_MODIFIERS] {
		if !MenuState.Has(Key)
				|| !LLM_Option_TryNormalize(Key, MenuState[Key], &Normalized) {
			try LoggerError("LLM",
				"Refusing to sync invalid option '{1}' into Features.", Key)
			return false
		}
		Validated[Key] := Normalized
	}
	Validated["streaming"] := LLM_EffectiveStreaming(
		Validated["backend"], Validated["streaming"])
	; The AI agent's settings ride along once the menu state carries them
	AgentValues := Map()
	for Key in LLM_AGENT_SETTING_KEYS {
		if !MenuState.Has(Key)
			continue
		if !LLM_Option_TryNormalize(Key, MenuState[Key], &Normalized) {
			try LoggerError("LLM",
				"Refusing to sync invalid option '{1}' into Features.", Key)
			return false
		}
		AgentValues[Key] := Normalized
	}
	ValModifiers := _LLM_Menu_ModifiersStringToArray(Validated[ConfigLeaf.VAL_MODIFIERS])
	if !(ValModifiers is Array) {
		try LoggerError("LLM",
			"Refusing to sync invalid validation modifiers into Features.")
		return false
	}
	llm := FeaturesTarget["llm"]
	llm["enabled"]                            := Validated["enabled"]
	llm["models"]["ollama"]                   := Validated["model"]
	llm["models"]["selected"]                 := Validated["backend"]
	llm["profiles"]["active"]                 := Validated["profile_id"]
	llm["profiles"][ConfigLeaf.NUM_PREDICTIONS]        := Validated["n_predictions"]
	llm["profiles"]["auto_profile_for_model"] := Validated["auto_profile_for_model"]
	llm["generation"]["temperature"]          := Float(Validated["temperature"])
	llm["generation"]["min_words"]            := Validated["min_words"]
	llm["generation"]["max_words"]            := Validated["max_words"]
	llm["generation"]["context_length"]       := Validated["ctx_chars"]
	llm["generation"][ConfigLeaf.AUTO_RAISE_TEMP]      := Validated[ConfigLeaf.AUTO_RAISE_TEMP]
	llm["generation"][ConfigLeaf.RESET_ON_NAV]         := Validated[ConfigLeaf.RESET_ON_NAV]
	llm["display"][ConfigLeaf.SHOW_INFO_BAR]           := Validated[ConfigLeaf.SHOW_INFO_BAR]
	llm["display"]["streaming"]               := Validated["streaming"]
	llm["display"][ConfigLeaf.STREAMING_MULTI]         := LLM_DisplayProgressive(Validated["show_all_at_once"])
	llm["display"][ConfigLeaf.PRED_INDENT]             := Validated[ConfigLeaf.PRED_INDENT]
	llm["trigger"][ConfigLeaf.DEBOUNCE_MS]             := Validated[ConfigLeaf.DEBOUNCE_MS]
	llm["trigger"][ConfigLeaf.MIN_REQUEST_INTERVAL_MS] := Validated[ConfigLeaf.MIN_REQUEST_INTERVAL_MS]
	llm["trigger"][ConfigLeaf.INSTANT_ON_WORD_END]     := Validated[ConfigLeaf.INSTANT_ON_WORD_END]
	llm["trigger"][ConfigLeaf.AFTER_HOTSTRING]         := Validated[ConfigLeaf.AFTER_HOTSTRING]
	llm["trigger"][ConfigLeaf.INLINE_AUTOTYPE]         := Validated[ConfigLeaf.INLINE_AUTOTYPE]
	llm["trigger"][ConfigLeaf.URL_BAR_FILTER_ENABLED]  := Validated["disable_url_bars"]
	llm["trigger"][ConfigLeaf.SECURE_FILTER_ENABLED]   := Validated["disable_password_fields"]
	llm["navigation"][ConfigLeaf.VAL_MODIFIERS]          := ValModifiers
	for Key, Value in AgentValues
		llm[Key] := Value
	return true
}

_LLM_Menu_AppendPersistedUpdates(Updates, MenuState := 0) {
	global _LLM_Menu
	if !(Updates is Array)
		return false
	if !(MenuState is Map)
		MenuState := _LLM_Menu
	if MenuState.Has("api_entry_id")
			&& !LLM_Option_TryNormalize("api_entry_id",
				MenuState["api_entry_id"], &ApiEntryId)
		return false
	if !MenuState.Has("user_profiles")
		return false
	NavModifiersText := false
	if !MenuState.Has(ConfigLeaf.NAV_MODIFIERS)
			|| !LLM_Option_TryNormalize(ConfigLeaf.NAV_MODIFIERS,
				MenuState[ConfigLeaf.NAV_MODIFIERS], &NavModifiersText)
		return false
	NavModifiers := _LLM_Menu_ModifiersStringToArray(NavModifiersText)
	if !(NavModifiers is Array)
		return false
	Apps := MenuState.Has(ConfigLeaf.DISABLED_APPS) ? MenuState[ConfigLeaf.DISABLED_APPS] : []
	if !LLM_Option_TryNormalize(ConfigLeaf.DISABLED_APPS, Apps, &Apps)
		return false
	if !LLM_Option_TryNormalize("user_profiles",
			MenuState["user_profiles"], &Profiles)
		return false
	ProfilesPayload := _LLM_Menu_SerializeUserProfiles(Profiles)
	if !(ProfilesPayload is String)
		return false
	if MenuState.Has("ollama_port")
			&& !LLM_Option_TryNormalize("ollama_port",
				MenuState["ollama_port"], &OllamaPort)
		return false

	; Ollama port lives under [llm] as a flat key — it is NOT in the Features
	; schema, so it round-trips via the TOML write here + the cache read in the
	; saved-opts loader, not via _LLM_Menu_SyncToFeatures.
	if MenuState.Has("ollama_port")
		Updates.Push({ Section: "llm", Key: "ollama_port", Value: OllamaPort })
	if MenuState.Has("api_entry_id")
		Updates.Push({ Section: "llm", Key: "api_entry_id", Value: ApiEntryId })
	Updates.Push({ Section: "llm", Key: "user_profiles", Value: ProfilesPayload })
	Updates.Push({ Section: ConfigKey.LLM_NAVIGATION, Key: ConfigLeaf.NAV_MODIFIERS,
		Value: NavModifiers })
	Updates.Push({ Section: ConfigKey.LLM_TRIGGER, Key: ConfigLeaf.DISABLED_APPS, Value: Apps })
	return true
}

_LLM_Menu_LogInvalidPersistedOption(Key, Value := unset) {
	if IsSet(Value) {
		DisplayValue := (Value is String) || (Value is Integer) || (Value is Float)
			? String(Value) : "<" . Type(Value) . ">"
		try LoggerError("LLM",
			"Persisted option '{1}' has invalid value '{2}'; keeping the validated default.",
			Key, DisplayValue)
		return
	}
	try LoggerError("LLM",
		"Persisted option '{1}' has an invalid type, shape, or value; keeping the validated default.",
		Key)
}

_LLM_Menu_PutValidatedPersistedOption(Opts, Key, Value, SourceKey := "") {
	if !LLM_Option_TryNormalize(Key, Value, &Normalized) {
		_LLM_Menu_LogInvalidPersistedOption(
			SourceKey != "" ? SourceKey : Key, Value)
		return false
	}
	Opts[Key] := Normalized
	return true
}

_LLM_Menu_LoadAppProfileOverridesFromCache(SavedOpts, Cache) {
	if !(SavedOpts is Map) || !(Cache is Map)
		return false
	Raw := IniCacheGet(Cache, "llm", ConfigLeaf.APP_PROFILE_OVERRIDES)
	if (Raw is String) {
		if (Raw == "_" || Raw == "")
			return true
		Overrides := _LLM_Menu_DeserializeAppProfileOverrides(Raw)
		if (Overrides is Map) {
			SavedOpts[ConfigLeaf.APP_PROFILE_OVERRIDES] := Overrides
			return true
		}
		LoggerError("LLM",
			"Persisted app-profile overrides are malformed; refusing partial restore.")
		return false
	}
	LoggerError("LLM",
		"Persisted app-profile overrides have the wrong type; refusing restore.")
	return false
}

LLM_Menu_BuildSavedOpts(Cache := unset) {
	global Features, LLM_AGENT_SETTING_KEYS
	opts := Map()
	if !IsSet(Features) or !Features.Has("llm")
		return opts
	llm := Features["llm"]
	for Entry in [
		["enabled", llm["enabled"], "llm.enabled"],
		["model", llm["models"]["ollama"], ConfigKey.LLM_MODELS_OLLAMA],
		["backend", llm["models"]["selected"], ConfigKey.LLM_MODELS_SELECTED],
		["profile_id", llm["profiles"]["active"], ConfigKey.LLM_PROFILES_ACTIVE],
		["n_predictions", llm["profiles"][ConfigLeaf.NUM_PREDICTIONS], ConfigKey.LLM_PROFILES_NUM_PREDICTIONS],
		["auto_profile_for_model", llm["profiles"]["auto_profile_for_model"], ConfigKey.LLM_PROFILES_AUTO_PROFILE_FOR_MODEL],
		["min_words", llm["generation"]["min_words"], ConfigKey.LLM_GENERATION_MIN_WORDS],
		["max_words", llm["generation"]["max_words"], ConfigKey.LLM_GENERATION_MAX_WORDS],
		["ctx_chars", llm["generation"]["context_length"], "llm.generation.context_length"],
		[ConfigLeaf.DEBOUNCE_MS, llm["trigger"][ConfigLeaf.DEBOUNCE_MS], ConfigKey.LLM_TRIGGER_DEBOUNCE_MS],
		[ConfigLeaf.MIN_REQUEST_INTERVAL_MS, llm["trigger"][ConfigLeaf.MIN_REQUEST_INTERVAL_MS], ConfigKey.LLM_TRIGGER_MIN_REQUEST_INTERVAL_MS],
		[ConfigLeaf.INSTANT_ON_WORD_END, llm["trigger"][ConfigLeaf.INSTANT_ON_WORD_END], ConfigKey.LLM_TRIGGER_INSTANT_ON_WORD_END],
		[ConfigLeaf.AFTER_HOTSTRING, llm["trigger"][ConfigLeaf.AFTER_HOTSTRING], ConfigKey.LLM_TRIGGER_AFTER_HOTSTRING],
		[ConfigLeaf.RESET_ON_NAV, llm["generation"][ConfigLeaf.RESET_ON_NAV], ConfigKey.LLM_GENERATION_RESET_ON_NAV],
		[ConfigLeaf.AUTO_RAISE_TEMP, llm["generation"][ConfigLeaf.AUTO_RAISE_TEMP], ConfigKey.LLM_GENERATION_AUTO_RAISE_TEMP],
		[ConfigLeaf.INLINE_AUTOTYPE, llm["trigger"][ConfigLeaf.INLINE_AUTOTYPE], ConfigKey.LLM_TRIGGER_INLINE_AUTOTYPE],
		[ConfigLeaf.SHOW_INFO_BAR, llm["display"][ConfigLeaf.SHOW_INFO_BAR], ConfigKey.LLM_DISPLAY_SHOW_INFO_BAR],
		["streaming", llm["display"]["streaming"], ConfigKey.LLM_DISPLAY_STREAMING],
		["show_all_at_once", llm["display"][ConfigLeaf.STREAMING_MULTI], ConfigKey.LLM_DISPLAY_STREAMING_MULTI],
		[ConfigLeaf.PRED_INDENT, llm["display"][ConfigLeaf.PRED_INDENT], ConfigKey.LLM_DISPLAY_PRED_INDENT],
		["disable_url_bars", llm["trigger"][ConfigLeaf.URL_BAR_FILTER_ENABLED], ConfigKey.LLM_TRIGGER_URL_BAR_FILTER_ENABLED],
		["disable_password_fields", llm["trigger"][ConfigLeaf.SECURE_FILTER_ENABLED], ConfigKey.LLM_TRIGGER_SECURE_FILTER_ENABLED]
	]
		_LLM_Menu_PutValidatedPersistedOption(
			opts, Entry[1], Entry[2], Entry[3])
	; Features stores progressive display; the native engine retains show-all.
	if opts.Has("show_all_at_once")
		opts["show_all_at_once"] := LLM_DisplayShowAll(opts["show_all_at_once"])
	TemperatureRaw := llm["generation"]["temperature"]
	if (TemperatureRaw is Integer) || (TemperatureRaw is Float)
		_LLM_Menu_PutValidatedPersistedOption(opts, "temperature",
			Format("{:.2f}", TemperatureRaw + 0), "llm.generation.temperature")
	else
		_LLM_Menu_LogInvalidPersistedOption("llm.generation.temperature")
	for Key in LLM_AGENT_SETTING_KEYS {
		if llm.Has(Key)
			_LLM_Menu_PutValidatedPersistedOption(opts, Key, llm[Key], "llm." . Key)
	}
	val_raw := llm["navigation"][ConfigLeaf.VAL_MODIFIERS]
	ValModifiers := (val_raw is Array)
		? _LLM_Menu_ModifiersArrayToString(val_raw)
		: ((val_raw is String)
			? _LLM_Menu_ModifiersArrayToString(
				_LLM_Menu_ModifiersStringToArray(val_raw)) : false)
	if (ValModifiers is String)
		opts[ConfigLeaf.VAL_MODIFIERS] := ValModifiers
	else
		_LLM_Menu_LogInvalidPersistedOption(ConfigKey.LLM_NAVIGATION_VAL_MODIFIERS)
	if IsSet(Cache) {
		raw := IniCacheGet(Cache, "llm", "ollama_port")
		; Earlier releases saved the stock port, which now belongs to the user's
		; own Ollama: such a value is dropped once, as on macOS, and is no error.
		if LLM_Option_IsStockOllamaPort(raw)
			LoggerInfo("LLM", "Saved Ollama port {1} is the stock port; Ergopti's own Ollama keeps its port.", raw)
		else if !((raw is String) && raw == "_")
			_LLM_Menu_PutValidatedPersistedOption(
				opts, "ollama_port", raw, "llm.ollama_port")
		raw := IniCacheGet(Cache, "llm", "api_entry_id")
		if !((raw is String) && raw == "_") {
			_LLM_Menu_PutValidatedPersistedOption(
				opts, "api_entry_id", raw, "llm.api_entry_id")
		}
		raw := IniCacheGet(Cache, "llm", "user_profiles")
		if !((raw is String) && raw == "_") {
			Profiles := (raw is String)
				? _LLM_Menu_DeserializeUserProfiles(raw) : false
			if (Profiles is Array)
				_LLM_Menu_PutValidatedPersistedOption(
					opts, "user_profiles", Profiles, ConfigKey.LLM_USER_PROFILES)
			else
				_LLM_Menu_LogInvalidPersistedOption(ConfigKey.LLM_USER_PROFILES)
		}
		if !ConfigTomlTryReadBootValue(Cache, ConfigKey.LLM, ConfigLeaf.ONBOARDING_SEEN, &raw)
			raw := IniCacheGet(Cache, "llm", ConfigLeaf.ONBOARDING_SEEN)
		if !((raw is String) && raw == "_") {
			if LLM_Option_TryParseConfigBoolean(raw, &OnboardingSeen)
				opts[ConfigLeaf.ONBOARDING_SEEN] := OnboardingSeen
			else
				_LLM_Menu_LogInvalidPersistedOption(ConfigKey.LLM_ONBOARDING_SEEN)
		}
		if !ConfigTomlTryReadBootValue(Cache, ConfigKey.LLM_NAVIGATION, ConfigLeaf.VAL_MODIFIERS, &raw)
			raw := IniCacheGet(Cache, ConfigKey.LLM_NAVIGATION, ConfigLeaf.VAL_MODIFIERS)
		if !((raw is String) && raw == "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			Value := (arr is Array) ? _LLM_Menu_ModifiersArrayToString(arr) : false
			if (Value is String)
				opts[ConfigLeaf.VAL_MODIFIERS] := Value
			else {
				if opts.Has(ConfigLeaf.VAL_MODIFIERS)
					opts.Delete(ConfigLeaf.VAL_MODIFIERS)
				_LLM_Menu_LogInvalidPersistedOption(ConfigKey.LLM_NAVIGATION_VAL_MODIFIERS)
			}
		}
		if !ConfigTomlTryReadBootValue(Cache, ConfigKey.LLM_NAVIGATION, ConfigLeaf.NAV_MODIFIERS, &raw)
			raw := IniCacheGet(Cache, ConfigKey.LLM_NAVIGATION, ConfigLeaf.NAV_MODIFIERS)
		if !((raw is String) && raw == "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			Value := (arr is Array) ? _LLM_Menu_ModifiersArrayToString(arr) : false
			if (Value is String)
				opts[ConfigLeaf.NAV_MODIFIERS] := Value
			else
				_LLM_Menu_LogInvalidPersistedOption(ConfigKey.LLM_NAVIGATION_NAV_MODIFIERS)
		}
		if !ConfigTomlTryReadBootValue(Cache, ConfigKey.LLM_TRIGGER, ConfigLeaf.DISABLED_APPS, &raw)
			raw := IniCacheGet(Cache, ConfigKey.LLM_TRIGGER, ConfigLeaf.DISABLED_APPS)
		if !((raw is String) && raw == "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			arr := (arr is Array) ? LLM_Option_NormalizeStringArray(arr, true) : false
			if (arr is Array)
				opts[ConfigLeaf.DISABLED_APPS] := arr
			else
				_LLM_Menu_LogInvalidPersistedOption(ConfigKey.LLM_TRIGGER_DISABLED_APPS)
		}
	}
	return opts
}
