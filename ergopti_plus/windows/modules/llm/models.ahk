; modules/llm/models.ahk

; ==============================================================================
; MODULE: LLM Models Registry
; DESCRIPTION:
; Loads the shared model catalogue from _shared/modules/llm/models.json and exposes the
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
 * Returns the absolute path to a file inside _shared/modules/llm/.
 * Walks up from the current script location to find the _shared sibling.
 * @param {string} filename - Filename within _shared/modules/llm/ (e.g. "models.json").
 * @returns {string} Absolute path, or "" if not found.
 */
LLM_GetSharedPath(filename) {
	global _SharedDir
	; so a single canonical path is enough; the legacy multi-candidate fallback
	; was only useful when the script could be invoked from arbitrary cwds.
	canonical := _SharedDir . "\modules\llm\" . filename
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





; =======================================
; =======================================
; ======= 3/ Public Catalogue API =======
; =======================================
; =======================================

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
	for name, in index
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
 * Core resolver — optionally logs when the name cannot be mapped to a known
 * catalogue entry or an installed Ollama tag. ``LLM_IsModelInstalled`` calls
 * this with logging disabled so the tray menu does not spam warnings.
 *
 * @param {string}  display_name - Catalogue display name or raw Ollama tag.
 * @param {boolean} log_unknown  - When true, emit a WARN for unknown names.
 * @returns {string} Ollama tag, or the input unchanged as last resort.
 */
_LLM_ResolveOllamaTagCore(display_name, log_unknown := false) {
	if (display_name == "")
		return ""
	index := LLM_GetModelIndex()
	if index.Has(display_name) {
		entry := index[display_name]
		if entry.Has("ollama") && entry["ollama"] != ""
			return entry["ollama"]
	}
	; Legacy configs and the installed-tag fallback menu store the raw tag.
	tags := _LLM_GetInstalledTagsCached()
	name_lc := StrLower(display_name)
	for _, installed in tags {
		if (StrLower(installed) == name_lc)
			return installed
	}
	; Case-insensitive catalogue display-name match (config.toml drift).
	for cat_name, entry in index {
		if (StrLower(cat_name) == name_lc) {
			if entry.Has("ollama") && entry["ollama"] != ""
				return entry["ollama"]
		}
	}
	if log_unknown {
		try LoggerWarn("LLM.models",
			"Unknown model '{1}' — not in catalogue and not installed locally; predictions may fail.",
			display_name)
	}
	return display_name
}

/**
 * Resolves the Ollama tag for a model display name.
 * @param {string} display_name - The "name" field from models.json.
 * @returns {string} Ollama model tag, or the display_name itself as fallback.
 */
LLM_ResolveOllamaTag(display_name) {
	return _LLM_ResolveOllamaTagCore(display_name, true)
}

/**
 * Picks the best catalogue display name that is installed locally.
 * Prefers the shared AHK default, then any catalogue entry, then the first
 * raw tag from the cached installed list.
 *
 * @returns {string} Display name or raw tag, or "" when Ollama has no models.
 */
LLM_PickBestInstalledDisplayName() {
	preferred := IsSet(LLM_Defaults) && LLM_Defaults.Has("llm_model")
		? LLM_Defaults["llm_model"] : _LLM_LOCAL_DEFAULTS["llm_model"]
	if (preferred != "" && LLM_IsModelInstalled(preferred))
		return preferred
	for _, name in LLM_GetAllModelNames() {
		if LLM_IsModelInstalled(name)
			return name
	}
	; Non-blocking: read the background-refreshed cache. The bridge-start caller
	; waits for LLM_InstalledTagsCacheReady() before reaching this fallback.
	installed := _LLM_GetInstalledTagsCached()
	return (installed.Length > 0) ? installed[1] : ""
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
	tag := _LLM_ResolveOllamaTagCore(display_name, false)
	if (tag == "")
		return false
	tags := _LLM_GetInstalledTagsCached()
	tag_lc := StrLower(tag)
	for _, installed in tags {
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
	raw := FSRead(models_path)
	if (raw == false)
		return []
	try {
		parsed := JsonParse(raw)
		; Defensive: the file MUST be an Array at the top level. If not,
		; return [] rather than handing a Map to the menu builder which
		; would crash on its first numeric index access.
		if (Type(parsed) != "Array")
			return []
		return parsed
	} catch as e {
		err_substr := SubStr(raw, 1, 200)
		try LoggerError("LLM.models", "Failed to load models.json: {1}. Raw (200c): {2}", e.Message, err_substr)
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
	for _, provider in presets {
		if (Type(provider) != "Map")
			continue
		families := provider.Has("families") ? provider["families"] : []
		if (Type(families) != "Array")
			continue
		for _, family in families {
			if (Type(family) != "Map")
				continue
			models := family.Has("models") ? family["models"] : []
			if (Type(models) != "Array")
				continue
			for _, model in models {
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
	if (s == "" or IsObject(s) or s == "N/A")
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
	typeStr := Type(v)
	return (typeStr == "Integer" or typeStr == "Float")
}





; ====================================
; ====================================
; ======= 5/ Install Detection =======
; ====================================
; ====================================

; In-memory snapshot of the locally-installed Ollama tag list, read by the tray
; menu (green install dots) and the tag resolver. It is refreshed ONLY in the
; background: the synchronous ``GET /api/tags`` that used to populate it ran once
; per model row at build time and froze the keyboard thread for up to ~20 s on a
; cold/slow daemon (AUDIT_AHK_2026-06-19 / TODO.md). The single writer is
; ``LLM_SetInstalledTagsCache``, fed by the async tray probe
; (LLM_Menu_FireInstalledTagsProbe). The TTL only throttles how often the async probe
; re-queries the daemon; the read path never consults it.
global LLM_INSTALLED_CACHE_TTL_MS := 0   ; sentinel — sourced at boot by LLMApiLoadTimings ([llm] installed_cache_ttl_ms)
global _LLM_InstalledTagsCache := unset
global _LLM_InstalledTagsCacheAt := 0

/**
 * Returns the most recent in-memory snapshot of the locally-installed Ollama tags.
 * NON-BLOCKING by contract: it NEVER performs the synchronous GET /api/tags — that
 * call, run per catalogue row at every tray rebuild, froze the keyboard thread for
 * up to ~20 s on a cold daemon. The cache is refreshed in the background through
 * LLM_OllamaListModels_Async (see LLM_SetInstalledTagsCache); until the first
 * refresh lands this returns an empty list (no dots yet), exactly like the health
 * dot which paints only after its async probe answers.
 * @returns {Array} Cached tag list (empty until the first refresh lands).
 */
_LLM_GetInstalledTagsCached() {
	global _LLM_InstalledTagsCache
	return IsSet(_LLM_InstalledTagsCache) ? _LLM_InstalledTagsCache : []
}

LLM_InstalledTagsCacheReady() {
	global _LLM_InstalledTagsCache
	return IsSet(_LLM_InstalledTagsCache)
}

/**
 * Replaces the in-memory installed-tags snapshot and stamps the refresh time. The
 * SINGLE writer for the cache that _LLM_GetInstalledTagsCached reads — fed by the
 * tray's async probe callback and the deps-ready sync warm. Logs at DEBUG so a
 * startup trace shows exactly when (and to how many tags) the list last refreshed.
 * @param {Array} tags - Tag names from Ollama (or [] when the daemon is unreachable).
 */
LLM_SetInstalledTagsCache(tags) {
	global _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt
	_LLM_InstalledTagsCache   := (tags is Array) ? tags : []
	_LLM_InstalledTagsCacheAt := A_TickCount
	try LoggerDebug("LLM.models", "Installed-tags cache updated ({1} tag(s)).", _LLM_InstalledTagsCache.Length)
}

/**
 * True when two installed-tag lists differ as SETS (membership, order-insensitive —
 * Ollama's /api/tags ordering is not guaranteed stable across calls). Lets the tray
 * probe repaint only on a real change, mirroring the health dot's flip-guard.
 * @param {Array} old - Previous tag list.
 * @param {Array} new - Freshly-fetched tag list.
 * @returns {Boolean} True when the membership changed.
 */
_LLM_InstalledTagsListChanged(old, new) {
	if !(old is Array) or !(new is Array)
		return true
	if (old.Length != new.Length)
		return true
	for _, tag in new {
		found := false
		for _, o in old {
			if (o == tag) {
				found := true
				break
			}
		}
		if !found
			return true
	}
	return false
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
