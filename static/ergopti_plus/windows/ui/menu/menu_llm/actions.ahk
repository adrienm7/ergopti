; ui/menu/menu_llm/actions.ahk

; ==============================================================================
; MODULE: LLM Tray — Action Handlers
; DESCRIPTION:
; Owns every click handler, toggle, setter, and lifecycle callback that backs
; the tray menu. Covers the main enable/disable toggle, the boolean toggles
; for granular settings, the typed setters (backend / model / profile / N /
; indent), the Ollama install bootstrap path, the health probe scheduler,
; the app exclusion picker integration, and the deps-ready / deps-failed
; lifecycle callbacks fired by the install pipeline. Also hosts the
; ``Ctrl+Alt+Shift+I`` debug hotkey that bypasses the tray menu to trigger
; an install directly.
;
; FEATURES & RATIONALE:
; 1. SaveConfig guard: ``LLM_Menu_SaveConfig`` is no-op until
;    ``_SaveFullConfigReady`` flips true — prevents the boot pipeline from
;    writing back an incomplete tray state before every module has reported
;    in.
; 2. Async health probe: ``_LLM_Menu_FireHealthProbe`` is throttled (one
;    probe per 3 s) so opening the menu twice in quick succession doesn't
;    fire two redundant pings.
; 3. Flip-guard rebuild: ``_LLM_Menu_OnHealthProbeDone`` only rebuilds when
;    the status actually flipped — avoids an infinite rebuild loop when the
;    backend stays stable.
; 4. SetModel warmup: switching model pre-loads the new tag into Ollama's
;    GPU cache so the first real prediction skips the cold-start penalty.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Toggle + Bootstrap Handlers =======
; ==============================================
; ==============================================

/**
 * Click handler for the ``⚠️ Ollama not installed`` warning row in the
 * tray menu. Forces a visible install attempt (show_ui=true). Logs the
 * click immediately so we can diagnose "I clicked but nothing happened"
 * reports — if this line is missing from the log, the click never
 * reached the handler at all (menu binding issue); if it's present but
 * BootstrapOllama isn't, the handoff dropped somewhere downstream.
 */
_LLM_Menu_OnWarningInstallClick(ItemName := "", ItemPos := 0, MenuObj := 0) {
	; Variadic-friendly signature so AHK's menu callback contract works
	; whether we're bound directly or via a fat-arrow wrapper. AHK calls
	; menu callbacks as ``fn(name, pos, menu)`` — if those args weren't
	; accepted the call threw immediately and the user saw nothing.
	LoggerInfo("LLM", "Warning row clicked — forcing visible install.")
	; Immediate, hard-to-miss visual confirmation that the click reached
	; AHK. If the user clicks the row and DOESN'T see this TrayTip pop,
	; we know the menu callback never fired — the bug is upstream of
	; this function (binding broken, menu not bound to A_TrayMenu,
	; AHK message loop saturated). Either way the answer is in the
	; TrayTip's presence, not in a buried log line.
	try TrayTip(t("llm.deps.tray_title"), t("llm.deps.install_launching"), 0x1)
	try {
		LLM_Menu_BootstrapOllama(true)
	} catch as err {
		LoggerError("LLM", "Bootstrap raised: " err.Message ".")
		try TrayTip(t("llm.deps.tray_title"), t("common.error_prefix") . err.Message, 0x3)
	}
}

