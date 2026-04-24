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
; ``UpdateLastSentCharacter`` function and its ``LastSentCharacterKeyTime``
; backing global. The last-character ring buffer (``_LSC_*``) lives in this
; file (see section 4). AHK v2 resolves these across the whole compilation
; unit, so the ``#Include`` ordering is irrelevant as long as all files are
; part of the same script.
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

; ── Test seams (production = 0, tests can swap them with a recorder). ──
; ``_HotstringRegistrar`` intercepts the AHK ``Hotstring()`` registration
; call; ``_SendHook`` intercepts every send primitive (SendNewResult,
; SendFinalResult, SendInstant). Both default to 0 so the production
; runtime path is bit-for-bit identical to before.
global _HotstringRegistrar := 0
global _SendHook := 0

; Boot-time resolution of whether AltGr needs the synthetic Up injection in
; HotstringHandler. Reading ``ScriptInformation["AltGrIsKanaRemap"]`` once
; at boot and caching as a plain bool lets the hot path skip both a Map
; lookup and a truthy test on every hotstring firing. ErgoptiPlus.ahk calls
; ``HotstringEngineInit`` after populating ``ScriptInformation`` from the
; ini so the cached value reflects the user's configuration.
global _ALTGR_KANA_FIXUP := False

HotstringEngineInit() {
    global _ALTGR_KANA_FIXUP
    if !IsSet(ScriptInformation) {
        return
    }
    if !ScriptInformation.Has("AltGrIsKanaRemap") {
        return
    }
    Val := ScriptInformation["AltGrIsKanaRemap"]
    ; INI values come back as strings; treat "true"/"1"/true as truthy.
    if (Val == true or Val == 1 or Val == "1" or Val == "true" or Val == "True") {
        _ALTGR_KANA_FIXUP := True
    }
}


; =======================================
; =======================================
; ======= 2/ Low-level send layer =======
; =======================================
; =======================================

; Internal — registers a hotstring through ``_HotstringRegistrar`` when the
; test seam is installed, otherwise falls through to AHK's built-in
; ``Hotstring()``. Centralised so CreateHotstring and the
; CreateCaseSensitiveHotstrings RegisterVariant lambda share one indirection.
_RegisterHotstring(TriggerSpec, Callback) {
    if _HotstringRegistrar {
        Reg := _HotstringRegistrar
        Reg(TriggerSpec, Callback)
    } else {
        Hotstring(TriggerSpec, Callback)
    }
}

; Hotstrings will still be triggered downstream, so SendNewResult("a") can
; cascade a ➜ b ➜ c (final result). OnlyText=true wraps the payload in {Text}
; to avoid modifier side effects on symbols like ', ", accents.
SendNewResult(Text, OnlyText := True) {
    if _SendHook {
        Hook := _SendHook
        Hook("SendNewResult", Text, OnlyText)
    } else {
        if OnlyText {
            SendEvent("{Text}" Text)
        } else {
            SendEvent(Text)
        }
    }
    UpdateLastSentCharacter(SubStr(Text, -1))
}

; SendInput prevents other hotstrings/hotkeys from activating, so this is the
; "final" result — used when we do not want cascading expansion.
SendFinalResult(Text, OnlyText := False) {
    if _SendHook {
        Hook := _SendHook
        Hook("SendFinalResult", Text, OnlyText)
        return
    }
    if OnlyText {
        SendInput("{Text}" Text)
    } else {
        SendInput(Text)
    }
}

