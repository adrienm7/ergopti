; infra/hotstrings/hotstrings_io.ahk

; ==============================================================================
; MODULE: Hotstrings Config — Override File I/O
; DESCRIPTION:
; Reads and writes the hotstrings override file
; (<configuration folder>\hotstrings_config.toml) that stores
; per-category/section delay, color, show_tooltip, and priority overrides
; shared between the AHK and Hammerspoon drivers.
;
; FEATURES & RATIONALE:
; 1. Cross-driver shared canon — the override file format is identical for both
;    drivers; any change from either menu takes effect on the other at reload.
; 2. Boot-time defaults loaded from _shared/hotstrings/data/catalogue/defaults.toml so
;    the AHK and macOS fallback values can never drift behind a re-typed literal.
; 3. Stable on-disk serialisation via _SaveOverrides: alphabetical category and
;    section order, HOTSTRINGS_DELAY_DECIMALS decimal places for delay values.
; 4. No [__global__] key is written: the delimiter state is config.toml leaves.
;    The strings an earlier build left here are read once and moved by
;    HotstringsDelimitersBoot.
;
; Included by infra/hotstrings/hotstrings_config.ahk.
; ==============================================================================


#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk
#Include common_autocorrection_migration.ahk

; ============================================================
; ============================================================
; ======= 1/ Override file I/O ==============================
; ============================================================
; ============================================================

; Load the cross-driver hotstring resolution defaults — the global default
; expansion delay, the global default tooltip color, and the per-category
; "personal" baseline color — from the shared canon
; (_shared/hotstrings/data/catalogue/defaults.toml), the SINGLE source shared verbatim with the
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
		Path := Dir . "\hotstrings\data\catalogue\defaults.toml"
		c    := ParseTomlFile(Path)
		if !c.Count {
				throw Error("_shared/hotstrings/data/catalogue/defaults.toml introuvable ou vide : " . Path)
		}

		GLOBAL_DEFAULT_DELAY := Float(ManifestDefaultFor(ConfigKey.HOTSTRINGS_EXPANSION_DELAY))
		DYN_HOTSTRINGS_DEFAULT_DELAY := Float(_HSDefaultsRequire(c, "delays", "dynamichotstrings_sec", Path))
		GLOBAL_DEFAULT_COLOR := _HSDefaultsRequireHex(c, "colors", "global_default", Path)
		HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"] := _HSDefaultsRequireHex(c, "colors", "personal", Path)

		try LoggerInfo("HotstringsConfig", "Shared defaults loaded (delay={1}s dyn={2}s color={3} personal={4}).",
				GLOBAL_DEFAULT_DELAY, DYN_HOTSTRINGS_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"])
}

; Source the llm_prediction baseline tint from the canonical AI loading hex
; (UI_AI_LOADING_HEX, loaded by UiStyle_LoadSharedConst() from
; _shared/core/ui/data/tooltip/constants.toml [accent_colors] ai_loading_hex) so the AI tint
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
				throw Error(Format("_shared/hotstrings/data/catalogue/defaults.toml — clé manquante : [{1}] {2} ({3})", Section, Key, Path))
		}
		return Val
}

; Like _HSDefaultsRequire but validates a "#RRGGBB" (or "RRGGBB") hex color and
; returns it normalised WITH the leading "#" (the form every consumer expects).
_HSDefaultsRequireHex(c, Section, Key, Path) {
		Val := _HSDefaultsRequire(c, Section, Key, Path)
		Hex := (SubStr(Val, 1, 1) == "#") ? SubStr(Val, 2) : Val
		if (StrLen(Hex) != 6) {
				throw Error(Format("_shared/hotstrings/data/catalogue/defaults.toml — couleur hex invalide : [{1}] {2} = {3}", Section, Key, Val))
		}
		return "#" . Hex
}

; Initialise the module. Must be called before any Resolve/Set call.
; The path is shared with Hammerspoon so both drivers can read each other's
; edits after a reload.
HotstringsConfigInit(OverridePath) {
		global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsLegacyDelimiters
		if !HotstringsCommonOverrideMigrate(OverridePath) {
				_HotstringsOverridesPath := OverridePath
				try LoggerError("HotstringsConfig", "Common autocorrection override migration was refused; prior proven overrides and delimiters remain in memory, and common families and writes are blocked.")
				return false
		}
		_HotstringsOverridesPath    := OverridePath
		try {
				_HotstringsOverrides := _ParseOverrides(OverridePath, &Legacy)
		} catch ValueError as Err {
				try LoggerError("HotstringsConfig", "The override file '{1}' is not valid TOML: {2} ({3}). No user override applies until it is repaired.",
						OverridePath, Err.Message, Err.Extra)
				return false
		}
		; The word and consumed delimiter strings of earlier builds: read once so
		; HotstringsDelimitersBoot can move them to config.toml, never used as a state.
		_HotstringsLegacyDelimiters := Legacy
		HotstringsResolveBumpGen()
		try LoggerInfo("HotstringsConfig", "Initialized (override file: '{1}').", OverridePath)
}

