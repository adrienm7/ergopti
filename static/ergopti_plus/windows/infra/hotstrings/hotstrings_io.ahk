; infra/hotstrings/hotstrings_io.ahk

; ==============================================================================
; MODULE: Hotstrings Config — Override File I/O
; DESCRIPTION:
; Reads and writes the hotstrings override file
; (%USERPROFILE%\.config\ergopti_plus\hotstrings_config.toml) that stores
; per-category/section delay, color, show_tooltip, and priority overrides
; shared between the AHK and Hammerspoon drivers.
;
; FEATURES & RATIONALE:
; 1. Cross-driver shared canon — the override file format is identical for both
;    drivers; any change from either menu takes effect on the other at reload.
; 2. Boot-time defaults loaded from _shared/modules/hotstrings/defaults.toml so
;    the AHK and macOS fallback values can never drift behind a re-typed literal.
; 3. Stable on-disk serialisation via _SaveOverrides: alphabetical category and
;    section order, HOTSTRINGS_DELAY_DECIMALS decimal places for delay values.
;
; Included by infra/hotstrings/hotstrings_config.ahk.
; ==============================================================================




; ============================================================
; ============================================================
; ======= 1/ Override file I/O ==============================
; ============================================================
; ============================================================

; Load the cross-driver hotstring resolution defaults — the global default
; expansion delay, the global default tooltip color, and the per-category
; "personal" baseline color — from the shared canon
; (_shared/modules/hotstrings/defaults.toml), the SINGLE source shared verbatim with the
; Hammerspoon driver. Must run once at boot BEFORE the tray menu is built (it
; reads GLOBAL_DEFAULT_DELAY) and before any HotstringsResolve.
;
; A missing file or key THROWS — in production the unhandled error surfaces the
; fatal dialog and the script exits (fail fast, rule 5.3); in the headless test
; runner run_all.ahk's OnError handler turns it into a "not ok 0" line instead
; of hanging on a modal. There is no compile-time fallback (rules 5.2 / 5.4).
; @param SharedDir Optional _shared/ root; defaults to the global ``_SharedDir``.
HotstringsConfigLoadSharedDefaults(SharedDir := "") {
		global _SharedDir, GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, DYN_HOTSTRINGS_DEFAULT_DELAY
		global HOTSTRINGS_CATEGORY_DEFAULT_COLORS
		Dir  := (SharedDir != "") ? SharedDir : (IsSet(_SharedDir) ? _SharedDir : "")
		Path := Dir . "\modules\hotstrings\defaults.toml"
		c    := ParseTomlFile(Path)
		if !c.Count {
				throw Error("_shared/modules/hotstrings/defaults.toml introuvable ou vide : " . Path)
		}

		GLOBAL_DEFAULT_DELAY := Float(_HSDefaultsRequire(c, "delays", "default_sec", Path))
		DYN_HOTSTRINGS_DEFAULT_DELAY := Float(_HSDefaultsRequire(c, "delays", "dynamichotstrings_sec", Path))
		GLOBAL_DEFAULT_COLOR := _HSDefaultsRequireHex(c, "colors", "global_default", Path)
		HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"] := _HSDefaultsRequireHex(c, "colors", "personal", Path)

		try LoggerInfo("HotstringsConfig", "Shared defaults loaded (delay={1}s dyn={2}s color={3} personal={4}).",
				GLOBAL_DEFAULT_DELAY, DYN_HOTSTRINGS_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"])
}

; Source the llm_prediction baseline tint from the canonical AI loading hex
; (UI_AI_LOADING_HEX, loaded by UiStyle_LoadSharedConst() from
; _shared/modules/tooltip/constants.toml [accent_colors] ai_loading_hex) so the AI tint
; lives in ONE place instead of a re-typed literal. Must run AFTER
; UiStyle_LoadSharedConst() — UI_AI_LOADING_HEX is "" until then — and before the
; tray menu build / any resolve. A missing value THROWS (fail fast, no fallback).
HotstringsConfigLoadLlmPredictionColor() {
		global UI_AI_LOADING_HEX, HOTSTRINGS_CATEGORY_DEFAULT_COLORS
		Hex := IsSet(UI_AI_LOADING_HEX) ? UI_AI_LOADING_HEX : ""
		if (Hex == "") {
				throw Error("HotstringsConfigLoadLlmPredictionColor(): UI_AI_LOADING_HEX not loaded — must run after UiStyle_LoadSharedConst().")
		}
		HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"] := Hex
}

; Fetch a required key from the parsed defaults cache, throwing on absence so a
; truncated/edited canon aborts loudly rather than resolving to "".
_HSDefaultsRequire(c, Section, Key, Path) {
		Val := IniCacheGet(c, Section, Key)
		if (Val == "_") {
				throw Error(Format("_shared/modules/hotstrings/defaults.toml — clé manquante : [{1}] {2} ({3})", Section, Key, Path))
		}
		return Val
}

; Like _HSDefaultsRequire but validates a "#RRGGBB" (or "RRGGBB") hex color and
; returns it normalised WITH the leading "#" (the form every consumer expects).
_HSDefaultsRequireHex(c, Section, Key, Path) {
		Val := _HSDefaultsRequire(c, Section, Key, Path)
		Hex := (SubStr(Val, 1, 1) == "#") ? SubStr(Val, 2) : Val
		if (StrLen(Hex) != 6) {
				throw Error(Format("_shared/modules/hotstrings/defaults.toml — couleur hex invalide : [{1}] {2} = {3}", Section, Key, Val))
		}
		return "#" . Hex
}

; Initialise the module. Must be called before any Resolve/Set call.
; The path is shared with Hammerspoon so both drivers can read each other's
; edits after a reload.
HotstringsConfigInit(OverridePath) {
		global _HotstringsOverridesPath, _HotstringsOverrides
		global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
		_HotstringsOverridesPath    := OverridePath
		_HotstringsOverrides        := _ParseOverrides(OverridePath)
		_HotstringsWordDelimiters   := _ParseGlobalKey(OverridePath, "word_delimiters")
		_HotstringsConsumedDelimiters := _ParseGlobalKey(OverridePath, "consumed_delimiters")
		HotstringsResolveBumpGen()
		try LoggerInfo("HotstringsConfig", "Initialized (override file: '{1}').", OverridePath)
}

; Read a quoted-string key from the ``[__global__]`` section of the override file.
; Returns "" when the file is missing or the key is absent.
_ParseGlobalKey(Path, KeyName) {
		if (Path == "" or !FileExist(Path)) {
				return ""
		}
		InGlobal := false
		Pattern  := "^" . KeyName . "\s*=\s*" . '"' . "((?:[^" . '"' . "\\]|\\.)*)" . '"' . "\s*$"
		loop read, Path {
				Line := Trim(A_LoopReadLine, " `t")
				if (Line == "[__global__]") {
						InGlobal := true
						continue
				}
				if (InGlobal and SubStr(Line, 1, 1) == "[") {
						break
				}
				if InGlobal and RegExMatch(Line, Pattern, &M) {
						return UnescapeTomlString(M[1])
				}
		}
		return ""
}

; Return the effective word-delimiter string: user override when present,
; otherwise the engine default ``HOTSTRINGS_DEFAULT_WORD_DELIMITERS``.
HotstringsGetWordDelimiters() {
		global _HotstringsWordDelimiters, HOTSTRINGS_DEFAULT_WORD_DELIMITERS
		return (_HotstringsWordDelimiters != "") ? _HotstringsWordDelimiters : HOTSTRINGS_DEFAULT_WORD_DELIMITERS
}

; Persist a new word-delimiter string and publish it to the live engine only
; after the complete override candidate is durable. The builder preserves the
; consumed set from the snapshot taken after write admission.
HotstringsSetWordDelimiters(Delimiters, WriterFn := 0, ReplaceFn := 0) {
		return HotstringsCommitDelimiterUpdate(
				(CurrentWord, CurrentConsumed) => {
						Word: Delimiters,
						Consumed: CurrentConsumed
				}, WriterFn, ReplaceFn)
}

; Return the effective consumed-delimiter string: user override when present,
; otherwise the catalogue-derived default (the magic key is consumed out of the
; box, matching macOS).
HotstringsGetConsumedDelimiters() {
		global _HotstringsConsumedDelimiters, HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
		return (_HotstringsConsumedDelimiters != "") ? _HotstringsConsumedDelimiters : HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
}

; Persist a new consumed-delimiter string and publish the effective catalogue
; default when the stored candidate is empty.
HotstringsSetConsumedDelimiters(Consumed, WriterFn := 0, ReplaceFn := 0) {
		return HotstringsCommitDelimiterUpdate(
				(CurrentWord, CurrentConsumed) => {
						Word: CurrentWord,
						Consumed: Consumed
				}, WriterFn, ReplaceFn)
}

; Change both delimiter sets in one whole-file transaction. This is the only
; safe primitive for menu actions such as adding/removing a consumed custom
; delimiter: two independent writes expose a half-applied state and let the
; second writer erase a concurrent sibling update.
HotstringsSetBothDelimiters(Delimiters, Consumed, WriterFn := 0, ReplaceFn := 0) {
		return HotstringsCommitDelimiterUpdate(
				(CurrentWord, CurrentConsumed) => {
						Word: Delimiters,
						Consumed: Consumed
				}, WriterFn, ReplaceFn)
}

; Claim the exact override store before reading any live delimiter state, ask
; BuildFn for one detached {Word, Consumed} candidate, atomically replace the
; whole file, then publish both caches and both engine variables while the same
; owner is still held. A process-wide terminal transition therefore refuses
; before even invoking BuildFn.
HotstringsCommitDelimiterUpdate(BuildFn, WriterFn := 0, ReplaceFn := 0) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				; Candidate construction, durable staging, atomic replacement and
				; logging must remain interruptible. The override-path lease supplies
				; serialization; only the final live projection becomes Critical.
				Critical("Off")
				try return HotstringsCommitDelimiterUpdate(BuildFn, WriterFn,
						ReplaceFn)
				finally Critical(InheritedCritical)
		}
		global _HotstringsOverridesPath, _HotstringsOverrides
		global _HotstringsWordDelimiters
		global _HotstringsConsumedDelimiters
		global HOTSTRINGS_DEFAULT_WORD_DELIMITERS
		global HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS

		OwnerToken := _HotstringsOverrideLeaseAcquire("change delimiters")
		if !(OwnerToken is Object)
				return false
		try {
				BoundPath := _HotstringsOverridesPath
				if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath) {
						try LoggerError("HotstringsConfig",
								"Cannot change delimiters: the admitted owner no longer owns the override path. The change is NOT persisted.")
						return false
				}
				if !HasMethod(BuildFn, "Call") {
						try LoggerError("HotstringsConfig",
								"Cannot change delimiters: the candidate builder is not callable. The change is NOT persisted.")
						return false
				}

				CurrentWord := (_HotstringsWordDelimiters != "")
						? _HotstringsWordDelimiters : HOTSTRINGS_DEFAULT_WORD_DELIMITERS
				CurrentConsumed := (_HotstringsConsumedDelimiters != "")
						? _HotstringsConsumedDelimiters : HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
				Candidate := 0
				try Candidate := BuildFn.Call(CurrentWord, CurrentConsumed)
				catch as Err {
						try LoggerError("HotstringsConfig",
								"Cannot change delimiters: candidate construction failed: {1}. The change is NOT persisted.",
								Err.Message)
						return false
				}
				if !(Candidate is Object)
						|| !Candidate.HasOwnProp("Word")
						|| !Candidate.HasOwnProp("Consumed")
						|| !(Candidate.Word is String)
						|| !(Candidate.Consumed is String) {
						try LoggerError("HotstringsConfig",
								"Cannot change delimiters: candidate must contain String Word and Consumed fields. The change is NOT persisted.")
						return false
				}

				; Store catalogue defaults canonically as an absent override. The live
				; engine still receives the effective strings after durable publication.
				WordCandidate := (Candidate.Word == HOTSTRINGS_DEFAULT_WORD_DELIMITERS)
						? "" : Candidate.Word
				ConsumedCandidate := (Candidate.Consumed == HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS)
						? "" : Candidate.Consumed

				if !_SaveOverrides(_HotstringsOverrides, WriterFn, ReplaceFn,
						WordCandidate, ConsumedCandidate, BoundPath,
						_HotstringsAuthorizeOverrideCommit.Bind(
								OwnerToken, BoundPath),
						_HotstringsPublishDelimiterCandidate.Bind(
								WordCandidate, ConsumedCandidate))
						return false

				; The in-memory publisher advanced the canonical runtime-decision
				; epoch in the same Critical span as both delimiter sets. Remove any
				; pre-commit pixels only now, after the persistence helper restored
				; interruptibility; TooltipHide performs Win32 work.
				if IsSet(HSE_InvalidateRuntimeDecisionProjection)
						HSE_InvalidateRuntimeDecisionProjection()

				try LoggerDebug("HotstringsConfig",
						"Global delimiter sets published after durable override replacement.")
				return true
		} finally _HotstringsOverrideLeaseRelease(OwnerToken)
}

