; static/ergopti_plus/windows/lib/hotstrings/hotstring_engine_main.ahk

; ==============================================================================
; MODULE: Hotstring Engine
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
; ============================
; ======= 1/ Constants =======
; ============================
; ============================================

; Maximum buffer length. Anything older than the longest registered trigger
; is irrelevant for matching; we cap so memory and lookup cost stay bounded.
; 64 chars matches the prefix watcher's HSE_MAX_BUFFER_LEN equivalent.
global HSE_MAX_BUFFER_LEN := 64

; Word terminators: characters whose typing ends the current word and
; resets the buffer. The newline characters cover SendInput-injected
; replacements that terminate with `r`n (rare but possible).
; Apostrophes (both ASCII U+0027 and typographic U+2019) are included so
; that French contractions like "l'ia" let the "ia" trigger fire on the
; next terminator — the engine must treat the char after an apostrophe
; as the start of a new word, exactly like after a space.
; Both apostrophes are spelled with Chr() rather than literals: a typography
; pass once silently rewrote the ASCII apostrophe to a second U+2019, dropping
; U+0027 from the set — Chr() makes the codepoints explicit and tamper-proof.
global HSE_WORD_TERMINATORS := " `t`r`n.,;:?!" . Chr(0x27) . Chr(0x2019)
; Set to true during live registry rebuilds (RebuildHotstringsLive) to prevent
; the OnChar reader from accessing a cleared or partially repopulated index.
; Prevents Map-access crashes and incorrect partial matching (hse-registry-torn-read-vs-onmessage).
global HSE_RebuildInProgress := false

; Subset of HSE_WORD_TERMINATORS whose chars are consumed (not re-injected) after
; an expansion fires. Empty by default — the user opts specific custom delimiters
; into consume mode via the word-delimiter menu. Only characters also present in
; HSE_WORD_TERMINATORS have any effect here.
global HSE_CONSUMED_DELIMITERS := ""

; Default collision priority by hotstring SOURCE (see Spec.Priority). Higher wins
; an equal-length tie. The cascade is individual > section > file > these source
; defaults, so a user can always override. Bundled "common" hotstrings sit
; lowest, third-party "package" (extension TOML) in the middle, and the user's
; own "personal" hotstrings highest — so personal beats a package beats a common
; trigger of the same length without any manual tuning.
; SINGLE SOURCE OF TRUTH: shared/hotstrings/priority.json. These literals are
; held identical to it (and to the macOS PRIORITY_* in registry.lua) by the gate
; tools/test/test-priority-parity.cjs — change the JSON and all three together.
global HSE_PRIORITY_COMMON   := 10
global HSE_PRIORITY_PACKAGE  := 30
global HSE_PRIORITY_PERSONAL := 50

; Source-default priority for a category — the final fallback in the cascade when
; no override is set at the individual, section or file level. Personal beats
; "ext." packages, which beat bundled common categories.
_HSE_SourcePriority(CategoryName) {
    global HSE_PRIORITY_COMMON, HSE_PRIORITY_PACKAGE, HSE_PRIORITY_PERSONAL
    Cat := StrLower(CategoryName)
    if (Cat == "personal")
        return HSE_PRIORITY_PERSONAL
    if (SubStr(Cat, 1, 4) == "ext.")
        return HSE_PRIORITY_PACKAGE
    return HSE_PRIORITY_COMMON
}





; ============================================
; ========================
; ======= 2/ State =======
; ========================
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

; Map(GroupName -> Array of Spec objects). Parallel index by group name
; so HSE_EnableGroup / HSE_DisableGroup can atomically splice their specs
; back into or out of HSE_RegistryByLastChar without re-running HSE_Register.
global HSE_RegistryByGroup := Map()

; Map(GroupName -> true) for disabled groups. Specs whose group appears
; here are absent from HSE_RegistryByLastChar until re-enabled.
global HSE_DisabledGroups := Map()

