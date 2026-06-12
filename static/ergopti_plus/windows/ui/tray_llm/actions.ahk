; ui/tray_llm/actions.ahk

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
; 1. SaveConfig guard: ``LLM_Tray_SaveConfig`` is no-op until
;    ``_SaveFullConfigReady`` flips true — prevents the boot pipeline from
;    writing back an incomplete tray state before every module has reported
;    in.
; 2. Async health probe: ``_LLM_Tray_FireHealthProbe`` is throttled (one
;    probe per 3 s) so opening the menu twice in quick succession doesn't
;    fire two redundant pings.
; 3. Flip-guard rebuild: ``_LLM_Tray_OnHealthProbeDone`` only rebuilds when
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
_LLM_Tray_OnWarningInstallClick(ItemName := "", ItemPos := 0, MenuObj := 0) {
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
	try TrayTip("Ergopti — IA", "Lancement de l'installation Ollama…", 0x1)
	try {
		LLM_Tray_BootstrapOllama(true)
	} catch as err {
		LoggerError("LLM", "Bootstrap raised: " err.Message ".")
		try TrayTip("Ergopti — IA", "Erreur : " err.Message, 0x3)
	}
}

; Debug hotkey: Ctrl+Alt+Shift+I directly fires the install bootstrap.
; Useful when the tray menu binding is suspect — pressing the hotkey
; bypasses the menu entirely. Always armed (no #HotIf) so the user
; can rescue an LLM in a broken state without re-toggling anything.
^!+i:: {
	LoggerInfo("LLM", "Debug hotkey Ctrl+Alt+Shift+I — direct install trigger.")
	try TrayTip("Ergopti — IA", "Installation Ollama (déclenchée par raccourci)…", 0x1)
	try LLM_Tray_BootstrapOllama(true)
}

LLM_Tray_OnToggle(*) {
	global _LLM_Tray
	_LLM_Tray["enabled"] := !_LLM_Tray["enabled"]
	LoggerInfo("LLM", "Toggle clicked — enabled: " (_LLM_Tray["enabled"] ? "true" : "false") ".")
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
	if _LLM_Tray["enabled"] {
		LLM_Tray_EnsureModelReady()
		SetTimer(() => LLM_Tray_BootstrapOllama(true), -1)
	} else {
		; OFF flow — kill any in-flight Ollama install AND close the
		; WebView so the user's Cancel intent reaches every layer.
		; Without these, toggling OFF mid-install would leave the
		; hidden powershell.exe running and the install window open.
		try LLM_Deps_Cancel()
		try OllamaWV_Close()
		try LLM_OllamaCancelWarmupRetry()
		LLM_Bridge_Stop()
	}
}

/**
 * Persists the current LLM tray state to the shared config TOML.
 * (_LLM_Tray_SyncToFeatures lives in persist.ahk, included by ui/tray_llm.ahk before this file.)
 */
LLM_Tray_SaveConfig() {
	global _SaveFullConfigReady
	if IsSet(_SaveFullConfigReady) && _SaveFullConfigReady {
		_LLM_Tray_SyncToFeatures()
		SaveFullConfig()
	}
}

LLM_Tray_OnInstantToggle(*) {
	global _LLM_Tray
	_LLM_Tray["instant_on_word_end"] := !_LLM_Tray["instant_on_word_end"]
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

/**
 * Generic boolean toggle for all simple on/off settings.
 * @param {string} key - The _LLM_Tray key to flip.
 */
LLM_Tray_ToggleBool(key) {
	global _LLM_Tray
	_LLM_Tray[key] := !_LLM_Tray[key]
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}

/**
 * Triggers the Ollama deps checker.
 * @param {boolean} show_ui - True when the user explicitly clicked the toggle.
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





; =====================================
; ==================================
; ======= 2/ Setter Handlers =======
; ==================================
; =====================================

LLM_Tray_SetBackend(id) {
	global _LLM_Tray
	_LLM_Tray["backend"] := id
	LLM_Tray_SaveConfig()
	LLM_Tray_Build()
}

LLM_Tray_SetModel(tag) {
	global _LLM_Tray
	_LLM_Tray["model"] := tag
	; Honour the auto-detect toggle BEFORE saving so the new profile id
	; lands in the same config write — keeps the on-disk state consistent
	; whatever path the user took to switch model.
	LLM_Tray_AutoApplyProfileForModel()
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	; Pre-load the new model into Ollama's GPU cache asynchronously so the
	; first real prediction skips the cold-start penalty. No-op for the
	; remote API backend — there's no local server to warm.
	if (_LLM_Tray["backend"] == "ollama") {
		global _LLM_Ollama_IsReady
		_LLM_Ollama_IsReady := false
		try LLM_OllamaScheduleWarmupRetry(tag)
	}
	LLM_Tray_Build()
}

/**
 * Fires an async backend health probe and stashes the result so the next
 * menu rebuild paints the dot accordingly. Mirrors the HS
 * ``probe_llm_health`` helper — fire-and-forget, paint on the next pass.
 */
; (Removed) ``_LLM_Tray_MaybeShowOnboarding`` — used to fire a tray balloon
; on first launch telling the user "Text predictions available". The
; notification was perceived as noise; users prefer to discover the LLM
; menu themselves rather than be solicited at startup. The
; ``menu.llm.onboarding_*`` locale keys it consumed have been deleted from
; every locale.

_LLM_Tray_FireHealthProbe() {
	global _LLM_Tray
	; Only probe Ollama for now. The API backend has its own readiness path
	; (the per-entry ping in api_remote.ahk) and the user-facing health dot
	; for a remote provider depends on the same probe, which we can layer
	; on in a follow-up without touching this scaffolding.
	if (_LLM_Tray["backend"] != "ollama")
		return
	if !_LLM_Tray["enabled"]
		return
	; Throttle to one probe every 3 seconds. Opening the tray menu fires a
	; rebuild which calls this helper; without the throttle the user
	; opening the menu twice in 100 ms would fire two redundant pings.
	now := A_TickCount
	last := _LLM_Tray.Has("last_health_probe_tick") ? _LLM_Tray["last_health_probe_tick"] : 0
	if (last > 0 and (now - last) < 3000)
		return
	_LLM_Tray["last_health_probe_tick"] := now
	try {
		LLM_OllamaIsRunning_Async((reachable) => _LLM_Tray_OnHealthProbeDone(reachable))
	}
}

_LLM_Tray_OnHealthProbeDone(reachable) {
	global _LLM_Tray
	prev := _LLM_Tray.Has("last_health_status") ? _LLM_Tray["last_health_status"] : ""
	new_status := reachable ? "ok" : "ko"
	_LLM_Tray["last_health_status"] := new_status
	; Only repaint when the status actually flipped — avoids an infinite
	; rebuild loop and keeps the menu stable when the user is not staring
	; at it.
	if (prev != new_status)
		LLM_Tray_Build()
}

LLM_Tray_SetProfile(id) {
	global _LLM_Tray
	; If the user picks a profile manually while auto-detection is on, they
	; clearly want a non-default choice — turn auto off so the next model
	; switch doesn't silently overwrite their pick. The recommended profile
	; for the current model is still computed live by the auto-detect
	; helper, so flipping the toggle back on later re-applies it.
	recommended := LLM_RecommendProfileForModel(_LLM_Tray["model"])
	if (_LLM_Tray["auto_profile_for_model"] and recommended != "" and id != recommended) {
		_LLM_Tray["auto_profile_for_model"] := false
	}
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

LLM_Tray_SetIndent(lvl) {
	global _LLM_Tray
	_LLM_Tray["pred_indent"] := lvl
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
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
LLM_Tray_OpenAppPicker() {
	global _LLM_Tray
	AppPicker_Show(Map(
		"title",    t("menu.llm.exclude_from_ai"),
		"prompt",   t("dialog.llm.exclude_prompt"),
		"ok_label", t("dialog.llm.exclude_ok"),
		"initial",  _LLM_Tray["disabled_apps"],
		"on_save",  LLM_Tray_OnAppPickerSave
	))
}

LLM_Tray_OnAppPickerSave(selected) {
	global _LLM_Tray
	_LLM_Tray["disabled_apps"] := selected
	LLM_Tray_SaveConfig()
	LLM_Engine_Init(LLM_Tray_BuildOpts())
	LLM_Tray_Build()
}





; ============================
; =======================
; ======= 4/ Misc =======
; =======================
; ============================

LLM_Tray_OnAbout(*) {
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
LLM_Tray_TryStartBridge() {
	global _LLM_Tray
	if !_LLM_Tray["enabled"] or !LLM_Deps_IsReady()
		return
	_LLM_Tray["bridge_pending"] := false
	LLM_Tray_StartBridge()
	if (IsSet(_PrefixInputHook) && _PrefixInputHook && IsSet(LLM_Bridge_OnPrefixWatcherReady))
		LLM_Bridge_OnPrefixWatcherReady()
}

LLM_Tray_StartBridge() {
	global _LLM_Tray
	LLM_Tray_EnsureModelReady()
	LLM_Bridge_Start(LLM_Tray_BuildOpts())
	tag := LLM_ResolveOllamaTag(_LLM_Tray["model"])
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		LoggerInfo("LLM", "Bridge started — model: {1}, tag: {2} (PrefixWatcher hook).", _LLM_Tray["model"], tag)
	else
		LoggerInfo("LLM", "Bridge started — model: {1}, tag: {2} (HookDispatcher until PrefixWatcher).", _LLM_Tray["model"], tag)
}

/**
 * Ensures _LLM_Tray["model"] points at a locally installed model before the
 * engine fires requests. Legacy configs stored raw Ollama tags (e.g.
 * ``qwen2.5:3b``) that are not installed — auto-switch to the best match.
 */
LLM_Tray_EnsureModelReady() {
	global _LLM_Tray
	if (_LLM_Tray["backend"] != "ollama")
		return
	; Never run the blocking installed-models probe (GET /api/tags, up to a 5 s
	; WinHTTP timeout) unless the Ollama daemon is confirmed reachable. At boot
	; the deps state is "pending", so a dead-port connect to localhost:11434
	; froze the synchronous menu build for ~2 s — the single largest chunk of
	; startup time — even with the LLM feature switched off. The model
	; auto-correct still runs once the daemon comes up: the deps-ready
	; bridge-start path (LLM_Tray_StartBridge) calls us again with
	; LLM_Deps_IsReady() == true, where the same probe returns in milliseconds.
	if !LLM_Deps_IsReady()
		return
	model := _LLM_Tray["model"]
	if (model == "")
		model := _LLM_DefaultFor("llm_model", "Qwen3.5-0.8B")
	if LLM_IsModelInstalled(model) {
		if (_LLM_Tray["model"] == "")
			_LLM_Tray["model"] := model
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
	_LLM_Tray["model"] := replacement
	LLM_Tray_SaveConfig()
}

/**
 * Converts the current tray state into a Map suitable for LLM_Engine_Init().
 * @returns {Map} Options map.
 */
LLM_Tray_BuildOpts() {
	global _LLM_Tray
	return Map(
		"model",                   _LLM_Tray["model"],
		"profile_id",              _LLM_Tray["profile_id"],
		"user_profiles",           _LLM_Tray["user_profiles"],
		"n_predictions",           _LLM_Tray["n_predictions"],
		"min_words",               _LLM_Tray["min_words"],
		"max_words",               _LLM_Tray["max_words"],
		"language",                _LLM_Tray["language"],
		"debounce_ms",             _LLM_Tray["debounce_ms"],
		"ctx_chars",               _LLM_Tray["ctx_chars"],
		"temperature",             _LLM_Tray["temperature"],
		"instant_on_word_end",     _LLM_Tray["instant_on_word_end"],
		"after_hotstring",         _LLM_Tray["after_hotstring"],
		"reset_on_nav",            _LLM_Tray["reset_on_nav"],
		"disable_url_bars",        _LLM_Tray["disable_url_bars"],
		"disable_password_fields", _LLM_Tray["disable_password_fields"],
		"disabled_apps",           _LLM_Tray["disabled_apps"],
		"show_info_bar",           _LLM_Tray["show_info_bar"],
		"streaming",               _LLM_Tray["streaming"],
		"show_all_at_once",        _LLM_Tray["show_all_at_once"],
		"pred_indent",             _LLM_Tray["pred_indent"],
		"auto_raise_temp",         _LLM_Tray["auto_raise_temp"],
		"nav_modifiers",           _LLM_Tray["nav_modifiers"],
		"val_modifiers",           _LLM_Tray["val_modifiers"],
		"backend",                 _LLM_Tray["backend"],
		"api_entries",             _LLM_Tray["api_entries"],
		"api_entry_id",            _LLM_Tray["api_entry_id"],
		"inline_autotype",         _LLM_Tray["inline_autotype"],
		"app_profile_overrides",   _LLM_Tray["app_profile_overrides"]
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
LLM_Tray_OnDepsReady() {
	global _LLM_Tray
	LoggerInfo("LLM", "Ollama ready — LLM enabled: {1}.",
		_LLM_Tray["enabled"] ? "true" : "false")
	LLM_Tray_Build()
	if _LLM_Tray["enabled"] {
		LLM_Tray_TryStartBridge()
		; Prime the current model so the first user keystroke does not
		; pay the cold-start penalty. Async — no blocking on Build.
		if (_LLM_Tray["backend"] == "ollama" and _LLM_Tray["model"] != "") {
			global _LLM_Ollama_IsReady
			_LLM_Ollama_IsReady := false
			try LLM_OllamaScheduleWarmupRetry(_LLM_Tray["model"])
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
LLM_Tray_OnDepsFailed(msg) {
	global _LLM_Tray
	_LLM_Tray["enabled"] := false
	LLM_Tray_Build()
}
