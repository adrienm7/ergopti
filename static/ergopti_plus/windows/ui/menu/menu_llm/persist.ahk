; ui/menu/menu_llm/persist.ahk
; Tray state <-> Features["llm"] <-> config.toml (no menu handlers / hotkeys).

#Requires AutoHotkey v2.0

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
	global _LLM_Menu, Features
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
		"ctx_chars", "auto_raise_temp", "reset_on_nav", "show_info_bar",
		"streaming", "show_all_at_once", "pred_indent", "debounce_ms",
		"instant_on_word_end", "after_hotstring", "inline_autotype",
		"disable_url_bars", "disable_password_fields", "val_modifiers"] {
		if !MenuState.Has(Key)
				|| !LLM_Option_TryNormalize(Key, MenuState[Key], &Normalized) {
			try LoggerError("LLM",
				"Refusing to sync invalid option '{1}' into Features.", Key)
			return false
		}
		Validated[Key] := Normalized
	}
	ValModifiers := _LLM_Menu_ModifiersStringToArray(Validated["val_modifiers"])
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
	llm["profiles"]["num_predictions"]        := Validated["n_predictions"]
	llm["profiles"]["auto_profile_for_model"] := Validated["auto_profile_for_model"]
	llm["generation"]["temperature"]          := Float(Validated["temperature"])
	llm["generation"]["min_words"]            := Validated["min_words"]
	llm["generation"]["max_words"]            := Validated["max_words"]
	llm["generation"]["context_length"]       := Validated["ctx_chars"]
	llm["generation"]["auto_raise_temp"]      := Validated["auto_raise_temp"]
	llm["generation"]["reset_on_nav"]         := Validated["reset_on_nav"]
	llm["display"]["show_info_bar"]           := Validated["show_info_bar"]
	llm["display"]["streaming"]               := Validated["streaming"]
	llm["display"]["streaming_multi"]         := Validated["show_all_at_once"]
	llm["display"]["pred_indent"]             := Validated["pred_indent"]
	llm["trigger"]["debounce_ms"]             := Validated["debounce_ms"]
	llm["trigger"]["instant_on_word_end"]     := Validated["instant_on_word_end"]
	llm["trigger"]["after_hotstring"]         := Validated["after_hotstring"]
	llm["trigger"]["inline_autotype"]         := Validated["inline_autotype"]
	llm["trigger"]["url_bar_filter_enabled"]  := Validated["disable_url_bars"]
	llm["trigger"]["secure_filter_enabled"]   := Validated["disable_password_fields"]
	llm["navigation"]["val_modifiers"]          := ValModifiers
	return true
}

_LLM_Menu_AppendPersistedUpdates(Updates, MenuState := 0) {
	global _LLM_Menu
	if !(Updates is Array)
		return false
	if !(MenuState is Map)
		MenuState := _LLM_Menu
	if !MenuState.Has("trigger_shortcut")
			|| !LLM_Option_TryNormalize("trigger_shortcut",
				MenuState["trigger_shortcut"], &TriggerShortcut)
		return false
	if MenuState.Has("api_entry_id")
			&& !LLM_Option_TryNormalize("api_entry_id",
				MenuState["api_entry_id"], &ApiEntryId)
		return false
	if !MenuState.Has("user_profiles")
		return false
	NavModifiersText := false
	if !MenuState.Has("nav_modifiers")
			|| !LLM_Option_TryNormalize("nav_modifiers",
				MenuState["nav_modifiers"], &NavModifiersText)
		return false
	NavModifiers := _LLM_Menu_ModifiersStringToArray(NavModifiersText)
	if !(NavModifiers is Array)
		return false
	Apps := MenuState.Has("disabled_apps") ? MenuState["disabled_apps"] : []
	if !LLM_Option_TryNormalize("disabled_apps", Apps, &Apps)
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

	Updates.Push({ Section: "llm", Key: "trigger_shortcut", Value: TriggerShortcut })
	; Ollama port lives under [llm] as a flat key (like trigger_shortcut) — it is
	; NOT in the Features schema, so it round-trips via the TOML write here + the
	; cache read in the saved-opts loader, not via _LLM_Menu_SyncToFeatures.
	if MenuState.Has("ollama_port")
		Updates.Push({ Section: "llm", Key: "ollama_port", Value: OllamaPort })
	if MenuState.Has("api_entry_id")
		Updates.Push({ Section: "llm", Key: "api_entry_id", Value: ApiEntryId })
	Updates.Push({ Section: "llm", Key: "user_profiles", Value: ProfilesPayload })
	Updates.Push({ Section: "llm.navigation", Key: "nav_modifiers",
		Value: NavModifiers })
	Updates.Push({ Section: "llm.trigger", Key: "disabled_apps", Value: Apps })
	return true
}

_LLM_Menu_LogInvalidPersistedOption(Key) {
	try LoggerError("LLM",
		"Persisted option '{1}' has the wrong type or element shape; keeping the validated default.",
		Key)
}

_LLM_Menu_PutValidatedPersistedOption(Opts, Key, Value, SourceKey := "") {
	if !LLM_Option_TryNormalize(Key, Value, &Normalized) {
		_LLM_Menu_LogInvalidPersistedOption(SourceKey != "" ? SourceKey : Key)
		return false
	}
	Opts[Key] := Normalized
	return true
}

