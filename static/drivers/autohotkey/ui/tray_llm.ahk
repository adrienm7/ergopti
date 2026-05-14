; ui/tray_llm.ahk

; ==============================================================================
; MODULE: LLM Tray Menu UI
; DESCRIPTION:
; System tray menu for the LLM feature on Windows. Provides enable/disable
; toggle, model selection, profile selection, prediction count controls,
; trigger settings (debounce, instant on word end), and generation settings
; (context length, min/max words, temperature) — mirroring the Hammerspoon
; menu_llm feature set.
;
; FEATURES & RATIONALE:
; 1. Tray-native: uses AHK v2's A_TrayMenu / Menu API — no external UI.
; 2. Settings persistence: reads/writes settings via the shared config helpers.
; 3. Ollama check: shows an install prompt if Ollama is not running on startup.
; 4. Lazy bootstrap: Ollama is never touched until the user explicitly enables IA.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Tray Menu Constants =======
; ======================================
; ======================================

; Title is resolved at call-time via a function — never at load-time —
; so the active language is already set when the menu is built or rebuilt.
LLM_TRAY_N_OPTIONS := [1, 2, 3]   ; available prediction count choices

; Debounce options in milliseconds (mirrors HS trigger settings)
LLM_TRAY_DEBOUNCE_OPTIONS := [300, 500, 600, 800, 1000, 1500, 2000]

; Temperature options (0.0 = deterministic, 1.0 = creative)
LLM_TRAY_TEMP_OPTIONS := ["0.0", "0.1", "0.2", "0.3", "0.5", "0.7", "1.0"]

; Context length options (characters)
LLM_TRAY_CTX_OPTIONS := [100, 200, 300, 500, 800, 1200]




; ======================================
; ======================================
; ======= 2/ Tray State =======
; ======================================
; ======================================

global _LLM_Tray := Map(
	"enabled",            false,
	"model",              "qwen2.5:3b",
	"profile_id",         "basic",
	"n_predictions",      1,
	"min_words",          2,
	"max_words",          8,
	"language",           "fr",
	"debounce_ms",        600,
	"ctx_chars",          300,
	"temperature",        "0.1",
	"instant_on_word_end", false
)

; Persistent Menu object — reused across rebuilds so the tray entry never
; moves. AHK v2 Menu.Delete+Add always appends; updating the same object
; in place is the only way to keep the canonical menu position.
global _LLM_Tray_Menu := Menu()
global _LLM_Tray_InTray := false




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

	if saved_opts.Has("model")
		_LLM_Tray["model"]               := saved_opts["model"]
	if saved_opts.Has("profile_id")
		_LLM_Tray["profile_id"]          := saved_opts["profile_id"]
	if saved_opts.Has("n_predictions")
		_LLM_Tray["n_predictions"]       := saved_opts["n_predictions"]
	if saved_opts.Has("min_words")
		_LLM_Tray["min_words"]           := saved_opts["min_words"]
	if saved_opts.Has("max_words")
		_LLM_Tray["max_words"]           := saved_opts["max_words"]
	if saved_opts.Has("language")
		_LLM_Tray["language"]            := saved_opts["language"]
	if saved_opts.Has("debounce_ms")
		_LLM_Tray["debounce_ms"]         := saved_opts["debounce_ms"]
	if saved_opts.Has("ctx_chars")
		_LLM_Tray["ctx_chars"]           := saved_opts["ctx_chars"]
	if saved_opts.Has("temperature")
		_LLM_Tray["temperature"]         := saved_opts["temperature"]
	if saved_opts.Has("instant_on_word_end")
		_LLM_Tray["instant_on_word_end"] := saved_opts["instant_on_word_end"]
	if saved_opts.Has("enabled")
		_LLM_Tray["enabled"]             := saved_opts["enabled"]

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
	; On the very first call the menu is empty — Delete("") on an empty menu
	; is a no-op in AHK v2, so this branch is always safe.
	try _LLM_Tray_Menu.Delete()

	; Enable / Disable toggle — show "activé" only when both the user has toggled
	; the feature ON and Ollama is confirmed ready. Mirrors the parent checkmark
	; logic so label and tray check are always in sync.
	_llm_is_operational := (_LLM_Tray["enabled"] && LLM_Deps_IsReady())
	AddCategoryToggleItem(_LLM_Tray_Menu,
		t("menu.llm.on"),
		t("menu.llm.off"),
		_llm_is_operational,
		LLM_Tray_OnToggle)

	; Model submenu
	model_menu := LLM_Tray_BuildModelMenu()
	_LLM_Tray_Menu.Add(StrReplace(t("menu.llm.model_label"), "%s", _LLM_Tray["model"]), model_menu)

	; Profile submenu
	profile_menu := LLM_Tray_BuildProfileMenu()
	_LLM_Tray_Menu.Add(StrReplace(t("menu.profiles.profile_label_prefix"), "%s", _LLM_Tray["profile_id"]), profile_menu)

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

	_LLM_Tray_Menu.Add()  ; separator
	_LLM_Tray_Menu.Add(t("menu.llm.about"), LLM_Tray_OnAbout)

	; Register in the system tray on first call only. On subsequent rebuilds
	; the same Menu object is already wired to the tray entry — items were
	; updated in place above, so the position is unchanged.
	if !_LLM_Tray_InTray {
		A_TrayMenu.Add(t("menu.llm.title"), _LLM_Tray_Menu)
		_LLM_Tray_InTray := true
	}

	; Check the parent tray entry only when enabled AND Ollama is confirmed
	; ready — mirrors the Hotstrings pattern where the checkmark signals that
	; the feature is both toggled on and fully operational.
	if (_LLM_Tray["enabled"] && LLM_Deps_IsReady())
		A_TrayMenu.Check(t("menu.llm.title"))
	else
		try A_TrayMenu.Uncheck(t("menu.llm.title"))
}

