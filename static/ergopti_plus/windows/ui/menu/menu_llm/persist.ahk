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

_LLM_Menu_SyncToFeatures() {
	global _LLM_Menu, Features
	if !IsSet(Features) or !IsSet(_LLM_Menu)
		return
	if !Features.Has("llm")
		return
	llm := Features["llm"]
	llm["enabled"]                            := _LLM_Menu["enabled"]
	llm["models"]["ollama"]                   := _LLM_Menu["model"]
	llm["models"]["selected"]                 := _LLM_Menu["backend"]
	llm["profiles"]["active"]                 := _LLM_Menu["profile_id"]
	llm["profiles"]["num_predictions"]        := _LLM_Menu["n_predictions"]
	llm["profiles"]["auto_profile_for_model"]   := _LLM_Menu["auto_profile_for_model"]
	llm["generation"]["temperature"]          := Float(_LLM_Menu["temperature"])
	llm["generation"]["min_words"]            := _LLM_Menu["min_words"]
	llm["generation"]["max_words"]            := _LLM_Menu["max_words"]
	llm["generation"]["context_length"]       := _LLM_Menu["ctx_chars"]
	llm["generation"]["auto_raise_temp"]        := _LLM_Menu["auto_raise_temp"]
	llm["generation"]["reset_on_nav"]           := _LLM_Menu["reset_on_nav"]
	llm["display"]["show_info_bar"]             := _LLM_Menu["show_info_bar"]
	llm["display"]["streaming"]                 := _LLM_Menu["streaming"]
	llm["display"]["streaming_multi"]           := _LLM_Menu["show_all_at_once"]
	llm["display"]["pred_indent"]               := _LLM_Menu["pred_indent"]
	llm["trigger"]["debounce_ms"]               := _LLM_Menu["debounce_ms"]
	llm["trigger"]["instant_on_word_end"]         := _LLM_Menu["instant_on_word_end"]
	llm["trigger"]["after_hotstring"]           := _LLM_Menu["after_hotstring"]
	llm["trigger"]["inline_autotype"]           := _LLM_Menu["inline_autotype"]
	llm["trigger"]["url_bar_filter_enabled"]    := _LLM_Menu["disable_url_bars"]
	llm["trigger"]["secure_filter_enabled"]     := _LLM_Menu["disable_password_fields"]
	llm["navigation"]["val_modifiers"]          := _LLM_Menu_ModifiersStringToArray(_LLM_Menu["val_modifiers"])
}

_LLM_Menu_AppendPersistedUpdates(Updates) {
	global _LLM_Menu
	Updates.Push({ Section: "llm", Key: "trigger_shortcut", Value: _LLM_Menu["trigger_shortcut"] })
	; Ollama port lives under [llm] as a flat key (like trigger_shortcut) — it is
	; NOT in the Features schema, so it round-trips via the TOML write here + the
	; cache read in the saved-opts loader, not via _LLM_Menu_SyncToFeatures.
	if _LLM_Menu.Has("ollama_port")
		Updates.Push({ Section: "llm", Key: "ollama_port", Value: _LLM_Menu["ollama_port"] })
	Updates.Push({ Section: "llm.navigation", Key: "nav_modifiers",
		Value: _LLM_Menu_ModifiersStringToArray(_LLM_Menu["nav_modifiers"]) })
	apps := _LLM_Menu.Has("disabled_apps") ? _LLM_Menu["disabled_apps"] : []
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