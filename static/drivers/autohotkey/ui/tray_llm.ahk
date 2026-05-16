; ui/tray_llm.ahk

; ==============================================================================
; MODULE: LLM Tray Menu UI
; DESCRIPTION:
; System tray menu for the LLM feature on Windows. Provides enable/disable
; toggle, backend selection, model selection, profile selection (built-in and
; user-defined), prediction count, trigger settings, generation settings,
; display settings, and navigation settings — mirroring the Hammerspoon
; menu_llm feature set as closely as possible on Windows.
;
; FEATURES & RATIONALE:
; 1. Tray-native: uses AHK v2's A_TrayMenu / Menu API — no external UI.
; 2. Settings persistence: reads/writes settings via the shared config helpers.
; 3. Ollama check: shows an install prompt if Ollama is not running on startup.
; 4. Lazy bootstrap: Ollama is never touched until the user explicitly enables IA.
; 5. User profiles: custom prompts created/edited/deleted via InputBox dialogs.
; 6. App exclusion: reuses the shared AppPicker_Show() to blacklist processes.
; 7. Trigger shortcut: optional hotkey that fires a prediction on demand.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Tray Menu Constants =======
; ======================================
; ======================================

; Title is resolved at call-time via a function — never at load-time —
; so the active language is already set when the menu is built or rebuilt.

; Available prediction count choices (mirrors HS: for i = 1, 10 do)
global LLM_TRAY_N_OPTIONS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

; Available backend IDs — Ollama is the only Windows backend today; the list
; is kept as an array so adding a future backend only requires appending here.
global LLM_TRAY_BACKEND_OPTIONS := ["ollama"]

; Indent level options for multi-prediction display
global LLM_TRAY_INDENT_OPTIONS := [0, 2, 4, 6]




; ======================================
; ======================================
; ======= 2/ Tray State =======
; ======================================
; ======================================

; Initial values are replaced at startup by LLM_Tray_ApplySharedDefaults()
; which reads from the shared defaults.json via LLM_Defaults (lib/llm_defaults.ahk).
global _LLM_Tray := Map(
	"enabled",                    false,
	"backend",                    "ollama",
	"model",                      "qwen2.5:3b",
	"profile_id",                 "basic",
	"user_profiles",              [],
	"n_predictions",              3,
	"min_words",                  3,
	"max_words",                  15,
	"language",                   "fr",
	"debounce_ms",                500,
	"ctx_chars",                  500,
	"temperature",                "0.10",
	"instant_on_word_end",        true,
	"after_hotstring",            true,
	"reset_on_nav",               true,
	"disable_url_bars",           false,
	"disable_password_fields",    false,
	"disabled_apps",              [],
	"show_info_bar",              true,
	"streaming",                  true,
	"show_all_at_once",           true,
	"pred_indent",                0,
	"auto_raise_temp",            true,
	"nav_modifiers",              "",
	"val_modifiers",              "alt",
	"trigger_shortcut",           ""
)

/**
 * Overwrites _LLM_Tray defaults with values from the shared defaults.json.
 * Called once at module load time, before LLM_Tray_Init() applies saved prefs.
 */
LLM_Tray_ApplySharedDefaults() {
	global _LLM_Tray, LLM_Defaults
	if !IsSet(LLM_Defaults)
		return

	static _key_map := Map(
		"llm_active_profile",          "profile_id",
		"llm_model",                   "model",
		"llm_backend",                 "backend",
		"llm_num_predictions",         "n_predictions",
		"llm_min_words",               "min_words",
		"llm_max_words",               "max_words",
		"llm_debounce_ms",             "debounce_ms",
		"llm_context_length",          "ctx_chars",
		"llm_pred_indent",             "pred_indent",
		"llm_temperature",             "temperature",
		"llm_show_info_bar",           "show_info_bar",
		"llm_streaming",               "streaming",
		"llm_streaming_multi",         "show_all_at_once",
		"llm_instant_on_word_end",     "instant_on_word_end",
		"llm_after_hotstring",         "after_hotstring",
		"llm_reset_on_nav",            "reset_on_nav",
		"llm_auto_raise_temp",         "auto_raise_temp",
		"llm_disable_url_bars",        "disable_url_bars",
		"llm_disable_password_fields", "disable_password_fields",
		"llm_nav_modifiers",           "nav_modifiers",
		"llm_val_modifiers",           "val_modifiers"
	)

	for shared_key, tray_key in _key_map {
		if LLM_Defaults.Has(shared_key)
			_LLM_Tray[tray_key] := LLM_Defaults[shared_key]
	}
}
LLM_Tray_ApplySharedDefaults()

; Persistent Menu object — reused across rebuilds so the tray entry never
; moves. AHK v2 Menu.Delete+Add always appends; updating the same object
; in place is the only way to keep the canonical menu position.
global _LLM_Tray_Menu    := Menu()
global _LLM_Tray_InTray  := false

; Active trigger hotkey object — deleted and recreated on every shortcut change
global _LLM_Tray_TriggerHk := unset




; ========================================
; ========================================
; ======= 3/ Initialisation =======
; ========================================
; ========================================