; Monotonically increasing insertion counter. Stored in each Spec as .Seq
; so that mappings registered later can be distinguished from earlier ones
; when length and group_order are equal (stable sort tiebreaker).
global HSE_SeqCounter := 0

; Flat array of all star-trigger Spec objects. Maintained alongside
; HSE_RegistryByLastChar so _HSE_StarTriggerCoversBody can scan only star
; triggers without iterating the full registry — avoids an O(all_triggers)
; walk on every word-terminator keystroke.
global HSE_StarSpecs := []

; Pre-computed prefix map for O(1) star-trigger cover check. For each star
; trigger registered, every strict prefix (length 1 to len-1) is stored as
; a key mapping to the set of characters that immediately follow that prefix
; in the registered star trigger(s). This lets _HSE_StarTriggerCoversBody
; verify that the typed end-char can actually extend toward the star trigger
; — suppression only happens when EndChar ∈ nextChars[prefix], preventing
; false suppression of end-char triggers (e.g. "ia" → "IA") by unrelated
; star triggers (e.g. "ia★") whose next char is the magic key, not space.
; Two maps: CI for case-insensitive triggers (lowercased keys), CS for
; case-sensitive triggers (exact-cased keys). Populated atomically in
; HSE_Register alongside HSE_StarSpecs; reset in HSE_RegistryClear.
global HSE_StarPrefixSetCI := Map()   ; prefix → Map(nextChar → true), CI
global HSE_StarPrefixSetCS := Map()   ; prefix → Map(nextChar → true), CS

; Star triggers indexed by FULL trigger string, for an O(buffer-suffix) match
; in HSE_FindMatchAtEnd instead of an O(all-star-triggers) bucket scan. Every
; star trigger ends in the magic key, so they ALL share one last-char bucket —
; ~2100 entries — and the old per-keystroke linear suffix test over that bucket
; cost ~21 ms on every magic-key press. A star trigger matches iff it equals
; some suffix of HSE_Buffer, so we probe the buffer's own suffixes (at most
; HSE_MaxStarTriggerLen of them) against these maps. Two maps mirror the
; case-sensitivity split used everywhere else (CI keys lowercased); values are
; arrays of Specs because the same trigger may be registered in several groups.
; Maintained alongside HSE_StarSpecs: incrementally in HSE_Register /
; HSE_EnableGroup, rebuilt in HSE_DisableGroup, reset in HSE_RegistryClear.
global HSE_StarByTriggerCI := Map()   ; lower(trigger) → [Spec, …], CI triggers
global HSE_StarByTriggerCS := Map()   ; exact trigger  → [Spec, …], CS triggers
; Longest registered star-trigger length — caps how many buffer suffixes we
; probe so the lookup never exceeds the longest trigger that could match.
global HSE_MaxStarTriggerLen := 0

; Suppression flag. When true, FeedChar / FeedBackspace / FeedReset
; short-circuit. The dispatch loop sets it for the duration of the
; SendEvent burst so its own replacement output does not feed back into
; the buffer through the InputHook.
global HSE_Suppressed := 0  ; depth counter (not bool) — multiple concurrent fires each hold their own level

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

; When false the engine-level repeat-key fallback (HSE_TryRepeatKey) is
; disabled — typed <x>★ sequences fall through unchanged.
global HSE_RepeatEnabled := true

; Set to true by HSE_FindMatchAtEnd when a NNBSP/NBSP was stripped from the
; buffer before matching a typographic end-char (``:`` / `` ; ``). The
; dispatcher reads this to add +1 to the BackSpace count so the NNBSP is
; erased together with the trigger and the end-char.
global HSE_TypoNbspStripped := false