; This receipt belongs to one actual parsed/published Map identity. It carries
; no reference back to that Map, so replaced owners form no reference cycle.
_HotstringsOverrideBindSource(Owner, Path, Snapshot) {
	if !(Owner is Map) || !(Snapshot is Map)
			|| (Snapshot.Get("status", "") != FS_STATUS_OK && Snapshot.Get("status", "") != FS_STATUS_ABSENT)
			|| !(Snapshot.Get("content", 0) is String)
		throw ValueError("An override source receipt requires an exact classified image.")
	Receipt := { MapIdentity: ObjPtr(Owner), PathKey: _ConfigWriteLeaseKey(Path),
		Source: Map("status", Snapshot["status"], "content", Snapshot["content"]) }
	Owner.DefineProp("_HotstringsSourceReceipt", {Value: Receipt})
	return Receipt
}

_HotstringsOverrideSourceFor(Owner, Path) {
	if !(Owner is Map) || !Object.Prototype.HasOwnProp.Call(Owner, "_HotstringsSourceReceipt")
		return 0
	Property := Object.Prototype.GetOwnPropDesc.Call(Owner, "_HotstringsSourceReceipt")
	if !Property.HasOwnProp("Value")
		return 0
	Receipt := Property.Value
	if !IsObject(Receipt) || !Receipt.HasOwnProp("MapIdentity") || Receipt.MapIdentity != ObjPtr(Owner)
			|| !Receipt.HasOwnProp("PathKey") || Receipt.PathKey != _ConfigWriteLeaseKey(Path)
			|| !Receipt.HasOwnProp("Source") || !(Receipt.Source is Map)
		return 0
	return Receipt
}

_HotstringsOverrideCommitMemoryCurrent(Origin, Receipt, Path, RequiresLive, NativeOwnerToken := 0) {
	global _HotstringsOverrides
	if _HotstringsOverrideSourceFor(Origin, Path) != Receipt || (RequiresLive && Origin != _HotstringsOverrides)
		return false
	; Only the actual lease-table producer may supply this internal token.
	; No arbitrary authorization callback executes in this pure final predicate.
	if !((NativeOwnerToken is Integer) && NativeOwnerToken == 0)
		if !(NativeOwnerToken is Object) || !_HotstringsAuthorizeOverrideCommit(NativeOwnerToken, Path)
			return false
	return _HotstringsOverrideSourceFor(Origin, Path) == Receipt
		&& (!RequiresLive || Origin == _HotstringsOverrides)
}

_HotstringsOverrideCommitSourceCurrent(Origin, Receipt, Path, AuthorizeFn, HasAuthorizer, RequiresLive, ReadPath := unset) {
	if !_HotstringsOverrideCommitMemoryCurrent(Origin, Receipt, Path, RequiresLive)
		return false
	if HasAuthorizer && !_FSNativeAdmissionAccepted(AuthorizeFn)
		return false
	return _HotstringsOverrideCommitMemoryCurrent(Origin, Receipt, Path, RequiresLive)
		&& _FSSourceIsUnchanged(IsSet(ReadPath) ? ReadPath : Path, Receipt.Source)
}

_HotstringsOverrideCreateHeldStage(State, Folder, Name, Attributes) {
	State.handle := _FSCreateHeldStage(Folder, Name, Attributes)
	return State.handle
}

_HotstringsOverrideHeldPreflight(State, PhysicalPath, Content, ExpectedSource, MemoryAdmission) {
	if !MemoryAdmission.Call()
		return false
	_FSRewind(State.handle)
	Readback := _FSReadUtf8ExactHandle(State.handle, 0, false)
	if !(Readback is String) || !(Readback == Content)
		return false
	; Source I/O precedes the final pure memory predicate and native rename.
	; This does not claim a kernel CAS against another process's source edits.
	return _FSSourceIsUnchanged(PhysicalPath, ExpectedSource.Source)
}

