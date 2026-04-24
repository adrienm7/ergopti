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

#Include *i vendor\UIA.ahk ; UIA v2 library — third-party, kept verbatim in vendor\ (source: https://github.com/Descolada/UIA-v2)
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
    try LoggerError("ErgoptiPlus", "Uncaught error: %s",
        Exc.Message . (Exc.HasProp("Stack") ? " | " . Exc.Stack : ""))
    ; Surface the error to the user once, without blocking subsequent keys
    try {
        MsgBox("ErgoptiPlus — erreur interne capturée :`n`n" . Exc.Message . "`n`n" . (Exc.HasProp("Stack") ? Exc.Stack : ""), "ErgoptiPlus", "Icon!")
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
#Include lib\logger.ahk

; INI helpers extracted to their own lib so the test runner can ``#Include``
; them without bootstrapping the rest of the driver.
#Include lib\ini_helpers.ahk

; Active-app cache must come before hotstring_engine.ahk because both
; ``HotstringHandler`` and ``MicrosoftApps`` consult ``GetActiveApp``.
#Include lib\active_app_cache.ahk

; Core hotstring engine (send primitives, hotstring builders, text helpers)
; and TOML reader helpers (UnescapeTomlString, LoadHotstringsSection,
; FoldAsciiLower, ApplyTomlMetadataToFeatures) extracted into dedicated
; submodules so the main file stays focused on ErgoptiPlus-specific logic.
#Include lib\hotstring_engine.ahk
#Include lib\toml_loader.ahk
; Auto-generated registrar for the bundled hotstring TOMLs. ``*i`` keeps the
; driver runnable from a fresh clone before ``tools/compile_hotstrings.py`` has
; been executed — ``LoadHotstringsSection`` falls back to the regex parser when
; ``_GENERATED_HOTSTRINGS`` is undefined.
#Include *i lib\hotstrings_generated.ahk
#Include lib\personal_toml_editor.ahk
#Include lib\dispatchers.ahk
#Include lib\layout_altgr.ahk
#Include lib\layout_shift_caps.ahk

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

; Read the configuration file path from a minimal bootstrap file so users can
; store ErgoptiPlus_Configuration.ini outside the Ergopti repository.
; The bootstrap file contains a single key: ConfigurationFilePath=<absolute path>
global _BootstrapFile := A_ScriptDir . "\ErgoptiPlus_Bootstrap.ini"
global ConfigurationFile := IniRead(_BootstrapFile, "Bootstrap", "ConfigurationFilePath",
    A_ScriptDir . "\ErgoptiPlus_Configuration.ini")

global ScriptInformation := Map(
    "MagicKey", "★",
    ; Shortcuts
    "ShortcutSuspend", True,
    "ShortcutSaveReload", True,
    "ShortcutEdit", True,
    ; The icon of the script when active or disabled
    "IconPath", "icons\ErgoptiPlus_Icon.ico",
    "IconPathDisabled", "icons\ErgoptiPlus_Icon_Disabled.ico",
    ; Configurable file paths (overridable from the ini so users can keep their
    ; personal files outside the Ergopti repository)
    "PersonalAhkPath", A_ScriptDir . "\personal.ahk",
    "PersonalTomlPath", A_ScriptDir . "\..\hotstrings\personal.toml",
    ; Set to True only when AltGr (SC138) has been remapped to Kana at the
    ; driver level (KbdEdit, MSKLC). With that remap active, AHK still sees
    ; the virtual AltGr-down bit stuck after a hotstring, and we need to
    ; inject {SC138 Up} before sending the replacement. Default is False:
    ; this spares one SendEvent per hotstring firing on standard setups.
    "AltGrIsKanaRemap", False,
)

global ConfigurationShortcutsList := [
    "ShortcutSuspend",
    "ShortcutSaveReload",
    "ShortcutEdit",
]

; ParseIniFile / IniCacheGet / ResolveConfigPath are defined in lib/ini_helpers.ahk
; (included above) so the test runner can exercise them in isolation.

ReadScriptConfig(Cache) {
    for Information in ScriptInformation {
        Value := IniCacheGet(Cache, "Script", Information)
        if Value != "_" {
            ScriptInformation[Information] := Value
        }
    }
}

global _IniCache := ParseIniFile(ConfigurationFile)
ReadScriptConfig(_IniCache)

; Resolve hot-path flags cached by the hotstring engine (AltGrIsKanaRemap)
; now that ScriptInformation reflects the INI overrides. Must run before the
; first hotstring fires.
HotstringEngineInit()

; Initialise the logger now that the ini cache is built and ScriptInformation
; reflects user overrides — LoggerInit reads [Script] LogLevel from the ini.
LoggerInit()
LoggerStart("ErgoptiPlus", "Booting ErgoptiPlus driver…")

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
#Include lib\features_config.ahk

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
                    Name := Feature . "." . Prop
                    RawValue := IniCacheGet(Cache, Category, Name)
                    if RawValue != "_" {
                        Features[Category][Feature].%Prop% := RawValue
                    }
                }
            }
        }
    }

    for Information in PersonalInformation {
        Value := IniCacheGet(Cache, "PersonalInformation", Information)
        if Value != "_" {
            PersonalInformation[Information] := Value
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
    Phone  := PersonalInformation["PhoneNumber"]
    FPhone := PersonalInformation["PhoneNumberClean"]
    Ssn    := PersonalInformation["SocialSecurityNumber"]
    Iban   := PersonalInformation["IBAN"]
    SsnRaw  := StrReplace(Ssn,  " ", "")
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
            return StrLen(SsnRaw) >= 5 ? 1 : 0
        case "IbanPrefixes":
            N := 0
            if StrLen(IbanRaw) >= 7
                N += 1
            if StrLen(IbanRaw) >= 9
                N += 1
            return N
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
                _DynVal.Description := "dt" . MK . " insère la date courante (" . FormatTime(, "dd/MM/yyyy") . ")" . CountSuffix
            case "Date":
                _DynVal.Description := "td" . MK . " insère la date courante (" . FormatTime(, "yyyy_MM_dd") . ")" . CountSuffix
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
        for Feature in GetFeatureByPath(CategoryPath)["__Order"] {
            if Feature == "-" {
                MenuParent.Add() ; Empty line
                continue
            }

            Key := Feature
            Val := GetFeatureByPath(CategoryPath)[Feature]
            CreateSubMenusRecursiveCommonCode(MenuParent, Key, Val, CategoryPath)
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
        ; Create submenu and store in SubMenus
        SubMenu := Menu()
        MenuParent.Add(Key, SubMenu)
        SubMenus[FullPath] := SubMenu
        ; Recursively create nested submenus
        CreateSubMenusRecursive(SubMenu, Val, FullPath)
    } else if IsObject(Val) and Val.HasOwnProp("Enabled") {
        MenuAddItem(MenuParent, CategoryPath, Key)
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
            IniWrite(Shortcut.Enabled, ConfigurationFile, FeatureCategoryPath, ShortcutName . ".Enabled")
        }
    }
    Feature.Enabled := !CurrentFeatureActivation
    IniWrite(Feature.Enabled, ConfigurationFile, FeatureCategoryPath, FeatureName . ".Enabled")
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
            return "Raccourcis"
        case "TapHolds":
            return "Tap-Holds ⌨️"
        default:
            return ""
    }
}

