; lib/llm_defaults.ahk

; ==============================================================================
; MODULE: LLM Defaults Loader
; DESCRIPTION:
; Reads static/ergopti_plus/shared/llm/defaults.json at boot and exposes a global
; LLM_Defaults Map so every LLM module reads its initial values from a single
; cross-platform source of truth instead of duplicating hardcoded constants.
;
; FEATURES & RATIONALE:
; 1. Single Source of Truth: defaults.json is shared with the Hammerspoon driver,
;    so a value change only needs to happen in one place.
; 2. Micro-parser: uses the same regex strategy as toml_loader.ahk and
;    menu_manifest.ahk — no external dependency.
; 3. Safe Fallback: if the file cannot be read, hardcoded in-code fallbacks
;    guarantee zero regression at runtime. The fallbacks mirror the JSON values.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ====================================
; ======= 1/ Fallback Defaults =======
; ====================================
; ============================================

; Hardcoded fallbacks — kept in sync with defaults.json as the single recovery
; point when the JSON file cannot be read.
global _LLM_DEFAULTS_FALLBACK := Map(
	"llm_enabled",               false,
	"llm_active_profile",        "basic",
	"llm_temperature",           "0.1",
	"llm_num_predictions",       3,
	"llm_debounce_ms",           500,
	"llm_context_length",        500,
	"llm_min_words",             3,
	"llm_max_words",             15,
	"llm_pred_indent",           0,
	"llm_show_info_bar",         true,
	"llm_streaming",             true,
	"llm_streaming_multi",       true,
	"llm_instant_on_word_end",   true,
	"llm_after_hotstring",       true,
	"llm_reset_on_nav",          true,
	"llm_auto_raise_temp",       true,
	"llm_disable_url_bars",      false,
	"llm_disable_password_fields", false,
	"llm_nav_modifiers",         "",
	"llm_val_modifiers",         "alt",
	"llm_model",                 "Qwen3.5-0.8B",
	"llm_backend",               "ollama"
)

; Loaded at boot by LLM_Defaults_Load() — read-only after that.
global LLM_Defaults := unset





; ==========================================
; ===============================
; ======= 2/ JSON Helpers =======
; ===============================
; ==========================================

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
	return (vals.Length > 0) ? _LLMD_JoinArray(vals, ",") : dflt
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





; ============================================
; ================================
; ======= 3/ Public Loader =======
; ================================
; ============================================

/**
 * Loads defaults.json from _shared/llm/ and returns a Map of default values.
 * Falls back gracefully to _LLM_DEFAULTS_FALLBACK on any read or parse error.
 * Must be called once at startup before any LLM module reads LLM_Defaults.
 */
LLM_Defaults_Load() {
	global LLM_Defaults, _LLM_DEFAULTS_FALLBACK

	path := LLM_GetSharedPath("defaults.json")
	raw  := ""
	try raw := FileRead(path, "UTF-8")

	if (raw == "") {
		try LoggerWarn("LLMDefaults", "defaults.json not found or empty — using fallback values.")
		LLM_Defaults := _LLM_DEFAULTS_FALLBACK.Clone()
		return
	}

	d := Map()

	; Booleans
	for key in ["llm_enabled", "llm_show_info_bar", "llm_streaming", "llm_streaming_multi",
		"llm_instant_on_word_end", "llm_after_hotstring", "llm_reset_on_nav",
		"llm_auto_raise_temp", "llm_disable_url_bars", "llm_disable_password_fields"]
		d[key] := _LLMD_GetBool(raw, key, _LLM_DEFAULTS_FALLBACK[key])

	; Numbers
	for key in ["llm_num_predictions", "llm_debounce_ms", "llm_context_length",
		"llm_min_words", "llm_max_words", "llm_pred_indent"]
		d[key] := _LLMD_GetNumber(raw, key, _LLM_DEFAULTS_FALLBACK[key])

	; Strings
	for key in ["llm_active_profile", "llm_model", "llm_backend"]
		d[key] := _LLMD_GetString(raw, key, _LLM_DEFAULTS_FALLBACK[key])

	; Temperature stored as string to preserve decimal precision in display
	d["llm_temperature"] := Format("{:.2f}", _LLMD_GetNumber(raw, "llm_temperature",
		Float(_LLM_DEFAULTS_FALLBACK["llm_temperature"])))

	; Array-valued modifiers — joined as comma-separated strings for AHK use
	d["llm_nav_modifiers"] := _LLMD_GetStringArray(raw, "llm_nav_modifiers",
		_LLM_DEFAULTS_FALLBACK["llm_nav_modifiers"])
	d["llm_val_modifiers"] := _LLMD_GetStringArray(raw, "llm_val_modifiers",
		_LLM_DEFAULTS_FALLBACK["llm_val_modifiers"])

	LLM_Defaults := d
	try LoggerDone("LLMDefaults", "Loaded %d default values from defaults.json.", LLM_Defaults.Count)
}