; A decoded replacement character is not proof of the source bytes it replaces.
; Keep empty valid input distinct from a failed exact native UTF-8 read.
_HotstringsOverrideReadDocument(Path, &Records := 0, &Physical := 0, &Snapshot := 0) {
	Snapshot := FSReadWithStatus(Path)
	if Snapshot["status"] != FS_STATUS_OK && Snapshot["status"] != FS_STATUS_ABSENT
		throw ValueError("Hotstring overrides must be readable exact UTF-8.")
	; Most installs have no override file: its empty document needs no parse,
	; which every boot paid (startup smoke, 2026-11-07).
	if Snapshot["status"] == FS_STATUS_ABSENT {
		Records := [], Physical := []
		return _TOML_DocumentTable()
	}
	return TOML_ParseDocument(Snapshot["content"], &Records, &Physical)
}

; Read a quoted-string key from the ``[__global__]`` section of the override file.
; Returns "" when the file is missing or the key is absent.
_ParseGlobalKey(Path, KeyName) {
	if Path == "" || !FileExist(Path)
		return ""
	; Legacy migration consumes the same decoded identities and strings as the
	; override owner. A different scanner could falsely retire unconsumed data.
	Document := _HotstringsOverrideReadDocument(Path)
	if !Document.Has("__global__") || !(Document["__global__"] is Map)
		return ""
	Values := Document["__global__"]
	return Values.Has(KeyName) && Values[KeyName] is String ? Values[KeyName] : ""
}

; Return the effective word-delimiter string the engine matches, derived from the
; delimiter settings in config.toml (see terminator_records.ahk).
HotstringsGetWordDelimiters() {
		return HotstringsTerminatorStrings().Word
}

; Return the effective consumed-delimiter string: the characters of the enabled
; delimiters that are swallowed by the expansion rather than typed after it.
HotstringsGetConsumedDelimiters() {
		return HotstringsTerminatorStrings().Consumed
}

; Boot step, once the configuration and the delimiter owner exist: moves the word
; and consumed strings of the override file (earlier builds) to config.toml
; leaves and records, then rewrites the override file without them. Idempotent:
; a failed step leaves the strings in place and the next boot retries.
; @param MigrateFn Optional seam standing for HotstringsTerminatorMigrateStrings.
; @returns {Integer} True when there was nothing to move or the move is durable.
HotstringsDelimitersBoot(MigrateFn := 0) {
		global _HotstringsLegacyDelimiters, _HotstringsOverrides, _HotstringsOverridesPath
		if !(_HotstringsLegacyDelimiters is Object)
				return true
		Legacy := _HotstringsLegacyDelimiters
		if Legacy.Word == "" and Legacy.Consumed == ""
				return true
		Origin := _HotstringsOverrideSourceFor(_HotstringsOverrides, _HotstringsOverridesPath)
		if !IsObject(Origin) || !_FSSourceIsUnchanged(_HotstringsOverridesPath, Origin.Source) {
				try LoggerError("HotstringsConfig", "Cannot retire legacy delimiter strings because the admitted source changed or is unavailable. Reload is required.")
				return false
		}
		RetiredLegacy := { Word: Legacy.Word, Consumed: Legacy.Consumed }
		Moved := HasMethod(MigrateFn, "Call")
				? MigrateFn.Call(RetiredLegacy.Word, RetiredLegacy.Consumed)
				: HotstringsTerminatorMigrateStrings(RetiredLegacy.Word, RetiredLegacy.Consumed)
		if !(Moved is Integer) || Moved != 1 {
				try LoggerError("HotstringsConfig",
						"The delimiter strings of the override file could not be moved to config.toml; the delimiters keep their catalogue state for this session and the move is retried at the next start.")
				return false
		}
		OwnerToken := _HotstringsOverrideLeaseAcquire("retire delimiter strings")
		Persisted := false
		if (OwnerToken is Object) {
				try Persisted := _HotstringsPersistOverrideCandidate(_HotstringsOverrides, OwnerToken,
						_HotstringsOverridesPath, 0, 0, RetiredLegacy, Origin)
				finally _HotstringsOverrideLeaseRelease(OwnerToken)
		}
		if !Persisted {
				try LoggerError("HotstringsConfig",
						"The override file could not be rewritten without its delimiter strings; the move is retried at the next start.")
				return false
		}
		_HotstringsLegacyDelimiters := { Word: "", Consumed: "" }
		return true
}

_EscapeTomlString(S) {
		return TOML_EscapeBasicStringContents(S)
}

