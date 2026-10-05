; ui/menu/menu_llm/init.ahk

; ==============================================================================
; MODULE: LLM Tray — Initialisation
; DESCRIPTION:
; Bootstraps the LLM tray module at script load. Reads persisted user
; preferences (passed in as a Map from ErgoptiPlus's main config loader),
; restores per-app overrides + API entries, registers the
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

; Capture every healthcheck field from one published menu owner transaction.
; The loaded bit is provenance: defaults constructed at include time are not a
; statement about the user's current configuration until boot restoration wins.
LLM_Menu_HealthSnapshot() {
	global _LLM_Menu, _LLM_Menu_Loaded
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_Loaded || !(_LLM_Menu is Map)
			return Map("available", false)
		return Map(
			"available", true,
			"enabled", _LLM_Menu.Get("enabled", false) ? true : false,
			"backend", _LLM_Menu.Get("backend", "unknown"),
			"profile_id", _LLM_Menu.Get("profile_id", "unknown"),
			"model", _LLM_Menu.Get("model", "n/a"),
			"n_predictions", _LLM_Menu.Get("n_predictions", "n/a"),
			"streaming", _LLM_Menu.Get("streaming", "n/a"))
	} finally {
		Critical(PreviousCritical)
	}
}

_LLM_Menu_RestoreSavedOptsOnce(saved_opts) {
	global _LLM_Menu, _LLM_Menu_Loaded
	if _LLM_Menu_Loaded
		return false
	if !(saved_opts is Map)
		throw TypeError("LLM saved options must be a Map.")
	static _str_keys := ["model", "profile_id", "temperature",
		"nav_modifiers", "val_modifiers", "backend",
		"api_entry_id", "agent_system1", "agent_system2", "agent_mode"]
	static _num_keys := ["n_predictions", "min_words", "max_words", "debounce_ms",
		"ctx_chars", "pred_indent", "ollama_port"]
	static _bool_keys := ["enabled", "instant_on_word_end", "after_hotstring",
		"reset_on_nav", "disable_url_bars", "disable_password_fields",
		"show_info_bar", "streaming", "show_all_at_once", "auto_raise_temp",
		"auto_profile_for_model", "onboarding_seen", "inline_autotype"]
	static _arr_keys := ["user_profiles", "disabled_apps", "agent_disabled_apps"]
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
			_LLM_Menu[key] := LLM_Defaults_ModifierString("llm_" . key)
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
	_LLM_Menu["streaming"] := LLM_EffectiveStreaming(
		_LLM_Menu["backend"], _LLM_Menu["streaming"])
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

_LLM_Menu_ActivateFirstRestoreHotkeys(FirstRestore, ProfileFn := 0,
		NavFn := 0) {
	global _LLM_PROFILE_HOTKEY_STATUS_READY
	global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	if !FirstRestore
		return true
	if !HasMethod(ProfileFn, "Call")
		ProfileFn := LLM_Menu_BindProfileHotkeys
	if !HasMethod(NavFn, "Call")
		NavFn := LLM_Menu_BindNavHotkeys
	ProfileStatus := ProfileFn.Call()
	if !((ProfileStatus is Integer)
			&& (ProfileStatus == _LLM_PROFILE_HOTKEY_STATUS_READY
				|| ProfileStatus == _LLM_PROFILE_HOTKEY_STATUS_DEGRADED))
		return false
	NavReady := NavFn.Call()
	return (NavReady is Integer) && NavReady == 1
}

; Whether the first activation of the AI hotkeys waits for the resume, and how
; many times that resume may try it, how far apart.
global _LLM_Menu_FirstRestoreHotkeysDeferred := false
global _LLM_Menu_RuntimeActivated := false
global LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS := 3
global LLM_MENU_DEFERRED_HOTKEY_RETRY_MS := 500

/**
 * Activates the profile and navigation hotkeys of the first menu build, or
 * defers them to the resume when the driver is paused. A pause suspends the
 * native navigation owner, which then refuses every plan: a driver reloaded
 * under a pause builds its first tray root paused, failed here three times and
 * retired that root, leaving no menu (llm-hotkeys-deferred-by-pause). The
 * hotkeys cannot fire under a pause, so nothing is lost by waiting.
 * @param {Boolean} FirstRestore - True on the build that restored the options.
 * @param {Func} ProfileFn - Test seam of the profile hotkeys.
 * @param {Func} NavFn - Test seam of the navigation hotkeys.
 * @param {Boolean} IsPaused - Test seam; A_IsSuspended when omitted.
 * @returns {Boolean} True when the hotkeys are active or deferred.
 * @throws {Error} When an active driver could not activate them.
 */
_LLM_Menu_RequireFirstRestoreHotkeys(FirstRestore, ProfileFn := 0,
		NavFn := 0, IsPaused := unset) {
	global _LLM_Menu_FirstRestoreHotkeysDeferred
	if FirstRestore && (IsSet(IsPaused) ? IsPaused : A_IsSuspended) {
		_LLM_Menu_FirstRestoreHotkeysDeferred := true
		try LoggerInfo("LLM", "AI hotkeys deferred to the resume: the driver is paused.")
		return true
	}
	if _LLM_Menu_ActivateFirstRestoreHotkeys(FirstRestore, ProfileFn, NavFn)
		return true
	if _LLM_Menu_ProfileHotkeyRetryPending()
		throw TrayRootRetryPendingError(
			"initial LLM profile hotkeys are pending a bounded retry")
	LoggerError("LLM",
		"Initial LLM hotkey activation remained incomplete; retaining the tray build for retry.")
	throw Error("initial LLM hotkey surface is incomplete")
}

/**
 * Activates, once the driver is active again, the AI hotkeys a paused first
 * build deferred. A refusal is retried a bounded number of times, since the
 * native owner may still be finishing its own resume, then reported.
 * @param {Func} ActivateFn - Test seam returning true once the hotkeys are active.
 * @param {Integer} Attempt - One-based attempt number.
 * @param {Func} ScheduleFn - Test seam taking the retry callback and its delay.
 * @param {Boolean} IsPaused - Test seam; A_IsSuspended when omitted.
 * @returns {Boolean} True when nothing was deferred or the hotkeys are active.
 */
LLM_Menu_ActivateDeferredHotkeys(ActivateFn := 0, Attempt := 1, ScheduleFn := 0,
		IsPaused := unset) {
	global _LLM_Menu_FirstRestoreHotkeysDeferred
	global LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS, LLM_MENU_DEFERRED_HOTKEY_RETRY_MS
	if !_LLM_Menu_FirstRestoreHotkeysDeferred
		return true
	; Paused again before this ran: the next resume takes it.
	if (IsSet(IsPaused) ? IsPaused : A_IsSuspended)
		return false
	Activated := HasMethod(ActivateFn, "Call")
		? ActivateFn.Call() : _LLM_Menu_ActivateFirstRestoreHotkeys(true)
	if (Activated is Integer) && Activated == 1 {
		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		try LoggerInfo("LLM", "AI hotkeys deferred by the pause are active.")
		return true
	}
	if Attempt >= LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS {
		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		LoggerError("LLM",
			"AI hotkeys deferred by the pause could not be activated after {1} attempts.",
			Attempt)
		return false
	}
	Retry := LLM_Menu_ActivateDeferredHotkeys.Bind(ActivateFn, Attempt + 1, ScheduleFn)
	if HasMethod(ScheduleFn, "Call")
		ScheduleFn.Call(Retry, LLM_MENU_DEFERRED_HOTKEY_RETRY_MS)
	else
		SetTimer(Retry, -LLM_MENU_DEFERRED_HOTKEY_RETRY_MS)
	return false
}

_LLM_Menu_ApplyOllamaPortAtBoot(MenuState, SetPortFn := 0) {
	if !(MenuState is Map) || !MenuState.Has("ollama_port")
		throw Error("LLM boot state has no Ollama port.")
	if !LLM_Option_TryNormalizeOllamaPort(
			MenuState["ollama_port"], &NormalizedPort)
		throw Error("LLM boot state contains an invalid Ollama port.")
	if !HasMethod(SetPortFn, "Call")
		SetPortFn := LLM_Ollama_SetPort
	Result := SetPortFn.Call(NormalizedPort)
	if !(Result is Integer) || Result != 1
		throw Error("The Ollama client refused the validated boot port "
			. NormalizedPort . ".")
	MenuState["ollama_port"] := NormalizedPort
	return true
}

_LLM_Menu_ShouldScheduleInitialBackendLifecycle(FirstRestore, MenuState) {
	return FirstRestore && MenuState is Map
		&& MenuState.Get("enabled", false)
}

/**
 * Bootstraps the tray menu and starts the LLM bridge if auto-start is enabled.
 * @param {Map} saved_opts - Persisted settings loaded from INI/registry.
 * @param {Boolean} ActivateRuntime - False while rendering before input registration.
 */
LLM_Menu_Init(saved_opts := Map(), ActivateRuntime := true) {
	global _LLM_Menu, _LLM_Menu_Handle, _LLM_Menu_InTray, DRIVER_BASELINE_PRIORITY_CLASS
	global _LLM_Menu_Loaded

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
	_LLM_Menu_ApplyOllamaPortAtBoot(_LLM_Menu)

	; Auto-correct legacy raw-tag configs (e.g. qwen2.5:3b) before the first
	; bootstrap / bridge start so predictions do not silently fail.
	if (_LLM_Menu["backend"] == "ollama")
		LLM_Menu_EnsureModelReady()

	; Restore persisted remote API entries (lives in api_entries.json next to
	; the main config.toml — kept separate because the array-of-maps shape
	; would not survive the project's flat-TOML writer).
	_LLM_Menu_LoadApiEntries()

	; (Removed) First-run LLM onboarding TrayTip — the unsolicited
	; "Text predictions available" balloon was perceived as noise by users
	; who already know what the tray menu offers. Discovery now lives
	; purely in the menu's "IA" submenu; no opt-in nag at startup.

	; Build the IA submenu inline so the first tray already carries it: the
	; deferred boot population then finds a populated handle and stands down
	; instead of re-running this whole menu. Row construction itself measures
	; ~0 ms; the old ~1.6 s stall came from the then-synchronous model-tags
	; probe, since moved off the hot path (async installed-tags probe), so
	; the deferral's original reason is gone. On failure the empty parent
	; stays staged exactly as before and the boot projections recover it —
	; a failed inline build must never fail the boot.
	if !_LLM_Menu_InTray {
		; initMenu may be constructing a detached replacement tree. Record the
		; root insertion in that transaction instead of exposing a half-built
		; tray while the rest of the menu is rendered.
		try {
			_IaSub := LLM_Menu_BuildSubmenu()
			_LLM_Menu_Handle := _IaSub
			TrayMenuStage_AddFeature(t("menu.llm.title"), _IaSub)
			MenuDispatcher_PruneMenu(_IaSub)
			if _LLM_Menu["enabled"]
				TrayMenuStage_Check(t("menu.llm.title"))
			_LLM_Menu_InTray := true
			BootProfile_Mark("MENU/initMenu: LLM IA submenu built inline")
		} catch as _IaErr {
			try LoggerError("LLM",
				"Inline IA submenu build failed, deferred population will recover: {1}.",
				_IaErr.Message)
			TrayMenuStage_AddFeature(t("menu.llm.title"), _LLM_Menu_Handle)
		}
	} else if IsObject(_TrayMenuStage) {
		; A full root replacement removed the previous IA parent entry. The
		; persistent submenu remains valid, but it must be attached to this new
		; staged root even though it was already in the retired tray.
		TrayMenuStage_AddFeature(t("menu.llm.title"), _LLM_Menu_Handle)
	}

	; Bootstrap the selected backend silently on reload when the feature was enabled.
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
	_LLM_Menu_Loaded := true
	if ActivateRuntime
		LLM_Menu_ActivateRuntime()
}

/** Activates restored AI state after the input hotkey variants exist. */
LLM_Menu_ActivateRuntime(ActivateHotkeysFn := 0, ScheduleBackendFn := 0, HealthTimerFn := 0,
		Attempt := 1) {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Menu_RuntimeActivated
	global LLM_HEALTH_PROBE_INTERVAL_MS
	global _MenuStartupCommands, _DriverReady
	if !_LLM_Menu_Loaded
		throw Error("AI runtime activation requires restored menu state")
	if _LLM_Menu_RuntimeActivated
		return false
	Activate := HasMethod(ActivateHotkeysFn, "Call") ? ActivateHotkeysFn : _LLM_Menu_RequireFirstRestoreHotkeys
	try Activate.Call(true)
	catch TrayRootRetryPendingError as Err {
		if Attempt >= LLM_MENU_DEFERRED_HOTKEY_ATTEMPTS
			throw Error("AI runtime activation exhausted its bounded retries: " . Err.Message)
		SetTimer(LLM_Menu_ActivateRuntime.Bind(ActivateHotkeysFn, ScheduleBackendFn,
			HealthTimerFn, Attempt + 1), -LLM_MENU_DEFERRED_HOTKEY_RETRY_MS)
		try LoggerWarn("LLM", "AI runtime activation retained for bounded retry {1}: {2}.",
			Attempt + 1, Err.Message)
		return false
	}
	ScheduleBackend := HasMethod(ScheduleBackendFn, "Call") ? ScheduleBackendFn : LLM_Menu_ScheduleBackendLifecycle
	if _LLM_Menu_ShouldScheduleInitialBackendLifecycle(true, _LLM_Menu)
		ScheduleBackend.Call(false)
	HealthTimer := HasMethod(HealthTimerFn, "Call") ? HealthTimerFn : SetTimer
	HealthTimer.Call(_LLM_Menu_FireHealthProbe, LLM_HEALTH_PROBE_INTERVAL_MS)
	_LLM_Menu_RuntimeActivated := true
	LLM_Menu_LocalServersInit()
	if Attempt > 1 && IsSet(_DriverReady) && _DriverReady
			&& IsSet(_MenuStartupCommands) && _MenuStartupCommands is MenuStartupCommands
		_MenuStartupCommands.NotifyReady()
	if !HasMethod(HealthTimerFn, "Call") {
		_LLM_Menu_FireHealthProbe(true)
		_LLM_Menu_FireInstalledTagsProbe()
	}
	try LoggerInfo("LLM", "Restored AI menu state activated after input registration.")
	return true
}
