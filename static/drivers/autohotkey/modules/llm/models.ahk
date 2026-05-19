; modules/llm/models.ahk

; ==============================================================================
; MODULE: LLM Models Registry
; DESCRIPTION:
; Loads the shared model catalogue from _shared/llm/models.json and exposes
; helpers to resolve Ollama model tags from display names.
;
; FEATURES & RATIONALE:
; 1. Shared data: models.json is canonical for all platforms — no duplication.
; 2. Runtime path: computed relative to this script file so it works regardless
;    of where Hammerspoon or AHK installs the driver bundle.
; 3. Lazy load: JSON is parsed once and cached for the session lifetime.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 1/ Path Resolution =======
; ==================================
; ==================================

/**
 * Returns the absolute path to a file inside _shared/llm/.
 * Walks up from the current script location to find the _shared sibling.
 * @param {string} filename - Filename within _shared/llm/ (e.g. "models.json").
 * @returns {string} Absolute path, or "" if not found.
 */
LLM_GetSharedPath(filename) {
	global _StaticDir
	; _StaticDir resolves to <repo>/static (dev) or A_ScriptDir\static
	; (compiled). _shared lives under drivers/_shared in both layouts so a
	; single canonical path is enough; the legacy multi-candidate fallback
	; was only useful when the script could be invoked from arbitrary cwds.
	canonical := _StaticDir . "\drivers\_shared\llm\" . filename
	if FileExist(canonical)
		return canonical
	return ""
}




; =================================
; =================================
; ======= 2/ Model Registry =======
; =================================
; =================================

global _LLM_ModelsCache := unset

/**
 * Returns the flat model index, loading from JSON on first call.
 * @returns {Map} Index keyed by display name, values are Map("ollama", tag).
 */
LLM_GetModelIndex() {
	global _LLM_ModelsCache
	if IsSet(_LLM_ModelsCache)
		return _LLM_ModelsCache
	_LLM_ModelsCache := LLM_LoadModelsJSON()
	return _LLM_ModelsCache
}

/**
 * Resolves the Ollama tag for a model display name.
 * @param {string} display_name - The "name" field from models.json.
 * @returns {string} Ollama model tag, or the display_name itself as fallback.
 */
LLM_ResolveOllamaTag(display_name) {
	index := LLM_GetModelIndex()
	if index.Has(display_name) {
		entry := index[display_name]
		if entry.Has("ollama") && entry["ollama"] != ""
			return entry["ollama"]
	}
	; Unknown model: pass the name as-is (may work if already a valid tag)
	return display_name
}

/**
 * Returns all available model display names from the shared catalogue.
 * @returns {Array} Sorted array of display name strings.
 */
LLM_GetAllModelNames() {
	index := LLM_GetModelIndex()
	names := []
	for name, _ in index
		names.Push(name)
	names.Sort()
	return names
}




; =====================================
; =====================================
; ======= 3/ JSON Loading =======
; =====================================
; =====================================

/**
 * Parses models.json and returns a flat index keyed by model display name.
 *
 * Each entry exposes the fields the rest of the AHK stack actually needs:
 *   - ollama        : Ollama tag (resolved from urls.ollama or empty).
 *   - mlx           : MLX tag (resolved from urls.mlx or empty) — kept for
 *                     parity with the HS catalogue even though MLX itself
 *                     does not run on Windows.
 *   - params_b      : total parameter count in billions (number, 0 = unknown).
 *   - active_b      : active parameter count in billions (MoE active expert
 *                     count, falls back to params_b when undefined).
 *   - ram_gb        : approximate RAM footprint at inference time (number,
 *                     0 = unknown) — read from hardware_requirements.mlx.ram_gb
 *                     (mlx because it is reported across more entries than
 *                     ollama; ram is a function of weights, not runtime).
 *   - speed_tok_s   : capabilities.speed_tok_s — used to drive the model
 *                     browser's "speed" badge.
 *   - type          : "chat" | "completion" — toggles the raw / chat profile
 *                     auto-pick.
 *
 * @returns {Map} Flat index keyed by display name.
 */
