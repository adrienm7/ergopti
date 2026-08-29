; infra/hotstrings/hotstrings_cache.ahk

; ==============================================================================
; MODULE: Hotstrings Self-Healing Cache
; DESCRIPTION:
; Replaces the committed ``generated_*.ahk`` bundle (~1 MB of AHK tokenised at
; boot, BEFORE the tray icon can appear) with a gitignored, self-healing flat
; ``.tsv`` data cache — the exact same pattern the i18n layer uses for locales.
;
; FEATURES & RATIONALE:
; 1. No generated CODE in the repo: the bundled-category hotstrings (distances,
;    SFBs, rolls, autocorrection, magic-key) are no longer emitted as AHK source.
;    The TOML files under ``_shared/modules/hotstrings/`` stay the single source of truth.
; 2. Faster time-to-icon: AHK no longer parses ~1 MB of generated source during
;    the load phase that precedes tray-icon creation. The cache is DATA read at
;    registration time (after the icon), not code parsed before it.
; 3. Self-healing: on boot the ``.tsv`` is used when it exists AND is at least as
;    new as every bundled TOML; otherwise it is rebuilt from the TOML (the slow
;    path runs once, on first launch or after a TOML edit) and rewritten so the
;    NEXT boot is fast — exactly mirroring _I18nLoadLocaleMap.
; 4. Behaviour-preserving: rows carry the identical fields the old generated
;    loaders fed to CreateHotstring / CreateCaseSensitiveHotstrings, and the
;    registrar reproduces _GenRegisterRows 1:1 (magic-key ★ substituted at
;    register time, OnlyText wiring, the case-sensitive call selection). It plugs
;    into the SAME _GENERATED_HOTSTRINGS fast-path LoadHotstringsSection already
;    consults, so callers need no change.
; ==============================================================================





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Bundled categories compiled into the cache. "personal" is excluded — its TOML
; can live outside the repo and always loads through the runtime TOML parser.
global HS_BUNDLED_CATEGORIES := ["distancesreduction", "sfbsreduction", "rolls", "autocorrection", "magickey"]

; Literal magic-key marker stored in cached triggers; substituted with the user's
; ScriptInformation["MagicKey"] at register time so the cache is MagicKey-agnostic.
global HS_CACHE_MARKER := "★"

; cat.sec → BoundFunc(_HsCacheRegisterSection, key). This IS the fast-path map
; LoadHotstringsSection consults; populating it keeps that call site unchanged.
global _GENERATED_HOTSTRINGS := Map()

; cat.sec → Array of rows; each row is [flags, trigger, output, finalResult,
; isRepeat, isCaseSens, priorityOverride]. priorityOverride is the per-entry
; `priority = N` value or "" (no override). Populated once from the .tsv (or a
; TOML rebuild).
global _HS_CACHE_ROWS := Map()

; True once the cache has been loaded (or rebuilt) this session — the ensure
; guard short-circuits on every subsequent call so it is paid at most once.
global _HS_CACHE_LOADED := false





; ======================================
; ======================================
; ======= 2/ Paths and freshness =======
; ======================================
; ======================================

; Absolute path to the gitignored flat cache, beside the source TOML files so a
; read-only install (compiled bundle) and a dev checkout resolve it identically.
_HotstringsCacheTsvPath() {
	global _SharedDir
	return _SharedDir . "\modules\hotstrings\generated_hotstrings.tsv"
}

; Absolute path to one bundled category's source TOML.
_HotstringsCacheTomlPath(Category) {
	global _SharedDir
	return _SharedDir . "\modules\hotstrings\" . Category . ".toml"
}