; This memory-only projection runs in the same tiny Critical span as the durable
; catalogue publication. It cannot expose one live delimiter cache without the
; matching engine variable to an interrupting callback.
_HotstringsPublishDelimiterCandidate(WordCandidate, ConsumedCandidate) {
		global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
		global HOTSTRINGS_DEFAULT_WORD_DELIMITERS
		global HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
		global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
		_HotstringsWordDelimiters := WordCandidate
		_HotstringsConsumedDelimiters := ConsumedCandidate
		HSE_WORD_TERMINATORS := (WordCandidate != "")
				? WordCandidate : HOTSTRINGS_DEFAULT_WORD_DELIMITERS
		HSE_CONSUMED_DELIMITERS := (ConsumedCandidate != "")
				? ConsumedCandidate : HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS
		if IsSet(HSE_AdvanceRuntimeDecisionGeneration)
				HSE_AdvanceRuntimeDecisionGeneration()
		return 1
}

; Write (or clear) the ``word_delimiters`` key in ``[__global__]``.
_SaveGlobalWordDelimiters(Delimiters) {
		return HotstringsSetWordDelimiters(Delimiters)
}

; Compatibility entrypoint for the two historical [__global__] keys. It no
; longer owns a second truncating writer; every call joins the same atomic
; whole-file delimiter transaction as the public setters.
_SaveGlobalKey(KeyName, Value, _Unused := "", WriterFn := 0, ReplaceFn := 0) {
		if (KeyName == "word_delimiters")
				return HotstringsSetWordDelimiters(Value, WriterFn, ReplaceFn)
		if (KeyName == "consumed_delimiters")
				return HotstringsSetConsumedDelimiters(Value, WriterFn, ReplaceFn)
		try LoggerError("HotstringsConfig",
				"Cannot write unknown [__global__] key '{1}'. The change is NOT persisted.",
				KeyName)
		return false
}

