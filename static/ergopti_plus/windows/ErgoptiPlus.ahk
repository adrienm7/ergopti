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
    for _, ModKey in ["LControl", "RControl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin"] {
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
#Include lib/boot_profiler.ahk
#Include lib/hotpath_profiler.ahk
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
#Include lib/hotstrings/hotstring_live_toggle.ahk
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
#Include lib/wrap_symbols_config.ahk
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
#Include _generated/prompt_builder.ahk
#Include modules/llm/api_common.ahk
#Include modules/llm/api_token_crypto.ahk
#Include modules/llm/api_ollama.ahk
#Include modules/llm/parser.ahk
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
; Load the user's wrap-symbol state (disabled set + custom pairs).
; Must come before HotstringPrefixWatcherInit so _WS_ACTIVE_PAIRS is populated
; before the InputHook starts intercepting keystrokes.
WrapSymbols_Init(_ConfigDir)
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
    "script_altgr_backspace", "script_reload",
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
for _, _Slot in SCRIPT_SHORTCUT_SLOTS {
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
    ; Per-TOML-file hotstring sub-category gates. Independent of the top
    ; Hotstrings master above: a category file can be switched off while the
    ; rest of the hotstrings stay live. The parent menu checkmark for each
    ; category follows ITS gate (not whether every section is checked), and
    ; ApplyMasterGatesToFeatures zeroes only that category's features when off.
    ; Default on so existing configs and fresh installs are unchanged.
    "Autocorrection",     true,
    "DistancesReduction", true,
    "SFBsReduction",      true,
    "Rolls",              true,
    "MagicKey",           true,
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
; Boot phase profiling — emits one INFO line per phase so a slow start can be
; diagnosed from the log alone (see lib/boot_profiler.ahk).
BootProfile_Begin()

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
; Uses a global cache to avoid redundant calculations during menu build.
CountDynamicSection(SectionName) {
    global PersonalInformation, _TomlCountCache
    CacheKey := "dynamic|" . StrLower(SectionName)
    if _TomlCountCache.Has(CacheKey)
        return _TomlCountCache[CacheKey]

    Phone := PersonalInformation["phone_number"]
    FPhone := PersonalInformation["phone_number_clean"]
    Ssn := PersonalInformation["social_security_number"]
    Iban := PersonalInformation["iban"]
    SsnRaw := StrReplace(Ssn, " ", "")
    IbanRaw := StrReplace(Iban, " ", "")

    Count := 0
    switch SectionName {
        case "DateFr", "DateLongFr", "Date", "date_fr", "date_long_fr", "date":
            Count := 1
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
            Count := N
        case "SsnPrefixes", "ssn_prefixes":
            ; No-space + spaced triggers — both fire when ssn_raw has >= 5 digits
            Count := StrLen(SsnRaw) >= 5 ? 2 : 0
        case "IbanPrefixes", "iban_prefixes":
            ; 6 raw chars (no-space) and 7-char spaced trigger if iban_raw has >= 6 chars
            Count := StrLen(IbanRaw) >= 6 ? 2 : 0
        case "TextExpansionPersonalInformation", "text_expansion_personal_information":
            N := 0
            for Key, Val in PersonalInformation {
                if (Val != "")
                    N++
            }
            Count := N
    }
    _TomlCountCache[CacheKey] := Count
    return Count
}

; Safe nested read
_SpaceAroundSymbolsNode := (Features.Has("hotstrings")
	and Features["hotstrings"].Has("distances_reduction")
	and Features["hotstrings"]["distances_reduction"].Has("space_around_symbols"))
	? Features["hotstrings"]["distances_reduction"]["space_around_symbols"]
	: Map()
global SpaceAroundSymbols := (_SpaceAroundSymbolsNode.Has("enabled") and _SpaceAroundSymbolsNode["enabled"]) ? " " : ""

#Include ui/tray_menu.ahk

RegisterPersonalFeature(Name, DefaultEnabled := false, Description := "") {
    global _PersonalShortcutsRegistry, Features
    Name := StrLower(Name)
    if !_PersonalShortcutsRegistry.Has(Name) {
        _PersonalShortcutsRegistry[Name] := Description
        Found := false
        for _, Item in _PersonalShortcutsRegistry["__Order"] {
            if Item == Name {
                Found := true
                break
            }
        }
        if !Found {
            _PersonalShortcutsRegistry["__Order"].Push(Name)
        }
    }
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

PersonalFeatureEnabled(name) {
    global Features
    name := StrLower(name)
    try {
        return Features["shortcuts"]["personal"][name] = true
    } catch {
        return false
    }
}

EnsurePersonalShortcutsFile(Path) {
    global PERSONAL_SHORTCUTS_TEMPLATE
    if (!IsSet(Path) or Type(Path) != "String" or Path == "") {
        try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile called with empty Path — skipping.")
        return
    }
    FileWasCreated := false
    if !FileExist(Path) {
        try {
            Dir := RegExReplace(Path, "\\[^\\]+$", "")
            if (Dir != "" and !DirExist(Dir)) {
                DirCreate(Dir)
            }
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
    if FileWasCreated or !StubMatches {
        try LoggerInfo("ErgoptiPlus", "Reloading to pick up freshly-written personal shortcuts chain.")
        Reload
    }
}

try {
    EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"])
} catch as _epsErr {
    try LoggerError("ErgoptiPlus", "EnsurePersonalShortcutsFile failed: {1}.", _epsErr.Message)
}
#InputLevel 2
#Include *i _generated/personal_shortcuts.ahk
#Include *i %A_LocalAppData%\Ergopti\_generated\personal_shortcuts.ahk
#Include %A_ScriptDir%
#InputLevel 0
; Capture the un-gated per-section hotstring Features BEFORE gating, so a live
; category toggle (ToggleCategoryAllFeatures) can restore a category's sections on
; re-enable. Declared + populated here, before gating, so the auto-execute thread
; never re-inits the Map after filling it.
global _HSCategorySnapshot := Map()
try _HSSnapshotAllCategories()
ApplyMasterGatesToFeatures()

#Include modules/gestures.ahk
ReadScriptShortcutsConfig()
ReadKeyboardShortcutsConfig()

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

CS_Load()
global _SaveFullConfigReady := true
global _ParseExtTomlSectionsCache := Map()
if MetricsShortcuts.enabled
    WPMWidget_LoadConfig(_IniCache)

BootProfile_Mark("Config, features & shortcuts loaded")
InitSubMenus()
initMenu()
BootProfile_Mark("MENU/initMenu returned (pre tray icon)")
UpdateTrayIcon()
BootProfile_Mark("Tray menu + icon built")
SetTimer(SaveFullConfig, -500)

if MetricsShortcuts.enabled {
    LoggerDebug("Startup", "Metrics enabled — WPMWidget.visible=%s, show_graph=%s.",
        WPMWidget.visible, WPMWidget.show_graph)
    if WPMWidget.visible
        WPMWidget_Show()
    if MetricsShortcuts.show_wpm_menubar
        SetTimer(WpmMenubar_Tick, 1000)
    KL_Init(_ConfigDir . "metrics")
    MS_ApplyAll(KLUI_ToggleTyping, KLUI_ToggleApps)
    HookDispatcher.Start()
    KL_Hook_Start()
    KL_Watchers_Start()
    KL_Mouse_Start()
    KL_Sensors_Start()
    KL_Topo_Start()
    KL_AV_Start()
    KL_Net_Start()
    KL_Clip_Start()
    KL_Roi_Start()
}

BootProfile_Mark("Metrics/keylogger started")
LoggerSuccess("ErgoptiPlus", "Tray menu built and icon set.")

_MakeOpenSectionFn(SecName) {
    return (*) => OpenPersonalEditor(SecName)
}

_SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu) {
    global _PrevDefaultLabel
    _EditorPrefSet("DefaultSection", SecName)
    DefaultSectionMenu.Uncheck(t("menu.hotstrings.default_none"))
    for _, SN in TomlData["sections_order"] {
        if (SN == "-")
            continue
        SD := TomlData["sections"][SN]
        try DefaultSectionMenu.Uncheck(SD["description"])
    }
    if (SecName == "") {
        DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
    } else if (TomlData["sections"].Has(SecName)) {
        DefaultSectionMenu.Check(TomlData["sections"][SecName]["description"])
    }
    NewLabel := (SecName == "") ? t("menu.hotstrings.default_none")
        : (TomlData["sections"].Has(SecName) ? TomlData["sections"][SecName]["description"] : SecName)
    try PersonalMenu.Rename(t("menu.hotstrings.default_category_prefix") . _PrevDefaultLabel,
        t("menu.hotstrings.default_category_prefix") . NewLabel)
    _PrevDefaultLabel := NewLabel
}

_MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu) {
    return (*) => _SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu)
}

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

_MakeOpenFileFn(FilePath) {
    return (*) => Run(FilePath)
}

_ParseExtTomlSections(FilePath) {
    global _ParseExtTomlSectionsCache
    if _ParseExtTomlSectionsCache.Has(FilePath)
        return _ParseExtTomlSectionsCache[FilePath]
    Result := []
    if !FileExist(FilePath) {
        _ParseExtTomlSectionsCache[FilePath] := Result
        return Result
    }
    Content := ReadTomlFile(FilePath)
    Q := Chr(34)
    SectionDescs := Map()
    SectionOrder := []
    InMetaSections := false
    loop parse, Content, "`n", "`r" {
        Trimmed := Trim(A_LoopField, " `t")
        if RegExMatch(Trimmed, "^\[([^\[\]]+)\]$", &HM) {
            InMetaSections := (Trim(HM[1]) == "_meta.sections")
            continue
        }
        if (SubStr(Trimmed, 1, 2) == "[[") {
            InMetaSections := false
            continue
        }
        if !InMetaSections
            continue
        if RegExMatch(Trimmed, '^([A-Za-z0-9_]+)\s*=\s*"((?:[^"\\]|\\.)*)"', &KM) {
            SectionKey := StrLower(KM[1])
            SectionDescs[SectionKey] := KM[2]
            SectionOrder.Push(SectionKey)
        }
    }
    SectionCounts := Map()
    CurSec := ""
    loop parse, Content, "`n", "`r" {
        Trimmed := Trim(A_LoopField, " `t")
        if RegExMatch(Trimmed, "^\[+([^\[\]]+)\]+$", &SecM) {
            CurSec := StrLower(Trim(SecM[1]))
            if (CurSec == "_meta" or CurSec == "_meta.sections") {
                CurSec := ""
            } else if !SectionCounts.Has(CurSec) {
                SectionCounts[CurSec] := 0
            }
            continue
        }
        if (CurSec != "" and Trimmed != "" and SubStr(Trimmed, 1, 1) != "#") {
            if RegExMatch(Trimmed, '^(?:"[^"]+"|[A-Za-z0-9_.-]+)\s*=') {
                SectionCounts[CurSec] := SectionCounts.Get(CurSec, 0) + 1
            }
        }
    }
    Seen := Map()
    for _, SecKey in SectionOrder {
        Seen[SecKey] := true
        Result.Push(Map("description", SectionDescs.Get(SecKey, SecKey), "count", SectionCounts.Get(SecKey, 0)))
    }
    OtherSections := []
    for SecKey, Count in SectionCounts {
        if !Seen.Has(SecKey)
            OtherSections.Push(SecKey)
    }
    _HS_BubbleSort(OtherSections)
    for _, SecKey in OtherSections {
        Result.Push(Map("description", SecKey, "count", SectionCounts[SecKey]))
    }
    _ParseExtTomlSectionsCache[FilePath] := Result
    return Result
}

_HS_BubbleSort(Array) {
	n := Array.Length
	if (n < 2)
		return
	Loop n - 1 {
		i := A_Index
		Loop n - i {
			j := A_Index
			if (StrCompare(Array[j], Array[j + 1], false) > 0) {
				Tmp := Array[j]
				Array[j] := Array[j + 1]
				Array[j + 1] := Tmp
			}
		}
	}
}

MagicKeyEditor(*) {
    GuiToShow := Gui_Create("+AlwaysOnTop", t("dialog.magic_key.title"))
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
    ; No Reload: the repeat key is a pure runtime flag the engine reads live
    ; (HSE_TryRepeatKey checks HSE_RepeatEnabled on every keystroke). Just
    ; rebuild the tray so the checkmark reflects the new state.
    RebuildTrayMenu()
}

PersonalInformationEditor(*) {
    GuiToShow := Gui(, t("dialog.personal_info.title"))
    UpdatedPersonalInformation := Map()
    ReverseLetters := Map()
    for k, v in PersonalInformationLetters
        ReverseLetters[v] := k
    for PersonalInformationKey, OldValue in PersonalInformation {
        TextToAdd := ""
        if ReverseLetters.Has(PersonalInformationKey)
            TextToAdd := " (@" . ReverseLetters[PersonalInformationKey] . ScriptInformation["MagicKey"] . ")"
        GuiToShow.SetFont("bold")
        GuiToShow.Add("Text", , PersonalInformationKey . TextToAdd)
        GuiToShow.SetFont("norm")
        NewValue := GuiToShow.Add("Edit", "w300", OldValue)
        UpdatedPersonalInformation[PersonalInformationKey] := NewValue
    }
    GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ProcessUserInput(GuiToShow, UpdatedPersonalInformation))
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
    if IsSet(Features) and Features.Has("shortcuts") and Features["shortcuts"].Has("gpt") and Features["shortcuts"]["gpt"].Has("link")
        CurrentLink := Features["shortcuts"]["gpt"]["link"]
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

global _FmtCountCache := Map()
FmtCount(N) {
    global _FmtCountCache
    if _FmtCountCache.Has(N)
        return _FmtCountCache[N]
    S := String(Round(N))
    Result := ""
    Len := StrLen(S)
    loop Len {
        i := A_Index
        Result := SubStr(S, Len - i + 1, 1) . Result
        if (Mod(i, 3) == 0 and i < Len)
            Result := " " . Result
    }
    _FmtCountCache[N] := Result
    return Result
}

NoAction(*) {
}

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

_GlobalRestoreFactoryBindings() {
    global GestureAssignments, GESTURE_SLOTS, GESTURE_FACTORY_DEFAULTS
    global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS
    global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_DEFAULTS
    global CategoryEnabled, _ConfigDir, _AhkSubDir
    if IsSet(GESTURE_FACTORY_DEFAULTS) {
        for Slot in GESTURE_SLOTS
            GestureAssignments[Slot] := GESTURE_FACTORY_DEFAULTS.Has(Slot) ? GESTURE_FACTORY_DEFAULTS[Slot] : "none"
    }
    for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
        KeyboardShortcutAssignments[Slot] := Action
    for Slot in SCRIPT_SHORTCUT_SLOTS
        ScriptShortcutAssignments[Slot] := SCRIPT_SHORTCUT_DEFAULTS[Slot]
    for Category, _ in CategoryEnabled
        CategoryEnabled[Category] := true
    Path := _ConfigDir . _AhkSubDir . "tap_hold.toml"
    try {
        if FileExist(Path)
            FileDelete(Path)
    }
}

_GlobalClearAllBindings(&Updates) {
    global GestureAssignments, GESTURE_SLOTS, KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, SCRIPT_SHORTCUT_SLOTS, ScriptShortcutAssignments, _IniCache
    for Slot in GESTURE_SLOTS {
        GestureAssignments[Slot] := "none"
        Updates.Push({ Section: "ahk.gestures", Key: Slot, Value: "none" })
    }
    KbWritten := Map()
    for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
        KeyboardShortcutAssignments[Slot] := "none"
        Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: "none" })
        KbWritten[Slot] := true
    }
    if IsSet(_IniCache) and _IniCache.Has("ahk.shortcuts.keyboard") {
        for Slot, _ in _IniCache["ahk.shortcuts.keyboard"] {
            if !KbWritten.Has(Slot) {
                KeyboardShortcutAssignments[Slot] := "none"
                Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: "none" })
            }
        }
    }
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        ScriptShortcutAssignments[Slot] := "none"
        Updates.Push({ Section: "ahk.shortcuts.script_control", Key: Slot, Value: "none" })
    }
    if IsSet(_TH_WriteTapHoldDisabled)
        try _TH_WriteTapHoldDisabled()
}

