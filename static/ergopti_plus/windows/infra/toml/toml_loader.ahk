; infra/toml/toml_loader.ahk

; ==============================================================================
; MODULE: TOML Loader
; DESCRIPTION:
; Lightweight TOML reader used by ErgoptiPlus to load hotstring payloads and
; feature metadata from ``..\hotstrings\*.toml`` files, making the TOML the
; single source of truth for hotstrings, menu titles and submenu ordering.
;
; FEATURES & RATIONALE:
; 1. UnescapeTomlString: mirrors the Python generator that writes trigger /
;    output fields with ``\\``, ``\"``, ``\n``, ``\t``, ``\r`` escapes.
; 2. LoadHotstringsSection: replays every ``[[section]]`` entry through the
;    exact same ``CreateHotstring`` / ``CreateCaseSensitiveHotstrings`` calls
;    that were used before the TOML migration, preserving behavior 1:1.
; 3. ParseTomlGroupConfig: reads ``[_meta]`` and ``[_meta.sections.*]`` blocks
;    for per-group delay, tooltip color and description.
; 4. FoldAsciiLower: accent-folding helper that reconciles identifiers
;    containing French letters (e.g. ``IÉ``) with lowercase TOML keys.
; ==============================================================================

; Holds the raw UTF-8 content of every TOML file that has been read this
; session, keyed by absolute file path. Large category files (autocorrection.toml,
; magickey.toml) are read at most once even when many sections are loaded.
global _TomlFileCache    := Map()
global _TomlCountCache   := Map()   ; key = CategoryName|SectionName → count

; Map of FilePath → Map(SectionId → Count)
global _TomlFileSectionCounts := Map()

; Pre-compiled regex for a full TOML hotstring entry line. Defined once at
; module level so AHK does not recompile this ~100-char pattern for every line
; scanned by LoadHotstringsSection (thousands of iterations at boot).
; The trailing is_case_sensitive_strict and priority keys are both optional so a
; personal entry carrying an individual `priority = N` override still matches —
; without that group the boot loader would silently skip the whole entry and the
; per-hotstring priority feature would be a no-op (the value is then read back by
; _ParseEntryPriority, which is order-tolerant).
global _HOTSTRING_ENTRY_PATTERN :=
		'i)^"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*\{\s*output\s*=\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,\s*is_word\s*=\s*(true|false)\s*,\s*auto_expand\s*=\s*(true|false)\s*,\s*is_case_sensitive\s*=\s*(true|false)\s*,\s*final_result\s*=\s*(true|false)(?:\s*,\s*is_case_sensitive_strict\s*=\s*(true|false))?(?:\s*,\s*priority\s*=\s*([0-9]+))?\s*\}'

; Simple `key = "value"` entry shape that LoadExtTomlFile also registers (as a
; CreateCaseSensitiveHotstrings call) when the full inline-table pattern misses.
; Defined once here so the displayed count helpers can recognise EXACTLY the two
; shapes that actually get registered, never a looser `key =` form that would
; over-count malformed or non-entry lines versus the registered rows.
global _HOTSTRING_SIMPLE_ENTRY_PATTERN :=
	'i)^(?:"((?:[^"\\]|\\.)*)"|([A-Za-z0-9_.-]+))\s*=\s*"((?:[^"\\]|\\.)*)"\s*$'

; A TOML section header, accepting ONE or MORE brackets — `[snippets]` and
; `[[snippets]]` are both valid and both register hotstrings.
;
; Named and shared because the extension-pack PREVIEW indexer
; (infra/hotstrings/hotstring_registry.ahk) parses the same files and used to
; accept double brackets only, resetting its current section on anything else.
; A pack written with single-bracket headers therefore expanded — the engine
; accepted it here — while never being indexed for the tooltip, so it could never
; be previewed. The two sides were unified on the FILE SET first; this is the
; other half, the GRAMMAR, and a shared constant is what stops it drifting again.
global HS_TOML_SECTION_HEADER_PATTERN := "^\[+([^\[\]]+)\]+$"





