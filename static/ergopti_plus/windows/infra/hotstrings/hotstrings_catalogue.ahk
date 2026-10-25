; infra/hotstrings/hotstrings_catalogue.ahk

; ==============================================================================
; MODULE: Hotstrings Config — Resolve API & Terminator Catalogue
; DESCRIPTION:
; Public resolution API (HotstringsResolve, HotstringsResolveExt,
; HotstringsSetOverride, HotstringsClearOverride, HotstringsConfigReload,
; HotstringsConfigPath) and the terminator catalogue helpers shared by the
; tray word-expander submenu and the config-window checkbox grid.
;
; FEATURES & RATIONALE:
; 1. Memoised resolution — HotstringsResolve caches (category, section) results
;    in _HSResolveCache and invalidates on every override mutation, so the
;    prefix watcher pays no TOML re-parse cost per keystroke.
; 2. Extension overrides — HotstringsResolveExt resolves [ext.extid] keys from
;    the shared override file, keeping bundled-extension delays editable from
;    the UI without touching per-extension TOML.
; 3. Terminator catalogue helpers are pure (no I/O); the delimiter state is a
;    set of config.toml leaves owned by terminator_records.ahk.
;
; Included by infra/hotstrings/hotstrings_config.ahk.
; ==============================================================================

; The generated config-key constants; #Include skips a file the entry script
; already loaded, so a unit harness that loads this file alone still resolves them.
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk




; ============================================================
; ============================================================
; ======= 1/ Public API =====================================
; ============================================================
; ============================================================

; Resolve the effective delay (seconds) and color (hex string, may be empty)
; for a given (category, section) pair. ``Section`` may be empty for the
; file-level lookup. The returned object always exposes both fields.
;
; Resolution order — first non-empty wins:
;   1. user_override.section
;   2. user_override.file
;   3. toml.section
;   4. toml.file
;   5. the base expansion delay (delay only); color stays empty.
HotstringsResolve(CategoryName, SectionName := "") {
		if IsSet(PersonalFileControls) && PersonalFileControls.owners.Has(CategoryName)
				return PersonalFileControls.owners[CategoryName].Resolve(SectionName)
		global _HSResolveCache, _HSResolveGen
		Key := StrLower(CategoryName) . "|" . (SectionName != "" ? FoldAsciiLower(SectionName) : "")
		if (_HSResolveCache.Has(Key)) {
				Cached := _HSResolveCache[Key]
				if (Cached.gen == _HSResolveGen)
						return Cached.val
		}
		Result := _HotstringsResolveUncached(CategoryName, SectionName)
		_HSResolveCache[Key] := { gen: _HSResolveGen, val: Result }
		return Result
}

; Invalidate every memoised HotstringsResolve result. Called from each override
; mutation and from the TOML group-config invalidation in toml_loader.ahk.
HotstringsResolveBumpGen() {
		global _HSResolveGen
		_HSResolveGen += 1
}

; The base expansion delay in seconds: the user's hotstrings.expansion_delay,
; else the shared default (the manifest's, loaded as GLOBAL_DEFAULT_DELAY). It is
; what a hotstring waits when nothing more specific says otherwise, and what a
; user override of a category or section is an offset of.
HotstringsBaseDelay() {
		global Features, GLOBAL_DEFAULT_DELAY
		if IsSet(Features) and (Features is Map) and Features.Has("hotstrings")
				and (Features["hotstrings"] is Map) and Features["hotstrings"].Has(ConfigLeaf.EXPANSION_DELAY)
				return Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY]
		return GLOBAL_DEFAULT_DELAY
}

; The effective delay of an override that adds Offset seconds to Base, on the
; millisecond grid and never below one grid step: 0 means "unlimited" everywhere,
; so an offset that cancels the base must not turn into it.
HotstringsDelayFromOffset(Base, Offset) {
		global HOTSTRINGS_DELAY_DECIMALS
		return Max(Round(Base + Offset, HOTSTRINGS_DELAY_DECIMALS), 10 ** -HOTSTRINGS_DELAY_DECIMALS)
}

; Derives the effective delay of every override read from a file, now that the
; base is known: the file stores offsets, the engine reads seconds. Memory only.
; @param Overrides Optional Map to derive; the live one by default.
HotstringsOverridesApplyBase(Overrides := unset) {
		global _HotstringsOverrides
		Source := IsSet(Overrides) ? Overrides : _HotstringsOverrides
		Base := HotstringsBaseDelay()
		for _, Entry in Source {
				_HotstringsRecordApplyBase(Entry, Base)
				for _, SectionRecord in Entry.Sections
						_HotstringsRecordApplyBase(SectionRecord, Base)
		}
}

_HotstringsRecordApplyBase(Record, Base) {
		if !Record.HasOwnProp("PendingOffset") or Record.PendingOffset == ""
				return
		Record.Delay := HotstringsDelayFromOffset(Base, Record.PendingOffset)
		Record.PendingOffset := ""
}

