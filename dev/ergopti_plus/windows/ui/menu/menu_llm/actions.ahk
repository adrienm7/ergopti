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
;    probe per LLM_HEALTH_PROBE_THROTTLE_MS) so opening the menu twice in
;    quick succession doesn't fire two redundant pings.
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
	; try-wrapped like every other call in this handler. The hotkey is
	; deliberately always armed (no #HotIf) so a broken LLM can be rescued, which
	; also means it is live during Bundle_Init's message-pumping RunWait — before
	; the logger's severity flags exist. A bare LoggerInfo there reads an unset
	; global, throws inside a hotkey thread while _DriverBootPhase is still
	; "starting", and the error net treats that as a fatal boot fault: pressing a
	; debug rescue hotkey killed the boot it was meant to rescue.
	try LoggerInfo("LLM", "Debug hotkey Ctrl+Alt+Shift+I — direct install trigger.")
	try TrayTip(t("llm.deps.tray_title"), t("llm.deps.install_launching_hotkey"), 0x1)
	try LLM_Menu_BootstrapOllama(true)
}

LLM_Menu_OnToggle(*) {
	static _Toggling := false
	if _Toggling
		return false
	_Toggling := true
	try {
		return LLM_Menu_CommitMutation("the LLM enabled-state change",
			(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "enabled"),
			_LLM_Menu_ApplyToggleCommitted)
	} finally {
		_Toggling := false
	}
}

_LLM_Menu_ApplyToggleCommitted(Candidate) {
	global LLM_HEALTH_PROBE_INTERVAL_MS
	LoggerInfo("LLM", "Toggle clicked — enabled: "
		. (Candidate["enabled"] ? "true" : "false") . ".")
	LLM_Menu_RequestBuild("toggle_committed")
	if Candidate["enabled"] {
		; Model readiness is checked by the deferred bootstrap after this global
		; barrier releases, so it cannot start a nested persistence transaction.
		SetTimer(_LLM_Menu_FireHealthProbe, LLM_HEALTH_PROBE_INTERVAL_MS)
		LLM_Menu_ScheduleBackendLifecycle(true)
	} else {
		SetTimer(_LLM_Menu_FireHealthProbe, 0)
		LLM_Menu_BackendLifecycleInvalidate(true)
		LLM_Bridge_Stop()
	}
	return true
}

/**
 * Persists the current LLM tray state to the shared config TOML.
 * (_LLM_Menu_SyncToFeatures lives in persist.ahk, included by ui/menu/menu_llm.ahk before this file.)
 *
 * A failed write is NOT silent. TOML_BatchWrite returns false without throwing
 * when the staging file cannot be opened or the atomic replace is refused, and
 * the LLM live toggles are the one family that never reaches a Reload: they
 * mutate _LLM_Menu in memory, re-init the engine and rebuild the menu in place.
 * So a failed persist left memory, engine and menu agreeing on a state that
 * existed nowhere on disk, and the next restart silently undid it. The bulk
 * togglers and the gesture/metrics toggles do not have this problem precisely
 * because they end in an unconditional Reload that re-reads the truth.
 *
 * Reload is therefore the recovery here too: the user sees their toggle revert,
 * which is honest, instead of a setting that quietly forgets itself overnight.
 *
 * @returns {Boolean} True when the state reached disk (or the save was deferred
 *                    because the driver is not ready yet).
 */
