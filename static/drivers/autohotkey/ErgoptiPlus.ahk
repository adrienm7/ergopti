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
; ``#HotIf CapsWordEnabled``, ``#HotIf LayerEnabled`` or anything reading
; ``Features["…"]…`` while those globals are still unset. Loading the
; Features Map and the two layer-state booleans here keeps the very first
; message pump well-formed.
global CapsWordEnabled := False
global LayerEnabled := False
#Include lib/features_config.ahk

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
; from the script location (static/drivers/autohotkey → static) and _VendorDir
; is the vendor/ sibling of the entry script.
if A_IsCompiled {
    _StaticDir := _BundleDir . "\static"
    _VendorDir := _BundleDir . "\vendor"
} else {
    SplitPath(A_ScriptDir, , &_DriversDir_early)    ; static/drivers
    SplitPath(_DriversDir_early, , &_StaticDir)     ; static
    _VendorDir := A_ScriptDir . "\vendor"
}
global _StaticDir
global _VendorDir

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

SetKeyDelay(0) ; No delay between key presses
SendMode("Event") ; Everything concerning hotstrings MUST use SendEvent and not SendInput which is the default
; Otherwise, we can't have a hotstring triggering another hotstring, triggering another hotstring, etc.

; Logger pulled in first so every other lib/module can call it during init.
; ``LoggerInit()`` is invoked after the configuration file is parsed so the
; minimum log level can be honoured from the very first INFO/START line.
#Include lib/logger.ahk

; INI helpers extracted to their own lib so the test runner can ``#Include``
; them without bootstrapping the rest of the driver.
#Include lib/toml/toml_helpers.ahk
#Include lib/layout/layout_ergopti.ahk

; Active-app cache must come before hotstring_engine.ahk because both
; ``HotstringHandler`` and ``MicrosoftApps`` consult ``GetActiveApp``.
#Include lib/active_app_cache.ahk

; Core hotstring engine (send primitives, hotstring builders, text helpers)
; and TOML reader helpers (UnescapeTomlString, LoadHotstringsSection,
; FoldAsciiLower, ApplyTomlMetadataToFeatures) extracted into dedicated
; submodules so the main file stays focused on ErgoptiPlus-specific logic.
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_v2.ahk
#Include lib/toml/toml_loader.ahk
#Include lib/menu_manifest.ahk
#Include lib/llm_defaults.ahk
#Include lib/updater.ahk
; i18n module — must come after toml_loader.ahk (TOML_BatchWrite) and logger.ahk
#Include lib/i18n.ahk
#Include lib/onboarding.ahk
#Include lib/hotstrings/hotstrings_config.ahk
#Include lib/hotstrings/hotstrings_config_window.ahk
#Include lib/ui_style.ahk
#Include lib/tooltip.ahk
#Include lib/hotstrings/hotstring_prefix_watcher.ahk
; Auto-generated registrar for the bundled hotstring TOMLs. ``*i`` keeps the
; driver runnable from a fresh clone before ``tools/compile_hotstrings.py`` has
; been executed — ``LoadHotstringsSection`` falls back to the regex parser when
; ``_GENERATED_HOTSTRINGS`` is undefined.
#Include *i lib/hotstrings/hotstrings_generated.ahk
#Include lib/hotstrings/personal_toml_editor.ahk
#Include lib/dispatchers.ahk
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
; In compiled mode the file lives in the bundle dir (LocalAppData\Ergopti\bundle\)
; so it never pollutes the folder the .exe was launched from (Downloads, Desktop…).
global _PathsFile := (A_IsCompiled and _BundleDir != "") ? _BundleDir . "\paths.toml" : A_ScriptDir . "\paths.toml"
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

; All AHK driver configuration lives in a single unified TOML under the
; driver subfolder: features, script settings, shortcuts, gestures, and
; expert overrides ([script] / [features]) are sections of this one file.
global ConfigurationFile := _ConfigDir . "ahk\config.toml"

; Initialise the hotstrings_config module so per-group delays and tooltip
; colors can be resolved from the TOML metadata + the shared user override
; file. The override file lives in the same shared config directory used by
; Hammerspoon, so edits made from either menu apply to both at next reload.
HotstringsConfigInit(_ConfigDir . "hotstrings_config.toml")

; _StaticDir was already resolved at the top of the script (compiled vs dev
; aware), so here we only derive _LogoDir from it. Building a fully-normalized
; absolute path avoids any '..' traversal that TraySetIcon may refuse to
; resolve on some Windows configurations.
global _LogoDir := _StaticDir . "\img\logo"

; Tray icon paths are deliberately NOT part of ScriptInformation so that
; ReadScriptConfig() cannot override them from a user's [Script] section in
; ErgoptiPlus_Configuration.ini — historical configs still hold stale paths
; pointing at the old static/drivers/autohotkey/icons/ location and would
; otherwise silently break the tray icon after each project-level move
global IconPath := _LogoDir . "\logo_simple.ico"
global IconPathDisabled := _LogoDir . "\logo_simple_disabled.ico"

; Set the custom tray icon immediately so the default green AHK icon never
; appears — even briefly during the module loading phase that follows.
if FileExist(IconPath)
    TraySetIcon(IconPath)

; Auto-create driver and shared subfolders under _ConfigDir on first launch.
; ahk/ holds driver-specific files; hotstrings/ holds the shared TOML files
; so a Mac+PC setup can keep both side by side without name collision.
DirCreate(_ConfigDir . "ahk")
DirCreate(_ConfigDir . "hotstrings")
; Bootstrap an empty personal_hotstrings.toml if it does not exist yet so the
; user always has a file to open rather than a confusing error.
_PersonalTomlBootstrap := _ConfigDir . "hotstrings\personal_hotstrings.toml"
if !FileExist(_PersonalTomlBootstrap)
    FileAppend("", _PersonalTomlBootstrap)

