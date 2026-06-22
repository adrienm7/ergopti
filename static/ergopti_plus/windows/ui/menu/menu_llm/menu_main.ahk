; ui/menu/menu_llm/menu_main.ahk

; ==============================================================================
; MODULE: LLM Tray — Main Menu Orchestrator
; DESCRIPTION:
; Top-level builder that assembles every sub-menu (backend, model, profile,
; predictions count, trigger, generation, display, navigation) into the
; persistent ``_LLM_Menu_Handle`` object. Reads state from ``_LLM_Menu`` and
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
 * Uses the persistent _LLM_Menu_Handle object: first call registers it in the
 * tray (position is determined by call order in initMenu); subsequent calls
 * delete all items and repopulate in place, so the entry never moves.
 */
LLM_Menu_Build() {
	global _LLM_Menu, _LLM_Menu_Handle, _LLM_Menu_InTray
	static _Building := false
	if _Building
		return
	_Building := true
	try {
	try LoggerInfo("LLM", "LLM_Menu_Build: building IA submenu (enabled={1}, inTray={2}).", _LLM_Menu["enabled"] ? "true" : "false", _LLM_Menu_InTray ? "true" : "false")
	; Clear all existing items so we can repopulate in place.
	try _LLM_Menu_Handle.Delete()

	; Prune the dispatch-bypass Maps for THIS menu's now-deleted items. This is a
	; single-menu rebuild (not a full tray rebuild), so the global dispatch reset
	; must NOT be used here — it would wipe the dispatch
	; tracking of every OTHER live tray menu. Without this per-menu prune, the
	; dead menu-item IDs from each rebuild accumulate in
	; _MenuDispatchCallbacks / _MenuDispatchLastFire without bound across the
	; very frequent LLM_Menu_Build() passes (settings tweaks, model pulls).
	try MenuDispatcher_PruneMenu(_LLM_Menu_Handle)

	; Enable / Disable toggle. The checked state MUST reflect
	; ``_LLM_Menu["enabled"]`` alone — that's the user's intent. We keep a
	; separate ``_llm_is_operational`` flag (enabled AND deps ready) for the
	; health dot below, because we still want a visual cue when the user
	; has flipped the toggle ON but Ollama hasn't finished installing yet.
	; Previously the checkbox itself used _llm_is_operational, so clicking
	; ON while Ollama was missing left the toggle visually OFF — the user
	; thought the click did nothing.
	; Probe deps ONCE, guarded: when the feature is off at boot the deps
	; subsystem may not be ready to answer, and an unguarded throw here used to
	; abort the whole build BEFORE the toggle was added — leaving the IA submenu
	; empty, with no visible control to switch the feature back on.
	_deps_ready := false
	try _deps_ready := LLM_Deps_IsReady()
	_llm_is_operational := (_LLM_Menu["enabled"] && _deps_ready)

	; Mirror the macOS menu (ui/menu/menu_llm/init.lua is_disabled): when the
	; feature is OFF, render the FULL menu unchanged but grey out every settings
	; row — only the enable toggle stays live so the user can always turn the
	; feature back on.
	_disabled := !_LLM_Menu["enabled"]

	AddCategoryToggleItem(_LLM_Menu_Handle,
		t("menu.llm.on"),
		t("menu.llm.off"),
		_LLM_Menu["enabled"],
		LLM_Menu_OnToggle)

	; Warning row — surfaces when the feature is ON but the active backend
	; can't actually answer (Ollama not installed yet, install crashed
	; mid-way, daemon got uninstalled). Clicking the row re-launches the
	; install with the WebView visible — same path as the toggle ON click
	; but without losing the user's enabled=true state. Without this row
	; a missing install was completely silent: the toggle showed ON, no
	; tooltip ever appeared, and the user had no obvious next step.
	if (_LLM_Menu["enabled"] and _LLM_Menu["backend"] == "ollama" and !_deps_ready) {
		LoggerInfo("LLM", "Tray: showing 'Ollama not installed' warning row.")
		; Pass the function reference DIRECTLY (no fat-arrow wrapper). AHK
		; v2 menu callbacks call ``fn(ItemName, ItemPos, MenuObj)``, which
		; works because _LLM_Menu_OnWarningInstallClick is variadic. The
		; previous ``(*) => …`` lambda may have been swallowing exceptions
		; silently — when the user clicked nothing ever fired and no log
		; line was emitted.
		RegisterMenuItem(_LLM_Menu_Handle, t("menu.llm.warning_install_ollama"), _LLM_Menu_OnWarningInstallClick)
	}

	; Backend submenu
	backend_menu := LLM_Menu_BuildBackendMenu()
	_LLM_Menu_AddRow(StrReplace(t("menu.llm.model_backend"), "%s", _LLM_Menu["backend"]), backend_menu, _disabled)

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
	model_menu := LLM_Menu_BuildModelMenu()
	_LLM_Menu_FireHealthProbe()
	last_status := _LLM_Menu.Has("last_health_status") ? _LLM_Menu["last_health_status"] : ""
	health_dot := _llm_is_operational
		? ((last_status == "ok") ? "🟢 " : (last_status == "ko") ? "🔴 " : "")
		: ""
	_LLM_Menu_AddRow(
		health_dot . StrReplace(t("menu.llm.model_label"), "%s", _LLM_Menu["model"]),
		model_menu, _disabled)

	; Thinking-model warning row — surfaces when the active model has built-in
	; reasoning ("-r1" suffix, "thinking" / "reasoning" in the name). The
	; built-in "basic" / "advanced" profiles use short prompts that conflict
	; with the model's chain-of-thought, so an unattended user wonders why
	; the predictions are slow and verbose. The row is disabled (info-only)
	; and mirrors HS's ui/menu/menu_llm/init.lua thinking-info insertion.
	if _LLM_Menu_IsThinkingModel(_LLM_Menu["model"]) {
		warning_label := t("menu.llm.thinking_model_info")
		_LLM_Menu_Handle.Add(warning_label, (*) => 0)
		_LLM_Menu_Handle.Disable(warning_label)
	}

	; Profile submenu
	profile_menu := LLM_Menu_BuildProfileMenu()
	active_label := LLM_Menu_GetProfileLabel(_LLM_Menu["profile_id"])
	_LLM_Menu_AddRow(StrReplace(t("menu.profiles.profile_label_prefix"), "%s", active_label), profile_menu, _disabled)

	; Number of predictions submenu — with the same conditional reset row that
	; HS exposes (ui/menu/menu_llm/init.lua build_menu near num_predictions).
	n_menu := LLM_Menu_BuildNMenu()
	_LLM_Menu_AddRow(StrReplace(t("menu.llm.num_predictions_label"), "%s", _LLM_Menu["n_predictions"]), n_menu, _disabled)
	_LLM_MaybeAddReset(_LLM_Menu_Handle,
		_LLM_Menu["n_predictions"],
		_LLM_DefaultFor("llm_num_predictions", 3),
		(*) => _LLM_AssignAndRebuild("n_predictions",
			_LLM_DefaultFor("llm_num_predictions", 3)))

	_LLM_Menu_Handle.Add()  ; separator

	; Trigger settings submenu
	trigger_menu := LLM_Menu_BuildTriggerMenu()
	_LLM_Menu_AddRow(t("menu.llm.trigger_menu_title"), trigger_menu, _disabled)

	; Generation settings submenu
	gen_menu := LLM_Menu_BuildGenerationMenu()
	_LLM_Menu_AddRow(t("menu.llm.generation_menu_title"), gen_menu, _disabled)

	; Display settings submenu
	disp_menu := LLM_Menu_BuildDisplayMenu()
	_LLM_Menu_AddRow(t("menu.llm.display_menu_title"), disp_menu, _disabled)

	; Navigation settings submenu
	nav_menu := LLM_Menu_BuildNavMenu()
	_LLM_Menu_AddRow(t("menu.llm.nav_menu_title"), nav_menu, _disabled)

	_LLM_Menu_Handle.Add()  ; separator
	RegisterMenuItem(_LLM_Menu_Handle, t("menu.llm.about"), LLM_Menu_OnAbout)

	; Register in the system tray on first call only.
	if !_LLM_Menu_InTray {
		A_TrayMenu.Add(t("menu.llm.title"), _LLM_Menu_Handle)
		_LLM_Menu_InTray := true
	}

	; Check the parent tray entry only when enabled AND Ollama is confirmed ready.
	; Both branches are guarded with try: the item may not exist yet if the updater
	; timer fires LLM_Menu_Build() before initMenu has had a chance to register it.
	if (_LLM_Menu["enabled"] && _deps_ready) {
		try A_TrayMenu.Check(t("menu.llm.title"))
	} else {
		try A_TrayMenu.Uncheck(t("menu.llm.title"))
	}
	try LoggerInfo("LLM", "LLM_Menu_Build: IA submenu built with {1} item(s).", DllCall("GetMenuItemCount", "ptr", _LLM_Menu_Handle.Handle, "int"))
	} finally {
		_Building := false
	}
}




/**
 * Adds a settings row to the LLM menu, greying it out when the feature is off.
 * Mirrors the macOS ``disabled = is_disabled`` pattern (ui/menu/menu_llm/
 * init.lua): every row is always present at a stable position, but only the
 * enable toggle stays interactive while the feature is disabled — so the menu
 * never collapses to an empty/unusable state the user cannot recover from.
 * @param {String}  label    Final, fully-formatted menu label.
 * @param {Menu}    target   Submenu object (or callback) to attach.
 * @param {Boolean} disabled True when the LLM feature is off.
 */
_LLM_Menu_AddRow(label, target, disabled) {
	global _LLM_Menu_Handle
	_LLM_Menu_Handle.Add(label, target)
	if disabled
		try _LLM_Menu_Handle.Disable(label)
}
