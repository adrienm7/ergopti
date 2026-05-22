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
; HotstringHandler — auto-detected via a reverse VK→SC probe, with a manual
; TOML override (ScriptInformation["AltGrIsKanaRemap"]) that always wins.
; Caching the resolved bool at boot lets the hot path skip a Map lookup and
; a truthy test on every hotstring firing.
global _ALTGR_KANA_FIXUP := False

; Win32 constants for MapVirtualKeyEx — see learn.microsoft.com/en-us/
; windows/win32/api/winuser/nf-winuser-mapvirtualkeyexw.
global _MAPVK_VK_TO_VSC_EX := 4
global _VK_RMENU := 0xA5

; Returns the HKL of the foreground window's thread, or 0 if the call chain
; fails. Used by both DetectAltGrKanaRemap and the layout-change watcher in
; ErgoptiPlus.ahk so both observe the same value.
GetForegroundKeyboardLayout() {
    HWND := DllCall("GetForegroundWindow", "Ptr")
    if (HWND = 0) {
        return 0
    }
    TID := DllCall("GetWindowThreadProcessId", "Ptr", HWND, "Ptr", 0, "UInt")
    if (TID = 0) {
        return 0
    }
    return DllCall("GetKeyboardLayout", "UInt", TID, "Ptr")
}

; Probe the active layout in REVERSE direction: does VK_RMENU have a scancode?
;
; On vanilla AltGr layouts (bépo, US-International, AZERTY, …) the RAlt key
; is mapped to VK_RMENU, so MapVirtualKeyExW(VK_RMENU, VK_TO_VSC_EX) returns
; the RAlt extended scancode (typically 0xE038). On custom KbdEdit/MSKLC
; remaps where AltGr is reassigned to a different VK (VK_KANA, VK_OEM_8,
; VK_LMENU, …), VK_RMENU has no scancode → the probe returns 0.
;
; The reverse direction proves more reliable than the SC→VK probe used in
; earlier revisions: that one needed an E0-encoded scancode and behaved
; inconsistently across bépo HKLs (returning VK_LMENU or 0 instead of
; VK_RMENU), wrongly flagging bépo as a Kana layout.
DetectAltGrKanaRemap() {
    HKL := GetForegroundKeyboardLayout()
    if (HKL = 0) {
        HKL := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
    }
    SC := DllCall("MapVirtualKeyExW",
        "UInt", _VK_RMENU,
        "UInt", _MAPVK_VK_TO_VSC_EX,
        "Ptr", HKL,
        "UInt")
    return (SC == 0)
}

; Read the manual TOML override from ScriptInformation. Returns "" when the
; key is missing or set to the sentinel "auto"; "true" / "false" when forced.
_ReadKanaTomlOverride() {
    if !IsSet(ScriptInformation) or !ScriptInformation.Has("AltGrIsKanaRemap") {
        return ""
    }
    Val := ScriptInformation["AltGrIsKanaRemap"]
    if (Val == true or Val == 1 or Val == "1" or Val == "true" or Val == "True") {
        return "true"
    }
    if (Val == false or Val == 0 or Val == "0" or Val == "false" or Val == "False") {
        return "false"
    }
    return ""  ; "auto" or unrecognised → defer to detection
}

HotstringEngineInit() {
    global _ALTGR_KANA_FIXUP
    Override := _ReadKanaTomlOverride()
    if (Override == "true") {
        _ALTGR_KANA_FIXUP := True
        return
    }
    if (Override == "false") {
        _ALTGR_KANA_FIXUP := False
        return
    }
    _ALTGR_KANA_FIXUP := DetectAltGrKanaRemap()
}

; =======================================
; =======================================
; ======= 2/ Low-level send layer =======
; =======================================
; =======================================

