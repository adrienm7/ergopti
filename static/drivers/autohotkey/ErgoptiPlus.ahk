; Last modified on 2026-04-23 at 00:00 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

; Compute _StaticDir early so i18n.ahk and any module-level t() calls that run
; during #Include processing can resolve locale file paths. _StaticDir is later
; re-confirmed at line ~184 via SplitPath — the two computations are identical.
SplitPath(A_ScriptDir, , &_DriversDir_early)    ; static/drivers
SplitPath(_DriversDir_early, , &_StaticDir)     ; static
global _StaticDir

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
; i18n module — must come after toml_loader.ahk (TOML_BatchWrite) and logger.ahk
#Include lib/i18n.ahk
#Include lib/onboarding.ahk
#Include lib/hotstrings/hotstrings_config.ahk
#Include lib/hotstrings/hotstrings_config_window.ahk
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
#Include modules/keylogger/keylogger_reader.ahk
#Include modules/keylogger/keylogger_prefetch.ahk
#Include modules/keylogger/keylogger_webview.ahk
#Include modules/keylogger/keylogger_ui.ahk
#Include modules/llm/api_ollama.ahk
#Include modules/llm/models.ahk
#Include modules/llm/profiles.ahk
#Include modules/llm/prediction_engine.ahk
#Include modules/llm/llm_bridge.ahk
#Include modules/llm/ollama_deps_checker.ahk
#Include ui/tooltip_llm.ahk
#Include ui/tray_llm.ahk

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
global CapsWordEnabled := False ; If the keyboard layer is currently in CapsWord state
global LayerEnabled := False ; If the keyboard layer is currently in navigation state
global NumberOfRepetitions := 1 ; Same as Vim where 3w does the w action 3 times, we can do the same in the navigation layer
global ActivitySimulation := False
global OneShotShiftEnabled := False
global _TOML_STRICT_CANON_IN_PROGRESS := false

; Read path overrides from paths.toml — same file format as Hammerspoon.
; Auto-generated with defaults if absent.
global _PathsFile := A_ScriptDir . "\paths.toml"
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

; Resolve the shared static/img/logo directory by walking up two levels from
; the script location (static/drivers/autohotkey → static/drivers → static).
; Building a fully-normalized absolute path avoids any '..' traversal that
; TraySetIcon may refuse to resolve on some Windows configurations.
SplitPath(A_ScriptDir, , &_DriversDir)         ; <repo>/static/drivers
SplitPath(_DriversDir, , &_StaticDir)          ; <repo>/static
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
; data literal. INI overrides are still applied by ReadConfiguration() below, and
; TOML metadata is still injected by ApplyTomlMetadataToFeatures() after that.
#Include lib/features_config.ahk

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

; =============================================================
; ======= 1.3) Tray menu of the script — Menus creation =======
; =============================================================

global SubMenus := Map()

CreateSubMenusRecursive(MenuParent, Items, CategoryPath) {
    global SubMenus

    if GetFeatureByPath(CategoryPath).Has("__Order") {
        ; Virtual grouping: ">Label" opens a transient submenu (no Features
        ; counterpart needed) and "<" closes it. Lets us tidy long flat menus
        ; without changing feature paths consumed elsewhere.
        MenuStack := [MenuParent]
        for Feature in GetFeatureByPath(CategoryPath)["__Order"] {
            CurrentMenu := MenuStack[MenuStack.Length]
            if Feature == "-" {
                CurrentMenu.Add() ; Empty line
                continue
            }
            if (SubStr(Feature, 1, 1) == ">") {
                GroupKey := Trim(SubStr(Feature, 2))
                ; If the key contains a dot it's an i18n key, otherwise literal label
                GroupLabel := InStr(GroupKey, ".") ? t(GroupKey) : GroupKey
                GroupMenu := Menu()
                CurrentMenu.Add(GroupLabel, GroupMenu)
                MenuStack.Push(GroupMenu)
                continue
            }
            if (Feature == "<") {
                if (MenuStack.Length > 1) {
                    MenuStack.Pop()
                }
                continue
            }
            Key := Feature
            Val := GetFeatureByPath(CategoryPath)[Feature]
            CreateSubMenusRecursiveCommonCode(CurrentMenu, Key, Val, CategoryPath)
        }
    } else {
        for Key, Val in Items {
            if Key == "__Configuration" {
                continue
            }
            CreateSubMenusRecursiveCommonCode(MenuParent, Key, Val, CategoryPath)
        }
    }
}

CreateSubMenusRecursiveCommonCode(MenuParent, Key, Val, CategoryPath) {
    FullPath := CategoryPath "." Key

    if (Type(Val) == "Map") {
        ; Create submenu and store in SubMenus. The visible label defaults to
        ; the raw map key but can be overridden by GetSubMenuLabel for paths
        ; whose code identifier is intentionally English while the menu UI is
        ; French (Shortcuts.Personal → « Raccourcis personnels », …).
        SubMenu := Menu()
        MenuParent.Add(GetSubMenuLabel(FullPath, Key), SubMenu)
        SubMenus[FullPath] := SubMenu
        ; Recursively create nested submenus
        CreateSubMenusRecursive(SubMenu, Val, FullPath)
    } else if IsObject(Val) and Val.HasOwnProp("Enabled") {
        ; Features that carry a remap target letter (the EGrave/ECirc/EAcute/
        ; AGrave accent shortcuts) render as a letter-picker sub-submenu so
        ; the user can pick any of a-z directly from the tray instead of
        ; juggling a binary toggle plus a separate Gui editor.
        if Val.HasOwnProp("Letter") {
            MenuAddLetterPicker(MenuParent, CategoryPath, Key)
        } else {
            MenuAddItem(MenuParent, CategoryPath, Key)
        }
        ; Mirror HS personal_info module_placeholder: add an editor shortcut
        ; below the "Remplissage de formulaires" toggle
        if (StrLower(Key) == "textexpansionpersonalinformation") {
            MenuParent.Add(t("menu.shortcuts.edit_personal_info"), PersonalInformationEditor)
        }
        ; Mirror HS ctrl_g pattern: inject the URL editor right below the GPT toggle
        if (StrLower(Key) == "gpt") {
            MenuParent.Add(t("menu.shortcuts.edit_gpt_link"), GPTLinkEditor)
        }
    }
}

MenuAddItem(MenuParent, FeatureCategoryPath, FeatureName) {
    FullPath := FeatureCategoryPath "." FeatureName
    MenuTitle := GetMenuTitleByPath(FullPath)
    MenuParent.Add(MenuTitle, (*) => ToggleMenuVariableByPath(FullPath))

    Feature := GetFeatureByPath(FullPath)
    if Feature.Enabled {
        MenuParent.Check(MenuTitle)
    } else {
        MenuParent.Uncheck(MenuTitle)
    }
}

; Build a sub-submenu listing « Désactivé » + a-z, with the currently active
; letter checked. Picking a letter sets it as the new mapping and enables
; the feature; picking « Désactivé » turns the feature off without losing
; the previously-selected letter (it is re-checked the next time the user
; re-enables via picking any letter). The parent menu entry stays checked
; whenever the feature is enabled, and its label remains the canonical
; "<description><LETTER>" string built by GetMenuTitleByPath.
MenuAddLetterPicker(MenuParent, FeatureCategoryPath, FeatureName) {
    FullPath := FeatureCategoryPath "." FeatureName
    Feature := GetFeatureByPath(FullPath)
    MenuTitle := GetMenuTitleByPath(FullPath)

    LetterMenu := Menu()

    ; Entry that disables the remap without touching Letter
    DisabledLabel := t("common.disabled")
    LetterMenu.Add(DisabledLabel, ((p) => (*) => SetFeatureLetterOff(p))(FullPath))
    if !Feature.Enabled {
        LetterMenu.Check(DisabledLabel)
    }

    LetterMenu.Add() ; Separator

    ; 26 letters a-z, displayed uppercase for menu legibility
    CurrentLetter := Feature.HasOwnProp("Letter") ? StrLower(Feature.Letter) : ""
    loop 26 {
        L := Chr(Ord("a") + A_Index - 1)
        UpperL := StrUpper(L)
        LetterMenu.Add(UpperL, ((p, l) => (*) => SetFeatureLetter(p, l))(FullPath, L))
        if Feature.Enabled and CurrentLetter == L {
            LetterMenu.Check(UpperL)
        }
    }

    MenuParent.Add(MenuTitle, LetterMenu)
    if Feature.Enabled {
        MenuParent.Check(MenuTitle)
    }
}

