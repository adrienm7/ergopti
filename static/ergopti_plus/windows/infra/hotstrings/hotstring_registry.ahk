; infra/hotstrings/hotstring_registry.ahk

; ==============================================================================
; MODULE: Hotstring Registry Construction
; DESCRIPTION:
; Builds the auxiliary hotstring catalogue from TOML files and the precompiled
; cache. Exposes _RegisterCategoryTriggers (TOML path) and
; _RegisterCategoryTriggersFromCache (cache fast-path) which populate the
; compatibility index and near-miss trigger set. Tooltip selection does not use
; either structure; it asks the live HSE registry directly.
;
; FEATURES & RATIONALE:
; 1. TOML path — parses each category file directly; always up-to-date but
;    slower on cold boot (disk I/O + regex per entry).
; 2. Cache fast-path (_RegisterCategoryTriggersFromCache) — reads from
;    _HS_CACHE_ROWS (pre-parsed at boot) so the deferred rebuild completes in
;    < 10 ms instead of multi-second disk scans. Personal hotstrings are
;    excluded from the cache as their TOML path is user-relocatable.
; 3. Case-variant expansion (_AddTriggerVariants) keeps catalogue analytics
;    comparable with the live registrations.
;
; Included by infra/hotstrings/hotstring_prefix_watcher.ahk.
; ==============================================================================




; ============================================================
; ============================================================
; ======= 1/ Registry construction ==========================
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
	return _SharedDir . "\modules\hotstrings\" . LowerCat . ".toml"
}

; Scan a category TOML and add every (trigger, output) pair to the auxiliary
; catalogue. Returns the number of entries registered. Lightweight regex scan —
; we capture trigger, output and the case-sensitivity flags so we can
; pre-compute the exact same case variants the engine registers.
; IndexTarget / SetTarget — optional Maps to populate. When omitted they
; resolve to the live globals (the historical behaviour every direct caller
; relies on); HotstringPrefixWatcherRebuildIndex passes fresh locals instead so
; it can build the whole index off to the side and swap it in atomically.
; One TOML hotstring entry, as written by the generator.
; Capture: 1=trigger, 2=output, 3=is_case_sensitive,
; 4=is_case_sensitive_strict (optional), 5=priority (optional). The individual
; priority is retained as catalogue metadata; collision selection is engine-owned.
;
; Hoisted to a single constant because the extension-pack indexer below parses the
; same file shape; two copies of a regex this size drift.
global HS_PREFIX_ENTRY_PATTERN :=
	'i)^"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*\{\s*output\s*=\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,\s*is_word\s*=\s*(?:true|false)\s*,\s*auto_expand\s*=\s*(?:true|false)\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(?:true|false)(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?(?:\s*,\s*priority\s*=\s*([0-9]+))?\s*\}'

_RegisterCategoryTriggers(Category, IndexTarget := "", SetTarget := "") {
	global ScriptInformation, Features, _V1CatToV2CatMap, _PrefixIndex, _TriggerSet
	global HS_PREFIX_ENTRY_PATTERN
	if !IsObject(IndexTarget)
		IndexTarget := _PrefixIndex
	if !IsObject(SetTarget)
		SetTarget := _TriggerSet
	; 1. Master gate check — if the hotstrings category is disabled globally,
	;    stop here. The watcher index will be empty for all groups.
	if !IsCategoryGated("Hotstrings") {
		return 0
	}

	Path := _PrefixWatcherTomlPath(Category)
	if !FileExist(Path) {
		if (StrLower(Category) == "personal")
			try LoggerWarn("PrefixWatcher", "Personal TOML not found at configured path: {1}.", Path)
		return 0
	}

	; 2. Category mapping — _PREFIX_WATCHER_CATEGORIES uses lowercase but
	;    Features v2 uses snake_case with underscores.
	V2Cat := Category
	if (V2Cat == "distancesreduction")
		V2Cat := "distances_reduction"
	else if (V2Cat == "sfbsreduction")
		V2Cat := "sfbs_reduction"
	else if (V2Cat == "magickey")
		V2Cat := "magic_key"

	if !Features.Has("hotstrings") or !Features["hotstrings"].Has(V2Cat) {
		return 0
	}

	EntryPattern := HS_PREFIX_ENTRY_PATTERN

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

		; 3. Section enabled check — only index triggers for sections that
		;    are actually enabled in the Features Map.
		SecId := CurrentSection
		if !Features["hotstrings"][V2Cat].Has(SecId) {
			continue
		}
		FNode := Features["hotstrings"][V2Cat][SecId]
		if !(IsObject(FNode) and FNode.Has("enabled") and FNode["enabled"]) {
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
		; Individual per-hotstring priority override (top of the cascade), empty
		; when the entry carries no `priority = N` key.
		Individual := (Match[5] != "") ? Match[5] + 0 : ""
		; Substitute ★ with the user's configured magic key so the prefix
		; index reflects what the user actually types at runtime.
		if (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
			Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
			Output  := StrReplace(Output,  "★", ScriptInformation["MagicKey"])
		}
		_AddTriggerVariants(Trigger, Output, Category, CurrentSection, IsCaseSensitive, IsStrict, Individual, IndexTarget, SetTarget)
		Count += 1
	}
	return Count
}