; Internal — registers a hotstring with HSE (the production dispatcher
; since Session 2 of the migration). The test seam ``_HotstringRegistrar``
; still receives the registration for harnesses that want to record what
; was registered without firing real expansions; the AHK native engine is
; no longer involved at all.
;
; Meta carries dispatch metadata (Replacement, OnlyText, FinalResult,
; TimeActivationSeconds, PrevCharKey). When omitted, HSE_DispatchMatch
; falls back to invoking Callback directly — the path used by tests that
; register bare lambdas.
_RegisterHotstring(TriggerSpec, Callback, Meta := unset) {
    if _HotstringRegistrar {
        Reg := _HotstringRegistrar
        Reg(TriggerSpec, Callback)
    }
    _MirrorRegistrationToHSE(TriggerSpec, Callback, Meta?)
}

; Parse the AHK ``:flags:abbrev`` trigger spec and forward to HSE_Register.
; Flag letters that HSE understands (``*``, ``?``, ``C``) are passed
; through verbatim; the rest (``B0``, ``O`` — both irrelevant to matching)
; are dropped. Abbreviations are registered as-is so the HSE bucket
; index stays in lockstep with the upstream registration call.
_MirrorRegistrationToHSE(TriggerSpec, Callback, Meta := unset) {
    if !RegExMatch(TriggerSpec, "^:([^:]*):(.+)$", &Match) {
        return
    }
    RawFlags := Match[1]
    Abbrev := Match[2]
    HseFlags := ""
    if InStr(RawFlags, "*") {
        HseFlags .= "*"
    }
    if InStr(RawFlags, "?") {
        HseFlags .= "?"
    }
    if InStr(RawFlags, "C") {
        HseFlags .= "C"
    }
    if IsSet(Meta) {
        HSE_Register(HseFlags, Abbrev, Callback, Meta)
    } else {
        HSE_Register(HseFlags, Abbrev, Callback)
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
; into positional booleans AND the per-firing string ``BackSpaceSeq`` is
; pre-computed so the hot-path dispatcher ``_HotstringDispatch`` never has
; to run ``StrLen`` or concatenate on every keystroke.
CreateHotstring(Flags, Abbreviation, Replacement, options := unset) {
    OnlyText := (IsSet(options) and options.Has("OnlyText")) ? options["OnlyText"] : True
    FinalResult := (IsSet(options) and options.Has("FinalResult")) ? options["FinalResult"] : False
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options[
        "TimeActivationSeconds"] : 0
    IsRepeat := (IsSet(options) and options.Has("IsRepeat")) ? options["IsRepeat"] : False
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""

    FlagsPortion := ":" Flags "B0O:" ; O omits the ending character from the abbreviation
    _RegisterHotstring(
        FlagsPortion Abbreviation,
        _MakeHotstringCallback(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds),
        _MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat, Category, Section)
    )
}

; Build the dispatch-metadata object HSE_DispatchMatch consumes. Kept next
; to the callback factory so the two stay in lockstep — every field used
; by the dispatcher has a clear origin in the original options dict.
_MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat := false, Category := "", Section := "") {
    return {
        Replacement: Replacement,
        OnlyText: OnlyText,
        FinalResult: FinalResult,
        TimeActivationSeconds: TimeActivationSeconds,
        PrevCharKey: SubStr(Abbreviation, -2, 1),
        IsRepeat: IsRepeat,
        Category: Category,
        Section: Section
    }
}

; Builds the per-keystroke callback for a single hotstring variant. Computes
; ``BackSpaceSeq`` / ``PrevCharKey`` once at registration time and closes
; over both plus the positional option booleans. Each call produces a fresh
; closure with its own captures — safe to call in a loop over variants.
_MakeHotstringCallback(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds) {
    BackSpaceSeq := "{BackSpace " . StrLen(Abbreviation) . "}"
    AbbreviationLen := StrLen(Abbreviation)
    PrevCharKey := SubStr(Abbreviation, -2, 1)
    return (*) => _HotstringDispatch(Replacement, A_EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult,
        TimeActivationSeconds, AbbreviationLen)
}

