; ui/tray_llm.ahk

; ==============================================================================
; MODULE: LLM Tray Menu UI
; DESCRIPTION:
; System tray menu for the LLM feature on Windows. Provides enable/disable
; toggle, model selection, profile selection, and prediction count controls —
; mirroring the Hammerspoon menu_llm feature set.
;
; FEATURES & RATIONALE:
; 1. Tray-native: uses AHK v2's A_TrayMenu / Menu API — no external UI.
; 2. Settings persistence: reads/writes settings via the shared config helpers.
; 3. Ollama check: shows an install prompt if Ollama is not running on startup.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================
; ======================================
; ======= 1/ Tray Menu Constants =======
; ======================================
; ======================================

LLM_TRAY_TITLE     := t("menu.llm.title")
LLM_TRAY_N_OPTIONS := [1, 2, 3]   ; available prediction count choices




; ======================================
; ======================================
; ======= 2/ Tray State =======
; ======================================
; ======================================

global _LLM_Tray := Map(
	"enabled",       false,
	"model",         "qwen2.5:3b",
	"profile_id",    "basic",
	"n_predictions", 1,
	"min_words",     2,
	"max_words",     8,
	"language",      "fr"
)




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
		_LLM_Tray["model"]         := saved_opts["model"]
	if saved_opts.Has("profile_id")
		_LLM_Tray["profile_id"]    := saved_opts["profile_id"]
	if saved_opts.Has("n_predictions")
		_LLM_Tray["n_predictions"] := saved_opts["n_predictions"]
	if saved_opts.Has("min_words")
		_LLM_Tray["min_words"]     := saved_opts["min_words"]
	if saved_opts.Has("max_words")
		_LLM_Tray["max_words"]     := saved_opts["max_words"]
	if saved_opts.Has("language")
		_LLM_Tray["language"]      := saved_opts["language"]
	if saved_opts.Has("enabled")
		_LLM_Tray["enabled"]       := saved_opts["enabled"]

	LLM_Tray_Build()

	; Bootstrap Ollama only if the user has explicitly enabled the AI feature.
	; Users who never activate it incur zero network or CPU overhead.
	if _LLM_Tray["enabled"]
		LLM_Tray_BootstrapOllama()
}




; ===================================
; ===================================
; ======= 4/ Menu Construction =======
; ===================================
; ===================================

/**
 * Builds (or rebuilds) the LLM submenu inside the tray.
 */
LLM_Tray_Build() {
	global _LLM_Tray

	llm_menu := Menu()

	; Enable / Disable toggle
	toggle_label := _LLM_Tray["enabled"] ? "Désactiver les suggestions IA" : "Activer les suggestions IA"
	llm_menu.Add(toggle_label, LLM_Tray_OnToggle)

	llm_menu.Add()  ; separator

	; Model submenu
	model_menu := LLM_Tray_BuildModelMenu()
	llm_menu.Add("Modèle : " _LLM_Tray["model"], model_menu)

	; Profile submenu
	profile_menu := LLM_Tray_BuildProfileMenu()
	llm_menu.Add("Profil : " _LLM_Tray["profile_id"], profile_menu)

	; Number of predictions submenu
	n_menu := LLM_Tray_BuildNMenu()
	llm_menu.Add("Suggestions : " _LLM_Tray["n_predictions"], n_menu)

	llm_menu.Add()  ; separator
	llm_menu.Add("À propos d'Ergopti IA", LLM_Tray_OnAbout)

	; Attach to system tray — delete old entry first to avoid duplicates on rebuild
	try A_TrayMenu.Delete(LLM_TRAY_TITLE)
	A_TrayMenu.Add(LLM_TRAY_TITLE, llm_menu)
}

/**
 * Builds the model selection submenu from installed Ollama models.
 * @returns {Menu} Populated model submenu.
 */
LLM_Tray_BuildModelMenu() {
	global _LLM_Tray
	m := Menu()
	installed := LLM_OllamaListModels()

	if (installed.Length == 0) {
		m.Add("(aucun modèle installé)", (*) => 0)
		m.Disable("(aucun modèle installé)")
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

	profile_labels := Map(
		"raw",            "Brut (contexte seul)",
		"basic",          "Basique",
		"advanced",       "Avancé (correction + complétion)",
		"batch_advanced", "Avancé — lots"
	)

	for id, label in profile_labels {
		captured_id := id
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
		label := String(n) " suggestion" (n > 1 ? "s" : "")
		m.Add(label, (name, pos, menu) => LLM_Tray_SetN(captured_n))
		if (n == _LLM_Tray["n_predictions"])
			m.Check(label)
	}
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
	if _LLM_Tray["enabled"] {
		; First activation: bootstrap Ollama (install if needed), then start bridge.
		LLM_Tray_BootstrapOllama()
	} else {
		LLM_Bridge_Stop()
	}
	LLM_Tray_Build()
}

/**
 * Triggers the Ollama deps checker. Called only when the user activates the feature.
 * If already ready, starts the bridge immediately.
 */
LLM_Tray_BootstrapOllama() {
	if LLM_Deps_IsReady() {
		LLM_Tray_OnDepsReady()
		return
	}
	LLM_Deps_CheckAndInstall(
		_LLM_Tray["model"],
		(*) => LLM_Tray_OnDepsReady(),
		(msg) => LLM_Tray_OnDepsFailed(msg)
	)
}

LLM_Tray_SetModel(tag) {
	global _LLM_Tray
	_LLM_Tray["model"] := tag
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetProfile(id) {
	global _LLM_Tray
	_LLM_Tray["profile_id"] := id
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_SetN(n) {
	global _LLM_Tray
	_LLM_Tray["n_predictions"] := n
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

LLM_Tray_OnAbout(*) {
	MsgBox("Ergopti IA — Suggestions intelligentes au clavier`nBackend : Ollama (local)`nVersion : 1.0", LLM_TRAY_TITLE)
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
		"model",         _LLM_Tray["model"],
		"profile_id",    _LLM_Tray["profile_id"],
		"n_predictions", _LLM_Tray["n_predictions"],
		"min_words",     _LLM_Tray["min_words"],
		"max_words",     _LLM_Tray["max_words"],
		"language",      _LLM_Tray["language"]
	)
}




/**
 * Called by the deps checker when Ollama is confirmed ready.
 * Starts the bridge if the user had enabled the feature.
 */
LLM_Tray_OnDepsReady() {
	global _LLM_Tray
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
