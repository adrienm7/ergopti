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
        EntryCount += _RegisterCategoryTriggers(Category)
    }

    _StartInputHook()
    _InstallMouseClickResetHooks()
    LoggerSuccess("PrefixWatcher", "Watcher started ({1} trigger(s) indexed).", EntryCount)
}

; Mouse clicks move the cursor to a position we cannot observe — the
; InputHook never sees them. Register pass-through hotkeys on the three
; primary buttons so HSEv2 can wipe its buffer and refuse to assume a
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
    ; Mirror the suppression into HSEv2 so its parallel buffer stays aligned
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
    global ScriptInformation
    LowerCat := StrLower(Category)
    if (LowerCat == "personal"
            and IsSet(ScriptInformation)
            and ScriptInformation.Has("PersonalTomlPath")) {
        return ScriptInformation["PersonalTomlPath"]
    }
    return A_ScriptDir . "\..\..\hotstrings\" . LowerCat . ".toml"
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
_AddTriggerVariants(Trigger, Output, Category, Section, IsCaseSensitive, IsStrict) {
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
    ; Three case variants — exact mirror of CreateCaseSensitiveHotstrings.
    _AddTriggerToIndex(StrLower(Trigger), StrLower(Output), Category, Section)
    _AddTriggerToIndex(StrTitle(Trigger), StrTitle(Output), Category, Section)
    _AddTriggerToIndex(StrUpper(Trigger), StrUpper(Output), Category, Section)
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
    global _PrefixBuffer, _MAX_BUFFER_LEN, _PrefixWatcherSuppressed
    if _PrefixWatcherSuppressed {
        return
    }
    try {
        ; Feed HSEv2 — when HSE_FeedChar reports a match, fire the
        ; expansion right here. HSE_LastEndChar is the authoritative end
        ; character: empty for star (immediate) triggers, the just-typed
        ; terminator for end-char-gated triggers. We can no longer derive
        ; it from « is Char a terminator? » alone because the new HSEv2
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
            try KL_LogHotstring(HSEMatch.Trigger, HotstringRepl, HotstringHType)
            ; Wipe the prefix watcher's own buffer so the post-expansion
            ; tail (which the user just observed on screen) does not
            ; surface a stale tooltip preview from the trigger we just
            ; fired. Pass ``true`` so the active suggestion is consumed
            ; silently — the fire is the answer to the suggestion, no
            ; ``dismissed`` event should pair with the ``suggested``.
            _ResetPrefixBuffer(true)
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
    global _PrefixWatcherSuppressed
    if _PrefixWatcherSuppressed {
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

        ; Feed HSEv2 with the appropriate buffer mutation. Backspace
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
; The buffer must match a trigger prefix exactly — the previous suffix-shrink
; recovery loop turned out to be unsafe: typing ``bon`` would shrink to
; ``on`` and surface the ``onu``→``ONU`` trigger from autocorrection. The
; buffer is already reset on every word-breaker (Space / Enter / Tab / arrow
; keys / Backspace), so leading noise is not a real concern.
_LookupAndRender() {
    global _PrefixBuffer, _PrefixIndex, _MIN_PREFIX_LEN
    Buffer := _PrefixBuffer
    Len := StrLen(Buffer)
    ; Short buffers are only skipped when they have no entry in the index.
    ; A 1-char buffer may validly match a magic-key trigger body (e.g. "c"
    ; is the body of "c★"), so we let the lookup below decide — the early
    ; exit here only avoids the Map lookup for guaranteed-empty cases.
    if (Len < 1) {
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }
    ; AHK v2's Map is case-sensitive by default, so this lookup distinguishes
    ; ``ct`` from ``CT`` — the index registers each case variant separately
    ; with its pre-cased output, exactly mirroring CreateCaseSensitiveHotstrings.
    if !_PrefixIndex.Has(Buffer) {
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }

    Match := _BestCandidate(_PrefixIndex[Buffer])
    if (Match == "") {
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }

    Cfg := HotstringsResolve(Match.Category, Match.Section)
    if !Cfg.ShowTooltip {
        TooltipHide()
        _NotifySuggestionDismissed()
        return
    }
    Color := (Cfg.Color != "") ? Cfg.Color : ""
    Delay := (Cfg.Delay != "") ? Cfg.Delay : 0
    TooltipShow(Match.Output, Color, Delay)
    ; Log the suggestion only when the displayed trigger actually changed
    ; (typing the next char of the same trigger keeps the same tooltip up
    ; on screen but we already logged that suggestion). The category is
    ; mirrored as ``h_type`` — this is richer than the macOS side which
    ; defaults to "unknown" for tooltip events without a TOML category.
    _NotifySuggestionShown(Match.Trigger, Match.Output, Match.Category)
}

; Pick the shortest trigger from a candidate list. Prefering the shortest
; trigger feels more like a "you're almost there" preview because it
; minimises the remaining keystrokes before the expansion fires.
_BestCandidate(Candidates) {
    if !IsObject(Candidates) or Candidates.Length == 0 {
        return ""
    }
    Best := Candidates[1]
    for _, Entry in Candidates {
        if (Entry.Length < Best.Length) {
            Best := Entry
        }
    }
    return Best
}