global ScriptInformation := Map(
    "MagicKey", "★",
    ; Configurable file paths — all derived from _ConfigDir set above.
    ; AHK-specific files (.ahk, AHK config.toml) go under ``ahk/`` so the
    ; folder can be safely shared with the Hammerspoon driver via cloud
    ; sync. Shared neutral files (hotstrings TOML, personal info) stay
    ; at the root of _ConfigDir.
    "PersonalAhkPath", _ConfigDir . "ahk\personal_shortcuts.ahk",
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
    "win_h", "screen_capture",
    "win_m", "activity_simulation",
    "win_n", "take_note",
    "win_o", "surround_parens",
    "win_s", "search_web",
    "win_t", "teleport_mouse",
    "win_u", "uppercase_selection",
    "win_w", "titlecase_selection",
    "win_x", "pick_color",
    "win_sc029", "screen_capture_instant",
    "ctrl_b", "microsoft_bold",
    "ctrl_shift_v", "paste_plain",
)
; AHK send-key codes for each slot — must match GESTURE_ACTIONS Fn lambdas.
; Slots not listed here are generated dynamically from their suffix.
global KEYBOARD_SHORTCUT_SEND_CODES := Map(
    "win_sc029", "#SC029",
    "ctrl_shift_v", "^+v",
)
global KeyboardShortcutAssignments := Map()

; ParseTomlFile / IniCacheGet / ResolveConfigPath are defined in lib/ini_helpers.ahk
; (included above) so the test runner can exercise them in isolation.

; Hotstring categories are grouped under a [Hotstrings] umbrella in the TOML,
; matching the Hammerspoon config layout. Internal AHK category names stay
; unchanged so no menu or hotstring code needs updating.
_HOTSTRING_TOML_CATEGORIES := Map(
    "Autocorrection",      "Hotstrings.Autocorrection",
    "DistancesReduction",  "Hotstrings.DistancesReduction",
    "DynamicHotstrings",   "Hotstrings.DynamicHotstrings",
    "MagicKey",            "Hotstrings.MagicKey",
    "Personal",            "Hotstrings.Personal",
    "Rolls",               "Hotstrings.Rolls",
    "SFBsReduction",       "Hotstrings.SFBsReduction",
)

; Map an internal AHK category name to its TOML section name.
_TomlSection(Category) {
    global _HOTSTRING_TOML_CATEGORIES
    if _HOTSTRING_TOML_CATEGORIES.Has(Category)
        return _HOTSTRING_TOML_CATEGORIES[Category]
    return Category
}

ReadScriptConfig(Cache) {
    ; MagicKey lives in [Hotstrings] in the TOML (alongside the hotstring modules)
    Raw := IniCacheGet(Cache, "Hotstrings", "MagicKey")
    if Raw != "_"
        ScriptInformation["MagicKey"] := Raw
    ; Backward-compat: also check the old [Script] location so existing configs still load
    Raw := IniCacheGet(Cache, "Script", "MagicKey")
    if Raw != "_"
        ScriptInformation["MagicKey"] := Raw
    ; Restore the engine-level repeat-key toggle (defaults to enabled when absent)
    global HSE_RepeatEnabled
    RawRepeat := IniCacheGet(Cache, "Hotstrings", "RepeatKeyEnabled")
    if RawRepeat != "_"
        HSE_RepeatEnabled := (RawRepeat == "1" or RawRepeat == "true")
    ; Paths are always derived from _ConfigDir at startup and are never persisted
}

Onboarding_Run()

global _IniCache := ParseTomlFile(ConfigurationFile)
ReadScriptConfig(_IniCache)
I18nInit(_IniCache)

; Auto-detect whether the active OS layout remaps AltGr to VK_KANA and cache
; the resolved bool in _ALTGR_KANA_FIXUP. Must run before the first hotstring
; fires. The layout-poll timer at the bottom of this file triggers a full
; Reload() on layout switch, so this runs again automatically.
HotstringEngineInit()

; Initialise the logger now that the ini cache is built and ScriptInformation
; reflects user overrides — LoggerInit reads [Script] LogLevel from the ini.
LoggerInit()
Updater_LoadChannel()
LoggerStart("ErgoptiPlus", "Booting ErgoptiPlus driver…")

; Probe SC138 → VK directly so we can see what MapVirtualKeyExW actually
; returns on this layout (VK_RMENU=0xA5, VK_KANA=0x15, anything else means
; the heuristic needs adjustment).
_DetectVK := DllCall("MapVirtualKeyExW",
    "UInt", 0x38, "UInt", 3,
    "Ptr", GetForegroundKeyboardLayout(), "UInt")
LoggerInfo("AltGrDetect",
    "HKL=0x{1:X}, SC138→VK=0x{2:X}, _ALTGR_KANA_FIXUP={3}.",
    GetForegroundKeyboardLayout(), _DetectVK,
    _ALTGR_KANA_FIXUP ? "true" : "false")

; Under this text is the configuration of the features, especially whether or not they are enabled.
; It is advised to modify which features are enabled by using the ErgoptiPlus_Configuration.ini file.
; This configuration file will automatically be created or updated as soon as one element of the tray menu is toggled on/off.
; It can also be created manually. The content will look like this, with the different categories in brackets:
; [Layout]
; ErgoptiBase.Enabled=0
; [TapHolds]
; AltGr.Enabled=1

; Features configuration (enabled flags, default parameters, submenu hierarchy)
; extracted to its own submodule so the main file is not dominated by a 650-line
; data literal. The actual #Include lives at the top of the file (before
; Bundle_Init) so the Features Map exists before any #HotIf can be evaluated
; during early message pumping. INI overrides are still applied by
; ReadConfiguration() below, and TOML metadata is still injected by
; ApplyTomlMetadataToFeatures() after that.

; It is best to modify those values by using the option in the script menu
global PersonalInformation := Map(
    "FirstName", "Prénom",
    "LastName", "Nom",
    "DateOfBirth", "01/01/2000",
    "EmailAddress", "prenom.nom@mail.fr",
    "WorkEmailAddress", "prenom.nom@mail.pro",
    "PhoneNumber", "0606060606",
    "PhoneNumberClean", "06 06 06 06 06",
    "StreetAddress", "1 Rue de la Paix",
    "City", "Paris",
    "Country", "France",
    "PostalCode", "75000",
    "IBAN", "FR00 0000 0000 0000 0000 0000 000",
    "BIC", "ABCDFRPP",
    "CreditCard", "1234 5678 9012 3456",
    "SocialSecurityNumber", "1 99 99 99 999 999 99",
)
global PersonalInformationLetters := Map(
    "a", "StreetAddress",
    "b", "BIC",
    "c", "CreditCard",
    "d", "DateOfBirth",
    "e", "EmailAddress",
    "f", "PhoneNumberClean",
    "i", "IBAN",
    "m", "EmailAddress",
    "n", "LastName",
    "p", "FirstName",
    "s", "SocialSecurityNumber",
    "t", "PhoneNumber",
    "w", "WorkEmailAddress",
)