; Sets the remap target letter on a feature and enables it. Persists both
; flags via TOML_Write so the change survives reload, then reloads to wire
; the new shortcut at the layer level.
SetFeatureLetter(FullPath, Letter) {
    Feature := GetFeatureByPath(FullPath)
    pos := InStr(FullPath, ".", , -1)
    FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)
    FeatureName := SubStr(FullPath, pos + 1)

    Feature.Enabled := true
    Feature.Letter := Letter
    TOML_Write(true, ConfigurationFile, FeatureCategoryPath, FeatureName)
    TOML_Write(Letter, ConfigurationFile, FeatureCategoryPath, FeatureName "_Letter")
    Reload
}

; Disables a letter-picker feature without touching its Letter, so the
; previously-selected mapping is restored on the next picker selection.
SetFeatureLetterOff(FullPath) {
    Feature := GetFeatureByPath(FullPath)
    pos := InStr(FullPath, ".", , -1)
    FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)
    FeatureName := SubStr(FullPath, pos + 1)

    Feature.Enabled := false
    TOML_Write(false, ConfigurationFile, FeatureCategoryPath, FeatureName)
    Reload
}

; Resolve the visible label of a sub-Map menu entry. Defaults to the raw
; FallbackKey (the map key as written in features_config.ahk), but lets us
; localise specific paths whose code identifier is intentionally English
; while the menu UI is French. Add a case here whenever a new sub-Map needs
; a different label than its key — the rest of the menu builder picks it up
; automatically through CreateSubMenusRecursiveCommonCode.
GetSubMenuLabel(FullPath, FallbackKey) {
    switch FullPath {
        case "Shortcuts.Personal":
            return t("menu.shortcuts.personal")
    }
    return FallbackKey
}

; Retrieve a feature title by its path
GetMenuTitleByPath(FullPath) {
    Feature := GetFeatureByPath(FullPath)
    if !IsObject(Feature)
        return FullPath

    if Feature.HasOwnProp("Description") {
        MenuTitle := Feature.Description
        if Feature.HasOwnProp("Letter")
            MenuTitle := MenuTitle StrUpper(Feature.Letter)
        return MenuTitle
    }
    return FullPath
}

; Retrieve a feature object by its path
GetFeatureByPath(FullPath) {
    Keys := StrSplit(FullPath, ".")
    Feature := Features
    for K in Keys {
        Feature := Feature[K]
    }
    return Feature
}

ToggleMenuVariableByPath(FullPath) {
    Feature := GetFeatureByPath(FullPath)
    CurrentFeatureActivation := Feature.Enabled ; Needs to be saved before turning off all shortcuts of the category

    ; Find position of the last dot
    pos := InStr(FullPath, ".", , -1)
    if (pos) {
        FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)   ; everything left of the last dot
        FeatureName := SubStr(FullPath, pos + 1)              ; everything right of the last dot
    } else {
        FeatureCategoryPath := FullPath
        FeatureName := ""
    }

    ; Count dot levels in FullPath
    DotCount := StrLen(FullPath) - StrLen(StrReplace(FullPath, ".", ""))
    if (DotCount >= 2) {
        ; Set to False all shortcut possibilities
        FeatureCategory := GetFeatureByPath(FeatureCategoryPath)
        for ShortcutName in FeatureCategory {
            Shortcut := FeatureCategory.Get(ShortcutName)
            Shortcut.Enabled := False
            TOML_Write(Shortcut.Enabled, ConfigurationFile, FeatureCategoryPath, ShortcutName)
        }
    }
    Feature.Enabled := !CurrentFeatureActivation
    TOML_Write(Feature.Enabled, ConfigurationFile, FeatureCategoryPath, FeatureName)
    Reload
}

GetCategoryTitle(Category) {
    switch Category {
        case "DistancesReduction":
            return t("category.distances_reduction")
        case "SFBsReduction":
            return t("category.sfbs_reduction")
        case "Rolls":
            return t("category.rolls")
        case "Autocorrection":
            return t("category.autocorrection")
        case "MagicKey":
            return t("category.magic_key")
        case "DynamicHotstrings":
            return t("category.dynamic_hotstrings")
        case "Personal":
            return t("category.personal")
        case "Shortcuts":
            return t("category.shortcuts")
        case "TapHolds":
            return t("category.tapholds")
        case "Gestures":
            return t("category.gestures")
        default:
            return ""
    }
}

; ===================================
; Gestures menu builder
; ===================================

BuildGesturesMenu() {
    global Features, GestureAssignments, GESTURE_SLOTS, GESTURE_ACTIONS, GESTURE_SLOT_LABELS

    GMenu := Menu()

    ; Canonical category toggle — inserted at position 1 with separator at 2.
    GestEnabled := Features["Gestures"]["Enabled"].Enabled
    AddCategoryToggleItem(GMenu,
        t("menu.gestures.on"),
        t("menu.gestures.off"),
        GestEnabled,
        (*) => ToggleGesturesEnabled())

    GMenu.Add(t("menu.gestures.auto_configure"),  (*) => GestureAutoConfigureAction())
    GMenu.Add(t("menu.gestures.instructions"),    (*) => GestureShowSetupInstructions())
    GMenu.Add(t("menu.gestures.open_touchpad"),   (*) => GestureOpenTouchpadSettings())

    GMenu.Add()

    ; Each slot becomes a single clickable item that opens a lazy GUI picker —
    ; avoids pre-building hundreds of submenus (N slots × M actions).
    for Slot in GESTURE_SLOTS {
        if (Slot == "tap_4")
            GMenu.Add()
        SlotLabel     := t("gesture.slots." . Slot)
        CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
        CurrentLabel  := GESTURE_ACTIONS.Has(CurrentAction) ? _GestureActionLabel(CurrentAction) : t("dialog.action_picker.disabled")
        EntryLabel    := SlotLabel . " : " . CurrentLabel
        GMenu.Add(EntryLabel, ((_s, _l) => (*) => ShowActionPicker(_l, GestureAssignments.Has(_s) ? GestureAssignments[_s] : "none", (Id) => SetGestureSlotAction(_s, Id)))(Slot, SlotLabel))
        if !GestEnabled
            GMenu.Disable(EntryLabel)
    }

    return GMenu
}

; Applies a new action to a gesture slot and reloads.
SetGestureSlotAction(Slot, ActionName) {
    GestureSaveAssignment(Slot, ActionName)
    Reload
}

; Toggles the Gestures enabled state and reloads.
ToggleGesturesEnabled() {
    global Features, ConfigurationFile
    Features["Gestures"]["Enabled"].Enabled := !Features["Gestures"]["Enabled"].Enabled
    TOML_Write(Features["Gestures"]["Enabled"].Enabled, ConfigurationFile, "Gestures", "Enabled")
    Reload
}

; ====================================
; ====================================
; ======= 1.X / Category toggle =======
; ====================================
; ====================================

