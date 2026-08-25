; ui/menu/menu_llm/menu_models.ahk

; ==============================================================================
; MODULE: LLM Tray — Backend + Model submenus
; DESCRIPTION:
; Builds the Backend selector ("Ollama" / "API"), the Model picker (curated
; catalogue parsed from _shared/modules/llm/models.json), the per-model sub-submenu
; (specs / capabilities / hardware requirements / source URL), and the
; auxiliary "+ Add an API…" entry that delegates to menu_api_entries.ahk.
;
; FEATURES & RATIONALE:
; 1. Catalogue-first: when models.json provides Ollama-installable entries,
;    they take precedence over the locally-installed Ollama tags fallback.
; 2. Always-full catalogue: the curated list (from the static models.json) is
;    shown in full whether or not the feature is enabled or Ollama is reachable,
;    mirroring Hammerspoon — selecting a model while off just records the choice.
;    Only the green "installed" dot needs Ollama, so its probe is skipped (rows
;    render dot-less) until the daemon is ready, keeping the menu non-blocking.
; 3. Per-iteration closure factories: the for-loop captures via ``_LLM_Menu_Make*``
;    factories rather than ``captured := value`` because AHK v2 closure scopes
;    are per-call, not per-iteration.
; ==============================================================================

#Requires AutoHotkey v2.0

; Delay before the menu is rebuilt after launching an `ollama pull` in its own
; terminal. Long enough that a small model has usually finished and the green
; "installed" dot appears on the first glance back at the tray; short enough that
; the user is unlikely to have opened the menu again before it fires. It is a
; cosmetic refresh, not a correctness deadline — the dot also updates on the next
; health probe — so it is deliberately NOT tied to LLM_HEALTH_PROBE_THROTTLE_MS,
; which happens to hold the same number for an unrelated reason.
global LLM_MENU_POST_PULL_REBUILD_MS := 3000





; ==================================
; ==================================
; ======= 1/ Backend Submenu =======
; ==================================
; ==================================

/**
 * Builds the backend selection submenu.
 * Currently only Ollama is supported on Windows; the list is structured so
 * future backends (e.g., LM Studio, llama.cpp) can be added without refactoring.
 * @returns {Menu} Populated backend submenu.
 */
LLM_Menu_BuildBackendMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_backend", (*) => _LLM_Menu_BackendRows())
	return m
}

/**
 * Row data for the backend submenu.
 * @returns {Array} One row per backend, then the Ollama port and its reset row.
 */
_LLM_Menu_BackendRows() {
	global _LLM_Menu
	; Hardcoded brand prefix per backend — name + emoji + em-dash. Only
	; the localised descriptive suffix (e.g. "Standard" / "fournisseur
	; distant") lives in the i18n catalogue; the rest is the same in
	; every language and would just be noise to translate.
	static _backend_prefix := Map(
		"ollama", "Ollama 🦙 — ",
		"api",    "API 🌐 — "
	)
	Rows := []
	for backend_id in LLM_MENU_BACKEND_OPTIONS {
		prefix := _backend_prefix.Has(backend_id) ? _backend_prefix[backend_id] : ""
		Rows.Push(Map(
			"label",   prefix . t("menu.llm.backend_" backend_id "_suffix"),
			"checked", (backend_id == _LLM_Menu["backend"]),
			"action",  _LLM_Menu_MakeSetBackendHandler(backend_id)))
	}

	; Ollama server port — the local daemon's port (11434 by default). Configurable
	; so a user running Ollama on a non-standard port (or behind a proxy) can still
	; reach it. Shown unconditionally: the user may set it before switching backend.
	Rows.Push(Map("separator", true))
	port_display := _LLM_Menu.Has("ollama_port") ? _LLM_Menu["ollama_port"] : _LLM_DefaultFor("llm_ollama_port")
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.ollama_port_label"), "%s", port_display),
		"action", (*) => LLM_Menu_PromptOllamaPort()))
	_LLM_MaybeResetRow(Rows,
		port_display,
		_LLM_DefaultFor("llm_ollama_port"),
		(*) => LLM_Menu_ResetOllamaPort(_LLM_DefaultFor("llm_ollama_port")))
	return Rows
}





; ================================
; ================================
; ======= 2/ Model Submenu =======
; ================================
; ================================

/**
 * Builds the model selection submenu. Mirrors the Hammerspoon driver's
 * curated catalogue: one provider per submenu, families separated by a
 * divider, each model row carrying a rich title (install dot, type badge,
 * params + RAM) and a per-model sub-submenu with specs and source URL.
 *
 * The catalogue is parsed from the shared ``_shared/modules/llm/models.json``
 * (loaded by ``LLM_GetModelPresets``). When the catalogue is empty or
 * unreadable, the function falls back to the legacy "installed Ollama
 * tags only" list so the user always has a picker.
 *
 * @returns {Menu} Populated model submenu.
 */
