; Last modified on 2026-04-23 at 00:00 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

; Globals referenced by ``#HotIf`` expressions across the driver. They MUST
; be assigned before any code that pumps the message loop runs — otherwise
; AHK throws "global variable has not been assigned a value" the first time
; a keystroke during early init causes a #HotIf expression to be evaluated.
;
; ``Bundle_Init()`` below shells out to PowerShell via ``RunWait`` (see
; ``lib/bundle.ahk``), and RunWait pumps messages. Any key pressed during the
; ~250ms unzip would otherwise trigger #HotIf evaluation on hotkeys like
; ``#HotIf CapsWordEnabled`` or ``#HotIf LayerEnabled`` while those globals
; are still unset — assigning them here keeps the very first message pump
; well-formed.
global CapsWordEnabled := False
global LayerEnabled := False
global TapHold := Map("keys", Map(), "layers", Map())
; Registry for runtime-registered personal shortcuts (personal_shortcuts.ahk).
; Stores ordered names + per-name descriptions so the tray menu can render them.
global _PersonalShortcutsRegistry := Map("__Order", [])
#Include lib/manifest_reader.ahk
#Include lib/path_translator.ahk

; In compiled mode the .exe ships an embedded zip of every runtime asset
; (hotstrings TOMLs, locales, icons, _shared tree, vendor DLLs). The bundle
; bootstrapper extracts it next to the .exe on first launch so the rest of
; the driver can keep reading from _StaticDir without caring whether it runs
; from source or from a compiled binary. In dev mode Bundle_Init() is a no-op.
#Include lib/bundle.ahk
Bundle_Init()

; Compute _StaticDir and _VendorDir early so i18n.ahk and any module-level
; t() calls that run during #Include processing can resolve locale file paths.
; In compiled mode both point at the extracted bundle dir under LocalAppData
; (resolved by Bundle_Init above). In dev mode _StaticDir walks up two levels
; from the script location (static/ergopti_plus/windows → static) and _VendorDir
; is the vendor/ sibling of the entry script.
if A_IsCompiled {
    _StaticDir := _BundleDir . "\static"
    _VendorDir := _BundleDir . "\vendor"
} else {
    SplitPath(A_ScriptDir, , &_DriversDir_early)    ; static/ergopti_plus
    SplitPath(_DriversDir_early, , &_StaticDir)     ; static
    _VendorDir := A_ScriptDir . "\vendor"
}
global _StaticDir
global _VendorDir
; Sub-roots derived from _StaticDir — declared here so every #Include below can use them.
global _SharedDir := _StaticDir . "\ergopti_plus\shared"
global _DriverDir := _StaticDir . "\ergopti_plus\windows"

; #Warn directives apply to the whole compilation unit in AHK v2 — they
; cannot be scoped to a single #Include. VarUnset and LocalSameAsGlobal are
; disabled globally because UIA.ahk (third-party) triggers both intentionally.
#Warn All
#Warn VarUnset, Off
#Warn LocalSameAsGlobal, Off

#Include *i vendor/UIA.ahk ; UIA v2 library — third-party, kept verbatim in vendor/ (source: https://github.com/Descolada/UIA-v2)
; *i = no error if the file isn't found. UIA is only used by WrapTextIfSelected
; (a Shift/AltGr shortcut that wraps the selection with the typed symbol). If
; that feature is disabled in your INI and you want to trim boot time / memory,
; you can safely delete ``vendor\UIA.ahk``: WrapTextIfSelected falls back to
; a plain SendNewResult via ``isSet(UIA)`` at the call site (see modules/layout.ahk).
; AHK v2 resolves #Include at parse time, so there is no true runtime lazy-load.

; ===== Global error net =====
; Without this, any uncaught error pops an AHK dialog mid-keystroke and can
; leave modifiers stuck down. We log and continue so one bad callback never
; locks the keyboard. The handler must return true to consider the error
; "handled" (suppressing the default dialog).
ErgoptiGlobalErrorHandler(Exc, Mode) {
    ; Release every modifier that could be stuck after the failed callback
    for ModKey in ["LControl", "RControl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin"] {
        if GetKeyState(ModKey, "P") {
            SendEvent("{" ModKey " Up}")
        }
    }
    ; Best-effort logging — guarded because the logger may not be initialised
    ; yet when an early-boot error fires the handler.
    try LoggerError("ErgoptiPlus", "Uncaught error: {1}",
        Exc.Message . (Exc.HasProp("Stack") ? " | " . Exc.Stack : ""))
    ; Offer the user an opt-in crash report before surfacing the generic alert.
    ; CrashReport_PromptUser is guarded internally so a failure here cannot
    ; re-enter the error handler.
    try {
        Report := CrashReport_Build(Exc)
        CrashReport_PromptUser(Report)
    }
    ; Surface the error to the user once, without blocking subsequent keys
    try {
        MsgBox(t("ergopti.error_caught") . "`n`n" . Exc.Message . "`n`n" . (Exc.HasProp("Stack") ? Exc.Stack :
            ""), "ErgoptiPlus", "Icon!")
    }
    return true
}
OnError(ErgoptiGlobalErrorHandler)

; #Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t   ; Adds the no breaking spaces as hotstrings triggers
A_MenuMaskKey := "vkff" ; Change the masking key to the void key
A_MaxHotkeysPerInterval := 150 ; Reduce messages saying too many hotkeys pressed in the interval

; AHK silently DROPS new pseudo-threads (hotkey callbacks, tray-menu items,
; OnMessage handlers, SetTimer callbacks) once A_MaxThreads concurrent
; threads are already active. The default ceiling of 10 is easy to hit
; with the keylogger's ~6 background timers + mouse/keyboard hooks. The
; menu-dispatcher bypass in lib/menu_dispatcher.ahk also relies on a free
; slot for its retry SetTimer, so the headroom matters even more there.
A_MaxThreads := 64

SetKeyDelay(0) ; No delay between key presses
SendMode("Event") ; Everything concerning hotstrings MUST use SendEvent and not SendInput which is the default
; Otherwise, we can't have a hotstring triggering another hotstring, triggering another hotstring, etc.

; Logger pulled in first so every other lib/module can call it during init.
; ``LoggerInit()`` is invoked after the configuration file is parsed so the
; minimum log level can be honoured from the very first INFO/START line.
#Include lib/logger.ahk
#Include lib/registry.ahk
#Include lib/app_state.ahk

; Port adapters — thin OS wrappers that isolate every DllCall, Send*, and
; WinGet* from the domain modules. Loaded before any lib/ or module/ file
; that references adapter functions (e.g. NI_GetSsidHash in keylogger_network).
#Include adapters/crypto.ahk
#Include adapters/clipboard.ahk
#Include adapters/timer_scheduler.ahk
#Include adapters/file_system.ahk
#Include adapters/window_info.ahk
#Include adapters/notifier.ahk
#Include adapters/tray_menu.ahk
#Include adapters/text_sender.ahk
#Include adapters/http_client.ahk
#Include adapters/secure_field_detector.ahk
#Include adapters/storage.ahk
#Include adapters/process_lifecycle.ahk
#Include adapters/key_state.ahk
#Include adapters/app_launcher.ahk
#Include adapters/network_info.ahk
#Include adapters/keyboard_hook.ahk
#Include adapters/mouse_control.ahk
#Include adapters/window_manager.ahk
#Include adapters/graphics_renderer.ahk
#Include adapters/tooltip_renderer.ahk

; INI helpers extracted to their own lib so the test runner can ``#Include``
; them without bootstrapping the rest of the driver.
#Include lib/toml/toml_helpers.ahk
#Include lib/layout/layout_ergopti.ahk

; Active-app cache must come before hotstring_engine.ahk because both
; ``HotstringHandler`` and ``MicrosoftApps`` consult ``GetActiveApp``.
#Include lib/active_app_cache.ahk
#Include lib/window_utils.ahk
#Include lib/string_utils.ahk
#Include lib/spotlight.ahk
#Include lib/nav_layer_helpers.ahk

; Core hotstring engine (send primitives, hotstring builders, text helpers)
; and TOML reader helpers (UnescapeTomlString, LoadHotstringsSection,
; FoldAsciiLower) extracted into dedicated submodules so the main file
; stays focused on ErgoptiPlus-specific logic.
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_main.ahk
; Generated terminator catalogue (single source of truth — shared with macOS via
; shared/domain/Terminators.spec.js). Both the tray and config-window delimiter
; menus render this catalogue so the word-terminator list never drifts between
; drivers. Included before the menus and before HSE_Terminators is instantiated.
#Include _generated/terminators.ahk
#Include lib/toml/toml_loader.ahk
#Include lib/toml/toml_config_loader.ahk
; manifest_reader.ahk + path_translator.ahk are loaded at the top of
; the file so Features / path-translation functions are available before
; any #HotIf expression is evaluated. Re-listing them here would cause AHK
; to complain about the same script being included twice.
#Include lib/first_boot.ahk
#Include lib/tap_hold/tap_hold_loader.ahk
#Include lib/tap_hold/tap_hold_writer.ahk
#Include lib/master_gates.ahk
#Include lib/manifest_descriptions.ahk
#Include lib/menu_dispatcher.ahk
#Include lib/hook_dispatcher.ahk
#Include lib/menu_manifest.ahk
#Include lib/menu_renderer.ahk
#Include lib/llm_defaults.ahk
#Include lib/updater.ahk
#Include lib/changelog_window.ahk
#Include lib/healthcheck.ahk
#Include lib/crash_reporter.ahk
#Include lib/json.ahk
; i18n module — must come after toml_loader.ahk (TOML_BatchWrite), logger.ahk, and json.ahk
#Include lib/i18n.ahk
#Include lib/onboarding.ahk
#Include lib/hotstrings/hotstrings_config.ahk
#Include lib/hotstrings/hotstrings_config_window.ahk
#Include lib/ui_style.ahk
#Include lib/tooltip.ahk
#Include lib/llm_diff.ahk
#Include lib/hotstrings/hotstring_prefix_watcher.ahk
; Auto-generated registrar for the bundled hotstring TOMLs. ``*i`` keeps the
; driver runnable from a fresh clone before ``tools/compile_hotstrings.py`` has
; been executed — ``LoadHotstringsSection`` falls back to the regex parser when
; ``_GENERATED_HOTSTRINGS`` is undefined.
#Include *i lib/hotstrings/hotstrings_generated.ahk
#Include lib/hotstrings/personal_toml_editor.ahk
#Include lib/layout/layout_altgr.ahk
#Include lib/layout/layout_shift_caps.ahk
#Include lib/app_picker.ahk
#Include lib/config_shortcuts.ahk
#Include lib/metrics/metrics_shortcuts.ahk
#Include lib/metrics/metrics_filters.ahk
#Include lib/metrics/wpm_widget.ahk
#Include lib/sqlite3.ahk
#Include vendor/ComVar.ahk
#Include vendor/Promise.ahk
#Include vendor/WebView2.ahk
#Include modules/keylogger/keylogger_app_categories.ahk
#Include modules/keylogger/keylogger.ahk
#Include modules/keylogger/keylogger_walker.ahk
#Include modules/keylogger/keylogger_hook.ahk
#Include modules/keylogger/keylogger_watchers.ahk
#Include modules/keylogger/keylogger_mouse.ahk
#Include modules/keylogger/keylogger_sensors.ahk
#Include modules/keylogger/keylogger_ergonomics.ahk
#Include modules/keylogger/keylogger_window_topology.ahk
#Include modules/keylogger/keylogger_av_state.ahk
#Include modules/keylogger/keylogger_network.ahk
#Include modules/keylogger/keylogger_clipboard.ahk
#Include modules/keylogger/keylogger_trigger_roi.ahk

; Bundled extension shortcut menus — each defines BuildExtMenu_<id>().
; ``*i`` keeps the driver runnable if an extension is removed without
; updating this list.
#Include *i ..\..\extensions\ergopti-demo\shortcuts\menu.ahk
#Include modules/keylogger/keylogger_reader.ahk
#Include modules/keylogger/keylogger_prefetch.ahk
#Include modules/keylogger/keylogger_webview.ahk
#Include modules/keylogger/keylogger_ui.ahk
#Include modules/llm/api_common.ahk
#Include modules/llm/api_token_crypto.ahk
#Include modules/llm/api_ollama.ahk
#Include modules/llm/api_remote.ahk
#Include modules/llm/models.ahk
; LLM_GetSharedPath is now available — load the cross-platform defaults before
; prediction_engine.ahk and tray_llm.ahk initialise their state maps.
LLM_Defaults_Load()
#Include modules/llm/profiles.ahk
#Include modules/llm/prediction_engine.ahk
#Include modules/llm/llm_bridge.ahk
#Include modules/llm/ollama_webview.ahk
#Include modules/llm/ollama_deps_checker.ahk
#Include ui/tooltip_llm.ahk
#Include ui/tray_llm.ahk
#Include ui/llm_model_browser.ahk

; ======================================================
; ======================================================
; ======================================================
; ================ 1/ SCRIPT MANAGEMENT ================
; ======================================================
; ======================================================
; ======================================================

; The code in this section shouldn't be modified
; All features can be changed by using the configuration file

; =============================================
; ======= 1.1) Variables initialization =======
; =============================================

; NOT TO MODIFY
global RemappedList := Map()
global LastSentCharacterKeyTime := Map() ; Tracks the time since a key was pressed
; Any entry older than this many milliseconds is definitionally useless to the
; time-activation check (no hotstring in the codebase uses a window close to
; this). Kept as a constant so pruning is deterministic and easy to tune.
global LAST_SENT_KEY_TIME_MAX_AGE_MS := 60000
; Pruning triggers when the map exceeds this size. ~150 covers ASCII + French
; accents + control-key sentinels ("LAlt", "BackSpace"…) with room to spare.
global LAST_SENT_KEY_TIME_PRUNE_AT := 150
; LastSentCharacters ring buffer lives in lib/hotstring_engine.ahk (_LSC_*).
; Accessed only via UpdateLastSentCharacter / GetLastSentCharacterAt.
; ``CapsWordEnabled`` and ``LayerEnabled`` are initialised at the very top of
; the script (before Bundle_Init) so #HotIf evaluation during early message
; pumping never sees them unset — do not re-declare them here.
global NumberOfRepetitions := 1 ; Same as Vim where 3w does the w action 3 times, we can do the same in the navigation layer
global ActivitySimulation := False
global OneShotShiftEnabled := False
global _TOML_STRICT_CANON_IN_PROGRESS := false