ToggleAllFeatures(Value) {
    global Features, CategoryEnabled, ConfigurationFile
    if !IsSet(Features)
        return
    Bool := (Value = true or Value = 1)
    Updates := []
    EmitFlip(SectionPath, Node) {
        if (Type(Node) != "Map")
            return
        if Node.Has("enabled") and (Type(Node["enabled"]) != "Map") {
            Node["enabled"] := Bool
            Updates.Push({ Section: SectionPath, Key: "enabled", Value: Bool })
            return
        }
        for K, V in Node {
            if (Type(V) == "Map")
                EmitFlip(SectionPath . "." . K, V)
            else {
                Node[K] := Bool
                Updates.Push({ Section: SectionPath, Key: K, Value: Bool })
            }
        }
    }
    if (!Bool) {
        for TopKey, TopVal in Features {
            if (Type(TopVal) == "Map")
            EmitFlip(TopKey, TopVal)
        }
    } else {
        for TopKey, TopVal in Features {
            if (Type(TopVal) != "Map")
                continue
            for K, V in TopVal {
                if (Type(V) == "Map") {
                    if V.Has("enabled") and (Type(V["enabled"]) != "Map") {
                        V["enabled"] := true
                        Updates.Push({ Section: TopKey . "." . K, Key: "enabled", Value: true })
                    }
                } else {
                    TopVal[K] := true
                    Updates.Push({ Section: TopKey, Key: K, Value: true })
                }
            }
        }
    }
    for Category, _ in CategoryEnabled {
        CategoryEnabled[Category] := Bool
        Updates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(Category), Value: Bool })
    }
    WPMWidget.visible := Bool
    WPMWidget.use_colors := Bool
    WPMWidget.show_graph := Bool
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: Bool ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: Bool ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: Bool ? "1" : "0" })
    if !Bool
        _GlobalClearAllBindings(Updates)
    TOML_BatchWrite(ConfigurationFile, Updates)
    if Bool {
        HsBatch := []
        for V1Path in _CollectAllHotstringsV1Paths()
            HsBatch.Push(Map("v1_path", V1Path . ".Enabled", "value", true))
        if (HsBatch.Length > 0)
            WriteFeatureBatch(HsBatch)
    }
    Reload
}