; =========================
; Main menu initialization
; =========================

global MenuHotstrings := "Hotstrings ⚡"
global MenuScriptManagement := "Gestion du script"
global MenuConfigurationShortcuts := "Raccourcis de gestion du script"
global MenuSuspend := "⏸︎ Suspendre" . (ScriptInformation["ShortcutSuspend"] ? " (AltGr + ↩)" : "")
global MenuDebugging := "⚠ Débogage"

; Categories that live inside the Hotstrings submenu (ordered to match HS menu)
global HotstringCategories := ["DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey"]

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
    ; Personal is defined in personal.ahk (not in the static Features map), so it
    ; must be wired separately after the loop — only when the user's file loaded it.
    if Features.Has("Personal") {
        PersonalSubMenu := Menu()
        SubMenus["Personal"] := PersonalSubMenu
        CreateSubMenusRecursive(PersonalSubMenu, Features["Personal"], "Personal")
    }
}

initMenu() {
    global Features, SubMenus, A_TrayMenu, HotstringCategories

    A_TrayMenu.Delete()

    ; ── Disposition clavier 🎹 — mirrors the future HS layout section ──
    LayoutMenu := Menu()
    for FeatureName in Features["Layout"]["__Order"] {
        MenuAddItem(LayoutMenu, "Layout", FeatureName)
    }
    A_TrayMenu.Add("Disposition clavier 🎹", LayoutMenu)

    ; ── Hotstrings ⚡ — single submenu grouping all hotstring categories ──
    HotstringsMenu := Menu()
    for Category in HotstringCategories {
        if SubMenus.Has(Category) {
            Total := CountTomlHotstrings(Category)
            Title := GetCategoryTitle(Category) . (Total > 0 ? " (" . Total . ")" : "")
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
            . (DynTotal > 0 ? " (" . DynTotal . ")" : "")
        HotstringsMenu.Add(DynTitle, DynMenu)
    }

    ; Personal hotstrings — unified submenu that mirrors HS build_custom layout:
    ; editor button + shortcut hint up top, then per-section toggle checkboxes
    ; with hotstring counts, replacing the old separate editor-only submenu.
    if Features.Has("Personal") {
        ; Read personal.toml once to get section order, descriptions, and counts
        TomlData := ReadPersonalToml()
        ; Enrich Features["Personal"] descriptions with entry counts so that
        ; MenuAddItem / GetMenuTitleByPath display them alongside the checkbox
        for _, SecName in TomlData["sections_order"] {
            SecData  := TomlData["sections"][SecName]
            Count    := SecData["entries"].Length
            BaseDesc := SecData["description"]
            ; Match lowercase TOML key to the PascalCase Features key
            for FeatKey in Features["Personal"] {
                if (FeatKey != "__Order" and StrLower(FeatKey) == SecName) {
                    Features["Personal"][FeatKey].Description := BaseDesc . " (" . Count . ")"
                }
            }
        }
        ; Build the unified personal submenu
        PersonalMenu := Menu()
        PersonalMenu.Add("Ouvrir l'éditeur de hotstrings", (*) => OpenPersonalEditor())
        PersonalMenu.Add("Raccourci : Win + " . ScriptInformation["MagicKey"], (*) => NoAction())
        PersonalMenu.Disable("Raccourci : Win + " . ScriptInformation["MagicKey"])
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
            . (TotalPersonal > 0 ? " (" . TotalPersonal . ")" : "")
        HotstringsMenu.Add(PersonalTitle, PersonalMenu)
    }
    HotstringsMenu.Add() ; Separating line
    HotstringsMenu.Add("☑ Activer tous les hotstrings", ToggleAllHotstringsOn)
    HotstringsMenu.Add("☐ Désactiver tous les hotstrings", ToggleAllHotstringsOff)
    HotstringsMenu.Add() ; Separating line
    ; Magic key editor — mirrors HS menu_hotstrings build_management placement
    HotstringsMenu.Add("Touche magique : " . ScriptInformation["MagicKey"], MagicKeyEditor)
    A_TrayMenu.Add(MenuHotstrings, HotstringsMenu)

    ; ── Raccourcis and Tap-Holds — standalone, like HS Raccourcis and Karabiner ──
    if SubMenus.Has("Shortcuts") {
        A_TrayMenu.Add(GetCategoryTitle("Shortcuts"), SubMenus["Shortcuts"])
    }
    if SubMenus.Has("TapHolds") {
        A_TrayMenu.Add(GetCategoryTitle("TapHolds"), SubMenus["TapHolds"])
    }

    A_TrayMenu.Add() ; Separating line

    ; ── Actions globales — mirrors HS "Actions globales" submenu ──
    GlobalActionsMenu := Menu()
    GlobalActionsMenu.Add("☑ Activer toutes les fonctionnalités", ToggleAllFeaturesOn)
    GlobalActionsMenu.Add("☐ Désactiver toutes les fonctionnalités", ToggleAllFeaturesOff)
    GlobalActionsMenu.Add("↺ Valeurs par défaut", ReloadWithDefaultConfig)
    A_TrayMenu.Add("Actions globales", GlobalActionsMenu)

    ; ── Préférences — mirrors HS bottom items (Préférences, Console, open file…) ──
    PrefsMenu := Menu()
    PrefsMenu.Add("Modifier les coordonnées personnelles", PersonalInformationEditor)
    PrefsMenu.Add("Modifier les raccourcis sur les lettres accentuées", ShortcutsEditor)
    PrefsMenu.Add("Modifier le lien ouvert par Win + G", GPTLinkEditor)
    PrefsMenu.Add("📂 Chemins des fichiers personnels", FilePathsEditor)
    A_TrayMenu.Add("Préférences…", PrefsMenu)

    ; ── Script management section ──
    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuScriptManagement, NoAction)
    A_TrayMenu.Disable(MenuScriptManagement)

    A_TrayMenu.Add(MenuConfigurationShortcuts, ToggleConfigurationShortcuts)
    if AllConfigurationShortcutsEnabled() {
        A_TrayMenu.Check(MenuConfigurationShortcuts)
    } else {
        A_TrayMenu.Uncheck(MenuConfigurationShortcuts)
    }

    A_TrayMenu.Add("✎ Éditer" . (ScriptInformation["ShortcutEdit"] ? " (AltGr + ⌦)" : ""), ActivateEdit)
    A_TrayMenu.Add(MenuSuspend, ToggleSuspend)
    A_TrayMenu.Add("🔄 Recharger" . (ScriptInformation["ShortcutSaveReload"] ? " (AltGr + ⌫)" : ""),
    ActivateReload)
    A_TrayMenu.Add("⏹ Quitter (AltGr + ⎋)", ActivateExitApp)

    ; ── Debugging section ──
    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuDebugging, NoAction)
    A_TrayMenu.Disable(MenuDebugging)
    A_TrayMenu.Add("Window Spy", WindowSpy)
    A_TrayMenu.Add("État des variables", ActivateListVars)
    A_TrayMenu.Add("Historique des touches", ActivateKeyHistory)
}

