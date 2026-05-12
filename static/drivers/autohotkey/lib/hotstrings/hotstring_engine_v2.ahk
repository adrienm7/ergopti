; static/drivers/autohotkey/lib/hotstring_engine_v2.ahk

; ==============================================================================
; MODULE: Hotstring Engine V2
; DESCRIPTION:
; Custom hotstring engine that replaces AHK's built-in Hotstring() for
; ErgoptiPlus's hotstrings. The native engine maintains its own opaque buffer
; and resets it on every Backspace / arrow / Home / End / etc., which makes
; it impossible to express the rule the user actually wants:
;
;     « Backspace and navigation keys preserve the current word context.
;       Only true separators (space, punctuation, Enter, Tab) introduce a
;       new word. »
;
; This rewrite owns the buffer end-to-end so the prefix watcher tooltip and
; the trigger matching share one source of truth — they cannot diverge by
; construction.
;
; FEATURES & RATIONALE:
; 1. Single source of truth — HSE_Buffer + HSE_StartIsWordBoundary describe
;    « what is to the left of the cursor, plus whether that left side starts
;    on a word boundary ». The prefix watcher reads the same buffer for its
;    tooltip preview; the dispatch loop reads it to decide whether a trigger
;    fires. Tooltip and behaviour cannot disagree.
; 2. Word-boundary semantics chosen for typing comfort:
;      - Printable char appends to buffer; if it is a word terminator the
;        buffer is reset and the « before-the-cursor was a terminator » flag
;        is set true (because the just-typed terminator now sits there).
;      - Backspace decrements the buffer (one char off the right end).
;        When the buffer is already empty, it instead sets the boundary flag
;        to false because we just deleted into unknown territory.
;      - Arrows / Home / End / PgUp / PgDn / Insert / Delete / Escape /
;        mouse click / disruptive Ctrl combos (X / V / Z / Y) reset the
;        buffer and set the boundary flag to false (cursor moved or context
;        rewritten — we cannot know whether the new cursor position is at a
;        word boundary).
;      - Ctrl+A is a special case: it replaces the entire selection with the
;        next typed char, so the new context starts at a word boundary.
; 3. O(1) match lookup keyed by trigger's last char. Each keystroke only
;    scans the bucket of triggers that end with the just-typed char (or the
;    just-typed end character).
; 4. Pure-function core. HSE_FeedChar / HSE_FeedBackspace / HSE_FeedReset /
;    HSE_FindMatchAtEnd / HSE_ApplyExpansion all operate on the module
;    globals without touching the OS — exhaustively testable from the unit
;    suite. The InputHook + SendEvent wiring lives at the edges and is
;    layered on top in a later phase.
; ==============================================================================

; ============================================
; ============================================
; ======= 1/ Constants =======
; ============================================
; ============================================

; Maximum buffer length. Anything older than the longest registered trigger
; is irrelevant for matching; we cap so memory and lookup cost stay bounded.
; 64 chars matches the prefix watcher's HSE_MAX_BUFFER_LEN equivalent.
global HSE_MAX_BUFFER_LEN := 64

; Word terminators: characters whose typing ends the current word and
; resets the buffer. The newline characters cover SendInput-injected
; replacements that terminate with `r`n (rare but possible).
global HSE_WORD_TERMINATORS := " `t`r`n.,;:?!"


; ============================================
; ============================================
; ======= 2/ State =======
; ============================================
; ============================================

; The user-typed buffer to the left of the cursor. Mirrors the visible
; screen content as best we can observe — updated by HSE_FeedChar (append),
; HSE_FeedBackspace (chop one char), HSE_FeedReset (clear), and
; HSE_ApplyExpansion (replace trigger suffix by replacement).
global HSE_Buffer := ""

; True when the character immediately to the left of HSE_Buffer is known to
; be a word terminator (or there is no character at all — start of input).
; Flipped to false whenever the cursor moves into an unknown context.
; Used by the word-boundary check when a trigger sits flush at the start of
; the buffer (BeforeLen == 0) — without this flag we could not distinguish
; « fresh document » from « cursor moved mid-word and buffer was reset ».
global HSE_StartIsWordBoundary := true

; Map(LastChar -> Array of HSE_Trigger objects). Each entry owns the
; trigger string, the callback, and parsed flags (case-sensitive, in-word
; allowed). Indexed by the trigger's last char so HSE_FindMatchAtEnd only
; scans the relevant subset on every keystroke. Case-insensitive triggers
; are bucketed under their lowercase last char; case-sensitive ones under
; the literal last char.
global HSE_RegistryByLastChar := Map()

; Suppression flag. When true, FeedChar / FeedBackspace / FeedReset
; short-circuit. The dispatch loop sets it for the duration of the
; SendEvent burst so its own replacement output does not feed back into
; the buffer through the InputHook.
global HSE_Suppressed := false

