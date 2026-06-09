; modules/llm/profiles.ahk

; ==============================================================================
; MODULE: LLM Profiles
; DESCRIPTION:
; Loads built-in and user-defined prompt profiles from the shared JSON registry
; at _shared/llm/profiles.json. Resolves the active profile and injects
; runtime variables ({min_words}, {max_words}, {language}) into the prompt.
;
; FEATURES & RATIONALE:
; 1. Single source of truth: prompt definitions live in _shared/ alongside the
;    Hammerspoon driver so both platforms always use the same prompts.
; 2. Batch support: profiles with batch=true append a multi-prediction footer.
; 3. {language} injection: hints the model toward the UI locale as a fallback.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ===================================
; ======= 1/ Profile Registry =======
; ===================================
; ====================================

; Module-level cache so the JSON file is parsed only once per session
global _LLM_ProfilesCache := unset

/**
 * Returns all profiles (built-in from JSON + user-defined).
 * @param {Array} user_profiles - Optional array of user profile objects.
 * @returns {Array} Combined array of profile objects.
 */
LLM_GetAllProfiles(user_profiles := []) {
	global _LLM_ProfilesCache
	if !IsSet(_LLM_ProfilesCache)
		_LLM_ProfilesCache := LLM_LoadProfilesJSON()

	all := _LLM_ProfilesCache.Clone()
	for _, p in user_profiles
		all.Push(p)
	return all
}

/**
 * Retrieves the active profile object by ID, falling back to "basic".
 * @param {string} active_id - ID of the requested profile.
 * @param {Array} user_profiles - Optional user-defined profiles.
 * @returns {Object} The matched profile Map object.
 */
LLM_GetActiveProfile(active_id, user_profiles := []) {
	static legacy := Map(
		"parallel",          "basic",
		"batch",             "batch_advanced",
		"parallel_advanced", "advanced",
		"base_completion",   "raw"
	)

	id := String(active_id)
	if legacy.Has(id)
		id := legacy[id]

	for _, p in LLM_GetAllProfiles(user_profiles) {
		if (p.Has("id") && p["id"] == id)
			return p
	}

	; Fallback: search basic in both user-provided and built-in profiles so the
	; fallback works even when the JSON file is absent (e.g. in tests).
	for _, p in LLM_GetAllProfiles(user_profiles)
		if (p.Has("id") && p["id"] == "basic")
			return p

	return Map("id", "raw", "system_single", "{context}", "batch", false)
}





; ============================================
; ====================================
; ======= 2/ Prompt Resolution =======
; ====================================
; ============================================

/**
 * Resolves the system prompt for the active profile, injecting runtime vars.
 * @param {Object} profile - Profile Map object from LLM_GetActiveProfile().
 * @param {number} n - Number of predictions expected (1 = single mode).
 * @param {number} min_words - Minimum word count hint.
 * @param {number} max_words - Maximum word count (0 = unlimited).
 * @param {string} language - Active UI locale code (e.g. "fr", "en").
 * @returns {string} The fully resolved system prompt.
 */
LLM_ResolveSystemPrompt(profile, n, min_words, max_words, language := "en") {
	prompt := ""

	if !IsObject(profile) {
		prompt := LLM_GetBasicPrompt()
	} else if (profile.Has("raw_prompt") && profile["raw_prompt"] != "") {
		prompt := profile["raw_prompt"]
	} else if (n == 1) {
		prompt := profile.Has("system_single") ? profile["system_single"] : LLM_GetBasicPrompt()
	} else {
		if profile.Has("system_multi_template") && profile["system_multi_template"] != "" {
			base   := profile.Has("system_single") ? profile["system_single"] : ""
			footer := StrReplace(profile["system_multi_template"], "{n}", n)
			prompt := base "`n`n" footer
		} else if profile.Has("system_single") {
			prompt := profile["system_single"]
		} else {
			prompt := LLM_GetBasicPrompt()
		}
	}

	; Inject runtime variables
	max_str := (max_words > 0) ? String(max_words) : "unlimited"
	prompt  := StrReplace(prompt, "{min_words}", String(min_words))
	prompt  := StrReplace(prompt, "{max_words}", max_str)
	prompt  := StrReplace(prompt, "{language}",  language)

	return prompt
}





