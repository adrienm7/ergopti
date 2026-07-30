; lib/hotstrings/hotstring_engine_main.ahk

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





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Maximum buffer length. Anything older than the longest registered trigger
; is irrelevant for matching; we cap so memory and lookup cost stay bounded.
; Mirrors the shared cap _shared/lua/hotstring_engine/init.lua BUFFER_MAX_CHARS
; (256) and the prefix watcher's _MAX_BUFFER_LEN; pinned equal by
; tools/test/test-hotstring-buffer-cap-parity.cjs.
global HSE_MAX_BUFFER_LEN := 256

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

; Characters that OPEN a word without TERMINATING a trigger. Declared HERE,
; next to the terminator set, because the matcher gate needs it at auto-execute
; time — hotstrings_io.ahk loads later, so a reference to a constant defined
; there would be unassigned at boot and kill the driver outright.
global HOTSTRINGS_QUOTE_WORD_BOUNDARIES := Chr(0x22) . Chr(0x201C) . Chr(0x201D)

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
; SINGLE SOURCE OF TRUTH: _shared/modules/hotstrings/priority.json. These literals are
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





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

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

; Non-star triggers use the same full-trigger indexes as star triggers.  End
; character matching probes bounded suffix lengths instead of scanning a dense
; last-character bucket on every word terminator.
global HSE_EndByTriggerCI := Map()
global HSE_EndByTriggerCS := Map()
global HSE_MaxEndTriggerLen := 0

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





; ======================================
; ======================================
; ======= 3/ Public registry API =======
; ======================================
; ======================================

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
						} else {
								_HSE_IndexEndTrigger(Spec)
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
		global HSE_EndByTriggerCI, HSE_EndByTriggerCS, HSE_MaxEndTriggerLen
		HSE_RegistryByLastChar := Map()
		HSE_StarSpecs := []
		HSE_StarPrefixSetCI := Map()
		HSE_StarPrefixSetCS := Map()
		HSE_StarByTriggerCI := Map()
		HSE_StarByTriggerCS := Map()
		HSE_MaxStarTriggerLen := 0
		HSE_EndByTriggerCI := Map()
		HSE_EndByTriggerCS := Map()
		HSE_MaxEndTriggerLen := 0
		HSE_RegistryByGroup := Map()
		HSE_DisabledGroups := Map()
		HSE_SeqCounter := 0
}

; Return all active mappings whose trigger ends with TailChar, sorted
; longest-trigger-first (then GroupOrder ascending, then Seq ascending).
; Mirrors Registry.spec.js mappingsForTail(tailChar).
;
; CONTRACT ACCESSOR — NOT ON THE MATCH PATH. It has zero production callers; it
; exists so the cross-driver Registry.spec.js contract stays exercised
; (test_domain_registry.ahk, test_personal_toml_editor.ahk). HSE_FindMatchAtEnd
; resolves matches through the by-trigger indexes and never consults
; HSE_RegistryByLastChar, so the O(n^2) sort below is a test-time cost only —
; the "registry size is small and this is called rarely" note used to read as a
; statement about the hot path, which sent a performance reader here by mistake.
; Its sibling _HSE_BucketsFor, which had no callers at all, was deleted.
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
		; HSE_FindMatchAtEnd tie-break exactly.
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
				_HSE_RebuildEndTriggerIndex()
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
						} else if !AlreadyIn {
								_HSE_IndexEndTrigger(Spec)
						}
				}
		} finally {
				Critical(_EgCrit)
		}
}

; Fully wipe a single HSE group in preparation for a live section-scoped
; reload (as opposed to HSE_DisableGroup, which only STASHES the group's specs
; so a later HSE_EnableGroup can restore them). Reuses HSE_DisableGroup's
; Critical-wrapped live-index splice, then also discards the stash and lifts
; the disabled marker so the caller's fresh HSE_Register calls for this group
; land in a clean, live-eligible index instead of extending stale specs behind
; the newest registration or being silently dropped by the disabled-group gate
; (personal-hotstring-live-reload-stale-group).
; @param Group {String} HSE group string ("<loader_category>.<section>").
HSE_ClearGroupForReload(Group) {
		global HSE_RegistryByGroup, HSE_DisabledGroups
		HSE_DisableGroup(Group)
		HSE_RegistryByGroup[Group] := []
		if HSE_DisabledGroups.Has(Group)
				HSE_DisabledGroups.Delete(Group)
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





; ==================================
; ==================================
; ======= 4/ Buffer mutation =======
; ==================================
; ==================================

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
HSE_FeedChar(Char, IsPhysical := false) {
		global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN
		global HSE_LastMatch, HSE_LastEndChar, HSE_Suppressed
		HSE_LastMatch := ""
		HSE_LastEndChar := ""
		if ((HSE_Suppressed and !IsPhysical) or (Char == "")) {
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
HSE_FeedBackspace(IsPhysical := false) {
		global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
		if HSE_Suppressed and !IsPhysical {
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
HSE_FeedReset(KnownTerminatorBefore := false, IsPhysical := false) {
		global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
		if HSE_Suppressed and !IsPhysical {
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
		global HSE_RebuildInProgress
		; The live-rebuild fence belongs here as much as in HSE_FindMatchAtEnd. While
		; the registry is being rewritten the matcher answers "" for EVERY sequence —
		; that means "the registry cannot answer right now", not "no trigger claims
		; this". _OnPrefixChar cannot tell the two apart, so it falls through to this
		; fallback and the doubling replaces the expansion the user asked for with
		; different text for the ~1.3 s a live toggle takes. Passing the keystroke
		; through unexpanded is the contract RebuildHotstringsLive advertises.
		if (HSE_RebuildInProgress or !HSE_RepeatEnabled or HSE_Suppressed) {
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
		if (RepeatChar == "" or InStr(_HSE_WordBoundarySet(), RepeatChar) > 0) {
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
		; Boundary set, not terminator set: after an opening quote the char is the
		; FIRST letter of its word, so doubling it is meaningless and the real
		; expansion must be allowed to win instead.
		if (InStr(_HSE_WordBoundarySet(), PredChar) > 0) {
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

#Include hotstring_match.ahk
#Include hotstring_dispatch.ahk
