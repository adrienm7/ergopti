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

; Live keystroke buffer (lowercased). Trimmed to MAX_BUFFER_LEN whenever it
; would overflow so memory and lookup cost stay bounded.
global _PrefixBuffer := ""

; Reference to the running InputHook (kept global so the GC does not collect
; it and so that the watcher can be reset / stopped at shutdown).
global _PrefixInputHook := 0

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
        try LoggerWarn("PrefixWatcher", "Init called twice — ignoring duplicate.")
        return
    }
    try LoggerStart("PrefixWatcher", "Initializing prefix watcher…")

    EntryCount := 0
    for _, Category in _PREFIX_WATCHER_CATEGORIES {
        EntryCount += _RegisterCategoryTriggers(Category)
    }

    _StartInputHook()
    try LoggerSuccess("PrefixWatcher", "Watcher started ({1} trigger(s) indexed).", EntryCount)
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
; we do not need the full feature flags here, just trigger and output, so we
; deliberately avoid coupling to LoadHotstringsSection.
_RegisterCategoryTriggers(Category) {
    global ScriptInformation
    Path := _PrefixWatcherTomlPath(Category)
    if !FileExist(Path) {
        return 0
    }

    EntryPattern :=
        'i)^"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*\{\s*output\s*=\s*"([^"\\]*(?:\\.[^"\\]*)*)"'

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
        ; Substitute ★ with the user's configured magic key so the prefix
        ; index reflects what the user actually types at runtime.
        if (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
            Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
            Output  := StrReplace(Output,  "★", ScriptInformation["MagicKey"])
        }
        _AddTriggerToIndex(Trigger, Output, Category, CurrentSection)
        Count += 1
    }
    return Count
}

; Add every prefix of Trigger (of length >= _MIN_PREFIX_LEN) to _PrefixIndex.
; Multiple triggers can share a prefix; entries are appended in registration
; order so the lookup returns the first registered match, mirroring how
; CreateHotstring conflicts are resolved (first registered wins).
_AddTriggerToIndex(Trigger, Output, Category, Section) {
    global _PrefixIndex, _MIN_PREFIX_LEN
    Entry := { Trigger:  Trigger,
               Output:   Output,
               Category: Category,
               Section:  Section,
               Length:   StrLen(Trigger) }

    Lower := StrLower(Trigger)
    Len := StrLen(Lower)
    i := _MIN_PREFIX_LEN
    while (i <= Len) {
        Prefix := SubStr(Lower, 1, i)
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
_OnPrefixChar(IH, Char) {
    global _PrefixBuffer, _MAX_BUFFER_LEN
    _PrefixBuffer .= StrLower(Char)
    if (StrLen(_PrefixBuffer) > _MAX_BUFFER_LEN) {
        _PrefixBuffer := SubStr(_PrefixBuffer, -_MAX_BUFFER_LEN)
    }
    _LookupAndRender()
}

; OnKeyDown — handles word-breaking / navigation keys that should reset the
; buffer regardless of whether they produce a visible character. The VK list
; covers Space/Enter/Tab/Escape/Backspace and the four arrows. Mouse clicks
; are not handled here; the InputHook does not see them. We rely on the
; tooltip's auto-hide timer for that case.
_OnPrefixKeyDown(IH, VK, SC) {
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
    if ResetVKs.Has(VK) {
        _ResetPrefixBuffer()
    }
}

_ResetPrefixBuffer() {
    global _PrefixBuffer
    _PrefixBuffer := ""
    TooltipHide()
}

; Look up the current buffer in the prefix index and update the tooltip.
; Strategy: try the longest possible suffix of the buffer first, then shrink
; until either a match is found or the buffer falls below MIN_PREFIX_LEN.
; The shrink lets us recover when the buffer carries leading "noise" from
; an earlier word that no longer matches anything in the registry.
_LookupAndRender() {
    global _PrefixBuffer, _PrefixIndex, _MIN_PREFIX_LEN
    Buffer := _PrefixBuffer
    Len := StrLen(Buffer)
    if (Len < _MIN_PREFIX_LEN) {
        TooltipHide()
        return
    }

    Match := _BestMatchForBuffer(Buffer, Len)
    if (Match == "") {
        TooltipHide()
        return
    }

    Cfg := HotstringsResolve(Match.Category, Match.Section)
    Color := (Cfg.Color != "") ? Cfg.Color : ""
    Delay := (Cfg.Delay != "") ? Cfg.Delay : 0
    TooltipShow(Match.Output, Color, Delay)
}

; Returns the best matching entry for a buffer, or "" if none is found.
; Preference: shortest trigger that still has the buffer as its prefix —
; that minimises remaining keystrokes the user has to type, which feels
; more like a "you're almost there" preview.
_BestMatchForBuffer(Buffer, Len) {
    global _PrefixIndex, _MIN_PREFIX_LEN
    StartLen := Len
    while (StartLen >= _MIN_PREFIX_LEN) {
        Suffix := SubStr(Buffer, -StartLen)
        if _PrefixIndex.Has(Suffix) {
            Candidates := _PrefixIndex[Suffix]
            Best := Candidates[1]
            for _, Entry in Candidates {
                if (Entry.Length < Best.Length) {
                    Best := Entry
                }
            }
            return Best
        }
        StartLen -= 1
    }
    return ""
}