; Moves every override with it when the base changes: the delays are offsets, so
; each keeps its distance from the base. Unlimited delays stay unlimited.
; Memory only; the file holds offsets and does not change.
HotstringsOverridesRebase(PreviousBase, NewBase) {
		global _HotstringsOverrides
		for _, Entry in _HotstringsOverrides {
				_HotstringsRecordRebase(Entry, PreviousBase, NewBase)
				for _, SectionRecord in Entry.Sections
						_HotstringsRecordRebase(SectionRecord, PreviousBase, NewBase)
		}
		HotstringsResolveBumpGen()
}

_HotstringsRecordRebase(Record, PreviousBase, NewBase) {
		if Record.Delay == "" or Record.Delay == 0
				return
		Record.Delay := HotstringsDelayFromOffset(NewBase, Record.Delay - PreviousBase)
}

; Boot step, run once the configuration (and so the base expansion delay) is
; known: turns the absolute delays and the menu-set default delay of earlier
; builds into offsets of the base, keeping every effective delay, and derives
; the effective delay of every override read from the file.
; @param BaseWriterFn Optional seam standing for the config.toml write of the base.
; @returns {Integer} True when the file needed no migration or was rewritten.
HotstringsOverridesBoot(BaseWriterFn := 0) {
		global _HotstringsOverrides
		Legacy := false
		for _, Entry in _HotstringsOverrides {
				if _HotstringsRecordIsLegacy(Entry)
						Legacy := true
				for _, SectionRecord in Entry.Sections {
						if _HotstringsRecordIsLegacy(SectionRecord)
								Legacy := true
				}
		}
		if !Legacy {
				HotstringsOverridesApplyBase()
				HotstringsResolveBumpGen()
				return true
		}
		return _HotstringsOverridesMigrateLegacyDelays(BaseWriterFn)
}

_HotstringsRecordIsLegacy(Record) {
		return Record.HasOwnProp("LegacyDelay") and Record.LegacyDelay != ""
}

; Adopts an absolute delay of an earlier build as the record's effective delay.
; A delay already stored in the current form wins.
_HotstringsRecordAdoptLegacy(Record) {
		if !_HotstringsRecordIsLegacy(Record)
				return
		if Record.Delay == "" and Record.PendingOffset == ""
				Record.Delay := Record.LegacyDelay
		Record.LegacyDelay := ""
}

; The migration itself. The menu-set default delay (the "_global" record) becomes
; hotstrings.expansion_delay, the absolute delays become offsets of that base on
; the next write, and the file is rewritten at once so no later build reads the
; old spelling. Each step is idempotent: a failed write leaves the old file in
; place and the next boot starts again, while this session already runs on the
; migrated values.
_HotstringsOverridesMigrateLegacyDelays(BaseWriterFn := 0) {
		global _HotstringsOverrides, _HotstringsOverridesPath, Features
		Candidate := Map()
		GlobalDelay := ""
		for Cat, Entry in _HotstringsOverrides {
				if (Cat == "_global") {
						GlobalDelay := Entry.LegacyDelay
						continue
				}
				Clone := _HotstringsCloneOverrideCategory(Entry)
				Clone.Sections := Map()
				_HotstringsRecordAdoptLegacy(Clone)
				for Sec, SectionRecord in Entry.Sections {
						SectionClone := _HotstringsCloneOverrideSection(SectionRecord)
						_HotstringsRecordAdoptLegacy(SectionClone)
						Clone.Sections[Sec] := SectionClone
				}
				Candidate[Cat] := Clone
		}
		if (GlobalDelay != "") {
				Written := HasMethod(BaseWriterFn, "Call")
						? BaseWriterFn.Call(GlobalDelay)
						: WriteFeatureV2(Features, ConfigKey.HOTSTRINGS_EXPANSION_DELAY, GlobalDelay)
				if !Written {
						try LoggerError("HotstringsConfig",
								"The default expansion delay of the override file could not be moved to config.toml (hotstrings.expansion_delay); it applies for this session and the move is retried at the next start.")
						Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := GlobalDelay
				}
		}
		HotstringsOverridesApplyBase(Candidate)
		OwnerToken := _HotstringsOverrideLeaseAcquire("migrate delay overrides")
		Persisted := false
		if (OwnerToken is Object) {
				try Persisted := _HotstringsPersistOverrideCandidate(Candidate, OwnerToken,
						_HotstringsOverridesPath, 0, 0)
				finally _HotstringsOverrideLeaseRelease(OwnerToken)
		}
		if !Persisted {
				try LoggerError("HotstringsConfig",
						"The delay overrides could not be rewritten as offsets of the base expansion delay; they apply for this session and the rewrite is retried at the next start.")
				PreviousCritical := Critical("On")
				try _HotstringsPublishOverrideCandidate(Candidate)
				finally Critical(PreviousCritical)
				return false
		}
		try LoggerInfo("HotstringsConfig", "Delay overrides migrated to offsets of the base expansion delay.")
		return true
}