; ============================================
; ======================================
; ======= 3/ Public registry API =======
; ======================================
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
; Register a mapping and return the created Spec object. The returned Spec
; has all domain-contract fields populated (Trigger, Repl, PlainRepl, IsWord,
; Auto, Seq, TLen, TriggerBytes, TailChar, HasMagic, StarBase, StarBaseBytes,
; StarBaseTail, Group, GroupOrder, FinalResult, Color) so callers that implement
; the Registry.spec.js contract can forward the return value directly.
;
; The optional Meta map is used by the production hotstring loader to inject
; dispatch metadata (Replacement, OnlyText, FinalResult, TimeActivationSeconds,
; PrevCharKey, IsRepeat, Category, Section). When absent the Spec can still
; be exercised by unit tests that pass a bare Callback.
HSE_Register(Flags, Trigger, Callback, Meta := unset) {
    global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_StarPrefixSetCI, HSE_StarPrefixSetCS
    global HSE_RegistryByGroup, HSE_DisabledGroups, HSE_SeqCounter, HSE_PRIORITY_COMMON
    if (Trigger == "") {
        return
    }
    HSE_SeqCounter++
    ; Resolve the group used by HSE_EnableGroup / HSE_DisableGroup for live,
    ; reload-free section toggling. An explicit Meta "group" always wins; when
    ; absent we derive "<category>.<section>" from the dispatch metadata so every
    ; hotstring loaded for a TOML section lands in its own toggleable group.
    ; Section-less registrations (inline expansions, unit tests) stay "default".
    ; Meta may be a Map (legacy / tests) or an object (production _MakeHotstringMeta).
    Group := "default"
    GroupOrder := 0
    if IsSet(Meta) {
        if Meta is Map {
            if Meta.Has("group")
                Group := Meta["group"]
            if Meta.Has("group_order")
                GroupOrder := Meta["group_order"]
            if (Group == "default" and Meta.Has("Category") and Meta.Has("Section")
                and Meta["Category"] != "" and Meta["Section"] != "")
                Group := Meta["Category"] . "." . Meta["Section"]
        } else {
            if Meta.HasOwnProp("group")
                Group := Meta.group
            if Meta.HasOwnProp("group_order")
                GroupOrder := Meta.group_order
            if (Group == "default" and Meta.HasOwnProp("Category") and Meta.HasOwnProp("Section")
                and Meta.Category != "" and Meta.Section != "")
                Group := Meta.Category . "." . Meta.Section
        }
    }
    IsStar := InStr(Flags, "*") > 0
    ; StarBase: trigger without trailing magic key (for magic-key cycling).
    ; Computed here once so the Spec is self-contained.
    StarBase := IsStar ? SubStr(Trigger, 1, StrLen(Trigger) - 1) : ""
    TailChar := SubStr(Trigger, -1)
    Spec := {
        Trigger:       Trigger,
        Length:        StrLen(Trigger),
        Callback:      Callback,
        Star:          IsStar,
        InWord:        InStr(Flags, "?") > 0,
        CaseSensitive: InStr(Flags, "C") > 0,
        ; Registry.spec.js domain-contract fields
        Repl:          "",
        PlainRepl:     "",
        IsWord:        InStr(Flags, "?") == 0,
        Auto:          IsStar,
        Seq:           HSE_SeqCounter,
        TLen:          StrLen(Trigger),
        TriggerBytes:  StrLen(Trigger),   ; AHK StrLen is codepoint-based; good enough
        TailChar:      TailChar,
        HasMagic:      IsStar,
        StarBase:      StarBase,
        StarBaseBytes: StrLen(StarBase),
        StarBaseTail:  (StarBase != "") ? SubStr(StarBase, -1) : "",
        Group:         Group,
        GroupOrder:    GroupOrder,
        ; Collision precedence among EQUAL-LENGTH triggers. Higher wins. Defaults
        ; to the common-source value; the loader overrides it via Meta with the
        ; resolved cascade (individual > section > file > source default). When no
        ; registration sets distinct priorities every Spec shares this value, so
        ; ties fall straight back to Seq — the pre-priority behaviour.
        Priority:      HSE_PRIORITY_COMMON,
        FinalResult:   false,
        Color:         ""
    }
    ; Optional dispatch metadata injected by the production loader.
    if IsSet(Meta) {
        if Meta is Map {
            for Key, Val in Meta {
                Spec.%Key% := Val
            }
        } else {
            ; Support legacy object-literal Meta (older callers).
            for Key, Val in Meta.OwnProps() {
                Spec.%Key% := Val
            }
        }
    }
    ; Propagate Repl → PlainRepl when the caller set Repl directly.
    if (Spec.PlainRepl == "" and Spec.Repl != "") {
        Spec.PlainRepl := Spec.Repl
    }
    ; Propagate Replacement (dispatch key) → Repl / PlainRepl for the
    ; contract fields when the loader used the old Replacement key name.
    if Spec.HasOwnProp("Replacement") and (Spec.Repl == "") {
        Spec.Repl := Spec.Replacement
        if (Spec.PlainRepl == "") {
            Spec.PlainRepl := Spec.Replacement
        }
    }

    ; Only insert into the live index when the group is not disabled.
    if !HSE_DisabledGroups.Has(Group) {
        _HsCrit := Critical("On")
        try {
            LastChar := TailChar
            LookupKey := Spec.CaseSensitive ? LastChar : StrLower(LastChar)
            if !HSE_RegistryByLastChar.Has(LookupKey) {
                HSE_RegistryByLastChar[LookupKey] := []
            }
            HSE_RegistryByLastChar[LookupKey].Push(Spec)
            ; Maintain the flat star-spec index and the O(1) prefix set so
            ; _HSE_StarTriggerCoversBody never has to scan on every terminator keystroke.
            if Spec.Star {
                HSE_StarSpecs.Push(Spec)
                _HSE_IndexStarPrefixes(Spec)
                _HSE_IndexStarTrigger(Spec)
            }
        } finally {
            Critical(_HsCrit)
        }
    }

    ; Always store in the group index regardless of enabled/disabled state
    ; so HSE_EnableGroup can restore them without re-registration.
    if !HSE_RegistryByGroup.Has(Group) {
        HSE_RegistryByGroup[Group] := []
    }
    HSE_RegistryByGroup[Group].Push(Spec)

    return Spec
}

