; drivers/autohotkey/lib/hotstring_prefix_watcher.ahk

; ==============================================================================
; MODULE: Hotstring Prefix Watcher
; DESCRIPTION:
; Real-time observer that mirrors the Hammerspoon hotstring tooltip: while the
; user is typing characters that prefix one (or more) registered triggers, a
; tooltip is shown previewing the eventual expansion, tinted with the colour
; of the matching group. The tooltip vanishes when:
;   - The user finishes the trigger and the hotstring fires.
;   - The user types a non-matching character (prefix lost).
;   - The auto-hide timer fires (per-group delay).
;   - A word-breaking key is pressed (Space, Enter, Tab, Escape, Backspace,
;     arrow keys, mouse click).
;
; FEATURES & RATIONALE:
; 1. TOML-only registry — the watcher parses each category TOML directly to
;    build its index instead of hooking the engine's CreateHotstring path.
;    This keeps the watcher fully decoupled from the registration internals
;    and works equally well with the ``_GENERATED_HOTSTRINGS`` fast path.
; 2. Single InputHook in pass-through mode (``V`` flag) so every keystroke
;    reaches its destination unchanged — the watcher is a passive observer.
; 3. Prefix index keyed by lowercase substring, mapping to all triggers that
;    have it as a prefix. O(1) lookup per keystroke regardless of registry
;    size; matches the HS behaviour that handles ~1000 triggers comfortably.
; 4. MIN_PREFIX_LEN = 2 — single-letter prefixes match too many triggers to
;    be useful as a preview signal, and would surface a tooltip on every
;    keystroke. HS uses the same heuristic implicitly (its trigger set
;    rarely starts firing on length 1).
; ==============================================================================

; The prefix index built at boot. Map(lowerPrefix -> Array of entries), where
; each entry is { Trigger, Output, Category, Section, Length }.
global _PrefixIndex := Map()

; Flat set of all known trigger strings (lower-cased) → entry object.
; Used by the near-miss detector in _ResetPrefixBuffer so it can check
; exact trigger equality and Levenshtein-1 neighbours without re-walking
; the prefix tree.
global _TriggerSet := Map()

; Live keystroke buffer with original casing preserved — the index now holds
; one entry per case variant (``ct`` / ``Ct`` / ``CT`` for non-strict
; triggers, exactly mirroring CreateCaseSensitiveHotstrings), so the lookup
; is a byte-for-byte match against this buffer. Trimmed to MAX_BUFFER_LEN
; whenever it would overflow so memory and lookup cost stay bounded.
global _PrefixBuffer := ""

; Reference to the running InputHook (kept global so the GC does not collect
; it and so that the watcher can be reset / stopped at shutdown).
global _PrefixInputHook := 0

; When True, OnChar / OnKeyDown callbacks short-circuit. Toggled by the
; hotstring engine while it is replaying characters via SendEvent so the
; InputHook does not mistake AHK's own output for fresh user input. After
; an expansion fires, the buffer would otherwise drift into ``c'était`` and
; surface unrelated triggers like ``taiwan`` (Taïwan) on the next refresh.
global _PrefixWatcherSuppressed := false

; Currently-suggested hotstring — populated when a tooltip transitions
; from hidden to visible, cleared when the tooltip hides (and a dismissed
; event is logged) or when a fire consumes the suggestion (silent clear).
; Object shape: { Trigger, Output, Category } or "" when no tooltip is up.
; Used to mirror Hammerspoon's M.log_hotstring_suggested / dismissed pair
; logging — HS pairs every "suggested" with exactly one "dismissed" or one
; "fired", never both, so we track state here to enforce the same contract.
global _KLLastShownSuggestion := ""

; Configuration constants.
global _MIN_PREFIX_LEN := 2
global _MAX_BUFFER_LEN := 64    ; longest trigger we expect, with margin

; Categories scanned at boot. The order matches Hammerspoon's default load
; order so a tie on the prefix index returns the same first-match across
; both drivers.
global _PREFIX_WATCHER_CATEGORIES := [
    "distancesreduction", "sfbsreduction", "rolls",
    "autocorrection", "magickey", "personal"
]





; ============================================================
; ============================================================
; ======= 1/ Public API =====================================
; ============================================================
; ============================================================

; Build the prefix index from every category TOML and start the InputHook.
; Idempotent — calling it twice is a no-op (the second call only logs).
HotstringPrefixWatcherInit() {
    global _PrefixInputHook, _PrefixIndex, _PREFIX_WATCHER_CATEGORIES
    if _PrefixInputHook {
        LoggerWarn("PrefixWatcher", "Init called twice — ignoring duplicate.")
        return
    }
    LoggerStart("PrefixWatcher", "Initializing prefix watcher…")

    EntryCount := 0
    for _, Category in _PREFIX_WATCHER_CATEGORIES {
        CatCount := _RegisterCategoryTriggers(Category)
        LoggerDebug("PrefixWatcher", "DBG category '{1}': {2} trigger(s) indexed.", Category, CatCount)
        EntryCount += CatCount
    }

    LoggerDebug("PrefixWatcher", "DBG index built: {1} trigger(s), {2} prefix bucket(s).", EntryCount, _PrefixIndex.Count)
    LoggerDebug("PrefixWatcher", "DBG 'ct' in index: {1}.", _PrefixIndex.Has("ct") ? "YES" : "NO")
    _StartInputHook()
    _InstallMouseClickResetHooks()
    LoggerSuccess("PrefixWatcher", "Watcher started ({1} trigger(s) indexed).", EntryCount)
}