; Persists the base expansion delay and moves the overrides with it. The setting
; is a config.toml leaf, so it goes through the live writer: no reload.
; @param Seconds New base, a non-negative number of seconds.
; @returns {Integer} True once the leaf is durable and the overrides are rebased.
HotstringsSetBaseDelay(Seconds) {
		global Features
		if !(Seconds is Number) or !TickTryDurationMsFromSeconds(Seconds, &DelayMs) {
				try LoggerError("HotstringsConfig",
						"SetBaseDelay: the base delay must fit the elapsed-tick domain, got '{1}'.", Seconds)
				return false
		}
		Previous := HotstringsBaseDelay()
		if !WriteFeatureV2(Features, ConfigKey.HOTSTRINGS_EXPANSION_DELAY, Seconds)
				return false
		PreviousCritical := Critical("On")
		try HotstringsOverridesRebase(Previous, Seconds)
		finally Critical(PreviousCritical)
		try LoggerInfo("HotstringsConfig", "Base expansion delay set to {1} s.", Seconds)
		return true
}

; Internal resolution logic (uncached); HotstringsResolve above memoises it.
_HotstringsResolveUncached(CategoryName, SectionName := "") {
		global _HotstringsOverrides
		global GLOBAL_DEFAULT_COLOR, HOTSTRINGS_CATEGORY_DEFAULT_COLORS
		Cat := StrLower(CategoryName)
		; Section names in features_config use PascalCase that may contain French
		; letters (``IÉ``, ``ÊCirc``…). The TOML keeps the ASCII-folded lowercase
		; form (``ie``, ``ecirc``…), so fold on the way in to keep call-sites
		; ergonomic — they can pass the same string they already use elsewhere.
		Sec := SectionName != "" ? FoldAsciiLower(SectionName) : ""

		UserCat := _HotstringsOverrides.Has(Cat) ? _HotstringsOverrides[Cat] : ""
		UserSec := (UserCat != "" and Sec != "" and UserCat.Sections.Has(Sec))
				? UserCat.Sections[Sec]
				: ""

		TomlCfg := ParseTomlGroupConfig(Cat)
		TomlSec := (Sec != "" and TomlCfg.Sections.Has(Sec))
				? TomlCfg.Sections[Sec]
				: ""

		Delay := ""
		if (UserSec != "" and UserSec.Delay != "") {
				Delay := UserSec.Delay
		} else if (UserCat != "" and UserCat.Delay != "") {
				Delay := UserCat.Delay
		} else if (TomlSec != "" and TomlSec.Delay != "") {
				Delay := TomlSec.Delay
		} else if (TomlCfg.Delay != "") {
				Delay := TomlCfg.Delay
		} else {
				; The base expansion delay (hotstrings.expansion_delay): the user's
				; value, else the shared default. A user delay above is stored as an
				; offset of it.
				Delay := HotstringsBaseDelay()
		}

		Color := ""
		if (UserSec != "" and UserSec.Color != "") {
				Color := UserSec.Color
		} else if (UserCat != "" and UserCat.Color != "") {
				Color := UserCat.Color
		} else if (TomlSec != "" and TomlSec.Color != "") {
				Color := TomlSec.Color
		} else if (TomlCfg.Color != "") {
				Color := TomlCfg.Color
		} else {
				; Nothing in user overrides or TOML _meta — fall back to the
				; per-category default first (e.g. personal → orange) then to the
				; single global default. ``HotstringsResolveExt`` already lands
				; here; ``HotstringsResolve`` now matches so a resolved color is
				; never empty, regardless of category.
				CatKey := StrLower(CategoryName)
				Color := HOTSTRINGS_CATEGORY_DEFAULT_COLORS.Has(CatKey)
						? HOTSTRINGS_CATEGORY_DEFAULT_COLORS[CatKey]
						: GLOBAL_DEFAULT_COLOR
		}

		; ShowTooltip — explicit false anywhere in the chain suppresses the tooltip.
		; Default when unset at every level is true.
		ShowTooltip := true
		if (UserSec != "" and UserSec.ShowTooltip != "") {
				ShowTooltip := UserSec.ShowTooltip
		} else if (UserCat != "" and UserCat.ShowTooltip != "") {
				ShowTooltip := UserCat.ShowTooltip
		} else if (TomlSec != "" and TomlSec.ShowTooltip != "") {
				ShowTooltip := TomlSec.ShowTooltip
		} else if (TomlCfg.ShowTooltip != "") {
				ShowTooltip := TomlCfg.ShowTooltip
		}

		; Priority — same cascade as Delay (section > category override, then TOML
		; section > category default), falling back to the source default (personal
		; 50 > package 30 > common 10) so a resolved priority is never empty. The
		; individual per-hotstring level sits ABOVE this, applied in the TOML loader.
		; HasOwnProp guards the TOML-config structs, which may predate the field.
		; HasOwnProp guards every level: Priority is the newest override field, so a
		; struct built before it existed (or a hand-rolled test mock) may lack it.
		Priority := ""
		if (UserSec != "" and UserSec.HasOwnProp("Priority") and UserSec.Priority != "") {
				Priority := UserSec.Priority
		} else if (UserCat != "" and UserCat.HasOwnProp("Priority") and UserCat.Priority != "") {
				Priority := UserCat.Priority
		} else if (TomlSec != "" and TomlSec.HasOwnProp("Priority") and TomlSec.Priority != "") {
				Priority := TomlSec.Priority
		} else if (TomlCfg.HasOwnProp("Priority") and TomlCfg.Priority != "") {
				Priority := TomlCfg.Priority
		} else {
				Priority := _HSE_SourcePriority(CategoryName)
		}

		HasOverride := false
		if (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "" or UserSec.ShowTooltip != "" or (UserSec.HasOwnProp("Priority") and UserSec.Priority != ""))) {
				HasOverride := true
		} else if (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "" or UserCat.ShowTooltip != "" or (UserCat.HasOwnProp("Priority") and UserCat.Priority != ""))) {
				HasOverride := true
		}

		return { Delay: Delay, Color: Color, ShowTooltip: ShowTooltip, Priority: Priority, HasOverride: HasOverride }
}

