; lib/hotstrings/hotstring_dispatch.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Dispatch
; DESCRIPTION:
; Expansion dispatch for the custom hotstring engine: owns the full
; backspace+replacement burst, suppression lifecycle, AltGr fixup, Notepad
; clipboard route, case-conform resolution, and deferred KL marker release.
;
; FEATURES & RATIONALE:
; 1. Atomic SendInput burst — backspaces + replacement + end-char injected
;    as one unit so no physical keystroke can splice into the middle.
; 2. Raw-callback path — migrated native AHK Hotstring() registrations (e.g.
;    E-circumflex deadkey, ellipsis) dispatch through _HSE_DispatchRawCallback
;    with their own variable-length send contract.
; 3. Suppression via PrefixWatcherSuppress (refcount) so the InputHook ignores
;    AHK-generated characters during the burst.
;
; Included by lib/hotstrings/hotstring_engine_main.ahk.
; ==============================================================================

; Number of milliseconds we wait after the SendEvent burst before
; releasing HSE_Suppressed. Just enough margin for the OS message loop
; to drain the BackSpace/Replacement events through the InputHook so
; they are filtered out instead of polluting the buffer with our own
; replayed characters.
global HSE_SUPPRESS_RELEASE_DELAY_MS := 60




; ===============================================
; ===============================================
; ======= 1/ Dispatch ===========================
; ===============================================
; ===============================================

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
; Dispatch a "raw callback" hotstring (the natives migrated into the HSE: the
; E-circumflex deadkey and the "..." ellipsis). The callback does ALL of its own
; conditional, variable-length sending/backspacing and returns a { Bs, Ins } effect
; (Bs chars removed from the buffer's right, Ins appended) — or a falsy value when
; it declined to expand. We wrap it with the same prefix-watcher suppression +
; keylogger synthetic-marking the Replacement path uses, and resync HSE_Buffer from
; the effect so the next keystroke matches the post-expansion screen. This is what
; lets those two former native AHK Hotstring() registrations live in the HSE — no
; A_InputLevel dependency remains, so they register on the normal (and live-rebuild)
; path like every other section.
_HSE_DispatchRawCallback(Spec, EndChar) {
    global HSE_SUPPRESS_RELEASE_DELAY_MS, HSE_Buffer, HSE_MAX_BUFFER_LEN, HSE_StartIsWordBoundary
    if !(Spec.HasOwnProp("Callback") and Spec.Callback) {
        return false
    }
    ; Whether the callback actually expanded. A raw callback is allowed to DECLINE
    ; (the E-circumflex deadkey and ellipsis guards refuse in the wrong context) by
    ; returning a falsy effect or {Bs:0, Ins:""} — the caller must not then log a fire
    ; or strip the preview buffer for an expansion the user never saw.
    Fired := false
    ; Route through PrefixWatcherSuppress when available — it delegates to
    ; HSE_Suppress internally, so a SINGLE matched pair (true/false) keeps
    ; HSE_Suppressed balanced at depth 1. The direct HSE_Suppress(true) path is
    ; the fallback for contexts where the prefix watcher is not loaded (tools/,
    ; standalone tests). Mixing both paths would double-increment HSE_Suppressed
    ; to 2, requiring two release timers to fire — a timing assumption that breaks
    ; in CI environments where timer ordering is not guaranteed.
    if IsSet(PrefixWatcherSuppress) {
        try PrefixWatcherSuppress(true)
    } else {
        HSE_Suppress(true)
    }
    try KL_MarkSynthetic("hotstring")
    try {
        Effect := (Spec.Callback)(EndChar)
        ; A falsy Effect means the callback declined to expand — leave the buffer
        ; (with the trigger chars still in it) untouched.
        if (IsObject(Effect) and Effect.HasOwnProp("Bs")) {
            BufLen := StrLen(HSE_Buffer)
            Bs  := Max(0, Min(Effect.Bs, BufLen))
            if (Bs != Effect.Bs)
                try LoggerWarn("HSE", "Raw callback returned Bs={1} out of range [0,{2}] — clamped.", Effect.Bs, BufLen)
            Ins := Effect.HasOwnProp("Ins") ? Effect.Ins : ""
            ; Deleted nothing AND inserted nothing == the callback declined.
            Fired := (Bs > 0 or Ins != "")
            HSE_Buffer := (BufLen >= Bs ? SubStr(HSE_Buffer, 1, BufLen - Bs) : "") . Ins
            ; Mirror HSE_ApplyExpansion's cap so a future raw callback with a large
            ; Ins can never grow the buffer unbounded or drift the boundary flag.
            if (StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN) {
                HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
                HSE_StartIsWordBoundary := false
            }
        }
    } finally {
        if IsSet(_ResetPrefixBuffer) {
            try _ResetPrefixBuffer(true)
        }
        ; Release via the same path used to suppress — a single matched pair keeps
        ; HSE_Suppressed balanced. The PrefixWatcherSuppress path handles both the
        ; prefix-watcher counter and HSE_Suppressed in one call.
        if IsSet(PrefixWatcherSuppress) {
            SetTimer((*) => PrefixWatcherSuppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        } else {
            SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        }
        SetTimer((*) => KL_ClearSynthetic(), -HSE_SUPPRESS_RELEASE_DELAY_MS)
    }
    return Fired
}

; Returns TRUE when the match actually produced an expansion, FALSE when it declined
; (no spec, a raw callback that refused, a time-activation timeout, or a mixed-case
; conform verdict). Callers use this to decide whether a fire really happened: logging
; a fire — or stripping the preview buffer — for a decline reports an expansion the
; user never saw.
HSE_DispatchMatch(Spec, EndChar) {
    global HSE_SUPPRESS_RELEASE_DELAY_MS, _SendHook, HSE_TypoNbspStripped, HSE_Buffer
    if (Spec == "") {
        return false
    }
    ; Raw-callback specs (the natives migrated into the HSE: E-circumflex deadkey,
    ; "..." ellipsis) do all their own conditional, variable-length send/backspace;
    ; route them to _HSE_DispatchRawCallback so the engine never auto-strips a
    ; trigger the callback may have left in place.
    if (Spec.HasOwnProp("RawCallback") and Spec.RawCallback) {
        ; Propagate the callback's own verdict: it alone knows whether it expanded.
        return _HSE_DispatchRawCallback(Spec, EndChar)
    }
    if !Spec.HasOwnProp("Replacement") {
        Invoked := false
        if Spec.HasOwnProp("Callback") and Spec.Callback {
            try (Spec.Callback)(EndChar)
            Invoked := true
        }
        return Invoked
    }

    ; Time-activation gate: refuse to fire when the previous character
    ; was emitted too long ago. Mirrors IsTimeActivationExpired so
    ; cascading hotstrings inherit the same protection they had under
    ; the AHK-native engine.
    if Spec.HasOwnProp("TimeActivationSeconds")
        and Spec.TimeActivationSeconds > 0
        and Spec.HasOwnProp("PrevCharKey") {
        ; The gate keys off LastSentCharacterKeyTime, which UpdateLastSentCharacter
        ; stores by the char AS TYPED (so an UPPER "T" and a lowercase "t" are
        ; distinct entries). A case-conform spec carries the LOWERCASE canonical
        ; PrevCharKey, but the user may have typed the trigger in UPPER/Title — then
        ; the lowercase key-time is never refreshed and the activation wrongly
        ; expires (the "UPPER ct★ fires a few times then stops" regression from
        ; collapsing the per-case variants). For a conform spec read the prev char
        ; AS TYPED from the buffer (the char before the 1-char magic key, mirroring
        ; PrevCharKey = SubStr(Abbreviation, -2, 1)) so the lookup hits the right
        ; cased entry. Non-conform specs keep their precomputed per-case PrevCharKey.
        PrevKey := Spec.PrevCharKey
        if (Spec.HasOwnProp("CaseConform") and Spec.CaseConform) {
            TypedPrev := SubStr(HSE_Buffer, -2, 1)
            if (TypedPrev != "") {
                PrevKey := TypedPrev
            }
        }
        if IsTimeActivationExpired(PrevKey, Spec.TimeActivationSeconds) {
            return false
        }
    }

    ; ── Case-conform gate ───────────────────────────────────────────────────
    ; For a conform spec (registered case-insensitively by CreateCaseSensitiveHotstrings
    ; in place of explicit lower/UPPER/Title variants), resolve the output casing
    ; from the trigger as it was actually typed — the last Spec.Length chars still
    ; sitting in HSE_Buffer (conform specs are always star triggers, EndChar == "",
    ; so no end-char/nbsp offset is involved). Doing this BEFORE we take the
    ; suppress/synthetic locks means a "mixed case → do not fire" verdict is a clean
    ; early return with no lock state to unwind, exactly matching the old behaviour
    ; where no spec was ever registered for a mixed-case trigger.
    IsConform := Spec.HasOwnProp("CaseConform") and Spec.CaseConform
    ConformedRepl := ""
    if IsConform {
        ResolvedRepl := Spec.Replacement
        if HasMethod(ResolvedRepl)
            ResolvedRepl := ResolvedRepl()
        TypedTrigger := SubStr(HSE_Buffer, -Spec.Length)
        DoFire := true
        ConformedRepl := _HSE_ConformReplacement(ResolvedRepl, TypedTrigger, Spec.Trigger,
            (Spec.HasOwnProp("ConformOneChar") and Spec.ConformOneChar), &DoFire)
        if !DoFire {
            return false
        }
    }

    ; Route through PrefixWatcherSuppress when available — it delegates to
    ; HSE_Suppress internally, so a SINGLE matched pair (true/false) keeps
    ; HSE_Suppressed balanced at depth 1. The direct HSE_Suppress(true) path is
    ; the fallback for contexts where the prefix watcher is not loaded (tools/,
    ; standalone tests). Mixing both paths would double-increment HSE_Suppressed
    ; to 2, requiring two release timers to fire — a timing assumption that breaks
    ; in CI environments where timer ordering is not guaranteed.
    ; Mirror _HotstringDispatch's PrefixWatcherSuppress guard: mute the
    ; prefix watcher for the duration of the send burst so the backspaces
    ; and replacement characters do not pollute _PrefixBuffer and stale the
    ; tooltip state. Without this, calling HSE_DispatchMatch from outside the
    ; InputHook callback (e.g. SpaceTapHold) leaves _PrefixBuffer pointing at
    ; the pre-expansion context, causing incorrect tooltip lookups afterward.
    if IsSet(PrefixWatcherSuppress) {
        try PrefixWatcherSuppress(true)
    } else {
        HSE_Suppress(true)
    }
    ; Tag the backspace+replacement burst as synthetic so the keylogger keeps
    ; it out of the manual `chars` count and attributes the resulting n-grams
    ; to the hotstring source (esrc). Released on the same deferred timer as
    ; the suppression below so it covers the OS message-loop flush window.
    try KL_MarkSynthetic("hotstring")
    try {
        if _ALTGR_KANA_FIXUP {
            ; SendInput (not SendEvent) — non-blocking injection that does not
            ; yield the message loop. SendEvent was adding ~10-20 ms of latency
            ; on every expansion on AltGr-fixup keyboards by flushing through
            ; the hook chain synchronously. SendInput injects directly into the
            ; kernel input queue, clears the stuck AltGr state before the burst,
            ; and returns immediately — consistent with the SendInput burst below.
            SendInput("{SC138 Up}")
        }

        ; +1 for the NNBSP/NBSP that was stripped before matching when the
        ; end-char is a typographic punctuation (``:`` / `` ; ``).
        BSCount := Spec.Length + (EndChar != "" ? 1 : 0) + (HSE_TypoNbspStripped ? 1 : 0)
        BackSpaceSeq := "{BackSpace " . BSCount . "}"
        ; For a conform spec the replacement was already resolved + cased by the
        ; case-conform gate above; otherwise take it straight from the Spec.
        Replacement := IsConform ? ConformedRepl : Spec.Replacement
        ; Allow a non-conform Replacement to be a callable — resolved at fire time
        ; so dynamic values (dates, live data) are computed on each keystroke.
        if (!IsConform and HasMethod(Replacement))
            Replacement := Replacement()
        OnlyText := Spec.HasOwnProp("OnlyText") ? Spec.OnlyText : true
        ; (KLHook global removed)
        IsNotepadApp := false
        try {
            exe := (IsSet(KLHook) and KLHook.HasOwnProp("prev_app")) ? KLHook.prev_app : WinGetProcessName("A")
            IsNotepadApp := (exe = "notepad.exe")
        }
        SentBurst := ""   ; exactly what we injected — captured for the fire-trace

        if IsNotepadApp {
            ; Windows-11 Notepad mis-handles SendInput-injected hotstrings, so the
            ; replacement is routed through the clipboard. SendInstant accepts the
            ; erase sequence as a prefix and injects it with Ctrl+V in one SendInput
            ; burst, so no physical key can land between erase and paste.
            ; Mirror the atomic branch's consumed-delimiter guard so a space
            ; (or any other consumed end-char) is not re-injected after the
            ; clipboard paste — same contract as the SendInput path.
            EndCharEmitted := (EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)) ? EndChar : ""
            _NpCrit := Critical("On")
            try {
                ; BackSpaceSeq is a control sequence, not emitted text. The actual
                ; last character is recorded explicitly below after the atomic paste.
                SendInstant(Replacement . EndCharEmitted, BackSpaceSeq)
            } finally {
                Critical(_NpCrit)
            }
            UpdateLastSentCharacter(SubStr(EndCharEmitted != "" ? EndCharEmitted : Replacement, -1))
            SentBurst := BackSpaceSeq . "[clip]" . Replacement . EndCharEmitted
        } else {
            ; SendInput is atomic: the ENTIRE backspace+replacement+endchar burst is
            ; injected as one unit, so any physical keystroke the user types during
            ; the expansion is buffered by the OS and delivered AFTER it — never
            ; spliced into the middle (the race that produced "outpubct" /
            ; "Cha[letter]tGPT"). This single path now also serves former
            ; final_result triggers: post the SendInput migration every expansion is
            ; non-cascading anyway, so the old 3-call SendFinalResult branch (which
            ; sent BackSpace, Replacement and EndChar as SEPARATE SendInputs with
            ; interleave gaps between them) was both redundant and the interleave
            ; source — folded into this one atomic send, which additionally grants
            ; those triggers the {Text} wrapping, consumed-delimiter handling and
            ; UpdateLastSentCharacter the split branch silently skipped.
            ReplacementPart := OnlyText ? ("{Text}" . Replacement) : Replacement
            ; Consume the end-char when it is explicitly listed as consumed —
            ; otherwise always re-inject it so the user sees what they typed.
            EndCharPart := (EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)) ? EndChar : ""
            Burst := BackSpaceSeq . ReplacementPart . EndCharPart
            ; Critical so AHK cannot start the next physical key's layout-remap
            ; SendEvent thread between issuing this burst and it draining — keeping
            ; the expansion atomic even when dispatched from a caller that is NOT
            ; already Critical (e.g. the Space tap-hold path). Save/restore nests
            ; safely under _OnPrefixChar's Critical. No Sleep here, so it is safe to
            ; hold. Route through _SendHook when present (test harness) so the entire
            ; atomic burst is recorded and assertions can inspect it; in production
            ; _SendHook is unset and SendInput fires directly.
            _AtCrit := Critical("On")
            try {
                if _SendHook {
                    Hook := _SendHook
                    Hook("SendFinalResult", Burst, false)
                } else {
                    SendInput(Burst)
                }
            } finally {
                Critical(_AtCrit)
            }
            UpdateLastSentCharacter(SubStr(EndCharPart != "" ? EndCharPart : Replacement, -1))
            SentBurst := Burst
        }

        ; ── Diagnostic fire-trace (debug only) ──────────────────────────────────
        ; One line per expansion capturing the exact injected burst, branch and
        ; context, so a reproduction of an interleave/drop ("outpubct",
        ; "abcd"->"acd") can be read straight off the log. Debug-gated so normal
        ; typing stays silent; enable via tray Debug -> Log level -> DEBUG.
        if LoggerIsDebugEnabled() {
            try LoggerDebug("HSEFire",
                "FIRE trig='{1}' end='{2}' bs={3} branch={4} conform={5} burst='{6}'.",
                Spec.Trigger, EndChar, BSCount, IsNotepadApp ? "notepad-clip" : "atomic",
                IsConform ? 1 : 0, SentBurst)
        }

        ; Mirror the post-expansion screen state into the buffer so the
        ; next keystroke matches against the right context. Done while
        ; suppression is still active so the SetTimer release does not
        ; race with us.
        HSE_ApplyExpansion(Spec, Replacement, EndChar)
    } finally {
        ; Reset the prefix watcher buffer synchronously so the post-expansion
        ; state is immediately clean. This must happen before the deferred
        ; Suppress(false) fires so that PrefixWatcherSuppress(false) does not
        ; find a stale buffer and clear it 60 ms later — which would erase the
        ; first keystrokes of the next word if the user types quickly.
        if IsSet(_ResetPrefixBuffer) {
            try _ResetPrefixBuffer(true)
        }
        ; Release via the same path used to suppress — a single matched pair keeps
        ; HSE_Suppressed balanced. The PrefixWatcherSuppress path handles both the
        ; prefix-watcher counter and HSE_Suppressed in one call.
        if IsSet(PrefixWatcherSuppress) {
            SetTimer((*) => PrefixWatcherSuppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        } else {
            SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        }
        ; Release the synthetic flag on the same flush window as the suppression
        ; — clearing inline would let trailing replacement keystrokes look manual.
        SetTimer((*) => KL_ClearSynthetic(), -HSE_SUPPRESS_RELEASE_DELAY_MS)
    }
    ; Reached only when the replacement was actually emitted.
    return true
}