; Personal file and TOML loaded here — before menu build — so Features["Personal"]
; exists by the time InitSubMenus / initMenu run.
#Include *i personal.ahk
if Features.Has("Personal") {
    ApplyTomlMetadataToFeatures("Personal")
}

InitSubMenus()
initMenu()
UpdateTrayIcon()
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
    IniWrite(NewValue, ConfigurationFile, "Script", "MagicKey")

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
    global PersonalInformation, ConfigurationFile
    changed := Map()
    for key, editControl in edits {
        NewValue := editControl.Text
        OldValue := PersonalInformation.Has(key) ? PersonalInformation[key] : ""
        if (NewValue != OldValue)
            changed[key] := True
        PersonalInformation[key] := NewValue
        IniWrite(NewValue, ConfigurationFile, "PersonalInformation", key)
    }
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

ShortcutsEditor(*) {
    GuiToShow := Gui(, "Modifier les raccourcis par défaut")

    GuiToShow.SetFont("bold")
    GuiToShow.Add("Text", , "Raccourcis sur la touche È")
    GuiToShow.SetFont("norm")
    NewEGraveValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["EGrave"].Letter)

    GuiToShow.SetFont("bold")
    GuiToShow.Add("Text", , "Raccourcis sur la touche Ê")
    GuiToShow.SetFont("norm")
    NewECircValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["ECirc"].Letter)

    GuiToShow.SetFont("bold")
    GuiToShow.Add("Text", , "Raccourcis sur la touche É")
    GuiToShow.SetFont("norm")
    NewEAcuteValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["EAcute"].Letter)

    GuiToShow.SetFont("bold")
    GuiToShow.Add("Text", , "Raccourcis sur la touche À")
    GuiToShow.SetFont("norm")
    NewAGraveValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["AGrave"].Letter)

    GuiToShow.Add("Button", "w100 Center", "OK").OnEvent(
        "Click",
        (*) => ModifyValues(GuiToShow, NewEGraveValue.Text, NewECircValue.Text, NewEAcuteValue.Text, NewAGraveValue
            .Text
        )
    )
    GuiToShow.Show("Center")
}
ModifyValues(gui, NewEGraveValue, NewECircValue, NewEAcuteValue, NewAGraveValue) {
    Features["Shortcuts"]["EGrave"].Letter := NewEGraveValue
    IniWrite(NewEGraveValue, ConfigurationFile, "Shortcuts", "EGrave" . "." . "Letter")

    Features["Shortcuts"]["ECirc"].Letter := NewECircValue
    IniWrite(NewECircValue, ConfigurationFile, "Shortcuts", "ECirc" . "." . "Letter")

    Features["Shortcuts"]["EAcute"].Letter := NewEAcuteValue
    IniWrite(NewEAcuteValue, ConfigurationFile, "Shortcuts", "EAcute" . "." . "Letter")

    Features["Shortcuts"]["AGrave"].Letter := NewAGraveValue
    IniWrite(NewAGraveValue, ConfigurationFile, "Shortcuts", "AGrave" . "." . "Letter")

    gui.Destroy()
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
    IniWrite(NewValue, ConfigurationFile, "Shortcuts", "GPT" . "." . "Link")

    gui.Destroy()
    Reload
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
    ; through IniWrite does 50+ FileOpen/Write/Close round-trips and produces a
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
    IniBatchWrite(ConfigurationFile, Updates)
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
    IniBatchWrite(ConfigurationFile, Updates)
    Reload
}

