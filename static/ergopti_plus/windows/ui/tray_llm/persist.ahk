; ui/tray_llm/persist.ahk
; Tray state <-> Features["llm"] <-> config.toml (no menu handlers / hotkeys).

#Requires AutoHotkey v2.0

_LLM_Tray_ModifiersStringToArray(s) {
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

_LLM_Tray_ModifiersArrayToString(arr) {
	if !(arr is Array) || arr.Length = 0
		return ""
	out := ""
	for i, v in arr
		out .= (i > 1 ? "," : "") . String(v)
	return out
}

_LLM_Tray_CoerceIniArray(raw) {
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

_LLM_Tray_SyncToFeatures() {
	global _LLM_Tray, Features
	if !IsSet(Features) or !IsSet(_LLM_Tray)
		return
	if !Features.Has("llm")
		return
	llm := Features["llm"]
	llm["enabled"]                            := _LLM_Tray["enabled"]
	llm["models"]["ollama"]                   := _LLM_Tray["model"]
	llm["models"]["selected"]                 := _LLM_Tray["backend"]
	llm["profiles"]["active"]                 := _LLM_Tray["profile_id"]
	llm["profiles"]["num_predictions"]        := _LLM_Tray["n_predictions"]
	llm["profiles"]["auto_profile_for_model"]   := _LLM_Tray["auto_profile_for_model"]
	llm["generation"]["temperature"]          := Float(_LLM_Tray["temperature"])
	llm["generation"]["min_words"]            := _LLM_Tray["min_words"]
	llm["generation"]["max_words"]            := _LLM_Tray["max_words"]
	llm["generation"]["context_length"]       := _LLM_Tray["ctx_chars"]
	llm["generation"]["auto_raise_temp"]        := _LLM_Tray["auto_raise_temp"]
	llm["generation"]["reset_on_nav"]           := _LLM_Tray["reset_on_nav"]
	llm["display"]["show_info_bar"]             := _LLM_Tray["show_info_bar"]
	llm["display"]["streaming"]                 := _LLM_Tray["streaming"]
	llm["display"]["streaming_multi"]           := _LLM_Tray["show_all_at_once"]
	llm["display"]["pred_indent"]               := _LLM_Tray["pred_indent"]
	llm["trigger"]["debounce_ms"]               := _LLM_Tray["debounce_ms"]
	llm["trigger"]["instant_on_word_end"]         := _LLM_Tray["instant_on_word_end"]
	llm["trigger"]["after_hotstring"]           := _LLM_Tray["after_hotstring"]
	llm["trigger"]["inline_autotype"]           := _LLM_Tray["inline_autotype"]
	llm["trigger"]["url_bar_filter_enabled"]    := _LLM_Tray["disable_url_bars"]
	llm["trigger"]["secure_filter_enabled"]     := _LLM_Tray["disable_password_fields"]
	llm["navigation"]["val_modifiers"]          := _LLM_Tray_ModifiersStringToArray(_LLM_Tray["val_modifiers"])
}

_LLM_Tray_AppendPersistedUpdates(Updates) {
	global _LLM_Tray
	Updates.Push({ Section: "llm", Key: "trigger_shortcut", Value: _LLM_Tray["trigger_shortcut"] })
	; Ollama port lives under [llm] as a flat key (like trigger_shortcut) — it is
	; NOT in the Features schema, so it round-trips via the TOML write here + the
	; cache read in the saved-opts loader, not via _LLM_Tray_SyncToFeatures.
	if _LLM_Tray.Has("ollama_port")
		Updates.Push({ Section: "llm", Key: "ollama_port", Value: _LLM_Tray["ollama_port"] })
	Updates.Push({ Section: "llm.navigation", Key: "nav_modifiers",
		Value: _LLM_Tray_ModifiersStringToArray(_LLM_Tray["nav_modifiers"]) })
	apps := _LLM_Tray.Has("disabled_apps") ? _LLM_Tray["disabled_apps"] : []
	if !(apps is Array)
		apps := []
	Updates.Push({ Section: "llm.trigger", Key: "disabled_apps", Value: apps })
}

LLM_Tray_BuildSavedOpts(Cache := unset) {
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
		? _LLM_Tray_ModifiersArrayToString(val_raw) : String(val_raw)
	if IsSet(Cache) {
		raw := IniCacheGet(Cache, "llm", "trigger_shortcut")
		if (raw != "_")
			opts["trigger_shortcut"] := String(raw)
		raw := IniCacheGet(Cache, "llm", "ollama_port")
		if (raw != "_" and IsInteger(raw))
			opts["ollama_port"] := Integer(raw)
		raw := IniCacheGet(Cache, "llm.navigation", "val_modifiers")
		if (raw != "_") {
			arr := _LLM_Tray_CoerceIniArray(raw)
			opts["val_modifiers"] := _LLM_Tray_ModifiersArrayToString(arr)
		}
		raw := IniCacheGet(Cache, "llm.navigation", "nav_modifiers")
		if (raw != "_") {
			arr := _LLM_Tray_CoerceIniArray(raw)
			opts["nav_modifiers"] := _LLM_Tray_ModifiersArrayToString(arr)
		}
		raw := IniCacheGet(Cache, "llm.trigger", "disabled_apps")
		if (raw != "_") {
			arr := _LLM_Tray_CoerceIniArray(raw)
			if (arr.Length > 0)
				opts["disabled_apps"] := arr
		}
	}
	return opts
}