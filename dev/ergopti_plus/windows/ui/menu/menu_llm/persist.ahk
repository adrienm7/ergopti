; ui/menu/menu_llm/persist.ahk
; Tray state <-> Features["llm"] <-> config.toml (no menu handlers / hotkeys).

#Requires AutoHotkey v2.0

_LLM_Menu_ModifiersStringToArray(s) {
	s := Trim(String(s))
	if (s == "")
		return []
	out := []
	for part in StrSplit(s, ",") {
		part := Trim(part)
		if (part != "")
			out.Push(part)
	}
	return out
}

_LLM_Menu_ModifiersArrayToString(arr) {
	if !(arr is Array) || arr.Length = 0
		return ""
	out := ""
	for i, v in arr
		out .= (i > 1 ? "," : "") . String(v)
	return out
}

_LLM_Menu_CoerceIniArray(raw) {
	if (raw is Array)
		return raw
	if (raw = "_" or raw == "")
		return []
	s := Trim(String(raw))
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
		return out
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
	llm := FeaturesTarget["llm"]
	llm["enabled"]                            := MenuState["enabled"]
	llm["models"]["ollama"]                   := MenuState["model"]
	llm["models"]["selected"]                 := MenuState["backend"]
	llm["profiles"]["active"]                 := MenuState["profile_id"]
	llm["profiles"]["num_predictions"]        := MenuState["n_predictions"]
	llm["profiles"]["auto_profile_for_model"]   := MenuState["auto_profile_for_model"]
	llm["generation"]["temperature"]          := Float(MenuState["temperature"])
	llm["generation"]["min_words"]            := MenuState["min_words"]
	llm["generation"]["max_words"]            := MenuState["max_words"]
	llm["generation"]["context_length"]       := MenuState["ctx_chars"]
	llm["generation"]["auto_raise_temp"]        := MenuState["auto_raise_temp"]
	llm["generation"]["reset_on_nav"]           := MenuState["reset_on_nav"]
	llm["display"]["show_info_bar"]             := MenuState["show_info_bar"]
	llm["display"]["streaming"]                 := MenuState["streaming"]
	llm["display"]["streaming_multi"]           := MenuState["show_all_at_once"]
	llm["display"]["pred_indent"]               := MenuState["pred_indent"]
	llm["trigger"]["debounce_ms"]               := MenuState["debounce_ms"]
	llm["trigger"]["instant_on_word_end"]         := MenuState["instant_on_word_end"]
	llm["trigger"]["after_hotstring"]           := MenuState["after_hotstring"]
	llm["trigger"]["inline_autotype"]           := MenuState["inline_autotype"]
	llm["trigger"]["url_bar_filter_enabled"]    := MenuState["disable_url_bars"]
	llm["trigger"]["secure_filter_enabled"]     := MenuState["disable_password_fields"]
	llm["navigation"]["val_modifiers"]          := _LLM_Menu_ModifiersStringToArray(MenuState["val_modifiers"])
	return true
}

_LLM_Menu_AppendPersistedUpdates(Updates, MenuState := 0) {
	global _LLM_Menu
	if !(MenuState is Map)
		MenuState := _LLM_Menu
	Updates.Push({ Section: "llm", Key: "trigger_shortcut", Value: MenuState["trigger_shortcut"] })
	; Ollama port lives under [llm] as a flat key (like trigger_shortcut) — it is
	; NOT in the Features schema, so it round-trips via the TOML write here + the
	; cache read in the saved-opts loader, not via _LLM_Menu_SyncToFeatures.
	if MenuState.Has("ollama_port")
		Updates.Push({ Section: "llm", Key: "ollama_port", Value: MenuState["ollama_port"] })
	if MenuState.Has("api_entry_id")
		Updates.Push({ Section: "llm", Key: "api_entry_id", Value: MenuState["api_entry_id"] })
	ProfilesPayload := _LLM_Menu_SerializeUserProfiles(MenuState["user_profiles"])
	if !(ProfilesPayload is String)
		return false
	Updates.Push({ Section: "llm", Key: "user_profiles", Value: ProfilesPayload })
	Updates.Push({ Section: "llm.navigation", Key: "nav_modifiers",
		Value: _LLM_Menu_ModifiersStringToArray(MenuState["nav_modifiers"]) })
	apps := MenuState.Has("disabled_apps") ? MenuState["disabled_apps"] : []
	if !(apps is Array)
		apps := []
	Updates.Push({ Section: "llm.trigger", Key: "disabled_apps", Value: apps })
}