; Insert the canonical « ✅ X activé(s) (cliquer pour désactiver) » /
; « ❌ X désactivé(s) (cliquer pour activer) » synthetic top item into a
; submenu, followed by a separator at position 2. AHK does not let us
; bind a callback on the parent label of a submenu (clicks open the
; submenu), so this is how every category exposes its global on/off
; toggle in a uniform way — same pattern Métriques uses.
;
; ``on_label`` and ``off_label`` are passed in full (not built from a
; template) so each category keeps its own French gender/number
; agreement: « activée » for « Disposition », « activés » for
; « Raccourcis », « activées » for « Métriques », etc.
AddCategoryToggleItem(menu, on_label, off_label, is_enabled, on_click) {
    label := is_enabled ? on_label : off_label
    menu.Insert("1&", label, on_click)
    menu.Insert("2&")  ; separator
}

; ====================================
; ====================================
; ======= 1.X / Metrics menu =======
; ====================================
; ====================================

; Build the « 📊 Métriques » submenu and attach it to the tray. The parent
; entry doubles as an ON/OFF toggle for the global keylogger feature: the
; checkmark reflects MetricsShortcuts.enabled, and clicking it triggers
; ToggleMetricsEnabled() with a confirmation dialog before turning ON.
;
; When the feature is OFF, the sub-items remain visible (so the user can
; still see what the menu looks like) but are disabled — no dashboard can
; open, no shortcut binding takes effect.
; Global reference kept so toggle callbacks can call .ToggleCheck without Reload.
global _MetricsMenu := unset
global _WpmMenubarLabel := ""
global _WpmWidgetLabel  := ""
global _WpmMenubarColorsLabel := ""
global _WpmWidgetColorsLabel  := ""
global _WpmWidgetGraphLabel   := ""

BuildMetricsMenu() {
    global A_TrayMenu, _MetricsMenu
    global _WpmMenubarLabel, _WpmWidgetLabel
    global _WpmMenubarColorsLabel, _WpmWidgetColorsLabel, _WpmWidgetGraphLabel
    MetricsMenu := Menu()
    _MetricsMenu := MetricsMenu

    enabled := MetricsShortcuts.enabled
    typing_label := t("menu.metrics.show_typing")
    apps_label   := t("menu.metrics.show_apps")
    ; A trailing zero-width space differentiates the second « ↳ Raccourci :
    ; Aucun » entry from the first — AHK’s tray menu uses the label as a
    ; unique key and would silently merge two identical strings into one.
    typing_sc := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("typing")
    apps_sc   := t("menu.metrics.shortcut_prefix") . MS_GetDisplayLabel("apps") . Chr(0x200B)

    MetricsMenu.Add(typing_label, (*) => KLUI_ToggleTyping())
    MetricsMenu.Add(typing_sc, (*) => MS_PromptShortcut("typing", KLUI_ToggleTyping))
    MetricsMenu.Add() ; separator
    MetricsMenu.Add(apps_label, (*) => KLUI_ToggleApps())
    MetricsMenu.Add(apps_sc, (*) => MS_PromptShortcut("apps", KLUI_ToggleApps))

    MetricsMenu.Add()
    privacy_header := MenuSectionTitle(t("menu.metrics.privacy_header"))
    MetricsMenu.Add(privacy_header, (*) => "")
    MetricsMenu.Disable(privacy_header)

    private_label := t("menu.metrics.filter_private")
    MetricsMenu.Add(private_label, ToggleFilterPrivate)
    if MetricsFilters.private_browsing
        MetricsMenu.Check(private_label)

    secure_label := t("menu.metrics.filter_secure")
    MetricsMenu.Add(secure_label, ToggleFilterSecureField)
    if MetricsFilters.secure_field
        MetricsMenu.Check(secure_label)

    sysauth_label := t("menu.metrics.filter_sysauth")
    MetricsMenu.Add(sysauth_label, ToggleFilterSystemAuth)
    if MetricsFilters.system_auth
        MetricsMenu.Check(sysauth_label)

    ; App exclusion entry — label reflects the count, click opens the
    ; reusable AppPicker Gui. Mirror of HS « Désactivé dans N application(s) ».
    n := MF_DisabledCount()
    excl_label := (n > 0)
        ? t("menu.metrics.disabled_in_prefix") . n . (n > 1 ? t("menu.metrics.disabled_in_suffix_p") : t("menu.metrics.disabled_in_suffix_s"))
        : t("menu.metrics.exclude_apps")
    MetricsMenu.Add(excl_label, OpenMetricsAppPicker)

    ; ── Real-time WPM display ──────────────────────────────────────────────
    MetricsMenu.Add()
    _WpmMenubarLabel        := t("menu.metrics.show_wpm_menubar")
    _WpmMenubarColorsLabel  := t("menu.metrics.colors_by_source") . Chr(0x200B)
    _WpmWidgetLabel         := t("menu.metrics.show_wpm_widget")
    _WpmWidgetColorsLabel   := t("menu.metrics.colors_by_source")
    _WpmWidgetGraphLabel    := t("menu.metrics.include_realtime")

    MetricsMenu.Add(_WpmMenubarLabel,       (*) => ToggleWpmMenubar())
    MetricsMenu.Add(_WpmMenubarColorsLabel, (*) => ToggleWpmMenubarColors())
    MetricsMenu.Add()
    MetricsMenu.Add(_WpmWidgetLabel,        (*) => ToggleWpmWidget())
    MetricsMenu.Add(_WpmWidgetColorsLabel,  (*) => ToggleWpmWidgetColors())
    MetricsMenu.Add(_WpmWidgetGraphLabel,   (*) => ToggleWpmWidgetGraph())

    if MetricsShortcuts.show_wpm_menubar
        MetricsMenu.Check(_WpmMenubarLabel)
    if MetricsShortcuts.show_wpm_menubar && MetricsShortcuts.wpm_menubar_colors
        MetricsMenu.Check(_WpmMenubarColorsLabel)
    if WPMWidget.visible
        MetricsMenu.Check(_WpmWidgetLabel)
    if WPMWidget.visible && WPMWidget.use_colors
        MetricsMenu.Check(_WpmWidgetColorsLabel)
    if WPMWidget.visible && WPMWidget.show_graph
        MetricsMenu.Check(_WpmWidgetGraphLabel)

    ; Sub-options are disabled when their parent toggle is off.
    if !MetricsShortcuts.show_wpm_menubar
        MetricsMenu.Disable(_WpmMenubarColorsLabel)
    if !WPMWidget.visible {
        MetricsMenu.Disable(_WpmWidgetColorsLabel)
        MetricsMenu.Disable(_WpmWidgetGraphLabel)
    }

    if !enabled {
        MetricsMenu.Disable(typing_label)
        MetricsMenu.Disable(typing_sc)
        MetricsMenu.Disable(apps_label)
        MetricsMenu.Disable(apps_sc)
        MetricsMenu.Disable(private_label)
        MetricsMenu.Disable(secure_label)
        MetricsMenu.Disable(sysauth_label)
        MetricsMenu.Disable(excl_label)
        MetricsMenu.Disable(_WpmMenubarLabel)
        MetricsMenu.Disable(_WpmMenubarColorsLabel)
        MetricsMenu.Disable(_WpmWidgetLabel)
        MetricsMenu.Disable(_WpmWidgetColorsLabel)
        MetricsMenu.Disable(_WpmWidgetGraphLabel)
    }

    A_TrayMenu.Add(t("menu.metrics.title"), MetricsMenu)
    ; Aligned with the canonical ✅/❌ pattern used by every other
    ; category submenu. The security-warning dialog still fires inside
    ; ToggleMetricsEnabled() before flipping ON, so the privacy
    ; safeguard stays in place — the icon change is purely cosmetic.
    AddCategoryToggleItem(MetricsMenu,
        t("menu.metrics.on"),
        t("menu.metrics.off"),
        MetricsShortcuts.enabled,
        (*) => ToggleMetricsEnabled())
}