; Erase the entire registry. Tests rely on this between cases; the live
; engine never needs it because Reload re-runs the registration code from
; scratch with a fresh module state.
HSE_RegistryClear() {
    global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_StarPrefixSetCI, HSE_StarPrefixSetCS
    global HSE_RegistryByGroup, HSE_DisabledGroups, HSE_SeqCounter
    global HSE_StarByTriggerCI, HSE_StarByTriggerCS, HSE_MaxStarTriggerLen
    HSE_RegistryByLastChar := Map()
    HSE_StarSpecs := []
    HSE_StarPrefixSetCI := Map()
    HSE_StarPrefixSetCS := Map()
    HSE_StarByTriggerCI := Map()
    HSE_StarByTriggerCS := Map()
    HSE_MaxStarTriggerLen := 0
    HSE_RegistryByGroup := Map()
    HSE_DisabledGroups := Map()
    HSE_SeqCounter := 0
}

; Return all active mappings whose trigger ends with TailChar, sorted
; longest-trigger-first (then GroupOrder ascending, then Seq ascending).
; Mirrors Registry.spec.js mappingsForTail(tailChar).
HSE_MappingsForTail(TailChar) {
    global HSE_RegistryByLastChar
    ; Collect from both the case-sensitive and case-insensitive buckets.
    Out := []
    LowerKey := StrLower(TailChar)
    if HSE_RegistryByLastChar.Has(TailChar) {
        for _, Spec in HSE_RegistryByLastChar[TailChar] {
            Out.Push(Spec)
        }
    }
    ; Avoid double-adding when TailChar is already lowercase.
    if (TailChar !== LowerKey) and HSE_RegistryByLastChar.Has(LowerKey) {
        for _, Spec in HSE_RegistryByLastChar[LowerKey] {
            Out.Push(Spec)
        }
    }
    ; Sort: longest trigger first, then Priority desc, then GroupOrder asc, then
    ; Seq asc. Priority slots in right after length so it mirrors the
    ; HSE_FindMatchAtEnd tie-break exactly. Bubble sort is fine — registry size
    ; is small and this is called rarely.
    Len := Out.Length
    loop (Len - 1) {
        i := A_Index
        loop (Len - i) {
            j := A_Index
            A := Out[j]
            B := Out[j + 1]
            APrio := A.HasOwnProp("Priority") ? A.Priority : 50
            BPrio := B.HasOwnProp("Priority") ? B.Priority : 50
            Swap := false
            if (A.Length < B.Length) {
                Swap := true
            } else if (A.Length == B.Length) {
                if (APrio < BPrio) {
                    Swap := true
                } else if (APrio == BPrio and A.GroupOrder > B.GroupOrder) {
                    Swap := true
                } else if (APrio == BPrio and A.GroupOrder == B.GroupOrder and A.Seq > B.Seq) {
                    Swap := true
                }
            }
            if Swap {
                Out[j]     := B
                Out[j + 1] := A
            }
        }
    }
    return Out
}