LLM_Menu_SaveConfig() {
	global _SaveFullConfigReady
	if !(IsSet(_SaveFullConfigReady) && _SaveFullConfigReady)
		return true
	_LLM_Menu_SyncToFeatures()
	global CONFIG_SAVE_OK, CONFIG_SAVE_DEFERRED
	global CONFIG_SAVE_RESOLVE_RELOAD, CONFIG_SAVE_RESOLVE_DEFERRED
	RequestedGeneration := 0
	SaveResult := SaveFullConfig(0, 0, true, 0, 0, &RequestedGeneration)
	if (SaveResult = CONFIG_SAVE_OK)
		return true
	if (SaveResult = CONFIG_SAVE_DEFERRED) {
		try LoggerInfo("LLM_Menu", "The LLM configuration save was deferred behind another config.toml transaction; a coalesced retry will persist the current live state.")
		return true
	}
	Resolution := _ConfigFullSaveResolveFailure(RequestedGeneration)
	if (Resolution = CONFIG_SAVE_RESOLVE_DEFERRED) {
		try LoggerWarn("LLM_Menu", "The failed LLM save could not discard an older accepted generation; the coalesced retry retains the current live state.")
		return true
	}
	if (Resolution = CONFIG_SAVE_RESOLVE_RELOAD) {
		try LoggerError("LLM_Menu", "The LLM settings could not be written to config.toml. Reloading so the menu, the engine and the file agree again — the exact failed generation was rejected rather than shown as saved.")
		ReloadAccepted := false
		try ReloadAccepted := ReloadPreservingSuspend()
		catch as Err
			try LoggerError("LLM_Menu", "Reload raised after the failed LLM save: {1}.", Err.Message)
		if !ReloadAccepted {
			; An OnExit gate kept this process alive, so disk authority was never
			; completed. Reopen only this exact generation and retry it; otherwise
			; every later setter would mutate RAM while the save coordinator stayed
			; permanently sealed behind the returned Reload.
			if _ConfigFullSaveResumeRejected(RequestedGeneration) {
				try LoggerWarn("LLM_Menu", "Reload was refused; the rejected LLM save was restored as a pending obligation and its retry was re-armed.")
				return true
			} else {
				try LoggerError("LLM_Menu", "Reload was refused and the exact LLM save could not be restored as a pending obligation.")
				try ConfigReportPersistenceFailure(
					"the LLM configuration save after a refused Reload")
			}
		}
		return false
	}
	try LoggerError("LLM_Menu", "The LLM settings could not be persisted or safely rejected because an older save remains pending and its retry could not be armed.")
	try ConfigReportPersistenceFailure("the LLM configuration save")
	return false
}

LLM_Menu_OnInstantToggle(*) {
	return LLM_Menu_CommitMutation("the instant-on-word-end setting",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate,
			"instant_on_word_end"), _LLM_Menu_ApplyStandardCommitted)
}

/**
 * Generic boolean toggle for all simple on/off settings.
 * @param {string} key - The _LLM_Menu key to flip.
 */
LLM_Menu_ToggleBool(key) {
	global _LLM_Menu
	if (key == "streaming"
			&& !LLM_EffectiveStreaming(_LLM_Menu["backend"], true))
		return false
	return LLM_Menu_CommitMutation("the LLM '" . key . "' setting",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, key),
		_LLM_Menu_ApplyStandardCommitted)
}





; ==================================
; ==================================
; ======= 2/ Setter Handlers =======
; ==================================
; ==================================

LLM_Menu_SetBackend(id) {
	return LLM_Menu_CommitMutation("the LLM backend selection",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "backend", id),
		_LLM_Menu_ApplyBackendCommitted)
}

_LLM_Menu_ApplyBackendCommitted(Candidate) {
	LLM_Menu_BackendLifecycleInvalidate(true)
	try LLM_Engine_StopGeneration()
	Candidate["streaming"] := LLM_EffectiveStreaming(
		Candidate["backend"], Candidate["streaming"])
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_RequestBuild("backend_committed")
	if Candidate["enabled"]
		LLM_Menu_ScheduleBackendLifecycle(false)
	return true
}

_LLM_Menu_ApplyApiEntriesCommitted(Candidate) {
	_LLM_Menu_ApplyStandardCommitted(Candidate)
	if Candidate["enabled"] && Candidate["backend"] == "api"
		LLM_Menu_ScheduleBackendLifecycle(false)
	return true
}