; Mouse clicks move the cursor to a position we cannot observe — the
; InputHook never sees them. Register pass-through hotkeys on the three
; primary buttons so HSE can wipe its buffer and refuse to assume a
; word boundary on the new cursor's left. ``~`` keeps the click going
; through to the active window unchanged.
_InstallMouseClickResetHooks() {
    Hotkey("~LButton", _OnMouseClickReset)
    Hotkey("~MButton", _OnMouseClickReset)
    Hotkey("~RButton", _OnMouseClickReset)
}

_OnMouseClickReset(*) {
    try {
        ; A click places the cursor at an unknown position, but the next
        ; keystroke will start a fresh run — treat it as a word boundary so
        ; is_word triggers (e.g. "c★ → c'est") fire immediately.
        HSE_FeedReset(true)
        _ResetPrefixBuffer()
    } catch as Err {
        LoggerError("PrefixWatcher", "Mouse-click reset failed: {1}.", Err.Message)
    }
}

; ─── Suggestion lifecycle helpers ────────────────────────────────────────
; Suggested / dismissed events are written from a single state machine so
; the JSONL never contains an unmatched dismissed event, nor two suggested
; events back-to-back for the same trigger. The state lives in
; ``_KLLastShownSuggestion``: "" when no tooltip is up, an object otherwise.
;
; ``_NotifySuggestionShown`` fires when a tooltip is rendered. If the same
; trigger is re-displayed (the user kept typing characters that all map to
; the same suggested expansion), we do NOT re-emit a suggested event — HS
; only logs once per visibility cycle. When a different trigger replaces
; the previous one, we emit a dismissed for the old one then a suggested
; for the new one.
;
; ``_NotifySuggestionDismissed`` fires when the tooltip hides for any
; reason other than a fire (buffer reset, prefix lost, word terminator,
; mouse click). The fire path uses the silent-clear variant below so the
; suggestion is not double-counted as both fired and dismissed.
_NotifySuggestionShown(Trigger, Output, Category) {
    global _KLLastShownSuggestion
    Prev := _KLLastShownSuggestion
    if (IsObject(Prev) and Prev.Trigger == Trigger and Prev.Output == Output) {
        return
    }
    if IsObject(Prev) {
        try KL_LogHotstringDismissed(Prev.Trigger, Prev.Output, Prev.Category)
    }
    _KLLastShownSuggestion := { Trigger: Trigger, Output: Output, Category: Category }
    try KL_LogHotstringSuggested(Trigger, Output, Category)
}

_NotifySuggestionDismissed() {
    global _KLLastShownSuggestion
    Prev := _KLLastShownSuggestion
    if !IsObject(Prev) {
        return
    }
    _KLLastShownSuggestion := ""
    try KL_LogHotstringDismissed(Prev.Trigger, Prev.Output, Prev.Category)
}

; Silent clear — used by the fire path so a single user action emits
; ``hotstring`` (fired) without a paired ``hotstring_dismissed``.
_NotifySuggestionConsumed() {
    global _KLLastShownSuggestion
    _KLLastShownSuggestion := ""
}

; Decide which ``h_type`` value to log for a fired hotstring. The richest
; source is the matching active suggestion: its TOML Category names the
; group ("autocorrection", "personal", "magickey"…) and is far more
; informative than HS's generic "unknown". When the fire happens without
; a preceding suggestion (single-char-after-magic-key triggers that fire
; below the prefix watcher's MIN_PREFIX_LEN, or fires that race the
; tooltip render), fall back to a basic star/endchar tag derived from
; ``Spec.Star`` so the field is never empty.
_ResolveFireHType(Spec) {
    global _KLLastShownSuggestion
    Prev := _KLLastShownSuggestion
    if (IsObject(Prev) and Prev.Trigger == Spec.Trigger) {
        return Prev.Category
    }
    return (Spec.HasOwnProp("Star") and Spec.Star) ? "star" : "endchar"
}

; Toggle the suppression flag. The hotstring engine wraps its SendEvent
; bursts in ``PrefixWatcherSuppress(true)`` / ``PrefixWatcherSuppress(false)``
; pairs (with a small SetTimer delay on the release) so the InputHook
; ignores AHK-generated characters. Releasing the flag also wipes the
; live buffer and hides any leftover tooltip — by the time we re-enable
; observation, the user is starting a fresh keystroke run.
PrefixWatcherSuppress(YesNo) {
    global _PrefixWatcherSuppressed, _PrefixBuffer
    _PrefixWatcherSuppressed := !!YesNo
    ; Mirror the suppression into HSE so its parallel buffer stays aligned
    ; with the prefix watcher during SendEvent bursts. HSE_Suppress only
    ; flips the flag — the HSE buffer is NOT wiped here; HSE_DispatchMatch
    ; already called HSE_ApplyExpansion before deferring this release,
    ; so the buffer already reflects the post-expansion screen state.
    HSE_Suppress(YesNo)
    if !YesNo {
        _PrefixBuffer := ""
        TooltipHide()
    }
}