; Resolve the effective delay and color for an extension hotstring file.
; ExtId  — the extension id (e.g. "ergopti-demo").
; TomlPath — absolute path to the extension TOML file, used to read its [_meta].
; SectionName — optional section name within the file.
;
; Resolution order (first non-empty wins):
;   1. [ext.extid.section] in hotstrings_config.toml (user override, section level)
;   2. [ext.extid]         in hotstrings_config.toml (user override, file level)
;   3. [_meta.sections.*] in the extension TOML     (extension default, section)
;   4. [_meta]             in the extension TOML     (extension default, file)
;   5. the base expansion delay / GLOBAL_DEFAULT_COLOR  (hard fallback)
HotstringsResolveExt(ExtId, TomlPath, SectionName := "") {
		global _HotstringsOverrides, GLOBAL_DEFAULT_COLOR
		OverrideKey := "ext." . StrLower(ExtId)
		Sec := SectionName != "" ? StrLower(SectionName) : ""

		UserCat := _HotstringsOverrides.Has(OverrideKey) ? _HotstringsOverrides[OverrideKey] : ""
		UserSec := (UserCat != "" and Sec != "" and UserCat.Sections.Has(Sec))
				? UserCat.Sections[Sec]
				: ""

		TomlCfg := ParseTomlGroupConfig("", TomlPath)
		TomlSec := (Sec != "" and TomlCfg.Sections.Has(Sec))
				? TomlCfg.Sections[Sec]
				: ""

		Delay := ""
		if (UserSec != "" and UserSec.Delay != "") {
				Delay := UserSec.Delay
		} else if (UserCat != "" and UserCat.Delay != "") {
				Delay := UserCat.Delay
		} else if (TomlSec != "" and TomlSec.Delay != "") {
				Delay := TomlSec.Delay
		} else if (TomlCfg.Delay != "") {
				Delay := TomlCfg.Delay
		} else {
				; The base expansion delay (hotstrings.expansion_delay): the user's
				; value, else the shared default. A user delay above is stored as an
				; offset of it.
				Delay := HotstringsBaseDelay()
		}

		Color := ""
		if (UserSec != "" and UserSec.Color != "") {
				Color := UserSec.Color
		} else if (UserCat != "" and UserCat.Color != "") {
				Color := UserCat.Color
		} else if (TomlSec != "" and TomlSec.Color != "") {
				Color := TomlSec.Color
		} else if (TomlCfg.Color != "") {
				Color := TomlCfg.Color
		} else {
				Color := GLOBAL_DEFAULT_COLOR
		}

		ShowTooltip := true
		if (UserSec != "" and UserSec.ShowTooltip != "") {
				ShowTooltip := UserSec.ShowTooltip
		} else if (UserCat != "" and UserCat.ShowTooltip != "") {
				ShowTooltip := UserCat.ShowTooltip
		} else if (TomlSec != "" and TomlSec.ShowTooltip != "") {
				ShowTooltip := TomlSec.ShowTooltip
		} else if (TomlCfg.ShowTooltip != "") {
				ShowTooltip := TomlCfg.ShowTooltip
		}

		; Priority — same cascade as Delay, with the extension source default
		; (package tier 30) as the final fallback so a resolved priority is never
		; empty. HasOwnProp guards structs (TOML config / test mocks) predating the
		; field. The individual per-hotstring level sits above this, in the loader.
		Priority := ""
		if (UserSec != "" and UserSec.HasOwnProp("Priority") and UserSec.Priority != "") {
				Priority := UserSec.Priority
		} else if (UserCat != "" and UserCat.HasOwnProp("Priority") and UserCat.Priority != "") {
				Priority := UserCat.Priority
		} else if (TomlSec != "" and TomlSec.HasOwnProp("Priority") and TomlSec.Priority != "") {
				Priority := TomlSec.Priority
		} else if (TomlCfg.HasOwnProp("Priority") and TomlCfg.Priority != "") {
				Priority := TomlCfg.Priority
		} else {
				Priority := _HSE_SourcePriority("ext." . StrLower(ExtId))
		}

		HasOverride := (UserSec != "" and (UserSec.Delay != "" or UserSec.Color != "" or UserSec.ShowTooltip != "" or (UserSec.HasOwnProp("Priority") and UserSec.Priority != "")))
				or  (UserCat != "" and (UserCat.Delay != "" or UserCat.Color != "" or UserCat.ShowTooltip != "" or (UserCat.HasOwnProp("Priority") and UserCat.Priority != "")))
		return { Delay: Delay, Color: Color, ShowTooltip: ShowTooltip, Priority: Priority, HasOverride: HasOverride }
}