ReloadWithDefaultConfig(*) {
    ; Delete the ini so the next startup uses all default values, then reload
    if FileExist(ConfigurationFile) {
        FileDelete(ConfigurationFile)
    }
    Reload
}

ToggleConfigurationShortcuts(*) {
    NewValue := not AllConfigurationShortcutsEnabled()
    Updates := []
    for Shortcut in ConfigurationShortcutsList {
        ScriptInformation[Shortcut] := NewValue
        Updates.Push({ Section: "Script", Key: Shortcut, Value: NewValue })
    }
    IniBatchWrite(ConfigurationFile, Updates)
    Reload
}
AllConfigurationShortcutsEnabled(*) {
    for Shortcut in ConfigurationShortcutsList {
        if ( not ScriptInformation[Shortcut]) {
            return False
        }
    }
    return True
}

FilePathsEditor(*) {
    global ScriptInformation, ConfigurationFile, _BootstrapFile

    W := Gui(, "Chemins des fichiers personnels")
    W.SetFont("s10", "Segoe UI")
    W.MarginX := 12
    W.MarginY := 12

    ; --- ErgoptiPlus_Configuration.ini (first: all other paths are stored in it) ---
    W.Add("Text", "xm", "Fichier de configuration (.ini) :")
    IniEdit := W.Add("Edit", "xm w480", ConfigurationFile)
    W.Add("Button", "x+6 w80", "Parcourir…").OnEvent("Click", (*) => BrowseFile(
        IniEdit, "Fichiers INI (*.ini)", "*.ini"))

    ; --- personal.ahk ---
    W.Add("Text", "xm y+10", "Fichier personal.ahk :")
    AhkEdit := W.Add("Edit", "xm w480", ScriptInformation["PersonalAhkPath"])
    W.Add("Button", "x+6 w80", "Parcourir…").OnEvent("Click", (*) => BrowseFile(
        AhkEdit, "Fichiers AHK (*.ahk)", "*.ahk"))

    ; --- personal.toml ---
    W.Add("Text", "xm y+10", "Fichier personal.toml :")
    TomlEdit := W.Add("Edit", "xm w480", ScriptInformation["PersonalTomlPath"])
    W.Add("Button", "x+6 w80", "Parcourir…").OnEvent("Click", (*) => BrowseFile(
        TomlEdit, "Fichiers TOML (*.toml)", "*.toml"))

    W.Add("Text", "xm y+14 cGray",
        "Laissez un champ vide pour utiliser le chemin par défaut.")

    W.Add("Button", "xm y+10 w80", "OK").OnEvent("Click", SaveFilePaths)
    W.Add("Button", "x+6 w80", "Annuler").OnEvent("Click", (*) => W.Destroy())

    BrowseFile(EditCtrl, FilterDesc, FilterExts) {
        Selected := FileSelect(3, EditCtrl.Value, "Sélectionner un fichier", FilterDesc . " (" . FilterExts . ")")
        if (Selected != "") {
            EditCtrl.Value := Selected
        }
    }

    SaveFilePaths(*) {
        global ScriptInformation, ConfigurationFile, _BootstrapFile

        NewAhkPath := Trim(AhkEdit.Value)
        NewTomlPath := Trim(TomlEdit.Value)
        NewIniPath := Trim(IniEdit.Value)

        DefaultAhkPath := A_ScriptDir . "\personal.ahk"
        DefaultTomlPath := A_ScriptDir . "\..\hotstrings\personal.toml"
        DefaultIniPath := A_ScriptDir . "\ErgoptiPlus_Configuration.ini"

        FinalAhkPath := (NewAhkPath == "") ? DefaultAhkPath : NewAhkPath
        FinalTomlPath := (NewTomlPath == "") ? DefaultTomlPath : NewTomlPath
        FinalIniPath := (NewIniPath == "") ? DefaultIniPath : NewIniPath

        ; Persist the ini path in the bootstrap file (it cannot live in the ini itself)
        IniWrite(FinalIniPath, _BootstrapFile, "Bootstrap", "ConfigurationFilePath")

        ; Persist the two file paths in the ini under [Script]
        IniWrite(FinalAhkPath, FinalIniPath, "Script", "PersonalAhkPath")
        IniWrite(FinalTomlPath, FinalIniPath, "Script", "PersonalTomlPath")

        TomlChanged := (FinalTomlPath != ScriptInformation["PersonalTomlPath"])

        ScriptInformation["PersonalAhkPath"] := FinalAhkPath
        ScriptInformation["PersonalTomlPath"] := FinalTomlPath
        ConfigurationFile := FinalIniPath

        W.Destroy()

        if TomlChanged {
            ; The TOML path changed — a full reload is required to re-register hotstrings
            MsgBox("Le chemin du fichier TOML a changé.`nLe script va être rechargé.", "Rechargement", "Icon!")
            Reload
        }
    }

    W.Show("Center")
}

