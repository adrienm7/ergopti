; ui/tray_llm/init.ahk

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





; ====================================
; ======================================
; ======= 1/ Tray Initialisation =======
; ======================================
; ====================================

/**
 * Bootstraps the tray menu and starts the LLM bridge if auto-start is enabled.
 * @param {Map} saved_opts - Persisted settings loaded from INI/registry.
 */
LLM_Tray_Init(saved_opts := Map()) {
	global _LLM_Tray

	; Defensive: a previous session that crashed mid-install would have
	; left the AHK process at PriorityClass = High (we boost it in
	; LLM_Deps_RunInstaller to keep typing responsive during winget,
	; and lower it back in LLM_Deps_OnPollProbeResult on completion).
	; Reset to Normal at every boot so a fresh script never inherits a
	; stale boost.
	try ProcessSetPriority("Normal")

	static _str_keys := ["model", "profile_id", "language", "temperature", "nav_modifiers", "val_modifiers", "trigger_shortcut", "backend"]
	static _num_keys := ["n_predictions", "min_words", "max_words", "debounce_ms", "ctx_chars", "pred_indent"]
	static _bool_keys := ["enabled", "instant_on_word_end", "after_hotstring", "reset_on_nav",
		"disable_url_bars", "disable_password_fields", "show_info_bar", "streaming",
		"show_all_at_once", "auto_raise_temp", "auto_profile_for_model", "onboarding_seen",
		"inline_autotype"]
	static _arr_keys := ["user_profiles", "disabled_apps"]

	for key in _str_keys
		if saved_opts.Has(key)
			_LLM_Tray[key] := saved_opts[key]
	for key in _num_keys
		if saved_opts.Has(key)
			_LLM_Tray[key] := saved_opts[key]
	for key in _bool_keys
		if saved_opts.Has(key)
			_LLM_Tray[key] := saved_opts[key]
	for key in _arr_keys
		if saved_opts.Has(key) && (saved_opts[key] is Array)
			_LLM_Tray[key] := saved_opts[key]

	; Keep Features["llm"] aligned with tray state so the deferred startup
	; SaveFullConfig() (~500 ms) does not rewrite num_predictions (etc.) back
	; to manifest defaults and clobber a change the user just saved.
	if IsSet(_LLM_Tray_SyncToFeatures)
		_LLM_Tray_SyncToFeatures()

	; Auto-correct legacy raw-tag configs (e.g. qwen2.5:3b) before the first
	; bootstrap / bridge start so predictions do not silently fail.
	if (_LLM_Tray["backend"] == "ollama")
		LLM_Tray_EnsureModelReady()

	; Restore trigger shortcut hotkey
	if (_LLM_Tray["trigger_shortcut"] != "")
		LLM_Tray_ApplyTriggerShortcut(_LLM_Tray["trigger_shortcut"])

	; Restore per-app profile overrides Map (defaults to empty when the
	; config never carried the field).
	if saved_opts.Has("app_profile_overrides") and (saved_opts["app_profile_overrides"] is Map)
		_LLM_Tray["app_profile_overrides"] := saved_opts["app_profile_overrides"]

	; Restore persisted remote API entries (lives in api_entries.json next to
	; the main config.toml — kept separate because the array-of-maps shape
	; would not survive the project's flat-TOML writer).
	_LLM_Tray_LoadApiEntries()

	; Register Ctrl+1 … Ctrl+9 once. Re-registering on every build_menu pass
	; would be wasteful and noisy in the AHK Hotkey log; doing it here
	; covers both fresh boots and post-Reload paths since LLM_Tray_Init is
	; the only entry into the tray module.
	LLM_Tray_BindProfileHotkeys()

	; (Removed) First-run LLM onboarding TrayTip — the unsolicited
	; "Text predictions available" balloon was perceived as noise by users
	; who already know what the tray menu offers. Discovery now lives
	; purely in the menu's "IA" submenu; no opt-in nag at startup.

	LLM_Tray_Build()

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
	if _LLM_Tray["enabled"]
		SetTimer(() => LLM_Tray_BootstrapOllama(false), -1)

	; Background health-tick: refreshes the dot every 10 s without waiting
	; for the user to open the menu. The previous "probe on menu open"
	; model painted a stale dot on the first open after the daemon died
	; (probe result only landed the second time around). The tick uses
	; the same flip-guard as the on-open probe, so a stable backend
	; doesn't trigger spurious rebuilds.
	SetTimer(_LLM_Tray_FireHealthProbe, 10000)
}