; Read path overrides from paths.toml — same file format as Hammerspoon.
; Auto-generated with defaults if absent.
; In compiled mode the file lives in %APPDATA%\Ergopti\ — a stable location that
; persists across updates. The bundle dir (LocalAppData\Ergopti\bundle\) is wiped
; and re-extracted on every version change, so storing paths.toml there caused
; ConfigDirPath overrides to be lost on every update, which triggered the
; onboarding wizard again even for existing users. The dev-mode fallback keeps
; using A_ScriptDir\_generated\paths.toml.
global _PathsFile := A_IsCompiled
    ? (A_AppData . "\Ergopti\paths.toml")
    : (A_ScriptDir . "\_generated\paths.toml")
global _PathsOverrides := ReadPathsToml(_PathsFile)

; ConfigDirPath is the single relocatable folder that holds all personal files.
; Defaults to %USERPROFILE%\.config\ergopti_plus\ (mirrors XDG-style on Unix);
; must end with a backslash.
global _DefaultConfigDir := EnvGet("USERPROFILE") . "\.config\ergopti_plus\"
global _ConfigDir := (_PathsOverrides.Has("ConfigDirPath") and _PathsOverrides["ConfigDirPath"] != "")
    ? _PathsOverrides["ConfigDirPath"]
    : _DefaultConfigDir
if !(_ConfigDir ~= "[/\\]$")
    _ConfigDir .= "\"
if !DirExist(_ConfigDir) {
    try DirCreate(_ConfigDir)
}

; Subfolder name for AHK-specific user files under _ConfigDir. Centralised so
; a future rename only requires changing this one constant.
global _AhkSubDir := "autohotkey\"

; All AHK driver configuration lives in a single unified TOML under the
; driver subfolder: features, script settings, shortcuts, gestures, and
; expert overrides ([script] / [features]) are sections of this one file.
global ConfigurationFile := _ConfigDir . _AhkSubDir . "config.toml"

; Initialise the hotstrings_config module so per-group delays and tooltip
; colors can be resolved from the TOML metadata + the shared user override
; file. The override file lives in the same shared config directory used by
; Hammerspoon, so edits made from either menu apply to both at next reload.
HotstringsConfigInit(_ConfigDir . "hotstrings_config.toml")
; Apply the user's word-delimiter preference so HSE fires on the right chars.
; HotstringsGetWordDelimiters() returns the stored override or the canonical
; default — assigning it here replaces the compile-time constant in the engine.
HSE_WORD_TERMINATORS    := HotstringsGetWordDelimiters()
HSE_CONSUMED_DELIMITERS := HotstringsGetConsumedDelimiters()
TooltipDequeueInit()

; Arm the suspend watchdog so the pause reactor (Ergopti_OnSuspendEnter/Resume)
; fires even when suspend is toggled outside ToggleSuspend. 500 ms is well under
; human perception for the tear-down yet costs nothing while idle.
SUSPEND_WATCHDOG_MS := 500
global _LastSuspendState := A_IsSuspended
SetTimer(_SuspendStateWatchdog, SUSPEND_WATCHDOG_MS)

; _LogoDir: fully-normalized absolute path avoids any '..' traversal that
; TraySetIcon may refuse to resolve on some Windows configurations.
global _LogoDir := _StaticDir . "\img\logo"

; Tray icon paths are deliberately NOT part of ScriptInformation so that
; ReadScriptConfig() cannot override them from a user's [Script] section in
; ErgoptiPlus_Configuration.ini — historical configs still hold stale paths
; pointing at the old static/ergopti_plus/windows/icons/ location and would
; otherwise silently break the tray icon after each project-level move
global IconPath := _LogoDir . "\logo_simple.ico"
global IconPathDisabled := _LogoDir . "\logo_simple_disabled.ico"

; Set the custom tray icon immediately so the default green AHK icon never
; appears — even briefly during the module loading phase that follows.
if FileExist(IconPath)
    TraySetIcon(IconPath)

; Auto-create driver and shared subfolders under _ConfigDir on first launch.
; autohotkey/ holds driver-specific files; hotstrings/ holds the shared TOML
; files so a Mac+PC setup can keep both side by side without name collision.
DirCreate(_ConfigDir . _AhkSubDir)
DirCreate(_ConfigDir . "hotstrings")
; Bootstrap an empty personal_hotstrings.toml if it does not exist yet so the
; user always has a file to open rather than a confusing error.
_PersonalTomlBootstrap := _ConfigDir . "hotstrings\personal_hotstrings.toml"
if !FileExist(_PersonalTomlBootstrap)
    FileAppend("", _PersonalTomlBootstrap)

global ScriptInformation := Map(
    "MagicKey", "★",
    ; Scancode and QWERTY character of the physical key remapped to ★.
    ; Defaults to SC02E / "j" (the J position on the Ergopti layout).
    ; QWERTY users or other layouts can override via [hotstrings] magic_key_source_scan
    ; and magic_key_source_char in config.toml.
    "MagicKeySourceScan", "SC02E",
    "MagicKeySourceChar", "j",
    ; Manual override for the AltGr-as-Kana / custom-remap detection. Default
    ; false here is overwritten by HotstringEngineInit() which auto-detects via
    ; a reverse VK_RMENU→SC probe. The TOML value (under [Script]) wins when
    ; explicitly set to "true" or "false"; "auto" (or absent) defers to the
    ; probe. Kept as an escape hatch in case the probe ever misfires on an
    ; exotic layout.
    "AltGrIsKanaRemap", "auto",
    ; Configurable file paths — all derived from _ConfigDir set above.
    ; AHK-specific files (.ahk, AHK config.toml) go under ``autohotkey/`` so
    ; the folder can be safely shared with the Hammerspoon driver via cloud
    ; sync. Shared neutral files (hotstrings TOML, personal info) stay
    ; at the root of _ConfigDir.
    "PersonalAhkPath", _ConfigDir . _AhkSubDir . "personal_shortcuts.ahk",
    "PersonalTomlPath", _ConfigDir . "hotstrings\personal_hotstrings.toml",
    "PersonalHotstringsDir", _ConfigDir . "hotstrings\",
    "PersonalInfoTomlPath", _ConfigDir . "personal_info.toml",
)

; Script-management hotkey slots. Each AltGr+key combo dispatches to an action
; from GESTURE_ACTIONS (see modules/gestures.ahk) so the user can re-purpose
; them via the tray menu the same way they configure trackpad gestures.
; ``Default`` is the action fired on a fresh install; ``Fallback`` is what we
; send to the OS when the assignment is "none" (so the underlying key keeps
; working). ``ScKey`` is the scancode of the secondary key for the GetKeyState
; double-check guarding against AltGr+Enter pause-bug-style misfires.
global SCRIPT_SHORTCUT_SLOTS := [
    "script_altgr_enter",
    "script_altgr_backspace",
    "script_altgr_delete",
    "script_altgr_escape",
]
global SCRIPT_SHORTCUT_LABELS := Map(
    "script_altgr_enter",    t("sg_labels.script_altgr_enter"),
    "script_altgr_backspace", t("sg_labels.script_altgr_backspace"),
    "script_altgr_delete",   t("sg_labels.script_altgr_delete"),
    "script_altgr_escape",   t("sg_labels.script_altgr_escape"),
)
global SCRIPT_SHORTCUT_DEFAULTS := Map(
    "script_altgr_enter", "script_pause_toggle",
    "script_altgr_backspace", "script_save_reload",
    "script_altgr_delete", "open_personal_shortcuts",
    "script_altgr_escape", "script_quit",
)
global SCRIPT_SHORTCUT_FALLBACKS := Map(
    "script_altgr_enter", "{Enter}",
    "script_altgr_backspace", "{BackSpace}",
    "script_altgr_delete", "{Delete}",
    "script_altgr_escape", "{Escape}",
)
global ScriptShortcutAssignments := Map()
for _Slot in SCRIPT_SHORTCUT_SLOTS {
    ScriptShortcutAssignments[_Slot] := SCRIPT_SHORTCUT_DEFAULTS[_Slot]
}

; Configurable keyboard shortcuts — Ctrl/Win/Alt × a-z, 0-9 and special keys.
; Each slot id matches a GESTURE_ACTIONS key (e.g. "win_a", "ctrl_b").
; Defaults below mirror the legacy hard-coded shortcuts so a fresh install
; behaves identically to before while giving the user full control via the menu.
global KEYBOARD_SHORTCUT_DEFAULTS := Map(
    "win_a", "select_line",
    "win_d", "open_hotstrings_editor",
    "win_g", "open_url",
    "win_c", "ocr_screenshot",
    "win_h", "screen_capture",
    "win_m", "activity_simulation",
    "win_n", "take_note",
    "win_o", "surround_parens",
    "win_s", "search_web",
    "win_t", "teleport_mouse",
    "win_u", "uppercase_selection",
    "win_w", "titlecase_selection",
    "win_x", "pick_color",
    "ctrl_b", "microsoft_bold",
    "ctrl_shift_v", "paste_plain",
)
; AHK send-key codes for each slot — must match GESTURE_ACTIONS Fn lambdas.
; Slots not listed here are generated dynamically from their suffix.
global KEYBOARD_SHORTCUT_SEND_CODES := Map(
    "ctrl_shift_v", "^+v",
)
global KeyboardShortcutAssignments := Map()

; ParseTomlFile / IniCacheGet / ResolveConfigPath are defined in lib/ini_helpers.ahk
; (included above) so the test runner can exercise them in isolation.

; Category-level gating state (Phase 7.4 master-toggle refactor).
;
; The master toggle at the top of every category submenu ("Activer la
; disposition" / "Désactiver les raccourcis" / ...) used to flip every
; individual feature in the category to the same value, destroying the
; user's per-feature choices on every master click. The new design
; separates the master gate (this Map) from the per-feature .Enabled
; flags: toggling the master flips ``CategoryEnabled[Category]`` only,
; and ``ApplyMasterGatesToFeatures`` in lib/master_gates.ahk forces
; the corresponding Features entries to false at boot — a disabled
; category propagates as all Features entries reading false at the HotIf
; level, but the underlying per-feature choices persisted on disk are
; preserved for when the user re-enables the master.
;
; Defaults all true so a fresh install (or a user who hasn't touched
; the master) sees no behavior change. Loaded from the [CategoryEnabled]
; section of config.toml; default-on when the section is absent.
global CategoryEnabled := Map(
    "Layout",     true,
    "Shortcuts",  true,
    "Hotstrings", true,
    "TapHolds",   true,
)

ReadCategoryEnabled(Cache) {
    global CategoryEnabled
    for Category, _Default in CategoryEnabled {
        Raw := IniCacheGet(Cache, "ahk.category_enabled", _CategoryEnabledKey(Category))
        if (Raw == "_") {
            continue
        }
        CategoryEnabled[Category] := (Raw == true or Raw == 1 or Raw == "1" or Raw == "true")
    }
}

; Returns true when the master gate for ``Category`` is on. Used by
; the mirrors (to apply gating when populating Features) and by the
; tray-menu rendering (to label the master toggle and parent menu).
IsCategoryGated(Category) {
    global CategoryEnabled
    return CategoryEnabled.Has(Category) ? CategoryEnabled[Category] : true
}

ReadScriptConfig(Cache) {
    ; MagicKey lives in [hotstrings] trigger_char in the v2 TOML.
    Raw := IniCacheGet(Cache, "hotstrings", "trigger_char")
    if Raw != "_"
        ScriptInformation["MagicKey"] := Raw
    ; Source key for the J→★ remap — scancode and QWERTY character are stored
    ; separately so the remapping works regardless of the active OS layout.
    RawScan := IniCacheGet(Cache, "hotstrings", "magic_key_source_scan")
    if RawScan != "_"
        ScriptInformation["MagicKeySourceScan"] := RawScan
    RawChar := IniCacheGet(Cache, "hotstrings", "magic_key_source_char")
    if RawChar != "_"
        ScriptInformation["MagicKeySourceChar"] := RawChar
    ; AltGr-as-Kana manual override. Default "auto" defers to the reverse
    ; VK_RMENU→SC probe in HotstringEngineInit(); "true" / "false" force the
    ; respective mode. Lives in [script] so the user can lock it once per
    ; machine if auto-detection misfires on an exotic layout.
    RawKana := IniCacheGet(Cache, "script", "alt_gr_is_kana_remap")
    if RawKana != "_"
        ScriptInformation["AltGrIsKanaRemap"] := RawKana
    ; Restore the engine-level repeat-key toggle (defaults to enabled when absent).
    global HSE_RepeatEnabled
    RawRepeat := IniCacheGet(Cache, "hotstrings", "repeat_key_enabled")
    if RawRepeat != "_"
        HSE_RepeatEnabled := (RawRepeat == "1" or RawRepeat == "true")
    ; Paths are always derived from _ConfigDir at startup and are never persisted.
}

Onboarding_Run()

global _IniCache := ParseTomlFile(ConfigurationFile)
ReadScriptConfig(_IniCache)
ReadCategoryEnabled(_IniCache)
I18nInit(_IniCache)

; Resolve _ALTGR_KANA_FIXUP: TOML override (ScriptInformation["AltGrIsKanaRemap"])
; wins when set; otherwise auto-detect via the reverse VK_RMENU→SC probe. Must
; run before the first hotstring fires. The layout-poll timer at the bottom of
; this file triggers a full Reload() on layout switch, so this re-runs and
; adapts to the new layout automatically.
HotstringEngineInit()

; Initialise the logger now that the ini cache is built and ScriptInformation
; reflects user overrides — LoggerInit reads [Script] LogLevel from the ini.
LoggerInit()
Updater_LoadChannel()
Updater_LoadCheckInterval()
; Schedule the background update poller. No-op in dev / source mode, or
; when the user has chosen "never" — those checks happen inside the helper.
try Updater_StartBackgroundChecks()
try Updater_InitTrayNotifyHandler()
LoggerStart("ErgoptiPlus", "Booting ErgoptiPlus driver…")

; Load tooltip visual constants from shared/tooltip/constants.toml so the
; runtime values stay in sync with the TOML single source of truth.
; Must run after _SharedDir is set (line ~51) and ParseTomlFile is available.
UiStyle_LoadSharedConst()

; Log both the raw reverse-probe result (VK_RMENU → SC) and the resolved
; Kana-remap flag so future regressions on exotic layouts surface immediately.
; SC=0 means VK_RMENU is not mapped → Kana-like remap; non-zero means RAlt
; exists on this layout → standard AltGr. The resolved flag also accounts for
; any manual TOML override from [Script] AltGrIsKanaRemap.
_DetectSC := DllCall("MapVirtualKeyExW",
    "UInt", 0xA5, "UInt", 4,
    "Ptr", GetForegroundKeyboardLayout(), "UInt")
LoggerInfo("AltGrDetect",
    "HKL=0x{1:X}, VK_RMENU→SC=0x{2:X}, _ALTGR_KANA_FIXUP={3}.",
    GetForegroundKeyboardLayout(), _DetectSC,
    _ALTGR_KANA_FIXUP ? "true" : "false")

; Under this text is the configuration of the features, especially whether or not they are enabled.
; It is advised to modify which features are enabled by using the ErgoptiPlus_Configuration.ini file.
; This configuration file will automatically be created or updated as soon as one element of the tray menu is toggled on/off.
; It can also be created manually. The content will look like this, with the different categories in brackets:
; [Layout]
; ErgoptiBase.Enabled=0
; [TapHolds]
; AltGr.Enabled=1

; It is best to modify those values by using the option in the script menu
global PersonalInformation := Map(
    "first_name", "Prénom",
    "last_name", "Nom",
    "date_of_birth", "01/01/2000",
    "email_address", "prenom.nom@mail.fr",
    "work_email_address", "prenom.nom@mail.pro",
    "phone_number", "0606060606",
    "phone_number_clean", "06 06 06 06 06",
    "street_address", "1 Rue de la Paix",
    "city", "Paris",
    "country", "France",
    "postal_code", "75000",
    "iban", "FR00 0000 0000 0000 0000 0000 000",
    "bic", "ABCDFRPP",
    "credit_card", "1234 5678 9012 3456",
    "social_security_number", "1 99 99 99 999 999 99",
)
global PersonalInformationLetters := Map(
    "a", "street_address",
    "b", "bic",
    "c", "credit_card",
    "d", "date_of_birth",
    "e", "email_address",
    "f", "phone_number_clean",
    "i", "iban",
    "m", "email_address",
    "n", "last_name",
    "p", "first_name",
    "s", "social_security_number",
    "t", "phone_number",
    "w", "work_email_address",
)

; ======================================================================
; ======= 1.2) Variables update if there is a configuration file =======
; ======================================================================

