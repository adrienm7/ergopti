; ui/menu/menu_llm/_index.ahk

; ==============================================================================
; MODULE: LLM Tray Menu UI — Entry Point
; DESCRIPTION:
; System tray menu for the LLM feature on Windows. Provides enable/disable
; toggle, backend selection, model selection, profile selection (built-in and
; user-defined), prediction count, trigger settings, generation settings,
; display settings, and navigation settings — mirroring the Hammerspoon
; menu_llm feature set as closely as possible on Windows.
;
; This file is the entry point: it declares every module-wide global (state
; Map, profile thresholds, menu handle, hotkey handle), seeds them from the
; shared ``defaults.json`` via ``LLM_Menu_ApplySharedDefaults``, then
; ``#Include``-s every sub-module that defines the actual menu builders,
; setters, hotkeys, and lifecycle callbacks.
;
; FEATURES & RATIONALE:
; 1. Tray-native: uses AHK v2's A_TrayMenu / Menu API — no external UI.
; 2. Settings persistence: reads/writes settings via the shared config helpers.
; 3. Ollama check: shows an install prompt if Ollama is not running on startup.
; 4. Lazy bootstrap: Ollama is never touched until the user explicitly enables IA.
; 5. User profiles: custom prompts created/edited/deleted via InputBox dialogs.
; 6. App exclusion: reuses the shared AppPicker_Show() to blacklist processes.
; 7. Trigger shortcut: optional hotkey that fires a prediction on demand.
;
; SUB-MODULE LAYOUT:
;   menu_llm/init.ahk            — Bootstrap (LLM_Menu_Init).
;   menu_llm/menu_main.ahk       — Top-level menu orchestrator (LLM_Menu_Build).
;   menu_llm/menu_models.ahk     — Backend + Model submenus + model handlers.
;   menu_llm/menu_api_entries.ahk — Remote API entries + JSON storage.
;   menu_llm/menu_profiles.ahk   — Profile menu + per-app + user CRUD + hotkeys.
;   menu_llm/menu_settings.ahk   — N / Trigger / Gen / Display / Nav menus +
;                                  numeric / modifier / shortcut prompts.
;   menu_llm/actions.ahk         — Toggles, setters, health probe, Ollama
;                                  bootstrap, app picker, lifecycle callbacks.
;   menu_llm/tab_accept.ahk      — Tab-accept hotkey + slot navigation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Tray Menu Constants =======
; ======================================
; ======================================

; Title is resolved at call-time via a function — never at load-time —
; so the active language is already set when the menu is built or rebuilt.

; Available prediction count choices (mirrors HS: for i = 1, 10 do)
global LLM_MENU_N_OPTIONS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

; Available backend IDs — Ollama is the only Windows backend today; the list
; is kept as an array so adding a future backend only requires appending here.
; "api" routes through the LLM_RemoteGenerate adapter in api_remote.ahk and
; lets the user plug into OpenAI / Anthropic / Google Gemini / any
; OpenAI-compatible endpoint via the "+ Add an API…" item in the model
; submenu. "mlx" is macOS-only — kept out of the AHK list deliberately.
global LLM_MENU_BACKEND_OPTIONS := ["ollama", "api"]

; Indent level options for multi-prediction display. Range mirrors the HS
; menu (modules/llm/init.lua DEFAULT_STATE + ui/menu/menu_llm/settings_manager.lua
; build_indent_menu): negative values produce a leading deletion of N chars so
; the prediction lines up at column-N relative to the original cursor, while
; positive values insert N spaces before each line. Built lazily at startup
; so the integer array stays a single source of truth.
global LLM_MENU_INDENT_OPTIONS := _LLMMenuBuildIndentRange()
_LLMMenuBuildIndentRange() {
    out := []
    Loop 15 {
        out.Push(A_Index - 8)   ; -7, -6, …, 0, …, 6, 7
    }
    return out
}

; Physical-idle ceiling for the background Ollama health tick. Past it the tick
; early-returns instead of spawning a curl.exe child every 10 s — 6 processes a
; minute, 8640 a day — to refresh a dot nobody is looking at, which also keeps
; the daemon and the network stack awake for nothing. 60 s is long enough that
; a user pausing to read never loses the live dot, short enough that an
; unattended machine goes quiet almost at once. Freshness is preserved from both
; ends: the tray-build path forces past the gate so opening the menu always
; re-pings, and the ordinary tick resumes within 10 s of the next physical input.
; Deliberately NOT derived from TOOLTIP_UIA_IDLE_REQUIRED_MS — that one asks
; "has the typing burst ended?" (a 250 ms floor), the opposite question.
global LLM_HEALTH_PROBE_IDLE_MAX_MS := 60000