ToggleAllHotstringsOn(*) {
    ToggleAllHotstrings(1)
}
ToggleAllHotstringsOff(*) {
    ToggleAllHotstrings(0)
}
ToggleAllHotstrings(Value) {
    global CategoryEnabled, ConfigurationFile
    Bool := (Value = true or Value = 1)
    CategoryEnabled["Hotstrings"] := Bool
    TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", "hotstrings")
    if Bool {
        Batch := []
        for V1Path in _CollectAllHotstringsV1Paths()
            Batch.Push(Map("v1_path", V1Path . ".Enabled", "value", true))
        if (Batch.Length > 0)
            WriteFeatureBatch(Batch)
    }
    Reload
}

IsCategoryAllEnabled(Categories) {
    if (Categories.Length == 0)
        return true
    return IsCategoryGated(Categories[1])
}

; Deep-clone a (possibly nested) Map. Used to snapshot per-section hotstring
; Features so a live category toggle can restore them independently of later
; mutations. Non-Map values are returned as-is (leaf bool / number / string).
_HSDeepCloneMap(M) {
    if (Type(M) != "Map") {
        return M
    }
    Out := Map()
    for K, V in M {
        Out[K] := _HSDeepCloneMap(V)
    }
    return Out
}

; Snapshot one category's current (un-gated) section states into _HSCategorySnapshot.
_HSSnapshotCategory(V2Cat) {
    global Features, _HSCategorySnapshot
    if (IsSet(Features) and Features.Has("hotstrings") and Features["hotstrings"].Has(V2Cat)) {
        _HSCategorySnapshot[V2Cat] := _HSDeepCloneMap(Features["hotstrings"][V2Cat])
    }
}