; Stop the InputHook and clear the index. Useful when the user disables the
; preview from the tray menu or before reloading.
HotstringPrefixWatcherStop() {
    global _PrefixInputHook, _PrefixIndex, _PrefixBuffer
    if _PrefixInputHook {
        try _PrefixInputHook.Stop()
        _PrefixInputHook := 0
    }
    _PrefixIndex := Map()
    _PrefixBuffer := ""
    TooltipHide()
    ; Close out any tooltip that was on screen — the user disabling the
    ; watcher mid-suggestion is functionally a dismissal, not a fire.
    _NotifySuggestionDismissed()
}





; ============================================================
; ============================================================
; ======= 2/ Registry construction ==========================
; ============================================================
; ============================================================

; Resolve the on-disk path of a category's TOML file. Personal hotstrings
; honour the user-relocatable path stored in ScriptInformation; everything
; else lives next to the bundled hotstrings directory.
_PrefixWatcherTomlPath(Category) {
    global ScriptInformation, _StaticDir
    LowerCat := StrLower(Category)
    if (LowerCat == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        return ScriptInformation["PersonalTomlPath"]
    }
    return _StaticDir . "\ergopti_plus\shared\hotstrings\" . LowerCat . ".toml"
}

; Scan a category TOML and add every (trigger, output) pair to the prefix
; index. Returns the number of entries registered. Lightweight regex scan —
; we capture trigger, output and the case-sensitivity flags so we can
; pre-compute the exact same case variants the engine registers.
_RegisterCategoryTriggers(Category) {
    global ScriptInformation
    Path := _PrefixWatcherTomlPath(Category)
    if !FileExist(Path) {
        return 0
    }

    ; Capture: 1=trigger, 2=output, 3=is_case_sensitive,
    ; 4=is_case_sensitive_strict (optional, defaults to false when missing).
    EntryPattern :=
        'i)^"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*\{\s*output\s*=\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,\s*is_word\s*=\s*(?:true|false)\s*,\s*auto_expand\s*=\s*(?:true|false)\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(?:true|false)(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?\s*\}'

    CurrentSection := ""
    Count := 0
    FileContent := ReadTomlFile(Path)
    loop parse, FileContent, "`n", "`r" {
        Line := Trim(A_LoopField, " `t")
        if (Line == "" or SubStr(Line, 1, 1) == "#") {
            continue
        }
        if RegExMatch(Line, "^\[\[(.+)\]\]$", &SectionMatch) {
            CurrentSection := StrLower(SectionMatch[1])
            continue
        }
        if (SubStr(Line, 1, 1) == "[") {
            CurrentSection := ""
            continue
        }
        if (CurrentSection == "") {
            continue
        }
        if !RegExMatch(Line, EntryPattern, &Match) {
            continue
        }
        Trigger := UnescapeTomlString(Match[1])
        Output  := UnescapeTomlString(Match[2])
        ; Generator semantics: ``is_case_sensitive = not case_sensitive``.
        ; When false, the engine runs CreateCaseSensitiveHotstrings which
        ; registers all three case variants. When true, only the literal
        ; trigger is registered (case-sensitive but with the C0 option, so
        ; AHK still uppercases the result if the user types in uppercase).
        ; Strict means even the case-folded variants are not registered —
        ; the trigger only fires on the exact casing in the TOML.
        IsCaseSensitive := (Match[3] == "true")
        IsStrict := (Match.Count >= 4 and Match[4] == "true")
        ; Substitute ★ with the user's configured magic key so the prefix
        ; index reflects what the user actually types at runtime.
        if (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
            Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
            Output  := StrReplace(Output,  "★", ScriptInformation["MagicKey"])
        }
        _AddTriggerVariants(Trigger, Output, Category, CurrentSection, IsCaseSensitive, IsStrict)
        Count += 1
    }
    return Count
}

