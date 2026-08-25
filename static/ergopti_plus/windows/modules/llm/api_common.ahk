; modules/llm/api_common.ahk

; ==============================================================================
; MODULE: LLM API Common Helpers
; DESCRIPTION:
; Shared helpers reused by every AHK LLM backend (api_ollama.ahk, api_remote.ahk,
; the prediction engine itself). 1:1 mirror of the Hammerspoon twin at
; ``modules/llm/api_common.lua`` — same surface (get_diversity_temperature,
; get_retry_policy, get_rate_limit_min_interval_ms, insert_prediction,
; new_dedup_stats), same algorithm, and the same numeric tunables (loaded
; from ``static/ergopti_plus/_shared/modules/llm/inference.json``).
;
; FEATURES & RATIONALE:
; 1. Single source of truth for inference tunables: change a knob in
;    inference.json and both drivers track it. No more drift between
;    Lua and AHK constants.
; 2. Same algorithm as HS: diversity-temperature step depends on the user's
;    base temperature with the same three brackets; dedup compares against
;    a normalised text key; retry policy is the same multiplier / step /
;    extra-tokens triple.
; 3. Fail fast: inference.json is REQUIRED. A missing/unparseable file or a
;    missing tunable raises loudly (LoggerError + throw) instead of silently
;    degrading to an in-code mirror that could drift from the JSON.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================
; =====================================
; ======= 1/ Shared Constants =========
; =====================================
; =====================================

; Loaded from inference.json on first access (cached for the session). ``unset``
; so the first call probes the JSON exactly once. There is no in-code mirror of
; these tunables — inference.json is the single source and is required.
global _LLM_COMMON_INFERENCE     := unset
; Raw text of inference.json, cached alongside the parsed map so array-valued
; sections can be extracted by _LLM_Common_GetStringArray without a second read.
global _LLM_COMMON_INFERENCE_RAW := unset

/**
 * Returns the cached inference-constants table, lazy-loading from inference.json
 * on first call. inference.json is REQUIRED: a missing/unreadable/empty file
 * raises (fail fast) rather than substituting a hardcoded mirror.
 * @returns {Map} Constants table parsed from inference.json.
 */