; Copy the mutable category branch used by one candidate transaction. The
; top-level Map and Sections Map use copy-on-write, while untouched section
; objects remain shared because the transaction never mutates them.
_HotstringsCloneOverrideCategory(Source) {
		return {
				Delay: Source.Delay,
				PendingOffset: Source.HasOwnProp("PendingOffset") ? Source.PendingOffset : "",
				LegacyDelay: Source.HasOwnProp("LegacyDelay") ? Source.LegacyDelay : "",
				Color: Source.Color,
				ShowTooltip: Source.ShowTooltip,
				Priority: Source.HasOwnProp("Priority") ? Source.Priority : "",
				Sections: Source.Sections.Clone()
		}
}

; Copy one mutable section leaf before changing it in a candidate transaction.
_HotstringsCloneOverrideSection(Source) {
		return {
				Delay: Source.Delay,
				PendingOffset: Source.HasOwnProp("PendingOffset") ? Source.PendingOffset : "",
				LegacyDelay: Source.HasOwnProp("LegacyDelay") ? Source.LegacyDelay : "",
				Color: Source.Color,
				ShowTooltip: Source.ShowTooltip,
				Priority: Source.HasOwnProp("Priority") ? Source.Priority : ""
		}
}

; Claim the physical override path before any candidate snapshot is taken.
; Config I/O can yield to another AHK thread, so process-local execution alone
; does not serialize two logical writers.
_HotstringsOverrideLeaseAcquire(Action) {
		global _HotstringsOverridesPath
		if (_HotstringsOverridesPath == "") {
				try LoggerError("HotstringsConfig", "Cannot {1}: HotstringsConfigInit has not provided an override path. The change is NOT persisted.", Action)
				return false
		}
		OwnerToken := _ConfigWriteLeaseTryAcquire(_HotstringsOverridesPath,
				"hotstrings-overrides")
		if !(OwnerToken is Object) {
				try LoggerError("HotstringsConfig", "Cannot {1} for '{2}': another configuration transaction already owns the path. The change is NOT persisted.", Action, _HotstringsOverridesPath)
				return false
		}
		return OwnerToken
}

; Release only the opaque token returned for this transaction. A failed release
; is impossible in normal flow but must remain visible because it blocks all
; later writers on the same path.
_HotstringsOverrideLeaseRelease(OwnerToken) {
		if _ConfigWriteLeaseRelease(OwnerToken)
				return true
		try LoggerError("HotstringsConfig", "Failed to release the hotstrings override write lease; later changes may be refused.")
		return false
}

; Revalidate both authorities immediately before durable publication. A terminal
; path transition cannot rebase the store while an ordinary owner is alive, and
; an injected/yielding writer that bypasses that contract is refused after its
; private stage has been completed.
_HotstringsAuthorizeOverrideCommit(OwnerToken, BoundPath) {
		global _HotstringsOverridesPath
		if !(BoundPath is String) || BoundPath == ""
				return false
		if !_ConfigWriteLeaseOwns(OwnerToken, BoundPath)
				return false
		return _ConfigWriteLeaseKey(_HotstringsOverridesPath)
				== _ConfigWriteLeaseKey(BoundPath)
}

; Publish the detached catalogue and invalidate every resolved-cache entry in
; one memory-only Critical callback supplied to _SaveOverrides.
_HotstringsPublishOverrideCandidate(Candidate) {
		global _HotstringsOverrides
		HotstringsOverridesApplyBase(Candidate)
		_HotstringsOverrides := Candidate
		HotstringsResolveBumpGen()
		return 1
}

