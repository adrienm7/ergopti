; lib/hotstrings/hotstring_match.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Match Logic & Suffix Matching
; DESCRIPTION:
; Trigger-matching logic for the custom hotstring engine: collision precedence,
; the star (immediate) and end-char match paths, and the suffix-equality helper.
;
; FEATURES & RATIONALE:
; 1. Star path: probes HSE_Buffer suffixes against by-trigger maps (O(MaxLen)
;    lookups) instead of scanning the ~2100-entry magic-key bucket.
; 2. End-char path: scans the last-char registry bucket for non-star specs
;    that are suffixes of the body buffer.
; 3. HSE_SuffixMatches: case-folded suffix equality used by the end-char path.
;
; Included by lib/hotstrings/hotstring_engine_main.ahk.
; ==============================================================================




; ====================================================
; ====================================================
; ======= 1/ Match logic =============================
; ====================================================
; ====================================================

; Collision precedence between two candidate Specs of the SAME kind (both star,
; or both end-char). The longest trigger wins; ties are broken by higher
; Priority, then by lower Seq (first-registered) for a stable, deterministic
; result. Returns true when Cand should replace Best.
_HSE_Beats(Cand, Best) {
    if (!IsObject(Best)) {
        return true
    }
    if (Cand.Length != Best.Length) {
        return Cand.Length > Best.Length
    }
    CandPrio := Cand.HasOwnProp("Priority") ? Cand.Priority : 50
    BestPrio := Best.HasOwnProp("Priority") ? Best.Priority : 50
    if (CandPrio != BestPrio) {
        return CandPrio > BestPrio
    }
    if (Cand.GroupOrder != Best.GroupOrder) {
        return Cand.GroupOrder < Best.GroupOrder
    }
    return Cand.Seq < Best.Seq
}

; Precedence for an end-char candidate against the current best, which may be a
; star match carried over from the star path. A star match only yields to a
; STRICTLY longer end-char trigger — this preserves the long-standing rule that
; a star trigger wins an equal-length tie against an end-char trigger, so adding
; priority never silently flips star/end-char outcomes. Among end-char
; candidates the full _HSE_Beats tie-break (length, priority, Seq) applies.
_HSE_EndCharBeats(Cand, Best, BestIsEndChar) {
    if (Best == "") {
        return true
    }
    if !BestIsEndChar {
        return Cand.Length > Best.Length
    }
    return _HSE_Beats(Cand, Best)
}