; Configuration is hydrated from the user's v2 config.toml by
; ApplyConfigToml below. The legacy INI-based ReadConfiguration path
; and the v1 Features Map are gone.

; Materialise personal_info.toml from defaults if missing, so renaming or
; deleting the file simply triggers a fresh re-creation on the next launch
; (same guarantee EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk).
EnsurePersonalInfoTomlFile(ScriptInformation["PersonalInfoTomlPath"])
ReadPersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])

EnsureUserConfigsExist()
; Guard: the generated manifest must be present and loaded before we build
; the Features Map. If it is missing (e.g. after a fresh clone or when the
; codegen has not been run yet), ManifestBuildFeaturesMap returns an empty
; Map and every downstream Features["llm"]["enabled"] access throws a
; cryptic "Item has no value" error. Fail loudly here instead.
if !ManifestEnsureLoaded() {
	MsgBox(t("startup.manifest_missing"), t("startup.manifest_title"), "OK Iconx")
	ExitApp(1)
}
global Features := ManifestBuildFeaturesMap()
ApplyConfigToml(Features, _ConfigDir . _AhkSubDir . "config.toml")
global TapHold := LoadTapHoldToml(_ConfigDir . _AhkSubDir . "tap_hold.toml",
	_DriverDir . "\data\tap_hold\defaults.toml")

; When Ergopti keyboard emulation is off, MagicKeySourceScan must point to
; the physical key that produces MagicKeySourceChar ("j" by default) on the
; user's active OS layout. On bépo, "j" lives on a different scancode than
; SC02E (the Ergopti/QWERTY position), so we probe the layout at startup.
;
; Strategy: enumerate scancodes 0x01→0x7F, call ToUnicodeEx on each with no
; modifiers, and pick the one whose output matches MagicKeySourceChar.
; VkKeyScanExW is not used here because it fails on layouts like bépo where
; the target character ("j") sits behind a driver-level remapping that the
; API cannot see.
;
; HKL resolution cascade: at script startup there may be no foreground window
; (AHK launches tray-only), so GetForegroundKeyboardLayout() returns 0.
; Fallback 1: GetKeyboardLayout(A_ThreadID) — layout of the AHK thread itself.
; Fallback 2: SystemParametersInfo(SPI_GETDEFAULTINPUTLANG) — system default.
if !Features["layout"]["ergopti_base"] {
	_HKL := GetForegroundKeyboardLayout()
	if _HKL = 0 {
		_HKL := DllCall("GetKeyboardLayout", "UInt", A_ThreadID, "Ptr")
	}
	if _HKL = 0 {
		; SPI_GETDEFAULTINPUTLANG = 0x0059; pvParam receives an HKL.
		_HklBuf := Buffer(A_PtrSize, 0)
		DllCall("SystemParametersInfo", "UInt", 0x0059, "UInt", 0, "Ptr", _HklBuf, "UInt", 0)
		_HKL := NumGet(_HklBuf, 0, "Ptr")
	}
	if _HKL != 0 {
		_TargetChar := ScriptInformation["MagicKeySourceChar"]
		_CharBuf  := Buffer(10, 0)
		_KeyState := Buffer(256, 0)  ; all modifier keys unpressed
		_FoundScan := 0
		_FoundVK   := 0
		; Probe every base scancode. 0x01–0x58 covers all standard keys;
		; extend to 0x7F as a safety margin for exotic layouts.
		Loop 127 {
			_SC := A_Index
			; MAPVK_VSC_TO_VK_EX = 3: extended-key-aware SC → VK.
			_VK := DllCall("MapVirtualKeyExW", "UInt", _SC, "UInt", 3, "Ptr", _HKL, "UInt")
			if _VK = 0
				continue
			; ToUnicodeEx with flat (no-modifier) key state.
			; Reset buffer before each call — dead-key state can persist across calls.
			_CharBuf := Buffer(10, 0)
			_Len := DllCall("ToUnicodeEx",
				"UInt", _VK, "UInt", _SC, "Ptr", _KeyState,
				"Ptr", _CharBuf, "Int", 4, "UInt", 0, "Ptr", _HKL, "Int")
			if _Len <= 0
				continue
			_Ch := StrGet(_CharBuf, _Len, "UTF-16")
			if _Ch = _TargetChar {
				_FoundScan := _SC
				_FoundVK   := _VK
				break
			}
		}
		if _FoundScan != 0 {
			ScriptInformation["MagicKeySourceScan"] := Format("SC{:03X}", _FoundScan)
			LoggerInfo("ErgoptiPlus",
				"Magic-key source resolved from layout: char='{1}', VK=0x{2:X}, scan={3} (HKL=0x{4:X}).",
				_TargetChar, _FoundVK, ScriptInformation["MagicKeySourceScan"], _HKL)
		} else {
			LoggerWarn("ErgoptiPlus",
				"Magic-key source: char '{1}' not found on any base scancode of layout"
				. " HKL=0x{2:X} — keeping default scan {3}.",
				_TargetChar, _HKL, ScriptInformation["MagicKeySourceScan"])
		}
	} else {
		LoggerWarn("ErgoptiPlus",
			"Magic-key source resolution skipped: could not obtain a valid HKL at startup"
			. " — keeping default scan {1}.",
			ScriptInformation["MagicKeySourceScan"])
	}
}

; Count the exact number of hotstrings that will be generated for a DynamicHotstrings
; section — mirrors the same threshold logic used in hotstrings.ahk section 5.
; This must stay in sync with the registration code whenever prefix rules change.
CountDynamicSection(SectionName) {
    global PersonalInformation
    Phone := PersonalInformation["phone_number"]
    FPhone := PersonalInformation["phone_number_clean"]
    Ssn := PersonalInformation["social_security_number"]
    Iban := PersonalInformation["iban"]
    SsnRaw := StrReplace(Ssn, " ", "")
    IbanRaw := StrReplace(Iban, " ", "")

    switch SectionName {
        case "DateFr", "DateLongFr", "Date", "date_fr", "date_long_fr", "date":
            return 1
        case "PhonePrefixes", "phone_prefixes":
            N := 0
            if StrLen(Phone) >= 2
                N += 2  ; phone[1:2]+★ and +33+phone[1:2]
            if StrLen(Phone) >= 4
                N += 2  ; phone[1:4] and +33+phone[2:4]
            if StrLen(Phone) >= 6
                N += 1  ; phone[2:5]
            if StrLen(FPhone) >= 5
                N += 1  ; fphone[1:5]
            return N
        case "SsnPrefixes", "ssn_prefixes":
            ; No-space + spaced triggers — both fire when ssn_raw has >= 5 digits
            return StrLen(SsnRaw) >= 5 ? 2 : 0
        case "IbanPrefixes", "iban_prefixes":
            ; 6 raw chars (no-space) and 7-char spaced trigger if iban_raw has >= 6 chars
            return StrLen(IbanRaw) >= 6 ? 2 : 0
        default:
            return 0
    }
}

; The legacy ``Features["DynamicHotstrings"]`` mutation block that injected
; the current date and " (N)" suffix into Features v1 descriptions is gone
; — ``_ApplyMenuLabelDynamicSubstitutions`` in ui/tray_menu.ahk replaces
; the ``{date}`` placeholders in the i18n value at render time and
; appends the count from CountDynamicSection. Pure runtime resolution,
; no boot-time Features mutation.

; Safe nested read — the manifest normally provides the default Map("enabled", true), but a
; stale or missing _generated/features_manifest.ahk would leave the key absent and crash here
_SpaceAroundSymbolsNode := (Features.Has("hotstrings")
	and Features["hotstrings"].Has("distances_reduction")
	and Features["hotstrings"]["distances_reduction"].Has("space_around_symbols"))
	? Features["hotstrings"]["distances_reduction"]["space_around_symbols"]
	: Map()
global SpaceAroundSymbols := (_SpaceAroundSymbolsNode.Has("enabled") and _SpaceAroundSymbolsNode["enabled"]) ? " " : ""

#Include ui/tray_menu.ahk

; Convert a PascalCase or camelCase name to snake_case so that keys stored in
; the TOML config always use the canonical lowercase-with-underscores format,
; regardless of the casing used in personal_shortcuts.ahk.
; Examples: "LaptopBrokenKey" → "laptop_broken_key", "myFeature" → "my_feature".
_PersonalFeatureNormaliseName(Name) {
    ; Insert an underscore before every uppercase letter that follows a
    ; lowercase letter or digit, then lowercase the whole string.
    Name := RegExReplace(Name, "([a-z0-9])([A-Z])", "$1_$2")
    return StrLower(Name)
}

; Register a behavioural toggle for a personal hotkey defined in the user's
; personal_shortcuts.ahk. Toggles are stored under the nested namespace
; Features["shortcuts"]["personal"][Name] so that user-chosen names cannot
; collide with the built-in Shortcuts entries (EGrave, MicrosoftBold, …) and
; show up as a dedicated « Raccourcis personnels » sub-submenu inside
; « 🎯 Raccourcis ».
; Their on/off state is persisted in Features under the
; [ahk.shortcuts.personal] section. The persisted value is already hydrated
; in Features at boot, so toggling via the tray survives reloads without
; any special lookup here — we only set the default on the very first boot.
; Names are normalised to snake_case so PascalCase names from personal_shortcuts.ahk
; do not produce PascalCase TOML keys that fail the lint conventions check.
RegisterPersonalFeature(Name, DefaultEnabled := false, Description := "") {
    global _PersonalShortcutsRegistry, Features

    ; Normalise to snake_case so TOML keys are always lowercase
    Name := _PersonalFeatureNormaliseName(Name)

    ; Register the description for use by the tray menu's GetMenuTitleByPath.
    if !_PersonalShortcutsRegistry.Has(Name) {
        _PersonalShortcutsRegistry[Name] := Description

        ; Track insertion order so the submenu respects personal_shortcuts.ahk
        ; declaration order across reloads.
        Found := false
        for Item in _PersonalShortcutsRegistry["__Order"] {
            if Item == Name {
                Found := true
                break
            }
        }
        if !Found {
            _PersonalShortcutsRegistry["__Order"].Push(Name)
        }
    }

    ; Persist the initial enabled state into Features if no value is stored
    ; yet. On subsequent reloads the user's persisted value already exists so
    ; we never overwrite it with the code-level default.
    if !(IsSet(Features) and Features.Has("shortcuts")
        and Features["shortcuts"].Has("personal")
        and IsObject(Features["shortcuts"]["personal"])
        and Features["shortcuts"]["personal"].Has(Name)) {
        if IsSet(Features) and Features.Has("shortcuts") {
            if !Features["shortcuts"].Has("personal") {
                Features["shortcuts"]["personal"] := Map()
            }
            Features["shortcuts"]["personal"][Name] := DefaultEnabled
        }
    }
}

/**
 * Safe accessor for a personal feature's enabled state.
 * Use this in #HotIf expressions instead of the raw Map lookup to avoid
 * "Item has no value" crashes when the feature key is evaluated before
 * RegisterPersonalFeature() has run (e.g. during AHK's hotkey-condition
 * sweep on the very first keypress after a rapid reload).
 * The name is normalised to snake_case so callers using the original
 * PascalCase name (as declared in personal_shortcuts.ahk) still resolve
 * correctly after RegisterPersonalFeature has canonicalised the key.
 * @param {string} name - The feature name passed to RegisterPersonalFeature.
 * @returns {boolean} True if enabled, false if absent or disabled.
 */
PersonalFeatureEnabled(name) {
    global Features
    ; Normalise so PascalCase call-sites match the snake_case stored key
    name := _PersonalFeatureNormaliseName(name)
    try {
        return Features["shortcuts"]["personal"][name] = true
    } catch {
        return false
    }
}

