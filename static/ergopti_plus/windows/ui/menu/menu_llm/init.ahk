; ui/menu/menu_llm/init.ahk

; ==============================================================================
; MODULE: LLM Tray — Initialisation
; DESCRIPTION:
; Bootstraps the LLM tray module at script load. Reads persisted user
; preferences (passed in as a Map from ErgoptiPlus's main config loader),
; restores trigger shortcut + per-app overrides + API entries, registers the
; Ctrl+<n> profile hotkeys, builds the menu, and schedules the background
; health probe.
;
; FEATURES & RATIONALE:
; 1. Defensive priority reset: a crashed install would leave the process at
;    PriorityClass=High; every boot starts from Normal.
; 2. Typed restoration: explicit string / number / boolean / array key lists
;    avoid silently coercing the wrong type when a stale config carries a
;    legacy value.
; 3. Async health probe: avoids the 2 s blocking probe at boot that used to
;    swallow the first user keystrokes (see commit 6ac57794 history).
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Tray Initialisation =======
; ======================================
; ======================================

_LLM_Menu_RestoreSavedOptsOnce(saved_opts) {
	global _LLM_Menu, _LLM_Menu_Loaded
	if _LLM_Menu_Loaded
		return false
	if !(saved_opts is Map)
		throw TypeError("LLM saved options must be a Map.")
	static _str_keys := ["model", "profile_id", "language", "temperature",
		"nav_modifiers", "val_modifiers", "trigger_shortcut", "backend",
		"api_entry_id"]
	static _num_keys := ["n_predictions", "min_words", "max_words", "debounce_ms",
		"ctx_chars", "pred_indent", "ollama_port"]
	static _bool_keys := ["enabled", "instant_on_word_end", "after_hotstring",
		"reset_on_nav", "disable_url_bars", "disable_password_fields",
		"show_info_bar", "streaming", "show_all_at_once", "auto_raise_temp",
		"auto_profile_for_model", "onboarding_seen", "inline_autotype"]
	static _arr_keys := ["user_profiles", "disabled_apps"]
	for key in _str_keys {
		if !saved_opts.Has(key)
			continue
		if LLM_Option_TryNormalize(key, saved_opts[key], &Normalized)
			_LLM_Menu[key] := Normalized
		else
			try LoggerError("LLM",
				"Ignoring persisted '{1}' because its scalar type is invalid.", key)
	}
	for key in ["nav_modifiers", "val_modifiers"] {
		if !LLM_Menu_IsValidModifierString(_LLM_Menu[key]) {
			LoggerError("LLM", "Ignoring invalid persisted {1} value: '{2}'.", key, _LLM_Menu[key])
			_LLM_Menu[key] := (key == "val_modifiers") ? "alt" : ""
		}
	}
	for key in _num_keys {
		if !saved_opts.Has(key)
			continue
		if LLM_Option_TryNormalize(key, saved_opts[key], &Normalized)
			_LLM_Menu[key] := Normalized
		else
			try LoggerError("LLM",
				"Ignoring persisted '{1}' because it is not an integer.", key)
	}
	for key in _bool_keys {
		if !saved_opts.Has(key)
			continue
		if LLM_Option_TryNormalize(key, saved_opts[key], &Normalized)
			_LLM_Menu[key] := Normalized
		else
			try LoggerError("LLM",
				"Ignoring persisted '{1}' because it is not a Boolean.", key)
	}
	if !LLM_BackendCapabilities(_LLM_Menu["backend"])["streaming"]
		_LLM_Menu["streaming"] := false
	for key in _arr_keys {
		if !saved_opts.Has(key)
			continue
		if LLM_Option_TryNormalize(key, saved_opts[key], &Normalized)
			_LLM_Menu[key] := Normalized
		else
			try LoggerError("LLM",
				"Ignoring persisted '{1}' because its array shape is invalid.", key)
	}
	if saved_opts.Has("app_profile_overrides") {
		if LLM_Option_TryNormalize("app_profile_overrides",
				saved_opts["app_profile_overrides"], &NormalizedOverrides)
			_LLM_Menu["app_profile_overrides"] := NormalizedOverrides
		else
			try LoggerError("LLM",
				"Ignoring persisted app-profile overrides because their shape is invalid.")
	}
	return true
}

/**
 * Bootstraps the tray menu and starts the LLM bridge if auto-start is enabled.
 * @param {Map} saved_opts - Persisted settings loaded from INI/registry.
 */
LLM_Menu_Init(saved_opts := Map()) {
	global _LLM_Menu, _LLM_Menu_Handle, _LLM_Menu_InTray, DRIVER_BASELINE_PRIORITY_CLASS
	global _LLM_Menu_Loaded
	global LLM_HEALTH_PROBE_INTERVAL_MS

	; Defensive: a previous session that crashed mid-install would have
	; left the AHK process at PriorityClass = High (we boost it in
	; LLM_Deps_RunInstaller to keep typing responsive during winget,
	; and lower it back in LLM_Deps_OnPollProbeResult on completion).
	; Reset to the driver baseline at every boot so a fresh script never
	; inherits a stale boost. MUST use the shared constant, not a hardcoded
	; "Normal" literal — this call runs ~16 ms after ErgoptiPlus.ahk's boot
	; boost, and a literal here silently reverted it every session
	; (driver-baseline-priority-reverted-to-normal).
	try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)

	; saved_opts derives from the boot-only _IniCache snapshot. A tray rebuild
	; calls initMenu again after live commits, so replaying that snapshot here
	; would roll every LLM setting back in memory while disk keeps the new value.
	; Restore persisted values exactly once; later builds use the published map.
	FirstRestore := _LLM_Menu_RestoreSavedOptsOnce(saved_opts)
	; _LLM_Menu_RestoreSavedOptsOnce installs Map-valued overrides before any
	; model correction can persist a full detached candidate; otherwise an early
	; correction could durably replace the user's overrides with the empty default.
	if FirstRestore && _LLM_Menu_PruneOrphanProfileOverrides(_LLM_Menu)
		LoggerWarn("LLM", "Removed orphan per-application profile override(s) during startup.")

	; Keep Features["llm"] aligned with tray state so the deferred startup
	; SaveFullConfig() (~500 ms) does not rewrite num_predictions (etc.) back
	; to manifest defaults and clobber a change the user just saved.
	if IsSet(_LLM_Menu_SyncToFeatures)
		_LLM_Menu_SyncToFeatures()

	; Apply the persisted Ollama port to the HTTP client BEFORE any request fires
	; (bootstrap probe, warmup) so every call targets the user's configured port.
	if IsSet(LLM_Ollama_SetPort) and _LLM_Menu.Has("ollama_port")
		LLM_Ollama_SetPort(_LLM_Menu["ollama_port"])

	; Auto-correct legacy raw-tag configs (e.g. qwen2.5:3b) before the first
	; bootstrap / bridge start so predictions do not silently fail.
	if (_LLM_Menu["backend"] == "ollama")
		LLM_Menu_EnsureModelReady()

	; Reconcile the native owner even for an empty string. This is essential on
	; explicit reload and also prevents a stale live handle from surviving while
	; the row says that the shortcut is disabled.
	if FirstRestore {
		TriggerReady := LLM_Menu_ApplyTriggerShortcut(
			_LLM_Menu["trigger_shortcut"])
		if !((TriggerReady is Integer) && TriggerReady == 1)
			try LoggerError("LLM",
				"Initial trigger shortcut activation remained incomplete.")
	}

	; Restore persisted remote API entries (lives in api_entries.json next to
	; the main config.toml — kept separate because the array-of-maps shape
	; would not survive the project's flat-TOML writer).
	_LLM_Menu_LoadApiEntries()

	; Register Ctrl+1 … Ctrl+9 once. Re-registering on every build_menu pass
	; would be wasteful and noisy in the AHK Hotkey log; doing it here
	; covers both fresh boots and post-Reload paths since LLM_Menu_Init is
	; the only entry into the tray module.
	LLM_Menu_BindProfileHotkeys()
	LLM_Menu_BindNavHotkeys()

	; (Removed) First-run LLM onboarding TrayTip — the unsolicited
	; "Text predictions available" balloon was perceived as noise by users
	; who already know what the tray menu offers. Discovery now lives
	; purely in the menu's "IA" submenu; no opt-in nag at startup.

	; Place the IA entry in the tray NOW (empty submenu, in its canonical position)
	; so the top-level menu is complete the instant initMenu returns, then defer the
	; expensive population (8 submenus + i18n lookups) to the post-"ready" boot tail.
	; A synchronous build here blocks initMenu mid-way — measured at ~1.6 s under
	; load — and a tray opened during that window shows only the items registered
	; before this point (the "menu shows only the first items" bug). Re-populating
	; _LLM_Menu_Handle in place later keeps the entry's position (see the persistent-
	; Menu note at its declaration), so menu order is preserved. The population is
	; armed UNCONDITIONALLY at the boot tail (SetTimer LLM_Menu_Build) — NOT signalled
	; from here via a flag: initMenu() itself runs inside the deferred tray-build pass,
	; so any flag set here would be read by the boot tail long before this line runs.
	if !_LLM_Menu_InTray {
		; initMenu may be constructing a detached replacement tree. Record the
		; root insertion in that transaction instead of exposing a half-built
		; tray while the rest of the menu is rendered.
		TrayMenuStage_Add(t("menu.llm.title"), _LLM_Menu_Handle)
		_LLM_Menu_InTray := true
	} else if IsObject(_TrayMenuStage) {
		; A full root replacement removed the previous IA parent entry. The
		; persistent submenu remains valid, but it must be attached to this new
		; staged root even though it was already in the retired tray.
		TrayMenuStage_Add(t("menu.llm.title"), _LLM_Menu_Handle)
	}

	; Bootstrap Ollama silently on reload when the feature was already enabled.
	; show_ui=false so the install window NEVER opens automatically — the user
	; must click the menu toggle to trigger a visible installation.
	;
	; An earlier attempt (commit 6ac57794) auto-resumed the install with UI
	; when Ollama wasn't reachable. Two problems: (a) the synchronous
	; LLM_OllamaIsRunning probe blocked the main thread for up to 2 seconds
	; on reload, which delayed PrefixWatcher's InputHook startup and caused
	; the first few user keystrokes to be swallowed; (b) the multi-minute
	; download then ran in the background while the user typed, contesting
	; CPU with the input pipeline. The build_warning_row below now surfaces
	; the missing-install state in the menu so the user can re-trigger the
	; install themselves when they're ready.
	if _LLM_Menu["enabled"]
		SetTimer(() => LLM_Menu_BootstrapCurrentBackend(false), -1)

	; Background health-tick: refreshes the dot on the shared cadence without
	; waiting for the user to open the menu. The previous "probe on menu open"
	; model painted a stale dot on the first open after the daemon died
	; (probe result only landed the second time around). The tick uses
	; the same flip-guard as the on-open probe, so a stable backend
	; doesn't trigger spurious rebuilds.
	SetTimer(_LLM_Menu_FireHealthProbe, LLM_HEALTH_PROBE_INTERVAL_MS)

	_LLM_Menu_Loaded := true
}
