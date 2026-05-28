; ui/tray_llm/menu_main.ahk

; ==============================================================================
; MODULE: LLM Tray — Main Menu Orchestrator
; DESCRIPTION:
; Top-level builder that assembles every sub-menu (backend, model, profile,
; predictions count, trigger, generation, display, navigation) into the
; persistent ``_LLM_Tray_Menu`` object. Reads state from ``_LLM_Tray`` and
; delegates each submenu to its own builder defined in the menu_<topic>.ahk
; companion modules.
;
; FEATURES & RATIONALE:
; 1. Persistent menu object: the AHK v2 ``Menu`` instance is reused across
;    rebuilds so the canonical tray position is preserved.
; 2. Health-dot prefix: backend reachability is reflected via the 🟢/🔴 prefix
;    on the model entry, painted from the most recent async probe result.
; 3. Warning row: surfaces a missing Ollama install with a re-install click
;    target — without this, a missing daemon was completely silent.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ==============================================
; ======= 1/ Top-Level Menu Construction =======
; ==============================================
; ============================================

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

	; Enable / Disable toggle. The checked state MUST reflect
	; ``_LLM_Tray["enabled"]`` alone — that's the user's intent. We keep a
	; separate ``_llm_is_operational`` flag (enabled AND deps ready) for the
	; health dot below, because we still want a visual cue when the user
	; has flipped the toggle ON but Ollama hasn't finished installing yet.
	; Previously the checkbox itself used _llm_is_operational, so clicking
	; ON while Ollama was missing left the toggle visually OFF — the user
	; thought the click did nothing.
	_llm_is_operational := (_LLM_Tray["enabled"] && LLM_Deps_IsReady())
	AddCategoryToggleItem(_LLM_Tray_Menu,
		t("menu.llm.on"),
		t("menu.llm.off"),
		_LLM_Tray["enabled"],
		LLM_Tray_OnToggle)

	; Warning row — surfaces when the feature is ON but the active backend
	; can't actually answer (Ollama not installed yet, install crashed
	; mid-way, daemon got uninstalled). Clicking the row re-launches the
	; install with the WebView visible — same path as the toggle ON click
	; but without losing the user's enabled=true state. Without this row
	; a missing install was completely silent: the toggle showed ON, no
	; tooltip ever appeared, and the user had no obvious next step.
	if (_LLM_Tray["enabled"] and _LLM_Tray["backend"] == "ollama" and !LLM_Deps_IsReady()) {
		LoggerInfo("LLM", "Tray: showing 'Ollama not installed' warning row.")
		; Pass the function reference DIRECTLY (no fat-arrow wrapper). AHK
		; v2 menu callbacks call ``fn(ItemName, ItemPos, MenuObj)``, which
		; works because _LLM_Tray_OnWarningInstallClick is variadic. The
		; previous ``(*) => …`` lambda may have been swallowing exceptions
		; silently — when the user clicked nothing ever fired and no log
		; line was emitted.
		RegisterMenuItem(_LLM_Tray_Menu, t("menu.llm.warning_install_ollama"), _LLM_Tray_OnWarningInstallClick)
	}

	; Backend submenu
	backend_menu := LLM_Tray_BuildBackendMenu()
	backend_label := t("menu.llm.backend_label")
	_LLM_Tray_Menu.Add(StrReplace(backend_label, "%s", _LLM_Tray["backend"]), backend_menu)

	; Model submenu — prefix the label with a backend-health dot so the user
	; can tell at a glance whether the active backend is reachable, mirroring
	; HS's ui/menu/menu_llm/init.lua build_model_item (the "health_dot" block).
	; 🟢 = backend answered the latest async probe, 🔴 = either not running
	; or unreachable, "" when the feature is disabled entirely so the dot
	; does not nag while the user is intentionally off.
	;
	; The probe itself fires async every time the menu is rebuilt — the
	; dot paints with the previously-cached status and the next rebuild
	; reflects the new one. Same pattern as HS's probe_llm_health.
	model_menu := LLM_Tray_BuildModelMenu()
	_LLM_Tray_FireHealthProbe()
	last_status := _LLM_Tray.Has("last_health_status") ? _LLM_Tray["last_health_status"] : ""
	health_dot := _llm_is_operational
		? ((last_status == "ok") ? "🟢 " : (last_status == "ko") ? "🔴 " : "")
		: ""
	_LLM_Tray_Menu.Add(
		health_dot . StrReplace(t("menu.llm.model_label"), "%s", _LLM_Tray["model"]),
		model_menu)

	; Thinking-model warning row — surfaces when the active model has built-in
	; reasoning ("-r1" suffix, "thinking" / "reasoning" in the name). The
	; built-in "basic" / "advanced" profiles use short prompts that conflict
	; with the model's chain-of-thought, so an unattended user wonders why
	; the predictions are slow and verbose. The row is disabled (info-only)
	; and mirrors HS's ui/menu/menu_llm/init.lua thinking-info insertion.
	if _LLM_Tray_IsThinkingModel(_LLM_Tray["model"]) {
		warning_label := t("menu.llm.thinking_model_info")
		_LLM_Tray_Menu.Add(warning_label, (*) => 0)
		_LLM_Tray_Menu.Disable(warning_label)
	}

	; Profile submenu
	profile_menu := LLM_Tray_BuildProfileMenu()
	active_label := LLM_Tray_GetProfileLabel(_LLM_Tray["profile_id"])
	_LLM_Tray_Menu.Add(StrReplace(t("menu.profiles.profile_label_prefix"), "%s", active_label), profile_menu)

	; Number of predictions submenu — with the same conditional reset row that
	; HS exposes (ui/menu/menu_llm/init.lua build_menu near num_predictions).
	n_menu := LLM_Tray_BuildNMenu()
	_LLM_Tray_Menu.Add(StrReplace(t("menu.llm.num_predictions_label"), "%s", _LLM_Tray["n_predictions"]), n_menu)
	_LLM_MaybeAddReset(_LLM_Tray_Menu,
		_LLM_Tray["n_predictions"],
		_LLM_DefaultFor("llm_num_predictions", 3),
		(*) => _LLM_AssignAndRebuild("n_predictions",
			_LLM_DefaultFor("llm_num_predictions", 3)))

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
	RegisterMenuItem(_LLM_Tray_Menu, t("menu.llm.about"), LLM_Tray_OnAbout)

	; Register in the system tray on first call only.
	if !_LLM_Tray_InTray {
		A_TrayMenu.Add(t("menu.llm.title"), _LLM_Tray_Menu)
		_LLM_Tray_InTray := true
	}

	; Check the parent tray entry only when enabled AND Ollama is confirmed ready.
	; Both branches are guarded with try: the item may not exist yet if the updater
	; timer fires LLM_Tray_Build() before initMenu has had a chance to register it.
	if (_LLM_Tray["enabled"] && LLM_Deps_IsReady()) {
		try A_TrayMenu.Check(t("menu.llm.title"))
	} else {
		try A_TrayMenu.Uncheck(t("menu.llm.title"))
	}
}