/**
 * Bootstraps the tray menu and starts the LLM bridge if auto-start is enabled.
 * @param {Map} saved_opts - Persisted settings loaded from INI/registry.
 */
LLM_Tray_Init(saved_opts := Map()) {
	global _LLM_Tray

	static _str_keys := ["model", "profile_id", "language", "temperature", "nav_modifiers", "val_modifiers", "trigger_shortcut", "backend"]
	static _num_keys := ["n_predictions", "min_words", "max_words", "debounce_ms", "ctx_chars", "pred_indent"]
	static _bool_keys := ["enabled", "instant_on_word_end", "after_hotstring", "reset_on_nav",
		"disable_url_bars", "disable_password_fields", "show_info_bar", "streaming",
		"show_all_at_once", "auto_raise_temp"]
	static _arr_keys := ["user_profiles", "disabled_apps"]

	for key in _str_keys
		if saved_opts.Has(key)
			_LLM_Tray[key] := saved_opts[key]
	for key in _num_keys
		if saved_opts.Has(key)
			_LLM_Tray[key] := saved_opts[key]
	for key in _bool_keys
		if saved_opts.Has(key)
			_LLM_Tray[key] := saved_opts[key]
	for key in _arr_keys
		if saved_opts.Has(key) && (saved_opts[key] is Array)
			_LLM_Tray[key] := saved_opts[key]

	; Restore trigger shortcut hotkey
	if (_LLM_Tray["trigger_shortcut"] != "")
		LLM_Tray_ApplyTriggerShortcut(_LLM_Tray["trigger_shortcut"])

	LLM_Tray_Build()

	; Bootstrap Ollama silently on reload when the feature was already enabled.
	; show_ui=false so the install window never opens automatically — the user
	; must click the menu toggle to trigger a visible installation.
	if _LLM_Tray["enabled"]
		SetTimer(() => LLM_Tray_BootstrapOllama(false), -1)
}




; ===================================
; ===================================
; ======= 4/ Menu Construction =======
; ===================================
; ===================================

/**
 * Builds (or rebuilds) the LLM submenu inside the tray.
 * Uses the persistent _LLM_Tray_Menu object: first call registers it in the
 * tray (position is determined by call order in initMenu); subsequent calls
 * delete all items and repopulate in place, so the entry never moves.
 */
LLM_Tray_Build() {
	global _LLM_Tray, _LLM_Tray_Menu, _LLM_Tray_InTray

	; Clear all existing items so we can repopulate in place.
	try _LLM_Tray_Menu.Delete()

	; Enable / Disable toggle
	_llm_is_operational := (_LLM_Tray["enabled"] && LLM_Deps_IsReady())
	AddCategoryToggleItem(_LLM_Tray_Menu,
		t("menu.llm.on"),
		t("menu.llm.off"),
		_llm_is_operational,
		LLM_Tray_OnToggle)

	; Backend submenu
	backend_menu := LLM_Tray_BuildBackendMenu()
	backend_label := t("menu.llm.backend_label")
	_LLM_Tray_Menu.Add(StrReplace(backend_label, "%s", _LLM_Tray["backend"]), backend_menu)

	; Model submenu
	model_menu := LLM_Tray_BuildModelMenu()
	_LLM_Tray_Menu.Add(StrReplace(t("menu.llm.model_label"), "%s", _LLM_Tray["model"]), model_menu)

	; Profile submenu
	profile_menu := LLM_Tray_BuildProfileMenu()
	active_label := LLM_Tray_GetProfileLabel(_LLM_Tray["profile_id"])
	_LLM_Tray_Menu.Add(StrReplace(t("menu.profiles.profile_label_prefix"), "%s", active_label), profile_menu)

	; Number of predictions submenu
	n_menu := LLM_Tray_BuildNMenu()
	_LLM_Tray_Menu.Add(StrReplace(t("menu.llm.num_predictions_label"), "%s", _LLM_Tray["n_predictions"]), n_menu)

	_LLM_Tray_Menu.Add()  ; separator

	; Trigger settings submenu
	trigger_menu := LLM_Tray_BuildTriggerMenu()
	_LLM_Tray_Menu.Add(t("menu.llm.trigger_menu_title"), trigger_menu)

	; Generation settings submenu
	gen_menu := LLM_Tray_BuildGenerationMenu()
	_LLM_Tray_Menu.Add(t("menu.llm.generation_menu_title"), gen_menu)

	; Display settings submenu
	disp_menu := LLM_Tray_BuildDisplayMenu()
	_LLM_Tray_Menu.Add(t("menu.llm.display_menu_title"), disp_menu)

	; Navigation settings submenu
	nav_menu := LLM_Tray_BuildNavMenu()
	_LLM_Tray_Menu.Add(t("menu.llm.nav_menu_title"), nav_menu)

	_LLM_Tray_Menu.Add()  ; separator
	_LLM_Tray_Menu.Add(t("menu.llm.about"), LLM_Tray_OnAbout)

	; Register in the system tray on first call only.
	if !_LLM_Tray_InTray {
		A_TrayMenu.Add(t("menu.llm.title"), _LLM_Tray_Menu)
		_LLM_Tray_InTray := true
	}

	; Check the parent tray entry only when enabled AND Ollama is confirmed ready.
	if (_LLM_Tray["enabled"] && LLM_Deps_IsReady())
		A_TrayMenu.Check(t("menu.llm.title"))
	else
		try A_TrayMenu.Uncheck(t("menu.llm.title"))
}