; ========================================================
; ========================================================
; ======= 1/ TOML string and metadata load helpers =======
; ========================================================
; ========================================================

; Extract an individual per-hotstring priority from a TOML entry line, or return
; Fallback when the entry carries no `priority = N` key. The key must be preceded
; by `{` or `,` so it is matched only as a real inline-table key and can never
; collide with the word "priority" appearing inside the output string. This is
; the top level of the priority cascade (individual > section > file > source).
_ParseEntryPriority(Line, Fallback) {
		if RegExMatch(Line, "i)[,{]\s*priority\s*=\s*([0-9]+)", &PrioM) {
				return PrioM[1] + 0
		}
		return Fallback
}

; Return the cached content of a TOML file, reading it from disk on first access.
ReadTomlFile(FilePath) {
		global _TomlFileCache, _TomlUnreadableFiles
		if _TomlFileCache.Has(FilePath) {
				return _TomlFileCache[FilePath]
		}
		Content := ""
		try {
				Content := FileRead(FilePath, "UTF-8")
		} catch as Err {
				; Do NOT cache a failed read. Caching it made one transient lock at
				; boot — a sync client, the personal TOML editor, a backup scanner —
				; hide a whole hotstring file for the entire session: every consumer
				; saw zero entries and the load was still logged as done. Leaving the
				; path uncached lets the next caller retry.
				if FileExist(FilePath) {
						; Record the failure so writers can tell "unreadable" from "empty".
						; Only for an existing file: a missing one legitimately reads empty,
						; and flagging it would block the first save of a fresh install.
						_TomlUnreadableFiles[FilePath] := true
						try LoggerError("TomlLoader", "Cannot read '{1}': {2}. Treated as empty for this call; not cached so a later read retries, and flagged unreadable so writers refuse to rebuild from it.", FilePath, Err.Message)
				}
				return ""
		}
		; A successful read clears the sticky flag: the content below is now the
		; real file, so anything derived from it is safe to persist again.
		if _TomlUnreadableFiles.Has(FilePath)
				_TomlUnreadableFiles.Delete(FilePath)
		_TomlFileCache[FilePath] := Content
		return Content
}

; Helper to warm the section counts cache for a specific file.
_TomlWarmFileCounts(FilePath) {
		global _TomlFileSectionCounts, _HOTSTRING_ENTRY_PATTERN, _HOTSTRING_SIMPLE_ENTRY_PATTERN
		if _TomlFileSectionCounts.Has(FilePath)
				return _TomlFileSectionCounts[FilePath]

		Counts := Map()
		if !FileExist(FilePath) {
				_TomlFileSectionCounts[FilePath] := Counts
				return Counts
		}

		CurrentSec := ""
		loop parse, ReadTomlFile(FilePath), "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#")
						continue
						
				; [[section]] or [section] header.
				; Stripped like LoadHotstringsSection does. This pattern is ANCHORED, so
				; a header carrying a trailing comment simply fails to match: the line
				; then falls through to the entry parser, fails that too, and continues —
				; leaving CurrentSec on the PREVIOUS section, so every entry below is
				; counted against the wrong one. That is why the menu's hotstring count
				; could disagree with the number of entries actually registered.
				if RegExMatch(TOML_StripInlineComment(Line), "^\[+([^\[\]]+)\]+$", &SectionMatch) {
						CurrentSec := StrLower(Trim(SectionMatch[1]))
						if !Counts.Has(CurrentSec)
								Counts[CurrentSec] := 0
						continue
				}
				
				; Match hotstring entry: key = value or key = { ... }
				; Skip every metadata block, not just the two flat forms: equality checks
				; let the dotted per-section form ([_meta.sections.<x>], [_meta.section_delays])
				; written by the config window slip through, so its delay/color/priority lines
				; were miscounted as hotstrings. Mirror _HotstringsCacheBuildRows' convention.
				; Count a line only when it matches one of the two shapes the loaders
				; actually register: the full inline-table entry (LoadHotstringsSection /
				; LoadExtTomlFile) or the simple key="value" entry (LoadExtTomlFile
				; fallback). A looser `key =` test over-counted non-entry lines, so the
				; displayed count could exceed the registered/cached row count.
				if (CurrentSec != "" and CurrentSec != "_meta" and !InStr(CurrentSec, "_meta.")) {
						if (RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN)
						or RegExMatch(Line, _HOTSTRING_SIMPLE_ENTRY_PATTERN)) {
								Counts[CurrentSec] := Counts[CurrentSec] + 1
						}
				}
		}

		; Never memoise a count derived from a read that failed. ReadTomlFile
		; deliberately leaves an unreadable path uncached so the next caller retries;
		; caching the zero it produced here reinstated the very bug that rule removed,
		; one call level up — the menu showed the category as empty for the whole
		; session and no later successful read could reach this consumer again.
		if TOML_UnreadableFile(FilePath)
				return Counts
		_TomlFileSectionCounts[FilePath] := Counts
		return Counts
}