; Create the user's personal_shortcuts.ahk from PERSONAL_SHORTCUTS_TEMPLATE if
; it does not exist yet. Best-effort: any failure is logged and ignored so a
; read-only config dir cannot prevent the driver from starting.
EnsurePersonalShortcutsFile(Path) {
    global PERSONAL_SHORTCUTS_TEMPLATE

    ; Guard against an unusable Path early — an empty or non-string argument
    ; would otherwise propagate into RegExReplace/FileExist and surface as a
    ; misleading "local variable has not been assigned" error from somewhere
    ; deep in this function.
    if (!IsSet(Path) or Type(Path) != "String" or Path == "") {
        try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile called with empty Path — skipping.")
        return
    }

    ; Step 1 — make sure the user's actual file exists at _ConfigDir, creating
    ; it from the template on first launch (and after the user renames or
    ; deletes it). FileWasCreated drives the reload at the end so the parser
    ; gets to see the freshly-written content during this session.
    FileWasCreated := false
    if !FileExist(Path) {
        try {
            Dir := RegExReplace(Path, "\\[^\\]+$", "")
            if (Dir != "" and !DirExist(Dir)) {
                DirCreate(Dir)
            }
            ; PERSONAL_SHORTCUTS_TEMPLATE is defined in ui/tray_menu.ahk which is
            ; #Include'd before this call site. If somebody removes that include
            ; (or renames the constant) we would otherwise crash here with the
            ; opaque "local variable has not been assigned a value" error.
            Template := IsSet(PERSONAL_SHORTCUTS_TEMPLATE) ? PERSONAL_SHORTCUTS_TEMPLATE : ""
            FileAppend(Template, Path, "UTF-8-RAW")
            FileWasCreated := true
            try LoggerInfo("ErgoptiPlus", "Personal shortcuts file created from template at '{1}'.", Path)
        } catch as e {
            try LoggerWarn("ErgoptiPlus", "Could not create personal shortcuts file at '{1}': {2}.",
                Path, e.Message)
            return
        }
    }

    ; Step 2 — maintain a forwarding stub in the script directory. AHK's
    ; #Include directive is parse-time and cannot resolve runtime variables
    ; like _ConfigDir, so the static `#Include *i personal_shortcuts.ahk`
    ; below only ever searches A_ScriptDir. We keep a tiny stub there whose
    ; sole purpose is `#Include *i <absolute_path_to_user_file>`, redirecting
    ; the loader to the canonical _ConfigDir copy. The inner `*i` is required
    ; so renaming or deleting the user's file does not break script loading
    ; before EnsurePersonalShortcutsFile gets a chance to recreate it.
    ; In compiled mode place the stub in LocalAppData\Ergopti\_generated\ so it
    ; never lands next to the .exe (Downloads, Desktop…). In dev mode the sibling
    ; _generated/ folder (gitignored) keeps the source tree tidy as before.
    ;
    ; AHK v2's built-in ``A_LocalAppData`` can throw "This local variable has
    ; not been assigned a value" in some compiled / restricted runtime contexts
    ; (RDP sessions, services, ill-defined user profiles). EnvGet("LOCALAPPDATA")
    ; is more reliable because it reads the environment block directly, and we
    ; only fall back to ``A_LocalAppData`` inside a try so an unresolvable
    ; built-in cannot crash the boot path. The compiled-only %USERPROFILE%
    ; reconstruction is the last-resort safety net.
    StubDir := ""
    if A_IsCompiled {
        LocalAppData := EnvGet("LOCALAPPDATA")
        if (LocalAppData == "") {
            try LocalAppData := A_LocalAppData
        }
        if (LocalAppData == "") {
            UserProfile := EnvGet("USERPROFILE")
            if (UserProfile != "") {
                LocalAppData := UserProfile . "\AppData\Local"
            }
        }
        if (LocalAppData == "") {
            try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile: cannot resolve LocalAppData — skipping stub creation.")
            return
        }
        StubDir := LocalAppData . "\Ergopti\_generated"
    } else {
        StubDir := A_ScriptDir . "\_generated"
    }
    try DirCreate(StubDir)
    StubPath := StubDir . "\personal_shortcuts.ahk"
    DesiredStub := "; Auto-generated forwarding stub — do not edit.`r`n"
        . "; Forwards to the user's personal shortcuts file located at:`r`n"
        . ";     " . Path . "`r`n"
        . "; Edit that file (e.g. via the tray menu) rather than this stub.`r`n"
        . "#Include *i " . Path . "`r`n"
    Existing := ""
    if FileExist(StubPath) {
        try Existing := FileRead(StubPath, "UTF-8-RAW")
    }
    StubMatches := (Existing == DesiredStub)
    if !StubMatches {
        try {
            if FileExist(StubPath) {
                FileDelete(StubPath)
            }
            FileAppend(DesiredStub, StubPath, "UTF-8-RAW")
            try LoggerInfo("ErgoptiPlus", "Personal shortcuts forwarding stub refreshed at '{1}'.", StubPath)
        } catch as e {
            try LoggerWarn("ErgoptiPlus", "Could not write forwarding stub at '{1}': {2}.",
                StubPath, e.Message)
            return
        }
    }
    ; Reload whenever either the stub or the user's file just changed on disk
    ; — the parser's #Include chain only saw the previous state. The guard
    ; above ensures DesiredStub matches on the next pass with no further file
    ; creation, avoiding an infinite reload loop.
    if FileWasCreated or !StubMatches {
        try LoggerInfo("ErgoptiPlus", "Reloading to pick up freshly-written personal shortcuts chain.")
        Reload
    }
}

; Personal file and TOML loaded here — before menu build — so Features["Personal"]
; exists by the time InitSubMenus / initMenu run. Create the file from a minimal
; template if the user has not authored one yet, so #Include *i has something to
; load on first launch (and the user can find it via the tray menu shortcut).
; Outer try guards the boot path against any internal failure inside the helper
; — the driver must keep starting even when the personal shortcuts file cannot
; be created (read-only home, locked AppData, …); the worst case is just that
; personal hotkeys are inert until the user fixes the permissions.
try {
    EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"])
} catch as _epsErr {
    try LoggerError("ErgoptiPlus", "EnsurePersonalShortcutsFile failed: {1}.", _epsErr.Message)
}
; #InputLevel 2 is required for the user's personal hotkeys to fire after the
; layout's key remappings (which run at the default level 0). We set it here so
; the user does not have to know about input levels in their personal file.
#InputLevel 2
; In dev mode: _generated/ sits next to the script (A_ScriptDir-relative).
; In compiled mode: %A_LocalAppData%\Ergopti\_generated\ so the .exe never
; litters its own folder (Downloads, Desktop, etc.) with generated files.
#Include *i _generated/personal_shortcuts.ahk
#Include *i %A_LocalAppData%\Ergopti\_generated\personal_shortcuts.ahk
; Reset the include working directory to the script root so subsequent
; relative #Include paths resolve correctly. The two lines above may have
; changed it to _generated/ (AHK shifts the context on any successful
; directory-relative include, which breaks the next bare path include).
#Include %A_ScriptDir%
#InputLevel 0
; Apply master gates: disabled category master → force every feature in that
; category to false in Features so all #HotIf evaluations short-circuit.
ApplyMasterGatesToFeatures()

; Gestures module included here — before menu build — so GESTURE_SLOTS,
; GESTURE_ACTIONS and GESTURE_SLOT_LABELS exist when BuildGesturesMenu runs.
#Include modules/gestures.ahk

; Load script-shortcut overrides now that GESTURE_ACTIONS is defined — the
; reader validates each candidate action name against the registry.
ReadScriptShortcutsConfig()

; Seed keyboard shortcut assignments with defaults, then apply any user overrides.
ReadKeyboardShortcutsConfig()

; Register configurable hotkeys for each Ctrl/Win/Alt slot that has a non-"none"
; assignment. All hotkeys call RunKeyboardShortcutAction with their slot id.
LoggerStart("KeyboardShortcuts", "Enregistrement des hotkeys configurables…")
_KbBoundCount := 0
for _KbSlot, _KbAction in KeyboardShortcutAssignments {
    if (_KbAction == "none")
        continue
    _KbSend := _KeyboardSlotSendCode(_KbSlot)
    if (_KbSend == "") {
        LoggerWarn("KeyboardShortcuts", "Slot '%s' skipped — send code not found.", _KbSlot)
        continue
    }
    try {
        Hotkey(_KbSend, ((_s) => (*) => RunKeyboardShortcutAction(_s))(_KbSlot))
        LoggerDebug("KeyboardShortcuts", "Hotkey '%s' → '%s' registered.", _KbSlot, _KbAction)
        _KbBoundCount++
    } catch as _KbErr {
        LoggerWarn("KeyboardShortcuts", "Failed to register hotkey '%s': %s.", _KbSlot, _KbErr.Message)
    }
}
LoggerSuccess("KeyboardShortcuts", "Configurable hotkeys registered (%d active).", _KbBoundCount)

; Load every UI shortcut + privacy filter from the [shortcuts] section
; of autohotkey/config.toml. CS_Load() populates both MetricsShortcuts
; and MetricsFilters in one pass.
CS_Load()

; Expose a global flag so lib modules loaded before this point
; (config_shortcuts, toml_helpers) can detect that SaveFullConfig() is
; available and delegate persistence to the full writer.
global _SaveFullConfigReady := true

; Restore WPM widget state before SaveFullConfig() so that the canonical
; write captures the correct visible/graph/colors values rather than the
; class defaults (which are all false). Without this ordering, SaveFullConfig
; would overwrite WpmWidgetVisible = 0 and the next reload would see that 0.
if MetricsShortcuts.enabled
    WPMWidget_LoadConfig(_IniCache)

InitSubMenus()
initMenu()
UpdateTrayIcon()

; Defer config persistence until after the menu is visible — the write is
; a multi-pass TOML rewrite that parses and rewrites the config file, so
; doing it synchronously delays the tray icon appearing by ~300 ms.
; A 500 ms one-shot timer keeps it off the critical startup path.
SetTimer(SaveFullConfig, -500)

; The keylogger storage layer + the dashboard hotkeys only come up when
; the user has explicitly opted in. A fresh install starts OFF — this is
; a keylogger; the privacy default must be the safe one.
if MetricsShortcuts.enabled {
    LoggerDebug("Startup", "Metrics enabled — WPMWidget.visible=%s, show_graph=%s.",
        WPMWidget.visible, WPMWidget.show_graph)
    if WPMWidget.visible
        WPMWidget_Show()
    if MetricsShortcuts.show_wpm_menubar
        SetTimer(WpmMenubar_Tick, 1000)

    ; Use the resolved config dir (paths.toml override honoured) so the
    ; metrics folder follows the user's relocated config when applicable.
    KL_Init(_ConfigDir . "metrics")
    MS_ApplyAll(KLUI_ToggleTyping, KLUI_ToggleApps)
    ; Start the unified hook dispatcher BEFORE any module-specific hook
    ; start functions so the shared InputHook and mouse Hotkeys are live
    ; when modules subscribe via HookDispatcher.Register().
    HookDispatcher.Start()
    ; Wire the InputHook AFTER KL_Init so Keylogger.initialized is true
    ; by the time the first OnChar fires.
    KL_Hook_Start()
    ; Session / idle timer + Win32 system-event handlers (lock, unlock,
    ; sleep, wake). The hook above must already be wired so the first
    ; KL_Watchers_OnKeystroke call from the input hook reads a sane
    ; KLHook.last_tick.
    KL_Watchers_Start()
    KL_Mouse_Start()
    KL_Sensors_Start()
    KL_Topo_Start()
    KL_AV_Start()
    KL_Net_Start()
    KL_Clip_Start()
    KL_Roi_Start()
}

LoggerSuccess("ErgoptiPlus", "Tray menu built and icon set.")

; ========================================================
; ======= 1.4) Tray menu of the script — Functions =======
; ========================================================

; Returns a bound callback that opens the personal editor on a specific section.
; Wrapping in a function freezes SecName by value — AHK v2 closures capture by
; reference so a direct lambda inside a loop would always use the last iteration value.
_MakeOpenSectionFn(SecName) {
    return (*) => OpenPersonalEditor(SecName)
}

; Sets the default section pref and refreshes checkmarks + parent title.
_SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu) {
    global _PrevDefaultLabel
    _EditorPrefSet("DefaultSection", SecName)
    ; Refresh checkmarks inside the sub-menu
    DefaultSectionMenu.Uncheck(t("menu.hotstrings.default_none"))
    for _, SN in TomlData["sections_order"] {
        if (SN == "-") {
            continue
        }
        SD := TomlData["sections"][SN]
        try DefaultSectionMenu.Uncheck(SD["description"])
    }
    if (SecName == "") {
        DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
    } else if (TomlData["sections"].Has(SecName)) {
        DefaultSectionMenu.Check(TomlData["sections"][SecName]["description"])
    }
    ; Rename the parent item to reflect the new selection
    NewLabel := (SecName == "") ? t("menu.hotstrings.default_none")
        : (TomlData["sections"].Has(SecName) ? TomlData["sections"][SecName]["description"] : SecName)
    try PersonalMenu.Rename(t("menu.hotstrings.default_category_prefix") . _PrevDefaultLabel,
        t("menu.hotstrings.default_category_prefix") . NewLabel)
    _PrevDefaultLabel := NewLabel
}

; Freezes all closure values for use inside a loop.
_MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu) {
    return (*) => _SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu)
}

; Toggles the close-on-add pref and the corresponding checkmark.
_TogglePersonalCloseOnAdd(PersonalMenu) {
    Label  := t("menu.hotstrings.close_on_add")
    NewVal := (_EditorPrefGet("CloseOnAdd", "1") == "1") ? "0" : "1"
    _EditorPrefSet("CloseOnAdd", NewVal)
    if (NewVal == "1") {
        PersonalMenu.Check(Label)
    } else {
        PersonalMenu.Uncheck(Label)
    }
}

; Returns a closure that opens a file with the default OS application.
_MakeOpenFileFn(FilePath) {
    return (*) => Run(FilePath)
}

; Parses an extension TOML file and returns a list of section summaries:
; [{description, count}, ...] in the order declared in [_meta.sections].
; Descriptions come from [_meta.sections], counts from [[section]] entries.
_ParseExtTomlSections(FilePath) {
    Result := []
    if !FileExist(FilePath) {
        return Result
    }
    Content := FileRead(FilePath)
    Q := Chr(34)
    ; First pass: collect descriptions from [_meta.sections] and section order
    SectionDescs := Map()
    SectionOrder := []
    InMetaSections := false
    for _, Line in StrSplit(Content, "`n", "`r") {
        Trimmed := Trim(Line, " `t")
        if RegExMatch(Trimmed, "^\[([^\[\]]+)\]$", &HM) {
            InMetaSections := (Trim(HM[1]) == "_meta.sections")
            continue
        }
        if (SubStr(Trimmed, 1, 2) == "[[") {
            InMetaSections := false
            continue
        }
        if !InMetaSections {
            continue
        }
        if RegExMatch(Trimmed, "^([A-Za-z0-9_]+)\s*=\s*" . Q . "((?:[^" . Q . "\\]|\\.)*)" . Q, &KM) {
            SectionKey := StrLower(KM[1])
            SectionDescs[SectionKey] := KM[2]
            SectionOrder.Push(SectionKey)
        }
    }
    ; Second pass: count entries per [[section]]
    SectionCounts := Map()
    CurSec := ""
    for _, Line in StrSplit(Content, "`n", "`r") {
        Trimmed := Trim(Line, " `t")
        if RegExMatch(Trimmed, "^\[\[([^\[\]]+)\]\]$", &SecM) {
            CurSec := StrLower(Trim(SecM[1]))
            if !SectionCounts.Has(CurSec) {
                SectionCounts[CurSec] := 0
            }
            continue
        }
        if (SubStr(Trimmed, 1, 1) == "[") {
            CurSec := ""
            continue
        }
        if (CurSec != "" and SubStr(Trimmed, 1, 1) == Q and InStr(Trimmed, "output")) {
            SectionCounts[CurSec] := SectionCounts.Get(CurSec, 0) + 1
        }
    }
    ; Build result in [_meta.sections] order (or any section not in meta, alphabetically)
    Seen := Map()
    for _, SecKey in SectionOrder {
        Seen[SecKey] := true
        Result.Push(Map(
            "description", SectionDescs.Get(SecKey, SecKey),
            "count",       SectionCounts.Get(SecKey, 0)
        ))
    }
    for SecKey, Cnt in SectionCounts {
        if !Seen.Has(SecKey) {
            Result.Push(Map("description", SecKey, "count", Cnt))
        }
    }
    return Result
}

