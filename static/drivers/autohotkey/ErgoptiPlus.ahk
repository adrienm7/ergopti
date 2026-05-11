; Last modified on 2026-04-23 at 00:00 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

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
        MsgBox("ErgoptiPlus — erreur interne capturée :`n`n" . Exc.Message . "`n`n" . (Exc.HasProp("Stack") ? Exc.Stack :
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

; Auto-create the AHK driver subfolder under _ConfigDir on first launch.
; Driver-specific files (personal_shortcuts.ahk, config.toml, …) live
; here so a Mac+PC setup can keep ahk/ and hammerspoon/ side by side
; without any name collision.
DirCreate(_ConfigDir . "ahk")

global ScriptInformation := Map(
    "MagicKey", "★",
    ; Configurable file paths — all derived from _ConfigDir set above.
    ; AHK-specific files (.ahk, AHK config.toml) go under ``ahk/`` so the
    ; folder can be safely shared with the Hammerspoon driver via cloud
    ; sync. Shared neutral files (hotstrings TOML, personal info) stay
    ; at the root of _ConfigDir.
    "PersonalAhkPath", _ConfigDir . "ahk\personal_shortcuts.ahk",
    "PersonalTomlPath", _ConfigDir . "personal_hotstrings.toml",
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
    "script_altgr_enter", "AltGr + Entrée",
    "script_altgr_backspace", "AltGr + ⌫",
    "script_altgr_delete", "AltGr + ⌦",
    "script_altgr_escape", "AltGr + Échap",
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

; ParseTomlFile / IniCacheGet / ResolveConfigPath are defined in lib/ini_helpers.ahk
; (included above) so the test runner can exercise them in isolation.

ReadScriptConfig(Cache) {
    for Information in ScriptInformation {
        Value := IniCacheGet(Cache, "Script", Information)
        if Value != "_" {
            ScriptInformation[Information] := Value
        }
    }
}

global _IniCache := ParseTomlFile(ConfigurationFile)
ReadScriptConfig(_IniCache)

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
    Props := ["Enabled", "TimeActivationSeconds", "Letter", "PatternMaxLength", "Link", "DestinationFolder",
        "DatedNotes", "SearchEngine", "SearchEngineURLQuery"]

    for Category, FeaturesMap in Features {
        for Feature, Value in FeaturesMap {
            if (Type(Value) = "Map") {
                ; Sub-map => iterate sub-features under [Category.Feature]
                for SubFeature, SubValue in Value {
                    for Prop in Props {
                        Name := SubFeature . "." . Prop
                        RawValue := IniCacheGet(Cache, Category "." Feature, Name)
                        if RawValue != "_" {
                            Features[Category][Feature][SubFeature].%Prop% := RawValue
                        }
                    }
                }
            } else {
                for Prop in Props {
                    ; Avoid "Foo.Foo" when the feature key and the property share the same name
                    Name := (Feature = Prop) ? Prop : Feature . "." . Prop
                    RawValue := IniCacheGet(Cache, Category, Name)
                    if RawValue != "_" {
                        Features[Category][Feature].%Prop% := RawValue
                    }
                }
            }
        }
    }

    for Information in ScriptInformation {
        Value := IniCacheGet(Cache, "Script", Information)
        if Value != "_" {
            ScriptInformation[Information] := Value
        }
    }
}

ReadConfiguration(_IniCache)
; Materialise personal_info.toml from defaults if missing, so renaming or
; deleting the file simply triggers a fresh re-creation on the next launch
; (same guarantee EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk).
EnsurePersonalInfoTomlFile(ScriptInformation["PersonalInfoTomlPath"])
ReadPersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])

; Pull menu titles and submenu ordering from the per-category TOML files so
; that those hotstring files are the single source of truth for both the
; hotstring payload and the feature descriptions shown in the tray menu.
; Categories without a TOML (``Layout``, ``Shortcuts``, ``TapHolds``) keep
; their hardcoded Descriptions and ``__Order`` arrays in the Features Map.
ApplyTomlMetadataToFeatures("Autocorrection")
ApplyTomlMetadataToFeatures("DistancesReduction")
ApplyTomlMetadataToFeatures("MagicKey")
ApplyTomlMetadataToFeatures("Rolls")
ApplyTomlMetadataToFeatures("SFBsReduction")

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
        case "DateFr", "Date":
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
                _DynVal.Description := "dt" . MK . " insère la date courante (" . FormatTime(, "dd/MM/yyyy") . ")" .
                CountSuffix
            case "Date":
                _DynVal.Description := "td" . MK . " insère la date courante (" . FormatTime(, "yyyy_MM_dd") . ")" .
                CountSuffix
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
                GroupLabel := Trim(SubStr(Feature, 2))
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
            MenuParent.Add("   ↳ Modifier les informations…", PersonalInformationEditor)
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

    ; "Désactivé" entry — disables the remap without touching Letter
    DisabledLabel := "Désactivé"
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
    TOML_Write(true, ConfigurationFile, FeatureCategoryPath, FeatureName . ".Enabled")
    TOML_Write(Letter, ConfigurationFile, FeatureCategoryPath, FeatureName . ".Letter")
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
    TOML_Write(false, ConfigurationFile, FeatureCategoryPath, FeatureName . ".Enabled")
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
            return "Raccourcis personnels"
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
            TOML_Write(Shortcut.Enabled, ConfigurationFile, FeatureCategoryPath, ShortcutName . ".Enabled")
        }
    }
    Feature.Enabled := !CurrentFeatureActivation
    TOML_Write(Feature.Enabled, ConfigurationFile, FeatureCategoryPath, FeatureName . ".Enabled")
    Reload
}

