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

; The backend catalogue belongs beside its only reader, so definitions-only
; includes build the same menu as the resident driver without the tray bootstrap.
; API uses the shared remote-provider catalogue; MLX remains macOS-only.
global LLM_MENU_BACKEND_OPTIONS := ["ollama", "api"]

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
 * Offers Ollama, saved APIs and discovered local OpenAI-compatible servers.
 * @returns {Menu} Populated backend submenu.
 */
LLM_Menu_BuildBackendMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_backend", (*) => _LLM_Menu_BackendRows())
	return m
}

/**
 * The label of a backend's option in the Backend submenu: its brand and emoji,
 * the same in every language, then an em dash and the localised description.
 * @param {String} BackendId "ollama" or "api".
 * @returns {String} Such as "API 🌐 — Fournisseur distant".
 */
_LLM_Menu_BackendOptionLabel(BackendId) {
	static Brands := Map("ollama", "Ollama 🦙", "api", "API 🌐")
	if !(BackendId is String) || !Brands.Has(BackendId)
		throw ValueError("The Backend submenu offers no backend '"
			. ((BackendId is String) ? BackendId : Type(BackendId)) . "'.")
	CaptionRows := _LLM_Menu_BackendOptionCaptionRows(BackendId, Brands[BackendId])
	if !(CaptionRows is Array) || CaptionRows.Length != 1
		throw Error("Declared backend option caption was refused.")
	return CaptionRows[1]["label"]
}

/**
 * What an option names: its label before the first em dash, trimmed, or the
 * whole label when it has none.
 * @param {String} Label An option label.
 * @returns {String} Such as "API 🌐".
 */
_LLM_Menu_OptionHead(Label) {
	Dash := InStr(Label, "—")
	return Trim(Dash ? SubStr(Label, 1, Dash - 1) : Label)
}

/**
 * The Backend row's label: the selected option as the submenu lists it, cut
 * before its em dash, emoji included. It read « Backend : API » until the
 * maintainer asked on 2026-09-30 for what the submenu shows instead.
 * @returns {String} Such as "Ollama 🦙".
 */
_LLM_Menu_BackendRowLabel() {
	global _LLM_Menu
	; Label lookup must not create a second local-server row view.
	for BackendId in LLM_MENU_BACKEND_OPTIONS {
		if BackendId == _LLM_Menu.Get("backend", "")
			return LLM_Menu_LocalServersBackendLabel(
				_LLM_Menu_OptionHead(_LLM_Menu_BackendOptionLabel(BackendId)))
	}
	try LoggerWarn("LLM", "The Backend submenu offers no option for backend '{1}'.",
		_LLM_Menu.Get("backend", ""))
	return t("menu.llm.backend_unknown")
}

/**
 * Row data for the backend submenu.
 * @returns {Array} One row per backend, then the Ollama port and its reset row.
 */
_LLM_Menu_BackendRows() {
	global _LLM_Menu
	; Admit the genuine boundary and complete static presentation before state reads.
	BoundaryRows := MenuRenderer_TemplateRows("llm_backend_choice_boundary", Map(), Map(), Map())
	Admission := _LLM_Menu_BackendChildFrameRows([], [], [])
	; These nonpublished numeric witnesses exercise both real port/reset declarations.
	PortAdmission := _LLM_Menu_BackendPortRows("0", "1")
	if !(BoundaryRows is Array) || !(Admission is Array) || !(PortAdmission is Array)
		return []
	BackendOptions := LLM_MENU_BACKEND_OPTIONS, OptionCaptions := []
	for backend_id in BackendOptions
		OptionCaptions.Push(_LLM_Menu_BackendOptionLabel(backend_id))
	ChoiceRows := []
	for Index, backend_id in BackendOptions {
		ChoiceRows.Push(Map(
			"label",   OptionCaptions[Index],
			"checked", (backend_id == _LLM_Menu["backend"]),
			"action",  _LLM_Menu_MakeSetBackendHandler(backend_id)))
	}

	; Original current/default reads and late reset-default callback remain native.
	port_display := _LLM_Menu.Has("ollama_port") ? _LLM_Menu["ollama_port"] : _LLM_DefaultFor("llm_ollama_port")
	PortRows := _LLM_Menu_BackendPortRows(port_display, _LLM_DefaultFor("llm_ollama_port"))
	if !(PortRows is Array)
		return []
	LocalRows := LLM_Menu_LocalServersRows()
	Rows := _LLM_Menu_BackendChildFrameRows(ChoiceRows, PortRows, LocalRows)
	return Rows is Array ? Rows : []
}





