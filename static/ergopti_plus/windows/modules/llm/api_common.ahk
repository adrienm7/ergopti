; modules/llm/api_common.ahk

; ==============================================================================
; MODULE: LLM API Common Helpers
; DESCRIPTION:
; Shared helpers reused by every AHK LLM backend (api_ollama.ahk, api_remote.ahk,
; the prediction engine itself). 1:1 mirror of the Hammerspoon twin at
; ``modules/llm/api_common.lua`` — same surface (get_diversity_temperature,
; get_retry_policy, get_rate_limit_min_interval_ms, insert_prediction,
; new_dedup_stats), same algorithm, and the same numeric tunables (loaded
; from ``static/ergopti_plus/shared/llm/inference.json``).
;
; FEATURES & RATIONALE:
; 1. Single source of truth for inference tunables: change a knob in
;    inference.json and both drivers track it. No more drift between
;    Lua and AHK constants.
; 2. Same algorithm as HS: diversity-temperature step depends on the user's
;    base temperature with the same three brackets; dedup compares against
;    a normalised text key; retry policy is the same multiplier / step /
;    extra-tokens triple.
; 3. Hardcoded fallback: if inference.json is missing or unparseable, the
;    fallback table keeps the engine working with the same values that
;    were committed alongside the JSON — silent degradation, no crash.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================
; =====================================
; ======= 1/ Shared Constants =========
; =====================================
; =====================================

; Hardcoded fallback used when inference.json can't be read. Values mirror
; the JSON committed alongside this file — keeping them here too means a
; corrupted / missing JSON never leaves the engine in an undefined state.
global LLM_COMMON_FALLBACK := Map(
	"diversity_temperature", Map(
		"step_when_base_le_0_15",  0.24,
		"step_when_base_le_0_35",  0.18,
		"step_default",            0.12,
		"effective_base_floor",    0.20,
		"max_temperature",         1.30
	),
	"dedup", Map(
		"enabled_by_default", true
	),
	"retry", Map(
		"max_multiplier",         2,
		"retry_temperature_step", 0.18,
		"retry_extra_tokens",     5
	),
	"rate_limit_min_interval_ms", Map(
		"ollama", 300,
		"mlx",    300,
		"api",    500
	)
)

; Loaded from inference.json on first access. ``unset`` so we can detect the
; first call and probe the JSON exactly once per session.
global _LLM_COMMON_INFERENCE := unset

/**
 * Returns the cached inference-constants table, lazy-loading from
 * inference.json on first call. Same path probe as LLM_Defaults_Load so we
 * benefit from the same discovery story and the same fallback story.
 * @returns {Map} Constants table — always non-empty (falls back to LLM_COMMON_FALLBACK).
 */
_LLM_Common_GetInference() {
	global _LLM_COMMON_INFERENCE, LLM_COMMON_FALLBACK, _StaticDir
	if IsSet(_LLM_COMMON_INFERENCE)
		return _LLM_COMMON_INFERENCE
	; Try the canonical path next to defaults.json / models.json.
	path := _StaticDir . "\ergopti_plus\shared\llm\inference.json"
	if !FileExist(path) {
		_LLM_COMMON_INFERENCE := LLM_COMMON_FALLBACK
		return _LLM_COMMON_INFERENCE
	}
	try {
		fh := FileOpen(path, "r", "UTF-8")
		if !IsObject(fh) {
			_LLM_COMMON_INFERENCE := LLM_COMMON_FALLBACK
			return _LLM_COMMON_INFERENCE
		}
		raw := fh.Read()
		fh.Close()
		parsed := _LLM_Common_ParseInferenceJson(raw)
		_LLM_COMMON_INFERENCE := parsed.Count > 0 ? parsed : LLM_COMMON_FALLBACK
	} catch {
		_LLM_COMMON_INFERENCE := LLM_COMMON_FALLBACK
	}
	return _LLM_COMMON_INFERENCE
}

/**
 * Lightweight JSON-to-Map parser tailored to inference.json's flat shape
 * (only nested one level deep, only number and boolean leaves). We do NOT
 * use a generic JSON parser to avoid the dependency — the file is small,
 * we control its schema, and a few regex passes are enough.
 * @param {string} raw - Raw inference.json contents.
 * @returns {Map} Parsed two-level map.
 */
