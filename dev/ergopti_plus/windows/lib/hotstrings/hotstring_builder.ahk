; lib/hotstrings/hotstring_builder.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Builders & Text Helpers
; DESCRIPTION:
; Public hotstring factory functions (CreateHotstring, CreateCaseSensitiveHotstrings,
; CreateRawCallbackHotstring), the hot-path dispatcher (_HotstringDispatch),
; and shared text utilities (StrTitle, GenerateUppercaseVariants, GetLastSentCharacterAt).
;
; Included by lib/hotstrings/hotstring_engine.ahk after the send primitives section.
; ==============================================================================





; ============================================
; ============================================
; ======= 1/ Hotstring builders & core =======
; ============================================
; ============================================

; Resolve the collision priority to register a hotstring at, for the case where
; the caller did NOT pass an explicit ``Priority`` in its options. The hand loader
; (LoadHotstringsSection) always passes the fully resolved cascade value
; (individual > section > file > source) and never reaches here. The GENERATED-loader
; path only carries Category/Section, so fold in the section/file/source override
; cascade via HotstringsResolve so the ~3000 bundled hotstrings honour a user's
; per-section priority override instead of always landing at the common tier (10).
; HotstringsConfigInit runs long before RegisterAllHotstrings, so the override file
; is loaded here; HotstringsResolve is memoised per (category, section) so this stays
; cheap across thousands of entries. Falls back to HSE_PRIORITY_COMMON when no
; category context is available. NB: takes Category/Section, NOT the options Map —
; callers omit ``options`` entirely (declared ``options := unset``), and passing an
; unset variable as an argument throws UnsetError at the call site in AHK v2, so the
; ``IsSet(options)`` guard MUST live in the caller, never in a parameter here.
_HSE_ResolveRegistrationPriority(Category, Section) {
    global HSE_PRIORITY_COMMON
    if (Category != "") {
        Resolved := HotstringsResolve(Category, Section)
        if (Resolved.HasOwnProp("Priority") and Resolved.Priority != "") {
            return Resolved.Priority
        }
    }
    return HSE_PRIORITY_COMMON
}

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
    ; An explicit Priority (passed by the hand loader) always wins; otherwise resolve
    ; the override cascade from Category/Section. The IsSet(options) guard MUST be here
    ; — passing the unset ``options`` variable into the helper would throw UnsetError.
    Priority := (IsSet(options) and options.Has("Priority"))
        ? options["Priority"]
        : _HSE_ResolveRegistrationPriority(Category, Section)

    ; HSE_DispatchMatch fires via Spec.Replacement, so the per-spec callback closure
    ; is only needed when a test has installed _HotstringRegistrar (it records and may
    ; invoke it). In production (Rec == 0) we skip building the closure and the
    ; ":flags:B0O:abbrev" string — both pure boot-time waste. The ternaries
    ; short-circuit, so neither is constructed unless a recorder is present.
    Rec := _HotstringRegistrar
    _RegisterHotstringFast(
        Rec, _HseFlagSubset(Flags), Abbreviation,
        Rec ? (":" Flags "B0O:" Abbreviation) : "",
        Rec ? _MakeHotstringCallback(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, Category, Section) : 0,
        _MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat, Category, Section, Priority)
    )
}

