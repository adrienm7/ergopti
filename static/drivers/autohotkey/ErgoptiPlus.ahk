; Last modified on 2026-04-12 at 20:06 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

#Warn All
#Warn VarUnset, Off ; Disable undefined variables warning. This removes the warnings caused by the import of UIA

#Include *i UIA\Lib\UIA.ahk ; Can be downloaded here : https://github.com/Descolada/UIA-v2/tree/main
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

global ConfigurationFile := "ErgoptiPlus_Configuration.ini"

global ScriptInformation := Map(
    "MagicKey", "★",
    ; Shortcuts
    "ShortcutSuspend", True,
    "ShortcutSaveReload", True,
    "ShortcutEdit", True,
    ; The icon of the script when active or disabled
    "IconPath", "ErgoptiPlus_Icon.ico",
    "IconPathDisabled", "ErgoptiPlus_Icon_Disabled.ico",
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
            return "➀ Réduction des distances"
        case "SFBsReduction":
            return "➁ Réduction des SFBs"
        case "Rolls":
            return "➂ Roulements"
        case "Autocorrection":
            return "➃ Autocorrection"
        case "MagicKey":
            return "➄ Touche " . ScriptInformation["MagicKey"] . " et expansion de texte"
        case "Shortcuts":
            return "➅ Raccourcis"
        case "TapHolds":
            return "➆ Tap-Holds"
        default:
            return ""
    }
}

; =========================
; Main menu initialization
; =========================

global MenuLayout := "Modification de la disposition clavier"
global MenuAllFeatures := "Features Ergopti➕"
global MenuScriptManagement := "Gestion du script"
global MenuConfigurationShortcuts := "Raccourcis de gestion du script"
global MenuSuspend := "⏸︎ Suspendre" . (ScriptInformation["ShortcutSuspend"] ? " (AltGr + ↩)" : "")
global MenuDebugging := "⚠ Débogage"

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
}

initMenu() {
    global Features, SubMenus, A_TrayMenu
    A_TrayMenu.Delete()

    ; Layout section (top-level)
    A_TrayMenu.Add(MenuLayout, NoAction)
    A_TrayMenu.Disable(MenuLayout)
    for FeatureName in Features["Layout"]["__Order"] {
        MenuAddItem(A_TrayMenu, "Layout", FeatureName)
    }
    A_TrayMenu.Add()
    A_TrayMenu.Add(MenuAllFeatures, NoAction)
    A_TrayMenu.Disable(MenuAllFeatures)

    ; Add only top-level submenus to global tray menu
    for Category in Features["__Order"] {
        if Category = "Layout"
            continue ; Don’t add this submenu as we already added it above
        SubMenu := SubMenus[Category]
        CategoryTitle := GetCategoryTitle(Category)
        A_TrayMenu.Add(CategoryTitle, SubMenu)
    }

    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add("✔️ TOUT activer", ToggleAllFeaturesOn)
    A_TrayMenu.Add("❌ TOUT désactiver", ToggleAllFeaturesOff)
    A_TrayMenu.Add("Modifier la touche magique", MagicKeyEditor)
    A_TrayMenu.Add("Modifier les coordonnées personnelles", PersonalInformationEditor)
    A_TrayMenu.Add("Modifier les raccourcis sur les lettres accentuées", ShortcutsEditor)
    A_TrayMenu.Add("Modifier le lien ouvert par Win + G", GPTLinkEditor)

    ; Script management section
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
    A_TrayMenu.Add("⏹ Quitter", ActivateExitApp)

    ; Debugging section
    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuDebugging, NoAction)
    A_TrayMenu.Disable(MenuDebugging)
    A_TrayMenu.Add("Window Spy", WindowSpy)
    A_TrayMenu.Add("État des variables", ActivateListVars)
    A_TrayMenu.Add("Historique des touches", ActivateKeyHistory)
}

InitSubMenus()
initMenu()
UpdateTrayIcon()

; ========================================================
; ======= 1.4) Tray menu of the script — Functions =======
; ========================================================

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