ActivateEdit(*) {
    Edit
}

ToggleSuspend(*) {
    SuspendScript := not A_IsSuspended
    if SuspendScript {
        Suspend(1)
        Pause(1) ; Freeze currently executing things in the thread
    } else {
        Suspend(0)
        Pause(0) ; Unfreeze the thread
    }
    UpdateTrayIcon()
    LoggerInfo("ErgoptiPlus", "Suspend toggled: %s.", SuspendScript ? "ON" : "OFF")
}

UpdateTrayIcon() {
    if A_IsSuspended {
        A_TrayMenu.Check(MenuSuspend)
        if FileExist(ScriptInformation["IconPathDisabled"]) {
            TraySetIcon(ScriptInformation["IconPathDisabled"], , True)
        }
    } else {
        A_TrayMenu.Uncheck(MenuSuspend)
        if FileExist(ScriptInformation["IconPath"]) {
            TraySetIcon(ScriptInformation["IconPath"])
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

#SuspendExempt

#HotIf ScriptInformation["ShortcutSuspend"]
; Activate/Deactivate the script with AltGr + Enter
RAlt & Enter::
SC138 & SC01C::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC01C", "P")) {
        ToggleSuspend()
    } else {
        SendInput("{Enter}")
    }
}
#HotIf

#HotIf ScriptInformation["ShortcutSaveReload"]
; Save and reload the script with AltGr + BackSpace
RAlt & BackSpace::
SC138 & SC00E::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC00E", "P")) {
        SendInput("{LControl Down}s{LControl Up}") ; Save the script by sending Ctrl + S
        Sleep(300) ; Leave time for the file to be saved
        Reload
    } else {
        SendInput("{BackSpace}")
    }
}
#HotIf