; Register a "raw callback" hotstring: the callback does ALL of its own
; conditional, variable-length sending/backspacing and returns a { Bs, Ins }
; effect (Bs chars removed from the buffer's right, Ins appended) for HSE buffer
; resync — see _HSE_DispatchRawCallback. Used by the formerly-native E-circumflex
; deadkey + "..." ellipsis so no AHK-native Hotstring() (hence no A_InputLevel
; dependency) remains. The B0O flag suffix matches CreateHotstring: the engine
; never auto-backspaces — the callback owns the screen edit.
CreateRawCallbackHotstring(Flags, Abbreviation, Callback, options := unset) {
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options["TimeActivationSeconds"] : 0
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""
    Priority := (IsSet(options) and options.Has("Priority"))
        ? options["Priority"]
        : _HSE_ResolveRegistrationPriority(Category, Section)
    ; The callback IS the dispatch here (HSE_DispatchMatch routes RawCallback specs
    ; to it), so it is always passed; only the recorder string is gated on Rec.
    Rec := _HotstringRegistrar
    _RegisterHotstringFast(
        Rec, _HseFlagSubset(Flags), Abbreviation,
        Rec ? (":" Flags "B0O:" Abbreviation) : "",
        Callback,
        { RawCallback: true, TimeActivationSeconds: TimeActivationSeconds, PrevCharKey: SubStr(Abbreviation, -2, 1), Category: Category, Section: Section, Priority: Priority }
    )
}

; Build the dispatch-metadata object HSE_DispatchMatch consumes. Kept next
; to the callback factory so the two stay in lockstep — every field used
; by the dispatcher has a clear origin in the original options dict.
; Priority defaults to 10 here — the literal mirrors HSE_PRIORITY_COMMON, which
; an AHK v2 default-parameter expression cannot reference. Both callers
; (CreateHotstring / CreateCaseSensitiveHotstrings) always pass the resolved
; value, so this default only guards a hypothetical third caller.
_MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat := false, Category := "", Section := "", Priority := 10) {
    static _NextSeq := 0
    _NextSeq += 1
    return {
        Replacement: Replacement,
        Trigger: Abbreviation,
        Length: StrLen(Abbreviation),
        OnlyText: OnlyText,
        FinalResult: FinalResult,
        TimeActivationSeconds: TimeActivationSeconds,
        PrevCharKey: SubStr(Abbreviation, -2, 1),
        IsRepeat: IsRepeat,
        Category: Category,
        Section: Section,
        Priority: Priority,
        Seq: _NextSeq
    }
}

; Builds the per-keystroke callback for a single hotstring variant. Computes
; ``BackSpaceSeq`` / ``PrevCharKey`` once at registration time and closes
; over both plus the positional option booleans. Each call produces a fresh
; closure with its own captures — safe to call in a loop over variants.
_MakeHotstringCallback(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, Category := "", Section := "") {
    BackSpaceSeq := "{BackSpace " . StrLen(Abbreviation) . "}"
    AbbreviationLen := StrLen(Abbreviation)
    PrevCharKey := SubStr(Abbreviation, -2, 1)
    return (*) => _HotstringDispatch(Replacement, A_EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult,
        TimeActivationSeconds, AbbreviationLen, Abbreviation, Category, Section)
}