; Enumerates the extension-pack TOMLs: every *.toml under PersonalHotstringsDir
; except the root personal_hotstrings.toml, which is its own category. Sub-folders
; produce hierarchical labels ("work / snippets"), matching what the engine's
; registration already builds.
;
; Extracted so catalogue consumers share one recursive walk. Visible preview no
; longer depends on this filesystem projection.
; @returns {Array} Items of Map("Path", <full path>, "Label", <category label>).
HS_EnumeratePersonalExtFiles() {
	global ScriptInformation
	Found := []
	if !(IsSet(ScriptInformation) and ScriptInformation.Has("PersonalHotstringsDir"))
		return Found
	Root := RegExReplace(ScriptInformation["PersonalHotstringsDir"], "[/\\]+$")
	if !DirExist(Root)
		return Found

	; Explicit stack rather than a recursive closure: this runs on the index
	; rebuild path, and a closure that captures itself is the shape that already
	; cost this driver a silent nil-binding elsewhere.
	Pending := [Map("Dir", Root, "Prefix", "")]
	while (Pending.Length > 0) {
		Node := Pending.Pop()
		Dir := Node["Dir"]
		Prefix := Node["Prefix"]
		Loop Files Dir . "\*", "DF" {
			Child := (Prefix == "" ? "" : Prefix . " / ") . A_LoopFileName
			if (A_LoopFileAttrib ~= "D") {
				Pending.Push(Map("Dir", A_LoopFileFullPath, "Prefix", Child))
				continue
			}
			if !(A_LoopFileName ~= "i)\.toml$")
				continue
			if (Prefix == "" and A_LoopFileName == "personal_hotstrings.toml")
				continue
			SplitPath A_LoopFileFullPath, , , , &Stem
			Found.Push(Map("Path", A_LoopFileFullPath,
				"Label", (Prefix == "" ? "" : Prefix . " / ") . Stem))
		}
	}
	return Found
}