; Mirror what CreateCaseSensitiveHotstrings registers in the live engine: for
; non-strict, non-case-sensitive triggers it emits three variants (lowercase
; + titlecase + uppercase) each paired with its own pre-cased output. We
; index every variant so the runtime lookup never has to transform anything
; — what the user types either matches a variant exactly (exact preview) or
; matches none (no tooltip, in line with the engine not firing either).
;
; ── Single-character body special case ──
; When the trigger body is a single character (e.g. ``e★``, or a plain ``e``),
; ``StrTitle`` and ``StrUpper`` produce the SAME string (``E★`` / ``E``). The
; engine's ``CreateCaseSensitiveHotstrings`` handles this at lines 438-441 of
; hotstring_engine.ahk: it registers only Lower + Title and skips Upper.
; The prefix watcher has to mirror that — otherwise we would push two entries
; (title + upper) into the same prefix bucket with identical triggers but
; different replacements (``Est`` for title, ``EST`` for upper), and the
; tooltip would surface the upper variant as a dimmed strikethrough alternative
; that the engine could never actually fire.
;
; ⚠ The dedup MUST gate on body length (mirroring the engine's exact
; ``StrLen(RTrim(Abbreviation, MagicKey)) == 1`` check), NOT on
; ``UpperTrig != TitleTrig``. AHK v2's ``!=`` operator is case-INSENSITIVE,
; so comparing ``IA★`` against ``Ia★`` with ``!=`` returns false for every
; letter-only trigger of any length — which used to suppress the UPPER
; variant globally and leave typings like ``IA`` without a tooltip even
; though the engine still fires on the upper variant.
_AddTriggerVariants(Trigger, Output, Category, Section, IsCaseSensitive, IsStrict) {
    global ScriptInformation
    if IsStrict {
        ; Strict triggers only match the exact casing in the TOML — anything
        ; else neither fires nor previews.
        _AddTriggerToIndex(Trigger, Output, Category, Section)
        return
    }
    if IsCaseSensitive {
        ; Single registration via plain CreateHotstring (no auto-folding) —
        ; only the literal lowercase form is matched in practice.
        _AddTriggerToIndex(Trigger, Output, Category, Section)
        return
    }
    LowerTrig := StrLower(Trigger)
    TitleTrig := StrTitle(Trigger)
    UpperTrig := StrUpper(Trigger)
    _AddTriggerToIndex(LowerTrig, StrLower(Output), Category, Section)
    _AddTriggerToIndex(TitleTrig, StrTitle(Output), Category, Section)
    MagicSuffix := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey"))
        ? ScriptInformation["MagicKey"] : "★"
    BodyLen := StrLen(RTrim(Trigger, MagicSuffix))
    if (BodyLen != 1) {
        _AddTriggerToIndex(UpperTrig, StrUpper(Output), Category, Section)
    }
}

; Add at most ONE prefix entry per trigger so the tooltip only surfaces
; at a moment that genuinely reflects « what is about to be output ».
; Mirror of the Hammerspoon split (modules/keymap/llm_bridge.lua):
;
;   - Magic-key triggers (last char(s) == the user's magic key, e.g.
;     « c★ », « gt★ »): the user types the body then ★ to fire.
;     Index « trigger minus magic key » — the tooltip surfaces while
;     the body is on screen and pressing ★ completes the expansion.
;
;   - Every other trigger (autocorrects fired on word terminators,
;     full-word matches, …): index the FULL trigger. The tooltip
;     surfaces when the body is fully typed — pressing space / tab /
;     enter / punctuation completes the expansion. This is the
;     subtlety the magic-key path differs from: those tooltips
;     preview « one keystroke » away (the ★), end-char-gated ones
;     preview « one terminator » away.
;
; Triggers below _MIN_PREFIX_LEN-1 (magic) or _MIN_PREFIX_LEN
; (everything else) are not indexed at all — their previews would
; fire on a single-letter typed buffer, which is too noisy to be
; useful.
_AddTriggerToIndex(Trigger, Output, Category, Section) {
    global _PrefixIndex, _MIN_PREFIX_LEN, ScriptInformation

    MagicKey := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey"))
        ? ScriptInformation["MagicKey"] : "★"
    MkLen := StrLen(MagicKey)
    Len := StrLen(Trigger)
    HasMagic := (MkLen > 0 and Len > MkLen and SubStr(Trigger, -MkLen) == MagicKey)

    Entry := { Trigger:  Trigger,
               Output:   Output,
               Category: Category,
               Section:  Section,
               Length:   Len }

    KeyLen := HasMagic ? (Len - MkLen) : Len
    ; Magic-key triggers with a 1-char body (e.g. "c★") are allowed through
    ; with KeyLen = 1: the ★ itself is the final discriminant, so a single
    ; body character is enough signal to show a useful tooltip. Non-magic
    ; triggers still require _MIN_PREFIX_LEN to avoid per-keystroke noise.
    MinLen := HasMagic ? 1 : _MIN_PREFIX_LEN
    if (KeyLen < MinLen) {
        return
    }
    Prefix := SubStr(Trigger, 1, KeyLen)
    if !_PrefixIndex.Has(Prefix) {
        _PrefixIndex[Prefix] := []
    }
    _PrefixIndex[Prefix].Push(Entry)
    ; Register exact trigger in the flat set for near-miss lookups
    _TriggerSet[StrLower(Trigger)] := Entry
}





; ============================================================
; ============================================================
; ======= 3/ InputHook & buffer logic =======================
; ============================================================
; ============================================================

; Configure and start the pass-through InputHook. Visible mode (``V``) means
; every keystroke also reaches its normal destination — the watcher only
; observes. ``L0 I0`` disables length-based termination; the hook stays alive
; until HotstringPrefixWatcherStop is called.
_StartInputHook() {
    global _PrefixInputHook
    Hook := InputHook("V L0 I0")
    Hook.KeyOpt("{All}", "+N")            ; notify OnKeyDown for every key
    Hook.OnChar    := _OnPrefixChar
    Hook.OnKeyDown := _OnPrefixKeyDown
    Hook.Start()
    _PrefixInputHook := Hook
}