; Cadence of that same background tick. It was written as a bare 10000 at BOTH
; arming sites — the boot arm in init.ahk and the re-arm when the user toggles the
; feature back on in actions.ahk — so the two could silently drift apart and the
; number carried none of the reasoning above (it is the "how fast does a dead
; daemon show up as a red dot" budget, and it is what makes the 8640-probes-a-day
; arithmetic in LLM_HEALTH_PROBE_IDLE_MAX_MS true).
global LLM_HEALTH_PROBE_INTERVAL_MS := 10000

; Floor between two probes, whoever asks. Opening the tray fires a rebuild that
; re-enters _LLM_Menu_FireHealthProbe with Force, and a status flip rebuilds the
; menu again from _LLM_Menu_OnHealthProbeDone — so this throttle is the ONLY thing
; that breaks the build → probe → flip → build loop, and the idle gate cannot help
; because Force bypasses it. Kept well under LLM_HEALTH_PROBE_INTERVAL_MS so the
; ordinary tick is never throttled away, and above the cost of a curl round-trip
; so opening the menu twice in a second cannot spawn two children.
global LLM_HEALTH_PROBE_THROTTLE_MS := 3000





; ============================
; =============================
; ======= 2/ Tray State =======
; =============================
; ============================

; Initial values are replaced at startup by LLM_Menu_ApplySharedDefaults()
; which reads from the shared defaults.json via LLM_Defaults (lib/llm_defaults.ahk).
; String fields use "" as placeholder — ApplySharedDefaults() overwrites them.
global _LLM_Menu := Map(
	"enabled",                    false,
	"backend",                    "ollama",
	; Local Ollama daemon port — placeholder, replaced at startup by
	; LLM_Menu_ApplySharedDefaults() from the shared default (defaults.json
	; llm_ollama_port). User-overridable from the backend submenu (persisted
	; under [llm] ollama_port) for non-standard setups.
	"ollama_port",                0,
	"model",                      "",
	"profile_id",                 "basic",
	"user_profiles",              [],
	"n_predictions",              3,
	"min_words",                  3,
	"max_words",                  15,
	"language",                   "fr",
	"debounce_ms",                500,
	"ctx_chars",                  500,
	"temperature",                "0.10",
	"instant_on_word_end",        true,
	"after_hotstring",            true,
	"reset_on_nav",               true,
	"disable_url_bars",           false,
	"disable_password_fields",    false,
	"disabled_apps",              [],
	"show_info_bar",              true,
	"streaming",                  true,
	"show_all_at_once",           true,
	"pred_indent",                0,
	"auto_raise_temp",            true,
	"nav_modifiers",              "",
	"val_modifiers",              "alt",
	; On-demand prediction shortcut. Ctrl+Space is the default — same key
	; combo as Copilot's "trigger inline suggestion" so muscle memory
	; carries over. The user can rebind it via the tray menu; setting it
	; to the empty string disables the feature entirely.
	"trigger_shortcut",           "Ctrl+Space",
	; Inline auto-type mode (Copilot-style). When ON, the prediction is
	; typed directly into the active app instead of being shown in a
	; tooltip. Forces n_predictions = 1 internally because typing N
	; alternatives sequentially would be chaos. Disabled by default —
	; the tooltip flow is the safer baseline.
	"inline_autotype",            false,
	; Per-app profile overrides. Map(app_name_lower -> profile_id).
	; Resolved at fire time so the user can keep one global profile and
	; override it just for Slack (short informal), VS Code (code), etc.
	; Empty by default; populated via the per-app picker UI.
	"app_profile_overrides",      Map(),
	; When true, switching to a new model auto-picks the matching profile
	; (raw / basic / advanced / batch_advanced) using the params count from
	; models.json. Mirrors the HS get_recommended_profile_info heuristic so
	; the user does not have to manually re-pick a profile every time they
	; try a different model size. Toggleable via the profile submenu.
	"auto_profile_for_model",     true,
	; Onboarding flag — flipped to true the first time the user enables
	; the LLM feature so the welcome TrayTip never fires twice. MUST be
	; declared here (not only added at first-flip) because SaveFullConfig
	; reads it as part of the [LLM] section on every save, including
	; saves triggered during the hotstrings boot before any onboarding
	; logic has had a chance to run. Without this default a fresh install
	; would crash with ``Item has no value`` on the first config write.
	"onboarding_seen",            false,
	; Set when Ollama is ready but PrefixWatcher is not up yet; cleared when
	; HotstringPrefixWatcherInit starts the bridge.
	"bridge_pending",             false,
	; Set when a deferred Ollama lifecycle callback lands while Suspend is
	; active. Resume replays one bootstrap after every suspended producer has
	; stopped, rather than allowing a dependency callback to rebuild the menu or
	; start an InputHook-visible bridge during the pause.
	"bootstrap_pending",          false,
	; ── Remote API backend ──
	; Persisted across reloads via SaveFullConfig (config.toml [LLM]
	; subsection). The user adds an entry via "+ Add an API…" in the model
	; submenu when backend = "api"; each record is a Map with
	; { Id, Name, Provider, BaseUrl, Token, Model }.
	"api_entries",                [],
	"api_entry_id",               ""
)

