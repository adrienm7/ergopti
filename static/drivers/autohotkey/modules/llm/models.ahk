; modules/llm/models.ahk

; ==============================================================================
; MODULE: LLM Models Registry
; DESCRIPTION:
; Loads the shared model catalogue from _shared/llm/models.json and exposes the
; hierarchical (provider → family → model) and flat (display name → metadata)
; views the rest of the AHK stack needs.
;
; FEATURES & RATIONALE:
; 1. Shared data: models.json is canonical for all platforms — no duplication
;    between drivers; one edit propagates to both Hammerspoon and AHK.
; 2. Single parse: the file is parsed once on first access and the result is
;    cached for the session lifetime via _LLM_PresetsCache / _LLM_IndexCache.
; 3. Two views: ``LLM_GetModelPresets()`` exposes the curated provider /
;    family hierarchy used by the tray menu's nested submenus, while
;    ``LLM_GetModelIndex()`` keeps the flat lookup used by the API layer
;    (resolve display name → Ollama tag, RAM badge, type, etc.).
; 4. Tolerant access: every per-model getter Maps absent keys to neutral
;    defaults so a partial entry never throws — the menu degrades to a
;    badge-less row rather than locking the driver out of the catalogue.
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




; ====================================
; ====================================
; ======= 2/ Catalogue Caches ========
; ====================================
; ====================================

; Hierarchical preset list — parsed once, kept as the authoritative source.
; Layout mirrors models.json verbatim:
;   [ { label, families: [ { label, models: [ <model>, … ] } ] } ]
global _LLM_PresetsCache := unset

; Flat lookup index built lazily from _LLM_PresetsCache the first time the
; legacy ``LLM_GetModelIndex`` API is hit. Keys are display names, values are
; Maps with the per-model metadata the prediction engine consumes.
global _LLM_IndexCache := unset




; =====================================
; =====================================
; ======= 3/ Public Catalogue API =====
; =====================================
; =====================================

/**
 * Returns the curated catalogue as a hierarchical Array — one entry per
 * provider, each with a ``label`` and ``families`` (Array). Families contain
 * a ``label`` and ``models`` (Array of Maps mirroring the JSON model record).
 *
 * Mirrors Hammerspoon's ``models_mgr.get_presets()`` so both drivers expose
 * the same shape to their menu builders.
 *
 * @returns {Array} Array of provider Maps; empty array if models.json is
 *                  missing or unreadable.
 */
LLM_GetModelPresets() {
	global _LLM_PresetsCache
	if IsSet(_LLM_PresetsCache)
		return _LLM_PresetsCache
	_LLM_PresetsCache := _LLM_LoadPresets()
	return _LLM_PresetsCache
}

/**
 * Returns the flat index keyed by display name. Each value is a Map with the
 * fields consumed by the API / prediction layer: ollama, mlx, params_b,
 * active_b, ram_gb, speed_tok_s, type.
 *
 * @returns {Map} Lookup keyed by display name. Empty when no catalogue.
 */
LLM_GetModelIndex() {
	global _LLM_IndexCache
	if IsSet(_LLM_IndexCache)
		return _LLM_IndexCache
	_LLM_IndexCache := _LLM_BuildFlatIndex(LLM_GetModelPresets())
	return _LLM_IndexCache
}

/**
 * Returns all available model display names from the shared catalogue,
 * sorted alphabetically for stable iteration.
 * @returns {Array} Sorted array of display name strings.
 */
LLM_GetAllModelNames() {
	index := LLM_GetModelIndex()
	names := []
	for name, _ in index
		names.Push(name)
	; Tiny n (~50 entries) — bubble sort keeps the dependency surface
	; minimal and the cost is invisible.
	swapped := true
	while swapped {
		swapped := false
		loop names.Length - 1 {
			i := A_Index
			if (StrCompare(names[i], names[i+1], false) > 0) {
				tmp := names[i]
				names[i] := names[i+1]
				names[i+1] := tmp
				swapped := true
			}
		}
	}
	return names
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
	; Unknown model: pass the name as-is (may work if already a valid tag).
	; Log a warn so a "predictions silently stopped working after I typed a
	; custom model name" diagnostic actually shows up in the unified log —
	; the previous silent fallback hid the symptom.
	try LoggerWarn("LLM.models", "Unknown model '{1}' — passing through as Ollama tag; predictions may fail.", display_name)
	return display_name
}

/**
 * True when the catalogue model's Ollama tag is present in the locally
 * installed Ollama list. Mirrors HS's ``models_mgr.is_model_installed`` —
 * used by the tray menu to paint the green dot next to installed entries.
 *
 * @param {string} display_name - Catalogue name as stored in models.json.
 * @returns {Boolean} True when ``ollama list`` includes the resolved tag.
 */