; Snapshot every hotstring category. Called once at boot, before gating.
_HSSnapshotAllCategories() {
    global Features
    if (IsSet(Features) and Features.Has("hotstrings")) {
        for V2Cat, _ in Features["hotstrings"] {
            _HSSnapshotCategory(V2Cat)
        }
    }
}

; Restore a category's section states from the snapshot, in place (the category Map
; keeps its identity; each section entry is replaced with a fresh clone).
_HSRestoreCategory(V2Cat) {
    global Features, _HSCategorySnapshot
    if !(_HSCategorySnapshot.Has(V2Cat) and IsSet(Features)
        and Features.Has("hotstrings") and Features["hotstrings"].Has(V2Cat)) {
        return
    }
    Target := Features["hotstrings"][V2Cat]
    for Section, SecMap in _HSCategorySnapshot[V2Cat] {
        Target[Section] := _HSDeepCloneMap(SecMap)
    }
}

; Hotstring sub-categories whose entire content the live rebuild can apply, so
; flipping their master gate rebuilds in-process instead of Reloading. Only Rolls
; and SFBsReduction qualify: every other gated hotstring category holds a feature
; the rebuild can't apply (DistancesReduction -> the E-circumflex deadkey,
; Autocorrection -> the multiple-punctuation rule, MagicKey -> the J-to-star layout
; remap) or is the Hotstrings master that gates those too.
_IsLiveHotstringCategory(Category) {
    static Live := Map("Rolls", true, "SFBsReduction", true)
    return Live.Has(Category)
}

ToggleCategoryAllFeatures(Category, Value) {
    global CategoryEnabled, ConfigurationFile, Features
    Bool := (Value = true or Value = 1)
    if _IsLiveHotstringCategory(Category) {
        ; In-process: restore (ON) or snapshot (OFF) the category's sections, flip the
        ; gate, re-apply all master gates, then rebuild the engine — no Reload. The
        ; snapshot-on-OFF preserves any live section toggles made while it was on.
        V2Cat := _CategoryEnabledKey(Category)
        try LoggerDebug("Menu", "Live category toggle: {1} -> {2}.", Category, Bool ? "ON" : "OFF")
        if Bool {
            _HSRestoreCategory(V2Cat)
        } else {
            _HSSnapshotCategory(V2Cat)
        }
        CategoryEnabled[Category] := Bool
        TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", _CategoryEnabledKey(Category))
        ApplyMasterGatesToFeatures()
        RebuildHotstringsLive()
        return
    }
    CategoryEnabled[Category] := Bool
    TOML_Write(Bool, ConfigurationFile, "ahk.category_enabled", _CategoryEnabledKey(Category))
    Reload
}

_CategoryEnabledKey(Category) {
    switch Category {
        case "Layout":     return "layout"
        case "Shortcuts":  return "shortcuts"
        case "Hotstrings": return "hotstrings"
        case "TapHolds":   return "tap_holds"
        ; Hotstring sub-category gates — snake_case to match the v2 schema.
        case "DistancesReduction": return "distances_reduction"
        case "SFBsReduction":      return "sfbs_reduction"
        case "MagicKey":           return "magic_key"
        default: return StrLower(Category)
    }
}