; ── Filter toggles. Each persists + flips the corresponding flag and
; triggers a Reload so the menu rerenders with the new checkmark state
; (AHK Menu.Check / Uncheck cannot retro-update an entry whose label was
; built into the submenu reference; rebuilding the whole tray is cleaner
; than playing with .ToggleCheck on a stale label).
ToggleFilterPrivate(*) {
    MetricsFilters.private_browsing := !MetricsFilters.private_browsing
    MF_SaveToIni()
    Reload
}

ToggleFilterSecureField(*) {
    MetricsFilters.secure_field := !MetricsFilters.secure_field
    MF_SaveToIni()
    Reload
}

ToggleFilterSystemAuth(*) {
    MetricsFilters.system_auth := !MetricsFilters.system_auth
    MF_SaveToIni()
    Reload
}

; ── WPM toggle callbacks — no Reload; ToggleCheck updates the menu live. ──────

ToggleWpmMenubar(*) {
    global _MetricsMenu, _WpmMenubarLabel, _WpmMenubarColorsLabel
    MetricsShortcuts.show_wpm_menubar := !MetricsShortcuts.show_wpm_menubar
    CS_Save()
    try _MetricsMenu.ToggleCheck(_WpmMenubarLabel)
    if MetricsShortcuts.show_wpm_menubar {
        SetTimer(WpmMenubar_Tick, 1000)
        try _MetricsMenu.Enable(_WpmMenubarColorsLabel)
    } else {
        SetTimer(WpmMenubar_Tick, 0)
        A_IconTip := "ErgoptiPlus"
        try _MetricsMenu.Disable(_WpmMenubarColorsLabel)
    }
}

ToggleWpmMenubarColors(*) {
    global _MetricsMenu, _WpmMenubarColorsLabel
    MetricsShortcuts.wpm_menubar_colors := !MetricsShortcuts.wpm_menubar_colors
    CS_Save()
    try _MetricsMenu.ToggleCheck(_WpmMenubarColorsLabel)
}

ToggleWpmWidget(*) {
    global _MetricsMenu, _WpmWidgetLabel, _WpmWidgetColorsLabel, _WpmWidgetGraphLabel
    WPMWidget_Toggle()
    try _MetricsMenu.ToggleCheck(_WpmWidgetLabel)
    if WPMWidget.visible {
        try _MetricsMenu.Enable(_WpmWidgetColorsLabel)
        try _MetricsMenu.Enable(_WpmWidgetGraphLabel)
    } else {
        try _MetricsMenu.Disable(_WpmWidgetColorsLabel)
        try _MetricsMenu.Disable(_WpmWidgetGraphLabel)
    }
}

ToggleWpmWidgetColors(*) {
    global _MetricsMenu, _WpmWidgetColorsLabel
    WPMWidget.use_colors := !WPMWidget.use_colors
    WPMWidget_SaveConfig()
    try _MetricsMenu.ToggleCheck(_WpmWidgetColorsLabel)
}

ToggleWpmWidgetGraph(*) {
    global _MetricsMenu, _WpmWidgetGraphLabel
    was_visible := WPMWidget.visible
    ; Rebuild the widget in the new mode — compact and graph use different Gui layouts.
    if was_visible
        WPMWidget_Hide()
    WPMWidget.show_graph := !WPMWidget.show_graph
    ; Destroy existing GUI so it is rebuilt in the correct layout on next show.
    if WPMWidget._gui {
        try WPMWidget._gui.Destroy()
        WPMWidget._gui      := false
        WPMWidget._lbl_wpm  := false
        WPMWidget._lbl_unit := false
    }
    if WPMWidget._graph_gui {
        try WPMWidget._graph_gui.Destroy()
        WPMWidget._graph_gui      := false
        WPMWidget._graph_wv       := false
        WPMWidget._graph_wv_ready := false
    }
    ; Reset saved position so default bottom-right is recalculated for new size.
    WPMWidget.pos_x := -1
    WPMWidget.pos_y := -1
    WPMWidget_SaveConfig()
    try _MetricsMenu.ToggleCheck(_WpmWidgetGraphLabel)
    if was_visible
        WPMWidget_Show()
}

; Updates A_IconTip with the current live WPM every second.
; When colors are enabled, appends the keystroke-origin tag [HS] or [IA].
WpmMenubar_Tick() {
    result := WPMWidget_Calc()
    wpm    := result["wpm"]
    if (wpm > 0) {
        suffix := ""
        if MetricsShortcuts.wpm_menubar_colors {
            if result["has_ai"]
                suffix := " [IA]"
            else if result["has_hs"]
                suffix := " [HS]"
        }
        A_IconTip := "ErgoptiPlus  |  " . wpm . " " . t("menu.metrics.wpm_unit") . suffix
    } else {
        A_IconTip := "ErgoptiPlus"
    }
}

OpenMetricsAppPicker(*) {
    AppPicker_Show(Map(
        "title",    t("dialog.metrics.exclude_title"),
        "prompt",   t("dialog.metrics.exclude_prompt"),
        "ok_label", t("dialog.metrics.exclude_ok"),
        "initial",  MF_DisabledList(),
        "on_save",  OnMetricsAppPickerSave
    ))
}

OnMetricsAppPickerSave(selected) {
    ; Replace the disabled-apps map wholesale with the picker's result —
    ; the user expects "what's checked = what's filtered", not "diff
    ; against the previous state".
    MetricsFilters.disabled_apps := Map()
    for proc in selected
        MetricsFilters.disabled_apps[StrLower(proc)] := true
    MF_SaveToIni()
    Reload
}

; Flip the global keylogger feature with a warning dialog before enabling.
; Persisted via metrics_shortcuts.ini and applied on Reload (the keylogger
; can only initialise its file IO at boot, not mid-session, mirroring the
; Hammerspoon behaviour where toggling the feature triggers HS reload).
ToggleMetricsEnabled() {
    if MetricsShortcuts.enabled {
        ; Disabling — no warning needed, just confirm.
        res := MsgBox(
            t("dialog.metrics.disable_confirm"),
            t("dialog.metrics.title"),
            "OKCancel Icon?"
        )
        if (res != "OK")
            return
        MetricsShortcuts.enabled := false
        MS_SaveToIni()
        Reload
        return
    }

    ; Enabling — explicit warning, OK is the dangerous action. The metrics
    ; folder lives under the user-resolved _ConfigDir (paths.toml override
    ; honoured) so the displayed path matches reality, even when the user
    ; has relocated their config.
    global _ConfigDir
    metrics_path := _ConfigDir . "metrics"
    warn := Format(t("dialog.metrics.enable_warning"), metrics_path)
    ; Icon! = exclamation triangle (warning). Iconx is the red error stop
    ; sign and was the wrong choice for a "you are about to enable a
    ; logging feature" notice.
    res := MsgBox(warn, t("dialog.metrics.security_warning_title"), "OKCancel Icon!")
    if (res != "OK")
        return
    MetricsShortcuts.enabled := true
    MS_SaveToIni()
    Reload
}

; Runs the auto-configure and shows the result to the user.
GestureAutoConfigureAction() {
    Success := GestureAutoConfigureRegistry()
    if (Success) {
        MsgBox(
            t("dialog.gestures.auto_configure_success"),
            t("dialog.gestures.auto_configure_title"),
            "Iconi"
        )
    } else {
        MsgBox(
            t("dialog.gestures.auto_configure_error"),
            t("dialog.gestures.auto_configure_error_title"),
            "Icon!"
        )
    }
}