/**
 * Builds the model selection submenu from installed Ollama models.
 * Skips the network call when IA is disabled — the list is only relevant
 * once the user has activated the feature (Ollama must be running then).
 * @returns {Menu} Populated model submenu.
 */
LLM_Tray_BuildModelMenu() {
	global _LLM_Tray
	m := Menu()

	; Avoid a blocking HTTP call during startup or when IA is off.
	; The current model name is shown on the parent entry label regardless.
	if !_LLM_Tray["enabled"] {
		placeholder := _LLM_Tray["model"]
		m.Add(placeholder, (*) => 0)
		m.Check(placeholder)
		return m
	}

	installed := LLM_OllamaListModels()

	if (installed.Length == 0) {
		m.Add(t("menu.llm.no_model"), (*) => 0)
		m.Disable(t("menu.llm.no_model"))
		return m
	}

	for tag in installed {
		captured_tag := tag
		m.Add(tag, (name, pos, menu) => LLM_Tray_SetModel(captured_tag))
		if (tag == _LLM_Tray["model"])
			m.Check(tag)
	}
	return m
}

/**
 * Builds the profile selection submenu.
 * @returns {Menu} Populated profile submenu.
 */
LLM_Tray_BuildProfileMenu() {
	global _LLM_Tray
	m := Menu()

	profile_keys := ["raw", "basic", "advanced", "batch_advanced"]

	for id in profile_keys {
		captured_id := id
		label := t("llm.profile." id ".label")
		m.Add(label, (name, pos, menu) => LLM_Tray_SetProfile(captured_id))
		if (id == _LLM_Tray["profile_id"])
			m.Check(label)
	}
	return m
}

/**
 * Builds the prediction count submenu.
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

/**
 * Builds the trigger settings submenu (debounce delay, instant on word end).
 * @returns {Menu} Populated trigger submenu.
 */
LLM_Tray_BuildTriggerMenu() {
	global _LLM_Tray
	m := Menu()

	; Debounce delay sub-submenu
	debounce_menu := Menu()
	for ms in LLM_TRAY_DEBOUNCE_OPTIONS {
		captured_ms := ms
		label := StrReplace(t("menu.llm.debounce_label"), "%s", ms " ms")
		debounce_menu.Add(label, (name, pos, menu) => LLM_Tray_SetDebounce(captured_ms))
		if (ms == _LLM_Tray["debounce_ms"])
			debounce_menu.Check(label)
	}
	m.Add(StrReplace(t("menu.llm.debounce_label"), "%s", _LLM_Tray["debounce_ms"] " ms"), debounce_menu)

	m.Add()  ; separator

	; Instant on word end toggle
	instant_label := t("menu.llm.instant_on_word_end")
	m.Add(instant_label, LLM_Tray_OnInstantToggle)
	if _LLM_Tray["instant_on_word_end"]
		m.Check(instant_label)

	return m
}

/**
 * Builds the generation settings submenu (context, min/max words, temperature).
 * @returns {Menu} Populated generation submenu.
 */