; Hot path — runs on every hotstring firing. ``BackSpaceSeq`` and
; ``PrevCharKey`` are pre-computed at registration time so this function
; does zero allocation / string work before dispatching the three sends.
_HotstringDispatch(Replacement, EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult, TimeActivationSeconds, AbbreviationLen := 0, Trigger := "", Category := "", Section := "") {
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

    ; Tag the backspace+replacement burst as synthetic so the keylogger keeps
    ; it out of the manual `chars` count and attributes the resulting n-grams
    ; to the hotstring source (esrc). Released on the same deferred timer as
    ; the prefix-watcher suppression so it covers the OS message-loop flush.
    try KL_MarkSynthetic("hotstring")

    try {
        isNotepad := false
        try {
            exe := (IsSet(KLHook) and KLHook.HasOwnProp("prev_app")) ? KLHook.prev_app : WinGetProcessName("A")
            isNotepad := (exe = "notepad.exe")
        }
        if isNotepad {
            ; Windows 11 Notepad mis-handles hotstrings (Windows bug, not AHK),
            ; so we route replacement through the clipboard. Keep the erase and
            ; Ctrl+V in one SendInput transaction: a separate SendEvent erase lets
            ; a physical key interleave before the clipboard paste.
            _HsNotepadCritical := Critical("On")
            try SendInstant(Replacement . EndChar, BackSpaceSeq)
            finally Critical(_HsNotepadCritical)
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
        ; Release the synthetic flag on the same flush window — clearing it
        ; inline would let trailing replacement keystrokes look manual.
        SetTimer((*) => KL_ClearSynthetic(), -60)
    }
    ; Notify the WPM widget for end-char fires only — star (immediate) fires
    ; are already logged by the prefix watcher via HSE_DispatchMatch.
    ; KL_LogHotstring is guarded by Keylogger.initialized — safe to call here.
    if (EndChar != "") and (Trigger != "") and (Category != "") {
        repl_str := HasMethod(Replacement) ? "" : Replacement
        if IsSet(KL_LogHotstring) {
            try KL_LogHotstring(Trigger, repl_str, "endchar", "", Category, Section)
        } else if IsSet(WPMWidget_Push) {
            repl_len := HasMethod(Replacement) ? 1 : StrLen(repl_str)
            Loop repl_len
                try WPMWidget_Push(true, false, false, Category, Section)
        }
    }
}

IsTimeActivationExpired(PreviousCharacter, OptionTimeActivationSeconds) {
    ; Don't activate the hotstring if taped too slowly
    Now := A_TickCount
    if OptionTimeActivationSeconds > 0 {
        ; Fail CLOSED: a missing timestamp means we cannot prove the prior char
        ; was typed recently (it may have been pruned by LAST_SENT_KEY_TIME_MAX_AGE_MS
        ; after a long pause), so the time gate must treat it as expired rather
        ; than defaulting to "now" — which would let a deliberately-paused trigger
        ; fire as if it had just been typed.
        if !LastSentCharacterKeyTime.Has(PreviousCharacter) {
            return True
        }
        CharacterSentTime := LastSentCharacterKeyTime[PreviousCharacter]
        ; We need to convert into milliseconds, hence the multiplication by 1000
        if (Now - CharacterSentTime > OptionTimeActivationSeconds * 1000) {
            return True
        }
    }
    return False
}

; SINGLE SOURCE OF TRUTH for the TOML `is_case_sensitive` flag -> registrar
; mapping. Generator semantics (documented at hotstring_registry.ahk:132):
;   is_case_sensitive = not case_sensitive
;   TRUE  -> register the literal trigger only          -> CreateHotstring
;   FALSE -> register the whole cased family (conform)  -> CreateCaseSensitiveHotstrings
;
; Every loader MUST route through this instead of open-coding the branch. There
; used to be four open-coded copies and two of them (LoadHotstringsSection and
; LoadExtTomlFile) had drifted into the OPPOSITE meaning — so the same personal
; or extension entry registered a different casing family depending on whether it
; came from boot or from a live editor save, and the preview index disagreed with
; the engine in both directions. Bundled categories always short-circuit into the
; cache registrar, so only the two least-covered paths were affected.
HSE_RegisterFromTomlFlags(IsCaseSensitive, Flags, Trigger, Output, Options) {
    if IsCaseSensitive {
        CreateHotstring(Flags, Trigger, Output, Options)
        return
    }
    CreateCaseSensitiveHotstrings(Flags, Trigger, Output, Options)
}

CreateCaseSensitiveHotstrings(Flags, Abbreviation, Replacement, options := unset) {
    OnlyText := (IsSet(options) and options.Has("OnlyText")) ? options["OnlyText"] : True
    FinalResult := (IsSet(options) and options.Has("FinalResult")) ? options["FinalResult"] : False
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options[
        "TimeActivationSeconds"] : 0
    IsRepeat := (IsSet(options) and options.Has("IsRepeat")) ? options["IsRepeat"] : False
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""
    ; An explicit Priority (passed by the hand loader) always wins; otherwise resolve
    ; the override cascade from Category/Section. The IsSet(options) guard MUST be here
    ; — passing the unset ``options`` variable into the helper would throw UnsetError.
    Priority := (IsSet(options) and options.Has("Priority"))
        ? options["Priority"]
        : _HSE_ResolveRegistrationPriority(Category, Section)

    Rec := _HotstringRegistrar

    ; Order matters: nbsp abbreviations must trigger before bare punctuation
    ; so the engine can delete the preceding non-breaking space correctly.
    ; The apostrophe key uses Chr(0x27) via a helper because AHK v2 parses
    ; a bare ' inside Map() as a string delimiter, causing a parse error.
    static UppercasedSymbols := _BuildUppercasedSymbols()

    ; Only the lowercase forms are needed to decide and take the case-conform fast
    ; path below; the Title / UPPER forms (4 StrXxx calls) serve solely the
    ; explicit-variant path, so they are computed only after the conform return.
    AbbreviationLowerCase := StrLower(Abbreviation)
    ReplacementLowerCase := StrLower(Replacement)

    ; ── Case-conform fast path ──────────────────────────────────────────────
    ; For a star trigger with no shift-symbol char (the common case — every
    ; magic-key text-expansion entry), register ONE case-INSENSITIVE spec instead
    ; of the lower/UPPER/Title explicit variants. HSE_DispatchMatch conforms the
    ; replacement casing to how the trigger was typed (see _HSE_ConformReplacement),
    ; roughly halving the magic-key registration with no observable change.
    ; Triggers containing "," or "'" KEEP the explicit path: their UPPER forms are
    ; DIFFERENT characters (shifted nbsp + ;/:/?) a case-insensitive match cannot
    ; reproduce — exactly the set _BuildUppercasedSymbols enumerates.
    IsStarTrigger := InStr(Flags, "*") > 0
    HasShiftSymbol := false
    for _, _ConformChar in StrSplit(Abbreviation) {
        if UppercasedSymbols.Has(_ConformChar) {
            HasShiftSymbol := true
            break
        }
    }
    if (IsStarTrigger and !HasShiftSymbol) {
        ; A 1-char abbreviation (before the magic key) has no distinct UPPER form.
        ConformOneChar := StrLen(RTrim(Abbreviation, ScriptInformation["MagicKey"])) == 1
        ; Drop the "C" flag so any-case typing matches the single registered spec.
        ConformFlags := StrReplace(Flags, "C")
        ConformMeta := _MakeHotstringMeta(ReplacementLowerCase, AbbreviationLowerCase, OnlyText,
            FinalResult, TimeActivationSeconds, IsRepeat, Category, Section, Priority)
        ConformMeta.CaseConform := true
        ConformMeta.ConformOneChar := ConformOneChar
        _RegisterHotstringFast(
            Rec, _HseFlagSubset(ConformFlags), AbbreviationLowerCase,
            Rec ? (":" ConformFlags "B0O:" AbbreviationLowerCase) : "",
            Rec ? _MakeHotstringCallback(ReplacementLowerCase, AbbreviationLowerCase, OnlyText, FinalResult, TimeActivationSeconds, Category, Section) : 0,
            ConformMeta
        )
        return
    }

    ; ── Explicit-variant path ───────────────────────────────────────────────
    ; Reached only for triggers that cannot use the conform fast path (non-star,
    ; or containing a shift-symbol char). The Title / UPPER case forms and the
    ; "C"-flag spec string are needed from here on, so they are built now rather
    ; than for every conform registration above.
    FlagsPortion := ":" Flags "CB0O:" ; O omits the ending character from the abbreviation
    AbbreviationTitleCase := StrTitle(Abbreviation)
    AbbreviationUpperCase := StrUpper(Abbreviation)
    FirstChar := SubStr(Abbreviation, 1, 1)
    ReplacementTitleCase := StrTitle(Replacement)
    ReplacementUpperCase := StrUpper(Replacement)

    ; Helper closure: installs one hotstring variant with positional args
    ; baked in, plus the pre-computed ``BackSpaceSeq`` / ``PrevCharKey`` so
    ; ``_HotstringDispatch`` skips the StrLen + SubStr work on every firing.
    ; Must be a fat-arrow lambda so it closes over the outer locals; nested
    ; ``f() {}`` functions in AHK v2 do not capture the enclosing scope.
    RegisterVariant := (Abbr, Repl) => _RegisterHotstringFast(
        Rec, _HseFlagSubset(Flags "C"), Abbr,
        Rec ? (FlagsPortion Abbr) : "",
        Rec ? _MakeHotstringCallback(Repl, Abbr, OnlyText, FinalResult, TimeActivationSeconds, Category, Section) : 0,
        _MakeHotstringMeta(Repl, Abbr, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat, Category, Section, Priority)
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
            for _, UppercasedSymbol in UppercasedSymbols[FirstChar] {
                RegisterVariant(UppercasedSymbol . SubStr(AbbreviationLowerCase, 2), ReplacementTitleCase)
            }
        }
    }
}





