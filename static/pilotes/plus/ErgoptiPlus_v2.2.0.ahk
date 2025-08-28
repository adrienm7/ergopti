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
            return true
        }
    }
    return false
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
; ErgoptiBase=0
; [TapHolds]
; AltGr=1

global Features := Map(
    "Layout", Map(
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
    ),
    "MagicKey", Map(
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
            Description: "Taper un symbole quand du texte est sélectionné encadre le texte par celui-ci. Ne fonctionne que si UIA/Lib/UIA.ahk est dans le dossier du script",
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
        "AltGrLAltGivesCtrlBackSpace", {
            Enabled: True,
            Description: "`"AltGr`" + `"LAlt`" = Ctrl + BackSpace",
        },
        "AltGrLAltGivesCtrlDelete", {
            Enabled: False,
            Description: "`"AltGr`" + `"LAlt`" = Ctrl + Delete",
        },
        "AltGrLAltGivesOneShotShift", {
            Enabled: False,
            Description: "`"AltGr`" + `"LAlt`" = OneShotShift",
        },
        "AltGrLAltGivesCapsWord", {
            Enabled: False,
            Description: "`"AltGr`" + `"LAlt`" = CapsWord",
        },
        "AltGrCapsLockGivesCtrlDelete", {
            Enabled: True,
            Description: "`"AltGr`" + `"CapsLock`" = Ctrl + Delete",
        },
        "AltGrCapsLockGivesCtrlBackSpace", {
            Enabled: False,
            Description: "`"AltGr`" + `"CapsLock`" = Ctrl + BackSpace",
        },
        "AltGrCapsLockGivesCapsWord", {
            Enabled: False,
            Description: "`"AltGr`" + `"CapsLock`" = CapsWord",
        },
        "AltGrCapsLockGivesCapsLock", {
            Enabled: False,
            Description: "`"AltGr`" + `"CapsLock`" = CapsLock",
        },
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
        "CapsLockEnterCtrl", {
            Enabled: True,
            Description: "`"CapsLock`" : Enter en tap, Ctrl en hold. CapsLock en Win + `"CapsLock`"",
            TimeActivationSeconds: 0.2,
        },
        "CapsLockBackSpace", {
            Enabled: False,
            Description: "`"CapsLock`" : BackSpace. CapsLock en Win + `"CapsLock`"",
        },
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
        "LAltOneShotShift", {
            Enabled: True,
            Description: "`"LAlt`" : OneShotShift en tap, Shift en hold",
        },
        "LAltAltTabMonitor", {
            Enabled: False,
            Description: "`"LAlt`" : Alt+Tab sur le moniteur en tap, Alt en hold",
            TimeActivationSeconds: 0.2,
        },
        "LAltTabLayer", {
            Enabled: False,
            Description: "`"LAlt`" : Tab en tap, layer de navigation en hold",
            TimeActivationSeconds: 0.2,
        },
        "LAltBackSpace", {
            Enabled: False,
            Description: "`"LAlt`" : BackSpace. Shift + `"LAlt`" = Delete",
        },
        "LAltBackSpaceLayer", {
            Enabled: False,
            Description: "`"LAlt`" : BackSpace en tap, layer de navigation en hold. Shift + `"LAlt`" = Delete",
            TimeActivationSeconds: 0.2,
        },
        "SpaceLayer", {
            Enabled: True,
            Description: "`"Espace`" : Espace en tap, layer de navigation en hold",
            TimeActivationSeconds: 0.15,
        },
        "SpaceCtrl", {
            Enabled: False,
            Description: "`"Espace`" : Espace en tap, Ctrl en hold",
            TimeActivationSeconds: 0.15,
        },
        "AltGrTab", {
            Enabled: True,
            Description: "`"AltGr`" : Tab en tap, AltGr en hold",
            TimeActivationSeconds: 0.2,
        },
        "AltGrOneShotShift", {
            Enabled: False,
            Description: "`"AltGr`" : OneShotShift en tap, AltGr en hold",
            TimeActivationSeconds: 0.2,
        },
        "RCtrlBackSpace", {
            Enabled: True,
            Description: "`"RCtrl`" : BackSpace. Shift + `"RCtrl`" = Delete"
        },
        "RCtrlTab", {
            Enabled: False,
            Description: "`"RCtrl`" : Tab en tap, Ctrl en hold",
            TimeActivationSeconds: 0.2,
        },
        "RCtrlOneShotShift", {
            Enabled: False,
            Description: "`"RCtrl`" : OneShotShift en tap, Shift en hold",
        },
        "TabAlt", {
            Enabled: True,
            Description: "`"Tab`" : Alt-Tab sur le moniteur en tap, Alt en hold. À activer si `"LAlt`" est remplacé par un autre raccourci pour ne pas perdre Alt",
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
    ; "_" = value if the key is not found in the ini file
    for Category in Features {
        for Feature in Features[Category] {
            RawValueEnabled := IniRead(ConfigurationFile, Category, Feature, "_")
            if RawValueEnabled != "_" {
                Features[Category][Feature].Enabled := (RawValueEnabled != "0")
            }

            RawValueTimeActivationSeconds := IniRead(ConfigurationFile, Category, Feature . "TimeActivationSeconds",
                "_")
            if RawValueTimeActivationSeconds != "_" {
                Features[Category][Feature].TimeActivationSeconds := RawValueTimeActivationSeconds
            }
        }
    }

    Value := IniRead(ConfigurationFile, "MagicKey", "TextExpansionPersonalInformationPatternMaxLength", "_")
    if Value != "_" {
        Features["MagicKey"]["TextExpansionPersonalInformationPatternMaxLength"].PatternMaxLength := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "EGraveLetter", "_")
    if Value != "_" {
        Features["Shortcuts"]["EGrave"].Letter := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "ECircLetter", "_")
    if Value != "_" {
        Features["Shortcuts"]["ECirc"].Letter := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "EAcuteLetter", "_")
    if Value != "_" {
        Features["Shortcuts"]["EAcute"].Letter := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "AGraveLetter", "_")
    if Value != "_" {
        Features["Shortcuts"]["AGrave"].Letter := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "GPTLink", "_")
    if Value != "_" {
        Features["Shortcuts"]["GPT"].Link := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "TakeNoteDatedNotes", "_")
    if Value != "_" {
        Features["Shortcuts"]["TakeNote"].DatedNotes := Value
    }

    Value := IniRead(ConfigurationFile, "Shortcuts", "TakeNoteDestinationFolder", "_")
    if Value != "_" {
        Features["Shortcuts"]["TakeNote"].DestinationFolder := Value
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

MenuAddItem(Menu, FeatureCategory, FeatureName) {
    MenuTitle := GetMenuTitle(FeatureCategory, FeatureName)
    Menu.Add(MenuTitle, (*) => ToggleMenuVariable(Menu, FeatureCategory, FeatureName))
}

GetMenuTitle(FeatureCategory, FeatureName) {
    MenuTitle := Features[FeatureCategory][FeatureName].Description
    if FeatureCategory == "Shortcuts" and Features[FeatureCategory][FeatureName].HasOwnProp("Letter") {
        MenuTitle := MenuTitle StrUpper(Features[FeatureCategory][FeatureName].Letter)
    }
    return MenuTitle
}

ToggleMenuVariable(Menu, FeatureCategory, FeatureName) {
    global Features, ConfigurationFile
    Features[FeatureCategory][FeatureName].Enabled := not Features[FeatureCategory][FeatureName].Enabled ; Toggle the global variable value
    FeatureValue := Features[FeatureCategory][FeatureName].Enabled

    ; Update the configuration file with the new value
    IniWrite(FeatureValue, ConfigurationFile, FeatureCategory, FeatureName)
    Reload
}

MenuItemCheckmarkUpdate(Menu, FeatureCategory, FeatureName, FeatureValue) {
    global Features
    MenuTitle := GetMenuTitle(FeatureCategory, FeatureName)
    if FeatureValue {
        Menu.Check(MenuTitle)
    } else {
        Menu.Uncheck(MenuTitle)
    }
}

SubmenuUpdate(FeatureCategory) {
    if FeatureCategory == "Layout" {
        ; No submenu for the layout category
        return
    }

    MenuTitle := %"Menu" FeatureCategory%
    AreEveryFeaturesEnabled := True
    global Features
    for FeatureName in Features[FeatureCategory] {
        FeatureEnabled := Features[FeatureCategory][FeatureName].Enabled
        if not FeatureEnabled {
            AreEveryFeaturesEnabled := False
            break
        }
    }

    if AreEveryFeaturesEnabled {
        A_TrayMenu.Check(MenuTitle)
    } else {
        A_TrayMenu.Uncheck(MenuTitle)
    }
}

MenuItemUpdate(Menu, FeatureCategory, FeatureName) {
    global Features
    FeatureValue := Features[FeatureCategory][FeatureName].Enabled
    MenuItemCheckmarkUpdate(Menu, FeatureCategory, FeatureName, FeatureValue)
}

MenuStructure := Map(
    "Layout", [
        "ErgoptiBase",
        "DirectAccessDigits",
        "ErgoptiAltGr",
        "ErgoptiPlus",
    ],
    "DistancesReduction", [
        "SuffixesA",
        "QU",
        "DeadKeyECircumflex",
        "CommaJ",
        "CommaFarLetters",
        "SpaceAroundSymbols",
    ],
    "SFBsReduction", [
        "Comma",
        "ECirc",
        "EGrave",
    ],
    "Rolls", [
        "HC",
        "SX",
        "CX",
        "EnglishNegation",
        "EZ",
        "CT",
        "-",
        "CloseChevronTag",
        "ChevronEqual",
        "Assign",
        "NotEqual",
        "HashtagQuote",
        "HashtagParenthesis",
        "HashtagBracket",
        "EqualString",
        "Comment",
        "AssignArrowEqualRight",
        "AssignArrowEqualLeft",
        "AssignArrowMinusRight",
        "AssignArrowMinusLeft",
    ],
    "Autocorrection", [
        "TypographicApostrophe",
        "-",
        "Errors",
        "OU",
        "SuffixesAChaining",
        "-",
        "Minus",
        "-",
        "Brands",
        "Names",
        "Accents",
    ],
    "MagicKey", [
        "Replace",
        "Repeat",
        "-",
        "TextExpansionPersonalInformation",
        "TextExpansion",
        "TextExpansionEmojis",
        "TextExpansionSymbols",
        "TextExpansionSymbolsTypst",
    ],
    "Shortcuts", [
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
        "-",
        "AltGrLAltGivesCtrlBackSpace",
        "AltGrLAltGivesCtrlDelete",
        "AltGrLAltGivesOneShotShift",
        "AltGrLAltGivesCapsWord",
        "-",
        "AltGrCapsLockGivesCtrlDelete",
        "AltGrCapsLockGivesCtrlBackSpace",
        "AltGrCapsLockGivesCapsWord",
        "AltGrCapsLockGivesCapsLock",
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
        "SelectWord",
    ],
    "TapHolds", [
        "CapsLockEnterCtrl",
        "CapsLockBackSpace",
        "-",
        "LShiftCopy",
        "LCtrlPaste",
        "-",
        "LAltOneShotShift",
        "LAltTabLayer",
        "LAltAltTabMonitor",
        "LAltBackSpace",
        "LAltBackSpaceLayer",
        "-",
        "SpaceLayer",
        "SpaceCtrl",
        "-",
        "AltGrTab",
        "AltGrOneShotShift",
        "-",
        "RCtrlBackSpace",
        "RCtrlTab",
        "RCtrlOneShotShift",
        "-",
        "TabAlt",
    ]
)

CreateSubMenus(MenuStructure) {
    Menus := Map()
    for Category, Items in MenuStructure {
        if (Category == "Layout") {
            continue
        }
        SubMenu := Menu()
        for Item in Items {
            if (Item == "-") {
                SubMenu.Add() ; Separating line
            }
            else {
                MenuAddItem(SubMenu, Category, Item)
            }
        }
        Menus[Category] := SubMenu
    }
    return Menus
}
global SubMenus := CreateSubMenus(MenuStructure)

; We use variables for repeating text
; Indeed, an element of the menu is referenced by the text it contains
MenuLayout := "Modification de la disposition clavier"
MenuAllFeatures := "Features Ergopti➕"
MenuDistancesReduction := "➀ Réduction des distances"
MenuSFBsReduction := "➁ Réduction des SFBs"
MenuRolls := "➂ Roulements"
MenuAutocorrection := "➃ Autocorrection"
MenuMagicKey := "➄ Touche ★"
MenuShortcuts := "➅ Raccourcis"
MenuTapHolds := "➆ Tap-Holds"
MenuScriptManagement := "Gestion du script"
MenuSuspend := "⏸︎ Suspendre"
MenuDebugging := "⚠ Débogage"

; Menu that will be shown and contain all tho other menus
initMenu() {
    global MenuStructure, SubMenus, A_TrayMenu
    A_TrayMenu.Delete() ; Remove all items of the default menu

    A_TrayMenu.Add(MenuLayout, NoAction)
    A_TrayMenu.Disable(MenuLayout)
    for Item in MenuStructure["Layout"] {
        MenuAddItem(A_TrayMenu, "Layout", Item)
    }

    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuAllFeatures, NoAction)
    A_TrayMenu.Disable(MenuAllFeatures)
    A_TrayMenu.Add(MenuDistancesReduction, SubMenus["DistancesReduction"])
    A_TrayMenu.Add(MenuSFBsReduction, SubMenus["SFBsReduction"])
    A_TrayMenu.Add(MenuRolls, SubMenus["Rolls"])
    A_TrayMenu.Add(MenuAutocorrection, SubMenus["Autocorrection"])
    A_TrayMenu.Add(MenuMagicKey, SubMenus["MagicKey"])
    A_TrayMenu.Add(MenuShortcuts, SubMenus["Shortcuts"])
    A_TrayMenu.Add(MenuTapHolds, SubMenus["TapHolds"])

    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add("✔️ TOUT activer", ToggleAllFeaturesOn)
    A_TrayMenu.Add("❌ TOUT désactiver", ToggleAllFeaturesOff)
    A_TrayMenu.Add("Modifier les coordonnées personnelles", PersonalInformationEditor)
    A_TrayMenu.Add("Modifier les raccourcis sur les lettres accentuées", ShortcutsEditor)
    A_TrayMenu.Add("Modifier le lien ouvert par Win + G", GPTLinkEditor)

    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuScriptManagement, NoAction)
    A_TrayMenu.Disable(MenuScriptManagement)
    A_TrayMenu.Add("✎ Éditer", ActivateEdit)
    A_TrayMenu.Add(MenuSuspend, ToggleSuspend)
    A_TrayMenu.Add("🔄 Recharger", ActivateReload)
    A_TrayMenu.Add("⏹ Quitter", ActivateExitApp)

    A_TrayMenu.Add() ; Separating line
    A_TrayMenu.Add(MenuDebugging, NoAction)
    A_TrayMenu.Disable(MenuDebugging)
    A_TrayMenu.Add("Window Spy", WindowSpy)
    A_TrayMenu.Add("État des variables", ActivateListVars)
    A_TrayMenu.Add("Historique des touches", ActivateKeyHistory)
}
initMenu()
UpdateTrayIcon()

MenuItemUpdateAll() {
    global MenuStructure, SubMenus, A_TrayMenu
    for Category, Items in MenuStructure {
        SubmenuUpdate(Category)
        CurrentMenu := (Category == "Layout") ? A_TrayMenu : SubMenus[Category]
        for Item in Items {
            if (Item != "-") {
                MenuItemUpdate(CurrentMenu, Category, Item)
            }
        }
    }
}
MenuItemUpdateAll()

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
            changed[key] := true
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

    GuiToShow.Add("Button", "w100 Center", "OK").OnEvent("Click", (*) => ModifyValues(GuiToShow, NewEGraveValue.Text,
        NewECircValue.Text, NewEAcuteValue.Text, NewAGraveValue.Text))
    GuiToShow.Show("Center")
}
ModifyValues(gui, NewEGraveValue, NewECircValue, NewEAcuteValue, NewAGraveValue) {
    Features["Shortcuts"]["EGrave"].Letter := NewEGraveValue
    IniWrite(NewEGraveValue, ConfigurationFile, "Shortcuts", "EGraveLetter")

    Features["Shortcuts"]["ECirc"].Letter := NewECircValue
    IniWrite(NewECircValue, ConfigurationFile, "Shortcuts", "ECircLetter")

    Features["Shortcuts"]["EAcute"].Letter := NewEAcuteValue
    IniWrite(NewEAcuteValue, ConfigurationFile, "Shortcuts", "EAcuteLetter")

    Features["Shortcuts"]["AGrave"].Letter := NewAGraveValue
    IniWrite(NewAGraveValue, ConfigurationFile, "Shortcuts", "AGraveLetter")

    gui.Destroy()
}

GPTLinkEditor(*) {
    GuiToShow := Gui(, "Modifier le lien ouvert par Win + G")
    NewValue := GuiToShow.Add("Edit", "w300", Features["Shortcuts"]["GPT"].Link)

    GuiToShow.Add("Button", "w100 Center", "OK").OnEvent("Click", (*) => ModifyLink(GuiToShow, NewValue.Text))
    GuiToShow.Show("Center")
}
ModifyLink(gui, NewValue) {
    Features["Shortcuts"]["GPT"].Link := NewValue
    IniWrite(NewValue, ConfigurationFile, "Shortcuts", "GPTLink")
    gui.Destroy()
}

NoAction(*) {
}

ToggleAllFeaturesOn(*) {
    MsgBox(
        "⚠ ATTENTION : Toutes les fonctionnalités ont été activées. Cela inclut les différents raccourcis que l’on peut choisir d’avoir sur la même combinaison de touches. Par défaut, le premier raccourci actif d’une combinaison de touches sera celui utilisé, les autres raccourcis actifs sur cette même combinaison n’auront pas d’effet. Après cette opération, il est cependant très fortement recommandé de DÉSACTIVER MANUELLEMENT LES RACCOURCIS EN CONFLIT pour éviter de futurs potentiels problèmes."
    )
    ToggleAllFeatures(1)
}
ToggleAllFeaturesOff(*) {
    ToggleAllFeatures(0)
}
ToggleAllFeatures(Value) {
    global Features
    for FeatureCategory in Features {
        for FeatureName in Features[FeatureCategory] {
            Features[FeatureCategory][FeatureName].Enabled := Value
            IniWrite(Value, ConfigurationFile, FeatureCategory, FeatureName)
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
            TraySetIcon(ScriptInformation["IconPathDisabled"], , true)
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

global DeadkeyMappingCircumflex := Map(
    "a", "â", "A", "Â",
    "à", "œ", "À", "Œ",
    "b", "⚐", "B", "⚑",
    "c", "©", "C", "©",
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
    "r", "®", "R", "®",
    "s", "ß", "S", "ẞ",
    "t", "™", "T", "™",
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
    "e", "ë", "E", "Ë",
    "h", "ḧ", "H", "Ḧ",
    "i", "ï", "I", "Ï",
    "o", "ö", "O", "Ö",
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

; =========================
; ======= 3.1) Base =======
; =========================

#HotIf Features["Layout"]["DirectAccessDigits"].Enabled
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
#HotIf

#HotIf Features["Layout"]["ErgoptiBase"].Enabled
~SC039:: {
    UpdateLastSentCharacter(" ")
}

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
#HotIf

if Features["MagicKey"]["Replace"].Enabled {
    RemapKey("SC02E", "j", "★")
}

; ==========================
; ======= 3.2) Shift =======
; ==========================

#HotIf Features["Layout"]["ErgoptiBase"].Enabled
; === Space bar ===
+SC039:: WrapTextIfSelected("-", "-", "-")

; === Number row ===
+SC029:: SendNewResult("+")
+SC002:: SendNewResult("1")
+SC003:: SendNewResult("2")
+SC004:: SendNewResult("3")
+SC005:: SendNewResult("3")
+SC006:: SendNewResult("5")
+SC007:: SendNewResult("6")
+SC008:: SendNewResult("7")
+SC009:: SendNewResult("8")
+SC00A:: SendNewResult("9")
+SC00B:: SendNewResult("º")
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
#HotIf

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
SC138 & SC029:: RemapAltGr((*) => SendNewResult("}"), (*) => SendNewResult("⁰"))
SC138 & SC002:: RemapAltGr((*) => SendNewResult("1"), (*) => SendNewResult("¹"))
SC138 & SC003:: RemapAltGr((*) => SendNewResult("2"), (*) => SendNewResult("²"))
SC138 & SC004:: RemapAltGr((*) => SendNewResult("3"), (*) => SendNewResult("³"))
SC138 & SC005:: RemapAltGr((*) => SendNewResult("4"), (*) => SendNewResult("⁴"))
SC138 & SC006:: RemapAltGr((*) => SendNewResult("5"), (*) => SendNewResult("⁵"))
SC138 & SC007:: RemapAltGr((*) => SendNewResult("6"), (*) => SendNewResult("⁶"))
SC138 & SC008:: RemapAltGr((*) => SendNewResult("7"), (*) => SendNewResult("⁷"))
SC138 & SC009:: RemapAltGr((*) => SendNewResult("8"), (*) => SendNewResult("⁸"))
SC138 & SC00A:: RemapAltGr((*) => SendNewResult("9"), (*) => SendNewResult("⁹"))
SC138 & SC00B:: RemapAltGr((*) => SendNewResult("°"), (*) => SendNewResult("ª"))
SC138 & SC00C:: RemapAltGr((*) => SendNewResult("‰"), (*) => SendNewResult("‱"))
SC138 & SC00D:: RemapAltGr((*) => SendNewResult("€"), (*) => SendNewResult("£"))

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
    (*) => SendNewResult("€")
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
^SC02F:: SendFinalResult("^v") ; Correct issue where Win + V paste does't work
^SC00C:: SendFinalResult("^{NumpadSub}") ; Zoom out with Ctrl + %
^SC00D:: SendFinalResult("^{NumpadAdd}") ; Zoom in with Ctrl + $
#HotIf

; In Microsoft apps like Word or Excel, we can’t use Numpad + to zoom
#HotIf Features["Layout"]["ErgoptiBase"].Enabled and MicrosoftApps()
^SC00C:: SendFinalResult("^{WheelDown}") ; Zoom out with Ctrl + %
^SC00D:: SendFinalResult("^{WheelUp}") ; Zoom in with Ctrl + $
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
    and not Features["TapHolds"]["LAltOneShotShift"].Enabled
    and not Features["TapHolds"]["LAltBackSpace"].Enabled ; No need to add the shortcut here, as it is impossible with a BackSpace key that fires immediately
    and not Features["TapHolds"]["LAltBackSpaceLayer"].Enabled ; Here we directly change the result on the layer
    and not Features["TapHolds"]["LAltTabLayer"].Enabled ; Here we directly change the result on the layer
)
SC038 & SC03A:: ToggleCapsWordState()
#HotIf

; This function fixes Features["Shortcuts"]["LAltCapsLockGivesCapsWord"] when used with Features["TapHolds"]["LAltOneShotShift"]
; It needs to be used in every remapping of the "CapsLock" key, or the "CapsLock" key itself if no remapping is done
CapsWordShortcutFix() {
    if (
        Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled
        and Features["TapHolds"]["LAltOneShotShift"].Enabled
        and GetKeyState("SC038", "P")
    ) {
        ToggleCapsWordState()
        return
    }
}

; When no remapping of the "CapsLock" key is done, add the fix
#HotIf (
    Features["Shortcuts"]["LAltCapsLockGivesCapsWord"].Enabled
    and Features["TapHolds"]["LAltOneShotShift"].Enabled
    and not Features["TapHolds"]["CapsLockEnterCtrl"].Enabled and not LayerEnabled
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

#HotIf Features["Shortcuts"]["AltGrLAltGivesCtrlBackSpace"].Enabled
; "AltGr" + "LAlt" = Ctrl + BackSpace
SC138 & SC038:: {
    OneShotShiftFix()
    SendInput("^{BackSpace}")
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrLAltGivesCtrlDelete"].Enabled
; "AltGr" + "LAlt" = Ctrl + Delete
SC138 & SC038:: {
    OneShotShiftFix()
    SendInput("^{Delete}")
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrLAltGivesOneShotShift"].Enabled
; "AltGr" + "LAlt" = OneShotShift
SC138 & SC038:: {
    global OneShotShiftEnabled := True
    OneShotShift()
}
#HotIf
#HotIf Features["Shortcuts"]["AltGrLAltGivesCapsWord"].Enabled
; "AltGr" + "LAlt" = CapsWord
SC138 & SC038:: {
    ToggleCapsWordState()
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLockGivesCtrlDelete"].Enabled
; "AltGr" + "CapsLock" = Ctrl + Delete
SC138 & SC03A:: {
    SendInput("^{Delete}")
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLockGivesCtrlBackSpace"].Enabled
; "AltGr" + "CapsLock" = Ctrl + BackSpace
SC138 & SC03A:: {
    SendInput("^{BackSpace}")
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLockGivesCapsWord"].Enabled
; "AltGr" + "CapsLock" = CapsWord
SC138 & SC03A:: {
    ToggleCapsWordState()
}
#HotIf

#HotIf Features["Shortcuts"]["AltGrCapsLockGivesCapsLock"].Enabled
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

#HotIf Features["TapHolds"]["CapsLockEnterCtrl"].Enabled and not LayerEnabled
*SC03A::Enter
; Tap-hold on "CapsLock" : Enter on tap, Ctrl on hold
$SC03A::
{
    CapsWordShortcutFix()
    SendEvent("{LControl Down}") ; It is necessary to send an event to then get it in A_PriorKey
    tap := KeyWait("CapsLock", "T" . Features["TapHolds"]["CapsLockEnterCtrl"].TimeActivationSeconds)
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

#HotIf Features["TapHolds"]["CapsLockBackSpace"].Enabled
SC03A::BackSpace
#HotIf

#HotIf Features["TapHolds"]["CapsLockEnterCtrl"].Enabled or Features["TapHolds"]["CapsLockBackSpace"].Enabled
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

#HotIf Features["TapHolds"]["LAltOneShotShift"].Enabled and not LayerEnabled
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

#HotIf Features["TapHolds"]["LAltTabLayer"].Enabled and not LayerEnabled
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
    tap := (Now - CharacterSentTime <= Features["TapHolds"]["LAltTabLayer"].TimeActivationSeconds * 1000)
    if tap {
        SendEvent("{Tab}")
    }
}

SC02A & SC038:: SendInput("+{Tab}") ; On "LShift"
if Features["TapHolds"]["RCtrlOneShotShift"].Enabled {
    SC11D & SC038:: {
        OneShotShiftFix()
        SendInput("+{Tab}")
    }
}
#SC038:: SendEvent("#{Tab}") ; Doesn’t fire when SendInput is used
!SC038:: SendInput("!{Tab}")
#HotIf

#HotIf Features["TapHolds"]["LAltAltTabMonitor"].Enabled and not LayerEnabled
; Tap-hold on "LAlt" : AltTabMonitor on tap, Alt on hold
SC038::
{
    Send("{LAlt Down}")
    tap := KeyWait("SC038", "T" . Features["TapHolds"]["LAltAltTabMonitor"].TimeActivationSeconds)
    if tap {
        Send("{LAlt Up}")
        AltTabMonitor()
    } else {
        KeyWait("SC038")
        Send("{LAlt Up}")
    }
}
#HotIf

#HotIf Features["TapHolds"]["LAltBackSpace"].Enabled and not LayerEnabled
; "LAlt" becomes BackSpace, and Delete on Shift
*SC038::
{
    if GetKeyState("SC02A", "P") { ; LShift
        SendInput("{Delete}")
    } else if Features["TapHolds"]["RCtrlOneShotShift"].Enabled and GetKeyState("SC11D", "P") {
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
    } else {
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        Sleep(300) ; Delay before repeating the key
        while GetKeyState("SC038", "P") {
            SendEvent("{BackSpace}")
            Sleep(70)
        }
    }
}
#HotIf

#HotIf Features["TapHolds"]["LAltBackSpaceLayer"].Enabled and not LayerEnabled
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
    tap := (Now - CharacterSentTime <= Features["TapHolds"]["LAltBackSpaceLayer"].TimeActivationSeconds * 1000)

    if (
        tap
        and A_PriorKey == "LAlt" ; Prevents triggering BackSpace when the layer is quickly used and then released
        and not GetKeyState("SC03A", "P") ; Fix a sent BackSpace when triggering quickly "LAlt" + "CapsLock"
    ) {
        if GetKeyState("SC02A", "P") { ; LShift
            SendInput("{Delete}")
        } else if Features["TapHolds"]["RCtrlOneShotShift"].Enabled and GetKeyState("SC11D", "P") {
            OneShotShiftFix()
            SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
        } else {
            SendEvent("{BackSpace}")
        }
    }
}
#HotIf

; ==========================
; ======= 5.4) Space =======
; ==========================

#HotIf Features["TapHolds"]["SpaceLayer"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Layer on hold
SC039::
{
    ih := InputHook("L1 T" . Features["TapHolds"]["SpaceLayer"].TimeActivationSeconds)
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
        and A_TimeSinceThisHotkey <= Features["TapHolds"]["SpaceLayer"].TimeActivationSeconds
    ) {
        SendEvent("{Space}")
        UpdateLastSentCharacter(" ")
    }
}
#HotIf

#HotIf Features["TapHolds"]["SpaceCtrl"].Enabled and not LayerEnabled
; Tap-hold on "Space" : Space on tap, Ctrl on hold
SC039::
{
    ih := InputHook("L1 T" . Features["TapHolds"]["SpaceCtrl"].TimeActivationSeconds)
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
        and A_TimeSinceThisHotkey <= Features["TapHolds"]["SpaceCtrl"].TimeActivationSeconds
    ) {
        SendEvent("{Space}")
    }
}
#HotIf

; ==========================
; ======= 5.5) AltGr =======
; ==========================

#HotIf Features["TapHolds"]["AltGrTab"].Enabled and not LayerEnabled
RAlt::Tab
; Tap-hold on "AltGr" : Tab on tap, AltGr on hold
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . Features["TapHolds"]["AltGrTab"].TimeActivationSeconds)
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

#HotIf Features["TapHolds"]["AltGrOneShotShift"].Enabled and not LayerEnabled
; Tap-hold on "AltGr" : OneShotShift on tap, AltGr on hold
SC01D & ~SC138:: ; LControl & RAlt is the only way to make it fire on tap directly
RAlt:: ; Necessary to work on layouts like QWERTY
{
    tap := KeyWait("RAlt", "T" . Features["TapHolds"]["AltGrOneShotShift"].TimeActivationSeconds)
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

#HotIf Features["TapHolds"]["RCtrlBackSpace"].Enabled and not LayerEnabled
; RCtrl becomes BackSpace, and Delete on Shift
SC11D::
{
    if GetKeyState("LShift", "P") {
        SendInput("{Delete}")
    } else if Features["TapHolds"]["LAltOneShotShift"].Enabled and GetKeyState("SC038", "P") {
        OneShotShiftFix()
        SendInput("{Right}{BackSpace}") ; = Delete, but we cannot simply use Delete, as it would do Ctrl + Alt + Delete and Windows would interpret it
    } else {
        SendEvent("{BackSpace}") ; Event to be able to correct hostrings and still trigger them afterwards
        tap := KeyWait("SC11D", "T" . Features["TapHolds"]["RCtrlBackSpace"].TimeActivationSeconds)
        if not tap {
            while GetKeyState("SC11D", "P") {
                SendEvent("{BackSpace}")
                Sleep(100)
            }
        }
    }
}
#HotIf

#HotIf Features["TapHolds"]["RCtrlTab"].Enabled and not LayerEnabled
; Tap-hold on "RCtrl" : Tab on tap, Ctrl on hold
~SC11D:: {
    tap := KeyWait("RControl", "T" . Features["TapHolds"]["RCtrlTab"].TimeActivationSeconds)
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

#HotIf Features["TapHolds"]["RCtrlOneShotShift"].Enabled and not LayerEnabled
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
        if Features["TapHolds"]["LAltTabLayer"].Enabled and GetKeyState("SC038", "P") {
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
        Features["TapHolds"]["LAltBackSpaceLayer"].Enabled
        or Features["TapHolds"]["LAltTabLayer"].Enabled
    )
)
SC03A:: ToggleCapsWordState() ; Overrides the "BackSpace" shortcut on the layer
#HotIf

; Fix when Space triggers the layer
#HotIf (
    Features["TapHolds"]["SpaceLayer"].Enabled
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

#HotIf Features["DistancesReduction"]["DeadKeyECircumflex"].Enabled
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

; The "Ê" key will enable to use the other symbols on the layer if we aren’t inside a word
DeadkeyMappingCircumflexModified := DeadkeyMappingCircumflex.Clone()
DeadkeyMappingCircumflexModified.Delete(" ")

if Features["SFBsReduction"]["ECirc"].Enabled {
    DeadkeyMappingCircumflexModified.Delete("é")
    DeadkeyMappingCircumflexModified.Delete("e")
    DeadkeyMappingCircumflexModified.Delete(",")
    DeadkeyMappingCircumflexModified.Delete(".")
}

; Fix the only word starting with "ê": "être"
CreateCaseSensitiveHotstrings(
    "*?", "êt", "êt",
    Map("TimeActivationSeconds", Features["DistancesReduction"]["DeadKeyECircumflex"].TimeActivationSeconds
    )
)

for MapKey, MappedValue in DeadkeyMappingCircumflexModified {
    doHotstring(MapKey, MappedValue)
}

doHotstring(MapKey, MappedValue) {
    Combination := "ê" . MapKey
    Hotstring(
        ":*CB0:" . Combination,
        (*) => deadfunction(Combination, MappedValue)
    )
}

deadfunction(Combination, MappedValue) {
    ; We only activate the deadkey if it is the start of a new word, as symbols aren’t put in words
    ; This condition corrects problems such as writing "même" that give "mê⁂e"
    if (GetLastSentCharacterAt(-3) = " ") {
        ; Character at -1 is the key in the deadkey, character at -2 is "ê", character at -3 is character before using the deadkey
        SendNewResult("{BackSpace 2}", Map("OnlyText", False))
        SendNewResult(MappedValue)
    }
}
#HotIf

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
    CreateHotstring("*", "1/★", "⅟")
    CreateHotstring("*", "1/2★", "½")
    CreateHotstring("*", "0/3★", "↉")
    CreateHotstring("*", "1/3★", "⅓")
    CreateHotstring("*", "2/3★", "⅔")
    CreateHotstring("*", "1/4★", "¼")
    CreateHotstring("*", "3/4★", "¾")
    CreateHotstring("*", "1/5★", "⅕")
    CreateHotstring("*", "2/5★", "⅖")
    CreateHotstring("*", "3/5★", "⅗")
    CreateHotstring("*", "4/5★", "⅘")
    CreateHotstring("*", "1/6★", "⅙")
    CreateHotstring("*", "5/6★", "⅚")
    CreateHotstring("*", "1/8★", "⅛")
    CreateHotstring("*", "3/8★", "⅜")
    CreateHotstring("*", "5/8★", "⅝")
    CreateHotstring("*", "7/8★", "⅞")
    CreateHotstring("*", "1/7★", "⅐")
    CreateHotstring("*", "1/9★", "⅑")
    CreateHotstring("*", "1/10★", "⅒")

    ; === Numbers ===
    CreateHotstring("*", "(0)★", "🄋")
    CreateHotstring("*", "(1)★", "➀")
    CreateHotstring("*", "(2)★", "➁")
    CreateHotstring("*", "(3)★", "➂")
    CreateHotstring("*", "(4)★", "➃")
    CreateHotstring("*", "(5)★", "➄")
    CreateHotstring("*", "(6)★", "➅")
    CreateHotstring("*", "(7)★", "➆")
    CreateHotstring("*", "(8)★", "➇")
    CreateHotstring("*", "(9)★", "➈")
    CreateHotstring("*", "(10)★", "➉")
    CreateHotstring("*", "(0n)★", "🄌")
    CreateHotstring("*", "(1n)★", "➊")
    CreateHotstring("*", "(2n)★", "➋")
    CreateHotstring("*", "(3n)★", "➌")
    CreateHotstring("*", "(4n)★", "➍")
    CreateHotstring("*", "(5n)★", "➎")
    CreateHotstring("*", "(6n)★", "➏")
    CreateHotstring("*", "(7n)★", "➐")
    CreateHotstring("*", "(8n)★", "➑")
    CreateHotstring("*", "(9n)★", "➒")
    CreateHotstring("*", "(10n)★", "➓")
    CreateHotstring("*", "(0b)★", "𝟎") ; B for Bold
    CreateHotstring("*", "(1b)★", "𝟏")
    CreateHotstring("*", "(2b)★", "𝟐")
    CreateHotstring("*", "(3b)★", "𝟑")
    CreateHotstring("*", "(4b)★", "𝟒")
    CreateHotstring("*", "(5b)★", "𝟓")
    CreateHotstring("*", "(6b)★", "𝟔")
    CreateHotstring("*", "(7b)★", "𝟕")
    CreateHotstring("*", "(8b)★", "𝟖")
    CreateHotstring("*", "(9b)★", "𝟗")
    CreateHotstring("*", "(0g)★", "𝟬") ; G for Gras
    CreateHotstring("*", "(1g)★", "𝟭")
    CreateHotstring("*", "(2g)★", "𝟮")
    CreateHotstring("*", "(3g)★", "𝟯")
    CreateHotstring("*", "(4g)★", "𝟰")
    CreateHotstring("*", "(5g)★", "𝟱")
    CreateHotstring("*", "(6g)★", "𝟲")
    CreateHotstring("*", "(7g)★", "𝟳")
    CreateHotstring("*", "(8g)★", "𝟴")
    CreateHotstring("*", "(9g)★", "𝟵")

    ; === Mathematical symbols ===
    CreateHotstring("*", "(infini)★", "∞")
    CreateHotstring("*", "(product)★", "∏")
    CreateHotstring("*", "(produit)★", "∏")
    CreateHotstring("*", "(coproduct)★", "∐")
    CreateHotstring("*", "(coproduit)★", "∐")
    CreateHotstring("*", "(forall)★", "∀")
    CreateHotstring("*", "(for all)★", "∀")
    CreateHotstring("*", "(pour tout)★", "∀")
    CreateHotstring("*", "(exist)★", "∃")
    CreateHotstring("*", "(exists)★", "∃")
    CreateHotstring("*", "(vide)★", "∅")
    CreateHotstring("*", "(ensemble vide)★", "∅")
    CreateHotstring("*", "(void)★", "∅")
    CreateHotstring("*", "(empty)★", "∅")
    CreateHotstring("*", "(prop)★", "∝")
    CreateHotstring("*", "(proportionnel)★", "∝")
    CreateHotstring("*", "(proportionnal)★", "∝")
    CreateHotstring("*", "(union)★", "∪")
    CreateHotstring("*", "(intersection)★", "⋂")
    CreateHotstring("*", "(appartient)★", "∈")
    CreateHotstring("*", "(inclus)★", "⊂")
    CreateHotstring("*", "(non inclus)★", "⊄")
    CreateHotstring("*", "(non appartient)★", "∉")
    CreateHotstring("*", "(n’appartient pas)★", "∉")
    CreateHotstring("*", "(non)★", "¬")
    CreateHotstring("*", "(et)★", "∧")
    CreateHotstring("*", "(sqrt)★", "√")
    CreateHotstring("*", "(racine)★", "√")
    CreateHotstring("*", "(^)★", "∧")
    CreateHotstring("*", "(v)★", "∨")
    CreateHotstring("*", "(delta)★", "∆")
    CreateHotstring("*", "(nabla)★", "∇")
    CreateHotstring("*", "(<<)★", "≪")
    CreateHotstring("*", "(partial)★", "∂")
    CreateHotstring("*", "(end of proof)★", "∎")
    CreateHotstring("*", "(eop)★", "∎")
    ; Integrals
    CreateHotstring("*", "(int)★", "∫")
    CreateHotstring("*", "(s)★", "∫")
    CreateHotstring("*", "(so)★", "∮")
    CreateHotstring("*", "(sso)★", "∯")
    CreateHotstring("*", "(sss)★", "∭")
    CreateHotstring("*", "(ssso)★", "∰")
    ; Relations
    CreateHotstring("*", "(=)★", "≡")
    CreateHotstring("*", "(equivalent)★", "⇔")
    CreateHotstring("*", "(équivalent)★", "⇔")
    CreateHotstring("*", "(implique)★", "⇒")
    CreateHotstring("*", "(impliqué)★", "⇒")
    CreateHotstring("*", "(imply)★", "⇒")
    CreateHotstring("*", "(non implique)★", "⇏")
    CreateHotstring("*", "(non impliqué)★", "⇏")
    CreateHotstring("*", "(non équivalent)★", "⇎")
    CreateHotstring("*", "(not equivalent)★", "⇎")

    ; === Arrows ===
    CreateHotstring("*", ">★", "➢")
    CreateHotstring("*", " -> ★", "➜")
    CreateHotstring("*", "-->★", "➜")
    CreateHotstring("*", "==>★", "⇒")
    CreateHotstring("*", "=/=>★", "⇏")
    CreateHotstring("*", "<==★", "⇐")
    CreateHotstring("*", "<==>★", "⇔")
    CreateHotstring("*", "<=/=>★", "⇎")
    CreateHotstring("*", "<=>★", "⇔")
    CreateHotstring("*", "^|★", "↑")
    CreateHotstring("*", "|^★", "↓")
    CreateHotstring("*", "->★", "→")
    CreateHotstring("*", "<-★", "←")
    CreateHotstring("*", "->>★", "➡")
    CreateHotstring("*", "<<-★", "⬅")
    CreateHotstring("*", "|->★", "↪")
    CreateHotstring("*", "<-|★", "↩")
    CreateHotstring("*", "^|-★", "⭮")

    ; === Checks and checkboxes ===
    CreateHotstring("*", "(v)★", "✓")
    CreateHotstring("*", "(x)★", "✗")
    CreateHotstring("*", "[v]★", "☑")
    CreateHotstring("*", "[x]★", "☒")

    ; === Miscellaneous symbols ===
    CreateHotstring("*", "/!\★", "⚠")
    CreateHotstring("*", "**★", "⁂")
    CreateHotstring("*", "°C★", "℃")
    CreateHotstring("*", "(b)★", "•")
    CreateHotstring("*", "(c)★", "©")
    CreateHotstring("*?", "eme★", "ᵉ")
    CreateHotstring("*?", "ème★", "ᵉ")
    CreateHotstring("*?", "ieme★", "ᵉ")
    CreateHotstring("*?", "ième★", "ᵉ")
    CreateHotstring("*", "(o)★", "•")
    CreateHotstring("*", "(r)★", "®")
    CreateHotstring("*", "(tm)★", "™")
}

if Features["MagicKey"]["TextExpansionSymbolsTypst"].Enabled {
    ; https://typst.app/docs/reference/symbols/sym/ to search for a symbol.
    ; List scrapped here: https://github.com/typst/codex/tree/main/src/modules/sym.txt

    ; === Control ===
    CreateHotstring("*", "$wj$", "{U+2060}", Map("OnlyText", False))
    CreateHotstring("*", "$zwj$", "{U+200D}", Map("OnlyText", False))
    CreateHotstring("*", "$zwnj$", "{U+200C}", Map("OnlyText", False))
    CreateHotstring("*", "$zws$", "{U+200B}", Map("OnlyText", False))
    CreateHotstring("*", "$lrm$", "{U+200E}", Map("OnlyText", False))
    CreateHotstring("*", "$rlm$", "{U+200F}", Map("OnlyText", False))

    ; === Spaces ===
    CreateHotstring("*", "$space$", "{U+0020}", Map("OnlyText", False))
    CreateHotstring("*", "$space.nobreak$", "{U+00A0}", Map("OnlyText", False))
    CreateHotstring("*", "$space.nobreak.narrow$", "{U+202F}", Map("OnlyText", False))
    CreateHotstring("*", "$space.en$", "{U+2002}", Map("OnlyText", False))
    CreateHotstring("*", "$space.quad$", "{U+2003}", Map("OnlyText", False))
    CreateHotstring("*", "$space.third$", "{U+2004}", Map("OnlyText", False))
    CreateHotstring("*", "$space.quarter$", "{U+2005}", Map("OnlyText", False))
    CreateHotstring("*", "$space.sixth$", "{U+2006}", Map("OnlyText", False))
    CreateHotstring("*", "$space.med$", "{U+205F}", Map("OnlyText", False))
    CreateHotstring("*", "$space.fig$", "{U+2007}", Map("OnlyText", False))
    CreateHotstring("*", "$space.punct$", "{U+2008}", Map("OnlyText", False))
    CreateHotstring("*", "$space.thin$", "{U+2009}", Map("OnlyText", False))
    CreateHotstring("*", "$space.hair$", "{U+200A}", Map("OnlyText", False))

    ; === Delimiters ===
    ; Paren
    CreateHotstring("*", "$paren.l$", "(")
    CreateHotstring("*", "$paren.l.flat$", "⟮")
    CreateHotstring("*", "$paren.l.closed$", "⦇")
    CreateHotstring("*", "$paren.l.stroked$", "⦅")
    CreateHotstring("*", "$paren.l.double$", "⦅")
    CreateHotstring("*", "$paren.r$", ")")
    CreateHotstring("*", "$paren.r.flat$", "⟯")
    CreateHotstring("*", "$paren.r.closed$", "⦈")
    CreateHotstring("*", "$paren.r.stroked$", "⦆")
    CreateHotstring("*", "$paren.r.double$", "⦆")
    CreateHotstring("*", "$paren.t$", "⏜")
    CreateHotstring("*", "$paren.b$", "⏝")
    ; Brace
    CreateHotstring("*", "$brace.l$", "{")
    CreateHotstring("*", "$brace.l.stroked$", "{U+27C3}", Map("OnlyText", False))
    CreateHotstring("*", "$brace.l.double$", "{U+27C3}", Map("OnlyText", False))
    CreateHotstring("*", "$brace.r$", "}")
    CreateHotstring("*", "$brace.r.stroked$", "⦄")
    CreateHotstring("*", "$brace.r.double$", "⦄")
    CreateHotstring("*", "$brace.t$", "⏞")
    CreateHotstring("*", "$brace.b$", "⏟")
    ; Bracket
    CreateHotstring("*", "$bracket.l$", "[")
    CreateHotstring("*", "$bracket.l.tick.t$", "⦍")
    CreateHotstring("*", "$bracket.l.tick.b$", "⦏")
    CreateHotstring("*", "$bracket.l.stroked$", "⟦")
    CreateHotstring("*", "$bracket.l.double$", "⟦")
    CreateHotstring("*", "$bracket.r$", "]")
    CreateHotstring("*", "$bracket.r.tick.t$", "⦐")
    CreateHotstring("*", "$bracket.r.tick.b$", "⦎")
    CreateHotstring("*", "$bracket.r.stroked$", "⟧")
    CreateHotstring("*", "$bracket.r.double$", "⟧")
    CreateHotstring("*", "$bracket.t$", "⎴")
    CreateHotstring("*", "$bracket.b$", "⎵")
    ; Shell
    CreateHotstring("*", "$shell.l$", "❲")
    CreateHotstring("*", "$shell.l.stroked$", "⟬")
    CreateHotstring("*", "$shell.l.filled$", "⦗")
    CreateHotstring("*", "$shell.l.double$", "⟬")
    CreateHotstring("*", "$shell.r$", "❳")
    CreateHotstring("*", "$shell.r.stroked$", "⟭")
    CreateHotstring("*", "$shell.r.filled$", "⦘")
    CreateHotstring("*", "$shell.r.double$", "⟭")
    CreateHotstring("*", "$shell.t$", "⏠")
    CreateHotstring("*", "$shell.b$", "⏡")
    ; Bag
    CreateHotstring("*", "$bag.l$", "⟅")
    CreateHotstring("*", "$bag.r$", "⟆")
    ; Mustache
    CreateHotstring("*", "$mustache.l$", "⎰")
    CreateHotstring("*", "$mustache.r$", "⎱")
    ; Bar
    CreateHotstring("*", "$bar.v$", "|")
    CreateHotstring("*", "$bar.v.double$", "‖")
    CreateHotstring("*", "$bar.v.triple$", "⦀")
    CreateHotstring("*", "$bar.v.broken$", "¦")
    CreateHotstring("*", "$bar.v.o$", "⦶")
    CreateHotstring("*", "$bar.v.circle$", "⦶")
    CreateHotstring("*", "$bar.h$", "―")
    ; Fence
    CreateHotstring("*", "$fence.l$", "⧘")
    CreateHotstring("*", "$fence.l.double$", "⧚")
    CreateHotstring("*", "$fence.r$", "⧙")
    CreateHotstring("*", "$fence.r.double$", "⧛")
    CreateHotstring("*", "$fence.dotted$", "⦙")
    ; Chevron
    CreateHotstring("*", "$chevron.l$", "⟨")
    CreateHotstring("*", "$chevron.l.curly$", "⧼")
    CreateHotstring("*", "$chevron.l.dot$", "⦑")
    CreateHotstring("*", "$chevron.l.closed$", "⦉")
    CreateHotstring("*", "$chevron.l.double$", "⟪")
    CreateHotstring("*", "$chevron.r$", "⟩")
    CreateHotstring("*", "$chevron.r.curly$", "⧽")
    CreateHotstring("*", "$chevron.r.dot$", "⦒")
    CreateHotstring("*", "$chevron.r.closed$", "⦊")
    CreateHotstring("*", "$chevron.r.double$", "⟫")
    ; Ceil
    CreateHotstring("*", "$ceil.l$", "⌈")
    CreateHotstring("*", "$ceil.r$", "⌉")
    ; Floor
    CreateHotstring("*", "$floor.l$", "⌊")
    CreateHotstring("*", "$floor.r$", "⌋")
    ; Corner
    CreateHotstring("*", "$corner.l.t$", "⌜")
    CreateHotstring("*", "$corner.l.b$", "⌞")
    CreateHotstring("*", "$corner.r.t$", "⌝")
    CreateHotstring("*", "$corner.r.b$", "⌟")

    ; === Punctuation ===
    CreateHotstring("*", "$amp$", "&")
    CreateHotstring("*", "$amp.inv$", "⅋")
    ; Ast
    CreateHotstring("*", "$ast.op$", "∗")
    CreateHotstring("*", "$ast.op.o$", "⊛")
    CreateHotstring("*", "$ast.basic$", "*")
    CreateHotstring("*", "$ast.low$", "⁎")
    CreateHotstring("*", "$ast.double$", "⁑")
    CreateHotstring("*", "$ast.triple$", "⁂")
    CreateHotstring("*", "$ast.small$", "﹡")
    CreateHotstring("*", "$ast.circle$", "⊛")
    CreateHotstring("*", "$ast.square$", "⧆")
    CreateHotstring("*", "$at$", "@")
    CreateHotstring("*", "$backslash$", "\")
    CreateHotstring("*", "$backslash.o$", "⦸")
    CreateHotstring("*", "$backslash.circle$", "⦸")
    CreateHotstring("*", "$backslash.not$", "⧷")
    CreateHotstring("*", "$co$", "℅")
    CreateHotstring("*", "$colon$", ":")
    CreateHotstring("*", "$colon.currency$", "₡")
    CreateHotstring("*", "$colon.double$", "∷")
    CreateHotstring("*", "$colon.tri$", "⁝")
    CreateHotstring("*", "$colon.tri.op$", "⫶")
    CreateHotstring("*", "$colon.eq$", "≔")
    CreateHotstring("*", "$colon.double.eq$", "⩴")
    CreateHotstring("*", "$comma$", ",")
    CreateHotstring("*", "$comma.inv$", "⸲")
    CreateHotstring("*", "$comma.rev$", "⹁")
    CreateHotstring("*", "$dagger$", "†")
    CreateHotstring("*", "$dagger.double$", "‡")
    CreateHotstring("*", "$dagger.triple$", "⹋")
    CreateHotstring("*", "$dagger.l$", "⸶")
    CreateHotstring("*", "$dagger.r$", "⸷")
    CreateHotstring("*", "$dagger.inv$", "⸸")
    ; Dash
    CreateHotstring("*", "$dash.en$", "–")
    CreateHotstring("*", "$dash.em$", "—")
    CreateHotstring("*", "$dash.em.two$", "⸺")
    CreateHotstring("*", "$dash.em.three$", "⸻")
    CreateHotstring("*", "$dash.fig$", "‒")
    CreateHotstring("*", "$dash.wave$", "〜")
    CreateHotstring("*", "$dash.colon$", "∹")
    CreateHotstring("*", "$dash.o$", "⊝")
    CreateHotstring("*", "$dash.circle$", "⊝")
    CreateHotstring("*", "$dash.wave.double$", "〰")
    ; Dot
    CreateHotstring("*", "$dot.op$", "⋅")
    CreateHotstring("*", "$dot.basic$", ".")
    CreateHotstring("*", "$dot.c$", "·")
    CreateHotstring("*", "$dot.o$", "⊙")
    CreateHotstring("*", "$dot.o.big$", "⨀")
    CreateHotstring("*", "$dot.circle$", "⊙")
    CreateHotstring("*", "$dot.circle.big$", "⨀")
    CreateHotstring("*", "$dot.square$", "⊡")
    CreateHotstring("*", "$dot.double$", "¨")
    CreateHotstring("*", "$dot.triple$", "{U+20DB}", Map("OnlyText", False))
    CreateHotstring("*", "$dot.quad$", "{U+20DC}", Map("OnlyText", False))
    CreateHotstring("*", "$excl$", "!")
    CreateHotstring("*", "$excl.double$", "‼")
    CreateHotstring("*", "$excl.inv$", "¡")
    CreateHotstring("*", "$excl.quest$", "⁉")
    CreateHotstring("*", "$quest$", "?")
    CreateHotstring("*", "$quest.double$", "⁇")
    CreateHotstring("*", "$quest.excl$", "⁈")
    CreateHotstring("*", "$quest.inv$", "¿")
    CreateHotstring("*", "$interrobang$", "‽")
    CreateHotstring("*", "$interrobang.inv$", "⸘")
    CreateHotstring("*", "$hash$", "#")
    CreateHotstring("*", "$hyph$", "‐")
    CreateHotstring("*", "$hyph.minus$", "-")
    CreateHotstring("*", "$hyph.nobreak$", "{U+2011}", Map("OnlyText", False))
    CreateHotstring("*", "$hyph.point$", "‧")
    CreateHotstring("*", "$hyph.soft$", "{U+00AD}", Map("OnlyText", False))
    CreateHotstring("*", "$numero$", "№")
    CreateHotstring("*", "$percent$", "%")
    CreateHotstring("*", "$permille$", "‰")
    CreateHotstring("*", "$permyriad$", "‱")
    CreateHotstring("*", "$pilcrow$", "¶")
    CreateHotstring("*", "$pilcrow.rev$", "⁋")
    CreateHotstring("*", "$section$", "§")
    CreateHotstring("*", "$semi$", ";")
    CreateHotstring("*", "$semi.inv$", "⸵")
    CreateHotstring("*", "$semi.rev$", "⁏")
    CreateHotstring("*", "$slash$", "/")
    CreateHotstring("*", "$slash.o$", "⊘")
    CreateHotstring("*", "$slash.double$", "⫽")
    CreateHotstring("*", "$slash.triple$", "⫻")
    CreateHotstring("*", "$slash.big$", "⧸")
    ; Dots
    CreateHotstring("*", "$dots.h.c$", "⋯")
    CreateHotstring("*", "$dots.h$", "…")
    CreateHotstring("*", "$dots.v$", "⋮")
    CreateHotstring("*", "$dots.down$", "⋱")
    CreateHotstring("*", "$dots.up$", "⋰")
    ; Tilde
    CreateHotstring("*", "$tilde.op$", "∼")
    CreateHotstring("*", "$tilde.basic$", "~")
    CreateHotstring("*", "$tilde.dot$", "⩪")
    CreateHotstring("*", "$tilde.eq$", "≃")
    CreateHotstring("*", "$tilde.eq.not$", "≄")
    CreateHotstring("*", "$tilde.eq.rev$", "⋍")
    CreateHotstring("*", "$tilde.equiv$", "≅")
    CreateHotstring("*", "$tilde.equiv.not$", "≇")
    CreateHotstring("*", "$tilde.nequiv$", "≆")
    CreateHotstring("*", "$tilde.not$", "≁")
    CreateHotstring("*", "$tilde.rev$", "∽")
    CreateHotstring("*", "$tilde.rev.equiv$", "≌")
    CreateHotstring("*", "$tilde.triple$", "≋")

    ; === Accents, quotes, and primes ===
    CreateHotstring("*", "$acute$", "´")
    CreateHotstring("*", "$acute.double$", "˝")
    CreateHotstring("*", "$breve$", "˘")
    CreateHotstring("*", "$caret$", "‸")
    CreateHotstring("*", "$caron$", "ˇ")
    CreateHotstring("*", "$hat$", "^")
    CreateHotstring("*", "$diaer$", "¨")
    CreateHotstring("*", "$grave$", "`"")
    CreateHotstring("*", "$macron$", "¯")
    ; Quote
    CreateHotstring("*", "$quote.double$", "`"")
    CreateHotstring("*", "$quote.single$", "'")
    CreateHotstring("*", "$quote.l.double$", "“")
    CreateHotstring("*", "$quote.l.single$", "‘")
    CreateHotstring("*", "$quote.r.double$", "”")
    CreateHotstring("*", "$quote.r.single$", "’")
    CreateHotstring("*", "$quote.chevron.l.double$", "«")
    CreateHotstring("*", "$quote.chevron.l.single$", "‹")
    CreateHotstring("*", "$quote.chevron.r.double$", "»")
    CreateHotstring("*", "$quote.chevron.r.single$", "›")
    CreateHotstring("*", "$quote.angle.l.double$", "«")
    CreateHotstring("*", "$quote.angle.l.single$", "‹")
    CreateHotstring("*", "$quote.angle.r.double$", "»")
    CreateHotstring("*", "$quote.angle.r.single$", "›")
    CreateHotstring("*", "$quote.high.double$", "‟")
    CreateHotstring("*", "$quote.high.single$", "‛")
    CreateHotstring("*", "$quote.low.double$", "„")
    CreateHotstring("*", "$quote.low.single$", "‚")
    CreateHotstring("*", "$prime$", "′")
    CreateHotstring("*", "$prime.rev$", "‵")
    CreateHotstring("*", "$prime.double$", "″")
    CreateHotstring("*", "$prime.double.rev$", "‶")
    CreateHotstring("*", "$prime.triple$", "‴")
    CreateHotstring("*", "$prime.triple.rev$", "‷")
    CreateHotstring("*", "$prime.quad$", "⁗")

    ; === Arithmetic ===
    CreateHotstring("*", "$plus$", "+")
    CreateHotstring("*", "$plus.o$", "⊕")
    CreateHotstring("*", "$plus.o.l$", "⨭")
    CreateHotstring("*", "$plus.o.r$", "⨮")
    CreateHotstring("*", "$plus.o.arrow$", "⟴")
    CreateHotstring("*", "$plus.o.big$", "⨁")
    CreateHotstring("*", "$plus.circle$", "⊕")
    CreateHotstring("*", "$plus.circle.arrow$", "⟴")
    CreateHotstring("*", "$plus.circle.big$", "⨁")
    CreateHotstring("*", "$plus.dot$", "∔")
    CreateHotstring("*", "$plus.double$", "⧺")
    CreateHotstring("*", "$plus.minus$", "±")
    CreateHotstring("*", "$plus.small$", "﹢")
    CreateHotstring("*", "$plus.square$", "⊞")
    CreateHotstring("*", "$plus.triangle$", "⨹")
    CreateHotstring("*", "$plus.triple$", "⧻")
    CreateHotstring("*", "$minus$", "−")
    CreateHotstring("*", "$minus.o$", "⊖")
    CreateHotstring("*", "$minus.circle$", "⊖")
    CreateHotstring("*", "$minus.dot$", "∸")
    CreateHotstring("*", "$minus.plus$", "∓")
    CreateHotstring("*", "$minus.square$", "⊟")
    CreateHotstring("*", "$minus.tilde$", "≂")
    CreateHotstring("*", "$minus.triangle$", "⨺")
    CreateHotstring("*", "$div$", "÷")
    CreateHotstring("*", "$div.o$", "⨸")
    CreateHotstring("*", "$div.slanted.o$", "⦼")
    CreateHotstring("*", "$div.circle$", "⨸")
    CreateHotstring("*", "$times$", "×")
    CreateHotstring("*", "$times.big$", "⨉")
    CreateHotstring("*", "$times.o$", "⊗")
    CreateHotstring("*", "$times.o.l$", "⨴")
    CreateHotstring("*", "$times.o.r$", "⨵")
    CreateHotstring("*", "$times.o.hat$", "⨶")
    CreateHotstring("*", "$times.o.big$", "⨂")
    CreateHotstring("*", "$times.circle$", "⊗")
    CreateHotstring("*", "$times.circle.big$", "⨂")
    CreateHotstring("*", "$times.div$", "⋇")
    CreateHotstring("*", "$times.three.l$", "⋋")
    CreateHotstring("*", "$times.three.r$", "⋌")
    CreateHotstring("*", "$times.l$", "⋉")
    CreateHotstring("*", "$times.r$", "⋊")
    CreateHotstring("*", "$times.square$", "⊠")
    CreateHotstring("*", "$times.triangle$", "⨻")
    CreateHotstring("*", "$ratio$", "∶")

    ; === Relations ===
    CreateHotstring("*", "$eq$", "=")
    CreateHotstring("*", "$eq.star$", "≛")
    CreateHotstring("*", "$eq.o$", "⊜")
    CreateHotstring("*", "$eq.circle$", "⊜")
    CreateHotstring("*", "$eq.colon$", "≕")
    CreateHotstring("*", "$eq.dots$", "≑")
    CreateHotstring("*", "$eq.dots.down$", "≒")
    CreateHotstring("*", "$eq.dots.up$", "≓")
    CreateHotstring("*", "$eq.def$", "≝")
    CreateHotstring("*", "$eq.delta$", "≜")
    CreateHotstring("*", "$eq.equi$", "≚")
    CreateHotstring("*", "$eq.est$", "≙")
    CreateHotstring("*", "$eq.gt$", "⋝")
    CreateHotstring("*", "$eq.lt$", "⋜")
    CreateHotstring("*", "$eq.m$", "≞")
    CreateHotstring("*", "$eq.not$", "≠")
    CreateHotstring("*", "$eq.prec$", "⋞")
    CreateHotstring("*", "$eq.quest$", "≟")
    CreateHotstring("*", "$eq.small$", "﹦")
    CreateHotstring("*", "$eq.succ$", "⋟")
    CreateHotstring("*", "$eq.triple$", "≡")
    CreateHotstring("*", "$eq.triple.not$", "≢")
    CreateHotstring("*", "$eq.quad$", "≣")
    CreateHotstring("*", "$gt$", ">")
    CreateHotstring("*", "$gt.o$", "⧁")
    CreateHotstring("*", "$gt.circle$", "⧁")
    CreateHotstring("*", "$gt.dot$", "⋗")
    CreateHotstring("*", "$gt.approx$", "⪆")
    CreateHotstring("*", "$gt.double$", "≫")
    CreateHotstring("*", "$gt.eq$", "≥")
    CreateHotstring("*", "$gt.eq.slant$", "⩾")
    CreateHotstring("*", "$gt.eq.lt$", "⋛")
    CreateHotstring("*", "$gt.eq.not$", "≱")
    CreateHotstring("*", "$gt.equiv$", "≧")
    CreateHotstring("*", "$gt.lt$", "≷")
    CreateHotstring("*", "$gt.lt.not$", "≹")
    CreateHotstring("*", "$gt.neq$", "⪈")
    CreateHotstring("*", "$gt.napprox$", "⪊")
    CreateHotstring("*", "$gt.nequiv$", "≩")
    CreateHotstring("*", "$gt.not$", "≯")
    CreateHotstring("*", "$gt.ntilde$", "⋧")
    CreateHotstring("*", "$gt.small$", "﹥")
    CreateHotstring("*", "$gt.tilde$", "≳")
    CreateHotstring("*", "$gt.tilde.not$", "≵")
    CreateHotstring("*", "$gt.tri$", "⊳")
    CreateHotstring("*", "$gt.tri.eq$", "⊵")
    CreateHotstring("*", "$gt.tri.eq.not$", "⋭")
    CreateHotstring("*", "$gt.tri.not$", "⋫")
    CreateHotstring("*", "$gt.triple$", "⋙")
    CreateHotstring("*", "$gt.triple.nested$", "⫸")
    CreateHotstring("*", "$lt$", "<")
    CreateHotstring("*", "$lt.o$", "⧀")
    CreateHotstring("*", "$lt.circle$", "⧀")
    CreateHotstring("*", "$lt.dot$", "⋖")
    CreateHotstring("*", "$lt.approx$", "⪅")
    CreateHotstring("*", "$lt.double$", "≪")
    CreateHotstring("*", "$lt.eq$", "≤")
    CreateHotstring("*", "$lt.eq.slant$", "⩽")
    CreateHotstring("*", "$lt.eq.gt$", "⋚")
    CreateHotstring("*", "$lt.eq.not$", "≰")
    CreateHotstring("*", "$lt.equiv$", "≦")
    CreateHotstring("*", "$lt.gt$", "≶")
    CreateHotstring("*", "$lt.gt.not$", "≸")
    CreateHotstring("*", "$lt.neq$", "⪇")
    CreateHotstring("*", "$lt.napprox$", "⪉")
    CreateHotstring("*", "$lt.nequiv$", "≨")
    CreateHotstring("*", "$lt.not$", "≮")
    CreateHotstring("*", "$lt.ntilde$", "⋦")
    CreateHotstring("*", "$lt.small$", "﹤")
    CreateHotstring("*", "$lt.tilde$", "≲")
    CreateHotstring("*", "$lt.tilde.not$", "≴")
    CreateHotstring("*", "$lt.tri$", "⊲")
    CreateHotstring("*", "$lt.tri.eq$", "⊴")
    CreateHotstring("*", "$lt.tri.eq.not$", "⋬")
    CreateHotstring("*", "$lt.tri.not$", "⋪")
    CreateHotstring("*", "$lt.triple$", "⋘")
    CreateHotstring("*", "$lt.triple.nested$", "⫷")
    CreateHotstring("*", "$approx$", "≈")
    CreateHotstring("*", "$approx.eq$", "≊")
    CreateHotstring("*", "$approx.not$", "≉")
    CreateHotstring("*", "$prec$", "≺")
    CreateHotstring("*", "$prec.approx$", "⪷")
    CreateHotstring("*", "$prec.curly.eq$", "≼")
    CreateHotstring("*", "$prec.curly.eq.not$", "⋠")
    CreateHotstring("*", "$prec.double$", "⪻")
    CreateHotstring("*", "$prec.eq$", "⪯")
    CreateHotstring("*", "$prec.equiv$", "⪳")
    CreateHotstring("*", "$prec.napprox$", "⪹")
    CreateHotstring("*", "$prec.neq$", "⪱")
    CreateHotstring("*", "$prec.nequiv$", "⪵")
    CreateHotstring("*", "$prec.not$", "⊀")
    CreateHotstring("*", "$prec.ntilde$", "⋨")
    CreateHotstring("*", "$prec.tilde$", "≾")
    CreateHotstring("*", "$succ$", "≻")
    CreateHotstring("*", "$succ.approx$", "⪸")
    CreateHotstring("*", "$succ.curly.eq$", "≽")
    CreateHotstring("*", "$succ.curly.eq.not$", "⋡")
    CreateHotstring("*", "$succ.double$", "⪼")
    CreateHotstring("*", "$succ.eq$", "⪰")
    CreateHotstring("*", "$succ.equiv$", "⪴")
    CreateHotstring("*", "$succ.napprox$", "⪺")
    CreateHotstring("*", "$succ.neq$", "⪲")
    CreateHotstring("*", "$succ.nequiv$", "⪶")
    CreateHotstring("*", "$succ.not$", "⊁")
    CreateHotstring("*", "$succ.ntilde$", "⋩")
    CreateHotstring("*", "$succ.tilde$", "≿")
    CreateHotstring("*", "$equiv$", "≡")
    CreateHotstring("*", "$equiv.not$", "≢")
    CreateHotstring("*", "$smt$", "⪪")
    CreateHotstring("*", "$smt.eq$", "⪬")
    CreateHotstring("*", "$lat$", "⪫")
    CreateHotstring("*", "$lat.eq$", "⪭")
    CreateHotstring("*", "$prop$", "∝")
    CreateHotstring("*", "$original$", "⊶")
    CreateHotstring("*", "$image$", "⊷")
    CreateHotstring("*", "$asymp$", "≍")
    CreateHotstring("*", "$asymp.not$", "≭")

    ; === Set theory ===
    CreateHotstring("*", "$emptyset$", "∅")
    CreateHotstring("*", "$emptyset.arrow.r$", "⦳")
    CreateHotstring("*", "$emptyset.arrow.l$", "⦴")
    CreateHotstring("*", "$emptyset.bar$", "⦱")
    CreateHotstring("*", "$emptyset.circle$", "⦲")
    CreateHotstring("*", "$emptyset.rev$", "⦰")
    CreateHotstring("*", "$nothing$", "∅")
    CreateHotstring("*", "$nothing.arrow.r$", "⦳")
    CreateHotstring("*", "$nothing.arrow.l$", "⦴")
    CreateHotstring("*", "$nothing.bar$", "⦱")
    CreateHotstring("*", "$nothing.circle$", "⦲")
    CreateHotstring("*", "$nothing.rev$", "⦰")
    CreateHotstring("*", "$without$", "∖")
    CreateHotstring("*", "$complement$", "∁")
    CreateHotstring("*", "$in$", "∈")
    CreateHotstring("*", "$in.not$", "∉")
    CreateHotstring("*", "$in.rev$", "∋")
    CreateHotstring("*", "$in.rev.not$", "∌")
    CreateHotstring("*", "$in.rev.small$", "∍")
    CreateHotstring("*", "$in.small$", "∊")
    CreateHotstring("*", "$subset$", "⊂")
    CreateHotstring("*", "$subset.dot$", "⪽")
    CreateHotstring("*", "$subset.double$", "⋐")
    CreateHotstring("*", "$subset.eq$", "⊆")
    CreateHotstring("*", "$subset.eq.not$", "⊈")
    CreateHotstring("*", "$subset.eq.sq$", "⊑")
    CreateHotstring("*", "$subset.eq.sq.not$", "⋢")
    CreateHotstring("*", "$subset.neq$", "⊊")
    CreateHotstring("*", "$subset.not$", "⊄")
    CreateHotstring("*", "$subset.sq$", "⊏")
    CreateHotstring("*", "$subset.sq.neq$", "⋤")
    CreateHotstring("*", "$supset$", "⊃")
    CreateHotstring("*", "$supset.dot$", "⪾")
    CreateHotstring("*", "$supset.double$", "⋑")
    CreateHotstring("*", "$supset.eq$", "⊇")
    CreateHotstring("*", "$supset.eq.not$", "⊉")
    CreateHotstring("*", "$supset.eq.sq$", "⊒")
    CreateHotstring("*", "$supset.eq.sq.not$", "⋣")
    CreateHotstring("*", "$supset.neq$", "⊋")
    CreateHotstring("*", "$supset.not$", "⊅")
    CreateHotstring("*", "$supset.sq$", "⊐")
    CreateHotstring("*", "$supset.sq.neq$", "⋥")
    CreateHotstring("*", "$union$", "∪")
    CreateHotstring("*", "$union.arrow$", "⊌")
    CreateHotstring("*", "$union.big$", "⋃")
    CreateHotstring("*", "$union.dot$", "⊍")
    CreateHotstring("*", "$union.dot.big$", "⨃")
    CreateHotstring("*", "$union.double$", "⋓")
    CreateHotstring("*", "$union.minus$", "⩁")
    CreateHotstring("*", "$union.or$", "⩅")
    CreateHotstring("*", "$union.plus$", "⊎")
    CreateHotstring("*", "$union.plus.big$", "⨄")
    CreateHotstring("*", "$union.sq$", "⊔")
    CreateHotstring("*", "$union.sq.big$", "⨆")
    CreateHotstring("*", "$union.sq.double$", "⩏")
    CreateHotstring("*", "$inter$", "∩")
    CreateHotstring("*", "$inter.and$", "⩄")
    CreateHotstring("*", "$inter.big$", "⋂")
    CreateHotstring("*", "$inter.dot$", "⩀")
    CreateHotstring("*", "$inter.double$", "⋒")
    CreateHotstring("*", "$inter.sq$", "⊓")
    CreateHotstring("*", "$inter.sq.big$", "⨅")
    CreateHotstring("*", "$inter.sq.double$", "⩎")
    CreateHotstring("*", "$sect$", "∩")
    CreateHotstring("*", "$sect.and$", "⩄")
    CreateHotstring("*", "$sect.big$", "⋂")
    CreateHotstring("*", "$sect.dot$", "⩀")
    CreateHotstring("*", "$sect.double$", "⋒")
    CreateHotstring("*", "$sect.sq$", "⊓")
    CreateHotstring("*", "$sect.sq.big$", "⨅")
    CreateHotstring("*", "$sect.sq.double$", "⩎")

    ; === Calculus ===
    CreateHotstring("*", "$infinity$", "∞")
    CreateHotstring("*", "$infinity.bar$", "⧞")
    CreateHotstring("*", "$infinity.incomplete$", "⧜")
    CreateHotstring("*", "$infinity.tie$", "⧝")
    CreateHotstring("*", "$oo$", "∞")
    CreateHotstring("*", "$diff$", "∂")
    CreateHotstring("*", "$partial$", "∂")
    CreateHotstring("*", "$gradient$", "∇")
    CreateHotstring("*", "$nabla$", "∇")
    CreateHotstring("*", "$sum$", "∑")
    CreateHotstring("*", "$sum.integral$", "⨋")
    CreateHotstring("*", "$product$", "∏")
    CreateHotstring("*", "$product.co$", "∐")
    CreateHotstring("*", "$integral$", "∫")
    CreateHotstring("*", "$integral.arrow.hook$", "⨗")
    CreateHotstring("*", "$integral.ccw$", "⨑")
    CreateHotstring("*", "$integral.cont$", "∮")
    CreateHotstring("*", "$integral.cont.ccw$", "∳")
    CreateHotstring("*", "$integral.cont.cw$", "∲")
    CreateHotstring("*", "$integral.cw$", "∱")
    CreateHotstring("*", "$integral.dash$", "⨍")
    CreateHotstring("*", "$integral.dash.double$", "⨎")
    CreateHotstring("*", "$integral.double$", "∬")
    CreateHotstring("*", "$integral.quad$", "⨌")
    CreateHotstring("*", "$integral.inter$", "⨙")
    CreateHotstring("*", "$integral.sect$", "⨙")
    CreateHotstring("*", "$integral.slash$", "⨏")
    CreateHotstring("*", "$integral.square$", "⨖")
    CreateHotstring("*", "$integral.surf$", "∯")
    CreateHotstring("*", "$integral.times$", "⨘")
    CreateHotstring("*", "$integral.triple$", "∭")
    CreateHotstring("*", "$integral.union$", "⨚")
    CreateHotstring("*", "$integral.vol$", "∰")
    CreateHotstring("*", "$laplace$", "∆")

    ; === Logic ===
    CreateHotstring("*", "$forall$", "∀")
    CreateHotstring("*", "$exists$", "∃")
    CreateHotstring("*", "$exists.not$", "∄")
    CreateHotstring("*", "$top$", "⊤")
    CreateHotstring("*", "$bot$", "⊥")
    CreateHotstring("*", "$not$", "¬")
    CreateHotstring("*", "$and$", "∧")
    CreateHotstring("*", "$and.big$", "⋀")
    CreateHotstring("*", "$and.curly$", "⋏")
    CreateHotstring("*", "$and.dot$", "⟑")
    CreateHotstring("*", "$and.double$", "⩓")
    CreateHotstring("*", "$or$", "∨")
    CreateHotstring("*", "$or.big$", "⋁")
    CreateHotstring("*", "$or.curly$", "⋎")
    CreateHotstring("*", "$or.dot$", "⟇")
    CreateHotstring("*", "$or.double$", "⩔")
    CreateHotstring("*", "$xor$", "⊕")
    CreateHotstring("*", "$xor.big$", "⨁")
    CreateHotstring("*", "$models$", "⊧")
    CreateHotstring("*", "$forces$", "⊩")
    CreateHotstring("*", "$forces.not$", "⊮")
    CreateHotstring("*", "$therefore$", "∴")
    CreateHotstring("*", "$because$", "∵")
    CreateHotstring("*", "$qed$", "∎")

    ; === Function and category theory ===
    CreateHotstring("*", "$mapsto$", "↦")
    CreateHotstring("*", "$mapsto.long$", "⟼")
    CreateHotstring("*", "$compose$", "∘")
    CreateHotstring("*", "$compose.o$", "⊚")
    CreateHotstring("*", "$convolve$", "∗")
    CreateHotstring("*", "$convolve.o$", "⊛")
    CreateHotstring("*", "$multimap$", "⊸")
    CreateHotstring("*", "$multimap.double$", "⧟")

    ; === Game theory ===
    CreateHotstring("*", "$tiny$", "⧾")
    CreateHotstring("*", "$miny$", "⧿")

    ; === Number theory ===
    CreateHotstring("*", "$divides$", "∣")
    CreateHotstring("*", "$divides.not$", "∤")
    CreateHotstring("*", "$divides.not.rev$", "⫮")
    CreateHotstring("*", "$divides.struck$", "⟊")

    ; === Algebra ===
    CreateHotstring("*", "$wreath$", "≀")

    ; === Geometry ===
    CreateHotstring("*", "$angle$", "∠")
    CreateHotstring("*", "$angle.l$", "⟨")
    CreateHotstring("*", "$angle.l.curly$", "⧼")
    CreateHotstring("*", "$angle.l.dot$", "⦑")
    CreateHotstring("*", "$angle.l.double$", "⟪")
    CreateHotstring("*", "$angle.r$", "⟩")
    CreateHotstring("*", "$angle.r.curly$", "⧽")
    CreateHotstring("*", "$angle.r.dot$", "⦒")
    CreateHotstring("*", "$angle.r.double$", "⟫")
    CreateHotstring("*", "$angle.acute$", "⦟")
    CreateHotstring("*", "$angle.arc$", "∡")
    CreateHotstring("*", "$angle.arc.rev$", "⦛")
    CreateHotstring("*", "$angle.azimuth$", "⍼")
    CreateHotstring("*", "$angle.oblique$", "⦦")
    CreateHotstring("*", "$angle.rev$", "⦣")
    CreateHotstring("*", "$angle.right$", "∟")
    CreateHotstring("*", "$angle.right.rev$", "⯾")
    CreateHotstring("*", "$angle.right.arc$", "⊾")
    CreateHotstring("*", "$angle.right.dot$", "⦝")
    CreateHotstring("*", "$angle.right.sq$", "⦜")
    CreateHotstring("*", "$angle.s$", "⦞")
    CreateHotstring("*", "$angle.spatial$", "⟀")
    CreateHotstring("*", "$angle.spheric$", "∢")
    CreateHotstring("*", "$angle.spheric.rev$", "⦠")
    CreateHotstring("*", "$angle.spheric.t$", "⦡")
    CreateHotstring("*", "$angle.spheric.top$", "⦡")
    CreateHotstring("*", "$angzarr$", "⍼")
    CreateHotstring("*", "$parallel$", "∥")
    CreateHotstring("*", "$parallel.struck$", "⫲")
    CreateHotstring("*", "$parallel.o$", "⦷")
    CreateHotstring("*", "$parallel.circle$", "⦷")
    CreateHotstring("*", "$parallel.eq$", "⋕")
    CreateHotstring("*", "$parallel.equiv$", "⩨")
    CreateHotstring("*", "$parallel.not$", "∦")
    CreateHotstring("*", "$parallel.slanted.eq$", "⧣")
    CreateHotstring("*", "$parallel.slanted.eq.tilde$", "⧤")
    CreateHotstring("*", "$parallel.slanted.equiv$", "⧥")
    CreateHotstring("*", "$parallel.tilde$", "⫳")
    CreateHotstring("*", "$perp$", "⟂")
    CreateHotstring("*", "$perp.o$", "⦹")
    CreateHotstring("*", "$perp.circle$", "⦹")

    ; === Astronomical ===
    CreateHotstring("*", "$earth$", "🜨")
    CreateHotstring("*", "$earth.alt$", "♁")
    CreateHotstring("*", "$jupiter$", "♃")
    CreateHotstring("*", "$mars$", "♂")
    CreateHotstring("*", "$mercury$", "☿")
    CreateHotstring("*", "$neptune$", "♆")
    CreateHotstring("*", "$neptune.alt$", "⯉")
    CreateHotstring("*", "$saturn$", "♄")
    CreateHotstring("*", "$sun$", "☉")
    CreateHotstring("*", "$uranus$", "⛢")
    CreateHotstring("*", "$uranus.alt$", "♅")
    CreateHotstring("*", "$venus$", "♀")

    ; === Miscellaneous Technical ===
    CreateHotstring("*", "$diameter$", "⌀")
    CreateHotstring("*", "$interleave$", "⫴")
    CreateHotstring("*", "$interleave.big$", "⫼")
    CreateHotstring("*", "$interleave.struck$", "⫵")
    CreateHotstring("*", "$join$", "⨝")
    CreateHotstring("*", "$join.r$", "⟖")
    CreateHotstring("*", "$join.l$", "⟕")
    CreateHotstring("*", "$join.l.r$", "⟗")
    ; Hourglass
    CreateHotstring("*", "$hourglass.stroked$", "⧖")
    CreateHotstring("*", "$hourglass.filled$", "⧗")
    CreateHotstring("*", "$degree$", "°")
    CreateHotstring("*", "$smash$", "⨳")
    ; Power
    CreateHotstring("*", "$power.standby$", "⏻")
    CreateHotstring("*", "$power.on$", "⏽")
    CreateHotstring("*", "$power.off$", "⭘")
    CreateHotstring("*", "$power.on.off$", "⏼")
    CreateHotstring("*", "$power.sleep$", "⏾")
    CreateHotstring("*", "$smile$", "⌣")
    CreateHotstring("*", "$frown$", "⌢")

    ; === Currency ===
    CreateHotstring("*", "$afghani$", "؋")
    CreateHotstring("*", "$baht$", "฿")
    CreateHotstring("*", "$bitcoin$", "₿")
    CreateHotstring("*", "$cedi$", "₵")
    CreateHotstring("*", "$cent$", "¢")
    CreateHotstring("*", "$currency$", "¤")
    CreateHotstring("*", "$dollar$", "$")
    CreateHotstring("*", "$dong$", "₫")
    CreateHotstring("*", "$dorome$", "߾")
    CreateHotstring("*", "$dram$", "֏")
    CreateHotstring("*", "$euro$", "€")
    CreateHotstring("*", "$franc$", "₣")
    CreateHotstring("*", "$guarani$", "₲")
    CreateHotstring("*", "$hryvnia$", "₴")
    CreateHotstring("*", "$kip$", "₭")
    CreateHotstring("*", "$lari$", "₾")
    CreateHotstring("*", "$lira$", "₺")
    CreateHotstring("*", "$manat$", "₼")
    CreateHotstring("*", "$naira$", "₦")
    CreateHotstring("*", "$pataca$", "$")
    CreateHotstring("*", "$peso$", "$")
    CreateHotstring("*", "$peso.philippine$", "₱")
    CreateHotstring("*", "$pound$", "£")
    CreateHotstring("*", "$riel$", "៛")
    CreateHotstring("*", "$ruble$", "₽")
    ; Rupee
    CreateHotstring("*", "$rupee.indian$", "₹")
    CreateHotstring("*", "$rupee.generic$", "₨")
    CreateHotstring("*", "$rupee.tamil$", "௹")
    CreateHotstring("*", "$rupee.wancho$", "𞋿")
    CreateHotstring("*", "$shekel$", "₪")
    CreateHotstring("*", "$som$", "⃀")
    CreateHotstring("*", "$taka$", "৳")
    CreateHotstring("*", "$taman$", "߿")
    CreateHotstring("*", "$tenge$", "₸")
    CreateHotstring("*", "$togrog$", "₮")
    CreateHotstring("*", "$won$", "₩")
    CreateHotstring("*", "$yen$", "¥")
    CreateHotstring("*", "$yuan$", "¥")

    ; === Miscellaneous ===
    CreateHotstring("*", "$ballot$", "☐")
    CreateHotstring("*", "$ballot.cross$", "☒")
    CreateHotstring("*", "$ballot.check$", "☑")
    CreateHotstring("*", "$ballot.check.heavy$", "🗹")
    CreateHotstring("*", "$checkmark$", "✓")
    CreateHotstring("*", "$checkmark.light$", "🗸")
    CreateHotstring("*", "$checkmark.heavy$", "✔")
    CreateHotstring("*", "$crossmark$", "✗")
    CreateHotstring("*", "$crossmark.heavy$", "✘")
    CreateHotstring("*", "$floral$", "❦")
    CreateHotstring("*", "$floral.l$", "☙")
    CreateHotstring("*", "$floral.r$", "❧")
    CreateHotstring("*", "$refmark$", "※")
    CreateHotstring("*", "$cc$", "🅭")
    CreateHotstring("*", "$cc.by$", "🅯")
    CreateHotstring("*", "$cc.nc$", "🄏")
    CreateHotstring("*", "$cc.nd$", "⊜")
    CreateHotstring("*", "$cc.public$", "🅮")
    CreateHotstring("*", "$cc.sa$", "🄎")
    CreateHotstring("*", "$cc.zero$", "🄍")
    CreateHotstring("*", "$copyright$", "©")
    CreateHotstring("*", "$copyright.sound$", "℗")
    CreateHotstring("*", "$copyleft$", "🄯")
    CreateHotstring("*", "$trademark$", "™")
    CreateHotstring("*", "$trademark.registered$", "®")
    CreateHotstring("*", "$trademark.service$", "℠")
    CreateHotstring("*", "$maltese$", "✠")
    ; Suit
    CreateHotstring("*", "$suit.club.filled$", "♣")
    CreateHotstring("*", "$suit.club.stroked$", "♧")
    CreateHotstring("*", "$suit.diamond.filled$", "♦")
    CreateHotstring("*", "$suit.diamond.stroked$", "♢")
    CreateHotstring("*", "$suit.heart.filled$", "♥")
    CreateHotstring("*", "$suit.heart.stroked$", "♡")
    CreateHotstring("*", "$suit.spade.filled$", "♠")
    CreateHotstring("*", "$suit.spade.stroked$", "♤")

    ; === Music ===
    ; Note
    CreateHotstring("*", "$note.up$", "🎜")
    CreateHotstring("*", "$note.down$", "🎝")
    CreateHotstring("*", "$note.whole$", "𝅝")
    CreateHotstring("*", "$note.half$", "𝅗𝅥")
    CreateHotstring("*", "$note.quarter$", "𝅘𝅥")
    CreateHotstring("*", "$note.quarter.alt$", "♩")
    CreateHotstring("*", "$note.eighth$", "𝅘𝅥𝅮")
    CreateHotstring("*", "$note.eighth.alt$", "♪")
    CreateHotstring("*", "$note.eighth.beamed$", "♫")
    CreateHotstring("*", "$note.sixteenth$", "𝅘𝅥𝅯")
    CreateHotstring("*", "$note.sixteenth.beamed$", "♬")
    CreateHotstring("*", "$note.grace$", "𝆕")
    CreateHotstring("*", "$note.grace.slash$", "𝆔")
    ; Rest
    CreateHotstring("*", "$rest.whole$", "𝄻")
    CreateHotstring("*", "$rest.multiple$", "𝄺")
    CreateHotstring("*", "$rest.multiple.measure$", "𝄩")
    CreateHotstring("*", "$rest.half$", "𝄼")
    CreateHotstring("*", "$rest.quarter$", "𝄽")
    CreateHotstring("*", "$rest.eighth$", "𝄾")
    CreateHotstring("*", "$rest.sixteenth$", "𝄿")
    CreateHotstring("*", "$natural$", "♮")
    CreateHotstring("*", "$natural.t$", "𝄮")
    CreateHotstring("*", "$natural.b$", "𝄯")
    CreateHotstring("*", "$flat$", "♭")
    CreateHotstring("*", "$flat.t$", "𝄬")
    CreateHotstring("*", "$flat.b$", "𝄭")
    CreateHotstring("*", "$flat.double$", "𝄫")
    CreateHotstring("*", "$flat.quarter$", "𝄳")
    CreateHotstring("*", "$sharp$", "♯")
    CreateHotstring("*", "$sharp.t$", "𝄰")
    CreateHotstring("*", "$sharp.b$", "𝄱")
    CreateHotstring("*", "$sharp.double$", "𝄪")
    CreateHotstring("*", "$sharp.quarter$", "𝄲")

    ; === Shapes ===
    CreateHotstring("*", "$bullet$", "•")
    CreateHotstring("*", "$bullet.op$", "∙")
    CreateHotstring("*", "$bullet.o$", "⦿")
    CreateHotstring("*", "$bullet.stroked$", "◦")
    CreateHotstring("*", "$bullet.stroked.o$", "⦾")
    CreateHotstring("*", "$bullet.hole$", "◘")
    CreateHotstring("*", "$bullet.hyph$", "⁃")
    CreateHotstring("*", "$bullet.tri$", "‣")
    CreateHotstring("*", "$bullet.l$", "⁌")
    CreateHotstring("*", "$bullet.r$", "⁍")
    ; Circle
    CreateHotstring("*", "$circle.stroked$", "○")
    CreateHotstring("*", "$circle.stroked.tiny$", "∘")
    CreateHotstring("*", "$circle.stroked.small$", "⚬")
    CreateHotstring("*", "$circle.stroked.big$", "◯")
    CreateHotstring("*", "$circle.filled$", "●")
    CreateHotstring("*", "$circle.filled.tiny$", "⦁")
    CreateHotstring("*", "$circle.filled.small$", "∙")
    CreateHotstring("*", "$circle.filled.big$", "⬤")
    CreateHotstring("*", "$circle.dotted$", "◌")
    CreateHotstring("*", "$circle.nested$", "⊚")
    ; Ellipse
    CreateHotstring("*", "$ellipse.stroked.h$", "⬭")
    CreateHotstring("*", "$ellipse.stroked.v$", "⬯")
    CreateHotstring("*", "$ellipse.filled.h$", "⬬")
    CreateHotstring("*", "$ellipse.filled.v$", "⬮")
    ; Triangle
    CreateHotstring("*", "$triangle.stroked.t$", "△")
    CreateHotstring("*", "$triangle.stroked.b$", "▽")
    CreateHotstring("*", "$triangle.stroked.r$", "▷")
    CreateHotstring("*", "$triangle.stroked.l$", "◁")
    CreateHotstring("*", "$triangle.stroked.bl$", "◺")
    CreateHotstring("*", "$triangle.stroked.br$", "◿")
    CreateHotstring("*", "$triangle.stroked.tl$", "◸")
    CreateHotstring("*", "$triangle.stroked.tr$", "◹")
    CreateHotstring("*", "$triangle.stroked.small.t$", "▵")
    CreateHotstring("*", "$triangle.stroked.small.b$", "▿")
    CreateHotstring("*", "$triangle.stroked.small.r$", "▹")
    CreateHotstring("*", "$triangle.stroked.small.l$", "◃")
    CreateHotstring("*", "$triangle.stroked.rounded$", "🛆")
    CreateHotstring("*", "$triangle.stroked.nested$", "⟁")
    CreateHotstring("*", "$triangle.stroked.dot$", "◬")
    CreateHotstring("*", "$triangle.filled.t$", "▲")
    CreateHotstring("*", "$triangle.filled.b$", "▼")
    CreateHotstring("*", "$triangle.filled.r$", "▶")
    CreateHotstring("*", "$triangle.filled.l$", "◀")
    CreateHotstring("*", "$triangle.filled.bl$", "◣")
    CreateHotstring("*", "$triangle.filled.br$", "◢")
    CreateHotstring("*", "$triangle.filled.tl$", "◤")
    CreateHotstring("*", "$triangle.filled.tr$", "◥")
    CreateHotstring("*", "$triangle.filled.small.t$", "▴")
    CreateHotstring("*", "$triangle.filled.small.b$", "▾")
    CreateHotstring("*", "$triangle.filled.small.r$", "▸")
    CreateHotstring("*", "$triangle.filled.small.l$", "◂")
    ; Square
    CreateHotstring("*", "$square.stroked$", "□")
    CreateHotstring("*", "$square.stroked.tiny$", "▫")
    CreateHotstring("*", "$square.stroked.small$", "◽")
    CreateHotstring("*", "$square.stroked.medium$", "◻")
    CreateHotstring("*", "$square.stroked.big$", "⬜")
    CreateHotstring("*", "$square.stroked.dotted$", "⬚")
    CreateHotstring("*", "$square.stroked.rounded$", "▢")
    CreateHotstring("*", "$square.filled$", "■")
    CreateHotstring("*", "$square.filled.tiny$", "▪")
    CreateHotstring("*", "$square.filled.small$", "◾")
    CreateHotstring("*", "$square.filled.medium$", "◼")
    CreateHotstring("*", "$square.filled.big$", "⬛")
    ; Rect
    CreateHotstring("*", "$rect.stroked.h$", "▭")
    CreateHotstring("*", "$rect.stroked.v$", "▯")
    CreateHotstring("*", "$rect.filled.h$", "▬")
    CreateHotstring("*", "$rect.filled.v$", "▮")
    ; Penta
    CreateHotstring("*", "$penta.stroked$", "⬠")
    CreateHotstring("*", "$penta.filled$", "⬟")
    ; Hexa
    CreateHotstring("*", "$hexa.stroked$", "⬡")
    CreateHotstring("*", "$hexa.filled$", "⬢")
    ; Diamond
    CreateHotstring("*", "$diamond.stroked$", "◇")
    CreateHotstring("*", "$diamond.stroked.small$", "⋄")
    CreateHotstring("*", "$diamond.stroked.medium$", "⬦")
    CreateHotstring("*", "$diamond.stroked.dot$", "⟐")
    CreateHotstring("*", "$diamond.filled$", "◆")
    CreateHotstring("*", "$diamond.filled.medium$", "⬥")
    CreateHotstring("*", "$diamond.filled.small$", "⬩")
    ; Lozenge
    CreateHotstring("*", "$lozenge.stroked$", "◊")
    CreateHotstring("*", "$lozenge.stroked.small$", "⬫")
    CreateHotstring("*", "$lozenge.stroked.medium$", "⬨")
    CreateHotstring("*", "$lozenge.filled$", "⧫")
    CreateHotstring("*", "$lozenge.filled.small$", "⬪")
    CreateHotstring("*", "$lozenge.filled.medium$", "⬧")
    ; Parallelogram
    CreateHotstring("*", "$parallelogram.stroked$", "▱")
    CreateHotstring("*", "$parallelogram.filled$", "▰")
    ; Star
    CreateHotstring("*", "$star.op$", "⋆")
    CreateHotstring("*", "$star.stroked$", "☆")
    CreateHotstring("*", "$star.filled$", "★")

    ; === Arrows, harpoons, and tacks ===
    ; Arrow
    CreateHotstring("*", "$arrow.r$", "→")
    CreateHotstring("*", "$arrow.r.long.bar$", "⟼")
    CreateHotstring("*", "$arrow.r.bar$", "↦")
    CreateHotstring("*", "$arrow.r.curve$", "⤷")
    CreateHotstring("*", "$arrow.r.turn$", "⮎")
    CreateHotstring("*", "$arrow.r.dashed$", "⇢")
    CreateHotstring("*", "$arrow.r.dotted$", "⤑")
    CreateHotstring("*", "$arrow.r.double$", "⇒")
    CreateHotstring("*", "$arrow.r.double.bar$", "⤇")
    CreateHotstring("*", "$arrow.r.double.long$", "⟹")
    CreateHotstring("*", "$arrow.r.double.long.bar$", "⟾")
    CreateHotstring("*", "$arrow.r.double.not$", "⇏")
    CreateHotstring("*", "$arrow.r.double.struck$", "⤃")
    CreateHotstring("*", "$arrow.r.filled$", "➡")
    CreateHotstring("*", "$arrow.r.hook$", "↪")
    CreateHotstring("*", "$arrow.r.long$", "⟶")
    CreateHotstring("*", "$arrow.r.long.squiggly$", "⟿")
    CreateHotstring("*", "$arrow.r.loop$", "↬")
    CreateHotstring("*", "$arrow.r.not$", "↛")
    CreateHotstring("*", "$arrow.r.quad$", "⭆")
    CreateHotstring("*", "$arrow.r.squiggly$", "⇝")
    CreateHotstring("*", "$arrow.r.stop$", "⇥")
    CreateHotstring("*", "$arrow.r.stroked$", "⇨")
    CreateHotstring("*", "$arrow.r.struck$", "⇸")
    CreateHotstring("*", "$arrow.r.dstruck$", "⇻")
    CreateHotstring("*", "$arrow.r.tail$", "↣")
    CreateHotstring("*", "$arrow.r.tail.struck$", "⤔")
    CreateHotstring("*", "$arrow.r.tail.dstruck$", "⤕")
    CreateHotstring("*", "$arrow.r.tilde$", "⥲")
    CreateHotstring("*", "$arrow.r.triple$", "⇛")
    CreateHotstring("*", "$arrow.r.twohead$", "↠")
    CreateHotstring("*", "$arrow.r.twohead.bar$", "⤅")
    CreateHotstring("*", "$arrow.r.twohead.struck$", "⤀")
    CreateHotstring("*", "$arrow.r.twohead.dstruck$", "⤁")
    CreateHotstring("*", "$arrow.r.twohead.tail$", "⤖")
    CreateHotstring("*", "$arrow.r.twohead.tail.struck$", "⤗")
    CreateHotstring("*", "$arrow.r.twohead.tail.dstruck$", "⤘")
    CreateHotstring("*", "$arrow.r.open$", "⇾")
    CreateHotstring("*", "$arrow.r.wave$", "↝")
    CreateHotstring("*", "$arrow.l$", "←")
    CreateHotstring("*", "$arrow.l.bar$", "↤")
    CreateHotstring("*", "$arrow.l.curve$", "⤶")
    CreateHotstring("*", "$arrow.l.turn$", "⮌")
    CreateHotstring("*", "$arrow.l.dashed$", "⇠")
    CreateHotstring("*", "$arrow.l.dotted$", "⬸")
    CreateHotstring("*", "$arrow.l.double$", "⇐")
    CreateHotstring("*", "$arrow.l.double.bar$", "⤆")
    CreateHotstring("*", "$arrow.l.double.long$", "⟸")
    CreateHotstring("*", "$arrow.l.double.long.bar$", "⟽")
    CreateHotstring("*", "$arrow.l.double.not$", "⇍")
    CreateHotstring("*", "$arrow.l.double.struck$", "⤂")
    CreateHotstring("*", "$arrow.l.filled$", "⬅")
    CreateHotstring("*", "$arrow.l.hook$", "↩")
    CreateHotstring("*", "$arrow.l.long$", "⟵")
    CreateHotstring("*", "$arrow.l.long.bar$", "⟻")
    CreateHotstring("*", "$arrow.l.long.squiggly$", "⬳")
    CreateHotstring("*", "$arrow.l.loop$", "↫")
    CreateHotstring("*", "$arrow.l.not$", "↚")
    CreateHotstring("*", "$arrow.l.quad$", "⭅")
    CreateHotstring("*", "$arrow.l.squiggly$", "⇜")
    CreateHotstring("*", "$arrow.l.stop$", "⇤")
    CreateHotstring("*", "$arrow.l.stroked$", "⇦")
    CreateHotstring("*", "$arrow.l.struck$", "⇷")
    CreateHotstring("*", "$arrow.l.dstruck$", "⇺")
    CreateHotstring("*", "$arrow.l.tail$", "↢")
    CreateHotstring("*", "$arrow.l.tail.struck$", "⬹")
    CreateHotstring("*", "$arrow.l.tail.dstruck$", "⬺")
    CreateHotstring("*", "$arrow.l.tilde$", "⭉")
    CreateHotstring("*", "$arrow.l.triple$", "⇚")
    CreateHotstring("*", "$arrow.l.twohead$", "↞")
    CreateHotstring("*", "$arrow.l.twohead.bar$", "⬶")
    CreateHotstring("*", "$arrow.l.twohead.struck$", "⬴")
    CreateHotstring("*", "$arrow.l.twohead.dstruck$", "⬵")
    CreateHotstring("*", "$arrow.l.twohead.tail$", "⬻")
    CreateHotstring("*", "$arrow.l.twohead.tail.struck$", "⬼")
    CreateHotstring("*", "$arrow.l.twohead.tail.dstruck$", "⬽")
    CreateHotstring("*", "$arrow.l.open$", "⇽")
    CreateHotstring("*", "$arrow.l.wave$", "↜")
    CreateHotstring("*", "$arrow.t$", "↑")
    CreateHotstring("*", "$arrow.t.bar$", "↥")
    CreateHotstring("*", "$arrow.t.curve$", "⤴")
    CreateHotstring("*", "$arrow.t.turn$", "⮍")
    CreateHotstring("*", "$arrow.t.dashed$", "⇡")
    CreateHotstring("*", "$arrow.t.double$", "⇑")
    CreateHotstring("*", "$arrow.t.filled$", "⬆")
    CreateHotstring("*", "$arrow.t.quad$", "⟰")
    CreateHotstring("*", "$arrow.t.stop$", "⤒")
    CreateHotstring("*", "$arrow.t.stroked$", "⇧")
    CreateHotstring("*", "$arrow.t.struck$", "⤉")
    CreateHotstring("*", "$arrow.t.dstruck$", "⇞")
    CreateHotstring("*", "$arrow.t.triple$", "⤊")
    CreateHotstring("*", "$arrow.t.twohead$", "↟")
    CreateHotstring("*", "$arrow.b$", "↓")
    CreateHotstring("*", "$arrow.b.bar$", "↧")
    CreateHotstring("*", "$arrow.b.curve$", "⤵")
    CreateHotstring("*", "$arrow.b.turn$", "⮏")
    CreateHotstring("*", "$arrow.b.dashed$", "⇣")
    CreateHotstring("*", "$arrow.b.double$", "⇓")
    CreateHotstring("*", "$arrow.b.filled$", "⬇")
    CreateHotstring("*", "$arrow.b.quad$", "⟱")
    CreateHotstring("*", "$arrow.b.stop$", "⤓")
    CreateHotstring("*", "$arrow.b.stroked$", "⇩")
    CreateHotstring("*", "$arrow.b.struck$", "⤈")
    CreateHotstring("*", "$arrow.b.dstruck$", "⇟")
    CreateHotstring("*", "$arrow.b.triple$", "⤋")
    CreateHotstring("*", "$arrow.b.twohead$", "↡")
    CreateHotstring("*", "$arrow.l.r$", "↔")
    CreateHotstring("*", "$arrow.l.r.double$", "⇔")
    CreateHotstring("*", "$arrow.l.r.double.long$", "⟺")
    CreateHotstring("*", "$arrow.l.r.double.not$", "⇎")
    CreateHotstring("*", "$arrow.l.r.double.struck$", "⤄")
    CreateHotstring("*", "$arrow.l.r.filled$", "⬌")
    CreateHotstring("*", "$arrow.l.r.long$", "⟷")
    CreateHotstring("*", "$arrow.l.r.not$", "↮")
    CreateHotstring("*", "$arrow.l.r.stroked$", "⬄")
    CreateHotstring("*", "$arrow.l.r.struck$", "⇹")
    CreateHotstring("*", "$arrow.l.r.dstruck$", "⇼")
    CreateHotstring("*", "$arrow.l.r.open$", "⇿")
    CreateHotstring("*", "$arrow.l.r.wave$", "↭")
    CreateHotstring("*", "$arrow.t.b$", "↕")
    CreateHotstring("*", "$arrow.t.b.double$", "⇕")
    CreateHotstring("*", "$arrow.t.b.filled$", "⬍")
    CreateHotstring("*", "$arrow.t.b.stroked$", "⇳")
    CreateHotstring("*", "$arrow.tr$", "↗")
    CreateHotstring("*", "$arrow.tr.double$", "⇗")
    CreateHotstring("*", "$arrow.tr.filled$", "⬈")
    CreateHotstring("*", "$arrow.tr.hook$", "⤤")
    CreateHotstring("*", "$arrow.tr.stroked$", "⬀")
    CreateHotstring("*", "$arrow.br$", "↘")
    CreateHotstring("*", "$arrow.br.double$", "⇘")
    CreateHotstring("*", "$arrow.br.filled$", "⬊")
    CreateHotstring("*", "$arrow.br.hook$", "⤥")
    CreateHotstring("*", "$arrow.br.stroked$", "⬂")
    CreateHotstring("*", "$arrow.tl$", "↖")
    CreateHotstring("*", "$arrow.tl.double$", "⇖")
    CreateHotstring("*", "$arrow.tl.filled$", "⬉")
    CreateHotstring("*", "$arrow.tl.hook$", "⤣")
    CreateHotstring("*", "$arrow.tl.stroked$", "⬁")
    CreateHotstring("*", "$arrow.bl$", "↙")
    CreateHotstring("*", "$arrow.bl.double$", "⇙")
    CreateHotstring("*", "$arrow.bl.filled$", "⬋")
    CreateHotstring("*", "$arrow.bl.hook$", "⤦")
    CreateHotstring("*", "$arrow.bl.stroked$", "⬃")
    CreateHotstring("*", "$arrow.tl.br$", "⤡")
    CreateHotstring("*", "$arrow.tr.bl$", "⥢")
    CreateHotstring("*", "$arrow.ccw$", "↺")
    CreateHotstring("*", "$arrow.ccw.half$", "↶")
    CreateHotstring("*", "$arrow.cw$", "↻")
    CreateHotstring("*", "$arrow.cw.half$", "↷")
    CreateHotstring("*", "$arrow.zigzag$", "↯")
    ; Arrows
    CreateHotstring("*", "$arrows.rr$", "⇉")
    CreateHotstring("*", "$arrows.ll$", "⇇")
    CreateHotstring("*", "$arrows.tt$", "⇈")
    CreateHotstring("*", "$arrows.bb$", "⇊")
    CreateHotstring("*", "$arrows.lr$", "⇆")
    CreateHotstring("*", "$arrows.lr.stop$", "↹")
    CreateHotstring("*", "$arrows.rl$", "⇄")
    CreateHotstring("*", "$arrows.tb$", "⇅")
    CreateHotstring("*", "$arrows.bt$", "⇵")
    CreateHotstring("*", "$arrows.rrr$", "⇶")
    CreateHotstring("*", "$arrows.lll$", "⬱")
    ; Arrowhead
    CreateHotstring("*", "$arrowhead.t$", "⌃")
    CreateHotstring("*", "$arrowhead.b$", "⌄")
    ; Harpoon
    CreateHotstring("*", "$harpoon.rt$", "⇀")
    CreateHotstring("*", "$harpoon.rt.bar$", "⥛")
    CreateHotstring("*", "$harpoon.rt.stop$", "⥓")
    CreateHotstring("*", "$harpoon.rb$", "⇁")
    CreateHotstring("*", "$harpoon.rb.bar$", "⥟")
    CreateHotstring("*", "$harpoon.rb.stop$", "⥗")
    CreateHotstring("*", "$harpoon.lt$", "↼")
    CreateHotstring("*", "$harpoon.lt.bar$", "⥚")
    CreateHotstring("*", "$harpoon.lt.stop$", "⥒")
    CreateHotstring("*", "$harpoon.lb$", "↽")
    CreateHotstring("*", "$harpoon.lb.bar$", "⥞")
    CreateHotstring("*", "$harpoon.lb.stop$", "⥖")
    CreateHotstring("*", "$harpoon.tl$", "↿")
    CreateHotstring("*", "$harpoon.tl.bar$", "⥠")
    CreateHotstring("*", "$harpoon.tl.stop$", "⥘")
    CreateHotstring("*", "$harpoon.tr$", "↾")
    CreateHotstring("*", "$harpoon.tr.bar$", "⥜")
    CreateHotstring("*", "$harpoon.tr.stop$", "⥔")
    CreateHotstring("*", "$harpoon.bl$", "⇃")
    CreateHotstring("*", "$harpoon.bl.bar$", "⥡")
    CreateHotstring("*", "$harpoon.bl.stop$", "⥙")
    CreateHotstring("*", "$harpoon.br$", "⇂")
    CreateHotstring("*", "$harpoon.br.bar$", "⥝")
    CreateHotstring("*", "$harpoon.br.stop$", "⥕")
    CreateHotstring("*", "$harpoon.lt.rt$", "⥎")
    CreateHotstring("*", "$harpoon.lb.rb$", "⥐")
    CreateHotstring("*", "$harpoon.lb.rt$", "⥋")
    CreateHotstring("*", "$harpoon.lt.rb$", "⥊")
    CreateHotstring("*", "$harpoon.tl.bl$", "⥑")
    CreateHotstring("*", "$harpoon.tr.br$", "⥏")
    CreateHotstring("*", "$harpoon.tl.br$", "⥍")
    CreateHotstring("*", "$harpoon.tr.bl$", "⥌")
    ; Harpoons
    CreateHotstring("*", "$harpoons.rtrb$", "⥤")
    CreateHotstring("*", "$harpoons.blbr$", "⥥")
    CreateHotstring("*", "$harpoons.bltr$", "⥯")
    CreateHotstring("*", "$harpoons.lbrb$", "⥧")
    CreateHotstring("*", "$harpoons.ltlb$", "⥢")
    CreateHotstring("*", "$harpoons.ltrb$", "⇋")
    CreateHotstring("*", "$harpoons.ltrt$", "⥦")
    CreateHotstring("*", "$harpoons.rblb$", "⥩")
    CreateHotstring("*", "$harpoons.rtlb$", "⇌")
    CreateHotstring("*", "$harpoons.rtlt$", "⥨")
    CreateHotstring("*", "$harpoons.tlbr$", "⥮")
    CreateHotstring("*", "$harpoons.tltr$", "⥣")
    ; Tack
    CreateHotstring("*", "$tack.r$", "⊢")
    CreateHotstring("*", "$tack.r.not$", "⊬")
    CreateHotstring("*", "$tack.r.long$", "⟝")
    CreateHotstring("*", "$tack.r.short$", "⊦")
    CreateHotstring("*", "$tack.r.double$", "⊨")
    CreateHotstring("*", "$tack.r.double.not$", "⊭")
    CreateHotstring("*", "$tack.l$", "⊣")
    CreateHotstring("*", "$tack.l.long$", "⟞")
    CreateHotstring("*", "$tack.l.short$", "⫞")
    CreateHotstring("*", "$tack.l.double$", "⫤")
    CreateHotstring("*", "$tack.t$", "⊥")
    CreateHotstring("*", "$tack.t.big$", "⟘")
    CreateHotstring("*", "$tack.t.double$", "⫫")
    CreateHotstring("*", "$tack.t.short$", "⫠")
    CreateHotstring("*", "$tack.b$", "⊤")
    CreateHotstring("*", "$tack.b.big$", "⟙")
    CreateHotstring("*", "$tack.b.double$", "⫪")
    CreateHotstring("*", "$tack.b.short$", "⫟")
    CreateHotstring("*", "$tack.l.r$", "⟛")

    ; === Lowercase Greek ===
    CreateHotstring("*", "$alpha$", "α")
    CreateHotstring("*", "$beta$", "β")
    CreateHotstring("*", "$beta.alt$", "ϐ")
    CreateHotstring("*", "$chi$", "χ")
    CreateHotstring("*", "$delta$", "δ")
    CreateHotstring("*", "$digamma$", "ϝ")
    CreateHotstring("*", "$epsilon$", "ε")
    CreateHotstring("*", "$epsilon.alt$", "ϵ")
    CreateHotstring("*", "$epsilon.alt.rev$", "϶")
    CreateHotstring("*", "$eta$", "η")
    CreateHotstring("*", "$gamma$", "γ")
    CreateHotstring("*", "$iota$", "ι")
    CreateHotstring("*", "$iota.inv$", "℩")
    CreateHotstring("*", "$kai$", "ϗ")
    CreateHotstring("*", "$kappa$", "κ")
    CreateHotstring("*", "$kappa.alt$", "ϰ")
    CreateHotstring("*", "$lambda$", "λ")
    CreateHotstring("*", "$mu$", "μ")
    CreateHotstring("*", "$nu$", "ν")
    CreateHotstring("*", "$omega$", "ω")
    CreateHotstring("*", "$omicron$", "ο")
    CreateHotstring("*", "$phi$", "φ")
    CreateHotstring("*", "$phi.alt$", "ϕ")
    CreateHotstring("*", "$pi$", "π")
    CreateHotstring("*", "$pi.alt$", "ϖ")
    CreateHotstring("*", "$psi$", "ψ")
    CreateHotstring("*", "$rho$", "ρ")
    CreateHotstring("*", "$rho.alt$", "ϱ")
    CreateHotstring("*", "$sigma$", "σ")
    CreateHotstring("*", "$sigma.alt$", "ς")
    CreateHotstring("*", "$tau$", "τ")
    CreateHotstring("*", "$theta$", "θ")
    CreateHotstring("*", "$theta.alt$", "ϑ")
    CreateHotstring("*", "$upsilon$", "υ")
    CreateHotstring("*", "$xi$", "ξ")
    CreateHotstring("*", "$zeta$", "ζ")

    ; === Uppercase Greek ===
    CreateHotstring("*", "$Alpha$", "Α")
    CreateHotstring("*", "$Beta$", "Β")
    CreateHotstring("*", "$Chi$", "Χ")
    CreateHotstring("*", "$Delta$", "Δ")
    CreateHotstring("*", "$Digamma$", "Ϝ")
    CreateHotstring("*", "$Epsilon$", "Ε")
    CreateHotstring("*", "$Eta$", "Η")
    CreateHotstring("*", "$Gamma$", "Γ")
    CreateHotstring("*", "$Iota$", "Ι")
    CreateHotstring("*", "$Kai$", "Ϗ")
    CreateHotstring("*", "$Kappa$", "Κ")
    CreateHotstring("*", "$Lambda$", "Λ")
    CreateHotstring("*", "$Mu$", "Μ")
    CreateHotstring("*", "$Nu$", "Ν")
    CreateHotstring("*", "$Omega$", "Ω")
    CreateHotstring("*", "$Omega.inv$", "℧")
    CreateHotstring("*", "$Omicron$", "Ο")
    CreateHotstring("*", "$Phi$", "Φ")
    CreateHotstring("*", "$Pi$", "Π")
    CreateHotstring("*", "$Psi$", "Ψ")
    CreateHotstring("*", "$Rho$", "Ρ")
    CreateHotstring("*", "$Sigma$", "Σ")
    CreateHotstring("*", "$Tau$", "Τ")
    CreateHotstring("*", "$Theta$", "Θ")
    CreateHotstring("*", "$Theta.alt$", "ϴ")
    CreateHotstring("*", "$Upsilon$", "Υ")
    CreateHotstring("*", "$Xi$", "Ξ")
    CreateHotstring("*", "$Zeta$", "Ζ")

    ; === Lowercase Cyrillic ===
    CreateHotstring("*", "$sha$", "ш")

    ; === Uppercase Cyrillic ===
    CreateHotstring("*", "$Sha$", "Ш")

    ; === Hebrew ===
    CreateHotstring("*", "$aleph$", "א")
    CreateHotstring("*", "$alef$", "א")
    CreateHotstring("*", "$beth$", "ב")
    CreateHotstring("*", "$bet$", "ב")
    CreateHotstring("*", "$gimel$", "ג")
    CreateHotstring("*", "$gimmel$", "ג")
    CreateHotstring("*", "$daleth$", "ד")
    CreateHotstring("*", "$dalet$", "ד")
    CreateHotstring("*", "$shin$", "ש")

    ; === Double-struck ===
    CreateHotstring("*", "$AA$", "𝔸")
    CreateHotstring("*", "$BB$", "𝔹")
    CreateHotstring("*", "$CC$", "ℂ")
    CreateHotstring("*", "$DD$", "𝔻")
    CreateHotstring("*", "$EE$", "𝔼")
    CreateHotstring("*", "$FF$", "𝔽")
    CreateHotstring("*", "$GG$", "𝔾")
    CreateHotstring("*", "$HH$", "ℍ")
    CreateHotstring("*", "$II$", "𝕀")
    CreateHotstring("*", "$JJ$", "𝕁")
    CreateHotstring("*", "$KK$", "𝕂")
    CreateHotstring("*", "$LL$", "𝕃")
    CreateHotstring("*", "$MM$", "𝕄")
    CreateHotstring("*", "$NN$", "ℕ")
    CreateHotstring("*", "$OO$", "𝕆")
    CreateHotstring("*", "$PP$", "ℙ")
    CreateHotstring("*", "$QQ$", "ℚ")
    CreateHotstring("*", "$RR$", "ℝ")
    CreateHotstring("*", "$SS$", "𝕊")
    CreateHotstring("*", "$TT$", "𝕋")
    CreateHotstring("*", "$UU$", "𝕌")
    CreateHotstring("*", "$VV$", "𝕍")
    CreateHotstring("*", "$WW$", "𝕎")
    CreateHotstring("*", "$XX$", "𝕏")
    CreateHotstring("*", "$YY$", "𝕐")
    CreateHotstring("*", "$ZZ$", "ℤ")

    ; === Miscellaneous letter-likes ===
    CreateHotstring("*", "$angstrom$", "Å")
    CreateHotstring("*", "$ell$", "ℓ")
    CreateHotstring("*", "$planck$", "ħ")
    CreateHotstring("*", "$planck.reduce$", "ħ")
    CreateHotstring("*", "$Re$", "ℜ")
    CreateHotstring("*", "$Im$", "ℑ")
    ; Dotless
    CreateHotstring("*", "$dotless.i$", "ı")
    CreateHotstring("*", "$dotless.j$", "ȷ")

    ; === Miscellany ===
    ; Die
    CreateHotstring("*", "$die.six$", "⚅")
    CreateHotstring("*", "$die.five$", "⚄")
    CreateHotstring("*", "$die.four$", "⚃")
    CreateHotstring("*", "$die.three$", "⚂")
    CreateHotstring("*", "$die.two$", "⚁")
    CreateHotstring("*", "$die.one$", "⚀")
    ; Errorbar
    CreateHotstring("*", "$errorbar.square.stroked$", "⧮")
    CreateHotstring("*", "$errorbar.square.filled$", "⧯")
    CreateHotstring("*", "$errorbar.diamond.stroked$", "⧰")
    CreateHotstring("*", "$errorbar.diamond.filled$", "⧱")
    CreateHotstring("*", "$errorbar.circle.stroked$", "⧲")
    CreateHotstring("*", "$errorbar.circle.filled$", "⧳")
    ; Gender
    CreateHotstring("*", "$gender.female$", "♀")
    CreateHotstring("*", "$gender.female.double$", "⚢")
    CreateHotstring("*", "$gender.female.male$", "⚤")
    CreateHotstring("*", "$gender.intersex$", "⚥")
    CreateHotstring("*", "$gender.male$", "♂")
    CreateHotstring("*", "$gender.male.double$", "⚣")
    CreateHotstring("*", "$gender.male.female$", "⚤")
    CreateHotstring("*", "$gender.male.stroke$", "⚦")
    CreateHotstring("*", "$gender.male.stroke.t$", "⚨")
    CreateHotstring("*", "$gender.male.stroke.r$", "⚩")
    CreateHotstring("*", "$gender.neuter$", "⚲")
    CreateHotstring("*", "$gender.trans$", "⚧")
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