; Indexes one extension-pack TOML into the auxiliary catalogue.
;
; Deliberately does NOT apply the per-section Features gate _RegisterCategoryTriggers
; applies: an extension pack has no per-section toggle in the menu — the engine loads
; every section of it (LoadExtTomlFile, "all sections enabled") — so applying a
; Features node that cannot exist would erase the pack from analytics.
; The master hotstrings gate still applies, because that one really can silence a pack.
; @param Path        {String} Full path to the pack's TOML.
; @param Label       {String} Category label to attribute previews to.
; @param IndexTarget {Map}    Index being built.
; @param SetTarget   {Map}    Trigger set being built.
; @returns {Integer} Number of triggers indexed.
_RegisterExtPackTriggers(Path, Label, IndexTarget, SetTarget) {
	global ScriptInformation, HS_PREFIX_ENTRY_PATTERN
	global HS_TOML_SECTION_HEADER_PATTERN, _HOTSTRING_SIMPLE_ENTRY_PATTERN
	global HSE_PRIORITY_PACKAGE
	if !IsCategoryGated("Hotstrings")
		return 0
	if !FileExist(Path)
		return 0

	CurrentSection := ""
	Count := 0
	loop parse, ReadTomlFile(Path), "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#")
			continue
		; The SHARED header pattern, which accepts one OR more brackets. This
		; previously matched `[[section]]` only and reset CurrentSection on any
		; other bracketed line, so every entry under a single-bracket `[section]`
		; header was skipped — while LoadExtTomlFile registered them happily. The
		; pack expanded and could never be previewed.
		if RegExMatch(Line, HS_TOML_SECTION_HEADER_PATTERN, &SectionMatch) {
			CurrentSection := StrLower(Trim(SectionMatch[1]))
			continue
		}
		if (CurrentSection == "")
			continue
		; Metadata blocks describe the file and are not hotstrings. The engine skips
		; them explicitly; here the old single-bracket RESET happened to stand in
		; for that, so accepting single brackets above means the skip has to become
		; explicit too — otherwise a [_meta] description would index as a trigger.
		if (CurrentSection == "_meta" or InStr(CurrentSection, "_meta."))
			continue

		Trigger := ""
		Output := ""
		IsCaseSensitive := false
		IsStrict := false
		Individual := ""
		if RegExMatch(Line, HS_PREFIX_ENTRY_PATTERN, &Match) {
			Trigger := UnescapeTomlString(Match[1])
			Output := UnescapeTomlString(Match[2])
			IsCaseSensitive := (Match[3] == "true")
			IsStrict := (Match.Count >= 4 and Match[4] == "true")
			Individual := (Match[5] != "") ? Match[5] + 0 : ""
		} else if RegExMatch(Line, _HOTSTRING_SIMPLE_ENTRY_PATTERN, &SimpleMatch) {
			; The engine's second accepted shape: a bare `key = "value"` line, which
			; LoadExtTomlFile registers through CreateCaseSensitiveHotstrings. The
			; preview side ignored it entirely, so those entries expanded without
			; ever being previewable.
			Trigger := UnescapeTomlString(
				(SimpleMatch[1] != "") ? SimpleMatch[1] : SimpleMatch[2])
			Output := UnescapeTomlString(SimpleMatch[3])
		} else {
			continue
		}
		if (Trigger == "")
			continue
		if (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey")) {
			Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
			Output := StrReplace(Output, "★", ScriptInformation["MagicKey"])
		}
		; Rank the preview at the priority the ENGINE fires this pack at.
		; LoadExtTomlFile registers every ext-pack entry at HSE_PRIORITY_PACKAGE
		; (both shapes: _ParseEntryPriority's fallback and the simple-entry
		; Options), while the index's own fallback is HSE_PRIORITY_COMMON — and it
		; is reached here because a pack's Category is its LABEL, which
		; HotstringsResolve knows nothing about. A pack trigger colliding with a
		; bundled one therefore previewed as the LOSER and fired as the winner:
		; the tooltip named one expansion and the user got another
		; (ext-pack-preview-ranked-below-its-fire).
		_AddTriggerVariants(Trigger, Output, Label, CurrentSection, IsCaseSensitive, IsStrict,
			Individual, IndexTarget, SetTarget, HSE_PRIORITY_PACKAGE)
		Count += 1
	}
	return Count
}

; True when a category's hotstrings live in the precompiled in-memory cache
; (HS_BUNDLED_CATEGORIES, loaded once at boot via HotstringsCacheEnsure). Personal
; is deliberately NOT bundled — its TOML can live outside the repo — so it always
; takes the TOML rebuild path. Returns false until the cache is loaded so an early
; rebuild (before HotstringsCacheEnsure ran) safely falls back to the TOML scan.
_PrefixWatcherCategoryIsCached(Category) {
	global HS_BUNDLED_CATEGORIES, _HS_CACHE_LOADED
	if (!IsSet(_HS_CACHE_LOADED) or !_HS_CACHE_LOADED or !IsSet(HS_BUNDLED_CATEGORIES))
		return false
	LowerCat := StrLower(Category)
	for Cat in HS_BUNDLED_CATEGORIES {
		if (StrLower(Cat) == LowerCat)
			return true
	}
	return false
}