; Debug hotkey: Ctrl+Alt+Shift+I directly fires the install bootstrap.
; Useful when the tray menu binding is suspect — pressing the hotkey
; bypasses the menu entirely. Always armed (no #HotIf) so the user
; can rescue an LLM in a broken state without re-toggling anything.
^!+i:: {
	LoggerInfo("LLM", "Debug hotkey Ctrl+Alt+Shift+I — direct install trigger.")
	try TrayTip(t("llm.deps.tray_title"), t("llm.deps.install_launching_hotkey"), 0x1)
	try LLM_Menu_BootstrapOllama(true)
}

LLM_Menu_OnToggle(*) {
	static _Toggling := false
	if _Toggling
		return
	_Toggling := true
	try {
		global _LLM_Menu
		_LLM_Menu["enabled"] := !_LLM_Menu["enabled"]
		LoggerInfo("LLM", "Toggle clicked — enabled: " (_LLM_Menu["enabled"] ? "true" : "false") ".")
		LLM_Menu_SaveConfig()
		LLM_Menu_Build()
		if _LLM_Menu["enabled"] {
			; Re-arm the health probe timer so the dot updates promptly
			; after re-enabling without waiting for the next 10 s tick
			SetTimer(_LLM_Menu_FireHealthProbe, 10000)
			LLM_Menu_EnsureModelReady()
			SetTimer(() => LLM_Menu_BootstrapOllama(true), -1)
		} else {
			; Cancel the health probe timer — no point pinging a disabled feature
			SetTimer(_LLM_Menu_FireHealthProbe, 0)
			; OFF flow — kill any in-flight Ollama install AND close the
			; WebView so the user's Cancel intent reaches every layer.
			; Without these, toggling OFF mid-install would leave the
			; hidden powershell.exe running and the install window open.
			try LLM_Deps_Cancel()
			try OllamaWV_Close()
			try LLM_OllamaCancelWarmupRetry()
			LLM_Bridge_Stop()
		}
	} finally {
		_Toggling := false
	}
}

/**
 * Persists the current LLM tray state to the shared config TOML.
 * (_LLM_Menu_SyncToFeatures lives in persist.ahk, included by ui/menu/menu_llm.ahk before this file.)
 */
LLM_Menu_SaveConfig() {
	global _SaveFullConfigReady
	if IsSet(_SaveFullConfigReady) && _SaveFullConfigReady {
		_LLM_Menu_SyncToFeatures()
		SaveFullConfig()
	}
}

LLM_Menu_OnInstantToggle(*) {
	global _LLM_Menu
	_LLM_Menu["instant_on_word_end"] := !_LLM_Menu["instant_on_word_end"]
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

/**
 * Generic boolean toggle for all simple on/off settings.
 * @param {string} key - The _LLM_Menu key to flip.
 */
LLM_Menu_ToggleBool(key) {
	global _LLM_Menu
	_LLM_Menu[key] := !_LLM_Menu[key]
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

/**
 * Triggers the Ollama deps checker.
 * @param {boolean} show_ui - True when the user explicitly clicked the toggle.
 */
LLM_Menu_BootstrapOllama(show_ui := true) {
	global _LLM_Menu
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		LoggerDebug("LLM", "BootstrapOllama deferred while suspended.")
		return
	}
	_LLM_Menu["bootstrap_pending"] := false
	LoggerInfo("LLM", "BootstrapOllama fired — deps state: " LLM_Deps_GetState() " show_ui=" (show_ui ? "true" : "false") ".")
	if LLM_Deps_IsReady() {
		LoggerInfo("LLM", "Ollama already ready — starting bridge directly.")
		LLM_Menu_OnDepsReady()
		return
	}
	LoggerInfo("LLM", "Ollama not ready — launching CheckAndInstall…")
	LLM_Deps_CheckAndInstall(
		_LLM_Menu["model"],
		(*) => LLM_Menu_OnDepsReady(),
		(msg) => LLM_Menu_OnDepsFailed(msg),
		show_ui
	)
}





; =====================================
; ==================================
; ======= 2/ Setter Handlers =======
; ==================================
; =====================================

LLM_Menu_SetBackend(id) {
	global _LLM_Menu
	_LLM_Menu["backend"] := id
	LLM_Menu_SaveConfig()
	; Every sibling setter (SetModel, SetProfile, SetN, SetIndent) re-inits the
	; live engine; this one was the sole exception. Without it the engine kept
	; dispatching to the stale backend until some other setter incidentally
	; called Init, and LLM_Engine_Init's own "stop in-flight generation when
	; the backend changes" safety net never triggered on a backend switch (F25).
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

LLM_Menu_SetModel(tag) {
	global _LLM_Menu
	_LLM_Menu["model"] := tag
	; Honour the auto-detect toggle BEFORE saving so the new profile id
	; lands in the same config write — keeps the on-disk state consistent
	; whatever path the user took to switch model.
	LLM_Menu_AutoApplyProfileForModel()
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	; Pre-load the new model into Ollama's GPU cache asynchronously so the
	; first real prediction skips the cold-start penalty. No-op for the
	; remote API backend — there's no local server to warm.
	if (_LLM_Menu["backend"] == "ollama") {
		global _LLM_Ollama_IsReady
		_LLM_Ollama_IsReady := false
		try LLM_OllamaScheduleWarmupRetry(tag)
	}
	LLM_Menu_Build()
}

/**
 * Fires an async backend health probe and stashes the result so the next
 * menu rebuild paints the dot accordingly. Mirrors the HS
 * ``probe_llm_health`` helper — fire-and-forget, paint on the next pass.
 */
; (Removed) ``_LLM_Menu_MaybeShowOnboarding`` — used to fire a tray balloon
; on first launch telling the user "Text predictions available". The
; notification was perceived as noise; users prefer to discover the LLM
; menu themselves rather than be solicited at startup. The
; ``menu.llm.onboarding_*`` locale keys it consumed have been deleted from
; every locale.

_LLM_Menu_FireHealthProbe() {
	global _LLM_Menu
	; Pause invariant: SetTimer callbacks bypass native Suspend, so this 10 s
	; health tick keeps pinging Ollama (and can trigger a full tray rebuild)
	; while the user believes the driver is fully paused. Mirror the guard used
	; in hotstring_prefix_watcher.ahk / tooltip.ahk / keylogger so the probe is
	; inert during suspend; the next unpaused tick refreshes the dot.
	if A_IsSuspended
		return
	; Only probe Ollama for now. The API backend has its own readiness path
	; (the per-entry ping in api_remote.ahk) and the user-facing health dot
	; for a remote provider depends on the same probe, which we can layer
	; on in a follow-up without touching this scaffolding.
	if (_LLM_Menu["backend"] != "ollama")
		return
	if !_LLM_Menu["enabled"]
		return
	; Throttle to one probe every 3 seconds. Opening the tray menu fires a
	; rebuild which calls this helper; without the throttle the user
	; opening the menu twice in 100 ms would fire two redundant pings.
	now := A_TickCount
	last := _LLM_Menu.Has("last_health_probe_tick") ? _LLM_Menu["last_health_probe_tick"] : 0
	if (last > 0 and (now - last) < 3000)
		return
	_LLM_Menu["last_health_probe_tick"] := now
	try {
		LLM_OllamaIsRunning_Async((reachable) => _LLM_Menu_OnHealthProbeDone(reachable))
	}
}

_LLM_Menu_OnHealthProbeDone(reachable) {
	global _LLM_Menu
	prev := _LLM_Menu.Has("last_health_status") ? _LLM_Menu["last_health_status"] : ""
	new_status := reachable ? "ok" : "ko"
	_LLM_Menu["last_health_status"] := new_status
	; Only repaint when the status actually flipped — avoids an infinite
	; rebuild loop and keeps the menu stable when the user is not staring
	; at it. Also skip the rebuild while suspended: a probe fired just before
	; Pause could still land here and churn the tray menu, violating the
	; "pause silences everything" invariant. The stashed status above still
	; updates so the next unpaused build paints the correct dot.
	if (prev != new_status and !A_IsSuspended)
		LLM_Menu_Build()
}

/**
 * Fires an async installed-models probe and stashes the result in the shared
 * models cache so the next rebuild paints the green install dots. The exact mirror
 * of _LLM_Menu_FireHealthProbe, but for GET /api/tags instead of the reachability
 * ping: fire-and-forget, paint on the next pass. The blocking list probe used to
 * run inline per catalogue row at build time and froze the keyboard thread for up
 * to ~20 s on a cold daemon — this moves it off the hot path entirely.
 */
_LLM_Menu_FireInstalledTagsProbe() {
	global _LLM_Menu, _LLM_InstalledTagsCacheAt, LLM_INSTALLED_CACHE_TTL_MS
	; Same Pause invariant as the health probe: SetTimer-driven rebuilds bypass
	; native Suspend, so a probe firing while paused could repaint the tray.
	if A_IsSuspended
		return
	if (_LLM_Menu["backend"] != "ollama")
		return
	; The install dots only mean something once Ollama is confirmed reachable —
	; mirrors the menu's own deps_ready gate on the per-row probe. When the daemon
	; is down the async request would just time out with nothing to paint.
	if !(IsSet(LLM_Deps_IsReady) and LLM_Deps_IsReady())
		return
	; Throttle on the cache age (the same TTL the blocking path used) so repeated
	; menu opens / rebuilds don't re-query the daemon every time.
	now := A_TickCount
	if (_LLM_InstalledTagsCacheAt > 0 and (now - _LLM_InstalledTagsCacheAt) < LLM_INSTALLED_CACHE_TTL_MS)
		return
	try LLM_OllamaListModels_Async((tags) => _LLM_Menu_OnInstalledTagsProbeDone(tags))
}

_LLM_Menu_OnInstalledTagsProbeDone(tags) {
	prev := _LLM_GetInstalledTagsCached()
	LLM_SetInstalledTagsCache(tags)
	; Repaint only when the installed SET actually changed (mirrors the health dot's
	; flip-guard) and never while suspended — so a probe landing mid-build doesn't
	; churn the tray, and the green dots appear a moment after the daemon answers.
	; The next rebuild's probe sees a fresh cache and skips, so there is no loop.
	if (_LLM_InstalledTagsListChanged(prev, IsSet(tags) ? tags : []) and !A_IsSuspended)
		LLM_Menu_Build()
}

LLM_Menu_SetProfile(id) {
	global _LLM_Menu
	; If the user picks a profile manually while auto-detection is on, they
	; clearly want a non-default choice — turn auto off so the next model
	; switch doesn't silently overwrite their pick. The recommended profile
	; for the current model is still computed live by the auto-detect
	; helper, so flipping the toggle back on later re-applies it.
	recommended := LLM_RecommendProfileForModel(_LLM_Menu["model"])
	if (_LLM_Menu["auto_profile_for_model"] and recommended != "" and id != recommended) {
		_LLM_Menu["auto_profile_for_model"] := false
	}
	_LLM_Menu["profile_id"] := id
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

LLM_Menu_SetN(n) {
	global _LLM_Menu
	_LLM_Menu["n_predictions"] := n
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

LLM_Menu_SetIndent(lvl) {
	global _LLM_Menu
	_LLM_Menu["pred_indent"] := lvl
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}





; ==========================================
; =======================================
; ======= 3/ App Exclusion Picker =======
; =======================================
; ==========================================

/**
 * Opens the shared AppPicker_Show() GUI so the user can select processes
 * to exclude from LLM predictions. Reuses the same picker used by Metrics.
 */
LLM_Menu_OpenAppPicker() {
	global _LLM_Menu
	AppPicker_Show(Map(
		"title",    t("menu.llm.exclude_from_ai"),
		"prompt",   t("dialog.llm.exclude_prompt"),
		"ok_label", t("dialog.llm.exclude_ok"),
		"initial",  _LLM_Menu["disabled_apps"],
		"on_save",  LLM_Menu_OnAppPickerSave
	))
}

LLM_Menu_OnAppPickerSave(selected) {
	global _LLM_Menu
	_LLM_Menu["disabled_apps"] := selected
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}





; ============================
; =======================
; ======= 4/ Misc =======
; =======================
; ============================

LLM_Menu_OnAbout(*) {
	MsgBox(t("menu.llm.about_body"), t("menu.llm.title"))
}

/**
 * Starts the LLM bridge with the current tray settings.
 */
/**
 * Starts the bridge once PrefixWatcher's InputHook is alive. Ollama bootstrap
 * can finish before HotstringPrefixWatcherInit — starting early left the bridge
 * subscribed to HookDispatcher while keystrokes only reached PrefixWatcher.
 */
LLM_Menu_TryStartBridge() {
	global _LLM_Menu
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return
	}
	if !_LLM_Menu["enabled"] or !LLM_Deps_IsReady()
		return
	_LLM_Menu["bridge_pending"] := false
	LLM_Menu_StartBridge()
	if (IsSet(_PrefixInputHook) && _PrefixInputHook && IsSet(LLM_Bridge_OnPrefixWatcherReady))
		LLM_Bridge_OnPrefixWatcherReady()
}

LLM_Menu_StartBridge() {
	global _LLM_Menu
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return
	}
	LLM_Menu_EnsureModelReady()
	LLM_Bridge_Start(LLM_Menu_BuildOpts())
	tag := LLM_ResolveOllamaTag(_LLM_Menu["model"])
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		LoggerInfo("LLM", "Bridge started — model: {1}, tag: {2} (PrefixWatcher hook).", _LLM_Menu["model"], tag)
	else
		LoggerInfo("LLM", "Bridge started — model: {1}, tag: {2} (HookDispatcher until PrefixWatcher).", _LLM_Menu["model"], tag)
}

/**
 * Ensures _LLM_Menu["model"] points at a locally installed model before the
 * engine fires requests. Legacy configs stored raw Ollama tags (e.g.
 * ``qwen2.5:3b``) that are not installed — auto-switch to the best match.
 */
LLM_Menu_EnsureModelReady() {
	global _LLM_Menu
	if (_LLM_Menu["backend"] != "ollama")
		return
	; Never run the blocking installed-models probe (GET /api/tags, up to a 5 s
	; WinHTTP timeout) unless the Ollama daemon is confirmed reachable. At boot
	; the deps state is "pending", so a dead-port connect to localhost:11434
	; froze the synchronous menu build for ~2 s — the single largest chunk of
	; startup time — even with the LLM feature switched off. The model
	; auto-correct still runs once the daemon comes up: the deps-ready
	; bridge-start path (LLM_Menu_StartBridge) calls us again with
	; LLM_Deps_IsReady() == true, where the same probe returns in milliseconds.
	if !LLM_Deps_IsReady()
		return
	; Deps are confirmed up — refresh the installed-tags cache with ONE synchronous
	; probe so the model auto-correct below reads a trustworthy snapshot. This is the
	; only sanctioned blocking /api/tags call (off the keyboard hot path, gated on
	; deps-ready above); the tray build itself stays non-blocking via the async probe.
	_LLM_WarmInstalledTagsSync()
	model := _LLM_Menu["model"]
	if (model == "")
		model := _LLM_DefaultFor("llm_model", _LLM_LOCAL_DEFAULTS["llm_model"])
	if LLM_IsModelInstalled(model) {
		if (_LLM_Menu["model"] == "")
			_LLM_Menu["model"] := model
		return
	}
	replacement := LLM_PickBestInstalledDisplayName()
	if (replacement == "")
		return
	old_tag := _LLM_ResolveOllamaTagCore(model, false)
	new_tag := _LLM_ResolveOllamaTagCore(replacement, false)
	try LoggerWarn("LLM",
		"Model '{1}' (tag '{2}') is not installed — switching to '{3}' (tag '{4}').",
		model, old_tag, replacement, new_tag)
	_LLM_Menu["model"] := replacement
	LLM_Menu_SaveConfig()
}

/**
 * Converts the current tray state into a Map suitable for LLM_Engine_Init().
 * @returns {Map} Options map.
 */
LLM_Menu_BuildOpts() {
	global _LLM_Menu
	return Map(
		"model",                   _LLM_Menu["model"],
		"profile_id",              _LLM_Menu["profile_id"],
		"user_profiles",           _LLM_Menu["user_profiles"],
		"n_predictions",           _LLM_Menu["n_predictions"],
		"min_words",               _LLM_Menu["min_words"],
		"max_words",               _LLM_Menu["max_words"],
		"language",                _LLM_Menu["language"],
		"debounce_ms",             _LLM_Menu["debounce_ms"],
		"ctx_chars",               _LLM_Menu["ctx_chars"],
		"temperature",             _LLM_Menu["temperature"],
		"instant_on_word_end",     _LLM_Menu["instant_on_word_end"],
		"after_hotstring",         _LLM_Menu["after_hotstring"],
		"reset_on_nav",            _LLM_Menu["reset_on_nav"],
		"disable_url_bars",        _LLM_Menu["disable_url_bars"],
		"disable_password_fields", _LLM_Menu["disable_password_fields"],
		"disabled_apps",           _LLM_Menu["disabled_apps"],
		"show_info_bar",           _LLM_Menu["show_info_bar"],
		"streaming",               _LLM_Menu["streaming"],
		"show_all_at_once",        _LLM_Menu["show_all_at_once"],
		"pred_indent",             _LLM_Menu["pred_indent"],
		"auto_raise_temp",         _LLM_Menu["auto_raise_temp"],
		"nav_modifiers",           _LLM_Menu["nav_modifiers"],
		"val_modifiers",           _LLM_Menu["val_modifiers"],
		"backend",                 _LLM_Menu["backend"],
		"api_entries",             _LLM_Menu["api_entries"],
		"api_entry_id",            _LLM_Menu["api_entry_id"],
		"inline_autotype",         _LLM_Menu["inline_autotype"],
		"app_profile_overrides",   _LLM_Menu["app_profile_overrides"]
	)
}





; ==============================================
; =============================================
; ======= 5/ Ollama Lifecycle Callbacks =======
; =============================================
; ==============================================

/**
 * Called by the deps checker when Ollama is confirmed ready.
 */
LLM_Menu_OnDepsReady() {
	global _LLM_Menu
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		LoggerDebug("LLM", "Deps-ready callback deferred while suspended.")
		return
	}
	LoggerInfo("LLM", "Ollama ready — LLM enabled: {1}.",
		_LLM_Menu["enabled"] ? "true" : "false")
	LLM_Menu_Build()
	if _LLM_Menu["enabled"] {
		LLM_Menu_TryStartBridge()
		; Prime the current model so the first user keystroke does not
		; pay the cold-start penalty. Async — no blocking on Build.
		if (_LLM_Menu["backend"] == "ollama" and _LLM_Menu["model"] != "") {
			global _LLM_Ollama_IsReady
			_LLM_Ollama_IsReady := false
			try LLM_OllamaScheduleWarmupRetry(_LLM_Menu["model"])
		} else {
			global _LLM_Ollama_IsReady
			_LLM_Ollama_IsReady := true
		}
	}
}

/**
 * Called by the deps checker on permanent failure.
 * @param {string} msg - Failure reason.
 */
LLM_Menu_OnDepsFailed(msg) {
	global _LLM_Menu
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		LoggerDebug("LLM", "Deps-failed callback deferred while suspended.")
		return
	}
	_LLM_Menu["enabled"] := false
	LLM_Menu_Build()
}

; Replays the suspended lifecycle work from the resume watchdog, after native
; Suspend has released hotkeys. The one-shot avoids performing dependency work
; inside the watchdog callback itself.
LLM_Menu_OnResume() {
	global _LLM_Menu
	if A_IsSuspended or !_LLM_Menu["bootstrap_pending"]
		return
	_LLM_Menu["bootstrap_pending"] := false
	if !_LLM_Menu["enabled"]
		return
	SetTimer(() => LLM_Menu_BootstrapOllama(false), -1)
}