LLM_Menu_BuildModelMenu() {
	global _LLM_Menu
	; Backend == "api": the model picker becomes an "API endpoints" picker —
	; one entry per user-added provider record, plus "+ Add an API…" at the
	; bottom. The remote adapter (LLM_RemoteGenerate) reads the active entry
	; by id at request time.
	if (_LLM_Menu["backend"] == "api") {
		return _LLM_Menu_BuildApiEntriesMenu()
	}

	m := Menu()
	active := _LLM_Menu["model"]

	; The curated catalogue is STATIC (parsed from the shared models.json), so it
	; is listed in FULL regardless of whether the LLM feature is enabled or the
	; Ollama daemon is reachable — exactly like the Hammerspoon driver, whose model
	; submenu is gated only by "paused", never by the enabled flag. Picking a model
	; while the feature is off simply records the choice; predictions resume once
	; the user re-enables. Only the green "installed" dot needs Ollama, so the
	; per-row install probe is skipped (rows render dot-less, with a "Download"
	; action) until the daemon is confirmed ready — that keeps the menu instant and
	; never blocks on a /api/tags round-trip while the feature is intentionally off.
	deps_ready := LLM_Deps_IsReady()

	; "Aucun modèle (Désactivé)" — first row of the HS menu.
	HeadRows := [Map(
		"label",   t("menu.llm.no_model"),
		"checked", (active == ""),
		"action",  _LLM_Menu_MakeSetModelHandler(""))]

	; Backend default — shortcut that restores the canonical Ollama tag
	; without scrolling the catalogue. Reads from the shared defaults.json
	; so any change to the canonical default propagates here automatically.
	default_name := _LLM_DefaultFor("llm_model", "")
	if (default_name != "") {
		HeadRows.Push(Map(
			"label",   StrReplace(t("menu.llm.backend_default_model"), "%s", default_name),
			"checked", (active == default_name),
			"action",  _LLM_Menu_MakeSetModelHandler(default_name)))
	}
	HeadRows.Push(Map("separator", true))
	MenuRenderer_AppendRows(m, "llm_menu", "llm_model", HeadRows)

	; Curated catalogue — provider → family → model. Family boundaries are
	; rendered as separators inside the provider submenu (matches HS's
	; ``models_manager`` behaviour: no per-family sub-sub-menu).
	presets := LLM_GetModelPresets()
	presets_used := _LLM_Menu_AppendCatalogue(m, presets, active, deps_ready)

	; Catalogue fallback: when models.json fails to load OR no entry in the
	; catalogue advertises an Ollama URL (e.g. an MLX-only catalogue), fall
	; back to the locally-installed Ollama tag list so the user is never
	; left without a picker. Probe ``ollama list`` only when the daemon is
	; confirmed ready — otherwise the blocking GET /api/tags would freeze the
	; menu while the feature is off (Ollama is usually not running then).
	if (!presets_used) {
		installed := deps_ready ? _LLM_GetInstalledTagsCached() : []
		; An empty list adds NO placeholder row. It used to add one built from
		; t("menu.llm.no_model") — the SAME i18n key as the actionable "Aucun
		; modèle" selector registered at the top of this menu — and AHK v2's
		; Menu.Add with an already-present label modifies that item in place
		; instead of appending, so the raw no-op Add replaced the selector's
		; callback and the Disable that followed greyed out the very row the user
		; needs to clear a configured model (llm-no-model-row-clobbered). The
		; selector already reads "no model" and stays clickable, so the
		; placeholder never carried information the menu was not showing.
		TagRows := []
		for tag in installed {
			TagRows.Push(Map(
				"label",   tag,
				"checked", (tag == active),
				"action",  _LLM_Menu_MakeSetModelHandler(tag)))
		}
		MenuRenderer_AppendRows(m, "llm_menu", "llm_model", TagRows)
	}

	; Visual model browser — exposes the shared models.json catalogue with
	; params / RAM / speed columns so the user can compare specs before
	; picking. Mirrors the HS visual chooser in ui/menu/menu_llm/models_manager.
	MenuRenderer_AppendRows(m, "llm_menu", "llm_model", [
		Map("separator", true),
		Map("label", t("menu.llm.add_model_entry"),     "action", (*) => LLM_Menu_PromptAddModel()),
		Map("label", t("menu.llm.browse_models_entry"), "action", (*) => LLM_ModelBrowser_Show())
	])
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
 * @param {Menu}    m          - Target model menu being assembled.
 * @param {Array}   presets    - Provider list from ``LLM_GetModelPresets``.
 * @param {string}  active     - Currently selected model name (for the checkmark).
 * @param {Boolean} deps_ready - True when the Ollama daemon is confirmed reachable;
 *                               when false the per-row install probe is skipped so
 *                               the menu never blocks while the feature is off.
 * @returns {Boolean} True when the catalogue produced at least one entry.
 */
_LLM_Menu_AppendCatalogue(m, presets, active, deps_ready := true) {
	Rows := _LLM_Menu_CatalogueRows(presets, active, deps_ready)
	if (Rows.Length == 0)
		return false
	MenuRenderer_AppendRows(m, "llm_menu", "llm_model", Rows)
	return true
}

/**
 * The catalogue as row DATA: one provider row per entry, each holding its
 * models, each holding its specs sheet. Three levels, which is what the
 * renderer allows — and the reason the specs sheet is a flat list of disabled
 * rows rather than a section per topic.
 *
 * @param {Array}   presets    - Provider list from ``LLM_GetModelPresets``.
 * @param {string}  active     - Currently selected model name (for the checkmark).
 * @param {Boolean} deps_ready - True when the Ollama daemon is confirmed reachable.
 * @returns {Array} Provider rows; empty when the catalogue yields nothing.
 */
_LLM_Menu_CatalogueRows(presets, active, deps_ready := true) {
	global JSON_NULL
	Rows := []
	if (Type(presets) != "Array" or presets.Length == 0)
		return Rows
	for provider in presets {
		if (Type(provider) != "Map")
			continue
		provider_label := provider.Has("label") ? provider["label"] : ""
		if (provider_label == "")
			continue
		families := provider.Has("families") ? provider["families"] : ""
		if (Type(families) != "Array" or families.Length == 0)
			continue

		ProviderRows := []
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
					ProviderRows.Push(Map("separator", true))
				}

				ProviderRows.Push(Map(
					"label",   _LLM_Menu_BuildModelRowTitle(name, active, deps_ready),
					"checked", (name == active),
					"items",   _LLM_Menu_PerModelRows(name, model, ollama_url, active, deps_ready)))
				family_added_any := true
			}

			if (family_added_any)
				first_family_with_entries := false
		}

		if (ProviderRows.Length > 0)
			Rows.Push(Map("label", provider_label, "items", ProviderRows))
	}
	return Rows
}