; OnChar — called for every printable character produced by the active
; keyboard layout. We keep this fast: append, trim, lookup, render. Anything
; heavy belongs out of the hot path.
; Wrapped in try so that any exception from _LookupAndRender / TooltipShow
; does not silently kill the InputHook callback chain — AHK v2 stops invoking
; the OnChar callback permanently if an unhandled error propagates out of it.
_OnPrefixChar(IH, Char) {
    global _PrefixBuffer, _MAX_BUFFER_LEN, _PrefixWatcherSuppressed, HSE_Suppressed
    ; Honour BOTH suppression flags. _PrefixWatcherSuppressed is set by
    ; PrefixWatcherSuppress (manual / tray toggles); HSE_Suppressed is
    ; set by HSE_DispatchMatch while it is replaying its SendEvent burst.
    ; Missing the HSE flag here lets AHK's own output refill _PrefixBuffer
    ; and resurface a ghost tooltip on a prefix match against the
    ; expansion we just emitted.
    if (_PrefixWatcherSuppressed or HSE_Suppressed) {
        return
    }
    try {
        LoggerDebug("PrefixWatcher", "DBG OnChar: char='{1}' buf='{2}' suppressed={3}/{4}.", Char, _PrefixBuffer, _PrefixWatcherSuppressed, HSE_Suppressed)
        ; Feed HSE — when HSE_FeedChar reports a match, fire the
        ; expansion right here. HSE_LastEndChar is the authoritative end
        ; character: empty for star (immediate) triggers, the just-typed
        ; terminator for end-char-gated triggers. We can no longer derive
        ; it from « is Char a terminator? » alone because the new HSE
        ; keeps terminators in its buffer, which means a terminator may
        ; trigger a STAR match (e.g. a personal ``,a → ja`` rule fires
        ; on the « a », not on the comma).
        HSEMatch := HSE_FeedChar(Char)
        ; When no registered hotstring matched, try the engine-level repeat
        ; fallback: <x><MagicKey> repeats <x> when x is at least the 2nd
        ; letter of the current word. This replaces the now-removed [[repeat]]
        ; TOML entries and fires at the lowest priority (only on no-match).
        if (HSEMatch == "" and IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
            HSEMatch := HSE_TryRepeatKey(ScriptInformation["MagicKey"])
        }
        if (HSEMatch != "") {
            HSE_DispatchMatch(HSEMatch, HSE_LastEndChar)
            ; Log the fired hotstring. ``h_type`` is taken from the
            ; preceding suggestion when available (richest categorisation —
            ; "autocorrection", "personal", …) and falls back to a basic
            ; star/endchar tag so dispatch paths that bypass the tooltip
            ; (single-char-after-magic-key triggers that fire below
            ; _MIN_PREFIX_LEN) still carry meaningful metadata.
            HotstringHType := _ResolveFireHType(HSEMatch)
            HotstringRepl := HSEMatch.HasOwnProp("Replacement") ? HSEMatch.Replacement : HSEMatch.Trigger
            ; IsRepeat matches have no Category property — pass "repeat_key" explicitly
            ; so the WPM widget knows to stay at the default color.
            HotstringCategory := HSEMatch.HasOwnProp("IsRepeat") && HSEMatch.IsRepeat
                ? "repeat_key"
                : (HSEMatch.HasOwnProp("Category") ? HSEMatch.Category : "")
            HotstringSection := HSEMatch.HasOwnProp("Section") ? HSEMatch.Section : ""
            try KL_LogHotstring(HSEMatch.Trigger, HotstringRepl, HotstringHType, "", HotstringCategory, HotstringSection)
            ; ── Sync the watcher buffer to the post-expansion screen state ──
            ; The naive "wipe to empty" used to drop the in-word context the
            ; user is still typing inside of. After a STAR fire (no end-char),
            ; the cursor sits IMMEDIATELY after the replacement and the user
            ; usually keeps typing the same word — so the next keystroke
            ; needs the post-expansion prefix as its lookup context. Without
            ; this sync, typing ``l`` then the apostrophe trigger (``l’``)
            ; would erase the watcher's memory of the ``l’`` boundary, and
            ; subsequent ``ia`` would never surface the ``ia`` trigger
            ; preview because the word-anchored lookup had no terminator to
            ; anchor against.
            ;
            ; End-char fires are the original "word is done" case: the user
            ; pressed a terminator, the trigger fired, the cursor is now at
            ; a fresh word boundary. The old wipe behaviour is correct there.
            if (HSE_LastEndChar == "") {
                StripLen := (HSEMatch.HasOwnProp("Length") ? HSEMatch.Length : 0) - 1
                if (StripLen > 0 and StrLen(_PrefixBuffer) >= StripLen) {
                    _PrefixBuffer := SubStr(_PrefixBuffer, 1, StrLen(_PrefixBuffer) - StripLen)
                } else if (StripLen > 0) {
                    _PrefixBuffer := ""
                }
                if HSEMatch.HasOwnProp("Replacement") and Type(HSEMatch.Replacement) == "String" {
                    _PrefixBuffer .= HSEMatch.Replacement
                }
                if (StrLen(_PrefixBuffer) > _MAX_BUFFER_LEN) {
                    _PrefixBuffer := SubStr(_PrefixBuffer, -_MAX_BUFFER_LEN)
                }
                ; The roll/cascade injected new text into the buffer — check
                ; if it prefixes a registered trigger and show the tooltip
                ; immediately. This handles « p'★ → c'était »: the roll fires
                ; p' → ct, the buffer becomes "ct", and the tooltip for ct★
                ; should appear right away so the user knows to press ★.
                ; Without this call, TooltipHide() would clear the display and
                ; the next keystroke (★) would look up "ct★" instead of "ct".
                _LookupAndRender()
                _NotifySuggestionConsumed()
            } else {
                _ResetPrefixBuffer(true)
            }
            return
        }

        ; Space and other non-word characters reset the buffer — the trigger
        ; index only contains word-internal sequences, and a leading space
        ; would prevent any match from being found. OnKeyDown handles the VK
        ; path for keys that produce no character (arrows, Escape…); this
        ; guard covers keys that do produce a character (Space via tap-hold
        ; or AltGr layers) but whose VK event may be swallowed by AHK before
        ; reaching the InputHook.
        if (Char == " " or Char == "`t") {
            _ResetPrefixBuffer()
            return
        }
        _PrefixBuffer .= Char
        if (StrLen(_PrefixBuffer) > _MAX_BUFFER_LEN) {
            _PrefixBuffer := SubStr(_PrefixBuffer, -_MAX_BUFFER_LEN)
        }
        LoggerDebug("PrefixWatcher", "DBG about to _LookupAndRender: buf='{1}' indexSize={2}.", _PrefixBuffer, _PrefixIndex.Count)
        _LookupAndRender()
    } catch as Err {
        LoggerError("PrefixWatcher", "OnChar error for char '{1}': {2}.", Char, Err.Message)
    }
}