; Profile-power thresholds used by LLM_RecommendProfileForModel — kept here
; as named constants so the policy is the same as the HS reference (see
; ui/menu/menu_llm/init.lua MODEL_ADVANCED_PARAMS_THRESHOLD_B and
; MODEL_BATCH_PARAMS_THRESHOLD_B).
global LLM_PROFILE_ADVANCED_PARAMS_B := 2.0   ; ≥ 2B → advanced
global LLM_PROFILE_BATCH_PARAMS_B    := 4.0   ; ≥ 4B → batch_advanced

; Ordered profile list used by the Ctrl+<n> hotkeys. Index 1 maps to the
; first row of the profile submenu (Ctrl+1), index 2 to Ctrl+2, etc. The
; built-ins always come first so the shortcut layout stays stable across
; sessions — appending user profiles after them lets a user keep their
; muscle memory while still reaching their own profiles by index.
global LLM_PROFILE_BUILTIN_ORDER := ["raw", "basic", "advanced", "batch_advanced"]
; How many Ctrl+<n> shortcuts we register. We stop at Ctrl+9 because Ctrl+0
; collides with browser zoom reset on too many apps to be worth binding.
global LLM_PROFILE_HOTKEY_LIMIT := 9

/**
 * Overwrites _LLM_Menu defaults with values from the shared defaults.json.
 * Called once at module load time, before LLM_Menu_Init() applies saved prefs.
 */
LLM_Menu_ApplySharedDefaults() {
	global _LLM_Menu, LLM_Defaults
	if !IsSet(LLM_Defaults)
		return

	static _key_map := Map(
		"llm_active_profile",          "profile_id",
		"llm_model",                   "model",
		"llm_backend",                 "backend",
		"llm_num_predictions",         "n_predictions",
		"llm_min_words",               "min_words",
		"llm_max_words",               "max_words",
		"llm_debounce_ms",             "debounce_ms",
		"llm_context_length",          "ctx_chars",
		"llm_pred_indent",             "pred_indent",
		"llm_temperature",             "temperature",
		"llm_show_info_bar",           "show_info_bar",
		"llm_streaming",               "streaming",
		"llm_streaming_multi",         "show_all_at_once",
		"llm_instant_on_word_end",     "instant_on_word_end",
		"llm_after_hotstring",         "after_hotstring",
		"llm_reset_on_nav",            "reset_on_nav",
		"llm_auto_raise_temp",         "auto_raise_temp",
		"llm_disable_url_bars",        "disable_url_bars",
		"llm_disable_password_fields", "disable_password_fields",
		"llm_nav_modifiers",           "nav_modifiers",
		"llm_val_modifiers",           "val_modifiers",
		"llm_ollama_port",             "ollama_port"
	)

	for shared_key, tray_key in _key_map {
		if LLM_Defaults.Has(shared_key)
			_LLM_Menu[tray_key] := LLM_Defaults[shared_key]
	}
}
LLM_Menu_ApplySharedDefaults()

; Persistent Menu object — reused across rebuilds so the tray entry never
; moves. AHK v2 Menu.Delete+Add always appends; updating the same object
; in place is the only way to keep the canonical menu position.
global _LLM_Menu_Handle    := Menu()
global _LLM_Menu_InTray  := false
; Becomes true once LLM_Menu_Init() has run and _LLM_Menu holds the user's
; persisted values. SaveFullConfig() gates _LLM_Menu_SyncToFeatures on this
; flag so a boot-timer flush fired before LLM_Menu_Init can never clobber the
; user's saved LLM settings with module-level defaults.
global _LLM_Menu_Loaded  := false

; Delay (ms) after boot before the deferred IA submenu is populated. Armed from
; the boot tail (post-"ready") so it never interrupts the hotstring registration;
; short so the dropdown is ready almost immediately for a user who opens it.
global LLM_MENU_BUILD_DEFER_MS := 200

; Active trigger hotkey object — deleted and recreated on every shortcut change
global _LLM_Menu_TriggerHk := unset





; ===================================
; ====================================
; ======= 3/ Sub-module Wiring =======
; ====================================
; ===================================

; Order is non-binding for AHK v2 — functions and globals from #Include files
; are merged into the main script before any user code runs, so any sub-module
; can reference any other. The grouping below mirrors the call graph
; (init → build → action handlers) purely for human readability.

#Include persist.ahk
#Include init.ahk
#Include menu_main.ahk
#Include menu_models.ahk
#Include menu_api_entries.ahk
#Include menu_profiles.ahk
#Include menu_settings.ahk
#Include actions.ahk
#Include tab_accept.ahk