_HotstringsOverrideIdentifiersAreValid(CategoryName, SectionName := "") {
		; The loader reserves bare ext for extension tables, never a category.
		if !(CategoryName is String) || CategoryName == "__global__"
				|| StrLower(CategoryName) == "ext"
				|| !RegExMatch(CategoryName,
					"^(?:ext\.[A-Za-z0-9_-]+|[A-Za-z0-9_-]+)$")
				return false
		return SectionName is String
				&& (SectionName == ""
					|| RegExMatch(SectionName, "^[A-Za-z0-9_-]+$"))
}

_HotstringsOverrideCandidateIdentifiersAreValid(Source, &Detail) {
		Detail := ""
		for CategoryName, Entry in Source {
				if !_HotstringsOverrideIdentifiersAreValid(CategoryName) {
						Detail := "invalid category identifier"
						return false
				}
				if !IsObject(Entry) || !Entry.HasOwnProp("Sections")
						|| !(Entry.Sections is Map) {
						Detail := "category '" . CategoryName
								. "' has no section Map"
						return false
				}
				for SectionName in Entry.Sections {
						if _HotstringsOverrideIdentifiersAreValid(
								CategoryName, SectionName)
								continue
						Detail := "invalid section identifier under category '"
								. CategoryName . "'"
						return false
				}
		}
		return true
}

; One category-level override record. Delay is the EFFECTIVE delay in seconds
; (0 = unlimited, "" = none); it is stored in the file as an offset of the base
; expansion delay. PendingOffset holds a parsed offset until the base is known,
; StoredOffset retains the finite intent even when effective delay clamps;
; LegacyDelay is an absolute delay of an earlier build until boot migration.
_HotstringsNewOverrideEntry() {
		return { Delay: "", PendingOffset: "", StoredOffset: "", LegacyDelay: "", Color: "", ShowTooltip: "",
				Priority: "", Sections: Map() }
}

; One section-level override record, same fields as the category's.
_HotstringsNewOverrideSection() {
		return { Delay: "", PendingOffset: "", StoredOffset: "", LegacyDelay: "", Color: "", ShowTooltip: "",
				Priority: "" }
}

; Parse the override TOML file. Returns an empty Map when the file is missing.
; A file that is not valid TOML (a duplicate key or table, an unclosed header, a
; key with no value) raises, as the shared reader does on the other drivers
; (_shared/tests/corpus/hotstrings/override_parse_vectors.json): the caller
; decides how a whole unreadable file is reported.
; Recognises the following header forms:
;   [category]                       — standard category (e.g. [magickey])
;   [category.section]               — section override (e.g. [magickey.repeat])
;   [ext.ext-name]                   — extension file-level override
;   [ext.ext-name.section]           — extension section override
; The full dotted key is used as the Map key for ext.* entries so it never
; collides with a bare single-word category (e.g. "ext.ergopti-demo").
; Decode owned scalar leaves once through the canonical typed document model.
; Wrong types retain the shared parser's ignored-leaf policy, without coercion.
_HotstringsOverrideProjectFields(Values, Target) {
	if Values.Has("delay_offset") {
		Value := Values["delay_offset"]
		if Value is Number && TickTryDurationMsFromSeconds(Abs(Value), &Milliseconds)
			Target.PendingOffset := Value
	}
	if Values.Has("delay_unlimited") {
		Value := Values["delay_unlimited"]
		if Value is TOML_Bool && Value.Value
			Target.Delay := 0
	}
	if Values.Has("delay") {
		Value := Values["delay"]
		if Value is Number && TickTryDurationMsFromSeconds(Value, &Milliseconds)
			Target.LegacyDelay := Value
	}
	if Values.Has("color") && Values["color"] is String
		Target.Color := Values["color"]
	if Values.Has("show_tooltip") && Values["show_tooltip"] is TOML_Bool
		Target.ShowTooltip := Values["show_tooltip"].Value
	if Values.Has("priority") && HotstringsTryPriority(Values["priority"], &Priority)
		Target.Priority := Priority
}

_HotstringsOverrideProjectCategory(Result, CategoryName, Values) {
	if !_HotstringsOverrideIdentifiersAreValid(CategoryName) || !(Values is Map)
		return
	if !Result.Has(CategoryName)
		Result[CategoryName] := _HotstringsNewOverrideEntry()
	Entry := Result[CategoryName]
	_HotstringsOverrideProjectFields(Values, Entry)
	for Name, Section in Values {
		if !(Section is Map) || !_HotstringsOverrideIdentifiersAreValid(CategoryName, Name)
				|| Name == ""
			continue
		SectionName := StrLower(Name)
		if !Entry.Sections.Has(SectionName)
			Entry.Sections[SectionName] := _HotstringsNewOverrideSection()
		_HotstringsOverrideProjectFields(Section, Entry.Sections[SectionName])
	}
}