; =========================================
; =========================================
; ======= 2/ Text & history helpers =======
; =========================================
; =========================================

; Build the UppercasedSymbols Map used by CreateCaseSensitiveHotstrings.
; Extracted into a function so the apostrophe key can be written as Chr(0x27)
; rather than a literal ' inside Map(), which AHK v2 would misparse as a
; string delimiter.
;
; CRITICAL — the "uppercase" form of a comma/apostrophe is NOT a plain ASCII
; space + punctuation. On the Ergopti Shift layer the comma key emits a NARROW
; no-break space (NNBSP, U+202F) followed by ";" and the period key emits a
; full no-break space (NBSP, U+00A0) followed by ":" — French typography pairs
; ";" with the narrow space and ":" with the full one (see layout_shift_caps.ahk).
; The deadkey path can also emit either no-break space. So a case-sensitive
; hotstring whose trigger contains a comma must generate its shifted variants
; with an nbsp/nnbsp prefix — exactly what the user types via Shift+comma /
; Shift+period. Using a plain ASCII space here was a bug on two counts:
; (1) "nbsp + : + D" never matched the generated trigger (so ",d → ds" never
; produced "DS" in caps), and (2) a plain "<space>:D" emoji typed after a normal
; word DID match and got swallowed into "DS". The variant set below is
; deliberately LENIENT — it pairs both no-break spaces with both ";" and ":" so
; the "DS" expansion fires regardless of which no-break space landed in the
; buffer, while a bare ":D" emoji (plain space) stays untouched.
_BuildUppercasedSymbols() {
    NNBSP := Chr(0x202F)  ; U+202F — narrow no-break space (Shift+comma, before ";")
    NBSP  := Chr(0xA0)    ; U+00A0 — full no-break space (Shift+period, before ":")
    m := Map(",", [NNBSP Chr(0x3B), NNBSP ":", NBSP Chr(0x3B), NBSP ":"])
    m[Chr(0x27)] := [NNBSP "?", NBSP "?"]
    return m
}