; ================================
; ================================
; ======= 2/ Model Submenu =======
; ================================
; ================================

/**
 * Display name for one API entry: its automatic name, <provider>/<model> with
 * the model its requests use, told apart from the menu's other entries as the
 * entry list tells it. A name the user typed in an earlier build is not read.
 * @param {Map} Entry API entry record.
 * @returns {String} Such as "cerebras/qwen-3.8-27b".
 */
_LLM_Menu_ApiEntryDisplayName(Entry) {
	global _LLM_Menu
	Entries := (_LLM_Menu is Map) ? _LLM_Menu.Get("api_entries", []) : []
	Id := _LLM_MenuApiEntryGet(Entry, "Id", "")
	if ((Entries is Array) && (Id != "")) {
		for Index, Listed in Entries {
			if (_LLM_MenuApiEntryGet(Listed, "Id", "") == Id)
				return _LLM_Menu_ApiEntryNameList(Entries)[Index]
		}
	}
	return _LLM_Menu_ApiEntryNameList([Entry])[1]
}

/**
 * Text for the model parent row. With backend api the Ollama slot is stale
 * by design — it is preserved so switching back restores it — so the row
 * shows the selected entry instead, never the leftover tag.
 * @returns {String} Model id, provider default, or "".
 */
_LLM_Menu_ModelDisplayText() {
	global _LLM_Menu
	if !(_LLM_Menu is Map)
		return ""
	if (_LLM_Menu.Get("backend", "") == "api") {
		ActiveId := _LLM_Menu.Has("api_entry_id") ? _LLM_Menu["api_entry_id"] : ""
		if ((ActiveId != "") && _LLM_Menu.Has("api_entries")
			&& (_LLM_Menu["api_entries"] is Array)) {
		for E in _LLM_Menu["api_entries"] {
			if (_LLM_MenuApiEntryGet(E, "Id", "") == ActiveId)
				return _LLM_Menu_ApiEntryDisplayName(E)
		}
		}
		return ""
	}
	return _LLM_Menu.Get("model", "")
}

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
	HeadRows := MenuRenderer_TemplateRows("llm_model_picker_head",
		Map("llm_model_none", _LLM_Menu_MakeSetModelHandler("")),
		Map("model_none_selected", (*) => active == "", "model_picker_ready", (*) => true), Map())
	if !(HeadRows is Array)
		return m

	; Backend default — shortcut that restores the canonical Ollama tag
	; without scrolling the catalogue. Reads from the shared defaults.json
	; so any change to the canonical default propagates here automatically.
	default_name := _LLM_DefaultFor("llm_model", "")
	if (default_name != "") {
		DefaultRows := MenuRenderer_TemplateRows("llm_model_picker_default",
			Map("llm_model_backend_default", _LLM_Menu_MakeSetModelHandler(default_name)),
			Map("model_backend_default_caption", (*) => default_name, "model_default_selected", (*) => active == default_name,
				"model_picker_ready", (*) => true), Map())
		if !(DefaultRows is Array)
			return m
		for Row in DefaultRows
			HeadRows.Push(Row)
	}
	HeaderRows := MenuRenderer_TemplateRows("llm_model_header_boundary", Map(), Map(), Map())
	if !(HeaderRows is Array)
		return m
	for Row in HeaderRows
		HeadRows.Push(Row)
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
	MenuRenderer_AppendRows(m, "llm_menu", "llm_model", _LLM_Menu_ModelTailRows())
	return m
}