; Count hotstring entries inside a specific [[section]] of a TOML category file.
; Returns 0 when the file or section does not exist.
; Optimized to parse each file only ONCE and cache all section counts.
CountTomlSection(CategoryName, SectionName, FilePath := "") {
		global ScriptInformation, _SharedDir
		if (FilePath == "") {
				if (StrLower(CategoryName) == "personal"
				and IsSet(ScriptInformation)
				and ScriptInformation.Has("PersonalTomlPath")) {
						FilePath := ScriptInformation["PersonalTomlPath"]
				} else {
						FilePath := _SharedDir . "\modules\hotstrings\" . StrLower(CategoryName) . ".toml"
				}
		}
		
		Counts := _TomlWarmFileCounts(FilePath)
		SName := StrLower(SectionName)
		return Counts.Has(SName) ? Counts[SName] : 0
}

; Count all hotstring entries across every [[section]] in a TOML category file.
; Returns 0 when the file does not exist or contains no matching entries.
CountTomlHotstrings(CategoryName, FilePath := "") {
		global ScriptInformation, _SharedDir
		if (FilePath == "") {
				if (StrLower(CategoryName) == "personal"
				and IsSet(ScriptInformation)
				and ScriptInformation.Has("PersonalTomlPath")) {
						FilePath := ScriptInformation["PersonalTomlPath"]
				} else {
						FilePath := _SharedDir . "\modules\hotstrings\" . StrLower(CategoryName) . ".toml"
				}
		}
		
		Counts := _TomlWarmFileCounts(FilePath)
		Total := 0
		for _, Count in Counts {
				Total += Count
		}
		return Total
}

; Resolve the (CategoryName, FilePath) pair ParseTomlGroupConfig was called with
; to the TOML file that actually backs it. Shared with the invalidator below so
; the cache key and the eviction key can never drift apart: the resolver calls
; ParseTomlGroupConfig("personal") while the config window calls it with an
; explicit path, and both must be recognised as the same file.
_ParseTomlGroupConfig_ResolveFile(CategoryName, FilePath := "") {
		global ScriptInformation, _SharedDir
		if (FilePath != "") {
				return FilePath
		}
		LowerCat := StrLower(CategoryName)
		if (LowerCat == "personal"
				and IsSet(ScriptInformation)
				and ScriptInformation.Has("PersonalTomlPath")) {
				return ScriptInformation["PersonalTomlPath"]
		}
		return (IsSet(_SharedDir) ? _SharedDir : "") . "\modules\hotstrings\" . LowerCat . ".toml"
}

