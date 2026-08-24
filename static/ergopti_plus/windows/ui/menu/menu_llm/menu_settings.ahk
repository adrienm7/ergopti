; ui/menu/menu_llm/menu_settings.ahk

; ==============================================================================
; MODULE: LLM Tray — Settings submenus
; DESCRIPTION:
; Builds the five settings submenus that hang off the main tray entry — N
; predictions, Trigger, Generation, Display, Navigation — and the InputBox
; prompts that back every numeric / modifier / shortcut setting. Also owns
; the small set of cross-cutting helpers (``_LLM_DefaultFor``,
; ``_LLM_AssignAndRebuild``, ``_LLM_MaybeAddReset``) that every settings
; submenu uses to surface "Reset to <default>" rows.
;
; FEATURES & RATIONALE:
; 1. Reset-row hygiene: ``_LLM_MaybeAddReset`` appends a reset row ONLY when
;    the current value differs from the shared default — mirrors HS's pattern
;    of hiding the row when it would be a no-op so the menu stays compact.
; 2. Shared-defaults single source of truth: every "Reset" target reads from
;    ``LLM_Defaults`` (populated from defaults.json — the single source). The
;    loader fails fast if the file is missing, so there is no hardcoded mirror
;    map; a per-call default only covers keys the loader does not parse.
; 3. Trigger shortcut: optional global hotkey that fires a prediction on
;    demand. Default Ctrl+Space mirrors Copilot's "trigger inline suggestion"
;    so muscle memory carries over.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Count Submenu =======
; ================================
; ================================

/**
 * Builds the prediction count submenu (1 to 10).
 * The renderer materialises the rows; this only says what they are — see
 * ``_LLM_Menu_NRows``.
 * @returns {Menu} Populated count submenu.
 */
LLM_Menu_BuildNMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_num_predictions", (*) => _LLM_Menu_NRows())
	return m
}

/**
 * Row data for the prediction count submenu.
 * @returns {Array} One row per option, ticked on the active one.
 */
_LLM_Menu_NRows() {
	global _LLM_Menu
	Rows := []
	for n in LLM_MENU_N_OPTIONS {
		Rows.Push(Map(
			"label",   StrReplace(StrReplace(t("menu.llm.prediction_count_label"), "%d", n), "%s", (n > 1 ? "s" : "")),
			"checked", (n == _LLM_Menu["n_predictions"]),
			"action",  _LLM_Menu_MakeSetNHandler(n)))
	}
	return Rows
}





; ==================================
; ==================================
; ======= 2/ Trigger Submenu =======
; ==================================
; ==================================

/**
 * Builds the trigger settings submenu.
 * Mirrors HS: trigger shortcut, debounce (dialog), instant-on-word-end,
 * after-hotstring, reset-on-nav, URL bar filter, password field filter,
 * and the app-exclusion picker.
 * @returns {Menu} Populated trigger submenu.
 */
LLM_Menu_BuildTriggerMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_trigger", (*) => _LLM_Menu_TriggerRows())
	return m
}

/**
 * Row data for the trigger submenu.
 * @returns {Array} Trigger shortcut, debounce, the four toggles, the app picker.
 */