/**
 * Builds the rich, single-line label for a model row inside a provider
 * submenu. Mirrors the HS format exactly: optional "🟢 " when locally
 * installed, then the display name, then the type tag, then the parameter
 * count and approximate RAM footprint between parentheses.
 *
 * @param {string}  name       - Model display name from the catalogue.
 * @param {string}  active     - Currently active model (kept for parity; the
 *                               green check is applied by the caller via .Check()).
 * @param {Boolean} deps_ready - When false the install probe is skipped (no dot).
 * @returns {string} Formatted row label.
 */
_LLM_Menu_BuildModelRowTitle(name, active, deps_ready := true) {
	info := LLM_GetModelInfo(name)
	installed := deps_ready ? LLM_IsModelInstalled(name) : false
	status := installed ? "🟢 " : ""
	type_str := " [" . t((info.Has("type") and info["type"] == "completion")
		? "menu.llm.model_type_completion"
		: "menu.llm.model_type_chat") . "]"
	params_b := info.Has("params_b") ? info["params_b"] : 0
	ram_gb   := info.Has("ram_gb")   ? info["ram_gb"]   : 0
	if (params_b > 0) {
		params_lbl := StrReplace(t("menu.llm.model_specs_params"), "{1}", _LLM_Menu_FormatBillions(params_b))
		params_lbl := StrReplace(params_lbl, "{2}", Ceil(ram_gb))
	} else {
		params_lbl := StrReplace(t("menu.llm.model_specs_ram"), "{1}", Ceil(ram_gb))
	}
	return status . name . type_str . params_lbl
}

/**
 * Row data for the per-model sheet shown when the user hovers a model row.
 * Reproduces the HS layout: Select (with checkmark), Delete cache (when
 * installed), Backend + Source URL, then a SPECIFICATIONS section, a
 * CAPABILITIES section, and a HARDWARE REQUIREMENTS section.
 *
 * All info rows carry no action, so the renderer draws them disabled and the
 * user cannot land a no-op click on a spec line.
 *
 * @param {string}  name       - Model display name.
 * @param {Map}     model      - Raw catalogue record (from models.json).
 * @param {string}  ollama_url - Resolved Ollama URL (already verified non-empty).
 * @param {string}  active     - Currently selected model name.
 * @param {Boolean} deps_ready - When false the install probe is skipped: every
 *                               model offers "Download" since nothing is confirmed.
 * @returns {Array} The per-model rows.
 */
