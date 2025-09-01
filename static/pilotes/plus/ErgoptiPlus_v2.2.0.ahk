#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

#Warn All
#Warn VarUnset, Off ; Disable undefined variables warning. This removes the warnings caused by the import of UIA

#Include *i UIA\Lib\UIA.ahk ; Can be downloaded here : https://github.com/Descolada/UIA-v2/tree/main
; *i = no error if the file isn't found, as this library is not mandatory to run this script

#Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t   ; Adds the no breaking spaces as hotstrings triggers
A_MenuMaskKey := "vkff" ; Change the masking key to the void key
A_MaxHotkeysPerInterval := 200 ; Reduce messages saying too many hotkeys pressed in the interval

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
HotstringsTriggerDelay := 30 ; in ms
ActivateHotstrings() {
    SendNewResult(" ")
    Sleep(HotstringsTriggerDelay)
    SendFinalResult("{BackSpace}")
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

    if IsTimeActivationExpired(Abbreviation, OptionTimeActivationSeconds) {
        return
    }

    ; We pass the abbreviation as argument to delete it manually, as we use the B0 flag
    ; This is to make it work everywhere, like in URL bar or in the code inspector inside navigators
    ; Otherwise, typing hc to get wh gives hwh for example when trying to type "white"
    NumberOfCharactersToDelete := StrLen(Abbreviation)
    if (EndChar != "" and EndChar != "`t") {
        ; Delete ending character too if present, to then add it again
        ; Doesn’t work with Tab, as it can add multiple Spaces
        NumberOfCharactersToDelete := NumberOfCharactersToDelete + 1
    }

    if FinalResult {
        if (EndChar == "`t") {
            SendFinalResult("^{BackSpace}", Map("OnlyText", False)) ; To remove the tab
        }
        SendFinalResult("{BackSpace " . NumberOfCharactersToDelete . "}", Map("OnlyText", False))
        SendFinalResult(Replacement, Map("OnlyText", OnlyText))
        SendFinalResult(EndChar)
    } else {
        if (EndChar == "`t") {
            SendNewResult("^{BackSpace}", Map("OnlyText", False)) ; To remove the tab
        }
        SendNewResult("{BackSpace " . NumberOfCharactersToDelete . "}", Map("OnlyText", False))
        SendNewResult(Replacement, Map("OnlyText", OnlyText))
        SendNewResult(EndChar, Map("OnlyText", False))
    }
}