GetCategoryTitle(Category) {
    switch Category {
        case "DistancesReduction":
            return "Réduction des distances"
        case "SFBsReduction":
            return "Réduction des SFBs"
        case "Rolls":
            return "Roulements"
        case "Autocorrection":
            return "Autocorrection"
        case "MagicKey":
            return "Touche " . ScriptInformation["MagicKey"] . " et expansion de texte"
        case "DynamicHotstrings":
            return "Hotstrings dynamiques"
        case "Personal":
            return "Hotstrings personnels"
        case "Shortcuts":
            return "🎯 Raccourcis"
        case "TapHolds":
            return "⌨️ Tap-Holds"
        case "Gestures":
            return "🖐️ Gestes"
        default:
            return ""
    }
}

; ===================================
; Gestures menu builder
; ===================================

BuildGesturesMenu() {
    global Features, GestureAssignments, GESTURE_SLOTS, GESTURE_ACTIONS
    global GESTURE_ACTION_NAMES, GESTURE_SLOT_LABELS

    GMenu := Menu()

    ; Canonical category toggle. AddCategoryToggleItem inserts at position
    ; 1 (and a separator at 2), so the rest of the submenu is appended
    ; AFTER and ends up at positions 3+.
    GestEnabled := Features["Gestures"]["Enabled"].Enabled
    AddCategoryToggleItem(GMenu,
        "✅ Gestes activés (cliquer pour désactiver)",
        "❌ Gestes désactivés (cliquer pour activer)",
        GestEnabled,
        (*) => ToggleGesturesEnabled())

    ; Setup items
    GMenu.Add("🔧 Configurer automatiquement (registre)", (*) => GestureAutoConfigureAction())
    GMenu.Add("📋 Instructions de configuration", (*) => GestureShowSetupInstructions())
    GMenu.Add("⚙ Ouvrir Pavé tactile (puis « Mouvements avancés »)", (*) => GestureOpenTouchpadSettings())

    GMenu.Add() ; Separator

    ; Per-slot submenus — each slot shows all available actions as radio
    ; items. Group separators are driven by the "--" sentinels embedded in
    ; GESTURE_ACTION_NAMES (see modules/gestures.ahk), so this loop only
    ; needs to translate sentinel → menu separator and skip duplicates.

    for Slot in GESTURE_SLOTS {
        ; Separator between 3-finger and 4-finger groups
        if (Slot == "tap_4") {
            GMenu.Add()
        }
        SlotLabel := GESTURE_SLOT_LABELS[Slot]
        CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
        CurrentActionLabel := GESTURE_ACTIONS.Has(CurrentAction) ? GESTURE_ACTIONS[CurrentAction].Label : "Désactivé"

        SlotMenu := Menu()
        last_was_separator := true   ; suppress leading separators
        for ActionName in GESTURE_ACTION_NAMES {
            ; "--" sentinels mark category boundaries — render as a
            ; menu separator (collapsing consecutive ones).
            if (ActionName == "--") {
                if !last_was_separator {
                    SlotMenu.Add()
                    last_was_separator := true
                }
                continue
            }
            if !GESTURE_ACTIONS.Has(ActionName)
                continue
            ActionLabel := GESTURE_ACTIONS[ActionName].Label
            SlotMenu.Add(ActionLabel, MakeGestureSlotHandler(Slot, ActionName))
            if (ActionName == CurrentAction) {
                SlotMenu.Check(ActionLabel)
            }
            if !Features["Gestures"]["Enabled"].Enabled {
                SlotMenu.Disable(ActionLabel)
            }
            last_was_separator := false
        }
        EntryLabel := SlotLabel . " : " . CurrentActionLabel
        GMenu.Add(EntryLabel, SlotMenu)
        if !Features["Gestures"]["Enabled"].Enabled {
            GMenu.Disable(EntryLabel)
        }
    }

    return GMenu
}