LLM_IsModelInstalled(display_name) {
	tag := LLM_ResolveOllamaTag(display_name)
	if (tag == "")
		return false
	tags := _LLM_GetInstalledTagsCached()
	tag_lc := StrLower(tag)
	for installed in tags {
		if (StrLower(installed) == tag_lc)
			return true
	}
	return false
}

/**
 * Returns the model's RAM requirement in GB for the active backend, falling
 * back to the MLX figure when the Ollama side is missing (most entries quote
 * the same number for both). 0 when neither is known.
 *
 * @param {string} display_name - Catalogue name as stored in models.json.
 * @returns {number} Estimated RAM use in GB, 0 when unknown.
 */
LLM_GetModelRam(display_name) {
	info := LLM_GetModelInfo(display_name)
	if (info.Has("ram_gb") and info["ram_gb"] > 0)
		return info["ram_gb"]
	return 0
}




; ====================================
; ====================================
; ======= 4/ Internal Loading ========
; ====================================
; ====================================

/**
 * Reads models.json and returns the parsed Array, preserving order. Returns
 * an empty array on any I/O or parse failure — the menu degrades gracefully
 * to its "no catalogue available" path instead of throwing at startup.
 *
 * @returns {Array} Provider list, or [] on failure.
 */
_LLM_LoadPresets() {
	models_path := LLM_GetSharedPath("models.json")
	if (models_path == "")
		return []
	try {
		fh := FileOpen(models_path, "r", "UTF-8")
		if !IsObject(fh)
			return []
		raw := fh.Read()
		fh.Close()
		parsed := JsonParse(raw)
		; Defensive: the file MUST be an Array at the top level. If not,
		; return [] rather than handing a Map to the menu builder which
		; would crash on its first numeric index access.
		if (Type(parsed) != "Array")
			return []
		return parsed
	} catch as e {
		try LoggerError("LLM.models", "Failed to load models.json: {1}.", e.Message)
		return []
	}
}

/**
 * Walks the hierarchical preset list and returns the flat index used by the
 * legacy API. Each model contributes one entry keyed by its display name.
 *
 * @param {Array} presets - Provider list as returned by ``LLM_GetModelPresets``.
 * @returns {Map} Display name → metadata Map.
 */
_LLM_BuildFlatIndex(presets) {
	index := Map()
	if (Type(presets) != "Array")
		return index
	for provider in presets {
		if (Type(provider) != "Map")
			continue
		families := provider.Has("families") ? provider["families"] : []
		if (Type(families) != "Array")
			continue
		for family in families {
			if (Type(family) != "Map")
				continue
			models := family.Has("models") ? family["models"] : []
			if (Type(models) != "Array")
				continue
			for model in models {
				if (Type(model) != "Map")
					continue
				name := model.Has("name") ? model["name"] : ""
				if (name == "")
					continue
				index[name] := _LLM_ExtractModelMetadata(model)
			}
		}
	}
	return index
}

/**
 * Reduces a raw catalogue model record (a Map straight out of JSON) to the
 * compact metadata shape the prediction engine consumes. Centralises every
 * "field absent → neutral default" decision in one place.
 *
 * @param {Map} model - Raw model record from models.json.
 * @returns {Map} Metadata Map with the fields documented at the call sites.
 */
_LLM_ExtractModelMetadata(model) {
	urls := model.Has("urls") and Type(model["urls"]) == "Map" ? model["urls"] : Map()
	ollama_url := urls.Has("ollama") ? urls["ollama"] : ""
	mlx_url    := urls.Has("mlx")    ? urls["mlx"]    : ""

	params := model.Has("parameters") and Type(model["parameters"]) == "Map" ? model["parameters"] : Map()
	params_total  := params.Has("total")  ? params["total"]  : ""
	params_active := params.Has("active") ? params["active"] : ""

	caps := model.Has("capabilities") and Type(model["capabilities"]) == "Map" ? model["capabilities"] : Map()
	speed_tok := caps.Has("speed_tok_s") ? caps["speed_tok_s"] : 0

	; Hardware requirements live under hardware_requirements.<backend>.ram_gb.
	; Prefer the active-backend figure when available, falling back to MLX
	; because mlx is reported on more entries than ollama in practice.
	hw := model.Has("hardware_requirements") and Type(model["hardware_requirements"]) == "Map" ? model["hardware_requirements"] : Map()
	hw_ollama := hw.Has("ollama") and Type(hw["ollama"]) == "Map" ? hw["ollama"] : Map()
	hw_mlx    := hw.Has("mlx")    and Type(hw["mlx"])    == "Map" ? hw["mlx"]    : Map()
	ram_gb := 0.0
	if (hw_ollama.Has("ram_gb") and _LLM_IsNumber(hw_ollama["ram_gb"]))
		ram_gb := hw_ollama["ram_gb"]
	else if (hw_mlx.Has("ram_gb") and _LLM_IsNumber(hw_mlx["ram_gb"]))
		ram_gb := hw_mlx["ram_gb"]

	params_b := _LLM_ParseBillions(params_total)
	active_b := _LLM_ParseBillions(params_active)
	if (active_b == 0)
		active_b := params_b

	model_type := model.Has("type") ? model["type"] : "chat"

	return Map(
		"ollama",      _LLM_TagFromUrl(ollama_url),
		"mlx",         _LLM_TagFromUrl(mlx_url),
		"params_b",    params_b,
		"active_b",    active_b,
		"ram_gb",      ram_gb,
		"speed_tok_s", speed_tok,
		"type",        model_type
	)
}