_LLM_Common_ParseInferenceJson(raw) {
	out := Map()
	; First: strip comments. inference.json's comments are pseudo-keys
	; ("_comment": "..." ) so we leave them in — the section extractor below
	; ignores any key whose name starts with an underscore.
	;
	; Section: "name": { ... }
	pos := 1
	while RegExMatch(raw, '"([A-Za-z_]+)"\s*:\s*\{', &section, pos) {
		section_name := section[1]
		section_start := section.Pos + section.Len
		; Find the matching closing brace; the schema only nests one level
		; so a simple depth counter is enough.
		depth := 1
		i := section_start
		while (i <= StrLen(raw) and depth > 0) {
			c := SubStr(raw, i, 1)
			if (c == "{")
				depth += 1
			else if (c == "}")
				depth -= 1
			i += 1
		}
		section_body := SubStr(raw, section_start, i - section_start - 1)
		if (SubStr(section_name, 1, 1) != "_") {
			out[section_name] := _LLM_Common_ParseSectionBody(section_body)
		}
		pos := i
	}
	return out
}

/**
 * Parses one section body into a Map of name → number|boolean. Skips keys
 * starting with an underscore (treated as comments by convention).
 */
_LLM_Common_ParseSectionBody(body) {
	out := Map()
	; Numbers and booleans
	pos := 1
	while RegExMatch(body, '"([A-Za-z_0-9]+)"\s*:\s*(-?[0-9]+(?:\.[0-9]+)?|true|false)', &m, pos) {
		key := m[1]
		raw_val := m[2]
		if (SubStr(key, 1, 1) != "_") {
			if (raw_val == "true") {
				out[key] := true
			} else if (raw_val == "false") {
				out[key] := false
			} else {
				out[key] := raw_val + 0   ; coerce to number
			}
		}
		pos := m.Pos + m.Len
	}
	return out
}

/**
 * Pulls a field from inference.json with a fallback to LLM_COMMON_FALLBACK.
 * Keeps call sites readable: ``_LLM_Common_Cfg("diversity_temperature", "step_default")``.
 */
_LLM_Common_Cfg(section, key) {
	cfg := _LLM_Common_GetInference()
	if (cfg.Has(section) and cfg[section].Has(key))
		return cfg[section][key]
	return LLM_COMMON_FALLBACK[section][key]
}

/**
 * Returns true when exact-text dedup is enabled by default. The engine
 * may override this per-request via the ``dedup_enabled`` flag.
 * @returns {boolean}
 */
LLM_ApiCommon_DefaultDedupEnabled() {
	return _LLM_Common_Cfg("dedup", "enabled_by_default") == true
}

/**
 * Returns the minimum interval (milliseconds) between two prediction
 * requests for the given backend. Mirrors the HS
 * ``ApiCommon.get_rate_limit_min_interval_s`` API. Returns 300 ms for
 * unknown backends — same default as HS.
 * @param {string} backend_id - One of "ollama" / "mlx" / "api".
 * @returns {number} Floor interval in milliseconds.
 */
LLM_ApiCommon_GetRateLimitMs(backend_id) {
	cfg := _LLM_Common_GetInference()
	rateMap := cfg.Has("rate_limit_min_interval_ms") ? cfg["rate_limit_min_interval_ms"] : LLM_COMMON_FALLBACK["rate_limit_min_interval_ms"]
	if rateMap.Has(backend_id)
		return rateMap[backend_id]
	return 300
}

/**
 * Returns the retry policy as three numbers:
 *   - max_multiplier      — upper bound on attempts (× requested_predictions)
 *   - retry_temperature_step — added on top of the diversity step on the 2nd attempt
 *   - retry_extra_tokens  — extra max-token budget for the retry
 * @returns {Array} [max_mult, temp_step, extra_tokens]
 */
LLM_ApiCommon_GetRetryPolicy() {
	return [
		_LLM_Common_Cfg("retry", "max_multiplier"),
		_LLM_Common_Cfg("retry", "retry_temperature_step"),
		_LLM_Common_Cfg("retry", "retry_extra_tokens")
	]
}




; =========================================
; =========================================
; ======= 2/ Diversity Temperature ========
; =========================================
; =========================================

/**
 * Computes request temperature for a prediction variant. Algorithm MUST
 * stay in lockstep with the HS twin (api_common.lua / get_diversity_temperature):
 *
 *   1. Pick the diversity step:
 *        - explicit ``step`` argument wins when provided,
 *        - else: base ≤ 0.15 → step_when_base_le_0_15
 *                base ≤ 0.35 → step_when_base_le_0_35
 *                base  > 0.35 → step_default
 *   2. Raise the effective base to effective_base_floor when variant_index > 1
 *      AND base < effective_base_floor — first variant stays faithful to the
 *      user's setting, next ones get headroom for diversity.
 *   3. Clamp the final value at max_temperature.
 *
 * @param {number} base_temp - Base temperature configured by the user.
 * @param {number} variant_index - 1-based variant index.
 * @param {number|string} step - Optional explicit step; "" / unset = auto.
 * @returns {number} Computed temperature for this variant.
 */