; Persist one detached catalogue while retaining the exact owner and path that
; admitted its snapshot.
_HotstringsPersistOverrideCandidate(Candidate, OwnerToken, BoundPath,
		WriterFn, ReplaceFn) {
		return _SaveOverrides(Candidate, WriterFn, ReplaceFn,
				BoundPath,
				_HotstringsAuthorizeOverrideCommit.Bind(OwnerToken, BoundPath),
				_HotstringsPublishOverrideCandidate.Bind(Candidate))
}

; Validate the shared priority domain before any backend can stage or publish a
; candidate. The UI exposes this value as an integer slider from 0 through 100;
; accepting a wider type or range here would let bridge or programmatic callers
; persist state that the UI cannot faithfully represent.
HotstringsTryPriority(Value, &Priority) {
	Priority := ""
	if !(Value is Integer) || Value < 0 || Value > 100
		return false
	Priority := Value
	return true
}

; AHK represents booleans as Integer 0/1. Reject every other value explicitly
; so strings such as "false" cannot become true through ordinary truthiness at
; the TOML serializer boundary.
HotstringsTryBooleanOverride(Value, &BooleanValue) {
	BooleanValue := ""
	if !(Value is Integer) || (Value != 0 && Value != 1)
		return false
	BooleanValue := Value
	return true
}

; Set a single override field for (category, section). Pass SectionName as ""
; to set the file-level override. The live Map changes only after the complete
; candidate file has replaced the durable file successfully.
HotstringsSetOverride(CategoryName, SectionName, Field, Value,
		WriterFn := 0, ReplaceFn := 0) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				; A caller-level Critical span must not leak into staging, replacement,
				; logging, or cleanup. The global owner provides transaction isolation.
				Critical("Off")
				try return HotstringsSetOverride(CategoryName, SectionName, Field,
						Value, WriterFn, ReplaceFn)
				finally Critical(InheritedCritical)
		}
		if (Field != "delay" and Field != "color" and Field != "show_tooltip" and Field != "priority") {
				try LoggerError("HotstringsConfig", "SetOverride: field must be 'delay', 'color', 'show_tooltip', or 'priority', got '{1}'.", Field)
				return false
		}
		if (Field == "delay" and Value != ""
				and !TickTryDurationMsFromSeconds(Value, &DelayMs)) {
				try LoggerError("HotstringsConfig",
						"SetOverride: delay must fit the elapsed-tick domain, got '{1}'.",
						Value)
				return false
		}
		if (Field == "priority" and !HotstringsTryPriority(Value, &Priority)) {
				try LoggerError("HotstringsConfig",
						"SetOverride: priority must be an integer from 0 through 100, got '{1}'.",
						Value)
				return false
		}
		if (Field == "show_tooltip"
				and !HotstringsTryBooleanOverride(Value, &TooltipValue)) {
				try LoggerError("HotstringsConfig",
						"SetOverride: show_tooltip must be a Boolean, got '{1}'.", Value)
				return false
		}
		if (Field == "color" and !(Value is String)) {
				try LoggerError("HotstringsConfig",
						"SetOverride: color must be a String.")
				return false
		}
		if !_HotstringsOverrideIdentifiersAreValid(CategoryName, SectionName) {
				try LoggerError("HotstringsConfig",
						"SetOverride: category or section identifier is invalid.")
				return false
		}
		Cat := StrLower(CategoryName)
		Sec := StrLower(SectionName)
		OwnerToken := _HotstringsOverrideLeaseAcquire("set override")
		if !(OwnerToken is Object)
				return false
		BoundPath := _HotstringsOverridesPath
		try return _HotstringsSetOverrideOwned(Cat, Sec, Field, Value,
				WriterFn, ReplaceFn, OwnerToken, BoundPath)
		finally _HotstringsOverrideLeaseRelease(OwnerToken)
}