_LLM_Menu_TriggerRows() {
	global _LLM_Menu
	Rows := []

	; Trigger shortcut (fires prediction on demand)
	sc_display := LLM_Menu_TriggerDisplayValue()
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.trigger_shortcut_label"), "%s", sc_display),
		"action", (*) => LLM_Menu_PromptTriggerShortcut()))

	; Debounce — dialog like HS (free numeric input)
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.debounce_label"), "%s", _LLM_Menu["debounce_ms"] . " ms"),
		"action", (*) => LLM_Menu_PromptDebounce()))
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["debounce_ms"],
		_LLM_DefaultFor("llm_debounce_ms", 500),
		(*) => _LLM_AssignAndRebuild("debounce_ms",
			_LLM_DefaultFor("llm_debounce_ms", 500)))

	Rows.Push(Map("separator", true))

	; Instant on word end
	Rows.Push(Map(
		"label",   t("menu.llm.instant_on_word_end"),
		"checked", _LLM_Menu["instant_on_word_end"],
		"action",  LLM_Menu_OnInstantToggle))

	; After hotstring (suggest after a hotstring expansion finishes)
	Rows.Push(Map(
		"label",   t("menu.llm.after_hotstring"),
		"checked", _LLM_Menu["after_hotstring"],
		"action",  (*) => LLM_Menu_ToggleBool("after_hotstring")))

	Rows.Push(Map("separator", true))

	; URL bar filter
	Rows.Push(Map(
		"label",   t("menu.llm.disable_url_bars"),
		"checked", _LLM_Menu["disable_url_bars"],
		"action",  (*) => LLM_Menu_ToggleBool("disable_url_bars")))

	; Password field filter
	Rows.Push(Map(
		"label",   t("menu.llm.disable_password_fields"),
		"checked", _LLM_Menu["disable_password_fields"],
		"action",  (*) => LLM_Menu_ToggleBool("disable_password_fields")))

	; App exclusion picker
	n := _LLM_Menu["disabled_apps"].Length
	Rows.Push(Map(
		"label", (n > 0)
			? StrReplace(StrReplace(t("menu.llm.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
			: t("menu.llm.exclude_from_ai"),
		"action", (*) => LLM_Menu_OpenAppPicker()))

	return Rows
}





; =====================================
; =====================================
; ======= 3/ Generation Submenu =======
; =====================================
; =====================================

/**
 * Builds the generation settings submenu.
 * All numeric values use InputBox dialogs (same UX as HS settings_manager).
 * @returns {Menu} Populated generation submenu.
 */
LLM_Menu_BuildGenerationMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_generation_settings", (*) => _LLM_Menu_GenerationRows())
	return m
}

/**
 * Row data for the generation submenu.
 * @returns {Array} The four numeric prompts with their reset rows, plus the two toggles.
 */
_LLM_Menu_GenerationRows() {
	global _LLM_Menu
	Rows := []

	; Context length — dialog
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.context_length_label"), "%s", _LLM_Menu["ctx_chars"]),
		"action", (*) => LLM_Menu_PromptCtxChars()))
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["ctx_chars"],
		_LLM_DefaultFor("llm_context_length", 500),
		(*) => _LLM_AssignAndRebuild("ctx_chars",
			_LLM_DefaultFor("llm_context_length", 500)))

	; Reset on nav toggle
	Rows.Push(Map(
		"label",   t("menu.llm.reset_on_nav"),
		"checked", _LLM_Menu["reset_on_nav"],
		"action",  (*) => LLM_Menu_ToggleBool("reset_on_nav")))

	Rows.Push(Map("separator", true))

	; Min words — dialog
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.min_words_label"), "%s", _LLM_Menu["min_words"]),
		"action", (*) => LLM_Menu_PromptMinWords()))
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["min_words"],
		_LLM_DefaultFor("llm_min_words", 3),
		(*) => _LLM_AssignAndRebuild("min_words",
			_LLM_DefaultFor("llm_min_words", 3)))

	; Max words — dialog
	max_val     := _LLM_Menu["max_words"]
	max_display := (max_val == 0) ? t("menu.llm.unlimited") : max_val
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.max_words_label"), "%s", max_display),
		"action", (*) => LLM_Menu_PromptMaxWords()))
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["max_words"],
		_LLM_DefaultFor("llm_max_words", 15),
		(*) => _LLM_AssignAndRebuild("max_words",
			_LLM_DefaultFor("llm_max_words", 15)))

	Rows.Push(Map("separator", true))

	; Temperature — dialog
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.temperature_label"), "%s", _LLM_Menu["temperature"]),
		"action", (*) => LLM_Menu_PromptTemperature()))
	; ``temperature`` is stored as a formatted string ("0.10"), so compare the
	; canonical form of the default to avoid spurious resets when the JSON
	; carries a numeric 0.1 vs the stored "0.10".
	_temp_default := Format("{:.2f}", Float(_LLM_DefaultFor("llm_temperature", "0.10")) + 0)
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["temperature"],
		_temp_default,
		(*) => _LLM_AssignAndRebuild("temperature", _temp_default))

	; Auto-raise temperature — only meaningful when several predictions are drawn
	Rows.Push(Map(
		"label",    t("menu.llm.auto_raise_temp"),
		"checked",  _LLM_Menu["auto_raise_temp"],
		"disabled", (_LLM_Menu["n_predictions"] <= 1),
		"action",   (*) => LLM_Menu_ToggleBool("auto_raise_temp")))

	return Rows
}