/**
 * Returns the last path segment of a Hugging Face / Ollama URL — that is the
 * tag the backend's CLI expects. Empty input returns empty so the caller can
 * branch on "no tag advertised for this backend" without a separate flag.
 *
 * @param {string} url - URL string, possibly empty or JSON null sentinel.
 * @returns {string} The trailing path segment, or "".
 */
_LLM_TagFromUrl(url) {
	global JSON_NULL
	if (!IsObject(url) and url != "" and url != JSON_NULL) {
		if RegExMatch(url, "/([^/]+)$", &m)
			return m[1]
	}
	return ""
}

/**
 * Parses a "30.53B" / "3B" / "750M" parameter count and returns the numeric
 * value in **billions**. Returns 0 on malformed input so the caller can use
 * the result for thresholds without an isFinite-style guard.
 *
 * @param {string} s - Raw parameters string from models.json.
 * @returns {number} Parameter count in billions.
 */
_LLM_ParseBillions(s) {
	if (s == "" or not IsObject(s) and s == "N/A")
		return 0.0
	if !RegExMatch(s, "^([0-9]+(?:\.[0-9]+)?)\s*([BbMm]?)", &m)
		return 0.0
	val := m[1] + 0
	unit := StrLower(m[2])
	if (unit == "m")
		return val / 1000.0
	return val
}

/**
 * True when ``v`` is a usable AHK number (not the JSON_NULL sentinel, not an
 * empty string). models.json uses ``null`` for unspecified download_gb /
 * ram_gb fields, which the parser turns into JSON_NULL — those must be
 * rejected before we treat them as zeros.
 */
_LLM_IsNumber(v) {
	global JSON_NULL
	if (v == JSON_NULL)
		return false
	if IsObject(v)
		return false
	if (v == "")
		return false
	; Use Type() — AHK v2 reports "Integer" or "Float" for numeric values.
	t := Type(v)
	return (t == "Integer" or t == "Float")
}




; ====================================
; ====================================
; ======= 5/ Install Detection =======
; ====================================
; ====================================

; Short TTL cache for the locally installed Ollama tag list. Without it the
; tray menu would call ``ollama list`` once per model row at build time, which
; is fine for a handful of entries but becomes a perceptible stutter on a
; catalogue of ~50 models. The 2-second TTL keeps the menu responsive while
; still picking up newly-installed models within a couple of menu opens.
global LLM_INSTALLED_CACHE_TTL_MS := 2000
global _LLM_InstalledTagsCache := unset
global _LLM_InstalledTagsCacheAt := 0

_LLM_GetInstalledTagsCached() {
	global _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt, LLM_INSTALLED_CACHE_TTL_MS
	now := A_TickCount
	if IsSet(_LLM_InstalledTagsCache) and (now - _LLM_InstalledTagsCacheAt) < LLM_INSTALLED_CACHE_TTL_MS
		return _LLM_InstalledTagsCache
	tags := []
	try {
		; LLM_OllamaListModels lives in api_ollama.ahk; treat it as optional
		; so this module remains loadable in tests that stub the Ollama
		; layer out.
		if IsSet(LLM_OllamaListModels)
			tags := LLM_OllamaListModels()
	} catch {
		tags := []
	}
	_LLM_InstalledTagsCache := tags
	_LLM_InstalledTagsCacheAt := now
	return tags
}

/**
 * Extracts the model tag (last path segment) from a HuggingFace or Ollama URL.
 * Kept as a public helper because the model browser uses it directly when
 * resolving custom user-entered URLs.
 * @param {string} url - Full URL string.
 * @returns {string} The last path segment, or "" if not parseable.
 */
LLM_ExtractTagFromURL(url) {
	if RegExMatch(url, "/([^/]+)$", &m)
		return m[1]
	return ""
}
