; drivers/autohotkey/lib/hotstring_engine.ahk

; ==============================================================================
; MODULE: Hotstring Engine
; DESCRIPTION:
; Core hotstring engine used by ErgoptiPlus: low-level send primitives,
; hotstring builders (case-insensitive and case-sensitive variants), and the
; shared ``HotstringHandler`` that performs the backspace/replace dance.
;
; FEATURES & RATIONALE:
; 1. Send primitives (``SendNewResult`` / ``SendFinalResult`` / ``SendInstant``)
;    wrap ``SendEvent`` / ``SendInput`` so the rest of the codebase never has
;    to worry about mode selection, nested hotstring triggering, or the
;    clipboard dance used by ``SendInstant`` for large payloads.
; 2. ``CreateHotstring`` and ``CreateCaseSensitiveHotstrings`` are the only two
;    public entry points every feature module should use to register a
;    hotstring — they guarantee consistent flags (``B0O``), a shared options
;    schema, and the Windows-11 Notepad workaround.
; 3. ``HotstringHandler`` centralises the replacement logic so adding a new
;    quirk (e.g. a new mis-triggering app) only touches one place.
; 4. ``GenerateUppercaseVariants`` / ``StrTitle`` / ``GetLastSentCharacterAt``
;    are shared text helpers kept close to the engine because every caller
;    sits either in this module or in a feature file that depends on it.
;
; DEPENDENCIES:
; The engine references the following globals/functions provided by the main
; ErgoptiPlus script: ``ScriptInformation`` (for the magic key), the
; ``UpdateLastSentCharacter`` function and its ``LastSentCharacters`` /
; ``LastSentCharacterKeyTime`` backing globals. AHK v2 resolves these across
; the whole compilation unit, so the ``#Include`` ordering is irrelevant as
; long as all files are part of the same script.
; ==============================================================================

; =======================================
; =======================================
; ======= 1/ Constants =======
; =======================================
; =======================================

; Delay (ms) after Ctrl+V in SendInstant to let the paste settle before
; the clipboard is restored. 200 ms was tuned empirically and handles
; slow paste targets (Teams/Word) without blocking perceptibly.
global SEND_INSTANT_PASTE_DELAY_MS := 200

; Timeout (s) for ClipWait in GetSelection. Most apps fill the clipboard
; in <100 ms; 2 s is a conservative ceiling before we return an empty
; string and restore the original clipboard.
global GET_SELECTION_TIMEOUT_SEC := 2

; Delay (ms) used by ActivateHotstrings between the Space poke and the
; BackSpace. Kept explicit so we can tune it in one place without
; chasing magic numbers across hot paths.
global ACTIVATE_HOTSTRINGS_DELAY_MS := 50


; =======================================
; =======================================
; ======= 2/ Low-level send layer =======
; =======================================
; =======================================

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
    ; Function for sending immediately a big text without typing it letter by letter.
    ; Uses try/finally so the user's clipboard is restored even on error/crash.
    OldClipboard := ClipboardAll()
    try {
        A_Clipboard := Text
        SendInput("^v")
        Sleep(SEND_INSTANT_PASTE_DELAY_MS)
    } finally {
        A_Clipboard := OldClipboard
        OldClipboard := ""
    }
}

; Leave time to trigger hotstrings between sending a character and then another one
ActivateHotstrings() {
    SendNewResult(" ")
    Sleep(ACTIVATE_HOTSTRINGS_DELAY_MS)
    SendNewResult("{BackSpace}", Map("OnlyText", False))
}

GetSelection() {
    ; Save/restore the user's clipboard around a Ctrl+C capture of the current selection.
    ; Wrapped in try/finally so the clipboard is restored even on error/timeout.
    OldClipboard := ClipboardAll()
    Text := ""
    try {
        A_Clipboard := ""
        SendEvent("^c")
        ClipWait(GET_SELECTION_TIMEOUT_SEC)
        Text := A_Clipboard
    } finally {
        A_Clipboard := OldClipboard
        OldClipboard := ""
    }
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

; ============================================
; ============================================
; ======= 3/ Hotstring builders & core =======
; ============================================
; ============================================

CreateHotstring(Flags, Abbreviation, Replacement, options := Map()) {
    ; Default values if not provided
    OptionOnlyText := options.Has("OnlyText") ? options["OnlyText"] : True
    OptionFinalResult := options.Has("FinalResult") ? options["FinalResult"] : False
    OptionTimeActivationSeconds := options.Has("TimeActivationSeconds") ? options[
        "TimeActivationSeconds"] : 0

    HotstringOptions := Map("OnlyText", OptionOnlyText).Set("FinalResult", OptionFinalResult).Set(
        "TimeActivationSeconds", OptionTimeActivationSeconds)

    FlagsPortion := ":" Flags "B0O:" ; O is to omit the ending character from the abbreviation
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
    FlagsPortion := ":" Flags "CB0O:" ; O is to omit the ending character from the abbreviation

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
        for _, variant in GenerateUppercaseVariants(AbbreviationUpperCase, UppercasedSymbols) {
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
    }
}

; ==========================================
; ==========================================
; ======= 4/ Text & history helpers =======
; ==========================================
; ==========================================

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