_LLM_Common_GetInference() {
	global _LLM_COMMON_INFERENCE, _LLM_COMMON_INFERENCE_RAW, _SharedDir
	if IsSet(_LLM_COMMON_INFERENCE)
		return _LLM_COMMON_INFERENCE
	; Canonical path next to defaults.json / models.json.
	path := _SharedDir . "\modules\llm\inference.json"
	if !FileExist(path) {
		LoggerError("LLMCommon", "_shared/modules/llm/inference.json not found at '{1}' — LLM inference tunables cannot be loaded.", path)
		throw Error("ergopti_plus: _shared/modules/llm/inference.json is required but was not found")
	}
	raw := FSRead(path)
	if (raw == false) {
		LoggerError("LLMCommon", "_shared/modules/llm/inference.json could not be read at '{1}'.", path)
		throw Error("ergopti_plus: _shared/modules/llm/inference.json could not be read")
	}
	_LLM_COMMON_INFERENCE_RAW := raw
	parsed := _LLM_Common_ParseInferenceJson(raw)
	if (parsed.Count == 0) {
		LoggerError("LLMCommon", "_shared/modules/llm/inference.json parsed to an empty table — malformed JSON.")
		throw Error("ergopti_plus: _shared/modules/llm/inference.json is present but parsed empty")
	}
	_LLM_COMMON_INFERENCE := parsed
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
	; Quoted string values — matched before numbers/booleans so "true" and "123"
	; inside quotes are preserved as strings rather than coerced
	pos_str := 1
	while RegExMatch(body, '"([A-Za-z_0-9]+)"\s*:\s*"([^"]*)"', &ms, pos_str) {
		if (SubStr(ms[1], 1, 1) != "_")
			out[ms[1]] := ms[2]
		pos_str := ms.Pos + ms.Len
	}
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
 * Pulls a tunable from inference.json (the single source); raises if absent.
 * Keeps call sites readable: ``_LLM_Common_Cfg("diversity_temperature", "step_default")``.
 */
_LLM_Common_Cfg(section, key) {
	cfg := _LLM_Common_GetInference()
	if (cfg.Has(section) and cfg[section].Has(key))
		return cfg[section][key]
	LoggerError("LLMCommon", "_shared/modules/llm/inference.json is missing tunable '{1}.{2}' — malformed or outdated JSON.", section, key)
	throw Error("ergopti_plus: inference.json missing tunable " . section . "." . key)
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
 * ``ApiCommon.get_rate_limit_min_interval_s`` API. For an unknown backend id it
 * returns the ollama floor from the JSON — all floors come from inference.json.
 * @param {string} backend_id - One of "ollama" / "mlx" / "api".
 * @returns {number} Floor interval in milliseconds.
 */
LLM_ApiCommon_GetRateLimitMs(backend_id) {
	cfg := _LLM_Common_GetInference()
	if !cfg.Has("rate_limit_min_interval_ms") {
		LoggerError("LLMCommon", "_shared/modules/llm/inference.json is missing section 'rate_limit_min_interval_ms'.")
		throw Error("ergopti_plus: inference.json missing section rate_limit_min_interval_ms")
	}
	rateMap := cfg["rate_limit_min_interval_ms"]
	if rateMap.Has(backend_id)
		return rateMap[backend_id]
	; Unknown backend id — use the ollama floor from the JSON as the default.
	if rateMap.Has("ollama")
		return rateMap["ollama"]
	LoggerError("LLMCommon", "inference.json rate_limit_min_interval_ms has neither '{1}' nor 'ollama'.", backend_id)
	throw Error("ergopti_plus: inference.json rate_limit floor unavailable")
}

/**
 * Extracts a string array from inference.json by section and key. Uses the
 * raw text cached alongside the parsed Map — the scalar-only Map parser cannot
 * represent arrays, so we walk the raw JSON with a depth counter.
 * @param {string} section - Top-level section name (e.g. "stop_sequences").
 * @param {string} key     - Array key within the section (e.g. "batch").
 * @returns {Array} Unescaped string array.
 */
_LLM_Common_GetStringArray(section, key) {
	global _LLM_COMMON_INFERENCE_RAW, _SharedDir
	if !IsSet(_LLM_COMMON_INFERENCE_RAW) {
		; Fallback path: raw not yet cached — read the file directly.
		path := _SharedDir . "\modules\llm\inference.json"
		raw := FSRead(path)
		if (raw == false)
			throw Error("ergopti_plus: inference.json unavailable for array extraction")
		_LLM_COMMON_INFERENCE_RAW := raw
	}
	raw := _LLM_COMMON_INFERENCE_RAW
	; Locate the section object: "section": { ... }
	if !RegExMatch(raw, '"' . section . '"\s*:\s*\{', &sec_match)
		throw Error("ergopti_plus: inference.json missing section " . section)
	sec_start := sec_match.Pos + sec_match.Len
	depth := 1
	i := sec_start
	while (i <= StrLen(raw) and depth > 0) {
		c := SubStr(raw, i, 1)
		if (c == "{")
			depth += 1
		else if (c == "}")
			depth -= 1
		i += 1
	}
	sec_body := SubStr(raw, sec_start, i - sec_start - 1)
	; Locate the array value within the section: "key": [ ... ]
	if !RegExMatch(sec_body, '"' . key . '"\s*:\s*\[', &key_match)
		throw Error("ergopti_plus: inference.json missing array " . section . "." . key)
	arr_start := key_match.Pos + key_match.Len
	depth := 1
	i := arr_start
	while (i <= StrLen(sec_body) and depth > 0) {
		c := SubStr(sec_body, i, 1)
		if (c == "[")
			depth += 1
		else if (c == "]")
			depth -= 1
		i += 1
	}
	arr_body := SubStr(sec_body, arr_start, i - arr_start - 1)
	; Extract and unescape each quoted string element.
	result := []
	pos := 1
	while RegExMatch(arr_body, '"((?:[^"\\]|\\.)*)"', &m, pos) {
		result.Push(LLM_UnescapeJSON(m[1]))
		pos := m.Pos + m.Len
	}
	return result
}

/**
 * Returns the stop-sequence array for the given backend variant from
 * inference.json (single source). Variants: "batch", "line".
 * Raises if the key is absent — fail fast.
 * @param {string} variant - Key within stop_sequences in inference.json.
 * @returns {Array} Array of stop-token strings.
 */
LLM_ApiCommon_GetStopSequences(variant) {
	return _LLM_Common_GetStringArray("stop_sequences", variant)
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

	for _, existing in results {
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





; ===========================================
; ===========================================
; ======= 4/ Timer / Deadline Helpers =======
; ===========================================
; ===========================================

/**
 * Returns true when the elapsed time since start_tick meets or exceeds timeout_ms.
 * Uses modular subtraction so comparisons remain correct across the 32-bit
 * A_TickCount wrap that occurs after ~49.7 days of uptime.
 * @param {Integer} start_tick  - A_TickCount captured when the operation started.
 * @param {Integer} timeout_ms  - Maximum allowed duration in milliseconds.
 * @returns {Integer} 1 (true) when timed out, 0 (false) otherwise.
 */
_LLM_DeadlineExpired(start_tick, timeout_ms) {
	return TickExpired(start_tick, timeout_ms)
}




; =====================================
; =====================================
; ======= 5/ Logging Helpers ==========
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
	try LoggerDebug("LLMCommon", "Prediction summary [{1}]: requested={2}, candidates={3}, duplicates={4}, kept={5}.",
		mode, requested, candidates, duplicates, kept_count)
}

/**
 * Runs the OS/COM half of a cancellation off the calling thread.
 *
 * Every keystroke reaches LLM_Engine_OnKeystroke, which takes Critical and then
 * cancels whatever is in flight. Critical suspends the message pump, so a
 * TerminateProcess that does not return promptly — an anti-virus filter on the
 * target, a WerFault dialog — starves the keyboard hook for exactly as long as
 * it blocks. Flipping the cancelled flags is pure memory and must stay inside
 * Critical, because the poll ticks read them; killing the transport is OS work
 * and has no business being there.
 *
 * A negative SetTimer period runs the callback on a NEW thread once the current
 * one finishes, i.e. after Critical has been restored. This is the same
 * mechanism the spawn side already uses to keep Run() off the keystroke path.
 *
 * Kills MUST be a snapshot taken under Critical, never a live Map: the entries
 * it refers to are mutated and deleted by the poll ticks that run in between.
 *
 * @param {Array} Kills - Array of Maps carrying an exact cancel callback,
 *                        a legacy PID, and/or a WinHTTP object.
 */
LLM_DeferCancelKills(Kills) {
	if (!IsObject(Kills) or Kills.Length == 0)
		return
	SetTimer(() => _LLM_RunCancelKills(Kills), -1)
}

_LLM_RunCancelKills(Kills) {
	for _, K in Kills {
		if K.Has("cancel")
			try K["cancel"].Call()
		if (K.Has("pid") and K["pid"] > 0)
			try ProcessClose(K["pid"])
		if K.Has("http")
			try K["http"].Abort()
	}
}


; Invoke an LLM completion callback so a throw inside it can never vanish.
;
; Every backend hands its result to a caller-supplied callback, and 49 of those
; hand-offs were written as a bare `_LLM_InvokeCallback(on_x, "on_x", ...)`. A bare try discards the
; exception with no log line at all, so an engine-side throw — a malformed
; response the parser chokes on, a renderer that hits an unset global — looked
; exactly like a request that simply never completed: no prediction, no error,
; nothing to search for. This is the class the adapters were already ratcheted
; against; the LLM backends were never brought in line.
;
; The catch is deliberate rather than a rethrow: these run from HTTP completion
; handlers and timer callbacks, where an escaping exception reaches the global
; error net and, before the driver is ready, is treated as fatal. Logging and
; abandoning the one request is the correct blast radius.
;
; @param Fn    {Func}   The callback. A falsy value is a no-op, matching the
;                       previous `try` behaviour when the caller passed nothing.
; @param Name  {String} Callback name, for the log line.
; @param Args* {Any}    Forwarded verbatim.
_LLM_InvokeCallback(Fn, Name, Args*) {
    if !Fn
        return
    try {
        Fn(Args*)
    } catch as Err {
        try LoggerError("LLM", "Callback '{1}' raised: {2}. This request is abandoned — nothing downstream retries it, so the user simply never sees a prediction.", Name, Err.Message)
    }
}