LLM_Menu_BuildSavedOpts(Cache := unset) {
	global Features
	opts := Map()
	if !IsSet(Features) or !Features.Has("llm")
		return opts
	llm := Features["llm"]
	opts["enabled"]                := llm["enabled"]
	opts["model"]                  := llm["models"]["ollama"]
	opts["backend"]                := llm["models"]["selected"]
	opts["profile_id"]             := llm["profiles"]["active"]
	opts["n_predictions"]          := llm["profiles"]["num_predictions"]
	opts["auto_profile_for_model"] := llm["profiles"]["auto_profile_for_model"]
	opts["temperature"]            := Format("{:.2f}", Float(llm["generation"]["temperature"]) + 0)
	opts["min_words"]              := llm["generation"]["min_words"]
	opts["max_words"]              := llm["generation"]["max_words"]
	opts["ctx_chars"]              := llm["generation"]["context_length"]
	opts["debounce_ms"]            := llm["trigger"]["debounce_ms"]
	opts["instant_on_word_end"]    := llm["trigger"]["instant_on_word_end"]
	opts["after_hotstring"]        := llm["trigger"]["after_hotstring"]
	opts["reset_on_nav"]           := llm["generation"]["reset_on_nav"]
	opts["auto_raise_temp"]        := llm["generation"]["auto_raise_temp"]
	opts["inline_autotype"]        := llm["trigger"]["inline_autotype"]
	opts["show_info_bar"]          := llm["display"]["show_info_bar"]
	opts["streaming"]              := llm["display"]["streaming"]
	opts["show_all_at_once"]       := llm["display"]["streaming_multi"]
	opts["pred_indent"]            := llm["display"]["pred_indent"]
	opts["disable_url_bars"]       := llm["trigger"]["url_bar_filter_enabled"]
	opts["disable_password_fields"] := llm["trigger"]["secure_filter_enabled"]
	val_raw := llm["navigation"]["val_modifiers"]
	opts["val_modifiers"]          := (val_raw is Array)
		? _LLM_Menu_ModifiersArrayToString(val_raw) : String(val_raw)
	if IsSet(Cache) {
		raw := IniCacheGet(Cache, "llm", "trigger_shortcut")
		if (raw != "_")
			opts["trigger_shortcut"] := String(raw)
		raw := IniCacheGet(Cache, "llm", "ollama_port")
		if (raw != "_" and IsInteger(raw))
			opts["ollama_port"] := Integer(raw)
		raw := IniCacheGet(Cache, "llm", "api_entry_id")
		if (raw != "_")
			opts["api_entry_id"] := String(raw)
		raw := IniCacheGet(Cache, "llm", "user_profiles")
		if (raw != "_") {
			Profiles := _LLM_Menu_DeserializeUserProfiles(String(raw))
			if (Profiles is Array)
				opts["user_profiles"] := Profiles
			else
				LoggerError("LLM", "Persisted custom profiles are malformed; refusing to publish them.")
		}
		raw := IniCacheGet(Cache, "llm.navigation", "val_modifiers")
		if (raw != "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			opts["val_modifiers"] := _LLM_Menu_ModifiersArrayToString(arr)
		}
		raw := IniCacheGet(Cache, "llm.navigation", "nav_modifiers")
		if (raw != "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			opts["nav_modifiers"] := _LLM_Menu_ModifiersArrayToString(arr)
		}
		raw := IniCacheGet(Cache, "llm.trigger", "disabled_apps")
		if (raw != "_") {
			arr := _LLM_Menu_CoerceIniArray(raw)
			if (arr.Length > 0)
				opts["disabled_apps"] := arr
		}
	}
	return opts
}