_ParseOverrides(Path, &Legacy := 0) {
	Result := Map(), Legacy := { Word: "", Consumed: "" }
	if Path == ""
		return Result
	Document := _HotstringsOverrideReadDocument(Path, &Records, &Physical, &Snapshot)
	for Record in Physical
		if Record.Kind == "opaque"
			throw ValueError("The override file contains an uninterpreted TOML record.")
	for Name, Values in Document {
		if Name == "__global__" || !(Values is Map)
			continue
		if StrLower(Name) == "ext" {
			for ExtensionName, Extension in Values
				_HotstringsOverrideProjectCategory(Result, "ext." . StrLower(ExtensionName), Extension)
		} else
			_HotstringsOverrideProjectCategory(Result, StrLower(Name), Values)
	}
	if Document.Has("__global__") && Document["__global__"] is Map {
		Values := Document["__global__"]
		if Values.Has("word_delimiters") && Values["word_delimiters"] is String
			Legacy.Word := Values["word_delimiters"]
		if Values.Has("consumed_delimiters") && Values["consumed_delimiters"] is String
			Legacy.Consumed := Values["consumed_delimiters"]
	}
	_HotstringsOverrideBindSource(Result, Path, Snapshot)
	return Result
}

; The full-state serializer cannot carry foreign leaves or deeper tables.
; Readers may ignore them under the shared projection policy; writers must
; refuse instead of converting that read policy into durable data deletion.
_HotstringsOverrideLeafIsRepresentable(Key, Value) {
	switch Key {
		case "delay_offset":
			return Value is Number && TickTryDurationMsFromSeconds(Abs(Value), &Milliseconds)
		case "delay":
			return Value is Number && TickTryDurationMsFromSeconds(Value, &Milliseconds)
		case "delay_unlimited", "show_tooltip":
			return Value is TOML_Bool
		case "color":
			return Value is String
		case "priority":
			return HotstringsTryPriority(Value, &Priority)
	}
	return false
}

_HotstringsOverrideCategoryIsRepresentable(CategoryName, Values, Seen) {
	if !_HotstringsOverrideIdentifiersAreValid(CategoryName) || !(Values is Map)
			|| Seen.Has(CategoryName)
		return false
	Seen[CategoryName] := true
	Sections := Map()
	for Key, Value in Values {
		if Value is Map {
			if Key == "" || !_HotstringsOverrideIdentifiersAreValid(CategoryName, Key)
					|| Sections.Has(StrLower(Key))
				return false
			Sections[StrLower(Key)] := true
			for Leaf, Scalar in Value
				if !_HotstringsOverrideLeafIsRepresentable(Leaf, Scalar)
					return false
		} else if !_HotstringsOverrideLeafIsRepresentable(Key, Value)
			return false
	}
	return true
}

_HotstringsOverrideSourceIsRepresentable(Path, &Detail, RetiredLegacy := 0) {
	Detail := ""
	if !FileExist(Path)
		return true
	try {
		Document := _HotstringsOverrideReadDocument(Path, &Records, &Physical)
		for Record in Physical
			if Record.Kind == "opaque"
				throw ValueError("an uninterpreted TOML record")
		Seen := Map()
		for Name, Values in Document {
			if Name == "__global__" {
				; Ordinary writes cannot retire nonempty migration source strings.
				; Only the boot call carrying its acknowledged exact values may.
				if !(Values is Map)
					throw ValueError("an unsupported reserved global value")
				for Key, Value in Values
					if (Key != "word_delimiters" && Key != "consumed_delimiters") || !(Value is String)
						throw ValueError("an unowned reserved global leaf")
				Word := Values.Get("word_delimiters", ""), Consumed := Values.Get("consumed_delimiters", "")
				if Word != "" || Consumed != "" {
					if !IsObject(RetiredLegacy) || !RetiredLegacy.HasOwnProp("Word")
							|| !RetiredLegacy.HasOwnProp("Consumed")
							|| !(RetiredLegacy.Word is String) || !(RetiredLegacy.Consumed is String)
							|| !(Word == RetiredLegacy.Word) || !(Consumed == RetiredLegacy.Consumed)
						throw ValueError("legacy delimiter strings have no matching durable migration receipt")
				}
				continue
			}
			if StrLower(Name) == "ext" && Values is Map {
				for ExtensionName, Extension in Values
					if !_HotstringsOverrideCategoryIsRepresentable("ext." . StrLower(ExtensionName), Extension, Seen)
						throw ValueError("an unsupported extension override tree")
			} else if !_HotstringsOverrideCategoryIsRepresentable(StrLower(Name), Values, Seen)
				throw ValueError("an unsupported category override tree")
		}
		return true
	} catch as Err {
		Detail := Err.Message
		return false
	}
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
		if !TickTryDurationMsFromSeconds(Value, &DelayMs)
				throw ValueError("Hotstring delay must fit the elapsed-tick domain.")
		; Zero alone means unlimited. Preserve a positive finite intention even
		; when its sub-millisecond precision rounds below the storage grid.
		FiniteValue := Value > 0 ? Max(Value, 10 ** -HOTSTRINGS_DELAY_DECIMALS) : Value
		return Format("{:." . HOTSTRINGS_DELAY_DECIMALS . "f}", FiniteValue)
}