; Evict all cache entries for a given file path so that the next call to
; ParseTomlGroupConfig or ReadTomlFile re-reads from disk. Called after
; _HCW_PatchTomlMeta writes changes to a personal TOML file.
_ParseTomlGroupConfig_InvalidatePath(FilePath) {
		global _TomlFileCache, HotstringGroupConfig, _TomlCountCache, _TomlFileSectionCounts
		if _TomlFileCache.Has(FilePath) {
				_TomlFileCache.Delete(FilePath)
		}
		; One file is cached under more than one key: the engine/tooltip resolver
		; reaches personal_hotstrings.toml as the bare category "personal" while the
		; config window reaches it by absolute path. Deleting only the path left the
		; category-keyed entry alive, so a personal delay/priority edit re-registered
		; the engine from the PRE-edit [_meta] while the window displayed the new
		; value — with every signal saying the write had landed. Evict every key that
		; resolves to this file, not just the one the caller happened to name.
		for Key, _ in HotstringGroupConfig.Clone() {
				if (Key == FilePath) {
						HotstringGroupConfig.Delete(Key)
						continue
				}
				Resolved := ""
				try Resolved := _ParseTomlGroupConfig_ResolveFile(Key)
				if (Resolved != "" and Resolved == FilePath) {
						HotstringGroupConfig.Delete(Key)
				}
		}
		; The resolved hotstring delay/color for this group may now differ, so drop
		; the memoised HotstringsResolve results too (defined in hotstrings_config.ahk).
		try HotstringsResolveBumpGen()
		; Also invalidate the section counts cache for this file
		if _TomlFileSectionCounts.Has(FilePath) {
				_TomlFileSectionCounts.Delete(FilePath)
		}
		; Legacy count cache invalidation
		for Key, _ in _TomlCountCache.Clone() {
				if InStr(Key, FilePath) {
						_TomlCountCache.Delete(Key)
				}
		}
}

; Unescapes TOML basic-string contents through the shared complete codec.
; The generator at static/hotstrings/0_generate_hotstrings.py writes
; trigger/output with these escapes, so we mirror the inverse transform here.
UnescapeTomlString(s) {
		return TOML_UnescapeBasicStringContents(s)
}





; =======================================================
; =======================================================
; ======= 2/ High-level hotstring section loading =======
; =======================================================
; =======================================================

