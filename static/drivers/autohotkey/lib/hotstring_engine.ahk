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

; Hotstrings will still be triggered downstream, so SendNewResult("a") can
; cascade a ➜ b ➜ c (final result). OnlyText=true wraps the payload in {Text}
; to avoid modifier side effects on symbols like ', ", accents.
SendNewResult(Text, OnlyText := True) {
    if OnlyText {
        SendEvent("{Text}" Text)
    } else {
        SendEvent(Text)
    }
    UpdateLastSentCharacter(SubStr(Text, -1))
}

; SendInput prevents other hotstrings/hotkeys from activating, so this is the
; "final" result — used when we do not want cascading expansion.
SendFinalResult(Text, OnlyText := False) {
    if OnlyText {
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
    SendNewResult("{BackSpace}", False)
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

; Public hotstring factory. The Map-based options API is kept because this
; runs once at startup (cold path); internally the options are decomposed
; into positional booleans that the per-keystroke HotstringHandler closes
; over without further Map lookups.
CreateHotstring(Flags, Abbreviation, Replacement, options := unset) {
    OnlyText := (IsSet(options) and options.Has("OnlyText")) ? options["OnlyText"] : True
    FinalResult := (IsSet(options) and options.Has("FinalResult")) ? options["FinalResult"] : False
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options["TimeActivationSeconds"] : 0

    FlagsPortion := ":" Flags "B0O:" ; O omits the ending character from the abbreviation
    Hotstring(
        FlagsPortion Abbreviation,
        (*) => HotstringHandler(Abbreviation, Replacement, A_EndChar, OnlyText, FinalResult, TimeActivationSeconds)
    )
}

; Hot path — runs on every hotstring firing. Positional booleans avoid any
; Map allocation here, which matters for frequent triggers.
HotstringHandler(Abbreviation, Replacement, EndChar, OnlyText := True, FinalResult := False, TimeActivationSeconds := 0) {
    if IsTimeActivationExpired(SubStr(Abbreviation, -2, 1), TimeActivationSeconds) {
        return
    }

    SendEvent("{SC138 Up}") ; Becomes necessary when we replaced the AltGr key by Kana

    ; B0 flag means we delete the abbreviation manually; this behaves
    ; consistently everywhere (URL bars, devtools) unlike AHK's auto-erase.
    NumberOfCharactersToDelete := StrLen(Abbreviation)

    if WinActive("ahk_class Notepad") {
        ; Windows 11 Notepad mis-handles hotstrings (Windows bug, not AHK),
        ; so we route replacement through the clipboard.
        SendNewResult("{BackSpace " . NumberOfCharactersToDelete . "}", False)
        SendInstant(Replacement . EndChar)
        return
    }

    if FinalResult {
        SendFinalResult("{BackSpace " . NumberOfCharactersToDelete . "}", False)
        SendFinalResult(Replacement, OnlyText)
        SendFinalResult(EndChar, False)
    } else {
        SendNewResult("{BackSpace " . NumberOfCharactersToDelete . "}", False)
        SendNewResult(Replacement, OnlyText)
        SendNewResult(EndChar, False)
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

CreateCaseSensitiveHotstrings(Flags, Abbreviation, Replacement, options := unset) {
    OnlyText := (IsSet(options) and options.Has("OnlyText")) ? options["OnlyText"] : True
    FinalResult := (IsSet(options) and options.Has("FinalResult")) ? options["FinalResult"] : False
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options["TimeActivationSeconds"] : 0

    FlagsPortion := ":" Flags "CB0O:" ; O omits the ending character from the abbreviation

    ; Order matters: nbsp abbreviations must trigger before bare punctuation
    ; so the engine can delete the preceding non-breaking space correctly.
    static UppercasedSymbols := Map(",", [" ;", " :"], Chr(0x27), [" ?"])

    AbbreviationLowerCase := StrLower(Abbreviation)
    AbbreviationTitleCase := StrTitle(Abbreviation)
    AbbreviationUpperCase := StrUpper(Abbreviation)
    FirstChar := SubStr(Abbreviation, 1, 1)

    ReplacementLowerCase := StrLower(Replacement)
    ReplacementTitleCase := StrTitle(Replacement)
    ReplacementUpperCase := StrUpper(Replacement)

    ; Helper closure: installs one hotstring variant with positional args
    ; baked in. Must be a fat-arrow lambda so it closes over the outer
    ; locals (FlagsPortion, OnlyText…); nested `f() {}` functions in AHK v2
    ; do not capture the enclosing scope.
    RegisterVariant := (Abbr, Repl) => Hotstring(
        FlagsPortion Abbr,
        (*) => HotstringHandler(Abbr, Repl, A_EndChar, OnlyText, FinalResult, TimeActivationSeconds)
    )

    RegisterVariant(AbbreviationLowerCase, ReplacementLowerCase)

    ; When an abbreviation is only one character, titlecase = uppercase
    if StrLen(RTrim(Abbreviation, ScriptInformation["MagicKey"])) == 1 {
        RegisterVariant(AbbreviationTitleCase, ReplacementTitleCase)
        return
    }

    if (StrLen(Abbreviation) >= 2) {
        for _, variant in GenerateUppercaseVariants(AbbreviationUpperCase, UppercasedSymbols) {
            RegisterVariant(variant, ReplacementUpperCase)
        }

        ; Titlecase: first letter uppercase, rest lowercase
        if !(StrLower(FirstChar) == StrUpper(FirstChar)) {
            RegisterVariant(AbbreviationTitleCase, ReplacementTitleCase)
        } else if UppercasedSymbols.Has(FirstChar) {
            for UppercasedSymbol in UppercasedSymbols[FirstChar] {
                RegisterVariant(UppercasedSymbol . SubStr(AbbreviationLowerCase, 2), ReplacementTitleCase)
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