StrTitle(Text) {
    if (StrLen(Text) > 0) {
        return StrUpper(SubStr(Text, 1, 1)) StrLower(SubStr(Text, 2))
    } else {
        return Text
    }
}

; Case-conform a replacement to the way the user actually typed the trigger. This
; replaces the old explicit lower/UPPER/Title variant registrations:
; CreateCaseSensitiveHotstrings now registers ONE case-insensitive spec (for star
; triggers without a shift-symbol char), and HSE_DispatchMatch calls this at fire
; time to pick the output casing — roughly halving the magic-key registration
; (~2119 -> ~1000 specs) with no observable change.
;   - ``Repl``      the registered (lowercase) replacement.
;   - ``Typed``     the trigger exactly as typed (the matched buffer suffix).
;   - ``Canonical`` the registered (lowercase) trigger.
;   - ``OneChar``   true when the abbreviation is a single character before the
;                   magic key — such a trigger has no distinct UPPER form (the old
;                   code registered lowercase + Title only, Title == Upper for one
;                   letter), so a typed capital maps to the Title replacement.
; Comparisons use ``==`` (case-SENSITIVE in AHK v2). Sets ``DoFire := false`` and
; returns "" when the typed case is not a clean lower / UPPER / Title form: the old
; code registered no variant for mixed case, so the hotstring must NOT fire then.
_HSE_ConformReplacement(Repl, Typed, Canonical, OneChar, &DoFire) {
    DoFire := true
    if (Typed == Canonical) {
        return Repl
    }
    TitleForm := StrTitle(Canonical)
    ; "!==" is case-SENSITIVE inequality — plain "!=" is case-insensitive in AHK v2
    ; and would treat "Ab" and "ab" as equal, collapsing the Title branch.
    if (Typed == TitleForm and TitleForm !== Canonical) {
        return StrTitle(Repl)
    }
    if (Typed == StrUpper(Canonical)) {
        return OneChar ? StrTitle(Repl) : StrUpper(Repl)
    }
    DoFire := false
    return ""
}

GenerateUppercaseVariants(AbbreviationUpperCase, UppercasedSymbols) {
    Variants := [AbbreviationUpperCase]
    if !(UppercasedSymbols is Map) {
        return Variants
    }
    for i, Char in StrSplit(AbbreviationUpperCase) {
        if UppercasedSymbols.Has(Char) {
            for UpperSymbol in UppercasedSymbols[Char] {
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