; Remove all mappings in Group from the live index. They remain stored in
; HSE_RegistryByGroup so HSE_EnableGroup can restore them later.
HSE_DisableGroup(Group) {
    global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_StarPrefixSetCI, HSE_StarPrefixSetCS
    global HSE_RegistryByGroup, HSE_DisabledGroups
    if !HSE_RegistryByGroup.Has(Group) {
        HSE_DisabledGroups[Group] := true
        return
    }
    HSE_DisabledGroups[Group] := true
    ; ATOMICITY — same contract as HSE_Register: the splice below resets the whole
    ; star prefix set / by-trigger index to empty before re-indexing the survivors,
    ; opening a wide window where an OnChar reader (HSE_FindMatchAtEnd) would see an
    ; empty star index and drop every star expansion for the rebuild duration. This
    ; is wrapped in Critical so the reader thread never preempts mid-rebuild and the
    ; index is never observed empty. Critical is safe here: every step is in-memory
    ; (Map/Array mutation), no Sleep. NOTE for any future re-wiring of group toggling
    ; to a live menu path: keep this Critical wrap — without it the dead-path race
    ; this guards becomes a live high-severity star-expansion drop.
    _DgCrit := Critical("On")
    try {
        ; Remove each spec from the live index.
        for _, Spec in HSE_RegistryByGroup[Group] {
            LookupKey := Spec.CaseSensitive ? Spec.TailChar : StrLower(Spec.TailChar)
            if HSE_RegistryByLastChar.Has(LookupKey) {
                Bucket := HSE_RegistryByLastChar[LookupKey]
                NewBucket := []
                for _, S in Bucket {
                    if (S.Seq !== Spec.Seq) {
                        NewBucket.Push(S)
                    }
                }
                HSE_RegistryByLastChar[LookupKey] := NewBucket
            }
            ; Remove from star index if applicable.
            if Spec.Star {
                NewStarSpecs := []
                for _, S in HSE_StarSpecs {
                    if (S.Seq !== Spec.Seq) {
                        NewStarSpecs.Push(S)
                    }
                }
                HSE_StarSpecs := NewStarSpecs
            }
        }
        ; Rebuild the prefix sets and the by-trigger index from the remaining star
        ; specs — both derive from HSE_StarSpecs, which was just spliced above.
        HSE_StarPrefixSetCI := Map()
        HSE_StarPrefixSetCS := Map()
        for _, S in HSE_StarSpecs {
            _HSE_IndexStarPrefixes(S)
        }
        _HSE_RebuildStarTriggerIndex()
    } finally {
        Critical(_DgCrit)
    }
}