ToggleConfigurationShortcuts(*) {
    NewValue := not AllConfigurationShortcutsEnabled()
    for Shortcut in ConfigurationShortcutsList {
        ScriptInformation[Shortcut] := ToggleConfigurationShortcuts
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
        PersonalAhkPath := A_ScriptDir . "\personal.ahk"
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

; Open personal hotstring editor with Ctrl + ★ (SC02E — physical key position of ★/j)
^SC02E::OpenPersonalEditor()

#SuspendExempt False

; =======================================================
; =======================================================
; =======================================================
; ================ 2/ PERSONAL SHORTCUTS ================
; =======================================================
; =======================================================
; =======================================================

; Personal shortcuts, hotkeys, and feature configuration live in personal.ahk
; (not tracked by git). Drop your own hotkeys there; they override any
; built-in definition because they are registered first.
; Personal TOML hotstrings (hotstrings/personal.toml) are then loaded
; immediately after so they also take priority over all other hotstrings.
#Include *i personal.ahk

; Load personal TOML hotstrings with maximum priority (defined before all
; built-in hotstrings so they shadow any conflicting built-in entry).
if Features.Has("Personal") {
    ApplyTomlMetadataToFeatures("Personal")
    if Features["Personal"].Has("EmailShortcuts") and Features["Personal"]["EmailShortcuts"].Enabled {
        LoadHotstringsSection("personal", "emailshortcuts", Features["Personal"]["EmailShortcuts"])
    }
    if Features["Personal"].Has("Code") and Features["Personal"]["Code"].Enabled {
        LoadHotstringsSection("personal", "code", Features["Personal"]["Code"])
    }
    if Features["Personal"].Has("ProfessionalVocabulary") and Features["Personal"]["ProfessionalVocabulary"].Enabled {
        LoadHotstringsSection("personal", "professionalvocabulary", Features["Personal"]["ProfessionalVocabulary"])
    }
    if Features["Personal"].Has("Autocorrection") and Features["Personal"]["Autocorrection"].Enabled {
        LoadHotstringsSection("personal", "autocorrection", Features["Personal"]["Autocorrection"])
    }
}

#InputLevel 2 ; Mandatory for this section to work, it needs to be below the InputLevel of the key remappings

; ========================================================
; ========================================================
; ========================================================
; ================ 3/ LAYOUT MODIFICATION ================
; ========================================================
; ========================================================
; ========================================================

#InputLevel 2 ; Very important, we need to be at an higher InputLevel to remap the keys into something else.
; It is because we will then remap keys we just remapped, so the InputLevel of those other shortcuts must be lower
; This is especially important for the "★" key, otherwise the hotstrings involving this key won’t trigger.

; It is better to use #HotIf everywhere in this part instead of simple ifs.
; Otherwise we can run into issues like double defined hotkeys, or hotkeys that can’t be overriden

/*
    ======= Scancodes map of the keyboard keys =======
        A scancode has a form like SC000.
        Thus, to select the key located at the F character location in QWERTY/AZERTY, the scancode is SC021.
        SC039 is the space bar, SC028 the character ù, SC003 the key &/1, etc.
        Using scancodes is much more reliable than using the characters produced by the keys, as those heavily depend on the keyboard layouts.

	---     ---------------   ---------------   ---------------   -----------
	| 01|   | 3B| 3C| 3D| 3E| | 3F| 40| 41| 42| | 43| 44| 57| 58| |+37|+46|+45|
	---     ---------------   ---------------   ---------------   -----------
	-----------------------------------------------------------   -----------   ---------------
	| 29| 02| 03| 04| 05| 06| 07| 08| 09| 0A| 0B| 0C| 0D|     0E| |*52|*47|*49| |+45|+35|+37| 4A|
	|-----------------------------------------------------------| |-----------| |---------------|
	|   0F| 10| 11| 12| 13| 14| 15| 16| 17| 18| 19| 1A| 1B|     | |*53|*4F|*51| | 47| 48| 49|   |
	|------------------------------------------------------|  1C|  -----------  |-----------| 4E|
	|    3A| 1E| 1F| 20| 21| 22| 23| 24| 25| 26| 27| 28| 2B|    |               | 4B| 4C| 4D|   |
	|-----------------------------------------------------------|      ---      |---------------|
	|  2A| 56| 2C| 2D| 2E| 2F| 30| 31| 32| 33| 34| 35|       136|     |*4C|     | 4F| 50| 51|   |
	|-----------------------------------------------------------|  -----------  |-----------|-1C|
	|   1D|15B|   38|           39            |138|15C|15D|  11D| |*4B|*50|*4D| |     52| 53|   |
	-----------------------------------------------------------   -----------   ---------------
*/

UpdateLastSentCharacter(Character) {
    global LastSentCharacters
    LastSentCharacters.Push(Character)
    ; Keep only the last 5 keys to save memory
    if (LastSentCharacters.Length > 5)
        LastSentCharacters.RemoveAt(1)

    global LastSentCharacterKeyTime
    LastSentCharacterKeyTime[Character] := A_TickCount
}

RemapKey(ScanCode, Character, AlternativeCharacter := "") {
    global RemappedList
    InputLevel := "I2"

    Hotkey(
        "*" ScanCode,
        (*) => SendEvent("{Blind}" Character) UpdateLastSentCharacter(Character),
        InputLevel
    )

    if AlternativeCharacter == "" {
        RemappedList[Character] := ScanCode
    } else {
        Hotkey(
            ScanCode,
            (*) => SendEvent("{Text}" . AlternativeCharacter) UpdateLastSentCharacter(AlternativeCharacter),
            InputLevel
        )
    }

    ; In theory, * and {Blind} should be sufficient, but it isn’t the case when we define custom hotkeys in next sections
    ; For example, a new hotkey for ^b leads to ^t giving ^b in QWERTY
    ; The same happens for Win shortcuts, where we can get the shortcut on the QWERTY layer and not emulated Ergopti layer
    Hotkey(
        "^" ScanCode,
        (*) => SendEvent("^" Character) UpdateLastSentCharacter(Character),
        InputLevel
    )
    Hotkey(
        "!" ScanCode,
        (*) => SendEvent("!" Character) UpdateLastSentCharacter(Character),
        "I3" ; Needs to be higher to keep the Alt shortcuts
    )
    if Character == "l" {
        ; Solves a bug of # + remapped letter L not triggering the Lock shortcup
        Hotkey(
            "#" ScanCode,
            (*) => DllCall("LockWorkStation") UpdateLastSentCharacter(Character),
            InputLevel
        )
    } else {
        Hotkey(
            "#" ScanCode,
            (*) => SendEvent("#" Character) UpdateLastSentCharacter(Character),
            InputLevel
        )
    }
}

WrapTextIfSelected(Symbol, LeftSymbol, RightSymbol) {
    Selection := ""
    if (
        isSet(UIA) and Features["Shortcuts"]["WrapTextIfSelected"].Enabled
        and not WinActive("Code") ; Electron Apps like VSCode don’t fully work with UIA
    ) {
        try {
            el := UIA.GetFocusedElement()
            if (el.IsTextPatternAvailable) {
                Selection := el.GetSelection()[1].GetText()
            }
        }
    }

    ; This regex is to not trigger the wrapping if there are only blank lines
    RegEx := "^(\r\n|\r|\n)+$"

    if Selection != "" and RegExMatch(Selection, RegEx) = 0 {
        ; Send all the text instantly and without triggering hotstrings while typing it
        SendInstant(LeftSymbol Selection RightSymbol)
    } else {
        SendNewResult(Symbol) ; SendEvent({Text}) doesn’t work everywhere, for example in Google Sheets
    }
    UpdateLastSentCharacter(Symbol)
}

; === Dead Keys ===

global InDeadKeySequence := false

DeadKey(Mapping) {
    global InDeadKeySequence
    InDeadKeySequence := true
    ; DeadKeyName := Mapping[" "]
    ih := InputHook(
        "L1",
        "{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Ins}{Numlock}{PrintScreen}{Pause}{Enter}{BackSpace}{Delete}"
    )
    ih.Start()
    ih.Wait()
    PressedKey := ih.Input
    InDeadKeySequence := false
    if Mapping.Has(PressedKey) {
        SendNewResult(Mapping[PressedKey])
    } else {
        SendNewResult(PressedKey)
    }
}

; TODO : if KbdEdit is upgraded, some "NEW" Unicode characters will become available
; This AutoHotkey script has all the characters, and the KbdEdit file has some missing ones
; For example, there is no 🄋 character yet in KbdEdit, but it is already available in this emulation

global DeadkeyMappingCircumflex := Map(
    " ", "^", "^", "^",
    "¨", "/", "_", "\",
    "'", "⚠",
    ",", "➜",
    ".", "•",
    "/", "⁄",
    "0", "🄋", ; NEW
    "1", "➀",
    "2", "➁",
    "3", "➂",
    "4", "➃",
    "5", "➄",
    "6", "➅",
    "7", "➆",
    "8", "➇",
    "9", "➈",
    ":", "▶",
    ";", "↪",
    "a", "â", "A", "Â",
    "b", "ó", "B", "Ó",
    "c", "ç", "C", "Ç",
    "d", "★", "D", "☆",
    "e", "ê", "E", "Ê",
    "f", "⚐", "F", "⚑",
    "g", "ĝ", "G", "Ĝ",
    "h", "ĥ", "H", "Ĥ",
    "i", "î", "I", "Î",
    "j", "j", "J", "J",
    "k", "☺", "K", "☻",
    "l", "†", "L", "‡",
    "m", "✅", "M", "☑",
    "n", "ñ", "N", "Ñ",
    "o", "ô", "O", "Ô",
    "p", "¶", "P", "⁂",
    "q", "☒", "Q", "☐",
    "r", "º", "R", "°",
    "s", "ß", "S", "ẞ",
    "t", "!", "T", "¡",
    "u", "û", "U", "Û",
    "v", "✓", "V", "✔",
    "w", "ù ", "W", "Ù",
    "x", "✕", "X", "✖",
    "y", "ŷ", "Y", "Ŷ",
    "z", "ẑ", "Z", "Ẑ",
    "à", "æ", "À", "Æ",
    "è", "í", "È", "Í",
    "é", "œ", "É", "Œ",
    "ê", "á", "Ê", "Á",
)

global DeadkeyMappingDiaresis := Map(
    " ", "¨", "¨", "¨",
    "0", "🄌", ; NEW
    "1", "➊",
    "2", "➋",
    "3", "➌",
    "4", "➍",
    "5", "➎",
    "6", "➏",
    "7", "➐",
    "8", "➑",
    "9", "➒",
    "a", "ä", "A", "Ä",
    "c", "©", "C", "©",
    "e", "ë", "E", "Ë",
    "h", "ḧ", "H", "Ḧ",
    "i", "ï", "I", "Ï",
    "n", " ", "N", " ",
    "o", "ö", "O", "Ö",
    "r", "®", "R", "®",
    "s", " ", "S", " ",
    "t", "™", "T", "™",
    "u", "ü", "U", "Ü",
    "w", "ẅ", "W", "Ẅ",
    "x", "ẍ", "X", "Ẍ",
    "y", "ÿ", "Y", "Ÿ",
)

global DeadkeyMappingSuperscript := Map(
    " ", "ᵉ",
    "(", "⁽", ")", "⁾",
    "+", "⁺",
    ",", "ᶿ",
    "-", "⁻",
    ".", "ᵝ",
    "/", "̸",
    "0", "⁰",
    "1", "¹",
    "2", "²",
    "3", "³",
    "4", "⁴",
    "5", "⁵",
    "6", "⁶",
    "7", "⁷",
    "8", "⁸",
    "9", "⁹",
    "=", "⁼",
    "a", "ᵃ", "A", "ᴬ",
    "b", "ᵇ", "B", "ᴮ",
    "c", "ᶜ", "C", "ꟲ",
    "d", "ᵈ", "D", "ᴰ",
    "e", "ᵉ", "E", "ᴱ",
    "f", "ᶠ", "F", "ꟳ",
    "g", "ᶢ", "G", "ᴳ",
    "h", "ʰ", "H", "ᴴ",
    "i", "ⁱ", "I", "ᴵ",
    "j", "ʲ", "J", "ᴶ",
    "k", "ᵏ", "K", "ᴷ",
    "l", "ˡ", "L", "ᴸ",
    "m", "ᵐ", "M", "ᴹ",
    "n", "ⁿ", "N", "ᴺ",
    "o", "ᵒ", "O", "ᴼ",
    "p", "ᵖ", "P", "ᴾ",
    "q", "𐞥", "Q", "ꟴ", ; 𐞥 is NEW
    "r", "ʳ", "R", "ᴿ",
    "s", "ˢ", "S", "", ; There is no superscript capital s yet in Unicode
    "t", "ᵗ", "T", "ᵀ",
    "u", "ᵘ", "U", "ᵁ",
    "v", "ᵛ", "V", "ⱽ",
    "w", "ʷ", "W", "ᵂ",
    "x", "ˣ", "X", "", ; There is no superscript capital x yet in Unicode
    "y", "ʸ", "Y", "", ; There is no superscript capital y yet in Unicode
    "z", "ᶻ", "Z", "", ; There is no superscript capital z yet in Unicode
    "[", "˹", "]", "˺",
    "à", "ᵡ", "À", "", ; There is no superscript capital ᵡ yet in Unicode
    "æ", "𐞃", "Æ", "ᴭ", ; 𐞃 is NEW
    "è", "ᵞ", "È", "", ; There is no superscript capital ᵞ yet in Unicode
    "é", "ᵟ", "É", "", ; There is no superscript capital ᵟ yet in Unicode
    "ê", "ᵠ", "Ê", "", ; There is no superscript capital ᵠ yet in Unicode
    "œ", "ꟹ", "Œ", "", ; There is no superscript capital œ yet in Unicode
)

global DeadkeyMappingSubscript := Map(
    " ", "ᵢ",
    "(", "₍", ")", "₎",
    "+", "₊", "-", "₋",
    "/", "̸",
    "0", "₀",
    "1", "₁",
    "2", "₂",
    "3", "₃",
    "4", "₄",
    "5", "₅",
    "6", "₆",
    "7", "₇",
    "8", "₈",
    "9", "₉",
    "=", "₌",
    "a", "ₐ", "A", "ᴀ",
    "b", "ᵦ", "B", "ʙ", ; ᵦ, not real subscript b
    "c", "", "C", "ᴄ", ; There is no subscript c yet in Unicode
    "d", "", "D", "ᴅ", ; There is no subscript d yet in Unicode
    "e", "ₑ", "E", "ᴇ", ; There is no subscript f yet in Unicode
    "f", "", "F", "ꜰ",
    "g", "ᵧ", "G", "ɢ", ; ᵧ, not real subscript g
    "h", "ₕ", "H", "ʜ",
    "i", "ᵢ", "I", "ɪ",
    "j", "ⱼ", "J", "ᴊ",
    "k", "ₖ", "K", "ᴋ",
    "l", "ₗ", "L", "ʟ",
    "m", "ₘ", "M", "ᴍ",
    "n", "ₙ", "N", "ɴ",
    "o", "ₒ", "O", "ᴏ",
    "p", "ᵨ", "P", "ₚ",
    "q", "", "Q", "ꞯ", ; There is no subscript q yet in Unicode
    "r", "ᵣ", "R", "ʀ",
    "s", "ₛ", "S", "ꜱ",
    "t", "ₜ", "T", "ᴛ",
    "u", "ᵤ", "U", "ᴜ",
    "v", "ᵥ", "V", "ᴠ",
    "w", "", "W", "ᴡ", ; There is no subscript w yet in Unicode
    "x", "ₓ", "X", "ᵪ", ; There is no subscript capital x yet in Unicode, we use subscript capital chi instead
    "y", "ᵧ", "Y", "ʏ", ; There is no subscript y yet in Unicode, we use subscript gamma instead
    "z", "", "Z", "ᴢ", ; There is no subscript z yet in Unicode
    "[", "˻", "]", "˼",
    "æ", "", "Æ", "ᴁ", ; There is no subscript æ yet in Unicode
    "è", "ᵧ", "Y", "", ; There is no subscript capital ᵧ yet in Unicode
    "ê", "ᵩ", "Ê", "", ; There is no subscript capital ᵩ yet in Unicode
    "œ", "", "Œ", "ɶ", ; There is no subscript œ yet in Unicode
)

global DeadkeyMappingGreek := Map(
    " ", "µ",
    "'", "ς",
    "-", "Μ",
    "_", "Ω", ; Attention, Ohm symbol and not capital Omega
    "a", "α", "A", "Α",
    "b", "β", "B", "Β",
    "c", "ψ", "C", "Ψ",
    "d", "δ", "D", "Δ",
    "e", "ε", "E", "Ε",
    "f", "φ", "F", "Φ",
    "g", "γ", "G", "Γ",
    "h", "η", "H", "Η",
    "i", "ι", "I", "Ι",
    "j", "ξ", "J", "Ξ",
    "k", "κ", "K", "Κ",
    "l", "λ", "L", "Λ",
    "m", "μ", "M", "Μ",
    "n", "ν", "N", "Ν",
    "o", "ο", "O", "Ο",
    "p", "π", "P", "Π",
    "q", "χ", "Q", "Χ",
    "r", "ρ", "R", "Ρ",
    "s", "σ", "S", "Σ",
    "t", "τ", "T", "Τ",
    "u", "θ", "U", "Θ",
    "v", "ν", "V", "Ν",
    "w", "ω", "W", "Ω",
    "x", "ξ", "X", "Ξ",
    "y", "υ", "Y", "Υ",
    "z", "ζ", "Z", "Ζ",
    "é", "η", "É", "Η",
    "ê", "ϕ", "Ê", "", ; Alternative phi character
)

global DeadkeyMappingR := Map(
    " ", "ℝ",
    "'", "ℜ",
    "(", "⟦", ")", "⟧",
    "[", "⟦", "]", "⟧",
    "<", "⟪", ">", "⟫",
    "«", "⟪", "»", "⟫",
    "b", "", "B", "ℬ",
    "c", "", "C", "ℂ",
    "e", "", "E", "⅀",
    "f", "", "F", "ℱ",
    "g", "ℊ", "G", "ℊ",
    "h", "", "H", "ℋ",
    "j", "", "J", "ℐ",
    "l", "ℓ", "L", "ℒ",
    "m", "", "M", "ℳ",
    "n", "", "N", "ℕ",
    "p", "", "P", "ℙ",
    "q", "", "Q", "ℚ",
    "r", "", "R", "ℝ",
    "s", "", "S", "⅀",
    "t", "", "T", "ℭ",
    "u", "", "U", "ℿ",
    "x", "", "X", "ℛ",
    "z", "", "Z", "ℨ",
)

global DeadkeyMappingCurrency := Map(
    " ", "¤",
    "$", "£",
    "&", "৳",
    "'", "£",
    "-", "£",
    "_", "€",
    "``", "₰",
    "a", "؋", "A", "₳",
    "b", "₿", "B", "฿",
    "c", "¢", "C", "₵",
    "d", "₫", "D", "₯",
    "e", "€", "E", "₠",
    "f", "ƒ", "F", "₣",
    "g", "₲", "G", "₲",
    "h", "₴", "H", "₴",
    "i", "﷼", "I", "៛",
    "k", "₭", "K", "₭",
    "l", "₺", "L", "₤",
    "m", "₥", "M", "ℳ",
    "n", "₦", "N", "₦",
    "o", "௹", "O", "૱",
    "p", "₱", "P", "₧",
    "r", "₽", "R", "₹",
    "s", "₪", "S", "₷",
    "t", "₸", "T", "₮",
    "u", "元", "U", "圓",
    "w", "₩", "W", "₩",
    "y", "¥", "Y", "円",
)

; =========================
; ======= 3.1) Base =======
; =========================

#HotIf Features["Layout"]["DirectAccessDigits"].Enabled
; We need to use SendEvent for symbols, otherwise it may trigger and lock AltGr. This issue happens on AZERTY at least.
; For digits, it is better to remap with sending the down event instead of using the RemapKey function.
; Otherwise, there is a problem of digit password boxes that skips to the n+2 box instead of n+2 because two down key events are sent by key
; One example is on the password box of https://github.com/login/device where they implemented an AutoShift in the boxes

; === Number row ===
SC029:: SendNewResult("$")
SC002:: SendEvent("{1 Down}") UpdateLastSentCharacter("1")
SC002 Up:: SendEvent("{1 Up}")
SC003:: SendEvent("{2 Down}") UpdateLastSentCharacter("2")
SC003 Up:: SendEvent("{2 Up}")
SC004:: SendEvent("{3 Down}") UpdateLastSentCharacter("3")
SC004 Up:: SendEvent("{3 Up}")
SC005:: SendEvent("{4 Down}") UpdateLastSentCharacter("4")
SC005 Up:: SendEvent("{4 Up}")
SC006:: SendEvent("{5 Down}") UpdateLastSentCharacter("5")
SC006 Up:: SendEvent("{5 Up}")
SC007:: SendEvent("{6 Down}") UpdateLastSentCharacter("6")
SC007 Up:: SendEvent("{6 Up}")
SC008:: SendEvent("{7 Down}") UpdateLastSentCharacter("7")
SC008 Up:: SendEvent("{7 Up}")
SC009:: SendEvent("{8 Down}") UpdateLastSentCharacter("8")
SC009 Up:: SendEvent("{8 Up}")
SC00A:: SendEvent("{9 Down}") UpdateLastSentCharacter("9")
SC00A Up:: SendEvent("{9 Up}")
SC00B:: SendEvent("{0 Down}") UpdateLastSentCharacter("0")
SC00B Up:: SendEvent("{0 Up}")
SC00C:: SendNewResult("%")
SC00D:: SendNewResult("=")
#HotIf

; Cannot be HotIf because the remapping is done with Hotkey function and cannot be undone afterwards
if Features["Layout"]["ErgoptiBase"].Enabled {
    RemapKey("SC039", " ")

    ; === Top row ===
    RemapKey("SC010", Features["Shortcuts"]["EGrave"].Letter, "è")
    RemapKey("SC011", "y")
    RemapKey("SC012", "o")
    RemapKey("SC013", "w")
    RemapKey("SC014", "b")
    RemapKey("SC015", "f")
    RemapKey("SC016", "g")
    RemapKey("SC017", "h")
    RemapKey("SC018", "c")
    RemapKey("SC019", "x")
    RemapKey("SC01A", "z")
    Hotkey(
        "SC01B",
        (*) => (InDeadKeySequence ? SendNewResult("¨") : DeadKey(DeadkeyMappingDiaresis)),
        "I2"
    )

    ; === Middle row ===
    RemapKey("SC01E", "a")
    RemapKey("SC01F", "i")
    RemapKey("SC020", "e")
    RemapKey("SC021", "u")
    RemapKey("SC022", ".")
    RemapKey("SC023", "v")
    RemapKey("SC024", "s")
    RemapKey("SC025", "n")
    RemapKey("SC026", "t")
    RemapKey("SC027", "r")
    RemapKey("SC028", "q")
    Hotkey(
        "SC02B",
        (*) => (InDeadKeySequence ? SendNewResult("^") : DeadKey(DeadkeyMappingCircumflex)),
        "I2"
    )

    ; === Bottom row ===
    RemapKey("SC056", Features["Shortcuts"]["ECirc"].Letter, "ê")
    RemapKey("SC02C", Features["Shortcuts"]["EAcute"].Letter, "é")
    RemapKey("SC02D", Features["Shortcuts"]["AGrave"].Letter, "à")
    RemapKey("SC02E", "j")
    RemapKey("SC02F", ",")
    RemapKey("SC030", "k")
    RemapKey("SC031", "m")
    RemapKey("SC032", "d")
    RemapKey("SC033", "l")
    RemapKey("SC034", "p")
    RemapKey("SC035", "'")
}

if Features["MagicKey"]["Replace"].Enabled {
    RemapKey("SC02E", "j", ScriptInformation["MagicKey"])
}

; ==========================
; ======= 3.2) Shift =======
; ==========================

#HotIf Features["Layout"]["ErgoptiBase"].Enabled
; === Space bar ===
+SC039:: WrapTextIfSelected("-", "-", "-")

; === Number row ===
+SC029:: {
    ActivateHotstrings()
    SendNewResult(" €") ; Thin non-breaking space
}
+SC002:: SendNewResult("1")
+SC003:: SendNewResult("2")
+SC004:: SendNewResult("3")
+SC005:: SendNewResult("3")
+SC006:: SendNewResult("5")
+SC007:: SendNewResult("6")
+SC008:: SendNewResult("7")
+SC009:: SendNewResult("8")
+SC00A:: SendNewResult("9")
+SC00B:: SendNewResult("0")
+SC00C:: {
    ActivateHotstrings()
    SendNewResult(" %") ; Thin non-breaking space
}
+SC00D:: SendNewResult("º")

; === Top row ===
+SC010:: SendNewResult("È")
+SC011:: SendNewResult("Y")
+SC012:: SendNewResult("O")
+SC013:: SendNewResult("W")
+SC014:: SendNewResult("B")
+SC015:: SendNewResult("F")
+SC016:: SendNewResult("G")
+SC017:: SendNewResult("H")
+SC018:: SendNewResult("C")
+SC019:: SendNewResult("X")
+SC01A:: SendNewResult("Z")
+SC01B:: SendNewResult("_")

; === Middle row ===
+SC01E:: SendNewResult("A")
+SC01F:: SendNewResult("I")
+SC020:: SendNewResult("E")
+SC021:: SendNewResult("U")
+SC022:: {
    ActivateHotstrings()
    SendNewResult(" :") ; Non-breaking space
}
+SC023:: SendNewResult("V")
+SC024:: SendNewResult("S")
+SC025:: SendNewResult("N")
+SC026:: SendNewResult("T")
+SC027:: SendNewResult("R")
+SC028:: SendNewResult("Q")
+SC02B:: {
    ActivateHotstrings()
    SendNewResult(" !") ; Thin non-breaking space
}