; ======================================================================
; ======= 1.2) Variables update if there is a configuration file =======
; ======================================================================

ReadConfiguration(Cache) {
    ExtraProps := ["TimeActivationSeconds", "Letter", "PatternMaxLength",
        "Link", "DestinationFolder", "DatedNotes", "SearchEngine", "SearchEngineURLQuery"]

    for Category, FeaturesMap in Features {
        if !IsObject(FeaturesMap) or Type(FeaturesMap) != "Map"
            continue
        TomlCat := _TomlSection(Category)
        for Feature, Value in FeaturesMap {
            if Feature == "__Order"
                continue
            if Type(Value) == "Map" {
                ; Sub-map: __Configuration props live directly in [TomlCat.Feature]
                if Value.Has("__Configuration") {
                    Cfg := Value["__Configuration"]
                    for Prop in ExtraProps {
                        if Cfg.HasOwnProp(Prop) {
                            Raw := IniCacheGet(Cache, TomlCat "." Feature, Prop)
                            if Raw != "_"
                                Value["__Configuration"].%Prop% := Raw
                        }
                    }
                }
                ; Leaf sub-features are flattened in [TomlCat.Feature]
                for SubFeature, SubValue in Value {
                    if SubFeature == "__Order" or SubFeature == "__Configuration"
                        continue
                    if !IsObject(SubValue)
                        continue
                    EnabledRaw := IniCacheGet(Cache, TomlCat "." Feature, SubFeature)
                    if EnabledRaw != "_"
                        Features[Category][Feature][SubFeature].Enabled := EnabledRaw
                    for Prop in ExtraProps {
                        if SubValue.HasOwnProp(Prop) {
                            Raw := IniCacheGet(Cache, TomlCat "." Feature, SubFeature "_" Prop)
                            if Raw != "_"
                                Features[Category][Feature][SubFeature].%Prop% := Raw
                        }
                    }
                }
            } else if IsObject(Value) {
                ; Leaf feature: Enabled lives as FeatureName key in [TomlCat]
                EnabledRaw := IniCacheGet(Cache, TomlCat, Feature)
                if EnabledRaw != "_"
                    Features[Category][Feature].Enabled := EnabledRaw
                for Prop in ExtraProps {
                    if Value.HasOwnProp(Prop) {
                        Raw := IniCacheGet(Cache, TomlCat, Feature "_" Prop)
                        if Raw != "_"
                            Features[Category][Feature].%Prop% := Raw
                    }
                }
            }
        }
    }
}

ReadConfiguration(_IniCache)
; Migrate TextExpansionPersonalInformation from MagicKey to DynamicHotstrings:
; remove the stale keys from [Hotstrings.MagicKey] so they stop reappearing
; in the config file on every write.
TOML_BatchWrite(ConfigurationFile, [
    { Section: "Hotstrings.MagicKey", Key: "TextExpansionPersonalInformation",              Value: "_DELETE_" },
    { Section: "Hotstrings.MagicKey", Key: "TextExpansionPersonalInformation_PatternMaxLength", Value: "_DELETE_" },
])
; Materialise personal_info.toml from defaults if missing, so renaming or
; deleting the file simply triggers a fresh re-creation on the next launch
; (same guarantee EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk).
EnsurePersonalInfoTomlFile(ScriptInformation["PersonalInfoTomlPath"])
ReadPersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])

; Pull menu titles and submenu ordering from the per-category TOML files so
; that those hotstring files are the single source of truth for both the
; hotstring payload and the feature descriptions shown in the tray menu.
; Categories without a dedicated TOML (``Layout``, ``Shortcuts``, ``Gestures``,
; and the flat DynamicHotstrings entries) get their descriptions from the locale
; file via ``ApplyLocaleDescriptions``. ``TapHolds`` descriptions come from
; ``tap_hold_config.ahk``.
ApplyTomlMetadataToFeatures("Autocorrection")
ApplyTomlMetadataToFeatures("DistancesReduction")
ApplyTomlMetadataToFeatures("MagicKey")
ApplyTomlMetadataToFeatures("Rolls")
ApplyTomlMetadataToFeatures("SFBsReduction")
ApplyIndexTomlToDynamicHotstrings()
ApplyLocaleDescriptions(I18nGetLocale())

; Append hotstring counts to section descriptions so the tray menu shows
; "(N)" next to each section item — mirrors Hammerspoon's per-section display.
EnrichSectionDescriptionsWithCounts(Category) {
    global Features
    if !Features.Has(Category) {
        return
    }
    for FeatKey, FeatVal in Features[Category] {
        if (FeatKey == "__Order" or !IsObject(FeatVal) or Type(FeatVal) == "Map") {
            continue
        }
        ; TOML section name is the lowercase/accent-folded version of the AHK feature key
        TomlSection := FoldAsciiLower(FeatKey)
        N := CountTomlSection(Category, TomlSection)
        if (N > 0 and FeatVal.HasOwnProp("Description") and FeatVal.Description != "") {
            FeatVal.Description := FeatVal.Description . " (" . N . ")"
        }
    }
}
for _Cat in ["Autocorrection", "DistancesReduction", "MagicKey", "Rolls", "SFBsReduction"] {
    EnrichSectionDescriptionsWithCounts(_Cat)
}