_EscapeTomlString(S) {
		S := StrReplace(S, "\", "\\")
		S := StrReplace(S, '"', '\"')
		S := StrReplace(S, "`t", "\t")
		S := StrReplace(S, "`r", "\r")
		S := StrReplace(S, "`n", "\n")
		return S
}

; Parse the override TOML file. Returns an empty Map when the file is missing.
; Recognises the following header forms:
;   [category]                       — standard category (e.g. [magickey])
;   [category.section]               — section override (e.g. [magickey.repeat])
;   [ext.ext-name]                   — extension file-level override
;   [ext.ext-name.section]           — extension section override
; The full dotted key is used as the Map key for ext.* entries so it never
; collides with a bare single-word category (e.g. "ext.ergopti-demo").
_ParseOverrides(Path) {
		Result := Map()
		if (Path == "" or !FileExist(Path)) {
				return Result
		}

		Content := FileRead(Path, "UTF-8")
		CurrentCat := ""
		CurrentSec := ""
		; Tracks every section key already seen to detect duplicates
		SeenSections := Map()

		loop parse, Content, "`n", "`r" {
				Line := Trim(A_LoopField, " `t")
				if (Line == "" or SubStr(Line, 1, 1) == "#") {
						continue
				}

				; Extension section header: [ext.name.section] — 3 dotted segments
				if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &ExtSecMatch) {
						CurrentCat := "ext." . StrLower(ExtSecMatch[1])
						CurrentSec := StrLower(ExtSecMatch[2])
						SectionName := CurrentCat . "." . CurrentSec
						if SeenSections.Has(SectionName)
								try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
						SeenSections[SectionName] := true
						if !Result.Has(CurrentCat)
								Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
						if !Result[CurrentCat].Sections.Has(CurrentSec)
								Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
						continue
				}

				; Extension file header: [ext.name] — 2 dotted segments starting with "ext."
				if RegExMatch(Line, "^\[ext\.([A-Za-z0-9_\-]+)\]$", &ExtMatch) {
						CurrentCat := "ext." . StrLower(ExtMatch[1])
						CurrentSec := ""
						SectionName := CurrentCat
						if SeenSections.Has(SectionName)
								try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
						SeenSections[SectionName] := true
						if !Result.Has(CurrentCat)
								Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
						continue
				}

				; Standard section header: [category.section]
				if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\]$", &SecMatch) {
						CurrentCat := StrLower(SecMatch[1])
						CurrentSec := StrLower(SecMatch[2])
						SectionName := CurrentCat . "." . CurrentSec
						if SeenSections.Has(SectionName)
								try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
						SeenSections[SectionName] := true
						if !Result.Has(CurrentCat)
								Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
						if !Result[CurrentCat].Sections.Has(CurrentSec)
								Result[CurrentCat].Sections[CurrentSec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
						continue
				}

				; Standard category header: [category]
				if RegExMatch(Line, "^\[([A-Za-z0-9_\-]+)\]$", &CatMatch) {
						CurrentCat := StrLower(CatMatch[1])
						CurrentSec := ""
						SectionName := CurrentCat
						if SeenSections.Has(SectionName)
								try LoggerWarn("HotstringsConfig", "Duplicate section '[{1}]' in overrides file — later values will override earlier.", SectionName)
						SeenSections[SectionName] := true
						if !Result.Has(CurrentCat)
								Result[CurrentCat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
						continue
				}

				if (CurrentCat == "") {
						continue
				}

				Target := (CurrentSec != "")
						? Result[CurrentCat].Sections[CurrentSec]
						: Result[CurrentCat]

				if RegExMatch(Line, "^delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*$", &NumMatch) {
						Target.Delay := NumMatch[1] + 0
				} else if RegExMatch(Line, "^color\s*=\s*" . '"' . "((?:[^" . '"' . "\\]|\\.)*)" . '"' . "\s*$", &ColMatch) {
						Target.Color := UnescapeTomlString(ColMatch[1])
				} else if RegExMatch(Line, "^show_tooltip\s*=\s*(true|false)\s*$", &BoolMatch) {
						Target.ShowTooltip := (BoolMatch[1] == "true")
				} else if RegExMatch(Line, "^priority\s*=\s*([0-9]+)\s*$", &PrioMatch) {
						Target.Priority := PrioMatch[1] + 0
				}
		}

		return Result
}