; === Bottom row ===
+SC056:: SendNewResult("Ê")
+SC02C:: SendNewResult("É")
+SC02D:: SendNewResult("À")
+SC02E:: SendNewResult("J")
+SC02F:: {
    ActivateHotstrings()
    SendNewResult(" ;") ; Thin non-breaking space
}
+SC030:: SendNewResult("K")
+SC031:: SendNewResult("M")
+SC032:: SendNewResult("D")
+SC033:: SendNewResult("L")
+SC034:: SendNewResult("P")
+SC035:: {
    ActivateHotstrings()
    SendNewResult(" ?") ; Thin non-breaking space
}
#HotIf

; =============================
; ======= 3.3) CapsLock =======
; =============================

GetCapsLockCondition() {
    return GetKeyState("CapsLock", "T") and not LayerEnabled
}

#HotIf GetCapsLockCondition() and Features["MagicKey"]["Replace"].Enabled
SC02E:: SendNewResult(ScriptInformation["MagicKey"])
#HotIf

#HotIf GetCapsLockCondition() and Features["Layout"]["ErgoptiBase"].Enabled
; === Number row ===
SC029:: SendNewResult("$")
SC002:: SendNewResult("1")
SC003:: SendNewResult("2")
SC004:: SendNewResult("3")
SC005:: SendNewResult("3")
SC006:: SendNewResult("5")
SC007:: SendNewResult("6")
SC008:: SendNewResult("7")
SC009:: SendNewResult("8")
SC00A:: SendNewResult("9")
SC00B:: SendNewResult("0")
SC00C:: SendNewResult("%")
SC00D:: SendNewResult("=")

; === Top row ===
SC010:: SendNewResult("È")
SC011:: SendNewResult("Y")
SC012:: SendNewResult("O")
SC013:: SendNewResult("W")
SC014:: SendNewResult("B")
SC015:: SendNewResult("F")
SC016:: SendNewResult("G")
SC017:: SendNewResult("H")
SC018:: SendNewResult("C")
SC019:: SendNewResult("X")
SC01A:: SendNewResult("Z")
SC01B:: (InDeadKeySequence ? SendNewResult("¨") : DeadKey(DeadkeyMappingDiaresis))

; === Middle row ===
SC01E:: SendNewResult("A")
SC01F:: SendNewResult("I")
SC020:: SendNewResult("E")
SC021:: SendNewResult("U")
SC022:: SendNewResult(".")
SC023:: SendNewResult("V")
SC024:: SendNewResult("S")
SC025:: SendNewResult("N")
SC026:: SendNewResult("T")
SC027:: SendNewResult("R")
SC028:: SendNewResult("Q")
SC02B:: (InDeadKeySequence ? SendNewResult("^") : DeadKey(DeadkeyMappingCircumflex))

; === Bottom row ===
SC056:: SendNewResult("Ê")
SC02C:: SendNewResult("É")
SC02D:: SendNewResult("À")
SC02E:: SendNewResult("J")
SC02F:: SendNewResult(",")
SC030:: SendNewResult("K")
SC031:: SendNewResult("M")
SC032:: SendNewResult("D")
SC033:: SendNewResult("L")
SC034:: SendNewResult("P")
SC035:: SendNewResult("'")
#HotIf

; =========================================
; ======= 3.4) AltGr and ShiftAltGr =======
; =========================================

; This code comes before remapping ErgoptiAltGr to be able to override the keys
#HotIf Features["Rolls"]["ChevronEqual"].Enabled
SC138 & SC012:: {
    if GetKeyState("Shift", "P") {
        Features["Layout"]["ErgoptiPlus"].Enabled ? SendNewResult(" %") : SendNewResult("Œ")
    } else {
        AddRollEqual()
    }
}
AddRollEqual() {
    LastSentCharacter := GetLastSentCharacterAt(-1)
    if (
        LastSentCharacter == "<" or LastSentCharacter == ">")
    and A_TimeSincePriorHotkey < (Features["Rolls"]["ChevronEqual"].TimeActivationSeconds * 1000
    ) {
        SendNewResult("=")
        UpdateLastSentCharacter("=")
    } else if Features["Layout"]["ErgoptiPlus"].Enabled {
        WrapTextIfSelected("%", "%", "%")
    } else {
        SendNewResult("œ")
    }
}
#HotIf

#HotIf Features["Rolls"]["HashtagQuote"].Enabled
SC138 & SC017:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("%")
    } else {
        HashtagOrQuote()
    }
}
HashtagOrQuote() {
    LastSentCharacter := GetLastSentCharacterAt(-1)
    if (
        LastSentCharacter == "(" or LastSentCharacter == "[")
    and A_TimeSincePriorHotkey < (Features["Rolls"]["HashtagQuote"].TimeActivationSeconds * 1000
    ) {
        SendNewResult("`"")
        UpdateLastSentCharacter("`"")
    } else {
        WrapTextIfSelected("#", "#", "#")
    }
}
#HotIf

; AltGr changes made in ErgoptiPlus
#HotIf Features["Layout"]["ErgoptiPlus"].Enabled
SC138 & SC012:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("Œ")
    } else {
        WrapTextIfSelected("%", "%", "%")
    }
}
SC138 & SC013:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("Où" . SpaceAroundSymbols)
    } else {
        SendNewResult("où" . SpaceAroundSymbols)
    }
}
SC138 & SC018:: {
    if GetKeyState("Shift", "P") {
        SendNewResult(" !")
    } else {
        WrapTextIfSelected("!", "!", "!")
    }
}
#HotIf

#HotIf Features["Layout"]["ErgoptiAltGr"].Enabled and Features["Layout"]["ErgoptiBase"].Enabled
; === Number row ===
SC138 & SC029:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingCurrency)
    } else {
        SendNewResult("€")
    }
}
SC138 & SC002:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₁")
    } else {
        SendNewResult("¹")
    }
}
SC138 & SC003:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₂")
    } else {
        SendNewResult("²")
    }
}
SC138 & SC004:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₃")
    } else {
        SendNewResult("³")
    }
}
SC138 & SC005:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₄")
    } else {
        SendNewResult("⁴")
    }
}
SC138 & SC006:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₅")
    } else {
        SendNewResult("⁵")
    }
}
SC138 & SC007:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₆")
    } else {
        SendNewResult("⁶")
    }
}
SC138 & SC008:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₇")
    } else {
        SendNewResult("⁷")
    }
}
SC138 & SC009:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₈")
    } else {
        SendNewResult("⁸")
    }
}
SC138 & SC00A:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₉")
    } else {
        SendNewResult("⁹")
    }
}
SC138 & SC00B:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("₀")
    } else {
        SendNewResult("⁰")
    }
}
SC138 & SC00C:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("‱")
    } else {
        SendNewResult("‰")
    }
}
SC138 & SC00D:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("ª")
    } else {
        SendNewResult("°")
    }
}

; ======= Ctrl + Alt is different from AltGr on the Number row =======
; Some programs use these shortcuts, like in Google Docs where it changes the heading
^!SC002:: SendFinalResult("^!{Numpad1}")
^!SC003:: SendFinalResult("^!{Numpad2}")
^!SC004:: SendFinalResult("^!{Numpad3}")
^!SC005:: SendFinalResult("^!{Numpad4}")
^!SC006:: SendFinalResult("^!{Numpad5}")
^!SC007:: SendFinalResult("^!{Numpad6}")
^!SC008:: SendFinalResult("^!{Numpad7}")
^!SC009:: SendFinalResult("^!{Numpad8}")
^!SC00A:: SendFinalResult("^!{Numpad9}")
^!SC00B:: SendFinalResult("^!{Numpad0}")
#HotIf

#HotIf Features["Layout"]["ErgoptiAltGr"].Enabled
; === Space bar ===
SC138 & SC039:: {
    if GetKeyState("Shift", "P") {

    } else {
        WrapTextIfSelected("_", "_", "_")
    }
}
SC138 & SC010:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("„")
    } else {
        WrapTextIfSelected("``", "``", "``")
    }
}
SC138 & SC011:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("€")
    } else {
        WrapTextIfSelected("@", "@", "@")
    }
}
SC138 & SC012:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("Œ")
    } else {
        SendNewResult("œ")
    }
}
SC138 & SC013:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("Ù")
    } else {
        SendNewResult("ù")
    }
}
SC138 & SC014:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("“")
    } else {
        WrapTextIfSelected("« ", "« ", " »")
    }
}
SC138 & SC015:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("”")
    } else {
        WrapTextIfSelected(" »", "« ", " »")
    }
}
SC138 & SC016:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("≈")
    } else {
        WrapTextIfSelected("~", "~", "~")
    }
}
SC138 & SC017:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("%")
    } else {
        WrapTextIfSelected("#", "#", "#")
    }
}
SC138 & SC018:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("Ç")
    } else {
        SendNewResult("ç")
    }
}
SC138 & SC019:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("×")
    } else {
        WrapTextIfSelected("*", "*", "*")
    }
}
SC138 & SC01A:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("‰")
    } else {
        WrapTextIfSelected("%", "%", "%")
    }
}
SC138 & SC01B:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("★")
    } else {
        SendNewResult("-")
    }
}

; === Middle row ===
SC138 & SC01E:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("≤")
    } else {
        WrapTextIfSelected("<", "<", ">")
    }
}
SC138 & SC01F:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("≥")
    } else {
        WrapTextIfSelected(">", "<", ">")
    }
}
SC138 & SC020:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingSuperscript)
    } else {
        WrapTextIfSelected("{", "{", "}")
    }
}
SC138 & SC021:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingGreek)
    } else {
        WrapTextIfSelected("}", "{", "}")
    }
}
SC138 & SC022:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("·")
    } else {
        WrapTextIfSelected(":", ":", ":")
    }
}
SC138 & SC023:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("¦")
    } else {
        WrapTextIfSelected("|", "|", "|")
    }
}
SC138 & SC024:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("—")
    } else {
        WrapTextIfSelected("(", "(", ")")
    }
}
SC138 & SC025:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("–")
    } else {
        WrapTextIfSelected(")", "(", ")")
    }
}
SC138 & SC026:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingDiaresis)
    } else {
        WrapTextIfSelected("[", "[", "]")
    }
}
SC138 & SC027:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingR)
    } else {
        WrapTextIfSelected("]", "[", "]")
    }
}
SC138 & SC028:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingCurrency)
    } else {
        SendNewResult("’")
    }
}
SC138 & SC02B:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("¡")
    } else {
        WrapTextIfSelected("!", "!", "!")
    }
}

; === Bottom row ===
SC138 & SC056:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingCircumflex)
    } else {
        WrapTextIfSelected("^", "^", "^")
    }
}
SC138 & SC02C:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("÷")
    } else {
        WrapTextIfSelected("/", "/", "/")
    }
}
SC138 & SC02D:: {
    if GetKeyState("Shift", "P") {
        DeadKey(DeadkeyMappingSubscript)
    } else {
        WrapTextIfSelected("\", "\", "\")
    }
}
SC138 & SC02E:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("j")
    } else {
        WrapTextIfSelected("`"", "`"", "`"")
    }
}
SC138 & SC02F:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("…")
    } else {
        WrapTextIfSelected(";", ";", ";")
    }
}
SC138 & SC030:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("+")
    } else {
        SendNewResult("…")
    }
}
SC138 & SC031:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("−")
    } else {
        WrapTextIfSelected("&", "&", "&")
    }
}
SC138 & SC032:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("§")
    } else {
        WrapTextIfSelected("$", "$", "$")
    }
}
SC138 & SC033:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("≠")
    } else {
        WrapTextIfSelected("=", "=", "=")
    }
}
SC138 & SC034:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("±")
    } else {
        WrapTextIfSelected("+", "+", "+")
    }
}
SC138 & SC035:: {
    if GetKeyState("Shift", "P") {
        SendNewResult("¿")
    } else {
        WrapTextIfSelected("?", "?", "?")
    }
}
#HotIf

; ============================
; ======= 3.5) Control =======
; ============================

#HotIf Features["Layout"]["ErgoptiBase"].Enabled
^SC02F:: SendFinalResult("^v") ; Correct issue where Win + V paste doesn't work
*^SC00C:: SendFinalResult("^{NumpadSub}") ; Zoom out with Ctrl + %
*^SC00D:: SendFinalResult("^{NumpadAdd}") ; Zoom in with Ctrl + $
#HotIf

; In Microsoft apps like Word or Excel, we can’t use Numpad + to zoom
#HotIf Features["Layout"]["ErgoptiBase"].Enabled and MicrosoftApps()
*^SC00C:: SendFinalResult("^{WheelDown}") ; Zoom out with (Shift +) Ctrl + %
*^SC00D:: SendFinalResult("^{WheelUp}") ; Zoom in with (Shift +) Ctrl + $
#HotIf

; ==============================================
; ==============================================
; ==============================================
; ================ 4/ SHORTCUTS ================
; ==============================================
; ==============================================
; ==============================================

; This function below makes it possible to create a shortcut that works
; no matter the keyboard layout or the potential emulation of the Ergopti layout on top of it
; If the keyboard layout changes, the script must be reloaded
AddShortcut(Modifier, Letter, BehaviorFunction) {
    Scancode := RetrieveScancode(Letter)
    Key := Modifier Scancode
    Hotkey(Key, BehaviorFunction.Call())
}

RetrieveScancode(Letter) {
    if RemappedList.Has(Letter) {
        Scancode := RemappedList[Letter]
    } else {
        Scancode := Format("sc{:x}", GetKeySC(Letter))
    }
    return Scancode
}

; ==========================
; ======= 4.1) Base =======
; ==========================

#HotIf (
    ; We need to handle the shortcut differently when LAlt has been remapped
    not Features["TapHolds"]["LAlt"]["BackSpace"].Enabled ; No need to add the shortcut here, as it is impossible to have this shortcut with a BackSpace key that fires immediately
    and not Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled ; Here we directly change the result on the layer
    and not Features["TapHolds"]["LAlt"]["TabLayer"].Enabled ; Here we directly change the result on the layer
    and not Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled ; Necessary to be able to use OneShotShift on LAlt
)
SC038 & SC03A:: LAltCapsLockShortcut()
#HotIf