MagicKeyEditor(*) {
    ; A plain Edit control routes every keystroke through the hotstring engine
    ; (~6000 mappings), causing severe lag on each character. Capture the new
    ; magic key via a one-shot InputHook instead: the GUI is purely informative,
    ; the first non-modifier key pressed becomes the new value.
    GuiToShow := Gui("+AlwaysOnTop", t("dialog.magic_key.title"))
    GuiToShow.Add("Text", "w300", t("dialog.magic_key.prompt"))
    GuiToShow.Add("Text", "w300", t("button.cancel") . " → Echap")
    GuiToShow.Show("Center")

    IH := InputHook("L1 I", "{Escape}")
    IH.Start()
    IH.Wait()
    GuiToShow.Destroy()

    if (IH.EndReason = "Stopped" && IH.Input != "")
        ModifyMagicKey(0, IH.Input)
}
ModifyMagicKey(gui, NewValue) {
    global ScriptInformation, Features, ConfigurationFile
    ScriptInformation["MagicKey"] := NewValue
    if IsSet(Features) and Features.Has("hotstrings") {
        Features["hotstrings"]["trigger_char"] := NewValue
    }
    TOML_Write(NewValue, ConfigurationFile, "hotstrings", "trigger_char")

    if (gui != 0)
        gui.Destroy()
    Reload
}

ToggleRepeatKeyEnabled(*) {
    global HSE_RepeatEnabled, Features, ConfigurationFile
    HSE_RepeatEnabled := !HSE_RepeatEnabled
    if IsSet(Features) and Features.Has("hotstrings") {
        Features["hotstrings"]["repeat_key_enabled"] := HSE_RepeatEnabled
    }
    TOML_Write(HSE_RepeatEnabled, ConfigurationFile, "hotstrings", "repeat_key_enabled")
    Reload
}

PersonalInformationEditor(*) {
    GuiToShow := Gui(, t("dialog.personal_info.title"))
    UpdatedPersonalInformation := Map()

    ReverseLetters := Map()
    for k, v in PersonalInformationLetters
        ReverseLetters[v] := k

    ; Dynamically generate a field for each element in the Map
    for PersonalInformationKey, OldValue in PersonalInformation {
        TextToAdd := ""
        if ReverseLetters.Has(PersonalInformationKey) {
            TextToAdd := " (@" . ReverseLetters[PersonalInformationKey] . ScriptInformation[
                "MagicKey"] .
                ")"
        }
        GuiToShow.SetFont("bold")
        GuiToShow.Add("Text", , PersonalInformationKey . TextToAdd)
        GuiToShow.SetFont("norm")
        NewValue := GuiToShow.Add("Edit", "w300", OldValue)
        UpdatedPersonalInformation[PersonalInformationKey] := NewValue
    }

    ; OK button
    GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ProcessUserInput(GuiToShow,
        UpdatedPersonalInformation))

    GuiToShow.Show("Center")
}
ProcessUserInput(gui, edits) {
    global PersonalInformation, ScriptInformation
    changed := Map()
    for key, editControl in edits {
        NewValue := editControl.Text
        OldValue := PersonalInformation.Has(key) ? PersonalInformation[key] : ""
        if (NewValue != OldValue)
            changed[key] := True
        PersonalInformation[key] := NewValue
    }
    WritePersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])
    gui.Destroy()

    PersonalInformationSummary := ""
    for key, _ in edits {
        NewValue := PersonalInformation[key]
        line := key ": " NewValue "`n"
        if changed.Has(key) {
            PersonalInformationSummary := PersonalInformationSummary line
        }
    }

    MsgBox(t("dialog.personal_info.saved") "`n`n" PersonalInformationSummary)
    Reload
}

GPTLinkEditor(*) {
    global Features
    CurrentLink := ""
    if IsSet(Features) and Features.Has("shortcuts")
        and Features["shortcuts"].Has("gpt")
        and IsObject(Features["shortcuts"]["gpt"])
        and Features["shortcuts"]["gpt"].Has("link") {
        CurrentLink := Features["shortcuts"]["gpt"]["link"]
    }
    GuiToShow := Gui(, t("dialog.gpt_link.title"))
    NewValue := GuiToShow.Add("Edit", "w300", CurrentLink)

    GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
    GuiToShow.Show("Center")
}
ModifyLink(gui, NewValue) {
    global Features, ConfigurationFile
    if IsSet(Features) and Features.Has("shortcuts") and Features["shortcuts"].Has("gpt") {
        Features["shortcuts"]["gpt"]["link"] := NewValue
    }
    TOML_Write(NewValue, ConfigurationFile, "ahk.shortcuts.gpt", "link")

    gui.Destroy()
    Reload
}

; Formats a number with spaces as thousands separators, matching HS fmt_count.
FmtCount(N) {
    S := String(Round(N))
    Result := ""
    loop StrLen(S) {
        Pos := StrLen(S) - A_Index + 1
        Result := SubStr(S, Pos, 1) . Result
        if (Mod(A_Index, 3) == 0 and A_Index < StrLen(S)) {
            Result := " " . Result
        }
    }
    return Result
}

NoAction(*) {
}

; Wraps a string in section-title dashes for disabled menu headers.
; Use instead of embedding — directly in locale values.
MenuSectionTitle(Text) {
    return "— " . Text . " —"
}

ToggleAllFeaturesOn(*) {
    MsgBox(t("dialog.enable_all.warning"))
    ToggleAllFeatures(1)
}
ToggleAllFeaturesOff(*) {
    ToggleAllFeatures(0)
}
; Walk every feature in ``Features`` and force its ``enabled`` flag to
; ``Value``. Collects all mutations into a single batch — writing them one
; by one through TOML_Write does 50+ FileOpen/Write/Close round-trips and
; produces a visible delay in the tray menu.
;
; Behavior:
; - If Value == 0 : set every feature to false recursively (including
;                   nested Modélisation α entries and sub-Map groups).
; - If Value == 1 : set only first-level features to true; mutually-exclusive
;                   nested choices (AltGr sub-Maps) stay at their existing
;                   per-key state so a "Enable all" doesn't simultaneously
;                   enable every variant of a one-of-N picker.
ToggleAllFeatures(Value) {
    global Features, CategoryEnabled, ConfigurationFile
    if !IsSet(Features) {
        return
    }
    Bool := (Value = true or Value = 1)
    Updates := []

    ; Recursive walker — for each Map encountered, either flip ``enabled``
    ; if it carries one (Modélisation α) or descend into children.
    EmitFlip(SectionPath, Node) {
        if (Type(Node) != "Map") {
            return
        }
        ; Modélisation α entry: { enabled = bool, … }
        if Node.Has("enabled") and (Type(Node["enabled"]) != "Map") {
            Node["enabled"] := Bool
            Updates.Push({ Section: SectionPath, Key: "enabled", Value: Bool })
            return
        }
        for K, V in Node {
            if (Type(V) == "Map") {
                EmitFlip(SectionPath . "." . K, V)
            } else {
                ; Plain bool leaf (e.g. [shortcuts] microsoft_bold = true).
                Node[K] := Bool
                Updates.Push({ Section: SectionPath, Key: K, Value: Bool })
            }
        }
    }

    if (!Bool) {
        ; Disable everything recursively.
        for TopKey, TopVal in Features {
            if (Type(TopVal) != "Map") {
                continue
            }
            EmitFlip(TopKey, TopVal)
        }
    } else {
        ; Enable only first-level/default features (do not descend into
        ; sub-Map groups like alt_gr_lalt that hold mutually-exclusive picks).
        for TopKey, TopVal in Features {
            if (Type(TopVal) != "Map") {
                continue
            }
            for K, V in TopVal {
                if (Type(V) == "Map") {
                    ; Modélisation α with .enabled — flip the leaf only,
                    ; not the surrounding properties.
                    if V.Has("enabled") and (Type(V["enabled"]) != "Map") {
                        V["enabled"] := true
                        Updates.Push({ Section: TopKey . "." . K, Key: "enabled", Value: true })
                    }
                    ; Sub-Map groups (alt_gr_*) without .enabled: skip — the
                    ; user's prior single-pick stays in place.
                } else {
                    TopVal[K] := true
                    Updates.Push({ Section: TopKey, Key: K, Value: true })
                }
            }
        }
    }

    ; CategoryEnabled holds the per-category master gates (Layout, Shortcuts,
    ; Hotstrings, TapHolds). ToggleAllFeatures must flip these too so the
    ; parent-menu checkmarks reflect the new state — Features mutations alone
    ; are not enough when a category gate was off.
    for Category, _ in CategoryEnabled {
        CategoryEnabled[Category] := Bool
        Updates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(Category), Value: Bool })
    }

    ; WPM widget lives outside Features — its three flags are persisted
    ; under [ahk.metrics] and must be flipped explicitly.
    WPMWidget.visible    := Bool
    WPMWidget.use_colors := Bool
    WPMWidget.show_graph := Bool
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: Bool ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: Bool ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: Bool ? "1" : "0" })

    TOML_BatchWrite(ConfigurationFile, Updates)
    ; Hotstrings features are nested 3 levels deep (hotstrings.cat.id.enabled)
    ; so EmitFlip's single-level descent misses them. Delegate to the dedicated
    ; helper which iterates every section via _CollectAllHotstringsV1Paths.
    if Bool {
        HsBatch := []
        for V1Path in _CollectAllHotstringsV1Paths() {
            HsBatch.Push(Map("v1_path", V1Path . ".Enabled", "value", true))
        }
        if (HsBatch.Length > 0) {
            WriteFeatureBatch(HsBatch)
        }
    }
    Reload
}

ToggleAllHotstringsOn(*) {
    ToggleAllHotstrings(1)
}
ToggleAllHotstringsOff(*) {
    ToggleAllHotstrings(0)
}
; Master Hotstrings gate — flips the category-level enabled flag. When
; enabling (Value=1), also activates every individual hotstring feature
; so "tout activer" actually checks all sub-items, not just the gate.
; ApplyMasterGatesToFeatures (lib/master_gates.ahk) applies the gate at
; boot so every HotIf check evaluates false while the gate is off.
ToggleAllHotstrings(Value) {
    global CategoryEnabled, ConfigurationFile
    Bool := (Value = true or Value = 1)
    CategoryEnabled["Hotstrings"] := Bool
    TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", "hotstrings")
    ; When enabling, also flip every individual feature to true so the
    ; sub-menu items appear checked after the reload.
    if Bool {
        Batch := []
        for V1Path in _CollectAllHotstringsV1Paths() {
            Batch.Push(Map("v1_path", V1Path . ".Enabled", "value", true))
        }
        if (Batch.Length > 0) {
            WriteFeatureBatch(Batch)
        }
    }
    Reload
}

; Returns true when the master gate for ``Categories[1]`` is on. Used
; by initMenu to label the per-submenu master toggle and to drive the
; parent-menu checkmark. Per-feature .Enabled flags are no longer
; consulted here — the master gate is the single source of truth for
; "is this category active" UX state.
IsCategoryAllEnabled(Categories) {
    if (Categories.Length == 0) {
        return true
    }
    return IsCategoryGated(Categories[1])
}

; Master category gate — flips ``CategoryEnabled[Category]`` and reloads.
; ApplyMasterGatesToFeatures (lib/master_gates.ahk) reads this flag at
; boot and forces the corresponding Features entries to false, so a
; flipped gate disables every HotIf for the category without altering
; per-feature .Enabled values. Used by tray-menu master toggles for
; Layout / Shortcuts / TapHolds.
ToggleCategoryAllFeatures(Category, Value) {
    global CategoryEnabled, ConfigurationFile
    Bool := (Value = true or Value = 1)
    CategoryEnabled[Category] := Bool
    ; v2 uses lowercase snake_case for the keys too (Layout -> layout, TapHolds -> tap_holds).
    TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", _CategoryEnabledKey(Category))
    Reload
}

; Map a v1 PascalCase category name to its snake_case v2 key, used as the
; leaf id under [category_enabled]. Hotstrings keeps the same id either way.
_CategoryEnabledKey(Category) {
    switch Category {
        case "Layout":     return "layout"
        case "Shortcuts":  return "shortcuts"
        case "Hotstrings": return "hotstrings"
        case "TapHolds":   return "tap_holds"
        default:
            return StrLower(Category)
    }
}