; =====================================
; ===== 4.1) Backend Submenu =====
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
	for backend_id in LLM_TRAY_BACKEND_OPTIONS {
		captured_id := backend_id
		label := t("menu.llm.backend_" backend_id)
		m.Add(label, (name, pos, menu) => LLM_Tray_SetBackend(captured_id))
		if (backend_id == _LLM_Tray["backend"])
			m.Check(label)
	}
	return m
}


; ================================
; ===== 4.2) Model Submenu =====
; ================================

/**
 * Builds the model selection submenu from installed Ollama models.
 * Adds an "Add custom model" entry at the bottom for power users.
 * @returns {Menu} Populated model submenu.
 */
LLM_Tray_BuildModelMenu() {
	global _LLM_Tray
	m := Menu()

	; Avoid a blocking HTTP call during startup or when Ollama is not ready.
	if !_LLM_Tray["enabled"] || !LLM_Deps_IsReady() {
		placeholder := _LLM_Tray["model"]
		m.Add(placeholder, (*) => 0)
		m.Check(placeholder)
		m.Add()
		m.Add(t("menu.llm.add_model_entry"), (*) => LLM_Tray_PromptAddModel())
		return m
	}

	installed := LLM_OllamaListModels()

	if (installed.Length == 0) {
		no_label := t("menu.llm.no_model")
		m.Add(no_label, (*) => 0)
		m.Disable(no_label)
	} else {
		for tag in installed {
			captured_tag := tag
			m.Add(tag, (name, pos, menu) => LLM_Tray_SetModel(captured_tag))
			if (tag == _LLM_Tray["model"])
				m.Check(tag)
		}
	}

	m.Add()
	m.Add(t("menu.llm.add_model_entry"), (*) => LLM_Tray_PromptAddModel())
	return m
}


; ===================================
; ===== 4.3) Profile Submenu =====
; ===================================

/**
 * Returns the human-readable label for a profile ID.
 * Checks user profiles first, then falls back to i18n built-in labels.
 * @param {string} id - Profile ID.
 * @returns {string} Display label.
 */
LLM_Tray_GetProfileLabel(id) {
	global _LLM_Tray
	n := _LLM_Tray["n_predictions"]
	s := (n > 1) ? "s" : ""

	; Check user profiles
	for p in _LLM_Tray["user_profiles"] {
		if (p.Has("id") && p["id"] == id)
			return p.Has("label") ? p["label"] : id
	}

	; Built-in profile labels
	if (id == "raw")
		return t("llm.profile.raw.label")
	if (id == "basic")
		return t("llm.profile.basic.label")
	if (id == "advanced")
		return t("llm.profile.advanced.label")
	if (id == "batch_advanced")
		return StrReplace(StrReplace(t("llm.profile.batch_advanced.label"), "{n}", n), "{s}", s)
	return id
}

/**
 * Builds the profile selection submenu with built-in and user profiles.
 * @returns {Menu} Populated profile submenu.
 */
LLM_Tray_BuildProfileMenu() {
	global _LLM_Tray
	m := Menu()

	; Section header: built-in profiles
	header_builtin := t("menu.profiles.header_default_profiles")
	m.Add(header_builtin, (*) => 0)
	m.Disable(header_builtin)

	for id in ["raw", "basic", "advanced", "batch_advanced"] {
		captured_id := id
		label := LLM_Tray_GetProfileLabel(id)
		m.Add(label, (name, pos, menu) => LLM_Tray_SetProfile(captured_id))
		if (id == _LLM_Tray["profile_id"])
			m.Check(label)
	}

	; Section: user profiles
	user_profiles := _LLM_Tray["user_profiles"]
	if (user_profiles.Length > 0) {
		m.Add()
		header_custom := t("menu.profiles.header_custom_profiles")
		m.Add(header_custom, (*) => 0)
		m.Disable(header_custom)

		for p in user_profiles {
			captured_p := p
			pid        := p.Has("id") ? p["id"] : ""
			plabel     := p.Has("label") ? p["label"] : pid
			m.Add(plabel, (name, pos, menu) => LLM_Tray_OnUserProfileClick(captured_p))
			if (pid == _LLM_Tray["profile_id"])
				m.Check(plabel)
		}
	}

	m.Add()
	m.Add(t("menu.profiles.create_profile"), (*) => LLM_Tray_PromptCreateProfile())
	return m
}


; ==================================
; ===== 4.4) Count Submenu =====
; ==================================

/**
 * Builds the prediction count submenu (1 to 10).
 * @returns {Menu} Populated count submenu.
 */