LAltCapsLockShortcut() {
    if Features["Shortcuts"]["LAltCapsLock"]["BackSpace"].Enabled {
        SendEvent("{BackSpace}")
    } else if Features["Shortcuts"]["LAltCapsLock"]["CapsLock"].Enabled {
        ToggleCapsLock()
    } else if Features["Shortcuts"]["LAltCapsLock"]["CapsWord"].Enabled {
        ToggleCapsWord()
    } else if Features["Shortcuts"]["LAltCapsLock"]["CtrlBackSpace"].Enabled {
        SendInput("^{BackSpace}")
    } else if Features["Shortcuts"]["LAltCapsLock"]["CtrlDelete"].Enabled {
        SendInput("^{Delete}")
    } else if Features["Shortcuts"]["LAltCapsLock"]["Delete"].Enabled {
        SendInput("{Delete}")
    } else if Features["Shortcuts"]["LAltCapsLock"]["Enter"].Enabled {
        SendInput("{Enter}")
    } else if Features["Shortcuts"]["LAltCapsLock"]["Escape"].Enabled {
        SendInput("{Escape}")
    } else if Features["Shortcuts"]["LAltCapsLock"]["OneShotShift"].Enabled {
        OneShotShift()
    } else if Features["Shortcuts"]["LAltCapsLock"]["Tab"].Enabled {
        SendInput("{Tab}")
    }
}

; ==========================
; ======= 4.2) Shift =======
; ==========================

; ============================
; ======= 4.3) Control =======
; ============================

if Features["Shortcuts"]["Save"].Enabled {
    AddShortcut("^", "j", (*) => (*) => SendFinalResult("^s"))
}
if Features["Shortcuts"]["CtrlJ"].Enabled {
    AddShortcut("^", "s", (*) => (*) => SendFinalResult("^j"))
}

if Features["Shortcuts"]["MicrosoftBold"].Enabled {
    ; Makes it possible to use the standard shortcuts instead of their translation in Microsoft apps
    AddShortcut(
        "^", "b",
        (*) => (*) => MicrosoftApps() ? SendFinalResult("^g") : SendFinalResult("^b")
    )
}

; ========================
; ======= 4.4) Alt =======
; ========================

; Attention to the Windows shortcut Alt + LShift that changes the keyboard layout

; ==========================
; ======= 4.5) AltGr =======
; ==========================