; =========================
; Main menu initialization
; =========================

global MenuHotstrings := "⚡ Hotstrings"
global MenuConfigurationShortcuts := t("menu.script_control.title")
; Holds the « Suspendre » label so UpdateTrayIcon can check/uncheck the
; entry by its exact text on A_TrayMenu. Re-assigned in initMenu so future
; label tweaks (icons, hints) only need to change the menu builder.
global MenuSuspend := t("menu.global.suspend")
global MenuDebugging := t("menu.debug.title")

; Categories that live inside the Hotstrings submenu (ordered to match HS menu)
global HotstringCategories := ["DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey"]
; Standard (layout-agnostic) hotstring categories
global HotstringCategoriesStd := ["DistancesReduction", "Autocorrection", "MagicKey"]
; Layout-specific categories for the Ergopti keyboard disposition
global HotstringCategoriesErgopti := ["SFBsReduction", "Rolls"]

InitSubMenus() {
    global Features, SubMenus
    SubMenus := Map()
    for Category, Items in Features {
        if Category = "Layout" {
            continue
        }
        SubMenu := Menu()
        SubMenus[Category] := SubMenu ; Only top-level category stored
        CreateSubMenusRecursive(SubMenu, Items, Category)
    }
    ; Personal is defined in personal_shortcuts.ahk (not in the static Features map),
    ; so it must be wired separately after the loop — only when the user's file loaded it.
    if Features.Has("Personal") {
        PersonalSubMenu := Menu()
        SubMenus["Personal"] := PersonalSubMenu
        CreateSubMenusRecursive(PersonalSubMenu, Features["Personal"], "Personal")
    }
}