; Restore all mappings in Group to the live index.
HSE_EnableGroup(Group) {
    global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_StarPrefixSetCI, HSE_StarPrefixSetCS
    global HSE_RegistryByGroup, HSE_DisabledGroups
    if HSE_DisabledGroups.Has(Group) {
        HSE_DisabledGroups.Delete(Group)
    }
    if !HSE_RegistryByGroup.Has(Group) {
        return
    }
    ; ATOMICITY — same contract as HSE_DisableGroup: re-inserting specs into the live
    ; index must not be observed half-done by _OnPrefixChar running on the hook thread.
    ; Without Critical, the reader can see a partially re-populated bucket and match
    ; against stale (duplicate or missing) specs for the rebuild duration.
    _EgCrit := Critical("On")
    try {
        ; Re-insert each spec into the live index.
        for _, Spec in HSE_RegistryByGroup[Group] {
            LookupKey := Spec.CaseSensitive ? Spec.TailChar : StrLower(Spec.TailChar)
            if !HSE_RegistryByLastChar.Has(LookupKey) {
                HSE_RegistryByLastChar[LookupKey] := []
            }
            ; Avoid duplicates (idempotent enable).
            AlreadyIn := false
            for _, S in HSE_RegistryByLastChar[LookupKey] {
                if (S.Seq == Spec.Seq) {
                    AlreadyIn := true
                    break
                }
            }
            if !AlreadyIn {
                HSE_RegistryByLastChar[LookupKey].Push(Spec)
            }
            if Spec.Star {
                AlreadyStar := false
                for _, S in HSE_StarSpecs {
                    if (S.Seq == Spec.Seq) {
                        AlreadyStar := true
                        break
                    }
                }
                if !AlreadyStar {
                    HSE_StarSpecs.Push(Spec)
                    _HSE_IndexStarPrefixes(Spec)
                    _HSE_IndexStarTrigger(Spec)
                }
            }
        }
    } finally {
        Critical(_EgCrit)
    }
}

; Return the total number of active mappings across all groups.
; Mirrors Registry.spec.js size().
HSE_Size() {
    global HSE_RegistryByLastChar
    Total := 0
    for , Bucket in HSE_RegistryByLastChar {
        Total += Bucket.Length
    }
    return Total
}





; ============================================
; ==================================
; ======= 4/ Buffer mutation =======
; ==================================
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
    if YesNo {
        HSE_Suppressed += 1
    } else {
        HSE_Suppressed := Max(0, HSE_Suppressed - 1)
    }
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
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN, HSE_TypoNbspStripped
    global HSE_CONSUMED_DELIMITERS

    StripLen := Spec.Length + (EndChar != "" ? 1 : 0) + (HSE_TypoNbspStripped ? 1 : 0)
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
    ; Consumed delimiters are swallowed by the dispatcher and never re-injected
    ; into the app — appending them to the buffer here would desync it with the
    ; actual screen state and make the next trigger match against a ghost char.
    HSE_Buffer .= Replacement
    if (EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar))
        HSE_Buffer .= EndChar

    if (StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN) {
        HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
        HSE_StartIsWordBoundary := false
    }
}