; Single source of truth for serialising a delay (in seconds) to its on-disk
; TOML numeric string. Both backends MUST route through this so the shared
; override file and a personal file's [_meta] never diverge for the same value:
; previously the override store wrote the raw number while the config window's
; _HCW_TomlValue quantised to 3 decimals, so the same logical delay could land
; as two different strings (UI/engine drift). Delays are millisecond-quantised
; everywhere — 3 decimal places of a second == whole milliseconds.
global HOTSTRINGS_DELAY_DECIMALS := 3
HotstringsSerialiseDelay(Value) {
		global HOTSTRINGS_DELAY_DECIMALS
		Num := Value + 0
		return Format("{:." . HOTSTRINGS_DELAY_DECIMALS . "f}", Num)
}

; Serialise an override candidate and atomically publish it to disk. Callers
; pass the candidate explicitly so durable publication can precede the live Map
; swap; omitting it retains compatibility for internal full-state saves.
; Stable ordering: alphabetical category, alphabetical section.
_SaveOverrides(Overrides := unset, WriterFn := 0, ReplaceFn := 0,
		WordDelimiters := unset, ConsumedDelimiters := unset,
		TargetPath := unset, AuthorizeFn := 0, PublishFn := 0) {
		global _HotstringsOverrides, _HotstringsOverridesPath
		global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
		InheritedCritical := A_IsCritical
		if InheritedCritical
				Critical("Off")
		try {
		Path := IsSet(TargetPath) ? TargetPath : _HotstringsOverridesPath
		if !(Path is String) || Path == "" {
				try LoggerError("HotstringsConfig", "Cannot write overrides before HotstringsConfigInit has provided a target path. The change is NOT persisted.")
				return false
		}
		HasAuthorizer := !((AuthorizeFn is Integer) && AuthorizeFn == 0)
		HasPublisher := !((PublishFn is Integer) && PublishFn == 0)
		if (HasAuthorizer && !HasMethod(AuthorizeFn, "Call"))
				|| (HasPublisher && !HasMethod(PublishFn, "Call")) {
				try LoggerError("HotstringsConfig", "Cannot write overrides: a transaction callback is not callable. The change is NOT persisted.")
				return false
		}
		Source := IsSet(Overrides) ? Overrides : _HotstringsOverrides
		if !(Source is Map) {
				try LoggerError("HotstringsConfig", "Cannot write overrides: the candidate state is not a Map. The change is NOT persisted.")
				return false
		}
		WordSource := IsSet(WordDelimiters)
				? WordDelimiters : _HotstringsWordDelimiters
		ConsumedSource := IsSet(ConsumedDelimiters)
				? ConsumedDelimiters : _HotstringsConsumedDelimiters
		if !(WordSource is String) || !(ConsumedSource is String) {
				try LoggerError("HotstringsConfig", "Cannot write overrides: delimiter candidates must be strings. The change is NOT persisted.")
				return false
		}

		Out := "# Hotstrings — overrides utilisateur`n"
				. "# Édité depuis la fenêtre « Délais & couleurs hotstrings ».`n"
				. "# Ne pas mélanger les sections : chaque [category] et [category.section]`n"
				. "# ne doit apparaître qu'une seule fois.`n`n"

		; Re-emit [__global__] so a category/section edit never erases the
		; cross-driver word/consumed delimiter customisation.
		if (WordSource != "" or ConsumedSource != "") {
				Out .= "[__global__]`n"
				; Both keys share this one serializer and escape path. The explicit
				; candidates keep an uncommitted delimiter set detached from live RAM.
				if (WordSource != "")
						Out .= 'word_delimiters = "' . _EscapeTomlString(WordSource) . '"`n'
				if (ConsumedSource != "")
						Out .= 'consumed_delimiters = "' . _EscapeTomlString(ConsumedSource) . '"`n'
				Out .= "`n"
		}

		Cats := []
		for Cat in Source {
				Cats.Push(Cat)
		}
		_SortStringsInPlace(Cats)

		for _, Cat in Cats {
				if (Cat == "__global__")   ; reserved — handled above
						continue
				Entry := Source[Cat]
				; Extension keys are stored as "ext.name" — the header must be written
				; as [ext.name] (2 segments), not [ext.name] which would be ambiguous
				; when parsed back. Section headers for ext keys: [ext.name.section].
				IsExt := SubStr(Cat, 1, 4) == "ext."

				EntryPrio := Entry.HasOwnProp("Priority") ? Entry.Priority : ""
				if (Entry.Delay != "" or Entry.Color != "" or Entry.ShowTooltip != "" or EntryPrio != "") {
						Out .= "[" . Cat . "]`n"
						if (Entry.Delay != "") {
								Out .= "delay = " . HotstringsSerialiseDelay(Entry.Delay) . "`n"
						}
						if (Entry.Color != "") {
								Out .= 'color = "' . Entry.Color . '"' . "`n"
						}
						if (Entry.ShowTooltip != "") {
								Out .= "show_tooltip = " . (Entry.ShowTooltip ? "true" : "false") . "`n"
						}
						if (EntryPrio != "") {
								Out .= "priority = " . EntryPrio . "`n"
						}
						Out .= "`n"
				}

				Secs := []
				for Sec in Entry.Sections {
						Secs.Push(Sec)
				}
				_SortStringsInPlace(Secs)
				for _, Sec in Secs {
						S := Entry.Sections[Sec]
						SPrio := S.HasOwnProp("Priority") ? S.Priority : ""
						if (S.Delay != "" or S.Color != "" or S.ShowTooltip != "" or SPrio != "") {
								; Extension: [ext.name.section] — Cat already contains the dot
								Out .= "[" . Cat . "." . Sec . "]`n"
								if (S.Delay != "") {
										Out .= "delay = " . HotstringsSerialiseDelay(S.Delay) . "`n"
								}
								if (S.Color != "") {
										Out .= 'color = "' . S.Color . '"' . "`n"
								}
								if (S.ShowTooltip != "") {
										Out .= "show_tooltip = " . (S.ShowTooltip ? "true" : "false") . "`n"
								}
								if (SPrio != "") {
										Out .= "priority = " . SPrio . "`n"
								}
								Out .= "`n"
						}
				}
		}

		static STALE_TEMP_MS := 60000  ; One minute distinguishes abandoned stages from live writers
		static WriteSeq := 0
		LocalSeq := ++WriteSeq
		StagePath := Path . "." . A_ScriptHwnd . "-" . LocalSeq . ".tmp"
		_TOML_ReapStaleTemps(Path, STALE_TEMP_MS)

		FileHandle := 0
		Written := false
		try {
				if HasMethod(WriterFn, "Call") {
						Written := WriterFn.Call(StagePath, Out)
				} else {
						FileHandle := FileOpen(StagePath, "w", "UTF-8")
						if !IsObject(FileHandle)
								throw Error("FileOpen returned no staging handle")
						FileHandle.Write(Out)
						FileHandle.Close()
						FileHandle := 0
						Written := true
				}
		} catch as Err {
				if IsObject(FileHandle)
						try FileHandle.Close()
				_HotstringsRemoveOverrideStage(StagePath)
				try LoggerError("HotstringsConfig", "Failed to write override staging file for '{1}': {2}. The previous contents are intact and the change is NOT persisted.", Path, Err.Message)
				return false
		}
		if !(Written is Integer) || Written != 1 {
				_HotstringsRemoveOverrideStage(StagePath)
				try LoggerError("HotstringsConfig", "Writing override staging file for '{1}' was refused. The previous contents are intact and the change is NOT persisted.", Path)
				return false
		}

		Authorized := !HasAuthorizer
		AuthorizeError := ""
		if HasAuthorizer {
				; The authorizer is memory-only and reads both the lease table and the
				; module target. Keep that pair coherent without extending Critical over I/O.
				PreviousCritical := Critical("On")
				try {
						try Authorized := AuthorizeFn.Call()
						catch as Err {
								Authorized := false
								AuthorizeError := Err.Message
						}
				} finally Critical(PreviousCritical)
				Authorized := (Authorized is Integer) && Authorized == 1
		}

		Published := false
		ReplaceError := ""
		MoveError := 0
		if Authorized {
				; Atomic replacement can block in filesystem/AV code and must never hold
				; Critical. The exact logical owner remains held across this call.
				try Published := HasMethod(ReplaceFn, "Call")
						? ReplaceFn.Call(StagePath, Path)
						: FSAtomicMoveReplace(StagePath, Path)
				catch as Err {
						Published := false
						ReplaceError := Err.Message
				}
				Published := (Published is Integer) && Published == 1
				if !Published
						MoveError := A_LastError
		}

		LivePublished := !HasPublisher
		PublishError := ""
		if Published && HasPublisher {
				; Publication is deliberately the only post-I/O Critical span and each
				; publisher is constrained to memory projection plus generation updates.
				PreviousCritical := Critical("On")
				try {
						try LivePublished := PublishFn.Call()
						catch as Err {
								LivePublished := false
								PublishError := Err.Message
						}
				} finally Critical(PreviousCritical)
				LivePublished := (LivePublished is Integer) && LivePublished == 1
		}

		if !Authorized {
				_HotstringsRemoveOverrideStage(StagePath)
				if (AuthorizeError != "") {
						try LoggerError("HotstringsConfig",
								"Authorization before publishing override file '{1}' raised: {2}. The previous contents are intact and the change is NOT persisted.",
								Path, AuthorizeError)
				} else {
						try LoggerError("HotstringsConfig",
								"Authorization before publishing override file '{1}' was refused. The previous contents are intact and the change is NOT persisted.",
								Path)
				}
				return false
		}
		if !(Published is Integer) || Published != 1 {
				_HotstringsRemoveOverrideStage(StagePath)
				if (ReplaceError != "") {
						try LoggerError("HotstringsConfig",
								"Atomic replacement of override file '{1}' raised: {2}. The previous contents are intact and the change is NOT persisted.",
								Path, ReplaceError)
				} else {
						try LoggerError("HotstringsConfig",
								"Atomic replacement of override file '{1}' failed (Windows error {2}). The previous contents are intact and the change is NOT persisted.",
								Path, MoveError)
				}
				return false
		}
		if !LivePublished {
				if (PublishError != "") {
						try LoggerError("HotstringsConfig",
								"Override file '{1}' was replaced but live publication raised: {2}. Reload is required.",
								Path, PublishError)
				} else {
						try LoggerError("HotstringsConfig",
								"Override file '{1}' was replaced but live publication was refused. Reload is required.",
								Path)
				}
				return false
		}

		try LoggerDebug("HotstringsConfig", "Override file written: '{1}'.", Path)
		return true
		} finally {
				if InheritedCritical
						Critical(InheritedCritical)
		}
}

; Remove a rejected transaction's private stage and surface cleanup failure.
_HotstringsRemoveOverrideStage(StagePath) {
		if !FileExist(StagePath)
				return true
		try {
				FileDelete(StagePath)
				return true
		} catch as Err {
				try LoggerError("HotstringsConfig", "Failed to remove rejected override staging file '{1}': {2}.", StagePath, Err.Message)
				return false
		}
}

; In-place ascending sort of a string array (AHK v2 has no built-in for this).
_SortStringsInPlace(Arr) {
		n := Arr.Length
		i := 2
		while (i <= n) {
				Pivot := Arr[i]
				j := i - 1
				while (j >= 1 and StrCompare(Arr[j], Pivot) > 0) {
						Arr[j + 1] := Arr[j]
						j -= 1
				}
				Arr[j + 1] := Pivot
				i += 1
		}
}
