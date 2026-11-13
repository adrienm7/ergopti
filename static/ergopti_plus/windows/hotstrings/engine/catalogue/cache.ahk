; hotstrings/engine/catalogue/cache.ahk

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
;    The TOML files under ``_shared/hotstrings/data/catalogue/`` stay the single source of truth.
; 2. Faster time-to-icon: AHK no longer parses ~1 MB of generated source during
;    the load phase that precedes tray-icon creation. The cache is DATA read at
;    registration time (after the icon), not code parsed before it.
; 3. Self-healing: on boot the ``.tsv`` is used only when its captured source
;    inventory still matches native reads; otherwise it is rebuilt (the slow
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

; Common categories are populated from the shared index by the cache owner.
; Extension and personal files always use their native runtime TOML owners.
global HS_BUNDLED_CATEGORIES := []

; Language-pack gate name (PascalCase, e.g. "FrenchAutocorrection") → the
; category_enabled key it persists under (its group id). Filled by
; HotstringsSeedLanguageCategoryGates at boot; empty until then.
global HS_LANGUAGE_GATE_KEYS := Map()

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

; The file a layout extension supplies for a bundled category, or for one of its
; sections: the whole-category file answers for every section, a section
; binding only for its own sections. "" when the bundled file applies. The
; routes are committed once per boot by HotstringExtensions_Prepare
; (extension_packs.ahk); spellings fold like HotstringsBundledTomlPath's.
HotstringsBoundTomlPath(Category, Section := "") {
	global _HotstringBoundSources
	if !IsSet(_HotstringBoundSources) || !(_HotstringBoundSources is Map)
		return ""
	Key := StrLower(StrReplace(Category, "_"))
	if !_HotstringBoundSources.Has(Key)
		return ""
	Route := _HotstringBoundSources[Key]
	if (Route["path"] != "")
		return Route["path"]
	Wanted := StrLower(Section)
	return (Wanted != "" && Route["sections"].Has(Wanted)) ? Route["sections"][Wanted] : ""
}

; The sections of a bundled category that a layout extension supplies from its
; own file, as Map(lowercase section → file); empty when none is bound.
HotstringsBoundSections(Category) {
	global _HotstringBoundSources
	if !IsSet(_HotstringBoundSources) || !(_HotstringBoundSources is Map)
		return Map()
	Key := StrLower(StrReplace(Category, "_"))
	return _HotstringBoundSources.Has(Key) ? _HotstringBoundSources[Key]["sections"] : Map()
}

; Absolute path to the gitignored flat cache, beside the source TOML files so a
; read-only install (compiled bundle) and a dev checkout resolve it identically.
_HotstringsCacheTsvPath() {
	global _SharedDir
	return _SharedDir . "\hotstrings\data\catalogue\generated_hotstrings.tsv"
}

; Absolute path to one bundled category's source TOML.
_HotstringsCacheTomlPath(Category) {
	return _HotstringsPhysicalBundledTomlPath(Category)
}

; Language packs declared by _shared/hotstrings/data/catalogue/_index.toml [languages],
; in declared order. Each item is Map("id", folder, "locale", locale code,
; "categories", Array of file stems). The index is the only place a language is
; declared, so adding one is data: its folder, its [languages.<id>] table and its
; manifest rows. Parsed once per canonical index image; an index that declares a language
; without a locale or categories is a broken install and throws.
; Preserve the exact canonical memo image actually consumed by both scanners.
; A later physical read may verify this receipt, but cannot replace its content.
_HotstringsIndexSource() {
	global _SharedDir
	Path := _SharedDir . "\hotstrings\data\catalogue\_index.toml"
	Content := ReadTomlFile(Path)
	if Content == ""
		throw Error("Hotstring index is unreadable: " . Path)
	return {path: Path, content: Content}
}

HotstringsLanguagePacks() {
	return _HotstringsLanguagePacksFrom(_HotstringsIndexSource())
}

_HotstringsCloneLanguagePacks(Packs) {
	Result := []
	for Pack in Packs
		Result.Push(Map("id", Pack["id"], "locale", Pack["locale"], "categories", Pack["categories"].Clone()))
	return Result
}

_HotstringsLanguagePacksFrom(Source) {
	static MemoPath := "", MemoContent := "", Packs := ""
	IndexPath := Source.path, Content := Source.content
	if Packs is Array && StrCompare(MemoPath, IndexPath, true) == 0
		&& StrCompare(MemoContent, Content, true) == 0
		return _HotstringsCloneLanguagePacks(Packs)
	Order := []
	ById := Map()
	Table := ""
	loop parse, Content, "`n", "`r" {
		Line := Trim(TOML_StripInlineComment(Trim(A_LoopField, " `t")), " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#")
			continue
		if RegExMatch(Line, "^\[([A-Za-z0-9_.]+)\]$", &Head) {
			Table := Head[1]
			continue
		}
		if (Table == "languages" and RegExMatch(Line, "^order\s*=\s*\[(.*)\]$", &M)) {
			Order := _HotstringsIndexStringArray(M[1])
			continue
		}
		if !RegExMatch(Table, "^languages\.([A-Za-z0-9_]+)$", &LangM)
			continue
		Id := LangM[1]
		if !ById.Has(Id)
			ById[Id] := Map("id", Id, "locale", "", "categories", [])
		if RegExMatch(Line, '^locale\s*=\s*"([^"]+)"$', &Loc)
			ById[Id]["locale"] := Loc[1]
		else if RegExMatch(Line, "^categories_order\s*=\s*\[(.*)\]$", &Cats)
			ById[Id]["categories"] := _HotstringsIndexStringArray(Cats[1])
	}
	Result := []
	for _, Id in Order {
		if !ById.Has(Id) or ById[Id]["locale"] == "" or ById[Id]["categories"].Length == 0
			throw Error("Hotstring index declares language '" . Id . "' without a locale or categories: " . IndexPath)
		Result.Push(ById[Id])
	}
	Packs := Result, MemoPath := IndexPath, MemoContent := Content
	return _HotstringsCloneLanguagePacks(Packs)
}

; Split the inside of a one-line TOML string array ("a", "b") into an Array.
_HotstringsIndexStringArray(Inner) {
	Out := []
	loop parse, Inner, "," {
		Token := Trim(A_LoopField, " `t" . Chr(34))
		if (Token != "")
			Out.Push(Token)
	}
	return Out
}

; The group id of one language pack's category file: "<language>_<stem>", the
; same key the feature manifest, config.toml and the cache use.
HotstringsLanguageGroupId(Language, Stem) {
	return Language . "_" . Stem
}

; True when ``Group`` is the id of a language pack's category file.
HotstringsIsLanguageGroup(Group) {
	for _, Pack in HotstringsLanguagePacks() {
		for _, Stem in Pack["categories"] {
			if (Group == HotstringsLanguageGroupId(Pack["id"], Stem))
				return true
		}
	}
	return false
}

; Every bundled category a cache or catalogue must cover: the neutral root files
; followed by each language pack's categories, as group ids.
HotstringsCommonCategories() {
	return _HotstringsCommonCategoriesFrom(_HotstringsIndexSource())
}

_HotstringsCommonCategoriesFrom(Source) {
	global HS_BUNDLED_CATEGORIES
	IndexPath := Source.path, Content := Source.content
	Table := ""
	loop parse, Content, "`n", "`r" {
		Line := Trim(TOML_StripInlineComment(Trim(A_LoopField, " `t")), " `t")
		if RegExMatch(Line, "^\[([A-Za-z0-9_.]+)\]$", &Head)
			Table := Head[1]
		else if Table == "menu" && RegExMatch(Line, "^categories_order\s*=\s*\[(.*)\]$", &Order) {
			HS_BUNDLED_CATEGORIES := _HotstringsIndexStringArray(Order[1])
			if HS_BUNDLED_CATEGORIES.Length
				return HS_BUNDLED_CATEGORIES.Clone()
		}
	}
	throw Error("Hotstring index has no common category order: " . IndexPath)
}

HotstringsBundledCategories() {
	Source := _HotstringsIndexSource()
	All := _HotstringsCommonCategoriesFrom(Source)
	for _, Pack in _HotstringsLanguagePacksFrom(Source) {
		for _, Stem in Pack["categories"]
			All.Push(HotstringsLanguageGroupId(Pack["id"], Stem))
	}
	return All
}

; The language packs as the tray menu and the category gates see them: each
; pack's categories carry their v2 group id and the PascalCase gate name the
; manifest's hotstring_category_keys assigns to it. A language category the
; manifest does not name has no gate, no config rows and no menu entry, so it is
; refused at the first read instead of rendering as a dead row.
HotstringsLanguageCategories() {
	static Cache := ""
	if (Cache is Array)
		return Cache
	GateByGroup := Map()
	for GateName, FeatureGroup in _MG_LoadSubCategories()
		GateByGroup[FeatureGroup] := GateName
	Result := []
	for _, Pack in HotstringsLanguagePacks() {
		Cats := []
		for _, Stem in Pack["categories"] {
			Group := HotstringsLanguageGroupId(Pack["id"], Stem)
			if !GateByGroup.Has(Group)
				throw Error("Language category '" . Group . "' has no hotstring_category_keys entry in the menu manifest.")
			Cats.Push(Map("v1", GateByGroup[Group], "v2", Group))
		}
		Result.Push(Map("id", Pack["id"], "locale", Pack["locale"], "categories", Cats))
	}
	Cache := Result
	return Cache
}

; Give declared native and language categories their own gates in ``GateTarget`` (the
; CategoryEnabled Map), using the declared neutral default. Called once at boot
; before the gates are read from config.toml; a gate already present is kept.
HotstringsSeedLanguageCategoryGates(GateTarget) {
	global HS_LANGUAGE_GATE_KEYS
	if !(GateTarget is Map)
		throw Error("HotstringsSeedLanguageCategoryGates requires the category gate Map.")
	Groups := MenuManifest_LoadHotstringGroups(), CategoryGroups := _MG_LoadSubCategories()
	for Categories in [Groups.standard, Groups.ergopti] {
		for Category in Categories {
			Group := CategoryGroups[Category]
			HS_LANGUAGE_GATE_KEYS[Category] := Group
			if !GateTarget.Has(Category)
				GateTarget[Category] := ManifestDefaultFor("category_enabled." . Group)
		}
	}
	for _, Pack in HotstringsLanguageCategories() {
		for _, Cat in Pack["categories"] {
			HS_LANGUAGE_GATE_KEYS[Cat["v1"]] := Cat["v2"]
			if !GateTarget.Has(Cat["v1"])
				GateTarget[Cat["v1"]] := ManifestDefaultFor("category_enabled." . Cat["v2"])
		}
	}
}

; Native display name of a language pack's locale, from the generated locale
; table (itself built from _shared/core/i18n/data/locale_names.json). A pack naming a
; locale the table lacks is a broken index, not a row to label with a raw code.
HotstringsLanguageName(Locale) {
	for _, Row in LocaleTableData() {
		if (Row.Code == Locale)
			return Row.Name
	}
	throw Error("Hotstring language pack names unknown locale '" . Locale . "'.")
}

; Absolute path to the TOML that backs a bundled category. A language group
; ("french_autocorrection", or the menu's "FrenchAutocorrection") lives in its
; language folder; every other category is a root file named by its lowercased
; id. Underscores and case are ignored when matching so the file-stem, config and
; menu spellings of one group resolve to the same file.
HotstringsBundledTomlPath(Category) {
	if IsSet(PersonalFileControls) {
		Adopted := PersonalFileControls.Path(Category)
		if Adopted != ""
			return Adopted
	}
	global _SharedDir
	; A category a layout extension binds whole loads from the extension's file.
	Bound := HotstringsBoundTomlPath(Category)
	if (Bound != "")
		return Bound
	return _HotstringsPhysicalBundledTomlPath(Category)
}

; Physical bundled sources are independent of current extension/adopted routes.
_HotstringsPhysicalBundledTomlPath(Category, IndexSource := 0) {
	global _SharedDir
	Source := IndexSource is Object ? IndexSource : _HotstringsIndexSource()
	Wanted := StrLower(StrReplace(Category, "_"))
	for _, Pack in _HotstringsLanguagePacksFrom(Source) {
		for _, Stem in Pack["categories"] {
			if (Wanted == StrLower(Pack["id"] . StrReplace(Stem, "_")))
				return _SharedDir . "\hotstrings\data\catalogue\" . Pack["id"] . "\" . Stem . ".toml"
		}
	}
	return _SharedDir . "\hotstrings\data\catalogue\" . StrLower(Category) . ".toml"
}

; Derive the full physical inventory from one canonical index input. Every
; category and its route belongs to that same generation, including absences.
_HotstringsCacheSourcePaths(Source) {
	Paths := Map()
	for Category in _HotstringsCommonCategoriesFrom(Source)
		Paths[StrLower(Category)] := _HotstringsPhysicalBundledTomlPath(Category, Source)
	for Pack in _HotstringsLanguagePacksFrom(Source)
		for Stem in Pack["categories"] {
			Category := StrLower(HotstringsLanguageGroupId(Pack["id"], Stem))
			if Paths.Has(Category)
				throw Error("Hotstring source categories overlap.")
			Paths[Category] := _HotstringsPhysicalBundledTomlPath(Category, Source)
		}
	return Paths
}

_HotstringsCachePathKey(Path) {
	return StrLower(StrReplace(Path, "/", "\"))
}

; Only the candidate actually parsed for loading may lend its receipt. Fresh
; native reads verify it; the canonical memo never pretends to be a fresh read.
_HotstringsCacheInventoryMatches(Rows, RequireTerminalReceipt := true) {
	try {
		if !(Rows is Map) || !Rows.HasOwnProp("SourceIndex") || !Rows.HasOwnProp("SourceInventory")
			return false
		if RequireTerminalReceipt && (!Rows.HasOwnProp("SourceReceiptComplete") || !Rows.SourceReceiptComplete)
			return false
		Source := _HotstringsIndexSource()
		Index := Rows.SourceIndex
		if !RegExMatch(Index.hash, "^[0-9a-f]{64}$")
			return false
		if _HotstringsCachePathKey(Index.path) != _HotstringsCachePathKey(Source.path)
			|| CryptoSha256(Source.content) != Index.hash
			|| CryptoSha256(FileRead(Source.path, "UTF-8")) != Index.hash
			return false
		Paths := _HotstringsCacheSourcePaths(Source)
		if Rows.SourceInventory.Length != Paths.Count
			return false
		Position := 0
		for Category, Path in Paths {
			Receipt := Rows.SourceInventory[++Position]
			if StrCompare(Category, Receipt.category, true) != 0
				|| _HotstringsCachePathKey(Path) != _HotstringsCachePathKey(Receipt.path)
				return false
			Present := FSStrictExists(Path) ? 1 : 0
			if Present != Receipt.present
				return false
			if !(Receipt.present is Integer) || (Receipt.present != 0 && Receipt.present != 1)
				|| (Present ? !RegExMatch(Receipt.hash, "^[0-9a-f]{64}$") : Receipt.hash != "-")
				return false
			if Present && CryptoSha256(FileRead(Path, "UTF-8")) != Receipt.hash
				return false
		}
		return true
	} catch {
		return false
	}
}

; Compatibility wrapper for direct freshness callers. Ensure below parses once
; and validates the same Rows object it will publish, rather than reopening TSV.
_HotstringsCacheIsFresh(TsvPath) {
	try return _HotstringsCacheInventoryMatches(_HotstringsCacheReadTsv(FileRead(TsvPath, "UTF-8")))
	catch
		return false
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
; SourceOrder carries physical records separately; section rows retain their ABI.
; An explicit path map lets native tests exercise the same canonical parser.
_HotstringsCacheBuildRows(CategoryPaths := 0) {
	global HS_BUNDLED_CATEGORIES, HS_CACHE_MARKER, _HOTSTRING_ENTRY_PATTERN
	Rows := Map()
	Rows.SourceOrder := []
	Rows.SourceOrderVersion := true
	HasSourceReceipt := !(CategoryPaths is Map)
	if HasSourceReceipt {
		IndexSource := _HotstringsIndexSource()
		CategoryPaths := _HotstringsCacheSourcePaths(IndexSource)
		Rows.SourceIndex := {path: IndexSource.path, hash: CryptoSha256(IndexSource.content)}
		Rows.SourceInventory := []
	}
	for Category, TomlPath in CategoryPaths {
		Present := FSStrictExists(TomlPath) ? 1 : 0
		Content := Present ? FileRead(TomlPath, "UTF-8") : ""
		if HasSourceReceipt
			Rows.SourceInventory.Push({category: StrLower(Category), path: TomlPath,
				present: Present, hash: Present ? CryptoSha256(Content) : "-"})
		if !Present
			continue
		CategoryLower := StrLower(Category)
		CurrentSection := ""
		loop parse, Content, "`n", "`r" {
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
			; (HSE_TryRepeatKey, ../matcher/engine_main.ahk), so the runtime TOML
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
			Row := [Flags, Trigger, Output, FinalResult, IsRepeat, IsCaseSens, PriorityOverride]
			Rows[Key].Push(Row)
			Rows.SourceOrder.Push([Key, Row])
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
		PhysicalPath := FSResolveAbsolutePath(TsvPath)
		Content := "# source-order-v1`n"
		if !Rows.HasOwnProp("SourceOrder")
			throw Error("Hotstring cache source order is unavailable.")
		Records := Rows.SourceOrder
		for Record in Records {
			Parts := StrSplit(Record[1], ".",, 2)
			Category := Parts[1]
			Section := Parts.Length >= 2 ? Parts[2] : ""
			Row := Record[2]
			Line := Category . "`t" . Section . "`t" . Row[1] . "`t"
			Line .= _HsCacheEscape(Row[2]) . "`t" . _HsCacheEscape(Row[3]) . "`t"
			Line .= (Row[4] ? "1" : "0") . "`t" . (Row[5] ? "1" : "0") . "`t"
			Line .= (Row[6] ? "1" : "0") . "`t" . (Row.Length >= 7 ? Row[7] : "") . "`n"
			Content .= Line
		}
		; Receipt and rows are one verified atomic file. Never derive a new
		; receipt from current disk state for rows captured from an older input.
		if Rows.HasOwnProp("SourceIndex") && Rows.HasOwnProp("SourceInventory") {
			Index := Rows.SourceIndex
			if !RegExMatch(Index.hash, "^[0-9a-f]{64}$")
				throw Error("hotstring index receipt is unavailable")
			Content .= "# index-v1`t" . _HsCacheEscape(Index.path) . "`t" . Index.hash . "`n"
			for Receipt in Rows.SourceInventory {
				if !(Receipt.present is Integer) || (Receipt.present != 0 && Receipt.present != 1)
					|| (Receipt.present ? !RegExMatch(Receipt.hash, "^[0-9a-f]{64}$") : Receipt.hash != "-")
					throw Error("hotstring source receipt is unavailable")
				Content .= "# source-v1`t" . _HsCacheEscape(Receipt.category) . "`t"
					. _HsCacheEscape(Receipt.path) . "`t" . Receipt.present . "`t" . Receipt.hash . "`n"
			}
			Digest := CryptoSha256(Content)
			if !RegExMatch(Digest, "^[0-9a-f]{64}$")
				throw Error("hotstring cache receipt checksum is unavailable")
			Content .= "# receipt-v1`t" . Rows.SourceInventory.Length . "`t" . Records.Length . "`t" . Digest . "`n"
		}
		; The cache is best effort, but never borrows an existing sidecar.
		; Retain one exclusive native stage through readback, rename and cleanup.
		static WriteSeq := 0
		Suffix := "." . A_ScriptHwnd . "-" . (++WriteSeq) . ".tmp"
		Stage := {handle: -1}
		CreateStage(Folder, Name, Attributes) {
			Stage.handle := _FSCreateHeldStage(Folder, Name, Attributes)
			return Stage.handle
		}
		VerifyStage() {
			_FSRewind(Stage.handle)
			Readback := _FSReadUtf8ExactHandle(Stage.handle, 0, false)
			return (Readback is String) && Readback == Content
		}
		if !FSWriteReplaceOwned(PhysicalPath, Content, Suffix, &Detail,
				CreateStage, VerifyStage, 0, true, &Publication)
			throw Error("hotstring cache publication was not fully acknowledged: " . Detail)
	} catch as err {
		try LoggerWarn("Hotstrings", "Could not write hotstring cache '{1}' ({2}); TOML path stays active.", TsvPath, err.Message)
	}
}

; Parse a flat .tsv back into a Map(cat.sec → Array of rows). The exact
; source-order header fences older grouped caches; every complete record keeps
; the existing nine-column ABI. Missing headers or malformed tails reject the
; whole candidate, so ensure rebuilds from TOML instead of admitting a prefix.
; Only trigger/output are
; unescaped; cat/sec/flags/priority are identifier-safe and stored raw. An empty
; priority column means "no per-entry override" — the registrar then applies the
; resolved section/source priority it receives.
_HotstringsCacheReadTsv(Content) {
	Rows := Map()
	Rows.SourceOrder := []
	if StrCompare(SubStr(Content, 1, StrLen("# source-order-v1`n")), "# source-order-v1`n", true) != 0
		throw ValueError("Hotstring cache source-order header is invalid.")
	Rows.SourceOrderVersion := true
	Rows.SourceReceiptComplete := false
	Rows.SourceInventory := []
	SeenCategories := Map(), SeenPaths := Map()
	Payload := "# source-order-v1`n", HasIndex := false, HasFooter := false
	loop parse, Content, "`n", "`r" {
		Line := A_LoopField
		if A_Index == 1
			continue
		if HasFooter {
			if Line != ""
				throw ValueError("Hotstring cache receipt is not terminal.")
			continue
		}
		if Line == "" {
			Payload .= "`n"
			continue
		}
		Fields := StrSplit(Line, "`t")
		if Fields[1] == "# receipt-v1" {
			if Fields.Length != 4 || !HasIndex
				|| StrCompare(Fields[2], String(Rows.SourceInventory.Length), true) != 0
				|| StrCompare(Fields[3], String(Rows.SourceOrder.Length), true) != 0
				|| !RegExMatch(Fields[4], "^[0-9a-f]{64}$") || CryptoSha256(Payload) != Fields[4]
				throw ValueError("Hotstring cache source receipt is incomplete.")
			HasFooter := true
			Rows.SourceReceiptComplete := true
			continue
		}
		Payload .= Line . "`n"
		if Fields[1] == "# index-v1" {
			if Fields.Length != 3 || HasIndex || !RegExMatch(Fields[3], "^[0-9a-f]{64}$")
				throw ValueError("Hotstring cache index receipt is invalid.")
			Path := _HsCacheUnescape(Fields[2])
			if Path == "" || RegExMatch(Path, "\x00")
				throw ValueError("Hotstring cache index path is invalid.")
			Rows.SourceIndex := {path: Path, hash: Fields[3]}
			HasIndex := true
			continue
		}
		if Fields[1] == "# source-v1" {
			if Fields.Length != 5 || !HasIndex
				|| (Fields[4] !== "0" && Fields[4] !== "1")
				|| (Fields[4] == "1" ? !RegExMatch(Fields[5], "^[0-9a-f]{64}$") : Fields[5] != "-")
				throw ValueError("Hotstring cache source receipt is invalid.")
			Category := _HsCacheUnescape(Fields[2]), Path := _HsCacheUnescape(Fields[3])
			Key := _HotstringsCachePathKey(Path)
			if Category == "" || Path == "" || RegExMatch(Category . Path, "\x00")
				|| SeenCategories.Has(Category) || SeenPaths.Has(Key)
				throw ValueError("Hotstring cache source receipt is duplicated or empty.")
			SeenCategories[Category] := true, SeenPaths[Key] := true
			Rows.SourceInventory.Push({category: Category, path: Path, present: Integer(Fields[4]), hash: Fields[5]})
			continue
		}
		if HasIndex
			throw ValueError("Hotstring cache rules cannot follow their source inventory.")
		if Fields.Length != 9
			throw ValueError("Hotstring cache record has an invalid column count.")
		Priority := ""
		if (Fields[9] != "" and (!RegExMatch(Fields[9], "^\d+$")
			or !TOML_TryParseInteger(Fields[9], &ParsedPriority)
			or !HotstringsTryPriority(ParsedPriority, &Priority)))
			throw ValueError("Hotstring cache contains an invalid priority literal.")
		Key := Fields[1] . "." . Fields[2]
		Row := [Fields[3], _HsCacheUnescape(Fields[4]), _HsCacheUnescape(Fields[5]), (Fields[6] == "1"), (Fields[7] == "1"), (Fields[8] == "1"), Priority]
		if !Rows.Has(Key)
			Rows[Key] := []
		Rows[Key].Push(Row)
		Rows.SourceOrder.Push([Key, Row])
	}
	if HasIndex && !HasFooter
		throw ValueError("Hotstring cache source receipt has no terminal proof.")
	return Rows
}





; =================================================
; =================================================
; ======= 6/ Ensure + register (public API) =======
; =================================================
; =================================================

; Load the hotstring cache exactly once: admit the exact parsed .tsv by its
; captured source inventory, else rebuild from
; the TOML and rewrite the .tsv for next boot. Populates _GENERATED_HOTSTRINGS so
; LoadHotstringsSection's existing fast path resolves every cached section to the
; shared registrar. Idempotent and cheap after the first call.
HotstringsCacheEnsure() {
	global _HS_CACHE_LOADED, _HS_CACHE_ROWS, _GENERATED_HOTSTRINGS, _SharedDir
	static Loading := false
	if _HS_CACHE_LOADED
		return
	if !IsSet(_SharedDir)
		return
	PreviousCritical := Critical("On")
	try {
		if _HS_CACHE_LOADED
			return
		if Loading
			throw Error("Hotstring cache initialization is already in progress; retry after its owner completes.")
		Loading := true
	} finally Critical(PreviousCritical)
	try {
		TsvPath := _HotstringsCacheTsvPath()
		Rows := "", Fast := false
		if FileExist(TsvPath) {
			try {
				Candidate := _HotstringsCacheReadTsv(FileRead(TsvPath, "UTF-8"))
				if _HotstringsCacheInventoryMatches(Candidate)
					Rows := Candidate, Fast := true
			} catch as Err {
				try LoggerWarn("Hotstrings", "Hotstring cache '{1}' unreadable ({2}); rebuilding from TOML.", TsvPath, Err.Message)
			}
		}
		if !(Rows is Map) || Rows.Count == 0 || !Rows.SourceOrderVersion {
			Rows := ""
			; One independent edit may settle on the retry. Persistent movement or
			; a stale canonical index refuses instead of publishing an old image.
			MaxBuildAttempts := 2
			loop MaxBuildAttempts {
				Candidate := _HotstringsCacheBuildRows()
				_HotstringsCacheWriteTsv(TsvPath, Candidate)
				; Cache publication may fail and log through a yielding observer.
				; A verified source snapshot still loads without a writable cache.
				if _HotstringsCacheInventoryMatches(Candidate, false) {
					Rows := Candidate
					break
				}
			}
			if !(Rows is Map)
				throw Error("Hotstring sources changed or could not be verified during cache initialization; no cache projection was published. Retry once the sources are stable.")
			Fast := false
		}
		; There is no arbitrary callback between the final source witness and
		; this memory-only publication. Logging below is post-publication.
		PreviousCritical := Critical("On")
		try {
			_GENERATED_HOTSTRINGS := Map()
			_HS_CACHE_ROWS := Rows
			for Key, _RowList in Rows
				_GENERATED_HOTSTRINGS[Key] := _HsCacheRegisterSection.Bind(Key)
			_HS_CACHE_LOADED := true
		} finally Critical(PreviousCritical)
		try LoggerDone("Hotstrings", "Hotstring cache ready ({1} section(s), {2}).",
			Rows.Count, Fast ? "fast" : "rebuilt")
	} catch as Err {
		PreviousCritical := Critical("On")
		try {
			_HS_CACHE_ROWS := Map()
			_HS_CACHE_ROWS.SourceOrder := []
			_GENERATED_HOTSTRINGS := Map()
			_HS_CACHE_LOADED := false
		} finally Critical(PreviousCritical)
		throw Err
	} finally {
		PreviousCritical := Critical("On")
		try Loading := false
		finally Critical(PreviousCritical)
	}
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
	global _HS_CACHE_ROWS
	if !_HS_CACHE_ROWS.Has(LoaderKey)
		return
	_HsCacheRegisterRows(LoaderKey, _HS_CACHE_ROWS[LoaderKey], FeatureConfig, ExtraOptions, ResolvedPriority)
}

; Both section and source-ordered registration share the exact per-row native owner.
_HsCacheRegisterRows(LoaderKey, RowList, FeatureConfig, ExtraOptions, ResolvedPriority := "") {
	global ScriptInformation, HS_CACHE_MARKER, HSE_PRIORITY_COMMON
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