; Build a bundled category's prefix entries from the in-memory _HS_CACHE_ROWS
; instead of re-reading + regex-parsing its TOML from disk. The bundled hotstrings
; are already parsed into _HS_CACHE_ROWS at boot (for the HSE fast path), so the
; index rebuild reuses that work: no FileRead, no per-line regex — the optimisation
; that collapses the deferred rebuild from a cold-disk multi-second rescan to a few
; ms. Mirrors _RegisterCategoryTriggers' gating (master gate, V2 category remap,
; per-section Features "enabled" flag) and feeds the SAME _AddTriggerVariants
; pipeline so the resulting entries are byte-identical (pinned by
; test_prefix_index_cache_equiv). Returns the number of entries registered.
_RegisterCategoryTriggersFromCache(Category, IndexTarget := "", SetTarget := "") {
	global Features, ScriptInformation, _HS_CACHE_ROWS, _PrefixIndex, _TriggerSet, HS_CACHE_MARKER
	if !IsObject(IndexTarget)
		IndexTarget := _PrefixIndex
	if !IsObject(SetTarget)
		SetTarget := _TriggerSet
	; 1. Master gate — a globally disabled Hotstrings category yields an empty
	;    index through this path exactly as through the TOML path.
	if !IsCategoryGated("Hotstrings") {
		return 0
	}
	; 2. Category mapping — the cache keys (and _PREFIX_WATCHER_CATEGORIES) use
	;    lowercase but Features v2 uses snake_case (same remap as the TOML path).
	V2Cat := Category
	if (V2Cat == "distancesreduction")
		V2Cat := "distances_reduction"
	else if (V2Cat == "sfbsreduction")
		V2Cat := "sfbs_reduction"
	else if (V2Cat == "magickey")
		V2Cat := "magic_key"
	if !Features.Has("hotstrings") or !Features["hotstrings"].Has(V2Cat) {
		return 0
	}
	MagicKey := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey"))
		? ScriptInformation["MagicKey"] : HS_CACHE_MARKER
	CatPrefix := StrLower(Category) . "."
	CatPrefixLen := StrLen(CatPrefix)
	Count := 0
	for Key, RowList in _HS_CACHE_ROWS {
		if (SubStr(Key, 1, CatPrefixLen) != CatPrefix) {
			continue
		}
		; Section is the key remainder after the first dot (limit 2 so a section
		; name that itself contains a dot survives — matches _HsCacheRegisterSection).
		Parts := StrSplit(Key, ".", , 2)
		SecId := Parts.Length >= 2 ? Parts[2] : ""
		; 3. Section-enabled gate — only index sections whose Features flag is set,
		;    identical to the TOML path so a live toggle adds/removes them in lockstep.
		if !Features["hotstrings"][V2Cat].Has(SecId) {
			continue
		}
		FNode := Features["hotstrings"][V2Cat][SecId]
		if !(IsObject(FNode) and FNode.Has("enabled") and FNode["enabled"]) {
			continue
		}
		for Row in RowList {
			; Row layout (hotstrings_cache.ahk): [flags, trigger(★ preserved),
			; output, finalResult, isRepeat, isCaseSens, priorityOverride]. The
			; watcher index only needs case-sensitivity, strictness (the "C" flag
			; == is_case_sensitive_strict) and the per-entry priority override;
			; finalResult/isRepeat/is_word/auto_expand do not affect the index.
			IsCaseSensitive := Row[6]
			IsStrict := InStr(Row[1], "C") > 0
			Individual := (Row.Length >= 7 and Row[7] != "") ? (Row[7] + 0) : ""
			; ★ marker → the user's configured magic key, exactly as the TOML path
			; substitutes it before indexing so the index reflects real keystrokes.
			Trigger := StrReplace(Row[2], HS_CACHE_MARKER, MagicKey)
			Output := StrReplace(Row[3], HS_CACHE_MARKER, MagicKey)
			_AddTriggerVariants(Trigger, Output, Category, SecId, IsCaseSensitive, IsStrict, Individual, IndexTarget, SetTarget)
			Count += 1
		}
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
_AddTriggerVariants(Trigger, Output, Category, Section, IsCaseSensitive, IsStrict, Individual := "", IndexTarget := "", SetTarget := "", SourceDefault := "") {
	global ScriptInformation
	if IsStrict {
		; Strict triggers only match the exact casing in the TOML — anything
		; else neither fires nor previews.
		_AddTriggerToIndex(Trigger, Output, Category, Section, Individual, IndexTarget, SetTarget, SourceDefault)
		return
	}
	if IsCaseSensitive {
		; Single registration via plain CreateHotstring (no auto-folding) —
		; only the literal lowercase form is matched in practice.
		_AddTriggerToIndex(Trigger, Output, Category, Section, Individual, IndexTarget, SetTarget, SourceDefault)
		return
	}
	LowerTrig := StrLower(Trigger)
	TitleTrig := StrTitle(Trigger)
	UpperTrig := StrUpper(Trigger)
	_AddTriggerToIndex(LowerTrig, StrLower(Output), Category, Section, Individual, IndexTarget, SetTarget, SourceDefault)
	_AddTriggerToIndex(TitleTrig, StrTitle(Output), Category, Section, Individual, IndexTarget, SetTarget, SourceDefault)
	MagicSuffix := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey"))
		? ScriptInformation["MagicKey"] : "★"
	BodyLen := StrLen(RTrim(Trigger, MagicSuffix))
	if (BodyLen != 1) {
		_AddTriggerToIndex(UpperTrig, StrUpper(Output), Category, Section, Individual, IndexTarget, SetTarget, SourceDefault)
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
_AddTriggerToIndex(Trigger, Output, Category, Section, Individual := "", IndexTarget := "", SetTarget := "", SourceDefault := "") {
	global _PrefixIndex, _TriggerSet, _MIN_PREFIX_LEN, ScriptInformation, HSE_PRIORITY_COMMON
	; Default to the live globals so existing direct callers (and the test
	; suite) keep populating _PrefixIndex / _TriggerSet exactly as before.
	if !IsObject(IndexTarget)
		IndexTarget := _PrefixIndex
	if !IsObject(SetTarget)
		SetTarget := _TriggerSet

	MagicKey := (IsSet(ScriptInformation) and ScriptInformation.Has("MagicKey"))
		? ScriptInformation["MagicKey"] : "★"
	MkLen := StrLen(MagicKey)
	Len := StrLen(Trigger)
	HasMagic := (MkLen > 0 and Len > MkLen and SubStr(Trigger, -MkLen) == MagicKey)

	; Resolve the collision priority exactly as the engine registers it: an
	; individual `priority = N` wins, otherwise the section/file/source override
	; cascade via HotstringsResolve. Stored on the entry so _LookupAndRender can
	; rank colliding candidates so the non-dimmed preview = the engine's fire winner.
	;
	; SourceDefault is set only by the extension-pack caller, and it BYPASSES the
	; override cascade on purpose, because the engine does too: LoadExtTomlFile
	; applies _ParseEntryPriority(Line, HSE_PRIORITY_PACKAGE) — an individual
	; `priority = N`, else the package default — and never consults
	; HotstringsResolve, because a pack is not in the hotstrings config and has no
	; section or category override to find.
	;
	; Asking the cascade anyway is what broke this: HotstringsResolve ends in
	; _HSE_SourcePriority(CategoryName), whose package branch tests for an "ext."
	; prefix that nothing in the driver ever produces, so a pack's LABEL fell
	; through to HSE_PRIORITY_COMMON. A pack trigger colliding with a bundled one
	; was previewed as the loser and fired as the winner: the tooltip named one
	; expansion and the user got another (ext-pack-preview-ranked-below-its-fire).
	if (Individual != "") {
		Priority := Individual
	} else if (SourceDefault != "") {
		Priority := SourceDefault
	} else {
		Resolved := HotstringsResolve(Category, Section)
		Priority := (Resolved.HasOwnProp("Priority") and Resolved.Priority != "")
			? Resolved.Priority
			: HSE_PRIORITY_COMMON
	}

	Entry := { Trigger:  Trigger,
	           Output:   Output,
	           Category: Category,
	           Section:  Section,
	           Length:   Len,
	           Priority: Priority }

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
	if (!IndexTarget.Has(Prefix) or Type(IndexTarget[Prefix]) != "Array") {
		IndexTarget[Prefix] := []
	}
	IndexTarget[Prefix].Push(Entry)
	; Register exact trigger in the flat set for near-miss lookups
	SetTarget[StrLower(Trigger)] := Entry
}