#HotIf (
    Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["CapsLock"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["CapsWord"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["CtrlBackSpace"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["CtrlDelete"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["Delete"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["Enter"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["Escape"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["OneShotShift"].Enabled
    or Features["Shortcuts"]["AltGrLAlt"]["Tab"].Enabled
)
SC138 & SC038:: AltGrLAltShortcut()
#HotIf

AltGrLAltShortcut() {
    if Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = Ctrl + BackSpace (Can’t use Ctrl because of AltGr = Ctrl + Alt)
            SendInput("^{BackSpace}")
        } else {
            SendInput("{BackSpace}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["CapsLock"].Enabled {
        ToggleCapsLock()
    } else if Features["Shortcuts"]["AltGrLAlt"]["CapsWord"].Enabled {
        ToggleCapsWord()
    } else if Features["Shortcuts"]["AltGrLAlt"]["CtrlBackSpace"].Enabled {
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            ; "Shift" + "AltGr" + "LAlt" = BackSpace (Can’t use Ctrl because of AltGr = Ctrl + Alt)
            SendInput("{BackSpace}")
        } else {
            SendInput("^{BackSpace}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["CtrlDelete"].Enabled {
        ; "Shift" + "AltGr" + "LAlt" = Delete (Can’t use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            SendInput("{Delete}")
        } else {
            SendInput("^{Delete}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["Delete"].Enabled {
        ; "Shift" + "AltGr" + "LAlt" = Ctrl + Delete (Can’t use Ctrl because of AltGr = Ctrl + Alt)
        OneShotShiftFix()
        if GetKeyState("Shift", "P") {
            SendInput("^{Delete}")
        } else {
            SendInput("{Delete}")
        }
    } else if Features["Shortcuts"]["AltGrLAlt"]["Enter"].Enabled {
        SendInput("{Enter}")
    } else if Features["Shortcuts"]["AltGrLAlt"]["Escape"].Enabled {
        SendInput("{Escape}")
    } else if Features["Shortcuts"]["AltGrLAlt"]["OneShotShift"].Enabled {
        OneShotShift()
    } else if Features["Shortcuts"]["AltGrLAlt"]["Tab"].Enabled {
        SendInput("{Tab}")
    }
}

#HotIf (
    Features["Shortcuts"]["AltGrCapsLock"]["BackSpace"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["CapsLock"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["CapsWord"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["CtrlBackSpace"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["CtrlDelete"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["Delete"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["Enter"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["Escape"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["OneShotShift"].Enabled
    or Features["Shortcuts"]["AltGrCapsLock"]["Tab"].Enabled
)
SC138 & SC03A:: AltGrCapsLockShortcut()
#HotIf

AltGrCapsLockShortcut() {
    if Features["Shortcuts"]["AltGrCapsLock"]["BackSpace"].Enabled {
        SendEvent("{BackSpace}")
    } else if Features["Shortcuts"]["AltGrCapsLock"]["CapsLock"].Enabled {
        ToggleCapsLock()
    } else if Features["Shortcuts"]["AltGrCapsLock"]["CapsWord"].Enabled {
        ToggleCapsWord()
    } else if Features["Shortcuts"]["AltGrCapsLock"]["CtrlBackSpace"].Enabled {
        SendInput("^{BackSpace}")
    } else if Features["Shortcuts"]["AltGrCapsLock"]["CtrlDelete"].Enabled {
        SendInput("^{Delete}")
    } else if Features["Shortcuts"]["AltGrCapsLock"]["Delete"].Enabled {
        SendInput("{Delete}")
    } else if Features["Shortcuts"]["AltGrCapsLock"]["Enter"].Enabled {
        SendInput("{Enter}")
    } else if Features["Shortcuts"]["AltGrCapsLock"]["Escape"].Enabled {
        SendInput("{Escape}")
    } else if Features["Shortcuts"]["AltGrCapsLock"]["OneShotShift"].Enabled {
        OneShotShift()
    } else if Features["Shortcuts"]["AltGrCapsLock"]["Tab"].Enabled {
        SendInput("{Tab}")
    }
}

; ============================
; ======= 4.6) Windows =======
; ============================

#HotIf Features["Shortcuts"]["WinCapsLock"].Enabled
; Win + "CapsLock" to toggle CapsLock
#SC03A:: ToggleCapsLock()
#HotIf

if Features["Shortcuts"]["SelectLine"].Enabled {
    ; Win + A (All)
    AddShortcut("#", "a", (*) => SelectLine)

    SelectLine(*) {
        SendFinalResult("{Home}{Shift Down}{End}{Shift Up}")
    }
}

if Features["Shortcuts"]["Screen"].Enabled {
    ; Win + H (ScreensHot)
    AddShortcut("#", "h", (*) => (*) => SendFinalResult("#+s"))
}

if Features["Shortcuts"]["GPT"].Enabled {
    ; Win + G (GPT)
    AddShortcut("#", "g", (*) => (*) => Run(Features["Shortcuts"]["GPT"].Link))
}

if Features["Shortcuts"]["GetHexValue"].Enabled {
    ; Win + X (heX)
    AddShortcut("#", "x", (*) => GetHexValue)

    GetHexValue(*) {
        MouseGetPos(&MouseX, &MouseY)
        HexColor := PixelGetColor(MouseX, MouseY, "RGB")
        HexColor := "#" StrLower(SubStr(HexColor, 3))
        A_Clipboard := HexColor
        Msgbox("La couleur sous le curseur est " HexColor "`nElle a été sauvegardée dans le presse-papiers : " A_Clipboard
        )
    }
}

if Features["Shortcuts"]["TakeNote"].Enabled {
    ; Win + N (Note)
    AddShortcut("#", "n", (*) => TakeNote)

    TakeNote(*) {
        ; Determine the file name (with or without date)
        if (Features["Shortcuts"]["TakeNote"].DatedNotes) {
            Date := FormatTime(, "dd_MM_yyyy")
            FileName := "Notes_" Date ".txt"
        } else {
            FileName := "Notes.txt"
        }

        ; Build the full file path
        FilePath := Features["Shortcuts"]["TakeNote"].DestinationFolder "\" FileName

        ; Create the file if it doesn’t exist yet
        if not FileExist(FilePath) {
            FileAppend("", FilePath)
        }

        ; Match the window title containing the file name
        SetTitleMatchMode(2) ; Partial match
        WinPattern := FileName

        WindowAlreadyOpen := False
        if WinExist(WinPattern) {
            WindowAlreadyOpen := True
            WinActivate(WinPattern)
            WinWaitActive(WinPattern, , 3)
        } else {
            Run("notepad " . FilePath)
            WinWait(FileName, , 7)
            WinActivate(FileName)
            WinWaitActive(FileName, , 3)
        }

        WinMaximize
        Sleep(100)
        if not WindowAlreadyOpen {
            SendFinalResult("^{End}{Enter}") ; Jump to the end of the file and start a new line
        }
    }
}

if Features["Shortcuts"]["Move"].Enabled {
    ; Win + M (Move)
    AddShortcut("#", "m", (*) => (*) => ToggleActivitySimulation() SetTimer(SimulateActivity, Random(1000, 5000)))

    ToggleActivitySimulation(*) {
        global ActivitySimulation := not ActivitySimulation
    }
    SimulateActivity() {
        if ActivitySimulation {
            MouseMoveCount := Random(3, 8) ; Randomly select the number of mouse moves
            loop MouseMoveCount {
                MouseX := Random(0, A_ScreenWidth)
                MouseY := Random(0, A_ScreenHeight)
                DllCall("SetCursorPos", "int", MouseX, "int", MouseY)
                Sleep(Random(200, 800)) ; Wait for a short duration
            }
            SendFinalResult("{VKFF}") ; Send the void keypress. Otherwise, despite the mouse moving, it can be seen as inactivity
        }
    }
}

if Features["Shortcuts"]["SurroundWithParentheses"].Enabled {
    AddShortcut("#", "o", (*) => (*) => SendFinalResult("{Home}({End}){Home}"))
}

if Features["Shortcuts"]["Search"].Enabled {
    ; Win + S (Search)
    AddShortcut("#", "s", (*) => Search)

    Search(*) {
        SelectedText := Trim(GetSelection())
        if WinActive("ahk_exe explorer.exe") {
            GetPath(SelectedText)
        } else {
            SearchPath(SelectedText)
        }
    }

    SearchPath(SelectedText) {
        ; The result of each of those regexes is a boolean

        ; Detects Windows file paths like C:/ or D:\ (supports forward and backward slashes)
        ; Invalid Windows path characters are excluded: <>:"|?*
        FilePath := RegExMatch(
            SelectedText,
            "^[A-Za-z]:[\\/](?:[^<>:`"|?*\r\n]+[\\/]?)*$"
        )

        ; Detects Windows Registry paths (optional Computer\ or Ordinateur\ prefix)
        ; Matches both full names (HKEY_CLASSES_ROOT...) and abbreviations (HKCR, HKCU, etc.)
        RegeditPath := RegExMatch(
            SelectedText,
            "i)^(?:Computer\\|Ordinateur\\)?(?:HKEY_(?:CLASSES_ROOT|CURRENT_USER|LOCAL_MACHINE|USERS|CURRENT_CONFIG)|HK(?:CR|CU|LM|U|CC))(?:\\[^\r\n]*)?$"
        )

        ; Detects full URLs with protocol (http, https, ftp, file, etc.)
        ; Protocol must start with a letter and be 2–9 characters long
        URLPath := RegExMatch(
            SelectedText,
            "i)^[a-z][a-z0-9+\-.]{1,8}://[^\s]+$"
        )

        ; Detects domain names (supports up to 4 subdomain levels, TLD up to 63 chars)
        ; Optionally followed by a path (no spaces allowed)
        WebsitePath := RegExMatch(
            SelectedText,
            "i)^(?:[\w-]{1,63}\.){1,4}[a-z]{2,63}(?:/[^\s]*)?$"
        )

        if FilePath {
            Run(SelectedText, , "Max")
        } else if RegeditPath {
            RegJump(SelectedText)
        } else {
            ; Modify some characters that screw up the URL
            SelectedText := StrReplace(SelectedText, "`r`n", " ")
            SelectedText := StrReplace(SelectedText, "#", "%23")
            SelectedText := StrReplace(SelectedText, "&", "%26")
            SelectedText := StrReplace(SelectedText, "+", "%2b")
            SelectedText := StrReplace(SelectedText, "`"", "%22")

            if URLPath {
                Run(SelectedText)
            } else if (WebsitePath) {
                Run("https://" . SelectedText)
            } else if (SelectedText == "") { ; If nothing was copied
                Run(Features["Shortcuts"]["Search"].SearchEngine)
            } else {
                Run(Features["Shortcuts"]["Search"].SearchEngineURLQuery . SelectedText)
            }
        }
    }

    ; Open Regedit and navigate to RegPath.
    ; RegPath accepts both HKEY_LOCAL_MACHINE and HKLM formats.
    RegJump(RegPath) {
        ; Close existing Registry Editor to ensure target key is selected next time
        if WinExist("Registry Editor") {
            WinKill("Registry Editor")
        }

        ; Normalize leading Computer\ prefix to French "Ordinateur\"
        if SubStr(RegPath, 1, 9) == "Computer\" {
            RegPath := "Ordinateur\" . SubStr(RegPath, 10)
        }

        ; Remove trailing backslash if present
        RegPath := Trim(RegPath, "\")

        ; Extract root key (first component of path)
        RootKey := StrSplit(RegPath, "\")[1]

        ; Convert short root key forms to long forms if necessary
        if !InStr(RootKey, "HKEY_") {
            KeyMap := Map(
                "HKCR", "HKEY_CLASSES_ROOT",
                "HKCU", "HKEY_CURRENT_USER",
                "HKLM", "HKEY_LOCAL_MACHINE",
                "HKU", "HKEY_USERS",
                "HKCC", "HKEY_CURRENT_CONFIG"
            )
            if KeyMap.HasKey(RootKey) {
                RegPath := StrReplace(RegPath, RootKey, KeyMap[RootKey], , , 1)
            }
        }

        ; Set the last selected key in Regedit. When we will run Regedit, it will open directly to the target
        RegWrite(RegPath, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit", "LastKey")
        Run("Regedit.exe")
    }

    GetPath(Path) {
        PathWithBackslash := Path
        PathWithSlash := StrReplace(Path, "\", "/")
        A_Clipboard := PathWithSlash

        SetTimer ChangeButtonNames, 50
        Result := MsgBox("Le chemin`n" A_Clipboard "`na été copié dans le presse-papier. `n`nVoulez-vous la version avec des \ à la place des / ?",
            "Copie du chemin d’accès", "YesNo")
        if (Result == "No") {
            A_Clipboard := PathWithBackslash
            Sleep(200)
            MsgBox("Le chemin`n" A_Clipboard "`na été copié dans le presse-papier.")
        }
    }
    ChangeButtonNames() {
        if not WinExist("Copie du chemin d’accès")
            return ; Keep waiting
        SetTimer ChangeButtonNames, 0
        WinActivate()
        ControlSetText("&Quitter", "Button1")
        ControlSetText("&Backslash (\)", "Button2")
    }
}

if Features["Shortcuts"]["TitleCase"].Enabled {
    ; Win + T (TitleCase)
    AddShortcut("#", "t", (*) => ConvertToTitleCase)

    ConvertToTitleCase(*) {
        Text := GetSelection()

        ; Pattern to detect if text is already in title case:
        ; Each word starts with an uppercase letter (including accented),
        ; followed by lowercase letters (including accented) or digits or allowed symbols.
        ; Words are separated by spaces, tabs or returns ([ \t\r\n]).
        TitleCasePattern :=
            "^(?:[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9'’\(\),.\-:;!?\-]*[ \t\r\n]+)*[A-ZÉÈÀÙÂÊÎÔÛÇ][a-zéèàùâêîôûç0-9'’\(\),.\-:;!?\-]*$"
        ; Pattern to detect if text is all uppercase (including accented), digits, spaces, and allowed symbols
        UpperCasePattern := "^[A-ZÉÈÀÙÂÊÎÔÛÇ0-9'’\(\),.\-:;!?\s]+$"

        if RegExMatch(Text, TitleCasePattern) {
            ; Text is Title Case ➜ convert to lowercase
            SendInstant(Format("{:L}", Text))
        } else if RegExMatch(Text, UpperCasePattern) {
            ; Text is UPPERCASE ➜ convert to TitleCase
            SendInstant(Format("{:T}", Text))
        } else {
            ; Otherwise, convert to TitleCase
            SendInstant(Format("{:T}", Text))
        }
    }
}

if Features["Shortcuts"]["Uppercase"].Enabled {
    ; Win + U (Uppercase)
    AddShortcut("#", "u", (*) => ConvertToUppercase)

    ConvertToUppercase(*) {
        Text := GetSelection()
        ; Check if the selected text contains at least one lowercase letter
        if RegExMatch(Text, "[a-zà-ÿ]") {
            SendInstant(Format("{:U}", Text)) ; Convert to uppercase
        } else {
            SendInstant(Format("{:L}", Text)) ; Convert to lowercase
        }
    }
}

if Features["Shortcuts"]["SelectWord"].Enabled {
    ; Win + W (Word)
    AddShortcut("#", "w", (*) => SelectWord)

    SelectWord(*) {
        SendFinalResult("^{Left}")
        SendFinalResult("{LShift Down}^{Right}{LShift Up}")

        SelectedWord := GetSelection()
        if (SubStr(SelectedWord, -1, 1) == " ") {
            ; If the selected word finishes with a space, we remove it from the selection
            SendFinalResult("{LShift Down}{Left}{LShift Up}")
        }
    }
}

; ===========================
; ======= 4.7) Others =======
; ===========================

; ========================
; ======= CapsWord =======
; ========================

; (cf. https://github.com/qmk/qmk_firmware/blob/master/users/drashna/keyrecords/capwords.md)

ToggleCapsWord() {
    global CapsWordEnabled := not CapsWordEnabled
    UpdateCapsLockLED()
}

DisableCapsWord() {
    global CapsWordEnabled := False
    UpdateCapsLockLED()
}

UpdateCapsLockLED() {
    if CapsWordEnabled or LayerEnabled {
        SetCapsLockState("On")
    } else {
        SetCapsLockState("Off")
    }
}

; Defines what deactivates the CapsLock triggered by CapsWord
#HotIf CapsWordEnabled
SC039::
{
    SendEvent("{Space}")
    Keywait("SC039") ; Solves bug of 2 sent Spaces when exiting CapsWord with a Space
    DisableCapsWord()
}

; Big Enter key
SC01C::
{
    SendEvent("{Enter}")
    DisableCapsWord()
}

; Mouse click
~LButton::
~RButton::
{
    global drag_enabled := 0
    DisableCapsWord()
}
#HotIf

; ===================================================================================
; ===================================================================================
; ===================================================================================
; ================ 5/ TAP-HOLDS, ONE-SHOT SHIFT AND NAVIGATION LAYER ================
; ===================================================================================
; ===================================================================================
; ===================================================================================

; =============================
; ======= 5.1) CapsLock =======
; =============================

; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock not remapped
#HotIf (
    Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled
    and not Features["TapHolds"]["CapsLock"]["BackSpace"]
    and not CapsLockRemappedCondition()
    and not LayerEnabled
)
SC03A:: {
    if (GetKeyState("SC038", "P")) {
        LAltCapsLockShortcut()
        return
    }
    ToggleCapsLock()
}
#HotIf

#HotIf Features["TapHolds"]["CapsLock"]["BackSpace"].Enabled and not LayerEnabled
*SC03A:: {
    if (GetKeyState("SC038", "P")) {
        LAltCapsLockShortcut()
        return
    }

    SendEvent("{Blind}{BackSpace}")
}
#HotIf

CapsLockRemappedCondition() {
    return (
        Features["TapHolds"]["CapsLock"]["BackSpaceCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["CapsLockCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["CapsWordCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["CtrlBackSpaceCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["CtrlDeleteCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["DeleteCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["EscapeCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["OneShotShiftCtrl"].Enabled
        or Features["TapHolds"]["CapsLock"]["TabCtrl"].Enabled
    )
}

#HotIf CapsLockRemappedCondition() and not LayerEnabled
*SC03A:: {
    CtrlActivated := False
    if (GetKeyState("SC01D", "P")) {
        CtrlActivated := True
    }

    if (GetKeyState("SC038", "P")) {
        ; Fix for using the LAltCapsLockShortcut with LAlt remapped to OneShotShift and CapsLock remapped
        LAltCapsLockShortcut()
        return
    }

    SendEvent("{LCtrl Down}")
    tap := KeyWait("CapsLock", "T" . Features["TapHolds"]["CapsLock"]["__Configuration"].TimeActivationSeconds)
    if (tap and A_PriorKey == "LControl") {
        SendEvent("{LCtrl Up}")
        CapsLockShortcut(CtrlActivated)
    }
    SendEvent("{LCtrl Up}")
}
#HotIf

CapsLockShortcut(CtrlActivated) {
    if CtrlActivated {
        SendEvent("{LCtrl Down}")
    }

    if Features["TapHolds"]["CapsLock"]["BackSpaceCtrl"].Enabled {
        SendEvent("{Blind}{BackSpace}")
    } else if Features["TapHolds"]["CapsLock"]["CapsLockCtrl"].Enabled {
        ToggleCapsLock()
    } else if Features["TapHolds"]["CapsLock"]["CapsWordCtrl"].Enabled {
        ToggleCapsWord()
    } else if Features["TapHolds"]["CapsLock"]["CtrlBackSpaceCtrl"].Enabled {
        SendInput("^{BackSpace}")
    } else if Features["TapHolds"]["CapsLock"]["CtrlDeleteCtrl"].Enabled {
        SendInput("^{Delete}")
    } else if Features["TapHolds"]["CapsLock"]["DeleteCtrl"].Enabled {
        SendEvent("{Blind}{Delete}")
    } else if Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled {
        SendEvent("{Blind}{Enter}")
        DisableCapsWord()
    } else if Features["TapHolds"]["CapsLock"]["EscapeCtrl"].Enabled {
        SendEvent("{Blind}{Escape}")
    } else if Features["TapHolds"]["CapsLock"]["OneShotShiftCtrl"].Enabled {
        OneShotShift()
    } else if Features["TapHolds"]["CapsLock"]["TabCtrl"].Enabled {
        SendEvent("{Blind}{Tab}")
    }

    SendEvent("{LCtrl Up}")
}

; =====================================
; ======= 5.2) LShift and LCtrl =======
; =====================================

#HotIf Features["TapHolds"]["LShiftCopy"].Enabled and not LayerEnabled
; Tap-hold on "LShift" : Ctrl + C on tap, Shift on hold
~$SC02A::
{
    TimeBefore := A_TickCount
    KeyWait("SC02A")
    TimeAfter := A_TickCount
    tap := ((TimeAfter - TimeBefore) <= Features["TapHolds"]["LShiftCopy"].TimeActivationSeconds * 1000)
    if (
        tap
        and (TimeAfter - TimeBefore) >= 50
        and A_PriorKey == "LShift"
    ) { ; A_PriorKey is to be able to fire shortcuts very quickly, under the tap time
        SendInput("{LCtrl Down}c{LCtrl Up}")
    }
}
#HotIf

#HotIf Features["TapHolds"]["LCtrlPaste"].Enabled and not LayerEnabled
; This bug seems resolved now:
; « ~ must not be used here, otherwise [AltGr] [AltGr] … [AltGr], which is supposed to give Tab multiple times, will suddenly block and keep LCtrl activated »

; Tap-hold on "LControl" : Ctrl + V on tap, Ctrl on hold
~$SC01D::
{
    UpdateLastSentCharacter("LControl")
    TimeBefore := A_TickCount
    KeyWait("SC01D")
    TimeAfter := A_TickCount
    tap := ((TimeAfter - TimeBefore) <= Features["TapHolds"]["LCtrlPaste"].TimeActivationSeconds * 1000)
    if (
        tap
        and (TimeAfter - TimeBefore) >= 50
        and A_PriorKey == "LControl"
        and not GetKeyState("SC03A", "P") ; "CapsLock"
        and not GetKeyState("SC038", "P") ; "LAlt"
    ) {
        SendInput("{LCtrl Down}v{LCtrl Up}")
    }
}
#HotIf

; =========================
; ======= 5.3) LAlt =======
; =========================

#HotIf Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : OneShotShift on tap, Shift on hold
SC038:: {
    if (
        GetKeyState("SC11D", "P")
        or GetKeyState("SC03A", "P")
        or GetKeyState("LShift", "P")
        or GetKeyState("LCtrl", "P")
    ) {
        ; Solves a problem where shorcuts consisting of another key (pressed first) + SC038 (pressed second) triggers the shortcut, but also OneShotShift()
        return
    }

    SendEvent("{LAlt Up}")
    OneShotShift()
    SendInput("{LShift Down}")
    KeyWait("SC038")
    SendInput("{LShift Up}")
}
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["TabLayer"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : Tab on tap, Layer on hold
SC038::
{
    UpdateLastSentCharacter("LAlt")

    ActivateLayer()
    KeyWait("SC038")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
    tap := (Now - CharacterSentTime <= Features["TapHolds"]["LAlt"]["TabLayer"].TimeActivationSeconds * 1000)
    if tap {
        SendEvent("{Tab}")
    }
}

SC02A & SC038:: SendInput("+{Tab}") ; On "LShift"
if Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled {
    SC11D & SC038:: {
        OneShotShiftFix()
        SendInput("+{Tab}")
    }
}
#SC038:: SendEvent("#{Tab}") ; Doesn’t fire when SendInput is used
!SC038:: SendInput("!{Tab}")
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["AltTabMonitor"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : AltTabMonitor on tap, Alt on hold
SC038::
{
    Send("{LAlt Down}")
    tap := KeyWait("SC038", "T" . Features["TapHolds"]["LAlt"]["AltTabMonitor"].TimeActivationSeconds)
    if tap {
        Send("{LAlt Up}")
        AltTabMonitor()
    } else {
        KeyWait("SC038")
        Send("{LAlt Up}")
    }
}
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["BackSpace"].Enabled and not LayerEnabled
; "LAlt" becomes BackSpace, and Delete on Shift
*SC038::
{
    BackSpaceActionWithModifiers := BackSpaceLogic()
    if not BackSpaceActionWithModifiers {
        ; If no modifier was pressed
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        Sleep(300) ; Delay before repeating the key
        while GetKeyState("SC038", "P") {
            SendEvent("{BackSpace}")
            Sleep(100)
        }
    }
}
#HotIf

#HotIf Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : BackSpace on tap, Layer on hold
*SC038::
{
    UpdateLastSentCharacter("LAlt")

    ActivateLayer()
    KeyWait("SC038")
    DisableLayer()

    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LAlt") ? LastSentCharacterKeyTime["LAlt"] : Now
    tap := (Now - CharacterSentTime <= Features["TapHolds"]["LAlt"]["BackSpaceLayer"].TimeActivationSeconds * 1000)

    if (
        tap
        and A_PriorKey == "LAlt" ; Prevents triggering BackSpace when the layer is quickly used and then released
        and not GetKeyState("SC03A", "P") ; Fix a sent BackSpace when triggering quickly "LAlt" + "CapsLock"
    ) {
        BackSpaceActionWithModifiers := BackSpaceLogic()
        if not BackSpaceActionWithModifiers {
            ; If no modifier was pressed
            SendEvent("{BackSpace}")
        }
    }
}
#HotIf

BackSpaceLogic() {
    if (
        GetKeyState("SC01D", "P")
        and GetKeyState("Shift", "P")
    ) {
        ; "LCtrl" and Shift
        SendInput("^{Delete}")
        return True
    } else if (
        GetKeyState("SC11D", "P")
        and not Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
        and GetKeyState("Shift", "P")
    ) {
        ; "RCtrl" when it stays RCtrl and Shift
        SendInput("^{Delete}")
        return True
    } else if (
        GetKeyState("SC01D", "P")
        and Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
        and GetKeyState("SC11D", "P")
    ) {
        ; "LCtrl" and Shift on "RCtrl"
        OneShotShiftFix()
        SendInput("^{Right}^{BackSpace}") ; = ^Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        return True
    } else if (
        Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
        and GetKeyState("SC11D", "P")
    ) {
        ; Shift on "RCtrl"
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        return True
    } else if GetKeyState("Shift", "P") {
        ; Shift
        SendInput("{Delete}")
        return True
    } else if GetKeyState("SC01D", "P") {
        ; "LCtrl"
        SendInput("^{BackSpace}")
        return True
    } else if (
        not Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled
        and GetKeyState("SC11D", "P")
    ) {
        ; "RCtrl" when it stays RCtrl
        SendInput("^{BackSpace}")
        return True
    }
    return False
}

; ==========================
; ======= 5.4) Space =======
; ==========================

#HotIf Features["TapHolds"]["Space"]["Ctrl"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Ctrl on hold
SC039::
{
    ih := InputHook("L1 T" . Features["TapHolds"]["Space"]["Ctrl"].TimeActivationSeconds)
    ih.Start()
    ih.Wait()
    if ih.EndReason != "Timeout" {
        Text := ih.Input
        if ih.Input == " " {
            Text := "" ; To not send a double space
        }
        SendEvent("{Space}" Text)
        ; SendEvent is used to be able to do testt{BS}★ ➜ test★ that will trigger the hotstring.
        ; Otherwise, SendInput resets the hotstrings search
        UpdateLastSentCharacter(" ")
        return
    }

    SendEvent("{LCtrl Down}")
    KeyWait("SC039")
    SendEvent("{LCtrl Up}")
}
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled ; Solves a bug of 2 sent Spaces when exiting CapsWord with a Space
        and A_TimeSinceThisHotkey <= Features["TapHolds"]["Space"]["Ctrl"].TimeActivationSeconds
    ) {
        SendEvent("{Space}")
    }
}
#HotIf

#HotIf Features["TapHolds"]["Space"]["Layer"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039::
{
    ih := InputHook("L1 T" . Features["TapHolds"]["Space"]["Layer"].TimeActivationSeconds)
    ih.Start()
    ih.Wait()
    if ih.EndReason != "Timeout" {
        Text := ih.Input
        if ih.Input == " " {
            Text := "" ; To not send a double space
        }
        SendEvent("{Space}" Text)
        ; SendEvent is used to be able to do testt{BS}★ ➜ test★ that will trigger the hotstring.
        ; Otherwise, SendInput resets the hotstrings search
        UpdateLastSentCharacter(" ")
        return
    }

    ActivateLayer()
    KeyWait("SC039")
    DisableLayer()
}
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled ; Solves a bug of 2 sent Spaces when exiting CapsWord with a Space
        and A_TimeSinceThisHotkey <= Features["TapHolds"]["Space"]["Layer"].TimeActivationSeconds
    ) {
        SendEvent("{Space}")
        UpdateLastSentCharacter(" ")
    }
}
#HotIf

#HotIf Features["TapHolds"]["Space"]["Shift"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Shift on hold
SC039::
{
    ih := InputHook("L1 T" . Features["TapHolds"]["Space"]["Shift"].TimeActivationSeconds)
    ih.Start()
    ih.Wait()
    if ih.EndReason != "Timeout" {
        Text := ih.Input
        if ih.Input == " " {
            Text := "" ; To not send a double space
        }
        SendEvent("{Space}" Text)
        ; SendEvent is used to be able to do testt{BS}★ ➜ test★ that will trigger the hotstring.
        ; Otherwise, SendInput resets the hotstrings search
        UpdateLastSentCharacter(" ")
        return
    }

    SendEvent("{LShift Down}")
    KeyWait("SC039")
    SendEvent("{LShift Up}")
}
SC039 Up:: {
    if (
        A_PriorHotkey == "SC039"
        and not CapsWordEnabled ; Solves a bug of 2 sent Spaces when exiting CapsWord with a Space
        and A_TimeSinceThisHotkey <= Features["TapHolds"]["Space"]["Shift"].TimeActivationSeconds
    ) {
        SendEvent("{Space}")
    }
}
#HotIf

; ==========================
; ======= 5.5) AltGr =======
; ==========================

#HotIf (
    not LayerEnabled
    and (
        Features["TapHolds"]["AltGr"]["BackSpace"].Enabled
        or Features["TapHolds"]["AltGr"]["CapsLock"].Enabled
        or Features["TapHolds"]["AltGr"]["CapsWord"].Enabled
        or Features["TapHolds"]["AltGr"]["CtrlBackSpace"].Enabled
        or Features["TapHolds"]["AltGr"]["CtrlDelete"].Enabled
        or Features["TapHolds"]["AltGr"]["Delete"].Enabled
        or Features["TapHolds"]["AltGr"]["Enter"].Enabled
        or Features["TapHolds"]["AltGr"]["Escape"].Enabled
        or Features["TapHolds"]["AltGr"]["OneShotShift"].Enabled
        or Features["TapHolds"]["AltGr"]["Tab"].Enabled
    )
)
; Tap-hold on "AltGr"
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . Features["TapHolds"]["AltGr"]["__Configuration"].TimeActivationSeconds)
    if (tap and (A_PriorKey == "RAlt" or A_PriorKey == "^")) {
        DisableCapsWord()
        if Features["TapHolds"]["AltGr"]["BackSpace"].Enabled {
            SendEvent("{Blind}{BackSpace}") ; SendEvent be able to trigger hotstrings
            UpdateLastSentCharacter("BackSpace")
        } else if Features["TapHolds"]["AltGr"]["CapsLock"].Enabled {
            ToggleCapsLock()
        } else if Features["TapHolds"]["AltGr"]["CapsWord"].Enabled {
            ToggleCapsWord()
        } else if Features["TapHolds"]["AltGr"]["CtrlBackSpace"].Enabled {
            SendEvent("{Blind}^{BackSpace}")
            UpdateLastSentCharacter("")
        } else if Features["TapHolds"]["AltGr"]["CtrlDelete"].Enabled {
            SendEvent("{Blind}^{Delete}")
            UpdateLastSentCharacter("")
        } else if Features["TapHolds"]["AltGr"]["Delete"].Enabled {
            SendEvent("{Blind}{Delete}")
            UpdateLastSentCharacter("Delete")
        } else if Features["TapHolds"]["AltGr"]["Enter"].Enabled {
            SendEvent("{Blind}{Enter}") ; SendEvent be able to trigger hotstrings with a Enter ending character
            UpdateLastSentCharacter("Enter")
        } else if Features["TapHolds"]["AltGr"]["Escape"].Enabled {
            SendEvent("{Escape}")
        } else if Features["TapHolds"]["AltGr"]["OneShotShift"].Enabled {
            OneShotShift()
        } else if Features["TapHolds"]["AltGr"]["Tab"].Enabled {
            SendEvent("{Blind}{Tab}") ; SendEvent be able to trigger hotstrings with a Tab ending character
            UpdateLastSentCharacter("Tab")
        }
    }
}

SC01D & ~SC138 Up::
RAlt Up:: {
    UpdateLastSentCharacter("")
}
#HotIf

; ==========================
; ======= 5.6) RCtrl =======
; ==========================

#HotIf Features["TapHolds"]["RCtrl"]["BackSpace"].Enabled and not LayerEnabled
; RCtrl becomes BackSpace, and Delete on Shift
SC11D::
{
    if GetKeyState("LShift", "P") {
        SendInput("{Delete}")
    } else if Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled and GetKeyState("SC038", "P") {
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
    } else {
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        Sleep(300) ; Delay before repeating the key
        while GetKeyState("SC11D", "P") {
            SendEvent("{BackSpace}")
            Sleep(100)
        }
    }
}
#HotIf

#HotIf Features["TapHolds"]["RCtrl"]["Tab"].Enabled and not LayerEnabled
; Tap-hold on "RCtrl" : Tab on tap, Ctrl on hold
~SC11D:: {
    tap := KeyWait("RControl", "T" . Features["TapHolds"]["RCtrl"]["Tab"].TimeActivationSeconds)
    if (tap and A_PriorKey == "RControl") {
        SendEvent("{RCtrl Up}")
        SendEvent("{Tab}") ; To be able to trigger hotstrings with a Tab ending character
    }
}

+SC11D:: SendInput("+{Tab}")
^SC11D:: SendInput("^{Tab}")
^+SC11D:: SendInput("^+{Tab}")
#SC11D:: SendEvent("#{Tab}") ; SendInput doesn’t work in that case
#HotIf

#HotIf Features["TapHolds"]["RCtrl"]["OneShotShift"].Enabled and not LayerEnabled
; Tap-hold on "RCtrl" : OneShotShift on tap, Shift on hold
SC11D:: {
    OneShotShift()
    SendEvent("{LShift Down}")
    KeyWait("SC11D")
    SendEvent("{LShift Up}")
}
#HotIf

; ========================
; ======= 5.7) Tab =======
; ========================

#HotIf Features["TapHolds"]["TabAlt"].Enabled and not LayerEnabled
; Tap-hold on "Tab": Alt + Tab on tap, Alt on hold
SC00F::LAlt
SC00F::
{
    SendInput("{LAlt Down}")
    tap := KeyWait("SC00F", "T" . Features["TapHolds"]["TabAlt"].TimeActivationSeconds)
    if tap {
        if Features["TapHolds"]["LAlt"]["TabLayer"].Enabled and GetKeyState("SC038", "P") {
            SendInput("!{Tab}")
        } else {
            SendInput("{LAlt Up}")
            AltTabMonitor()
        }

    }
}
SC00F Up:: SendInput("{LAlt Up}")
#HotIf

AltTabMonitor() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&MousePosX, &MousePosY)
    MonitorNum := GetMonitorFromPoint(MousePosX, MousePosY)
    if MonitorNum == 0 {
        return ; No monitor found
    }

    CurrentWindowId := WinExist("A")
    AppWindowsOnMonitorFiltered := []

    for WindowId in WinGetList() {
        ; Skip the currently active window
        if WindowId == CurrentWindowId {
            continue
        }

        ; Get window position and size
        WinGetPos(&x, &y, &w, &h, WindowId)

        ; Filter out windows that are too small to be usable
        if (w < 100 || h < 100) {
            continue
        }

        ; Determine which monitor contains the center of the window
        CenterX := x + w // 2
        CenterY := y + h // 2
        if GetMonitorFromPoint(CenterX, CenterY) != MonitorNum {
            continue ; Window is not on the target monitor
        }

        ; Skip windows with no title — often tooltips, overlays, or hidden UI elements, and when dragging files, and windows when a file operation is happening
        if WinGetTitle(WindowId) == "" or WinGetTitle(WindowId) == "Drag" or WinGetClass(WindowId) ==
        "OperationStatusWindow" {
            continue
        }

        ; Exclude known system window classes:
        ; - Shell_TrayWnd: Windows taskbar
        ; - Progman: desktop background
        ; - WorkerW: hidden background windows
        if ["Shell_TrayWnd", "Progman", "WorkerW"].Has(WinGetClass(WindowId)) {
            continue
        }

        ; WindowId passed all filters — add to list
        AppWindowsOnMonitorFiltered.Push(WindowId)
    }

    ; Activate the first relevant window found
    if AppWindowsOnMonitorFiltered.Length > 0 {
        WinActivate(AppWindowsOnMonitorFiltered[1])
    }
}

GetMonitorFromPoint(X, Y) {
    MonitorCount := MonitorGetCount()

    loop MonitorCount {
        ; Get the monitor’s rectangle bounding coordinates, for monitor number A_Index
        MonitorGet(A_Index, &MonitorLeft, &MonitorTop, &MonitorRight, &MonitorBottom)

        ; Check if the mouse is inside the monitor
        if (X >= MonitorLeft && X < MonitorRight && Y >= MonitorTop && Y <
            MonitorBottom) {
            return A_Index
        }
    }

    return 0 ; No monitor found
}

; ==============================
; ======= One-Shot Shift =======
; ==============================

OneShotShift() {
    global OneShotShiftEnabled := True
    ihvText := InputHook("L1 T2 E", "=%$.', " . ScriptInformation["MagicKey"])
    ihvText.KeyOpt("{BackSpace}{Enter}{Delete}", "E") ; End keys to not swallow
    ihvText.Start()
    ihvText.Wait()
    SpecialCharacter := ""

    if (ihvText.EndKey == "=") {
        SpecialCharacter := "º"
    } else if (ihvText.EndKey == "%") {
        SpecialCharacter := " %"
    } else if (ihvText.EndKey == "$") {
        SpecialCharacter := " €"
    } else if (ihvText.EndKey == ".") {
        SpecialCharacter := " :"
    } else if (ihvText.EndKey == ScriptInformation["MagicKey"]) {
        SpecialCharacter := "J" ; OneShotShift + ★ gives J directly
    } else if (ihvText.EndKey == ",") {
        SpecialCharacter := " ;"
    } else if (ihvText.EndKey == "'") {
        SpecialCharacter := " ?"
    } else if (ihvText.EndKey == " ") {
        SpecialCharacter := "-"
    }

    if (ihvText == "Timeout") {
        return
    } else if SpecialCharacter != "" {
        if OneShotShiftEnabled {
            ActivateHotstrings()
            SendNewResult(SpecialCharacter)
        } else {
            SendNewResult(ihvText.EndKey)
        }
    } else {
        if OneShotShiftEnabled {
            TitleCaseText := Format("{:T}", ihvText.Input)
            SendNewResult(TitleCaseText)
        } else {
            SendNewResult(ihvText.Input)
        }
    }
}

OneShotShiftFix() {
    ; This function and global variable solves a problem when we use the OneShotShift key as a modifier.
    ; In that case, we first press this key, thus firing the OneShotShift() function that will uppercase the next character in the next 2 seconds.
    ; The only way to disable it after it has fired is to modify this global variable by setting global OneShotShiftEnabled := False.
    ; That way, calling this function OneShotShiftFix() won’t uppercase the next character in our shortcuts involving the OneShotShift key.
    global OneShotShiftEnabled := False
}

ToggleCapsLock() {
    global CapsWordEnabled := False
    if GetKeyState("CapsLock", "T") {
        SetCapsLockState("Off")
    } else {
        SetCapsLockState("On")
    }
}

; ================================
; ======= Navigation layer =======
; ================================

ActivateLayer() {
    global LayerEnabled := True
    ResetNumberOfRepetitions()
    UpdateCapsLockLED()
}
DisableLayer() {
    global LayerEnabled := False
    A_MaxHotkeysPerInterval := 150 ; Restore old value
    UpdateCapsLockLED()
}
ResetNumberOfRepetitions() {
    SetNumberOfRepetitions(1)
}
SetNumberOfRepetitions(NewNumber) {
    global NumberOfRepetitions := NewNumber
}
ActionLayer(action) {
    SendInput(action)
    ResetNumberOfRepetitions()
}

; Fix to get the CapsWord shortcut working when pressing "LAlt" activates the layer
#HotIf (LayerEnabled
    and (
        Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled
        or Features["TapHolds"]["LAlt"]["TabLayer"].Enabled
    ) and (
        Features["Shortcuts"]["LAltCapsLock"]["BackSpace"].Enabled
        or Features["Shortcuts"]["LAltCapsLock"]["CapsLock"].Enabled
        or Features["Shortcuts"]["LAltCapsLock"]["CapsWord"].Enabled
        or Features["Shortcuts"]["LAltCapsLock"]["CtrlBackSpace"].Enabled
        or Features["Shortcuts"]["LAltCapsLock"]["CtrlDelete"].Enabled
        or Features["Shortcuts"]["LAltCapsLock"]["Delete"].Enabled
        or Features["Shortcuts"]["LAltCapsLock"]["OneShotShift"].Enabled
    )
)
; Overrides the "BackSpace" shortcut on the layer
SC03A:: {
    DisableLayer() LAltCapsLockShortcut()
}
#HotIf

; Fix when LAlt triggers the layer
#HotIf (
    Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled
    and LayerEnabled
)
SC038:: SendInput("{LAlt Up}") ; Necessary to do this, otherwise multicursor triger in VSCode when scrolling in the layer and then leaving it
#HotIf

; Fix when Space triggers the layer
#HotIf (
    Features["TapHolds"]["Space"]["Layer"].Enabled
    and LayerEnabled
)
SC039:: return ; Necessary to do this, otherwise Space keeps being sent while it is held to get the layer
#HotIf

#HotIf LayerEnabled
; The base layer will become this one when the navigation layer variable is set to True

*WheelUp:: {
    A_MaxHotkeysPerInterval := 1000 ; Reduce messages saying too many hotkeys pressed in the interval
    ActionLayer("{Volume_Up " . NumberOfRepetitions . "}") ; Turn on the volume by scrolling up
}
*WheelDown:: {
    A_MaxHotkeysPerInterval := 1000 ; Reduce messages saying too many hotkeys pressed in the interval
    ActionLayer("{Volume_Down " . NumberOfRepetitions . "}") ; Turn down the volume by scrolling down
}

SC01D & ~SC138:: ; RAlt
RAlt:: ; RAlt on QWERTY
{
    ActionLayer("{Escape " . NumberOfRepetitions . "}")
}

; === Number row ===
SC002:: SetNumberOfRepetitions(1) ; On key 1
SC003:: SetNumberOfRepetitions(2) ; On key 2
SC004:: SetNumberOfRepetitions(3) ; On key 3
SC005:: SetNumberOfRepetitions(4) ; On key 4
SC006:: SetNumberOfRepetitions(5) ; On key 5
SC007:: SetNumberOfRepetitions(6) ; On key 6
SC008:: SetNumberOfRepetitions(7) ; On key 7
SC009:: SetNumberOfRepetitions(8) ; On key 8
SC00A:: SetNumberOfRepetitions(9) ; On key 9
SC00B:: SetNumberOfRepetitions(10) ; On key 0

; ======= Left hand =======

; === Top row ===
SC010:: ActionLayer("^+{Home}") ; Select to the beginning of the document
SC011:: ActionLayer("^{Home}") ; Go to the beginning of the document
SC012:: ActionLayer("^{End}") ; Go to the end of the document
SC013:: ActionLayer("^+{End}") ; Select to the end of the document
SC014:: ActionLayer("{F2}")

; === Middle row ===
SC03A:: ActionLayer(Format("{BackSpace {1}}", NumberOfRepetitions)) ; "CapsLock" becomes BackSpace
SC01E:: ActionLayer(Format("^+{Up {1}}", NumberOfRepetitions))
SC01F:: ActionLayer(Format("{Up {1}}", NumberOfRepetitions)) ; ⇧
SC020:: ActionLayer(Format("{Down {1}}", NumberOfRepetitions)) ; ⇩
SC021:: ActionLayer(Format("^+{Down {1}}", NumberOfRepetitions))
SC022:: ActionLayer("{F12}")

; === Bottom row ===
SC056:: ActionLayer(Format("!+{Up {1}}", NumberOfRepetitions))  ; Duplicate the line up
SC02C:: ActionLayer(Format("!{Up {1}}", NumberOfRepetitions)) ; Move the line up
SC02D:: ActionLayer(Format("!{Down {1}}", NumberOfRepetitions)) ; Move the line down
SC02E:: ActionLayer(Format("!+{Down {1}}", NumberOfRepetitions)) ; Duplicate the line down
SC02F:: ActionLayer(Format("{End}{Enter {1}}", NumberOfRepetitions)) ; Start a new line below the cursor
; SC030:: ; On K

; ======= Right hand =======

; === Top row ===
SC015:: ActionLayer("+{Home}") ; Select everything to the beginning of the line
SC016:: ActionLayer(Format("^+{Left {1}}", NumberOfRepetitions)) ; Select the previous word
SC017:: ActionLayer(Format("+{Left {1}}", NumberOfRepetitions)) ; Select the previous character
SC018:: ActionLayer(Format("+{Right {1}}", NumberOfRepetitions)) ; Select the next character
SC019:: ActionLayer(Format("^+{Right {1}}", NumberOfRepetitions)) ; Select the next word
SC01A:: ActionLayer("+{End}") ; Select everything to the end of the line

; === Middle row ===
SC023:: ActionLayer("#+{Left}") ; Move the window to the left screen
SC024:: ActionLayer(Format("^{Left {1}}", NumberOfRepetitions)) ; Move to the previous word
SC025:: ActionLayer(Format("{Left {1}}", NumberOfRepetitions)) ; ⇦
SC026:: ActionLayer(Format("{Right {1}}", NumberOfRepetitions)) ; ⇨
SC027:: ActionLayer(Format("^{Right {1}}", NumberOfRepetitions)) ; Move to the next word
SC028:: ActionLayer("#+{Right}") ; Move the window to the right screen

; === Bottom row ===
SC031:: WinMaximize("A") ; Make the window fullscreen
SC032:: ActionLayer("{Home}") ; Go to the beginning of the line
SC033:: ActionLayer("#{Left}") ; Move the window to the left of the current screen
SC034:: ActionLayer("#{Right}") ; Move the window to the right of the current screen
SC035:: ActionLayer("{End}") ; Go to the end of the line
#HotIf

; ====================================================================
; ====================================================================
; ====================================================================
; ================ 6/ REDUCTION OF DISTANCES AND SFBs ================
; ====================================================================
; ====================================================================
; ====================================================================

; =====================================================
; ======= 6.1) Q becomes QU if a vowel is after =======
; =====================================================

if Features["DistancesReduction"]["QU"].Enabled {
    LoadHotstringsSection("distancesreduction", "qu", Features["DistancesReduction"]["QU"])
}

; ==========================================
; ======= 6.2) Ê acts like a deadkey =======
; ==========================================

if Features["DistancesReduction"]["DeadKeyECircumflex"].Enabled {
    DeadkeyMappingCircumflexModified := DeadkeyMappingCircumflex.Clone()
    for Vowel in ["a", "à", "i", "o", "u", "s"] {
        ; We specify the result with the vowels first to be sure it will override any problems
        CreateCaseSensitiveHotstrings(
            "*?", "ê" . Vowel, DeadkeyMappingCircumflex[Vowel],
            Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
            )
        )
        ; Necessary for things to work, as we define them already
        DeadkeyMappingCircumflexModified.Delete(Vowel)
    }
    DeadkeyMappingCircumflexModified.Delete("e") ; For the rolling "êe" that gives "œ"
    DeadkeyMappingCircumflexModified.Delete("t") ; To be able to type "être"

    ; The "Ê" key will enable to use the other symbols on the layer if we aren’t inside a word
    for MapKey, MappedValue in DeadkeyMappingCircumflexModified {
        CreateDeadkeyHotstring(MapKey, MappedValue)
    }

    CreateDeadkeyHotstring(MapKey, MappedValue) {
        ; We only activate the deadkey if it is the start of a new word, as symbols aren’t put in words
        ; This condition corrects problems such as writing "même" that give "mê⁂e"
        Combination := "ê" . MapKey
        Hotstring(
            ":*?CB0:" . Combination,
            (*) => ShouldActivateDeadkey(Combination, MappedValue)
        )
    }

    ShouldActivateDeadkey(Combination, MappedValue) {
        if not IsTimeActivationExpired(GetLastSentCharacterAt(-2), Features["DistancesReduction"][
            "DeadKeyECircumflex"]
        .TimeActivationSeconds
        ) {
            ; We only activate the deadkey if it is the start of a new word, as symbols aren’t put in words
            ; This condition corrects problems such as writing "même" that give "mê⁂e"
            ; We could simply have removed the "?" flag in the Hotstring definition, but we want to get the symbols also if we are typing numbers.
            ; For example to write 01/02 by using the / on the deadkey.
            if (GetLastSentCharacterAt(-3) ~= "^[^A-Za-z★]$") { ; Everything except a letter
                ; Character at -1 is the key in the deadkey, character at -2 is "ê", character at -3 is character before using the deadkey
                SendNewResult("{BackSpace 2}", Map("OnlyText", False))
                SendNewResult(MappedValue)
            } else if (GetLastSentCharacterAt(-3) ~= "^[nN]$" and GetLastSentCharacterAt(-1) == "c") { ; Special case of the º symbol
                SendNewResult("{BackSpace 2}", Map("OnlyText", False))
                SendNewResult(MappedValue)
            }
        }
    }
}