LLM_Tray_BuildGenerationMenu() {
	global _LLM_Tray
	m := Menu()

	; Context length sub-submenu
	ctx_menu := Menu()
	for chars in LLM_TRAY_CTX_OPTIONS {
		captured_chars := chars
		label := StrReplace(t("menu.llm.context_length_label"), "%s", chars)
		ctx_menu.Add(label, (name, pos, menu) => LLM_Tray_SetCtxChars(captured_chars))
		if (chars == _LLM_Tray["ctx_chars"])
			ctx_menu.Check(label)
	}
	m.Add(StrReplace(t("menu.llm.context_length_label"), "%s", _LLM_Tray["ctx_chars"]), ctx_menu)

	m.Add()  ; separator

	; Min words sub-submenu
	min_menu := Menu()
	for n in [1, 2, 3, 4, 5] {
		captured_n := n
		label := StrReplace(t("menu.llm.min_words_label"), "%s", n)
		min_menu.Add(label, (name, pos, menu) => LLM_Tray_SetMinWords(captured_n))
		if (n == _LLM_Tray["min_words"])
			min_menu.Check(label)
	}
	m.Add(StrReplace(t("menu.llm.min_words_label"), "%s", _LLM_Tray["min_words"]), min_menu)

	; Max words sub-submenu
	max_menu := Menu()
	for n in [4, 6, 8, 10, 15, 20] {
		captured_n := n
		label := StrReplace(t("menu.llm.max_words_label"), "%s", n)
		max_menu.Add(label, (name, pos, menu) => LLM_Tray_SetMaxWords(captured_n))
		if (n == _LLM_Tray["max_words"])
			max_menu.Check(label)
	}
	m.Add(StrReplace(t("menu.llm.max_words_label"), "%s", _LLM_Tray["max_words"]), max_menu)

	m.Add()  ; separator

	; Temperature sub-submenu
	temp_menu := Menu()
	for val in LLM_TRAY_TEMP_OPTIONS {
		captured_val := val
		label := StrReplace(t("menu.llm.temperature_label"), "%s", val)
		temp_menu.Add(label, (name, pos, menu) => LLM_Tray_SetTemperature(captured_val))
		if (val == _LLM_Tray["temperature"])
			temp_menu.Check(label)
	}
	m.Add(StrReplace(t("menu.llm.temperature_label"), "%s", _LLM_Tray["temperature"]), temp_menu)

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
	; Rebuild immediately so the menu reflects the new state before any async
	; Ollama work starts. If bootstrap fails, OnDepsFailed flips enabled back
	; to false and rebuilds again — the user always sees the true final state.
	LLM_Tray_Build()
	if _LLM_Tray["enabled"] {
		; Defer bootstrap via a one-shot timer so the menu closes and redraws
		; before the 2-second blocking HTTP check for Ollama fires.
		SetTimer(LLM_Tray_BootstrapOllama, -1)
	} else {
		LLM_Bridge_Stop()
	}
}

/**
 * Persists the current LLM tray state to the shared config TOML.
 * Called after every user-visible state change so settings survive reload.
 */
LLM_Tray_SaveConfig() {
	global _SaveFullConfigReady
	; _SaveFullConfigReady is set by ErgoptiPlus.ahk after all modules load.
	; When tray_llm.ahk runs standalone (unit tests) the flag is absent — skip.
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
 * Triggers the Ollama deps checker.
 * @param {boolean} show_ui - True when the user explicitly clicked the toggle
 *                            (shows the install window if Ollama is absent).
 *                            False on automatic reload boot (silent fast-path only).
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

LLM_Tray_SetDebounce(ms) {
	global _LLM_Tray
	_LLM_Tray["debounce_ms"] := ms
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetCtxChars(chars) {
	global _LLM_Tray
	_LLM_Tray["ctx_chars"] := chars
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetMinWords(n) {
	global _LLM_Tray
	_LLM_Tray["min_words"] := n
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetMaxWords(n) {
	global _LLM_Tray
	_LLM_Tray["max_words"] := n
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetTemperature(val) {
	global _LLM_Tray
	_LLM_Tray["temperature"] := val
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

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
		"model",               _LLM_Tray["model"],
		"profile_id",          _LLM_Tray["profile_id"],
		"n_predictions",       _LLM_Tray["n_predictions"],
		"min_words",           _LLM_Tray["min_words"],
		"max_words",           _LLM_Tray["max_words"],
		"language",            _LLM_Tray["language"],
		"debounce_ms",         _LLM_Tray["debounce_ms"],
		"ctx_chars",           _LLM_Tray["ctx_chars"],
		"temperature",         _LLM_Tray["temperature"],
		"instant_on_word_end", _LLM_Tray["instant_on_word_end"]
	)
}




/**
 * Called by the deps checker when Ollama is confirmed ready.
 * Starts the bridge if the user had enabled the feature.
 */
LLM_Tray_OnDepsReady() {
	global _LLM_Tray
	; Rebuild so the parent tray entry gets its checkmark now that deps are ready.
	LLM_Tray_Build()
	if _LLM_Tray["enabled"]
		LLM_Tray_StartBridge()
}

/**
 * Called by the deps checker on permanent failure.
 * Disables the feature and updates the tray label.
 * @param {string} msg - Failure reason.
 */
LLM_Tray_OnDepsFailed(msg) {
	global _LLM_Tray
	_LLM_Tray["enabled"] := false
	LLM_Tray_Build()
}




; =====================================
; =====================================
; ======= 6/ Tab Hotkey (Accept) =======
; =====================================
; =====================================

; Tab accepts the visible suggestion when the tooltip is displayed.
; The hotkey is context-sensitive: active only when the tooltip is shown.
#HotIf LLM_Tooltip_GetText() != ""
Tab:: {
	text := LLM_Tooltip_GetText()
	if (text != "")
		LLM_Bridge_OnAccept(text)
}
#HotIf