; The shared inert boundary precedes the unchanged native Add and browser owners.
_LLM_Menu_ModelTailRows() {
	BoundaryRows := MenuRenderer_StatusRows("llm_menu", "llm_model", "model_picker_tail")
	TailRows := BoundaryRows is Array ? BoundaryRows : []
	AddRows := MenuRenderer_TemplateRows("llm_model_add_command",
		Map("llm_add_model_entry", (*) => LLM_Menu_PromptAddModel()), Map("model_picker_ready", (*) => true), Map())
	if !(AddRows is Array)
		return []
	for Row in AddRows
		TailRows.Push(Row)
	BrowserRow := _LLM_Menu_ModelBrowserRow()
	if BrowserRow is Map
		TailRows.Push(BrowserRow)
	return TailRows
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
					FamilyRows := MenuRenderer_TemplateRows("llm_model_family_boundary", Map(), Map(), Map())
					if !(FamilyRows is Array)
						return []
					for Row in FamilyRows
						ProviderRows.Push(Row)
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
	Frame := Map("model_backend_caption", _LLM_Menu_OptionHead(_LLM_Menu_BackendOptionLabel("ollama")),
		"model_source_caption", ollama_url, "model_selected", name == active,
		"model_select_ready", true)
	Commands := Map("model_select", _LLM_Menu_MakeSetModelHandler(name),
		"model_source", _LLM_Menu_MakeOpenUrlHandler(ollama_url))
	if (deps_ready and LLM_IsModelInstalled(name)) {
		Frame["model_delete_present"] := true
		Frame["model_download_present"] := false
		Commands["model_delete"] := _LLM_Menu_MakeDeleteCacheHandler(name)
	} else {
		Frame["model_delete_present"] := false
		Frame["model_download_present"] := true
		Commands["model_download"] := _LLM_Menu_MakeDownloadModelHandler(name)
	}
	Rows := MenuRenderer_TemplateRows("llm_model_action_rows", Commands, _LLM_Menu_ModelFrameGetters(Frame), Map())
	if !(Rows is Array)
		return []
	OriginRows := MenuRenderer_TemplateRows("llm_model_origin_boundary", Map(), Map(), Map())
	if !(OriginRows is Array)
		return []
	for Row in OriginRows
		Rows.Push(Row)
	IdentityRows := _LLM_Menu_ModelDetailAbi(MenuRenderer_TemplateRows("llm_model_identity_rows", Commands, _LLM_Menu_ModelFrameGetters(Frame), Map()))
	if !(IdentityRows is Array)
		return []
	for Row in IdentityRows
		Rows.Push(Row)
	SpecsRows := MenuRenderer_TemplateRows("llm_model_specs_frame", Map(), Map(), Map())
	if !(SpecsRows is Array)
		return []
	for Row in SpecsRows
		Rows.Push(Row)

	type_val := model.Has("type") ? model["type"] : ""
	type_label_text := t((type_val == "completion") ? "menu.llm.model_type_completion" : "menu.llm.model_type_chat")
	Frame["model_type_caption"] := type_label_text
	Frame["model_date_present"] := false
	if (model.Has("last_updated") and model["last_updated"] != "" and model["last_updated"] != "Unknown") {
		date_val := model["last_updated"]
		if RegExMatch(date_val, "^(\d{4})-(\d{2})-(\d{2})$", &dm)
			date_val := dm[3] . "/" . dm[2] . "/" . dm[1]
		Frame["model_date_present"] := true
		Frame["model_date_caption"] := "" . date_val
	}
	Frame["model_params_total_present"] := false
	Frame["model_params_active_present"] := false
	if (model.Has("parameters") and Type(model["parameters"]) == "Map") {
		params := model["parameters"]
		if (params.Has("total") and params["total"] != "" and params["total"] != "N/A") {
			Frame["model_params_total_present"] := true
			Frame["model_params_total_caption"] := "" . params["total"]
		}
		if (params.Has("active") and params["active"] != "" and params["active"] != "N/A") {
			Frame["model_params_active_present"] := true
			Frame["model_params_active_caption"] := "" . params["active"]
		}
	}
	DetailRows := _LLM_Menu_ModelDetailAbi(MenuRenderer_TemplateRows("llm_model_spec_rows", Commands, _LLM_Menu_ModelFrameGetters(Frame), Map()))
	if !(DetailRows is Array)
		return []
	for Row in DetailRows
		Rows.Push(Row)

	if (model.Has("capabilities") and Type(model["capabilities"]) == "Map") {
		caps := model["capabilities"]
		CapsRows := MenuRenderer_TemplateRows("llm_model_caps_frame", Map(), Map(), Map())
		if !(CapsRows is Array)
			return []
		for Row in CapsRows
			Rows.Push(Row)
		Frame["model_speed_present"] := false
		if (caps.Has("speed_tok_s") and _LLM_Menu_IsNumber(caps["speed_tok_s"])) {
			Frame["model_speed_present"] := true
			Frame["model_speed_caption"] := "" . caps["speed_tok_s"]
		}
		Frame["model_tags_present"] := false
		if (caps.Has("tags") and Type(caps["tags"]) == "Array" and caps["tags"].Length > 0) {
			joined := ""
			for tag in caps["tags"] {
				joined .= (joined == "" ? "" : ", ") . tag
			}
			Frame["model_tags_present"] := true
			Frame["model_tags_caption"] := joined
		}
		CapabilityRows := _LLM_Menu_ModelDetailAbi(MenuRenderer_TemplateRows("llm_model_capability_rows", Commands, _LLM_Menu_ModelFrameGetters(Frame), Map()))
		if !(CapabilityRows is Array)
			return []
		for Row in CapabilityRows
			Rows.Push(Row)
	}

	if (model.Has("hardware_requirements") and Type(model["hardware_requirements"]) == "Map") {
		hw_root := model["hardware_requirements"]
		if (hw_root.Has("ollama") and Type(hw_root["ollama"]) == "Map") {
			hw := hw_root["ollama"]
			HardwareRows := MenuRenderer_TemplateRows("llm_model_hardware_boundary", Map(), Map(), Map())
			if !(HardwareRows is Array)
				return []
			for Row in HardwareRows
				Rows.Push(Row)
			Frame["model_hw_backend_caption"] := "Ollama"
			Frame["model_hw_download_present"] := false
			if (hw.Has("download_gb") and _LLM_Menu_IsNumber(hw["download_gb"])) {
				Frame["model_hw_download_present"] := true
				Frame["model_hw_download_caption"] := "" . hw["download_gb"]
			}
			Frame["model_hw_disk_present"] := false
			if (hw.Has("disk_gb") and _LLM_Menu_IsNumber(hw["disk_gb"])) {
				Frame["model_hw_disk_present"] := true
				Frame["model_hw_disk_caption"] := "" . hw["disk_gb"]
			}
			Frame["model_hw_ram_present"] := false
			if (hw.Has("ram_gb") and _LLM_Menu_IsNumber(hw["ram_gb"])) {
				Frame["model_hw_ram_present"] := true
				Frame["model_hw_ram_caption"] := "" . hw["ram_gb"]
			}
			HardwareDetails := _LLM_Menu_ModelDetailAbi(MenuRenderer_TemplateRows("llm_model_hardware_rows", Commands, _LLM_Menu_ModelFrameGetters(Frame), Map()))
			if !(HardwareDetails is Array)
				return []
			for Row in HardwareDetails
				Rows.Push(Row)
		}
	}
	return Rows
}

