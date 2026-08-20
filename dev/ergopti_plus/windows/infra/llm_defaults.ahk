; infra/llm_defaults.ahk

; ==============================================================================
; MODULE: LLM Defaults Loader
; DESCRIPTION:
; Reads static/ergopti_plus/_shared/modules/llm/defaults.json at boot and exposes a global
; LLM_Defaults Map so every LLM module reads its initial values from a single
; cross-platform source of truth instead of duplicating hardcoded constants.
;
; FEATURES & RATIONALE:
; 1. Single Source of Truth: defaults.json is shared with the Hammerspoon driver,
;    so a value change only needs to happen in one place.
; 2. Micro-parser: uses the same regex strategy as toml_loader.ahk and
;    menu_manifest.ahk — no external dependency.
; 3. Fail fast: defaults.json is REQUIRED. A missing/unreadable file or any
;    missing shared key raises loudly instead of silently substituting a mirror
;    of the values. Only the AHK-local keys (model, backend) have an in-code source.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ AHK-Local Defaults =======
; =====================================
; =====================================

; The only LLM defaults that are NOT in the cross-platform defaults.json: the
; chosen model and backend are AHK-local choices. Every other default is sourced
; EXCLUSIVELY from defaults.json (rule 5.2). This is a small single local source,
; not a mirror of the shared values — so it can never drift from the JSON.
global _LLM_LOCAL_DEFAULTS := Map(
	"llm_model",   "Qwen3.5-0.8B",
	"llm_backend", "ollama"
)

; Loaded at boot by LLM_Defaults_Load() — read-only after that.
global LLM_Defaults := unset





; ===============================
; ===============================
; ======= 2/ JSON Helpers =======
; ===============================
; ===============================

/**
 * Extracts a string value from a flat JSON object literal.
 * Returns dflt if the key is absent.
 * @param {string} raw   - Raw JSON text.
 * @param {string} key   - Key to look up.
 * @param {string} dflt  - Fallback value.
 * @returns {string}
 */
_LLMD_GetString(raw, key, dflt := "") {
	if RegExMatch(raw, '"' key '"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"', &m)
		return m[1]
	return dflt
}

/**
 * Extracts a numeric value from a flat JSON object literal.
 * Returns dflt if the key is absent.
 * @param {string} raw   - Raw JSON text.
 * @param {string} key   - Key to look up.
 * @param {number} dflt  - Fallback value.
 * @returns {number}
 */
_LLMD_GetNumber(raw, key, dflt := 0) {
	if RegExMatch(raw, '"' key '"\s*:\s*(-?\d+(?:\.\d+)?)', &m)
		return m[1] + 0
	return dflt
}

/**
 * Extracts a boolean value from a flat JSON object literal.
 * Returns dflt if the key is absent.
 * @param {string} raw   - Raw JSON text.
 * @param {string} key   - Key to look up.
 * @param {boolean} dflt - Fallback value.
 * @returns {boolean}
 */
_LLMD_GetBool(raw, key, dflt := false) {
	if RegExMatch(raw, '"' key '"\s*:\s*(true|false)', &m)
		return (m[1] == "true")
	return dflt
}

/**
 * Extracts an array of strings from a flat JSON key whose value is ["a","b",...].
 * Returns a comma-joined string (e.g. "alt,ctrl") for easy AHK use.
 * Returns dflt if absent or empty.
 * @param {string} raw   - Raw JSON text.
 * @param {string} key   - Key to look up.
 * @param {string} dflt  - Fallback value.
 * @returns {string}
 */
_LLMD_GetStringArray(raw, key, dflt := "") {
	if !RegExMatch(raw, '"' key '"\s*:\s*(\[[^\]]*\])', &arr)
		return dflt
	lit  := arr[1]
	vals := []
	pos  := 1
	while RegExMatch(lit, '"([^"\\]*(?:\\.[^"\\]*)*)"', &elem, pos) {
		vals.Push(elem[1])
		pos := elem.Pos + elem.Len
	}
	; Key is present — return the join even when the array is empty ([]).
	; Returning dflt for an explicit [] would be wrong: the caller cannot
	; distinguish "key absent" from "key set to empty list".
	return _LLMD_JoinArray(vals, ",")
}

/**
 * Joins an array of strings with a separator.
 * @param {Array}  arr - Array of strings.
 * @param {string} sep - Separator.
 * @returns {string}
 */
