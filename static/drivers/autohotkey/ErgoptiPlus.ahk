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

SendNewResult(Text, options := Map()) {
    ; Default values if not provided
    OptionOnlyText := options.Has("OnlyText") ? options["OnlyText"] : True

    ; Hotstrings will be triggered, so SendNewResult("a") can give a ➜ b ➜ c (final result)
    if OptionOnlyText {
        SendEvent("{Text}" Text)
        ; We use Send("{Text}") because otherwise sending certain special characters like symbols will trigger modifiers, like Alt or AltGr, and may even stay locked in that state
        ; An example is writing "c’est" with the windows Ergopti layout
    } else {
        SendEvent(Text)
    }
    UpdateLastSentCharacter(SubStr(Text, -1))
}

SendFinalResult(Text, options := Map()) {
    ; Default values if not provided
    OptionOnlyText := options.Has("OnlyText") ? options["OnlyText"] : False

    ; SendInput prevents other hotstrings/hotkeys from activating, so this is the "final" result
    if OptionOnlyText {
        SendInput("{Text}" Text)
    } else {
        SendInput(Text)
    }
}

SendInstant(Text) {
    ; Function for sending immediately a big text without typing it letter by letter
    OldClipboard := ClipboardAll()  ; Save the current clipboard

    A_Clipboard := Text             ; Put the text into the clipboard
    SendInput("^v")                 ; Paste into the active window
    Sleep(200)                      ; Give time for the paste to finish

    A_Clipboard := OldClipboard     ; Restore the original clipboard
    OldClipboard := ""              ; Clear the variable holding old clipboard to free memory
}

; Leave time to trigger hotstrings between sending a character and then another one
ActivateHotstrings() {
    SendNewResult(" ")
    Sleep(50) ; in ms
    SendNewResult("{BackSpace}", Map("OnlyText", False))
}

GetSelection() {
    OldClipboard := ClipboardAll() ; Save entire clipboard content (including formats)
    A_Clipboard := ""              ; Clear clipboard to detect new content
    SendEvent("^c")                ; Copy selected text (using SendEvent for ClipWait reliability)
    ClipWait(2)                    ; Wait up to 2 seconds for clipboard to contain data
    Text := A_Clipboard            ; Retrieve copied text

    ; Restore original clipboard content
    A_Clipboard := OldClipboard
    OldClipboard := "" ; Clear the variable holding old clipboard to free memory

    return Text
}

; Functions to change the behavior depending on the context
MicrosoftApps() {
    return WinActive("ahk_exe Teams.exe")
    or WinActive("ahk_exe ms-teams.exe") ; New version
    or WinActive("ahk_exe ONENOTE.exe")
    or WinActive("ahk_exe olk.exe") ; New version
    or WinActive("ahk_exe OUTLOOK.EXE")
    or WinActive("ahk_exe WINWORD.EXE")
    or WinActive("ahk_exe EXCEL.EXE")
    or WinActive("ahk_exe POWERPNT.EXE")
}

CreateHotstring(Flags, Abbreviation, Replacement, options := Map()) {
    ; Default values if not provided
    OptionOnlyText := options.Has("OnlyText") ? options["OnlyText"] : True
    OptionFinalResult := options.Has("FinalResult") ? options["FinalResult"] : False
    OptionTimeActivationSeconds := options.Has("TimeActivationSeconds") ? options[
        "TimeActivationSeconds"] : 0

    HotstringOptions := Map("OnlyText", OptionOnlyText).Set("FinalResult", OptionFinalResult).Set(
        "TimeActivationSeconds", OptionTimeActivationSeconds)

    FlagsPortion := ":" Flags "B0:"
    Hotstring(
        FlagsPortion Abbreviation,
        (*) => HotstringHandler(
            Abbreviation,
            Replacement,
            A_EndChar,
            HotstringOptions
        )
    )
}

HotstringHandler(Abbreviation, Replacement, EndChar, HotstringOptions := Map()) {
    ; Default values if not provided
    OnlyText := HotstringOptions.Has("OnlyText") ? HotstringOptions["OnlyText"] : True
    FinalResult := HotstringOptions.Has("FinalResult") ? HotstringOptions["FinalResult"] : False
    OptionTimeActivationSeconds := HotstringOptions.Has("TimeActivationSeconds") ? HotstringOptions[
        "TimeActivationSeconds"] : 0

    if IsTimeActivationExpired(SubStr(Abbreviation, -2, 1), OptionTimeActivationSeconds) {
        return
    }

    SendEvent("{SC138 Up}") ; Becomes necessary when we replaced the AltGr key by Kana

    ; We pass the abbreviation as argument to delete it manually, as we use the B0 flag
    ; This is to make it work everywhere, like in URL bar or in the code inspector inside navigators
    ; Otherwise, typing hc to get wh gives hwh for example when trying to type "white"
    NumberOfCharactersToDelete := StrLen(Abbreviation)
    if (EndChar != "") {
        ; Delete ending character too if present, to then add it again
        ; Tab is now safely included here, relying on the modern editors' smart backspace
        NumberOfCharactersToDelete := NumberOfCharactersToDelete + 1
    }

    if WinActive("ahk_class Notepad") {
        ; In Windows 11 Notepad, hotstrings don’t work properly, this is a Windows bug, not AutoHotkey one
        SendNewResult("{BackSpace " . NumberOfCharactersToDelete . "}", Map("OnlyText", False))
        SendInstant(Replacement . EndChar)
        return
    }

    if FinalResult {
        SendFinalResult("{BackSpace " . NumberOfCharactersToDelete . "}", Map("OnlyText", False))
        SendFinalResult(Replacement, Map("OnlyText", OnlyText))
        SendFinalResult(EndChar, Map("OnlyText", False))
    } else {
        SendNewResult("{BackSpace " . NumberOfCharactersToDelete . "}", Map("OnlyText", False))
        SendNewResult(Replacement, Map("OnlyText", OnlyText))
        SendNewResult(EndChar, Map("OnlyText", False))
    }
}

IsTimeActivationExpired(PreviousCharacter, OptionTimeActivationSeconds) {
    ; Don’t activate the hotstring if taped too slowly
    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has(PreviousCharacter) ? LastSentCharacterKeyTime[PreviousCharacter] :
        Now
    if OptionTimeActivationSeconds > 0 {
        ; We need to convert into milliseconds, hence the multiplication by 1000
        if (Now - CharacterSentTime > OptionTimeActivationSeconds * 1000) {
            return True
        }
    }
    return False
}

CreateCaseSensitiveHotstrings(Flags, Abbreviation, Replacement, options := Map()) {
    ; Default values if not provided
    OptionPreferTitleCase := options.Has("PreferTitleCase") ? options["PreferTitleCase"] : True
    OptionOnlyText := options.Has("OnlyText") ? options["OnlyText"] : True
    OptionFinalResult := options.Has("FinalResult") ? options["FinalResult"] : False
    OptionTimeActivationSeconds := options.Has("TimeActivationSeconds") ? options["TimeActivationSeconds"] : 0

    HotstringOptions := Map("OnlyText", OptionOnlyText).Set("FinalResult", OptionFinalResult).Set(
        "TimeActivationSeconds", OptionTimeActivationSeconds)
    FlagsPortion := ":" Flags "CB0:"

    UppercasedSymbols := Map(
        ",", [" ;", " :"], ; Order matters, the nbsp abbreviations need to trigger first the engine, otherwise the nbsp won’t be deleted
        "'", [" ?"]
    )

    AbbreviationLowerCase := StrLower(Abbreviation)
    AbbreviationTitleCase := StrTitle(Abbreviation)
    AbbreviationInvertedTitleCase := StrLower(SubStr(Abbreviation, 1, -1)) . StrUpper(SubStr(Abbreviation, -1))
    AbbreviationUpperCase := StrUpper(Abbreviation)

    FirstChar := SubStr(Abbreviation, 1, 1)
    LastChar := SubStr(Abbreviation, -1)

    ReplacementLowerCase := StrLower(Replacement)
    ReplacementTitleCase := StrTitle(Replacement)
    ReplacementUpperCase := StrUpper(Replacement)

    ; Lowercase
    Hotstring(
        FlagsPortion AbbreviationLowerCase,
        (*) => HotstringHandler(AbbreviationLowerCase, ReplacementLowerCase, A_EndChar, HotstringOptions)
    )

    ; When an abbreviation is only one character, titlecase = uppercase
    if StrLen(RTrim(Abbreviation, ScriptInformation["MagicKey"])) == 1 {
        ; Uppercase/Titlecase
        Hotstring(
            FlagsPortion AbbreviationTitleCase,
            (*) => HotstringHandler(AbbreviationTitleCase, ReplacementTitleCase, A_EndChar, HotstringOptions)
        )
        return
    }

    if (StrLen(Abbreviation) >= 2) {

        ; Uppercase
        for _, variant in GenerateUppercaseVariants(AbbreviationUppercase, UppercasedSymbols) {
            v := variant ; Capture the value for this iteration (otherwise there is an error)
            Hotstring(
                FlagsPortion v,
                (*) => HotstringHandler(v, ReplacementUpperCase, A_EndChar, HotstringOptions)
            )
        }

        ; Titlecase: first letter uppercase, rest lowercase
        if !(StrLower(FirstChar) == StrUpper(FirstChar)) {
            Hotstring(
                FlagsPortion AbbreviationTitleCase,
                (*) => HotstringHandler(AbbreviationTitleCase, ReplacementTitleCase, A_EndChar, HotstringOptions)
            )
        } else if UppercasedSymbols.Has(firstChar) {
            for UppercasedSymbol in UppercasedSymbols[firstChar] {
                AbbreviationTitleCaseVariant := UppercasedSymbol . SubStr(AbbreviationLowerCase, 2)
                Hotstring(
                    FlagsPortion AbbreviationTitleCaseVariant,
                    (*) => HotstringHandler(AbbreviationTitleCaseVariant, ReplacementTitleCase, A_EndChar,
                        HotstringOptions
                    )
                )
            }
        }

        ; Inverted titlecase: beginning lowercase, last letter uppercase
        if OptionPreferTitleCase {
            if !(StrLower(lastChar) == StrUpper(lastChar)) {
                Hotstring(
                    FlagsPortion AbbreviationInvertedTitleCase,
                    (*) => HotstringHandler(AbbreviationInvertedTitleCase, ReplacementTitleCase, A_EndChar,
                        HotstringOptions)
                )
            } else if UppercasedSymbols.Has(LastChar) {
                for UppercasedSymbol in UppercasedSymbols[LastChar] {
                    AbbreviationInvertedTitleCaseVariant := SubStr(AbbreviationLowerCase, 1, -1) . UppercasedSymbol
                    Hotstring(
                        FlagsPortion AbbreviationInvertedTitleCaseVariant,
                        (*) => HotstringHandler(AbbreviationInvertedTitleCaseVariant, ReplacementTitleCase, A_EndChar,
                            HotstringOptions)
                    )
                }
            }
        } else {
            Hotstring(
                FlagsPortion AbbreviationInvertedTitleCase,
                (*) => HotstringHandler(AbbreviationInvertedTitleCase, ReplacementUpperCase, A_EndChar,
                    HotstringOptions)
            )
        }
    }
}

StrTitle(Text) {
    if (StrLen(Text) > 0) {
        return StrUpper(SubStr(Text, 1, 1)) StrLower(SubStr(Text, 2))
    } else {
        return Text
    }
}

GenerateUppercaseVariants(AbbreviationUpperCase, UppercasedSymbols) {
    Variants := [AbbreviationUpperCase]
    for i, Char in StrSplit(AbbreviationUpperCase) {
        if UppercasedSymbols.Has(Char) {
            for _, UpperSymbol in UppercasedSymbols[Char] {
                AbbreviationUpperCaseVariant :=
                    SubStr(AbbreviationUpperCase, 1, i - 1)
                    . UpperSymbol
                    . SubStr(AbbreviationUpperCase, i + 1)
                Variants.Push(AbbreviationUpperCaseVariant)
            }
        }
    }
    return Variants
}

GetLastSentCharacterAt(Offset) {
    if !IsSet(LastSentCharacters)
        return ""
    Len := LastSentCharacters.Length
    if Len < Abs(Offset)
        return ""
    return LastSentCharacters[Offset]
}

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

global Features := Map(
    "__Order", ["Layout", "DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey", "Shortcuts",
        "TapHolds"],
    "Layout", Map(
        "__Order", ["ErgoptiBase", "DirectAccessDigits", "ErgoptiAltGr", "ErgoptiPlus"],
        "ErgoptiBase", {
            Enabled: True,
            Description: "Émuler la couche de base de la disposition Ergopti",
        },
        "DirectAccessDigits", {
            Enabled: True,
            Description: "Chiffres en accès direct sur la rangée du haut",
        },
        "ErgoptiAltGr", {
            Enabled: True,
            Description: "Émuler la couche AltGr de la disposition Ergopti",
        },
        "ErgoptiPlus", {
            Enabled: True,
            Description: "Appliquer les légers changements en AltGr d’Ergopti➕",
        }
    ),
    "DistancesReduction", Map(
        "__Order", [
            "QU",
            "SuffixesA",
            "-",
            "CommaJ",
            "CommaFarLetters",
            "-",
            "DeadKeyECircumflex",
            "ECircumflexE",
            "-",
            "SpaceAroundSymbols"
        ],
        "QU", {
            Enabled: True,
            Description: "Q devient QU quand elle est suivie d’une voyelle : qa = qua, qo = quo, …",
            TimeActivationSeconds: 1,
        },
        "SuffixesA", {
            Enabled: True,
            Description: "À + lettre donne un suffixe : às = ement, àn = ation, àh = ight, …",
            TimeActivationSeconds: 1,
        },
        "CommaJ", {
            Enabled: True,
            Description: "Virgule + Voyelle donne J : ,a = ja, ,o = jo, ,' = j’, …",
            TimeActivationSeconds: 1,
        },
        "CommaFarLetters", {
            Enabled: True,
            Description: "Virgule permet de taper des lettres excentrées : ,è=z et ,y=k et ,c=ç et ,x=où et ,s=q",
            TimeActivationSeconds: 1,
        },
        "DeadKeyECircumflex", {
            Enabled: True,
            Description: "Ê suivi d’une lettre agit comme une touche morte : êo = ô, êu = û, ês = ß…",
            TimeActivationSeconds: 1,
        },
        "ECircumflexE", {
            Enabled: True,
            Description: "Ê suivi de E donne Œ",
            TimeActivationSeconds: 1,
        },
        "SpaceAroundSymbols", {
            Enabled: True,
            Description: "Ajouter un espace avant et après les symboles obtenus par rolls ainsi qu’après la touche [où]",
            TimeActivationSeconds: 1,
        },
    ),
    "SFBsReduction", Map(
        "__Order", [
            "Comma",
            "-",
            "ECirc",
            "EGrave",
            "-",
            "BU",
            "IÉ"
        ],
        "Comma", {
            Enabled: True,
            Description: "Virgule + Consonne corrige de très nombreux SFBs : ,t = pt, ,d= ds, ,p = xp, …",
            TimeActivationSeconds: 1,
        },
        "ECirc", {
            Enabled: True,
            Description: "Ê + touche sur la main gauche corrige 4 SFBs : êé = oe, éê = eo, ê, = u, et ê. = u.",
            TimeActivationSeconds: 1,
        },
        "EGrave", {
            Enabled: True,
            Description: "È + touche Y corrige 2 SFBs : èy = aî et yè = â",
            TimeActivationSeconds: 1,
        },
        "BU", {
            Enabled: True,
            Description: "À + " . ScriptInformation["MagicKey"] . "/B corrige 2 SFBs : à" . ScriptInformation[
                "MagicKey"] . " = bu et àu = ub",
            TimeActivationSeconds: 1,
        },
        "IÉ", {
            Enabled: True,
            Description: "À + É corrige 2 SFBs : éà = ié et àé = éi",
            TimeActivationSeconds: 1,
        },
    ),
    "Rolls", Map(
        "__Order", ["HC", "SX", "CX", "EnglishNegation", "EZ", "CT",
            "-",
            "CloseChevronTag", "ChevronEqual", "Comment",
            "-",
            "Assign", "NotEqual",
            "-",
            "HashtagQuote", "HashtagParenthesis", "HashtagBracket", "EqualString",
            "-",
            "LeftArrow", "AssignArrowEqualRight", "AssignArrowEqualLeft", "AssignArrowMinusRight",
            "AssignArrowMinusLeft"],
        "HC", {
            Enabled: True,
            Description: "HC ➜ WH",
            TimeActivationSeconds: 0.5,
        },
        "SX", {
            Enabled: True,
            Description: "SX ➜ SK",
            TimeActivationSeconds: 0.5,
        },
        "CX", {
            Enabled: True,
            Description: "CX ➜ CK",
            TimeActivationSeconds: 0.5,
        },
        "EnglishNegation", {
            Enabled: True,
            Description: "NT' ➜ = N’T",
            TimeActivationSeconds: 0.5,
        },
        "EZ", {
            Enabled: True,
            Description: "EÉ ➜ EZ",
            TimeActivationSeconds: 0.5,
        },
        "CT", {
            Enabled: True,
            Description: "P' ➜ CT",
            TimeActivationSeconds: 0.5,
        },
        "CloseChevronTag", {
            Enabled: True,
            Description: "<@ ➜ </",
            TimeActivationSeconds: 0.5,
        },
        "ChevronEqual", {
            Enabled: True,
            Description: "<% ➜ <= et >% ➜ >=",
            TimeActivationSeconds: 0.5,
        },
        "Comment", {
            Enabled: True,
            Description: "\`" ➜ /* et `"\`" ➜ */",
            TimeActivationSeconds: 0.5,
        },
        "Assign", {
            Enabled: True,
            Description: "#! ➜ :=",
            TimeActivationSeconds: 0.5,
        },
        "NotEqual", {
            Enabled: True,
            Description: "!# ➜ !=",
            TimeActivationSeconds: 0.5,
        },
        "HashtagQuote", {
            Enabled: True,
            Description: "(# ➜ (`" et [# ➜ [`"",
            TimeActivationSeconds: 1,
        },
        "HashtagParenthesis", {
            Enabled: True,
            Description: "#( ➜ `")",
            TimeActivationSeconds: 0.5,
        },
        "HashtagBracket", {
            Enabled: True,
            Description: "#[ ➜ `"] et #] ➜ `"]",
            TimeActivationSeconds: 0.5,
        },
        "EqualString", {
            Enabled: True,
            Description: "[ ) ➜ = `" `"",
            TimeActivationSeconds: 0.5,
        },
        "LeftArrow", {
            Enabled: True,
            Description: "=+ = ➜",
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowEqualRight", {
            Enabled: True,
            Description: "$= ➜ =>",
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowEqualLeft", {
            Enabled: True,
            Description: "=$ ➜ <=",
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowMinusRight", {
            Enabled: True,
            Description: "+? ➜ ->",
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowMinusLeft", {
            Enabled: True,
            Description: "?+ ➜ <-",
            TimeActivationSeconds: 0.5,
        },
    ),
    "Autocorrection", Map(
        "__Order", [
            "Accents",
            "Names",
            "Brands",
            "-",
            "TypographicApostrophe",
            "-",
            "Errors",
            "OU",
            "MultiplePunctuationMarks",
            "SuffixesAChaining",
            "-",
            "Minus",
            "MinusApostrophe",
        ],
        "TypographicApostrophe", {
            Enabled: True,
            Description: "L’apostrophe devient typographique lors de l’écriture de texte : m'a = m’a, it's = it’s, …",
            TimeActivationSeconds: 1,
        },
        "Errors", {
            Enabled: True,
            Description: "Correction de certaines fautes de frappe : OUi = Oui, aeu = eau, …",
            TimeActivationSeconds: 1,
        },
        "SuffixesAChaining", {
            Enabled: True,
            Description: "Enchaîner plusieurs fois des suffixes, comme aim|able|ement = aimablement",
            TimeActivationSeconds: 1,
        },
        "Accents", {
            Enabled: True,
            Description: "Autocorrection des accents de très nombreux mots",
        },
        "Brands", {
            Enabled: True,
            Description: "Majuscules automatiques aux noms des marques : chatgpt = ChatGPT, powerpoint = PowerPoint, …",
        },
        "Names", {
            Enabled: True,
            Description: "Autocorrection des accents sur les prénoms et les noms de pays : alexei = Alexeï, taiwan = Taïwan, …",
        },
        "Minus", {
            Enabled: True,
            Description: "Évite de devoir taper des tirets : aije = ai-je, atil = a-t-il, … ",
        },
        "MinusApostrophe", {
            Enabled: True,
            Description: "L’apostrophe agit comme un tiret : ai'je = ai-je, a't'il = a-t-il, … ",
        },
        "OU", {
            Enabled: True,
            Description: "Taper [où ] puis un point ou une virgule supprime automatiquement l’espace ajouté avant",
            TimeActivationSeconds: 1,
        },
        "MultiplePunctuationMarks", {
            Enabled: True,
            Description: "Taper `"!`" ou `"?`" plusieurs fois d’affilée n’ajoute pas d’espace insécable entre chaque caractère",
            TimeActivationSeconds: 1,
        },
    ),
    "MagicKey", Map(
        "__Order", [
            "Replace",
            "Repeat",
            "-",
            "TextExpansion",
            "TextExpansionAuto",
            "TextExpansionEmojis",
            "TextExpansionSymbols",
            "TextExpansionSymbolsTypst",
            "-",
            "TextExpansionPersonalInformation",
        ],
        "Replace", {
            Enabled: True,
            Description: "Transformer la touche J en " . ScriptInformation["MagicKey"],
        },
        "Repeat", {
            Enabled: True,
            Description: "La touche " . ScriptInformation["MagicKey"] . " permet la répétition",
        },
        "TextExpansion", {
            Enabled: True,
            Description: "Expansion de texte : c" . ScriptInformation["MagicKey"] . " = c’est, gt" . ScriptInformation[
                "MagicKey"] . " = j’étais, pex" . ScriptInformation["MagicKey"] . " = par exemple, …",
        },
        "TextExpansionAuto", {
            Enabled: True,
            Description: "Expansion de texte sans touche " . ScriptInformation["MagicKey"] .
                " : ju' = jusqu’, ya = y’a, …",
        },
        "TextExpansionEmojis", {
            Enabled: True,
            Description: "Expansion de texte Emojis : voiture" . ScriptInformation["MagicKey"] . " = 🚗, koala" .
                ScriptInformation["MagicKey"] . " = 🐨, …",
        },
        "TextExpansionSymbols", {
            Enabled: True,
            Description: "Expansion de texte Symboles : -->" . ScriptInformation["MagicKey"] . " = ➜, (v)" .
                ScriptInformation["MagicKey"] . " = ✓, …",
        },
        "TextExpansionSymbolsTypst", {
            Enabled: True,
            Description: "Expansion de texte Symboles Typst : $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
        },
        "TextExpansionPersonalInformation", {
            Enabled: True,
            Description: "Remplissage de formulaires avec le suffixe @ : @np" . ScriptInformation["MagicKey"] .
                " = Nom Prénom, etc.",
            PatternMaxLength: 1,
        },
    ),
    "Shortcuts", Map(
        "__Order", [
            "EGrave",
            "ECirc",
            "EAcute",
            "AGrave",
            "-",
            "WrapTextIfSelected",
            "-",
            "MicrosoftBold",
            "Save",
            "CtrlJ",
            "-",
            "AltGrLAlt",
            "AltGrCapsLock",
            "LAltCapsLock",
            "WinCapsLock",
            "-",
            "SelectLine",
            "Screen",
            "GPT",
            "GetHexValue",
            "TakeNote",
            "SurroundWithParentheses",
            "Move",
            "Search",
            "TitleCase",
            "Uppercase",
            "SelectWord"
        ],
        "EGrave", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche È correspondent à ceux de ",
            Letter: "z",
        },
        "ECirc", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche Ê correspondent à ceux de ",
            Letter: "x",
        },
        "EAcute", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche É correspondent à ceux de ",
            Letter: "c",
        },
        "AGrave", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche À correspondent à ceux de ",
            Letter: "v",
        },
        "WrapTextIfSelected", {
            Enabled: True,
            Description: "Taper un symbole lors d'une sélection de texte va encadrer celle-ci par le symbole. Fonctionne si émulation et si UIA/Lib/UIA.ahk dans le dossier du script",
        },
        "MicrosoftBold", {
            Enabled: True,
            Description: "Ctrl + B met en gras dans les applications Microsoft (comme Ctrl + G)",
        },
        "Save", {
            Enabled: False,
            Description: "Ctrl + J/" . ScriptInformation["MagicKey"] . " = Ctrl + S. Attention, Ctrl + J est perdu",
        },
        "CtrlJ", {
            Enabled: False,
            Description: "Ctrl + S = Ctrl + J",
        },
        "AltGrLAlt", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = BackSpace",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = CapsLock",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = CapsWord",
            },
            "CtrlBackSpace", {
                Enabled: True,
                Description: "`"AltGr`" + `"LAlt`" = Ctrl + BackSpace",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Ctrl + Delete",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Delete",
            },
            "Enter", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Entrée",
            },
            "Escape", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Échap",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = OneShotShift",
            },
            "Tab", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Tab",
            },
        ),
        "AltGrCapsLock", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = BackSpace",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = CapsLock",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = CapsWord",
            },
            "CtrlDelete", {
                Enabled: True,
                Description: "`"AltGr`" + `"CapsLock`" = Ctrl + Delete",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Ctrl + BackSpace",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Delete",
            },
            "Enter", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Entrée",
            },
            "Escape", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Échap",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = OneShotShift",
            },
            "Tab", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Tab",
            },
        ),
        "LAltCapsLock", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = BackSpace",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = CapsLock",
            },
            "CapsWord", {
                Enabled: True,
                Description: "`"LAlt`" + `"CapsLock`" = CapsWord",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Ctrl + Delete",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Ctrl + BackSpace",
            },
            "Delete", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Delete",
            },
            "Enter", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Entrée",
            },
            "Escape", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Échap",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = OneShotShift",
            },
            "Tab", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Tab",
            },
        ),
        "WinCapsLock", {
            Enabled: True,
            Description: "Win + `"CapsLock`" = CapsLock",
        },
        "SelectLine", {
            Enabled: True,
            Description: "Win + A(ll) = Sélection de toute la ligne",
        },
        "Screen", {
            Enabled: True,
            Description: "Win + H (screensHot) = Capture de l’écran (réalise le raccourci Win + Shift + S)",
        },
        "GPT", {
            Enabled: True,
            Description: "Win + G(PT) = Ouverture de ChatGPT (site configurable)",
            Link: "https://chatgpt.com/",
        },
        "GetHexValue", {
            Enabled: True,
            Description: "Win + X (heX) = Copie dans le presse-papiers de la couleur HEX du pixel situé sous le curseur",
        },
        "TakeNote", {
            Enabled: True,
            Description: "Win + N(ote) = Ouverture d’un fichier pour prendre des notes",
            DatedNotes: False,
            DestinationFolder: A_Desktop,
        },
        "SurroundWithParentheses", {
            Enabled: True,
            Description: "Win + O = Entoure de parenthèses la ligne",
        },
        "Move", {
            Enabled: True,
            Description: "Win + M(ove) = Simulation d’une activité en bougeant la souris aléatoirement. Pour désactiver, réitérer le raccourci ou recharger le script",
        },
        "Search", {
            Enabled: True,
            Description: "Win + S(earch) = Recherche de la sélection sur Internet. Dans l’explorateur, récupération du chemin du fichier sélectionné",
            SearchEngine: "https://www.google.com",
            SearchEngineURLQuery: "https://www.google.com/search?q=",
        },
        "TitleCase", {
            Enabled: True,
            Description: "Win + T(itleCase) = Conversion en casse de titre (majuscule à chaque première lettre de mot)",
        },
        "Uppercase", {
            Enabled: True,
            Description: "Win + U(ppercase) = Conversion en majuscules/minuscules la sélection",
        },
        "SelectWord", {
            Enabled: True,
            Description: "Win + W(ord) = Sélection du mot là où se trouve le curseur",
        },
    ),
    "TapHolds", Map(
        "__Order", [
            "CapsLock",
            "LShiftCopy",
            "LCtrlPaste",
            "LAlt",
            "Space",
            "AltGr",
            "RCtrl",
            "TabAlt"
        ],
        "CapsLock", Map(
            "__Configuration", {
                TimeActivationSeconds: 0.35,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"CapsLock`" : BackSpace",
            },
            "BackSpaceCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : BackSpace en tap, Ctrl en hold",
            },
            "CapsLockCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : CapsLock en tap, Ctrl en hold",
            },
            "CapsWordCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : CapsWord en tap, Ctrl en hold",
            },
            "CtrlBackSpaceCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Ctrl + BackSpace en tap, Ctrl en hold",
            },
            "CtrlDeleteCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Ctrl + Delete en tap, Ctrl en hold",
            },
            "DeleteCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Delete en tap, Ctrl en hold",
            },
            "EnterCtrl", {
                Enabled: True,
                Description: "`"CapsLock`" : Entrée en tap, Ctrl en hold",
            },
            "EscapeCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Échap en tap, Ctrl en hold",
            },
            "OneShotShiftCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : OneShotShift en tap, Ctrl en hold",
            },
            "TabCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Tab en tap, Ctrl en hold",
            },
        ),
        "LShiftCopy", {
            Enabled: True,
            Description: "`"LShift`" : Ctrl + C en tap, Shift en hold",
            TimeActivationSeconds: 0.35,
        },
        "LCtrlPaste", {
            Enabled: True,
            Description: "`"LCtrl`" : Ctrl + V en tap, Ctrl en hold",
            TimeActivationSeconds: 0.2,
        },
        "LAlt", Map(
            "AltTabMonitor", {
                Enabled: False,
                Description: "`"LAlt`" : Alt+Tab sur le moniteur en tap, Alt en hold",
                TimeActivationSeconds: 0.2,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"LAlt`" : BackSpace. Shift + `"LAlt`" = Delete",
            },
            "BackSpaceLayer", {
                Enabled: True,
                Description: "`"LAlt`" : BackSpace en tap, layer de navigation en hold. Shift + `"LAlt`" = Delete",
                TimeActivationSeconds: 0.2,
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"LAlt`" : OneShotShift en tap, Shift en hold",
            },
            "TabLayer", {
                Enabled: False,
                Description: "`"LAlt`" : Tab en tap, layer de navigation en hold",
                TimeActivationSeconds: 0.2,
            },
        ),
        "Space", Map(
            "Ctrl", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, Ctrl en hold",
                TimeActivationSeconds: 0.15,
            },
            "Layer", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, layer de navigation en hold",
                TimeActivationSeconds: 0.15,
            },
            "Shift", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, Shift en hold",
                TimeActivationSeconds: 0.15,
            },
        ),
        "AltGr", Map(
            "__Configuration", {
                TimeActivationSeconds: 0.2,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" : BackSpace en tap, AltGr en hold",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" : CapsLock en tap, AltGr en hold",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" : CapsWord en tap, AltGr en hold",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"AltGr`" : Ctrl + BackSpace en tap, AltGr en hold",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"AltGr`" : Ctrl + Delete en tap, AltGr en hold",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" : Delete en tap, AltGr en hold",
            },
            "Enter", {
                Enabled: False,
                Description: "`"AltGr`" : Entrée en tap, AltGr en hold",
            },
            "Escape", {
                Enabled: False,
                Description: "`"AltGr`" : Échap en tap, AltGr en hold",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" : OneShotShift en tap, AltGr en hold",
            },
            "Tab", {
                Enabled: True,
                Description: "`"AltGr`" : Tab en tap, AltGr en hold",
            },
        ),
        "RCtrl", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"RCtrl`" : BackSpace. Shift + `"RCtrl`" = Delete"
            },
            "Tab", {
                Enabled: False,
                Description: "`"RCtrl`" : Tab en tap, Ctrl en hold",
                TimeActivationSeconds: 0.2,
            },
            "OneShotShift", {
                Enabled: True,
                Description: "`"RCtrl`" : OneShotShift en tap, Shift en hold",
            },
        ),
        "TabAlt", {
            Enabled: True,
            Description: "`"Tab`" : Alt-Tab sur le moniteur en tap, Alt en hold. À activer pour ne pas perdre Alt",
            TimeActivationSeconds: 0.2,
        },
    ),
)

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
; Edit the script with AltGr + Delete (Suppr.)
RAlt & Delete::
SC138 & SC153::
{
    if (GetKeyState("SC138", "P") and GetKeyState("SC153", "P")) {
        Edit
    } else {
        SendInput("{Delete}")
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

; Here you can add your own hotkeys and hotstrings.
; As they are defined before everything else, they will override any existing definitions if there are duplicates
; Putting everything in this part makes is easy to update your ErgoptiPlus version, as you will only need
; to paste this part into the « 2/ PERSONAL SHORTCUTS » part of the new version.

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
    CreateCaseSensitiveHotstrings(
        "*?", "qa", "qua",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qà", "quà",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qe", "que",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qé", "qué",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qè", "què",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qê", "quê",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qi", "qui",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "qo", "quo",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "q'", "qu’",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "q’", "qu’",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["QU"].TimeActivationSeconds)
    )
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
    CreateCaseSensitiveHotstrings(
        "*?", "êe", "œ",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["ECircumflexE"].TimeActivationSeconds)
    )
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
    ; === Top row ===
    CreateCaseSensitiveHotstrings("*?", ",f", "fl",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",g", "gl",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",h", "ph",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",z", "bj",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )

    ; === Middle row ===
    CreateCaseSensitiveHotstrings("*?", ",v", "dv",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",n", "nl",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",t", "pt",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",r", "rq",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",q", "qu’",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )

    ; === Bottom row ===
    CreateCaseSensitiveHotstrings("*?", ",m", "ms",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",d", "ds",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",l", "cl",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings("*?", ",p", "xp",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["Comma"].TimeActivationSeconds)
    )
}