; True when the .tsv is STRICTLY newer than EVERY bundled TOML — i.e. not stale
; after a TOML edit or pull. FileGetTime "M" is YYYYMMDDHH24MISS, ordering
; chronologically as a plain integer. The comparison is `>=` (a TOML whose mtime
; equals the .tsv's is treated as stale): mtime is second-granular and a rebuild
; writes the .tsv in the SAME wall-clock second it read the TOMLs, so a TOML
; re-saved within that second would otherwise tie and be served stale until the
; next boot. Equal-second ties rebuild — the safe direction (one extra rebuild on
; the rare tie, never a silently ignored edit). Any stat failure returns false so
; the caller rebuilds defensively (mirrors _I18nTsvIsFresh).
_HotstringsCacheIsFresh(TsvPath) {
	global HS_BUNDLED_CATEGORIES
	try {
		TsvTime := FileGetTime(TsvPath, "M")
		for Category in HS_BUNDLED_CATEGORIES {
			TomlPath := _HotstringsCacheTomlPath(Category)
			if FileExist(TomlPath) and FileGetTime(TomlPath, "M") >= TsvTime
				return false
		}
		return true
	} catch {
		return false
	}
}





; =====================================
; =====================================
; ======= 3/ TSV value escaping =======
; =====================================
; =====================================

; Escape a trigger/output value for one TAB-delimited cache field. Backslash is
; escaped FIRST so it can never collide with the \t/\r/\n sequences; the literal
; tab escape (\t) is what lets a value safely contain a tab without breaking the
; column split. ★ is preserved (the reader substitutes the MagicKey).
_HsCacheEscape(Value) {
	Esc := Value
	if InStr(Esc, "\")
		Esc := StrReplace(Esc, "\", "\\")
	if InStr(Esc, "`t")
		Esc := StrReplace(Esc, "`t", "\t")
	if InStr(Esc, "`r")
		Esc := StrReplace(Esc, "`r", "\r")
	if InStr(Esc, "`n")
		Esc := StrReplace(Esc, "`n", "\n")
	return Esc
}

; Invert _HsCacheEscape in a single left-to-right scan so "\\" never collides with
; "\t"/"\r"/"\n". Only called for values that contain a backslash, so the common
; case pays nothing (mirrors _I18nUnescapeTSV).
_HsCacheUnescape(Value) {
	if !InStr(Value, "\")
		return Value
	Out := ""
	I := 1
	Len := StrLen(Value)
	while (I <= Len) {
		C := SubStr(Value, I, 1)
		if (C == "\" and I < Len) {
			N := SubStr(Value, I + 1, 1)
			if (N == "n") {
				Out .= "`n"
				I += 2
				continue
			}
			if (N == "r") {
				Out .= "`r"
				I += 2
				continue
			}
			if (N == "t") {
				Out .= "`t"
				I += 2
				continue
			}
			if (N == "\") {
				Out .= "\"
				I += 2
				continue
			}
		}
		Out .= C
		I += 1
	}
	return Out
}





; ===========================================
; ===========================================
; ======= 4/ Build rows from the TOML =======
; ===========================================
; ===========================================

; Parse every bundled category TOML into a Map(cat.sec → Array of rows), using the
; SAME line-based scan + _HOTSTRING_ENTRY_PATTERN as the runtime LoadHotstringsSection
; fallback, so the cache reproduces that reference behaviour exactly. Each row is
; [flags, trigger(raw, ★ preserved), output, finalResult, isRepeat, isCaseSens,
; priorityOverride]. Runs only on a cache miss (first launch or after a TOML edit).
_HotstringsCacheBuildRows() {
	global HS_BUNDLED_CATEGORIES, HS_CACHE_MARKER, _HOTSTRING_ENTRY_PATTERN
	Rows := Map()
	for Category in HS_BUNDLED_CATEGORIES {
		TomlPath := _HotstringsCacheTomlPath(Category)
		if !FileExist(TomlPath)
			continue
		CategoryLower := StrLower(Category)
		CurrentSection := ""
		loop parse, FileRead(TomlPath, "UTF-8"), "`n", "`r" {
			Line := Trim(A_LoopField, " `t")
			if (Line == "" or SubStr(Line, 1, 1) == "#")
				continue
			; Strip the trailing comment before the anchored header match. TOML
			; allows `[[ct]] # note`, and the raw line cannot match `…\]+$`, so
			; the header used to fall through to the entry parser, fail that too
			; and `continue` — leaving CurrentSection on the PREVIOUS section, so
			; every entry under the commented header was cached against the wrong
			; section (or dropped when it was the first). The runtime loaders this
			; scan claims to reproduce exactly already strip (toml_loader.ahk).
			if RegExMatch(TOML_StripInlineComment(Line), "^\[+([^\[\]]+)\]+$", &SectionMatch) {
				CurrentSection := StrLower(Trim(SectionMatch[1]))
				continue
			}
			; Skip the metadata blocks — they never carry hotstring entries.
			if (CurrentSection == "" or CurrentSection == "_meta" or InStr(CurrentSection, "_meta."))
				continue
			if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match)
				continue

			Trigger := UnescapeTomlString(Match[1])
			Output := UnescapeTomlString(Match[2])
			IsWord := (Match[3] == "true")
			AutoExpand := (Match[4] == "true")
			IsCaseSens := (Match[5] == "true")
			FinalResult := (Match[6] == "true")
			StrictCase := (Match[7] == "true")

			Flags := ""
			if AutoExpand
				Flags .= "*"
			if !IsWord
				Flags .= "?"
			if StrictCase
				Flags .= "C"

			; IsRepeat is owned end-to-end by the engine-level repeat fallback
			; (HSE_TryRepeatKey, hotstring_engine_main.ahk), so the runtime TOML
			; fallback LoadHotstringsSection does NOT set it. The cache and that
			; fallback MUST use byte-identical IsRepeat logic to register the same
			; TOML the same way, so the cache stores it false unconditionally too.
			; (The old per-row test matched a snake_case-renamed section literal that
			; no longer matched the [[repeat_corrections]] header, so it never fired.)
			IsRepeat := false

			; Individual per-hotstring priority override (the top of the cascade
			; individual > section > file > source). Empty when the entry carries no
			; `priority = N` key — the registrar then applies the resolved section/
			; source priority it receives, reproducing the TOML fallback's
			; _ParseEntryPriority(Line, ResolvedPriority) cascade 1:1.
			PriorityOverride := _ParseEntryPriority(Line, "")

			Key := CategoryLower . "." . CurrentSection
			if !Rows.Has(Key)
				Rows[Key] := []
			Rows[Key].Push([Flags, Trigger, Output, FinalResult, IsRepeat, IsCaseSens, PriorityOverride])
		}
	}
	return Rows
}





; ===================================================
; ===================================================
; ======= 5/ TSV read / write (the cache I/O) =======
; ===================================================
; ===================================================

; Serialise a Map(cat.sec → rows) to the flat .tsv. One record per hotstring:
; cat<TAB>sec<TAB>flags<TAB>trigger<TAB>output<TAB>final<TAB>repeat<TAB>caseSens<TAB>priority.
; Trigger/output are escaped (see _HsCacheEscape); ★ is preserved; bools are 1/0;
; the priority column is the per-entry override (a small int) or empty when none;
; LF endings, UTF-8 without BOM. Best-effort: a read-only directory simply means
; every boot keeps rebuilding from the TOML (mirrors _I18nWriteTsvCache).
_HotstringsCacheWriteTsv(TsvPath, Rows) {
	try {
		Content := ""
		for Key, RowList in Rows {
			Parts := StrSplit(Key, ".",, 2)
			Category := Parts[1]
			Section := Parts.Length >= 2 ? Parts[2] : ""
			for Row in RowList {
				Line := Category . "`t" . Section . "`t" . Row[1] . "`t"
				Line .= _HsCacheEscape(Row[2]) . "`t" . _HsCacheEscape(Row[3]) . "`t"
				Line .= (Row[4] ? "1" : "0") . "`t" . (Row[5] ? "1" : "0") . "`t"
				Line .= (Row[6] ? "1" : "0") . "`t" . (Row.Length >= 7 ? Row[7] : "") . "`n"
				Content .= Line
			}
		}
		; Write to a temp file and rename atomically — FileDelete+FileAppend is
		; a two-step operation that leaves the cache empty between the two calls
		; if the script crashes or another instance starts at that instant
		; (hotstrings-cache-non-atomic-write fix).
		TmpPath := TsvPath . ".tmp"
		if FileExist(TmpPath)
			FileDelete(TmpPath)
		FileAppend(Content, TmpPath, "UTF-8-RAW")
		FileMove(TmpPath, TsvPath, 1)
	} catch as err {
		try LoggerWarn("Hotstrings", "Could not write hotstring cache '{1}' ({2}); TOML path stays active.", TsvPath, err.Message)
	}
}

; Parse a flat .tsv back into a Map(cat.sec → Array of rows). Lines with fewer
; than the 9 expected columns are skipped defensively. The 9-column requirement
; also bumps the cache format: an old 8-column .tsv yields zero rows here, so
; HotstringsCacheEnsure rebuilds it from the TOML (picking up the new priority
; column) instead of serving a priority-less cache. Only trigger/output are
; unescaped; cat/sec/flags/priority are identifier-safe and stored raw. An empty
; priority column means "no per-entry override" — the registrar then applies the
; resolved section/source priority it receives.
_HotstringsCacheReadTsv(Content) {
	Rows := Map()
	loop parse, Content, "`n", "`r" {
		Line := A_LoopField
		if (Line == "")
			continue
		Fields := StrSplit(Line, "`t")
		if Fields.Length < 9
			continue
		Priority := ""
		if (Fields[9] != "" and (!RegExMatch(Fields[9], "^\d+$")
			or !TOML_TryParseInteger(Fields[9], &Priority)))
			throw ValueError("Hotstring cache contains an invalid priority literal.")
		Key := Fields[1] . "." . Fields[2]
		Row := [Fields[3], _HsCacheUnescape(Fields[4]), _HsCacheUnescape(Fields[5]), (Fields[6] == "1"), (Fields[7] == "1"), (Fields[8] == "1"), Priority]
		if !Rows.Has(Key)
			Rows[Key] := []
		Rows[Key].Push(Row)
	}
	return Rows
}





; =================================================
; =================================================
; ======= 6/ Ensure + register (public API) =======
; =================================================
; =================================================

; Load the hotstring cache exactly once: read the fresh .tsv, else rebuild from
; the TOML and rewrite the .tsv for next boot. Populates _GENERATED_HOTSTRINGS so
; LoadHotstringsSection's existing fast path resolves every cached section to the
; shared registrar. Idempotent and cheap after the first call.
HotstringsCacheEnsure() {
	global _HS_CACHE_LOADED, _HS_CACHE_ROWS, _GENERATED_HOTSTRINGS, _SharedDir
	if _HS_CACHE_LOADED
		return
	; Cannot resolve the source/cache paths without _SharedDir (set at boot in
	; ErgoptiPlus.ahk). Bail without marking loaded so a later call can succeed —
	; callers then fall through to the runtime TOML path. Relevant only to harnesses
	; that invoke LoadHotstringsSection before _SharedDir exists.
	if !IsSet(_SharedDir)
		return
	TsvPath := _HotstringsCacheTsvPath()
	Rows := ""
	Fast := false
	if FileExist(TsvPath) and _HotstringsCacheIsFresh(TsvPath) {
		try {
			Rows := _HotstringsCacheReadTsv(FileRead(TsvPath, "UTF-8"))
			Fast := true
		} catch as err {
			try LoggerWarn("Hotstrings", "Hotstring cache '{1}' unreadable ({2}); rebuilding from TOML.", TsvPath, err.Message)
			Rows := ""
		}
	}
	if !(Rows is Map) or Rows.Count == 0 {
		Rows := _HotstringsCacheBuildRows()
		_HotstringsCacheWriteTsv(TsvPath, Rows)
		Fast := false
	}
	_HS_CACHE_ROWS := Rows
	for Key, _RowList in Rows
		_GENERATED_HOTSTRINGS[Key] := _HsCacheRegisterSection.Bind(Key)
	_HS_CACHE_LOADED := true
	try LoggerDone("Hotstrings", "Hotstring cache ready ({1} section(s), {2}).",
		Rows.Count, Fast ? "fast" : "rebuilt")
}

; Register every cached hotstring of one section. Reproduces the runtime TOML
; fallback (LoadHotstringsSection) 1:1: per-row opts (TimeActivationSeconds from
; FeatureConfig, FinalResult, IsRepeat, Category, Section, Priority, optional
; OnlyText), ★ substituted at register time, and the CreateHotstring vs
; CreateCaseSensitiveHotstrings choice. ResolvedPriority is the section/file/source
; priority the caller already resolved (HotstringsResolve cascade); a per-row
; priority override beats it, exactly as _ParseEntryPriority(Line, ResolvedPriority)
; does on the TOML path. Bound by key into _GENERATED_HOTSTRINGS and invoked from
; LoadHotstringsSection.
_HsCacheRegisterSection(LoaderKey, FeatureConfig, ExtraOptions, ResolvedPriority := "") {
	global _HS_CACHE_ROWS, ScriptInformation, HS_CACHE_MARKER, HSE_PRIORITY_COMMON
	if !_HS_CACHE_ROWS.Has(LoaderKey)
		return
	RowList := _HS_CACHE_ROWS[LoaderKey]
	Parts := StrSplit(LoaderKey, ".",, 2)
	Category := Parts[1]
	Section := Parts.Length >= 2 ? Parts[2] : ""
	TimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
	MagicKey := ScriptInformation["MagicKey"]
	HasExtras := IsSet(ExtraOptions) and (ExtraOptions is Map)
	; The section/file/source-resolved priority the caller passes is the cascade
	; fallback applied to any entry without its own `priority = N`. When the caller
	; omits it (older call sites) fall back to the common default so an entry never
	; registers with an empty priority.
	BasePriority := (ResolvedPriority != "") ? ResolvedPriority : HSE_PRIORITY_COMMON
	for Row in RowList {
		EntryPriority := (Row.Length >= 7 and Row[7] != "") ? Row[7] : BasePriority
		; Start from the caller's options and let the per-row values win, rather
		; than naming the one key worth forwarding. The enumerated version copied
		; OnlyText and nothing else, so IsPrivate — an option whose whole job is to
		; keep an IBAN out of a 14-day log — would have been dropped silently by
		; any section that ever round-tripped through the cache. Nothing routes the
		; @ family through here today, which is precisely why the omission would
		; have been found late; copying wholesale means the next option added
		; cannot repeat it.
		Opts := HasExtras ? ExtraOptions.Clone() : Map()
		Opts["TimeActivationSeconds"] := TimeAct
		Opts["FinalResult"] := Row[4]
		Opts["IsRepeat"] := Row[5]
		Opts["Category"] := Category
		Opts["Section"] := Section
		Opts["Priority"] := EntryPriority
		Trigger := StrReplace(Row[2], HS_CACHE_MARKER, MagicKey)
		; The REPLACEMENT carries the marker too, and the preview index already
		; substitutes it on both sides (hotstring_registry). Substituting only the
		; trigger here meant a replacement containing the marker was previewed with
		; the user's magic key and then EMITTED with a literal star — the tooltip
		; promising one string and the engine typing another.
		Output := StrReplace(Row[3], HS_CACHE_MARKER, MagicKey)
		HSE_RegisterFromTomlFlags(Row[6], Row[1], Trigger, Output, Opts)
	}
}