; Register every hotstring of a given [[section]] defined inside a TOML file
; located under ..\hotstrings\<CategoryName>.toml (relative to the script).
; Hotstrings flagged as commented-out in TOML (line starting with "#") are
; skipped, mirroring AHK source lines starting with ";".
LoadHotstringsSection(CategoryName, SectionName, FeatureConfig, ExtraOptions := Map()) {
		global ScriptInformation, _GENERATED_HOTSTRINGS, _SharedDir

		; Accept either shape transparently
		if (IsObject(FeatureConfig) and Type(FeatureConfig) == "Map") {
				_V1Compat := { Enabled: false }
				if FeatureConfig.Has("enabled") {
						_V1Compat.Enabled := FeatureConfig["enabled"]
				}
				if FeatureConfig.Has("time_activation_seconds") {
						_V1Compat.TimeActivationSeconds := FeatureConfig["time_activation_seconds"]
				}
				if FeatureConfig.Has("pattern_max_length") {
						_V1Compat.PatternMaxLength := FeatureConfig["pattern_max_length"]
				}
				FeatureConfig := _V1Compat
		}

		; Delay and the section/file/source priority both come from the same override
		; cascade as color (HotstringsResolve). The resolved priority already folds in
		; the source-default fallback (personal 50 > package 30 > common 10); the
		; individual per-hotstring level overrides it per entry below. _HSE_SourcePriority
		; is the pre-resolve default in case HotstringsResolve throws.
		ResolvedPriority := _HSE_SourcePriority(CategoryName)
		try {
				Resolved := HotstringsResolve(CategoryName, SectionName)
				if (Resolved.Delay != "") {
						FeatureConfig.TimeActivationSeconds := Resolved.Delay
				}
				if (Resolved.HasOwnProp("Priority") and Resolved.Priority != "") {
						ResolvedPriority := Resolved.Priority
				}
		}

		; Fast path — bundled categories served from the self-healing .tsv cache.
		; HotstringsCacheEnsure (infra/hotstrings/hotstrings_cache.ahk) loads the cache
		; once and populates _GENERATED_HOTSTRINGS with a registrar per cached section;
		; a cache miss leaves the map empty so we fall through to the TOML parse below.
		HotstringsCacheEnsure()
		LoaderKey := StrLower(CategoryName) . "." . StrLower(SectionName)
		if (IsSet(_GENERATED_HOTSTRINGS)
		and StrLower(CategoryName) != "personal"
		and _GENERATED_HOTSTRINGS.Has(LoaderKey)) {
				try LoggerTrace("TomlLoader", "Using generated loader for [{1}.{2}].",
						CategoryName, SectionName)
				GeneratedFn := _GENERATED_HOTSTRINGS[LoaderKey]
				; Thread the section/file/source-resolved priority into the cache registrar
				; so a cached entry with no individual override registers at the SAME
				; priority the TOML fallback would compute via _ParseEntryPriority(Line,
				; ResolvedPriority). Without this the fast/cached path and the fallback
				; could resolve different collision priorities for the same TOML.
				GeneratedFn(FeatureConfig, ExtraOptions, ResolvedPriority)
				try LoggerDone("TomlLoader", "Generated section [{1}.{2}] loaded.",
						CategoryName, SectionName)
				return
		}

		if (StrLower(CategoryName) == "personal"
		and IsSet(ScriptInformation)
		and ScriptInformation.Has("PersonalTomlPath")) {
				FilePath := ScriptInformation["PersonalTomlPath"]
		} else {
				FilePath := _SharedDir . "\modules\hotstrings\" . CategoryName . ".toml"
		}
		if !FileExist(FilePath) {
				try LoggerWarn("TomlLoader", "Section [{1}.{2}]: file {3} not found.",
						CategoryName, SectionName, FilePath)
				return
		}
		try LoggerTrace("TomlLoader", "Loading section [{1}.{2}]…", CategoryName, SectionName)
		Loaded := 0

		TimeActivationSeconds := FeatureConfig.HasOwnProp("TimeActivationSeconds") ? FeatureConfig.TimeActivationSeconds : 0
		TargetSection := StrLower(SectionName)
		CurrentSection := ""

		FileContent := ReadTomlFile(FilePath)
		loop parse, FileContent, "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#") {
						continue
				}
				; Comment cut first — this pattern is anchored, so a commented header
				; would not match, would fall through as a non-key line, and would leave
				; CurrentSection pointing at the PREVIOUS section.
				if RegExMatch(TOML_StripInlineComment(Line), "^\[+([^\[\]]+)\]+$", &SectionMatch) {
						CurrentSection := StrLower(Trim(SectionMatch[1]))
						continue
				}
				if (CurrentSection != TargetSection) {
						continue
				}
				if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match) {
						continue
				}

				Trigger := UnescapeTomlString(Match[1])
				Output := UnescapeTomlString(Match[2])
				Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
				; The REPLACEMENT carries the marker too — the bundled corpus ships
				; entries whose output is the magic key itself. Substituting only the
				; trigger emitted a literal U+2605 the user cannot type, while the
				; preview index (hotstring_registry.ahk) substitutes both sides, so the
				; tooltip promised one string and the engine typed another.
				Output := StrReplace(Output, "★", ScriptInformation["MagicKey"])
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

				; Individual per-hotstring priority — the top of the cascade
				; (individual > section > file > source default). Falls back to the
				; resolved section/source value when the entry has no `priority` key.
				EntryPriority := _ParseEntryPriority(Line, ResolvedPriority)

				; The caller's options first, the per-entry values on top. Naming the
				; single key worth forwarding is what let the cache path silently drop
				; IsPrivate; this path is the one the cache reproduces 1:1, so the two
				; forward the same way or the fallback quietly means something else.
				Options := ExtraOptions.Clone()
				Options["TimeActivationSeconds"] := TimeActivationSeconds
				Options["FinalResult"] := FinalResult
				Options["Category"] := CategoryName
				Options["Section"] := SectionName
				Options["Priority"] := EntryPriority

				HSE_RegisterFromTomlFlags(IsCaseSens, Flags, Trigger, Output, Options)
				Loaded += 1
		}
		try LoggerDone("TomlLoader", "Section [{1}.{2}]: {3} entry(ies) loaded.",
				CategoryName, SectionName, Loaded)
}

