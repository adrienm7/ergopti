; ui/tray_llm/menu_models.ahk

; ==============================================================================
; MODULE: LLM Tray — Backend + Model submenus
; DESCRIPTION:
; Builds the Backend selector ("Ollama" / "API"), the Model picker (curated
; catalogue parsed from _shared/llm/models.json), the per-model sub-submenu
; (specs / capabilities / hardware requirements / source URL), and the
; auxiliary "+ Add an API…" entry that delegates to menu_api_entries.ahk.
;
; FEATURES & RATIONALE:
; 1. Catalogue-first: when models.json provides Ollama-installable entries,
;    they take precedence over the locally-installed Ollama tags fallback.
; 2. Health-aware placeholder: when Ollama is unreachable, the picker shows
;    only the current selection + "+ Add" / "Browse" so the menu opens
;    instantly without blocking on /api/tags.
; 3. Per-iteration closure factories: the for-loop captures via ``_LLM_Tray_Make*``
;    factories rather than ``captured := value`` because AHK v2 closure scopes
;    are per-call, not per-iteration.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; ==================================
; ======= 1/ Backend Submenu =======
; ==================================
; =====================================

/**
 * Builds the backend selection submenu.
 * Currently only Ollama is supported on Windows; the list is structured so
 * future backends (e.g., LM Studio, llama.cpp) can be added without refactoring.
 * @returns {Menu} Populated backend submenu.
 */