; ==================================
; ==================================
; ======= 4/ Display Submenu =======
; ==================================
; ==================================

/**
 * Builds the display settings submenu.
 * Mirrors HS display_menu: info bar, streaming, show-all-at-once, indent.
 * @returns {Menu} Populated display submenu.
 */
LLM_Menu_BuildDisplayMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_display", (*) => _LLM_Menu_DisplayRows())
	return m
}

/**
 * Row data for the display submenu, including the nested indent picker.
 * @returns {Array} The four toggles and the indent-level submenu.
 */
_LLM_Menu_DisplayRows() {
	global _LLM_Menu
	Rows := []
	n := _LLM_Menu["n_predictions"]

	; Info bar (shows model name and latency in the tooltip)
	Rows.Push(Map(
		"label",   t("menu.llm.show_info_bar"),
		"checked", _LLM_Menu["show_info_bar"],
		"action",  (*) => LLM_Menu_ToggleBool("show_info_bar")))

	; Inline auto-type — when on, the prediction is typed directly into
	; the active app instead of showing in a tooltip (Copilot-style). The
	; engine forces n=1 internally so we never race two variants. The
	; user keeps the option of bare Backspace / Ctrl+Z to roll back what
	; was typed.
	Rows.Push(Map(
		"label",   t("menu.llm.inline_autotype"),
		"checked", _LLM_Menu["inline_autotype"],
		"action",  (*) => LLM_Menu_ToggleBool("inline_autotype")))

	Rows.Push(Map("separator", true))

	; Streaming (token-by-token display) — only meaningful when show-all-at-once
	; (multi) is enabled
	Rows.Push(Map(
"label",    t("menu.llm.show_streaming"),
"checked",  _LLM_Menu["streaming"] && LLM_BackendCapabilities(_LLM_Menu["backend"])["streaming"],
"disabled", !_LLM_Menu["show_all_at_once"] || !LLM_BackendCapabilities(_LLM_Menu["backend"])["streaming"],
		"action",   (*) => LLM_Menu_ToggleBool("streaming")))

	; Show all predictions at once
	Rows.Push(Map(
		"label",    t("menu.llm.show_all_at_once"),
		"checked",  _LLM_Menu["show_all_at_once"],
		"disabled", (n < 2),
		"action",   (*) => LLM_Menu_ToggleBool("show_all_at_once")))

	Rows.Push(Map("separator", true))

	; Indent level submenu — mirrors HS settings_manager.build_indent_menu():
	;   0           → "Aucun" (special-cased so 0 reads naturally).
	;   -1 or +1    → singular "espace" (with sign preserved so the user can
	;                 tell -1 from +1 — HS has a quirk that hides the number
	;                 for these values; AHK fixes the readability here).
	;   anything else → "N espaces" (plural, sign preserved for negatives).
	; Negative values yield a leading deletion of N chars so the predicted
	; continuation lines up at column-N relative to the original cursor.
	IndentRows := []
	for lvl in LLM_MENU_INDENT_OPTIONS {
		if (lvl == 0) {
			indent_label := t("menu.llm.indent_none")
		} else if (lvl == 1 or lvl == -1) {
			indent_label := lvl . " " . t("menu.llm.indent_space")
		} else {
			indent_label := lvl . " " . t("menu.llm.indent_spaces")
		}
		IndentRows.Push(Map(
			"label",   indent_label,
			"checked", (lvl == _LLM_Menu["pred_indent"]),
			"action",  _LLM_Menu_MakeSetIndentHandler(lvl)))
	}
	Rows.Push(Map(
		"label",    t("menu.llm.indent_label"),
		"disabled", (n < 2),
		"items",    IndentRows))
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["pred_indent"],
		_LLM_DefaultFor("llm_pred_indent", 0),
		(*) => _LLM_AssignAndRebuild("pred_indent",
			_LLM_DefaultFor("llm_pred_indent", 0)))

	return Rows
}





; =====================================
; =====================================
; ======= 5/ Navigation Submenu =======
; =====================================
; =====================================