LLM_Menu_BuildSavedOpts(Cache := unset) {
	global Features
	opts := Map()
	if !IsSet(Features) or !Features.Has("llm")
		return opts
	llm := Features["llm"]
	for Entry in [
		["enabled", llm["enabled"], "llm.enabled"],
		["model", llm["models"]["ollama"], "llm.models.ollama"],
		["backend", llm["models"]["selected"], "llm.models.selected"],
		["profile_id", llm["profiles"]["active"], "llm.profiles.active"],
		["n_predictions", llm["profiles"]["num_predictions"], "llm.profiles.num_predictions"],
		["auto_profile_for_model", llm["profiles"]["auto_profile_for_model"], "llm.profiles.auto_profile_for_model"],
		["min_words", llm["generation"]["min_words"], "llm.generation.min_words"],
		["max_words", llm["generation"]["max_words"], "llm.generation.max_words"],
		["ctx_chars", llm["generation"]["context_length"], "llm.generation.context_length"],
		["debounce_ms", llm["trigger"]["debounce_ms"], "llm.trigger.debounce_ms"],
		["instant_on_word_end", llm["trigger"]["instant_on_word_end"], "llm.trigger.instant_on_word_end"],
		["after_hotstring", llm["trigger"]["after_hotstring"], "llm.trigger.after_hotstring"],
		["reset_on_nav", llm["generation"]["reset_on_nav"], "llm.generation.reset_on_nav"],
		["auto_raise_temp", llm["generation"]["auto_raise_temp"], "llm.generation.auto_raise_temp"],
		["inline_autotype", llm["trigger"]["inline_autotype"], "llm.trigger.inline_autotype"],
		["show_info_bar", llm["display"]["show_info_bar"], "llm.display.show_info_bar"],
		["streaming", llm["display"]["streaming"], "llm.display.streaming"],
		["show_all_at_once", llm["display"]["streaming_multi"], "llm.display.streaming_multi"],
		["pred_indent", llm["display"]["pred_indent"], "llm.display.pred_indent"],
		["disable_url_bars", llm["trigger"]["url_bar_filter_enabled"], "llm.trigger.url_bar_filter_enabled"],
		["disable_password_fields", llm["trigger"]["secure_filter_enabled"], "llm.trigger.secure_filter_enabled"]
	]
		_LLM_Menu_PutValidatedPersistedOption(
			opts, Entry[1], Entry[2], Entry[3])
	TemperatureRaw := llm["generation"]["temperature"]
	if (TemperatureRaw is Integer) || (TemperatureRaw is Float)
		_LLM_Menu_PutValidatedPersistedOption(opts, "temperature",
			Format("{:.2f}", TemperatureRaw + 0), "llm.generation.temperature")
	else
		_LLM_Menu_LogInvalidPersistedOption("llm.generation.temperature")
	val_raw := llm["navigation"]["val_modifiers"]
	ValModifiers := (val_raw is Array)
		? _LLM_Menu_ModifiersArrayToString(val_raw)
		: ((val_raw is String)
			? _LLM_Menu_ModifiersArrayToString(
				_LLM_Menu_ModifiersStringToArray(val_raw)) : false)
	if (ValModifiers is String)
		opts["val_modifiers"] := ValModifiers
	else
		_LLM_Menu_LogInvalidPersistedOption("llm.navigation.val_modifiers")
	if IsSet(Cache) {
		raw := IniCacheGet(Cache, "llm", "trigger_shortcut")
		if !((raw is String) && raw == "_") {
			_LLM_Menu_PutValidatedPersistedOption(
				opts, "trigger_shortcut", raw, "llm.trigger_shortcut")
		}
		raw := IniCacheGet(Cache, "llm", "ollama_port")
		if !((raw is String) && raw == "_")
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
					opts, "user_profiles", Profiles, "llm.user_profiles")
			else
				_LLM_Menu_LogInvalidPersistedOption("llm.user_profiles")
		}
		raw := IniCacheGet(Cache, "llm", "onboarding_seen")
		if !((raw is String) && raw == "_") {
			if LLM_Option_TryParseConfigBoolean(raw, &OnboardingSeen)
				opts["onboarding_seen"] := OnboardingSeen
			else
				_LLM_Menu_LogInvalidPersistedOption("llm.onboarding_seen")
		}
		raw := IniCacheGet(Cache, "llm.navigation", "val_modifiers")
		if !((raw is String) && raw == "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			Value := (arr is Array) ? _LLM_Menu_ModifiersArrayToString(arr) : false
			if (Value is String)
				opts["val_modifiers"] := Value
			else {
				if opts.Has("val_modifiers")
					opts.Delete("val_modifiers")
				_LLM_Menu_LogInvalidPersistedOption("llm.navigation.val_modifiers")
			}
		}
		raw := IniCacheGet(Cache, "llm.navigation", "nav_modifiers")
		if !((raw is String) && raw == "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			Value := (arr is Array) ? _LLM_Menu_ModifiersArrayToString(arr) : false
			if (Value is String)
				opts["nav_modifiers"] := Value
			else
				_LLM_Menu_LogInvalidPersistedOption("llm.navigation.nav_modifiers")
		}
		raw := IniCacheGet(Cache, "llm.trigger", "disabled_apps")
		if !((raw is String) && raw == "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			arr := (arr is Array) ? LLM_Option_NormalizeStringArray(arr, true) : false
			if (arr is Array)
				opts["disabled_apps"] := arr
			else
				_LLM_Menu_LogInvalidPersistedOption("llm.trigger.disabled_apps")
		}
	}
	return opts
}