; OnKeyDown — handles word-breaking / navigation keys that should reset the
; buffer regardless of whether they produce a visible character. The VK list
; covers Space/Enter/Tab/Escape/Backspace and the four arrows. Mouse clicks
; are not handled here; the InputHook does not see them. We rely on the
; tooltip's auto-hide timer for that case.
_OnPrefixKeyDown(IH, VK, SC) {
    global _PrefixWatcherSuppressed, HSE_Suppressed
    ; Same dual-flag guard as _OnPrefixChar — the BackSpace events the
    ; dispatcher fires via SendEvent reach this callback as VK 0x08 events.
    ; Without the HSE_Suppressed check the watcher would call
    ; _ResetPrefixBuffer() once per replayed BackSpace, which is harmless
    ; on its own but pairs with the OnChar pollution to produce ghosts.
    if (_PrefixWatcherSuppressed or HSE_Suppressed) {
        return
    }
    static ResetVKs := Map(
        0x08, true,  ; VK_BACK
        0x09, true,  ; VK_TAB
        0x0D, true,  ; VK_RETURN
        0x1B, true,  ; VK_ESCAPE
        0x20, true,  ; VK_SPACE
        0x25, true,  ; VK_LEFT
        0x26, true,  ; VK_UP
        0x27, true,  ; VK_RIGHT
        0x28, true,  ; VK_DOWN
    )
    ; Same try guard as _OnPrefixChar — an unhandled error here permanently
    ; silences the OnKeyDown callback for all subsequent keystrokes.
    try {
        ; Detect Ctrl-modified combos that mutate the document context but
        ; do not produce a printable char observable by OnChar. Held Ctrl
        ; is read off the live keyboard state since the InputHook does
        ; not surface modifier flags. Done before the plain-VK branches
        ; so Ctrl+A/X/V/Z/Y do not also fall through to (e.g.) the « no
        ; printable » case.
        CtrlHeld := GetKeyState("Control", "P")
        if CtrlHeld {
            if (VK == 0x41) {
                ; Ctrl+A — select-all. The next typed char replaces the
                ; entire selection, landing at a fresh word-start.
                HSE_FeedReset(true)
                _ResetPrefixBuffer()
                return
            }
            if (VK == 0x58 or VK == 0x56 or VK == 0x5A or VK == 0x59) {
                ; Ctrl+X (cut) / Ctrl+V (paste) / Ctrl+Z (undo) /
                ; Ctrl+Y (redo) — document content rewritten by an
                ; unknown amount, cursor lands somewhere we cannot
                ; observe. Wipe the buffer and refuse to assume a
                ; word boundary on its left.
                HSE_FeedReset(false)
                _ResetPrefixBuffer()
                return
            }
        }

        ; Feed HSE with the appropriate buffer mutation. Backspace
        ; decrements its buffer (preserving word context, the whole point
        ; of the rewrite); Tab/Enter/arrows/Escape/mouse-click all declare
        ; a word boundary — the cursor lands somewhere unknown but the next
        ; typed run always starts fresh. Space is already handled by
        ; HSE_FeedChar via OnChar's terminator path, but we also reset here
        ; so a Space whose char event was swallowed (e.g. layered on
        ; tap-hold) still flips the boundary flag.
        if (VK == 0x08) {
            HSE_FeedBackspace()
        } else if (VK == 0x09 or VK == 0x0D) {
            HSE_FeedReset(true)
        } else if (VK == 0x1B
                or VK == 0x25 or VK == 0x26
                or VK == 0x27 or VK == 0x28) {
            ; Arrow keys and Escape move the cursor to an unknown position,
            ; but the next typed run starts fresh — treat as word boundary.
            HSE_FeedReset(true)
        }
        if ResetVKs.Has(VK) {
            _ResetPrefixBuffer()
        }
    } catch as Err {
        LoggerError("PrefixWatcher", "OnKeyDown error for VK {1}: {2}.", VK, Err.Message)
    }
}

