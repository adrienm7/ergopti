; Last modified on 2026-04-23 at 00:00 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

#Warn All
#Warn VarUnset, Off ; Disable undefined variables warning. This removes the warnings caused by the import of UIA

#Include *i lib\UIA.ahk ; UIA v2 library — bundled in lib\ (source: https://github.com/Descolada/UIA-v2)
; *i = no error if the file isn't found, as this library is not mandatory to run this script

; #Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t   ; Adds the no breaking spaces as hotstrings triggers
A_MenuMaskKey := "vkff" ; Change the masking key to the void key
A_MaxHotkeysPerInterval := 150 ; Reduce messages saying too many hotkeys pressed in the interval

SetKeyDelay(0) ; No delay between key presses
SendMode("Event") ; Everything concerning hotstrings MUST use SendEvent and not SendInput which is the default
; Otherwise, we can’t have a hotstring triggering another hotstring, triggering another hotstring, etc.

; Core hotstring engine (send primitives, hotstring builders, text helpers)
; and TOML reader helpers (UnescapeTomlString, LoadHotstringsSection,
; FoldAsciiLower, ApplyTomlMetadataToFeatures) extracted into dedicated
; submodules so the main file stays focused on ErgoptiPlus-specific logic.
#Include lib\hotstring_engine.ahk
#Include lib\toml_loader.ahk
#Include lib\personal_toml_editor.ahk

; ======================================================
; ======================================================
; ======================================================
; ================ 1/ SCRIPT MANAGEMENT ================
; ======================================================
; ======================================================
; ======================================================

; The code in this section shouldn’t be modified
; All features can be changed by using the configuration file

; =============================================
; ======= 1.1) Variables initialization =======
; =============================================

; NOT TO MODIFY
global RemappedList := Map()
global LastSentCharacterKeyTime := Map() ; Tracks the time since a key was pressed
global LastSentCharacters := [] ; Enables to modify the output of a key depending on the previous character sent
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
)

global ConfigurationShortcutsList := [
    "ShortcutSuspend",
    "ShortcutSaveReload",
    "ShortcutEdit",
]

ReadScriptConfig() {
    for Information in ScriptInformation {
        Value := IniRead(ConfigurationFile, "Script", Information, "_")
        if Value != "_" {
            ScriptInformation[Information] := Value
        }
    }
}

; Resolve a configured path: expand %VARS% and fall back to DefaultPath when blank.
ResolveConfigPath(RawValue, DefaultPath) {
    Trimmed := Trim(RawValue)
    if (Trimmed == "" or Trimmed == "_") {
        return DefaultPath
    }
    return Trimmed
}

if FileExist(ConfigurationFile) {
    ReadScriptConfig()
}

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

ReadConfiguration() {
    Props := ["Enabled", "TimeActivationSeconds", "Letter", "PatternMaxLength", "Link", "DestinationFolder",
        "DatedNotes", "SearchEngine", "SearchEngineURLQuery"]

    for Category, FeaturesMap in Features {
        for Feature, Value in FeaturesMap {
            if (Type(Value) = "Map") {
                ; Sub-map => iterate sub-features under [Category.Feature]
                for SubFeature, SubValue in Value {
                    for Prop in Props {
                        Name := SubFeature . "." . Prop
                        RawValue := IniRead(ConfigurationFile, Category "." Feature, Name, "_")
                        if RawValue != "_" {
                            Features[Category][Feature][SubFeature].%Prop% := RawValue
                        }
                    }
                }
            } else {
                for Prop in Props {
                    Name := Feature . "." . Prop
                    RawValue := IniRead(ConfigurationFile, Category, Name, "_")
                    if RawValue != "_" {
                        Features[Category][Feature].%Prop% := RawValue
                    }
                }
            }
        }
    }

    for Information in PersonalInformation {
        Value := IniRead(ConfigurationFile, "PersonalInformation", Information, "_")
        if Value != "_" {
            PersonalInformation[Information] := Value
        }
    }

    for Information in ScriptInformation {
        Value := IniRead(ConfigurationFile, "Script", Information, "_")
        if Value != "_" {
            ScriptInformation[Information] := Value
        }
    }
}