; Surface for tests and higher layers: the most recent match returned by
; HSE_FeedChar. "" when no match. Reset to "" at the start of each FeedChar
; so consecutive « no match » keystrokes do not surface a stale value.
global HSE_LastMatch := ""

; The end character associated with HSE_LastMatch:
;   - "" when the match is a star (immediate) trigger.
;   - the just-typed terminator when the match is a non-star (end-char-gated)
;     trigger.
; Surfaced so the dispatch and the InputHook agree on whether to BackSpace
; an extra char and re-emit it after the replacement.
global HSE_LastEndChar := ""


; ============================================
; ============================================
; ======= 3/ Public registry API =======
; ============================================
; ============================================

; Register a trigger. The Flags string mirrors the AHK Hotstring() option
; letters so existing callers (CreateHotstring, CreateCaseSensitiveHotstrings,
; LoadHotstringsSection) translate one-for-one once the wire-up commit lands.
;
;   Flags:
;     « * » — trigger fires immediately on its last char (no end-char gate).
;     « ? » — trigger may match in the middle of a word (no word-boundary
;             check on the char preceding the trigger).
;     « C » — case-sensitive match.
;
; Without « * » the trigger only fires when an end character (one of
; HSE_WORD_TERMINATORS) is typed right after — that end character is
; consumed by the dispatch and re-injected by HSE_ApplyExpansion.
HSE_Register(Flags, Trigger, Callback, Meta := unset) {
    global HSE_RegistryByLastChar
    if (Trigger == "") {
        return
    }
    Spec := {
        Trigger:       Trigger,
        Length:        StrLen(Trigger),
        Callback:      Callback,
        Star:          InStr(Flags, "*") > 0,
        InWord:        InStr(Flags, "?") > 0,
        CaseSensitive: InStr(Flags, "C") > 0
    }
    ; Optional dispatch metadata. When present, HSE_DispatchMatch performs
    ; the BackSpace/Replacement/EndChar burst itself and ignores Callback.
    ; When absent (e.g. unit tests passing a bare lambda), HSE_DispatchMatch
    ; falls through to invoking Callback so existing test harnesses keep
    ; working unchanged.
    if IsSet(Meta) {
        for Key, Val in Meta.OwnProps() {
            Spec.%Key% := Val
        }
    }
    LastChar := SubStr(Trigger, -1)
    LookupKey := Spec.CaseSensitive ? LastChar : StrLower(LastChar)
    if !HSE_RegistryByLastChar.Has(LookupKey) {
        HSE_RegistryByLastChar[LookupKey] := []
    }
    HSE_RegistryByLastChar[LookupKey].Push(Spec)
}

; Erase the entire registry. Tests rely on this between cases; the live
; engine never needs it because Reload re-runs the registration code from
; scratch with a fresh module state.
HSE_RegistryClear() {
    global HSE_RegistryByLastChar
    HSE_RegistryByLastChar := Map()
}


; ============================================
; ============================================
; ======= 4/ Buffer mutation =======
; ============================================
; ============================================

; Append a printable character to the buffer and report whether a trigger
; just matched. Word terminators are appended to the buffer like any other
; char so triggers that contain or START with a terminator can still match
; (e.g. a personal hotstring « ,a → ja » that turns a comma into the J
; key). The earlier reset-on-terminator design made such triggers
; structurally impossible to fire — typing « , » would erase the comma
; from the buffer before « a » could be read as the second char.
;
; Word boundaries for the « is_word » check are read directly off the
; buffer: a literal terminator sitting one position before the trigger
; matched in the buffer is recognised as a boundary by the existing
; word-boundary logic in HSE_FindMatchAtEnd. The HSE_StartIsWordBoundary
; flag still applies when a trigger sits flush at byte index 1 of the
; buffer.
;
; Returns the matching Spec object or "" when nothing matched. The
; associated end character is exposed via HSE_LastEndChar — empty for
; star triggers, the just-typed terminator for end-char-gated triggers.
HSE_FeedChar(Char) {
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN
    global HSE_LastMatch, HSE_LastEndChar, HSE_Suppressed
    HSE_LastMatch := ""
    HSE_LastEndChar := ""
    if HSE_Suppressed or (Char == "") {
        return ""
    }

    HSE_Buffer .= Char
    if (StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN) {
        ; Drop the oldest characters; once trimmed we can no longer prove
        ; the new start sits on a word boundary, so flip the flag.
        HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
        HSE_StartIsWordBoundary := false
    }

    Match := HSE_FindMatchAtEnd(Char)
    HSE_LastMatch := Match
    return Match
}