LLM_Tray_BuildNMenu() {
	global _LLM_Tray
	m := Menu()
	for n in LLM_TRAY_N_OPTIONS {
		captured_n := n
		label := StrReplace(StrReplace(t("menu.llm.prediction_count_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		m.Add(label, (name, pos, menu) => LLM_Tray_SetN(captured_n))
		if (n == _LLM_Tray["n_predictions"])
			m.Check(label)
	}
	return m
}


; ===================================
; ===== 4.5) Trigger Submenu =====
; ===================================

/**
 * Builds the trigger settings submenu.
 * Mirrors HS: trigger shortcut, debounce (dialog), instant-on-word-end,
 * after-hotstring, reset-on-nav, URL bar filter, password field filter,
 * and the app-exclusion picker.
 * @returns {Menu} Populated trigger submenu.
 */
LLM_Tray_BuildTriggerMenu() {
	global _LLM_Tray
	m := Menu()

	; Trigger shortcut (fires prediction on demand)
	sc_display := _LLM_Tray["trigger_shortcut"] != "" ? _LLM_Tray["trigger_shortcut"] : t("common.none")
	m.Add(StrReplace(t("menu.llm.trigger_shortcut_label"), "%s", sc_display), (*) => LLM_Tray_PromptTriggerShortcut())

	; Debounce — dialog like HS (free numeric input)
	debounce_display := _LLM_Tray["debounce_ms"] . " ms"
	m.Add(StrReplace(t("menu.llm.debounce_label"), "%s", debounce_display), (*) => LLM_Tray_PromptDebounce())

	m.Add()

	; Instant on word end
	instant_label := t("menu.llm.instant_on_word_end")
	m.Add(instant_label, LLM_Tray_OnInstantToggle)
	if _LLM_Tray["instant_on_word_end"]
		m.Check(instant_label)

	; After hotstring (suggest after a hotstring expansion finishes)
	after_hs_label := t("menu.llm.after_hotstring")
	m.Add(after_hs_label, (*) => LLM_Tray_ToggleBool("after_hotstring"))
	if _LLM_Tray["after_hotstring"]
		m.Check(after_hs_label)

	m.Add()

	; URL bar filter
	url_label := t("menu.llm.disable_url_bars")
	m.Add(url_label, (*) => LLM_Tray_ToggleBool("disable_url_bars"))
	if _LLM_Tray["disable_url_bars"]
		m.Check(url_label)

	; Password field filter
	pwd_label := t("menu.llm.disable_password_fields")
	m.Add(pwd_label, (*) => LLM_Tray_ToggleBool("disable_password_fields"))
	if _LLM_Tray["disable_password_fields"]
		m.Check(pwd_label)

	; App exclusion picker
	disabled_apps := _LLM_Tray["disabled_apps"]
	n := disabled_apps.Length
	excl_label := (n > 0)
		? StrReplace(StrReplace(t("menu.llm.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		: t("menu.llm.exclude_from_ai")
	m.Add(excl_label, (*) => LLM_Tray_OpenAppPicker())

	return m
}


; ========================================
; ===== 4.6) Generation Submenu =====
; ========================================

/**
 * Builds the generation settings submenu.
 * All numeric values use InputBox dialogs (same UX as HS settings_manager).
 * @returns {Menu} Populated generation submenu.
 */
LLM_Tray_BuildGenerationMenu() {
	global _LLM_Tray
	m := Menu()

	; Context length — dialog
	ctx_display := _LLM_Tray["ctx_chars"]
	m.Add(StrReplace(t("menu.llm.context_length_label"), "%s", ctx_display), (*) => LLM_Tray_PromptCtxChars())

	; Reset on nav toggle
	nav_label := t("menu.llm.reset_on_nav")
	m.Add(nav_label, (*) => LLM_Tray_ToggleBool("reset_on_nav"))
	if _LLM_Tray["reset_on_nav"]
		m.Check(nav_label)

	m.Add()

	; Min words — dialog
	min_display := _LLM_Tray["min_words"]
	m.Add(StrReplace(t("menu.llm.min_words_label"), "%s", min_display), (*) => LLM_Tray_PromptMinWords())

	; Max words — dialog
	max_val     := _LLM_Tray["max_words"]
	max_display := (max_val == 0) ? t("menu.llm.unlimited") : max_val
	m.Add(StrReplace(t("menu.llm.max_words_label"), "%s", max_display), (*) => LLM_Tray_PromptMaxWords())

	m.Add()

	; Temperature — dialog
	temp_display := _LLM_Tray["temperature"]
	m.Add(StrReplace(t("menu.llm.temperature_label"), "%s", temp_display), (*) => LLM_Tray_PromptTemperature())

	; Auto-raise temperature
	auto_raise_label := t("menu.llm.auto_raise_temp")
	is_batch := (_LLM_Tray["n_predictions"] > 1)
	m.Add(auto_raise_label, (*) => LLM_Tray_ToggleBool("auto_raise_temp"))
	if _LLM_Tray["auto_raise_temp"]
		m.Check(auto_raise_label)
	if !is_batch
		m.Disable(auto_raise_label)

	return m
}


; =====================================
; ===== 4.7) Display Submenu =====
; =====================================

/**
 * Builds the display settings submenu.
 * Mirrors HS display_menu: info bar, streaming, show-all-at-once, indent.
 * @returns {Menu} Populated display submenu.
 */
LLM_Tray_BuildDisplayMenu() {
	global _LLM_Tray
	m := Menu()
	n := _LLM_Tray["n_predictions"]

	; Info bar (shows model name and latency in the tooltip)
	info_label := t("menu.llm.show_info_bar")
	m.Add(info_label, (*) => LLM_Tray_ToggleBool("show_info_bar"))
	if _LLM_Tray["show_info_bar"]
		m.Check(info_label)

	m.Add()

	; Streaming (token-by-token display)
	streaming_label := t("menu.llm.show_streaming")
	m.Add(streaming_label, (*) => LLM_Tray_ToggleBool("streaming"))
	if _LLM_Tray["streaming"]
		m.Check(streaming_label)
	; Streaming only meaningful when show-all-at-once (multi) is enabled
	if !_LLM_Tray["show_all_at_once"]
		m.Disable(streaming_label)

	; Show all predictions at once
	all_at_once_label := t("menu.llm.show_all_at_once")
	m.Add(all_at_once_label, (*) => LLM_Tray_ToggleBool("show_all_at_once"))
	if _LLM_Tray["show_all_at_once"]
		m.Check(all_at_once_label)
	if (n < 2)
		m.Disable(all_at_once_label)

	m.Add()

	; Indent level submenu
	indent_menu := Menu()
	for lvl in LLM_TRAY_INDENT_OPTIONS {
		captured_lvl := lvl
		indent_label := (lvl == 0) ? t("menu.llm.indent_none") : lvl . " " . t("menu.llm.indent_spaces")
		indent_menu.Add(indent_label, (name, pos, menu) => LLM_Tray_SetIndent(captured_lvl))
		if (lvl == _LLM_Tray["pred_indent"])
			indent_menu.Check(indent_label)
	}
	indent_parent_label := t("menu.llm.indent_label")
	m.Add(indent_parent_label, indent_menu)
	if (n < 2)
		m.Disable(indent_parent_label)

	return m
}


; =========================================
; ===== 4.8) Navigation Submenu =====
; =========================================

/**
 * Builds the navigation settings submenu.
 * nav_modifiers: modifier key required to navigate predictions with arrows.
 * val_modifiers: modifier key required to select a prediction by digit.
 * Both accept free-text input (e.g. "ctrl", "alt", "" = no modifier needed).
 * @returns {Menu} Populated navigation submenu.
 */
LLM_Tray_BuildNavMenu() {
	global _LLM_Tray
	m := Menu()
	n := _LLM_Tray["n_predictions"]

	nav_display  := (_LLM_Tray["nav_modifiers"] != "") ? _LLM_Tray["nav_modifiers"] : t("menu.llm.arrows_only")
	nav_item_lbl := t("menu.llm.nav_label") . " — " . nav_display
	m.Add(nav_item_lbl, (*) => LLM_Tray_PromptNavModifiers())
	if (n < 2)
		m.Disable(nav_item_lbl)

	val_display  := (_LLM_Tray["val_modifiers"] != "") ? _LLM_Tray["val_modifiers"] : t("menu.llm.digits_only")
	val_key_range := (n == 10) ? "1-0" : "1-" . n
	val_item_lbl := StrReplace(t("menu.llm.val_label"), "%s", val_key_range) . " — " . val_display
	m.Add(val_item_lbl, (*) => LLM_Tray_PromptValModifiers())
	if (n < 2)
		m.Disable(val_item_lbl)

	return m
}




; =====================================
; =====================================
; ======= 5/ Action Handlers =======
; =====================================
; =====================================

LLM_Tray_OnToggle(*) {
	global _LLM_Tray
	_LLM_Tray["enabled"] := !_LLM_Tray["enabled"]
	LoggerInfo("LLM", "Toggle clicked — enabled: " (_LLM_Tray["enabled"] ? "true" : "false") ".")
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
	if _LLM_Tray["enabled"] {
		SetTimer(LLM_Tray_BootstrapOllama, -1)
	} else {
		LLM_Bridge_Stop()
	}
}

/**
 * Persists the current LLM tray state to the shared config TOML.
 */
LLM_Tray_SaveConfig() {
	global _SaveFullConfigReady
	if IsSet(_SaveFullConfigReady) && _SaveFullConfigReady
		SaveFullConfig()
}

LLM_Tray_OnInstantToggle(*) {
	global _LLM_Tray
	_LLM_Tray["instant_on_word_end"] := !_LLM_Tray["instant_on_word_end"]
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

/**
 * Generic boolean toggle for all simple on/off settings.
 * @param {string} key - The _LLM_Tray key to flip.
 */
LLM_Tray_ToggleBool(key) {
	global _LLM_Tray
	_LLM_Tray[key] := !_LLM_Tray[key]
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

/**
 * Triggers the Ollama deps checker.
 * @param {boolean} show_ui - True when the user explicitly clicked the toggle.
 */
LLM_Tray_BootstrapOllama(show_ui := true) {
	LoggerInfo("LLM", "BootstrapOllama fired — deps state: " LLM_Deps_GetState() " show_ui=" (show_ui ? "true" : "false") ".")
	if LLM_Deps_IsReady() {
		LoggerInfo("LLM", "Ollama already ready — starting bridge directly.")
		LLM_Tray_OnDepsReady()
		return
	}
	LoggerInfo("LLM", "Ollama not ready — launching CheckAndInstall…")
	LLM_Deps_CheckAndInstall(
		_LLM_Tray["model"],
		(*) => LLM_Tray_OnDepsReady(),
		(msg) => LLM_Tray_OnDepsFailed(msg),
		show_ui
	)
}


; ============================================
; ===== 5.1) Setter Handlers =====
; ============================================

LLM_Tray_SetBackend(id) {
	global _LLM_Tray
	_LLM_Tray["backend"] := id
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
}

LLM_Tray_SetModel(tag) {
	global _LLM_Tray
	_LLM_Tray["model"] := tag
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetProfile(id) {
	global _LLM_Tray
	_LLM_Tray["profile_id"] := id
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetN(n) {
	global _LLM_Tray
	_LLM_Tray["n_predictions"] := n
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetIndent(lvl) {
	global _LLM_Tray
	_LLM_Tray["pred_indent"] := lvl
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}


; ===========================================
; ===== 5.2) InputBox Dialog Handlers =====
; ===========================================

/**
 * Opens an InputBox for a numeric setting, validates, and applies it.
 * @param {string} key     - The _LLM_Tray key to update.
 * @param {string} title   - Dialog title.
 * @param {string} prompt  - Dialog prompt text.
 * @param {number} min_val - Minimum valid value (0 = no minimum).
 * @param {number} max_val - Maximum valid value (0 = no maximum).
 */
LLM_Tray_PromptNumeric(key, title, prompt, min_val := 0, max_val := 0) {
	global _LLM_Tray
	ib := InputBox(prompt, title, "w400 h120", _LLM_Tray[key])
	if (ib.Result != "OK" || ib.Value == "")
		return
	val := Integer(ib.Value)
	if (min_val > 0 && val < min_val) || (max_val > 0 && val > max_val)
		return
	_LLM_Tray[key] := val
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_PromptDebounce() {
	LLM_Tray_PromptNumeric("debounce_ms", t("menu.llm.trigger_menu_title"),
		t("menu.llm.debounce_prompt"), 50, 10000)
}

LLM_Tray_PromptCtxChars() {
	LLM_Tray_PromptNumeric("ctx_chars", t("menu.llm.generation_menu_title"),
		t("menu.llm.context_length_prompt"), 50, 10000)
}

LLM_Tray_PromptMinWords() {
	LLM_Tray_PromptNumeric("min_words", t("menu.llm.generation_menu_title"),
		t("menu.llm.min_words_prompt"), 1, 20)
}

LLM_Tray_PromptMaxWords() {
	global _LLM_Tray
	ib := InputBox(t("menu.llm.max_words_prompt"), t("menu.llm.generation_menu_title"), "w400 h120", _LLM_Tray["max_words"])
	if (ib.Result != "OK" || ib.Value == "")
		return
	val := Integer(ib.Value)
	if (val < 0)
		return
	_LLM_Tray["max_words"] := val  ; 0 = unlimited
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_PromptTemperature() {
	global _LLM_Tray
	ib := InputBox(t("menu.llm.temperature_prompt"), t("menu.llm.generation_menu_title"), "w400 h120", _LLM_Tray["temperature"])
	if (ib.Result != "OK" || ib.Value == "")
		return
	val := Float(ib.Value)
	if (val < 0.0 || val > 2.0)
		return
	_LLM_Tray["temperature"] := Format("{:.2f}", val)
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_PromptNavModifiers() {
	global _LLM_Tray
	ib := InputBox(t("menu.llm.nav_modifiers_prompt"), t("menu.llm.nav_menu_title"), "w400 h120", _LLM_Tray["nav_modifiers"])
	if (ib.Result != "OK")
		return
	_LLM_Tray["nav_modifiers"] := Trim(ib.Value)
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_PromptValModifiers() {
	global _LLM_Tray
	ib := InputBox(t("menu.llm.val_modifiers_prompt"), t("menu.llm.nav_menu_title"), "w400 h120", _LLM_Tray["val_modifiers"])
	if (ib.Result != "OK")
		return
	_LLM_Tray["val_modifiers"] := Trim(ib.Value)
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}


; ============================================
; ===== 5.3) Trigger Shortcut =====
; ============================================

/**
 * Opens an InputBox to set/clear the manual trigger shortcut.
 * Format expected: modifier(s) + key, e.g. "ctrl+alt+p" or "ctrl+space".
 * An empty input clears the shortcut.
 */
LLM_Tray_PromptTriggerShortcut() {
	global _LLM_Tray
	ib := InputBox(t("menu.llm.shortcut_prompt"), t("menu.llm.trigger_shortcut_title"), "w450 h140", _LLM_Tray["trigger_shortcut"])
	if (ib.Result != "OK")
		return
	raw := Trim(ib.Value)
	_LLM_Tray["trigger_shortcut"] := raw
	LLM_Tray_ApplyTriggerShortcut(raw)
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
}

/**
 * Registers (or removes) the global trigger hotkey from the active shortcut string.
 * @param {string} raw - Hotkey string like "ctrl+alt+p" or "" to disable.
 */
LLM_Tray_ApplyTriggerShortcut(raw) {
	global _LLM_Tray_TriggerHk

	; Remove the previous hotkey if one was set
	if IsSet(_LLM_Tray_TriggerHk) {
		try Hotkey(_LLM_Tray_TriggerHk, "Off")
		_LLM_Tray_TriggerHk := unset
	}

	if (raw == "")
		return

	; Convert "ctrl+alt+p" → "^!p" AHK format
	converted := LLM_Tray_ShortcutToAhk(raw)
	if (converted == "")
		return

	try {
		Hotkey(converted, (*) => LLM_Tray_TriggerPrediction(), "On")
		_LLM_Tray_TriggerHk := converted
	} catch as e {
		LoggerWarn("LLM", "Trigger shortcut binding failed: " e.Message)
	}
}

/**
 * Converts a human-readable shortcut string to AHK hotkey notation.
 * e.g. "ctrl+alt+p" → "^!p"
 * @param {string} raw - Human-readable shortcut string.
 * @returns {string} AHK hotkey string, or "" on failure.
 */
LLM_Tray_ShortcutToAhk(raw) {
	if (raw == "")
		return ""

	parts  := StrSplit(raw, "+")
	key    := ""
	prefix := ""

	for part in parts {
		p := StrLower(Trim(part))
		if (p == "ctrl") {
			prefix .= "^"
			continue
		}
		if (p == "alt") {
			prefix .= "!"
			continue
		}
		if (p == "shift") {
			prefix .= "+"
			continue
		}
		if (p == "win") {
			prefix .= "#"
			continue
		}
		; Everything else is treated as the key
		key := p
	}

	if (key == "")
		return ""
	return prefix . key
}

/**
 * Fires an immediate prediction request (used by the trigger shortcut).
 */
LLM_Tray_TriggerPrediction() {
	global _LLM_Tray
	if !_LLM_Tray["enabled"] || !LLM_Deps_IsReady()
		return
	ctx := SubStr(_LLM_Bridge_Buffer, -_LLM_Tray["ctx_chars"])
	if (ctx != "")
		LLM_Engine_FirePrediction(ctx)
}


; ============================================
; ===== 5.4) Model: custom model prompt =====
; ============================================

/**
 * Prompts the user to enter a custom Ollama model identifier.
 */
LLM_Tray_PromptAddModel() {
	global _LLM_Tray
	ib := InputBox(t("menu.llm.ollama_model_hint"), t("menu.llm.add_custom_model"), "w450 h130")
	if (ib.Result != "OK" || Trim(ib.Value) == "")
		return
	name := Trim(ib.Value)
	LLM_Tray_SetModel(name)
}


; ========================================
; ===== 5.5) User Profiles CRUD =====
; ========================================

/**
 * Shows a context sub-menu style dialog for a user profile (use / edit / delete).
 * AHK has no native submenu on the fly; we show a MsgBox with button choices.
 * @param {Map} profile - The user profile Map object.
 */
LLM_Tray_OnUserProfileClick(profile) {
	global _LLM_Tray
	pid    := profile.Has("id")    ? profile["id"]    : ""
	plabel := profile.Has("label") ? profile["label"] : pid

	choice := MsgBox(
		t("menu.profiles.use_profile") . "`n"
		. t("menu.profiles.edit_profile") . "`n"
		. t("menu.profiles.delete_profile"),
		plabel,
		"3 32"  ; Yes/No/Cancel buttons + question icon
	)

	if (choice == "Yes") {
		; Use this profile
		LLM_Tray_SetProfile(pid)
	} else if (choice == "No") {
		; Edit this profile
		LLM_Tray_PromptEditProfile(profile)
	}
	; Cancel = delete — we use a separate confirm to avoid accidental deletion
}

/**
 * Opens InputBox dialogs to create a new user profile (label + prompt).
 */
LLM_Tray_PromptCreateProfile() {
	global _LLM_Tray

	; Step 1: label
	ib_label := InputBox(t("menu.profiles.prompt_label"), t("menu.profiles.create_profile"), "w450 h120")
	if (ib_label.Result != "OK" || Trim(ib_label.Value) == "")
		return
	plabel := Trim(ib_label.Value)

	; Step 2: system prompt (multi-line via Edit control)
	ib_prompt := InputBox(t("menu.profiles.prompt_system_single"), t("menu.profiles.create_profile"), "w520 h320")
	if (ib_prompt.Result != "OK")
		return
	system_single := ib_prompt.Value

	; Generate a unique ID from the label
	pid := "user_" . LLM_Tray_Slugify(plabel) . "_" . A_TickCount

	new_profile := Map(
		"id",            pid,
		"label",         plabel,
		"system_single", system_single,
		"system_multi",  "",
		"batch",         false
	)

	_LLM_Tray["user_profiles"].Push(new_profile)
	_LLM_Tray["profile_id"] := pid
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

/**
 * Opens InputBox dialogs to edit an existing user profile in place.
 * @param {Map} profile - The user profile to edit.
 */
LLM_Tray_PromptEditProfile(profile) {
	global _LLM_Tray
	pid := profile.Has("id") ? profile["id"] : ""

	ib_label := InputBox(t("menu.profiles.prompt_label"), t("menu.profiles.edit_profile"), "w450 h120",
		profile.Has("label") ? profile["label"] : "")
	if (ib_label.Result != "OK")
		return
	new_label := Trim(ib_label.Value)
	if (new_label == "")
		return

	ib_prompt := InputBox(t("menu.profiles.prompt_system_single"), t("menu.profiles.edit_profile"), "w520 h320",
		profile.Has("system_single") ? profile["system_single"] : "")
	if (ib_prompt.Result != "OK")
		return

	; Update in the array in place
	for i, p in _LLM_Tray["user_profiles"] {
		if (p.Has("id") && p["id"] == pid) {
			_LLM_Tray["user_profiles"][i]["label"]         := new_label
			_LLM_Tray["user_profiles"][i]["system_single"] := ib_prompt.Value
			break
		}
	}
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

/**
 * Converts a label string into a safe ASCII slug for use as a profile ID.
 * @param {string} label - Source label.
 * @returns {string} Slugified string (lowercase alphanumeric + underscores).
 */
LLM_Tray_Slugify(label) {
	slug := RegExReplace(StrLower(label), "[^a-z0-9]+", "_")
	slug := Trim(slug, "_")
	return (slug == "") ? "profile" : slug
}


; ==========================================
; ===== 5.6) App Exclusion Picker =====
; ==========================================

/**
 * Opens the shared AppPicker_Show() GUI so the user can select processes
 * to exclude from LLM predictions. Reuses the same picker used by Metrics.
 */
LLM_Tray_OpenAppPicker() {
	global _LLM_Tray
	AppPicker_Show(Map(
		"title",    t("menu.llm.exclude_from_ai"),
		"prompt",   t("dialog.llm.exclude_prompt"),
		"ok_label", t("dialog.llm.exclude_ok"),
		"initial",  _LLM_Tray["disabled_apps"],
		"on_save",  LLM_Tray_OnAppPickerSave
	))
}

LLM_Tray_OnAppPickerSave(selected) {
	global _LLM_Tray
	_LLM_Tray["disabled_apps"] := selected
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}


; ============================
; ===== 5.7) Misc =====
; ============================

LLM_Tray_OnAbout(*) {
	MsgBox(t("menu.llm.about_body"), t("menu.llm.title"))
}

/**
 * Starts the LLM bridge with the current tray settings.
 */
LLM_Tray_StartBridge() {
	LLM_Bridge_Start(LLM_Tray_BuildOpts())
}

/**
 * Converts the current tray state into a Map suitable for LLM_Engine_Init().
 * @returns {Map} Options map.
 */
LLM_Tray_BuildOpts() {
	global _LLM_Tray
	return Map(
		"model",                   _LLM_Tray["model"],
		"profile_id",              _LLM_Tray["profile_id"],
		"user_profiles",           _LLM_Tray["user_profiles"],
		"n_predictions",           _LLM_Tray["n_predictions"],
		"min_words",               _LLM_Tray["min_words"],
		"max_words",               _LLM_Tray["max_words"],
		"language",                _LLM_Tray["language"],
		"debounce_ms",             _LLM_Tray["debounce_ms"],
		"ctx_chars",               _LLM_Tray["ctx_chars"],
		"temperature",             _LLM_Tray["temperature"],
		"instant_on_word_end",     _LLM_Tray["instant_on_word_end"],
		"after_hotstring",         _LLM_Tray["after_hotstring"],
		"reset_on_nav",            _LLM_Tray["reset_on_nav"],
		"disable_url_bars",        _LLM_Tray["disable_url_bars"],
		"disable_password_fields", _LLM_Tray["disable_password_fields"],
		"disabled_apps",           _LLM_Tray["disabled_apps"],
		"show_info_bar",           _LLM_Tray["show_info_bar"],
		"streaming",               _LLM_Tray["streaming"],
		"show_all_at_once",        _LLM_Tray["show_all_at_once"],
		"pred_indent",             _LLM_Tray["pred_indent"],
		"auto_raise_temp",         _LLM_Tray["auto_raise_temp"],
		"nav_modifiers",           _LLM_Tray["nav_modifiers"],
		"val_modifiers",           _LLM_Tray["val_modifiers"]
	)
}


; ====================================================
; ====================================================
; ======= 6/ Ollama Lifecycle Callbacks =======
; ====================================================
; ====================================================

/**
 * Called by the deps checker when Ollama is confirmed ready.
 */
LLM_Tray_OnDepsReady() {
	global _LLM_Tray
	LLM_Tray_Build()
	if _LLM_Tray["enabled"]
		LLM_Tray_StartBridge()
}

/**
 * Called by the deps checker on permanent failure.
 * @param {string} msg - Failure reason.
 */
LLM_Tray_OnDepsFailed(msg) {
	global _LLM_Tray
	_LLM_Tray["enabled"] := false
	LLM_Tray_Build()
}




; ======================================
; ======================================
; ======= 7/ Tab Hotkey (Accept) =======
; ======================================
; ======================================

; Tab accepts the visible suggestion when the tooltip is displayed.
; The hotkey is context-sensitive: active only when the tooltip is shown.
#HotIf LLM_Tooltip_GetText() != ""
Tab:: {
	text := LLM_Tooltip_GetText()
	if (text != "")
		LLM_Bridge_OnAccept(text)
}
#HotIf