; ConsumedByFire ─ true when the reset is the consequence of a hotstring
; firing. The currently-suggested entry is then cleared silently so the
; logger does not emit a ``hotstring_dismissed`` event paired with the
; ``hotstring`` (fired) one — HS treats the fire as the resolution of the
; suggestion, never a parallel dismissal. Every other caller (word
; terminator, mouse click, navigation key, prefix lost) leaves the default
; in place so the tooltip's disappearance is properly logged.
_ResetPrefixBuffer(ConsumedByFire := false) {
    global _PrefixBuffer, _TriggerSet
    Buf := _PrefixBuffer
    _PrefixBuffer := ""
    TooltipHide()
    if ConsumedByFire {
        _NotifySuggestionConsumed()
    } else {
        _NotifySuggestionDismissed()
        ; Near-miss and manual-trigger detection on non-fire resets.
        ; Only worth checking when the buffer has meaningful length.
        if (StrLen(Buf) >= 2)
            try _CheckNearMiss(Buf)
    }
}

; Checks whether the typed buffer (at word boundary) is a known trigger
; typed manually (manual_typed_known_trigger) or within edit distance 1
; of a known trigger (hotstring_near_miss).
_CheckNearMiss(Buf) {
    global _TriggerSet
    key := StrLower(Buf)
    ; Exact match → user typed a known trigger without using the expansion
    if _TriggerSet.Has(key) {
        Entry := _TriggerSet[key]
        try KL_LogHotstringNearMiss("manual_typed_known_trigger",
            Entry.Trigger, Entry.Output, Entry.Category)
        return
    }
    ; Edit-distance-1 check — scan triggers of same length ± 1
    BufLen := StrLen(Buf)
    for trig, Entry in _TriggerSet {
        tLen := StrLen(trig)
        if (Abs(tLen - BufLen) > 1)
            continue
        if (_EditDistance1(key, trig)) {
            try KL_LogHotstringNearMiss("hotstring_near_miss",
                Entry.Trigger, Entry.Output, Entry.Category)
            ; Only report the first near-miss per reset to avoid spam
            return
        }
    }
}

; Returns true when the Levenshtein distance between a and b is exactly 1.
; Only evaluates strings whose lengths differ by at most 1 (pre-filtered).
_EditDistance1(a, b) {
    la := StrLen(a)
    lb := StrLen(b)
    if (la = lb) {
        ; Same length — must be exactly one substitution
        diffs := 0
        loop la {
            if (SubStr(a, A_Index, 1) != SubStr(b, A_Index, 1))
                diffs += 1
            if (diffs > 1)
                return false
        }
        return diffs = 1
    }
    ; Length differs by 1 — one insertion or deletion
    longer  := (la > lb) ? a : b
    shorter := (la > lb) ? b : a
    llong   := (la > lb) ? la : lb
    lshort  := (la > lb) ? lb : la
    i := 1
    j := 1
    skipped := false
    while (i <= llong and j <= lshort) {
        if (SubStr(longer, i, 1) != SubStr(shorter, j, 1)) {
            if skipped
                return false
            skipped := true
            i += 1
        } else {
            i += 1
            j += 1
        }
    }
    return true
}

KL_LogHotstringNearMiss(kind, trigger, replacement, h_type) {
    if !Keylogger.initialized
        return
    KL_AppendLog(Map(
        "type",        kind,
        "app",         Keylogger.session_app,
        "trigger",     trigger,
        "replacement", replacement,
        "h_type",      h_type
    ))
}