; Build, persist, and publish one set candidate while the caller owns the path.
_HotstringsSetOverrideOwned(Cat, Sec, Field, Value, WriterFn, ReplaceFn,
		OwnerToken, BoundPath) {
		global _HotstringsOverrides
		if !_HotstringsAuthorizeOverrideCommit(OwnerToken, BoundPath) {
				try LoggerError("HotstringsConfig", "Cannot set override: the admitted owner no longer owns the exact override path. The change is NOT persisted.")
				return false
		}
		Candidate := _HotstringsOverrides.Clone()

		if Candidate.Has(Cat) {
				Entry := _HotstringsCloneOverrideCategory(Candidate[Cat])
		} else {
				Entry := _HotstringsNewOverrideEntry()
		}
		Candidate[Cat] := Entry

		if (Sec != "") {
				if Entry.Sections.Has(Sec) {
						Target := _HotstringsCloneOverrideSection(Entry.Sections[Sec])
				} else {
						Target := _HotstringsNewOverrideSection()
				}
				Entry.Sections[Sec] := Target
		} else {
				Target := Entry
		}

		if (Field == "delay") {
				Target.Delay := Value
				Target.PendingOffset := ""
		} else if (Field == "color") {
				Target.Color := Value
		} else if (Field == "priority") {
				Target.Priority := Value
		} else {
				Target.ShowTooltip := Value
		}

		if !_HotstringsPersistOverrideCandidate(Candidate, OwnerToken,
				BoundPath, WriterFn, ReplaceFn)
				return false

		try LoggerDebug("HotstringsConfig", "Override set: {1}{2}.{3} = {4}.",
				Cat, (Sec != "") ? "." . Sec : "", Field, Value)
		return true
}

; Remove a single override field, or every field when Field is empty.
; Reverts the resolution to the TOML default (or global fallback).
HotstringsClearOverride(CategoryName, SectionName, Field := "",
		WriterFn := 0, ReplaceFn := 0) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				; Match the set path: no external wrapper may turn configuration I/O
				; into a keyboard-starving Critical span.
				Critical("Off")
				try return HotstringsClearOverride(CategoryName, SectionName, Field,
						WriterFn, ReplaceFn)
				finally Critical(InheritedCritical)
		}
		if !(Field is String) || (Field != "" && Field != "delay"
				&& Field != "color" && Field != "show_tooltip"
				&& Field != "priority") {
				try LoggerError("HotstringsConfig",
						"ClearOverride: field must be empty, 'delay', 'color', 'show_tooltip', or 'priority'.")
				return false
		}
		if !_HotstringsOverrideIdentifiersAreValid(CategoryName, SectionName) {
				try LoggerError("HotstringsConfig",
						"ClearOverride: category or section identifier is invalid.")
				return false
		}
		Cat := StrLower(CategoryName)
		Sec := StrLower(SectionName)
		OwnerToken := _HotstringsOverrideLeaseAcquire("clear override")
		if !(OwnerToken is Object)
				return false
		BoundPath := _HotstringsOverridesPath
		try return _HotstringsClearOverrideOwned(Cat, Sec, Field,
				WriterFn, ReplaceFn, OwnerToken, BoundPath)
		finally _HotstringsOverrideLeaseRelease(OwnerToken)
}

; Build, persist, and publish one clear candidate while the caller owns the path.
_HotstringsClearOverrideOwned(Cat, Sec, Field, WriterFn, ReplaceFn,
		OwnerToken, BoundPath) {
		global _HotstringsOverrides
		if !_HotstringsAuthorizeOverrideCommit(OwnerToken, BoundPath) {
				try LoggerError("HotstringsConfig", "Cannot clear override: the admitted owner no longer owns the exact override path. The change is NOT persisted.")
				return false
		}
		if !_HotstringsOverrides.Has(Cat) {
				return true
		}
		Candidate := _HotstringsOverrides.Clone()
		Entry := _HotstringsCloneOverrideCategory(Candidate[Cat])
		Candidate[Cat] := Entry

		if (Sec != "") {
				if !Entry.Sections.Has(Sec) {
						return true
				}
				Target := _HotstringsCloneOverrideSection(Entry.Sections[Sec])
				Entry.Sections[Sec] := Target
		} else {
				Target := Entry
		}

		if (Field == "" or Field == "delay") {
				Target.Delay := ""
				Target.PendingOffset := ""
		}
		if (Field == "" or Field == "color") {
				Target.Color := ""
		}
		if (Field == "" or Field == "show_tooltip") {
				Target.ShowTooltip := ""
		}
		if (Field == "" or Field == "priority") {
				Target.Priority := ""
		}

		if !_HotstringsPersistOverrideCandidate(Candidate, OwnerToken,
				BoundPath, WriterFn, ReplaceFn)
				return false

		try LoggerDebug("HotstringsConfig", "Override cleared: {1}{2}{3}.",
				Cat,
				(Sec != "") ? "." . Sec : "",
				(Field != "") ? "." . Field : "")
		return true
}

; Reload the override file from disk — useful after Hammerspoon has written
; to it while AHK was running. It shares path ownership with Set/Clear because
; an AHK callback can interrupt another callback inside configuration I/O.
HotstringsConfigReload(ParseFn := 0) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				; FileRead and logging can block. The path lease, followed by one
				; memory-only publication span, supplies the required serialization.
				Critical("Off")
				try return HotstringsConfigReload(ParseFn)
				finally Critical(InheritedCritical)
		}
		global _HotstringsOverridesPath
		OwnerToken := _HotstringsOverrideLeaseAcquire("reload overrides")
		if !(OwnerToken is Object)
				return false
		BoundPath := _HotstringsOverridesPath
		try return _HotstringsConfigReloadOwned(OwnerToken, BoundPath, ParseFn)
		finally _HotstringsOverrideLeaseRelease(OwnerToken)
}