LLM_Menu_SetModel(tag) {
	return LLM_Menu_CommitMutation("the LLM model selection",
		(Candidate) => _LLM_Menu_SetModelCandidate(Candidate, tag),
		_LLM_Menu_ApplyModelCommitted)
}

_LLM_Menu_SetModelCandidate(Candidate, Tag) {
	if !_LLM_Menu_SetCandidateValue(Candidate, "model", Tag)
		return false
	LLM_Menu_AutoApplyProfileForModel(Candidate)
	return true
}

_LLM_Menu_ApplyModelCommitted(Candidate) {
	return LLM_Menu_ApplyModelLifecycleCommitted(Candidate,
		_LLM_Menu_ApplyModelRuntimeCommitted)
}

_LLM_Menu_ApplyModelRuntimeCommitted(Candidate) {
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_RequestBuild("model_committed")
	return true
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

; Force lets the tray-build path demand a refresh the idle gate cannot veto. It
; is surgically limited to that gate: every other guard below still applies, and
; the suspend guard deliberately sits ahead of it.
_LLM_Menu_FireHealthProbe(Force := false) {
	global _LLM_Menu, LLM_HEALTH_PROBE_IDLE_MAX_MS, LLM_HEALTH_PROBE_THROTTLE_MS
	; Edge trigger for the idle-gate log: an unattended machine must produce one
	; line when it goes quiet and one when it wakes, not one line per tick
	static _idle_gated := false
	; Pause invariant: SetTimer callbacks bypass native Suspend, so this 10 s
	; health tick keeps pinging Ollama (and can trigger a full tray rebuild)
	; while the user believes the driver is fully paused. Mirror the guard used
	; in hotstring_prefix_watcher.ahk / tooltip.ahk / keylogger so the probe is
	; inert during suspend; the next unpaused tick refreshes the dot. Force is
	; powerless here — a paused driver stays silent whoever asks.
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
	; Throttle to one probe per LLM_HEALTH_PROBE_THROTTLE_MS. Opening the tray menu
	; fires a rebuild which calls this helper; without the throttle the user
	; opening the menu twice in 100 ms would fire two redundant pings.
	now := A_TickCount
	last := _LLM_Menu.Has("last_health_probe_tick") ? _LLM_Menu["last_health_probe_tick"] : 0
	if (last > 0 and (now - last) < LLM_HEALTH_PROBE_THROTTLE_MS)
		return
	; Idle gate, kept LAST so the caller-supplied bypass reaches only this guard
	; and can never defeat the suspend, backend, enabled or throttle checks above.
	; That ordering is load-bearing: _LLM_Menu_OnHealthProbeDone rebuilds the menu
	; on a state flip, the rebuild re-enters here with Force, and only the
	; LLM_HEALTH_PROBE_THROTTLE_MS gap breaks the build → probe → flip → build loop.
	; Every tick that gets past this point spawns a curl.exe child (see
	; LLM_OllamaIsRunning_Async) plus its poll chain — 8640 a day on a machine
	; nobody is sitting at. The tick stamp below is deliberately NOT written on
	; the gated path, so the first tick after the user returns probes at once
	; instead of serving out a stale throttle window.
	if (!Force and A_TimeIdlePhysical > LLM_HEALTH_PROBE_IDLE_MAX_MS) {
		if !_idle_gated {
			_idle_gated := true
			LoggerDebug("LLM", "Health probe idle-gated — no physical input for {1} ms (ceiling {2} ms).", A_TimeIdlePhysical, LLM_HEALTH_PROBE_IDLE_MAX_MS)
		}
		return
	}
	if _idle_gated {
		_idle_gated := false
		LoggerDebug("LLM", "Health probe resumed — physical input detected again.")
	}
	_LLM_Menu["last_health_probe_tick"] := now
	Owner := _LLM_Menu_BeginOllamaAux("menu_health")
	try {
		LLM_OllamaIsRunning_Async(
			(reachable) => _LLM_Menu_OnHealthProbeDone(reachable, Owner), Owner)
	} catch {
		LLM_AuxFinish(Owner)
	}
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
	Owner := _LLM_Menu_BeginOllamaAux("menu_tags")
	try LLM_OllamaListModels_Async(
		(tags) => _LLM_Menu_OnInstalledTagsProbeDone(tags, Owner), Owner)
	catch
		LLM_AuxFinish(Owner)
}

LLM_Menu_SetProfile(id) {
	return LLM_Menu_CommitMutation("the LLM profile selection",
		(Candidate) => _LLM_Menu_SetProfileCandidate(Candidate, id),
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_SetProfileCandidate(Candidate, Id) {
	if !(Candidate is Map) || !(Id is String) || Id == ""
		return false
	CandidateIds := _LLM_Menu_ProfileCandidateIds(Candidate)
	if !(CandidateIds is Map) || !CandidateIds.Has(Id)
		return false
	; If the user picks a profile manually while auto-detection is on, they
	; clearly want a non-default choice — turn auto off so the next model
	; switch doesn't silently overwrite their pick. The recommended profile
	; for the current model is still computed live by the auto-detect
	; helper, so flipping the toggle back on later re-applies it.
	recommended := LLM_RecommendProfileForModel(Candidate["model"])
	if (Candidate["auto_profile_for_model"] and recommended != ""
			and Id != recommended) {
		Candidate["auto_profile_for_model"] := false
	}
	Candidate["profile_id"] := Id
	return true
}

LLM_Menu_SetN(n) {
	return LLM_Menu_CommitMutation("the LLM prediction-count setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"n_predictions", n), _LLM_Menu_ApplyStandardCommitted)
}

LLM_Menu_SetIndent(lvl) {
	return LLM_Menu_CommitMutation("the LLM indentation setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"pred_indent", lvl), _LLM_Menu_ApplyStandardCommitted)
}





; =======================================
; =======================================
; ======= 3/ App Exclusion Picker =======
; =======================================
; =======================================

/**
 * Opens the shared AppPicker_Show() GUI so the user can select processes
 * to exclude from LLM predictions. Reuses the same picker used by Metrics.
 */
LLM_Menu_OpenAppPicker() {
	global _LLM_Menu
	AppPicker_Show(Map(
		"owner",    "llm:disabled_apps",
		"title",    t("menu.llm.exclude_from_ai"),
		"prompt",   t("dialog.llm.exclude_prompt"),
		"ok_label", t("dialog.llm.exclude_ok"),
		"initial",  _LLM_Menu["disabled_apps"],
		"on_save",  LLM_Menu_OnAppPickerSave
	))
}

LLM_Menu_OnAppPickerSave(selected, receipt) {
	return LLM_Menu_CommitMutation("the LLM disabled-applications setting",
		(Candidate) => _LLM_Menu_ApplyAppPickerSelection(Candidate,
			selected, receipt),
		_LLM_Menu_ApplyStandardCommitted)
}





; =======================
; =======================
; ======= 4/ Misc =======
; =======================
; =======================

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
	if !_LLM_Menu["enabled"]
		return false
	if (_LLM_Menu["backend"] == "ollama" && !LLM_Deps_IsReady())
		return
	if (_LLM_Menu["backend"] == "api"
			&& !_LLM_Menu_SelectedApiEntryIsUsable())
		return false
	_LLM_Menu["bridge_pending"] := false
	if !LLM_Menu_StartBridge()
		return false
	if (IsSet(_PrefixInputHook) && _PrefixInputHook && IsSet(LLM_Bridge_OnPrefixWatcherReady))
		LLM_Bridge_OnPrefixWatcherReady()
	return true
}

LLM_Menu_StartBridge() {
	global _LLM_Menu
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return
	}
	if !LLM_Menu_EnsureModelReady()
		return false
	LLM_Bridge_Start(LLM_Menu_BuildOpts())
	tag := LLM_ResolveOllamaTag(_LLM_Menu["model"])
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		LoggerInfo("LLM", "Bridge started — model: {1}, tag: {2} (PrefixWatcher hook).", _LLM_Menu["model"], tag)
	else
		LoggerInfo("LLM", "Bridge started — model: {1}, tag: {2} (HookDispatcher until PrefixWatcher).", _LLM_Menu["model"], tag)
	return true
}

/**
 * Ensures _LLM_Menu["model"] points at a locally installed model before the
 * engine fires requests. Legacy configs stored raw Ollama tags (e.g.
 * ``qwen2.5:3b``) that are not installed — auto-switch to the best match.
 */
LLM_Menu_EnsureModelReady() {
	global _LLM_Menu
	if (_LLM_Menu["backend"] != "ollama")
		return true
	; Never run the blocking installed-models probe (GET /api/tags, up to a 5 s
	; WinHTTP timeout) unless the Ollama daemon is confirmed reachable. At boot
	; the deps state is "pending", so a dead-port connect to localhost:11434
	; froze the synchronous menu build for ~2 s — the single largest chunk of
	; startup time — even with the LLM feature switched off. The model
	; auto-correct still runs once the daemon comes up: the deps-ready
	; bridge-start path (LLM_Menu_StartBridge) calls us again with
	; LLM_Deps_IsReady() == true, where the same probe returns in milliseconds.
	if !LLM_Deps_IsReady()
		return true
	; Deps are confirmed up — refresh the installed-tags cache with ONE synchronous
	; probe so the model auto-correct below reads a trustworthy snapshot. This is the
	; only sanctioned blocking /api/tags call (off the keyboard hot path, gated on
	; deps-ready above); the tray build itself stays non-blocking via the async probe.
	_LLM_WarmInstalledTagsSync()
	model := _LLM_Menu["model"]
	if (model == "")
		model := _LLM_DefaultFor("llm_model", _LLM_LOCAL_DEFAULTS["llm_model"])
	if LLM_IsModelInstalled(model) {
		if (_LLM_Menu["model"] != "")
			return true
		return LLM_Menu_CommitMutation("the default installed LLM model",
			(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
				"model", model))
	}
	replacement := LLM_PickBestInstalledDisplayName()
	if (replacement == "")
		return true
	old_tag := _LLM_ResolveOllamaTagCore(model, false)
	new_tag := _LLM_ResolveOllamaTagCore(replacement, false)
	Committed := LLM_Menu_CommitMutation("the installed LLM model correction",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"model", replacement))
	if Committed {
		try LoggerWarn("LLM",
			"Model '{1}' (tag '{2}') is not installed — switched to '{3}' (tag '{4}').",
			model, old_tag, replacement, new_tag)
	}
	return Committed
}

; Replays the suspended lifecycle work from the resume watchdog, after native
; Suspend has released hotkeys. The one-shot avoids performing dependency work
; inside the watchdog callback itself.
LLM_Menu_OnResume() {
	global _LLM_Menu
	if A_IsSuspended
		return
	; A trigger cleanup/rollback timer consumes its scheduled ownership before
	; observing suspend. Transfer the retained record now that native Suspend no
	; longer bypasses the callback guard.
	if IsSet(LLM_Menu_ServiceTriggerRecovery) {
		try LLM_Menu_ServiceTriggerRecovery()
		catch as Err
			try LoggerError("LLM",
				"Trigger shortcut recovery resume service failed: {1}.", Err.Message)
	}
	LLM_Menu_ServiceBuilds()
	if _LLM_Menu["bootstrap_pending"] {
		_LLM_Menu["bootstrap_pending"] := false
		if _LLM_Menu["enabled"]
			LLM_Menu_ScheduleBackendLifecycle(false)
	}
}