SaveFullConfig() {
    global Features, ScriptInformation, ScriptShortcutAssignments, GestureAssignments, KeyboardShortcutAssignments, ConfigurationFile, _TOML_STRICT_CANON_IN_PROGRESS, PrevCanonState
    Updates := []
    if IsSet(_LLM_Tray_SyncToFeatures)
        _LLM_Tray_SyncToFeatures()
    if IsSet(Features) {
        _CollectFeatureUpdates(Updates, "", Features)
        Updates.Push({ Section: "_meta", Key: "schema_version", Value: 2 })
    }
    Updates.Push({ Section: "script", Key: "locale", Value: I18nGetLocale() })
    global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
    Updates.Push({ Section: "script", Key: "log_level", Value: IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : LOGGER_DEFAULT_LEVEL })
    Updates.Push({ Section: "hotstrings", Key: "trigger_char", Value: ScriptInformation["MagicKey"] })
    if IsSet(ScriptShortcutAssignments) {
        for Slot, Action in ScriptShortcutAssignments
            Updates.Push({ Section: "ahk.shortcuts.script_control", Key: Slot, Value: Action })
    }
    if IsSet(KeyboardShortcutAssignments) {
        for Slot, Action in KeyboardShortcutAssignments
            Updates.Push({ Section: "ahk.shortcuts.keyboard", Key: Slot, Value: Action })
    }
    if IsSet(GestureAssignments) {
        for Slot, Action in GestureAssignments
            Updates.Push({ Section: "ahk.gestures", Key: Slot, Value: Action })
    }
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
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_X,       Value: String(WPMWidget.pos_x) })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_Y,       Value: String(WPMWidget.pos_y) })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: WPMWidget.use_colors ? "1" : "0" })
    Updates.Push({ Section: "ahk.metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: WPMWidget.show_graph  ? "1" : "0" })
    Updates.Push({ Section: "llm", Key: "onboarding_seen", Value: _LLM_Tray["onboarding_seen"] ? "1" : "0" })
    _AppOverridesStr := ""
    for _AppName, _AppProfileId in _LLM_Tray["app_profile_overrides"] {
        if (_AppOverridesStr != "")
            _AppOverridesStr .= ";"
        _AppOverridesStr .= _AppName . "=" . _AppProfileId
    }
    Updates.Push({ Section: "llm", Key: "app_profile_overrides", Value: _AppOverridesStr })
    if IsSet(_LLM_Tray_AppendPersistedUpdates)
        _LLM_Tray_AppendPersistedUpdates(Updates)
    global CategoryEnabled
    if IsSet(CategoryEnabled) {
        for _CatName, _CatBool in CategoryEnabled
            Updates.Push({ Section: "ahk.category_enabled", Key: _CategoryEnabledKey(_CatName), Value: _CatBool })
    }
    global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, UPDATER_INI_SECTION, UPDATER_INI_KEY, UPDATER_INI_INTERVAL_KEY
    if IsSet(UPDATER_CHECK_INTERVAL)
        Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_INTERVAL_KEY, Value: UPDATER_CHECK_INTERVAL })
    if IsSet(UPDATER_CHANNEL)
        Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_KEY, Value: UPDATER_CHANNEL })
    if FileExist(ConfigurationFile)
        try FileDelete(ConfigurationFile)
    PrevCanonState := _TOML_STRICT_CANON_IN_PROGRESS
    _TOML_STRICT_CANON_IN_PROGRESS := true
    try {
        TOML_BatchWrite(ConfigurationFile, Updates)
    } finally {
        _TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState
    }
    TOML_FormatViaScript(ConfigurationFile)
}

_CollectFeatureUpdates(Updates, SectionPath, Node) {
    if (Type(Node) != "Map")
        return
    for Key, Value in Node {
        if (SectionPath == "" and Type(Value) != "Map")
            continue
        Sub := (SectionPath == "") ? Key : SectionPath "." Key
        if (Type(Value) == "Map")
            _CollectFeatureUpdates(Updates, Sub, Value)
        else
            Updates.Push({ Section: SectionPath, Key: Key, Value: Value })
    }
}

ReloadWithDefaultConfig(*) {
    global _ConfigDir, _AhkSubDir
    _GlobalRestoreFactoryBindings()
    AhkDir := _ConfigDir . _AhkSubDir
    for FileName in ["config.toml", "tap_hold.toml", "api_entries.json"] {
        Path := AhkDir . FileName
        try {
            if FileExist(Path)
                FileDelete(Path)
        }
    }
    Reload
}

ReadScriptShortcutsConfig() {
    global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Value := IniCacheGet(_IniCache, "ahk.shortcuts.script_control", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
            ScriptShortcutAssignments[Slot] := Value
    }
}

ResetScriptComboKeys(SuffixSC) {
    global _ALTGR_KANA_FIXUP
    if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
        return
    KeyWait(SuffixSC, "T2")
    if !GetKeyState(SuffixSC, "P")
        SendEvent("{SC138 Up}")
}

RunScriptShortcutAction(Slot) {
    global ScriptShortcutAssignments, GESTURE_ACTIONS, SCRIPT_SHORTCUT_FALLBACKS
    Action := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
    if (Action == "none") {
        SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
        return
    }
    if !GESTURE_ACTIONS.Has(Action) {
        SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
        return
    }
    GESTURE_ACTIONS[Action].Fn.Call()
}

SetScriptShortcutAction(Slot, ActionName) {
    global ScriptShortcutAssignments, ConfigurationFile
    ScriptShortcutAssignments[Slot] := ActionName
    TOML_Write(ActionName, ConfigurationFile, "ahk.shortcuts.script_control", Slot)
    Reload
}

BuildScriptShortcutsMenu() {
    global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, GESTURE_ACTIONS
    SMenu := Menu()
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Current := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
        CurrentLabel := GESTURE_ACTIONS.Has(Current) ? _GestureActionLabel(Current) : t("dialog.action_picker.disabled")
        SlotLabel := SCRIPT_SHORTCUT_LABELS[Slot]
        RegisterMenuItem(SMenu, SlotLabel . " : " . CurrentLabel, ((_s, _l) => (*) => ShowActionPicker(_l, ScriptShortcutAssignments.Has(_s) ? ScriptShortcutAssignments[_s] : "none", (Id) => SetScriptShortcutAction(_s, Id)))(Slot, SlotLabel))
    }
    return SMenu
}

_KeyboardSlotSendCode(SlotId) {
    global KEYBOARD_SHORTCUT_SEND_CODES
    if KEYBOARD_SHORTCUT_SEND_CODES.Has(SlotId)
        return KEYBOARD_SHORTCUT_SEND_CODES[SlotId]
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
    if SubStr(SlotId, 1, 10) = "ctrl_shift"
        Suffix := SubStr(SlotId, 12)
    else
        Suffix := SubStr(SlotId, InStr(SlotId, "_") + 1)
    static _SpecialMap := Map("space", "{Space}", "enter", "{Enter}", "period", ".", "comma", ",", "sc029", "SC029")
    return _SpecialMap.Has(Suffix) ? Mod . _SpecialMap[Suffix] : Mod . Suffix
}

ReadKeyboardShortcutsConfig() {
    global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache, GESTURE_ACTIONS
    for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
        KeyboardShortcutAssignments[Slot] := Action
    for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
        Value := IniCacheGet(_IniCache, "ahk.shortcuts.keyboard", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
            KeyboardShortcutAssignments[Slot] := Value
    }
}