; Count the exact number of hotstrings that will be generated for a DynamicHotstrings
; section — mirrors the same threshold logic used in hotstrings.ahk section 5.
; This must stay in sync with the registration code whenever prefix rules change.
CountDynamicSection(SectionName) {
    global PersonalInformation
    Phone := PersonalInformation["PhoneNumber"]
    FPhone := PersonalInformation["PhoneNumberClean"]
    Ssn := PersonalInformation["SocialSecurityNumber"]
    Iban := PersonalInformation["IBAN"]
    SsnRaw := StrReplace(Ssn, " ", "")
    IbanRaw := StrReplace(Iban, " ", "")

    switch SectionName {
        case "DateFr", "DateLongFr", "Date":
            return 1
        case "PhonePrefixes":
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
        case "SsnPrefixes":
            ; No-space + spaced triggers — both fire when ssn_raw has >= 5 digits
            return StrLen(SsnRaw) >= 5 ? 2 : 0
        case "IbanPrefixes":
            ; 6 raw chars (no-space) and 7-char spaced trigger if iban_raw has >= 6 chars
            return StrLen(IbanRaw) >= 6 ? 2 : 0
        default:
            return 0
    }
}

; Replace the static date placeholder in DynamicHotstrings descriptions with today's
; actual date and real hotstring counts so the tray menu always reflects live data.
if Features.Has("DynamicHotstrings") {
    MK := ScriptInformation["MagicKey"]
    for _DynKey, _DynVal in Features["DynamicHotstrings"] {
        if (_DynKey == "__Order" or !IsObject(_DynVal) or Type(_DynVal) == "Map") {
            continue
        }
        N := CountDynamicSection(_DynKey)
        CountSuffix := N > 0 ? " (" . N . ")" : ""
        switch _DynKey {
            case "DateFr":
                _DynVal.Description := StrReplace(StrReplace(t("dynamichotstrings.datefr"), "★", MK), "{date}", FormatTime(, "dd/MM/yyyy")) . CountSuffix
            case "DateLongFr":
                _DynDays   := ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
                _DynMonths := ["janvier", "février", "mars", "avril", "mai", "juin",
                               "juillet", "août", "septembre", "octobre", "novembre", "décembre"]
                _DynLongDate := _DynDays[A_WDay] . " " . FormatTime(, "d") . " " . _DynMonths[FormatTime(, "M") + 0] . " " . FormatTime(, "yyyy")
                _DynVal.Description := StrReplace(StrReplace(t("dynamichotstrings.datelongfr"), "★", MK), "{date}", _DynLongDate) . CountSuffix
            case "Date":
                _DynVal.Description := StrReplace(StrReplace(t("dynamichotstrings.date"), "★", MK), "{date}", FormatTime(, "yyyy_MM_dd")) . CountSuffix
            default:
                if (_DynVal.HasOwnProp("Description") and _DynVal.Description != "" and N > 0) {
                    _DynVal.Description := _DynVal.Description . CountSuffix
                }
        }
    }
}

global SpaceAroundSymbols := Features["DistancesReduction"]["SpaceAroundSymbols"].Enabled ? " " : ""

#Include ui/tray_menu.ahk

; Register a behavioural toggle for a personal hotkey defined in the user's
; personal_shortcuts.ahk. Toggles are stored under the nested namespace
; Features["Shortcuts"]["Personal"][Name] so that user-chosen names cannot
; collide with the built-in Shortcuts entries (EGrave, MicrosoftBold, …) and
; show up as a dedicated « Raccourcis personnels » sub-submenu inside
; « 🎯 Raccourcis ».
; Their on/off state is persisted in the configuration INI under the
; [Shortcuts.Personal] section. The persisted value is looked up at
; registration time so previously-saved toggles survive across reloads even
; though personal_shortcuts.ahk is loaded after the global ReadConfiguration.
RegisterPersonalFeature(Name, DefaultEnabled := false, Description := "") {
    global Features, _IniCache
    if !Features.Has("Shortcuts") {
        return
    }
    Sc := Features["Shortcuts"]
    if !Sc.Has("__Order") {
        Sc["__Order"] := []
    }

    ; Lazily create the Personal sub-Map and its own __Order on the first call.
    if !Sc.Has("Personal") {
        Sc["Personal"] := Map("__Order", [])
        ; __Label drives GetSubMenuLabel — data-driven i18n key for this sub-Map
        Sc["Personal"]["__Label"] := "menu.shortcuts.personal"
    }
    Personal := Sc["Personal"]
    if !Personal.Has("__Order") {
        Personal["__Order"] := []
    }

    if !Personal.Has(Name) {
        ; Apply the persisted INI value if present, otherwise fall back to the default
        Enabled := DefaultEnabled
        RawValue := IniCacheGet(_IniCache, "Shortcuts.Personal", Name . ".Enabled")
        if RawValue != "_" {
            Enabled := RawValue
        }
        Personal[Name] := { Enabled: Enabled, Description: Description }
    }

    ; Append the feature to the Personal sub-Map order, avoiding duplicates
    Found := false
    for Item in Personal["__Order"] {
        if Item == Name {
            Found := true
            break
        }
    }
    if !Found {
        Personal["__Order"].Push(Name)
    }

    ; Hook the Personal sub-Map into the parent Shortcuts __Order once, with a
    ; preceding separator so it visually breaks away from built-in entries.
    HasPersonalEntry := false
    for Item in Sc["__Order"] {
        if Item == "Personal" {
            HasPersonalEntry := true
            break
        }
    }
    if !HasPersonalEntry {
        Sc["__Order"].Push("-")
        Sc["__Order"].Push("Personal")
    }
}

/**
 * Safe accessor for a personal feature's enabled state.
 * Use this in #HotIf expressions instead of the raw Map lookup to avoid
 * "Item has no value" crashes when the feature key is evaluated before
 * RegisterPersonalFeature() has run (e.g. during AHK's hotkey-condition
 * sweep on the very first keypress after a rapid reload).
 * @param {string} name - The feature name passed to RegisterPersonalFeature.
 * @returns {boolean} True if enabled, false if absent or disabled.
 */
