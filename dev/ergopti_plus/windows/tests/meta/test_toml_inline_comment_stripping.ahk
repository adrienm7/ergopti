; tests/meta/test_toml_inline_comment_stripping.ahk

; ==============================================================================
; MODULE: Regression — a trailing comment must never become data
; DESCRIPTION:
; ParseTomlFile stripped inline comments with a plain InStr, guarded only by a
; first-character test, under a comment that promised something else entirely:
; "Must scan character-by-character to skip # inside quoted strings."
;
; ROOT CAUSE ENCODED — three faces of one missing quote-aware scan:
;
; 1. QUOTED VALUES. A quoted value followed by a comment starts with a quote,
;    so comment stripping was skipped wholesale. TOML_CoerceValue then requires
;    the first AND last character to be a quote; the last one is part of the
;    comment, so the quoted-string branch was skipped too and the raw text fell
;    through unchanged. The value became the whole line tail. On the next write
;    it was re-rendered as an escaped string, so the corruption reached disk and
;    survived every restart — each further round trip re-corrupting it.
;
; 2. SECTION HEADERS. The trailing-bracket anchor cannot match once a comment
;    follows, so the comment became part of the section name. Every later read
;    of that section missed and the whole block reverted to defaults, and the
;    next write re-wrapped the garbage in brackets, mangling it further on each
;    save. The two sibling parsers fail differently on the same line: their
;    anchored patterns simply do not match, the line falls through to the key
;    parser, fails that too, and `continue` leaves the section pointer on the
;    PREVIOUS section — so the following keys are applied to the wrong section.
;
; 3. MULTI-LINE ARRAYS. Only lines that were ENTIRELY a comment were skipped,
;    so a trailing comment on an element line was accumulated into the value
;    and persisted as a real array element.
;
; Every one of these is silent: no parser raises, and the corrupted value is
; written back as though the user had typed it.
;
; SCOPE: behavioural, against the real parsers.
; ==============================================================================

#Requires AutoHotkey v2.0

; Writes Body to a scratch TOML and returns the parsed Sections map. The name
; must be unique per case: ParseTomlFile memoises by path, so reusing one file
; would hand every case after the first the FIRST case's parse.
_TIC_Parse(Tag, Body) {
	Path := A_Temp . "\ergopti_test_inline_comment_" . Tag . ".toml"
	try FileDelete(Path)
	FileAppend(Body, Path, "UTF-8")
	Result := ParseTomlFile(Path)
	try FileDelete(Path)
	return Result
}





; =================================================
; =================================================
; ======= 1/ A comment after a quoted value =======
; =================================================
; =================================================

_TIC_QuotedValueDropsItsComment() {
	Cache := _TIC_Parse("quoted", '[script]`nlocale = "fr" # francais`n')
	Value := IniCacheGet(Cache, "script", "locale")
	Assert(Value == "fr",
		"a quoted value followed by a comment must parse to the value alone — got '" . Value . "'; the raw text used to fall through unchanged and was then re-rendered as an escaped string on the next write, putting the corruption on disk permanently")
}

; The hash belongs to the user when it is INSIDE the quotes. Stripping it would
; be the same bug pointing the other way, so both directions are pinned.
_TIC_HashInsideQuotesIsKept() {
	Cache := _TIC_Parse("inquote", '[script]`ntag = "a#b" # trailing`n')
	Value := IniCacheGet(Cache, "script", "tag")
	Assert(Value == "a#b",
		"a hash inside the quotes is data, not a comment — got '" . Value . "'")
}

; An escaped quote must not be read as the end of the string, or everything
; after it looks unquoted and the following hash cuts into real data.
_TIC_EscapedQuoteDoesNotEndTheString() {
	Cache := _TIC_Parse("escaped", '[script]`nq = "say \"hi\" #1" # note`n')
	Value := IniCacheGet(Cache, "script", "q")
	Assert(InStr(Value, "#1") > 0,
		"an escaped quote must not terminate the string — the hash inside it is data; got '" . Value . "'")
	Assert(InStr(Value, "note") == 0,
		"the real trailing comment must still be removed; got '" . Value . "'")
}





; ===================================================
; ===================================================
; ======= 2/ A comment after a section header =======
; ===================================================
; ===================================================

_TIC_SectionHeaderDropsItsComment() {
	Cache := _TIC_Parse("header", "[layout] # mes reglages`nergopti_plus = 0`n")
	Assert(Cache.Has("layout"),
		"a section header with a trailing comment must still be named by its path alone — the trailing-bracket anchor cannot match once a comment follows, so the whole comment used to become part of the section name and every later read of that section missed")
	Assert(IniCacheGet(Cache, "layout", "ergopti_plus") == 0,
		"the keys under a commented header must land in that section")
}

; The sibling parsers fail differently on this line — theirs leave the section
; pointer on the PREVIOUS section, so keys are applied to the wrong one. Policed
; as a class so a fix to one parser cannot quietly skip the others.
_TIC_AllHeaderParsersStripComments() {
	Checked := 0
	for Name in ["ApplyConfigToml", "ReadTomlSectionsOrder", "LoadHotstringsSection"] {
		Body := _DriverFuncBody(Name)
		if (Body == "")
			continue
		if (InStr(Body, "^\[") == 0)
			continue
		Checked += 1
		Assert(InStr(Body, "TOML_StripInlineComment(") > 0,
			Name . " matches a section header but never strips an inline comment first — its anchored pattern fails on a commented header, the line falls through to the key parser, and the section pointer is left on the PREVIOUS section so the following keys are applied to the wrong one")
	}
	Assert(Checked >= 2,
		"expected at least two sibling header parsers to police (found " . Checked . ")")
}





; ======================================================
; ======================================================
; ======= 3/ A comment inside a multi-line array =======
; ======================================================
; ======================================================

_TIC_ArrayElementCommentIsNotAnElement() {
	Cache := _TIC_Parse("array", '[g]`nitems = [`n  "a", # premier`n  "b"`n]`n')
	Value := IniCacheGet(Cache, "g", "items")
	Assert(Value is Array,
		"the multi-line array must still parse as an array")
	Assert(Value.Length == 2,
		"a trailing comment on an element line must not become an array element — got " . Value.Length . " element(s) instead of 2, and the stray text would be persisted as real data on the next write")
	Assert(Value[1] == "a" and Value[2] == "b",
		"the real elements must survive intact")
}


Test("meta toml: a comment after a quoted value is stripped", _TIC_QuotedValueDropsItsComment)
Test("meta toml: a hash inside quotes is kept as data", _TIC_HashInsideQuotesIsKept)
Test("meta toml: an escaped quote does not end the string", _TIC_EscapedQuoteDoesNotEndTheString)
Test("meta toml: a comment after a section header is stripped", _TIC_SectionHeaderDropsItsComment)
Test("meta toml: every header parser strips comments first", _TIC_AllHeaderParsersStripComments)
Test("meta toml: an array element comment is not an element", _TIC_ArrayElementCommentIsNotAnElement)