ReadConfiguration()

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
    ; must be wired separately after the loop — only when the user’s file loaded it.
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
            HotstringsMenu.Add(GetCategoryTitle(Category), SubMenus[Category])
        }
    }
    ; Personal hotstrings section — only shown when personal.ahk defines it.
    ; Each TOML section gets its own submenu entry that opens the editor directly
    ; on that section, mirroring the HS build_custom section navigation.
    if (Features.Has("Personal") and SubMenus.Has("Personal")) {
        HotstringsMenu.Add(GetCategoryTitle("Personal"), SubMenus["Personal"])
    }
    HotstringsMenu.Add() ; Separating line
    HotstringsMenu.Add("☑ Activer tous les hotstrings", ToggleAllHotstringsOn)
    HotstringsMenu.Add("☐ Désactiver tous les hotstrings", ToggleAllHotstringsOff)
    HotstringsMenu.Add() ; Separating line
    ; Magic key editor — mirrors HS menu_hotstrings build_management placement
    HotstringsMenu.Add("Touche magique : " . ScriptInformation["MagicKey"], MagicKeyEditor)
    HotstringsMenu.Add() ; Separating line
    ; Editor entry with per-section submenu (mirrors HS build_custom section list)
    PersonalEditorMenu := Menu()
    PersonalEditorMenu.Add("Ouvrir l'éditeur", (*) => OpenPersonalEditor())
    TomlData := ReadPersonalToml()
    if TomlData["sections_order"].Length > 0 {
        PersonalEditorMenu.Add() ; Separating line
        for _, SecName in TomlData["sections_order"] {
            SecDesc := TomlData["sections"].Has(SecName)
                ? TomlData["sections"][SecName]["description"]
                : SecName
            ; Use a bound method to capture SecName by value — AHK v2 closures
            ; capture variables by reference so the loop variable must be frozen.
            PersonalEditorMenu.Add(SecDesc, _MakeOpenSectionFn(SecName))
        }
    }
    HotstringsMenu.Add("📝 Éditeur de hotstrings personnels (Win + " . ScriptInformation["MagicKey"] . ")",
        PersonalEditorMenu)
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
    global Features

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
                    IniWrite(Value, ConfigurationFile, parentSection, Key . ".Enabled")
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
                    IniWrite(Value, ConfigurationFile, section, Key . ".Enabled")
                } else {
                    IniWrite(Value, ConfigurationFile, section, keyName . ".Enabled")
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
                    IniWrite(Value, ConfigurationFile, Category, FeatureName . ".Enabled")
                }
                ; If Val is a Map without Enabled, we skip its children when enabling
            }
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
ToggleAllHotstrings(Value) {
    global Features, HotstringCategories
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
                IniWrite(Value, ConfigurationFile, Category, FeatureName . ".Enabled")
            }
        }
    }
    ; Also toggle the Personal category when present
    if Features.Has("Personal") {
        for FeatureName, Val in Features["Personal"] {
            if FeatureName == "__Order" {
                continue
            }
            if IsObject(Val) and Val.HasOwnProp("Enabled") {
                Val.Enabled := Value
                IniWrite(Value, ConfigurationFile, "Personal", FeatureName . ".Enabled")
            }
        }
    }
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
    for Shortcut in ConfigurationShortcutsList {
        ScriptInformation[Shortcut] := NewValue
        IniWrite(NewValue, ConfigurationFile, "Script", Shortcut)
    }
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
    Reload
}

ActivateExitApp(*) {
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
        MsgBox("WindowSpy.ahk n’a pas été trouvé à l’emplacement suivant : " spyPath)
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
        Run("notepad.exe " . PersonalAhkPath)
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