; Persist the complete in-memory state to the unified autohotkey/config.toml.
; Every feature flag, script setting, script shortcut assignment, and
; gesture assignment is written — not just the delta from defaults.
; Sections and keys within sections are sorted alphabetically by the
; TOML_BatchWrite writer for stable, human-readable output.
SaveFullConfig() {
    global Features, ScriptInformation, ScriptShortcutAssignments
    global GestureAssignments, KeyboardShortcutAssignments
    global ConfigurationFile, _TOML_STRICT_CANON_IN_PROGRESS
    global PrevCanonState
    Updates := []

    ; Emit every feature flag from the v2 Map. ``_CollectFeatureUpdates``
    ; walks the hierarchical Features (Map of Map of …) and produces one
    ; v2 TOML section per nested key path.
    if IsSet(Features) {
        _CollectFeatureUpdates(Updates, "", Features)
        ; Schema marker — pinned to 2 so future migrations can recognise
        ; the on-disk shape without sniffing section names.
        Updates.Push({ Section: "_meta", Key: "schema_version", Value: 2 })
    }

    ; [script] section — locale and other script-level settings.
    Updates.Push({ Section: "script", Key: "locale", Value: I18nGetLocale() })
    ; Persist the active log level so it survives a reload. LOGGER_MIN_LEVEL
    ; is mutated in-memory by LoggerSetLevel; SaveFullConfig is the only path
    ; that keeps config.toml consistent, so the value must be included here.
    global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
    Updates.Push({ Section: "script", Key: "log_level", Value: IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : LOGGER_DEFAULT_LEVEL })

    ; [hotstrings] root — MagicKey lives at hotstrings.trigger_char.
    Updates.Push({ Section: "hotstrings", Key: "trigger_char", Value: ScriptInformation["MagicKey"] })
    ; magic_key_source_scan and magic_key_source_char are intentionally NOT
    ; persisted here. The scan is either SC02E (Ergopti default, needs no
    ; entry) or resolved dynamically at startup from the active OS layout
    ; (must not be frozen or it breaks reload on layout switch). Manual
    ; overrides can be added directly to config.toml by the user and are
    ; respected by ReadScriptConfig without ever being rewritten here.

    ; [ahk.shortcuts.script_control] — script management hotkey slots.
    if IsSet(ScriptShortcutAssignments) {
        for Slot, Action in ScriptShortcutAssignments {
            Updates.Push({ Section: "ahk.shortcuts.script_control", Key: Slot, Value: Action })
        }
    }

    ; [ahk.shortcuts.keyboard] — configurable Ctrl/Win/Alt hotkeys.
    if IsSet(KeyboardShortcutAssignments) {
        for Slot, Action in KeyboardShortcutAssignments {
            Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: Action })
        }
    }

    ; [ahk.gestures] — trackpad gesture slot assignments.
    if IsSet(GestureAssignments) {
        for Slot, Action in GestureAssignments {
            Updates.Push({ Section: "ahk.gestures", Key: Slot, Value: Action })
        }
    }

    ; [ahk.metrics] — keylogger feature settings + privacy filters.
    apps := []
    for proc, _ in MetricsFilters.disabled_apps
        apps.Push(proc)
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_enabled", Value: MetricsShortcuts.enabled })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_shortcut_typing", Value: MetricsShortcuts.typing_str })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_shortcut_apps", Value: MetricsShortcuts.apps_str })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_show_wpm_menubar", Value: MetricsShortcuts.show_wpm_menubar })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_wpm_menubar_colors", Value: MetricsShortcuts.wpm_menubar_colors })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_filter_private_browsing", Value: MetricsFilters.private_browsing })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_filter_secure_field", Value: MetricsFilters.secure_field })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_filter_system_auth", Value: MetricsFilters.system_auth })
    Updates.Push({ Section: "ahk.metrics", Key: "metrics_disabled_apps", Value: apps })

    ; [ahk.metrics] — WPM widget position and display options.
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_X,       Value: String(WPMWidget.pos_x) })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_Y,       Value: String(WPMWidget.pos_y) })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: WPMWidget.use_colors ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: WPMWidget.show_graph  ? "1" : "0" })

    ; [llm] section — runtime state (onboarding flag + per-app overrides).
    ; The feature-shaped LLM settings (model / profile / generation / trigger /
    ; navigation) are already emitted by the v2 walker above; we only add
    ; the two runtime-only keys here.
    Updates.Push({ Section: "llm", Key: "onboarding_seen", Value: _LLM_Tray["onboarding_seen"] ? "1" : "0" })
    _AppOverridesStr := ""
    for _AppName, _AppProfileId in _LLM_Tray["app_profile_overrides"] {
        if (_AppOverridesStr != "")
            _AppOverridesStr .= ";"
        _AppOverridesStr .= _AppName . "=" . _AppProfileId
    }
    Updates.Push({ Section: "llm", Key: "app_profile_overrides", Value: _AppOverridesStr })

    ; [ahk.category_enabled] — master category gating state.
    global CategoryEnabled
    if IsSet(CategoryEnabled) {
        for _CatName, _CatBool in CategoryEnabled {
            Updates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(_CatName), Value: _CatBool })
        }
    }

    ; [ahk.updater] — update channel and background-check cadence.
    ; Both values live in the updater module's globals and must be written here
    ; so SaveFullConfig (which rewrites the entire file from scratch) does not
    ; silently erase the user's chosen frequency after every feature toggle.
    global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
    global UPDATER_INI_SECTION, UPDATER_INI_KEY, UPDATER_INI_INTERVAL_KEY
    if IsSet(UPDATER_CHECK_INTERVAL)
        Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_INTERVAL_KEY, Value: UPDATER_CHECK_INTERVAL })
    if IsSet(UPDATER_CHANNEL)
        Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_KEY, Value: UPDATER_CHANNEL })

    ; Strict schema: rewrite from scratch so stale/unknown sections and keys
    ; are removed on each full save.
    if FileExist(ConfigurationFile) {
        try FileDelete(ConfigurationFile)
    }

    PrevCanonState := _TOML_STRICT_CANON_IN_PROGRESS
    _TOML_STRICT_CANON_IN_PROGRESS := true
    try TOML_BatchWrite(ConfigurationFile, Updates)
    finally _TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState
    TOML_FormatViaScript(ConfigurationFile)
}

; Features walker — recursively emit ``Features`` (a hierarchical Map produced by
; ManifestBuildFeaturesMap and patched by the per-section mirrors) as TOML
; sections in the v2 schema. Each level of Map nesting becomes a deeper
; section path:
;   Features["shortcuts"]["microsoft_bold"] = true
;       -> [shortcuts] microsoft_bold = true
;   Features["shortcuts"]["gpt"] = Map("enabled"=>true, "link"=>"…")
;       -> [shortcuts.gpt] enabled = true; link = "…"
;   Features["hotstrings"]["autocorrection"]["accents"] = Map("enabled"=>true, …)
;       -> [hotstrings.autocorrection.accents] enabled = true; …
;
; Arrays and scalars at the root of Features (e.g. ``section_order``) are
; skipped — they're manifest metadata, not user-tunable config. The
; ``ahk.`` prefix that distinguishes AHK-only sections in the manifest is
; intentionally NOT re-emitted (the v2 reader ApplyConfigToml strips it
; on input, so round-trip equivalence is preserved without it).
_CollectFeatureUpdates(Updates, SectionPath, Node) {
    if (Type(Node) != "Map") {
        return
    }
    for Key, Value in Node {
        ; Skip manifest-only metadata at the top level (e.g. section_order array).
        if (SectionPath == "" and Type(Value) != "Map") {
            continue
        }
        Sub := (SectionPath == "") ? Key : SectionPath "." Key
        if (Type(Value) == "Map") {
            _CollectFeatureUpdates(Updates, Sub, Value)
        } else {
            Updates.Push({ Section: SectionPath, Key: Key, Value: Value })
        }
    }
}

ReloadWithDefaultConfig(*) {
    global _ConfigDir, _AhkSubDir
    ; « Valeurs par défaut » must restore the FULL factory state, not only the
    ; feature toggles. Three separate per-user files hold configurable state, all
    ; under _ConfigDir\autohotkey\:
    ;   - config.toml      → features, layout, shortcuts, gestures, LLM scalars,
    ;                        metrics (regenerated from the shipped template).
    ;   - tap_hold.toml    → tap/hold key assignments (regenerated from defaults).
    ;   - api_entries.json → LLM remote endpoints + DPAPI-encrypted tokens
    ;                        (absent file reads back as an empty list).
    ; Deleting only config.toml left tap-holds and API entries on disk, so they
    ; survived the reset — which is exactly the « ça réinitialise que les toggles »
    ; complaint. Remove all three together, then reload.
    AhkDir := _ConfigDir . _AhkSubDir
    for FileName in ["config.toml", "tap_hold.toml", "api_entries.json"] {
        Path := AhkDir . FileName
        try {
            if FileExist(Path) {
                FileDelete(Path)
            }
        } catch as Err {
            try LoggerError("GlobalReset", "Could not delete {1}: {2}.", FileName, Err.Message)
        }
    }
    Reload
}

; Read the user's per-slot action overrides from the config's
; [ahk.shortcuts.script_control] section. Defaults stay in place when the
; key is absent or the action name is unknown. Called once at boot from
; initMenu's preamble.
ReadScriptShortcutsConfig() {
    global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Value := IniCacheGet(_IniCache, "ahk.shortcuts.script_control", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value))) {
            ScriptShortcutAssignments[Slot] := Value
        }
    }
}

; Clean up after a script-management combo (AltGr+Enter/BackSpace/Delete/Escape)
; has fired its action. Two problems are solved here, and ONLY together — fixing
; one without the other reintroduces the other:
;
;   1. Stuck prefix: on an AltGr-as-Kana driver remap (_ALTGR_KANA_FIXUP) SC138
;      IS the Kana virtual key, kept by AHK as the held prefix for the
;      "S"-suspend-exempt script combos. After the un-suspend action the
;      layout's SC138 hotkeys come back on with that prefix still latched, so
;      every following keystroke lands on the AltGr/Kana layer (« AltGr bloqué »).
;      We clear it by injecting an SC138 up.
;   2. Leaked suffix: the custom combo already suppresses the suffix key-down,
;      but injecting the SC138 up WHILE the suffix is still physically held makes
;      AHK replay that suppressed key into the app — the « ça envoie enter puis
;      sort de la pause » bug. So we first wait (bounded) for the suffix to
;      physically lift, and only inject the prefix release once it is confirmed
;      up. If the wait times out with the key still down we skip the inject — a
;      possibly-latched prefix (one AltGr tap to clear) is far less bad than a
;      stray Enter/BackSpace landing in the document.
;
; On non-Kana layouts the prefix is physical RAlt; nothing is injected and
; natural key release already does the right thing, so this is a no-op.
ResetScriptComboKeys(SuffixSC) {
    global _ALTGR_KANA_FIXUP
    if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
        return
    }
    KeyWait(SuffixSC, "T2")
    if !GetKeyState(SuffixSC, "P") {
        SendEvent("{SC138 Up}")
    }
}

; Dispatch the configured action for a script-shortcut slot. ``none`` lets the
; underlying key fall through (the hotkey handler already SendInputs the
; fallback in its else-branch — here we additionally return early so a slot
; explicitly set to "none" produces no action at all).
RunScriptShortcutAction(Slot) {
    global ScriptShortcutAssignments, GESTURE_ACTIONS, SCRIPT_SHORTCUT_FALLBACKS
    Action := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
    if (Action == "none") {
        SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
        return
    }
    if !GESTURE_ACTIONS.Has(Action) {
        try LoggerWarn("ScriptShortcuts", "Unknown action '{1}' for slot {2} — falling back.",
            Action, Slot)
        SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
        return
    }
    GESTURE_ACTIONS[Action].Fn.Call()
}

; Persist a single slot assignment and reload so the new binding is picked up
; by the tray menu hints and by future hotkey firings.
SetScriptShortcutAction(Slot, ActionName) {
    global ScriptShortcutAssignments, ConfigurationFile
    ScriptShortcutAssignments[Slot] := ActionName
    TOML_Write(ActionName, ConfigurationFile, "ahk.shortcuts.script_control", Slot)
    Reload
}

; Build the « Raccourcis de gestion du script » submenu — one entry per slot,
; each opening a lazy GUI picker so the user can rebind the AltGr+ combos.
BuildScriptShortcutsMenu() {
    global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, GESTURE_ACTIONS

    SMenu := Menu()
    ; Each slot becomes a single clickable item that opens a lazy GUI picker —
    ; avoids pre-building a submenu with all actions for every slot.
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Current      := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
        CurrentLabel := GESTURE_ACTIONS.Has(Current) ? _GestureActionLabel(Current) : t("dialog.action_picker.disabled")
        SlotLabel    := SCRIPT_SHORTCUT_LABELS[Slot]
        ; RegisterMenuItem (not raw SMenu.Add) routes the click through the
        ; WM_COMMAND retry dispatcher. Raw SMenu.Add inherits AHK 2.0's flaky
        ; native menu dispatch, which silently drops the click so the action
        ; picker never opens — exactly the gesture-slot pattern at GMenu.
        RegisterMenuItem(SMenu, SlotLabel . " : " . CurrentLabel,
            ((_s, _l) => (*) => ShowActionPicker(_l, ScriptShortcutAssignments.Has(_s) ? ScriptShortcutAssignments[_s] : "none", (Id) => SetScriptShortcutAction(_s, Id)))(Slot, SlotLabel))
    }
    return SMenu
}

; ============================================================
; ============================================================
; ======= Keyboard Shortcuts — configurable Ctrl/Win/Alt =======
; ============================================================
; ============================================================

; Derive the AHK send-code for a slot id from its suffix when not in the
; explicit override table. "win_a" → "#a", "ctrl_0" → "^0", "alt_space" → "!{Space}".
_KeyboardSlotSendCode(SlotId) {
    global KEYBOARD_SHORTCUT_SEND_CODES
    if KEYBOARD_SHORTCUT_SEND_CODES.Has(SlotId)
        return KEYBOARD_SHORTCUT_SEND_CODES[SlotId]
    ; Derive from slot id: "win_<key>", "ctrl_<key>", "ctrl_shift_<key>", "alt_<key>"
    if SubStr(SlotId, 1, 10) = "ctrl_shift"
        Mod := "^+"
    else if SubStr(SlotId, 1, 4) = "ctrl"
        Mod := "^"
    else if SubStr(SlotId, 1, 3) = "win"
        Mod := "#"
    else if SubStr(SlotId, 1, 3) = "alt"
        Mod := "!"
    else
        return ""
    ; Extract suffix after last underscore group
    if SubStr(SlotId, 1, 10) = "ctrl_shift"
        Suffix := SubStr(SlotId, 12)
    else
        Suffix := SubStr(SlotId, InStr(SlotId, "_") + 1)
    ; Map special suffix names to AHK key strings
    static _SpecialMap := Map(
        "space", "{Space}", "enter", "{Enter}",
        "period", ".", "comma", ",", "sc029", "SC029"
    )
    if _SpecialMap.Has(Suffix)
        return Mod . _SpecialMap[Suffix]
    return Mod . Suffix
}

; Read per-slot action overrides from [ahk.shortcuts.keyboard] in the v2 config TOML.
ReadKeyboardShortcutsConfig() {
    global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache, GESTURE_ACTIONS
    LoggerStart("KeyboardShortcuts", "Chargement des raccourcis clavier configurables…")
    ; Seed with defaults first
    for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
        KeyboardShortcutAssignments[Slot] := Action
    ; Apply any user overrides persisted in the TOML
    OverrideCount := 0
    for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
        Value := IniCacheGet(_IniCache, "ahk.shortcuts.keyboard", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value))) {
            KeyboardShortcutAssignments[Slot] := Value
            OverrideCount++
            LoggerDebug("KeyboardShortcuts", "TOML override: '%s' → '%s'.", Slot, Value)
        }
    }
    LoggerSuccess("KeyboardShortcuts", "Keyboard shortcuts loaded (%d default(s), %d override(s)).",
        KEYBOARD_SHORTCUT_DEFAULTS.Count, OverrideCount)
}

; Execute the configured action for a keyboard shortcut slot.
RunKeyboardShortcutAction(SlotId) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    Action := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
    if (Action == "none" or !GESTURE_ACTIONS.Has(Action)) {
        LoggerDebug("KeyboardShortcuts", "Shortcut '%s' skipped (action: '%s').", SlotId, Action)
        return
    }
    LoggerDebug("KeyboardShortcuts", "Shortcut '%s' → '%s' triggered.", SlotId, Action)
    GESTURE_ACTIONS[Action].Fn.Call()
}

; Persist a slot assignment and reload.
SetKeyboardShortcutAction(SlotId, ActionName) {
    global KeyboardShortcutAssignments, ConfigurationFile
    KeyboardShortcutAssignments[SlotId] := ActionName
    TOML_Write(ActionName, ConfigurationFile, "ahk.shortcuts.keyboard", SlotId)
    Reload
}