initMenu() {
    global Features, SubMenus, A_TrayMenu, HotstringCategories

    A_TrayMenu.Delete()

    ; Prepend a global on/off toggle at the top of the Raccourcis submenu —
    ; mirrors the HS pattern where clicking the parent title toggles the
    ; category. AHK does not support clickable parent titles, so the first
    ; item is the toggle.
    ;
    ; The checkbox reflects « at least one shortcut enabled » rather than
    ; « every shortcut enabled »: several built-ins (Save, CtrlJ, the AltGr
    ; combo variants, …) ship as off-by-default on purpose, so an « all
    ; enabled » metric would always render the toggle unchecked at first
    ; launch and falsely suggest the category is inactive. With « any
    ; enabled », the toggle ships checked for a fresh install (where most
    ; leaf features default to true) and the click action remains intuitive
    ; — when checked, click disables every shortcut; when unchecked, click
    ; re-enables every shortcut.
    if SubMenus.Has("Shortcuts") {
        ShortcutsAnyEnabled := HasAnyEnabled(Features["Shortcuts"])
        AddCategoryToggleItem(SubMenus["Shortcuts"],
            t("menu.shortcuts.on"),
            t("menu.shortcuts.off"),
            ShortcutsAnyEnabled,
            (*) => ToggleCategoryAllFeatures("Shortcuts", !ShortcutsAnyEnabled))
    }

    ; Insert the configurable keyboard shortcut groups just before the
    ; « Combinaison de modificateurs » group that CreateSubMenusRecursive already
    ; added — keeping the modifier combos visually grouped together.
    ; Then append « Raccourcis de gestion du script » at the bottom.
    if SubMenus.Has("Shortcuts") {
        InsertKeyboardShortcutGroups(SubMenus["Shortcuts"], t("menu.shortcuts.group_modifiers"))
        SubMenus["Shortcuts"].Add(t("menu.shortcuts.script_shortcuts"), BuildScriptShortcutsMenu())
    }

    ; ── 🌐 Disposition clavier — mirrors the HS layout submenu naming ──
    LayoutMenu := Menu()
    LayoutAnyEnabled := HasAnyEnabled(Features["Layout"])
    AddCategoryToggleItem(LayoutMenu,
        t("menu.layout.on"),
        t("menu.layout.off"),
        LayoutAnyEnabled,
        (*) => ToggleCategoryAllFeatures("Layout", !LayoutAnyEnabled))
    for FeatureName in Features["Layout"]["__Order"] {
        MenuAddItem(LayoutMenu, "Layout", FeatureName)
    }
    LayoutMenuTitle := t("menu.layout.title")
    A_TrayMenu.Add(LayoutMenuTitle, LayoutMenu)
    if LayoutAnyEnabled {
        A_TrayMenu.Check(LayoutMenuTitle)
    }

    ; ── Hotstrings ⚡ — single submenu grouping all hotstring categories ──
    ; Layout mirrors Hammerspoon builder.lua:
    ;   1. Global toggle + separator
    ;   2. Paramètres (config items) + separator
    ;   3. "— Hotstrings communs —" header + common TOML groups + dynamic
    ;   4. Separator + "— Hotstrings personnels —" header + personal TOML(s) + extensions
    HotstringsMenu := Menu()
    HotstringsAllEnabled := IsCategoryAllEnabled(HotstringCategories)
    AddCategoryToggleItem(HotstringsMenu,
        t("menu.hotstrings.on"),
        t("menu.hotstrings.off"),
        HotstringsAllEnabled,
        HotstringsAllEnabled ? ToggleAllHotstringsOff : ToggleAllHotstringsOn)

    ; 1. Paramètres — mirrors HS "⚙️ Paramètres hotstrings" submenu
    ParamsMenu := Menu()
    ParamsMenu.Add(t("menu.hotstrings.delays_colors"),
        (*) => OpenHotstringsConfigWindow())
    ParamsMenu.Add(t("menu.hotstrings.magic_key_prefix") . ScriptInformation["MagicKey"], MagicKeyEditor)
    HotstringsMenu.Add(t("menu.hotstrings.params"), ParamsMenu)
    HotstringsMenu.Add() ; Separator after paramètres block

    ; 2a. Standard hotstring groups + dynamic — "Hotstrings communs" header
    StdTotal := 0
    for _CCat in HotstringCategoriesStd {
        StdTotal += CountTomlHotstrings(_CCat)
    }
    DynTotalStd := 0
    for _DSec in Features["DynamicHotstrings"]["__Order"] {
        if (_DSec != "-" and Features["DynamicHotstrings"].Has(_DSec)
        and Features["DynamicHotstrings"][_DSec].Enabled) {
            DynTotalStd += CountDynamicSection(_DSec)
        }
    }
    StdTotal += DynTotalStd
    StdHeader := MenuSectionTitle(t("menu.hotstrings.common_header") . (StdTotal > 0 ? " (" . FmtCount(StdTotal) . ")" : ""))
    HotstringsMenu.Add(StdHeader, (*) => NoAction())
    HotstringsMenu.Disable(StdHeader)
    for Category in HotstringCategoriesStd {
        if SubMenus.Has(Category) {
            Total := CountTomlHotstrings(Category)
            Title := GetCategoryTitle(Category) . (Total > 0 ? " (" . FmtCount(Total) . ")" : "")
            HotstringsMenu.Add(Title, SubMenus[Category])
        }
    }
    ; Dynamic hotstrings — date insertion and future rule-based expansions.
    if Features.Has("DynamicHotstrings") and SubMenus.Has("DynamicHotstrings") {
        DynMenu := SubMenus["DynamicHotstrings"]
        DynTotal := 0
        for _DSec in Features["DynamicHotstrings"]["__Order"] {
            if (_DSec != "-" and Features["DynamicHotstrings"].Has(_DSec)
            and Features["DynamicHotstrings"][_DSec].Enabled) {
                DynTotal += CountDynamicSection(_DSec)
            }
        }
        DynTitle := GetCategoryTitle("DynamicHotstrings")
        . (DynTotal > 0 ? " (" . FmtCount(DynTotal) . ")" : "")
        HotstringsMenu.Add(DynTitle, DynMenu)
    }

    ; 2b. Ergopti-layout-specific groups — separated from the standard block
    HotstringsMenu.Add() ; Separator between communs and Ergopti blocks
    ErgoptiTotal := 0
    for _ECat in HotstringCategoriesErgopti {
        ErgoptiTotal += CountTomlHotstrings(_ECat)
    }
    ErgoptiHeader := MenuSectionTitle(t("menu.hotstrings.ergopti_header") . (ErgoptiTotal > 0 ? " (" . FmtCount(ErgoptiTotal) . ")" : ""))
    HotstringsMenu.Add(ErgoptiHeader, (*) => NoAction())
    HotstringsMenu.Disable(ErgoptiHeader)
    for Category in HotstringCategoriesErgopti {
        if SubMenus.Has(Category) {
            Total := CountTomlHotstrings(Category)
            Title := GetCategoryTitle(Category) . (Total > 0 ? " (" . FmtCount(Total) . ")" : "")
            HotstringsMenu.Add(Title, SubMenus[Category])
        }
    }

    ; CommonTotal = all groups (std + ergopti) used for GrandTotal
    CommonTotal := StdTotal + ErgoptiTotal

    ; 3. Personal/custom hotstrings — separator + disabled header + entries
    ; personal_hotstrings.toml first, then extra TOMLs from hotstrings\ folder alphabetically.
    TotalPersonal := 0
    if Features.Has("Personal") {
        ; Read personal_hotstrings.toml once to get section order, descriptions, and counts
        TomlData := ReadPersonalToml()
        ; Enrich Features["Personal"] descriptions with entry counts
        for _, SecName in TomlData["sections_order"] {
            SecData := TomlData["sections"][SecName]
            Count := SecData["entries"].Length
            BaseDesc := SecData["description"]
            for FeatKey in Features["Personal"] {
                if (FeatKey != "__Order" and StrLower(FeatKey) == SecName) {
                    Features["Personal"][FeatKey].Description := BaseDesc . " (" . FmtCount(Count) . ")"
                }
            }
        }
        for _, SecData in TomlData["sections"] {
            TotalPersonal += SecData["entries"].Length
        }
    }
    ; Count extra extension TOMLs
    ExtTomlFiles := []
    if IsSet(ScriptInformation) and ScriptInformation.Has("PersonalHotstringsDir") {
        HsDir := ScriptInformation["PersonalHotstringsDir"]
        if DirExist(HsDir) {
            Loop Files HsDir . "*.toml" {
                if (A_LoopFileName != "personal_hotstrings.toml") {
                    ExtTomlFiles.Push(A_LoopFileFullPath)
                    for _, _ESec in _ParseExtTomlSections(A_LoopFileFullPath) {
                        TotalPersonal += _ESec["count"]
                    }
                }
            }
        }
    }
    HotstringsMenu.Add() ; Separator before personal group
    PersonalHeader := MenuSectionTitle(t("menu.hotstrings.personal_header") . (TotalPersonal > 0 ? " (" . FmtCount(TotalPersonal) . ")" : ""))
    HotstringsMenu.Add(PersonalHeader, (*) => NoAction())
    HotstringsMenu.Disable(PersonalHeader)
    if Features.Has("Personal") {
        ; Build the unified personal submenu for personal_hotstrings.toml
        PersonalMenu := Menu()
        PersonalMenu.Add(t("menu.hotstrings.open_editor"), (*) => OpenPersonalEditor())
        ; Shortcut item — not yet customisable from AHK (HS handles it on macOS)
        _ShortcutLabel := t("menu.hotstrings.shortcut_prefix") . ScriptInformation["MagicKey"]
        PersonalMenu.Add(_ShortcutLabel, (*) => NoAction())
        PersonalMenu.Disable(_ShortcutLabel)
        ; Default section — submenu with "Aucune" + one item per TOML section
        CurDefaultSec := _EditorPrefGet("DefaultSection", "")
        DefaultSectionMenu := Menu()
        DefaultSectionMenu.Add(t("menu.hotstrings.default_none"), (*) => _SetPersonalDefaultSection("", PersonalMenu, TomlData,
            DefaultSectionMenu))
        if (CurDefaultSec == "") {
            DefaultSectionMenu.Check(t("menu.hotstrings.default_none"))
        }
        DefaultSectionMenu.Add()
        for _, SecName in TomlData["sections_order"] {
            if (SecName == "-") {
                continue
            }
            SecData := TomlData["sections"][SecName]
            SecLabel := SecData["description"]
            DefaultSectionMenu.Add(SecLabel, _MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData,
                DefaultSectionMenu))
            if (CurDefaultSec == SecName) {
                DefaultSectionMenu.Check(SecLabel)
            }
        }
        CurDefaultLabel := (CurDefaultSec == "") ? t("menu.hotstrings.default_none")
            : (TomlData["sections"].Has(CurDefaultSec) ? TomlData["sections"][CurDefaultSec]["description"] :
                CurDefaultSec)
        global _PrevDefaultLabel := CurDefaultLabel
        _DefaultCatLabel := t("menu.hotstrings.default_category_prefix") . CurDefaultLabel
        PersonalMenu.Add(_DefaultCatLabel, DefaultSectionMenu)
        _CloseOnAddLabel := t("menu.hotstrings.close_on_add")
        PersonalMenu.Add(_CloseOnAddLabel, (*) => _TogglePersonalCloseOnAdd(PersonalMenu))
        if (_EditorPrefGet("CloseOnAdd", "1") == "1") {
            PersonalMenu.Check(_CloseOnAddLabel)
        }
        if (Features["Personal"].Has("__Order") and Features["Personal"]["__Order"].Length > 0) {
            PersonalMenu.Add()
            for FeatName in Features["Personal"]["__Order"] {
                if FeatName == "-" {
                    PersonalMenu.Add()
                } else if Features["Personal"].Has(FeatName) {
                    MenuAddItem(PersonalMenu, "Personal", FeatName)
                }
            }
        }
        PersonalCount := 0
        for _, SecData in TomlData["sections"] {
            PersonalCount += SecData["entries"].Length
        }
        PersonalTitle := GetCategoryTitle("Personal")
            . (PersonalCount > 0 ? " (" . FmtCount(PersonalCount) . ")" : "")
        HotstringsMenu.Add(PersonalTitle, PersonalMenu)
    }
    ; Extension TOML files — one submenu entry per file, alphabetically sorted
    for _, ExtPath in ExtTomlFiles {
        SplitPath ExtPath, &ExtFileName, , , &ExtStem
        ExtSections := _ParseExtTomlSections(ExtPath)
        ExtCount := 0
        for _, _ES in ExtSections {
            ExtCount += _ES["count"]
        }
        ExtMenu := Menu()
        ExtMenu.Add(t("menu.hotstrings.open_file"), _MakeOpenFileFn(ExtPath))
        if (ExtSections.Length > 0) {
            ExtMenu.Add()
            for _, _ES in ExtSections {
                SecLabel := _ES["description"] . " (" . FmtCount(_ES["count"]) . ")"
                ExtMenu.Add(SecLabel, (*) => NoAction())
                ExtMenu.Disable(SecLabel)
            }
        }
        ExtTitle := ExtStem . (ExtCount > 0 ? " (" . FmtCount(ExtCount) . ")" : "")
        HotstringsMenu.Add(ExtTitle, ExtMenu)
    }
    ; Compute grand total = common + personal
    GrandTotal := CommonTotal + TotalPersonal
    HotstringsMenuTitle := t("menu.hotstrings.title") . (GrandTotal > 0 ? " (" . FmtCount(GrandTotal) . ")" : "")
    A_TrayMenu.Add(HotstringsMenuTitle, HotstringsMenu)
    if HotstringsAllEnabled {
        A_TrayMenu.Check(HotstringsMenuTitle)
    }

    ; ── IA / LLM — sits right after Hotstrings, mirroring the Hammerspoon menu order ──
    ; Load persisted LLM settings from the shared config TOML cache.
    _LlmSavedOpts := Map()
    _LlmRawEnabled := IniCacheGet(_IniCache, "LLM", "enabled")
    if _LlmRawEnabled != "_"
        _LlmSavedOpts["enabled"] := (_LlmRawEnabled == "1" || _LlmRawEnabled == "true")
    for _LlmKey in ["model", "profile_id", "temperature"] {
        _LlmRaw := IniCacheGet(_IniCache, "LLM", _LlmKey)
        if _LlmRaw != "_"
            _LlmSavedOpts[_LlmKey] := _LlmRaw
    }
    for _LlmKey in ["n_predictions", "min_words", "max_words", "debounce_ms", "ctx_chars"] {
        _LlmRaw := IniCacheGet(_IniCache, "LLM", _LlmKey)
        if _LlmRaw != "_"
            _LlmSavedOpts[_LlmKey] := Integer(_LlmRaw)
    }
    _LlmRawInstant := IniCacheGet(_IniCache, "LLM", "instant_on_word_end")
    if _LlmRawInstant != "_"
        _LlmSavedOpts["instant_on_word_end"] := (_LlmRawInstant == "1" || _LlmRawInstant == "true")
    LLM_Tray_Init(_LlmSavedOpts)

    ; ── 📊 Métriques — mirrors the HS Métriques submenu position exactly:
    ; sits between Hotstrings + AI and the Shortcuts (Raccourcis) submenu.
    ; The parent entry doubles as a
    ; global ON/OFF toggle for the keylogger feature. OFF by default — it
    ; *is* a keylogger — and only flips ON after the user explicitly
    ; acknowledges the security warning. While OFF, the sub-items remain
    ; visible but greyed out so the menu shape stays familiar.
    BuildMetricsMenu()
    if MetricsShortcuts.enabled {
        A_TrayMenu.Check(t("menu.metrics.title"))
    }

    ; ── Raccourcis and Tap-Holds — standalone, like HS Raccourcis and Karabiner ──
    if SubMenus.Has("Shortcuts") {
        A_TrayMenu.Add(GetCategoryTitle("Shortcuts"), SubMenus["Shortcuts"])
        if ShortcutsAnyEnabled {
            A_TrayMenu.Check(GetCategoryTitle("Shortcuts"))
        }
    }
    ; TapHolds: prepend a global on/off toggle before adding to the tray
    if SubMenus.Has("TapHolds") {
        TapHoldsAllEnabled := IsCategoryAllEnabled(["TapHolds"])
        AddCategoryToggleItem(SubMenus["TapHolds"],
            t("menu.tapholds.on"),
            t("menu.tapholds.off"),
            TapHoldsAllEnabled,
            (*) => ToggleCategoryAllFeatures("TapHolds", !TapHoldsAllEnabled))
        A_TrayMenu.Add(GetCategoryTitle("TapHolds"), SubMenus["TapHolds"])
        ; Check the parent title when all tap-holds are enabled — mirrors HS checked submenu.
        if TapHoldsAllEnabled {
            A_TrayMenu.Check(GetCategoryTitle("TapHolds"))
        }
    }

    ; ── Gestes — custom submenu mirroring Hammerspoon's gesture picker ──
    GesturesMenu := BuildGesturesMenu()
    A_TrayMenu.Add(GetCategoryTitle("Gestures"), GesturesMenu)
    if Features["Gestures"]["Enabled"].Enabled {
        A_TrayMenu.Check(GetCategoryTitle("Gestures"))
    }

    A_TrayMenu.Add() ; Single separator between feature submenus and configuration items

    ; ── Actions globales — bulk-toggle / reset-defaults actions kept as a
    ; single submenu so the top-level tray stays scannable. ──
    GlobalActionsMenu := Menu()
    GlobalActionsMenu.Add(t("menu.global.enable_all"),  ToggleAllFeaturesOn)
    GlobalActionsMenu.Add(t("menu.global.disable_all"), ToggleAllFeaturesOff)
    GlobalActionsMenu.Add(t("menu.global.reset_defaults"), ReloadWithDefaultConfig)
    GlobalActionsMenu.Add()
    ; Language selector — one entry per supported locale, check mark on active one
    LangMenu := Menu()
    I18nBuildLanguageMenu(LangMenu)
    GlobalActionsMenu.Add(t("menu.global.language"), LangMenu)

    ; ── Script management — flattened into the top-level tray menu (used to
    ; live in a "Gestion du script" submenu). The lifecycle actions sit one
    ; click closer to the tray icon and stay grouped via separators. ──
    global MenuSuspend
    MenuSuspend := t("menu.global.suspend")
    A_TrayMenu.Add(t("menu.global.title"), GlobalActionsMenu)
    A_TrayMenu.Add(t("menu.global.config_folder"), FilePathsEditor)
    A_TrayMenu.Add(t("menu.global.setup_wizard"), Onboarding_ShowFromMenu)
    A_TrayMenu.Add() ; Separator before lifecycle actions
    A_TrayMenu.Add(t("menu.global.edit_shortcuts"), OpenPersonalShortcuts)
    A_TrayMenu.Add(MenuSuspend, ToggleSuspend)
    A_TrayMenu.Add(t("menu.global.reload"), ActivateReload)
    A_TrayMenu.Add(t("menu.global.quit"), ActivateExitApp)

    ; ── Debug tools — grouped in a submenu to keep the top-level menu tidy.
    ; Mirrors Hammerspoon's "⚠ Debug" entry (Console + log shortcuts);
    ; Window Spy / List Vars / Key History are AutoHotkey-specific particulars. ──
    DebuggingMenu := Menu()
    DebuggingMenu.Add(t("menu.debug.window_spy"),    WindowSpy)
    DebuggingMenu.Add(t("menu.debug.list_vars"),     ActivateListVars)
    DebuggingMenu.Add(t("menu.debug.key_history"),   ActivateKeyHistory)
    DebuggingMenu.Add(t("menu.debug.open_logs"),     OpenLogsFolder)
    DebuggingMenu.Add(t("menu.debug.open_today_log"), OpenTodayLog)
    A_TrayMenu.Add(t("menu.debug.title"), DebuggingMenu)
}