; Attempt the magic-key repeat: when the user types <x><MagicKey> and x is
; preceded by at least one non-terminator letter (i.e. x is not the first
; letter of the word), emit <x><x> instead. This is the engine-level fallback
; that replaced the now-removed [[repeat]] TOML entries — it fires only when no
; registered hotstring already claimed the <x><MagicKey> sequence.
;
; Returns a minimal Spec-like object compatible with HSE_DispatchMatch (star
; trigger, no end char) or "" when the repeat condition is not met.
HSE_TryRepeatKey(MagicKey) {
    global HSE_Buffer, HSE_StartIsWordBoundary, HSE_WORD_TERMINATORS, HSE_RepeatEnabled, HSE_Suppressed
    if !HSE_RepeatEnabled or HSE_Suppressed {
        return ""
    }
    MkLen := StrLen(MagicKey)
    BufLen := StrLen(HSE_Buffer)
    ; Buffer must contain at least <x><RepeatChar><MagicKey> = MkLen+2 chars.
    if (BufLen <= MkLen) {
        return ""
    }
    ; Verify the buffer ends with MagicKey.
    if (SubStr(HSE_Buffer, -MkLen) !== MagicKey) {
        return ""
    }
    ; The char being repeated is immediately before the magic key.
    RepeatCharPos := BufLen - MkLen
    RepeatChar := SubStr(HSE_Buffer, RepeatCharPos, 1)
    ; Refuse to repeat whitespace or terminators.
    if (RepeatChar == "" or InStr(HSE_WORD_TERMINATORS, RepeatChar) > 0) {
        return ""
    }
    ; The char before RepeatChar must exist and be a non-terminator — this ensures
    ; RepeatChar is at least the 2nd letter of the current word.
    PredPos := RepeatCharPos - 1
    if (PredPos < 1) {
        ; RepeatChar is flush at the start of the buffer — refuse to repeat because
        ; we cannot confirm it is mid-word.
        return ""
    }
    PredChar := SubStr(HSE_Buffer, PredPos, 1)
    if (InStr(HSE_WORD_TERMINATORS, PredChar) > 0) {
        return ""
    }
    ; When PredChar sits at position 1 of the buffer (PredPos == 1) and the buffer
    ; start context is unknown (HSE_StartIsWordBoundary = false), we cannot confirm
    ; RepeatChar is truly the 2nd+ letter of a word — refuse to avoid false-positive
    ; doubling when a registered text-expansion with the same suffix happens to fail
    ; its own word-boundary check.
    if (PredPos == 1 and !HSE_StartIsWordBoundary) {
        return ""
    }
    ; All checks passed — build a transient Spec and fire.
    TriggerStr := RepeatChar . MagicKey
    return {
        Trigger:     TriggerStr,
        Length:      StrLen(TriggerStr),
        Star:        true,
        InWord:      true,
        IsRepeat:    true,
        Replacement: RepeatChar . RepeatChar,
        OnlyText:    true,
        FinalResult: false
    }
}





; ============================================
; ==============================
; ======= 5/ Match logic =======
; ==============================
; ============================================

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
    MaxSuffix := Min(BufLen, HSE_MaxStarTriggerLen)
    loop MaxSuffix {
        Suffix := SubStr(HSE_Buffer, -A_Index)
        ; Case-sensitive triggers: exact suffix key.
        if HSE_StarByTriggerCS.Has(Suffix) {
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
            EffBodyLastChar := SubStr(EffBody, -1)
            if (EffBodyLastChar != "") {
                Buckets2 := _HSE_BucketsFor(EffBodyLastChar)
                for _, Bucket in Buckets2 {
                    for _, Spec in Bucket {
                        if Spec.Star {
                            continue
                        }
                        if !HSE_SuffixMatches(EffBody, Spec.Trigger, Spec.CaseSensitive) {
                            continue
                        }
                        if !_HSE_WordBoundaryAllows(EffBody, Spec) {
                            continue
                        }
                        ; Star-prefix priority: suppress the end-char match only when
                        ; the just-typed end char can itself continue toward a star
                        ; trigger (e.g. magic-key press after "ia" → yields to "ia★").
                        ; Typing space after "ia" does NOT suppress because space is not
                        ; the magic key and cannot reach "ia★".
                        if _HSE_StarTriggerCoversBody(EffBody, Spec, JustTypedChar) {
                            continue
                        }
                        if _HSE_EndCharBeats(Spec, BestMatch, BestEndChar != "") {
                            BestMatch := Spec
                            BestEndChar := JustTypedChar
                        }
                    }
                }
            }
        }
    }

    HSE_LastEndChar := BestEndChar
    return BestMatch
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
        T := Spec.Trigger
        Set := HSE_StarPrefixSetCS
    } else {
        T := StrLower(Spec.Trigger)
        Set := HSE_StarPrefixSetCI
    }
    ; Build each successive prefix by appending one char rather than re-slicing
    ; from position 1 each iteration (the old SubStr(Trigger, 1, i) was O(len^2)
    ; in total characters copied per registration).
    Len := StrLen(T)
    Prefix := ""
    loop (Len - 1) {
        Prefix .= SubStr(T, A_Index, 1)
        NextChar := SubStr(T, A_Index + 1, 1)
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





; ============================================
; ===========================
; ======= 6/ Dispatch =======
; ===========================
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
        return
    }
    HSE_Suppress(true)
    if IsSet(PrefixWatcherSuppress) {
        try PrefixWatcherSuppress(true)
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
        SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        if IsSet(PrefixWatcherSuppress) {
            SetTimer((*) => PrefixWatcherSuppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        }
        SetTimer((*) => KL_ClearSynthetic(), -HSE_SUPPRESS_RELEASE_DELAY_MS)
    }
}