PersonalFeatureEnabled(name) {
    global Features
    try {
        return Features["Shortcuts"]["Personal"][name].Enabled
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
    ; Both branches of the original ternary were evaluated eagerly at parse time
    ; in some AHK v2 releases, which made a missing/empty A_LocalAppData surface
    ; as an "unassigned local variable" crash even in dev mode. EnvGet provides
    ; a deterministic fallback when A_LocalAppData is somehow blank (RDP/service
    ; contexts), and the explicit if/else avoids any ternary-eval ambiguity.
    StubDir := ""
    if A_IsCompiled {
        LocalAppData := A_LocalAppData
        if (LocalAppData == "") {
            LocalAppData := EnvGet("LOCALAPPDATA")
        }
        if (LocalAppData == "") {
            LocalAppData := EnvGet("USERPROFILE") . "\AppData\Local"
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
#InputLevel 0
; Apply user overrides from ahk/config.toml on top of the INI-driven
; configuration. The [script] and [features] sections are an optional "expert"
; layer the user can edit by hand to override anything the menu exposes
; (LogLevel, MagicKey, individual feature flags). All sections live in a
; single unified config file — no separate cross-driver config.toml.
ApplyConfigTomlOverrides(ConfigurationFile)

; Bootstrap Features["Personal"] from personal_hotstrings.toml _meta.sections
; before applying TOML metadata, so the user's section toggles appear in the menu.
BootstrapPersonalFeatures()
if Features.Has("Personal") {
    ApplyTomlMetadataToFeatures("Personal")
    ; Apply [Personal] INI overrides AFTER bootstrap — the generic
    ; ReadConfiguration() ran before bootstrap so it had no Features.Personal
    ; entries to write into. Without this, user-disabled sections always come
    ; back enabled on reload.
    for FeatKey, FeatVal in Features["Personal"] {
        if FeatKey == "__Order" {
            continue
        }
        if !(IsObject(FeatVal) and FeatVal.HasOwnProp("Enabled")) {
            continue
        }
        RawValue := IniCacheGet(_IniCache, "Personal", FeatKey . ".Enabled")
        if RawValue != "_" {
            Features["Personal"][FeatKey].Enabled := RawValue
        }
    }
}

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
; The Features["Shortcuts"] hard-coded behaviours (Win+A, Win+G, …) remain
; active alongside these — the user disables individual Features items if they
; prefer the configurable system exclusively.
LoggerStart("KeyboardShortcuts", "Enregistrement des hotkeys configurables…")
_KbBoundCount := 0
for _KbSlot, _KbAction in KeyboardShortcutAssignments {
    if (_KbAction == "none")
        continue
    _KbSend := _KeyboardSlotSendCode(_KbSlot)
    if (_KbSend == "") {
        LoggerWarn("KeyboardShortcuts", "Slot '%s' ignoré — code d'envoi introuvable.", _KbSlot)
        continue
    }
    try {
        Hotkey(_KbSend, ((_s) => (*) => RunKeyboardShortcutAction(_s))(_KbSlot))
        LoggerDebug("KeyboardShortcuts", "Hotkey '%s' → '%s' enregistré.", _KbSlot, _KbAction)
        _KbBoundCount++
    } catch as _KbErr {
        LoggerWarn("KeyboardShortcuts", "Échec enregistrement hotkey '%s' : %s.", _KbSlot, _KbErr.Message)
    }
}
LoggerSuccess("KeyboardShortcuts", "Hotkeys configurables enregistrés (%d actif(s)).", _KbBoundCount)

; Load every UI shortcut + privacy filter from the [shortcuts] section
; of ahk/config.toml. CS_Load() populates both MetricsShortcuts
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
    GuiToShow := Gui(, t("dialog.magic_key.title"))
    GuiToShow.Add("Text", , t("dialog.magic_key.prompt"))
    NewValue := GuiToShow.Add("Edit", "w50 x+10", ScriptInformation["MagicKey"])

    GuiToShow.Add("Button", "w100 x+10", t("button.ok")).OnEvent("Click", (*) => ModifyMagicKey(GuiToShow, NewValue.Text))
    GuiToShow.Show("Center")
}
ModifyMagicKey(gui, NewValue) {
    global ScriptInformation, ConfigurationFile
    ScriptInformation["MagicKey"] := NewValue
    TOML_Write(NewValue, ConfigurationFile, "Hotstrings", "MagicKey")

    gui.Destroy()
    Reload
}

ToggleRepeatKeyEnabled(*) {
    global HSE_RepeatEnabled, ConfigurationFile
    HSE_RepeatEnabled := !HSE_RepeatEnabled
    TOML_Write(HSE_RepeatEnabled, ConfigurationFile, "Hotstrings", "RepeatKeyEnabled")
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
    GuiToShow := Gui(, t("dialog.gpt_link.title"))
    NewValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["GPT"].Link)

    GuiToShow.Add("Button", "w100 Center", t("button.ok")).OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
    GuiToShow.Show("Center")
}
ModifyLink(gui, NewValue) {
    Features["Shortcuts"]["GPT"].Link := NewValue
    TOML_Write(NewValue, ConfigurationFile, "Shortcuts", "GPT_Link")

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
ToggleAllFeatures(Value) {
    ; Behavior:
    ; - If Value == 0 : set everything to 0 recursively (including sub-sub-menus)
    ; - If Value == 1 : set only first-level features (the defaults) to 1; do not enable nested choices
    ; Collect all INI mutations into a single batch — writing them one by one
    ; through TOML_Write does 50+ FileOpen/Write/Close round-trips and produces a
    ; visible delay in the tray menu.
    global Features
    Updates := []

    ; Recursive setter used when Value == 0.
    ; Section is the TOML section where this node's leaf children are flattened.
    ; Pass an empty string for the root call; the function handles the top-level
    ; category keys by using Key directly as the section name.
    SetAllRecursive(Section, Items) {
        for Key, Val in Items {
            if Key == "__Order" or Key == "__Configuration" {
                continue
            }
            ; Translate category names to TOML sections at the top level
            TomlKey := (Section = "") ? _TomlSection(Key) : Key
            ChildSection := (Section = "") ? TomlKey : Section "." Key
            if Type(Val) == "Map" {
                ; Sub-map: its leaf children are flattened in [ChildSection]
                SetAllRecursive(ChildSection, Val)
            } else if IsObject(Val) and Val.HasOwnProp("Enabled") {
                ; Leaf: flatten into parent Section with Key as the TOML key
                Val.Enabled := Value
                Updates.Push({ Section: Section, Key: Key, Value: Value })
            }
        }
    }

    if (Value == 0) {
        ; Disable everything recursively
        SetAllRecursive("", Features)
    } else {
        ; Enable only first-level/default features (do not descend into nested choices)
        for Category, Items in Features {
            if Category == "__Order" {
                continue
            }
            for FeatureName, Val in Items {
                if FeatureName == "__Order" {
                    continue
                }
                if IsObject(Val) and Val.HasOwnProp("Enabled") {
                    Val.Enabled := Value
                    Updates.Push({ Section: _TomlSection(Category), Key: FeatureName, Value: Value })
                }
                ; If Val is a Map without Enabled, we skip its children when enabling
            }
        }
    }
    TOML_BatchWrite(ConfigurationFile, Updates)
    Reload
}

ToggleAllHotstringsOn(*) {
    ToggleAllHotstrings(1)
}
ToggleAllHotstringsOff(*) {
    ToggleAllHotstrings(0)
}
ToggleAllHotstrings(Value) {
    global Features, HotstringCategories
    Updates := []
    ; Toggle all hotstring categories including DynamicHotstrings and Personal
    AllHotsCats := HotstringCategories.Clone()
    for ExtraCat in ["DynamicHotstrings", "Personal"] {
        Found := false
        for C in AllHotsCats {
            if C == ExtraCat {
                Found := true
                break
            }
        }
        if !Found
            AllHotsCats.Push(ExtraCat)
    }
    for Category in AllHotsCats {
        if !Features.Has(Category) {
            continue
        }
        TomlCat := _TomlSection(Category)
        for FeatureName, Val in Features[Category] {
            if FeatureName == "__Order" {
                continue
            }
            if IsObject(Val) and Val.HasOwnProp("Enabled") {
                Val.Enabled := Value
                Updates.Push({ Section: TomlCat, Key: FeatureName, Value: Value })
            }
        }
    }
    TOML_BatchWrite(ConfigurationFile, Updates)
    Reload
}

; Returns true when every leaf feature in the given category list is enabled.
; Used by initMenu to decide the initial state of the per-submenu on/off toggle.
IsCategoryAllEnabled(Categories) {
    global Features
    for Category in Categories {
        if !Features.Has(Category) {
            continue
        }
        for FeatureName, Val in Features[Category] {
            if FeatureName == "__Order" {
                continue
            }
            if IsObject(Val) and Val.HasOwnProp("Enabled") and !Val.Enabled {
                return false
            }
        }
    }
    return true
}

; Toggle all leaf features of a single category to Value (true/false) and reload.
; Mirrors ToggleAllHotstrings for non-hotstring categories (Shortcuts, TapHolds).
ToggleCategoryAllFeatures(Category, Value) {
    global Features, ConfigurationFile
    if !Features.Has(Category) {
        return
    }
    Updates := []
    for FeatureName, Val in Features[Category] {
        if FeatureName == "__Order" {
            continue
        }
        if IsObject(Val) and Val.HasOwnProp("Enabled") {
            Val.Enabled := Value
            Updates.Push({ Section: _TomlSection(Category), Key: FeatureName, Value: Value })
        }
    }
    TOML_BatchWrite(ConfigurationFile, Updates)
    Reload
}

; Persist the complete in-memory state to the unified ahk/config.toml.
; Every feature flag, script setting, script shortcut assignment, and
; gesture assignment is written — not just the delta from defaults.
; Sections and keys within sections are sorted alphabetically by the
; TOML_BatchWrite writer for stable, human-readable output.
SaveFullConfig() {
    global Features, ScriptInformation, ScriptShortcutAssignments
    global GestureAssignments, ConfigurationFile, _TOML_STRICT_CANON_IN_PROGRESS
    global PrevCanonState
    Updates := []

    ; Collect all feature flags recursively
    _CollectFeatureUpdates(Updates, "", Features)

    ; [Script] section — locale and other script-level settings
    Updates.Push({ Section: "Script", Key: "Locale", Value: I18nGetLocale() })

    ; [Hotstrings] root — MagicKey lives here, paths are never persisted
    Updates.Push({ Section: "Hotstrings", Key: "MagicKey", Value: ScriptInformation["MagicKey"] })

    ; [Shortcuts.ScriptControl] section
    if IsSet(ScriptShortcutAssignments) {
        for Slot, Action in ScriptShortcutAssignments {
            Updates.Push({ Section: "Shortcuts.ScriptControl", Key: Slot, Value: Action })
        }
    }

    ; [Gestures] assignments (trackpad gesture slots)
    if IsSet(GestureAssignments) {
        for Slot, Action in GestureAssignments {
            Updates.Push({ Section: "Gestures", Key: Slot, Value: Action })
        }
    }

    ; [Metrics] section — metrics shortcut bindings and privacy filters
    apps := []
    for proc, _ in MetricsFilters.disabled_apps
        apps.Push(proc)
    Updates.Push({ Section: "Metrics", Key: "metrics_enabled", Value: MetricsShortcuts.enabled })
    Updates.Push({ Section: "Metrics", Key: "metrics_shortcut_typing", Value: MetricsShortcuts.typing_str })
    Updates.Push({ Section: "Metrics", Key: "metrics_shortcut_apps", Value: MetricsShortcuts.apps_str })
    Updates.Push({ Section: "Metrics", Key: "metrics_show_wpm_menubar", Value: MetricsShortcuts.show_wpm_menubar })
    Updates.Push({ Section: "Metrics", Key: "metrics_wpm_menubar_colors", Value: MetricsShortcuts.wpm_menubar_colors })
    Updates.Push({ Section: "Metrics", Key: "metrics_filter_private_browsing", Value: MetricsFilters.private_browsing })
    Updates.Push({ Section: "Metrics", Key: "metrics_filter_secure_field", Value: MetricsFilters.secure_field })
    Updates.Push({ Section: "Metrics", Key: "metrics_filter_system_auth", Value: MetricsFilters.system_auth })
    Updates.Push({ Section: "Metrics", Key: "metrics_disabled_apps", Value: apps })

    ; [Script] section — WPM widget position and display options
    Updates.Push({ Section: "Script", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible ? "1" : "0" })
    Updates.Push({ Section: "Script", Key: WPMWidgetConst.CFG_X,       Value: String(WPMWidget.pos_x) })
    Updates.Push({ Section: "Script", Key: WPMWidgetConst.CFG_Y,       Value: String(WPMWidget.pos_y) })
    Updates.Push({ Section: "Script", Key: WPMWidgetConst.CFG_COLORS,  Value: WPMWidget.use_colors ? "1" : "0" })
    Updates.Push({ Section: "Script", Key: WPMWidgetConst.CFG_GRAPH,   Value: WPMWidget.show_graph  ? "1" : "0" })

    ; [LLM] section — IA feature settings
    Updates.Push({ Section: "LLM", Key: "enabled",             Value: _LLM_Tray["enabled"] ? "1" : "0" })
    Updates.Push({ Section: "LLM", Key: "model",               Value: _LLM_Tray["model"] })
    Updates.Push({ Section: "LLM", Key: "profile_id",          Value: _LLM_Tray["profile_id"] })
    Updates.Push({ Section: "LLM", Key: "n_predictions",       Value: String(_LLM_Tray["n_predictions"]) })
    Updates.Push({ Section: "LLM", Key: "min_words",           Value: String(_LLM_Tray["min_words"]) })
    Updates.Push({ Section: "LLM", Key: "max_words",           Value: String(_LLM_Tray["max_words"]) })
    Updates.Push({ Section: "LLM", Key: "debounce_ms",         Value: String(_LLM_Tray["debounce_ms"]) })
    Updates.Push({ Section: "LLM", Key: "ctx_chars",           Value: String(_LLM_Tray["ctx_chars"]) })
    Updates.Push({ Section: "LLM", Key: "temperature",         Value: _LLM_Tray["temperature"] })
    Updates.Push({ Section: "LLM", Key: "instant_on_word_end", Value: _LLM_Tray["instant_on_word_end"] ? "1" : "0" })
    Updates.Push({ Section: "LLM", Key: "auto_profile_for_model", Value: _LLM_Tray["auto_profile_for_model"] ? "1" : "0" })

    ; Strict schema: rewrite from scratch so stale/unknown sections and keys
    ; are removed on each full save
    if FileExist(ConfigurationFile) {
        try FileDelete(ConfigurationFile)
    }

    PrevCanonState := _TOML_STRICT_CANON_IN_PROGRESS
    _TOML_STRICT_CANON_IN_PROGRESS := true
    try TOML_BatchWrite(ConfigurationFile, Updates)
    finally _TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState
    TOML_FormatViaScript(ConfigurationFile)
}

; Recursively walk the Features map to collect all persistable properties
; into the Updates array. Leaf features are flattened into their parent section:
;   [Rolls]  CT = true
;   [TapHolds.CapsLock]  EnterCtrl = true
; Extra props use FeatureName_Prop keys:
;   [TapHolds.LAlt]  BackSpaceLayer_TimeActivationSeconds = 0.2
; This mirrors how Hammerspoon groups modules into compact sections.
_CollectFeatureUpdates(Updates, ParentPath, Node) {
    ExtraProps := ["TimeActivationSeconds", "Letter", "PatternMaxLength",
        "Link", "DestinationFolder", "DatedNotes", "SearchEngine", "SearchEngineURLQuery"]

    for Key, Value in Node {
        if Key == "__Order" or Key == "__Configuration" {
            continue
        }
        ; Translate top-level category names to their TOML section (e.g. Autocorrection →
        ; Hotstrings.Autocorrection). Sub-levels already carry the translated prefix.
        TomlKey := (ParentPath == "") ? _TomlSection(Key) : Key
        CurrentPath := (ParentPath == "") ? TomlKey : ParentPath "." Key

        if Type(Value) == "Map" {
            ; Sub-map: __Configuration props go directly into [CurrentPath], then recurse
            if Value.Has("__Configuration") {
                Cfg := Value["__Configuration"]
                for Prop in ExtraProps {
                    if Cfg.HasOwnProp(Prop) {
                        Updates.Push({ Section: CurrentPath, Key: Prop, Value: Cfg.%Prop% })
                    }
                }
            }
            _CollectFeatureUpdates(Updates, CurrentPath, Value)
        } else if IsObject(Value) {
            ; Leaf feature: flatten into ParentPath section.
            ; Enabled maps to the feature name key; other props use FeatureName_Prop.
            if Value.HasOwnProp("Enabled") {
                Updates.Push({ Section: ParentPath, Key: Key, Value: Value.Enabled })
            }
            for Prop in ExtraProps {
                if Value.HasOwnProp(Prop) {
                    Updates.Push({ Section: ParentPath, Key: Key "_" Prop, Value: Value.%Prop% })
                }
            }
        }
    }
}

ReloadWithDefaultConfig(*) {
    ; Delete the config so the next startup uses all default values, then reload
    if FileExist(ConfigurationFile) {
        FileDelete(ConfigurationFile)
    }
    Reload
}

; Read the user's per-slot action overrides from the config's
; [Shortcuts.ScriptControl] section. Defaults stay in place when the key is absent or the action name is
; unknown. Called once at boot from initMenu's preamble.
ReadScriptShortcutsConfig() {
    global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Value := IniCacheGet(_IniCache, "Shortcuts.ScriptControl", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value))) {
            ScriptShortcutAssignments[Slot] := Value
        }
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
    TOML_Write(ActionName, ConfigurationFile, "Shortcuts.ScriptControl", Slot)
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
        SMenu.Add(SlotLabel . " : " . CurrentLabel,
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

; Read per-slot action overrides from [Shortcuts.Keyboard] in the config TOML.
ReadKeyboardShortcutsConfig() {
    global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache, GESTURE_ACTIONS
    LoggerStart("KeyboardShortcuts", "Chargement des raccourcis clavier configurables…")
    ; Seed with defaults first
    for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
        KeyboardShortcutAssignments[Slot] := Action
    ; Apply any user overrides persisted in the TOML
    OverrideCount := 0
    for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
        Value := IniCacheGet(_IniCache, "Shortcuts.Keyboard", Slot)
        if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value))) {
            KeyboardShortcutAssignments[Slot] := Value
            OverrideCount++
            LoggerDebug("KeyboardShortcuts", "Surcharge TOML : '%s' → '%s'.", Slot, Value)
        }
    }
    LoggerSuccess("KeyboardShortcuts", "Raccourcis clavier chargés (%d défaut(s), %d surcharge(s)).",
        KEYBOARD_SHORTCUT_DEFAULTS.Count, OverrideCount)
}