; Opens personal_shortcuts.ahk in Notepad. Same function the gesture binding
; uses (modules/gestures.ahk:GestureEditPersonalShortcuts), but kept callable
; from the tray menu so the user has both entry points.
OpenPersonalShortcuts(*) {
    Path := ScriptInformation["PersonalAhkPath"]
    EnsurePersonalShortcutsFile(Path)
    Run('notepad.exe "' . Path . '"')
}

; Opens the per-user log directory (under <ConfigDir>/ahk/logs/) in Explorer.
; Creates it on first use so the user never sees an "introuvable" dialog
OpenLogsFolder(*) {
    LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
        ? _ConfigDir . "ahk\logs\"
        : A_ScriptDir . "\logs\"
    if !DirExist(LogDir) {
        try DirCreate(LogDir)
    }
    Run('explorer.exe "' . LogDir . '"')
}

; Opens today's rolling log file in Notepad. LOGGER_LOG_PATH is refreshed by
; LoggerInit() at every menu rebuild, so the path follows day rollover.
OpenTodayLog(*) {
    global LOGGER_LOG_PATH
    Path := (IsSet(LOGGER_LOG_PATH) and LOGGER_LOG_PATH != "")
        ? LOGGER_LOG_PATH
        : ""
    if Path = "" or !FileExist(Path) {
        ; Fall back to the day-stamped path under <ConfigDir>/ahk/logs/ even if the
        ; logger hasn't initialised yet (very early boot, edge case)
        LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
            ? _ConfigDir . "ahk\logs\"
            : A_ScriptDir . "\logs\"
        Path := LogDir . "ErgoptiPlus_" . FormatTime(, "yyyy-MM-dd") . ".log"
    }
    Run('notepad.exe "' . Path . '"')
}