_LLMD_JoinArray(arr, sep) {
	out := ""
	for i, v in arr
		out .= (i > 1 ? sep : "") . v
	return out
}

/**
 * Reports whether a flat JSON object literal declares the given key (regardless
 * of its value type). Used to fail fast on a missing shared key rather than
 * silently substituting a hardcoded value.
 * @param {string} raw - Raw JSON text.
 * @param {string} key - Key to look for.
 * @returns {boolean} true when the key is present.
 */
_LLMD_HasKey(raw, key) {
	return RegExMatch(raw, '"' key '"\s*:') > 0
}





; ================================
; ================================
; ======= 3/ Public Loader =======
; ================================
; ================================

/**
 * Loads defaults.json from _shared/modules/llm/ and populates the global LLM_Defaults
 * Map. defaults.json is REQUIRED: a missing/unreadable file or any missing
 * shared key raises (fail fast) rather than substituting a hardcoded mirror that
 * could drift from the JSON. Only the AHK-local keys (model, backend) come from
 * the in-code _LLM_LOCAL_DEFAULTS. Must run once at startup before any LLM
 * module reads LLM_Defaults.
 */
LLM_Defaults_Load() {
	global LLM_Defaults, _LLM_LOCAL_DEFAULTS

	path := LLM_GetSharedPath("defaults.json")
	raw  := ""
	try raw := FileRead(path, "UTF-8")

	if (raw == "") {
		LoggerError("LLMDefaults", "_shared/modules/llm/defaults.json not found or empty at '{1}' — LLM defaults cannot be initialised.", path)
		throw Error("ergopti_plus: _shared/modules/llm/defaults.json is required but was not found")
	}

	d       := Map()
	missing := []

	; Booleans (all present in defaults.json)
	for key in ["llm_enabled", "llm_show_info_bar", "llm_streaming", "llm_streaming_multi",
		"llm_instant_on_word_end", "llm_after_hotstring", "llm_reset_on_nav",
		"llm_auto_raise_temp", "llm_disable_url_bars", "llm_disable_password_fields"] {
		if !_LLMD_HasKey(raw, key)
			missing.Push(key)
		else
			d[key] := _LLMD_GetBool(raw, key)
	}

	; Numbers
	for key in ["llm_num_predictions", "llm_debounce_ms", "llm_context_length",
		"llm_min_words", "llm_max_words", "llm_pred_indent", "llm_ollama_port"] {
		if !_LLMD_HasKey(raw, key)
			missing.Push(key)
		else
			d[key] := _LLMD_GetNumber(raw, key)
	}

	; Strings (shared) — model/backend are AHK-local and applied below.
	; llm_ollama_keep_alive belongs here and not to a `Has()` guard downstream:
	; api_ollama/init.ahk only copies it when the key exists, so omitting it from
	; this list left that guard permanently false and the payload builder fell back
	; to a hardcoded literal — the shared JSON could be edited with no effect on
	; Windows while macOS honoured it.
	for key in ["llm_active_profile", "llm_ollama_keep_alive"] {
		if !_LLMD_HasKey(raw, key)
			missing.Push(key)
		else
			d[key] := _LLMD_GetString(raw, key)
	}

	; Temperature stored as string to preserve decimal precision in display
	if !_LLMD_HasKey(raw, "llm_temperature")
		missing.Push("llm_temperature")
	else
		d["llm_temperature"] := Format("{:.2f}", _LLMD_GetNumber(raw, "llm_temperature"))

	; Array-valued modifiers — present in defaults.json even when empty ([]).
	for key in ["llm_nav_modifiers", "llm_val_modifiers"] {
		if !_LLMD_HasKey(raw, key)
			missing.Push(key)
		else
			d[key] := _LLMD_GetStringArray(raw, key)
	}

	if (missing.Length > 0) {
		LoggerError("LLMDefaults", "_shared/modules/llm/defaults.json is missing required key(s): {1} — LLM defaults incomplete.", _LLMD_JoinArray(missing, ", "))
		throw Error("ergopti_plus: _shared/modules/llm/defaults.json is missing required key(s): " . _LLMD_JoinArray(missing, ", "))
	}

	; AHK-local keys (model, backend) — not part of the cross-platform JSON.
	for key, val in _LLM_LOCAL_DEFAULTS
		d[key] := val

	LLM_Defaults := d
	try LoggerDone("LLMDefaults", "Loaded {1} default values from defaults.json.", LLM_Defaults.Count)
}