HSE_DispatchMatch(Spec, EndChar) {
    global HSE_SUPPRESS_RELEASE_DELAY_MS, _SendHook, HSE_TypoNbspStripped, HSE_Buffer
    if (Spec == "") {
        return
    }
    ; Raw-callback specs (the natives migrated into the HSE: E-circumflex deadkey,
    ; "..." ellipsis) do all their own conditional, variable-length send/backspace;
    ; route them to _HSE_DispatchRawCallback so the engine never auto-strips a
    ; trigger the callback may have left in place.
    if (Spec.HasOwnProp("RawCallback") and Spec.RawCallback) {
        _HSE_DispatchRawCallback(Spec, EndChar)
        return
    }
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
            return
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
            return
        }
    }

    HSE_Suppress(true)
    ; Mirror _HotstringDispatch's PrefixWatcherSuppress guard: mute the
    ; prefix watcher for the duration of the send burst so the backspaces
    ; and replacement characters do not pollute _PrefixBuffer and stale the
    ; tooltip state. Without this, calling HSE_DispatchMatch from outside the
    ; InputHook callback (e.g. SpaceTapHold) leaves _PrefixBuffer pointing at
    ; the pre-expansion context, causing incorrect tooltip lookups afterward.
    if IsSet(PrefixWatcherSuppress) {
        try PrefixWatcherSuppress(true)
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
            ; replacement is routed through the clipboard. This is the ONE remaining
            ; non-atomic path (SendEvent backspaces + a clipboard paste); a physical
            ; key typed mid-expansion can still interleave here, but the atomic path
            ; is unreliable in Notepad specifically, so the trade-off stands.
            ; SendInstant Sleeps (paste-settle); a caller may have entered Critical
            ; (_OnPrefixChar does), and Critical MUST NOT span a Sleep — it would
            ; yield (breaking the guarantee) and freeze all input ~200 ms. Release
            ; Critical for this branch and restore it after. No-op when the caller
            ; was not Critical (the space tap-hold path).
            ; Mirror the atomic branch's consumed-delimiter guard so a space
            ; (or any other consumed end-char) is not re-injected after the
            ; clipboard paste — same contract as the SendInput path.
            EndCharEmitted := (EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)) ? EndChar : ""
            _NpCrit := Critical("Off")
            try {
                SendNewResult(BackSpaceSeq, false)
                SendInstant(Replacement . EndCharEmitted)
            } finally {
                Critical(_NpCrit)
            }
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
            UpdateLastSentCharacter(SubStr(EndChar != "" ? EndChar : Replacement, -1))
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
        SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        if IsSet(PrefixWatcherSuppress) {
            SetTimer((*) => PrefixWatcherSuppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
        }
        ; Release the synthetic flag on the same flush window as the suppression
        ; — clearing inline would let trailing replacement keystrokes look manual.
        SetTimer((*) => KL_ClearSynthetic(), -HSE_SUPPRESS_RELEASE_DELAY_MS)
    }
}





; ============================================
; ==================================
; ======= 7/ Suffix matching =======
; ==================================
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