_MakeKeyboardShortcutHandler(SlotId, ActionName) {
    return (*) => SetKeyboardShortcutAction(SlotId, ActionName)
}

; Convert a slot id to a human-readable label: "ctrl_shift_a" → "Ctrl + Shift + A".
_FormatSlotLabel(SlotId) {
    static _ModLabels := Map(
        "ctrl_shift_", "Ctrl + Shift + ",
        "ctrl_",       "Ctrl + ",
        "win_",        "Win + ",
        "alt_",        "Alt + ",
    )
    static _KeyNames := Map(
        "space",  "Espace",
        "enter",  "Entrée",
        "period", ".",
        "comma",  ",",
        "sc029",  "²",
    )
    for Prefix, ModLabel in _ModLabels {
        if (SubStr(SlotId, 1, StrLen(Prefix)) = Prefix) {
            Suffix := SubStr(SlotId, StrLen(Prefix) + 1)
            Key := _KeyNames.Has(Suffix) ? _KeyNames[Suffix] : StrUpper(Suffix)
            return ModLabel . Key
        }
    }
    return SlotId
}

; Build the "⌨️ Raccourcis clavier" submenu.
; Inserts the four keyboard shortcut groups (Win/Ctrl/Ctrl+Shift/Alt) into
; TargetMenu just before the item named InsertBefore.
; Each group shows only assigned slots plus an "Ajouter…" item.
; Clicking any item opens a lightweight GUI picker — no nested submenus built
; up-front (which caused ~2 min load time on a 300+ slot map).
InsertKeyboardShortcutGroups(TargetMenu, InsertBefore) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    LoggerStart("KeyboardShortcutsMenu", "Insertion des groupes de raccourcis clavier…")

    _Groups := [
        Map("prefix", "alt_",        "label", t("menu.shortcuts.alt_group"),        "add_label", t("menu.shortcuts.alt_add")),
        Map("prefix", "ctrl_",       "label", t("menu.shortcuts.ctrl_group"),       "add_label", t("menu.shortcuts.ctrl_add")),
        Map("prefix", "ctrl_shift_", "label", t("menu.shortcuts.ctrl_shift_group"), "add_label", t("menu.shortcuts.ctrl_shift_add")),
        Map("prefix", "win_",        "label", t("menu.shortcuts.win_group"),        "add_label", t("menu.shortcuts.win_add")),
    ]

    ; Build all group menus first, then insert in reverse order so the final
    ; menu order matches _Groups (Insert always places before InsertBefore).
    AssignedCount := 0
    GroupMenus := []
    for GroupInfo in _Groups {
        Prefix   := GroupInfo["prefix"]
        GLabel   := GroupInfo["label"]
        AddLabel := GroupInfo["add_label"]
        GMenu    := Menu()

        ; Only show slots that have a non-none assignment
        for Slot, Action in KeyboardShortcutAssignments {
            if (SubStr(Slot, 1, StrLen(Prefix)) != Prefix)
                continue
            ; Ensure exact prefix match — e.g. "ctrl_shift_v" must not appear under "ctrl_"
            ; because "ctrl_shift_" is a longer prefix that matches first.
            IsExactPrefix := true
            for OtherGroup in _Groups {
                OtherPrefix := OtherGroup["prefix"]
                if (OtherPrefix != Prefix and StrLen(OtherPrefix) > StrLen(Prefix)
                    and SubStr(Slot, 1, StrLen(OtherPrefix)) == OtherPrefix) {
                    IsExactPrefix := false
                    break
                }
            }
            if !IsExactPrefix
                continue
            if (Action == "none")
                continue
            ActionLabel := GESTURE_ACTIONS.Has(Action) ? _GestureActionLabel(Action) : Action
            SlotDisplay := _FormatSlotLabel(Slot) . " : " . ActionLabel
            GMenu.Add(SlotDisplay, ((_s) => (*) => ShowKeyboardShortcutPicker(_s))(Slot))
            AssignedCount++
        }

        ; "Add shortcut" item — opens picker with full slot list for this prefix
        GMenu.Add(AddLabel, ((_p) => (*) => ShowKeyboardSlotPicker(_p))(Prefix))

        GroupMenus.Push(Map("label", GLabel, "menu", GMenu))
    }

    ; Insert separator first (it ends up just before the block after reversal)
    TargetMenu.Insert(InsertBefore)
    ; Insert groups in reverse so final order is Alt / Ctrl / Ctrl+Shift / Win
    loop GroupMenus.Length {
        Idx := GroupMenus.Length - A_Index + 1
        TargetMenu.Insert(InsertBefore, GroupMenus[Idx]["label"], GroupMenus[Idx]["menu"])
    }

    LoggerSuccess("KeyboardShortcutsMenu", "Groups inserted (%d active shortcut(s)).", AssignedCount)
}

; Open a two-step GUI: first pick the key slot, then pick the action.
; Called when the user clicks "Ajouter…" for a modifier group.
ShowKeyboardSlotPicker(Prefix) {
    global GESTURE_ACTIONS

    ; Collect all valid slots for this prefix from GESTURE_ACTIONS
    Slots := []
    static _SpecialOrder := ["space", "enter", "period", "comma", "sc029"]
    ; Letters first (a-z)
    Letters := "abcdefghijklmnopqrstuvwxyz"
    loop StrLen(Letters) {
        L := SubStr(Letters, A_Index, 1)
        SlotId := Prefix . L
        if GESTURE_ACTIONS.Has(SlotId)
            Slots.Push(SlotId)
    }
    ; Digits 0-9
    loop 10 {
        D := SubStr("0123456789", A_Index, 1)
        SlotId := Prefix . D
        if GESTURE_ACTIONS.Has(SlotId)
            Slots.Push(SlotId)
    }
    ; Special keys
    for Sk in _SpecialOrder {
        SlotId := Prefix . Sk
        if GESTURE_ACTIONS.Has(SlotId)
            Slots.Push(SlotId)
    }

    if (Slots.Length = 0)
        return

    ; Build display labels for the ListBox
    SlotLabels := []
    for SlotId in Slots
        SlotLabels.Push(_GestureActionLabel(SlotId))

    W := Gui("+AlwaysOnTop", t("dialog.keyboard_shortcut.title_prefix") . Prefix)
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12
    W.Add("Text", "xm", t("dialog.keyboard_shortcut.prompt"))
    LB := W.Add("ListBox", "xm w320 r16", SlotLabels)
    W.Add("Button", "xm w80", t("button.ok")).OnEvent("Click", PickSlot)
    W.Add("Button", "x+6 w80", t("button.cancel")).OnEvent("Click", (*) => W.Destroy())
    W.Show()

    PickSlot(*) {
        Idx := LB.Value
        if (Idx = 0)
            return
        W.Destroy()
        ShowKeyboardShortcutPicker(Slots[Idx])
    }
}

; Generic action picker GUI — shows a searchable list of all available actions.
; Title     : window title string
; Current    : currently assigned action id (or "none")
; OnConfirm  : callback(ActionId) called when the user validates their pick
; ShowNative : when true, prepend a "Natif" entry (id="") that clears the tap action
ShowActionPicker(Title, Current, OnConfirm, ShowNative := false) {
    global GESTURE_ACTION_NAMES, GESTURE_ACTIONS
    LoggerStart("ActionPicker", "Opening action picker '%s'…", Title)

    ; Build the source data: parallel arrays of ids and display labels.
    ; Category headers are stored with id="" so ConfirmPick can ignore them.
    ; AllItems holds {Id, Label, Cat} for re-filtering with category re-injection.
    AllItems    := []  ; [{Id, Label, Cat}] — action rows only (no header rows)

    _PushItem(Id, Label, Cat) {
        AllItems.Push({ Id: Id, Label: Label, Cat: Cat })
    }

    ; "Natif" entry — only for tap-hold pickers where the physical key behaviour is meaningful
    if ShowNative
        _PushItem("__native__", t("tap_hold.tap.none"), "")
    ; "∅ Rien" entry — absorbs the tap (no-op action), always before any group
    _PushItem("none", t("dialog.action_picker.disabled"), "")

    CurrentCat := ""
    for ActionName in GESTURE_ACTION_NAMES {
        if (ActionName == "--")
            continue
        ; "none" is already pushed above — skip it to avoid a duplicate entry
        if (ActionName == "none")
            continue
        if (SubStr(ActionName, 1, 1) = "#") {
            ; Header keys are i18n keys (e.g. "#mouse_nav" → "sg_actions.sg_order.header.mouse_nav").
            ; The i18n value itself starts with "#" (e.g. "#Souris et Navigation") — strip it.
            local TranslatedHeader := t("sg_actions.sg_order.header." . SubStr(ActionName, 2))
            CurrentCat := SubStr(TranslatedHeader, 1, 1) = "#" ? SubStr(TranslatedHeader, 2) : TranslatedHeader
            continue
        }
        if !GESTURE_ACTIONS.Has(ActionName)
            continue
        _PushItem(ActionName, _GestureActionLabel(ActionName), CurrentCat)
    }

    ; Rebuilds the ListBox from a filtered subset of AllItems, injecting
    ; category headers before the first item of each group.
    ; Returns the parallel FilteredIds array for ConfirmPick lookups.
    BuildListRows(Items) {
        Ids    := []
        Labels := []
        LastCat := Chr(0)  ; sentinel that can't match any real category
        for Item in Items {
            if (Item.Cat != "" and Item.Cat != LastCat) {
                Ids.Push("")              ; header is not selectable
                Labels.Push("▸ " . Item.Cat)
                LastCat := Item.Cat
            }
            Ids.Push(Item.Id)
            Labels.Push("    " . Item.Label)
        }
        return { Ids: Ids, Labels: Labels }
    }

    Rows        := BuildListRows(AllItems)
    FilteredIds := Rows.Ids

    ; Pre-select current action ("" means native → map to __native__ sentinel for lookup)
    SelectedIdx := 0
    LookupId    := (Current == "") ? "__native__" : Current
    for i, Id in FilteredIds {
        if (Id == LookupId) {
            SelectedIdx := i
            break
        }
    }

    W := Gui("+AlwaysOnTop", Title)
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12
    W.Add("Text", "xm", t("dialog.action_picker.label"))

    SearchEdit  := W.Add("Edit", "xm w340")
    LB          := W.Add("ListBox", "xm w340 r20", Rows.Labels)
    if (SelectedIdx > 0)
        LB.Choose(SelectedIdx)

    W.Add("Button", "xm w80", t("button.ok")).OnEvent("Click", ConfirmPick)
    W.Add("Button", "x+6 w80", t("button.cancel")).OnEvent("Click", (*) => W.Destroy())
    W.Show()

    SearchEdit.OnEvent("Change", FilterList)

    FilterList(*) {
        Query       := StrLower(SearchEdit.Value)
        Matched     := []
        if (Query == "") {
            Matched := AllItems
        } else {
            for Item in AllItems {
                if InStr(StrLower(Item.Label), Query)
                    Matched.Push(Item)
            }
        }
        NewRows     := BuildListRows(Matched)
        FilteredIds := NewRows.Ids
        LB.Delete()
        LB.Add(NewRows.Labels)
        ; Skip headers when pre-selecting first result
        for i, Id in FilteredIds {
            if (Id != "") {
                LB.Choose(i)
                break
            }
        }
    }

    ConfirmPick(*) {
        Idx := LB.Value
        if (Idx = 0)
            return
        ChosenId := FilteredIds[Idx]
        ; Ignore clicks on category headers (id="" marks a non-selectable header row)
        if (ChosenId == "")
            return
        W.Destroy()
        ; "__native__" sentinel clears the tap action so the key passes through to the OS
        ResolvedId := (ChosenId == "__native__") ? "" : ChosenId
        LoggerSuccess("ActionPicker", "Selection confirmed → '%s'.", ResolvedId)
        OnConfirm(ResolvedId)
    }
}

; Open a GUI to pick an action for a keyboard shortcut slot.
; Used both from the "Ajouter…" flow and from clicking an existing slot.
ShowKeyboardShortcutPicker(SlotId) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    Current      := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
    SlotDisplay  := _GestureActionLabel(SlotId)
    ShowActionPicker(t("dialog.keyboard_shortcut.title_prefix") . SlotDisplay, Current, (Id) => SetKeyboardShortcutAction(SlotId, Id))
}