LLM_ApiCommon_GetDiversityTemp(base_temp, variant_index, step := "") {
	idx := Max(1, Integer(variant_index))
	base := base_temp + 0.0
	delta := 0.0
	if (step == "" or step == 0) {
		if (base <= 0.15)
			delta := _LLM_Common_Cfg("diversity_temperature", "step_when_base_le_0_15")
		else if (base <= 0.35)
			delta := _LLM_Common_Cfg("diversity_temperature", "step_when_base_le_0_35")
		else
			delta := _LLM_Common_Cfg("diversity_temperature", "step_default")
	} else {
		delta := step + 0.0
	}

	floor_val := _LLM_Common_Cfg("diversity_temperature", "effective_base_floor")
	max_val   := _LLM_Common_Cfg("diversity_temperature", "max_temperature")
	effective_base := base
	if (idx > 1 and effective_base < floor_val)
		effective_base := floor_val

	tempVal := effective_base + (idx - 1) * delta
	return (tempVal > max_val) ? max_val : tempVal
}




; =====================================
; =====================================
; ======= 3/ Dedup Helpers ============
; =====================================
; =====================================

/**
 * Returns an empty dedup statistics map. Mirrors ApiCommon.new_dedup_stats
 * on the HS side — candidates / duplicates / kept counters.
 */
LLM_ApiCommon_NewDedupStats() {
	return Map("candidates", 0, "duplicates", 0, "kept", 0)
}

/**
 * Inserts a prediction with optional exact-text deduplication. Mirrors
 * ApiCommon.insert_prediction on the HS side. The prediction object is
 * expected to expose ``to_type`` (the rendered insertion text); a string
 * passed in directly is wrapped into a plain ``{ to_type: <s> }`` shape.
 *
 * @param {Array} results - Accumulator array.
 * @param {Object|Map|String} pred - Candidate prediction.
 * @param {Map} stats - Dedup statistics accumulator (or unset).
 * @param {boolean} dedup_enabled - Whether exact dedup is on.
 * @returns {boolean} True when inserted, false when ignored as a duplicate.
 */
LLM_ApiCommon_InsertPrediction(results, pred, stats, dedup_enabled) {
	if (Type(results) != "Array")
		return false
	if (pred == "" or pred == 0)
		return false

	pred_text := _LLM_ApiCommon_PredText(pred)
	if (IsObject(stats))
		stats["candidates"] := stats["candidates"] + 1

	if (!dedup_enabled) {
		results.Push(pred)
		if (IsObject(stats))
			stats["kept"] := stats["kept"] + 1
		return true
	}

	for existing in results {
		; Case-SENSITIVE comparison via StrCompare(.., true). AHK v2's ``==``
		; on strings is case-INSENSITIVE, so without this two predictions that
		; differ only by case would collapse into one slot. Matches the HS
		; api_common.lua behaviour (Lua's ``==`` is byte-exact by default).
		if (StrCompare(_LLM_ApiCommon_PredText(existing), pred_text, true) == 0) {
			if (IsObject(stats))
				stats["duplicates"] := stats["duplicates"] + 1
			return false
		}
	}
	results.Push(pred)
	if (IsObject(stats))
		stats["kept"] := stats["kept"] + 1
	return true
}

/**
 * Pulls the to_type string off of a prediction, regardless of whether it
 * is a Map, an object with .to_type, or a plain string.
 */
_LLM_ApiCommon_PredText(pred) {
	if (Type(pred) == "String")
		return pred
	if (pred is Map)
		return pred.Has("to_type") ? pred["to_type"] : ""
	try return pred.to_type
	return ""
}




; =====================================
; =====================================
; ======= 4/ Logging Helpers ==========
; =====================================
; =====================================

/**
 * Logs prediction summary counters for one fetch strategy. Same message
 * shape as HS so a tail of the unified log reads identically across
 * drivers.
 *
 * @param {string} mode - "batch" / "parallel" / "sequential".
 * @param {number} requested - Number of predictions originally asked for.
 * @param {Map} stats - Dedup statistics accumulator.
 * @param {number} kept_count - Final number of predictions retained.
 */
LLM_ApiCommon_LogSummary(mode, requested, stats, kept_count) {
	candidates := (IsObject(stats) and stats.Has("candidates")) ? stats["candidates"] : 0
	duplicates := (IsObject(stats) and stats.Has("duplicates")) ? stats["duplicates"] : 0
	try LoggerInfo("llm.api_common",
		"Résumé prédictions [{1}]: demandées={2}, candidates={3}, doublons={4}, retenues={5}",
		mode, requested, candidates, duplicates, kept_count)
}