; Load all hotstring entries from every [[section]] in an arbitrary TOML file.
LoadExtTomlFile(FilePath, CategoryLabel) {
		global ScriptInformation, _HOTSTRING_ENTRY_PATTERN, _HOTSTRING_SIMPLE_ENTRY_PATTERN, HSE_PRIORITY_PACKAGE
		global HS_TOML_SECTION_HEADER_PATTERN
		if !FileExist(FilePath) {
				try LoggerWarn("TomlLoader", "Extension TOML '{1}' not found — skipped.", FilePath)
				return
		}
		try LoggerStart("TomlLoader", "Loading extension TOML '{1}'…", FilePath)
		TotalLoaded := 0
		CurrentSection := ""
		SplitPath FilePath, , , , &CategoryName
		FileContent := ReadTomlFile(FilePath)
		loop parse, FileContent, "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#") {
						continue
				}
				; Stripped for the same reason as the counter above and
				; LoadHotstringsSection: an anchored pattern silently mis-attributes
				; every following entry when a header carries a trailing comment.
				if RegExMatch(TOML_StripInlineComment(Line), HS_TOML_SECTION_HEADER_PATTERN, &SecM) {
						CurrentSection := StrLower(Trim(SecM[1]))
						continue
				}
				if (CurrentSection == "") {
						continue
				}
				; Metadata blocks ([_meta], [_meta.sections], [_meta.sections.<x>]) describe
				; the file — they are NOT hotstrings. Skip them so a key like
				; description="Hotstrings personnels" or a section label never registers as
				; an expandable trigger (mirrors CountTomlSection and _HotstringsCacheBuildRows).
				if (CurrentSection == "_meta" or InStr(CurrentSection, "_meta.")) {
						continue
				}
				if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match) {
						if RegExMatch(Line, _HOTSTRING_SIMPLE_ENTRY_PATTERN, &SimpleM) {
								Trigger := UnescapeTomlString(
									(SimpleM[1] != "") ? SimpleM[1] : SimpleM[2])
								Output  := UnescapeTomlString(SimpleM[3])
								Trigger := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
								; Same marker substitution on the replacement as on the trigger:
								; an extension pack whose output is the magic key must emit the
								; user's key, not the corpus placeholder.
								Output  := StrReplace(Output, "★", ScriptInformation["MagicKey"])
								Options := Map("TimeActivationSeconds", 0, "FinalResult", true, "Priority", HSE_PRIORITY_PACKAGE)
								CreateCaseSensitiveHotstrings("", Trigger, Output, Options)
								TotalLoaded += 1
						}
						continue
				}
				Trigger    := UnescapeTomlString(Match[1])
				Output     := UnescapeTomlString(Match[2])
				Trigger    := StrReplace(Trigger, "★", ScriptInformation["MagicKey"])
				Output     := StrReplace(Output, "★", ScriptInformation["MagicKey"])
				IsWord     := (Match[3] == "true")
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

				SectionName := CurrentSection
				IsRepeat := (StrLower(CategoryName) == "magickey" and SectionName == "repeatcorrections"
						and InStr(Trigger, ScriptInformation["MagicKey"]) > 0)
				EntryPriority := _ParseEntryPriority(Line, HSE_PRIORITY_PACKAGE)
				Options := Map("TimeActivationSeconds", 0, "FinalResult", FinalResult, "IsRepeat", IsRepeat, "Priority", EntryPriority)
				HSE_RegisterFromTomlFlags(IsCaseSens, Flags, Trigger, Output, Options)
				TotalLoaded += 1
		}
		try LoggerSuccess("TomlLoader", "Extension TOML '{1}': {2} entry(ies) loaded.", CategoryLabel, TotalLoaded)
}

