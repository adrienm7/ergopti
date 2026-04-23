; static/drivers/autohotkey/lib/ini_helpers.ahk

; ==============================================================================
; MODULE: INI Helpers
; DESCRIPTION:
; Pure helpers for reading the ErgoptiPlus configuration file. Extracted from
; ErgoptiPlus.ahk so they can be ``#Include``-d from the test runner without
; bootstrapping the rest of the driver.
;
; FEATURES & RATIONALE:
; 1. ``ParseIniFile`` reads the entire file once into a nested Map so that
;    repeated lookups via ``IniCacheGet`` are O(1) — at startup the original
;    code did ~475 ``IniRead`` calls (one ``FileOpen`` each).
; 2. ``IniCacheGet`` exposes a sentinel-based « value or default » lookup;
;    the underscore sentinel is the documented "key absent" marker so callers
;    can distinguish a real empty-string value from a missing entry.
; 3. ``ResolveConfigPath`` centralises the « expand environment + fall back to
;    the bundled default » logic that several config callers used to duplicate.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Parser and accessors =======
; ============================================
; ============================================

; Read the entire INI file into Map[Section][Key]=Value. Missing files return
; an empty Map so callers can rely on ``Has`` checks without a prior
; ``FileExist``. Lines without an equals sign and lines outside any section
; are silently skipped, mirroring the behaviour of the Win32 INI APIs.
ParseIniFile(Path) {
	Sections := Map()
	if !FileExist(Path) {
		return Sections
	}
	CurrentSection := ""
	loop read Path {
		Line := Trim(A_LoopReadLine)
		if (SubStr(Line, 1, 1) == "[") {
			; Section header: [SectionName]
			CurrentSection := SubStr(Line, 2, StrLen(Line) - 2)
			if !Sections.Has(CurrentSection) {
				Sections[CurrentSection] := Map()
			}
		} else if (CurrentSection != "" and InStr(Line, "=")) {
			EqPos := InStr(Line, "=")
			Key := Trim(SubStr(Line, 1, EqPos - 1))
			Val := SubStr(Line, EqPos + 1)
			Sections[CurrentSection][Key] := Val
		}
	}
	return Sections
}

; Look up Section/Key in a parsed cache. Returns ``Default`` (defaulting to
; the underscore sentinel) when either the section or the key is absent.
; Callers compare against ``"_"`` to detect missing entries cheaply.
IniCacheGet(Cache, Section, Key, Default := "_") {
	if Cache.Has(Section) and Cache[Section].Has(Key) {
		return Cache[Section][Key]
	}
	return Default
}

; Resolve a configured path: trim whitespace, treat empty / underscore as
; "use the default", otherwise return the trimmed value. Centralised so the
; semantics of "blank ⇒ default" are honoured everywhere.
ResolveConfigPath(RawValue, DefaultPath) {
	Trimmed := Trim(RawValue)
	if (Trimmed == "" or Trimmed == "_") {
		return DefaultPath
	}
	return Trimmed
}