; Creates a closure for a gesture slot action handler.
MakeGestureSlotHandler(Slot, ActionName) {
    return (*) => SetGestureSlotAction(Slot, ActionName)
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
BuildMetricsMenu() {
    global A_TrayMenu
    MetricsMenu := Menu()

    enabled := MetricsShortcuts.enabled
    typing_label := "Afficher les métriques de frappe"
    apps_label := "Afficher le temps sur les applications"
    ; A trailing zero-width space differentiates the second « ↳ Raccourci :
    ; Aucun » entry from the first — AHK's tray menu uses the label as a
    ; unique key and would silently merge two identical strings into one.
    typing_sc := "↳ Raccourci : " . MS_GetDisplayLabel("typing")
    apps_sc := "↳ Raccourci : " . MS_GetDisplayLabel("apps") . Chr(0x200B)

    MetricsMenu.Add(typing_label, (*) => KLUI_ToggleTyping())
    MetricsMenu.Add(typing_sc, (*) => MS_PromptShortcut("typing", KLUI_ToggleTyping))
    MetricsMenu.Add() ; separator
    MetricsMenu.Add(apps_label, (*) => KLUI_ToggleApps())
    MetricsMenu.Add(apps_sc, (*) => MS_PromptShortcut("apps", KLUI_ToggleApps))

    ; ── Privacy filters — same section as HS menu_metrics.lua « FILTRES
    ; DE CONFIDENTIALITÉ ». Each toggle persists immediately to
    ; metrics_shortcuts.ini and takes effect on the next keystroke
    ; flushed from the buffer (no Reload required because filters live
    ; in RAM and the next MF_ShouldFilter call picks the new value).
    MetricsMenu.Add()
    privacy_header := "— FILTRES DE CONFIDENTIALITÉ —"
    MetricsMenu.Add(privacy_header, (*) => "")
    MetricsMenu.Disable(privacy_header)

    private_label := "Ignorer la navigation privée"
    MetricsMenu.Add(private_label, ToggleFilterPrivate)
    if MetricsFilters.private_browsing
        MetricsMenu.Check(private_label)

    secure_label := "Ignorer les champs mot de passe"
    MetricsMenu.Add(secure_label, ToggleFilterSecureField)
    if MetricsFilters.secure_field
        MetricsMenu.Check(secure_label)

    sysauth_label := "Ignorer les boîtes de dialogue d’authentification système"
    MetricsMenu.Add(sysauth_label, ToggleFilterSystemAuth)
    if MetricsFilters.system_auth
        MetricsMenu.Check(sysauth_label)

    ; App exclusion entry — label reflects the count, click opens the
    ; reusable AppPicker Gui. Mirror of HS « Désactivé dans N application(s) ».
    n := MF_DisabledCount()
    excl_label := (n > 0)
        ? "Désactivé dans " . n . " application" . (n > 1 ? "s" : "")
        : "Exclure des applications du keylogger…"
    MetricsMenu.Add(excl_label, OpenMetricsAppPicker)

    if !enabled {
        MetricsMenu.Disable(typing_label)
        MetricsMenu.Disable(typing_sc)
        MetricsMenu.Disable(apps_label)
        MetricsMenu.Disable(apps_sc)
        MetricsMenu.Disable(private_label)
        MetricsMenu.Disable(secure_label)
        MetricsMenu.Disable(sysauth_label)
        MetricsMenu.Disable(excl_label)
    }

    A_TrayMenu.Add("📊 Métriques", MetricsMenu)
    ; Aligned with the canonical ✅/❌ pattern used by every other
    ; category submenu. The security-warning dialog still fires inside
    ; ToggleMetricsEnabled() before flipping ON, so the privacy
    ; safeguard stays in place — the icon change is purely cosmetic.
    AddCategoryToggleItem(MetricsMenu,
        "✅ Métriques activées (cliquer pour désactiver)",
        "❌ Métriques désactivées (cliquer pour activer)",
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

OpenMetricsAppPicker(*) {
    AppPicker_Show(Map(
        "title", "Exclure des applications — Métriques",
        "prompt", "Sélectionnez les applications dont les frappes ne "
        . "seront jamais enregistrées par le keylogger.",
        "ok_label", "Enregistrer",
        "initial", MF_DisabledList(),
        "on_save", OnMetricsAppPickerSave
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
            "Désactiver les métriques ?`n`n"
            . "Le keylogger ne capturera plus aucune frappe. Les données déjà "
            . "enregistrées sont conservées.",
            "📊 Métriques",
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
    warn := "ATTENTION : Vous êtes sur le point d’activer le keylogger.`n`n"
        . "Il enregistre vos frappes au clavier à la milliseconde près. "
        . "Ces logs sont stockés en local sous :`n"
        . "    " . metrics_path . "`n`n"
        . "Bien que les champs de mots de passe soient ignorés automatiquement "
        . "(filtre UIA), il est recommandé de mettre le script en PAUSE lors "
        . "de la saisie de données sensibles.`n`n"
        . "Activer ?"
    ; Icon! = exclamation triangle (warning). Iconx is the red error stop
    ; sign and was the wrong choice for a "you are about to enable a
    ; logging feature" notice.
    res := MsgBox(warn, "⚠ Avertissement de sécurité — Métriques", "OKCancel Icon!")
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
            "Configuration des gestes appliquée avec succès.`n`n"
            . "Les 10 gestes ont été configurés dans le registre Windows`n"
            . "(Ctrl+Win+Shift+F1 à F10).`n`n"
            . "Une déconnexion / reconnexion peut être nécessaire pour que`n"
            . "Windows prenne les nouveaux raccourcis en compte.",
            "ErgoptiPlus — Configuration des gestes",
            "Iconi"
        )
    } else {
        MsgBox(
            "Erreur lors de l'écriture du registre.`n`n"
            . "Essayez d’exécuter le script en tant qu'administrateur,`n"
            . "ou configurez manuellement (voir Instructions).",
            "ErgoptiPlus — Erreur",
            "Icon!"
        )
    }
}

; =========================
; Main menu initialization
; =========================

global MenuHotstrings := "⚡ Hotstrings"
global MenuConfigurationShortcuts := "Raccourcis de gestion du script"
; Holds the « Suspendre » label so UpdateTrayIcon can check/uncheck the
; entry by its exact text on A_TrayMenu. Re-assigned in initMenu so future
; label tweaks (icons, hints) only need to change the menu builder.
global MenuSuspend := "⏸︎ Suspendre"
global MenuDebugging := "⚠ Débogage"

; Categories that live inside the Hotstrings submenu (ordered to match HS menu)
global HotstringCategories := ["DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey", "Personal"]

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
            "✅ Raccourcis activés (cliquer pour désactiver)",
            "❌ Raccourcis désactivés (cliquer pour activer)",
            ShortcutsAnyEnabled,
            (*) => ToggleCategoryAllFeatures("Shortcuts", !ShortcutsAnyEnabled))
    }

    ; Append the « Raccourcis de gestion du script » sub-submenu at the bottom
    ; of the « Raccourcis » category so the per-slot action assignments live
    ; alongside the other shortcut configuration rather than at the tray root.
    if SubMenus.Has("Shortcuts") {
        SubMenus["Shortcuts"].Add()
        SubMenus["Shortcuts"].Add(MenuConfigurationShortcuts, BuildScriptShortcutsMenu())
    }

    ; ── 🌐 Disposition clavier — mirrors the HS layout submenu naming ──
    LayoutMenu := Menu()
    LayoutAnyEnabled := HasAnyEnabled(Features["Layout"])
    AddCategoryToggleItem(LayoutMenu,
        "✅ Disposition activée (cliquer pour désactiver)",
        "❌ Disposition désactivée (cliquer pour activer)",
        LayoutAnyEnabled,
        (*) => ToggleCategoryAllFeatures("Layout", !LayoutAnyEnabled))
    for FeatureName in Features["Layout"]["__Order"] {
        MenuAddItem(LayoutMenu, "Layout", FeatureName)
    }
    A_TrayMenu.Add("🌐 Disposition clavier", LayoutMenu)
    if LayoutAnyEnabled {
        A_TrayMenu.Check("🌐 Disposition clavier")
    }

    ; ── Hotstrings ⚡ — single submenu grouping all hotstring categories ──
    HotstringsMenu := Menu()
    HotstringsAllEnabled := IsCategoryAllEnabled(HotstringCategories)
    AddCategoryToggleItem(HotstringsMenu,
        "✅ Hotstrings activés (cliquer pour désactiver)",
        "❌ Hotstrings désactivés (cliquer pour activer)",
        HotstringsAllEnabled,
        HotstringsAllEnabled ? ToggleAllHotstringsOff : ToggleAllHotstringsOn)
    for Category in HotstringCategories {
        if SubMenus.Has(Category) {
            Total := CountTomlHotstrings(Category)
            Title := GetCategoryTitle(Category) . (Total > 0 ? " (" . FmtCount(Total) . ")" : "")
            HotstringsMenu.Add(Title, SubMenus[Category])
        }
    }
    ; Dynamic hotstrings — date insertion and future rule-based expansions.
    ; Mirrors HS build_custom's dynamichotstrings group: one item per section
    ; (currently only "date") with an enable/disable checkbox.
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

    ; Personal hotstrings — unified submenu that mirrors HS build_custom layout:
    ; editor button + shortcut hint up top, then per-section toggle checkboxes
    ; with hotstring counts, replacing the old separate editor-only submenu.
    if Features.Has("Personal") {
        ; Read personal_hotstrings.toml once to get section order, descriptions, and counts
        TomlData := ReadPersonalToml()
        ; Enrich Features["Personal"] descriptions with entry counts so that
        ; MenuAddItem / GetMenuTitleByPath display them alongside the checkbox
        for _, SecName in TomlData["sections_order"] {
            SecData := TomlData["sections"][SecName]
            Count := SecData["entries"].Length
            BaseDesc := SecData["description"]
            ; Match lowercase TOML key to the PascalCase Features key
            for FeatKey in Features["Personal"] {
                if (FeatKey != "__Order" and StrLower(FeatKey) == SecName) {
                    Features["Personal"][FeatKey].Description := BaseDesc . " (" . FmtCount(Count) . ")"
                }
            }
        }
        ; Build the unified personal submenu
        PersonalMenu := Menu()
        PersonalMenu.Add("Ouvrir l'éditeur de hotstrings", (*) => OpenPersonalEditor())
        ; Shortcut item — not yet customisable from AHK (HS handles it on macOS)
        PersonalMenu.Add("Raccourci : Win + " . ScriptInformation["MagicKey"], (*) => NoAction())
        PersonalMenu.Disable("Raccourci : Win + " . ScriptInformation["MagicKey"])
        ; Default section — submenu with "Aucune" + one item per TOML section
        CurDefaultSec := _EditorPrefGet("DefaultSection", "")
        DefaultSectionMenu := Menu()
        DefaultSectionMenu.Add("Aucune", (*) => _SetPersonalDefaultSection("", PersonalMenu, TomlData,
            DefaultSectionMenu))
        if (CurDefaultSec == "") {
            DefaultSectionMenu.Check("Aucune")
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
        ; Title reflects the currently selected section
        CurDefaultLabel := (CurDefaultSec == "") ? "Aucune"
            : (TomlData["sections"].Has(CurDefaultSec) ? TomlData["sections"][CurDefaultSec]["description"] :
                CurDefaultSec)
        global _PrevDefaultLabel := CurDefaultLabel
        PersonalMenu.Add("Catégorie par défaut : " . CurDefaultLabel, DefaultSectionMenu)
        ; Close-on-add toggle — mirrors HS "Fermer l'UI après ajout"
        PersonalMenu.Add("Fermer l'UI après ajout d’un hotstring par le raccourci",
            (*) => _TogglePersonalCloseOnAdd(PersonalMenu))
        if (_EditorPrefGet("CloseOnAdd", "1") == "1") {
            PersonalMenu.Check("Fermer l'UI après ajout d’un hotstring par le raccourci")
        }
        if (Features["Personal"].Has("__Order") and Features["Personal"]["__Order"].Length > 0) {
            PersonalMenu.Add() ; Separating line
            for FeatName in Features["Personal"]["__Order"] {
                if FeatName == "-" {
                    PersonalMenu.Add()
                } else if Features["Personal"].Has(FeatName) {
                    MenuAddItem(PersonalMenu, "Personal", FeatName)
                }
            }
        }
        ; Compute total count for the top-level category title
        TotalPersonal := 0
        for _, SecData in TomlData["sections"] {
            TotalPersonal += SecData["entries"].Length
        }
        PersonalTitle := GetCategoryTitle("Personal")
        . (TotalPersonal > 0 ? " (" . FmtCount(TotalPersonal) . ")" : "")
        HotstringsMenu.Add(PersonalTitle, PersonalMenu)
    }
    HotstringsMenu.Add() ; Separating line
    ; Hotstrings configuration window — per-group delay and tooltip color.
    ; Edits the same shared override file consumed by Hammerspoon, so any
    ; change here applies to both drivers at next reload.
    HotstringsMenu.Add("Délais et couleurs des hotstrings…",
        (*) => OpenHotstringsConfigWindow())
    HotstringsMenu.Add() ; Separating line
    ; Magic key editor — mirrors HS menu_hotstrings build_management placement
    HotstringsMenu.Add("Touche magique : " . ScriptInformation["MagicKey"], MagicKeyEditor)
    HotstringsMenu.Add("Modifier le lien ouvert par Win + G", GPTLinkEditor)
    A_TrayMenu.Add(MenuHotstrings, HotstringsMenu)
    ; Check the parent title when all hotstrings are enabled — mirrors HS checked submenu.
    if HotstringsAllEnabled {
        A_TrayMenu.Check(MenuHotstrings)
    }

    ; ── 📊 Métriques — mirrors the HS Métriques submenu position exactly:
    ; sits between Hotstrings (+ the AI item, absent on the AHK side) and
    ; the Shortcuts (Raccourcis) submenu. The parent entry doubles as a
    ; global ON/OFF toggle for the keylogger feature. OFF by default — it
    ; *is* a keylogger — and only flips ON after the user explicitly
    ; acknowledges the security warning. While OFF, the sub-items remain
    ; visible but greyed out so the menu shape stays familiar.
    BuildMetricsMenu()
    if MetricsShortcuts.enabled {
        A_TrayMenu.Check("📊 Métriques")
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
            "✅ Tap-holds activés (cliquer pour désactiver)",
            "❌ Tap-holds désactivés (cliquer pour activer)",
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
    GlobalActionsMenu.Add("☑ Activer toutes les fonctionnalités", ToggleAllFeaturesOn)
    GlobalActionsMenu.Add("☐ Désactiver toutes les fonctionnalités", ToggleAllFeaturesOff)
    GlobalActionsMenu.Add("↺ Valeurs par défaut", ReloadWithDefaultConfig)

    ; ── Script management — flattened into the top-level tray menu (used to
    ; live in a "Gestion du script" submenu). The lifecycle actions sit one
    ; click closer to the tray icon and stay grouped via separators. ──
    global MenuSuspend
    MenuSuspend := "⏸︎ Suspendre"
    A_TrayMenu.Add("Actions globales", GlobalActionsMenu)
    A_TrayMenu.Add("📂 Dossier de configuration…", FilePathsEditor)
    A_TrayMenu.Add() ; Separator before lifecycle actions
    A_TrayMenu.Add("✎ Éditer personal_shortcuts.ahk", OpenPersonalShortcuts)
    A_TrayMenu.Add(MenuSuspend, ToggleSuspend)
    A_TrayMenu.Add("🔄 Recharger", ActivateReload)
    A_TrayMenu.Add("⏹ Quitter", ActivateExitApp)

    ; ── Débogage — tools grouped in a submenu to keep the top-level menu tidy.
    ; Mirrors Hammerspoon's "⚠ Débogage" entry (Console + log shortcuts);
    ; Window Spy / List Vars / Key History are AutoHotkey-specific particulars. ──
    DebuggingMenu := Menu()
    DebuggingMenu.Add("Window Spy", WindowSpy)
    DebuggingMenu.Add("État des variables", ActivateListVars)
    DebuggingMenu.Add("Historique des touches", ActivateKeyHistory)
    DebuggingMenu.Add("Ouvrir le dossier de logs", OpenLogsFolder)
    DebuggingMenu.Add("Ouvrir le fichier de log du jour", OpenTodayLog)
    A_TrayMenu.Add(MenuDebugging, DebuggingMenu)
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
    . ";    #HotIf Features[`"Shortcuts`"][`"Personal`"][`"<Name>`"].Enabled so the matching`r`n"
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
    . ";     #HotIf Features[`"Shortcuts`"][`"Personal`"][`"LockScreen`"].Enabled`r`n"
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

; Load every UI shortcut + privacy filter from the [shortcuts] section
; of ahk/config.toml. CS_Load() populates both MetricsShortcuts
; and MetricsFilters in one pass.
CS_Load()

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
    DefaultSectionMenu.Uncheck("Aucune")
    for _, SN in TomlData["sections_order"] {
        if (SN == "-") {
            continue
        }
        SD := TomlData["sections"][SN]
        try DefaultSectionMenu.Uncheck(SD["description"])
    }
    if (SecName == "") {
        DefaultSectionMenu.Check("Aucune")
    } else if (TomlData["sections"].Has(SecName)) {
        DefaultSectionMenu.Check(TomlData["sections"][SecName]["description"])
    }
    ; Rename the parent item to reflect the new selection
    NewLabel := (SecName == "") ? "Aucune"
        : (TomlData["sections"].Has(SecName) ? TomlData["sections"][SecName]["description"] : SecName)
    try PersonalMenu.Rename("Catégorie par défaut : " . _PrevDefaultLabel, "Catégorie par défaut : " . NewLabel)
    _PrevDefaultLabel := NewLabel
}

; Freezes all closure values for use inside a loop.
_MakeSetDefaultSectionFn(SecName, PersonalMenu, TomlData, DefaultSectionMenu) {
    return (*) => _SetPersonalDefaultSection(SecName, PersonalMenu, TomlData, DefaultSectionMenu)
}

; Toggles the close-on-add pref and the corresponding checkmark.
_TogglePersonalCloseOnAdd(PersonalMenu) {
    Label := "Fermer l'UI après ajout d’un hotstring par le raccourci"
    NewVal := (_EditorPrefGet("CloseOnAdd", "1") == "1") ? "0" : "1"
    _EditorPrefSet("CloseOnAdd", NewVal)
    if (NewVal == "1") {
        PersonalMenu.Check(Label)
    } else {
        PersonalMenu.Uncheck(Label)
    }
}

MagicKeyEditor(*) {
    GuiToShow := Gui(, "Modifier la touche magique")
    GuiToShow.Add("Text", , "Nouvelle valeur (★ par défaut) :")
    NewValue := GuiToShow.Add("Edit", "w50 x+10", ScriptInformation["MagicKey"])

    GuiToShow.Add("Button", "w100 x+10", "OK").OnEvent("Click", (*) => ModifyMagicKey(GuiToShow, NewValue.Text))
    GuiToShow.Show("Center")
}
ModifyMagicKey(gui, NewValue) {
    global ScriptInformation, ConfigurationFile
    ScriptInformation["MagicKey"] := NewValue
    TOML_Write(NewValue, ConfigurationFile, "Script", "MagicKey")

    gui.Destroy()
    Reload
}

PersonalInformationEditor(*) {
    GuiToShow := Gui(, "Modifier les coordonnées personnelles")
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
    GuiToShow.Add("Button", "w100 Center", "OK").OnEvent("Click", (*) => ProcessUserInput(GuiToShow,
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

    MsgBox("Nouvelles coordonnées :`n`n" PersonalInformationSummary)
    Reload
}

GPTLinkEditor(*) {
    GuiToShow := Gui(, "Modifier le lien ouvert par Win + G")
    NewValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["GPT"].Link)

    GuiToShow.Add("Button", "w100 Center", "OK").OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
    GuiToShow.Show("Center")
}
ModifyLink(gui, NewValue) {
    Features["Shortcuts"]["GPT"].Link := NewValue
    TOML_Write(NewValue, ConfigurationFile, "Shortcuts", "GPT" . "." . "Link")

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

ToggleAllFeaturesOn(*) {
    MsgBox(
        "⚠ ATTENTION : Toutes les fonctionnalités ont été activées, même quelques unes désactivées par défaut."
    )
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

    ; Recursive setter used when Value == 0
    SetAllRecursive(Path, Items) {
        for Key, Val in Items {
            if Key == "__Order" {
                continue
            }
            NewPath := (Path = "") ? Key : Path "." Key
            if Type(Val) == "Map" {
                if Val.HasOwnProp("Enabled") {
                    ; The Enabled flag of the map itself is written in the parent section
                    parentSection := Path = "" ? Key : Path
                    Val.Enabled := Value
                    Updates.Push({ Section: parentSection, Key: Key . ".Enabled", Value: Value })
                }
                ; Recurse into nested entries to set their Enabled to Value
                SetAllRecursive(NewPath, Val)
            } else if IsObject(Val) and Val.HasOwnProp("Enabled") {
                ; For leaf features, write under the section corresponding to the parent path
                pos := InStr(NewPath, ".", , -1)
                if pos {
                    section := SubStr(NewPath, 1, pos - 1)
                    keyName := SubStr(NewPath, pos + 1)
                } else {
                    section := NewPath
                    keyName := ""
                }
                Val.Enabled := Value
                if keyName = "" {
                    Updates.Push({ Section: section, Key: Key . ".Enabled", Value: Value })
                } else {
                    Updates.Push({ Section: section, Key: keyName . ".Enabled", Value: Value })
                }
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
                    Updates.Push({ Section: Category, Key: FeatureName . ".Enabled", Value: Value })
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
    for Category in HotstringCategories {
        if !Features.Has(Category) {
            continue
        }
        for FeatureName, Val in Features[Category] {
            if FeatureName == "__Order" {
                continue
            }
            if IsObject(Val) and Val.HasOwnProp("Enabled") {
                Val.Enabled := Value
                Updates.Push({ Section: Category, Key: FeatureName . ".Enabled", Value: Value })
            }
        }
    }
    ; Also toggle DynamicHotstrings and Personal categories
    if Features.Has("DynamicHotstrings") {
        for FeatureName, Val in Features["DynamicHotstrings"] {
            if FeatureName == "__Order" {
                continue
            }
            if IsObject(Val) and Val.HasOwnProp("Enabled") {
                Val.Enabled := Value
                Updates.Push({ Section: "DynamicHotstrings", Key: FeatureName . ".Enabled", Value: Value })
            }
        }
    }
    if Features.Has("Personal") {
        for FeatureName, Val in Features["Personal"] {
            if FeatureName == "__Order" {
                continue
            }
            if IsObject(Val) and Val.HasOwnProp("Enabled") {
                Val.Enabled := Value
                Updates.Push({ Section: "Personal", Key: FeatureName . ".Enabled", Value: Value })
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
            Updates.Push({ Section: Category, Key: FeatureName . ".Enabled", Value: Value })
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

    ; [Script] section — all entries from ScriptInformation
    for Key, Value in ScriptInformation {
        Updates.Push({ Section: "Script", Key: Key, Value: Value })
    }

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
    Updates.Push({ Section: "Metrics", Key: "metrics_filter_private_browsing", Value: MetricsFilters.private_browsing })
    Updates.Push({ Section: "Metrics", Key: "metrics_filter_secure_field", Value: MetricsFilters.secure_field })
    Updates.Push({ Section: "Metrics", Key: "metrics_filter_system_auth", Value: MetricsFilters.system_auth })
    Updates.Push({ Section: "Metrics", Key: "metrics_disabled_apps", Value: apps })

    ; Strict schema: rewrite from scratch so stale/unknown sections and keys
    ; are removed on each full save
    if FileExist(ConfigurationFile) {
        try FileDelete(ConfigurationFile)
    }

    PrevCanonState := _TOML_STRICT_CANON_IN_PROGRESS
    _TOML_STRICT_CANON_IN_PROGRESS := true
    try TOML_BatchWrite(ConfigurationFile, Updates)
    finally _TOML_STRICT_CANON_IN_PROGRESS := PrevCanonState
}

; Recursively walk the Features map to collect all persistable properties
; into the Updates array. The key format mirrors ReadConfiguration so the
; round-trip is lossless.
_CollectFeatureUpdates(Updates, ParentPath, Node) {
    Props := ["Enabled", "TimeActivationSeconds", "Letter", "PatternMaxLength",
        "Link", "DestinationFolder", "DatedNotes", "SearchEngine", "SearchEngineURLQuery"]

    for Key, Value in Node {
        if Key == "__Order" or Key == "__Configuration" {
            continue
        }
        CurrentPath := (ParentPath == "") ? Key : ParentPath "." Key

        if Type(Value) == "Map" {
            ; Nested sub-map: persist __Configuration if present, then recurse
            if Value.Has("__Configuration") {
                Cfg := Value["__Configuration"]
                for Prop in Props {
                    if Cfg.HasOwnProp(Prop) {
                        ConfigKey := (Key == Prop) ? Prop : Key "." Prop
                        Updates.Push({ Section: ParentPath == "" ? Key : ParentPath,
                            Key: ConfigKey, Value: Cfg.%Prop% })
                    }
                }
            }
            _CollectFeatureUpdates(Updates, CurrentPath, Value)
        } else if IsObject(Value) {
            ; Leaf feature object: persist all known properties
            Section := (ParentPath == "") ? Key : ParentPath
            for Prop in Props {
                if Value.HasOwnProp(Prop) {
                    ; Mirror ReadConfiguration: avoid "Foo.Foo" when the key
                    ; and property share the same name
                    ConfigKey := (Key == Prop) ? Prop : Key "." Prop
                    Updates.Push({ Section: Section, Key: ConfigKey, Value: Value.%Prop% })
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

_MakeScriptShortcutHandler(Slot, ActionName) {
    return (*) => SetScriptShortcutAction(Slot, ActionName)
}

; Build the « Raccourcis de gestion du script » submenu — one entry per slot,
; each opening a sub-submenu listing every gesture action so the user can
; rebind the AltGr+ combos to any of them.
BuildScriptShortcutsMenu() {
    global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, SCRIPT_SHORTCUT_DEFAULTS
    global ScriptShortcutAssignments, GESTURE_ACTIONS, GESTURE_ACTION_NAMES

    SMenu := Menu()
    for Slot in SCRIPT_SHORTCUT_SLOTS {
        Current := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
        CurrentLabel := GESTURE_ACTIONS.Has(Current)
            ? GESTURE_ACTIONS[Current].Label
            : "Désactivé"
        SlotMenu := Menu()
        ; "--" sentinels in GESTURE_ACTION_NAMES become visual separators
        ; in the slot picker so the user can see category boundaries
        ; (Selection / Editing / Keys / Tabs / Windows / …).
        last_was_separator := true   ; suppress leading separators
        for ActionName in GESTURE_ACTION_NAMES {
            if (ActionName == "--") {
                if !last_was_separator {
                    SlotMenu.Add()
                    last_was_separator := true
                }
                continue
            }
            if !GESTURE_ACTIONS.Has(ActionName)
                continue
            ActionLabel := GESTURE_ACTIONS[ActionName].Label
            SlotMenu.Add(ActionLabel, _MakeScriptShortcutHandler(Slot, ActionName))
            if (ActionName == Current) {
                SlotMenu.Check(ActionLabel)
            }
            last_was_separator := false
        }
        SMenu.Add(SCRIPT_SHORTCUT_LABELS[Slot] . " : " . CurrentLabel, SlotMenu)
    }
    return SMenu
}

FilePathsEditor(*) {
    global _ConfigDir, _PathsFile

    W := Gui(, "Dossier de configuration")
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12

    W.Add("Text", "xm", "Dossier de configuration personnel :")
    DirEdit := W.Add("Edit", "xm w480", _ConfigDir)
    W.Add("Button", "x+6 w80", "Parcourir…").OnEvent("Click", BrowseDir)

    W.Add("Text", "xm y+14 cGray",
        "Tous les fichiers personnels (personal_shortcuts.ahk, personal_hotstrings.toml…)`n"
        . "seront cherchés dans ce dossier. Laisser vide pour utiliser le dossier par défaut.")

    W.Add("Button", "xm y+10 w80", "OK").OnEvent("Click", SaveConfigDir)
    W.Add("Button", "x+6 w80", "Annuler").OnEvent("Click", (*) => W.Destroy())

    BrowseDir(*) {
        ; Start from the current field value if it exists, otherwise fall back to
        ; My Documents so the dialog opens somewhere useful rather than the script root.
        StartDir := Trim(DirEdit.Value)
        if (StartDir == "" or !DirExist(StartDir)) {
            StartDir := A_MyDocuments
        }
        Selected := DirSelect("*" . StartDir, 1, "Sélectionner le dossier de configuration")
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
        MsgBox("WindowSpy.ahk n'a pas été trouvé à l'emplacement suivant : " spyPath)
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
