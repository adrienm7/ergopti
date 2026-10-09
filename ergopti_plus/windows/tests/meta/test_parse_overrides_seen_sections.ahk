; tests/meta/test_parse_overrides_seen_sections.ahk

; ==============================================================================
; MODULE: _ParseOverrides Duplicate Section Detection Guard
; DESCRIPTION:
; Static source guard for the duplicate-section detection fix in
; infra/hotstrings/hotstrings_config.ahk.
;
; ROOT CAUSE ENCODED:
; The original _ParseOverrides function parsed TOML section headers without
; tracking which sections it had already seen. A TOML file with a duplicate
; [ext.name.section] header would silently clobber earlier values, making it
; impossible to diagnose accidental duplicates in user-written override files.
;
; The fix introduces a SeenSections Map() tracker and calls LoggerWarn whenever
; a section header appears more than once in the same file, so the user gets an
; actionable warning rather than silent data loss.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPOSS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TPOSS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ===========================================================
; ===========================================================
; ======= 1/ SeenSections tracker present in _ParseOverrides =
; ===========================================================
; ===========================================================

_TPOSS_SeenSectionsTracker() {
	Src := _TPOSS_StripLineComments(_TPOSS_ReadSource("infra/hotstrings/hotstrings_config.ahk"))
	Assert(Src != "", "infra/hotstrings/hotstrings_config.ahk must be readable")

	Body := _DriverFuncBody("_ParseOverrides")
	Assert(Body != "", "_ParseOverrides must be defined in infra/hotstrings/hotstrings_config.ahk")

	; SeenSections Map must be declared
	Assert(InStr(Body, "SeenSections := Map()") > 0,
		"_ParseOverrides must declare SeenSections := Map() to track duplicate section headers")

	; Must check for duplicates with SeenSections.Has(...)
	Assert(InStr(Body, "SeenSections.Has(") > 0,
		"_ParseOverrides must check SeenSections.Has(SectionName) before processing each section header")

	; Must warn on duplicate via LoggerWarn
	Assert(InStr(Body, "LoggerWarn") > 0,
		"_ParseOverrides must call LoggerWarn when a duplicate section header is detected")
}
Test("hotstrings_config: _ParseOverrides tracks SeenSections and warns on duplicates", _TPOSS_SeenSectionsTracker)
