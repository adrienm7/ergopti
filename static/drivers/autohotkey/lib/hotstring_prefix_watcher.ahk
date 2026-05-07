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
    LoggerSuccess("PrefixWatcher", "Watcher started ({1} trigger(s) indexed).", EntryCount)
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
    return A_ScriptDir . "\..\hotstrings\" . LowerCat . ".toml"
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

; Add every prefix of Trigger (of length >= _MIN_PREFIX_LEN) to _PrefixIndex.
; The prefix key preserves the original casing of the variant; the runtime
; lookup uses the raw user buffer so an exact match is required for the
; tooltip to surface — which is what we want for a faithful preview.
_AddTriggerToIndex(Trigger, Output, Category, Section) {
    global _PrefixIndex, _MIN_PREFIX_LEN
    Entry := { Trigger:  Trigger,
               Output:   Output,
               Category: Category,
               Section:  Section,
               Length:   StrLen(Trigger) }

    Len := StrLen(Trigger)
    i := _MIN_PREFIX_LEN
    while (i <= Len) {
        Prefix := SubStr(Trigger, 1, i)
        if !_PrefixIndex.Has(Prefix) {
            _PrefixIndex[Prefix] := []
        }
        _PrefixIndex[Prefix].Push(Entry)
        i += 1
    }
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
        if ResetVKs.Has(VK) {
            _ResetPrefixBuffer()
        }
    } catch as Err {
        LoggerError("PrefixWatcher", "OnKeyDown error for VK {1}: {2}.", VK, Err.Message)
    }
}

_ResetPrefixBuffer() {
    global _PrefixBuffer
    _PrefixBuffer := ""
    TooltipHide()
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
    if (Len < _MIN_PREFIX_LEN) {
        TooltipHide()
        return
    }
    ; AHK v2's Map is case-sensitive by default, so this lookup distinguishes
    ; ``ct`` from ``CT`` — the index registers each case variant separately
    ; with its pre-cased output, exactly mirroring CreateCaseSensitiveHotstrings.
    if !_PrefixIndex.Has(Buffer) {
        TooltipHide()
        return
    }

    Match := _BestCandidate(_PrefixIndex[Buffer])
    if (Match == "") {
        TooltipHide()
        return
    }

    Cfg := HotstringsResolve(Match.Category, Match.Section)
    Color := (Cfg.Color != "") ? Cfg.Color : ""
    Delay := (Cfg.Delay != "") ? Cfg.Delay : 0
    TooltipShow(Match.Output, Color, Delay)
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