; Fold common French accented characters to their ASCII equivalent.
FoldAsciiLower(Str) {
		Result := StrLower(Str)
		Result := StrReplace(Result, "à", "a")
		Result := StrReplace(Result, "â", "a")
		Result := StrReplace(Result, "ä", "a")
		Result := StrReplace(Result, "é", "e")
		Result := StrReplace(Result, "è", "e")
		Result := StrReplace(Result, "ê", "e")
		Result := StrReplace(Result, "ë", "e")
		Result := StrReplace(Result, "î", "i")
		Result := StrReplace(Result, "ï", "i")
		Result := StrReplace(Result, "ô", "o")
		Result := StrReplace(Result, "ö", "o")
		Result := StrReplace(Result, "ù", "u")
		Result := StrReplace(Result, "û", "u")
		Result := StrReplace(Result, "ü", "u")
		Result := StrReplace(Result, "ç", "c")
		return Result
}



; Parse the ``[_meta]`` and ``[_meta.sections.<name>]`` blocks of a category TOML.
global HotstringGroupConfig := Map()

ParseTomlGroupConfig(CategoryName, FilePath := "") {
		global ScriptInformation, HotstringGroupConfig, _SharedDir
		LowerCat := StrLower(CategoryName)
		CacheKey := (FilePath != "") ? FilePath : LowerCat
		if HotstringGroupConfig.Has(CacheKey) {
				return HotstringGroupConfig[CacheKey]
		}

		; Resolved through the shared helper so _ParseTomlGroupConfig_InvalidatePath
		; recognises exactly the same file for a bare-category key as for a path one.
		FilePath := _ParseTomlGroupConfig_ResolveFile(CategoryName, FilePath)

		Config := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
		if !FileExist(FilePath) {
				; Cache the missing-file result under CacheKey (the same key the lookup at
				; the top of this function checks and that _ParseTomlGroupConfig_InvalidatePath
				; deletes). Keying it under LowerCat instead made explicit-path calls never
				; cache-hit and left a stale empty Config unreachable by invalidation.
				HotstringGroupConfig[CacheKey] := Config
				return Config
		}

		Mode := ""
		CurrentSec := ""

		FileContent := ReadTomlFile(FilePath)
		loop parse, FileContent, "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#") {
						continue
				}
				Line := Trim(TOML_StripInlineComment(Line), " `t")
				if (Line == "")
						continue
				if (SubStr(Line, 1, 2) == "[[") {
						break
				}
				if RegExMatch(Line, "^\[_meta\.sections\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
						Mode := "meta_section"
						CurrentSec := StrLower(SecMatch[1])
						if !Config.Sections.Has(CurrentSec) {
								Config.Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Description: "" }
						}
						continue
				}
				if RegExMatch(Line, "^\[_meta\.section_delays\]$") {
						Mode := "meta_section_delays"
						CurrentSec := ""
						continue
				}
				if (Line == "[_meta]") {
						Mode := "meta"
						continue
				}
				if RegExMatch(Line, "^\[([^\[\]]+)\]$", &HeaderMatch) {
						Mode := ""
						CurrentSec := ""
						continue
				}

				if (Mode == "meta") {
						if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
								Config.Delay := NumMatch[1] + 0
						} else if RegExMatch(Line, '^color\s*=\s*"((?:[^"\\]|\\.)*)"$', &ColMatch) {
								Config.Color := UnescapeTomlString(ColMatch[1])
						} else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
								Config.ShowTooltip := (BoolMatch[1] == "true")
						} else if RegExMatch(Line, "^priority\s*=\s*([0-9]+)\s*$", &PrioMatch) {
								Config.Priority := PrioMatch[1] + 0
						}
				} else if (Mode == "meta_section" and CurrentSec != "") {
						Sec := Config.Sections[CurrentSec]
						if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
								Sec.Delay := NumMatch[1] + 0
						} else if RegExMatch(Line, '^color\s*=\s*"((?:[^"\\]|\\.)*)"$', &ColMatch) {
								Sec.Color := UnescapeTomlString(ColMatch[1])
						} else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
								Sec.ShowTooltip := (BoolMatch[1] == "true")
						} else if RegExMatch(Line, "^priority\s*=\s*([0-9]+)\s*$", &PrioMatch) {
								Sec.Priority := PrioMatch[1] + 0
						} else if RegExMatch(Line, '^description\s*=\s*"((?:[^"\\]|\\.)*)"$', &DescMatch) {
								Sec.Description := UnescapeTomlString(DescMatch[1])
						}
				} else if (Mode == "meta_section_delays") {
						if RegExMatch(Line, "^([A-Za-z0-9_\-]+)\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &SDMatch) {
								SDKey := StrLower(SDMatch[1])
								if !Config.Sections.Has(SDKey) {
										Config.Sections[SDKey] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Description: "" }
								}
								Config.Sections[SDKey].Delay := SDMatch[2] + 0
						}
				}
		}

		; Same rule as _TomlWarmFileCounts: an all-empty Config produced by a read
		; that never saw the file must not become permanent. Memoising it froze the
		; group's [_meta] delay/colour/priority at the global fallback for the whole
		; session, and the cache hit precedes the read so no retry could correct it.
		if TOML_UnreadableFile(FilePath)
				return Config
		HotstringGroupConfig[CacheKey] := Config
		return Config
}