FilePathsEditor(*) {
    global _ConfigDir, _PathsFile

    W := Gui(, t("dialog.config_folder.title"))
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12

    W.Add("Text", "xm", t("dialog.config_folder.label"))
    ; Display path with forward slashes for readability
    DirEdit := W.Add("Edit", "xm w480", StrReplace(_ConfigDir, "\", "/"))
    W.Add("Button", "x+6 w80", t("common.browse")).OnEvent("Click", BrowseDir)

    W.Add("Text", "xm y+14 cGray", t("dialog.config_folder.hint"))

    W.Add("Button", "xm y+10 w80", t("button.ok")).OnEvent("Click", SaveConfigDir)
    W.Add("Button", "x+6 w80", t("common.cancel")).OnEvent("Click", (*) => W.Destroy())

    BrowseDir(*) {
        ; Start from the current field value if it exists, otherwise fall back to
        ; My Documents so the dialog opens somewhere useful rather than the script root.
        StartDir := StrReplace(Trim(DirEdit.Value), "/", "\")
        if (StartDir == "" or !DirExist(StartDir)) {
            StartDir := A_MyDocuments
        }
        Selected := DirSelect("*" . StartDir, 1, t("dialog.config_folder.select_title"))
        if (Selected != "") {
            Selected := StrReplace(Selected, "\", "/")
            if !RegExMatch(Selected, "/$")
                Selected .= "/"
            DirEdit.Value := Selected
        }
    }

    SaveConfigDir(*) {
        global _ConfigDir, _DefaultConfigDir, _PathsFile, ScriptInformation, ConfigurationFile

        NewDir := StrReplace(Trim(DirEdit.Value), "/", "\")
        if (NewDir == "") {
            NewDir := _DefaultConfigDir
        } else if !RegExMatch(NewDir, "\\$") {
            NewDir .= "\"
        }

        W.Destroy()

        if (NewDir == _ConfigDir)
            return

        ; Persist the new config dir into paths.toml
        ; Ensure the parent folder exists — in compiled mode _PathsFile lives in
        ; %APPDATA%\Ergopti\ which may not have been created yet on this machine.
        try DirCreate(SubStr(_PathsFile, 1, InStr(_PathsFile, "\", , -1) - 1))
        try {
            f := FileOpen(_PathsFile, "w", "UTF-8")
            if f {
                DefaultDirFwd := StrReplace(_DefaultConfigDir, "\", "/")
                NewDirFwd := StrReplace(NewDir, "\", "/")
                f.Write("# Custom paths — auto-generated by ErgoptiPlus.`r`n")
                f.Write("# Edit this file to point to your personal configuration folder.`r`n")
                f.Write("# If absent or commented out, files are looked up in: " . DefaultDirFwd . "`r`n")
                f.Write("`r`n")
                if (NewDir != _DefaultConfigDir) {
                    f.Write('ConfigDirPath = "' . NewDirFwd . '"`r`n')
                } else {
                    f.Write('# ConfigDirPath = "' . DefaultDirFwd . '"`r`n')
                }
                f.Close()
            }
        }

        Reload
    }

    W.Show("Center")
}

ActivateEdit(*) {
    Edit
}

ToggleSuspend(*) {
    global _LastSuspendState, _ALTGR_KANA_FIXUP
    if A_IsSuspended {
        Suspend(0)
    } else {
        ; Keyboard-combo pause: SC138 (the Kana AltGr prefix) is physically held.
        ; Wait for it to lift BEFORE suspending so the still-live AltGr layer sees
        ; the release and clears its custom-combination prefix flag. Suspending
        ; while SC138 is down strands that flag set — its release then lands while
        ; the layer is disarmed — surfacing as « AltGr bloqué » after a menu/gesture
        ; resume. A synthetic tap cannot clear it (only a real release does), so we
        ; prevent the latch here instead. The guard makes a menu/gesture pause
        ; (SC138 already up) suspend with no delay; T1 bounds the wait so a stuck
        ; key can never hang the toggle.
        if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP and GetKeyState("SC138", "P")) {
            KeyWait("SC138", "T1")
        }
        Suspend(1)
    }
    UpdateTrayIcon()
    ; Drive the pause reactor from the authoritative toggle. _LastSuspendState is
    ; updated here too so the watchdog (which catches transitions that bypass
    ; this function) sees the new state and does not double-fire the handlers.
    _LastSuspendState := A_IsSuspended
    if A_IsSuspended {
        Ergopti_OnSuspendEnter()
    } else {
        Ergopti_OnSuspendResume()
    }
    LoggerInfo("ErgoptiPlus", "Suspend toggled: {1}.", A_IsSuspended ? "ON" : "OFF")
}

; Pause reactor — entered when the script becomes suspended. Native Suspend only
; disarms hotkeys/hotstrings; every InputHook, timer and OnMessage keeps running,
; so the user still sees tooltips, LLM predictions, the WPM widget, etc. The
; per-callback ``if A_IsSuspended`` guards stop NEW activity; this handler tears
; down whatever was already live so the paused state is truly « AHK éteint ».
Ergopti_OnSuspendEnter() {
    try TooltipHide("Suspend", true)
    try LLM_Tooltip_Hide(true)
    try LLM_Engine_CancelTimer()
}

; Pause reactor — entered when the script resumes. The guards simply stop
; early-returning once A_IsSuspended is false and the WPM tick repaints itself,
; so the only cleanup needed is to drop any stale prefix-watcher context so
; typing restarts at a clean word boundary instead of matching pre-pause input.
Ergopti_OnSuspendResume() {
    if IsSet(_ResetPrefixBuffer) {
        try _ResetPrefixBuffer()
    }
}

; Catches suspend transitions that bypass ToggleSuspend (a native Pause/Suspend
; command, an external trigger, the AltGr+Enter pause-bug edge) and runs the same
; reactor so « pause = tout éteint » holds no matter how suspend was toggled.
; Timer callbacks are never affected by Suspend, so this keeps polling while
; suspended — exactly what is needed to detect the resume edge.
_SuspendStateWatchdog() {
    global _LastSuspendState
    if (A_IsSuspended == _LastSuspendState) {
        return
    }
    _LastSuspendState := A_IsSuspended
    UpdateTrayIcon()
    if A_IsSuspended {
        Ergopti_OnSuspendEnter()
    } else {
        Ergopti_OnSuspendResume()
    }
}

UpdateTrayIcon() {
    ; The Suspend entry now lives directly on the tray menu; tick/untick it
    ; there since the old ScriptMgmtMenu submenu was flattened away.
    if A_IsSuspended {
        A_TrayMenu.Check(MenuSuspend)
        if FileExist(IconPathDisabled) {
            TraySetIcon(IconPathDisabled, , True)
        }
    } else {
        A_TrayMenu.Uncheck(MenuSuspend)
        if FileExist(IconPath) {
            TraySetIcon(IconPath)
        }
    }
}

ActivateReload(*) {
    LoggerInfo("ErgoptiPlus", "User-triggered reload.")
    Reload
}

ActivateExitApp(*) {
    LoggerInfo("ErgoptiPlus", "User-triggered ExitApp.")
    ExitApp
}

WindowSpy(*) {
    ; Get the directory containing the AHK executable
    SplitPath(A_AhkPath, , &ahkDir)

    ; Go up one directory
    SplitPath(ahkDir, , &parentDir)

    ; Build the path to WindowSpy.ahk
    spyPath := parentDir "\WindowSpy.ahk"

    ; Run the script if found
    if FileExist(spyPath) {
        Run(spyPath)
    } else {
        MsgBox(Format(t("ergopti.windowspy_not_found"), spyPath))
    }
}

ActivateListVars(*) {
    ListVars
}

ActivateKeyHistory(*) {
    KeyHistory
}

; Opens a blocking dialog that displays the full healthcheck report.
; Wired to the "Healthcheck" item in the Debug submenu of the tray menu.
ShowHealthCheck(*) {
    HealthCheck_ShowWindow()
}

; ================================================
; ======= 1.5) Script management shortcuts =======
; ================================================

; We use GetKeyState("SC138", "P") to make sure the AltGr key is pressed
; It avoids a bug where AltGr + Enter pauses the script, but then pressing BackSpace alone triggers a reload
; This bug for example happens if the keyboard layout is QWERTY

; Each combo double-checks both keys with GetKeyState — works around an
; AltGr+Enter quirk on some QWERTY layouts where pressing BackSpace alone
; would otherwise replay a stale AltGr+BackSpace event and reload the script.

; The four script-management combos below are registered DYNAMICALLY at the
; end of the auto-execute section via _RegisterScriptAltGrHotkeys(). Defining
; them as static ``SC138 & X::`` blocks here would have AHK promote SC138 to a
; prefix key at parse time — and the prefix status is parse-time-only, so it
; would persist even after our onboarding ``IsRealAltGrPress`` short-circuit
; made every variant evaluate false. With the registration happening after
; Onboarding_Run returns, SC138 stays a vanilla key for the whole duration of
; the first-run wizard, restoring native AltGr/Kana behaviour in the wizard's
; Edit boxes (and anywhere else the user types while it is up).

; Handler bodies stay as named functions so the dynamic Hotkey() calls only
; reference them. Each handler double-checks the modifier state via
; GetKeyState — same defensive guard as the original blocks — so a stale
; AltGr+key ghost cannot replay the action on the next isolated keystroke.
; After RunScriptShortcutAction returns (for actions that do — e.g. the pause
; toggle), ResetScriptComboKeys waits for the suffix to lift then clears the
; SC138/Kana prefix, so the combo neither leaks its key into the app nor leaves
; AltGr stuck. Reload/ExitApp actions never return, so the reset is skipped —
; a fresh process (or a closed one) has no latched prefix to clear anyway.
_ScriptAltGrEnterHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC01C", "P")) {
        RunScriptShortcutAction("script_altgr_enter")
        ResetScriptComboKeys("SC01C")
    } else {
        SendInput("{Enter}")
    }
}

_ScriptAltGrBackSpaceHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC00E", "P")) {
        RunScriptShortcutAction("script_altgr_backspace")
        ResetScriptComboKeys("SC00E")
    } else {
        SendInput("{BackSpace}")
    }
}

_ScriptAltGrDeleteHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC153", "P")) {
        RunScriptShortcutAction("script_altgr_delete")
        ResetScriptComboKeys("SC153")
    } else {
        SendInput("{Delete}")
    }
}

_ScriptAltGrEscapeHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC001", "P")) {
        RunScriptShortcutAction("script_altgr_escape")
        ResetScriptComboKeys("SC001")
    } else {
        SendInput("{Escape}")
    }
}

; Registration entry point. Called once Onboarding_Run() has returned so the
; wizard never sees SC138 as a prefix key. Each Hotkey() inherits the HotIf
; criterion set immediately before, which mirrors what the previous static
; ``#HotIf IsRealAltGrPress()`` block established.
_RegisterScriptAltGrHotkeys() {
    ; HotIf() expects a callable of the form Callback(HotkeyName), so passing
    ; the bare ``IsRealAltGrPress`` reference fails with "Invalid callback
    ; function" — that helper takes no parameters. Wrap it in a varargs lambda
    ; so AHK can hand it the hotkey name without tripping the signature check.
    ; "S" option = suspend-exempt: the script-management combos must keep
    ; firing while AHK is suspended, otherwise the user cannot unsuspend the
    ; script after pressing AltGr+Enter once (the pause toggle disables itself).
    HotIf((*) => IsRealAltGrPress())
    Hotkey("RAlt & Enter",     _ScriptAltGrEnterHandler,     "I2 S")
    Hotkey("SC138 & SC01C",    _ScriptAltGrEnterHandler,     "I2 S")
    Hotkey("RAlt & BackSpace", _ScriptAltGrBackSpaceHandler, "I2 S")
    Hotkey("SC138 & SC00E",    _ScriptAltGrBackSpaceHandler, "I2 S")
    Hotkey("RAlt & Delete",    _ScriptAltGrDeleteHandler,    "I2 S")
    Hotkey("SC138 & SC153",    _ScriptAltGrDeleteHandler,    "I2 S")
    Hotkey("RAlt & Escape",    _ScriptAltGrEscapeHandler,    "I2 S")
    Hotkey("SC138 & SC001",    _ScriptAltGrEscapeHandler,    "I2 S")
    HotIf()

    ; Suspend fallback. A pause toggled from anywhere other than the combo's own
    ; hook thread (tray-menu « Suspendre », a gesture) rebuilds the keyboard hook
    ; with the SC138/RAlt custom-combination prefix left un-armed, so the
    ; ``SC138 & X`` combos above silently stop firing and the script can no longer
    ; be un-paused from the keyboard. Re-detect the same chords as PLAIN SUFFIX
    ; hotkeys gated on « suspended AND SC138 physically held »: a suffix hotkey
    ; needs no prefix arming, so the menu-thread rebuild cannot break it, and it
    ; never re-registers an SC138 prefix so it cannot latch the Kana key. They
    ; reuse the existing handlers; the GetKeyState in the HotIf guarantees SC138
    ; is down, so a lone Enter/BackSpace/Delete/Escape while paused is untouched
    ; (HotIf false → native key). When the prefix IS armed (a keyboard pause) the
    ; ``SC138 & X`` combo takes precedence, so these never double-fire.
    HotIf((*) => A_IsSuspended and GetKeyState("SC138", "P"))
    Hotkey("SC01C", _ScriptAltGrEnterHandler,     "I2 S")
    Hotkey("SC00E", _ScriptAltGrBackSpaceHandler, "I2 S")
    Hotkey("SC153", _ScriptAltGrDeleteHandler,    "I2 S")
    Hotkey("SC001", _ScriptAltGrEscapeHandler,    "I2 S")
    HotIf()
}

; Auto-execute hook: at this point Onboarding_Run() has long since returned
; (line ~395 of the auto-exec section), so registering the SC138-prefixed
; combos now is safe — the first-run wizard ran with SC138 still acting as a
; vanilla key.
_RegisterScriptAltGrHotkeys()

; =======================================================
; =======================================================
; =======================================================
; ================ 2/ PERSONAL SHORTCUTS ================
; =======================================================
; =======================================================
; =======================================================

; personal_shortcuts.ahk is included earlier (before menu build) so
; Features["Personal"] is populated before InitSubMenus/initMenu run.
; TOML hotstrings are loaded here with maximum priority so they shadow any
; conflicting built-in entry (registered before the layout section below).
if Features.Has("hotstrings") and Features["hotstrings"].Has("personal") {
    for SectionName, SectionConfig in Features["hotstrings"]["personal"] {
        if !(IsObject(SectionConfig) and Type(SectionConfig) == "Map") {
            continue
        }
        if !(SectionConfig.Has("enabled") and SectionConfig["enabled"]) {
            continue
        }
        ; v2 Personal keys are already the lowercase TOML section names — no
        ; FoldAsciiLower needed. LoadHotstringsSection accepts v2 Maps directly
        ; (it converts internally to the v1-shape object the regex/fast paths
        ; expect).
        LoadHotstringsSection("personal", SectionName, SectionConfig)
    }
}

#InputLevel 2 ; Very important, we need to be at a higher InputLevel to remap the keys into something else.
; It is because we will then remap keys we just remapped, so the InputLevel of those other shortcuts must be lower.
; This is especially important for the "★" key, otherwise the hotstrings involving this key won't trigger.
#Include modules/layout.ahk
#Include modules/shortcuts.ahk
#Include modules/tap_holds.ahk
#Include modules/hotstrings.ahk

; Hotstrings are now registered — start the prefix watcher so typing a
; partial trigger surfaces a tinted tooltip preview (parity with the
; Hammerspoon driver). The watcher reads its own copy of the TOML registry,
; so it works regardless of whether the fast-path generated loader or the
; regex parser was used to register the live hotstrings.
HotstringPrefixWatcherInit()

; Final lifecycle marker — all hotkeys and hotstrings are registered, the
; script is ready to handle keystrokes. A missing SUCCESS in the log file
; pinpoints which #Include above failed silently.
LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")





; =========================================
; =========================================
; ======= 99/ Keyboard layout watch =======
; =========================================
; =========================================

; Polls the foreground keyboard layout once per second. WM_INPUTLANGCHANGE
; only reaches the focused window, so polling is the simplest cross-process
; signal. A change means SC138 may have flipped between RAlt and Kana, and
; #HotIf gates / _ALTGR_KANA_FIXUP must re-resolve. Reload() is the
; cheapest way to guarantee every dependent global, hotkey and BoundFunc
; reflects the new layout — partial in-place updates would be brittle.
global _LAYOUT_POLL_INTERVAL_MS := 1000
global _LAST_KEYBOARD_HKL := GetForegroundKeyboardLayout()

CheckKeyboardLayoutChange() {
    global _LAST_KEYBOARD_HKL
    HKL := GetForegroundKeyboardLayout()
    if (HKL = 0 or HKL = _LAST_KEYBOARD_HKL) {
        return
    }
    try LoggerInfo("LayoutWatch",
        "Keyboard layout changed (0x{1:X} → 0x{2:X}) — reloading script.",
        _LAST_KEYBOARD_HKL, HKL)
    _LAST_KEYBOARD_HKL := HKL
    Reload()
}

SetTimer(CheckKeyboardLayoutChange, _LAYOUT_POLL_INTERVAL_MS)