; Minimal template for personal_shortcuts.ahk — created on first launch so the
; user has a starter file with the canonical header. The header below is the
; same one the user is expected to keep at the top of their personal file, so
; both views stay perfectly aligned across ErgoptiPlus updates.
global PERSONAL_SHORTCUTS_TEMPLATE := "; personal_shortcuts.ahk`r`n"
    . ";`r`n"
    . "; ==============================================================================`r`n"
    . "; MODULE: Personal Shortcuts`r`n"
    . "; DESCRIPTION:`r`n"
    . "; User-defined hotkeys layered on top of the ErgoptiPlus driver. Loaded into`r`n"
    . "; the driver via a forwarding stub generated by EnsurePersonalShortcutsFile, so`r`n"
    . "; this file lives at <ConfigDirPath>/personal_shortcuts.ahk and survives`r`n"
    . "; ErgoptiPlus updates without any manual copying.`r`n"
    . ";`r`n"
    . "; FEATURES & RATIONALE:`r`n"
    . "; 1. Toggle-gated bindings — every binding is wrapped in`r`n"
    . ";    #HotIf PersonalFeatureEnabled(`"<Name>`") so the matching`r`n"
    . ";    tray-menu checkbox in « 🎯 Raccourcis » → « Raccourcis personnels » fully controls`r`n"
    . ";    whether the binding fires, with persistence in the configuration INI.`r`n"
    . "; 2. Two-section layout — every feature is registered in section 1 and bound`r`n"
    . ";    (along with any helper functions it needs) in section 2 with matching`r`n"
    . ";    subsection numbering. The at-a-glance roster of available toggles and the`r`n"
    . ";    wiring of each one are each easy to scan in isolation.`r`n"
    . "; 3. AHK input level 2 is already set by the parent driver before this file is`r`n"
    . ";    included, so personal hotkeys override the layout's remappings without`r`n"
    . ";    this file needing its own #InputLevel directives.`r`n"
    . ";`r`n"
    . "; ADDING A FEATURE — drop a RegisterPersonalFeature call into section 1 and`r`n"
    . "; the matching #HotIf-gated binding into section 2. The toggle then appears`r`n"
    . "; in the tray under « 🎯 Raccourcis » → « Raccourcis personnels ». Example:`r`n"
    . ";`r`n"
    . ";     RegisterPersonalFeature(`"LockScreen`", true,`r`n"
    . ";         `"Lock the workstation with Ctrl + Alt + L`")`r`n"
    . ";`r`n"
    . ";     #HotIf PersonalFeatureEnabled(`"LockScreen`")`r`n"
    . ";     ^!l:: DllCall(`"user32\LockWorkStation`")`r`n"
    . ";     #HotIf`r`n"
    . "; ==============================================================================`r`n"
    . "`r`n"
    . "#Requires AutoHotkey v2.0`r`n"
    . "`r`n"
    . "`r`n"
    . "`r`n"
    . "`r`n"
    . "`r`n"
    . "; =======================================`r`n"
    . "; =======================================`r`n"
    . "; ======= 1/ Feature Registration =======`r`n"
    . "; =======================================`r`n"
    . "; =======================================`r`n"
    . "`r`n"
    . "; (Add RegisterPersonalFeature calls here — see the example in the header.)`r`n"
    . "`r`n"
    . "`r`n"
    . "`r`n"
    . "`r`n"
    . "`r`n"
    . "; ==================================`r`n"
    . "; ==================================`r`n"
    . "; ======= 2/ Hotkey Bindings =======`r`n"
    . "; ==================================`r`n"
    . "; ==================================`r`n"
    . "`r`n"
    . "; (Add #HotIf-gated hotkey blocks here — see the example in the header.)`r`n"
    . "`r`n"

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
            FileAppend(PERSONAL_SHORTCUTS_TEMPLATE, Path, "UTF-8-RAW")
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
    ; Hide the stub in a sibling _generated/ folder so it does not clutter
    ; the source tree alongside the actual driver files. The folder is
    ; gitignored; AHK resolves `#Include *i _generated\personal_shortcuts.ahk`
    ; relative to A_ScriptDir at parse time.
    StubDir := A_ScriptDir . "\_generated"
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
EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"])
; #InputLevel 2 is required for the user's personal hotkeys to fire after the
; layout's key remappings (which run at the default level 0). We set it here so
; the user does not have to know about input levels in their personal file.
#InputLevel 2
#Include *i _generated/personal_shortcuts.ahk
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

; Now that all modules are loaded and config is hydrated, persist the
; complete state to ensure the on-disk TOML contains every key — not
; just the ones the user has ever toggled. This makes the file a
; human-readable, complete reference of the current configuration.
SaveFullConfig()

InitSubMenus()
initMenu()
UpdateTrayIcon()

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
    DirEdit := W.Add("Edit", "xm w480", _ConfigDir)
    W.Add("Button", "x+6 w80", t("common.browse")).OnEvent("Click", BrowseDir)

    W.Add("Text", "xm y+14 cGray", t("dialog.config_folder.hint"))

    W.Add("Button", "xm y+10 w80", t("button.ok")).OnEvent("Click", SaveConfigDir)
    W.Add("Button", "x+6 w80", t("common.cancel")).OnEvent("Click", (*) => W.Destroy())

    BrowseDir(*) {
        ; Start from the current field value if it exists, otherwise fall back to
        ; My Documents so the dialog opens somewhere useful rather than the script root.
        StartDir := Trim(DirEdit.Value)
        if (StartDir == "" or !DirExist(StartDir)) {
            StartDir := A_MyDocuments
        }
        Selected := DirSelect("*" . StartDir, 1, t("dialog.config_folder.select_title"))
        if (Selected != "") {
            if !RegExMatch(Selected, "\\$")
                Selected .= "\"
            DirEdit.Value := Selected
        }
    }

    SaveConfigDir(*) {
        global _ConfigDir, _DefaultConfigDir, _PathsFile, ScriptInformation, ConfigurationFile

        NewDir := Trim(DirEdit.Value)
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

#SuspendExempt

; Gate on a real AltGr/Kana press so a ghost SC138 (injected by an OS driver
; for AltGr-mapped keys like Bépo's `'`) does not trigger these script
; shortcuts on the next Enter/BackSpace/Delete/Escape press.
#HotIf IsRealAltGrPress()

RAlt & Enter::
SC138 & SC01C::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC01C", "P")) {
        RunScriptShortcutAction("script_altgr_enter")
    } else {
        SendInput("{Enter}")
    }
}

RAlt & BackSpace::
SC138 & SC00E::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC00E", "P")) {
        RunScriptShortcutAction("script_altgr_backspace")
    } else {
        SendInput("{BackSpace}")
    }
}

RAlt & Delete::
SC138 & SC153::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC153", "P")) {
        RunScriptShortcutAction("script_altgr_delete")
    } else {
        SendInput("{Delete}")
    }
}

RAlt & Escape::
SC138 & SC001::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC001", "P")) {
        RunScriptShortcutAction("script_altgr_escape")
    } else {
        SendInput("{Escape}")
    }
}

#HotIf

#SuspendExempt False

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