/**
 * Builds the navigation settings submenu.
 * nav_modifiers: modifier key required to navigate predictions with arrows.
 * val_modifiers: modifier key required to select a prediction by digit.
 * Both accept free-text input (e.g. "ctrl", "alt", "" = no modifier needed).
 * @returns {Menu} Populated navigation submenu.
 */
LLM_Menu_BuildNavMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_navigation", (*) => _LLM_Menu_NavRows())
	return m
}

/**
 * Row data for the navigation submenu.
 * Both rows are greyed below two predictions: with a single one there is
 * nothing to navigate between.
 * @returns {Array} The navigation and validation modifier rows.
 */
_LLM_Menu_NavRows() {
	global _LLM_Menu
	n := _LLM_Menu["n_predictions"]

	nav_display   := (_LLM_Menu["nav_modifiers"] != "") ? _LLM_Menu["nav_modifiers"] : t("menu.llm.arrows_only")
	val_display   := (_LLM_Menu["val_modifiers"] != "") ? _LLM_Menu["val_modifiers"] : t("menu.llm.digits_only")
	val_key_range := (n == 10) ? "1-0" : "1-" . n

	return [
		Map("label",    t("menu.llm.nav_label") . " — " . nav_display,
			"disabled", (n < 2),
			"action",   (*) => LLM_Menu_PromptNavModifiers()),
		Map("label",    StrReplace(t("menu.llm.val_label"), "%s", val_key_range) . " — " . val_display,
			"disabled", (n < 2),
			"action",   (*) => LLM_Menu_PromptValModifiers())
	]
}





; =============================================
; =============================================
; ======= 6/ Numeric Prompt Dispatchers =======
; =============================================
; =============================================

/**
 * Opens an InputBox for a numeric setting, validates, and applies it.
 * @param {string} key     - The _LLM_Menu key to update.
 * @param {string} title   - Dialog title.
 * @param {string} prompt  - Dialog prompt text.
 * @param {number} min_val - Minimum valid value (0 = no minimum).
 * @param {number} max_val - Maximum valid value (0 = no maximum).
 */
LLM_Menu_PromptNumeric(key, title, prompt, min_val := 0, max_val := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptNumeric(key, title, prompt, min_val, max_val)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(prompt, title, "w400 h120", _LLM_Menu[key])
	if (ib.Result != "OK" || ib.Value == "")
		return
	; Reject non-numeric typos before converting — Integer() throws on a bad
	; string (e.g. "abc" or "12,5"), and this runs in a menu-callback thread
	; where the error would surface as an unhandled AHK dialog (mirrors the
	; IsInteger guard in LLM_Menu_PromptOllamaPort)
	if !IsInteger(ib.Value)
		return
	val := Integer(ib.Value)
	if (min_val > 0 && val < min_val) || (max_val > 0 && val > max_val)
		return
	return LLM_Menu_CommitMutation("the LLM numeric '" . key . "' setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, key, val),
		_LLM_Menu_ApplyStandardCommitted)
}

; Resolve the shared default for ``shared_key`` (e.g. "llm_debounce_ms") from the
; runtime ``LLM_Defaults`` map (populated from defaults.json — the single source).
; The per-call ``fallback`` is a last resort only for keys the loader does not
; parse; the old hardcoded mirror map is gone. Centralised so every "Reset to N"
; row in the menu hits the same source (mirrors HS's llm_mod.DEFAULT_STATE reads).
_LLM_DefaultFor(shared_key, fallback := "") {
	global LLM_Defaults
	if IsSet(LLM_Defaults) and Type(LLM_Defaults) == "Map" and LLM_Defaults.Has(shared_key)
		return LLM_Defaults[shared_key]
	return fallback
}

; Persist a numeric / boolean tray-state change and force a menu rebuild — same
; tail every prompt setter runs. Factored out so the "Reset to N" rows can do
; the right thing without copying the boilerplate inline at every call site.
_LLM_AssignAndRebuild(tray_key, value) {
	return LLM_Menu_CommitMutation("the LLM '" . tray_key . "' reset",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, tray_key, value),
		_LLM_Menu_ApplyStandardCommitted)
}