; Backspace: chop the last character off the buffer. When the buffer is
; already empty, instead flip HSE_StartIsWordBoundary to false because the
; user has just deleted a character that lived to the LEFT of the buffer's
; start, into territory we never observed — we can no longer guarantee the
; new cursor position abuts a word boundary.
HSE_FeedBackspace() {
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
    if HSE_Suppressed {
        return
    }
    if (HSE_Buffer != "") {
        HSE_Buffer := SubStr(HSE_Buffer, 1, StrLen(HSE_Buffer) - 1)
        return
    }
    HSE_StartIsWordBoundary := false
}

; Generic reset. KnownTerminatorBefore declares whether the caller can
; vouch for the new cursor position abutting a word boundary:
;   - true for keystrokes that land at a known fresh context: Tab, Enter
;     (terminator emitted), Ctrl+A (selection replaced), arrows, Escape,
;     mouse click (cursor moved — next run starts fresh).
;   - false for destructive or content-replacing operations where the
;     buffer content to the left is completely unknown: Ctrl+X (cut),
;     Ctrl+V (paste), Ctrl+Z/Y (undo/redo), backspace on empty buffer.
HSE_FeedReset(KnownTerminatorBefore := false) {
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
    if HSE_Suppressed {
        return
    }
    HSE_Buffer := ""
    HSE_StartIsWordBoundary := !!KnownTerminatorBefore
}

; Suppress / un-suppress feeds for the duration of an internal SendEvent
; burst. The release no longer wipes the buffer because HSE_DispatchMatch
; now calls HSE_ApplyExpansion immediately after its send burst — that
; mirrors the post-expansion screen state exactly, and a wipe here would
; throw it away and turn « config★ » into a buffer of "" with a default
; word-boundary flag of false (the next char would then refuse to fire
; because it would not know the cursor sits at a word boundary).
;
; Callers that genuinely want to wipe the buffer (e.g. on focus change to
; an unknown context) should call HSE_HardReset() explicitly.
HSE_Suppress(YesNo) {
    global HSE_Suppressed
    HSE_Suppressed := !!YesNo
}

; Force the buffer back to a known-empty state with no word-boundary
; assumption. Use sparingly — a hard reset means subsequent triggers that
; sit flush at the start of the new buffer will refuse to fire until a
; word terminator has been observed.
HSE_HardReset() {
    global HSE_Buffer, HSE_StartIsWordBoundary
    HSE_Buffer := ""
    HSE_StartIsWordBoundary := false
}

; Apply an expansion to the buffer to mirror the screen change a hotstring
; fire produces. The trigger suffix is stripped off the right end together
; with the end character (when one is involved — the dispatcher BackSpaces
; both off the screen) and the replacement is appended, followed by the
; end character re-emitted. The buffer therefore matches « what the cursor
; sits behind » exactly, regardless of whether the end char was a word
; terminator (the new HSE_FeedChar keeps terminators in the buffer too,
; so triggers that span them — e.g. « ,a → ja » — can still match).
HSE_ApplyExpansion(Spec, Replacement, EndChar := "") {
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN

    StripLen := Spec.Length + (EndChar != "" ? 1 : 0)
    BufLen := StrLen(HSE_Buffer)

    ; Strip the trigger suffix (and the end char when present). Be
    ; defensive: if the buffer drifted out of sync we still strip
    ; StripLen chars off the right end since that reflects the BackSpace
    ; count the dispatcher will send.
    if (BufLen >= StripLen) {
        HSE_Buffer := SubStr(HSE_Buffer, 1, BufLen - StripLen)
    } else {
        HSE_Buffer := ""
    }

    ; Append the replacement, then the end character if any.
    HSE_Buffer .= Replacement
    if (EndChar != "") {
        HSE_Buffer .= EndChar
    }

    if (StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN) {
        HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
        HSE_StartIsWordBoundary := false
    }
}