; Parse one detached candidate outside Critical, then revalidate the same owner
; and exact path in the tiny Critical span that swaps the Map and generation.
; ParseFn is an internal test seam for yielded/re-entrant parser behaviour.
_HotstringsConfigReloadOwned(OwnerToken, BoundPath, ParseFn := 0) {
		Candidate := 0
		try Candidate := HasMethod(ParseFn, "Call")
				? ParseFn.Call(BoundPath) : _ParseOverrides(BoundPath)
		catch as Err {
				try LoggerError("HotstringsConfig",
						"Cannot reload overrides from '{1}': {2}. The live catalogue is unchanged.",
						BoundPath, Err.Message)
				return false
		}
		if !(Candidate is Map) {
				try LoggerError("HotstringsConfig",
						"Cannot reload overrides from '{1}': the parser returned no Map. The live catalogue is unchanged.",
						BoundPath)
				return false
		}

		Authorized := false
		Published := false
		PreviousCritical := Critical("On")
		try {
				Authorized := _HotstringsAuthorizeOverrideCommit(OwnerToken, BoundPath)
				if Authorized
						Published := _HotstringsPublishOverrideCandidate(Candidate)
		} finally Critical(PreviousCritical)
		if !(Authorized is Integer) || Authorized != 1 {
				try LoggerError("HotstringsConfig",
						"Cannot reload overrides from '{1}': the admitted owner no longer owns the exact path. The live catalogue is unchanged.",
						BoundPath)
				return false
		}
		if !(Published is Integer) || Published != 1 {
				try LoggerError("HotstringsConfig",
						"Cannot reload overrides from '{1}': live publication was refused.",
						BoundPath)
				return false
		}
		try LoggerDebug("HotstringsConfig", "Overrides reloaded from disk.")
		return true
}

; Return the absolute path of the override file (for diagnostics / UI).
HotstringsConfigPath() {
		global _HotstringsOverridesPath
		return _HotstringsOverridesPath
}




; ============================================================
; ============================================================
; ======= 2/ Terminator catalogue helpers ===================
; ============================================================
; ============================================================

; Pure helpers over the generated HSE_Terminators catalogue and a word-delimiter
; STRING: the catalogue defaults, which characters the catalogue owns, and the
; membership tests the one-time migration of the old strings uses. No I/O here.

; The keys of the generated catalogue. A row registered at runtime (addCustom)
; is enabled by default but is never a shipped default: reset defaults must not
; promote it.
_HSE_TerminatorShippedKeys() {
		static Keys := 0
		if !(Keys is Map) {
				Keys := Map()
				for _, D in Terminators().all()
						Keys[D["key"]] := true
		}
		return Keys
}

; Default word-terminator string — the chars of every catalogue entry that is
; enabled by default. This is the single source for the AHK default set, kept in
; lock-step with macOS (both read the same catalogue). Separators are skipped.
HSE_TerminatorDefaultWordDelimiters() {
		global HSE_Terminators
		Shipped := _HSE_TerminatorShippedKeys()
		Out := ""
		for _, D in HSE_Terminators.all() {
				if (D.Has("type") and D["type"] == "separator") or !Shipped.Has(D["key"])
						continue
				if !D["default_enabled"]
						continue
				for _, Ch in D["chars"]
						Out .= Ch
		}
		return Out
}

; Default consumed-delimiter string — the chars of every catalogue entry that is
; both enabled by default AND marked consume (i.e. the magic key). Swallowed
; rather than re-injected after an expansion, matching macOS.
HSE_TerminatorDefaultConsumedDelimiters() {
		global HSE_Terminators
		Shipped := _HSE_TerminatorShippedKeys()
		Out := ""
		for _, D in HSE_Terminators.all() {
				if (D.Has("type") and D["type"] == "separator") or !Shipped.Has(D["key"])
						continue
				if !(D["default_enabled"] and D["consume"])
						continue
				for _, Ch in D["chars"]
						Out .= Ch
		}
		return Out
}

; True when EVERY char of a catalogue entry is present in the delimiter string
; (an entry such as "enter" owns both CR and LF and toggles as one unit).
HSE_TerminatorEntryEnabled(CharsArr, WordStr) {
		if (CharsArr.Length == 0)
				return false
		for _, Ch in CharsArr {
				if !InStr(WordStr, Ch)
						return false
		}
		return true
}

; True when any of the entry's chars appears in the given string (used to render
; the "(consumed)" suffix from the actual consumed-delimiter set).
HSE_TerminatorAnyCharIn(CharsArr, Hay) {
		for _, Ch in CharsArr {
				if InStr(Hay, Ch)
						return true
		}
		return false
}