; Append a "Reset to <default>" row immediately below a setting when the
; current value differs from the shared default. Mirrors HS's pattern of
; surfacing the reset only when it would do something — a non-default value
; means the user has customised the setting, so the reset is now useful;
; an at-default value means the reset would be a no-op and we hide the row to
; keep the menu compact. The label re-uses the existing ``menu.llm.reset_label``
; i18n key which is already translated in every locale.
_LLM_MaybeAddReset(menu, current, default_val, on_click) {
	if (current = default_val)
		return
	label := StrReplace(t("menu.llm.reset_label"), "%s", default_val)
	MenuRenderer_AppendRows(menu, "llm_menu", "reset_row",
		[Map("label", label, "action", (*) => on_click())])
}

/**
 * The same conditional reset row, appended to a provider's row array instead of
 * added to a Menu. Two shapes because two callers are still native: the
 * top-level IA menu emits into the live tray handle, and the model submenu is
 * built by another subsystem.
 * @param {Array} Rows        Row array to append to.
 * @param {Any}   current     Current value.
 * @param {Any}   default_val Shared default.
 * @param {Func}  on_click    Applied on click.
 */
_LLM_MaybeResetRow(Rows, current, default_val, on_click) {
	if (current = default_val)
		return
	Rows.Push(Map(
		"label",  StrReplace(t("menu.llm.reset_label"), "%s", default_val),
		"action", (*) => on_click()))
}

LLM_Menu_PromptDebounce() {
	LLM_Menu_PromptNumeric("debounce_ms", t("menu.llm.trigger_menu_title"),
		t("menu.llm.debounce_prompt"), 50, 10000)
}

; Ollama port has its own prompt (not LLM_Menu_PromptNumeric) because applying it
; means rebuilding the HTTP client's base URL via LLM_Ollama_SetPort, not feeding
; the value through LLM_Engine_Init(LLM_Menu_BuildOpts()) — the port is a property
; of the api_ollama client, not of the engine options.
LLM_Menu_PromptOllamaPort() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptOllamaPort()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	current := _LLM_Menu.Has("ollama_port") ? _LLM_Menu["ollama_port"] : _LLM_DefaultFor("llm_ollama_port")
	ib := InputBox(t("menu.llm.ollama_port_prompt"), t("menu.llm.ollama_port_title"), "w400 h120", current)
	if (ib.Result != "OK" || ib.Value == "")
		return
	if !IsInteger(ib.Value)
		return
	val := Integer(ib.Value)
	if (val < 1024 || val > 65535)
		return
	return LLM_Menu_CommitMutation("the Ollama port setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"ollama_port", val), _LLM_Menu_ApplyOllamaPortCommitted,
		0, 0, 0, 0, 0, 0, _LLM_Menu_PrepareOllamaPortCandidate,
		_LLM_Menu_PublishOllamaPortCandidate)
}

; Resets the Ollama port to its shared default and applies it live.
LLM_Menu_ResetOllamaPort(default_port) {
	return LLM_Menu_CommitMutation("the Ollama port reset",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"ollama_port", default_port), _LLM_Menu_ApplyOllamaPortCommitted,
		0, 0, 0, 0, 0, 0, _LLM_Menu_PrepareOllamaPortCandidate,
		_LLM_Menu_PublishOllamaPortCandidate)
}

_LLM_Menu_ApplyOllamaPortCommitted(Candidate) {
	if !LLM_Ollama_SetPort(Candidate["ollama_port"])
		return false
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
	if Candidate.Get("enabled", false)
			&& Candidate.Get("backend", "") == "ollama"
		LLM_Menu_ScheduleBackendLifecycle(false)
	return true
}

LLM_Menu_PromptCtxChars() {
	LLM_Menu_PromptNumeric("ctx_chars", t("menu.llm.generation_menu_title"),
		t("menu.llm.context_length_prompt"), 50, 10000)
}

LLM_Menu_PromptMinWords() {
	LLM_Menu_PromptNumeric("min_words", t("menu.llm.generation_menu_title"),
		t("menu.llm.min_words_prompt"), 1, 20)
}