; The signed number of seconds a delay override adds to the base expansion
; delay, on the same millisecond grid as every other delay.
HotstringsSerialiseDelayOffset(Offset) {
		global HOTSTRINGS_DELAY_DECIMALS
		if !TickTryDurationMsFromSeconds(Abs(Offset), &OffsetMs)
				throw ValueError("Hotstring delay offset must fit the elapsed-tick domain.")
		return Format("{:." . HOTSTRINGS_DELAY_DECIMALS . "f}", Offset)
}

; The delay line one override record contributes to the file, "" when it has
; none: an unlimited delay (0) is its own flag, any other delay is stored as the
; offset of the base expansion delay, and an offset not yet applied (the base
; was unknown when the file was read) is written back unchanged.
_HotstringsDelayLine(Record, Base) {
		if (Record.Delay != "") {
				if (Record.Delay == 0)
						return "delay_unlimited = true`n"
				Offset := Record.HasOwnProp("StoredOffset") && Record.StoredOffset != ""
						? Record.StoredOffset : Record.Delay - Base
				return "delay_offset = " . HotstringsSerialiseDelayOffset(Offset) . "`n"
		}
		if (Record.HasOwnProp("PendingOffset") and Record.PendingOffset != "")
				return "delay_offset = " . HotstringsSerialiseDelayOffset(Record.PendingOffset) . "`n"
		; A full-state edit can run before boot adopts an absolute legacy delay.
		; Preserve that known intention until its explicit migration or removal.
		if Record.HasOwnProp("LegacyDelay") && Record.LegacyDelay != ""
				return "delay = " . HotstringsSerialiseDelay(Record.LegacyDelay) . "`n"
		return ""
}