#HotIf ScriptInformation["ShortcutEdit"]
; Open personal.ahk (user config file) with AltGr + Delete (Suppr.)
RAlt & Delete::
SC138 & SC153::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC153", "P")) {
        PersonalAhkPath := ScriptInformation["PersonalAhkPath"]
        if !FileExist(PersonalAhkPath) {
            FileAppend(
                "; drivers/autohotkey/personal.ahk`r`n"
                . "; Fichier de configuration personnelle — non suivi par git.`r`n"
                . "; Ajouter ici vos propres raccourcis clavier et hotstrings.`r`n"
                . "; Ce fichier est chargé en priorité maximale par ErgoptiPlus.ahk.`r`n"
                . "`r`n"
                . "#Requires AutoHotkey v2.0`r`n",
                PersonalAhkPath,
                "UTF-8-RAW"
            )
        }
        Run('notepad.exe "' . PersonalAhkPath . '"')
    } else {
        SendInput("{Delete}")
    }
}
#HotIf

; Quit the script entirely with AltGr + Escape
RAlt & Escape::
SC138 & SC001::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC001", "P")) {
        ExitApp
    } else {
        SendInput("{Escape}")
    }
}

#SuspendExempt False

; =======================================================
; =======================================================
; =======================================================
; ================ 2/ PERSONAL SHORTCUTS ================
; =======================================================
; =======================================================
; =======================================================

; personal.ahk is included earlier (before menu build) so Features["Personal"]
; is populated before InitSubMenus/initMenu run.
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
#Include modules\layout.ahk
#Include modules\shortcuts.ahk
#Include modules\tap_holds.ahk
#Include modules\hotstrings.ahk

; Final lifecycle marker — all hotkeys and hotstrings are registered, the
; script is ready to handle keystrokes. A missing SUCCESS in the log file
; pinpoints which #Include above failed silently.
LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")