; ============================================
; ============================================
; ======= 5/ Match logic =======
; ============================================
; ============================================

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
    global HSE_WORD_TERMINATORS, HSE_LastEndChar

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
    Buckets := _HSE_BucketsFor(JustTypedChar)
    for _, Bucket in Buckets {
        for _, Spec in Bucket {
            if !Spec.Star {
                continue
            }
            if !HSE_SuffixMatches(HSE_Buffer, Spec.Trigger, Spec.CaseSensitive) {
                continue
            }
            if !_HSE_WordBoundaryAllows(HSE_Buffer, Spec) {
                continue
            }
            if (BestMatch == "" or Spec.Length > BestMatch.Length) {
                BestMatch := Spec
                BestEndChar := ""
            }
        }
    }

    ; ── END-CHAR path ──────────────────────────────────────────────
    if IsTerminator and (BodyLastChar != "") {
        Buckets2 := _HSE_BucketsFor(BodyLastChar)
        for _, Bucket in Buckets2 {
            for _, Spec in Bucket {
                if Spec.Star {
                    continue
                }
                if !HSE_SuffixMatches(BodyBuf, Spec.Trigger, Spec.CaseSensitive) {
                    continue
                }
                if !_HSE_WordBoundaryAllows(BodyBuf, Spec) {
                    continue
                }
                if (BestMatch == "" or Spec.Length > BestMatch.Length) {
                    BestMatch := Spec
                    BestEndChar := JustTypedChar
                }
            }
        }
    }

    HSE_LastEndChar := BestEndChar
    return BestMatch
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
        return true
    }
    BeforeLen := StrLen(Buf) - Spec.Length
    if (BeforeLen >= 1) {
        BeforeChar := SubStr(Buf, BeforeLen, 1)
        return InStr(HSE_WORD_TERMINATORS, BeforeChar) > 0
    }
    return HSE_StartIsWordBoundary
}

; ============================================
; ============================================
; ======= 6/ Dispatch =======
; ============================================
; ============================================

; Number of milliseconds we wait after the SendEvent burst before
; releasing HSE_Suppressed. Just enough margin for the OS message loop
; to drain the BackSpace/Replacement events through the InputHook so
; they are filtered out instead of polluting the buffer with our own
; replayed characters.
global HSE_SUPPRESS_RELEASE_DELAY_MS := 60

; Fire the expansion attached to a matched Spec. Owns the entire
; replacement burst end-to-end:
;   1. Optional time-activation gate.
;   2. Suppression on, AltGr Kana fixup if needed.
;   3. BackSpace ``Spec.Length + (EndChar != "" ? 1 : 0)`` characters off
;      the screen — when an end character is involved, the OS already
;      typed it through the InputHook so we have to delete it too.
;   4. SendEvent / SendInput / SendInstant the replacement and the end
;      character, mirroring the three branches of the original
;      _HotstringDispatch (Notepad clipboard route, FinalResult, default).
;   5. HSE_ApplyExpansion to mirror the new screen state into the buffer.
;   6. Deferred Suppress(false) so in-flight events stay filtered.
;
; Specs without dispatch metadata (Replacement undefined — the unit-test
; path) fall through to invoking Spec.Callback for backwards
; compatibility with the test-only registrations.
HSE_DispatchMatch(Spec, EndChar) {
    global HSE_SUPPRESS_RELEASE_DELAY_MS
    if !Spec.HasOwnProp("Replacement") {
        if Spec.HasOwnProp("Callback") and Spec.Callback {
            try (Spec.Callback)(EndChar)
        }
        return
    }

    ; Time-activation gate: refuse to fire when the previous character
    ; was emitted too long ago. Mirrors IsTimeActivationExpired so
    ; cascading hotstrings inherit the same protection they had under
    ; the AHK-native engine.
    if Spec.HasOwnProp("TimeActivationSeconds")
        and Spec.TimeActivationSeconds > 0
        and Spec.HasOwnProp("PrevCharKey") {
        if IsTimeActivationExpired(Spec.PrevCharKey, Spec.TimeActivationSeconds) {
            return
        }
    }

    HSE_Suppress(true)
    try {
        if _ALTGR_KANA_FIXUP {
            SendEvent("{SC138 Up}")
        }

        BSCount := Spec.Length + (EndChar != "" ? 1 : 0)
        BackSpaceSeq := "{BackSpace " . BSCount . "}"
        Replacement := Spec.Replacement
        OnlyText := Spec.HasOwnProp("OnlyText") ? Spec.OnlyText : true
        FinalResult := Spec.HasOwnProp("FinalResult") ? Spec.FinalResult : false

        if GetActiveApp().IsNotepad {
            ; Same Windows-11 Notepad workaround as the original engine.
            SendNewResult(BackSpaceSeq, false)
            SendInstant(Replacement . EndChar)
        } else if FinalResult {
            SendFinalResult(BackSpaceSeq, false)
            SendFinalResult(Replacement, OnlyText)
            if (EndChar != "") {
                SendFinalResult(EndChar, false)
            }
        } else {
            SendNewResult(BackSpaceSeq, false)
            SendNewResult(Replacement, OnlyText)
            if (EndChar != "") {
                SendNewResult(EndChar, false)
            }
        }

        ; Mirror the post-expansion screen state into the buffer so the
        ; next keystroke matches against the right context. Done while
        ; suppression is still active so the SetTimer release does not
        ; race with us.
        HSE_ApplyExpansion(Spec, Replacement, EndChar)
    } finally {
        SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
    }
}


; ============================================
; ============================================
; ======= 7/ Suffix matching =======
; ============================================
; ============================================

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