; Serialise an override candidate and atomically publish it to disk. Callers
; pass the candidate explicitly so durable publication can precede the live Map
; swap; omitting it retains compatibility for internal full-state saves.
; Stable ordering: alphabetical category, alphabetical section.
_SaveOverrides(Overrides := unset, WriterFn := 0, ReplaceFn := 0,
		TargetPath := unset, AuthorizeFn := 0, PublishFn := 0, RetiredLegacy := 0, ExpectedSource := 0, NativeOwnerToken := 0) {
		global _HotstringsOverrides, _HotstringsOverridesPath
		InheritedCritical := A_IsCritical
		if InheritedCritical
				Critical("Off")
		try {
		Path := IsSet(TargetPath) ? TargetPath : _HotstringsOverridesPath
		if !(Path is String) || Path == "" {
				try LoggerError("HotstringsConfig", "Cannot write overrides before HotstringsConfigInit has provided a target path. The change is NOT persisted.")
				return false
		}
		NativeAdapters := (WriterFn is Integer) && WriterFn == 0
				&& (ReplaceFn is Integer) && ReplaceFn == 0
		if NativeAdapters {
				try PhysicalPath := FSResolveAbsolutePath(Path)
				catch as Err {
						try LoggerError("HotstringsConfig", "Cannot capture the override publication target: {1}.", Err.Message)
						return false
				}
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
		Origin := Source
		if IsObject(ExpectedSource) {
				if _HotstringsOverrideSourceFor(Source, Path) != ExpectedSource
						Origin := _HotstringsOverrides
		} else
				ExpectedSource := _HotstringsOverrideSourceFor(Source, Path)
		if !IsObject(ExpectedSource) || _HotstringsOverrideSourceFor(Origin, Path) != ExpectedSource {
				try LoggerError("HotstringsConfig", "Cannot write overrides without the source receipt captured with the candidate. Reload is required.")
				return false
		}
		if !((NativeOwnerToken is Integer) && NativeOwnerToken == 0) && !(NativeOwnerToken is Object)
				return false
		HasNativeOwner := NativeOwnerToken is Object
		FinalAdmission := _HotstringsOverrideCommitSourceCurrent.Bind(Origin, ExpectedSource, Path,
				AuthorizeFn, HasAuthorizer, HasPublisher, NativeAdapters ? PhysicalPath : Path)
		MemoryAdmission := _HotstringsOverrideCommitMemoryCurrent.Bind(Origin, ExpectedSource, Path,
				HasPublisher, NativeOwnerToken)
		; Runtime Set/Clear/boot gateways supply a real owned lease and therefore
		; use the pure final predicate. Legacy direct custom authorizers retain
		; their existing callback-then-source-check ordering at the native gate.
		NativeAdmission := HasNativeOwner || !HasAuthorizer ? MemoryAdmission : FinalAdmission
		; An optional arbitrary authorizer still runs before the source witness.
		; Real runtime lease authority is separately resampled without callbacks.
		if !FinalAdmission.Call() || !MemoryAdmission.Call() {
				try LoggerError("HotstringsConfig", "Cannot write overrides because their admitted source changed. Reload is required.")
				return false
		}

		if !_HotstringsOverrideCandidateIdentifiersAreValid(
				Source, &IdentifierDetail) {
				try LoggerError("HotstringsConfig",
						"Cannot write overrides: {1}. The change is NOT persisted.",
						IdentifierDetail)
				return false
		}

		if !_HotstringsOverrideSourceIsRepresentable(NativeAdapters ? PhysicalPath : Path, &SourceDetail, RetiredLegacy) {
				try LoggerError("HotstringsConfig",
						"Cannot rewrite overrides without losing source data: {1}. The existing file and live state are unchanged.", SourceDetail)
				return false
		}

		Out := "# Hotstrings — overrides utilisateur`n"
				. "# Édité depuis la fenêtre « Délais & couleurs hotstrings ».`n"
				. "# Ne pas mélanger les sections : chaque [category] et [category.section]`n"
				. "# ne doit apparaître qu'une seule fois.`n`n"

		; Delays are stored as offsets of the base expansion delay, so the file
		; stays valid when the base changes.
		BaseDelay := HotstringsBaseDelay()
		Cats := []
		for Cat in Source {
				Cats.Push(Cat)
		}
		_SortStringsInPlace(Cats)

		for _, Cat in Cats {
				if (Cat == "__global__")   ; reserved: no key of it is written any more
						continue
				Entry := Source[Cat]
				; Extension keys are stored as "ext.name" — the header must be written
				; as [ext.name] (2 segments), not [ext.name] which would be ambiguous
				; when parsed back. Section headers for ext keys: [ext.name.section].
				IsExt := SubStr(Cat, 1, 4) == "ext."

				EntryPrio := Entry.HasOwnProp("Priority") ? Entry.Priority : ""
				EntryDelay := _HotstringsDelayLine(Entry, BaseDelay)
				if (EntryDelay != "" or Entry.Color != "" or Entry.ShowTooltip != "" or EntryPrio != "") {
						Out .= "[" . Cat . "]`n"
						Out .= EntryDelay
						if (Entry.Color != "") {
								Out .= "color = " . TOML_RenderString(Entry.Color) . "`n"
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
						SecDelay := _HotstringsDelayLine(S, BaseDelay)
						if (SecDelay != "" or S.Color != "" or S.ShowTooltip != "" or SPrio != "") {
								; Extension: [ext.name.section] — Cat already contains the dot
								Out .= "[" . Cat . "." . Sec . "]`n"
								Out .= SecDelay
								if (S.Color != "") {
										Out .= "color = " . TOML_RenderString(S.Color) . "`n"
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

		static WriteSeq := 0
		LocalSeq := ++WriteSeq
		StagePath := Path . "." . A_ScriptHwnd . "-" . LocalSeq . ".tmp"
		if NativeAdapters {
				_TOML_ReapStaleTemps(PhysicalPath, StaleTempAgeMs())
				Stage := {handle: -1}
				Suffix := "." . A_ScriptHwnd . "-" . LocalSeq . ".tmp"
				Preflight := _HotstringsOverrideHeldPreflight.Bind(Stage, PhysicalPath, Out, ExpectedSource, MemoryAdmission)
				Published := FSWriteReplaceOwned(PhysicalPath, Out, Suffix, &StageDetail,
						_HotstringsOverrideCreateHeldStage.Bind(Stage), Preflight, NativeAdmission,
						ExpectedSource.Source["status"] == FS_STATUS_OK, &Publication)
				if !((Published is Integer) && Published == 1) {
						if Publication.renamed && !Publication.durable
								return ConfigReportPersistenceFailure("hotstring override publication", 0,
										"A native replacement occurred without complete durable acknowledgement. Verify the saved image and reload if the live source is stale. " . StageDetail, false)
						try LoggerError("HotstringsConfig", "Owned override publication was refused: {1}. No target was replaced.", StageDetail)
						return false
				}
				Authorized := true, ReplaceError := "", MoveError := 0
		} else {
		_TOML_ReapStaleTemps(Path, StaleTempAgeMs())

		Written := false
		UsesCustomWriter := HasMethod(WriterFn, "Call")
		try {
				if UsesCustomWriter {
						Written := WriterFn.Call(StagePath, Out)
				} else {
						Written := FSWriteDurable(StagePath, Out)
				}
		} catch as Err {
				_HotstringsRemoveOverrideStage(StagePath)
				try LoggerError("HotstringsConfig", "Failed to write override staging file for '{1}': {2}. The previous contents are intact and the change is NOT persisted.", Path, Err.Message)
				return false
		}
		if !(Written is Integer) || Written != 1 {
				_HotstringsRemoveOverrideStage(StagePath)
				try LoggerError("HotstringsConfig", "Writing override staging file for '{1}' was refused. The previous contents are intact and the change is NOT persisted.", Path)
				return false
		}
		if !UsesCustomWriter && !FSUtf8ExactMatches(StagePath, Out) {
				_HotstringsRemoveOverrideStage(StagePath)
				try LoggerError("HotstringsConfig", "Override staging file for '{1}' failed exact readback validation. The previous contents are intact and the change is NOT persisted.", Path)
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
				; The native gate consumes the retained source and logical admission
				; immediately before moving. Optional adapters remain outside Critical.
				try {
						if HasMethod(ReplaceFn, "Call") {
								if FinalAdmission.Call()
										Published := ReplaceFn.Call(StagePath, Path)
						}
						else if ExpectedSource.Source["status"] == FS_STATUS_ABSENT
								Published := FSConfigAtomicMoveCreate(StagePath, Path, FinalAdmission)
						else
								Published := FSConfigAtomicMoveReplace(StagePath, Path, &MoveError, FinalAdmission)
				}
				catch as Err {
						Published := false
						ReplaceError := Err.Message
				}
				Published := (Published is Integer) && Published == 1
				if !Published
						MoveError := A_LastError
		}

		}
		if Published && !FSUtf8ExactMatches(NativeAdapters ? PhysicalPath : Path, Out) {
				if !NativeAdapters
						_HotstringsRemoveOverrideStage(StagePath)
				if NativeAdapters
						return ConfigReportPersistenceFailure("hotstring override publication", 0,
								"Native replacement was acknowledged, but later readback could not confirm the candidate. Verify the current file and reload.", false)
				try LoggerError("HotstringsConfig", "The published override image is not the staged candidate. Reload is required.")
				return false
		}

		LivePublished := !HasPublisher
		PublishError := ""
		if Published && HasPublisher {
				; Publication is deliberately the only post-I/O Critical span and each
				; publisher is constrained to memory projection plus generation updates.
				PreviousCritical := Critical("On")
				try {
						try {
								LivePublished := MemoryAdmission.Call() ? PublishFn.Call() : false
								if (LivePublished is Integer) && LivePublished == 1
										_HotstringsOverrideBindSource(Source, Path, Map("status", FS_STATUS_OK, "content", Out))
						} catch as Err {
								LivePublished := false
								PublishError := Err.Message
						}
				} finally Critical(PreviousCritical)
				LivePublished := (LivePublished is Integer) && LivePublished == 1
		}

		if Published && !HasPublisher
				_HotstringsOverrideBindSource(Source, Path, Map("status", FS_STATUS_OK, "content", Out))

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
				if NativeAdapters
						return ConfigReportPersistenceFailure("hotstring override publication", 0,
								"Native replacement occurred, but the live projection was not acknowledged. Verify the current file and reload. " . PublishError, false)
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
