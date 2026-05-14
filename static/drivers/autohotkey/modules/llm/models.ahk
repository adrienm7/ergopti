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
	; This file lives at: .../autohotkey/modules/llm/models.ahk
	; _shared lives at:   .../autohotkey/../_shared/llm/
	base := A_ScriptDir  ; typically .../autohotkey/

	candidates := [
		base "\..\..\_shared\llm\" filename,
		base "\..\_shared\llm\" filename,
		base "\_shared\llm\" filename,
	]

	for path in candidates {
		if FileExist(path)
			return path
	}
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
 * @returns {Map} Flat index: Map(name -> Map("ollama", tag, "mlx", tag)).
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
		; JSON structure: [{families:[{models:[{name,urls:{ollama,mlx}}]}]}]
		pos := 1
		while (RegExMatch(raw, '"name"\s*:\s*"([^"]+)"', &nm, pos)) {
			model_name := nm[1]
			after_name := SubStr(raw, nm.Pos + nm.Len)

			ollama_tag := ""
			mlx_tag    := ""

			; Look for urls block close to this name (within 500 chars)
			nearby := SubStr(after_name, 1, 500)
			if RegExMatch(nearby, '"ollama"\s*:\s*"([^"]+)"', &om)
				ollama_tag := LLM_ExtractTagFromURL(om[1])
			if RegExMatch(nearby, '"mlx"\s*:\s*"([^"]+)"', &mm)
				mlx_tag := LLM_ExtractTagFromURL(mm[1])

			entry := Map("ollama", ollama_tag, "mlx", mlx_tag)
			index[model_name] := entry
			pos := nm.Pos + nm.Len
		}
	} catch {
		; JSON unreadable — return empty index
	}
	return index
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