if Features["DistancesReduction"]["ECircumflexE"].Enabled {
    LoadHotstringsSection("distancesreduction", "ecircumflexe", Features["DistancesReduction"]["ECircumflexE"])
}

; ======================================================
; ======= 6.3) Comma becomes a J with the vowels =======
; ======================================================

if Features["DistancesReduction"]["CommaJ"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", ",à", "j",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",a", "ja",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",e", "je",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",é", "jé",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",i", "ji",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",o", "jo",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",u", "ju",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",ê", "ju",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", ",'", "j’",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
    ; To fix a problem of "J’" for ,'
    CreateHotstring(
        "*?C", ",'", "j’",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaJ"].TimeActivationSeconds)
    )
}

; ===================================================================================
; ======= 6.4) Comma makes it possible to type letters that are hard to reach =======
; ===================================================================================

if Features["DistancesReduction"]["CommaFarLetters"].Enabled {
    ; === Top row ===
    CreateCaseSensitiveHotstrings("*?", ",è", "z",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",y", "k",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",c", "ç",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",x", "où" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
    )

    ; === Middle row ===
    CreateCaseSensitiveHotstrings("*?", ",s", "q",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["CommaFarLetters"].TimeActivationSeconds)
    )
}

; ==========================================================
; ======= 6.5) SFBs reduction with Comma and consons =======
; ==========================================================