; Hot path — runs on every hotstring firing. ``BackSpaceSeq`` and
; ``PrevCharKey`` are pre-computed at registration time so this function
; does zero allocation / string work before dispatching the three sends.
_HotstringDispatch(Replacement, EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult, TimeActivationSeconds, AbbreviationLen := 0) {
    if IsTimeActivationExpired(PrevCharKey, TimeActivationSeconds) {
        return
    }
    ; Yield to a longer registered trigger that covers the same suffix.
    ; AHK native dispatches the most-recently-registered hotstring when two
    ; triggers overlap (e.g. "t★" fires before "@dt★" because the repeat
    ; section is registered last). HSE_LastMatch holds the longest match
    ; found by HSE_FeedChar on the same keystroke — if it is longer than our
    ; abbreviation, a better callback will fire (or already fired): abort.
    if (AbbreviationLen > 0 and HSE_LastMatch != ""
        and HSE_LastMatch.HasOwnProp("Length")
        and HSE_LastMatch.Length > AbbreviationLen) {
        return
    }
    ; Allow Replacement to be a zero-argument callable — resolved at fire time
    ; so dynamic values (dates, live data) are computed on each keystroke.
    if HasMethod(Replacement)
        Replacement := Replacement()

    if _ALTGR_KANA_FIXUP {
        ; Only needed when AltGr (SC138) is remapped to Kana at the driver
        ; level — without that remap the Up is a wasted SendEvent on the
        ; hottest path. ``HotstringEngineInit`` sets the flag at boot.
        SendEvent("{SC138 Up}")
    }

    ; Mute the prefix watcher's InputHook for the duration of the send burst.
    ; SendEvent re-injects characters that the hook would otherwise observe
    ; in pass-through mode, polluting the buffer with our own replacement
    ; (typing ``ct`` then ★ would surface a ``Taïwan`` preview right after
    ; the expansion because ``c'était`` ends with ``tai``). The release is
    ; deferred via SetTimer so any character still queued in the OS message
    ; loop is silently dropped before observation resumes.
    if IsSet(PrefixWatcherSuppress) {
        try PrefixWatcherSuppress(true)
    }

    try {
        if GetActiveApp().IsNotepad {
            ; Windows 11 Notepad mis-handles hotstrings (Windows bug, not AHK),
            ; so we route replacement through the clipboard.
            SendNewResult(BackSpaceSeq, False)
            SendInstant(Replacement . EndChar)
        } else if FinalResult {
            SendFinalResult(BackSpaceSeq, False)
            SendFinalResult(Replacement, OnlyText)
            SendFinalResult(EndChar, False)
        } else {
            SendNewResult(BackSpaceSeq, False)
            SendNewResult(Replacement, OnlyText)
            SendNewResult(EndChar, False)
        }
    }
    finally {
        ; 60 ms is enough margin for the OS to flush the SendEvent bursts
        ; into the InputHook before observation resumes. Tested against the
        ; longest replacements we ship (~30 chars) and against the Notepad
        ; clipboard path which is slower than the direct event injection.
        if IsSet(PrefixWatcherSuppress) {
            SetTimer((*) => PrefixWatcherSuppress(false), -60)
        }
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
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options[
        "TimeActivationSeconds"] : 0
    IsRepeat := (IsSet(options) and options.Has("IsRepeat")) ? options["IsRepeat"] : False
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""

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
    ; baked in, plus the pre-computed ``BackSpaceSeq`` / ``PrevCharKey`` so
    ; ``_HotstringDispatch`` skips the StrLen + SubStr work on every firing.
    ; Must be a fat-arrow lambda so it closes over the outer locals; nested
    ; ``f() {}`` functions in AHK v2 do not capture the enclosing scope.
    RegisterVariant := (Abbr, Repl) => _RegisterHotstring(
        FlagsPortion Abbr,
        _MakeHotstringCallback(Repl, Abbr, OnlyText, FinalResult, TimeActivationSeconds),
        _MakeHotstringMeta(Repl, Abbr, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat, Category, Section)
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