LLM_Tray_BuildBackendMenu() {
	global _LLM_Tray
	m := Menu()
	; Hardcoded brand prefix per backend — name + emoji + em-dash. Only
	; the localised descriptive suffix (e.g. "Standard" / "fournisseur
	; distant") lives in the i18n catalogue; the rest is the same in
	; every language and would just be noise to translate.
	static _backend_prefix := Map(
		"ollama", "Ollama 🦙 — ",
		"api",    "API 🌐 — "
	)
	for backend_id in LLM_TRAY_BACKEND_OPTIONS {
		captured_id := backend_id
		prefix := _backend_prefix.Has(backend_id) ? _backend_prefix[backend_id] : ""
		label := prefix . t("menu.llm.backend_" backend_id "_suffix")
		RegisterMenuItem(m, label, (name, pos, menu) => LLM_Tray_SetBackend(captured_id))
		if (backend_id == _LLM_Tray["backend"])
			m.Check(label)
	}
	return m
}





; ===================================
; ================================
; ======= 2/ Model Submenu =======
; ================================
; ===================================

/**
 * Builds the model selection submenu. Mirrors the Hammerspoon driver's
 * curated catalogue: one provider per submenu, families separated by a
 * divider, each model row carrying a rich title (install dot, type badge,
 * params + RAM) and a per-model sub-submenu with specs and source URL.
 *
 * The catalogue is parsed from the shared ``_shared/llm/models.json``
 * (loaded by ``LLM_GetModelPresets``). When the catalogue is empty or
 * unreadable, the function falls back to the legacy "installed Ollama
 * tags only" list so the user always has a picker.
 *
 * @returns {Menu} Populated model submenu.
 */
LLM_Tray_BuildModelMenu() {
	global _LLM_Tray
	; Backend == "api": the model picker becomes an "API endpoints" picker —
	; one entry per user-added provider record, plus "+ Add an API…" at the
	; bottom. The remote adapter (LLM_RemoteGenerate) reads the active entry
	; by id at request time.
	if (_LLM_Tray["backend"] == "api") {
		return _LLM_Tray_BuildApiEntriesMenu()
	}

	m := Menu()
	active := _LLM_Tray["model"]

	; Early-exit path: backend disabled or Ollama daemon not reachable. The
	; lightweight placeholder UX keeps the menu opening instantly without
	; blocking on a /api/tags probe, while still exposing the "+ Add" and
	; "Browse" actions for the user to bootstrap.
	if !_LLM_Tray["enabled"] || !LLM_Deps_IsReady() {
		placeholder := (active != "") ? active : t("menu.llm.no_model")
		m.Add(placeholder, (*) => 0)
		m.Check(placeholder)
		m.Add()
		RegisterMenuItem(m, t("menu.llm.add_model_entry"),     (*) => LLM_Tray_PromptAddModel())
		RegisterMenuItem(m, t("menu.llm.browse_models_entry"), (*) => LLM_ModelBrowser_Show())
		return m
	}

	; "Aucun modèle (Désactivé)" — first row of the HS menu.
	no_label := t("menu.llm.no_model")
	RegisterMenuItem(m, no_label, _LLM_Tray_MakeSetModelHandler(""))
	if (active == "")
		m.Check(no_label)

	; Backend default — shortcut that restores the canonical Ollama tag
	; without scrolling the catalogue. Reads from the shared defaults.json
	; so any change to the canonical default propagates here automatically.
	default_tag := _LLM_DefaultFor("llm_model_ollama", "")
	if (default_tag != "") {
		def_label := StrReplace(t("menu.llm.backend_default_model"), "%s", default_tag)
		RegisterMenuItem(m, def_label, _LLM_Tray_MakeSetModelHandler(default_tag))
		if (active == default_tag)
			m.Check(def_label)
	}

	m.Add()  ; separator

	; Curated catalogue — provider → family → model. Family boundaries are
	; rendered as separators inside the provider submenu (matches HS's
	; ``models_manager`` behaviour: no per-family sub-sub-menu).
	presets := LLM_GetModelPresets()
	presets_used := _LLM_Tray_AppendCatalogue(m, presets, active)

	; Catalogue fallback: when models.json fails to load OR no entry in the
	; catalogue advertises an Ollama URL (e.g. an MLX-only catalogue), fall
	; back to the locally-installed Ollama tag list so the user is never
	; left without a picker.
	if (!presets_used) {
		installed := LLM_OllamaListModels()
		if (installed.Length == 0) {
			no_models_label := t("menu.llm.no_model")
			m.Add(no_models_label, (*) => 0)
			m.Disable(no_models_label)
		} else {
			for tag in installed {
				RegisterMenuItem(m, tag, _LLM_Tray_MakeSetModelHandler(tag))
				if (tag == active)
					m.Check(tag)
			}
		}
	}

	m.Add()
	RegisterMenuItem(m, t("menu.llm.add_model_entry"),     (*) => LLM_Tray_PromptAddModel())
	; Visual model browser — exposes the shared models.json catalogue with
	; params / RAM / speed columns so the user can compare specs before
	; picking. Mirrors the HS visual chooser in ui/menu/menu_llm/models_manager.
	RegisterMenuItem(m, t("menu.llm.browse_models_entry"), (*) => LLM_ModelBrowser_Show())
	return m
}

/**
 * Appends one provider submenu per catalogue entry to ``m``. Skips entries
 * with no installable Ollama variant (MLX-only models on Windows would
 * dead-end every click). Returns True when at least one row was added.
 *
 * Kept as a free helper rather than nested inside ``BuildModelMenu`` so the
 * provider loop reads top-to-bottom without three layers of indentation.
 *
 * @param {Menu}   m       - Target model menu being assembled.
 * @param {Array}  presets - Provider list from ``LLM_GetModelPresets``.
 * @param {string} active  - Currently selected model name (for the checkmark).
 * @returns {Boolean} True when the catalogue produced at least one entry.
 */
_LLM_Tray_AppendCatalogue(m, presets, active) {
	global JSON_NULL
	if (Type(presets) != "Array" or presets.Length == 0)
		return false
	any_added := false
	for provider in presets {
		if (Type(provider) != "Map")
			continue
		provider_label := provider.Has("label") ? provider["label"] : ""
		if (provider_label == "")
			continue
		families := provider.Has("families") ? provider["families"] : ""
		if (Type(families) != "Array" or families.Length == 0)
			continue

		provider_menu := Menu()
		provider_has_entries := false
		first_family_with_entries := true

		for family in families {
			if (Type(family) != "Map")
				continue
			models := family.Has("models") ? family["models"] : ""
			if (Type(models) != "Array" or models.Length == 0)
				continue

			family_added_any := false
			for model in models {
				if (Type(model) != "Map" or !model.Has("name"))
					continue
				name := model["name"]
				if (name == "")
					continue

				; Skip models without an Ollama URL — they cannot run on
				; Windows via the Ollama backend, and exposing them in the
				; picker would either dead-end the click or silently pull
				; the wrong tag.
				urls := (model.Has("urls") and Type(model["urls"]) == "Map") ? model["urls"] : Map()
				ollama_url := urls.Has("ollama") ? urls["ollama"] : ""
				if (ollama_url == "" or ollama_url == JSON_NULL)
					continue

				; Separator between families inside the same provider — HS
				; renders families flat with a "-" between groups instead of
				; nested sub-sub-menus. Insert it only once per family, and
				; only if a previous family already contributed rows.
				if (family_added_any == false and !first_family_with_entries) {
					provider_menu.Add()
				}

				rich_title := _LLM_Tray_BuildModelRowTitle(name, active)
				model_menu := _LLM_Tray_BuildPerModelSubmenu(name, model, ollama_url, active)
				provider_menu.Add(rich_title, model_menu)
				if (name == active)
					provider_menu.Check(rich_title)
				family_added_any := true
				provider_has_entries := true
			}

			if (family_added_any)
				first_family_with_entries := false
		}

		if (provider_has_entries) {
			m.Add(provider_label, provider_menu)
			any_added := true
		}
	}
	return any_added
}

/**
 * Builds the rich, single-line label for a model row inside a provider
 * submenu. Mirrors the HS format exactly: optional "🟢 " when locally
 * installed, then the display name, then the type tag, then the parameter
 * count and approximate RAM footprint between parentheses.
 *
 * @param {string} name   - Model display name from the catalogue.
 * @param {string} active - Currently active model (kept for parity; the
 *                          green check is applied by the caller via .Check()).
 * @returns {string} Formatted row label.
 */
_LLM_Tray_BuildModelRowTitle(name, active) {
	info := LLM_GetModelInfo(name)
	installed := LLM_IsModelInstalled(name)
	status := installed ? "🟢 " : ""
	type_str := (info.Has("type") and info["type"] == "completion")
		? " [📝 Complétion]"
		: " [💬 Chat]"
	params_b := info.Has("params_b") ? info["params_b"] : 0
	ram_gb   := info.Has("ram_gb")   ? info["ram_gb"]   : 0
	if (params_b > 0)
		params_lbl := " (" . _LLM_Tray_FormatBillions(params_b) . "B params, ~" . Ceil(ram_gb) . " Go RAM)"
	else
		params_lbl := " (~" . Ceil(ram_gb) . " Go RAM)"
	return status . name . type_str . params_lbl
}

/**
 * Builds the per-model sub-submenu shown when the user hovers a model row.
 * Reproduces the HS layout: Select (with checkmark), Delete cache (when
 * installed), Backend + Source URL, then a SPECIFICATIONS section, a
 * CAPABILITIES section, and a HARDWARE REQUIREMENTS section.
 *
 * All info rows are added as disabled items so the user cannot accidentally
 * trigger a no-op click on a spec line.
 *
 * @param {string} name       - Model display name.
 * @param {Map}    model      - Raw catalogue record (from models.json).
 * @param {string} ollama_url - Resolved Ollama URL (already verified non-empty).
 * @param {string} active     - Currently selected model name.
 * @returns {Menu} The per-model submenu.
 */
_LLM_Tray_BuildPerModelSubmenu(name, model, ollama_url, active) {
	global JSON_NULL
	sub := Menu()

	select_label := t("menu.llm.select_model")
	RegisterMenuItem(sub, select_label, _LLM_Tray_MakeSetModelHandler(name))
	if (name == active)
		sub.Check(select_label)

	if LLM_IsModelInstalled(name) {
		del_label := t("menu.llm.delete_model_cache")
		RegisterMenuItem(sub, del_label, _LLM_Tray_MakeDeleteCacheHandler(name))
	} else {
		dl_label := t("menu.llm.download_model")
		RegisterMenuItem(sub, dl_label, _LLM_Tray_MakeDownloadModelHandler(name))
	}

	sub.Add()  ; separator

	backend_label := StrReplace(t("menu.llm.model_backend"), "%s", "Ollama")
	sub.Add(backend_label, (*) => 0)
	sub.Disable(backend_label)

	source_label := StrReplace(t("menu.llm.model_source"), "%s", ollama_url)
	RegisterMenuItem(sub, source_label, _LLM_Tray_MakeOpenUrlHandler(ollama_url))

	sub.Add()
	specs_header := t("menu.llm.specs_header")
	sub.Add(specs_header, (*) => 0)
	sub.Disable(specs_header)

	type_val := model.Has("type") ? model["type"] : ""
	type_label_text := (type_val == "completion") ? "📝 Complétion" : "💬 Chat"
	type_label := StrReplace(t("menu.llm.model_type"), "%s", type_label_text)
	sub.Add(type_label, (*) => 0)
	sub.Disable(type_label)

	if (model.Has("last_updated") and model["last_updated"] != "" and model["last_updated"] != "Unknown") {
		date_val := model["last_updated"]
		if RegExMatch(date_val, "^(\d{4})-(\d{2})-(\d{2})$", &dm)
			date_val := dm[3] . "/" . dm[2] . "/" . dm[1]
		date_label := StrReplace(t("menu.llm.model_date"), "%s", date_val)
		sub.Add(date_label, (*) => 0)
		sub.Disable(date_label)
	}

	if (model.Has("parameters") and Type(model["parameters"]) == "Map") {
		params := model["parameters"]
		if (params.Has("total") and params["total"] != "" and params["total"] != "N/A") {
			lbl := StrReplace(t("menu.llm.model_params_total"), "%s", params["total"])
			sub.Add(lbl, (*) => 0)
			sub.Disable(lbl)
		}
		if (params.Has("active") and params["active"] != "" and params["active"] != "N/A") {
			lbl := StrReplace(t("menu.llm.model_params_active"), "%s", params["active"])
			sub.Add(lbl, (*) => 0)
			sub.Disable(lbl)
		}
	}

	if (model.Has("capabilities") and Type(model["capabilities"]) == "Map") {
		caps := model["capabilities"]
		sub.Add()
		caps_header := t("menu.llm.caps_header")
		sub.Add(caps_header, (*) => 0)
		sub.Disable(caps_header)
		if (caps.Has("speed_tok_s") and _LLM_Tray_IsNumber(caps["speed_tok_s"])) {
			lbl := StrReplace(t("menu.llm.model_speed"), "%s", caps["speed_tok_s"])
			sub.Add(lbl, (*) => 0)
			sub.Disable(lbl)
		}
		if (caps.Has("tags") and Type(caps["tags"]) == "Array" and caps["tags"].Length > 0) {
			joined := ""
			for tag in caps["tags"] {
				joined .= (joined == "" ? "" : ", ") . tag
			}
			lbl := StrReplace(t("menu.llm.model_tags"), "%s", joined)
			sub.Add(lbl, (*) => 0)
			sub.Disable(lbl)
		}
	}

	if (model.Has("hardware_requirements") and Type(model["hardware_requirements"]) == "Map") {
		hw_root := model["hardware_requirements"]
		if (hw_root.Has("ollama") and Type(hw_root["ollama"]) == "Map") {
			hw := hw_root["ollama"]
			sub.Add()
			hw_header := StrReplace(t("menu.llm.hw_header"), "%s", "Ollama")
			sub.Add(hw_header, (*) => 0)
			sub.Disable(hw_header)
			if (hw.Has("download_gb") and _LLM_Tray_IsNumber(hw["download_gb"])) {
				lbl := StrReplace(t("menu.llm.hw_download"), "%s", hw["download_gb"])
				sub.Add(lbl, (*) => 0)
				sub.Disable(lbl)
			}
			if (hw.Has("disk_gb") and _LLM_Tray_IsNumber(hw["disk_gb"])) {
				lbl := StrReplace(t("menu.llm.hw_disk"), "%s", hw["disk_gb"])
				sub.Add(lbl, (*) => 0)
				sub.Disable(lbl)
			}
			if (hw.Has("ram_gb") and _LLM_Tray_IsNumber(hw["ram_gb"])) {
				lbl := StrReplace(t("menu.llm.hw_ram"), "%s", hw["ram_gb"])
				sub.Add(lbl, (*) => 0)
				sub.Disable(lbl)
			}
		}
	}

	return sub
}





; ===========================================
; ====================================
; ======= 3/ Closure Factories =======
; ====================================
; ===========================================

; AHK v2 closes over outer-scope variables by reference. Inside a for-loop,
; assigning to a temp variable (``captured := value``) does NOT create a
; new closure scope per iteration — every closure would see the LAST loop
; value. The IIFE-style factory below wraps the captured value in a fresh
; function parameter, which IS scoped per call and therefore safe.

_LLM_Tray_MakeSetModelHandler(name) {
	captured := name
	return (*) => LLM_Tray_SetModel(captured)
}

_LLM_Tray_MakeDeleteCacheHandler(name) {
	captured := name
	return (*) => _LLM_Tray_PromptDeleteCachedModel(captured)
}

_LLM_Tray_MakeDownloadModelHandler(name) {
	captured := name
	return (*) => _LLM_Tray_PullModel(captured)
}

/**
 * Launches ``ollama pull <tag>`` in a visible cmd window so the user gets
 * real-time download progress directly in the terminal. Resolves the Ollama
 * tag from the catalogue display name first — identical to the warmup path.
 * After the window closes the tray menu is rebuilt so the green dot appears.
 *
 * @param {string} name - Catalogue display name (e.g. "Qwen 2.5 3B").
 */
_LLM_Tray_PullModel(name) {
	tag := LLM_ResolveOllamaTag(name)
	if (tag == "") {
		MsgBox(StrReplace(t("menu.llm.ollama_model_hint"), "%s", name), t("menu.llm.download_model"), "16")
		return
	}
	; Open a persistent cmd window so the download progress (layer-by-layer
	; progress bars) is fully visible. /k keeps it open after completion so
	; the user can confirm the download succeeded before closing.
	Run('cmd.exe /k ollama pull "' . tag . '"', , "")
	; Rebuild after a short delay so the green dot appears once Ollama finishes
	; (the user will close the window manually; this just keeps the menu fresh
	; if they glance at it again while the terminal is still open).
	SetTimer(() => LLM_Tray_Build(), -3000)
}

_LLM_Tray_MakeOpenUrlHandler(url) {
	captured := url
	return (*) => _LLM_Tray_OpenUrl(captured)
}

_LLM_Tray_OpenUrl(url) {
	try Run(url)
}





; =====================================
; ====================================
; ======= 4/ Catalogue Helpers =======
; ====================================
; =====================================

/**
 * AHK numeric guard for catalogue values. Filters out JSON_NULL (used by
 * models.json for "field absent") and non-numeric strings so the spec rows
 * never read "null" or "" verbatim.
 */
_LLM_Tray_IsNumber(v) {
	global JSON_NULL
	if (v == JSON_NULL)
		return false
	if IsObject(v)
		return false
	if (v == "")
		return false
	t := Type(v)
	return (t == "Integer" or t == "Float")
}

/**
 * Formats a parameter count in billions for display, trimming trailing
 * zeros so 3.00 → 3 and 30.53 → 30.53. Mirrors HS's ``%g`` formatter.
 */
_LLM_Tray_FormatBillions(n) {
	s := Format("{:.2f}", n)
	s := RTrim(s, "0")
	s := RTrim(s, ".")
	return s
}

/**
 * Confirms the delete with the user, then drops the Ollama-side model cache
 * through the HTTP DELETE /api/delete endpoint. The tray rebuild at the end
 * refreshes the installed dot so the row stops showing the green badge.
 */
_LLM_Tray_PromptDeleteCachedModel(name) {
	tag := LLM_ResolveOllamaTag(name)
	if (tag == "")
		return
	title := t("menu.llm.delete_model_title")
	body  := StrReplace(t("menu.llm.delete_model_body"), "%s", name)
	choice := MsgBox(body, title, "YesNo Icon!")
	if (choice != "Yes")
		return
	try LLM_OllamaDeleteModel(tag)
	; Invalidate the install-status cache so the next rebuild reflects the
	; new state immediately instead of waiting for the 2 s TTL.
	global _LLM_InstalledTagsCacheAt
	_LLM_InstalledTagsCacheAt := 0
	LLM_Tray_Build()
}