; Look up the current buffer in the prefix index and update the tooltip.
;
; ── Word-anchored lookup ──
; The buffer holds every keystroke since the last reset (word-breaker, mouse
; click, arrow key…), so for a mid-word context like ``l'ia`` the literal
; buffer is "l'ia" but the trigger the user is reaching for is the substring
; AFTER the last word-boundary char — here ``ia``. Looking up the full buffer
; means we miss every trigger whose context includes an in-word terminator
; (apostrophes for French contractions, punctuation, …) even though the
; HSE engine itself fires those triggers correctly via suffix matching.
;
; We slide a cursor across HSE_WORD_TERMINATORS to find the rightmost
; terminator in the buffer; everything to its right is the effective "word
; under typing", and that is what we look up. When no terminator is present
; we fall back to the full buffer.
_LookupAndRender() {
    global _PrefixBuffer, _PrefixIndex, _MIN_PREFIX_LEN, HSE_WORD_TERMINATORS, ScriptInformation
    Buffer := _PrefixBuffer
    Len := StrLen(Buffer)
    LoggerDebug("PrefixWatcher", "DBG _LookupAndRender: buf='{1}' len={2} indexSize={3}.", Buffer, Len, _PrefixIndex.Count)
    ; Short buffers are only skipped when they have no entry in the index.
    ; A 1-char buffer may validly match a magic-key trigger body (e.g. "c"
    ; is the body of "c★"), so we let the lookup below decide — the early
    ; exit here only avoids the Map lookup for guaranteed-empty cases.
    if (Len < 1) {
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }

    ; Walk the buffer from the right edge backwards; the first character we
    ; meet that appears in ``HSE_WORD_TERMINATORS`` marks the boundary of
    ; the leading context, and everything to its right is the current word
    ; under typing. The straightforward ``InStr(..., , 1, -1)`` form does
    ; NOT do this: with a positive StartingPos and a negative Occurrence,
    ; AHK v2 essentially returns the first match from the left, not the
    ; last from the right — verified by direct probe, which is why ``a'ia``
    ; used to return ``a'ia`` (no terminator found) instead of ``ia``.
    LastTermPos := 0
    BufScanIdx := StrLen(Buffer)
    while (BufScanIdx >= 1) {
        ScanChar := SubStr(Buffer, BufScanIdx, 1)
        if (InStr(HSE_WORD_TERMINATORS, ScanChar) > 0) {
            LastTermPos := BufScanIdx
            break
        }
        BufScanIdx -= 1
    }
    SearchKey := (LastTermPos > 0) ? SubStr(Buffer, LastTermPos + 1) : Buffer
    if (SearchKey == "") {
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }
    ; AHK v2's Map is case-sensitive by default, so this lookup distinguishes
    ; ``ct`` from ``CT`` — the index registers each case variant separately
    ; with its pre-cased output, exactly mirroring CreateCaseSensitiveHotstrings.
    if !_PrefixIndex.Has(SearchKey) {
        LoggerDebug("PrefixWatcher", "DBG no prefix match for '{1}'.", SearchKey)
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }
    LoggerDebug("PrefixWatcher", "DBG prefix MATCH for '{1}' ({2} candidates).", SearchKey, _PrefixIndex[SearchKey].Length)
    Buffer := SearchKey

    ; Collect candidates per group and lay them out as the user requested:
    ; end-char (↵) triggers FIRST (top), then magic-key (★) triggers below.
    ; End-char triggers usually have a shorter delay (the user types
    ; space/tab/enter quickly) so they need maximum visibility on top.
    ; Within each group, the FIRST surviving candidate is the one the engine
    ; will actually fire — it is rendered normally. Every subsequent candidate
    ; of the same group is rendered dimmed + strikethrough (IsDimmed flag,
    ; consumed by tooltip.ahk's _TooltipBuildGui).
    Candidates := _PrefixIndex[Buffer]
    MK := ScriptInformation["MagicKey"]
    EndItems := []
    StarItems := []
    for _, Entry in Candidates {
        Cfg := HotstringsResolve(Entry.Category, Entry.Section)
        if !Cfg.ShowTooltip {
            continue
        }
        Color := (Cfg.Color != "") ? Cfg.Color : ""
        Delay := (Cfg.Delay != "") ? Cfg.Delay : 0
        IsMagic := InStr(Entry.Trigger, MK) > 0
        ; Trigger label shown on the right side of the row:
        ;   ★ (or the configured magic key) for star triggers,
        ;   ↵  for end-char-gated triggers (space / punctuation / enter).
        TriggerLabel := IsMagic ? MK : "↵"
        Bucket := IsMagic ? StarItems : EndItems
        Item := { Text: Entry.Output, TriggerLabel: TriggerLabel,
                  ColorHex: Color, DurationSec: Delay,
                  Trigger: Entry.Trigger, Category: Entry.Category,
                  IsDimmed: Bucket.Length > 0 }
        Bucket.Push(Item)
    }
    Items := []
    for _, Item in EndItems {
        Items.Push(Item)
    }
    for _, Item in StarItems {
        Items.Push(Item)
    }
    if (Items.Length == 0) {
        LoggerDebug("PrefixWatcher", "DBG all candidates have ShowTooltip=false, hiding.")
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }
    LoggerDebug("PrefixWatcher", "DBG calling TooltipShow: {1} item(s), first='{2}'.", Items.Length, Items[1].Text)
    TooltipShow(Items)
    ; Log the suggestion based on the first (top) item only.
    Primary := Items[1]
    _NotifySuggestionShown(Primary.Trigger, Primary.Text, Primary.Category)
}