_LLM_Menu_PerModelRows(name, model, ollama_url, active, deps_ready := true) {
	Rows := [Map(
		"label",   t("menu.llm.select_model"),
		"checked", (name == active),
		"action",  _LLM_Menu_MakeSetModelHandler(name))]

	if (deps_ready and LLM_IsModelInstalled(name)) {
		Rows.Push(Map(
			"label",  t("menu.llm.delete_model_cache"),
			"action", _LLM_Menu_MakeDeleteCacheHandler(name)))
	} else {
		Rows.Push(Map(
			"label",  t("menu.llm.download_model"),
			"action", _LLM_Menu_MakeDownloadModelHandler(name)))
	}

	Rows.Push(Map("separator", true))
	; A row with no action is drawn disabled by the renderer, which is what every
	; spec line below is: information, not a click target.
	Rows.Push(Map("label", StrReplace(t("menu.llm.model_backend"), "%s", "Ollama")))
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.model_source"), "%s", ollama_url),
		"action", _LLM_Menu_MakeOpenUrlHandler(ollama_url)))

	Rows.Push(Map("separator", true))
	Rows.Push(Map("label", t("menu.llm.specs_header")))

	type_val := model.Has("type") ? model["type"] : ""
	type_label_text := t((type_val == "completion") ? "menu.llm.model_type_completion" : "menu.llm.model_type_chat")
	Rows.Push(Map("label", StrReplace(t("menu.llm.model_type"), "%s", type_label_text)))

	if (model.Has("last_updated") and model["last_updated"] != "" and model["last_updated"] != "Unknown") {
		date_val := model["last_updated"]
		if RegExMatch(date_val, "^(\d{4})-(\d{2})-(\d{2})$", &dm)
			date_val := dm[3] . "/" . dm[2] . "/" . dm[1]
		Rows.Push(Map("label", StrReplace(t("menu.llm.model_date"), "%s", date_val)))
	}

	if (model.Has("parameters") and Type(model["parameters"]) == "Map") {
		params := model["parameters"]
		if (params.Has("total") and params["total"] != "" and params["total"] != "N/A")
			Rows.Push(Map("label", StrReplace(t("menu.llm.model_params_total"), "%s", params["total"])))
		if (params.Has("active") and params["active"] != "" and params["active"] != "N/A")
			Rows.Push(Map("label", StrReplace(t("menu.llm.model_params_active"), "%s", params["active"])))
	}

	if (model.Has("capabilities") and Type(model["capabilities"]) == "Map") {
		caps := model["capabilities"]
		Rows.Push(Map("separator", true))
		Rows.Push(Map("label", t("menu.llm.caps_header")))
		if (caps.Has("speed_tok_s") and _LLM_Menu_IsNumber(caps["speed_tok_s"]))
			Rows.Push(Map("label", StrReplace(t("menu.llm.model_speed"), "%s", caps["speed_tok_s"])))
		if (caps.Has("tags") and Type(caps["tags"]) == "Array" and caps["tags"].Length > 0) {
			joined := ""
			for tag in caps["tags"] {
				joined .= (joined == "" ? "" : ", ") . tag
			}
			Rows.Push(Map("label", StrReplace(t("menu.llm.model_tags"), "%s", joined)))
		}
	}

	if (model.Has("hardware_requirements") and Type(model["hardware_requirements"]) == "Map") {
		hw_root := model["hardware_requirements"]
		if (hw_root.Has("ollama") and Type(hw_root["ollama"]) == "Map") {
			hw := hw_root["ollama"]
			Rows.Push(Map("separator", true))
			Rows.Push(Map("label", StrReplace(t("menu.llm.hw_header"), "%s", "Ollama")))
			if (hw.Has("download_gb") and _LLM_Menu_IsNumber(hw["download_gb"]))
				Rows.Push(Map("label", StrReplace(t("menu.llm.hw_download"), "%s", hw["download_gb"])))
			if (hw.Has("disk_gb") and _LLM_Menu_IsNumber(hw["disk_gb"]))
				Rows.Push(Map("label", StrReplace(t("menu.llm.hw_disk"), "%s", hw["disk_gb"])))
			if (hw.Has("ram_gb") and _LLM_Menu_IsNumber(hw["ram_gb"]))
				Rows.Push(Map("label", StrReplace(t("menu.llm.hw_ram"), "%s", hw["ram_gb"])))
		}
	}

	return Rows
}