RunKeyboardShortcutAction(SlotId) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    Action := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
    if (Action == "none" or !GESTURE_ACTIONS.Has(Action))
        return
    GESTURE_ACTIONS[Action].Fn.Call()
}

SetKeyboardShortcutAction(SlotId, ActionName) {
    global KeyboardShortcutAssignments, ConfigurationFile
    KeyboardShortcutAssignments[SlotId] := ActionName
    TOML_Write(ActionName, ConfigurationFile, "ahk.shortcuts.keyboard", SlotId)
    Reload
}

_MakeKeyboardShortcutHandler(SlotId, ActionName) {
    return (*) => SetKeyboardShortcutAction(SlotId, ActionName)
}

_FormatSlotLabel(SlotId) {
    static _ModLabels := Map("ctrl_shift_", "Ctrl + Shift + ", "ctrl_", "Ctrl + ", "win_", "Win + ", "alt_", "Alt + ")
    static _KeyNames := Map("space", "Espace", "enter", "Entrée", "period", ".", "comma", ",", "sc029", "²")
    for Prefix, ModLabel in _ModLabels {
        if (SubStr(SlotId, 1, StrLen(Prefix)) = Prefix) {
            Suffix := SubStr(SlotId, StrLen(Prefix) + 1)
            Key := _KeyNames.Has(Suffix) ? _KeyNames[Suffix] : StrUpper(Suffix)
            return ModLabel . Key
        }
    }
    return SlotId
}

InsertKeyboardShortcutGroups(TargetMenu, InsertBefore) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    _Groups := [
        Map("prefix", "alt_", "label", t("menu.shortcuts.alt_group"), "add_label", t("menu.shortcuts.alt_add")),
        Map("prefix", "ctrl_", "label", t("menu.shortcuts.ctrl_group"), "add_label", t("menu.shortcuts.ctrl_add")),
        Map("prefix", "ctrl_shift_", "label", t("menu.shortcuts.ctrl_shift_group"), "add_label", t("menu.shortcuts.ctrl_shift_add")),
        Map("prefix", "win_", "label", t("menu.shortcuts.win_group"), "add_label", t("menu.shortcuts.win_add")),
    ]
    GroupMenus := []
    for GroupInfo in _Groups {
        Prefix := GroupInfo["prefix"]
        GLabel := GroupInfo["label"]
        AddLabel := GroupInfo["add_label"]
        GMenu := Menu()
        for Slot, Action in KeyboardShortcutAssignments {
            if (SubStr(Slot, 1, StrLen(Prefix)) != Prefix)
                continue
            IsExactPrefix := true
            for OtherGroup in _Groups {
                OtherPrefix := OtherGroup["prefix"]
                if (OtherPrefix != Prefix and StrLen(OtherPrefix) > StrLen(Prefix) and SubStr(Slot, 1, StrLen(OtherPrefix)) == OtherPrefix) {
                    IsExactPrefix := false
                    break
                }
            }
            if !IsExactPrefix or (Action == "none")
                continue
            ActionLabel := GESTURE_ACTIONS.Has(Action) ? _GestureActionLabel(Action) : Action
            GMenu.Add(_FormatSlotLabel(Slot) . " : " . ActionLabel, ((_s) => (*) => ShowKeyboardShortcutPicker(_s))(Slot))
        }
        GMenu.Add(AddLabel, ((_p) => (*) => ShowKeyboardSlotPicker(_p))(Prefix))
        GroupMenus.Push(Map("label", GLabel, "menu", GMenu))
    }
    TargetMenu.Insert(InsertBefore)
    loop GroupMenus.Length {
        Idx := GroupMenus.Length - A_Index + 1
        TargetMenu.Insert(InsertBefore, GroupMenus[Idx]["label"], GroupMenus[Idx]["menu"])
    }
}