; ======================================
; ===============================
; ======= 3/ JSON Loading =======
; ===============================
; ======================================

/**
 * Parses profiles.json from _shared/llm/ and returns an array of Map objects.
 * @returns {Array} Array of profile Map objects.
 */
LLM_LoadProfilesJSON() {
	profiles_path := LLM_GetSharedPath("profiles.json")
	profiles := []

	raw := FSRead(profiles_path)
	if (raw != false) {
		try {
			profiles := LLM_ParseProfilesJSON(raw)
		} catch {
			; File malformed — return empty, callers fall back to raw
		}
	}
	return profiles
}

/**
 * Minimal JSON array parser for the profiles.json format.
 * Extracts string and boolean fields from each object in the top-level array.
 * @param {string} raw - Raw JSON string content.
 * @returns {Array} Array of Map objects.
 */
LLM_ParseProfilesJSON(raw) {
	result := []
	; Split on object boundaries — each profile is a { ... } block
	pos := 1
	depth := 0
	obj_start := 0

	loop Parse, raw {
		ch := A_LoopField
		if (ch == "{") {
			if (depth == 0)
				obj_start := A_Index
			depth++
		} else if (ch == "}") {
			depth--
			if (depth == 0 && obj_start > 0) {
				obj_str := SubStr(raw, obj_start, A_Index - obj_start + 1)
				p := LLM_ParseProfileObject(obj_str)
				result.Push(p)
				obj_start := 0
			}
		}
	}
	return result
}

/**
 * Parses a single JSON object string into a Map.
 * @param {string} obj - JSON object string (without outer array brackets).
 * @returns {Map} Parsed key-value Map.
 */
LLM_ParseProfileObject(obj) {
	m := Map()

	; Extract string fields
	for key in ["id", "label", "system_single", "system_multi", "system_multi_template", "raw_prompt"] {
		if RegExMatch(obj, '"' key '"\s*:\s*"((?:[^"\\]|\\.)*)"', &match)
			m[key] := LLM_UnescapeJSON(match[1])
		else
			m[key] := ""
	}

	; Extract boolean field
	if RegExMatch(obj, '"batch"\s*:\s*(true|false)', &match)
		m["batch"] := (match[1] == "true")
	else
		m["batch"] := false

	; Extract ``stop_sequences`` — optional string array. Power-user
	; profiles can use this to clip generation at custom markers (e.g.
	; ``` for a code profile, "\n\n" for a single-paragraph
	; profile). Empty when the field is absent — Ollama then falls back
	; to its own built-in stops.
	m["stop_sequences"] := []
	if RegExMatch(obj, '"stop_sequences"\s*:\s*\[([^\]]*)\]', &match) {
		body := match[1]
		pos := 1
		while RegExMatch(body, '"((?:[^"\\]|\\.)*)"', &sm, pos) {
			m["stop_sequences"].Push(LLM_UnescapeJSON(sm[1]))
			pos := sm.Pos + sm.Len
		}
	}

	return m
}

/**
 * Returns the basic profile's system_single prompt as a hardcoded fallback.
 * Used when the JSON file cannot be loaded.
 * @returns {string} The basic system prompt.
 */
LLM_GetBasicPrompt() {
	return "You are an ultra-concise keyboard completion engine.`n"
		. "User context: {context}`n`n"
		. "Output strictly the immediate continuation of the context.`n"
		. "ABSOLUTE RULE: generate AT LEAST {min_words} words and AT MOST {max_words} words. NOT ONE WORD MORE OR LESS.`n"
		. "Match the language of the context. If the context language is ambiguous, default to {language}.`n"
		. "No explanation, no comment, no list, no bullet, no quote, no rephrasing of the context.`n"
		. "Return only the words to append."
}
