; ui/tray_llm/menu_settings.ahk

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





; ============================================
; ================================
; ======= 1/ Count Submenu =======
; ================================
; ============================================

/**
 * Builds the prediction count submenu (1 to 10).
 * @returns {Menu} Populated count submenu.
 */
LLM_Tray_BuildNMenu() {
	global _LLM_Tray
	m := Menu()
	for n in LLM_TRAY_N_OPTIONS {
		label := StrReplace(StrReplace(t("menu.llm.prediction_count_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		RegisterMenuItem(m, label, _LLM_Tray_MakeSetNHandler(n))
		if (n == _LLM_Tray["n_predictions"])
			m.Check(label)
	}
	return m
}





; ============================================
; ==================================
; ======= 2/ Trigger Submenu =======
; ==================================
; ============================================

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
	RegisterMenuItem(m, StrReplace(t("menu.llm.trigger_shortcut_label"), "%s", sc_display), (*) => LLM_Tray_PromptTriggerShortcut())

	; Debounce — dialog like HS (free numeric input)
	debounce_display := _LLM_Tray["debounce_ms"] . " ms"
	RegisterMenuItem(m, StrReplace(t("menu.llm.debounce_label"), "%s", debounce_display), (*) => LLM_Tray_PromptDebounce())
	_LLM_MaybeAddReset(m,
		_LLM_Tray["debounce_ms"],
		_LLM_DefaultFor("llm_debounce_ms", 500),
		(*) => _LLM_AssignAndRebuild("debounce_ms",
			_LLM_DefaultFor("llm_debounce_ms", 500)))

	m.Add()

	; Instant on word end
	instant_label := t("menu.llm.instant_on_word_end")
	RegisterMenuItem(m, instant_label, LLM_Tray_OnInstantToggle)
	if _LLM_Tray["instant_on_word_end"]
		m.Check(instant_label)

	; After hotstring (suggest after a hotstring expansion finishes)
	after_hs_label := t("menu.llm.after_hotstring")
	RegisterMenuItem(m, after_hs_label, (*) => LLM_Tray_ToggleBool("after_hotstring"))
	if _LLM_Tray["after_hotstring"]
		m.Check(after_hs_label)

	m.Add()

	; URL bar filter
	url_label := t("menu.llm.disable_url_bars")
	RegisterMenuItem(m, url_label, (*) => LLM_Tray_ToggleBool("disable_url_bars"))
	if _LLM_Tray["disable_url_bars"]
		m.Check(url_label)

	; Password field filter
	pwd_label := t("menu.llm.disable_password_fields")
	RegisterMenuItem(m, pwd_label, (*) => LLM_Tray_ToggleBool("disable_password_fields"))
	if _LLM_Tray["disable_password_fields"]
		m.Check(pwd_label)

	; App exclusion picker
	disabled_apps := _LLM_Tray["disabled_apps"]
	n := disabled_apps.Length
	excl_label := (n > 0)
		? StrReplace(StrReplace(t("menu.llm.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
		: t("menu.llm.exclude_from_ai")
	RegisterMenuItem(m, excl_label, (*) => LLM_Tray_OpenAppPicker())

	return m
}





; ===========================================
; =====================================
; ======= 3/ Generation Submenu =======
; =====================================
; ===========================================

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
	RegisterMenuItem(m, StrReplace(t("menu.llm.context_length_label"), "%s", ctx_display), (*) => LLM_Tray_PromptCtxChars())
	_LLM_MaybeAddReset(m,
		_LLM_Tray["ctx_chars"],
		_LLM_DefaultFor("llm_context_length", 500),
		(*) => _LLM_AssignAndRebuild("ctx_chars",
			_LLM_DefaultFor("llm_context_length", 500)))

	; Reset on nav toggle
	nav_label := t("menu.llm.reset_on_nav")
	RegisterMenuItem(m, nav_label, (*) => LLM_Tray_ToggleBool("reset_on_nav"))
	if _LLM_Tray["reset_on_nav"]
		m.Check(nav_label)

	m.Add()

	; Min words — dialog
	min_display := _LLM_Tray["min_words"]
	RegisterMenuItem(m, StrReplace(t("menu.llm.min_words_label"), "%s", min_display), (*) => LLM_Tray_PromptMinWords())
	_LLM_MaybeAddReset(m,
		_LLM_Tray["min_words"],
		_LLM_DefaultFor("llm_min_words", 3),
		(*) => _LLM_AssignAndRebuild("min_words",
			_LLM_DefaultFor("llm_min_words", 3)))

	; Max words — dialog
	max_val     := _LLM_Tray["max_words"]
	max_display := (max_val == 0) ? t("menu.llm.unlimited") : max_val
	RegisterMenuItem(m, StrReplace(t("menu.llm.max_words_label"), "%s", max_display), (*) => LLM_Tray_PromptMaxWords())
	_LLM_MaybeAddReset(m,
		_LLM_Tray["max_words"],
		_LLM_DefaultFor("llm_max_words", 15),
		(*) => _LLM_AssignAndRebuild("max_words",
			_LLM_DefaultFor("llm_max_words", 15)))

	m.Add()

	; Temperature — dialog
	temp_display := _LLM_Tray["temperature"]
	RegisterMenuItem(m, StrReplace(t("menu.llm.temperature_label"), "%s", temp_display), (*) => LLM_Tray_PromptTemperature())
	; ``temperature`` is stored as a formatted string ("0.10"), so compare the
	; canonical form of the default to avoid spurious resets when the JSON
	; carries a numeric 0.1 vs the stored "0.10".
	_temp_default := Format("{:.2f}", Float(_LLM_DefaultFor("llm_temperature", "0.10")) + 0)
	_LLM_MaybeAddReset(m,
		_LLM_Tray["temperature"],
		_temp_default,
		(*) => _LLM_AssignAndRebuild("temperature", _temp_default))

	; Auto-raise temperature
	auto_raise_label := t("menu.llm.auto_raise_temp")
	is_batch := (_LLM_Tray["n_predictions"] > 1)
	RegisterMenuItem(m, auto_raise_label, (*) => LLM_Tray_ToggleBool("auto_raise_temp"))
	if _LLM_Tray["auto_raise_temp"]
		m.Check(auto_raise_label)
	if !is_batch
		m.Disable(auto_raise_label)

	return m
}





; ========================================
; ==================================
; ======= 4/ Display Submenu =======
; ==================================
; ========================================

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
	RegisterMenuItem(m, info_label, (*) => LLM_Tray_ToggleBool("show_info_bar"))
	if _LLM_Tray["show_info_bar"]
		m.Check(info_label)

	; Inline auto-type — when on, the prediction is typed directly into
	; the active app instead of showing in a tooltip (Copilot-style). The
	; engine forces n=1 internally so we never race two variants. The
	; user keeps the option of bare Backspace / Ctrl+Z to roll back what
	; was typed.
	inline_label := t("menu.llm.inline_autotype")
	RegisterMenuItem(m, inline_label, (*) => LLM_Tray_ToggleBool("inline_autotype"))
	if _LLM_Tray["inline_autotype"]
		m.Check(inline_label)

	m.Add()

	; Streaming (token-by-token display)
	streaming_label := t("menu.llm.show_streaming")
	RegisterMenuItem(m, streaming_label, (*) => LLM_Tray_ToggleBool("streaming"))
	if _LLM_Tray["streaming"]
		m.Check(streaming_label)
	; Streaming only meaningful when show-all-at-once (multi) is enabled
	if !_LLM_Tray["show_all_at_once"]
		m.Disable(streaming_label)

	; Show all predictions at once
	all_at_once_label := t("menu.llm.show_all_at_once")
	RegisterMenuItem(m, all_at_once_label, (*) => LLM_Tray_ToggleBool("show_all_at_once"))
	if _LLM_Tray["show_all_at_once"]
		m.Check(all_at_once_label)
	if (n < 2)
		m.Disable(all_at_once_label)

	m.Add()

	; Indent level submenu — mirrors HS settings_manager.build_indent_menu():
	;   0           → "Aucun" (special-cased so 0 reads naturally).
	;   -1 or +1    → singular "espace" (with sign preserved so the user can
	;                 tell -1 from +1 — HS has a quirk that hides the number
	;                 for these values; AHK fixes the readability here).
	;   anything else → "N espaces" (plural, sign preserved for negatives).
	; Negative values yield a leading deletion of N chars so the predicted
	; continuation lines up at column-N relative to the original cursor.
	indent_menu := Menu()
	for lvl in LLM_TRAY_INDENT_OPTIONS {
		if (lvl == 0) {
			indent_label := t("menu.llm.indent_none")
		} else if (lvl == 1 or lvl == -1) {
			indent_label := lvl . " " . t("menu.llm.indent_space")
		} else {
			indent_label := lvl . " " . t("menu.llm.indent_spaces")
		}
		RegisterMenuItem(indent_menu, indent_label, _LLM_Tray_MakeSetIndentHandler(lvl))
		if (lvl == _LLM_Tray["pred_indent"])
			indent_menu.Check(indent_label)
	}
	indent_parent_label := t("menu.llm.indent_label")
	m.Add(indent_parent_label, indent_menu)
	if (n < 2)
		m.Disable(indent_parent_label)
	_LLM_MaybeAddReset(m,
		_LLM_Tray["pred_indent"],
		_LLM_DefaultFor("llm_pred_indent", 0),
		(*) => _LLM_AssignAndRebuild("pred_indent",
			_LLM_DefaultFor("llm_pred_indent", 0)))

	return m
}





; ==========================================
; =====================================
; ======= 5/ Navigation Submenu =======
; =====================================
; ==========================================

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
	RegisterMenuItem(m, nav_item_lbl, (*) => LLM_Tray_PromptNavModifiers())
	if (n < 2)
		m.Disable(nav_item_lbl)

	val_display  := (_LLM_Tray["val_modifiers"] != "") ? _LLM_Tray["val_modifiers"] : t("menu.llm.digits_only")
	val_key_range := (n == 10) ? "1-0" : "1-" . n
	val_item_lbl := StrReplace(t("menu.llm.val_label"), "%s", val_key_range) . " — " . val_display
	RegisterMenuItem(m, val_item_lbl, (*) => LLM_Tray_PromptValModifiers())
	if (n < 2)
		m.Disable(val_item_lbl)

	return m
}





; ==============================================
; =============================================
; ======= 6/ Numeric Prompt Dispatchers =======
; =============================================
; ==============================================

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
	; Reject non-numeric typos before converting — Integer() throws on a bad
	; string (e.g. "abc" or "12,5"), and this runs in a menu-callback thread
	; where the error would surface as an unhandled AHK dialog (mirrors the
	; IsInteger guard in LLM_Tray_PromptOllamaPort)
	if !IsInteger(ib.Value)
		return
	val := Integer(ib.Value)
	if (min_val > 0 && val < min_val) || (max_val > 0 && val > max_val)
		return
	_LLM_Tray[key] := val
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
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
	global _LLM_Tray
	_LLM_Tray[tray_key] := value
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
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
	RegisterMenuItem(menu, label, (*) => on_click())
}

LLM_Tray_PromptDebounce() {
	LLM_Tray_PromptNumeric("debounce_ms", t("menu.llm.trigger_menu_title"),
		t("menu.llm.debounce_prompt"), 50, 10000)
}

; Ollama port has its own prompt (not LLM_Tray_PromptNumeric) because applying it
; means rebuilding the HTTP client's base URL via LLM_Ollama_SetPort, not feeding
; the value through LLM_Engine_Init(LLM_Tray_BuildOpts()) — the port is a property
; of the api_ollama client, not of the engine options.
LLM_Tray_PromptOllamaPort() {
	global _LLM_Tray
	current := _LLM_Tray.Has("ollama_port") ? _LLM_Tray["ollama_port"] : 11434
	ib := InputBox(t("menu.llm.ollama_port_prompt"), t("menu.llm.ollama_port_title"), "w400 h120", current)
	if (ib.Result != "OK" || ib.Value == "")
		return
	if !IsInteger(ib.Value)
		return
	val := Integer(ib.Value)
	if (val < 1024 || val > 65535)
		return
	_LLM_Tray["ollama_port"] := val
	LLM_Ollama_SetPort(val)
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
}

; Resets the Ollama port to its shared default and applies it live.
LLM_Tray_ResetOllamaPort(default_port) {
	global _LLM_Tray
	_LLM_Tray["ollama_port"] := default_port
	LLM_Ollama_SetPort(default_port)
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
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
	; Reject non-numeric typos before converting — Integer() throws on a bad
	; string in this menu-callback thread (mirrors LLM_Tray_PromptOllamaPort)
	if !IsInteger(ib.Value)
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
	; Accept the comma-decimal habit common on a French keyboard (the project's
	; UI locale) by normalising "12,5" to "12.5" before validating
	raw := StrReplace(ib.Value, ",", ".")
	; Reject non-numeric typos before converting — Float() throws on a bad
	; string in this menu-callback thread (mirrors LLM_Tray_PromptOllamaPort)
	if !IsNumber(raw)
		return
	val := Float(raw)
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
	LLM_Tray_BindNavHotkeys()
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
	LLM_Tray_BindNavHotkeys()
}





; ================================================
; ===============================================
; ======= 7/ Trigger Shortcut + Add Model =======
; ===============================================
; ================================================

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