SendInstant(Text) {
    ; Function for sending immediately a big text without typing it letter by letter.
    ; Uses try/finally so the user's clipboard is restored even on error/crash.
    if _SendHook {
        Hook := _SendHook
        Hook("SendInstant", Text)
        return
    }
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
    if !_SendHook {
        Sleep(ACTIVATE_HOTSTRINGS_DELAY_MS)
    }
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

; Returns true when the foreground window is a Microsoft Office app or Teams.
; Backed by the 100 ms active-app cache so the eight-app check costs one
; ``WinGetProcessName`` per cache window instead of one ``WinActive`` per app
; per hotstring firing.
MicrosoftApps() {
    return GetActiveApp().IsMicrosoftOffice
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
    _RegisterHotstring(
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

    if _ALTGR_KANA_FIXUP {
        ; Only needed when AltGr (SC138) is remapped to Kana at the driver
        ; level — without that remap the Up is a wasted SendEvent on the
        ; hottest path. ``HotstringEngineInit`` sets the flag at boot.
        SendEvent("{SC138 Up}")
    }

    ; B0 flag means we delete the abbreviation manually; this behaves
    ; consistently everywhere (URL bars, devtools) unlike AHK's auto-erase.
    NumberOfCharactersToDelete := StrLen(Abbreviation)

    if GetActiveApp().IsNotepad {
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
    ; Don't activate the hotstring if taped too slowly
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
    ; The apostrophe key uses Chr(0x27) via a helper because AHK v2 parses
    ; a bare ' inside Map() as a string delimiter, causing a parse error.
    static UppercasedSymbols := _BuildUppercasedSymbols()

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
    RegisterVariant := (Abbr, Repl) => _RegisterHotstring(
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

; =====================================================
; =====================================================
; ======= 4/ Last-sent-character ring buffer =======
; =====================================================
; =====================================================

; Fixed-capacity ring of the last N characters emitted by the driver, used by
; hotstrings / rolls / deadkeys to peek at what the user just typed without
; calling back into Win32. The ring avoids the O(n) ``RemoveAt(1)`` memmove
; the previous Array-based implementation performed on every keystroke.
;
; Indexing contract (unchanged for callers of ``GetLastSentCharacterAt``):
;   - Negative offset -k returns the k-th character from the NEWEST
;     (offset -1 = just-pushed char, offset -2 = the one before, …).
;   - Positive offset +k returns the k-th character from the OLDEST
;     still in the buffer (offset +1 = oldest).
;   - Any offset beyond the current fill count returns "".
global _LSC_CAP := 5
global _LSC_RING := ["", "", "", "", ""]
global _LSC_CURSOR := 0  ; 1-based index of the most recently written slot
global _LSC_LEN := 0     ; number of populated slots, saturates at _LSC_CAP

; Push a new character; O(1), no reallocation after boot.
_LSCPush(Char) {
    global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
    _LSC_CURSOR := Mod(_LSC_CURSOR, _LSC_CAP) + 1
    _LSC_RING[_LSC_CURSOR] := Char
    if _LSC_LEN < _LSC_CAP {
        _LSC_LEN += 1
    }
}

; Reset the ring to a known sequence (oldest-first). Kept as a thin wrapper
; so tests can seed state without reaching into globals.
_LSCResetFrom(Chars) {
    global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
    _LSC_RING := []
    loop _LSC_CAP {
        _LSC_RING.Push("")
    }
    _LSC_CURSOR := 0
    _LSC_LEN := 0
    for _, c in Chars {
        _LSCPush(c)
    }
}




; ==========================================
; ==========================================
; ======= 5/ Text & history helpers =======
; ==========================================
; ==========================================

; Build the UppercasedSymbols Map used by CreateCaseSensitiveHotstrings.
; Extracted into a function so the apostrophe key can be written as Chr(0x27)
; rather than a literal ' inside Map(), which AHK v2 would misparse as a
; string delimiter.
_BuildUppercasedSymbols() {
    m := Map(",", [" " Chr(0x3B), " :"])
    m[Chr(0x27)] := [" ?"]
    return m
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
    global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
    if _LSC_LEN == 0 {
        return ""
    }
    if Offset < 0 {
        K := -Offset
        if K > _LSC_LEN {
            return ""
        }
        Idx := Mod(_LSC_CURSOR - K + _LSC_CAP, _LSC_CAP) + 1
        return _LSC_RING[Idx]
    }
    if Offset > 0 {
        if Offset > _LSC_LEN {
            return ""
        }
        ; Oldest slot is cursor + 1 wrapped when the buffer is full, otherwise slot 1.
        OldestIdx := (_LSC_LEN < _LSC_CAP) ? 1 : (Mod(_LSC_CURSOR, _LSC_CAP) + 1)
        Idx := Mod(OldestIdx - 1 + (Offset - 1), _LSC_CAP) + 1
        return _LSC_RING[Idx]
    }
    return ""
}