; ====================================
; ====================================
; ======= 3/ Closure Factories =======
; ====================================
; ====================================

; AHK v2 closes over outer-scope variables by reference. Inside a for-loop,
; assigning to a temp variable (``captured := value``) does NOT create a
; new closure scope per iteration — every closure would see the LAST loop
; value. The IIFE-style factory below wraps the captured value in a fresh
; function parameter, which IS scoped per call and therefore safe.

_LLM_Menu_MakeSetModelHandler(name) {
	captured := name
	return (*) => LLM_Menu_SetModel(captured)
}

_LLM_Menu_MakeSetNHandler(n) {
	return (name, pos, menu) => LLM_Menu_SetN(n)
}

_LLM_Menu_MakeSetIndentHandler(lvl) {
	return (name, pos, menu) => LLM_Menu_SetIndent(lvl)
}

_LLM_Menu_MakeSetBackendHandler(backend_id) {
	return (name, pos, menu) => LLM_Menu_SetBackend(backend_id)
}

_LLM_Menu_MakeSetProfileHandler(id) {
	return (name, pos, menu) => LLM_Menu_SetProfile(id)
}

_LLM_Menu_MakeUserProfileClickHandler(p) {
	return (name, pos, menu) => LLM_Menu_OnUserProfileClick(p)
}

_LLM_Menu_MakeSelectApiEntryHandler(entry) {
	return (name, pos, menu) => _LLM_Menu_SelectApiEntry(entry)
}

_LLM_Menu_MakeClearOverrideHandler(app_name) {
	return (*) => _LLM_Menu_ClearOverrideFor(app_name)
}

_LLM_Menu_MakeDeleteCacheHandler(name) {
	captured := name
	return (*) => _LLM_Menu_PromptDeleteCachedModel(captured)
}

_LLM_Menu_MakeDownloadModelHandler(name) {
	captured := name
	return (*) => _LLM_Menu_PullModel(captured)
}

/**
 * Launches ``ollama pull <tag>`` in a visible cmd window so the user gets
 * real-time download progress directly in the terminal. Resolves the Ollama
 * tag from the catalogue display name first — identical to the warmup path.
 * After the window closes the tray menu is rebuilt so the green dot appears.
 *
 * @param {string} name - Catalogue display name (e.g. "Qwen 2.5 3B").
 */
_LLM_Menu_PullModel(name) {
	global LLM_MENU_POST_PULL_REBUILD_MS
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
	SetTimer(LLM_Menu_RequestBuild.Bind("post_pull"),
		-LLM_MENU_POST_PULL_REBUILD_MS)
}

_LLM_Menu_MakeOpenUrlHandler(url) {
	captured := url
	return (*) => _LLM_Menu_OpenUrl(captured)
}

_LLM_Menu_OpenUrl(url) {
	try Run(url)
}





; ====================================
; ====================================
; ======= 4/ Catalogue Helpers =======
; ====================================
; ====================================

/**
 * AHK numeric guard for catalogue values. Filters out JSON_NULL (used by
 * models.json for "field absent") and non-numeric strings so the spec rows
 * never read "null" or "" verbatim.
 */
_LLM_Menu_IsNumber(v) {
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
_LLM_Menu_FormatBillions(n) {
	s := Format("{:.2f}", n)
	s := RTrim(s, "0")
	s := RTrim(s, ".")
	return s
}

/**
 * Confirms the delete with the user, then drops the Ollama-side model cache
 * through the async curl-child DELETE /api/delete pattern (mirrors
 * LLM_OllamaListModels_Async — F24). The tray rebuild happens in the
 * completion callback so it never fires before the daemon actually answers.
 */
_LLM_Menu_PromptDeleteCachedModel(name) {
	tag := LLM_ResolveOllamaTag(name)
	if (tag == "")
		return
	title := t("menu.llm.delete_model_title")
	body  := StrReplace(t("menu.llm.delete_model_body"), "%s", name)
	choice := MsgBox(body, title, "YesNo Icon!")
	if (choice != "Yes")
		return
	Owner := _LLM_Menu_BeginOllamaAux("menu_delete:" . tag, tag)
	try LLM_OllamaDeleteModel_Async(tag,
		(ok) => _LLM_Menu_OnDeleteCachedModelDone(name, tag, ok, Owner), 0, Owner)
	catch
		LLM_AuxFinish(Owner)
}