LLM_LoadModelsJSON() {
	index := Map()
	models_path := LLM_GetSharedPath("models.json")
	if (models_path == "")
		return index

	try {
		fh := FileOpen(models_path, "r", "UTF-8")
		if !IsObject(fh)
			return index
		raw := fh.Read()
		fh.Close()

		; Extract all model "name" + urls.ollama + urls.mlx blocks
		; JSON structure: [{families:[{models:[{name,urls:{ollama,mlx},parameters:{total,active},hardware_requirements:{mlx:{ram_gb}}}]}]}]
		; We scan name → nearby (500 chars) for the rest of the metadata. The
		; 500-char window matches LLM_LoadModelsJSON's existing heuristic and
		; is wide enough to capture the typical model record without
		; accidentally bleeding into the next entry.
		pos := 1
		while (RegExMatch(raw, '"name"\s*:\s*"([^"]+)"', &nm, pos)) {
			model_name := nm[1]
			after_name := SubStr(raw, nm.Pos + nm.Len)
			nearby := SubStr(after_name, 1, 1500)

			ollama_tag := ""
			mlx_tag    := ""
			params_b   := 0.0
			active_b   := 0.0
			ram_gb     := 0.0
			speed_tok  := 0
			model_type := "chat"

			if RegExMatch(nearby, '"ollama"\s*:\s*"([^"]+)"', &om)
				ollama_tag := LLM_ExtractTagFromURL(om[1])
			if RegExMatch(nearby, '"mlx"\s*:\s*"([^"]+)"', &mm)
				mlx_tag := LLM_ExtractTagFromURL(mm[1])

			; "parameters" : { "total" : "30.53B" , "active" : "3B" }
			if RegExMatch(nearby, '"parameters"\s*:\s*\{[^}]*?"total"\s*:\s*"([^"]+)"', &pm)
				params_b := _LLM_ParseBillions(pm[1])
			if RegExMatch(nearby, '"parameters"\s*:\s*\{[^}]*?"active"\s*:\s*"([^"]+)"', &am)
				active_b := _LLM_ParseBillions(am[1])
			if (active_b == 0)
				active_b := params_b

			; "hardware_requirements" : { "mlx" : { "ram_gb" : 17.3 } }
			if RegExMatch(nearby, '"ram_gb"\s*:\s*([0-9]+(?:\.[0-9]+)?)', &rm)
				ram_gb := rm[1] + 0

			; "speed_tok_s" : 80
			if RegExMatch(nearby, '"speed_tok_s"\s*:\s*([0-9]+(?:\.[0-9]+)?)', &sm)
				speed_tok := sm[1] + 0

			; "type" : "chat" | "completion"
			if RegExMatch(nearby, '"type"\s*:\s*"([^"]+)"', &tm)
				model_type := tm[1]

			entry := Map(
				"ollama",      ollama_tag,
				"mlx",         mlx_tag,
				"params_b",    params_b,
				"active_b",    active_b,
				"ram_gb",      ram_gb,
				"speed_tok_s", speed_tok,
				"type",        model_type
			)
			index[model_name] := entry
			pos := nm.Pos + nm.Len
		}
	} catch {
		; JSON unreadable — return empty index
	}
	return index
}

/**
 * Parses a "30.53B" / "3B" / "750M" style parameter count and returns the
 * numeric value in **billions**. Returns 0 on malformed input so the caller
 * can safely use the result for thresholds without an isFinite-style guard.
 *
 * @param {string} s - Raw parameters string from models.json.
 * @returns {number} Parameter count in billions.
 */
_LLM_ParseBillions(s) {
	if (s == "")
		return 0.0
	; Strip any non-numeric trailing decoration; capture the leading number
	; and the optional B/M suffix (case-insensitive).
	if !RegExMatch(s, "^([0-9]+(?:\.[0-9]+)?)\s*([BbMm]?)", &m)
		return 0.0
	val := m[1] + 0
	unit := StrLower(m[2])
	if (unit == "m")
		return val / 1000.0
	return val
}

/**
 * Returns the metadata Map for a given model display name, or an empty
 * placeholder when the model is unknown. Centralises the "missing key →
 * defaults" branch so callers can read fields unconditionally.
 *
 * @param {string} display_name - Name as stored in models.json.
 * @returns {Map} Metadata Map (always non-empty).
 */
LLM_GetModelInfo(display_name) {
	index := LLM_GetModelIndex()
	if index.Has(display_name)
		return index[display_name]
	return Map(
		"ollama", "", "mlx", "",
		"params_b", 0.0, "active_b", 0.0,
		"ram_gb", 0.0, "speed_tok_s", 0,
		"type", "chat"
	)
}

/**
 * Extracts the model tag (last path segment) from a HuggingFace or Ollama URL.
 * @param {string} url - Full URL string.
 * @returns {string} The last path segment, or "" if not parseable.
 */
LLM_ExtractTagFromURL(url) {
	if RegExMatch(url, "/([^/]+)$", &m)
		return m[1]
	return ""
}