; ==========================================
; ======= 6.6) SFBs reduction with Ê =======
; ==========================================

if Features["SFBsReduction"]["ECirc"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "êé", "oe",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds
        )
    )
    CreateCaseSensitiveHotstrings(
        "*?", "éê", "eo",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds
        )
    )

    CreateCaseSensitiveHotstrings(
        "*?", "ê.", "u.",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "ê,", "u,",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds)
    )
}

; ==========================================
; ======= 6.7) SFBs reduction with È =======
; ==========================================

if Features["SFBsReduction"]["EGrave"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "yè", "â",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["EGrave"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "èy", "aî",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["EGrave"].TimeActivationSeconds)
    )
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
    CreateHotstring(
        "*?P", "<@", "</",
        Map("TimeActivationSeconds", Features["Rolls"]["CloseChevronTag"].TimeActivationSeconds)
    )
}

; === Middle row ===
if Features["Rolls"]["EZ"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "eé", "ez",
        Map("TimeActivationSeconds", Features["Rolls"]["EZ"].TimeActivationSeconds)
    )
}

; === Bottom row ===
if Features["Rolls"]["Comment"].Enabled {
    CreateHotstring(
        "*?", "\`"", "/*",
        Map("TimeActivationSeconds", Features["Rolls"]["Comment"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "`"\", "*/",
        Map("TimeActivationSeconds", Features["Rolls"]["Comment"].TimeActivationSeconds)
    )
}

; =======================================
; ======= 7.2 Rolls on right hand =======
; =======================================