; Look for a trigger that fires given the just-typed char.
;
; Two paths, both scanned because they can both succeed and longest-match
; wins across them:
;
;   STAR path — ``Spec.Star`` triggers (immediate). The trigger's last
;   char IS the just-typed char; the entire trigger must be a suffix of
;   HSE_Buffer. No end character is involved (HSE_LastEndChar stays "").
;
;   END-CHAR path — non-``Spec.Star`` triggers. Only attempted when the
;   just-typed char is a word terminator. The trigger's last char is the
;   char SITTING IN THE BUFFER one position before the just-typed char;
;   the trigger body must be a suffix of ``HSE_Buffer`` excluding its
;   final character. The end character (HSE_LastEndChar) is the just-typed
;   terminator — it will be backspaced and re-emitted by the dispatcher.
;
; Returns the matching Spec (longest match wins) or "" when nothing
; matches. Side-effect: HSE_LastEndChar is set to "" (star match) or to
; ``JustTypedChar`` (end-char match).
HSE_FindMatchAtEnd(JustTypedChar) {
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_RegistryByLastChar
    global HSE_WORD_TERMINATORS, HSE_LastEndChar, HSE_TypoNbspStripped
    global HSE_RebuildInProgress
    global HSE_StarByTriggerCI, HSE_StarByTriggerCS, HSE_MaxStarTriggerLen
    global HSE_EndByTriggerCI, HSE_EndByTriggerCS, HSE_MaxEndTriggerLen

    if HSE_RebuildInProgress {
        return ""
    }

    HSE_TypoNbspStripped := false
    if (JustTypedChar == "") {
        return ""
    }

    BufLen := StrLen(HSE_Buffer)
    IsTerminator := InStr(HSE_WORD_TERMINATORS, JustTypedChar) > 0

    ; Trigger-body buffer for the end-char path (buffer minus the
    ; just-typed terminator). For the star path, we match against the
    ; full buffer.
    BodyBuf := SubStr(HSE_Buffer, 1, BufLen - 1)
    BodyLastChar := SubStr(BodyBuf, -1)

    BestMatch := ""
    BestEndChar := ""

    ; ── STAR path ──────────────────────────────────────────────────
    ; A star trigger fires iff it equals some suffix of HSE_Buffer (the suffix
    ; already ends in JustTypedChar, since that char was just appended). Rather
    ; than scan every star trigger in the last-char bucket — ~2100 of them all
    ; ending in the magic key, ~21 ms per press — probe the buffer's OWN suffixes
    ; against the by-trigger index: at most HSE_MaxStarTriggerLen Map lookups.
    ; Ascending suffix length means a longer trigger naturally overrides a shorter
    ; one (the `Length <= BestMatch.Length` skip preserves the old "strictly
    ; longer wins, first-registered breaks ties" semantics). CS map is probed
    ; before CI, mirroring the old exact-char-bucket-before-lowercased ordering.
    ;
    ; O(1) guards: skip the entire star path when neither index has entries
    ; (common when no magic-key hotstrings are configured), and skip the CS
    ; lookup when only CI triggers exist (the typical case — magic-key star
    ; triggers are almost all case-insensitive).
    HasCS := HSE_StarByTriggerCS.Count > 0
    HasCI := HSE_StarByTriggerCI.Count > 0
    ; No star triggers at all — skip the entire loop (SubStr + StrLower per suffix).
    if HasCS or HasCI {
        MaxSuffix := Min(BufLen, HSE_MaxStarTriggerLen)
        loop MaxSuffix {
            Suffix := SubStr(HSE_Buffer, -A_Index)
            ; Case-sensitive triggers: exact suffix key.
            if HasCS and HSE_StarByTriggerCS.Has(Suffix) {
                for _, Spec in HSE_StarByTriggerCS[Suffix] {
                    if !_HSE_Beats(Spec, BestMatch) {
                        continue
                    }
                    if _HSE_WordBoundaryAllows(HSE_Buffer, Spec) {
                        BestMatch := Spec
                        BestEndChar := ""
                    }
                }
            }
            ; Case-insensitive triggers: lowercased suffix key.
            if HasCI {
                LowerSuffix := StrLower(Suffix)
                if HSE_StarByTriggerCI.Has(LowerSuffix) {
                    for _, Spec in HSE_StarByTriggerCI[LowerSuffix] {
                        if !_HSE_Beats(Spec, BestMatch) {
                            continue
                        }
                        if _HSE_WordBoundaryAllows(HSE_Buffer, Spec) {
                            BestMatch := Spec
                            BestEndChar := ""
                        }
                    }
                }
            }
        }
    }

    ; ── END-CHAR path ──────────────────────────────────────────────
    if IsTerminator and (BodyLastChar != "") {
        ; ``:`` and ``;`` on the Ergopti Shift layer always arrive as
        ; ``NNBSP + :``. The NNBSP lands in the buffer BEFORE the ``:``
        ; end-char, so ``BodyBuf`` ends in ``…triggerNNBSP`` rather than
        ; ``…trigger``. To let these typographic end-chars still fire
        ; hotstrings we:
        ;   1. Strip the trailing NNBSP/NBSP from BodyBuf so matching sees
        ;      ``…trigger`` again (EffBody).
        ;   2. Require that NNBSP/NBSP was indeed present — a bare ``:`` or
        ;      ``;`` NOT preceded by an nbsp must NOT expand (e.g. the ``:``
        ;      in ``:D`` must stay literal).
        IsTypoEndChar := (JustTypedChar == ":" or JustTypedChar == Chr(0x3B))
        EffBody := BodyBuf
        ShouldMatch := true
        if IsTypoEndChar {
            LastOfBody := SubStr(BodyBuf, -1)
            if (LastOfBody == Chr(0x202F) or LastOfBody == Chr(0xA0)) {
                ; Strip the nbsp so the trigger can match the actual body text.
                EffBody := SubStr(BodyBuf, 1, StrLen(BodyBuf) - 1)
                HSE_TypoNbspStripped := true
            } else {
                ; A bare ``:`` / ``;`` without preceding nbsp is a mid-sequence
                ; character (e.g. ``:D``) and must not trigger any expansion.
                ShouldMatch := false
            }
        }
        if ShouldMatch {
            ; End-char matching is suffix equality just like star matching.
            ; Probe the bounded set of buffer suffixes against full-trigger
            ; indexes, rather than walking every same-tail candidate.
            HasEndCS := HSE_EndByTriggerCS.Count > 0
            HasEndCI := HSE_EndByTriggerCI.Count > 0
            if HasEndCS or HasEndCI {
                MaxSuffix := Min(StrLen(EffBody), HSE_MaxEndTriggerLen)
                loop MaxSuffix {
                    Suffix := SubStr(EffBody, -A_Index)
                    if HasEndCS and HSE_EndByTriggerCS.Has(Suffix)
                        _HSE_ConsiderEndSpecs(HSE_EndByTriggerCS[Suffix], EffBody, JustTypedChar, &BestMatch, &BestEndChar)
                    if HasEndCI {
                        LowerSuffix := StrLower(Suffix)
                        if HSE_EndByTriggerCI.Has(LowerSuffix)
                            _HSE_ConsiderEndSpecs(HSE_EndByTriggerCI[LowerSuffix], EffBody, JustTypedChar, &BestMatch, &BestEndChar)
                    }
                }
            }
        }
    }

    HSE_LastEndChar := BestEndChar
    return BestMatch
}

_HSE_ConsiderEndSpecs(Specs, EffBody, JustTypedChar, &BestMatch, &BestEndChar) {
    for _, Spec in Specs {
        if !_HSE_WordBoundaryAllows(EffBody, Spec)
            continue
        if _HSE_StarTriggerCoversBody(EffBody, Spec, JustTypedChar)
            continue
        if _HSE_EndCharBeats(Spec, BestMatch, BestEndChar != "") {
            BestMatch := Spec
            BestEndChar := JustTypedChar
        }
    }
}

; Return true when a registered star trigger would shadow the given end-char
; Spec, taking the typed end character into account. Suppression only happens
; when EndChar itself is the character that would continue Spec.Trigger toward
; the star trigger — i.e. when (Spec.Trigger + EndChar) is a prefix of a
; registered star trigger. If the end char cannot extend the prefix (e.g. the
; user typed space but the star trigger continues with the magic key), the
; end-char match is NOT suppressed.
;
; Example: Spec.Trigger = "ia", star trigger "ia★" (magic key = F20) registered.
;   - EndChar = " " (space): HSE_StarPrefixSetCI["ia"] has no " " entry →
;     suppression is FALSE → "ia " fires and expands to "IA ".   ✓
;   - EndChar = F20 (magic key): HSE_StarPrefixSetCI["ia"] has F20 entry →
;     suppression is TRUE → end-char match yields to the star trigger "ia★". ✓
;
; Implementation: O(1) double lookup — first check prefix exists, then check
; whether EndChar is among the recorded continuation characters. The
; HSE_StarPrefixSetCI/CS maps now store prefix → Map(nextChar → true) so the
; next-char membership test is also O(1).
_HSE_StarTriggerCoversBody(BodyBuf, Spec, EndChar) {
    global HSE_StarPrefixSetCI, HSE_StarPrefixSetCS
    ; Case-sensitive triggers only shadow other case-sensitive triggers.
    ; Case-insensitive triggers shadow both CI and CS (conservative suppression).
    if Spec.CaseSensitive {
        if !HSE_StarPrefixSetCS.Has(Spec.Trigger) {
            return false
        }
        return HSE_StarPrefixSetCS[Spec.Trigger].Has(EndChar)
    }
    LowerTrigger := StrLower(Spec.Trigger)
    if !HSE_StarPrefixSetCI.Has(LowerTrigger) {
        return false
    }
    return HSE_StarPrefixSetCI[LowerTrigger].Has(StrLower(EndChar))
}

; Populate HSE_StarPrefixSetCI and HSE_StarPrefixSetCS with all strict prefixes
; of the given star-trigger Spec, recording for each prefix which character
; immediately follows it in this star trigger. Multiple star triggers can share
; the same prefix with different continuation characters — each is recorded.
; Called once per registration (cold path only).
_HSE_IndexStarPrefixes(Spec) {
    global HSE_StarPrefixSetCI, HSE_StarPrefixSetCS
    if (Spec.Length <= 1) {
        return
    }
    ; Pick the target set and (for the case-insensitive path) lowercase the whole
    ; trigger ONCE up front instead of StrLower-ing every prefix and next-char
    ; inside the loop. Lowercasing commutes with substring for these triggers, so
    ; the keys land byte-identical — this is a pure speedup of the magic-key boot
    ; registration, which is the single heaviest category at startup (every star
    ; trigger walks all its prefixes here). ``Set`` aliases the global Map by
    ; reference, so inserts below mutate the real index.
    if Spec.CaseSensitive {
        TriggerText := Spec.Trigger
        Set := HSE_StarPrefixSetCS
    } else {
        TriggerText := StrLower(Spec.Trigger)
        Set := HSE_StarPrefixSetCI
    }
    ; Build each successive prefix by appending one char rather than re-slicing
    ; from position 1 each iteration (the old SubStr(Trigger, 1, i) was O(len^2)
    ; in total characters copied per registration).
    Len := StrLen(TriggerText)
    Prefix := ""
    loop (Len - 1) {
        Prefix .= SubStr(TriggerText, A_Index, 1)
        NextChar := SubStr(TriggerText, A_Index + 1, 1)
        if !Set.Has(Prefix) {
            Set[Prefix] := Map()
        }
        Set[Prefix][NextChar] := true
    }
}

; Insert one star Spec into the by-trigger index (incremental, O(1)). Keyed by
; the full trigger so HSE_FindMatchAtEnd can resolve a magic-key match with a
; handful of suffix lookups instead of scanning the whole magic-key bucket.
_HSE_IndexStarTrigger(Spec) {
    global HSE_StarByTriggerCI, HSE_StarByTriggerCS, HSE_MaxStarTriggerLen
    if (Spec.Length > HSE_MaxStarTriggerLen) {
        HSE_MaxStarTriggerLen := Spec.Length
    }
    if Spec.CaseSensitive {
        Key := Spec.Trigger
        if !HSE_StarByTriggerCS.Has(Key) {
            HSE_StarByTriggerCS[Key] := []
        }
        HSE_StarByTriggerCS[Key].Push(Spec)
    } else {
        Key := StrLower(Spec.Trigger)
        if !HSE_StarByTriggerCI.Has(Key) {
            HSE_StarByTriggerCI[Key] := []
        }
        HSE_StarByTriggerCI[Key].Push(Spec)
    }
}

; Add one non-star trigger to its exact or lowercased full-trigger index.
_HSE_IndexEndTrigger(Spec) {
    global HSE_EndByTriggerCI, HSE_EndByTriggerCS, HSE_MaxEndTriggerLen
    if (Spec.Length > HSE_MaxEndTriggerLen)
        HSE_MaxEndTriggerLen := Spec.Length
    if Spec.CaseSensitive {
        if !HSE_EndByTriggerCS.Has(Spec.Trigger)
            HSE_EndByTriggerCS[Spec.Trigger] := []
        HSE_EndByTriggerCS[Spec.Trigger].Push(Spec)
    } else {
        Key := StrLower(Spec.Trigger)
        if !HSE_EndByTriggerCI.Has(Key)
            HSE_EndByTriggerCI[Key] := []
        HSE_EndByTriggerCI[Key].Push(Spec)
    }
}

; Rebuild the non-star full-trigger indexes from the live last-char registry.
_HSE_RebuildEndTriggerIndex() {
    global HSE_RegistryByLastChar, HSE_EndByTriggerCI, HSE_EndByTriggerCS, HSE_MaxEndTriggerLen
    HSE_EndByTriggerCI := Map()
    HSE_EndByTriggerCS := Map()
    HSE_MaxEndTriggerLen := 0
    for _, Bucket in HSE_RegistryByLastChar {
        for _, Spec in Bucket {
            if !Spec.Star
                _HSE_IndexEndTrigger(Spec)
        }
    }
}

; Rebuild the by-trigger index from the current HSE_StarSpecs. Used after a
; group toggle splices the star set (HSE_DisableGroup), mirroring how the star
; prefix sets are rebuilt there — HSE_StarSpecs is the single source of truth.
_HSE_RebuildStarTriggerIndex() {
    global HSE_StarSpecs, HSE_StarByTriggerCI, HSE_StarByTriggerCS, HSE_MaxStarTriggerLen
    HSE_StarByTriggerCI := Map()
    HSE_StarByTriggerCS := Map()
    HSE_MaxStarTriggerLen := 0
    for _, S in HSE_StarSpecs {
        _HSE_IndexStarTrigger(S)
    }
}


; Return the bucket array(s) to scan for triggers ending in LookupChar.
; Both the case-sensitive bucket (literal LookupChar) and the
; case-insensitive bucket (lowercase LookupChar) are returned when they
; differ — a CaseSensitive=false trigger stored under its lowercased
; last char would otherwise never be probed for an uppercase keystroke.
_HSE_BucketsFor(LookupChar) {
    global HSE_RegistryByLastChar
    Out := []
    if HSE_RegistryByLastChar.Has(LookupChar) {
        Out.Push(HSE_RegistryByLastChar[LookupChar])
    }
    LowerKey := StrLower(LookupChar)
    ; !== is the strict inequality operator: AHK v2's loose != is
    ; case-insensitive, so "U" != "u" is FALSE and the fallback bucket
    ; would never be probed for case-insensitive triggers stored under
    ; their lowercased last char.
    if (LookupChar !== LowerKey) and HSE_RegistryByLastChar.Has(LowerKey) {
        Out.Push(HSE_RegistryByLastChar[LowerKey])
    }
    return Out
}

; Word-boundary gate. The char immediately preceding the matched suffix
; must be either absent (start of buffer — falls back to the
; HSE_StartIsWordBoundary flag) or a word terminator. ``Spec.InWord``
; (the AHK ``?`` flag) bypasses the check entirely.
_HSE_WordBoundaryAllows(Buf, Spec) {
    global HSE_StartIsWordBoundary, HSE_WORD_TERMINATORS
    if Spec.InWord {
        ; Repeat triggers (x★ → xx) require that the char being repeated is at
        ; least the 2nd letter of the current word — i.e. the char immediately
        ; before it in the buffer must itself be a non-terminator. Without this
        ; guard "c★" would fire at the start of a word (buffer = "c★"), where
        ; the repeat is meaningless and the user likely intended a text-expansion.
        if (Spec.HasOwnProp("IsRepeat") and Spec.IsRepeat) {
            ; Trigger is "x★": body char sits at BeforeLen, its predecessor at BeforeLen-1.
            BeforeLen := StrLen(Buf) - Spec.Length
            if (BeforeLen < 1) {
                return false
            }
            PredChar := SubStr(Buf, BeforeLen, 1)
            return InStr(HSE_WORD_TERMINATORS, PredChar) == 0
        }
        return true
    }
    BeforeLen := StrLen(Buf) - Spec.Length
    if (BeforeLen >= 1) {
        BeforeChar := SubStr(Buf, BeforeLen, 1)
        return InStr(HSE_WORD_TERMINATORS, BeforeChar) > 0
    }
    return HSE_StartIsWordBoundary
}




; =====================================================
; =====================================================
; ======= 2/ Suffix matching =========================
; =====================================================
; =====================================================

; Return true when Trigger is the suffix of Buffer (case-folded if
; CaseSensitive is false). Empty triggers never match.
HSE_SuffixMatches(Buffer, Trigger, CaseSensitive) {
    if (Trigger == "") {
        return false
    }
    BufLen := StrLen(Buffer)
    TrgLen := StrLen(Trigger)
    if (TrgLen > BufLen) {
        return false
    }
    BufSuffix := SubStr(Buffer, BufLen - TrgLen + 1)
    if CaseSensitive {
        return BufSuffix == Trigger
    }
    return StrLower(BufSuffix) == StrLower(Trigger)
}
