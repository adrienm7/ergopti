; tests/meta/test_logger_sub_files_routing.ahk

; ==============================================================================
; MODULE: Logger Sub-Files Routing Test
; DESCRIPTION:
; Source-scan meta test that guards the three routing bugs fixed in F11 and F19.
;
; BUGS ENCODED:
; F11 — _LoggerLoadSubFilesToml used a three-level relative path
;        (..\..\..\_shared\modules\logger\sub_files.toml) instead of one level up or
;        the canonical _SharedDir global, causing the TOML file to never be
;        found and silently falling back to the hardcoded list.
; F19a — The platform filter compared P against "autohotkey" but sub_files.toml
;         uses the token "ahk", so no entries were ever selected from the TOML.
; F19b — _LoggerFanOut compared Tag against TagPattern with exact equality, but
;         TOML patterns are bracketed substrings of the full log line (e.g.
;         "[LayoutShift]"), so no line was ever routed to a sub-file.
; F19c — LOGGER_SUB_FILES_FALLBACK used bare tag names ("LayoutShift") instead
;         of the bracketed form ("[LayoutShift]"), breaking fallback routing too.
; ==============================================================================

#Requires AutoHotkey v2.0


_LSFR_ReadSource(RelPath) {
	Root := A_ScriptDir . "\.."
	return FileRead(Root . "\" . RelPath, "UTF-8")
}





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

; ── F11 / F19a — now asserted on the DATA, not on the parser's spelling ──────
;
; These two used to grep infra/logger.ahk: F11 for the shared-file path the parser
; built, F19a for the "ahk" token its platform filter compared against. Both were
; pins on the current spelling of a hand-rolled parser — and that parser is gone,
; because the routing table is generated from the canonical TOML now.
;
; The invariants survive intact and are stronger stated as data: a wrong path in
; the generator produces an empty or wrong table, and a wrong platform token
; produces the wrong set of entries. Comparing the generated table against the
; canonical file catches both, and cannot be satisfied by a rename.

; Names of the [[sub_files]] entries whose platforms array lists "ahk".
;
; Reads only what it needs: every shipped platforms array is written on one line,
; so this needs no array-continuation handling — which is deliberate, since a
; second hand-rolled TOML reader is precisely what this work removed.
_LSFR_CanonicalAhkNames() {
	Raw := ""
	try {
		Raw := FileRead(A_ScriptDir . "\..\..\_shared\modules\logger\sub_files.toml", "UTF-8")
	} catch {
		return []
	}
	Names := []
	CurName := ""
	for _, Line in StrSplit(Raw, "`n", "`r") {
		T := Trim(Line)
		if (T == "[[sub_files]]") {
			CurName := ""
			continue
		}
		if RegExMatch(T, '^name\s*=\s*"([^"]*)"', &M) {
			CurName := M[1]
			continue
		}
		if (SubStr(T, 1, 9) == "platforms" and InStr(T, '"ahk"') and CurName != "") {
			Names.Push(CurName)
		}
	}
	return Names
}

_LSFR_GeneratedMatchesCanonical() {
	Canonical := _LSFR_CanonicalAhkNames()
	Assert(Canonical.Length > 0,
		"the canonical _shared/modules/logger/sub_files.toml must be readable and declare at least one ahk entry, or this test asserts nothing")

	Entries := LoggerSubFilesData()
	Assert(Entries.Length > 0, "the generated routing table must not be empty")

	; Every canonical ahk entry must be present. A wrong source path in the
	; generator, or a platform filter comparing against the wrong token, both
	; show up here as a missing entry.
	for _, Name in Canonical {
		Want := "ErgoptiPlus_" . Name . ".log"
		Found := false
		for _, E in Entries {
			if (E["name"] == Want) {
				Found := true
				break
			}
		}
		Assert(Found, "the generated routing table is missing " . Want . ", which sub_files.toml declares for the ahk platform")
	}

	; …and nothing else. An entry the canonical file does not declare for ahk
	; means the platform filter let a macOS-only topic through.
	Assert(Entries.Length == Canonical.Length,
		"the generated table has " . Entries.Length . " entr(ies) but sub_files.toml declares " . Canonical.Length . " for ahk — the platform filter is including topics this driver never writes")
}
Test("meta logger sub_files: the generated table matches the canonical file's ahk entries", _LSFR_GeneratedMatchesCanonical)


; F19b — fan-out must use substring match (InStr) not exact tag equality
_LSFR_F19b_FanOutSubstringMatch() {
	Src := _LSFR_ReadSource("infra\logger.ahk")
	; Old broken form: (Tag = TagPattern)
	HasExactEquality := false
	for _, Line in StrSplit(Src, "`n", "`r") {
		if InStr(Line, "Tag = TagPattern") or InStr(Line, "(Tag = TagPattern)")
			HasExactEquality := true
	}
	; New correct form must use InStr(Line, Pat
	HasInStr := InStr(Src, "InStr(Line, Pat")
	Assert(!HasExactEquality, "F19b: _LoggerFanOut still uses exact tag equality (Tag = TagPattern).")
	Assert(HasInStr, "F19b: _LoggerFanOut must use InStr(Line, Pat, ...) for substring matching.")
}
Test("meta logger sub_files: F19b — fan-out uses InStr substring match", _LSFR_F19b_FanOutSubstringMatch)


; F19c — fallback patterns must be bracketed, not bare tag names
_LSFR_F19c_FallbackBracketedPatterns() {
	Src := _LSFR_ReadSource("infra\logger.ahk")
	; The canonical bracketed pattern for the layout sub-file
	HasBracketed := InStr(Src, Chr(34) . "[LayoutShift]" . Chr(34))
	; The old bare form must not appear in the fallback definition
	HasBareName := false
	InFallback := false
	for _, Line in StrSplit(Src, "`n", "`r") {
		if InStr(Line, "LOGGER_SUB_FILES_FALLBACK")
			InFallback := true
		if InFallback and InStr(Line, "]") and !InStr(Line, "[[") and !InStr(Line, "Map(")
			InFallback := false
		; A quoted bare "LayoutShift" (no bracket) inside the fallback block is the bug
		if InFallback and InStr(Line, Chr(34) . "LayoutShift" . Chr(34))
			HasBareName := true
	}
	Assert(HasBracketed, "F19c: LOGGER_SUB_FILES_FALLBACK must contain bracketed pattern " . Chr(34) . "[LayoutShift]" . Chr(34) . ".")
	Assert(!HasBareName, "F19c: LOGGER_SUB_FILES_FALLBACK must not contain bare pattern " . Chr(34) . "LayoutShift" . Chr(34) . " (missing brackets).")
}
Test("meta logger sub_files: F19c — fallback uses bracketed patterns", _LSFR_F19c_FallbackBracketedPatterns)