; === Top row ===
if Features["Rolls"]["HashtagParenthesis"].Enabled {
    CreateHotstring(
        "*?", "#(", "`")",
        Map("TimeActivationSeconds", Features["Rolls"]["HashtagParenthesis"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["HashtagBracket"].Enabled {
    CreateHotstring(
        "*?", "#[", "`"]",
        Map("TimeActivationSeconds", Features["Rolls"]["HashtagBracket"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "#]", "`"]",
        Map("TimeActivationSeconds", Features["Rolls"]["HashtagBracket"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["HC"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "hc", "wh",
        Map("TimeActivationSeconds", Features["Rolls"]["HC"].TimeActivationSeconds)
    )
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
    CreateCaseSensitiveHotstrings("*?", "xlsx", "xlsx") ; To not trigger the replacement in this particular case
    CreateCaseSensitiveHotstrings(
        "*?", "sx", "sk",
        Map("TimeActivationSeconds", Features["Rolls"]["SX"].TimeActivationSeconds)
    )
}
if Features["Rolls"]["CX"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "cx", "ck",
        Map("TimeActivationSeconds", Features["Rolls"]["CX"].TimeActivationSeconds)
    )
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
    CreateHotstring(
        "*?C", "p ?", "p ?",
        Map("TimeActivationSeconds", Features["Rolls"]["CT"].TimeActivationSeconds)
    ) ; Fix "stp ?"
    CreateCaseSensitiveHotstrings(
        "*?", "p'", "ct",
        Map("TimeActivationSeconds", Features["Rolls"]["CT"].TimeActivationSeconds)
    )
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
    CreateCaseSensitiveHotstrings(
        "*", "c'", "c’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "d'", "d’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "j'", "j’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "l'", "l’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "m'", "m’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "n'", "n’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "s'", "s’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "t'", "t’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )

    ; Create all hotstrings y'a → y’a, y'b → y’b, etc.
    ; This prevents false positives like writing ['key'] ➜ ['key’]
    for Letter in StrSplit("abcdefghijklmnopqrstuvwxyz") {
        CreateCaseSensitiveHotstrings(
            "*?", "y'" . Letter, "y’" . Letter,
            Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
        )
    }

    CreateCaseSensitiveHotstrings(
        "*?", "n't", "n’t",  ; words negated with -n’t in English
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
}

; ==========================================
; ======= 8.2) Errors autocorrection =======
; ==========================================

if Features["Autocorrection"]["Errors"].Enabled {
    ; === Prevents getting an underscore instead of space when typing quickly in AltGr
    CreateHotstring(
        "*", "(_", "( ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", ")_", ") ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "+_", "+ ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "#_", "# ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "$_", "$ ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "=_", "= ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "[_", "[ ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "]_", "] ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "~_", "~ ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "*_", "* ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )

    ; === Caps correction ===
    CreateHotstring(
        "*C", "OUi", "Oui",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )

    ; === Letters chaining correction ===
    CreateCaseSensitiveHotstrings(
        "*", "acceuil", "accueil",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "aeu", "eau",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eiu", "ieu",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eua", "eau",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "oiu", "oui",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "oyu", "you",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "poru", "pour",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "sru", "sur",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "uio", "uoi",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "uei", "uie",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
}

if Features["Autocorrection"]["OU"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*", "où .", "où.",
        Map("TimeActivationSeconds", Features["Autocorrection"]["OU"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "où ,", "où, ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["OU"].TimeActivationSeconds)
    )
}

if Features["Autocorrection"]["MultiplePunctuationMarks"].Enabled {
    CreateHotstring(
        "*", " ! !", " !!",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "! !", "!!",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )

    CreateHotstring(
        "*", " ? ?", " ??",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "? ?", "??",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )

    CreateHotstring(
        "*", " ! ?", " !?",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "! ?", "!?",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )

    CreateHotstring(
        "*", " ? !", " ?!",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "? !", "?!",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePunctuationMarks"].TimeActivationSeconds)
    )

    ; We can’t use the TimeActivationSeconds here, as previous character = current character = "."
    Hotstring(
        ":*?B0:" . "...",
        ; Needs to be activated only after a word, otherwise can cause problem in code, like in js: [...a, ...b]
        (*) => GetLastSentCharacterAt(-4) ~= "^[A-Za-z]$" ?
            SendNewResult("{BackSpace 3}…", Map("OnlyText", False)) : ""
    )
}

if Features["Autocorrection"]["SuffixesAChaining"].Enabled {
    CreateCaseSensitiveHotstrings(
        "*?", "eàa", "aire",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàf", "iste",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàl", "elle",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàm", "isme",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàn", "ation",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàp", "ence",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "ieàq", "ique", ; For example "psychologie" + ique
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàq", "ique",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàr", "erre",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàs", "ement",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàt", "ettre",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eàz", "ez-vous",
        Map("TimeActivationSeconds", Features["Autocorrection"]["SuffixesAChaining"].TimeActivationSeconds)
    )
}

; =================================================
; ======= 8.3) Add minus sign automatically =======
; =================================================

if Features["Autocorrection"]["Minus"].Enabled {
    CreateCaseSensitiveHotstrings("", "aije", "ai-je")
    CreateCaseSensitiveHotstrings("", "astu", "as-tu")
    ; CreateCaseSensitiveHotstrings("", "atelle", "a-t-elle") ; Conflict with the word "atelle" for when you are injured
    CreateCaseSensitiveHotstrings("", "atil", "a-t-il")
    CreateCaseSensitiveHotstrings("", "aton", "a-t-on")
    CreateCaseSensitiveHotstrings("", "auratelle", "aura-t-elle")
    CreateCaseSensitiveHotstrings("", "auratil", "aura-t-il")
    CreateCaseSensitiveHotstrings("", "auraton", "aura-t-on")
    CreateCaseSensitiveHotstrings("", "dismoi", "dis-moi")
    CreateCaseSensitiveHotstrings("", "ditelle", "dit-elle")
    CreateCaseSensitiveHotstrings("", "ditil", "dit-il")
    CreateCaseSensitiveHotstrings("", "distu", "dis-tu")
    CreateCaseSensitiveHotstrings("", "diton", "dit-on")
    CreateCaseSensitiveHotstrings("", "doisje", "dois-je")
    CreateCaseSensitiveHotstrings("", "doitelle", "doit-elle")
    CreateCaseSensitiveHotstrings("", "doitil", "doit-il")
    CreateCaseSensitiveHotstrings("", "doiton", "doit-on")
    CreateCaseSensitiveHotstrings("", "estu", "es-tu")
    ; CreateCaseSensitiveHotstrings("", "estelle", "est-elle") ; Conflict with the name Estelle
    CreateCaseSensitiveHotstrings("", "estil", "est-il")
    CreateCaseSensitiveHotstrings("", "eston", "est-on")
    CreateCaseSensitiveHotstrings("", "fautelle", "faut-elle")
    CreateCaseSensitiveHotstrings("", "fautil", "faut-il")
    CreateCaseSensitiveHotstrings("", "fauton", "faut-on")
    CreateCaseSensitiveHotstrings("", "peutil", "peut-il")
    CreateCaseSensitiveHotstrings("", "peutelle", "peut-elle")
    CreateCaseSensitiveHotstrings("", "peuton", "peut-on")
    CreateCaseSensitiveHotstrings("", "peuxtu", "peux-tu")
    CreateCaseSensitiveHotstrings("", "puisje", "puis-je")
    CreateCaseSensitiveHotstrings("", "vatelle", "va-t-elle")
    CreateCaseSensitiveHotstrings("", "vatil", "va-t-il")
    CreateCaseSensitiveHotstrings("", "vaton", "va-t-on")
    CreateCaseSensitiveHotstrings("", "veutelle", "veut-elle")
    CreateCaseSensitiveHotstrings("", "veutil", "veut-il")
    CreateCaseSensitiveHotstrings("", "veuton", "veut-on")
    CreateCaseSensitiveHotstrings("", "veuxtu", "veux-tu")
    CreateCaseSensitiveHotstrings("", "yatil", "y a-t-il")

    CreateCaseSensitiveHotstrings("*?", "vonsn", "vons-n")
    CreateCaseSensitiveHotstrings("*?", "vezv", "vez-v")
}

if Features["Autocorrection"]["MinusApostrophe"].Enabled {
    CreateCaseSensitiveHotstrings("*?", "ai'j", "ai-j")
    CreateCaseSensitiveHotstrings("*?", "ai',", "ai-j")
    CreateCaseSensitiveHotstrings("*?", "as't", "as-t")
    CreateCaseSensitiveHotstrings("*?", "a't", "a-t")
    CreateCaseSensitiveHotstrings("*?", "a-t’e", "a-t-e")  ; Fix typographic apostrophe
    CreateCaseSensitiveHotstrings("*?", "a't'e", "a-t-e")
    CreateCaseSensitiveHotstrings("*?", "a-t’i", "a-t-i")  ; Fix typographic apostrophe
    CreateCaseSensitiveHotstrings("*?", "a't'i", "a-t-i")
    CreateCaseSensitiveHotstrings("*?", "a-t’o", "a-t-o")  ; Fix typographic apostrophe
    CreateCaseSensitiveHotstrings("*?", "a't'o", "a-t-o")
    CreateCaseSensitiveHotstrings("*?", "s',", "s-j")
    CreateCaseSensitiveHotstrings("*?", "s'j", "s-j")
    CreateCaseSensitiveHotstrings("*?", "s'm", "s-m")
    CreateCaseSensitiveHotstrings("*?", "s'n", "s-n")
    CreateCaseSensitiveHotstrings("*?", "s't", "s-t")
    CreateCaseSensitiveHotstrings("*?", "t'e", "t-e")
    CreateCaseSensitiveHotstrings("*?", "t'i", "t-i")
    CreateCaseSensitiveHotstrings("*?", "t'o", "t-o")
    CreateCaseSensitiveHotstrings("*?", "x't", "x-t")
    CreateCaseSensitiveHotstrings("*?", "z'v", "z-v")
}

; ========================================
; ======= 8.4) Caps autocorrection =======
; ========================================

if Features["Autocorrection"]["Brands"].Enabled {
    ; CreateHotstring("", "ai", "AI") ; conflict with j’"ai"
    CreateHotstring("", "api", "API")
    CreateHotstring("", "autohotkey", "AutoHotkey")
    CreateHotstring("", "aws", "AWS")
    CreateHotstring("", "axa", "AXA")
    CreateHotstring("", "azure devops", "Azure DevOps")
    CreateHotstring("", "bdd", "BDD")
    CreateHotstring("", "bdds", "BDDs")
    CreateHotstring("", "catboost", "CatBoost")
    CreateHotstring("", "chatgpt", "ChatGPT")
    CreateHotstring("", "citroen", "Citroën")
    CreateHotstring("", "cli", "CLI")
    CreateHotstring("", "comex", "COMEX")
    CreateHotstring("", "cpu", "CPU")
    CreateHotstring("", "data science", "Data Science")
    CreateHotstring("", "data scientist", "Data Scientist")
    CreateHotstring("", "databricks", "Databricks")
    CreateHotstring("", "docker", "Docker")
    CreateHotstring("", "dynatrace", "Dynatrace")
    CreateHotstring("", "ergopti", "Ergopti")
    CreateHotstring("", "facebook", "Facebook")
    CreateHotstring("", "firefox", "Firefox")
    CreateHotstring("", "gcp", "GCP")
    CreateHotstring("", "github", "GitHub")
    CreateHotstring("", "google", "Google")
    CreateHotstring("", "gpu", "GPU")
    CreateHotstring("", "hammerspoon", "Hammerspoon")
    CreateHotstring("", "ht", "HT")
    CreateHotstring("", "ia", "IA")
    CreateHotstring("", "insee", "INSEE")
    CreateHotstring("", "instagram", "Instagram")
    CreateHotstring("", "intellij", "IntelliJ")
    CreateHotstring("", "json", "JSON")
    CreateHotstring("", "ko", "KO")
    CreateHotstring("", "kpi", "KPI")
    CreateHotstring("", "kpis", "KPIs")
    CreateHotstring("", "latex", "LaTeX")
    CreateHotstring("", "lightgbm", "LightGBM")
    CreateHotstring("", "linux", "Linux")
    CreateHotstring("", "llm", "LLM")
    CreateHotstring("", "llms", "LLMs")
    CreateHotstring("", "lora", "LoRA")
    CreateHotstring("", "lualatex", "LuaLaTeX")
    CreateHotstring("", "macos", "macOS")
    CreateHotstring("", "maj", "MAJ")
    CreateHotstring("", "majs", "MAJs")
    CreateHotstring("", "mbti", "MBTI")
    CreateHotstring("", "mcp", "MCP")
    CreateHotstring("", "ml", "ML")
    CreateHotstring("", "mle", "MLE")
    CreateHotstring("", "mlflow", "MLflow")
    CreateHotstring("", "mlops", "MLOps")
    CreateHotstring("", "nasa", "NASA")
    CreateHotstring("", "nlp", "NLP")
    CreateHotstring("", "ok", "OK")
    CreateHotstring("", "optimot", "Optimot")
    CreateHotstring("", "onedrive", "OneDrive")
    CreateHotstring("", "onenote", "OneNote")
    CreateHotstring("", "openshift", "OpenShift")
    CreateHotstring("", "opentelemetry", "OpenTelemetry")
    CreateHotstring("", "outlook", "Outlook")
    CreateHotstring("", "powerbi", "PowerBI")
    CreateHotstring("", "poc", "POC")
    CreateHotstring("", "pnl", "PNL")
    CreateHotstring("", "powerpoint", "PowerPoint")
    CreateHotstring("", "pr", "PR")
    CreateHotstring("", "qlora", "QLoRA")
    CreateHotstring("", "r", "R")
    CreateHotstring("", "rdc", "RDC")
    CreateHotstring("", "red hat", "Rad Hat")
    CreateHotstring("", "rh", "RH")
    CreateHotstring("", "sas", "SAS")
    CreateHotstring("", "sharepoint", "SharePoint")
    CreateHotstring("", "slm", "SLM")
    CreateHotstring("", "sql", "SQL")
    CreateHotstring("", "ssh", "SSH")
    CreateHotstring("", "ssl", "SSL")
    CreateHotstring("", "tls", "TLS")
    CreateHotstring("", "ttc", "TTC")
    CreateHotstring("", "url", "URL")
    CreateHotstring("", "vscode", "VSCode")
    CreateHotstring("", "wikipedia", "Wikipedia")
    CreateHotstring("", "wikipédia", "Wikipédia")
    CreateHotstring("", "windows", "Windows")
    CreateHotstring("", "xgboost", "XGBoost")
    CreateHotstring("", "youtube", "YouTube")

    ; Cloud / as-a-Service acronyms
    CreateHotstring("", "iaas", "IaaS")
    CreateHotstring("", "paas", "PaaS")
    CreateHotstring("", "saas", "SaaS")
    CreateHotstring("", "caas", "CaaS")
    CreateHotstring("", "faas", "FaaS")
    CreateHotstring("", "dbaas", "DBaaS")

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
    CreateHotstring("", "alexei", "Alexeï")
    CreateHotstring("", "anais", "Anaïs")
    CreateHotstring("", "azerbaidjan", "Azerbaïdjan")
    CreateHotstring("", "benoit", "Benoît")
    CreateHotstring("", "caraibes", "Caraïbes")
    CreateHotstring("", "cleopatre", "Cléopâtre")
    CreateHotstring("", "cléopatre", "Cléopâtre")
    CreateHotstring("", "dubai", "Dubaï")
    CreateHotstring("", "gaetan", "Gaëtan")
    CreateHotstring("", "hanoi", "Hanoï")
    CreateHotstring("", "israel", "Israël")
    CreateHotstring("", "jerome", "Jérôme")
    CreateHotstring("", "jérome", "Jérôme")
    CreateHotstring("", "joel", "Joël")
    ; CreateHotstring("", "michael", "Michaël") ; Probably better to not make it the default, as it is "Michael" Jackson and not Michaël
    CreateHotstring("", "mickael", "Mickaël")
    CreateHotstring("", "noel", "Noël")
    CreateHotstring("*", "Quatar", "Qatar") ; We can use it with the QU feature that way
    CreateHotstring("", "raphael", "Raphaël")
    CreateHotstring("", "serguei", "Sergueï")
    CreateHotstring("", "shanghai", "Shanghaï")
    CreateHotstring("", "taiwan", "Taïwan")
    CreateHotstring("", "thais", "Thaïs")
    CreateHotstring("", "thailande", "Thaïlande")
    CreateHotstring("", "tolstoi", "Tolstoï")
}

if Features["Autocorrection"]["Accents"].Enabled {
    ; === A ===
    CreateCaseSensitiveHotstrings("*", "abim", "abîm")
    CreateCaseSensitiveHotstrings("*", "accroit", "accroît")
    CreateCaseSensitiveHotstrings("*", "affut", "affût")
    CreateCaseSensitiveHotstrings("", "agé", "âgé")
    CreateCaseSensitiveHotstrings("", "agée", "âgée")
    CreateCaseSensitiveHotstrings("", "agés", "âgés")
    CreateCaseSensitiveHotstrings("", "agées", "âgées")
    CreateCaseSensitiveHotstrings("*", "aieul", "aïeul")
    CreateCaseSensitiveHotstrings("*", "aieux", "aïeux")
    CreateCaseSensitiveHotstrings("*", "aigue", "aiguë")
    CreateCaseSensitiveHotstrings("*", "aikido", "aïkido")
    CreateCaseSensitiveHotstrings("*", "ainé", "aîné")
    CreateCaseSensitiveHotstrings("*", "ambigue", "ambiguë")
    CreateCaseSensitiveHotstrings("*", "ambigui", "ambiguï")
    CreateCaseSensitiveHotstrings("", "ame", "âme")
    CreateCaseSensitiveHotstrings("", "ames", "âmes")
    CreateCaseSensitiveHotstrings("", "ane", "âne")
    CreateCaseSensitiveHotstrings("*", "anerie", "ânerie")
    CreateCaseSensitiveHotstrings("", "anes", "ânes")
    CreateCaseSensitiveHotstrings("", "angstrom", "ångström")
    CreateCaseSensitiveHotstrings("*", "apotre", "apôtre")
    CreateCaseSensitiveHotstrings("*", "appat", "appât")
    CreateCaseSensitiveHotstrings("", "apprete", "apprête")
    CreateCaseSensitiveHotstrings("", "appreter", "apprêter")
    CreateCaseSensitiveHotstrings("", "apre", "âpre")
    CreateCaseSensitiveHotstrings("*", "archaique", "archaïque")
    CreateCaseSensitiveHotstrings("*", "archaisme", "archaïsme")
    CreateCaseSensitiveHotstrings("", "archeveque", "archevêque")
    CreateCaseSensitiveHotstrings("", "archeveques", "archevêques")
    CreateCaseSensitiveHotstrings("", "arete", "arête")
    CreateCaseSensitiveHotstrings("", "aretes", "arêtes")
    CreateCaseSensitiveHotstrings("*", "arome", "arôme")
    CreateCaseSensitiveHotstrings("*", "arret", "arrêt")
    CreateCaseSensitiveHotstrings("*", "aout", "août")
    CreateCaseSensitiveHotstrings("*", "aumone", "aumône")
    CreateCaseSensitiveHotstrings("*", "aumonier", "aumônier")
    CreateCaseSensitiveHotstrings("*", "aussitot", "aussitôt")
    CreateCaseSensitiveHotstrings("*", "avant-gout", "avant-goût")

    ; === B ===
    CreateCaseSensitiveHotstrings("*", "babord", "bâbord")
    CreateCaseSensitiveHotstrings("*", "baille", "bâille")
    CreateCaseSensitiveHotstrings("*", "baillon", "bâillon")
    CreateCaseSensitiveHotstrings("*", "baionnette", "baïonnette")
    CreateCaseSensitiveHotstrings("*", "batard", "bâtard")
    CreateCaseSensitiveHotstrings("*", "bati", "bâti")
    CreateCaseSensitiveHotstrings("*", "baton", "bâton")
    CreateCaseSensitiveHotstrings("", "beche", "bêche")
    CreateCaseSensitiveHotstrings("", "beches", "bêches")
    CreateCaseSensitiveHotstrings("", "benet", "benêt")
    CreateCaseSensitiveHotstrings("", "benets", "benêts")
    CreateCaseSensitiveHotstrings("*", "bete", "bête")
    CreateCaseSensitiveHotstrings("*", "betis", "bêtis")
    CreateCaseSensitiveHotstrings("*", "bientot", "bientôt")
    CreateCaseSensitiveHotstrings("*", "binome", "binôme")
    CreateCaseSensitiveHotstrings("*", "blamer", "blâmer")
    CreateCaseSensitiveHotstrings("", "bleme", "blême")
    CreateCaseSensitiveHotstrings("", "blemes", "blêmes")
    CreateCaseSensitiveHotstrings("", "blemir", "blêmir")
    CreateCaseSensitiveHotstrings("", "blémir", "blêmir")
    CreateCaseSensitiveHotstrings("*", "boeuf", "bœuf")
    CreateCaseSensitiveHotstrings("*?", "boite", "boîte")
    CreateCaseSensitiveHotstrings("*", "brul", "brûl")
    CreateCaseSensitiveHotstrings("*", "buche", "bûche")

    ; === C ===
    CreateCaseSensitiveHotstrings("*", "calin", "câlin")
    CreateCaseSensitiveHotstrings("*", "canoe", "canoë")
    CreateCaseSensitiveHotstrings("*", "prochaine", "prochaine")
    CreateCaseSensitiveHotstrings("*?", "chaine", "chaîne")
    CreateCaseSensitiveHotstrings("*?", "chaîned", "chained")
    CreateCaseSensitiveHotstrings("*?", "chainé", "chaîné")
    CreateCaseSensitiveHotstrings("", "chassis", "châssis")
    CreateCaseSensitiveHotstrings("*", "chateau", "château")
    CreateCaseSensitiveHotstrings("*", "chatier", "châtier")
    CreateCaseSensitiveHotstrings("*", "chatiment", "châtiment")
    CreateCaseSensitiveHotstrings("*", "chomage", "chômage")
    CreateCaseSensitiveHotstrings("", "chomer", "chômer")
    CreateCaseSensitiveHotstrings("*", "chomeu", "chômeu")
    CreateCaseSensitiveHotstrings("*", "chomé", "chômé")
    CreateCaseSensitiveHotstrings("*", "cloture", "clôture")
    CreateCaseSensitiveHotstrings("*", "cloturé", "clôturé")
    CreateCaseSensitiveHotstrings("*", "cocaine", "cocaïne")
    CreateCaseSensitiveHotstrings("*", "cocaino", "cocaïno")
    CreateCaseSensitiveHotstrings("*", "coeur", "cœur")
    CreateCaseSensitiveHotstrings("*", "coincide", "coïncide")
    CreateCaseSensitiveHotstrings("*?", "connait", "connaît")
    CreateCaseSensitiveHotstrings("*", "controle", "contrôle")
    CreateCaseSensitiveHotstrings("*", "controlé", "contrôlé")
    CreateCaseSensitiveHotstrings("", "cout", "coût")
    CreateCaseSensitiveHotstrings("", "coute", "coûte")
    CreateCaseSensitiveHotstrings("", "couter", "coûter")
    CreateCaseSensitiveHotstrings("*", "couteu", "coûteu")
    CreateCaseSensitiveHotstrings("", "couts", "coûts")
    CreateCaseSensitiveHotstrings("", "cote", "côte")
    CreateCaseSensitiveHotstrings("", "cotes", "côtes")
    CreateCaseSensitiveHotstrings("*", "cotoie", "côtoie")
    CreateCaseSensitiveHotstrings("*", "cotoy", "côtoy")
    CreateCaseSensitiveHotstrings("*?", "croitre", "croître")
    CreateCaseSensitiveHotstrings("*", "crouton", "croûton")

    ; === D ===
    CreateCaseSensitiveHotstrings("*", "débacle", "débâcle")
    CreateCaseSensitiveHotstrings("*", "dégat", "dégât")
    CreateCaseSensitiveHotstrings("*", "dégout", "dégoût")
    CreateCaseSensitiveHotstrings("*", "dépech", "dépêch")
    CreateCaseSensitiveHotstrings("", "dépot", "dépôt")
    CreateCaseSensitiveHotstrings("", "dépots", "dépôts")
    ; CreateCaseSensitiveHotstrings("", "diner", "dîner") ; Conflict in English
    CreateCaseSensitiveHotstrings("*", "diplome", "diplôme")
    CreateCaseSensitiveHotstrings("*", "diplomé", "diplômé")
    CreateCaseSensitiveHotstrings("*", "drole", "drôle")
    CreateCaseSensitiveHotstrings("", "dument", "dûment")

    ; === E ===
    CreateCaseSensitiveHotstrings("*", "egoisme", "egoïsme")
    CreateCaseSensitiveHotstrings("*", "égoisme", "égoïsme")
    CreateCaseSensitiveHotstrings("*", "egoiste", "egoïste")
    CreateCaseSensitiveHotstrings("*", "égoiste", "égoïste")
    CreateCaseSensitiveHotstrings("*", "elle-meme", "elle-même")
    CreateCaseSensitiveHotstrings("*", "elles-meme", "elles-mêmes")
    CreateCaseSensitiveHotstrings("*", "elles-memes", "elles-mêmes")
    CreateCaseSensitiveHotstrings("*", "embet", "embêt")
    CreateCaseSensitiveHotstrings("*", "embuch", "embûch")
    CreateCaseSensitiveHotstrings("*", "empeche", "empêche")
    CreateCaseSensitiveHotstrings("*", "enchaine", "enchaîne")
    CreateCaseSensitiveHotstrings("*", "enjoleu", "enjôleu")
    CreateCaseSensitiveHotstrings("*", "enrole", "enrôle")
    CreateCaseSensitiveHotstrings("*", "entete", "entête")
    CreateCaseSensitiveHotstrings("*", "enteté", "entêté")
    CreateCaseSensitiveHotstrings("*", "entraina", "entraîna")
    CreateCaseSensitiveHotstrings("*", "entraine", "entraîne")
    CreateCaseSensitiveHotstrings("*", "entrainé", "entraîné")
    CreateCaseSensitiveHotstrings("*", "entrepot", "entrepôt")
    CreateCaseSensitiveHotstrings("*", "envout", "envoût")
    CreateCaseSensitiveHotstrings("*", "eux-meme", "eux-mêmes")

    ; === F ===
    CreateCaseSensitiveHotstrings("*", "fache", "fâche")
    CreateCaseSensitiveHotstrings("*", "faché", "fâché")
    CreateCaseSensitiveHotstrings("*", "fantom", "fantôm")
    CreateCaseSensitiveHotstrings("*", "fenetre", "fenêtre")
    CreateCaseSensitiveHotstrings("*", "felure", "fêlure")
    CreateCaseSensitiveHotstrings("*", "félure", "fêlure")
    CreateCaseSensitiveHotstrings("", "fete", "fête")
    CreateCaseSensitiveHotstrings("", "feter", "fêter")
    CreateCaseSensitiveHotstrings("", "fetes", "fêtes")
    CreateCaseSensitiveHotstrings("", "flane", "flâne")
    CreateCaseSensitiveHotstrings("", "flaner", "flâner")
    CreateCaseSensitiveHotstrings("", "flanes", "flânes")
    CreateCaseSensitiveHotstrings("*", "flaneu", "flâneu")
    CreateCaseSensitiveHotstrings("", "flanez", "flânez")
    CreateCaseSensitiveHotstrings("", "flanons", "flânons")
    CreateCaseSensitiveHotstrings("", "flute", "flûte")
    CreateCaseSensitiveHotstrings("", "flutes", "flûtes")
    CreateCaseSensitiveHotstrings("*", "foetus", "fœtus")
    CreateCaseSensitiveHotstrings("*", "foret", "forêt")
    CreateCaseSensitiveHotstrings("*?", "fraich", "fraîch")
    CreateCaseSensitiveHotstrings("*", "frole", "frôle")

    ; === G ===
    CreateCaseSensitiveHotstrings("*", "gach", "gâch")
    CreateCaseSensitiveHotstrings("*", "gateau", "gâteau")
    CreateCaseSensitiveHotstrings("", "gater", "gâter")
    CreateCaseSensitiveHotstrings("", "gaté", "gâté")
    CreateCaseSensitiveHotstrings("", "gatés", "gâtés")
    CreateCaseSensitiveHotstrings("*", "genant", "gênant")
    CreateCaseSensitiveHotstrings("", "gener", "gêner")
    CreateCaseSensitiveHotstrings("*", "génant", "gênant")
    CreateCaseSensitiveHotstrings("", "génants", "gênants")
    CreateCaseSensitiveHotstrings("*", "geole", "geôle")
    CreateCaseSensitiveHotstrings("*?", "geolier", "geôlier")
    CreateCaseSensitiveHotstrings("*?", "geoliè", "geôliè")
    CreateCaseSensitiveHotstrings("", "gout", "goût")
    CreateCaseSensitiveHotstrings("", "gouta", "goûta")
    CreateCaseSensitiveHotstrings("", "goute", "goûte")
    CreateCaseSensitiveHotstrings("", "gouter", "goûter")
    CreateCaseSensitiveHotstrings("", "goutes", "goûtes")
    CreateCaseSensitiveHotstrings("", "goutez", "goûtez")
    CreateCaseSensitiveHotstrings("", "goutons", "goûtons")
    CreateCaseSensitiveHotstrings("", "grele", "grêle")
    CreateCaseSensitiveHotstrings("", "grèle", "grêle")
    CreateCaseSensitiveHotstrings("*", "greler", "grêler")
    CreateCaseSensitiveHotstrings("*", "guepe", "guêpe")

    ; === H ===
    CreateCaseSensitiveHotstrings("*", "heroique", "héroïque")
    CreateCaseSensitiveHotstrings("*", "heroisme", "héroïsme")
    CreateCaseSensitiveHotstrings("*", "héroique", "héroïque")
    CreateCaseSensitiveHotstrings("*", "héroisme", "héroïsme")
    CreateCaseSensitiveHotstrings("*?", "honnete", "honnête")
    CreateCaseSensitiveHotstrings("*", "hopita", "hôpita")
    CreateCaseSensitiveHotstrings("*", "huitre", "huître")

    ; === I ===
    CreateCaseSensitiveHotstrings("*", "icone", "icône")
    CreateCaseSensitiveHotstrings("*", "idolatr", "idolâtr")
    CreateCaseSensitiveHotstrings("", "ile", "île")
    CreateCaseSensitiveHotstrings("", "iles", "îles")
    CreateCaseSensitiveHotstrings("", "ilot", "îlot")
    CreateCaseSensitiveHotstrings("", "ilots", "îlots")
    CreateCaseSensitiveHotstrings("", "impot", "impôt")
    CreateCaseSensitiveHotstrings("", "impots", "impôts")
    CreateCaseSensitiveHotstrings("", "indu", "indû")
    CreateCaseSensitiveHotstrings("*", "indument", "indûment")
    CreateCaseSensitiveHotstrings("", "indus", "indûs")
    CreateCaseSensitiveHotstrings("*", "infame", "infâme")
    CreateCaseSensitiveHotstrings("*", "infamie", "infâmie")
    CreateCaseSensitiveHotstrings("*", "inoui", "inouï")
    CreateCaseSensitiveHotstrings("*", "interet", "intérêt")
    CreateCaseSensitiveHotstrings("*", "intéret", "intérêt")

    ; === J ===
    CreateCaseSensitiveHotstrings("*", "jeuner", "jeûner")

    ; === K ===

    ; === L ===
    CreateCaseSensitiveHotstrings("*", "lache", "lâche")
    CreateCaseSensitiveHotstrings("*", "laique", "laïque")
    CreateCaseSensitiveHotstrings("*", "laius", "laïus")
    CreateCaseSensitiveHotstrings("*", "les notres", "les nôtres")
    CreateCaseSensitiveHotstrings("*", "les votres", "les vôtres")
    CreateCaseSensitiveHotstrings("*", "lui-meme", "lui-même")

    ; === M ===
    CreateCaseSensitiveHotstrings("*", "m'apprete", "m'apprête")
    CreateCaseSensitiveHotstrings("*", "m’apprete", "m’apprête")
    CreateCaseSensitiveHotstrings("", "mache", "mâche")
    CreateCaseSensitiveHotstrings("", "macher", "mâcher")
    CreateCaseSensitiveHotstrings("*", "machoire", "mâchoire")
    CreateCaseSensitiveHotstrings("*", "machouill", "mâchouill")
    CreateCaseSensitiveHotstrings("*", "maelstrom", "maelström")
    CreateCaseSensitiveHotstrings("*", "malstrom", "malström")
    CreateCaseSensitiveHotstrings("*", "maitr", "maîtr")
    CreateCaseSensitiveHotstrings("", "male", "mâle")
    CreateCaseSensitiveHotstrings("", "males", "mâles")
    CreateCaseSensitiveHotstrings("*", "manoeuvr", "manœuvr")
    CreateCaseSensitiveHotstrings("*", "maratre", "marâtre")
    CreateCaseSensitiveHotstrings("*?", "meler", "mêler")
    CreateCaseSensitiveHotstrings("", "mome", "môme")
    CreateCaseSensitiveHotstrings("", "momes", "mômes")
    CreateCaseSensitiveHotstrings("*", "mosaique", "mosaïque")
    CreateCaseSensitiveHotstrings("*", "multitache", "multitâche")
    CreateCaseSensitiveHotstrings("*", "murement", "mûrement")
    CreateCaseSensitiveHotstrings("*", "murir", "mûrir")

    ; === N ===
    CreateCaseSensitiveHotstrings("", "naif", "naïf")
    CreateCaseSensitiveHotstrings("*", "naifs", "naïfs")
    CreateCaseSensitiveHotstrings("*", "naivement", "naïvement")
    CreateCaseSensitiveHotstrings("*", "naives", "naïves")
    CreateCaseSensitiveHotstrings("*", "naitre", "naître")
    CreateCaseSensitiveHotstrings("*", "noeud", "nœud")

    ; === O ===
    CreateCaseSensitiveHotstrings("*", "oecuméni", "œcuméni")
    CreateCaseSensitiveHotstrings("*", "oeil", "œil")
    CreateCaseSensitiveHotstrings("*", "oesophage", "œsophage")
    CreateCaseSensitiveHotstrings("*", "oeuf", "œuf")
    CreateCaseSensitiveHotstrings("*", "oeuvre", "œuvre")
    CreateCaseSensitiveHotstrings("*?", "oiaque", "oïaque") ; Suffixes like paran-oïaque
    CreateCaseSensitiveHotstrings("*?", "froide", "froide") ; Fixes this particular word to not get froïde
    CreateCaseSensitiveHotstrings("*?", "oide", "oïde") ; Suffixes like ov-oïde
    CreateCaseSensitiveHotstrings("*", "opiniatre", "opiniâtre")
    CreateCaseSensitiveHotstrings("*", "ouie", "ouïe")
    CreateCaseSensitiveHotstrings("", "oter", "ôter")

    ; === P ===
    CreateCaseSensitiveHotstrings("*", "paella", "paëlla")
    CreateCaseSensitiveHotstrings("*", "palir", "pâlir")
    CreateCaseSensitiveHotstrings("*?", "parait", "paraît")
    CreateCaseSensitiveHotstrings("*?", "paranoia", "paranoïa")
    CreateCaseSensitiveHotstrings("", "paté", "pâté")
    CreateCaseSensitiveHotstrings("", "patés", "pâtés")
    CreateCaseSensitiveHotstrings("", "pate", "pâte")
    CreateCaseSensitiveHotstrings("", "pates", "pâtes")
    CreateCaseSensitiveHotstrings("*", "patir", "pâtir")
    CreateCaseSensitiveHotstrings("*", "patiss", "pâtiss")
    CreateCaseSensitiveHotstrings("*", "patur", "pâtur")
    CreateCaseSensitiveHotstrings("", "peche", "pêche")
    CreateCaseSensitiveHotstrings("", "pecher", "pêcher")
    CreateCaseSensitiveHotstrings("", "peches", "pêches")
    CreateCaseSensitiveHotstrings("*", "pecheu", "pêcheu")
    CreateCaseSensitiveHotstrings("*", "pentecote", "Pentecôte")
    CreateCaseSensitiveHotstrings("*", "phoenix", "phœnix")
    CreateCaseSensitiveHotstrings("*", "photovoltai", "photovoltaï")
    CreateCaseSensitiveHotstrings("*", "piqure", "piqûre")
    CreateCaseSensitiveHotstrings("", "plait", "plaît")
    CreateCaseSensitiveHotstrings("*", "platre", "plâtre")
    CreateCaseSensitiveHotstrings("*", "plutot", "plutôt")
    CreateCaseSensitiveHotstrings("*", "poele", "poêle")
    CreateCaseSensitiveHotstrings("*", "polynom", "polynôm")
    CreateCaseSensitiveHotstrings("", "pret", "prêt")
    CreateCaseSensitiveHotstrings("", "prets", "prêts")
    CreateCaseSensitiveHotstrings("*", "prosaique", "prosaïque")
    CreateCaseSensitiveHotstrings("*", "pylone", "pylône")

    ; === Q ===
    CreateCaseSensitiveHotstrings("*", "quete", "quête")

    ; === R ===
    CreateCaseSensitiveHotstrings("*", "raler", "râler")
    CreateCaseSensitiveHotstrings("*", "relache", "relâche")
    CreateCaseSensitiveHotstrings("*", "revasse", "rêvasse")
    CreateCaseSensitiveHotstrings("", "reve", "rêve")
    CreateCaseSensitiveHotstrings("", "rever", "rêver")
    CreateCaseSensitiveHotstrings("", "reverie", "rêverie")
    CreateCaseSensitiveHotstrings("", "reves", "rêves")
    CreateCaseSensitiveHotstrings("*", "requete", "requête")
    CreateCaseSensitiveHotstrings("*", "roti", "rôti")

    ; === S ===
    CreateCaseSensitiveHotstrings("*", "salpetre", "salpêtre")
    CreateCaseSensitiveHotstrings("*", "samourai", "samouraï")
    CreateCaseSensitiveHotstrings("*", "soeur", "sœur")
    CreateCaseSensitiveHotstrings("", "soule", "soûle")
    CreateCaseSensitiveHotstrings("*", "souler", "soûler")
    CreateCaseSensitiveHotstrings("", "soules", "soûles")
    CreateCaseSensitiveHotstrings("*", "soulé", "soûlé")
    CreateCaseSensitiveHotstrings("*", "stoique", "stoïque")
    CreateCaseSensitiveHotstrings("*", "stoicisme", "stoïcisme")
    ; CreateCaseSensitiveHotstrings("", "sure", "sûre") ; Conflict with "to be sure"
    CreateCaseSensitiveHotstrings("*", "surement", "sûrement")
    CreateCaseSensitiveHotstrings("*", "sureté", "sûreté")
    CreateCaseSensitiveHotstrings("*", "surcout", "surcoût")
    CreateCaseSensitiveHotstrings("*", "surcroit", "surcroît")
    CreateCaseSensitiveHotstrings("", "surs", "sûrs")
    CreateCaseSensitiveHotstrings("*?", "symptom", "symptôm")

    ; === T ===
    CreateCaseSensitiveHotstrings("*", "tantot", "tantôt")
    CreateCaseSensitiveHotstrings("", "tete", "tête")
    CreateCaseSensitiveHotstrings("", "tetes", "têtes")
    CreateCaseSensitiveHotstrings("*", "theatr", "théâtr")
    CreateCaseSensitiveHotstrings("*", "théatr", "théâtr")
    CreateCaseSensitiveHotstrings("", "tole", "tôle")
    CreateCaseSensitiveHotstrings("", "toles", "tôles")
    ; CreateCaseSensitiveHotstrings("", "tot", "tôt") ; Deactivated to be able to use the abbreviation "tot" for total
    CreateCaseSensitiveHotstrings("*", "traitr", "traîtr")
    CreateCaseSensitiveHotstrings("", "treve", "trêve")
    CreateCaseSensitiveHotstrings("", "treves", "trêves")
    CreateCaseSensitiveHotstrings("*", "trinome", "trinôme")
    CreateCaseSensitiveHotstrings("*?*", "trone", "trône")
    CreateCaseSensitiveHotstrings("*", "tempete", "tempête")

    ; === U ===

    ; === V ===
    CreateCaseSensitiveHotstrings("*?", "vetement", "vêtement")
    CreateCaseSensitiveHotstrings("*", "voeu", "vœu")

    ; === W ===

    ; === X ===

    ; === Y ===

    ; === Z ===
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
    CreateCaseSensitiveHotstrings(
        "*?", "àa", "aire",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àc", "ction",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )

    ; À + d = "could", "should" or "would" depending on the prefix
    CreateCaseSensitiveHotstrings(
        "*?", "càd", "could",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "shàd", "should",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àd", "would",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )

    CreateCaseSensitiveHotstrings(
        "*?", "àê", "able",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àf", "iste",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àg", "ought",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àh", "ight",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "ài", "ying",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àk", "ique",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àl", "elle",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àp", "ence",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àm", "isme",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àn", "ation",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àq", "ique",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àr", "erre",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "às", "ement",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àt", "ettre",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àv", "ment",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àx", "ieux",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "àz", "ez-vous",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "à'", "ance",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "à’", "ance",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
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

; ===========================================
; ======= 9.3) TEXT EXPANSION WITH ★ =======
; ===========================================

if Features["MagicKey"]["TextExpansion"].Enabled {
    ; === Alphabetic ligatures ===
    CreateCaseSensitiveHotstrings("*?", "ae" . ScriptInformation["MagicKey"], "æ")
    CreateCaseSensitiveHotstrings("*?", "oe" . ScriptInformation["MagicKey"], "œ")

    ; === Numbers and symbols ===
    CreateCaseSensitiveHotstrings("*", "1er" . ScriptInformation["MagicKey"], "premier")
    CreateCaseSensitiveHotstrings("*", "1ere" . ScriptInformation["MagicKey"], "première")
    CreateCaseSensitiveHotstrings("*", "2e" . ScriptInformation["MagicKey"], "deuxième")
    CreateCaseSensitiveHotstrings("*", "3e" . ScriptInformation["MagicKey"], "troisième")
    CreateCaseSensitiveHotstrings("*", "4e" . ScriptInformation["MagicKey"], "quatrième")
    CreateCaseSensitiveHotstrings("*", "5e" . ScriptInformation["MagicKey"], "cinquième")
    CreateCaseSensitiveHotstrings("*", "6e" . ScriptInformation["MagicKey"], "sixième")
    CreateCaseSensitiveHotstrings("*", "7e" . ScriptInformation["MagicKey"], "septième")
    CreateCaseSensitiveHotstrings("*", "8e" . ScriptInformation["MagicKey"], "huitième")
    CreateCaseSensitiveHotstrings("*", "9e" . ScriptInformation["MagicKey"], "neuvième")
    CreateCaseSensitiveHotstrings("*", "10e" . ScriptInformation["MagicKey"], "dixième")
    CreateCaseSensitiveHotstrings("*", "11e" . ScriptInformation["MagicKey"], "onzième")
    CreateCaseSensitiveHotstrings("*", "12e" . ScriptInformation["MagicKey"], "douzième")
    CreateCaseSensitiveHotstrings("*", "20e" . ScriptInformation["MagicKey"], "vingtième")
    CreateCaseSensitiveHotstrings("*", "100e" . ScriptInformation["MagicKey"], "centième")
    CreateCaseSensitiveHotstrings("*", "1000e" . ScriptInformation["MagicKey"], "millième")
    CreateCaseSensitiveHotstrings("*", "2s" . ScriptInformation["MagicKey"], "2 secondes")
    CreateCaseSensitiveHotstrings("*", "//" . ScriptInformation["MagicKey"], "rapport")
    CreateCaseSensitiveHotstrings("*", "+m" . ScriptInformation["MagicKey"], "meilleur")

    ; === A ===
    CreateCaseSensitiveHotstrings("*", "a" . ScriptInformation["MagicKey"], "ainsi")
    CreateCaseSensitiveHotstrings("*", "abr" . ScriptInformation["MagicKey"], "abréviation")
    CreateCaseSensitiveHotstrings("*", "actu" . ScriptInformation["MagicKey"], "actualité")
    CreateCaseSensitiveHotstrings("*", "add" . ScriptInformation["MagicKey"], "addresse")
    CreateCaseSensitiveHotstrings("*", "admin" . ScriptInformation["MagicKey"], "administrateur")
    CreateCaseSensitiveHotstrings("*", "afr" . ScriptInformation["MagicKey"], "à faire")
    CreateCaseSensitiveHotstrings("*", "ah" . ScriptInformation["MagicKey"], "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "ahk" . ScriptInformation["MagicKey"], "autohotkey")
    CreateCaseSensitiveHotstrings("*", "ajd" . ScriptInformation["MagicKey"], "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "algo" . ScriptInformation["MagicKey"], "algorithme")
    CreateCaseSensitiveHotstrings("*", "alpha" . ScriptInformation["MagicKey"], "alphabétique")
    CreateCaseSensitiveHotstrings("*", "amé" . ScriptInformation["MagicKey"], "amélioration")
    CreateCaseSensitiveHotstrings("*", "amélio" . ScriptInformation["MagicKey"], "amélioration")
    CreateCaseSensitiveHotstrings("*", "anc" . ScriptInformation["MagicKey"], "ancien")
    CreateCaseSensitiveHotstrings("*", "ano" . ScriptInformation["MagicKey"], "anomalie")
    CreateCaseSensitiveHotstrings("*", "anniv" . ScriptInformation["MagicKey"], "anniversaire")
    CreateCaseSensitiveHotstrings("*", "apm" . ScriptInformation["MagicKey"], "après-midi")
    CreateCaseSensitiveHotstrings("*", "apad" . ScriptInformation["MagicKey"], "à partir de")
    CreateCaseSensitiveHotstrings("*", "app" . ScriptInformation["MagicKey"], "application")
    CreateCaseSensitiveHotstrings("*", "appart" . ScriptInformation["MagicKey"], "appartement")
    CreateCaseSensitiveHotstrings("*", "appli" . ScriptInformation["MagicKey"], "application")
    CreateCaseSensitiveHotstrings("*", "approx" . ScriptInformation["MagicKey"], "approximation")
    CreateCaseSensitiveHotstrings("*", "archi" . ScriptInformation["MagicKey"], "architecture")
    CreateCaseSensitiveHotstrings("*", "arg" . ScriptInformation["MagicKey"], "argument")
    CreateCaseSensitiveHotstrings("*", "asso" . ScriptInformation["MagicKey"], "association")
    CreateCaseSensitiveHotstrings("*", "asap" . ScriptInformation["MagicKey"], "le plus rapidement possible")
    CreateCaseSensitiveHotstrings("*", "atd" . ScriptInformation["MagicKey"], "attend")
    CreateCaseSensitiveHotstrings("*", "att" . ScriptInformation["MagicKey"], "attention")
    CreateCaseSensitiveHotstrings("*", "aud" . ScriptInformation["MagicKey"], "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "aug" . ScriptInformation["MagicKey"], "augmentation")
    CreateCaseSensitiveHotstrings("*", "auj" . ScriptInformation["MagicKey"], "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "auto" . ScriptInformation["MagicKey"], "automatique")
    CreateCaseSensitiveHotstrings("*", "av" . ScriptInformation["MagicKey"], "avant")
    CreateCaseSensitiveHotstrings("*", "avv" . ScriptInformation["MagicKey"], "avez-vous")
    CreateCaseSensitiveHotstrings("*", "avvd" . ScriptInformation["MagicKey"], "avez-vous déjà")

    ; === B ===
    CreateCaseSensitiveHotstrings("*", "b" . ScriptInformation["MagicKey"], "bonjour")
    CreateCaseSensitiveHotstrings("*", "bc" . ScriptInformation["MagicKey"], "because")
    CreateCaseSensitiveHotstrings("*", "bcp" . ScriptInformation["MagicKey"], "beaucoup")
    CreateCaseSensitiveHotstrings("*", "bdd" . ScriptInformation["MagicKey"], "base de données")
    CreateCaseSensitiveHotstrings("*", "bdds" . ScriptInformation["MagicKey"], "bases de données")
    CreateCaseSensitiveHotstrings("*", "bea" . ScriptInformation["MagicKey"], "beaucoup")
    CreateCaseSensitiveHotstrings("*", "bec" . ScriptInformation["MagicKey"], "because")
    CreateCaseSensitiveHotstrings("*", "bib" . ScriptInformation["MagicKey"], "bibliographie")
    CreateCaseSensitiveHotstrings("*", "biblio" . ScriptInformation["MagicKey"], "bibliographie")
    CreateCaseSensitiveHotstrings("*", "bjr" . ScriptInformation["MagicKey"], "bonjour")
    CreateCaseSensitiveHotstrings("*", "brain" . ScriptInformation["MagicKey"], "brainstorming")
    CreateCaseSensitiveHotstrings("*", "br" . ScriptInformation["MagicKey"], "bonjour")
    CreateCaseSensitiveHotstrings("*", "bsr" . ScriptInformation["MagicKey"], "bonsoir")
    CreateCaseSensitiveHotstrings("*", "bv" . ScriptInformation["MagicKey"], "bravo")
    CreateCaseSensitiveHotstrings("*", "bvn" . ScriptInformation["MagicKey"], "bienvenue")
    CreateCaseSensitiveHotstrings("*", "bwe" . ScriptInformation["MagicKey"], "bon week-end")
    CreateCaseSensitiveHotstrings("*", "bwk" . ScriptInformation["MagicKey"], "bon week-end")

    ; === C ===
    CreateCaseSensitiveHotstrings("*", "c" . ScriptInformation["MagicKey"], "c’est")
    CreateCaseSensitiveHotstrings("*", "cad" . ScriptInformation["MagicKey"], "c’est-à-dire")
    CreateCaseSensitiveHotstrings("*", "camp" . ScriptInformation["MagicKey"], "campagne")
    CreateCaseSensitiveHotstrings("*", "carac" . ScriptInformation["MagicKey"], "caractère")
    CreateCaseSensitiveHotstrings("*", "caract" . ScriptInformation["MagicKey"], "caractéristique")
    CreateCaseSensitiveHotstrings("*", "cb" . ScriptInformation["MagicKey"], "combien")
    CreateCaseSensitiveHotstrings("*", "cc" . ScriptInformation["MagicKey"], "copier-coller")
    CreateCaseSensitiveHotstrings("*", "ccé" . ScriptInformation["MagicKey"], "copié-collé")
    CreateCaseSensitiveHotstrings("*", "ccl" . ScriptInformation["MagicKey"], "conclusion")
    CreateHotstring("*", "cdg" . ScriptInformation["MagicKey"], "Charles de Gaulle")
    CreateCaseSensitiveHotstrings("*", "cdt" . ScriptInformation["MagicKey"], "cordialement")
    CreateCaseSensitiveHotstrings("*", "certif" . ScriptInformation["MagicKey"], "certification")
    CreateCaseSensitiveHotstrings("*", "chg" . ScriptInformation["MagicKey"], "charge")
    CreateCaseSensitiveHotstrings("*", "chap" . ScriptInformation["MagicKey"], "chapitre")
    CreateCaseSensitiveHotstrings("*", "chr" . ScriptInformation["MagicKey"], "chercher")
    CreateCaseSensitiveHotstrings("*", "ci" . ScriptInformation["MagicKey"], "ci-joint")
    CreateCaseSensitiveHotstrings("*", "cj" . ScriptInformation["MagicKey"], "ci-joint")
    CreateCaseSensitiveHotstrings("*", "coeff" . ScriptInformation["MagicKey"], "coefficient")
    CreateCaseSensitiveHotstrings("*", "cog" . ScriptInformation["MagicKey"], "cognition")
    CreateCaseSensitiveHotstrings("*", "cogv" . ScriptInformation["MagicKey"], "cognitive")
    CreateCaseSensitiveHotstrings("*", "comp" . ScriptInformation["MagicKey"], "comprendre")
    CreateCaseSensitiveHotstrings("*", "cond" . ScriptInformation["MagicKey"], "condition")
    CreateCaseSensitiveHotstrings("*", "conds" . ScriptInformation["MagicKey"], "conditions")
    CreateCaseSensitiveHotstrings("*", "config" . ScriptInformation["MagicKey"], "configuration")
    CreateCaseSensitiveHotstrings("*", "conso" . ScriptInformation["MagicKey"], "consommation")
    CreateCaseSensitiveHotstrings("*", "chgt" . ScriptInformation["MagicKey"], "changement")
    CreateCaseSensitiveHotstrings("*", "cnp" . ScriptInformation["MagicKey"], "ce n’est pas")
    CreateCaseSensitiveHotstrings("*", "contrib" . ScriptInformation["MagicKey"], "contribution")
    CreateCaseSensitiveHotstrings("*", "couv" . ScriptInformation["MagicKey"], "couverture")
    CreateCaseSensitiveHotstrings("*", "cpd" . ScriptInformation["MagicKey"], "cependant")
    CreateCaseSensitiveHotstrings("*", "cr" . ScriptInformation["MagicKey"], "compte-rendu")
    CreateCaseSensitiveHotstrings("*", "ct" . ScriptInformation["MagicKey"], "c’était")
    CreateCaseSensitiveHotstrings("*", "ctb" . ScriptInformation["MagicKey"], "c’est très bien")
    CreateCaseSensitiveHotstrings("*", "cv" . ScriptInformation["MagicKey"], "ça va ?")
    CreateCaseSensitiveHotstrings("*", "cvt" . ScriptInformation["MagicKey"], "ça va toi ?")
    CreateHotstring("*", "ctc" . ScriptInformation["MagicKey"], "Est-ce que cela te convient ?")
    CreateHotstring("*", "cvc" . ScriptInformation["MagicKey"], "Est-ce que cela vous convient ?")

    ; === D ===
    CreateCaseSensitiveHotstrings("*", "dac" . ScriptInformation["MagicKey"], "d’accord")
    CreateCaseSensitiveHotstrings("*", "ddl" . ScriptInformation["MagicKey"], "download")
    CreateCaseSensitiveHotstrings("*", "dé" . ScriptInformation["MagicKey"], "déjà")
    CreateCaseSensitiveHotstrings("*", "dê" . ScriptInformation["MagicKey"], "d’être")
    CreateCaseSensitiveHotstrings("*", "déc" . ScriptInformation["MagicKey"], "décembre")
    CreateCaseSensitiveHotstrings("*", "dec" . ScriptInformation["MagicKey"], "décembre")
    CreateCaseSensitiveHotstrings("*", "dedt" . ScriptInformation["MagicKey"], "d’emploi du temps")
    CreateCaseSensitiveHotstrings("*", "déf" . ScriptInformation["MagicKey"], "définition")
    CreateCaseSensitiveHotstrings("*", "def" . ScriptInformation["MagicKey"], "définition")
    CreateCaseSensitiveHotstrings("*", "défs" . ScriptInformation["MagicKey"], "définitions")
    CreateCaseSensitiveHotstrings("*", "démo" . ScriptInformation["MagicKey"], "démonstration")
    CreateCaseSensitiveHotstrings("*", "demo" . ScriptInformation["MagicKey"], "démonstration")
    CreateCaseSensitiveHotstrings("*", "dep" . ScriptInformation["MagicKey"], "département")
    CreateCaseSensitiveHotstrings("*", "deux" . ScriptInformation["MagicKey"], "deuxième")
    CreateCaseSensitiveHotstrings("*", "desc" . ScriptInformation["MagicKey"], "description")
    CreateCaseSensitiveHotstrings("*", "dev" . ScriptInformation["MagicKey"], "développeur")
    CreateCaseSensitiveHotstrings("*", "dév" . ScriptInformation["MagicKey"], "développeur")
    CreateCaseSensitiveHotstrings("*", "devt" . ScriptInformation["MagicKey"], "développement")
    CreateCaseSensitiveHotstrings("*", "dico" . ScriptInformation["MagicKey"], "dictionnaire")
    CreateCaseSensitiveHotstrings("*", "diff" . ScriptInformation["MagicKey"], "différence")
    CreateCaseSensitiveHotstrings("*", "difft" . ScriptInformation["MagicKey"], "différent")
    CreateCaseSensitiveHotstrings("*", "dim" . ScriptInformation["MagicKey"], "dimension")
    CreateCaseSensitiveHotstrings("*", "dimi" . ScriptInformation["MagicKey"], "diminution")
    CreateCaseSensitiveHotstrings("*", "la dispo" . ScriptInformation["MagicKey"], "la disposition")
    CreateCaseSensitiveHotstrings("*", "ta dispo" . ScriptInformation["MagicKey"], "ta disposition")
    CreateCaseSensitiveHotstrings("*", "une dispo" . ScriptInformation["MagicKey"], "une disposition")
    CreateCaseSensitiveHotstrings("*", "dispo" . ScriptInformation["MagicKey"], "disponible")
    CreateCaseSensitiveHotstrings("*", "distri" . ScriptInformation["MagicKey"], "distributeur")
    CreateCaseSensitiveHotstrings("*", "distrib" . ScriptInformation["MagicKey"], "distributeur")
    CreateCaseSensitiveHotstrings("*", "dj" . ScriptInformation["MagicKey"], "déjà")
    CreateCaseSensitiveHotstrings("*", "dm" . ScriptInformation["MagicKey"], "donne-moi")
    CreateCaseSensitiveHotstrings("*", "la doc" . ScriptInformation["MagicKey"], "la documentation")
    CreateCaseSensitiveHotstrings("*", "une doc" . ScriptInformation["MagicKey"], "une documentation")
    CreateCaseSensitiveHotstrings("*", "doc" . ScriptInformation["MagicKey"], "document")
    CreateCaseSensitiveHotstrings("*", "docs" . ScriptInformation["MagicKey"], "documents")
    CreateCaseSensitiveHotstrings("*", "dp" . ScriptInformation["MagicKey"], "de plus")
    CreateCaseSensitiveHotstrings("*", "ds" . ScriptInformation["MagicKey"], "data science")
    CreateCaseSensitiveHotstrings("*", "dsl" . ScriptInformation["MagicKey"], "désolé")
    CreateCaseSensitiveHotstrings("*", "dst" . ScriptInformation["MagicKey"], "data scientist")
    CreateCaseSensitiveHotstrings("*", "dtm" . ScriptInformation["MagicKey"], "détermine")
    CreateCaseSensitiveHotstrings("*", "dvlp" . ScriptInformation["MagicKey"], "développe")

    ; === E ===
    CreateCaseSensitiveHotstrings("*", "e" . ScriptInformation["MagicKey"], "est")
    CreateCaseSensitiveHotstrings("*", "echant" . ScriptInformation["MagicKey"], "échantillon")
    CreateCaseSensitiveHotstrings("*", "echants" . ScriptInformation["MagicKey"], "échantillons")
    CreateCaseSensitiveHotstrings("*", "eco" . ScriptInformation["MagicKey"], "économie")
    CreateCaseSensitiveHotstrings("*", "ecq" . ScriptInformation["MagicKey"], "est-ce que")
    CreateCaseSensitiveHotstrings("*", "edt" . ScriptInformation["MagicKey"], "emploi du temps")
    CreateCaseSensitiveHotstrings("*", "eef" . ScriptInformation["MagicKey"], "en effet")
    CreateCaseSensitiveHotstrings("*", "elt" . ScriptInformation["MagicKey"], "élément")
    CreateCaseSensitiveHotstrings("*", "elts" . ScriptInformation["MagicKey"], "éléments")
    CreateCaseSensitiveHotstrings("*", "eo" . ScriptInformation["MagicKey"], "en outre")
    CreateCaseSensitiveHotstrings("*", "enc" . ScriptInformation["MagicKey"], "encore")
    CreateCaseSensitiveHotstrings("*", "eng" . ScriptInformation["MagicKey"], "english")
    CreateCaseSensitiveHotstrings("*", "enft" . ScriptInformation["MagicKey"], "en fait")
    CreateCaseSensitiveHotstrings("*", "ens" . ScriptInformation["MagicKey"], "ensemble")
    CreateCaseSensitiveHotstrings("*", "ent" . ScriptInformation["MagicKey"], "entreprise")
    CreateCaseSensitiveHotstrings("*", "env" . ScriptInformation["MagicKey"], "environ")
    CreateCaseSensitiveHotstrings("*", "ep" . ScriptInformation["MagicKey"], "épisode")
    CreateCaseSensitiveHotstrings("*", "eps" . ScriptInformation["MagicKey"], "épisodes")
    CreateCaseSensitiveHotstrings("*", "eq" . ScriptInformation["MagicKey"], "équation")
    CreateCaseSensitiveHotstrings("*", "ety" . ScriptInformation["MagicKey"], "étymologie")
    CreateCaseSensitiveHotstrings("*", "eve" . ScriptInformation["MagicKey"], "événement")
    CreateCaseSensitiveHotstrings("*", "evtl" . ScriptInformation["MagicKey"], "éventuel")
    CreateCaseSensitiveHotstrings("*", "evtle" . ScriptInformation["MagicKey"], "éventuelle")
    CreateCaseSensitiveHotstrings("*", "evtlt" . ScriptInformation["MagicKey"], "éventuellement")
    CreateCaseSensitiveHotstrings("*", "ex" . ScriptInformation["MagicKey"], "exemple")
    CreateCaseSensitiveHotstrings("*", "exo" . ScriptInformation["MagicKey"], "exercice")
    CreateCaseSensitiveHotstrings("*", "exp" . ScriptInformation["MagicKey"], "expérience")
    CreateCaseSensitiveHotstrings("*", "expo" . ScriptInformation["MagicKey"], "exposition")
    CreateCaseSensitiveHotstrings("*", "é" . ScriptInformation["MagicKey"], "écart")
    CreateCaseSensitiveHotstrings("*", "échant" . ScriptInformation["MagicKey"], "échantillon")
    CreateCaseSensitiveHotstrings("*", "échants" . ScriptInformation["MagicKey"], "échantillons")
    CreateCaseSensitiveHotstrings("*", "éco" . ScriptInformation["MagicKey"], "économie")
    CreateCaseSensitiveHotstrings("*", "ém" . ScriptInformation["MagicKey"], "écris-moi")
    CreateCaseSensitiveHotstrings("*", "éq" . ScriptInformation["MagicKey"], "équation")
    CreateCaseSensitiveHotstrings("*", "ê" . ScriptInformation["MagicKey"], "être")
    CreateCaseSensitiveHotstrings("*", "êt" . ScriptInformation["MagicKey"], "es-tu")

    ; === F ===
    CreateCaseSensitiveHotstrings("*", "f" . ScriptInformation["MagicKey"], "faire")
    CreateCaseSensitiveHotstrings("*", "fam" . ScriptInformation["MagicKey"], "famille")
    CreateCaseSensitiveHotstrings("*", "fb" . ScriptInformation["MagicKey"], "facebook")
    CreateCaseSensitiveHotstrings("*", "fc" . ScriptInformation["MagicKey"], "fonction")
    CreateCaseSensitiveHotstrings("*", "fct" . ScriptInformation["MagicKey"], "fonction")
    CreateCaseSensitiveHotstrings("*", "fea" . ScriptInformation["MagicKey"], "feature")
    CreateCaseSensitiveHotstrings("*", "feat" . ScriptInformation["MagicKey"], "feature")
    CreateCaseSensitiveHotstrings("*", "fev" . ScriptInformation["MagicKey"], "février")
    CreateCaseSensitiveHotstrings("*", "fi" . ScriptInformation["MagicKey"], "financier")
    CreateCaseSensitiveHotstrings("*", "fiè" . ScriptInformation["MagicKey"], "financière")
    CreateCaseSensitiveHotstrings("*", "ff" . ScriptInformation["MagicKey"], "firefox")
    CreateCaseSensitiveHotstrings("*", "fig" . ScriptInformation["MagicKey"], "figure")
    CreateCaseSensitiveHotstrings("*", "fl" . ScriptInformation["MagicKey"], "falloir")
    CreateCaseSensitiveHotstrings("*", "freq" . ScriptInformation["MagicKey"], "fréquence")
    CreateHotstring("*", "fr" . ScriptInformation["MagicKey"], "France")
    CreateCaseSensitiveHotstrings("*", "frs" . ScriptInformation["MagicKey"], "français")
    CreateCaseSensitiveHotstrings("*", "ft" . ScriptInformation["MagicKey"], "fine-tuning")

    ; === G ===
    CreateCaseSensitiveHotstrings("*", "g" . ScriptInformation["MagicKey"], "j’ai")
    CreateCaseSensitiveHotstrings("*", "g1r" . ScriptInformation["MagicKey"], "j’ai une réunion")
    CreateCaseSensitiveHotstrings("*", "gar" . ScriptInformation["MagicKey"], "garantie")
    CreateCaseSensitiveHotstrings("*", "gars" . ScriptInformation["MagicKey"], "garanties")
    CreateCaseSensitiveHotstrings("*", "gd" . ScriptInformation["MagicKey"], "grand")
    CreateCaseSensitiveHotstrings("*", "gg" . ScriptInformation["MagicKey"], "google")
    CreateCaseSensitiveHotstrings("*", "ges" . ScriptInformation["MagicKey"], "gestion")
    CreateCaseSensitiveHotstrings("*", "gf" . ScriptInformation["MagicKey"], "j’ai fait")
    CreateCaseSensitiveHotstrings("*", "gh" . ScriptInformation["MagicKey"], "github")
    CreateHotstring("*", "ghc" . ScriptInformation["MagicKey"], "GitHub Copilot")
    CreateCaseSensitiveHotstrings("*", "ght" . ScriptInformation["MagicKey"], "j’ai acheté")
    CreateCaseSensitiveHotstrings("*", "gmag" . ScriptInformation["MagicKey"], "j’ai mis à jour")
    CreateCaseSensitiveHotstrings("*", "gov" . ScriptInformation["MagicKey"], "government")
    CreateCaseSensitiveHotstrings("*", "gouv" . ScriptInformation["MagicKey"], "gouvernement")
    CreateCaseSensitiveHotstrings("*", "indiv" . ScriptInformation["MagicKey"], "individuel")
    CreateCaseSensitiveHotstrings("*", "gpa" . ScriptInformation["MagicKey"], "je n’ai pas")
    CreateCaseSensitiveHotstrings("*", "gt" . ScriptInformation["MagicKey"], "j’étais")
    CreateCaseSensitiveHotstrings("*", "gvt" . ScriptInformation["MagicKey"], "gouvernement")

    ; === H ===
    CreateCaseSensitiveHotstrings("*", "h" . ScriptInformation["MagicKey"], "heure")
    CreateHotstring("*", "hf" . ScriptInformation["MagicKey"], "Hugging Face")
    CreateCaseSensitiveHotstrings("*", "his" . ScriptInformation["MagicKey"], "historique")
    CreateCaseSensitiveHotstrings("*", "histo" . ScriptInformation["MagicKey"], "historique")
    CreateCaseSensitiveHotstrings("*", "hs" . ScriptInformation["MagicKey"], "hammerspoon")
    CreateCaseSensitiveHotstrings("*", "hyp" . ScriptInformation["MagicKey"], "hypothèse")

    ; === I ===
    CreateCaseSensitiveHotstrings("*", "ia" . ScriptInformation["MagicKey"], "intelligence artificielle")
    CreateCaseSensitiveHotstrings("*", "id" . ScriptInformation["MagicKey"], "identifiant")
    CreateHotstring("*", "idf" . ScriptInformation["MagicKey"], "Île-de-France")
    CreateHotstring("*", "idk" . ScriptInformation["MagicKey"], "I don’t know")
    CreateCaseSensitiveHotstrings("*", "ids" . ScriptInformation["MagicKey"], "identifiants")
    CreateCaseSensitiveHotstrings("*", "img" . ScriptInformation["MagicKey"], "image")
    CreateCaseSensitiveHotstrings("*", "imgs" . ScriptInformation["MagicKey"], "images")
    CreateCaseSensitiveHotstrings("*", "imm" . ScriptInformation["MagicKey"], "immeuble")
    CreateCaseSensitiveHotstrings("*", "imo" . ScriptInformation["MagicKey"], "in my opinion")
    CreateCaseSensitiveHotstrings("*", "imp" . ScriptInformation["MagicKey"], "impossible")
    CreateCaseSensitiveHotstrings("*", "inf" . ScriptInformation["MagicKey"], "inférieur")
    CreateCaseSensitiveHotstrings("*", "info" . ScriptInformation["MagicKey"], "information")
    CreateCaseSensitiveHotstrings("*", "infos" . ScriptInformation["MagicKey"], "informations")
    CreateCaseSensitiveHotstrings("*", "infra" . ScriptInformation["MagicKey"], "infrastructure")
    CreateCaseSensitiveHotstrings("*", "insta" . ScriptInformation["MagicKey"], "instagram")
    CreateCaseSensitiveHotstrings("*", "intart" . ScriptInformation["MagicKey"], "intelligence artificielle")
    CreateCaseSensitiveHotstrings("*", "inter" . ScriptInformation["MagicKey"], "international")
    CreateCaseSensitiveHotstrings("*", "intro" . ScriptInformation["MagicKey"], "introduction")

    ; === J ===
    CreateCaseSensitiveHotstrings("*", "j" . ScriptInformation["MagicKey"], "bonjour")
    CreateCaseSensitiveHotstrings("*", "ja" . ScriptInformation["MagicKey"], "jamais")
    CreateCaseSensitiveHotstrings("*", "janv" . ScriptInformation["MagicKey"], "janvier")
    CreateCaseSensitiveHotstrings("*", "jm" . ScriptInformation["MagicKey"], "j’aime")
    CreateCaseSensitiveHotstrings("*", "jms" . ScriptInformation["MagicKey"], "jamais")
    CreateCaseSensitiveHotstrings("*", "jnsp" . ScriptInformation["MagicKey"], "je ne sais pas")
    CreateCaseSensitiveHotstrings("*", "js" . ScriptInformation["MagicKey"], "je suis")
    CreateCaseSensitiveHotstrings("*", "jsp" . ScriptInformation["MagicKey"], "je ne sais pas")
    CreateCaseSensitiveHotstrings("*", "jtm" . ScriptInformation["MagicKey"], "je t’aime")
    CreateCaseSensitiveHotstrings("*", "ju" . ScriptInformation["MagicKey"], "jusque")
    CreateCaseSensitiveHotstrings("*", "ju'" . ScriptInformation["MagicKey"], "jusqu’")
    CreateCaseSensitiveHotstrings("*", "jus" . ScriptInformation["MagicKey"], "jusque")
    CreateCaseSensitiveHotstrings("*", "jusq" . ScriptInformation["MagicKey"], "jusqu’")
    CreateCaseSensitiveHotstrings("*", "jus'" . ScriptInformation["MagicKey"], "jusqu’")
    CreateCaseSensitiveHotstrings("*", "jui" . ScriptInformation["MagicKey"], "juillet")

    ; === K ===
    CreateCaseSensitiveHotstrings("*", "k" . ScriptInformation["MagicKey"], "contacter")
    CreateCaseSensitiveHotstrings("*", "kb" . ScriptInformation["MagicKey"], "keyboard")
    CreateCaseSensitiveHotstrings("*", "kbd" . ScriptInformation["MagicKey"], "keyboard")
    CreateCaseSensitiveHotstrings("*", "kdo", "cadeau")
    CreateCaseSensitiveHotstrings("*", "kn" . ScriptInformation["MagicKey"], "construction")

    ; === L ===
    CreateCaseSensitiveHotstrings("*", "l" . ScriptInformation["MagicKey"], "elle")
    CreateCaseSensitiveHotstrings("*", "lê" . ScriptInformation["MagicKey"], "l’être")
    CreateCaseSensitiveHotstrings("*", "ledt" . ScriptInformation["MagicKey"], "l’emploi du temps")
    CreateCaseSensitiveHotstrings("*", "lex" . ScriptInformation["MagicKey"], "l’exemple")
    CreateCaseSensitiveHotstrings("*", "lgb" . ScriptInformation["MagicKey"], "lightgbm")
    CreateCaseSensitiveHotstrings("*", "lim" . ScriptInformation["MagicKey"], "limite")
    CreateCaseSensitiveHotstrings("*", "llm" . ScriptInformation["MagicKey"], "large language model")

    ; === M ===
    CreateCaseSensitiveHotstrings("*", "m" . ScriptInformation["MagicKey"], "mais")
    CreateCaseSensitiveHotstrings("*", "ma" . ScriptInformation["MagicKey"], "madame")
    CreateCaseSensitiveHotstrings("*", "maj" . ScriptInformation["MagicKey"], "mise à jour")
    CreateCaseSensitiveHotstrings("*", "majs" . ScriptInformation["MagicKey"], "mises à jour")
    CreateCaseSensitiveHotstrings("*", "màj" . ScriptInformation["MagicKey"], "mise à jour")
    CreateCaseSensitiveHotstrings("*", "màjs" . ScriptInformation["MagicKey"], "mises à jour")
    CreateCaseSensitiveHotstrings("*", "math" . ScriptInformation["MagicKey"], "mathématique")
    CreateCaseSensitiveHotstrings("*", "manip" . ScriptInformation["MagicKey"], "manipulation")
    CreateCaseSensitiveHotstrings("*", "maths" . ScriptInformation["MagicKey"], "mathématiques")
    CreateCaseSensitiveHotstrings("*", "max" . ScriptInformation["MagicKey"], "maximum")
    CreateCaseSensitiveHotstrings("*", "md" . ScriptInformation["MagicKey"], "markdown")
    CreateCaseSensitiveHotstrings("*", "mdav" . ScriptInformation["MagicKey"], "merci d’avance")
    CreateCaseSensitiveHotstrings("*", "mdb" . ScriptInformation["MagicKey"], "merci de bien vouloir")
    CreateCaseSensitiveHotstrings("*", "mdl" . ScriptInformation["MagicKey"], "modèle")
    CreateCaseSensitiveHotstrings("*", "mdp" . ScriptInformation["MagicKey"], "mot de passe")
    CreateCaseSensitiveHotstrings("*", "mdps" . ScriptInformation["MagicKey"], "mots de passe")
    CreateCaseSensitiveHotstrings("*", "méthodo" . ScriptInformation["MagicKey"], "méthodologie")
    CreateCaseSensitiveHotstrings("*", "min" . ScriptInformation["MagicKey"], "minimum")
    CreateCaseSensitiveHotstrings("*", "mio" . ScriptInformation["MagicKey"], "million")
    CreateCaseSensitiveHotstrings("*", "mios" . ScriptInformation["MagicKey"], "millions")
    CreateCaseSensitiveHotstrings("*", "mjo" . ScriptInformation["MagicKey"], "mettre à jour")
    CreateCaseSensitiveHotstrings("*", "ml" . ScriptInformation["MagicKey"], "machine learning")
    CreateCaseSensitiveHotstrings("*", "mle" . ScriptInformation["MagicKey"], "machine learning engineer")
    CreateCaseSensitiveHotstrings("*", "mm" . ScriptInformation["MagicKey"], "même")
    CreateCaseSensitiveHotstrings("*", "mme" . ScriptInformation["MagicKey"], "madame")
    CreateCaseSensitiveHotstrings("*", "modif" . ScriptInformation["MagicKey"], "modification")
    CreateCaseSensitiveHotstrings("*", "mom" . ScriptInformation["MagicKey"], "moi-même")
    CreateCaseSensitiveHotstrings("*", "mq" . ScriptInformation["MagicKey"], "montre que")
    CreateCaseSensitiveHotstrings("*", "mr" . ScriptInformation["MagicKey"], "monsieur")
    CreateCaseSensitiveHotstrings("*", "mrc" . ScriptInformation["MagicKey"], "merci")
    CreateCaseSensitiveHotstrings("*", "msg" . ScriptInformation["MagicKey"], "message")
    CreateCaseSensitiveHotstrings("*", "mtn" . ScriptInformation["MagicKey"], "maintenant")
    CreateCaseSensitiveHotstrings("*", "moy" . ScriptInformation["MagicKey"], "moyenne")
    CreateCaseSensitiveHotstrings("*", "mutu" . ScriptInformation["MagicKey"], "mutualiser")
    CreateCaseSensitiveHotstrings("*", "mvt" . ScriptInformation["MagicKey"], "mouvement")

    ; === N ===
    CreateCaseSensitiveHotstrings("*", "n" . ScriptInformation["MagicKey"], "nouveau")
    CreateCaseSensitiveHotstrings("*", "nav" . ScriptInformation["MagicKey"], "navigation")
    CreateCaseSensitiveHotstrings("*", "nb" . ScriptInformation["MagicKey"], "nombre")
    CreateCaseSensitiveHotstrings("*", "nean" . ScriptInformation["MagicKey"], "néanmoins")
    CreateCaseSensitiveHotstrings("*", "new" . ScriptInformation["MagicKey"], "nouveau")
    CreateCaseSensitiveHotstrings("*", "newe" . ScriptInformation["MagicKey"], "nouvelle")
    CreateCaseSensitiveHotstrings("*", "nimp" . ScriptInformation["MagicKey"], "n’importe")
    CreateCaseSensitiveHotstrings("*", "niv" . ScriptInformation["MagicKey"], "niveau")
    CreateCaseSensitiveHotstrings("*", "norm" . ScriptInformation["MagicKey"], "normalement")
    CreateCaseSensitiveHotstrings("*", "nota" . ScriptInformation["MagicKey"], "notamment")
    CreateCaseSensitiveHotstrings("*", "notm" . ScriptInformation["MagicKey"], "notamment")
    CreateCaseSensitiveHotstrings("*", "nouv" . ScriptInformation["MagicKey"], "nouvelle")
    CreateCaseSensitiveHotstrings("*", "nov" . ScriptInformation["MagicKey"], "novembre")
    CreateCaseSensitiveHotstrings("*", "now" . ScriptInformation["MagicKey"], "maintenant")
    CreateCaseSensitiveHotstrings("*", "np" . ScriptInformation["MagicKey"], "ne pas")
    CreateCaseSensitiveHotstrings("*", "nrj" . ScriptInformation["MagicKey"], "énergie")
    CreateCaseSensitiveHotstrings("*", "ns" . ScriptInformation["MagicKey"], "nous")
    CreateCaseSensitiveHotstrings("*", "num" . ScriptInformation["MagicKey"], "numéro")

    ; === O ===
    CreateCaseSensitiveHotstrings("*", "o-" . ScriptInformation["MagicKey"], "au moins")
    CreateCaseSensitiveHotstrings("*", "o+" . ScriptInformation["MagicKey"], "au plus")
    CreateCaseSensitiveHotstrings("*", "obj" . ScriptInformation["MagicKey"], "objectif")
    CreateCaseSensitiveHotstrings("*", "obs" . ScriptInformation["MagicKey"], "observation")
    CreateCaseSensitiveHotstrings("*", "oct" . ScriptInformation["MagicKey"], "octobre")
    CreateCaseSensitiveHotstrings("*", "odj" . ScriptInformation["MagicKey"], "ordre du jour")
    CreateCaseSensitiveHotstrings("*", "opé" . ScriptInformation["MagicKey"], "opération")
    CreateCaseSensitiveHotstrings("*", "oqp" . ScriptInformation["MagicKey"], "occupé")
    CreateCaseSensitiveHotstrings("*", "ordi" . ScriptInformation["MagicKey"], "ordinateur")
    CreateCaseSensitiveHotstrings("*", "org" . ScriptInformation["MagicKey"], "organisation")
    CreateCaseSensitiveHotstrings("*", "orga" . ScriptInformation["MagicKey"], "organisation")
    CreateCaseSensitiveHotstrings("*", "ortho" . ScriptInformation["MagicKey"], "orthographe")
    CreateHotstring("*", "out" . ScriptInformation["MagicKey"], "Où es-tu ?")
    CreateHotstring("*", "outv" . ScriptInformation["MagicKey"], "Où êtes-vous ?")
    CreateCaseSensitiveHotstrings("*", "ouv" . ScriptInformation["MagicKey"], "ouverture")

    ; === P ===
    CreateCaseSensitiveHotstrings("*", "p" . ScriptInformation["MagicKey"], "prendre")
    CreateCaseSensitiveHotstrings("*", "p//" . ScriptInformation["MagicKey"], "par rapport")
    CreateCaseSensitiveHotstrings("*", "par" . ScriptInformation["MagicKey"], "paragraphe")
    CreateCaseSensitiveHotstrings("*", "param" . ScriptInformation["MagicKey"], "paramètre")
    CreateCaseSensitiveHotstrings("*", "pb" . ScriptInformation["MagicKey"], "problème")
    CreateCaseSensitiveHotstrings("*", "pcq" . ScriptInformation["MagicKey"], "parce que")
    CreateCaseSensitiveHotstrings("*", "pck" . ScriptInformation["MagicKey"], "parce que")
    CreateCaseSensitiveHotstrings("*", "pckil" . ScriptInformation["MagicKey"], "parce qu’il")
    CreateCaseSensitiveHotstrings("*", "pcquil" . ScriptInformation["MagicKey"], "parce qu’il")
    CreateCaseSensitiveHotstrings("*", "pcquon" . ScriptInformation["MagicKey"], "parce qu’on")
    CreateCaseSensitiveHotstrings("*", "pckon" . ScriptInformation["MagicKey"], "parce qu’on")
    CreateCaseSensitiveHotstrings("*", "pd" . ScriptInformation["MagicKey"], "pendant")
    CreateCaseSensitiveHotstrings("*", "pdt" . ScriptInformation["MagicKey"], "pendant")
    CreateCaseSensitiveHotstrings("*", "pdv" . ScriptInformation["MagicKey"], "point de vue")
    CreateCaseSensitiveHotstrings("*", "pdvs" . ScriptInformation["MagicKey"], "points de vue")
    CreateCaseSensitiveHotstrings("*", "perf" . ScriptInformation["MagicKey"], "performance")
    CreateCaseSensitiveHotstrings("*", "perso" . ScriptInformation["MagicKey"], "personne")
    CreateCaseSensitiveHotstrings("*", "pê" . ScriptInformation["MagicKey"], "peut-être")
    CreateCaseSensitiveHotstrings("*", "péri" . ScriptInformation["MagicKey"], "périmètre")
    CreateCaseSensitiveHotstrings("*", "périm" . ScriptInformation["MagicKey"], "périmètre")
    CreateCaseSensitiveHotstrings("*", "peut-ê" . ScriptInformation["MagicKey"], "peut-être")
    CreateCaseSensitiveHotstrings("*", "pex" . ScriptInformation["MagicKey"], "par exemple")
    CreateCaseSensitiveHotstrings("*", "pf" . ScriptInformation["MagicKey"], "portefeuille")
    CreateCaseSensitiveHotstrings("*", "pg" . ScriptInformation["MagicKey"], "pas grave")
    CreateCaseSensitiveHotstrings("*", "pgm" . ScriptInformation["MagicKey"], "programme")
    CreateCaseSensitiveHotstrings("*", "pi" . ScriptInformation["MagicKey"], "pour information")
    CreateCaseSensitiveHotstrings("*", "pic" . ScriptInformation["MagicKey"], "picture")
    CreateCaseSensitiveHotstrings("*", "pics" . ScriptInformation["MagicKey"], "pictures")
    CreateCaseSensitiveHotstrings("*", "piè" . ScriptInformation["MagicKey"], "pièce jointe")
    CreateCaseSensitiveHotstrings("*", "pj" . ScriptInformation["MagicKey"], "pièce jointe")
    CreateCaseSensitiveHotstrings("*", "pjs" . ScriptInformation["MagicKey"], "pièces jointes")
    CreateCaseSensitiveHotstrings("*", "pk" . ScriptInformation["MagicKey"], "pourquoi")
    CreateCaseSensitiveHotstrings("*", "pls" . ScriptInformation["MagicKey"], "please")
    CreateCaseSensitiveHotstrings("*", "poc" . ScriptInformation["MagicKey"], "proof of concept")
    CreateCaseSensitiveHotstrings("*", "poum" . ScriptInformation["MagicKey"], "plus ou moins")
    CreateCaseSensitiveHotstrings("*", "poss" . ScriptInformation["MagicKey"], "possible")
    CreateCaseSensitiveHotstrings("*", "pourcent" . ScriptInformation["MagicKey"], "pourcentage")
    CreateCaseSensitiveHotstrings("*", "ppt" . ScriptInformation["MagicKey"], "PowerPoint")
    CreateCaseSensitiveHotstrings("*", "pq" . ScriptInformation["MagicKey"], "pourquoi")
    CreateCaseSensitiveHotstrings("*", "pr" . ScriptInformation["MagicKey"], "pull request")
    CreateCaseSensitiveHotstrings("*", "prd" . ScriptInformation["MagicKey"], "produit")
    CreateCaseSensitiveHotstrings("*", "prem" . ScriptInformation["MagicKey"], "premier")
    CreateCaseSensitiveHotstrings("*", "prez" . ScriptInformation["MagicKey"], "présentation")
    CreateCaseSensitiveHotstrings("*", "prg" . ScriptInformation["MagicKey"], "programme")
    CreateCaseSensitiveHotstrings("*", "prio" . ScriptInformation["MagicKey"], "priorité")
    CreateCaseSensitiveHotstrings("*", "pro" . ScriptInformation["MagicKey"], "professionnel")
    CreateCaseSensitiveHotstrings("*", "prob" . ScriptInformation["MagicKey"], "problème")
    CreateCaseSensitiveHotstrings("*", "proba" . ScriptInformation["MagicKey"], "probabilité")
    CreateCaseSensitiveHotstrings("*", "prod" . ScriptInformation["MagicKey"], "production")
    CreateCaseSensitiveHotstrings("*", "prof" . ScriptInformation["MagicKey"], "professeur")
    CreateCaseSensitiveHotstrings("*", "prog" . ScriptInformation["MagicKey"], "programme")
    CreateCaseSensitiveHotstrings("*", "prop" . ScriptInformation["MagicKey"], "propriété")
    CreateCaseSensitiveHotstrings("*", "propo" . ScriptInformation["MagicKey"], "proposition")
    CreateCaseSensitiveHotstrings("*", "props" . ScriptInformation["MagicKey"], "propriétés")
    CreateCaseSensitiveHotstrings("*", "pros" . ScriptInformation["MagicKey"], "professionnels")
    CreateCaseSensitiveHotstrings("*", "prot" . ScriptInformation["MagicKey"], "professionnellement")
    CreateCaseSensitiveHotstrings("*", "prov" . ScriptInformation["MagicKey"], "provision")
    CreateCaseSensitiveHotstrings("*", "psycha" . ScriptInformation["MagicKey"], "psychanalyse")
    CreateCaseSensitiveHotstrings("*", "psycho" . ScriptInformation["MagicKey"], "psychologie")
    CreateCaseSensitiveHotstrings("*", "psb" . ScriptInformation["MagicKey"], "possible")
    CreateCaseSensitiveHotstrings("*", "psy" . ScriptInformation["MagicKey"], "psychologie")
    CreateCaseSensitiveHotstrings("*", "psycho" . ScriptInformation["MagicKey"], "psychologie")
    CreateCaseSensitiveHotstrings("*", "pt" . ScriptInformation["MagicKey"], "point")
    CreateCaseSensitiveHotstrings("*", "ptf" . ScriptInformation["MagicKey"], "portefeuille")
    CreateCaseSensitiveHotstrings("*", "pts" . ScriptInformation["MagicKey"], "points")
    CreateCaseSensitiveHotstrings("*", "pub" . ScriptInformation["MagicKey"], "publicité")
    CreateCaseSensitiveHotstrings("*", "pvv" . ScriptInformation["MagicKey"], "pouvez-vous")
    CreateCaseSensitiveHotstrings("*", "py" . ScriptInformation["MagicKey"], "python")

    ; === Q ===
    CreateCaseSensitiveHotstrings("*", "q" . ScriptInformation["MagicKey"], "question")
    CreateCaseSensitiveHotstrings("*", "qc" . ScriptInformation["MagicKey"], "qu’est-ce")
    CreateCaseSensitiveHotstrings("*", "qcq" . ScriptInformation["MagicKey"], "qu’est-ce que")
    CreateCaseSensitiveHotstrings("*", "qcq'" . ScriptInformation["MagicKey"], "qu’est-ce qu’")
    CreateCaseSensitiveHotstrings("*", "qq" . ScriptInformation["MagicKey"], "quelque")
    CreateCaseSensitiveHotstrings("*", "qqch" . ScriptInformation["MagicKey"], "quelque chose")
    CreateCaseSensitiveHotstrings("*", "qqs" . ScriptInformation["MagicKey"], "quelques")
    CreateCaseSensitiveHotstrings("*", "qqn" . ScriptInformation["MagicKey"], "quelqu’un")
    CreateCaseSensitiveHotstrings("*", "quasi" . ScriptInformation["MagicKey"], "quasiment")
    CreateCaseSensitiveHotstrings("*", "ques" . ScriptInformation["MagicKey"], "question")
    CreateCaseSensitiveHotstrings("*", "quid" . ScriptInformation["MagicKey"], "qu’en est-il de")

    ; === R ===
    CreateCaseSensitiveHotstrings("*", "r" . ScriptInformation["MagicKey"], "rien")
    CreateCaseSensitiveHotstrings("*", "rapidt" . ScriptInformation["MagicKey"], "rapidement")
    CreateCaseSensitiveHotstrings("*", "rdc" . ScriptInformation["MagicKey"], "rez-de-chaussée")
    CreateCaseSensitiveHotstrings("*", "rdv" . ScriptInformation["MagicKey"], "rendez-vous")
    CreateCaseSensitiveHotstrings("*", "ré" . ScriptInformation["MagicKey"], "réunion")
    CreateCaseSensitiveHotstrings("*", "rés" . ScriptInformation["MagicKey"], "réunions")
    CreateCaseSensitiveHotstrings("*", "rép" . ScriptInformation["MagicKey"], "répertoire")
    CreateCaseSensitiveHotstrings("*", "résil" . ScriptInformation["MagicKey"], "résiliation")
    CreateCaseSensitiveHotstrings("*", "reco" . ScriptInformation["MagicKey"], "recommandation")
    CreateCaseSensitiveHotstrings("*", "ref" . ScriptInformation["MagicKey"], "référence")
    CreateCaseSensitiveHotstrings("*", "rep" . ScriptInformation["MagicKey"], "répertoire")
    CreateCaseSensitiveHotstrings("*", "rex" . ScriptInformation["MagicKey"], "retour d’expérience")
    CreateCaseSensitiveHotstrings("*", "rh" . ScriptInformation["MagicKey"], "ressources humaines")
    CreateCaseSensitiveHotstrings("*", "rmq" . ScriptInformation["MagicKey"], "remarque")
    CreateCaseSensitiveHotstrings("*", "rpz" . ScriptInformation["MagicKey"], "représente")
    CreateCaseSensitiveHotstrings("*", "rs" . ScriptInformation["MagicKey"], "résultat")

    ; === S ===
    CreateCaseSensitiveHotstrings("*", "seg" . ScriptInformation["MagicKey"], "segment")
    CreateCaseSensitiveHotstrings("*", "segm" . ScriptInformation["MagicKey"], "segment")
    CreateCaseSensitiveHotstrings("*", "sep" . ScriptInformation["MagicKey"], "septembre")
    CreateCaseSensitiveHotstrings("*", "sept" . ScriptInformation["MagicKey"], "septembre")
    CreateCaseSensitiveHotstrings("*", "simpl" . ScriptInformation["MagicKey"], "simplement")
    CreateCaseSensitiveHotstrings("*", "situ" . ScriptInformation["MagicKey"], "situation")
    CreateCaseSensitiveHotstrings("*", "smth" . ScriptInformation["MagicKey"], "something")
    ; CreateCaseSensitiveHotstrings("*", "sol" . ScriptInformation["MagicKey"],  "solution") ; Conflict with "sollicitation"
    CreateCaseSensitiveHotstrings("*", "srx" . ScriptInformation["MagicKey"], "sérieux")
    CreateCaseSensitiveHotstrings("*", "sécu" . ScriptInformation["MagicKey"], "sécurité")
    CreateCaseSensitiveHotstrings("*", "st" . ScriptInformation["MagicKey"], "s’était")
    CreateCaseSensitiveHotstrings("*", "stat" . ScriptInformation["MagicKey"], "statistique")
    CreateCaseSensitiveHotstrings("*", "sth" . ScriptInformation["MagicKey"], "something")
    CreateCaseSensitiveHotstrings("*", "stp" . ScriptInformation["MagicKey"], "s’il te plaît")
    CreateCaseSensitiveHotstrings("*", "strat" . ScriptInformation["MagicKey"], "stratégique")
    CreateCaseSensitiveHotstrings("*", "stream" . ScriptInformation["MagicKey"], "streaming")
    CreateCaseSensitiveHotstrings("*", "suff" . ScriptInformation["MagicKey"], "suffisant")
    CreateCaseSensitiveHotstrings("*", "sufft" . ScriptInformation["MagicKey"], "suffisamment")
    CreateCaseSensitiveHotstrings("*", "supé" . ScriptInformation["MagicKey"], "supérieur")
    CreateCaseSensitiveHotstrings("*", "surv" . ScriptInformation["MagicKey"], "survenance")
    CreateCaseSensitiveHotstrings("*", "svp" . ScriptInformation["MagicKey"], "s’il vous plaît")
    CreateCaseSensitiveHotstrings("*", "svt" . ScriptInformation["MagicKey"], "souvent")
    CreateCaseSensitiveHotstrings("*", "sya" . ScriptInformation["MagicKey"], "s’il y a")
    CreateCaseSensitiveHotstrings("*", "syn" . ScriptInformation["MagicKey"], "synonyme")
    CreateCaseSensitiveHotstrings("*", "sync" . ScriptInformation["MagicKey"], "synchronisation")
    CreateCaseSensitiveHotstrings("*", "syncro" . ScriptInformation["MagicKey"], "synchronisation")
    CreateCaseSensitiveHotstrings("*", "sys" . ScriptInformation["MagicKey"], "système")

    ; === T ===
    CreateCaseSensitiveHotstrings("*", "t" . ScriptInformation["MagicKey"], "très")
    CreateCaseSensitiveHotstrings("*", "tb" . ScriptInformation["MagicKey"], "très bien")
    CreateCaseSensitiveHotstrings("*", "temp" . ScriptInformation["MagicKey"], "temporaire")
    CreateCaseSensitiveHotstrings("*", "tes" . ScriptInformation["MagicKey"], "tu es")
    CreateCaseSensitiveHotstrings("*", "tél" . ScriptInformation["MagicKey"], "téléphone") ; "tel" can’t be used, because there would be a conflict with "tel★e que"
    CreateCaseSensitiveHotstrings("*", "teq" . ScriptInformation["MagicKey"], "telle que")
    CreateCaseSensitiveHotstrings("*", "teqs" . ScriptInformation["MagicKey"], "telles que")
    CreateCaseSensitiveHotstrings("*", "tfk" . ScriptInformation["MagicKey"], "qu’est-ce que tu fais ?")
    CreateCaseSensitiveHotstrings("*", "tgh" . ScriptInformation["MagicKey"], "together")
    CreateCaseSensitiveHotstrings("*", "théo" . ScriptInformation["MagicKey"], "théorie")
    CreateCaseSensitiveHotstrings("*", "thm" . ScriptInformation["MagicKey"], "théorème")
    CreateCaseSensitiveHotstrings("*", "tj" . ScriptInformation["MagicKey"], "toujours")
    CreateCaseSensitiveHotstrings("*", "tjr" . ScriptInformation["MagicKey"], "toujours")
    CreateCaseSensitiveHotstrings("*", "tlm" . ScriptInformation["MagicKey"], "tout le monde")
    CreateCaseSensitiveHotstrings("*", "tq" . ScriptInformation["MagicKey"], "tel que")
    CreateCaseSensitiveHotstrings("*", "tqs" . ScriptInformation["MagicKey"], "tels que")
    CreateCaseSensitiveHotstrings("*", "tout" . ScriptInformation["MagicKey"], "toutefois")
    CreateCaseSensitiveHotstrings("*", "tra" . ScriptInformation["MagicKey"], "travail")
    CreateCaseSensitiveHotstrings("*", "trad" . ScriptInformation["MagicKey"], "traduction")
    CreateCaseSensitiveHotstrings("*", "trav" . ScriptInformation["MagicKey"], "travail")
    CreateCaseSensitiveHotstrings("*", "trkl" . ScriptInformation["MagicKey"], "tranquille")
    CreateCaseSensitiveHotstrings("*", "tt" . ScriptInformation["MagicKey"], "télétravail")
    CreateCaseSensitiveHotstrings("*", "tv" . ScriptInformation["MagicKey"], "télévision")
    CreateCaseSensitiveHotstrings("*", "ty" . ScriptInformation["MagicKey"], "thank you")
    CreateCaseSensitiveHotstrings("*", "typo" . ScriptInformation["MagicKey"], "typographie")

    ; === U ===
    CreateCaseSensitiveHotstrings("*", "une amé" . ScriptInformation["MagicKey"], "une amélioration")
    CreateCaseSensitiveHotstrings("*", "uniq" . ScriptInformation["MagicKey"], "uniquement")
    CreateHotstring("*", "usa" . ScriptInformation["MagicKey"], "États-Unis")

    ; === V ===
    CreateCaseSensitiveHotstrings("*", "v" . ScriptInformation["MagicKey"], "version")
    CreateCaseSensitiveHotstrings("*", "var" . ScriptInformation["MagicKey"], "variable")
    CreateCaseSensitiveHotstrings("*", "vav" . ScriptInformation["MagicKey"], "vis-à-vis")
    CreateCaseSensitiveHotstrings("*", "verif" . ScriptInformation["MagicKey"], "vérification")
    CreateCaseSensitiveHotstrings("*", "vérif" . ScriptInformation["MagicKey"], "vérification")
    CreateCaseSensitiveHotstrings("*", "vocab" . ScriptInformation["MagicKey"], "vocabulaire")
    CreateCaseSensitiveHotstrings("*", "volat" . ScriptInformation["MagicKey"], "volatilité")
    CreateCaseSensitiveHotstrings("*", "vrm" . ScriptInformation["MagicKey"], "vraiment")
    CreateCaseSensitiveHotstrings("*", "vrmt" . ScriptInformation["MagicKey"], "vraiment")
    CreateCaseSensitiveHotstrings("*", "vs" . ScriptInformation["MagicKey"], "vous êtes")

    ; === W ===
    CreateCaseSensitiveHotstrings("*", "w" . ScriptInformation["MagicKey"], "with")
    CreateCaseSensitiveHotstrings("*", "wd" . ScriptInformation["MagicKey"], "windows")
    CreateCaseSensitiveHotstrings("*", "wk" . ScriptInformation["MagicKey"], "week-end")
    CreateCaseSensitiveHotstrings("*", "wknd" . ScriptInformation["MagicKey"], "week-end")
    CreateCaseSensitiveHotstrings("*", "wiki" . ScriptInformation["MagicKey"], "wikipédia")

    ; === X ===
    CreateCaseSensitiveHotstrings("*", "x" . ScriptInformation["MagicKey"], "exemple")
    CreateCaseSensitiveHotstrings("*", "xg" . ScriptInformation["MagicKey"], "xgboost")
    CreateCaseSensitiveHotstrings("*", "xgb" . ScriptInformation["MagicKey"], "xgboost")

    ; === Y ===
    CreateCaseSensitiveHotstrings("*", "ya" . ScriptInformation["MagicKey"], "il y a")
    CreateCaseSensitiveHotstrings("*", "yapa" . ScriptInformation["MagicKey"], "il n’y a pas")
    CreateCaseSensitiveHotstrings("*", "yatil" . ScriptInformation["MagicKey"], "y a-t-il")
    CreateCaseSensitiveHotstrings("*", "yc" . ScriptInformation["MagicKey"], "y compris")
    CreateCaseSensitiveHotstrings("*", "yt" . ScriptInformation["MagicKey"], "youtube")

    ; === Z ===
}

if Features["MagicKey"]["TextExpansionAuto"].Enabled {
    CreateCaseSensitiveHotstrings("*", "ju'", "jusqu’")
    CreateCaseSensitiveHotstrings("", "ya", "y’a")
}

; ===========================
; ======= 9.4) Emojis =======
; ===========================

if Features["MagicKey"]["TextExpansionEmojis"].Enabled {
    ; === Basic smileys ===
    CreateHotstring("*", ":)" . ScriptInformation["MagicKey"], "😀")
    CreateHotstring("*", ":))" . ScriptInformation["MagicKey"], "😁")
    CreateHotstring("*", ":/" . ScriptInformation["MagicKey"], "🫤")
    CreateHotstring("*", ":(" . ScriptInformation["MagicKey"], "☹️")
    CreateHotstring("*", ":3" . ScriptInformation["MagicKey"], "😗")
    CreateHotstring("*", ":D" . ScriptInformation["MagicKey"], "😁")
    CreateHotstring("*", ":O" . ScriptInformation["MagicKey"], "😮")
    CreateHotstring("*", ":P" . ScriptInformation["MagicKey"], "😛")

    ; === Animals ===
    CreateHotstring("*", "abeille" . ScriptInformation["MagicKey"], "🐝")
    CreateHotstring("*", "aigle" . ScriptInformation["MagicKey"], "🦅")
    CreateHotstring("*", "araignée" . ScriptInformation["MagicKey"], "🕷️")
    CreateHotstring("*", "baleine" . ScriptInformation["MagicKey"], "🐋")
    CreateHotstring("*", "canard" . ScriptInformation["MagicKey"], "🦆")
    CreateHotstring("*", "cerf" . ScriptInformation["MagicKey"], "🦌")
    CreateHotstring("*", "chameau" . ScriptInformation["MagicKey"], "🐪")
    CreateHotstring("*", "chat" . ScriptInformation["MagicKey"], "🐈")
    CreateHotstring("*", "chauve-souris" . ScriptInformation["MagicKey"], "🦇")
    CreateHotstring("*", "chèvre" . ScriptInformation["MagicKey"], "🐐")
    CreateHotstring("*", "cheval" . ScriptInformation["MagicKey"], "🐎")
    CreateHotstring("*", "chien" . ScriptInformation["MagicKey"], "🐕")
    CreateHotstring("*", "cochon" . ScriptInformation["MagicKey"], "🐖")
    CreateHotstring("*", "coq" . ScriptInformation["MagicKey"], "🐓")
    CreateHotstring("*", "crabe" . ScriptInformation["MagicKey"], "🦀")
    CreateHotstring("*", "croco" . ScriptInformation["MagicKey"], "🐊")
    CreateHotstring("*", "crocodile" . ScriptInformation["MagicKey"], "🐊")
    CreateHotstring("*", "cygne" . ScriptInformation["MagicKey"], "🦢")
    CreateHotstring("*", "dauphin" . ScriptInformation["MagicKey"], "🐬")
    CreateHotstring("*", "dragon" . ScriptInformation["MagicKey"], "🐉")
    CreateHotstring("*", "écureuil" . ScriptInformation["MagicKey"], "🐿️")
    CreateHotstring("*", "éléphant" . ScriptInformation["MagicKey"], "🐘")
    CreateHotstring("*", "escargot" . ScriptInformation["MagicKey"], "🐌")
    CreateHotstring("*", "flamant" . ScriptInformation["MagicKey"], "🦩")
    CreateHotstring("*", "fourmi" . ScriptInformation["MagicKey"], "🐜")
    CreateHotstring("*", "girafe" . ScriptInformation["MagicKey"], "🦒")
    CreateHotstring("*", "gorille" . ScriptInformation["MagicKey"], "🦍")
    CreateHotstring("*", "grenouille" . ScriptInformation["MagicKey"], "🐸")
    CreateHotstring("*", "hamster" . ScriptInformation["MagicKey"], "🐹")
    CreateHotstring("*", "hérisson" . ScriptInformation["MagicKey"], "🦔")
    CreateHotstring("*", "hibou" . ScriptInformation["MagicKey"], "🦉")
    CreateHotstring("*", "hippopotame" . ScriptInformation["MagicKey"], "🦛")
    CreateHotstring("*", "homard" . ScriptInformation["MagicKey"], "🦞")
    CreateHotstring("*", "kangourou" . ScriptInformation["MagicKey"], "🦘")
    CreateHotstring("*", "koala" . ScriptInformation["MagicKey"], "🐨")
    CreateHotstring("*", "lama" . ScriptInformation["MagicKey"], "🦙")
    CreateHotstring("*", "lapin" . ScriptInformation["MagicKey"], "🐇")
    CreateHotstring("*", "léopard" . ScriptInformation["MagicKey"], "🐆")
    CreateHotstring("*", "licorne" . ScriptInformation["MagicKey"], "🦄")
    CreateHotstring("*", "lion" . ScriptInformation["MagicKey"], "🦁")
    ; CreateHotstring("*", "lit" . ScriptInformation["MagicKey"],  "🛏️") ; Conflict with "little"
    CreateHotstring("*", "loup" . ScriptInformation["MagicKey"], "🐺")
    CreateHotstring("*", "mouton" . ScriptInformation["MagicKey"], "🐑")
    CreateHotstring("*", "octopus" . ScriptInformation["MagicKey"], "🐙")
    CreateHotstring("*", "ours" . ScriptInformation["MagicKey"], "🐻")
    CreateHotstring("*", "panda" . ScriptInformation["MagicKey"], "🐼")
    CreateHotstring("*", "papillon" . ScriptInformation["MagicKey"], "🦋")
    CreateHotstring("*", "paresseux" . ScriptInformation["MagicKey"], "🦥")
    CreateHotstring("*", "perroquet" . ScriptInformation["MagicKey"], "🦜")
    CreateHotstring("*", "pingouin" . ScriptInformation["MagicKey"], "🐧")
    CreateHotstring("*", "poisson" . ScriptInformation["MagicKey"], "🐟")
    CreateHotstring("*", "poule" . ScriptInformation["MagicKey"], "🐔")
    CreateHotstring("*", "poussin" . ScriptInformation["MagicKey"], "🐣")
    ; CreateHotstring("*", "rat" . ScriptInformation["MagicKey"],  "🐀") ; Conflict with several words, like "rattrapage"
    CreateHotstring("*", "renard" . ScriptInformation["MagicKey"], "🦊")
    CreateHotstring("*", "requin" . ScriptInformation["MagicKey"], "🦈")
    CreateHotstring("*", "rhinocéros" . ScriptInformation["MagicKey"], "🦏")
    CreateHotstring("*", "rhinoceros" . ScriptInformation["MagicKey"], "🦏")
    CreateHotstring("*", "sanglier" . ScriptInformation["MagicKey"], "🐗")
    CreateHotstring("*", "serpent" . ScriptInformation["MagicKey"], "🐍")
    CreateHotstring("*", "singe" . ScriptInformation["MagicKey"], "🐒")
    CreateHotstring("*", "souris" . ScriptInformation["MagicKey"], "🐁")
    CreateHotstring("*", "tigre" . ScriptInformation["MagicKey"], "🐅")
    CreateHotstring("*", "tortue" . ScriptInformation["MagicKey"], "🐢")
    CreateHotstring("*", "trex" . ScriptInformation["MagicKey"], "🦖")
    CreateHotstring("*", "vache" . ScriptInformation["MagicKey"], "🐄")
    CreateHotstring("*", "zèbre" . ScriptInformation["MagicKey"], "🦓")

    ; === Objects and symbols ===
    CreateHotstring("*", "aimant" . ScriptInformation["MagicKey"], "🧲")
    CreateHotstring("*", "ampoule" . ScriptInformation["MagicKey"], "💡")
    CreateHotstring("*", "ancre" . ScriptInformation["MagicKey"], "⚓")
    CreateHotstring("*", "arbre" . ScriptInformation["MagicKey"], "🌲")
    CreateHotstring("*", "argent" . ScriptInformation["MagicKey"], "💰")
    CreateHotstring("*", "attention" . ScriptInformation["MagicKey"], "⚠️")
    CreateHotstring("*", "avion" . ScriptInformation["MagicKey"], "✈️")
    CreateHotstring("*", "balance" . ScriptInformation["MagicKey"], "⚖️")
    CreateHotstring("*", "ballon" . ScriptInformation["MagicKey"], "🎈")
    CreateHotstring("*", "batterie" . ScriptInformation["MagicKey"], "🔋")
    CreateHotstring("*", "blanc" . ScriptInformation["MagicKey"], "🏳️")
    CreateHotstring("*", "bombe" . ScriptInformation["MagicKey"], "💣")
    CreateHotstring("*", "boussole" . ScriptInformation["MagicKey"], "🧭")
    CreateHotstring("*", "bougie" . ScriptInformation["MagicKey"], "🕯️")
    CreateHotstring("*", "cadeau" . ScriptInformation["MagicKey"], "🎁")
    CreateHotstring("*", "cadenas" . ScriptInformation["MagicKey"], "🔒")
    CreateHotstring("*", "calendrier" . ScriptInformation["MagicKey"], "📅")
    CreateHotstring("*", "caméra" . ScriptInformation["MagicKey"], "📷")
    CreateHotstring("*", "clavier" . ScriptInformation["MagicKey"], "⌨️")
    CreateHotstring("*", "check" . ScriptInformation["MagicKey"], "✔️")
    CreateHotstring("*", "clé" . ScriptInformation["MagicKey"], "🔑")
    CreateHotstring("*", "cloche" . ScriptInformation["MagicKey"], "🔔")
    CreateHotstring("*", "couronne" . ScriptInformation["MagicKey"], "👑")
    CreateHotstring("*", "croix" . ScriptInformation["MagicKey"], "❌")
    CreateHotstring("*", "danse" . ScriptInformation["MagicKey"], "💃")
    ; CreateHotstring("*", "dé" . ScriptInformation["MagicKey"], "🎲") ; Conflict with déjà
    CreateHotstring("*", "diamant" . ScriptInformation["MagicKey"], "💎")
    CreateHotstring("*", "drapeau" . ScriptInformation["MagicKey"], "🏁")
    CreateHotstring("*", "douche" . ScriptInformation["MagicKey"], "🛁")
    CreateHotstring("*", "éclair" . ScriptInformation["MagicKey"], "⚡")
    CreateHotstring("*", "eau" . ScriptInformation["MagicKey"], "💧")
    CreateHotstring("*", "email" . ScriptInformation["MagicKey"], "📧")
    CreateHotstring("*", "épée" . ScriptInformation["MagicKey"], "⚔️")
    CreateHotstring("*", "étoile" . ScriptInformation["MagicKey"], "⭐")
    CreateHotstring("*", "faux" . ScriptInformation["MagicKey"], "❌")
    CreateHotstring("*", "feu" . ScriptInformation["MagicKey"], "🔥")
    CreateHotstring("*", "fete" . ScriptInformation["MagicKey"], "🎉")
    CreateHotstring("*", "fête" . ScriptInformation["MagicKey"], "🎉")
    CreateHotstring("*", "film" . ScriptInformation["MagicKey"], "🎬")
    CreateHotstring("*", "fleur" . ScriptInformation["MagicKey"], "🌸")
    CreateHotstring("*", "fusée" . ScriptInformation["MagicKey"], "🚀")
    CreateHotstring("*", "guitare" . ScriptInformation["MagicKey"], "🎸")
    CreateHotstring("*", "idée" . ScriptInformation["MagicKey"], "💡")
    CreateHotstring("*", "idee" . ScriptInformation["MagicKey"], "💡")
    CreateHotstring("*", "interdit" . ScriptInformation["MagicKey"], "⛔")
    CreateHotstring("*", "journal" . ScriptInformation["MagicKey"], "📰")
    CreateHotstring("*", "ko" . ScriptInformation["MagicKey"], "❌")
    CreateHotstring("*", "livre" . ScriptInformation["MagicKey"], "📖")
    CreateHotstring("*", "loupe" . ScriptInformation["MagicKey"], "🔎")
    CreateHotstring("*", "lune" . ScriptInformation["MagicKey"], "🌙")
    ; CreateHotstring("*", "mail" . ScriptInformation["MagicKey"],  "📧") ; Conflict with "maillon"
    CreateHotstring("*", "médaille" . ScriptInformation["MagicKey"], "🥇")
    CreateHotstring("*", "medaille" . ScriptInformation["MagicKey"], "🥇")
    CreateHotstring("*", "microphone" . ScriptInformation["MagicKey"], "🎤")
    CreateHotstring("*", "montre" . ScriptInformation["MagicKey"], "⌚")
    CreateHotstring("*", "musique" . ScriptInformation["MagicKey"], "🎵")
    CreateHotstring("*", "noel" . ScriptInformation["MagicKey"], "🎄")
    CreateHotstring("*", "nuage" . ScriptInformation["MagicKey"], "☁️")
    CreateHotstring("*", "ok" . ScriptInformation["MagicKey"], "✅")
    CreateHotstring("*", "olaf" . ScriptInformation["MagicKey"], "⛄")
    CreateHotstring("*", "ordi" . ScriptInformation["MagicKey"], "💻")
    CreateHotstring("*", "ordinateur" . ScriptInformation["MagicKey"], "💻")
    CreateHotstring("*", "parapluie" . ScriptInformation["MagicKey"], "☂️")
    CreateHotstring("*", "pc" . ScriptInformation["MagicKey"], "💻")
    CreateHotstring("*", "piano" . ScriptInformation["MagicKey"], "🎹")
    CreateHotstring("*", "pirate" . ScriptInformation["MagicKey"], "🏴‍☠️")
    CreateHotstring("*", "pluie" . ScriptInformation["MagicKey"], "🌧️")
    CreateHotstring("*", "radioactif" . ScriptInformation["MagicKey"], "☢️")
    CreateHotstring("*", "regard" . ScriptInformation["MagicKey"], "👀")
    CreateHotstring("*", "robot" . ScriptInformation["MagicKey"], "🤖")
    CreateHotstring("*", "rocket" . ScriptInformation["MagicKey"], "🚀")
    CreateHotstring("*", "sacoche" . ScriptInformation["MagicKey"], "💼")
    CreateHotstring("*", "smartphone" . ScriptInformation["MagicKey"], "📱")
    CreateHotstring("*", "soleil" . ScriptInformation["MagicKey"], "☀️")
    CreateHotstring("*", "terre" . ScriptInformation["MagicKey"], "🌍")
    CreateHotstring("*", "thermomètre" . ScriptInformation["MagicKey"], "🌡️")
    CreateHotstring("*", "timer" . ScriptInformation["MagicKey"], "⏲️")
    CreateHotstring("*", "toilette" . ScriptInformation["MagicKey"], "🧻")
    CreateHotstring("*", "telephone" . ScriptInformation["MagicKey"], "☎️")
    CreateHotstring("*", "téléphone" . ScriptInformation["MagicKey"], "☎️")
    CreateHotstring("*", "train" . ScriptInformation["MagicKey"], "🚂")
    CreateHotstring("*", "vélo" . ScriptInformation["MagicKey"], "🚲")
    CreateHotstring("*", "voiture" . ScriptInformation["MagicKey"], "🚗")
    CreateHotstring("*", "yeux" . ScriptInformation["MagicKey"], "👀")

    ; === Food ===
    CreateHotstring("*", "ananas" . ScriptInformation["MagicKey"], "🍍")
    CreateHotstring("*", "aubergine" . ScriptInformation["MagicKey"], "🍆")
    CreateHotstring("*", "avocat" . ScriptInformation["MagicKey"], "🥑")
    CreateHotstring("*", "banane" . ScriptInformation["MagicKey"], "🍌")
    CreateHotstring("*", "bière" . ScriptInformation["MagicKey"], "🍺")
    CreateHotstring("*", "brocoli" . ScriptInformation["MagicKey"], "🥦")
    CreateHotstring("*", "burger" . ScriptInformation["MagicKey"], "🍔")
    CreateHotstring("*", "café" . ScriptInformation["MagicKey"], "☕")
    CreateHotstring("*", "carotte" . ScriptInformation["MagicKey"], "🥕")
    CreateHotstring("*", "cerise" . ScriptInformation["MagicKey"], "🍒")
    CreateHotstring("*", "champignon" . ScriptInformation["MagicKey"], "🍄")
    CreateHotstring("*", "chocolat" . ScriptInformation["MagicKey"], "🍫")
    CreateHotstring("*", "citron" . ScriptInformation["MagicKey"], "🍋")
    CreateHotstring("*", "coco" . ScriptInformation["MagicKey"], "🥥")
    CreateHotstring("*", "cookie" . ScriptInformation["MagicKey"], "🍪")
    CreateHotstring("*", "croissant" . ScriptInformation["MagicKey"], "🥐")
    CreateHotstring("*", "donut" . ScriptInformation["MagicKey"], "🍩")
    CreateHotstring("*", "fraise" . ScriptInformation["MagicKey"], "🍓")
    CreateHotstring("*", "frites" . ScriptInformation["MagicKey"], "🍟")
    CreateHotstring("*", "fromage" . ScriptInformation["MagicKey"], "🧀")
    CreateHotstring("*", "gâteau" . ScriptInformation["MagicKey"], "🎂")
    CreateHotstring("*", "glace" . ScriptInformation["MagicKey"], "🍦")
    CreateHotstring("*", "hamburger" . ScriptInformation["MagicKey"], "🍔")
    CreateHotstring("*", "hotdog" . ScriptInformation["MagicKey"], "🌭")
    CreateHotstring("*", "kebab" . ScriptInformation["MagicKey"], "🥙")
    CreateHotstring("*", "kiwi" . ScriptInformation["MagicKey"], "🥝")
    CreateHotstring("*", "lait" . ScriptInformation["MagicKey"], "🥛")
    CreateHotstring("*", "maïs" . ScriptInformation["MagicKey"], "🌽")
    CreateHotstring("*", "melon" . ScriptInformation["MagicKey"], "🍈")
    CreateHotstring("*", "miel" . ScriptInformation["MagicKey"], "🍯")
    CreateHotstring("*", "orange" . ScriptInformation["MagicKey"], "🍊")
    CreateHotstring("*", "pain" . ScriptInformation["MagicKey"], "🍞")
    CreateHotstring("*", "pastèque" . ScriptInformation["MagicKey"], "🍉")
    CreateHotstring("*", "pates" . ScriptInformation["MagicKey"], "🍝")
    CreateHotstring("*", "pêche" . ScriptInformation["MagicKey"], "🍑")
    CreateHotstring("*", "pizza" . ScriptInformation["MagicKey"], "🍕")
    CreateHotstring("*", "poire" . ScriptInformation["MagicKey"], "🍐")
    CreateHotstring("*", "pomme" . ScriptInformation["MagicKey"], "🍎")
    CreateHotstring("*", "popcorn" . ScriptInformation["MagicKey"], "🍿")
    CreateHotstring("*", "raisin" . ScriptInformation["MagicKey"], "🍇")
    CreateHotstring("*", "riz" . ScriptInformation["MagicKey"], "🍚")
    CreateHotstring("*", "salade" . ScriptInformation["MagicKey"], "🥗")
    CreateHotstring("*", "sandwich" . ScriptInformation["MagicKey"], "🥪")
    CreateHotstring("*", "spaghetti" . ScriptInformation["MagicKey"], "🍝")
    CreateHotstring("*", "taco" . ScriptInformation["MagicKey"], "🌮")
    CreateHotstring("*", "tacos" . ScriptInformation["MagicKey"], "🌮")
    CreateHotstring("*", "thé" . ScriptInformation["MagicKey"], "🍵")
    CreateHotstring("*", "tomate" . ScriptInformation["MagicKey"], "🍅")
    CreateHotstring("*", "vin" . ScriptInformation["MagicKey"], "🍷")

    ; === Expressions and emotions ===
    CreateHotstring("*", "amour" . ScriptInformation["MagicKey"], "🥰")
    CreateHotstring("*", "ange" . ScriptInformation["MagicKey"], "👼")
    CreateHotstring("*", "bisou" . ScriptInformation["MagicKey"], "😘")
    CreateHotstring("*", "bouche" . ScriptInformation["MagicKey"], "🤭")
    CreateHotstring("*", "caca" . ScriptInformation["MagicKey"], "💩")
    CreateHotstring("*", "clap" . ScriptInformation["MagicKey"], "👏")
    CreateHotstring("*", "clin" . ScriptInformation["MagicKey"], "😉")
    CreateHotstring("*", "cœur" . ScriptInformation["MagicKey"], "❤️")
    CreateHotstring("*", "coeur" . ScriptInformation["MagicKey"], "❤️")
    CreateHotstring("*", "colère" . ScriptInformation["MagicKey"], "😠")
    CreateHotstring("*", "cowboy" . ScriptInformation["MagicKey"], "🤠")
    CreateHotstring("*", "dégoût" . ScriptInformation["MagicKey"], "🤮")
    CreateHotstring("*", "délice" . ScriptInformation["MagicKey"], "😋")
    CreateHotstring("*", "délicieux" . ScriptInformation["MagicKey"], "😋")
    CreateHotstring("*", "diable" . ScriptInformation["MagicKey"], "😈")
    CreateHotstring("*", "dislike" . ScriptInformation["MagicKey"], "👎")
    CreateHotstring("*", "dodo" . ScriptInformation["MagicKey"], "😴")
    CreateHotstring("*", "effroi" . ScriptInformation["MagicKey"], "😱")
    CreateHotstring("*", "facepalm" . ScriptInformation["MagicKey"], "🤦")
    CreateHotstring("*", "fatigue" . ScriptInformation["MagicKey"], "😩")
    CreateHotstring("*", "fier" . ScriptInformation["MagicKey"], "😤")
    CreateHotstring("*", "fort" . ScriptInformation["MagicKey"], "💪")
    CreateHotstring("*", "fou" . ScriptInformation["MagicKey"], "🤪")
    CreateHotstring("*", "heureux" . ScriptInformation["MagicKey"], "😊")
    CreateHotstring("*", "innocent" . ScriptInformation["MagicKey"], "😇")
    CreateHotstring("*", "intello" . ScriptInformation["MagicKey"], "🤓")
    CreateHotstring("*", "larme" . ScriptInformation["MagicKey"], "😢")
    CreateHotstring("*", "larmes" . ScriptInformation["MagicKey"], "😭")
    CreateHotstring("*", "like" . ScriptInformation["MagicKey"], "👍")
    CreateHotstring("*", "lol" . ScriptInformation["MagicKey"], "😂")
    CreateHotstring("*", "lunettes" . ScriptInformation["MagicKey"], "🤓")
    CreateHotstring("*", "malade" . ScriptInformation["MagicKey"], "🤒")
    CreateHotstring("*", "masque" . ScriptInformation["MagicKey"], "😷")
    CreateHotstring("*", "mdr" . ScriptInformation["MagicKey"], "😂")
    CreateHotstring("*", "mignon" . ScriptInformation["MagicKey"], "🥺")
    CreateHotstring("*", "monocle" . ScriptInformation["MagicKey"], "🧐")
    CreateHotstring("*", "mort" . ScriptInformation["MagicKey"], "💀")
    CreateHotstring("*", "muscles" . ScriptInformation["MagicKey"], "💪")
    CreateHotstring("*", "(n)" . ScriptInformation["MagicKey"], "👎")
    CreateHotstring("*", "nice" . ScriptInformation["MagicKey"], "👌")
    CreateHotstring("*", "ouf" . ScriptInformation["MagicKey"], "😅")
    CreateHotstring("*", "oups" . ScriptInformation["MagicKey"], "😅")
    CreateHotstring("*", "parfait" . ScriptInformation["MagicKey"], "👌")
    CreateHotstring("*", "penser" . ScriptInformation["MagicKey"], "🤔")
    CreateHotstring("*", "pensif" . ScriptInformation["MagicKey"], "🤔")
    CreateHotstring("*", "peur" . ScriptInformation["MagicKey"], "😨")
    CreateHotstring("*", "pleur" . ScriptInformation["MagicKey"], "😭")
    CreateHotstring("*", "pleurer" . ScriptInformation["MagicKey"], "😭")
    CreateHotstring("*", "pouce" . ScriptInformation["MagicKey"], "👍")
    CreateHotstring("*", "rage" . ScriptInformation["MagicKey"], "😡")
    CreateHotstring("*", "rire" . ScriptInformation["MagicKey"], "😂")
    CreateHotstring("*", "silence" . ScriptInformation["MagicKey"], "🤫")
    CreateHotstring("*", "snif" . ScriptInformation["MagicKey"], "😢")
    CreateHotstring("*", "stress" . ScriptInformation["MagicKey"], "😰")
    CreateHotstring("*", "strong" . ScriptInformation["MagicKey"], "💪")
    CreateHotstring("*", "surprise" . ScriptInformation["MagicKey"], "😲")
    CreateHotstring("*", "timide" . ScriptInformation["MagicKey"], "😳")
    CreateHotstring("*", "triste" . ScriptInformation["MagicKey"], "😢")
    CreateHotstring("*", "victoire" . ScriptInformation["MagicKey"], "✌️")
    CreateHotstring("*", "(y)" . ScriptInformation["MagicKey"], "👍")
    CreateHotstring("*", "zombie" . ScriptInformation["MagicKey"], "🧟")
}

; ============================
; ======= 9.5) Symbols =======
; ============================

if Features["MagicKey"]["TextExpansionSymbols"].Enabled {
    ; === Fractions ===
    CreateHotstring("*C", "1/" . ScriptInformation["MagicKey"], "⅟")
    CreateHotstring("*C", "1/2" . ScriptInformation["MagicKey"], "½")
    CreateHotstring("*C", "0/3" . ScriptInformation["MagicKey"], "↉")
    CreateHotstring("*C", "1/3" . ScriptInformation["MagicKey"], "⅓")
    CreateHotstring("*C", "2/3" . ScriptInformation["MagicKey"], "⅔")
    CreateHotstring("*C", "1/4" . ScriptInformation["MagicKey"], "¼")
    CreateHotstring("*C", "3/4" . ScriptInformation["MagicKey"], "¾")
    CreateHotstring("*C", "1/5" . ScriptInformation["MagicKey"], "⅕")
    CreateHotstring("*C", "2/5" . ScriptInformation["MagicKey"], "⅖")
    CreateHotstring("*C", "3/5" . ScriptInformation["MagicKey"], "⅗")
    CreateHotstring("*C", "4/5" . ScriptInformation["MagicKey"], "⅘")
    CreateHotstring("*C", "1/6" . ScriptInformation["MagicKey"], "⅙")
    CreateHotstring("*C", "5/6" . ScriptInformation["MagicKey"], "⅚")
    CreateHotstring("*C", "1/8" . ScriptInformation["MagicKey"], "⅛")
    CreateHotstring("*C", "3/8" . ScriptInformation["MagicKey"], "⅜")
    CreateHotstring("*C", "5/8" . ScriptInformation["MagicKey"], "⅝")
    CreateHotstring("*C", "7/8" . ScriptInformation["MagicKey"], "⅞")
    CreateHotstring("*C", "1/7" . ScriptInformation["MagicKey"], "⅐")
    CreateHotstring("*C", "1/9" . ScriptInformation["MagicKey"], "⅑")
    CreateHotstring("*C", "1/10" . ScriptInformation["MagicKey"], "⅒")

    ; === Numbers ===
    CreateHotstring("*C", "(0)" . ScriptInformation["MagicKey"], "🄋")
    CreateHotstring("*C", "(1)" . ScriptInformation["MagicKey"], "➀")
    CreateHotstring("*C", "(2)" . ScriptInformation["MagicKey"], "➁")
    CreateHotstring("*C", "(3)" . ScriptInformation["MagicKey"], "➂")
    CreateHotstring("*C", "(4)" . ScriptInformation["MagicKey"], "➃")
    CreateHotstring("*C", "(5)" . ScriptInformation["MagicKey"], "➄")
    CreateHotstring("*C", "(6)" . ScriptInformation["MagicKey"], "➅")
    CreateHotstring("*C", "(7)" . ScriptInformation["MagicKey"], "➆")
    CreateHotstring("*C", "(8)" . ScriptInformation["MagicKey"], "➇")
    CreateHotstring("*C", "(9)" . ScriptInformation["MagicKey"], "➈")
    CreateHotstring("*C", "(10)" . ScriptInformation["MagicKey"], "➉")
    CreateHotstring("*C", "(0n)" . ScriptInformation["MagicKey"], "🄌")
    CreateHotstring("*C", "(1n)" . ScriptInformation["MagicKey"], "➊")
    CreateHotstring("*C", "(2n)" . ScriptInformation["MagicKey"], "➋")
    CreateHotstring("*C", "(3n)" . ScriptInformation["MagicKey"], "➌")
    CreateHotstring("*C", "(4n)" . ScriptInformation["MagicKey"], "➍")
    CreateHotstring("*C", "(5n)" . ScriptInformation["MagicKey"], "➎")
    CreateHotstring("*C", "(6n)" . ScriptInformation["MagicKey"], "➏")
    CreateHotstring("*C", "(7n)" . ScriptInformation["MagicKey"], "➐")
    CreateHotstring("*C", "(8n)" . ScriptInformation["MagicKey"], "➑")
    CreateHotstring("*C", "(9n)" . ScriptInformation["MagicKey"], "➒")
    CreateHotstring("*C", "(10n)" . ScriptInformation["MagicKey"], "➓")
    CreateHotstring("*C", "(0b)" . ScriptInformation["MagicKey"], "𝟎") ; B for Bold
    CreateHotstring("*C", "(1b)" . ScriptInformation["MagicKey"], "𝟏")
    CreateHotstring("*C", "(2b)" . ScriptInformation["MagicKey"], "𝟐")
    CreateHotstring("*C", "(3b)" . ScriptInformation["MagicKey"], "𝟑")
    CreateHotstring("*C", "(4b)" . ScriptInformation["MagicKey"], "𝟒")
    CreateHotstring("*C", "(5b)" . ScriptInformation["MagicKey"], "𝟓")
    CreateHotstring("*C", "(6b)" . ScriptInformation["MagicKey"], "𝟔")
    CreateHotstring("*C", "(7b)" . ScriptInformation["MagicKey"], "𝟕")
    CreateHotstring("*C", "(8b)" . ScriptInformation["MagicKey"], "𝟖")
    CreateHotstring("*C", "(9b)" . ScriptInformation["MagicKey"], "𝟗")
    CreateHotstring("*C", "(0g)" . ScriptInformation["MagicKey"], "𝟬") ; G for Gras
    CreateHotstring("*C", "(1g)" . ScriptInformation["MagicKey"], "𝟭")
    CreateHotstring("*C", "(2g)" . ScriptInformation["MagicKey"], "𝟮")
    CreateHotstring("*C", "(3g)" . ScriptInformation["MagicKey"], "𝟯")
    CreateHotstring("*C", "(4g)" . ScriptInformation["MagicKey"], "𝟰")
    CreateHotstring("*C", "(5g)" . ScriptInformation["MagicKey"], "𝟱")
    CreateHotstring("*C", "(6g)" . ScriptInformation["MagicKey"], "𝟲")
    CreateHotstring("*C", "(7g)" . ScriptInformation["MagicKey"], "𝟳")
    CreateHotstring("*C", "(8g)" . ScriptInformation["MagicKey"], "𝟴")
    CreateHotstring("*C", "(9g)" . ScriptInformation["MagicKey"], "𝟵")

    ; === Mathematical symbols ===
    CreateHotstring("*C", "(infini)" . ScriptInformation["MagicKey"], "∞")
    CreateHotstring("*C", "(product)" . ScriptInformation["MagicKey"], "∏")
    CreateHotstring("*C", "(produit)" . ScriptInformation["MagicKey"], "∏")
    CreateHotstring("*C", "(coproduct)" . ScriptInformation["MagicKey"], "∐")
    CreateHotstring("*C", "(coproduit)" . ScriptInformation["MagicKey"], "∐")
    CreateHotstring("*C", "(forall)" . ScriptInformation["MagicKey"], "∀")
    CreateHotstring("*C", "(for all)" . ScriptInformation["MagicKey"], "∀")
    CreateHotstring("*C", "(pour tout)" . ScriptInformation["MagicKey"], "∀")
    CreateHotstring("*C", "(exist)" . ScriptInformation["MagicKey"], "∃")
    CreateHotstring("*C", "(exists)" . ScriptInformation["MagicKey"], "∃")
    CreateHotstring("*C", "(vide)" . ScriptInformation["MagicKey"], "∅")
    CreateHotstring("*C", "(ensemble vide)" . ScriptInformation["MagicKey"], "∅")
    CreateHotstring("*C", "(void)" . ScriptInformation["MagicKey"], "∅")
    CreateHotstring("*C", "(empty)" . ScriptInformation["MagicKey"], "∅")
    CreateHotstring("*C", "(prop)" . ScriptInformation["MagicKey"], "∝")
    CreateHotstring("*C", "(proportionnel)" . ScriptInformation["MagicKey"], "∝")
    CreateHotstring("*C", "(proportionnal)" . ScriptInformation["MagicKey"], "∝")
    CreateHotstring("*C", "(union)" . ScriptInformation["MagicKey"], "∪")
    CreateHotstring("*C", "(intersection)" . ScriptInformation["MagicKey"], "⋂")
    CreateHotstring("*C", "(appartient)" . ScriptInformation["MagicKey"], "∈")
    CreateHotstring("*C", "(inclus)" . ScriptInformation["MagicKey"], "⊂")
    CreateHotstring("*C", "(non inclus)" . ScriptInformation["MagicKey"], "⊄")
    CreateHotstring("*C", "(non appartient)" . ScriptInformation["MagicKey"], "∉")
    CreateHotstring("*C", "(n’appartient pas)" . ScriptInformation["MagicKey"], "∉")
    CreateHotstring("*C", "(non)" . ScriptInformation["MagicKey"], "¬")
    CreateHotstring("*C", "(et)" . ScriptInformation["MagicKey"], "∧")
    CreateHotstring("*C", "(sqrt)" . ScriptInformation["MagicKey"], "√")
    CreateHotstring("*C", "(racine)" . ScriptInformation["MagicKey"], "√")
    CreateHotstring("*C", "(^)" . ScriptInformation["MagicKey"], "∧")
    CreateHotstring("*C", "(delta)" . ScriptInformation["MagicKey"], "∆")
    CreateHotstring("*C", "(nabla)" . ScriptInformation["MagicKey"], "∇")
    CreateHotstring("*C", "(<<)" . ScriptInformation["MagicKey"], "≪")
    CreateHotstring("*C", "(partial)" . ScriptInformation["MagicKey"], "∂")
    CreateHotstring("*C", "(end of proof)" . ScriptInformation["MagicKey"], "∎")
    CreateHotstring("*C", "(eop)" . ScriptInformation["MagicKey"], "∎")
    ; Integrals
    CreateHotstring("*C", "(int)" . ScriptInformation["MagicKey"], "∫")
    CreateHotstring("*C", "(s)" . ScriptInformation["MagicKey"], "∫")
    CreateHotstring("*C", "(so)" . ScriptInformation["MagicKey"], "∮")
    CreateHotstring("*C", "(sso)" . ScriptInformation["MagicKey"], "∯")
    CreateHotstring("*C", "(sss)" . ScriptInformation["MagicKey"], "∭")
    CreateHotstring("*C", "(ssso)" . ScriptInformation["MagicKey"], "∰")
    ; Relations
    CreateHotstring("*C", "(=)" . ScriptInformation["MagicKey"], "≡")
    CreateHotstring("*C", "(equivalent)" . ScriptInformation["MagicKey"], "⇔")
    CreateHotstring("*C", "(équivalent)" . ScriptInformation["MagicKey"], "⇔")
    CreateHotstring("*C", "(implique)" . ScriptInformation["MagicKey"], "⇒")
    CreateHotstring("*C", "(impliqué)" . ScriptInformation["MagicKey"], "⇒")
    CreateHotstring("*C", "(imply)" . ScriptInformation["MagicKey"], "⇒")
    CreateHotstring("*C", "(non implique)" . ScriptInformation["MagicKey"], "⇏")
    CreateHotstring("*C", "(non impliqué)" . ScriptInformation["MagicKey"], "⇏")
    CreateHotstring("*C", "(non équivalent)" . ScriptInformation["MagicKey"], "⇎")
    CreateHotstring("*C", "(not equivalent)" . ScriptInformation["MagicKey"], "⇎")

    ; === Arrows ===
    CreateHotstring("*C", " -> " . ScriptInformation["MagicKey"], " ➜ ")
    CreateHotstring("*C", "-->" . ScriptInformation["MagicKey"], " ➜ ")
    CreateHotstring("*C", ">" . ScriptInformation["MagicKey"], "➢") ; ATtention, order matters, needs to be after -->
    CreateHotstring("*C", "==>" . ScriptInformation["MagicKey"], "⇒")
    CreateHotstring("*C", "=/=>" . ScriptInformation["MagicKey"], "⇏")
    CreateHotstring("*C", "<==" . ScriptInformation["MagicKey"], "⇐")
    CreateHotstring("*C", "<==>" . ScriptInformation["MagicKey"], "⇔")
    CreateHotstring("*C", "<=/=>" . ScriptInformation["MagicKey"], "⇎")
    CreateHotstring("*C", "<=>" . ScriptInformation["MagicKey"], "⇔")
    CreateHotstring("*C", "^|" . ScriptInformation["MagicKey"], "↑")
    CreateHotstring("*C", "|^" . ScriptInformation["MagicKey"], "↓")
    CreateHotstring("*C", "->" . ScriptInformation["MagicKey"], "→")
    CreateHotstring("*C", "<-" . ScriptInformation["MagicKey"], "←")
    CreateHotstring("*C", "->>" . ScriptInformation["MagicKey"], "➡")
    CreateHotstring("*C", "<<-" . ScriptInformation["MagicKey"], "⬅")
    CreateHotstring("*C", "|->" . ScriptInformation["MagicKey"], "↪")
    CreateHotstring("*C", "<-|" . ScriptInformation["MagicKey"], "↩")
    CreateHotstring("*C", "^|-" . ScriptInformation["MagicKey"], "⭮")

    ; === Checks and checkboxes ===
    CreateHotstring("*C", "(v)" . ScriptInformation["MagicKey"], "✓")
    CreateHotstring("*C", "(x)" . ScriptInformation["MagicKey"], "✗")
    CreateHotstring("*C", "[v]" . ScriptInformation["MagicKey"], "☑")
    CreateHotstring("*C", "[x]" . ScriptInformation["MagicKey"], "☒")

    ; === Miscellaneous symbols ===
    CreateHotstring("*C", "/!\" . ScriptInformation["MagicKey"], "⚠")
    CreateHotstring("*C", "**" . ScriptInformation["MagicKey"], "⁂")
    CreateHotstring("*C", "°C" . ScriptInformation["MagicKey"], "℃")
    CreateHotstring("*C", "(b)" . ScriptInformation["MagicKey"], "•")
    CreateHotstring("*C", "(c)" . ScriptInformation["MagicKey"], "©")
    CreateHotstring("*", "eme" . ScriptInformation["MagicKey"], "ᵉ")
    CreateHotstring("*", "ème" . ScriptInformation["MagicKey"], "ᵉ")
    CreateHotstring("*", "ieme" . ScriptInformation["MagicKey"], "ᵉ")
    CreateHotstring("*", "ième" . ScriptInformation["MagicKey"], "ᵉ")
    CreateHotstring("*C", "(o)" . ScriptInformation["MagicKey"], "•")
    CreateHotstring("*C", "(r)" . ScriptInformation["MagicKey"], "®")
    CreateHotstring("*C", "(tm)" . ScriptInformation["MagicKey"], "™")
}

if Features["MagicKey"]["TextExpansionSymbolsTypst"].Enabled {
    ; https://typst.app/docs/reference/symbols/sym/ to search for a symbol.
    ; List scrapped here: https://github.com/typst/codex/tree/main/src/modules/sym.txt

    ; === Control ===
    CreateHotstring("*C", "$wj$", "{U+2060}", Map("OnlyText", False))
    CreateHotstring("*C", "$zwj$", "{U+200D}", Map("OnlyText", False))
    CreateHotstring("*C", "$zwnj$", "{U+200C}", Map("OnlyText", False))
    CreateHotstring("*C", "$zws$", "{U+200B}", Map("OnlyText", False))
    CreateHotstring("*C", "$lrm$", "{U+200E}", Map("OnlyText", False))
    CreateHotstring("*C", "$rlm$", "{U+200F}", Map("OnlyText", False))

    ; === Spaces ===
    CreateHotstring("*C", "$space$", "{U+0020}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.nobreak$", "{U+00A0}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.nobreak.narrow$", "{U+202F}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.en$", "{U+2002}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.quad$", "{U+2003}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.third$", "{U+2004}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.quarter$", "{U+2005}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.sixth$", "{U+2006}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.med$", "{U+205F}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.fig$", "{U+2007}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.punct$", "{U+2008}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.thin$", "{U+2009}", Map("OnlyText", False))
    CreateHotstring("*C", "$space.hair$", "{U+200A}", Map("OnlyText", False))

    ; === Delimiters ===
    ; Paren
    CreateHotstring("*C", "$paren.l$", "(")
    CreateHotstring("*C", "$paren.l.flat$", "⟮")
    CreateHotstring("*C", "$paren.l.closed$", "⦇")
    CreateHotstring("*C", "$paren.l.stroked$", "⦅")
    CreateHotstring("*C", "$paren.l.double$", "⦅")
    CreateHotstring("*C", "$paren.r$", ")")
    CreateHotstring("*C", "$paren.r.flat$", "⟯")
    CreateHotstring("*C", "$paren.r.closed$", "⦈")
    CreateHotstring("*C", "$paren.r.stroked$", "⦆")
    CreateHotstring("*C", "$paren.r.double$", "⦆")
    CreateHotstring("*C", "$paren.t$", "⏜")
    CreateHotstring("*C", "$paren.b$", "⏝")
    ; Brace
    CreateHotstring("*C", "$brace.l$", "{")
    CreateHotstring("*C", "$brace.l.stroked$", "{U+27C3}", Map("OnlyText", False))
    CreateHotstring("*C", "$brace.l.double$", "{U+27C3}", Map("OnlyText", False))
    CreateHotstring("*C", "$brace.r$", "}")
    CreateHotstring("*C", "$brace.r.stroked$", "⦄")
    CreateHotstring("*C", "$brace.r.double$", "⦄")
    CreateHotstring("*C", "$brace.t$", "⏞")
    CreateHotstring("*C", "$brace.b$", "⏟")
    ; Bracket
    CreateHotstring("*C", "$bracket.l$", "[")
    CreateHotstring("*C", "$bracket.l.tick.t$", "⦍")
    CreateHotstring("*C", "$bracket.l.tick.b$", "⦏")
    CreateHotstring("*C", "$bracket.l.stroked$", "⟦")
    CreateHotstring("*C", "$bracket.l.double$", "⟦")
    CreateHotstring("*C", "$bracket.r$", "]")
    CreateHotstring("*C", "$bracket.r.tick.t$", "⦐")
    CreateHotstring("*C", "$bracket.r.tick.b$", "⦎")
    CreateHotstring("*C", "$bracket.r.stroked$", "⟧")
    CreateHotstring("*C", "$bracket.r.double$", "⟧")
    CreateHotstring("*C", "$bracket.t$", "⎴")
    CreateHotstring("*C", "$bracket.b$", "⎵")
    ; Shell
    CreateHotstring("*C", "$shell.l$", "❲")
    CreateHotstring("*C", "$shell.l.stroked$", "⟬")
    CreateHotstring("*C", "$shell.l.filled$", "⦗")
    CreateHotstring("*C", "$shell.l.double$", "⟬")
    CreateHotstring("*C", "$shell.r$", "❳")
    CreateHotstring("*C", "$shell.r.stroked$", "⟭")
    CreateHotstring("*C", "$shell.r.filled$", "⦘")
    CreateHotstring("*C", "$shell.r.double$", "⟭")
    CreateHotstring("*C", "$shell.t$", "⏠")
    CreateHotstring("*C", "$shell.b$", "⏡")
    ; Bag
    CreateHotstring("*C", "$bag.l$", "⟅")
    CreateHotstring("*C", "$bag.r$", "⟆")
    ; Mustache
    CreateHotstring("*C", "$mustache.l$", "⎰")
    CreateHotstring("*C", "$mustache.r$", "⎱")
    ; Bar
    CreateHotstring("*C", "$bar.v$", "|")
    CreateHotstring("*C", "$bar.v.double$", "‖")
    CreateHotstring("*C", "$bar.v.triple$", "⦀")
    CreateHotstring("*C", "$bar.v.broken$", "¦")
    CreateHotstring("*C", "$bar.v.o$", "⦶")
    CreateHotstring("*C", "$bar.v.circle$", "⦶")
    CreateHotstring("*C", "$bar.h$", "―")
    ; Fence
    CreateHotstring("*C", "$fence.l$", "⧘")
    CreateHotstring("*C", "$fence.l.double$", "⧚")
    CreateHotstring("*C", "$fence.r$", "⧙")
    CreateHotstring("*C", "$fence.r.double$", "⧛")
    CreateHotstring("*C", "$fence.dotted$", "⦙")
    ; Chevron
    CreateHotstring("*C", "$chevron.l$", "⟨")
    CreateHotstring("*C", "$chevron.l.curly$", "⧼")
    CreateHotstring("*C", "$chevron.l.dot$", "⦑")
    CreateHotstring("*C", "$chevron.l.closed$", "⦉")
    CreateHotstring("*C", "$chevron.l.double$", "⟪")
    CreateHotstring("*C", "$chevron.r$", "⟩")
    CreateHotstring("*C", "$chevron.r.curly$", "⧽")
    CreateHotstring("*C", "$chevron.r.dot$", "⦒")
    CreateHotstring("*C", "$chevron.r.closed$", "⦊")
    CreateHotstring("*C", "$chevron.r.double$", "⟫")
    ; Ceil
    CreateHotstring("*C", "$ceil.l$", "⌈")
    CreateHotstring("*C", "$ceil.r$", "⌉")
    ; Floor
    CreateHotstring("*C", "$floor.l$", "⌊")
    CreateHotstring("*C", "$floor.r$", "⌋")
    ; Corner
    CreateHotstring("*C", "$corner.l.t$", "⌜")
    CreateHotstring("*C", "$corner.l.b$", "⌞")
    CreateHotstring("*C", "$corner.r.t$", "⌝")
    CreateHotstring("*C", "$corner.r.b$", "⌟")

    ; === Punctuation ===
    CreateHotstring("*C", "$amp$", "&")
    CreateHotstring("*C", "$amp.inv$", "⅋")
    ; Ast
    CreateHotstring("*C", "$ast.op$", "∗")
    CreateHotstring("*C", "$ast.op.o$", "⊛")
    CreateHotstring("*C", "$ast.basic$", "*")
    CreateHotstring("*C", "$ast.low$", "⁎")
    CreateHotstring("*C", "$ast.double$", "⁑")
    CreateHotstring("*C", "$ast.triple$", "⁂")
    CreateHotstring("*C", "$ast.small$", "﹡")
    CreateHotstring("*C", "$ast.circle$", "⊛")
    CreateHotstring("*C", "$ast.square$", "⧆")
    CreateHotstring("*C", "$at$", "@")
    CreateHotstring("*C", "$backslash$", "\")
    CreateHotstring("*C", "$backslash.o$", "⦸")
    CreateHotstring("*C", "$backslash.circle$", "⦸")
    CreateHotstring("*C", "$backslash.not$", "⧷")
    CreateHotstring("*C", "$co$", "℅")
    CreateHotstring("*C", "$colon$", ":")
    CreateHotstring("*C", "$colon.currency$", "₡")
    CreateHotstring("*C", "$colon.double$", "∷")
    CreateHotstring("*C", "$colon.tri$", "⁝")
    CreateHotstring("*C", "$colon.tri.op$", "⫶")
    CreateHotstring("*C", "$colon.eq$", "≔")
    CreateHotstring("*C", "$colon.double.eq$", "⩴")
    CreateHotstring("*C", "$comma$", ",")
    CreateHotstring("*C", "$comma.inv$", "⸲")
    CreateHotstring("*C", "$comma.rev$", "⹁")
    CreateHotstring("*C", "$dagger$", "†")
    CreateHotstring("*C", "$dagger.double$", "‡")
    CreateHotstring("*C", "$dagger.triple$", "⹋")
    CreateHotstring("*C", "$dagger.l$", "⸶")
    CreateHotstring("*C", "$dagger.r$", "⸷")
    CreateHotstring("*C", "$dagger.inv$", "⸸")
    ; Dash
    CreateHotstring("*C", "$dash.en$", "–")
    CreateHotstring("*C", "$dash.em$", "—")
    CreateHotstring("*C", "$dash.em.two$", "⸺")
    CreateHotstring("*C", "$dash.em.three$", "⸻")
    CreateHotstring("*C", "$dash.fig$", "‒")
    CreateHotstring("*C", "$dash.wave$", "〜")
    CreateHotstring("*C", "$dash.colon$", "∹")
    CreateHotstring("*C", "$dash.o$", "⊝")
    CreateHotstring("*C", "$dash.circle$", "⊝")
    CreateHotstring("*C", "$dash.wave.double$", "〰")
    ; Dot
    CreateHotstring("*C", "$dot.op$", "⋅")
    CreateHotstring("*C", "$dot.basic$", ".")
    CreateHotstring("*C", "$dot.c$", "·")
    CreateHotstring("*C", "$dot.o$", "⊙")
    CreateHotstring("*C", "$dot.o.big$", "⨀")
    CreateHotstring("*C", "$dot.circle$", "⊙")
    CreateHotstring("*C", "$dot.circle.big$", "⨀")
    CreateHotstring("*C", "$dot.square$", "⊡")
    CreateHotstring("*C", "$dot.double$", "¨")
    CreateHotstring("*C", "$dot.triple$", "{U+20DB}", Map("OnlyText", False))
    CreateHotstring("*C", "$dot.quad$", "{U+20DC}", Map("OnlyText", False))
    CreateHotstring("*C", "$excl$", "!")
    CreateHotstring("*C", "$excl.double$", "‼")
    CreateHotstring("*C", "$excl.inv$", "¡")
    CreateHotstring("*C", "$excl.quest$", "⁉")
    CreateHotstring("*C", "$quest$", "?")
    CreateHotstring("*C", "$quest.double$", "⁇")
    CreateHotstring("*C", "$quest.excl$", "⁈")
    CreateHotstring("*C", "$quest.inv$", "¿")
    CreateHotstring("*C", "$interrobang$", "‽")
    CreateHotstring("*C", "$interrobang.inv$", "⸘")
    CreateHotstring("*C", "$hash$", "#")
    CreateHotstring("*C", "$hyph$", "‐")
    CreateHotstring("*C", "$hyph.minus$", "-")
    CreateHotstring("*C", "$hyph.nobreak$", "{U+2011}", Map("OnlyText", False))
    CreateHotstring("*C", "$hyph.point$", "‧")
    CreateHotstring("*C", "$hyph.soft$", "{U+00AD}", Map("OnlyText", False))
    CreateHotstring("*C", "$numero$", "№")
    CreateHotstring("*C", "$percent$", "%")
    CreateHotstring("*C", "$permille$", "‰")
    CreateHotstring("*C", "$permyriad$", "‱")
    CreateHotstring("*C", "$pilcrow$", "¶")
    CreateHotstring("*C", "$pilcrow.rev$", "⁋")
    CreateHotstring("*C", "$section$", "§")
    CreateHotstring("*C", "$semi$", ";")
    CreateHotstring("*C", "$semi.inv$", "⸵")
    CreateHotstring("*C", "$semi.rev$", "⁏")
    CreateHotstring("*C", "$slash$", "/")
    CreateHotstring("*C", "$slash.o$", "⊘")
    CreateHotstring("*C", "$slash.double$", "⫽")
    CreateHotstring("*C", "$slash.triple$", "⫻")
    CreateHotstring("*C", "$slash.big$", "⧸")
    ; Dots
    CreateHotstring("*C", "$dots.h.c$", "⋯")
    CreateHotstring("*C", "$dots.h$", "…")
    CreateHotstring("*C", "$dots.v$", "⋮")
    CreateHotstring("*C", "$dots.down$", "⋱")
    CreateHotstring("*C", "$dots.up$", "⋰")
    ; Tilde
    CreateHotstring("*C", "$tilde.op$", "∼")
    CreateHotstring("*C", "$tilde.basic$", "~")
    CreateHotstring("*C", "$tilde.dot$", "⩪")
    CreateHotstring("*C", "$tilde.eq$", "≃")
    CreateHotstring("*C", "$tilde.eq.not$", "≄")
    CreateHotstring("*C", "$tilde.eq.rev$", "⋍")
    CreateHotstring("*C", "$tilde.equiv$", "≅")
    CreateHotstring("*C", "$tilde.equiv.not$", "≇")
    CreateHotstring("*C", "$tilde.nequiv$", "≆")
    CreateHotstring("*C", "$tilde.not$", "≁")
    CreateHotstring("*C", "$tilde.rev$", "∽")
    CreateHotstring("*C", "$tilde.rev.equiv$", "≌")
    CreateHotstring("*C", "$tilde.triple$", "≋")

    ; === Accents, quotes, and primes ===
    CreateHotstring("*C", "$acute$", "´")
    CreateHotstring("*C", "$acute.double$", "˝")
    CreateHotstring("*C", "$breve$", "˘")
    CreateHotstring("*C", "$caret$", "‸")
    CreateHotstring("*C", "$caron$", "ˇ")
    CreateHotstring("*C", "$hat$", "^")
    CreateHotstring("*C", "$diaer$", "¨")
    CreateHotstring("*C", "$grave$", "``")
    CreateHotstring("*C", "$macron$", "¯")
    ; Quote
    CreateHotstring("*C", "$quote.double$", "`"")
    CreateHotstring("*C", "$quote.single$", "'")
    CreateHotstring("*C", "$quote.l.double$", "“")
    CreateHotstring("*C", "$quote.l.single$", "‘")
    CreateHotstring("*C", "$quote.r.double$", "”")
    CreateHotstring("*C", "$quote.r.single$", "’")
    CreateHotstring("*C", "$quote.chevron.l.double$", "«")
    CreateHotstring("*C", "$quote.chevron.l.single$", "‹")
    CreateHotstring("*C", "$quote.chevron.r.double$", "»")
    CreateHotstring("*C", "$quote.chevron.r.single$", "›")
    CreateHotstring("*C", "$quote.angle.l.double$", "«")
    CreateHotstring("*C", "$quote.angle.l.single$", "‹")
    CreateHotstring("*C", "$quote.angle.r.double$", "»")
    CreateHotstring("*C", "$quote.angle.r.single$", "›")
    CreateHotstring("*C", "$quote.high.double$", "‟")
    CreateHotstring("*C", "$quote.high.single$", "‛")
    CreateHotstring("*C", "$quote.low.double$", "„")
    CreateHotstring("*C", "$quote.low.single$", "‚")
    CreateHotstring("*C", "$prime$", "′")
    CreateHotstring("*C", "$prime.rev$", "‵")
    CreateHotstring("*C", "$prime.double$", "″")
    CreateHotstring("*C", "$prime.double.rev$", "‶")
    CreateHotstring("*C", "$prime.triple$", "‴")
    CreateHotstring("*C", "$prime.triple.rev$", "‷")
    CreateHotstring("*C", "$prime.quad$", "⁗")

    ; === Arithmetic ===
    CreateHotstring("*C", "$plus$", "+")
    CreateHotstring("*C", "$plus.o$", "⊕")
    CreateHotstring("*C", "$plus.o.l$", "⨭")
    CreateHotstring("*C", "$plus.o.r$", "⨮")
    CreateHotstring("*C", "$plus.o.arrow$", "⟴")
    CreateHotstring("*C", "$plus.o.big$", "⨁")
    CreateHotstring("*C", "$plus.circle$", "⊕")
    CreateHotstring("*C", "$plus.circle.arrow$", "⟴")
    CreateHotstring("*C", "$plus.circle.big$", "⨁")
    CreateHotstring("*C", "$plus.dot$", "∔")
    CreateHotstring("*C", "$plus.double$", "⧺")
    CreateHotstring("*C", "$plus.minus$", "±")
    CreateHotstring("*C", "$plus.small$", "﹢")
    CreateHotstring("*C", "$plus.square$", "⊞")
    CreateHotstring("*C", "$plus.triangle$", "⨹")
    CreateHotstring("*C", "$plus.triple$", "⧻")
    CreateHotstring("*C", "$minus$", "−")
    CreateHotstring("*C", "$minus.o$", "⊖")
    CreateHotstring("*C", "$minus.circle$", "⊖")
    CreateHotstring("*C", "$minus.dot$", "∸")
    CreateHotstring("*C", "$minus.plus$", "∓")
    CreateHotstring("*C", "$minus.square$", "⊟")
    CreateHotstring("*C", "$minus.tilde$", "≂")
    CreateHotstring("*C", "$minus.triangle$", "⨺")
    CreateHotstring("*C", "$div$", "÷")
    CreateHotstring("*C", "$div.o$", "⨸")
    CreateHotstring("*C", "$div.slanted.o$", "⦼")
    CreateHotstring("*C", "$div.circle$", "⨸")
    CreateHotstring("*C", "$times$", "×")
    CreateHotstring("*C", "$times.big$", "⨉")
    CreateHotstring("*C", "$times.o$", "⊗")
    CreateHotstring("*C", "$times.o.l$", "⨴")
    CreateHotstring("*C", "$times.o.r$", "⨵")
    CreateHotstring("*C", "$times.o.hat$", "⨶")
    CreateHotstring("*C", "$times.o.big$", "⨂")
    CreateHotstring("*C", "$times.circle$", "⊗")
    CreateHotstring("*C", "$times.circle.big$", "⨂")
    CreateHotstring("*C", "$times.div$", "⋇")
    CreateHotstring("*C", "$times.three.l$", "⋋")
    CreateHotstring("*C", "$times.three.r$", "⋌")
    CreateHotstring("*C", "$times.l$", "⋉")
    CreateHotstring("*C", "$times.r$", "⋊")
    CreateHotstring("*C", "$times.square$", "⊠")
    CreateHotstring("*C", "$times.triangle$", "⨻")
    CreateHotstring("*C", "$ratio$", "∶")

    ; === Relations ===
    CreateHotstring("*C", "$eq$", "=")
    CreateHotstring("*C", "$eq.star$", "≛")
    CreateHotstring("*C", "$eq.o$", "⊜")
    CreateHotstring("*C", "$eq.circle$", "⊜")
    CreateHotstring("*C", "$eq.colon$", "≕")
    CreateHotstring("*C", "$eq.dots$", "≑")
    CreateHotstring("*C", "$eq.dots.down$", "≒")
    CreateHotstring("*C", "$eq.dots.up$", "≓")
    CreateHotstring("*C", "$eq.def$", "≝")
    CreateHotstring("*C", "$eq.delta$", "≜")
    CreateHotstring("*C", "$eq.equi$", "≚")
    CreateHotstring("*C", "$eq.est$", "≙")
    CreateHotstring("*C", "$eq.gt$", "⋝")
    CreateHotstring("*C", "$eq.lt$", "⋜")
    CreateHotstring("*C", "$eq.m$", "≞")
    CreateHotstring("*C", "$eq.not$", "≠")
    CreateHotstring("*C", "$eq.prec$", "⋞")
    CreateHotstring("*C", "$eq.quest$", "≟")
    CreateHotstring("*C", "$eq.small$", "﹦")
    CreateHotstring("*C", "$eq.succ$", "⋟")
    CreateHotstring("*C", "$eq.triple$", "≡")
    CreateHotstring("*C", "$eq.triple.not$", "≢")
    CreateHotstring("*C", "$eq.quad$", "≣")
    CreateHotstring("*C", "$gt$", ">")
    CreateHotstring("*C", "$gt.o$", "⧁")
    CreateHotstring("*C", "$gt.circle$", "⧁")
    CreateHotstring("*C", "$gt.dot$", "⋗")
    CreateHotstring("*C", "$gt.approx$", "⪆")
    CreateHotstring("*C", "$gt.double$", "≫")
    CreateHotstring("*C", "$gt.eq$", "≥")
    CreateHotstring("*C", "$gt.eq.slant$", "⩾")
    CreateHotstring("*C", "$gt.eq.lt$", "⋛")
    CreateHotstring("*C", "$gt.eq.not$", "≱")
    CreateHotstring("*C", "$gt.equiv$", "≧")
    CreateHotstring("*C", "$gt.lt$", "≷")
    CreateHotstring("*C", "$gt.lt.not$", "≹")
    CreateHotstring("*C", "$gt.neq$", "⪈")
    CreateHotstring("*C", "$gt.napprox$", "⪊")
    CreateHotstring("*C", "$gt.nequiv$", "≩")
    CreateHotstring("*C", "$gt.not$", "≯")
    CreateHotstring("*C", "$gt.ntilde$", "⋧")
    CreateHotstring("*C", "$gt.small$", "﹥")
    CreateHotstring("*C", "$gt.tilde$", "≳")
    CreateHotstring("*C", "$gt.tilde.not$", "≵")
    CreateHotstring("*C", "$gt.tri$", "⊳")
    CreateHotstring("*C", "$gt.tri.eq$", "⊵")
    CreateHotstring("*C", "$gt.tri.eq.not$", "⋭")
    CreateHotstring("*C", "$gt.tri.not$", "⋫")
    CreateHotstring("*C", "$gt.triple$", "⋙")
    CreateHotstring("*C", "$gt.triple.nested$", "⫸")
    CreateHotstring("*C", "$lt$", "<")
    CreateHotstring("*C", "$lt.o$", "⧀")
    CreateHotstring("*C", "$lt.circle$", "⧀")
    CreateHotstring("*C", "$lt.dot$", "⋖")
    CreateHotstring("*C", "$lt.approx$", "⪅")
    CreateHotstring("*C", "$lt.double$", "≪")
    CreateHotstring("*C", "$lt.eq$", "≤")
    CreateHotstring("*C", "$lt.eq.slant$", "⩽")
    CreateHotstring("*C", "$lt.eq.gt$", "⋚")
    CreateHotstring("*C", "$lt.eq.not$", "≰")
    CreateHotstring("*C", "$lt.equiv$", "≦")
    CreateHotstring("*C", "$lt.gt$", "≶")
    CreateHotstring("*C", "$lt.gt.not$", "≸")
    CreateHotstring("*C", "$lt.neq$", "⪇")
    CreateHotstring("*C", "$lt.napprox$", "⪉")
    CreateHotstring("*C", "$lt.nequiv$", "≨")
    CreateHotstring("*C", "$lt.not$", "≮")
    CreateHotstring("*C", "$lt.ntilde$", "⋦")
    CreateHotstring("*C", "$lt.small$", "﹤")
    CreateHotstring("*C", "$lt.tilde$", "≲")
    CreateHotstring("*C", "$lt.tilde.not$", "≴")
    CreateHotstring("*C", "$lt.tri$", "⊲")
    CreateHotstring("*C", "$lt.tri.eq$", "⊴")
    CreateHotstring("*C", "$lt.tri.eq.not$", "⋬")
    CreateHotstring("*C", "$lt.tri.not$", "⋪")
    CreateHotstring("*C", "$lt.triple$", "⋘")
    CreateHotstring("*C", "$lt.triple.nested$", "⫷")
    CreateHotstring("*C", "$approx$", "≈")
    CreateHotstring("*C", "$approx.eq$", "≊")
    CreateHotstring("*C", "$approx.not$", "≉")
    CreateHotstring("*C", "$prec$", "≺")
    CreateHotstring("*C", "$prec.approx$", "⪷")
    CreateHotstring("*C", "$prec.curly.eq$", "≼")
    CreateHotstring("*C", "$prec.curly.eq.not$", "⋠")
    CreateHotstring("*C", "$prec.double$", "⪻")
    CreateHotstring("*C", "$prec.eq$", "⪯")
    CreateHotstring("*C", "$prec.equiv$", "⪳")
    CreateHotstring("*C", "$prec.napprox$", "⪹")
    CreateHotstring("*C", "$prec.neq$", "⪱")
    CreateHotstring("*C", "$prec.nequiv$", "⪵")
    CreateHotstring("*C", "$prec.not$", "⊀")
    CreateHotstring("*C", "$prec.ntilde$", "⋨")
    CreateHotstring("*C", "$prec.tilde$", "≾")
    CreateHotstring("*C", "$succ$", "≻")
    CreateHotstring("*C", "$succ.approx$", "⪸")
    CreateHotstring("*C", "$succ.curly.eq$", "≽")
    CreateHotstring("*C", "$succ.curly.eq.not$", "⋡")
    CreateHotstring("*C", "$succ.double$", "⪼")
    CreateHotstring("*C", "$succ.eq$", "⪰")
    CreateHotstring("*C", "$succ.equiv$", "⪴")
    CreateHotstring("*C", "$succ.napprox$", "⪺")
    CreateHotstring("*C", "$succ.neq$", "⪲")
    CreateHotstring("*C", "$succ.nequiv$", "⪶")
    CreateHotstring("*C", "$succ.not$", "⊁")
    CreateHotstring("*C", "$succ.ntilde$", "⋩")
    CreateHotstring("*C", "$succ.tilde$", "≿")
    CreateHotstring("*C", "$equiv$", "≡")
    CreateHotstring("*C", "$equiv.not$", "≢")
    CreateHotstring("*C", "$smt$", "⪪")
    CreateHotstring("*C", "$smt.eq$", "⪬")
    CreateHotstring("*C", "$lat$", "⪫")
    CreateHotstring("*C", "$lat.eq$", "⪭")
    CreateHotstring("*C", "$prop$", "∝")
    CreateHotstring("*C", "$original$", "⊶")
    CreateHotstring("*C", "$image$", "⊷")
    CreateHotstring("*C", "$asymp$", "≍")
    CreateHotstring("*C", "$asymp.not$", "≭")

    ; === Set theory ===
    CreateHotstring("*C", "$emptyset$", "∅")
    CreateHotstring("*C", "$emptyset.arrow.r$", "⦳")
    CreateHotstring("*C", "$emptyset.arrow.l$", "⦴")
    CreateHotstring("*C", "$emptyset.bar$", "⦱")
    CreateHotstring("*C", "$emptyset.circle$", "⦲")
    CreateHotstring("*C", "$emptyset.rev$", "⦰")
    CreateHotstring("*C", "$nothing$", "∅")
    CreateHotstring("*C", "$nothing.arrow.r$", "⦳")
    CreateHotstring("*C", "$nothing.arrow.l$", "⦴")
    CreateHotstring("*C", "$nothing.bar$", "⦱")
    CreateHotstring("*C", "$nothing.circle$", "⦲")
    CreateHotstring("*C", "$nothing.rev$", "⦰")
    CreateHotstring("*C", "$without$", "∖")
    CreateHotstring("*C", "$complement$", "∁")
    CreateHotstring("*C", "$in$", "∈")
    CreateHotstring("*C", "$in.not$", "∉")
    CreateHotstring("*C", "$in.rev$", "∋")
    CreateHotstring("*C", "$in.rev.not$", "∌")
    CreateHotstring("*C", "$in.rev.small$", "∍")
    CreateHotstring("*C", "$in.small$", "∊")
    CreateHotstring("*C", "$subset$", "⊂")
    CreateHotstring("*C", "$subset.dot$", "⪽")
    CreateHotstring("*C", "$subset.double$", "⋐")
    CreateHotstring("*C", "$subset.eq$", "⊆")
    CreateHotstring("*C", "$subset.eq.not$", "⊈")
    CreateHotstring("*C", "$subset.eq.sq$", "⊑")
    CreateHotstring("*C", "$subset.eq.sq.not$", "⋢")
    CreateHotstring("*C", "$subset.neq$", "⊊")
    CreateHotstring("*C", "$subset.not$", "⊄")
    CreateHotstring("*C", "$subset.sq$", "⊏")
    CreateHotstring("*C", "$subset.sq.neq$", "⋤")
    CreateHotstring("*C", "$supset$", "⊃")
    CreateHotstring("*C", "$supset.dot$", "⪾")
    CreateHotstring("*C", "$supset.double$", "⋑")
    CreateHotstring("*C", "$supset.eq$", "⊇")
    CreateHotstring("*C", "$supset.eq.not$", "⊉")
    CreateHotstring("*C", "$supset.eq.sq$", "⊒")
    CreateHotstring("*C", "$supset.eq.sq.not$", "⋣")
    CreateHotstring("*C", "$supset.neq$", "⊋")
    CreateHotstring("*C", "$supset.not$", "⊅")
    CreateHotstring("*C", "$supset.sq$", "⊐")
    CreateHotstring("*C", "$supset.sq.neq$", "⋥")
    CreateHotstring("*C", "$union$", "∪")
    CreateHotstring("*C", "$union.arrow$", "⊌")
    CreateHotstring("*C", "$union.big$", "⋃")
    CreateHotstring("*C", "$union.dot$", "⊍")
    CreateHotstring("*C", "$union.dot.big$", "⨃")
    CreateHotstring("*C", "$union.double$", "⋓")
    CreateHotstring("*C", "$union.minus$", "⩁")
    CreateHotstring("*C", "$union.or$", "⩅")
    CreateHotstring("*C", "$union.plus$", "⊎")
    CreateHotstring("*C", "$union.plus.big$", "⨄")
    CreateHotstring("*C", "$union.sq$", "⊔")
    CreateHotstring("*C", "$union.sq.big$", "⨆")
    CreateHotstring("*C", "$union.sq.double$", "⩏")
    CreateHotstring("*C", "$inter$", "∩")
    CreateHotstring("*C", "$inter.and$", "⩄")
    CreateHotstring("*C", "$inter.big$", "⋂")
    CreateHotstring("*C", "$inter.dot$", "⩀")
    CreateHotstring("*C", "$inter.double$", "⋒")
    CreateHotstring("*C", "$inter.sq$", "⊓")
    CreateHotstring("*C", "$inter.sq.big$", "⨅")
    CreateHotstring("*C", "$inter.sq.double$", "⩎")
    CreateHotstring("*C", "$sect$", "∩")
    CreateHotstring("*C", "$sect.and$", "⩄")
    CreateHotstring("*C", "$sect.big$", "⋂")
    CreateHotstring("*C", "$sect.dot$", "⩀")
    CreateHotstring("*C", "$sect.double$", "⋒")
    CreateHotstring("*C", "$sect.sq$", "⊓")
    CreateHotstring("*C", "$sect.sq.big$", "⨅")
    CreateHotstring("*C", "$sect.sq.double$", "⩎")

    ; === Calculus ===
    CreateHotstring("*C", "$infinity$", "∞")
    CreateHotstring("*C", "$infinity.bar$", "⧞")
    CreateHotstring("*C", "$infinity.incomplete$", "⧜")
    CreateHotstring("*C", "$infinity.tie$", "⧝")
    CreateHotstring("*C", "$oo$", "∞")
    CreateHotstring("*C", "$diff$", "∂")
    CreateHotstring("*C", "$partial$", "∂")
    CreateHotstring("*C", "$gradient$", "∇")
    CreateHotstring("*C", "$nabla$", "∇")
    CreateHotstring("*C", "$sum$", "∑")
    CreateHotstring("*C", "$sum.integral$", "⨋")
    CreateHotstring("*C", "$product$", "∏")
    CreateHotstring("*C", "$product.co$", "∐")
    CreateHotstring("*C", "$integral$", "∫")
    CreateHotstring("*C", "$integral.arrow.hook$", "⨗")
    CreateHotstring("*C", "$integral.ccw$", "⨑")
    CreateHotstring("*C", "$integral.cont$", "∮")
    CreateHotstring("*C", "$integral.cont.ccw$", "∳")
    CreateHotstring("*C", "$integral.cont.cw$", "∲")
    CreateHotstring("*C", "$integral.cw$", "∱")
    CreateHotstring("*C", "$integral.dash$", "⨍")
    CreateHotstring("*C", "$integral.dash.double$", "⨎")
    CreateHotstring("*C", "$integral.double$", "∬")
    CreateHotstring("*C", "$integral.quad$", "⨌")
    CreateHotstring("*C", "$integral.inter$", "⨙")
    CreateHotstring("*C", "$integral.sect$", "⨙")
    CreateHotstring("*C", "$integral.slash$", "⨏")
    CreateHotstring("*C", "$integral.square$", "⨖")
    CreateHotstring("*C", "$integral.surf$", "∯")
    CreateHotstring("*C", "$integral.times$", "⨘")
    CreateHotstring("*C", "$integral.triple$", "∭")
    CreateHotstring("*C", "$integral.union$", "⨚")
    CreateHotstring("*C", "$integral.vol$", "∰")
    CreateHotstring("*C", "$laplace$", "∆")

    ; === Logic ===
    CreateHotstring("*C", "$forall$", "∀")
    CreateHotstring("*C", "$exists$", "∃")
    CreateHotstring("*C", "$exists.not$", "∄")
    CreateHotstring("*C", "$top$", "⊤")
    CreateHotstring("*C", "$bot$", "⊥")
    CreateHotstring("*C", "$not$", "¬")
    CreateHotstring("*C", "$and$", "∧")
    CreateHotstring("*C", "$and.big$", "⋀")
    CreateHotstring("*C", "$and.curly$", "⋏")
    CreateHotstring("*C", "$and.dot$", "⟑")
    CreateHotstring("*C", "$and.double$", "⩓")
    CreateHotstring("*C", "$or$", "∨")
    CreateHotstring("*C", "$or.big$", "⋁")
    CreateHotstring("*C", "$or.curly$", "⋎")
    CreateHotstring("*C", "$or.dot$", "⟇")
    CreateHotstring("*C", "$or.double$", "⩔")
    CreateHotstring("*C", "$xor$", "⊕")
    CreateHotstring("*C", "$xor.big$", "⨁")
    CreateHotstring("*C", "$models$", "⊧")
    CreateHotstring("*C", "$forces$", "⊩")
    CreateHotstring("*C", "$forces.not$", "⊮")
    CreateHotstring("*C", "$therefore$", "∴")
    CreateHotstring("*C", "$because$", "∵")
    CreateHotstring("*C", "$qed$", "∎")

    ; === Function and category theory ===
    CreateHotstring("*C", "$mapsto$", "↦")
    CreateHotstring("*C", "$mapsto.long$", "⟼")
    CreateHotstring("*C", "$compose$", "∘")
    CreateHotstring("*C", "$compose.o$", "⊚")
    CreateHotstring("*C", "$convolve$", "∗")
    CreateHotstring("*C", "$convolve.o$", "⊛")
    CreateHotstring("*C", "$multimap$", "⊸")
    CreateHotstring("*C", "$multimap.double$", "⧟")

    ; === Game theory ===
    CreateHotstring("*C", "$tiny$", "⧾")
    CreateHotstring("*C", "$miny$", "⧿")

    ; === Number theory ===
    CreateHotstring("*C", "$divides$", "∣")
    CreateHotstring("*C", "$divides.not$", "∤")
    CreateHotstring("*C", "$divides.not.rev$", "⫮")
    CreateHotstring("*C", "$divides.struck$", "⟊")

    ; === Algebra ===
    CreateHotstring("*C", "$wreath$", "≀")

    ; === Geometry ===
    CreateHotstring("*C", "$angle$", "∠")
    CreateHotstring("*C", "$angle.l$", "⟨")
    CreateHotstring("*C", "$angle.l.curly$", "⧼")
    CreateHotstring("*C", "$angle.l.dot$", "⦑")
    CreateHotstring("*C", "$angle.l.double$", "⟪")
    CreateHotstring("*C", "$angle.r$", "⟩")
    CreateHotstring("*C", "$angle.r.curly$", "⧽")
    CreateHotstring("*C", "$angle.r.dot$", "⦒")
    CreateHotstring("*C", "$angle.r.double$", "⟫")
    CreateHotstring("*C", "$angle.acute$", "⦟")
    CreateHotstring("*C", "$angle.arc$", "∡")
    CreateHotstring("*C", "$angle.arc.rev$", "⦛")
    CreateHotstring("*C", "$angle.azimuth$", "⍼")
    CreateHotstring("*C", "$angle.oblique$", "⦦")
    CreateHotstring("*C", "$angle.rev$", "⦣")
    CreateHotstring("*C", "$angle.right$", "∟")
    CreateHotstring("*C", "$angle.right.rev$", "⯾")
    CreateHotstring("*C", "$angle.right.arc$", "⊾")
    CreateHotstring("*C", "$angle.right.dot$", "⦝")
    CreateHotstring("*C", "$angle.right.sq$", "⦜")
    CreateHotstring("*C", "$angle.s$", "⦞")
    CreateHotstring("*C", "$angle.spatial$", "⟀")
    CreateHotstring("*C", "$angle.spheric$", "∢")
    CreateHotstring("*C", "$angle.spheric.rev$", "⦠")
    CreateHotstring("*C", "$angle.spheric.t$", "⦡")
    CreateHotstring("*C", "$angle.spheric.top$", "⦡")
    CreateHotstring("*C", "$angzarr$", "⍼")
    CreateHotstring("*C", "$parallel$", "∥")
    CreateHotstring("*C", "$parallel.struck$", "⫲")
    CreateHotstring("*C", "$parallel.o$", "⦷")
    CreateHotstring("*C", "$parallel.circle$", "⦷")
    CreateHotstring("*C", "$parallel.eq$", "⋕")
    CreateHotstring("*C", "$parallel.equiv$", "⩨")
    CreateHotstring("*C", "$parallel.not$", "∦")
    CreateHotstring("*C", "$parallel.slanted.eq$", "⧣")
    CreateHotstring("*C", "$parallel.slanted.eq.tilde$", "⧤")
    CreateHotstring("*C", "$parallel.slanted.equiv$", "⧥")
    CreateHotstring("*C", "$parallel.tilde$", "⫳")
    CreateHotstring("*C", "$perp$", "⟂")
    CreateHotstring("*C", "$perp.o$", "⦹")
    CreateHotstring("*C", "$perp.circle$", "⦹")

    ; === Astronomical ===
    CreateHotstring("*C", "$earth$", "🜨")
    CreateHotstring("*C", "$earth.alt$", "♁")
    CreateHotstring("*C", "$jupiter$", "♃")
    CreateHotstring("*C", "$mars$", "♂")
    CreateHotstring("*C", "$mercury$", "☿")
    CreateHotstring("*C", "$neptune$", "♆")
    CreateHotstring("*C", "$neptune.alt$", "⯉")
    CreateHotstring("*C", "$saturn$", "♄")
    CreateHotstring("*C", "$sun$", "☉")
    CreateHotstring("*C", "$uranus$", "⛢")
    CreateHotstring("*C", "$uranus.alt$", "♅")
    CreateHotstring("*C", "$venus$", "♀")

    ; === Miscellaneous Technical ===
    CreateHotstring("*C", "$diameter$", "⌀")
    CreateHotstring("*C", "$interleave$", "⫴")
    CreateHotstring("*C", "$interleave.big$", "⫼")
    CreateHotstring("*C", "$interleave.struck$", "⫵")
    CreateHotstring("*C", "$join$", "⨝")
    CreateHotstring("*C", "$join.r$", "⟖")
    CreateHotstring("*C", "$join.l$", "⟕")
    CreateHotstring("*C", "$join.l.r$", "⟗")
    ; Hourglass
    CreateHotstring("*C", "$hourglass.stroked$", "⧖")
    CreateHotstring("*C", "$hourglass.filled$", "⧗")
    CreateHotstring("*C", "$degree$", "°")
    CreateHotstring("*C", "$smash$", "⨳")
    ; Power
    CreateHotstring("*C", "$power.standby$", "⏻")
    CreateHotstring("*C", "$power.on$", "⏽")
    CreateHotstring("*C", "$power.off$", "⭘")
    CreateHotstring("*C", "$power.on.off$", "⏼")
    CreateHotstring("*C", "$power.sleep$", "⏾")
    CreateHotstring("*C", "$smile$", "⌣")
    CreateHotstring("*C", "$frown$", "⌢")

    ; === Currency ===
    CreateHotstring("*C", "$afghani$", "؋")
    CreateHotstring("*C", "$baht$", "฿")
    CreateHotstring("*C", "$bitcoin$", "₿")
    CreateHotstring("*C", "$cedi$", "₵")
    CreateHotstring("*C", "$cent$", "¢")
    CreateHotstring("*C", "$currency$", "¤")
    CreateHotstring("*C", "$dollar$", "$")
    CreateHotstring("*C", "$dong$", "₫")
    CreateHotstring("*C", "$dorome$", "߾")
    CreateHotstring("*C", "$dram$", "֏")
    CreateHotstring("*C", "$euro$", "€")
    CreateHotstring("*C", "$franc$", "₣")
    CreateHotstring("*C", "$guarani$", "₲")
    CreateHotstring("*C", "$hryvnia$", "₴")
    CreateHotstring("*C", "$kip$", "₭")
    CreateHotstring("*C", "$lari$", "₾")
    CreateHotstring("*C", "$lira$", "₺")
    CreateHotstring("*C", "$manat$", "₼")
    CreateHotstring("*C", "$naira$", "₦")
    CreateHotstring("*C", "$pataca$", "$")
    CreateHotstring("*C", "$peso$", "$")
    CreateHotstring("*C", "$peso.philippine$", "₱")
    CreateHotstring("*C", "$pound$", "£")
    CreateHotstring("*C", "$riel$", "៛")
    CreateHotstring("*C", "$ruble$", "₽")
    ; Rupee
    CreateHotstring("*C", "$rupee.indian$", "₹")
    CreateHotstring("*C", "$rupee.generic$", "₨")
    CreateHotstring("*C", "$rupee.tamil$", "௹")
    CreateHotstring("*C", "$rupee.wancho$", "𞋿")
    CreateHotstring("*C", "$shekel$", "₪")
    CreateHotstring("*C", "$som$", "⃀")
    CreateHotstring("*C", "$taka$", "৳")
    CreateHotstring("*C", "$taman$", "߿")
    CreateHotstring("*C", "$tenge$", "₸")
    CreateHotstring("*C", "$togrog$", "₮")
    CreateHotstring("*C", "$won$", "₩")
    CreateHotstring("*C", "$yen$", "¥")
    CreateHotstring("*C", "$yuan$", "¥")

    ; === Miscellaneous ===
    CreateHotstring("*C", "$ballot$", "☐")
    CreateHotstring("*C", "$ballot.cross$", "☒")
    CreateHotstring("*C", "$ballot.check$", "☑")
    CreateHotstring("*C", "$ballot.check.heavy$", "🗹")
    CreateHotstring("*C", "$checkmark$", "✓")
    CreateHotstring("*C", "$checkmark.light$", "🗸")
    CreateHotstring("*C", "$checkmark.heavy$", "✔")
    CreateHotstring("*C", "$crossmark$", "✗")
    CreateHotstring("*C", "$crossmark.heavy$", "✘")
    CreateHotstring("*C", "$floral$", "❦")
    CreateHotstring("*C", "$floral.l$", "☙")
    CreateHotstring("*C", "$floral.r$", "❧")
    CreateHotstring("*C", "$refmark$", "※")
    CreateHotstring("*C", "$cc$", "🅭")
    CreateHotstring("*C", "$cc.by$", "🅯")
    CreateHotstring("*C", "$cc.nc$", "🄏")
    CreateHotstring("*C", "$cc.nd$", "⊜")
    CreateHotstring("*C", "$cc.public$", "🅮")
    CreateHotstring("*C", "$cc.sa$", "🄎")
    CreateHotstring("*C", "$cc.zero$", "🄍")
    CreateHotstring("*C", "$copyright$", "©")
    CreateHotstring("*C", "$copyright.sound$", "℗")
    CreateHotstring("*C", "$copyleft$", "🄯")
    CreateHotstring("*C", "$trademark$", "™")
    CreateHotstring("*C", "$trademark.registered$", "®")
    CreateHotstring("*C", "$trademark.service$", "℠")
    CreateHotstring("*C", "$maltese$", "✠")
    ; Suit
    CreateHotstring("*C", "$suit.club.filled$", "♣")
    CreateHotstring("*C", "$suit.club.stroked$", "♧")
    CreateHotstring("*C", "$suit.diamond.filled$", "♦")
    CreateHotstring("*C", "$suit.diamond.stroked$", "♢")
    CreateHotstring("*C", "$suit.heart.filled$", "♥")
    CreateHotstring("*C", "$suit.heart.stroked$", "♡")
    CreateHotstring("*C", "$suit.spade.filled$", "♠")
    CreateHotstring("*C", "$suit.spade.stroked$", "♤")

    ; === Music ===
    ; Note
    CreateHotstring("*C", "$note.up$", "🎜")
    CreateHotstring("*C", "$note.down$", "🎝")
    CreateHotstring("*C", "$note.whole$", "𝅝")
    CreateHotstring("*C", "$note.half$", "𝅗𝅥")
    CreateHotstring("*C", "$note.quarter$", "𝅘𝅥")
    CreateHotstring("*C", "$note.quarter.alt$", "♩")
    CreateHotstring("*C", "$note.eighth$", "𝅘𝅥𝅮")
    CreateHotstring("*C", "$note.eighth.alt$", "♪")
    CreateHotstring("*C", "$note.eighth.beamed$", "♫")
    CreateHotstring("*C", "$note.sixteenth$", "𝅘𝅥𝅯")
    CreateHotstring("*C", "$note.sixteenth.beamed$", "♬")
    CreateHotstring("*C", "$note.grace$", "𝆕")
    CreateHotstring("*C", "$note.grace.slash$", "𝆔")
    ; Rest
    CreateHotstring("*C", "$rest.whole$", "𝄻")
    CreateHotstring("*C", "$rest.multiple$", "𝄺")
    CreateHotstring("*C", "$rest.multiple.measure$", "𝄩")
    CreateHotstring("*C", "$rest.half$", "𝄼")
    CreateHotstring("*C", "$rest.quarter$", "𝄽")
    CreateHotstring("*C", "$rest.eighth$", "𝄾")
    CreateHotstring("*C", "$rest.sixteenth$", "𝄿")
    CreateHotstring("*C", "$natural$", "♮")
    CreateHotstring("*C", "$natural.t$", "𝄮")
    CreateHotstring("*C", "$natural.b$", "𝄯")
    CreateHotstring("*C", "$flat$", "♭")
    CreateHotstring("*C", "$flat.t$", "𝄬")
    CreateHotstring("*C", "$flat.b$", "𝄭")
    CreateHotstring("*C", "$flat.double$", "𝄫")
    CreateHotstring("*C", "$flat.quarter$", "𝄳")
    CreateHotstring("*C", "$sharp$", "♯")
    CreateHotstring("*C", "$sharp.t$", "𝄰")
    CreateHotstring("*C", "$sharp.b$", "𝄱")
    CreateHotstring("*C", "$sharp.double$", "𝄪")
    CreateHotstring("*C", "$sharp.quarter$", "𝄲")

    ; === Shapes ===
    CreateHotstring("*C", "$bullet$", "•")
    CreateHotstring("*C", "$bullet.op$", "∙")
    CreateHotstring("*C", "$bullet.o$", "⦿")
    CreateHotstring("*C", "$bullet.stroked$", "◦")
    CreateHotstring("*C", "$bullet.stroked.o$", "⦾")
    CreateHotstring("*C", "$bullet.hole$", "◘")
    CreateHotstring("*C", "$bullet.hyph$", "⁃")
    CreateHotstring("*C", "$bullet.tri$", "‣")
    CreateHotstring("*C", "$bullet.l$", "⁌")
    CreateHotstring("*C", "$bullet.r$", "⁍")
    ; Circle
    CreateHotstring("*C", "$circle.stroked$", "○")
    CreateHotstring("*C", "$circle.stroked.tiny$", "∘")
    CreateHotstring("*C", "$circle.stroked.small$", "⚬")
    CreateHotstring("*C", "$circle.stroked.big$", "◯")
    CreateHotstring("*C", "$circle.filled$", "●")
    CreateHotstring("*C", "$circle.filled.tiny$", "⦁")
    CreateHotstring("*C", "$circle.filled.small$", "∙")
    CreateHotstring("*C", "$circle.filled.big$", "⬤")
    CreateHotstring("*C", "$circle.dotted$", "◌")
    CreateHotstring("*C", "$circle.nested$", "⊚")
    ; Ellipse
    CreateHotstring("*C", "$ellipse.stroked.h$", "⬭")
    CreateHotstring("*C", "$ellipse.stroked.v$", "⬯")
    CreateHotstring("*C", "$ellipse.filled.h$", "⬬")
    CreateHotstring("*C", "$ellipse.filled.v$", "⬮")
    ; Triangle
    CreateHotstring("*C", "$triangle.stroked.t$", "△")
    CreateHotstring("*C", "$triangle.stroked.b$", "▽")
    CreateHotstring("*C", "$triangle.stroked.r$", "▷")
    CreateHotstring("*C", "$triangle.stroked.l$", "◁")
    CreateHotstring("*C", "$triangle.stroked.bl$", "◺")
    CreateHotstring("*C", "$triangle.stroked.br$", "◿")
    CreateHotstring("*C", "$triangle.stroked.tl$", "◸")
    CreateHotstring("*C", "$triangle.stroked.tr$", "◹")
    CreateHotstring("*C", "$triangle.stroked.small.t$", "▵")
    CreateHotstring("*C", "$triangle.stroked.small.b$", "▿")
    CreateHotstring("*C", "$triangle.stroked.small.r$", "▹")
    CreateHotstring("*C", "$triangle.stroked.small.l$", "◃")
    CreateHotstring("*C", "$triangle.stroked.rounded$", "🛆")
    CreateHotstring("*C", "$triangle.stroked.nested$", "⟁")
    CreateHotstring("*C", "$triangle.stroked.dot$", "◬")
    CreateHotstring("*C", "$triangle.filled.t$", "▲")
    CreateHotstring("*C", "$triangle.filled.b$", "▼")
    CreateHotstring("*C", "$triangle.filled.r$", "▶")
    CreateHotstring("*C", "$triangle.filled.l$", "◀")
    CreateHotstring("*C", "$triangle.filled.bl$", "◣")
    CreateHotstring("*C", "$triangle.filled.br$", "◢")
    CreateHotstring("*C", "$triangle.filled.tl$", "◤")
    CreateHotstring("*C", "$triangle.filled.tr$", "◥")
    CreateHotstring("*C", "$triangle.filled.small.t$", "▴")
    CreateHotstring("*C", "$triangle.filled.small.b$", "▾")
    CreateHotstring("*C", "$triangle.filled.small.r$", "▸")
    CreateHotstring("*C", "$triangle.filled.small.l$", "◂")
    ; Square
    CreateHotstring("*C", "$square.stroked$", "□")
    CreateHotstring("*C", "$square.stroked.tiny$", "▫")
    CreateHotstring("*C", "$square.stroked.small$", "◽")
    CreateHotstring("*C", "$square.stroked.medium$", "◻")
    CreateHotstring("*C", "$square.stroked.big$", "⬜")
    CreateHotstring("*C", "$square.stroked.dotted$", "⬚")
    CreateHotstring("*C", "$square.stroked.rounded$", "▢")
    CreateHotstring("*C", "$square.filled$", "■")
    CreateHotstring("*C", "$square.filled.tiny$", "▪")
    CreateHotstring("*C", "$square.filled.small$", "◾")
    CreateHotstring("*C", "$square.filled.medium$", "◼")
    CreateHotstring("*C", "$square.filled.big$", "⬛")
    ; Rect
    CreateHotstring("*C", "$rect.stroked.h$", "▭")
    CreateHotstring("*C", "$rect.stroked.v$", "▯")
    CreateHotstring("*C", "$rect.filled.h$", "▬")
    CreateHotstring("*C", "$rect.filled.v$", "▮")
    ; Penta
    CreateHotstring("*C", "$penta.stroked$", "⬠")
    CreateHotstring("*C", "$penta.filled$", "⬟")
    ; Hexa
    CreateHotstring("*C", "$hexa.stroked$", "⬡")
    CreateHotstring("*C", "$hexa.filled$", "⬢")
    ; Diamond
    CreateHotstring("*C", "$diamond.stroked$", "◇")
    CreateHotstring("*C", "$diamond.stroked.small$", "⋄")
    CreateHotstring("*C", "$diamond.stroked.medium$", "⬦")
    CreateHotstring("*C", "$diamond.stroked.dot$", "⟐")
    CreateHotstring("*C", "$diamond.filled$", "◆")
    CreateHotstring("*C", "$diamond.filled.medium$", "⬥")
    CreateHotstring("*C", "$diamond.filled.small$", "⬩")
    ; Lozenge
    CreateHotstring("*C", "$lozenge.stroked$", "◊")
    CreateHotstring("*C", "$lozenge.stroked.small$", "⬫")
    CreateHotstring("*C", "$lozenge.stroked.medium$", "⬨")
    CreateHotstring("*C", "$lozenge.filled$", "⧫")
    CreateHotstring("*C", "$lozenge.filled.small$", "⬪")
    CreateHotstring("*C", "$lozenge.filled.medium$", "⬧")
    ; Parallelogram
    CreateHotstring("*C", "$parallelogram.stroked$", "▱")
    CreateHotstring("*C", "$parallelogram.filled$", "▰")
    ; Star
    CreateHotstring("*C", "$star.op$", "⋆")
    CreateHotstring("*C", "$star.stroked$", "☆")
    CreateHotstring("*C", "$star.filled$", "★")

    ; === Arrows, harpoons, and tacks ===
    ; Arrow
    CreateHotstring("*C", "$arrow.r$", "→")
    CreateHotstring("*C", "$arrow.r.long.bar$", "⟼")
    CreateHotstring("*C", "$arrow.r.bar$", "↦")
    CreateHotstring("*C", "$arrow.r.curve$", "⤷")
    CreateHotstring("*C", "$arrow.r.turn$", "⮎")
    CreateHotstring("*C", "$arrow.r.dashed$", "⇢")
    CreateHotstring("*C", "$arrow.r.dotted$", "⤑")
    CreateHotstring("*C", "$arrow.r.double$", "⇒")
    CreateHotstring("*C", "$arrow.r.double.bar$", "⤇")
    CreateHotstring("*C", "$arrow.r.double.long$", "⟹")
    CreateHotstring("*C", "$arrow.r.double.long.bar$", "⟾")
    CreateHotstring("*C", "$arrow.r.double.not$", "⇏")
    CreateHotstring("*C", "$arrow.r.double.struck$", "⤃")
    CreateHotstring("*C", "$arrow.r.filled$", "➡")
    CreateHotstring("*C", "$arrow.r.hook$", "↪")
    CreateHotstring("*C", "$arrow.r.long$", "⟶")
    CreateHotstring("*C", "$arrow.r.long.squiggly$", "⟿")
    CreateHotstring("*C", "$arrow.r.loop$", "↬")
    CreateHotstring("*C", "$arrow.r.not$", "↛")
    CreateHotstring("*C", "$arrow.r.quad$", "⭆")
    CreateHotstring("*C", "$arrow.r.squiggly$", "⇝")
    CreateHotstring("*C", "$arrow.r.stop$", "⇥")
    CreateHotstring("*C", "$arrow.r.stroked$", "⇨")
    CreateHotstring("*C", "$arrow.r.struck$", "⇸")
    CreateHotstring("*C", "$arrow.r.dstruck$", "⇻")
    CreateHotstring("*C", "$arrow.r.tail$", "↣")
    CreateHotstring("*C", "$arrow.r.tail.struck$", "⤔")
    CreateHotstring("*C", "$arrow.r.tail.dstruck$", "⤕")
    CreateHotstring("*C", "$arrow.r.tilde$", "⥲")
    CreateHotstring("*C", "$arrow.r.triple$", "⇛")
    CreateHotstring("*C", "$arrow.r.twohead$", "↠")
    CreateHotstring("*C", "$arrow.r.twohead.bar$", "⤅")
    CreateHotstring("*C", "$arrow.r.twohead.struck$", "⤀")
    CreateHotstring("*C", "$arrow.r.twohead.dstruck$", "⤁")
    CreateHotstring("*C", "$arrow.r.twohead.tail$", "⤖")
    CreateHotstring("*C", "$arrow.r.twohead.tail.struck$", "⤗")
    CreateHotstring("*C", "$arrow.r.twohead.tail.dstruck$", "⤘")
    CreateHotstring("*C", "$arrow.r.open$", "⇾")
    CreateHotstring("*C", "$arrow.r.wave$", "↝")
    CreateHotstring("*C", "$arrow.l$", "←")
    CreateHotstring("*C", "$arrow.l.bar$", "↤")
    CreateHotstring("*C", "$arrow.l.curve$", "⤶")
    CreateHotstring("*C", "$arrow.l.turn$", "⮌")
    CreateHotstring("*C", "$arrow.l.dashed$", "⇠")
    CreateHotstring("*C", "$arrow.l.dotted$", "⬸")
    CreateHotstring("*C", "$arrow.l.double$", "⇐")
    CreateHotstring("*C", "$arrow.l.double.bar$", "⤆")
    CreateHotstring("*C", "$arrow.l.double.long$", "⟸")
    CreateHotstring("*C", "$arrow.l.double.long.bar$", "⟽")
    CreateHotstring("*C", "$arrow.l.double.not$", "⇍")
    CreateHotstring("*C", "$arrow.l.double.struck$", "⤂")
    CreateHotstring("*C", "$arrow.l.filled$", "⬅")
    CreateHotstring("*C", "$arrow.l.hook$", "↩")
    CreateHotstring("*C", "$arrow.l.long$", "⟵")
    CreateHotstring("*C", "$arrow.l.long.bar$", "⟻")
    CreateHotstring("*C", "$arrow.l.long.squiggly$", "⬳")
    CreateHotstring("*C", "$arrow.l.loop$", "↫")
    CreateHotstring("*C", "$arrow.l.not$", "↚")
    CreateHotstring("*C", "$arrow.l.quad$", "⭅")
    CreateHotstring("*C", "$arrow.l.squiggly$", "⇜")
    CreateHotstring("*C", "$arrow.l.stop$", "⇤")
    CreateHotstring("*C", "$arrow.l.stroked$", "⇦")
    CreateHotstring("*C", "$arrow.l.struck$", "⇷")
    CreateHotstring("*C", "$arrow.l.dstruck$", "⇺")
    CreateHotstring("*C", "$arrow.l.tail$", "↢")
    CreateHotstring("*C", "$arrow.l.tail.struck$", "⬹")
    CreateHotstring("*C", "$arrow.l.tail.dstruck$", "⬺")
    CreateHotstring("*C", "$arrow.l.tilde$", "⭉")
    CreateHotstring("*C", "$arrow.l.triple$", "⇚")
    CreateHotstring("*C", "$arrow.l.twohead$", "↞")
    CreateHotstring("*C", "$arrow.l.twohead.bar$", "⬶")
    CreateHotstring("*C", "$arrow.l.twohead.struck$", "⬴")
    CreateHotstring("*C", "$arrow.l.twohead.dstruck$", "⬵")
    CreateHotstring("*C", "$arrow.l.twohead.tail$", "⬻")
    CreateHotstring("*C", "$arrow.l.twohead.tail.struck$", "⬼")
    CreateHotstring("*C", "$arrow.l.twohead.tail.dstruck$", "⬽")
    CreateHotstring("*C", "$arrow.l.open$", "⇽")
    CreateHotstring("*C", "$arrow.l.wave$", "↜")
    CreateHotstring("*C", "$arrow.t$", "↑")
    CreateHotstring("*C", "$arrow.t.bar$", "↥")
    CreateHotstring("*C", "$arrow.t.curve$", "⤴")
    CreateHotstring("*C", "$arrow.t.turn$", "⮍")
    CreateHotstring("*C", "$arrow.t.dashed$", "⇡")
    CreateHotstring("*C", "$arrow.t.double$", "⇑")
    CreateHotstring("*C", "$arrow.t.filled$", "⬆")
    CreateHotstring("*C", "$arrow.t.quad$", "⟰")
    CreateHotstring("*C", "$arrow.t.stop$", "⤒")
    CreateHotstring("*C", "$arrow.t.stroked$", "⇧")
    CreateHotstring("*C", "$arrow.t.struck$", "⤉")
    CreateHotstring("*C", "$arrow.t.dstruck$", "⇞")
    CreateHotstring("*C", "$arrow.t.triple$", "⤊")
    CreateHotstring("*C", "$arrow.t.twohead$", "↟")
    CreateHotstring("*C", "$arrow.b$", "↓")
    CreateHotstring("*C", "$arrow.b.bar$", "↧")
    CreateHotstring("*C", "$arrow.b.curve$", "⤵")
    CreateHotstring("*C", "$arrow.b.turn$", "⮏")
    CreateHotstring("*C", "$arrow.b.dashed$", "⇣")
    CreateHotstring("*C", "$arrow.b.double$", "⇓")
    CreateHotstring("*C", "$arrow.b.filled$", "⬇")
    CreateHotstring("*C", "$arrow.b.quad$", "⟱")
    CreateHotstring("*C", "$arrow.b.stop$", "⤓")
    CreateHotstring("*C", "$arrow.b.stroked$", "⇩")
    CreateHotstring("*C", "$arrow.b.struck$", "⤈")
    CreateHotstring("*C", "$arrow.b.dstruck$", "⇟")
    CreateHotstring("*C", "$arrow.b.triple$", "⤋")
    CreateHotstring("*C", "$arrow.b.twohead$", "↡")
    CreateHotstring("*C", "$arrow.l.r$", "↔")
    CreateHotstring("*C", "$arrow.l.r.double$", "⇔")
    CreateHotstring("*C", "$arrow.l.r.double.long$", "⟺")
    CreateHotstring("*C", "$arrow.l.r.double.not$", "⇎")
    CreateHotstring("*C", "$arrow.l.r.double.struck$", "⤄")
    CreateHotstring("*C", "$arrow.l.r.filled$", "⬌")
    CreateHotstring("*C", "$arrow.l.r.long$", "⟷")
    CreateHotstring("*C", "$arrow.l.r.not$", "↮")
    CreateHotstring("*C", "$arrow.l.r.stroked$", "⬄")
    CreateHotstring("*C", "$arrow.l.r.struck$", "⇹")
    CreateHotstring("*C", "$arrow.l.r.dstruck$", "⇼")
    CreateHotstring("*C", "$arrow.l.r.open$", "⇿")
    CreateHotstring("*C", "$arrow.l.r.wave$", "↭")
    CreateHotstring("*C", "$arrow.t.b$", "↕")
    CreateHotstring("*C", "$arrow.t.b.double$", "⇕")
    CreateHotstring("*C", "$arrow.t.b.filled$", "⬍")
    CreateHotstring("*C", "$arrow.t.b.stroked$", "⇳")
    CreateHotstring("*C", "$arrow.tr$", "↗")
    CreateHotstring("*C", "$arrow.tr.double$", "⇗")
    CreateHotstring("*C", "$arrow.tr.filled$", "⬈")
    CreateHotstring("*C", "$arrow.tr.hook$", "⤤")
    CreateHotstring("*C", "$arrow.tr.stroked$", "⬀")
    CreateHotstring("*C", "$arrow.br$", "↘")
    CreateHotstring("*C", "$arrow.br.double$", "⇘")
    CreateHotstring("*C", "$arrow.br.filled$", "⬊")
    CreateHotstring("*C", "$arrow.br.hook$", "⤥")
    CreateHotstring("*C", "$arrow.br.stroked$", "⬂")
    CreateHotstring("*C", "$arrow.tl$", "↖")
    CreateHotstring("*C", "$arrow.tl.double$", "⇖")
    CreateHotstring("*C", "$arrow.tl.filled$", "⬉")
    CreateHotstring("*C", "$arrow.tl.hook$", "⤣")
    CreateHotstring("*C", "$arrow.tl.stroked$", "⬁")
    CreateHotstring("*C", "$arrow.bl$", "↙")
    CreateHotstring("*C", "$arrow.bl.double$", "⇙")
    CreateHotstring("*C", "$arrow.bl.filled$", "⬋")
    CreateHotstring("*C", "$arrow.bl.hook$", "⤦")
    CreateHotstring("*C", "$arrow.bl.stroked$", "⬃")
    CreateHotstring("*C", "$arrow.tl.br$", "⤡")
    CreateHotstring("*C", "$arrow.tr.bl$", "⥢")
    CreateHotstring("*C", "$arrow.ccw$", "↺")
    CreateHotstring("*C", "$arrow.ccw.half$", "↶")
    CreateHotstring("*C", "$arrow.cw$", "↻")
    CreateHotstring("*C", "$arrow.cw.half$", "↷")
    CreateHotstring("*C", "$arrow.zigzag$", "↯")
    ; Arrows
    CreateHotstring("*C", "$arrows.rr$", "⇉")
    CreateHotstring("*C", "$arrows.ll$", "⇇")
    CreateHotstring("*C", "$arrows.tt$", "⇈")
    CreateHotstring("*C", "$arrows.bb$", "⇊")
    CreateHotstring("*C", "$arrows.lr$", "⇆")
    CreateHotstring("*C", "$arrows.lr.stop$", "↹")
    CreateHotstring("*C", "$arrows.rl$", "⇄")
    CreateHotstring("*C", "$arrows.tb$", "⇅")
    CreateHotstring("*C", "$arrows.bt$", "⇵")
    CreateHotstring("*C", "$arrows.rrr$", "⇶")
    CreateHotstring("*C", "$arrows.lll$", "⬱")
    ; Arrowhead
    CreateHotstring("*C", "$arrowhead.t$", "⌃")
    CreateHotstring("*C", "$arrowhead.b$", "⌄")
    ; Harpoon
    CreateHotstring("*C", "$harpoon.rt$", "⇀")
    CreateHotstring("*C", "$harpoon.rt.bar$", "⥛")
    CreateHotstring("*C", "$harpoon.rt.stop$", "⥓")
    CreateHotstring("*C", "$harpoon.rb$", "⇁")
    CreateHotstring("*C", "$harpoon.rb.bar$", "⥟")
    CreateHotstring("*C", "$harpoon.rb.stop$", "⥗")
    CreateHotstring("*C", "$harpoon.lt$", "↼")
    CreateHotstring("*C", "$harpoon.lt.bar$", "⥚")
    CreateHotstring("*C", "$harpoon.lt.stop$", "⥒")
    CreateHotstring("*C", "$harpoon.lb$", "↽")
    CreateHotstring("*C", "$harpoon.lb.bar$", "⥞")
    CreateHotstring("*C", "$harpoon.lb.stop$", "⥖")
    CreateHotstring("*C", "$harpoon.tl$", "↿")
    CreateHotstring("*C", "$harpoon.tl.bar$", "⥠")
    CreateHotstring("*C", "$harpoon.tl.stop$", "⥘")
    CreateHotstring("*C", "$harpoon.tr$", "↾")
    CreateHotstring("*C", "$harpoon.tr.bar$", "⥜")
    CreateHotstring("*C", "$harpoon.tr.stop$", "⥔")
    CreateHotstring("*C", "$harpoon.bl$", "⇃")
    CreateHotstring("*C", "$harpoon.bl.bar$", "⥡")
    CreateHotstring("*C", "$harpoon.bl.stop$", "⥙")
    CreateHotstring("*C", "$harpoon.br$", "⇂")
    CreateHotstring("*C", "$harpoon.br.bar$", "⥝")
    CreateHotstring("*C", "$harpoon.br.stop$", "⥕")
    CreateHotstring("*C", "$harpoon.lt.rt$", "⥎")
    CreateHotstring("*C", "$harpoon.lb.rb$", "⥐")
    CreateHotstring("*C", "$harpoon.lb.rt$", "⥋")
    CreateHotstring("*C", "$harpoon.lt.rb$", "⥊")
    CreateHotstring("*C", "$harpoon.tl.bl$", "⥑")
    CreateHotstring("*C", "$harpoon.tr.br$", "⥏")
    CreateHotstring("*C", "$harpoon.tl.br$", "⥍")
    CreateHotstring("*C", "$harpoon.tr.bl$", "⥌")
    ; Harpoons
    CreateHotstring("*C", "$harpoons.rtrb$", "⥤")
    CreateHotstring("*C", "$harpoons.blbr$", "⥥")
    CreateHotstring("*C", "$harpoons.bltr$", "⥯")
    CreateHotstring("*C", "$harpoons.lbrb$", "⥧")
    CreateHotstring("*C", "$harpoons.ltlb$", "⥢")
    CreateHotstring("*C", "$harpoons.ltrb$", "⇋")
    CreateHotstring("*C", "$harpoons.ltrt$", "⥦")
    CreateHotstring("*C", "$harpoons.rblb$", "⥩")
    CreateHotstring("*C", "$harpoons.rtlb$", "⇌")
    CreateHotstring("*C", "$harpoons.rtlt$", "⥨")
    CreateHotstring("*C", "$harpoons.tlbr$", "⥮")
    CreateHotstring("*C", "$harpoons.tltr$", "⥣")
    ; Tack
    CreateHotstring("*C", "$tack.r$", "⊢")
    CreateHotstring("*C", "$tack.r.not$", "⊬")
    CreateHotstring("*C", "$tack.r.long$", "⟝")
    CreateHotstring("*C", "$tack.r.short$", "⊦")
    CreateHotstring("*C", "$tack.r.double$", "⊨")
    CreateHotstring("*C", "$tack.r.double.not$", "⊭")
    CreateHotstring("*C", "$tack.l$", "⊣")
    CreateHotstring("*C", "$tack.l.long$", "⟞")
    CreateHotstring("*C", "$tack.l.short$", "⫞")
    CreateHotstring("*C", "$tack.l.double$", "⫤")
    CreateHotstring("*C", "$tack.t$", "⊥")
    CreateHotstring("*C", "$tack.t.big$", "⟘")
    CreateHotstring("*C", "$tack.t.double$", "⫫")
    CreateHotstring("*C", "$tack.t.short$", "⫠")
    CreateHotstring("*C", "$tack.b$", "⊤")
    CreateHotstring("*C", "$tack.b.big$", "⟙")
    CreateHotstring("*C", "$tack.b.double$", "⫪")
    CreateHotstring("*C", "$tack.b.short$", "⫟")
    CreateHotstring("*C", "$tack.l.r$", "⟛")

    ; === Lowercase Greek ===
    CreateHotstring("*C", "$alpha$", "α")
    CreateHotstring("*C", "$beta$", "β")
    CreateHotstring("*C", "$beta.alt$", "ϐ")
    CreateHotstring("*C", "$chi$", "χ")
    CreateHotstring("*C", "$delta$", "δ")
    CreateHotstring("*C", "$digamma$", "ϝ")
    CreateHotstring("*C", "$epsilon$", "ε")
    CreateHotstring("*C", "$epsilon.alt$", "ϵ")
    CreateHotstring("*C", "$epsilon.alt.rev$", "϶")
    CreateHotstring("*C", "$eta$", "η")
    CreateHotstring("*C", "$gamma$", "γ")
    CreateHotstring("*C", "$iota$", "ι")
    CreateHotstring("*C", "$iota.inv$", "℩")
    CreateHotstring("*C", "$kai$", "ϗ")
    CreateHotstring("*C", "$kappa$", "κ")
    CreateHotstring("*C", "$kappa.alt$", "ϰ")
    CreateHotstring("*C", "$lambda$", "λ")
    CreateHotstring("*C", "$mu$", "μ")
    CreateHotstring("*C", "$nu$", "ν")
    CreateHotstring("*C", "$omega$", "ω")
    CreateHotstring("*C", "$omicron$", "ο")
    CreateHotstring("*C", "$phi$", "φ")
    CreateHotstring("*C", "$phi.alt$", "ϕ")
    CreateHotstring("*C", "$pi$", "π")
    CreateHotstring("*C", "$pi.alt$", "ϖ")
    CreateHotstring("*C", "$psi$", "ψ")
    CreateHotstring("*C", "$rho$", "ρ")
    CreateHotstring("*C", "$rho.alt$", "ϱ")
    CreateHotstring("*C", "$sigma$", "σ")
    CreateHotstring("*C", "$sigma.alt$", "ς")
    CreateHotstring("*C", "$tau$", "τ")
    CreateHotstring("*C", "$theta$", "θ")
    CreateHotstring("*C", "$theta.alt$", "ϑ")
    CreateHotstring("*C", "$upsilon$", "υ")
    CreateHotstring("*C", "$xi$", "ξ")
    CreateHotstring("*C", "$zeta$", "ζ")

    ; === Uppercase Greek ===
    CreateHotstring("*C", "$Alpha$", "Α")
    CreateHotstring("*C", "$Beta$", "Β")
    CreateHotstring("*C", "$Chi$", "Χ")
    CreateHotstring("*C", "$Delta$", "Δ")
    CreateHotstring("*C", "$Digamma$", "Ϝ")
    CreateHotstring("*C", "$Epsilon$", "Ε")
    CreateHotstring("*C", "$Eta$", "Η")
    CreateHotstring("*C", "$Gamma$", "Γ")
    CreateHotstring("*C", "$Iota$", "Ι")
    CreateHotstring("*C", "$Kai$", "Ϗ")
    CreateHotstring("*C", "$Kappa$", "Κ")
    CreateHotstring("*C", "$Lambda$", "Λ")
    CreateHotstring("*C", "$Mu$", "Μ")
    CreateHotstring("*C", "$Nu$", "Ν")
    CreateHotstring("*C", "$Omega$", "Ω")
    CreateHotstring("*C", "$Omega.inv$", "℧")
    CreateHotstring("*C", "$Omicron$", "Ο")
    CreateHotstring("*C", "$Phi$", "Φ")
    CreateHotstring("*C", "$Pi$", "Π")
    CreateHotstring("*C", "$Psi$", "Ψ")
    CreateHotstring("*C", "$Rho$", "Ρ")
    CreateHotstring("*C", "$Sigma$", "Σ")
    CreateHotstring("*C", "$Tau$", "Τ")
    CreateHotstring("*C", "$Theta$", "Θ")
    CreateHotstring("*C", "$Theta.alt$", "ϴ")
    CreateHotstring("*C", "$Upsilon$", "Υ")
    CreateHotstring("*C", "$Xi$", "Ξ")
    CreateHotstring("*C", "$Zeta$", "Ζ")

    ; === Lowercase Cyrillic ===
    CreateHotstring("*C", "$sha$", "ш")

    ; === Uppercase Cyrillic ===
    CreateHotstring("*C", "$Sha$", "Ш")

    ; === Hebrew ===
    CreateHotstring("*C", "$aleph$", "א")
    CreateHotstring("*C", "$alef$", "א")
    CreateHotstring("*C", "$beth$", "ב")
    CreateHotstring("*C", "$bet$", "ב")
    CreateHotstring("*C", "$gimel$", "ג")
    CreateHotstring("*C", "$gimmel$", "ג")
    CreateHotstring("*C", "$daleth$", "ד")
    CreateHotstring("*C", "$dalet$", "ד")
    CreateHotstring("*C", "$shin$", "ש")

    ; === Double-struck ===
    CreateHotstring("*C", "$AA$", "𝔸")
    CreateHotstring("*C", "$BB$", "𝔹")
    CreateHotstring("*C", "$CC$", "ℂ")
    CreateHotstring("*C", "$DD$", "𝔻")
    CreateHotstring("*C", "$EE$", "𝔼")
    CreateHotstring("*C", "$FF$", "𝔽")
    CreateHotstring("*C", "$GG$", "𝔾")
    CreateHotstring("*C", "$HH$", "ℍ")
    CreateHotstring("*C", "$II$", "𝕀")
    CreateHotstring("*C", "$JJ$", "𝕁")
    CreateHotstring("*C", "$KK$", "𝕂")
    CreateHotstring("*C", "$LL$", "𝕃")
    CreateHotstring("*C", "$MM$", "𝕄")
    CreateHotstring("*C", "$NN$", "ℕ")
    CreateHotstring("*C", "$OO$", "𝕆")
    CreateHotstring("*C", "$PP$", "ℙ")
    CreateHotstring("*C", "$QQ$", "ℚ")
    CreateHotstring("*C", "$RR$", "ℝ")
    CreateHotstring("*C", "$SS$", "𝕊")
    CreateHotstring("*C", "$TT$", "𝕋")
    CreateHotstring("*C", "$UU$", "𝕌")
    CreateHotstring("*C", "$VV$", "𝕍")
    CreateHotstring("*C", "$WW$", "𝕎")
    CreateHotstring("*C", "$XX$", "𝕏")
    CreateHotstring("*C", "$YY$", "𝕐")
    CreateHotstring("*C", "$ZZ$", "ℤ")

    ; === Miscellaneous letter-likes ===
    CreateHotstring("*C", "$angstrom$", "Å")
    CreateHotstring("*C", "$ell$", "ℓ")
    CreateHotstring("*C", "$planck$", "ħ")
    CreateHotstring("*C", "$planck.reduce$", "ħ")
    CreateHotstring("*C", "$Re$", "ℜ")
    CreateHotstring("*C", "$Im$", "ℑ")
    ; Dotless
    CreateHotstring("*C", "$dotless.i$", "ı")
    CreateHotstring("*C", "$dotless.j$", "ȷ")

    ; === Miscellany ===
    ; Die
    CreateHotstring("*C", "$die.six$", "⚅")
    CreateHotstring("*C", "$die.five$", "⚄")
    CreateHotstring("*C", "$die.four$", "⚃")
    CreateHotstring("*C", "$die.three$", "⚂")
    CreateHotstring("*C", "$die.two$", "⚁")
    CreateHotstring("*C", "$die.one$", "⚀")
    ; Errorbar
    CreateHotstring("*C", "$errorbar.square.stroked$", "⧮")
    CreateHotstring("*C", "$errorbar.square.filled$", "⧯")
    CreateHotstring("*C", "$errorbar.diamond.stroked$", "⧰")
    CreateHotstring("*C", "$errorbar.diamond.filled$", "⧱")
    CreateHotstring("*C", "$errorbar.circle.stroked$", "⧲")
    CreateHotstring("*C", "$errorbar.circle.filled$", "⧳")
    ; Gender
    CreateHotstring("*C", "$gender.female$", "♀")
    CreateHotstring("*C", "$gender.female.double$", "⚢")
    CreateHotstring("*C", "$gender.female.male$", "⚤")
    CreateHotstring("*C", "$gender.intersex$", "⚥")
    CreateHotstring("*C", "$gender.male$", "♂")
    CreateHotstring("*C", "$gender.male.double$", "⚣")
    CreateHotstring("*C", "$gender.male.female$", "⚤")
    CreateHotstring("*C", "$gender.male.stroke$", "⚦")
    CreateHotstring("*C", "$gender.male.stroke.t$", "⚨")
    CreateHotstring("*C", "$gender.male.stroke.r$", "⚩")
    CreateHotstring("*C", "$gender.neuter$", "⚲")
    CreateHotstring("*C", "$gender.trans$", "⚧")
}

; ===============================
; ======= 9.6) Repeat key =======
; ===============================

#InputLevel 1 ; Mandatory for this section to work, it needs to be below the inputlevel of the key remappings

; ★ becomes a repeat key. It will activate will the lowest priority of all hotstrings
; That means a letter will only be repeated if no hotstring defined above matches
if Features["MagicKey"]["Repeat"].Enabled {
    ; ======= PRIORITY 1/3: SFB corrections with Ê — Special cases =======
    ; Defined with the highest priority, so that priority 2 below won’t be activated

    ; Special case of "honnête" (we don’t want "honnute")
    CreateCaseSensitiveHotstrings("*?", "honnê", "honnê")
    ; Special case of "arrêt" (we don’t want "arrut")
    CreateCaseSensitiveHotstrings("*?", "arrê", "arrê")

    ; ======= PRIORITY 2/3: SFB corrections with Ê =======
    ; Instead of having a SFB when we type ★ (repeat last character) + U, we can type ★ + Ê that will transforms Ê into U
    CreateCaseSensitiveHotstrings("*?", "ccê", "ccu")
    CreateCaseSensitiveHotstrings("*?", "ddê", "ddu")
    CreateCaseSensitiveHotstrings("*?", "ffê", "ffu")
    CreateCaseSensitiveHotstrings("*?", "ggê", "ggu")
    CreateCaseSensitiveHotstrings("*?", "llê", "llu")
    CreateCaseSensitiveHotstrings("*?", "mmê", "mmu")
    CreateCaseSensitiveHotstrings("*?", "nnê", "nnu")
    CreateCaseSensitiveHotstrings("*?", "ppê", "ppu")
    CreateCaseSensitiveHotstrings("*?", "rrê", "rru")
    CreateCaseSensitiveHotstrings("*?", "ssê", "ssu")
    CreateCaseSensitiveHotstrings("*?", "ttê", "ttu")

    ; ======= PRIORITY 3/3: Repeat last sent character =======

    ; === Letters ===
    CreateCaseSensitiveHotstrings("*?", "a" . ScriptInformation["MagicKey"], "aa")
    CreateCaseSensitiveHotstrings("*?", "b" . ScriptInformation["MagicKey"], "bb")
    CreateCaseSensitiveHotstrings("*?", "c" . ScriptInformation["MagicKey"], "cc")
    CreateCaseSensitiveHotstrings("*?", "d" . ScriptInformation["MagicKey"], "dd")
    CreateCaseSensitiveHotstrings("*?", "e" . ScriptInformation["MagicKey"], "ee")
    CreateCaseSensitiveHotstrings("*?", "é" . ScriptInformation["MagicKey"], "éé")
    CreateCaseSensitiveHotstrings("*?", "è" . ScriptInformation["MagicKey"], "èè")
    CreateCaseSensitiveHotstrings("*?", "ê" . ScriptInformation["MagicKey"], "êê")
    CreateCaseSensitiveHotstrings("*?", "f" . ScriptInformation["MagicKey"], "ff")
    CreateCaseSensitiveHotstrings("*?", "g" . ScriptInformation["MagicKey"], "gg")
    CreateCaseSensitiveHotstrings("*?", "h" . ScriptInformation["MagicKey"], "hh")
    CreateCaseSensitiveHotstrings("*?", "i" . ScriptInformation["MagicKey"], "ii")
    CreateCaseSensitiveHotstrings("*?", "j" . ScriptInformation["MagicKey"], "jj")
    CreateCaseSensitiveHotstrings("*?", "k" . ScriptInformation["MagicKey"], "kk")
    CreateCaseSensitiveHotstrings("*?", "l" . ScriptInformation["MagicKey"], "ll")
    CreateCaseSensitiveHotstrings("*?", "m" . ScriptInformation["MagicKey"], "mm")
    CreateCaseSensitiveHotstrings("*?", "n" . ScriptInformation["MagicKey"], "nn")
    CreateCaseSensitiveHotstrings("*?", "o" . ScriptInformation["MagicKey"], "oo")
    CreateCaseSensitiveHotstrings("*?", "p" . ScriptInformation["MagicKey"], "pp")
    CreateCaseSensitiveHotstrings("*?", "q" . ScriptInformation["MagicKey"], "qq")
    CreateCaseSensitiveHotstrings("*?", "r" . ScriptInformation["MagicKey"], "rr")
    CreateCaseSensitiveHotstrings("*?", "s" . ScriptInformation["MagicKey"], "ss")
    CreateCaseSensitiveHotstrings("*?", "t" . ScriptInformation["MagicKey"], "tt")
    CreateCaseSensitiveHotstrings("*?", "u" . ScriptInformation["MagicKey"], "uu")
    CreateCaseSensitiveHotstrings("*?", "v" . ScriptInformation["MagicKey"], "vv")
    CreateCaseSensitiveHotstrings("*?", "w" . ScriptInformation["MagicKey"], "ww")
    CreateCaseSensitiveHotstrings("*?", "x" . ScriptInformation["MagicKey"], "xx")
    CreateCaseSensitiveHotstrings("*?", "y" . ScriptInformation["MagicKey"], "yy")
    CreateCaseSensitiveHotstrings("*?", "z" . ScriptInformation["MagicKey"], "zz")

    ; === Numbers ===
    CreateHotstring("*?", "0" . ScriptInformation["MagicKey"], "00")
    CreateHotstring("*?", "1" . ScriptInformation["MagicKey"], "11")
    CreateHotstring("*?", "2" . ScriptInformation["MagicKey"], "22")
    CreateHotstring("*?", "3" . ScriptInformation["MagicKey"], "33")
    CreateHotstring("*?", "4" . ScriptInformation["MagicKey"], "44")
    CreateHotstring("*?", "5" . ScriptInformation["MagicKey"], "55")
    CreateHotstring("*?", "6" . ScriptInformation["MagicKey"], "66")
    CreateHotstring("*?", "7" . ScriptInformation["MagicKey"], "77")
    CreateHotstring("*?", "8" . ScriptInformation["MagicKey"], "88")
    CreateHotstring("*?", "9" . ScriptInformation["MagicKey"], "99")

    ; === Symbol pairs ===
    CreateHotstring("*?", "<" . ScriptInformation["MagicKey"], "<<")
    CreateHotstring("*?", ">" . ScriptInformation["MagicKey"], ">>")
    CreateHotstring("*?", "{" . ScriptInformation["MagicKey"], "{{")
    CreateHotstring("*?", "}" . ScriptInformation["MagicKey"], "}}")
    CreateHotstring("*?", "(" . ScriptInformation["MagicKey"], "((")
    CreateHotstring("*?", ")" . ScriptInformation["MagicKey"], "))")
    CreateHotstring("*?", "[" . ScriptInformation["MagicKey"], "[[")
    CreateHotstring("*?", "]" . ScriptInformation["MagicKey"], "]]")

    ; === Symbols ===
    CreateHotstring("*?", "-" . ScriptInformation["MagicKey"], "--")
    CreateHotstring("*?", "_" . ScriptInformation["MagicKey"], "__")
    CreateHotstring("*?", ":" . ScriptInformation["MagicKey"], "::")
    CreateHotstring("*?", ";" . ScriptInformation["MagicKey"], ";;")
    CreateHotstring("*?", "?" . ScriptInformation["MagicKey"], "??")
    CreateHotstring("*?", "!" . ScriptInformation["MagicKey"], "!!")
    CreateHotstring("*?", "+" . ScriptInformation["MagicKey"], "++")
    CreateHotstring("*?", "^" . ScriptInformation["MagicKey"], "^^")
    CreateHotstring("*?", "#" . ScriptInformation["MagicKey"], "##")
    CreateHotstring("*?", "``" . ScriptInformation["MagicKey"], "````")
    CreateHotstring("*?", "=" . ScriptInformation["MagicKey"], "==")
    CreateHotstring("*?", "/" . ScriptInformation["MagicKey"], "//")
    CreateHotstring("*?", "\" . ScriptInformation["MagicKey"], "\\")
    CreateHotstring("*?", "|" . ScriptInformation["MagicKey"], "||")
    CreateHotstring("*?", "&" . ScriptInformation["MagicKey"], "&&")
    CreateHotstring("*?", "$" . ScriptInformation["MagicKey"], "$$")
    CreateHotstring("*?", "@" . ScriptInformation["MagicKey"], "@@")
    CreateHotstring("*?", "~" . ScriptInformation["MagicKey"], "~~")
    CreateHotstring("*?", "*" . ScriptInformation["MagicKey"], "**")
}