; Execute the configured action for a keyboard shortcut slot.
RunKeyboardShortcutAction(SlotId) {
    global KeyboardShortcutAssignments, GESTURE_ACTIONS
    Action := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
    if (Action == "none" or !GESTURE_ACTIONS.Has(Action)) {
        LoggerDebug("KeyboardShortcuts", "Raccourci '%s' ignoré (action : '%s').", SlotId, Action)
        return
    }
    LoggerDebug("KeyboardShortcuts", "Raccourci '%s' → '%s' déclenché.", SlotId, Action)
    GESTURE_ACTIONS[Action].Fn.Call()
}

; Persist a slot assignment and reload.
SetKeyboardShortcutAction(SlotId, ActionName) {
    global KeyboardShortcutAssignments, ConfigurationFile
    KeyboardShortcutAssignments[SlotId] := ActionName
    TOML_Write(ActionName, ConfigurationFile, "Shortcuts.Keyboard", SlotId)
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
; Current   : currently assigned action id (or "none")
; OnConfirm : callback(ActionId) called when the user validates their pick
ShowActionPicker(Title, Current, OnConfirm) {
    global GESTURE_ACTION_NAMES, GESTURE_ACTIONS
    LoggerStart("ActionPicker", "Ouverture du sélecteur '%s'…", Title)

    ; Build the source data: parallel arrays of ids and display labels.
    ; Category headers are stored with id="" so ConfirmPick can ignore them.
    ; AllItems holds {Id, Label, Cat} for re-filtering with category re-injection.
    AllItems    := []  ; [{Id, Label, Cat}] — action rows only (no header rows)

    _PushItem(Id, Label, Cat) {
        AllItems.Push({ Id: Id, Label: Label, Cat: Cat })
    }

    ; "Désactivé" entry (no category)
    _PushItem("none", t("dialog.action_picker.disabled"), "")

    CurrentCat := ""
    for ActionName in GESTURE_ACTION_NAMES {
        if (ActionName == "--")
            continue
        if (SubStr(ActionName, 1, 1) = "#") {
            CurrentCat := SubStr(ActionName, 2)
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

    ; Pre-select current action
    SelectedIdx := 0
    for i, Id in FilteredIds {
        if (Id == Current) {
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
                ; id="" is the "none" entry — keep it if it matches
                if (Item.Id == "none") {
                    if InStr(StrLower(Item.Label), Query)
                        Matched.Push(Item)
                } else if InStr(StrLower(Item.Label), Query) {
                    Matched.Push(Item)
                }
            }
        }
        NewRows     := BuildListRows(Matched)
        FilteredIds := NewRows.Ids
        LB.Delete()
        for Lbl in NewRows.Labels
            LB.Add(Lbl)
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
        ; Ignore clicks on category headers
        if (ChosenId == "")
            return
        W.Destroy()
        LoggerSuccess("ActionPicker", "Sélection confirmée → '%s'.", ChosenId)
        OnConfirm(ChosenId)
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
    if A_IsSuspended {
        Suspend(0)
    } else {
        Suspend(1)
    }
    UpdateTrayIcon()
    LoggerInfo("ErgoptiPlus", "Suspend toggled: {1}.", A_IsSuspended ? "ON" : "OFF")
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

; ================================================
; ======= 1.5) Script management shortcuts =======
; ================================================

; We use GetKeyState("SC138", "P") to make sure the AltGr key is pressed
; It avoids a bug where AltGr + Enter pauses the script, but then pressing BackSpace alone triggers a reload
; This bug for example happens if the keyboard layout is QWERTY

; Each combo double-checks both keys with GetKeyState — works around an
; AltGr+Enter quirk on some QWERTY layouts where pressing BackSpace alone
; would otherwise replay a stale AltGr+BackSpace event and reload the script.

; Known limitation: suspending via the tray menu disables these combos as
; well. Suspend(1) drops the SC138 / RAlt prefix from AHK's keyboard hook
; once the 60+ non-exempt SC138 & xxx combos from layout_altgr.ahk get
; suspended — and the #SuspendExempt directive does not survive that.
; Workaround for the user: resume by clicking the tray menu entry again.

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
_ScriptAltGrEnterHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC01C", "P")) {
        RunScriptShortcutAction("script_altgr_enter")
    } else {
        SendInput("{Enter}")
    }
}

_ScriptAltGrBackSpaceHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC00E", "P")) {
        RunScriptShortcutAction("script_altgr_backspace")
    } else {
        SendInput("{BackSpace}")
    }
}

_ScriptAltGrDeleteHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC153", "P")) {
        RunScriptShortcutAction("script_altgr_delete")
    } else {
        SendInput("{Delete}")
    }
}

_ScriptAltGrEscapeHandler(*) {
    if (GetKeyState("SC138", "P") and GetKeyState("SC001", "P")) {
        RunScriptShortcutAction("script_altgr_escape")
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
    HotIf((*) => IsRealAltGrPress())
    Hotkey("RAlt & Enter",     _ScriptAltGrEnterHandler,     "I2")
    Hotkey("SC138 & SC01C",    _ScriptAltGrEnterHandler,     "I2")
    Hotkey("RAlt & BackSpace", _ScriptAltGrBackSpaceHandler, "I2")
    Hotkey("SC138 & SC00E",    _ScriptAltGrBackSpaceHandler, "I2")
    Hotkey("RAlt & Delete",    _ScriptAltGrDeleteHandler,    "I2")
    Hotkey("SC138 & SC153",    _ScriptAltGrDeleteHandler,    "I2")
    Hotkey("RAlt & Escape",    _ScriptAltGrEscapeHandler,    "I2")
    Hotkey("SC138 & SC001",    _ScriptAltGrEscapeHandler,    "I2")
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
if Features.Has("Personal") {
    for SectionName, SectionConfig in Features["Personal"] {
        if SectionName == "__Order" {
            continue
        }
        if IsObject(SectionConfig) and SectionConfig.HasOwnProp("Enabled") and SectionConfig.Enabled {
            LoadHotstringsSection("personal", FoldAsciiLower(SectionName), SectionConfig)
        }
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