LLM_Menu_PromptMaxWords() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptMaxWords()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(t("menu.llm.max_words_prompt"), t("menu.llm.generation_menu_title"), "w400 h120", _LLM_Menu["max_words"])
	if (ib.Result != "OK" || ib.Value == "")
		return
	; Reject non-numeric typos before converting — Integer() throws on a bad
	; string in this menu-callback thread (mirrors LLM_Menu_PromptOllamaPort)
	if !IsInteger(ib.Value)
		return
	val := Integer(ib.Value)
	if (val < 0)
		return
	return LLM_Menu_CommitMutation("the LLM maximum-word setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"max_words", val), _LLM_Menu_ApplyStandardCommitted)
}

LLM_Menu_PromptTemperature() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptTemperature()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(t("menu.llm.temperature_prompt"), t("menu.llm.generation_menu_title"), "w400 h120", _LLM_Menu["temperature"])
	if (ib.Result != "OK" || ib.Value == "")
		return
	; Accept the comma-decimal habit common on a French keyboard (the project's
	; UI locale) by normalising "12,5" to "12.5" before validating
	raw := StrReplace(ib.Value, ",", ".")
	; Reject non-numeric typos before converting — Float() throws on a bad
	; string in this menu-callback thread (mirrors LLM_Menu_PromptOllamaPort)
	if !IsNumber(raw)
		return
	val := Float(raw)
	if (val < 0.0 || val > 2.0)
		return
	return LLM_Menu_CommitMutation("the LLM temperature setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"temperature", Format("{:.2f}", val)),
		_LLM_Menu_ApplyStandardCommitted)
}

LLM_Menu_PromptNavModifiers() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptNavModifiers()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(t("menu.llm.nav_modifiers_prompt"), t("menu.llm.nav_menu_title"), "w400 h120", _LLM_Menu["nav_modifiers"])
	if (ib.Result != "OK")
		return
	return LLM_Menu_CommitNavModifier("nav_modifiers", ib.Value)
}

LLM_Menu_PromptValModifiers() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptValModifiers()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(t("menu.llm.val_modifiers_prompt"), t("menu.llm.nav_menu_title"), "w400 h120", _LLM_Menu["val_modifiers"])
	if (ib.Result != "OK")
		return
	return LLM_Menu_CommitNavModifier("val_modifiers", ib.Value)
}

_LLM_Menu_ApplyNavCommitted(*) {
	return _LLM_Menu_ApplyStandardCommitted()
}





; ===============================================
; ===============================================
; ======= 7/ Trigger Shortcut + Add Model =======
; ===============================================
; ===============================================

/**
 * Opens an InputBox to set/clear the manual trigger shortcut.
 * Format expected: modifier(s) + key, e.g. "ctrl+alt+p" or "ctrl+space".
 * An empty input clears the shortcut.
 */
LLM_Menu_PromptTriggerShortcut() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptTriggerShortcut()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(t("menu.llm.shortcut_prompt"), t("menu.llm.trigger_shortcut_title"), "w450 h140", _LLM_Menu["trigger_shortcut"])
	if (ib.Result != "OK")
		return
	raw := Trim(ib.Value)
	Committed := LLM_Menu_CommitTriggerShortcut(raw)
	; A partial native cleanup failure returns false but publishes an explicit
	; recovery projection. Rebuild that warning instead of leaving a stale label
	if Committed || LLM_Menu_TriggerNeedsAttention()
		LLM_Menu_Build()
	return Committed
}

/**
 * Fires an immediate prediction request (used by the trigger shortcut).
 */
LLM_Menu_TriggerPrediction() {
	global _LLM_Menu
	if A_IsSuspended || !_LLM_Menu_BackendIsReadyForUse()
		return
	ctx := SubStr(_LLM_Bridge_Buffer, -_LLM_Menu["ctx_chars"])
	if (ctx != "")
		LLM_Engine_FirePrediction(ctx)
}

/**
 * Prompts the user to enter a custom Ollama model identifier.
 */
LLM_Menu_PromptAddModel() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptAddModel()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := InputBox(t("menu.llm.ollama_model_hint"), t("menu.llm.add_custom_model"), "w450 h130")
	if (ib.Result != "OK" || Trim(ib.Value) == "")
		return
	name := Trim(ib.Value)
	LLM_Menu_SetModel(name)
}