if Features["SFBsReduction"]["Comma"].Enabled {
    LoadHotstringsSection("sfbsreduction", "comma", Features["SFBsReduction"]["Comma"])
}

; ==========================================
; ======= 6.6) SFBs reduction with Ê =======
; ==========================================

if Features["SFBsReduction"]["ECirc"].Enabled {
    LoadHotstringsSection("sfbsreduction", "ecirc", Features["SFBsReduction"]["ECirc"])
}

; ==========================================
; ======= 6.7) SFBs reduction with È =======
; ==========================================

if Features["SFBsReduction"]["EGrave"].Enabled {
    LoadHotstringsSection("sfbsreduction", "egrave", Features["SFBsReduction"]["EGrave"])
}

; ==========================================
; ======= 6.8) SFBs reduction with À =======
; ==========================================

if Features["SFBsReduction"]["BU"].Enabled and Features["MagicKey"]["TextExpansion"].Enabled {
    ; Those hotstrings must be defined before bu, otherwise they won’t get activated
    CreateCaseSensitiveHotstrings("*", "il a mà" . ScriptInformation["MagicKey"], "il a mis à jour")
    CreateCaseSensitiveHotstrings("*", "la mà" . ScriptInformation["MagicKey"], "la mise à jour")
    CreateCaseSensitiveHotstrings("*", "ta mà" . ScriptInformation["MagicKey"], "ta mise à jour")
    CreateCaseSensitiveHotstrings("*", "ma mà" . ScriptInformation["MagicKey"], "ma mise à jour")
    CreateCaseSensitiveHotstrings("*?", "e mà" . ScriptInformation["MagicKey"], "e mise à jour")
    CreateCaseSensitiveHotstrings("*?", "es mà" . ScriptInformation["MagicKey"], "es mises à jour")
    CreateCaseSensitiveHotstrings("*", "mà" . ScriptInformation["MagicKey"], "mettre à jour")
    CreateCaseSensitiveHotstrings("*", "mià" . ScriptInformation["MagicKey"], "mise à jour")
    CreateCaseSensitiveHotstrings("*", "pià" . ScriptInformation["MagicKey"], "pièce jointe")
    CreateCaseSensitiveHotstrings("*", "tà" . ScriptInformation["MagicKey"], "toujours")
}
if Features["SFBsReduction"]["IÉ"].Enabled and Features["SFBsReduction"]["BU"].Enabled {
    CreateCaseSensitiveHotstrings(
        ; Fix éà★ ➜ ébu insteaf of iéé
        "*?", "ié★", "ébu",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["BU"].TimeActivationSeconds)
    )
}
if Features["SFBsReduction"]["BU"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "à★", "bu",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["BU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àu", "ub",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["BU"].TimeActivationSeconds)
    )
}
if Features["SFBsReduction"]["IÉ"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "àé", "éi",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["IÉ"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "éà", "ié",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["IÉ"].TimeActivationSeconds)
    )
}

; ==========================================
; ==========================================
; ==========================================
; ================ 7/ ROLLS ================
; ==========================================
; ==========================================
; ==========================================

; =======================================
; ======= 7.1) Rolls on left hand =======
; =======================================

; === Top row ===
if Features["Rolls"]["CloseChevronTag"].Enabled {
    ; The original call used flags "*?P" — the "P" flag is lost via TOML
    ; extraction but the remaining "*?" still yields the same behavior here
    LoadHotstringsSection("rolls", "closechevrontag", Features["Rolls"]["CloseChevronTag"])
}

; === Middle row ===
if Features["Rolls"]["EZ"].Enabled {
    LoadHotstringsSection("rolls", "ez", Features["Rolls"]["EZ"])
}

; === Bottom row ===
if Features["Rolls"]["Comment"].Enabled {
    LoadHotstringsSection("rolls", "comment", Features["Rolls"]["Comment"])
}

; =======================================
; ======= 7.2 Rolls on right hand =======
; =======================================