; Read sections_order array from [_meta] block.
ReadTomlSectionsOrder(CategoryName, FilePath := "") {
		global _SharedDir
		if (FilePath == "") {
				FilePath := _SharedDir . "\modules\hotstrings\" . StrLower(CategoryName) . ".toml"
		}
		if !FileExist(FilePath) {
				return []
		}
		InMeta := false
		loop parse, ReadTomlFile(FilePath), "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#") {
						continue
				}
				Line := Trim(TOML_StripInlineComment(Line), " `t")
				if (Line == "")
						continue
				if (Line == "[_meta]") {
						InMeta := true
						continue
				}
				if (InMeta and SubStr(Line, 1, 1) == "[") {
						break
				}
				if !InMeta {
						continue
				}
				if !RegExMatch(Line, "^sections_order\s*=\s*\[(.+)\]", &M) {
						continue
				}
				Out := []
				loop parse, M[1], "," {
						Token := Trim(A_LoopField, " `t" Chr(34))
						if (Token != "") {
								Out.Push(Token)
						}
				}
				return Out
		}
		return []
}

; Coerce raw TOML literal into appropriate AHK type.
TomlCoerceValue(Raw) {
		Trimmed := Trim(Raw, " `t")
		Lower := StrLower(Trimmed)
		if (Lower == "true")
				return 1
		if (Lower == "false")
				return 0
		if TOML_TryParseInteger(Trimmed, &IntegerValue)
				return IntegerValue
		if RegExMatch(Trimmed, "^-?\d+\.\d+$")
				return Float(Trimmed)
		Q := Chr(34)
		if (StrLen(Trimmed) >= 2 and SubStr(Trimmed, 1, 1) == Q
		and SubStr(Trimmed, StrLen(Trimmed), 1) == Q) {
				return UnescapeTomlString(SubStr(Trimmed, 2, StrLen(Trimmed) - 2))
		}
		return Trimmed
}