; The private native values are snapshots of the unchanged catalogue predicates.
_LLM_Menu_ModelFrameValue(Frame, Key) {
	return Frame[Key]
}

_LLM_Menu_ModelFrameGetters(Frame) {
	Getters := Map()
	for Key in Frame
		Getters[Key] := _LLM_Menu_ModelFrameValue.Bind(Frame, Key)
	return Getters
}

_LLM_Menu_ModelDetailAbi(Rows) {
	if !(Rows is Array)
		return false
	for Row in Rows {
		; The existing native renderer disables callback-free data without this flag.
		; Only information frames use this bridge; explicit section headers stay separate.
		if !Row.Has("action") && !Row.Has("items") && !Row.Has("menu") && Row.Get("disabled", false) == true
			Row.Delete("disabled")
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
_LLM_Menu_PullModel(name, IsTag := false, BaseUrl := "", RunFn := 0, ScheduleFn := 0) {
	global LLM_MENU_POST_PULL_REBUILD_MS, LLM_OLLAMA_BASE_URL
	tag := IsTag ? name : LLM_ResolveOllamaTag(name)
	if (tag == "") {
		Ui_MsgBox(StrReplace(t("menu.llm.ollama_model_hint"), "%s", name), t("menu.llm.download_model"), "16")
		return false
	}
	if !(tag is String) || !RegExMatch(tag, "^[A-Za-z0-9_./:-]+$")
		return false
	if BaseUrl == ""
		BaseUrl := LLM_OLLAMA_BASE_URL
	if BaseUrl != LLM_OLLAMA_BASE_URL || !RegExMatch(BaseUrl, "^http://localhost:[0-9]+$")
		return false
	; Open a persistent cmd window so the download progress (layer-by-layer
	; progress bars) is fully visible. /k keeps it open after completion so
	; the user can confirm the download succeeded before closing.
	Command := 'cmd.exe /k set "OLLAMA_HOST=' . BaseUrl . '"&& ollama pull "' . tag . '"'
	try {
		if HasMethod(RunFn, "Call") {
			if RunFn.Call(Command) != true
				return false
		} else
			Run(Command, , "")
	} catch as Err {
		try LoggerWarn("LLM.menu", "Ollama download launch failed: {1}.", Err.Message)
		return false
	}
	; Rebuild after a short delay so the green dot appears once Ollama finishes
	; (the user will close the window manually; this just keeps the menu fresh
	; if they glance at it again while the terminal is still open).
	if HasMethod(ScheduleFn, "Call")
		ScheduleFn.Call(LLM_Menu_RequestBuild.Bind("post_pull"), -LLM_MENU_POST_PULL_REBUILD_MS)
	else
		SetTimer(LLM_Menu_RequestBuild.Bind("post_pull"), -LLM_MENU_POST_PULL_REBUILD_MS)
	return true
}

_LLM_Menu_MakeOpenUrlHandler(url) {
	captured := url
	return (*) => _LLM_Menu_OpenUrl(captured)
}

_LLM_Menu_RunUrl(url) {
	Run(url)
}

_LLM_Menu_OpenUrl(url, RunFn := 0, NotifyFn := 0, LogFn := 0) {
	if !HasMethod(RunFn, "Call")
		RunFn := _LLM_Menu_RunUrl
	try {
		RunFn.Call(url)
		return true
	} catch as Err {
		if HasMethod(LogFn, "Call")
			LogFn.Call(url, Err)
		else
			try LoggerError("LLM.menu",
				"Model source URL launch failed for '{1}': {2}", url, Err.Message)
		Body := t("menu.llm.open_source_failed")
		Title := t("common.error_title")
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(Body, Title)
		else
			try Ui_MsgBox(Body, Title, "Iconx")
		return false
	}
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
	choice := Ui_MsgBox(body, title, "YesNo Icon!")
	if (choice != "Yes")
		return
	Owner := _LLM_Menu_BeginOllamaAux("menu_delete:" . tag, tag)
	_LLM_Menu_RecordDeleteReconcile(Owner, name, tag)
	try LLM_OllamaDeleteModel_Async(tag,
		(ok) => _LLM_Menu_OnDeleteCachedModelDone(name, tag, ok, Owner), 0, Owner)
	catch {
		_LLM_Menu_ClearDeleteReconcile(Owner)
		LLM_AuxFinish(Owner)
	}
}


; The fixed browser command is provider data; native browser fallback owns presentation.
_LLM_Menu_ModelBrowserRow(OpenFn := 0) {
	if !IsObject(OpenFn) && IsSet(LLM_ModelBrowser_Show)
		OpenFn := LLM_ModelBrowser_Show
	return MenuRenderer_CommandRow("llm_model_commands", "llm_browse_models",
		Map("llm_browse_models", OpenFn),
		Map("llm_model_browser_ready", () => IsObject(OpenFn) && HasMethod(OpenFn, "Call")))
}


; Real native brands feed shared suffix policy without inventing a backend catalogue.
_LLM_Menu_BackendOptionCaptionRows(BackendId, Brand) {
	Root := _MR_GetManifestRoot(), Definitions := Map()
	for Key in ["llm_backend_option_caption_frame_ahk", "llm_backend_ollama_option_caption_ahk", "llm_backend_api_option_caption_ahk"]
		Definitions[Key] := Root.Get(Key, false)
	Getters := Map("llm_backend_option_brand", (*) => Brand,
		"llm_backend_option_is_ollama", (*) => BackendId == "ollama",
		"llm_backend_option_is_api", (*) => BackendId == "api")
	Rows := MenuRenderer_TemplateRows("llm_backend_option_caption_frame_ahk", Map(), Getters, Map())
	if !(Rows is Array) || Rows.Length != 1 || _MR_GetManifestRoot() != Root
		return false
	for Key, Definition in Definitions
		if Root.Get(Key, false) != Definition
			return false
	return Rows
}

; The canonical port/reset frame consumes native numeric data and original callbacks.
_LLM_Menu_BackendPortRows(CurrentPort, DefaultPort, PromptCallback := unset, ResetCallback := unset) {
	Root := _MR_GetManifestRoot(), Definitions := Map()
	for Key in ["llm_backend_ollama_port_frame_ahk", "llm_backend_ollama_port_control_ahk", "llm_native_numeric_reset"]
		Definitions[Key] := Root.Get(Key, false)
	Prompt := IsSet(PromptCallback) ? PromptCallback : (*) => LLM_Menu_PromptOllamaPort()
	Reset := IsSet(ResetCallback) ? ResetCallback : (*) => LLM_Menu_ResetOllamaPort(_LLM_DefaultFor("llm_ollama_port"))
	Customized := !(CurrentPort = DefaultPort)
	Getters := Map("llm_backend_ollama_port_caption", (*) => "" . CurrentPort,
		"llm_numeric_reset_caption", (*) => "" . DefaultPort,
		"llm_backend_ollama_port_customized", (*) => Customized)
	Rows := MenuRenderer_TemplateRows("llm_backend_ollama_port_frame_ahk",
		Map("llm_backend_ollama_port", Prompt, "llm_native_numeric_reset", Reset), Getters, Map())
	if !(Rows is Array) || Rows.Length != (Customized ? 2 : 1) || _MR_GetManifestRoot() != Root
		return false
	for Key, Definition in Definitions
		if Root.Get(Key, false) != Definition
			return false
	return Rows
}

; The actual catalogue, numeric controls and local-server owner retain row identities.
_LLM_Menu_BackendChildFrameRows(ChoiceRows, PortRows, LocalRows) {
	for Rows in [ChoiceRows, PortRows, LocalRows] {
		if !(Rows is Array)
			return false
		Loop Rows.Length
			if !Rows.Has(A_Index) || !(Rows[A_Index] is Map)
				return false
	}
	Root := _MR_GetManifestRoot(), Definitions := Map()
	for Key in ["llm_backend_child_frame_ahk", "llm_backend_child_choices_ahk", "llm_backend_choice_boundary",
		"llm_backend_child_port_rows_ahk", "llm_backend_child_local_rows_ahk"]
		Definitions[Key] := Root.Get(Key, false)
	Rows := MenuRenderer_TemplateRows("llm_backend_child_frame_ahk", Map(), Map(),
		Map("llm_backend_child_choices", (*) => ChoiceRows,
			"llm_backend_child_port_rows", (*) => PortRows,
			"llm_backend_child_local_rows", (*) => LocalRows))
	if !(Rows is Array) || _MR_GetManifestRoot() != Root
		return false
	for Key, Definition in Definitions
		if Root.Get(Key, false) != Definition
			return false
	return Rows
}