; === Top row ===
if Features["Rolls"]["HashtagParenthesis"].Enabled {
    LoadHotstringsSection("rolls", "hashtagparenthesis", Features["Rolls"]["HashtagParenthesis"])
}
if Features["Rolls"]["HashtagBracket"].Enabled {
    LoadHotstringsSection("rolls", "hashtagbracket", Features["Rolls"]["HashtagBracket"])
}
if Features["Rolls"]["HC"].Enabled {
    LoadHotstringsSection("rolls", "hc", Features["Rolls"]["HC"])
}
if Features["Rolls"]["Assign"].Enabled {
    CreateHotstring(
        "*?", " #ç", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", " #!", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "#ç", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "#!", SpaceAroundSymbols . ":=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["Assign"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["NotEqual"].Enabled {
    CreateHotstring(
        "*?", " ç#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", " !#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "ç#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "!#", SpaceAroundSymbols . "!=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["NotEqual"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["SX"].Enabled {
    LoadHotstringsSection("rolls", "sx", Features["Rolls"]["SX"])
}
if Features["Rolls"]["CX"].Enabled {
    LoadHotstringsSection("rolls", "cx", Features["Rolls"]["CX"])
}

; === Middle row ===
if Features["Rolls"]["EqualString"].Enabled {
    CreateHotstring(
        "*?", " [)", SpaceAroundSymbols . "=" . SpaceAroundSymbols . "`"`"{Left}",
        Map("OnlyText", False).Set("TimeActivationSeconds", Features["Rolls"]["EqualString"].TimeActivationSeconds
        )
    )
    CreateHotstring(
        "*?", "[)", SpaceAroundSymbols . "=" . SpaceAroundSymbols . "`"`"{Left}",
        Map("OnlyText", False).Set("TimeActivationSeconds", Features["Rolls"]["EqualString"].TimeActivationSeconds
        )
    )
}
if Features["Rolls"]["EnglishNegation"].Enabled and Features["Autocorrection"]["TypographicApostrophe"].Enabled {
    CreateHotstring(
        "*?", "nt'", "n’t",
        Map("TimeActivationSeconds", Features["Rolls"]["EnglishNegation"].TimeActivationSeconds)
    )
} else if Features["Rolls"]["EnglishNegation"].Enabled {
    CreateHotstring(
        "*?", "nt'", "n't",
        Map("TimeActivationSeconds", Features["Rolls"]["EnglishNegation"].TimeActivationSeconds)
    )
}

; === Bottom row ===
if Features["Rolls"]["LeftArrow"].Enabled {
    CreateHotstring(
        "*?", " =+", SpaceAroundSymbols . "➜" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["LeftArrow"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "=+", SpaceAroundSymbols . "➜" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["LeftArrow"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["AssignArrowEqualRight"].Enabled {
    CreateHotstring(
        "*?", " $=", SpaceAroundSymbols . "=>" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualRight"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "$=", SpaceAroundSymbols . "=>" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualRight"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["AssignArrowEqualLeft"].Enabled {
    CreateHotstring(
        "*?", " =$", SpaceAroundSymbols . "<=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualLeft"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "=$", SpaceAroundSymbols . "<=" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowEqualLeft"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["AssignArrowMinusRight"].Enabled {
    CreateHotstring(
        "*?", " +?", SpaceAroundSymbols . "->" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusRight"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "+?", SpaceAroundSymbols . "->" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusRight"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["AssignArrowMinusLeft"].Enabled {
    CreateHotstring(
        "*?", " ?+", SpaceAroundSymbols . "<-" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusLeft"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "?+", SpaceAroundSymbols . "<-" . SpaceAroundSymbols,
        Map("TimeActivationSeconds", Features["Rolls"]["AssignArrowMinusLeft"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["CT"].Enabled {
    LoadHotstringsSection("rolls", "ct", Features["Rolls"]["CT"])
}

; ===================================================
; ===================================================
; ===================================================
; ================ 8/ AUTOCORRECTION ================
; ===================================================
; ===================================================
; ===================================================

; ==============================================================================
; ======= 8.1) Automatic conversion of apostrophe into a typographic one =======
; ==============================================================================

if Features["Autocorrection"]["TypographicApostrophe"].Enabled {
    LoadHotstringsSection("autocorrection", "typographicapostrophe", Features["Autocorrection"][
        "TypographicApostrophe"])

    ; Create all hotstrings y'a → y’a, y'b → y’b, etc.
    ; This prevents false positives like writing ['key'] ➜ ['key’]
    for Letter in StrSplit("abcdefghijklmnopqrstuvwxyz") {
        CreateCaseSensitiveHotstrings(
            "*?", "y'" . Letter, "y’" . Letter,
            Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
        )
    }
}

; ==========================================
; ======= 8.2) Errors autocorrection =======
; ==========================================

if Features["Autocorrection"]["Errors"].Enabled {
    LoadHotstringsSection("autocorrection", "errors", Features["Autocorrection"]["Errors"])
}

if Features["Autocorrection"]["OU"].Enabled {
    LoadHotstringsSection("autocorrection", "ou", Features["Autocorrection"]["OU"])
}

if Features["Autocorrection"]["MultiplePunctuationMarks"].Enabled {
    LoadHotstringsSection("autocorrection", "multiplepunctuationmarks", Features["Autocorrection"][
        "MultiplePunctuationMarks"])

    ; We can’t use the TimeActivationSeconds here, as previous character = current character = "."
    Hotstring(
        ":*?B0:" . "...",
        ; Needs to be activated only after a word, otherwise can cause problem in code, like in js: [...a, ...b]
        (*) => GetLastSentCharacterAt(-4) ~= "^[A-Za-z]$" ?
            SendNewResult("{BackSpace 3}…", Map("OnlyText", False)) : ""
    )
}

if Features["Autocorrection"]["SuffixesAChaining"].Enabled {
    LoadHotstringsSection("autocorrection", "suffixesachaining", Features["Autocorrection"]["SuffixesAChaining"])
}

; =================================================
; ======= 8.3) Add minus sign automatically =======
; =================================================

if Features["Autocorrection"]["Minus"].Enabled {
    LoadHotstringsSection("autocorrection", "minus", Features["Autocorrection"]["Minus"])
}

if Features["Autocorrection"]["MinusApostrophe"].Enabled {
    LoadHotstringsSection("autocorrection", "minusapostrophe", Features["Autocorrection"]["MinusApostrophe"])
}

; =====================================================================
; ======= 8.3.1) Phone number & social security auto-complete =========
; =====================================================================

if Features["Autocorrection"]["PhoneNumberAutoComplete"].Enabled {
    CreateHotstring("*", "+33" . SubStr(PersonalInformation["PhoneNumber"], 1, 2), "+33" . PersonalInformation[
        "PhoneNumber"]) ; +3306X
    CreateHotstring("*", "+33" . SubStr(PersonalInformation["PhoneNumber"], 2, 3), "+33" . PersonalInformation[
        "PhoneNumber"]) ; +336X
    CreateHotstring("*", SubStr(PersonalInformation["PhoneNumber"], 1, 4), PersonalInformation["PhoneNumber"]) ; 06XX
    CreateHotstring("*", SubStr(PersonalInformation["PhoneNumber"], 2, 5), PersonalInformation["PhoneNumber"]) ; 6XXX

    CreateHotstring("*", SubStr(PersonalInformation["PhoneNumberClean"], 1, 5), PersonalInformation["PhoneNumberClean"]) ; 06 XX
    CreateHotstring("*", SubStr(PersonalInformation["PhoneNumberClean"], 2, 5), SubStr(PersonalInformation[
        "PhoneNumberClean"], 2)) ; 6 XX
    CreateHotstring("*", SubStr(PersonalInformation["SocialSecurityNumber"], 1, 5), PersonalInformation[
        "SocialSecurityNumber"])
}

; ========================================
; ======= 8.4) Caps autocorrection =======
; ========================================

if Features["Autocorrection"]["Caps"].Enabled {
    LoadHotstringsSection("autocorrection", "caps", Features["Autocorrection"]["Caps"])

    ; For these apps, we only capitalize them when used in context of apps, and not as English words
    apps := ["excel", "teams", "word", "office"]
    prefixes := [
        "avec",
        "dans",
        "en",
        "et",
        "fichier",
        "fichiers",
        "le",
        "mon",
        "sur",
        "son",
        "ton",
    ]
    for prefix in prefixes {
        for app in apps {
            from := prefix . " " . app
            to := prefix . " " . Capitalize(app)
            CreateHotstring("", from, to)
        }
    }
    Capitalize(str) {
        return StrUpper(SubStr(str, 1, 1)) . SubStr(str, 2)
    }
}

; ===========================================
; ======= 8.5) Accents autocorrection =======
; ===========================================

if Features["Autocorrection"]["Names"].Enabled {
    LoadHotstringsSection("autocorrection", "names", Features["Autocorrection"]["Names"])
}

if Features["Autocorrection"]["Accents"].Enabled {
    LoadHotstringsSection("autocorrection", "accents", Features["Autocorrection"]["Accents"])
}

; ===================================================
; ===================================================
; ===================================================
; ================ 9/ TEXT EXPANSION ================
; ===================================================
; ===================================================
; ===================================================

; ====================================
; ======= 9.1) Suffixes with À =======
; ====================================

if Features["DistancesReduction"]["SuffixesA"].Enabled {
    LoadHotstringsSection("distancesreduction", "suffixesa", Features["DistancesReduction"]["SuffixesA"])
}

; ==========================================================
; ======= 9.2) PERSONAL INFORMATION SHORTCUTS WITH @ =======
; ==========================================================

if Features["MagicKey"]["TextExpansionPersonalInformation"].Enabled {
    CreateHotstring("*", "@bic" . ScriptInformation["MagicKey"], PersonalInformation["BIC"], Map("FinalResult",
        True))
    CreateHotstring("*", "@cb" . ScriptInformation["MagicKey"], PersonalInformation["CreditCard"], Map(
        "FinalResult",
        True))
    CreateHotstring("*", "@cc" . ScriptInformation["MagicKey"], PersonalInformation["CreditCard"], Map(
        "FinalResult",
        True))
    CreateHotstring("*", "@iban" . ScriptInformation["MagicKey"], PersonalInformation["IBAN"], Map("FinalResult",
        True))
    CreateHotstring("*", "@rib" . ScriptInformation["MagicKey"], PersonalInformation["IBAN"], Map("FinalResult",
        True))
    CreateHotstring("*", "@ss" . ScriptInformation["MagicKey"], PersonalInformation["SocialSecurityNumber"], Map(
        "FinalResult", True))
    CreateHotstring("*", "@tel" . ScriptInformation["MagicKey"], PersonalInformation["PhoneNumber"], Map(
        "FinalResult",
        True))
    CreateHotstring("*", "@tél" . ScriptInformation["MagicKey"], PersonalInformation["PhoneNumber"], Map(
        "FinalResult",
        True))

    ; Map a letter to a value (n ➜ Nom, t ➜ 0606060606, etc.)
    global PersonalInformationHotstrings := Map()
    for InfoKey, InfoValue in PersonalInformationLetters {
        PersonalInformationHotstrings[InfoKey] := PersonalInformation[InfoValue]
    }

    ; Generate all possible combinations of letters between 1 and PatternMaxLength characters
    GeneratePersonalInformationHotstrings(
        PersonalInformationHotstrings,
        Features["MagicKey"]["TextExpansionPersonalInformation"].PatternMaxLength
    )

    GeneratePersonalInformationHotstrings(hotstrings, maxLen) {
        keys := []
        for k in hotstrings
            keys.Push(k)
        loop maxLen
            Generate(keys, hotstrings, "", A_Index)
    }

    ; In case email is "^a" we want to send raw string and not Ctrl + A
    EscapeSpecialChars(text) {
        text := StrReplace(text, "{", "{{}")
        text := StrReplace(text, "}", "{}}")
        text := StrReplace(text, "^", "{Asc 94}")
        text := StrReplace(text, "~", "{Asc 126}")
        text := StrReplace(text, "+", "{+}")
        text := StrReplace(text, "!", "{!}")
        text := StrReplace(text, "#", "{#}")
        return text
    }

    Generate(keys, hotstrings, combo, len) {
        if (len == 0) {
            value := ""
            loop parse, combo {
                if (hotstrings.Has(A_LoopField)) {
                    if (value != "") {
                        value := value . "{Tab}"
                    }

                    value := value . hotstrings[A_LoopField]
                }
            }
            if (value != "") {
                CreateHotstringCombo(combo, EscapeSpecialChars(value))
            }
            return
        }
        for key in keys {
            Generate(keys, hotstrings, combo . key, len - 1)
        }
    }

    CreateHotstringCombo(combo, value) {
        CreateHotstring("*", "@" combo "" . ScriptInformation["MagicKey"], value, Map("OnlyText", False).Set(
            "FinalResult", True))
    }

    ; Generate manually longer shortcuts, as increasing PatternMaxLength expands memory exponentially
    CreateHotstringComboAuto(Combo) {
        Value := ""
        loop StrLen(Combo) {
            ComboLetter := SubStr(Combo, A_Index, 1)
            Value := Value . PersonalInformationHotstrings[ComboLetter] . "{Tab}"
        }
        CreateHotstring("*", "@" . Combo . ScriptInformation["MagicKey"], Value, Map("OnlyText", False).Set(
            "FinalResult", True))
    }
    CreateHotstringComboAuto("mm")
    CreateHotstringComboAuto("mnp")
    CreateHotstringComboAuto("mpn")
    CreateHotstringComboAuto("np")
    CreateHotstringComboAuto("npam")
    CreateHotstringComboAuto("npamm")
    CreateHotstringComboAuto("npd")
    CreateHotstringComboAuto("npdm")
    CreateHotstringComboAuto("npdmm")
    CreateHotstringComboAuto("npdmmt")
    CreateHotstringComboAuto("npdmt")
    CreateHotstringComboAuto("npm")
    CreateHotstringComboAuto("npmd")
    CreateHotstringComboAuto("npmm")
    CreateHotstringComboAuto("npmmd")
    CreateHotstringComboAuto("npmt")
    CreateHotstringComboAuto("npt")
    CreateHotstringComboAuto("nptm")
    CreateHotstringComboAuto("nptmm")
    CreateHotstringComboAuto("pn")
    CreateHotstringComboAuto("pnam")
    CreateHotstringComboAuto("pnamm")
    CreateHotstringComboAuto("pnd")
    CreateHotstringComboAuto("pndm")
    CreateHotstringComboAuto("pndmm")
    CreateHotstringComboAuto("pnm")
    CreateHotstringComboAuto("pnmm")
    CreateHotstringComboAuto("pntm")
    CreateHotstringComboAuto("pntmd")
    CreateHotstringComboAuto("pntmm")
    CreateHotstringComboAuto("pntmmd")
}

; ===============================================
; ======= 9.2.1) DATE EXPANSION WITH dt★ =======
; ===============================================

if Features["MagicKey"]["TextExpansionDate"].Enabled {
    MK := ScriptInformation["MagicKey"]
    Abbreviation := "dt" . MK
    Hotstring(":*B0:" . Abbreviation, DateHotstringCallback.Bind(Abbreviation))
    DateHotstringCallback(Abbr, *) {
        SendFinalResult("{BackSpace " . StrLen(Abbr) . "}", Map("OnlyText", False))
        SendFinalResult(FormatTime(, "dd/MM/yyyy"))
    }
}

; ===========================================
; ======= 9.3) TEXT EXPANSION WITH ★ =======
; ===========================================

if Features["MagicKey"]["TextExpansion"].Enabled {
    LoadHotstringsSection("magickey", "textexpansion", Features["MagicKey"]["TextExpansion"])
}

if Features["MagicKey"]["TextExpansionAuto"].Enabled {
    LoadHotstringsSection("magickey", "textexpansionauto", Features["MagicKey"]["TextExpansionAuto"])
}

; ===========================
; ======= 9.4) Emojis =======
; ===========================

if Features["MagicKey"]["TextExpansionEmojis"].Enabled {
    LoadHotstringsSection("magickey", "textexpansionemojis", Features["MagicKey"]["TextExpansionEmojis"])
}

; ============================
; ======= 9.5) Symbols =======
; ============================

if Features["MagicKey"]["TextExpansionSymbols"].Enabled {
    LoadHotstringsSection("magickey", "textexpansionsymbols", Features["MagicKey"]["TextExpansionSymbols"])
}

if Features["MagicKey"]["TextExpansionSymbolsTypst"].Enabled {
    LoadHotstringsSection("magickey", "textexpansionsymbolstypst", Features["MagicKey"]["TextExpansionSymbolsTypst"],
        Map("OnlyText", False))
}

; ===============================
; ======= 9.6) Repeat key =======
; ===============================

#InputLevel 1 ; Mandatory for this section to work, it needs to be below the inputlevel of the key remappings

; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
; That means a letter will only be repeated if no hotstring defined above matches
if Features["MagicKey"]["Repeat"].Enabled {
    LoadHotstringsSection("magickey", "repeat", Features["MagicKey"]["Repeat"])
}

CreateHotstring("*", "clé" . ScriptInformation["MagicKey"], "🔑")