IsTimeActivationExpired(Abbreviation, OptionTimeActivationSeconds) {
    ; Don’t activate the hotstring if taped too slowly
    Now := A_TickCount
    PreviousCharacter := SubStr(Abbreviation, -2, 1)
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
    OptionTimeActivationSeconds := options.Has("TimeActivationSeconds") ? options[
        "TimeActivationSeconds"] : 0

    HotstringOptions := Map("OnlyText", OptionOnlyText).Set("FinalResult", OptionFinalResult).Set(
        "TimeActivationSeconds", OptionTimeActivationSeconds)

    FlagsPortion := ":" Flags "CB0:"
    AbbreviationLowercase := StrLower(Abbreviation)
    ReplacementLowercase := StrLower(Replacement)
    AbbreviationTitleCase := StrTitle(Abbreviation)
    ReplacementTitleCase := StrTitle(Replacement)
    AbbreviationUppercase := StrUpper(Abbreviation)
    ReplacementUppercase := StrUpper(Replacement)

    ; Abbreviation lowercase
    Hotstring(
        FlagsPortion AbbreviationLowercase,
        (*) => HotstringHandler(AbbreviationLowercase, ReplacementLowercase, A_EndChar, HotstringOptions)
    )

    ; First letter of abbreviation uppercase and rest lowercase
    if not OptionPreferTitleCase {
        ; Special case of repeat key ("A★" must give AA)
        Hotstring(
            FlagsPortion AbbreviationTitleCase,
            (*) => HotstringHandler(AbbreviationTitleCase, ReplacementUppercase, A_EndChar, HotstringOptions)
        )
        return
    } else if (SubStr(AbbreviationTitleCase, 1, 1) == ",") {
        ; In case we are creating the abbreviations for the , key, we need to consider its shift version
        AbbreviationTitleCaseV1 := " :" SubStr(AbbreviationLowercase, 2)
        Hotstring(
            FlagsPortion AbbreviationTitleCaseV1,
            (*) => HotstringHandler(AbbreviationTitleCaseV1, ReplacementTitleCase, A_EndChar, HotstringOptions)
        )
        AbbreviationTitleCaseV2 := " ;" SubStr(AbbreviationLowercase, 2)
        Hotstring(
            FlagsPortion AbbreviationTitleCaseV2,
            (*) => HotstringHandler(AbbreviationTitleCaseV2, ReplacementTitleCase, A_EndChar, HotstringOptions)
        )
    } else {
        Hotstring(
            FlagsPortion AbbreviationTitleCase,
            (*) => HotstringHandler(AbbreviationTitleCase, ReplacementTitleCase, A_EndChar, HotstringOptions)
        )
    }

    ; Abbreviation uppercase
    if StrLen(RTrim(Abbreviation, "★")) > 1 {
        ; The abbreviation usually finishes with ★, so we remove it to get the real length
        ; If this length is 1, that means Titlecase and Uppercase abbreviation will trigger the same result.
        ; Thus, we need to make sure this result is in titlecase instead of uppercase because it is the most useful.
        if (SubStr(AbbreviationUppercase, 1, 1) == ",") {
            Hotstring(
                FlagsPortion AbbreviationUppercase,
                (*) => HotstringHandler(AbbreviationUppercase, ReplacementUppercase, A_EndChar, HotstringOptions)
            )
            ; In case we are creating the abbreviations for the , key, we need to consider its shift version
            AbbreviationUppercaseV1 := " :" SubStr(AbbreviationUppercase, 2)
            Hotstring(
                FlagsPortion AbbreviationUppercaseV1,
                (*) => HotstringHandler(AbbreviationUppercaseV1, ReplacementUppercase, A_EndChar, HotstringOptions
                )
            )
            AbbreviationUppercaseV2 := " ;" SubStr(AbbreviationUppercase, 2)
            Hotstring(
                FlagsPortion AbbreviationUppercaseV2,
                (*) => HotstringHandler(AbbreviationUppercaseV2, ReplacementUppercase, A_EndChar, HotstringOptions
                )
            )
        } else if (SubStr(AbbreviationUppercase, -1, 1) == "'") {
            AbbreviationUppercase := SubStr(AbbreviationUppercase, 1, StrLen(AbbreviationUppercase) - 1) " ?"
            Hotstring(
                FlagsPortion AbbreviationUppercase,
                (*) => HotstringHandler(AbbreviationUppercase, ReplacementUppercase, A_EndChar, HotstringOptions)
            )
        }
        else {
            Hotstring(
                FlagsPortion AbbreviationUppercase,
                (*) => HotstringHandler(AbbreviationUppercase, ReplacementUppercase, A_EndChar, HotstringOptions)
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
            "SuffixesA",
            "QU",
            "DeadKeyECircumflex",
            "CommaJ",
            "CommaFarLetters",
            "SpaceAroundSymbols"
        ],
        "QU", {
            Enabled: True,
            Description: "Q devient QU quand elle est suivie d’une voyelle : q + a = qua, q + o = quo, …",
            TimeActivationSeconds: 1,
        },
        "SuffixesA", {
            Enabled: True,
            Description: "À + lettre donne un suffixe : às = ement, àn = ation, àé = ying, …",
            TimeActivationSeconds: 1,
        },
        "DeadKeyECircumflex", {
            Enabled: True,
            Description: "Ê suivi d’une voyelle agit comme une touche morte : ê + o = ô, ê + u = û, …",
            TimeActivationSeconds: 1,
        },
        "CommaJ", {
            Enabled: True,
            Description: "Virgule + Voyelle donne J : ,a = ja, ,' = j’, …",
            TimeActivationSeconds: 1,
        },
        "CommaFarLetters", {
            Enabled: True,
            Description: "Virgule permet de taper des lettres excentrées : ,è=z et ,y=k et ,s=q et ,c=ç et ,x=où",
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
            "ECirc",
            "EGrave"
        ],
        "Comma", {
            Enabled: True,
            Description: "Virgule + Consonne corrige de très nombreux SFBs : ,t = pt, ,d= ds, ,p = xp, …",
            TimeActivationSeconds: 1,
        },
        "ECirc", {
            Enabled: True,
            Description: "Ê + touche sur la main gauche corrige des SFBs : êe = oe, eê = eo, ê. = u., êé = aî, …",
            TimeActivationSeconds: 1,
        },
        "EGrave", {
            Enabled: True,
            Description: "È + touche Y corrige 2 SFBs : èy = ié et yè = éi",
            TimeActivationSeconds: 1,
        },
        "BU", {
            Enabled: True,
            Description: "À corrige 2 SFBs : à★ = bu et àu = ub",
            TimeActivationSeconds: 1,
        },
    ),
    "Rolls", Map(
        "__Order", ["HC", "SX", "CX", "EnglishNegation", "EZ", "CT", "-", "CloseChevronTag", "ChevronEqual", "Assign",
            "NotEqual", "HashtagQuote", "HashtagParenthesis", "HashtagBracket", "EqualString", "Comment",
            "AssignArrowEqualRight", "AssignArrowEqualLeft", "AssignArrowMinusRight", "AssignArrowMinusLeft"],
        "HC", {
            Enabled: True,
            Description: "hc ➜ wh",
            TimeActivationSeconds: 0.5,
        },
        "SX", {
            Enabled: True,
            Description: "sx ➜ sk",
            TimeActivationSeconds: 0.5,
        },
        "CX", {
            Enabled: True,
            Description: "cx ➜ ck",
            TimeActivationSeconds: 0.5,
        },
        "EnglishNegation", {
            Enabled: True,
            Description: "nt' ➜ = n’t",
            TimeActivationSeconds: 0.5,
        },
        "EZ", {
            Enabled: True,
            Description: "eé ➜ ez",
            TimeActivationSeconds: 0.5,
        },
        "CT", {
            Enabled: True,
            Description: "p' ➜ ct",
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
            TimeActivationSeconds: 0.5,
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
        "Comment", {
            Enabled: True,
            Description: "\`" = /*",
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
            "TypographicApostrophe",
            "-",
            "Errors",
            "OU",
            "MultiplePonctuationMarks",
            "SuffixesAChaining",
            "-",
            "Minus",
            "-",
            "Brands",
            "Names",
            "Accents"
        ],
        "TypographicApostrophe", {
            Enabled: True,
            Description: "L’apostrophe devient typographique lors de l’écriture de texte : m'a = m’a, it's = it’s, …",
            TimeActivationSeconds: 1,
        },
        "Errors", {
            Enabled: True,
            Description: "Corrige certaines fautes de frappe : OUi = Oui, aeu = eau, …",
            TimeActivationSeconds: 1,
        },
        "SuffixesAChaining", {
            Enabled: True,
            Description: "Permet d’enchaîner plusieurs fois des suffixes, comme aim|able|ement = aimablement",
            TimeActivationSeconds: 1,
        },
        "Accents", {
            Enabled: True,
            Description: "Autocorrection des accents de nombreux mots",
        },
        "Brands", {
            Enabled: True,
            Description: "Met les majuscules au noms de marques : chatgpt = ChatGPT, powerpoint = PowerPoint, …",
        },
        "Names", {
            Enabled: True,
            Description: "Corrige les accents sur les prénoms et sur les noms de pays : alexei = Alexeï, taiwan = Taïwan, …",
        },
        "Minus", {
            Enabled: True,
            Description: "Évite de devoir taper des tirets : aije = ai-je, atil = a-t-il, … ",
        },
        "OU", {
            Enabled: True,
            Description: "Permet de taper [où ] puis un point ou une virgule et de supprimer automatiquement l’espace ajouté avant",
            TimeActivationSeconds: 1,
        },
        "MultiplePonctuationMarks", {
            Enabled: True,
            Description: "Permet de taper `"!`" ou `"?`" plusieurs fois d’affilée sans espace insécable entre chaque caractère",
            TimeActivationSeconds: 1,
        },
    ),
    "MagicKey", Map(
        "__Order", [
            "Replace",
            "Repeat",
            "-",
            "TextExpansionPersonalInformation",
            "TextExpansion",
            "TextExpansionEmojis",
            "TextExpansionSymbols",
            "TextExpansionSymbolsTypst"
        ],
        "Replace", {
            Enabled: True,
            Description: "Transformer la touche J en ★",
        },
        "Repeat", {
            Enabled: True,
            Description: "La touche ★ permet la répétition",
        },
        "TextExpansion", {
            Enabled: True,
            Description: "Expansion de texte : c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
        },
        "TextExpansionPersonalInformation", {
            Enabled: True,
            Description: "Remplissage de formulaires avec le suffixe @ : @np★ = Nom Prénom, etc.",
            PatternMaxLength: 3,
        },
        "TextExpansionEmojis", {
            Enabled: True,
            Description: "Expansion de texte Emojis : voiture★ = 🚗, koala★ = 🐨, …",
        },
        "TextExpansionSymbols", {
            Enabled: True,
            Description: "Expansion de texte Symboles : -->★ = ➜, (v)★ = ✓, …",
        },
        "TextExpansionSymbolsTypst", {
            Enabled: True,
            Description: "Expansion de texte Symboles Typst : $eq.not$ = ≠, $AA$ = 𝔸, …",
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
            "LAltCapsLockGivesCapsWord",
            "AltGrLAlt",
            "AltGrCapsLock",
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
            Description: "Taper un symbole quand du texte est sélectionné encadre le texte par celui-ci. Fonctionne si UIA/Lib/UIA.ahk est dans le dossier du script",
        },
        "MicrosoftBold", {
            Enabled: True,
            Description: "Ctrl + B met en gras dans les applications Microsoft au lieu de Ctrl + G",
        },
        "Save", {
            Enabled: False,
            Description: "Ctrl + J/★ = Ctrl + S. Attention, Ctrl + J est perdu",
        },
        "CtrlJ", {
            Enabled: False,
            Description: "Ctrl + S = Ctrl + J",
        },
        "LAltCapsLockGivesCapsWord", {
            Enabled: True,
            Description: "`"LAlt`" + `"CapsLock`" = CapsWord",
        },
        "AltGrLAlt", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = BackSpace",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Delete",
            },
            "CtrlBackSpace", {
                Enabled: True,
                Description: "`"AltGr`" + `"LAlt`" = Ctrl + BackSpace",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Ctrl + Delete",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = OneShotShift",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = CapsWord",
            },
        ),
        "AltGrCapsLock", Map(
            "CtrlDelete", {
                Enabled: True,
                Description: "`"AltGr`" + `"CapsLock`" = Ctrl + Delete",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Ctrl + BackSpace",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = CapsWord",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = CapsLock",
            },
        ),
        "SelectLine", {
            Enabled: True,
            Description: "Win + A(ll) = Sélectionne toute la ligne",
        },
        "Screen", {
            Enabled: True,
            Description: "Win + C(apture) = Prend une capture d’écran (Win + Shift + S)",
        },
        "GPT", {
            Enabled: True,
            Description: "Win + G(PT) = Ouvre ChatGPT",
            Link: "https://chatgpt.com/",
        },
        "GetHexValue", {
            Enabled: True,
            Description: "Win + H(ex) = Copie dans le presse-papiers la couleur HEX du pixel situé sous le curseur",
        },
        "TakeNote", {
            Enabled: True,
            Description: "Win + N(ote) = Ouvre un fichier pour prendre des notes",
            DatedNotes: False,
            DestinationFolder: A_Desktop,
        },
        "SurroundWithParentheses", {
            Enabled: True,
            Description: "Win + O = Entoure de parenthèses la ligne",
        },
        "Move", {
            Enabled: True,
            Description: "Win + M(ove) = Simule de l’activité en bougeant la souris aléatoirement. Réitérer le raccourci pour désactiver, ou recharger le script",
        },
        "Search", {
            Enabled: True,
            Description: "Win + S(earch) = Cherche la sélection sur google, ou récupère le chemin du fichier sélectionné",
        },
        "TitleCase", {
            Enabled: True,
            Description: "Win + T(itleCase) = Convertit en casse de titre (majuscule à chaque première lettre de mot)",
        },
        "Uppercase", {
            Enabled: True,
            Description: "Win + U(ppercase) = Convertit en majuscules/minuscules la sélection",
        },
        "SelectWord", {
            Enabled: True,
            Description: "Win + W(ord) = Sélectionne le mot là où se trouve le curseur",
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
            "EnterCtrl", {
                Enabled: True,
                Description: "`"CapsLock`" : Enter en tap, Ctrl en hold. CapsLock en Win + `"CapsLock`"",
                TimeActivationSeconds: 0.2,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"CapsLock`" : BackSpace. CapsLock en Win + `"CapsLock`"",
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
            TimeActivationSeconds: 0.35,
        },
        "LAlt", Map(
            "OneShotShift", {
                Enabled: False,
                Description: "`"LAlt`" : OneShotShift en tap, Shift en hold",
            },
            "AltTabMonitor", {
                Enabled: False,
                Description: "`"LAlt`" : Alt+Tab sur le moniteur en tap, Alt en hold",
                TimeActivationSeconds: 0.2,
            },
            "TabLayer", {
                Enabled: False,
                Description: "`"LAlt`" : Tab en tap, layer de navigation en hold",
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
        ),
        "Space", Map(
            "Layer", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, layer de navigation en hold",
                TimeActivationSeconds: 0.15,
            },
            "Ctrl", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, Ctrl en hold",
                TimeActivationSeconds: 0.15,
            },
        ),
        "AltGr", Map(
            "Tab", {
                Enabled: True,
                Description: "`"AltGr`" : Tab en tap, AltGr en hold",
                TimeActivationSeconds: 0.2,
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" : OneShotShift en tap, AltGr en hold",
                TimeActivationSeconds: 0.2,
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
    "DateOfBirth", "01/01/2020",
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

global ScriptInformation := Map(
    "ShortcutSuspend", True,
    "ShortcutSaveReload", True,
    "ShortcutEdit", True,
    ; The icon of the script when active or disabled
    "IconPath", "ErgoptiPlus_Icon.ico",
    "IconPathDisabled", "ErgoptiPlus_Icon_Disabled.ico",
)

; ======================================================================
; ======= 1.2) Variables update if there is a configuration file =======
; ======================================================================

global ConfigurationFile := "ErgoptiPlus_Configuration.ini"

; If the configuration file exists, update the default values created above by using the data in the file
if FileExist(ConfigurationFile) {
    ReadConfiguration()
}

ReadConfiguration() {
    global Features, PersonalInformation, ScriptInformation
    Props := ["Enabled", "TimeActivationSeconds", "Letter", "Link", "DestinationFolder", "DatedNotes"]

    for Category, FeaturesMap in Features {
        for Feature, Value in FeaturesMap {
            if (Type(Value) = "Map") {
                ; Sub-map => iterate sub-features under [Category.Feature]
                for SubFeature, SubValue in Value {
                    for Prop in Props {
                        Name := SubFeature . "." . Prop
                        RawValue := IniRead(ConfigurationFile, Category "." Feature, Name, "_")
                        if RawValue != "_" {
                            Features[Category][Feature][SubValue].%Prop% := RawValue
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
    global Features
    Keys := StrSplit(FullPath, ".")
    Feature := Features
    for K in Keys {
        Feature := Feature[K]
    }
    return Feature
}

; Toggle a feature Enabled state
ToggleMenuVariableByPath(FullPath) {
    Feature := GetFeatureByPath(FullPath)

    ; Chercher position du dernier point
    pos := InStr(FullPath, ".", , -1)
    if (pos) {
        FeatureCategoryPath := SubStr(FullPath, 1, pos - 1)   ; tout à gauche du point
        FeatureName := SubStr(FullPath, pos + 1)      ; tout à droite du point
    } else {
        FeatureCategoryPath := FullPath
        FeatureName := ""
    }

    ; MsgBox(Feature.Description " " Feature.Enabled)
    Feature.Enabled := !Feature.Enabled
    ; MsgBox(Feature.Description " " Feature.Enabled)
    Value := Feature.Enabled ? 1 : 0
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
            return "➄ Touche ★"
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
global MenuSuspend := "⏸︎ Suspendre (Raccourci : AltGr + ↩)"
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
    A_TrayMenu.Add("Modifier les coordonnées personnelles", PersonalInformationEditor)
    A_TrayMenu.Add("Modifier les raccourcis sur les lettres accentuées", ShortcutsEditor)
    A_TrayMenu.Add("Modifier le lien ouvert par Win + G", GPTLinkEditor)

    ; Script management section
    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuScriptManagement, NoAction)
    A_TrayMenu.Disable(MenuScriptManagement)
    A_TrayMenu.Add("✎ Éditer (Raccourci : AltGr + ⌦)", ActivateEdit)
    A_TrayMenu.Add(MenuSuspend, ToggleSuspend)
    A_TrayMenu.Add("🔄 Recharger (Raccourci : AltGr + ⌫)", ActivateReload)
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

PersonalInformationEditor(*) {
    GuiToShow := Gui(, "Modifier les coordonnées personnelles")
    UpdatedPersonalInformation := Map()

    ; Génère dynamiquement un champ par élément de la Map
    for key, OldValue in PersonalInformation {
        GuiToShow.SetFont("bold")
        GuiToShow.Add("Text", , key)
        GuiToShow.SetFont("norm")
        NewValue := GuiToShow.Add("Edit", "w300", OldValue)
        UpdatedPersonalInformation[key] := NewValue
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
        (*) => ModifyValues(GuiToShow, NewEGraveValue.Text, NewECircValue.Text, NewEAcuteValue.Text, NewAGraveValue.Text
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
    ; MsgBox(
    ;     "⚠ ATTENTION : Toutes les fonctionnalités ont été activées. Cela inclut les différents raccourcis que l’on peut choisir d’avoir sur la même combinaison de touches. Par défaut, le premier raccourci actif d’une combinaison de touches sera celui utilisé, les autres raccourcis actifs sur cette même combinaison n’auront pas d’effet. Après cette opération, il est cependant très fortement recommandé de DÉSACTIVER MANUELLEMENT LES RACCOURCIS EN CONFLIT pour éviter de futurs potentiels problèmes."
    ; )
    ToggleAllFeatures(1)
}
ToggleAllFeaturesOff(*) {
    ToggleAllFeatures(0)
}
ToggleAllFeatures(Value) {
    ; TO UPDATE because it isn’t easy like that anymore with one more level
    global Features
    for FeatureCategory in Features {
        if FeatureCategory == "__Order" {
            continue
        }
        for FeatureName in Features[FeatureCategory] {
            if FeatureName == "__Order" {
                continue
            }
            Features[FeatureCategory][FeatureName].Enabled := Value
            IniWrite(Value, ConfigurationFile, FeatureCategory, FeatureName . ".Enabled")
        }
    }
    Reload
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
    if GetKeyState("SC138", "P") {
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
    if GetKeyState("SC138", "P") {
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
    if GetKeyState("SC138", "P") {
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
            (*) => SendEvent(AlternativeCharacter) UpdateLastSentCharacter(AlternativeCharacter),
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

RemapAltGr(AltGrFunction, ShiftAltGrFunction) {
    if GetKeyState("Shift", "P") {
        ShiftAltGrFunction.Call()
    } else {
        AltGrFunction.Call()
    }
}

WrapTextIfSelected(Symbol, LeftSymbol, RightSymbol) {
    Selection := ""
    if isSet(UIA) and Features["Shortcuts"]["WrapTextIfSelected"].Enabled {
        try {
            el := UIA.GetFocusedElement()
            if (el.IsTextPatternAvailable) {
                Selection := el.GetSelection()[1].GetText()
            }
        }
    }

    if (Selection != "") {
        ; Send all the text instantly and without triggering hotstrings while typing it
        SendInstant(LeftSymbol Selection RightSymbol)
    } else {
        SendNewResult(Symbol)
    }
    UpdateLastSentCharacter(Symbol)
}

; === Dead Keys ===

DeadKey(Mapping) {
    ih := InputHook(
        "L1",
        "{F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Ins}{Numlock}{PrintScreen}{Pause}{Enter}{BackSpace}{Delete}"
    )
    ih.Start()
    ih.Wait()
    PressedKey := ih.Input
    if Mapping.Has(PressedKey) {
        SendNewResult(Mapping[PressedKey])
    } else {
        SendNewResult(PressedKey)
    }
}

; TODO : if KbdEdit is upgraded, some new Unicode characters will become available.
; This AutoHotkey script has all the characters, and the KbdEdit file has some missing ones.
; For example, there is no 🄋 character yet in KbdEdit, so we use a temporary ➉ as it is better than nothing

global DeadkeyMappingCircumflex := Map(
    "a", "â", "A", "Â",
    "à", "œ", "À", "Œ",
    "b", "⚐", "B", "⚑",
    "c", "º", "C", "°",
    "d", "★", "D", "☆",
    "e", "ê", "E", "Ê",
    "é", "æ", "É", "Æ",
    "è", "ó", "È", "Ó",
    "ê", "á", "Ê", "Á",
    "f", "✅", "F", "☑",
    "g", "ĝ", "G", "Ĝ",
    "h", "ĥ", "H", "Ĥ",
    "i", "î", "I", "Î",
    "j", "ĵ", "J", "Ĵ",
    "k", "☺", "K", "☻",
    "l", "†", "‡", "☻",
    "m", "⁂", "M", "⁂",
    "n", "ñ", "N", "Ñ",
    "o", "ô", "O", "Ô",
    "p", "¶", "P", "¶",
    "q", "☒", "Q", "☐",
    "r", "/", "R", "/",
    "s", "ß", "S", "ẞ",
    "t", "!", "T", "¡",
    "u", "û", "U", "Û",
    "v", "✓", "V", "✔",
    "w", "ŵ", "W", "Ŵ",
    "x", "✕", "X", "✖",
    "y", "ŷ", "Y", "Ŷ",
    "z", "ẑ", "Z", "Ẑ",
    " ", "^", "^", "^",
    "'", "⚠",
    ".", "•",
    ":", "▶",
    ",", "➜",
    ";", "↪",
    "/", "⁄",
    "0", "🄋",
    "1", "➀",
    "2", "➁",
    "3", "➂",
    "4", "➃",
    "5", "➄",
    "6", "➅",
    "7", "➆",
    "8", "➇",
    "9", "➈",
)

global DeadkeyMappingDiaresis := Map(
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
    " ", "¨", "¨", "¨",
    "0", "🄌",
    "1", "➊",
    "2", "➋",
    "3", "➌",
    "4", "➍",
    "5", "➎",
    "6", "➏",
    "7", "➐",
    "8", "➑",
    "9", "➒",
)

global DeadkeyMappingSuperscript := Map(
    "a", "ᵃ", "A", "ᴬ",
    "æ", "𐞃", "Æ", "ᴭ",
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
    "œ", "ꟹ", "Œ", "ꟹ",
    "œ", "ꟹ", "Œ", "ꟹ",
    "p", "ᵖ", "P", "ᴾ",
    "q", "𐞥", "Q", "ꟴ",
    "r", "ʳ", "R", "ᴿ",
    "s", "ˢ", "S", "ˢ",
    "t", "ᵗ", "T", "ᵀ",
    "u", "ᵘ", "U", "ᵁ",
    "v", "ᵛ", "V", "ⱽ",
    "w", "ʷ", "W", "ᵂ",
    "x", "ˣ", "X", "ˣ",
    "y", "ʸ", "Y", "ʸ",
    "z", "ᶻ", "Z", "ᶻ",
    " ", "ᵉ",
    ",", "ᶿ",
    ".", "ᵝ",
    "ê", "ᵠ", "Ê", "ᵠ",
    "é", "ᵟ", "É", "ᵟ",
    "è", "ᵞ", "È", "ᵞ",
    "à", "ᵡ", "À", "ᵡ",
    "(", "⁽", ")", "⁾",
    "[", "˹", "]", "˺",
    "+", "⁺", "-", "⁻",
    "/", "̸",
    "=", "⁼",
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
)

global DeadkeyMappingSubscript := Map(
    "a", "ₐ", "A", "ᴀ",
    "æ", "ᴁ", "Æ", "ᴁ",
    "b", "ᵦ", "B", "ʙ",
    "c", "ᴄ", "C", "ᴄ",
    "d", "ᴅ", "D", "ᴅ",
    "e", "ₑ", "E", "ᴇ",
    "f", "ꜰ", "F", "ꜰ",
    "g", "ᵧ", "G", "ɢ",
    "h", "ₕ", "H", "ʜ",
    "i", "ᵢ", "I", "ɪ",
    "j", "ⱼ", "J", "ᴊ",
    "k", "ₖ", "K", "ᴋ",
    "l", "ₗ", "L", "ʟ",
    "m", "ₘ", "M", "ᴍ",
    "n", "ₙ", "N", "ɴ",
    "o", "ₒ", "O", "ᴏ",
    "œ", "ɶ", "Œ", "ɶ",
    "p", "ᵨ", "P", "ₚ",
    "q", "ꞯ", "Q", "ꞯ",
    "r", "ᵣ", "R", "ʀ",
    "s", "ₛ", "S", "ꜱ",
    "t", "ₜ", "T", "ᴛ",
    "u", "ᵤ", "U", "ᴜ",
    "v", "ᵥ", "V", "ᴠ",
    "w", "ᴡ", "W", "ᴡ",
    "x", "ₓ", "X", "ₓ",
    "y", "ʏ", "Y", "ʏ",
    "z", "ᴢ", "Z", "ᴢ",
    " ", "ᵢ",
    "ê", "ᵩ", "Ê", "ᵩ",
    "è", "ᵧ", "È", "ᵧ",
    "(", "₍", ")", "₎",
    "[", "˻", "]", "˼",
    "+", "₊", "-", "₋",
    "/", "̸", "=", "₌",
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
)

global DeadkeyMappingGreek := Map(
    "a", "α", "A", "Α",
    "à", "θ", "À", "Θ",
    "b", "β", "B", "Β",
    "c", "ψ", "C", "Ψ",
    "d", "δ", "D", "Δ",
    "e", "ε", "E", "Ε",
    "é", "η", "É", "Η",
    "ê", "ϕ", "Ê", "ϕ",
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
    " ", "µ", "_", "Ω",
    "'", "ς"
)

global DeadkeyMappingR := Map(
    "b", "ℬ", "B", "ℬ",
    "c", "ℂ", "C", "ℂ",
    "e", "⅀", "E", "⅀",
    "f", "𝔽", "F", "ℱ",
    "g", "ℊ", "G", "ℊ",
    "h", "ℍ", "H", "ℋ",
    "j", "ℑ", "J", "ℐ",
    "l", "ℓ", "L", "ℒ",
    "m", "ℳ", "M", "ℳ",
    "n", "ℕ", "N", "ℕ",
    "p", "ℙ", "P", "ℙ",
    "q", "ℚ", "Q", "ℚ",
    "r", "ℝ", "R", "ℝ",
    "s", "⅀", "S", "⅀",
    "t", "ℭ", "T", "ℭ",
    "u", "ℿ", "U", "ℿ",
    "x", "ℜ", "X", "ℛ",
    "z", "ℤ", "Z", "ℨ",
    " ", "ℝ", "'", "ℜ",
    "(", "⟦", ")", "⟧",
    "[", "⟦", "]", "⟧",
    "<", "⟪", ">", "⟫",
    "«", "⟪", "»", "⟫",
)

global DeadkeyMappingCurrency := Map(
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
    "$", "£",
    "&", "৳",
    "'", "£",
    "-", "£",
    "_", "€",
    " ", "¤"
)

; =========================
; ======= 3.1) Base =======
; =========================

if Features["Layout"]["DirectAccessDigits"].Enabled {
    ; === Number row ===
    SC029:: SendInput("=")
    RemapKey("SC002", "1")
    RemapKey("SC003", "2")
    RemapKey("SC004", "3")
    RemapKey("SC005", "4")
    RemapKey("SC006", "5")
    RemapKey("SC007", "6")
    RemapKey("SC008", "7")
    RemapKey("SC009", "8")
    RemapKey("SC00A", "9")
    RemapKey("SC00B", "0")
    SC00C:: SendInput("%") ; Non letter characters don’t use RemapKey. Otherwise when tapping % for example, it will trigger and lock AltGr
    SC00D:: SendInput("$")
}

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
    SC01B:: DeadKey(DeadkeyMappingDiaresis)

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
    SC02B:: DeadKey(DeadkeyMappingCircumflex)

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
    RemapKey("SC02E", "j", "★")
}

; ==========================
; ======= 3.2) Shift =======
; ==========================

if Features["Layout"]["ErgoptiBase"].Enabled {
    ; === Space bar ===
    +SC039:: WrapTextIfSelected("-", "-", "-")

    ; === Number row ===
    +SC029:: SendNewResult("º")
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
        SendNewResult(" ") ; Thin non-breaking space
        Sleep(HotstringsTriggerDelay)
        SendNewResult("%")
    }
    +SC00D:: {
        SendNewResult(" ") ; Thin non-breaking space
        Sleep(HotstringsTriggerDelay)
        SendNewResult("€")
    }

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
    +SC01B:: SendNewResult(" ") ; Thin non-breaking space

    ; === Middle row ===
    +SC01E:: SendNewResult("A")
    +SC01F:: SendNewResult("I")
    +SC020:: SendNewResult("E")
    +SC021:: SendNewResult("U")
    +SC022:: {
        SendNewResult(" ") ; Non-breaking space
        Sleep(HotstringsTriggerDelay)
        SendNewResult(":")
    }
    +SC023:: SendNewResult("V")
    +SC024:: SendNewResult("S")
    +SC025:: SendNewResult("N")
    +SC026:: SendNewResult("T")
    +SC027:: SendNewResult("R")
    +SC028:: SendNewResult("Q")
    +SC02B:: {
        SendNewResult(" ") ; Thin non-breaking space
        Sleep(HotstringsTriggerDelay)
        SendNewResult("!")
    }

    ; === Bottom row ===
    +SC056:: SendNewResult("Ê")
    +SC02C:: SendNewResult("É")
    +SC02D:: SendNewResult("À")
    +SC02E:: SendNewResult("J")
    +SC02F:: {
        SendNewResult(" ") ; Thin non-breaking space
        Sleep(HotstringsTriggerDelay)
        SendNewResult(";")
    }
    +SC030:: SendNewResult("K")
    +SC031:: SendNewResult("M")
    +SC032:: SendNewResult("D")
    +SC033:: SendNewResult("L")
    +SC034:: SendNewResult("P")
    +SC035:: {
        SendNewResult(" ") ; Thin non-breaking space
        Sleep(HotstringsTriggerDelay)
        SendNewResult("?")
    }
}

; =============================
; ======= 3.3) CapsLock =======
; =============================

GetCapsLockCondition() {
    return GetKeyState("CapsLock", "T") and not LayerEnabled
}

#HotIf GetCapsLockCondition() and Features["MagicKey"]["Replace"].Enabled
SC02E:: SendNewResult("★")
#HotIf

#HotIf GetCapsLockCondition() and Features["Layout"]["ErgoptiBase"].Enabled
; === Number row ===
SC029:: SendNewResult("=")
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
SC00D:: SendNewResult("$")

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
SC01B:: DeadKey(DeadkeyMappingDiaresis)

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
SC02B:: DeadKey(DeadkeyMappingCircumflex)

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
SC138 & SC012:: RemapAltGr(
    () => AddRollEqual(),
    () => SendNewResult("Œ")
)
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
SC138 & SC017:: RemapAltGr(
    (*) => HashtagOrQuote(),
    (*) => SendNewResult("%")
)
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
SC138 & SC012:: RemapAltGr(
    () => WrapTextIfSelected("%", "%", "%"),
    () => SendNewResult("Œ")
)
SC138 & SC013:: RemapAltGr(
    (*) => SendNewResult("où" . SpaceAroundSymbols),
    (*) => SendNewResult("Où" . SpaceAroundSymbols)
)
SC138 & SC018:: RemapAltGr(
    (*) => WrapTextIfSelected("!", "!", "!"),
    (*) => SendNewResult(" !")
)
#HotIf

; AltGr layer of the Ergopti layout
#HotIf Features["Layout"]["ErgoptiAltGr"].Enabled

; === Space bar ===
SC138 & SC039:: WrapTextIfSelected("_", "_", "_")

; === Number row ===
SC138 & SC029:: RemapAltGr((*) => SendNewResult("°"), (*) => SendNewResult("ª"))
SC138 & SC002:: RemapAltGr((*) => SendNewResult("¹"), (*) => SendNewResult("₁"))
SC138 & SC003:: RemapAltGr((*) => SendNewResult("²"), (*) => SendNewResult("₂"))
SC138 & SC004:: RemapAltGr((*) => SendNewResult("³"), (*) => SendNewResult("₃"))
SC138 & SC005:: RemapAltGr((*) => SendNewResult("⁴"), (*) => SendNewResult("₄"))
SC138 & SC006:: RemapAltGr((*) => SendNewResult("⁵"), (*) => SendNewResult("₅"))
SC138 & SC007:: RemapAltGr((*) => SendNewResult("⁶"), (*) => SendNewResult("₆"))
SC138 & SC008:: RemapAltGr((*) => SendNewResult("⁷"), (*) => SendNewResult("₇"))
SC138 & SC009:: RemapAltGr((*) => SendNewResult("⁸"), (*) => SendNewResult("₈"))
SC138 & SC00A:: RemapAltGr((*) => SendNewResult("⁹"), (*) => SendNewResult("₉"))
SC138 & SC00B:: RemapAltGr((*) => SendNewResult("⁰"), (*) => SendNewResult("₀"))
SC138 & SC00C:: RemapAltGr((*) => SendNewResult("‰"), (*) => SendNewResult("‱"))
SC138 & SC00D:: RemapAltGr((*) => SendNewResult("€"), (*) => DeadKey(DeadkeyMappingCurrency))

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

; === Top row ===
SC138 & SC010:: RemapAltGr(
    (*) => WrapTextIfSelected("``", "``", "``"),
    (*) => SendNewResult("„")
)
SC138 & SC011:: RemapAltGr(
    (*) => WrapTextIfSelected("@", "@", "@"),
    (*) => SendNewResult("€")
)
SC138 & SC012:: RemapAltGr(
    (*) => SendNewResult("œ"),
    (*) => SendNewResult("Œ")
)
SC138 & SC013:: RemapAltGr(
    (*) => SendNewResult("ù"),
    (*) => SendNewResult("Ù")
)
SC138 & SC014:: RemapAltGr(
    (*) => WrapTextIfSelected("« ", '« ', ' »'),
    (*) => SendNewResult("“")
)
SC138 & SC015:: RemapAltGr(
    (*) => WrapTextIfSelected(" »", '« ', ' »'),
    (*) => SendNewResult("”")
)
SC138 & SC016:: RemapAltGr(
    (*) => WrapTextIfSelected("~", "~", "~"),
    (*) => SendNewResult("≈")
)
SC138 & SC017:: RemapAltGr(
    (*) => WrapTextIfSelected("#", "#", "#"),
    (*) => SendNewResult("%")
)
SC138 & SC018:: RemapAltGr(
    (*) => SendNewResult("ç"),
    (*) => SendNewResult("Ç")
)
SC138 & SC019:: RemapAltGr(
    (*) => WrapTextIfSelected("*", "*", "*"),
    (*) => SendNewResult("×")
)
SC138 & SC01A:: RemapAltGr(
    (*) => WrapTextIfSelected("%", "%", "%"),
    (*) => SendNewResult("‰")
)
SC138 & SC01B:: RemapAltGr(
    (*) => SendNewResult(" "),
    (*) => SendNewResult("£")
)

; === Middle row ===
SC138 & SC01E:: RemapAltGr(
    (*) => WrapTextIfSelected("<", "<", ">"),
    (*) => SendNewResult("≤")
)
SC138 & SC01F:: RemapAltGr(
    (*) => WrapTextIfSelected(">", "<", ">"),
    (*) => SendNewResult("≥")
)
SC138 & SC020:: RemapAltGr(
    (*) => WrapTextIfSelected("{", "{", "}"),
    (*) => DeadKey(DeadkeyMappingSuperscript)
)
SC138 & SC021:: RemapAltGr(
    (*) => WrapTextIfSelected("}", "{", "}"),
    (*) => DeadKey(DeadkeyMappingGreek)
)
SC138 & SC022:: RemapAltGr(
    (*) => WrapTextIfSelected(":", ":", ":"),
    (*) => SendNewResult("·")
)
SC138 & SC023:: RemapAltGr(
    (*) => WrapTextIfSelected("|", "|", "|"),
    (*) => SendNewResult("¦")
)
SC138 & SC024:: RemapAltGr(
    (*) => WrapTextIfSelected("(", "(", ")"),
    (*) => SendNewResult("—")
)
SC138 & SC025:: RemapAltGr(
    (*) => WrapTextIfSelected(")", "(", ")"),
    (*) => SendNewResult("–")
)
SC138 & SC026:: RemapAltGr(
    (*) => WrapTextIfSelected("[", "[", "]"),
    (*) => DeadKey(DeadkeyMappingDiaresis)
)
SC138 & SC027:: RemapAltGr(
    (*) => WrapTextIfSelected("]", "[", "]"),
    (*) => DeadKey(DeadkeyMappingR)
)
SC138 & SC028:: RemapAltGr(
    (*) => SendNewResult("’"),
    (*) => DeadKey(DeadkeyMappingCurrency)
)
SC138 & SC02B:: RemapAltGr(
    (*) => WrapTextIfSelected("!", "!", "!"),
    (*) => SendNewResult("¡")
)

; === Bottom row ===
SC138 & SC056:: RemapAltGr(
    (*) => WrapTextIfSelected("^", "^", "^"),
    (*) => DeadKey(DeadkeyMappingCircumflex)
)
SC138 & SC02C:: RemapAltGr(
    (*) => WrapTextIfSelected("/", "/", "/"),
    (*) => SendNewResult("÷")
)
SC138 & SC02D:: RemapAltGr(
    (*) => WrapTextIfSelected("\", "\", "\"),
    (*) => DeadKey(DeadkeyMappingSubscript)
)
SC138 & SC02E:: RemapAltGr(
    (*) => WrapTextIfSelected("`"", "`"", "`""),
    (*) => SendNewResult("j")
)
SC138 & SC02F:: RemapAltGr(
    (*) => WrapTextIfSelected(";", ";", ";"),
    (*) => SendNewResult("…")
)
SC138 & SC030:: RemapAltGr(
    (*) => SendNewResult("…"),
    (*) =>
)
SC138 & SC031:: RemapAltGr(
    (*) => WrapTextIfSelected("&", "&", "&"),
    (*) => SendNewResult("−")
)
SC138 & SC032:: RemapAltGr(
    (*) => WrapTextIfSelected("$", "$", "$"),
    (*) => SendNewResult("§")
)
SC138 & SC033:: RemapAltGr(
    (*) => WrapTextIfSelected("=", "=", "="),
    (*) => SendNewResult("≠")
)
SC138 & SC034:: RemapAltGr(
    (*) => WrapTextIfSelected("+", "+", "+"),
    (*) => SendNewResult("±")
)
SC138 & SC035:: RemapAltGr(
    (*) => WrapTextIfSelected("?", "?", "?"),
    (*) => SendNewResult("¿")
)
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
    Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled
    ; We need to handle the shortcut differently when LAlt has been remapped:
    and not Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled
    and not Features["TapHolds"]["LAlt"]["BackSpace"].Enabled ; No need to add the shortcut here, as it is impossible with a BackSpace key that fires immediately
    and not Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled ; Here we directly change the result on the layer
    and not Features["TapHolds"]["LAlt"]["TabLayer"].Enabled ; Here we directly change the result on the layer
)
SC038 & SC03A:: ToggleCapsWordState()
#HotIf

; This function fixes Features["Shortcuts"]["LAltCapsLockGivesCapsWord"] when used with Features["TapHolds"]["LAlt"]["OneShotShift"]
; It needs to be used in every remapping of the "CapsLock" key, or the "CapsLock" key itself if no remapping is done
CapsWordShortcutFix() {
    if (
        Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled
        and Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled
        and GetKeyState("SC038", "P")
    ) {
        ToggleCapsWordState()
        return
    }
}

; When no remapping of the "CapsLock" key is done, add the fix
#HotIf (
    Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled
    and Features["TapHolds"]["LAlt"]["OneShotShift"].Enabled
    and not Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled and not LayerEnabled
)
~SC03A::
{
    CapsWordShortcutFix()
}
#HotIf

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

#HotIf Features["Shortcuts"]["AltGrLAlt"]["BackSpace"].Enabled
; "AltGr" + "LAlt" = BackSpace
; "Shift" + "AltGr" + "LAlt" = Ctrl + BackSpace (Can’t use Ctrl because of AltGr = Ctrl + Alt)
SC138 & SC038:: {
    OneShotShiftFix()
    if GetKeyState("Shift", "P") {
        SendInput("^{BackSpace}")
    } else {
        SendInput("{BackSpace}")
    }
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrLAlt"]["Delete"].Enabled
; "AltGr" + "LAlt" = Delete
; "Shift" + "AltGr" + "LAlt" = Ctrl + Delete (Can’t use Ctrl because of AltGr = Ctrl + Alt)
SC138 & SC038:: {
    OneShotShiftFix()
    if GetKeyState("Shift", "P") {
        SendInput("^{Delete}")
    } else {
        SendInput("{Delete}")
    }
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrLAlt"]["CtrlBackSpace"].Enabled
; "AltGr" + "LAlt" = Ctrl + BackSpace
; "Shift" + "AltGr" + "LAlt" = BackSpace (Can’t use Ctrl because of AltGr = Ctrl + Alt)
SC138 & SC038:: {
    OneShotShiftFix()
    if GetKeyState("Shift", "P") {
        SendInput("{BackSpace}")
    } else {
        SendInput("^{BackSpace}")
    }
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrLAlt"]["CtrlDelete"].Enabled
; "AltGr" + "LAlt" = Ctrl + Delete
; "Shift" + "AltGr" + "LAlt" = Delete (Can’t use Ctrl because of AltGr = Ctrl + Alt)
SC138 & SC038:: {
    OneShotShiftFix()
    if GetKeyState("Shift", "P") {
        SendInput("{Delete}")
    } else {
        SendInput("^{Delete}")
    }
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrLAlt"]["OneShotShift"].Enabled
; "AltGr" + "LAlt" = OneShotShift
SC138 & SC038:: {
    global OneShotShiftEnabled := True
    OneShotShift()
}
#HotIf
#HotIf Features["Shortcuts"]["AltGrLAlt"]["CapsWord"].Enabled
; "AltGr" + "LAlt" = CapsWord
SC138 & SC038:: {
    ToggleCapsWordState()
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLock"]["CtrlDelete"].Enabled
; "AltGr" + "CapsLock" = Ctrl + Delete
SC138 & SC03A:: {
    SendInput("^{Delete}")
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLock"]["CtrlBackSpace"].Enabled
; "AltGr" + "CapsLock" = Ctrl + BackSpace
SC138 & SC03A:: {
    SendInput("^{BackSpace}")
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLock"]["CapsWord"].Enabled
; "AltGr" + "CapsLock" = CapsWord
SC138 & SC03A:: {
    ToggleCapsWordState()
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLock"]["CapsLock"].Enabled
; "AltGr" + "CapsLock" = CapsLock
SC138 & SC03A:: {
    SetCapsLockState( not GetCapsLockCondition())
}
#HotIf

; ============================
; ======= 4.6) Windows =======
; ============================

if Features["Shortcuts"]["SelectLine"].Enabled {
    ; Win + A (All)
    AddShortcut("#", "a", (*) => SelectLine)

    SelectLine(*) {
        SendFinalResult("{Home}{Shift Down}{End}{Shift Up}")
    }
}

if Features["Shortcuts"]["Screen"].Enabled {
    ; Win + C (Capture)
    AddShortcut("#", "c", (*) => (*) => SendFinalResult("#+s"))
}

if Features["Shortcuts"]["GPT"].Enabled {
    ; Win + G (GPT)
    AddShortcut("#", "g", (*) => (*) => Run(Features["Shortcuts"]["GPT"].Link))
}

if Features["Shortcuts"]["GetHexValue"].Enabled {
    ; Win + H (Hex)
    AddShortcut("#", "h", (*) => GetHexValue)

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
                Run("https://www.google.com/")
            } else {
                Run("https://www.google.com/search?q=" . SelectedText)
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
        if StrLeft(RegPath, 9) == "Computer\" {
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

        #SingleInstance
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

ToggleCapsWordState() {
    global CapsWordEnabled := not CapsWordEnabled
    UpdateCapsLockLED()
}

DisableCapsWordState() {
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
#HotIf Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled and CapsWordEnabled
SC039::
{
    SendEvent("{Space}")
    Keywait("SC039") ; Solves bug of 2 sent Spaces when exiting CapsWord with a Space
    DisableCapsWordState()
}

; Big Enter key
SC01C::
{
    SendEvent("{Enter}")
    DisableCapsWordState()
}

; Mouse click
~LButton::
~RButton::
{
    DisableCapsWordState()
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

#HotIf Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled and not LayerEnabled
*SC03A::Enter
; Tap-hold on "CapsLock" : Enter on tap, Ctrl on hold
$SC03A::
{
    CapsWordShortcutFix()
    SendEvent("{LControl Down}") ; It is necessary to send an event to then get it in A_PriorKey
    tap := KeyWait("CapsLock", "T" . Features["TapHolds"]["CapsLock"]["EnterCtrl"].TimeActivationSeconds)
    if (tap and (A_PriorKey == "LControl")) { ; A_PriorKey is to be able to fire shortcuts very quickly, under the tap time
        SendEvent("{LControl Up}")
        SendEvent("{Enter}")
        DisableCapsWordState()
    }
}
SC03A Up:: SendEvent("{LControl Up}")

; It is necessary to do this, otherwise keeping the finger pressed on CapsLock will trigger an infinite number of spaces instead of keeping Ctrl down
^SC03A:: {
    if GetKeyState("SC01D", 'P') {
        SendInput("{LControl Down}{Enter}{LControl Up}")
    }
}
#HotIf

#HotIf Features["TapHolds"]["CapsLock"]["BackSpace"].Enabled
SC03A::BackSpace
#HotIf

#HotIf Features["TapHolds"]["CapsLock"]["EnterCtrl"].Enabled or Features["TapHolds"]["CapsLock"]["BackSpace"].Enabled
; Win + "CapsLock" to toggle CapsLock
#SC03A::
{
    global CapsWordEnabled := False
    if GetKeyState("CapsLock", "T") {
        SetCapsLockState("Off")
    }
    else {
        SetCapsLockState("On")
    }
}
#HotIf

; =====================================
; ======= 5.2) LShift and LCtrl =======
; =====================================

#HotIf Features["TapHolds"]["LShiftCopy"].Enabled and not LayerEnabled
; Tap-hold on "LShift" : Ctrl + C on tap, Shift on hold
~$SC02A::
{
    tap := KeyWait("LShift", "T" . Features["TapHolds"]["LShiftCopy"].TimeActivationSeconds)
    if (tap and (A_PriorKey == "LShift")) { ; A_PriorKey is to be able to fire shortcuts very quickly, under the tap time
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
}

~SC01D Up:: {
    Now := A_TickCount
    CharacterSentTime := LastSentCharacterKeyTime.Has("LControl") ? LastSentCharacterKeyTime["LControl"] : Now
    if (
        Now - CharacterSentTime <= Features["TapHolds"]["LCtrlPaste"].TimeActivationSeconds * 1000
        and A_PriorKey == "LControl"
    ) {
        SendInput("^v")
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

    global OneShotShiftEnabled := True
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

    global LayerEnabled := True
    ResetNumberOfRepetitions()
    UpdateCapsLockLED()

    KeyWait("SC038")

    LayerEnabled := False
    UpdateCapsLockLED()

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

    global LayerEnabled := True
    ResetNumberOfRepetitions()
    UpdateCapsLockLED()

    KeyWait("SC038")

    LayerEnabled := False
    UpdateCapsLockLED()

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

    global LayerEnabled := True
    ResetNumberOfRepetitions()
    UpdateCapsLockLED()
    KeyWait("SC039")
    LayerEnabled := False
    UpdateCapsLockLED()
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

; ==========================
; ======= 5.5) AltGr =======
; ==========================

#HotIf Features["TapHolds"]["AltGr"]["Tab"].Enabled and not LayerEnabled
RAlt::Tab
; Tap-hold on "AltGr" : Tab on tap, AltGr on hold
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . Features["TapHolds"]["AltGr"]["Tab"].TimeActivationSeconds)
    if (tap and A_PriorKey == "RAlt") {
        DisableCapsWordState()
        if (GetKeyState("LControl", "P") and GetKeyState("LShift", "P")) {
            SendInput("^+{Tab}")
        } else if GetKeyState("LControl", "P") {
            SendInput("^{Tab}")
        } else if GetKeyState("LShift", "P") {
            SendInput("+{Tab}")
        } else if GetKeyState("LWin", "P") {
            SendEvent("#{Tab}") ; SendInput doesn’t work in that case
        } else {
            SendEvent("{Tab}") ; To be able to trigger hotstrings with a Tab ending character
        }
    }
}

SC01D & ~SC138 Up::
RAlt Up:: {
    UpdateLastSentCharacter("")
}
#HotIf

#HotIf Features["TapHolds"]["AltGr"]["OneShotShift"].Enabled and not LayerEnabled
; Tap-hold on "AltGr" : OneShotShift on tap, AltGr on hold
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . Features["TapHolds"]["AltGr"]["OneShotShift"].TimeActivationSeconds)
    if (tap and A_PriorKey == "RAlt") {
        DisableCapsWordState()
        global OneShotShiftEnabled := True
        OneShotShift()
    }
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
    global OneShotShiftEnabled := True
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

        ; Skip windows with no title — often tooltips, overlays, or hidden UI elements, and when dragging files
        if WinGetTitle(WindowId) == "" or WinGetTitle(WindowId) == "Drag" {
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
    ihvText := InputHook("L1 T2 E", "%€.★', ")
    ihvText.KeyOpt("{BackSpace}{Enter}{Delete}", "E") ; End keys to not swallow
    ihvText.Start()
    ihvText.Wait()
    SpecialCharacter := ""

    if (ihvText.EndKey == "%") {
        SpecialCharacter := " %"
    } else if (ihvText.EndKey == "€") {
        SpecialCharacter := " €"
    } else if (ihvText.EndKey == ".") {
        SpecialCharacter := " :"
    } else if (ihvText.EndKey == "★") {
        SpecialCharacter := "J" ; OneShotShift + ★ will give J directly
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

; ================================
; ======= Navigation layer =======
; ================================

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

; Fix to get the CapsWord shortcut working when "LAlt" is activating the layer
#HotIf (
    Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled
    and LayerEnabled
    and (
        Features["TapHolds"]["LAlt"]["BackSpaceLayer"].Enabled
        or Features["TapHolds"]["LAlt"]["TabLayer"].Enabled
    )
)
SC03A:: ToggleCapsWordState() ; Overrides the "BackSpace" shortcut on the layer
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

SC039:: ActionLayer("{Escape}")
WheelUp:: ActionLayer("{Volume_Up " . NumberOfRepetitions . "}") ; Turn on the volume by scrolling up
WheelDown:: ActionLayer("{Volume_Down " . NumberOfRepetitions . "}") ; Turn down the volume by scrolling down

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
}

; ==========================================
; ======= 6.2) Ê acts like a deadkey =======
; ==========================================

if Features["DistancesReduction"]["DeadKeyECircumflex"].Enabled {
    ; We specify the result with the vowels first to be sure it will override any problems
    CreateCaseSensitiveHotstrings(
        "*?", "êa", "â",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
        )
    )
    CreateCaseSensitiveHotstrings(
        "*?", "êi", "î",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
        )
    )
    CreateCaseSensitiveHotstrings(
        "*?", "êo", "ô",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
        )
    )
    CreateCaseSensitiveHotstrings(
        "*?", "êu", "û",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
        )
    )

    CreateCaseSensitiveHotstrings(
        "*?", "êé", "æ",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
        )
    )
    CreateCaseSensitiveHotstrings(
        "*?", "êà", "œ",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
        )
    )

    ; The "Ê" key will enable to use the other symbols on the layer if we aren’t inside a word
    DeadkeyMappingCircumflexModified := DeadkeyMappingCircumflex.Clone()
    for Vowel in ["a", "i", "o", "u", "é", "à"] {
        ; Necessary for things to work, as we define them above alraedy
        DeadkeyMappingCircumflexModified.Delete(Vowel)
    }
    DeadkeyMappingCircumflexModified.Delete("t") ; To be able to type "être"

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
        "*?", "êé", "aî",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "éê", "â",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "êe", "oe",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "eê", "eo",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["ECirc"].TimeActivationSeconds)
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

if Features["SFBsReduction"]["EGrave"] {
    CreateCaseSensitiveHotstrings(
        "*?", "yè", "éi",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["EGrave"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "èy", "ié",
        Map("TimeActivationSeconds", Features["SFBsReduction"]["EGrave"].TimeActivationSeconds)
    )
}

; ==========================================
; ======= 6.8) SFBs reduction with À =======
; ==========================================

if Features["SFBsReduction"]["BU"].Enabled and Features["MagicKey"]["TextExpansion"].Enabled {
    ; Those hotstrings must be defined before bu, otherwise they won’t get activated
    CreateCaseSensitiveHotstrings("*", "il a mà★", "il a mis à jour")
    CreateCaseSensitiveHotstrings("*", "la mà★", "la mise à jour")
    CreateCaseSensitiveHotstrings("*", "ta mà★", "ta mise à jour")
    CreateCaseSensitiveHotstrings("*", "ma mà★", "ma mise à jour")
    CreateCaseSensitiveHotstrings("*?", "e mà★", "e mise à jour")
    CreateCaseSensitiveHotstrings("*?", "es mà★", "es mises à jour")
    CreateCaseSensitiveHotstrings("*", "mà★", "mettre à jour")
    CreateCaseSensitiveHotstrings("*", "mià★", "mise à jour")
    CreateCaseSensitiveHotstrings("*", "pià★", "pièce jointe")
    CreateCaseSensitiveHotstrings("*", "tà★", "toujours")
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
    CreateCaseSensitiveHotstrings(
        "*?", "y'", "y’",
        Map("TimeActivationSeconds", Features["Autocorrection"]["TypographicApostrophe"].TimeActivationSeconds)
    )
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
    CreateHotstring(
        "*", "=_", "= ",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )

    ; === Caps correction ===
    CreateHotstring(
        "?:C", "OUi", "Oui",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )

    ; === Letters chaining correction ===
    CreateHotstring(
        "*?", "eua", "eau",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*?", "aeu", "eau",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "oiu", "oui",
        Map("TimeActivationSeconds", Features["Autocorrection"]["Errors"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*", "poru", "pour",
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

if Features["Autocorrection"]["MultiplePonctuationMarks"].Enabled {
    CreateHotstring(
        "*", " ! !", " !!",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePonctuationMarks"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "! !", "!!",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePonctuationMarks"].TimeActivationSeconds)
    )

    CreateHotstring(
        "*", " ? ?", " ??",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePonctuationMarks"].TimeActivationSeconds)
    )
    CreateHotstring(
        "*", "? ?", "??",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePonctuationMarks"].TimeActivationSeconds)
    )

    CreateHotstring(
        "*", "...", "…",
        Map("TimeActivationSeconds", Features["Autocorrection"]["MultiplePonctuationMarks"].TimeActivationSeconds)
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

    CreateCaseSensitiveHotstrings("*?", "vezv", "vez-v")
}

; ========================================
; ======= 8.4) Caps autocorrection =======
; ========================================

if Features["Autocorrection"]["Brands"].Enabled {
    CreateHotstring("", "autohotkey", "AutoHotkey")
    CreateHotstring("", "citroen", "Citroën")
    CreateHotstring("", "chatgpt", "ChatGPT")
    CreateHotstring("", "insee", "INSEE")
    CreateHotstring("", "latex", "LaTeX")
    CreateHotstring("", "lualatex", "LuaLaTeX")
    CreateHotstring("", "mbti", "MBTI")
    CreateHotstring("", "nasa", "NASA")
    CreateHotstring("", "nlp", "NLP")
    CreateHotstring("", "optimot", "Optimot")
    CreateHotstring("", "onedrive", "OneDrive")
    CreateHotstring("", "onenote", "OneNote")
    CreateHotstring("", "outlook", "Outlook")
    CreateHotstring("", "powerbi", "PowerBI")
    CreateHotstring("", "pnl", "PNL")
    CreateHotstring("", "powerpoint", "PowerPoint")
    CreateHotstring("", "sharepoint", "SharePoint")
    CreateHotstring("", "vscode", "VSCode")

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
    CreateCaseSensitiveHotstrings("*", "ainé", "aîné")
    CreateCaseSensitiveHotstrings("*", "ambigue", "ambiguë")
    CreateCaseSensitiveHotstrings("*", "ambigui", "ambiguï")
    CreateCaseSensitiveHotstrings("", "ame", "âme")
    CreateCaseSensitiveHotstrings("", "ames", "âmes")
    CreateCaseSensitiveHotstrings("", "ane", "âne")
    CreateCaseSensitiveHotstrings("*", "anerie", "ânerie")
    CreateCaseSensitiveHotstrings("", "anes", "ânes")
    CreateCaseSensitiveHotstrings("", "angstrom", "ångström")
    CreateCaseSensitiveHotstrings("", "apre", "âpre")
    CreateCaseSensitiveHotstrings("*", "appat", "appât")
    CreateCaseSensitiveHotstrings("", "apprete", "apprête")
    CreateCaseSensitiveHotstrings("", "appreter", "apprêter")
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
    CreateCaseSensitiveHotstrings("*", "cloture", "clôture")
    CreateCaseSensitiveHotstrings("*", "cloturé", "clôturé")
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
    ; CreateCaseSensitiveHotstrings("", "naive", "naïve") ; Conflict in English
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
    CreateCaseSensitiveHotstrings("*?", "oide", "oïde") ; Suffixes like ov-oïde
    CreateCaseSensitiveHotstrings("*?", "froide", "froide") ; Fixes this particular word to not get froïde
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
        "*?", "àé", "ying",
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
        "*?", "àh", "techn",
        Map("TimeActivationSeconds", Features["DistancesReduction"]["SuffixesA"].TimeActivationSeconds)
    )
    CreateCaseSensitiveHotstrings(
        "*?", "ài", "ight",
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
}

; ==========================================================
; ======= 9.2) PERSONAL INFORMATION SHORTCUTS WITH @ =======
; ==========================================================

if Features["MagicKey"]["TextExpansionPersonalInformation"].Enabled {
    global PersonalInformationHotstrings := Map(
        "a", PersonalInformation["StreetAddress"],
        "d", PersonalInformation["DateOfBirth"],
        "m", PersonalInformation["EmailAddress"],
        "n", PersonalInformation["LastName"],
        "p", PersonalInformation["FirstName"],
        "t", PersonalInformation["PhoneNumber"],
        "w", PersonalInformation["WorkEmailAddress"]
    )

    GeneratePersonalInformationHotstrings(hotstrings, maxLen) {
        keys := []
        for k in hotstrings
            keys.Push(k)
        loop maxLen
            Generate(keys, hotstrings, "", A_Index)
    }

    Generate(keys, hotstrings, combo, len) {
        if (len == 0) {
            value := ""
            loop parse, combo {
                if (hotstrings.Has(A_LoopField)) {
                    if (value != "")
                        value .= "{Tab}"
                    value .= hotstrings[A_LoopField]
                }
            }
            if (value != "")
                CreateHotstring("*", "@" combo "★", value, Map("OnlyText", False).Set("FinalResult", True))
            return
        }
        for key in keys
            Generate(keys, hotstrings, combo . key, len - 1)
    }

    GeneratePersonalInformationHotstrings(
        PersonalInformationHotstrings,
        Features["MagicKey"]["TextExpansionPersonalInformation"].PatternMaxLength
    )

    CreateHotstring("*", "@b★", PersonalInformation["BIC"], Map("FinalResult", True))
    CreateHotstring("*", "@bic★", PersonalInformation["BIC"], Map("FinalResult", True))
    CreateHotstring("*", "@c★", PersonalInformation["PhoneNumberClean"], Map("FinalResult", True))
    CreateHotstring("*", "@cb★", PersonalInformation["CreditCard"], Map("FinalResult", True))
    CreateHotstring("*", "@cc★", PersonalInformation["CreditCard"], Map("FinalResult", True))
    CreateHotstring("*", "@i★", PersonalInformation["IBAN"], Map("FinalResult", True))
    CreateHotstring("*", "@iban★", PersonalInformation["IBAN"], Map("FinalResult", True))
    CreateHotstring("*", "@rib★", PersonalInformation["IBAN"], Map("FinalResult", True))
    CreateHotstring("*", "@s★", PersonalInformation["SocialSecurityNumber"], Map("FinalResult", True))
    CreateHotstring("*", "@ss★", PersonalInformation["SocialSecurityNumber"], Map("FinalResult", True))
    CreateHotstring("*", "@tel★", PersonalInformation["PhoneNumber"], Map("FinalResult", True))
    CreateHotstring("*", "@tél★", PersonalInformation["PhoneNumber"], Map("FinalResult", True))
}

; ===========================================
; ======= 9.3) TEXT EXPANSION WITH ★ =======
; ===========================================

if Features["MagicKey"]["TextExpansion"].Enabled {
    ; === Alphabetic ligatures ===
    CreateCaseSensitiveHotstrings("*?", "ae★", "æ")
    CreateCaseSensitiveHotstrings("*?", "oe★", "œ")

    ; === Numbers and symbols ===
    CreateCaseSensitiveHotstrings("*", "1er★", "premier")
    CreateCaseSensitiveHotstrings("*", "1ere★", "première")
    CreateCaseSensitiveHotstrings("*", "2e★", "deuxième")
    CreateCaseSensitiveHotstrings("*", "3e★", "troisième")
    CreateCaseSensitiveHotstrings("*", "4e★", "quatrième")
    CreateCaseSensitiveHotstrings("*", "5e★", "cinquième")
    CreateCaseSensitiveHotstrings("*", "6e★", "sixième")
    CreateCaseSensitiveHotstrings("*", "7e★", "septième")
    CreateCaseSensitiveHotstrings("*", "8e★", "huitième")
    CreateCaseSensitiveHotstrings("*", "9e★", "neuvième")
    CreateCaseSensitiveHotstrings("*", "10e★", "dixième")
    CreateCaseSensitiveHotstrings("*", "11e★", "onzième")
    CreateCaseSensitiveHotstrings("*", "12e★", "douzième")
    CreateCaseSensitiveHotstrings("*", "20e★", "vingtième")
    CreateCaseSensitiveHotstrings("*", "100e★", "centième")
    CreateCaseSensitiveHotstrings("*", "1000e★", "millième")
    CreateCaseSensitiveHotstrings("*", "2s★", "2 secondes")
    CreateCaseSensitiveHotstrings("*", "//★", "rapport")
    CreateCaseSensitiveHotstrings("*", "+m★", "meilleur")

    ; === A ===
    CreateCaseSensitiveHotstrings("*", "a★", "ainsi")
    CreateCaseSensitiveHotstrings("*", "abr★", "abréviation")
    CreateCaseSensitiveHotstrings("*", "actu★", "actualité")
    CreateCaseSensitiveHotstrings("*", "add★", "addresse")
    CreateCaseSensitiveHotstrings("*", "admin★", "administrateur")
    CreateCaseSensitiveHotstrings("*", "afr★", "à faire")
    CreateCaseSensitiveHotstrings("*", "ah★", "aujourd’hui")
    CreateHotstring("*", "ahk★", "AutoHotkey")
    CreateCaseSensitiveHotstrings("*", "ajd★", "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "algo★", "algorithme")
    CreateCaseSensitiveHotstrings("*", "alpha★", "alphabétique")
    CreateCaseSensitiveHotstrings("*", "amé★", "amélioration")
    CreateCaseSensitiveHotstrings("*", "amélio★", "amélioration")
    CreateCaseSensitiveHotstrings("*", "anc★", "ancien")
    CreateCaseSensitiveHotstrings("*", "ano★", "anomalie")
    CreateCaseSensitiveHotstrings("*", "anniv★", "anniversaire")
    CreateCaseSensitiveHotstrings("*", "apm★", "après-midi")
    CreateCaseSensitiveHotstrings("*", "apad★", "à partir de")
    CreateCaseSensitiveHotstrings("*", "app★", "application")
    CreateCaseSensitiveHotstrings("*", "appart★", "appartement")
    CreateCaseSensitiveHotstrings("*", "appli★", "application")
    CreateCaseSensitiveHotstrings("*", "approx★", "approximation")
    CreateCaseSensitiveHotstrings("*", "archi★", "architecture")
    CreateCaseSensitiveHotstrings("*", "asso★", "association")
    CreateCaseSensitiveHotstrings("*", "asap★", "le plus rapidement possible")
    CreateCaseSensitiveHotstrings("*", "atd★", "attend")
    CreateCaseSensitiveHotstrings("*", "att★", "attention")
    CreateCaseSensitiveHotstrings("*", "aud★", "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "aug★", "augmentation")
    CreateCaseSensitiveHotstrings("*", "auj★", "aujourd’hui")
    CreateCaseSensitiveHotstrings("*", "auto★", "automatique")
    CreateCaseSensitiveHotstrings("*", "av★", "avant")
    CreateCaseSensitiveHotstrings("*", "avv★", "avez-vous")
    CreateCaseSensitiveHotstrings("*", "avvd★", "avez-vous déjà")

    ; === B ===
    CreateCaseSensitiveHotstrings("*", "b★", "bonjour")
    CreateCaseSensitiveHotstrings("*", "bc★", "because")
    CreateCaseSensitiveHotstrings("*", "bcp★", "beaucoup")
    CreateCaseSensitiveHotstrings("*", "bdd★", "base de données")
    CreateCaseSensitiveHotstrings("*", "bdds★", "bases de données")
    CreateCaseSensitiveHotstrings("*", "bea★", "beaucoup")
    CreateCaseSensitiveHotstrings("*", "bec★", "because")
    CreateCaseSensitiveHotstrings("*", "bib★", "bibliographie")
    CreateCaseSensitiveHotstrings("*", "biblio★", "bibliographie")
    CreateCaseSensitiveHotstrings("*", "bjr★", "bonjour")
    CreateCaseSensitiveHotstrings("*", "brain★", "brainstorming")
    CreateCaseSensitiveHotstrings("*", "br★", "bonjour")
    CreateCaseSensitiveHotstrings("*", "bsr★", "bonsoir")
    CreateCaseSensitiveHotstrings("*", "bv★", "bravo")
    CreateCaseSensitiveHotstrings("*", "bvn★", "bienvenue")
    CreateCaseSensitiveHotstrings("*", "bwe★", "bon week-end")
    CreateCaseSensitiveHotstrings("*", "bwk★", "bon week-end")

    ; === C ===
    CreateCaseSensitiveHotstrings("*", "c★", "c’est")
    CreateCaseSensitiveHotstrings("*", "cad★", "c’est-à-dire")
    CreateCaseSensitiveHotstrings("*", "camp★", "campagne")
    CreateCaseSensitiveHotstrings("*", "carac★", "caractère")
    CreateCaseSensitiveHotstrings("*", "caract★", "caractéristique")
    CreateCaseSensitiveHotstrings("*", "cb★", "combien")
    CreateCaseSensitiveHotstrings("*", "cc★", "copier-coller")
    CreateCaseSensitiveHotstrings("*", "ccé★", "copié-collé")
    CreateCaseSensitiveHotstrings("*", "ccl★", "conclusion")
    CreateCaseSensitiveHotstrings("*", "cdg★", "Charles de Gaulle")
    CreateCaseSensitiveHotstrings("*", "cdt★", "cordialement")
    CreateCaseSensitiveHotstrings("*", "certif★", "certification")
    CreateCaseSensitiveHotstrings("*", "chg★", "charge")
    CreateCaseSensitiveHotstrings("*", "chap★", "chapitre")
    CreateCaseSensitiveHotstrings("*", "chr★", "chercher")
    CreateCaseSensitiveHotstrings("*", "ci★", "ci-joint")
    CreateCaseSensitiveHotstrings("*", "cj★", "ci-joint")
    CreateCaseSensitiveHotstrings("*", "coeff★", "coefficient")
    CreateCaseSensitiveHotstrings("*", "cog★", "cognition")
    CreateCaseSensitiveHotstrings("*", "cogv★", "cognitive")
    CreateCaseSensitiveHotstrings("*", "comp★", "comprendre")
    CreateCaseSensitiveHotstrings("*", "cond★", "condition")
    CreateCaseSensitiveHotstrings("*", "conds★", "conditions")
    CreateCaseSensitiveHotstrings("*", "config★", "configuration")
    CreateCaseSensitiveHotstrings("*", "chgt★", "changement")
    CreateCaseSensitiveHotstrings("*", "cnp★", "ce n’est pas")
    CreateCaseSensitiveHotstrings("*", "contrib★", "contribution")
    CreateCaseSensitiveHotstrings("*", "couv★", "couverture")
    CreateCaseSensitiveHotstrings("*", "cpd★", "cependant")
    CreateCaseSensitiveHotstrings("*", "cr★", "compte-rendu")
    CreateCaseSensitiveHotstrings("*", "ct★", "c’était")
    CreateCaseSensitiveHotstrings("*", "ctb★", "c’est très bien")
    CreateCaseSensitiveHotstrings("*", "cv★", "ça va ?")
    CreateCaseSensitiveHotstrings("*", "cvt★", "ça va toi ?")
    CreateHotstring("*", "ctc★", "Est-ce que cela te convient ?")
    CreateHotstring("*", "cvc★", "Est-ce que cela vous convient ?")

    ; === D ===
    CreateCaseSensitiveHotstrings("*", "dac★", "d’accord")
    CreateCaseSensitiveHotstrings("*", "ddl★", "download")
    CreateCaseSensitiveHotstrings("*", "dé★", "déjà")
    CreateCaseSensitiveHotstrings("*", "dê★", "d’être")
    CreateCaseSensitiveHotstrings("*", "déc★", "décembre")
    CreateCaseSensitiveHotstrings("*", "dec★", "décembre")
    CreateCaseSensitiveHotstrings("*", "dedt★", "d’emploi du temps")
    CreateCaseSensitiveHotstrings("*", "déf★", "définition")
    CreateCaseSensitiveHotstrings("*", "def★", "définition")
    CreateCaseSensitiveHotstrings("*", "défs★", "définitions")
    CreateCaseSensitiveHotstrings("*", "démo★", "démonstration")
    CreateCaseSensitiveHotstrings("*", "demo★", "démonstration")
    CreateCaseSensitiveHotstrings("*", "dep★", "département")
    CreateCaseSensitiveHotstrings("*", "deux★", "deuxième")
    CreateCaseSensitiveHotstrings("*", "desc★", "description")
    CreateCaseSensitiveHotstrings("*", "dev★", "développeur")
    CreateCaseSensitiveHotstrings("*", "dév★", "développeur")
    CreateCaseSensitiveHotstrings("*", "devt★", "développement")
    CreateCaseSensitiveHotstrings("*", "dico★", "dictionnaire")
    CreateCaseSensitiveHotstrings("*", "diff★", "différence")
    CreateCaseSensitiveHotstrings("*", "difft★", "différent")
    CreateCaseSensitiveHotstrings("*", "dim★", "dimension")
    CreateCaseSensitiveHotstrings("*", "dimi★", "diminution")
    CreateCaseSensitiveHotstrings("*", "la dispo★", "la disposition")
    CreateCaseSensitiveHotstrings("*", "ta dispo★", "ta disposition")
    CreateCaseSensitiveHotstrings("*", "une dispo★", "une disposition")
    CreateCaseSensitiveHotstrings("*", "dispo★", "disponible")
    CreateCaseSensitiveHotstrings("*", "distri★", "distributeur")
    CreateCaseSensitiveHotstrings("*", "distrib★", "distributeur")
    CreateCaseSensitiveHotstrings("*", "dj★", "déjà")
    CreateCaseSensitiveHotstrings("*", "dm★", "donne-moi")
    CreateCaseSensitiveHotstrings("*", "la doc★", "la documentation")
    CreateCaseSensitiveHotstrings("*", "une doc★", "une documentation")
    CreateCaseSensitiveHotstrings("*", "doc★", "document")
    CreateCaseSensitiveHotstrings("*", "docs★", "documents")
    CreateCaseSensitiveHotstrings("*", "dp★", "de plus")
    CreateCaseSensitiveHotstrings("*", "dsl★", "désolé")
    CreateCaseSensitiveHotstrings("*", "dtm★", "détermine")
    CreateCaseSensitiveHotstrings("*", "dvlp★", "développe")

    ; === E ===
    CreateCaseSensitiveHotstrings("*", "e★", "est")
    CreateCaseSensitiveHotstrings("*", "echant★", "échantillon")
    CreateCaseSensitiveHotstrings("*", "echants★", "échantillons")
    CreateCaseSensitiveHotstrings("*", "eco★", "économie")
    CreateCaseSensitiveHotstrings("*", "ecq★", "est-ce que")
    CreateCaseSensitiveHotstrings("*", "edt★", "emploi du temps")
    CreateCaseSensitiveHotstrings("*", "eef★", "en effet")
    CreateCaseSensitiveHotstrings("*", "elt★", "élément")
    CreateCaseSensitiveHotstrings("*", "elts★", "éléments")
    CreateCaseSensitiveHotstrings("*", "eo★", "en outre")
    CreateCaseSensitiveHotstrings("*", "enc★", "encore")
    CreateCaseSensitiveHotstrings("*", "eng★", "english")
    CreateCaseSensitiveHotstrings("*", "enft★", "en fait")
    CreateCaseSensitiveHotstrings("*", "ens★", "ensemble")
    CreateCaseSensitiveHotstrings("*", "ent★", "entreprise")
    CreateCaseSensitiveHotstrings("*", "env★", "environ")
    CreateCaseSensitiveHotstrings("*", "ep★", "épisode")
    CreateCaseSensitiveHotstrings("*", "eps★", "épisodes")
    CreateCaseSensitiveHotstrings("*", "eq★", "équation")
    CreateCaseSensitiveHotstrings("*", "ety★", "étymologie")
    CreateCaseSensitiveHotstrings("*", "eve★", "événement")
    CreateCaseSensitiveHotstrings("*", "evtl★", "éventuel")
    CreateCaseSensitiveHotstrings("*", "evtle★", "éventuelle")
    CreateCaseSensitiveHotstrings("*", "evtlt★", "éventuellement")
    CreateCaseSensitiveHotstrings("*", "ex★", "exemple")
    CreateCaseSensitiveHotstrings("*", "exo★", "exercice")
    CreateCaseSensitiveHotstrings("*", "exp★", "expérience")
    CreateCaseSensitiveHotstrings("*", "expo★", "exposition")
    CreateCaseSensitiveHotstrings("*", "é★", "écart")
    CreateCaseSensitiveHotstrings("*", "éco★", "économie")
    CreateCaseSensitiveHotstrings("*", "ém★", "écris-moi")
    CreateCaseSensitiveHotstrings("*", "éq★", "équation")
    CreateCaseSensitiveHotstrings("*", "ê★", "être")
    CreateCaseSensitiveHotstrings("*", "êe★", "est-ce")
    CreateCaseSensitiveHotstrings("*", "êt★", "es-tu")

    ; === F ===
    CreateCaseSensitiveHotstrings("*", "f★", "faire")
    CreateCaseSensitiveHotstrings("*", "fam★", "famille")
    CreateCaseSensitiveHotstrings("*", "fb★", "Facebook")
    CreateCaseSensitiveHotstrings("*", "fc★", "fonction")
    CreateCaseSensitiveHotstrings("*", "fct★", "fonction")
    CreateCaseSensitiveHotstrings("*", "fea★", "feature")
    CreateCaseSensitiveHotstrings("*", "feat★", "feature")
    CreateCaseSensitiveHotstrings("*", "fev★", "février")
    CreateCaseSensitiveHotstrings("*", "fi★", "financier")
    CreateCaseSensitiveHotstrings("*", "fiè★", "financière")
    CreateCaseSensitiveHotstrings("*", "ff★", "Firefox")
    CreateCaseSensitiveHotstrings("*", "fig★", "figure")
    CreateCaseSensitiveHotstrings("*", "fl★", "falloir")
    CreateCaseSensitiveHotstrings("*", "freq★", "fréquence")
    CreateHotstring("*", "fr★", "France")
    CreateCaseSensitiveHotstrings("*", "frs★", "français")

    ; === G ===
    CreateCaseSensitiveHotstrings("*", "g★", "j’ai")
    CreateCaseSensitiveHotstrings("*", "g1r★", "j’ai une réunion")
    CreateCaseSensitiveHotstrings("*", "gar★", "garantie")
    CreateCaseSensitiveHotstrings("*", "gars★", "garanties")
    CreateCaseSensitiveHotstrings("*", "gd★", "grand")
    CreateCaseSensitiveHotstrings("*", "gg★", "Google")
    CreateCaseSensitiveHotstrings("*", "ges★", "gestion")
    CreateCaseSensitiveHotstrings("*", "gf★", "J’ai fait")
    CreateCaseSensitiveHotstrings("*", "gmag★", "J’ai mis à jour")
    CreateCaseSensitiveHotstrings("*", "gov★", "government")
    CreateCaseSensitiveHotstrings("*", "gouv★", "gouvernement")
    CreateCaseSensitiveHotstrings("*", "indiv★", "individuel")
    CreateCaseSensitiveHotstrings("*", "gpa★", "je n’ai pas")
    CreateCaseSensitiveHotstrings("*", "gt★", "j’étais")
    CreateCaseSensitiveHotstrings("*", "gvt★", "gouvernement")

    ; === H ===
    CreateCaseSensitiveHotstrings("*", "h★", "heure")
    CreateCaseSensitiveHotstrings("*", "his★", "historique")
    CreateCaseSensitiveHotstrings("*", "histo★", "historique")
    CreateCaseSensitiveHotstrings("*", "hyp★", "hypothèse")

    ; === I ===
    CreateCaseSensitiveHotstrings("*", "ia★", "intelligence artificielle")
    CreateCaseSensitiveHotstrings("*", "id★", "identifiant")
    CreateCaseSensitiveHotstrings("*", "idf★", "Île-de-France")
    CreateCaseSensitiveHotstrings("*", "idk★", "I don’t know")
    CreateCaseSensitiveHotstrings("*", "ids★", "identifiants")
    CreateCaseSensitiveHotstrings("*", "img★", "image")
    CreateCaseSensitiveHotstrings("*", "imgs★", "images")
    CreateCaseSensitiveHotstrings("*", "imm★", "immeuble")
    CreateCaseSensitiveHotstrings("*", "imo★", "in my opinion")
    CreateCaseSensitiveHotstrings("*", "imp★", "impossible")
    CreateCaseSensitiveHotstrings("*", "inf★", "inférieur")
    CreateCaseSensitiveHotstrings("*", "info★", "information")
    CreateHotstring("*", "insta★", "Instagram")
    CreateCaseSensitiveHotstrings("*", "intart★", "intelligence artificielle")
    CreateCaseSensitiveHotstrings("*", "inter★", "international")
    CreateCaseSensitiveHotstrings("*", "intro★", "introduction")

    ; === J ===
    CreateCaseSensitiveHotstrings("*", "j★", "bonjour")
    CreateCaseSensitiveHotstrings("*", "ja★", "jamais")
    CreateCaseSensitiveHotstrings("*", "janv★", "janvier")
    CreateCaseSensitiveHotstrings("*", "jm★", "j’aime")
    CreateCaseSensitiveHotstrings("*", "jms★", "jamais")
    CreateCaseSensitiveHotstrings("*", "jnsp★", "je ne sais pas")
    CreateCaseSensitiveHotstrings("*", "js★", "je suis")
    CreateCaseSensitiveHotstrings("*", "jsp★", "je ne sais pas")
    CreateCaseSensitiveHotstrings("*", "jtm★", "je t’aime")
    CreateCaseSensitiveHotstrings("*", "ju★", "jusque")
    CreateCaseSensitiveHotstrings("*", "ju'★", "jusqu’")
    CreateCaseSensitiveHotstrings("*", "jus★", "jusque")
    CreateCaseSensitiveHotstrings("*", "jusq★", "jusqu’")
    CreateCaseSensitiveHotstrings("*", "jus'★", "jusqu’")
    CreateCaseSensitiveHotstrings("*", "jui★", "juillet")

    ; === K ===
    CreateCaseSensitiveHotstrings("*", "k★", "contacter")
    CreateCaseSensitiveHotstrings("*", "kb★", "keyboard")
    CreateCaseSensitiveHotstrings("*", "kbd★", "keyboard")
    CreateCaseSensitiveHotstrings("*", "kn★", "construction")
    CreateCaseSensitiveHotstrings("*", "lê★", "l’être")
    CreateCaseSensitiveHotstrings("*", "ledt★", "l’emploi du temps")
    CreateCaseSensitiveHotstrings("*", "lex★", "l’exemple")
    CreateCaseSensitiveHotstrings("*", "lim★", "limite")

    ; === M ===
    CreateCaseSensitiveHotstrings("*", "m★", "mais")
    CreateCaseSensitiveHotstrings("*", "ma★", "madame")
    CreateCaseSensitiveHotstrings("*", "maj★", "mise à jour")
    CreateCaseSensitiveHotstrings("*", "màj★", "mise à jour")
    CreateCaseSensitiveHotstrings("*", "math★", "mathématique")
    CreateCaseSensitiveHotstrings("*", "manip★", "manipulation")
    CreateCaseSensitiveHotstrings("*", "maths★", "mathématiques")
    CreateCaseSensitiveHotstrings("*", "max★", "maximum")
    CreateCaseSensitiveHotstrings("*", "md★", "milliard")
    CreateCaseSensitiveHotstrings("*", "mds★", "milliards")
    CreateCaseSensitiveHotstrings("*", "mdav★", "merci d’avance")
    CreateCaseSensitiveHotstrings("*", "mdb★", "merci de bien vouloir")
    CreateCaseSensitiveHotstrings("*", "mdl★", "modèle")
    CreateCaseSensitiveHotstrings("*", "mdp★", "mot de passe")
    CreateCaseSensitiveHotstrings("*", "mdps★", "mots de passe")
    CreateCaseSensitiveHotstrings("*", "méthodo★", "méthodologie")
    CreateCaseSensitiveHotstrings("*", "min★", "minimum")
    CreateCaseSensitiveHotstrings("*", "mio★", "million")
    CreateCaseSensitiveHotstrings("*", "mios★", "millions")
    CreateCaseSensitiveHotstrings("*", "mjo★", "mettre à jour")
    CreateCaseSensitiveHotstrings("*", "ml★", "machine learning")
    CreateCaseSensitiveHotstrings("*", "mm★", "même")
    CreateCaseSensitiveHotstrings("*", "mme★", "madame")
    CreateCaseSensitiveHotstrings("*", "modif★", "modification")
    CreateCaseSensitiveHotstrings("*", "mom★", "moi-même")
    CreateCaseSensitiveHotstrings("*", "mrc★", "merci")
    CreateCaseSensitiveHotstrings("*", "msg★", "message")
    CreateCaseSensitiveHotstrings("*", "mt★", "montant")
    CreateCaseSensitiveHotstrings("*", "mtn★", "maintenant")
    CreateCaseSensitiveHotstrings("*", "moy★", "moyenne")
    CreateCaseSensitiveHotstrings("*", "mq★", "montre que")
    CreateCaseSensitiveHotstrings("*", "mr★", "monsieur")
    CreateCaseSensitiveHotstrings("*", "mtn★", "maintenant")
    CreateCaseSensitiveHotstrings("*", "mutu★", "mutualiser")
    CreateCaseSensitiveHotstrings("*", "mvt★", "mouvement")

    ; === N ===
    CreateCaseSensitiveHotstrings("*", "n★", "nouveau")
    CreateCaseSensitiveHotstrings("*", "nav★", "navigation")
    CreateCaseSensitiveHotstrings("*", "nb★", "nombre")
    CreateCaseSensitiveHotstrings("*", "nean★", "néanmoins")
    CreateCaseSensitiveHotstrings("*", "new★", "nouveau")
    CreateCaseSensitiveHotstrings("*", "newe★", "nouvelle")
    CreateCaseSensitiveHotstrings("*", "nimp★", "n’importe")
    CreateCaseSensitiveHotstrings("*", "niv★", "niveau")
    CreateCaseSensitiveHotstrings("*", "norm★", "normalement")
    CreateCaseSensitiveHotstrings("*", "nota★", "notamment")
    CreateCaseSensitiveHotstrings("*", "notm★", "notamment")
    CreateCaseSensitiveHotstrings("*", "nouv★", "nouvelle")
    CreateCaseSensitiveHotstrings("*", "nov★", "novembre")
    CreateCaseSensitiveHotstrings("*", "now★", "maintenant")
    CreateCaseSensitiveHotstrings("*", "np★", "ne pas")
    CreateCaseSensitiveHotstrings("*", "nrj★", "énergie")
    CreateCaseSensitiveHotstrings("*", "ns★", "nous")
    CreateCaseSensitiveHotstrings("*", "num★", "numéro")

    ; === O ===
    CreateCaseSensitiveHotstrings("*", "o-★", "au moins")
    CreateCaseSensitiveHotstrings("*", "o+★", "au plus")
    CreateCaseSensitiveHotstrings("*", "obj★", "objectif")
    CreateCaseSensitiveHotstrings("*", "obs★", "observation")
    CreateCaseSensitiveHotstrings("*", "oct★", "octobre")
    CreateCaseSensitiveHotstrings("*", "odj★", "ordre du jour")
    CreateCaseSensitiveHotstrings("*", "opé★", "opération")
    CreateCaseSensitiveHotstrings("*", "oqp★", "occupé")
    CreateCaseSensitiveHotstrings("*", "ordi★", "ordinateur")
    CreateCaseSensitiveHotstrings("*", "org★", "organisation")
    CreateCaseSensitiveHotstrings("*", "orga★", "organisation")
    CreateCaseSensitiveHotstrings("*", "ortho★", "orthographe")
    CreateHotstring("*", "out★", "Où es-tu ?")
    CreateHotstring("*", "outv★", "Où êtes-vous ?")
    CreateCaseSensitiveHotstrings("*", "ouv★", "ouverture")

    ; === P ===
    CreateCaseSensitiveHotstrings("*", "p//★", "par rapport")
    CreateCaseSensitiveHotstrings("*", "par★", "paragraphe")
    CreateCaseSensitiveHotstrings("*", "param★", "paramètre")
    CreateCaseSensitiveHotstrings("*", "pb★", "problème")
    CreateCaseSensitiveHotstrings("*", "pcq★", "parce que")
    CreateCaseSensitiveHotstrings("*", "pck★", "parce que")
    CreateCaseSensitiveHotstrings("*", "pckil★", "parce qu’il")
    CreateCaseSensitiveHotstrings("*", "pcquil★", "parce qu’il")
    CreateCaseSensitiveHotstrings("*", "pcquon★", "parce qu’on")
    CreateCaseSensitiveHotstrings("*", "pckon★", "parce qu’on")
    CreateCaseSensitiveHotstrings("*", "pd★", "pendant")
    CreateCaseSensitiveHotstrings("*", "pdt★", "pendant")
    CreateCaseSensitiveHotstrings("*", "pdv★", "point de vue")
    CreateCaseSensitiveHotstrings("*", "pdvs★", "points de vue")
    CreateCaseSensitiveHotstrings("*", "perf★", "performance")
    CreateCaseSensitiveHotstrings("*", "perso★", "personne")
    CreateCaseSensitiveHotstrings("*", "pê★", "peut-être")
    CreateCaseSensitiveHotstrings("*", "péri★", "périmètre")
    CreateCaseSensitiveHotstrings("*", "périm★", "périmètre")
    CreateCaseSensitiveHotstrings("*", "peut-ê★", "peut-être")
    CreateCaseSensitiveHotstrings("*", "pex★", "par exemple")
    CreateCaseSensitiveHotstrings("*", "pf★", "portefeuille")
    CreateCaseSensitiveHotstrings("*", "pg★", "pas grave")
    CreateCaseSensitiveHotstrings("*", "pgm★", "programme")
    CreateCaseSensitiveHotstrings("*", "pi★", "pour information")
    CreateCaseSensitiveHotstrings("*", "pic★", "picture")
    CreateCaseSensitiveHotstrings("*", "pics★", "pictures")
    CreateCaseSensitiveHotstrings("*", "piè★", "pièce jointe")
    CreateCaseSensitiveHotstrings("*", "pj★", "pièce jointe")
    CreateCaseSensitiveHotstrings("*", "pjs★", "pièces jointes")
    CreateCaseSensitiveHotstrings("*", "pk★", "pourquoi")
    CreateCaseSensitiveHotstrings("*", "pls★", "please")
    CreateCaseSensitiveHotstrings("*", "poum★", "plus ou moins")
    CreateCaseSensitiveHotstrings("*", "poss★", "possible")
    CreateCaseSensitiveHotstrings("*", "pourcent★", "pourcentage")
    CreateCaseSensitiveHotstrings("*", "ppt★", "PowerPoint")
    CreateCaseSensitiveHotstrings("*", "pq★", "pourquoi")
    CreateCaseSensitiveHotstrings("*", "prd★", "produit")
    CreateCaseSensitiveHotstrings("*", "prem★", "premier")
    CreateCaseSensitiveHotstrings("*", "prez★", "présentation")
    CreateCaseSensitiveHotstrings("*", "prg★", "programme")
    CreateCaseSensitiveHotstrings("*", "pro★", "professionnel")
    CreateCaseSensitiveHotstrings("*", "prob★", "problème")
    CreateCaseSensitiveHotstrings("*", "proba★", "probabilité")
    CreateCaseSensitiveHotstrings("*", "prod★", "production")
    CreateCaseSensitiveHotstrings("*", "prof★", "professeur")
    CreateCaseSensitiveHotstrings("*", "prog★", "programme")
    CreateCaseSensitiveHotstrings("*", "prop★", "propriété")
    CreateCaseSensitiveHotstrings("*", "propo★", "proposition")
    CreateCaseSensitiveHotstrings("*", "props★", "propriétés")
    CreateCaseSensitiveHotstrings("*", "pros★", "professionnels")
    CreateCaseSensitiveHotstrings("*", "prot★", "professionnellement")
    CreateCaseSensitiveHotstrings("*", "prov★", "provision")
    CreateCaseSensitiveHotstrings("*", "psycha★", "psychanalyse")
    CreateCaseSensitiveHotstrings("*", "psycho★", "psychologie")
    CreateCaseSensitiveHotstrings("*", "psb★", "possible")
    CreateCaseSensitiveHotstrings("*", "psy★", "psychologie")
    CreateCaseSensitiveHotstrings("*", "psycho★", "psychologie")
    CreateCaseSensitiveHotstrings("*", "pt★", "point")
    CreateCaseSensitiveHotstrings("*", "ptf★", "portefeuille")
    CreateCaseSensitiveHotstrings("*", "pts★", "points")
    CreateCaseSensitiveHotstrings("*", "pub★", "publicité")
    CreateCaseSensitiveHotstrings("*", "pvv★", "pouvez-vous")
    CreateCaseSensitiveHotstrings("*", "py★", "python")

    ; === Q ===
    CreateCaseSensitiveHotstrings("*", "q★", "question")
    CreateCaseSensitiveHotstrings("*", "qc★", "qu’est-ce")
    CreateCaseSensitiveHotstrings("*", "qcq★", "qu’est-ce que")
    CreateCaseSensitiveHotstrings("*", "qcq'★", "qu’est-ce qu’")
    CreateCaseSensitiveHotstrings("*", "qq★", "quelque")
    CreateCaseSensitiveHotstrings("*", "qqch★", "quelque chose")
    CreateCaseSensitiveHotstrings("*", "qqs★", "quelques")
    CreateCaseSensitiveHotstrings("*", "qqn★", "quelqu’un")
    CreateCaseSensitiveHotstrings("*", "quasi★", "quasiment")
    CreateCaseSensitiveHotstrings("*", "ques★", "question")
    CreateCaseSensitiveHotstrings("*", "quid★", "qu’en est-il de")

    ; === R ===
    CreateCaseSensitiveHotstrings("*", "r★", "rien")
    CreateCaseSensitiveHotstrings("*", "rapidt★", "rapidement")
    CreateCaseSensitiveHotstrings("*", "rdv★", "rendez-vous")
    CreateCaseSensitiveHotstrings("*", "ré★", "réunion")
    CreateCaseSensitiveHotstrings("*", "rés★", "réunions")
    CreateCaseSensitiveHotstrings("*", "rép★", "répertoire")
    CreateCaseSensitiveHotstrings("*", "résil★", "résiliation")
    CreateCaseSensitiveHotstrings("*", "reco★", "recommandation")
    CreateCaseSensitiveHotstrings("*", "ref★", "référence")
    CreateCaseSensitiveHotstrings("*", "rep★", "répertoire")
    CreateCaseSensitiveHotstrings("*", "rex★", "retour d’expérience")
    CreateCaseSensitiveHotstrings("*", "rmq★", "remarque")
    CreateCaseSensitiveHotstrings("*", "rpz★", "représente")
    CreateCaseSensitiveHotstrings("*", "rs★", "résultat")

    ; === S ===
    CreateCaseSensitiveHotstrings("*", "seg★", "segment")
    CreateCaseSensitiveHotstrings("*", "segm★", "segment")
    CreateCaseSensitiveHotstrings("*", "sep★", "septembre")
    CreateCaseSensitiveHotstrings("*", "sept★", "septembre")
    CreateCaseSensitiveHotstrings("*", "simpl★", "simplement")
    CreateCaseSensitiveHotstrings("*", "situ★", "situation")
    CreateCaseSensitiveHotstrings("*", "smth★", "something")
    ; CreateCaseSensitiveHotstrings("*", "sol★", "solution") ; Conflict with "sollicitation"
    CreateCaseSensitiveHotstrings("*", "srx★", "sérieux")
    CreateCaseSensitiveHotstrings("*", "sécu★", "sécurité")
    CreateCaseSensitiveHotstrings("*", "st★", "s’était")
    CreateCaseSensitiveHotstrings("*", "stat★", "statistique")
    CreateCaseSensitiveHotstrings("*", "sth★", "something")
    CreateCaseSensitiveHotstrings("*", "stp★", "s’il te plaît")
    CreateCaseSensitiveHotstrings("*", "strat★", "stratégique")
    CreateCaseSensitiveHotstrings("*", "stream★", "streaming")
    CreateCaseSensitiveHotstrings("*", "suff★", "suffisant")
    CreateCaseSensitiveHotstrings("*", "sufft★", "suffisament")
    CreateCaseSensitiveHotstrings("*", "supé★", "supérieur")
    CreateCaseSensitiveHotstrings("*", "surv★", "survenance")
    CreateCaseSensitiveHotstrings("*", "svp★", "s’il vous plaît")
    CreateCaseSensitiveHotstrings("*", "svt★", "souvent")
    CreateCaseSensitiveHotstrings("*", "sya★", "s’il y a")
    CreateCaseSensitiveHotstrings("*", "syn★", "synonyme")
    CreateCaseSensitiveHotstrings("*", "sync★", "synchronisation")
    CreateCaseSensitiveHotstrings("*", "sys★", "système")

    ; === T ===
    CreateCaseSensitiveHotstrings("*", "t★", "très")
    CreateCaseSensitiveHotstrings("*", "tb★", "très bien")
    CreateCaseSensitiveHotstrings("*", "temp★", "temporaire")
    CreateCaseSensitiveHotstrings("*", "tes★", "tu es")
    CreateCaseSensitiveHotstrings("*", "tél★", "téléphone") ; "tel" can’t be used, because there would be a conflict with "tel★e que"
    CreateCaseSensitiveHotstrings("*", "teq★", "telle que")
    CreateCaseSensitiveHotstrings("*", "teqs★", "telles que")
    CreateCaseSensitiveHotstrings("*", "tfk★", "qu’est-ce que tu fais ?")
    CreateCaseSensitiveHotstrings("*", "tgh★", "together")
    CreateCaseSensitiveHotstrings("*", "théo★", "théorie")
    CreateCaseSensitiveHotstrings("*", "thm★", "théorème")
    CreateCaseSensitiveHotstrings("*", "tj★", "toujours")
    CreateCaseSensitiveHotstrings("*", "tjr★", "toujours")
    CreateCaseSensitiveHotstrings("*", "tlm★", "tout le monde")
    CreateCaseSensitiveHotstrings("*", "tq★", "tel que")
    CreateCaseSensitiveHotstrings("*", "tqs★", "tels que")
    CreateCaseSensitiveHotstrings("*", "tout★", "toutefois")
    CreateCaseSensitiveHotstrings("*", "tra★", "travail")
    CreateCaseSensitiveHotstrings("*", "trad★", "traduction")
    CreateCaseSensitiveHotstrings("*", "trav★", "travail")
    CreateCaseSensitiveHotstrings("*", "trkl★", "tranquille")
    CreateCaseSensitiveHotstrings("*", "tt★", "télétravail")
    CreateCaseSensitiveHotstrings("*", "tv★", "télévision")
    CreateCaseSensitiveHotstrings("*", "ty★", "thank you")
    CreateCaseSensitiveHotstrings("*", "typo★", "typographie")

    ; === U ===
    CreateCaseSensitiveHotstrings("*", "une amé★", "une amélioration")
    CreateCaseSensitiveHotstrings("*", "uniq★", "uniquement")
    CreateCaseSensitiveHotstrings("*", "usa★", "États-Unis")

    ; === V ===
    CreateCaseSensitiveHotstrings("*", "v★", "version")
    CreateCaseSensitiveHotstrings("*", "var★", "variable")
    CreateCaseSensitiveHotstrings("*", "vav★", "vis-à-vis")
    CreateCaseSensitiveHotstrings("*", "verif★", "vérification")
    CreateCaseSensitiveHotstrings("*", "vérif★", "vérification")
    CreateCaseSensitiveHotstrings("*", "vocab★", "vocabulaire")
    CreateCaseSensitiveHotstrings("*", "volat★", "volatilité")
    CreateCaseSensitiveHotstrings("*", "vrm★", "vraiment")
    CreateCaseSensitiveHotstrings("*", "vrmt★", "vraiment")
    CreateCaseSensitiveHotstrings("*", "vs★", "vous êtes")

    ; === W ===
    CreateCaseSensitiveHotstrings("*", "w★", "with")
    CreateCaseSensitiveHotstrings("*", "wd★", "Windows")
    CreateCaseSensitiveHotstrings("*", "wk★", "week-end")
    CreateCaseSensitiveHotstrings("*", "wknd★", "week-end")
    CreateHotstring("*", "wiki★", "Wikipédia")

    ; === X ===
    CreateCaseSensitiveHotstrings("*", "x★", "exemple")

    ; === Y ===
    CreateCaseSensitiveHotstrings("*", "ya★", "il y a")
    CreateCaseSensitiveHotstrings("*", "yapa★", "il n’y a pas")
    CreateCaseSensitiveHotstrings("*", "yc★", "y compris")
    CreateHotstring("*", "yt★", "YouTube")

    ; === Z ===
}

; ===========================
; ======= 9.4) Emojis =======
; ===========================

if Features["MagicKey"]["TextExpansionEmojis"].Enabled {
    ; === Basic smileys ===
    CreateHotstring("*", ":)★", "😀")
    CreateHotstring("*", ":))★", "😁")
    CreateHotstring("*", ":3★", "😗")
    CreateHotstring("*", ":D★", "😁")
    CreateHotstring("*", ":O★", "😮")
    CreateHotstring("*", ":P★", "😛")

    ; === Animals ===
    CreateHotstring("*", "abeille★", "🐝")
    CreateHotstring("*", "aigle★", "🦅")
    CreateHotstring("*", "araignée★", "🕷️")
    CreateHotstring("*", "baleine★", "🐋")
    CreateHotstring("*", "canard★", "🦆")
    CreateHotstring("*", "cerf★", "🦌")
    CreateHotstring("*", "chameau★", "🐪")
    CreateHotstring("*", "chat★", "🐈")
    CreateHotstring("*", "chauve-souris★", "🦇")
    CreateHotstring("*", "chèvre★", "🐐")
    CreateHotstring("*", "cheval★", "🐎")
    CreateHotstring("*", "chien★", "🐕")
    CreateHotstring("*", "cochon★", "🐖")
    CreateHotstring("*", "coq★", "🐓")
    CreateHotstring("*", "crabe★", "🦀")
    CreateHotstring("*", "croco★", "🐊")
    CreateHotstring("*", "crocodile★", "🐊")
    CreateHotstring("*", "cygne★", "🦢")
    CreateHotstring("*", "dauphin★", "🐬")
    CreateHotstring("*", "dragon★", "🐉")
    CreateHotstring("*", "écureuil★", "🐿️")
    CreateHotstring("*", "éléphant★", "🐘")
    CreateHotstring("*", "escargot★", "🐌")
    CreateHotstring("*", "flamant★", "🦩")
    CreateHotstring("*", "fourmi★", "🐜")
    CreateHotstring("*", "girafe★", "🦒")
    CreateHotstring("*", "gorille★", "🦍")
    CreateHotstring("*", "grenouille★", "🐸")
    CreateHotstring("*", "hamster★", "🐹")
    CreateHotstring("*", "hérisson★", "🦔")
    CreateHotstring("*", "hibou★", "🦉")
    CreateHotstring("*", "hippopotame★", "🦛")
    CreateHotstring("*", "homard★", "🦞")
    CreateHotstring("*", "kangourou★", "🦘")
    CreateHotstring("*", "koala★", "🐨")
    CreateHotstring("*", "lama★", "🦙")
    CreateHotstring("*", "lapin★", "🐇")
    CreateHotstring("*", "léopard★", "🐆")
    CreateHotstring("*", "licorne★", "🦄")
    CreateHotstring("*", "lion★", "🦁")
    ; CreateHotstring("*", "lit★", "🛏️") ; Conflict with "little"
    CreateHotstring("*", "loup★", "🐺")
    CreateHotstring("*", "mouton★", "🐑")
    CreateHotstring("*", "octopus★", "🐙")
    CreateHotstring("*", "ours★", "🐻")
    CreateHotstring("*", "panda★", "🐼")
    CreateHotstring("*", "papillon★", "🦋")
    CreateHotstring("*", "paresseux★", "🦥")
    CreateHotstring("*", "perroquet★", "🦜")
    CreateHotstring("*", "pingouin★", "🐧")
    CreateHotstring("*", "poisson★", "🐟")
    CreateHotstring("*", "poule★", "🐔")
    CreateHotstring("*", "poussin★", "🐣")
    ; CreateHotstring("*", "rat★", "🐀") ; Conflict with several words, like "rattrapage"
    CreateHotstring("*", "renard★", "🦊")
    CreateHotstring("*", "requin★", "🦈")
    CreateHotstring("*", "rhinocéros★", "🦏")
    CreateHotstring("*", "rhinoceros★", "🦏")
    CreateHotstring("*", "sanglier★", "🐗")
    CreateHotstring("*", "serpent★", "🐍")
    CreateHotstring("*", "singe★", "🐒")
    CreateHotstring("*", "souris★", "🐁")
    CreateHotstring("*", "tigre★", "🐅")
    CreateHotstring("*", "tortue★", "🐢")
    CreateHotstring("*", "trex★", "🦖")
    CreateHotstring("*", "vache★", "🐄")
    CreateHotstring("*", "zèbre★", "🦓")

    ; === Objects and symbols ===
    CreateHotstring("*", "aimant★", "🧲")
    CreateHotstring("*", "ampoule★", "💡")
    CreateHotstring("*", "ancre★", "⚓")
    CreateHotstring("*", "arbre★", "🌲")
    CreateHotstring("*", "argent★", "💰")
    CreateHotstring("*", "attention★", "⚠️")
    CreateHotstring("*", "avion★", "✈️")
    CreateHotstring("*", "balance★", "⚖️")
    CreateHotstring("*", "ballon★", "🎈")
    CreateHotstring("*", "batterie★", "🔋")
    CreateHotstring("*", "blanc★", "🏳️")
    CreateHotstring("*", "bombe★", "💣")
    CreateHotstring("*", "boussole★", "🧭")
    CreateHotstring("*", "bougie★", "🕯️")
    CreateHotstring("*", "cadeau★", "🎁")
    CreateHotstring("*", "cadenas★", "🔒")
    CreateHotstring("*", "calendrier★", "📅")
    CreateHotstring("*", "caméra★", "📷")
    CreateHotstring("*", "clavier★", "⌨️")
    CreateHotstring("*", "check★", "✔️")
    CreateHotstring("*", "clé★", "🔑")
    CreateHotstring("*", "cloche★", "🔔")
    CreateHotstring("*", "couronne★", "👑")
    CreateHotstring("*", "croix★", "❌")
    CreateHotstring("*", "dé★", "🎲")
    CreateHotstring("*", "diamant★", "💎")
    CreateHotstring("*", "drapeau★", "🏁")
    CreateHotstring("*", "douche★", "🛁")
    CreateHotstring("*", "éclair★", "⚡")
    CreateHotstring("*", "eau★", "💧")
    CreateHotstring("*", "email★", "📧")
    CreateHotstring("*", "épée★", "⚔️")
    CreateHotstring("*", "étoile★", "⭐")
    CreateHotstring("*", "faux★", "❌")
    CreateHotstring("*", "feu★", "🔥")
    CreateHotstring("*", "fete★", "🎉")
    CreateHotstring("*", "fête★", "🎉")
    CreateHotstring("*", "film★", "🎬")
    CreateHotstring("*", "fleur★", "🌸")
    CreateHotstring("*", "guitare★", "🎸")
    CreateHotstring("*", "idée★", "💡")
    CreateHotstring("*", "idee★", "💡")
    CreateHotstring("*", "interdit★", "⛔")
    CreateHotstring("*", "journal★", "📰")
    CreateHotstring("*", "ko★", "❌")
    CreateHotstring("*", "livre★", "📖")
    CreateHotstring("*", "loupe★", "🔎")
    CreateHotstring("*", "lune★", "🌙")
    ; CreateHotstring("*", "mail★", "📧") ; Conflict with "maillon"
    CreateHotstring("*", "médaille★", "🥇")
    CreateHotstring("*", "medaille★", "🥇")
    CreateHotstring("*", "microphone★", "🎤")
    CreateHotstring("*", "montre★", "⌚")
    CreateHotstring("*", "musique★", "🎵")
    CreateHotstring("*", "noel★", "🎄")
    CreateHotstring("*", "nuage★", "☁️")
    CreateHotstring("*", "ok★", "✔️")
    CreateHotstring("*", "olaf★", "⛄")
    CreateHotstring("*", "ordi★", "💻")
    CreateHotstring("*", "ordinateur★", "💻")
    CreateHotstring("*", "parapluie★", "☂️")
    CreateHotstring("*", "pc★", "💻")
    CreateHotstring("*", "piano★", "🎹")
    CreateHotstring("*", "pirate★", "🏴‍☠️")
    CreateHotstring("*", "pluie★", "🌧️")
    CreateHotstring("*", "radioactif★", "☢️")
    CreateHotstring("*", "regard★", "👀")
    CreateHotstring("*", "robot★", "🤖")
    CreateHotstring("*", "sacoche★", "💼")
    CreateHotstring("*", "soleil★", "☀️")
    CreateHotstring("*", "téléphone★", "📱")
    CreateHotstring("*", "terre★", "🌍")
    CreateHotstring("*", "thermomètre★", "🌡️")
    CreateHotstring("*", "timer★", "⏲️")
    CreateHotstring("*", "toilette★", "🧻")
    CreateHotstring("*", "telephone★", "☎️")
    CreateHotstring("*", "téléphone★", "☎️")
    CreateHotstring("*", "train★", "🚂")
    CreateHotstring("*", "vélo★", "🚲")
    CreateHotstring("*", "voiture★", "🚗")
    CreateHotstring("*", "yeux★", "👀")

    ; === Food ===
    CreateHotstring("*", "ananas★", "🍍")
    CreateHotstring("*", "aubergine★", "🍆")
    CreateHotstring("*", "avocat★", "🥑")
    CreateHotstring("*", "banane★", "🍌")
    CreateHotstring("*", "bière★", "🍺")
    CreateHotstring("*", "brocoli★", "🥦")
    CreateHotstring("*", "burger★", "🍔")
    CreateHotstring("*", "café★", "☕")
    CreateHotstring("*", "carotte★", "🥕")
    CreateHotstring("*", "cerise★", "🍒")
    CreateHotstring("*", "champignon★", "🍄")
    CreateHotstring("*", "chocolat★", "🍫")
    CreateHotstring("*", "citron★", "🍋")
    CreateHotstring("*", "coco★", "🥥")
    CreateHotstring("*", "cookie★", "🍪")
    CreateHotstring("*", "croissant★", "🥐")
    CreateHotstring("*", "donut★", "🍩")
    CreateHotstring("*", "fraise★", "🍓")
    CreateHotstring("*", "frites★", "🍟")
    CreateHotstring("*", "fromage★", "🧀")
    CreateHotstring("*", "gâteau★", "🎂")
    CreateHotstring("*", "glace★", "🍦")
    CreateHotstring("*", "hamburger★", "🍔")
    CreateHotstring("*", "hotdog★", "🌭")
    CreateHotstring("*", "kiwi★", "🥝")
    CreateHotstring("*", "lait★", "🥛")
    CreateHotstring("*", "maïs★", "🌽")
    CreateHotstring("*", "melon★", "🍈")
    CreateHotstring("*", "miel★", "🍯")
    CreateHotstring("*", "orange★", "🍊")
    CreateHotstring("*", "pain★", "🍞")
    CreateHotstring("*", "pastèque★", "🍉")
    CreateHotstring("*", "pates★", "🍝")
    CreateHotstring("*", "pêche★", "🍑")
    CreateHotstring("*", "pizza★", "🍕")
    CreateHotstring("*", "poire★", "🍐")
    CreateHotstring("*", "pomme★", "🍎")
    CreateHotstring("*", "popcorn★", "🍿")
    CreateHotstring("*", "raisin★", "🍇")
    CreateHotstring("*", "riz★", "🍚")
    CreateHotstring("*", "salade★", "🥗")
    CreateHotstring("*", "sandwich★", "🥪")
    CreateHotstring("*", "spaghetti★", "🍝")
    CreateHotstring("*", "taco★", "🌮")
    CreateHotstring("*", "tacos★", "🌮")
    CreateHotstring("*", "thé★", "🍵")
    CreateHotstring("*", "tomate★", "🍅")
    CreateHotstring("*", "vin★", "🍷")

    ; === Expressions and emotions ===
    CreateHotstring("*", "amour★", "🥰")
    CreateHotstring("*", "ange★", "👼")
    CreateHotstring("*", "bisou★", "😘")
    CreateHotstring("*", "bouche★", "🤭")
    CreateHotstring("*", "caca★", "💩")
    CreateHotstring("*", "clap★", "👏")
    CreateHotstring("*", "clin★", "😉")
    CreateHotstring("*", "cœur★", "❤️")
    CreateHotstring("*", "coeur★", "❤️")
    CreateHotstring("*", "colère★", "😠")
    CreateHotstring("*", "cowboy★", "🤠")
    CreateHotstring("*", "dégoût★", "🤮")
    CreateHotstring("*", "délice★", "😋")
    CreateHotstring("*", "délicieux★", "😋")
    CreateHotstring("*", "diable★", "😈")
    CreateHotstring("*", "dislike★", "👎")
    CreateHotstring("*", "dodo★", "😴")
    CreateHotstring("*", "effroi★", "😱")
    CreateHotstring("*", "facepalm★", "🤦")
    CreateHotstring("*", "fatigue★", "😩")
    CreateHotstring("*", "fier★", "😤")
    CreateHotstring("*", "fort★", "💪")
    CreateHotstring("*", "fou★", "🤪")
    CreateHotstring("*", "heureux★", "😊")
    CreateHotstring("*", "innocent★", "😇")
    CreateHotstring("*", "intello★", "🤓")
    CreateHotstring("*", "larme★", "😢")
    CreateHotstring("*", "larmes★", "😭")
    CreateHotstring("*", "like★", "👍")
    CreateHotstring("*", "lol★", "😂")
    CreateHotstring("*", "lunettes★", "🤓")
    CreateHotstring("*", "malade★", "🤒")
    CreateHotstring("*", "masque★", "😷")
    CreateHotstring("*", "mdr★", "😂")
    CreateHotstring("*", "mignon★", "🥺")
    CreateHotstring("*", "monocle★", "🧐")
    CreateHotstring("*", "mort★", "💀")
    CreateHotstring("*", "muscles★", "💪")
    CreateHotstring("*", "(n)★", "👎")
    CreateHotstring("*", "nice★", "👌")
    CreateHotstring("*", "ouf★", "😅")
    CreateHotstring("*", "oups★", "😅")
    CreateHotstring("*", "parfait★", "👌")
    CreateHotstring("*", "penser★", "🤔")
    CreateHotstring("*", "pensif★", "🤔")
    CreateHotstring("*", "peur★", "😨")
    CreateHotstring("*", "pleur★", "😭")
    CreateHotstring("*", "pleurer★", "😭")
    CreateHotstring("*", "pouce★", "👍")
    CreateHotstring("*", "rage★", "😡")
    CreateHotstring("*", "rire★", "😂")
    CreateHotstring("*", "silence★", "🤫")
    CreateHotstring("*", "snif★", "😢")
    CreateHotstring("*", "stress★", "😰")
    CreateHotstring("*", "strong★", "💪")
    CreateHotstring("*", "surprise★", "😲")
    CreateHotstring("*", "timide★", "😳")
    CreateHotstring("*", "triste★", "😢")
    CreateHotstring("*", "victoire★", "✌️")
    CreateHotstring("*", "(y)★", "👍")
    CreateHotstring("*", "zombie★", "🧟")
}

; ============================
; ======= 9.5) Symbols =======
; ============================

if Features["MagicKey"]["TextExpansionSymbols"].Enabled {
    ; === Fractions ===
    CreateHotstring("*C", "1/★", "⅟")
    CreateHotstring("*C", "1/2★", "½")
    CreateHotstring("*C", "0/3★", "↉")
    CreateHotstring("*C", "1/3★", "⅓")
    CreateHotstring("*C", "2/3★", "⅔")
    CreateHotstring("*C", "1/4★", "¼")
    CreateHotstring("*C", "3/4★", "¾")
    CreateHotstring("*C", "1/5★", "⅕")
    CreateHotstring("*C", "2/5★", "⅖")
    CreateHotstring("*C", "3/5★", "⅗")
    CreateHotstring("*C", "4/5★", "⅘")
    CreateHotstring("*C", "1/6★", "⅙")
    CreateHotstring("*C", "5/6★", "⅚")
    CreateHotstring("*C", "1/8★", "⅛")
    CreateHotstring("*C", "3/8★", "⅜")
    CreateHotstring("*C", "5/8★", "⅝")
    CreateHotstring("*C", "7/8★", "⅞")
    CreateHotstring("*C", "1/7★", "⅐")
    CreateHotstring("*C", "1/9★", "⅑")
    CreateHotstring("*C", "1/10★", "⅒")

    ; === Numbers ===
    CreateHotstring("*C", "(0)★", "🄋")
    CreateHotstring("*C", "(1)★", "➀")
    CreateHotstring("*C", "(2)★", "➁")
    CreateHotstring("*C", "(3)★", "➂")
    CreateHotstring("*C", "(4)★", "➃")
    CreateHotstring("*C", "(5)★", "➄")
    CreateHotstring("*C", "(6)★", "➅")
    CreateHotstring("*C", "(7)★", "➆")
    CreateHotstring("*C", "(8)★", "➇")
    CreateHotstring("*C", "(9)★", "➈")
    CreateHotstring("*C", "(10)★", "➉")
    CreateHotstring("*C", "(0n)★", "🄌")
    CreateHotstring("*C", "(1n)★", "➊")
    CreateHotstring("*C", "(2n)★", "➋")
    CreateHotstring("*C", "(3n)★", "➌")
    CreateHotstring("*C", "(4n)★", "➍")
    CreateHotstring("*C", "(5n)★", "➎")
    CreateHotstring("*C", "(6n)★", "➏")
    CreateHotstring("*C", "(7n)★", "➐")
    CreateHotstring("*C", "(8n)★", "➑")
    CreateHotstring("*C", "(9n)★", "➒")
    CreateHotstring("*C", "(10n)★", "➓")
    CreateHotstring("*C", "(0b)★", "𝟎") ; B for Bold
    CreateHotstring("*C", "(1b)★", "𝟏")
    CreateHotstring("*C", "(2b)★", "𝟐")
    CreateHotstring("*C", "(3b)★", "𝟑")
    CreateHotstring("*C", "(4b)★", "𝟒")
    CreateHotstring("*C", "(5b)★", "𝟓")
    CreateHotstring("*C", "(6b)★", "𝟔")
    CreateHotstring("*C", "(7b)★", "𝟕")
    CreateHotstring("*C", "(8b)★", "𝟖")
    CreateHotstring("*C", "(9b)★", "𝟗")
    CreateHotstring("*C", "(0g)★", "𝟬") ; G for Gras
    CreateHotstring("*C", "(1g)★", "𝟭")
    CreateHotstring("*C", "(2g)★", "𝟮")
    CreateHotstring("*C", "(3g)★", "𝟯")
    CreateHotstring("*C", "(4g)★", "𝟰")
    CreateHotstring("*C", "(5g)★", "𝟱")
    CreateHotstring("*C", "(6g)★", "𝟲")
    CreateHotstring("*C", "(7g)★", "𝟳")
    CreateHotstring("*C", "(8g)★", "𝟴")
    CreateHotstring("*C", "(9g)★", "𝟵")

    ; === Mathematical symbols ===
    CreateHotstring("*C", "(infini)★", "∞")
    CreateHotstring("*C", "(product)★", "∏")
    CreateHotstring("*C", "(produit)★", "∏")
    CreateHotstring("*C", "(coproduct)★", "∐")
    CreateHotstring("*C", "(coproduit)★", "∐")
    CreateHotstring("*C", "(forall)★", "∀")
    CreateHotstring("*C", "(for all)★", "∀")
    CreateHotstring("*C", "(pour tout)★", "∀")
    CreateHotstring("*C", "(exist)★", "∃")
    CreateHotstring("*C", "(exists)★", "∃")
    CreateHotstring("*C", "(vide)★", "∅")
    CreateHotstring("*C", "(ensemble vide)★", "∅")
    CreateHotstring("*C", "(void)★", "∅")
    CreateHotstring("*C", "(empty)★", "∅")
    CreateHotstring("*C", "(prop)★", "∝")
    CreateHotstring("*C", "(proportionnel)★", "∝")
    CreateHotstring("*C", "(proportionnal)★", "∝")
    CreateHotstring("*C", "(union)★", "∪")
    CreateHotstring("*C", "(intersection)★", "⋂")
    CreateHotstring("*C", "(appartient)★", "∈")
    CreateHotstring("*C", "(inclus)★", "⊂")
    CreateHotstring("*C", "(non inclus)★", "⊄")
    CreateHotstring("*C", "(non appartient)★", "∉")
    CreateHotstring("*C", "(n’appartient pas)★", "∉")
    CreateHotstring("*C", "(non)★", "¬")
    CreateHotstring("*C", "(et)★", "∧")
    CreateHotstring("*C", "(sqrt)★", "√")
    CreateHotstring("*C", "(racine)★", "√")
    CreateHotstring("*C", "(^)★", "∧")
    CreateHotstring("*C", "(v)★", "∨")
    CreateHotstring("*C", "(delta)★", "∆")
    CreateHotstring("*C", "(nabla)★", "∇")
    CreateHotstring("*C", "(<<)★", "≪")
    CreateHotstring("*C", "(partial)★", "∂")
    CreateHotstring("*C", "(end of proof)★", "∎")
    CreateHotstring("*C", "(eop)★", "∎")
    ; Integrals
    CreateHotstring("*C", "(int)★", "∫")
    CreateHotstring("*C", "(s)★", "∫")
    CreateHotstring("*C", "(so)★", "∮")
    CreateHotstring("*C", "(sso)★", "∯")
    CreateHotstring("*C", "(sss)★", "∭")
    CreateHotstring("*C", "(ssso)★", "∰")
    ; Relations
    CreateHotstring("*C", "(=)★", "≡")
    CreateHotstring("*C", "(equivalent)★", "⇔")
    CreateHotstring("*C", "(équivalent)★", "⇔")
    CreateHotstring("*C", "(implique)★", "⇒")
    CreateHotstring("*C", "(impliqué)★", "⇒")
    CreateHotstring("*C", "(imply)★", "⇒")
    CreateHotstring("*C", "(non implique)★", "⇏")
    CreateHotstring("*C", "(non impliqué)★", "⇏")
    CreateHotstring("*C", "(non équivalent)★", "⇎")
    CreateHotstring("*C", "(not equivalent)★", "⇎")

    ; === Arrows ===
    CreateHotstring("*C", ">★", "➢")
    CreateHotstring("*C", " -> ★", "➜")
    CreateHotstring("*C", "-->★", "➜")
    CreateHotstring("*C", "==>★", "⇒")
    CreateHotstring("*C", "=/=>★", "⇏")
    CreateHotstring("*C", "<==★", "⇐")
    CreateHotstring("*C", "<==>★", "⇔")
    CreateHotstring("*C", "<=/=>★", "⇎")
    CreateHotstring("*C", "<=>★", "⇔")
    CreateHotstring("*C", "^|★", "↑")
    CreateHotstring("*C", "|^★", "↓")
    CreateHotstring("*C", "->★", "→")
    CreateHotstring("*C", "<-★", "←")
    CreateHotstring("*C", "->>★", "➡")
    CreateHotstring("*C", "<<-★", "⬅")
    CreateHotstring("*C", "|->★", "↪")
    CreateHotstring("*C", "<-|★", "↩")
    CreateHotstring("*C", "^|-★", "⭮")

    ; === Checks and checkboxes ===
    CreateHotstring("*C", "(v)★", "✓")
    CreateHotstring("*C", "(x)★", "✗")
    CreateHotstring("*C", "[v]★", "☑")
    CreateHotstring("*C", "[x]★", "☒")

    ; === Miscellaneous symbols ===
    CreateHotstring("*C", "/!\★", "⚠")
    CreateHotstring("*C", "**★", "⁂")
    CreateHotstring("*C", "°C★", "℃")
    CreateHotstring("*C", "(b)★", "•")
    CreateHotstring("*C", "(c)★", "©")
    CreateHotstring("*?", "eme★", "ᵉ")
    CreateHotstring("*?", "ème★", "ᵉ")
    CreateHotstring("*?", "ieme★", "ᵉ")
    CreateHotstring("*?", "ième★", "ᵉ")
    CreateHotstring("*C", "(o)★", "•")
    CreateHotstring("*C", "(r)★", "®")
    CreateHotstring("*C", "(tm)★", "™")
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
    CreateHotstring("*C", "$grave$", "`"")
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
    CreateCaseSensitiveHotstrings("*?", "ssê", "SSU")
    CreateCaseSensitiveHotstrings("*?", "ttê", "ttu")

    ; ======= PRIORITY 3/3: Repeat last sent character =======

    ; === Letters ===
    CreateCaseSensitiveHotstrings("*?", "a★", "aa", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "b★", "bb", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "c★", "cc", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "d★", "dd", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "e★", "ee", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "é★", "éé", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "è★", "èè", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "ê★", "êê", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "f★", "ff", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "g★", "gg", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "h★", "hh", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "i★", "ii", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "j★", "jj", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "k★", "kk", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "l★", "ll", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "m★", "mm", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "n★", "nn", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "o★", "oo", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "p★", "pp", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "q★", "qq", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "r★", "rr", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "s★", "ss", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "t★", "tt", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "u★", "uu", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "v★", "vv", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "w★", "ww", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "x★", "xx", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "y★", "yy", Map("PreferTitleCase", False))
    CreateCaseSensitiveHotstrings("*?", "z★", "zz", Map("PreferTitleCase", False))

    ; === Numbers ===
    CreateHotstring("*?", "0★", "00")
    CreateHotstring("*?", "1★", "11")
    CreateHotstring("*?", "2★", "22")
    CreateHotstring("*?", "3★", "33")
    CreateHotstring("*?", "4★", "44")
    CreateHotstring("*?", "5★", "55")
    CreateHotstring("*?", "6★", "66")
    CreateHotstring("*?", "7★", "77")
    CreateHotstring("*?", "8★", "88")
    CreateHotstring("*?", "9★", "99")

    ; === Symbol pairs ===
    CreateHotstring("*?", "<★", "<<")
    CreateHotstring("*?", ">★", ">>")
    CreateHotstring("*?", "{★", "{{")
    CreateHotstring("*?", "}★", "}}")
    CreateHotstring("*?", "(★", "((")
    CreateHotstring("*?", ")★", "))")
    CreateHotstring("*?", "[★", "[[")
    CreateHotstring("*?", "]★", "]]")

    ; === Symbols ===
    CreateHotstring("*?", "-★", "--")
    CreateHotstring("*?", "_★", "__")
    CreateHotstring("*?", ":★", "::")
    CreateHotstring("*?", ";★", ";;")
    CreateHotstring("*?", "?★", "??")
    CreateHotstring("*?", "!★", "!!")
    CreateHotstring("*?", "+★", "++")
    CreateHotstring("*?", "^★", "^^")
    CreateHotstring("*?", "#★", "##")
    CreateHotstring("*?", "``★", "````")
    CreateHotstring("*?", "=★", "==")
    CreateHotstring("*?", "/★", "//")
    CreateHotstring("*?", "\★", "\\")
    CreateHotstring("*?", "|★", "||")
    CreateHotstring("*?", "&★", "&&")
    CreateHotstring("*?", "$★", "$$")
    CreateHotstring("*?", "@★", "@@")
    CreateHotstring("*?", "~★", "~~")
    CreateHotstring("*?", "*★", "**")
}
