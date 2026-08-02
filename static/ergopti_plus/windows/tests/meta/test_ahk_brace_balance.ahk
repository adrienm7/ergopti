; tests/meta/test_ahk_brace_balance.ahk

; ==============================================================================
; MODULE: AHK Brace Balance Validation Test
; DESCRIPTION:
; Meta-test that verifies every AHK source file under infra/ and modules/ has
; perfectly balanced curly braces after stripping string literals, line
; comments, and block comments.
;
; CATCHES:
; Orphan closing or opening braces left over when refactoring control-flow
; into early-return guards. Such orphans are silent parse errors that only
; surface at AHK runtime startup, never during development.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

_MetaBrace_ListFiles(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_brace_list.txt"
	try FileDelete(TempFile)
	RunWait('cmd /c dir /b /s /a-d "' . Dir . '" > "' . TempFile . '"', , "Hide")
	try {
		Raw := FileRead(TempFile)
	} catch {
		return Files
	}
	for Line in StrSplit(Raw, "`n", "`r") {
		Line := Trim(Line)
		if Line = ""
			continue
		Line := StrReplace(Line, "\", "/")
		if not Line ~= "i)\.ahk$"
			continue
		; Skip test files — only validate production source
		if Line ~= "i)/tests/"
			continue
		Files.Push(Line)
	}
	return Files
}





; =======================================
; =======================================
; ======= 2/ Brace balance parser =======
; =======================================
; =======================================

; Counts { and } in Source after stripping string literals, line comments,
; and block comments. Returns a Map with keys "open" and "close".
_MetaBrace_Count(Source) {
	Open := 0
	Close := 0
	I := 1
	Len := StrLen(Source)
	DQ := Chr(34)  ; double-quote character
	SQ := Chr(39)  ; single-quote character (AHK v2 also delimits strings with ')
	BT := Chr(96)  ; backtick (AHK v2 string-escape prefix)

	while I <= Len {
		Ch := SubStr(Source, I, 1)

		; Block comment: /* ... */
		if Ch = "/" && SubStr(Source, I + 1, 1) = "*" {
			End := InStr(Source, "*/", true, I + 2)
			I := (End > 0) ? End + 2 : Len + 1
			continue
		}

		; Line comment: ; ... newline
		if Ch = ";" {
			NL := InStr(Source, "`n", true, I)
			I := (NL > 0) ? NL + 1 : Len + 1
			continue
		}

		; String literal: "..." or '...' — AHK v2 delimits with either quote, and
		; BT is the escape prefix inside both. A brace inside a string is not code,
		; so an unmatched ``{`` in e.g. a single-quoted regex must not be counted.
		if Ch = DQ || Ch = SQ {
			Quote := Ch
			I++
			while I <= Len {
				SC := SubStr(Source, I, 1)
				if SC = BT {
					I += 2   ; skip backtick-escaped character
					continue
				}
				if SC = Quote {
					I++
					break
				}
				I++
			}
			continue
		}

		if Ch = "{"
			Open++
		else if Ch = "}"
			Close++
		I++
	}

	return Map("open", Open, "close", Close)
}





; =====================================
; =====================================
; ======= 3/ Test registrations =======
; =====================================
; =====================================

; Per-file checker. Kept at module scope (NOT nested in the loop) so each
; registered test binds its OWN path through the factory below. A function
; nested in the loop would close over the shared loop variable by reference, so
; every test would re-check only the LAST enumerated file — the guard then
; silently validated a single file instead of all of them.
_MetaBrace_CheckFile(AbsPath, NormRoot) {
	try {
		Source := FileRead(StrReplace(AbsPath, "/", "\"))
	} catch {
		Assert(false, "cannot read " . AbsPath)
		return
	}
	Counts := _MetaBrace_Count(Source)
	Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)
	Assert(
		Counts["open"] = Counts["close"],
		"unbalanced braces in " . Rel
		. " — open: " . Counts["open"]
		. "  close: " . Counts["close"]
	)
}

; Factory: binds AbsPath + NormRoot into a fresh closure per file (parameters are
; per-call, so each returned closure captures its own values).
_MetaBrace_MakeCheck(AbsPath, NormRoot) {
	return () => _MetaBrace_CheckFile(AbsPath, NormRoot)
}

_MetaRunBraceBalanceTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	NormRoot := StrReplace(DriverRoot, "\", "/")
	Checked := 0

	for Sub in ["infra", "modules", "platform", "ui"] {
		for AbsPath in _MetaBrace_ListFiles(StrReplace(DriverRoot . Sub, "/", "\")) {
			Checked++
			Test("brace balance: " . RegExReplace(AbsPath, ".*[/\\]"),
				_MetaBrace_MakeCheck(AbsPath, NormRoot))
		}
	}

	_MetaBraceAtLeastOne() {
		Assert(Checked > 0, "no AHK source files were located — check SrcDirs")
	}
	Test("meta brace balance: at least one file checked", _MetaBraceAtLeastOne)
}

_MetaRunBraceBalanceTests()
