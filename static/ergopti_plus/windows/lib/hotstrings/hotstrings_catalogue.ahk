; lib/hotstrings/hotstrings_catalogue.ahk

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
; 3. Terminator catalogue helpers are pure (no I/O); callers persist the
;    returned string via HotstringsSetWordDelimiters (in hotstrings_io.ahk).
;
; Included by lib/hotstrings/hotstrings_config.ahk.
; ==============================================================================




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
;   5. GLOBAL_DEFAULT_DELAY (delay only); color stays empty.
HotstringsResolve(CategoryName, SectionName := "") {
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

; Internal resolution logic (uncached); HotstringsResolve above memoises it.
_HotstringsResolveUncached(CategoryName, SectionName := "") {
		global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY
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
		} else if (_HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != "") {
				; Menu-set global default expansion delay — applied only when no user or
				; TOML delay is defined for this category/section. It is the "default
				; expansion delay" the user edits from the tray menu; the hardcoded
				; GLOBAL_DEFAULT_DELAY below is the final fallback when even that is unset.
				Delay := _HotstringsOverrides["_global"].Delay
		} else {
				Delay := GLOBAL_DEFAULT_DELAY
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
;   5. GLOBAL_DEFAULT_DELAY / GLOBAL_DEFAULT_COLOR   (hard fallback)
HotstringsResolveExt(ExtId, TomlPath, SectionName := "") {
		global _HotstringsOverrides, GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR
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
		} else if (_HotstringsOverrides.Has("_global") and _HotstringsOverrides["_global"].Delay != "") {
				; Menu-set global default expansion delay — applied only when no user or
				; TOML delay is defined for this category/section. It is the "default
				; expansion delay" the user edits from the tray menu; the hardcoded
				; GLOBAL_DEFAULT_DELAY below is the final fallback when even that is unset.
				Delay := _HotstringsOverrides["_global"].Delay
		} else {
				Delay := GLOBAL_DEFAULT_DELAY
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


; Set a single override field for (category, section). Pass SectionName as ""
; to set the file-level override. ``Field`` must be "delay" or "color".
; Persists immediately and refreshes the in-memory cache.
HotstringsSetOverride(CategoryName, SectionName, Field, Value) {
		global _HotstringsOverrides
		if (Field != "delay" and Field != "color" and Field != "show_tooltip" and Field != "priority") {
				try LoggerError("HotstringsConfig", "SetOverride: field must be 'delay', 'color', 'show_tooltip', or 'priority', got '{1}'.", Field)
				return false
		}
		Cat := StrLower(CategoryName)
		Sec := StrLower(SectionName)

		if !_HotstringsOverrides.Has(Cat) {
				_HotstringsOverrides[Cat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
		}
		Entry := _HotstringsOverrides[Cat]

		if (Sec != "") {
				if !Entry.Sections.Has(Sec) {
						Entry.Sections[Sec] := { Delay: "", Color: "", ShowTooltip: "", Priority: "" }
				}
				Target := Entry.Sections[Sec]
		} else {
				Target := Entry
		}

		if (Field == "delay") {
				Target.Delay := Value
		} else if (Field == "color") {
				Target.Color := Value
		} else if (Field == "priority") {
				Target.Priority := Value
		} else {
				Target.ShowTooltip := Value
		}

		try LoggerDebug("HotstringsConfig", "Override set: {1}{2}.{3} = {4}.",
				Cat, (Sec != "") ? "." . Sec : "", Field, Value)
		HotstringsResolveBumpGen()
		return _SaveOverrides()
}

; Remove a single override field, or both fields when Field is empty.
; Reverts the resolution to the TOML default (or global fallback).
HotstringsClearOverride(CategoryName, SectionName, Field := "") {
		global _HotstringsOverrides
		Cat := StrLower(CategoryName)
		Sec := StrLower(SectionName)

		if !_HotstringsOverrides.Has(Cat) {
				return true
		}
		Entry := _HotstringsOverrides[Cat]

		if (Sec != "") {
				if !Entry.Sections.Has(Sec) {
						return true
				}
				Target := Entry.Sections[Sec]
		} else {
				Target := Entry
		}

		if (Field == "" or Field == "delay") {
				Target.Delay := ""
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

		try LoggerDebug("HotstringsConfig", "Override cleared: {1}{2}{3}.",
				Cat,
				(Sec != "") ? "." . Sec : "",
				(Field != "") ? "." . Field : "")
		HotstringsResolveBumpGen()
		return _SaveOverrides()
}

; Reload the override file from disk — useful after Hammerspoon has written
; to it while AHK was running. AHK is single-process so we don't need locks.
HotstringsConfigReload() {
		global _HotstringsOverridesPath, _HotstringsOverrides
		if (_HotstringsOverridesPath == "") {
				return false
		}
		_HotstringsOverrides := _ParseOverrides(_HotstringsOverridesPath)
		HotstringsResolveBumpGen()
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

; Pure helpers shared by the tray word-expander submenu and the config-window
; checkbox grid so the per-entry enable/toggle logic lives in exactly one place
; (and is unit-tested via test_terminators.ahk). They operate on the active
; word-delimiter STRING — the persisted serialization of the catalogue's
; enabled state — and the generated HSE_Terminators catalogue. No I/O here;
; callers persist the returned string via HotstringsSetWordDelimiters.

; Default word-terminator string — the chars of every catalogue entry that is
; enabled by default. This is the single source for the AHK default set, kept in
; lock-step with macOS (both read the same catalogue). Separators are skipped.
HSE_TerminatorDefaultWordDelimiters() {
		global HSE_Terminators
		Out := ""
		for _, D in HSE_Terminators.all() {
				if (D.Has("type") and D["type"] == "separator")
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
		Out := ""
		for _, D in HSE_Terminators.all() {
				if (D.Has("type") and D["type"] == "separator")
						continue
				if !(D["default_enabled"] and D["consume"])
						continue
				for _, Ch in D["chars"]
						Out .= Ch
		}
		return Out
}

; Concatenated chars of every built-in (non-separator) catalogue entry. Used to
; tell user-defined custom delimiters apart from catalogue ones.
HSE_TerminatorBuiltinChars() {
		global HSE_Terminators
		Out := ""
		for _, D in HSE_Terminators.all() {
				if (D.Has("type") and D["type"] == "separator")
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

; Pure: return WordStr with the entry's chars toggled — all removed when the
; entry is currently enabled, all added otherwise.
HSE_TerminatorToggleString(WordStr, CharsArr) {
		if HSE_TerminatorEntryEnabled(CharsArr, WordStr) {
				for _, Ch in CharsArr
						WordStr := StrReplace(WordStr, Ch, "")
		} else {
				for _, Ch in CharsArr {
						if !InStr(WordStr, Ch)
								WordStr .= Ch
				}
		}
		return WordStr
}

; Pure: return WordStr with every built-in catalogue char enabled (Enable=true)
; or removed (Enable=false), always preserving user-defined custom chars (those
; owned by no catalogue entry). CR/LF belong to the "enter" entry and follow it.
HSE_TerminatorSetAllString(WordStr, Enable) {
		global HSE_Terminators
		BuiltinChars := HSE_TerminatorBuiltinChars()
		Kept := ""
		Loop Parse, WordStr {
				Ch := A_LoopField
				if (Ch != "`r" and Ch != "`n" and !InStr(BuiltinChars, Ch))
						Kept .= Ch
		}
		if Enable {
				for _, D in HSE_Terminators.all() {
						if (D.Has("type") and D["type"] == "separator")
								continue
						for _, Ch in D["chars"] {
								if !InStr(Kept, Ch)
										Kept .= Ch
						}
				}
		}
		return Kept
}