ShowKeyboardSlotPicker(Prefix) {
    global GESTURE_ACTIONS
    Slots := []
    static _SpecialOrder := ["space", "enter", "period", "comma", "sc029"]
    Letters := "abcdefghijklmnopqrstuvwxyz"
    loop StrLen(Letters) {
        SlotId := Prefix . SubStr(Letters, A_Index, 1)
        if GESTURE_ACTIONS.Has(SlotId)
            Slots.Push(SlotId)
    }
    loop 10 {
        SlotId := Prefix . SubStr("0123456789", A_Index, 1)
        if GESTURE_ACTIONS.Has(SlotId)
            Slots.Push(SlotId)
    }
    for Sk in _SpecialOrder {
        SlotId := Prefix . Sk
        if GESTURE_ACTIONS.Has(SlotId)
            Slots.Push(SlotId)
    }
    if (Slots.Length = 0)
        return
    SlotLabels := []
    for SlotId in Slots
        SlotLabels.Push(_GestureActionLabel(SlotId))
    W := Gui_Create("+AlwaysOnTop", t("dialog.keyboard_shortcut.title_prefix") . Prefix)
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

ShowActionPicker(Title, Current, OnConfirm, ShowNative := false) {
    global GESTURE_ACTION_NAMES, GESTURE_ACTIONS
    AllItems := []
    _PushItem(Id, Label, Cat) {
        AllItems.Push({ Id: Id, Label: Label, Cat: Cat })
    }
    if ShowNative
        _PushItem("__native__", t("tap_hold.tap.none"), "")
    _PushItem("none", t("dialog.action_picker.disabled"), "")
    CurrentCat := ""
    for ActionName in GESTURE_ACTION_NAMES {
        if (ActionName == "--" or ActionName == "none")
            continue
        if (SubStr(ActionName, 1, 1) = "#") {
            local TranslatedHeader := t("sg_actions.sg_order.header." . SubStr(ActionName, 2))
            CurrentCat := SubStr(TranslatedHeader, 1, 1) = "#" ? SubStr(TranslatedHeader, 2) : TranslatedHeader
            continue
        }
        if GESTURE_ACTIONS.Has(ActionName)
            _PushItem(ActionName, _GestureActionLabel(ActionName), CurrentCat)
    }
    BuildListRows(Items) {
        Ids := []
        Labels := []
        LastCat := Chr(0)
        for Item in Items {
            if (Item.Cat != "" and Item.Cat != LastCat) {
                Ids.Push("")
                Labels.Push("▸ " . Item.Cat)
                LastCat := Item.Cat
            }
            Ids.Push(Item.Id)
            Labels.Push("    " . Item.Label)
        }
        return { Ids: Ids, Labels: Labels }
    }
    Rows := BuildListRows(AllItems)
    FilteredIds := Rows.Ids
    SelectedIdx := 0
    LookupId := (Current == "") ? "__native__" : Current
    for i, Id in FilteredIds {
        if (Id == LookupId) {
            SelectedIdx := i
            break
        }
    }
    W := Gui_Create("+AlwaysOnTop", Title)
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12
    W.Add("Text", "xm", t("dialog.action_picker.label"))
    SearchEdit := W.Add("Edit", "xm w340")
    LB := W.Add("ListBox", "xm w340 r20", Rows.Labels)
    if (SelectedIdx > 0)
        LB.Choose(SelectedIdx)
    W.Add("Button", "xm w80", t("button.ok")).OnEvent("Click", ConfirmPick)
    W.Add("Button", "x+6 w80", t("button.cancel")).OnEvent("Click", (*) => W.Destroy())
    W.Show()
    SearchEdit.OnEvent("Change", FilterList)
    FilterList(*) {
        Query := StrLower(SearchEdit.Value)
        Matched := []
        if (Query == "") {
            Matched := AllItems
        } else {
            for Item in AllItems {
                if InStr(StrLower(Item.Label), Query)
                    Matched.Push(Item)
            }
        }
        NewRows := BuildListRows(Matched)
        FilteredIds := NewRows.Ids
        LB.Delete()
        LB.Add(NewRows.Labels)
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
        if (ChosenId == "")
            return
        W.Destroy()
        OnConfirm((ChosenId == "__native__") ? "" : ChosenId)
    }
}

ShowKeyboardShortcutPicker(SlotId) {
    global KeyboardShortcutAssignments
    Current := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
    ShowActionPicker(t("dialog.keyboard_shortcut.title_prefix") . _GestureActionLabel(SlotId), Current, (Id) => SetKeyboardShortcutAction(SlotId, Id))
}

FilePathsEditor(*) {
    global _ConfigDir, _PathsFile
    W := Gui(, t("dialog.config_folder.title"))
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12
    W.Add("Text", "xm w400", t("dialog.config_folder.label"))
    DirEdit := W.Add("Edit", "xm w400", StrReplace(_ConfigDir, "\", "/"))
    W.Add("Button", "xm y+6 w80", t("common.browse")).OnEvent("Click", (*) => ( (S := DirSelect("*" . StrReplace(Trim(DirEdit.Value), "/", "\"), 1, t("dialog.config_folder.select_title"))) != "" ? DirEdit.Value := StrReplace(S, "\", "/") : 0 ))
    ConfirmPath(*) {
        N := StrReplace(Trim(DirEdit.Value), "/", "\")
        if (N == "")
            N := _DefaultConfigDir
        if !RegExMatch(N, "\\$")
            N .= "\"
        if (N == _ConfigDir) {
            W.Destroy()
            return
        }
        try DirCreate(SubStr(_PathsFile, 1, InStr(_PathsFile, "\", , -1) - 1))
        f := FileOpen(_PathsFile, "w", "UTF-8")
        if f {
            f.Write('# Custom paths' . "`r`n" . 'ConfigDirPath = "' . StrReplace(N, "\", "/") . '"' . "`r`n")
            f.Close()
        }
        Reload()
    }
    W.Add("Button", "x162 y+10 w100 Default", t("button.ok")).OnEvent("Click", ConfirmPath)
    W.Show("Center")
}

ActivateEdit(*) {
    Edit()
}
ToggleSuspend(*) {
    global _ALTGR_KANA_FIXUP
    if !A_IsSuspended and IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP and GetKeyState("SC138", "P")
        KeyWait("SC138", "T1")
    Suspend(-1)
    UpdateTrayIcon()
    global _LastSuspendState := A_IsSuspended
    if A_IsSuspended
        Ergopti_OnSuspendEnter()
    else
        Ergopti_OnSuspendResume()
}
Ergopti_OnSuspendEnter() {
    try TooltipHide("Suspend", true)
    try LLM_Tooltip_Hide(true)
    try LLM_Engine_CancelTimer()
}
Ergopti_OnSuspendResume() {
    if IsSet(_ResetPrefixBuffer)
        try _ResetPrefixBuffer()
}
_SuspendStateWatchdog() {
    global _LastSuspendState
    if (A_IsSuspended == _LastSuspendState)
        return
    _LastSuspendState := A_IsSuspended
    UpdateTrayIcon()
    if A_IsSuspended
        Ergopti_OnSuspendEnter()
    else
        Ergopti_OnSuspendResume()
}
UpdateTrayIcon() {
    if A_IsSuspended {
        A_TrayMenu.Check(MenuSuspend)
        if FileExist(IconPathDisabled)
            TraySetIcon(IconPathDisabled, , True)
    }
    else {
        A_TrayMenu.Uncheck(MenuSuspend)
        if FileExist(IconPath)
            TraySetIcon(IconPath)
    }
}
ActivateReload(*) {
    Reload()
}
ActivateExitApp(*) {
    ExitApp()
}
WindowSpy(*) {
    SplitPath(A_AhkPath, , &ahkDir)
    SplitPath(ahkDir, , &parentDir)
    spyPath := parentDir "\WindowSpy.ahk"
    if FileExist(spyPath)
        Run(spyPath)
    else
        MsgBox(Format(t("ergopti.windowspy_not_found"), spyPath))
}
ActivateListVars(*) {
    ListVars()
}
ActivateKeyHistory(*) {
    KeyHistory()
}
ShowHealthCheck(*) {
    HealthCheck_ShowWindow()
}

_ScriptAltGrChordDebounce() {
    static last_tick := 0
    if (A_TickCount - last_tick < 80)
        return true
    last_tick := A_TickCount
    return false
}
_ScriptAltGrIsPhysical(SuffixSC) {
    global _ALTGR_KANA_FIXUP
    if !GetKeyState(SuffixSC, "P")
        return false
    if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
        return GetKeyState("SC138", "P")
    if GetKeyState("SC138", "P") or GetKeyState("RAlt", "P")
        return true
    return InStr(A_ThisHotkey, "^!") and GetKeyState("Ctrl", "P") and GetKeyState("Alt", "P") and !(GetKeyState("LAlt", "P") and !GetKeyState("RAlt", "P"))
}
_ScriptAltGrDispatch(SuffixSC, Slot, NativeSend, CtrlAltSuffixKey) {
    if _ScriptAltGrChordDebounce()
        return
    if !_ScriptAltGrIsPhysical(SuffixSC) {
        if InStr(A_ThisHotkey, "^!")
            SendInput("^!{" . CtrlAltSuffixKey . "}")
        else
            SendInput(NativeSend)
        return
    }
    RunScriptShortcutAction(Slot)
    ResetScriptComboKeys(SuffixSC)
}
_ScriptAltGrEnterHandler(*) {
    _ScriptAltGrDispatch("SC01C", "script_altgr_enter", "{Enter}", "Enter")
}
_ScriptAltGrBackSpaceHandler(*) {
    _ScriptAltGrDispatch("SC00E", "script_altgr_backspace", "{BackSpace}", "Backspace")
}
_ScriptAltGrDeleteHandler(*) {
    _ScriptAltGrDispatch("SC153", "script_altgr_delete", "{Delete}", "Delete")
}
_ScriptAltGrEscapeHandler(*) {
    _ScriptAltGrDispatch("SC001", "script_altgr_escape", "{Escape}", "Escape")
}

global _SCRIPT_ALTGR_HOTKEY_OPTS := "I3 S"
_ScriptAltGrHookKey(KeyName) {
    return (SubStr(KeyName, 1, 1) = "$" or InStr(KeyName, " & ")) ? KeyName : "$" . KeyName
}
_RegisterScriptAltGrHotkeys() {
    global _SCRIPT_ALTGR_HOTKEY_OPTS
    opts := _SCRIPT_ALTGR_HOTKEY_OPTS
    HotIf((*) => IsRealAltGrPress())
    Hotkey(_ScriptAltGrHookKey("RAlt & Enter"), _ScriptAltGrEnterHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC138 & SC01C"), _ScriptAltGrEnterHandler, opts)
    Hotkey(_ScriptAltGrHookKey("RAlt & BackSpace"), _ScriptAltGrBackSpaceHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC138 & SC00E"), _ScriptAltGrBackSpaceHandler, opts)
    Hotkey(_ScriptAltGrHookKey("RAlt & Delete"), _ScriptAltGrDeleteHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC138 & SC153"), _ScriptAltGrDeleteHandler, opts)
    Hotkey(_ScriptAltGrHookKey("RAlt & Escape"), _ScriptAltGrEscapeHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC138 & SC001"), _ScriptAltGrEscapeHandler, opts)
    HotIf()
    if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
        Hotkey(_ScriptAltGrHookKey("^!Enter"), _ScriptAltGrEnterHandler, opts)
        Hotkey(_ScriptAltGrHookKey("^!Backspace"), _ScriptAltGrBackSpaceHandler, opts)
        Hotkey(_ScriptAltGrHookKey("^!Delete"), _ScriptAltGrDeleteHandler, opts)
        Hotkey(_ScriptAltGrHookKey("^!Escape"), _ScriptAltGrEscapeHandler, opts)
    }
    if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
        HotIf((*) => GetKeyState("SC138", "P"))
        Hotkey(_ScriptAltGrHookKey("SC01C"), _ScriptAltGrEnterHandler, opts)
        Hotkey(_ScriptAltGrHookKey("SC00E"), _ScriptAltGrBackSpaceHandler, opts)
        Hotkey(_ScriptAltGrHookKey("SC153"), _ScriptAltGrDeleteHandler, opts)
        Hotkey(_ScriptAltGrHookKey("SC001"), _ScriptAltGrEscapeHandler, opts)
        HotIf()
    }
    HotIf((*) => A_IsSuspended and GetKeyState("SC138", "P"))
    Hotkey(_ScriptAltGrHookKey("SC01C"), _ScriptAltGrEnterHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC00E"), _ScriptAltGrBackSpaceHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC153"), _ScriptAltGrDeleteHandler, opts)
    Hotkey(_ScriptAltGrHookKey("SC001"), _ScriptAltGrEscapeHandler, opts)
    HotIf()
}
_RegisterScriptAltGrHotkeys()

; Personal hotstrings are loaded exactly once, inside RegisterAllHotstrings()
; below. There used to be an inline forward-order load here at #InputLevel 0,
; but personal hotstrings register through HSE (CreateHotstring → HSE_Register),
; not AHK-native Hotstring(), so #InputLevel never applied to them — the inline
; loop was a pre-HSE leftover that double-registered all 263 personal specs and
; re-parsed their TOML on every boot/reload. RegisterAllHotstrings now loads
; them in forward order so first-declared (prominent) sections win HSE's
; first-registered-wins collision tiebreak, matching the old effective order.
#InputLevel 2
#Include modules/layout.ahk
#Include modules/shortcuts.ahk
#Include modules/tap_holds.ahk
#Include modules/hotstrings.ahk
; The module now only DEFINES RegisterAllHotstrings(); invoke it here so the
; registration runs at the same boot point (and A_InputLevel) as before the
; in-process refactor. A_InputLevel is still 2 from the #InputLevel 2 above.
RegisterAllHotstrings()
HotstringPrefixWatcherInit()
BootProfile_Mark("Hotstrings registered + prefix watcher armed")
LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")

global _LAYOUT_POLL_INTERVAL_MS := 1000
global _LAST_KEYBOARD_HKL := GetForegroundKeyboardLayout()
CheckKeyboardLayoutChange() {
    global _LAST_KEYBOARD_HKL
    HKL := GetForegroundKeyboardLayout()
    if (HKL != 0 and HKL != _LAST_KEYBOARD_HKL) {
        _LAST_KEYBOARD_HKL := HKL
        Reload()
    }
}
SetTimer(CheckKeyboardLayoutChange, _LAYOUT_POLL_INTERVAL_MS)
