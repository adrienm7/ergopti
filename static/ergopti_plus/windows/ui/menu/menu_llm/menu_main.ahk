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





; ==============================================
; ==============================================
; ======= 1/ Top-Level Menu Construction =======
; ==============================================
; ==============================================

/**
 * Builds (or rebuilds) the LLM submenu inside the tray.
 * Builds a detached Menu first, then replaces the tray entry in one short
 * critical publication. The previously published submenu remains callable when
 * an asynchronous dependency callback or a settings action requests a rebuild.
 */
LLM_Menu_Build() {
	global _LLM_Menu, _LLM_Menu_Handle, _LLM_Menu_InTray
	static _Building := false
	if _Building
		return
	_Building := true
	; Never clear the published submenu before its replacement is complete. A menu
	; build can be preempted by timers and callbacks; an in-place Delete() exposed
	; an empty or partial LLM tree and silently dropped the user's next click.
	OldHandle := _LLM_Menu_Handle
	StagedHandle := Menu()
	_LLM_Menu_Handle := StagedHandle
	Published := false
	try {
	_t0 := A_TickCount
	try LoggerInfo("LLM", "LLM_Menu_Build: building IA submenu (enabled={1}, inTray={2}).", _LLM_Menu["enabled"] ? "true" : "false", _LLM_Menu_InTray ? "true" : "false")
	_tStaged := A_TickCount

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

	; ── Settings rows ────────────────────────────────────────────────────────
	; Row ORDER and the disabled-when-off POLICY come from the shared menu manifest
	; (_shared/modules/menu/menu_manifest.json, key llm_menu), so the Windows and
	; macOS IA menus can never drift again (a greying mismatch between them was the
	; bug this prevents).
	; The per-row native label + submenu builder are dispatched by id inside
	; _LLM_Menu_EmitRow — those must stay native because they read Win32/tray state;
	; the spec owns only the order and the greying. backend/model carry
	; disabled_when_off=false (usable while off, so the user can configure before
	; enabling); the rest carry true (greyed while off). Conditional/native-only rows
	; (thinking-model info, the num-predictions reset, the inner separator) are
	; emitted from inside _LLM_Menu_EmitRow at their anchor row.
	_rows := _LLM_MenuLayout_Rows()
	; Diagnostic breakdown of the detached staging work. Publishing and pruning
	; happen only after every row has been successfully constructed.
	try LoggerInfo("LLM", "LLM_Menu_Build: pre-emit staging took {1} ms.", A_TickCount - _tStaged)
	try LoggerInfo("LLM", "LLM_Menu_Build: emitting {1} settings row(s) from shared spec…", _rows.Length)
	for _i, _row in _rows
		_LLM_Menu_EmitRow(_row["id"], (_row["disabled_when_off"] ? _disabled : false), _llm_is_operational, _MR_Get(_row, "health_dot", false))
	try LoggerInfo("LLM", "LLM_Menu_Build: settings rows emitted ({1} item(s) so far).", DllCall("GetMenuItemCount", "ptr", _LLM_Menu_Handle.Handle, "int"))

	_LLM_Menu_Handle.Add()  ; separator
	RegisterMenuItem(_LLM_Menu_Handle, t("menu.llm.about"), LLM_Menu_OnAbout)

	; Publish the completed subtree and retire obsolete dispatcher IDs in one
	; short, non-preemptible commit. Building itself deliberately stays outside
	; Critical so a slow menu cannot starve the keyboard hook.
	_PublishCritical := Critical("On")
	try {
		A_TrayMenu.Add(t("menu.llm.title"), _LLM_Menu_Handle)
		_LLM_Menu_InTray := true
		Published := true
		; Prune only after the tray points at the staged subtree. The whole-tray
		; walk then retains every new ID and removes the old generation's IDs.
		MenuDispatcher_PruneMenu(_LLM_Menu_Handle)
	} finally {
		Critical(_PublishCritical)
	}

	; Check the parent tray entry only when enabled AND Ollama is confirmed ready.
	; Both branches are guarded with try: the item may not exist yet if the updater
	; timer fires LLM_Menu_Build() before initMenu has had a chance to register it.
	if (_LLM_Menu["enabled"] && _deps_ready) {
		try A_TrayMenu.Check(t("menu.llm.title"))
	} else {
		try A_TrayMenu.Uncheck(t("menu.llm.title"))
	}
	try LoggerInfo("LLM", "LLM_Menu_Build: IA submenu built with {1} item(s) in {2}ms.", DllCall("GetMenuItemCount", "ptr", _LLM_Menu_Handle.Handle, "int"), A_TickCount - _t0)
	} catch as e {
		; A failed staged build leaves the previous tree live. This is fail-closed
		; for output: no menu action disappears merely because a new row failed.
		if !Published {
			_LLM_Menu_Handle := OldHandle
			try StagedHandle.Delete()
		}
		try LoggerError("LLM", "LLM_Menu_Build FAILED: {1} ({2}:{3}).", e.Message, e.File, e.Line)
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




; =====================================================
; ===== 1.1) Shared-spec-driven settings row emit =====
; =====================================================

/**
 * Returns the ordered settings-row list for this platform from the shared menu
 * manifest (_shared/modules/menu/menu_manifest.json, key ``llm_menu``) — the
 * SINGLE SOURCE OF TRUTH shared with the macOS renderer so the two IA menus can
 * never drift in row order or greying policy. Cached after the first read (the
 * manifest is static for the session).
 *
 * The rows used to live in a SECOND shared file of their own
 * (_shared/modules/llm/menu_layout.json); one menu therefore had two shared
 * descriptions, and the manifest's ``llm_menu`` key described a menu only Linux
 * drew. Reading the manifest here is what collapses the two back into one.
 *
 * Rows carrying a ``platforms`` restriction that excludes "ahk" — Linux's two
 * inline lists — are filtered out exactly as every other manifest-driven menu
 * filters them.
 *
 * Falls back to a built-in mirror if the manifest is missing/corrupt so the menu
 * always renders; the built-in list is pinned to the manifest by the
 * cross-platform contract test (tests/meta/test_llm_menu_layout_shared.ahk), so
 * it cannot drift.
 * @returns {Array} Array of Maps, each with "id" (string) and "disabled_when_off" (bool).
 */
_LLM_MenuLayout_Rows() {
	static _cache := ""
	if (_cache != "")
		return _cache
	rows := _LLM_MenuLayout_Fallback()
	try {
		Declared := _MR_GetMenuDef("llm_menu")
		Filtered := []
		for _, Entry in Declared {
			; Separators and Linux's inline lists are not settings rows: this
			; dispatch emits a native submenu per id, and only the declared
			; ``dynamic`` rows have one.
			if (Entry is Map && _MR_IsForAhk(Entry) && _MR_Get(Entry, "type", "") == "dynamic")
				Filtered.Push(Entry)
		}
		if (Filtered.Length > 0)
			rows := Filtered
		else
			try LoggerWarn("LLM", "menu_manifest.json 'llm_menu' yielded no Windows row — using built-in fallback order.")
	} catch as e {
		try LoggerWarn("LLM", "menu_manifest.json load failed ({1}) — using built-in fallback order.", e.Message)
	}
	_cache := rows
	return rows
}

/**
 * Built-in fallback for the shared layout — mirrors the manifest's ``llm_menu``
 * row order and disabled-when-off policy. Pinned to the manifest by the contract
 * test so the two never diverge; exists only so a missing/corrupt manifest still
 * yields a menu.
 * @returns {Array} The canonical settings-row list.
 */
_LLM_MenuLayout_Fallback() {
	return [
		Map("id", "llm_backend",             "disabled_when_off", false, "health_dot", false),
		Map("id", "llm_model",               "disabled_when_off", false, "health_dot", true),
		Map("id", "llm_profile",             "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_num_predictions",     "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_trigger",             "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_generation_settings", "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_display",             "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_navigation",          "disabled_when_off", true,  "health_dot", false)
	]
}

/**
 * Emits one settings row by its shared-spec id. The spec (_LLM_MenuLayout_Rows)
 * owns the ORDER and the `disabled` flag; this dispatch owns the platform-native
 * label formatting and submenu construction (which read Win32/tray state and so
 * cannot live in shared data). Conditional native-only rows that have no shared
 * entry — the thinking-model info row, the num-predictions reset row, and the
 * inner separator — are emitted here at their anchor row to preserve menu order.
 * @param {String}  id                  Row id from the manifest's llm_menu.
 * @param {Boolean} disabled            Greying flag already resolved from the spec policy.
 * @param {Boolean} llm_is_operational  Enabled AND deps ready — gates the health dot.
 * @param {Boolean} has_health_dot      The row's declared health_dot flag. Which row
 *                                      carries the dot is the manifest's call, not this
 *                                      file's, so macOS cannot end up dotting another row.
 */
_LLM_Menu_EmitRow(id, disabled, llm_is_operational, has_health_dot := false) {
	global _LLM_Menu, _LLM_Menu_Handle
	switch id {
	case "llm_backend":
		_LLM_Menu_AddRow(StrReplace(t("menu.llm.model_backend"), "%s", _LLM_Menu["backend"]), LLM_Menu_BuildBackendMenu(), disabled)
	case "llm_model":
		; Build the submenu, fire the async probes (backend health + installed-tags
		; list), then prefix the label with the cached backend-health dot (🟢
		; reachable / 🔴 down / "" when off) — mirrors HS's build_model_item
		; health_dot block. BOTH probes are non-blocking and paint on the next pass:
		; the submenu reads only the in-memory caches, never a synchronous /api/tags
		; or reachability round-trip, so opening the tray can never freeze the thread.
		model_menu := LLM_Menu_BuildModelMenu()
		; Force past the idle gate: this row is only painted while the tray menu is
		; actually being built, i.e. for a user looking at it right now, so the dot
		; must refresh even when A_TimeIdlePhysical claims the machine has been
		; unattended. That counter only notices the tray click because AHK's mouse
		; hook happens to be installed (nav_layer.ahk declares wheel hotkeys) — far
		; too incidental a dependency to hang the on-demand refresh on. The 3 s
		; throttle inside the helper is NOT bypassed, so a rebuild storm still costs
		; a single ping.
		_LLM_Menu_FireHealthProbe(true)
		_LLM_Menu_FireInstalledTagsProbe()
		last_status := _LLM_Menu.Has("last_health_status") ? _LLM_Menu["last_health_status"] : ""
		health_dot := (has_health_dot && llm_is_operational)
			? ((last_status == "ok") ? "🟢 " : (last_status == "ko") ? "🔴 " : "")
			: ""
		_LLM_Menu_AddRow(health_dot . StrReplace(t("menu.llm.model_label"), "%s", _LLM_Menu["model"]), model_menu, disabled)
		; Thinking-model info row — conditional, native-only (mirrors HS thinking-info).
		if _LLM_Menu_IsThinkingModel(_LLM_Menu["model"]) {
			warning_label := t("menu.llm.thinking_model_info")
			_LLM_Menu_Handle.Add(warning_label, (*) => 0)
			try _LLM_Menu_Handle.Disable(warning_label)
		}
	case "llm_profile":
		_LLM_Menu_AddRow(StrReplace(t("menu.profiles.profile_label_prefix"), "%s", LLM_Menu_GetProfileLabel(_LLM_Menu["profile_id"])), LLM_Menu_BuildProfileMenu(), disabled)
	case "llm_num_predictions":
		_LLM_Menu_AddRow(StrReplace(t("menu.llm.num_predictions_label"), "%s", _LLM_Menu["n_predictions"]), LLM_Menu_BuildNMenu(), disabled)
		; Conditional reset row (native), then the separator before the trigger block.
		_LLM_MaybeAddReset(_LLM_Menu_Handle,
			_LLM_Menu["n_predictions"],
			_LLM_DefaultFor("llm_num_predictions", 3),
			(*) => _LLM_AssignAndRebuild("n_predictions", _LLM_DefaultFor("llm_num_predictions", 3)))
		_LLM_Menu_Handle.Add()  ; separator
	case "llm_trigger":
		_LLM_Menu_AddRow(t("menu.llm.trigger_menu_title"), LLM_Menu_BuildTriggerMenu(), disabled)
	case "llm_generation_settings":
		_LLM_Menu_AddRow(t("menu.llm.generation_menu_title"), LLM_Menu_BuildGenerationMenu(), disabled)
	case "llm_display":
		_LLM_Menu_AddRow(t("menu.llm.display_menu_title"), LLM_Menu_BuildDisplayMenu(), disabled)
	case "llm_navigation":
		_LLM_Menu_AddRow(t("menu.llm.nav_menu_title"), LLM_Menu_BuildNavMenu(), disabled)
	default:
		try LoggerWarn("LLM", "_LLM_Menu_EmitRow: unknown row id '{1}' in the shared menu manifest — skipped.", id)
	}
}
